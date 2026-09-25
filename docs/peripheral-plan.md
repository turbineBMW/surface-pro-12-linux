# Peripheral bring-up plan

Survey of `linux-omarchy` 7.2.5 with the `sp12-modules` DKMS package, UEFI 12.15.143,
2026-09-23. Sources: this machine (`lspci`, ACPI/sysfs, dmesg), the
[linux-surface#2144](https://github.com/linux-surface/linux-surface/issues/2144)
thread (zR-JB's eight-patch series, MosesKim84), and `~/Projects/sp11`.

## Inventory

### Already working (no action)

| Device | Path | Notes |
|---|---|---|
| Touchscreen + pen | `MSHW0744` → `i2c_hid_acpi`, Elan `04F3:4505`, `hid-multitouch` | **I²C-HID, not SPI.** SP11's HID-over-SPI / iptsd stack does not apply |
| Speakers + mic | SOF PTL, SoundWire link 3, `rt1320-sdca`, generic SDCA function topologies | "No SoundWire machine driver found": works via the default fallback. Tuning is open (see Phase 6) |
| Sensors | ISH + `IshS_SI.bin` → accel/gyro/magn/orientation IIO | via `install-ish-firmware.sh`. ALS enumerates but stalls, see #13 |
| Wi-Fi / BT | CNVi `iwlwifi` / `btintel_pcie` | |
| Keyboard, touchpad, battery, AC, fan, profiles, POS, lid wake, Flex BT | SSAM, `dkms/` | |
| Backlight | `intel_backlight` | |
| IPU7 | `intel-ipu7`, `ipu7ptl_fw.bin` authenticates | rear + front sensors attached (Phase 2a) |

### Not working or unverified

| # | Device | ACPI | Symptom | Driver in kernel? |
|---|---|---|---|---|
| 1 | Power / volume buttons | `MSHW0040` `\_SB.MSBT` | **Fixed** (`0005` probe order). Volume order matches Windows (left = up), shipped as stock | `soc_button_array` (=m) |
| 2 | Rear camera, OV13858 | `OVTID858` `I2C3.CAMR` | **Works** (`0009`, `0011`) | `ov13858` + power patch |
| 3 | Front camera, IMX681 | `SONY0681` `I2C1.CAMF` | **Works** (`0010`–`0016`, libcamera 0.7.2-4.2). Open: colour tuning, noise (soft ISP has no NR) | new `imx681` |
| 4 | IR camera, VD55G0 + illuminator | `SMO55F0` `I2C3.CAM3`, I²C `0x60`, 1-lane CSI link 1, power via `ICL1` | **Works** (`0017`–`0022`): GREY 644×604 on `/dev/video8`, emitter strobes alternate frames; irlume next | `vd55g1` + VD55G0 |
| 5 | NFC, **NXP PN560** | `1FC93002` `I2C4.NFC1`, I²C `0x28`; `_CRS` = IRQ, supply, VEN | **Works for phones** (`0006`, stock nxp-nci core). A contactless card isn't detected (Windows reads it): RF tuning, Phase 8 | stock nxp-nci + `0006` |
| 6 | ~~Unknown~~ Surface Display Hardware Driver (UMDF + `MIS766FpgaFirmware.bin`) | `MSHW0380` `I2C0.FINK`, **no `_CRS`** | unbound | out of scope: the display works without it |
| 7 | ~~SSAM "dropping unexpected command message (rqid = 0x0000)"~~ | `MSHW0084` | **Fixed:** a symptom of a POS event storm (~13% CPU), see `0008` | tabletsw |
| 8 | Suspend | s2idle only | **S0ix reached** on lid close (19.6 s residency); keyboard wake and longer suspends still untested | |
| 9 | Speakers | `rt1320` | **Fine, not reproduced** (2026-09-24): loud and clean at 100% and at low steps with bass-heavy tracks. #2144 had reported distortion at high volume and low loudness at low volume | |
| 10 | Slim Pen tail button | BLE | **Works** (`sp12-pen-pair`): Meta+F20 / F19 / F18 for click / double click / hold | bluez |
| 11 | Microsoft power/thermal devices | `MSHW0800` TS01–12, `MSFT000A/F/10/12`, `MSHW0801`, `MSHW0299` | Temperatures **work** via `surface_temp` (hwmon `surface_thermal`: RTS1–6, VTS1–4); the ACPI devices themselves stay unbound | Windows PEP/thermal framework |
| 12 | HECI `e362` = **Pluton**, `e35d` = **Intel ISSEI** | PCI 00:13.0, 00:18.0 | unbound | out of scope |
| 13 | Ambient light sensor (ISH virtual sensor, "INTEL / Model 0") | ISH `HID-SENSOR-200041` | **Works when streamed** (`sp12-als`, tools 1.5 → `/run/sp12-als/lux`). The one-shot read (`in_illuminance_raw`) returns a stale cached report, so sysfs polling and iio-sensor-proxy (whose 0.5 s buffer probe times out; the sensor reports every 0.75 s) see 0. Insensitive, as in Windows: TV-lit room 0 lux, overhead light 1–20, flashlight to ~2800. Reads 4006 K / x 0.380 / y 0.376 when too dark for colour | `hid-sensor-als`: correct |
| — | Limine `protocol: linux` | — | still freezes after handoff | tracked in `docs/limine.md` |

## What SP11 gives us

Your SP11 is X1E (Qualcomm), so the DT, CAMSS, ADSP, AudioReach, battmgr and QSPI-touch
work does **not** transfer. What does transfer:

- **Camera sensor code.** The upstream SP12 IMX681 driver is Andre Gilerson's SP11
  *Intel* driver (linux-surface/kernel#164), not your X1E driver. Your work is still
  useful: `public/userspace/libcamera/` (IMX681 properties, sensor helper, simple-IPA
  tuning), `public/kernel/sp11-imx681-exposure.patch`, and especially
  `archive-private/.../0017-media-vd55g1-Wire-V4L2-exposure-controls-to-the-VD55.patch`,
  which ran the **VD55G0 through the upstream `vd55g1` driver**. That turns the IR camera
  from a new driver into a variant plus ACPI power glue. Howdy setup:
  `public/userspace/howdy/`. Caveat: IMX681 was C-PHY on SP11 and is D-PHY on SP12.
- **SSAM/KIP fixes (same protocol, same EC family):**
  `public/kernel/sp11-tablet-mode-resume-resync.patch` (re-query posture after resume
  and on KIP connect) and `sp11-surface-hid-shutdown.patch`. The Flex BT OOB work is
  already ported.
- **SSAM tooling:** `lab-private/flex-bt-20260829/ssam-listen.py` and
  `probe-kip-instances.py` on Linux; `decode-shutdown-log.ps1` (SSAM frame decoder) on
  Windows. These are the tools for item 7.
- **Slim Pen:** `sp11-pen-pair`, `pen-addr.py`, `pen-autobond.py`, and the address
  derivation in `lab-private/windows-trace-20260906/WINDOWS-OBSERVATION-PLAN.md`. The pen
  is generic BLE, so this should apply directly.
- **Windows RE kit:** `lab-private/windows-trace-20260906/kit/` (WPR profiles, logman
  sessions, `btetlparse`, `regf.py`); KDNET-over-USB instructions in
  `archive-private/legacy-frozen-working-tree/windows-re/`. Local kernel debugging
  failed on ARM64, but on x86 it works, so you don't need a second laptop for simple
  inspection.
- **Method, not code:** SP11's audio approach (start from the closest topology, set a
  conservative gain ceiling in UCM) and its S0ix method (Windows sleepstudy/DRIPS
  baseline compared with Linux).
- **Warning carried over:** on SP11, probing vendor page `0xFFF4` over hidraw killed the
  stylus until reboot. The SP12 Elan digitizer exposes about 8 `UNKNOWN` collections.
  Don't probe those blind.

## Linux-only vs Windows

Much of the Windows-side information doesn't need a Windows boot. `nvme0n1p3` is plain
NTFS (not BitLocker), so it can be mounted **read-only** from Linux:

```sh
sudo mount -o ro -t ntfs3 /dev/nvme0n1p3 /mnt/win
ls /mnt/win/Windows/System32/DriverStore/FileRepository/
grep -ril 'MSHW0380\|1FC93002\|SMO55F0' /mnt/win/Windows/INF /mnt/win/Windows/System32/DriverStore/FileRepository --include='*.inf'
```

**Offline (mount the partition):** device identity and driver names (MSHW0380, NFC chip
model, IR illuminator driver), INF `AddReg` tuning (camera module info, audio APO/EQ
settings, rt1320 calibration data), and registry hives via `regf.py`.

**Needs a live Windows boot.** Do these in one session (see Phase 3):
1. ETW/WPR trace of SSAM traffic while idling, docking/undocking the keyboard, and
   suspending. This should identify the `rqid 0` requests and how Windows answers them.
2. `powercfg /sleepstudy` and `/systempowerreport` for a DRIPS baseline.
3. A speaker loudness/EQ reference recording (the same test tone at fixed volume steps,
   recorded with a phone).
4. Only if the DSDT isn't enough: the IR illuminator and VD55G0 power-up sequence, via
   KDNET/WinDbg breakpoints or an I²C ETW trace.
5. The Slim Pen pairing trace, if the SP11 derivation doesn't match.

**Linux-side, needs root once:** `sudo acpidump -b` then `iasl -d` (install `acpica`).
It's required for everything below: `_CRS`/`_DSD`/`_DEP` for FINK, NFC1, CAM3, and the
INT3472 GPIO roles.

## Phase 0 findings (2026-09-23)

Captured to `private/` (gitignored): ACPI tables (`private/acpi/dsl/`, MSDM excluded),
all 864 Windows DriverStore INFs (`private/windows/inf-utf8/`), the DriverStore file
list, and a `pmc_core` baseline. The registry hives were not copied because they hold
credentials.

- **Every unknown device is identified** (see the INF → package mapping in
  `private/windows/`). FINK, Pluton/ISSEI, and the MS thermal/power framework
  (`MSHW0800` → SurfaceNativeTemperatureSensor, `MSFT000F/10/12` → MPTF power clients,
  `MSHW0801` → IHV power limit, `MSHW0299` → ACPI platform extension) are Windows-only
  and out of scope.
- **NFC:** `NFC1` `_CRS` has the three-GPIO layout that `nxp-nci_i2c`'s built-in ACPI
  map assumes: IRQ (GPI0 pin 0x18), then GpioIo #1 (GPI5 pin 0x11) = `firmware`, then
  GpioIo #2 (GPI1 pin 0x0F) = `enable` (`drivers/nfc/nxp-nci/i2c.c`). There's no `_DSD`,
  so nothing confirms SP12 uses that pin order. Adding the ID may be enough; if init
  fails, try swapping the two pins with a local `acpi_gpio_mapping`. Windows also applies
  `CustomEEPROMConfigBlob` (NXP proprietary RF/EEPROM tags, starting `A0 11 …`) and
  ships `NXPPN560FW.dat`. If RF performance is poor, replay that blob over NCI.
- **Camera power:** CAMR→ICL0, CAMF→ICL2, CAM3→ICL1. The GPIO types are all ones the
  kernel knows (power-enable `0x0B`, reset `0x00`, privacy LED `0x0D`, DOVDD `0x10`).
  **No INT3472 strobe GPIO and no LED-driver device**, so the IR emitter is almost
  certainly driven by the VD55G0's own GPIO pins (the `vd55g1` driver's `st,leds`
  mechanism). Find the pin on Linux by trying each sensor GPIO and comparing IR frame
  brightness; a Windows I²C trace of `0x60` is the fallback.
- **VD55G0 on Windows** (`vd55g0.sys` + extension): tuning `vd55g0_MSHW0742_PTL.aiqb`
  and `graph_settings_vd55g0_MSHW0742_PTL.bin`. SP11 patch 0017 already has the
  VD55G0 exposure/gain register bank (host-side AE, as on Windows).
- Windows camera extensions also exist for `imx681` and `ov13858`; their `.aiqb` files
  are a source for Phase 6 tuning.

## Phase 1 results (2026-09-23)

`sp12-modules-dkms` 1.2-2 is installed, with three new patches:

- `0005` soc_button_array: MSHW0040 defers until its GPIO provider exists (zR-JB,
  #2144). Takes effect on the next boot.
- `0006` nxp-nci: **PN560 works.** `SsdtNfc`'s `_PTS`/`_WAK` show three power lines:
  pad `0x001A1010` (supply, not in `_CRS`, also gates `_STA`) → `0x001A1011` (_CRS
  GpioIo #1, a second supply) → `0x001A040F` (_CRS GpioIo #2, VEN). There's **no
  firmware-download line**. The stock mapping drove #1 low as "firmware" and the chip
  NAKed (`-EREMOTEIO`). With #2 as `enable` and #1 held high as `power`: NCI
  `DEV_UP`/`START_POLL`/`DEV_DOWN` all succeed. No tag detected yet; next test with a
  bank card, then try replaying Windows' `CustomEEPROMConfigBlob`.
- `0007` tabletsw: re-query posture 2 s after resume (SP11 1/3). SP11 2/3 and 3/3 are
  KIP-only and weren't ported. SP11's `surface-hid-shutdown` was also left out (the
  SP11 commit calls it intermittent).

**Found: a POS posture event storm (item 7's root cause).** The `rqid 0` warnings are
a symptom. A kprobe on `ssh_rtl_rx_data` showed a continuous loop of about 1,100
POS frames/s: EC posture-changed event (`cid 0x03`, payload `00000000 01000000
03000000`, unchanged posture) → tabletsw queries the sources list (`cid 0x01`) and
the posture (`cid 0x02`) → the EC emits another event right after the sources-list
response. The SSAM threads use **~13% of a core continuously**; unloading tabletsw
drops that to 0. Hypothesis: the sources-list query triggers the event. The test
module `pos_quirk` (bit 0: cache the source ID; bit 1: drop events matching the
current state) is ready. Capture: `private/ssam-rqid0.trace`. Note: the tracepoint
`ssam_rx_response_received` gives headers only; payloads need the kprobe (struct
`ssh_command` = type, tc, tid, sid, **iid, rqid(le16)**, cid).

**Resolved (`0008`, installed as 1.2-3):** a sources-list request makes the EC replay
the last posture event, whose payload is `{source, old state, new state}` (confirmed
by detach `0,3,1` and reattach `0,1,3`). Caching the source ID ended it: 376
events/s and 12% CPU → 0, and detach/reattach is still tracked. Worth reporting
upstream in #2144; it affects anyone running the SP12 registry entry.

**After reboot (2026-09-23):** buttons bind at boot (`0005`), zero storm warnings,
SSAM CPU 0. Lid close → `PM: suspend entry (s2idle)`, and
`low_power_idle_system_residency_us` = 19.6 s, so **S0ix is reached**. Tablet switch
reads `laptop` after resume. The volume rocker came out reversed (left = up):
swapped by `userspace/etc/udev/hwdb.d/61-sp12-volume-keys.hwdb` (verified with
EVIOCGKEYCODE). **Windows uses the stock order** (checked 2026-09-23), so this is a
preference, not a bug. The swap is no longer shipped (`sp12-flex-tools` 1.3); a
personal copy lives in `private/local/`.

## Phase 2a results (2026-09-23)

`sp12-modules-dkms` 1.3 and `sp12-flex-tools` 1.2 are installed. **Both visible cameras
work from boot**: libcamera lists "Internal back camera" and "Internal front camera",
and PipeWire exposes "Built-in Back/Front Camera" (the 32 raw IPU7 V4L2 devices have
no source nodes, so no WirePlumber policy is needed). Both stream at 30 fps.

- `0009` ov13858: take optional `reset` and `avdd` from the INT3472 (ICL0) and power
  the sensor for probe and runtime PM. zR-JB's attachment was malformed (includes
  pasted inside the struct) and made both resources mandatory; ours keeps the
  Surface Pro 9 path working.
- `0010` imx681: zR-JB's RFC (linux-surface/kernel#176), from Andre Gilerson's SP11
  Intel driver.
- `0011` ipu-bridge: `OVTID858` (mainline has none; 2 frequencies, 540/270 MHz, per
  the driver), `SONY0681`, and the rear 180° DMI quirk (#174/#175/#176).
- `0012` imx681: `-EPROBE_DEFER` without an endpoint. It failed with `-ENXIO` when
  it probed before IPU7 built the bridge graph, as ov2740 used to.
- **GPU SoftISP artifact (libcamera 0.7.2):** the front camera shows a 1-px grid and a
  magenta cast at some output sizes: 1920×1080 bad (score 1.36), and 640×360 has
  the cast. 640×480, 1280×720, 1920×1440, 2560×1440 and 3840×2160 are clean. It's a
  one-pass Bayer-downscale aliasing bug (zR-JB, #2144); upstream's multi-pass GPU
  ISP series should fix it. **Workaround:** `LIBCAMERA_SOFTISP_MODE=cpu` via
  `/usr/lib/environment.d/60-sp12-libcamera.conf`. It's clean at 1080p (score 0.82)
  for ~5% more of one core. Scorer: `private/camera/tools/gridscore.py`.
- `0013` imx681: **no mirror.** The driver copied Windows' `0x0101 = 0x01` (H-mirror,
  GRBG), so frames were reversed (shirt text backwards). Now orientation is 0 with
  native RGGB. Raw check: the matching (green) sites are (0,1)/(1,0) (604/590 vs
  280/295), and a warm lamp stays warm after demosaicing. Installed in DKMS 1.4.
- `0014` imx681: after a warm reboot from Windows the sensor read chip ID 0x0000
  1–2 ms after reset release, so probe failed (-EIO) with no retry and the front
  camera was missing. Now it waits 10 ms and retries the ID read 4× at 5 ms.
  (Recovering without a reboot: `modprobe -r imx681; modprobe imx681`, then
  `systemctl --user restart wireplumber`, because WirePlumber only enumerates
  libcamera cameras at startup.) DKMS 1.5.
- **Framing:** the driver's single mode reads a 3844×2640 centre window (X from 100,
  Y from 256), and a 16:9 request crops it further, so Linux is tighter than
  Windows, which bins the full array and crops digitally (Studio Effects subject
  following). The crop causes none of the open issues. A binned full-array mode
  is the prerequisite for any future framing work.
- **libcamera 0.7.2-4.1** (`pkg/libcamera-sp12`): the SP11 IMX681 series rebased onto
  0.7.2 (sensor properties, reciprocal gain helper `1024/(1024-code)` plus black
  level 64@10 bit, initial `imx681.yaml`). zR-JB measured the same gain law on SP12.
  AGC now reports 9.85× where stock reported "919×" (the raw code). Builds only
  libcamera, -ipa and -tools; any newer Arch release supersedes it.
- **Still open:**
  - **Motion dashes:** 1–3-row orange/blue dashes along moving edges only. They're
    in `cam` output too (not PipeWire) and with both CPU and GPU ISPs (13 and 53 per
    81 motion frames at 1920×1440), scattered at many rows (not one tear seam). So
    they're in the raw data: likely a readout mode where adjacent rows/sites aren't
    exposed at the same instant (Windows-derived vendor registers). **Next: wave at
    the Windows Camera app.** No dashes there means compare against a Windows I²C
    trace; dashes there too means it's inherent and gets handled in demosaic
    tuning. Detector: `private/camera/tools/dashscore.py`.
    **Windows result (2026-09-23): no dashes.** Windows streams a **2×2-binned**
    mode (the ultrawide full FOV, cropped digitally for Windows Studio Effects'
    subject following). Our driver only has the full-res 3844×2640 mode. If the
    IMX681 is quad-Bayer, full-res depends on on-chip remosaic, which fringes where
    the four same-colour pixels of a cell disagree (motion). Binned readout averages
    the cell into a clean native Bayer (~1922×1320) with better SNR. **Next:** add a
    binned mode. Register source: a Windows I²C trace of stream start (preferred,
    fits the SP11 runtime-traces-only provenance rule), or the mode tables in
    `imx681.sys` (data only; private cross-check). The Windows extension also ships
    `graph_settings_imx681_MSHW0740_PTL.bin` (IPU mode list).
  - ~~Exposure pinned at maximum~~ **fixed:** libcamera patch `0004` adds an
    `exposureGainThreshold` to the simple AGC (exposure up to it, then gain, then
    exposure to the limit; rebalances power-on exposure into gain).
    `imx681.yaml` sets 1/60 s. Verified: 16.7 ms instead of 33 ms, gain takes over.
    It trades blur for noise in dim rooms; tune the threshold by eye
    (`/usr/share/libcamera/ipa/simple/imx681.yaml`). libcamera 0.7.2-4.2.
  - ~~Pixel rate reported at half~~ **fixed (`0015`):** it was derived from the CSI
    link (387.84 MHz); the VT clock is 19.2 MHz × 225 / 6 = 720 MHz (7552 × 3177 ×
    29.97 fps = 719 MHz). Exposure metadata now tops out at 33.3 ms. IPU7 uses
    `LINK_FREQ`, which is unchanged. DKMS 1.6.
  - **Windows' `imx681.sys` mode tables** (read from the binary, 8-byte entries
    `{u16 addr, u16 0, u32 val}` around offset 0x25534): two modes, both full-res
    3844×2640 with the same crop and vendor registers, and **no binning** and no
    `0x0101`. A: line 0x1D60, frame 0x0C77, PLL2 0x134 (30 fps). B: line 0x1D80,
    frame 0x18D2, PLL2 0x12F (15 fps). Ours is B's clock at a 30 fps frame
    length, which is valid. So **Windows scales in its ISP rather than binning**,
    and Linux's tighter framing is the CPU soft ISP centre-cropping instead of
    scaling. (An earlier theory that Windows' ISP cleans up the motion dashes
    was wrong; see below.)
  - ~~Motion dashes~~ **fixed (`0016`, DKMS 1.7):** they appeared on the **rear**
    camera too, which ruled out the sensor. Cause: IPU7 ISYS output pins had
    `link.is_snoop = 0` ("TODO: set the snoop bit"), so frames were written
    without snooping the CPU cache, and x86 `dma_sync_*_for_cpu()` doesn't
    invalidate. libcamera read stale 64-byte lines (32 px, one row) of each
    buffer's previous frame wherever the scene had moved. Setting `is_snoop = 1`:
    zero dashes on both cameras, still 30 fps. **Affects every IPU7 machine using
    libcamera's soft ISP: report upstream.**
  - Green/grey cast under warm light: no CCM or tuned AWB yet (Phase 6).
  - The GPU and CPU ISPs pick different fields of view at 1920×1440.

## Order of work

Phases 0 and 1 are done (see the findings above; committed in `a22260f`).

### Phase 2: cameras (now)
**2a, visible cameras (patches exist upstream):**
- Rear: `ov13858` power/runtime-PM patch, `ipu-bridge` OVTID858 link-frequency entry,
  and the 180° DMI rotation quirk.
- Front: the `imx681` driver (kernel#164 lineage, D-PHY) and the `ipu-bridge`
  SONY0681 entry.
- All targets are `=m` (`ov13858`, `ipu-bridge`, new `imx681`), so they fit DKMS.
- Userspace: `libcamera` ≥ 0.7.2 plus the IMX681 helper (reconcile the SP11 libcamera
  patches with zR-JB's helper), and PipeWire's libcamera SPA. Add it to the ISO.
- Check first whether zR-JB's series has landed in `linux-surface/kernel`.

**2b, IR camera (driver work):** extend `vd55g1` for the VD55G0 (SP11 patch 0017 has the
exposure/gain bank), ACPI power via `ICL1`, an `ipu-bridge` SMO55F0 entry, then find
the emitter pin (sensor-GPIO strobe; try each pin, compare IR frame brightness).
Then Howdy from SP11's config.

### Phase 2b results (2026-09-23): IR camera
- `0017` vd55g1: the Surface Pro 11 VD55G0 support, ported to 7.2 (model ID, FSM at
  0x002c, 552-byte firmware patch, fixed 644×604 mode, exposure bank at 0x044x).
- `0018` vd55g1: ACPI `SMO55F0`, INT3472 supplies (`avdd`/`dovdd`), defer until the
  bridge endpoint exists, and the **SP12** Windows 19.2 MHz mode table.
  `vd55g0.sys` holds three firmware patches (the 552-byte one is identical to
  SP11's) and three mode tables (24/12/19.2 MHz EXT_CLOCK). SP12's table sets
  **GPIO0/GPIO1 (0x0469/0x046a) = strobe**, which drives the emitter.
- `0019` ipu-bridge: `SMO55F0`, one lane, 420 MHz (840 Mbps).
- `0020`/`0021` IPU7 ISYS: `Y10`/`Y10P` and `GREY` capture (the CSI2 receiver
  already accepted Y10; Y8 added). `0022` vd55g1: RAW8 output on the VD55G0
  (`FORMAT_CTRL`/`OIF_IMG_CTRL` after the table); the firmware accepts it.
- **Emitter:** strobes **alternate frames** (lit ~83/255, ambient ~22 in a dark
  room), Windows Hello-style; a faint red glow on the **left** of the camera cluster.
  The INT3472 "privacy LED" (`SMO55F0_00::privacy_led`) is the visible indicator on
  the **right**. `0023`: vd55g1 now registers with
  `v4l2_async_register_subdev_sensor()`, so the core drives that LED while the IR
  camera streams (verified: 0 → 1 → 0, both lights seen).
- Boot wiring: `sp12-ir-camera.service` + `70-sp12-ir-camera.rules` link CSI2 1 →
  ISYS Capture 8 and set Y8 644×604 (`/dev/sp12-ir` symlink). libcamera use of the
  other cameras leaves the link alone.
- Testing note: `ipu-bridge` builds its graph once at IPU7 probe and skips it if a
  graph exists, so a new bridge entry needs a reboot, not a module reload.
- **irlume:** it refuses `v4l2loopback` by design (physical-bus pinning), so there's no
  bridge; the ISYS node is on PCI and passes. It needs 8-bit GREY (done). No
  physical RGB node, so **IR-only** (`irlume auth sensor ir-only --yes`,
  experimental) until Phase 7's hardware ISP provides one.

### Phase 3: one Windows session
SSAM ETW trace (optional now that the storm is fixed), `powercfg /sleepstudy`, the
speaker loudness reference, which rocker button Windows treats as volume up, and a
pen trace if needed.

### Phase 4: suspend quality
Longer suspends, keyboard wake, `pmc_core` substate blockers, and the resume paths
(touchpad finger-count offset seen on SP11, tablet-mode resync, camera runtime-PM).

Results (2026-09-23):
- 60 s s2idle: 98–99% hardware sleep, all in S0i2.2; RTC wake via IRQ 9.
- Resume takes 1.5 s, 1.1 s of it `rt1320-sdca` resyncing its register cache over
  SoundWire (synchronous, no async toggle). Optional patch: resume it async or
  defer the sync.
- `intel-ipu7: Failed to get runtime PM` on every resume: `ipu7_resume()` takes a
  runtime-PM reference on PSYS, which has no driver, and returns before firmware
  re-auth. Harmless in practice (IR, front and rear stream right after resume);
  revisit with Phase 7.
- Detaching the keyboard while asleep: tablet mode is correct on wake (`0007`), and
  keyboard/touchpad devices are removed cleanly.
- **Keyboard wake doesn't work.** SSAM wakeup (`serial0-0`) is off by default; with it
  on, any EC event (battery updates while charging) wakes the system at once.
  Upstream's `ssam_irq_handle()` leaves this unimplemented (TODO: fetch the pending
  events one by one with the GPIO callback command, and only resume for wake-worthy
  ones). Doing it needs that command's IDs, which can come from Windows' SSAM driver.
- 28 min on battery: 99.8% hardware sleep in S0i2.2, 0.27 Wh used (~0.57 W average
  including the awake seconds around the suspend), about 1%/h, ~4 days standby.
- Flex Keyboard over Bluetooth (045E:0C7A, "bluez-hog-device"): libinput treated
  the touchpad as external (no palm detection) and matched none of the Surface
  quirks. `61-sp12-flex-touchpad.hwdb` marks it internal; `60-sp12-flex-keyboard.quirks`
  adds the keyboard/touchpad quirks plus `ModelTabletModeNoSuspend` (internal
  devices are otherwise suspended in tablet mode, i.e. whenever it's detached).
  Quirks load when the compositor starts.
- Bluetooth touchpad jagged, no acceleration: BlueZ had no connection parameters for
  the keyboard (it never requests any), so Linux's 30-50 ms default interval
  delivered its 125 Hz reports in bursts of ~4 (0.6 ms apart, then ~29 ms gaps) and
  libinput's velocity went wrong. `sp12-flex-pair` now stores 7.5-11.25 ms
  (latency 4) after pairing; `--conn-params` applies it to a paired keyboard.
  Reports then arrive every 7.5 ms.
- Bluetooth keyboard wake (detached): the controller (`0000:00:14.7`) has wakeup off
  by default. With it on and BlueZ's suspend scan raised to 30 ms every 160 ms
  (`ScanWindowSuspend=48`, `ScanIntervalSuspend=256`), a key press woke it at once,
  but so did the keyboard's own chatter 6 s into an untouched suspend. BlueZ logged
  "wake event 0x1" (unexpected event), not a remote wake, for both. Reverted: keys
  on the detached keyboard don't wake it; the power button does.
- **Attached keyboard wake: done (2026-09-24, sp12-modules 1.13, tools 1.13).**
  - **Cause:** the keyboard *looks* dead in suspend (no backlight, no haptics)
    because display-off turns those off, but key presses still reach the EC. The EC
    holds them and raises the SSAM wake line.
  - **Tests** (SSAM wake on, 5 min each, event tracing): on battery, the tablet
    slept until the RTC alarm and a spacebar press woke it instantly. While
    charging, a BAT event (`0x53`, "TurboPowerUpdate") woke it after 133 s.
  - **DKMS `0025`:** `surface_battery`/`surface_charger` unregister their BAT
    notifiers on suspend (the EC event is disabled once both refs drop) and
    re-register on resume. Charging then slept the full 5 min.
  - **tools `70-sp12-keyboard-wake.rules`:** enables `serial0-0` (MSHW0084) wakeup.
  - **Still wake sources:** keys, the touchpad, and POS (keyboard attach/detach)
    events.
  - **Windows reference:** its SSH driver releases held events with SAM command
    `0x17` (GPIO callback, in `SurfaceSerialHubPassiveLevelCallbackGpioTarget`) and
    sends display off/on (`0x15`/`0x16`) on console display state, D0 exit/entry
    (`0x33`/`0x34`) as "UART sleep". Linux doesn't need `0x17`: display-on at
    resume releases them all.
- **Bluetooth keyboard wake: done (2026-09-24, sp12-modules 1.14, bluez-sp12 5.87-2.3,
  tools 1.16).** A 5-min hands-off sleep with the keyboard connected saw no traffic
  (RTC wake). A spacebar press woke it at once (report `00 2c`).
  - **bluez-sp12** (`pkg/bluez-sp12`, Arch's PKGBUILD + patch `0001`):
    - `src/sleep.c` watches logind PrepareForSleep and holds a 300 ms delay
      inhibitor.
    - HoG (`suspend-sleep` replaces `suspend-none`) writes HID Control Point
      Suspend/Exit to every HID instance. The first version segfaulted on bonded,
      unconnected HoG devices (the pen): NULL `dev->hog` in a path that never ran
      upstream.
    - It pauses vendor-page input reports (report map walk; the keyboard's
      `0xd1` status report on page 0xFFF5 ignores HID Suspend and woke it at ~60 s).
    - The battery plugin unregisters Battery Level notifications.
    - Everything is restored on resume.
  - Earlier findings below.
- **Bluetooth keyboard wake (history): half done (sp12-modules 1.14, wake left off in tools 1.15).**
  - **Cause of the old "chatter" wakes:** Linux drops every link at suspend
    (`hci_disconnect_all_sync`, "remote power off"), and the keyboard reconnects
    within seconds (seen awake: reconnected ~12 s after a disconnect, then sent 10
    empty reports). That reconnection wakes the host.
  - **Connected and idle,** the keyboard sends only input and a **Battery Level
    notification (handle 0x000e) about every 62 s** (btmon, 3 min idle).
    HID Information flags = 0x03 (RemoteWake, NormallyConnectable).
  - **DKMS `0026`** keeps LE links to WakeAllowed devices over suspend when the
    controller may wake (log: "keeping 1 wake-capable link(s)"). With controller
    wake on, the tablet then woke at 14-47 s on the battery notification.
  - **Missing piece:** pause battery notifications (CCCD 0x000f) and/or send HID
    Control Point Suspend (0x001e/0x0052/0x0086 = 0x00) before suspend, then undo
    them after. BlueZ refuses both from D-Bus ("Operation Not Authorized": the HID
    and battery services are its own) and Arch's build uses `suspend-none` (no HoG
    suspend). Options: a BlueZ fork that does it on logind PrepareForSleep, or
    disabling BlueZ's battery plugin and having a helper own the battery
    notifications (Stop/StartNotify around sleep, BatteryProvider1 for UPower).

### Phase 4b: ambient light sensor and auto-brightness (done)
`sp12-als` streams the ALS with change sensitivity 0, as Windows reads it (Windows
adaptive brightness is on; the probe is `windows/sp12-sensor-probe.ps1`). The
AOSP-style controller lives in the local `turbinebmw.monitor` plugin: user offset on
a lux curve, log-lux bands with debounce, a minimum brightness delta, slow ramps.
No human presence sensor exists (Windows lists none).

### Phase 5: NFC (done for phones; card reading moved to Phase 8)
Findings (2026-09-24):
- **Phones work** with the stock nxp-nci core plus `0006`: a Galaxy Z Fold8 (Samsung
  Wallet, HCE) is detected on every tap as ISO14443-A (random `08:xx` UID).
- **A contactless credit card is never detected on Linux**, while Windows reads it
  easily. Phones answer strongly; passive cards need proper field strength and
  receiver settings, so this points at RF tuning or low-power card detection.
- Windows' `CustomEEPROMConfigBlob` is three NXP TLVs (A011, A068, A00B). The chip
  already holds all three byte-for-byte (read back with `CORE_GET_CONFIG`), since
  Windows writes them to EEPROM. Windows' runtime `RfConfigData` is empty.
- The PN560 is NCI 2.0 (firmware info `1f ca 01 01 40`). `CORE_SET_POWER_SUB_STATE`
  looked necessary once but isn't: the stock driver detects the phone without it
  (a draft patch for it was dropped). NfcCx only sends it with a secure element or
  HCE present.
- The antenna is at the top left of the screen (front), range ~15 mm. Windows
  detects cards through the proximity path (the smart-card reader state stays empty).
- Upstream nxp-nci deadlocks if the driver is removed while the device is up
  (`nxp_nci_remove` holds `info_lock`, and `nci_unregister_device` →
  `nxp_nci_close` takes it again). Take the device down before `rmmod`.
- Windows' NFC class extension is open source (microsoft/NFC-Class-Extension-Driver,
  cloned in `private/nfc/nfccx`). Its NCI library logs through WPP GUID
  `696D4914-12A4-422C-A09E-E7E0EB25806A`, with hex dumps of config values. The NXP
  client driver can inject vendor commands at NfcCx sequence points, which only a
  trace of real traffic would show.
- Tools: `private/nfc/pn560-nci.py` (raw NCI over I²C, driver unbound),
  `private/nfc/nfc-poll.py` (kernel netlink poll), `windows/sp12-nfc-probe.ps1`.
- `sp12-nfc-probe.ps1` now also enables NfcCx's five WPP GUIDs and its TraceLogging
  provider (`6E6BACF6-...`) by GUID. The NCI hex dumps are WPP, so the packets must
  be pulled out of the raw event data (no TMF).
- Next for cards: capture Windows' traffic (WPP trace of the five NfcCx GUIDs across
  a device restart and a card tap), or compare NXP's published PN7160/PN560 RF
  settings. Don't write EEPROM blind.

### Phase 6: polish
- ~~Speaker tuning~~: not needed. #2144's distortion report didn't reproduce here.
- ~~kmonad remaps with the Flex Keyboard over Bluetooth~~: done (personal config,
  udev-started `kmonad.service`/`kmonad-bt.service`).
- ~~Slim Pen tail button~~: done (`sp12-pen-pair`, tools 1.9). A BLE bond (Just
  Works); click = Meta+F20, double click = Meta+F19, press and hold = Meta+F18.
  XKB names F20 `XF86AudioMicMute` and F18 `XF86Launch9`, so Hyprland binds must
  use those names; only F19 keeps its own name.
  Docking switches the pen to Windows' loosely coupled mode (radio silent): hold the
  tail button ~7 s after undocking to reconnect (automating that is Phase 8a).
- ~~Camera colour (CCM)~~: done (libcamera-sp12 4.4, patches `0005`/`0006`). Both
  modules' Windows `.aiqb` files are CPFF containers (sections LCMC/LAIQ/LISP/LTHR,
  records `{u32 size, u16 id, u16 type}`; the parser in
  github.com/MarcoGlauser/galaxybook6-ultra-camera walks them). LCMC record type 25
  holds the CCMs: per illuminant a 924-byte block of 4 chromaticity floats, u32 colour
  temperature, the base (global) 3x3 matrix, then 24 hue-sector matrices;
  `private/camera/tuning/aiqb_ccm.py` extracts them. Front IMX681: 7 illuminants
  (2300-6859 K); rear OV13858: 6 (2514-6366 K). 4.4 first shipped the 24th
  (red/magenta) sector matrix by mistake; 4.6 uses the base matrices, preferred in a
  blind A/B, which also amplify blue noise less (2.1x vs 2.6x). 30 fps unaffected. A screen-and-mirror ColorChecker fit was tried first and was
  unreliable (AE drift, unknown panel gamut). Open: AWB (grey world, casts in mixed
  light), lens shading, noise.
- ~~MS thermal devices (`MSHW0800` TSxx)~~: already work. They're the EC's ten
  temperature sensors (RTS1-6 thermistors, VTS1-4 computed), which `surface_temp`
  reads over SSAM as hwmon `surface_thermal`. The ACPI devices are Windows'
  descriptions of the same sensors.

### Phase 7: hardware ISP (IPU7 PSYS)
Windows' image quality comes from IPU7's hardware ISP (PSYS): denoise, CCM, AWB and
lens shading, tuned by the `.aiqb` files we already have from Windows
(`private/windows/drivers/imx681_extension…`, `ov13858_extension…`). Linux
currently uses only ISYS plus libcamera's software ISP, which has no noise reduction
or colour matrix. Research Intel's out-of-tree IPU7 PSYS driver and camera HAL
(closed components) on Arch: what exists, how it coexists with PipeWire/libcamera,
and whether our DKMS/package approach can carry it.

Findings (2026-09-24), hardware ISP not viable for now:
- Intel's stack: `intel/ipu7-drivers` (PSYS module; on kernels >= 6.17 it builds only
  PSYS against the staging core; tested up to 7.0), `ipu7-camera-hal` (Panther Lake
  = `ipu75xa`), proprietary `ipu7-camera-bins`, and `icamerasrc` → v4l2loopback.
  PSYS isn't upstream and isn't headed there (the 2026-09 ISYS series doesn't cover it).
- PSYS can't run on the staging core. Its headers add `acquire_fw_task_buffer_lock`
  and `get_running_fw_task_count` to `struct ipu7_bus_device`, and it locks and
  writes them; the staging core allocates the smaller struct and never initialises
  the mutex, so loading it corrupts memory (intel/ipu7-drivers issue #63). It also
  needs `isp->ipu7_dir`, and the MMU `tlb_invalidate(mmu, mmu_id)` signature differs.
  Intel's own v7.0 staging patch series doesn't add these. The only consistent route
  is Intel's whole out-of-tree core+ISYS+PSYS, ported to 7.2 with our `0016`/`0020`/
  `0021` redone on it.
- The HAL needs a per-sensor graph-settings binary (Intel-generated, schema-hashed).
  Linux ones exist for OV13B10, OV08X40, OV8856, OV05C10 and IMX471, not for IMX681
  or OV13858. Windows' `graph_settings_*.bin` are a different format (header
  `0x5c63b5e7` with embedded output modes) and can't be used.
- Revisit if Intel publishes graph settings for these sensors or PSYS goes upstream.
  Meanwhile improve the software ISP (Phase 7B).

### Phase 7B: software ISP from the Windows tuning
Done (libcamera-sp12 4.7):
- `0007` 2x2 binning in the CPU debayer. The soft ISP couldn't scale, so 1080p from
  the IMX681 (no binned sensor mode) was a centre crop at full per-pixel noise. It
  now bins a 3840x2160 window to 1920x1080: Windows' field of view, finer and
  quieter noise, a quarter of the work. The OV13858 already had a binned sensor mode.
- `0008` temporal noise reduction on the binned path: per-pixel running average in
  the raw domain, reset above a noise threshold. Default `64,24,3` (about 40% less
  frame-to-frame noise at 16x gain); `64,32,5` gives 50% but leaves trails behind
  motion (no motion compensation). `LIBCAMERA_SOFTISP_TNR=0` turns it off.
- PipeWire runs libcamera inside wireplumber: restart it after a libcamera upgrade.
- `0009` (4.8) lens shading on the binned path, from the `.aiqb` LCMC type 0x1c
  tables (11 or 12 illuminants x R/Gr/Gb/B x 63x47 u16 gains, 2048 = 1.0, full pixel
  array), added to the tuning files as a `lensShading` section. The table nearest the
  AWB white point is used. A paper flat field confirmed the tables: raw green falls to
  0.17 in the corners, and full correction evens it out. Strength 0.7 (exponent on the
  gains) beat 1.0 in a blind A/B, leaving a gentle vignette and less corner noise.
  `LIBCAMERA_SOFTISP_LSC` overrides it; 0 turns it off. Type 0x21 is unused.
  4.9 extends it to the unbinned path (raw lines shaded as they're copied), which
  covers the rear camera: the OV13858's 2112x1188 mode is a centred 2x-binned crop of
  its 4224x3136 array (`arraySize` in the tuning), debayered to a 1080p centre crop.
- `0010` (4.10) AWB from grey zones and the illuminant locus. The CCM records' first
  four floats are the sensor white point (R/G, B/G) and the illuminant's CIE xy at
  that CCT, which gives each module's locus. The soft ISP stats gain a 16x12 zone
  grid. The AWB averages the lit, unsaturated zones within 0.1 of the locus
  (brightness-weighted), then snaps the estimate onto the locus, keeping up to 0.06
  off it. Room LED light measured ~0.046 green of the IMX681 locus, and 0.03 left a
  green cast. The CCT for the CCM comes from the locus. Blind A/B: this fixed the
  rear's cyan whites (warm floor/cardboard had fooled grey world); the front was a tie.
- The PKGBUILD applied `../000*.patch`; patches from 0010 on need `00[0-9][0-9]-*`.
- `0011` (4.11):
  - **FOV:** 1080p front defaults to the centre crop at full resolution (the user found
    the binned full sensor too wide). `sp12-camera-fov crop|wide|toggle` (tools 1.10)
    writes `fov=` to `~/.config/sp12/camera.conf`, read at each camera start;
    `LIBCAMERA_SOFTISP_FOV` overrides it.
  - **Raw TNR:** TNR on the unbinned path, applied to raw lines as they're copied (after
    lens shading), so the crop and the rear camera get it: ~40% less frame-to-frame noise.
  - **Chroma NR:** a half-resolution 5x5 sigma filter on B-Y/R-Y, with luma kept; default
    threshold 8 (`LIBCAMERA_SOFTISP_CNR`). Threshold 20 flattened skin tones and lost a
    blind A/B to off; 8 beat off.
  - **Threads:** libcamera-sp12 ships `/usr/share/libcamera/configuration.yaml` with 4 soft
    ISP threads (default 2): ~20 ms per 1080p frame with everything on.

Still open:
- GPU mode: retest when libcamera's multi-pass GPU ISP lands (the one-pass one
  aliases the IMX681 mosaic when downscaling).

### Phase 7C: NPU/GPU video denoise
The software TNR has no motion compensation, hence the trails at higher strength.
Phone-style quality needs either motion-compensated multi-frame merging (optical
flow on the GPU) or a learned video denoiser (FastDVDnet-like). Panther Lake has an
NPU and an Xe GPU that OpenVINO can use on Linux. Scope: a real-time 1080p30
model/pipeline between libcamera and apps (v4l2loopback or a PipeWire filter), its
power cost, and how apps pick it up.

Spike (2026-09-24): OpenVINO 2026.3 with NPU and GPU plugins, all from Arch `extra`.
The NPU needed a `uaccess` udev tag: the package makes `/dev/accel/accel0` 0660
root:render (`/etc/udev/rules.d/70-intel-npu-uaccess.rules`, local). Benchmarks of a
FastDVDnet-shaped net (random weights, `private/camera/denoise/bench_fastdvd.py`,
streaming, so two DenBlocks per frame):

| Net | Resolution | Device | Speed |
|---|---|---|---|
| full width | 1080p | GPU | 4.7 fps |
| 1/2 width | 1080p | GPU | 10 fps |
| 1/4 width | 1080p | GPU | 19 fps |
| 1/4 width | 1920x544 tiles | NPU | 24 tiles/s (~12 fps) |

The NPU compiler (intel-npu-compiler 2026.28) segfaults on most 1080p and 1/2-width
graphs. Only the paper's full net has pretrained weights, and even a slim net would
need training. ffmpeg `nlmeans_vulkan` (p=5, r=7) manages 22 fps at 1080p; CPU `hqdn3d`
~195 fps. Conclusion: learned 1080p30 video denoise isn't viable on this machine
today. Revisit with a newer NPU compiler, or at 720p (what Teams sends) with a
trained slim model.

### Phase 8: last items
#### 8a: pen cradle detection
How Windows knows the Slim Pen has left its charging cradle in the Flex Keyboard
(never solved on the SP11 X1E). This Intel machine allows stronger Windows-side
tracing (ETW/WPP, and KDNET if needed): record SSAM, Bluetooth and HID traffic while
docking and undocking the pen, then find the event and map it on Linux.

Linux-side passive checks (2026-09-24, cued dock/undock runs, `private/pen/hidlog.py`,
`cues.sh`) found **no signal at all**. What was checked:
- keyboard HID over Bluetooth (0C7A: vendor pages FFF5/FF0B) and attached (0C8B/0C8D/
  0C8E/0C8F/0C90), plus the SSAM HID 0C97;
- all SSAM events (`ssam_rx_event_received`);
- the ISH HID streams and the Elan digitizer;
- BLE advertisements: nothing from Microsoft or the pen. The pen holds no link;
  it connects only on a tail-button press.

So Windows probably *enables* the notification first: an SSAM event category, or a
feature/output report on a keyboard collection, which Linux never sends. The
candidates to read (copy the `.sys` from the DriverStore) are:
- `bthlcpen.inf` (inbox Bluetooth loosely coupled pen);
- `SurfacePenBleLcAddrAdaptationDriver`;
- `surfaceintegrationdriver`;
- `surface_hid_mini`.

Pair that with a Windows trace (TraceLogging where the drivers use it, so it decodes
without PDBs) of SSAM and HID I/O during docking.

Driver reading (DriverStore, read-only):
- **Charger hotkey:** `SurfacePenWirelessChargerHotkey.inf` binds
  `HID\VID_045E&PID_0C8E&Col01` (keyboard page), the "Surface Wireless Pen Charger
  Hotkey". Its descriptor carries F18/F19/F20, i.e. tail-button presses passed through
  the charger.
- **Collection 2** (FFF4:0x0A) has input report `0x14`: 6 bytes (probably the pen's
  BD_ADDR), three flag bits and a 0-100 value (battery). That's the pen status.
- **Collection 3** (FFF4:0x01) looks like a pairing channel: `0x54`/`0x6e` in,
  `0x55`/`0x6f` out (8- and 16-byte key-sized fields), and features `0x56`, `0x70`
  (bits 0x10, 0x22) and `0x73`.
- **`SurfacePenBleLcAddrAdaptationDriver`:** PenService sets
  `FEATURE_REPORT_ID_HOST_AB_CAPABILITY` ("host auto-bonding capability") on the
  "SeparatePenCharger" and the digitizer. It's likely the enable that makes the
  charger report.
- **User's observation:** a faint haptic pulse from the pen on lift-out, so the pen
  itself knows it left the charger, which may wake its radio. Hence the Bluetooth
  trace.

Windows run 1 (2026-09-24):
- **HID half failed:** my SetupDi enumeration found no devices, so the script needs
  fixing.
- **Bluetooth trace:** WPP undecodable without TMFs, plus my own beeps. It still
  showed that the pen stays BLE-connected on Windows the whole time (DevicesFlowUI:
  Slim Pen 2 connected before and after an undock), and a tail press arrives as an
  ATT notification (handle 0x0047).
- **User observations:** they believe the pen does disconnect eventually, and the
  test may have moved too fast. Also, the pen had never met Windows before; Windows
  bonded it the first time it touched the screen. That matches
  SurfacePenBleLcAddrAdaptationDriver's `ConvertPenIDToMACAddress` / "PenService
  queries for Auto Bonding": the digitizer reports a pen ID on contact, and Windows
  derives the BLE address and bonds with no pairing UI. Worth tracing and porting:
  touch-to-pair on Linux.

Windows run 2 (2026-09-24, probe v2, raw HCI via BTHPORT all keywords →
`private/pen/hcixml2snoop.py` → btsnoop):
- **Cradle:** the pen stays BLE-connected while docked until it idles or the host
  suspends. It doesn't reconnect when pulled out; any button press does,
  performing the action at once (eraser click → OneNote). The HCI log shows an
  advertisement from a resolvable private address (5D:F..), a connection within
  13 ms, encryption with the stored key, then the HID report. That's an ordinary
  bonded reconnect, which Linux already does (sp12-pen-pair). **Cradle detection
  is therefore not a Bluetooth event.** The charger's 0C8E report 0x14 is still
  unobserved (the keyboard was on Bluetooth in this run).
- **Touch-to-pair (pen removed, tip touched):**
  - The first radio traffic comes ~4 s after the touch, and it's already a bonded
    connection. Windows adds the pen's static random address (C6:12:34:56:78:9A;
    Linux's bond uses D2:AB:CD:EF:01:23, so each host has its own identity) to the
    accept list, connects as central, and starts encryption with an LTK it
    already has. **No SMP pairing.** Then plain GATT discovery.
  - Windows logs LE Start Encryption without parameters, so the key isn't in the
    trace.
  - So the digitizer supplies a pen ID on contact (the Linux digitizer descriptor
    has usage 0x5B Transducer Serial Number), and Windows derives the address and
    keys (LTK, and an IRK for the RPA) from it.
  - SurfacePenBleLcAddrAdaptationDriver has `ConvertPenIDToMACAddress` and
    BCrypt; the key derivation may be there or in the inbox bthlcpen/BthLE stack.
  - Porting it to Linux = reverse-engineering that derivation, then writing a
    BlueZ bond on touch.

**Click-to-connect: done (tools 1.17).** Skip the derivation: share Windows' bond.
- `windows/sp12-bt-keys.ps1` exports BTHPORT's `Keys` (a one-shot SYSTEM task) to
  `out\bt-keys.reg`. Keep it private.
- `sp12-bt-import-windows bt-keys.reg C6:12:34:56:78:9A --like D2:AB:CD:EF:01:23`
  writes the BlueZ bond. Conversions: LTK as stored, IRK reversed, ERand a
  little-endian u64. It copies the name, services and GATT cache from the Linux bond.
  The two identities expose the same GATT table.
- **Result (2026-09-24):** after docking or idling, one eraser click connects in
  ~25 ms. The link comes up with the resolved RPA and AES-CCM from the imported
  key, and the click's report arrives about 0.6 s later.
  - With the GATT cache, the uhid device is up before the report arrives, so the
    action fires (a Hyprland screenshot). As on Windows, there's no 7 s hold.
  - Without the cache, BlueZ's first discovery takes ~5 s and the click is dropped.
  - A BlueZ discovery scan running at the time (the Bluetooth panel open) makes
    the connect miss the pen's short advertising burst.
- Windows keeps working because it's the same bond. Re-pairing on either side
  changes the keys, so the import has to be run again.
- **Open:** touch-to-pair on a fresh Linux install without Windows.

**Charge status (2026-09-24).** The OSD is a local shell plugin (`turbinebmw.pen`):
- It shows a pen battery bar when the pen connects.
- It shows "Pen charging" when the Battery Level rises during a connection.

On Linux, the docked pen stays connected for only about 25 s. It sends nothing while
docked and then disconnects itself (reason 0x13). It sometimes reconnects on its own
when pulled out soon afterwards.

Driver reading (SurfacePenBleLcAddrAdaptationDriver and the Loosely-Coupled code in
`Microsoft.Bluetooth.Service.dll`):
- **Charger pen status:** the charger's report 0x14 carries the pen address (usage
  2), bits 0x08/0x0D/0x0E and battery 0x0C.
  - Windows only reads it. No host write enables it.
  - On Linux it never arrives, and nothing shows at the SSAM level either.
  - A get-feature request for 0x14 times out, and `surface_hid` can't fetch input
    reports.
- **Host auto-bonding setup:** feature 0x70 bit 0 (usage 0x10) is the host
  capability. Bit 1 (usage 0x22) is set by the device.
  - Windows writes `70 01`, then `56 <host BD_ADDR, LSB first> <flag: usage 0x09>`.
  - Sending the same from Linux enabled nothing visible.
- **FHID:** feature 0x73 is copied from the charger to the digitizer. The SP12
  charger returns `ffff` (unsupported).
- **Pen address from the pen ID (reports 0x54/0x6E):**
  - `h` = first 8 bytes of SHA1(`f876af012e1c2840918f6f605e6b1fd6` || PenID,
    big-endian), read as a little-endian integer.
  - The address is `((h ^ hostAddr) & 0x3FFFFFFFFFFF) | 0xC00000000000` when the
    device is auto-bonding capable (usage 0x12), else `(~h & …) | 0xC0…`.
  - Output 0x55 carries an 8-byte "Security Key" for the pen.
  - This is the start of touch-to-pair. The LTK/IRK derivation isn't traced yet.
  - `ioctl_adaptation_cmd` is `0x9C402401`.

`windows/sp12-pen-probe.ps1` reads the 0C8E features Windows has set (read only) and
logs every 0C8E report through cued dock/undock, with Microsoft's
`BluetoothStack.wprp` (verbose) running.

#### 8b: NFC card reading
Phones work; a passive contactless card isn't detected on Linux, though Windows
reads it easily (Phase 5). Capture Windows' NCI traffic across an NFC device restart
and a card tap (WPP trace of the five NfcCx GUIDs, decoded against the NfcCx source
in `private/nfc/nfccx`) to find the RF settings or card-detection mode the NXP
client driver applies; then apply them from nxp-nci, RAM only.

#### 8c: battery charge limit: done (sp12-modules 1.12, tools 1.11)
`sp12-charge-limit 80` holds the battery at 80% (50-99, or `off` for adaptive). It's
saved in `/etc/sp12/charge-limit` and applied by udev when BAT1 appears. DKMS `0024`
adds `charge_control_end_threshold` to `surface_battery`, found from the Windows
drivers (`SurfaceBatteryMiniport`/`SurfaceBatteryClient`) and the Surface app's
.NET battery service (`BatteryDm.exe`):
- **User charge mode:** BAT target command `0x0a`, 5 bytes `{u8 mode; __le32
  threshold}`. Modes: 0 = Adaptive, 1 = UserLimit, 2 = UnlimitedWithTimeout. No
  response, and no known read-back.
- **Support check:** the SAM protection policy (SAM 0x01/0x01 command `0x3a`, read,
  1 byte) has bit 0x10 BatteryChargeLimit set. Windows sets `{0x10,0x10}` with
  `0x2f` at D0; the SP12 reads `0x10`. Other bits: 0x01 BatteryLimit (the 50% UEFI
  limit), 0x02 ThermalOverride, 0x04 DisplayOverride, 0x08 CutTheTop.
- **Other commands:** ProtectionStatus `0x41` (`80 09` while limiting), BPM counters
  `0x42`/`0x43`, BAT MaxCharge `0x69` (1 while limiting), PCC enable `0x65` and
  predictions `0x64` (adaptive), BAT `0x46` = **battery shutdown (never send)**.
- **Test:** a limit below the current charge stops charging on AC at once;
  adaptive resumes it within seconds. `private/battery/ssam-req.py` sends raw
  requests via `surface_aggregator_cdev`.

Original notes: there was no charge limit on Linux. The battery is reported by the Surface
embedded controller (`surface_battery` under `MSHW0743`), whose power_supply has no
`charge_control_*` or `charge_behaviour` attributes. Two routes:
1. **Surface UEFI "Battery Limit":** a fixed 50% cap, applied by the firmware whatever
   OS is running. Check whether the SP12 firmware has the option.
2. **Windows smart charging:** trace SSAM on Windows while toggling the Surface app's
   charging settings. The same `ssh_rtl_rx_data` / request logging as the posture
   work should find the battery-subsystem command. Then add
   `charge_control_end_threshold` (and `charge_behaviour` if the EC supports it) to
   `surface_battery` in our DKMS modules, so standard tools (e.g. TLP, a
   `power_supply` udev rule) can set it.

#### 8d: OLED PSR2 without the pulse
With xe's default PSR2 (selective update, selective fetch), the OLED pulses faintly on a
mostly still screen, and Windows doesn't. A live A/B via debugfs `i915_edp_psr_debug`
(1 = off, 3 = force PSR1) removed it.
- `psr_safest_params=1` doesn't keep PSR2: with the safest wake lines it doesn't fit,
  and the driver falls back to PSR1.
- **Shipped:** tools 1.20 `/usr/lib/modprobe.d/sp12-display.conf` sets
  `xe enable_psr=1` (PSR1).
- **Panel:** eDP 1.5 with PSR2 (DPCD 0x070 = 03). Brightness goes through Intel's
  HDR AUX interface in nits (0x344 = 0x90); the TCON has an optimization capability
  that isn't enabled.

To do:
- Find out whether Windows runs PSR2 on this panel and with what parameters.
- Tune PSR2 (wake lines, SU granularity, early transport, IO/fast wake) with drm
  debug on.
- Report it to the xe/PTL display maintainers if there's a panel quirk to add. The
  gain is the extra idle power of PSR2 over PSR1.

### Post-work: upstream reports (once everything is up)
- **#2144, POS event storm (`0008`):** everyone running the SP12 registry entry has
  ~13% CPU from boot. Include the payload layout `{source, old, new}`, the
  sources-list replay trigger, and the before/after numbers.
- **IPU7 ISYS snoop (`0016`):** linux-media (staging ipu7 maintainers). Stale-cache
  dashes on any IPU7 laptop with libcamera's soft ISP; one-line fix, before/after
  evidence.
- **libcamera:** the IMX681 helper/properties (`pkg/libcamera-sp12` 0001–0003), the
  AGC `exposureGainThreshold` (0004), and the GPU-ISP downscale aliasing reproducer.
- **IMX681 driver fixes** (`0012`–`0015`) as review comments on linux-surface/kernel#176.
- `0006` PN560 GPIO roles (with a working tag read) and `0005` (zR-JB's, confirm it's
  merged).
