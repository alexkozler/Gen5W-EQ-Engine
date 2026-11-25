/*
 * EQ on CarPlay's music (0.7.3): the two files between the EQ Engine app and the CarPlay watch,
 * which runs EQ Engine's filter (eqengine.c's core) inside the factory CarPlay app.
 *
 * All values are int32, little-endian (as the head unit is). The app's side is CarPlayEq.java.
 *
 * The app's control file, CPE_CTL (written by the app, read by the watch every CPE_TICK_MS):
 *   [0] CPE_MAGIC  [1] CPE_VERSION  [2] seq (changes with every write)
 *   [3] on: 1 = EQ on CarPlay's music, 0 = CarPlay plays untouched (Diagnostics' switch)
 *   [4] live_until: CLOCK_MONOTONIC ms (Android's uptimeMillis) until which the live view is wanted
 *   [5] 0
 *   [6 ..] the EQ settings, exactly what the app sends Android's filter (eqengine.c eqe_settings:
 *          layout 4, CPE_NSET values, for a watch from 0.7.8 on; layout 3, CPE_NSET3 values, which
 *          every watch takes; the app writes layout 4 only to a watch whose cpl_live.lib is 0x326 or later)
 *   Written to a temporary file and renamed, so the watch never reads half of one.
 *
 * The watch's live file, CPW_DIR "/live.bin" (CPL_BYTES long, written by the watch, read by the app
 * through a read-only mapping): a cpl_live. seq is odd while the watch writes it; the app reads it
 * again when seq was odd or changed meanwhile.
 */
#ifndef EQE_CPEQ_H
#define EQE_CPEQ_H
#include <stdint.h>

#define CPE_MAGIC 0x31455043u   /* "CPE1" */
#define CPE_VERSION 1
#define CPE_HDR 6               /* int32 values before the settings */
#define CPE_NSET 101            /* EQE_SET_COUNT (layout 4, 0.7.8) */
#define CPE_NSET3 99            /* layout 3 (0.7.3 .. 0.7.7) */

#define CPL_MAGIC 0x314c5043u   /* "CPL1" */
#define CPL_VERSION 1
#define CPL_BYTES 4096
#define CPL_NSPEC 48            /* EQE_NSPEC */

/* why a CarPlay stream is not processed (cpl_live.why) */
#define CPE_WHY_NONE 0          /* processed */
#define CPE_WHY_SWITCH 1        /* EQ on CarPlay is switched off in the app */
#define CPE_WHY_NOSET 2         /* no settings from the app yet (or not valid ones) */
#define CPE_WHY_OFF 3           /* EQ Engine is turned off */
#define CPE_WHY_FORMAT 4        /* not CarPlay's music stream (rate, format, link) */
#define CPE_WHY_MIC 5           /* a microphone stream is open (Siri or a call): dry until it closes */
#define CPE_WHY_STARTED 6       /* the stream opened while the EQ was off; it gets the EQ from the next open */

/* cpl_live.state */
#define CPL_IDLE 0              /* no CarPlay output stream open */
#define CPL_PASSING 1           /* one is open and plays untouched (why says why) */
#define CPL_PROCESSING 2        /* CarPlay's music goes through the EQ */

typedef struct {
    int32_t magic, version;
    uint32_t seq;               /* odd while being written */
    int32_t pid;                /* the CarPlay app's process */
    int32_t state, why;         /* CPL_*, CPE_WHY_* */
    int32_t rate;               /* the open stream's */
    int32_t frames;             /* the last buffer's frames */
    uint32_t blk_seq;           /* buffers processed so far */
    int32_t blk_ms;             /* CLOCK_MONOTONIC ms (low 32 bits) of the last buffer */
    int32_t blk_peak;           /* its output peak, 0 .. 32768 */
    int32_t blk_rms;            /* its output average (RMS), 0.01 dBFS (-10000 silent) */
    int32_t avg_ns, max_ns;     /* processing time per buffer over the last second */
    int32_t min_gain;           /* the clip guard's lowest gain over the last second, x 10000 */
    uint32_t limited, clipped, in_clip; /* since the CarPlay app started: samples limited, clipped,
                                           and arrived clipped (flat tops) */
    int32_t ctl_seq;            /* the control file's seq in use */
    int32_t lib;                /* the filter core's version (EQE_LIB_VERSION) */
    uint32_t spec_seq;          /* live view analyses so far (0: none) */
    int32_t spec_ms;            /* CLOCK_MONOTONIC ms (low 32 bits) of the newest */
    int32_t spec[CPL_NSPEC];    /* its band levels, 0.01 dBFS, as eqengine.c's spec_read */
    /* (after 0.7.6; a watch before that leaves them 0) for the settings in use, what Android's filter
       answers to EQE_PARAM_PEAK and EQE_PARAM_GAINS, so the app's Auto and Copy Easy EQ also work
       while only CarPlay's EQ can be reached (Android's filter not loaded in this start) */
    int32_t ans_seq;            /* the control file's seq they are for (follows ctl_seq); 0 = none */
    int32_t ans_peak[3];        /* the largest boost: 0.01 dB, Hz, the rate it is at (as EQE_PARAM_PEAK) */
    int32_t ans_rate;           /* the rate ans_gains are worked out for */
    int32_t ans_gains[10];      /* Easy settings: the solved filter gains, 0.01 dB (EQE_PARAM_GAINS); else 0 */
} cpl_live;

#endif
