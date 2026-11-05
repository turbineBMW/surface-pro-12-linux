#!/bin/bash
# Short capture through Intel's HAL and PSYS from the dev prefix built by
# build-dev.sh. Writes NV12 frames to a file; killed after 30 s regardless.
#
# Frame layout in the file: the HAL allocates NV12 buffers with one extra
# line (W x (H+1) x 1.5 bytes; 3113280 for 1920x1080) and filesink writes
# the whole buffer, so step through the file by that size, not W*H*1.5. Y is
# at 0 and UV at W*H; the extra line is trailing padding. Parsing at W*H*1.5
# makes every frame start 1.5 rows early, which looks like a growing band at
# the top and a picture that slides down 1.5 rows per frame.
#   run-dev.sh [imx681-uf|ov13858-wf] [WxH] [frames] [out.nv12] [cameraDebug]
# cameraDebug is the HAL's log mask (0x1 errors+warnings; 0x3 adds info).
HERE=$(dirname "$(readlink -f "$0")")
W=$(dirname "$HERE")/private/camera/psys/work
P=${PREFIX:-$W/prefix}
DEV=${1:-imx681-uf}
SIZE=${2:-1920x1080}
NUM=${3:-30}
OUT=${4:-$W/test-$DEV-$SIZE.nv12}
LD_LIBRARY_PATH=$P/lib GST_PLUGIN_PATH=$P/lib/gstreamer-1.0 GST_REGISTRY=$P/gst-registry.bin \
CAMERA_CFG_PATH=$P/etc/camera/ipu75xa/ cameraDebug=${5:-0x1} \
timeout -s KILL 30 gst-launch-1.0 icamerasrc device-name="$DEV" num-buffers="$NUM" \
	! "video/x-raw,format=NV12,width=${SIZE%x*},height=${SIZE#*x}" ! filesink location="$OUT"
ls -l "$OUT" 2>/dev/null
