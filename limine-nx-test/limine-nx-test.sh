#!/bin/bash
# Test whether this firmware refuses EFI images without the NX_COMPAT flag,
# using Limine 12.9.0 stock (no flag) and an identical copy with only that bit
# set. Entries are created with --create-only (never added to BootOrder) and
# booted once via BootNext, so the normal boot is never changed.
#
#   sudo ./limine-nx-test.sh setup     copy files to the ESP, create entries
#   sudo ./limine-nx-test.sh stock     boot stock Limine once (reboots)
#   sudo ./limine-nx-test.sh nx        boot NX-flagged Limine once (reboots)
#   sudo ./limine-nx-test.sh crumbs <efi> [conf]   install a Limine build (and conf) and
#                                         arm it via BootNext (no reboot)
#   sudo ./limine-nx-test.sh cleanup   remove the entries and files
set -eu

here=$(cd "$(dirname "$0")" && pwd)
esp=/boot
dir=EFI/limine-nx-test
disk=/dev/nvme0n1
part=4

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

entry() { # label -> Boot#### number
	efibootmgr | awk -F'\t' -v l="$1" '$1 ~ /^Boot[0-9A-F]{4}/ {
		n = substr($1, 5, 4); sub(/^Boot[0-9A-F]{4}\*? /, "", $1)
		if ($1 == l) { print n; exit } }'
}

case "${1:-}" in
setup)
	install -Dm644 "$here/stock.efi" "$esp/$dir/stock.efi"
	install -Dm644 "$here/nx.efi" "$esp/$dir/nx.efi"
	install -Dm644 "$here/limine.conf" "$esp/$dir/limine.conf"
	[ -n "$(entry 'Limine NX test stock')" ] ||
		efibootmgr -q --create-only --disk $disk --part $part \
			--label 'Limine NX test stock' --loader '\EFI\limine-nx-test\stock.efi'
	[ -n "$(entry 'Limine NX test nx')" ] ||
		efibootmgr -q --create-only --disk $disk --part $part \
			--label 'Limine NX test nx' --loader '\EFI\limine-nx-test\nx.efi'
	efibootmgr | grep -E '^Boot(Order|[0-9A-F]{4}.*NX test)'
	;;
stock|nx)
	n=$(entry "Limine NX test $1")
	[ -n "$n" ] || { echo "run setup first" >&2; exit 1; }
	efibootmgr -q --bootnext "$n"
	echo "BootNext=$n ($1); rebooting"
	systemctl reboot
	;;
crumbs)
	src=${2:?usage: limine-nx-test.sh crumbs <efi> [limine.conf]}
	install -Dm644 "$src" "$esp/$dir/crumbs.efi"
	install -Dm644 "${3:-$here/limine.conf}" "$esp/$dir/limine.conf"
	# A config booting Linux needs a standalone initramfs (this system uses a UKI).
	if grep -q 'initramfs-linux.img' "$esp/$dir/limine.conf"; then
		# Test initramfs: the system config plus the crashdump hook, which saves
		# the kernel log to NVRAM if the boot never reaches the real root.
		mkinitcpio -c "$here/mkinitcpio-crashdump.conf" -D "$here/initcpio" -D /usr/lib/initcpio \
			-k "$esp/vmlinuz-linux" -g "$esp/$dir/initramfs-linux.img" >/dev/null
		ls -la "$esp/$dir/initramfs-linux.img"
	fi
	[ -n "$(entry 'Limine NX test crumbs')" ] ||
		efibootmgr -q --create-only --disk $disk --part $part \
			--label 'Limine NX test crumbs' --loader '\EFI\limine-nx-test\crumbs.efi'
	# Start from a clean slate so a stale value cannot be mistaken for progress.
	for v in /sys/firmware/efi/efivars/Limine{Crumb,MemDbg,Handoff,Tramp,Dmesg0,Dmesg1,Dmesg2,Dmesg3}-513ee0d0-6e43-cb05-b272-f146a2fcb88a; do
		if [ -e "$v" ]; then chattr -i "$v"; rm -f "$v"; fi
	done
	n=$(entry 'Limine NX test crumbs')
	efibootmgr -q --bootnext "$n"
	sha256sum "$esp/$dir/crumbs.efi"
	efibootmgr | grep -E '^Boot(Next|Order)'
	;;
cleanup)
	for l in stock nx crumbs; do
		n=$(entry "Limine NX test $l")
		[ -z "$n" ] || efibootmgr -q --bootnum "$n" --delete-bootnum
	done
	rm -rf "${esp:?}/$dir"
	for v in /sys/firmware/efi/efivars/Limine{Crumb,MemDbg,Handoff,Tramp,Dmesg0,Dmesg1,Dmesg2,Dmesg3}-513ee0d0-6e43-cb05-b272-f146a2fcb88a; do
		if [ -e "$v" ]; then chattr -i "$v"; rm -f "$v"; fi
	done
	efibootmgr | grep -E '^Boot(Order|[0-9A-F]{4})'
	;;
*)
	sed -n '2,14p' "$0"; exit 1 ;;
esac
