#!/bin/bash
# Build Intel's IPU7 camera HAL (e5172cc) and icamerasrc (4fb31db) with the
# ipu7-camera-bins (ed16ac7) into a dev prefix, with the Surface Pro 12
# configuration: our sensor profiles, the Windows graph settings converted for
# the in-tree ISYS, and the Windows tuning files. Dev use only (stage 2 of
# docs/hardware-isp-plan.md); the package comes later.
#
# Expects, under private/camera/psys/work: hal/, bins/, icamerasrc/ checked
# out at those commits (shallow fetch of the commit is fine), and under
# private/camera/psys/out/linux the converted graph files (tools/
# stamp-hashes.py then tools/linuxize-100002). Re-runnable: patches apply
# with --forward, cmake and make are incremental.
#
# Another release goes through the environment, e.g. the 2026-09 one
# (docs/camera-colour-plan.md):
#   HAL=$W/hal-2609 BINS=$W/bins-2609 ICAMERASRC=$W/icamerasrc-2609 \
#   BUILD=$W/build-2609 PREFIX=$W/prefix-2609 \
#   GRAPHS=private/camera/psys/out/linux-2609 EXTRA_PATCHES=isp/patches-2609 \
#   isp/build-dev.sh
set -euo pipefail
HERE=$(dirname "$(readlink -f "$0")")
REPO=$(dirname "$HERE")
W=$REPO/private/camera/psys/work
PREFIX=${PREFIX:-$W/prefix}
HAL=${HAL:-$W/hal}
BINS=${BINS:-$W/bins}
ICAMERASRC=${ICAMERASRC:-$W/icamerasrc}
BUILD=${BUILD:-$W/build}
WIN=$REPO/private/windows/drivers
GRAPHS=$(readlink -f "${GRAPHS:-$REPO/private/camera/psys/out/linux}")

mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$BUILD"
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig

# Closed-source libraries (ipu75xa only).
cp -a "$BINS"/lib/*ipu75xa* "$PREFIX/lib/"
cp -a "$BINS/include/ipu75xa" "$PREFIX/include/"
sed "s#^prefix=.*#prefix=$PREFIX#" "$BINS/lib/pkgconfig/ia_imaging-ipu75xa.pc" \
	> "$PREFIX/lib/pkgconfig/ia_imaging-ipu75xa.pc"

# The same patches as the package (isp/patches, in glob order).
for p in "$HERE"/patches/hal-*.patch; do
	patch -d "$HAL" -p1 --forward --batch -s < "$p" || true
done
# Release-specific HAL patches (e.g. EXTRA_PATCHES=isp/patches-2609).
if [[ -n ${EXTRA_PATCHES:-} ]]; then
	for p in "$EXTRA_PATCHES"/hal-*.patch; do
		patch -d "$HAL" -p1 --forward --batch -s < "$p" || true
	done
fi
for p in "$HERE"/patches/icamerasrc-*.patch; do
	patch -d "$ICAMERASRC" -p1 --forward --batch -s < "$p" || true
done
cmake -S "$HAL" -B "$BUILD/hal" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
	-DCMAKE_INSTALL_SYSCONFDIR="$PREFIX/etc" \
	-DBUILD_CAMHAL_ADAPTOR=ON -DBUILD_CAMHAL_PLUGIN=ON -DIPU_VERSIONS=ipu75xa \
	-DUSE_STATIC_GRAPH=ON -DUSE_STATIC_GRAPH_AUTOGEN=ON > "$BUILD/hal-cmake.log"
make -C "$BUILD/hal" -j"$(nproc)" > "$BUILD/hal-make.log" 2>&1
make -C "$BUILD/hal" install > /dev/null

# icamerasrc (slim camhal API), out of tree.
if [[ ! -f $ICAMERASRC/configure ]]; then
	(cd "$ICAMERASRC" && autoreconf --force --install --make > "$BUILD/icamerasrc-autoreconf.log" 2>&1)
fi
mkdir -p "$BUILD/icamerasrc"
(cd "$BUILD/icamerasrc" && export CHROME_SLIM_CAMHAL=ON &&
	"$ICAMERASRC/configure" --prefix="$PREFIX" > "$BUILD/icamerasrc-configure.log" 2>&1 &&
	make -j"$(nproc)" > "$BUILD/icamerasrc-make.log" 2>&1 && make install > /dev/null)

# Surface Pro 12 configuration.
C=$PREFIX/etc/camera/ipu75xa
mkdir -p "$C/sensors" "$C/gcss"
cp "$HERE"/config/sensors/*.json "$C/sensors/"
cp "$GRAPHS"/*.IPU75XA.bin "$C/gcss/"
cp "$WIN/imx681_extension.inf_amd64_8bc8aa270eb92060/imx681_MSHW0740_PTL.aiqb" "$C/"
cp "$WIN/ov13858_extension.inf_amd64_351bd9cc51fd8e38/OV13858_MSHW0741_PTL.aiqb" "$C/"
python3 - "$C/libcamhal_configs.json" <<'PY'
import json, re, sys
p = sys.argv[1]
t = re.sub(r'^\s*//.*$', '', open(p).read(), flags=re.M)
j = json.loads(t)
# The ipu6 driver names the IPU7.5 entities "Intel IPU7.5 CSI2 N"; the HAL
# builds that prefix from this field.
j['Common']['platform'] = 'IPU7.5'
j['Common']['availableSensors'] = ['imx681-uf-2', 'ov13858-wf-0']
open(p, 'w').write(json.dumps(j, indent=4) + '\n')
PY
echo "Built into $PREFIX"
ls "$C" "$C/sensors" "$C/gcss"
