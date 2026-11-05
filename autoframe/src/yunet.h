// YuNet face detector through OpenVINO (NPU, GPU or CPU).
// SPDX-License-Identifier: MIT
#pragma once
#include <memory>
#include <string>
#include <vector>
#include <opencv2/core.hpp>
#include "framing.h"

namespace sp12 {

class YuNet {
public:
    // Throws std::exception on failure (missing model, device not found).
    YuNet(const std::string& model, const std::string& device, int width, int height,
          float score_thr = 0.6f, float nms_thr = 0.3f);
    ~YuNet();
    int width() const { return w_; }
    int height() const { return h_; }
    const std::string& device() const { return device_; }
    // bgr: CV_8UC3, exactly width x height. Detections in input pixels, best first.
    std::vector<Det> infer(const cv::Mat& bgr);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    int w_, h_;
    float score_thr_, nms_thr_;
    std::string device_;
};

}  // namespace sp12
