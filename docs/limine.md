# Limine on the Surface Pro 12 (Intel)

Stock Limine 12.9.0 (Omarchy's bootloader) never runs on this machine: the
firmware skips its boot entry and falls through to the next one. Two separate
bugs are involved; both are fixed by `limine/patches/` (packaged in `pkg/limine`).

## 1. Firmware refuses images without NX_COMPAT

The Surface firmware is Project Mu based and enforces
`BlockImagesWithoutNxFlag`: `LoadImage` rejects any EFI image whose PE header
lacks `IMAGE_DLLCHARACTERISTICS_NX_COMPAT` (0x0100). Limine's PE header is
hand-written in PicoEFI (`picoefi/x86_64/entry.S`) with DllCharacteristics 0.
systemd-boot (0x0160) and the kernel's EFI stub (0x0100) carry the flag.

- Hardware: stock `BOOTX64.EFI` is skipped; the identical file with only that
  bit set is loaded.
- QEMU: Mu Q35 v15.0.2 with the policy enabled (`limine/qemu/`) rejects stock
  Limine with *"The platform attempted to load an EFI application which does
  not have the NX_COMPAT DLL Characteristic…"*. With the flag, Limine runs to its
  menu and boots Linux under the full Mu memory-protection profile (no faults).

Fix: `0002-picoefi-x86_64-set-nx-compat.patch` (PicoEFI).

## 2. Writing firmware-owned memory freezes the machine

With the flag set, Limine froze before drawing anything. NVRAM breadcrumbs
(`limine/patches/debug/`, read back from efivarfs after a forced power-off)
placed the hang in `init_memmap()` (`common/mm/pmm.s2.c`), in the loop that
"leaves 64MiB to the firmware below 4GiB": it reserves 64 x 1MiB in Limine's
own memory map via `ext_mem_alloc_type()`, which **zeroes** the memory. That
memory is still `EfiConventionalMemory` owned by the firmware (Limine has not
called `AllocatePages` on it yet, and is leaving it to the firmware anyway); the
Surface firmware traps the write (first chunk `0x67b57000`) and hangs.

Open-source Mu declares `FreeMemoryReadProtected` but does not implement it,
so QEMU cannot reproduce this; it was confirmed on hardware: skipping the zeroing
lets `init_memmap()` finish (38 `AllocatePages`, 0 failures, 78 map entries,
~31.5 GiB free) and Limine reaches its menu.

Fix: `0001-limine-mm-pmm-do-not-zero-memory-left-to-the-firmware.patch` — the
reservation goes through a non-zeroing path; every other `ext_mem_alloc*`
caller keeps zeroed memory. All ports build without warnings.

The loop is not arch-specific, which makes it a likely cause of
[Limine#587](https://github.com/Limine-Bootloader/Limine/issues/587)
(Surface Pro 11, BOOTAA64.EFI "hangs before any output").

## 3. `protocol: linux` freezes after handoff (unsolved)

With both fixes, `protocol: efi` works: chainloading systemd-boot, and booting
`vmlinuz-linux` through its own EFI stub with
`cmdline: initrd=\intel-ucode.img initrd=\path\initramfs.img root=…`. Omarchy
uses UKIs (`ENABLE_UKI=yes`), i.e. `protocol: efi`, so it is unaffected.

`protocol: linux` freezes: the kernel never prints (not even with
`earlyprintk=efi,keep ignore_loglevel`), no lockup watchdog or initramfs timer
fires, and the machine does not reset. Established so far:

- Limine completes its handoff: runtime-services breadcrumbs after
  `ExitBootServices` reach the final `common_spinup()` call; the spinup
  trampoline's `EFI_MEMORY_XP` is cleared successfully via
  `EFI_MEMORY_ATTRIBUTE_PROTOCOL` (same as QEMU).
- The 32-bit handoff path is used (kernel at 16MiB, initrd at 0x5e700000).
- Not: graphics (`module_blacklist=xe`), KASLR (`nokaslr`), x2APIC (CPU has
  `LEGACY_XAPIC_DISABLED`, but Limine already detects it and keeps x2APIC), CET
  (CR4.CET clear, S_CET 0 at handoff).
- QEMU (Mu, also with `-cpu host`) boots the same kernel through the same path.

So the kernel dies between Limine's 32-bit spinup and its first console output,
on this hardware only.

## Reproducing

```sh
limine/qemu/build-q35.sh                 # Mu Q35 with the Surface-like image policy
limine/qemu/run-q35.sh <esp-dir> [secs]  # firmware log, serial, screenshot in out/
limine/tools/peinfo.py BOOTX64.EFI       # NX_COMPAT and section permissions
```

On the hardware, `limine-nx-test/limine-nx-test.sh` installs a build to
`\EFI\limine-nx-test\` with a `--create-only` boot entry and boots it once via
`BootNext`; `limine/tools/handoff.py` and `memdbg.py` decode the NVRAM records.
