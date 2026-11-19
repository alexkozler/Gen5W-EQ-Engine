
static inline
int32_t mulRL(int left, int32_t in, uint32_t vRL)
{
#if USE_INLINE_ASSEMBLY
    int32_t out;
    if (left) {
        asm( "smultb %[out], %[in], %[vRL] \n"
             : [out]"=r"(out)
             : [in]"%r"(in), [vRL]"r"(vRL)
             : );
    } else {
        asm( "smultt %[out], %[in], %[vRL] \n"
             : [out]"=r"(out)
             : [in]"%r"(in), [vRL]"r"(vRL)
             : );
    }
    return out;
#else
    int16_t v = left ? int16_t(vRL) : int16_t(vRL>>16);
    return int32_t((int64_t(in) * v) >> 16);
#endif
}

static inline
int32_t mulAdd(int16_t in, int32_t v, int32_t a)
{
#if USE_INLINE_ASSEMBLY
    int32_t out;
    asm( "smlawb %[out], %[v], %[in], %[a] \n"
         : [out]"=r"(out)
         : [in]"%r"(in), [v]"r"(v), [a]"r"(a)
         : );
    return out;
#else
    return a + int32_t((int64_t(v) * in) >> 16);
#endif
}

static inline
int32_t mulAddRL(int left, uint32_t inRL, int32_t v, int32_t a)
{
#if USE_INLINE_ASSEMBLY
    int32_t out;
    if (left) {
        asm( "smlawb %[out], %[v], %[inRL], %[a] \n"
             : [out]"=r"(out)
             : [inRL]"%r"(inRL), [v]"r"(v), [a]"r"(a)
             : );
    } else {
        asm( "smlawt %[out], %[v], %[inRL], %[a] \n"
             : [out]"=r"(out)
             : [inRL]"%r"(inRL), [v]"r"(v), [a]"r"(a)
             : );
    }
    return out;
#else
    int16_t s = left ? int16_t(inRL) : int16_t(inRL>>16);
    return a + int32_t((int64_t(v) * s) >> 16);
#endif
}

// ----------------------------------------------------------------------------

template<int CHANNELS>
void K::filterCoefficient(
        int32_t* out, uint32_t phase, const int16_t *samples, uint32_t vRL)
{
    // NOTE: be very careful when modifying the code here. register
    // pressure is very high and a small change might cause the compiler
    // to generate far less efficient code.
    // Always sanity check the result with objdump or test-resample.

    // compute the index of the coefficient on the positive side and
    // negative side
    const Constants& c(*mConstants);
    const int32_t ONE = c.cMask | c.pMask;
    uint32_t indexP = ( phase & c.cMask) >> c.cShift;
    uint32_t lerpP  = ( phase & c.pMask) >> c.pShift;
    uint32_t indexN = ((ONE-phase) & c.cMask) >> c.cShift;
    uint32_t lerpN  = ((ONE-phase) & c.pMask) >> c.pShift;

    const size_t offset = c.halfNumCoefs;
    indexP *= offset;
    indexN *= offset;

    int32_t const* coefsP = mFirCoefs + indexP;
    int32_t const* coefsN = mFirCoefs + indexN;
    int16_t const* sP = samples;
    int16_t const* sN = samples + CHANNELS;

    size_t count = offset;

    if (!USE_NEON) {
        int32_t l = 0;
        int32_t r = 0;
        for (size_t i=0 ; i<count ; i++) {
            interpolate<CHANNELS>(l, r, coefsP++, offset, lerpP, sP);
            sP -= CHANNELS;
            interpolate<CHANNELS>(l, r, coefsN++, offset, lerpN, sN);
            sN += CHANNELS;
        }
        out[0] += 2 * mulRL(1, l, vRL);
        out[1] += 2 * mulRL(0, r, vRL);
    } else if (CHANNELS == 1) {
        int32_t const* coefsP1 = coefsP + offset;
        int32_t const* coefsN1 = coefsN + offset;
        sP -= CHANNELS*3;
        asm (
            "vmov.32        d2[0], %[lerpP]          \n"    // load the positive phase
            "vmov.32        d2[1], %[lerpN]          \n"    // load the negative phase
            "veor           q0, q0, q0               \n"    // result, initialize to 0
            "vshl.s32       d2, d2, #16              \n"    // convert to 32 bits

            "1:                                      \n"
            "vld1.16        { d4}, [%[sP]]           \n"    // load 4 16-bits stereo samples
            "vld1.32        { q8}, [%[coefsP0]:128]! \n"    // load 4 32-bits coefs
            "vld1.32        { q9}, [%[coefsP1]:128]! \n"    // load 4 32-bits coefs for interpolation
            "vld1.16        { d6}, [%[sN]]!          \n"    // load 4 16-bits stereo samples
            "vld1.32        {q10}, [%[coefsN0]:128]! \n"    // load 4 32-bits coefs
            "vld1.32        {q11}, [%[coefsN1]:128]! \n"    // load 4 32-bits coefs for interpolation

            "vrev64.16      d4, d4                   \n"    // reverse 2 frames of the positive side

            "vsub.s32        q9,  q9,  q8            \n"    // interpolate (step1) 1st set of coefs
            "vsub.s32       q11, q11, q10            \n"    // interpolate (step1) 2nd set of coets
            "vshll.s16      q12,  d4, #15            \n"    // extend samples to 31 bits

            "vqrdmulh.s32    q9,  q9, d2[0]          \n"    // interpolate (step2) 1st set of coefs
            "vqrdmulh.s32   q11, q11, d2[1]          \n"    // interpolate (step3) 2nd set of coefs
            "vshll.s16      q14,  d6, #15            \n"    // extend samples to 31 bits

            "vadd.s32        q8,  q8,  q9            \n"    // interpolate (step3) 1st set
            "vadd.s32       q10, q10, q11            \n"    // interpolate (step4) 2nd set
            "subs           %[count], %[count], #4   \n"    // update loop counter

            "vqrdmulh.s32   q12, q12, q8             \n"    // multiply samples by interpolated coef
            "vqrdmulh.s32   q14, q14, q10            \n"    // multiply samples by interpolated coef
            "sub            %[sP], %[sP], #8         \n"    // move pointer to next set of samples

            "vadd.s32       q0, q0, q12              \n"    // accumulate result
            "vadd.s32       q0, q0, q14              \n"    // accumulate result

            "bne            1b                       \n"    // loop

            "vld1.s32       {d2}, [%[vLR]]           \n"    // load volumes
            "vld1.s32       {d3}, %[out]             \n"    // load the output
            "vpadd.s32      d0, d0, d1               \n"    // add all 4 partial sums
            "vpadd.s32      d0, d0, d0               \n"    // together
            "vdup.i32       d0, d0[0]                \n"    // interleave L,R channels
            "vqrdmulh.s32   d0, d0, d2               \n"    // apply volume
            "vadd.s32       d3, d3, d0               \n"    // accumulate result
            "vst1.s32       {d3}, %[out]             \n"    // store result

            : [out]     "=Uv" (out[0]),
              [count]   "+r" (count),
              [coefsP0] "+r" (coefsP),
              [coefsP1] "+r" (coefsP1),
              [coefsN0] "+r" (coefsN),
              [coefsN1] "+r" (coefsN1),
              [sP]      "+r" (sP),
              [sN]      "+r" (sN)
            : [lerpP]   "r" (lerpP),
              [lerpN]   "r" (lerpN),
              [vLR]     "r" (mVolumeSIMD)
            : "cc", "memory",
              "q0", "q1", "q2", "q3",
              "q8", "q9", "q10", "q11",
              "q12", "q14"
        );
    } else if (CHANNELS == 2) {
        int32_t const* coefsP1 = coefsP + offset;
        int32_t const* coefsN1 = coefsN + offset;
        sP -= CHANNELS*3;
        asm (
            "vmov.32        d2[0], %[lerpP]          \n"    // load the positive phase
            "vmov.32        d2[1], %[lerpN]          \n"    // load the negative phase
            "veor           q0, q0, q0               \n"    // result, initialize to 0
            "veor           q4, q4, q4               \n"    // result, initialize to 0
            "vshl.s32       d2, d2, #16              \n"    // convert to 32 bits

            "1:                                      \n"
            "vld2.16        {d4,d5}, [%[sP]]         \n"    // load 4 16-bits stereo samples
            "vld1.32        { q8}, [%[coefsP0]:128]! \n"    // load 4 32-bits coefs
            "vld1.32        { q9}, [%[coefsP1]:128]! \n"    // load 4 32-bits coefs for interpolation
            "vld2.16        {d6,d7}, [%[sN]]!        \n"    // load 4 16-bits stereo samples
            "vld1.32        {q10}, [%[coefsN0]:128]! \n"    // load 4 32-bits coefs
            "vld1.32        {q11}, [%[coefsN1]:128]! \n"    // load 4 32-bits coefs for interpolation

            "vrev64.16      d4, d4                   \n"    // reverse 2 frames of the positive side
            "vrev64.16      d5, d5                   \n"    // reverse 2 frames of the positive side

            "vsub.s32        q9,  q9,  q8            \n"    // interpolate (step1) 1st set of coefs
            "vsub.s32       q11, q11, q10            \n"    // interpolate (step1) 2nd set of coets
            "vshll.s16      q12,  d4, #15            \n"    // extend samples to 31 bits
            "vshll.s16      q13,  d5, #15            \n"    // extend samples to 31 bits

            "vqrdmulh.s32    q9,  q9, d2[0]          \n"    // interpolate (step2) 1st set of coefs
            "vqrdmulh.s32   q11, q11, d2[1]          \n"    // interpolate (step3) 2nd set of coefs
            "vshll.s16      q14,  d6, #15            \n"    // extend samples to 31 bits
            "vshll.s16      q15,  d7, #15            \n"    // extend samples to 31 bits

            "vadd.s32        q8,  q8,  q9            \n"    // interpolate (step3) 1st set
            "vadd.s32       q10, q10, q11            \n"    // interpolate (step4) 2nd set
            "subs           %[count], %[count], #4   \n"    // update loop counter

            "vqrdmulh.s32   q12, q12, q8             \n"    // multiply samples by interpolated coef
            "vqrdmulh.s32   q13, q13, q8             \n"    // multiply samples by interpolated coef
            "vqrdmulh.s32   q14, q14, q10            \n"    // multiply samples by interpolated coef
            "vqrdmulh.s32   q15, q15, q10            \n"    // multiply samples by interpolated coef
            "sub            %[sP], %[sP], #16        \n"    // move pointer to next set of samples

            "vadd.s32       q0, q0, q12              \n"    // accumulate result
            "vadd.s32       q4, q4, q13              \n"    // accumulate result
            "vadd.s32       q0, q0, q14              \n"    // accumulate result
            "vadd.s32       q4, q4, q15              \n"    // accumulate result

            "bne            1b                       \n"    // loop

            "vld1.s32       {d2}, [%[vLR]]           \n"    // load volumes
            "vld1.s32       {d3}, %[out]             \n"    // load the output
            "vpadd.s32      d0, d0, d1               \n"    // add all 4 partial sums from q0
            "vpadd.s32      d8, d8, d9               \n"    // add all 4 partial sums from q4
            "vpadd.s32      d0, d0, d0               \n"    // together
            "vpadd.s32      d8, d8, d8               \n"    // together
            "vtrn.s32       d0, d8                   \n"    // interlace L,R channels
            "vqrdmulh.s32   d0, d0, d2               \n"    // apply volume
            "vadd.s32       d3, d3, d0               \n"    // accumulate result
            "vst1.s32       {d3}, %[out]             \n"    // store result

            : [out]     "=Uv" (out[0]),
              [count]   "+r" (count),
              [coefsP0] "+r" (coefsP),
              [coefsP1] "+r" (coefsP1),
              [coefsN0] "+r" (coefsN),
              [coefsN1] "+r" (coefsN1),
              [sP]      "+r" (sP),
              [sN]      "+r" (sN)
            : [lerpP]   "r" (lerpP),
              [lerpN]   "r" (lerpN),
              [vLR]     "r" (mVolumeSIMD)
            : "cc", "memory",
              "q0", "q1", "q2", "q3", "q4",
              "q8", "q9", "q10", "q11",
              "q12", "q13", "q14", "q15"
        );
    }
}

template<int CHANNELS>
void K::interpolate(
        int32_t& l, int32_t& r,
        const int32_t* coefs, size_t offset,
        int32_t lerp, const int16_t* samples)
{
    int32_t c0 = coefs[0];
    int32_t c1 = coefs[offset];
    int32_t sinc = mulAdd(lerp, (c1-c0)<<1, c0);
    if (CHANNELS == 2) {
        uint32_t rl = *reinterpret_cast<const uint32_t*>(samples);
        l = mulAddRL(1, rl, sinc, l);
        r = mulAddRL(0, rl, sinc, r);
    } else {
        r = l = mulAdd(samples[0], sinc, l);
    }
}
// ----------------------------------------------------------------------------
