/* Android 4.4's AudioResamplerSinc::filterCoefficient<2> and interpolate<2>, extracted verbatim
 * from the AOSP source (kernel_body.inc), compiled for ARM in one of three variants:
 *   -DVARIANT=0  plain C (a Thumb build of Android)
 *   -DVARIANT=1  ARM-mode scalar assembly (smlawb / smultb), no NEON
 *   -DVARIANT=2  ARM-mode with NEON assembly
 * Entry point: entry(Args*), run under an emulator by neon_test.py. */
#include <stdint.h>
#include <stddef.h>
#if VARIANT == 0
#define USE_INLINE_ASSEMBLY (false)
#define USE_NEON (false)
#elif VARIANT == 1
#define USE_INLINE_ASSEMBLY (true)
#define USE_NEON (false)
#else
#define USE_INLINE_ASSEMBLY (true)
#define USE_NEON (true)
#endif
#define CC_LIKELY(x) (x)
namespace android {
struct K {
    struct Constants { int coefsBits; int cShift; uint32_t cMask; int pShift; uint32_t pMask; unsigned int halfNumCoefs; };
    const Constants *mConstants;
    const int32_t *mFirCoefs;
    int32_t mVolumeSIMD[2];
    template<int CHANNELS> void filterCoefficient(int32_t* out, uint32_t phase, const int16_t *samples, uint32_t vRL);
    template<int CHANNELS> void interpolate(int32_t& l, int32_t& r, const int32_t* coefs, size_t offset, int32_t lerp, const int16_t* samples);
};
#include "kernel_body.inc"
}
struct Args {
    int32_t *out; uint32_t phase; const int16_t *samples; const int32_t *coefs;
    uint32_t vRL; int32_t volL, volR; int coefsBits; unsigned halfNumCoefs;
};
extern "C" __attribute__((used, section(".text.entry"))) void entry(Args *a) {
    android::K::Constants c;
    const int kNumPhaseBits = 30, pLerpBits = 15;
    c.coefsBits = a->coefsBits;
    c.cShift = kNumPhaseBits - c.coefsBits;
    c.cMask = ((1 << c.coefsBits) - 1) << c.cShift;
    c.pShift = kNumPhaseBits - c.coefsBits - pLerpBits;
    c.pMask = ((1 << pLerpBits) - 1) << c.pShift;
    c.halfNumCoefs = a->halfNumCoefs;
    android::K k;
    k.mConstants = &c;
    k.mFirCoefs = a->coefs;
    k.mVolumeSIMD[0] = a->volL;
    k.mVolumeSIMD[1] = a->volR;
    k.filterCoefficient<2>(a->out, a->phase, a->samples, a->vRL);
}
