#!/usr/bin/env python3
"""Decode LimineMemDbg records: from efivarfs (skips 4-byte attribute prefix)
or from a QEMU vars.fd (every stored copy, oldest first)."""
import struct, sys
FMT = '<IIII' + 'Q' * 10
SIZE = struct.calcsize(FMT)
NAMES = ('stage writes map_entries conv_regions conv_pages claim_calls claim_fails '
         'first_fail_base first_fail_pages first_fail_status last_base last_pages '
         'chunk_pages usec').split()

def show(buf):
    r = dict(zip(NAMES, struct.unpack(FMT, buf[:SIZE])))
    hx = {'first_fail_base', 'first_fail_status', 'last_base'}
    print('  ' + ' '.join(f"{k}={r[k]:#x}" if k in hx else f"{k}={r[k]}" for k in NAMES))

p = sys.argv[1]
d = open(p, 'rb').read()
if '/efivars/' in p:
    show(d[4:])
else:
    name = 'LimineMemDbg'.encode('utf-16-le') + b'\0\0'
    i = d.find(name)
    while i != -1:
        show(d[i + len(name):])
        i = d.find(name, i + 1)
