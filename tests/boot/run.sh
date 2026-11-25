#!/bin/bash
# Simulated head unit for pkg/bin/boot.sh. Usage: run.sh <shell>
SH=${1:-dash}
R=$(cd "$(dirname "$0")/../.." && pwd)
BOOT=$R/pkg/bin/boot.sh
# the package version (the boot step logs it)
PV=$(sed -n "s/^package-version=//p" "$R/pkg/NEMESIS.data")
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
    # its stat (started 2.93 s after power-on, field 22 in clock ticks), as init starts it
    echo "167 (mediaserver) S 1 167 0 0 -1 4194560 100 0 0 0 10 5 0 0 20 0 9 0 293 30000000 2000 4294967295" > $T/proc/167/stat
    cat > $T/stubs/md5 <<'S'
#!/bin/sh
md5sum "$1"
S
    cat > $T/stubs/mount <<'S'
#!/bin/sh
# mount -o bind SRC DST
[ "$1" = "-o" ] && [ "$2" = "bind" ] || exit 1
e=/tmp/eqeboot/root/data/eqengine/state/events.log; n=0; [ -f $e ] && n=$(wc -l < $e | tr -d " ")
echo "mount after $n event lines" >> /tmp/eqeboot/mount.log
# (after 0.7.8) as the kernel: symlinks on the target are followed (a NEMESIS LivePatch farm's), and
# the mount is listed at the file it landed on
p=$(readlink -f "$4"); [ -n "$p" ] || p=$4
cp "$p" "$p.under.$$" && cp "$3" "$p" && echo "$p.under.$$" >> /tmp/eqeboot/stack && echo "none $p none rw 0 0" >> /tmp/eqeboot/proc/mounts
S
    cat > $T/stubs/umount <<'S'
#!/bin/sh
p=$(readlink -f "$1"); [ -n "$p" ] || p=$1; set -- "$p"
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
# a capture (-f) writes the running audio server's converter line, as logcat writes what its
# buffer holds first (none when /tmp/eqeboot/noconv: an audio server that never converts); a new
# file is made root only, as Android 4.4's logcat makes it (S_IRUSR|S_IWUSR)
[ -n "$f" ] && [ ! -f "$f" ] && (umask 077; : > "$f")
[ -n "$f" ] && [ ! -f /tmp/eqeboot/noconv ] && echo "11-18 16:00:00.000 D/AudioResampler(  $(cat /tmp/eqeboot/mspid)): forcing AudioResampler quality to 3" >> "$f"
# a dump (-d, no file): what system_server logs when it dies
# (after 0.7.6) the crash log's mode while the system log is written into it
[ -z "$f" ] && [ -f /tmp/eqeboot/root/data/eqengine/state/crash.log ] && stat -c %a /tmp/eqeboot/root/data/eqengine/state/crash.log > /tmp/eqeboot/crash_mode
[ -z "$f" ] && case " $(cat /tmp/eqeboot/logcat.log | tail -n1) " in *" -d "*) echo "11-18 16:00:17.000  654  700 E AndroidRuntime: *** FATAL EXCEPTION IN SYSTEM PROCESS: main" ;; esac
exit 0
S
    cat > $T/stubs/dmesg <<'S'
#!/bin/sh
echo "<3>[   17.020000] init: untracked pid 165 exited"
S
    # the car has no printf (its mksh has none, nor its toolbox)
    printf '#!/bin/sh\necho "printf: not found" >&2\nexit 127\n' > $T/stubs/printf
    # the 48 kHz keeper: notes that it was started and shows up as a process (in the simulated /proc)
    cat > $T/stubs/keeper <<'S'
#!/bin/sh
mkdir -p /tmp/eqeboot/proc/$$; echo "keeper $$" >> /tmp/eqeboot/keeper.log
# (its command line as the car's has it: sh, act.sh, keep, with NULs between)
printf 'sh\000/data/eqengine/bin/act.sh\000keep\000' > /tmp/eqeboot/proc/$$/cmdline
S
    # act.sh cpwboot (the CarPlay watch at the car start): notes when it ran
    cat > $T/stubs/cpwboot <<'S'
#!/bin/sh
n=0; [ -f /tmp/eqeboot/root/data/eqengine/state/events.log ] && n=$(wc -l < /tmp/eqeboot/root/data/eqengine/state/events.log)
echo "cpwboot after $n event lines" >> /tmp/eqeboot/cpwboot.log
echo "EQE_CPW_NOTE a note for the app only"
echo "EQE_CPW laid over the CarPlay app's JNI library at the car start (uptime 3)"
S
    chmod +x $T/stubs/*; : > $T/stack; rm -f $T/setprop.log $T/am.log $T/logcat.log $T/keeper.log $T/cpwboot.log
}
runboot() {  # runs until the script exits or ~$1 simulated seconds pass
    # exec: $BP is the boot step itself, so the kill below stops it (a leftover run would write into the next test)
    ( cd /; EQE_TEST_ROOT=$T/root EQE_PROC=$T/proc EQE_KEEP_CMD=$T/stubs/keeper EQE_CPW_CMD=$T/stubs/cpwboot PATH=$T/stubs:/usr/bin:/bin exec $SH $BOOT > $T/out.txt 2>&1 ) &
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
  p=$(cat /tmp/eqeboot/mspid); rm -rf /tmp/eqeboot/proc/$p; p=$((p + 1)); mkdir -p /tmp/eqeboot/proc/$p; echo $p > /tmp/eqeboot/mspid; echo $((n + 1)) > /tmp/eqeboot/crashes
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
  p=$(cat /tmp/eqeboot/mspid); rm -rf /tmp/eqeboot/proc/$p; p=$((p + 1)); mkdir -p /tmp/eqeboot/proc/$p; echo $p > /tmp/eqeboot/mspid; touch /tmp/eqeboot/done8
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

echo "== 9b. (after 0.7.6) the boot step run again in the same start (EQ Engine turned back on) keeps a keeper that still runs"
setup bootJK; echo 1 > $T/props/sys.boot_completed
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 130 ] && touch /tmp/eqeboot/stop' > $T/hook
( cd /; EQE_TEST_ROOT=$T/root EQE_PROC=$T/proc EQE_KEEP_CMD=$T/stubs/keeper PATH=$T/stubs:/usr/bin:/bin exec $SH $BOOT > $T/out1.txt 2>&1 ) & P1=$!
while [ ! -f $T/stop ]; do /bin/sleep 0.05; done; kill $P1; wait $P1 2>/dev/null
K1=$(cut -d' ' -f2 $T/keeper.log | head -n1)
rm -f $T/stop
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 200 ] && touch /tmp/eqeboot/stop' > $T/hook
runboot 300
ok "the keeper from the first run is kept, not started a second time" "[ -n \"$K1\" ] && grep -q \"keeper still running (pid $K1): kept\" $T/out.txt && [ \$(wc -l < $T/keeper.log) = 1 ]"
printf '/system/bin/foo' > $T/proc/$K1/cmdline; rm -f $T/stop
runboot 300
ok "a pid used since by another program is not taken for the keeper: a new one is started" "[ \$(wc -l < $T/keeper.log) = 2 ] && grep -q '48 kHz output keeper started' $T/out.txt"

echo "== 9c. (after 0.7.6) another package's file laid over the effects list: refused with that reason, left alone"
setup bootJF
echo "another package's effects list" > $T/foreign.conf
$T/stubs/mount -o bind $T/foreign.conf $T/root/system/etc/audio_effects.conf
runboot 60
ok "refused, saying so; the other file stays laid over, nothing of EQ Engine's mounted" "[ \"\$(st state)\" = refused ] && grep -q \"another package's file is laid over Android's effects list\" $T/root/data/eqengine/state/status && grep -qx \"another package's effects list\" $T/root/system/etc/audio_effects.conf && [ \$(grep -c 'mount after' $T/mount.log) = 1 ]"


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
  p=$(cat /tmp/eqeboot/mspid); rm -rf /tmp/eqeboot/proc/$p; p=$((p + 1)); mkdir -p /tmp/eqeboot/proc/$p; echo $p > /tmp/eqeboot/mspid; echo $((n + 1)) > /tmp/eqeboot/crashes
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
    ( cd /; EQE_TEST_ROOT=$T/root EQE_PROC=$T/proc EQE_KEEP_CMD=$T/stubs/keeper EQE_CPW_CMD=$T/stubs/cpwboot PATH=$T/stubs:/usr/bin:/bin exec $SH $BOOT > $T/out.txt 2>&1 ) & P1=$!
    while [ ! -f $T/stop ]; do /bin/sleep 0.05; done; kill $P1; wait $P1 2>/dev/null
}

echo "== 19. very high quality: one unexpected audio server restart steps it down to high quality"
setup bootV4; vhqsetup 1 good map
crashhook 130; rununtilstop
ok "stepped down: converter 3 kept in the settings, marker gone, reason kept for the app" "[ \"\$(cat $VSET/converter)\" = 3 ] && [ ! -f $VS/vhq_load ] && [ \"\$(tail -n1 $T/setprop.log)\" = af.resampler.quality=3 ] && grep -q 'restarted unexpectedly' $VS/conv_cut"
ok "one crash alone does not turn EQ Engine off" "[ ! -f $VS/disabled ] && grep -q 'stepped down to 3' $T/out.txt"
ok "the setting and the reason stay readable by the app" "[ \"\$(stat -c %a $VSET/converter)\" = 644 ] && [ \"\$(stat -c %a $VS/conv_cut)\" = 644 ]"
ok "the log at that moment is kept, root only (0.6.12)" "head -n1 $VS/crash.log | grep -q 'the audio server restarted unexpectedly: pid 167 -> 168' && grep -q 'FATAL EXCEPTION' $VS/crash.log && grep -q 'untracked pid' $VS/crash.log && [ \"\$(stat -c %a $VS/crash.log)\" = 600 ] && grep -q 'the log is in state/crash.log' $VS/events.log"

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

echo "== 21b. (after 0.7.6) the converter capture stops once it has the audio server's line, and starts again for the next one"
setup bootCP1; vhqsetup "" good nomap
cat > $T/hook <<'H'
read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}
if [ $u -ge 150 ] && [ ! -f /tmp/eqeboot/done_r ]; then
  [ -f /tmp/eqeboot/root/data/eqengine/state/resampler.pid ] && touch /tmp/eqeboot/cap_still_on
  # (the new capture makes a new file, root only as logcat makes it)
  cp /tmp/eqeboot/root/data/eqengine/state/resampler.log /tmp/eqeboot/first_cap.log
  rm -f /tmp/eqeboot/root/data/eqengine/state/resampler.log
  echo $u > /tmp/eqeboot/root/data/eqengine/state/expected_restart
  rm -rf /tmp/eqeboot/proc/167; mkdir -p /tmp/eqeboot/proc/168; echo 168 > /tmp/eqeboot/mspid; touch /tmp/eqeboot/done_r
fi
# before the main loop's once-a-minute chmod (about 60 s after "confirmed good" at 145): only
# cap_check can have made the new capture's file readable for the app by then
[ -f /tmp/eqeboot/done_r ] && [ $u -lt 200 ] && [ "$(stat -c %a /tmp/eqeboot/root/data/eqengine/state/resampler.log 2>/dev/null)" = 644 ] && touch /tmp/eqeboot/r644_early
[ $u -ge 240 ] && touch /tmp/eqeboot/stop
H
rununtilstop
ok "stopped for the first audio server before it was replaced, started again for the new one, stopped again" "[ ! -f $T/cap_still_on ] && [ \$(grep -c 'AudioResampler:D' $T/logcat.log) = 2 ] && grep -q 'AudioResampler(  167)' $T/first_cap.log && grep -q 'AudioResampler(  168)' $VS/resampler.log && [ ! -f $VS/resampler.pid ]"
ok "the new audio server's line is made readable for the app as soon as it is there (not only by the once-a-minute chmod)" "[ -f $T/r644_early ]"
setup bootCP2; vhqsetup "" good nomap; touch $T/noconv
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 200 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "an audio server that has not converted yet: the capture keeps running (started once)" "[ -f $VS/resampler.pid ] && [ \$(grep -c 'AudioResampler:D' $T/logcat.log) = 1 ]"
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
mkdir -p $T/root/data/eqengine/lib
cat > $T/root/data/eqengine/lib/eqe_drvwatch.so <<'X'
watch layer
X
STOPAT=300 crashhook 150 160
cat >> $T/hook <<'H'
if [ $u -ge 140 ] && [ ! -f /tmp/eqeboot/labon ]; then
  mount -o bind /tmp/eqeboot/root/data/eqengine/lib/eqe_drvwatch.so /tmp/eqeboot/root/system/lib/hw/audio.primary.tcc803x.so
  echo " watch" > /tmp/eqeboot/root/data/eqengine/state/lab_active; touch /tmp/eqeboot/labon
fi
H
rununtilstop
ok "the driver watch was removed (Hyundai's driver file back)" "[ \"\$(cat $T/root/system/lib/hw/audio.primary.tcc803x.so)\" = 'hyundai driver' ] && ! grep -q 'audio.primary' $T/proc/mounts && [ ! -f $VS/lab_active ]"
ok "the app gets the reason" "grep -q 'watch was on when the audio server restarted unexpectedly' $VS/lab_result"
ok "two crashes 10 s apart during the test: no step-down, EQ Engine stays on" "[ ! -f $VSET/converter ] && [ ! -f $VS/disabled ] && [ -f $VS/vhq_load ] && [ \$(grep -c 'during a Lab test' $T/out.txt) = 2 ]"

echo "== 23c. (after 0.7.6) another package's file over the audio driver is never taken for the driver watch"
setup bootW5
mkdir -p $T/root/system/lib/hw $T/root/data/eqengine/lib
echo "factory driver" > $T/root/system/lib/hw/audio.primary.tcc803x.so
echo "watch layer" > $T/root/data/eqengine/lib/eqe_drvwatch.so
echo "another package's driver" > $T/foreign.so
$T/stubs/mount -o bind $T/foreign.so $T/root/system/lib/hw/audio.primary.tcc803x.so
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 150 ] && echo "turned off in the app" > /tmp/eqeboot/root/data/eqengine/state/disabled' > $T/hook
runboot 300
ok "turned off: EQ Engine's overlay removed, the other package's driver file left laid over, state off (not an error)" "[ \"\$(st state)\" = off ] && [ \"\$(tm)\" = $ORIGMD5 ] && grep -qx \"another package's driver\" $T/root/system/lib/hw/audio.primary.tcc803x.so && grep -q ' $T/root/system/lib/hw/audio.primary.tcc803x.so ' $T/proc/mounts"

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
echo "   after 0.7.6: a crash put down to the switch gives no Lab grace, and delays 'confirmed good' by 45 s"
setup bootK6; vhqsetup 1 good map
STOPAT=220 crashhook 120
cat >> $T/hook <<'H'
[ $u -ge 118 ] && [ ! -f /tmp/eqeboot/sent ] && { echo $u > /tmp/eqeboot/root/data/eqengine/state/rate48_sent; touch /tmp/eqeboot/sent; }
H
rununtilstop
G=$(sed -n 's/^\([0-9]*\) confirmed good.*/\1/p' $VS/events.log | head -n1)
ok "put down to the switch, then confirmed good only 45 s after that restart (at $G)" "grep -q 'right after a 48 kHz switch' $T/out.txt && [ -n \"$G\" ] && [ $G -ge 165 ]"
setup bootK7; vhqsetup 1 good map
STOPAT=220 crashhook 120 140
cat >> $T/hook <<'H'
[ $u -ge 118 ] && [ ! -f /tmp/eqeboot/sent ] && { echo $u > /tmp/eqeboot/root/data/eqengine/state/rate48_sent; touch /tmp/eqeboot/sent; }
H
rununtilstop
ok "a second crash 20 s later is counted (stepped down), not excused as a Lab test" "grep -q 'right after a 48 kHz switch' $T/out.txt && grep -q 'unexpectedly (1' $T/out.txt && ! grep -q 'during a Lab test' $T/out.txt && [ \"\$(cat $VSET/converter)\" = 3 ] && ! grep -q 'confirmed good' $T/out.txt"

echo "== 28. a new start: the previous start's 48 kHz state is cleared, its keeper log kept as the previous one"
setup bootK5; mkdir -p $VS; echo "167 101" > $VS/rate48; echo 90 > $VS/rate48_sent; echo "state=48k" > $VS/output; echo 4444 > $VS/keep.pid
mkdir -p $VS/hold; echo "held 2 13 21" > $VS/hold/state; echo 4445 > $VS/hold/pid
echo "80 switched to 48000 Hz" > $VS/output.log; echo bootK0 > $VS/runboot
printf 'state=on\npid=2300\n' > $VS/cpwatch; echo "90 on in the factory CarPlay app (pid 2300)" > $VS/cpw_result
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 120 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "rate48, rate48_sent, output and keep.pid cleared; output.log moved" "[ ! -f $VS/rate48 ] && [ ! -f $VS/rate48_sent ] && [ ! -f $VS/output ] && [ ! -f $VS/keep.pid ] && [ ! -f $VS/output.log ] && grep -q 'switched to 48000' $VS/output.prev.log"
ok "the 48 kHz helper's folder from the last start is gone" "[ ! -d $VS/hold ]"
ok "the CarPlay watch's state from the last start is gone, its results kept as the previous ones" "[ ! -f $VS/cpwatch ] && [ ! -f $VS/cpw_result ] && grep -q 'pid 2300' $VS/cpw_result.prev"

echo "== 29. the overlay first, the timing, and a late effects list (0.6.9)"
setup bootT1; mkdir -p $VS; echo "100 an old line" > $VS/events.log; rm -f $T/mount.log
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 160 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "mounted before this start wrote any event line" "grep -qx 'mount after 1 event lines' $T/mount.log && grep -q 'overlay applied' $T/out.txt"
ok "the order in the event log: starting, overlay, timing" "[ \"\$(sed -n 2p $VS/events.log | cut -d' ' -f2-)\" = 'EQ Engine boot step $PV starting (strikes 0)' ] && sed -n 3p $VS/events.log | grep -q 'effects list overlay applied' && sed -n 4p $VS/events.log | grep -q '^[0-9]* timing: '"
ok "timing: this step's start and the overlay with decimals, the audio server's own start (its stat), nothing loaded yet" "grep -q 'timing: this step started at 100.25 s (its process at ? s), the overlay was in place at 100.25 s; Android.s audio server (pid 167) started at 2.93 s and had loaded at 100.25 s: no effect library yet' $T/out.txt"
ok "timing kept for the app and the logs; in time, no late note" "grep -qx 'audio_server_start=2.93' $VS/boot_timing && grep -qx 'loaded_at_overlay=none' $VS/boot_timing && grep -qx 'result=in_time' $VS/boot_timing && grep -qx 'overlay_at=100.25' $VS/boot_timing && grep -qx 'checked_at=100.25' $VS/boot_timing && [ ! -f $VS/late_list ]"

setup bootT2
printf 'b6b00000-b6b20000 r-xp 00000000 b3:19 99   /system/lib/libaudioflinger.so\nb6c00000-b6c10000 r-xp 00000000 b3:19 98   /system/lib/soundfx/libbundlewrapper.so\n' > $T/proc/167/maps
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 160 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "late: the factory list was already loaded at the overlay, and still is a second later: said at once" "grep -q \"Android's audio server (167) read the factory effects list before the overlay was in place: EQ Engine is not active this start. Restart Android audio once (parked); the EQ Engine app offers it\" $T/out.txt && grep -qx 'result=late' $VS/boot_timing && grep -qx 'loaded_at_overlay=factory' $VS/boot_timing"
ok "late: noted for the app (boot id and audio server), in the status too" "[ \"\$(cat $VS/late_list)\" = 'bootT2 167' ] && grep -q 'read its effects list before it' $VS/status"
ok "late: at 'confirmed good' it is not said a second time" "grep -q 'confirmed good' $T/out.txt && ! grep -q 'is not loaded in the audio server (167)' $T/out.txt && grep -q 'read its effects list before it' $VS/status"

setup bootT3
printf 'b6c00000-b6c10000 r-xp 00000000 b3:19 98   /system/lib/soundfx/libbundlewrapper.so\n' > $T/proc/167/maps
# it was loading EQ Engine's list at that moment: EQ Engine's filter is there a second later
cat > $T/hook <<'H'
echo "b6d00000-b6d10000 r-xp 00000000 b3:19 97   /data/eqengine/lib/libeqengine.so" >> /tmp/eqeboot/proc/167/maps
read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 160 ] && touch /tmp/eqeboot/stop
H
rununtilstop
ok "loading at the overlay, EQ Engine's filter there a second later: in time, no late note" "grep -qx 'result=in_time' $VS/boot_timing && grep -qx 'loaded_at_overlay=factory' $VS/boot_timing && [ ! -f $VS/late_list ] && ! grep -q 'read the factory effects list' $T/out.txt"

setup bootT4; mkdir -p $VS; touch $VS/fresh_install
printf 'b6c00000-b6c10000 r-xp 00000000 b3:19 98   /system/lib/soundfx/libbundlewrapper.so\n' > $T/proc/167/maps
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 160 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "right after an install: the timing is kept, but no late note (that audio server predates EQ Engine)" "grep -qx 'result=late' $VS/boot_timing && grep -qx 'fresh_install=1' $VS/boot_timing && [ ! -f $VS/late_list ] && ! grep -q 'read the factory effects list' $T/out.txt"

setup bootT5
printf 'b6c00000-b6c10000 r-xp 00000000 b3:19 98   /system/lib/soundfx/libbundlewrapper.so\n' > $T/proc/167/maps
cat > $T/hook <<'H'
read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}
if [ $u -ge 120 ] && [ ! -f /tmp/eqeboot/restarted ]; then
    touch /tmp/eqeboot/restarted; echo $u > /tmp/eqeboot/root/data/eqengine/state/expected_restart
    rm -rf /tmp/eqeboot/proc/167; mkdir -p /tmp/eqeboot/proc/168; echo 168 > /tmp/eqeboot/mspid
fi
[ $u -ge 140 ] && touch /tmp/eqeboot/stop
H
rununtilstop
ok "the requested audio restart: the late note is gone (the new audio server read EQ Engine's list)" "grep -q 'restarted on request' $T/out.txt && [ ! -f $VS/late_list ]"

setup bootT6; mkdir -p $VS; echo "bootT0 167" > $VS/late_list; echo "result=late" > $VS/boot_timing; echo bootT0 > $VS/runboot
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 120 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "a new start: the last start's late note and timing are replaced" "[ ! -f $VS/late_list ] && grep -qx 'boot_id=bootT6' $VS/boot_timing && grep -qx 'result=in_time' $VS/boot_timing"

setup bootT7; mkdir -p $VS; echo "turned off in the app" > $VS/disabled; rm -f $T/mount.log
runboot 30
ok "turned off: nothing mounted, no timing, the start's events still written" "[ ! -f $T/mount.log ] && [ ! -f $VS/boot_timing ] && grep -q 'boot step $PV starting' $VS/events.log && [ \"\$(st state)\" = off ]"

setup bootT8
# the audio server loads EQ Engine's list while this step does its housekeeping (its first chmod)
cat > $T/stubs/chmod <<'S'
#!/bin/sh
grep -q libeqengine /tmp/eqeboot/proc/167/maps 2>/dev/null || echo "b6d00000-b6d10000 r-xp 00000000 b3:19 97   /data/eqengine/lib/libeqengine.so" >> /tmp/eqeboot/proc/167/maps
exec /bin/chmod "$@"
S
chmod +x $T/stubs/chmod
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 120 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "the audio server is looked at right after the mount, before the housekeeping (0.6.10)" "grep -qx 'loaded_at_overlay=none' $VS/boot_timing && grep -qx 'result=in_time' $VS/boot_timing && grep -q 'libeqengine' $T/proc/167/maps"

echo "== 30. the CarPlay watch at the car start (0.6.10)"
setup bootC1; mkdir -p $VS; echo "1 0123456789abcdef0123456789abcdef 1000" > $VS/cpw_want
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 120 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "on: act.sh cpwboot runs once, after the overlay and its timing line, before the main loop" "[ \$(wc -l < $T/cpwboot.log) = 1 ] && n=\$(sed -n 's/^cpwboot after \([0-9]*\) event lines\$/\1/p' $T/cpwboot.log) && [ \$n -ge 4 ] && grep -qx 'mount after 0 event lines' $T/mount.log"
ok "on: its result goes into the event log, its notes for the app do not" "grep -q \"CarPlay watch: laid over the CarPlay app's JNI library at the car start (uptime 3)\" $VS/events.log && ! grep -q 'a note for the app only' $VS/events.log"
ok "on: the choice is kept for later car starts" "[ -f $VS/cpw_want ]"
setup bootC2
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 120 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "off: act.sh cpwboot is not run" "[ ! -f $T/cpwboot.log ] && ! grep -q 'CarPlay watch' $VS/events.log"
setup bootC3; mkdir -p $VS; echo "1 0123456789abcdef0123456789abcdef 1000" > $VS/cpw_want; echo "turned off in the app" > $VS/disabled
runboot 30
ok "EQ Engine off: the CarPlay watch is not laid over either" "[ ! -f $T/cpwboot.log ]"
setup bootC4; mkdir -p $VS; echo "1 0123456789abcdef0123456789abcdef 1000" > $VS/cpw_want; echo bootC0 > $VS/runboot
printf 'state=on
pid=2300
' > $VS/cpwatch; echo 2 > $VS/cpw_restarts
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 120 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "a new start: the last start's watch state is cleared before cpwboot, the choice stays" "[ ! -f $VS/cpwatch ] && [ ! -f $VS/cpw_restarts ] && [ -f $VS/cpw_want ] && [ -f $T/cpwboot.log ]"

echo "== 31. the audio server restarted with Android's framework (0.6.12): not counted, the log kept"
zy() {  # the zygote's stat, as init starts it
    mkdir -p $T/proc/$1; echo "$1 (zygote) S 1 $1 0 0 -1 4194560 100 0 0 0 10 5 0 0 20 0 9 0 292 30000000 2000 4294967295" > $T/proc/$1/stat
}
setup bootZ1; vhqsetup 1 good map; zy 165
{ echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}'
  echo 'if [ $u -ge 130 ] && [ ! -f /tmp/eqeboot/zy_done ]; then rm -rf /tmp/eqeboot/proc/165; mkdir -p /tmp/eqeboot/proc/3000; echo "3000 (zygote) S 1 3000 0 0 -1 4194560 100 0 0 0 10 5 0 0 20 0 9 0 13000 30000000 2000 4294967295" > /tmp/eqeboot/proc/3000/stat; p=$(cat /tmp/eqeboot/mspid); rm -rf /tmp/eqeboot/proc/$p; p=$((p + 1)); mkdir -p /tmp/eqeboot/proc/$p; echo $p > /tmp/eqeboot/mspid; touch /tmp/eqeboot/zy_done; fi'
  echo '[ $u -ge 260 ] && touch /tmp/eqeboot/stop'; } > $T/hook
rununtilstop
ok "named as a framework restart, with both pids" "grep -q \"audio server restarted with Android's framework (zygote 165 -> 3000, audio server 167 -> 168)\" $VS/events.log"
ok "not counted: the converter kept, confirmed good" "[ ! -f $VSET/converter ] && [ -f $VS/vhq_load ] && ! grep -q 'restarted unexpectedly' $VS/events.log && ! grep -q 'stepped down' $VS/events.log && grep -q 'confirmed good' $VS/events.log"
ok "the log at that moment is kept, root only" "head -n1 $VS/crash.log | grep -q \"Android's framework restarted: zygote 165 -> 3000\" && grep -q 'FATAL EXCEPTION IN SYSTEM PROCESS' $VS/crash.log && [ \"\$(stat -c %a $VS/crash.log)\" = 600 ]"
ok "(after 0.7.6) root only already while the system log is being written into it" "[ \"\$(cat $T/crash_mode)\" = 600 ]"
setup bootZ2; vhqsetup 1 good map; zy 165
{ echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}'
  echo 'if [ $u -ge 130 ] && [ ! -f /tmp/eqeboot/c1 ]; then p=$(cat /tmp/eqeboot/mspid); rm -rf /tmp/eqeboot/proc/$p; p=$((p + 1)); mkdir -p /tmp/eqeboot/proc/$p; echo $p > /tmp/eqeboot/mspid; touch /tmp/eqeboot/c1; fi'
  echo '[ $u -ge 260 ] && touch /tmp/eqeboot/stop'; } > $T/hook
rununtilstop
ok "the zygote still running: an audio server crash counts as before" "grep -q 'restarted unexpectedly (1 this start): pid 167 -> 168' $VS/events.log && [ \"\$(cat $VSET/converter)\" = 3 ]"
rm -f $T/hook $T/stop
runboot 30
ok "0.7.6: the next run's housekeeping leaves the crash logs root only (they hold the raw system log)" "[ -f $VS/crash.log ] && [ \"\$(stat -c %a $VS/crash.log)\" = 600 ] && [ \"\$(stat -c %a $VS/events.log)\" = 644 ]"

echo "== 32. (0.7.6) the status file is written only when it changes"
setup bootW
runboot 300
U=$(st updated)
UE=$(cut -d. -f1 $T/proc/uptime)
ok "written when it changed only: last at uptime $U, the run went on to $UE (confirmed good long before the end)" "[ -n \"$U\" ] && [ \"$U\" -lt 1000 ] && [ \"$UE\" -gt 5000 ] && [ \"\$(st good)\" = 1 ] && grep -q 'confirmed good' $T/out.txt"

echo "== 33. (after 0.7.8) a NEMESIS LivePatch farm over /system/etc"
# LivePatch's farm as native/livepatch.c builds it: the folder's stock view (a bind of /system's
# folder, without mounts made on files in it) and a tmpfs of symlinks into it over the folder
FSTK=$T/root/data/nemesis/livepatch/stock/system/etc
fxfarm() {  # $1 = the factory list to show
    mkdir -p $FSTK; cp "$1" $FSTK/audio_effects.conf
    rm -f $T/root/system/etc/audio_effects.conf; ln -s $FSTK/audio_effects.conf $T/root/system/etc/audio_effects.conf
    { echo "/dev/block/system $FSTK ext4 ro 0 0"; echo "tmpfs $T/root/system/etc tmpfs ro 0 0"; } >> $T/proc/mounts
}
setup bootLP1; fxfarm $ORIG; zy 165
echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; [ $u -ge 130 ] && touch /tmp/eqeboot/stop' > $T/hook
rununtilstop
ok "the farm already there: the overlay goes on the file the farm shows, the audio server gets EQ Engine's list" "grep -q 'effects list overlay applied' $VS/events.log && grep -q \" $FSTK/audio_effects.conf \" $T/proc/mounts && [ \"\$(tm)\" = $OURSMD5 ] && ! grep -q 'laid again' $VS/events.log && [ \"\$(st state)\" = applied ]"
setup bootLP2
{ echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; T=/tmp/eqeboot'
  # the farm built after the overlay (EQ Engine's mount stays listed, hidden), then the zygote
  echo 'if [ $u -ge 110 ] && [ ! -f $T/farmed ]; then mkdir -p '"$FSTK"'; cp '"$ORIG"' '"$FSTK"'/audio_effects.conf; rm -f $T/root/system/etc/audio_effects.conf; ln -s '"$FSTK"'/audio_effects.conf $T/root/system/etc/audio_effects.conf; echo "/dev/block/system '"$FSTK"' ext4 ro 0 0" >> $T/proc/mounts; echo "tmpfs $T/root/system/etc tmpfs ro 0 0" >> $T/proc/mounts; touch $T/farmed; fi'
  echo 'if [ $u -ge 120 ] && [ ! -d $T/proc/165 ]; then mkdir -p $T/proc/165; echo "165 (zygote) S 1 165 0 0 -1 4194560 100 0 0 0 10 5 0 0 20 0 9 0 292 30000000 2000 4294967295" > $T/proc/165/stat; fi'
  echo 'if [ $u -ge 160 ] && [ ! -f $T/laid ]; then cp $T/root/data/eqengine/state/events.log $T/events_at60; md5sum < $T/root/system/etc/audio_effects.conf | cut -c1-32 > $T/md5_at60; cp $T/proc/mounts $T/mounts_at60; touch $T/laid; fi'
  echo '[ $u -ge 170 ] && echo "turned off in the app" > $T/root/data/eqengine/state/disabled'; } > $T/hook
runboot 200
ok "the farm built after the overlay: laid again where the farm shows the list once the zygote runs" "grep -q 'effects list overlay laid again at $FSTK/audio_effects.conf' $T/events_at60 && [ \"\$(cat $T/md5_at60)\" = $OURSMD5 ] && grep -q \" $FSTK/audio_effects.conf \" $T/mounts_at60 && grep -q 'confirmed good' $T/events_at60"
ok "... turned off: the overlay taken off the file the farm shows, the factory list back there" "[ \"\$(st state)\" = off ] && [ \"\$(tm)\" = $ORIGMD5 ] && ! grep -q \" $FSTK/audio_effects.conf \" $T/proc/mounts"
setup bootLP3
{ echo 'read u r < /tmp/eqeboot/proc/uptime; u=${u%%.*}; T=/tmp/eqeboot'
  echo 'if [ $u -ge 110 ] && [ ! -f $T/farmed ]; then mkdir -p '"$FSTK"'; echo "another package list" > '"$FSTK"'/audio_effects.conf; rm -f $T/root/system/etc/audio_effects.conf; ln -s '"$FSTK"'/audio_effects.conf $T/root/system/etc/audio_effects.conf; touch $T/farmed; fi'
  echo 'if [ $u -ge 120 ] && [ ! -d $T/proc/165 ]; then mkdir -p $T/proc/165; echo "165 (zygote) S 1 165 0 0 -1 4194560 100 0 0 0 10 5 0 0 20 0 9 0 292 30000000 2000 4294967295" > $T/proc/165/stat; fi'
  echo '[ $u -ge 150 ] && touch $T/stop'; } > $T/hook
rununtilstop
ok "the farm shows another list: left alone, and said" "grep -q 'it is not the factory list: left alone' $VS/events.log && ! grep -q 'laid again' $VS/events.log && grep -qx 'another package list' $T/root/system/etc/audio_effects.conf"

echo "$SH: $pass passed, $fail failed"
