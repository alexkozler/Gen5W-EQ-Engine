/*
 * Runs Android 4.4's linear converter (AudioResamplerOrder1) on the PC: the converter a stock car
 * uses for Android Auto's music (af.resampler.quality unset), and the one Android 4.4 always uses
 * for any ratio other than 44.1 <-> 48 kHz (voice and navigation prompts), whatever the setting.
 *
 * order1.inc is the class and its portable code, extracted unchanged from
 * third_party/aosp-af/AudioResampler.cpp by run.sh (the ARM assembly stays behind its #ifdef).
 *
 * Each figure is checked against linear interpolation's own response (sinc2dB below) at the tone
 * and at its image (input rate - f), which lands in the audible band 3.9 kHz from the tone
 * (44.1 <-> 48 kHz) or at (input rate - f) (up-sampling a 16 or 22.05 kHz voice).
 *
 *   test_linear     prints the figures in README.md's converter section; exit 1 on any failure
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <vector>
#include <cutils/log.h>
#include "AudioResampler.h"

namespace android {
#include "order1.inc"
}
using namespace android;

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
        size_t n = 1 + (seed >> 8) % maxChunk;
        if (n > b->frameCount) n = b->frameCount;
        if (n > frames - pos) n = frames - pos;
        b->i16 = const_cast<int16_t *>(&pcm[pos * 2]);
        b->frameCount = n;
        return 0;
    }
    virtual void releaseBuffer(Buffer *b) { pos += b->frameCount; b->raw = NULL; b->frameCount = 0; }
};

// Converts `in` (stereo, inRate) to outRate; int32 output frames as AudioMixer receives them.
static std::vector<int32_t> run(int inRate, int outRate, const std::vector<int16_t> &in, size_t outFrames) {
    AudioResamplerOrder1 r(16, 2, outRate);
    AudioResampler *b = &r;
    b->init();
    b->setSampleRate(inRate);
    b->setVolume(0x1000, 0x1000);
    Provider p(in, 1, 1024);
    std::vector<int32_t> out(outFrames * 2, 0);
    for (size_t done = 0; done < outFrames;) {
        size_t n = outFrames - done < 2048 ? outFrames - done : 2048;
        b->resample(&out[done * 2], n, &p);
        done += n;
    }
    return out;
}

static std::vector<int16_t> tone(double f, int rate, size_t frames, double amp) {
    std::vector<int16_t> v(frames * 2);
    for (size_t i = 0; i < frames; i++)
        v[2 * i] = v[2 * i + 1] = (int16_t)lrint(amp * 32767.0 * sin(2 * M_PI * f * i / rate));
    return v;
}

// Least-squares sine at f (cycles per output sample) in channel 0 of y[from..to): its amplitude,
// and the RMS of everything else relative to it (dB).
static void fit(const std::vector<int32_t> &y, double scale, double f, size_t from, size_t to, double *amp, double *rest) {
    double ss = 0, sc = 0, cc = 0, ys = 0, yc = 0;
    for (size_t i = from; i < to; i++) {
        double s = sin(2 * M_PI * f * i), c = cos(2 * M_PI * f * i), v = y[2 * i] / scale;
        ss += s * s; cc += c * c; sc += s * c; ys += v * s; yc += v * c;
    }
    double det = ss * cc - sc * sc, a = (ys * cc - yc * sc) / det, bb = (yc * ss - ys * sc) / det;
    *amp = hypot(a, bb);
    if (!rest) return;
    double e = 0;
    for (size_t i = from; i < to; i++) {
        double v = y[2 * i] / scale - a * sin(2 * M_PI * f * i) - bb * cos(2 * M_PI * f * i);
        e += v * v;
    }
    *rest = 20 * log10(sqrt(e / (to - from)) * sqrt(2.0) / (*amp > 0 ? *amp : 1e-30));
}

static double dcGain(int inRate, int outRate) {
    std::vector<int16_t> in(48000 * 2, 16384);
    std::vector<int32_t> y = run(inRate, outRate, in, 20000);
    double s = 0;
    for (size_t i = 5000; i < 15000; i++) s += y[2 * i];
    return s / 10000 / 16384.0;
}

// linear interpolation's response, dB, at f for an input rate fin and output rate fout. With
// unrelated rates the output lands at every phase between two input samples and the response is
// sinc^2(f / fin); at exactly twice the input rate it lands only on a sample and half way, which
// is the filter [1/2 1 1/2] at the output rate: cos^2(pi f / fout).
static double sinc2dB(double f, double fin, double fout) {
    if (fout == 2 * fin) return 20 * log10(pow(cos(M_PI * f / fout), 2));
    double x = M_PI * f / fin;
    return 20 * log10(pow(sin(x) / x, 2));
}

// One conversion: level of each tone, the image (false tone) at `imageOf(f)`, and everything else.
static void table(const char *title, int inRate, int outRate, std::initializer_list<double> tones) {
    double g = dcGain(inRate, outRate);
    CHECK(fabs(g - 4096) < 1, "%s: gain %.1f, expected 4096 (unity in mixer units)", title, g);
    printf("\n%s\n   tone      level   (expected)   false tone              everything else\n", title);
    size_t outFrames = (size_t)outRate * 9 / 10, from = outFrames / 20, to = outFrames - from;
    for (double f : tones) {
        std::vector<int16_t> in = tone(f, inRate, inRate, 0.5);
        std::vector<int32_t> y = run(inRate, outRate, in, outFrames);
        double sc = g * 32767 * 0.5, a, rest, ai;
        fit(y, sc, f / outRate, from, to, &a, &rest);
        // the image at (inRate - f) is heard at its alias in the output band
        double img = inRate - f, heard = img < outRate / 2.0 ? img : outRate - img;
        if (heard < 0) heard = -heard;
        fit(y, sc, heard / outRate, from, to, &ai, NULL);
        double lvl = 20 * log10(a), fal = 20 * log10(ai / a);
        double eLvl = sinc2dB(f, inRate, outRate), eFal = sinc2dB(img, inRate, outRate) - eLvl;
        printf("  %6.0f Hz  %6.2f dB (%6.2f)    %6.1f dB at %5.2f kHz (%6.1f)    %6.1f dB\n",
               f, lvl, eLvl, fal, heard / 1000, eFal, rest);
        CHECK(fabs(lvl - eLvl) < 0.05, "%.0f Hz: level %.2f dB, linear interpolation gives %.2f", f, lvl, eLvl);
        if (f >= 5000) CHECK(fabs(fal - eFal) < 0.3, "%.0f Hz: false tone %.1f dB, linear interpolation gives %.1f", f, fal, eFal);
    }
}

int main() {
    table("48 kHz -> 44.1 kHz (Android Auto's music at a 44.1 kHz output; a stock car, always)", 48000, 44100,
          {1000, 5000, 10000, 12000, 14000, 15000, 16000, 18000, 19000, 20000});
    table("44.1 kHz -> 48 kHz (a 44.1 kHz source at a 48 kHz output with Stock chosen)", 44100, 48000,
          {1000, 5000, 10000, 14000, 16000, 18000, 19000, 20000});
    table("16 kHz -> 44.1 kHz (a voice prompt; linear whatever the converter choice)", 16000, 44100,
          {1000, 3000, 5000, 7000});
    table("22.05 kHz -> 44.1 kHz (a voice prompt; linear whatever the converter choice)", 22050, 44100,
          {1000, 3000, 5000, 7000, 10000});
    printf("\n%s\n", failures ? "SOME CHECKS FAILED" : "all checks passed");
    return failures ? 1 : 0;
}
