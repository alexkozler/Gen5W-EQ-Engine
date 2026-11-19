/*
 * Runs Android 4.4's own converter (AudioResamplerSinc.cpp, unmodified) on the PC with EQ Engine's
 * libaudio-resampler.so, loaded the same way Android loads it (dlopen by name from init_routine).
 *
 *   test_vhq            all checks (exit 1 on any failure)
 *   test_vhq bench      CPU time, high vs very high
 *   test_vhq fallback   run with no library on the path: very high must equal high
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <dlfcn.h>
#include <vector>
#include "AudioResampler.h"
#include "AudioResamplerSinc.h"

using namespace android;

int property_get(const char *, char *value, const char *def) {
    if (def) { strcpy(value, def); return strlen(def); }
    value[0] = 0;
    return 0;
}

static int failures = 0;
#define CHECK(c, ...) do { if (!(c)) { failures++; printf("  FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

// Feeds stereo int16 frames in chunks of varying size, like AudioFlinger's track buffers.
struct Provider : public AudioBufferProvider {
    const std::vector<int16_t> &pcm;
    size_t pos = 0;
    unsigned seed;
    size_t maxChunk;
    Provider(const std::vector<int16_t> &p, unsigned s, size_t mc) : pcm(p), seed(s), maxChunk(mc) {}
    virtual status_t getNextBuffer(Buffer *b, int64_t) {
        size_t frames = pcm.size() / 2;
        if (pos >= frames) { b->raw = NULL; b->frameCount = 0; return -1; }
        seed = seed * 1103515245u + 12345u;
        size_t want = b->frameCount;
        size_t n = 1 + (seed >> 8) % maxChunk;
        if (n > want) n = want;
        if (n > frames - pos) n = frames - pos;
        b->i16 = const_cast<int16_t *>(&pcm[pos * 2]);
        b->frameCount = n;
        return 0;
    }
    virtual void releaseBuffer(Buffer *b) { pos += b->frameCount; b->raw = NULL; b->frameCount = 0; }
};

// Converts `in` (stereo, inRate) to outRate with the given quality; returns int32 output frames
// (both channels) as AudioMixer receives them (unity volume 0x1000).
static std::vector<int32_t> run(AudioResampler::src_quality q, int inRate, int outRate,
                                const std::vector<int16_t> &in, size_t outFrames, unsigned seed = 1, size_t maxChunk = 1024) {
    AudioResamplerSinc *r = new AudioResamplerSinc(16, 2, outRate, q);
    AudioResampler *b = r;
    b->init();
    b->setSampleRate(inRate);
    b->setVolume(0x1000, 0x1000);
    Provider p(in, seed, maxChunk);
    std::vector<int32_t> out(outFrames * 2, 0);
    size_t done = 0;
    while (done < outFrames) {
        size_t n = outFrames - done < 2048 ? outFrames - done : 2048;
        b->resample(&out[done * 2], n, &p);
        done += n;
    }
    delete r;
    return out;
}

static std::vector<int16_t> tone(double f, int rate, size_t frames, double amp, double phaseR = 0.3) {
    std::vector<int16_t> v(frames * 2);
    for (size_t i = 0; i < frames; i++) {
        v[2 * i] = (int16_t)lrint(amp * 32767.0 * sin(2 * M_PI * f * i / rate));
        v[2 * i + 1] = (int16_t)lrint(amp * 32767.0 * sin(2 * M_PI * f * i / rate + phaseR));
    }
    return v;
}

// Least-squares fit of a sine at frequency f (cycles per output sample) to channel 0 of y[from..to):
// amplitude, and the RMS of everything else relative to that amplitude (dB).
static void fit(const std::vector<int32_t> &y, double scale, double f, size_t from, size_t to, double *amp, double *rest) {
    double ss = 0, sc = 0, cc = 0, ys = 0, yc = 0;
    for (size_t i = from; i < to; i++) {
        double s = sin(2 * M_PI * f * i), c = cos(2 * M_PI * f * i), v = y[2 * i] / scale;
        ss += s * s; cc += c * c; sc += s * c; ys += v * s; yc += v * c;
    }
    double det = ss * cc - sc * sc, a = (ys * cc - yc * sc) / det, bb = (yc * ss - ys * sc) / det;
    double e = 0;
    for (size_t i = from; i < to; i++) {
        double v = y[2 * i] / scale - a * sin(2 * M_PI * f * i) - bb * cos(2 * M_PI * f * i);
        e += v * v;
    }
    *amp = hypot(a, bb);
    *rest = 20 * log10(sqrt(e / (to - from)) * sqrt(2.0) / (*amp > 0 ? *amp : 1e-30));
}

static double rms(const std::vector<int32_t> &y, double scale, size_t from, size_t to) {
    double e = 0;
    for (size_t i = from; i < to; i++) e += (y[2 * i] / scale) * (y[2 * i] / scale);
    return sqrt(e / (to - from));
}

// Output for a DC input of 16384, per unit of input: the converter's gain in AudioMixer units.
static double dcGain(AudioResampler::src_quality q, int inRate) {
    std::vector<int16_t> in(48000 * 2, 16384);
    std::vector<int32_t> y = run(q, inRate, 44100, in, 20000);
    double s = 0;
    for (size_t i = 5000; i < 15000; i++) s += y[2 * i];
    return s / 10000 / 16384.0;
}

typedef void (*statsFn)(int32_t *);

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "all";
    const auto HQ = AudioResampler::HIGH_QUALITY, VHQ = AudioResampler::VERY_HIGH_QUALITY;

    if (!strcmp(mode, "fallback")) {
        // libaudio-resampler.so not on the path: Android logs an error and "very high" must
        // produce exactly what "high" produces.
        std::vector<int16_t> in = tone(9000, 48000, 48000, 0.5);
        std::vector<int32_t> a = run(HQ, 48000, 44100, in, 30000), b = run(VHQ, 48000, 44100, in, 30000);
        bool same = a == b;
        printf("library missing: very high %s high (bit for bit)\n", same ? "equals" : "DIFFERS FROM");
        return same ? 0 : 1;
    }

    if (!strcmp(mode, "bench")) {
        std::vector<int16_t> in = tone(1000, 48000, 48000 * 20, 0.5);
        for (auto q : {HQ, VHQ}) {
            clock_t t0 = clock();
            run(q, 48000, 44100, in, 44100 * 19);
            double s = (double)(clock() - t0) / CLOCKS_PER_SEC;
            printf("%s: %.3f s of CPU for 19 s of stereo audio (%.2f%% of real time on this PC)\n",
                   q == HQ ? "high     " : "very high", s, 100 * s / 19);
        }
        return 0;
    }

    // ---- the library is the one Android loads, and Android uses it
    void *lib = dlopen("libaudio-resampler.so", RTLD_NOW | RTLD_NOLOAD);
    printf("before any converter exists, library loaded: %s\n", lib ? "yes" : "no");
    double gH = dcGain(HQ, 48000), gV = dcGain(VHQ, 48000);
    lib = dlopen("libaudio-resampler.so", RTLD_NOW | RTLD_NOLOAD);
    printf("after the first converter, Android has loaded libaudio-resampler.so: %s\n", lib ? "yes" : "no");
    CHECK(lib, "Android's init_routine did not load the library");
    int32_t st[6] = {0};
    statsFn stats = lib ? (statsFn)dlsym(lib, "eqe_vhq_stats") : NULL;
    if (stats) stats(st);
    printf("library stats: set-ups %d, down-sampling blocks %d, up-sampling blocks %d, %d taps per side, %d phase bits\n",
           st[0], st[1], st[2], st[3], st[4]);
    CHECK(st[0] == 1 && st[1] > 0, "Android did not ask the library for its tables");

    // ---- level
    double ratio = 20 * log10(gV / gH);
    printf("gain: high %.6f, very high %.6f (%.3f dB)\n", gH, gV, ratio);
    CHECK(fabs(ratio + 1.6) < 0.01, "very high should be 1.6 dB below high");

    // ---- 48 -> 44.1 kHz response: passband, and everything that is not the tone
    printf("\n48 kHz -> 44.1 kHz (Android Auto music)          high                very high\n");
    printf("   tone      level   rest            level   rest\n");
    double worstFlat = 0, worstRest = -200;
    for (double f : {100.0, 1000.0, 5000.0, 10000.0, 12000.0, 14000.0, 15000.0, 16000.0, 17000.0, 18000.0, 19000.0, 19500.0, 20000.0}) {
        std::vector<int16_t> in = tone(f, 48000, 48000, 0.5);
        double aH, rH, aV, rV;
        std::vector<int32_t> yH = run(HQ, 48000, 44100, in, 40000), yV = run(VHQ, 48000, 44100, in, 40000);
        fit(yH, gH * 32767 * 0.5, f / 44100, 2000, 38000, &aH, &rH);
        fit(yV, gV * 32767 * 0.5, f / 44100, 2000, 38000, &aV, &rV);
        printf("  %6.0f Hz  %6.2f dB  %6.1f dB      %6.2f dB  %6.1f dB\n", f, 20 * log10(aH), rH, 20 * log10(aV), rV);
        if (fabs(20 * log10(aV)) > worstFlat) worstFlat = fabs(20 * log10(aV));
        if (rV > worstRest) worstRest = rV;
    }
    printf("  very high: worst level error up to 20 kHz %.3f dB, worst 'everything else' %.1f dB\n", worstFlat, worstRest);
    CHECK(worstFlat < 0.05, "very high is not flat to 20 kHz");
    CHECK(worstRest < -85, "very high adds more than -85 dB of other signal");

    // ---- content above 22.05 kHz in the 48 kHz source: how much folds back. By design (transition
    // band 20 -> 24.1 kHz) it can only land between 20.1 and 22.05 kHz, above hearing: a 48 kHz
    // source has nothing above 24 kHz. Reported, not judged.
    printf("\nsource content above 22.05 kHz (folds back to 20.1-22.05 kHz)\n");
    for (double f : {22500.0, 23000.0, 23500.0, 23900.0}) {
        std::vector<int16_t> in = tone(f, 48000, 48000, 0.5);
        std::vector<int32_t> yH = run(HQ, 48000, 44100, in, 40000), yV = run(VHQ, 48000, 44100, in, 40000);
        double lH = 20 * log10(rms(yH, gH * 32767 * 0.5, 2000, 38000) * sqrt(2.0));
        double lV = 20 * log10(rms(yV, gV * 32767 * 0.5, 2000, 38000) * sqrt(2.0));
        printf("  %6.0f Hz tone -> %6.0f Hz: high %6.1f dB, very high %6.1f dB\n", f, 44100 - f, lH, lV);
        CHECK(44100 - f >= 20000, "fold-back below 20 kHz");
    }

    // ---- up-sampling: 16 kHz (Android Auto guidance) and 22.05 kHz (prompts)
    double gH16 = dcGain(HQ, 16000), gV16 = dcGain(VHQ, 16000);
    printf("\n16 kHz -> 44.1 kHz (guidance voice); gain %.3f dB vs high\n", 20 * log10(gV16 / gH16));
    for (double f : {1000.0, 3000.0, 5000.0, 6000.0, 6500.0, 7000.0, 7500.0}) {
        std::vector<int16_t> in = tone(f, 16000, 16000 * 3, 0.5);
        std::vector<int32_t> yH = run(HQ, 16000, 44100, in, 120000), yV = run(VHQ, 16000, 44100, in, 120000);
        double aH, rH, aV, rV;
        fit(yH, gH16 * 32767 * 0.5, f / 44100, 4000, 110000, &aH, &rH);
        fit(yV, gV16 * 32767 * 0.5, f / 44100, 4000, 110000, &aV, &rV);
        printf("  %6.0f Hz  high %6.2f dB (rest %6.1f dB)   very high %6.2f dB (rest %6.1f dB)\n", f, 20 * log10(aH), rH, 20 * log10(aV), rV);
        if (f <= 6500) CHECK(fabs(20 * log10(aV)) < 0.05, "up-sampling not flat at %.0f Hz", f);
        if (f <= 6500) CHECK(rV < -80, "up-sampling images at %.0f Hz: %.1f dB", f, rV);
    }

    // ---- 32-bit headroom inside Android's sum: worst-case and full-scale noise inputs.
    // (UBSan aborts on signed overflow in Android's int32 arithmetic.)
    {
        std::vector<int16_t> sq(48000 * 4 * 2), wn(48000 * 4 * 2);
        unsigned s = 7;
        for (size_t i = 0; i < sq.size(); i++) {
            s = s * 1664525u + 1013904223u;
            sq[i] = (s >> 31) ? 32767 : -32768;          // full-scale random +/- (worst real-world case)
            wn[i] = (int16_t)((int32_t)(s >> 16) - 32768);
        }
        // near-Nyquist full-scale square wave, the input that lines up with the filter's lobes
        std::vector<int16_t> ny(48000 * 4 * 2);
        for (size_t i = 0; i < ny.size() / 2; i++) ny[2 * i] = ny[2 * i + 1] = ((i / 1) & 1) ? 32767 : -32768;
        for (int rate : {48000, 16000, 22050, 32000, 11025, 8000}) {
            run(VHQ, rate, 44100, sq, 44100 * 2, 3, 700);
            run(VHQ, rate, 44100, wn, 44100 * 2, 5, 300);
            run(VHQ, rate, 44100, ny, 44100 * 2, 9, 2048);
        }
        printf("\nfull-scale noise, random +/- full scale and a full-scale Nyquist square wave at 6 input rates: no overflow\n");
    }

    // ---- random rates, chunk sizes and signals: no out-of-range reads (ASan), no overflow (UBSan)
    {
        unsigned s = 11;
        for (int k = 0; k < 40; k++) {
            s = s * 1664525u + 1013904223u;
            int rates[] = {8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000};
            int rate = rates[(s >> 8) % 9];
            std::vector<int16_t> in(rate * 2 * 2);
            for (size_t i = 0; i < in.size(); i++) { s = s * 1664525u + 1013904223u; in[i] = (int16_t)(s >> 16); }
            run(VHQ, rate, 44100, in, 44100, s, 1 + (s >> 20) % 4096);
        }
        printf("random rates, chunk sizes and signals: done\n");
    }

    if (stats) stats(st);
    printf("library stats now: set-ups %d (Android set it up once), down %d, up %d\n", st[0], st[1], st[2]);
    CHECK(st[0] == 1, "Android set the library up more than once");
    printf("\n%s\n", failures ? "SOME CHECKS FAILED" : "all checks passed");
    return failures ? 1 : 0;
}
