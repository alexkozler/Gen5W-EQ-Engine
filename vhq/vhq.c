/*
 * libaudio-resampler.so for EQ Engine: the coefficient tables Android 4.4's VERY_HIGH_QUALITY
 * converter (AudioResamplerSinc) asks for. Android's audio server looks for this library by name
 * the first time it creates a high-quality converter; without it, "very high" uses the same
 * tables as "high". EQ Engine's filter loads it into the audio server (and nowhere else) before
 * that moment, only when the Lab switch is on.
 *
 * The three functions are the ones AudioResamplerSinc::init_routine() looks up with dlsym().
 * eqe_vhq_stats() lets EQ Engine's filter (in the same process) report whether Android uses it.
 * No allocation, no I/O, no threads.
 */
#include <stdint.h>
#include <stdbool.h>
#include "vhq_tables.h"

#define VHQ_TABLE_VERSION 1

#define EXPORT __attribute__((visibility("default")))

static volatile uint32_t n_init, n_down, n_up;

/* Called once per audio server, from Android's converter set-up: taps on each side. */
EXPORT int32_t readResampleFirNumCoeff(void) {
    n_init++;
    return VHQ_HALF_NUM_COEFS;
}

/* Phases = 2^bits, interpolated linearly between rows. */
EXPORT int32_t readResampleFirLerpIntBits(void) {
    return VHQ_COEFS_BITS;
}

/* Called for every block Android converts: true = up-sampling (input rate <= output rate). */
EXPORT const int32_t *readResamplerCoefficients(bool upDownSample) {
    if (upDownSample) {
        n_up++;
        return &vhq_up[0][0];
    }
    n_down++;
    return &vhq_down[0][0];
}

/* For EQ Engine's status page: out[0..5] = set-ups, down-sampling blocks, up-sampling blocks,
 * taps per side, phase bits, table version. */
EXPORT void eqe_vhq_stats(int32_t *out) {
    out[0] = (int32_t)n_init;
    out[1] = (int32_t)(n_down & 0x7fffffffu);
    out[2] = (int32_t)(n_up & 0x7fffffffu);
    out[3] = VHQ_HALF_NUM_COEFS;
    out[4] = VHQ_COEFS_BITS;
    out[5] = VHQ_TABLE_VERSION;
}
