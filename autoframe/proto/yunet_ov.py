"""YuNet face detector through OpenVINO (NPU, GPU or CPU).

Model: face_detection_yunet_2023mar.onnx (OpenCV Zoo, Apache-2.0). Input is a
BGR image, 0..255 floats, NCHW. Outputs per stride s in (8, 16, 32):
cls_s [1,N,1], obj_s [1,N,1], bbox_s [1,N,4], kps_s [1,N,10], N = (W/s)*(H/s),
row-major over the stride grid. score = sqrt(cls*obj), box centre
(col+dx, row+dy)*s, size exp(dw)*s, exp(dh)*s.
"""
import numpy as np
import openvino as ov

MODEL = "/usr/share/irlume/models/face_detection_yunet_2023mar.onnx"
STRIDES = (8, 16, 32)


class YuNet:
    def __init__(self, width=320, height=192, device="NPU", model=MODEL,
                 score_thr=0.6, nms_thr=0.3):
        assert width % 32 == 0 and height % 32 == 0
        self.w, self.h = width, height
        self.score_thr, self.nms_thr = score_thr, nms_thr
        core = ov.Core()
        m = core.read_model(model)
        m.reshape({m.inputs[0].get_any_name(): [1, 3, height, width]})
        self.cm = core.compile_model(m, device)
        self.req = self.cm.create_infer_request()
        self.out = {o.get_any_name(): o for o in self.cm.outputs}
        self.device = device

    def infer(self, bgr):
        """bgr: HxWx3 uint8 at (self.h, self.w). Returns [(x, y, w, h, score), ...]
        in input-image pixels, sorted by score."""
        x = np.ascontiguousarray(bgr.transpose(2, 0, 1)[None].astype(np.float32))
        self.req.infer({0: x})
        dets = []
        for s in STRIDES:
            cols, rows = self.w // s, self.h // s
            cls = self.req.get_tensor(self.out[f"cls_{s}"]).data[0, :, 0]
            obj = self.req.get_tensor(self.out[f"obj_{s}"]).data[0, :, 0]
            box = self.req.get_tensor(self.out[f"bbox_{s}"]).data[0]
            score = np.sqrt(np.clip(cls, 0, 1) * np.clip(obj, 0, 1))
            idx = np.nonzero(score > self.score_thr)[0]
            for i in idx:
                r, c = divmod(int(i), cols)
                cx = (c + box[i, 0]) * s
                cy = (r + box[i, 1]) * s
                w = np.exp(box[i, 2]) * s
                h = np.exp(box[i, 3]) * s
                dets.append((cx - w / 2, cy - h / 2, w, h, float(score[i])))
        return nms(dets, self.nms_thr)


def nms(dets, thr):
    dets = sorted(dets, key=lambda d: -d[4])
    keep = []
    for d in dets:
        if all(iou(d, k) < thr for k in keep):
            keep.append(d)
    return keep


def iou(a, b):
    x1, y1 = max(a[0], b[0]), max(a[1], b[1])
    x2, y2 = min(a[0] + a[2], b[0] + b[2]), min(a[1] + a[3], b[1] + b[3])
    inter = max(0, x2 - x1) * max(0, y2 - y1)
    return inter / (a[2] * a[3] + b[2] * b[3] - inter + 1e-9)


def read_ppm(path):
    with open(path, "rb") as f:
        assert f.readline().strip() == b"P6"
        dims = f.readline().split()
        while len(dims) < 2:
            dims += f.readline().split()
        w, h = int(dims[0]), int(dims[1])
        maxval = int(f.readline())
        assert maxval == 255
        data = np.frombuffer(f.read(w * h * 3), dtype=np.uint8)
    return data.reshape(h, w, 3)[:, :, ::-1]  # BGR


def resize_nn(img, w, h):
    """Nearest-neighbour resize (prototype only; the element uses area/linear)."""
    ys = (np.arange(h) * img.shape[0] / h).astype(int)
    xs = (np.arange(w) * img.shape[1] / w).astype(int)
    return img[ys][:, xs]


def resize_area(img, w, h):
    """Box-filter resize for integer-ish ratios: average over blocks."""
    fy, fx = img.shape[0] // h, img.shape[1] // w
    if fy < 1 or fx < 1:
        return resize_nn(img, w, h)
    c = img[: h * fy, : w * fx].reshape(h, fy, w, fx, -1).mean(axis=(1, 3))
    return c.astype(np.uint8)
