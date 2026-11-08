#!/usr/bin/env python3
"""Compare recovered pages with the original Mach-O's pre-encryption hashes.

This checks embedded page hashes, not Apple's CMS certificate chain. It never
prints license records, keys, or recovered code. Both thin and FAT inputs work.
"""
import argparse
import hashlib
import json
import struct
import zipfile
from pathlib import Path


def unpack(fmt, data, offset):
    return struct.unpack_from(fmt, data, offset)


def slices(data):
    magic = unpack('>I', data, 0)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        count = unpack('>I', data, 4)[0]
        assert count < 100
        for i in range(count):
            if magic == 0xCAFEBABE:
                cpu, sub, offset, size, _ = unpack('>IIIII', data, 8 + 20 * i)
            else:
                cpu, sub, offset, size, _, _ = unpack('>IIQQII', data, 8 + 32 * i)
            yield (cpu, sub), data[offset:offset + size]
    else:
        cpu, sub = unpack('<II', data, 4)
        yield (cpu, sub), data


def metadata(data):
    magic = unpack('<I', data, 0)[0]
    assert magic in (0xFEEDFACE, 0xFEEDFACF)
    cursor = 32 if magic == 0xFEEDFACF else 28
    count = unpack('<I', data, 16)[0]
    encryption = None
    signature = None
    for _ in range(count):
        cmd, size = unpack('<II', data, cursor)
        assert size >= 8 and cursor + size <= len(data)
        if cmd in (0x21, 0x2C):
            encryption = unpack('<III', data, cursor + 8)
        if cmd == 0x1D:
            signature = unpack('<II', data, cursor + 8)
        cursor += size
    return encryption, signature


def code_directories(data, signature):
    offset, length = signature
    blob = data[offset:offset + length]
    magic, total, count = unpack('>III', blob, 0)
    assert magic == 0xFADE0CC0 and total <= len(blob) and count < 100
    for i in range(count):
        slot, pos = unpack('>II', blob, 12 + 8 * i)
        magic, size = unpack('>II', blob, pos)
        if magic == 0xFADE0C02:
            yield slot, blob[pos:pos + size]


def verify(original, recovered):
    output = []
    recovered_slices = dict(slices(recovered))
    for architecture, data in slices(original):
        enc, signature = metadata(data)
        if enc is None or enc[2] == 0:
            continue
        offset, size, cryptid = enc
        result = {'cpuType': hex(architecture[0]), 'cpuSubtype': hex(architecture[1]),
                  'cryptoff': offset, 'cryptsize': size, 'originalCryptid': cryptid}
        new = recovered_slices[architecture]
        new_enc, _ = metadata(new)
        assert new_enc[:2] == enc[:2]
        result['recoveredCryptid'] = new_enc[2]
        result['encryptedRegionSHA256'] = hashlib.sha256(data[offset:offset + size]).hexdigest()
        result['recoveredRegionSHA256'] = hashlib.sha256(new[offset:offset + size]).hexdigest()
        tables = []
        for slot, cd in code_directories(data, signature):
            version = unpack('>I', cd, 8)[0]
            if version < 0x20500:
                continue
            pre_hash_offset = unpack('>I', cd, 92)[0]
            if not pre_hash_offset:
                continue
            count, limit = unpack('>II', cd, 28)
            hash_size, hash_type, _, shift = unpack('>BBBB', cd, 36)
            if version >= 0x20300:
                limit64 = unpack('>Q', cd, 56)[0]
                if limit64:
                    limit = limit64
            assert shift < 32 and shift != 0
            page = 1 << shift
            assert pre_hash_offset + count * hash_size <= len(cd)
            hash_name = {1: 'sha1', 2: 'sha256', 3: 'sha256', 4: 'sha384'}[hash_type]
            checked = 0
            mismatches = []
            for index in range(offset // page, (offset + size + page - 1) // page):
                assert index < count
                expected = cd[pre_hash_offset + index * hash_size:pre_hash_offset + (index + 1) * hash_size]
                actual = hashlib.new(hash_name, new[index * page:min((index + 1) * page, limit)]).digest()[:hash_size]
                checked += 1
                if actual != expected:
                    mismatches.append(index)
            tables.append({'slot': slot, 'version': hex(version), 'pageBytes': page,
                           'hashType': hash_type, 'protectedPagesChecked': checked,
                           'mismatchedPageIndices': mismatches})
        result['preEncryptionHashTables'] = tables
        result['verified'] = bool(tables) and new_enc[2] == 0 and all(not t['mismatchedPageIndices'] for t in tables)
        output.append(result)
    return {'scope': 'Original embedded pre-encryption page hashes; CMS chain not evaluated.',
            'slices': output, 'allEncryptedSlicesVerified': bool(output) and all(x['verified'] for x in output)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('member')
    parser.add_argument('recovered', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    with zipfile.ZipFile(args.ipa) as archive:
        result = verify(archive.read(args.member), args.recovered.read_bytes())
    formatted = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(formatted)
    print(formatted, end='')
