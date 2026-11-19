/*
 * PC stand-in for Hyundai's audio driver, with Hyundai's 19-entry device table (hy_audio.h) and
 * Android 4.4's stream table, for the driver watch tests. It records every call it receives so the
 * test can check that the watch layer forwards each one exactly. FAKE_CORRUPT=1 puts a value that
 * is not a function into one entry, FAKE_DATA_SLOT=1 a pointer to the driver's own data (the watch
 * must then hand the device over untouched). Writes wait as long as the audio lasts, like a real
 * driver.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <hardware/audio.h>
#include <hardware/hardware.h>

#include "hy_audio.h"

#define EXPORT __attribute__((visibility("default")))

EXPORT char fake_calls[65536];
EXPORT float fake_last_float[3];
EXPORT const void *fake_last_ptr[3];
EXPORT unsigned fake_last_u[3];

static void rec(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#include <stdarg.h>
static void rec(const char *fmt, ...) {
    size_t n = strlen(fake_calls);
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(fake_calls + n, sizeof(fake_calls) - n - 2, fmt, ap);
    va_end(ap);
    n = strlen(fake_calls);
    fake_calls[n] = '\n';
    fake_calls[n + 1] = 0;
}

struct fake_out {
    struct audio_stream_out s;
    unsigned rate;
    int secret; /* private fields after the table, like a real driver */
};

static int bad(const void *p) {
    return (uintptr_t)p < 4096;
}

static uint32_t o_get_sample_rate(const struct audio_stream *s) { return ((const struct fake_out *)s)->rate; }
static int o_set_sample_rate(struct audio_stream *s, uint32_t r) { rec("out set_sample_rate %u", r); (void)s; return 0; }
static size_t o_get_buffer_size(const struct audio_stream *s) { (void)s; return 4096; }
static audio_channel_mask_t o_get_channels(const struct audio_stream *s) { (void)s; return AUDIO_CHANNEL_OUT_STEREO; }
static audio_format_t o_get_format(const struct audio_stream *s) { (void)s; return AUDIO_FORMAT_PCM_16_BIT; }
static int o_set_format(struct audio_stream *s, audio_format_t f) { (void)s; rec("out set_format %d", f); return 0; }
static int o_standby(struct audio_stream *s) { (void)s; rec("out standby"); return 0; }
static int o_dump(const struct audio_stream *s, int fd) { (void)s; (void)fd; return 0; }
static audio_devices_t o_get_device(const struct audio_stream *s) { (void)s; return 2; }
static int o_set_device(struct audio_stream *s, audio_devices_t d) { (void)s; rec("out set_device 0x%x", d); return 0; }
static int o_set_parameters(struct audio_stream *s, const char *kv) {
    (void)s;
    if (bad(kv)) return -EINVAL;
    rec("out set_parameters %s", kv);
    return 0;
}
static char *o_get_parameters(const struct audio_stream *s, const char *k) {
    (void)s;
    rec("out get_parameters %s", bad(k) ? "(bad)" : k);
    return strdup("sampling_rate=48000");
}
static int o_add_effect(const struct audio_stream *s, effect_handle_t e) { (void)s; (void)e; return 0; }
static int o_remove_effect(const struct audio_stream *s, effect_handle_t e) { (void)s; (void)e; return 0; }
static uint32_t o_get_latency(const struct audio_stream_out *s) { (void)s; return 85; }
static int o_set_volume(struct audio_stream_out *s, float l, float r) {
    (void)s;
    fake_last_float[1] = l;
    fake_last_float[2] = r;
    rec("out set_volume %.3f %.3f", l, r);
    return 0;
}
static ssize_t o_write(struct audio_stream_out *s, const void *buf, size_t bytes) {
    struct fake_out *o = (struct fake_out *)s;
    fake_last_ptr[2] = buf;
    /* wait as long as the audio lasts (4 bytes a frame) */
    long ns = (long)((double)(bytes / 4) / o->rate * 1e9);
    struct timespec t = {ns / 1000000000L, ns % 1000000000L};
    nanosleep(&t, NULL);
    return (ssize_t)bytes;
}
static int o_get_render_position(const struct audio_stream_out *s, uint32_t *f) { (void)s; *f = 0; return 0; }
static int o_get_next_write_timestamp(const struct audio_stream_out *s, int64_t *t) { (void)s; (void)t; return -ENOSYS; }
static int o_get_presentation_position(const struct audio_stream_out *s, uint64_t *f, struct timespec *t) {
    (void)s; (void)f; (void)t;
    return -ENOSYS;
}

static uint32_t d_get_supported_devices(const struct hy_dev *d) { (void)d; return 0xffff; }
static int d_init_check(const struct hy_dev *d) { (void)d; rec("init_check"); return 0; }
static int d_set_voice_volume(struct hy_dev *d, float v) {
    (void)d;
    fake_last_float[0] = v;
    rec("set_voice_volume %.3f", v);
    return 0;
}
static int d_set_master_volume(struct hy_dev *d, float v) {
    (void)d;
    fake_last_float[0] = v;
    rec("set_master_volume %.3f", v);
    return -ENOSYS;
}
static int d_get_master_volume(struct hy_dev *d, float *v) { (void)d; (void)v; return -ENOSYS; }
static int d_set_mode(struct hy_dev *d, audio_mode_t m) { (void)d; rec("set_mode %d", m); return 0; }
static int d_set_mic_mute(struct hy_dev *d, bool m) { (void)d; rec("set_mic_mute %d", m); return 0; }
static int d_get_mic_mute(const struct hy_dev *d, bool *m) { (void)d; *m = false; return 0; }
static int d_set_parameters(struct hy_dev *d, const char *kv) {
    (void)d;
    if (bad(kv)) {
        rec("set_parameters (bad pointer)");
        return -EINVAL;
    }
    rec("set_parameters %s", kv);
    return 0;
}
static char *d_get_parameters(const struct hy_dev *d, const char *k) {
    (void)d;
    rec("get_parameters %s", bad(k) ? "(bad)" : k);
    return strdup("sampling_rate=44100");
}
static size_t d_get_input_buffer_size(const struct hy_dev *d, const struct audio_config *c) {
    (void)d;
    rec("get_input_buffer_size %u", c->sample_rate);
    return 2048;
}
static int d_open_output_stream(struct hy_dev *d, audio_io_handle_t h, audio_devices_t devs,
                                audio_output_flags_t flags, struct audio_config *c, struct audio_stream_out **out) {
    (void)d;
    fake_last_ptr[0] = c;
    fake_last_ptr[1] = out;
    fake_last_u[0] = (unsigned)h;
    fake_last_u[1] = devs;
    fake_last_u[2] = flags;
    rec("open_output_stream %d 0x%x 0x%x %u", h, devs, flags, c->sample_rate);
    if (getenv("FAKE_REJECT_48K") && c->sample_rate == 48000) {
        c->sample_rate = 44100;
        return -EINVAL;
    }
    struct fake_out *o = calloc(1, sizeof(*o));
    o->rate = c->sample_rate ? c->sample_rate : 44100;
    o->secret = 0x5eC2e7;
    o->s.common.get_sample_rate = o_get_sample_rate;
    o->s.common.set_sample_rate = o_set_sample_rate;
    o->s.common.get_buffer_size = o_get_buffer_size;
    o->s.common.get_channels = o_get_channels;
    o->s.common.get_format = o_get_format;
    o->s.common.set_format = o_set_format;
    o->s.common.standby = o_standby;
    o->s.common.dump = o_dump;
    o->s.common.get_device = o_get_device;
    o->s.common.set_device = o_set_device;
    o->s.common.set_parameters = o_set_parameters;
    o->s.common.get_parameters = o_get_parameters;
    o->s.common.add_audio_effect = o_add_effect;
    o->s.common.remove_audio_effect = o_remove_effect;
    o->s.get_latency = o_get_latency;
    o->s.set_volume = o_set_volume;
    o->s.write = o_write;
    o->s.get_render_position = o_get_render_position;
    o->s.get_next_write_timestamp = o_get_next_write_timestamp;
    o->s.get_presentation_position = o_get_presentation_position;
    *out = &o->s;
    return 0;
}
static void d_close_output_stream(struct hy_dev *d, struct audio_stream_out *s) {
    (void)d;
    rec("close_output_stream secret 0x%x", ((struct fake_out *)s)->secret);
    free(s);
}
static int d_open_input_stream(struct hy_dev *d, audio_io_handle_t h, audio_devices_t devs,
                               struct audio_config *c, struct audio_stream_in **in) {
    (void)d; (void)in;
    rec("open_input_stream %d 0x%x %u", h, devs, c->sample_rate);
    return -ENOSYS;
}
static void d_close_input_stream(struct hy_dev *d, struct audio_stream_in *s) { (void)d; (void)s; }
static int d_dump(const struct hy_dev *d, int fd) { (void)d; (void)fd; return 0; }
static int d_set_master_mute(struct hy_dev *d, bool m) { (void)d; rec("set_master_mute %d", m); return -ENOSYS; }
static int d_get_master_mute(struct hy_dev *d, bool *m) { (void)d; (void)m; return -ENOSYS; }
static int d_hy_extra(struct hy_dev *d, int v) { (void)d; rec("hy_extra %d", v); return 7; }
static int d_close(hw_device_t *d) { free(d); return 0; }

struct fake_dev {
    struct hy_dev dev;
    int secret;
};

EXPORT struct hy_dev *fake_device;

static int d_open(const hw_module_t *mod, const char *name, hw_device_t **device) {
    if (strcmp(name, AUDIO_HARDWARE_INTERFACE) != 0) return -EINVAL;
    struct fake_dev *f = calloc(1, sizeof(*f));
    struct hy_dev *d = &f->dev;
    d->common.tag = HARDWARE_DEVICE_TAG;
    d->common.version = AUDIO_DEVICE_API_VERSION_2_0;
    d->common.module = (struct hw_module_t *)mod;
    d->common.close = d_close;
    d->get_supported_devices = d_get_supported_devices;
    d->init_check = d_init_check;
    d->set_voice_volume = d_set_voice_volume;
    d->set_master_volume = d_set_master_volume;
    d->get_master_volume = d_get_master_volume;
    d->set_mode = d_set_mode;
    d->set_mic_mute = d_set_mic_mute;
    d->hy_extra = d_hy_extra;
    d->get_mic_mute = d_get_mic_mute;
    d->set_parameters = d_set_parameters;
    d->get_parameters = d_get_parameters;
    d->get_input_buffer_size = d_get_input_buffer_size;
    d->open_output_stream = d_open_output_stream;
    d->close_output_stream = d_close_output_stream;
    d->open_input_stream = d_open_input_stream;
    d->close_input_stream = d_close_input_stream;
    d->dump = d_dump;
    d->set_master_mute = d_set_master_mute;
    d->get_master_mute = d_get_master_mute;
    if (getenv("FAKE_CORRUPT")) d->get_master_mute = (int (*)(struct hy_dev *, bool *))(uintptr_t)0x1234;
    if (getenv("FAKE_DATA_SLOT")) d->get_master_mute = (int (*)(struct hy_dev *, bool *))(void *)fake_calls;
    f->secret = 0x7a5;
    fake_device = d;
    *device = &d->common;
    rec("open %s", name);
    return 0;
}

static struct hw_module_methods_t methods = {.open = d_open};

EXPORT struct audio_module HMI = {
    .common =
        {
            .tag = HARDWARE_MODULE_TAG,
            .module_api_version = AUDIO_MODULE_API_VERSION_0_1,
            .hal_api_version = HARDWARE_HAL_API_VERSION,
            .id = AUDIO_HARDWARE_MODULE_ID,
            .name = "fake Telechips audio",
            .author = "test",
            .methods = &methods,
        },
};
