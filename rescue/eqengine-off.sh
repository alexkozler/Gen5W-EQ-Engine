#!/system/bin/sh
# EQ Engine rescue: turns EQ Engine off.
# NEMESIS runs this from the stick as root: it asks first while Android is up, and runs on its own
# while Android is down (because NEMESIS.emergency is on the stick).
# It writes /data/eqengine/state/disabled (later starts skip the boot step), stops the boot step,
# removes the in-memory overlay of Android's effects list, and puts Android's converter setting
# back to its default (the very high quality converter's marker goes too), and stops the 48 kHz
# keeper once it has put 44.1 kHz back (and its helper). Nothing else.
# Results go to EQENGINE-RESCUE/ on this stick.

# Tests (tests/install/run.sh) point the paths at a simulated unit; on the car R is empty.
R=${EQE_TEST_ROOT:-}
PROC=/proc
if [ -n "$R" ]; then
    PROC=$R/proc
    kill() { "$R/stubs/kill" "$@"; }
fi
U="$PWD"
D=$R/data/eqengine
TARGET=$R/system/etc/audio_effects.conf
read up rest < /proc/uptime
T="${up%%.*}"
OUT="$U/EQENGINE-RESCUE"
mkdir -p "$OUT"

mounted() {
    while read _d _m _rest; do
        [ "$_m" = "$TARGET" ] && return 0
    done < $PROC/mounts
    return 1
}

mounted_at() {
    while read _d _m _rest; do
        [ "$_m" = "$1" ] && return 0
    done < $PROC/mounts
    return 1
}

# 0 = the file at $1 is now EQ Engine's own $2, byte for byte (0.7.6: EQ Engine unmounts only its
# own mounts, never another package's at the same path)
ours() {
    [ -f "$2" ] || return 1
    set -- $(md5 "$1" 2>/dev/null) $(md5 "$2" 2>/dev/null)
    [ -n "$1" ] && [ "$1" = "$3" ]
}

# 0 = the 48 kHz keeper says another process (the factory CarPlay app) plays to the main link
# itself (state/output: state=other); it then changes nothing and does not stop by itself
keep_other() {
    [ -f $D/state/output ] || return 1
    while IFS='=' read -r _ok _ov; do
        [ "$_ok" = state ] && [ "$_ov" = other ] && return 0
    done < $D/state/output
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
    $R/system/xbin/nemesis service stop eqengine/boot 2>&1
    setprop af.resampler.quality 0
    echo "converter setting: Android's default"
    i=0
    while mounted && ours $TARGET $D/conf/audio_effects.conf && [ $i -lt 5 ]; do
        umount $TARGET
        i=$((i + 1))
        mounted && sleep 1
    done
    if mounted && ours $TARGET $D/conf/audio_effects.conf; then
        echo "overlay still mounted: it goes away when the head unit restarts"
    elif mounted; then
        echo "another package's file is laid over $TARGET: left as it is"
    else
        echo "overlay removed (or was not there)"
    fi
    # EQ on CarPlay's layer over the CarPlay app's JNI library, and the Lab driver watch, while the
    # file there is EQ Engine's own (never another package's mount on the same path)
    for t in "$R/system/lib/libCarPlayAndroid.so:eqe_cpwatch.so:EQ on CarPlay's layer" \
             "$R/system/lib/hw/audio.primary.tcc803x.so:eqe_drvwatch.so:the Lab driver watch"; do
        what=${t##*:}
        t=${t%:*}
        f=$D/lib/${t#*:}
        t=${t%%:*}
        i=0
        while [ $i -lt 5 ] && mounted_at "$t" && ours "$t" "$f"; do
            umount "$t"
            # busy while a process has the file loaded: detach it instead
            mounted_at "$t" && ours "$t" "$f" && [ -x $D/bin/eqe_lab ] && $D/bin/eqe_lab umount "$t"
            i=$((i + 1))
        done
        if mounted_at "$t" && ours "$t" "$f"; then
            echo "$what is still laid over $t: it goes away when the head unit restarts"
        elif mounted_at "$t"; then
            echo "another package's file is laid over $t: left as it is"
        fi
    done
    rm -f $D/state/lab_active
    # the CarPlay watch's choice for later car starts (0.6.10), and 0.6.7's setting for the CarPlay
    # app's next start, if either is still there
    if [ -f $D/state/cpw_want ]; then
        rm -f $D/state/cpw_want
        echo "CarPlay watch turned off for later car starts"
    fi
    case "$(getprop wrap.com.daudio.app.dipo)" in
        *eqe_cpwatch.so*) setprop wrap.com.daudio.app.dipo ""; echo "CarPlay watch setting cleared" ;;
    esac
    # the 48 kHz keeper puts 44.1 kHz back and stops once it sees "disabled"; then it is stopped.
    # (after 0.7.6) Not waited for while the factory CarPlay app plays to the main link itself
    # (state=other): the keeper can change nothing then, and would only be stopped after 15 s.
    if [ -f $D/state/keep.pid ]; then
        read kp < $D/state/keep.pid
        i=0
        while [ -n "$kp" ] && [ -f $PROC/$kp/cmdline ] && [ $i -lt 15 ] && ! keep_other; do
            sleep 1
            i=$((i + 1))
        done
        if [ -n "$kp" ] && [ -f $PROC/$kp/cmdline ]; then
            read c < $PROC/$kp/cmdline
            case "$c" in
                *act.sh*) kill $kp 2>/dev/null; echo "48 kHz keeper stopped" ;;
            esac
        fi
    fi
    if [ -f $D/state/hold/pid ]; then
        read hp < $D/state/hold/pid
        if [ -n "$hp" ] && [ -f $PROC/$hp/cmdline ]; then
            read c < $PROC/$hp/cmdline
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
