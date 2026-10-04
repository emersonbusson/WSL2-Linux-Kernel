#!/usr/bin/env python3
"""Validate a CoCo report structurally; this never proves hardware execution."""
import argparse
import copy
import datetime
import json
import re
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker


def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate-json-key")
        result[key] = value
    return result


def load_json(path):
    if path.stat().st_size > 10 * 1024 * 1024:
        raise ValueError("report-size-limit")
    return json.loads(path.read_text(), object_pairs_hook=reject_duplicates,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError("non-json-number")))


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, child in value.items():
            yield key
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)


def validate_report(report, schema):
    # Report codes only: schema error messages may include sensitive values.
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = {"schema:" + e.validator for e in validator.iter_errors(report)}
    for value in strings(report):
        if "TODO" in value:
            errors.add("unfinished-report")
        if re.search(r"0x[fF]{4}[0-9a-fA-F]+|\bffff[0-9a-fA-F]{12}\b", value):
            errors.add("kernel-address")
        if re.search(r"/home/|/mnt/[a-z]/|/Users/|[A-Za-z]:[\\/]", value):
            errors.add("absolute-host-path")
    if errors or not isinstance(report, dict):
        return sorted(errors)
    for key in ("started_utc", "finished_utc"):
        value = report["run"][key]
        try:
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})", value):
                raise ValueError("invalid timestamp")
            datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            errors.add("invalid-timestamp")
    if report["qualification_status"] != "PASS":
        return sorted(errors)
    checks = report.get("subchecks", [])
    if not checks or any(c["result"] != "pass" for c in checks):
        errors.add("pass-with-unproven-subchecks")
    if len({c["id"] for c in checks}) != len(checks):
        errors.add("duplicate-subcheck")
    if any(c["name"] == "bug_oops_panic_total" and c["value"] != 0 for c in report["counters"]):
        errors.add("pass-with-fault-counter")
    mode = {"COCO-1": "sev_snp", "COCO-2": "tdx_no_paravisor", "COCO-3": "arm_cca"}.get(report["row"])
    if mode and report["capability"]["isolation_mode"] != mode:
        errors.add("row-platform-mismatch")
    if not report["capability"]["vmbus_present"]:
        errors.add("pass-without-vmbus")
    return sorted(errors)


def self_test(schema):
    digest = "a" * 64
    report = {
        "schema": "ramshared-coco-result/v1",
        "run": {"run_id": "validator-fixture", "attempt": 1, "started_utc": "2026-10-04T00:00:00Z", "finished_utc": "2026-10-04T00:01:00Z", "executor": "fixture", "bundle_sha256": digest},
        "candidate": {"series_base": "a" * 40, "series_tip": "b" * 40, "cover_sha256": digest, "patch_sha256s": [digest] * 13, "series_sha256sums_ok": True, "architecture": "x86_64"},
        "row": "COCO-1",
        "capability": {"claimed_platform": "sev_snp", "isolation_mode": "sev_snp", "isolation_proof": ["synthetic fixture only"], "paravisor": "unknown", "paravisor_evidence": [], "vmbus_present": True, "preflight_report_path": "preflight.txt"},
        "infrastructure_status": "completed", "qualification_status": "PASS", "status_justification": "Validator fixture, never platform proof",
        "counters": [{"name": "bug_oops_panic_total", "phase": "after", "value": 0, "unit": "count", "source": "fixture"}],
        "subchecks": [{"id": "fixture", "description": "validator only", "result": "pass", "evidence": ["synthetic fixture"]}],
        "artifacts": [{"path": "preflight.txt", "sha256": digest, "kind": "preflight_report"}],
        "log_safety": {"kernel_virtual_addresses_stripped": True, "secrets_stripped": True, "attested_by": "fixture"},
    }
    cases = [
        ("valid_schema_fixture", lambda r: None, False),
        ("wrong_counter_type", lambda r: r["counters"][0].update(value="0"), True),
        ("missing_candidate", lambda r: r.pop("candidate"), True),
        ("not_run_cannot_pass", lambda r: r["subchecks"][0].update(result="not_run"), True),
        ("absent_subchecks_cannot_pass", lambda r: r.pop("subchecks"), True),
        ("row_platform_mismatch", lambda r: r.update(row="COCO-2"), True),
        ("nonzero_fault_not_hidden_by_zero", lambda r: r["counters"].append({**r["counters"][0], "phase": "during", "value": 1}), True),
        ("unfinished_evidence", lambda r: r.update(notes="TODO"), True),
        ("decoded_host_path_refused", lambda r: r.update(notes="/home/private/file"), True),
        ("invalid_timestamp", lambda r: r["run"].update(started_utc="yesterday"), True),
    ]
    for name, change, expected in cases:
        candidate = copy.deepcopy(report)
        change(candidate)
        assert bool(validate_report(candidate, schema)) == expected, name
        print("PASS", name)
    try:
        json.loads('{"schema":1,"schema":2}', object_pairs_hook=reject_duplicates)
        raise AssertionError("duplicate keys accepted")
    except ValueError:
        print("PASS duplicate_json_key_refused")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    schema = load_json(Path(__file__).with_name("coco-result.schema.json"))
    if args.self_test:
        self_test(schema)
        return 0
    if args.report is None:
        parser.error("report is required")
    try:
        errors = validate_report(load_json(args.report), schema)
    except (OSError, ValueError, RecursionError):
        errors = ["unreadable-or-invalid-json"]
    for code in errors:
        print("REFUSE", code)
    if not errors:
        print("PASS JSON Schema and report consistency; hardware evidence still requires review")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
