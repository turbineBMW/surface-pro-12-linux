#!/usr/bin/env python3
"""List LimineCrumb values, oldest first, from a QEMU vars.fd (EDK2 keeps old copies)."""
import struct, sys
d = open(sys.argv[1], 'rb').read()
name = 'LimineCrumb'.encode('utf-16-le') + b'\0\0'
vals, i = [], d.find(name)
while i != -1:
    vals.append(struct.unpack_from('<I', d, i + len(name))[0])
    i = d.find(name, i + 1)
print(' '.join(map(str, vals)) or 'none')
