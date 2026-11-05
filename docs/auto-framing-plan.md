# Automatic framing for the front camera (Windows Studio Effects on Linux)

Plan written 2026-11-05, after the hardware ISP landed (PR #8, #9).

## 1. What Windows does

The IMX681 front camera is a 3844×2640 sensor with a very wide lens. Windows
never shows that whole field of view: Windows Studio Effects' *Automatic
framing* finds the face(s), crops a 16:9 window around them and follows them.
The wide lens is the headroom for that crop.

Facts from the Windows driver store of this machine
(`private/windows/driverstore-files.tsv`, `private/windows/inf/`):

- The feature ships as the **Microsoft Effect Pack** 3.0.8.0 (2026-01-16),
  `MicrosoftEffectPack.inf`, component IDs `MEP_CAM&VEN_8086_DEV_B03E` and
  `MEP_AUD&VEN_8086_VOICEFOCUS_V2`. `8086:B03E` is this machine's **NPU**
  (`00:0b.0`, `intel_vpu` on Linux): the pack is bound to the NPU, not the
  camera.
- `mep_camera_component.inf` registers `WindowsEffectsCameraMediaSource.dll`
  as a **Custom Media Source** ("Windows Camera Effects", category
  `{1D813233-…}`) that wraps the physical camera. That is a man in the middle
  by design: apps open the effects source, the effects source opens the Intel
  camera.
- The models run in `PerceptionCore.dll` (3 MB) with assets in
  `PerceptionCoreResources.dll` (53 MB) through `ps-onnxruntime.dll`,
  `onnxruntime_providers_openvino.dll`, `openvino.dll` and
  `openvino_intel_npu_plugin.dll`. So: **ONNX → onnxruntime → OpenVINO → NPU**,
  the exact stack Arch ships (`openvino`, `openvino-intel-npu-plugin`,
  `onnxruntime-cpu`, `intel-npu-driver`) and that is installed here.
- Windows 11 has a camera DDI for exactly this crop,
  `KSPROPERTY_CAMERACONTROL_EXTENDED_DIGITALWINDOW` (flags `MANUAL` and
  `AUTOFACEFRAMING`, window in Q24 fixed point, only while streaming), so
  the ISP can do the crop and scale for the effects source. Whether Intel's
  Panther Lake camera driver implements it on this unit is **not verified**
  (nothing in the INFs; the `.sys`/DMFT strings were not searched).

What we do *not* do: extract or run Microsoft's models. They are Microsoft's,
they live as encrypted assets in a DLL, and they are not needed: face
detection is a solved open problem (YuNet, LGPL-free Apache-2.0 model, already
installed by `irlume` for face unlock). The thing worth copying from Windows
is the **behaviour**, which we reimplement from observation, and the
**architecture** (effects source in front of the camera, detector on the NPU,
crop in the ISP), which maps 1:1 onto what we already have.

## 2. What we already have (measured 2026-11-05)

| Piece | State |
|---|---|
| Man-in-the-middle point | `v4l2-relayd@sp12-front`: `icamerasrc device-name=imx681-uf ! NV12 1080p ! videoconvert` → appsrc → `v4l2sink` on the loopback "Surface Front Camera ISP". The source description is a `gst_parse_launch` string, so any element can be inserted. |
| Face detector on the NPU | YuNet (`/usr/share/irlume/models/face_detection_yunet_2023mar.onnx`) reshaped to 320×320 through OpenVINO: **NPU 0.42 ms/frame, GPU 0.63 ms, CPU 1.4 ms** (scratch `npu_yunet_bench.py`). Compile time 0.3 s. |
| Full-resolution source | The Windows graph file has NV12 outputs up to **3840×2160** and 2560×1440 for the IMX681 (graph 100002, the one we run). The HAL profile `isp/config/sensors/imx681-uf.json` lists only up to 1920×1080; icamerasrc's caps come from the HAL's `getSupportedStreamConfig`, so adding the size to the profile is enough. 3840 wide is the whole 3844-pixel sensor: no detail is lost before the crop. |
| Hardware crop/scale | Intel's HAL has `Parameters::setZoomRegion(camera_zoom_region_t{left,top,right,bottom,ratio,rotate})`, consumed per frame by `Dvs::handleEvent` → `IntelCca::updateZoom` → `runDVS` → the **GDC** kernel. It needs a graph with a GDC node: **100003** (`LbffBayerWithGmv` + `SwGdc`), selected by `video-stabilization-mode=on` in icamerasrc when the profile lists `supportedVideoStabilizationModes: ["ON"]`. icamerasrc exposes `crop`/`crop-x`/`crop-y` (static sensor crop) but **no zoom-region property**: a ~30-line icamerasrc patch. |
| Second output pin | Graph 100002 has two output formatters (`ofs_mp`, `ofs_dp`): a 1080p/4K main stream and a small display stream can run at once (icamerasrc `video_%u` request pads). Not needed if the detector runs on a downscaled copy of the main stream. |
| Software crop cost | `videocrop` + `videoscale` of 4K NV12 → 1080p: **≈1.7 ms/frame on one core** (150 frames, `videotestsrc` baseline subtracted), i.e. ~5 % of a core at 30 fps. GL path (`glupload`/`glcolorscale`, DMABuf from icamerasrc) available if wanted. |
| Prototyping | PyGObject + GStreamer 1.28, OpenVINO and OpenCV 5 C++ headers, `python-openvino`, recorded IMX681 frames under `private/camera/frames/`. No `python-opencv`, no `gst-python`. |

## 3. Target architecture

```
IMX681 3844×2640 ─CSI─▶ ISYS ─▶ Intel HAL / PSYS ─NV12 3840×2160─▶ icamerasrc ─▶ sp12autoframe ─▶ v4l2-relayd ─▶ loopback ─▶ PipeWire / apps
                                        ▲                                              │  1080p out
                                        │ zoom-region (stage 3)                        ├─ detector: NV12 → 320×320 → YuNet on NPU (OpenVINO), every frame or every 2nd
                                        └──────────────────────────────────────────────┤─ controller: faces → target box → smoothed window (dead zone, rate limits, hold)
                                                                                       └─ cropper: stage 1 CPU, stage 2 GL, stage 3 none (PSYS GDC does it)
```

`sp12autoframe` is a GStreamer element (C++, `GstBaseTransform`), shipped in
`sp12-flex-tools` or its own package, with properties `enable`, `mode`
(`off|single|group`), `max-zoom`, `headroom`, `speed`, `hold-time`, and a
control socket or D-Bus name so a tray toggle (Omarchy plugin, like
`sp12.nfc`) can switch it live. Off = passthrough of the full 16:9 field of
view, scaled, which is what we deliver today.

The IR camera, face unlock and the rear camera are untouched. The rear camera
could get the same element later (it has the same 4K output set).

## 4. Behaviour to reproduce (the actual reverse engineering)

Observed Windows behaviour to confirm on the Surface Pro 11 (or a Windows
boot of this unit) before tuning; write the numbers into `sp12autoframe`'s
defaults:

- **Target**: a 16:9 box around the dominant face (single) or the union of
  faces (group), with headroom above the face(s) and a margin that keeps
  shoulders in; Windows frames roughly head-and-shoulders, not head-only.
- **Zoom limit**: Windows stops zooming in at about 2×; with a 3840-wide
  source and a 1080p output, 2× is still a native-resolution crop. Allow a
  configurable extra upscale (default none).
- **Dead zone**: the window does not move for small head motion; it re-frames
  when the face leaves a tolerance band (~10–15 % of the window) or its size
  changes by more than a ratio.
- **Motion**: pan and zoom ease in and out over roughly a second (critically
  damped spring or exponential smoothing with rate limits), never jump. Pan
  and zoom are limited so the window stays inside the source.
- **Hold**: on lost detection the window stays for several seconds, then
  eases back to the full field of view. Detection flicker must not cause
  motion (hysteresis on face presence).
- **Multi-person**: switching between single and group framing is slow and
  hysteretic; a face has to be stable for a while before it widens the shot.

## 5. Work plan

Each stage ends in a go/no-go. Stages 1–2 need the user in front of the camera
(chime first; timed tests only when they say ready).

### Stage 0: offline (no camera)
- Decide and document the framing rules above as tunables (§4).
- Python prototype of detector + controller on the recorded IMX681 frames
  and on a synthetic moving face, plotting window position over time, to
  settle the smoothing before anything touches the relay.
- Go: controller output is smooth and bounded on the synthetic track.

### Stage 1: software framing in the relay — done 2026-11-05 (dev install)
- `3840x2160` and `2560x1440` added to `imx681-uf.json`; icamerasrc
  negotiates 4K and the PSYS delivers it at 30 fps on the first try.
- `sp12autoframe` (`autoframe/`): NV12 4K in, NV12 1080p out, YuNet on the
  NPU through OpenVINO (falls back to GPU, CPU), the controller from stage 0,
  OpenCV crop + scale on the two planes. Dev install: `autoframe/install-dev.sh`
  (plugin, model, HAL config copy and relay drop-in under
  `/opt/sp12-autoframe-dev`); toggle: `sp12-autoframe auto|off`.
- Found on the way: the relay unit's `DevicePolicy=closed` list lacks the
  NPU (`char-accel`), so OpenVINO silently fell back to the GPU; OpenCV's
  thread pool spent 13 workers × 2.5 % on a 2 ms resize (`cv::setNumThreads(1)`);
  `INTER_AREA` at non-integer ratios is the slow generic path (8 ms for
  4K→1080p), so linear below 2×; the detector input is letterboxed to an
  integer ratio (320×180 in 320×192).
- Measured (450–600 live frames, relay process): framing on **25 %** of a
  core, framing off 20 %, the untouched 1080p rear relay 13 %. The element
  itself: detect 1.4 ms (every 2nd frame) + crop/scale 1.7 ms per frame ≈ 9 %.
  The other ~7 points are the 4K path in the HAL/icamerasrc. Over the plan's
  15 % target; stage 2's GL path or a 1440p source would bring it back.
- Go (visual): the saved frames show a head-and-shoulders crop at 1.3×
  from the 4K wide field, the Windows look.

### Stage 2: polish and controls
- Done 2026-11-05: control file + `sp12-autoframe` (mode, face fraction,
  zoom cap, headroom, speed, hold), settings saved per user and restored at
  login by a user unit; package `sp12-autoframe` 0.1 (plugin, model from
  OpenCV Zoo at a pinned commit, relay environment file + unit drop-in,
  tmpfiles) installed in place of the dev install.
- Done 2026-11-05: Omarchy bar widget `sp12.autoframe` (toggle, presets,
  every setting as a slider, boxes overlay, reset), package 0.2 with a
  `sp12-camera-hal>=2025.12.10-3` constraint.
- `off` is the full field of view scaled from 4K, not bit-identical to the
  former 1080p relay output (the ISP scales 3844→3840 differently); fine.
- GPU crop/scale: **tried and dropped 2026-11-05.** `vapostproc` (iHD VPP)
  with `GstVideoCropMeta` works, but 4K system-memory frames have to be
  copied into a VA surface and the 1080p result copied back for the loopback
  device (which cannot import GPU buffers): 3.3 ms CPU per frame plus ~17 ms
  of wall time against 1.8 ms for the CPU crop+scale (300 frames,
  `videotestsrc` baseline subtracted). Only the ISP-side crop (stage 3)
  removes the cost.
- Detector cadence (every 2nd frame) and the 640×360 display pin as an
  alternative detector input if the downscale is the expensive part.
- Go: survives suspend/resume and relay restarts; off/auto switch is seamless.

### Stage 3: crop in the ISP, as Windows does — in progress 2026-11-05

Findings that replaced the original plan for this stage:

- **Graph 100003 is out.** Its GDC (`SwGdc`, `gdc7_1`) is a *software* node
  (`NodeTypes::Sw`) fed from the BBPS output pins; the Linux HAL has no
  implementation for Sw nodes, so the stabilisation graph cannot run at all,
  and even on Windows the warp is not done by the ISP. The `Dvs` code path
  (`setZoomRegion` → `ia_dvs`) is therefore dead on Linux.
- **The real path is PTZ inside graph 100002.** `camera_zoom_region_t`
  (active-array pixels) → `PipeManager::updateZoomSettings` → normalised
  pan/tilt/zoom, the region widened to the sensor aspect → `GraphConfig::
  updateGraphSettingForPtz` → `GraphResolutionConfigurator::
  updateStaticGraphConfig` → `updateRunKernelOfScalers`: the BBPS output
  scaler/cropper run kernels get new crops → `IntelCca::
  updateConfigurationResolutions` → the AIC recomputes the kernel payloads.
  Per request. The "zoom key resolutions" in the graph file (1920×1080,
  1280×720, 640×360) are the thresholds at which the kernel configuration
  variant changes.
- **Three gaps closed by `isp/patches/hal-zoom-region.patch`:**
  1. `ParameterConvert::setParameters` never copied the zoom region into the
     per-request `DataContext` (one line).
  2. `updateZoomSettings` called a region "centred" when centred on *either*
     axis (`||`), which turns a pan into a centred zoom; now both (`&&`).
  3. `updateRunKernelOfScalers`: a window exactly the output size (a 2× zoom
     of this sensor is a 1:1 1920-wide crop) took the pass-through branch,
     whose final cropper always centred; it now crops at the ROI.
- **`icamerasrc` `zoom-region` property** (`isp/patches/icamerasrc-zoom-region.patch`):
  `"left,top,right,bottom"` in active-array pixels, applied while streaming
  (`camera_set_parameters`); `0,0,0,0` is ignored by the HAL, the full view
  is `0,0,3844,2640`.
- **Verified on hardware** (`autoframe/tools/zoom-region-test.py`, dev HAL,
  root because the HAL's SysV shared-memory segment belongs to the relay):
  centred 2× zoom, two-axis pan, a corner window and the return to full view
  all land where sent, at 1080p from the ISP, no 4K frame anywhere.
- **Element `mode=isp`**: passes 1080p through, runs the detector on the
  output, maps detections into active-array coordinates through the window
  sent `isp-latency` frames earlier, keeps the window's sensor-aspect
  extension inside the array (`extend_aspect` in the controller), and sets
  `zoom-region` on the upstream icamerasrc only when the window moved ≥ 2 px.
- Packaging: `sp12-camera-hal` pkgrel 4 carries both patches (the PKGBUILD
  now applies `hal-*.patch` to the HAL and `icamerasrc-*.patch` to
  icamerasrc); `autoframe/install-isp-dev.sh` installs it with the element in
  ISP mode for the live test.

Measured with the packaged stack (sp12-autoframe 0.3, HAL pkgrel 4), 300
live frames: relay **17 %** of a core (crop mode was 25 %, the plain 1080p
relay 13 %), detector 0.7 ms per frame on the NPU, crop 0 ms. Still to
measure: the HAL's apply latency (`isp-latency`, default 2 frames) and the
AIC recompute cost while the window moves.

## 6. Risks and open questions

- **4K through PSYS** at 30 fps on the IMX681 is in the Windows graph file
  but untested on our converted settings (only 1080p and 720p were run).
- **PSYS/HAL per-frame zoom** (stage 3) rides on closed `ia_dvs`; if its
  region semantics or its update latency are bad, stage 2 is the end state
  and that is fine.
- **NPU contention**: the NPU is otherwise idle on this desktop; `irlume`
  (face unlock) uses the CPU. If both ever run at once, YuNet on the NPU is
  0.4 ms so it does not matter.
- **Licensing**: YuNet (Apache-2.0) and our code (MIT) are redistributable.
  Nothing from the Microsoft Effect Pack is used. The HAL profile change is
  part of the private `sp12-camera-hal` inputs like the rest.
- **Surface Pro 11**: same idea, different pipeline (CAMSS/libcamera); the
  element and controller are reusable, the source and crop stage are not.
