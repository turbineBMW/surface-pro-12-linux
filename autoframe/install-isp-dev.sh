#!/bin/sh
# Dev test of the ISP-side crop (run as root): install the sp12-camera-hal
# package that carries the zoom-region patches, then the element in ISP mode
# into the front relay (install-dev.sh with AUTOFRAME_MODE=isp).
#   sudo autoframe/install-isp-dev.sh [path/to/sp12-camera-hal-*.pkg.tar.zst]
set -eu
HERE=$(dirname "$(readlink -f "$0")")
R=$(dirname "$HERE")
PKG=${1:-$(ls -t "$R"/pkg/sp12-camera-hal/sp12-camera-hal-*.pkg.tar.zst | head -n1)}
pacman -U --noconfirm "$PKG"
AUTOFRAME_MODE=isp "$HERE/install-dev.sh"
