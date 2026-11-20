#!/system/bin/sh
# EQ Engine rescue: turns EQ Engine off.
# NEMESIS runs this from the stick as root: it asks first while Android is up, and runs on its own
# while Android is down (because NEMESIS.emergency is on the stick).
# It writes /data/eqengine/state/disabled (later starts skip the boot step), stops the boot step,
# removes the in-memory overlay of Android's effects list, and puts Android's converter setting
# back to its default (the very high quality converter's marker goes too), and stops the 48 kHz
# keeper once it has put 44.1 kHz back (and its helper). Nothing else.
# Results go to EQENGINE-RESCUE/ on this stick.

U="$PWD"
D=/data/eqengine
TARGET=/system/etc/audio_effects.conf
read up rest < /proc/uptime
T="${up%%.*}"
OUT="$U/EQENGINE-RESCUE"
mkdir -p "$OUT"

mounted() {
    while read _d _m _rest; do
        [ "$_m" = "$TARGET" ] && return 0
    done < /proc/mounts
    return 1
}

{
    echo "EQ Engine rescue"
    date
    if [ -d $D ]; then
        mkdir -p $D/state
        echo "rescue stick" > $D/state/disabled
        rm -f $D/state/vhq_load
        echo "turned off for all later starts (the very high quality converter too)"
    else
        echo "EQ Engine is not installed here ($D does not exist)"
    fi
    /system/xbin/nemesis service stop eqengine/boot 2>&1
    setprop af.resampler.quality 0
    echo "converter setting: Android's default"
    i=0
    while mounted && [ $i -lt 5 ]; do
        umount $TARGET
        i=$((i + 1))
        mounted && sleep 1
    done
    if mounted; then
        echo "overlay still mounted: it goes away when the head unit restarts"
    else
        echo "overlay removed (or was not there)"
    fi
    # Lab tests (the driver watch, or 0.6.0's 48 kHz policy copy), if one was on
    for t in /system/lib/hw/audio.primary.tcc803x.so /system/etc/audio_policy.conf; do
        i=0
        while [ $i -lt 5 ]; do
            m=0
            while read _d _m _rest; do
                [ "$_m" = "$t" ] && m=1
            done < /proc/mounts
            [ $m = 0 ] && break
            umount $t
            # busy while the audio server has the file loaded: detach it instead
            [ $i = 0 ] && [ -x $D/bin/eqe_lab ] && $D/bin/eqe_lab umount $t
            i=$((i + 1))
        done
        [ $m = 1 ] && echo "Lab test $t still mounted: it goes away when the head unit restarts"
    done
    rm -f $D/state/lab_active
    # the 48 kHz keeper puts 44.1 kHz back and stops once it sees "disabled"; then it is stopped
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
                *act.sh*) kill $kp 2>/dev/null; echo "48 kHz keeper stopped" ;;
            esac
        fi
    fi
    if [ -f $D/state/hold/pid ]; then
        read hp < $D/state/hold/pid
        if [ -n "$hp" ] && [ -f /proc/$hp/cmdline ]; then
            read c < /proc/$hp/cmdline
            case "$c" in
                *app_process*) kill $hp 2>/dev/null; echo "48 kHz helper stopped" ;;
            esac
        fi
    fi
    echo "--- status"
    cat $D/state/status 2>&1
    echo "--- events"
    cat $D/state/events.log 2>&1
} > "$OUT/rescue_$T.txt" 2>&1 < /dev/null
sync
exit 0
