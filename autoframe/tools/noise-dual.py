#!/usr/bin/env python3
"""Temporal noise of a 1080p second stream while the main stream runs at 4K
(does the ISP's full-resolution temporal noise reduction carry over to the
downscaled pin?). Same wall band as noise-by-size.py. Run as root.
    noise-dual.py [main WxH] [second WxH]
"""
import sys, time
import numpy as np
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib

Gst.init(None)
main = sys.argv[1] if len(sys.argv) > 1 else "3840x2160"
second = sys.argv[2] if len(sys.argv) > 2 else "1920x1080"
MW, MH = (int(v) for v in main.split("x"))
W, H = (int(v) for v in second.split("x"))
sc = W / 3844
t, b, l, r = int(780 * sc), int(930 * sc), int(962 * sc), int(2882 * sc)
pipe = Gst.parse_launch(
    "icamerasrc name=cam device-name=imx681-uf num-vc=0 "
    "cam.src ! video/x-raw,format=NV12,width=%d,height=%d,framerate=30/1 ! fakesink sync=false "
    "cam.video_0 ! video/x-raw,format=NV12,width=%d,height=%d,framerate=30/1 "
    "! appsink name=sink emit-signals=true sync=false max-buffers=4 drop=true" % (MW, MH, W, H))
sink = pipe.get_by_name("sink")
loop = GLib.MainLoop()
st = {"y": None, "n": 0, "d": [], "s": [], "m": []}
def on_sample(s):
    buf = s.emit("pull-sample").get_buffer()
    ok, mi = buf.map(Gst.MapFlags.READ)
    if not ok: return Gst.FlowReturn.OK
    y = np.frombuffer(mi.data, dtype=np.uint8, count=W * H).reshape(H, W)[t:b, l:r].astype(np.int16)
    buf.unmap(mi)
    st["n"] += 1
    if st["n"] > 60 and st["y"] is not None:
        st["d"].append(float(np.mean(np.abs(y - st["y"])))); st["s"].append(float(np.std(y))); st["m"].append(float(np.mean(y)))
    st["y"] = y
    return Gst.FlowReturn.OK
sink.connect("new-sample", on_sample)
GLib.timeout_add(7000, lambda: (pipe.send_event(Gst.Event.new_eos()), False)[1])
bus = pipe.get_bus(); bus.add_signal_watch()
def on_msg(bb, m):
    if m.type == Gst.MessageType.ERROR: print("ERROR:", m.parse_error()[0], flush=True)
    if m.type in (Gst.MessageType.EOS, Gst.MessageType.ERROR): loop.quit()
bus.connect("message", on_msg)
pipe.set_state(Gst.State.PLAYING); loop.run(); pipe.set_state(Gst.State.NULL)
if st["d"]:
    d = np.array(st["d"])
    print("main %s + second %s: luma %6.1f spatial %6.2f temporal mean %5.2f median %5.2f (%d frames)" % (main, second, np.mean(st["m"]), np.mean(st["s"]), d.mean(), np.median(d), len(d)), flush=True)
else:
    print("main %s + second %s: no frames on the second stream" % (main, second), flush=True)
