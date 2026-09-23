#!/usr/bin/env python3
"""Decode LimineTramp / LimineCrumb / LimineHandoff from efivarfs or a QEMU vars.fd."""
import struct, sys, os
G = '513ee0d0-6e43-cb05-b272-f146a2fcb88a'
def get(name, src):
    if src == 'efivarfs':
        p = f'/sys/firmware/efi/efivars/{name}-{G}'
        return open(p, 'rb').read()[4:] if os.path.exists(p) else None
    d = open(src, 'rb').read(); n = name.encode('utf-16-le') + b'\0\0'
    k = d.rfind(n)
    return d[k + len(n):k + len(n) + 256] if k >= 0 else None
src = sys.argv[1] if len(sys.argv) > 1 else 'efivarfs'
t = get('LimineTramp', src)
if t:
    v = struct.unpack_from('<8Q', t)
    n = 'buf len locate_status clear_status get_before_status attrs_before get_after_status attrs_after'.split()
    r = dict(zip(n, v)); print('Tramp:', ' '.join(f'{a}={r[a]:#x}' for a in n))
    for k in ('attrs_before', 'attrs_after'):
        a = r[k]; print(f'   {k}: XP={bool(a & 0x4000)} RO={bool(a & 0x20000)} RP={bool(a & 0x2000)}')
else:
    print('Tramp: none')
c = get('LimineCrumb', src)
print('Crumb:', struct.unpack_from('<I', c)[0] if c else 'none')
