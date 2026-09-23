#!/bin/bash
# Runs inside the omarchy-iso build container, after the offline mirror has
# been downloaded and pruned and before it is indexed. Builds the Surface Pro
# 12 packages, replaces the stock limine with the patched one, and drops them
# into the mirror.
#   sp12-build-packages.sh <offline mirror dir>
set -euo pipefail

mirror=${1:?usage: sp12-build-packages.sh <offline mirror dir>}
src=/builder/sp12
work=/tmp/sp12-build

rm -rf "$work"
cp -r "$src" "$work"
mkdir -p "$work/out"

pacman --noconfirm -S --needed git nasm mtools llvm lld clang dkms >/dev/null

if ! id builder &>/dev/null; then
	useradd -m -s /bin/bash builder
fi
chown -R builder:builder "$work"

# Bundle kernel sources for the kernels the Surface runs (Omarchy's default and
# stock Arch) whose headers the mirror carries, so DKMS builds offline during
# the install.
kvers=""
for hdr in "$mirror"/linux-omarchy-headers-[0-9]*.pkg.tar.zst "$mirror"/linux-headers-[0-9]*.pkg.tar.zst; do
	[ -f "$hdr" ] || continue
	k=$(bsdtar -tf "$hdr" | sed -n 's|^usr/lib/modules/\([^/]*\)/$|\1|p' | head -1)
	[ -n "$k" ] && kvers="$kvers $k"
done
echo "sp12: bundling kernel sources for:$kvers"

ish_fw=""
if [ -f "$work/private/IshS_SI.bin" ]; then
	ish_fw="$work/private/IshS_SI.bin"
fi

build() {
	echo "sp12: building $1"
	su builder -c "cd '$work/pkg/$1' && PKGDEST='$work/out' SP12_CACHE_KVERS='$kvers' \
		SP12_ISH_FW='$ish_fw' makepkg -f --nodeps --noconfirm --skippgpcheck"
}
build limine
build sp12-modules-dkms
build sp12-flex-tools
if [ -n "$ish_fw" ]; then
	build sp12-ish-firmware
fi
rm -f "$work"/out/*-debug-*.pkg.tar.zst

# The stock limine does not boot on this hardware; the mirror must offer only
# the patched one. limine-[0-9]* leaves limine-snapper-sync and friends alone.
rm -f "$mirror"/limine-[0-9]*.pkg.tar.zst "$mirror"/limine-[0-9]*.pkg.tar.zst.sig
cp "$work"/out/*.pkg.tar.zst "$mirror/"
ls -la "$work"/out/
