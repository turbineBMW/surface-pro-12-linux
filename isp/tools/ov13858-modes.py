"""Dump register tables from Windows ov13858.sys: 8-byte entries {u16 addr, u16 0, u32 val}.
Usage: ov13858-modes.py <ov13858.sys> [start-offset-hex ...]   (no offsets: find tables)"""
import struct, sys
d = open(sys.argv[1], 'rb').read()
ENTRY = 16  # {u32 1 (write), u16 addr, u16 0, u32 val, u32 0}
def entry(o):
    t, a, z, v, z2 = struct.unpack_from('<IHHII', d, o)
    return (a, v) if t == 1 and z == 0 and z2 == 0 and 0x100 <= a <= 0x7fff and v <= 0xff else None
def table_at(o):
    out = []
    while o + ENTRY <= len(d):
        e = entry(o)
        if e is None: break
        out.append(e); o += ENTRY
    return out
def find_tables():
    o, tabs = 0, []
    while o + ENTRY <= len(d):
        t = table_at(o)
        if len(t) >= 12:
            tabs.append((o, t)); o += ENTRY * len(t)
        else:
            o += 1
    return tabs
def summarize(t):
    r = dict(t)
    def pair(h): return (r.get(h, 0) << 8) | r.get(h + 1, 0)
    return dict(xs=pair(0x3800), ys=pair(0x3802), xe=pair(0x3804), ye=pair(0x3806),
                xout=pair(0x3808), yout=pair(0x380a), hts=pair(0x380c), vts=pair(0x380e),
                xoff=pair(0x3810), yoff=pair(0x3812), fmt1=r.get(0x3820), fmt2=r.get(0x3821),
                pll=(r.get(0x0300), r.get(0x0301), r.get(0x0302), r.get(0x0303), r.get(0x030a), r.get(0x030b)),
                n=len(t))
offs = [int(x, 16) for x in sys.argv[2:]]
tabs = [(o, table_at(o)) for o in offs] if offs else find_tables()
for o, t in tabs:
    print(hex(o), summarize(t))
    if offs:
        print(' '.join(f'{a:04x}={v:02x}' for a, v in t))
