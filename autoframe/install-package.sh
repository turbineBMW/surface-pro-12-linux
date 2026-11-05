#!/bin/sh
# Switch automatic framing from the dev install (install-dev.sh) to the
# sp12-autoframe package, as root: undo the dev install (restores the relay
# config), install the package, which restarts the front relay itself.
#   sudo autoframe/install-package.sh [path/to/sp12-autoframe-*.pkg.tar.zst]
set -eu
HERE=$(dirname "$(readlink -f "$0")")
R=$(dirname "$HERE")
PKG=${1:-$(ls -t "$R"/pkg/sp12-autoframe/sp12-autoframe-*.pkg.tar.zst | head -n1)}

if [ -d /opt/sp12-autoframe-dev ]; then
	"$HERE/uninstall-dev.sh"
fi
pacman -U --noconfirm "$PKG"
systemctl is-active v4l2-relayd@sp12-front.service
