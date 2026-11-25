/* A stand-in for Telechips' libCarPlayAudio.so (built as libCarPlayAudio.so for the CarPlay watch's PC
   tests, linked like the car's: BIND_NOW and RELRO, so its import table is read-only once loaded).
   cpa_play() plays like the factory CarPlay app (an output stream at 44.1 kHz, 1024-frame periods,
   an error, a failed open, an input stream, a stream opened past the watch) through its own imports
   of TinyALSA's functions, and checks that every call reaches TinyALSA unchanged and every result
   comes back unchanged. Returns the number of failed checks; run.sh then checks the watch's notes. */
#define _DEFAULT_SOURCE
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct pcm;
struct pcm_config {
    unsigned int channels, rate, period_size, period_count;
    int format;
    unsigned int start_threshold, stop_threshold, silence_threshold;
    int avail_min;
};
struct pcm *pcm_open(unsigned int card, unsigned int device, unsigned int flags, struct pcm_config *config);
extern void (*fake_close_hook)(void);
int pcm_close(struct pcm *pcm);
int pcm_write(struct pcm *pcm, const void *data, unsigned int count);
int pcm_read(struct pcm *pcm, void *data, unsigned int count);
int pcm_is_ready(struct pcm *pcm);
const char *pcm_get_error(struct pcm *pcm);
int fake_writes(void);
int fake_reads(void);
int fake_closes(void);
unsigned int fake_last_count(void);
const void *fake_last_data(void);
void fake_fail_next(int rc);
struct pcm *fake_open_direct(void);

static int fails;
#define CHECK(c, what)                   \
    do {                                 \
        if (!(c)) {                      \
            fails++;                     \
            printf("  FAIL %s\n", what); \
        } else {                         \
            printf("  ok   %s\n", what); \
        }                                \
    } while (0)

int cpa_play(double secs) {
    fails = 0;
    struct pcm_config c = {2, 44100, 1024, 4, 0, 4096, 4096, 0, 0};
    struct pcm_config keep = c;
    struct pcm *p = pcm_open(0, 2, 0, &c);
    CHECK(p != NULL && pcm_is_ready(p), "pcm_open reaches TinyALSA and its stream comes back");
    CHECK(memcmp(&c, &keep, sizeof(c)) == 0, "pcm_open leaves the app's settings as they were");

    /* a 1 kHz tone at half scale (-6.0 dBFS), different in every buffer */
    static short buf[2048];
    int n = (int)(secs * 44100 / 1024), bad = 0, w0 = fake_writes();
    for (int k = 0; k < n; k++) {
        for (int i = 0; i < 1024; i++) {
            short v = (short)lrint(16384.0 * sin(2 * M_PI * 1000.0 * (k * 1024 + i) / 44100.0));
            buf[2 * i] = v;
            buf[2 * i + 1] = (short)(v + k % 7);
        }
        int rc = pcm_write(p, buf, sizeof(buf));
        if (rc != 0 || fake_last_count() != sizeof(buf) || memcmp(fake_last_data(), buf, sizeof(buf)) != 0) bad++;
    }
    CHECK(bad == 0 && fake_writes() - w0 == n, "every write reaches TinyALSA once, with the same samples and size");

    fake_fail_next(-32);
    CHECK(pcm_write(p, buf, sizeof(buf)) == -32, "an error from TinyALSA comes back unchanged");

    struct pcm_config cb = c;
    struct pcm *b = pcm_open(9, 0, 0, &cb);
    CHECK(b != NULL && !pcm_is_ready(b) && strstr(pcm_get_error(b), "busy") != NULL,
          "a failed open comes back as TinyALSA gave it");
    pcm_close(b);

    struct pcm_config ci = {1, 16000, 320, 4, 0, 0, 0, 0, 0};
    struct pcm *in = pcm_open(0, 0, 0x10000000u, &ci);
    short ib[640];
    int r0 = fake_reads();
    CHECK(pcm_read(in, ib, sizeof(ib)) == 0 && pcm_read(in, ib, sizeof(ib)) == 0 && fake_reads() - r0 == 2 && ib[0] == -2000,
          "reads reach TinyALSA and the samples come back");
    pcm_close(in);

    struct pcm *d = fake_open_direct();
    CHECK(pcm_write(d, buf, 960 * 4) == 0, "a stream the watch never saw is handed on too");

    int c0 = fake_closes();
    CHECK(pcm_close(p) == 0 && fake_closes() - c0 == 1, "pcm_close reaches TinyALSA once");
    return fails;
}

/* ------------------------------------------------------------------ EQ on CarPlay's music (0.7.3)
   cpa_eq() writes the app's control file (cpeq.h) as the EQ Engine app does, plays CarPlay-like
   streams through the watch, and checks what reaches TinyALSA and what the live file says. Paths
   from the environment: CPE_TEST_CTL (the control file), CPE_TEST_OFF (EQ Engine turned off),
   CPE_TEST_LIVE (the watch's live file). */
#include <fcntl.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include "cpeq.h"
void fake_cap_reset(void);
const short *fake_cap(unsigned int *n);
const void *fake_last_ptr(void);

#define LA_DELAY 63
static int32_t eq_set[CPE_NSET];
static int eq_nset = CPE_NSET3; /* values written: layout 3 (an app before 0.7.8) or layout 4 */
static uint32_t eq_seq;
static short hin[44100 * 2 * 8];
static unsigned int hin_n;
static long tone_n;
static int app_changed, own_buffer, app_buffer;

static int32_t mono_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int32_t)((int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000);
}

/* layout 3: layout, eq_on, preamp, guard, 10 sliders, delay L R, ends, mode, nx, 20 x 4 */
static void set_easy(int eq_on, int slider_1k) {
    memset(eq_set, 0, sizeof(eq_set));
    eq_nset = CPE_NSET3;
    eq_set[0] = 3;
    eq_set[1] = eq_on;
    eq_set[3] = 1;
    eq_set[4 + 5] = slider_1k;
}

static void set_expert_peak(int f_cHz, int gain_cdb, int bw) {
    memset(eq_set, 0, sizeof(eq_set));
    eq_nset = CPE_NSET3;
    eq_set[0] = 3;
    eq_set[1] = 1;
    eq_set[3] = 1;
    eq_set[17] = 1;
    eq_set[18] = 1;
    eq_set[19] = 1;
    eq_set[20] = f_cHz;
    eq_set[21] = gain_cdb;
    eq_set[22] = bw;
}

/* 0.7.8, layout 4: the layout 3 values, then the stereo width (percent) and the mono bass (Hz) */
static void set_easy4(int width_pct, int mono_hz) {
    memset(eq_set, 0, sizeof(eq_set));
    eq_nset = CPE_NSET;
    eq_set[0] = 4;
    eq_set[1] = 1;
    eq_set[3] = 1;
    eq_set[99] = width_pct;
    eq_set[100] = mono_hz;
}

static void write_ctl(const char *path, int on, int live_for_ms) {
    int32_t b[CPE_HDR + CPE_NSET];
    size_t nb = (size_t)(CPE_HDR + eq_nset) * sizeof(int32_t);
    b[0] = (int32_t)CPE_MAGIC;
    b[1] = CPE_VERSION;
    b[2] = (int32_t)++eq_seq;
    b[3] = on;
    b[4] = live_for_ms > 0 ? mono_ms() + live_for_ms : mono_ms() - 1;
    b[5] = 0;
    memcpy(b + CPE_HDR, eq_set, (size_t)eq_nset * sizeof(int32_t));
    char tmp[600];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (f == NULL) return;
    fwrite(b, nb, 1, f);
    fclose(f);
    rename(tmp, path);
}

/* a stream's start: what reached TinyALSA and what was played are both counted from here */
static void seg_reset(void) {
    fake_cap_reset();
    hin_n = 0;
}

/* n writes of `frames` frames of a 1 kHz tone at -20 dBFS (the right channel a little different),
   each from a buffer the test keeps a copy of, to see that the watch never writes into it */
static void play(struct pcm *p, int n, unsigned int frames, unsigned int rate) {
    static short buf[4096 * 2], keep[4096 * 2];
    for (int k = 0; k < n; k++) {
        for (unsigned int i = 0; i < frames; i++) {
            short v = (short)lrint(3277.0 * sin(2 * M_PI * 1000.0 * (double)tone_n / rate));
            buf[2 * i] = v;
            buf[2 * i + 1] = (short)(v / 2);
            tone_n++;
        }
        memcpy(keep, buf, frames * 4);
        if (hin_n + frames * 2 <= sizeof(hin) / sizeof(hin[0])) {
            memcpy(hin + hin_n, buf, frames * 4);
            hin_n += frames * 2;
        }
        pcm_write(p, buf, frames * 4);
        if (memcmp(keep, buf, frames * 4) != 0) app_changed++;
        if (fake_last_ptr() == (const void *)buf) app_buffer++;
        else own_buffer++;
    }
}

/* one 1024-frame block that TinyALSA refuses once, then the same block again (a retry) */
static int play_retry(struct pcm *p) {
    static short buf[1024 * 2];
    for (unsigned int i = 0; i < 1024; i++) {
        short v = (short)lrint(3277.0 * sin(2 * M_PI * 1000.0 * (double)tone_n / 44100));
        buf[2 * i] = v;
        buf[2 * i + 1] = (short)(v / 2);
        tone_n++;
    }
    memcpy(hin + hin_n, buf, sizeof(buf));
    hin_n += 2048;
    fake_fail_next(-32);
    int r1 = pcm_write(p, buf, sizeof(buf));
    int r2 = pcm_write(p, buf, sizeof(buf));
    return r1 == -32 && r2 == 0;
}

/* every frame from `from` on came out exactly as played, `delay` frames later */
static int same_delayed(unsigned int from, int delay) {
    unsigned int n;
    const short *o = fake_cap(&n);
    if (n != hin_n || n == 0) return 0;
    for (unsigned int i = from * 2; i < n; i++) {
        long j = (long)i - 2L * delay;
        short want = j >= 0 ? hin[j] : 0;
        if (o[i] != want) return 0;
    }
    return 1;
}

/* the output's level over its last `frames` frames, against the input's, in dB (left channel) */
static double gain_db(unsigned int frames) {
    unsigned int n;
    const short *o = fake_cap(&n);
    if (n != hin_n || n / 2 < frames) return -99;
    double so = 0, si = 0;
    for (unsigned int f = n / 2 - frames; f < n / 2; f++) {
        so += (double)o[2 * f] * o[2 * f];
        si += (double)hin[2 * f] * hin[2 * f];
    }
    return si > 0 && so > 0 ? 10 * log10(so / si) : -99;
}

static int read_live(const char *path, cpl_live *L) {
    for (int t = 0; t < 50; t++) {
        int fd = open(path, O_RDONLY);
        if (fd < 0) return 0;
        ssize_t r = read(fd, L, sizeof(*L));
        close(fd);
        if (r == (ssize_t)sizeof(*L) && (L->seq & 1u) == 0) return L->magic == (int32_t)CPL_MAGIC;
        usleep(1000);
    }
    return 0;
}

/* the watch's status in this process: eq_applies= (0.7.6), -1 when it cannot be read */
static long read_applies(void) {
    const char *live = getenv("CPE_TEST_LIVE");
    const char *sl = live != NULL ? strrchr(live, '/') : NULL;
    if (sl == NULL) return -1;
    char path[512];
    snprintf(path, sizeof(path), "%.*s/status.%d", (int)(sl - live), live, (int)getpid());
    FILE *f = fopen(path, "r");
    if (f == NULL) return -1;
    char line[256];
    long v = -1;
    while (fgets(line, sizeof(line), f) != NULL)
        if (strncmp(line, "eq_applies=", 11) == 0) v = atol(line + 11);
    fclose(f);
    return v;
}

/* the other thread's open in test 12: after the watch has written the closing stream's notes */
static struct pcm *race_b;
static void race_open(void) {
    usleep(400000);
    struct pcm_config cb;
    memset(&cb, 0, sizeof(cb));
    cb.channels = 2;
    cb.rate = 24000;
    cb.period_size = 777;
    cb.period_count = 4;
    race_b = pcm_open(0, 0, 0x10000000u, &cb);
}

int cpa_eq(void) {
    const char *ctl = getenv("CPE_TEST_CTL"), *off = getenv("CPE_TEST_OFF"), *live = getenv("CPE_TEST_LIVE");
    if (ctl == NULL || off == NULL || live == NULL) return 1;
    fails = 0;
    char what[300];
    struct pcm_config c = {2, 44100, 1024, 4, 0, 0, 0, 0, 0};
    cpl_live L;

    /* 1. no settings from the app yet */
    unlink(ctl);
    unlink(off);
    usleep(150000);
    seg_reset();
    app_buffer = own_buffer = 0;
    struct pcm *p = pcm_open(0, 2, 0, &c);
    play(p, 4, 1024, 44100);
    CHECK(app_buffer == 4 && own_buffer == 0 && same_delayed(0, 0), "no settings from the app: the music is handed on untouched (the app's own buffer, no delay)");
    CHECK(read_live(live, &L) && L.state == CPL_PASSING && L.why == CPE_WHY_NOSET && L.rate == 44100,
          "the live file says: untouched, no settings yet");
    pcm_close(p);

    /* 2. a flat EQ, on */
    set_easy(1, 0);
    write_ctl(ctl, 1, 0);
    usleep(150000);
    seg_reset();
    app_buffer = own_buffer = app_changed = 0;
    p = pcm_open(0, 2, 0, &c);
    play(p, 8, 1024, 44100);
    CHECK(own_buffer == 8 && app_buffer == 0, "EQ on: the filter's own buffer goes to TinyALSA");
    CHECK(same_delayed(0, LA_DELAY), "a flat EQ: every sample comes out bit for bit, 63 samples later (the clip guard's look-ahead)");
    int rt = play_retry(p);
    play(p, 3, 1024, 44100);
    CHECK(rt && same_delayed(0, LA_DELAY), "a block TinyALSA refused, written again: its processed samples are sent again (the filter does not run twice over it)");

    /* 3. +6 dB at 1 kHz while it plays, and the live view asked for */
    set_easy(1, 600);
    write_ctl(ctl, 1, 6000);
    play(p, 30, 1024, 44100);
    double g = gain_db(8192);
    snprintf(what, sizeof(what), "the 1 kHz slider at +6 dB, sent while it plays: the tone comes out %.2f dB louder (6.00 +-0.15)", g);
    CHECK(fabs(g - 6.0) < 0.15, what);
    CHECK(app_changed == 0, "the app's buffers are never written to");
    int ok = read_live(live, &L);
    int best = 0;
    for (int b = 1; b < CPL_NSPEC; b++)
        if (L.spec[b] > L.spec[best]) best = b;
    snprintf(what, sizeof(what), "the live file: processing at 44100 Hz, 1024-frame buffers, the output peak (%d, a +6 dB tone: about 6538), the settings in use, processing time (%d ns)",
             L.blk_peak, L.avg_ns);
    CHECK(ok && L.state == CPL_PROCESSING && L.why == CPE_WHY_NONE && L.rate == 44100 && L.frames == 1024 && L.blk_seq >= 30 &&
              L.blk_peak > 6400 && L.blk_peak < 6700 && L.ctl_seq == (int32_t)eq_seq && L.avg_ns > 0 && L.lib == 0x326,
          what);
    snprintf(what, sizeof(what), "the live view: analysed (%u), its strongest band is the one at 1 kHz (band %d, %.1f dBFS)", L.spec_seq,
             best, L.spec[best] / 100.0);
    CHECK(L.spec_seq > 0 && (best == 26 || best == 27), what);

    /* 4. a microphone opens (Siri or a call): the music goes dry, and gets the EQ again after */
    struct pcm_config ci = {2, 24000, 256, 4, 0, 0, 0, 0, 0};
    struct pcm *mic = pcm_open(0, 0, 0x10000000u, &ci);
    usleep(20000);
    play(p, 6, 1024, 44100);
    CHECK(same_delayed(hin_n / 2 - 2048, LA_DELAY), "a microphone open: the music crossfades to dry (bit for bit, 63 samples later)");
    CHECK(read_live(live, &L) && L.state == CPL_PROCESSING && L.why == CPE_WHY_MIC, "the live file says: dry while the microphone is open");
    pcm_close(mic);
    play(p, 12, 1024, 44100);
    g = gain_db(4096);
    snprintf(what, sizeof(what), "the microphone closed: the EQ is back (%.2f dB)", g);
    CHECK(fabs(g - 6.0) < 0.15, what);

    /* 5. the app's switch off while it plays: dry */
    write_ctl(ctl, 0, 0);
    play(p, 8, 1024, 44100);
    CHECK(same_delayed(hin_n / 2 - 2048, LA_DELAY), "EQ on CarPlay switched off while it plays: it crossfades to dry");
    pcm_close(p);
    CHECK(read_live(live, &L) && L.state == CPL_IDLE, "closed: the live file says nothing is open");

    /* 6. a new stream with the switch off: untouched; switched on while it plays: still untouched */
    seg_reset();
    app_buffer = own_buffer = 0;
    p = pcm_open(0, 2, 0, &c);
    play(p, 3, 1024, 44100);
    CHECK(app_buffer == 3 && same_delayed(0, 0) && read_live(live, &L) && L.state == CPL_PASSING && L.why == CPE_WHY_SWITCH,
          "opened with the switch off: untouched, and the live file says why");
    write_ctl(ctl, 1, 0);
    usleep(150000);
    play(p, 3, 1024, 44100);
    CHECK(app_buffer == 6 && same_delayed(0, 0) && read_live(live, &L) && L.why == CPE_WHY_STARTED,
          "switched on while it plays: it stays untouched until its next open, and says so");
    pcm_close(p);

    /* 7. EQ Engine turned off: untouched */
    FILE *f = fopen(off, "w");
    if (f) fclose(f);
    usleep(150000);
    seg_reset();
    app_buffer = 0;
    p = pcm_open(0, 2, 0, &c);
    play(p, 3, 1024, 44100);
    CHECK(app_buffer == 3 && same_delayed(0, 0) && read_live(live, &L) && L.why == CPE_WHY_OFF, "EQ Engine turned off: untouched");
    pcm_close(p);
    unlink(off);
    usleep(150000);

    /* 8. Siri's 24 kHz voice on the main link: untouched */
    seg_reset();
    app_buffer = 0;
    struct pcm_config c24 = {2, 24000, 256, 4, 0, 0, 0, 0, 0};
    p = pcm_open(0, 2, 0, &c24);
    play(p, 4, 256, 24000);
    CHECK(app_buffer == 4 && same_delayed(0, 0) && read_live(live, &L) && L.why == CPE_WHY_FORMAT,
          "a 24 kHz stream (Siri, calls): untouched");
    pcm_close(p);

    /* 9. Expert: one peak at 1 kHz, +6 dB, one octave */
    set_expert_peak(100000, 600, 1000);
    write_ctl(ctl, 1, 0);
    usleep(150000);
    seg_reset();
    p = pcm_open(0, 2, 0, &c);
    play(p, 20, 1024, 44100);
    g = gain_db(8192);
    snprintf(what, sizeof(what), "Expert, a 1 kHz peak at +6 dB: %.2f dB", g);
    CHECK(fabs(g - 6.0) < 0.15, what);

    /* 9b. (0.7.8) a layout 4 control file: a stereo width of 150 % on the test tone (right at half
       the left: mid 0.75, side 0.25 of the left), so the left comes out at 0.75 + 1.5 x 0.25 = 1.125
       (+1.02 dB); then 0 % (mono): 0.75 (-2.50 dB) */
    set_easy4(150, 0);
    write_ctl(ctl, 1, 0);
    play(p, 20, 1024, 44100);
    g = gain_db(8192);
    snprintf(what, sizeof(what), "layout 4: stereo width 150 %%: the left %.2f dB (+1.02 +-0.1)", g);
    CHECK(fabs(g - 20 * log10(1.125)) < 0.1, what);
    set_easy4(0, 120);
    write_ctl(ctl, 1, 0);
    play(p, 20, 1024, 44100);
    g = gain_db(8192);
    snprintf(what, sizeof(what), "layout 4: width 0 %% (mono) with mono bass: the left %.2f dB (-2.50 +-0.1)", g);
    CHECK(fabs(g - 20 * log10(0.75)) < 0.1, what);
    set_expert_peak(100000, 600, 1000);
    write_ctl(ctl, 1, 0);
    play(p, 20, 1024, 44100);
    g = gain_db(8192);
    snprintf(what, sizeof(what), "layout 3 again (an app before 0.7.8): the 1 kHz peak at +6 dB, as recorded width (%.2f dB)", g);
    CHECK(fabs(g - 6.0) < 0.15, what);

    /* 10. a control file that is not valid: the music goes dry (the last settings kept, EQ off) */
    eq_set[0] = 9;
    write_ctl(ctl, 1, 0);
    play(p, 8, 1024, 44100);
    CHECK(same_delayed(hin_n / 2 - 2048, LA_DELAY) && read_live(live, &L) && L.why == CPE_WHY_NOSET,
          "settings that are not valid: it goes dry, and the live file says no settings");
    pcm_close(p);

    /* 11. a long drive: every pause is a new stream; past the watch's 64 slots the EQ still works */
    set_easy(1, 600);
    write_ctl(ctl, 1, 0);
    usleep(150000);
    for (int k = 0; k < 70; k++) {
        p = pcm_open(0, 2, 0, &c);
        play(p, 1, 1024, 44100);
        pcm_close(p);
        if (k % 20 == 19) usleep(350000); /* the watch writes the closed streams' notes */
    }
    usleep(350000);
    seg_reset();
    own_buffer = app_buffer = 0;
    p = pcm_open(0, 2, 0, &c);
    play(p, 20, 1024, 44100);
    g = gain_db(8192);
    snprintf(what, sizeof(what), "the 75th stream (the table holds 64): still through the EQ (%.2f dB)", g);
    CHECK(own_buffer == 20 && fabs(g - 6.0) < 0.15, what);
    pcm_close(p);

    /* 12. (0.7.6) a close that takes long while the table is full: another thread opens a stream
       meanwhile (here from inside TinyALSA's close, after the watch has written the closing stream's
       notes). The closing stream's slot stays its own until the close is done: run.sh checks that
       its close is noted under its own number and that the other open finds the table full. */
    usleep(350000);
    struct pcm *keep[63];
    struct pcm_config ck = c;
    for (int k = 0; k < 63; k++) {
        keep[k] = pcm_open(0, 1, 0, &ck);
        if (k % 12 == 11) usleep(250000); /* the watch writes the notes a few at a time */
    }
    usleep(250000);
    struct pcm_config ca = c;
    ca.period_size = 999;
    p = pcm_open(0, 2, 0, &ca);
    play(p, 2, 1024, 44100);
    fake_close_hook = race_open;
    pcm_close(p);
    if (race_b != NULL) pcm_close(race_b);
    for (int k = 0; k < 63; k++) pcm_close(keep[k]);

    /* 13. (0.7.6) the same settings written again with a new number (the app's once-a-second "the
       live view is wanted"): not applied again; different settings are */
    set_easy(1, 600);
    write_ctl(ctl, 1, 0);
    usleep(150000);
    p = pcm_open(0, 2, 0, &c);
    play(p, 4, 1024, 44100);
    struct pcm *dummy;
    struct pcm_config cd = c;
    dummy = pcm_open(0, 1, 0, &cd);
    pcm_close(dummy);
    usleep(350000);
    long a0 = read_applies();
    write_ctl(ctl, 1, 0);
    usleep(150000);
    write_ctl(ctl, 1, 0);
    usleep(150000);
    dummy = pcm_open(0, 1, 0, &cd);
    pcm_close(dummy);
    usleep(350000);
    long a1 = read_applies();
    set_easy(1, 300);
    write_ctl(ctl, 1, 0);
    usleep(150000);
    dummy = pcm_open(0, 1, 0, &cd);
    pcm_close(dummy);
    usleep(350000);
    long a2 = read_applies();
    snprintf(what, sizeof(what), "the same settings written again (a new number) are not applied again, new ones are (applies %ld, %ld, %ld)", a0, a1, a2);
    CHECK(a0 > 0 && a1 == a0 && a2 == a1 + 1, what);
    play(p, 4, 1024, 44100);

    /* 13b. (after 0.7.6) the answers for Auto and Copy Easy EQ (+3 dB at 1 kHz, Easy): worked out once
       the settings have held for 300 ms, for the control file in use */
    usleep(500000);
    {
        int okl = read_live(live, &L);
        snprintf(what, sizeof(what), "the live file has Auto's and Copy Easy EQ's answers for the settings in use (seq %d of %d, "
                 "largest boost %d at %d Hz, rate %d, 1 kHz band %d)", L.ans_seq, L.ctl_seq, L.ans_peak[0], L.ans_peak[1],
                 L.ans_rate, L.ans_gains[5]);
        CHECK(okl && L.ans_seq == L.ctl_seq && L.ans_peak[0] >= 280 && L.ans_peak[0] <= 340 && L.ans_peak[1] > 500 &&
                  L.ans_peak[1] < 2000 && L.ans_gains[5] > 200 && L.ans_rate == 44100,
              what);
    }

    /* 14. (after 0.7.6) an update of EQ Engine deletes /data/eqengine while the CarPlay app runs the
       watch: the live file the app reads is made again within about a second, and the notes go on in
       a new file (the old one is renamed here, so run.sh still reads all of them) */
    {
        const char *sl = strrchr(live, '/');
        char logp[512], keep[540];
        snprintf(logp, sizeof(logp), "%.*s/cpw_%d.log", (int)(sl - live), live, (int)getpid());
        snprintf(keep, sizeof(keep), "%s.before", logp);
        rename(logp, keep);
        unlink(live);
        dummy = pcm_open(0, 1, 0, &cd);
        pcm_close(dummy);
        usleep(1600000);
        play(p, 4, 1024, 44100);
        CHECK(read_live(live, &L) && L.pid == (int32_t)getpid() && L.state == CPL_PROCESSING && L.rate == 44100,
              "a deleted live file is made again within about a second, and shows the music being processed");
        dummy = pcm_open(0, 1, 0, &cd);
        pcm_close(dummy);
        usleep(400000);
        char buf[4096];
        int fd = open(logp, O_RDONLY);
        ssize_t r = fd >= 0 ? read(fd, buf, sizeof(buf) - 1) : -1;
        if (fd >= 0) close(fd);
        if (r < 0) r = 0;
        buf[r] = 0;
        CHECK(strstr(buf, "the earlier notes were removed") != NULL && strstr(buf, "open s") != NULL,
              "deleted notes: a new notes file says so, and the notes go on there");
    }
    pcm_close(p);
    return fails;
}

