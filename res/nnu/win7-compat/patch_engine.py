"""Redirect this exact Win7 engine's BoringSSL entropy loader to its CNG adapter."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

ORIGINAL_SHA256 = '295d3767a5e5c4017f4877e67a4a8926178ecdfbb1196c3bd21ec5f5097f5ed3'
STRING_RVA = 0xe35ed0
ORIGINAL_NAME = 'bcryptprimitives'
ADAPTER_NAME = 'nnu_win7_rng.dll'


def patch(source, destination):
    raw = source.read_bytes()
    if hashlib.sha256(raw).hexdigest() != ORIGINAL_SHA256:
        raise ValueError('Engine does not match the verified Win7 build; refusing patch')
    nt = struct.unpack_from('<I', raw, 0x3c)[0]
    if raw[nt:nt+4] != b'PE\0\0' or struct.unpack_from('<H',raw,nt+4)[0] != 0x8664:
        raise ValueError('Expected x64 PE engine')
    sections = struct.unpack_from('<H',raw,nt+6)[0]
    table = nt + 24 + struct.unpack_from('<H',raw,nt+20)[0]
    offset = None
    for index in range(sections):
        entry = table + index * 40
        virtual_size, rva, size, position = struct.unpack_from('<IIII',raw,entry+8)
        if rva <= STRING_RVA < rva + min(virtual_size, size):
            offset = position + STRING_RVA - rva
            break
    before = (ORIGINAL_NAME + '\0').encode('utf-16le')
    after = (ADAPTER_NAME + '\0').encode('utf-16le').ljust(len(before), b'\0')
    if offset is None or raw[offset:offset+len(before)] != before or len(after) != len(before):
        raise ValueError('Expected entropy loader name not found at verified RVA')
    result = raw[:offset] + after + raw[offset+len(before):]
    destination.write_bytes(result)
    return dict(original_sha256=ORIGINAL_SHA256,
                patched_sha256=hashlib.sha256(result).hexdigest(),
                file_offset=offset, rva=STRING_RVA, before=ORIGINAL_NAME, after=ADAPTER_NAME,
                bytes_outside_loader_name_unchanged=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    print(json.dumps(patch(args.source,args.destination),indent=2))
