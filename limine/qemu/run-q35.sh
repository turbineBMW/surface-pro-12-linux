#!/bin/bash
# Boot an ESP directory under Project Mu Q35 (built by build-q35.sh) with the
# same QEMU arguments as Mu's QemuRunner. Firmware debug log (port 0x402) and
# serial console go to files in out/<name>/; a screenshot is taken at the end.
#   ./run-q35.sh <esp-dir> [seconds]      e.g. ./run-q35.sh esp/stock 40
#   FW=ovmf ./run-q35.sh ...               upstream OVMF baseline instead of Mu
#   MEM=16384 ./run-q35.sh ...             guest RAM in MiB (default 2048)
#   GDB=1 ./run-q35.sh ...                 also listen for gdb on :1234, paused
set -euo pipefail
cd "$(dirname "$0")"
esp=${1:?usage: run-q35.sh <esp-dir> [seconds]}
secs=${2:-40}
fv=mu_tiano_platforms/Build/QemuQ35PkgX64/DEBUG_GCC5/FV
code=$fv/QEMUQ35_CODE.fd vars=$fv/QEMUQ35_VARS.fd
if [ "${FW:-mu}" = ovmf ]; then   # upstream edk2 baseline, no NX image policy
    code=/usr/share/edk2/x64/OVMF_CODE.4m.fd vars=/usr/share/edk2/x64/OVMF_VARS.4m.fd
fi
out=out/${FW:-mu}-$(basename "$esp")${MEM:+-$MEM}
rm -rf "$out"; mkdir -p "$out"
cp "$vars" "$out/vars.fd"
gdb=()
[ -z "${GDB:-}" ] || gdb=(-s -S)

timeout "$secs" qemu-system-x86_64 \
    -net none \
    -global isa-debugcon.iobase=0x402 -debugcon file:"$out/debug.log" \
    -global ICH9-LPC.disable_s3=1 \
    -global mch.extended-tseg-mbytes=32 \
    -machine q35,smm=on,accel=kvm \
    -m "${MEM:-2048}" \
    -cpu "${CPU:-qemu64,rdrand=on,umip=on,smep=on,pdpe1gb=on,popcnt=on,+sse,+sse2,+sse3,+ssse3,+sse4.2,+sse4.1}" \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,file="$code",readonly=on \
    -drive if=pflash,format=raw,unit=1,file="$out/vars.fd" \
    -device qemu-xhci,id=usb -device usb-tablet,id=input0,bus=usb.0,port=1 \
    -drive file=fat:"$esp",format=raw,media=disk,if=virtio,readonly=on \
    -display none -device bochs-display,addr=0x03 -vga none \
    -serial file:"$out/serial.log" -serial file:"$out/serial2.log" \
    -monitor unix:"$out/monitor.sock",server,nowait \
    "${gdb[@]}" &
qpid=$!
sleep $((secs - 3))
python3 -c 'import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(b"screendump " + sys.argv[2].encode() + b"\n"); time.sleep(1)' "$out/monitor.sock" "$out/screen.ppm" 2>/dev/null || true
wait $qpid || true
echo "== $out: $(wc -l < "$out/debug.log") debug lines, $(wc -c < "$out/serial.log")/$(wc -c < "$out/serial2.log") serial bytes"
