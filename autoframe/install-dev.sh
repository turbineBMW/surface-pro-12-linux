#!/bin/sh
# Dev install of automatic framing into the front-camera relay (run as root).
# Stages the plugin, the YuNet model and a HAL config copy with 4K output
# under /opt/sp12-autoframe-dev, points the relay at them with a systemd
# drop-in, and rewrites the relay's source pipeline. The package will replace
# all of this; uninstall-dev.sh undoes it.
#   sudo autoframe/install-dev.sh            # crop mode: 4K from the ISP, crop in the element
#   AUTOFRAME_MODE=isp sudo -E autoframe/install-dev.sh   # ISP mode: 1080p, zoom-region upstream
# With the sp12-autoframe package installed its relay environment file
# (sp12-front-autoframe.env) carries the pipeline and is the one rewritten.
set -eu
MODE=${AUTOFRAME_MODE:-crop}
HERE=$(dirname "$(readlink -f "$0")")
D=/opt/sp12-autoframe-dev
MODEL_SRC=${MODEL_SRC:-/usr/share/irlume/models/face_detection_yunet_2023mar.onnx}
HALCFG=/usr/share/defaults/etc/camera/ipu75xa
CONF=/etc/v4l2-relayd.d/sp12-front.conf
[ -f /etc/v4l2-relayd.d/sp12-front-autoframe.env ] && CONF=/etc/v4l2-relayd.d/sp12-front-autoframe.env

install -Dm644 "$HERE/build/gstsp12autoframe.so" "$D/gstreamer-1.0/gstsp12autoframe.so"
install -Dm644 "$MODEL_SRC" "$D/face_detection_yunet_2023mar.onnx"
rm -rf "$D/camera"
mkdir -p "$D/camera"
cp -a "$HALCFG" "$D/camera/ipu75xa"
# 4K and 1440p NV12 outputs (both are in the Windows graph settings).
python3 - "$D/camera/ipu75xa/sensors/imx681-uf.json" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
if "[3840, 2160]" not in s:
    entry = ('            {\n              "format": "V4L2_PIX_FMT_NV12", "size": [%d, %d], "field": 0, "mcId": 0\n            },\n')
    s = s.replace('          "supportedStreamConfig": [\n',
                  '          "supportedStreamConfig": [\n' + entry % (3840, 2160) + entry % (2560, 1440), 1)
    open(p, "w").write(s)
PY
grep -c '"size": \[3840, 2160\]' "$D/camera/ipu75xa/sensors/imx681-uf.json"

mkdir -p /run/sp12 && chmod 1777 /run/sp12

install -Dm644 /dev/stdin /etc/systemd/system/v4l2-relayd@sp12-front.service.d/zz-autoframe-dev.conf <<'UNIT'
# Dev only (autoframe/install-dev.sh): automatic framing plugin and a HAL
# config with 4K output from /opt/sp12-autoframe-dev.
[Service]
Environment=GST_PLUGIN_PATH=/opt/sp12-autoframe-dev/gstreamer-1.0
Environment=CAMERA_CFG_PATH=/opt/sp12-autoframe-dev/camera/ipu75xa/
Environment=GST_DEBUG=sp12autoframe:5
# The NPU is an accel-class node, which the base unit's DevicePolicy=closed
# list (drm, media, video4linux, psys) does not cover.
DeviceAllow=char-accel rw
DeviceAllow=/dev/accel/accel0 rw
UNIT

[ -f "$CONF.orig" ] || cp -a "$CONF" "$CONF.orig"
ELEM="sp12autoframe model=/opt/sp12-autoframe-dev/face_detection_yunet_2023mar.onnx control-file=/run/sp12/autoframe"
if [ "$MODE" = isp ]; then
	SRC="icamerasrc device-name=imx681-uf ! video/x-raw,format=NV12,width=1920,height=1080,framerate=30/1 ! $ELEM mode=isp ! video/x-raw,format=NV12,width=1920,height=1080 ! videoconvert"
else
	SRC="icamerasrc device-name=imx681-uf ! video/x-raw,format=NV12,width=3840,height=2160,framerate=30/1 ! $ELEM ! video/x-raw,format=NV12,width=1920,height=1080 ! videoconvert"
fi
sed -i "s|^VIDEOSRC=.*|VIDEOSRC=\"$SRC\"|" "$CONF"
grep ^VIDEOSRC "$CONF"

systemctl daemon-reload
systemctl restart v4l2-relayd@sp12-front.service
systemctl is-active v4l2-relayd@sp12-front.service
