#!/bin/sh
# Driver watch tests on the PC: the layer and a fake driver with Hyundai's 19-entry device table
# (hy_audio.h), built against the Android 4.4 headers (AOSP android-4.4.2_r2: hardware/libhardware
# and system/core include folders), with AddressSanitizer and UndefinedBehaviorSanitizer. The
# hardware links come from a simulated /proc/asound in each run's folder.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
INC="-I$HERE/../../tests -isystem $HERE/../aosp44"
O=/tmp/eqe_drvtest
rm -rf $O && mkdir -p $O/out $O/out_corrupt $O/out_data
SAN="-fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer"
CF="-std=gnu11 -O1 -g -Wall -Wextra -Wno-sign-compare -Wno-unused-parameter -fPIC"
gcc $CF $SAN $INC -shared -o $O/fake_hal.so $HERE/fake_hal.c
for v in out out_corrupt out_data; do
    gcc $CF $SAN $INC -shared -fvisibility=hidden -DDRV_ORIG="\"$O/fake_hal.so\"" -DDRV_DIR="\"$O/$v\"" \
        -DDRV_ASOUND="\"$O/$v/asound\"" -DDRV_WINDOW_MS=300 \
        -o $O/shim_$v.so $HERE/../drvwatch.c $HERE/../drvwatch_tramp_host.c -ldl -lpthread -lm
done
gcc $CF $SAN $INC -o $O/test_drv $HERE/test_drv.c -ldl -lpthread -lm
export ASAN_OPTIONS=detect_leaks=0
echo "== driver watch 2, Hyundai's layout"
$O/test_drv $O/shim_out.so $O/fake_hal.so $O/out
echo "== driver watch 2, an entry that is not a function"
FAKE_CORRUPT=1 $O/test_drv $O/shim_out_corrupt.so $O/fake_hal.so $O/out_corrupt corrupt
echo "== driver watch 2, an entry that points at the driver's data, not its code"
FAKE_DATA_SLOT=1 $O/test_drv $O/shim_out_data.so $O/fake_hal.so $O/out_data corrupt
echo "--- sample of the log"
head -40 $O/out/drv.log
