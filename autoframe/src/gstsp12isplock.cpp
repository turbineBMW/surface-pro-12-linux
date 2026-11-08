// sp12isplock: one camera at a time through the IPU7 hardware ISP.
//
// Streaming the front and rear cameras through the ISP at the same time
// wedges the IPU firmware (2026-11-06: PSYS "group 3, code 1" errors, then
// "wait running fw tasks clear timeout"; or ISYS STREAM_CAPTURE_ACK errors,
// then "fw not ready for shutdown, state 0xdead0001" and the ISYS runtime PM
// in error, which only a reboot clears). Front alone: 10/10 start/stop
// sessions clean; with the rear streaming: failure after 7.
//
// Placed right after icamerasrc in each relay's pipeline. A bin changes its
// children's state from the sinks towards the sources, so this element goes
// NULL -> READY before icamerasrc goes READY -> PAUSED (camera_device_open),
// and READY -> NULL after icamerasrc's PAUSED -> READY (camera_device_close).
// It takes an exclusive flock on the lock file in the first and drops it in
// the second, so a second camera waits until the first one is fully closed:
// a camera switch in an app waits for the old camera, and two apps on both
// cameras get one picture, not a wedged ISP. Data passes through untouched.
//
// Pipeline: icamerasrc ! caps ! sp12isplock ! ...
// SPDX-License-Identifier: MIT
#include <gst/base/gstbasetransform.h>
#include <gst/gst.h>

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

GST_DEBUG_CATEGORY_STATIC(gst_sp12_isplock_debug);
#define GST_CAT_DEFAULT gst_sp12_isplock_debug

#define DEFAULT_LOCK_FILE "/run/sp12/isp.lock"
#define DEFAULT_TIMEOUT 0 /* seconds, 0 = wait as long as it takes */

typedef struct _GstSp12IspLock {
    GstBaseTransform parent;
    gchar *lock_file;
    guint timeout;
    int fd;
} GstSp12IspLock;

typedef struct _GstSp12IspLockClass {
    GstBaseTransformClass parent_class;
} GstSp12IspLockClass;

enum { PROP_0, PROP_LOCK_FILE, PROP_TIMEOUT };

static GstStaticPadTemplate sink_template =
    GST_STATIC_PAD_TEMPLATE("sink", GST_PAD_SINK, GST_PAD_ALWAYS, GST_STATIC_CAPS_ANY);
static GstStaticPadTemplate src_template =
    GST_STATIC_PAD_TEMPLATE("src", GST_PAD_SRC, GST_PAD_ALWAYS, GST_STATIC_CAPS_ANY);

GType gst_sp12_isplock_get_type(void);
G_DEFINE_TYPE(GstSp12IspLock, gst_sp12_isplock, GST_TYPE_BASE_TRANSFORM);
#define GST_SP12_ISPLOCK(obj) (G_TYPE_CHECK_INSTANCE_CAST((obj), gst_sp12_isplock_get_type(), GstSp12IspLock))

static bool acquire(GstSp12IspLock *self) {
    GST_OBJECT_LOCK(self);
    gchar *path = g_strdup(self->lock_file);
    const guint timeout = self->timeout;
    GST_OBJECT_UNLOCK(self);

    self->fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0666);
    if (self->fd < 0) {
        GST_ELEMENT_ERROR(self, RESOURCE, OPEN_READ_WRITE, (NULL), ("open %s: %s", path, strerror(errno)));
        g_free(path);
        return false;
    }
    const gint64 start = g_get_monotonic_time();
    bool waited = false, held = false;
    while (!(held = flock(self->fd, LOCK_EX | LOCK_NB) == 0)) {
        if (errno != EWOULDBLOCK && errno != EINTR) {
            GST_ELEMENT_ERROR(self, RESOURCE, BUSY, (NULL), ("flock %s: %s", path, strerror(errno)));
            break;
        }
        if (!waited) {
            GST_WARNING_OBJECT(self, "the other camera is using the ISP, waiting for %s", path);
            g_printerr("sp12isplock: the other camera is using the ISP, waiting\n");
            waited = true;
        }
        if (timeout && g_get_monotonic_time() - start > (gint64)timeout * G_USEC_PER_SEC) {
            GST_ELEMENT_ERROR(self, RESOURCE, BUSY, ("The other camera is in use."),
                              ("%s still locked after %u s", path, timeout));
            break;
        }
        g_usleep(50 * 1000);
    }
    if (held) {
        if (waited)
            g_printerr("sp12isplock: ISP free after %.1f s\n", (g_get_monotonic_time() - start) / 1e6);
        GST_INFO_OBJECT(self, "holding %s", path);
        g_free(path);
        return true;
    }
    close(self->fd);
    self->fd = -1;
    g_free(path);
    return false;
}

static void release(GstSp12IspLock *self) {
    if (self->fd < 0) return;
    flock(self->fd, LOCK_UN);
    close(self->fd);
    self->fd = -1;
    GST_INFO_OBJECT(self, "released the ISP lock");
}

static GstStateChangeReturn gst_sp12_isplock_change_state(GstElement *element, GstStateChange transition) {
    GstSp12IspLock *self = GST_SP12_ISPLOCK(element);
    if (transition == GST_STATE_CHANGE_NULL_TO_READY && !acquire(self)) return GST_STATE_CHANGE_FAILURE;
    GstStateChangeReturn ret = GST_ELEMENT_CLASS(gst_sp12_isplock_parent_class)->change_state(element, transition);
    /* Released after the whole pipeline left PAUSED (icamerasrc closed the
     * camera), or if taking it was this element's own failed transition. */
    if (transition == GST_STATE_CHANGE_READY_TO_NULL ||
        (transition == GST_STATE_CHANGE_NULL_TO_READY && ret == GST_STATE_CHANGE_FAILURE))
        release(self);
    return ret;
}

static void gst_sp12_isplock_set_property(GObject *object, guint prop_id, const GValue *value, GParamSpec *pspec) {
    GstSp12IspLock *self = GST_SP12_ISPLOCK(object);
    GST_OBJECT_LOCK(self);
    switch (prop_id) {
    case PROP_LOCK_FILE:
        g_free(self->lock_file);
        self->lock_file = g_value_dup_string(value);
        break;
    case PROP_TIMEOUT:
        self->timeout = g_value_get_uint(value);
        break;
    default:
        G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec);
    }
    GST_OBJECT_UNLOCK(self);
}

static void gst_sp12_isplock_get_property(GObject *object, guint prop_id, GValue *value, GParamSpec *pspec) {
    GstSp12IspLock *self = GST_SP12_ISPLOCK(object);
    GST_OBJECT_LOCK(self);
    switch (prop_id) {
    case PROP_LOCK_FILE:
        g_value_set_string(value, self->lock_file);
        break;
    case PROP_TIMEOUT:
        g_value_set_uint(value, self->timeout);
        break;
    default:
        G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec);
    }
    GST_OBJECT_UNLOCK(self);
}

static void gst_sp12_isplock_finalize(GObject *object) {
    GstSp12IspLock *self = GST_SP12_ISPLOCK(object);
    release(self);
    g_free(self->lock_file);
    G_OBJECT_CLASS(gst_sp12_isplock_parent_class)->finalize(object);
}

static void gst_sp12_isplock_class_init(GstSp12IspLockClass *klass) {
    GObjectClass *gobject_class = G_OBJECT_CLASS(klass);
    GstElementClass *element_class = GST_ELEMENT_CLASS(klass);

    gobject_class->set_property = gst_sp12_isplock_set_property;
    gobject_class->get_property = gst_sp12_isplock_get_property;
    gobject_class->finalize = gst_sp12_isplock_finalize;
    g_object_class_install_property(
        gobject_class, PROP_LOCK_FILE,
        g_param_spec_string("lock-file", "Lock file", "File locked (flock) while the camera upstream is open",
                            DEFAULT_LOCK_FILE, (GParamFlags)(G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS)));
    g_object_class_install_property(
        gobject_class, PROP_TIMEOUT,
        g_param_spec_uint("timeout", "Timeout", "Seconds to wait for the lock before failing (0: no limit)", 0,
                          G_MAXUINT, DEFAULT_TIMEOUT, (GParamFlags)(G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS)));

    gst_element_class_set_static_metadata(element_class, "Surface Pro 12 ISP lock", "Generic",
                                          "Holds a lock while the camera upstream is open, so only one camera "
                                          "streams through the hardware ISP",
                                          "surface-pro-12-linux");
    gst_element_class_add_static_pad_template(element_class, &sink_template);
    gst_element_class_add_static_pad_template(element_class, &src_template);
    element_class->change_state = GST_DEBUG_FUNCPTR(gst_sp12_isplock_change_state);
}

static void gst_sp12_isplock_init(GstSp12IspLock *self) {
    self->lock_file = g_strdup(DEFAULT_LOCK_FILE);
    self->timeout = DEFAULT_TIMEOUT;
    self->fd = -1;
    gst_base_transform_set_passthrough(GST_BASE_TRANSFORM(self), TRUE);
}

gboolean gst_sp12_isplock_register(GstPlugin *plugin) {
    GST_DEBUG_CATEGORY_INIT(gst_sp12_isplock_debug, "sp12isplock", 0, "Surface Pro 12 ISP lock");
    return gst_element_register(plugin, "sp12isplock", GST_RANK_NONE, gst_sp12_isplock_get_type());
}
