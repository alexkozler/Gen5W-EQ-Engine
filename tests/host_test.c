/* Host tests for eqengine.c 0.4, driven the way AudioFlinger 4.4 drives an insert effect.
 * The source is included directly so internal functions (design, response) can be checked. */
/* the very high quality loader: a marker file and the PC build of the library (see vhq/host/run.sh) */
#define VHQ_MARK "/tmp/eqe_host_vhq_load"
#define VHQ_LIB "/tmp/vhqhost_40_9/o2/libaudio-resampler.so"
#include "../native/eqengine.c"

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
    s.layout = 1;
    s.eq_on = eq_on;
    s.preamp_cdb = pre;
    s.guard_on = guard;
    for (int i = 0; i < EQE_NB; i++) s.band_cdb[i] = bands ? bands[i] : 0;
    return s;
}

static int32_t apply(effect_handle_t h, eqe_settings s) { return set_param_raw(h, EQE_PARAM_SETTINGS, &s, sizeof(s)); }

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
    CHECK(get_param(h, EQE_PARAM_VERSION, &ver, 4, &got) == 0 && ver == 0x310);
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
    bad.layout = 2;
    CHECK(apply(h, bad) == -EINVAL);
    bad = mk(1, 0, 1, NULL);
    bad.band_cdb[3] = 1501;
    CHECK(apply(h, bad) == -EINVAL);
    bad = mk(1, 601, 1, NULL);
    CHECK(apply(h, bad) == -EINVAL);
    bad = mk(2, 0, 1, NULL);
    CHECK(apply(h, bad) == -EINVAL);
    bad = mk(1, 0, 1, NULL);
    CHECK(set_param_raw(h, EQE_PARAM_SETTINGS, &bad, sizeof(bad) - 4) == -EINVAL);
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
        CHECK(st[0] == 3 && st[1] == 44100 && st[19] == 0x310 && st[6] == 70 && st[16] > 0 && st[23] == 1);
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
        h = make(44100, in, out, N, 0);
        eqe_ctx *cc = (eqe_ctx *)h;
        cc->config.inputCfg.channels = 0x1; /* mono */
        cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
        for (int i = 0; i < N * 2; i++) { in[i] = (int16_t)i; out[i] = 0; }
        (*h)->process(h, &bi, &bo);
        CHECK(memcmp(in, out, N * 4) == 0 && cc->unsupported == 1);
        AELI.release_effect(h);
        free(in);
        free(out);
    }

    /* ---- cost on this PC (the car's CPU is slower; the car app measures it there) */
    {
        h = make(44100, mix, mix, N, 0);
        cmd_int(h, EFFECT_CMD_ENABLE, 0, NULL, &reply);
        int bands[EQE_NB] = {300, 200, 100, -100, -200, 100, 200, 300, 400, 500};
        apply(h, mk(1, -500, 1, bands));
        int64_t t0 = now_ns();
        for (int blk = 0; blk < 200; blk++) {
            for (int i = 0; i < N * 2; i++) mix[i] = (int16_t)floor((rnd() * 2.0 - 1.0) * 20000.0);
            (*h)->process(h, &b, &b);
        }
        double per = (now_ns() - t0) / 200.0 / 1000.0;
        printf("cost on this PC (sanitizers on): %.0f us per 2048-frame buffer = %.2f%% of real time\n", per,
               per / (N / 44100.0 * 1e6) * 100.0);
        AELI.release_effect(h);
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
