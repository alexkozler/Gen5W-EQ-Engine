#!/bin/sh
# Builds libeqengine.so for the Gen5W head unit: 32-bit ARM, Android 4.4 (API 19), NDK r25c.
# Plain C, no C++ runtime; links only libc, libdl and liblog, which mediaserver already has.
# Linker flags match the NDK build systems for API < 30 (--no-rosegment: NDK issues 1196, 1589).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
NDK=${NDK:-$HOME/ndk/android-ndk-r25c}
BIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
OUT=$HERE/out
mkdir -p "$OUT"
"$BIN/armv7a-linux-androideabi19-clang" \
    -std=c11 -O2 -Wall -Wextra -Werror \
    -fPIC -fvisibility=hidden -fno-stack-protector -fno-exceptions \
    -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -mthumb \
    -shared -o "$OUT/libeqengine.so" "$HERE/eqengine.c" \
    -Wl,-soname,libeqengine.so -Wl,--hash-style=both -Wl,-z,noexecstack -Wl,-z,relro \
    -Wl,--no-undefined -Wl,--build-id=sha1 -Wl,--no-rosegment -Wl,--fatal-warnings -llog -lm
"$BIN/llvm-strip" --strip-unneeded "$OUT/libeqengine.so"
echo "built $OUT/libeqengine.so"
# Read-only ALSA mixer lister for the Lab's audio trace (a position-independent executable).
"$BIN/armv7a-linux-androideabi19-clang" \
    -std=c11 -O2 -Wall -Wextra -Werror -fPIE -pie \
    -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -mthumb \
    -o "$OUT/alsactl_dump" "$HERE/alsactl_dump.c" \
    -Wl,--hash-style=both -Wl,-z,noexecstack -Wl,-z,relro -Wl,--no-rosegment -Wl,--fatal-warnings
"$BIN/llvm-strip" --strip-unneeded "$OUT/alsactl_dump"
echo "built $OUT/alsactl_dump"
# Very high quality converter tables for Android's own converter (Lab test). Generated tables,
# no allocation, no I/O; exports only the three functions Android looks up plus a status call.
python3 "$HERE/../vhq/gen_tables.py" 40 9 "$HERE/../vhq/vhq_tables.h" > /dev/null
"$BIN/armv7a-linux-androideabi19-clang" \
    -std=c11 -O2 -Wall -Wextra -Werror \
    -fPIC -fvisibility=hidden -fno-stack-protector \
    -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -mthumb -I"$HERE/../vhq" \
    -shared -o "$OUT/libaudio-resampler.so" "$HERE/../vhq/vhq.c" \
    -Wl,-soname,libaudio-resampler.so -Wl,--hash-style=both -Wl,-z,noexecstack -Wl,-z,relro \
    -Wl,--no-undefined -Wl,--build-id=sha1 -Wl,--no-rosegment -Wl,--fatal-warnings
"$BIN/llvm-strip" --strip-unneeded "$OUT/libaudio-resampler.so"
echo "built $OUT/libaudio-resampler.so"
# Driver watch (Lab test): pass-through layer in front of Hyundai's audio driver. Built against
# the Android 4.4.2 headers in aosp44/; forwarders for the driver's exported helper functions are
# generated from drvwatch_exports.txt (names only).
python3 "$HERE/gen_tramp.py" "$HERE/drvwatch_exports.txt" "$OUT/drvwatch_tramp.S" "$OUT/drvwatch_tramp_tab.c"
"$BIN/armv7a-linux-androideabi19-clang" \
    -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-sign-compare \
    -fPIC -fvisibility=hidden -fno-stack-protector \
    -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -mthumb -isystem "$HERE/aosp44" \
    -shared -o "$OUT/eqe_drvwatch.so" "$HERE/drvwatch.c" "$OUT/drvwatch_tramp.S" "$OUT/drvwatch_tramp_tab.c" \
    -Wl,-soname,eqe_drvwatch.so -Wl,--hash-style=both -Wl,-z,noexecstack -Wl,-z,relro -Wl,-z,text \
    -Wl,--no-undefined -Wl,--build-id=sha1 -Wl,--no-rosegment -Wl,--fatal-warnings -ldl -llog -lm
"$BIN/llvm-strip" --strip-unneeded "$OUT/eqe_drvwatch.so"
echo "built $OUT/eqe_drvwatch.so"
# CarPlay watch 2 (Lab test): laid over the factory CarPlay app's libCarPlayAndroid.so (an in-memory
# bind mount); its JNI_OnLoad loads an unchanged copy of the car's file and hands on to it, then
# points libCarPlayAudio.so's imports of TinyALSA's pcm_open, pcm_close, pcm_write and pcm_read at
# pass-through functions that hand each call on, unchanged, to the car's libtinyalsa.so. Exports
# JNI_OnLoad and its check, nothing else.
"$BIN/armv7a-linux-androideabi19-clang" \
    -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-sign-compare \
    -fPIC -fvisibility=hidden -fno-stack-protector \
    -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -mthumb \
    -shared -o "$OUT/eqe_cpwatch.so" "$HERE/cpwatch.c" \
    -Wl,-soname,eqe_cpwatch.so -Wl,--hash-style=both -Wl,-z,noexecstack -Wl,-z,relro -Wl,-z,text \
    -Wl,--no-undefined -Wl,--build-id=sha1 -Wl,--no-rosegment -Wl,--fatal-warnings -ldl -llog -lm
"$BIN/llvm-strip" --strip-unneeded "$OUT/eqe_cpwatch.so"
echo "built $OUT/eqe_cpwatch.so"
# Lab helper for the 48 kHz test (0.6.1): measures the hardware links' real rate from the kernel's
# counters, and sends Android's own per-output settings through the car's libmedia (found by name
# at run time, so nothing of Android's is linked in).
"$BIN/armv7a-linux-androideabi19-clang" \
    -std=c11 -O2 -Wall -Wextra -Werror -fPIE -pie \
    -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -mthumb \
    -o "$OUT/eqe_lab" "$HERE/eqe_lab.c" \
    -Wl,--hash-style=both -Wl,-z,noexecstack -Wl,-z,relro -Wl,--no-rosegment -Wl,--fatal-warnings -ldl
"$BIN/llvm-strip" --strip-unneeded "$OUT/eqe_lab"
echo "built $OUT/eqe_lab"
