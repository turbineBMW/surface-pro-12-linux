#!/bin/bash
# Build the sp12-camera-hal package (pkg/sp12-camera-hal). Stages the inputs
# makepkg cannot fetch into pkg/sp12-camera-hal/private (gitignored): the
# HAL, bins and icamerasrc checkouts from private/camera/psys/work, our HAL
# patches, the sensor profiles, the converted graph settings and the Windows
# tuning files, and the relay configuration. Then runs makepkg.
# Stage 6 of docs/hardware-isp-plan.md. The package is not published.
set -euo pipefail
HERE=$(dirname "$(readlink -f "$0")")
REPO=$(dirname "$HERE")
W=$REPO/private/camera/psys/work
WIN=$REPO/private/windows/drivers
PKG=$REPO/pkg/sp12-camera-hal
P=$PKG/private

rm -rf "$P"
mkdir -p "$P/patches" "$P/config/sensors" "$P/graphs" "$P/tuning" "$P/userspace"
# Pristine upstream trees (the work checkouts have the dev patches applied).
for r in hal bins icamerasrc; do
	git -C "$W/$r" archive --format=tar --prefix="$r/" HEAD | tar -xf - -C "$P"
done
cp "$HERE"/patches/*.patch "$P/patches/"
cp "$HERE"/config/sensors/*.json "$P/config/sensors/"
cp "$REPO"/private/camera/psys/out/linux/IMX681_MSHW0740.IPU75XA.bin \
   "$REPO"/private/camera/psys/out/linux/OV13858_MSHW0741.IPU75XA.bin "$P/graphs/"
cp "$WIN/imx681_extension.inf_amd64_8bc8aa270eb92060/imx681_MSHW0740_PTL.aiqb" \
   "$WIN/ov13858_extension.inf_amd64_351bd9cc51fd8e38/OV13858_MSHW0741_PTL.aiqb" "$P/tuning/"
cp -a "$REPO/userspace/etc" "$P/userspace/"

cd "$PKG"
makepkg -f "$@"
ls -1 "$PKG"/sp12-camera-hal-*.pkg.tar.zst | tail -n1
