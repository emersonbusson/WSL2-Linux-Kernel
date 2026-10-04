#!/usr/bin/env python3
"""Normalize and compare Sparse / W=1 diagnostic dumps (K12).

Takes two diagnostic logs -- baseline and candidate -- and reports the
diagnostics the candidate introduces or removes. Path and line-number
shifts are normalized away; warning type and surrounding context are
preserved, because erasing those would hide the very thing the gate is
for.

  python3 normalize-diagnostics.py --baseline base.log --candidate cand.log

Input is any log containing compiler or Sparse lines in the usual shapes:

  path/file.c:123:45: warning: ... [-Wsomething]
  path/file.c:123:45: sparse: warning: ...
  ./path/file.c:123: warning: ...

Output is a small report:
  INTRODUCED  <type>  <normalized-context>
  REMOVED     <type>  <normalized-context>
  UNCHANGED   count

Normalization rules (deliberate, and narrow):
  * the path is reduced to its basename plus the last two directory
    components, so a tree move or an a/ b/ prefix does not create a
    phantom difference;
  * the line:column becomes the token 'LINE', because a hunk above will
    shift every later line and that is not a diagnostic change;
  * the warning type (-Wfoo, or the text right after 'sparse: warning:')
    is kept verbatim;
  * the message text is kept verbatim except that hexadecimal numbers
    that look like kernel addresses (0xffff...) are replaced with ADDR,
    so the same diagnostic at a different address is the same diagnostic.

What this does not do: decide whether an introduced diagnostic is
acceptable. Every introduced row must be given an explicit disposition by
a human, and the disposition recorded next to the report.

Exit 0 = no introduced diagnostics. Exit 1 = at least one introduced.
Exit 2 = usage error.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter

# path:line:col: kind: message   (GCC / clang style)
GCC_RE = re.compile(
    r"^(?P<path>[^\s:]+):(?P<line>\d+):(?:(?P<col>\d+):)?\s+"
    r"(?P<kind>warning|error|note):\s+(?P<msg>.*)$"
)

# path:line: sparse: warning: message
SPARSE_RE = re.compile(
    r"^(?P<path>[^\s:]+):(?P<line>\d+):(?:\s+sparse:\s+)?"
    r"(?P<kind>warning|error):\s+(?P<msg>.*)$"
)

# A kernel virtual address, or any long hex that could be one.
ADDR_RE = re.compile(r"0x[fF]{4}[0-9a-fA-F]+")

# Trailing [-Wfoo] or [sparse-Wfoo] style type tag.
TYPE_RE = re.compile(r"\[(-W[^\]]+|sparse[^\]]*)\]\s*$")


def normalize_path(path: str) -> str:
    """basename plus at most two trailing directory components."""
    parts = path.replace("\\", "/").split("/")
    parts = [p for p in parts if p and p != "."]
    if len(parts) >= 3:
        return "/".join(parts[-3:])
    return "/".join(parts)


def normalize_message(msg: str) -> tuple[str, str]:
    """Return (type, normalized-message)."""
    m = TYPE_RE.search(msg)
    wtype = m.group(1) if m else "untyped"
    body = TYPE_RE.sub("", msg).strip()
    body = ADDR_RE.sub("ADDR", body)
    # Collapse whitespace so a reflowed message is the same diagnostic.
    body = re.sub(r"\s+", " ", body)
    return wtype, body


def parse_line(line: str) -> tuple[str, str, str] | None:
    """Return (normalized_path, type, normalized_message) or None."""
    line = line.rstrip("\n")
    m = GCC_RE.match(line) or SPARSE_RE.match(line)
    if not m:
        return None
    kind = m.group("kind")
    # Notes are context for a warning, not independent diagnostics.
    if kind == "note":
        return None
    wtype, body = normalize_message(m.group("msg"))
    return normalize_path(m.group("path")), wtype, body


def load(path: str) -> Counter:
    counts: Counter = Counter()
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            parsed = parse_line(line)
            if parsed:
                counts[parsed] += 1
    return counts


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--show-unchanged", action="store_true")
    args = ap.parse_args()

    try:
        base = load(args.baseline)
        cand = load(args.candidate)
    except OSError as exc:
        print(f"usage error: {exc}", file=sys.stderr)
        return 2

    introduced = cand - base
    removed = base - cand
    unchanged = cand & base

    for (path, wtype, body), n in sorted(introduced.items()):
        for _ in range(n):
            print(f"INTRODUCED  {wtype:<16} {path}  {body}")
    for (path, wtype, body), n in sorted(removed.items()):
        for _ in range(n):
            print(f"REMOVED     {wtype:<16} {path}  {body}")

    print(f"UNCHANGED   {sum(unchanged.values())}")
    print(f"INTRODUCED_total {sum(introduced.values())}")
    print(f"REMOVED_total    {sum(removed.values())}")

    if args.show_unchanged:
        for (path, wtype, body), n in sorted(unchanged.items()):
            for _ in range(n):
                print(f"UNCHANGED   {wtype:<16} {path}  {body}")

    return 1 if introduced else 0


if __name__ == "__main__":
    sys.exit(main())
