#!/usr/bin/env python3
"""Print PE DllCharacteristics (NX_COMPAT) and section permissions of EFI images."""
import struct, sys

for p in sys.argv[1:]:
    d = open(p, 'rb').read()
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    nsec, = struct.unpack_from('<H', d, pe + 6)
    optsz, = struct.unpack_from('<H', d, pe + 20)
    o = pe + 24
    salign, = struct.unpack_from('<I', d, o + 32)
    dll, = struct.unpack_from('<H', d, o + 70)
    print(f"{p}\n  SectionAlignment=0x{salign:x} DllCharacteristics=0x{dll:04x} "
          f"NX_COMPAT={'yes' if dll & 0x100 else 'NO'} DYNAMIC_BASE={'yes' if dll & 0x40 else 'no'}")
    s = o + optsz
    for _ in range(nsec):
        name = d[s:s + 8].rstrip(b'\0').decode(errors='replace')
        vs, va = struct.unpack_from('<II', d, s + 8)
        ch, = struct.unpack_from('<I', d, s + 36)
        w, x = bool(ch & 0x80000000), bool(ch & 0x20000000)
        flags = ('R' if ch & 0x40000000 else '-') + ('W' if w else '-') + ('X' if x else '-')
        note = ('  <-- W+X' if w and x else '') + ('  <-- not 4K aligned' if va % 4096 else '')
        print(f"   {name:10} va=0x{va:08x} size=0x{vs:08x} {flags}{note}")
        s += 40
