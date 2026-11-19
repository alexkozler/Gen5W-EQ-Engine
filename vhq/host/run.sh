#!/bin/sh
# Builds Android 4.4's converter and EQ Engine's library for the PC and runs the checks.
# Usage: run.sh <halfNumCoefs> <coefsBits>
set -e
H=${1:-40}; B=${2:-9}
cd "$(dirname "$0")"
OUT=/tmp/vhqhost_${H}_${B}
mkdir -p $OUT $OUT/nolib
python3 ../gen_tables.py $H $B ../vhq_tables.h > /dev/null
SAN="-fsanitize=address,undefined -fno-sanitize=shift-base -fno-sanitize-recover=all -fno-omit-frame-pointer"
AOSP=$(cd ../../third_party/aosp-af && pwd)
# the library, as Android will load it
gcc -std=c11 -O1 -g $SAN -fPIC -shared -I.. ../vhq.c -o $OUT/libaudio-resampler.so -Wl,-soname,libaudio-resampler.so
# Android's converter (unmodified source) + the checks
g++ -std=gnu++11 -O1 -g $SAN -I. -I$AOSP -Wno-unused-parameter \
    $AOSP/AudioResamplerSinc.cpp test_vhq.cpp -ldl -o $OUT/test_vhq
LD_LIBRARY_PATH=$OUT $OUT/test_vhq all
LD_LIBRARY_PATH=$OUT/nolib $OUT/test_vhq fallback 2>&1 | grep -v "^E/x"
# CPU, without sanitizers
gcc -std=c11 -O2 -fPIC -shared -I.. ../vhq.c -o $OUT/nolib/../libaudio-resampler-o2.so -Wl,-soname,libaudio-resampler.so
mkdir -p $OUT/o2 && cp $OUT/libaudio-resampler-o2.so $OUT/o2/libaudio-resampler.so
g++ -std=gnu++11 -O2 -I. -I$AOSP $AOSP/AudioResamplerSinc.cpp test_vhq.cpp -ldl -o $OUT/bench
LD_LIBRARY_PATH=$OUT/o2 $OUT/bench bench
