/*
 * EQ Engine driver watch 2 (Lab test, 0.6.1): a pass-through layer in front of Hyundai's audio
 * driver.
 *
 * Put in place only from the Lab page (an in-memory bind mount over
 * /system/lib/hw/audio.primary.tcc803x.so, gone at the next car start or when switched off), it
 * loads Hyundai's driver from an unchanged copy (DRV_ORIG), hands every call on to it and writes
 * down what Android asks of the driver. It changes nothing in the audio.
 *
 * Hyundai's device table: Android 4.4's audio_hw_device has 18 function entries after "common";
 * Hyundai's has 19. The 0.6.0 car logs (2026-11-19) placed the extra one: entries 0 to 5 are where
 * Android 4.4 has them (init_check, set_voice_volume, set_master_volume and set_mode were seen
 * there), and from set_parameters on everything sits one further (set_parameters was seen at 9,
 * open_output_stream at 12, dump at 16). Entries 6 to 8 hold the two microphone mute functions
 * and Hyundai's extra one, in an order that is not known: they are forwarded and written down as
 * numbers only. Version 1 used Android's own positions, so it misnamed every call from
 * set_parameters on and never saw an output stream open.
 *
 * Safety:
 *  - Only the 19 device entries are replaced, in Hyundai's own device object, before Android gets
 *    it. Output and input streams are never touched: their tables could be laid out differently
 *    too, so this layer does not change them and does not call into them.
 *  - Before that, the device is checked: tag, version 2.0, its module, and every entry empty or
 *    inside the executable mapping of Hyundai's driver (from /proc/self/maps). If anything looks
 *    unfamiliar, the device is handed to Android untouched: "pass-through only".
 *  - Every forwarder passes eight words on and hands the result back as it came, so a call
 *    reaches Hyundai's function exactly as Android made it. (On this car's ARM build, float
 *    arguments travel in core registers too.)
 *  - Pointers the logger reads (parameter strings, stream configs) are read through a pipe, so a
 *    bad pointer gives an error instead of a crash. Nothing is ever written through an argument.
 *  - The hardware links' real rate comes from the kernel's own counters
 *    (/proc/asound/cardN/pcmMp/sub0/status: hw_ptr over tstamp), read by the logger thread.
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
#ifndef DRV_ASOUND
#define DRV_ASOUND "/proc/asound"
#endif
#ifndef DRV_WINDOW_MS
#define DRV_WINDOW_MS 30000
#endif
#define DRV_LINK_MS (DRV_WINDOW_MS / 3) /* how often the status file's link rates are measured */
#define DRV_VERSION 2
#define LOG_CAP (512 * 1024)
#define EXPORT __attribute__((visibility("default")))

typedef uintptr_t W;
typedef W (*fn8)(W, W, W, W, W, W, W, W);

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
 * the status file, and measures the links, so no file work ever happens on the audio threads. */

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

static void wlog(int to_logcat, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
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
static void links_poll(int64_t now);

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
    int64_t next_poll = 0;
    for (;;) {
        char text[QLINE];
        struct timespec when;
        int lc = 0, have = 0, status = 0;
        unsigned dropped = 0;
        int64_t now = now_ns();
        if (now >= next_poll) {
            links_poll(now);
            next_poll = now + (int64_t)DRV_LINK_MS * 1000000LL;
        }
        pthread_mutex_lock(&g_log_lock);
        while (g_q_head == g_q_tail && !g_status_dirty) {
            int64_t wait = next_poll - now_ns();
            if (wait <= 0) break;
            if (wait > 5000000000LL) wait = 5000000000LL;
            struct timespec t;
            clock_gettime(CLOCK_REALTIME, &t);
            t.tv_sec += (time_t)(wait / 1000000000LL);
            t.tv_nsec += (long)(wait % 1000000000LL);
            if (t.tv_nsec >= 1000000000L) {
                t.tv_sec++;
                t.tv_nsec -= 1000000000L;
            }
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
static pthread_once_t g_orig_once = PTHREAD_ONCE_INIT;
static const char *g_state = "starting";
static char g_reason[240] = "";

/* drvwatch_tramp.S: forwarders for the driver's exported helper functions */
extern int drvwatch_tramp_resolve(void *so);
extern int drvwatch_tramp_count;

/* the executable mappings of Hyundai's driver copy, from /proc/self/maps */
#define MAXR 8
static uintptr_t g_code[MAXR][2];
static int g_ncode;

static void code_ranges(void) {
    FILE *f = fopen("/proc/self/maps", "r");
    if (f == NULL) return;
    char line[512];
    while (fgets(line, sizeof(line), f) && g_ncode < MAXR) {
        unsigned long lo, hi;
        char perms[8], path[400];
        path[0] = 0;
        if (sscanf(line, "%lx-%lx %7s %*s %*s %*s %399s", &lo, &hi, perms, path) < 3) continue;
        if (perms[2] == 'x' && strcmp(path, DRV_ORIG) == 0) {
            g_code[g_ncode][0] = (uintptr_t)lo;
            g_code[g_ncode][1] = (uintptr_t)hi;
            g_ncode++;
        }
    }
    fclose(f);
}

/* a function inside Hyundai's driver (Thumb functions are odd addresses), or empty */
static int in_code(W p) {
    if (p == 0) return 1;
    uintptr_t a = (uintptr_t)p & ~(uintptr_t)1;
    for (int i = 0; i < g_ncode; i++)
        if (a >= g_code[i][0] && a < g_code[i][1]) return 1;
    return 0;
}

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
    code_ranges();
    g_orig_mod->dso = g_orig_so;
    int found = drvwatch_tramp_resolve(g_orig_so);
    wlog(0, "Hyundai's driver copy loaded (%d executable mapping%s); %d of its %d helper functions forwarded", g_ncode,
         g_ncode == 1 ? "" : "s", found, drvwatch_tramp_count);
}

/* ------------------------------------------------------------------ hardware links (kernel counters) */

#define MAXL 16
typedef struct {
    int used, card, dev, owner;
    unsigned rate;
    long long hw, win_hw;
    double ts, win_ts, fps;
} link_rec;
static link_rec g_link[MAXL];
static int64_t g_win_start;
static pthread_mutex_t g_link_lock = PTHREAD_MUTEX_INITIALIZER;

static const char *field(const char *line, const char *key) {
    size_t n = strlen(key);
    if (strncmp(line, key, n) != 0) return NULL;
    const char *p = line + n;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != ':') return NULL;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    return p;
}

/* 1 = running, with its counters */
static int link_read(int card, int dev, int *owner, unsigned *rate, long long *hw, double *ts) {
    char path[256], line[256];
    int running = 0;
    snprintf(path, sizeof(path), DRV_ASOUND "/card%d/pcm%dp/sub0/status", card, dev);
    FILE *f = fopen(path, "r");
    if (f == NULL) return 0;
    *owner = 0;
    *hw = 0;
    *ts = 0;
    *rate = 0;
    while (fgets(line, sizeof(line), f)) {
        const char *v;
        if ((v = field(line, "state"))) running = strncmp(v, "RUNNING", 7) == 0;
        else if ((v = field(line, "owner_pid"))) *owner = atoi(v);
        else if ((v = field(line, "hw_ptr"))) *hw = atoll(v);
        else if ((v = field(line, "tstamp"))) *ts = atof(v);
    }
    fclose(f);
    if (!running) return 0;
    snprintf(path, sizeof(path), DRV_ASOUND "/card%d/pcm%dp/sub0/hw_params", card, dev);
    f = fopen(path, "r");
    if (f != NULL) {
        while (fgets(line, sizeof(line), f)) {
            const char *v = field(line, "rate");
            if (v) *rate = (unsigned)strtoul(v, NULL, 10);
        }
        fclose(f);
    }
    return 1;
}

/* logger thread: every DRV_LINK_MS for the status file; every DRV_WINDOW_MS a line in the log */
static void links_poll(int64_t now) {
    int report = g_win_start == 0 || now - g_win_start >= (int64_t)DRV_WINDOW_MS * 1000000LL;
    pthread_mutex_lock(&g_link_lock);
    for (int i = 0; i < MAXL; i++) g_link[i].used = -g_link[i].used; /* not seen yet this time */
    for (int card = 0; card < 4; card++) {
        for (int dev = 0; dev < 16; dev++) {
            int owner;
            unsigned rate;
            long long hw;
            double ts;
            if (!link_read(card, dev, &owner, &rate, &hw, &ts)) continue;
            link_rec *r = NULL, *fr = NULL;
            for (int i = 0; i < MAXL; i++) {
                if (g_link[i].used != 0 && g_link[i].card == card && g_link[i].dev == dev) r = &g_link[i];
                if (g_link[i].used == 0 && fr == NULL) fr = &g_link[i];
            }
            if (r != NULL && (r->owner != owner || hw < r->hw || ts <= r->ts)) r->used = 0, fr = r, r = NULL;
            if (r == NULL) {
                if (fr == NULL) continue;
                r = fr;
                memset(r, 0, sizeof(*r));
                r->card = card;
                r->dev = dev;
                r->owner = owner;
                r->win_hw = hw;
                r->win_ts = ts;
                r->fps = 0;
            } else if (ts > r->ts) {
                r->fps = (double)(hw - r->hw) / (ts - r->ts);
            }
            r->used = 1;
            r->rate = rate;
            r->hw = hw;
            r->ts = ts;
            if (report && ts > r->win_ts && hw > r->win_hw) {
                wlog(0, "link pcm%dp (card%d, played by thread %d): set to %u Hz, took %.0f frames/s over %.1f s", dev, card,
                     owner, rate, (double)(hw - r->win_hw) / (ts - r->win_ts), ts - r->win_ts);
                r->win_hw = hw;
                r->win_ts = ts;
            }
        }
    }
    for (int i = 0; i < MAXL; i++)
        if (g_link[i].used < 0) g_link[i].used = 0; /* stopped */
    pthread_mutex_unlock(&g_link_lock);
    if (report) g_win_start = now;
    write_status_now();
}

/* ------------------------------------------------------------------ Hyundai's device table */

#define NSLOT 19
enum {
    S_SUPPORTED = 0, S_INIT = 1, S_VOICE = 2, S_MASTER = 3, S_GET_MASTER = 4, S_MODE = 5,
    S_SETP = 9, S_GETP = 10, S_INBUF = 11, S_OPEN_OUT = 12, S_CLOSE_OUT = 13, S_OPEN_IN = 14,
    S_CLOSE_IN = 15, S_DUMP = 16, S_SET_MUTE = 17, S_GET_MUTE = 18
};
static const char *const k_name[NSLOT] = {
    "get_supported_devices", "init_check", "set_voice_volume", "set_master_volume", "get_master_volume", "set_mode",
    NULL, NULL, NULL, /* the microphone mute pair and Hyundai's extra entry, order not known */
    "set_parameters", "get_parameters", "get_input_buffer_size", "open_output_stream", "close_output_stream",
    "open_input_stream", "close_input_stream", "dump", "set_master_mute", "get_master_mute"};

static W g_orig[NSLOT];
static unsigned g_calls[NSLOT], g_calls_noted[NSLOT], g_raw_logged[NSLOT];
static W g_dev;
static int g_dev_hooked;
static int g_mode = -1;

static int is_dev(W d) {
    return d == g_dev;
}

static void slot_label(int i, char *b, size_t n) {
    if (k_name[i]) snprintf(b, n, "%s", k_name[i]);
    else snprintf(b, n, "entry %d (not named)", i);
}

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

/* get_parameters can be asked often: log each question once, then only when the answer changes */
#define MAX_Q 24
static struct {
    char keys[96], answer[160];
} g_q[MAX_Q];
static int g_nq;
static pthread_mutex_t g_q_lock = PTHREAD_MUTEX_INITIALIZER;

static void log_question(const char *keys, const char *answer) {
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
    if (changed) wlog(0, "device get_parameters \"%s\" -> \"%s\"", keys, answer);
}

#if defined(__arm__)
/* softfp: a float argument is in a core register as raw bits */
static float word_float(W w) {
    float f;
    uint32_t u = (uint32_t)w;
    memcpy(&f, &u, sizeof(f));
    return f;
}
#endif

/* plausible audio_config: the rate Android asks for */
static int config_ok(const struct audio_config *c) {
    return c->sample_rate >= 4000 && c->sample_rate <= 384000;
}

static W slot_call(int i, W a0, W a1, W a2, W a3, W a4, W a5, W a6, W a7) {
    struct audio_config in, out;
    int have_in = 0;
    char text[1024], line[700];
    text[0] = 0;
    /* before the call: what Android hands over (read only) */
    if (i == S_OPEN_OUT)
        have_in = is_dev(a0) && a1 < 1000000 && peek(&in, (const void *)a4, sizeof(in)) == 0 && config_ok(&in);
    else if (i == S_OPEN_IN)
        have_in = is_dev(a0) && a1 < 1000000 && peek(&in, (const void *)a3, sizeof(in)) == 0 && config_ok(&in);
    else if (i == S_SETP || i == S_GETP)
        peek_str(text, sizeof(text), (const char *)a1);

    W r = ((fn8)g_orig[i])(a0, a1, a2, a3, a4, a5, a6, a7);
    __atomic_fetch_add(&g_calls[i], 1, __ATOMIC_RELAXED);

    switch (i) {
    case S_INIT:
        wlog(1, "device init_check -> %d", (int)r);
        break;
#if defined(__arm__)
    case S_VOICE:
    case S_MASTER:
        /* softfp: the float is in r1 as raw bits */
        wlog(i == S_MASTER, "device %s %.3f -> %d", k_name[i], word_float(a1), (int)r);
        break;
#endif
    case S_MODE:
        if (is_dev(a0)) g_mode = (int)a1;
        wlog(1, "device set_mode %d -> %d", (int)a1, (int)r);
        write_status();
        break;
    case S_SETP:
        snprintf(line, sizeof(line), "device set_parameters \"%s\" -> %d", text, (int)r);
        log_param(line);
        break;
    case S_GETP: {
        char ans[512];
        peek_str(ans, sizeof(ans), (const char *)r);
        log_question(text, ans);
        break;
    }
    case S_OPEN_OUT:
    case S_OPEN_IN:
        if (have_in && peek(&out, (const void *)(i == S_OPEN_OUT ? a4 : a3), sizeof(out)) == 0) {
            if (i == S_OPEN_OUT)
                wlog(1, "open_output_stream handle %d devices 0x%x flags 0x%x: asked %u Hz mask 0x%x format 0x%x -> %d, "
                        "config now %u Hz mask 0x%x format 0x%x",
                     (int)a1, (unsigned)a2, (unsigned)a3, (unsigned)in.sample_rate, (unsigned)in.channel_mask,
                     (unsigned)in.format, (int)r, (unsigned)out.sample_rate, (unsigned)out.channel_mask,
                     (unsigned)out.format);
            else
                wlog(1, "open_input_stream handle %d devices 0x%x: asked %u Hz mask 0x%x format 0x%x -> %d, config now %u Hz "
                        "mask 0x%x format 0x%x",
                     (int)a1, (unsigned)a2, (unsigned)in.sample_rate, (unsigned)in.channel_mask, (unsigned)in.format,
                     (int)r, (unsigned)out.sample_rate, (unsigned)out.channel_mask, (unsigned)out.format);
            break;
        }
        /* not what it should look like: written down as numbers, below */
        __attribute__((fallthrough));
    default:
        if (__atomic_fetch_add(&g_raw_logged[i], 1, __ATOMIC_RELAXED) < 3) {
            char lab[40];
            slot_label(i, lab, sizeof(lab));
            wlog(0, "device %s: 0x%lx 0x%lx 0x%lx -> 0x%lx%s", lab, (unsigned long)a1, (unsigned long)a2, (unsigned long)a3,
                 (unsigned long)r, g_raw_logged[i] >= 3 ? " (from now on only counted)" : "");
        }
        break;
    }
    return r;
}

#define SLOT(n) \
    static W slot_##n(W a0, W a1, W a2, W a3, W a4, W a5, W a6, W a7) { return slot_call(n, a0, a1, a2, a3, a4, a5, a6, a7); }
SLOT(0) SLOT(1) SLOT(2) SLOT(3) SLOT(4) SLOT(5) SLOT(6) SLOT(7) SLOT(8) SLOT(9) SLOT(10) SLOT(11) SLOT(12) SLOT(13)
SLOT(14) SLOT(15) SLOT(16) SLOT(17) SLOT(18)
static const fn8 k_slot_fn[NSLOT] = {slot_0,  slot_1,  slot_2,  slot_3,  slot_4,  slot_5,  slot_6,
                                     slot_7,  slot_8,  slot_9,  slot_10, slot_11, slot_12, slot_13,
                                     slot_14, slot_15, slot_16, slot_17, slot_18};

#if !defined(__arm__)
/* PC test builds: floats travel in their own registers, so the two volume entries keep their types */
static int pc_volume(int i, W d, float v) {
    int r = ((int (*)(W, float))g_orig[i])(d, v);
    __atomic_fetch_add(&g_calls[i], 1, __ATOMIC_RELAXED);
    wlog(i == S_MASTER, "device %s %.3f -> %d", k_name[i], v, r);
    return r;
}
static int pc_voice(W d, float v) { return pc_volume(S_VOICE, d, v); }
static int pc_master(W d, float v) { return pc_volume(S_MASTER, d, v); }
#endif

/* the logger thread's summary of the calls since the last one */
static void calls_note(void) {
    char b[400];
    int n = 0;
    for (int i = 0; i < NSLOT && n < (int)sizeof(b) - 48; i++) {
        unsigned c = __atomic_load_n(&g_calls[i], __ATOMIC_RELAXED);
        unsigned d = c - g_calls_noted[i];
        g_calls_noted[i] = c;
        if (d == 0) continue;
        char lab[40];
        slot_label(i, lab, sizeof(lab));
        n += snprintf(b + n, sizeof(b) - (size_t)n, "%s%s %u", n ? ", " : "", lab, d);
    }
    if (n) wlog(0, "device calls since the last note: %s", b);
}

/* ------------------------------------------------------------------ status file */

static void write_status_now(void) {
    char buf[2000];
    int n = snprintf(buf, sizeof(buf), "version=%d\nstate=%s\nreason=%s\nmode=%d\nlayout=hyundai-%d\n", DRV_VERSION, g_state,
                     g_reason, g_mode, NSLOT);
    pthread_mutex_lock(&g_link_lock);
    for (int i = 0; i < MAXL && n < (int)sizeof(buf) - 120; i++) {
        link_rec *r = &g_link[i];
        if (r->used != 1) continue;
        n += snprintf(buf + n, sizeof(buf) - (size_t)n, "link=pcm%dp card=%d owner=%d rate=%u fps=%.0f\n", r->dev, r->card,
                      r->owner, r->rate, r->fps);
    }
    pthread_mutex_unlock(&g_link_lock);
    static int64_t last_note;
    int64_t t = now_ns();
    if (g_dev_hooked && t - last_note >= (int64_t)DRV_WINDOW_MS * 1000000LL) {
        last_note = t;
        calls_note();
    }
    int fd = open(DRV_DIR "/status.tmp", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    ssize_t w = write(fd, buf, (size_t)n);
    (void)w;
    fchmod(fd, 0644);
    close(fd);
    rename(DRV_DIR "/status.tmp", DRV_DIR "/status");
}

/* ------------------------------------------------------------------ the module */

static int device_ok(struct audio_hw_device *d, W *slots, char *why, size_t cap) {
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
    if (g_ncode == 0) {
        snprintf(why, cap, "the driver's code was not found in the memory map");
        return 0;
    }
    if (!in_code((W)d->common.close)) {
        snprintf(why, cap, "close is outside the driver's code");
        return 0;
    }
    /* Hyundai's 19 entries, read without trusting the Android 4.4 struct's length */
    if (peek(slots, &d->get_supported_devices, NSLOT * sizeof(W)) != 0) {
        snprintf(why, cap, "the device table could not be read");
        return 0;
    }
    for (int i = 0; i < NSLOT; i++) {
        if (!in_code(slots[i])) {
            snprintf(why, cap, "entry %d is not a function in the driver", i);
            return 0;
        }
    }
    if (slots[S_SETP] == 0 || slots[S_OPEN_OUT] == 0) {
        snprintf(why, cap, "set_parameters or open_output_stream is empty");
        return 0;
    }
    return 1;
}

static void hook_device(struct audio_hw_device *d) {
    char why[96];
    W slots[NSLOT];
    g_dev = (W)d;
    if (!device_ok(d, slots, why, sizeof(why))) {
        g_state = "pass-through";
        snprintf(g_reason, sizeof(g_reason), "Hyundai's device table looks unfamiliar (%s); handed to Android untouched", why);
        wlog(1, "%s", g_reason);
        write_status();
        return;
    }
    W *table = (W *)&d->get_supported_devices;
    int n = 0;
    for (int i = 0; i < NSLOT; i++) {
        if (slots[i] == 0) continue;
        g_orig[i] = slots[i];
        W f = (W)k_slot_fn[i];
#if !defined(__arm__)
        if (i == S_VOICE) f = (W)pc_voice;
        if (i == S_MASTER) f = (W)pc_master;
#endif
        table[i] = f;
        n++;
    }
    g_dev_hooked = 1;
    g_state = "watching";
    g_reason[0] = 0;
    wlog(1, "watching Hyundai's driver: module \"%s\" by \"%s\", module version 0x%x, device version 0x%x; %d of its %d "
            "device entries forwarded (Hyundai's layout); output streams left untouched",
         g_orig_mod->name ? g_orig_mod->name : "?", g_orig_mod->author ? g_orig_mod->author : "?",
         g_orig_mod->module_api_version, d->common.version, n, NSLOT);
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
    if (name != NULL && strcmp(name, AUDIO_HARDWARE_INTERFACE) == 0 && g_dev == 0) {
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
