#!/usr/bin/env python3
"""Run all original-instruction watch probes and assemble their evidence report."""
import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).parent
PROBES = [
    ('WatchMovementProbe.py', 'watch-movement-proof.json', 'comparisonsPassed'),
    ('WatchAlarmParameterProbe.py', 'watch-alarm-parameter-proof.json', 'checksPassed'),
    ('WatchAlarmRuleProbe.py', 'watch-alarm-rule-proof.json', 'casesPassed'),
    ('WatchArmedFilterProbe.py', 'watch-armed-filter-proof.json', 'casesPassed'),
    ('WatchHistoryCalibrationProbe.py', 'watch-history-calibration-proof.json', 'checksPassed'),
    ('WatchAlarmLifecycleProbe.py', 'watch-alarm-lifecycle-proof.json', 'casesPassed'),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--watch-binary', type=Path, required=True)
    parser.add_argument('--phone-binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'watch-proof.json')
    parser.add_argument('--merge-existing', action='store_true', help='Assemble existing reports without rerunning probes')
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    reports = {}
    checks = {}
    for script, report, key in PROBES:
        destination = args.output.parent / report
        if not args.merge_existing:
            command = [sys.executable, str(ROOT / script), '--watch-binary', str(args.watch_binary), '--output', str(destination)]
            if script == 'WatchMovementProbe.py':
                command.extend(['--phone-binary', str(args.phone_binary)])
            subprocess.run(command, check=True, env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        reports[script] = json.loads(destination.read_text())
        checks[script] = reports[script][key]
    sources = [s for s, _, _ in PROBES] + ['WatchAlgorithmReference.py', 'WatchProbeSupport.py', 'RunWatchProbes.py']
    result = {
        'app': 'Sleep Cycle 6.26.430 (28530)',
        'architectureExecuted': 'ARM64',
        'emulator': 'Unicorn 2.1.4',
        'scope': 'Original decrypted machine instructions with explicit platform/runtime shims, compared against independent behavioral reconstructions. No vendor binary bytes included in these files.',
        'totalComparisonChecksPassed': sum(checks.values()),
        'componentComparisonChecksPassed': checks,
        'countDefinition': 'Movement: 8 constructor cases x 2 binary/model comparisons plus 3209 samples x 2 comparisons (watch/phone parity and watch/reference). Other components count one comparison per case. Additional model-vs-saved-output checks are not added again.',
        'limitations': [
            'Not a complete app launch, overnight hardware validation, or clinical accuracy validation.',
            'ARM64_32 was statically cross-checked separately; these executable probes run ARM64.',
            'Synthetic finite motion, timestamps, Swift metadata, Foundation Date operations, object lifetimes and notification fixtures replace the platform environment.',
            'vDSP mean and libc exp use Python numerical equivalents; comparisons use the stated floating-point tolerance rather than claiming bit-identical platform math.',
            'The lifecycle probe executes the dispatcher, alarm decision, armed filter and runtime expiry predicate; its phase-change callback supplies phase state and previously selected calibration inputs. It does not execute historical mode/filter selection at 0x1000989f0.',
            'The history probe executes the rate calculation and recursive search; effective session end is supplied. Effective-end selection, calibration entry guards, D getter and recorder event binning are statically traced in the reference and specifications, not separately emulated by this suite.',
            'Alarm firing is observed at the callback boundary. Actual haptics, audio, runtime scheduling, expiration callbacks, OS recovery and HealthKit interfaces remain outside this suite.'
        ],
        'sourceSHA256': {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources},
        'reports': reports,
    }
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'totalComparisonChecksPassed': result['totalComparisonChecksPassed'], 'output': str(args.output)}))


if __name__ == '__main__':
    main()
