#!/bin/sh
# Dev install of the hardware-ISP relay (run as root): the relayd instance,
# its systemd drop-in (pointing at the HAL dev prefix) and the loopback
# module options from userspace/etc, the v4l2loopback module for this hand-built 7.4 kernel (no DKMS
# build dir, so loaded from a scratch build for this session), then the relay
# service enabled and started. The package will replace all of this.
#   sudo isp/install-relay-dev.sh [path/to/v4l2loopback.ko]
set -eu
HERE=$(dirname "$(readlink -f "$0")")
R=$(dirname "$HERE")
P=$R/private/camera/psys/work/prefix
KO=${1:-/tmp/claude-1000/-home-turbinebmw-Projects-surface-pro-12-linux/65d22590-a669-4df9-947e-69a7fee5b632/scratchpad/v4l2loopback/v4l2loopback.ko}

install -Dm644 "$R/userspace/etc/modprobe.d/sp12-v4l2loopback.conf" /etc/modprobe.d/sp12-v4l2loopback.conf
install -Dm644 "$R/userspace/etc/v4l2-relayd.d/sp12-front.conf" /etc/v4l2-relayd.d/sp12-front.conf
install -Dm644 "$R/userspace/etc/systemd/system/v4l2-relayd@sp12-front.service.d/sp12-isp.conf" \
	"/etc/systemd/system/v4l2-relayd@sp12-front.service.d/sp12-isp.conf"

# (Re)load the loopback module so the card label matches the config.
if lsmod | grep -q '^v4l2loopback' && ! grep -qx "Surface Front Camera ISP" /sys/devices/virtual/video4linux/*/name 2>/dev/null; then
	systemctl stop v4l2-relayd.service 2>/dev/null || true
	rmmod v4l2loopback
fi
if ! lsmod | grep -q '^v4l2loopback'; then
	if modprobe v4l2loopback 2>/dev/null; then :; else
		insmod "$KO" devices=1 exclusive_caps=1 card_label="Surface Front Camera ISP"
	fi
fi
sleep 1
grep -H . /sys/devices/virtual/video4linux/*/name

systemctl daemon-reload
systemctl enable --now v4l2-relayd.service
systemctl restart v4l2-relayd@sp12-front.service
sleep 2
systemctl --no-pager --lines=3 status v4l2-relayd@sp12-front.service || true
