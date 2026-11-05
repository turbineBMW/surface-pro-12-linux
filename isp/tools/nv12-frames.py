#!/usr/bin/env python3
"""Per-frame statistics of a raw NV12 capture from run-dev.sh, and optional
PNG export of one frame, using the HAL's buffer size (W x (H+1) x 1.5).

  nv12-frames.py <capture.nv12> <W> <H> [frame-to-png N out.nv12]

The exported frame is a plain W x H NV12 (Y then UV), for ffmpeg:
  ffmpeg -f rawvideo -pix_fmt nv12 -s WxH -i out.nv12 frame.png
"""
import sys
import numpy as np

path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
fs = w * (h + 1) * 3 // 2
d = np.fromfile(path, dtype=np.uint8)
n = len(d) // fs
print(f"{path}: {len(d)} bytes, {n} frames of {fs} (remainder {len(d) % fs})")
for i in range(n):
    f = d[i * fs:(i + 1) * fs]
    y = f[:w * h]
    uv = f[w * h:w * h + w * h // 2].reshape(-1, 2)
    print(f"  {i:3d}: Y {y.mean():6.1f} ±{y.std():5.1f}  U {uv[:, 0].mean():5.1f} V {uv[:, 1].mean():5.1f}")
if len(sys.argv) > 6 and sys.argv[4] == 'frame-to-png':
    i = int(sys.argv[5])
    f = d[i * fs:(i + 1) * fs]
    open(sys.argv[6], 'wb').write(f[:w * h].tobytes() + f[w * h:w * h + w * h // 2].tobytes())
    print(f"wrote frame {i} to {sys.argv[6]}")
