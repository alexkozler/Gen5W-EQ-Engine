/* Host tests for eqengine.c (0.6.6), driven the way AudioFlinger 4.4 drives an insert effect.
 * The source is included directly so internal functions (design, response) can be checked. */
/* the very high quality loader: a marker file and the PC build of the library (see vhq/host/run.sh) */
#define VHQ_MARK "/tmp/eqe_host_vhq_load"
#define VHQ_LIB "/tmp/vhqhost_40_9/o2/libaudio-resampler.so"
#include "../native/eqengine.c"
#include "ref_process_073.inc"

#include <stdio.h>

static const effect_uuid_t IMPL = { 0x64b3439e, 0x9662, 0x4040, 0x9fd1, { 0x83, 0xf1, 0x16, 0xf7, 0x49, 0x88 } };
static int fails;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static int32_t cmd_int(effect_handle_t h, uint32_t code, uint32_t size, void *data, int32_t *reply) {
    uint32_t rs = sizeof(int32_t);
    return (*h)->command(h, code, size, data, &rs, reply);
}

static int32_t set_param_raw(effect_handle_t h, int32_t id, const void *v, uint32_t vsize) {
    uint32_t total = sizeof(effect_param_t) + 4 + vsize;
    char *buf = calloc(1, total);
    effect_param_t *p = (effect_param_t *)buf;
    p->psize = 4;
    p->vsize = vsize;
    memcpy(p->data, &id, 4);
    memcpy(p->data + 4, v, vsize);
    int32_t reply = 99;
    int32_t r = cmd_int(h, EFFECT_CMD_SET_PARAM, total, p, &reply);
    free(buf);
    return r ? r : reply;
}

static int32_t get_param(effect_handle_t h, int32_t id, void *value, uint32_t vsize, uint32_t *got) {
    uint32_t total = sizeof(effect_param_t) + 4 + vsize;
    char *buf = calloc(1, total);
    effect_param_t *p = (effect_param_t *)buf;
    p->psize = 4;
    p->vsize = vsize;
    memcpy(p->data, &id, 4);
    uint32_t rs = total;
    int32_t r = (*h)->command(h, EFFECT_CMD_GET_PARAM, sizeof(effect_param_t) + 4, buf, &rs, buf);
    if (r == 0 && p->status == 0) {
        memcpy(value, p->data + 4, p->vsize);
        *got = p->vsize;
    }
    int32_t st = r ? r : p->status;
    free(buf);
    return st;
}

static eqe_settings mk(int eq_on, int pre, int guard, const int *bands) {
    eqe_settings s;
    memset(&s, 0, sizeof(s));
    s.layout = 3;
    s.eq_on = eq_on;
    s.preamp_cdb = pre;
    s.guard_on = guard;
    for (int i = 0; i < EQE_NB; i++) s.band_cdb[i] = bands ? bands[i] : 0;
    return s;
}

static eqe_settings mk_ends(int eq_on, int pre, int guard, const int *bands, int ends) {
    eqe_settings s = mk(eq_on, pre, guard, bands);
    s.ends = ends;
    return s;
}

static int32_t apply(effect_handle_t h, eqe_settings s) { return set_param_raw(h, EQE_PARAM_SETTINGS, &s, sizeof(s)); }

/* the designed response at f, dB */
static double resp_at(eqe_ctx *c, double f) {
    double r = 0.0;
    for (int j = 0; j < EQE_NBAND; j++) r += coefs_db(&c->band[j].tgt, f, c->rate);
    return r;
}

static effect_handle_t make(double rate, int16_t *inbuf, int16_t *outbuf, int frames, int accumulate) {
    effect_handle_t h = NULL;
    if (AELI.create_effect(&IMPL, 0, 2, &h) != 0) return NULL;
    int32_t reply = 99;
    cmd_int(h, EFFECT_CMD_INIT, 0, NULL, &reply);
    effect_config_t cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.inputCfg.buffer.frameCount = frames;
    cfg.inputCfg.buffer.raw = inbuf;
    cfg.outputCfg.buffer.frameCount = frames;
    cfg.outputCfg.buffer.raw = outbuf;
    cfg.inputCfg.samplingRate = cfg.outputCfg.samplingRate = (uint32_t)rate;
    cfg.inputCfg.channels = cfg.outputCfg.channels = AUDIO_CHANNEL_OUT_STEREO;
    cfg.inputCfg.format = cfg.outputCfg.format = AUDIO_FORMAT_PCM_16_BIT;
    cfg.inputCfg.accessMode = EFFECT_BUFFER_ACCESS_READ;
    cfg.outputCfg.accessMode = accumulate ? EFFECT_BUFFER_ACCESS_ACCUMULATE : EFFECT_BUFFER_ACCESS_WRITE;
    cmd_int(h, EFFECT_CMD_SET_CONFIG, sizeof(cfg), &cfg, &reply);
    return h;
}

/* measured response of the solved filters at the band centres vs the sliders */
static double centre_error(eqe_ctx *c) {
    double worst = 0.0;
    for (int i = 0; i < EQE_NB; i++) {
        if (!band_usable(c->rate, i)) continue;
        double r = 0.0;
        for (int j = 0; j < EQE_NB; j++) r += coefs_db(&c->band[j].tgt, kCenters[i], c->rate);
        double e = fabs(r - c->set.band_cdb[i] / 100.0);
        if (e > worst) worst = e;
    }
    return worst;
}

static uint32_t lcg = 12345;
static double rnd(void) {
    lcg = lcg * 1664525u + 1013904223u;
    return (lcg >> 8) / 16777216.0;
}

/* runs a stereo sine through h (in place) for `seconds`, returns output RMS over the last half */
static double sine_gain_db(effect_handle_t h, double rate, double f, double amp, double seconds, int16_t *buf, int frames) {
    int total = (int)(seconds * rate);
    double ph = 0.0, sin_sum = 0.0, sout_sum = 0.0;
    int done = 0;
    audio_buffer_t b = { (size_t)frames, { buf } };
    while (done < total) {
        double in[8192];
        for (int i = 0; i < frames; i++) {
            double v = amp * sin(ph);
            ph += 2.0 * EQE_PI * f / rate;
            in[i] = v;
            buf[2 * i] = buf[2 * i + 1] = (int16_t)floor(v * 32767.0 + 0.5);
        }
        (*h)->process(h, &b, &b);
        for (int i = 0; i < frames; i++) {
            if (done + i > total / 2) {
                sin_sum += in[i] * in[i] * 32767.0 * 32767.0;
                sout_sum += (double)buf[2 * i] * buf[2 * i];
            }
        }
        done += frames;
    }
    return 10.0 * log10(sout_sum / sin_sum);
}

int main(void) {
    /* the loader runs once, at the library's first call: the marker must exist before that */
    { FILE *m = fopen(VHQ_MARK, "w"); if (m) fclose(m); }
    int32_t reply;
    uint32_t got;
    effect_descriptor_t d;

    /* ---- library basics */
    CHECK(AELI.tag == AUDIO_EFFECT_LIBRARY_TAG);
    CHECK(EFFECT_API_VERSION_MAJOR(AELI.version) == 3);
    CHECK(AELI.get_descriptor(&IMPL, &d) == 0);
    CHECK(EFFECT_API_VERSION_MAJOR(d.apiVersion) == 2);
    effect_uuid_t other = IMPL;
    other.timeLow ^= 1;
    CHECK(AELI.get_descriptor(&other, &d) == -EINVAL);
    effect_handle_t h0 = NULL;
    CHECK(AELI.create_effect(&other, 0, 2, &h0) == -ENOENT);

    enum { N = 2048 };
    int16_t *mix = calloc(N * 2, sizeof(int16_t));
    int16_t *ref = calloc(N * 2, sizeof(int16_t));
    audio_buffer_t b = { N, { mix } };

    /* ---- no settings yet: bit-exact, delayed by LA - 1 */
    effect_handle_t h = make(44100, mix, mix, N, 0);
    CHECK(h != NULL);
    for (int i = 0; i < N * 2; i++) ref[i] = mix[i] = (int16_t)((i * 7919) % 65536 - 32768);
    CHECK((*h)->process(h, &b, &b) == -ENODATA);
    CHECK(memcmp(mix, ref, N * 4) == 0);
    CHECK(cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply) == 0 && reply == 0);
    CHECK((*h)->process(h, &b, &b) == 0);
    {
        int ok = 1;
        for (int f = 0; f < N; f++) {
            int16_t el = f < LA - 1 ? 0 : ref[2 * (f - (LA - 1))];
            int16_t er = f < LA - 1 ? 0 : ref[2 * (f - (LA - 1)) + 1];
            if (mix[2 * f] != el || mix[2 * f + 1] != er) ok = 0;
        }
        CHECK(ok);
    }

    /* ---- parameter checks */
    int32_t ver = 0;
    CHECK(get_param(h, EQE_PARAM_VERSION, &ver, 4, &got) == 0 && ver == 0x324);
    {
        /* very high quality loader: the marker was there at the first call, so the PC build of
           libaudio-resampler.so is loaded and its status is readable */
        int32_t vq[8];
        CHECK(get_param(h, EQE_PARAM_VHQ, vq, sizeof(vq), &got) == 0);
        printf("very high quality loader: state %d, %d taps per side, %d phase bits, table version %d\n", vq[0], vq[4], vq[5], vq[6]);
        CHECK(vq[0] == 1 && vq[4] == 40 && vq[5] == 9 && vq[6] == 1);
        CHECK(dlopen("libaudio-resampler.so", RTLD_NOW | RTLD_NOLOAD) != NULL);
    }
    eqe_settings bad = mk(1, 0, 1, NULL);
    bad.layout = 1; /* layout 1 is 16 values, not the whole struct */
    CHECK(apply(h, bad) == -EINVAL);
    bad.layout = 2; /* layout 2 is 17 values */
    CHECK(apply(h, bad) == -EINVAL);
    bad.layout = 4;
    CHECK(apply(h, bad) == -EINVAL);
    bad = mk(1, 0, 1, NULL);
    bad.ends = 4;
    CHECK(apply(h, bad) == -EINVAL);
    bad = mk(1, 0, 1, NULL); /* layout 3 sent as 16 or 17 values */
    CHECK(set_param_raw(h, EQE_PARAM_SETTINGS, &bad, EQE_SET1_BYTES) == -EINVAL);
    CHECK(set_param_raw(h, EQE_PARAM_SETTINGS, &bad, EQE_SET2_BYTES) == -EINVAL);
    {
        /* an app from 0.6.6 .. 0.6.10 sends layout 2 (17 values): accepted as Easy mode */
        eqe_settings o2 = mk_ends(1, 0, 1, NULL, EQE_ENDS_HIGH);
        o2.layout = 2;
        o2.band_cdb[2] = -400;
        o2.mode = 1;     /* past the 17 values: not sent, so not seen */
        o2.nx = 5;
        CHECK(set_param_raw(h, EQE_PARAM_SETTINGS, &o2, EQE_SET2_BYTES) == 0);
        eqe_ctx *cc = (eqe_ctx *)h;
        CHECK(cc->set.layout == 3 && cc->set.mode == 0 && cc->set.nx == 0 && cc->set.ends == EQE_ENDS_HIGH && cc->set.band_cdb[2] == -400);
    }
    {
        /* an app from before 0.6.6 sends layout 1 (16 values): accepted, both ends peaks */
        eqe_settings old = mk(1, 0, 1, NULL);
        old.layout = 1;
        old.band_cdb[0] = 300;
        CHECK(set_param_raw(h, EQE_PARAM_SETTINGS, &old, EQE_SET1_BYTES) == 0);
        CHECK(((eqe_ctx *)h)->set.layout == 3 && ((eqe_ctx *)h)->set.mode == 0 && ((eqe_ctx *)h)->set.ends == 0 && ((eqe_ctx *)h)->set.band_cdb[0] == 300);
    }
    bad = mk(1, 0, 1, NULL);
    bad.band_cdb[3] = 1501;
    CHECK(apply(h, bad) == -EINVAL);
    bad = mk(1, 601, 1, NULL);
    CHECK(apply(h, bad) == -EINVAL);
    bad = mk(2, 0, 1, NULL);
    CHECK(apply(h, bad) == -EINVAL);
    bad = mk(1, 0, 1, NULL);
    CHECK(set_param_raw(h, EQE_PARAM_SETTINGS, &bad, sizeof(bad) - 8) == -EINVAL);
    CHECK(set_param_raw(h, 99, &bad, sizeof(bad)) == -EINVAL);
    int32_t small[4];
    CHECK(get_param(h, EQE_PARAM_STATS, small, sizeof(small), &got) == -EINVAL);
    CHECK(get_param(h, EQE_PARAM_RESPONSE, small, sizeof(small), &got) == -EINVAL);

    /* ---- slider accuracy at the band centres */
    eqe_ctx *c = (eqe_ctx *)h;
    double worst_single = 0, worst_all = 0, worst_alt = 0, worst_rand = 0, worst_smile = 0;
    for (int k = 0; k < EQE_NB; k++) {
        int bands[EQE_NB] = {0};
        bands[k] = 1200;
        CHECK(apply(h, mk(1, 0, 1, bands)) == 0);
        double e = centre_error(c);
        if (e > worst_single) worst_single = e;
        bands[k] = -1200;
        CHECK(apply(h, mk(1, 0, 1, bands)) == 0);
        e = centre_error(c);
        if (e > worst_single) worst_single = e;
    }
    {
        int all6[EQE_NB], allm12[EQE_NB], alt[EQE_NB];
        for (int i = 0; i < EQE_NB; i++) { all6[i] = 600; allm12[i] = -1200; alt[i] = (i % 2) ? -1200 : 1200; }
        apply(h, mk(1, 0, 1, all6));
        worst_all = centre_error(c);
        apply(h, mk(1, 0, 1, allm12));
        if (centre_error(c) > worst_all) worst_all = centre_error(c);
        apply(h, mk(1, 0, 1, alt));
        worst_alt = centre_error(c);
        int smile[EQE_NB] = {800, 600, 300, 0, -200, -200, 0, 300, 600, 800};
        apply(h, mk(1, 0, 1, smile));
        worst_smile = centre_error(c);
    }
    for (int t = 0; t < 300; t++) {
        int bands[EQE_NB];
        for (int i = 0; i < EQE_NB; i++) bands[i] = (int)floor((rnd() * 24.0 - 12.0) * 2.0 + 0.5) * 50;
        CHECK(apply(h, mk(1, 0, 1, bands)) == 0);
        double e = centre_error(c);
        if (e > worst_rand) worst_rand = e;
    }
    printf("slider accuracy at band centres (worst error, dB): single band %.3f, all equal %.3f, "
           "smile %.3f, random (300) %.3f, alternating +-12 %.3f\n",
           worst_single, worst_all, worst_smile, worst_rand, worst_alt);
    CHECK(worst_single < 0.1);
    CHECK(worst_all < 0.1);
    CHECK(worst_smile < 0.1);
    CHECK(worst_rand < 0.25);
    CHECK(worst_alt < 1.0);
    /* plain graphic EQ (no correction) for comparison */
    {
        int all6[EQE_NB];
        for (int i = 0; i < EQE_NB; i++) all6[i] = 600;
        double worst = 0;
        for (int i = 0; i < EQE_NB; i++) {
            double r = 0;
            for (int j = 0; j < EQE_NB; j++) {
                coefs_t k = peaking(kCenters[j], all6[j] / 100.0, 44100);
                r += coefs_db(&k, kCenters[i], 44100);
            }
            if (fabs(r - 6.0) > worst) worst = fabs(r - 6.0);
        }
        printf("for comparison, the same all-+6 dB setting without correction is off by up to %.2f dB\n", worst);
    }

    /* ---- response query matches internal design */
    {
        int bands[EQE_NB] = {600, 0, 0, 0, 0, 0, 0, 0, 0, -600};
        apply(h, mk(1, 0, 1, bands));
        int32_t resp[EQE_NRESP];
        CHECK(get_param(h, EQE_PARAM_RESPONSE, resp, sizeof(resp), &got) == 0 && got == sizeof(resp));
        double f0 = eqe_resp_hz(0), f95 = eqe_resp_hz(EQE_NRESP - 1);
        CHECK(fabs(f0 - 20.0) < 1e-9 && fabs(f95 - 20000.0) < 1e-6);
        double mid = 0;
        for (int j = 0; j < EQE_NB; j++) mid += coefs_db(&c->band[j].tgt, eqe_resp_hz(48), 44100);
        CHECK(abs(resp[48] - (int32_t)floor(mid * 100 + 0.5)) <= 1);
        int32_t gains[EQE_NB];
        CHECK(get_param(h, EQE_PARAM_GAINS, gains, sizeof(gains), &got) == 0);
        eqe_settings back;
        CHECK(get_param(h, EQE_PARAM_SETTINGS, &back, sizeof(back), &got) == 0 && back.band_cdb[9] == -600);
    }
    AELI.release_effect(h);

    /* ---- time-domain gains agree with the design (and preamp) */
    {
        h = make(44100, mix, mix, N, 0);
        cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
        int bands[EQE_NB] = {0, 0, 0, 0, 0, 600, 0, 0, 0, 0};
        apply(h, mk(1, -600, 1, bands));
        c = (eqe_ctx *)h;
        double fs[] = {100, 500, 1000, 3000, 12000};
        double worst = 0;
        for (int i = 0; i < 5; i++) {
            double want = -6.0;
            for (int j = 0; j < EQE_NB; j++) want += coefs_db(&c->band[j].tgt, fs[i], 44100);
            double meas = sine_gain_db(h, 44100, fs[i], 0.25, 1.0, mix, N);
            if (fabs(meas - want) > worst) worst = fabs(meas - want);
        }
        printf("time-domain vs designed response (5 tones): worst %.3f dB\n", worst);
        CHECK(worst < 0.05);
        AELI.release_effect(h);
    }

    /* ---- clip guard: +12 dB everywhere on near-full-scale noise */
    {
        h = make(44100, mix, mix, N, 0);
        cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
        int bands[EQE_NB];
        for (int i = 0; i < EQE_NB; i++) bands[i] = 1200;
        apply(h, mk(1, 0, 1, bands));
        c = (eqe_ctx *)h;
        int maxabs = 0;
        long pinned = 0, total = 0;
        for (int blk = 0; blk < 60; blk++) {
            for (int i = 0; i < N * 2; i++) mix[i] = (int16_t)floor((rnd() * 2.0 - 1.0) * 30000.0);
            (*h)->process(h, &b, &b);
            for (int i = 0; i < N * 2; i++) {
                if (abs(mix[i]) > maxabs) maxabs = abs(mix[i]);
                if (mix[i] == 32767 || mix[i] == -32768) pinned++;
                total++;
            }
        }
        printf("clip guard on (+12 dB on near-full-scale noise): samples pinned at full scale %ld of %ld (%.4f%%)\n",
               pinned, total, 100.0 * pinned / total);
        CHECK(pinned * 1000 < total); /* only where dither met the ceiling */
        printf("clip guard on: loudest output sample %d, limited samples %u, clipped %u\n", maxabs, c->limited, c->clipped);
        CHECK(c->limited > 0 && c->clipped == 0);
        apply(h, mk(1, 0, 0, bands));
        for (int blk = 0; blk < 10; blk++) {
            for (int i = 0; i < N * 2; i++) mix[i] = (int16_t)floor((rnd() * 2.0 - 1.0) * 30000.0);
            (*h)->process(h, &b, &b);
        }
        printf("clip guard off: clipped samples %u\n", c->clipped);
        CHECK(c->clipped > 0);
        int32_t st[EQE_STATS_COUNT];
        CHECK(get_param(h, EQE_PARAM_STATS, st, sizeof(st), &got) == 0 && got == sizeof(st));
        CHECK(st[0] == 3 && st[1] == 44100 && st[19] == 0x324 && st[6] == 70 && st[16] > 0 && st[23] == 1);
        AELI.release_effect(h);
    }

    /* ---- average level and clipped-input counters */
    {
        h = make(44100, mix, mix, N, 0);
        cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
        apply(h, mk(0, 0, 1, NULL)); /* EQ off: bit-exact path */
        int32_t st[EQE_STATS_COUNT];
        double ph = 0;
        /* 1 kHz sine at -20 dBFS peak: average -23.01 dB, nothing clipped */
        get_param(h, EQE_PARAM_STATS, st, sizeof(st), &got);
        for (int blk = 0; blk < 40; blk++) {
            for (int f = 0; f < N; f++, ph += 2 * M_PI * 1000.0 / 44100.0)
                mix[2 * f] = mix[2 * f + 1] = (int16_t)lrint(0.1 * 32768.0 * sin(ph));
            (*h)->process(h, &b, &b);
        }
        get_param(h, EQE_PARAM_STATS, st, sizeof(st), &got);
        printf("average level of a -20 dBFS sine: in %.2f, out %.2f dB; clipped input %d\n", st[24] / 100.0, st[25] / 100.0, st[26]);
        CHECK(abs(st[24] + 2301) <= 2 && abs(st[25] + 2301) <= 30 && st[26] == 0 && st[27] == 0);
        /* the same sine at 1.5x full scale, clamped the way Android's mixer does: flat-topped */
        long expect = 0; /* every sample of each run of 2 or more at the same rail, one channel */
        int16_t prevl = 0;
        int run = 0;
        for (int blk = 0; blk < 10; blk++) {
            for (int f = 0; f < N; f++, ph += 2 * M_PI * 1000.0 / 44100.0) {
                double v = 1.5 * 32768.0 * sin(ph);
                int16_t q = v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)lrint(v);
                mix[2 * f] = mix[2 * f + 1] = q;
                if ((q == 32767 || q == -32768) && q == prevl) {
                    if (++run == 2) expect += 2; else expect += 1;
                } else {
                    run = (q == 32767 || q == -32768) ? 1 : 0;
                }
                prevl = q;
            }
            (*h)->process(h, &b, &b);
        }
        get_param(h, EQE_PARAM_STATS, st, sizeof(st), &got);
        printf("clamped sine at 1.5x full scale: clipped input samples %d (both channels), %ld expected; average in %.2f dB\n",
               st[26], 2 * expect, st[24] / 100.0);
        CHECK(st[26] == 2 * expect && st[27] == st[26]);
        /* a single full-scale sample is a peak, not clipping */
        memset(mix, 0, sizeof(int16_t) * 2 * N);
        mix[100] = 32767; mix[101] = -32768; mix[300] = 32767;
        (*h)->process(h, &b, &b);
        get_param(h, EQE_PARAM_STATS, st, sizeof(st), &got);
        printf("isolated full-scale samples: clipped input %d (expected 0)\n", st[26]);
        CHECK(st[26] == 0);
        /* silence */
        memset(mix, 0, sizeof(int16_t) * 2 * N);
        (*h)->process(h, &b, &b);
        get_param(h, EQE_PARAM_STATS, st, sizeof(st), &got);
        CHECK(st[24] == -10000 && st[25] == -10000);
        AELI.release_effect(h);
    }

    /* ---- flat EQ, preamp 0, clip guard on: full-scale input comes out bit-identical */
    {
        h = make(44100, mix, mix, N, 0);
        cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
        c = (eqe_ctx *)h;
        apply(h, mk(1, 0, 1, NULL));
        int16_t prev[2 * (LA - 1)];
        memset(prev, 0, sizeof(prev));
        int ok = 1;
        for (int blk = 0; blk < 6; blk++) {
            for (int i = 0; i < N * 2; i++) ref[i] = mix[i] = (int16_t)((i * 7919 + blk * 31) % 65536 - 32768);
            ref[10] = mix[10] = 32767;
            ref[11] = mix[11] = -32768;
            (*h)->process(h, &b, &b);
            if (blk >= 1) { /* after the EQ-on fade-in */
                if (memcmp(mix, prev, sizeof(prev)) != 0) ok = 0;
                for (int f = LA - 1; f < N; f++)
                    if (mix[2 * f] != ref[2 * (f - (LA - 1))] || mix[2 * f + 1] != ref[2 * (f - (LA - 1)) + 1]) ok = 0;
            }
            memcpy(prev, ref + 2 * (N - (LA - 1)), sizeof(prev));
        }
        printf("flat EQ, preamp 0, clip guard on, full-scale input: bit-identical (delayed %d samples): %s\n", LA - 1,
               ok ? "yes" : "NO");
        CHECK(ok && c->limited == 0);
        AELI.release_effect(h);
    }

    /* ---- listening-position delay: exact shift, validation, click-free changes */
    {
        h = make(44100, mix, mix, N, 0);
        cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
        c = (eqe_ctx *)h;
        eqe_settings sd = mk(1, 0, 1, NULL);
        sd.delay_us[0] = 1000; /* 44.1 samples -> 44 */
        CHECK(apply(h, sd) == 0);
        for (int blk = 0; blk < 2; blk++) { memset(mix, 0, N * 4); (*h)->process(h, &b, &b); }
        memset(mix, 0, N * 4);
        mix[2 * 100] = 10000;
        mix[2 * 100 + 1] = 10000;
        (*h)->process(h, &b, &b);
        int ok = mix[2 * (100 + LA - 1 + 44)] == 10000 && mix[2 * (100 + LA - 1) + 1] == 10000;
        int others = 0;
        for (int f = 0; f < N; f++) {
            if (f != 100 + LA - 1 + 44 && mix[2 * f] != 0) others++;
            if (f != 100 + LA - 1 && mix[2 * f + 1] != 0) others++;
        }
        printf("seat delay 1.0 ms on the left: left impulse %d samples after the right, exact values, nothing else: %s\n", 44,
               ok && others == 0 ? "yes" : "NO");
        CHECK(ok && others == 0);
        sd.delay_us[1] = 5001;
        CHECK(apply(h, sd) == -EINVAL);
        sd.delay_us[1] = -1;
        CHECK(apply(h, sd) == -EINVAL);
        /* move the seat back and forth on a steady tone: no clicks */
        double ph = 0;
        int prev = 0, worst_change = 0, worst_steady = 0;
        for (int blk = 0; blk < 40; blk++) {
            int changing = blk >= 8 && blk % 4 == 0;
            if (changing) {
                eqe_settings m = mk(1, 0, 1, NULL);
                m.delay_us[blk % 8 == 0 ? 0 : 1] = 400 * (blk % 5 + 1);
                apply(h, m);
            }
            for (int i = 0; i < N; i++) {
                double v = 0.3 * sin(ph);
                ph += 2.0 * EQE_PI * 700 / 44100;
                mix[2 * i] = mix[2 * i + 1] = (int16_t)floor(v * 32767 + 0.5);
            }
            (*h)->process(h, &b, &b);
            for (int i = 0; i < N; i++) {
                int st = abs(mix[2 * i] - prev);
                prev = mix[2 * i];
                if (blk < 6) continue;
                if (changing) { if (st > worst_change) worst_change = st; }
                else if (st > worst_steady) worst_steady = st;
            }
        }
        printf("seat delay changes on a steady tone: largest step while changing %d, steady %d\n", worst_change, worst_steady);
        CHECK(worst_change <= worst_steady + 12);
        AELI.release_effect(h);
    }

    /* ---- EQ off returns to the bit-exact path; changes are click-free */
    {
        h = make(44100, mix, mix, N, 0);
        cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
        c = (eqe_ctx *)h;
        int bands[EQE_NB] = {300, 300, 0, 0, -300, 0, 0, 200, 400, 600};
        apply(h, mk(1, -300, 1, bands));
        sine_gain_db(h, 44100, 440, 0.3, 0.5, mix, N);
        CHECK(c->processing == 1);
        apply(h, mk(0, -300, 1, bands));
        sine_gain_db(h, 44100, 440, 0.3, 0.3, mix, N);
        CHECK(c->processing == 0);
        for (int i = 0; i < N * 2; i++) ref[i] = mix[i] = (int16_t)((i * 4099) % 50000 - 25000);
        int16_t tail[2 * (LA - 1)];
        (*h)->process(h, &b, &b);
        /* next buffer starts with the last LA-1 frames of the previous input */
        memcpy(tail, ref + 2 * (N - (LA - 1)), sizeof(tail));
        for (int i = 0; i < N * 2; i++) ref[i] = mix[i] = (int16_t)((i * 811) % 60000 - 30000);
        (*h)->process(h, &b, &b);
        int ok = memcmp(mix, tail, sizeof(tail)) == 0;
        for (int f = LA - 1; f < N && ok; f++)
            if (mix[2 * f] != ref[2 * (f - (LA - 1))] || mix[2 * f + 1] != ref[2 * (f - (LA - 1)) + 1]) ok = 0;
        CHECK(ok);
        printf("EQ off: output is bit-identical to the input (delayed %d samples): %s\n", LA - 1, ok ? "yes" : "NO");

        /* click test: a continuous 1 kHz tone at -12 dBFS; slider 1 kHz 0 -> +12 dB at block 10 */
        apply(h, mk(1, 0, 1, NULL));
        int bands2[EQE_NB] = {0, 0, 0, 0, 0, 1200, 0, 0, 0, 0};
        double ph = 0;
        int maxstep_trans = 0, maxstep_after = 0, prev = 0;
        for (int blk = 0; blk < 40; blk++) {
            if (blk == 10) apply(h, mk(1, 0, 1, bands2));
            for (int i = 0; i < N; i++) {
                double v = 0.25 * sin(ph);
                ph += 2.0 * EQE_PI * 1000 / 44100;
                mix[2 * i] = mix[2 * i + 1] = (int16_t)floor(v * 32767 + 0.5);
            }
            (*h)->process(h, &b, &b);
            for (int i = 0; i < N; i++) {
                int step = abs(mix[2 * i] - prev);
                prev = mix[2 * i];
                if (blk >= 10 && blk < 13) { if (step > maxstep_trans) maxstep_trans = step; }
                else if (blk > 20) { if (step > maxstep_after) maxstep_after = step; }
            }
        }
        printf("slider jump 0 -> +12 dB on a steady tone: largest sample step during the change %d, after %d\n",
               maxstep_trans, maxstep_after);
        CHECK(maxstep_trans <= maxstep_after + 8);
        AELI.release_effect(h);
    }

    /* ---- stability: random settings, random changes, noise; 48 kHz too */
    {
        double rates[] = {44100, 48000};
        for (int ri = 0; ri < 2; ri++) {
            h = make(rates[ri], mix, mix, N, 0);
            cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
            c = (eqe_ctx *)h;
            int finite = 1;
            double worst = 0;
            for (int blk = 0; blk < 400; blk++) {
                if (blk % 7 == 0) {
                    int bands[EQE_NB];
                    for (int i = 0; i < EQE_NB; i++) bands[i] = (int)floor(rnd() * 3001) - 1500;
                    int pre = (int)floor(rnd() * 3001) - 2400;
                    eqe_settings rs = mk(rnd() < 0.85, pre, rnd() < 0.8, bands);
                    rs.delay_us[0] = (int)floor(rnd() * 5001);
                    rs.delay_us[1] = rnd() < 0.5 ? 0 : (int)floor(rnd() * 5001);
                    apply(h, rs);
                    if (centre_error(c) > worst && c->set.eq_on) worst = centre_error(c);
                }
                for (int i = 0; i < N * 2; i++) mix[i] = (int16_t)floor((rnd() * 2.0 - 1.0) * 32767.0 * (blk % 3 == 0 ? 1.0 : 0.05));
                (*h)->process(h, &b, &b);
                for (int j = 0; j < EQE_NB; j++)
                    for (int ch = 0; ch < 2; ch++)
                        if (!isfinite(c->band[j].z1[ch]) || !isfinite(c->band[j].z2[ch])) finite = 0;
                if (!isfinite(c->g2)) finite = 0;
            }
            printf("stability at %.0f Hz: 400 buffers, random settings (+-15 dB): states finite %s, "
                   "worst centre error %.2f dB\n", rates[ri], finite ? "yes" : "NO", worst);
            CHECK(finite);
            AELI.release_effect(h);
        }
    }

    /* ---- Expert mode (settings layout 3): up to 20 bands of its own, each what it says */
    {
        int16_t *buf = calloc(N * 2, sizeof(int16_t));
        h = make(48000, buf, buf, N, 0);
        c = (eqe_ctx *)h;
        cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
        eqe_settings x = mk(1, 0, 1, NULL);
        x.mode = 1;
        /* validation */
        int32_t okb[4] = {EQE_X_PEAK, 63000, -700, 333};
        x.nx = 1; memcpy(x.x[0], okb, sizeof(okb));
        CHECK(apply(h, x) == 0);
        struct { int i; int32_t v; } badv[] = {{0, 0}, {0, 5}, {1, 1999}, {1, 2000001}, {2, 1501}, {2, -1501}, {3, 99}, {3, 4001}};
        for (size_t k = 0; k < sizeof(badv) / sizeof(badv[0]); k++) {
            eqe_settings b = x;
            b.x[0][badv[k].i] = badv[k].v;
            CHECK(apply(h, b) == -EINVAL);
        }
        {
            eqe_settings b = x;
            b.x[0][0] = EQE_X_LOW_CUT; b.x[0][3] = 499;
            CHECK(apply(h, b) == -EINVAL);
            b.x[0][3] = 707; b.x[0][2] = 9999;            /* a low cut has no gain: not checked */
            CHECK(apply(h, b) == 0);
            b.nx = 21;
            CHECK(apply(h, b) == -EINVAL);
            b.nx = 1; b.mode = 2;
            CHECK(apply(h, b) == -EINVAL);
            /* slots past nx may hold anything: ignored and cleared */
            b = x; b.x[5][0] = 77; b.x[5][1] = -3;
            CHECK(apply(h, b) == 0 && c->set.x[5][0] == 0 && c->set.x[5][1] == 0);
        }
        /* each type's shape at 48 kHz */
        CHECK(apply(h, x) == 0);
        double e1 = fabs(resp_at(c, 630.0) + 7.0);
        double lo = resp_at(c, 630.0 / pow(2.0, 0.333 / 2)), hi = resp_at(c, 630.0 * pow(2.0, 0.333 / 2));
        printf("Expert peak 630 Hz -7 dB 0.333 octave: %.3f dB at 630 Hz, %.2f / %.2f dB at the band edges (half gain -3.5)\n",
               resp_at(c, 630.0), lo, hi);
        CHECK(e1 < 0.01 && fabs(lo + 3.5) < 0.2 && fabs(hi + 3.5) < 0.2 && fabs(resp_at(c, 63.0)) < 0.05);
        x.x[0][0] = EQE_X_LOW_CUT; x.x[0][1] = 6000; x.x[0][2] = 0; x.x[0][3] = 707;
        CHECK(apply(h, x) == 0);
        printf("Expert low cut 60 Hz Q 0.707: %.2f dB at 60 Hz, %.2f dB at 30 Hz, %.3f dB at 1 kHz, %.1f dB at 0 Hz\n",
               resp_at(c, 60.0), resp_at(c, 30.0), resp_at(c, 1000.0), resp_at(c, 0.0));
        CHECK(fabs(resp_at(c, 60.0) + 3.01) < 0.05 && fabs(resp_at(c, 30.0) + 12.3) < 0.3 && fabs(resp_at(c, 1000.0)) < 0.01 && resp_at(c, 0.0) < -100.0);
        x.x[0][0] = EQE_X_LOW_SHELF; x.x[0][1] = 6000; x.x[0][2] = -500; x.x[0][3] = 0;
        x.nx = 2; x.x[1][0] = EQE_X_HIGH_SHELF; x.x[1][1] = 1000000; x.x[1][2] = 400; x.x[1][3] = 0;
        CHECK(apply(h, x) == 0);
        CHECK(fabs(resp_at(c, 0.0) + 5.0) < 0.01 && fabs(resp_at(c, 60.0) + 2.5) < 0.05 && fabs(resp_at(c, 1000.0)) < 0.2 &&
              fabs(resp_at(c, 10000.0) - 2.0) < 0.05 && fabs(resp_at(c, 24000.0) - 4.0) < 0.05);
        /* Copy Easy EQ: the Easy page's solved filters as Expert bands give the same sound */
        double worstc = 0.0;
        int clamped = 0;
        for (int t = 0; t < 80; t++) {
            int bands[EQE_NB];
            for (int j = 0; j < EQE_NB; j++) bands[j] = (int)((rnd() * 2.0 - 1.0) * (t < 40 ? 600.0 : 1200.0));
            int ends = t % 4;
            CHECK(apply(h, mk_ends(1, 0, 1, bands, ends)) == 0);
            int32_t gq[EQE_NB];
            CHECK(get_param(h, EQE_PARAM_GAINS, gq, sizeof(gq), &got) == 0);
            double easy[EQE_NRESP];
            for (int k = 0; k < EQE_NRESP; k++) easy[k] = resp_at(c, eqe_resp_hz(k));
            eqe_settings e = mk(1, 0, 1, NULL);
            e.mode = 1; e.nx = EQE_NB;
            int cl = 0;
            for (int j = 0; j < EQE_NB; j++) {
                int lowsh = j == 0 && (ends & EQE_ENDS_LOW), highsh = j == EQE_NB - 1 && (ends & EQE_ENDS_HIGH);
                e.x[j][0] = lowsh ? EQE_X_LOW_SHELF : highsh ? EQE_X_HIGH_SHELF : EQE_X_PEAK;
                e.x[j][1] = lowsh ? 5000 : highsh ? 1130000 : (int32_t)lrint(kCenters[j] * 100.0);
                int g = gq[j];
                if (g > EQE_BAND_LIMIT) { g = EQE_BAND_LIMIT; cl = 1; }
                if (g < -EQE_BAND_LIMIT) { g = -EQE_BAND_LIMIT; cl = 1; }
                e.x[j][2] = g;
                e.x[j][3] = (lowsh || highsh) ? 0 : 1000;
            }
            CHECK(apply(h, e) == 0);
            if (cl) { clamped++; continue; }
            for (int k = 0; k < EQE_NRESP; k++) {
                double d = fabs(resp_at(c, eqe_resp_hz(k)) - easy[k]);
                if (d > worstc) worstc = d;
            }
        }
        printf("Copy Easy EQ: 80 random settings (all four end-band types): worst difference %.4f dB (%d set aside: a solved "
               "gain past +-15 dB)\n", worstc, clamped);
        CHECK(worstc < 0.01);
        /* the largest boost of Expert settings: never below a fine sweep */
        double under = 0.0;
        for (int t = 0; t < 60; t++) {
            eqe_settings r = mk(1, 0, 1, NULL);
            r.mode = 1; r.nx = 1 + (int)(rnd() * 19.99);
            for (int j = 0; j < r.nx; j++) {
                r.x[j][0] = 1 + (int)(rnd() * 3.99);
                r.x[j][1] = (int32_t)(2000.0 * pow(1000.0, rnd()));
                r.x[j][2] = (int32_t)((rnd() * 2.0 - 1.0) * 1500.0);
                r.x[j][3] = r.x[j][0] == EQE_X_PEAK ? 100 + (int)(rnd() * 3900) : r.x[j][0] == EQE_X_LOW_CUT ? 500 + (int)(rnd() * 1500) : 0;
            }
            int32_t pk[3];
            CHECK(set_param_raw(h, EQE_PARAM_PEAK, &r, sizeof(r)) == 0);
            CHECK(get_param(h, EQE_PARAM_PEAK, pk, sizeof(pk), &got) == 0);
            CHECK(apply(h, r) == 0);
            double m = resp_at(c, 0.0);
            for (double f = 0.5; f < 24000.0; f *= 1.001) { double d = resp_at(c, f); if (d > m) m = d; }
            if (m - pk[0] / 100.0 > under) under = m - pk[0] / 100.0;
        }
        printf("Expert largest boost, 60 random settings: at most %.3f dB under a fine sweep\n", under);
        CHECK(under <= 0.005);
        /* 0.7.6 (0x324): the same settings also play at CarPlay's 44.1 kHz, where a band at or above
           0.45 of the rate (19,845 Hz) is left out: a 19 kHz boost next to a 20 kHz cut boosts far
           more there, and the answer is the larger of the rates */
        {
            eqe_settings r = mk(1, 0, 1, NULL);
            r.mode = 1; r.nx = 2;
            r.x[0][0] = EQE_X_PEAK; r.x[0][1] = 1900000; r.x[0][2] = 1200; r.x[0][3] = 500;
            r.x[1][0] = EQE_X_PEAK; r.x[1][1] = 2000000; r.x[1][2] = -1500; r.x[1][3] = 500;
            int32_t pk[3];
            CHECK(set_param_raw(h, EQE_PARAM_PEAK, &r, sizeof(r)) == 0);
            CHECK(get_param(h, EQE_PARAM_PEAK, pk, sizeof(pk), &got) == 0);
            coefs_t k48[EQE_NBAND], k44[EQE_NBAND];
            for (int j = 0; j < EQE_NBAND; j++) {
                k48[j] = j < 2 ? xband_coefs(r.x[j], 48000.0) : kIdentity;
                k44[j] = j < 2 ? xband_coefs(r.x[j], 44100.0) : kIdentity;
            }
            double at48, at44;
            double p48 = peak_gain(k48, 48000.0, &at48), p44 = peak_gain(k44, 44100.0, &at44);
            printf("largest boost, a 19 kHz +12 dB peak next to a 20 kHz -15 dB cut: %+.2f dB at 48 kHz, %+.2f dB at 44.1 kHz; "
                   "asked of the %.0f Hz filter: %+.2f dB at %d Hz, at %d Hz\n", p48, p44, c->rate, pk[0] / 100.0, pk[1], pk[2]);
            CHECK(pk[2] == 44100 && fabs(pk[0] / 100.0 - p44) < 0.02 && p44 > p48 + 3.0);
        }
        /* Easy -> Expert -> Easy while music plays: the ramps stay finite, and every band of the
         * other mode goes quiet */
        {
            int bands[EQE_NB] = {600, 300, 0, -300, 0, 200, 0, -200, 400, 600};
            CHECK(apply(h, mk_ends(1, -600, 1, bands, 3)) == 0);
            double g1 = sine_gain_db(h, 48000, 1000.0, 0.25, 0.3, buf, N);
            eqe_settings r = mk(1, -600, 1, NULL);
            r.mode = 1; r.nx = 20;
            for (int j = 0; j < 20; j++) { r.x[j][0] = EQE_X_PEAK; r.x[j][1] = (int32_t)(2500.0 * pow(1.4, j)); r.x[j][2] = (j & 1) ? 300 : -300; r.x[j][3] = 500; }
            r.x[19][0] = EQE_X_LOW_CUT; r.x[19][1] = 3000; r.x[19][3] = 707;
            CHECK(apply(h, r) == 0);
            double g2 = sine_gain_db(h, 48000, 1000.0, 0.25, 0.3, buf, N);
            int act = 0, finite = 1;
            for (int j = 0; j < EQE_NBAND; j++) {
                if (c->band[j].active) act++;
                for (int ch = 0; ch < 2; ch++) if (!isfinite(c->band[j].z1[ch]) || !isfinite(c->band[j].z2[ch])) finite = 0;
            }
            CHECK(apply(h, mk_ends(1, -600, 1, bands, 3)) == 0);
            double g3 = sine_gain_db(h, 48000, 1000.0, 0.25, 0.3, buf, N);
            int left = 0;
            for (int j = EQE_NB; j < EQE_NBAND; j++) if (!is_identity(&c->band[j].tgt)) left++;
            printf("Easy -> Expert (20 bands) -> Easy at 1 kHz: %.2f, %.2f, %.2f dB; %d filters active in Expert, %d Expert-only "
                   "filters left in Easy\n", g1, g2, g3, act, left);
            CHECK(finite && act == 20 && left == 0 && fabs(g1 - g3) < 0.05 && isfinite(g2));
        }
        AELI.release_effect(h);
        free(buf);
    }

    /* ---- the largest boost (EQE_PARAM_PEAK): from the solved filters, 0 Hz to half the rate, for
     * settings the filter is asked about and does not apply (Auto preamp and the presets) */
    {
        int16_t *buf = calloc(N * 2, sizeof(int16_t));
        h = make(48000, buf, buf, N, 0);
        c = (eqe_ctx *)h;
        int32_t pk[3] = {0};
        CHECK(get_param(h, EQE_PARAM_PEAK, pk, sizeof(pk), &got) != 0); /* nothing asked yet */
        CHECK(apply(h, mk(1, 0, 1, NULL)) == 0);
        /* the worst case found on the PC: 31 Hz shelf +12 next to 63 Hz -12 and 125 Hz +12 */
        int worst[EQE_NB] = {1200, -1200, 1200, 0, 0, 0, 0, 0, 0, 0};
        eqe_settings q = mk_ends(1, 0, 1, worst, EQE_ENDS_LOW);
        CHECK(set_param_raw(h, EQE_PARAM_PEAK, &q, sizeof(q)) == 0);
        CHECK(get_param(h, EQE_PARAM_PEAK, pk, sizeof(pk), &got) == 0 && got == sizeof(pk));
        /* nothing was applied: the flat settings still play */
        int flat = 1;
        for (int j = 0; j < EQE_NB; j++) if (c->set.band_cdb[j] != 0 || !is_identity(&c->band[j].tgt)) flat = 0;
        CHECK(flat && c->set.ends == 0);
        /* the same settings applied: the answer matches a fine sweep of what then plays, and the
         * graph's 96 points (20 Hz .. 20 kHz) see more than 3 dB less */
        CHECK(apply(h, q) == 0);
        double tmax = resp_at(c, 0.0), tat = 0.0;
        for (double f = 0.5; f < 24000.0; f *= 1.001) { double d = resp_at(c, f); if (d > tmax) { tmax = d; tat = f; } }
        double gmax = -1e9;
        for (int k = 0; k < EQE_NRESP; k++) { double d = resp_at(c, eqe_resp_hz(k)); if (d > gmax) gmax = d; }
        printf("largest boost: 31 Hz shelf +12, 63 Hz -12, 125 Hz +12 at 48 kHz: %+.2f dB at %d Hz (fine sweep %+.2f dB at "
               "%.1f Hz; the graph's points %+.2f dB)\n", pk[0] / 100.0, pk[1], tmax, tat, gmax);
        CHECK(pk[0] / 100.0 >= tmax - 0.005 && pk[0] / 100.0 <= tmax + 0.02 && pk[1] == 0 && pk[2] == 48000);
        CHECK(pk[0] / 100.0 > gmax + 3.0 && pk[0] > 2100 && pk[0] < 2400);
        /* random settings, all four end-band types, asked of a filter at either rate: never below a
           fine sweep, and (0.7.6) the answer is the larger of 44.1 and 48 kHz */
        double rates2[] = {44100, 48000};
        double under = 0.0, over = 0.0;
        int other_rate = 0;
        for (int ri = 0; ri < 2; ri++) {
            AELI.release_effect(h);
            h = make(rates2[ri], buf, buf, N, 0);
            c = (eqe_ctx *)h;
            effect_handle_t hb = make(rates2[1 - ri], buf, buf, N, 0);
            eqe_ctx *cb = (eqe_ctx *)hb;
            for (int t = 0; t < 60; t++) {
                int bands[EQE_NB];
                for (int j = 0; j < EQE_NB; j++) bands[j] = (int)((rnd() * 2.0 - 1.0) * 1200.0);
                eqe_settings r = mk_ends(1, 0, 1, bands, t % 4);
                CHECK(set_param_raw(h, EQE_PARAM_PEAK, &r, sizeof(r)) == 0);
                CHECK(get_param(h, EQE_PARAM_PEAK, pk, sizeof(pk), &got) == 0);
                apply(h, r);
                apply(hb, r);
                double m = -1e9;
                for (int w = 0; w < 2; w++) {
                    eqe_ctx *cc = w == 0 ? c : cb;
                    double nyq = 0.5 * cc->rate;
                    double d = resp_at(cc, 0.0); if (d > m) m = d;
                    for (double f = 0.5; f < nyq; f *= 1.001) { d = resp_at(cc, f); if (d > m) m = d; }
                    d = resp_at(cc, nyq); if (d > m) m = d;
                }
                if (pk[2] != (int32_t)rates2[ri]) other_rate++;
                double e = pk[0] / 100.0 - m;
                if (-e > under) under = -e;
                if (e > over) over = e;
            }
            AELI.release_effect(hb);
        }
        printf("largest boost, 120 random settings: at most %.3f dB under and %.3f dB over a fine sweep at both rates "
               "(%d answers from the other rate)\n", under, over, other_rate);
        CHECK(under <= 0.005 && over <= 0.02);
        /* settings that are not valid: refused, and no answer left over */
        eqe_settings bad = mk(1, 0, 1, NULL);
        bad.band_cdb[3] = 5000;
        CHECK(set_param_raw(h, EQE_PARAM_PEAK, &bad, sizeof(bad)) != 0);
        CHECK(get_param(h, EQE_PARAM_PEAK, pk, sizeof(pk), &got) != 0);
        AELI.release_effect(h);
        free(buf);
    }

    /* ---- accumulate mode and unsupported formats */
    {
        int16_t *in = calloc(N * 2, sizeof(int16_t)), *out = calloc(N * 2, sizeof(int16_t));
        h = make(44100, in, out, N, 1);
        cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
        for (int i = 0; i < N * 2; i++) { in[i] = 1000; out[i] = 50; }
        audio_buffer_t bi = { N, { in } }, bo = { N, { out } };
        (*h)->process(h, &bi, &bo);
        CHECK(out[0] == 50 && out[2 * (N - 1)] == 1050);
        AELI.release_effect(h);
        free(in);
        free(out);
    }

    /* ---- layouts other than 16-bit stereo: refused at SET_CONFIG, handed on unchanged and sized
     * by the layout given (each buffer exactly the size Android would pass, so AddressSanitizer
     * catches any read or write past it) */
    {
        const uint32_t MONO = 0x1;
        struct { uint32_t inch, infmt, outch, outfmt; int acc; size_t inb, outb; const char *what; } cases[] = {
            {MONO, AUDIO_FORMAT_PCM_16_BIT, MONO, AUDIO_FORMAT_PCM_16_BIT, 0, 2, 2, "mono 16-bit"},
            {MONO, AUDIO_FORMAT_PCM_16_BIT, MONO, AUDIO_FORMAT_PCM_16_BIT, 1, 2, 2, "mono 16-bit, accumulate"},
            {AUDIO_CHANNEL_OUT_STEREO, AUDIO_FORMAT_PCM_32_BIT, AUDIO_CHANNEL_OUT_STEREO, AUDIO_FORMAT_PCM_32_BIT, 0, 8, 8, "stereo 32-bit"},
            {MONO, AUDIO_FORMAT_PCM_8_BIT, MONO, AUDIO_FORMAT_PCM_8_BIT, 0, 1, 1, "mono 8-bit"},
            {AUDIO_CHANNEL_OUT_STEREO, AUDIO_FORMAT_PCM_16_BIT, MONO, AUDIO_FORMAT_PCM_16_BIT, 0, 4, 2, "stereo in, mono out"},
            {0xF, AUDIO_FORMAT_PCM_16_BIT, 0xF, AUDIO_FORMAT_PCM_16_BIT, 0, 8, 8, "4 channels 16-bit"},
        };
        for (size_t ci = 0; ci < sizeof(cases) / sizeof(cases[0]); ci++) {
            uint8_t *in = malloc(N * cases[ci].inb), *out = malloc(N * cases[ci].outb);
            for (size_t i = 0; i < N * cases[ci].inb; i++) in[i] = (uint8_t)(i * 7 + 1);
            for (size_t i = 0; i < N * cases[ci].outb; i++) out[i] = (uint8_t)(i * 3 + 5);
            uint8_t *before = malloc(N * cases[ci].outb);
            memcpy(before, out, N * cases[ci].outb);
            h = make(44100, NULL, NULL, N, cases[ci].acc);
            eqe_ctx *cc = (eqe_ctx *)h;
            effect_config_t cfg = cc->config;
            cfg.inputCfg.channels = cases[ci].inch;
            cfg.inputCfg.format = cases[ci].infmt;
            cfg.outputCfg.channels = cases[ci].outch;
            cfg.outputCfg.format = cases[ci].outfmt;
            reply = 99;
            cmd_int(h, EFFECT_CMD_SET_CONFIG, sizeof(cfg), &cfg, &reply);
            CHECK(reply == -EINVAL && !cc->cfg_ok);
            cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
            audio_buffer_t bi = { N, { in } }, bo = { N, { out } };
            (*h)->process(h, &bi, &bo);
            int ok;
            if (cases[ci].inch != cases[ci].outch) {
                ok = memcmp(out, before, N * cases[ci].outb) == 0;      /* layouts differ: untouched */
            } else if (cases[ci].acc) {
                ok = 1;
                for (int i = 0; i < N; i++) {
                    int16_t a, b, o;
                    memcpy(&a, in + 2 * i, 2); memcpy(&b, before + 2 * i, 2); memcpy(&o, out + 2 * i, 2);
                    int32_t v = a + b;
                    if (o != (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v)) ok = 0;
                }
            } else {
                ok = memcmp(out, in, N * cases[ci].inb) == 0;           /* handed on, every byte */
            }
            CHECK(ok && cc->unsupported == 1);
            if (!ok) fprintf(stderr, "  layout case: %s\n", cases[ci].what);
            /* a 16-bit stereo config afterwards is taken again and processed */
            int16_t *s_in = calloc(N * 2, sizeof(int16_t)), *s_out = calloc(N * 2, sizeof(int16_t));
            cfg = cc->config;
            cfg.inputCfg.channels = cfg.outputCfg.channels = AUDIO_CHANNEL_OUT_STEREO;
            cfg.inputCfg.format = cfg.outputCfg.format = AUDIO_FORMAT_PCM_16_BIT;
            reply = 99;
            cmd_int(h, EFFECT_CMD_SET_CONFIG, sizeof(cfg), &cfg, &reply);
            audio_buffer_t si = { N, { s_in } }, so = { N, { s_out } };
            (*h)->process(h, &si, &so);
            CHECK(reply == 0 && cc->cfg_ok && cc->unsupported == 1);
            free(s_in); free(s_out);
            AELI.release_effect(h);
            free(in); free(out); free(before);
        }
        printf("layouts other than 16-bit stereo: refused and handed on unchanged, sized by their layout (%d cases)\n",
               (int)(sizeof(cases) / sizeof(cases[0])));
    }

    /* ---- end bands as shelves (0.6.6) and the one-octave bells */
    {
        double rates[] = {44100, 48000};
        for (int ri = 0; ri < 2; ri++) {
            double fs = rates[ri];
            h = make(fs, mix, mix, N, 0);
            c = (eqe_ctx *)h;
            double ws = 0, wr = 0;
            for (int ends = 0; ends < 4; ends++) {
                for (int k = 0; k < EQE_NB; k++) {
                    int bands[EQE_NB] = {0};
                    bands[k] = 1200;
                    CHECK(apply(h, mk_ends(1, 0, 1, bands, ends)) == 0);
                    if (centre_error(c) > ws) ws = centre_error(c);
                    bands[k] = -1200;
                    apply(h, mk_ends(1, 0, 1, bands, ends));
                    if (centre_error(c) > ws) ws = centre_error(c);
                }
                for (int t = 0; t < 100; t++) {
                    int bands[EQE_NB];
                    for (int i = 0; i < EQE_NB; i++) bands[i] = (int)floor((rnd() * 24.0 - 12.0) * 2.0 + 0.5) * 50;
                    apply(h, mk_ends(1, 0, 1, bands, ends));
                    if (centre_error(c) > wr) wr = centre_error(c);
                }
            }
            printf("%.0f Hz, all four end-band combinations: worst centre error single band %.3f dB, random (400) %.3f dB\n", fs,
                   ws, wr);
            CHECK(ws < 0.1 && wr < 0.25);
            /* all ten at +4: peaks fall away past the ends; shelves hold the level */
            int all4[EQE_NB];
            for (int i = 0; i < EQE_NB; i++) all4[i] = 400;
            apply(h, mk_ends(1, 0, 1, all4, 0));
            double p15 = resp_at(c, 15), p20 = resp_at(c, 20), p11 = resp_at(c, 11300), p12 = resp_at(c, 12500);
            double p18 = resp_at(c, 18000), p20k = resp_at(c, 20000);
            apply(h, mk_ends(1, 0, 1, all4, EQE_ENDS_LOW | EQE_ENDS_HIGH));
            double s15 = resp_at(c, 15), s20 = resp_at(c, 20), s11 = resp_at(c, 11300), s12 = resp_at(c, 12500);
            double s18 = resp_at(c, 18000), s20k = resp_at(c, 20000);
            printf("%.0f Hz, all ten +4 dB, peaks: 15 Hz %.1f, 20 Hz %.1f, 11.3k %.1f, 12.5k %.1f, 18k %.1f, 20k %.1f\n", fs, p15,
                   p20, p11, p12, p18, p20k);
            printf("%.0f Hz, all ten +4 dB, shelves: 15 Hz %.1f, 20 Hz %.1f, 11.3k %.1f, 12.5k %.1f, 18k %.1f, 20k %.1f\n", fs, s15,
                   s20, s11, s12, s18, s20k);
            CHECK(p15 < 1.5 && p20 < 2.5);           /* the bell falls away below 31 Hz */
            CHECK(p11 > 3.2 && p12 > 3.2);           /* one-octave bells: no dip between 8 and 16 kHz */
            CHECK(fabs(s15 - 4) < 0.6 && fabs(s20 - 4) < 0.6 && fabs(s18 - 4) < 0.6 && fabs(s20k - 4) < 0.8);
            CHECK(s11 > 3.2 && s12 > 3.2);
            /* one end band alone, +6 dB: the shelf's overshoot past the end stays small */
            int lo6[EQE_NB] = {600, 0, 0, 0, 0, 0, 0, 0, 0, 0}, hi6[EQE_NB] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 600};
            apply(h, mk_ends(1, 0, 1, lo6, EQE_ENDS_LOW));
            double lmax = 0, lmin = 99;
            for (double f = 15; f <= 25; f += 1) { double v = resp_at(c, f); if (v > lmax) lmax = v; if (v < lmin) lmin = v; }
            apply(h, mk_ends(1, 0, 1, hi6, EQE_ENDS_HIGH));
            double hmax = 0, hmin = 99;
            for (double f = 16000; f <= 0.45 * fs; f += 250) { double v = resp_at(c, f); if (v > hmax) hmax = v; if (v < hmin) hmin = v; }
            printf("%.0f Hz, one end band at +6 dB as a shelf: 15-25 Hz %.1f..%.1f dB, 16 kHz up %.1f..%.1f dB\n", fs, lmin, lmax,
                   hmin, hmax);
            CHECK(lmin > 5.0 && lmax < 7.6 && hmin > 5.0 && hmax < 7.6);
            AELI.release_effect(h);
        }
        /* switching an end band between peak and shelf while a tone plays: no click */
        h = make(48000, mix, mix, N, 0);
        cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
        int bands[EQE_NB] = {900, 300, 0, 0, 0, 0, 0, 200, 500, 900};
        apply(h, mk_ends(1, -900, 1, bands, 0));
        double ph = 0;
        int prev = 0, worst_change = 0, worst_steady = 0, finite = 1;
        for (int blk = 0; blk < 40; blk++) {
            int changing = blk >= 8 && blk % 4 == 0;
            if (changing) apply(h, mk_ends(1, -900, 1, bands, (blk / 4) & 3));
            for (int i = 0; i < N; i++) {
                double v = 0.2 * sin(ph) + 0.1 * sin(ph * 0.031);
                ph += 2.0 * EQE_PI * 700 / 48000;
                mix[2 * i] = mix[2 * i + 1] = (int16_t)floor(v * 32767 + 0.5);
            }
            (*h)->process(h, &b, &b);
            c = (eqe_ctx *)h;
            for (int j = 0; j < EQE_NB; j++)
                if (!isfinite(c->band[j].z1[0]) || !isfinite(c->band[j].z2[0])) finite = 0;
            for (int i = 0; i < N; i++) {
                int st = abs(mix[2 * i] - prev);
                prev = mix[2 * i];
                if (blk < 6) continue;
                if (changing) { if (st > worst_change) worst_change = st; }
                else if (st > worst_steady) worst_steady = st;
            }
        }
        printf("end bands switched between peak and shelf on a tone: largest step while changing %d, steady %d, finite %s\n",
               worst_change, worst_steady, finite ? "yes" : "NO");
        CHECK(finite && worst_change <= worst_steady + 12);
        AELI.release_effect(h);
    }

    /* ---- the guard's sliding minimum equals a scan of the look-ahead window */
    {
        h = make(44100, mix, mix, N, 0);
        c = (eqe_ctx *)h;
        double win[LA];
        for (int i = 0; i < LA; i++) win[i] = 1.0;
        int same = 1;
        for (int t = 0; t < 200000; t++) {
            double req = rnd() < 0.7 ? 1.0 : 0.3 + 0.7 * rnd();
            if (t % 5000 < 300) req = 0.5 + 0.0001 * (t % 300); /* rising runs */
            win[t % LA] = req;
            double scan = 1.0;
            for (int i = 0; i < LA; i++) if (win[i] < scan) scan = win[i];
            if (guard_min_push(c, req) != scan) same = 0;
        }
        printf("guard minimum over the look-ahead: queue matches a full scan for 200000 samples: %s\n", same ? "yes" : "NO");
        CHECK(same);
        AELI.release_effect(h);
    }

    /* ---- live view and buffer level (0.6.6) */
    {
        double rates[] = {44100, 48000};
        for (int ri = 0; ri < 2; ri++) {
            double fs = rates[ri];
            h = make(fs, mix, mix, N, 0);
            c = (eqe_ctx *)h;
            cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
            apply(h, mk(1, 0, 1, NULL));
            int32_t sv[4 + EQE_NSPEC], lv[6];
            /* nothing is allocated before the first read */
            double ph = 0;
            for (int blk = 0; blk < 3; blk++) {
                for (int f = 0; f < N; f++, ph += 2 * EQE_PI * 1000.0 / fs) mix[2 * f] = mix[2 * f + 1] = (int16_t)lrint(0.1 * 32768.0 * sin(ph));
                (*h)->process(h, &b, &b);
            }
            CHECK(c->spec == NULL);
            CHECK(get_param(h, EQE_PARAM_SPECTRUM, sv, sizeof(sv), &got) == 0 && got == sizeof(sv));
            CHECK(c->spec != NULL && sv[0] == 0 && sv[1] == -1 && sv[2] == EQE_NSPEC && sv[3] == (int)fs && sv[4] == EQE_RESP_NONE);
            for (int blk = 0; blk < 8; blk++) {
                for (int f = 0; f < N; f++, ph += 2 * EQE_PI * 1000.0 / fs) mix[2 * f] = mix[2 * f + 1] = (int16_t)lrint(0.1 * 32768.0 * sin(ph));
                (*h)->process(h, &b, &b);
            }
            get_param(h, EQE_PARAM_SPECTRUM, sv, sizeof(sv), &got);
            int b1k = -1;
            for (int k = 0; k < EQE_NSPEC; k++) {
                double f = eqe_spec_hz(k), half = sqrt(pow(1000.0, 1.0 / (EQE_NSPEC - 1)));
                if (1000.0 >= f / half && 1000.0 < f * half) b1k = k;
            }
            int b100 = 0, b10k = 0;
            for (int k = 0; k < EQE_NSPEC; k++) {
                if (fabs(eqe_spec_hz(k) - 100) < fabs(eqe_spec_hz(b100) - 100)) b100 = k;
                if (fabs(eqe_spec_hz(k) - 10000) < fabs(eqe_spec_hz(b10k) - 10000)) b10k = k;
            }
            printf("%.0f Hz live view, 1 kHz sine at -20 dBFS peak: %u analyses, band at %.0f Hz %.2f dB (expect -23.01), "
                   "100 Hz %.1f dB, 10 kHz %.1f dB, 20 kHz band %s\n",
                   fs, (unsigned)sv[0], eqe_spec_hz(b1k), sv[4 + b1k] / 100.0, sv[4 + b100] / 100.0, sv[4 + b10k] / 100.0,
                   sv[4 + EQE_NSPEC - 1] == EQE_RESP_NONE ? "none" : "has a level");
            CHECK(sv[0] >= 5 && sv[1] >= 0 && sv[1] < 1000);
            CHECK(b1k >= 0 && abs(sv[4 + b1k] + 2301) <= 40);
            CHECK(sv[4 + b100] < -7000 && sv[4 + b10k] < -7000);
            /* white noise at -20 dBFS RMS: the band powers add up to the total */
            double tot = 0;
            for (int blk = 0; blk < 6; blk++) {
                for (int i = 0; i < N * 2; i += 2) {
                    double v = (rnd() + rnd() + rnd() - 1.5) * 2.0 * 0.1;
                    mix[i] = mix[i + 1] = (int16_t)lrint(v * 32768.0);
                }
                (*h)->process(h, &b, &b);
            }
            get_param(h, EQE_PARAM_SPECTRUM, sv, sizeof(sv), &got);
            for (int k = 0; k < EQE_NSPEC; k++) if (sv[4 + k] != EQE_RESP_NONE) tot += pow(10.0, sv[4 + k] / 1000.0);
            CHECK(get_param(h, EQE_PARAM_LEVEL, lv, sizeof(lv), &got) == 0 && got == sizeof(lv));
            printf("%.0f Hz live view, white noise: bands add up to %.2f dB, the buffer's average level %.2f dB, peak %d, "
                   "%d frames\n", fs, 10 * log10(tot), lv[3] / 100.0, lv[2], lv[4]);
            CHECK(fabs(10 * log10(tot) - lv[3] / 100.0) < 1.0);
            CHECK(lv[0] > 0 && lv[1] >= 0 && lv[2] > 0 && lv[4] == N && lv[5] == (int)fs);
            /* not read for longer than SPEC_KEEP_NS: the analysis stops */
            uint32_t seq = c->spec->seq;
            c->spec_wanted_ns -= SPEC_KEEP_NS + 1;
            for (int blk = 0; blk < 3; blk++) (*h)->process(h, &b, &b);
            CHECK(c->spec->seq == seq);
            AELI.release_effect(h);
        }
    }

    /* ---- cost on this PC (the car's CPU is slower; the car app measures it there) */
    {
        const char *names[] = {"flat EQ (passes through)", "EQ with 10 bands, guard idle", "10 bands, guard limiting",
                               "10 bands and the live view", "Expert, 20 bands, guard idle"};
        for (int mode = 0; mode < 5; mode++) {
            h = make(44100, mix, mix, N, 0);
            cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
            int bands[EQE_NB] = {300, 200, 100, -100, -200, 100, 200, 300, 400, 500};
            int loud[EQE_NB] = {1200, 1200, 1200, 1200, 1200, 1200, 1200, 1200, 1200, 1200};
            if (mode == 0) apply(h, mk(1, 0, 1, NULL));
            else if (mode == 2) apply(h, mk(1, 0, 1, loud));
            else if (mode == 4) {
                eqe_settings r = mk(1, -500, 1, NULL);
                r.mode = 1; r.nx = EQE_NX;
                for (int j = 0; j < EQE_NX; j++) { r.x[j][0] = EQE_X_PEAK; r.x[j][1] = (int32_t)(2500.0 * pow(1.4, j)); r.x[j][2] = (j & 1) ? 300 : -300; r.x[j][3] = 500; }
                apply(h, r);
            }
            else apply(h, mk(1, -500, 1, bands));
            int32_t sv[4 + EQE_NSPEC];
            if (mode == 3) get_param(h, EQE_PARAM_SPECTRUM, sv, sizeof(sv), &got);
            for (int blk = 0; blk < 3; blk++) (*h)->process(h, &b, &b); /* past the fade-in */
            int64_t t0 = now_ns(), spent = 0;
            for (int blk = 0; blk < 200; blk++) {
                for (int i = 0; i < N * 2; i++) mix[i] = (int16_t)floor((rnd() * 2.0 - 1.0) * (mode == 2 ? 30000.0 : 20000.0));
                int64_t a = now_ns();
                (*h)->process(h, &b, &b);
                spent += now_ns() - a;
            }
            (void)t0;
            double per = spent / 200.0 / 1000.0;
            printf("cost on this PC (sanitizers on), %s: %.0f us per 2048-frame buffer = %.2f%% of real time\n", names[mode], per,
                   per / (N / 44100.0 * 1e6) * 100.0);
            AELI.release_effect(h);
        }
    }

    /* ---- bands a chunk at a time (0.7.4, bands_block) against 0.7.3's one-sample-at-a-time
     * process_frames (tests/ref_process_073.inc): the same output bit for bit, and the same filter
     * state after every buffer, through random Easy and Expert settings, changes while playing (ramps
     * across chunk and buffer edges), EQ off and on (the crossfade and the bit-exact path), flat
     * (transparent), loud input (the clip guard), silence, seat delays, preamp moves, both buffer
     * modes, odd buffer sizes. */
    {
        enum { NMAX = 3000 };
        int16_t *in = (int16_t *)malloc(NMAX * 4), *oa = (int16_t *)malloc(NMAX * 4), *ob = (int16_t *)malloc(NMAX * 4);
        effect_handle_t ha = make(48000, in, oa, NMAX, 0), hb = make(48000, in, ob, NMAX, 0);
        eqe_ctx *ca = (eqe_ctx *)ha, *cb = (eqe_ctx *)hb;
        cb->rng = ca->rng;
        long buffers = 0, frames_all = 0, diff = 0, state_diff = 0, blocked = 0, ramps = 0, limited = 0;
        double ph = 0.0;
        for (int round = 0; round < 1500; round++) {
            if (round % 6 == 0) {
                /* new settings: Easy or Expert, sometimes flat or off */
                int bands[EQE_NB];
                for (int i = 0; i < EQE_NB; i++) bands[i] = (int)floor((rnd() * 2 - 1) * 1200) / 50 * 50;
                double kind = rnd();
                if (kind < 0.12) for (int i = 0; i < EQE_NB; i++) bands[i] = 0;
                eqe_settings s = mk_ends(rnd() < 0.85, kind < 0.12 && rnd() < 0.5 ? 0 : (int)(-rnd() * 1200) / 50 * 50,
                                         rnd() < 0.8, bands, (int)(rnd() * 4));
                if (rnd() < 0.3) {
                    s.delay_us[0] = (int)(rnd() * 5000);
                    s.delay_us[1] = rnd() < 0.5 ? 0 : (int)(rnd() * 5000);
                }
                if (kind > 0.45) {
                    s.mode = 1;
                    s.nx = (int)(rnd() * (EQE_NX + 1));
                    for (int j = 0; j < s.nx; j++) {
                        int t = 1 + (int)(rnd() * 4);
                        s.x[j][0] = t;
                        s.x[j][1] = 2000 + (int)(pow(rnd(), 2) * 1998000);
                        s.x[j][2] = t == EQE_X_LOW_CUT ? 0 : (int)((rnd() * 2 - 1) * 1500);
                        s.x[j][3] = t == EQE_X_PEAK ? 100 + (int)(rnd() * 3900) : t == EQE_X_LOW_CUT ? 500 + (int)(rnd() * 1500) : 0;
                    }
                }
                int ra = apply(ha, s), rb = apply(hb, s);
                CHECK(ra == 0 && rb == 0);
                ramps += ca->ramp_left > 0;
            }
            int n = 1 + (int)(rnd() * (NMAX - 1));
            if (rnd() < 0.3) n = 1 + (int)(rnd() * 300);
            double amp = rnd() < 0.15 ? 0.0 : rnd() < 0.3 ? 32767.0 : 2000.0 + rnd() * 20000.0;
            for (int i = 0; i < n; i++) {
                ph += 0.031 + 0.002 * sin(i * 0.001);
                double v = amp * (0.6 * sin(ph) + 0.4 * (rnd() * 2 - 1));
                in[2 * i] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
                in[2 * i + 1] = (int16_t)(amp * (rnd() * 2 - 1) * 0.9);
            }
            int acc = rnd() < 0.2;
            for (int i = 0; i < 2 * n; i++) oa[i] = ob[i] = acc ? (int16_t)(rnd() * 2000 - 1000) : 0;
            int would_block = 0;
            {
                int nb = 0;
                for (int j = 0; j < EQE_NBAND; j++) nb += ca->band[j].active;
                would_block = nb > 0 && ca->processing && ca->w_tgt > 0.0;
            }
            uint32_t lim0 = ca->limited;
            process_frames(ca, in, oa, (size_t)n, acc, NULL);
            process_frames_ref(cb, in, ob, (size_t)n, acc, NULL);
            buffers++;
            frames_all += n;
            blocked += would_block;
            limited += ca->limited != lim0;
            if (memcmp(oa, ob, (size_t)n * 4) != 0) diff++;
            if (memcmp(ca->band, cb->band, sizeof(ca->band)) != 0 || ca->ramp_left != cb->ramp_left || ca->pre_cur != cb->pre_cur ||
                ca->w != cb->w || ca->g2 != cb->g2 || ca->rng != cb->rng || ca->processing != cb->processing ||
                ca->limited != cb->limited || ca->clipped != cb->clipped || ca->dpos != cb->dpos ||
                memcmp(ca->dbuf, cb->dbuf, sizeof(ca->dbuf)) != 0 || memcmp(ca->dl, cb->dl, sizeof(ca->dl)) != 0)
                state_diff++;
        }
        printf("bands a chunk at a time: %ld buffers (%ld frames; %ld through bands_block, %ld with a ramp started, %ld limited) "
               "against 0.7.3's code: %ld differ, %ld with a different state\n",
               buffers, frames_all, blocked, ramps, limited, diff, state_diff);
        CHECK(diff == 0 && state_diff == 0);
        CHECK(blocked > 300 && ramps > 100 && limited > 50);
        AELI.release_effect(ha);
        AELI.release_effect(hb);
        free(in);
        free(oa);
        free(ob);
    }

    CHECK(AELI.release_effect(NULL) == -EINVAL);
    free(mix);
    free(ref);
    if (fails) {
        fprintf(stderr, "%d check(s) failed\n", fails);
        return 1;
    }
    printf("all host tests passed\n");
    return 0;
}
