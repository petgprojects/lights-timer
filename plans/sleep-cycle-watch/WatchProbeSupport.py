#!/usr/bin/env python3
"""External binary loading and common arguments; no vendor bytes are included."""
import argparse
import struct
from pathlib import Path


def read_arm64(path):
    """Accept a decrypted thin ARM64 Mach-O or select ARM64 from a universal file."""
    blob = Path(path).read_bytes()
    if blob[:4] == bytes.fromhex('cafebabe'):
        entries = [struct.unpack_from('>IIIII', blob, 8 + i * 20)
                   for i in range(struct.unpack_from('>I', blob, 4)[0])]
        entry = next((e for e in entries if e[0] == 0x100000c), None)
        if entry is None:
            raise ValueError('Universal binary has no ARM64 slice')
        blob = blob[entry[2]:entry[2] + entry[3]]
    if blob[:4] != bytes.fromhex('cffaedfe') or struct.unpack_from('<I', blob, 4)[0] != 0x100000c:
        raise ValueError('Expected a decrypted ARM64 Mach-O (or universal file containing it)')
    return blob


def probe_arguments(description, output_name, *, phone=False):
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument('--watch-binary', type=Path, required=True,
                        help='Decrypted SCWatchExtension, thin ARM64 or universal Mach-O')
    if phone:
        parser.add_argument('--phone-binary', type=Path, required=True,
                            help='Decrypted iPhone GMFoundation ARM64 Mach-O')
    parser.add_argument('--output', type=Path, default=Path(__file__).parent / output_name)
    return parser.parse_args()
