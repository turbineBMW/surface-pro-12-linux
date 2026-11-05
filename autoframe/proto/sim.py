"""Stage 0: drive the controller with a synthetic face track at 30 fps and
report smoothness, bounds and dead-zone behaviour. Writes sim.csv."""
import math, random
from framing import Controller, Params

SW, SH, FPS = 3840, 2160, 30
random.seed(1)


def face_at(t):
    """Synthetic track: (x, y, w, h) of the face in source pixels, or None."""
    fw = fh = 360  # ~ a face at arm's length on the 4K frame (ours was ~210 px on 1080p)
    cx, cy = 900, 1000
    if 5 <= t < 7:            # walk right over 2 s
        cx = 900 + (t - 5) / 2 * 1800
    elif t >= 7:
        cx = 2700
    if 8 <= t < 9.5:          # lean in over 1.5 s
        fw = fh = 360 + (t - 8) / 1.5 * 220
    elif t >= 9.5:
        fw = fh = 580
    if 12.0 <= t < 12.3:      # detector flicker
        return None
    if t >= 15:               # leaves
        return None
    j = lambda: random.uniform(-4, 4)  # detector jitter
    return (cx - fw / 2 + j(), cy - fh / 2 + j(), fw + j(), fh + j())


c = Controller(SW, SH, params=Params())
rows, maxv, moved_in_jitter = [], 0.0, 0
prev = None
for i in range(int(20 * FPS)):
    t = i / FPS
    f = face_at(t)
    dets = [(*f, 0.9)] if f else []
    x, y, w, h = c.step(dets, 1 / FPS)
    assert x >= -0.5 and y >= -0.5 and x + w <= SW + 0.5 and y + h <= SH + 0.5, (t, x, y, w, h)
    assert w >= c.min_w - 0.5
    if prev:
        v = math.hypot(x - prev[0], y - prev[1]) * FPS
        maxv = max(maxv, v)
        if 3 <= t < 5 and v > 1:  # steady phase with jitter: must not move
            moved_in_jitter += 1
    prev = (x, y, w, h)
    rows.append((t, f, x, y, w, h))

with open("sim.csv", "w") as out:
    out.write("t,face_cx,face_cy,face_h,win_x,win_y,win_w,win_h,zoom\n")
    for t, f, x, y, w, h in rows:
        fc = f"{f[0]+f[2]/2:.0f},{f[1]+f[3]/2:.0f},{f[3]:.0f}" if f else ",,"
        out.write(f"{t:.3f},{fc},{x:.0f},{y:.0f},{w:.0f},{h:.0f},{c.full_w/w:.2f}\n")


def at(tt):
    r = rows[int(tt * FPS)]
    return f"t={tt:5.2f}s win x={r[2]:5.0f} y={r[3]:5.0f} w={r[4]:5.0f} zoom={c.full_w/r[4]:.2f}"


for tt in (0, 0.5, 1, 2, 3, 4.9, 5.5, 6.5, 7.5, 8.5, 9, 10, 11, 12.1, 12.5, 15.5, 17, 18.5, 19.9):
    print(at(tt))
f = face_at(8.5); r = rows[int(8.5*FPS)]; print(f"centring error at t=8.5 s: {abs((r[2]+r[4]/2) - (f[0]+f[2]/2)):.0f} px")
print(f"max window speed {maxv:.0f} px/s ({maxv/SW:.2f} widths/s); frames moved during jitter-only phase: {moved_in_jitter}")
