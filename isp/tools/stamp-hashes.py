"""Stamp a Windows IPU75XA graph settings file (layout of ipu7-camera-hal e5172cc)
with that release's hash codes. Based on Marco Glauser's patch-hashes.py.

Usage: stamp-hashes.py <windows .bin> <out .bin>
"""
import struct, sys

COMMON = 1110027246
GRAPHS = {100002: 2257098455, 100003: 835453801, 100026: 4190204929}
HEADER_SIZE = 116

d = bytearray(open(sys.argv[1], 'rb').read())
_, old_common, nres, nsm = struct.unpack_from('<4I', d, 0)
struct.pack_into('<I', d, 4, COMMON)
pins = struct.unpack_from('<5I', d, 16)
table = 16 + 20 + 16 * sum(pins)
count, = struct.unpack_from('<I', d, table)
seen = {}
for i in range(count):
    graph, old = struct.unpack_from('<2I', d, table + 4 + 8 * i)
    struct.pack_into('<I', d, table + 8 + 8 * i, GRAPHS[graph])
    seen[graph] = old
off = table + 4 + 8 * count
nzoom, = struct.unpack_from('<I', d, off)
headers = off + 4 + 8 * nzoom
for i in range(nres):
    b = headers + HEADER_SIZE * i
    graph, = struct.unpack_from('<i', d, b + 100)
    old, = struct.unpack_from('<I', d, b + 112)
    assert old == seen[graph], (i, graph, old)
    struct.pack_into('<I', d, b + 112, GRAPHS[graph])
open(sys.argv[2], 'wb').write(d)
print(f"{sys.argv[2]}: common {old_common}->{COMMON}, {nres} headers, graphs {seen}")
