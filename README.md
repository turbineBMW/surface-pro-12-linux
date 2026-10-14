# Linux on the Surface Pro 12 (Intel)

Bring-up for the **Microsoft Surface Pro for Business 13in 12th Edition, Intel**
(Core Ultra Series 3 / Panther Lake, SSAM platform hub `MSHW0743`), on Arch and
[Omarchy](https://omarchy.org). Companion to
[surface-pro-11-linux](https://github.com/turbineBMW/surface-pro-11-linux).

Experimental. One tested unit: `Surface_Pro_for_Business_13in_12th_Ed_Intel_2103`,
UEFI 12.15.143, kernels `7.2.6-arch2-1` and `linux-omarchy` 7.2.5.

## Status

| Area | State | How |
|---|---|---|
| Flex Keyboard + touchpad (attached), hotplug | ✅ | SSAM registry entry `MSHW0743` (`dkms/`) |
| Battery, AC, fan, temperatures, platform profiles | ✅ | same |
| Tablet-mode switch (POS) | ✅ | zero-padded source-list fix; source-ID caching stops a posture event storm (~13% CPU) (`dkms/`) |
| Lid-open wake from s2idle | ✅ | `surface_gpe` entry, GPE `0x30` (`dkms/`); S0ix reached |
| Power / volume buttons | ✅ | `soc_button_array` probe-order fix (`dkms/`) |
| NFC (NXP PN560) | partial | powers up and polls (`dkms/`); no tag detected yet (RF config) |
| Flex Keyboard detached over Bluetooth | ✅ | LE legacy OOB SMP (`dkms/`) + `sp12-flex-pair` (`userspace/`) |
| Accelerometer / ALS / auto-rotation | ✅ | Microsoft's ISH firmware (not redistributable, see below) |
| Limine (Omarchy's bootloader) | ✅ with patches | NX_COMPAT + firmware-memory fix (`limine/`, `pkg/limine`) |
| Limine `protocol: linux` | ❌ | freezes after handoff; `protocol: efi` / UKI works (see `docs/limine.md`) |
| Rear (OV13858) + front (IMX681) cameras | ✅ | `ov13858` power, new `imx681`, `ipu-bridge` entries (`dkms/`) + patched libcamera (`pkg/libcamera-sp12`); PipeWire/browsers via libcamera |
| IR camera (VD55G0) | ❌ | planned (`docs/peripheral-plan.md`) |

## Layout

- `dkms/` — DKMS package `sp12-modules`: patched `surface_aggregator_registry`,
  `surface_aggregator_tabletsw`, `surface_gpe`, `bluetooth`, `soc_button_array` and
  `nxp-nci_i2c`. `prepare-sources.sh`
  fetches the exact sources for the kernel being built (Arch `-archN` tags, or
  upstream stable tags for e.g. `linux-omarchy`), or uses a bundled `cache/`.
- `userspace/` — `sp12-flex-pair` (Flex Keyboard Bluetooth pairing over the
  wired OOB channel), reconnect-on-detach (udev rule + service), the
  libcamera software-ISP default (`environment.d`), and the NFC reader daemon
  (`sp12-nfc`) with its Omarchy plugin (`omarchy/plugins/sp12.nfc`: chime and
  popup on every read; `sp12-nfc plugin install`).
- `pkg/` — PKGBUILDs: `limine` (patched, `epoch=1`), `sp12-modules-dkms`,
  `sp12-flex-tools`, `libcamera-sp12` (libcamera 0.7.2 + IMX681 support),
  `sp12-ish-firmware` (private, see below).
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
  (`dkms/patches`, GPL-2.0-only), libcamera (`pkg/libcamera-sp12`,
  LGPL-2.1-or-later), BlueZ (`pkg/bluez-sp12`, GPL-2.0-or-later) and Limine
  (`limine/patches`, `pkg/limine`, BSD-2-Clause).
- **Arch packaging:** `pkg/bluez-sp12` and `pkg/libcamera-sp12/PKGBUILD` derive
  from Arch Linux's PKGBUILDs (0BSD, see `pkg/bluez-sp12/LICENSE`).
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
