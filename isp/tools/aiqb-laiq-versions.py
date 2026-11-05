import struct, sys
def laiq(d):
    off = 0x18
    while off + 16 <= len(d) and d[off:off+4].isalpha():
        size = struct.unpack_from('<I', d, off+4)[0]
        if d[off:off+4] == b'LAIQ': return off, size
        off += size
    return None
for p in sys.argv[1:]:
    d = open(p,'rb').read()
    secs = []
    off = 0x18
    while off + 16 <= len(d) and d[off:off+4].isalpha():
        secs.append(d[off:off+4].decode()); off += struct.unpack_from('<I', d, off+4)[0]
    r = laiq(d)
    out = {}
    if r:
        sec, size = r; b = sec+16; bsize = struct.unpack_from('<I', d, b+4)[0]
        pay, end = b+40, b+bsize
        while pay + 8 <= end:
            rsize, ver, alg = struct.unpack_from('<IHH', d, pay); out[alg] = ver; pay += rsize
    print(p.split('/')[-1], len(d), d[:4], secs, {hex(k): v for k, v in sorted(out.items())})
