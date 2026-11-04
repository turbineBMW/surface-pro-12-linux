#!/bin/bash
# Flex Keyboard and touchpad checks for sp12-flex-tools, ported from the
# Surface Pro 11 package tests. Bluetooth tools, systemd-run and hidraw are
# stubs, so this runs anywhere without root: bash pkg/sp12-flex-tools/test.sh

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
u="$root/userspace"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

bin="$scratch/bin"
mkdir -p "$bin"

# Flex Keyboard: pair on attach when there is no working bond, reconnect on
# detach. bluetoothctl, btmgmt and the pairing tool are stubs that record what
# they were asked to do.
cat >"$bin/bluetoothctl" <<'STUB'
#!/bin/bash
case $1 in
  show) printf '\tPowered: yes\n' ;;
  info)
    [[ -e $BT_STATE/paired ]] || exit 1
    printf '\tPaired: yes\n\tBonded: yes\n'
    if [[ -e $BT_STATE/connected ]]; then printf '\tConnected: yes\n'; else printf '\tConnected: no\n'; fi
    ;;
  connect) echo "connect $2" >>"$BT_STATE/log"; [[ ! -e $BT_STATE/connectable ]] || : >"$BT_STATE/connected" ;;
  remove) echo "remove $2" >>"$BT_STATE/log"; rm -f "$BT_STATE/paired" "$BT_STATE/connected" ;;
  *) echo "$*" >>"$BT_STATE/log" ;;
esac
STUB
cat >"$bin/btmgmt" <<'STUB'
#!/bin/bash
if [[ $1 == info ]]; then
  settings='powered ssp br/edr le secure-conn ll-privacy'
  # privacy-later holds "<checks before privacy comes on> <privacy value then>".
  if [[ -e $BT_STATE/privacy-later ]]; then
    read -r after hold <"$BT_STATE/privacy-later"
    if (( after > 0 )); then echo "$((after - 1)) $hold" >"$BT_STATE/privacy-later"
    else rm -f "$BT_STATE/privacy-later"; echo "$hold" >"$BT_STATE/privacy"
    fi
  fi
  # privacy-cycle counts checks; every third of the first 200 sees privacy on.
  if [[ -e $BT_STATE/privacy-cycle ]]; then
    c=$(( $(<"$BT_STATE/privacy-cycle") + 1 )); echo "$c" >"$BT_STATE/privacy-cycle"
    (( c <= 200 && c % 3 == 0 )) && settings+=' privacy'
  fi
  # privacy holds "on", or how many more checks see it on before it goes off.
  if [[ -e $BT_STATE/privacy ]]; then
    left=$(<"$BT_STATE/privacy")
    if [[ $left == on ]]; then settings+=' privacy'
    elif (( left > 0 )); then echo $((left - 1)) >"$BT_STATE/privacy"; settings+=' privacy'
    fi
  fi
  printf 'hci0:\tPrimary controller\n\tcurrent settings: %s \n' "$settings"
  exit 0
fi
echo "btmgmt $*" >>"$BT_STATE/log"
STUB
cat >"$bin/logger" <<'STUB'
#!/bin/bash
STUB
cat >"$bin/fake-flex-pair" <<'STUB'
#!/bin/bash
echo "pair $*" >>"$BT_STATE/log"
[[ ${PAIR_FAILS:-} ]] && exit 1
: >"$BT_STATE/paired"; : >"$BT_STATE/connected"
STUB
chmod +x "$bin/bluetoothctl" "$bin/btmgmt" "$bin/logger" "$bin/fake-flex-pair"

keyboard=C6:00:11:22:33:44
flex_reset() {
  rm -rf "$scratch/bt" "$scratch/run" "$scratch/hid"
  mkdir -p "$scratch/bt" "$scratch/run" "$scratch/hid"
  : >"$scratch/bt/log"
}
flex_attach() { mkdir -p "$scratch/hid/0019:045E:0C8B.0002" "$scratch/hid/0019:045E:0C8F.0001"; }
flex_bond() { echo "$keyboard" >"$scratch/bt/address"; : >"$scratch/bt/paired"; }
flex() { # $1 = script in usr/local/libexec
  PATH="$bin:$PATH" BT_STATE="$scratch/bt" \
    SP12_FLEX_HID_DEVICES="$scratch/hid" SP12_FLEX_ADDRESS_FILE="$scratch/bt/address" \
    SP12_FLEX_RUN_DIR="$scratch/run" SP12_FLEX_PAIR_TOOL="$bin/fake-flex-pair" SP12_FLEX_NO_SLEEP=1 \
    bash "$u/usr/local/libexec/$1" >/dev/null 2>&1 || true
}
flex_did() { grep -qx "$1" "$scratch/bt/log"; }

flex_reset; flex_attach
flex sp12-flex-autopair
flex_did "pair --no-detach" || fail "an attached keyboard with no bond is paired over the wire"

flex_reset; flex_attach; flex_bond; : >"$scratch/bt/connected"
flex sp12-flex-autopair
[[ ! -s $scratch/bt/log ]] || fail "a working bond is left alone"

# The bond would even connect on request: only the marker says it is stale.
flex_reset; flex_attach; flex_bond; : >"$scratch/bt/connectable"; : >"$scratch/run/flex-needs-repair"
flex sp12-flex-autopair
flex_did "remove $keyboard" && flex_did "pair --no-detach" ||
  fail "a bond that failed to reconnect on detach is replaced on the next attach"
[[ ! -e $scratch/run/flex-needs-repair ]] || fail "a successful pair clears the repair marker"

flex_reset; flex_attach; flex_bond
flex sp12-flex-autopair
flex_did "btmgmt power off" && flex_did "remove $keyboard" && flex_did "pair --no-detach" ||
  fail "a bond that will not connect even after a controller reset is replaced"

flex_reset; flex_attach; flex_bond; : >"$scratch/bt/connectable"
flex sp12-flex-autopair
! flex_did "pair --no-detach" || fail "a bond that connects on request is kept"

# While a pen is pairing (sp12-pen-pair), privacy is on and the keyboard
# cannot connect.
flex_reset; flex_attach; flex_bond; echo on >"$scratch/bt/privacy"
flex sp12-flex-autopair
! flex_did "remove $keyboard" && ! flex_did "pair --no-detach" && ! flex_did "btmgmt power off" ||
  fail "a bond is kept, and the radio left alone, while a pen is pairing"

# Once the pairing ends the keyboard may no longer advertise; that is no
# evidence against the bond.
flex_reset; flex_attach; flex_bond; echo 2 >"$scratch/bt/privacy"
flex sp12-flex-autopair
! flex_did "remove $keyboard" && ! flex_did "pair --no-detach" && ! flex_did "btmgmt power off" ||
  fail "a bond that does not connect right after a pen pairing is kept"

flex_reset; flex_attach; echo 2 >"$scratch/bt/privacy"
flex sp12-flex-autopair
flex_did "pair --no-detach" || fail "a keyboard with no bond is paired once a pen pairing ends"

flex_reset; mkdir -p "$scratch/hid/0019:045E:0C8B.0002"
flex sp12-flex-autopair
! flex_did "pair --no-detach" || fail "without the kernel's pairing channel nothing is paired"

flex_reset
flex sp12-flex-autopair
! flex_did "pair --no-detach" || fail "a detached keyboard is not paired"

flex_reset; flex_bond; : >"$scratch/bt/connectable"
flex sp12-flex-bt-autoconnect
flex_did "connect $keyboard" && [[ ! -e $scratch/run/flex-needs-repair ]] ||
  fail "a detached keyboard is connected over Bluetooth"

flex_reset; flex_bond
flex sp12-flex-bt-autoconnect
[[ -e $scratch/run/flex-needs-repair ]] || fail "a detached keyboard that never connects is marked for re-pairing"

flex_reset; flex_bond; echo on >"$scratch/bt/privacy"
flex sp12-flex-bt-autoconnect
! flex_did "connect $keyboard" && [[ ! -e $scratch/run/flex-needs-repair ]] ||
  fail "a keyboard detached while a pen is pairing is not marked for re-pairing"

flex_reset; flex_bond; echo 2 >"$scratch/bt/privacy"
flex sp12-flex-bt-autoconnect
flex_did "connect $keyboard" && [[ ! -e $scratch/run/flex-needs-repair ]] ||
  fail "a keyboard detached during a pen pairing is connected afterwards, and not marked if it stays away"

# A pen pairing that begins between tries is waited out, then the tries resume.
flex_reset; flex_bond; : >"$scratch/bt/connectable"; echo "2 2" >"$scratch/bt/privacy-later"
flex sp12-flex-bt-autoconnect
flex_did "connect $keyboard" ||
  fail "a pen pairing that starts while the keyboard reconnects does not end the reconnect"

flex_reset; flex_bond; echo "2 2" >"$scratch/bt/privacy-later"
flex sp12-flex-bt-autoconnect
flex_did "connect $keyboard" && ! flex_did "btmgmt power off" && [[ ! -e $scratch/run/flex-needs-repair ]] ||
  fail "a keyboard that stays away after a pen pairing mid-reconnect is retried, with the radio left alone, and not marked"

# A pen pairing that begins during the fifth try, just before the controller
# reset, is not cut off by it.
flex_reset; flex_bond; echo "7 on" >"$scratch/bt/privacy-later"
flex sp12-flex-bt-autoconnect
! flex_did "btmgmt power off" || fail "the controller is not reset while a pen is pairing"

# Pen pairings that keep coming do not keep the job running.
flex_reset; flex_bond; echo 0 >"$scratch/bt/privacy-cycle"
flex sp12-flex-bt-autoconnect
(( $(grep -c "^connect $keyboard" "$scratch/bt/log") <= 40 )) ||
  fail "a reconnect gives up after a few pen pairings in a row"

flex_reset; flex_attach; flex_bond
flex sp12-flex-bt-autoconnect
! flex_did "connect $keyboard" || fail "an attached keyboard is not connected over Bluetooth"

for tool in usr/local/bin/sp12-flex-pair usr/local/bin/sp12-pen-pair usr/lib/systemd/system-sleep/sp12-touchpad-mode; do
  python -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$u/$tool" ||
    fail "$tool is valid Python"
done
grep -q 'start sp12-flex-autopair.service' "$u/etc/udev/rules.d/99-sp12-flex-bt.rules" ||
  fail "attaching the keyboard starts sp12-flex-autopair"
grep -q 'start sp12-flex-bt-connect.service' "$u/etc/udev/rules.d/99-sp12-flex-bt.rules" ||
  fail "detaching the keyboard starts sp12-flex-bt-connect"

# Touchpad: after resume a job of its own puts the attached keyboard's touchpad
# back in touchpad mode. systemd-run is a stub that records what it was asked to
# run.
hook="$u/usr/lib/systemd/system-sleep/sp12-touchpad-mode"
cat >"$bin/systemd-run" <<'STUB'
#!/bin/bash
echo "systemd-run $*" >>"$TOUCHPAD_LOG"
STUB
chmod +x "$bin/systemd-run"
touchpad_sleep() {
  : >"$scratch/touchpad.log"
  PATH="$bin:$PATH" TOUCHPAD_LOG="$scratch/touchpad.log" python "$hook" "$@"
}
touchpad_sleep post suspend
grep -q -- "--no-block .*sp12-touchpad-mode check$" "$scratch/touchpad.log" ||
  fail "after resume the touchpad is checked in a job that does not hold up the resume"
touchpad_sleep pre suspend
[[ ! -s $scratch/touchpad.log ]] || fail "the touchpad hook acts only after resume"

# The touchpad's mode and switches, read and written through a fake hidraw node.
touchpad="$scratch/touchpad/0019:045E:0C8D.0005"
mkdir -p "$touchpad/hidraw/hidraw4" "$scratch/drivers/hid-multitouch" "$scratch/dev"
ln -s "$scratch/drivers/hid-multitouch" "$touchpad/driver"
: >"$scratch/dev/hidraw4"
# The touchpad's Device Configuration collection, as the keyboard reports it.
printf '\x05\x0d\x09\x0e\xa1\x01\x85\x84\x09\x22\xa1\x02\x09\x52\x15\x00\x25\x0a\x75\x08\x95\x01\xb1\x02\xc0\x09\x22\xa1\x00\x85\x85\x09\x57\x09\x58\x75\x01\x95\x02\x25\x01\xb1\x02\x95\x06\xb1\x03\xc0\xc0' \
  >"$scratch/config.rdesc"
cp "$scratch/config.rdesc" "$touchpad/report_descriptor"
touchpad_check() { # $1 = Input Mode, $2 = switch report byte, $3 = reply length
  python - "$hook" "$scratch" "$@" <<'EOF'
import sys
hook = {'__name__': 'hook'}
exec(open(sys.argv[1]).read(), hook)
scratch, mode, switches, length = sys.argv[2], int(sys.argv[3], 0), int(sys.argv[4], 0), int(sys.argv[5])
hook['HID'], hook['DEV'] = scratch + '/touchpad', scratch + '/dev'
report = {0x84: mode, 0x85: switches}

class Fcntl:
    def ioctl(self, fd, request, buf):
        nr = request & 0xff
        if nr == 0x07:
            buf[1] = report[buf[0]]
            return length
        print(f'set {buf.hex()}')
        return len(buf)

hook['fcntl'] = Fcntl()
try:
    print(hook['check']('0019:045E:0C8D.0005') or 'left alone')
except OSError as e:
    print(f'error {e}')
EOF
}
[[ $(touchpad_check 3 0x17 2) == "left alone" ]] ||
  fail "a touchpad in touchpad mode with both switches on is left alone"
[[ $(touchpad_check 0 0x17 2) == $'set 8403\nset 8517\nresumed in input mode 0 with switches 0x17, restored touchpad mode' ]] ||
  fail "a touchpad in mouse mode is put back in touchpad mode, keeping the rest of the switch report"
[[ $(touchpad_check 3 0x14 2) == $'set 8403\nset 8517\n'* ]] ||
  fail "a touchpad left with its surface and button switches off gets them back"
[[ $(touchpad_check 0 0x17 1) == "error short reply to feature report 0x84" ]] ||
  fail "a short reply to the mode read changes nothing"
printf '\x05\x0d\x09\x0e\xa1\x01\x85\x84\x09\x22\xa1\x02\x09\x52\x15\x00\x25\x0a\x75\x10' >"$touchpad/report_descriptor"
[[ $(touchpad_check 0 0x17 2) == "left alone" ]] ||
  fail "a touchpad whose configuration reports are laid out differently is left alone"

cp "$scratch/config.rdesc" "$touchpad/report_descriptor"
rm -rf "$touchpad/hidraw/hidraw4"
[[ $(SP12_TOUCHPAD_HID="$scratch/touchpad" SP12_TOUCHPAD_SETTLE=0 SP12_TOUCHPAD_TRIES=1 \
  python "$hook" check 2>&1) == "sp12-touchpad-mode: 0019:045E:0C8D.0005 gave up: IndexError"* ]] ||
  fail "a touchpad that goes away during the check is reported, not a crash"

grep -q 'usr/lib/systemd/system-sleep/sp12-touchpad-mode' "$root/pkg/sp12-flex-tools/PKGBUILD" ||
  fail "the touchpad hook is installed where systemd-sleep runs hooks"

echo "ok - sp12-flex-tools Flex Keyboard and touchpad checks"
