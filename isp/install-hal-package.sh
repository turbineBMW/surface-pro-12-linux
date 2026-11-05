#!/bin/sh
# Switch the hardware-ISP relay from the dev prefix to the sp12-camera-hal
# package, as root. The dev installer (install-relay-dev.sh) put copies of
# the relay configuration under /etc; the package ships them under /usr/lib
# (and the relay confs under /etc, which pacman must own), so the dev copies
# go first. Then both packages, a daemon reload and a relay restart.
#   sudo isp/install-hal-package.sh
# Afterwards, as the desktop user: systemctl --user restart wireplumber
set -eu
HERE=$(dirname "$(readlink -f "$0")")
R=$(dirname "$HERE")

systemctl stop v4l2-relayd@sp12-front.service v4l2-relayd@sp12-rear.service || true
for cam in front rear; do
	rm -rf "/etc/systemd/system/v4l2-relayd@sp12-$cam.service.d"
	rm -f "/etc/v4l2-relayd.d/sp12-$cam.conf"
done
rm -f /etc/modprobe.d/sp12-v4l2loopback.conf /etc/wireplumber/wireplumber.conf.d/50-sp12-isp-cameras.conf

pacman -U --noconfirm \
	"$R"/pkg/sp12-camera-hal/sp12-camera-hal-2025.12.10-2-x86_64.pkg.tar.zst \
	"$R"/pkg/sp12-flex-tools/sp12-flex-tools-1.32-1-any.pkg.tar.zst

systemctl daemon-reload
# The relays are wanted by the PSYS device (udev), not enabled.
systemctl disable v4l2-relayd@sp12-front.service v4l2-relayd@sp12-rear.service 2>/dev/null || true
udevadm control --reload
udevadm trigger --subsystem-match=psys
sleep 2
echo "psys device: $(ls /dev/ipu7-psys0 2>/dev/null || echo none)"
systemctl --no-pager --lines=0 status v4l2-relayd@sp12-front.service v4l2-relayd@sp12-rear.service | grep -E "service -|Active|Drop-In|sp12-isp|zz-dev" || true
echo "Now run: systemctl --user restart wireplumber"
