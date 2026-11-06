#!/bin/sh
# Undo autoframe/install-dev.sh (run as root): restore the relay config and
# drop-in, remove the staged files, restart the relay.
set -eu
for CONF in /etc/v4l2-relayd.d/sp12-front.conf /etc/v4l2-relayd.d/sp12-front-autoframe.env; do
	[ -f "$CONF.orig" ] && mv "$CONF.orig" "$CONF"
done
rm -f /etc/systemd/system/v4l2-relayd@sp12-front.service.d/zz-autoframe-dev.conf
rm -rf /opt/sp12-autoframe-dev
systemctl daemon-reload
systemctl restart v4l2-relayd@sp12-front.service
