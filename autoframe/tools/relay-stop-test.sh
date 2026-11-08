#!/bin/bash
# Relay start/stop test: client sessions on a hardware-ISP relay loopback.
# Each session must deliver >= 80 % of its frames; after each stop, wait 4 s
# (past v4l2-relayd's idle reset) and require the loopback to offer capture
# again. Stops at the first failure. With a background device, another
# client streams that camera the whole time (sp12isplock should then hold
# the foreground camera back: expect a failure on session 1, not a wedge).
# usage: relay-stop-test.sh /dev/videoN sessions [background-device]
dev=$1; n=$2; bg=${3:-}; name=$(basename $dev)
if [ -n "$bg" ]; then
	gst-launch-1.0 -q v4l2src device=$bg ! fakesink sync=false >/dev/null 2>&1 &
	bgpid=$!; sleep 4; echo "background stream on $bg (pid $bgpid)"
fi
fail() { echo "FAIL: $*"; [ -n "$bg" ] && kill $bgpid 2>/dev/null; exit 1; }
for i in $(seq $n); do
	dur=$((4 + RANDOM % 4)); want=$((dur * 30))
	got=$(timeout $((dur + 10)) gst-launch-1.0 -v v4l2src device=$dev num-buffers=$want ! \
		fakesink silent=false sync=false 2>/dev/null | grep -c "last-message = chain")
	sleep 4
	st=$(cat /sys/devices/virtual/video4linux/$name/state)
	echo "$i $(date +%T) ${dur}s frames $got/$want, state 4 s after stop: $st"
	[ "$got" -ge $((want * 8 / 10)) ] || fail "session $i got $got of $want frames"
	[ "$st" = capture ] || fail "session $i: loopback did not re-arm ($st)"
	if [ -n "$bg" ] && ! kill -0 $bgpid 2>/dev/null; then fail "background stream died"; fi
done
[ -n "$bg" ] && kill $bgpid 2>/dev/null
echo "OK: $n sessions"
