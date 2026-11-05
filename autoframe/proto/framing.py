"""Automatic-framing controller (stage 0 prototype; ported 1:1 to C++).

Coordinates are source pixels. The window is a 16:9 (output aspect) rectangle
inside the source; the element crops it and scales to the output size.

Behaviour (see docs/auto-framing-plan.md §4):
- target: head-and-shoulders box around the dominant face (single) or the
  union of present faces (group), with headroom; zoom capped at max_zoom.
- dead zone: the window only re-targets when the face box leaves a tolerance
  band around the current framing, or its size changes beyond a ratio.
- motion: critically damped spring per axis (position and width) with a
  velocity cap, so pans ease in and out and never jump.
- presence hysteresis: a face counts after `appear_frames` consecutive
  detections and stops counting after `lost_frames` misses; after
  `hold_time` seconds with no face the window eases back to the full view.
"""
import math


class Face:
    __slots__ = ("x", "y", "w", "h", "score", "seen", "missed", "id")

    def __init__(self, x, y, w, h, score, fid):
        self.x, self.y, self.w, self.h, self.score = x, y, w, h, score
        self.seen, self.missed, self.id = 1, 0, fid

    @property
    def cx(self): return self.x + self.w / 2

    @property
    def cy(self): return self.y + self.h / 2


class Params:
    def __init__(self, **kw):
        self.max_zoom = 2.0        # window never smaller than src / max_zoom
        self.face_frac = 0.30      # face height as a fraction of window height
        self.headroom = 0.12       # face centre sits this fraction of window height above centre
        self.dead_pos = 0.10       # re-target when the face centre drifts this fraction of the window off its spot
        self.dead_size = 0.25      # ...or the wanted width differs by more than this ratio
        self.omega = 4.0           # spring natural frequency, rad/s (settles in ~1 s)
        self.vmax_frac = 1.2       # max pan speed, window widths per second
        self.appear_frames = 5
        self.lost_frames = 15
        self.hold_time = 3.0
        self.follow_time = 0.7     # after a re-target, keep following for this long (lands centred)
        self.group = True
        self.group_grow_frames = 30  # a new face widens the shot after this many frames
        self.match_iou = 0.3
        self.__dict__.update(kw)


class Controller:
    def __init__(self, src_w, src_h, out_aspect=16 / 9, params=None):
        self.p = params or Params()
        self.sw, self.sh = src_w, src_h
        self.aspect = out_aspect
        # full-view window: the widest out_aspect rectangle in the source, centred
        self.full_w = min(src_w, src_h * out_aspect)
        self.full_h = self.full_w / out_aspect
        self.min_w = self.full_w / self.p.max_zoom
        self.cx, self.cy, self.w = src_w / 2, src_h / 2, self.full_w
        self.vx = self.vy = self.vw = 0.0
        self.tx, self.ty, self.tw = self.cx, self.cy, self.w
        self.tracks = []
        self.next_id = 1
        self.lost_for = 0.0
        self.follow_for = 0.0     # seconds left of continuous following after a re-target
        self.enabled = True

    # ---- tracking (presence hysteresis) ----
    def _update_tracks(self, dets):
        unmatched = list(dets)
        for t in self.tracks:
            best, bi = 0.0, -1
            for i, d in enumerate(unmatched):
                v = iou((t.x, t.y, t.w, t.h), d[:4])
                if v > best:
                    best, bi = v, i
            if bi >= 0 and best >= self.p.match_iou:
                d = unmatched.pop(bi)
                t.x, t.y, t.w, t.h, t.score = d[0], d[1], d[2], d[3], d[4]
                t.seen += 1; t.missed = 0
            else:
                t.missed += 1
        for d in unmatched:
            self.tracks.append(Face(*d[:5], self.next_id)); self.next_id += 1
        self.tracks = [t for t in self.tracks if t.missed < self.p.lost_frames]

    def present(self):
        return [t for t in self.tracks if t.seen >= self.p.appear_frames and t.missed == 0
                or (t.seen >= self.p.appear_frames and t.missed < self.p.lost_frames)]

    # ---- target ----
    def _wanted(self, faces):
        """Window (cx, cy, w) framing these faces, before dead zone and limits."""
        if len(faces) == 1 or not self.p.group:
            f = max(faces, key=lambda t: t.w * t.h)
            fh = f.h
            w = max(fh / self.p.face_frac * self.aspect, self.min_w)
            h = w / self.aspect
            return f.cx, f.cy + self.p.headroom * h, w
        # group: union of faces, each padded by one face height
        x0 = min(t.x - t.h for t in faces); x1 = max(t.x + t.w + t.h for t in faces)
        y0 = min(t.y - 1.3 * t.h for t in faces); y1 = max(t.y + t.h + 2.0 * t.h for t in faces)
        w = max(x1 - x0, (y1 - y0) * self.aspect, self.min_w)
        return (x0 + x1) / 2, (y0 + y1) / 2, w

    def _limit(self, cx, cy, w):
        w = min(max(w, self.min_w), self.full_w)
        h = w / self.aspect
        cx = min(max(cx, w / 2), self.sw - w / 2)
        cy = min(max(cy, h / 2), self.sh - h / 2)
        return cx, cy, w

    def step(self, dets, dt):
        """dets: [(x, y, w, h, score)] in source pixels. Returns (x, y, w, h) crop."""
        self._update_tracks(dets)
        faces = [t for t in self.tracks if t.seen >= self.p.appear_frames]
        if self.p.group and len(faces) > 1:
            # a face only widens the shot once it has been around for a while
            faces = [t for t in faces if t.seen >= self.p.group_grow_frames] or \
                    [max(faces, key=lambda t: t.seen)]
        if not self.enabled:
            self.tx, self.ty, self.tw = self.sw / 2, self.sh / 2, self.full_w
        elif faces:
            self.lost_for = 0.0
            cx, cy, w = self._limit(*self._wanted(faces))
            # dead zone against the *current target*: small drift is ignored;
            # once a move is triggered, keep following for follow_time so the
            # shot settles centred rather than at the edge of the dead zone
            if (abs(cx - self.tx) > self.p.dead_pos * self.tw or
                    abs(cy - self.ty) > self.p.dead_pos * self.tw / self.aspect or
                    abs(w / self.tw - 1) > self.p.dead_size):
                self.follow_for = self.p.follow_time
            if self.follow_for > 0:
                self.follow_for -= dt
                self.tx, self.ty, self.tw = cx, cy, w
        else:
            self.lost_for += dt
            if self.lost_for >= self.p.hold_time:
                self.tx, self.ty, self.tw = self.sw / 2, self.sh / 2, self.full_w
        # critically damped spring towards the target, velocity-capped
        k = self.p.omega ** 2; c = 2 * self.p.omega
        vmax = self.p.vmax_frac * self.w
        for a in ("x", "y", "w"):
            pos = getattr(self, {"x": "cx", "y": "cy", "w": "w"}[a])
            tgt = getattr(self, "t" + a)
            v = getattr(self, "v" + a)
            v += (k * (tgt - pos) - c * v) * dt
            v = max(-vmax, min(vmax, v))
            pos += v * dt
            setattr(self, {"x": "cx", "y": "cy", "w": "w"}[a], pos)
            setattr(self, "v" + a, v)
        self.cx, self.cy, self.w = self._limit(self.cx, self.cy, self.w)
        h = self.w / self.aspect
        return self.cx - self.w / 2, self.cy - h / 2, self.w, h


def iou(a, b):
    x1, y1 = max(a[0], b[0]), max(a[1], b[1])
    x2, y2 = min(a[0] + a[2], b[0] + b[2]), min(a[1] + a[3], b[1] + b[3])
    inter = max(0, x2 - x1) * max(0, y2 - y1)
    return inter / (a[2] * a[3] + b[2] * b[3] - inter + 1e-9)
