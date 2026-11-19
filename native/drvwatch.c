/*
 * EQ Engine driver watch (Lab test): a pass-through layer in front of Hyundai's audio driver.
 *
 * Put in place only from the Lab page (an in-memory bind mount over
 * /system/lib/hw/audio.primary.tcc803x.so, gone at the next car start or when switched off),
 * it loads Hyundai's driver from an unchanged copy (DRV_ORIG), hands every call on to it and
 * writes down what Android asks of the driver: output and input stream set-ups, parameter
 * strings, modes and volumes, and every DRV_WINDOW_MS what reaches each output stream (frames
 * per second as the driver takes them, how long each write waits, levels). It changes nothing
 * in the audio.
 *
 * Safety:
 *  - Hooks are installed in place, in Hyundai's own device and stream tables, so any field this
 *    layer does not know about stays exactly as Hyundai's driver set it.
 *  - Before hooking, the tables are checked: tag, version 2.0, every function slot empty or
 *    inside Hyundai's driver. If anything looks unfamiliar, the device (or that stream) is
 *    handed to Android untouched: "pass-through only".
 *  - Every forwarder passes eight words on, so a call arrives at Hyundai's function exactly as
 *    Android made it, even if a slot were not what the Android 4.4 headers say. (On this car's
 *    ARM build, float arguments travel in core registers too.)
 *  - Every pointer the logger reads (parameter strings, configs) is read through a pipe, so a
 *    bad pointer gives an error instead of a crash. Audio buffers are checked that way on the
 *    first writes of each stream before their levels are measured.
 *  - Hyundai's driver also exports helper functions (set_FM1288_*, runBypassThread, ...). This
 *    layer exports the same names and forwards them (drvwatch_tramp.S), in case anything looks
 *    them up through the driver's file name.
 */
#define _GNU_SOURCE /* Dl_info on PC test builds; bionic has it anyway */
#include <stddef.h>
#include <sys/types.h>
#include <time.h>

#include <hardware/hardware.h>
#include <hardware/audio.h>

#include <android/log.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifndef DRV_ORIG
#define DRV_ORIG "/data/eqengine/lib/hal/eqe_hal_orig.so"
#endif
#ifndef DRV_DIR
#define DRV_DIR "/data/eqengine/drv"
#endif
#ifndef DRV_WINDOW_MS
#define DRV_WINDOW_MS 30000
#endif
#define DRV_VERSION 1
#define LOG_CAP (512 * 1024)
#define EXPORT __attribute__((visibility("default")))

typedef uintptr_t W;
typedef W (*fn8)(W, W, W, W, W, W, W, W);
/* a forwarder in a slot of another function type (through void (*)(void) to say it is meant) */
#define AS(type, f) ((type)(void (*)(void))(f))

/* ------------------------------------------------------------------ safe reads */

static int g_pipe[2] = {-1, -1};
static pthread_mutex_t g_peek_lock = PTHREAD_MUTEX_INITIALIZER;

static void pipe_init(void) {
    if (g_pipe[0] >= 0) return;
    int p[2];
    if (pipe(p) != 0) return;
    fcntl(p[0], F_SETFL, O_NONBLOCK);
    fcntl(p[1], F_SETFL, O_NONBLOCK);
    fcntl(p[0], F_SETFD, FD_CLOEXEC);
    fcntl(p[1], F_SETFD, FD_CLOEXEC);
    g_pipe[0] = p[0];
    g_pipe[1] = p[1];
}

/* Copies n (<= 4096) bytes from src without faulting on a bad address. 0 = done. */
static int peek(void *dst, const void *src, size_t n) {
    if (src == NULL || n == 0 || n > 4096) return -1;
    int ok = -1;
    pthread_mutex_lock(&g_peek_lock);
    if (g_pipe[0] >= 0) {
        ssize_t w = write(g_pipe[1], src, n);
        if (w > 0) {
            ssize_t r = read(g_pipe[0], dst, (size_t)w);
            ok = (w == (ssize_t)n && r == w) ? 0 : -1;
        }
    }
    pthread_mutex_unlock(&g_peek_lock);
    return ok;
}

/* Copies a string (at most cap - 1 characters) in aligned chunks, which never cross a page, so
 * the copy may read up to PEEK_CHUNK - 1 bytes past the end of the string but never into a page
 * the string does not touch. 0 = complete, 1 = cut, -1 = unreadable. */
#if defined(__SANITIZE_ADDRESS__)
#define PEEK_CHUNK 1 /* PC test builds: the sanitizer counts reads past the end */
#else
#define PEEK_CHUNK 32
#endif
static int peek_str(char *dst, size_t cap, const char *src) {
    size_t got = 0;
    if (src == NULL) {
        snprintf(dst, cap, "(null)");
        return -1;
    }
    while (got + 1 < cap) {
        uintptr_t a = (uintptr_t)src + got;
        size_t n = PEEK_CHUNK - (a % PEEK_CHUNK);
        if (n > cap - 1 - got) n = cap - 1 - got;
        if (peek(dst + got, src + got, n) != 0) {
            if (got == 0) {
                snprintf(dst, cap, "(unreadable %p)", (const void *)src);
                return -1;
            }
            break;
        }
        if (memchr(dst + got, 0, n) != NULL) return 0;
        got += n;
    }
    dst[got] = 0;
    return 1;
}

/* ------------------------------------------------------------------ log queue
 *
 * wlog() only copies the line into a queue; a low-priority thread writes the file, logcat and
 * the status file, so no file work ever happens on the audio threads. */

#define QLEN 128
#define QLINE 600
static struct {
    struct timespec when;
    char text[QLINE];
    int logcat;
} g_q_line[QLEN];
static unsigned g_q_head, g_q_tail, g_q_dropped;
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_log_cond = PTHREAD_COND_INITIALIZER;
static int g_status_dirty, g_logger_started;
static int g_log_fd = -1;

static int64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static void wlog(int to_logcat, const char *fmt, ...) {
    pthread_mutex_lock(&g_log_lock);
    if (g_q_head - g_q_tail >= QLEN) {
        g_q_dropped++;
    } else {
        unsigned i = g_q_head % QLEN;
        clock_gettime(CLOCK_REALTIME, &g_q_line[i].when);
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(g_q_line[i].text, QLINE, fmt, ap);
        va_end(ap);
        g_q_line[i].logcat = to_logcat;
        g_q_head++;
    }
    pthread_cond_signal(&g_log_cond);
    pthread_mutex_unlock(&g_log_lock);
}

static void write_status_now(void);

static void file_line(const struct timespec *when, const char *text) {
    char line[QLINE + 64];
    struct tm tm;
    time_t s = when->tv_sec;
    localtime_r(&s, &tm);
    int n = snprintf(line, sizeof(line), "%04d-%02d-%02d %02d:%02d:%02d.%03ld %s\n", tm.tm_year + 1900, tm.tm_mon + 1,
                     tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec, when->tv_nsec / 1000000, text);
    if (n <= 0) return;
    if (n > (int)sizeof(line) - 1) n = (int)sizeof(line) - 1;
    if (g_log_fd >= 0) {
        struct stat st;
        if (fstat(g_log_fd, &st) == 0 && st.st_size > LOG_CAP) {
            close(g_log_fd);
            g_log_fd = -1;
            rename(DRV_DIR "/drv.log", DRV_DIR "/drv.log.1");
        }
    }
    if (g_log_fd < 0) {
        g_log_fd = open(DRV_DIR "/drv.log", O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
        if (g_log_fd >= 0) fchmod(g_log_fd, 0644);
    }
    if (g_log_fd >= 0) {
        ssize_t w = write(g_log_fd, line, (size_t)n);
        (void)w;
    }
}

static void *logger_main(void *arg) {
    (void)arg;
    setpriority(PRIO_PROCESS, 0, 10); /* below normal; the audio threads never wait for it */
    for (;;) {
        char text[QLINE];
        struct timespec when;
        int lc = 0, have = 0, status = 0;
        unsigned dropped = 0;
        pthread_mutex_lock(&g_log_lock);
        while (g_q_head == g_q_tail && !g_status_dirty) {
            struct timespec t;
            clock_gettime(CLOCK_REALTIME, &t);
            t.tv_sec += 5;
            pthread_cond_timedwait(&g_log_cond, &g_log_lock, &t);
        }
        if (g_q_head != g_q_tail) {
            unsigned i = g_q_tail % QLEN;
            memcpy(text, g_q_line[i].text, QLINE);
            when = g_q_line[i].when;
            lc = g_q_line[i].logcat;
            g_q_tail++;
            have = 1;
        } else {
            status = g_status_dirty;
            g_status_dirty = 0;
        }
        dropped = g_q_dropped;
        g_q_dropped = 0;
        pthread_mutex_unlock(&g_log_lock);
        if (dropped) {
            char d[64];
            struct timespec t;
            clock_gettime(CLOCK_REALTIME, &t);
            snprintf(d, sizeof(d), "(%u lines dropped: too many at once)", dropped);
            file_line(&t, d);
        }
        if (have) {
            text[QLINE - 1] = 0;
            file_line(&when, text);
            if (lc) __android_log_print(ANDROID_LOG_INFO, "EQEDrv", "%s", text);
        }
        if (status) write_status_now();
    }
    return NULL;
}

static void logger_start(void) {
    if (g_logger_started) return;
    g_logger_started = 1;
    pthread_t t;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&at, 64 * 1024);
    if (pthread_create(&t, &at, logger_main, NULL) != 0) g_logger_started = 0;
    pthread_attr_destroy(&at);
}

/* the status file is rewritten by the logger thread */
static void write_status(void) {
    pthread_mutex_lock(&g_log_lock);
    g_status_dirty = 1;
    pthread_cond_signal(&g_log_cond);
    pthread_mutex_unlock(&g_log_lock);
}

/* ------------------------------------------------------------------ Hyundai's driver */

static void *g_orig_so;
static struct hw_module_t *g_orig_mod;
static uintptr_t g_orig_base;
static pthread_once_t g_orig_once = PTHREAD_ONCE_INIT;
static const char *g_state = "starting";
static char g_reason[240] = "";

/* drvwatch_tramp.S: forwarders for the driver's exported helper functions */
extern int drvwatch_tramp_resolve(void *so);
extern int drvwatch_tramp_count;

static void orig_load(void) {
    pipe_init();
    logger_start();
    g_orig_so = dlopen(DRV_ORIG, RTLD_NOW);
    if (g_orig_so == NULL) {
        const char *e = dlerror();
        snprintf(g_reason, sizeof(g_reason), "Hyundai's driver copy did not load: %s", e ? e : "?");
        g_state = "error";
        wlog(1, "%s", g_reason);
        return;
    }
    g_orig_mod = (struct hw_module_t *)dlsym(g_orig_so, HAL_MODULE_INFO_SYM_AS_STR);
    if (g_orig_mod == NULL) {
        snprintf(g_reason, sizeof(g_reason), "Hyundai's driver copy has no %s", HAL_MODULE_INFO_SYM_AS_STR);
        g_state = "error";
        wlog(1, "%s", g_reason);
        return;
    }
    Dl_info di;
    if (dladdr(g_orig_mod, &di) != 0) g_orig_base = (uintptr_t)di.dli_fbase;
    g_orig_mod->dso = g_orig_so;
    int found = drvwatch_tramp_resolve(g_orig_so);
    wlog(0, "Hyundai's driver copy loaded at %p; %d of its %d helper functions forwarded", (void *)g_orig_base, found,
         drvwatch_tramp_count);
}

/* inside Hyundai's driver (or empty) */
static int in_orig(const void *p) {
    if (p == NULL) return 1;
    Dl_info di;
    if (g_orig_base == 0 || dladdr(p, &di) == 0) return 0;
    return (uintptr_t)di.dli_fbase == g_orig_base;
}

/* ------------------------------------------------------------------ status file */

#define MAX_OUT 12

typedef struct {
    struct audio_stream_out *s; /* NULL = free slot */
    int handle;
    unsigned devices, flags, rate, mask, format, frame_bytes, buffer_bytes, latency_ms;
    int hooked, stats_ok, checked;
    /* Hyundai's originals */
    W o_write, o_standby, o_set_params, o_get_params, o_set_rate, o_set_format, o_set_device, o_set_volume;
    /* stats for the current window */
    int64_t win_start, last_end;
    uint64_t win_frames, win_writes;
    int64_t win_wait_sum, win_wait_max;
    int peak;
    double sumsq;
    uint64_t nsamples, fullscale;
    /* last finished window, for the status file */
    double last_fps, last_peak_db, last_rms_db, last_wait_avg_ms, last_wait_max_ms;
    uint64_t last_fullscale, total_frames;
    float vol_l, vol_r;
} out_rec;

static out_rec g_out[MAX_OUT];
static pthread_mutex_t g_out_lock = PTHREAD_MUTEX_INITIALIZER;
static struct audio_hw_device *g_dev;
static int g_dev_hooked;
static int g_mode = -1;

static void write_status_now(void) {
    char buf[3000];
    int n = snprintf(buf, sizeof(buf), "version=%d\nstate=%s\nreason=%s\nmode=%d\n", DRV_VERSION, g_state, g_reason, g_mode);
    for (int i = 0; i < MAX_OUT && n < (int)sizeof(buf) - 300; i++) {
        out_rec *r = &g_out[i];
        if (r->s == NULL) continue;
        n += snprintf(buf + n, sizeof(buf) - (size_t)n,
                      "out=%d rate=%u mask=0x%x format=0x%x devices=0x%x flags=0x%x hooked=%d fps=%.0f peak_db=%.1f "
                      "rms_db=%.1f fullscale=%llu wait_avg_ms=%.2f wait_max_ms=%.2f frames=%llu buffer=%u latency_ms=%u\n",
                      r->handle, r->rate, r->mask, r->format, r->devices, r->flags, r->hooked, r->last_fps,
                      r->last_peak_db, r->last_rms_db, (unsigned long long)r->last_fullscale, r->last_wait_avg_ms,
                      r->last_wait_max_ms, (unsigned long long)r->total_frames, r->buffer_bytes, r->latency_ms);
    }
    int fd = open(DRV_DIR "/status.tmp", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    ssize_t w = write(fd, buf, (size_t)n);
    (void)w;
    fchmod(fd, 0644);
    close(fd);
    rename(DRV_DIR "/status.tmp", DRV_DIR "/status");
}

/* ------------------------------------------------------------------ device forwarders */

static struct {
    W init_check, set_voice_volume, set_master_volume, set_mode, set_mic_mute, set_parameters, get_parameters,
        get_input_buffer_size, open_output_stream, close_output_stream, open_input_stream, close_input_stream,
        set_master_mute;
} g_o;

#define FWD(f) ((fn8)(f))(a0, a1, a2, a3, a4, a5, a6, a7)
#define ARGS8 W a0, W a1, W a2, W a3, W a4, W a5, W a6, W a7

static int is_dev(W d) {
    return d == (W)g_dev;
}

static W w_init_check(ARGS8) {
    W r = FWD(g_o.init_check);
    wlog(1, "device init_check -> %d", (int)r);
    return r;
}

static W w_set_mode(ARGS8) {
    W r = FWD(g_o.set_mode);
    if (is_dev(a0)) g_mode = (int)a1;
    wlog(1, "device set_mode %d -> %d", (int)a1, (int)r);
    write_status();
    return r;
}

static W w_set_mic_mute(ARGS8) {
    W r = FWD(g_o.set_mic_mute);
    wlog(0, "device set_mic_mute %d -> %d", (int)(a1 & 0xff), (int)r);
    return r;
}

static W w_set_master_mute(ARGS8) {
    W r = FWD(g_o.set_master_mute);
    wlog(1, "device set_master_mute %d -> %d", (int)(a1 & 0xff), (int)r);
    return r;
}

#if defined(__arm__)
/* softfp: the float is in r1 as raw bits */
static float word_float(W w) {
    float f;
    uint32_t u = (uint32_t)w;
    memcpy(&f, &u, sizeof(f));
    return f;
}
static W w_set_voice_volume(ARGS8) {
    W r = FWD(g_o.set_voice_volume);
    wlog(0, "device set_voice_volume %.3f -> %d", word_float(a1), (int)r);
    return r;
}
static W w_set_master_volume(ARGS8) {
    W r = FWD(g_o.set_master_volume);
    wlog(1, "device set_master_volume %.3f -> %d", word_float(a1), (int)r);
    return r;
}
#else
/* PC test builds: floats travel in their own registers, so these keep the exact types */
static int w_set_voice_volume(struct audio_hw_device *d, float v) {
    int r = ((int (*)(struct audio_hw_device *, float))g_o.set_voice_volume)(d, v);
    wlog(0, "device set_voice_volume %.3f -> %d", v, r);
    return r;
}
static int w_set_master_volume(struct audio_hw_device *d, float v) {
    int r = ((int (*)(struct audio_hw_device *, float))g_o.set_master_volume)(d, v);
    wlog(1, "device set_master_volume %.3f -> %d", v, r);
    return r;
}
#endif

/* the same parameter line over and over is written once, then counted */
static pthread_mutex_t g_rep_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_rep_line[700];
static unsigned g_rep_count;
static int64_t g_rep_since;

static void log_param(const char *line) {
    int64_t t = now_ns();
    pthread_mutex_lock(&g_rep_lock);
    if (strcmp(line, g_rep_line) == 0 && t - g_rep_since < 60000000000LL) {
        g_rep_count++;
        pthread_mutex_unlock(&g_rep_lock);
        return;
    }
    unsigned n = g_rep_count;
    char prev[sizeof(g_rep_line)];
    memcpy(prev, g_rep_line, sizeof(prev));
    snprintf(g_rep_line, sizeof(g_rep_line), "%s", line);
    g_rep_count = 0;
    g_rep_since = t;
    pthread_mutex_unlock(&g_rep_lock);
    if (n) wlog(0, "(the line before, %s, came %u more times)", prev, n);
    wlog(1, "%s", line);
}

static W w_set_parameters(ARGS8) {
    char kv[1024], line[700];
    if (is_dev(a0)) peek_str(kv, sizeof(kv), (const char *)a1);
    else snprintf(kv, sizeof(kv), "(unexpected caller)");
    W r = FWD(g_o.set_parameters);
    snprintf(line, sizeof(line), "device set_parameters \"%s\" -> %d", kv, (int)r);
    log_param(line);
    return r;
}

/* get_parameters can be asked often: log each question once, then only when the answer changes */
#define MAX_Q 24
static struct {
    char keys[96], answer[160];
} g_q[MAX_Q];
static int g_nq;
static pthread_mutex_t g_q_lock = PTHREAD_MUTEX_INITIALIZER;

static void log_question(const char *who, const char *keys, const char *answer) {
    pthread_mutex_lock(&g_q_lock);
    int i, changed = 1;
    for (i = 0; i < g_nq; i++) {
        if (strncmp(g_q[i].keys, keys, sizeof(g_q[i].keys) - 1) == 0) break;
    }
    if (i < g_nq) {
        changed = strncmp(g_q[i].answer, answer, sizeof(g_q[i].answer) - 1) != 0;
    } else if (g_nq < MAX_Q) {
        g_nq++;
    } else {
        i = -1;
    }
    if (i >= 0) {
        snprintf(g_q[i].keys, sizeof(g_q[i].keys), "%s", keys);
        snprintf(g_q[i].answer, sizeof(g_q[i].answer), "%s", answer);
    }
    pthread_mutex_unlock(&g_q_lock);
    if (changed) wlog(0, "%s get_parameters \"%s\" -> \"%s\"", who, keys, answer);
}

static W w_get_parameters(ARGS8) {
    char keys[256], ans[512];
    if (is_dev(a0)) peek_str(keys, sizeof(keys), (const char *)a1);
    else snprintf(keys, sizeof(keys), "(unexpected caller)");
    W r = FWD(g_o.get_parameters);
    peek_str(ans, sizeof(ans), (const char *)r);
    log_question("device", keys, ans);
    return r;
}

static W w_get_input_buffer_size(ARGS8) {
    W r = FWD(g_o.get_input_buffer_size);
    struct audio_config c;
    if (is_dev(a0) && peek(&c, (const void *)a1, sizeof(c)) == 0) {
        char k[96], v[32];
        snprintf(k, sizeof(k), "input buffer size %u Hz mask 0x%x format 0x%x", c.sample_rate, c.channel_mask, c.format);
        snprintf(v, sizeof(v), "%u bytes", (unsigned)r);
        log_question("device", k, v);
    }
    return r;
}

/* ------------------------------------------------------------------ output stream forwarders */

static out_rec *find_out(W s) {
    for (int i = 0; i < MAX_OUT; i++)
        if ((W)g_out[i].s == s) return &g_out[i];
    return NULL;
}

/* the first hooked stream's originals: used if a call ever comes with an unknown stream */
static out_rec g_any;
static int g_anomaly_logged;

static out_rec *rec_or_any(W s, const char *what) {
    out_rec *r = find_out(s);
    if (r != NULL) return r;
    if (!g_anomaly_logged) {
        g_anomaly_logged = 1;
        wlog(1, "%s came with an unknown stream %p; forwarded with the first stream's function", what, (void *)s);
    }
    return &g_any;
}

static void window_report(out_rec *r, const char *why) {
    if (r->win_writes == 0) return;
    double secs = (double)(r->last_end - r->win_start) / 1e9;
    double fps = secs > 0 ? (double)r->win_frames / secs : 0;
    double peak_db = r->peak > 0 ? 20 * log10(r->peak / 32768.0) : -999;
    double rms_db = r->nsamples && r->sumsq > 0 ? 10 * log10(r->sumsq / (double)r->nsamples / (32768.0 * 32768.0)) : -999;
    double wavg = (double)r->win_wait_sum / (double)r->win_writes / 1e6, wmax = (double)r->win_wait_max / 1e6;
    r->last_fps = fps;
    r->last_peak_db = peak_db;
    r->last_rms_db = rms_db;
    r->last_wait_avg_ms = wavg;
    r->last_wait_max_ms = wmax;
    r->last_fullscale = r->fullscale;
    if (r->stats_ok) {
        wlog(0, "out %d %s: %.1f s, %llu writes, %llu frames, %.0f frames/s, write waits avg %.2f ms max %.2f ms, "
                "peak %.1f dBFS, average %.1f dBFS, full-scale samples %llu",
             r->handle, why, secs, (unsigned long long)r->win_writes, (unsigned long long)r->win_frames, fps, wavg, wmax,
             peak_db, rms_db, (unsigned long long)r->fullscale);
    } else {
        wlog(0, "out %d %s: %.1f s, %llu writes, %llu frames, %.0f frames/s, write waits avg %.2f ms max %.2f ms",
             r->handle, why, secs, (unsigned long long)r->win_writes, (unsigned long long)r->win_frames, fps, wavg, wmax);
    }
    r->win_writes = r->win_frames = 0;
    r->win_wait_sum = r->win_wait_max = 0;
    r->peak = 0;
    r->sumsq = 0;
    r->nsamples = r->fullscale = 0;
    r->win_start = 0;
    write_status();
}

static void stats_add(out_rec *r, const void *buf, size_t bytes, ssize_t done, int64_t t0, int64_t t1) {
    if (done <= 0 || r->frame_bytes == 0) return;
    /* a long gap (standby, nothing playing) starts a new window */
    if (r->win_start != 0 && t0 - r->last_end > 1000000000LL) window_report(r, "until a pause");
    if (r->win_start == 0) r->win_start = t0;
    r->last_end = t1;
    r->win_writes++;
    r->win_frames += (uint64_t)done / r->frame_bytes;
    r->total_frames += (uint64_t)done / r->frame_bytes;
    int64_t wait = t1 - t0;
    r->win_wait_sum += wait;
    if (wait > r->win_wait_max) r->win_wait_max = wait;
    if (!r->checked) {
        /* the first writes: is the buffer what a 16-bit stream should hand over? */
        unsigned char a[4], b[4];
        int ok = r->format == AUDIO_FORMAT_PCM_16_BIT && bytes % r->frame_bytes == 0 && bytes <= 262144 && bytes >= 4 &&
                 peek(a, buf, 4) == 0 && peek(b, (const char *)buf + bytes - 4, 4) == 0;
        r->stats_ok = ok;
        r->checked = 1;
        wlog(0, "out %d first write: %u bytes (%u frames)%s", r->handle, (unsigned)bytes,
             (unsigned)(bytes / r->frame_bytes), ok ? "; levels measured" : "; levels not measured");
    }
    if (r->stats_ok) {
        const int16_t *p = (const int16_t *)buf;
        size_t n = (size_t)done / 2;
        int peak = r->peak;
        double ss = 0;
        uint64_t fs = 0;
        for (size_t i = 0; i < n; i++) {
            int v = p[i];
            int m = v < 0 ? -v : v;
            if (m > peak) peak = m;
            if (v >= 32767 || v <= -32767) fs++;
            ss += (double)v * v;
        }
        r->peak = peak;
        r->sumsq += ss;
        r->nsamples += n;
        r->fullscale += fs;
    }
    if (t1 - r->win_start >= (int64_t)DRV_WINDOW_MS * 1000000LL) window_report(r, "last window");
}

static W w_out_write(ARGS8) {
    out_rec *r = rec_or_any(a0, "write");
    int64_t t0 = now_ns();
    W ret = FWD(r->o_write);
    int64_t t1 = now_ns();
    if (r != &g_any) stats_add(r, (const void *)a1, (size_t)a2, (ssize_t)ret, t0, t1);
    return ret;
}

static W w_out_standby(ARGS8) {
    out_rec *r = rec_or_any(a0, "standby");
    W ret = FWD(r->o_standby);
    if (r != &g_any) {
        window_report(r, "until standby");
        wlog(0, "out %d standby -> %d", r->handle, (int)ret);
    }
    return ret;
}

static W w_out_set_params(ARGS8) {
    out_rec *r = rec_or_any(a0, "set_parameters");
    char kv[1024];
    peek_str(kv, sizeof(kv), (const char *)a1);
    W ret = FWD(r->o_set_params);
    char line[700];
    snprintf(line, sizeof(line), "out %d set_parameters \"%s\" -> %d", r->handle, kv, (int)ret);
    log_param(line);
    return ret;
}

static W w_out_get_params(ARGS8) {
    out_rec *r = rec_or_any(a0, "get_parameters");
    char keys[256], ans[512], who[24];
    peek_str(keys, sizeof(keys), (const char *)a1);
    W ret = FWD(r->o_get_params);
    peek_str(ans, sizeof(ans), (const char *)ret);
    snprintf(who, sizeof(who), "out %d", r->handle);
    log_question(who, keys, ans);
    return ret;
}

static W w_out_set_rate(ARGS8) {
    out_rec *r = rec_or_any(a0, "set_sample_rate");
    W ret = FWD(r->o_set_rate);
    wlog(1, "out %d set_sample_rate %u -> %d", r->handle, (unsigned)a1, (int)ret);
    return ret;
}

static W w_out_set_format(ARGS8) {
    out_rec *r = rec_or_any(a0, "set_format");
    W ret = FWD(r->o_set_format);
    wlog(1, "out %d set_format 0x%x -> %d", r->handle, (unsigned)a1, (int)ret);
    return ret;
}

static W w_out_set_device(ARGS8) {
    out_rec *r = rec_or_any(a0, "set_device");
    W ret = FWD(r->o_set_device);
    wlog(1, "out %d set_device 0x%x -> %d", r->handle, (unsigned)a1, (int)ret);
    return ret;
}

#if defined(__arm__)
static W w_out_set_volume(ARGS8) {
    out_rec *r = rec_or_any(a0, "set_volume");
    W ret = FWD(r->o_set_volume);
    float l = word_float(a1), rr = word_float(a2);
    if (r != &g_any && (l != r->vol_l || rr != r->vol_r)) {
        r->vol_l = l;
        r->vol_r = rr;
        wlog(0, "out %d set_volume %.3f %.3f -> %d", r->handle, l, rr, (int)ret);
    }
    return ret;
}
#else
static int w_out_set_volume(struct audio_stream_out *s, float l, float rr) {
    out_rec *r = rec_or_any((W)s, "set_volume");
    int ret = ((int (*)(struct audio_stream_out *, float, float))r->o_set_volume)(s, l, rr);
    if (r != &g_any && (l != r->vol_l || rr != r->vol_r)) {
        r->vol_l = l;
        r->vol_r = rr;
        wlog(0, "out %d set_volume %.3f %.3f -> %d", r->handle, l, rr, ret);
    }
    return ret;
}
#endif

static int popcount32(unsigned v) {
    int c = 0;
    while (v) {
        c += v & 1;
        v >>= 1;
    }
    return c;
}

static int stream_tables_ok(struct audio_stream_out *s) {
    const void *const *slots = (const void *const *)s;
    size_t n = sizeof(struct audio_stream_out) / sizeof(void *);
    for (size_t i = 0; i < n; i++) {
        const void *p;
        if (peek(&p, &slots[i], sizeof(p)) != 0) return 0;
        if (!in_orig(p)) return 0;
    }
    return 1;
}

static void hook_out(struct audio_stream_out *s, int handle, unsigned devices, unsigned flags) {
    pthread_mutex_lock(&g_out_lock);
    out_rec *r = NULL;
    for (int i = 0; i < MAX_OUT; i++)
        if (g_out[i].s == NULL) {
            r = &g_out[i];
            break;
        }
    if (r == NULL) {
        pthread_mutex_unlock(&g_out_lock);
        wlog(1, "out %d: too many streams to watch; left untouched", handle);
        return;
    }
    memset(r, 0, sizeof(*r));
    r->handle = handle;
    r->devices = devices;
    r->flags = flags;
    r->vol_l = r->vol_r = -1;
    int ok = stream_tables_ok(s);
    if (ok) {
        /* Hyundai's own answers, the same calls Android makes next */
        r->rate = s->common.get_sample_rate ? s->common.get_sample_rate(&s->common) : 0;
        r->mask = s->common.get_channels ? s->common.get_channels(&s->common) : 0;
        r->format = s->common.get_format ? s->common.get_format(&s->common) : 0;
        r->buffer_bytes = s->common.get_buffer_size ? (unsigned)s->common.get_buffer_size(&s->common) : 0;
        r->latency_ms = s->get_latency ? s->get_latency(s) : 0;
        int ch = popcount32(r->mask);
        r->frame_bytes = (r->format == AUDIO_FORMAT_PCM_16_BIT ? 2 : r->format == AUDIO_FORMAT_PCM_8_BIT ? 1 : 4) *
                         (unsigned)(ch > 0 ? ch : 2);
        r->o_write = (W)s->write;
        r->o_standby = (W)s->common.standby;
        r->o_set_params = (W)s->common.set_parameters;
        r->o_get_params = (W)s->common.get_parameters;
        r->o_set_rate = (W)s->common.set_sample_rate;
        r->o_set_format = (W)s->common.set_format;
        r->o_set_device = (W)s->common.set_device;
        r->o_set_volume = (W)s->set_volume;
        if (g_any.o_write == 0) g_any = *r;
        r->s = s; /* findable before the first call can arrive */
        r->hooked = 1;
        if (s->write) s->write = AS(__typeof__(s->write), w_out_write);
        if (s->common.standby) s->common.standby = AS(__typeof__(s->common.standby), w_out_standby);
        if (s->common.set_parameters)
            s->common.set_parameters = AS(__typeof__(s->common.set_parameters), w_out_set_params);
        if (s->common.get_parameters)
            s->common.get_parameters = AS(__typeof__(s->common.get_parameters), w_out_get_params);
        if (s->common.set_sample_rate)
            s->common.set_sample_rate = AS(__typeof__(s->common.set_sample_rate), w_out_set_rate);
        if (s->common.set_format) s->common.set_format = AS(__typeof__(s->common.set_format), w_out_set_format);
        if (s->common.set_device) s->common.set_device = AS(__typeof__(s->common.set_device), w_out_set_device);
        if (s->set_volume) s->set_volume = AS(__typeof__(s->set_volume), w_out_set_volume);
    } else {
        r->s = s;
        r->hooked = 0;
    }
    pthread_mutex_unlock(&g_out_lock);
    if (ok)
        wlog(1, "out %d watched: %u Hz, mask 0x%x, format 0x%x, buffer %u bytes, latency %u ms", handle, r->rate, r->mask,
             r->format, r->buffer_bytes, r->latency_ms);
    else
        wlog(1, "out %d: its table looks unfamiliar; passed through untouched", handle);
    write_status();
}

static W w_open_output_stream(ARGS8) {
    struct audio_config in, out;
    int have_in = is_dev(a0) && peek(&in, (const void *)a4, sizeof(in)) == 0;
    W r = FWD(g_o.open_output_stream);
    int have_out = have_in && peek(&out, (const void *)a4, sizeof(out)) == 0;
    W sp = 0;
    if (r == 0 && is_dev(a0)) peek(&sp, (const void *)a5, sizeof(sp));
    if (have_in && have_out)
        wlog(1, "open_output_stream handle %d devices 0x%x flags 0x%x: asked %u Hz mask 0x%x format 0x%x -> %d, "
                "config now %u Hz mask 0x%x format 0x%x",
             (int)a1, (unsigned)a2, (unsigned)a3, in.sample_rate, in.channel_mask, in.format, (int)r, out.sample_rate,
             out.channel_mask, out.format);
    else
        wlog(1, "open_output_stream handle %d devices 0x%x flags 0x%x -> %d", (int)a1, (unsigned)a2, (unsigned)a3, (int)r);
    if (r == 0 && sp != 0 && g_dev_hooked) hook_out((struct audio_stream_out *)sp, (int)a1, (unsigned)a2, (unsigned)a3);
    return r;
}

static W w_close_output_stream(ARGS8) {
    out_rec *rec = NULL;
    pthread_mutex_lock(&g_out_lock);
    rec = find_out(a1);
    int handle = rec ? rec->handle : -1;
    if (rec) {
        window_report(rec, "until close");
        rec->s = NULL;
    }
    pthread_mutex_unlock(&g_out_lock);
    W r = FWD(g_o.close_output_stream);
    wlog(1, "close_output_stream out %d", handle);
    write_status();
    return r;
}

static W w_open_input_stream(ARGS8) {
    struct audio_config in, out;
    int have_in = is_dev(a0) && peek(&in, (const void *)a3, sizeof(in)) == 0;
    W r = FWD(g_o.open_input_stream);
    int have_out = have_in && peek(&out, (const void *)a3, sizeof(out)) == 0;
    if (have_in && have_out)
        wlog(1, "open_input_stream handle %d devices 0x%x: asked %u Hz mask 0x%x format 0x%x -> %d, config now %u Hz "
                "mask 0x%x format 0x%x",
             (int)a1, (unsigned)a2, in.sample_rate, in.channel_mask, in.format, (int)r, out.sample_rate, out.channel_mask,
             out.format);
    else
        wlog(1, "open_input_stream handle %d devices 0x%x -> %d", (int)a1, (unsigned)a2, (int)r);
    return r;
}

static W w_close_input_stream(ARGS8) {
    W r = FWD(g_o.close_input_stream);
    wlog(1, "close_input_stream %p", (void *)a1);
    return r;
}

/* ------------------------------------------------------------------ the module */

static int device_tables_ok(struct audio_hw_device *d, char *why, size_t cap) {
    if (d->common.tag != HARDWARE_DEVICE_TAG) {
        snprintf(why, cap, "device tag 0x%x", d->common.tag);
        return 0;
    }
    if (d->common.version != AUDIO_DEVICE_API_VERSION_2_0) {
        snprintf(why, cap, "device version 0x%x", d->common.version);
        return 0;
    }
    if (d->common.module != g_orig_mod) {
        snprintf(why, cap, "device belongs to another module");
        return 0;
    }
    if (!in_orig((const void *)d->common.close)) {
        snprintf(why, cap, "close is outside the driver");
        return 0;
    }
    const void *const *slots = (const void *const *)&d->get_supported_devices;
    size_t n = (sizeof(struct audio_hw_device) - offsetof(struct audio_hw_device, get_supported_devices)) / sizeof(void *);
    for (size_t i = 0; i < n; i++) {
        if (!in_orig(slots[i])) {
            snprintf(why, cap, "slot %u is outside the driver", (unsigned)i);
            return 0;
        }
    }
    return 1;
}

#define HOOK(field, wrapper)                                                                                      \
    do {                                                                                                          \
        if (d->field != NULL) {                                                                                   \
            g_o.field = (W)d->field;                                                                              \
            d->field = AS(__typeof__(d->field), wrapper);                                                         \
        }                                                                                                         \
    } while (0)

static void hook_device(struct audio_hw_device *d) {
    char why[96];
    g_dev = d;
    if (!device_tables_ok(d, why, sizeof(why))) {
        g_state = "pass-through";
        snprintf(g_reason, sizeof(g_reason), "Hyundai's device table looks unfamiliar (%s); handed to Android untouched", why);
        wlog(1, "%s", g_reason);
        write_status();
        return;
    }
    HOOK(init_check, w_init_check);
    HOOK(set_voice_volume, w_set_voice_volume);
    HOOK(set_master_volume, w_set_master_volume);
    HOOK(set_mode, w_set_mode);
    HOOK(set_mic_mute, w_set_mic_mute);
    HOOK(set_parameters, w_set_parameters);
    HOOK(get_parameters, w_get_parameters);
    HOOK(get_input_buffer_size, w_get_input_buffer_size);
    HOOK(open_output_stream, w_open_output_stream);
    HOOK(close_output_stream, w_close_output_stream);
    HOOK(open_input_stream, w_open_input_stream);
    HOOK(close_input_stream, w_close_input_stream);
    HOOK(set_master_mute, w_set_master_mute);
    g_dev_hooked = 1;
    g_state = "watching";
    g_reason[0] = 0;
    wlog(1, "watching Hyundai's driver: module \"%s\" by \"%s\", module version 0x%x, device version 0x%x",
         g_orig_mod->name ? g_orig_mod->name : "?", g_orig_mod->author ? g_orig_mod->author : "?",
         g_orig_mod->module_api_version, d->common.version);
    write_status();
}

static int shim_open(const struct hw_module_t *module, const char *name, struct hw_device_t **device) {
    (void)module;
    pthread_once(&g_orig_once, orig_load);
    if (g_orig_mod == NULL || g_orig_mod->methods == NULL || g_orig_mod->methods->open == NULL) {
        write_status();
        return -ENODEV;
    }
    wlog(1, "EQ Engine driver watch %d: opening \"%s\" in Hyundai's driver (%s)", DRV_VERSION, name ? name : "?", DRV_ORIG);
    int rc = g_orig_mod->methods->open(g_orig_mod, name, device);
    if (rc != 0 || device == NULL || *device == NULL) {
        wlog(1, "Hyundai's driver open \"%s\" -> %d", name ? name : "?", rc);
        return rc;
    }
    if (name != NULL && strcmp(name, AUDIO_HARDWARE_INTERFACE) == 0 && g_dev == NULL) {
        hook_device((struct audio_hw_device *)*device);
    } else {
        wlog(1, "device \"%s\" opened; not watched", name ? name : "?");
    }
    return 0;
}

static struct hw_module_methods_t shim_methods = {
    .open = shim_open,
};

EXPORT struct audio_module HMI = {
    .common =
        {
            .tag = HARDWARE_MODULE_TAG,
            .module_api_version = AUDIO_MODULE_API_VERSION_0_1,
            .hal_api_version = HARDWARE_HAL_API_VERSION,
            .id = AUDIO_HARDWARE_MODULE_ID,
            .name = "EQ Engine driver watch (Hyundai's driver behind it)",
            .author = "EQ Engine",
            .methods = &shim_methods,
        },
};
