# Hardware ISP (IPU7.5 PSYS) on the Surface Pro 12

Plan written 2026-11-04. It supersedes the "not viable for now" finding of
2026-09-24 in `peripheral-plan.md` Phase 7, which rested on two mistakes:
the Windows graph-settings files are *not* a different format, and the
7.4 `ipu6` driver already carries the PSYS plumbing for IPU7.

## 1. What PSYS is, and what is fixed

IPU7 has two halves. **ISYS** receives CSI-2 and writes raw Bayer frames to
memory; that is what we use today with libcamera's software ISP. **PSYS** is
the processing side: demosaic, denoise (spatial and temporal), lens shading,
CCM, scaling, NV12 output. Windows' picture quality comes from PSYS.

PSYS runs firmware from `intel/ipu/ipu7ptl_fw.bin`, the same file that already
authenticates on this machine for ISYS. The file contains both halves (strings
`psys_dispatcher_thread`, `psys_scheduler_thread`, `psys.met`); its PSYS build
is **1.2.1.251215214352** (linux-firmware 20260916). The firmware is signed, so
we cannot change it, but we can drive it: Intel's GPL driver publishes the whole
host↔firmware message ABI (`ipu7_fw_msg_abi.h`: dev open, graph open with nodes
and links, task request, task done).

What the firmware does **not** know is what to do: it schedules a *graph*
(which processing blocks, how linked) and passes each block an opaque
*payload* (parameter blob). Both are produced in userspace by Intel's closed
AIC/AIQ libraries from two per-sensor data files:

| File | What it holds | Who makes it |
|---|---|---|
| `graph_settings_<sensor>.bin` | per output resolution: the graph id, the per-kernel resolution/crop/stride info and "system API" blobs | Intel's graph tooling (not public) |
| `<sensor>.aiqb` (CPFF container) | tuning: CMC (sensor characterisation, CCMs, white points), AIQ algorithm records, ISP records | Intel IQ Studio, per module, by the OEM |

We have both for the IMX681 and the OV13858 (and the VD55G0) from Windows
(`private/windows/drivers/*_extension.inf_*`). Whether those files can be fed
to Intel's Linux stack is the whole question, and the answer is now "yes, with
a conversion that others have already done for another Panther Lake laptop".

## 2. Prior work (survey 2026-11-04)

- **Galaxy Book6 Ultra, SC200PC on IPU7.5 (Marco Glauser).** Ran a Panther
  Lake sensor through PSYS with Intel's Linux HAL using only the **Windows**
  `graph_settings_*.bin` and `.aiqb`, converted at build time
  ([intel/ipu7-camera-hal#74](https://github.com/intel/ipu7-camera-hal/issues/74),
  code: [MarcoGlauser/galaxybook6-ultra-camera](https://github.com/MarcoGlauser/galaxybook6-ultra-camera),
  GPL-2.0). Needed: (1) stamp the file with the Linux release's hash codes;
  (2) rebuild its DOL graph 100032 as the linear graph 100002 (not needed for
  us, see §3); (3) rewrite the input-feeder (`ifd`) words from packed RAW10 to
  the unpacked 16-bit lines the in-tree ISYS delivers, without which "the PSYS
  accepted the first task and never completed it, with no error"; (4) swap
  three LAIQ tuning records whose version the Dec-2025 Linux AIC doesn't read;
  (5) two small HAL patches (Bayer order acceptance, AIC timestamp). Result: a
  usable picture with plausible colour, noisier than Windows in low light.
  Stack: HAL `e5172cc` (PTL release 2025-12-10), `ipu7-camera-bins` `ed16ac7`,
  `icamerasrc` `4fb31db`, Ubuntu's `intel-ipu7-psys` module, firmware PSYS
  1.2.1.251215214352: **the same firmware build we have.** Delivery is
  `icamerasrc` → `v4l2-relayd` → v4l2loopback, on demand.
- **Surface Pro 7+ on IPU6 (dmanresa-saes/surface-ipu6-cameras).** The first
  documented PSYS pipeline on a mainline kernel: Intel's `ipu6-drivers` PSYS
  module built *on top of* mainline `intel-ipu6` (it binds the orphan
  `intel_ipu6.psys` auxiliary device), Intel's HAL with the OEM `.aiqb` from
  the Surface driver MSI. Findings that transfer: Intel's HAL only ever tested
  GRBG sensors (three one-line patches for BGGR); the OEM black level had to
  be divided by 4 because Windows' ISYS delivered RAW10 aligned to 12 bits
  while mainline is LSB-aligned; `.aiqb` CMC records decoded
  (`tools/decode_aiqb.py`, same record chain we already parse for our AWB).
  Also [ConsultingFuture4200/sp7-camera](https://github.com/ConsultingFuture4200/sp7-camera)
  has a CPF/AIQB → JSON decoder.
- **jibsta210/ipu7-camera-linux (Dell XPS 16, OV08X40).** A libcamera
  pipeline handler that drives PSYS *directly* through `/dev/ipu7-psys0`
  (graph open, ISA + OFS tasks), with the per-terminal payloads **captured**
  from Intel's HAL by an `LD_PRELOAD` ioctl interceptor (`tools/capture_psys.c`)
  at 1080p and 4K, and a software AE loop. No AWB, static parameters, one
  sensor. Author's own tests only; no third-party confirmation found. The
  author states the payloads "cannot be reverse-engineered by simple
  resolution substitution" (internal strides and offsets). Useful to us as the
  capture tool and as proof that the `ipu7-psys` UAPI can be driven without
  the HAL.
- **kervel/libcamera `ipu6-pipeline-handler`** (packaged on the AUR as
  `libcamera-ipu6`): a libcamera pipeline handler that is a thin shim over
  Intel's closed `libcamhal`, so PipeWire sees the HAL camera natively instead
  of through a loopback. IPU6 only; nobody has adapted it to IPU7.
- **Intel.** `ipu7-drivers` PSYS is GPL, 2850 lines, builds only PSYS on
  kernels ≥ 6.17 against the *staging* `intel_ipu7` core, and has no patch set
  for 7.4 (dirs up to `v7.0.0_iot`). [PR #120](https://github.com/intel/ipu7-drivers/pull/120)
  (open) fixes the struct-layout corruption we hit (issue #63/#93) by moving
  the two fields into `struct ipu7_psys`. The 7.4 `ipu6` driver that now
  claims IPU7 contains `ipu7_psys_buttress_ctrl`, creates the `psys` auxiliary
  device, maps its firmware, and exports `ipu7_buttress_wakeup_psys` and
  `ipu6_ipu7_boot_*`, so Intel is preparing PSYS on the `ipu6` core. No PSYS
  series was found on linux-media; lore.kernel.org refused our fetches (403),
  so that is unverified, as is the maintainers' stance on a PSYS driver whose
  only userspace is closed.
- **Arch/AUR today:** `intel-ipu7-camera-bin`, `intel-ipu7-camera-hal-git`,
  `intel-ipu7-dkms-git` (all pinned to Intel's 2025-09-28 releases), Omarchy's
  `intel-ipu7-camera` (OV08X40 only), and jibsta210's `libcamera-ipu7-ov08x40`
  set. None covers our sensors or kernel 7.4; we will build our own pins.

## 3. Facts established on our files (2026-11-04)

Parsed with the HAL's own `StaticGraphBinaryAutogen.h` layout (scratch
scripts, to be committed under `private/camera/psys/`):

| | `graph_settings_imx681_MSHW0740_PTL.bin` | `graph_settings_OV13858_MSHW0741_PTL.bin` |
|---|---|---|
| size | 4 572 356 | 3 790 360 |
| layout | HAL `e5172cc` (116-byte `GraphConfigurationHeader`, 16-byte `BinaryHeader`) | same |
| common hash | 1550038503 (`0x5c63b5e7`, the value I misread as a format marker) | same |
| settings | 968, all 30 fps | 801, all 30 fps |
| graphs used | **100002** ×484, 100003 ×483, 100026 ×1 | 100002 ×400, 100003 ×400, 100026 ×1 |
| sensor modes | 1: **3844×2640**, no crop, no scaling | 1: **4076×2806**, no crop, no scaling |
| NV12 outputs | 640×360 … 1920×1080, 1920×1440, 2560×1440, 3840×2160 | same set |

- Graph **100002** is `Isys → LbffBayer → BbpsWithTnr` (15 links): the standard
  linear graph Intel's own Linux files use. **100003** adds `LbffBayerWithGmv`
  and `SwGdc` (stabilisation, 20 links). **100026** (one setting) is the raw/
  PDAF variant. There is **no DOL graph**, so the Galaxy Book's graph rebuild
  (its step 2) is not needed; only the hash stamping and the `ifd` rewrite are.
- Hash codes to stamp, HAL `e5172cc`: common **1110027246**; 100002
  **2257098455**; 100003 **835453801**; 100026 **4190204929**. (Current HAL
  `main`, 2026-09-26 release: common 929000173, 100002 4223092366, 100003
  198891660, 100026 3485835604, but `main` also changed the binary prologue and
  added `isIsysUnpacked`/`additionalFeaturesBit` to the header, so the Windows
  files no longer match its layout. Start on `e5172cc`.)
- The IMX681 sensor mode (3844×2640) is exactly what our `imx681` driver
  outputs. The OV13858 mode (4076×2806) is **not** in the mainline `ov13858`
  driver (4224×3136, 2112×1568, 2112×1188); it is a crop that Windows'
  `ov13858.sys` mode table will give us, as `imx681.sys` did.
- `.aiqb` (CPFF, sections LCMC/LAIQ/LISP/LTHR): both of ours carry LAIQ record
  versions one step newer than the Linux `OV13B10_09B13_PTL.aiqb` at `e5172cc`:
  `0x103` 106 vs 105, `0x104` 107 vs 106, `0x105` 124 vs 122, `0x108` **103 vs
  102**, `0x10c` 107 vs 105, plus `0x110` (absent in the Linux file). This is
  the same situation Glauser hit (his `0x108` v103 wasn't read by the Dec-2025
  AIC), so expect to need his record swap, or the 2026-09 `ipu7-camera-bins`.
- Kernel 7.4 `ipu6` core: `ipu6_psys_init()` creates the `psys` auxiliary
  device with `ipu7_psys_buttress_ctrl`, its MMU, and its firmware
  (`isp->psys->fw_sgt`, `pkg_dir`). Exported for a PSYS module:
  `ipu6_dma_{alloc,free,map_sgtable,unmap_sgtable,sync_sgtable}`,
  `ipu6_mmu_hw_{init,cleanup}`, `ipu6_ipu7_boot_{start_fw,stop_fw,get_state}`,
  `ipu6_ipu7_{init,release}_boot_config`, `ipu7_fw_com_{get_queue_config,
  get_token,put_token}`, `ipu7_buttress_{wakeup_psys,get_psys_freq}`. Intel's
  PSYS module calls `ipu7_dma_*`, `ipu7_mmu_hw_*`, `ipu7_boot_*`,
  `ipu7_syscom_{get,put}_token`, `ipu7_bus_get_drvdata`: a near 1:1 mapping.
- `ipu6` ISYS already offers **packed** RAW10 (`V4L2_PIX_FMT_SRGGB10P` etc.),
  which is what the Windows `ifd` configuration expects. That gives a second
  option to the `ifd` rewrite (§5, stage 3).

## 4. Target architecture

```
IMX681 / OV13858 ─CSI─▶ IPU7.5 ISYS (ipu6, in-tree) ──raw──▶ Intel camera HAL ──▶ PSYS (our DKMS module, GPL)
                                                       (closed AIC/AIQ + .aiqb + graph)   │ firmware (signed, present)
                                                                                           ▼
                                                                    NV12 ──▶ icamerasrc ──▶ v4l2-relayd ──▶ v4l2loopback ──▶ PipeWire
VD55G0 (IR) ─CSI─▶ ISYS Capture 8 ──▶ /dev/sp12-ir ──▶ facelock / irlume   (unchanged; PSYS not involved)
```

Each RGB camera is driven by either the HAL (PSYS) or libcamera (soft ISP),
not both at once; the choice is per camera and switchable. The IR path stays
as it is. Face unlock does not gain an RGB device from this (irlume refuses
loopback devices by design), which corrects the Phase 7 text.

## 5. Work plan

Each stage ends in a go/no-go. Stages 0–3 are the proof of concept.

### Stage 0: offline checks (no hardware)
- Commit the graph/aiqb parsers under `private/camera/psys/`.
- Port Glauser's `patch-hashes.py` to our three graph ids and stamp both files.
- Build the HAL's `StaticGraphReader` (`modules/ipu_desc/ipu75xa`, Apache-2.0)
  standalone, as his `check-graph.cpp` does, and verify that every setting of
  both stamped files loads (`GetStaticGraphConfig` for each header key).
- Decode both `.aiqb` (CMC black level, white points, CCMs) with the Surface
  Pro 7+ tool and compare with the values Phase 7B already extracted; note the
  black-level alignment question (IPU6: ÷4) for stage 4.
- Extract the OV13858 4076×2806 mode from `ov13858.sys` (as `0015` did for
  the IMX681): line length, frame length, PLL, crop registers.
- Go: all settings load; the sensor-mode and stride numbers are consistent.

### Stage 1: PSYS kernel module on the 7.4 `ipu6` core
- Take `intel/ipu7-drivers` `drivers/media/pci/intel/ipu7/psys/` (+ PR #120's
  change to keep `acquire_fw_task_buffer_lock`/`get_running_fw_task_count` in
  `struct ipu7_psys`) and port it to the `ipu6` exports above as a new DKMS
  module (`intel-ipu6-psys` or `sp12-psys`), binding the `intel_ipu6.psys`
  auxiliary device like the Surface Pro 7+ module does on IPU6. Needs the
  private `ipu6` headers, which no headers package ships: bundle them from
  `~/Projects/linux-7.4` with a version check, as `dkms/prepare-sources.sh`
  already does for our patched sources.
- Fallback if the port stalls: boot the staging driver
  (`intel_ipu6.force_no_probe_ipu7=1 intel_ipu7.force_probe=1`) with Intel's
  module as is plus PR #120. Our pre-7.4 ISYS patches (`dkms/patches/`) apply
  there.
- Fix `ipu7_resume()`'s "Failed to get runtime PM" (Phase 4) on the way: with
  a PSYS driver bound it becomes real.
- Go: `/dev/ipu7-psys0` exists, `IPU_IOC_QUERYCAP` answers, a `dev_open`
  reaches the firmware and is acked, suspend/resume survives with the module
  loaded (jibsta210 reports `psys_suspend()` returning `-EBUSY` while a
  pipeline is live; check).

### Stage 2: Intel's userspace on Arch
- PKGBUILDs under `pkg/`: `ipu7-camera-hal` at `e5172cc` (with the Galaxy Book
  `hal-e5172cc.patch` rebased, minus the SC200PC bits), `ipu7-camera-bins`
  `ed16ac7` (redistributable binaries per its licence), `icamerasrc` `4fb31db`,
  `v4l2-relayd`, `v4l2loopback`.
- Sensor profiles `imx681-uf.json` and `ov13858-wf.json` from `ov13b10-uf.json`
  / `sc200pc-uf.json`: our entity names under `ipu6` are `Intel IPU7.5 CSI2 N`
  and `Intel IPU7.5 ISYS Capture N` (the HAL templates say `Intel IPU7 …`),
  I²C bus and CSI port from our media graph, `iSysRawFormat`, link frequency,
  `graphSettingsFile` and `supportedTuningConfig` pointing at the converted
  files. Both cameras share the `ipu6` ISYS with libcamera and the IR path;
  the PHY coupling of `0028` (rear port 0 vs IR on PHY 1) still applies.
- Go: `icamerasrc` enumerates both sensors and opens the ISYS stream (raw
  frames flow even before PSYS is right).

### Stage 3: first PSYS frame, front camera first (sensor mode matches)
- Input packing, two options, try in this order:
  1. Keep the Windows `ifd` words (packed RAW10, 25 px per 32 bytes) and have
     the HAL capture `V4L2_PIX_FMT_SRGGB10P` from ISYS. Smallest change to the
     graph; needs the HAL's V4L2 layer to accept a packed format.
  2. Glauser's `linuxize()`: rewrite stride/bpp words to unpacked 16-bit lines
     (stride `((3844*2)+63)/64*64 = 7744`, height 2640), set the BBPS output
     link to streaming mode / stream id as Intel's 100002 graphs do, resize the
     ISYS link buffer. Proven on his hardware.
- Bayer phase: the Windows graphs were generated for Windows' IMX681 setting
  (mirrored, GRBG); our driver outputs RGGB (`0013`). Expect to either shift
  the LBFF input crop by one column (Glauser shifted one row for BGGR→GRBG) or
  teach the HAL the mapping (`isSameStreamConfig`). The Surface Pro 7+ BGGR
  patches show where the HAL assumes GRBG.
- Go: NV12 1080p frames at 30 fps with plausible colour, from `icamerasrc`.

### Stage 4: tuning and quality
- `.aiqb` as is first. If the AIC rejects or ignores the v103 `0x108` record,
  swap `0x108`/`0x104`/`0x10c` from the Linux `OV13B10_09B13_PTL.aiqb` with
  `aiqb-laiq-swap.py` (fixes the LAIQ and file checksums), and note that those
  are then another sensor's algorithm records.
- Black level: measure the dark pedestal at the ISYS output (expect ~64 at 10
  bits for the IMX681) against the CMC record; apply the ÷4 only if Windows'
  value is 12-bit aligned as on IPU6.
- Measure against the soft ISP and against Windows: `dashscore`/`gridscore`,
  `noise-measure.py`-style temporal noise at 16× gain, blind A/B colour as in
  Phase 7B. Keep the soft ISP if PSYS does not win clearly.
- Try the 2026-09 `ipu7-camera-bins` + HAL `main` only if tuning records block
  us: it needs the graph files converted to the new prologue/header, and
  `isIsysUnpacked` would then replace the `ifd` rewrite.

### Stage 5: rear camera
- Add the 4076×2806 mode to `ov13858` from stage 0's extraction (new `0029`),
  with its link frequency; the HAL profile selects it.
- Repeat stage 3/4. OV13858 is GRBG in the mainline driver, which is the HAL's
  native case.

### Stage 6: integration
- On-demand `v4l2-relayd@sp12-{front,rear}` units (the HAL only runs while an
  app holds the loopback); WirePlumber rules to hide the raw ISYS nodes and to
  name the loopbacks "Built-in Front/Back Camera (ISP)"; keep the libcamera
  soft-ISP cameras available, or disable them per camera via the existing
  `environment.d` switch.
- Suspend/resume with a pipeline live; kernel updates (DKMS header bundle);
  `pipewire`/`wireplumber` upgrade notes as for the libcamera plugin.
- Optional: adapt the kervel `libcamhal` shim pipeline handler to the IPU7 HAL
  so PipeWire gets the camera without a loopback (removes v4l2-relayd and the
  "Virtual Camera" naming problem).

### Stage 7 (research, open-ended): an open PSYS userspace
Only after stages 0–6 work, since it needs a running closed stack to learn
from. Capture every terminal payload at the ioctl boundary (jibsta210's
interceptor), vary one tuning parameter at a time and diff, and build an
encoder per kernel in a libcamera pipeline handler + IPA, as libcamera did for
IPU3 and rkisp1. Nobody has started this for IPU6/7; months of work; the
payload format is undocumented by design. Decide then whether it is worth it.

## 5a. Progress

**Stage 0 done (2026-11-04).** `private/camera/psys/stamp-hashes.py` stamps
the e5172cc hashes (3,888 bytes change per file). The HAL's own
`StaticGraphReader`, built standalone from `modules/ipu_desc/ipu75xa` with
`-DIPU_SYSVER_ipu75 -DGRC_IPU75XA` (`private/camera/psys/check-graph.cpp`),
resolves **every** configuration: IMX681 968/968 (100002 ×484 at 14 active
links, 100003 ×483 at 17, 100026 ×1), OV13858 801/801 (400/400/1). The HAL
queries with `fps = 30`, `attributes` from the sensor, and the first two
video streams as preview/video at bpp 8 (`GraphConfig::queryGraphSettings`),
so the 30 fps-only files fit. OV13858: Windows' `ov13858.sys` holds the
4076×2806 mode (`private/camera/psys/ov13858-modes.py`, 16-byte entries
`{u32 1, u16 addr, u16 0, u32 val, u32 0}`): the mainline 4224×3136
register set with window 64..4191 × 160..3007, output 4076×2806, offsets
26/21, `0x3820 = 0xb0`, same HTS 1122 / VTS 3214 (a 15 fps twin has VTS
6418), so it is a 30 fps crop we can add on the mainline 1080 Mbps PLL
(Windows runs PLL1 `0x0300=5 0x0301=1 0x0302=0xee`, a higher rate, and
clears bit 5 of `0x5000` in every mode; note both for stage 5). The
Surface Pro 7+ `.aiqb` decoder reads only the first CMC record of our PTL
files correctly; the HAL takes the file as is, so no decoding is needed.

**Stage 1 done (2026-11-04).** `dkms/psys/`: Intel's PSYS (ipu7-drivers
484d713 + PR #120) ported to the 7.4 `ipu6` core. Mechanical renames
(`ipu7_bus_device → ipu6_bus_device`, `ipu7_dma_* → ipu6_dma_*`,
`ipu7_syscom_* → ipu7_fw_com_*`, `ipu7_boot_* → ipu6_ipu7_*`, buttress
calls), a `struct ipu7_fw_com_context *fwctx` in `struct ipu7_psys` (the
7.4 core keeps the fw-com context in the subsystem driver, as ISYS does),
`psys-compat.h` for the handful of macros the in-tree headers lack
(PSYS-to-SW IRQ registers, `FW_LOG_BUF_SIZE`, `FW_QUEUE_CONFIG_SIZE`), the
PSYS config ABI rewritten on `ipu7-boot.h`'s logger/wdt types, and
`MODULE_IMPORT_NS("INTEL_IPU6")`. Builds against `~/Projects/linux-7.4`
with `IPU6_SRC=` pointing at the kernel's `ipu6` directory. On the running
7.4.0-rc1-sp12: probe binds `intel_ipu6.psys.40`, creates `/dev/ipu7-psys0`;
opening it boots the firmware (`0x57a7e000 → 0x57a7d010 → 0x57a7d300 →
0x57a7e100` READY, message version `0x01000000`), `dev open done`, close
gives `dev close done`, `stop fw done`, sub-domains off. `IPU_IOC_QUERYCAP`
is not implemented by Intel's dispatcher (ENOTTY is expected).

**Stage 2 in progress (2026-11-04).** Tools, profiles and patches are in
`isp/` (nothing Windows-derived). Findings from comparing our graph-100002
blocks with Intel's Linux OV13B10/OV08X40 graphs of the same release
(`isp/tools/graph-dump`):
- Already equal: stream ids 60001, sink mapping, the flag bytes Glauser had
  to clear (DOL leftovers), ifd bpp 10→16. None of his DOL fixes apply.
- The packed-input difference is confined to the LBFF input feeder
  (`ifd_pipe_1_3`, 55223) and link 2: word 10 [31:16] = height; words 11 and
  24 [31:16] = stride (Windows 4928 = ⌈3844/25⌉×32; Linux 7744 =
  ALIGN64(3844×2)); **word 19 | word 18 [31:24] = stride×height/256** (checked
  on five files: 4224×1560/256 = 0x648c, 8448×3120/256 = 0x19230,
  7744×2176/256 = 0x10120, 4928×2640/256 = 0xc684, 5248×2806/256 = 0xe0b3);
  word 36 [31:24] = 1 for packed input; link 2 buffer = stride×height. Intel's
  Linux graphs also stream links 7, 8 and 10 and set 0x00020000 in word 34 of
  BBPS records 25579/20865; `linuxize-100002` applies both (`--windows-links`
  keeps Windows' values for an A/B).
- The IMX681 graph crops one column at the LBFF input (`crop left 1`), the
  RGGB→GRBG shift for a pipeline that wants GRBG; the OV13858 graph crops
  none. Both match our drivers' outputs, so no Bayer work is needed. The
  Windows IMX681 mode tables carry no mirror (`0015`), so this was also how
  Windows ran.
- The converted files pass the HAL reader (968/968, 801/801) and the HAL's
  single-stream query key picks graph 100002 for every size we offer.
- HAL: `MEDIA_DRIVER_NAME` is the prefix "intel-ipu", so `intel-ipu6` matches;
  the entity prefix comes from the common config's `platform` field, set to
  `IPU7.5`; `CAMERA_CFG_PATH` overrides the config dir. Sensors are listed as
  `imx681-uf-2` and `ov13858-wf-0` (CSI port suffix; Capture = port×8).
- The in-tree ISYS's packed formats are MIPI-style (4 px in 5 bytes,
  `ipu6_isys_try_fmt_cap`), not Windows' 25-in-32, so stage 3's option 1 is
  out; the ifd rewrite is the path.

## 6. Risks and unknowns

- The `ifd` words and BBPS flag bits Glauser copied "by comparison rather than
  understood" may differ for a 4-lane 13 MP sensor. Stage 3's option 1 avoids
  touching them.
- The 100003 graph (`SwGdc`) needs HAL support for the software GDC node on
  Linux; if it isn't there, only the 100002 settings (half of each file) are
  usable, which is still every output size.
- Bayer phase for the IMX681 (RGGB vs the GRBG the Windows graph assumed).
- The firmware's packed-input path on Linux is untested (option 1).
- Intel may upstream its own PSYS for `ipu6` and change the UAPI; our module
  would then be a stopgap, which is fine.
- Closed libraries: version-locked to the firmware; a linux-firmware update of
  `ipu7ptl_fw.bin` can break the pinned HAL. Pin the firmware file in the
  package or check the version string at service start.
- Image quality is not guaranteed to beat Phase 7B's soft ISP in daylight; the
  expected win is low light (hardware TNR) and CPU (HAL ~7% of a core on IPU6).

## 7. Upstream and sharing

- The PSYS port to the `ipu6` core is useful to every IPU7 owner on 7.4+;
  offer it to `intel/ipu7-drivers` (they take external PRs) or publish it with
  the DKMS package. Nothing in it is ours to keep private.
- The graph/aiqb conversion tools and the sensor profiles go in this repo; the
  Windows data files do not (they stay in `private/`, fetched from the Surface
  driver MSI by the user, as the Surface Pro 7+ project does).
- Report the `ifd` packed/unpacked finding and the hash-only difference between
  Windows and Linux graph files on ipu7-camera-hal#74, where Intel asked for
  exactly this kind of data point.

## 8. Not possible (for the record)

Changing the firmware (signed); obtaining official graph files for the IMX681
and OV13858 without Intel; fixing the closed libraries. None of these blocks
the plan above.
