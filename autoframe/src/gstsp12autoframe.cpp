// sp12autoframe: automatic framing (face-following crop) for the Surface
// Pro 12 front camera. NV12 in at any size, NV12 out at the negotiated size;
// a YuNet face detector on the NPU (OpenVINO) finds the face(s), the
// controller in framing.h decides the window, OpenCV crops and scales.
//
// Pipeline: icamerasrc ! NV12 3840x2160 ! sp12autoframe ! NV12 1920x1080 ! ...
// SPDX-License-Identifier: MIT
#include <gst/gst.h>
#include <gst/video/gstvideofilter.h>
#include <gst/video/video.h>
#include <opencv2/core/utility.hpp>
#include <opencv2/imgproc.hpp>
#include <sys/stat.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "framing.h"
#include "yunet.h"

GST_DEBUG_CATEGORY_STATIC(gst_sp12_autoframe_debug);
#define GST_CAT_DEFAULT gst_sp12_autoframe_debug

#define DEFAULT_MODEL "/usr/share/sp12/face_detection_yunet_2023mar.onnx"
#define DEFAULT_DEVICE "NPU"

struct State {
    std::unique_ptr<sp12::YuNet> det;
    sp12::Controller ctl;
    std::vector<sp12::Det> dets;  // last detections, source pixels
    cv::Mat ysmall, uvsmall, nv12small, bgr;
    guint64 frame_no = 0;
    GstClockTime last_pts = GST_CLOCK_TIME_NONE;
    time_t ctl_mtime = 0;
    double t_det = 0, t_crop = 0;
    int n_timed = 0;
    int in_w = 0, in_h = 0, out_w = 0, out_h = 0;
    /* ISP mode */
    GstElement *zoom_target = nullptr;      // upstream element with a "zoom-region" property
    std::vector<sp12::Window> sent;         // windows sent, newest last (for latency mapping)
    sp12::Window last_sent{0, 0, 0, 0};
    int array_w = 3844, array_h = 2640;
    /* Face-based exposure */
    GstElement *face_target = nullptr;      // upstream element with a "face-regions" property
    std::string faces_sent;                 // last "face-regions" value sent
};

typedef struct _GstSp12AutoFrame {
    GstVideoFilter parent;
    /* properties */
    gboolean enable;
    gchar *device;
    gchar *model;
    gint det_width, det_height;
    gdouble max_zoom, face_frac, headroom, speed, hold_time;
    gboolean group;
    gint detect_interval;
    gchar *control_file;
    gboolean draw_boxes;
    gint mode;                 /* 0 crop (in the element), 1 isp (zoom-region upstream) */
    gchar *active_array;       /* "WxH" sensor active array, ISP mode */
    gint isp_latency;          /* frames between a zoom-region update and its effect */
    gboolean face_ae;          /* send faces upstream as face-regions (face-based 3A) */
    /* state */
    State *st;
} GstSp12AutoFrame;

typedef struct _GstSp12AutoFrameClass {
    GstVideoFilterClass parent_class;
} GstSp12AutoFrameClass;

enum {
    PROP_0,
    PROP_ENABLE,
    PROP_DEVICE,
    PROP_MODEL,
    PROP_DET_WIDTH,
    PROP_DET_HEIGHT,
    PROP_MAX_ZOOM,
    PROP_FACE_FRAC,
    PROP_HEADROOM,
    PROP_SPEED,
    PROP_HOLD_TIME,
    PROP_GROUP,
    PROP_DETECT_INTERVAL,
    PROP_CONTROL_FILE,
    PROP_DRAW_BOXES,
    PROP_MODE,
    PROP_ACTIVE_ARRAY,
    PROP_ISP_LATENCY,
    PROP_FACE_AE,
};

enum { MODE_CROP = 0, MODE_ISP = 1 };

#define GST_TYPE_SP12_AUTOFRAME_MODE (gst_sp12_autoframe_mode_get_type())
static GType gst_sp12_autoframe_mode_get_type(void) {
    static GType t = 0;
    static const GEnumValue values[] = {
        {MODE_CROP, "Crop and scale in the element (input larger than output)", "crop"},
        {MODE_ISP, "Pass through; send the window upstream as zoom-region (ISP crops)", "isp"},
        {0, NULL, NULL}};
    if (!t) t = g_enum_register_static("GstSp12AutoFrameMode", values);
    return t;
}

#define CAPS_STR GST_VIDEO_CAPS_MAKE("NV12")
static GstStaticPadTemplate sink_template =
    GST_STATIC_PAD_TEMPLATE("sink", GST_PAD_SINK, GST_PAD_ALWAYS, GST_STATIC_CAPS(CAPS_STR));
static GstStaticPadTemplate src_template =
    GST_STATIC_PAD_TEMPLATE("src", GST_PAD_SRC, GST_PAD_ALWAYS, GST_STATIC_CAPS(CAPS_STR));

#define GST_TYPE_SP12_AUTOFRAME (gst_sp12_autoframe_get_type())
G_DEFINE_TYPE(GstSp12AutoFrame, gst_sp12_autoframe, GST_TYPE_VIDEO_FILTER);
#define GST_SP12_AUTOFRAME(obj) (G_TYPE_CHECK_INSTANCE_CAST((obj), GST_TYPE_SP12_AUTOFRAME, GstSp12AutoFrame))

static void apply_params(GstSp12AutoFrame *self) {
    sp12::FrameParams &p = self->st->ctl.p;
    p.max_zoom = self->max_zoom;
    p.face_frac = self->face_frac;
    p.headroom = self->headroom;
    p.omega = self->speed;
    p.hold_time = self->hold_time;
    p.group = self->group;
    self->st->ctl.set_enabled(self->enable);
}

static void gst_sp12_autoframe_set_property(GObject *object, guint prop_id, const GValue *value,
                                            GParamSpec *pspec) {
    GstSp12AutoFrame *self = GST_SP12_AUTOFRAME(object);
    GST_OBJECT_LOCK(self);
    switch (prop_id) {
    case PROP_ENABLE: self->enable = g_value_get_boolean(value); break;
    case PROP_DEVICE: g_free(self->device); self->device = g_value_dup_string(value); break;
    case PROP_MODEL: g_free(self->model); self->model = g_value_dup_string(value); break;
    case PROP_DET_WIDTH: self->det_width = g_value_get_int(value); break;
    case PROP_DET_HEIGHT: self->det_height = g_value_get_int(value); break;
    case PROP_MAX_ZOOM: self->max_zoom = g_value_get_double(value); break;
    case PROP_FACE_FRAC: self->face_frac = g_value_get_double(value); break;
    case PROP_HEADROOM: self->headroom = g_value_get_double(value); break;
    case PROP_SPEED: self->speed = g_value_get_double(value); break;
    case PROP_HOLD_TIME: self->hold_time = g_value_get_double(value); break;
    case PROP_GROUP: self->group = g_value_get_boolean(value); break;
    case PROP_DETECT_INTERVAL: self->detect_interval = g_value_get_int(value); break;
    case PROP_CONTROL_FILE:
        g_free(self->control_file);
        self->control_file = g_value_dup_string(value);
        self->st->ctl_mtime = 0;
        break;
    case PROP_DRAW_BOXES: self->draw_boxes = g_value_get_boolean(value); break;
    case PROP_MODE: self->mode = g_value_get_enum(value); break;
    case PROP_ACTIVE_ARRAY: {
        g_free(self->active_array);
        self->active_array = g_value_dup_string(value);
        int w = 0, h = 0;
        if (self->active_array && sscanf(self->active_array, "%dx%d", &w, &h) == 2 && w > 0 && h > 0) {
            self->st->array_w = w;
            self->st->array_h = h;
        }
        break;
    }
    case PROP_ISP_LATENCY: self->isp_latency = g_value_get_int(value); break;
    case PROP_FACE_AE: self->face_ae = g_value_get_boolean(value); break;
    default: G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec); break;
    }
    apply_params(self);
    GST_OBJECT_UNLOCK(self);
}

static void gst_sp12_autoframe_get_property(GObject *object, guint prop_id, GValue *value,
                                            GParamSpec *pspec) {
    GstSp12AutoFrame *self = GST_SP12_AUTOFRAME(object);
    GST_OBJECT_LOCK(self);
    switch (prop_id) {
    case PROP_ENABLE: g_value_set_boolean(value, self->enable); break;
    case PROP_DEVICE: g_value_set_string(value, self->device); break;
    case PROP_MODEL: g_value_set_string(value, self->model); break;
    case PROP_DET_WIDTH: g_value_set_int(value, self->det_width); break;
    case PROP_DET_HEIGHT: g_value_set_int(value, self->det_height); break;
    case PROP_MAX_ZOOM: g_value_set_double(value, self->max_zoom); break;
    case PROP_FACE_FRAC: g_value_set_double(value, self->face_frac); break;
    case PROP_HEADROOM: g_value_set_double(value, self->headroom); break;
    case PROP_SPEED: g_value_set_double(value, self->speed); break;
    case PROP_HOLD_TIME: g_value_set_double(value, self->hold_time); break;
    case PROP_GROUP: g_value_set_boolean(value, self->group); break;
    case PROP_DETECT_INTERVAL: g_value_set_int(value, self->detect_interval); break;
    case PROP_CONTROL_FILE: g_value_set_string(value, self->control_file); break;
    case PROP_DRAW_BOXES: g_value_set_boolean(value, self->draw_boxes); break;
    case PROP_MODE: g_value_set_enum(value, self->mode); break;
    case PROP_ACTIVE_ARRAY: g_value_set_string(value, self->active_array); break;
    case PROP_ISP_LATENCY: g_value_set_int(value, self->isp_latency); break;
    case PROP_FACE_AE: g_value_set_boolean(value, self->face_ae); break;
    default: G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec); break;
    }
    GST_OBJECT_UNLOCK(self);
}

static void gst_sp12_autoframe_finalize(GObject *object) {
    GstSp12AutoFrame *self = GST_SP12_AUTOFRAME(object);
    if (self->st->zoom_target) gst_object_unref(self->st->zoom_target);
    if (self->st->face_target) gst_object_unref(self->st->face_target);
    delete self->st;
    g_free(self->active_array);
    g_free(self->device);
    g_free(self->model);
    g_free(self->control_file);
    G_OBJECT_CLASS(gst_sp12_autoframe_parent_class)->finalize(object);
}

/* Any input size maps to any output size: strip width/height. */
static GstCaps *gst_sp12_autoframe_transform_caps(GstBaseTransform *trans, GstPadDirection direction,
                                                  GstCaps *caps, GstCaps *filter) {
    GstCaps *ret = gst_caps_copy(caps);
    for (guint i = 0; i < gst_caps_get_size(ret); i++) {
        GstStructure *s = gst_caps_get_structure(ret, i);
        gst_structure_set(s, "width", GST_TYPE_INT_RANGE, 2, G_MAXINT, "height", GST_TYPE_INT_RANGE, 2,
                          G_MAXINT, NULL);
        gst_structure_remove_fields(s, "pixel-aspect-ratio", NULL);
    }
    if (filter) {
        GstCaps *tmp = gst_caps_intersect_full(filter, ret, GST_CAPS_INTERSECT_FIRST);
        gst_caps_unref(ret);
        ret = tmp;
    }
    GST_DEBUG_OBJECT(trans, "transform_caps %s: %" GST_PTR_FORMAT " -> %" GST_PTR_FORMAT,
                     direction == GST_PAD_SINK ? "sink" : "src", caps, ret);
    return ret;
}

/* Prefer the input size when the other side leaves the size open. */
static GstCaps *gst_sp12_autoframe_fixate_caps(GstBaseTransform *trans, GstPadDirection direction,
                                               GstCaps *caps, GstCaps *othercaps) {
    (void)trans;
    (void)direction;
    GstStructure *in = gst_caps_get_structure(caps, 0);
    gint w = 0, h = 0;
    gst_structure_get_int(in, "width", &w);
    gst_structure_get_int(in, "height", &h);
    othercaps = gst_caps_make_writable(othercaps);
    othercaps = gst_caps_truncate(othercaps);
    GstStructure *out = gst_caps_get_structure(othercaps, 0);
    if (w > 0) gst_structure_fixate_field_nearest_int(out, "width", w);
    if (h > 0) gst_structure_fixate_field_nearest_int(out, "height", h);
    const GValue *fr = gst_structure_get_value(in, "framerate");
    if (fr && GST_VALUE_HOLDS_FRACTION(fr))
        gst_structure_fixate_field_nearest_fraction(out, "framerate", gst_value_get_fraction_numerator(fr),
                                                    gst_value_get_fraction_denominator(fr));
    return gst_caps_fixate(othercaps);
}

/* Walk upstream from our sink pad to the first element with property `prop`
 * (icamerasrc with the sp12 patches), through capsfilters and queues.
 * Returns a reference, or NULL. */
static GstElement *find_upstream_with(GstSp12AutoFrame *self, const char *prop) {
    GstPad *pad = GST_PAD(gst_object_ref(GST_BASE_TRANSFORM_SINK_PAD(self)));
    for (int hop = 0; hop < 8 && pad; hop++) {
        GstPad *peer = gst_pad_get_peer(pad);
        gst_object_unref(pad);
        pad = nullptr;
        if (!peer) break;
        GstElement *el = gst_pad_get_parent_element(peer);
        gst_object_unref(peer);
        if (!el) break;
        if (g_object_class_find_property(G_OBJECT_GET_CLASS(el), prop)) {
            GST_INFO_OBJECT(self, "%s target: %s", prop, GST_ELEMENT_NAME(el));
            return el;  // keep the ref
        }
        pad = gst_element_get_static_pad(el, "sink");
        gst_object_unref(el);
    }
    if (pad) gst_object_unref(pad);
    return nullptr;
}

static void find_zoom_target(GstSp12AutoFrame *self) {
    self->st->zoom_target = find_upstream_with(self, "zoom-region");
    if (!self->st->zoom_target)
        GST_WARNING_OBJECT(self, "no upstream element with a zoom-region property; ISP mode will not move the window");
}

/* Hand the faces to the camera HAL for face-based exposure (icamerasrc
 * "face-regions": "l,t,r,b;..." in sensor active-array pixels). `dets` are in
 * active-array pixels already in ISP mode; in crop mode they are in input
 * pixels of a frame that shows the full array width, centre-cropped to the
 * frame's aspect. Sent only when the (8 px quantised) list changes. */
static void send_faces(GstSp12AutoFrame *self, bool isp, bool on) {
    State *st = self->st;
    if (!st->face_target) return;
    std::string v;
    if (on) {
        const float scale = isp ? 1.f : (float)st->array_w / st->in_w;
        const float oy = isp ? 0.f : (st->array_h - st->in_h * scale) / 2;
        int n = 0;
        for (const auto &d : st->dets) {
            if (n++ == 4) break;
            int l = (int)std::lround(d.x * scale), t = (int)std::lround(oy + d.y * scale);
            int r = (int)std::lround((d.x + d.w) * scale), b = (int)std::lround(oy + (d.y + d.h) * scale);
            l = std::clamp(l, 0, st->array_w) & ~7; t = std::clamp(t, 0, st->array_h) & ~7;
            r = std::clamp(r, 0, st->array_w) & ~7; b = std::clamp(b, 0, st->array_h) & ~7;
            if (r <= l || b <= t) continue;
            char buf[64];
            g_snprintf(buf, sizeof buf, "%s%d,%d,%d,%d", v.empty() ? "" : ";", l, t, r, b);
            v += buf;
        }
    }
    if (v == st->faces_sent) return;
    st->faces_sent = v;
    g_object_set(st->face_target, "face-regions", v.c_str(), NULL);
}

static gboolean gst_sp12_autoframe_set_info(GstVideoFilter *filter, GstCaps *incaps, GstVideoInfo *in_info,
                                            GstCaps *outcaps, GstVideoInfo *out_info) {
    GstSp12AutoFrame *self = GST_SP12_AUTOFRAME(filter);
    (void)incaps;
    (void)outcaps;
    State *st = self->st;
    st->in_w = GST_VIDEO_INFO_WIDTH(in_info);
    st->in_h = GST_VIDEO_INFO_HEIGHT(in_info);
    st->out_w = GST_VIDEO_INFO_WIDTH(out_info);
    st->out_h = GST_VIDEO_INFO_HEIGHT(out_info);
    GST_OBJECT_LOCK(self);
    const bool isp = self->mode == MODE_ISP;
    if (isp) {
        st->ctl.p.extend_aspect = (float)st->array_w / st->array_h;
        st->ctl.reset(st->array_w, st->array_h, (float)st->out_w / st->out_h);
    } else {
        st->ctl.p.extend_aspect = 0;
        st->ctl.reset(st->in_w, st->in_h, (float)st->out_w / st->out_h);
    }
    apply_params(self);
    GST_OBJECT_UNLOCK(self);
    /* In place only when the sizes match (ISP mode). In crop mode the 1080p
     * result used to be written back into icamerasrc's 4K buffer, and reading
     * it there was slow: the relay's colour conversion took 17.7 ms per frame
     * on it against 3.8 ms on a copy, half a core. A fresh output buffer
     * (transform_frame) costs nothing extra: the crop writes it anyway. */
    gst_base_transform_set_in_place(GST_BASE_TRANSFORM(filter), st->in_w == st->out_w && st->in_h == st->out_h);
    st->dets.clear();
    st->sent.clear();
    st->last_sent = {0, 0, 0, 0};
    st->last_pts = GST_CLOCK_TIME_NONE;
    if (isp && !st->zoom_target) find_zoom_target(self);
    if (!st->face_target) {
        st->face_target = find_upstream_with(self, "face-regions");
        if (!st->face_target) GST_INFO_OBJECT(self, "no upstream face-regions property: no face-based exposure");
    }
    st->faces_sent = "";
    GST_INFO_OBJECT(self, "%s mode: in %dx%d -> out %dx%d, window space %dx%d, full window %.0f px wide, max zoom %.2f%s",
                    isp ? "isp" : "crop", st->in_w, st->in_h, st->out_w, st->out_h, isp ? st->array_w : st->in_w,
                    isp ? st->array_h : st->in_h, st->ctl.current().w, self->max_zoom,
                    isp ? (st->zoom_target ? ", zoom target found" : ", NO zoom target upstream") : "");
    return TRUE;
}

static gboolean gst_sp12_autoframe_start(GstBaseTransform *trans) {
    GstSp12AutoFrame *self = GST_SP12_AUTOFRAME(trans);
    State *st = self->st;
    GST_OBJECT_LOCK(self);
    std::string model = self->model ? self->model : DEFAULT_MODEL;
    std::string want = self->device ? self->device : DEFAULT_DEVICE;
    int dw = self->det_width, dh = self->det_height;
    GST_OBJECT_UNLOCK(self);
    /* The per-frame OpenCV work is ~2 ms; spreading it over a thread pool
     * costs more in wake-ups than it saves (13 idle-spinning workers measured). */
    cv::setNumThreads(1);
    const char *order[] = {want.c_str(), "GPU", "CPU"};
    std::string err;
    for (const char *dev : order) {
        try {
            st->det.reset(new sp12::YuNet(model, dev, dw, dh));
            break;
        } catch (const std::exception &e) {
            err = e.what();
            GST_WARNING_OBJECT(self, "face detector on %s failed: %s", dev, e.what());
        }
    }
    if (!st->det) {
        GST_ELEMENT_ERROR(self, LIBRARY, INIT, ("Face detector unavailable"), ("%s: %s", model.c_str(), err.c_str()));
        return FALSE;
    }
    GST_INFO_OBJECT(self, "face detector %s on %s, %dx%d", model.c_str(), st->det->device().c_str(), dw, dh);
    st->frame_no = 0;
    st->t_det = st->t_crop = 0;
    st->n_timed = 0;
    return TRUE;
}

static gboolean gst_sp12_autoframe_stop(GstBaseTransform *trans) {
    GstSp12AutoFrame *self = GST_SP12_AUTOFRAME(trans);
    /* The HAL keeps the last faces; leave none behind for the next session. */
    send_faces(self, false, false);
    self->st->det.reset();
    return TRUE;
}

/* Control file: "mode=auto|off" lines, re-read when its mtime changes.
 * Lets a user-session toggle reach the element inside the system relay. */
static void poll_control_file(GstSp12AutoFrame *self) {
    GST_OBJECT_LOCK(self);
    gchar *path = g_strdup(self->control_file);
    GST_OBJECT_UNLOCK(self);
    if (!path) return;
    struct stat sb;
    if (stat(path, &sb) != 0) {
        g_free(path);
        return;
    }
    if (sb.st_mtime == self->st->ctl_mtime) {
        g_free(path);
        return;
    }
    self->st->ctl_mtime = sb.st_mtime;
    gchar *data = nullptr;
    if (g_file_get_contents(path, &data, nullptr, nullptr)) {
        gchar **lines = g_strsplit(data, "\n", -1);
        for (gchar **l = lines; *l; l++) {
            gchar *line = g_strstrip(*l);
            if (g_str_has_prefix(line, "mode=")) {
                gboolean on = g_strcmp0(line + 5, "off") != 0;
                GST_INFO_OBJECT(self, "control file: mode=%s", line + 5);
                g_object_set(self, "enable", on, NULL);
            } else if (g_str_has_prefix(line, "max-zoom=")) {
                g_object_set(self, "max-zoom", g_ascii_strtod(line + 9, nullptr), NULL);
            } else if (g_str_has_prefix(line, "face-frac=")) {
                g_object_set(self, "face-frac", g_ascii_strtod(line + 10, nullptr), NULL);
            } else if (g_str_has_prefix(line, "headroom=")) {
                g_object_set(self, "headroom", g_ascii_strtod(line + 9, nullptr), NULL);
            } else if (g_str_has_prefix(line, "speed=")) {
                g_object_set(self, "speed", g_ascii_strtod(line + 6, nullptr), NULL);
            } else if (g_str_has_prefix(line, "hold-time=")) {
                g_object_set(self, "hold-time", g_ascii_strtod(line + 10, nullptr), NULL);
            } else if (g_str_has_prefix(line, "face-ae=")) {
                g_object_set(self, "face-ae", g_strcmp0(line + 8, "1") == 0 || g_strcmp0(line + 8, "true") == 0, NULL);
            } else if (g_str_has_prefix(line, "draw-boxes=")) {
                g_object_set(self, "draw-boxes", g_strcmp0(line + 11, "1") == 0 || g_strcmp0(line + 11, "true") == 0, NULL);
            }
        }
        g_strfreev(lines);
        g_free(data);
    }
    g_free(path);
}

/* Detection on the frame (any size): detections in frame pixels. */
static void run_detector(GstSp12AutoFrame *self, const cv::Mat &y_in, const cv::Mat &uv_in) {
    State *st = self->st;
    const int iw = y_in.cols, ih = y_in.rows;
    const int dw = st->det->width(), dh = st->det->height();
    int tw = dw, th = std::min(dh, (int)std::lround((double)ih * dw / iw)) & ~1;
    if (th < 2) th = 2;
    if (st->nv12small.empty()) {
        st->nv12small.create(dh * 3 / 2, dw, CV_8UC1);
        st->nv12small(cv::Rect(0, 0, dw, dh)).setTo(0);
        st->nv12small(cv::Rect(0, dh, dw, dh / 2)).setTo(128);
    }
    cv::Mat ydst = st->nv12small(cv::Rect(0, 0, tw, th));
    cv::resize(y_in, ydst, ydst.size(), 0, 0, cv::INTER_AREA);
    cv::resize(uv_in, st->uvsmall, cv::Size(tw / 2, th / 2), 0, 0, cv::INTER_AREA);
    st->uvsmall.reshape(1, th / 2).copyTo(st->nv12small(cv::Rect(0, dh, tw, th / 2)));
    cv::cvtColor(st->nv12small, st->bgr, cv::COLOR_YUV2BGR_NV12);
    st->dets = st->det->infer(st->bgr);
    const float sx = (float)iw / tw, sy = (float)ih / th;
    for (auto &d : st->dets) {
        d.x *= sx; d.w *= sx; d.y *= sy; d.h *= sy;
    }
}

/* Common per-frame work: control file, dt, detection, controller. Returns the
 * window in the controller's space (input pixels in crop mode, the sensor
 * active array in ISP mode). */
static sp12::Window frame_step(GstSp12AutoFrame *self, GstVideoFrame *in, gint64 *t_det_us) {
    State *st = self->st;
    if (st->frame_no % 30 == 0) poll_control_file(self);

    float dt = 1.f / 30;
    GstClockTime pts = GST_BUFFER_PTS(in->buffer);
    if (GST_CLOCK_TIME_IS_VALID(pts) && GST_CLOCK_TIME_IS_VALID(st->last_pts) && pts > st->last_pts) {
        dt = (float)((pts - st->last_pts) / 1e9);
        if (dt > 0.5f) dt = 0.5f;
    }
    st->last_pts = pts;

    GST_OBJECT_LOCK(self);
    gboolean enabled = self->enable;
    int interval = self->detect_interval > 0 ? self->detect_interval : 1;
    const bool isp = self->mode == MODE_ISP;
    const int latency = self->isp_latency;
    const bool face_ae = self->face_ae;
    GST_OBJECT_UNLOCK(self);

    const int iw = GST_VIDEO_FRAME_WIDTH(in), ih = GST_VIDEO_FRAME_HEIGHT(in);
    cv::Mat y_in(ih, iw, CV_8UC1, GST_VIDEO_FRAME_PLANE_DATA(in, 0), GST_VIDEO_FRAME_PLANE_STRIDE(in, 0));
    cv::Mat uv_in(ih / 2, iw / 2, CV_8UC2, GST_VIDEO_FRAME_PLANE_DATA(in, 1), GST_VIDEO_FRAME_PLANE_STRIDE(in, 1));

    gint64 t0 = g_get_monotonic_time();
    /* Detect for framing, and for face-based exposure even with framing off
     * (the controller ignores the faces then). */
    const bool detect_now = (enabled || face_ae) && st->det && st->frame_no % interval == 0;
    if (detect_now) {
        run_detector(self, y_in, uv_in);
        if (isp) {
            /* The frame shows the window sent `latency` frames ago; map the
             * detections through it into active-array coordinates. */
            sp12::Window w = st->ctl.current();
            if (!st->sent.empty()) {
                size_t idx = st->sent.size() > (size_t)latency ? st->sent.size() - 1 - latency : 0;
                w = st->sent[idx];
            }
            const float sx = w.w / iw, sy = w.h / ih;
            for (auto &d : st->dets) {
                d.x = w.x + d.x * sx; d.w *= sx; d.y = w.y + d.y * sy; d.h *= sy;
            }
        }
        send_faces(self, isp, face_ae);
    } else if (!face_ae) {
        send_faces(self, isp, false);  // switched off: clear the HAL's faces once
    }
    *t_det_us = g_get_monotonic_time() - t0;

    GST_OBJECT_LOCK(self);
    sp12::Window win = st->ctl.step(st->dets, dt);
    GST_OBJECT_UNLOCK(self);
    return win;
}

static void round_window(sp12::Window &win, int max_w, int max_h, int &x, int &y, int &w, int &h) {
    x = ((int)std::lround(win.x)) & ~1; y = ((int)std::lround(win.y)) & ~1;
    w = ((int)std::lround(win.w)) & ~1; h = ((int)std::lround(win.h)) & ~1;
    if (w < 2) w = 2;
    if (h < 2) h = 2;
    if (x + w > max_w) x = max_w - w;
    if (y + h > max_h) y = max_h - h;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
}

static void draw_dets(GstSp12AutoFrame *self, cv::Mat &y_out, float ox, float oy, float sx, float sy) {
    for (const auto &d : self->st->dets)
        cv::rectangle(y_out, cv::Rect((int)((d.x - ox) * sx), (int)((d.y - oy) * sy), (int)(d.w * sx), (int)(d.h * sy)),
                      cv::Scalar(235), 2);
}

static void log_timing(GstSp12AutoFrame *self, gint64 det_us, gint64 crop_us, int x, int y, int w, int h, float full_w) {
    State *st = self->st;
    st->t_det += det_us / 1000.0;
    st->t_crop += crop_us / 1000.0;
    if (++st->n_timed == 300) {
        GST_DEBUG_OBJECT(self, "avg per frame: detect %.2f ms, crop+scale %.2f ms; window %d,%d %dx%d zoom %.2f, %zu face(s)",
                         st->t_det / 300, st->t_crop / 300, x, y, w, h, w > 0 ? full_w / w : 0.f, st->dets.size());
        st->t_det = st->t_crop = 0;
        st->n_timed = 0;
    }
    st->frame_no++;
}

/* ISP mode (and crop mode with equal sizes): the frame passes through. */
static GstFlowReturn gst_sp12_autoframe_transform_frame_ip(GstVideoFilter *filter, GstVideoFrame *frame) {
    GstSp12AutoFrame *self = GST_SP12_AUTOFRAME(filter);
    State *st = self->st;
    gint64 det_us = 0;
    sp12::Window win = frame_step(self, frame, &det_us);
    gint64 t1 = g_get_monotonic_time();
    const int fw = GST_VIDEO_FRAME_WIDTH(frame), fh = GST_VIDEO_FRAME_HEIGHT(frame);
    int x, y, w, h;
    GST_OBJECT_LOCK(self);
    const bool isp = self->mode == MODE_ISP;
    gboolean draw = self->draw_boxes;
    GST_OBJECT_UNLOCK(self);
    if (isp) {
        round_window(win, st->array_w, st->array_h, x, y, w, h);
        sp12::Window sent{(float)x, (float)y, (float)w, (float)h};
        if (std::fabs(sent.x - st->last_sent.x) >= 2 || std::fabs(sent.y - st->last_sent.y) >= 2 ||
            std::fabs(sent.w - st->last_sent.w) >= 2) {
            if (st->zoom_target) {
                char buf[64];
                /* the full view is the whole active array, not 0,0,0,0 (which the HAL ignores) */
                if (w >= st->array_w - 2) g_snprintf(buf, sizeof buf, "0,0,%d,%d", st->array_w, st->array_h);
                else g_snprintf(buf, sizeof buf, "%d,%d,%d,%d", x, y, x + w, y + h);
                g_object_set(st->zoom_target, "zoom-region", buf, NULL);
            }
            st->last_sent = sent;
        }
        st->sent.push_back(sent);
        if (st->sent.size() > 64) st->sent.erase(st->sent.begin(), st->sent.begin() + 32);
        if (draw) {
            cv::Mat y_out(fh, fw, CV_8UC1, GST_VIDEO_FRAME_PLANE_DATA(frame, 0), GST_VIDEO_FRAME_PLANE_STRIDE(frame, 0));
            draw_dets(self, y_out, sent.x, sent.y, (float)fw / sent.w, (float)fh / sent.h);
        }
    } else {
        /* crop mode with in == out: crop and scale through a copy */
        round_window(win, fw, fh, x, y, w, h);
        cv::Mat y_io(fh, fw, CV_8UC1, GST_VIDEO_FRAME_PLANE_DATA(frame, 0), GST_VIDEO_FRAME_PLANE_STRIDE(frame, 0));
        cv::Mat uv_io(fh / 2, fw / 2, CV_8UC2, GST_VIDEO_FRAME_PLANE_DATA(frame, 1), GST_VIDEO_FRAME_PLANE_STRIDE(frame, 1));
        if (w != fw || h != fh) {
            cv::Mat yc, uvc;
            cv::resize(y_io(cv::Rect(x, y, w, h)), yc, y_io.size(), 0, 0, cv::INTER_LINEAR);
            cv::resize(uv_io(cv::Rect(x / 2, y / 2, w / 2, h / 2)), uvc, uv_io.size(), 0, 0, cv::INTER_LINEAR);
            yc.copyTo(y_io);
            uvc.copyTo(uv_io);
        }
        if (draw) draw_dets(self, y_io, x, y, (float)fw / w, (float)fh / h);
    }
    log_timing(self, det_us, g_get_monotonic_time() - t1, x, y, w, h, st->ctl.current().w > 0 ? (isp ? std::min(st->array_w, (int)(st->array_h * (float)fw / fh)) : std::min(fw, (int)(fh * (float)fw / fh))) : 0);
    return GST_FLOW_OK;
}

/* Crop mode with different sizes: crop and scale from in to out. */
static GstFlowReturn gst_sp12_autoframe_transform_frame(GstVideoFilter *filter, GstVideoFrame *in,
                                                        GstVideoFrame *out) {
    GstSp12AutoFrame *self = GST_SP12_AUTOFRAME(filter);
    State *st = self->st;
    const int iw = st->in_w, ih = st->in_h, ow = st->out_w, oh = st->out_h;
    gint64 det_us = 0;
    sp12::Window win = frame_step(self, in, &det_us);
    gint64 t1 = g_get_monotonic_time();
    GST_OBJECT_LOCK(self);
    gboolean draw = self->draw_boxes;
    GST_OBJECT_UNLOCK(self);
    int x, y, w, h;
    round_window(win, iw, ih, x, y, w, h);

    cv::Mat y_in(ih, iw, CV_8UC1, GST_VIDEO_FRAME_PLANE_DATA(in, 0), GST_VIDEO_FRAME_PLANE_STRIDE(in, 0));
    cv::Mat uv_in(ih / 2, iw / 2, CV_8UC2, GST_VIDEO_FRAME_PLANE_DATA(in, 1), GST_VIDEO_FRAME_PLANE_STRIDE(in, 1));
    cv::Mat y_out(oh, ow, CV_8UC1, GST_VIDEO_FRAME_PLANE_DATA(out, 0), GST_VIDEO_FRAME_PLANE_STRIDE(out, 0));
    cv::Mat uv_out(oh / 2, ow / 2, CV_8UC2, GST_VIDEO_FRAME_PLANE_DATA(out, 1), GST_VIDEO_FRAME_PLANE_STRIDE(out, 1));
    if (w == ow && h == oh) {
        y_in(cv::Rect(x, y, w, h)).copyTo(y_out);
        uv_in(cv::Rect(x / 2, y / 2, w / 2, h / 2)).copyTo(uv_out);
    } else {
        /* INTER_AREA only at >= 2x (OpenCV's integer fast path, ~1.5 ms);
         * its generic path at 1.x ratios costs 8 ms single-threaded. */
        int interp = w >= 2 * ow ? cv::INTER_AREA : cv::INTER_LINEAR;
        cv::resize(y_in(cv::Rect(x, y, w, h)), y_out, y_out.size(), 0, 0, interp);
        cv::resize(uv_in(cv::Rect(x / 2, y / 2, w / 2, h / 2)), uv_out, uv_out.size(), 0, 0, interp);
    }
    if (draw) draw_dets(self, y_out, x, y, (float)ow / w, (float)oh / h);
    log_timing(self, det_us, g_get_monotonic_time() - t1, x, y, w, h, std::min(iw, (int)(ih * (float)ow / oh)));
    return GST_FLOW_OK;
}

static void gst_sp12_autoframe_class_init(GstSp12AutoFrameClass *klass) {
    GObjectClass *gobject_class = G_OBJECT_CLASS(klass);
    GstElementClass *element_class = GST_ELEMENT_CLASS(klass);
    GstBaseTransformClass *trans_class = GST_BASE_TRANSFORM_CLASS(klass);
    GstVideoFilterClass *filter_class = GST_VIDEO_FILTER_CLASS(klass);

    gobject_class->set_property = gst_sp12_autoframe_set_property;
    gobject_class->get_property = gst_sp12_autoframe_get_property;
    gobject_class->finalize = gst_sp12_autoframe_finalize;

    auto flags = (GParamFlags)(G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);
    g_object_class_install_property(gobject_class, PROP_ENABLE,
        g_param_spec_boolean("enable", "Enable", "Follow faces (false: full view, scaled)", TRUE, flags));
    g_object_class_install_property(gobject_class, PROP_DEVICE,
        g_param_spec_string("device", "Device", "OpenVINO device for the detector (NPU, GPU, CPU); falls back GPU, CPU", DEFAULT_DEVICE, flags));
    g_object_class_install_property(gobject_class, PROP_MODEL,
        g_param_spec_string("model", "Model", "YuNet ONNX model path", DEFAULT_MODEL, flags));
    g_object_class_install_property(gobject_class, PROP_DET_WIDTH,
        g_param_spec_int("det-width", "Detector width", "Detector input width (multiple of 32)", 32, 1024, 320, flags));
    g_object_class_install_property(gobject_class, PROP_DET_HEIGHT,
        g_param_spec_int("det-height", "Detector height", "Detector input height (multiple of 32)", 32, 1024, 192, flags));
    g_object_class_install_property(gobject_class, PROP_MAX_ZOOM,
        g_param_spec_double("max-zoom", "Max zoom", "Tightest crop as a factor of the full view", 1.0, 8.0, 2.0, flags));
    g_object_class_install_property(gobject_class, PROP_FACE_FRAC,
        g_param_spec_double("face-frac", "Face fraction", "Face height as a fraction of the window height", 0.1, 0.9, 0.30, flags));
    g_object_class_install_property(gobject_class, PROP_HEADROOM,
        g_param_spec_double("headroom", "Headroom", "Face centre above window centre, fraction of window height", -0.3, 0.4, 0.12, flags));
    g_object_class_install_property(gobject_class, PROP_SPEED,
        g_param_spec_double("speed", "Speed", "Spring natural frequency, rad/s (bigger: snappier)", 0.5, 20.0, 4.0, flags));
    g_object_class_install_property(gobject_class, PROP_HOLD_TIME,
        g_param_spec_double("hold-time", "Hold time", "Seconds to hold the window after the face is lost", 0.0, 60.0, 3.0, flags));
    g_object_class_install_property(gobject_class, PROP_GROUP,
        g_param_spec_boolean("group", "Group", "Frame all faces (false: the largest)", TRUE, flags));
    g_object_class_install_property(gobject_class, PROP_DETECT_INTERVAL,
        g_param_spec_int("detect-interval", "Detect interval", "Run the detector every N frames", 1, 30, 2, flags));
    g_object_class_install_property(gobject_class, PROP_CONTROL_FILE,
        g_param_spec_string("control-file", "Control file", "File with mode=auto|off (and max-zoom=, face-frac=, headroom=, speed=, hold-time=, draw-boxes=), re-read on change", NULL, flags));
    g_object_class_install_property(gobject_class, PROP_DRAW_BOXES,
        g_param_spec_boolean("draw-boxes", "Draw boxes", "Draw detections on the output (debug)", FALSE, flags));
    g_object_class_install_property(gobject_class, PROP_MODE,
        g_param_spec_enum("mode", "Mode", "Where the crop happens", GST_TYPE_SP12_AUTOFRAME_MODE, MODE_CROP, flags));
    g_object_class_install_property(gobject_class, PROP_ACTIVE_ARRAY,
        g_param_spec_string("active-array", "Active array", "Sensor active array WxH, the zoom-region coordinate space (ISP mode)", "3844x2640", flags));
    g_object_class_install_property(gobject_class, PROP_ISP_LATENCY,
        g_param_spec_int("isp-latency", "ISP latency", "Frames between sending a zoom-region and seeing it in the output (ISP mode)", 0, 30, 2, flags));
    g_object_class_install_property(gobject_class, PROP_FACE_AE,
        g_param_spec_boolean("face-ae", "Face AE", "Send detected faces upstream as icamerasrc face-regions, for face-based exposure (also with framing off)", TRUE, flags));

    gst_element_class_set_static_metadata(element_class, "Surface Pro 12 automatic framing", "Filter/Effect/Video",
        "Crops and scales NV12 video to follow faces (YuNet on the NPU through OpenVINO)",
        "surface-pro-12-linux");
    gst_element_class_add_static_pad_template(element_class, &sink_template);
    gst_element_class_add_static_pad_template(element_class, &src_template);

    trans_class->transform_caps = GST_DEBUG_FUNCPTR(gst_sp12_autoframe_transform_caps);
    trans_class->fixate_caps = GST_DEBUG_FUNCPTR(gst_sp12_autoframe_fixate_caps);
    trans_class->start = GST_DEBUG_FUNCPTR(gst_sp12_autoframe_start);
    trans_class->stop = GST_DEBUG_FUNCPTR(gst_sp12_autoframe_stop);
    filter_class->set_info = GST_DEBUG_FUNCPTR(gst_sp12_autoframe_set_info);
    filter_class->transform_frame = GST_DEBUG_FUNCPTR(gst_sp12_autoframe_transform_frame);
    filter_class->transform_frame_ip = GST_DEBUG_FUNCPTR(gst_sp12_autoframe_transform_frame_ip);
}

static void gst_sp12_autoframe_init(GstSp12AutoFrame *self) {
    self->enable = TRUE;
    self->device = g_strdup(DEFAULT_DEVICE);
    self->model = g_strdup(DEFAULT_MODEL);
    self->det_width = 320;
    self->det_height = 192;
    self->max_zoom = 2.0;
    self->face_frac = 0.30;
    self->headroom = 0.12;
    self->speed = 4.0;
    self->hold_time = 3.0;
    self->group = TRUE;
    self->detect_interval = 2;
    self->control_file = NULL;
    self->draw_boxes = FALSE;
    self->mode = MODE_CROP;
    self->active_array = g_strdup("3844x2640");
    self->isp_latency = 2;
    self->face_ae = TRUE;
    self->st = new State();
    apply_params(self);
    gst_base_transform_set_passthrough(GST_BASE_TRANSFORM(self), FALSE);
    gst_base_transform_set_in_place(GST_BASE_TRANSFORM(self), TRUE);
}

gboolean gst_sp12_bt601_register(GstPlugin *plugin);   /* gstsp12bt601.cpp */
gboolean gst_sp12_isplock_register(GstPlugin *plugin); /* gstsp12isplock.cpp */

static gboolean plugin_init(GstPlugin *plugin) {
    GST_DEBUG_CATEGORY_INIT(gst_sp12_autoframe_debug, "sp12autoframe", 0, "Surface Pro 12 automatic framing");
    return gst_element_register(plugin, "sp12autoframe", GST_RANK_NONE, GST_TYPE_SP12_AUTOFRAME) &&
           gst_sp12_bt601_register(plugin) && gst_sp12_isplock_register(plugin);
}

#define PACKAGE "sp12-autoframe"
GST_PLUGIN_DEFINE(GST_VERSION_MAJOR, GST_VERSION_MINOR, sp12autoframe, "Surface Pro 12 automatic framing",
                  plugin_init, "0.1", "MIT/X11", "sp12-autoframe", "https://github.com/turbineBMW/surface-pro-12-linux")
