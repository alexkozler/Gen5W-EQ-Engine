/*
 * EQ on CarPlay (the CarPlay watch: 2 in 0.6.9, 3 in 0.7.3 with the EQ, on by default from 0.7.4):
 * watches the sound the factory CarPlay app plays itself, from inside that app as Android normally
 * starts it, and runs EQ Engine's filter on CarPlay's music (see "EQ on CarPlay's music" below; the
 * paragraph "Each call is handed on" describes every other stream, and the music when the EQ is
 * off).
 *
 * Wired CarPlay's music does not go through Android's audio server: the factory CarPlay app
 * (com.daudio.app.dipo) plays it with Telechips' libCarPlayAudio.so, which opens the main speaker
 * link with TinyALSA and writes it there itself (0.6.4 on the car). CarPlay watch 1 (0.6.7) was
 * loaded with the wrap property, which starts the app outside the zygote, so without HMG-API's
 * hooks (HMG-API sets them up in the zygote only); with HMG-API's wireless package installed,
 * CarPlay then never started (0.6.7 and 0.6.8 on the car).
 *
 * This library stands in for the app's JNI library instead: at the car start, before the app
 * starts, act.sh cpwboot lays it over /system/lib/libCarPlayAndroid.so (an in-memory bind mount);
 * Android forks the app from the zygote as always. When the app loads its JNI library, Dalvik
 * loads this file and calls its JNI_OnLoad, which
 *   1. loads an unchanged copy of the car's own libCarPlayAndroid.so (CPS_COPY, md5 checked by
 *      act.sh), whose own dependencies (libCarPlay*.so) load from /system/lib as they always do,
 *   2. hands the call on to the copy's JNI_OnLoad (which registers the app's native methods)
 *      and returns its result,
 *   3. points four entries of libCarPlayAudio.so's import table (pcm_open, pcm_close, pcm_write,
 *      pcm_read) at the pass-through functions below, after checking that each still holds
 *      TinyALSA's own function. The table is read-only after loading (BIND_NOW, RELRO): it is made
 *      writable for the change and read-only again. No code is changed, and nothing outside this
 *      one app is touched. HMG-API patches the CarPlay libraries after the load returns, by path
 *      and md5; those files are not changed, so its patches go in as before.
 * Nothing else imports anything from libCarPlayAndroid.so, and Dalvik needs only its JNI_OnLoad.
 *
 * Each call is handed on, with the same arguments, to the function of the same name in the car's
 * libtinyalsa.so (dlsym on that library's own handle), and its result is returned as it came. The
 * sound is not touched: this only writes down each stream opened, and measures the writes and reads
 * (calls, frames per second, the gaps between calls, the time spent inside the call, the peak level
 * of 16-bit streams, errors). The other TinyALSA functions are not wrapped.
 *
 * In the app's audio threads it reads the clock, scans the samples for the peak and updates
 * counters; nothing there allocates, locks or does I/O (pcm_open and pcm_close take a lock and read
 * the thread's name). A thread of its own, started in JNI_OnLoad, writes the notes to CPW_DIR:
 * cpw_<pid>.log (stops at CPW_LOG_MAX) and status.<pid> (for the app). No personal data: stream
 * settings, timings and levels only.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <link.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

/* EQ on CarPlay's music (0.7.3): EQ Engine's own filter, the same code as in the audio server
   (eqengine.c without the audio effect's entry points and the converter tables) */
#define EQE_CORE_ONLY 1
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#include "eqengine.c"
#pragma GCC diagnostic pop
#undef LOGI
#undef LOGW
#undef TAG
#include "cpeq.h"

#ifdef __ANDROID__
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "EQECPW", __VA_ARGS__)
#else
#define LOGI(...) ((void)0)
#endif

#ifndef CPW_DIR
#define CPW_DIR "/data/eqengine/cpw"
#endif
#ifndef CPW_TINYALSA
#define CPW_TINYALSA "libtinyalsa.so"
#endif
#ifndef CPW_WINDOW_MS
#define CPW_WINDOW_MS 30000
#endif
#ifndef CPW_TICK_MS
#define CPW_TICK_MS 1000
#endif
#ifndef CPW_LOG_MAX
#define CPW_LOG_MAX (512 * 1024)
#endif
/* the unchanged copy of the car's libCarPlayAndroid.so (act.sh copies it; another file name, so the
   linker does not take it for this library, which it knows as libCarPlayAndroid.so) */
#ifndef CPS_COPY
#define CPS_COPY "/data/eqengine/lib/libCarPlayAndroid.car.so"
#endif
/* the library whose TinyALSA imports are watched */
#ifndef CPS_TARGET
#define CPS_TARGET "libCarPlayAudio.so"
#endif
/* EQ on CarPlay's music: the app's control file (cpeq.h), EQ Engine turned off, the control tick */
#ifndef CPE_CTL
#define CPE_CTL "/data/eqengine/share/cp_eq.bin"
#endif
#ifndef CPE_OFF
#define CPE_OFF "/data/eqengine/state/disabled"
#endif
#ifndef CPE_TICK_MS
#define CPE_TICK_MS 100
#endif
#define OBUF_FRAMES 4096        /* the processed audio's buffer (CarPlay writes 1024 frames at a time) */
#define CPW_VERSION 3
#define MAX_STREAMS 64
#define NDONE 8
#define NEVENTS 32
#define EVLEN 360
#define NREAL 7

#define EXPORT __attribute__((visibility("default")))

struct pcm; /* TinyALSA's own, never looked into */

/* Android 4.4's struct pcm_config (external/tinyalsa, android-4.4.2_r1); only read, never written */
struct pcm_config {
    unsigned int channels;
    unsigned int rate;
    unsigned int period_size;
    unsigned int period_count;
    int format; /* 0 S16_LE, 1 S32_LE, 2 S8, 3 S24_LE (in 32 bits) */
    unsigned int start_threshold;
    unsigned int stop_threshold;
    unsigned int silence_threshold;
    int avail_min;
};
#define PCM_IN 0x10000000u

typedef struct pcm *(*open_fn)(unsigned int, unsigned int, unsigned int, struct pcm_config *);
typedef int (*close_fn)(struct pcm *);
typedef int (*write_fn)(struct pcm *, const void *, unsigned int);
typedef int (*read_fn)(struct pcm *, void *, unsigned int);
typedef int (*ready_fn)(struct pcm *);
typedef const char *(*error_fn)(struct pcm *);
typedef unsigned int (*bufsize_fn)(struct pcm *);

/* the pass-through functions: not exported (nothing finds them by name; libCarPlayAudio.so's import
   table is pointed at them) */
static struct pcm *w_open(unsigned int card, unsigned int device, unsigned int flags, struct pcm_config *config);
static int w_close(struct pcm *pcm);
static int w_write(struct pcm *pcm, const void *data, unsigned int count);
static int w_read(struct pcm *pcm, void *data, unsigned int count);
EXPORT int JNI_OnLoad(void *vm, void *reserved);
EXPORT int eqe_cpw_check(const char *copy, char *msg, int len);

/* ------------------------------------------------------------------ the car's TinyALSA */

static open_fn r_open;
static close_fn r_close;
static write_fn r_write;
static read_fn r_read;
static ready_fn r_is_ready;
static error_fn r_get_error;
static bufsize_fn r_get_buffer_size;
static int g_found;
static char g_missing[200];
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void *sym(void *h, const char *name, void *self) {
    void *p = dlsym(h, name);
    /* never this library's own function: that would call itself */
    if (p == self) p = NULL;
    if (p != NULL) {
        g_found++;
    } else {
        size_t n = strlen(g_missing);
        snprintf(g_missing + n, sizeof(g_missing) - n, "%s%s", n ? " " : "", name);
    }
    return p;
}

static void resolve(void) {
    void *h = dlopen(CPW_TINYALSA, RTLD_NOW);
    if (h == NULL) {
        const char *e = dlerror();
        snprintf(g_missing, sizeof(g_missing), "%s did not load: %s", CPW_TINYALSA, e ? e : "?");
        return;
    }
    void *p;
    p = sym(h, "pcm_open", (void *)w_open);
    memcpy(&r_open, &p, sizeof(p));
    p = sym(h, "pcm_close", (void *)w_close);
    memcpy(&r_close, &p, sizeof(p));
    p = sym(h, "pcm_write", (void *)w_write);
    memcpy(&r_write, &p, sizeof(p));
    p = sym(h, "pcm_read", (void *)w_read);
    memcpy(&r_read, &p, sizeof(p));
    p = sym(h, "pcm_is_ready", NULL);
    memcpy(&r_is_ready, &p, sizeof(p));
    p = sym(h, "pcm_get_error", NULL);
    memcpy(&r_get_error, &p, sizeof(p));
    p = sym(h, "pcm_get_buffer_size", NULL);
    memcpy(&r_get_buffer_size, &p, sizeof(p));
}

static inline void need(void) {
    pthread_once(&g_once, resolve);
}

/* ------------------------------------------------------------------ clocks */

static uint64_t now_us(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000u + (uint64_t)(t.tv_nsec / 1000);
}

/* "13:05:01.234 up 512.3": the wall clock (as in the system log) and the uptime (as in act.sh) */
static void stamp(char *b, size_t n) {
    struct timespec r, u;
    struct tm tm;
    clock_gettime(CLOCK_REALTIME, &r);
#ifdef CLOCK_BOOTTIME
    if (clock_gettime(CLOCK_BOOTTIME, &u) != 0)
#endif
        clock_gettime(CLOCK_MONOTONIC, &u);
    time_t s = r.tv_sec;
    localtime_r(&s, &tm);
    snprintf(b, n, "%02d:%02d:%02d.%03ld up %ld.%ld", tm.tm_hour, tm.tm_min, tm.tm_sec, r.tv_nsec / 1000000,
             (long)u.tv_sec, u.tv_nsec / 100000000);
}

/* ------------------------------------------------------------------ streams */

struct win {
    uint64_t t0;      /* start of the window's first call (us) */
    uint64_t t1;      /* end of its last call */
    uint64_t ts_prev; /* start of its last call */
    uint64_t frames;
    uint64_t fr_prev; /* frames before the last call: frames per second = fr_prev / (ts_prev - t0) */
    uint64_t gap_sum, dur_sum;
    uint32_t calls, errs, gaps, last_err;
    uint32_t gap_min, gap_max, dur_min, dur_max;
    uint32_t full; /* samples at full scale (16-bit streams) */
    int32_t peak;  /* largest sample magnitude (16-bit streams), -1 = not measured */
    int closed;
    /* EQ (0.7.3), for a processed stream: time in the filter, the output's peak, the clip guard */
    uint64_t eq_ns;
    uint32_t eq_calls, eq_max;
    int32_t out_peak, min_gain; /* min_gain x 10000, 10000 = idle */
    /* 0.7.6: the time writes waited for g_eq_lock (the settings thread holding it), apart from eq_ns */
    uint64_t wait_ns;
    uint32_t wait_max;
};

struct stream {
    struct pcm *pcm; /* set when opened, NULL once closed (atomic) */
    int closing;     /* 0.7.6: its close is under way: the slot is not reused until it is done (atomic) */
    int id;
    unsigned int card, device, flags, bufsize;
    struct pcm_config cfg;
    unsigned int bpf; /* bytes per frame, 0 = unknown format */
    int tid;
    char thread[20];
    uint64_t opened;
    uint64_t last_start; /* atomic */
    struct win cur;      /* the calling thread's */
    struct win done[NDONE];
    uint32_t done_seq; /* windows finished (atomic) */
    uint32_t read_seq; /* the logger's */
    uint64_t total_calls, total_frames, total_errs;
    struct win last;   /* the logger's: the newest finished window */
    int has_last;
    int proc;          /* CarPlay's music, through the EQ (set at the open) */
    int mic;           /* a microphone stream (Siri or a call) */
    int why;           /* an untouched output stream: why (CPE_WHY_*) */
    /* a processed block TinyALSA refused, kept until the next write (the writing thread's own) */
    int retry;
    const void *retry_src;
    unsigned int retry_count;
    uint32_t retry_hash;
};

/* FNV-1a over a block, to tell a retried block from new samples in the same buffer */
static uint32_t block_hash(const void *data, unsigned int n) {
    const unsigned char *p = (const unsigned char *)data;
    uint32_t h = 2166136261u;
    for (unsigned int i = 0; i < n; i++) h = (h ^ p[i]) * 16777619u;
    return h;
}

static struct stream g_st[MAX_STREAMS];
static int g_nst; /* slots used (atomic) */
/* streams opened so far (each stream's number). Every pause closes CarPlay's stream and the next play
   opens a new one (10 in 8 minutes in the 0.6.9 test), so once the table is full a closed stream's
   slot is used again (0.7.3), after its notes are written: the EQ keeps working on a long drive.
   The logger and the status read the slots under g_lock only. */
static int g_ids;
static uint32_t g_untracked, g_full_table;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
/* what JNI_OnLoad did, for the status file: "loading", "watching" (imports pointed here),
   "not watching" (the factory library runs, the imports were left alone) or "failed" (the factory
   library did not load: CarPlay does not work in this start of the app) */
static const char *volatile g_state = "loading";
static int g_slots, g_slots_want;   /* imports pointed here, of those found */
static int g_hmgapi = -1;           /* HMG-API's hook library is in this process: 1, 0, -1 not known */

static struct stream *find(struct pcm *p) {
    if (p == NULL) return NULL;
    int n = __atomic_load_n(&g_nst, __ATOMIC_ACQUIRE);
    for (int i = n - 1; i >= 0; i--) {
        if (__atomic_load_n(&g_st[i].pcm, __ATOMIC_ACQUIRE) == p) return &g_st[i];
    }
    return NULL;
}

static unsigned int bytes_per_frame(const struct pcm_config *c) {
    unsigned int b;
    switch (c->format) {
    case 0: b = 2; break;
    case 1: b = 4; break;
    case 2: b = 1; break;
    case 3: b = 4; break;
    default: return 0;
    }
    return c->channels > 0 && c->channels <= 32 ? b * c->channels : 0;
}

static const char *fmt_name(int f) {
    switch (f) {
    case 0: return "s16";
    case 1: return "s32";
    case 2: return "s8";
    case 3: return "s24";
    default: return "format?";
    }
}

static void scan16(const void *data, unsigned int bytes, int32_t *peak, uint32_t *full) {
    const int16_t *x = (const int16_t *)data;
    unsigned int n = bytes / 2;
    int32_t m = 0;
    uint32_t f = 0;
    for (unsigned int i = 0; i < n; i++) {
        int32_t v = x[i];
        if (v < 0) v = -v;
        if (v > m) m = v;
        if (v >= 32767) f++;
    }
    *peak = m;
    *full = f;
}

static void win_reset(struct win *w) {
    memset(w, 0, sizeof(*w));
    w->gap_min = w->dur_min = UINT32_MAX;
    w->peak = -1;
    w->out_peak = -1;
    w->min_gain = 10000;
}

/* the calling thread finishes its window: the logger picks it up */
static void roll(struct stream *s, int closed) {
    uint32_t q = __atomic_load_n(&s->done_seq, __ATOMIC_RELAXED);
    s->cur.closed = closed;
    s->done[q % NDONE] = s->cur;
    __atomic_store_n(&s->done_seq, q + 1, __ATOMIC_RELEASE);
    win_reset(&s->cur);
}

static uint32_t clamp32(uint64_t v) {
    return v > UINT32_MAX ? UINT32_MAX : (uint32_t)v;
}

static void account(struct stream *s, uint64_t t0, uint64_t t1, unsigned int count, int rc, int32_t peak, uint32_t full) {
    struct win *w = &s->cur;
    if (w->calls > 0 && t0 - w->t0 >= (uint64_t)CPW_WINDOW_MS * 1000u) roll(s, 0);
    if (w->calls == 0) w->t0 = t0;
    uint64_t ls = __atomic_load_n(&s->last_start, __ATOMIC_RELAXED);
    if (ls != 0 && t0 >= ls) {
        uint32_t g = clamp32(t0 - ls);
        if (g < w->gap_min) w->gap_min = g;
        if (g > w->gap_max) w->gap_max = g;
        w->gap_sum += g;
        w->gaps++;
    }
    __atomic_store_n(&s->last_start, t0, __ATOMIC_RELAXED);
    uint32_t d = clamp32(t1 - t0);
    if (d < w->dur_min) w->dur_min = d;
    if (d > w->dur_max) w->dur_max = d;
    w->dur_sum += d;
    w->ts_prev = t0;
    w->fr_prev = w->frames;
    w->calls++;
    w->t1 = t1;
    s->total_calls++;
    if (rc < 0) {
        w->errs++;
        w->last_err = (uint32_t)-rc;
        s->total_errs++;
    } else if (s->bpf) {
        w->frames += count / s->bpf;
        s->total_frames += count / s->bpf;
    }
    if (peak > w->peak) w->peak = peak;
    w->full += full;
}

/* ------------------------------------------------------------------ events for the log */

static char g_ev[NEVENTS][EVLEN];
static int g_ev_head, g_ev_tail;
static uint32_t g_ev_lost;

/* under g_lock */
static void event_l(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void event_l(const char *fmt, ...) {
    if ((g_ev_head + 1) % NEVENTS == g_ev_tail) {
        g_ev_lost++;
        return;
    }
    char *b = g_ev[g_ev_head];
    stamp(b, EVLEN);
    size_t n = strlen(b);
    b[n++] = ' ';
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b + n, EVLEN - n, fmt, ap);
    va_end(ap);
    g_ev_head = (g_ev_head + 1) % NEVENTS;
}

static void thread_name(int tid, char *b, size_t n) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/self/task/%d/comm", tid);
    b[0] = 0;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    ssize_t r = read(fd, b, n - 1);
    close(fd);
    if (r <= 0) {
        b[0] = 0;
        return;
    }
    b[r] = 0;
    for (ssize_t i = 0; i < r; i++) {
        if (b[i] == '\n' || b[i] < ' ' || b[i] > '~') b[i] = b[i] == '\n' ? 0 : '?';
    }
}

/* ------------------------------------------------------------------ EQ on CarPlay's music (0.7.3)
 *
 * CarPlay's music stream (the main link, card 0 device 2, 44.1 or 48 kHz 16-bit stereo) goes
 * through EQ Engine's own filter (eqengine.c's process_frames: the same EQ, preamp, clip guard and
 * seat delay as in the audio server), with the settings the app writes to CPE_CTL. The filter
 * writes into this library's own buffer, and that buffer is what goes to TinyALSA: the app's
 * samples are never written to. Added delay: the clip guard's 63-sample look-ahead (1.4 ms at
 * 44.1 kHz), plus the seat delay when one is set. Nothing is converted: CarPlay plays at its rate.
 *
 * Untouched (the original buffer is handed on): every other stream (Siri and calls at 24, 16 and
 * 8 kHz, the microphone), and the music too when the app's switch is off, no settings have come
 * from it, or EQ Engine is turned off. While a microphone stream is open (Siri or a call), the
 * music being processed goes dry (bit-exact, still with the 63-sample delay) until it closes. A
 * change while a stream plays crossfades (the filter's own ramps); a stream that opened untouched
 * stays so until its next open (a pause, the next track).
 *
 * A thread of its own (eqe-cpweq) reads the control file every CPE_TICK_MS, checks it as the audio
 * server's filter checks its settings, and applies it under g_eq_lock, which the audio thread
 * takes around each buffer's processing (never around the TinyALSA write). It also maps
 * CPW_DIR/live.bin, where the audio thread puts each buffer's level, the processing time and the
 * live view (cpeq.h's cpl_live), for the app's meter, live view and Status. */

static void note(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void sleep_ms(int ms);

static pthread_mutex_t g_eq_lock = PTHREAD_MUTEX_INITIALIZER;
static eqe_ctx g_eq;                /* the filter of the one processed stream (under g_eq_lock) */
static int g_eq_init;
static struct stream *g_proc;       /* the processed stream, or NULL */
static struct stream *g_pass;       /* an untouched stream on the main link, or NULL */
static int g_mics;                  /* microphone streams open */
static eqe_settings g_set;          /* the app's last valid settings */
static int g_set_ok, g_on, g_off;   /* valid settings now; the app's switch; EQ Engine turned off */
static uint32_t g_ctl_seq;
static int16_t g_obuf[OBUF_FRAMES * 2];
static cpl_live *g_live;            /* the live file, mapped; NULL if it could not be made */
static int64_t g_sec_t0, g_sec_ns;  /* the per-second processing numbers for the live file */
static uint32_t g_sec_n;
static int32_t g_sec_max, g_pub_avg, g_pub_max, g_pub_min = 10000;
static pthread_once_t g_eq_once = PTHREAD_ONCE_INIT;

static const char *why_text(int why) {
    switch (why) {
    case CPE_WHY_SWITCH: return "EQ on CarPlay is switched off in the app";
    case CPE_WHY_NOSET: return "no settings from the EQ Engine app yet";
    case CPE_WHY_OFF: return "EQ Engine is turned off";
    case CPE_WHY_FORMAT: return "not CarPlay's music stream (that is 44.1 or 48 kHz 16-bit stereo on the main link)";
    case CPE_WHY_MIC: return "a microphone stream is open (Siri or a call)";
    case CPE_WHY_STARTED: return "it opened while the EQ was off; it gets the EQ from its next open";
    default: return "processed";
    }
}

/* under g_eq_lock: why the music would not be processed now (CPE_WHY_NONE: it would) */
static int eq_why(void) {
    if (g_off) return CPE_WHY_OFF;
    if (!g_set_ok) return CPE_WHY_NOSET;
    if (!g_on) return CPE_WHY_SWITCH;
    return CPE_WHY_NONE;
}

/* the settings in one line, for the notes */
static void set_desc(const eqe_settings *s, char *b, size_t n) {
    if (s->mode == 1)
        snprintf(b, n, "Expert, %d bands, preamp %.1f dB, EQ %s, clip guard %s", s->nx, s->preamp_cdb / 100.0,
                 s->eq_on ? "on" : "off", s->guard_on ? "on" : "off");
    else
        snprintf(b, n, "Easy, preamp %.1f dB, EQ %s, clip guard %s", s->preamp_cdb / 100.0, s->eq_on ? "on" : "off",
                 s->guard_on ? "on" : "off");
    if (s->delay_us[0] || s->delay_us[1]) {
        size_t l = strlen(b);
        snprintf(b + l, n - l, ", seat delay L %d R %d us", s->delay_us[0], s->delay_us[1]);
    }
}

/* ---- the live file (written under g_eq_lock only, so there is one writer at a time) */

/* the live file mapped now (its device and inode), for live_check (the settings thread only) */
static dev_t g_live_dev;
static ino_t g_live_ino;
static void live_state(void);

/* Makes and maps CPW_DIR/live.bin with its header filled in; NULL if it cannot be made now. */
static cpl_live *live_map(void) {
    int fd = open(CPW_DIR "/live.bin", O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) return NULL;
    fchmod(fd, 0644); /* apps run with umask 077; the EQ Engine app reads this */
    struct stat st;
    if (ftruncate(fd, CPL_BYTES) != 0 || fstat(fd, &st) != 0) {
        close(fd);
        return NULL;
    }
    void *m = mmap(NULL, CPL_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return NULL;
    cpl_live *L = (cpl_live *)m;
    uint32_t q = __atomic_load_n(&L->seq, __ATOMIC_RELAXED) | 1u;
    __atomic_store_n(&L->seq, q, __ATOMIC_RELEASE);
    __atomic_thread_fence(__ATOMIC_RELEASE);
    memset((char *)L + sizeof(L->magic) + sizeof(L->version) + sizeof(L->seq), 0,
           sizeof(*L) - sizeof(L->magic) - sizeof(L->version) - sizeof(L->seq));
    L->magic = (int32_t)CPL_MAGIC;
    L->version = CPL_VERSION;
    L->pid = (int32_t)getpid();
    L->lib = EQE_LIB_VERSION;
    L->min_gain = 10000;
    __atomic_thread_fence(__ATOMIC_RELEASE);
    __atomic_store_n(&L->seq, q + 1, __ATOMIC_RELEASE);
    g_live_dev = st.st_dev;
    g_live_ino = st.st_ino;
    return L;
}

/* After 0.7.6: an update of EQ Engine deletes /data/eqengine while the CarPlay app runs the layer,
   and the app then reads a live file that is not this one. About once a second the settings thread
   checks that CPW_DIR/live.bin is still the file mapped here, and maps a new one when it is gone or
   replaced (the audio thread writes it only under g_eq_lock, so the swap is made under it). */
static void live_check(void) {
    struct stat st;
    if (g_live != NULL && stat(CPW_DIR "/live.bin", &st) == 0 && st.st_dev == g_live_dev && st.st_ino == g_live_ino)
        return;
    /* not while EQ Engine is marked off: an uninstall writes that before it deletes /data/eqengine,
       and a file made meanwhile would be left behind (an update's install takes the mark away) */
    if (access(CPE_OFF, F_OK) == 0) return;
    cpl_live *L = live_map();
    if (L == NULL) return; /* (the folder is not there yet: tried again in a second) */
    pthread_mutex_lock(&g_eq_lock);
    cpl_live *old = g_live;
    g_live = L;
    live_state();
    pthread_mutex_unlock(&g_eq_lock);
    if (old != NULL) {
        munmap(old, CPL_BYTES);
        note("EQ: the live file was made again (the one in %s had been removed: EQ Engine updated?)", CPW_DIR);
    } else {
        note("EQ: the live file was made");
    }
}

static void live_begin(void) {
    __atomic_store_n(&g_live->seq, __atomic_load_n(&g_live->seq, __ATOMIC_RELAXED) + 1, __ATOMIC_RELEASE);
    __atomic_thread_fence(__ATOMIC_RELEASE);
}

static void live_end(void) {
    __atomic_thread_fence(__ATOMIC_RELEASE);
    __atomic_store_n(&g_live->seq, __atomic_load_n(&g_live->seq, __ATOMIC_RELAXED) + 1, __ATOMIC_RELEASE);
}

/* under g_eq_lock: the state as it is now */
static void live_state(void) {
    if (g_live == NULL) return;
    live_begin();
    if (g_proc != NULL) {
        g_live->state = CPL_PROCESSING;
        g_live->why = g_mics > 0 ? CPE_WHY_MIC : eq_why();
        g_live->rate = (int32_t)g_proc->cfg.rate;
    } else if (g_pass != NULL) {
        g_live->state = CPL_PASSING;
        g_live->why = g_pass->why;
        g_live->rate = (int32_t)g_pass->cfg.rate;
    } else {
        g_live->state = CPL_IDLE;
        g_live->why = eq_why();
        g_live->rate = 0;
    }
    g_live->ctl_seq = (int32_t)g_ctl_seq;
    live_end();
}

/* ---- the filter */

/* under g_eq_lock: the processed stream's settings as they should be now (dry while a microphone is
   open, or when the EQ was switched off or the settings went away: the last ones stay, EQ off) */
static uint32_t g_applies; /* 0.7.6: settings applied to the filter (status eq_applies=), for the tests */
static void eq_apply(int jump) {
    eqe_ctx *c = &g_eq;
    __atomic_add_fetch(&g_applies, 1, __ATOMIC_RELAXED);
    eqe_settings s = g_set_ok ? g_set : c->set;
    if (eq_why() != CPE_WHY_NONE || g_mics > 0) s.eq_on = 0;
    c->set = s;
    apply_settings(c, jump);
}

/* the filter as the audio server's lib_create makes it (once, from whichever thread is first) */
static void eq_init(void) {
    eqe_ctx *c = &g_eq;
    for (int j = 0; j < EQE_NBAND; j++) c->band[j].cur = c->band[j].tgt = kIdentity;
    c->pre_cur = c->pre_tgt = 1.0;
    c->w_step = 1.0 / XFADE_LEN;
    c->min_gain = 1.0;
    c->rng = 0x9e3779b9u ^ (uint32_t)(uintptr_t)c;
    if (c->rng == 0) c->rng = 1;
    c->magic = EQE_MAGIC;
    c->enabled = 1;
    c->cfg_ok = 1;
    reset_guard(c);
    g_eq_init = 1;
}

/* under g_eq_lock: a new music stream at this rate (as the audio server's filter at a new start:
   clean states, the EQ at once at its setting) */
static void eq_start(unsigned int rate) {
    eqe_ctx *c = &g_eq;
    pthread_once(&g_eq_once, eq_init);
    c->set = g_set;
    if (eq_why() != CPE_WHY_NONE || g_mics > 0) c->set.eq_on = 0;
    if (c->rate != (double)rate) {
        c->rate = (double)rate;
        prepare_rate(c);
    }
    apply_settings(c, 1);
    reset_states(c);
    reset_guard(c);
    c->w = c->w_tgt;
    c->pre_cur = c->pre_tgt;
    c->processing = c->w_tgt > 0.0;
    c->spec_running = 0;
    g_sec_t0 = 0;
    g_sec_ns = 0;
    g_sec_n = 0;
    g_sec_max = 0;
}

/* under g_eq_lock, in the audio thread: n frames from src into dst, the live view, the live file.
   Returns the clip guard's lowest gain in this buffer (x 10000). */
static int32_t eq_block(const int16_t *src, int16_t *dst, unsigned int n, int64_t t0) {
    eqe_ctx *c = &g_eq;
    spec_t *sp = c->spec != NULL && t0 - c->spec_wanted_ns < SPEC_KEEP_NS ? c->spec : NULL;
    if (sp != NULL && !c->spec_running) {
        sp->filled = 0;
        sp->fresh = 0;
    }
    c->spec_running = sp != NULL;
    double mg0 = c->min_gain;
    c->min_gain = 1.0;
    process_frames(c, src, dst, n, 0, sp);
    double mgb = c->min_gain;
    if (mg0 < c->min_gain) c->min_gain = mg0;
    int analysed = 0;
    if (sp != NULL && sp->filled >= SPEC_N && sp->fresh >= SPEC_M) {
        spec_analyse(sp, c->rate, t0);
        analysed = 1;
    }
    int64_t t1 = now_ns();
    c->blk_ns = t1;
    int64_t dt = t1 - t0;
    if (dt < 0) dt = 0;
    if (dt > 0x7fffffff) dt = 0x7fffffff;
    if (g_sec_t0 == 0) g_sec_t0 = t1;
    g_sec_ns += dt;
    g_sec_n++;
    if ((int32_t)dt > g_sec_max) g_sec_max = (int32_t)dt;
    if (t1 - g_sec_t0 >= 1000000000LL) {
        g_pub_avg = (int32_t)(g_sec_ns / g_sec_n);
        g_pub_max = g_sec_max;
        g_pub_min = (int32_t)(c->min_gain * 10000.0 + 0.5);
        g_sec_t0 = t1;
        g_sec_ns = 0;
        g_sec_n = 0;
        g_sec_max = 0;
        c->min_gain = 1.0;
    }
    if (g_live != NULL) {
        live_begin();
        g_live->state = CPL_PROCESSING;
        g_live->why = g_mics > 0 ? CPE_WHY_MIC : eq_why();
        g_live->rate = (int32_t)c->rate;
        g_live->frames = (int32_t)n;
        g_live->blk_seq = c->blk_seq;
        g_live->blk_ms = (int32_t)(t1 / 1000000LL);
        g_live->blk_peak = c->blk_peak;
        g_live->blk_rms = rms_cdb(c->blk_ss, c->blk_frames);
        g_live->avg_ns = g_pub_avg ? g_pub_avg : (int32_t)dt;
        g_live->max_ns = g_pub_max ? g_pub_max : (int32_t)dt;
        g_live->min_gain = g_pub_min;
        g_live->limited = c->limited;
        g_live->clipped = c->clipped;
        g_live->in_clip = c->in_clip_total;
        g_live->ctl_seq = (int32_t)g_ctl_seq;
        if (analysed) {
            g_live->spec_seq = sp->seq;
            g_live->spec_ms = (int32_t)(sp->at_ns / 1000000LL);
            memcpy(g_live->spec, sp->lvl, sizeof(g_live->spec));
        }
        live_end();
    }
    return (int32_t)(mgb * 10000.0 + 0.5);
}

/* ---- the control thread */

static int read_ctl(int32_t *b, size_t n) {
    int fd = open(CPE_CTL, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, (char *)b + got, n - got);
        if (r <= 0) break;
        got += (size_t)r;
    }
    char extra;
    ssize_t more = read(fd, &extra, 1);
    close(fd);
    return got == n && more == 0;
}

/* After 0.7.6: what the app's Auto (EQE_PARAM_PEAK) and Copy Easy EQ (EQE_PARAM_GAINS) ask Android's
   filter, worked out here for settings s, so both also work while CarPlay's EQ is the only one the
   app can reach (Android's filter not loaded in this start). In the settings thread, outside
   g_eq_lock: the same code as the audio server's filter, on a scratch context (the rate and the
   solver's matrix only). The gains are for the stream's rate, or 44.1 kHz (CarPlay's music) before
   one opened. 0 = done. */
static int eq_answers(const eqe_settings *s, int32_t rate, int32_t peak[3], int32_t gains[EQE_NB]) {
    eqe_ctx *t = (eqe_ctx *)calloc(1, sizeof(eqe_ctx));
    if (t == NULL) return -1;
    t->rate = rate > 0 ? (double)rate : 44100.0;
    int r = peak_query(t, s, peak);
    for (int j = 0; j < EQE_NB; j++) gains[j] = 0;
    if (r == 0 && s->mode == 0) {
        t->set = *s;
        t->design_ends = 0;
        prepare_matrix(t);
        double g[EQE_NB];
        solve_gains(t, g);
        for (int j = 0; j < EQE_NB; j++) gains[j] = (int32_t)floor(g[j] * 100.0 + 0.5);
    }
    free(t);
    return r;
}

static void *eq_thread(void *arg) {
    (void)arg;
    prctl(PR_SET_NAME, (unsigned long)"eqe-cpweq", 0, 0, 0);
    pthread_once(&g_eq_once, eq_init);
    cpl_live *L0 = live_map();
    pthread_mutex_lock(&g_eq_lock);
    g_live = L0;
    live_state();
    pthread_mutex_unlock(&g_eq_lock);
    if (L0 == NULL) note("EQ: the live file (%s/live.bin) could not be made: the app shows no CarPlay levels", CPW_DIR);
    int ticks = 0;
    eqe_settings ans_set, ans_pend;
    int ans_have = 0, ans_dirty = 0;
    int64_t ans_since = 0;
    int32_t ans_pk[3] = {0, 0, 0}, ans_g[EQE_NB] = {0}, ans_rate = 0;
    uint32_t ans_written = 0;
    memset(&ans_set, 0, sizeof(ans_set));
    memset(&ans_pend, 0, sizeof(ans_pend));
    int64_t last_note = 0;
    int was_ok = -1, was_on = -1, was_off = -1;
    uint32_t noted_seq = 0;
    char noted_desc[200] = "";
    for (;;) {
        int32_t b[CPE_HDR + CPE_NSET];
        eqe_settings s;
        int ok = read_ctl(b, sizeof(b)) && (uint32_t)b[0] == CPE_MAGIC && b[1] == CPE_VERSION &&
                 settings_from((const char *)(b + CPE_HDR), (uint32_t)sizeof(eqe_settings), &s);
        int off = access(CPE_OFF, F_OK) == 0;
        int64_t now = now_ns();
        int live = ok && (int32_t)(b[4] - (int32_t)(now / 1000000LL)) > 0;
        /* the live view's buffers are made here, never in the audio thread (only this thread sets spec) */
        spec_t *fresh = live && g_eq.spec == NULL ? spec_new() : NULL;
        pthread_mutex_lock(&g_eq_lock);
        if (fresh != NULL) g_eq.spec = fresh;
        if (live) g_eq.spec_wanted_ns = now;
        int on = ok ? b[3] != 0 : g_on;
        /* 0.7.6: what the settings say, not their number: the app writes the file again every second
           while the live view is shown (a new seq, the same settings), and each of those used to
           redesign every band under the lock */
        int seqnew = ok && (uint32_t)b[2] != g_ctl_seq;
        int changed = ok != g_set_ok || off != g_off || on != g_on || (ok && memcmp(&s, &g_set, sizeof(s)) != 0);
        int before = eq_why();
        if (ok) {
            g_set = s;
            g_ctl_seq = (uint32_t)b[2];
        }
        g_set_ok = ok;
        g_on = on;
        g_off = off;
        if (changed) {
            if (g_proc != NULL) eq_apply(0);
            /* an untouched stream that opened while the EQ was off gets it from its next open */
            if (g_pass != NULL && g_pass->why != CPE_WHY_FORMAT && before != CPE_WHY_NONE && eq_why() == CPE_WHY_NONE)
                g_pass->why = CPE_WHY_STARTED;
            live_state();
        } else if (seqnew) {
            live_state(); /* the seq in use, for the app */
        }
        int why = eq_why();
        int procs = g_proc != NULL;
        int32_t srate = g_proc != NULL ? (int32_t)g_proc->cfg.rate : 0;
        pthread_mutex_unlock(&g_eq_lock);
        /* after 0.7.6: Auto's and Copy Easy EQ's answers for these settings, worked out again only when
           what the settings say (or the stream's rate) changed, and only once they have stayed so
           for 300 ms (not for every step of a slider being dragged); their seq follows every new
           write while they hold */
        int need = ok && (!ans_have || memcmp(&s, &ans_set, sizeof(s)) != 0 || (srate > 0 && srate != ans_rate));
        if (need) {
            if (!ans_dirty || memcmp(&s, &ans_pend, sizeof(s)) != 0) {
                ans_pend = s;
                ans_since = now;
                ans_dirty = 1;
            }
            if (now - ans_since >= 300000000LL) {
                int32_t rt = srate > 0 ? srate : (ans_rate > 0 ? ans_rate : 44100);
                ans_have = eq_answers(&ans_pend, rt, ans_pk, ans_g) == 0;
                ans_set = ans_pend;
                ans_rate = rt;
                ans_written = 0;
                ans_dirty = 0;
            }
        } else {
            ans_dirty = 0;
        }
        if (ok && ans_have && memcmp(&s, &ans_set, sizeof(s)) == 0 && (uint32_t)b[2] != ans_written) {
            pthread_mutex_lock(&g_eq_lock);
            if (g_live != NULL) {
                live_begin();
                memcpy(g_live->ans_peak, ans_pk, sizeof(g_live->ans_peak));
                g_live->ans_rate = ans_rate;
                memcpy(g_live->ans_gains, ans_g, sizeof(g_live->ans_gains));
                g_live->ans_seq = b[2];
                live_end();
                ans_written = (uint32_t)b[2];
            }
            pthread_mutex_unlock(&g_eq_lock);
        }
        /* the notes: every change of on, off or valid; settings changes at most every 2 s, and only
           when what they say changed (0.7.4: the app writes the file again every second while the
           live view is shown, with a new seq and the same settings) */
        char d[200];
        if (ok) set_desc(&s, d, sizeof(d));
        else snprintf(d, sizeof(d), "none");
        if (ok != was_ok || on != was_on || off != was_off ||
            (ok && (uint32_t)b[2] != noted_seq && strcmp(d, noted_desc) != 0 && now - last_note >= 2000000000LL)) {
            note("EQ: %s; settings from the app: %s%s", why == CPE_WHY_NONE ? "on for CarPlay's music" : why_text(why), d,
                 procs ? " (applied to the music playing now)" : "");
            was_ok = ok;
            was_on = on;
            was_off = off;
            noted_seq = ok ? (uint32_t)b[2] : 0;
            snprintf(noted_desc, sizeof(noted_desc), "%s", d);
            last_note = now;
        }
        if (++ticks >= 1000 / CPE_TICK_MS) {
            ticks = 0;
            cpl_live *was = g_live; /* (only this thread changes g_live) */
            live_check();
            if (g_live != was) ans_written = 0; /* a new live file gets the answers again */
        }
        sleep_ms(CPE_TICK_MS);
    }
    return NULL;
}

static pthread_once_t g_eqt_once = PTHREAD_ONCE_INIT;
static void start_eq(void) {
    pthread_attr_t a;
    pthread_t t;
    pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    pthread_create(&t, &a, eq_thread, NULL);
    pthread_attr_destroy(&a);
}

/* ------------------------------------------------------------------ the logger thread */

static char g_name[96];
static int g_logfd = -1;
static long g_logged;
static int g_logfull;
static uint64_t g_since;
static pthread_once_t g_log_once = PTHREAD_ONCE_INIT;

static void process_name(void) {
    char b[512];
    int fd = open("/proc/self/cmdline", O_RDONLY | O_CLOEXEC);
    ssize_t r = fd >= 0 ? read(fd, b, sizeof(b) - 1) : -1;
    if (fd >= 0) close(fd);
    if (r <= 0) {
        snprintf(g_name, sizeof(g_name), "?");
        return;
    }
    b[r] = 0;
    /* a wrapped start that has not set its name yet: "... --nice-name=<name> ..." */
    for (ssize_t i = 0; i < r; i += (ssize_t)strlen(b + i) + 1) {
        if (strncmp(b + i, "--nice-name=", 12) == 0) {
            snprintf(g_name, sizeof(g_name), "%.95s", b + i + 12);
            return;
        }
    }
    snprintf(g_name, sizeof(g_name), "%.95s", b);
}

static void log_write(const char *line) {
    if (g_logfull) return;
    if (g_logfd < 0) {
        char path[160];
        snprintf(path, sizeof(path), CPW_DIR "/cpw_%d.log", (int)getpid());
        g_logfd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
        if (g_logfd < 0) return;
        fchmod(g_logfd, 0644); /* apps run with umask 077; act.sh and the EQ Engine app read this */
    }
    size_t n = strlen(line);
    if (g_logged + (long)n + 1 > CPW_LOG_MAX) {
        const char *full = "log full: nothing more is written here\n";
        if (write(g_logfd, full, strlen(full)) < 0) { /* nothing to be done */ }
        g_logfull = 1;
        return;
    }
    if (write(g_logfd, line, n) < 0 || write(g_logfd, "\n", 1) < 0) return;
    g_logged += (long)n + 1;
}

static double db(int32_t peak) {
    return peak <= 0 ? -120.0 : 20.0 * log10((double)peak / 32768.0);
}

static void stream_desc(const struct stream *s, char *b, size_t n) {
    snprintf(b, n, "card %u device %u %s, %u Hz %u ch %s, period %u x %u", s->card, s->device,
             (s->flags & PCM_IN) ? "in" : "out", s->cfg.rate, s->cfg.channels, fmt_name(s->cfg.format),
             s->cfg.period_size, s->cfg.period_count);
}

static void window_line(const struct stream *s, const struct win *w) {
    char st[40], b[EVLEN + 40], pk[48];
    stamp(st, sizeof(st));
    double secs = w->t1 > w->t0 ? (double)(w->t1 - w->t0) / 1e6 : 0;
    double fps = w->ts_prev > w->t0 ? (double)w->fr_prev * 1e6 / (double)(w->ts_prev - w->t0) : 0;
    if (w->peak >= 0)
        snprintf(pk, sizeof(pk), "peak %.1f dBFS, %u at full scale", db(w->peak), w->full);
    else
        snprintf(pk, sizeof(pk), "level not measured");
    const char *what = (s->flags & PCM_IN) ? "reads" : "writes";
    if (w->calls == 0) {
        snprintf(b, sizeof(b), "%s s%d %s: no %s", st, s->id, w->closed ? "closed" : "window", what);
    } else {
        snprintf(b, sizeof(b),
                 "%s s%d %.1f s%s: %u %s, %.0f frames/s, gap %.1f ms avg (min %.1f, max %.1f), in call %.1f ms avg "
                 "(max %.1f), %s, %u errors",
                 st, s->id, secs, w->closed ? " (to its close)" : "", w->calls, what, fps,
                 w->gaps ? (double)w->gap_sum / w->gaps / 1000.0 : 0.0, w->gaps ? w->gap_min / 1000.0 : 0.0,
                 w->gaps ? w->gap_max / 1000.0 : 0.0, (double)w->dur_sum / w->calls / 1000.0, w->dur_max / 1000.0, pk,
                 w->errs);
        if (w->errs) {
            size_t l = strlen(b);
            snprintf(b + l, sizeof(b) - l, " (last: %s)", strerror((int)w->last_err));
        }
        if (w->eq_calls > 0) {
            size_t l = strlen(b);
            char g[40];
            if (w->min_gain >= 9999) snprintf(g, sizeof(g), "idle");
            else snprintf(g, sizeof(g), "down to %.1f dB", 20.0 * log10(w->min_gain / 10000.0));
            snprintf(b + l, sizeof(b) - l, "; EQ %.0f us avg (max %.0f) per write, out peak %.1f dBFS, clip guard %s; "
                     "waited for the settings %.0f us avg (max %.0f)",
                     (double)w->eq_ns / w->eq_calls / 1000.0, w->eq_max / 1000.0, db(w->out_peak), g,
                     (double)w->wait_ns / w->eq_calls / 1000.0, w->wait_max / 1000.0);
        }
    }
    log_write(b);
}

/* the app's status line for one stream: "card=0 device=2 dir=out rate=44100 ch=2 fmt=s16 ..." */
static void status_fields(const struct stream *s, int open_now, uint64_t now, char *b, size_t n) {
    uint64_t ls = __atomic_load_n(&s->last_start, __ATOMIC_RELAXED);
    long ago = ls ? (long)((now - ls) / 1000000u) : -1;
    snprintf(b, n, "card=%u device=%u dir=%s rate=%u ch=%u fmt=%s period=%ux%u state=%s calls=%llu idle_s=%ld",
             s->card, s->device, (s->flags & PCM_IN) ? "in" : "out", s->cfg.rate, s->cfg.channels, fmt_name(s->cfg.format),
             s->cfg.period_size, s->cfg.period_count, open_now ? "open" : "closed", (unsigned long long)s->total_calls, ago);
    if (s->has_last && s->last.calls > 0) {
        const struct win *w = &s->last;
        double fps = w->ts_prev > w->t0 ? (double)w->fr_prev * 1e6 / (double)(w->ts_prev - w->t0) : 0;
        size_t l = strlen(b);
        snprintf(b + l, n - l, " fps=%.0f errs=%u", fps, w->errs);
        if (w->peak >= 0) {
            l = strlen(b);
            snprintf(b + l, n - l, " peak_db=%.1f", db(w->peak));
        }
    }
}

static void write_status(void) {
    char tmp[176], path[160], line[EVLEN];
    snprintf(path, sizeof(path), CPW_DIR "/status.%d", (int)getpid());
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    fchmod(fd, 0644);
    static char b[4096];
    size_t len = 0;
    uint64_t now = now_us();
    /* the slots are read under g_lock (w_open may give a closed one to a new stream); the file is
       written after */
    pthread_mutex_lock(&g_lock);
    int n = __atomic_load_n(&g_nst, __ATOMIC_ACQUIRE), open_n = 0;
    const struct stream *m = NULL;
    for (int i = 0; i < n; i++) {
        int o = __atomic_load_n(&g_st[i].pcm, __ATOMIC_ACQUIRE) != NULL;
        open_n += o;
        if (!(g_st[i].flags & PCM_IN)) {
            /* the stream to show: the newest one on the main link (card 0 device 2), else the newest output */
            int main_i = g_st[i].card == 0 && g_st[i].device == 2, main_m = m != NULL && m->card == 0 && m->device == 2;
            if (m == NULL || (main_i && (!main_m || g_st[i].id > m->id)) || (!main_m && !main_i && g_st[i].id > m->id))
                m = &g_st[i];
        }
    }
    len += (size_t)snprintf(b + len, sizeof(b) - len, "version=%d\npid=%d\nname=%s\nstate=%s\nsince_s=%llu\nstreams=%d\nopen=%d\n"
                            "untracked=%u\nimports=%d of %d\nhmgapi=%s\n", CPW_VERSION, (int)getpid(), g_name, g_state,
                            (unsigned long long)(g_since / 1000000u), g_ids, open_n, __atomic_load_n(&g_untracked, __ATOMIC_RELAXED),
                            g_slots, g_slots_want, g_hmgapi == 1 ? "yes" : g_hmgapi == 0 ? "no" : "?");
    if (m != NULL) {
        status_fields(m, __atomic_load_n(&m->pcm, __ATOMIC_ACQUIRE) != NULL, now, line, sizeof(line));
        len += (size_t)snprintf(b + len, sizeof(b) - len, "main=s%d %s\n", m->id, line);
    }
    /* EQ on CarPlay's music: what happens to the music now, and why when untouched */
    pthread_mutex_lock(&g_eq_lock);
    int why = eq_why(), pid_ = g_proc ? g_proc->id : g_pass ? g_pass->id : 0, mics = g_mics;
    int pwhy = g_pass ? g_pass->why : 0;
    uint32_t cseq = g_ctl_seq;
    int set_ok = g_set_ok, on = g_on, is_proc = g_proc != NULL;
    uint32_t eq_bufs = g_eq.blk_seq;
    pthread_mutex_unlock(&g_eq_lock);
    if (pid_ && is_proc)
        len += (size_t)snprintf(b + len, sizeof(b) - len, "eq=processing s%d%s\n", pid_, mics ? " (dry: the microphone is open)" : "");
    else if (pid_)
        len += (size_t)snprintf(b + len, sizeof(b) - len, "eq=untouched s%d: %s\n", pid_, why_text(pwhy));
    else
        len += (size_t)snprintf(b + len, sizeof(b) - len, "eq=idle: %s\n", why == CPE_WHY_NONE ? "on for the next music stream" : why_text(why));
    len += (size_t)snprintf(b + len, sizeof(b) - len, "eq_switch=%s\neq_settings=%s %u\neq_buffers=%u\nlive=%s\neq_applies=%u\n",
                            on ? "on" : "off", set_ok ? "ok" : "none", cseq, eq_bufs, g_live ? "yes" : "no",
                            __atomic_load_n(&g_applies, __ATOMIC_RELAXED));
    /* the 16 newest streams */
    for (int i = 0; i < n && len < sizeof(b) - EVLEN; i++) {
        if (g_st[i].id <= g_ids - 16) continue;
        status_fields(&g_st[i], __atomic_load_n(&g_st[i].pcm, __ATOMIC_ACQUIRE) != NULL, now, line, sizeof(line));
        len += (size_t)snprintf(b + len, sizeof(b) - len, "s%d=%s\n", g_st[i].id, line);
    }
    pthread_mutex_unlock(&g_lock);
    int ok = write(fd, b, len) == (ssize_t)len;
    close(fd);
    if (ok) rename(tmp, path);
    else unlink(tmp);
}

static void sleep_ms(int ms) {
    struct timespec t = {ms / 1000, (long)(ms % 1000) * 1000000L};
    while (nanosleep(&t, &t) != 0 && errno == EINTR) {
    }
}

static void *logger(void *arg) {
    (void)arg;
    prctl(PR_SET_NAME, (unsigned long)"eqe-cpwatch", 0, 0, 0);
    char st[40], b[EVLEN + 200];
    process_name();
    stamp(st, sizeof(st));
    snprintf(b, sizeof(b), "%s EQ Engine CarPlay watch %d (in place of libCarPlayAndroid.so) in pid %d (%s), uid %d; TinyALSA: %d of %d functions%s%s",
             st, CPW_VERSION, (int)getpid(), g_name, (int)getuid(), g_found, NREAL, g_missing[0] ? ", missing: " : "", g_missing);
    log_write(b);
    int quiet = 0;
    for (;;) {
        int changed = 0;
        /* finished windows first: a stream's last window comes before its close. Each slot's new
           windows are copied under g_lock (w_open may give a closed slot to a new stream), then
           written out without it. */
        int n = __atomic_load_n(&g_nst, __ATOMIC_ACQUIRE);
        for (int i = 0; i < n; i++) {
            static struct win ws[NDONE];
            struct stream sc;
            int nw = 0;
            uint32_t lost = 0;
            pthread_mutex_lock(&g_lock);
            struct stream *s = &g_st[i];
            uint32_t q = __atomic_load_n(&s->done_seq, __ATOMIC_ACQUIRE);
            if (q - s->read_seq > NDONE) {
                lost = q - s->read_seq - NDONE;
                s->read_seq = q - NDONE;
            }
            while (s->read_seq != q && nw < NDONE) {
                ws[nw] = s->done[s->read_seq % NDONE];
                /* the app is shown the newest window with a rate in it (two calls at least) */
                if (ws[nw].calls >= 2) {
                    s->last = ws[nw];
                    s->has_last = 1;
                }
                s->read_seq++;
                nw++;
            }
            sc = *s;
            pthread_mutex_unlock(&g_lock);
            if (lost) {
                snprintf(b, sizeof(b), "s%d: %u windows not written (the log fell behind)", sc.id, lost);
                log_write(b);
            }
            for (int k = 0; k < nw; k++) window_line(&sc, &ws[k]);
            if (nw) changed = 1;
        }
        char line[EVLEN];
        for (;;) {
            pthread_mutex_lock(&g_lock);
            int have = g_ev_tail != g_ev_head;
            if (have) {
                memcpy(line, g_ev[g_ev_tail], EVLEN);
                g_ev_tail = (g_ev_tail + 1) % NEVENTS;
            }
            uint32_t lost = g_ev_lost;
            g_ev_lost = 0;
            pthread_mutex_unlock(&g_lock);
            if (lost) {
                snprintf(b, sizeof(b), "(%u notes lost: too many at once)", lost);
                log_write(b);
            }
            if (!have) break;
            log_write(line);
            changed = 1;
        }
        if (changed || ++quiet >= 10000 / CPW_TICK_MS) {
            /* after 0.7.6: an update of EQ Engine deletes the notes while this app runs: from then on
               they go to a new file (the status file is written by name anyway) */
            struct stat lst;
            char lpath[160];
            snprintf(lpath, sizeof(lpath), CPW_DIR "/cpw_%d.log", (int)getpid());
            if (g_logfd >= 0 && stat(lpath, &lst) != 0 && errno == ENOENT && access(CPE_OFF, F_OK) != 0) {
                close(g_logfd);
                g_logfd = -1;
                g_logged = 0;
                g_logfull = 0;
                stamp(st, sizeof(st));
                snprintf(b, sizeof(b), "%s EQ Engine CarPlay watch %d in pid %d: the earlier notes were removed (EQ Engine updated?); new notes from here",
                         st, CPW_VERSION, (int)getpid());
                log_write(b);
            }
            write_status();
            quiet = 0;
        }
        sleep_ms(CPW_TICK_MS);
    }
    return NULL;
}

static void start_logger(void) {
    pthread_attr_t a;
    pthread_t t;
    g_since = now_us();
    pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    pthread_create(&t, &a, logger, NULL);
    pthread_attr_destroy(&a);
}

/* ------------------------------------------------------------------ TinyALSA's functions */

static struct pcm *w_open(unsigned int card, unsigned int device, unsigned int flags, struct pcm_config *config) {
    need();
    if (r_open == NULL) {
        errno = ENOSYS;
        return NULL;
    }
    struct pcm_config c;
    memset(&c, 0, sizeof(c));
    if (config != NULL) c = *config;
    uint64_t t0 = now_us();
    struct pcm *p = r_open(card, device, flags, config);
    uint64_t t1 = now_us();
    int ready = p != NULL && r_is_ready != NULL ? r_is_ready(p) : 0;
    char err[160];
    err[0] = 0;
    if (!ready && p != NULL && r_get_error != NULL) {
        const char *e = r_get_error(p);
        if (e != NULL) snprintf(err, sizeof(err), "%s", e);
    }
    unsigned int bs = ready && r_get_buffer_size != NULL ? r_get_buffer_size(p) : 0;
    int tid = (int)syscall(SYS_gettid);
    char tn[20];
    thread_name(tid, tn, sizeof(tn));

    pthread_once(&g_log_once, start_logger);
    pthread_mutex_lock(&g_lock);
    struct stream *s = NULL;
    if (ready) {
        int slot = g_nst < MAX_STREAMS ? g_nst : -1;
        if (slot < 0) {
            /* full: the oldest closed stream whose notes are all written */
            for (int i = 0; i < g_nst; i++) {
                struct stream *r = &g_st[i];
                if (__atomic_load_n(&r->pcm, __ATOMIC_ACQUIRE) != NULL || __atomic_load_n(&r->closing, __ATOMIC_ACQUIRE) ||
                    r->read_seq != __atomic_load_n(&r->done_seq, __ATOMIC_ACQUIRE))
                    continue;
                if (slot < 0 || r->id < g_st[slot].id) slot = i;
            }
        }
        if (slot >= 0) {
            s = &g_st[slot];
            memset(s, 0, sizeof(*s));
            s->id = ++g_ids;
            s->card = card;
            s->device = device;
            s->flags = flags;
            s->cfg = c;
            s->bufsize = bs;
            s->bpf = bytes_per_frame(&c);
            s->tid = tid;
            snprintf(s->thread, sizeof(s->thread), "%s", tn);
            s->opened = t1;
            win_reset(&s->cur);
            __atomic_store_n(&s->pcm, p, __ATOMIC_RELEASE);
            if (slot == g_nst) __atomic_store_n(&g_nst, g_nst + 1, __ATOMIC_RELEASE);
        } else {
            g_full_table++;
        }
    }
    char d[160];
    struct stream tmp;
    memset(&tmp, 0, sizeof(tmp));
    tmp.card = card;
    tmp.device = device;
    tmp.flags = flags;
    tmp.cfg = c;
    stream_desc(&tmp, d, sizeof(d));
    if (ready && s != NULL) {
        event_l("open s%d: %s, start %u stop %u -> ok, buffer %u frames, %.1f ms, thread %d (%s)", s->id, d,
                c.start_threshold, c.stop_threshold, bs, (double)(t1 - t0) / 1000.0, tid, tn);
        /* EQ: CarPlay's music through the filter; everything else untouched (see "EQ on CarPlay's
           music"). The lock order is g_lock, then g_eq_lock. */
        int main_link = card == 0 && device == 2;
        pthread_mutex_lock(&g_eq_lock);
        if (flags & PCM_IN) {
            s->mic = 1;
            g_mics++;
            if (g_proc != NULL) {
                eq_apply(0);
                event_l("EQ: s%d goes dry while the microphone (s%d) is open: Siri or a call", g_proc->id, s->id);
            }
            live_state();
        } else if (main_link) {
            int music = c.channels == 2 && c.format == 0 && (c.rate == 44100 || c.rate == 48000);
            int why = !music || g_proc != NULL ? CPE_WHY_FORMAT : eq_why();
            if (why == CPE_WHY_NONE) {
                s->proc = 1;
                g_proc = s;
                if (g_pass != NULL && __atomic_load_n(&g_pass->pcm, __ATOMIC_ACQUIRE) == NULL) g_pass = NULL;
                eq_start(c.rate);
                char sd[200];
                set_desc(&g_set, sd, sizeof(sd));
                event_l("EQ: s%d through EQ Engine's filter at %u Hz (%s%s)", s->id, c.rate, sd,
                        g_mics ? "; dry while the microphone is open" : "");
            } else {
                s->why = why;
                g_pass = s;
                event_l("EQ: s%d plays untouched: %s", s->id, why_text(why));
            }
            live_state();
        }
        pthread_mutex_unlock(&g_eq_lock);
    } else if (ready) {
        event_l("open: %s -> ok, not followed (the table of %d streams is full), thread %d (%s)", d, MAX_STREAMS, tid, tn);
    } else {
        event_l("open: %s -> failed: %s, %.1f ms, thread %d (%s)", d, err[0] ? err : "no reason given",
                (double)(t1 - t0) / 1000.0, tid, tn);
    }
    pthread_mutex_unlock(&g_lock);
    return p;
}

static int w_close(struct pcm *pcm) {
    need();
    if (r_close == NULL) {
        errno = ENOSYS;
        return -1;
    }
    struct stream *s = find(pcm);
    if (s != NULL) {
        /* no call on this stream can come after its close: its window is finished here. The slot
           stays reserved (closing) until the bookkeeping below is done, so an open on another
           thread cannot take it over in between */
        __atomic_store_n(&s->closing, 1, __ATOMIC_RELEASE);
        __atomic_store_n(&s->pcm, NULL, __ATOMIC_RELEASE);
        roll(s, 1);
    }
    int rc = r_close(pcm);
    if (s != NULL) {
        uint64_t now = now_us();
        int again = 0;
        pthread_mutex_lock(&g_lock);
        event_l("close s%d after %.1f s: %llu calls, %llu frames, %llu errors -> %d", s->id,
                (double)(now - s->opened) / 1e6, (unsigned long long)s->total_calls, (unsigned long long)s->total_frames,
                (unsigned long long)s->total_errs, rc);
        pthread_mutex_lock(&g_eq_lock);
        if (g_proc == s) g_proc = NULL;
        if (g_pass == s) g_pass = NULL;
        if (s->mic && g_mics > 0) {
            g_mics--;
            if (g_mics == 0 && g_proc != NULL) {
                eq_apply(0);
                again = g_proc->id;
            }
        }
        live_state();
        pthread_mutex_unlock(&g_eq_lock);
        if (again) event_l("EQ: s%d gets the EQ again (the microphone closed)", again);
        __atomic_store_n(&s->closing, 0, __ATOMIC_RELEASE);
        pthread_mutex_unlock(&g_lock);
    }
    return rc;
}

static int w_write(struct pcm *pcm, const void *data, unsigned int count) {
    need();
    if (r_write == NULL) {
        errno = ENOSYS;
        return -1;
    }
    struct stream *s = find(pcm);
    if (s == NULL) {
        __atomic_add_fetch(&g_untracked, 1, __ATOMIC_RELAXED);
        return r_write(pcm, data, count);
    }
    int32_t peak = -1;
    uint32_t full = 0;
    if (s->cfg.format == 0 && data != NULL) scan16(data, count, &peak, &full);
    if (s->proc && data != NULL && count > 0 && count % 4 == 0) {
        /* CarPlay's music: through the filter into this library's buffer, which TinyALSA then
           plays (in pieces of OBUF_FRAMES if a write is ever longer); the app's buffer is only read */
        const int16_t *src = (const int16_t *)data;
        unsigned int left = count / 4;
        uint64_t eq_ns = 0, wait_ns = 0;
        int32_t opk = 0, mg = 10000;
        int rc = 0;
        uint64_t t0 = now_us();
        /* the same block again after TinyALSA refused it (a retry): the samples processed for it are
           sent again, so the filter never runs twice over one block */
        if (s->retry && data == s->retry_src && count == s->retry_count && block_hash(data, count) == s->retry_hash) {
            s->retry = 0;
            rc = r_write(pcm, g_obuf, count);
            if (rc < 0) s->retry = 1;
            account(s, t0, now_us(), count, rc, peak, full);
            return rc;
        }
        s->retry = 0;
        while (left > 0) {
            unsigned int n = left > OBUF_FRAMES ? OBUF_FRAMES : left;
            int64_t w0 = now_ns();
            pthread_mutex_lock(&g_eq_lock);
            int64_t a = now_ns();
            if (a > w0) wait_ns += (uint64_t)(a - w0);
            int32_t g = eq_block(src, g_obuf, n, a);
            eq_ns += (uint64_t)(now_ns() - a);
            if (g_eq.blk_peak > opk) opk = g_eq.blk_peak;
            if (g < mg) mg = g;
            pthread_mutex_unlock(&g_eq_lock);
            rc = r_write(pcm, g_obuf, n * 4);
            if (rc < 0) break;
            src += 2 * n;
            left -= n;
        }
        if (rc < 0 && count <= OBUF_FRAMES * 4) {
            /* kept for a retry of this block (one piece only: g_obuf holds it whole) */
            s->retry = 1;
            s->retry_src = data;
            s->retry_count = count;
            s->retry_hash = block_hash(data, count);
        }
        uint64_t t1 = now_us();
        account(s, t0, t1, count, rc, peak, full);
        struct win *w = &s->cur;
        w->eq_ns += eq_ns;
        w->eq_calls++;
        if (eq_ns > w->eq_max) w->eq_max = clamp32(eq_ns);
        w->wait_ns += wait_ns;
        if (wait_ns > w->wait_max) w->wait_max = clamp32(wait_ns);
        if (opk > w->out_peak) w->out_peak = opk;
        if (mg < w->min_gain) w->min_gain = mg;
        return rc;
    }
    uint64_t t0 = now_us();
    int rc = r_write(pcm, data, count);
    uint64_t t1 = now_us();
    account(s, t0, t1, count, rc, peak, full);
    return rc;
}

static int w_read(struct pcm *pcm, void *data, unsigned int count) {
    need();
    if (r_read == NULL) {
        errno = ENOSYS;
        return -1;
    }
    struct stream *s = find(pcm);
    if (s == NULL) {
        __atomic_add_fetch(&g_untracked, 1, __ATOMIC_RELAXED);
        return r_read(pcm, data, count);
    }
    uint64_t t0 = now_us();
    int rc = r_read(pcm, data, count);
    uint64_t t1 = now_us();
    int32_t peak = -1;
    uint32_t full = 0;
    if (rc == 0 && s->cfg.format == 0 && data != NULL) scan16(data, count, &peak, &full);
    account(s, t0, t1, count, rc, peak, full);
    return rc;
}


/* ------------------------------------------------------------------ in place of libCarPlayAndroid.so */

#if defined(__arm__)
#define R_JUMP_SLOT R_ARM_JUMP_SLOT
#define R_GLOB_DAT R_ARM_GLOB_DAT
#define EM_HERE EM_ARM
#elif defined(__aarch64__)
#define R_JUMP_SLOT R_AARCH64_JUMP_SLOT
#define R_GLOB_DAT R_AARCH64_GLOB_DAT
#define EM_HERE EM_AARCH64
#elif defined(__x86_64__)
#define R_JUMP_SLOT R_X86_64_JUMP_SLOT
#define R_GLOB_DAT R_X86_64_GLOB_DAT
#define EM_HERE EM_X86_64
#elif defined(__i386__)
#define R_JUMP_SLOT R_386_JMP_SLOT
#define R_GLOB_DAT R_386_GLOB_DAT
#define EM_HERE EM_386
#else
#error "unknown CPU"
#endif
#if UINTPTR_MAX == 0xffffffffu
#define R_SYM_OF(i) ELF32_R_SYM(i)
#define R_TYPE_OF(i) ELF32_R_TYPE(i)
#define CLASS_HERE ELFCLASS32
#else
#define R_SYM_OF(i) ELF64_R_SYM(i)
#define R_TYPE_OF(i) ELF64_R_TYPE(i)
#define CLASS_HERE ELFCLASS64
#endif

#define NWANT 4
static const char *const k_want[NWANT] = {"pcm_open", "pcm_close", "pcm_write", "pcm_read"};

static void note(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void note(const char *fmt, ...) {
    char b[EVLEN];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b, sizeof(b), fmt, ap);
    va_end(ap);
    pthread_mutex_lock(&g_lock);
    event_l("%s", b);
    pthread_mutex_unlock(&g_lock);
    LOGI("%s", b);
}

/* one line of /proc/self/maps */
struct mline {
    uintptr_t s, e;
    unsigned long off;
    char perms[8];
    char path[256];
};

static int maps_next(FILE *f, struct mline *m) {
    char line[600];
    while (fgets(line, sizeof(line), f) != NULL) {
        unsigned long s, e, off;
        int pos = 0;
        m->perms[0] = 0;
        if (sscanf(line, "%lx-%lx %7s %lx %*s %*s%n", &s, &e, m->perms, &off, &pos) < 4 || pos <= 0) continue;
        char *p = line + pos;
        while (*p == ' ' || *p == '\t') p++;
        size_t l = strlen(p);
        while (l > 0 && (p[l - 1] == '\n' || p[l - 1] == ' ')) p[--l] = 0;
        snprintf(m->path, sizeof(m->path), "%s", p);
        m->s = (uintptr_t)s;
        m->e = (uintptr_t)e;
        m->off = off;
        return 1;
    }
    return 0;
}

static int path_is(const char *path, const char *name) {
    size_t lp = strlen(path), ln = strlen(name);
    return lp > ln && path[lp - ln - 1] == '/' && strcmp(path + lp - ln, name) == 0;
}

/* the start of a loaded library's first mapping (file offset 0); 0 if it is not loaded */
static uintptr_t lib_base(const char *name) {
    FILE *f = fopen("/proc/self/maps", "re");
    if (f == NULL) return 0;
    struct mline m;
    uintptr_t b = 0;
    while (maps_next(f, &m)) {
        if (m.off == 0 && path_is(m.path, name)) {
            b = m.s;
            break;
        }
    }
    fclose(f);
    return b;
}

/* the protection of the mapping that holds addr (PROT_*), -1 if none */
static int prot_at(uintptr_t addr) {
    FILE *f = fopen("/proc/self/maps", "re");
    if (f == NULL) return -1;
    struct mline m;
    int p = -1;
    while (maps_next(f, &m)) {
        if (addr >= m.s && addr < m.e) {
            p = (m.perms[0] == 'r' ? PROT_READ : 0) | (m.perms[1] == 'w' ? PROT_WRITE : 0) | (m.perms[2] == 'x' ? PROT_EXEC : 0);
            break;
        }
    }
    fclose(f);
    return p;
}

/* Writes v into an import slot, making its page writable for the moment if it is not. */
static int store_slot(void **slot, void *v) {
    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0) pg = 4096;
    uintptr_t page = (uintptr_t)slot & ~(uintptr_t)(pg - 1);
    int prot = prot_at((uintptr_t)slot);
    if (prot < 0) return 0;
    if (!(prot & PROT_WRITE) && mprotect((void *)page, (size_t)pg, prot | PROT_WRITE) != 0) return 0;
    __atomic_store_n(slot, v, __ATOMIC_RELEASE);
    if (!(prot & PROT_WRITE)) mprotect((void *)page, (size_t)pg, prot);
    return 1;
}

/* The audio library's own readable mappings (after 0.7.6): every read of its headers, its tables
   and its import slots is checked against them first. A library laid out unlike any seen (one that
   another package edited on disk, for example) is then left alone with a note, instead of being
   read where nothing is mapped, which would end the CarPlay app at its start. Neighbouring
   mappings of the file count as one range (the linker's read-only part after relocation shows as
   a mapping of its own). */
#define LIBMAPS 16
struct libmaps {
    int n;
    uintptr_t s[LIBMAPS], e[LIBMAPS];
};

static void lib_maps(const char *name, struct libmaps *lm) {
    lm->n = 0;
    FILE *f = fopen("/proc/self/maps", "re");
    if (f == NULL) return;
    struct mline m;
    while (maps_next(f, &m)) {
        if (m.perms[0] != 'r' || !path_is(m.path, name)) continue;
        if (lm->n > 0 && lm->e[lm->n - 1] == m.s) {
            lm->e[lm->n - 1] = m.e;
        } else if (lm->n < LIBMAPS) {
            lm->s[lm->n] = m.s;
            lm->e[lm->n] = m.e;
            lm->n++;
        }
    }
    fclose(f);
}

/* bytes from a to the end of the library's readable range that holds it; 0 if none holds it */
static size_t lib_room(const struct libmaps *lm, uintptr_t a) {
    for (int i = 0; i < lm->n; i++)
        if (a >= lm->s[i] && a < lm->e[i]) return (size_t)(lm->e[i] - a);
    return 0;
}

/* 1 when the n bytes at a are all in one readable range of the library */
static int in_lib(const struct libmaps *lm, uintptr_t a, size_t n) {
    return n > 0 && lib_room(lm, a) >= n;
}

/* which of the four names the symbol name at n is (reading at most room bytes); -1 if none */
static int want_index(const char *n, size_t room) {
    for (int i = 0; i < NWANT; i++) {
        size_t l = strlen(k_want[i]);
        if (room > l && memcmp(n, k_want[i], l + 1) == 0) return i;
    }
    return -1;
}

/* Points libCarPlayAudio.so's imports of the four TinyALSA functions here (see the top). */
static void swap_imports(void) {
    g_state = "not watching";
    uintptr_t base = lib_base(CPS_TARGET);
    if (base == 0) {
        note("%s is not loaded in this process: nothing is watched", CPS_TARGET);
        return;
    }
    struct libmaps lm;
    lib_maps(CPS_TARGET, &lm);
    size_t room0 = lib_room(&lm, base);
    if (room0 < sizeof(ElfW(Ehdr))) {
        note("%s: its ELF header cannot be read where it is loaded: nothing is watched", CPS_TARGET);
        return;
    }
    const ElfW(Ehdr) *eh = (const ElfW(Ehdr) *)base;
    if (memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 || eh->e_ident[EI_CLASS] != CLASS_HERE) {
        note("%s is not mapped as an ELF file of this CPU: nothing is watched", CPS_TARGET);
        return;
    }
    /* its program headers: in the first loaded range, as every library's are (after 0.7.6) */
    if (eh->e_phentsize != sizeof(ElfW(Phdr)) || eh->e_phnum == 0 || eh->e_phoff >= room0 ||
        (size_t)eh->e_phnum * sizeof(ElfW(Phdr)) > room0 - (size_t)eh->e_phoff) {
        note("%s: its program headers are not where it is loaded (laid out unlike the factory file): nothing is watched", CPS_TARGET);
        return;
    }
    const ElfW(Phdr) *ph = (const ElfW(Phdr) *)(base + eh->e_phoff);
    uintptr_t lo = UINTPTR_MAX;
    const ElfW(Phdr) *dynph = NULL;
    for (int i = 0; i < eh->e_phnum; i++) {
        if (ph[i].p_type == PT_LOAD && ph[i].p_vaddr < lo) lo = ph[i].p_vaddr;
        if (ph[i].p_type == PT_DYNAMIC) dynph = &ph[i];
    }
    if (dynph == NULL || lo == UINTPTR_MAX) {
        note("%s has no dynamic section in memory: nothing is watched", CPS_TARGET);
        return;
    }
    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0) pg = 4096;
    uintptr_t bias = base - (lo & ~(uintptr_t)(pg - 1));
    uintptr_t strtab = 0, symtab = 0, jmprel = 0, rel = 0, rela = 0;
    size_t pltrelsz = 0, relsz = 0, relasz = 0;
    long pltrel = DT_REL;
    const ElfW(Dyn) *dyn = (const ElfW(Dyn) *)(bias + dynph->p_vaddr);
    size_t ndyn = (size_t)dynph->p_filesz / sizeof(ElfW(Dyn));
    if (ndyn == 0 || !in_lib(&lm, (uintptr_t)dyn, ndyn * sizeof(ElfW(Dyn)))) {
        note("%s: its dynamic section is not where it is loaded (laid out unlike the factory file): nothing is watched", CPS_TARGET);
        return;
    }
    for (size_t k = 0; k < ndyn && dyn[k].d_tag != DT_NULL; k++) {
        const ElfW(Dyn) *d = &dyn[k];
        switch (d->d_tag) {
        case DT_STRTAB: strtab = d->d_un.d_ptr; break;
        case DT_SYMTAB: symtab = d->d_un.d_ptr; break;
        case DT_JMPREL: jmprel = d->d_un.d_ptr; break;
        case DT_PLTRELSZ: pltrelsz = d->d_un.d_val; break;
        case DT_PLTREL: pltrel = (long)d->d_un.d_val; break;
        case DT_REL: rel = d->d_un.d_ptr; break;
        case DT_RELSZ: relsz = d->d_un.d_val; break;
        case DT_RELA: rela = d->d_un.d_ptr; break;
        case DT_RELASZ: relasz = d->d_un.d_val; break;
        default: break;
        }
    }
    /* Android's linker leaves these as they are in the file (relative to the load address); glibc's
       turns them into addresses */
#define ADJ(x) ((x) != 0 && (x) < bias ? (x) + bias : (x))
    strtab = ADJ(strtab);
    symtab = ADJ(symtab);
    jmprel = ADJ(jmprel);
    rel = ADJ(rel);
    rela = ADJ(rela);
#undef ADJ
    if (strtab == 0 || symtab == 0) {
        note("%s has no symbol table in memory: nothing is watched", CPS_TARGET);
        return;
    }
    struct {
        uintptr_t at;
        size_t size;
        int isrela;
    } tabs[3] = {{jmprel, pltrelsz, pltrel == DT_RELA}, {rel, relsz, 0}, {rela, relasz, 1}};
    void **slot[16];
    int which[16], ns = 0;
    for (int t = 0; t < 3; t++) {
        if (tabs[t].at == 0 || tabs[t].size == 0) continue;
        if (!in_lib(&lm, tabs[t].at, tabs[t].size)) {
            note("%s: a relocation table is not where it is loaded (laid out unlike the factory file): nothing is watched", CPS_TARGET);
            return;
        }
        size_t ent = tabs[t].isrela ? sizeof(ElfW(Rela)) : sizeof(ElfW(Rel));
        for (size_t o = 0; o + ent <= tabs[t].size; o += ent) {
            const ElfW(Rel) *r = (const ElfW(Rel) *)(tabs[t].at + o); /* a Rela starts the same way */
            unsigned type = (unsigned)R_TYPE_OF(r->r_info);
            if (type != R_JUMP_SLOT && type != R_GLOB_DAT) continue;
            size_t si = (size_t)R_SYM_OF(r->r_info);
            if (si == 0) continue;
            const ElfW(Sym) *sy = (const ElfW(Sym) *)symtab + si;
            if (!in_lib(&lm, (uintptr_t)sy, sizeof(*sy))) continue;
            uintptr_t nm = strtab + sy->st_name;
            int w = want_index((const char *)nm, lib_room(&lm, nm));
            if (w < 0) continue;
            void **s = (void **)(bias + r->r_offset);
            if (!in_lib(&lm, (uintptr_t)s, sizeof(*s))) {
                note("%s: its %s import slot is not where it is loaded: left alone", CPS_TARGET, k_want[w]);
                continue;
            }
            int dup = 0;
            for (int k = 0; k < ns; k++) dup |= slot[k] == s;
            if (!dup && ns < 16) {
                slot[ns] = s;
                which[ns++] = w;
            }
        }
    }
    g_slots_want = ns;
    /* in a fixed order (pcm_open, pcm_close, pcm_write, pcm_read), whatever the table's */
    for (int i = 1; i < ns; i++) {
        for (int k = i; k > 0 && which[k - 1] > which[k]; k--) {
            int tw = which[k];
            void **ts = slot[k];
            which[k] = which[k - 1];
            slot[k] = slot[k - 1];
            which[k - 1] = tw;
            slot[k - 1] = ts;
        }
    }
    if (ns == 0) {
        note("%s imports none of %s, %s, %s, %s: nothing is watched", CPS_TARGET, k_want[0], k_want[1], k_want[2], k_want[3]);
        return;
    }
    void *real[NWANT], *repl[NWANT];
    memcpy(&real[0], &r_open, sizeof(void *));
    memcpy(&real[1], &r_close, sizeof(void *));
    memcpy(&real[2], &r_write, sizeof(void *));
    memcpy(&real[3], &r_read, sizeof(void *));
    repl[0] = (void *)w_open;
    repl[1] = (void *)w_close;
    repl[2] = (void *)w_write;
    repl[3] = (void *)w_read;
    char done_names[120] = "", left[200] = "";
    int done = 0, write_done = 0, ro_again = 1;
    for (int i = 0; i < ns; i++) {
        void *cur = __atomic_load_n(slot[i], __ATOMIC_ACQUIRE);
        size_t l;
        if (real[which[i]] == NULL || cur != real[which[i]]) {
            l = strlen(left);
            snprintf(left + l, sizeof(left) - l, "%s%s (it holds %p, not TinyALSA's)", l ? ", " : "", k_want[which[i]], cur);
            continue;
        }
        int was_ro = !(prot_at((uintptr_t)slot[i]) & PROT_WRITE);
        if (!store_slot(slot[i], repl[which[i]])) {
            l = strlen(left);
            snprintf(left + l, sizeof(left) - l, "%s%s (could not be changed: %s)", l ? ", " : "", k_want[which[i]], strerror(errno));
            continue;
        }
        if (was_ro && (prot_at((uintptr_t)slot[i]) & PROT_WRITE)) ro_again = 0;
        done++;
        if (which[i] == 2) write_done = 1;
        l = strlen(done_names);
        snprintf(done_names + l, sizeof(done_names) - l, "%s%s", l ? " " : "", k_want[which[i]]);
    }
    g_slots = done;
    if (write_done) g_state = "watching";
    note("%s: %d of %d TinyALSA imports watched (%s)%s%s%s", CPS_TARGET, done, ns, done ? done_names : "none",
         ro_again ? ", the table read-only again" : ", the table left writable", left[0] ? "; left alone: " : "", left);
}

/* HMG-API's hook library in this process: its hooks run here (started from the zygote as always) */
static void hmgapi_check(void) {
    FILE *f = fopen("/proc/self/maps", "re");
    if (f == NULL) return;
    struct mline m;
    int found = 0;
    while (maps_next(f, &m))
        if (path_is(m.path, "libhmgapi_hook.so")) found = 1;
    fclose(f);
    g_hmgapi = found;
}

typedef int (*onload_fn)(void *, void *);

/* Dalvik calls this when CarPlayService loads "CarPlayAndroid" (see the top). */
EXPORT int JNI_OnLoad(void *vm, void *reserved) {
    uint64_t t0 = now_us();
    pthread_once(&g_log_once, start_logger);
    need();
    hmgapi_check();
    note("loaded in place of libCarPlayAndroid.so (HMG-API's hook library in this process: %s); the factory library: %s",
         g_hmgapi ? "yes" : "no", CPS_COPY);
    void *h = dlopen(CPS_COPY, RTLD_NOW);
    if (h == NULL) {
        const char *e = dlerror();
        g_state = "failed";
        note("the factory library did not load (%s): CarPlay cannot start in this start of the app", e ? e : "?");
        return -1;
    }
    void *p = dlsym(h, "JNI_OnLoad");
    if (p == NULL || p == (void *)JNI_OnLoad) {
        g_state = "failed";
        note("the factory library has no JNI_OnLoad of its own: CarPlay cannot start in this start of the app");
        return -1;
    }
    onload_fn f;
    memcpy(&f, &p, sizeof(p));
    int v = f(vm, reserved);
    note("the factory library is loaded; its JNI_OnLoad returned 0x%x (%.1f ms)", (unsigned)v, (double)(now_us() - t0) / 1000.0);
    if (v < 0) {
        /* Dalvik refuses the load: the app's JNI library does not load in this start of the app */
        g_state = "failed";
        note("its JNI_OnLoad failed: CarPlay cannot start in this start of the app; the imports are left alone");
        return v;
    }
    swap_imports();
    /* EQ on CarPlay's music: its control thread (reads the app's settings, keeps the live file) */
    if (g_slots > 0) pthread_once(&g_eqt_once, start_eq);
    return v;
}

/* ------------------------------------------------------------------ the check before use */

static int bad(char *why, size_t n, const char *what) {
    snprintf(why, n, "%s", what);
    return 0;
}

/* The copy of the factory library, read as a file (nothing of it runs here): an ELF file for this
   CPU that exports JNI_OnLoad and needs CPS_TARGET. */
static int file_check(const char *path, char *why, size_t wn) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        snprintf(why, wn, "the factory library cannot be read (%s)", strerror(errno));
        return 0;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(ElfW(Ehdr)) || st.st_size > 64 * 1024 * 1024) {
        close(fd);
        return bad(why, wn, "the factory library is not an ELF file");
    }
    size_t size = (size_t)st.st_size;
    unsigned char *b = malloc(size);
    size_t got = 0;
    while (b != NULL && got < size) {
        ssize_t r = read(fd, b + got, size - got);
        if (r <= 0) break;
        got += (size_t)r;
    }
    close(fd);
    if (b == NULL || got != size) {
        free(b);
        return bad(why, wn, "the factory library could not be read whole");
    }
    int ok = 0;
    const ElfW(Ehdr) *eh = (const ElfW(Ehdr) *)b;
    if (memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 || eh->e_ident[EI_CLASS] != CLASS_HERE) {
        bad(why, wn, "the factory library is not an ELF file of this CPU's class");
    } else if (eh->e_machine != EM_HERE) {
        snprintf(why, wn, "the factory library is for another CPU (machine %u)", (unsigned)eh->e_machine);
    } else if (eh->e_shoff == 0 || eh->e_shentsize != sizeof(ElfW(Shdr)) || eh->e_shoff > size ||
               (size_t)eh->e_shnum * sizeof(ElfW(Shdr)) > size - eh->e_shoff) {
        bad(why, wn, "the factory library has no section table");
    } else {
        const ElfW(Shdr) *sh = (const ElfW(Shdr) *)(b + eh->e_shoff);
        int onload = 0, needs = 0;
        for (int i = 0; i < eh->e_shnum; i++) {
            if (sh[i].sh_type != SHT_DYNSYM && sh[i].sh_type != SHT_DYNAMIC) continue;
            if (sh[i].sh_link >= eh->e_shnum) continue;
            const ElfW(Shdr) *ss = &sh[sh[i].sh_link];
            if (sh[i].sh_offset > size || sh[i].sh_size > size - sh[i].sh_offset || ss->sh_offset > size ||
                ss->sh_size > size - ss->sh_offset || ss->sh_size == 0)
                continue;
            const char *str = (const char *)b + ss->sh_offset;
            size_t strn = ss->sh_size;
            if (sh[i].sh_type == SHT_DYNSYM) {
                const ElfW(Sym) *sy = (const ElfW(Sym) *)(b + sh[i].sh_offset);
                size_t n = sh[i].sh_size / sizeof(ElfW(Sym));
                for (size_t k = 1; k < n; k++)
                    if (sy[k].st_name < strn && sy[k].st_shndx != SHN_UNDEF &&
                        strncmp(str + sy[k].st_name, "JNI_OnLoad", strn - sy[k].st_name) == 0 &&
                        strlen("JNI_OnLoad") < strn - sy[k].st_name)
                        onload = 1;
            } else {
                const ElfW(Dyn) *d = (const ElfW(Dyn) *)(b + sh[i].sh_offset);
                size_t n = sh[i].sh_size / sizeof(ElfW(Dyn));
                for (size_t k = 0; k < n && d[k].d_tag != DT_NULL; k++)
                    if (d[k].d_tag == DT_NEEDED && d[k].d_un.d_val < strn &&
                        strncmp(str + d[k].d_un.d_val, CPS_TARGET, strn - d[k].d_un.d_val) == 0 &&
                        strlen(CPS_TARGET) < strn - d[k].d_un.d_val)
                        needs = 1;
            }
        }
        if (!onload)
            bad(why, wn, "the factory library does not export JNI_OnLoad");
        else if (!needs)
            bad(why, wn, "the factory library does not need " CPS_TARGET);
        else {
            snprintf(why, wn, "the factory library exports JNI_OnLoad and needs %s", CPS_TARGET);
            ok = 1;
        }
    }
    free(b);
    return ok;
}

/* For act.sh's check before use (eqe_lab cpcheck): this library loads in a process of its own, finds
   the car's TinyALSA functions, and reads the copy of the factory library as a file. 1 = all good. */
EXPORT int eqe_cpw_check(const char *copy, char *msg, int len) {
    need();
    char why[200];
    int ok = copy != NULL && file_check(copy, why, sizeof(why));
    if (copy == NULL) snprintf(why, sizeof(why), "no factory library given");
    if (msg != NULL && len > 0)
        snprintf(msg, (size_t)len, "%s; TinyALSA: %d of %d functions%s%s", why, g_found, NREAL, g_missing[0] ? ", missing: " : "",
                 g_missing);
    return ok && g_found == NREAL;
}
