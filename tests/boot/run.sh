#!/bin/bash
# Simulated head unit for pkg/bin/boot.sh. Usage: run.sh <shell>
SH=${1:-dash}
R=$(cd "$(dirname "$0")/../.." && pwd)
BOOT=$R/pkg/bin/boot.sh
ORIG=${EQE_CAR:-$R/car-files}/audio_effects.conf
OURS=$R/pkg/conf/audio_effects.conf
T=/tmp/eqeboot
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }

setup() {
    rm -rf $T; mkdir -p $T/root/system/etc $T/root/vendor/etc $T/root/data/eqengine/lib $T/root/data/eqengine/conf $T/proc/sys/kernel/random $T/stubs
    cp $ORIG $T/root/system/etc/audio_effects.conf
    cp $OURS $T/root/data/eqengine/conf/audio_effects.conf
    echo lib > $T/root/data/eqengine/lib/libeqengine.so
    echo "100.25 50.00" > $T/proc/uptime
    echo "${1:-bootid-1}" > $T/proc/sys/kernel/random/boot_id
    echo "/dev/block/system /system ext4 ro 0 0" > $T/proc/mounts
    echo 167 > $T/mspid; mkdir -p $T/proc/167
    cat > $T/stubs/md5 <<'S'
#!/bin/sh
md5sum "$1"
S
    cat > $T/stubs/mount <<'S'
#!/bin/sh
# mount -o bind SRC DST
[ "$1" = "-o" ] && [ "$2" = "bind" ] || exit 1
cp "$4" "$4.under.$$" && cp "$3" "$4" && echo "$4.under.$$" >> /tmp/eqeboot/stack && echo "none $4 none rw 0 0" >> /tmp/eqeboot/proc/mounts
S
    cat > $T/stubs/umount <<'S'
#!/bin/sh
last=$(tail -n1 /tmp/eqeboot/stack 2>/dev/null); [ -n "$last" ] || exit 1
cp "$last" "$1"; rm -f "$last"; sed -i '$d' /tmp/eqeboot/stack
grep -n " $1 " /tmp/eqeboot/proc/mounts | tail -n1 | cut -d: -f1 | while read n; do sed -i "${n}d" /tmp/eqeboot/proc/mounts; done
S
    cat > $T/stubs/ps <<'S'
#!/bin/sh
echo "USER     PID   PPID  VSIZE  RSS     WCHAN    PC         NAME"
echo "root      1     0     1000   500   ffffffff 00000000 S /init"
p=$(cat /tmp/eqeboot/mspid); [ -d /tmp/eqeboot/proc/$p ] && echo "media     $p   1     33148  9784  ffffffff b6ea0870 S /system/bin/mediaserver"
[ -f /tmp/eqeboot/app_running ] && echo "u0_a85    2100  160   512000 40000 ffffffff b6ea0870 S com.eqengine.app"
exit 0
S
    cat > $T/stubs/sleep <<'S'
#!/bin/sh
read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; echo "$((u + $1)).10 50.00" > /tmp/eqeboot/proc/uptime
[ -f /tmp/eqeboot/hook ] && . /tmp/eqeboot/hook
/bin/sleep 0.02
S
    mkdir -p $T/props
    cat > $T/stubs/getprop <<'S'
#!/bin/sh
cat "/tmp/eqeboot/props/$1" 2>/dev/null
exit 0
S
    cat > $T/stubs/setprop <<'S'
#!/bin/sh
echo "$2" > "/tmp/eqeboot/props/$1"; echo "$1=$2" >> /tmp/eqeboot/setprop.log
S
    cat > $T/stubs/am <<'S'
#!/bin/sh
echo "$*" >> /tmp/eqeboot/am.log
echo "Starting service: Intent { cmp=$3 }"
S
    cat > $T/stubs/logcat <<'S'
#!/bin/sh
# Like Android 4.4's logcat: getopt("cdt:gsQf:r::n:v:b:B") without reordering, so options are
# read only up to the first non-option (a tag:level filter); -r takes its value only when attached.
echo "$*" >> /tmp/eqeboot/logcat.log
f=""
while [ $# -gt 0 ]; do
    case "$1" in
        -f|-t|-n|-v|-b) [ "$1" = "-f" ] && f=$2; shift 2 ;;
        -f*) f=${1#-f}; shift ;;
        -r*|-c|-d|-g|-s|-Q|-B) shift ;;
        -*) echo "logcat stub: unknown option $1" >&2; exit 1 ;;
        *) break ;;
    esac
done
[ -n "$f" ] && echo "11-18 16:00:00.000 D/AudioResampler(  166): forcing AudioResampler quality to 3" > "$f"
exit 0
S
    # the 48 kHz keeper: notes that it was started and shows up as a process (in the simulated /proc)
    cat > $T/stubs/keeper <<'S'
#!/bin/sh
mkdir -p /tmp/eqeboot/proc/$$; echo "keeper $$" >> /tmp/eqeboot/keeper.log
S
    chmod +x $T/stubs/*; : > $T/stack; rm -f $T/setprop.log $T/am.log $T/logcat.log $T/keeper.log
}
runboot() {  # runs until the script exits or ~$1 simulated seconds pass
    # exec: $BP is the boot step itself, so the kill below stops it (a leftover run would write into the next test)
    ( cd /; EQE_TEST_ROOT=$T/root EQE_PROC=$T/proc EQE_KEEP_CMD=$T/stubs/keeper PATH=$T/stubs:/usr/bin:/bin exec $SH $BOOT > $T/out.txt 2>&1 ) &
    BP=$!
    # generous real-time budget: the scripts end by themselves (stop_here) in the tests that need it
    i=0; while kill -0 $BP 2>/dev/null && [ $i -lt $(( ${1:-300} * 4 )) ]; do /bin/sleep 0.05; i=$((i+1)); done
    kill $BP 2>/dev/null; wait $BP 2>/dev/null
}
st() { sed -n "s/^$1=//p" $T/root/data/eqengine/state/status; }
tm() { md5sum < $T/root/system/etc/audio_effects.conf | cut -c1-32; }
ORIGMD5=4d98c1b38bd1d9eaf929d9b616c0d118; OURSMD5=69613834029b0e891c927e5843077c0d

echo "== 1. normal start: applies, confirms good, then turned off by the app"
setup bootA
cat > $T/hook <<'H'
read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}
[ $u -ge 200 ] && echo "turned off in the app" > /tmp/eqeboot/root/data/eqengine/state/disabled
H
runboot 400
ok "overlay was applied (event)" "grep -q 'overlay applied' $T/out.txt"
ok "confirmed good" "grep -q 'confirmed good' $T/out.txt"
ok "lastboot ends 'off' after turn-off" "grep -q 'bootA off' $T/root/data/eqengine/state/lastboot"
ok "state off, overlay removed" "[ \"\$(st state)\" = off ] && [ \"\$(st overlay)\" = 0 ]"
ok "stock list back" "[ \"\$(tm)\" = $ORIGMD5 ] && ! grep -q audio_effects $T/proc/mounts"

echo "== 2. next start while turned off: skipped"
rm -f $T/hook; echo bootB > $T/proc/sys/kernel/random/boot_id
runboot 50
ok "state off, no mount" "[ \"\$(st state)\" = off ] && ! grep -q audio_effects $T/proc/mounts"

echo "== 3. two strikes: two starts ended before 'good'"
setup bootC
mkdir -p $T/root/data/eqengine/state; echo "bootOLD applied" > $T/root/data/eqengine/state/lastboot; echo 1 > $T/root/data/eqengine/state/strikes
runboot 50
ok "turned itself off" "[ \"\$(st state)\" = off ] && [ -f $T/root/data/eqengine/state/disabled ]"
ok "never mounted" "[ \"\$(tm)\" = $ORIGMD5 ] && ! grep -q audio_effects $T/proc/mounts"
echo "   one strike only:"
setup bootD
mkdir -p $T/root/data/eqengine/state; echo "bootOLD applied" > $T/root/data/eqengine/state/lastboot
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 300 ] && echo x > /tmp/eqeboot/root/data/eqengine/state/disabled' > $T/hook
runboot 400
ok "one strike still applies" "grep -q 'overlay applied' $T/out.txt && grep -q 'strike 1' $T/out.txt"
ok "good resets strikes" "[ \"\$(cat $T/root/data/eqengine/state/strikes)\" = 0 ]"

echo "== 4. stock list differs (firmware changed): refused"
setup bootE; echo "# changed" >> $T/root/system/etc/audio_effects.conf
runboot 50
ok "refused, nothing mounted" "[ \"\$(st state)\" = refused ] && ! grep -q audio_effects $T/proc/mounts"
ok "not counted as a strike next time" "grep -q 'bootE refused' $T/root/data/eqengine/state/lastboot"

echo "== 5. damaged copy: refused"
setup bootF; echo "x" >> $T/root/data/eqengine/conf/audio_effects.conf
runboot 50
ok "refused" "[ \"\$(st state)\" = refused ] && ! grep -q audio_effects $T/proc/mounts"

echo "== 6. vendor list present: refused"
setup bootG; cp $ORIG $T/root/vendor/etc/audio_effects.conf
runboot 50
ok "refused" "[ \"\$(st state)\" = refused ] && ! grep -q audio_effects $T/proc/mounts"

echo "== 7. audio server crashes twice within 60 s: removes itself"
setup bootH
cat > $T/hook <<'H'
read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}
n=$(cat /tmp/eqeboot/crashes 2>/dev/null || echo 0)
if [ $u -ge 110 ] && [ $n -lt 2 ] && [ $u -ge $((110 + n * 20)) ]; then
  p=$(cat /tmp/eqeboot/mspid); rmdir /tmp/eqeboot/proc/$p; p=$((p + 1)); mkdir -p /tmp/eqeboot/proc/$p; echo $p > /tmp/eqeboot/mspid; echo $((n + 1)) > /tmp/eqeboot/crashes
fi
H
runboot 400
ok "detected crashes" "grep -q 'restarted unexpectedly (2' $T/out.txt"
ok "state crashed, disabled, overlay removed" "[ \"\$(st state)\" = crashed ] && [ -f $T/root/data/eqengine/state/disabled ] && [ \"\$(tm)\" = $ORIGMD5 ]"
ok "lastboot crashed" "grep -q 'bootH crashed' $T/root/data/eqengine/state/lastboot"

echo "== 8. restart requested by the app is not a crash"
setup bootI
cat > $T/hook <<'H'
read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}
if [ $u -ge 120 ] && [ ! -f /tmp/eqeboot/done8 ]; then
  echo $u > /tmp/eqeboot/root/data/eqengine/state/expected_restart
  p=$(cat /tmp/eqeboot/mspid); rmdir /tmp/eqeboot/proc/$p; p=$((p + 1)); mkdir -p /tmp/eqeboot/proc/$p; echo $p > /tmp/eqeboot/mspid; touch /tmp/eqeboot/done8
fi
[ $u -ge 300 ] && echo x > /tmp/eqeboot/root/data/eqengine/state/disabled
H
runboot 400
ok "logged as requested" "grep -q 'restarted on request' $T/out.txt"
ok "no unexpected restarts, still confirmed good" "! grep -q unexpectedly $T/out.txt && grep -q 'confirmed good' $T/out.txt"

echo "== 9. service restarted within the same start: no second mount"
setup bootJ
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 130 ] && touch /tmp/eqeboot/stop' > $T/hook
( cd /; EQE_TEST_ROOT=$T/root EQE_PROC=$T/proc EQE_KEEP_CMD=$T/stubs/keeper PATH=$T/stubs:/usr/bin:/bin exec $SH $BOOT > $T/out1.txt 2>&1 ) & P1=$!
while [ ! -f $T/stop ]; do /bin/sleep 0.05; done; kill $P1; wait $P1 2>/dev/null
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 200 ] && echo x > /tmp/eqeboot/root/data/eqengine/state/disabled' > $T/hook
runboot 400
ok "second run saw the overlay already in place" "grep -q 'already in place' $T/out.txt"
ok "exactly one mount was made, and it was removed" "[ \$(grep -c 'overlay applied' $T/out1.txt) = 1 ] && [ \"\$(tm)\" = $ORIGMD5 ] && [ ! -s $T/stack ]"


echo "== 10. converter: high quality by default, recorded; Android default when set to 0"
setup bootK
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 160 ] && echo x > /tmp/eqeboot/root/data/eqengine/state/disabled' > $T/hook
runboot 400
ok "set to 3 after the overlay" "grep -q 'af.resampler.quality=3' $T/setprop.log && grep -q 'high quality requested' $T/out.txt"
ok "confirmation capture started" "grep -q 'AudioResampler:D' $T/logcat.log && grep -q 'quality to 3' $T/root/data/eqengine/state/resampler.log"
ok "turning off puts it back to 0" "[ \"\$(tail -n1 $T/setprop.log)\" = af.resampler.quality=0 ] && [ \"\$(st converter)\" = 0 ]"
setup bootL; mkdir -p $T/root/data/eqengine/settings; echo 0 > $T/root/data/eqengine/settings/resampler
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 160 ] && echo x > /tmp/eqeboot/root/data/eqengine/state/disabled' > $T/hook
runboot 400
ok "an old settings file asking for 0 is ignored: still high quality" "grep -q 'af.resampler.quality=3' $T/setprop.log && grep -q 'AudioResampler:D' $T/logcat.log"
setup bootM; echo "# changed" >> $T/root/system/etc/audio_effects.conf
runboot 50
ok "refused: converter not touched" "[ ! -f $T/setprop.log ]"

echo "== 11. the EQ service is started once, after Android has finished starting"
setup bootN; touch $T/app_running
cat > $T/hook <<'H'
read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}
[ $u -ge 150 ] && echo 1 > /tmp/eqeboot/props/sys.boot_completed
[ $u -ge 260 ] && echo x > /tmp/eqeboot/root/data/eqengine/state/disabled
H
runboot 400
ok "started exactly once" "[ \$(grep -c 'startservice -n com.eqengine.app/.EqService' $T/am.log) = 1 ]"
ok "not before boot completed" "grep -q 'Android has started; starting the EQ service: Starting service' $T/out.txt && [ \$(sed -n 's/^\([0-9]*\) Android has started.*/\1/p' $T/root/data/eqengine/state/events.log) -ge 150 ]"
setup bootO; mkdir -p $T/root/data/eqengine/state; echo x > $T/root/data/eqengine/state/disabled
echo 1 > $T/props/sys.boot_completed
runboot 50
ok "turned off: service not started" "[ ! -f $T/am.log ]"

echo "== 12. crash watch also puts the converter back to 0"
setup bootP
cat > $T/hook <<'H'
read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}
n=$(cat /tmp/eqeboot/crashes 2>/dev/null || echo 0)
if [ $u -ge 110 ] && [ $n -lt 2 ] && [ $u -ge $((110 + n * 20)) ]; then
  p=$(cat /tmp/eqeboot/mspid); rmdir /tmp/eqeboot/proc/$p; p=$((p + 1)); mkdir -p /tmp/eqeboot/proc/$p; echo $p > /tmp/eqeboot/mspid; echo $((n + 1)) > /tmp/eqeboot/crashes
fi
H
runboot 400
ok "crashed and converter reset" "[ \"\$(st state)\" = crashed ] && [ \"\$(tail -n1 $T/setprop.log)\" = af.resampler.quality=0 ]"

echo "== 13. state files are not writable by other users"
setup bootQ; mkdir -p $T/root/data/eqengine/state; echo 0 > $T/root/data/eqengine/state/strikes; chmod 666 $T/root/data/eqengine/state/strikes
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 120 ] && echo x > /tmp/eqeboot/root/data/eqengine/state/disabled' > $T/hook
runboot 400
ok "strikes and events.log are 644" "[ \"\$(stat -c %a $T/root/data/eqengine/state/strikes)\" = 644 ] && [ \"\$(stat -c %a $T/root/data/eqengine/state/events.log)\" = 644 ]"


echo "== 14. watchdog: the EQ service is started again if the app's process is gone"
setup bootR; touch $T/app_running
cat > $T/hook <<'H'
read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}
[ $u -ge 110 ] && echo 1 > /tmp/eqeboot/props/sys.boot_completed
[ $u -ge 200 ] && rm -f /tmp/eqeboot/app_running
[ $u -ge 420 ] && echo x > /tmp/eqeboot/root/data/eqengine/state/disabled
H
runboot 600
ok "not restarted while the app ran" "[ \$(sed -n 's/^\\([0-9]*\\) the EQ service was not running.*/\\1/p' $T/root/data/eqengine/state/events.log | head -n1) -ge 200 ]"
ok "restarted after the app's process went away" "grep -q 'the EQ service was not running; starting it again' $T/out.txt && [ \$(grep -c 'startservice' $T/am.log) -ge 2 ]"
setup bootS; touch $T/app_running
cat > $T/hook <<'H'
read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}
[ $u -ge 110 ] && echo 1 > /tmp/eqeboot/props/sys.boot_completed
[ $u -ge 420 ] && echo x > /tmp/eqeboot/root/data/eqengine/state/disabled
H
runboot 600
ok "app running all along: started once only" "[ \$(grep -c 'startservice' $T/am.log) = 1 ]"

echo "== 15. a new start clears the previous start's converter lines and restart bookkeeping"
setup bootid-7
rm -f $T/hook
mkdir -p $T/root/data/eqengine/state
echo "11-18 19:28:01.120 D/AudioResampler(  167): forcing AudioResampler quality to 0" > $T/root/data/eqengine/state/resampler_now.log
echo 700 > $T/root/data/eqengine/state/last_restart
echo bootid-6 > $T/root/data/eqengine/state/runboot
runboot 40
ok "new start: old converter lines and restart time removed" "[ ! -f $T/root/data/eqengine/state/resampler_now.log ] && [ ! -f $T/root/data/eqengine/state/last_restart ] && [ \"\$(cat $T/root/data/eqengine/state/runboot)\" = bootid-7 ]"
echo "x" > $T/root/data/eqengine/state/resampler_now.log
echo 120 > $T/root/data/eqengine/state/last_restart
runboot 40
ok "a second run in the same start keeps them" "[ -f $T/root/data/eqengine/state/resampler_now.log ] && [ -f $T/root/data/eqengine/state/last_restart ]"

echo "== 16. very high quality: switched on, tables check out, loaded right away by the probe"
vhqsetup() {  # $1 = setting (empty = no file); $2 = good | bad (tables checksum); $3 = map (the audio server has the tables mapped) | nomap
    mkdir -p $T/root/data/eqengine/settings
    echo tables > $T/root/data/eqengine/lib/libaudio-resampler.so
    md5sum < $T/root/data/eqengine/lib/libaudio-resampler.so | cut -c1-32 > $T/root/data/eqengine/conf/libaudio-resampler.md5
    [ "$2" = bad ] && echo "changed" >> $T/root/data/eqengine/lib/libaudio-resampler.so
    [ -n "$1" ] && echo $1 > $T/root/data/eqengine/settings/vhq
    if [ "$3" = map ]; then
        echo "b6c00000-b6c06000 r-xp 00000000 b3:19 4243   /data/eqengine/lib/libeqengine.so" > $T/proc/$(cat $T/mspid)/maps
        echo "b6a00000-b6a2a000 r-xp 00000000 b3:19 4242   /data/eqengine/lib/libaudio-resampler.so" >> $T/proc/$(cat $T/mspid)/maps
    fi
    return 0
}
VS=$T/root/data/eqengine/state; VSET=$T/root/data/eqengine/settings
setup bootV1; vhqsetup 1 good map
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 160 ] && echo x > /tmp/eqeboot/root/data/eqengine/state/disabled' > $T/hook
runboot 400
ok "asks for very high quality (4)" "grep -q 'af.resampler.quality=4' $T/setprop.log && ! grep -q 'af.resampler.quality=3' $T/setprop.log && grep -q 'very high quality requested' $T/out.txt"
ok "after 'confirmed good' it checks the tables are in the audio server" "grep -q 'tables are loaded in the audio server (167)' $T/out.txt"
ok "turning off removes the marker and puts the converter back to 0" "[ ! -f $VS/vhq_load ] && [ \"\$(tail -n1 $T/setprop.log)\" = af.resampler.quality=0 ]"
setup bootV1b; vhqsetup 1 good map
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 140 ] && touch /tmp/eqeboot/stop' > $T/hook
( cd /; EQE_TEST_ROOT=$T/root EQE_PROC=$T/proc EQE_KEEP_CMD=$T/stubs/keeper PATH=$T/stubs:/usr/bin:/bin exec $SH $BOOT > $T/out.txt 2>&1 ) & P1=$!
while [ ! -f $T/stop ]; do /bin/sleep 0.05; done
ok "while it runs, the marker for the filter is there (readable by the audio server)" "[ -f $VS/vhq_load ] && [ \"\$(stat -c %a $VS/vhq_load)\" = 644 ]"
kill $P1; wait $P1 2>/dev/null

setup bootV1c; vhqsetup 1 good nomap; mkdir -p $VS; echo 1 > $VS/vhq_load; ino0=$(stat -c %i $VS/vhq_load)
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 140 ] && touch /tmp/eqeboot/stop' > $T/hook
( cd /; EQE_TEST_ROOT=$T/root EQE_PROC=$T/proc EQE_KEEP_CMD=$T/stubs/keeper PATH=$T/stubs:/usr/bin:/bin exec $SH $BOOT > $T/out.txt 2>&1 ) & P1=$!
while [ ! -f $T/stop ]; do /bin/sleep 0.05; done; kill $P1; wait $P1 2>/dev/null
ok "a marker kept from the last start is rewritten in place, never removed (same file)" "[ -f $VS/vhq_load ] && [ \$(stat -c %i $VS/vhq_load) = $ino0 ]"
setup bootV1d; vhqsetup 1 good nomap
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 160 ] && echo x > /tmp/eqeboot/root/data/eqengine/state/disabled' > $T/hook
runboot 400
ok "tables not in the audio server at 'confirmed good': says so" "grep -q 'tables are not loaded in the audio server (167)' $T/out.txt"
setup bootV1e; vhqsetup 1 good nomap
echo "b6b00000-b6b20000 r-xp 00000000 b3:19 99   /system/lib/libaudioflinger.so" > $T/proc/167/maps
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 160 ] && echo x > /tmp/eqeboot/root/data/eqengine/state/disabled' > $T/hook
runboot 400
ok "the audio server read its effects list before the overlay (0.6.3's middle car start): says EQ Engine is not active, restart audio (parked)" "grep -q 'confirmed good' $T/out.txt && grep -q \"EQ Engine's filter is not loaded in the audio server (167): it read its effects list before the overlay. Restart Android audio once (parked)\" $T/out.txt && ! grep -q 'tables are' $T/out.txt"

echo "== 17. very high quality: tables fail their check -> high quality, no marker"
setup bootV2; vhqsetup 1 bad map
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 140 ] && touch /tmp/eqeboot/stop' > $T/hook
( cd /; EQE_TEST_ROOT=$T/root EQE_PROC=$T/proc EQE_KEEP_CMD=$T/stubs/keeper PATH=$T/stubs:/usr/bin:/bin exec $SH $BOOT > $T/out.txt 2>&1 ) & P1=$!
while [ ! -f $T/stop ]; do /bin/sleep 0.05; done; kill $P1; wait $P1 2>/dev/null
ok "falls back to 3, says why, no marker" "grep -q 'af.resampler.quality=3' $T/setprop.log && ! grep -q 'quality=4' $T/setprop.log && grep -q 'failed their check' $T/out.txt && [ ! -f $VS/vhq_load ]"

echo "== 18. very high quality switched off (or never on): high quality, nothing loaded"
setup bootV3; vhqsetup 0 good map
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 140 ] && touch /tmp/eqeboot/stop' > $T/hook
mkdir -p $VS; echo 1 > $VS/vhq_load
( cd /; EQE_TEST_ROOT=$T/root EQE_PROC=$T/proc EQE_KEEP_CMD=$T/stubs/keeper PATH=$T/stubs:/usr/bin:/bin exec $SH $BOOT > $T/out.txt 2>&1 ) & P1=$!
while [ ! -f $T/stop ]; do /bin/sleep 0.05; done; kill $P1; wait $P1 2>/dev/null
ok "setting 0: 3, a leftover marker is removed" "grep -q 'af.resampler.quality=3' $T/setprop.log && ! grep -q 'quality=4' $T/setprop.log && [ ! -f $VS/vhq_load ]"

crashhook() {  # $1 $2 ... = uptimes of unexpected audio server restarts; stop at $STOPAT
    { echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}'
      for c in "$@"; do
        echo "if [ \$u -ge $c ] && [ ! -f /tmp/eqeboot/crashed_$c ]; then p=\$(cat /tmp/eqeboot/mspid); rm -rf /tmp/eqeboot/proc/\$p; p=\$((p + 1)); mkdir -p /tmp/eqeboot/proc/\$p; echo \$p > /tmp/eqeboot/mspid; touch /tmp/eqeboot/crashed_$c; fi"
      done
      echo "[ \$u -ge ${STOPAT:-260} ] && touch /tmp/eqeboot/stop"; } > $T/hook
}
rununtilstop() {
    ( cd /; EQE_TEST_ROOT=$T/root EQE_PROC=$T/proc EQE_KEEP_CMD=$T/stubs/keeper PATH=$T/stubs:/usr/bin:/bin exec $SH $BOOT > $T/out.txt 2>&1 ) & P1=$!
    while [ ! -f $T/stop ]; do /bin/sleep 0.05; done; kill $P1; wait $P1 2>/dev/null
}

echo "== 19. very high quality: one unexpected audio server restart steps it down to high quality"
setup bootV4; vhqsetup 1 good map
crashhook 130; rununtilstop
ok "stepped down: converter 3 kept in the settings, marker gone, reason kept for the app" "[ \"\$(cat $VSET/converter)\" = 3 ] && [ ! -f $VS/vhq_load ] && [ \"\$(tail -n1 $T/setprop.log)\" = af.resampler.quality=3 ] && grep -q 'restarted unexpectedly' $VS/conv_cut"
ok "one crash alone does not turn EQ Engine off" "[ ! -f $VS/disabled ] && grep -q 'stepped down to 3' $T/out.txt"
ok "the setting and the reason stay readable by the app" "[ \"\$(stat -c %a $VSET/converter)\" = 644 ] && [ \"\$(stat -c %a $VS/conv_cut)\" = 644 ]"

echo "== 20. very high quality chosen later in the app (marker and 4 for the next start): a crash steps it down"
setup bootV5; vhqsetup 0 good map
crashhook 140
cat >> $T/hook <<'H'
[ $u -ge 120 ] && [ ! -f /tmp/eqeboot/armed ] && { echo 4 > /tmp/eqeboot/root/data/eqengine/settings/converter; echo 1 > /tmp/eqeboot/root/data/eqengine/state/vhq_load; echo 4 > /tmp/eqeboot/props/af.resampler.quality; touch /tmp/eqeboot/armed; }
H
rununtilstop
ok "chosen later, then a crash: converter 3, marker gone" "[ \"\$(cat $VSET/converter)\" = 3 ] && [ ! -f $VS/vhq_load ]"

echo "== 21. converter choices at a start: default, stock, an old 0.5 setting"
setup bootV6; vhqsetup "" good nomap
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 140 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "no setting at all: very high quality (the default)" "grep -q 'af.resampler.quality=4' $T/setprop.log && [ -f $VS/vhq_load ]"
setup bootV7; vhqsetup "" good nomap; echo 0 > $VSET/converter
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 140 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "stock chosen: 0, no marker, the confirmation capture still runs" "grep -q 'af.resampler.quality=0' $T/setprop.log && ! grep -q 'quality=[34]' $T/setprop.log && [ ! -f $VS/vhq_load ] && grep -q 'AudioResampler:D' $T/logcat.log"
setup bootV8; vhqsetup 0 good nomap
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 140 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "0.5 setting vhq=0: high quality" "grep -q 'af.resampler.quality=3' $T/setprop.log && ! grep -q 'quality=4' $T/setprop.log"
setup bootV9; vhqsetup "" bad nomap
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 140 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "default with damaged tables: high quality this start, reason for the app, setting unchanged" "grep -q 'af.resampler.quality=3' $T/setprop.log && grep -q 'failed their check' $VS/conv_fallback && [ ! -f $VSET/converter ]"

echo "== 22. two unexpected restarts 90 s apart: very high -> high -> stock, EQ Engine stays on"
setup bootW1; vhqsetup 1 good map
STOPAT=330 crashhook 130 220; rununtilstop
ok "stepped down twice: converter 0 kept, property 0" "[ \"\$(cat $VSET/converter)\" = 0 ] && [ \"\$(tail -n1 $T/setprop.log)\" = af.resampler.quality=0 ] && [ \$(grep -c 'stepped down' $T/out.txt) = 2 ]"
ok "two restarts more than 60 s apart do not turn EQ Engine off" "[ ! -f $VS/disabled ]"

echo "== 23. a Lab test on when the audio server crashes: the test is removed, nothing else counts"
setup bootW2; vhqsetup 1 good map
mkdir -p $T/root/system/lib/hw; echo "hyundai driver" > $T/root/system/lib/hw/audio.primary.tcc803x.so
cat > $T/root/data/eqengine/watch.so <<'X'
watch layer
X
STOPAT=300 crashhook 150 160
cat >> $T/hook <<'H'
if [ $u -ge 140 ] && [ ! -f /tmp/eqeboot/labon ]; then
  mount -o bind /tmp/eqeboot/root/data/eqengine/watch.so /tmp/eqeboot/root/system/lib/hw/audio.primary.tcc803x.so
  echo " watch" > /tmp/eqeboot/root/data/eqengine/state/lab_active; touch /tmp/eqeboot/labon
fi
H
rununtilstop
ok "the driver watch was removed (Hyundai's driver file back)" "[ \"\$(cat $T/root/system/lib/hw/audio.primary.tcc803x.so)\" = 'hyundai driver' ] && ! grep -q 'audio.primary' $T/proc/mounts && [ ! -f $VS/lab_active ]"
ok "the app gets the reason" "grep -q 'watch was on when the audio server restarted unexpectedly' $VS/lab_result"
ok "two crashes 10 s apart during the test: no step-down, EQ Engine stays on" "[ ! -f $VSET/converter ] && [ ! -f $VS/disabled ] && [ -f $VS/vhq_load ] && [ \$(grep -c 'during a Lab test' $T/out.txt) = 2 ]"

echo "== 23b. a crash just after act.sh ended a failed Lab test: put down to the test"
setup bootW4; vhqsetup 1 good map
STOPAT=260 crashhook 150
cat >> $T/hook <<'H'
[ $u -ge 148 ] && [ ! -f /tmp/eqeboot/ended ] && { echo $u > /tmp/eqeboot/root/data/eqengine/state/lab_ended; touch /tmp/eqeboot/ended; }
H
rununtilstop
ok "no step-down, not counted" "[ ! -f $VSET/converter ] && [ -f $VS/vhq_load ] && grep -q 'during a Lab test' $T/out.txt && ! grep -q 'unexpectedly (1' $T/out.txt"

echo "== 24. a new start: no Lab test, the last result kept as the previous one"
setup bootW3; mkdir -p $VS; echo " watch" > $VS/lab_active; echo "100 watch watching" > $VS/lab_result; echo bootW2 > $VS/runboot
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 120 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "lab_active cleared, lab_result moved to lab_result.prev" "[ ! -f $VS/lab_active ] && [ ! -f $VS/lab_result ] && grep -q 'watch watching' $VS/lab_result.prev"

echo "== 25. the start right after an install: a car restart before 'good' is not a strike"
setup bootI1; mkdir -p $VS; echo installed > $VS/fresh_install
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 120 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "that start is marked 'installed' and the marker is used up" "grep -q 'bootI1 installed' $VS/lastboot && [ ! -f $VS/fresh_install ]"
rm -f $T/stop; echo bootI2 > $T/proc/sys/kernel/random/boot_id
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 240 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "the next start counts no strike and is confirmed good" "grep -q \"install's\" $T/out.txt && ! grep -q 'strike 1' $T/out.txt && [ \"\$(cat $VS/strikes)\" = 0 ] && grep -q 'bootI2 good' $VS/lastboot"
echo "   right after an install the running audio server cannot have the filter yet: said so, not as a fault"
setup bootI4; mkdir -p $VS; echo installed > $VS/fresh_install
echo "b6b00000-b6b20000 r-xp 00000000 b3:19 99   /system/lib/libaudioflinger.so" > $T/proc/167/maps
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 160 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "just installed: confirmed good, and the audio server is said to load EQ Engine at the next car start or audio restart" "grep -q 'confirmed good' $T/out.txt && grep -q 'just installed: the running audio server (167) started before EQ Engine was installed; it loads EQ Engine at the next car start or audio restart (parked)' $T/out.txt && ! grep -q 'read its effects list before the overlay' $T/out.txt && grep -q 'just installed' $VS/status"
setup bootI5; mkdir -p $VS; echo installed > $VS/fresh_install
echo "b6b00000-b6b20000 r-xp 00000000 b3:19 99   /system/lib/libaudioflinger.so" > $T/proc/167/maps
cat > $T/hook <<'H'
read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}
if [ $u -ge 120 ] && [ ! -f /tmp/eqeboot/done_r ]; then
  echo $u > /tmp/eqeboot/root/data/eqengine/state/expected_restart
  rm -rf /tmp/eqeboot/proc/167; mkdir -p /tmp/eqeboot/proc/168; echo 168 > /tmp/eqeboot/mspid; touch /tmp/eqeboot/done_r
  echo "b6b00000-b6b20000 r-xp 00000000 b3:19 99   /system/lib/libaudioflinger.so" > /tmp/eqeboot/proc/168/maps
fi
[ $u -ge 200 ] && touch /tmp/eqeboot/stop
H
rununtilstop
ok "just installed, but a later audio server (restarted after the install) has no filter either: the usual message" "grep -q 'restarted on request' $T/out.txt && grep -q \"EQ Engine's filter is not loaded in the audio server (168): it read its effects list before the overlay\" $T/out.txt && ! grep -q 'just installed' $T/out.txt"
echo "   the marker only covers the run right after the install:"
setup bootI3; mkdir -p $VS; echo installed > $VS/fresh_install; echo "turned off in the app" > $VS/disabled
runboot 50
ok "used up even when EQ Engine is off" "[ ! -f $VS/fresh_install ] && [ \"\$(st state)\" = off ]"

echo "== 26. the 48 kHz keeper: started once Android has started, and again if it stops"
setup bootK1; touch $T/app_running
cat > $T/hook <<'H'
read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}
[ $u -ge 110 ] && echo 1 > /tmp/eqeboot/props/sys.boot_completed
if [ $u -ge 200 ] && [ ! -f /tmp/eqeboot/killed ]; then rm -rf /tmp/eqeboot/proc/$(head -n1 /tmp/eqeboot/keeper.log | cut -d' ' -f2); touch /tmp/eqeboot/killed; fi
[ $u -ge 330 ] && touch /tmp/eqeboot/stop
H
rununtilstop
ok "started with the EQ service, its pid recorded" "grep -q '48 kHz output keeper started' $T/out.txt && [ \"\$(cat $VS/keep.pid)\" -gt 0 ] && [ \$(sed -n 's/^\([0-9]*\) 48 kHz output keeper started.*/\1/p' $VS/events.log) -ge 110 ]"
ok "started again after it stopped, and only then" "[ \$(wc -l < $T/keeper.log) = 2 ] && grep -q 'keeper was not running; started it again' $T/out.txt && [ \$(sed -n 's/^\([0-9]*\) the 48 kHz output keeper was not running.*/\1/p' $VS/events.log) -ge 200 ]"
setup bootK2; mkdir -p $VS; echo "off in the app" > $VS/disabled; echo 1 > $T/props/sys.boot_completed
runboot 50
ok "EQ Engine off: no keeper" "[ ! -f $T/keeper.log ]"

echo "== 27. an audio server crash right after a 48 kHz switch: 48 kHz output turned off, nothing else counts"
setup bootK3; vhqsetup 1 good map
STOPAT=260 crashhook 150
cat >> $T/hook <<'H'
[ $u -ge 146 ] && [ ! -f /tmp/eqeboot/sent ] && { echo $u > /tmp/eqeboot/root/data/eqengine/state/rate48_sent; touch /tmp/eqeboot/sent; }
H
rununtilstop
ok "48 kHz output turned off in the settings, with the reason for the app" "[ \"\$(cat $VSET/rate48)\" = 0 ] && grep -q 'right after a switch to 48 kHz' $VS/rate48_cut && grep -q 'right after a 48 kHz switch' $T/out.txt"
ok "no converter step-down, not counted as an unexpected restart" "[ ! -f $VSET/converter ] && [ -f $VS/vhq_load ] && ! grep -q 'unexpectedly (1' $T/out.txt && [ \"\$(st unexpected_restarts)\" = 0 ]"
setup bootK4; vhqsetup 1 good map
STOPAT=260 crashhook 180
cat >> $T/hook <<'H'
[ $u -ge 146 ] && [ ! -f /tmp/eqeboot/sent ] && { echo $u > /tmp/eqeboot/root/data/eqengine/state/rate48_sent; touch /tmp/eqeboot/sent; }
H
rununtilstop
ok "a crash 30 s after a switch counts as usual (stepped down, 48 kHz left on)" "[ \"\$(cat $VSET/converter)\" = 3 ] && grep -q 'unexpectedly (1' $T/out.txt && [ ! -f $VSET/rate48 ]"

echo "== 28. a new start: the previous start's 48 kHz state is cleared, its keeper log kept as the previous one"
setup bootK5; mkdir -p $VS; echo "167 101" > $VS/rate48; echo 90 > $VS/rate48_sent; echo "state=48k" > $VS/output; echo 4444 > $VS/keep.pid
mkdir -p $VS/hold; echo "held 2 13 21" > $VS/hold/state; echo 4445 > $VS/hold/pid
echo "80 switched to 48000 Hz" > $VS/output.log; echo bootK0 > $VS/runboot
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 120 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "rate48, rate48_sent, output and keep.pid cleared; output.log moved" "[ ! -f $VS/rate48 ] && [ ! -f $VS/rate48_sent ] && [ ! -f $VS/output ] && [ ! -f $VS/keep.pid ] && [ ! -f $VS/output.log ] && grep -q 'switched to 48000' $VS/output.prev.log"
ok "the 48 kHz helper's folder from the last start is gone" "[ ! -d $VS/hold ]"

echo "$SH: $pass passed, $fail failed"
