"""Concatenate recorded PPM frames into a raw NV12 file (BT.601 limited range)
for offline tests of the element: ppm2nv12.py out.nv12 frame.ppm..."""
import sys
import numpy as np
from yunet_ov import read_ppm

out = open(sys.argv[1], "wb")
for f in sys.argv[2:]:
    bgr = read_ppm(f).astype(np.float32)
    b, g, r = bgr[..., 0], bgr[..., 1], bgr[..., 2]
    y = 16 + (65.738 * r + 129.057 * g + 25.064 * b) / 256
    u = 128 + (-37.945 * r - 74.494 * g + 112.439 * b) / 256
    v = 128 + (112.439 * r - 94.154 * g - 18.285 * b) / 256
    h, w = y.shape
    u2 = u.reshape(h // 2, 2, w // 2, 2).mean(axis=(1, 3))
    v2 = v.reshape(h // 2, 2, w // 2, 2).mean(axis=(1, 3))
    uv = np.stack([u2, v2], axis=-1).reshape(h // 2, w)
    out.write(np.clip(y, 0, 255).astype(np.uint8).tobytes())
    out.write(np.clip(uv, 0, 255).astype(np.uint8).tobytes())
print("wrote", len(sys.argv) - 2, "frames", w, "x", h)
