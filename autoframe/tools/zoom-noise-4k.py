#!/usr/bin/env python3
"""Companion to zoom-noise-test.py: temporal noise of the ISP's 4K output
(the stage-1 crop-mode source) measured 1:1 in the same sensor region as the
zoomed 1080p test, plus the same band 2x2-averaged (what a 2x downscale gives).
    zoom-noise-4k.py [region]
"""
import sys, time
import numpy as np
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib

Gst.init(None)
W, H = 3840, 2160
region = sys.argv[1] if len(sys.argv) > 1 else "962,780,2882,1860"
l, t, r, b = (int(v) for v in region.split(","))
band = 150
pipe = Gst.parse_launch(
    "icamerasrc device-name=imx681-uf ! video/x-raw,format=NV12,width=%d,height=%d,framerate=30/1 "
    "! appsink name=sink emit-signals=true sync=false max-buffers=4 drop=true" % (W, H))
sink = pipe.get_by_name("sink")
loop = GLib.MainLoop()
prev = {"y": None, "n": 0}
d11, d22 = [], []

def on_sample(s):
    buf = s.emit("pull-sample").get_buffer()
    ok, mi = buf.map(Gst.MapFlags.READ)
    if not ok:
        return Gst.FlowReturn.OK
    y = np.frombuffer(mi.data, dtype=np.uint8, count=W * H).reshape(H, W)[t:t + band, l:r].astype(np.int16)
    buf.unmap(mi)
    prev["n"] += 1
    if prev["n"] > 60 and prev["y"] is not None:   # skip AE/AWB settling
        d11.append(float(np.mean(np.abs(y - prev["y"]))))
        a = y.reshape(band // 2, 2, (r - l) // 2, 2).mean(axis=(1, 3))
        p = prev["y"].reshape(band // 2, 2, (r - l) // 2, 2).mean(axis=(1, 3))
        d22.append(float(np.mean(np.abs(a - p))))
    prev["y"] = y
    return Gst.FlowReturn.OK

sink.connect("new-sample", on_sample)
GLib.timeout_add(7000, lambda: (pipe.send_event(Gst.Event.new_eos()), False)[1])
bus = pipe.get_bus(); bus.add_signal_watch()
bus.connect("message", lambda b, m: loop.quit() if m.type in (Gst.MessageType.EOS, Gst.MessageType.ERROR) else None)
pipe.set_state(Gst.State.PLAYING); loop.run(); pipe.set_state(Gst.State.NULL)
print("4K output, same sensor band: temporal 1:1 %.2f, 2x2-averaged %.2f (%d frames)" % (np.mean(d11), np.mean(d22), len(d11)))
