#!/usr/bin/env python3
"""Measure temporal noise of the front camera through icamerasrc's zoom-region
(the ISP-side crop) across phases: full view, zoomed still, zoomed with the
window nudged every frame, zoomed still again, full view again. Prints, per
phase, the mean absolute luma difference between consecutive frames and the
spatial std, over the top `band` rows (wall/ceiling, no subject).

    zoom-noise-test.py [region] [band_rows]

Run as root against a dev prefix or the installed HAL (see zoom-region-test.py).
"""
import sys, time
import numpy as np
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib

Gst.init(None)
W, H = 1920, 1080
region = sys.argv[1] if len(sys.argv) > 1 else "962,780,2882,1860"
band = int(sys.argv[2]) if len(sys.argv) > 2 else 150
l, t, r, b = (int(v) for v in region.split(","))

pipe = Gst.parse_launch(
    "icamerasrc name=cam device-name=imx681-uf ! video/x-raw,format=NV12,width=%d,height=%d,framerate=30/1 "
    "! appsink name=sink emit-signals=true sync=false max-buffers=4 drop=true" % (W, H))
cam = pipe.get_by_name("cam")
sink = pipe.get_by_name("sink")
loop = GLib.MainLoop()
t0 = time.time()

phase = {"name": "full", "diffs": [], "stds": []}
results = []
prev = {"y": None}
nudge = {"on": False, "i": 0}

def set_region(v):
    cam.set_property("zoom-region", v)

def start_phase(name, value):
    def f():
        if phase["diffs"]:
            results.append((phase["name"], np.mean(phase["diffs"]), np.mean(phase["stds"]), len(phase["diffs"])))
        phase.update(name=name, diffs=[], stds=[])
        nudge["on"] = name == "nudged"
        if value is not None:
            set_region(value)
        print("%5.1fs phase %s" % (time.time() - t0, name), flush=True)
        return False
    return f

def on_sample(s):
    buf = s.emit("pull-sample").get_buffer()
    ok, mi = buf.map(Gst.MapFlags.READ)
    if not ok:
        return Gst.FlowReturn.OK
    y = np.frombuffer(mi.data, dtype=np.uint8, count=W * H).reshape(H, W)[:band].astype(np.int16)
    buf.unmap(mi)
    if prev["y"] is not None and prev["y"].shape == y.shape:
        phase["diffs"].append(float(np.mean(np.abs(y - prev["y"]))))
        phase["stds"].append(float(np.std(y)))
    prev["y"] = y
    if nudge["on"]:
        nudge["i"] += 1
        d = 2 if nudge["i"] % 2 else -2
        set_region("%d,%d,%d,%d" % (l + d, t, r + d, b))
    return Gst.FlowReturn.OK

sink.connect("new-sample", on_sample)
GLib.timeout_add(1000, start_phase("full", "0,0,3844,2640"))
GLib.timeout_add(4000, start_phase("zoomed still", region))
GLib.timeout_add(8000, start_phase("nudged", region))
GLib.timeout_add(12000, start_phase("zoomed still 2", region))
GLib.timeout_add(16000, start_phase("full 2", "0,0,3844,2640"))
GLib.timeout_add(19500, lambda: (pipe.send_event(Gst.Event.new_eos()), False)[1])

bus = pipe.get_bus()
bus.add_signal_watch()
def on_msg(bus, msg):
    if msg.type == Gst.MessageType.EOS:
        loop.quit()
    elif msg.type == Gst.MessageType.ERROR:
        print("ERROR:", msg.parse_error()[0]); loop.quit()
bus.connect("message", on_msg)
pipe.set_state(Gst.State.PLAYING)
loop.run()
pipe.set_state(Gst.State.NULL)
if phase["diffs"]:
    results.append((phase["name"], np.mean(phase["diffs"]), np.mean(phase["stds"]), len(phase["diffs"])))
print("\n%-16s %10s %10s %6s" % ("phase", "temporal", "spatial", "frames"))
for name, d, s, n in results:
    print("%-16s %10.2f %10.2f %6d" % (name, d, s, n))
