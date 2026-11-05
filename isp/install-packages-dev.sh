#!/bin/sh
# Install the freshly built sp12-modules-dkms (with the PSYS driver) and
# sp12-flex-tools (PSYS udev rule), as root. The hand-built 7.4 kernel has no
# build directory, so it gets a link to the kernel tree it was built from;
# DKMS then builds our modules and v4l2loopback for it too. Dev helper; the
# packaged kernel will ship headers and need none of this.
#   sudo isp/install-packages-dev.sh
set -eu
HERE=$(dirname "$(readlink -f "$0")")
R=$(dirname "$HERE")
KVER=7.4.0-rc1-sp12
TREE=/home/turbinebmw/Projects/linux-7.4

if [ ! -e /lib/modules/$KVER/build ] || [ -L /lib/modules/$KVER/build ]; then
	ln -sfn "$TREE" /lib/modules/$KVER/build
	echo "build dir: /lib/modules/$KVER/build -> $TREE"
fi

pacman -U --noconfirm \
	"$R"/pkg/sp12-modules-dkms/sp12-modules-dkms-1.17-1-any.pkg.tar.zst \
	"$R"/pkg/sp12-flex-tools/sp12-flex-tools-1.30-1-any.pkg.tar.zst

# Everything registered with DKMS, for the running kernel (v4l2loopback too).
dkms autoinstall -k "$KVER" || true
echo "== dkms status"
dkms status
echo "== modules for $KVER"
ls /lib/modules/$KVER/updates/dkms/ 2>/dev/null | tr '\n' ' '; echo
udevadm control --reload
udevadm trigger --subsystem-match=psys 2>/dev/null || true
ls -l /dev/ipu7-psys0
