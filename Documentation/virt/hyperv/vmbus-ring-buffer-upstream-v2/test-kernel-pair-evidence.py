#!/usr/bin/env python3
"""Parser/refusal fixtures only; these tests are not kernel boot evidence."""
import copy
import importlib.util
import struct
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("collector", Path(__file__).with_name("collect-kernel-pair-evidence.py"))
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


def fixture():
    return {"schema": collector.SCHEMA, "scope": collector.SCOPE,
            "source_commit": "a" * 40, "captured_utc": "2026-10-05T00:00:00+00:00",
            "verdict": "PASS", "pair_id": "v1-" + "b" * 16 + "-" + "c" * 16,
            "boot_id": "11111111-1111-4111-8111-111111111111",
            "previous_boot_id": "22222222-2222-4222-8222-222222222222",
            "running_build_id": "d" * 40, "expected_build_id": "d" * 40,
            "kernel_release": "6.18.test", "kernel_log_sha256": "e" * 64,
            "kernel_fatals": 0, "module_loaded": False,
            "checks": {key: True for key in collector.CHECKS}}


class EvidenceTests(unittest.TestCase):
    def test_gnu_note_identity(self):
        note = struct.pack("<III", 4, 20, 3) + b"GNU\0" + b"x" * 20
        self.assertEqual(collector.build_id(note), (b"x" * 20).hex())
        for invalid in [note[:-1], note + note, note[:8]]:
            with self.assertRaises(ValueError):
                collector.build_id(invalid)

    def test_valid_fixture_and_honest_failure(self):
        report = fixture()
        collector.validate(report)
        report["checks"]["fresh_boot"] = False
        report["verdict"] = "FAIL"
        collector.validate(report)

    def test_contradictory_verdict_refused(self):
        report = fixture()
        report["checks"]["fresh_boot"] = False
        with self.assertRaises(ValueError):
            collector.validate(report)

    def test_invalid_scope_and_fields_refused(self):
        for mutate in [lambda r: r.update(scope="CoCo"),
                       lambda r: r.update(extra="unclassified"),
                       lambda r: r["checks"].pop("fresh_boot"),
                       lambda r: r["checks"].update(fresh_boot=1)]:
            report = copy.deepcopy(fixture())
            mutate(report)
            with self.assertRaises(ValueError):
                collector.validate(report)

    def test_identity_and_fatal_contradictions_refused(self):
        for key, value in [("kernel_fatals", 1), ("running_build_id", "f" * 40),
                           ("boot_id", fixture()["previous_boot_id"]),
                           ("kernel_log_sha256", "unavailable")]:
            report = fixture()
            report[key] = value
            with self.assertRaises(ValueError):
                collector.validate(report)

    def test_vermagic_whitespace_and_abi_identity(self):
        expected = "6.18.test SMP preempt mod_unload modversions "
        self.assertTrue(collector.vermagic_matches((expected + "\n").encode(), expected))
        self.assertTrue(collector.vermagic_matches(expected.rstrip().encode(), expected))
        for changed in [expected.replace("6.18", "6.19"),
                        expected.replace(" preempt", ""),
                        expected.replace(" modversions", "")]:
            self.assertFalse(collector.vermagic_matches(changed.encode(), expected))

    def test_duplicate_json_refused(self):
        with self.assertRaises(ValueError):
            collector.unique_object([("verdict", "PASS"), ("verdict", "FAIL")])


if __name__ == "__main__":
    unittest.main()
