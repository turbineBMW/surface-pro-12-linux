#!/usr/bin/env python3
"""Exercise icamerasrc's zoom-region property (the ISP-side crop) on the
front camera and save frames before, during and after a zoom, as PNG.

    zoom-region-test.py <outdir> [region]      default region: the middle 1920x1080

Runs against the installed HAL/icamerasrc unless PREFIX is set to a dev prefix
(then LD_LIBRARY_PATH, GST_PLUGIN_PATH and CAMERA_CFG_PATH point there; set
them in the environment before calling). Needs the camera free (the ISP relay
only opens it while a client streams)."""
import os, sys, time
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib

Gst.init(None)
out = sys.argv[1]
region = sys.argv[2] if len(sys.argv) > 2 else "962,780,2882,1860"
os.makedirs(out, exist_ok=True)

pipe = Gst.parse_launch(
    "icamerasrc name=cam device-name=imx681-uf ! video/x-raw,format=NV12,width=1920,height=1080,framerate=30/1 "
    "! videoconvert ! videorate drop-only=true ! video/x-raw,framerate=2/1 ! pngenc ! multifilesink name=sink location=%s/frame-%%03d.png" % out)
cam = pipe.get_by_name("cam")
loop = GLib.MainLoop()
t0 = time.time()
log = []

def step(label, value):
    def f():
        if value is not None:
            cam.set_property("zoom-region", value)
        log.append("%5.1fs %s -> zoom-region=%r" % (time.time() - t0, label, cam.get_property("zoom-region")))
        print(log[-1], flush=True)
        return False
    return f

l, t, r, b = (int(v) for v in region.split(","))
GLib.timeout_add(3000, step("zoom in", region))
GLib.timeout_add(6000, step("pan left and up", "%d,%d,%d,%d" % (l - 600, t - 300, r - 600, b - 300)))
GLib.timeout_add(9000, step("top-left corner", "0,0,%d,%d" % (r - l, b - t)))
GLib.timeout_add(12000, step("full view", "0,0,3844,2640"))
GLib.timeout_add(15500, lambda: (pipe.send_event(Gst.Event.new_eos()), False)[1])

bus = pipe.get_bus()
bus.add_signal_watch()
def on_msg(bus, msg):
    if msg.type == Gst.MessageType.EOS: loop.quit()
    elif msg.type == Gst.MessageType.ERROR:
        err, dbg = msg.parse_error(); print("ERROR:", err, dbg); loop.quit()
bus.connect("message", on_msg)
pipe.set_state(Gst.State.PLAYING)
loop.run()
pipe.set_state(Gst.State.NULL)
print("frames:", len([f for f in os.listdir(out) if f.endswith(".png")]))
