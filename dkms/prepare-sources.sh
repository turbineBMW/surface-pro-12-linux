#!/bin/sh
# Fetch the kernel sources for the target kernel, apply the SP12 patches, and
# lay them out for an out-of-tree build. Run by DKMS as PRE_BUILD from the
# build directory; also usable by hand:
#   ./prepare-sources.sh 7.2.6-arch2-1
#   ./prepare-sources.sh --cache 7.2.5-6-omarchy   # write cache/<tag>.tar.gz
#
# Arch 'linux' kernels use the matching archlinux/linux tag. Any other kernel
# (e.g. linux-omarchy) uses the upstream stable tag of its version; its own
# patches do not touch the files replaced here. A tarball in cache/ named after
# the tag is used instead of the network, which offline installs rely on.
set -eu

make_cache=
if [ "${1:-}" = --cache ]; then
	make_cache=1
	shift
fi
kver=${1:?usage: prepare-sources.sh [--cache] <kernel release>}

if printf '%s\n' "$kver" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?-arch[0-9]+-[0-9]+$'; then
	kind=arch
else
	kind=upstream
fi
case "$kind" in
arch)
	# 7.2.6-arch2-1 -> v7.2.6-arch2 (drop the package release)
	tag="v${kver%-*}"
	repos="https://github.com/archlinux/linux.git"
	;;
*)
	# 7.2.5-6-omarchy -> v7.2.5; 7.3.0-1-foo -> v7.3
	ver=$(printf '%s\n' "$kver" | sed -n 's/^\([0-9]*\.[0-9]*\)\(\.[0-9]*\)\{0,1\}.*/\1\2/p')
	[ -n "$ver" ] || { echo "prepare-sources: cannot parse '$kver'" >&2; exit 1; }
	ver=${ver%.0}
	tag="v$ver"
	repos="https://github.com/gregkh/linux.git https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
	;;
esac

here=$(pwd)
rm -rf src surface bluetooth input nfc
mkdir src
if [ -f "$here/cache/$tag.tar.gz" ]; then
	echo "prepare-sources: using cached $tag"
	tar -xzf "$here/cache/$tag.tar.gz" -C src
else
	git -C src init -q
	git -C src sparse-checkout set --no-cone /drivers/platform/surface/ /net/bluetooth/ \
		/drivers/input/misc/soc_button_array.c /drivers/nfc/nxp-nci/
	fetched=
	for repo in $repos; do
		echo "prepare-sources: fetching $tag from $repo"
		git -C src remote remove origin 2>/dev/null || true
		git -C src remote add origin "$repo"
		if git -C src fetch -q --depth 1 --filter=blob:none origin "refs/tags/$tag"; then
			fetched=1
			break
		fi
	done
	[ -n "$fetched" ] || { echo "prepare-sources: could not fetch $tag" >&2; exit 1; }
	git -C src checkout -q FETCH_HEAD
	rm -rf src/.git
fi

if [ -n "$make_cache" ]; then
	mkdir -p "$here/cache"
	tar -czf "$here/cache/$tag.tar.gz" -C src drivers net
	echo "prepare-sources: wrote cache/$tag.tar.gz"
	rm -rf src
	exit 0
fi

for p in "$here"/patches/*.patch; do
	echo "prepare-sources: applying $(basename "$p")"
	patch -d src -p1 --forward --batch -s < "$p"
done

mkdir surface
cp src/drivers/platform/surface/surface_aggregator_registry.c \
   src/drivers/platform/surface/surface_aggregator_tabletsw.c \
   src/drivers/platform/surface/surface_gpe.c surface/
cat > surface/Kbuild <<'KB'
obj-m += surface_aggregator_registry.o surface_aggregator_tabletsw.o surface_gpe.o
KB

# Build only bluetooth.ko; rfcomm, bnep, hidp and 6lowpan stay stock.
cp -r src/net/bluetooth bluetooth
grep -vE '^obj-\$\(CONFIG_BT_(RFCOMM|BNEP|HIDP|6LOWPAN)\)' bluetooth/Makefile > bluetooth/Kbuild

mkdir input
cp src/drivers/input/misc/soc_button_array.c input/
echo 'obj-m += soc_button_array.o' > input/Kbuild

# Build only nxp-nci_i2c.ko; the nxp-nci core stays stock.
mkdir nfc
cp src/drivers/nfc/nxp-nci/i2c.c src/drivers/nfc/nxp-nci/nxp-nci.h nfc/
printf 'obj-m += nxp-nci_i2c.o\nnxp-nci_i2c-objs := i2c.o\n' > nfc/Kbuild
rm -rf src
