#!/usr/bin/env python3
"""Counterexamples for bounded operator evidence; no hardware is exercised."""
import importlib.util
import json
from pathlib import Path
import unittest

root = Path(__file__).parent
spec = importlib.util.spec_from_file_location("summary_validator", root / "validate-local-pressure.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.report = json.loads((root / "local-pressure-summary.json").read_text())

    def test_actual_summary_acceptance_and_all_disclosures(self):
        validator.validate(self.report)

    def test_false_or_mistyped_proofs_are_refused(self):
        for field in ("boot_unchanged", "control_evidence_ok", "final_clean", "host_memory_gate_ok", "host_disk_telemetry_ok"):
            for value in (False, "true", 1, None):
                with self.subTest(field=field, value=value):
                    candidate = dict(self.report); candidate[field] = value
                    with self.assertRaises(ValueError): validator.validate(candidate)

    def test_unqualified_runtime_missing_and_extra_fields_refuse(self):
        for field, value in (("ghost", True), ("vm_termination", True), ("source_tree_state", "dirty"),
                             ("provenance", "hosted execution"), ("scope", "CoCo PASS"),
                             ("release", "v0.14.1-620-gffffffff"), ("cli_sha256", "invalid")):
            candidate = dict(self.report); candidate[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): validator.validate(candidate)
        candidate = dict(self.report); candidate["coco_pass"] = True
        with self.assertRaises(ValueError): validator.validate(candidate)
        candidate = dict(self.report); candidate.pop("private_envelope_sha256")
        with self.assertRaises(ValueError): validator.validate(candidate)

    def test_window_and_integrity_mutations_refuse(self):
        mutations = [
            lambda r: r["action_window"].update(measurement_errors=1),
            lambda r: r["action_window"]["states"].update(EMERGENCY=1),
            lambda r: r["action_window"].update(samples=0),
            lambda r: r["action_window"].update(end_ms=0),
            lambda r: r["rounds"].pop(),
            lambda r: r["rounds"][0].update(status="PARTIAL"),
            lambda r: r["rounds"][0].update(checksum_after="f" * 64),
            lambda r: r["rounds"][0].update(verified_chunks=0),
            lambda r: r["rounds"][0].update(allocated_mib=True),
        ]
        for mutation in mutations:
            candidate = json.loads(json.dumps(self.report)); mutation(candidate)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError): validator.validate(candidate)


if __name__ == "__main__": unittest.main()
