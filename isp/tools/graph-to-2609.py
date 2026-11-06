"""Convert an IPU75XA graph settings file from the layout of ipu7-camera-hal
e5172cc (2025-12-10) to that of 30ad691 (2026-09-26).

Input: a file already stamped and linuxized for e5172cc (stamp-hashes.py, then
linuxize-100002), i.e. what sp12-camera-hal ships today. Only graphs 100002,
100003 and 100026 are handled (all the Surface Pro 12 files use).

What changed between the releases (sizes from offsetof/sizeof of both HALs'
headers, values from Intel's own 2026-09 OV13B10/OV08X40 graphs):
  - BinaryHeader 16 -> 40 bytes: additionalFeaturesBit after sapAttributes,
    then a GSF timestamp and tool version (left zero) after the counts.
  - GraphConfigurationHeader 116 -> 120: isIsysUnpacked (u8, 3 pad) after
    additionalFeaturesBit. Intel's Linux graphs set it to 1 (the in-tree ISYS
    writes unpacked lines; nothing in the HAL reads it yet).
  - Every GraphConfiguration gains int32 numberOfActualLinks before its link
    array (Intel's files hold the array length).
  - LBFF system APIs: bxt_blc 5 -> 6 bytes (u16 uuid 12306 -> 9649, u16 0,
    dol_processing, + is_4_cell = 0) and b2i_ds_1_1 5 -> 12 bytes (uuid 2102 ->
    51813, u16 0, is_striping, 3 pad, int32 scaling_ratio = 0: the HAL fills it).
  - Common hash and per-graph hashes.

Usage: graph-to-2609.py <in.bin> <out.bin>
"""
import struct
import sys

COMMON = 929000173
HASH = {100002: 4223092366, 100003: 198891660, 100026: 3485835604}

# LBFF system API entry sizes in kernel order (e5172cc); the GMV variant
# appends ifd_gmv, gmv_statistics, odr_gmv_match, odr_gmv_feature.
LBFF_OLD = [156, 5, 5, 156, 40, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 24, 5, 20, 5, 0,
            156, 0, 156, 156, 156, 156, 24, 156, 156]
GMV_OLD = LBFF_OLD + [156, 0, 156, 156]
BXT_BLC, B2I_DS = 1, 20  # indices in the kernel lists


def convert_api(old, sizes, new_len):
    out = bytearray()
    o = 0
    for k, s in enumerate(sizes):
        e = old[o:o + s]
        o += s
        if k == BXT_BLC:
            uuid, z, dol = struct.unpack('<HHB', e)
            assert uuid == 12306 and z == 0, ('bxt_blc', uuid, z)
            e = struct.pack('<HHBB', 9649, 0, dol, 0)
        elif k == B2I_DS:
            uuid, z, striping = struct.unpack('<HHB', e)
            assert uuid == 2102 and z == 0, ('b2i_ds', uuid, z)
            e = struct.pack('<HHB3xi', 51813, 0, striping, 0)
        out += e
    assert o == len(old), (o, len(old))
    assert len(out) == new_len, (len(out), new_len)
    return bytes(out)


def convert_lbff(old, old_size, new_size, api_off, sizes):
    old_api = old[api_off:api_off + sum(sizes)]
    new_api_len = sum(sizes) + 8
    node = old[:api_off] + convert_api(old_api, sizes, new_api_len)
    return node + bytes(new_size - len(node))


def convert_block(gid, b):
    if gid == 100002:
        assert len(b) == 5440
        lbff = convert_lbff(b[120:2880], 2760, 2768, 1222, LBFF_OLD)
        return b[:120] + lbff + b[2880:5320] + struct.pack('<i', 15) + b[5320:5440]
    if gid == 100003:
        assert len(b) == 6304
        lbff = convert_lbff(b[120:3596], 3476, 3484, 1470, GMV_OLD)
        return b[:120] + lbff + b[3596:6144] + struct.pack('<i', 20) + b[6144:6304]
    if gid == 100026:
        assert len(b) == 136
        return b[:120] + struct.pack('<i', 2) + b[120:136]
    raise SystemExit(f'graph {gid} not handled')


OLD_SIZE = {100002: 5440, 100003: 6304, 100026: 136}

d = open(sys.argv[1], 'rb').read()
sap, common, nres, nsm = struct.unpack_from('<4I', d, 0)
assert common == 1110027246, f'not an e5172cc-stamped file (common {common})'
out = bytearray(struct.pack('<5I', sap, 0, COMMON, nres, nsm) + bytes(20))

off = 16
pins = struct.unpack_from('<5I', d, off)
n = 20 + 16 * sum(pins)
out += d[off:off + n]
off += n

ng, = struct.unpack_from('<I', d, off)
out += struct.pack('<I', ng)
for i in range(ng):
    gid, _ = struct.unpack_from('<2I', d, off + 4 + 8 * i)
    out += struct.pack('<2I', gid, HASH[gid])
off += 4 + 8 * ng

nz, = struct.unpack_from('<I', d, off)
out += d[off:off + 4 + 8 * nz]
off += 4 + 8 * nz

heads = off
modes = heads + 116 * nres
data = modes + 16 * nsm

# Data blocks in file order, converted once each (settings share blocks).
blocks = {}
for i in range(nres):
    h = heads + 116 * i
    gid, smi, rcd = struct.unpack_from('<iiI', d, h + 100)
    blocks.setdefault(rcd, gid)
    assert blocks[rcd] == gid
new_off = {}
new_data = bytearray()
for rcd in sorted(blocks):
    gid = blocks[rcd]
    new_off[rcd] = len(new_data)
    new_data += convert_block(gid, d[data + rcd:data + rcd + OLD_SIZE[gid]])
end = max(r + OLD_SIZE[g] for r, g in blocks.items())
assert data + end == len(d), f'{len(d) - data - end} bytes after the last block'

for i in range(nres):
    h = d[heads + 116 * i:heads + 116 * (i + 1)]
    afb, = struct.unpack_from('<I', h, 0)
    gid, smi, rcd, ghash = struct.unpack_from('<iiII', h, 100)
    out += struct.pack('<IB3x', afb, 1) + h[4:100] + struct.pack('<iiII', gid, smi, new_off[rcd], HASH[gid])
out += d[modes:data]
out += new_data
open(sys.argv[2], 'wb').write(out)
print(f'{sys.argv[2]}: {nres} settings, {len(blocks)} blocks, '
      f'graphs {sorted(set(blocks.values()))}, {len(d)} -> {len(out)} bytes')
