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
# Lab tests (driver watch, 48 kHz policy), if one is on
for t in /system/lib/hw/audio.primary.tcc803x.so /system/etc/audio_policy.conf; do
    i=0
    while [ $i -lt 5 ]; do
        m=0
        while read _d _m _rest; do
            [ "$_m" = "$t" ] && m=1
        done < /proc/mounts
        [ $m = 0 ] && break
        umount $t
        i=$((i + 1))
    done
done
rm -f $D/state/lab_active
sleep 3
exit 0
