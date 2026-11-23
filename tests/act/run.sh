#!/bin/bash
# Simulated head unit for "act.sh restart". Usage: run.sh <shell>
SH=${1:-dash}
R=$(cd "$(dirname "$0")/../.." && pwd)
ACT=$R/pkg/bin/act.sh
T=/tmp/eqeact
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; cat $T/out.txt | sed 's/^/       | /'; fi; }

# A healthy audioflinger dump: Android Auto (pid 987) playing music at 48 kHz.
dump_playing() {
cat <<'D'
Output thread 0xb5b34008 tracks
   Name Client Type      Fmt Chn mask Session fCount S F SRate  L dB  R dB    Server Main buf  Aux Buf Flags UndFrmCnt
      3    987    3 00000001 00000003      21   8916 A 3 48000     0     0  0096B43E B74A1940 00000000 0x401     84774
      1    953    3 00000001 00000001     111   8192 I 0 22050     0     0  00000000 B74A1940 00000000 0x000         0
Output thread 0xb5b34008 active tracks
   Name Client Type      Fmt Chn mask Session fCount S F SRate  L dB  R dB    Server Main buf  Aux Buf Flags UndFrmCnt
      3    987    3 00000001 00000003      21   8916 A 3 48000     0     0  0096B43E B74A1940 00000000 0x401     84774
Normal mixer raw underrun counters: partial=0 empty=0
Output thread 0xb59bf008 active tracks
   Name Client Type      Fmt Chn mask Session fCount S F SRate  L dB  R dB    Server Main buf  Aux Buf Flags UndFrmCnt
Normal mixer raw underrun counters: partial=0 empty=0
D
}
# What the car showed at 19:29:38: the stream recreated but idle.
dump_stuck() {
cat <<'D'
Output thread 0xb5ad5008 tracks
   Name Client Type      Fmt Chn mask Session fCount S F SRate  L dB  R dB    Server Main buf  Aux Buf Flags UndFrmCnt
      0    987    3 00000001 00000003      21   8916 I 0 48000     0     0  00000000 B7220940 00000000 0x000         0
Output thread 0xb5ad5008 active tracks
   Name Client Type      Fmt Chn mask Session fCount S F SRate  L dB  R dB    Server Main buf  Aux Buf Flags UndFrmCnt
Normal mixer raw underrun counters: partial=0 empty=0
D
}

setup() {
    rm -rf $T; mkdir -p $T/data/eqengine/state $T/proc $T/stubs $T/props
    # the car has no printf: neither its mksh nor its toolbox (0.6.11's curves load failed on it).
    # dash and bash have their own, so this stands in for the car under mksh only.
    printf '#!/bin/sh\necho "printf: not found" >&2\nexit 127\n' > $T/stubs/printf
    chmod +x $T/stubs/printf
    echo "700.25 50.00" > $T/proc/uptime
    echo 5056 > $T/mspid; mkdir -p $T/proc/5056 $T/proc/987
    : > $T/as.log
    echo "11-18 19:28:00.850 E/AudioService(  654): Media server started." >> $T/as.log
    echo playing > $T/after   # what the dump shows after the restart: playing | stuck | none
    echo playing > $T/now
    echo 1 > $T/reconnects    # 1 = AudioService logs "Media server started." after a restart
    cat > $T/stubs/ps <<'S'
#!/bin/sh
echo "USER     PID   PPID  VSIZE  RSS     WCHAN    PC         NAME"
echo "root      1     0     1000   500   ffffffff 00000000 S /init"
p=$(cat /tmp/eqeact/mspid); [ -d /tmp/eqeact/proc/$p ] && echo "media     $p   1     33148  9784  ffffffff b6ea0870 S /system/bin/mediaserver"
echo "system    987   165   979824 114648 ffffffff 4010fa40 S com.google.android.projection.sink"
echo "u0_a41    2290  165   612000 80000 ffffffff 4010fa40 S com.daudio.app.dipo"
i=0; while [ $i -lt 40 ]; do echo "u0_a$i     $((3000 + i))  165   1000 100 ffffffff 4010fa40 S app.number.$i"; i=$((i+1)); done
exit 0
S
    cat > $T/stubs/kill <<'S'
#!/bin/sh
[ "$1" = "-9" ] && shift
echo "kill $1" >> /tmp/eqeact/kill.log
p=$(cat /tmp/eqeact/mspid)
if [ "$1" = "$p" ]; then
    rm -rf /tmp/eqeact/proc/$p
    n=$((p + 100)); mkdir -p /tmp/eqeact/proc/$n; echo $n > /tmp/eqeact/mspid
    # like the EQ Engine filter: tables loaded at the new server's start only if the marker is there
    [ -f /tmp/eqeact/maps_tables ] && [ -f /tmp/eqeact/data/eqengine/state/vhq_load ] && \
        echo "b6a00000-b6a2a000 r-xp 00000000 b3:19 4242   /data/eqengine/lib/libaudio-resampler.so" > /tmp/eqeact/proc/$n/maps
    cp /tmp/eqeact/after /tmp/eqeact/now
    [ "$(cat /tmp/eqeact/reconnects)" = 1 ] && echo "11-18 19:28:39.850 E/AudioService(  654): Media server started. ($n)" >> /tmp/eqeact/as.log
    /tmp/eqeact/stubs/server_start $n
fi
exit 0
S
    # what a new audio server finds at its start: the policy's 44100, and the driver watch if it is mounted
    cat > $T/stubs/server_start <<'S'
#!/bin/sh
T=/tmp/eqeact; n=$1
echo "44100 44100" > $T/rates
if grep -q " $T/system/lib/hw/audio.primary.tcc803x.so " $T/proc/mounts 2>/dev/null; then
    echo "b6b00000-b6b20000 r-xp 00000000 b3:19 99   /data/eqengine/lib/hal/eqe_hal_orig.so" >> $T/proc/$n/maps
    mkdir -p $T/data/eqengine/drv; printf 'version=1\nstate=watching\n' > $T/data/eqengine/drv/status
fi
exit 0
S
    cat > $T/stubs/sleep <<'S'
#!/bin/sh
read u r < /tmp/eqeact/proc/uptime; u=${u%%.*}; echo "$((u + $1)).10 50.00" > /tmp/eqeact/proc/uptime
T=/tmp/eqeact
[ -d $T/data/eqengine/state/hold ] && /bin/sleep 0.03
# music that starts a moment after a switch made while nothing played (start_after_set)
if [ -f $T/start_in ]; then
    n=$(($(cat $T/start_in) - 1))
    if [ $n -le 0 ]; then rm -f $T/start_in; touch $T/playing; $T/stubs/asound; else echo $n > $T/start_in; fi
fi
# another process (the factory CarPlay app, thread 2291) has the main link from <from> to <until>
# (other_at: "<from> <until>"); other_stops_music: Android's music stops when it takes the link;
# other_then_play: Android's music plays again when it lets go
if [ -f $T/other_at ]; then
    read f2 u2 < $T/other_at; now=$((u + $1))
    if [ ! -f $T/other ] && [ $now -ge $f2 ] && [ $now -lt $u2 ]; then
        echo 2291 > $T/other; [ -f $T/other_stops_music ] && rm -f $T/playing; $T/stubs/asound
    fi
    if [ $now -ge $u2 ]; then
        rm -f $T/other $T/other_at; [ -f $T/other_then_play ] && { rm -f $T/other_then_play; touch $T/playing; }; $T/stubs/asound
    fi
fi
if [ -f $T/crash_at ] && [ $((u + $1)) -ge $(cat $T/crash_at) ]; then
    rm -f $T/crash_at
    # init starts a new audio server
    p=$(cat $T/mspid); rm -rf $T/proc/$p; n=$((p + 1)); mkdir -p $T/proc/$n; echo $n > $T/mspid
    echo "crash $p" >> $T/crash.log
    $T/stubs/server_start $n
fi
exit 0
S
    cat > $T/stubs/setprop <<'S'
#!/bin/sh
echo "$1=$2" >> /tmp/eqeact/setprop.log
echo "$2" > /tmp/eqeact/prop
S
    echo 3 > $T/prop
    cat > $T/stubs/getprop <<'S'
#!/bin/sh
cat /tmp/eqeact/prop
S
    cat > $T/stubs/md5 <<'S'
#!/bin/sh
md5sum "$1"
S
    cat > $T/stubs/service <<'S'
#!/bin/sh
# "service check media.audio_flinger": found while an audio server process exists
p=$(cat /tmp/eqeact/mspid)
if [ -d /tmp/eqeact/proc/$p ]; then echo "Service $2: found"; else echo "Service $2: not found"; fi
S
    cat > $T/stubs/logcat <<'S'
#!/bin/sh
case "$*" in
    *AudioService*) cat /tmp/eqeact/as.log ;;
    *audio_hw_primary*) cat /tmp/eqeact/hal.log 2>/dev/null ;;
    *AudioResampler*)
        case "$*" in
            *AudioResampler:D*) echo "11-18 19:28:01.120 D/AudioResampler( 5156): forcing AudioResampler quality to 3" ;;
        esac
        [ -f /tmp/eqeact/sinc_missed ] && echo "11-18 19:28:01.110 E/AudioResamplerSinc( $(cat /tmp/eqeact/mspid)): Could not open audio-resampler library: dlopen failed: library \"libaudio-resampler.so\" not found"
        ;;
esac
exit 0
S
    chmod +x $T/stubs/*
    rm -f $T/setprop.log $T/kill.log $T/sinc_missed $T/maps_tables
}
vhqsetup() {  # $1 = good | bad tables checksum; $2 = map (the new audio server maps the tables) | nomap
    mkdir -p $T/data/eqengine/lib $T/data/eqengine/conf
    echo tables > $T/data/eqengine/lib/libaudio-resampler.so
    md5sum < $T/data/eqengine/lib/libaudio-resampler.so | cut -c1-32 > $T/data/eqengine/conf/libaudio-resampler.md5
    [ "$1" = bad ] && echo changed >> $T/data/eqengine/lib/libaudio-resampler.so
    [ "$2" = map ] && touch $T/maps_tables
    return 0
}
mkdumps() {
    dump_playing > $T/dump_playing.txt; dump_stuck > $T/dump_stuck.txt
    cat > $T/stubs/dumpsys <<'S'
#!/bin/sh
# one "internals" block per output thread (io handles 101, 102, ...; the main output first), then the tracks
i=0
for r in $(cat /tmp/eqeact/rates 2>/dev/null || echo 44100); do
    i=$((i + 1))
    printf 'Output thread 0xb5ae300%d internals\nNormal frame count: 2048\nio handle: %d\nTID: %d\nstandby: 0\nSample rate: %s\nHAL frame count: 2048\n' $i $((100 + i)) $((4257 + i)) $r
    echo "Output thread 0xb5ae300$i stream volumes in dB:"
done
f=/tmp/eqeact/dump_$(cat /tmp/eqeact/now).txt
[ -f "$f" ] && cat "$f"
exit 0
S
    chmod +x $T/stubs/dumpsys
}
run() {
    ( cd /; EQE_TEST_ROOT=$T EQE_APP_PROCESS=$T/stubs/app_process PATH=$T/stubs:/usr/bin:/bin timeout 30 $SH $ACT "$@" > $T/out.txt 2>&1; echo $? > $T/rc )
}
rc() { cat $T/rc; }

echo "== act.sh restart under $SH"

setup; mkdumps; run restart 3
ok "normal restart succeeds" "[ $(rc) = 0 ] && grep -q EQE_OK $T/out.txt"
ok "it reports Android reconnecting" "grep -q 'Android reconnected' $T/out.txt"
ok "the converter is set before the audio server is stopped" "[ \"\$(cat $T/setprop.log)\" = 'af.resampler.quality=3' ]"
ok "nothing is reported stuck when the stream plays again" "! grep -q EQE_STUCK $T/out.txt"
ok "the lock is released" "[ ! -d $T/data/eqengine/state/restart.lock ]"
ok "the restart time is recorded" "[ -f $T/data/eqengine/state/last_restart ] && [ -f $T/data/eqengine/state/expected_restart ]"
ok "the converter lines are written for the app" "grep -q 'quality to 3' $T/data/eqengine/state/resampler_now.log"

# a second restart right away is refused, and changes nothing
rm -f $T/setprop.log $T/kill.log
run restart 0
ok "a restart within 10 s is refused" "[ $(rc) = 3 ] && grep -q EQE_WAIT $T/out.txt && grep -q 'Wait [0-9]* s' $T/out.txt"
ok "the refused restart sets nothing and stops nothing" "[ ! -f $T/setprop.log ] && [ ! -f $T/kill.log ]"
ok "the refused restart leaves no lock behind" "[ ! -d $T/data/eqengine/state/restart.lock ]"
echo "$(( $(cut -d. -f1 $T/proc/uptime) + 9 )).00 50.00" > $T/proc/uptime
run restart 0
ok "still refused after 9 s" "[ $(rc) = 3 ] && grep -q 'Wait 1 s' $T/out.txt"
echo "$(( $(cut -d. -f1 $T/proc/uptime) + 2 )).00 50.00" > $T/proc/uptime
run restart 0
ok "after 10 s it is allowed again" "[ $(rc) = 0 ] && grep -q EQE_OK $T/out.txt && grep -q 'quality=0' $T/setprop.log"

setup; mkdumps
mkdir -p $T/data/eqengine/state/restart.lock $T/proc/4242
echo "4242 690" > $T/data/eqengine/state/restart.lock/info
run restart 3
ok "a restart already running (live lock) is refused" "[ $(rc) = 3 ] && grep -q 'already restarting' $T/out.txt && [ ! -f $T/setprop.log ]"
ok "the other restart's lock is left alone" "[ -d $T/data/eqengine/state/restart.lock ]"
rm -rf $T/proc/4242
run restart 3
ok "a lock left by an interrupted restart is cleared" "[ $(rc) = 0 ] && grep -q EQE_OK $T/out.txt && [ ! -d $T/data/eqengine/state/restart.lock ]"

setup; mkdumps; echo stuck > $T/after
run restart 3
ok "a stream that stays idle is reported (Android Auto)" "grep -q 'EQE_STUCK com.google.android.projection.sink' $T/out.txt && grep -q EQE_OK $T/out.txt"

setup; mkdumps; echo none > $T/now; echo none > $T/after
run restart 3
ok "nothing playing before: nothing reported" "[ $(rc) = 0 ] && ! grep -q EQE_STUCK $T/out.txt"

setup; mkdumps; echo 0 > $T/reconnects
run restart
ok "no reconnect message: waits, then says so" "[ $(rc) = 0 ] && grep -q 'did not report reconnecting within 25 s' $T/out.txt"
ok "a plain restart does not touch the converter" "[ ! -f $T/setprop.log ]"

setup; mkdumps
run restart 7
ok "an unknown converter value is rejected" "[ $(rc) = 2 ] && [ ! -f $T/setprop.log ] && [ ! -f $T/kill.log ]"

setup; mkdumps; rm -rf $T/proc/5056
run restart 3
ok "no audio server found: nothing set, lock released" "[ $(rc) = 1 ] && [ ! -f $T/setprop.log ] && [ ! -d $T/data/eqengine/state/restart.lock ]"

echo "== very high quality (restart 4) under $SH"
VS=$T/data/eqengine/state
setup; mkdumps; vhqsetup good map
run restart 4
ok "restart 4: succeeds, sets 4, leaves the marker" "[ $(rc) = 0 ] && grep -q EQE_OK $T/out.txt && [ \"\$(cat $T/setprop.log)\" = af.resampler.quality=4 ] && [ -f $VS/vhq_load ]"
ok "reports the tables loaded" "grep -q 'EQE_VHQ loaded' $T/out.txt"
ok "the marker is readable by the audio server" "[ \"\$(stat -c %a $VS/vhq_load)\" = 644 ]"

setup; mkdumps; vhqsetup good nomap
run restart 4
ok "tables not mapped after the restart: says so" "[ $(rc) = 0 ] && grep -q 'EQE_VHQ not-loaded' $T/out.txt"

setup; mkdumps; vhqsetup good map; touch $T/sinc_missed
run restart 4
ok "Android set up its converter first: reported as missed" "[ $(rc) = 0 ] && grep -q 'EQE_VHQ missed' $T/out.txt"

setup; mkdumps; vhqsetup bad map
run restart 4
ok "tables fail their check: refused before anything changes" "[ $(rc) = 1 ] && grep -q 'failed their check' $T/out.txt && [ ! -f $T/setprop.log ] && [ ! -f $T/kill.log ] && [ ! -f $VS/vhq_load ]"
ok "refused restart leaves no lock" "[ ! -d $VS/restart.lock ]"

setup; mkdumps; vhqsetup good map; echo 1 > $VS/vhq_load
run restart 3
ok "restart 3 removes the marker first (the new server loads no tables); no EQE_VHQ" "[ $(rc) = 0 ] && [ ! -f $VS/vhq_load ] && [ ! -f $T/proc/5156/maps ] && ! grep -q EQE_VHQ $T/out.txt"
setup; mkdumps; vhqsetup good map; echo 1 > $VS/vhq_load
run restart 0
ok "restart 0 (comparison) removes the marker too" "[ $(rc) = 0 ] && [ ! -f $VS/vhq_load ] && grep -q 'quality=0' $T/setprop.log"
setup; mkdumps; vhqsetup good map; echo 1 > $VS/vhq_load
run restart
ok "a plain restart keeps the marker; the new server has the tables" "[ $(rc) = 0 ] && [ -f $VS/vhq_load ] && grep -q 'EQE_VHQ loaded' $T/out.txt && [ ! -f $T/setprop.log ]"

echo "== Lab driver watch, the 48 kHz keeper and the car report under $SH"
CAR=${EQE_CAR:-$R/car-files}
labsetup() {  # a unit with Hyundai's driver, EQ Engine's watch layer and Lab helper, Android Auto playing
    setup; mkdumps
    mkdir -p $T/system/lib/hw $T/system/etc $T/data/eqengine/lib $T/data/eqengine/conf $T/data/eqengine/bin $T/data/eqengine/settings
    cp $CAR/audio.primary.tcc803x.so $T/system/lib/hw/
    echo "watch layer" > $T/data/eqengine/lib/eqe_drvwatch.so
    md5sum < $T/data/eqengine/lib/eqe_drvwatch.so | cut -c1-32 > $T/data/eqengine/conf/eqe_drvwatch.md5
    echo "/dev/block/system /system ext4 ro 0 0" > $T/proc/mounts
    rm -f $T/crash_at $T/crash.log $T/lab_calls.log $T/hal.log $T/hold.log $T/set_times.log $T/umount.log
    mkdir -p $T/proc/5056/task/4258 $T/proc/4258 $T/data/app
    printf 'Name:\tmediaserver\nTgid:\t5056\n' > $T/proc/4258/status
    echo "b6c00000-b6c06000 r-xp 00000000 b3:19 4243   /data/eqengine/lib/libeqengine.so" > $T/proc/5056/maps
    rm -f $T/waking $T/wake_fail $T/newtrack $T/hold_fail_once $T/hold_fail_after $T/start_in $T/rate_none
    rm -f $T/other $T/other_at $T/other_stops_music $T/other_then_play $T/other_on_wake $T/imports.log
    # the factory CarPlay app (pid 2290; thread 2291 plays to the main link when "other" is set),
    # with the libraries it has mapped
    mkdir -p $T/proc/2290 $T/proc/2291 $T/system/lib
    printf 'com.daudio.app.dipo\0\0\0\0' > $T/proc/2290/cmdline
    printf 'Name:\tAudioTrack\nTgid:\t2290\n' > $T/proc/2291/status
    cat > $T/proc/2290/maps <<'M'
b6f00000-b6f40000 r-xp 00000000 b3:19 100        /system/lib/libc.so
b6f40000-b6f41000 rw-p 00040000 b3:19 100        /system/lib/libc.so
b5000000-b5040000 r-xp 00000000 b3:19 200        /system/lib/libCarPlayAudio.so
b4000000-b4010000 r-xp 00000000 b3:19 300        /data/hmgapi/lib/libleafiaaac.so
b3000000-b3010000 r-xp 00000000 b3:19 400        /system/lib/libbroken.so
b2000000-b2001000 rw-p 00000000 00:00 0          [anon:libc_malloc]
b1000000-b1100000 r--p 00000000 b3:19 500        /system/framework/framework.jar
M
    echo "factory tinyalsa" > $T/system/lib/libtinyalsa.so
    # the CarPlay code and config files the probe reads texts and checksums from
    echo "factory carplay audio" > $T/system/lib/libCarPlayAudio.so
    mkdir -p $T/system/app; echo "dipo code" > $T/system/app/DiPO.odex; echo "other code" > $T/system/app/Other.odex
    printf 'audio_out=tinyalsa\nlatency=40\n' > $T/system/etc/dipo_audio.conf; echo x > $T/system/etc/unrelated.conf
    rm -f $T/strings.log
    # the system log's clock (the driver's lines are read from the time of a switch on)
    cat > $T/stubs/date <<'S'
#!/bin/sh
case "$1" in
    +%H%M%S) cat /tmp/eqeact/clock 2>/dev/null || echo 180045 ;;
    *) exec /bin/date "$@" ;;
esac
S
    echo "EQ Engine's package" > $T/data/app/com.eqengine.app-1.apk
    echo "44100 44100" > $T/rates
    echo 44100 > $T/link_rate; echo 44100 > $T/link_fps; touch $T/playing
    echo accept > $T/driver48   # how the simulated driver takes sampling_rate=48000: accept | keep | convert | mismatch | crash | sticky
    # the kernel's files for the main link (pcm2p, played by the main output's thread 4258)
    cat > $T/stubs/asound <<'S'
#!/bin/sh
T=/tmp/eqeact; d=$T/proc/asound/card0/pcm2p/sub0; mkdir -p $d $T/proc/asound/card0/pcm0p/sub0
echo closed > $T/proc/asound/card0/pcm0p/sub0/status
if [ -f $T/other ]; then
    # the factory CarPlay app has the link (TinyALSA, 44.1 kHz, 1024-frame periods)
    printf 'state: RUNNING\nowner_pid   : %s\ntrigger_time: 300.000000000\ntstamp      : 310.000000000\n-----\nhw_ptr      : 441000\n' "$(cat $T/other)" > $d/status
    printf 'access: RW_INTERLEAVED\nformat: S16_LE\nchannels: 2\nrate: 44100 (44100/1)\nperiod_size: 1024\n' > $d/hw_params
elif [ -f $T/playing ] || [ -f $T/waking ]; then
    printf 'state: RUNNING\nowner_pid   : %s\ntrigger_time: 230.252515234\ntstamp      : 278.920789965\n-----\nhw_ptr      : 2336064\n' "$(cat $T/owner 2>/dev/null || echo 4258)" > $d/status
    printf 'access: RW_INTERLEAVED\nformat: S16_LE\nchannels: 2\nrate: %s (%s/1)\nperiod_size: 2048\n' $(cat $T/link_rate) $(cat $T/link_rate) > $d/hw_params
else
    echo closed > $d/status; echo closed > $d/hw_params
fi
S
    cat > $T/stubs/mount <<'S'
#!/bin/sh
# mount -o bind SRC DST
[ "$1" = "-o" ] && [ "$2" = "bind" ] || exit 1
cp "$4" "$4.under" && cp "$3" "$4" && echo "none $4 none rw 0 0" >> /tmp/eqeact/proc/mounts
S
    cat > $T/stubs/umount <<'S'
#!/bin/sh
grep -q " $1 " /tmp/eqeact/proc/mounts || exit 1
# the audio server has the file loaded
[ -f /tmp/eqeact/busy ] && { echo "failed: Device or resource busy" >&2; exit 1; }
cp "$1.under" "$1" && rm -f "$1.under"
grep -v " $1 " /tmp/eqeact/proc/mounts > /tmp/eqeact/proc/mounts.n; mv /tmp/eqeact/proc/mounts.n /tmp/eqeact/proc/mounts
S
    # eqe_lab: link rates from the simulated kernel, sampling_rate through the simulated mixer and driver
    cat > $T/data/eqengine/bin/eqe_lab <<'S'
#!/bin/sh
T=/tmp/eqeact
hal() { echo "11-19 18:00:45.210 D/audio_hw_primary( $(cat $T/mspid)): $1" >> $T/hal.log; }
case "$1" in
check) echo "symbols 4 of 4" ;;
umount)
    echo "umount $2" >> $T/umount.log
    grep -q " $2 " $T/proc/mounts || { echo "failed: Invalid argument"; exit 1; }
    cp "$2.under" "$2" && rm -f "$2.under"
    grep -v " $2 " $T/proc/mounts > $T/proc/mounts.n; mv $T/proc/mounts.n $T/proc/mounts
    echo "detached $2" ;;
rate)
    # rate_none: that many counts get nothing (the link stopped during the count)
    if [ -f $T/rate_none ] && [ "$(cat $T/rate_none)" -gt 0 ]; then
        echo $(($(cat $T/rate_none) - 1)) > $T/rate_none
        echo "link none"; exit 0
    fi
    if [ -f $T/other ]; then
        echo "link pcm2p card0 state=RUNNING owner=$(cat $T/other) rate=44100 fps=44100.0"
    elif [ -f $T/playing ] || [ -f $T/waking ]; then
        echo "link pcm2p card0 state=RUNNING owner=$(cat $T/owner 2>/dev/null || echo 4258) rate=$(cat $T/link_rate) fps=$(cat $T/link_fps).0"
    else echo "link none"; fi ;;
imports)
    # stand-ins for the CarPlay app's libraries (the real reader is tested in tests/lab)
    echo "imports $2" >> $T/imports.log
    case "$2" in
        */libCarPlayAudio.so) printf 'needed libc.so\nneeded libtinyalsa.so\nneeded libCarPlayUtils.so\nimport malloc\nimport pcm_open\nimport pcm_writei\nimport mixer_open\nimport mixer_get_ctl_by_name\nexport CarPlayAudioStart\nimport _ZN7android10AudioTrackC1Ev\nimport _ZN7android11AudioSystem13getParametersEiRKNS_7String8E\nexport TccCarPlayAudioTinyALSA_Open\nexport TccCarPlayAudioTrack_Write\n' ;;
        */libtinyalsa.so) printf 'needed libc.so\nimport ioctl\nexport pcm_open\nexport pcm_writei\nexport mixer_open\nexport mixer_ctl_get_name\n' ;;
        */libbroken.so) echo "EQE_LAB_ERR imports: unexpected program header size"; exit 1 ;;
        */libc.so) printf 'import __stack_chk_guard\nexport malloc\nexport pcm_fake_export\nimport _ZN7android10AudioTrackC1Ev\nexport tinyalsa_like_export\n' ;;
        *) printf 'needed libc.so\nimport memcpy\n' ;;
    esac ;;
strings)
    # stand-ins for the texts in the CarPlay code (the real scanner is tested in tests/lab)
    echo "strings $2" >> $T/strings.log
    case "$2" in
        */libCarPlayAudio.so) printf 'string persist.dipo.audio.output\nstring [TccCarPlayAudioTinyALSA] Main audio setting up PCM/%%d/%%d/%%d for %%s\n' ;;
        */DiPO.odex) printf 'string /system/etc/dipo_audio.conf\nstring-limit 3 more not printed\n' ;;
    esac ;;
set)
    echo "set $2 $3" >> $T/lab_calls.log
    echo "$(cut -d. -f1 $T/proc/uptime) $3" >> $T/set_times.log
    m=$(cat $T/driver48)
    # Hyundai's driver (0.6.3 on the car): sent while its stream is in standby, the rate reaches
    # Android but not the link, which starts at the old rate later ("diff outdevice", no standby)
    if [ ! -f $T/playing ] && [ ! -f $T/waking ] && [ "$m" != keep ] && [ "$m" != crash ]; then
        m=standby
        echo "standby $3" >> $T/standby_sets.log
    fi
    case "$3" in
    sampling_rate=48000)
        case "$m" in
        standby) hal "diff outdevice b738f8c0 0"; echo "48000 44100" > $T/rates; echo "status 0" ;;
        accept|sticky) hal "start_output_stream(0/2), channel(2), samplerate(48000), pcm(0xb7695898)"; echo "48000 44100" > $T/rates; echo 48000 > $T/link_rate; echo 48000 > $T/link_fps; echo "status 0" ;;
        keep) hal "Set sampling_rate error, out->pcm_config->rate (44100)"; echo "status -22" ;;
        convert) echo "48000 44100" > $T/rates; echo "status 0" ;;
        mismatch) hal "start_output_stream(0/2), channel(2), samplerate(48000), pcm(0xb7695898)"; echo 48000 > $T/link_rate; echo 48000 > $T/link_fps; echo "status 0" ;;
        # everyone says 48000, but the link is still clocked at 44.1 kHz (wrong speed)
        slowclock) hal "start_output_stream(0/2), channel(2), samplerate(48000), pcm(0xb7695898)"; echo "48000 44100" > $T/rates; echo 48000 > $T/link_rate; echo 44100 > $T/link_fps; echo "status 0" ;;
        crash) p=$(cat $T/mspid); rm -rf $T/proc/$p; n=$((p + 1)); mkdir -p $T/proc/$n/task/4258; echo $n > $T/mspid; echo "44100 44100" > $T/rates; echo 44100 > $T/link_rate; $T/stubs/afsim reset; echo "status -32" ;;
        esac ;;
    sampling_rate=44100)
        if [ "$m" = standby ]; then
            hal "diff outdevice b738f8c0 0"; echo "44100 44100" > $T/rates
        elif [ "$m" != sticky ]; then
            hal "start_output_stream(0/2), channel(2), samplerate(44100), pcm(0xb7695898)"; echo "44100 44100" > $T/rates; echo 44100 > $T/link_rate; echo 44100 > $T/link_fps
        fi
        echo "status 0" ;;
    esac
    # Android 4.4 rebuilds the output whenever the driver answered 0: a new mix buffer
    [ "$m" != keep ] && [ "$m" != crash ] && $T/stubs/afsim reconfig
    # music that starts right after a switch made while nothing played
    [ -f $T/start_after_set ] && { rm -f $T/start_after_set; echo 2 > $T/start_in; }
    $T/stubs/asound ;;
esac
exit 0
S
    # an audio restart (kill) brings back the policy's 44100
    cat > $T/stubs/server_start <<'S'
#!/bin/sh
T=/tmp/eqeact; n=$1
mkdir -p $T/proc/$n/task/4258
echo "b6c00000-b6c06000 r-xp 00000000 b3:19 4243   /data/eqengine/lib/libeqengine.so" >> $T/proc/$n/maps
echo "44100 44100" > $T/rates; echo 44100 > $T/link_rate; echo 44100 > $T/link_fps
$T/stubs/afsim reset
$T/stubs/asound
if grep -q " $T/system/lib/hw/audio.primary.tcc803x.so " $T/proc/mounts 2>/dev/null; then
    echo "b6b00000-b6b20000 r-xp 00000000 b3:19 99   /data/eqengine/lib/hal/eqe_hal_orig.so" >> $T/proc/$n/maps
    mkdir -p $T/data/eqengine/drv; printf 'version=3\nstate=watching\n' > $T/data/eqengine/drv/status
fi
exit 0
S
    # Android 4.4's main output (io 101) as far as buffers go: its mix buffer, its tracks and the
    # buffer each is mixed into, and effect chains. A rate change allocates a new mix buffer (at
    # the same address only with af/lucky); tracks follow only if their session has a chain.
    cat > $T/stubs/afsim <<'S'
#!/bin/sh
T=/tmp/eqeact; A=$T/af
mkdir -p $A; touch $A/chains $A/tracks
newbuf() { n=$(cat $A/next 2>/dev/null || echo 3087007744); echo $((n + 65536)) > $A/next; printf '%X' $n; }
repoint() {  # tracks of sessions with a chain play into the chain's buffer
    : > $A/tracks.n
    while read n c s b; do
        nb=$b
        while read cs cb; do [ "$cs" = "$s" ] && nb=$cb; done < $A/chains
        echo "$n $c $s $nb" >> $A/tracks.n
    done < $A/tracks
    mv $A/tracks.n $A/tracks
}
case "$1" in
reset)
    m=$(newbuf); echo $m > $A/mix; : > $A/chains
    printf '0 166 13 %s\n1 1114 107 %s\n2 987 21 %s\n3 972 111 %s\n' $m $m $m $m > $A/tracks ;;
reconfig)
    [ -f $A/lucky ] || newbuf > $A/mix
    : > $A/chains.n
    while read s b; do echo "$s $(newbuf)" >> $A/chains.n; done < $A/chains
    mv $A/chains.n $A/chains
    repoint ;;
hold)
    shift
    for s in "$@"; do grep -q "^$s " $A/chains || echo "$s $(newbuf)" >> $A/chains; done
    repoint ;;
release)
    shift; m=$(cat $A/mix)
    for s in "$@"; do
        grep -v "^$s " $A/chains > $A/chains.n; mv $A/chains.n $A/chains
        : > $A/tracks.n
        while read n c ts b; do [ "$ts" = "$s" ] && b=$m; echo "$n $c $ts $b" >> $A/tracks.n; done < $A/tracks
        mv $A/tracks.n $A/tracks
    done ;;
dump)
    i=0; m=$(cat $A/mix)
    for r in $(cat $T/rates 2>/dev/null || echo 44100); do
        i=$((i + 1))
        mb=$m; [ $i = 1 ] || mb=B7F00000
        printf 'Output thread 0xb5ae300%d internals\nNormal frame count: 2048\nmix buffer : 0x%s\nio handle: %d\nTID: %d\nstandby: 0\nSample rate: %s\nHAL frame count: 2048\n' \
            $i "$(echo $mb | tr A-F a-f)" $((100 + i)) $((4257 + i)) $r
        printf 'Pending setParameters commands: \n Index Command\n\nOutput thread 0xb5ae300%d stream volumes in dB:\n    0:0, 1:-6, 2:0\n' $i
        echo "Output thread 0xb5ae300$i tracks"
        echo "   Name Client Type      Fmt Chn mask Session fCount S F SRate  L dB  R dB    Server Main buf  Aux Buf Flags UndFrmCnt"
        if [ $i = 1 ]; then
            while read n c s b; do
                st=I; [ "$s" = 21 ] && [ -f $T/playing ] && st=A
                printf '%7s %6s    3 00000001 00000003 %7s   8916 %s 3 48000     0     0  0096B43E %s 00000000 0x000         0 \n' $n $c $s $st $b
            done < $A/tracks
        fi
        echo "Output thread 0xb5ae300$i active tracks"
        echo "   Name Client Type      Fmt Chn mask Session fCount S F SRate  L dB  R dB    Server Main buf  Aux Buf Flags UndFrmCnt"
        if [ $i = 1 ] && [ -f $T/playing ]; then
            while read n c s b; do
                [ "$s" = 21 ] && printf '%7s %6s    3 00000001 00000003 %7s   8916 A 3 48000     0     0  0096B43E %s 00000000 0x000         0 \n' $n $c $s $b
            done < $A/tracks
        fi
        echo "Normal mixer raw underrun counters: partial=0 empty=0"
        echo
        if [ $i = 1 ]; then
            echo "- $((1 + $(wc -l < $A/chains))) Effect Chains:"
            while read s b; do
                printf 'Effects for session %s:\n\tNum fx In buffer   Out buffer   Active tracks:\n\t01     0x%s  0x%s   0\n' $s "$(echo $b | tr A-F a-f)" "$(echo $m | tr A-F a-f)"
            done < $A/chains
            printf 'Effects for session 0:\n\tNum fx In buffer   Out buffer   Active tracks:\n\t01     0x%s  0x%s   0\n\tEffect ID 108:\n\t\t- name: EQ Engine 0.4 (10-band EQ)\n' "$(echo $m | tr A-F a-f)" "$(echo $m | tr A-F a-f)"
        fi
    done ;;
esac
S
    cat > $T/stubs/dumpsys <<'S'
#!/bin/sh
[ "$1" = media.audio_flinger ] && /tmp/eqeact/stubs/afsim dump
exit 0
S
    # Hold.java: a chain on each session given until the keeper writes "release"; with "wake" also
    # a silent track of its own (session 990) that runs the main link (unless wake_fail)
    cat > $T/stubs/app_process <<'S'
#!/bin/sh
# CLASSPATH=<apk> app_process /system/bin com.eqengine.app.Hold <dir> <seconds> [wake] <session>...
T=/tmp/eqeact; A=$T/af
[ -f "$CLASSPATH" ] && [ "$2" = com.eqengine.app.Hold ] || exit 1
d=$3; shift 4
w=""; [ "$1" = wake ] && { w=1; shift; }
echo "${w:+wake }$*" >> $T/hold.log
mkdir -p $T/proc/$$; echo app_process > $T/proc/$$/cmdline
# hold_fail_after N: N holds work, every later one fails
_fa=""
if [ -f $T/hold_fail_after ]; then
    _n=$(cat $T/hold_fail_after)
    if [ "$_n" -le 0 ]; then _fa=1; else echo $((_n - 1)) > $T/hold_fail_after; fi
fi
if [ -f $T/hold_fail ] || [ -f $T/hold_fail_once ] || [ -n "$_fa" ]; then
    rm -f $T/hold_fail_once
    echo "failed session $1: java.lang.RuntimeException: Cannot initialize effect engine for type: 1de0ea4c Error: -1" > $d/state.tmp; mv $d/state.tmp $d/state
    rm -rf $T/proc/$$; exit 1
fi
n=$#; sess="$*"
if [ -n "$w" ]; then
    sess="$sess 990"
    echo "9 0 990 $(cat $A/mix)" >> $A/tracks
    [ -f $T/wake_fail ] || touch $T/waking
    # the factory CarPlay app takes the main link just as the silent track starts
    [ -f $T/other_on_wake ] && { rm -f $T/other_on_wake; echo 2291 > $T/other; }
fi
$T/stubs/afsim hold $sess
# a track that comes up while the others are held (newtrack): not held, on the mix buffer
[ -f $T/newtrack ] && { rm -f $T/newtrack; echo "8 1010 222 $(cat $A/mix)" >> $A/tracks; }
$T/stubs/asound
echo "held $n $*${w:+ silent 990}" > $d/state.tmp; mv $d/state.tmp $d/state
i=0; while [ ! -f $d/release ] && [ $i -lt 1000 ]; do /bin/sleep 0.01; i=$((i + 1)); done
if [ -n "$w" ]; then
    rm -f $T/waking
    grep -v '^9 0 990 ' $A/tracks > $A/tracks.n; mv $A/tracks.n $A/tracks
fi
$T/stubs/afsim release $sess
$T/stubs/asound
echo "released $n" > $d/state.tmp; mv $d/state.tmp $d/state
rm -rf $T/proc/$$
exit 0
S
    chmod +x $T/stubs/* $T/data/eqengine/bin/eqe_lab
    $T/stubs/afsim reset
    $T/stubs/asound
}
LS=$T/data/eqengine/state
HALT=$T/system/lib/hw/audio.primary.tcc803x.so
nkills() { [ -f $T/kill.log ] && wc -l < $T/kill.log || echo 0; }
later() { echo "$(( $(cut -d. -f1 $T/proc/uptime) + ${1:-11} )).00 50.00" > $T/proc/uptime; }
nsets() { [ -f $T/lab_calls.log ] && wc -l < $T/lab_calls.log || echo 0; }
keep() { ( cd /; EQE_TEST_ROOT=$T EQE_KEEP_ROUNDS=${1:-4} EQE_IDLE_AFTER=${IDLE:-8} EQE_OTHER_QUIET=${QUIET:-60} EQE_KEEP_MTRIES=${MTRIES:-5} EQE_APP_PROCESS=$T/stubs/app_process PATH=$T/stubs:/usr/bin:/bin timeout 60 $SH $ACT keep > $T/out.txt 2>&1; echo $? > $T/rc ); }
keepi() { IDLE=2 keep "$@"; }
tracks_on_mix() { [ "$(cut -d' ' -f4 $T/af/tracks | sort -u)" = "$(cat $T/af/mix)" ]; }
ost() { sed -n "s/^$1=//p" $LS/output; }

labsetup
run lab 1
ok "watch: mounted over Hyundai's driver, with an exact copy of the driver kept" "[ $(rc) = 0 ] && grep -q \" $HALT \" $T/proc/mounts && [ \"\$(md5sum < $T/data/eqengine/lib/hal/eqe_hal_orig.so | cut -c1-32)\" = 4e23b3753aecde59b180b374745653a7 ]"
ok "watch: one audio restart, the new server runs Hyundai's driver behind the layer" "[ $(nkills) = 1 ] && grep -q 'EQE_LAB watch watching' $T/out.txt && grep -q ' watch' $LS/lab_active"
run lab 1
ok "watch again: nothing to do, no restart" "[ $(rc) = 0 ] && grep -q 'already on: watch' $T/out.txt && [ $(nkills) = 1 ]"
later
run lab 0 0
ok "off (0.6.1's two arguments still work): unmounted, Hyundai's driver file back, one more restart" "[ $(rc) = 0 ] && ! grep -q \" $HALT \" $T/proc/mounts && [ \"\$(md5sum < $HALT | cut -c1-32)\" = 4e23b3753aecde59b180b374745653a7 ] && [ $(nkills) = 2 ] && [ ! -f $LS/lab_active ] && grep -q 'EQE_LAB off' $T/out.txt"
labsetup; echo "changed" >> $HALT
run lab 1
ok "a different Hyundai driver: the watch is refused, nothing mounted, no restart" "[ $(rc) = 1 ] && grep -q 'not the one this was built for' $T/out.txt && ! grep -q ' none ' $T/proc/mounts && [ $(nkills) = 0 ]"
labsetup; echo "changed" >> $T/data/eqengine/lib/eqe_drvwatch.so
run lab 1
ok "a damaged watch layer: refused" "[ $(rc) = 1 ] && grep -q 'failed its check' $T/out.txt && [ $(nkills) = 0 ]"
labsetup; mkdir -p $T/vendor/lib/hw; touch $T/vendor/lib/hw/audio.primary.tcc803x.so
run lab 1
ok "a vendor driver that Android would load first: refused" "[ $(rc) = 1 ] && grep -q 'would load instead' $T/out.txt && [ $(nkills) = 0 ]"
labsetup; echo x > $LS/disabled
run lab 1
ok "EQ Engine turned off: the watch is refused" "[ $(rc) = 1 ] && grep -q 'EQ Engine is off' $T/out.txt && [ $(nkills) = 0 ]"
labsetup
run lab 2
ok "a wrong argument is rejected" "[ $(rc) = 2 ]"
labsetup
run lab 1
later 3
run lab 0
ok "the 10 s gap between restarts applies to the watch too (nothing changed)" "[ $(rc) = 3 ] && grep -q EQE_WAIT $T/out.txt && grep -q \" $HALT \" $T/proc/mounts"
labsetup
run lab 1
later; touch $T/busy
run lab 0
ok "off while the audio server has the driver loaded (umount busy, as on the car): detached, then one restart" "[ $(rc) = 0 ] && ! grep -q \" $HALT \" $T/proc/mounts && grep -q \"umount $HALT\" $T/umount.log && [ \"\$(md5sum < $HALT | cut -c1-32)\" = 4e23b3753aecde59b180b374745653a7 ] && [ $(nkills) = 2 ]"

# --- the 48 kHz keeper
labsetup
MIX0=$(cat $T/af/mix)
keep 4
ok "keeper: music at 44.1 kHz is switched with one setting to the main output (io 101), no audio restart" "[ \"\$(cat $T/lab_calls.log)\" = 'set 101 sampling_rate=48000' ] && [ $(nkills) = 0 ]"
ok "keeper: accepted only with Android, the link setting and the measured rate at 48000" "[ \"\$(ost state)\" = 48k ] && [ \"\$(ost out)\" = 48000 ] && [ \"\$(ost link_rate)\" = 48000 ] && [ \"\$(ost fps)\" = 48000 ] && grep -q 'switched to 48000 Hz: output 101 at 48000 Hz, link pcm2p at 48000 Hz, measured 48000 frames/s; driver: start_output_stream' $LS/output.log"
ok "keeper: the switch is marked for this audio server and timed for the boot step" "[ \"\$(cat $LS/rate48)\" = \"\$(cat $T/mspid) 101\" ] && [ -s $LS/rate48_sent ]"
ok "keeper: later rounds leave the agreed link alone" "[ $(nsets) = 1 ]"
ok "keeper: the main output's four sessions were held for the switch and released after it" "grep -q \"holding the main output's audio sessions (13 107 21 111) for the change\" $LS/output.log && [ \"\$(cat $T/hold.log)\" = '13 107 21 111' ] && [ ! -s $T/af/chains ] && [ ! -d $LS/hold ]"
ok "keeper: the mix buffer moved at the switch, and every track plays into the new one" "[ \"\$(cat $T/af/mix)\" != $MIX0 ] && tracks_on_mix"
rm -f $T/playing; $T/stubs/asound; keep 2
touch $T/playing; $T/stubs/asound; keep 3
ok "keeper: the music pauses and plays again at 48 kHz: checked, nothing sent" "[ $(nsets) = 1 ] && [ \"\$(ost state)\" = 48k ]"
echo 0 > $T/data/eqengine/settings/rate48
keep 3
ok "keeper: 48 kHz turned off in the settings: 44100 sent back, both at 44.1 kHz" "[ \"\$(tail -n1 $T/lab_calls.log)\" = 'set 101 sampling_rate=44100' ] && [ \"\$(cat $T/rates)\" = '44100 44100' ] && [ \"\$(ost state)\" = 44k ] && [ ! -f $LS/rate48 ] && [ $(nkills) = 0 ]"

labsetup; echo 0 > $T/data/eqengine/settings/rate48
keep 3
ok "keeper: 48 kHz off from the start: nothing sent, 44.1 kHz noted" "[ $(nsets) = 0 ] && [ \"\$(ost state)\" = 44k ] && grep -q 'note=44.1 kHz (48 kHz output is off)' $LS/output"
labsetup; rm -f $T/playing; $T/stubs/asound
keep 3
ok "keeper: nothing playing: nothing sent, waiting for music" "[ $(nsets) = 0 ] && [ \"\$(ost state)\" = waiting ]"
labsetup; echo 9999 > $T/owner; $T/stubs/asound
keep 3
ok "keeper: the link is played by a thread that is not the audio server's: nothing sent, state other" "[ $(nsets) = 0 ] && [ \"\$(ost state)\" = other ] && [ \"\$(ost owner)\" = 'pid 9999' ]"

# --- another process plays to the main link itself (wired CarPlay, 0.6.4 on the car: the factory
# CarPlay app opens pcm2p through TinyALSA, and the audio server's own opens fail meanwhile)
labsetup; rm -f $T/playing; echo 2291 > $T/other; $T/stubs/asound
keepi 9
ok "other: the factory CarPlay app has the main link and nothing plays in Android: no switch, no hold, no silent track" "[ $(nsets) = 0 ] && [ ! -f $T/hold.log ] && [ ! -f $T/standby_sets.log ] && ! grep -q 'nothing plays: switching' $LS/output.log && ! grep -q 'no rate change' $LS/output.log"
ok "other: state other, the owner's name, the link with its rate and frames/s, a plain note" "[ \"\$(ost state)\" = other ] && [ \"\$(ost owner)\" = com.daudio.app.dipo ] && [ \"\$(ost link)\" = pcm2p ] && [ \"\$(ost link_rate)\" = 44100 ] && [ \"\$(ost fps)\" = 44100 ] && [ \"\$(ost server)\" = 5056 ] && [ \"\$(ost note)\" = \"the main speaker link is in use by com.daudio.app.dipo, which plays to it directly, not through Android's audio server; EQ Engine cannot process that sound\" ]"
ok "other: one log line when it appears, none after that" "[ \$(grep -c 'is in use by com.daudio.app.dipo (thread 2291, RUNNING at 44100 Hz)' $LS/output.log) = 1 ] && [ \$(wc -l < $LS/output.log) -le 3 ]"
labsetup; rm -f $T/playing; echo 2291 > $T/other; echo "0 704" > $T/other_at; $T/stubs/asound
QUIET=3 keepi 14
REL=$(sed -n 's/^\([0-9]*\) the main link (pcm2p) is no longer in use by com.daudio.app.dipo.*/\1/p' $LS/output.log)
SW=$(sed -n 's/^\([0-9]*\) nothing plays: switching the main output to 48 kHz now.*/\1/p' $LS/output.log)
ok "other: it lets go and nothing plays: one line, then (once the link has been free a while) the switch while nothing plays as usual" "[ -n \"\$REL\" ] && [ -n \"\$SW\" ] && [ \$((SW - REL)) -ge 3 ] && [ \"\$(cat $T/lab_calls.log)\" = 'set 101 sampling_rate=48000' ] && [ \"\$(ost state)\" = 48k ] && ! grep -q '^owner=' $LS/output && [ \$(grep -c 'no longer in use' $LS/output.log) = 1 ] && tracks_on_mix"
labsetup; rm -f $T/playing; echo 2291 > $T/other; echo "0 703" > $T/other_at; touch $T/other_then_play; $T/stubs/asound
keep 8
ok "other: it lets go and Android's music starts on the link: checked as usual, switched with the music playing" "[ \"\$(cat $T/lab_calls.log)\" = 'set 101 sampling_rate=48000' ] && [ \"\$(ost state)\" = 48k ] && grep -q 'no longer in use by com.daudio.app.dipo' $LS/output.log && grep -q \"holding the main output's audio sessions (13 107 21 111) for the change\" $LS/output.log && tracks_on_mix && ! grep -q '^owner=' $LS/output"
labsetup; echo "716 721" > $T/other_at; touch $T/other_stops_music $T/other_then_play
keep 26
ok "other: music at 48 kHz, then the CarPlay app has the link for a while: nothing sent meanwhile, 48 kHz shown again after it" "[ $(nsets) = 1 ] && [ \"\$(ost state)\" = 48k ] && grep -q 'is in use by com.daudio.app.dipo' $LS/output.log && grep -q 'no longer in use by com.daudio.app.dipo' $LS/output.log && [ \$(grep -c 'switching the main output' $LS/output.log) = 1 ] && [ \"\$(ost link_rate)\" = 48000 ]"
labsetup; rm -f $T/playing; touch $T/other_on_wake; $T/stubs/asound
keepi 7
ok "other: it takes the link just as the silent track starts: nothing sent, no try spent, the hold released, then state other" "[ $(nsets) = 0 ] && grep -q 'no rate change: the main link was taken by com.daudio.app.dipo' $LS/output.log && ! grep -q 'did not start with the silent track' $LS/output.log && ! grep -q 'could not be held' $LS/output.log && [ \"\$(ost state)\" = other ] && [ ! -s $T/af/chains ] && [ ! -d $LS/hold ] && ! grep -q ' 990 ' $T/af/tracks"

labsetup; echo keep > $T/driver48
keep 5
ok "keeper: the driver keeps 44.1 kHz: nothing to put back, held for this audio server, no second try" "[ \"\$(cat $T/lab_calls.log | tr '\n' ' ')\" = 'set 101 sampling_rate=48000 ' ] && [ \"\$(ost state)\" = held ] && grep -q 'note=48 kHz did not take: the driver kept 44.1 kHz; 44.1 kHz' $LS/output && grep -q 'driver answered -22' $LS/output.log && grep -q 'nothing to put back' $LS/output.log && grep -q \"the driver's lines about its rate since the switch: Set sampling_rate error\" $LS/output.log"
labsetup; echo convert > $T/driver48
keep 4
ok "keeper: Android at 48 kHz but the link at 44.1 kHz: put back and held" "grep -q 'Android went to 48 kHz but the link stayed at 44.1 kHz' $LS/output && [ \"\$(cat $T/rates)\" = '44100 44100' ] && [ \"\$(ost state)\" = held ]"
labsetup; echo mismatch > $T/driver48
keep 4
ok "keeper: the link switched but Android did not: put back and held" "grep -q \"the link went to 48 kHz but Android's mixer stayed at 44.1 kHz\" $LS/output && [ \"\$(cat $T/link_rate)\" = 44100 ] && [ \"\$(ost state)\" = held ]"
labsetup; echo sticky > $T/driver48
keep 3
echo 0 > $T/data/eqengine/settings/rate48
keep 4
ok "keeper: 44.1 kHz does not come back: says it stays at 48 kHz, never restarts audio" "[ $(nkills) = 0 ] && [ \"\$(ost state)\" = held ] && grep -q 'stays at 48000 Hz until the next audio restart or car start' $LS/output"
labsetup; echo crash > $T/driver48
keep 6
ok "keeper: the audio server stops right after the switch: no switch in the new one" "[ $(nsets) = 1 ] && grep -q 'the audio server stopped right after the switch to 48000 Hz' $LS/output.log && [ \"\$(ost state)\" = held ] && [ \"\$(ost server)\" = \"\$(cat $T/mspid)\" ]"

labsetup; echo "48000 44100" > $T/rates
keep 4
ok "keeper: Android at 48 kHz and the link at 44.1 kHz from the start (wrong speed): both set to 48 kHz" "grep -q 'Android.s output runs at 48000 Hz but link pcm2p at 44100 Hz' $LS/output.log && [ \"\$(ost state)\" = 48k ] && [ $(nsets) = 1 ]"
labsetup; echo convert > $T/driver48
keep 3
ok "keeper: a switch the link does not follow (wrong speed) is put back within 4 s" "[ \"\$(cut -d' ' -f2 $T/set_times.log | tr '\n' ' ')\" = 'sampling_rate=48000 sampling_rate=44100 ' ] && [ \$((\$(sed -n 2p $T/set_times.log | cut -d' ' -f1) - \$(sed -n 1p $T/set_times.log | cut -d' ' -f1))) -le 4 ] && tracks_on_mix"
labsetup; $T/data/eqengine/bin/eqe_lab set 101 sampling_rate=48000 > /dev/null
keep 3
ok "keeper: tracks left on the freed buffer (a switch without the hold, like 0.6.2's) are found and moved back" "grep -q 'tracks of session(s) 13 107 21 111 play into a buffer the main output no longer uses' $LS/output.log && grep -q 'moved back: all 4 tracks' $LS/output.log && tracks_on_mix && [ \"\$(ost state)\" = 48k ]"
labsetup; $T/data/eqengine/bin/eqe_lab set 101 sampling_rate=48000 > /dev/null; touch $T/hold_fail
keep 3
ok "keeper: tracks on a freed buffer that cannot be moved back: says to restart audio, changes no rate" "[ \"\$(ost state)\" = unsafe ] && grep -q 'Restart Android audio (parked)' $LS/output && [ $(nsets) = 1 ] && [ $(nkills) = 0 ]"
labsetup; touch $T/hold_fail
keep 6
ok "keeper: the sessions cannot be held: tried 3 times, no switch at all, 44.1 kHz with the reason" "[ $(nsets) = 0 ] && [ \"\$(ost state)\" = held ] && grep -q 'note=48 kHz not used: the tracks could not be held for the switch' $LS/output && grep -q 'Cannot initialize effect engine' $LS/output.log && [ \$(wc -l < $T/hold.log) = 3 ]"
labsetup; touch $T/hold_fail_once
keep 5
ok "keeper: a hold that fails once is tried again at the next round: switched (0.6.3 gave up for the whole start)" "[ $(nsets) = 1 ] && [ \"\$(ost state)\" = 48k ] && [ \$(grep -c 'no rate change' $LS/output.log) = 1 ] && tracks_on_mix"
labsetup; touch $T/newtrack
keep 4
ok "keeper: a track that comes up during the hold (0.6.3's first car start): held again with its session, then switched" "grep -q 'a track came up during the hold (session(s) 222): holding again' $LS/output.log && [ \"\$(sed -n 2p $T/hold.log)\" = '13 107 21 111 222' ] && [ $(nsets) = 1 ] && [ \"\$(ost state)\" = 48k ] && tracks_on_mix"
labsetup; echo "b6b00000-b6b20000 r-xp 00000000 b3:19 99   /system/lib/libaudioflinger.so" > $T/proc/5056/maps
keep 4
ok "keeper: EQ Engine's filter is not in the audio server (it read its effects list before the overlay): no hold, no switch, says to restart audio" "[ $(nsets) = 0 ] && [ ! -f $T/hold.log ] && [ \"\$(ost state)\" = held ] && grep -q 'filter is not loaded in this audio server. Restart Android audio once (parked)' $LS/output"
labsetup; rm -f $T/data/app/com.eqengine.app-1.apk
keep 3
ok "keeper: the app's package is missing: no switch" "[ $(nsets) = 0 ] && grep -q \"EQ Engine's app package was not found\" $LS/output.log"
labsetup; touch $T/af/lucky
keep 4
ok "keeper: the new mix buffer at the old address (usual on the car): the same switch, all tracks fine" "[ \"\$(ost state)\" = 48k ] && tracks_on_mix && ! grep -q 'no longer uses' $LS/output.log"

# --- switching while nothing plays: a silent track runs the link (the driver ignores a rate sent
# to a stream in standby)
labsetup; rm -f $T/playing; $T/stubs/asound; touch $T/start_after_set
keepi 9
ok "idle: switched with a silent track running the link (once the audio server had settled); the music then starts at 48 kHz: accepted" "[ \"\$(cat $T/lab_calls.log)\" = 'set 101 sampling_rate=48000' ] && [ ! -f $T/standby_sets.log ] && grep -q 'nothing plays: switching the main output to 48 kHz now' $LS/output.log && grep -q 'a silent track (session 990) runs the main link for the change; holding the main output.s audio sessions (13 107 21 111)' $LS/output.log && grep -q 'the music started at 48000 Hz (switched while nothing played); measured 48000 frames/s' $LS/output.log && [ \"\$(ost state)\" = 48k ] && [ -f $LS/rate48 ] && tracks_on_mix"
ok "idle: the silence ends with the hold; its track and chains are gone" "[ ! -f $T/waking ] && ! grep -q ' 990 ' $T/af/tracks && [ ! -s $T/af/chains ] && [ ! -d $LS/hold ] && [ \"\$(head -n1 $T/hold.log)\" = 'wake 13 107 21 111' ]"
labsetup; rm -f $T/playing; $T/stubs/asound
keepi 7
ok "idle: no music yet: the switch is already checked at the link (Android and hw_params at 48000), the driver's line read after the silence" "[ $(nsets) = 1 ] && [ \"\$(ost state)\" = 48k ] && [ \"\$(cat $T/link_rate)\" = 48000 ] && grep -q 'switched to 48000 Hz: output 101 at 48000 Hz, link pcm2p at 48000 Hz (a silent track ran the link)' $LS/output.log && grep -q \"the driver's line for that switch: start_output_stream\" $LS/output.log && [ ! -f $T/waking ]"
labsetup; rm -f $T/playing; $T/stubs/asound
keep 5
ok "idle: not before the audio server has settled (8 s)" "[ $(nsets) = 0 ] && [ ! -f $T/hold.log ]"
labsetup; rm -f $T/playing; $T/stubs/asound; touch $T/wake_fail; echo 6 > $T/start_in
keepi 12
ok "idle: the silent track does not start the link: nothing is sent while idle; switched once the music plays" "grep -q \"the main output's link did not start with the silent track\" $LS/output.log && [ ! -f $T/standby_sets.log ] && [ \"\$(cat $T/lab_calls.log)\" = 'set 101 sampling_rate=48000' ] && [ \"\$(ost state)\" = 48k ] && tracks_on_mix"
# the link's frames counted when the music starts after a switch made while nothing played
labsetup; rm -f $T/playing; $T/stubs/asound
keepi 7
ok "measured: before the music the switch is not called checked (fps empty)" "[ \"\$(ost state)\" = 48k ] && [ -z \"\$(ost fps)\" ]"
labsetup; rm -f $T/playing; $T/stubs/asound; echo slowclock > $T/driver48; touch $T/start_after_set
keepi 12
ok "measured: the link says 48 kHz but runs at 44.1 kHz: 44100 put back with the main output's sessions held, like every rate change" "[ \"\$(cat $T/lab_calls.log)\" = 'set 101 sampling_rate=48000
set 101 sampling_rate=44100' ] && grep -q 'link pcm2p is set to 48000 Hz but took 44100 frames/s' $LS/output.log && [ \$(grep -c \"holding the main output's audio sessions\" $LS/output.log) = 2 ] && [ \"\$(sed -n 2p $T/hold.log)\" = '13 107 21 111' ] && tracks_on_mix && [ ! -s $T/af/chains ]"
ok "measured: back at 44.1 kHz and held there for this audio server, said why" "[ \"\$(ost state)\" = held ] && [ \"\$(cat $T/rates)\" = '44100 44100' ] && grep -q 'note=the link took 44100 frames/s at 48000 Hz; back at 44.1 kHz' $LS/output && [ ! -f $LS/rate48 ] && [ $(nsets) = 2 ]"
labsetup; rm -f $T/playing; $T/stubs/asound; echo slowclock > $T/driver48; touch $T/start_after_set; echo 1 > $T/hold_fail_after
keepi 12
ok "measured: the tracks cannot be held for the put-back: nothing is sent unheld, and the wrong speed is said" "[ \"\$(cat $T/lab_calls.log)\" = 'set 101 sampling_rate=48000' ] && [ \"\$(ost state)\" = mismatch ] && grep -q 'note=Link pcm2p runs at 44100 frames/s at 48000 Hz: wrong speed' $LS/output"
labsetup; rm -f $T/playing; $T/stubs/asound; touch $T/start_after_set; echo 1 > $T/rate_none
keepi 12
ok "measured: a count that gets nothing is made again at the next round" "grep -q 'its frames could not be counted; counted again while it plays' $LS/output.log && grep -q 'the music started at 48000 Hz (switched while nothing played); measured 48000 frames/s' $LS/output.log && [ \"\$(ost fps)\" = 48000 ] && [ \"\$(ost state)\" = 48k ]"
labsetup; rm -f $T/playing; $T/stubs/asound; touch $T/start_after_set; echo 99 > $T/rate_none
MTRIES=2 keepi 12; unset MTRIES
ok "measured: counts that keep getting nothing: left not measured (fps empty), not called checked" "grep -q 'its frames could not be counted 2 times; counted again at its next start' $LS/output.log && [ \"\$(ost state)\" = 48k ] && [ -z \"\$(ost fps)\" ]"
labsetup; rm -f $T/playing; $T/stubs/asound; echo keep > $T/driver48
keepi 6
ok "idle: the driver keeps 44.1 kHz with the silent track running: nothing to put back, held" "[ $(nsets) = 1 ] && [ \"\$(ost state)\" = held ] && grep -q 'the driver kept 44.1 kHz' $LS/output && [ ! -f $T/waking ]"
labsetup; rm -f $T/playing; $T/stubs/asound; : > $LS/idle48_bad
keepi 6
ok "idle: 0.6.3's marker is removed and the switch is made with the silent track" "[ ! -f $LS/idle48_bad ] && [ $(nsets) = 1 ] && [ \"\$(ost state)\" = 48k ]"
labsetup; rm -f $T/playing; $T/stubs/asound; $T/data/eqengine/bin/eqe_lab set 101 sampling_rate=48000 > /dev/null; touch $T/playing; $T/stubs/asound
keep 4
ok "the simulated driver: a rate sent to the idle stream (0.6.3) reaches Android only, the music then starts at 44.1 kHz; the keeper switches with the music playing" "grep -q 'standby sampling_rate=48000' $T/standby_sets.log && grep -q 'Android.s output runs at 48000 Hz but link pcm2p at 44100 Hz' $LS/output.log && [ \"\$(ost state)\" = 48k ] && [ \"\$(cat $T/link_rate)\" = 48000 ]"
labsetup; echo 0 > $T/data/eqengine/settings/rate48; rm -f $T/playing; echo "48000 44100" > $T/rates; echo 48000 > $T/link_rate; $T/stubs/asound
keepi 6
ok "idle: 48 kHz off with the output left at 48 kHz: 44.1 kHz put back with the silent track running the link" "[ \"\$(tail -n1 $T/lab_calls.log)\" = 'set 101 sampling_rate=44100' ] && [ ! -f $T/standby_sets.log ] && [ \"\$(cat $T/rates)\" = '44100 44100' ] && [ \"\$(cat $T/link_rate)\" = 44100 ]"
labsetup; mkdir -p $LS/restart.lock
keep 3
ok "keeper: an audio restart under way: it waits, nothing sent" "[ $(nsets) = 0 ]"
labsetup; echo x > $LS/disabled
keep 3
ok "keeper: EQ Engine off and the output at 44.1 kHz: it stops at once" "[ $(nsets) = 0 ] && [ \"\$(ost state)\" = off ] && [ ! -f $LS/keep.pid ]"
labsetup
keep 3
echo x > $LS/disabled
keep 6
ok "keeper: EQ Engine turned off at 48 kHz: 44100 put back first, then it stops" "[ \"\$(tail -n1 $T/lab_calls.log)\" = 'set 101 sampling_rate=44100' ] && [ \"\$(ost state)\" = off ] && [ \"\$(cat $T/rates)\" = '44100 44100' ]"
labsetup
keep 1
ok "keeper: it records its own pid and says so" "grep -q \"keeper started (pid \$(cat $LS/keep.pid))\" $LS/output.log"

# --- the car report
labsetup
mkdir -p $T/usb $T/app
echo "2026-11-19 18:00:00.000 I EQ Engine 0.6.2 screen opened" > $T/app/eqengine.log
echo "2026-11-19 18:00:01.000 I bt_headset_name=Someones Phone" >> $T/app/eqengine.log
cat > $T/stubs/getprop <<'S'
#!/bin/sh
if [ -z "$1" ]; then
cat <<'P'
[ro.build.product]: [NEEV.USA.0000.V015.012.260507]
[ro.build.version.sdk]: [19]
[ro.serialno]: [ABC123SERIAL]
[persist.service.bdroid.bdaddr]: [22:22:aa:bb:cc:dd]
[tcc.audio.sampling_rate]: [4]
[ro.daudio.vin]: [KM8KRDAF1NU000000]
[wifi.interface]: [wlan0]
[ro.debuggable]: [1]
[ro.secure]: [1]
[ro.some.other]: [x]
P
exit 0
fi
case "$1" in
ro.build.product) echo NEEV.USA.0000.V015.012.260507 ;;
ro.build.version.sdk) echo 19 ;;
ro.build.version.release) echo 4.4.2 ;;
af.resampler.quality) cat /tmp/eqeact/prop ;;
ro.debuggable|ro.secure) echo 1 ;;
esac
S
cat > $T/stubs/dmesg <<'S'
#!/bin/sh
echo "<5>[    0.000000] Kernel command line: console=ttyS0 androidboot.serialno=ABC123SERIAL"
echo "<7>[  230.251623] [DEBUG][I2S-3] tcc_i2s_hw_params - sample_rate : 48000"
echo "<6>[  231.000000] bcmdhd: wlan0 up"
S
cat > $T/stubs/logcat <<'S'
#!/bin/sh
# "logcat -v time -f FILE -s ...": a few audio lines, two of them with personal data
f=""; prev=""
for a in "$@"; do [ "$prev" = -f ] && f=$a; prev=$a; done
if [ -n "$f" ]; then
    {
        echo "11-19 18:00:45.170 D/AudioFlinger( 4220): setParameters(): io 101, keyvalue sampling_rate=48000, calling pid 4407"
        echo "11-19 18:00:46.000 D/AudioService(  663): connected A2DP device 00:1A:7D:DA:71:13"
        echo "11-19 18:00:46.100 D/MicomAudioService(  663): songTitle = Some Song"
        echo "11-19 18:00:47.000 D/audio_hw_primary( 4220): start_output_stream(0/2), channel(2), samplerate(48000)"
        i=0; while [ $i -lt 10 ]; do echo "11-19 18:00:48.$i$i$i W/AudioFlinger( 4220): prepareTracks_l(): track 4098 attached to effect but no chain found on session 21"; i=$((i + 1)); done
    } > "$f"
    exit 0
fi
case "$*" in
    *audio_hw_primary*) cat /tmp/eqeact/hal.log 2>/dev/null ;;
esac
exit 0
S
chmod +x $T/stubs/*
echo 4 > $T/prop
printf 'b6a00000-b6a2a000 r-xp 00000000 b3:19 4242   /data/eqengine/lib/libeqengine.so\nb6b00000-b6b2a000 r-xp 00000000 b3:19 4243   /data/eqengine/lib/libaudio-resampler.so\n' > $T/proc/5056/maps
run report $T/usb $T/app 1
RF=$(ls $T/usb/EQENGINE/report_*.txt 2>/dev/null | head -n1)
ok "report: one text file on the stick, named after the car's software" "[ $(rc) = 0 ] && [ -n \"$RF\" ] && echo \"$RF\" | grep -q 'report_NEEV.USA.0000.V015.012.260507_' && grep -q 'EQE_REPORT report_NEEV' $T/out.txt"
ok "report: the checks are there (Android, driver, 48 kHz switch, main output)" "grep -q 'ok    Android 4.4.2 (API 19)' \"$RF\" && grep -q 'audio driver: the same one as on the tested car' \"$RF\" && grep -q 'the 48 kHz switch can reach' \"$RF\" && grep -q 'main output: io 101 at 44100 Hz; link pcm2p set to 44100 Hz' \"$RF\""
ok "report: the audio lines and the kernel's audio line are kept" "grep -q 'keyvalue sampling_rate=48000' \"$RF\" && grep -q 'samplerate(48000)' \"$RF\" && grep -q 'tcc_i2s_hw_params - sample_rate : 48000' \"$RF\" && grep -q 'tcc.audio.sampling_rate' \"$RF\""
ok "report: no serial number, VIN, Bluetooth address, phone name or song" "! grep -q -i -e ABC123SERIAL -e KM8KRDAF -e '22:22:aa' -e '00:1A:7D' -e 'Someones' -e 'Some Song' -e 'command line' \"$RF\""
ok "report: factory files are not copied (checksums only)" "grep -q 'checksums only' \"$RF\" && ! grep -q 'snd-soc\\|ELF' \"$RF\""
ok "report: the filter and converter checks name the audio server and find the tables" "grep -q 'filter is loaded in the audio server (5056)' \"$RF\" && grep -q \"converter: very high quality with EQ Engine's tables (loaded)\" \"$RF\""
ok "report: the tracks' buffers are checked" "grep -q 'ok    track buffers: all 4 tracks on the main output' \"$RF\""
ok "report: who plays on each link" "grep -q 'pcm2p: RUNNING, played by thread 4258 of /system/bin/mediaserver' \"$RF\" && grep -q 'pcm0p: closed' \"$RF\""
ok "report: a line repeated at every mix cycle shows 3 times, then is counted" "[ \$(grep -c 'no chain found on session 21' \"$RF\") = 4 ] && grep -q 'came 7 more times' \"$RF\""
ok "report: no maker's name in its own text (Gen5W units are in other HMG cars too)" "! grep -q Hyundai \"$RF\" && grep -q '^==================== Factory audio files (checksums only)' \"$RF\" && grep -q \"the car maker's\" \"$RF\""
TAMD5=$(md5sum < $T/system/lib/libtinyalsa.so | cut -c1-32)
sed -n '/^-- CarPlay app.s audio code (symbol tables only)$/,/^====/p' "$RF" > $T/probe.txt
ok "report: CarPlay probe: the app found by its command line, its distinct libraries counted, HMG-API's decoder found" "grep -qx '  the factory CarPlay app (com.daudio.app.dipo) runs as pid 2290, with 4 libraries mapped' $T/probe.txt && grep -qx \"  HMG-API's AAC decoder libleafiaaac.so is mapped: /data/hmgapi/lib/libleafiaaac.so\" $T/probe.txt"
ok "report: CarPlay probe: each library with what it needs and only its pcm_ and mixer_ imports" "grep -A6 -x '  library /system/lib/libCarPlayAudio.so' $T/probe.txt | grep -qx '    needs: libc.so libtinyalsa.so libCarPlayUtils.so' && grep -qx '    imports pcm_open' $T/probe.txt && grep -qx '    imports pcm_writei' $T/probe.txt && grep -qx '    imports mixer_get_ctl_by_name' $T/probe.txt && ! grep -q 'imports malloc' $T/probe.txt && ! grep -q 'CarPlayAudioStart' $T/probe.txt && ! grep -q 'pcm_fake_export' $T/probe.txt && grep -A1 -x '  library /system/lib/libc.so' $T/probe.txt | grep -qx '    needs: nothing'"
ok "report: CarPlay probe: a library that cannot be read says why; libraries are read under the unit's root" "grep -A1 -x '  library /system/lib/libbroken.so' $T/probe.txt | grep -qx '    not read (unexpected program header size)' && grep -qx \"imports $T/system/lib/libCarPlayAudio.so\" $T/imports.log && ! grep -q 'framework.jar' $T/imports.log"
ok "report: CarPlay probe: libtinyalsa.so by md5 and exported names only, and the three properties" "grep -qx \"  /system/lib/libtinyalsa.so (factory file, not copied): md5 $TAMD5\" $T/probe.txt && grep -qx '    exports pcm_open' $T/probe.txt && grep -qx '    exports mixer_ctl_get_name' $T/probe.txt && ! grep -q 'import ioctl' $T/probe.txt && ! grep -q 'factory tinyalsa' \"$RF\" && grep -qx '  ro.debuggable = \[1\]' $T/probe.txt && grep -qx '  ro.secure = \[1\]' $T/probe.txt && grep -qx '  wrap.com.daudio.app.dipo = \[\]' $T/probe.txt"
ok "report: CarPlay probe: the CarPlay libraries' imports of Android's audio classes and exports named for an audio backend" "grep -qx '    imports (Android audio) _ZN7android10AudioTrackC1Ev' $T/probe.txt && grep -qx '    imports (Android audio) _ZN7android11AudioSystem13getParametersEiRKNS_7String8E' $T/probe.txt && grep -qx '    exports (audio backend) TccCarPlayAudioTinyALSA_Open' $T/probe.txt && grep -qx '    exports (audio backend) TccCarPlayAudioTrack_Write' $T/probe.txt && [ \$(grep -c 'imports (Android audio)' $T/probe.txt) = 2 ] && ! grep -q tinyalsa_like_export $T/probe.txt"
DCMD5=$(md5sum < $T/system/etc/dipo_audio.conf | cut -c1-32)
ok "report: CarPlay probe: config files named for CarPlay by md5 only; no texts, properties or file content (those are for All logs)" "grep -qx \"  config file /system/etc/dipo_audio.conf (factory file): md5 $DCMD5\" $T/probe.txt && ! grep -q 'unrelated.conf' $T/probe.txt && ! grep -q -e 'audio_out=tinyalsa' -e 'texts in the CarPlay code' -e 'persist.dipo.audio.output' -e 'properties for CarPlay' \"$RF\" && [ ! -f $T/strings.log ]"
ok "report: the properties section lists ro.debuggable and ro.secure (allowlist), not others" "grep -q '^\[ro.debuggable\]: \[1\]' \"$RF\" && grep -q '^\[ro.secure\]: \[1\]' \"$RF\" && ! grep -q 'ro.some.other' \"$RF\""
rm -rf $T/proc/2290; mkdir -p $T/usb2
run report $T/usb2 $T/app 1
RF2=$(ls $T/usb2/EQENGINE/report_*.txt 2>/dev/null | head -n1)
sed -n '/^-- CarPlay app.s audio code (symbol tables only)$/,/^====/p' "$RF2" > $T/probe2.txt
ok "report: CarPlay probe: the app not running is one line; libtinyalsa.so and the properties still there" "[ \$(grep -c 'CarPlay app' $T/probe2.txt) = 2 ] && grep -qx '  the factory CarPlay app (com.daudio.app.dipo) is not running' $T/probe2.txt && ! grep -q '^  library ' $T/probe2.txt && grep -q 'libtinyalsa.so (factory file, not copied)' $T/probe2.txt && grep -q 'ro.secure' $T/probe2.txt"
run report $T/nousb $T/app 1
ok "report: no stick: refused" "[ $(rc) = 1 ] && grep -q 'no USB stick' $T/out.txt"

echo "== All logs (save) and the Lab trace under $SH"
labsetup
cat > $T/stubs/getprop <<'S'
#!/bin/sh
if [ -z "$1" ]; then
    printf '[persist.dipo.audio.output]: [tinyalsa]\n[ro.build.product]: [NEEV]\n[tcc.audio.sampling_rate]: [4]\n[persist.sys.iap2.enable]: [1]\n[wrap.com.daudio.app.dipo]: []\n'
    exit 0
fi
cat /tmp/eqeact/prop
S
chmod +x $T/stubs/getprop
mkdir -p $T/usb3 $T/app $T/data/tombstones
for n in 00 01 02 03; do echo "tombstone $n" > $T/data/tombstones/tombstone_$n; done
touch -d '2026-11-01 10:00' $T/data/tombstones/tombstone_00 $T/data/tombstones/tombstone_01
echo "act.sh as installed" > $T/data/eqengine/bin/act.sh; touch -d '2026-11-10 10:00' $T/data/eqengine/bin/act.sh
touch -d '2026-11-15 10:00' $T/data/tombstones/tombstone_02; touch -d '2026-11-16 10:00' $T/data/tombstones/tombstone_03
run save $T/usb3 $T/app 1
SD=$(ls -d $T/usb3/EQENGINE/*/ 2>/dev/null | head -n1)
ok "save: only the tombstones written since the install are copied" "[ $(rc) = 0 ] && [ -f ${SD}tombstone_02.txt ] && [ -f ${SD}tombstone_03.txt ] && [ ! -f ${SD}tombstone_00.txt ] && [ ! -f ${SD}tombstone_01.txt ]"
ok "save: tombstones_list.txt lists all of them, and which were copied" "[ \$(grep -c '^-.* tombstone_0[0-3]\$' ${SD}tombstones_list.txt) = 4 ] && grep -qx 'copied here (written since this install of EQ Engine): tombstone_02 tombstone_03' ${SD}tombstones_list.txt"
ok "save: carplay_probe.txt reads no text out of the CarPlay code and no factory config file's content (0.7.4)" "! grep -q '^    libCarPlay[A-Za-z]*.so: \|^    DiPO.odex: \|^    | \|texts in the CarPlay code\|audio_out=tinyalsa' ${SD}carplay_probe.txt && [ ! -s $T/strings.log ] && grep -q 'config file /system/etc/dipo_audio.conf (factory file): md5' ${SD}carplay_probe.txt"
ok "save: carplay_probe.txt has the CarPlay, iAP and Telechips properties with their values" "grep -qx '    \[persist.dipo.audio.output\]: \[tinyalsa\]' ${SD}carplay_probe.txt && grep -qx '    \[tcc.audio.sampling_rate\]: \[4\]' ${SD}carplay_probe.txt && grep -qx '    \[persist.sys.iap2.enable\]: \[1\]' ${SD}carplay_probe.txt && ! grep -q 'ro.build.product' ${SD}carplay_probe.txt"
ok "save: carplay_probe.txt has the plain list of mapped libraries and the filtered imports" "grep -q 'runs as pid 2290, with 4 libraries mapped' ${SD}carplay_probe.txt && grep -qx '    /system/lib/libc.so' ${SD}carplay_probe.txt && grep -qx '    /data/hmgapi/lib/libleafiaaac.so' ${SD}carplay_probe.txt && grep -qx '    imports pcm_open' ${SD}carplay_probe.txt && ! grep -q 'imports malloc' ${SD}carplay_probe.txt && [ ! -d $LS/cp_probe ]"
ok "save: the CarPlay app's process as it runs (maps, command line)" "cmp -s ${SD}dipo_maps.txt $T/proc/2290/maps && cmp -s ${SD}dipo_cmdline.txt $T/proc/2290/cmdline && [ -f ${SD}dipo_environ.txt ]"
labsetup
mkdir -p $T/usb4 $T/data/tombstones; echo t > $T/data/tombstones/tombstone_05
run save $T/usb4 $T/app 0
SD=$(ls -d $T/usb4/EQENGINE/*/ 2>/dev/null | head -n1)
ok "save without the Android dumps (the app's crash handler): no tombstones, no probe" "[ $(rc) = 0 ] && [ -n \"$SD\" ] && [ ! -f ${SD}tombstone_05.txt ] && [ ! -f ${SD}carplay_probe.txt ] && grep -q tombstone_05 ${SD}tombstones_list.txt"
labsetup
mkdir -p $T/data/eqengine/lab/trace_20260101_000000 $T/data/eqengine/lab/trace_20260102_000000 $T/data/eqengine/lab/trace_20260103_000000
run trace 1
ok "trace: the newest 2 traces are kept" "[ $(rc) = 0 ] && [ \$(ls -d $T/data/eqengine/lab/trace_* | wc -l) = 2 ] && [ -d $T/data/eqengine/lab/trace_20260103_000000 ] && grep -q 'trace saved to' $T/out.txt"

echo "== screenshot to USB (shot) under $SH"
labsetup
mkdir -p $T/usb5 $T/system/bin
printf '#!/bin/sh\n[ "$1" = -p ] && printf "PNGDATA" > "$2"\n' > $T/system/bin/screencap; chmod 755 $T/system/bin/screencap
run shot $T/usb5 0
SF=$(ls $T/usb5/EQENGINE/screen_*.png 2>/dev/null | head -n1)
ok "shot: written straight to the stick, and the app is told its name" "[ $(rc) = 0 ] && [ -s \"$SF\" ] && grep -q '^EQE_SHOT EQENGINE/screen_[0-9_]*\.png\$' $T/out.txt && grep -q EQE_OK $T/out.txt"
ok "shot: nothing is kept on the head unit" "[ -z \"\$(find $T/data -name '*.png' 2>/dev/null)\" ]"
run shot $T/nousb 0
ok "shot: no stick: refused before waiting" "[ $(rc) = 1 ] && grep -q 'no USB stick' $T/out.txt"
printf '#!/bin/sh\nexit 1\n' > $T/system/bin/screencap
rm -rf $T/usb5/EQENGINE
run shot $T/usb5 0
ok "shot: screencap failing leaves no empty file and says so" "[ $(rc) = 1 ] && grep -q 'screenshot failed' $T/out.txt && [ -z \"\$(ls $T/usb5/EQENGINE 2>/dev/null)\" ]"
rm -f $T/system/bin/screencap
run shot $T/usb5 0
ok "shot: no screencap on the unit: says so" "[ $(rc) = 1 ] && grep -q 'no screencap' $T/out.txt"

echo "== curves on USB (curves) under $SH"
labsetup
CS2=$T/data/eqengine/settings
mkdir -p $T/usb6 $CS2
rm -f $CS2/preset*.txt
printf '%s\n' '-500,500,400,200,-100,-200,-100,100,300,400,400' > $CS2/preset1.txt
printf '%s\n' 'x;-600;2:6000:-500:0;1:63000:-700:333;4:3000:0:707' > $CS2/preset3.txt
run curves save $T/usb6
ok "curves save: the saved slots go to EQENGINE_CURVES as user1..4.txt, with a README, and the app is told" "[ $(rc) = 0 ] && cmp -s $CS2/preset1.txt $T/usb6/EQENGINE_CURVES/user1.txt && cmp -s $CS2/preset3.txt $T/usb6/EQENGINE_CURVES/user3.txt && [ ! -f $T/usb6/EQENGINE_CURVES/user2.txt ] && [ -s $T/usb6/EQENGINE_CURVES/README.txt ] && grep -q '^EQE_CURVES Saved 2 of the 4 user slots' $T/out.txt && grep -q EQE_OK $T/out.txt"
rm -f $CS2/preset*.txt
printf '%s\n' '0,0,0,0,0,0,0,0,0,0,0' > $CS2/preset2.txt
printf 'x;-300;1:100000:250:1000\r\n' > $T/usb6/EQENGINE_CURVES/user2.txt
printf 'rm -rf /;echo pwned\n' > $T/usb6/EQENGINE_CURVES/user4.txt
run curves load $T/usb6
ok "curves load: the stick's curves into the slots (a PC's line ending taken), a slot without a file kept" "[ $(rc) = 0 ] && cmp -s $T/usb6/EQENGINE_CURVES/user1.txt $CS2/preset1.txt && [ \"\$(cat $CS2/preset2.txt)\" = 'x;-300;1:100000:250:1000' ] && cmp -s $T/usb6/EQENGINE_CURVES/user3.txt $CS2/preset3.txt"
ok "curves load: a file that is not a curve is left out and named" "[ ! -f $CS2/preset4.txt ] && grep -q '^EQE_CURVES Loaded 3 curve(s) from the stick into the user slots. Left alone, not a curve file: User 4.' $T/out.txt"
ok "curves load: the slot files are the app's own, read-write for it only" "[ -z \"\$(find $CS2 -name 'preset*.txt' ! -perm 600)\" ] && [ ! -f $CS2/preset1.txt.tmp ]"
ok "curves: nothing the car lacks is called (0.6.11: printf, in mksh)" "! grep -q 'not found' $T/out.txt"
printf 'x;0;1:100000:0:1000\nsecond line\n' > $T/usb6/EQENGINE_CURVES/user4.txt
printf '1,2,x,4\n' > $T/usb6/EQENGINE_CURVES/user1.txt
run curves load $T/usb6
ok "curves load: two lines, or an x out of place: not a curve" "[ $(rc) = 0 ] && grep -q 'Left alone, not a curve file: User 1, User 4.' $T/out.txt && [ ! -f $CS2/preset4.txt ]"
rm -rf $T/usb6/EQENGINE_CURVES
run curves load $T/usb6
ok "curves load: no folder on the stick: refused, says how to make one" "[ $(rc) = 1 ] && grep -q 'has no EQENGINE_CURVES folder' $T/out.txt"
run curves save $T/nousb
ok "curves: no stick: refused" "[ $(rc) = 1 ] && grep -q 'no USB stick' $T/out.txt"
run curves send $T/usb6
ok "curves: an unknown word is rejected" "[ $(rc) = 2 ]"
rm -f $CS2/preset*.txt
run curves save $T/usb6
ok "curves save: nothing saved yet: says so" "[ $(rc) = 0 ] && grep -q 'No user slot is saved yet' $T/out.txt"
# the car runs these on mksh with toolbox only: no command-position use of a program it lacks
# (comment lines skipped; the CR line's printf is the dash/bash fallback after mksh's print)
CARLESS=$(grep -nE "(^|[;&|({\`]|\bthen|\bdo|\belse)[[:space:]]*(printf|tr|sed|awk|grep|egrep|head|tail|cut|sort|uniq|wc|xargs|basename|dirname|seq|expr|find|readlink|stat|tee|od|hexdump|which|timeout|nohup|pgrep|pkill|killall)([[:space:]]|\$|\))" \
    $R/pkg/bin/*.sh $R/pkg/scripts/*.sh $R/rescue/*.sh | grep -vE "^[^:]+:[0-9]+:[[:space:]]*#" | grep -v "CR=\$(printf '.r' 2>/dev/null)")
ok "the car's scripts call no program the car lacks (printf, grep, sed, head and the like)" "[ -z \"\$CARLESS\" ] || { echo \"\$CARLESS\" > $T/out.txt; false; }"

echo "== converter choice without a restart (conv) under $SH"
setup; vhqsetup good map
run conv 4
ok "conv 4: marker, 4 from the next start, no restart" "[ $(rc) = 0 ] && [ -f $VS/vhq_load ] && [ \"\$(cat $T/setprop.log)\" = af.resampler.quality=4 ] && [ ! -f $T/kill.log ]"
run conv 0
ok "conv 0: marker gone, stock from the next start" "[ $(rc) = 0 ] && [ ! -f $VS/vhq_load ] && [ \"\$(tail -n1 $T/setprop.log)\" = af.resampler.quality=0 ]"
run conv 3
ok "conv 3: high quality from the next start" "[ $(rc) = 0 ] && [ \"\$(tail -n1 $T/setprop.log)\" = af.resampler.quality=3 ]"
setup; vhqsetup bad map
run conv 4
ok "conv 4 with damaged tables: refused, nothing set" "[ $(rc) = 1 ] && [ ! -f $VS/vhq_load ] && [ ! -f $T/setprop.log ]"
setup
run conv 7
ok "conv with a wrong value is rejected" "[ $(rc) = 2 ]"

echo "== CarPlay watch 2 (cpwatch, cpwboot, cpwguard) and the CarPlay probe's process lines under $SH"
CS=$T/data/eqengine/state
CW=$T/data/eqengine/cpw
JNI=$T/system/lib/libCarPlayAndroid.so
COPY=$T/data/eqengine/lib/libCarPlayAndroid.car.so
cpwsetup() {  # labsetup, plus the CarPlay watch installed and the factory CarPlay app as Android runs it
    labsetup
    echo "the CarPlay watch" > $T/data/eqengine/lib/eqe_cpwatch.so
    md5sum < $T/data/eqengine/lib/eqe_cpwatch.so | cut -c1-32 > $T/data/eqengine/conf/eqe_cpwatch.md5
    # the factory CarPlay app's JNI library, which the watch is laid over
    echo "the factory CarPlay JNI library" > $JNI
    rm -f $COPY $CS/cpw_want $CS/cpwatch $CS/cpw_result $CS/cpw_restarts $CS/cpw_failed
    mkdir -p $T/proc/2290/task/2291 $T/props
    rm -rf $T/props/* $CW $CW.prev
    printf 'Name:\tcom.daudio.app\nTgid:\t2290\nPPid:\t150\nUid:\t1000\t1000\t1000\t1000\nGid:\t1000\t1000\t1000\t1000\nGroups:\t1015 3002 3003 \nCapEff:\t0000000000000000\n' > $T/proc/2290/status
    echo 00200000 > $T/proc/2290/personality
    echo "2290 (com.daudio.app) S 150 149 0 0 -1 1077936448 9000 0 4 0 300 120 0 0 20 0 60 0 2350 812000000 30000 4294967295" > $T/proc/2290/stat
    cp $T/proc/2290/maps $T/dipo_maps
    echo 2290 > $T/dipo_pid
    rm -f $T/dipo_no_restart $T/dipo_nudge_only $T/am.log $T/cpcheck_fail $T/cpcheck.log $T/dipo_starts.log
    rm -f $T/cps_noload $T/cps_fail $T/cps_nowatch $T/cps_nostatus $T/cp_connected $T/cp_jni_loaded
    # the kernel's TCP tables: a listening socket of the app, another process's established
    # connection, and (cp_connected) the app's established connection to a phone
    mkdir -p $T/proc/net
    cat > $T/stubs/nettcp <<'S'
#!/bin/sh
T=/tmp/eqeact
{
echo "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode"
echo "   0: 00000000:1B58 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 7000 1 00000000 100 0 0 10 0"
echo "   1: 0100007F:A1B2 0100007F:13AD 01 00000000:00000000 00:00000000 00000000  1000        0 7100 1 00000000 20 4 30 10 -1"
} > $T/proc/net/tcp
{
echo "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode"
[ -f $T/cp_connected ] && echo "   0: 000080FE00000000FF0234A2E100F23C:1B58 000080FE00000000FF0234A2E1000B3D:C4F1 01 00000000:00000000 00:00000000 00000000  1000        0 7001 1 00000000 20 4 30 10 -1"
} > $T/proc/net/tcp6
S
    chmod +x $T/stubs/nettcp; $T/stubs/nettcp
    # the app's open files: the listening socket (7000), the one a phone connects on (7001), a file
    cat > $T/stubs/dipo_fd <<'S'
#!/bin/sh
mkdir -p /tmp/eqeact/proc/$1/fd; cd /tmp/eqeact/proc/$1/fd || exit 1
ln -sf /dev/null 0; ln -sf 'socket:[7000]' 31; ln -sf 'socket:[7001]' 32
S
    chmod +x $T/stubs/dipo_fd; $T/stubs/dipo_fd 2290
    # the zygote, with TinyALSA loaded (through libmedia and libbtsound). As on the car, its
    # command line is "zygote" written over the start of the old first argument, the rest of the
    # old arguments after it; its stat names it.
    mkdir -p $T/proc/150
    printf 'zygote\0bin/app_process\0-Xzygote\0/system/bin\0--zygote\0' > $T/proc/150/cmdline
    echo "150 (zygote) S 1 150 0 0 -1 4194560 9000 0 4 0 300 120 0 0 20 0 60 0 300 893760000 18277 4294967295" > $T/proc/150/stat
    printf 'b6e00000-b6e08000 r-xp 00000000 b3:19 77   /system/lib/libtinyalsa.so\nb6f00000-b6f40000 r-xp 00000000 b3:19 100        /system/lib/libc.so\n' > $T/proc/150/maps
    # a process that calls itself zygote but is not init's child
    mkdir -p $T/proc/149
    echo "149 (zygote) S 700 149 0 0 -1 4194560 9000 0 4 0 300 120 0 0 20 0 60 0 300 893760000 18277 4294967295" > $T/proc/149/stat
    # Android's properties, by name
    cat > $T/stubs/setprop <<'S'
#!/bin/sh
T=/tmp/eqeact
echo "$1=$2" >> $T/setprop.log
if [ -z "$2" ]; then rm -f "$T/props/$1"; else printf '%s' "$2" > "$T/props/$1"; fi
S
    cat > $T/stubs/getprop <<'S'
#!/bin/sh
T=/tmp/eqeact
[ -n "$1" ] && [ -f "$T/props/$1" ] && cat "$T/props/$1"
echo
S
    # stopping the factory CarPlay app: Android starts it again (unless dipo_no_restart)
    mv $T/stubs/kill $T/stubs/kill.audio
    cat > $T/stubs/kill <<'S'
#!/bin/sh
T=/tmp/eqeact
a=$*
[ "$1" = "-9" ] && shift
d=$(cat $T/dipo_pid)
if [ "$1" = "$d" ]; then
    echo "kill $1" >> $T/dipo_kill.log
    rm -rf $T/proc/$d
    [ -f $T/dipo_no_restart ] || $T/stubs/dipo_start
    exit 0
fi
exec $T/stubs/kill.audio $a
S
    # Android starting the factory CarPlay app from the zygote: CarPlayService loads its JNI library;
    # when the watch is laid over it, the watch maps the copy of the factory library and writes its
    # status (watching, or what cps_fail / cps_nowatch / cps_nostatus / cps_noload ask for)
    cat > $T/stubs/dipo_start <<'S'
#!/bin/sh
T=/tmp/eqeact
n=$(($(cat $T/dipo_pid) + 10)); echo $n > $T/dipo_pid
mkdir -p $T/proc/$n/task/$((n + 1))
printf 'com.daudio.app.dipo\0\0\0' > $T/proc/$n/cmdline
printf 'Name:\tcom.daudio.app\nTgid:\t%s\nUid:\t1000\t1000\t1000\t1000\nGid:\t1000\t1000\t1000\t1000\n' $n > $T/proc/$n/status
cp $T/dipo_maps $T/proc/$n/maps
$T/stubs/dipo_fd $n
echo "b2800000-b2810000 r-xp 00000000 b3:19 88   /system/lib/libCarPlayAndroid.so" >> $T/proc/$n/maps
m=0
grep -q " $T/system/lib/libCarPlayAndroid.so " $T/proc/mounts && m=1
if [ $m = 1 ] && [ ! -f $T/cps_noload ]; then
    echo "b2700000-b2710000 r-xp 00000000 b3:19 89   /data/eqengine/lib/libCarPlayAndroid.car.so" >> $T/proc/$n/maps
    st=watching
    [ -f $T/cps_fail ] && st=failed
    [ -f $T/cps_nowatch ] && st="not watching"
    [ -f $T/cps_nostatus ] || printf 'version=2\npid=%s\nstate=%s\nimports=4 of 4\nhmgapi=yes\n' $n "$st" > $T/data/eqengine/cpw/status.$n
fi
echo "start $n mounted=$m" >> $T/dipo_starts.log
S
    cat > $T/stubs/am <<'S'
#!/bin/sh
T=/tmp/eqeact
echo "am $*" >> $T/am.log
[ "$1" = startservice ] && [ -f $T/dipo_nudge_only ] && [ ! -d $T/proc/$(cat $T/dipo_pid) ] && $T/stubs/dipo_start
exit 0
S
    # Android's lists of the app's services, its processes and its package entry
    mv $T/stubs/dumpsys $T/stubs/dumpsys.af
    cat > $T/stubs/dumpsys <<'S'
#!/bin/sh
T=/tmp/eqeact
d=$(cat $T/dipo_pid)
case "$*" in
    "activity services com.daudio.app.dipo")
        [ -d $T/proc/$d ] || exit 0
        echo "ACTIVITY MANAGER SERVICES (dumpsys activity services)"
        echo "  User 0 active services:"
        echo "  * ServiceRecord{42a8c1d0 u0 com.daudio.app.dipo/.telechips.CarPlayService}"
        echo "    intent={cmp=com.daudio.app.dipo/.telechips.CarPlayService}"
        echo "    app=ProcessRecord{41b8a3a0 $d:com.daudio.app.dipo/1000}"
        echo "  * ServiceRecord{42a8c2d0 u0 com.daudio.app.dipo/.DiPOService}" ;;
    "activity processes")
        echo "  *PERS* UID 1000 ProcessRecord{41b8a3a0 $d:com.daudio.app.dipo/1000}"
        echo "    PERS #44: sys   F/ /P  trm: 0 $d:com.daudio.app.dipo/1000 (fixed)"
        echo "    Proc # 3: fore  F/ /SB trm: 0 3210:com.android.phone/1001 (service)" ;;
    "package com.daudio.app.dipo")
        printf 'Packages:\n  Package [com.daudio.app.dipo] (41c2e1a0):\n    userId=1000 gids=[3003, 1028, 1015]\n    sharedUser=SharedUserSetting{41c0e8f8 android.uid.system/1000}\n    codePath=/system/app/DiPO.apk\n    versionCode=1 targetSdk=19\n    versionName=1.0\n    pkgFlags=[ SYSTEM HAS_CODE PERSISTENT ALLOW_CLEAR_USER_DATA ]\n' ;;
    *) exec $T/stubs/dumpsys.af "$@" ;;
esac
S
    # eqe_lab's check before use
    mv $T/data/eqengine/bin/eqe_lab $T/data/eqengine/bin/eqe_lab.base
    cat > $T/data/eqengine/bin/eqe_lab <<'S'
#!/bin/sh
T=/tmp/eqeact
if [ "$1" = cpcheck ]; then
    echo "cpcheck $2 $3" >> $T/cpcheck.log
    [ -f $T/cpcheck_fail ] && { echo "cpcheck failed: the factory library does not export JNI_OnLoad; TinyALSA: 7 of 7 functions"; exit 1; }
    echo "cpcheck ok the factory library exports JNI_OnLoad and needs libCarPlayAudio.so; TinyALSA: 7 of 7 functions"
    exit 0
fi
exec $T/data/eqengine/bin/eqe_lab.base "$@"
S
    chmod +x $T/stubs/* $T/data/eqengine/bin/eqe_lab
    rm -f $T/setprop.log $T/dipo_kill.log
}
cst() { sed -n "s/^$1=//p" $CS/cpwatch; }
jmounted() { grep -q " $JNI " $T/proc/mounts; }
nkill() { [ -f $T/dipo_kill.log ] && wc -l < $T/dipo_kill.log | tr -d ' ' || echo 0; }
nstart() { [ -f $T/dipo_starts.log ] && wc -l < $T/dipo_starts.log | tr -d ' ' || echo 0; }
# a car start: nothing is mounted any more, the boot step runs cpwboot before Android starts the
# CarPlay app, then the app starts (from the zygote) and the keeper's guard has a look
carstart() {
    rm -rf $T/proc/$(cat $T/dipo_pid)
    [ -f $JNI.under ] && cp $JNI.under $JNI && rm -f $JNI.under
    grep -v " $JNI " $T/proc/mounts > $T/proc/mounts.n; mv $T/proc/mounts.n $T/proc/mounts
    rm -f $CS/cpwatch $CS/cpw_restarts
    run cpwboot
    cp $T/out.txt $T/boot_out.txt
    $T/stubs/dipo_start
}
CPWF=$T/data/eqengine/lib/eqe_cpwatch.so
FMD5=$(echo "the factory CarPlay JNI library" | md5sum | cut -c1-32)

echo "-- on (from the next car start)"
cpwsetup; mkdir -p $CW; echo old > $CW/cpw_1.log
run cpwatch 1
ok "cpwatch on: checked before use with the copy, the copy is the car's file, the choice recorded for the next car start" "[ $(rc) = 0 ] && grep -q 'EQE_CPW on from the next car start; restart the car (parked) to start it. Nothing was restarted now' $T/out.txt && grep -qx 'cpcheck $CPWF $COPY' $T/cpcheck.log && [ \"\$(md5sum < $COPY | cut -c1-32)\" = $FMD5 ] && [ \"\$(cat $CS/cpw_want)\" = \"1 $FMD5 1000\" ]"
ok "cpwatch on: nothing laid over, the app not stopped, no wrap property" "! jmounted && [ $(nkill) = 0 ] && [ $(nstart) = 0 ] && [ -d $T/proc/2290 ] && [ ! -f $T/setprop.log ] && [ -z \"\$(ls $T/props)\" ]"
ok "cpwatch on: the state for the app (on from the next car start), and the app's connections noted" "[ \"\$(cst state)\" = pending ] && [ -z \"\$(cst pid)\" ] && grep -q 'EQE_CPW_NOTE the CarPlay app (pid 2290) has 0 established connections now' $T/out.txt"
carstart
ok "car start: the boot step lays the watch over the JNI library before the app starts; the last notes kept once" "[ $(rc) = 0 ] && grep -q 'EQE_CPW laid over the CarPlay app.s JNI library at the car start' $T/boot_out.txt && jmounted && cmp -s $JNI $CPWF && [ -d $CW ] && [ -f $CW.prev/cpw_1.log ] && [ \"\$(cst state)\" = waiting ]"
ok "car start: the app starts with the watch (from the zygote, nothing restarted by EQ Engine)" "grep -qx 'start 2300 mounted=1' $T/dipo_starts.log && [ -f $CW/status.2300 ] && [ $(nkill) = 0 ]"
ok "car start: the folder for the CarPlay EQ's settings is there, the app's, readable by the CarPlay app (0.7.3)" "[ -d $T/data/eqengine/share ] && [ \"\$(stat -c %a $T/data/eqengine/share)\" = 755 ] && [ \"\$(stat -c %U $T/data/eqengine/share)\" = \"\$(stat -c %U $T/data/eqengine/settings)\" ]"
run cpwguard
ok "guard: the app's first start with the watch is noted: on" "[ $(rc) = 0 ] && [ \"\$(cst state)\" = on ] && [ \"\$(cst pid)\" = 2300 ] && grep -q 'loaded in the factory CarPlay app (pid 2300), started from the zygote as usual' $CS/cpw_result && [ ! -f $CS/cpw_restarts ]"
run cpwatch 1
ok "cpwatch on while it is laid over: already on, nothing changed" "[ $(rc) = 0 ] && grep -q 'EQE_CPW already on' $T/out.txt && [ \$(grep -c \" $JNI \" $T/proc/mounts) = 1 ] && [ \"\$(cst state)\" = on ] && [ $(nstart) = 1 ]"
# what the watch writes in the app
printf 'version=2\npid=2300\nname=com.daudio.app.dipo\nstate=watching\nimports=4 of 4\nhmgapi=yes\nmain=s1 card=0 device=2 dir=out rate=44100 ch=2 fmt=s16 period=1024x4 state=open calls=812 idle_s=0 fps=44101 errs=0 peak_db=-1.2\n' > $CW/status.2300
echo "12:00:00.000 up 300.0 open s1: card 0 device 2 out, 44100 Hz 2 ch s16, period 1024 x 4, start 4096 stop 4096 -> ok" > $CW/cpw_2300.log
mkdir -p $T/usb6 $T/app
run save $T/usb6 $T/app 0
SD=$(ls -d $T/usb6/EQENGINE/*/ 2>/dev/null | head -n1)
ok "save: the watch's notes, and the last watch's" "[ $(rc) = 0 ] && [ -f ${SD}cpw_status.2300.txt ] && [ -f ${SD}cpw_cpw_2300.log.txt ] && [ -f ${SD}cpw_prev_cpw_1.log.txt ] && [ -f ${SD}state_cpwatch.txt ]"
touch $T/cp_connected; $T/stubs/nettcp
run report $T/usb6 $T/app 1
RF=$(ls $T/usb6/EQENGINE/report_*.txt 2>/dev/null | head -n1)
sed -n '/^-- CarPlay app.s audio code (symbol tables only)$/,/^====/p' "$RF" > $T/probe3.txt
ok "report: the watch's state and notes, filtered (no name line)" "grep -q '^-- CarPlay watch' \"$RF\" && grep -q '^== cpw_2300.log' \"$RF\" && grep -q 'open s1: card 0 device 2 out' \"$RF\" && grep -q '^main=s1 card=0 device=2' \"$RF\" && ! grep -q '^name=com.daudio' \"$RF\""
ok "probe: the app's user and start time, and that the watch is in it" "grep -qx '  its process: uid 1000, gid 1000, started at uptime ? s' $T/probe3.txt && grep -qx \"  EQ Engine's CarPlay watch is loaded in it (in place of libCarPlayAndroid.so; started from the zygote as usual)\" $T/probe3.txt"
ok "probe: the package's user and flags, persistent, its services" "grep -qx '  package: pkgFlags=\[ SYSTEM HAS_CODE PERSISTENT ALLOW_CLEAR_USER_DATA \]' $T/probe3.txt && grep -qx '  package: userId=1000 gids=\[3003, 1028, 1015\]' $T/probe3.txt && grep -qx '  package: codePath=/system/app/DiPO.apk' $T/probe3.txt && grep -qx '  persistent (Android starts it again at once when it stops): yes' $T/probe3.txt && grep -qx '  its running services: com.daudio.app.dipo/.telechips.CarPlayService com.daudio.app.dipo/.DiPOService' $T/probe3.txt && grep -q '  process list: \*PERS\* UID 1000' $T/probe3.txt && ! grep -q 'versionName\|com.android.phone' $T/probe3.txt"
ok "probe: its established connections: only its own, only established ones (not its listening socket, not another process's)" "grep -qx '  its established network connections (a connected CarPlay session has some): 1' $T/probe3.txt"
ok "probe: TinyALSA is in the zygote" "grep -qx '  libtinyalsa.so is loaded in the zygote (pid 150): every app has it from there' $T/probe3.txt"
ok "probe: a process whose status has none of the parent, groups or capabilities: question marks" "grep -qx '  its parent: pid ?; groups: none; effective capabilities: ?; personality: ?' $T/probe3.txt"
rm -f $T/cp_connected; $T/stubs/nettcp

echo "-- the keeper's guard (cpwguard)"
run cpwguard
ok "guard: the same app process: nothing done" "[ $(rc) = 0 ] && [ \"\$(cst pid)\" = 2300 ] && [ ! -f $CS/cpw_restarts ] && [ $(nkill) = 0 ]"
$T/stubs/kill -9 2300
run cpwguard
ok "guard: the app started again (a crash, an install): noted, the watch stays on (the mount is still there)" "[ $(rc) = 0 ] && [ \"\$(cst state)\" = on ] && [ \"\$(cst pid)\" = 2310 ] && [ \$(wc -l < $CS/cpw_restarts) = 1 ] && jmounted && grep -q 'started again (pid 2300 -> 2310); the watch stays on' $CS/cpw_result"
$T/stubs/kill -9 2310
run cpwguard
ok "guard: a second start within 2 minutes: taken off (the mount and the choice), the app not restarted by EQ Engine" "[ $(rc) = 0 ] && [ \"\$(cst state)\" = failed ] && ! jmounted && [ ! -f $CS/cpw_want ] && [ $(nstart) = 3 ] && grep -q 'taken off: the factory CarPlay app started again twice within 2 minutes with the watch; taken off (the CarPlay app.s next start and the next car start are without it)' $CS/cpw_result && [ ! -f $CS/cpw_restarts ]"
ok "guard: the take-off is noted for the app (state/cpw_failed: id, when, why; readable by it) (0.7.4)" "grep -q '^id=.*-[0-9]*$' $CS/cpw_failed && grep -q '^when=' $CS/cpw_failed && grep -qx 'why=the CarPlay app started again twice within 2 minutes with it' $CS/cpw_failed && [ \"\$(stat -c %a $CS/cpw_failed)\" = 644 ]"
carstart
ok "guard: after a take-off, the next car start is without the watch" "! jmounted && grep -qx 'start 2330 mounted=0' $T/dipo_starts.log && ! grep -q EQE_CPW $T/boot_out.txt"
cpwsetup; run cpwatch 1; touch $T/cps_fail; carstart; run cpwguard
ok "guard: the watch says the factory library did not load (nothing connected): taken off, the app restarted without it" "[ \"\$(cst state)\" = failed ] && ! jmounted && [ ! -f $CS/cpw_want ] && grep -qx 'start 2310 mounted=0' $T/dipo_starts.log && grep -q 'taken off: the watch could not load the factory library (pid 2300); taken off, and the CarPlay app restarted without it (pid 2310)' $CS/cpw_result"
cpwsetup; run cpwatch 1; touch $T/cps_fail $T/cp_connected; $T/stubs/nettcp; carstart; run cpwguard
ok "guard: the factory library did not load, but the app has a connection: taken off, not restarted, says to restart the car" "[ \"\$(cst state)\" = failed ] && ! jmounted && [ $(nstart) = 1 ] && grep -q 'the CarPlay app was not restarted (1 established connections); restart the car (parked)' $CS/cpw_result"
cpwsetup; run cpwatch 1; touch $T/cps_fail $T/dipo_no_restart $T/dipo_nudge_only; carstart; run cpwguard
ok "guard: the app restarted without the watch, Android slow to start it: its services are started after 15 s" "grep -q 'EQE_CPW_NOTE the app had not started again after 15 s; started its services' $T/out.txt && grep -qx 'am startservice -n com.daudio.app.dipo/.telechips.CarPlayService' $T/am.log && grep -qx 'start 2310 mounted=0' $T/dipo_starts.log"
cpwsetup; run cpwatch 1; touch $T/cps_nowatch; carstart; run cpwguard
ok "guard: loaded, but it left TinyALSA's functions alone: on (the app says so from the watch's status)" "[ \"\$(cst state)\" = on ] && jmounted && grep -q 'state=not watching' $CW/status.2300"
cpwsetup; run cpwatch 1; touch $T/cps_noload; carstart; run cpwguard
ok "guard: the app runs but has not loaded the watch: still waiting, nothing done" "[ \"\$(cst state)\" = waiting ] && jmounted && [ $(nkill) = 0 ]"

echo "-- off (from the next car start)"
cpwsetup; run cpwatch 1; carstart; run cpwguard
run cpwatch 0
ok "cpwatch off: the choice and the mount gone, the app not restarted (it keeps the watch until the car restarts)" "[ $(rc) = 0 ] && grep -q 'EQE_CPW off from the next car start; the CarPlay app running now keeps it until then (the EQ on CarPlay.s music too, unless its switch is off). Nothing was restarted' $T/out.txt && [ \"\$(cst state)\" = ending ] && [ \"\$(cst pid)\" = 2300 ] && ! jmounted && [ ! -f $CS/cpw_want ] && grep -q 'factory CarPlay JNI' $JNI && [ $(nkill) = 0 ] && [ $(nstart) = 1 ]"
touch $T/busy
run cpwatch 0
ok "cpwatch off again: nothing to take off, nothing restarted" "[ $(rc) = 0 ] && [ \"\$(cst state)\" = ending ] && [ $(nkill) = 0 ]"
rm -f $T/busy
carstart
ok "cpwatch off: the next car start is without it" "! jmounted && grep -qx 'start 2310 mounted=0' $T/dipo_starts.log && ! grep -q EQE_CPW $T/boot_out.txt"
run cpwatch 0
ok "cpwatch off with nothing in the app: off" "[ $(rc) = 0 ] && grep -q '^EQE_CPW off\$' $T/out.txt && [ \"\$(cst state)\" = off ]"
cpwsetup; run cpwatch 1; carstart; run cpwguard; echo 2301 > $T/other; $T/stubs/asound; touch $T/busy
run cpwatch 0
ok "cpwatch off while CarPlay plays (the app has the file loaded): detached, the app keeps running" "[ $(rc) = 0 ] && ! jmounted && grep -qx 'umount $JNI' $T/umount.log && [ $(nkill) = 0 ] && [ \"\$(cst state)\" = ending ]"
rm -f $T/other $T/busy; $T/stubs/asound

echo "-- off and on again within one car start (0.7.5)"
cpwsetup; run cpwatch 1; carstart; run cpwguard; run cpwatch 0; run cpwatch 1
ok "off and on again: the running app still has it: on for that app, laid over again for its next start, nothing restarted" "[ $(rc) = 0 ] && grep -q 'EQE_CPW on: still loaded in the CarPlay app (pid 2300); laid over again for its next start. Nothing was restarted' $T/out.txt && [ \"\$(cst state)\" = on ] && [ \"\$(cst pid)\" = 2300 ] && jmounted && [ -f $CS/cpw_want ] && [ $(nkill) = 0 ] && [ $(nstart) = 1 ]"
run cpwguard
ok "off and on again: the guard watches it again (the same app: nothing done)" "[ $(rc) = 0 ] && [ \"\$(cst state)\" = on ] && [ \"\$(cst pid)\" = 2300 ] && jmounted && [ $(nkill) = 0 ]"
carstart
ok "off and on again: the next car start lays it over as usual" "jmounted && grep -q 'EQE_CPW laid over the CarPlay app.s JNI library at the car start' $T/boot_out.txt"
cpwsetup; run cpwatch 1; carstart; run cpwguard; run cpwatch 0
echo "1 $FMD5 1000" > $CS/cpw_want; echo "the watch's notes" > $CW/keep.txt
run cpwboot
ok "the boot step while the app runs the watch from an earlier mount: laid over, the app's notes and live file left where they are" "[ $(rc) = 0 ] && jmounted && grep -q 'EQE_CPW laid over the CarPlay app.s JNI library at the car start' $T/out.txt && [ -f $CW/keep.txt ] && [ ! -f $CW.prev/keep.txt ]"

echo "-- refusals and failures"
cpwsetup; touch $CS/disabled
run cpwatch 1
ok "cpwatch on with EQ Engine off: refused, nothing recorded" "[ $(rc) = 1 ] && grep -q 'EQE_CPW refused: EQ Engine is off' $T/out.txt && [ ! -f $CS/cpw_want ] && ! jmounted"
cpwsetup; echo changed >> $CPWF
run cpwatch 1
ok "cpwatch on: a watch file that fails its md5: refused" "[ $(rc) = 1 ] && grep -q 'EQE_CPW refused: the CarPlay watch is not installed or failed its check' $T/out.txt && [ ! -f $CS/cpw_want ]"
cpwsetup; touch $T/cpcheck_fail
run cpwatch 1
ok "cpwatch on: the check before use fails: refused, with its reason" "[ $(rc) = 1 ] && grep -q 'did not pass its check before use (failed: the factory library does not export JNI_OnLoad; TinyALSA: 7 of 7 functions)' $T/out.txt && [ ! -f $CS/cpw_want ]"
ok "cpwatch on from the app's switch: a refusal is said, not noted (the app shows it at once)" "[ ! -f $CS/cpw_failed ]"
cpwsetup; touch $T/cpcheck_fail; export EQE_CPW_NOTIFY=1
run cpwatch 1
unset EQE_CPW_NOTIFY
ok "cpwatch on at the install (EQE_CPW_NOTIFY=1): a refusal is noted for the app, with its reason" "[ $(rc) = 1 ] && [ ! -f $CS/cpw_want ] && grep -q '^why=it could not be prepared: the CarPlay watch did not pass its check before use (failed: ' $CS/cpw_failed"
cpwsetup; echo 2291 > $T/other; $T/stubs/asound
run cpwatch 1
ok "cpwatch on while CarPlay plays: recorded for the next car start, the app not stopped" "[ $(rc) = 0 ] && [ -f $CS/cpw_want ] && [ $(nkill) = 0 ] && ! jmounted"
rm -f $T/other; $T/stubs/asound
cpwsetup; rm -rf $T/proc/2290
run cpwatch 1
ok "cpwatch on with the app not running: recorded (the app's user taken as 1000)" "[ $(rc) = 0 ] && [ \"\$(cat $CS/cpw_want)\" = \"1 $FMD5 1000\" ]"
cpwsetup; rm -f $JNI
run cpwatch 1
ok "cpwatch on: no factory JNI library on the unit: refused" "[ $(rc) = 1 ] && grep -q 'EQE_CPW refused: this unit has no $JNI' $T/out.txt && [ ! -f $CS/cpw_want ]"
cpwsetup; rm -f $JNI; export EQE_CPW_NOTIFY=1
run cpwatch 1
unset EQE_CPW_NOTIFY
ok "cpwatch on, a unit without the factory CarPlay app: state absent, never noted as a failure (also at the install)" "[ $(rc) = 1 ] && [ \"\$(cst state)\" = absent ] && [ ! -f $CS/cpw_failed ] && [ ! -f $CS/cpw_want ]"
cpwsetup; mkdir -p $COPY
run cpwatch 1
ok "cpwatch on: the copy cannot be made: refused" "[ $(rc) = 1 ] && grep -q 'EQE_CPW refused: the copy of the factory CarPlay library could not be made' $T/out.txt && [ ! -f $CS/cpw_want ]"
cpwsetup; run cpwatch 1; echo "an updated factory library" > $JNI; NMD5=$(md5sum < $JNI | cut -c1-32); carstart
ok "car start: the factory library changed (a software update): checked again before use, laid over, the choice follows it (0.7.4)" "grep -q 'EQE_CPW the factory CarPlay library changed (a software update?); the new one passed the check before use' $T/boot_out.txt && jmounted && [ \"\$(cat $CS/cpw_want)\" = \"1 $NMD5 1000\" ] && [ \"\$(md5sum < $COPY | cut -c1-32)\" = $NMD5 ] && [ \$(grep -c '^cpcheck ' $T/cpcheck.log) = 2 ] && [ ! -f $CS/cpw_failed ] && grep -qx 'start 2300 mounted=1' $T/dipo_starts.log"
cpwsetup; run cpwatch 1; echo "an updated factory library" > $JNI; touch $T/cpcheck_fail; carstart
ok "car start: the changed factory library fails the check: not laid over, off, and the app is told why" "grep -q 'not laid over at this start: the factory CarPlay library changed (a software update?) and the new one did not pass the check before use' $T/boot_out.txt && ! jmounted && [ ! -f $CS/cpw_want ] && [ \"\$(cst state)\" = failed ] && grep -q '^why=the factory CarPlay library changed' $CS/cpw_failed && grep -qx 'start 2300 mounted=0' $T/dipo_starts.log"
cpwsetup; run cpwatch 1; echo changed >> $CPWF; carstart
ok "car start: the watch file fails its md5: not laid over" "grep -q 'not laid over at this start: the CarPlay watch failed its check' $T/boot_out.txt && ! jmounted && [ ! -f $CS/cpw_want ]"
cpwsetup; run cpwatch 1; rm -f $COPY; carstart
ok "car start: the copy is gone: made again from the factory file, then laid over" "jmounted && [ \"\$(md5sum < $COPY | cut -c1-32)\" = $FMD5 ] && grep -qx 'start 2300 mounted=1' $T/dipo_starts.log"
cpwsetup; run cpwatch 1; echo "b2800000-b2810000 r-xp 00000000 b3:19 88   /system/lib/libCarPlayAndroid.so" >> $T/proc/2290/maps
run cpwboot
ok "car start too late: the app had already loaded its library: not laid over now, on from the next car start" "grep -q 'not laid over at this start: the CarPlay app (pid 2290) had already loaded its library; on from the next car start' $T/out.txt && ! jmounted && [ -f $CS/cpw_want ] && [ \"\$(cst state)\" = pending ]"
cpwsetup; run cpwatch 1; touch $CS/disabled
run cpwboot
ok "car start with EQ Engine off: nothing laid over" "[ $(rc) = 0 ] && ! grep -q EQE_CPW $T/out.txt && ! jmounted"
cpwsetup; run cpwatch 1; carstart; run cpwboot
ok "the boot step again in the same car start (EQ Engine turned on): nothing laid over twice" "[ $(rc) = 0 ] && ! grep -q EQE_CPW $T/out.txt && [ \$(grep -c \" $JNI \" $T/proc/mounts) = 1 ]"
cpwsetup; run cpwatch 1; carstart; run cpwguard; printf '%s' "LD_PRELOAD=$CPWF" > $T/props/wrap.com.daudio.app.dipo
run off
ok "EQ Engine off: the watch's choice and mount gone, the app not restarted, 0.6.7's wrap property cleared" "! jmounted && [ ! -f $CS/cpw_want ] && [ \"\$(cst state)\" = ending ] && [ $(nstart) = 1 ] && [ ! -f $T/props/wrap.com.daudio.app.dipo ]"
cpwsetup; mkdir -p $CS/cpwatch.lock; cut -d. -f1 $T/proc/uptime > $CS/cpwatch.lock/at
run cpwatch 1
ok "cpwatch: one switch at a time" "[ $(rc) = 3 ] && grep -q 'already being switched' $T/out.txt && [ ! -f $CS/cpw_want ]"
run cpwatch 2
ok "cpwatch with a wrong value: usage" "[ $(rc) = 2 ]"

cpwsetup
mkdir -p $T/usb7
sed -i 's/PERS/Proc/g; s/\*Proc\*/*APP*/' $T/stubs/dumpsys
run report $T/usb7 $T/app 1
RF=$(ls $T/usb7/EQENGINE/report_*.txt 2>/dev/null | head -n1)
sed -n '/^-- CarPlay app.s audio code (symbol tables only)$/,/^====/p' "$RF" > $T/probe4.txt
ok "probe: started at uptime 23 s (its stat), no watch in it, not persistent, no connection" "grep -qx '  its process: uid 1000, gid 1000, started at uptime 23 s' $T/probe4.txt && ! grep -q 'CarPlay watch is loaded' $T/probe4.txt && grep -qx '  persistent (Android starts it again at once when it stops): no' $T/probe4.txt && grep -qx '  its established network connections (a connected CarPlay session has some): 0' $T/probe4.txt"
ok "probe: its parent (the zygote, not the decoy), groups, capabilities and personality" "grep -qx '  its parent: pid 150 (the zygote); groups: 1015 3002 3003; effective capabilities: 0000000000000000; personality: 00200000' $T/probe4.txt"

echo "== no factory files copy in the release (0.7.4) under $SH"
mkdir -p $T/usbF
run factory $T/usbF
ok "factory: not an action any more: usage, nothing on the stick" "[ $(rc) != 0 ] && grep -q '^usage: act.sh' $T/out.txt && ! grep -q 'factory' $T/out.txt && [ ! -d $T/usbF/EQENGINE_FACTORY ]"

echo "$pass passed, $fail failed"
[ $fail = 0 ]
