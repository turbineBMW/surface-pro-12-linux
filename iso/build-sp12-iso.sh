#!/bin/bash
# Build an Omarchy ISO for the Surface Pro 12 (Intel): the official omarchy-iso
# build plus the patched Limine and the Surface Pro 12 packages in its offline
# mirror, installed onto the target by the stock installer.
#
#   SP12_ISH_FW=/path/to/IshS_SI.bin ./build-sp12-iso.sh   # private ISO, with
#                                                            # the ISH firmware
#   ./build-sp12-iso.sh                                      # shareable ISO
#
# Output: $WORK/omarchy-iso/release/*.iso. An ISO built with SP12_ISH_FW
# contains Microsoft's firmware and must not be shared.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
ISO_REPO=${ISO_REPO:-https://github.com/omacom/omarchy-iso}
ISO_REF=${ISO_REF:-7cfb711}
WORK=${WORK:-$HOME/Projects/sp12-iso-build}
export SUDO_ASKPASS=${SUDO_ASKPASS:-$HOME/.local/bin/sudo-askpass}

iso=$WORK/omarchy-iso
rm -rf "$iso"
mkdir -p "$WORK"
git clone -q "$ISO_REPO" "$iso"
git -C "$iso" checkout -q "$ISO_REF"
python3 "$here/iso/apply-sp12.py" "$iso"

# Everything the in-container package build needs, under the read-only /builder.
sp12=$iso/builder/sp12
mkdir -p "$sp12/pkg"
cp "$here/iso/sp12-build-packages.sh" "$sp12/"
for p in limine sp12-modules-dkms sp12-flex-tools sp12-ish-firmware; do
	mkdir -p "$sp12/pkg/$p"
	find "$here/pkg/$p" -maxdepth 1 -type f \
		\( -name PKGBUILD -o -name '*.patch' -o -name '*.install' \) \
		-exec cp {} "$sp12/pkg/$p/" \;
done
mkdir -p "$sp12/dkms"
cp -r "$here/dkms/dkms.conf" "$here/dkms/Makefile" "$here/dkms/prepare-sources.sh" \
	"$here/dkms/patches" "$sp12/dkms/"
cp -r "$here/userspace" "$sp12/"
if [[ -n ${SP12_ISH_FW:-} ]]; then
	mkdir -p "$sp12/private"
	cp "$SP12_ISH_FW" "$sp12/private/IshS_SI.bin"
	echo "Including the ISH firmware: this ISO is PRIVATE, do not share it."
fi

# omarchy-iso-make drives docker; run its container through rootful podman.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'EOF'
#!/bin/bash
args=()
for a in "$@"; do
	[[ $a == archlinux/archlinux:latest ]] && a=docker.io/archlinux/archlinux:latest
	args+=("$a")
done
exec sudo -A -p "Claude Code wants to run as root:  podman ${args[*]:0:3} ... (omarchy ISO build)" podman "${args[@]}"
EOF
chmod +x "$WORK/bin/docker"

cd "$iso"
PATH="$WORK/bin:$PATH" ./bin/omarchy-iso-make --keep-pkg-cache --no-boot-offer
ls -la "$iso"/release/*.iso
