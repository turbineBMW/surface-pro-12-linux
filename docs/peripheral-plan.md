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
| 5 | NFC, **NXP PN560** | `1FC93002` `I2C4.NFC1`, I²C `0x28`; `_CRS` = IRQ, supply, VEN | **Works** (`0006`, stock nxp-nci core): phones, and contactless cards when polling includes a listen phase (initiator + NFC-DEP target, as Windows does). Reader-only polling misses cards (8b). Daemon + Omarchy plugin: 8b2 | stock nxp-nci + `0006`, tools 1.21 |
| 6 | ~~Unknown~~ Surface Display Hardware Driver (UMDF + `MIS766FpgaFirmware.bin`) | `MSHW0380` `I2C0.FINK`, **no `_CRS`** | unbound | out of scope: the display works without it |
| 7 | ~~SSAM "dropping unexpected command message (rqid = 0x0000)"~~ | `MSHW0084` | **Fixed:** a symptom of a POS event storm (~13% CPU), see `0008` | tabletsw |
| 8 | Suspend | s2idle only | **S0ix reached** on lid close (19.6 s residency). Keyboard wake works attached and over Bluetooth (Phase 4, `0025`/`0026`, bluez-sp12). The dead-battery panic in the EC UART's DMA teardown is fixed (`0033`/`0034`, Phase 4) | |
| 9 | Speakers | `rt1320` | **Fine, not reproduced** (2026-09-24): loud and clean at 100% and at low steps with bass-heavy tracks. #2144 had reported distortion at high volume and low loudness at low volume | |
| 10 | Slim Pen tail button | BLE | **Works** (`sp12-pen-pair`, tools 1.28): Meta+F20 / F19 / F18 for click / double click / hold; any click reconnects, docked or not | bluez |
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

#### Dead battery after a closed-lid suspend (2026-11-05 and 2026-11-07, open)

Twice the tablet was found at 0 % after a lid-closed sleep. Both journals end
the same way: a wake/suspend loop, then a final `PM: suspend entry (s2idle)`
with nothing after it. UPower's battery history gives the rest:

|                                   | 2026-11-05                               | 2026-11-07                                       |
|-----------------------------------|------------------------------------------|--------------------------------------------------|
| battery before the last sleep     | 80 % at 17:24 (charge limit, unplugged)  | 70 % at 18:09                                    |
| long sleep                        | none                                     | 18:13 → 19:17 next day: 25.1 h, 70 → 58 %        |
| wake loop                         | 17:52–18:03, 10 cycles                   | 19:17–20:12, 56 cycles                           |
| asleep / awake per cycle          | 39–83 s / 29 s                           | 2–62 s, then a steady 33–34 s / 29 s             |
| last journal line                 | 18:03:40 suspend entry                   | 20:12:13 suspend entry (battery ~55 %)           |
| found                             | 07:16 next day, 0 %                      | 08:23 next day, 0 %                              |
| draw after the last entry         | ≥ 80 % in 13 h ≈ 3.2 W                   | ≥ 55 % in 12 h ≈ 2.4 W                           |

So s2idle itself is healthy: the 25 h sleep cost 0.48 %/h (≈ 0.26 W, the same
as the 2026-09-23 figure). The battery dies in a state entered after a loop:
ten times the sleep draw, no journal (the console is suspended and journald is
frozen from `suspend entry` on, so a hang in a device callback and a sleep
that never reaches S0ix look identical from the logs). The 29 s awake is
logind's lid holdoff re-suspending with the lid still closed. The wakes came
from the EC's `ssam_wakeup` GPIO (2026-11-06 A/B, pen section); the pen's
Bluetooth wake was turned off that day (tools 1.34), but the 2026-11-07 loop
ran with it off (`WakeAllowed: no`; the pen reconnected on every wake only
because the host was awake), so the EC event behind the loop is still
unknown. Charger-state events do wake the system: the 16:55:01 wake on
2026-11-06 is the second the charge limit flipped the battery from charging
to discharging (SSAM event tc 0x02 cid 0x69, unhandled; cid 0x15/0x16/0x53
= BIX/BST/DPTF came with the wake after the 25 h sleep).

Instrumentation (2026-11-08, `userspace/`):

- `usr/lib/systemd/system-sleep/sp12-sleep-log`: runs at every suspend. Pre:
  snapshots `/sys/class/wakeup/*` counters, battery energy and the LPIT /
  PMC S0ix counters, turns on `pm_debug_messages`, syncs the journal. Post:
  one `sp12-sleep` journal line with the sleep length, S0ix share, battery
  used and average draw, `pm_wakeup_irq` with its name, and every wakeup
  source whose counters moved. `/run/sp12/sleep-sentinel` (seconds) makes it
  arm the RTC at each sleep, so a closed-lid night becomes an hourly record.
- `usr/local/bin/sp12-suspend-test`: `baseline` (one RTC-timed sleep),
  `sentinel SECONDS|off`, `loop` (attended, lid open), `report`, `previous`
  (the cycle table of the last boot). Preflight refuses below 30 % battery
  or on the charger, sets `hung_task_panic=1` + `panic=90` so a suspend
  thread stuck for 2 min reboots instead of draining the battery, and with
  `--trace` turns on `pm_trace` (device name of a hang on the next boot; the
  RTC clock is wrong until the next clean shutdown). A panic's log needs
  efi-pstore, which Arch builds disabled: `etc/limine-entry-tool.d/efi-pstore.conf`
  adds `efi_pstore.pstore_disable=0` to the kernel command line (applied here
  2026-11-08 with `limine-mkinitcpio`, both kernels; active from the next boot).

Plan, once the battery is above ~50 %, on battery:

1. **Baseline, done 2026-11-08** (`sentinel 1800`, lid closed): 1801 s asleep,
   S0ix 99 % by both the LPIT and the PMC counter, 180 mWh = 0.36 W average
   (0.6 %/h, with the suspend/resume seconds inside), woken by IRQ 9 (RTC,
   "ACPI fixed event wakeup"); only `rtc_cmos` (+2 events) and `BAT1`
   (+1, the driver's refresh at resume) moved. One closed-lid sleep is
   healthy. Two findings on the way there: (a) with the **lid open** the
   suspend fails: `isys_suspend` returns -EBUSY because the lock screen that
   Omarchy raises before sleeping starts a face authentication, which opens
   the IR camera a few hundred ms after the facelock daemon "released camera
   for suspend" on logind's PrepareForSleep; systemd retries once and gives
   up (4 failed suspends in the stats, `omarchy-sleep-lock.service` exits 1).
   Lid closed, `pam_facelock` skips (`lid_closed`), so this never touched
   the dead-battery nights, but a lid-open suspend with face unlock cannot
   work until the daemon or the lock refuses new authentications while a
   sleep is pending. (b) `--trace` cannot be combined with RTC wakes:
   `pm_trace` stores its hash in the RTC time registers, so the armed alarm
   never matches. (c) Lid open, suspended by typing `systemctl suspend`, the
   tablet woke after 1-2 s through the EC's wake line (`ssam_wakeup`, GPIO
   IRQ 144 under IRQ 14, no wakeup source credited: `ssam_irq_handle()`
   registers none): the key release and touchpad contact that follow the
   Enter reach the EC, which holds them and wakes the host. The same command
   behind `sleep 10` with hands off slept the full 40 s to the RTC, 97 % S0ix.
   The hook now also diffs the GPIO/ACPI/RTC lines of `/proc/interrupts`, so
   an EC wake is named directly. The NFC reader's IRQ (`nxp-nci_i2c`) fired
   7 times in those 40 s without waking the system.
2. **Loop, done 2026-11-08: reproduced and root-caused** (`sentinel 40`, lid
   closed, EC wake on). The 12th cycle never came back; the machine was at
   the LUKS prompt because the runner had set `kernel.panic=90`, and
   efi-pstore kept the panic. 0.24 s into that suspend, after "Suspending
   console(s)" (so the journal never sees any of this): `intel-lpss
   0000:00:1e.0: dma_pool_destroy dma3chan1 busy`, then a NULL dereference
   in `__dma_tx_complete()` from the idma64 completion tasklet
   (`vchan_complete`) on an idle CPU, "Fatal exception in interrupt", kernel
   panic. dma3chan1 is the TX channel of the EC's UART (`dw-apb-uart.4`,
   ttyS4, the Surface Serial Hub link). Root cause: `uart_suspend_port()`
   clears the port's initialized flag and calls the 8250 shutdown, whose
   `serial8250_release_dma()` terminates and releases the DMA channels
   without the port lock, while nothing stops a write from the serdev
   client (the surface_aggregator packet layer answering an EC frame from
   a worker) from starting a new TX DMA in that window; the transfer
   completes on the released channel. About one suspend in 10-50 hits it
   (cycles 11, 57 and 12 in the three incidents). With `kernel.panic=0`,
   the default, the panicked kernel sits with its CPUs spinning at ~3 W
   until the battery is flat: that is the "found dead" state, and why the
   journal ends at `suspend entry`. The 2026-11-06 pen fix only removed one
   source of the wake loop that gave the race its chances.

   Fixes (2026-11-08): kernel patches `0033` (serial core: `__uart_start()`
   only queues while the port is not initialized) and `0034` (8250_dma:
   detach the channels under the port lock before terminating them, and
   NULL-safe start and completion paths) on `sp12/7.4`, built as
   linux-sp12test -4; upstream has neither as of v7.4-rc1-132 (2026-11-03).
   `etc/sysctl.d/90-sp12-panic-reboot.conf` sets `kernel.panic = 60`, so
   any future panic reboots to the LUKS prompt instead of draining the
   battery, with its log in `/sys/fs/pstore`. Still open: which EC event
   wakes the closed lid every 33 s; with the panic gone the loop costs
   about 1 Wh an hour, nothing worse.
3. **Fixed kernel, done 2026-11-08** (linux-sp12test -4, `sentinel 40`, lid
   closed, 12:28-14:29): 105 cycles, 105 suspends succeeded, 0 failed, no
   panic (the old kernel died on cycles 11, 57 and 12). 104 wakes were the
   RTC (IRQ 9), the last the lid opening, which arrives through the EC's
   wake line (`ssam_wakeup`); S0ix 95-96 % of every 41 s sleep. The loop
   itself cost 80 -> 71 % in two hours, about 2 Wh/h for 30 s awake per
   cycle: that is what a closed-lid EC wake loop costs now that it no
   longer kills the machine, and why the EC event behind it is still worth
   finding. Next: `sentinel 3600`, lid closed, overnight.

**EC wake rule and hibernate (2026-11-08, afternoon).** With the lid closed
the hook now turns the EC's wake line (`serial0-0` wakeup) off for the sleep
and restores it at resume (`/etc/sp12/sleep.conf`, `EC_WAKE_LID_CLOSED=no`):
a closed lid means the attached keyboard, the only user of that wake, cannot
be typed on, and lid-open arrives through ACPI GPE 0x30 ("ACPI non-EC GPE
wakeup", the GPE count moved, `ssam_wakeup` did not) and the power button
through gpio-keys. Verified with a 72 s closed-lid sleep, 99 % S0ix. The hook
also clears and reads the `ssam_rx_event_received` tracepoint around each
sleep, so the post line names the EC events delivered at resume (first
sample, charger plugged: BAT 0x16, 0x18 and 0x69); the event behind the
2026-11-05/07 wake loops will show up there if it recurs with the rule off.

Hibernate works: `systemctl hibernate` wrote a 12 GB image (3.05 M pages,
2.5 s to allocate), reached S4, powered off, and resumed into the same kernel
instance through the LUKS prompt with the session intact. But the IPU does
not survive it: the ISYS firmware then fails to boot ("fw boot timeout,
state 0x57a7e000", PSYS "Runtime PM failed (-16)"), the ISP relays deliver
no frames and libcamera's cameras (same ISYS) are gone too, so face unlock
as well. `ipu6_resume()` is also the restore path (`SYSTEM_SLEEP_PM_OPS`)
and does not re-authenticate the firmware after a power loss. Recovery
without a reboot is not possible either: a PCI remove/rescan of 0000:00:05.0
re-probes with `ipu_bridge_init` failing on `-EEXIST` ("Failed to register
the IPU HID node"), because the bridge only unregisters its software nodes
on an init failure, never on remove; after that the driver is unbound until
a reboot (tried 2026-11-08, cost a reboot). Untried next time: unbind and
rebind only `intel_ipu6.isys.40` on the auxiliary bus. A proper fix is a
`.restore` callback in ipu6 that redoes the buttress authentication (Phase 7
candidate).

Decision: `suspend-then-hibernate` for the lid (logind) and the idle plugin,
with `HibernateDelaySec=48h` and `HibernateOnACPower=no`
(`etc/systemd/sleep.conf.d/30-sp12-hibernate.conf`,
`etc/systemd/logind.conf.d/30-sp12-lid.conf`): a night or a day closed is
never touched (0.3 W, ~6 % per 12 h), a forgotten multi-day close hibernates
instead of draining, and the hook then logs a warning and leaves
`/run/sp12/cameras-need-reboot`. With the panic fixed and `kernel.panic=60`
this is the second net, not the first. The sentinel is only armed for plain
suspends, so an overnight record now comes from the battery history, not
hourly wakes.

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
  **Since tools 1.28 a click reconnects** (see the privacy pairing under "Other
  open items" in Phase 9).
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

**Revisited 2026-11-04: viable; plan in [`hardware-isp-plan.md`](hardware-isp-plan.md).**
Two of the findings below were wrong: the Windows `graph_settings_*.bin` are
the HAL's own static-graph format (`0x5c63b5e7` is the Windows common hash, not
a format marker) and already use the Linux linear graph 100002, and the 7.4
`ipu6` driver now creates the IPU7 PSYS device and maps its firmware, so a PSYS
module ports onto it rather than onto the staging core. Another laptop's sensor
runs on PSYS from converted Windows files (ipu7-camera-hal#74). Also, face
unlock gains nothing from PSYS: irlume refuses loopback devices.

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

#### 8b: NFC card reading: solved (2026-09-25), no kernel change
Phones worked, but a passive contactless card wasn't detected on Linux, though
Windows reads it easily (Phase 5).

**Cause:** the PN560 misses passive cards when discovery is reader-only. The kernel's
`RF_DISCOVER` for all reader protocols is `21 03 09 04 00 01 01 01 02 01 06 01`
(NFC-A/B/F/V poll). Windows adds NFC-A/F listen (`80`, `82`) and an NXP proprietary
mode (`70`).
- With the listen modes, the stock nxp-nci/nci stack reads the card (ISO14443-A,
  sens_res 4400, sel_res 20).
- The kernel adds those listen modes when START_POLL also asks for NFC-DEP target
  mode (`NFC_ATTR_TM_PROTOCOLS`). That's neard's "Dual" poll mode;
  `private/nfc/nfc-poll.py --tm` does it too.
- Likely mechanism: without a listen phase, the idle part of each discovery cycle
  uses low-power card detection, which a phone trips and a card doesn't. Unverified.

**Windows capture:** `out/nfc/nci-spb.csv`, from SPB class-extension ETW
`{72cd9ff7-...}` event 1023. It gives the full startup and two card activations.

**Bisected over raw I²C** (`pn560-nci.py --windows --drop ...`, logs
`private/nfc/probe-9..13`):
- Windows' extras aren't needed: `2F 02`, `A112=01` (it persists: reads 01 before
  any write), `2F 21`, `TOTAL_DURATION` 500 ms, and its discover map.
- A keep-configuration `CORE_RESET` looked needed after one run without it. The
  stock reset-configuration core then read the card with listen modes, so that run
  was a missed tap. A draft nxp-nci setup-hook patch was dropped
  (`private/nfc/0027-...`).
- Only the poll list mattered. The kernel's list missed the card; with the listen
  modes added, it was read.

**Open:** an upstream note for PN560/PN7160 (reader-only discovery misses passive
cards). A userspace consumer (neard isn't installed) must poll in dual mode.

#### 8b2: NFC reader daemon and Omarchy plugin (tools 1.21, 2026-09-25)
A userspace consumer for the reader, since neard isn't installed and the PN560 needs
dual-mode polling.
- **`sp12-nfc.service`** (`/usr/lib/sp12/sp12-nfc`, root: the NFC netlink commands
  need `CAP_NET_ADMIN`; started by udev when `nfc0` appears): keeps the device up and
  polling (all reader protocols plus NFC-DEP target mode), and on every target it
  opens an `AF_NFC` `SOCK_SEQPACKET` socket (connect via ctypes, Python has no
  `sockaddr_nfc`) to read what it can:
  - Type 2 tags (NTAG, Ultralight): the NDEF message (text, URI, smart poster, MIME).
  - ISO-DEP: NDEF Type 4 application, else the PPSE directory (brand from the
    RID, label, AID). Only the directory is read: no PAN or records.
  - FeliCa, ISO 15693, Type 1: identity only.
  Events go out as JSON lines on `/run/sp12-nfc/events` (Unix stream socket, a
  `reader` status line on connect) and the last read to `/run/sp12-nfc/last`. A
  fixed UID seen again within 3 s is the same presence (no new event); random
  ISO14443-A UIDs (`08:xx`, phones) are one presence while they keep appearing.
  Discovery restarts after each read (0.6 s), on SIGHUP, and on resume (detected
  by a CLOCK_BOOTTIME jump). The device is taken down on stop, so nxp-nci can be
  removed afterwards.
- **`sp12-nfc`** CLI: `watch [--json]`, `last`, `status`, `demo [kind]`, and
  `plugin install|remove` (copies the plugin below into
  `~/.config/omarchy/plugins/sp12.nfc` and enables it).
- **Omarchy plugin `sp12.nfc`** (`userspace/omarchy/plugins/sp12.nfc`, shipped in
  `/usr/share/sp12/omarchy/plugins`): a `service` that connects to the socket
  (retry every 3 s; a repeat `connected = true` is a no-op in Quickshell, so it
  toggles), plays `complete.oga` with `pw-play`, and shows a card at the top left
  (next to the antenna, below the bar using the notification plugin's bar-size
  lookup): title (brand, "Link", "Text", ...), technology and UID, then the lines.
  Click or 8 s closes it. IPC: `omarchy-shell nfc show|close|last|state|debug`.
  Settings are the properties at the top of `Service.qml`.
- **Gotcha:** the shell hot-reloads a saved plugin but the QML engine keeps the
  compiled component, so edits to a loaded `Service.qml` need `omarchy restart shell`.
- **Verified:** the popup and chime via `sp12-nfc demo`. Card/phone reads through
  the daemon: see the session notes below this line once tested.
- **Next:** user scripts on reads, e.g. `~/.config/omarchy/hooks/nfc-read.d/` run by
  the plugin with the event JSON on stdin (or `sp12-nfc watch --json | ...`).

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

#### 8d: OLED PSR2 without the pulse: closed
With xe's default PSR2 (selective update, selective fetch), the OLED pulses faintly on a
mostly still screen, and Windows doesn't. A live A/B via debugfs `i915_edp_psr_debug`
(1 = off, 3 = force PSR1) removed it.
- `psr_safest_params=1` doesn't keep PSR2: with the safest wake lines it doesn't fit,
  and the driver falls back to PSR1.
- **Shipped:** tools 1.20 `/usr/lib/modprobe.d/sp12-display.conf` sets
  `xe enable_psr=1` (PSR1).
- **Back to PSR2 (tools 1.22, 2026-09-26):** the pulse is faint and only shows
  sometimes, so the driver default is kept to find the conditions that bring it out.
  The `options` line in `sp12-display.conf` is commented out (uncomment it for PSR1).
  Installing 1.21 hadn't rebuilt the UKI (pacman's mkinitcpio hook doesn't watch
  `modprobe.d`), so the next boot still ran the old settings; 1.22 adds
  `90-sp12-display-initramfs.hook` to rebuild it on changes to the conf.
- **Windows' sink config live (0x170 = 0x65, CRC verification):** no visible difference
  on a boot where the pulse showed. Turning it on set sink 0x2006 = 01 (link CRC error).
- **Panel:** eDP 1.5 with PSR2 (DPCD 0x070 = 03). Brightness goes through Intel's
  HDR AUX interface in nits (0x344 = 0x90); the TCON has an optimization capability
  that isn't enabled.

**Closed (2026-11-04):** weeks of daily use on the default PSR2 brought no further pulse,
so the first sightings were a fluke. The machine stays on PSR2 (tools 1.22's commented-out
`options` line). If it comes back: uncomment the line for PSR1, and compare Windows' PSR2
parameters and the wake-line/SU tuning noted above.

#### 8e: Flex Keyboard updates from the SP11 (tools 1.26, 2026-11-04)
The SP11's `surface-pro-11-support` package (omarchy-pkgs, 1-3) moved on after the
autopair port in tools 1.25. Carried over:
- **`sp12-flex-pair`:** clears a bonding left pending by an interrupted run
  (`btmgmt cancelpair`, else Busy 0x0a), gives up a pair after 45 s with the
  wedged-LE-connect explanation and the controller reset to try, keeps Pairable on
  only for the pairing (try/finally), lists other connected devices for context,
  and reads the host address fresh before storing the connection interval.
  `SP12_FLEX_ADDRESS_FILE` overrides the address file.
- **`sp12-touchpad-mode` sleep hook:** after resume, a `systemd-run` job reads the
  attached touchpad's (SAM `0019:045E:0C8D`) Input Mode (feature 0x84) and
  surface/button switches (0x85), and restores mode 3 with both switches on, as
  hid-multitouch does at attach. On the SP11 the touchpad came back in mouse mode
  after about 1 in 60 resumes; not yet seen here, but the keyboard and endpoint are
  the same. Only the SAM interface: BlueZ cuts the Bluetooth GET_FEATURE reply to
  the report ID byte, so a mode read there is meaningless.
- **Tests:** `pkg/sp12-flex-tools/test.sh` (stubbed bluetoothctl/btmgmt/hidraw, run
  by the PKGBUILD's `check()`): autopair, reconnect-on-detach, the touchpad hook.

Not carried:
- ~~**Privacy waits** in autopair/reconnect~~: carried in tools 1.28 with the
  privacy pairing (Phase 9, "Other open items").
- **Touchpad quirk:** the SP11 uses `AttrTPKComboLayout=below` for palm rejection over
  Bluetooth; here the hwdb marks the touchpad internal (palm detection on) and the
  quirk adds `ModelTabletModeNoSuspend`, which covers it.

Hardware check (2026-11-04, tools 1.26, keyboard brought back from the SP11):
- **Attach** with the bond the SP11 had re-keyed: the bond didn't connect, a controller
  reset didn't help, so it was replaced and paired over the wire on the first try,
  about 60 s with no input. The 7.5-11.25 ms interval was stored.
- **Detach:** typing over Bluetooth at once (the link was already up from the pairing).
- **Re-attach** with a working bond: "bond healthy; nothing to do" within 0.1 s.
- **Pairable:** on before and after. The adapter's settings file is empty, so BlueZ's
  default is pairable here (the 10-13 run didn't have to turn it on either).
- **Suspend** with the keyboard attached (2.5 min s2idle, the Bluetooth link kept):
  the touchpad hook ran as its own job 0.08 s after resume and found touchpad mode
  with both switches on, so it logged nothing.
- **`--status`** found the channel and capability; no device report came within 20 s
  with the bond in place, as its message allows. It re-sends the host address to
  prompt the report, so the help no longer says "change nothing".

### Phase 9: kernel 7.4 and the camera stack (in progress)
Survey on 2026-11-04 (running 7.2.8-9-omarchy). The 7.4-rc1 commits below were checked in
`~/Projects/linux` (`git describe --contains`). The rest is from a web survey, with links.

**Why now:** v7.4-rc1 (2026-11-01) moves IPU7 into the mainline **ipu6** driver, and our
IPU7 patches target the staging ipu7 driver. Arch will move to 7.4 within weeks.
- `2f4ffd14b6c0` "media: ipu6: Enable support for IPU 7 and IPU 7.5":
  `CONFIG_VIDEO_INTEL_IPU6_IPU7` defaults to y. Built in, staging ipu7 probes only with
  `intel_ipu7.force_probe=1`. ipu6 has `force_no_probe_ipu7` for the reverse.
- `9d6b3fa3f5bd`: the staging TODO now says the driver "will be removed soon in favour
  of supporting IPU7 and later in the ipu6 driver".
- `f21f57ca4e55` "media: ipu6: Add the ipu7 psys buttress support": upstream PSYS will
  build on ipu6 (no PSYS series found; lore wasn't reachable from the survey).
- `7eef49c16461`: v4l2-subdev pad ops (`get_fmt`/`set_fmt`/`get/set_selection`) take a
  `struct v4l2_subdev_client_info *`. This affects our sensor drivers.

**Affected patches:**
- **IPU7 ISYS (staging, to move to ipu6):**
  - `0016` the snoop fix. The ipu6 IPU7 output pin is memset and never sets
    `link.is_snoop`, so it's still needed.
  - `0020`/`0021` Y10/Y10P/GREY. ipu6's table has GREY/Y10/Y10P/Y12. Check that the
    frame-format codes are right for IPU7 firmware.
- **Sensors (pad-op signature):** `0010`, `0012`–`0015` imx681; `0009` ov13858;
  `0017`/`0018`/`0022`/`0023` vd55g1.
- **Bridge:** `0011`/`0019` ipu-bridge entries (likely unchanged; check).
- **Userspace:** `sp12-ir-camera.service` / `70-sp12-ir-camera.rules` link CSI2 1 to ISYS
  Capture 8 by entity name. Check the entity names under ipu6.

**Plan:**
1. A worktree of `~/Projects/linux` at v7.4-rc1. Build ipu6 with IPU7 plus our sensor
   drivers, and port `0016`/`0020`/`0021` onto ipu6 and the pad-op changes onto the sensors.
2. DKMS: carry ipu6 (=m in Arch's config? check) or keep staging via `force_probe` as a
   stopgap. Decide once Arch's 7.4 config is known.
3. Test on hardware: both RGB cameras through libcamera, the IR camera (`/dev/sp12-ir`,
   Y8 644x604, emitter strobe), face unlock, and the snoop dashes gone under motion.
4. Upstream `0016` against ipu6 (linux-media), not staging (see Post-work).

**Progress (2026-11-04): steps 1–3 done (below).**
- Worktree `~/Projects/linux-7.4`, branch `sp12/7.4` on v7.4-rc1: the series
  rebased, one commit per patch. Exported as `dkms/patches-7.4/` (same numbers;
  applying it to v7.4-rc1 reproduces the branch exactly).
- Rebase changes: `0006` uses the new `.id =` ACPI table style. `0010` takes the
  `client_info` pad-op argument (the only sensor that needed it; ov13858 and
  vd55g1 were converted upstream). `0011` drops OVTID858 (upstream since
  2ee01a094aba, same frequencies). `0017` adds the VD55G0 as a fourth entry in
  vd55g1's new version table (vd55g4 support, 7a1e5239ae63) and skips the
  colour-version read for it (0x0670, never read on our hardware). `0018` joins
  SMO55F0 to the new upstream ACPI table (TBE20A1).
- `0016` is now `media: ipu6: ipu7: ...`, setting `is_snoop` in
  `ipu7-fw-isys.c`. `0020`/`0021` are dropped: ipu6's table already has
  GREY/Y10/Y10P, the CSI-2 receiver accepts Y8/Y10, and ipu6 passes its IPU6
  frame-format codes to IPU7 firmware, which are equal to IPU7's
  (RAW8 = 20, RAW10 = 21, RAW16 = 24).
- DKMS 1.15: `prepare-sources.sh` and `dkms.conf` pick `patches-7.4/` and build
  `intel-ipu6-isys` for 7.4+, or `patches/` and `intel-ipu7-isys` before 7.4.
  Arch already builds `VIDEO_INTEL_IPU6=m`, and `VIDEO_INTEL_IPU6_IPU7`
  defaults to y, so ipu6 claims the IPU on 7.4. Both paths build all 13
  modules (7.2.8 headers; the 7.4 tree with modpost warnings only).
- Our IPU is 8086:b05d, **IPU 7.5** (Panther Lake). Under ipu6 the entities
  are named `Intel IPU7.5 CSI2 1` / `Intel IPU7.5 ISYS Capture 8` and the media
  driver is `intel-ipu6` (libcamera's simple pipeline already lists it).
  `sp12-ir-graph` reads the prefix from the graph; the udev rule matches
  `Intel IPU7* ISYS Capture 8`.

**Step 3 (2026-11-04, test kernel `7.4.0-rc1-sp12` built from `sp12/7.4`):
cameras, IR, face unlock and the snoop fix all work.**
- ipu6 claims the IPU (`intel-ipu6`, model `ipu7.5`) and all three sensors
  bind: OV13858 on CSI2 0 (4 lanes), VD55G0 on CSI2 1 (1 lane), IMX681 on
  CSI2 2. libcamera lists the rear (camera 1, OV13858) and front (camera 2,
  IMX681). Both stream and converge to normal images.
- IR: tools 1.27 (the IPU7.5-aware rule and `sp12-ir-graph`) brings up
  `/dev/sp12-ir`. ipu6's default route carries Y8 to Capture 8: GREY 644x604,
  every frame complete, emitter on alternate frames (mean ~101 lit, ~15 dark).
- **`0027` (ISYS):** IPU7 firmware acks FLUSH and CLOSE without returning the
  2–3 buffers it still holds (SOF, never PIN_DATA_READY). ipu6's
  `return_buffers()` then sets `need_reset`, and every `open()` fails with
  EIO ("isys power cycle required"). The flag is set after the stream drops
  its runtime-PM reference, so the suspend that should clear it can come
  first: on stock 7.4-rc1 the camera opened after an IR stream failed until
  something else cycled the ISYS. Staging ipu7 returned these buffers without
  a reset (and closed the firmware per stream). `0027` skips the flag on
  IPU7. Kept awake by a 450-frame front stream, five IR start/stops on the
  firmware without a reset each got every frame, and the front stream lost
  none. **Upstream candidate** (linux-media, with `0016`): the ordering bug
  hits IPU6 too.
- **`0028` (VD55G0 power):** the rear's 4-lane port 0 aggregates PHY 0 and
  PHY 1, and the IR lane is on PHY 1. While the VD55G0 is powered (even in
  standby), the rear camera gets PHY ready but no SOF, and stop/close time
  out. vd55g1's 4 s autosuspend kept it powered after every IR stream: rear
  0 s and 3 s after IR failed, 8 s and 15 s worked. `0028` suspends at
  stream stop. The two cameras can never stream at the same time (Windows
  can't either, presumably).
- With both, 24 streams in every order (IR→rear, IR→front→rear, rear→IR)
  all complete, no kernel errors. The DKMS path builds the same
  `srcversion`s as the tested modules. `prepare-sources.sh` now maps RC
  kernels to their tag (`7.4.0-rc1-sp12` → `v7.4-rc1`).
- Face unlock works (`facelock test` and the lock screen). The Facelock IR
  quirk (private, `60-sp12-ir.toml`) matched the card name `ipu7`, anchored.
  Under ipu6 the card is `ipu7.5`, which gave "IR camera required". The
  pattern is now `ipu7.*`; restart `facelock-daemon` after a quirk change.
- Dashes under motion (`0016`), 1920x1080 CPU ISP, `dashscore` over 80
  frames while moving: front 30 (worst frame 3), rear 1100 (worst 43). The
  rear runs are colour fringes along clipped window-blind slat edges: they
  stack over adjacent rows, are not on a 32-pixel grid, and 86% of their
  pixels are within 4 rows of a saturated pixel. Only 25 of 1096 runs (none
  on the front) match the previous frame more than their neighbours do, the
  signature of stale data, and all 25 are on the blinds (a periodic pattern
  that pans onto itself). None are on unclipped edges, so there are no snoop
  dashes; `0016` holds on 7.4. `dashscore` counts clipped horizontal edges,
  so keep windows out of frame for A/B runs.
- **Step 3 done.**

**Related, after the port:**
- **libcamera v0.8.0** (2026-11-01): **done, libcamera-sp12 0.8.0-1.1** (2026-11-04).
  Series in `private/camera/libcamera` branch `sp12/0.8.0` (`sp12/0.7.2` is the
  old one rebuilt from the package patches). Upstream renamed the IPA to
  `softisp` (tuning files now in `/usr/share/libcamera/ipa/softisp/`) and moved
  AGC, AWB and CCM onto libipa:
  - `0004` (AGC threshold) is tuning only now: `AeExposureMode` stages of
    1/60 s, then gain to the analogue maximum (IMX681 16x, OV13858 8191/128),
    then longer exposure. The soft ISP applies no digital gain, so a stage gain
    above the analogue maximum would stall the helper.
  - `0010` (AWB) keeps the 16x12 zone statistics and grey-zone selection and
    feeds their colour to libipa's Bayes AWB, with the locus as `colourGains`
    (1/(R/G), 1/(B/G)), a flat prior, `transversePos/Neg` 0.06 (was
    `offLocus`) and an `AwbMode` Auto range over the locus (Bayes requires
    one). libipa's fixed 0.2 smoothing equals our old `speed`. The zones count
    every pixel; upstream's global sums exclude saturated ones.
  - `0005`/`0006` CCMs carry over (same `ccms`/`ct`/`ccm` keys). Upstream LSC
    (17x17, IPA `Lsc` algorithm) only reaches the GPU debayer, and we run the
    CPU ISP, so our `0009` LSC (63x47 `.aiqb` tables, top-level `lensShading`)
    stays. `0011` uses `PixelFormatInfo` for the output bytes per pixel
    (upstream dropped `DebayerOutputConfig::bpp`).
  - A/B against 0.7.2, CPU ISP 1080p: same fps (29.95 rear, 30.01 front),
    AWB gains and CT within a few percent. The front is no longer
    overexposed (mean 148 vs 194; upstream's mean-luminance AGC).
  - libcamera's soname moved to 0.8, so `pkg/pipewire-libcamera-sp12` rebuilds
    PipeWire 1.6.9's libcamera plugin (only that plugin) against it, with
    upstream's 0.8 compatibility fix (54f2f51) backported. Its `pipewire=`
    dependency is exact: when Arch updates pipewire, rebuild it at the new
    version, or drop it once Arch's pipewire-libcamera links 0.8. Install
    order on a 0.7 system: `pacman -Rdd pipewire-libcamera`, install
    libcamera 0.8, build and install the plugin.
  - ~~The IR sensor makes libcamera log "Unable to set controls: Permission
    denied" before it's skipped~~: fixed in libcamera-sp12 0.8.0-1.2
    (2026-11-06). Cause: for the VD55G0, our vd55g1 patch makes the controls
    it hasn't verified read-only (flips, test pattern, vblank, AE, HDR), and
    libcamera's sensor setup writes the flips and test pattern regardless
    (EACCES, then "Failed to create sensor ... -22", "No valid pipeline").
    Making them writable would be worse: the soft ISP can't debayer GREY, so
    the simple pipeline would pass the IR stream through raw and apps would
    list an IR camera. Patch `0012` adds `pipelines.simple.ignored_sensors`
    to libcamera's configuration file, and the package's `configuration.yaml`
    lists `vd55g1`: the sensor is skipped before any device is opened, with
    one debug line. The IR camera is still used through `/dev/sp12-ir`.
    The other libcamera noise, `ov13858` without a selection API ("Unable to
    get rectangle 0-3 ... Inappropriate ioctl", 5 ERROR lines per
    enumeration), is patch `0032` (DKMS 1.20): native 4256x3168, active
    4224x3136 at (16,16), and each mode's crop (nominal for the binned modes,
    whose borders the registers give only to a few pixels; the Windows
    4076x2806 window is exactly centred). Verified 2026-11-06 after a reboot:
    `cam -l` and wireplumber log no errors (two warnings remain: no OV13858
    sensor delays in libcamera's sensor database, no CCM `offsets` in our
    tuning files), CROP reads (16,16)/4224x3136 in the default mode, both
    cameras capture through libcamera and through the ISP relays, and five IR
    streams in a row complete without CSI errors. An IR stream started while
    the rear ISP relay was still streaming failed (stop/close time out), as
    `0028` predicts: the rear and IR cameras share PHY 1 and can't stream
    together.
- **GPU ISP: tried 2026-11-04, CPU ISP stays.** "debayer_egl: Fix texture sampling
  steps" (patchwork 28702, 2026-10-29, unreviewed: step 1/stride and 1/height instead
  of 1/(stride-1), 1/(height-1)) on libcamera-sp12 0.8.0, front camera 1920x1080:
  the frame breaks into rectangular tiles of different colour casts with magenta and
  cyan vertical stripes (Bayer phase flipping by region once the step is exactly one
  texel), `gridscore` 1.00. Without it, 0.8.0's GPU ISP shows no obvious 1-px grid at
  4x (score 0.94 vs 0.72 on the CPU; the GPU path has no TNR/CNR, so pixel noise
  raises the score). The CPU ISP stays the default anyway: our binning, TNR, CNR and
  LSC are CPU-only. Multi-pass GPU ISP is still only the 2026-06 RFC.
- **Watch:** soft-ISP temporal denoise (Božik, unmerged) and the AIQB-to-simple-IPA parser
  (Tia, v3) overlap our TNR/`.aiqb` work. intel/ipu7-drivers #102: OV08F4 stalls on 7.2.x.
- **PSYS stays blocked:** ipu7-camera-hal's 2026-09-26 release still has no graph
  settings for IMX681/OV13858/VD55G0. ipu7-drivers fixed #63's layout (858ab56), but
  its PSYS still needs Intel's core patches (`patch/v7.0.0_iot/0001`, `0005`).
- **Compare:** onuralpszr/xps-fedora#45 switched to Intel's own ISYS for Y10 on an IR
  sensor and a CSI-2 oops fix. Check whether it overlaps `0020`/`0021`.

**Other open items carried forward:**
- ~~Port the SP11's native pen pairing~~: **done, tools 1.28** (2026-11-04).
  - `sp12-pen-pair` is now the SP11's `surface-pro-11-pen-pair` (Python). It
    forgets old pen bonds, turns LE privacy on (`sudo btmgmt`, with the radio
    off) so BlueZ gives the pen an IRK and identity address, pairs Just Works
    after you approve the device found, then turns privacy back off.
    `sp12-pen-forget` forgets the pen.
  - Result: after undocking, one click reconnects the pen and runs the action,
    as on Windows. No 7 s hold, and no Windows key import
    (`sp12-bt-import-windows`) needed.
  - **Bug found and fixed:** turning privacy off power-cycles the radio. The
    first run did that while BlueZ was still reading the pen's HID Report Map
    on the pairing connection (`uhid_create() … Transport endpoint is not
    connected`). BlueZ kept the truncated 309-byte map in memory and replayed it
    on every reconnect, and the kernel rejected it ("item fetching failed at
    offset 308/309"): the pen connected but its buttons did nothing until
    bluetoothd restarted. `sp12-pen-pair` now waits for the pen's input devices
    before turning privacy off. A clean re-pair worked at once.
  - `sp12-flex-autopair` and `sp12-flex-bt-autoconnect` wait out a pen pairing
    (privacy on): no stale-bond verdict, no repair marker, no controller reset
    while it runs, and repeated pairings don't keep the reconnect job alive.
    Ported with the SP11's tests (`pkg/sp12-flex-tools/test.sh`).
  - **Touch-to-pair: won't do** (decided 2026-11-04). Windows derives the pen's
    bond from the digitizer's pen ID with no pairing step. On the SP11 that
    needed BlueZ/kernel Bluetooth changes the Linux Bluetooth maintainers
    weren't keen on, and the SP11 and SP12 should behave the same. Pairing
    stays manual (`sp12-pen-pair`), as on the SP11.
  - **The pen does not wake the system** (tools 1.34, 2026-11-06). BlueZ marks
    every HID device WakeAllowed, so DKMS `0026` kept the pen's link up over
    suspend next to the keyboard's, and with the lid closed the tablet woke every
    30-60 s. Logind suspends again after its 30 s lid holdoff, so it looped: on
    2026-11-05 a closed lid gave 11 cycles in 11 minutes, then a hang on the 11th
    suspend (black screen, no wake, battery flat by morning). A/B with
    `pm_debug_messages`, Flex Keyboard attached, pen connected, lid closed:
    - pen WakeAllowed off: one suspend, 232 s, until the lid opened (1 link kept);
    - pen WakeAllowed on: 23 wakes in 23 minutes. 19 were IRQ 14 (Intel GPIO)
      through `ssam_wakeup`, i.e. an EC event (the SSAM driver logs "dropping
      unexpected command message" at each), and 4 were the Bluetooth controller
      itself (ACPI GPE, BlueZ wake event 0x3). The touchscreen digitizer, on the
      same GPIO controller, logged no wakeups.
    Which EC event the awake pen causes is not known (a guess: charge status
    from the pen holder relayed by the keyboard). `sp12-pen-pair` now runs
    `bluetoothctl wake <pen> off` after pairing: the pen's link drops at suspend
    and a click reconnects it after resume. The keyboard keeps WakeAllowed.
- The upstream submissions under Post-work. `0008` is committed in `~/Projects/linux-tabletsw`
  and waits for the user's sign-off.

### Post-work: upstream reports (once everything is up)
- **#2144, POS event storm (`0008`):** everyone running the SP12 registry entry has
  ~13% CPU from boot. Include the payload layout `{source, old, new}`, the
  sources-list replay trigger, and the before/after numbers.
- **IPU7 ISYS snoop (`0016`):** linux-media, against the **ipu6** driver's IPU7 support (7.4+;
  staging ipu7 is being removed, see Phase 9). Stale-cache
  dashes on any IPU7 laptop with libcamera's soft ISP; one-line fix, before/after
  evidence.
- **libcamera:** the IMX681 helper/properties (`pkg/libcamera-sp12` 0001–0003), the
  AGC `exposureGainThreshold` (0004), and the GPU-ISP downscale aliasing reproducer.
- **IMX681 driver fixes** (`0012`–`0015`) as review comments on linux-surface/kernel#176.
- `0006` PN560 GPIO roles (with a working tag read) and `0005` (zR-JB's, confirm it's
  merged).
