#!/system/bin/sh
# EQ Engine preuninstall (root). Turns the boot step off, removes the in-memory overlay and puts
# Android's audio converter setting back to its default now. NEMESIS then removes the app (which
# ends its EQ service) and the boot step; postuninstall deletes /data/eqengine.
# A restart afterwards gives a completely stock audio setup. Always exits 0.

D=/data/eqengine
TARGET=/system/etc/audio_effects.conf
mkdir -p $D/state
echo "uninstalled" > $D/state/disabled
rm -f $D/state/vhq_load
setprop af.resampler.quality 0
if [ -f $D/state/resampler.pid ]; then
    read p < $D/state/resampler.pid
    if [ -n "$p" ] && [ -f /proc/$p/cmdline ]; then
        read c < /proc/$p/cmdline
        case "$c" in
            *logcat*) kill $p 2>/dev/null ;;
        esac
    fi
fi

mounted() {
    while read _d _m _rest; do
        [ "$_m" = "$TARGET" ] && return 0
    done < /proc/mounts
    return 1
}
i=0
while mounted && [ $i -lt 5 ]; do
    umount $TARGET
    i=$((i + 1))
    mounted && sleep 1
done
# Lab tests (the driver watch, or 0.6.0's 48 kHz policy copy), if one is on
for t in /system/lib/hw/audio.primary.tcc803x.so /system/etc/audio_policy.conf; do
    i=0
    while [ $i -lt 5 ]; do
        m=0
        while read _d _m _rest; do
            [ "$_m" = "$t" ] && m=1
        done < /proc/mounts
        [ $m = 0 ] && break
        umount $t
        # busy while the audio server has the file loaded: detach it (the running audio server
        # keeps what it has until the car restarts)
        [ $i = 0 ] && [ -x $D/bin/eqe_lab ] && $D/bin/eqe_lab umount $t > /dev/null 2>&1
        i=$((i + 1))
    done
done
rm -f $D/state/lab_active
# The 48 kHz keeper (act.sh keep) puts the main output back to 44.1 kHz and stops once it sees
# "disabled"; it gets some seconds for that (a change holds the output's tracks first), then it
# is stopped. Its helper (Hold.java) is stopped too: Android then releases the helper's filters.
if [ -f $D/state/keep.pid ]; then
    read kp < $D/state/keep.pid
    i=0
    while [ -n "$kp" ] && [ -f /proc/$kp/cmdline ] && [ $i -lt 15 ]; do
        sleep 1
        i=$((i + 1))
    done
    if [ -n "$kp" ] && [ -f /proc/$kp/cmdline ]; then
        read c < /proc/$kp/cmdline
        case "$c" in
            *act.sh*) kill $kp 2>/dev/null ;;
        esac
    fi
fi
if [ -f $D/state/hold/pid ]; then
    read hp < $D/state/hold/pid
    if [ -n "$hp" ] && [ -f /proc/$hp/cmdline ]; then
        read c < /proc/$hp/cmdline
        case "$c" in
            *app_process*) kill $hp 2>/dev/null ;;
        esac
    fi
fi
sleep 3
exit 0
