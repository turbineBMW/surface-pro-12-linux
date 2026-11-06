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
- `GLTM_2_0` (global/local tone mapping 2.0) appears in the Windows CCA; none
  of our Dec-2025 Linux `libia_*` libraries carry that string. Likely tied to
  the LAIQ records newer than the Linux AIC reads (`0x110` is absent from the
  Linux reference file).
- `LensDistortionCorrection.dll` with `IMX681DeLoB35P3A5.json`: a lens
  profile plus `face_mode_undistortion_info` (ZoomRect, strength 0.5) and
  `scene_mode_undistortion_info` (Rectilinear, 0.0): face-region
  undistortion while framing. Geometry, not colour; relevant to automatic
  framing later.
- `libia_cp64.dll`: computational photography for stills (HDR/low light);
  explains part of the first 4K still comparison, not video.

## Next steps

1. **Face-aware 3A from our own detector.** The Linux HAL already has the
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
