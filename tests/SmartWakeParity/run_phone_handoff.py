#!/usr/bin/env python3
"""Compile the production phone coordinator against effects-only test doubles."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    "Lights Timer/Models/DayOfWeek.swift",
    "Lights Timer/Models/LightSchedule.swift",
    "Lights Timer/Models/SmartWakeMessage.swift",
    "Lights Timer/Models/WatchScheduleSnapshot.swift",
    "Lights Timer/Services/SmartWakeCoordinator.swift",
    "tests/SmartWakeParity/PhoneHandoffChecks.swift",
]
REPORT = ROOT / "tests/SmartWakeParity/phone-handoff-proof.json"
HASHED_SOURCES = SOURCES + ["tests/SmartWakeParity/run_phone_handoff.py"]


def source_hashes():
    return {
        name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
        for name in HASHED_SOURCES
    }


before_hashes = source_hashes()
REPORT.unlink(missing_ok=True)

with tempfile.TemporaryDirectory(prefix="lights-phone-handoff-") as temporary:
    binary = str(Path(temporary) / "phone-handoff-checks")
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor",
        *[str(ROOT / name) for name in SOURCES], "-o", binary,
    ], check=True)
    result = subprocess.run([binary], check=True, text=True, capture_output=True)
    count = re.fullmatch(r"(\d+) phone coordinator integration checks passed", result.stdout.strip())
    if count is None:
        raise RuntimeError(f"Unexpected test result: {result.stdout!r}")
    if before_hashes != source_hashes():
        raise RuntimeError("Sources changed during validation; rerun to produce a consistent proof")
    report = {
        "suite": "production-phone-coordinator",
        "status": "passed",
        "checks": int(count.group(1)),
        "result": result.stdout.strip(),
        "source_sha256": before_hashes,
        "scope": "Actual production coordinator and SwiftData models compiled for native macOS; HomeKit execution, WatchConnectivity transport and logging replaced with test doubles. Does not validate device accessory writes or message delivery.",
    }
    REPORT.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
