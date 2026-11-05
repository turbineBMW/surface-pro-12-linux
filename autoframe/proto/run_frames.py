"""Stage 0: run YuNet (NPU) on the recorded IMX681 frames, print detections
in source pixels and timing. Usage: run_frames.py [device] [frame.ppm ...]"""
import glob, sys, time
import numpy as np
from yunet_ov import YuNet, read_ppm, resize_area

dev = sys.argv[1] if len(sys.argv) > 1 else "NPU"
files = sys.argv[2:] or sorted(glob.glob(
    "/home/turbinebmw/Projects/surface-pro-12-linux/private/camera/frames/*.ppm"))
det = YuNet(device=dev)
tp = ti = 0.0
for f in files:
    img = read_ppm(f)
    H, W = img.shape[:2]
    t0 = time.perf_counter()
    small = resize_area(img, det.w, det.h)
    t1 = time.perf_counter()
    faces = det.infer(small)
    t2 = time.perf_counter()
    tp += t1 - t0; ti += t2 - t1
    sx, sy = W / det.w, H / det.h
    out = ", ".join(f"({x*sx:.0f},{y*sy:.0f} {w*sx:.0f}x{h*sy:.0f} p={s:.2f})"
                    for x, y, w, h, s in faces)
    print(f"{f.split('/')[-1]:38s} {W}x{H}  {len(faces)} face(s): {out}")
n = len(files)
print(f"{dev}: preprocess {tp/n*1000:.2f} ms, infer+decode {ti/n*1000:.2f} ms per frame ({n} frames)")
