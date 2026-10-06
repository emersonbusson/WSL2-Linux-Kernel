#!/usr/bin/env python3
"""Validate an operator's bounded-pressure summary, never a hosted boot claim."""
import json
import re
import sys
import datetime


def validate(report):
    fields = {"schema", "provenance", "verdict", "captured_utc", "kernel_notes_sha256", "source_commit", "source_tree_state", "release", "cli_sha256", "daemon_sha256", "boot_unchanged", "action_window", "rounds", "control_evidence_ok", "final_clean", "host_memory_gate_ok", "host_disk_telemetry_ok", "ghost", "vm_termination", "scope", "private_envelope_sha256"}
    if not isinstance(report, dict) or set(report) != fields:
        raise ValueError("missing_or_unknown_summary_field")
    if report.get("schema") != "ramshared.bounded-wsl-pressure.v1" or report.get("verdict") != "PASS_BOUNDED":
        raise ValueError("unsupported_bounded_pressure_summary")
    if report.get("provenance") != "operator execution; CI validation does not constitute hosted execution":
        raise ValueError("operator_provenance_missing")
    for key in ("boot_unchanged", "control_evidence_ok", "final_clean", "host_memory_gate_ok", "host_disk_telemetry_ok"):
        if report.get(key) is not True:
            raise ValueError("required_proof_missing:" + key)
    for key in ("ghost", "vm_termination"):
        if report.get(key) is not False:
            raise ValueError("unsafe_runtime_outcome:" + key)
    if report.get("source_tree_state") != "clean":
        raise ValueError("source_is_not_clean")
    for key, size in (("source_commit", 40), ("kernel_notes_sha256", 64), ("cli_sha256", 64), ("daemon_sha256", 64), ("private_envelope_sha256", 64)):
        if not isinstance(report.get(key), str) or not re.fullmatch("[0-9a-f]{" + str(size) + "}", report[key]):
            raise ValueError("invalid_identity:" + key)
    timestamp = datetime.datetime.fromisoformat(report["captured_utc"])
    if timestamp.utcoffset() != datetime.timedelta(0):
        raise ValueError("capture_timestamp_requires_utc")
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-g" + report["source_commit"][:8], report["release"]):
        raise ValueError("release_source_mismatch")
    window = report["action_window"]
    if not isinstance(window, dict) or set(window) != {"start_ms", "end_ms", "samples", "states", "measurement_errors"}:
        raise ValueError("invalid_window_fields")
    if type(window["start_ms"]) is not int or type(window["end_ms"]) is not int or not 0 < window["start_ms"] < window["end_ms"]:
        raise ValueError("invalid_action_window")
    states = window["states"]
    if not states or set(states) - {"HEALTHY", "GUARDED", "CRITICAL"}:
        raise ValueError("unqualified_control_state")
    if any(type(value) is not int or value < 0 for value in states.values()):
        raise ValueError("invalid_state_count")
    if type(window["samples"]) is not int or window["samples"] <= 0 or sum(states.values()) != window["samples"]:
        raise ValueError("inconsistent_sample_count")
    if type(window["measurement_errors"]) is not int or window["measurement_errors"] != 0:
        raise ValueError("measurement_errors_present")
    rounds = report["rounds"]
    if not isinstance(rounds, list) or len(rounds) != 2:
        raise ValueError("two_integrity_rounds_required")
    for row in rounds:
        if not isinstance(row, dict) or set(row) != {"allocated_mib", "checksum_after", "checksum_before", "pattern", "reason", "status", "verified_chunks"}:
            raise ValueError("invalid_integrity_fields")
        if row.get("status") != "PASS" or row.get("reason") != "checksum_match":
            raise ValueError("incomplete_integrity")
        for key in ("allocated_mib", "verified_chunks"):
            if type(row.get(key)) is not int or row[key] <= 0:
                raise ValueError("invalid_integrity_capacity")
        checksum = row.get("checksum_before")
        if not isinstance(checksum, str) or not re.fullmatch("[0-9a-f]{64}", checksum) or row.get("checksum_after") != checksum:
            raise ValueError("checksum_mismatch")
        if row["pattern"] != "repeated-sha256-v1" or row["verified_chunks"] * 32 != row["allocated_mib"]:
            raise ValueError("integrity_chunk_mismatch")
    if "no saturation, prolonged operation, full unload or CoCo qualification" not in report.get("scope", ""):
        raise ValueError("scope_disclosure_missing")


if __name__ == "__main__":
    try:
        with open(sys.argv[1], encoding="utf-8") as source:
            raw = source.read(65537)
        if len(raw.encode()) > 65536:
            raise ValueError("summary_too_large")
        validate(json.loads(raw))
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        sys.exit("bounded pressure summary rejected: " + str(error))
    print("BOUNDED_OPERATOR_PRESSURE_SUMMARY=PASS; HOSTED_EXECUTION=NOT_CLAIMED")
