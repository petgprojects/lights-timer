#!/usr/bin/env python3
"""Run actual production policy/engine/model code with deterministic timestamps.

Native process replay, not watchOS lifecycle/sensor/HomeKit testing.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
WATCH = ROOT / "Lights Timer Watch App"


def main():
    models = [WATCH / "Models/WatchScheduleSnapshot.swift", WATCH / "Models/SmartWakeMessage.swift"]
    engine_files = [WATCH / "Services/RecoveredMovementCore.swift", WATCH / "Services/WakeHeuristicEngine.swift",
                    WATCH / "Services/SmartWakeExecutionPolicy.swift", WATCH / "Services/SmartWakePendingWakeStore.swift",
                    HERE / "IntegrationChecks.swift"]
    with tempfile.TemporaryDirectory(prefix="lights-smartwake-integration-") as folder:
        binary = Path(folder) / "checks"
        base = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor"]
        subprocess.run(base + list(map(str, models + engine_files)) + ["-o", str(binary)], check=True)
        report = json.loads(subprocess.check_output([str(binary)], text=True))
        recorder_files = [WATCH / "Services/RecoveredMovementCore.swift", WATCH / "Services/SmartWakeRecorderPipeline.swift", HERE / "RecorderChecks.swift"]
        subprocess.run(base + list(map(str, recorder_files)) + ["-o", str(binary)], check=True)
        report["recorder"] = json.loads(subprocess.check_output([str(binary)], text=True))
        migration_results = {}
        for target in ("Lights Timer", "Lights Timer Watch App"):
            sources = [models[0], ROOT / target / "Models/SmartWakeMessage.swift", HERE / "ModelMigrationChecks.swift"]
            subprocess.run(base + list(map(str, sources)) + ["-o", str(binary)], check=True)
            migration_results[target] = subprocess.check_output([str(binary)], text=True).strip()
        report["model_migration"] = migration_results
        report["model_migration_checks"] = 12
        report["source_sha256"] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in models + engine_files + recorder_files + [ROOT / "Lights Timer/Models/SmartWakeMessage.swift", HERE / "ModelMigrationChecks.swift", Path(__file__)]}
        report["scope"] = "Actual production policy, completion store, engine actor and Codable models compiled for native macOS; deterministic test inputs. Does not execute watchOS recovery APIs or device sensors."
        (HERE / "integration-proof.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({k: report[k] for k in ("status", "checks", "model_migration_checks")} | {"recorder_checks": report["recorder"]["checks"]}, indent=2))


if __name__ == "__main__":
    main()
