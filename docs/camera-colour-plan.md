# Front camera colour: closing the gap to Windows

Branch `camera-tuning`. Started 2026-11-06 after the low-light work
(`docs/auto-framing-plan.md` §6, PR #15) brought brightness close to Windows.

## Where we are

Same room, Windows Camera app in video mode with automatic framing against
the hardware-ISP relay (1080p, crop mode):

| | Windows | Linux |
|---|---|---|
| Mean level | 175 | 141–158 |
| Mean saturation (HSL) | 61 | 31–35 |
| White wall R,G,B | 244, 215, 182 (warm) | 170–189, 160–190, 149–185 (near neutral) |

Our AWB removes most of the room's warm cast and saturation is about half.
Faces come out greyish; Windows renders them warm and bright.

## Ruled out: the second module calibration

The IMX681 extension package carries two tuning files:
`imx681_MSHW0740_PTL.aiqb` (the one we use) and
`imx681_MSHW0740_2nd_PTL.aiqb`. LISP (ISP tuning) is identical, LAIQ differs
in 124 bytes, LCMC (CCMs, white points, lens shading) is almost entirely
different: a second-source module calibration. ACPI only reports MSHW0740,
so which one Windows loads is decided at runtime.

A/B on Linux, back to back, fresh AIQ state each (frame 150 of 150):

| | first | `_2nd_` |
|---|---|---|
| Mean level | 158 | 157 |
| Saturation | 31 | 35 |
| Wall R,G,B | 170, 160, 149 | 174, 159, 145 |

The 2nd file is slightly warmer and more saturated, a small step next to the
gap to Windows. Not the cause; the packaged file stays.

## What Windows does that we don't (iacamera64.inf_amd64_a237…)

- `IntelDeviceMFT64.dll` (Intel's device MFT) runs a face detector,
  `centernet_tracking` (int8, OpenVINO/oneDNN on the GPU, models in
  `intelic.dll` + `intelic_data.bin`), which reports face boxes, head pose and
  a **skin tone** estimate, and feeds the faces into 3A
  (`CGen3FDNode::UpdateFaceInfo`, `UpdateFaceRoiForStatistics`). AE and AWB
  on Windows are face-aware.
- `GLTM_2_0` (global/local tone mapping 2.0) appears in the Windows CCA.
  **Correction (2026-11-06):** our Dec-2025 `libia_aic` has the `gltm_2_0`
  kernel too (the first search was case-sensitive). See "Newer Intel
  libraries" below for the real difference.
- `IntelDeviceMFT64.dll` also carries `nntm_1_0` (neural tone mapping,
  `CNntmNode`, `CSubwayV2NntmExecutor` on the GPU, face ROI input). It is a
  software node (`SwNntmOuterNode`) in Intel's graph descriptions, and none
  of the three graphs Windows ships for the IMX681 (100002, 100003, 100026)
  contains it, so it does not apply to this camera.
- `LensDistortionCorrection.dll` with `IMX681DeLoB35P3A5.json`: a lens
  profile plus `face_mode_undistortion_info` (ZoomRect, strength 0.5) and
  `scene_mode_undistortion_info` (Rectilinear, 0.0): face-region
  undistortion while framing. Geometry, not colour; relevant to automatic
  framing later.
- `libia_cp64.dll`: computational photography for stills (HDR/low light);
  explains part of the first 4K still comparison, not video.

## Face-based exposure (done 2026-11-06, HAL pkgrel 10, autoframe 0.7)

sp12autoframe sends its YuNet faces upstream as icamerasrc `face-regions`
(`l,t,r,b;...` in active-array pixels, 8 px steps, only on change, cleared
at stop and when `face-ae` is off). `isp/patches/icamerasrc-face-regions.patch`
passes them to `Parameters::setFaceRegions`; `isp/patches/hal-face-regions.patch`
converts them to IA coordinates in `CameraHal::setParameters` and stores them
in `AiqResultStorage` as `FaceDetectionPVL` would (`fd_algo = CENTERNET_FD`,
`is_video_conf`). The profile sets `"faceAeEnabled": true`.

A first build did nothing: `isFaceAeEnabled()` also needs a face detect mode
in `statistics.info.availableFaceDetectModes`, and advertising one makes
`CameraDevice` add the HAL's own face stream for the missing PVL detector.
`PlatformData::isExternalFaceAeEnabled()` (the profile flag alone) gates our
path and AiqEngine's read instead. gdb dprintf on the relay then showed 13
`setFaceRegions`/`updateFaceResult` and 114 `getFaceResult` (one per frame)
in 7 s.

Results, one stream, framing off, face AE off then on (`--face-ae`):

| | dim room (AE saturated) | backlit (lights behind) |
|---|---|---|
| Gain off → on | 960 → 960 | 168 → 705 |
| Face R,G,B off | 104, 86, 84 | 65, 45, 40 |
| Face R,G,B on | 106, 86, 85 | 99, 70, 63 |
| Frame mean off → on | 154 → 154 | 129 → 166 |

Backlit, the face comes up ~55 % (+0.6 stop) and the background goes brighter,
the trade Windows makes. In the dim room exposure (66 ms) and gain were both
at their maximum, so there was nothing to give. Face colour ratios did not
move: the AIQ uses the faces for AE, not visibly for AWB.

## Next steps

1. ~~**Face-aware 3A from our own detector.**~~ Done (above). Original note: The Linux HAL already has the
   path: `faceAeEnabled` in the sensor profile makes `AiqEngine` pass
   `AiqResultStorage::getFaceResult()->ccaFaceState` to the AIQ
   (`statsParams->faces`). Only Intel's closed PVL detector fills it
   (`FaceDetectionPVL::updateFaceResult`, `is_video_conf = true`), and PVL
   is not in the Linux release. sp12autoframe already finds faces with YuNet
   on the NPU; hand them to the HAL (an icamerasrc property in the same style
   as `zoom-region`, written by the element each detection) and enable
   `faceAeEnabled`. Measure face level and skin colour against Windows.
2. **Tone mapping version.** Check whether the 2026-09 `ipu7-camera-bins`
   carry GLTM 2.0 and read the `0x110` record; that route needs the graph
   files converted to the newer header (hardware ISP plan, stage 4).
3. Only then consider colour preferences (saturation/AWB bias) as our own
   tuning on top.

## Newer Intel libraries (branch `camera-libs-2026-09`)

Intel published two releases after the one we run (HAL `e5172cc` +
bins `ed16ac7`, 2025-12-10): 2026-06-29 and 2026-09-26 (HAL `30ad691`,
bins `0525cdf`, 95 HAL commits).

- **Tuning records.** The 2026-09 HAL ships example `.aiqb` files (OV05C10,
  OV8856) whose LAIQ record versions are exactly those of the Windows IMX681
  file: `0x103` 106, `0x104` 107, `0x105` 124, `0x108` 103, `0x10c` 107,
  `0x110` 100. The Dec-2025 example (OV13B10) is one step older on each and
  has no `0x110`. The 2026-09 AIQ is built for our tuning generation; the
  Dec-2025 one may skip those records.
- **Tone mapping.** In 2026-09, `gltm_2_0` and `glim_2_0` also take the GBCE
  results (`ia_aiq_gbce_results`) and a `gltm_glim_plc_adaptation` input;
  new kernels `nntm_1_2`, changed `b2b`, `remosaic_1_0`, `b2i_ds_1_1`.
- **Firmware.** bins 2026-09 carry a newer `ipu7ptl_fw.bin` (266240 ->
  274432 bytes). Ours comes from linux-firmware (2026-09-16).
- **Kernel.** Our PSYS port is from ipu7-drivers `484d713` (2026-10-21),
  which already includes the 2026-09-26 release; nothing to do there.

Plan:
1. Worktrees `work/hal-2609` and `work/bins-2609` at the 2026-09 tags, so
   the packaged build (`git archive HEAD` of `work/hal`, `work/bins`) is
   untouched.
2. Rebase the six HAL patches onto HAL `30ad691` (aic-timestamp,
   arch-jsoncpp, face-regions, sensor-absent-controls, sensor-orientation,
   zoom-region); some may be upstream by now.
3. Graph files: HAL `main` changed the binary prologue and added
   `isIsysUnpacked`/`additionalFeaturesBit` to the header, so the Windows
   graph settings need the new layout and hashes (`stamp-hashes.py`), and
   `isIsysUnpacked` may replace our `ifd` rewrite.
4. Build into the dev prefix and run with the current firmware first; if the
   new libraries need it, A/B Intel's 2026-09 `ipu7ptl_fw.bin` through
   `/sys/module/firmware_class/parameters/path` (no persistence).
5. A/B against the packaged stack: white wall, face, saturation, plus the
   Windows video screenshot. Package only if it wins.

### Result (2026-11-06): no colour change; the grey look is a range bug downstream

Done: worktrees `work/{hal,bins,icamerasrc}-2609`; all six HAL patches apply
to `30ad691` as they are, plus `isp/patches-2609/hal-no-boot-install.patch`
(the release installs sensor `*.img` to an absolute `/boot`).
`isp/tools/graph-to-2609.py` converts our e5172cc graph files to the new
layout (header 16 -> 40, graph header 116 -> 120 with `isIsysUnpacked = 1`,
`numberOfActualLinks`, LBFF `bxt_blc` 5 -> 6 and `b2i_ds_1_1` 5 -> 12 with
the new system API uuids 9649/51813 and `scaling_ratio = 0`, new hashes; values
checked against Intel's 2026-09 OV13B10/OV08X40 graphs). The 2026-09
`check-graph` resolves 968/968 IMX681 and 801/801 OV13858 settings.
`isp/build-dev.sh` takes `HAL`, `BINS`, `ICAMERASRC`, `BUILD`, `PREFIX`,
`GRAPHS`, `EXTRA_PATCHES`. The 2026-09 stack streams on the current firmware
with no new errors.

A/B, same scene, direct icamerasrc 1080p, 90 frames each, fresh AIQD, last
frame decoded as limited range:

| | package (Dec-2025) | 2026-09 |
|---|---|---|
| Mean level | 144.8 | 145.2 |
| Saturation (HSL) | 60.5 | 61.7 |
| Wall R,G,B | 211, 217, 202 | 212, 216, 202 |
| Face R,G,B | 96, 70, 77 | 95, 68, 76 |

No measurable difference: the newer AIQ does not change the rendering. Not
worth packaging for colour.

**The real finding.** Decoded correctly (limited range), the HAL output already
has the Windows saturation (60.5 vs 61). Decoded as *full* range it drops to
~40 with blacks at 12-14. The Snapshot photos show exactly that signature:
luma 1st percentile 16-20, 99th 193-222, where the correctly decoded HAL frame
spans 0-1 to 238-255. The platform is right: the loopback reports Rec. 709 /
ITU-R 601 / limited quantisation, `v4l2src` and `pipewiresrc` negotiate
`colorimetry=2:4:7:1`, and the PipeWire node advertises `colorRange 16-235`.
The error is in the app's rendering or saving (Snapshot 51, GTK 4.24,
gtk4paintablesink 0.15.4). Earlier "Linux" numbers that went through Snapshot
or `v4l2src ! jpegenc` understate saturation and contrast for the same reason.

Remaining real difference: white balance (our wall stays neutral/greenish,
Windows keeps the room warm).

Next:
1. Check what the apps that matter show live (Snapshot preview, the browser
   via getUserMedia) and decide where to fix: in the app (report upstream),
   or at the source (full-range output declared full range, which apps that
   ignore the flag would then show correctly, but apps that assume limited
   would over-contrast).
2. Re-measure the Windows comparison with correctly decoded frames.
3. AWB warmth: a preference, tune last.

### In the browser (2026-11-06)

`userspace/camera-check` (a local PWA, scripted with headless Chromium) on the
front ISP camera, 1080p, after AE settled: black level (1st percentile) 8,
white (99th) 254, saturation 63-64, white wall R/B 1.07. Chromium decodes the
limited-range stream correctly, and saturation matches Windows (61). The grey
look was Snapshot only; no source-side change. What is left against Windows
is white balance warmth (wall R/B 1.07 here, 1.34 on Windows).

### Face skin type and white balance (2026-11-06): no effect

Intel's CCAT has face-based white balance (`ia_ccat_set_wb_face_based`,
`awb_face_status`) and per-project switches in `ccat_project_adaption_bitmap`
(bit 1 "wb face_base", bit 6 "wfov skin tone alignment"); nothing in the HAL
sets that bitmap, so it would come from the tuning, which Windows and we
share. The faces we pass carry no skin data (`skin_type_validity` 0), where
the Windows tracker estimates a skin tone. Experiment (dev prefix only, hook
removed again): relay-style pipeline, faces from sp12autoframe, framing off,
three back-to-back runs with the skin fields unset, light (0) and dark (100):

| | none | light | dark |
|---|---|---|---|
| Wall R/B | 1.057 | 1.050 | 1.065 |
| Face R,G,B | 131, 97, 94 | 129, 97, 93 | 128, 95, 92 |

Within noise: AWB does not use the skin fields here. Not pursued.

Note: in the dev prefixes always re-run `isp/build-dev.sh`; a bare
`make install` reinstalls Intel's config over ours (sensor list and profiles)
and the HAL then reports "No sensors available".

Open: the Windows numbers were taken at a different time (08:00) and partly
on a different wall; a fair warmth comparison needs Windows and Linux
measured back to back under the same lights.
