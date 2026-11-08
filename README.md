# Linux on the Surface Pro 12 (Intel)

Bring-up for the **Microsoft Surface Pro for Business 13in 12th Edition, Intel**
(Core Ultra Series 3 / Panther Lake, SSAM platform hub `MSHW0743`), on Arch and
[Omarchy](https://omarchy.org). Companion to
[surface-pro-11-linux](https://github.com/turbineBMW/surface-pro-11-linux).

Experimental. One tested unit: `Surface_Pro_for_Business_13in_12th_Ed_Intel_2103`,
UEFI 12.15.143, kernels `linux-omarchy` 7.2.x and 7.4.0-rc1 (the hardware ISP
needs 7.4).

## Status

| Area | State | How |
|---|---|---|
| Flex Keyboard + touchpad (attached), hotplug | ✅ | SSAM registry entry `MSHW0743` (`dkms/`) |
| Battery, AC, fan, temperatures, platform profiles | ✅ | same |
| Tablet-mode switch (POS) | ✅ | zero-padded source-list fix; source-ID caching stops a posture event storm (~13% CPU) (`dkms/`) |
| Battery charge limit | ✅ | `surface_battery` charge threshold (`dkms/`) + `sp12-charge-limit N\|off` |
| Suspend, lid-open wake | ✅ | `surface_gpe` entry, GPE `0x30` (`dkms/`); S0ix reached, ~0.3 W asleep. A panic in the EC UART's DMA teardown at suspend, which left the tablet dead after closed-lid wake loops, is fixed in the 7.4 series (`dkms/patches-7.4/0033`, `0034`); `kernel.panic=60` reboots instead of draining |
| Keyboard wake from suspend | ✅ | attached (SSAM) and over Bluetooth: DKMS keeps the keyboard's LE link, patched BlueZ (`pkg/bluez-sp12`) quiets it over sleep |
| Power / volume buttons | ✅ | `soc_button_array` probe-order fix (`dkms/`) |
| Touchscreen + Slim Pen | ✅ | stock `i2c_hid_acpi`; tail button over BLE via `sp12-pen-pair` (click / double click / hold), and the pen does not wake the system |
| NFC (NXP PN560) | ✅ | GPIO roles fix (`dkms/`); phones and contactless cards; reader daemon `sp12-nfc` + Omarchy plugin |
| Flex Keyboard detached over Bluetooth | ✅ | LE legacy OOB SMP (`dkms/`) + `sp12-flex-pair` (`userspace/`) |
| Accelerometer / ALS / auto-rotation | ✅ | Microsoft's ISH firmware (not redistributable, see below); `sp12-als` streams the light sensor for auto-brightness |
| Speakers, mic, Wi-Fi, Bluetooth, backlight | ✅ | stock kernel |
| Limine (Omarchy's bootloader) | ✅ with patches | NX_COMPAT + firmware-memory fix (`limine/`, `pkg/limine`) |
| Limine `protocol: linux` | ❌ | freezes after handoff; `protocol: efi` / UKI works (see `docs/limine.md`) |
| Rear (OV13858) + front (IMX681) cameras | ✅ | `ov13858` power, new `imx681`, `ipu-bridge` entries (`dkms/`). Two pipelines: the IPU7 hardware ISP (kernel 7.4+, `isp/`, `dkms/psys/`) or libcamera's software ISP (`pkg/libcamera-sp12`); apps and browsers get them through PipeWire |
| Automatic framing (front camera) | ✅ | face-following crop in the hardware ISP, YuNet on the NPU (`autoframe/`, `pkg/sp12-autoframe`), Omarchy bar widget |
| IR camera (VD55G0) + emitter | ✅ | `vd55g1` with VD55G0 support (`dkms/`); GREY 644×604 on `/dev/sp12-ir`; face unlock works with `facelock` (AUR) |

## Layout

- `dkms/` — DKMS package `sp12-modules`: patched `surface_aggregator_registry`,
  `surface_aggregator_tabletsw`, `surface_gpe`, `surface_battery`,
  `surface_charger`, `surface_platform_profile`, `bluetooth`,
  `soc_button_array`, `nxp-nci_i2c`, the camera sensors and IPU7 ISYS, and the
  IPU7 PSYS hardware-ISP module (`dkms/psys/`). `prepare-sources.sh`
  fetches the exact sources for the kernel being built (Arch `-archN` tags, or
  upstream stable tags for e.g. `linux-omarchy`), or uses a bundled `cache/`.
  Kernels before 7.4 use `patches/` and the staging `intel-ipu7-isys`; 7.4 and
  later use `patches-7.4/` and `intel-ipu6-isys`, which drives IPU7 from 7.4.
- `userspace/` — `sp12-flex-pair` (Flex Keyboard Bluetooth pairing over the
  wired OOB channel), reconnect-on-detach (udev rule + service), the
  libcamera software-ISP default (`environment.d`), and the NFC reader daemon
  (`sp12-nfc`) with its Omarchy plugin (`omarchy/plugins/sp12.nfc`: chime and
  popup on every read; `sp12-nfc plugin install`), plus the pen, charge-limit,
  light-sensor and IR-camera helpers shipped in `sp12-flex-tools`.
- `isp/` — hardware ISP (IPU7.5 PSYS) userspace: patches for Intel's camera HAL
  and `icamerasrc`, sensor configs, the tools that convert the Windows graph
  settings, and the build scripts for the local `sp12-camera-hal` package.
  Its Windows inputs stay in `private/`. Plan: `docs/hardware-isp-plan.md`.
- `autoframe/` — `sp12autoframe`, the GStreamer element for automatic framing.
  Plan: `docs/auto-framing-plan.md`.
- `pkg/` — PKGBUILDs: `limine` (patched, `epoch=1`), `sp12-modules-dkms`,
  `sp12-flex-tools`, `libcamera-sp12` (libcamera 0.8.0 + Surface Pro 12 camera
  support), `pipewire-libcamera-sp12` (PipeWire's libcamera plugin rebuilt for
  libcamera 0.8 until Arch ships it), `bluez-sp12` (BlueZ with the sleep
  patch for keyboard wake), `sp12-camera-hal` and `sp12-autoframe` (hardware
  ISP and automatic framing; the HAL package is built locally and never
  published), `sp12-ish-firmware` (private, see below).
  `bluez-sp12` and `pipewire-libcamera-sp12` track Arch's exact versions:
  rebuild them when Arch updates bluez or pipewire.
- `iso/` — builds an Omarchy ISO with all of the above in its offline mirror
  (`build-sp12-iso.sh`, on top of the official omarchy-iso build).
- `limine/` — the Limine/PicoEFI fixes, debugging patches, the Project Mu QEMU
  reproduction and decoders. Write-up: `docs/limine.md`.
- `limine-nx-test/` — boot-once (`BootNext`) test kit used on the hardware.
- `install.sh`, `install-ish-firmware.sh` — install on an existing Arch system.

## Install on Arch

```sh
sudo pacman -S --needed dkms linux-headers
sudo ./install.sh                     # DKMS modules + Flex Keyboard tools
# ISH firmware from Microsoft's driver MSI (msitools):
msiextract -C extracted SurfacePro12withIntel_Win11_*.msi
sudo ./install-ish-firmware.sh extracted/SurfaceUpdate/ishheciextension/FwImage/0004/IshS_SI.bin
sudo reboot
sudo sp12-flex-pair                   # optional: pair the Flex Keyboard for detached use
```

## Omarchy ISO

```sh
SP12_ISH_FW=/path/to/IshS_SI.bin iso/build-sp12-iso.sh   # private ISO (includes the firmware)
iso/build-sp12-iso.sh                                     # shareable ISO
```

`iso/test-vm-install.sh <iso> <mu-fv-dir>` installs the ISO unattended in QEMU
and boots the result under Project Mu with the Surface-like NX policy
(`limine/qemu/build-q35.sh`), then checks the loader, DKMS modules and packages.

The live ISO boots `linux-t2` without these modules, so use a USB keyboard in
the installer; the Flex Keyboard works from the first boot of the installed system.

## Microsoft firmware

The ISH image (`IshS_SI.bin`, SHA-256 `921e34f8…a8ea1`, platform `0004` = PTL in
`surface_ext_ishheci.inf`) comes from Microsoft's
[driver MSI](https://www.microsoft.com/en-us/download/details.aspx?id=108671)
and is not redistributable. It is never committed here; an ISO built with
`SP12_ISH_FW` must stay private.

## License

Everything written for this project (userspace tools, services, the Omarchy
plugin, scripts, PKGBUILDs and docs) is under the MIT license, see `LICENSE`.
Exceptions:

- **Patches** are under the license of the project they patch: the Linux kernel
  (`dkms/patches*`, GPL-2.0-only), libcamera (`pkg/libcamera-sp12`,
  LGPL-2.1-or-later), BlueZ (`pkg/bluez-sp12`, GPL-2.0-or-later) and Limine
  (`limine/patches`, `pkg/limine`, BSD-2-Clause).
- **Arch packaging:** `pkg/bluez-sp12`, `pkg/libcamera-sp12/PKGBUILD` and
  `pkg/pipewire-libcamera-sp12/PKGBUILD` derive from Arch Linux's PKGBUILDs
  (0BSD, see `pkg/bluez-sp12/LICENSE`). The PipeWire patch is a backport of an
  upstream commit (MIT).
- **`windows/BluetoothStack.wprp`** is Microsoft's, unmodified, from
  [microsoft/busiotools](https://github.com/microsoft/busiotools) (MIT).
- **Camera tuning values** (colour matrices, lens shading tables) in the libcamera
  patches come from the camera modules' Windows tuning files, as noted in each
  patch, for interoperability with this hardware.

## Credits

SSAM registry, tablet-switch and camera enablement by zR-JB in
[linux-surface#2144](https://github.com/linux-surface/linux-surface/issues/2144)
(linux-surface/kernel#171, #173); ISH firmware and lid GPE findings by MosesKim84
in the same issue. Bluetooth OOB pairing ported from surface-pro-11-linux.
AI tools (Claude) materially assisted development and debugging.
