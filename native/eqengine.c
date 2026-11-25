/*
 * EQ Engine: a 10-band graphic EQ audio effect for Android 4.4 (Gen5W head unit).
 *
 * Loaded by mediaserver's effect factory (listed in audio_effects.conf) and run inside the music
 * mixer on session 0 (all music output) when the EQ Engine app attaches it.
 *
 * Signal path, per stereo frame (all math in double precision):
 *   16-bit in -> preamp -> 10 filters (31 Hz .. 16 kHz, one octave apart)
 *             -> crossfade with the untouched input (EQ on/off) -> clip guard -> TPDF dither -> 16-bit out
 *
 * - Bands (0.6.6): one-octave peaking filters with the bandwidth prewarped, so the 8 and 16 kHz
 *   bells are as wide as the others near Nyquist. The 31 Hz and 16 kHz bands can each be a shelf
 *   instead (settings "ends"): a low shelf turning over at 50 Hz, a high shelf at 11.3 kHz. The
 *   slider still sets the level at the band's centre.
 * - Accurate sliders: neighbouring bands overlap, so a plain graphic EQ overshoots when several
 *   are raised. The requested slider values are solved for (an interaction matrix plus three
 *   refinement passes) so the measured response at each band centre matches its slider.
 * - Live view (0.6.6): while the app reads EQE_PARAM_SPECTRUM (at least every 2 s), the output
 *   is analysed once per buffer (4096-point FFT, 48 bands from 20 Hz to 20 kHz). Nothing is
 *   allocated or computed until the first read.
 * - Click-free changes: new filter settings are reached by interpolating the coefficients over
 *   1024 samples (stable for every step in between); preamp changes are smoothed; EQ on/off
 *   crossfades over 2048 samples.
 * - Clip guard: a 64-sample look-ahead peak limiter (stereo-linked) at full scale: it only acts
 *   on samples the EQ or preamp pushed past 16-bit full scale, ramps down over the look-ahead
 *   and recovers over about 80 ms. A flat EQ with 0 dB preamp leaves the audio bit-identical.
 *   Off = plain clipping at full scale (counted in the stats).
 * - Dither: triangular (TPDF) +-1 LSB, only for samples that were actually changed.
 * - EQ off is bit-exact: the input comes out unchanged, only delayed by the 63-sample look-ahead
 *   (1.4 ms at 44.1 kHz), so on/off comparisons are honest.
 * - Mid/side (0x326): while a stereo width other than 100 %, mono bass or an Expert band on the mid
 *   ((L + R) / 2) or the side ((L - R) / 2) only is set, the bands run on mid and side instead of
 *   left and right (each filter with each lane's own coefficients; the mono bass is a low cut on the
 *   side), the side is scaled by the width, and the two go back to left and right before the seat
 *   delay. Without any of them the bands run on left and right exactly as before.
 * - Listening position (0.4): an extra delay of up to 5 ms on the left or right channel, so the
 *   nearer speakers' sound arrives together with the farther ones' at the chosen seat. Changes
 *   crossfade between the old and new delay over 1024 samples (no clicks, no pitch bend).
 *
 * Nothing runs when the library is loaded. All work happens in process()/command(), which
 * AudioFlinger serialises with the effect's lock.
 */
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <android/log.h>

#include "fx44.h"

#define TAG "EQEngine"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

#define EQE_LIB_VERSION 0x00000326 /* 0x326 (0.7.8): settings layout 4: stereo width, mono bass and a channel (L+R, mid or
                                         side) for each Expert band; the bands run on mid and side while any of them is used;
                                      0x325 (after 0.7.6): the bit-exact path clamps what the processing path left in the look-ahead
                                         (EQ off, or a microphone on CarPlay, with the clip guard off: no wrap to the opposite sign);
                                      0x324 (0.7.6): EQE_PARAM_PEAK answers the largest boost over this rate, 44.1 and 48 kHz;
                                      0x323 (0.7.4): the bands run a chunk at a time (bands_block), bit for bit 0x322's output;
                                      0x322: settings layout 3 (Expert mode: up to EQE_NX bands of its own);
                                      0x321: EQE_PARAM_PEAK, and SET_CONFIG refuses all but 16-bit stereo;
                                      0x320 (0.6.6): settings layout 2 (ends), EQE_PARAM_SPECTRUM, EQE_PARAM_LEVEL;
                                      0x310 (0.5): as 0.4 (0x300) plus EQE_PARAM_VHQ */
#define EQE_MAGIC 0x45514532u     /* "EQE2" */
#define EQE_MAX_FRAMES 65536u

/* Parameters: 32-bit id; values are int32 arrays (little-endian, as the device is). */
#define EQE_PARAM_STATS    2  /* r:  int32[EQE_STATS_COUNT], see eqe_get_stats() */
#define EQE_PARAM_VERSION  3  /* r:  EQE_LIB_VERSION */
#define EQE_PARAM_SETTINGS 10 /* rw: int32[EQE_SET_COUNT], see eqe_settings (layouts 1 and 2 are still taken) */
#define EQE_PARAM_RESPONSE 11 /* r:  int32[EQE_NRESP] EQ response in 0.01 dB at eqe_resp_hz() */
#define EQE_PARAM_GAINS    12 /* r:  int32[EQE_NB] solved filter gains in 0.01 dB (diagnostic) */
#define EQE_PARAM_VHQ      13 /* r:  int32[8] very high quality converter status, see vhq_status() */
#define EQE_PARAM_SPECTRUM 14 /* r:  int32[4 + EQE_NSPEC] live view, see spec_read(); reading keeps it on */
#define EQE_PARAM_LEVEL    15 /* r:  int32[6] the last buffer's output level, see level_read() */
#define EQE_PARAM_PEAK     16 /* w:  eqe_settings to look at (nothing is applied); r: int32[3] their largest
                                     steady-state gain, see peak_query() */
/* EQE_CORE_ONLY (0.7.3): the CarPlay watch (cpwatch.c) includes this file for the filter itself:
   settings, design and process_frames, and the live view. Without the audio effect's entry points
   (no AELI, nothing exported) and without the converter tables, which belong in the audio server only. */
#ifndef EQE_CORE_ONLY
static void vhq_status(int32_t *v);
#endif

#define EQE_NB 10               /* Easy mode: the ten sliders */
#define EQE_NX 20               /* Expert mode: at most 20 bands of its own */
#define EQE_NBAND EQE_NX        /* band filters in the audio path (Easy uses the first EQE_NB) */
#define EQE_MONO EQE_NBAND      /* 0x326: the mono bass filter (a low cut on the side only), after the bands */
#define EQE_NFILT (EQE_NBAND + 1) /* every filter in the audio path */
#define EQE_NRESP 96
#define EQE_NSPEC 48            /* live view bands, 20 Hz .. 20 kHz, log spaced */
#define EQE_STATS_COUNT 28
#define EQE_SET_COUNT (21 + 4 * EQE_NX) /* layout 4 */
#define EQE_SET3_BYTES ((19 + 4 * EQE_NX) * 4) /* layout 3 (0.7.1 .. 0.7.7): no width, mono bass or band channels */
#define EQE_SET2_BYTES (17 * 4)  /* layout 2 (0.6.6 .. 0.6.10): no Expert mode */
#define EQE_SET1_BYTES (16 * 4)  /* layout 1 (0.4 .. 0.6.4): no "ends" */
/* Expert band types, and the ranges of their values */
#define EQE_X_PEAK 1            /* a bell: frequency, gain, bandwidth (0.001 octave, prewarped like bell()) */
#define EQE_X_LOW_SHELF 2       /* frequency (the midpoint), gain; slope S = 1 as the end bands' */
#define EQE_X_HIGH_SHELF 3
#define EQE_X_LOW_CUT 4         /* a 12 dB/octave high-pass: frequency, Q (0.001) in the width field */
#define EQE_X_FMIN 2000         /* 20 Hz, in 0.01 Hz */
#define EQE_X_FMAX 2000000      /* 20 kHz */
#define EQE_X_BWMIN 100         /* 0.1 octave */
#define EQE_X_BWMAX 4000        /* 4 octaves */
#define EQE_X_QMIN 500          /* low cut Q 0.5 .. 2 */
#define EQE_X_QMAX 2000
#define EQE_X_TYPE(t) ((t) & 0xF) /* layout 4: an Expert band's type field also holds its channel */
#define EQE_X_CH(t) (((t) >> 4) & 0xF)
#define EQE_CH_LR 0             /* left and right alike (as every band before 0x326) */
#define EQE_CH_MID 1            /* the mid only ((L + R) / 2: what both sides share) */
#define EQE_CH_SIDE 2           /* the side only ((L - R) / 2: what differs) */
#define EQE_WIDTH_MAX 150       /* stereo width, percent: 0 mono, 100 as recorded */
#define EQE_MONO_MIN 40         /* mono bass below this many Hz (0 = off) */
#define EQE_MONO_MAX 250
#define EQE_ENDS_LOW 1          /* the 31 Hz band is a low shelf */
#define EQE_ENDS_HIGH 2         /* the 16 kHz band is a high shelf */
#define LOW_SHELF_HZ 50.0       /* shelf midpoints: between the end band and its neighbour */
#define HIGH_SHELF_HZ 11300.0
#define BAND_BW_OCT 1.0         /* bell width between the half-gain points, octaves */
#define EQE_BAND_LIMIT 1500     /* +-15 dB per slider */
#define EQE_PRE_MIN (-2400)     /* preamp -24 dB .. +6 dB */
#define EQE_PRE_MAX 600
#define EQE_GAIN_CLAMP 24.0     /* solved filter gains stay within +-24 dB */
#define EQE_RESP_NONE ((int32_t)0x80000000)

#define EQE_CHUNK 256           /* frames per pass of the band filters (bands_block) */
#define RAMP_LEN 1024
#define XFADE_LEN 2048
#define LA 64                   /* look-ahead length; delay is LA - 1 samples */
#define GUARD_THR 1.0           /* full scale (-32768/32768): untouched 16-bit audio never triggers it */
#define BAND_Q 1.4142135623730951
#define DMAX 512                /* delay line length (samples) */
#define DFADE_LEN 1024
#define EQE_DELAY_MAX_US 5000
#define EQE_PI 3.14159265358979323846

typedef struct {
    int32_t layout;            /* 2 (layout 1, without "ends", is still accepted) */
    int32_t eq_on;             /* 0 = bypass (bit-exact), 1 = EQ on */
    int32_t preamp_cdb;        /* 0.01 dB */
    int32_t guard_on;          /* clip guard */
    int32_t band_cdb[EQE_NB];  /* slider values, 0.01 dB */
    int32_t delay_us[2];       /* listening position: extra delay, left and right (0..5000 us) */
    int32_t ends;              /* layout 2: EQE_ENDS_LOW | EQE_ENDS_HIGH, shelves for the end bands */
    int32_t mode;              /* layout 3: 0 = Easy (band_cdb, ends), 1 = Expert (x) */
    int32_t nx;                /* layout 3: Expert bands in x, 0 .. EQE_NX */
    int32_t x[EQE_NX][4];      /* layout 3, each Expert band: type (EQE_X_*; layout 4: plus its channel
                                  EQE_CH_* << 4), frequency (0.01 Hz), gain (0.01 dB; not for the low cut),
                                  width (peak: bandwidth in 0.001 octave; low cut: Q x 1000; shelves: unused) */
    int32_t width_pct;         /* layout 4: stereo width, 0 .. EQE_WIDTH_MAX percent (100 = as recorded) */
    int32_t mono_hz;           /* layout 4: mono bass below this frequency, Hz (0 = off) */
} eqe_settings;

typedef struct { double b0, b1, b2, a1, a2; } coefs_t;

/* 0x326: a filter has coefficients for each of the two lanes the bands run on. While no mid/side
   setting is used (c->ms == 0) the lanes are left and right, both take lane 0's coefficients, and
   the lane 1 set (cur1, inc1) is not kept up to date; while one is (c->ms == 1) the lanes are mid
   and side and each takes its own. */
typedef struct {
    coefs_t cur, tgt, inc;
    double z1[2], z2[2];
    int active;                /* cur/tgt not identity, or state not yet zero */
    coefs_t cur1, tgt1, inc1;  /* lane 1 (the side) while c->ms */
} band_t;

/* live view: allocated at the first EQE_PARAM_SPECTRUM read */
#define SPEC_N 4096             /* analysis length (real samples); FFT of SPEC_N / 2 complex points */
#define SPEC_M (SPEC_N / 2)
#define SPEC_KEEP_NS 2000000000LL /* analyse while the view was read within the last 2 s */
typedef struct {
    float ring[SPEC_N];        /* mono output, oldest at pos */
    float win[SPEC_N];         /* Hann window */
    double re[SPEC_M], im[SPEC_M];
    double twr[SPEC_M], twi[SPEC_M]; /* e^(-2 pi i k / SPEC_N) */
    int16_t rev[SPEC_M];       /* bit reversal for SPEC_M points */
    int pos, fresh, filled;
    double winsum2;            /* sum of the window's squares */
    double rate;               /* the band table below is for this rate */
    int lo[EQE_NSPEC], hi[EQE_NSPEC]; /* bin range per band (lo > hi: none) */
    double scale[EQE_NSPEC];   /* bands narrower than a bin: their share of the nearest bin */
    int32_t lvl[EQE_NSPEC];    /* 0.01 dBFS */
    uint32_t seq;
    int64_t at_ns;
} spec_t;

/* sliding minimum over the clip guard's look-ahead (a monotonic queue) */
typedef struct { double v; uint32_t t; } gq_t;

typedef struct eqe_ctx {
    const struct effect_interface_s *itfe; /* must be first: effect_handle_t points here */
    uint32_t magic;
    effect_config_t config;
    volatile int32_t enabled;
    int32_t session;
    int32_t io;
    eqe_settings set;
    /* design */
    double rate;
    int32_t design_ends;       /* the end-band types binv was made for */
    double binv[EQE_NB][EQE_NB];
    double gains[EQE_NB];      /* solved filter gains, dB (Easy mode) */
    band_t band[EQE_NFILT];    /* the bands, then the mono bass filter */
    int ramp_left;
    /* 0x326: mid/side */
    int ms;                    /* the bands run on mid and side (see band_t) */
    double wd_cur, wd_tgt, wd_inc; /* stereo width as a factor on the side, ramped like the bands */
    int wd_left;
    /* preamp, crossfade */
    double pre_cur, pre_tgt, pre_k;
    double w, w_tgt, w_step;
    /* clip guard */
    double dl[2][LA];
    /* listening-position delay */
    double dbuf[2][DMAX];
    int dpos;
    int dcur[2], dnew[2], dfade[2];
    gq_t gq[LA];               /* requested gains of the last LA samples that can still be the minimum */
    int gq_head, gq_n;
    uint32_t gq_clock;         /* sample counter for the queue */
    double box[LA];
    double boxsum;
    int box_low;               /* entries of box below 1 */
    int li;                    /* ring position */
    double g2, krel;
    /* live view and level */
    spec_t *spec;
    int64_t spec_wanted_ns;
    int spec_running;
    uint32_t blk_seq;
    int64_t blk_ns;
    int32_t blk_peak;
    uint64_t blk_ss;
    uint32_t blk_frames;
    int processing;            /* 0 = bit-exact delay path, 1 = processing path */
    uint32_t rng;
    /* statistics */
    uint32_t calls;
    uint64_t frames;
    uint32_t calls_sr;
    int64_t ns_sr;
    int32_t avg_ns;
    int32_t max_ns;
    int32_t in_peak_l, in_peak_r, out_peak;
    /* since the last read: sums of squares (for the average level) and frames, and input samples
       that arrived clipped (flat-topped: two or more consecutive samples at full scale) */
    uint64_t in_ss, out_ss, ss_frames;
    uint32_t in_clip_sr, in_clip_total;
    int32_t rail_sign[2], rail_run[2];
    double min_gain;
    uint32_t limited, clipped;
    int64_t last_call_ns;
    uint32_t unsupported, bad_buffers, configs;
    int32_t cfg_ok;           /* the last SET_CONFIG was 16-bit stereo in and out (others are refused) */
    int32_t peak_q[3];        /* the last EQE_PARAM_PEAK query's answer; peak_q_ok when there is one */
    int32_t peak_q_ok;
    int32_t logged_first;
    int64_t last_set_log;
    double yb[2 * EQE_CHUNK];  /* bands_block's output: one chunk, interleaved left and right */
} eqe_ctx;

static const double kCenters[EQE_NB] = {31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};

#ifndef EQE_CORE_ONLY
/* type 1de0ea4c-d55d-460b-a1e5-4a8c2e95c191, implementation 64b3439e-9662-4040-9fd1-83f116f74988 */
static const effect_descriptor_t gDescriptor = {
    { 0x1de0ea4c, 0xd55d, 0x460b, 0xa1e5, { 0x4a, 0x8c, 0x2e, 0x95, 0xc1, 0x91 } },
    { 0x64b3439e, 0x9662, 0x4040, 0x9fd1, { 0x83, 0xf1, 0x16, 0xf7, 0x49, 0x88 } },
    EFFECT_CONTROL_API_VERSION,
    EFFECT_FLAG_TYPE_INSERT | EFFECT_FLAG_INSERT_LAST,
    40, /* cpuLoad, 0.1 MIPS units (estimate) */
    8,  /* memoryUsage, KB (the live view's buffers, about 100 KB, exist only while the app shows it) */
    "EQ Engine (10-band EQ)",
    "EQ Engine",
};
#endif

static int64_t now_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static eqe_ctx *ctx_of(effect_handle_t self) {
    eqe_ctx *c = (eqe_ctx *)self;
    if (c == NULL || c->magic != EQE_MAGIC) return NULL;
    return c;
}

/* ------------------------------------------------------------------ filter design */

static const coefs_t kIdentity = {1.0, 0.0, 0.0, 0.0, 0.0};

static int is_identity(const coefs_t *k) {
    return k->b0 == 1.0 && k->b1 == 0.0 && k->b2 == 0.0 && k->a1 == 0.0 && k->a2 == 0.0;
}

/* RBJ peaking filter with Q = sqrt(2) (0.4 .. 0.6.4); kept for comparisons in the tests. */
static __attribute__((unused)) coefs_t peaking(double f0, double gain_db, double rate) {
    if (gain_db == 0.0 || rate <= 0.0 || f0 >= 0.45 * rate) return kIdentity;
    double A = pow(10.0, gain_db / 40.0);
    double w0 = 2.0 * EQE_PI * f0 / rate;
    double alpha = sin(w0) / (2.0 * BAND_Q);
    double cw = cos(w0);
    double a0 = 1.0 + alpha / A;
    coefs_t k;
    k.b0 = (1.0 + alpha * A) / a0;
    k.b1 = (-2.0 * cw) / a0;
    k.b2 = (1.0 - alpha * A) / a0;
    k.a1 = (-2.0 * cw) / a0;
    k.a2 = (1.0 - alpha / A) / a0;
    return k;
}

/* RBJ peaking filter, BAND_BW_OCT octaves between the half-gain points, with the bandwidth
 * prewarped (the cookbook's BW form). Far below Nyquist it is the Q = sqrt(2) filter above; near
 * Nyquist the plain Q form gets narrower (at 44.1 kHz the 16 kHz bell was about a third as
 * wide), which left a dip between 8 and 16 kHz when both were raised. */
static coefs_t bell_bw(double f0, double gain_db, double bw_oct, double rate) {
    if (gain_db == 0.0 || rate <= 0.0 || f0 >= 0.45 * rate) return kIdentity;
    double A = pow(10.0, gain_db / 40.0);
    double w0 = 2.0 * EQE_PI * f0 / rate;
    double sw = sin(w0), cw = cos(w0);
    double alpha = sw * sinh(0.5 * log(2.0) * bw_oct * w0 / sw);
    double a0 = 1.0 + alpha / A;
    coefs_t k;
    k.b0 = (1.0 + alpha * A) / a0;
    k.b1 = (-2.0 * cw) / a0;
    k.b2 = (1.0 - alpha * A) / a0;
    k.a1 = (-2.0 * cw) / a0;
    k.a2 = (1.0 - alpha / A) / a0;
    return k;
}

static coefs_t bell(double f0, double gain_db, double rate) { return bell_bw(f0, gain_db, BAND_BW_OCT, rate); }

/* RBJ high-pass (Expert's low cut), 12 dB an octave below f0; q = 0.707 is Butterworth. */
static coefs_t lowcut(double f0, double q, double rate) {
    if (rate <= 0.0 || f0 >= 0.45 * rate || q <= 0.0) return kIdentity;
    double w0 = 2.0 * EQE_PI * f0 / rate;
    double cw = cos(w0), alpha = sin(w0) / (2.0 * q);
    double a0 = 1.0 + alpha;
    coefs_t k = {(1.0 + cw) / 2.0 / a0, -(1.0 + cw) / a0, (1.0 + cw) / 2.0 / a0, -2.0 * cw / a0, (1.0 - alpha) / a0};
    return k;
}

/* RBJ shelving filter, slope S = 1; f0 is the midpoint (half the shelf's gain in dB). */
static coefs_t shelf(int high, double f0, double gain_db, double rate) {
    if (gain_db == 0.0 || rate <= 0.0 || f0 >= 0.45 * rate) return kIdentity;
    double A = pow(10.0, gain_db / 40.0);
    double w0 = 2.0 * EQE_PI * f0 / rate;
    double cw = cos(w0), sw = sin(w0);
    double alpha = sw / 2.0 * sqrt(2.0); /* S = 1 */
    double sa = 2.0 * sqrt(A) * alpha;
    double b0, b1, b2, a0, a1, a2;
    if (!high) {
        b0 = A * ((A + 1.0) - (A - 1.0) * cw + sa);
        b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cw);
        b2 = A * ((A + 1.0) - (A - 1.0) * cw - sa);
        a0 = (A + 1.0) + (A - 1.0) * cw + sa;
        a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cw);
        a2 = (A + 1.0) + (A - 1.0) * cw - sa;
    } else {
        b0 = A * ((A + 1.0) + (A - 1.0) * cw + sa);
        b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw);
        b2 = A * ((A + 1.0) + (A - 1.0) * cw - sa);
        a0 = (A + 1.0) - (A - 1.0) * cw + sa;
        a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cw);
        a2 = (A + 1.0) - (A - 1.0) * cw - sa;
    }
    coefs_t k = {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
    return k;
}

static coefs_t shelf(int high, double f0, double gain_db, double rate);

/* An Expert band (eqe_settings.x[j]). */
static coefs_t xband_coefs(const int32_t b[4], double rate) {
    double f = b[1] / 100.0, g = b[2] / 100.0;
    switch (EQE_X_TYPE(b[0])) {
    case EQE_X_PEAK: return bell_bw(f, g, b[3] / 1000.0, rate);
    case EQE_X_LOW_SHELF: return shelf(0, f, g, rate);
    case EQE_X_HIGH_SHELF: return shelf(1, f, g, rate);
    case EQE_X_LOW_CUT: return lowcut(f, b[3] / 1000.0, rate);
    default: return kIdentity;
    }
}

/* Band j's filter at gain g (dB), with the end-band types in `ends`. */
static coefs_t band_coefs(int32_t ends, int j, double g, double rate) {
    if (j == 0 && (ends & EQE_ENDS_LOW)) return shelf(0, LOW_SHELF_HZ, g, rate);
    if (j == EQE_NB - 1 && (ends & EQE_ENDS_HIGH)) return shelf(1, HIGH_SHELF_HZ, g, rate);
    return bell(kCenters[j], g, rate);
}

static double coefs_db(const coefs_t *k, double f, double rate) {
    double w = 2.0 * EQE_PI * f / rate;
    double c1 = cos(w), s1 = sin(w), c2 = cos(2.0 * w), s2 = sin(2.0 * w);
    double nr = k->b0 + k->b1 * c1 + k->b2 * c2, ni = -(k->b1 * s1 + k->b2 * s2);
    double dr = 1.0 + k->a1 * c1 + k->a2 * c2, di = -(k->a1 * s1 + k->a2 * s2);
    double num = nr * nr + ni * ni, den = dr * dr + di * di;
    if (num <= 0.0 || den <= 0.0) return -200.0;
    return 10.0 * log10(num / den);
}

/* Gauss-Jordan inverse with partial pivoting; returns 0 on success. */
static int invert(double m[EQE_NB][EQE_NB], double out[EQE_NB][EQE_NB]) {
    double a[EQE_NB][2 * EQE_NB];
    for (int i = 0; i < EQE_NB; i++)
        for (int j = 0; j < 2 * EQE_NB; j++) a[i][j] = j < EQE_NB ? m[i][j] : (j - EQE_NB == i ? 1.0 : 0.0);
    for (int col = 0; col < EQE_NB; col++) {
        int piv = col;
        for (int r = col + 1; r < EQE_NB; r++)
            if (fabs(a[r][col]) > fabs(a[piv][col])) piv = r;
        if (fabs(a[piv][col]) < 1e-9) return -1;
        if (piv != col)
            for (int j = 0; j < 2 * EQE_NB; j++) { double t = a[col][j]; a[col][j] = a[piv][j]; a[piv][j] = t; }
        double d = a[col][col];
        for (int j = 0; j < 2 * EQE_NB; j++) a[col][j] /= d;
        for (int r = 0; r < EQE_NB; r++) {
            if (r == col) continue;
            double f = a[r][col];
            if (f == 0.0) continue;
            for (int j = 0; j < 2 * EQE_NB; j++) a[r][j] -= f * a[col][j];
        }
    }
    for (int i = 0; i < EQE_NB; i++)
        for (int j = 0; j < EQE_NB; j++) out[i][j] = a[i][j + EQE_NB];
    return 0;
}

static int band_usable(double rate, int j) { return kCenters[j] < 0.45 * rate; }

/* Interaction matrix for the current sample rate and end-band types: response of band j (at
 * +12 dB) at centre i. */
static void prepare_matrix(eqe_ctx *c) {
    double m[EQE_NB][EQE_NB];
    c->design_ends = c->set.ends;
    for (int j = 0; j < EQE_NB; j++) {
        coefs_t k = band_coefs(c->set.ends, j, 12.0, c->rate);
        for (int i = 0; i < EQE_NB; i++) {
            if (!band_usable(c->rate, i) || !band_usable(c->rate, j)) {
                m[i][j] = i == j ? 1.0 : 0.0;
            } else {
                m[i][j] = coefs_db(&k, kCenters[i], c->rate) / 12.0;
            }
        }
    }
    if (invert(m, c->binv) != 0) {
        /* Not expected for octave bands; fall back to no correction. */
        for (int i = 0; i < EQE_NB; i++)
            for (int j = 0; j < EQE_NB; j++) c->binv[i][j] = i == j ? 1.0 : 0.0;
        LOGW("interaction matrix not invertible at %.0f Hz; sliders are used as filter gains", c->rate);
    }
}

/* Everything that depends on the sample rate. */
static void prepare_rate(eqe_ctx *c) {
    prepare_matrix(c);
    c->pre_k = 1.0 - exp(-1.0 / (0.010 * c->rate));
    c->krel = 1.0 - exp(-1.0 / (0.080 * c->rate));
}

static double clampd(double v, double lo, double hi) { return v < lo ? lo : v > hi ? hi : v; }

/* Solves filter gains so the response at each centre equals its slider. */
static void solve_gains(eqe_ctx *c, double g[EQE_NB]) {
    double t[EQE_NB];
    int any = 0;
    for (int i = 0; i < EQE_NB; i++) {
        t[i] = band_usable(c->rate, i) ? c->set.band_cdb[i] / 100.0 : 0.0;
        if (t[i] != 0.0) any = 1;
    }
    if (!any) {
        for (int i = 0; i < EQE_NB; i++) g[i] = 0.0;
        return;
    }
    for (int i = 0; i < EQE_NB; i++) {
        double s = 0.0;
        for (int j = 0; j < EQE_NB; j++) s += c->binv[i][j] * t[j];
        g[i] = clampd(s, -EQE_GAIN_CLAMP, EQE_GAIN_CLAMP);
    }
    for (int pass = 0; pass < 3; pass++) {
        coefs_t k[EQE_NB];
        for (int j = 0; j < EQE_NB; j++) k[j] = band_coefs(c->set.ends, j, g[j], c->rate);
        double e[EQE_NB];
        for (int i = 0; i < EQE_NB; i++) {
            double r = 0.0;
            if (band_usable(c->rate, i))
                for (int j = 0; j < EQE_NB; j++) r += coefs_db(&k[j], kCenters[i], c->rate);
            e[i] = band_usable(c->rate, i) ? t[i] - r : 0.0;
        }
        for (int i = 0; i < EQE_NB; i++) {
            double s = 0.0;
            for (int j = 0; j < EQE_NB; j++) s += c->binv[i][j] * e[j];
            g[i] = clampd(g[i] + s, -EQE_GAIN_CLAMP, EQE_GAIN_CLAMP);
        }
    }
    for (int i = 0; i < EQE_NB; i++) {
        if (!band_usable(c->rate, i)) g[i] = 0.0;
        /* tiny residues: keep the band off */
        if (fabs(g[i]) < 0.005) g[i] = 0.0;
    }
}

/* 0x326: a filter is identity on both lanes (lane 1 counts only while the bands run on mid and side,
   or when its target differs from lane 0's) */
static int band_identity(const eqe_ctx *c, const band_t *b) {
    if (!(is_identity(&b->cur) && is_identity(&b->tgt))) return 0;
    if (!is_identity(&b->tgt1)) return 0;
    return !c->ms || is_identity(&b->cur1);
}

/* A new filter: every band and the mono bass off on both lanes, the width as recorded. */
static void filters_init(eqe_ctx *c) {
    for (int j = 0; j < EQE_NFILT; j++) {
        band_t *b = &c->band[j];
        b->cur = b->tgt = b->cur1 = b->tgt1 = kIdentity;
    }
    c->wd_cur = c->wd_tgt = 1.0;
}

static void reset_states(eqe_ctx *c) {
    for (int j = 0; j < EQE_NFILT; j++) {
        band_t *b = &c->band[j];
        b->z1[0] = b->z1[1] = b->z2[0] = b->z2[1] = 0.0;
        b->active = !band_identity(c, b);
    }
    memset(c->dbuf, 0, sizeof(c->dbuf));
    for (int ch = 0; ch < 2; ch++) {
        if (c->dfade[ch] > 0) c->dcur[ch] = c->dnew[ch];
        c->dfade[ch] = 0;
    }
}

static int delay_samples(const eqe_ctx *c, int ch) {
    if (c->rate <= 0.0) return 0;
    int d = (int)floor(c->set.delay_us[ch] * c->rate / 1e6 + 0.5);
    if (d < 0) d = 0;
    if (d > DMAX - 1) d = DMAX - 1;
    return d;
}

static void reset_guard(eqe_ctx *c) {
    memset(c->dl, 0, sizeof(c->dl));
    for (int i = 0; i < LA; i++) c->box[i] = 1.0;
    c->boxsum = LA;
    c->box_low = 0;
    c->gq_head = c->gq_n = 0;
    c->li = 0;
    c->g2 = 1.0;
}

/* Adds this sample's requested gain to the look-ahead window and returns the smallest request of
 * the last LA samples (1.0 when none asked for less). The same as scanning the window, in O(1)
 * per sample on average. */
static inline double guard_min_push(eqe_ctx *c, double req) {
    uint32_t t = ++c->gq_clock;
    /* drop requests that left the window (older than LA samples) */
    while (c->gq_n > 0 && t - c->gq[c->gq_head].t >= LA) {
        c->gq_head = (c->gq_head + 1) & (LA - 1);
        c->gq_n--;
    }
    if (req < 1.0) {
        /* drop newer-but-larger requests from the back: they can never be the minimum again */
        while (c->gq_n > 0 && c->gq[(c->gq_head + c->gq_n - 1) & (LA - 1)].v >= req) c->gq_n--;
        int at = (c->gq_head + c->gq_n) & (LA - 1);
        c->gq[at].v = req;
        c->gq[at].t = t;
        c->gq_n++;
    }
    return c->gq_n > 0 ? c->gq[c->gq_head].v : 1.0;
}

/* Applies c->set. jump = 1: no ramps (new sample rate or first config). */
static void apply_settings(eqe_ctx *c, int jump) {
    c->pre_tgt = pow(10.0, c->set.preamp_cdb / 2000.0);
    c->w_tgt = c->set.eq_on ? 1.0 : 0.0;
    /* 0x326: the stereo width (the settings before the first arrive, layout 0, mean as recorded) */
    double wd = c->set.layout >= 4 ? c->set.width_pct / 100.0 : 1.0;
    if (c->rate <= 0.0) {
        c->wd_tgt = c->wd_cur = wd;
        c->wd_left = 0;
        return;
    }
    /* while the lanes are left and right, lane 1's coefficients are lane 0's (not kept apart) */
    if (!c->ms)
        for (int j = 0; j < EQE_NFILT; j++) c->band[j].cur1 = c->band[j].cur;
    if (c->set.mode == 1) {
        /* Expert: each band is what it says (no solver), on its channel; the rest are off */
        for (int j = 0; j < EQE_NB; j++) c->gains[j] = 0.0;
        for (int j = 0; j < EQE_NBAND; j++) {
            band_t *b = &c->band[j];
            coefs_t k = j < c->set.nx ? xband_coefs(c->set.x[j], c->rate) : kIdentity;
            int ch = j < c->set.nx ? EQE_X_CH(c->set.x[j][0]) : EQE_CH_LR;
            b->tgt = ch == EQE_CH_SIDE ? kIdentity : k;
            b->tgt1 = ch == EQE_CH_MID ? kIdentity : k;
        }
    } else {
        if (c->set.ends != c->design_ends) prepare_matrix(c);
        solve_gains(c, c->gains);
        for (int j = 0; j < EQE_NBAND; j++)
            c->band[j].tgt = c->band[j].tgt1 = j < EQE_NB ? band_coefs(c->set.ends, j, c->gains[j], c->rate) : kIdentity;
    }
    /* mono bass: the side's lows taken away (12 dB an octave below mono_hz) */
    c->band[EQE_MONO].tgt = kIdentity;
    c->band[EQE_MONO].tgt1 = c->set.layout >= 4 && c->set.mono_hz > 0 ? lowcut(c->set.mono_hz, 0.70710678118654752, c->rate) : kIdentity;
    /* (a ramp between two stable biquads stays stable: the stable (a1, a2) region is convex) */
    for (int j = 0; j < EQE_NFILT; j++) {
        band_t *b = &c->band[j];
        if (jump) {
            b->cur = b->tgt;
            b->cur1 = b->tgt1;
        }
        if (!band_identity(c, b) || !is_identity(&b->cur1)) b->active = 1;
    }
    if (jump) {
        c->ramp_left = 0;
        c->pre_cur = c->pre_tgt;
        c->wd_cur = c->wd_tgt = wd;
        c->wd_left = 0;
    } else {
        for (int j = 0; j < EQE_NFILT; j++) {
            band_t *b = &c->band[j];
            b->inc.b0 = (b->tgt.b0 - b->cur.b0) / RAMP_LEN;
            b->inc.b1 = (b->tgt.b1 - b->cur.b1) / RAMP_LEN;
            b->inc.b2 = (b->tgt.b2 - b->cur.b2) / RAMP_LEN;
            b->inc.a1 = (b->tgt.a1 - b->cur.a1) / RAMP_LEN;
            b->inc.a2 = (b->tgt.a2 - b->cur.a2) / RAMP_LEN;
            b->inc1.b0 = (b->tgt1.b0 - b->cur1.b0) / RAMP_LEN;
            b->inc1.b1 = (b->tgt1.b1 - b->cur1.b1) / RAMP_LEN;
            b->inc1.b2 = (b->tgt1.b2 - b->cur1.b2) / RAMP_LEN;
            b->inc1.a1 = (b->tgt1.a1 - b->cur1.a1) / RAMP_LEN;
            b->inc1.a2 = (b->tgt1.a2 - b->cur1.a2) / RAMP_LEN;
        }
        c->ramp_left = RAMP_LEN;
        if (wd != c->wd_tgt || c->wd_left > 0) {
            c->wd_tgt = wd;
            c->wd_inc = (wd - c->wd_cur) / RAMP_LEN;
            c->wd_left = c->wd_cur == wd ? 0 : RAMP_LEN;
        }
    }
    c->w_step = 1.0 / XFADE_LEN;
    for (int ch = 0; ch < 2; ch++) {
        int d = delay_samples(c, ch);
        if (jump) {
            c->dcur[ch] = c->dnew[ch] = d;
            c->dfade[ch] = 0;
        } else if (d != (c->dfade[ch] > 0 ? c->dnew[ch] : c->dcur[ch])) {
            if (c->dfade[ch] > 0) c->dcur[ch] = c->dnew[ch]; /* a change during a fade: start from the newer tap */
            c->dnew[ch] = d;
            c->dfade[ch] = DFADE_LEN;
        }
    }
}

static int xband_valid(const int32_t b[4]) {
    int t = EQE_X_TYPE(b[0]);
    if (b[0] < 0 || (b[0] & ~0x3F) || EQE_X_CH(b[0]) > EQE_CH_SIDE) return 0;
    if (t < EQE_X_PEAK || t > EQE_X_LOW_CUT) return 0;
    if (b[1] < EQE_X_FMIN || b[1] > EQE_X_FMAX) return 0;
    if (t != EQE_X_LOW_CUT && (b[2] < -EQE_BAND_LIMIT || b[2] > EQE_BAND_LIMIT)) return 0;
    if (t == EQE_X_PEAK && (b[3] < EQE_X_BWMIN || b[3] > EQE_X_BWMAX)) return 0;
    if (t == EQE_X_LOW_CUT && (b[3] < EQE_X_QMIN || b[3] > EQE_X_QMAX)) return 0;
    return 1;
}

static int settings_valid(const eqe_settings *s) {
    if (s->layout != 4) return 0;
    if (s->width_pct < 0 || s->width_pct > EQE_WIDTH_MAX) return 0;
    if (s->mono_hz != 0 && (s->mono_hz < EQE_MONO_MIN || s->mono_hz > EQE_MONO_MAX)) return 0;
    if (s->mode != 0 && s->mode != 1) return 0;
    if (s->nx < 0 || s->nx > EQE_NX) return 0;
    for (int j = 0; j < s->nx; j++)
        if (!xband_valid(s->x[j])) return 0;
    if (s->ends & ~(EQE_ENDS_LOW | EQE_ENDS_HIGH)) return 0;
    if (s->eq_on != 0 && s->eq_on != 1) return 0;
    if (s->guard_on != 0 && s->guard_on != 1) return 0;
    if (s->preamp_cdb < EQE_PRE_MIN || s->preamp_cdb > EQE_PRE_MAX) return 0;
    for (int i = 0; i < EQE_NB; i++)
        if (s->band_cdb[i] < -EQE_BAND_LIMIT || s->band_cdb[i] > EQE_BAND_LIMIT) return 0;
    for (int ch = 0; ch < 2; ch++)
        if (s->delay_us[ch] < 0 || s->delay_us[ch] > EQE_DELAY_MAX_US) return 0;
    return 1;
}

/* Settings from a SET_PARAM value of n bytes: layout 4, or an older app's layout 3 (no mid/side), 2
 * or 1 (Easy mode). Unused Expert slots are cleared. 1 when they are valid. */
static int settings_from(const char *v, uint32_t n, eqe_settings *s) {
    memset(s, 0, sizeof(*s));
    if (n == sizeof(eqe_settings)) {
        memcpy(s, v, n);
        if (s->layout != 4) return 0;
    } else if (n == EQE_SET3_BYTES) {
        /* 0.7.1 .. 0.7.7 (and the CarPlay layer's control file from them): no channel in the band types */
        memcpy(s, v, n);
        if (s->layout != 3) return 0;
        for (int j = 0; j < s->nx && j < EQE_NX; j++)
            if (s->x[j][0] & ~0xF) return 0;
        s->layout = 4;
        s->width_pct = 100;
    } else if (n == EQE_SET2_BYTES) {
        memcpy(s, v, n);
        if (s->layout != 2) return 0;
        s->layout = 4;
        s->width_pct = 100;
    } else if (n == EQE_SET1_BYTES) {
        /* an app from before 0.6.6: layout 1, both end bands peaks */
        memcpy(s, v, n);
        if (s->layout != 1) return 0;
        s->layout = 4;
        s->width_pct = 100;
        s->ends = 0;
    } else {
        return 0;
    }
    if (!settings_valid(s)) return 0;
    for (int j = s->nx; j < EQE_NX; j++) memset(s->x[j], 0, sizeof(s->x[j]));
    return 1;
}

static double eqe_resp_hz(int k) { return 20.0 * pow(1000.0, (double)k / (EQE_NRESP - 1)); }

/* ------------------------------------------------------------------ headroom
 *
 * The largest steady-state gain of a set of solved band filters, from 0 Hz to half the sample
 * rate: what a preamp must take away so that no frequency comes out louder than it went in.
 * The graph's 96 points (20 Hz to 20 kHz) are not enough for that: a low shelf goes on rising
 * below 20 Hz up to its full gain at 0 Hz, and the solver can set that gain well above the
 * slider (31 Hz +12 dB next to 63 Hz -12 dB: about +22 dB at 0 Hz); a high shelf goes on rising
 * above 20 kHz. So the two ends are taken exactly, the rest by a 1 % log sweep from 1 Hz, and
 * the best point of the sweep is looked at again in 0.05 % steps. Runs only when the app asks
 * (EQE_PARAM_PEAK), never in the audio path. */
static double resp_db(const coefs_t k[EQE_NBAND], double f, double rate) {
    double d = 0.0;
    for (int j = 0; j < EQE_NBAND; j++)
        if (!is_identity(&k[j])) d += coefs_db(&k[j], f, rate);
    return d;
}

static double peak_gain(const coefs_t k[EQE_NBAND], double rate, double *at_hz) {
    double nyq = 0.5 * rate;
    double best = resp_db(k, 0.0, rate), at = 0.0;
    double d = resp_db(k, nyq, rate);
    if (d > best) { best = d; at = nyq; }
    double fbest = -1.0;
    for (double f = 1.0; f < nyq; f *= 1.01) {
        d = resp_db(k, f, rate);
        if (d > best) { best = d; at = f; fbest = f; }
    }
    if (fbest > 0.0) {
        for (double f = fbest / 1.01; f < fbest * 1.01 && f < nyq; f *= 1.0005) {
            d = resp_db(k, f, rate);
            if (d > best) { best = d; at = f; }
        }
    }
    *at_hz = at;
    return best;
}

/* 0x326, mid/side: each lane's response is the product of its filters' (complex), the side's times
 * the width. Out of the left speaker comes (Hm + w Hs) / 2 of the left input plus (Hm - w Hs) / 2 of
 * the right (the right speaker the same, mirrored), so the most a speaker can get at f, for any
 * input with both sides within full scale, is (|Hm + w Hs| + |Hm - w Hs|) / 2: |Hm| for a mid-only
 * signal, |w Hs| for a side-only one, more when the two lanes differ in phase. Equal lanes and
 * w = 1 give back |H|. */
static void coefs_h(const coefs_t *k, double w, double *re, double *im) {
    double c1 = cos(w), s1 = sin(w), c2 = cos(2.0 * w), s2 = sin(2.0 * w);
    double nr = k->b0 + k->b1 * c1 + k->b2 * c2, ni = -(k->b1 * s1 + k->b2 * s2);
    double dr = 1.0 + k->a1 * c1 + k->a2 * c2, di = -(k->a1 * s1 + k->a2 * s2);
    double den = dr * dr + di * di;
    if (den <= 0.0) { *re = 0.0; *im = 0.0; return; }
    *re = (nr * dr + ni * di) / den;
    *im = (ni * dr - nr * di) / den;
}

static double ms_resp_db(const coefs_t k0[EQE_NFILT], const coefs_t k1[EQE_NFILT], double wd, double f, double rate) {
    double w = 2.0 * EQE_PI * f / rate;
    double mr = 1.0, mi = 0.0, sr = wd, si = 0.0;
    for (int j = 0; j < EQE_NFILT; j++) {
        double r, i, t;
        if (!is_identity(&k0[j])) {
            coefs_h(&k0[j], w, &r, &i);
            t = mr * r - mi * i; mi = mr * i + mi * r; mr = t;
        }
        if (!is_identity(&k1[j])) {
            coefs_h(&k1[j], w, &r, &i);
            t = sr * r - si * i; si = sr * i + si * r; sr = t;
        }
    }
    double a = hypot(mr + sr, mi + si), b = hypot(mr - sr, mi - si);
    double g = 0.5 * (a + b);
    return g > 1e-10 ? 20.0 * log10(g) : -200.0;
}

static double ms_peak_gain(const coefs_t k0[EQE_NFILT], const coefs_t k1[EQE_NFILT], double wd, double rate, double *at_hz) {
    double nyq = 0.5 * rate;
    double best = ms_resp_db(k0, k1, wd, 0.0, rate), at = 0.0;
    double d = ms_resp_db(k0, k1, wd, nyq, rate);
    if (d > best) { best = d; at = nyq; }
    double fbest = -1.0;
    for (double f = 1.0; f < nyq; f *= 1.01) {
        d = ms_resp_db(k0, k1, wd, f, rate);
        if (d > best) { best = d; at = f; fbest = f; }
    }
    if (fbest > 0.0) {
        for (double f = fbest / 1.01; f < fbest * 1.01 && f < nyq; f *= 1.0005) {
            d = ms_resp_db(k0, k1, wd, f, rate);
            if (d > best) { best = d; at = f; }
        }
    }
    *at_hz = at;
    return best;
}

/* settings s use mid/side (width, mono bass, or an Expert band on the mid or the side only) */
static int settings_ms(const eqe_settings *s) {
    if (s->layout < 4) return 0;
    if (s->width_pct != 100 || s->mono_hz != 0) return 1;
    if (s->mode == 1)
        for (int j = 0; j < s->nx && j < EQE_NX; j++)
            if (EQE_X_CH(s->x[j][0]) != EQE_CH_LR) return 1;
    return 0;
}

/* Answers EQE_PARAM_PEAK for settings s at this filter's rate, without touching what plays:
 * [0] the largest gain of s's solved band filters in 0.01 dB (rounded up; the preamp and the
 * on/off switch are not included), [1] where, in Hz (0 = 0 Hz), [2] the rate it was worked
 * out for. -1 when the rate is not known yet or memory is short. */
static int peak_query(const eqe_ctx *c, const eqe_settings *s, int32_t out[3]) {
    if (c->rate <= 0.0) return -1;
    /* the solver's inputs only (rate, settings, interaction matrix), in a scratch context */
    eqe_ctx *t = (eqe_ctx *)calloc(1, sizeof(eqe_ctx));
    if (t == NULL) return -1;
    /* 0.7.6 (0x324): the same settings also play at CarPlay's 44.1 kHz (and Android's output can be at
       either rate), and a band at or above 0.45 of a rate is left out at that rate: a 20 kHz cut
       works at 48 kHz but not at 44.1 kHz. So the largest boost over this filter's rate, 44.1 and
       48 kHz; [2] says at which rate it is. */
    const double rates[3] = {c->rate, 44100.0, 48000.0};
    double best = -1e300, best_at = 0.0, best_rate = c->rate;
    for (int r = 0; r < 3; r++) {
        if (r > 0 && rates[r] == c->rate) continue;
        t->rate = rates[r];
        t->set = *s;
        t->design_ends = 0;
        prepare_matrix(t);
        coefs_t k[EQE_NFILT];
        if (s->mode == 1) {
            for (int j = 0; j < EQE_NBAND; j++) k[j] = j < s->nx ? xband_coefs(s->x[j], t->rate) : kIdentity;
        } else {
            double g[EQE_NB];
            solve_gains(t, g);
            for (int j = 0; j < EQE_NBAND; j++) k[j] = j < EQE_NB ? band_coefs(s->ends, j, g[j], t->rate) : kIdentity;
        }
        double at, p;
        if (!settings_ms(s)) {
            p = peak_gain(k, t->rate, &at);
        } else {
            /* 0x326: each lane's filters, the width and the mono bass */
            coefs_t k0[EQE_NFILT], k1[EQE_NFILT];
            for (int j = 0; j < EQE_NBAND; j++) {
                int ch = s->mode == 1 && j < s->nx ? EQE_X_CH(s->x[j][0]) : EQE_CH_LR;
                k0[j] = ch == EQE_CH_SIDE ? kIdentity : k[j];
                k1[j] = ch == EQE_CH_MID ? kIdentity : k[j];
            }
            k0[EQE_MONO] = kIdentity;
            k1[EQE_MONO] = s->mono_hz > 0 ? lowcut(s->mono_hz, 0.70710678118654752, t->rate) : kIdentity;
            p = ms_peak_gain(k0, k1, s->width_pct / 100.0, t->rate, &at);
        }
        if (p > best + 1e-9) {
            best = p;
            best_at = at;
            best_rate = t->rate;
        }
    }
    free(t);
    out[0] = (int32_t)ceil(best * 100.0 - 1e-6);
    out[1] = (int32_t)floor(best_at + 0.5);
    out[2] = (int32_t)best_rate;
    return 0;
}

/* ------------------------------------------------------------------ processing */

static inline double biquad(band_t *b, int ch, double x) {
    double y = b->cur.b0 * x + b->z1[ch];
    b->z1[ch] = b->cur.b1 * x - b->cur.a1 * y + b->z2[ch];
    b->z2[ch] = b->cur.b2 * x - b->cur.a2 * y;
    return y;
}

static inline double uni(eqe_ctx *c) {
    uint32_t x = c->rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    c->rng = x;
    return (double)(x >> 8) * (1.0 / 16777216.0);
}

/* floor(s + 0.5) without a libm call (VFPv3 has no rounding instruction): shifted to positive and
 * truncated. Exact for |s| < 2^30, which quantise() makes sure of. */
static inline int32_t round_half_up(double s) {
    return (int32_t)((uint32_t)(s + 1073741824.5) - 1073741824u);
}

static inline int32_t quantise(eqe_ctx *c, double v, int guard) {
    double s = v * 32768.0;
    if (!(s < 1e9)) s = 1e9;        /* also catches NaN */
    else if (s < -1e9) s = -1e9;
    int32_t r = round_half_up(s);
    if ((double)r != s) r = round_half_up(s + uni(c) - uni(c));
    if (r > 32767) {
        if (!guard) c->clipped++;
        return 32767;
    }
    if (r < -32768) {
        if (!guard) c->clipped++;
        return -32768;
    }
    return r;
}

/* Flat-top detection for one input sample: a run of 2 or more consecutive samples at the same
   full-scale rail counts every sample of the run. Returns the number of samples to add. */
static inline uint32_t rail_count(eqe_ctx *c, int ch, int32_t x) {
    int32_t sg = x >= 32767 ? 1 : x <= -32767 ? -1 : 0;
    if (sg == 0 || sg != c->rail_sign[ch]) {
        c->rail_sign[ch] = sg;
        c->rail_run[ch] = sg != 0;
        return 0;
    }
    if (++c->rail_run[ch] == 2) return 2;
    return 1;
}

/* The preamp and the band filters over n frames (n <= EQE_CHUNK), into c->yb (0.7.4). Each band
 * runs over the whole chunk with its coefficients and states in registers, instead of every band
 * being loaded and stored again for every sample: the same arithmetic in the same order as the
 * per-sample path below, so the same samples bit for bit (tests/host_test.c checks it against
 * 0.7.3's code), with far fewer loads and stores. Only for a chunk that takes the processing
 * path from its first sample to its last: processing, not transparent, EQ on (w_tgt > 0, so it
 * cannot drop back to the bit-exact path inside the chunk). */
static void bands_block(eqe_ctx *c, const int16_t *src, size_t n, band_t *const *act, int nb) {
    double *y = c->yb;
    for (size_t f = 0; f < n; f++) {
        if (c->pre_cur != c->pre_tgt) {
            c->pre_cur += (c->pre_tgt - c->pre_cur) * c->pre_k;
            if (fabs(c->pre_tgt - c->pre_cur) < 1e-12) c->pre_cur = c->pre_tgt;
        }
        int32_t il = src[2 * f], ir = src[2 * f + 1];
        double xl = il * (1.0 / 32768.0), xr = ir * (1.0 / 32768.0);
        y[2 * f] = xl * c->pre_cur;
        y[2 * f + 1] = xr * c->pre_cur;
    }
    /* a ramp moves every band's coefficients one step per sample, and ends (at tgt) with its last */
    size_t rn = c->ramp_left <= 0 ? 0 : (size_t)c->ramp_left < n ? (size_t)c->ramp_left : n;
    int ends = rn > 0 && (size_t)c->ramp_left <= n;
    for (int k = 0; k < nb; k++) {
        band_t *b = act[k];
        double b0 = b->cur.b0, b1 = b->cur.b1, b2 = b->cur.b2, a1 = b->cur.a1, a2 = b->cur.a2;
        double l1 = b->z1[0], l2 = b->z2[0], r1 = b->z1[1], r2 = b->z2[1];
        size_t f = 0;
        if (rn > 0) {
            const coefs_t in = b->inc;
            for (; f < rn; f++) {
                double xl = y[2 * f], xr = y[2 * f + 1];
                double yl = b0 * xl + l1;
                l1 = b1 * xl - a1 * yl + l2;
                l2 = b2 * xl - a2 * yl;
                double yr = b0 * xr + r1;
                r1 = b1 * xr - a1 * yr + r2;
                r2 = b2 * xr - a2 * yr;
                y[2 * f] = yl;
                y[2 * f + 1] = yr;
                b0 += in.b0;
                b1 += in.b1;
                b2 += in.b2;
                a1 += in.a1;
                a2 += in.a2;
            }
            if (ends) {
                b0 = b->tgt.b0;
                b1 = b->tgt.b1;
                b2 = b->tgt.b2;
                a1 = b->tgt.a1;
                a2 = b->tgt.a2;
            }
        }
        for (; f < n; f++) {
            double xl = y[2 * f], xr = y[2 * f + 1];
            double yl = b0 * xl + l1;
            l1 = b1 * xl - a1 * yl + l2;
            l2 = b2 * xl - a2 * yl;
            double yr = b0 * xr + r1;
            r1 = b1 * xr - a1 * yr + r2;
            r2 = b2 * xr - a2 * yr;
            y[2 * f] = yl;
            y[2 * f + 1] = yr;
        }
        b->cur.b0 = b0;
        b->cur.b1 = b1;
        b->cur.b2 = b2;
        b->cur.a1 = a1;
        b->cur.a2 = a2;
        b->z1[0] = l1;
        b->z2[0] = l2;
        b->z1[1] = r1;
        b->z2[1] = r2;
    }
    if (rn > 0) {
        c->ramp_left -= (int)rn;
        if (c->ramp_left == 0)
            for (int j = 0; j < EQE_NBAND; j++) c->band[j].cur = c->band[j].tgt;
    }
}

/* 0x326: whether the bands must run on mid and side: a width other than 100 % (or on its way), or a
 * filter whose two lanes differ (an Expert band on the mid or the side only, the mono bass, or one
 * still ramping out of that). On a change the filters' states are carried over to the other lanes
 * (the filters are linear and, while the lanes are left and right, the same on both, so the
 * output carries on as if nothing changed). Called at the start of each buffer. */
static void ms_update(eqe_ctx *c) {
    int need = c->wd_cur != 1.0 || c->wd_tgt != 1.0 || c->wd_left > 0;
    for (int j = 0; j < EQE_NFILT && !need; j++) {
        const band_t *b = &c->band[j];
        if (memcmp(&b->tgt, &b->tgt1, sizeof(coefs_t)) != 0) need = 1;
        else if (c->ms && memcmp(&b->cur, &b->cur1, sizeof(coefs_t)) != 0) need = 1;
    }
    if (need == c->ms) return;
    for (int j = 0; j < EQE_NFILT; j++) {
        band_t *b = &c->band[j];
        double a1 = b->z1[0], c1 = b->z1[1], a2 = b->z2[0], c2 = b->z2[1];
        if (need) {
            /* left/right -> mid/side; lane 1 starts from lane 0's coefficients (apply_settings made
               them equal before setting a different target) */
            b->z1[0] = (a1 + c1) * 0.5;
            b->z1[1] = (a1 - c1) * 0.5;
            b->z2[0] = (a2 + c2) * 0.5;
            b->z2[1] = (a2 - c2) * 0.5;
        } else {
            b->z1[0] = a1 + c1;
            b->z1[1] = a1 - c1;
            b->z2[0] = a2 + c2;
            b->z2[1] = a2 - c2;
        }
    }
    c->ms = need;
}

/* 0x326: bands_block while the bands run on mid and side: the preamp, left/right to mid/side, each
 * filter with each lane's own coefficients, the width on the side, and back to left/right. */
static void bands_block_ms(eqe_ctx *c, const int16_t *src, size_t n, band_t *const *act, int nb) {
    double *y = c->yb;
    for (size_t f = 0; f < n; f++) {
        if (c->pre_cur != c->pre_tgt) {
            c->pre_cur += (c->pre_tgt - c->pre_cur) * c->pre_k;
            if (fabs(c->pre_tgt - c->pre_cur) < 1e-12) c->pre_cur = c->pre_tgt;
        }
        int32_t il = src[2 * f], ir = src[2 * f + 1];
        double xl = il * (1.0 / 32768.0) * c->pre_cur, xr = ir * (1.0 / 32768.0) * c->pre_cur;
        y[2 * f] = (xl + xr) * 0.5;
        y[2 * f + 1] = (xl - xr) * 0.5;
    }
    size_t rn = c->ramp_left <= 0 ? 0 : (size_t)c->ramp_left < n ? (size_t)c->ramp_left : n;
    int ends = rn > 0 && (size_t)c->ramp_left <= n;
    for (int k = 0; k < nb; k++) {
        band_t *b = act[k];
        coefs_t p = b->cur, q = b->cur1;
        double m1 = b->z1[0], m2 = b->z2[0], s1 = b->z1[1], s2 = b->z2[1];
        for (size_t f = 0; f < n; f++) {
            double xm = y[2 * f], xs = y[2 * f + 1];
            double ym = p.b0 * xm + m1;
            m1 = p.b1 * xm - p.a1 * ym + m2;
            m2 = p.b2 * xm - p.a2 * ym;
            double ys = q.b0 * xs + s1;
            s1 = q.b1 * xs - q.a1 * ys + s2;
            s2 = q.b2 * xs - q.a2 * ys;
            y[2 * f] = ym;
            y[2 * f + 1] = ys;
            if (f < rn) {
                p.b0 += b->inc.b0; p.b1 += b->inc.b1; p.b2 += b->inc.b2; p.a1 += b->inc.a1; p.a2 += b->inc.a2;
                q.b0 += b->inc1.b0; q.b1 += b->inc1.b1; q.b2 += b->inc1.b2; q.a1 += b->inc1.a1; q.a2 += b->inc1.a2;
                if (f + 1 == rn && ends) {
                    p = b->tgt;
                    q = b->tgt1;
                }
            }
        }
        b->cur = p;
        b->cur1 = q;
        b->z1[0] = m1;
        b->z2[0] = m2;
        b->z1[1] = s1;
        b->z2[1] = s2;
    }
    if (rn > 0) {
        c->ramp_left -= (int)rn;
        if (c->ramp_left == 0)
            for (int j = 0; j < EQE_NFILT; j++) {
                c->band[j].cur = c->band[j].tgt;
                c->band[j].cur1 = c->band[j].tgt1;
            }
    }
    for (size_t f = 0; f < n; f++) {
        if (c->wd_left > 0) {
            c->wd_cur += c->wd_inc;
            if (--c->wd_left == 0) c->wd_cur = c->wd_tgt;
        }
        double m = y[2 * f], s = y[2 * f + 1] * c->wd_cur;
        y[2 * f] = m + s;
        y[2 * f + 1] = m - s;
    }
}

/* One buffer. The per-sample work is only what the settings need (0.6.6):
 * - "transparent" (EQ on but flat, preamp 0 dB, no seat delay, the guard idle): the input goes
 *   through the look-ahead delay as in the bit-exact path, which gives exactly the same samples
 *   as the full path would;
 * - only bands that are not at 0 dB are run, a chunk at a time (bands_block, 0.7.4) whenever the
 *   whole chunk takes the processing path with the EQ on;
 * - the guard's bookkeeping is skipped while it is idle and the sample needs no limiting;
 * - a channel without seat delay skips the delay line's reads.
 * sp: the live view's buffer while the app shows it, else NULL. */
static void process_frames(eqe_ctx *c, const int16_t *src, int16_t *dst, size_t frames, int accumulate, spec_t *sp) {
    int32_t ipl = c->in_peak_l, ipr = c->in_peak_r, bpk = 0;
    uint64_t iss = 0, oss = 0;
    uint32_t clip = 0;
    band_t *act[EQE_NFILT];
    int nb = 0;
    ms_update(c);
    for (int j = 0; j < EQE_NFILT; j++)
        if (c->band[j].active) act[nb++] = &c->band[j];
    int transparent = c->processing && nb == 0 && !c->ms && c->ramp_left == 0 && c->pre_cur == 1.0 && c->pre_tgt == 1.0 &&
                      c->w == 1.0 && c->w_tgt == 1.0 && c->dcur[0] == 0 && c->dcur[1] == 0 && c->dfade[0] == 0 &&
                      c->dfade[1] == 0 && c->gq_n == 0 && c->box_low == 0 && c->g2 == 1.0;
    size_t cbase = 0, cend = 0;
    int blk = 0;
    for (size_t f = 0; f < frames; f++) {
        if (f == cend) {
            /* the next chunk: its preamp and bands at once when it stays on the processing path */
            size_t n = frames - f < EQE_CHUNK ? frames - f : EQE_CHUNK;
            cbase = f;
            cend = f + n;
            blk = (nb > 0 || c->ms) && c->processing && !transparent && c->w_tgt > 0.0;
            if (blk) {
                if (c->ms) bands_block_ms(c, src + 2 * f, n, act, nb);
                else bands_block(c, src + 2 * f, n, act, nb);
            }
        }
        int32_t il = src[2 * f], ir = src[2 * f + 1];
        int32_t al = il < 0 ? -il : il, ar = ir < 0 ? -ir : ir;
        if (al > ipl) ipl = al;
        if (ar > ipr) ipr = ar;
        iss += (uint64_t)(il * il) + (uint64_t)(ir * ir);
        if (al >= 32767 || ar >= 32767 || c->rail_sign[0] || c->rail_sign[1])
            clip += rail_count(c, 0, il) + rail_count(c, 1, ir);
        double xl = il * (1.0 / 32768.0), xr = ir * (1.0 / 32768.0);
        int32_t ol, orr;

        if (!c->processing || transparent) {
            /* Bit-exact path: the input, delayed by LA - 1 samples. */
            int w = c->li, rd = (w + 1) & (LA - 1);
            double dl = c->dl[0][rd], dr = c->dl[1][rd];
            c->dl[0][w] = xl;
            c->dl[1][w] = xr;
            c->li = rd;
            /* 0x325: right after the processing path hands back (EQ turned off, a microphone opened on
               CarPlay), the look-ahead still holds up to LA - 1 of its samples, which can be over full
               scale when the clip guard is off: clamped here instead of wrapping to the opposite
               sign (a crack). The path's own samples are always in range, so it stays bit-exact. */
            double tl = dl * 32768.0, tr = dr * 32768.0;
            ol = tl >= 32767.0 ? 32767 : tl <= -32768.0 ? -32768 : (int32_t)tl;
            orr = tr >= 32767.0 ? 32767 : tr <= -32768.0 ? -32768 : (int32_t)tr;
            if (transparent) {
                /* the seat delay keeps its history, for a later change */
                c->dbuf[0][c->dpos] = xl;
                c->dbuf[1][c->dpos] = xr;
                c->dpos = (c->dpos + 1) & (DMAX - 1);
            } else if (c->w_tgt > 0.0) {
                /* EQ turned on: start the processing path; the crossfade begins at w = 0. */
                c->processing = 1;
            }
        } else {
            double yl, yr;
            if (blk) {
                /* preamp and filters done for the whole chunk (bands_block) */
                yl = c->yb[2 * (f - cbase)];
                yr = c->yb[2 * (f - cbase) + 1];
            } else {
                /* preamp */
                if (c->pre_cur != c->pre_tgt) {
                    c->pre_cur += (c->pre_tgt - c->pre_cur) * c->pre_k;
                    if (fabs(c->pre_tgt - c->pre_cur) < 1e-12) c->pre_cur = c->pre_tgt;
                }
                yl = xl * c->pre_cur;
                yr = xr * c->pre_cur;
                if (c->ms) {
                    /* 0x326: mid and side, each lane with its own coefficients, the width, back */
                    double m = (yl + yr) * 0.5, s = (yl - yr) * 0.5;
                    for (int n = 0; n < nb; n++) {
                        band_t *b = act[n];
                        double ym = b->cur.b0 * m + b->z1[0];
                        b->z1[0] = b->cur.b1 * m - b->cur.a1 * ym + b->z2[0];
                        b->z2[0] = b->cur.b2 * m - b->cur.a2 * ym;
                        double ys = b->cur1.b0 * s + b->z1[1];
                        b->z1[1] = b->cur1.b1 * s - b->cur1.a1 * ys + b->z2[1];
                        b->z2[1] = b->cur1.b2 * s - b->cur1.a2 * ys;
                        m = ym;
                        s = ys;
                    }
                    if (c->ramp_left > 0) {
                        for (int n = 0; n < nb; n++) {
                            band_t *b = act[n];
                            b->cur.b0 += b->inc.b0; b->cur.b1 += b->inc.b1; b->cur.b2 += b->inc.b2;
                            b->cur.a1 += b->inc.a1; b->cur.a2 += b->inc.a2;
                            b->cur1.b0 += b->inc1.b0; b->cur1.b1 += b->inc1.b1; b->cur1.b2 += b->inc1.b2;
                            b->cur1.a1 += b->inc1.a1; b->cur1.a2 += b->inc1.a2;
                        }
                        if (--c->ramp_left == 0)
                            for (int j = 0; j < EQE_NFILT; j++) {
                                c->band[j].cur = c->band[j].tgt;
                                c->band[j].cur1 = c->band[j].tgt1;
                            }
                    }
                    if (c->wd_left > 0) {
                        c->wd_cur += c->wd_inc;
                        if (--c->wd_left == 0) c->wd_cur = c->wd_tgt;
                    }
                    s *= c->wd_cur;
                    yl = m + s;
                    yr = m - s;
                } else {
                /* filters */
                for (int n = 0; n < nb; n++) {
                    band_t *b = act[n];
                    yl = biquad(b, 0, yl);
                    yr = biquad(b, 1, yr);
                }
                if (c->ramp_left > 0) {
                    for (int n = 0; n < nb; n++) {
                        band_t *b = act[n];
                        b->cur.b0 += b->inc.b0;
                        b->cur.b1 += b->inc.b1;
                        b->cur.b2 += b->inc.b2;
                        b->cur.a1 += b->inc.a1;
                        b->cur.a2 += b->inc.a2;
                    }
                    if (--c->ramp_left == 0)
                        for (int j = 0; j < EQE_NBAND; j++) c->band[j].cur = c->band[j].tgt;
                }
                }
            }
            /* listening position: per-channel delay, crossfading between taps when it changes */
            {
                int wp = c->dpos;
                c->dbuf[0][wp] = yl;
                c->dbuf[1][wp] = yr;
                for (int ch = 0; ch < 2; ch++) {
                    if (c->dcur[ch] == 0 && c->dfade[ch] == 0) continue; /* tap 0 is the sample itself */
                    double a = c->dbuf[ch][(unsigned)(wp - c->dcur[ch]) & (DMAX - 1)];
                    if (c->dfade[ch] > 0) {
                        double b = c->dbuf[ch][(unsigned)(wp - c->dnew[ch]) & (DMAX - 1)];
                        double t = 1.0 - (double)c->dfade[ch] / DFADE_LEN;
                        a += (b - a) * t;
                        if (--c->dfade[ch] == 0) c->dcur[ch] = c->dnew[ch];
                    }
                    if (ch == 0) yl = a;
                    else yr = a;
                }
                c->dpos = (wp + 1) & (DMAX - 1);
            }
            /* EQ on/off crossfade (the dry signal has no preamp) */
            if (c->w != c->w_tgt) {
                if (c->w < c->w_tgt) { c->w += c->w_step; if (c->w > c->w_tgt) c->w = c->w_tgt; }
                else { c->w -= c->w_step; if (c->w < c->w_tgt) c->w = c->w_tgt; }
            }
            double ml = xl + (yl - xl) * c->w, mr = xr + (yr - xr) * c->w;
            /* clip guard (look-ahead peak limiter) */
            int w = c->li, rd = (w + 1) & (LA - 1);
            double dl = c->dl[0][rd], dr = c->dl[1][rd];
            c->dl[0][w] = ml;
            c->dl[1][w] = mr;
            c->li = rd;
            double pk = fabs(ml) > fabs(mr) ? fabs(ml) : fabs(mr);
            int over = c->set.guard_on && pk > GUARD_THR;
            double gl;
            if (!over && c->gq_n == 0 && c->box_low == 0 && c->g2 == 1.0) {
                /* idle: nothing to limit now or anywhere in the look-ahead */
                gl = 1.0;
            } else {
                double m = guard_min_push(c, over ? GUARD_THR / pk : 1.0);
                if (c->box[w] < 1.0) c->box_low--;
                c->boxsum += m - c->box[w];
                c->box[w] = m;
                if (m < 1.0) c->box_low++;
                double g = c->boxsum * (1.0 / LA);
                if (g > 1.0) g = 1.0;
                if (g < c->g2) c->g2 = g;
                else c->g2 += (g - c->g2) * c->krel;
                if (c->g2 > 1.0 || (g == 1.0 && c->g2 > 1.0 - 1e-9)) c->g2 = 1.0;
                gl = c->g2;
                if (gl < 0.99999) c->limited++;
                if (gl < c->min_gain) c->min_gain = gl;
            }
            ol = quantise(c, dl * gl, c->set.guard_on);
            orr = quantise(c, dr * gl, c->set.guard_on);
            /* Back to the bit-exact path once fully off and settled. */
            if (c->w == 0.0 && c->w_tgt == 0.0 && c->gq_n == 0 && c->g2 >= 0.99999 &&
                c->boxsum >= LA - 1e-9) {
                c->processing = 0;
                c->g2 = 1.0;
                reset_states(c);
            }
        }
        if (accumulate) {
            ol += dst[2 * f];
            orr += dst[2 * f + 1];
            if (ol > 32767) ol = 32767; else if (ol < -32768) ol = -32768;
            if (orr > 32767) orr = 32767; else if (orr < -32768) orr = -32768;
        }
        int32_t aol = ol < 0 ? -ol : ol, aor = orr < 0 ? -orr : orr;
        if (aol > bpk) bpk = aol;
        if (aor > bpk) bpk = aor;
        oss += (uint64_t)(ol * ol) + (uint64_t)(orr * orr);
        dst[2 * f] = (int16_t)ol;
        dst[2 * f + 1] = (int16_t)orr;
        if (sp) {
            sp->ring[sp->pos] = (float)((ol + orr) * (0.5 / 32768.0));
            sp->pos = (sp->pos + 1) & (SPEC_N - 1);
        }
    }
    if (sp) {
        sp->fresh += (int)frames;
        sp->filled = sp->filled + (int)frames > SPEC_N ? SPEC_N : sp->filled + (int)frames;
    }
    c->in_peak_l = ipl;
    c->in_peak_r = ipr;
    if (bpk > c->out_peak) c->out_peak = bpk;
    c->blk_peak = bpk;
    c->blk_ss = oss;
    c->blk_frames = (uint32_t)frames;
    c->blk_seq++;
    c->in_ss += iss;
    c->out_ss += oss;
    c->ss_frames += frames;
    c->in_clip_sr += clip;
    c->in_clip_total += clip;
    /* keep the filter states out of the denormal range, and the running sum exact */
    for (int j = 0; j < EQE_NFILT; j++) {
        band_t *b = &c->band[j];
        for (int ch = 0; ch < 2; ch++) {
            if (fabs(b->z1[ch]) < 1e-25) b->z1[ch] = 0.0;
            if (fabs(b->z2[ch]) < 1e-25) b->z2[ch] = 0.0;
        }
        if (b->active && c->ramp_left == 0 && band_identity(c, b) &&
            b->z1[0] == 0.0 && b->z1[1] == 0.0 && b->z2[0] == 0.0 && b->z2[1] == 0.0)
            b->active = 0;
    }
    double s = 0.0;
    for (int i = 0; i < LA; i++) s += c->box[i];
    c->boxsum = s;
}

/* ------------------------------------------------------------------ live view */

static double eqe_spec_hz(int b) { return 20.0 * pow(1000.0, (double)b / (EQE_NSPEC - 1)); }

/* Allocates the live view and its fixed tables (from a command, never from process()). */
static spec_t *spec_new(void) {
    spec_t *sp = (spec_t *)calloc(1, sizeof(spec_t));
    if (sp == NULL) return NULL;
    double s2 = 0.0;
    for (int n = 0; n < SPEC_N; n++) {
        double w = 0.5 - 0.5 * cos(2.0 * EQE_PI * n / SPEC_N); /* periodic Hann */
        sp->win[n] = (float)w;
        s2 += (double)sp->win[n] * sp->win[n];
    }
    sp->winsum2 = s2;
    for (int k = 0; k < SPEC_M; k++) {
        sp->twr[k] = cos(2.0 * EQE_PI * k / SPEC_N);
        sp->twi[k] = -sin(2.0 * EQE_PI * k / SPEC_N);
    }
    int bits = 0;
    while ((1 << bits) < SPEC_M) bits++;
    for (int m = 0; m < SPEC_M; m++) {
        int r = 0;
        for (int b = 0; b < bits; b++)
            if (m & (1 << b)) r |= 1 << (bits - 1 - b);
        sp->rev[m] = (int16_t)r;
    }
    return sp;
}

/* Which FFT bins make up each band at this rate. Bands narrower than a bin take their share of
 * the nearest bin, so every band reads a power, not a density. */
static void spec_bands(spec_t *sp, double rate) {
    double half = sqrt(pow(1000.0, 1.0 / (EQE_NSPEC - 1)));
    double binhz = rate / SPEC_N;
    for (int b = 0; b < EQE_NSPEC; b++) {
        double f = eqe_spec_hz(b), flo = f / half, fhi = f * half;
        sp->scale[b] = 1.0;
        if (f >= 0.5 * rate) {
            sp->lo[b] = 1;
            sp->hi[b] = 0;
            sp->scale[b] = 0.0;
            continue;
        }
        if (fhi > 0.5 * rate) fhi = 0.5 * rate;
        int lo = (int)ceil(flo / binhz), hi = (int)floor(fhi / binhz);
        if (lo < 1) lo = 1;
        if (hi > SPEC_M - 1) hi = SPEC_M - 1;
        if (lo > hi) {
            int k = (int)floor(f / binhz + 0.5);
            if (k < 1) k = 1;
            if (k > SPEC_M - 1) k = SPEC_M - 1;
            lo = hi = k;
            sp->scale[b] = (fhi - flo) / binhz;
        }
        sp->lo[b] = lo;
        sp->hi[b] = hi;
    }
    sp->rate = rate;
}

/* One analysis of the newest SPEC_N output samples: a Hann window, the real FFT done as a
 * SPEC_M-point complex FFT, band powers in 0.01 dBFS (a full-scale sine reads -3.01 dB, as the
 * level meter does). */
static void spec_analyse(spec_t *sp, double rate, int64_t now) {
    if (sp->rate != rate) spec_bands(sp, rate);
    for (int m = 0; m < SPEC_M; m++) {
        int i0 = (sp->pos + 2 * m) & (SPEC_N - 1), i1 = (i0 + 1) & (SPEC_N - 1);
        int r = sp->rev[m];
        sp->re[r] = (double)sp->ring[i0] * sp->win[2 * m];
        sp->im[r] = (double)sp->ring[i1] * sp->win[2 * m + 1];
    }
    for (int len = 2; len <= SPEC_M; len <<= 1) {
        int half = len >> 1, tstep = SPEC_N / len;
        for (int s = 0; s < SPEC_M; s += len) {
            for (int j = 0; j < half; j++) {
                double wr = sp->twr[j * tstep], wi = sp->twi[j * tstep];
                int a = s + j, b = a + half;
                double tr = sp->re[b] * wr - sp->im[b] * wi;
                double ti = sp->re[b] * wi + sp->im[b] * wr;
                sp->re[b] = sp->re[a] - tr;
                sp->im[b] = sp->im[a] - ti;
                sp->re[a] += tr;
                sp->im[a] += ti;
            }
        }
    }
    /* The real signal's bin k: X[k] = E[k] + W^k O[k], with E = (Z[k] + conj Z[M-k]) / 2 and
       O = (Z[k] - conj Z[M-k]) / 2i. Only the bins the bands use are computed. Power: one-sided
       Parseval with the window's energy, so a band holding a whole sine reads its mean square. */
    double norm = 2.0 / ((double)SPEC_N * sp->winsum2);
    for (int b = 0; b < EQE_NSPEC; b++) {
        if (sp->scale[b] == 0.0) {
            sp->lvl[b] = EQE_RESP_NONE;
            continue;
        }
        double sum = 0.0;
        for (int k = sp->lo[b]; k <= sp->hi[b]; k++) {
            double zr = sp->re[k], zi = sp->im[k];
            double cr = sp->re[SPEC_M - k], ci = -sp->im[SPEC_M - k];
            double er = 0.5 * (zr + cr), ei = 0.5 * (zi + ci);
            double orr = 0.5 * (zi - ci), oi = -0.5 * (zr - cr);
            double wr = sp->twr[k], wi = sp->twi[k];
            double xr = er + wr * orr - wi * oi, xi = ei + wr * oi + wi * orr;
            sum += xr * xr + xi * xi;
        }
        double ms = sum * sp->scale[b] * norm;
        sp->lvl[b] = ms > 1e-12 ? (int32_t)lrint(1000.0 * log10(ms)) : -12000;
    }
    sp->seq++;
    sp->at_ns = now;
    sp->fresh = 0;
}

/* EQE_PARAM_SPECTRUM: [0] analyses so far, [1] age of the newest in ms (-1: none yet), [2]
 * EQE_NSPEC, [3] sample rate, [4..] band levels in 0.01 dBFS at eqe_spec_hz() (EQE_RESP_NONE:
 * nothing yet, or above Nyquist). Each read keeps the analysis running for SPEC_KEEP_NS. */
static void spec_read(eqe_ctx *c, int32_t *v) {
    int64_t now = now_ns();
    c->spec_wanted_ns = now;
    if (c->spec == NULL) c->spec = spec_new();
    spec_t *sp = c->spec;
    int have = sp != NULL && sp->seq > 0;
    v[0] = sp ? (int32_t)sp->seq : 0;
    v[1] = have ? (int32_t)((now - sp->at_ns) / 1000000LL) : -1;
    v[2] = EQE_NSPEC;
    v[3] = (int32_t)c->rate;
    for (int b = 0; b < EQE_NSPEC; b++) v[4 + b] = have ? sp->lvl[b] : EQE_RESP_NONE;
}

/* EQE_PARAM_LEVEL: the last buffer's output: [0] buffers so far, [1] ms since it was processed
 * (-1: none yet), [2] peak 0..32768, [3] average (RMS) in 0.01 dBFS, [4] frames, [5] rate. */
static int32_t rms_cdb(uint64_t ss, uint64_t frames);
static void level_read(eqe_ctx *c, int32_t *v) {
    v[0] = (int32_t)c->blk_seq;
    v[1] = c->blk_ns ? (int32_t)((now_ns() - c->blk_ns) / 1000000LL) : -1;
    v[2] = c->blk_peak;
    v[3] = rms_cdb(c->blk_ss, c->blk_frames);
    v[4] = (int32_t)c->blk_frames;
    v[5] = (int32_t)c->rate;
}

/* Bytes per frame of a PCM layout, 0 when the format is not one Android 4.4 has. */
static size_t frame_bytes(uint32_t format, uint32_t channels) {
    size_t b;
    switch (format) {
    case AUDIO_FORMAT_PCM_16_BIT: b = 2; break;
    case AUDIO_FORMAT_PCM_8_BIT: b = 1; break;
    case AUDIO_FORMAT_PCM_32_BIT:
    case AUDIO_FORMAT_PCM_8_24_BIT: b = 4; break;
    default: return 0;
    }
    return b * (size_t)__builtin_popcount(channels);
}

/* The output's layout is the input's: the same, or left unset (0) by the caller. */
static int out_layout_same(const effect_config_t *k) {
    uint32_t of = k->outputCfg.format, oc = k->outputCfg.channels;
    return (of == 0 || of == k->inputCfg.format) && (oc == 0 || oc == k->inputCfg.channels);
}

static int32_t eqe_process(effect_handle_t self, audio_buffer_t *in, audio_buffer_t *out) {
    eqe_ctx *c = ctx_of(self);
    if (c == NULL) return -EINVAL;
    if (in == NULL || out == NULL || in->raw == NULL || out->raw == NULL) {
        c->bad_buffers++;
        return -EINVAL;
    }
    if (!c->enabled) return -ENODATA;

    size_t frames = in->frameCount < out->frameCount ? in->frameCount : out->frameCount;
    if (frames > EQE_MAX_FRAMES) frames = EQE_MAX_FRAMES;
    int64_t t0 = now_ns();
    /* Audio resumed after the output went idle: start clean, so nothing from before the pause
     * (the look-ahead delay, filter memory) comes out first. */
    int gap = c->last_call_ns != 0 && t0 - c->last_call_ns > 500000000LL;
    if (gap) {
        reset_states(c);
        reset_guard(c);
    }
    /* the live view runs while the app reads it; it starts again from empty after a pause */
    spec_t *sp = c->spec != NULL && t0 - c->spec_wanted_ns < SPEC_KEEP_NS ? c->spec : NULL;
    if (sp != NULL && (gap || !c->spec_running)) {
        sp->filled = 0;
        sp->fresh = 0;
    }
    c->spec_running = sp != NULL;

    int supported = c->cfg_ok && c->rate > 0.0;
    int accumulate = in->raw != out->raw && c->config.outputCfg.accessMode == EFFECT_BUFFER_ACCESS_ACCUMULATE;
    if (!supported) {
        /* Not the 16-bit stereo the 4.4 mixer uses (SET_CONFIG refused it): leave the audio
         * alone. With separate buffers the input is handed on as it is, sized by the layout
         * Android gave (never assumed to be stereo 16-bit), and only when the input and output
         * layouts are the same; anything else leaves the output untouched. */
        c->unsupported++;
        if (in->raw != out->raw) {
            size_t frames_all = in->frameCount < out->frameCount ? in->frameCount : out->frameCount;
            size_t fb = frame_bytes(c->config.inputCfg.format, c->config.inputCfg.channels);
            if (out_layout_same(&c->config) && fb > 0 && frames_all > 0) {
                if (!accumulate) {
                    memmove(out->raw, in->raw, frames_all * fb);
                } else if (c->config.inputCfg.format == AUDIO_FORMAT_PCM_16_BIT) {
                    size_t n = frames_all * (fb / sizeof(int16_t));
                    for (size_t i = 0; i < n; i++) {
                        int32_t v = out->s16[i] + in->s16[i];
                        out->s16[i] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
                    }
                }
            }
        }
    } else if (frames > 0) {
        process_frames(c, in->s16, out->s16, frames, accumulate, sp);
        if (sp != NULL && sp->filled >= SPEC_N && sp->fresh >= SPEC_M) spec_analyse(sp, c->rate, t0);
    }

    int64_t t1 = now_ns();
    c->blk_ns = t1;
    int64_t dt = t1 - t0;
    if (dt < 0) dt = 0;
    if (dt > 0x7fffffff) dt = 0x7fffffff;
    c->calls++;
    c->frames += frames;
    c->calls_sr++;
    c->ns_sr += dt;
    if ((int32_t)dt > c->max_ns) c->max_ns = (int32_t)dt;
    c->last_call_ns = t1;
    if (!c->logged_first) {
        c->logged_first = 1;
        LOGI("first buffer: %u frames, %u Hz, channels 0x%x, format %u, in-place %d, access %u",
             (unsigned)frames, c->config.inputCfg.samplingRate, c->config.inputCfg.channels,
             c->config.inputCfg.format, in->raw == out->raw, c->config.outputCfg.accessMode);
    }
    return 0;
}

/* ------------------------------------------------------------------ parameters and commands */

static int32_t rms_cdb(uint64_t ss, uint64_t frames) {
    if (frames == 0 || ss == 0) return -10000;
    double ms = (double)ss / (2.0 * (double)frames) / (32768.0 * 32768.0);
    double db = 10.0 * log10(ms);
    if (db < -99.99) return -10000;
    return (int32_t)lrint(db * 100.0);
}

static void eqe_get_stats(eqe_ctx *c, int32_t *s) {
    int64_t now = now_ns();
    memset(s, 0, EQE_STATS_COUNT * sizeof(int32_t));
    if (c->calls_sr > 0) c->avg_ns = (int32_t)(c->ns_sr / c->calls_sr);
    s[0] = 3; /* layout version */
    s[1] = (int32_t)c->config.inputCfg.samplingRate;
    s[2] = (int32_t)c->config.inputCfg.channels;
    s[3] = (int32_t)c->config.inputCfg.format;
    s[4] = (int32_t)c->config.inputCfg.buffer.frameCount;
    s[5] = (int32_t)c->config.outputCfg.accessMode;
    s[6] = (int32_t)c->calls;
    s[7] = (int32_t)(uint32_t)(c->frames & 0xffffffffu);
    s[8] = (int32_t)(uint32_t)(c->frames >> 32);
    s[9] = c->avg_ns;
    s[10] = c->max_ns;
    s[11] = c->in_peak_l;
    s[12] = c->in_peak_r;
    if (c->last_call_ns == 0) {
        s[13] = -1;
    } else {
        int64_t age = (now - c->last_call_ns) / 1000000LL;
        s[13] = age > 0x7fffffff ? 0x7fffffff : (int32_t)age;
    }
    s[14] = c->enabled;
    s[15] = c->set.eq_on;
    s[16] = c->out_peak;
    s[17] = (int32_t)(c->min_gain * 10000.0 + 0.5);
    s[18] = (int32_t)(c->limited & 0x7fffffffu);
    s[19] = EQE_LIB_VERSION;
    s[20] = (int32_t)c->unsupported;
    s[21] = (int32_t)c->configs;
    s[22] = (int32_t)(c->clipped & 0x7fffffffu);
    s[23] = c->processing;
    /* average (RMS) levels in 0.01 dBFS, both channels together; a full-scale sine reads -3.01 dB.
       -10000 = silent or no audio since the last read */
    s[24] = rms_cdb(c->in_ss, c->ss_frames);
    s[25] = rms_cdb(c->out_ss, c->ss_frames);
    s[26] = (int32_t)(c->in_clip_sr > 0x7fffffffu ? 0x7fffffffu : c->in_clip_sr);
    s[27] = (int32_t)(c->in_clip_total & 0x7fffffffu);
    /* "since the last read" values */
    c->calls_sr = 0;
    c->ns_sr = 0;
    c->max_ns = 0;
    c->in_peak_l = c->in_peak_r = c->out_peak = 0;
    c->min_gain = 1.0;
    c->in_ss = c->out_ss = c->ss_frames = 0;
    c->in_clip_sr = 0;
}

static int reply_int_ok(uint32_t *replySize, void *pReply) {
    return pReply != NULL && replySize != NULL && *replySize >= sizeof(int32_t);
}

static int32_t reply_int(uint32_t *replySize, void *pReply, int32_t v) {
    *(int32_t *)pReply = v;
    *replySize = sizeof(int32_t);
    return 0;
}

static void log_settings(eqe_ctx *c, const char *what) {
    const eqe_settings *s = &c->set;
    if (s->mode == 1) {
        /* Expert: the band count and each band as type@Hz/0.01 dB/width, on one line */
        char b[EQE_NX * 34 + 1];
        int o = 0;
        b[0] = 0;
        for (int j = 0; j < s->nx && o < (int)sizeof(b) - 34; j++) {
            static const char *kT[] = {"?", "peak", "lshelf", "hshelf", "lowcut"};
            static const char *kC[] = {"", "(mid)", "(side)"};
            int t = EQE_X_TYPE(s->x[j][0]), ch = EQE_X_CH(s->x[j][0]);
            o += snprintf(b + o, sizeof(b) - o, " %s%s@%d/%d/%d", kT[t >= 1 && t <= 4 ? t : 0], kC[ch <= 2 ? ch : 0],
                          s->x[j][1] / 100, s->x[j][2], s->x[j][3]);
        }
        LOGI("%s: eq %s, preamp %d, guard %d, Expert %d bands:%s, delay L %d R %d us, width %d%%, mono bass %d Hz", what,
             s->eq_on ? "on" : "off", s->preamp_cdb, s->guard_on, s->nx, b, s->delay_us[0], s->delay_us[1], s->width_pct,
             s->mono_hz);
        return;
    }
    LOGI("%s: eq %s, preamp %d, guard %d, bands %d %d %d %d %d %d %d %d %d %d (0.01 dB), ends %s/%s, delay L %d R %d us, "
         "width %d%%, mono bass %d Hz",
         what, s->eq_on ? "on" : "off", s->preamp_cdb, s->guard_on, s->band_cdb[0], s->band_cdb[1], s->band_cdb[2],
         s->band_cdb[3], s->band_cdb[4], s->band_cdb[5], s->band_cdb[6], s->band_cdb[7], s->band_cdb[8],
         s->band_cdb[9], (s->ends & EQE_ENDS_LOW) ? "shelf" : "peak", (s->ends & EQE_ENDS_HIGH) ? "shelf" : "peak",
         s->delay_us[0], s->delay_us[1], s->width_pct, s->mono_hz);
}

#ifndef EQE_CORE_ONLY
static int32_t eqe_command(effect_handle_t self, uint32_t cmd, uint32_t cmdSize, void *pCmd,
                           uint32_t *replySize, void *pReply) {
    eqe_ctx *c = ctx_of(self);
    if (c == NULL) return -EINVAL;

    switch (cmd) {
    case EFFECT_CMD_INIT:
        if (!reply_int_ok(replySize, pReply)) return -EINVAL;
        return reply_int(replySize, pReply, 0);

    case EFFECT_CMD_SET_CONFIG: {
        if (pCmd == NULL || cmdSize != sizeof(effect_config_t) || !reply_int_ok(replySize, pReply))
            return -EINVAL;
        memcpy(&c->config, pCmd, sizeof(effect_config_t));
        c->configs++;
        /* Only 16-bit stereo, in and out (what Android 4.4's mixer gives an effect). Anything
         * else is refused; process() then hands the audio on unchanged, sized by this layout. */
        c->cfg_ok = c->config.inputCfg.format == AUDIO_FORMAT_PCM_16_BIT &&
                    c->config.inputCfg.channels == AUDIO_CHANNEL_OUT_STEREO && out_layout_same(&c->config);
        if (!c->cfg_ok) {
            LOGI("config refused: in channels 0x%x format %u, out channels 0x%x format %u (only 16-bit stereo)",
                 c->config.inputCfg.channels, c->config.inputCfg.format, c->config.outputCfg.channels,
                 c->config.outputCfg.format);
            return reply_int(replySize, pReply, -EINVAL);
        }
        double rate = (double)c->config.inputCfg.samplingRate;
        if (rate < 8000.0 || rate > 192000.0) rate = 0.0;
        if (rate != c->rate) {
            c->rate = rate;
            if (rate > 0.0) prepare_rate(c);
            apply_settings(c, 1);
            reset_states(c);
            reset_guard(c);
        }
        LOGI("config: %u Hz, channels 0x%x, format %u, %u frames, out access %u",
             c->config.inputCfg.samplingRate, c->config.inputCfg.channels, c->config.inputCfg.format,
             (unsigned)c->config.inputCfg.buffer.frameCount, c->config.outputCfg.accessMode);
        return reply_int(replySize, pReply, 0);
    }

    case EFFECT_CMD_GET_CONFIG:
        if (pReply == NULL || replySize == NULL || *replySize < sizeof(effect_config_t)) return -EINVAL;
        memcpy(pReply, &c->config, sizeof(effect_config_t));
        *replySize = sizeof(effect_config_t);
        return 0;

    case EFFECT_CMD_RESET:
        reset_states(c);
        reset_guard(c);
        c->processing = c->w_tgt > 0.0;
        c->w = 0.0;
        if (reply_int_ok(replySize, pReply)) reply_int(replySize, pReply, 0);
        return 0;

    case EFFECT_CMD_ENABLE:
    case EFFECT_CMD_DISABLE:
        if (!reply_int_ok(replySize, pReply)) return -EINVAL;
        c->enabled = cmd == EFFECT_CMD_ENABLE;
        if (c->enabled) {
            /* fresh start: fade the EQ in from the untouched signal */
            c->logged_first = 0;
            reset_states(c);
            reset_guard(c);
            c->w = 0.0;
            c->pre_cur = c->pre_tgt;
            c->processing = c->w_tgt > 0.0;
        }
        LOGI("%s (session %d, io %d)", c->enabled ? "enabled" : "disabled", c->session, c->io);
        return reply_int(replySize, pReply, 0);

    case EFFECT_CMD_SET_PARAM: {
        if (pCmd == NULL || cmdSize < sizeof(effect_param_t) + sizeof(int32_t) || !reply_int_ok(replySize, pReply))
            return -EINVAL;
        effect_param_t *p = (effect_param_t *)pCmd;
        if (p->psize != sizeof(int32_t) || cmdSize < sizeof(effect_param_t) + p->psize + p->vsize)
            return reply_int(replySize, pReply, -EINVAL);
        int32_t id;
        memcpy(&id, p->data, sizeof(id));
        if (id == EQE_PARAM_SETTINGS) {
            eqe_settings s;
            if (!settings_from(p->data + sizeof(int32_t), p->vsize, &s)) return reply_int(replySize, pReply, -EINVAL);
            int first = c->set.layout == 0;
            c->set = s;
            apply_settings(c, first);
            /* slider drags send ~20 updates a second: log at most one every 2 s */
            int64_t t = now_ns();
            if (first || t - c->last_set_log > 2000000000LL) {
                log_settings(c, first ? "settings" : "settings changed");
                c->last_set_log = t;
            }
            return reply_int(replySize, pReply, 0);
        }
        if (id == EQE_PARAM_PEAK) {
            /* a question about settings (the app's Auto preamp and presets): nothing is applied */
            eqe_settings s;
            c->peak_q_ok = 0;
            if (!settings_from(p->data + sizeof(int32_t), p->vsize, &s) || peak_query(c, &s, c->peak_q) != 0)
                return reply_int(replySize, pReply, -EINVAL);
            c->peak_q_ok = 1;
            return reply_int(replySize, pReply, 0);
        }
        return reply_int(replySize, pReply, -EINVAL);
    }

    case EFFECT_CMD_GET_PARAM: {
        if (pCmd == NULL || cmdSize < sizeof(effect_param_t) + sizeof(int32_t) || pReply == NULL ||
            replySize == NULL || *replySize < sizeof(effect_param_t) + sizeof(int32_t))
            return -EINVAL;
        effect_param_t *q = (effect_param_t *)pCmd;
        if (q->psize != sizeof(int32_t)) return -EINVAL;
        uint32_t room = *replySize - (uint32_t)(sizeof(effect_param_t) + sizeof(int32_t));
        memcpy(pReply, pCmd, sizeof(effect_param_t) + sizeof(int32_t));
        effect_param_t *r = (effect_param_t *)pReply;
        char *value = r->data + sizeof(int32_t);
        int32_t id;
        memcpy(&id, q->data, sizeof(id));
        uint32_t vsize = 0;
        r->status = 0;
        if (id == EQE_PARAM_VERSION) {
            int32_t v = EQE_LIB_VERSION;
            if (room < sizeof(v)) r->status = -EINVAL;
            else { memcpy(value, &v, sizeof(v)); vsize = sizeof(v); }
        } else if (id == EQE_PARAM_STATS) {
            int32_t s[EQE_STATS_COUNT];
            if (room < sizeof(s)) r->status = -EINVAL;
            else { eqe_get_stats(c, s); memcpy(value, s, sizeof(s)); vsize = sizeof(s); }
        } else if (id == EQE_PARAM_SETTINGS) {
            if (room < sizeof(eqe_settings)) r->status = -EINVAL;
            else { memcpy(value, &c->set, sizeof(eqe_settings)); vsize = sizeof(eqe_settings); }
        } else if (id == EQE_PARAM_RESPONSE) {
            int32_t v[EQE_NRESP];
            if (room < sizeof(v)) {
                r->status = -EINVAL;
            } else {
                for (int k = 0; k < EQE_NRESP; k++) {
                    double f = eqe_resp_hz(k);
                    if (c->rate <= 0.0 || f >= 0.5 * c->rate) { v[k] = EQE_RESP_NONE; continue; }
                    double d = 0.0;
                    for (int j = 0; j < EQE_NBAND; j++) d += coefs_db(&c->band[j].tgt, f, c->rate);
                    v[k] = (int32_t)floor(d * 100.0 + 0.5);
                }
                memcpy(value, v, sizeof(v));
                vsize = sizeof(v);
            }
        } else if (id == EQE_PARAM_VHQ) {
            int32_t v[8];
            if (room < sizeof(v)) r->status = -EINVAL;
            else { vhq_status(v); memcpy(value, v, sizeof(v)); vsize = sizeof(v); }
        } else if (id == EQE_PARAM_SPECTRUM) {
            int32_t v[4 + EQE_NSPEC];
            if (room < sizeof(v)) r->status = -EINVAL;
            else { spec_read(c, v); memcpy(value, v, sizeof(v)); vsize = sizeof(v); }
        } else if (id == EQE_PARAM_LEVEL) {
            int32_t v[6];
            if (room < sizeof(v)) r->status = -EINVAL;
            else { level_read(c, v); memcpy(value, v, sizeof(v)); vsize = sizeof(v); }
        } else if (id == EQE_PARAM_PEAK) {
            /* the answer to the last question asked with SET_PARAM EQE_PARAM_PEAK */
            if (room < sizeof(c->peak_q) || !c->peak_q_ok) r->status = -EINVAL;
            else { memcpy(value, c->peak_q, sizeof(c->peak_q)); vsize = sizeof(c->peak_q); }
        } else if (id == EQE_PARAM_GAINS) {
            int32_t v[EQE_NB];
            if (room < sizeof(v)) r->status = -EINVAL;
            else {
                for (int j = 0; j < EQE_NB; j++) v[j] = (int32_t)floor(c->gains[j] * 100.0 + 0.5);
                memcpy(value, v, sizeof(v));
                vsize = sizeof(v);
            }
        } else {
            r->status = -EINVAL;
        }
        r->vsize = vsize;
        *replySize = (uint32_t)(sizeof(effect_param_t) + sizeof(int32_t)) + vsize;
        return 0;
    }

    case EFFECT_CMD_SET_DEVICE:
    case EFFECT_CMD_SET_VOLUME:
    case EFFECT_CMD_SET_AUDIO_MODE:
    case EFFECT_CMD_SET_INPUT_DEVICE:
    case EFFECT_CMD_SET_AUDIO_SOURCE:
        return 0;

    case EFFECT_CMD_OFFLOAD:
        if (reply_int_ok(replySize, pReply)) return reply_int(replySize, pReply, 0);
        return 0;

    default:
        return -EINVAL;
    }
}

static int32_t eqe_get_descriptor(effect_handle_t self, effect_descriptor_t *pDescriptor) {
    if (ctx_of(self) == NULL || pDescriptor == NULL) return -EINVAL;
    *pDescriptor = gDescriptor;
    return 0;
}

static const struct effect_interface_s gInterface = {
    eqe_process,
    eqe_command,
    eqe_get_descriptor,
    NULL,
};

/* ---- very high quality converter (Lab test)
 *
 * Android 4.4's converter looks for libaudio-resampler.so by name, once per audio server, when it
 * creates its first high-quality converter; without it, "very high" quality uses the "high" tables.
 * When the boot step has left VHQ_MARK (the Lab switch is on and the library passed its check),
 * this filter loads EQ Engine's copy into the audio server the first time the audio server calls
 * into this library (when Android first lists its effects). Android 4.4's dlopen() then finds the
 * already-loaded library by its file name. Nothing outside this process changes; without the
 * marker nothing is loaded. The library only hands Android two numbers and two tables. */
#ifndef VHQ_MARK
#define VHQ_MARK "/data/eqengine/state/vhq_load"
#endif
#ifndef VHQ_LIB
#define VHQ_LIB "/data/eqengine/lib/libaudio-resampler.so"
#endif
static pthread_once_t vhq_once = PTHREAD_ONCE_INIT;
static int vhq_state;                    /* 0 not asked for, 1 loaded, -1 load failed */
static void (*vhq_stats_fn)(int32_t *);

static void vhq_load(void) {
    if (access(VHQ_MARK, F_OK) != 0) return;
    void *h = dlopen(VHQ_LIB, RTLD_NOW);
    if (h == NULL) {
        const char *e = dlerror();
        vhq_state = -1;
        LOGW("very high quality converter: library not loaded (%s)", e ? e : "?");
        return;
    }
    vhq_stats_fn = (void (*)(int32_t *))dlsym(h, "eqe_vhq_stats");
    vhq_state = 1;
    LOGI("very high quality converter: EQ Engine's filter tables loaded for Android's converter");
}

static void vhq_status(int32_t *v) {
    int32_t st[6] = {0, 0, 0, 0, 0, 0};
    pthread_once(&vhq_once, vhq_load);
    if (vhq_stats_fn != NULL) vhq_stats_fn(st);
    v[0] = vhq_state;
    v[1] = st[0]; /* times Android set it up (1 once it is in use) */
    v[2] = st[1]; /* blocks converted down (48 -> 44.1 kHz) */
    v[3] = st[2]; /* blocks converted up (16, 22.05 kHz ... -> 44.1 kHz) */
    v[4] = st[3]; /* taps per side */
    v[5] = st[4]; /* phase bits */
    v[6] = st[5]; /* table version */
    v[7] = 0;
}

static int32_t lib_create(const effect_uuid_t *uuid, int32_t sessionId, int32_t ioId,
                          effect_handle_t *pHandle) {
    pthread_once(&vhq_once, vhq_load);
    if (uuid == NULL || pHandle == NULL) return -EINVAL;
    if (memcmp(uuid, &gDescriptor.uuid, sizeof(effect_uuid_t)) != 0) return -ENOENT;
    eqe_ctx *c = (eqe_ctx *)calloc(1, sizeof(eqe_ctx));
    if (c == NULL) return -ENOMEM;
    c->itfe = &gInterface;
    c->magic = EQE_MAGIC;
    c->session = sessionId;
    c->io = ioId;
    filters_init(c);
    c->pre_cur = c->pre_tgt = 1.0;
    c->w_step = 1.0 / XFADE_LEN;
    c->min_gain = 1.0;
    c->rng = 0x9e3779b9u ^ (uint32_t)(uintptr_t)c;
    if (c->rng == 0) c->rng = 1;
    reset_guard(c);
    *pHandle = (effect_handle_t)c;
    LOGI("created (session %d, io %d), filter version %x", sessionId, ioId, EQE_LIB_VERSION);
    return 0;
}

static int32_t lib_release(effect_handle_t handle) {
    eqe_ctx *c = ctx_of(handle);
    if (c == NULL) return -EINVAL;
    LOGI("released after %u buffers", c->calls);
    c->magic = 0;
    c->enabled = 0;
    free(c->spec);
    free(c);
    return 0;
}

static int32_t lib_get_descriptor(const effect_uuid_t *uuid, effect_descriptor_t *pDescriptor) {
    /* the audio server's first call into this library (Android's effect list is built) */
    pthread_once(&vhq_once, vhq_load);
    if (uuid == NULL || pDescriptor == NULL) return -EINVAL;
    if (memcmp(uuid, &gDescriptor.uuid, sizeof(effect_uuid_t)) != 0) return -EINVAL;
    *pDescriptor = gDescriptor;
    return 0;
}

__attribute__((visibility("default"))) audio_effect_library_t AELI = {
    AUDIO_EFFECT_LIBRARY_TAG,
    EFFECT_LIBRARY_API_VERSION,
    "EQ Engine",
    "EQ Engine",
    lib_create,
    lib_release,
    lib_get_descriptor,
};
#endif /* EQE_CORE_ONLY */
