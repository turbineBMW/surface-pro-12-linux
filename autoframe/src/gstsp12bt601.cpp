// sp12bt601: NV12 YCbCr matrix conversion in place, for the camera relays.
//
// The relays feed v4l2loopback, which describes its frames as BT.601 matrix,
// sRGB transfer, BT.709 primaries, limited range (GStreamer 2:4:7:1). icamerasrc
// output is labelled BT.709, so the relay's videoconvert converted every frame:
// 7-21 ms of CPU per 1080p frame (a third of a core) for what is only a change
// of matrix (videoconvert's gamma and primaries modes are "none", so the
// transfer and primaries labels never touch the pixels).
//
// The matrix change is linear, the luma row's Cb/Cr terms do not depend on Y,
// and the chroma rows have no Y term. So per 2x2 block one table lookup on
// (Cb, Cr) gives the new Cb, Cr and a luma offset added to the block's four
// Y values (with a 256-entry table for a range change of Y). Same pixels as
// videoconvert within +-2 code values (it upsamples chroma, this uses the
// block's own), about 1 ms per 1080p frame. The output is labelled with the
// colorimetry property, so a downstream videoconvert to the loopback's
// format passes through.
//
// Pipeline: icamerasrc ! NV12 ! sp12bt601 ! videoconvert ! appsink
// SPDX-License-Identifier: MIT
#include <gst/gst.h>
#include <gst/video/gstvideofilter.h>
#include <gst/video/video.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

GST_DEBUG_CATEGORY_STATIC(gst_sp12_bt601_debug);
#define GST_CAT_DEFAULT gst_sp12_bt601_debug

#define DEFAULT_COLORIMETRY "2:4:7:1"

namespace {
struct Entry {
    int32_t dy; /* luma offset, 1/256 code values */
    uint8_t cb, cr;
};
/* Same luma range (the relays): whole-code-value offset, at most +-40 for
 * these matrices; 256 KB instead of 512 KB keeps the table in L2. */
struct Entry4 {
    int8_t dy;
    uint8_t cb, cr, pad;
};
} // namespace

typedef struct _GstSp12Bt601 {
    GstVideoFilter parent;
    gchar *colorimetry; /* output label */
    bool identity;      /* same matrix and range: relabel only */
    bool same_range;    /* luma range unchanged: ylut is the identity */
    int32_t ylut[256];  /* scaled luma, 1/256 code values */
    std::vector<Entry> *lut;
    std::vector<Entry4> *lut4;
    std::vector<int16_t> *row16; /* per-pixel luma offsets of one chroma row */
    std::vector<int32_t> *row32;
} GstSp12Bt601;

typedef struct _GstSp12Bt601Class {
    GstVideoFilterClass parent_class;
} GstSp12Bt601Class;

enum { PROP_0, PROP_COLORIMETRY };

#define CAPS_STR GST_VIDEO_CAPS_MAKE("NV12")
static GstStaticPadTemplate sink_template =
    GST_STATIC_PAD_TEMPLATE("sink", GST_PAD_SINK, GST_PAD_ALWAYS, GST_STATIC_CAPS(CAPS_STR));
static GstStaticPadTemplate src_template =
    GST_STATIC_PAD_TEMPLATE("src", GST_PAD_SRC, GST_PAD_ALWAYS, GST_STATIC_CAPS(CAPS_STR));

GType gst_sp12_bt601_get_type(void);
G_DEFINE_TYPE(GstSp12Bt601, gst_sp12_bt601, GST_TYPE_VIDEO_FILTER);
#define GST_SP12_BT601(obj) (G_TYPE_CHECK_INSTANCE_CAST((obj), gst_sp12_bt601_get_type(), GstSp12Bt601))

/* GStreamer's colorimetry for unlabelled frames of this size (BT.709 for HD,
 * BT.601 for SD), which is what videoconvert assumed in the relays. */
static gchar *default_colorimetry(const GstStructure *s) {
    gint w = 0, h = 0;
    GstVideoInfo info;
    if (!gst_structure_get_int(s, "width", &w) || !gst_structure_get_int(s, "height", &h)) {
        w = 1920;
        h = 1080;
    }
    gst_video_info_set_format(&info, GST_VIDEO_FORMAT_NV12, w, h);
    return gst_video_colorimetry_to_string(&info.colorimetry);
}

/* Input colorimetries offered upstream, the size's default first. The output
 * label is never offered: the relay's appsrc caps carry it upstream as a
 * query filter, a source that leaves colorimetry open (icamerasrc) would
 * fixate to it, and its BT.709 frames would go through unconverted. */
static void set_input_colorimetries(GstStructure *s) {
    static const char *const known[] = {"bt709", "bt601", "bt2020", "smpte240m"};
    gchar *def = default_colorimetry(s);
    GValue list = G_VALUE_INIT, v = G_VALUE_INIT;
    g_value_init(&list, GST_TYPE_LIST);
    g_value_init(&v, G_TYPE_STRING);
    g_value_set_string(&v, def);
    gst_value_list_append_value(&list, &v);
    for (const char *k : known) {
        GstVideoColorimetry a, b;
        if (gst_video_colorimetry_from_string(&a, k) && gst_video_colorimetry_from_string(&b, def) &&
            gst_video_colorimetry_is_equal(&a, &b))
            continue;
        g_value_set_string(&v, k);
        gst_value_list_append_value(&list, &v);
    }
    gst_structure_take_value(s, "colorimetry", &list);
    g_value_unset(&v);
    g_free(def);
}

/* Downstream gets the configured colorimetry; upstream one of the inputs. */
static GstCaps *gst_sp12_bt601_transform_caps(GstBaseTransform *trans, GstPadDirection direction, GstCaps *caps,
                                              GstCaps *filter) {
    GstSp12Bt601 *self = GST_SP12_BT601(trans);
    GstCaps *out;
    if (direction == GST_PAD_SINK) {
        out = gst_caps_copy(caps);
        GST_OBJECT_LOCK(self);
        for (guint i = 0; i < gst_caps_get_size(out); i++)
            gst_structure_set(gst_caps_get_structure(out, i), "colorimetry", G_TYPE_STRING, self->colorimetry, NULL);
        GST_OBJECT_UNLOCK(self);
    } else {
        out = gst_caps_new_empty();
        for (guint i = 0; i < gst_caps_get_size(caps); i++) {
            GstStructure *s = gst_structure_copy(gst_caps_get_structure(caps, i));
            set_input_colorimetries(s);
            out = gst_caps_merge_structure(out, s);
        }
    }
    if (filter) {
        GstCaps *tmp = gst_caps_intersect_full(filter, out, GST_CAPS_INTERSECT_FIRST);
        gst_caps_unref(out);
        out = tmp;
    }
    return out;
}

/* R'G'B' (0..1) -> (Y, Cb, Cr) with Y in 0..1 and Cb, Cr in -0.5..0.5. */
static void rgb_to_ycbcr(double kr, double kb, double m[3][3]) {
    const double kg = 1.0 - kr - kb;
    const double r[3][3] = {{kr, kg, kb},
                            {-kr / (2 * (1 - kb)), -kg / (2 * (1 - kb)), 0.5},
                            {0.5, -kg / (2 * (1 - kr)), -kb / (2 * (1 - kr))}};
    std::copy(&r[0][0], &r[0][0] + 9, &m[0][0]);
}

static bool invert3(const double a[3][3], double o[3][3]) {
    const double det = a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) -
                       a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) +
                       a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]);
    if (std::fabs(det) < 1e-12) return false;
    o[0][0] = (a[1][1] * a[2][2] - a[1][2] * a[2][1]) / det;
    o[0][1] = (a[0][2] * a[2][1] - a[0][1] * a[2][2]) / det;
    o[0][2] = (a[0][1] * a[1][2] - a[0][2] * a[1][1]) / det;
    o[1][0] = (a[1][2] * a[2][0] - a[1][0] * a[2][2]) / det;
    o[1][1] = (a[0][0] * a[2][2] - a[0][2] * a[2][0]) / det;
    o[1][2] = (a[0][2] * a[1][0] - a[0][0] * a[1][2]) / det;
    o[2][0] = (a[1][0] * a[2][1] - a[1][1] * a[2][0]) / det;
    o[2][1] = (a[0][1] * a[2][0] - a[0][0] * a[2][1]) / det;
    o[2][2] = (a[0][0] * a[1][1] - a[0][1] * a[1][0]) / det;
    return true;
}

static gboolean gst_sp12_bt601_set_info(GstVideoFilter *filter, GstCaps *incaps, GstVideoInfo *in_info,
                                        GstCaps *outcaps, GstVideoInfo *out_info) {
    GstSp12Bt601 *self = GST_SP12_BT601(filter);
    (void)incaps;
    (void)outcaps;
    const GstVideoColorimetry &ci = in_info->colorimetry;
    const GstVideoColorimetry &co = out_info->colorimetry;
    GstVideoFormatInfo const *finfo = in_info->finfo;
    gint oin[4], sin[4], oout[4], sout[4];
    gst_video_color_range_offsets(ci.range, finfo, oin, sin);
    gst_video_color_range_offsets(co.range, finfo, oout, sout);
    gdouble kri, kbi, kro, kbo;
    if (!gst_video_color_matrix_get_Kr_Kb(ci.matrix, &kri, &kbi) ||
        !gst_video_color_matrix_get_Kr_Kb(co.matrix, &kro, &kbo)) {
        GST_ELEMENT_ERROR(self, CORE, NEGOTIATION, (NULL),
                          ("unsupported matrix %d -> %d", (int)ci.matrix, (int)co.matrix));
        return FALSE;
    }
    self->same_range = oin[0] == oout[0] && sin[0] == sout[0];
    self->identity = ci.matrix == co.matrix && self->same_range && sin[1] == sout[1];
    gchar *a = gst_video_colorimetry_to_string(&ci), *b = gst_video_colorimetry_to_string(&co);
    GST_INFO_OBJECT(self, "%s -> %s%s", a, b, self->identity ? " (relabel only)" : "");
    g_free(a);
    g_free(b);
    if (self->identity) return TRUE;

    /* A acts on (Y - oy, Cb - oc, Cr - oc) in code values. */
    double min[3][3], mout[3][3], inv[3][3], m[3][3];
    rgb_to_ycbcr(kri, kbi, min);
    rgb_to_ycbcr(kro, kbo, mout);
    if (!invert3(min, inv)) return FALSE;
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++) {
            m[r][c] = 0;
            for (int k = 0; k < 3; k++) m[r][c] += mout[r][k] * inv[k][c];
        }
    const double si[3] = {(double)sin[0], (double)sin[1], (double)sin[2]};
    const double so[3] = {(double)sout[0], (double)sout[1], (double)sout[2]};
    double A[3][3];
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++) A[r][c] = so[r] * m[r][c] / si[c];

    for (int y = 0; y < 256; y++) self->ylut[y] = (int32_t)std::lround((oout[0] + A[0][0] * (y - oin[0])) * 256.0);
    self->lut->resize(65536);
    for (int u = 0; u < 256; u++)
        for (int v = 0; v < 256; v++) {
            const double cb = u - oin[1], cr = v - oin[2];
            Entry &e = (*self->lut)[(u << 8) | v];
            e.dy = (int32_t)std::lround((A[0][1] * cb + A[0][2] * cr) * 256.0);
            e.cb = (uint8_t)std::clamp(std::lround(oout[1] + A[1][1] * cb + A[1][2] * cr), 0L, 255L);
            e.cr = (uint8_t)std::clamp(std::lround(oout[2] + A[2][1] * cb + A[2][2] * cr), 0L, 255L);
        }
    if (self->same_range) {
        self->lut4->resize(65536);
        for (int k = 0; k < 65536; k++) {
            const Entry &e = (*self->lut)[k];
            const int dy = (e.dy + 128) >> 8;
            if (dy < -128 || dy > 127) {
                self->same_range = false; /* fall back to the 32-bit path */
                break;
            }
            (*self->lut4)[k] = {(int8_t)dy, e.cb, e.cr, 0};
        }
    }
    return TRUE;
}

static inline uint8_t clamp8(int32_t v256) {
    const int32_t v = (v256 + 128) >> 8;
    return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
}

/* Luma row pass. With the range unchanged (the relays) the table is the
 * identity and the offsets are whole code values: a saturating add the
 * compiler vectorises. */
static void luma_row_same_range(uint8_t *__restrict y, const int16_t *__restrict d, int w) {
    for (int x = 0; x < w; x++) {
        const int v = y[x] + d[x];
        y[x] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
    }
}

static void luma_row_scaled(uint8_t *__restrict y, const int32_t *__restrict d256, const int32_t *yl, int w) {
    for (int x = 0; x < w; x++) y[x] = clamp8(yl[y[x]] + d256[x]);
}

static GstFlowReturn gst_sp12_bt601_transform_frame_ip(GstVideoFilter *filter, GstVideoFrame *frame) {
    GstSp12Bt601 *self = GST_SP12_BT601(filter);
    if (self->identity) return GST_FLOW_OK;
    const int w = GST_VIDEO_FRAME_WIDTH(frame), h = GST_VIDEO_FRAME_HEIGHT(frame);
    uint8_t *yp = (uint8_t *)GST_VIDEO_FRAME_PLANE_DATA(frame, 0);
    uint8_t *uvp = (uint8_t *)GST_VIDEO_FRAME_PLANE_DATA(frame, 1);
    const int ys = GST_VIDEO_FRAME_PLANE_STRIDE(frame, 0), uvs = GST_VIDEO_FRAME_PLANE_STRIDE(frame, 1);
    const Entry *lut = self->lut->data();
    const Entry4 *lut4 = self->lut4->data();
    const int32_t *yl = self->ylut;
    const bool same_range = self->same_range;
    const int cw = (w + 1) / 2, ch = (h + 1) / 2;
    /* Per chroma row: new Cb/Cr in place and each pixel's luma offset (the
     * block's, repeated), then both luma rows of the block. */
    std::vector<int16_t> &d16 = *self->row16;
    std::vector<int32_t> &d32 = *self->row32;
    d16.resize(2 * cw);
    d32.resize(2 * cw);
    for (int j = 0; j < ch; j++) {
        uint8_t *uv = uvp + (size_t)j * uvs;
        if (same_range) {
            for (int i = 0; i < cw; i++) {
                const Entry4 e = lut4[(uv[2 * i] << 8) | uv[2 * i + 1]];
                uv[2 * i] = e.cb;
                uv[2 * i + 1] = e.cr;
                d16[2 * i] = d16[2 * i + 1] = e.dy;
            }
        } else {
            for (int i = 0; i < cw; i++) {
                const Entry e = lut[(uv[2 * i] << 8) | uv[2 * i + 1]];
                uv[2 * i] = e.cb;
                uv[2 * i + 1] = e.cr;
                d32[2 * i] = d32[2 * i + 1] = e.dy;
            }
        }
        for (int r = 2 * j; r < std::min(2 * j + 2, h); r++) {
            uint8_t *y = yp + (size_t)r * ys;
            if (same_range)
                luma_row_same_range(y, d16.data(), w);
            else
                luma_row_scaled(y, d32.data(), yl, w);
        }
    }
    return GST_FLOW_OK;
}

static void gst_sp12_bt601_set_property(GObject *object, guint prop_id, const GValue *value, GParamSpec *pspec) {
    GstSp12Bt601 *self = GST_SP12_BT601(object);
    switch (prop_id) {
    case PROP_COLORIMETRY: {
        GstVideoColorimetry c;
        const gchar *s = g_value_get_string(value);
        if (!s || !gst_video_colorimetry_from_string(&c, s)) {
            GST_WARNING_OBJECT(self, "invalid colorimetry '%s', keeping %s", s ? s : "(null)", self->colorimetry);
            break;
        }
        GST_OBJECT_LOCK(self);
        g_free(self->colorimetry);
        self->colorimetry = g_strdup(s);
        GST_OBJECT_UNLOCK(self);
        gst_base_transform_reconfigure_src(GST_BASE_TRANSFORM(self));
        break;
    }
    default:
        G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec);
    }
}

static void gst_sp12_bt601_get_property(GObject *object, guint prop_id, GValue *value, GParamSpec *pspec) {
    GstSp12Bt601 *self = GST_SP12_BT601(object);
    switch (prop_id) {
    case PROP_COLORIMETRY:
        GST_OBJECT_LOCK(self);
        g_value_set_string(value, self->colorimetry);
        GST_OBJECT_UNLOCK(self);
        break;
    default:
        G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec);
    }
}

static void gst_sp12_bt601_finalize(GObject *object) {
    GstSp12Bt601 *self = GST_SP12_BT601(object);
    g_free(self->colorimetry);
    delete self->lut;
    delete self->lut4;
    delete self->row16;
    delete self->row32;
    G_OBJECT_CLASS(gst_sp12_bt601_parent_class)->finalize(object);
}

static void gst_sp12_bt601_class_init(GstSp12Bt601Class *klass) {
    GObjectClass *gobject_class = G_OBJECT_CLASS(klass);
    GstElementClass *element_class = GST_ELEMENT_CLASS(klass);
    GstBaseTransformClass *trans_class = GST_BASE_TRANSFORM_CLASS(klass);
    GstVideoFilterClass *filter_class = GST_VIDEO_FILTER_CLASS(klass);

    gobject_class->set_property = gst_sp12_bt601_set_property;
    gobject_class->get_property = gst_sp12_bt601_get_property;
    gobject_class->finalize = gst_sp12_bt601_finalize;

    g_object_class_install_property(
        gobject_class, PROP_COLORIMETRY,
        g_param_spec_string("colorimetry", "Colorimetry",
                            "Output colorimetry (GStreamer string). The matrix and range are converted; the transfer "
                            "and primaries are only labels, as with videoconvert's default gamma and primaries modes. "
                            "The default is v4l2loopback's: BT.601 matrix, sRGB transfer, BT.709 primaries, limited "
                            "range",
                            DEFAULT_COLORIMETRY, (GParamFlags)(G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS)));

    gst_element_class_set_static_metadata(element_class, "Surface Pro 12 NV12 matrix conversion",
                                          "Filter/Converter/Video",
                                          "Converts NV12 between YCbCr matrices in place with a lookup table",
                                          "surface-pro-12-linux");
    gst_element_class_add_static_pad_template(element_class, &sink_template);
    gst_element_class_add_static_pad_template(element_class, &src_template);

    trans_class->transform_caps = GST_DEBUG_FUNCPTR(gst_sp12_bt601_transform_caps);
    trans_class->passthrough_on_same_caps = FALSE;
    filter_class->set_info = GST_DEBUG_FUNCPTR(gst_sp12_bt601_set_info);
    filter_class->transform_frame_ip = GST_DEBUG_FUNCPTR(gst_sp12_bt601_transform_frame_ip);
}

static void gst_sp12_bt601_init(GstSp12Bt601 *self) {
    self->colorimetry = g_strdup(DEFAULT_COLORIMETRY);
    self->identity = false;
    self->same_range = true;
    self->lut = new std::vector<Entry>();
    self->lut4 = new std::vector<Entry4>();
    self->row16 = new std::vector<int16_t>();
    self->row32 = new std::vector<int32_t>();
    gst_base_transform_set_in_place(GST_BASE_TRANSFORM(self), TRUE);
}

gboolean gst_sp12_bt601_register(GstPlugin *plugin) {
    GST_DEBUG_CATEGORY_INIT(gst_sp12_bt601_debug, "sp12bt601", 0, "Surface Pro 12 NV12 matrix conversion");
    return gst_element_register(plugin, "sp12bt601", GST_RANK_NONE, gst_sp12_bt601_get_type());
}
