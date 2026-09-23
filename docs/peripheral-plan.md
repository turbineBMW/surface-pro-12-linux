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
| IPU7 | `intel-ipu7`, `ipu7ptl_fw.bin` authenticates | no sensors attached, see below |

### Not working or unverified

| # | Device | ACPI | Symptom | Driver in kernel? |
|---|---|---|---|---|
| 1 | Power / volume buttons | `MSHW0040` `\_SB.MSBT` | **Fixed** (`0005` probe order); volume rocker reversed → hwdb swap | `soc_button_array` (=m) |
| 2 | Rear camera, OV13858 | `OVTID858` `I2C3.CAMR` | `failed to find sensor: -5` (not powered) | `ov13858` (=m), needs a power patch |
| 3 | Front camera, IMX681 | `SONY0681` `I2C1.CAMF` | unbound | **no** |
| 4 | IR camera, VD55G0 + illuminator | `SMO55F0` `I2C3.CAM3`, I²C `0x60`, 1-lane CSI link 1, power via `ICL1` | unbound | `vd55g1` (=m) is the sibling part |
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
EVIOCGKEYCODE). Still to check in Windows whether that's SP12 wiring (then it
belongs in `soc_button_array` upstream) or preference.

## Order of work

### Phase 0: capture evidence (about 1 hour, no code)
- Dump ACPI (DSDT + all SSDTs, especially `SsdtNfc` and `IpuSsdt`) into a private
  `acpi/` directory in the repo.
- Mount the Windows partition read-only and grep the INFs for the unknown IDs. Save
  `pnputil`-equivalent notes.
- Suspend test: `systemctl suspend` for 10 minutes, then read
  `/sys/devices/system/cpu/cpuidle/low_power_idle_system_residency_us` (currently 0; no
  suspend has happened this boot yet). With root, also check
  `/sys/kernel/debug/pmc_core/substate_requirements`.

### Phase 1: port known-good patches into `dkms/` (low risk, quick)
- `soc_button_array` deferred-probe fix (from #2144). It's `=m`, so it fits DKMS.
- SP11 `tablet-mode-resume-resync` and `surface-hid-shutdown`, rebased onto our
  `surface_aggregator_tabletsw` patch.
- Instrument `ssam_ll` on the `rqid 0` path to log TC/TID/IID/CID and the payload. Run
  for a day with a dock/undock/suspend cycle. That tells us whether item 7 is an event
  that should be registered or a real request that needs an answer.

### Phase 2: visible cameras (biggest user-visible win; patches exist)
- Rear: `ov13858` power/runtime-PM patch, `ipu-bridge` OVTID858 link-frequency entry, and
  the 180° DMI rotation quirk.
- Front: the `imx681` driver (kernel#164 lineage, D-PHY) and the `ipu-bridge` SONY0681
  entry.
- All targets are `=m` (`ov13858`, `ipu-bridge`, new `imx681`), so they can go in
  `sp12-modules-dkms` or a sibling `sp12-camera-dkms`.
- Userspace: `libcamera` ≥ 0.7.2 plus the IMX681 helper (reconcile your SP11 libcamera
  patches with zR-JB's helper), and PipeWire's libcamera SPA. Package as
  `sp12-camera-tools` or a patched `libcamera` PKGBUILD. Add it to the ISO.
- Before carrying our own copy, check whether zR-JB's series has landed in
  `linux-surface/kernel`.

### Phase 3: identification (DSDT + offline Windows, then one Windows boot)
- MSHW0380 "FINK": identify it from the DSDT and the Windows driver name, then decide
  whether it's worth pursuing.
- NFC: confirm the chip (PN7160 works with `nxp-nci`; PN7220 is a different beast) and
  the GPIOs.
- IR: find the illuminator control path (INT3472 GPIO? an I²C LED driver? SSAM?).
- Then do the single live Windows session: SSAM ETW trace, sleepstudy, speaker
  reference, and pen trace if needed.

### Phase 4: suspend quality
- Measure S0ix residency and find blocking IPs with `pmc_core`. Fix keyboard wake,
  which is probably SSAM/KIP wake events plus what Phase 1 found about `rqid 0`.
- Validate the resume paths: the touchpad finger-count offset seen on SP11, tablet-mode
  resync, and camera runtime-PM.

### Phase 5: driver writing
- **IR camera:** extend `vd55g1` for the VD55G0 (reuse SP11 patch 0017), add ACPI power
  via INT3472, an `ipu-bridge` SMO55F0 entry, and the illuminator control. Then set up
  Howdy from SP11's config.
- **NFC:** add the `1FC93002` ACPI ID to `nxp-nci_i2c` and map its GPIOs. Test with
  `neard`/`nfctool`.
- **MSHW0380:** depends on what Phase 3 finds.

### Phase 6: polish
- Speaker tuning: UCM gain ceiling first (the SP11 method), then an EQ derived from the
  Windows APO settings or the reference recording (PipeWire filter-chain). Look at the
  `rt1320 R0 Calibration` controls.
- Slim Pen tail button: port `sp11-pen-pair`.
- Camera tuning (AWB/CCM/LSC) with the libcamera simple-IPA.
- Optional: MS thermal devices (`MSHW0800` TSxx) if they expose useful temperatures.
