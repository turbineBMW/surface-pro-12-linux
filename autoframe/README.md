# Automatic framing (sp12autoframe)

Windows Studio Effects' *Automatic framing* for the front camera: a GStreamer
element that sits in the hardware-ISP relay, finds the face(s) with a YuNet
detector on the NPU (OpenVINO) and crops a 16:9 window out of the 4K ISP
output that follows them, scaled to 1080p. Plan and findings:
`docs/auto-framing-plan.md`.

```
icamerasrc (IMX681, PSYS, NV12 1920x1080) ! sp12autoframe mode=isp ! videoconvert  →  v4l2-relayd → loopback → PipeWire
        ▲ zoom-region "l,t,r,b" (active-array px) ──┘
```

Two modes. `mode=isp` (the package default, needs sp12-camera-hal
2025.12.10-4 or later): the element passes 1080p through, runs the detector
on it, maps detections into sensor active-array coordinates through the
window it sent `isp-latency` frames earlier, and sets `zoom-region` on the
upstream icamerasrc; the ISP's output scaler crops and scales (the HAL's
pan-tilt-zoom path, unblocked by `isp/patches/hal-zoom-region.patch`).
`mode=crop`: 4K in, the element crops and scales on the CPU (the stage-1
path, kept for hardware without the patched HAL).

## Layout

- `src/gstsp12autoframe.cpp`: the element (`GstVideoFilter`, NV12 in at any
  size, NV12 out at the negotiated size). Properties: `enable`, `device`
  (NPU, falls back to GPU, CPU), `model`, `det-width`/`det-height`,
  `max-zoom`, `face-frac`, `headroom`, `speed`, `hold-time`, `group`,
  `detect-interval`, `control-file`, `draw-boxes`.
- `src/framing.h`: the controller (target box, dead zone, critically damped
  spring, presence hysteresis, hold). `proto/framing.py` is the same thing in
  Python; keep them in step.
- `src/yunet.{h,cpp}`: YuNet through OpenVINO, output decoding and NMS.
- `proto/`: stage-0 prototypes: `run_frames.py` (detector on the recorded
  frames under `private/camera/frames`), `sim.py` (controller on a synthetic
  track, writes `sim.csv`), `ppm2nv12.py` (test clip for the element).
- `install-dev.sh` / `uninstall-dev.sh` (root): stage the plugin, the model
  and a HAL config copy with 4K output under `/opt/sp12-autoframe-dev`, add
  the relay drop-in (plugin path, config path, NPU device access), rewrite
  the relay's source pipeline (`AUTOFRAME_MODE=isp` for ISP mode), restart
  the relay. For hacking on the element; `install-package.sh` (root)
  replaces it with the package, `install-isp-dev.sh` installs a freshly built
  HAL package plus the element in ISP mode.
- `tools/zoom-region-test.py`: drives icamerasrc's `zoom-region` directly
  (zoom, two-axis pan, corner, full view) and saves frames; run as root
  against a dev prefix.
- `../pkg/sp12-autoframe`: the package: the plugin in `/usr/lib/gstreamer-1.0`,
  the model in `/usr/share/sp12`, the toggle, a second relay environment file
  (`/etc/v4l2-relayd.d/sp12-front-autoframe.env`, loaded after the relay's
  own by the unit drop-in so its `VIDEOSRC` wins and removing the package
  leaves the plain relay), the NPU device rule for the unit, tmpfiles for
  `/run/sp12`, and a user unit that restores the saved settings at login.
  Needs the 4K entries in the HAL profile (sp12-camera-hal built from
  `isp/config/sensors/imx681-uf.json` after 2026-11-05).
- `../userspace/omarchy/plugins/sp12.autoframe`: Omarchy bar widget (Quickshell
  QML): a camera icon in the bar (right-click switches), and a popup with
  Follow me / Full view, Loose / Normal / Tight presets, sliders for face
  size, zoom limit, headroom, speed and hold, the detection-box overlay and a
  reset. It watches `/run/sp12/autoframe` and drives everything through the
  tool, so CLI and widget stay in sync. `sp12-autoframe plugin install` copies
  it to `~/.config/omarchy/plugins` and enables it; `omarchy-shell
  sp12.autoframe open|close|toggle` summons it.
- `../userspace/usr/local/bin/sp12-autoframe`: user-side control
  (`auto|off|toggle|status|restore`, `--face F`, `--zoom N`, `--headroom H`,
  `--speed S`, `--hold T`, `--boxes on|off`) through `/run/sp12/autoframe`,
  re-read by the element within a second, and saved to
  `~/.config/sp12/autoframe.conf`.

## Build and offline test

```sh
meson setup build && ninja -C build
# a test clip from recorded frames, then the element on it, boxes drawn:
python proto/ppm2nv12.py /tmp/x/front.nv12 private/camera/frames/front-cam0-stream0-*.ppm
GST_PLUGIN_PATH=build gst-launch-1.0 filesrc location=/tmp/x/front.nv12 ! \
  rawvideoparse format=nv12 width=1920 height=1080 framerate=30/1 ! \
  sp12autoframe model=/usr/share/irlume/models/face_detection_yunet_2023mar.onnx draw-boxes=true ! \
  video/x-raw,width=960,height=540 ! videoconvert ! pngenc ! multifilesink location=/tmp/x/out-%03d.png
```

`GST_DEBUG=sp12autoframe:5` logs the per-frame cost every 300 frames.

## Model

YuNet `face_detection_yunet_2023mar.onnx` (OpenCV Zoo, Apache-2.0). The dev
install copies the one `irlume` ships; the package will carry its own copy.
Nothing from Microsoft's effect pack is used.
