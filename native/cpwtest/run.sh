#!/bin/sh
# CarPlay watch tests on the PC: the watch (native/cpwatch.c) loaded in place of libCarPlayAndroid.so
# by a program that calls its JNI_OnLoad as Dalvik does. It loads a stand-in factory library, which
# brings a stand-in libCarPlayAudio.so (linked BIND_NOW and RELRO like the car's, so its import table
# is read-only once loaded) and a stand-in libtinyalsa.so, then the audio library plays. With
# AddressSanitizer and UndefinedBehaviorSanitizer; short windows (300 ms) and ticks (100 ms).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
O=/tmp/eqe_cpwtest
rm -rf $O && mkdir -p $O/lib $O/notes $O/notes2 $O/notes3 $O/notes4 $O/share4 $O/state4 $O/w1 $O/w2 $O/w3 $O/w4 $O/nolib $O/bad
SAN="-fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer"
CF="-std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-sign-compare -fPIC"
NOW="-Wl,-z,now -Wl,-z,relro"
gcc $CF $SAN -shared -o $O/lib/libtinyalsa.so $HERE/fake_tinyalsa.c
gcc $CF $SAN -shared -o $O/lib/libtinyalsa_other.so $HERE/fake_tinyalsa.c
gcc $CF $SAN -shared $NOW -I$HERE/.. -o $O/lib/libCarPlayAudio.so $HERE/fake_cpaudio.c -L$O/lib -ltinyalsa -lm
gcc $CF $SAN -shared $NOW -DNEEDS_AUDIO -Wl,--no-as-needed -o $O/lib/libCarPlayAndroid.car.so $HERE/fake_cpandroid.c -L$O/lib -lCarPlayAudio
gcc $CF $SAN -shared -o $O/bad/libCarPlayAndroid.noaudio.so $HERE/fake_cpandroid.c
# the watch includes the filter (eqengine.c), so the host stand-in for <android/log.h> (tests/) is needed;
# the EQ's control file and "EQ Engine off" file are under $O (none of them there for w1 .. w3)
W="-shared -fvisibility=hidden -DCPW_WINDOW_MS=300 -DCPW_TICK_MS=100 -DCPE_TICK_MS=20 -I$HERE/../../tests"
gcc $CF $SAN $W -DCPW_DIR="\"$O/notes\"" -DCPS_COPY="\"$O/lib/libCarPlayAndroid.car.so\"" \
    -DCPE_CTL="\"$O/share1/cp_eq.bin\"" -DCPE_OFF="\"$O/share1/disabled\"" \
    -o $O/w1/libCarPlayAndroid.so $HERE/../cpwatch.c -ldl -lpthread -lm
gcc $CF $SAN $W -DCPW_DIR="\"$O/notes4\"" -DCPS_COPY="\"$O/lib/libCarPlayAndroid.car.so\"" \
    -DCPE_CTL="\"$O/share4/cp_eq.bin\"" -DCPE_OFF="\"$O/state4/disabled\"" \
    -o $O/w4/libCarPlayAndroid.so $HERE/../cpwatch.c -ldl -lpthread -lm
gcc $CF $SAN $W -DCPW_DIR="\"$O/notes2\"" -DCPS_COPY="\"$O/missing/libCarPlayAndroid.car.so\"" \
    -o $O/w2/libCarPlayAndroid.so $HERE/../cpwatch.c -ldl -lpthread -lm
gcc $CF $SAN $W -DCPW_DIR="\"$O/notes3\"" -DCPS_COPY="\"$O/lib/libCarPlayAndroid.car.so\"" -DCPW_TINYALSA="\"libtinyalsa_other.so\"" \
    -o $O/w3/libCarPlayAndroid.so $HERE/../cpwatch.c -ldl -lpthread -lm
gcc $CF $SAN $W -DCPW_DIR="\"$O/notes2\"" -DCPW_TINYALSA="\"libtinyalsa_none.so\"" \
    -o $O/nolib/libCarPlayAndroid.so $HERE/../cpwatch.c -ldl -lpthread -lm
gcc $CF $SAN -o $O/test_cps $HERE/test_cps.c -ldl
gcc -std=gnu11 -O1 -g -Wall -Wextra -Werror $SAN -o $O/eqe_lab $HERE/../eqe_lab.c -ldl
export ASAN_OPTIONS=detect_leaks=0
export LD_LIBRARY_PATH=$O/lib
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }
COPY=$O/lib/libCarPlayAndroid.car.so

echo "== the watch in place of libCarPlayAndroid.so, the factory library behind it"
$O/test_cps $O/w1/libCarPlayAndroid.so $COPY normal 1.2 || fail=$((fail+1))
PID=$(ls $O/notes | sed -n 's/^cpw_\([0-9]*\)\.log$/\1/p' | head -n1)
L=$O/notes/cpw_$PID.log
S=$O/notes/status.$PID
echo "--- its notes"
cat $L
echo "--- its status"
cat $S
ok "one log and one status file, named by the process" "[ -n '$PID' ] && [ -f $L ] && [ -f $S ] && [ ! -f $S.tmp ]"
ok "the log and status are readable by others (the app runs with umask 077)" "[ \"\$(stat -c %a $L)\" = 644 ] && [ \"\$(stat -c %a $S)\" = 644 ]"
ok "first line: the process, in place of libCarPlayAndroid.so, all 7 of TinyALSA's functions found" "head -n1 $L | grep -q 'EQ Engine CarPlay watch 3 (in place of libCarPlayAndroid.so) in pid $PID (.*test_cps), uid [0-9]*; TinyALSA: 7 of 7 functions\$'"
ok "JNI_OnLoad: loaded, whether HMG-API's hook library is there, the factory library named" "grep -q \"loaded in place of libCarPlayAndroid.so (HMG-API's hook library in this process: no); the factory library: $COPY\" $L"
ok "the factory library's JNI_OnLoad result is noted" "grep -q 'the factory library is loaded; its JNI_OnLoad returned 0x10006 ([0-9.]* ms)' $L"
ok "the audio library's four TinyALSA imports are watched, and its import table is read-only again" "grep -q 'libCarPlayAudio.so: 4 of 4 TinyALSA imports watched (pcm_open pcm_close pcm_write pcm_read), the table read-only again\$' $L"
ok "the stream opened: card, device, direction, rate, channels, format, periods, thresholds, buffer, thread" \
   "grep -q 'open s1: card 0 device 2 out, 44100 Hz 2 ch s16, period 1024 x 4, start 4096 stop 4096 -> ok, buffer 4096 frames, [0-9.]* ms, thread [0-9]* (test_cps)' $L"
FPS=$(sed -n 's/.* s1 [0-9.]* s: [0-9]* writes, \([0-9]*\) frames\/s.*/\1/p' $L | head -n1)
ok "a window: about 44,100 frames/s from a stream that plays at 44.1 kHz (got $FPS)" "[ -n '$FPS' ] && [ $FPS -gt 41000 ] && [ $FPS -lt 47000 ]"
ok "a window: the gaps between writes are about one period (23.2 ms)" "grep -q ' s1 [0-9.]* s: [0-9]* writes, [0-9]* frames/s, gap 2[2-4]\.[0-9] ms avg' $L"
ok "a window: the peak of a half-scale tone is -6.0 dBFS, none at full scale" "grep ' s1 [0-9.]* s: ' $L | head -n1 | grep -q 'peak -6.0 dBFS, 0 at full scale, 0 errors'"
ok "the error is counted, with its reason" "grep -q ' s1 .*(to its close): .* 1 errors (last: Broken pipe)' $L"
ok "the failed open is written down with TinyALSA's reason" "grep -q \"open: card 9 device 0 out, 44100 Hz 2 ch s16, period 1024 x 4 -> failed: cannot open device '/dev/snd/pcmC9D0p': Device or resource busy\" $L"
ok "the input stream: opened, 2 reads, its level measured" "grep -q 'open s2: card 0 device 0 in, 16000 Hz 1 ch s16, period 320 x 4' $L && grep -q ' s2 [0-9.]* s (to its close): 2 reads, .* peak -24.3 dBFS' $L"
ok "each close: how long, calls, frames, errors" "grep -q 'close s1 after 1\.[0-9] s: [0-9]* calls, [0-9]* frames, 1 errors -> 0' $L && grep -q 'close s2 after' $L"
ok "status: the main stream (card 0 device 2) and its last window" "grep -q '^main=s1 card=0 device=2 dir=out rate=44100 ch=2 fmt=s16 period=1024x4 state=closed calls=[0-9]* idle_s=[0-9]* fps=4[0-9]* errs=[01] peak_db=-6.0\$' $S"
ok "status: watching, streams, open, the stream it never saw, the imports, HMG-API" "grep -qx 'state=watching' $S && grep -qx 'streams=2' $S && grep -qx 'open=0' $S && grep -qx 'untracked=1' $S && grep -qx 'imports=4 of 4' $S && grep -qx 'hmgapi=no' $S"
ok "no personal data: only settings, times and levels" "! grep -q -i -e 'name=' -e '@' $L"

ok "no settings from the app: CarPlay's music untouched, and the notes and status say why" "grep -q 'EQ: s1 plays untouched: no settings from the EQ Engine app yet' $L && grep -qx 'eq=idle: no settings from the EQ Engine app yet' $S && grep -qx 'eq_settings=none 0' $S"

echo "== EQ on CarPlay's music (0.7.3): the app's control file, the streams, the live file"
CPE_TEST_CTL=$O/share4/cp_eq.bin CPE_TEST_OFF=$O/state4/disabled CPE_TEST_LIVE=$O/notes4/live.bin \
    $O/test_cps $O/w4/libCarPlayAndroid.so $COPY eq 0 || fail=$((fail+1))
PID=$(ls $O/notes4 | sed -n 's/^cpw_\([0-9]*\)\.log$/\1/p' | head -n1)
L4=$O/notes4/cpw_$PID.log
echo "--- its notes"
cat $L4
ok "the live file: made by the watch, 4096 bytes, readable by the app" "[ \"\$(stat -c %s $O/notes4/live.bin)\" = 4096 ] && [ \"\$(stat -c %a $O/notes4/live.bin)\" = 644 ]"
ok "notes: a processed stream, its rate and settings" "grep -q 'EQ: s[0-9]* through EQ Engine.s filter at 44100 Hz (Easy, preamp 0.0 dB, EQ on, clip guard on)' $L4"
ok "notes: the settings from the app, and the switch" "grep -q 'EQ: on for CarPlay.s music; settings from the app: Easy' $L4 && grep -q 'EQ: EQ on CarPlay is switched off in the app; settings from the app' $L4"
ok "notes: the microphone: dry, then the EQ again" "grep -q 'EQ: s[0-9]* goes dry while the microphone (s[0-9]*) is open: Siri or a call' $L4 && grep -q 'EQ: s[0-9]* gets the EQ again (the microphone closed)' $L4"
ok "notes: each untouched stream with its reason" "grep -q 'plays untouched: EQ on CarPlay is switched off in the app' $L4 && grep -q 'plays untouched: EQ Engine is turned off' $L4 && grep -q 'plays untouched: not CarPlay.s music stream' $L4"
ok "notes: a processed stream's windows have the EQ's time, output peak and clip guard" "grep -q '; EQ [0-9]* us avg (max [0-9]*) per write, out peak -[0-9.]* dBFS, clip guard idle' $L4"
ok "notes: settings that are not valid are not used" "grep -q 'EQ: no settings from the EQ Engine app yet; settings from the app: none' $L4"
ok "notes: past the table's 64 slots, streams keep their own numbers and their notes (closed slots used again)" "grep -q 'open s7[0-9]: card 0 device 2 out' $L4 && grep -q 'EQ: s7[0-9] through EQ Engine.s filter' $L4 && ! grep -q 'not followed' $L4"

echo "== no factory library behind it"
$O/test_cps $O/w2/libCarPlayAndroid.so $O/missing/libCarPlayAndroid.car.so failed 0 || fail=$((fail+1))
PID=$(ls $O/notes2 | sed -n 's/^cpw_\([0-9]*\)\.log$/\1/p' | head -n1)
ok "the log says the factory library did not load, and that CarPlay cannot start; the status says failed" "grep -q 'the factory library did not load (.*): CarPlay cannot start in this start of the app' $O/notes2/cpw_$PID.log && grep -qx 'state=failed' $O/notes2/status.$PID"

echo "== an import that does not hold the TinyALSA the watch hands on to"
$O/test_cps $O/w3/libCarPlayAndroid.so $COPY guarded 0.3 || fail=$((fail+1))
PID=$(ls $O/notes3 | sed -n 's/^cpw_\([0-9]*\)\.log$/\1/p' | head -n1)
ok "each import left alone, said why; not watching, and the music still played (the checks above)" "grep -q 'libCarPlayAudio.so: 0 of 4 TinyALSA imports watched (none), the table read-only again; left alone: pcm_open (it holds 0x[0-9a-f]*, not TinyALSA.s)' $O/notes3/cpw_$PID.log && grep -qx 'state=not watching' $O/notes3/status.$PID && grep -qx 'imports=0 of 4' $O/notes3/status.$PID"

echo "== the check before use (eqe_lab cpcheck <watch> <copy>)"
NB=$(ls $O/notes | wc -l)
out=$($O/eqe_lab cpcheck $O/w1/libCarPlayAndroid.so $COPY); r=$?
ok "the watch loads, finds all 7 functions, and the factory library checks out: '$out'" "[ $r = 0 ] && [ \"\$out\" = 'cpcheck ok the factory library exports JNI_OnLoad and needs libCarPlayAudio.so; TinyALSA: 7 of 7 functions' ]"
ok "the check runs nothing of the factory library (no JNI_OnLoad here: the watch writes no notes)" "[ \"\$(ls $O/notes | wc -l)\" = $NB ]"
set +e
out=$($O/eqe_lab cpcheck $O/nolib/libCarPlayAndroid.so $COPY); r=$?
ok "no TinyALSA to hand on to: refused, says why: '$out'" "[ $r = 1 ] && echo \"\$out\" | grep -q '^cpcheck failed: the factory library exports JNI_OnLoad and needs libCarPlayAudio.so; TinyALSA: 0 of 7 functions, missing: libtinyalsa_none.so did not load'"
out=$($O/eqe_lab cpcheck $O/w1/libCarPlayAndroid.so $O/lib/libtinyalsa.so); r=$?
ok "a copy that is not the JNI library (no JNI_OnLoad): refused: '$out'" "[ $r = 1 ] && echo \"\$out\" | grep -q '^cpcheck failed: the factory library does not export JNI_OnLoad;'"
out=$($O/eqe_lab cpcheck $O/w1/libCarPlayAndroid.so $O/bad/libCarPlayAndroid.noaudio.so); r=$?
ok "a copy that does not need libCarPlayAudio.so: refused: '$out'" "[ $r = 1 ] && echo \"\$out\" | grep -q '^cpcheck failed: the factory library does not need libCarPlayAudio.so;'"
out=$($O/eqe_lab cpcheck $O/w1/libCarPlayAndroid.so $O/missing.so); r=$?
ok "a copy that is not there: refused: '$out'" "[ $r = 1 ] && echo \"\$out\" | grep -q '^cpcheck failed: the factory library cannot be read (No such file or directory)'"
echo "not an ELF file" > $O/bad/text.so
out=$($O/eqe_lab cpcheck $O/w1/libCarPlayAndroid.so $O/bad/text.so); r=$?
ok "a copy that is not an ELF file: refused: '$out'" "[ $r = 1 ] && echo \"\$out\" | grep -q '^cpcheck failed: the factory library is not an ELF file'"
out=$($O/eqe_lab cpcheck $O/lib/libtinyalsa.so $COPY); r=$?
ok "a library that is not the watch: refused: '$out'" "[ $r = 1 ] && [ \"\$out\" = 'cpcheck failed: it is not the CarPlay watch (no eqe_cpw_check)' ]"
out=$($O/eqe_lab cpcheck $O/missing.so $COPY); r=$?
ok "a watch file that is not there: refused" "[ $r = 1 ] && echo \"\$out\" | grep -q '^cpcheck failed: it does not load'"
out=$($O/eqe_lab cpcheck relative.so $COPY 2>&1); r=$?
ok "a relative path: usage" "[ $r = 2 ]"
out=$($O/eqe_lab cpcheck $O/w1/libCarPlayAndroid.so 2>&1); r=$?
ok "the copy left out: usage" "[ $r = 2 ]"
set -e

echo "$pass passed, $fail failed"
[ $fail = 0 ]
