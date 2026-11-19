#pragma once
#include <stdint.h>
#include <stddef.h>
namespace android {
typedef int32_t status_t;
class AudioBufferProvider {
public:
    struct Buffer {
        Buffer() : raw(NULL), frameCount(0) { }
        union { void* raw; short* i16; int8_t* i8; };
        size_t frameCount;
    };
    virtual ~AudioBufferProvider() {}
    virtual status_t getNextBuffer(Buffer* buffer, int64_t pts = kInvalidPTS) = 0;
    virtual void releaseBuffer(Buffer* buffer) = 0;
    static const int64_t kInvalidPTS = 0x7FFFFFFFFFFFFFFFLL;
};
}
