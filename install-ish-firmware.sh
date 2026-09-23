#!/bin/sh
# Install Microsoft's Surface ISH (sensor hub) firmware for the Surface Pro 12
# (Intel) under the vendor-specific name the kernel ISH loader looks for.
# Without it the loader falls back to Intel's generic ish_ptl.bin, which this
# ISH rejects, and no accelerometer/ALS/gyro is available (no auto-rotation).
#
# The image cannot be redistributed; take it from Microsoft's driver MSI:
#   msiextract -C extracted SurfacePro12withIntel_Win11_*.msi
#   sudo ./install-ish-firmware.sh extracted/.../ishheciextension/FwImage/0004/IshS_SI.bin
set -eu

src=${1:?usage: install-ish-firmware.sh <path to IshS_SI.bin>}

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

# The loader's most specific name: CRC32 of sys_vendor, product_family,
# product_name and product_sku (drivers/hid/intel-ish-hid/ishtp/loader.c).
name=$(python3 -c '
import zlib
d = lambda f: open("/sys/class/dmi/id/" + f).read().rstrip("\n").encode()
print("ish_ptl_" + "_".join("%08x" % zlib.crc32(d(f)) for f in
      ("sys_vendor", "product_family", "product_name", "product_sku")) + ".bin")')

dst=/lib/firmware/updates/intel/ish/$name
install -Dm644 "$src" "$dst"
echo "installed $dst"

# Reload the ISH driver so the new image is picked up without a reboot.
modprobe -r intel_ish_ipc intel_ishtp_hid intel_ishtp 2>/dev/null || true
modprobe intel_ish_ipc
