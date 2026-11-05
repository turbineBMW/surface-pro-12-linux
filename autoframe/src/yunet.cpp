// SPDX-License-Identifier: MIT
#include "yunet.h"
#include <algorithm>
#include <cmath>
#include <openvino/openvino.hpp>

namespace sp12 {

struct YuNet::Impl {
    ov::Core core;
    ov::CompiledModel cm;
    ov::InferRequest req;
};

static const int STRIDES[] = {8, 16, 32};

YuNet::YuNet(const std::string& model, const std::string& device, int width, int height,
             float score_thr, float nms_thr)
    : impl_(new Impl), w_(width), h_(height), score_thr_(score_thr), nms_thr_(nms_thr) {
    auto m = impl_->core.read_model(model);
    m->reshape({{m->inputs()[0].get_any_name(), ov::PartialShape{1, 3, height, width}}});
    impl_->cm = impl_->core.compile_model(m, device);
    impl_->req = impl_->cm.create_infer_request();
    device_ = device;
}

YuNet::~YuNet() = default;

std::vector<Det> YuNet::infer(const cv::Mat& bgr) {
    CV_Assert(bgr.type() == CV_8UC3 && bgr.cols == w_ && bgr.rows == h_);
    ov::Tensor in = impl_->req.get_input_tensor();
    float* p = in.data<float>();
    const int plane = w_ * h_;
    for (int y = 0; y < h_; y++) {
        const uint8_t* row = bgr.ptr<uint8_t>(y);
        float* o = p + y * w_;
        for (int x = 0; x < w_; x++) {
            o[x] = row[3 * x];
            o[x + plane] = row[3 * x + 1];
            o[x + 2 * plane] = row[3 * x + 2];
        }
    }
    impl_->req.infer();
    std::vector<Det> dets;
    for (int s : STRIDES) {
        int cols = w_ / s, rows = h_ / s;
        const float* cls = impl_->req.get_tensor("cls_" + std::to_string(s)).data<const float>();
        const float* obj = impl_->req.get_tensor("obj_" + std::to_string(s)).data<const float>();
        const float* box = impl_->req.get_tensor("bbox_" + std::to_string(s)).data<const float>();
        for (int i = 0; i < cols * rows; i++) {
            float sc = std::sqrt(std::clamp(cls[i], 0.f, 1.f) * std::clamp(obj[i], 0.f, 1.f));
            if (sc <= score_thr_) continue;
            int r = i / cols, c = i % cols;
            float cx = (c + box[4 * i]) * s, cy = (r + box[4 * i + 1]) * s;
            float w = std::exp(box[4 * i + 2]) * s, h = std::exp(box[4 * i + 3]) * s;
            dets.push_back({cx - w / 2, cy - h / 2, w, h, sc});
        }
    }
    std::sort(dets.begin(), dets.end(), [](const Det& a, const Det& b) { return a.score > b.score; });
    std::vector<Det> keep;
    for (const Det& d : dets) {
        bool ok = true;
        for (const Det& k : keep)
            if (iou(d.x, d.y, d.w, d.h, k.x, k.y, k.w, k.h) >= nms_thr_) { ok = false; break; }
        if (ok) keep.push_back(d);
    }
    return keep;
}

}  // namespace sp12
