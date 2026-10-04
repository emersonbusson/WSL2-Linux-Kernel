#!/usr/bin/env python3
"""Reconcile VMBus owner trace events without logging addresses or raw lines."""
import argparse
import base64
import gzip
import hashlib
import json
import re
from collections import Counter
from pathlib import Path
import zlib


EVENT = re.compile(
    r"vmbus_buffer_owner: owner_id=(\d+) channel_id=(\d+) "
    r"action=(created|released|retained|reclaimed|discarded) "
    r"size=(\d+) pages=(\d+) state=(\d+)\s*$"
)


def reconcile(lines):
    owners, errors, unobserved, capture_errors = {}, [], set(), []
    capture, ended = None, False
    for number, line in enumerate(lines, 1):
        if line.startswith("OWNER_TRACE "):
            match = re.fullmatch(r"OWNER_TRACE overruns=(\d+) dropped=(\d+) stats_cpus=([1-9]\d*) capture=boot_to_quiescence\s*", line)
            if match:
                if capture is not None:
                    errors.append(f"line {number}: repeated capture metadata")
                capture = tuple(map(int, match.groups()))
            elif line.strip() == "OWNER_TRACE end=1":
                ended = True
            continue
        if "vmbus_buffer_owner:" not in line:
            continue
        match = EVENT.search(line)
        if not match:
            capture_errors.append(f"line {number}: malformed owner event")
            continue
        ident, channel, action, size, pages, state = match.groups()
        ident, channel, size, pages, state = map(int, (ident, channel, size, pages, state))
        if ident == 0 or state > 7:
            errors.append(f"line {number}: invalid identity/state")
            continue
        if action == "created":
            if ident in owners or ident in unobserved:
                errors.append(f"line {number}: repeated owner creation")
            else:
                owners[ident] = {"channel": channel, "action": action, "released": False}
            continue
        if ident not in owners:
            unobserved.add(ident)
            continue
        owner = owners[ident]
        if owner["channel"] != channel:
            errors.append(f"line {number}: owner changed channel lifetime")
        if owner["action"] in ("reclaimed", "discarded"):
            errors.append(f"line {number}: event after terminal disposition")
        if action == "released":
            if owner["released"]:
                errors.append(f"line {number}: duplicate owner release")
            owner["released"] = True
        if action in ("retained", "reclaimed") and not owner["released"]:
            errors.append(f"line {number}: disposition before release")
        if action == "reclaimed" and state:
            errors.append(f"line {number}: reclaim with unresolved ownership/page state")
        if action == "retained" and not state:
            errors.append(f"line {number}: retention without a recorded reason")
        if action == "discarded" and (owner["released"] or pages or state):
            errors.append(f"line {number}: discard of a published/backed owner")
        owner.update(action=action, size=size, pages=pages, state=state)
    counts = Counter(owner["action"] for owner in owners.values())
    complete = capture is not None and capture[0] == 0 and capture[1] == 0 and ended and not capture_errors
    result = "PARTIAL" if not complete else "FAIL" if errors else "PARTIAL" if unobserved or not owners else "PASS"
    return {
        "verdict": result,
        "scope": "captured_owner_events_only",
        "owners_created": len(owners),
        "owners_unobserved_create": len(unobserved),
        "final_dispositions": dict(sorted(counts.items())),
        "errors": errors,
        "capture_errors": capture_errors,
        "capture_complete": complete,
        "limitation": "active owners are not leaks; this validates the captured allocation lifetimes, not all guest memory",
    }


def decode_capture(lines):
    headers, fragments, indexed, ended = Counter(), [], {}, False
    for line in lines:
        match = re.fullmatch(r"OWNER_TRACE_BLOB format=gzip-base64-indexed rows=([1-9]\d*) sha256=([0-9a-f]{64})\s*", line)
        if match:
            headers[(int(match[1]), match[2])] += 1
            continue
        match = re.fullmatch(r"OWNER_TRACE_BLOB format=gzip-base64 sha256=([0-9a-f]{64})\s*", line)
        if match:
            headers[(0, match[1])] += 1
            continue
        match = re.fullmatch(r"OWNER_TRACE_DATA index=(\d+) data=([A-Za-z0-9+/=]+)\s*", line)
        if match:
            index, data = int(match[1]), match[2]
            if index < 60000 and len(data) <= 76 and len(data) % 4 == 0:
                indexed.setdefault(index, Counter())[data] += 1
        elif line.startswith("OWNER_TRACE_DATA "):
            fragments.append(line[len("OWNER_TRACE_DATA "):].strip())
        elif line.strip() == "OWNER_TRACE_BLOB end=1":
            ended = True
    if not headers or not ended:
        return [], "incomplete-transport"
    ranked = headers.most_common()
    if len(ranked) > 1 and ranked[0][1] == ranked[1][1]:
        return [], "conflicting-transport-headers"
    (rows, digest), copies = ranked[0]
    if not rows and copies != 1:
        return [], "repeated-transport-header"
    if rows > 60000:
        return [], "transport-size-limit"
    if rows:
        fragments = []
        for index in range(rows):
            choices = indexed.get(index, Counter()).most_common()
            if not choices or (len(choices) > 1 and choices[0][1] == choices[1][1]):
                return [], "missing-or-conflicting-row"
            data = choices[0][0]
            if index < rows - 1 and len(data) != 76:
                return [], "incomplete-row"
            fragments.append(data)
    encoded = "".join(fragments)
    if len(encoded) > 4 * 1024 * 1024:
        return [], "transport-size-limit"
    try:
        packed = base64.b64decode(encoded, validate=True)
        if hashlib.sha256(packed).hexdigest() != digest:
            return [], "transport-checksum-mismatch"
        decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
        payload = decoder.decompress(packed, 16 * 1024 * 1024)
        if not decoder.eof or decoder.unused_data:
            return [], "invalid-or-oversized-payload"
        return payload.decode("utf-8").splitlines(), None
    except (ValueError, UnicodeError, zlib.error):
        return [], "invalid-transport"


def self_test():
    def event(ident, action, state=0, size=65536):
        if action in ("created", "discarded"):
            size = 0
        return f"vmbus_buffer_owner: owner_id={ident} channel_id=1 action={action} size={size} pages=0 state={state}"

    cases = [
        ("legitimate_release_reclaim", [event(1, "created"), event(1, "released"), event(1, "reclaimed")], "PASS"),
        ("empty_owner_discard", [event(1, "created"), event(1, "discarded")], "PASS"),
        ("distinct_same_size_owners", [event(1, "created"), event(2, "created"), event(1, "released"), event(2, "released", 1), event(1, "reclaimed"), event(2, "retained", 1)], "PASS"),
        ("duplicate_known_size_is_not_owner_identity", [event(1, "created"), event(2, "released")], "PARTIAL"),
        ("replacement_owner_same_size_is_not_complete_pass", [event(1, "created"), event(1, "released"), event(1, "reclaimed"), event(2, "released")], "PARTIAL"),
        ("unproven_host_ownership_blocks_reclaim", [event(1, "created"), event(1, "released", 1), event(1, "reclaimed", 1)], "FAIL"),
        ("duplicate_disposition_refused", [event(1, "created"), event(1, "released"), event(1, "reclaimed"), event(1, "reclaimed")], "FAIL"),
        ("empty_capture_is_not_pass", [], "PARTIAL"),
    ]
    for name, lines, expected in cases:
        actual = reconcile(["OWNER_TRACE overruns=0 dropped=0 stats_cpus=2 capture=boot_to_quiescence", *lines, "OWNER_TRACE end=1"])["verdict"]
        if actual != expected:
            raise AssertionError(f"{name}: {actual}, expected {expected}")
        print(f"PASS {name}")
    events = [event(1, "created"), event(1, "released"), event(1, "reclaimed")]
    payload = "\n".join(["OWNER_TRACE overruns=0 dropped=0 stats_cpus=2 capture=boot_to_quiescence", *events, "OWNER_TRACE end=1"]).encode()
    packed = gzip.compress(payload, mtime=0)
    blob = ["OWNER_TRACE_BLOB format=gzip-base64 sha256=" + hashlib.sha256(packed).hexdigest(), "OWNER_TRACE_DATA " + base64.b64encode(packed).decode(), "OWNER_TRACE_BLOB end=1"]
    decoded, error = decode_capture(blob)
    assert error is None and reconcile(decoded)["verdict"] == "PASS"
    print("PASS verified_compressed_capture")
    for name, altered in [
        ("truncated_serial_capture_is_partial", blob[:-1]),
        ("corrupt_serial_capture_is_partial", [blob[0], blob[1][:-4], blob[2]]),
        ("raw_serial_capture_is_unverified", payload.decode().splitlines()),
    ]:
        assert decode_capture(altered)[1] is not None, name
        print("PASS", name)
    events = [event(1, "created"), event(1, "released"), event(1, "reclaimed")]
    for name, metadata, footer in [
        ("overrun_is_partial", "OWNER_TRACE overruns=1 dropped=0 stats_cpus=2 capture=boot_to_quiescence", ["OWNER_TRACE end=1"]),
        ("dropped_event_is_partial", "OWNER_TRACE overruns=0 dropped=1 stats_cpus=2 capture=boot_to_quiescence", ["OWNER_TRACE end=1"]),
        ("missing_stats_is_partial", "OWNER_TRACE status=UNAVAILABLE", ["OWNER_TRACE end=1"]),
        ("truncated_capture_is_partial", "OWNER_TRACE overruns=0 dropped=0 stats_cpus=2 capture=boot_to_quiescence", []),
    ]:
        assert reconcile([metadata, *events, *footer])["verdict"] == "PARTIAL", name
        print(f"PASS {name}")


def self_test_replication():
    payload = b"OWNER_TRACE status=UNAVAILABLE\n"
    packed = gzip.compress(payload, mtime=0)
    encoded = base64.b64encode(packed).decode()
    rows = [encoded[i:i + 76] for i in range(0, len(encoded), 76)]
    header = f"OWNER_TRACE_BLOB format=gzip-base64-indexed rows={len(rows)} sha256={hashlib.sha256(packed).hexdigest()}"
    one = [header, *[f"OWNER_TRACE_DATA index={i} data={row}" for i, row in enumerate(rows)], "OWNER_TRACE_BLOB end=1"]
    complete = one * 3
    assert decode_capture(complete) == (payload.decode().splitlines(), None)
    print("PASS replicated_capture_verified")
    damaged = complete.copy()
    damaged[1] = damaged[1][:-1]
    assert decode_capture(damaged) == (payload.decode().splitlines(), None)
    print("PASS single_character_loss_recovered_with_checksum")
    damaged = complete.copy()
    for offset in (0, len(one)):
        damaged[offset + 1] = damaged[offset + 1][:-1]
    assert decode_capture(damaged) == (payload.decode().splitlines(), None)
    print("PASS two_lost_replicas_recovered_with_checksum")
    assert decode_capture([header, *one[-1:]])[1] is not None
    print("PASS all_replicas_lost_is_partial")
    prefix, data = one[1].split("data=", 1)
    changed = prefix + "data=" + ("A" if data[0] != "A" else "B") + data[1:]
    conflict = [header, one[1], changed, *one[2:]]
    assert decode_capture(conflict)[1] == "missing-or-conflicting-row"
    print("PASS conflicting_replicas_refused")
    wrong = [header, changed, *one[2:]]
    assert decode_capture(wrong)[1] is not None
    print("PASS coherent_wrong_copy_fails_checksum")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        self_test_replication()
        return 0
    if args.trace is None:
        parser.error("trace path is required")
    with args.trace.open() as stream:
        lines, transport_error = decode_capture(stream)
    result = reconcile(lines)
    result["transport_integrity"] = transport_error or "verified"
    if transport_error:
        result["verdict"] = "PARTIAL"
        result["capture_errors"].append(transport_error)
    print(json.dumps(result, indent=2))
    return {"PASS": 0, "FAIL": 1, "PARTIAL": 3}[result["verdict"]]


if __name__ == "__main__":
    raise SystemExit(main())
