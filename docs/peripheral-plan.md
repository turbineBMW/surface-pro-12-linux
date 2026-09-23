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
| Sensors | ISH + `IshS_SI.bin` → accel/gyro/magn/ALS/orientation IIO | via `install-ish-firmware.sh` |
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
| 5 | NFC, **NXP PN560** | `1FC93002` `I2C4.NFC1`, I²C `0x28`; `_CRS` = IRQ, supply, VEN | **Powers up and polls (`0006`); a credit card isn't detected** | RF config next |
| 6 | ~~Unknown~~ Surface Display Hardware Driver (UMDF + `MIS766FpgaFirmware.bin`) | `MSHW0380` `I2C0.FINK`, **no `_CRS`** | unbound | out of scope: the display works without it |
| 7 | ~~SSAM "dropping unexpected command message (rqid = 0x0000)"~~ | `MSHW0084` | **Fixed:** a symptom of a POS event storm (~13% CPU), see `0008` | tabletsw |
| 8 | Suspend | s2idle only | **S0ix reached** on lid close (19.6 s residency); keyboard wake and longer suspends still untested | |
| 9 | Speaker tuning | `rt1320` | distorts at high volume, too quiet at low volume (#2144) | |
| 10 | Slim Pen tail button | BLE | untested here | generic BT |
| 11 | Microsoft power/thermal devices | `MSHW0800` TS01–12, `MSFT000A/F/10/12`, `MSHW0801`, `MSHW0299` | unbound | Windows PEP/thermal framework. Probably ignore |
| 12 | HECI `e362` = **Pluton**, `e35d` = **Intel ISSEI** | PCI 00:13.0, 00:18.0 | unbound | out of scope |
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
  room), Windows Hello-style. INT3472 "privacy LED" `SMO55F0_00::privacy_led`
  raises lit frames to ~121 but is not the emitter.
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

### Phase 5: NFC RF
The PN560 powers up and polls but doesn't detect a credit card. Decode Windows'
`CustomEEPROMConfigBlob` (NXP proprietary set-config tags, starting `A0 11 …`) and
send it after `CORE_INIT` from a userspace tool, RAM only first (no EEPROM write
until it's proven). Then decide whether it belongs in `nxp-nci`.

### Phase 6: polish
- Speaker tuning: UCM gain ceiling first (the SP11 method), then an EQ derived from the
  Windows APO settings or the reference recording (PipeWire filter-chain). Look at the
  `rt1320 R0 Calibration` controls.
- Slim Pen tail button: port `sp11-pen-pair`.
- Camera tuning (AWB/CCM/LSC) with the libcamera simple-IPA; Windows `.aiqb` files
  are the reference.
- Optional: MS thermal devices (`MSHW0800` TSxx) if they expose useful temperatures.

### Phase 7: hardware ISP (IPU7 PSYS)
Windows' image quality comes from IPU7's hardware ISP (PSYS): denoise, CCM, AWB and
lens shading, tuned by the `.aiqb` files we already have from Windows
(`private/windows/drivers/imx681_extension…`, `ov13858_extension…`). Linux
currently uses only ISYS plus libcamera's software ISP, which has no noise reduction
or colour matrix. Research Intel's out-of-tree IPU7 PSYS driver and camera HAL
(closed components) on Arch: what exists, how it coexists with PipeWire/libcamera,
and whether our DKMS/package approach can carry it.

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
