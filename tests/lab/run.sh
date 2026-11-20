#!/bin/bash
# PC tests for native/eqe_lab.c (the Lab's 48 kHz helper): link rates from a simulated
# /proc/asound, and the AudioSystem calls through stand-in libraries. Run from anywhere.
R=$(cd "$(dirname "$0")/../.." && pwd)
O=/tmp/eqelab
rm -rf $O; mkdir -p $O
SAN="-fsanitize=address,undefined -fno-sanitize-recover=undefined"
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }

gcc -std=c11 -O1 -g -Wall -Wextra -Werror $SAN -o $O/eqe_lab $R/native/eqe_lab.c -ldl || exit 1
gcc -std=c11 -O1 -g -fPIC -shared -DUTILS -o $O/libutils_fake.so $R/tests/lab/fake_audiosystem.c || exit 1
gcc -std=c11 -O1 -g -fPIC -shared -DMEDIA -o $O/libmedia_fake.so $R/tests/lab/fake_audiosystem.c || exit 1
gcc -std=c11 -O1 -g -fPIC -shared -DMEDIA -DNO_GET -o $O/libmedia_noget.so $R/tests/lab/fake_audiosystem.c || exit 1
export EQE_ASOUND=$O/asound EQE_UTILS_LIB=$O/libutils_fake.so EQE_MEDIA_LIB=$O/libmedia_fake.so FAKE_LOG=$O/calls.log
L=$O/asound/card0/pcm2p/sub0
mkdir -p $L $O/asound/card0/pcm0p/sub0
echo closed > $O/asound/card0/pcm0p/sub0/status
echo closed > $O/asound/card0/pcm0p/sub0/hw_params
link() {  # $1 rate (hw_params) $2 frames/s really taken $3 seconds since start $4 owner
    printf 'access: RW_INTERLEAVED\nformat: S16_LE\nsubformat: STD\nchannels: 2\nrate: %s (%s/1)\nperiod_size: 2048\nbuffer_size: 8192\n' $1 $1 > $L/hw_params
    awk -v f=$2 -v s=$3 -v o=$4 'BEGIN { printf "state: RUNNING\nowner_pid   : %d\ntrigger_time: 100.000000000\ntstamp      : %.9f\ndelay       : 6576\navail       : 1616\navail_max   : 6144\n-----\nhw_ptr      : %d\nappl_ptr    : %d\n", o, 100 + s, f * s, f * s + 6000 }' > $L/status.tmp
    mv $L/status.tmp $L/status
}

echo "== 1. one reading: frames since the link started"
link 44100 44100 81.3 4258
out=$($O/eqe_lab rate 0)
ok "44100 Hz link, 44100 frames/s, owner shown" "[ \"\$out\" = 'link pcm2p card0 state=RUNNING owner=4258 rate=44100 fps=44100.0' ]"

echo "== 2. two readings 300 ms apart (the counter keeps moving)"
link 48000 48000 10 4258
( sleep 0.15; link 48000 48000 10.5 4258 ) &
out=$($O/eqe_lab rate 300); wait
ok "48000 frames/s from the change between readings" "echo \"\$out\" | grep -q 'rate=48000 fps=48000.0\$'"
link 48000 44100 10 4258
( sleep 0.15; link 48000 44100 12 4258 ) &
out=$($O/eqe_lab rate 300); wait
ok "a link set to 48000 that takes 44100 frames/s is reported as such" "echo \"\$out\" | grep -q 'rate=48000 fps=44100.0\$'"

echo "== 3. the link restarted or stopped between readings"
link 44100 44100 50 4258
( sleep 0.15; link 44100 44100 2 4300 ) &
out=$($O/eqe_lab rate 300); wait
ok "new owner: no rate, marked restarted" "echo \"\$out\" | grep -q 'fps=0.0 restarted\$'"
link 44100 44100 50 4258
( sleep 0.15; echo closed > $L/status ) &
out=$($O/eqe_lab rate 300); wait
ok "closed: marked stopped" "echo \"\$out\" | grep -q 'fps=0.0 stopped\$'"
echo closed > $L/status
ok "nothing playing: link none" "[ \"\$($O/eqe_lab rate 100)\" = 'link none' ]"

echo "== 4. Android's settings, through the stand-in libraries"
: > $O/calls.log
out=$($O/eqe_lab set 101 sampling_rate=48000)
ok "set: one call, io and text as given, status printed" "[ \"\$out\" = 'status 0' ] && [ \"\$(cat $O/calls.log)\" = 'set io 101 \"sampling_rate=48000\"' ]"
out=$(FAKE_SET_STATUS=-22 $O/eqe_lab set 101 sampling_rate=48000)
ok "the driver's refusal comes back" "[ \"\$out\" = 'status -22' ]"
out=$($O/eqe_lab get 101 sampling_rate)
ok "get: answer printed" "[ \"\$out\" = 'answer sampling_rate=44100' ]"
: > $O/calls.log
$O/eqe_lab set 101 'sampling_rate=48000;x=$(reboot)' > $O/bad.txt 2>&1; rc=$?
ok "text other than plain key=value is refused, nothing sent" "[ $rc = 2 ] && [ ! -s $O/calls.log ]"
$O/eqe_lab set -5 sampling_rate=48000 > /dev/null 2>&1; rc=$?
ok "a bad io handle is refused" "[ $rc = 2 ] && [ ! -s $O/calls.log ]"
out=$(EQE_MEDIA_LIB=$O/libmedia_noget.so $O/eqe_lab get 101 sampling_rate); rc=$?
ok "a missing Android function: says which, does nothing" "[ $rc = 2 ] && echo \"\$out\" | grep -q 'EQE_LAB_ERR missing _ZN7android11AudioSystem13getParameters'"
out=$(EQE_MEDIA_LIB=$O/nothing.so $O/eqe_lab set 101 sampling_rate=48000); rc=$?
ok "Android's library missing: error, nothing sent" "[ $rc = 2 ] && echo \"\$out\" | grep -q 'EQE_LAB_ERR could not load' && [ ! -s $O/calls.log ]"

echo "== 5. check (for the car report): looks the functions up, calls nothing"
: > $O/calls.log
out=$($O/eqe_lab check); rc=$?
ok "all four found" "[ $rc = 0 ] && [ \"\$out\" = 'symbols 4 of 4' ] && [ ! -s $O/calls.log ]"
out=$(EQE_MEDIA_LIB=$O/libmedia_noget.so $O/eqe_lab check); rc=$?
ok "one missing: named, 3 of 4" "[ $rc = 2 ] && echo \"\$out\" | grep -q 'missing _ZN7android11AudioSystem13getParameters' && echo \"\$out\" | grep -q 'symbols 3 of 4'"

echo "== 6. umount (the driver watch while the audio server still has it open)"
$O/eqe_lab umount /data/local/tmp/x > $O/u.txt 2>&1; rc=$?
ok "a path that is not one of EQ Engine's mounts is refused" "[ $rc = 2 ]"
$O/eqe_lab umount $O/../x/system/lib/hw/audio.primary.tcc803x.so > $O/u.txt 2>&1; rc=$?
ok "a path with .. is refused" "[ $rc = 2 ]"
mkdir -p $O/root/system/lib/hw; touch $O/root/system/lib/hw/audio.primary.tcc803x.so
out=$($O/eqe_lab umount $O/root/system/lib/hw/audio.primary.tcc803x.so); rc=$?
ok "the driver file, not mounted here: tried, the error comes back" "[ $rc = 1 ] && echo \"\$out\" | grep -q '^failed: '"

echo "lab helper: $pass passed, $fail failed"
[ $fail = 0 ]
