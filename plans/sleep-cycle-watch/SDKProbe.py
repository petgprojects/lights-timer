#!/usr/bin/env python3
"""Inspect the matching public SDK and emulate three pure ARM64 math routines.

Usage: python SDKProbe.py /path/to/ios-arm64/SleepCycleSDK.framework/SleepCycleSDK
Requires the `unicorn` Python package. Does not load the SDK or contact its API.
This verifies SDK arithmetic, not the encrypted watch app or sleep accuracy.
"""

import hashlib
import json
from pathlib import Path
import struct
import sys

from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM
from unicorn.arm64_const import (
    UC_ARM64_REG_D0, UC_ARM64_REG_D1, UC_ARM64_REG_D2,
    UC_ARM64_REG_LR, UC_ARM64_REG_PC, UC_ARM64_REG_SP,
    UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X20,
)


EXPECTED_HASH = "81779e6e6be6b5b1752875e63bd4ac158db0463f2be51bf67bddd7a1ab7b0379"
CODE_BASE = 0x10000000
DATA_BASE = 0x20000000
STACK_BASE = 0x30000000
RETURN_ADDRESS = CODE_BASE + 0x1F0000


def double_bits(value):
    return struct.unpack("<Q", struct.pack("<d", value))[0]


def bits_double(value):
    return struct.unpack("<d", struct.pack("<Q", value))[0]


def ease_in_out(progress):
    t = max(0.0, min(1.0, progress))
    return 2.0 * t * t if t < 0.5 else -1.0 + 4.0 * t - 2.0 * t * t


def check_close(actual, expected):
    if abs(actual - expected) > 1e-12:
        raise AssertionError((actual, expected))


def main(path):
    blob = Path(path).read_bytes()
    digest = hashlib.sha256(blob).hexdigest()
    if digest != EXPECTED_HASH:
        raise ValueError("This probe is specific to the verified SDK 1.5.2 iOS arm64 binary.")

    cpu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    cpu.mem_map(CODE_BASE, 0x200000)
    cpu.mem_write(CODE_BASE, blob)
    cpu.mem_map(DATA_BASE, 0x1000)
    cpu.mem_map(STACK_BASE, 0x10000)

    def run(address, arguments, x0=3, result_register=UC_ARM64_REG_D0):
        cpu.reg_write(UC_ARM64_REG_SP, STACK_BASE + 0x8000)
        cpu.reg_write(UC_ARM64_REG_LR, RETURN_ADDRESS)
        cpu.reg_write(UC_ARM64_REG_X0, x0)
        cpu.reg_write(UC_ARM64_REG_X1, 0)
        cpu.reg_write(UC_ARM64_REG_X20, DATA_BASE)
        for register, value in zip((UC_ARM64_REG_D0, UC_ARM64_REG_D1, UC_ARM64_REG_D2), arguments):
            cpu.reg_write(register, double_bits(value))
        cpu.emu_start(CODE_BASE + address, RETURN_ADDRESS, count=1000)
        if cpu.reg_read(UC_ARM64_REG_PC) != RETURN_ADDRESS:
            raise AssertionError("Instruction budget reached without returning")
        return bits_double(cpu.reg_read(result_register))

    interpolation_cases = 0
    for t in [-0.5] + [i / 100 for i in range(101)] + [1.5]:
        # d0=end, d1=progress, d2=start, x0=curve enum (3 = ease in/out).
        actual = run(0xF3CB4, [5.0, t, 20.0])
        check_close(actual, 20.0 - 15.0 * ease_in_out(t))
        interpolation_cases += 1

    # SmartAlarmTrigger layout: start/end shift, upper/lower threshold,
    # optional large-movement range (two doubles plus discriminator).
    # These 20/5 thresholds are controlled inputs, not universal SDK defaults.
    cpu.mem_write(DATA_BASE, struct.pack("<6dB", 0.3, 1.0, 20.0, 5.0, 5.0, 20.0, 0))
    large_movement_cases = []
    for p in [0.0, 0.3, 0.475, 0.65, 0.825, 1.0, 1.2]:
        actual = run(0xFE818, [p])
        t = max(0.0, min(1.0, (p - 0.3) / 0.7))
        check_close(actual, 5.0 + 15.0 * ease_in_out(1.0 - t))
        large_movement_cases.append({"windowFraction": p, "instructionResult": actual})
    cpu.mem_write(DATA_BASE + 0x30, b"\x01")
    check_close(run(0xFE818, [0.7]), 10.0)

    # Swift native array representation for the allocation-free percentile helper.
    values = [float(i) for i in range(1, 11)]
    cpu.mem_write(DATA_BASE, struct.pack("<4Q10d", 0, 0, len(values), 20, *values))
    quantiles = []
    for p in [0.0, 0.5, 0.7, 0.9, 1.0]:
        actual = run(0xFE95C, [p], x0=DATA_BASE, result_register=UC_ARM64_REG_X0)
        expected = values[min(len(values) - 1, int(p * len(values)))]
        check_close(actual, expected)
        if cpu.reg_read(UC_ARM64_REG_X1) != 0:
            raise AssertionError("Unexpected nil percentile")
        quantiles.append({"fraction": p, "instructionResult": actual})

    coefficients = [struct.unpack_from("<5d", blob, address) for address in (0x160438, 0x160460)]
    result = {
        "binarySHA256": digest,
        "scope": "Pure SDK arithmetic executed in an ARM64 emulator; no watch code executed.",
        "interpolation": {"address": "0xF3CB4", "casesPassed": interpolation_cases},
        "largeMovementThreshold": {"address": "0xFE818", "cases": large_movement_cases, "missingRangeResult": 10.0},
        "percentile": {"address": "0xFE95C", "cases": quantiles},
        "biquadCoefficients_b0_b1_b2_a1_a2": coefficients,
        "constructorConstants": {
            "internalSamplingHz": 40.0, "gridStepSeconds": 0.025,
            "thresholdMultiplier": 6.0, "holdMultiplier": 1.5,
            "minimumEventSeconds": 0.6, "envelopeSeconds": 0.15,
            "noiseWindowSeconds": 120.0, "noiseSamplingHz": 10.0,
            "noiseUpdateSeconds": 0.5, "warmupSeconds": 10.0,
            "gapResetSeconds": 1.0, "maximumGapWithinEventSeconds": 1.0,
            "maximumEventSeconds": 30.0, "minimumIntervalBetweenEventsSeconds": 0.0,
        },
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main(sys.argv[1])
