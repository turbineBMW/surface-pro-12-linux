#!/bin/bash
# Install an SP12 Omarchy ISO unattended in QEMU, then boot the installed
# system under Project Mu Q35 with the Surface-like NX image policy and check
# that the patched Limine boots it and the Surface packages are in place.
#   test-vm-install.sh <iso> <mu-fv-dir>
#   <mu-fv-dir>: .../Build/QemuQ35PkgX64/DEBUG_GCC5/FV from limine/qemu/build-q35.sh
# Autoinstall config follows omarchy-iso's test/integration.d/base-test.sh.
set -euo pipefail

iso=$(realpath "${1:?usage: test-vm-install.sh <iso> <mu-fv-dir>}")
fv=$(realpath "${2:?usage: test-vm-install.sh <iso> <mu-fv-dir>}")
work=${WORK:-$HOME/Projects/sp12-vm-test}
user=omarchy
password=omarchy
ssh_port=2222

# SKIP_INSTALL=1 reuses the disk from a previous run and only boots it.
if [ -z "${SKIP_INSTALL:-}" ]; then
rm -rf "$work"
mkdir -p "$work/cidata"
ssh-keygen -t ed25519 -N "" -q -C sp12-vm-test -f "$work/key"
hash=$(openssl passwd -6 "$password")

disk_bytes=$((40 * 1024 * 1024 * 1024))
mib=$((1024 * 1024))
boot_start=$mib
boot_size=$((2 * 1024 * mib))
main_start=$((boot_start + boot_size))
main_size=$((disk_bytes - main_start - mib))

cat > "$work/cidata/user_credentials.json" <<EOF
{
    "root_enc_password": $(jq -Rn --arg v "$hash" '$v'),
    "users": [ { "enc_password": $(jq -Rn --arg v "$hash" '$v'), "groups": [], "sudo": true, "username": "$user" } ]
}
EOF
cat > "$work/cidata/user_configuration.json" <<EOF
{
    "app_config": null,
    "archinstall-language": "English",
    "auth_config": {},
    "audio_config": { "audio": "pipewire" },
    "bootloader_config": { "bootloader": "Limine", "uki": false, "removable": false },
    "custom_commands": [],
    "omarchy_install": {
        "mode": "full_disk",
        "defer_provisioning": false,
        "target_mount": "/mnt",
        "boot": { "esp_mount": "/boot", "esp_path": "/EFI/limine", "efi_binary": "limine_x64.efi", "enable_fallback": true },
        "storage": { "kernel": "linux-omarchy" }
    },
    "disk_config": {
        "config_type": "default_layout",
        "device_modifications": [ {
            "device": "/dev/nvme0n1",
            "partitions": [
                { "btrfs": [], "dev_path": null, "flags": [ "boot", "esp" ], "fs_type": "fat32", "mount_options": [],
                  "mountpoint": "/boot", "obj_id": "ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d",
                  "size": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $boot_size },
                  "start": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $boot_start },
                  "status": "create", "type": "primary" },
                { "btrfs": [ { "mountpoint": "/", "name": "@" }, { "mountpoint": "/home", "name": "@home" },
                             { "mountpoint": "/var/log", "name": "@log" }, { "mountpoint": "/var/cache/pacman/pkg", "name": "@pkg" } ],
                  "dev_path": null, "flags": [], "fs_type": "btrfs", "mount_options": [ "compress=zstd" ], "mountpoint": null,
                  "obj_id": "8c2c2b92-1070-455d-b76a-56263bab24aa",
                  "size": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $main_size },
                  "start": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $main_start },
                  "status": "create", "type": "primary" }
            ],
            "wipe": true
        } ]
    },
    "hostname": "sp12-vm",
    "kernels": [ "linux-omarchy" ],
    "network_config": { "type": "iso" },
    "ntp": true,
    "parallel_downloads": 8,
    "script": null,
    "services": [],
    "swap": true,
    "timezone": "UTC",
    "locale_config": { "kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8" },
    "mirror_config": { "custom_repositories": [], "custom_servers": [], "mirror_regions": {}, "optional_repositories": [] },
    "packages": [ "base-devel", "git", "omarchy-keyring", "omarchy-settings", "omarchy" ],
    "profile_config": { "gfx_driver": null, "greeter": null, "profile": {} },
    "version": "3.0.9"
}
EOF
echo "SP12 VM Test" > "$work/cidata/user_full_name.txt"
echo "test@example.org" > "$work/cidata/user_email_address.txt"
echo "false" > "$work/cidata/user_encrypt_installation.txt"
cp "$work/key.pub" "$work/cidata/authorized_keys"
truncate -s 4M "$work/cidata.img"
mkfs.vfat -n CIDATA "$work/cidata.img" >/dev/null
mcopy -i "$work/cidata.img" "$work"/cidata/* ::/
qemu-img create -f qcow2 "$work/disk.qcow2" 40G >/dev/null

echo "== phase 1: unattended install (OVMF)"
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$work/ovmf-vars.fd"
timeout 5400 qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -smp 8 -m 8192 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
    -drive if=pflash,format=raw,file="$work/ovmf-vars.fd" \
    -drive file="$work/disk.qcow2",if=none,id=d0,format=qcow2 -device nvme,serial=sp12vm,drive=d0,bootindex=1 \
    -drive file="$iso",media=cdrom,if=none,format=raw,id=cd0 -device ide-cd,drive=cd0,bootindex=2 \
    -drive file="$work/cidata.img",format=raw,if=none,id=cidata -device qemu-xhci -device usb-storage,drive=cidata \
    -vga std -display none -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -serial file:"$work/install-serial.log" -no-reboot && rc=0 || rc=$?
# -no-reboot turns the installer's final reboot into a clean exit; a timeout or
# a QEMU error is not an install.
used=$(qemu-img info --output=json "$work/disk.qcow2" | jq '.["actual-size"]')
echo "install VM exited rc=$rc, disk holds $((used / 1024 / 1024)) MiB"
if [ "$rc" -ne 0 ] || [ "$used" -lt $((4 * 1024 * 1024 * 1024)) ]; then
    echo "FAIL: install did not complete"
    tr -d '\r' < "$work/install-serial.log" | tail -20
    exit 1
fi
fi

echo "== phase 2: boot the installed disk under Mu (BlockImagesWithoutNxFlag=1)"
# Mu Q35 has a fixed maximum CPU count; more than 4 asserts in PlatformPei.
# A VM left over from an earlier run holds the pid file and the disk.
pkill -f -- "$work/mu-vars.fd" && sleep 2 || true
cp "$fv/QEMUQ35_VARS.fd" "$work/mu-vars.fd"
rm -f "$work/mu-debug.log"
qemu-system-x86_64 \
    -net none -global isa-debugcon.iobase=0x402 -debugcon file:"$work/mu-debug.log" \
    -global ICH9-LPC.disable_s3=1 -global mch.extended-tseg-mbytes=32 \
    -machine q35,smm=on,accel=kvm -cpu host -smp 4 -m 8192 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,file="$fv/QEMUQ35_CODE.fd",readonly=on \
    -drive if=pflash,format=raw,unit=1,file="$work/mu-vars.fd" \
    -drive file="$work/disk.qcow2",if=none,id=d0,format=qcow2 -device nvme,serial=sp12vm,drive=d0,bootindex=1 \
    -device qemu-xhci -device usb-tablet \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$ssh_port-:22 -device virtio-net-pci,netdev=n0 \
    -display none -device bochs-display \
    -serial file:"$work/boot-serial.log" -serial file:"$work/boot-serial2.log" \
    -daemonize -pidfile "$work/qemu.pid"

ssh_guest() {
    ssh -q -i "$work/key" -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 "$user@127.0.0.1" "$@"
}
for _ in $(seq 1 120); do
    ssh_guest true 2>/dev/null && break
    sleep 5
done
if ! ssh_guest true 2>/dev/null; then
    echo "FAIL: installed system did not come up under Mu within 10 minutes"
    grep -aE "NX_COMPAT|Security Violation|BOOTX64|limine" "$work/mu-debug.log" | tail -5
    kill "$(cat "$work/qemu.pid")"
    exit 1
fi

echo "== checks (installed system booted under Mu)"
ssh_guest 'set -x
tr -d "\0" < /sys/firmware/efi/efivars/LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f | tail -c +5; echo
uname -r
pacman -Q limine sp12-modules-dkms sp12-flex-tools sp12-ish-firmware linux-omarchy
sha256sum /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI /boot/EFI/limine/limine_x64.efi 2>&1
dkms status
for m in surface_aggregator_registry surface_aggregator_tabletsw surface_gpe bluetooth; do modinfo -n $m; done
ls /usr/lib/firmware/updates/intel/ish/
grep -E "^/|protocol|path" /boot/limine.conf | head -12
systemctl is-system-running' 2>&1
kill "$(cat "$work/qemu.pid")"
