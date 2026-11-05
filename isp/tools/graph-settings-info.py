import struct, sys, collections
for p in sys.argv[1:]:
    d = open(p,'rb').read()
    isSap, common, nres, nsm = struct.unpack_from('<4I', d, 0)
    pins = struct.unpack_from('<5I', d, 16)
    table = 16 + 20 + 16*sum(pins)
    count, = struct.unpack_from('<I', d, table)
    off = table + 4 + 8*count
    nzoom, = struct.unpack_from('<I', d, off); off += 4 + 8*nzoom
    hdr = off; HS = 116
    sm = hdr + HS*nres
    print("==", p.split('/')[-1], "nres", nres, "sensor modes", nsm, [struct.unpack_from('<8H', d, sm+16*i) for i in range(nsm)])
    pinres = collections.Counter(); keys = collections.Counter(); attrs = collections.Counter()
    for i in range(nres):
        w = struct.unpack_from('<23I', d, hdr+HS*i)
        fps, attr = w[0], w[1]; attrs[attr]+=1
        streams = [tuple(w[2+3*k:5+3*k]) for k in range(7)]
        keys[(fps,)+tuple(s[:2] for s in streams if s[0])] += 1
    print("  attributes:", dict(attrs))
    print("  distinct fps:", sorted({k[0] for k in keys}))
    sizes = collections.Counter()
    for k in keys:
        for s in k[1:]: sizes[s]+=1
    print("  output sizes:", sorted(sizes))
    print("  pin table (first 6):", [(d[16+20+16*i:16+20+16*i+4], struct.unpack_from('<3I', d, 16+20+16*i+4)) for i in range(6)])
