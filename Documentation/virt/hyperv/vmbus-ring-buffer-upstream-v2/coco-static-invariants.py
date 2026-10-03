#!/usr/bin/env python3
"""Machine-check the CoCo static invariants of the VMBus ring-buffer v2 series.

Static negative check for the guest-fatal pattern Michael Kelley named
(set_memory_decrypted() on a vmalloc()/vmap() virtual range): every
set_memory_*() site in the paths this series allocates receives a
page_address() direct-map chunk, an accepted legacy argument, or the file is
rejected. Run against the candidate tree after all thirteen patches are
applied.

  python3 coco-static-invariants.py --tree <linux-tree>

What this does establish: no set_memory_*() call site this series introduces
or moves takes a non-direct-map argument, and INV-2/3/6 hold as written.

What this does not establish: reachability. The checks are syntactic. INV-4
in particular compares the textual order of vzalloc() and set_memory_*() inside
vmbus_alloc_buffer_owned(); it is not a control-flow proof that the private
path returns before an encryption transition. Treat the result as a
necessary static condition, not as a closed COCO row.

Exit 0 = every invariant holds. Exit 1 = at least one invariant is violated,
with the exact site printed. This step must never be silenced to land a patch.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

CHANNEL = Path("drivers/hv/channel.c")
UIO = Path("drivers/uio/uio_hv_generic.c")
NETVSC = Path("drivers/net/hyperv/netvsc.c")

# Virtual-address encryption sites that mainline already had, preserved by the
# exported legacy API for non-owned caller buffers. vmbus_establish_gpadl()
# decrypts the caller's kbuffer once (memory_prepared == false) and attaches no
# owner, so the range is re-encrypted on whichever teardown path holds it. The
# owner-less compat vmbus_teardown_gpadl() adapter does it synchronously on
# gpadl->buffer, exactly as mainline always has, because its caller frees the
# range as soon as the symbol returns and there is no owner left to defer the
# work to. A retained owner instead defers the same work to the reclaim worker:
# owner->raw_decrypted re-encrypts the whole range through owner->addr, and the
# chunked owner->needs_encrypt path re-encrypts per page_address() page. Every
# path this series allocates uses page_address() of an alloc_pages_node() result.
#
# A bare local is also a direct-map chunk when every assignment to it is
# page_address() of a page. mainline's own vmbus_free_buffer() has always done
# exactly that:
#
#   unsigned long vaddr = (unsigned long)page_address(chunks[i]);
#   ...
#   if (set_memory_encrypted(vaddr, 1U << order))
#
# Rejecting the temporary would reject mainline. Accepting any bare identifier
# would hide a vmalloc() temporary. So accept a local only when every assignment
# to that name in the file derives from page_address().
#
# "Every assignment" means every assignment, not every declaration. A clean
# declaration followed by a reassignment hands set_memory_*() whatever the last
# write put there, and a checker that only reads declarations accepts it:
#
#   unsigned long vaddr = (unsigned long)page_address(chunks[i]);
#   unsigned int order = folio_order(page_folio(chunks[i]));
#   vaddr = (unsigned long)addr;           /* not page_address() */
#   if (set_memory_encrypted(vaddr, 1U << order))
#
# This is an aliasing hole, not a spelling quirk, so the gate rejects a name as
# soon as anything other than a page_address() derivation is assigned to it --
# including compound assignment and increment, which also move the address.
LEGACY_DECRYPT_ARG = "kbuffer"
LEGACY_ENCRYPT_ARG = "owner->addr"
LEGACY_COMPAT_ENCRYPT_ARG = "gpadl->buffer"

failures: list[str] = []
notes: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)


def note(msg: str) -> None:
    notes.append(msg)


def read(tree: Path, rel: Path) -> str:
    path = tree / rel
    if not path.is_file():
        fail(f"missing source file: {rel}")
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def strip_comments(src: str) -> str:
    """Remove // and /* */ comments and string/char literals, keep newlines."""
    out: list[str] = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                if src[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
        elif c in ('"', "'"):
            quote = c
            out.append(" ")
            i += 1
            while i < n and src[i] != quote:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == "\n":
                    out.append("\n")
                i += 1
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def line_of(src: str, index: int) -> int:
    return src.count("\n", 0, index) + 1


def function_body(src: str, name: str) -> tuple[str, int] | None:
    """Return (body, start_line) of a function definition, or None."""
    pattern = re.compile(
        r"^[a-zA-Z_][\w\s\*]*\b" + re.escape(name) + r"\s*\([^;]*?\)\s*\{",
        re.MULTILINE | re.DOTALL,
    )
    for match in pattern.finditer(src):
        start = match.end() - 1
        depth = 0
        i = start
        while i < len(src):
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    return src[start : i + 1], line_of(src, match.start())
            i += 1
    return None


def first_call_arg(call_src: str, open_paren_index: int) -> str:
    """Extract the first argument of a call, paren-balanced."""
    i = open_paren_index + 1
    depth = 0
    start = i
    while i < len(call_src):
        c = call_src[i]
        if c == "(":
            depth += 1
        elif c == ")":
            if depth == 0:
                return call_src[start:i].strip()
            depth -= 1
        elif c == "," and depth == 0:
            return call_src[start:i].strip()
        i += 1
    return call_src[start:].strip()


def unwrap_cast(expr: str) -> str:
    """Strip leading C casts such as (unsigned long) or (unsigned long int)."""
    expr = re.sub(r"\s+", " ", expr.strip())
    while True:
        match = re.match(r"^\(\s*(?:unsigned\s+|signed\s+)?(?:long|int|u32|u64|size_t|void)\s*\)\s*", expr)
        if not match:
            return expr
        expr = expr[match.end():].strip()


# A direct-map address local: `T name = [cast] page_address(`.
DIRECT_MAP_DECL = re.compile(
    r"\b(?:unsigned\s+long(?:\s+int)?|u64|uintptr_t)\s+(\w+)\s*=\s*"
)
# A write to a bare identifier, with no -> or . member access in front of it.
BARE_WRITE = re.compile(r"(?<![\w.>])(\w+)\s*(\+\+|--|<<=|>>=|[+\-*/%|&^]?=)(?!=)")
# A bare identifier occurrence, ignoring member access and longer names.
BARE_IDENT = re.compile(r"(?<![\w.>])(\w+)(?!\w)")
SET_MEMORY_CALL = re.compile(r"\bset_memory_(?:en|de)crypted\s*\(")


def is_pure_call(expr: str, fn: str) -> bool:
    """True when @expr is exactly fn(...) and nothing else.

    The gate is about the range an expression names, not about its spelling.
    page_address(p) + (addr - page_address(p)) simplifies to addr -- a virtual
    address, not a direct-map chunk -- while every prefix test accepts it,
    because the text does start with page_address(. So the call's matching
    parenthesis has to be the last character of the expression.
    """
    expr = re.sub(r"\s+", " ", expr.strip())
    match = re.match(r"^\b" + re.escape(fn) + r"\s*\(", expr)
    if not match:
        return False
    open_i = expr.index("(", match.start())
    depth = 0
    for i in range(open_i, len(expr)):
        if expr[i] == "(":
            depth += 1
        elif expr[i] == ")":
            depth -= 1
            if depth == 0:
                return i == len(expr) - 1
    return False


def first_arg_span(code: str, open_paren_index: int) -> tuple[int, int]:
    """Span of the first argument of a call, paren-balanced."""
    i = open_paren_index + 1
    depth = 0
    start = i
    while i < len(code):
        c = code[i]
        if c == "(":
            depth += 1
        elif c == ")":
            if depth == 0:
                return start, i
            depth -= 1
        elif c == "," and depth == 0:
            return start, i
        i += 1
    return start, len(code)


def sanctioned_read_spans(code: str) -> list[tuple[int, int]]:
    """Spans of set_memory_* first arguments that are exactly a bare name.

    Those are the only reads this gate understands: the transition is being
    applied to the range that name already describes. A name read anywhere
    else may be handed to a helper that writes it, so it cannot be trusted.
    """
    spans: list[tuple[int, int]] = []
    for match in SET_MEMORY_CALL.finditer(code):
        start, end = first_arg_span(code, match.end() - 1)
        bare = re.sub(r"\s+", " ", unwrap_cast(code[start:end]).strip())
        if re.fullmatch(r"\w+", bare):
            spans.append((start, end))
    return spans


def blank_spans(code: str, spans: list[tuple[int, int]]) -> str:
    out = list(code)
    for start, end in spans:
        for i in range(start, end):
            if out[i] != "\n":
                out[i] = " "
    return "".join(out)


def direct_map_locals(code: str) -> set[str]:
    """Names whose every assignment is a pure page_address() direct-map chunk.

    mainline's vmbus_free_buffer() stores page_address(chunks[i]) in a local
    and passes that local to set_memory_encrypted(). The invariant is about the
    range, not the spelling, so a local qualifies only when nothing ever
    assigns it a non-page_address value.

    Both the declaration and any later write count. Collecting declarations
    alone is how a reassignment of a clean temporary slipped past this gate.

    The right-hand side has to be the whole page_address() call. An expression
    that merely starts with one is not a direct-map chunk:
    page_address(p) + (addr - page_address(p)) is addr.

    And the name has to be used only in ways this gate understands: as the
    left-hand side of one of those assignments, or as the first argument of a
    set_memory_*() call. Anything else -- an address taken by a helper, a
    macro that writes it, an unsanctioned call argument -- can move the
    address without this checker seeing an assignment, so the name is dropped
    rather than trusted.
    """
    writes: dict[str, list[tuple[int, int, str]]] = {}
    decl_tail = re.compile(
        r"(?:unsigned\s+long(?:\s+int)?|u64|uintptr_t)\s+$"
    )

    for match in DIRECT_MAP_DECL.finditer(code):
        rhs = code[match.end():].split(";", 1)[0]
        writes.setdefault(match.group(1), []).append(
            (match.start(1), match.end(1),
             unwrap_cast(re.sub(r"\s+", " ", rhs.strip())))
        )
    if not writes:
        return set()

    for name in list(writes):
        for match in BARE_WRITE.finditer(code):
            if match.group(1) != name:
                continue
            before = code[max(0, match.start() - 40):match.start()]
            if decl_tail.search(before):
                continue  # already recorded from the declaration
            op = match.group(2)
            if op == "=":
                rhs = code[match.end():].split(";", 1)[0]
                writes[name].append(
                    (match.start(1), match.end(1),
                     unwrap_cast(re.sub(r"\s+", " ", rhs.strip())))
                )
            else:
                # ++, --, += and friends move the address without deriving it.
                writes[name].append(
                    (match.start(1), match.end(1), f"<compound-assignment:{op}>")
                )

    accepted: set[str] = set()
    reads = sanctioned_read_spans(code)
    for name, assigns in writes.items():
        if not assigns or not all(is_pure_call(rhs, "page_address")
                                  for _, _, rhs in assigns):
            continue
        used = blank_spans(code, reads)
        used = blank_spans(used, [(s, e) for s, e, _ in assigns])
        leftover = [m for m in BARE_IDENT.finditer(used) if m.group(1) == name]
        if leftover:
            continue
        accepted.add(name)
    return accepted


def scan_set_memory(src: str, path: Path) -> None:
    """INV-1: encryption transitions only on page_address() chunks, plus the
    single preserved legacy virtual-address pair."""
    code = strip_comments(src)
    direct_map = direct_map_locals(code)
    seen_decrypt_legacy = 0
    seen_encrypt_legacy = 0
    seen_compat_encrypt = 0
    for match in re.finditer(r"\b(set_memory_decrypted|set_memory_encrypted)\s*\(", code):
        fn = match.group(1)
        arg = first_call_arg(code, match.end() - 1)
        line = line_of(code, match.start())
        bare = unwrap_cast(arg)
        compact = re.sub(r"\s+", " ", bare)
        if is_pure_call(compact, "page_address"):
            note(f"{path}:{line} {fn}(page_address(...)) OK direct-map chunk")
            continue
        if compact in direct_map:
            note(f"{path}:{line} {fn}({compact}) OK direct-map local from page_address()")
            continue
        if fn == "set_memory_decrypted" and compact in (
            f"(unsigned long){LEGACY_DECRYPT_ARG}",
            f"(unsigned long) {LEGACY_DECRYPT_ARG}",
            LEGACY_DECRYPT_ARG,
        ):
            seen_decrypt_legacy += 1
            note(f"{path}:{line} set_memory_decrypted({LEGACY_DECRYPT_ARG}) legacy export")
            continue
        if fn == "set_memory_encrypted" and compact in (
            f"(unsigned long){LEGACY_ENCRYPT_ARG}",
            f"(unsigned long) {LEGACY_ENCRYPT_ARG}",
            LEGACY_ENCRYPT_ARG,
        ):
            seen_encrypt_legacy += 1
            note(f"{path}:{line} set_memory_encrypted({LEGACY_ENCRYPT_ARG}) legacy reclaim")
            continue
        if fn == "set_memory_encrypted" and compact in (
            f"(unsigned long){LEGACY_COMPAT_ENCRYPT_ARG}",
            f"(unsigned long) {LEGACY_COMPAT_ENCRYPT_ARG}",
            LEGACY_COMPAT_ENCRYPT_ARG,
        ):
            seen_compat_encrypt += 1
            note(
                f"{path}:{line} set_memory_encrypted({LEGACY_COMPAT_ENCRYPT_ARG}) "
                f"legacy compat teardown"
            )
            continue
        fail(
            f"INV-1 {path}:{line}: {fn}() on a non-page_address argument "
            f"`{compact}` — this is the guest-fatal vmalloc decryption pattern"
        )
    if seen_decrypt_legacy != 1:
        fail(
            f"INV-1: expected exactly 1 legacy set_memory_decrypted({LEGACY_DECRYPT_ARG}) "
            f"site in {path}, found {seen_decrypt_legacy}"
        )
    if seen_encrypt_legacy != 1:
        fail(
            f"INV-1: expected exactly 1 legacy set_memory_encrypted({LEGACY_ENCRYPT_ARG}) "
            f"site in {path}, found {seen_encrypt_legacy}"
        )
    if seen_compat_encrypt != 1:
        fail(
            f"INV-1: expected exactly 1 legacy "
            f"set_memory_encrypted({LEGACY_COMPAT_ENCRYPT_ARG}) "
            f"site in {path}, found {seen_compat_encrypt}"
        )


def scan_memory_prepared(src: str, path: Path) -> None:
    """INV-2: only the legacy export may pass memory_prepared == false."""
    code = strip_comments(src)
    body = function_body(code, "__vmbus_establish_gpadl")
    if body is None:
        fail("INV-2: __vmbus_establish_gpadl() not found")
        return

    # Every call site of __vmbus_establish_gpadl(...) must end with true or false.
    for match in re.finditer(r"\b__vmbus_establish_gpadl\s*\(", code):
        call_start = match.end() - 1
        depth = 0
        i = call_start
        while i < len(code):
            if code[i] == "(":
                depth += 1
            elif code[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        # Skip the function definition itself: `)` followed by `{`.
        after = code[i + 1 : i + 40].lstrip()
        if after.startswith("{"):
            continue
        args_src = code[call_start + 1 : i]
        # last argument is memory_prepared
        parts: list[str] = []
        depth = 0
        start = 0
        for idx, c in enumerate(args_src):
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            elif c == "," and depth == 0:
                parts.append(args_src[start:idx].strip())
                start = idx + 1
        parts.append(args_src[start:].strip())
        if len(parts) < 5:
            fail(
                f"INV-2 {path}:{line_of(code, match.start())}: "
                f"__vmbus_establish_gpadl() call has {len(parts)} args, expected 5"
            )
            continue
        prepared = re.sub(r"\s+", " ", parts[-1])
        line = line_of(code, match.start())
        if prepared == "true":
            note(f"{path}:{line} __vmbus_establish_gpadl(..., memory_prepared=true) OK")
        elif prepared == "false":
            # allowed only from the legacy export vmbus_establish_gpadl()
            window = code[max(0, match.start() - 800) : match.start()]
            if "vmbus_establish_gpadl_caller_decrypted" in window:
                fail(
                    f"INV-2 {path}:{line}: vmbus_establish_gpadl_caller_decrypted() "
                    f"must pass memory_prepared=true"
                )
            elif re.search(
                r"\bint\s+vmbus_establish_gpadl\s*\(", window
            ) or window.rstrip().endswith("return"):
                note(f"{path}:{line} memory_prepared=false from legacy export OK")
            else:
                # fall back: accept only if inside the legacy export body
                legacy = function_body(code, "vmbus_establish_gpadl")
                owned = function_body(code, "vmbus_establish_gpadl_owned")
                caller = function_body(code, "vmbus_establish_gpadl_caller_decrypted")
                in_legacy = legacy and legacy[1] <= line < legacy[1] + 80
                in_bad = (owned and owned[1] <= line < owned[1] + 30) or (
                    caller and caller[1] <= line < caller[1] + 40
                )
                if in_bad or not in_legacy:
                    fail(
                        f"INV-2 {path}:{line}: memory_prepared=false outside the "
                        f"legacy vmbus_establish_gpadl() export"
                    )
                else:
                    note(f"{path}:{line} memory_prepared=false from legacy export OK")
        else:
            fail(
                f"INV-2 {path}:{line}: memory_prepared argument is `{prepared}`, "
                f"expected literal true or false"
            )

    # Explicit: owned / caller_decrypted / ring open must never decrypt again.
    for name, want in (
        ("vmbus_establish_gpadl_owned", "true"),
        ("vmbus_establish_gpadl_caller_decrypted", "true"),
    ):
        fn = function_body(code, name)
        if fn is None:
            fail(f"INV-2: {name}() not found")
            continue
        body_src, base_line = fn
        if re.search(r"\bset_memory_", body_src):
            fail(f"INV-2 {path}:{base_line}: {name}() must not call set_memory_*")
        if want not in body_src:
            fail(f"INV-2 {path}:{base_line}: {name}() must pass memory_prepared=true")

    # Ring open: the HV_GPADL_RING call must be prepared.
    for match in re.finditer(r"__vmbus_establish_gpadl\s*\(\s*newchannel\s*,\s*HV_GPADL_RING", code):
        line = line_of(code, match.start())
        tail = code[match.start() : match.start() + 400]
        if not re.search(r",\s*true\s*\)", tail):
            fail(f"INV-2 {path}:{line}: ring GPADL must pass memory_prepared=true")


def scan_retain(src: str, path: Path) -> None:
    """INV-3: unknown page state is retained, never freed or re-encrypted."""
    code = strip_comments(src)

    alloc = function_body(code, "vmbus_alloc_buffer_owned")
    if alloc is None:
        fail("INV-3: vmbus_alloc_buffer_owned() not found")
    else:
        body, line = alloc
        if "set_memory_decrypted" not in body:
            fail(f"INV-3 {path}:{line}: allocator must decrypt chunk pages")
        if not re.search(r"encryption_unknown\s*=\s*true", body):
            fail(
                f"INV-3 {path}:{line}: allocator must set owner->encryption_unknown "
                f"when set_memory_decrypted() fails"
            )
        # the failure path must not free the page it just could not transition
        if not re.search(r"set_memory_decrypted[\s\S]{0,400}?encryption_unknown\s*=\s*true", body):
            fail(
                f"INV-3 {path}:{line}: encryption_unknown must be set on the "
                f"set_memory_decrypted() failure path"
            )

    gate = function_body(code, "vmbus_buffer_owner_can_reclaim")
    if gate is None:
        fail("INV-3: vmbus_buffer_owner_can_reclaim() not found")
    else:
        body, line = gate
        for marker in ("permanent_leak", "encryption_unknown"):
            if marker not in body:
                fail(f"INV-3 {path}:{line}: reclaim gate must reject owner->{marker}")
        if not re.search(r"!\s*owner->encryption_unknown", body):
            fail(f"INV-3 {path}:{line}: reclaim gate must require !encryption_unknown")

    free = function_body(code, "vmbus_free_buffer")
    if free is None:
        fail("INV-3: vmbus_free_buffer() not found")
    else:
        body, line = free
        # set_memory_encrypted failure must continue (skip __free_pages)
        if not re.search(
            r"set_memory_encrypted\s*\([\s\S]{0,200}?\)\s*(?:\n\s*)?continue\s*;", body
        ):
            fail(
                f"INV-3 {path}:{line}: vmbus_free_buffer() must skip __free_pages "
                f"when re-encryption fails"
            )

    reclaim = function_body(code, "vmbus_buffer_reclaim_work")
    if reclaim is None:
        fail("INV-3: vmbus_buffer_reclaim_work() not found")
    else:
        body, line = reclaim
        if not re.search(r"permanent_leak\s*=\s*true", body):
            fail(f"INV-3 {path}:{line}: reclaim must mark permanent_leak on encrypt failure")
        # needs_encrypt branch must use page_address chunks
        if "needs_encrypt" in body and not re.search(
            r"needs_encrypt[\s\S]{0,400}?page_address\(", body
        ):
            fail(f"INV-3 {path}:{line}: needs_encrypt branch must re-encrypt via page_address()")


def scan_private_path(src: str, path: Path) -> None:
    """INV-4: the private allocation is textually free of encryption calls.

    Checks ordering only: vzalloc() appears in vmbus_alloc_buffer_owned()
    before any set_memory_*() in that body, and the shared-page selector does
    not itself touch encryption state. This is not a reachability proof that
    the private path returns before a transition.
    """
    code = strip_comments(src)
    alloc = function_body(code, "vmbus_alloc_buffer_owned")
    if alloc is None:
        fail("INV-4: vmbus_alloc_buffer_owned() not found")
        return
    body, line = alloc
    if "vzalloc" not in body:
        fail(f"INV-4 {path}:{line}: private path must use vzalloc()")
    # vzalloc branch must return before any set_memory_*
    vz = body.find("vzalloc")
    sm = body.find("set_memory_")
    if vz < 0:
        fail(f"INV-4 {path}:{line}: vzalloc() path missing")
    elif sm >= 0 and sm < vz:
        fail(f"INV-4 {path}:{line}: set_memory_* appears before the vzalloc() private path")

    selector = function_body(code, "vmbus_needs_shared_pages")
    if selector is None:
        fail("INV-4: vmbus_needs_shared_pages() not found")
    else:
        body, line = selector
        if "confidential" not in body:
            fail(f"INV-4 {path}:{line}: selector must honour the confidential flag")
        if "set_memory_" in body:
            fail(f"INV-4 {path}:{line}: selector must not touch encryption state")


def scan_uio(src: str, path: Path) -> None:
    """INV-5: UIO maps pages; it never transitions encryption state."""
    code = strip_comments(src)
    for match in re.finditer(r"\bset_memory_\w+\s*\(", code):
        fail(
            f"INV-5 {path}:{line_of(code, match.start())}: UIO must not call "
            f"{match.group(0).rstrip('(')}()"
        )
    if "vmbus_establish_gpadl" in code and not re.search(
        r"vmbus_establish_gpadl_owned\s*\(", code
    ):
        fail(f"INV-5 {path}: UIO must use vmbus_establish_gpadl_owned()")


def scan_legacy_callers(src: str, path: Path) -> None:
    """INV-6: series consumers never take the legacy decrypt-on-vaddr path."""
    code = strip_comments(src)
    for match in re.finditer(r"\bvmbus_establish_gpadl\s*\(", code):
        # skip the _owned and _caller_decrypted names, which are longer
        before = code[max(0, match.start() - 30) : match.start()]
        if before.rstrip().endswith(("establish_gpadl_owned", "establish_gpadl_caller_decrypted")):
            continue
        if re.search(r"establish_gpadl_(owned|caller_decrypted)\s*$", before):
            continue
        fail(
            f"INV-6 {path}:{line_of(code, match.start())}: consumer must not call "
            f"vmbus_establish_gpadl() — use vmbus_establish_gpadl_owned()"
        )



def self_test() -> int:
    """Refusal fixtures for the direct-map alias rules.

    These fragments are synthetic. They demonstrate gaps in the *validator*:
    a prefix test that accepted an algebraic alias, and a write tracker that
    missed a write through a helper. They are not reproduced kernel leaks and
    must never be cited as one.

    mainline's real shape is the accept case and has to stay accepted:

        unsigned long vaddr = (unsigned long)page_address(chunks[i]);
        ...
        if (set_memory_encrypted(vaddr, 1U << order))
            continue;
    """
    results: list[tuple[str, bool, str]] = []

    def check(name: str, ok: bool, detail: str) -> None:
        results.append((name, ok, detail))

    def local_case(name: str, var: str, code: str, want: bool) -> None:
        got = var in direct_map_locals(strip_comments(code))
        check(name, got == want,
              f"direct_map_locals -> {got}, want {want}")

    def pure_call_case(name: str, expr: str, want: bool) -> None:
        got = is_pure_call(expr, "page_address")
        check(name, got == want, f"is_pure_call -> {got}, want {want}")

    def call_site_case(name: str, code: str, want_reject: bool) -> None:
        global failures, notes
        saved_failures, saved_notes = failures, notes
        failures, notes = [], []
        try:
            scan_set_memory(strip_comments(code), Path("selftest.c"))
            rejected = any("non-page_address argument" in f for f in failures)
        finally:
            failures, notes = saved_failures, saved_notes
        check(name, rejected == want_reject,
              f"scan_set_memory rejected -> {rejected}, want {want_reject}")

    # ---- is_pure_call: the expression, not its prefix ----
    pure_call_case(
        "coco_pure_call_exact_accept",
        "page_address(chunks[i])",
        True,
    )
    pure_call_case(
        "coco_pure_call_ternary_arg_accept",
        "page_address(cond ? a : b)",
        True,
    )
    pure_call_case(
        "coco_pure_call_trailing_plus_reject",
        "page_address(p) + (addr - page_address(p))",
        False,
    )
    pure_call_case(
        "coco_pure_call_trailing_ternary_reject",
        "page_address(p) ? a : b",
        False,
    )
    pure_call_case(
        "coco_pure_call_trailing_or_one_reject",
        "page_address(p) | 1",
        False,
    )
    pure_call_case(
        "coco_pure_call_not_a_call_reject",
        "addr",
        False,
    )

    # ---- direct_map_locals: every assignment, the whole expression ----
    local_case(
        "coco_alias_exact_direct_map_accept",
        "vaddr",
        """
void f(struct page **chunks, unsigned int i, unsigned int order)
{
	unsigned long vaddr = (unsigned long)page_address(chunks[i]);

	if (set_memory_encrypted(vaddr, 1U << order))
		continue;
}
""",
        True,
    )
    local_case(
        "coco_alias_reassigned_virtual_reject",
        "vaddr",
        """
void f(struct page **chunks, unsigned int i, unsigned int order)
{
	unsigned long vaddr = (unsigned long)page_address(chunks[i]);

	vaddr = (unsigned long)addr;
	if (set_memory_encrypted(vaddr, 1U << order))
		continue;
}
""",
        False,
    )
    local_case(
        "coco_alias_algebraic_virtual_reject",
        "vaddr",
        """
void f(struct page **chunks, unsigned int i, unsigned int order)
{
	unsigned long vaddr = (unsigned long)page_address(chunks[i])
		+ ((unsigned long)addr - (unsigned long)page_address(chunks[i]));

	if (set_memory_encrypted(vaddr, 1U << order))
		continue;
}
""",
        False,
    )
    local_case(
        "coco_alias_conditional_reject",
        "vaddr",
        """
void f(struct page *a, struct page *b, int cond, unsigned int order)
{
	unsigned long vaddr = cond ? (unsigned long)page_address(a)
				   : (unsigned long)addr;

	if (set_memory_encrypted(vaddr, 1U << order))
		continue;
}
""",
        False,
    )
    local_case(
        "coco_alias_scope_shadow_reject",
        "vaddr",
        """
void f(struct page *p, unsigned int order)
{
	unsigned long vaddr = (unsigned long)page_address(p);

	if (set_memory_encrypted(vaddr, 1U << order))
		return;
}

void g(unsigned long addr, unsigned int order)
{
	unsigned long vaddr = addr;

	if (set_memory_encrypted(vaddr, 1U << order))
		return;
}
""",
        False,
    )
    local_case(
        "coco_alias_compound_write_reject",
        "vaddr",
        """
void f(struct page *p, unsigned int order)
{
	unsigned long vaddr = (unsigned long)page_address(p);

	vaddr += 1;
	if (set_memory_encrypted(vaddr, 1U << order))
		return;
}
""",
        False,
    )
    local_case(
        "coco_alias_helper_write_reject",
        "vaddr",
        """
void f(struct page *p, unsigned long addr, unsigned int order)
{
	unsigned long vaddr = (unsigned long)page_address(p);

	set_vaddr(&vaddr, addr);
	if (set_memory_encrypted(vaddr, 1U << order))
		return;
}
""",
        False,
    )
    local_case(
        "coco_alias_macro_write_reject",
        "vaddr",
        """
void f(struct page *p, unsigned long addr, unsigned int order)
{
	unsigned long vaddr = (unsigned long)page_address(p);

	SET_VADDR(vaddr, addr);
	if (set_memory_encrypted(vaddr, 1U << order))
		return;
}
""",
        False,
    )
    local_case(
        "coco_alias_unsanctioned_read_reject",
        "vaddr",
        """
void f(struct page *p, unsigned int order)
{
	unsigned long vaddr = (unsigned long)page_address(p);

	do_thing(vaddr, 1);
	if (set_memory_encrypted(vaddr, 1U << order))
		return;
}
""",
        False,
    )

    # ---- scan_set_memory: the call-site argument, the whole expression ----
    call_site_case(
        "coco_call_exact_direct_map_accept",
        """
void f(struct page *page, unsigned int order)
{
	if (set_memory_encrypted((unsigned long)page_address(page),
				 1U << order))
		return;
}
""",
        False,
    )
    call_site_case(
        "coco_call_algebraic_virtual_reject",
        """
void f(struct page *p, unsigned long addr, unsigned int order)
{
	if (set_memory_encrypted((unsigned long)page_address(p)
				 + ((unsigned long)addr
				    - (unsigned long)page_address(p)),
				 1U << order))
		return;
}
""",
        True,
    )
    call_site_case(
        "coco_call_trailing_or_one_reject",
        """
void f(struct page *p, unsigned int order)
{
	if (set_memory_encrypted((unsigned long)page_address(p) | 1,
				 1U << order))
		return;
}
""",
        True,
    )

    failed = [r for r in results if not r[1]]
    print("=== CoCo alias self-test ===")
    for name, ok, detail in results:
        print(f"  {'ok  ' if ok else 'FAIL'} {name}: {detail}")
    print()
    if failed:
        print(f"{len(failed)} self-test case(s) failed.")
        return 1
    print(f"All {len(results)} self-test cases hold.")
    print("scope: synthetic validator fixtures, not reproduced kernel leaks.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tree",
        help="candidate kernel tree with all thirteen patches applied",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run the direct-map alias refusal fixtures and exit",
    )
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.tree:
        parser.error("--tree is required unless --self-test is given")
    tree = Path(args.tree)
    if not tree.is_dir():
        print(f"error: not a directory: {tree}", file=sys.stderr)
        return 2

    channel = read(tree, CHANNEL)
    uio = read(tree, UIO)
    netvsc = read(tree, NETVSC)
    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1

    scan_set_memory(channel, CHANNEL)
    scan_memory_prepared(channel, CHANNEL)
    scan_retain(channel, CHANNEL)
    scan_private_path(channel, CHANNEL)
    scan_uio(uio, UIO)
    scan_legacy_callers(netvsc, NETVSC)
    scan_legacy_callers(uio, UIO)

    print("=== CoCo static invariants ===")
    for n in notes:
        print(f"  ok  {n}")
    if failures:
        print()
        for f in failures:
            print(f"FAIL {f}")
        print(f"\n{len(failures)} invariant violation(s).")
        return 1

    print("INV-1 direct-map chunk encryption ............ PASS")
    print("INV-2 prepared GPADL does not re-decrypt ...... PASS")
    print("INV-3 unknown page state retained ............. PASS")
    print("INV-4 private alloc ordering, not reachability  PASS")
    print("INV-5 UIO never transitions encryption ........ PASS")
    print("INV-6 consumers avoid legacy decrypt path ..... PASS")
    print("COCO-STATIC-PROOF: all invariants hold.")
    print("scope: syntactic necessary condition, not a closed COCO row.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
