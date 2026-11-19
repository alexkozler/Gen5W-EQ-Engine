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
    ( cd /; EQE_TEST_ROOT=$T PATH=$T/stubs:/usr/bin:/bin timeout 20 $SH $ACT "$@" > $T/out.txt 2>&1; echo $? > $T/rc )
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

echo "== Lab tests (driver watch, 48 kHz) under $SH"
CAR=${EQE_CAR:-$R/car-files}
labsetup() {  # a unit with Hyundai's driver, EQ Engine's watch layer and Lab helper, Android Auto playing
    setup; mkdumps
    mkdir -p $T/system/lib/hw $T/system/etc $T/data/eqengine/lib $T/data/eqengine/conf $T/data/eqengine/bin
    cp $CAR/audio.primary.tcc803x.so $T/system/lib/hw/
    echo "watch layer" > $T/data/eqengine/lib/eqe_drvwatch.so
    md5sum < $T/data/eqengine/lib/eqe_drvwatch.so | cut -c1-32 > $T/data/eqengine/conf/eqe_drvwatch.md5
    echo "/dev/block/system /system ext4 ro 0 0" > $T/proc/mounts
    rm -f $T/crash_at $T/crash.log $T/lab_calls.log $T/hal.log
    echo "44100 44100" > $T/rates
    echo 44100 > $T/link_rate; echo 44100 > $T/link_fps; touch $T/playing
    echo accept > $T/driver48   # how the simulated driver takes sampling_rate=48000: accept | keep | convert | mismatch | crash | sticky
    cat > $T/stubs/mount <<'S'
#!/bin/sh
# mount -o bind SRC DST
[ "$1" = "-o" ] && [ "$2" = "bind" ] || exit 1
cp "$4" "$4.under" && cp "$3" "$4" && echo "none $4 none rw 0 0" >> /tmp/eqeact/proc/mounts
S
    cat > $T/stubs/umount <<'S'
#!/bin/sh
grep -q " $1 " /tmp/eqeact/proc/mounts || exit 1
cp "$1.under" "$1" && rm -f "$1.under"
grep -v " $1 " /tmp/eqeact/proc/mounts > /tmp/eqeact/proc/mounts.n; mv /tmp/eqeact/proc/mounts.n /tmp/eqeact/proc/mounts
S
    # eqe_lab: link rates from the simulated kernel, sampling_rate through the simulated mixer and driver
    cat > $T/data/eqengine/bin/eqe_lab <<'S'
#!/bin/sh
T=/tmp/eqeact
hal() { echo "11-19 15:16:26.210 D/audio_hw_primary( $(cat $T/mspid)): $1" >> $T/hal.log; }
case "$1" in
rate)
    if [ -f $T/playing ]; then
        set -- $(cat $T/rates); echo "link pcm2p card0 state=RUNNING owner=4258 rate=$(cat $T/link_rate) fps=$(cat $T/link_fps).0"
    else echo "link none"; fi ;;
set)
    echo "set $2 $3" >> $T/lab_calls.log
    case "$3" in
    sampling_rate=48000)
        case "$(cat $T/driver48)" in
        accept|sticky) hal "sample rate  44100 is changed to 48000"; echo "48000 44100" > $T/rates; echo 48000 > $T/link_rate; echo 48000 > $T/link_fps; echo "status 0" ;;
        keep) hal "Set sampling_rate error, out->pcm_config->rate (44100)"; echo "status -22" ;;
        convert) echo "48000 44100" > $T/rates; echo "status 0" ;;
        mismatch) hal "sample rate  44100 is changed to 48000"; echo 48000 > $T/link_rate; echo 48000 > $T/link_fps; echo "status 0" ;;
        crash) p=$(cat $T/mspid); rm -rf $T/proc/$p; n=$((p + 1)); mkdir -p $T/proc/$n; echo $n > $T/mspid; echo "44100 44100" > $T/rates; echo "status -32" ;;
        esac ;;
    sampling_rate=44100)
        if [ "$(cat $T/driver48)" != sticky ]; then
            hal "sample rate  48000 is changed to 44100"; echo "44100 44100" > $T/rates; echo 44100 > $T/link_rate; echo 44100 > $T/link_fps
        fi
        echo "status 0" ;;
    esac ;;
esac
exit 0
S
    # an audio restart (kill) brings back the policy's 44100
    cat > $T/stubs/server_start <<'S'
#!/bin/sh
T=/tmp/eqeact; n=$1
echo "44100 44100" > $T/rates; echo 44100 > $T/link_rate; echo 44100 > $T/link_fps
if grep -q " $T/system/lib/hw/audio.primary.tcc803x.so " $T/proc/mounts 2>/dev/null; then
    echo "b6b00000-b6b20000 r-xp 00000000 b3:19 99   /data/eqengine/lib/hal/eqe_hal_orig.so" >> $T/proc/$n/maps
    mkdir -p $T/data/eqengine/drv; printf 'version=2\nstate=watching\n' > $T/data/eqengine/drv/status
fi
exit 0
S
    chmod +x $T/stubs/* $T/data/eqengine/bin/eqe_lab
}
LS=$T/data/eqengine/state
HALT=$T/system/lib/hw/audio.primary.tcc803x.so
nkills() { [ -f $T/kill.log ] && wc -l < $T/kill.log || echo 0; }
later() { echo "$(( $(cut -d. -f1 $T/proc/uptime) + ${1:-11} )).00 50.00" > $T/proc/uptime; }

labsetup
run lab 1 0
ok "watch: mounted over Hyundai's driver, with an exact copy of the driver kept" "[ $(rc) = 0 ] && grep -q \" $HALT \" $T/proc/mounts && [ \"\$(md5sum < $T/data/eqengine/lib/hal/eqe_hal_orig.so | cut -c1-32)\" = 4e23b3753aecde59b180b374745653a7 ]"
ok "watch: one audio restart, the new server runs Hyundai's driver behind the layer" "[ $(nkills) = 1 ] && grep -q 'EQE_LAB watch watching' $T/out.txt && grep -q ' watch' $LS/lab_active"
run lab 1 0
ok "watch again: nothing to do, no restart" "[ $(rc) = 0 ] && grep -q 'already on: watch' $T/out.txt && [ $(nkills) = 1 ]"
later
run lab 0 0
ok "off: unmounted, Hyundai's driver file back, one more restart" "[ $(rc) = 0 ] && ! grep -q \" $HALT \" $T/proc/mounts && [ \"\$(md5sum < $HALT | cut -c1-32)\" = 4e23b3753aecde59b180b374745653a7 ] && [ $(nkills) = 2 ] && [ ! -f $LS/lab_active ] && grep -q 'EQE_LAB off' $T/out.txt"

labsetup
run lab 0 1
ok "48 kHz accepted: one setting sent to the main output (io 101), no audio restart" "[ $(rc) = 0 ] && [ \"\$(cat $T/lab_calls.log)\" = 'set 101 sampling_rate=48000' ] && [ $(nkills) = 0 ]"
ok "48 kHz accepted: Android, the link setting and the measured rate all reported, with the driver's own line" "grep -q 'EQE_LAB rate48 accepted: output 101 at 48000 Hz, link pcm2p at 48000 Hz, measured 48000 frames/s; driver: sample rate  44100 is changed to 48000' $T/out.txt"
ok "48 kHz accepted: marked as on in this audio server" "grep -q rate48 $LS/lab_active && [ \"\$(cat $LS/rate48)\" = \"\$(cat $T/mspid) 101\" ]"
run lab 0 1
ok "48 kHz again: nothing to do" "[ $(rc) = 0 ] && grep -q 'already on: rate48' $T/out.txt && [ \$(wc -l < $T/lab_calls.log) = 1 ]"
later
run lab 0 0
ok "48 kHz off: 44100 sent back, both at 44.1 kHz again, no restart" "[ $(rc) = 0 ] && grep -q 'set 101 sampling_rate=44100' $T/lab_calls.log && grep -q 'EQE_LAB rate48 off: back at 44.1 kHz' $T/out.txt && [ \"\$(cat $T/rates)\" = '44100 44100' ] && [ $(nkills) = 0 ] && [ ! -f $LS/lab_active ] && [ ! -f $LS/rate48 ]"

labsetup; echo keep > $T/driver48
run lab 0 1
ok "the driver keeps 44.1 kHz: refused with its answer and its own line, nothing to undo, no restart" "[ $(rc) = 0 ] && grep -q 'EQE_LAB rate48 refused: the driver kept 44.1 kHz (driver answered -22; output 101 at 44100 Hz, link pcm2p at 44100 Hz, measured 44100 frames/s); driver: Set sampling_rate error' $T/out.txt && [ \$(wc -l < $T/lab_calls.log) = 1 ] && [ $(nkills) = 0 ] && [ ! -f $LS/lab_active ]"
labsetup; echo convert > $T/driver48
run lab 0 1
ok "Android at 48 kHz but the link at 44.1 kHz (the driver converts): refused and put back" "[ $(rc) = 0 ] && grep -q 'rate48 refused: Android runs at 48 kHz but the link stays at 44.1 kHz' $T/out.txt && grep -q 'sampling_rate=44100' $T/lab_calls.log && [ \"\$(cat $T/rates)\" = '44100 44100' ] && [ $(nkills) = 0 ]"
labsetup; echo mismatch > $T/driver48
run lab 0 1
ok "the link switched but Android did not: refused and put back" "[ $(rc) = 0 ] && grep -q \"rate48 refused: the link switched but Android's mixer did not follow\" $T/out.txt && grep -q 'sampling_rate=44100' $T/lab_calls.log && [ \"\$(cat $T/link_rate)\" = 44100 ]"
labsetup; echo sticky > $T/driver48
run lab 0 1
later
run lab 0 0
ok "44.1 kHz does not come back by itself: audio restarted to get it back" "[ $(rc) = 0 ] && grep -q 'rate48 off: audio restarted to get 44.1 kHz back' $T/out.txt && [ $(nkills) = 1 ] && [ \"\$(cat $T/rates)\" = '44100 44100' ] && [ ! -f $LS/rate48 ]"
labsetup; echo crash > $T/driver48
run lab 0 1
ok "the audio server stops after the switch: reported, marked for the boot step, not left on" "[ $(rc) = 1 ] && grep -q 'EQE_LAB failed: the audio server stopped after the 48 kHz switch' $T/out.txt && [ -f $LS/lab_ended ] && [ ! -f $LS/rate48 ] && [ ! -f $LS/lab_active ]"

labsetup; rm -f $T/playing
run lab 0 1
ok "nothing playing: not started, nothing sent" "[ $(rc) = 1 ] && grep -q 'start Android Auto' $T/out.txt && [ ! -f $T/lab_calls.log ]"
labsetup; echo "changed" >> $HALT
run lab 0 1
ok "a different Hyundai driver: the 48 kHz test is refused, nothing sent" "[ $(rc) = 1 ] && grep -q 'not the one this was built for' $T/out.txt && [ ! -f $T/lab_calls.log ]"
labsetup; rm -f $T/data/eqengine/bin/eqe_lab
run lab 0 1
ok "the helper missing: refused" "[ $(rc) = 1 ] && grep -q 'not installed' $T/out.txt"

labsetup
run lab 1 1
ok "both tests at once: one restart for the watch, then the switch in the new audio server" "[ $(rc) = 0 ] && grep -q \" $HALT \" $T/proc/mounts && [ $(nkills) = 1 ] && grep -q 'EQE_LAB watch watching' $T/out.txt && grep -q 'EQE_LAB rate48 accepted' $T/out.txt && grep -q 'watch rate48' $LS/lab_active"
later
run restart
ok "an audio restart ends the 48 kHz switch (marker gone, watch still listed)" "[ $(rc) = 0 ] && [ ! -f $LS/rate48 ] && ! grep -q rate48 $LS/lab_active && grep -q watch $LS/lab_active"
labsetup; echo "1234 101" > $LS/rate48
run lab 0 0
ok "a marker from an earlier audio server counts as off" "[ $(rc) = 0 ] && grep -q 'no Lab test is on' $T/out.txt && [ ! -f $LS/rate48 ]"

labsetup; echo "changed" >> $HALT
run lab 1 0
ok "a different Hyundai driver: the watch is refused, nothing mounted, no restart" "[ $(rc) = 1 ] && grep -q 'not the one this was built for' $T/out.txt && ! grep -q ' none ' $T/proc/mounts && [ $(nkills) = 0 ]"
labsetup; echo "changed" >> $T/data/eqengine/lib/eqe_drvwatch.so
run lab 1 0
ok "a damaged watch layer: refused" "[ $(rc) = 1 ] && grep -q 'failed its check' $T/out.txt && [ $(nkills) = 0 ]"
labsetup; mkdir -p $T/vendor/lib/hw; touch $T/vendor/lib/hw/audio.primary.tcc803x.so
run lab 1 0
ok "a vendor driver that Android would load first: refused" "[ $(rc) = 1 ] && grep -q 'would load instead' $T/out.txt && [ $(nkills) = 0 ]"
labsetup; echo x > $LS/disabled
run lab 1 0
ok "EQ Engine turned off: Lab tests refused" "[ $(rc) = 1 ] && grep -q 'EQ Engine is off' $T/out.txt && [ $(nkills) = 0 ]"
labsetup
run lab 2 0
ok "a wrong argument is rejected" "[ $(rc) = 2 ]"
labsetup
run lab 1 0
later 3
run lab 0 0
ok "the 10 s gap between restarts applies to Lab tests too (nothing changed)" "[ $(rc) = 3 ] && grep -q EQE_WAIT $T/out.txt && grep -q \" $HALT \" $T/proc/mounts"

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

echo "$pass passed, $fail failed"
[ $fail = 0 ]
