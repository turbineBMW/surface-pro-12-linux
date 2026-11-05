#!/usr/bin/env python3
"""Temporal noise of the ISP output by output size (full view), measured in
the same sensor region scaled to each size: mean luma, spatial std, mean
absolute frame-to-frame difference. Run as root (HAL shared memory).
    noise-by-size.py [WxH ...]      default 1920x1080 2560x1440 3840x2160
"""
import sys, time
import numpy as np
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib

Gst.init(None)
sizes = sys.argv[1:] or ["1920x1080", "2560x1440", "3840x2160"]
SENSOR_W = 3844
# sensor band: rows 780..930, cols 962..2882 (a wall patch), scaled per size
for size in sizes:
    W, H = (int(v) for v in size.split("x"))
    sc = W / SENSOR_W
    t, b, l, r = int(780 * sc), int(930 * sc), int(962 * sc), int(2882 * sc)
    pipe = Gst.parse_launch(
        "icamerasrc device-name=imx681-uf ! video/x-raw,format=NV12,width=%d,height=%d,framerate=30/1 "
        "! appsink name=sink emit-signals=true sync=false max-buffers=4 drop=true" % (W, H))
    sink = pipe.get_by_name("sink")
    loop = GLib.MainLoop()
    st = {"y": None, "n": 0, "d": [], "s": [], "m": []}
    def on_sample(s, st=st, W=W, H=H, t=t, b=b, l=l, r=r):
        buf = s.emit("pull-sample").get_buffer()
        ok, mi = buf.map(Gst.MapFlags.READ)
        if not ok: return Gst.FlowReturn.OK
        y = np.frombuffer(mi.data, dtype=np.uint8, count=W * H).reshape(H, W)[t:b, l:r].astype(np.int16)
        buf.unmap(mi)
        st["n"] += 1
        if st["n"] > 60 and st["y"] is not None:
            st["d"].append(float(np.mean(np.abs(y - st["y"]))))
            st["s"].append(float(np.std(y))); st["m"].append(float(np.mean(y)))
        st["y"] = y
        return Gst.FlowReturn.OK
    sink.connect("new-sample", on_sample)
    GLib.timeout_add(7000, lambda p=pipe: (p.send_event(Gst.Event.new_eos()), False)[1])
    bus = pipe.get_bus(); bus.add_signal_watch()
    bus.connect("message", lambda bb, m, lp=loop: lp.quit() if m.type in (Gst.MessageType.EOS, Gst.MessageType.ERROR) else None)
    pipe.set_state(Gst.State.PLAYING); loop.run(); pipe.set_state(Gst.State.NULL)
    bus.remove_signal_watch()
    if st["d"]:
        d = np.array(st["d"])
        print("%-10s luma %6.1f  spatial %6.2f  temporal mean %5.2f median %5.2f p90 %5.2f  near-identical pairs %d/%d" % (
            size, np.mean(st["m"]), np.mean(st["s"]), d.mean(), np.median(d), np.percentile(d, 90), int((d < 0.2).sum()), len(d)), flush=True)
    else:
        print("%-10s no frames" % size, flush=True)
    time.sleep(1)
