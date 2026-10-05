#!/usr/bin/env python3
"""Read-only local WSL kernel-pair evidence; no CoCo or installation effect."""
import argparse
import datetime
import hashlib
import json
import os
import re
import struct
import subprocess
import tempfile
from pathlib import Path

SCHEMA = "ramshared.local-kernel-pair.v1"
SCOPE = "ordinary WSL2 operator observation; no CoCo qualification"
CHECKS = {"fresh_boot", "running_build_id", "kernel_release", "image_hash",
          "modules_hash", "configuration_pair", "module_file", "module_vermagic",
          "readable_kernel_log", "zero_kernel_fatals"}
FIELDS = {"schema", "scope", "source_commit", "captured_utc", "verdict",
          "pair_id", "boot_id", "previous_boot_id", "running_build_id",
          "expected_build_id", "kernel_release", "kernel_log_sha256",
          "kernel_fatals", "module_loaded", "checks"}


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def build_id(notes):
    offset, found = 0, []
    while offset < len(notes):
        if offset + 12 > len(notes):
            raise ValueError("truncated note header")
        names, size, kind = struct.unpack_from("<III", notes, offset)
        offset += 12
        name_end = offset + names
        data_start = offset + ((names + 3) & ~3)
        data_end = data_start + size
        end = data_start + ((size + 3) & ~3)
        if names > 256 or size > 65536 or end > len(notes):
            raise ValueError("invalid note extent")
        if notes[offset:name_end] == b"GNU\0" and kind == 3:
            if not 16 <= size <= 64:
                raise ValueError("invalid build ID size")
            found.append(notes[data_start:data_end].hex())
        offset = end
    if len(found) != 1:
        raise ValueError("missing or duplicate GNU build ID")
    return found[0]


def command(args):
    with tempfile.TemporaryFile() as output:
        subprocess.run(args, stdout=output, stderr=subprocess.DEVNULL,
                       timeout=15, check=True)
        if output.tell() > 16 * 1024 * 1024:
            raise ValueError("observation exceeds byte limit")
        output.seek(0)
        return output.read(16 * 1024 * 1024)


def key_values(text):
    result = {}
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if not separator or key in result:
            raise ValueError("malformed or duplicate manifest key")
        result[key] = value
    return result


def configuration_pair(path, kernel, modules):
    values = {"kernel": [], "kernelmodules": []}
    section = ""
    for line in Path(path).read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if line.startswith("["):
            section = line.lower()
        elif section == "[wsl2]" and not line.startswith(("#", ";")):
            key, sep, value = line.partition("=")
            if sep and key.strip().lower() in values:
                values[key.strip().lower()].append(value.strip())
    return values == {"kernel": [kernel], "kernelmodules": [modules]}


def observe(callback, fallback):
    try:
        return callback()
    except (OSError, ValueError, subprocess.SubprocessError):
        return fallback


def validate(report):
    if not isinstance(report, dict) or set(report) != FIELDS:
        raise ValueError("report fields differ from schema")
    if report["schema"] != SCHEMA or report["scope"] != SCOPE:
        raise ValueError("wrong schema or evidence scope")
    checks = report["checks"]
    if not isinstance(checks, dict) or set(checks) != CHECKS:
        raise ValueError("missing or unknown observation check")
    if any(type(value) is not bool for value in checks.values()):
        raise ValueError("observation checks must be booleans")
    if report["verdict"] != ("PASS" if all(checks.values()) else "FAIL"):
        raise ValueError("contradictory verdict")
    if not re.fullmatch(r"[0-9a-f]{40}", report["source_commit"]):
        raise ValueError("invalid source identity")
    if type(report["kernel_fatals"]) is not int or report["kernel_fatals"] < 0:
        raise ValueError("invalid fatal count")
    if type(report["module_loaded"]) is not bool:
        raise ValueError("invalid module load observation")
    for field in FIELDS - {"checks", "kernel_fatals", "module_loaded"}:
        if not isinstance(report[field], str) or len(report[field]) > 256:
            raise ValueError("invalid scalar field")
    if not re.fullmatch(r"v1-[0-9a-f]{16}-[0-9a-f]{16}", report["pair_id"]):
        raise ValueError("invalid pair identity")
    for field in ["boot_id", "previous_boot_id"]:
        if not re.fullmatch(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", report[field]):
            raise ValueError("invalid boot identity")
    for field in ["running_build_id", "expected_build_id"]:
        if not re.fullmatch(r"(?:[0-9a-f]{2}){16,64}", report[field]) and not (
                field == "running_build_id" and report[field] == "unavailable" and
                not checks["running_build_id"]):
            raise ValueError("invalid build identity")
    timestamp = datetime.datetime.fromisoformat(report["captured_utc"])
    if timestamp.utcoffset() != datetime.timedelta(0):
        raise ValueError("capture timestamp must be UTC")
    if not re.fullmatch(r"[0-9A-Za-z._+-]{1,128}", report["kernel_release"]):
        raise ValueError("invalid kernel release")
    digest = report["kernel_log_sha256"]
    if digest != "unavailable" and not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("invalid log digest")
    if checks["readable_kernel_log"] != bool(re.fullmatch(r"[0-9a-f]{64}", digest)):
        raise ValueError("log digest contradicts readability")
    if checks["zero_kernel_fatals"] != (report["kernel_fatals"] == 0):
        raise ValueError("fatal count contradicts check")
    if checks["running_build_id"] and (not report["running_build_id"] or
            report["running_build_id"] != report["expected_build_id"]):
        raise ValueError("build ID contradicts check")
    if checks["fresh_boot"] and (not report["boot_id"] or
            report["boot_id"] == report["previous_boot_id"]):
        raise ValueError("boot ID contradicts check")
    return report


def collect(args):
    manifest = key_values(Path(args.manifest).read_text())
    if manifest.get("schema") != "ramshared.kernel-pair.v1":
        raise ValueError("wrong pair manifest schema")
    root = Path(args.manifest).resolve().parent
    for key, name in [("kernel_file", "kernel.bzImage"),
                      ("modules_file", "modules.vhdx")]:
        if manifest.get(key) != name:
            raise ValueError("unexpected artifact basename")
    release = os.uname().release
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    actual_id = observe(lambda: build_id(Path("/sys/kernel/notes").read_bytes()), "unavailable")
    module = observe(lambda: command(["modinfo", "-n", "uio_hv_generic"]).decode().strip(), "")
    log = observe(lambda: command(["dmesg", "--color=never", "--buffer-size", "16777216"]), None)
    fatals = len(re.findall(rb"(?im)BUG:|Oops:|kernel panic|general protection fault|Unable to handle kernel", log or b""))
    checks = {
        "fresh_boot": bool(boot and boot != args.previous_boot_id),
        "running_build_id": actual_id == args.expected_build_id,
        "kernel_release": release == manifest["release"],
        "image_hash": observe(lambda: sha256(root / "kernel.bzImage"), "") == manifest["kernel_sha256"],
        "modules_hash": observe(lambda: sha256(root / "modules.vhdx"), "") == manifest["modules_sha256"],
        "configuration_pair": observe(lambda: configuration_pair(args.wslconfig, args.windows_kernel, args.windows_modules), False),
        "module_file": bool(module) and observe(lambda: sha256(module), "") == args.module_sha256,
        "module_vermagic": observe(lambda: vermagic_matches(command(["modinfo", "-F", "vermagic", "uio_hv_generic"]), manifest["module_vermagic"]), False),
        "readable_kernel_log": log is not None,
        "zero_kernel_fatals": fatals == 0,
    }
    return validate({
        "schema": SCHEMA, "scope": SCOPE, "source_commit": args.source_commit,
        "captured_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "verdict": "PASS" if all(checks.values()) else "FAIL",
        "pair_id": manifest["pair_id"], "boot_id": boot,
        "previous_boot_id": args.previous_boot_id, "running_build_id": actual_id,
        "expected_build_id": args.expected_build_id, "kernel_release": release,
        "kernel_log_sha256": hashlib.sha256(log).hexdigest() if log is not None else "unavailable",
        "kernel_fatals": fatals, "module_loaded": Path("/sys/module/uio_hv_generic").exists(),
        "checks": checks,
    })


def vermagic_matches(raw, expected):
    return raw.decode().strip() == expected.strip()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate", type=Path)
    for name in ["manifest", "previous-boot-id", "expected-build-id", "source-commit",
                 "module-sha256", "wslconfig", "windows-kernel", "windows-modules"]:
        parser.add_argument("--" + name)
    args = parser.parse_args()
    if args.validate:
        if args.validate.stat().st_size > 65536:
            raise ValueError("report size limit")
        report = validate(json.loads(args.validate.read_text(), object_pairs_hook=unique_object))
        print("REPORT_VALIDATION=PASS runtime_verdict=" + report["verdict"])
        return 0
    if any(value is None for key, value in vars(args).items() if key != "validate"):
        parser.error("collection requires every observation argument")
    report = collect(args)
    print(json.dumps(report, sort_keys=True, indent=2))
    return 0 if report["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
