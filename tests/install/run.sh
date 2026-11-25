#!/bin/bash
# Install, update, uninstall and rescue tests (after 0.7.6): pkg/scripts/pre.sh, post.sh, preun.sh,
# postun.sh and rescue/eqengine-off.sh run under the shell named in $1 (dash, bash, mksh) against a
# simulated unit (EQE_TEST_ROOT), with stand-ins for the car's programs: mount and umount keep a
# simulated /proc/mounts, md5 is md5sum, logcat writes a file and keeps running, kill and the
# processes it stops are simulated, sleep returns at once (except preinstall's 40 s, held until
# the test releases it).
#   bash tests/install/run.sh dash
SH=${1:-sh}
R=$(cd "$(dirname "$0")/../.." && pwd)
T=/tmp/eqeinst
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "  ok   $1"; else fail=$((fail + 1)); echo "  FAIL $1"; fi; }

stubs() {
    mkdir -p $T/stubs
    cat > $T/stubs/md5 <<'S'
#!/bin/sh
[ -f "$1" ] || { echo "could not open $1" >&2; exit 1; }
set -- $(md5sum "$1") "$1"
echo "$1  $3"
S
    # mount -o bind <file> <path>: the file laid over the path (the old one kept underneath)
    # (after 0.7.8) as the kernel: symlinks on the path are followed (a NEMESIS LivePatch farm's), and
    # the mount is listed at the file it landed on
    cat > $T/stubs/mount <<'S'
#!/bin/sh
[ "$1" = -o ] && [ "$2" = bind ] || exit 1
p=$(readlink -f "$4"); [ -n "$p" ] || p=$4
cp "$p" "$p.under.$$" && cat "$3" > "$p" && echo "none $p none rw 0 0" >> /tmp/eqeinst/proc/mounts
mv "$p.under.$$" "$p.under"
S
    cat > $T/stubs/umount <<'S'
#!/bin/sh
p=$(readlink -f "$1"); [ -n "$p" ] || p=$1
grep -q " $p " /tmp/eqeinst/proc/mounts || exit 1
echo "umount $1" >> /tmp/eqeinst/umount.log
[ -f "$p.under" ] && mv "$p.under" "$p"
grep -v " $p " /tmp/eqeinst/proc/mounts > /tmp/eqeinst/proc/mounts.n; mv /tmp/eqeinst/proc/mounts.n /tmp/eqeinst/proc/mounts
S
    cat > $T/stubs/setprop <<'S'
#!/bin/sh
echo "$1=$2" >> /tmp/eqeinst/setprop.log
S
    cat > $T/stubs/getprop <<'S'
#!/bin/sh
[ -f "/tmp/eqeinst/props/$1" ] && cat "/tmp/eqeinst/props/$1"
exit 0
S
    # the 40 s capture: writes its file, keeps running (its command line names logcat and the file)
    cat > $T/stubs/logcat <<'S'
#!/bin/sh
f=""
for a in "$@"; do [ "$p" = -f ] && f=$a; p=$a; done
[ -n "$f" ] && echo "a system log line with personal data" > "$f"
while :; do /bin/sleep 1; done
S
    # kill of a simulated process (/tmp/eqeinst/proc/<pid>): it is gone
    cat > $T/stubs/kill <<'S'
#!/bin/sh
for a in "$@"; do
    case "$a" in -*) ;; *) echo "kill $a" >> /tmp/eqeinst/kill.log; rm -rf "/tmp/eqeinst/proc/$a" ;; esac
done
exit 0
S
    # sleep returns at once, except preinstall's 40 s, which waits until the test releases it
    cat > $T/stubs/sleep <<'S'
#!/bin/sh
echo "$1" >> /tmp/eqeinst/sleep.log
if [ "$1" = 40 ]; then
    while [ ! -f /tmp/eqeinst/release_sleep ]; do /bin/sleep 0.1; done
fi
exit 0
S
    printf '#!/bin/sh\necho "nemesis $*" >> /tmp/eqeinst/nemesis.log\n' > $T/stubs/nemesis
    printf '#!/bin/sh\necho "package:/data/app/com.eqengine.app-1.apk"\n' > $T/stubs/pm
    printf '#!/bin/sh\nexit 0\n' > $T/stubs/chown
    for p in getenforce df date id; do printf '#!/bin/sh\necho "%s"\n' "$p" > $T/stubs/$p; done
    chmod +x $T/stubs/*
}

# a simulated unit with NEMESIS's staging of the package (cwd for the install scripts)
setup() {
    rm -rf $T
    mkdir -p $T/proc $T/dev $T/system/etc $T/system/lib/hw $T/system/xbin $T/data/nemesis/apps $T/data/data/com.eqengine.app \
        $T/mnt/media_rw/usb0 $T/pkg/bin $T/pkg/lib $T/pkg/conf $T/props
    stubs
    cp $T/stubs/nemesis $T/system/xbin/nemesis
    echo "/dev/block/system /system ext4 ro 0 0" > $T/proc/mounts
    echo "100.00 50.00" > $T/proc/uptime
    echo "factory effects list" > $T/system/etc/audio_effects.conf
    echo "factory audio driver" > $T/system/lib/hw/audio.primary.tcc803x.so
    echo "factory CarPlay JNI library" > $T/system/lib/libCarPlayAndroid.so
    echo "EQ Engine 0.7.x" > $T/mnt/media_rw/usb0/README-EQENGINE.txt
    cp $R/pkg/bin/act.sh $T/pkg/bin/act.sh
    printf '#!/bin/sh\nexit 0\n' > $T/pkg/bin/alsactl_dump
    # eqe_lab umount <path>: as umount (the detach); cpcheck: the layer checks out
    printf '#!/bin/sh\n[ "$1" = umount ] && exec /tmp/eqeinst/stubs/umount "$2"\n[ "$1" = cpcheck ] && { echo "cpcheck ok (stand-in)"; exit 0; }\nexit 1\n' > $T/pkg/bin/eqe_lab
    chmod +x $T/pkg/bin/*
    cp $R/pkg/conf/audio_effects.conf $T/pkg/conf/audio_effects.conf
    for l in libeqengine libaudio-resampler eqe_drvwatch eqe_cpwatch; do
        echo "$l library" > $T/pkg/lib/$l.so
        md5sum $T/pkg/lib/$l.so | cut -c1-32 > $T/pkg/lib/$l.md5
    done
}

runs() {  # runs <script> from the package folder (or $RUNDIR) under $SH; output in $T/out.txt
    # (CALLER stands for the nemesis command that runs the hook, for example "nemesis uninstall eqengine")
    ( cd ${RUNDIR:-$T/pkg}; EQE_TEST_ROOT=$T EQE_TEST_CALLER="$CALLER" PATH=$T/stubs:/usr/bin:/bin timeout 60 $SH "$1" > $T/out.txt 2>&1; echo $? > $T/rc )
}
rc() { cat $T/rc; }
stage() {  # NEMESIS has the new EQ Engine unpacked in its staging folder (an update)
    mkdir -p $T/data/local/tmp/nemesis/stage/eqengine
    printf '[nemesis]\nversion=1.1\nid=eqengine\n' > $T/data/local/tmp/nemesis/stage/eqengine/NEMESIS.data
}
keeper() {  # a running 48 kHz keeper (simulated), pid $1
    mkdir -p $T/proc/$1; printf 'sh\000/data/eqengine/bin/act.sh\000keep\000' > $T/proc/$1/cmdline; echo $1 > $D/state/keep.pid
}
D=$T/data/eqengine

echo "== a first install under $SH"
setup
runs $R/pkg/scripts/pre.sh
ok "preinstall: diagnostics and the 40 s system log on the stick, its pid noted for postinstall" "[ $(rc) = 0 ] && ls $T/mnt/media_rw/usb0/EQENGINE/install_*.txt > /dev/null 2>&1 && ls $T/mnt/media_rw/usb0/EQENGINE/logcat_install_*.txt > /dev/null 2>&1 && [ -s $T/dev/eqengine-install-log ]"
read LP LF < $T/dev/eqengine-install-log
ok "the capture is still running when postinstall starts" "[ -d /proc/$LP ]"
runs $R/pkg/scripts/post.sh
ok "postinstall: the filter, effects list, helpers and layer in /data/eqengine, readable as they must be" "[ $(rc) = 0 ] && cmp -s $T/pkg/lib/libeqengine.so $D/lib/libeqengine.so && cmp -s $T/pkg/conf/audio_effects.conf $D/conf/audio_effects.conf && cmp -s $T/pkg/lib/eqe_cpwatch.so $D/lib/eqe_cpwatch.so && [ -x $D/bin/act.sh ] && [ \"\$(stat -c %a $D/lib/libeqengine.so)\" = 644 ] && [ \"\$(stat -c %a $D/bin/act.sh)\" = 755 ]"
ok "postinstall: a clean failsafe state, the start marked as the install's, an event line" "[ -f $D/state/fresh_install ] && [ ! -f $D/state/disabled ] && grep -q 'installed EQ Engine' $D/state/events.log"
ok "postinstall: the install note on the stick" "ls $T/mnt/media_rw/usb0/EQENGINE/install_ok_*.txt > /dev/null 2>&1"
/bin/sleep 0.3
ok "postinstall stopped the system log itself and deleted it from the stick (after 0.7.6)" "[ ! -d /proc/$LP ] && [ ! -f \"$LF\" ] && [ ! -f $T/dev/eqengine-install-log ]"
ok "postinstall: EQ on CarPlay prepared for the next car start (this unit's CarPlay library is there; nothing laid over now)" "grep -q '^EQE_CPW on from the next car start' $D/state/cpw_install.txt && read w x < $D/state/cpw_want && [ \"\$w\" = 1 ] && ! grep -q ' $T/system/lib/libCarPlayAndroid.so ' $T/proc/mounts"
touch $T/release_sleep; kill $LP 2>/dev/null

echo "== an update keeps the settings, on flash (after 0.7.6)"
mkdir -p $D/settings; stage; keeper 4444; rm -f $T/kill.log
echo "preamp=-300" > $D/settings/current.txt
echo "0,1,2,3,4,5,6,7,8,9,10" > $D/settings/preset1.txt
runs $R/pkg/scripts/preun.sh
ok "preuninstall: EQ Engine off for the boot step, the converter back to Android's default" "[ $(rc) = 0 ] && grep -qx uninstalled $D/state/disabled && grep -q 'af.resampler.quality=0' $T/setprop.log"
ok "during an update the keeper is stopped first (it does not put 44.1 kHz back for the new version to undo)" "grep -qx 'kill 4444' $T/kill.log"
runs $R/pkg/scripts/postun.sh
ok "postuninstall during an update: the settings kept in /data/eqengine-keep, the rest gone" "[ $(rc) = 0 ] && [ ! -d $D ] && grep -qx 'preamp=-300' $T/data/eqengine-keep/current.txt && [ -f $T/data/eqengine-keep/preset1.txt ] && [ ! -d $T/dev/eqengine-keep ]"
echo "   (a power cut here would lose nothing: the copy is on flash)"
runs $R/pkg/scripts/post.sh
ok "the new version's postinstall puts them back and removes the copy" "grep -qx 'preamp=-300' $D/settings/current.txt && [ -f $D/settings/preset1.txt ] && [ ! -d $T/data/eqengine-keep ] && grep -q 'kept settings restored: yes' $D/state/events.log"
rm -rf $T/data/local/tmp/nemesis/stage

echo "== a stage left by an interrupted install does not turn an uninstall into an update"
mkdir -p $D/settings; echo "preamp=-200" > $D/settings/current.txt; stage
CALLER="nemesis uninstall eqengine" runs $R/pkg/scripts/postun.sh
ok "postuninstall run by 'nemesis uninstall': the settings only in RAM, nothing left on flash" "[ ! -d $T/data/eqengine-keep ] && grep -qx 'preamp=-200' $T/dev/eqengine-keep/current.txt"
rm -rf $T/dev/eqengine-keep $T/data/local/tmp/nemesis/stage
runs $R/pkg/scripts/post.sh
mkdir -p $D/settings $T/data/local/tmp/nemesis/stage/eqengine; echo "preamp=-250" > $D/settings/current.txt
runs $R/pkg/scripts/postun.sh
ok "a stage folder without EQ Engine's package in it is not an update either" "[ ! -d $T/data/eqengine-keep ] && grep -qx 'preamp=-250' $T/dev/eqengine-keep/current.txt"
rm -rf $T/data/local/tmp/nemesis/stage $T/dev/eqengine-keep; runs $R/pkg/scripts/post.sh

echo "== a plain uninstall"
mkdir -p $D/settings; echo "preamp=-100" > $D/settings/current.txt
runs $R/pkg/scripts/preun.sh
runs $R/pkg/scripts/postun.sh
ok "postuninstall: everything of EQ Engine's gone; the settings only in RAM (/dev), gone at the next restart" "[ ! -d $D ] && [ ! -d $T/data/eqengine-keep ] && grep -qx 'preamp=-100' $T/dev/eqengine-keep/current.txt"
runs $R/pkg/scripts/post.sh
ok "a reinstall in the same car start gets them back" "grep -qx 'preamp=-100' $D/settings/current.txt && [ ! -d $T/dev/eqengine-keep ]"

echo "== preuninstall removes only EQ Engine's own mounts (0.7.6; the driver watch's path too after 0.7.6)"
setup; runs $R/pkg/scripts/post.sh
$T/stubs/mount -o bind $D/conf/audio_effects.conf $T/system/etc/audio_effects.conf
$T/stubs/mount -o bind $D/lib/eqe_drvwatch.so $T/system/lib/hw/audio.primary.tcc803x.so
echo "another package's CarPlay library" > $T/other.so
$T/stubs/mount -o bind $T/other.so $T/system/lib/libCarPlayAndroid.so
keeper 4444; rm -f $T/kill.log
runs $R/pkg/scripts/preun.sh
ok "EQ Engine's effects list and driver watch taken off, the factory files back" "[ \"\$(cat $T/system/etc/audio_effects.conf)\" = 'factory effects list' ] && [ \"\$(cat $T/system/lib/hw/audio.primary.tcc803x.so)\" = 'factory audio driver' ]"
ok "another package's file over the CarPlay library is left as it is" "grep -q ' $T/system/lib/libCarPlayAndroid.so ' $T/proc/mounts && grep -qx \"another package's CarPlay library\" $T/system/lib/libCarPlayAndroid.so"
ok "the 48 kHz keeper is stopped (after its time to put 44.1 kHz back)" "grep -qx 'kill 4444' $T/kill.log"
mkdir -p $T/proc/4445; echo "/system/bin/sleep60" > $T/proc/4445/cmdline; echo 4445 > $D/state/keep.pid; rm -f $T/kill.log
runs $R/pkg/scripts/preun.sh
ok "a pid used since by another program is not stopped" "[ ! -f $T/kill.log ] || ! grep -q 'kill 4445' $T/kill.log"
setup; runs $R/pkg/scripts/post.sh
echo "another package's driver" > $T/other.so; $T/stubs/mount -o bind $T/other.so $T/system/lib/hw/audio.primary.tcc803x.so
echo "another package's effects list" > $T/other.conf; $T/stubs/mount -o bind $T/other.conf $T/system/etc/audio_effects.conf
rm -f $T/umount.log; runs $R/pkg/scripts/preun.sh
ok "another package's driver file and effects list are left laid over (after 0.7.6 for the driver path), nothing unmounted" "grep -qx \"another package's driver\" $T/system/lib/hw/audio.primary.tcc803x.so && grep -qx \"another package's effects list\" $T/system/etc/audio_effects.conf && [ ! -s $T/umount.log ]"

echo "== (after 0.7.6) no wait for the 48 kHz keeper while the factory CarPlay app plays to the main link itself"
setup; runs $R/pkg/scripts/post.sh
keeper 4444; printf 'want=1\nstate=48k\nout=48000\n' > $D/state/output; rm -f $T/kill.log $T/sleep.log
runs $R/pkg/scripts/preun.sh
ok "preuninstall, Android with the main link: the keeper gets its 15 s to put 44.1 kHz back" "[ \$(grep -cx 1 $T/sleep.log) = 15 ] && grep -qx 'kill 4444' $T/kill.log"
setup; runs $R/pkg/scripts/post.sh
keeper 4444; printf 'want=1\nstate=other\nout=48000\nowner=com.daudio.app.dipo\n' > $D/state/output; rm -f $T/kill.log $T/sleep.log
runs $R/pkg/scripts/preun.sh
ok "preuninstall, CarPlay with the main link: the keeper (which can change nothing then) is stopped at once" "! grep -qx 1 $T/sleep.log && grep -qx 'kill 4444' $T/kill.log"
setup; runs $R/pkg/scripts/post.sh
keeper 4444; printf 'want=1\nstate=other\nout=48000\nowner=com.daudio.app.dipo\n' > $D/state/output; rm -f $T/kill.log $T/sleep.log
mkdir -p $T/stick; RUNDIR=$T/stick runs $R/rescue/eqengine-off.sh
ok "rescue, CarPlay with the main link: the keeper stopped at once" "! grep -qx 1 $T/sleep.log && grep -qx 'kill 4444' $T/kill.log"

echo "== the rescue stick"
setup; runs $R/pkg/scripts/post.sh
$T/stubs/mount -o bind $D/conf/audio_effects.conf $T/system/etc/audio_effects.conf
$T/stubs/mount -o bind $T/pkg/lib/eqe_cpwatch.so $T/system/lib/libCarPlayAndroid.so
mkdir -p $T/stick; RUNDIR=$T/stick runs $R/rescue/eqengine-off.sh
RF=$(ls $T/stick/EQENGINE-RESCUE/rescue_*.txt 2>/dev/null | head -n1)
ok "rescue: EQ Engine off for later starts, the boot step stopped, the overlay and EQ on CarPlay's layer taken off" "[ $(rc) = 0 ] && grep -qx 'rescue stick' $D/state/disabled && grep -q 'service stop eqengine/boot' $T/nemesis.log && [ \"\$(cat $T/system/etc/audio_effects.conf)\" = 'factory effects list' ] && [ \"\$(cat $T/system/lib/libCarPlayAndroid.so)\" = 'factory CarPlay JNI library' ] && grep -q 'overlay removed' \"$RF\""
setup; runs $R/pkg/scripts/post.sh
echo "another package's CarPlay library" > $T/other.so
$T/stubs/mount -o bind $T/other.so $T/system/lib/libCarPlayAndroid.so
echo "another package's driver" > $T/other2.so
$T/stubs/mount -o bind $T/other2.so $T/system/lib/hw/audio.primary.tcc803x.so
rm -f $T/umount.log; mkdir -p $T/stick; RUNDIR=$T/stick runs $R/rescue/eqengine-off.sh
RF=$(ls $T/stick/EQENGINE-RESCUE/rescue_*.txt 2>/dev/null | head -n1)
ok "rescue: another package's file over the CarPlay library is left alone, and named as such (not as a Lab test)" "grep -q \"another package's file is laid over $T/system/lib/libCarPlayAndroid.so: left as it is\" \"$RF\" && ! grep -q 'Lab test' \"$RF\" && grep -q ' $T/system/lib/libCarPlayAndroid.so ' $T/proc/mounts"
ok "rescue: another package's driver file is left alone and named as such (after 0.7.6)" "grep -qx \"another package's driver\" $T/system/lib/hw/audio.primary.tcc803x.so && grep -q \"another package's file is laid over $T/system/lib/hw/audio.primary.tcc803x.so: left as it is\" \"$RF\" && [ ! -s $T/umount.log ]"

echo "== (after 0.7.8) NEMESIS LivePatch farms over /system/lib and /system/etc: EQ Engine's mounts are on the files they show"
ifarm() {  # $1 = folder under /system, $2 = file: the stock view's copy, and the farm's symlink at the path
    mkdir -p $T/data/nemesis/livepatch/stock/system/$1
    mv $T/system/$1/$2 $T/data/nemesis/livepatch/stock/system/$1/$2
    ln -s $T/data/nemesis/livepatch/stock/system/$1/$2 $T/system/$1/$2
}
setup; runs $R/pkg/scripts/post.sh
ifarm lib libCarPlayAndroid.so; ifarm etc audio_effects.conf
$T/stubs/mount -o bind $D/conf/audio_effects.conf $T/system/etc/audio_effects.conf
$T/stubs/mount -o bind $D/lib/eqe_cpwatch.so $T/system/lib/libCarPlayAndroid.so
runs $R/pkg/scripts/preun.sh
ok "preuninstall: the effects list and EQ on CarPlay's layer taken off the files the farms show" "[ \"\$(cat $T/system/etc/audio_effects.conf)\" = 'factory effects list' ] && [ \"\$(cat $T/system/lib/libCarPlayAndroid.so)\" = 'factory CarPlay JNI library' ] && ! grep -q livepatch $T/proc/mounts && [ -L $T/system/lib/libCarPlayAndroid.so ]"
setup; runs $R/pkg/scripts/post.sh
ifarm lib libCarPlayAndroid.so; ifarm etc audio_effects.conf
$T/stubs/mount -o bind $D/conf/audio_effects.conf $T/system/etc/audio_effects.conf
$T/stubs/mount -o bind $D/lib/eqe_cpwatch.so $T/system/lib/libCarPlayAndroid.so
mkdir -p $T/stick; RUNDIR=$T/stick runs $R/rescue/eqengine-off.sh
RF=$(ls $T/stick/EQENGINE-RESCUE/rescue_*.txt 2>/dev/null | head -n1)
ok "rescue: the same, said as removed (not as another package's file)" "[ \"\$(cat $T/system/etc/audio_effects.conf)\" = 'factory effects list' ] && [ \"\$(cat $T/system/lib/libCarPlayAndroid.so)\" = 'factory CarPlay JNI library' ] && ! grep -q livepatch $T/proc/mounts && grep -q 'overlay removed' \"$RF\" && ! grep -q 'another package' \"$RF\""

echo "$SH: $pass passed, $fail failed"
[ $fail = 0 ]
