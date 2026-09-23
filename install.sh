#!/bin/sh
# Install the Surface Pro 12 (Intel) kernel modules (via DKMS) and the Flex
# Keyboard Bluetooth pairing tools. Run as root from anywhere:
#   sudo ./install.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
name=sp12-modules
ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$here/dkms/dkms.conf")
kver=$(uname -r)

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
command -v dkms >/dev/null || { echo "dkms is not installed (pacman -S dkms)" >&2; exit 1; }

# Modules installed by hand before the DKMS package existed.
rm -f "/lib/modules/$kver/updates/surface_aggregator_registry.ko" \
      "/lib/modules/$kver/updates/surface_aggregator_tabletsw.ko"
rmdir "/lib/modules/$kver/updates" 2>/dev/null || true

if dkms status -m "$name" -v "$ver" | grep -q .; then
	dkms remove -m "$name" -v "$ver" --all
fi
rm -rf "/usr/src/$name-$ver"
mkdir -p "/usr/src/$name-$ver"
cp -r "$here/dkms/dkms.conf" "$here/dkms/Makefile" "$here/dkms/prepare-sources.sh" \
      "$here/dkms/patches" "/usr/src/$name-$ver/"
dkms add -m "$name" -v "$ver"
dkms install -m "$name" -v "$ver" -k "$kver"

u="$here/userspace"
install -Dm755 "$u/usr/local/bin/sp12-flex-pair" /usr/local/bin/sp12-flex-pair
install -Dm755 "$u/usr/local/libexec/sp12-flex-bt-autoconnect" /usr/local/libexec/sp12-flex-bt-autoconnect
install -Dm644 "$u/etc/udev/rules.d/99-sp12-flex-bt.rules" /etc/udev/rules.d/99-sp12-flex-bt.rules
install -Dm644 "$u/etc/systemd/system/sp12-flex-bt-connect.service" /etc/systemd/system/sp12-flex-bt-connect.service
install -Dm644 "$u/usr/lib/environment.d/60-sp12-libcamera.conf" /etc/environment.d/60-sp12-libcamera.conf
install -Dm755 "$u/usr/lib/sp12/sp12-ir-graph" /usr/local/lib/sp12/sp12-ir-graph
sed 's|/usr/lib/sp12/sp12-ir-graph|/usr/local/lib/sp12/sp12-ir-graph|' "$u/usr/lib/systemd/system/sp12-ir-camera.service" > /etc/systemd/system/sp12-ir-camera.service
install -Dm644 "$u/usr/lib/udev/rules.d/70-sp12-ir-camera.rules" /etc/udev/rules.d/70-sp12-ir-camera.rules
systemctl daemon-reload
udevadm control --reload

echo
dkms status -m "$name"
echo "Done. Reboot to load the new bluetooth and surface modules."
