/* Host stand-in for Android 4.4's AudioResampler.h: the members and constants
 * AudioResamplerSinc.cpp uses, with the same values (kNumPhaseBits 30). */
#pragma once
#include <stdint.h>
#include <sys/types.h>
#include <pthread.h>
#include <cutils/compiler.h>
#include <media/AudioBufferProvider.h>
namespace android {
class AudioResampler {
public:
    enum src_quality { DEFAULT_QUALITY = 0, LOW_QUALITY = 1, MED_QUALITY = 2, HIGH_QUALITY = 3, VERY_HIGH_QUALITY = 4 };
    virtual ~AudioResampler() {}
    virtual void init() = 0;
    virtual void setSampleRate(int32_t inSampleRate) {
        mInSampleRate = inSampleRate;
        mPhaseIncrement = (uint32_t)((kPhaseMultiplier * inSampleRate) / mSampleRate);
    }
    virtual void setVolume(int16_t left, int16_t right) { mVolume[0] = left; mVolume[1] = right; }
    virtual void resample(int32_t* out, size_t outFrameCount, AudioBufferProvider* provider) = 0;
    virtual void reset() { mInputIndex = 0; mPhaseFraction = 0; mBuffer.frameCount = 0; }
    src_quality getQuality() const { return mQuality; }
protected:
    static const int kNumPhaseBits = 30;
    static const uint32_t kPhaseMask = (1LU << kNumPhaseBits) - 1;
    static const uint64_t kPhaseMultiplier = 1L << kNumPhaseBits;
    AudioResampler(int bitDepth, int inChannelCount, int32_t sampleRate, src_quality quality)
        : mBitDepth(bitDepth), mChannelCount(inChannelCount), mSampleRate(sampleRate), mInSampleRate(sampleRate),
          mInputIndex(0), mPhaseIncrement(0), mPhaseFraction(0), mLocalTimeFreq(0),
          mPTS(AudioBufferProvider::kInvalidPTS), mQuality(quality) {
        mVolume[0] = mVolume[1] = 0;
        mBuffer.frameCount = 0;
    }
    int64_t calculateOutputPTS(int) { return AudioBufferProvider::kInvalidPTS; }
    const int32_t mBitDepth;
    const int32_t mChannelCount;
    const int32_t mSampleRate;
    int32_t mInSampleRate;
    AudioBufferProvider::Buffer mBuffer;
    union { int16_t mVolume[2]; uint32_t mVolumeRL; };
    int16_t mTargetVolume[2];
    size_t mInputIndex;
    int32_t mPhaseIncrement;
    uint32_t mPhaseFraction;
    uint64_t mLocalTimeFreq;
    int64_t mPTS;
private:
    const src_quality mQuality;
};
}
