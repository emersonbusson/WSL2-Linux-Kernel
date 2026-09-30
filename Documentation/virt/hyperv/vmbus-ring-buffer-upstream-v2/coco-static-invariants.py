#!/usr/bin/env python3
"""Machine-check the CoCo static invariants of the VMBus ring-buffer v2 series.

Static negative proof: the guest-fatal pattern Michael Kelley named
(set_memory_decrypted() on a vmalloc()/vmap() virtual range) has no code path
in any allocation this series introduces. Run against the candidate tree after
all six patches are applied.

  python3 coco-static-invariants.py --tree <linux-tree>

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

# The one virtual-address encryption site that mainline already had, preserved
# by the exported legacy API for non-owned caller buffers. It is reached only
# from vmbus_establish_gpadl() (memory_prepared == false) and is symmetrically
# undone by the owner->raw_decrypted branch of the reclaim worker. Every path
# this series allocates uses page_address() of an alloc_pages_node() result.
LEGACY_DECRYPT_ARG = "kbuffer"
LEGACY_ENCRYPT_ARG = "owner->addr"

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


def scan_set_memory(src: str, path: Path) -> None:
    """INV-1: encryption transitions only on page_address() chunks, plus the
    single preserved legacy virtual-address pair."""
    code = strip_comments(src)
    seen_decrypt_legacy = 0
    seen_encrypt_legacy = 0
    for match in re.finditer(r"\b(set_memory_decrypted|set_memory_encrypted)\s*\(", code):
        fn = match.group(1)
        arg = first_call_arg(code, match.end() - 1)
        line = line_of(code, match.start())
        bare = unwrap_cast(arg)
        compact = re.sub(r"\s+", " ", bare)
        if compact.startswith("page_address("):
            note(f"{path}:{line} {fn}(page_address(...)) OK direct-map chunk")
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
    """INV-4: guest-private / non-isolated buffers never touch encryption."""
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tree",
        required=True,
        help="candidate kernel tree with all six patches applied",
    )
    args = parser.parse_args()
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
    print("INV-4 private path never touches encryption ... PASS")
    print("INV-5 UIO never transitions encryption ........ PASS")
    print("INV-6 consumers avoid legacy decrypt path ..... PASS")
    print("COCO-STATIC-PROOF: all invariants hold.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
