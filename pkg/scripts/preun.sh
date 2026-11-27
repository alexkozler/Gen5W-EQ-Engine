#!/system/bin/sh
# EQ Engine preuninstall (root). Turns the boot step off, removes the in-memory overlay and puts
# Android's audio converter setting back to its default now. NEMESIS then removes the app (which
# ends its EQ service) and the boot step; postuninstall deletes /data/eqengine.
# A restart afterwards gives a completely stock audio setup. Always exits 0.

# Tests (tests/install/run.sh) point the paths at a simulated unit; on the car R is empty.
R=${EQE_TEST_ROOT:-}
PROC=/proc
if [ -n "$R" ]; then
    PROC=$R/proc
    kill() { "$R/stubs/kill" "$@"; }
fi
D=$R/data/eqengine
TARGET=$R/system/etc/audio_effects.conf
# An update (after 0.7.6): NEMESIS has the new EQ Engine unpacked in its staging folder (its
# NEMESIS.data says id=eqengine; pkg.c cmd_install), and the nemesis command running this is not an
# uninstall, so a stage left by an interrupted install cannot turn an uninstall into an update
# (HMG-API's preuninstall tells the two apart the same way).
is_update() {
    _cl=""
    if [ -n "$R" ]; then
        _cl=${EQE_TEST_CALLER:-}
    elif [ -f /proc/$PPID/cmdline ]; then
        read -r _cl < /proc/$PPID/cmdline
    fi
    case "$_cl" in
        *uninstall*) return 1 ;;
    esac
    for _nd in $R/data/local/tmp/nemesis/stage/eqengine/NEMESIS.data $R/data/local/tmp/nemesis/stage/eqengine/*/NEMESIS.data; do
        [ -f "$_nd" ] || continue
        while IFS= read -r _nl || [ -n "$_nl" ]; do
            case "$_nl" in
                id=eqengine|id=eqengine?) return 0 ;;
            esac
        done < "$_nd"
    done
    return 1
}
# the 48 kHz keeper (act.sh keep), stopped only when its pid is still an act.sh
stop_keeper() {
    [ -f $D/state/keep.pid ] || return 0
    read kp < $D/state/keep.pid
    if [ -n "$kp" ] && [ -f $PROC/$kp/cmdline ]; then
        read c < $PROC/$kp/cmdline
        case "$c" in
            *act.sh*) kill $kp 2>/dev/null ;;
        esac
    fi
}
UPD=""
is_update && UPD=1
if [ -n "$UPD" ]; then
    # During an update the keeper is stopped before EQ Engine is marked off, so it does not put the
    # main output back to 44.1 kHz (the new version's keeper carries on at the rate it has), and
    # only once no track hold of its is in progress: a rate change in flight finishes first (15 s
    # at most).
    i=0
    while [ -d $D/state/hold ] && [ $i -lt 15 ]; do
        sleep 1
        i=$((i + 1))
    done
    stop_keeper
fi
mkdir -p $D/state
echo "uninstalled" > $D/state/disabled
rm -f $D/state/vhq_load
setprop af.resampler.quality 0
if [ -f $D/state/resampler.pid ]; then
    read p < $D/state/resampler.pid
    if [ -n "$p" ] && [ -f $PROC/$p/cmdline ]; then
        read c < $PROC/$p/cmdline
        case "$c" in
            *logcat*) kill $p 2>/dev/null ;;
        esac
    fi
fi

mounted_at() {
    while read _d _m _rest; do
        [ "$_m" = "$1" ] && return 0
    done < $PROC/mounts
    return 1
}

# mt_has <table> <path>: something is listed as mounted at <path> in that mount table (0.8.0)
mt_has() {
    while read _d _m _rest; do
        [ "$_m" = "$2" ] && return 0
    done < $1
    return 1
}

# (after 0.7.8) NEMESIS 1.17's LivePatch can lay a "farm" over a folder (a tmpfs of symlinks to a
# view of the stock folder); EQ Engine's mounts are then on the file a symlink points to. real_path
# <path>: the path with every symlink on the way followed, into RP (as in act.sh).
real_path() {
    RP=""
    _rp_t=${2:-}
    _rp_r=${1#/}
    _rp_n=0
    while [ -n "$_rp_r" ]; do
        case "$_rp_r" in
            */*) _rp_c=${_rp_r%%/*}; _rp_r=${_rp_r#*/} ;;
            *) _rp_c=$_rp_r; _rp_r="" ;;
        esac
        case "$_rp_c" in
            ''|.) continue ;;
            ..) RP=${RP%/*}; continue ;;
        esac
        if [ -L "$_rp_t$RP/$_rp_c" ] && [ $_rp_n -lt 16 ]; then
            _rp_n=$((_rp_n + 1))
            # the link's target from toolbox ls -l ("... name -> target")
            _rp_l=""
            set -f
            set -- $(ls -l "$_rp_t$RP/$_rp_c" 2>/dev/null)
            set +f
            while [ $# -gt 1 ]; do
                [ "$1" = "->" ] && { _rp_l=$2; break; }
                shift
            done
            case "$_rp_l" in
                '') ;;
                /*) RP=""; _rp_r=${_rp_l#/}${_rp_r:+/$_rp_r}; continue ;;
                *) _rp_r=$_rp_l${_rp_r:+/$_rp_r}; continue ;;
            esac
        fi
        RP=$RP/$_rp_c
    done
    [ -n "$RP" ] || RP=/
}

# 0 = the file at $1 is now EQ Engine's own $2, byte for byte (0.7.6: EQ Engine unmounts only its
# own mounts, never another package's at the same path)
ours() {
    [ -f "$2" ] || return 1
    set -- $(md5 "$1" 2>/dev/null) $(md5 "$2" 2>/dev/null)
    [ -n "$1" ] && [ "$1" = "$3" ]
}
i=0
real_path $TARGET
TP=$RP
while mounted_at $TP && ours $TP $D/conf/audio_effects.conf && [ $i -lt 5 ]; do
    umount $TP
    i=$((i + 1))
    mounted_at $TP && sleep 1
done
# The other bind mounts, while the file there is EQ Engine's own (never another package's mount on
# the same path; 0.7.6, and after 0.7.6 for the driver watch too): EQ on CarPlay's layer over the
# CarPlay app's JNI library (a CarPlay app that runs it keeps it until it next starts; with the
# app's files gone it passes the music through untouched), and the Lab driver watch. (0.6.0's
# 48 kHz policy copy cannot outlast a car start, so a mount on audio_policy.conf is not EQ
# Engine's and is left alone.)
for t in /system/lib/hw/audio.primary.tcc803x.so:eqe_drvwatch.so /system/lib/libCarPlayAndroid.so:eqe_cpwatch.so; do
    f=$D/lib/${t#*:}
    real_path $R${t%%:*}
    t=$RP
    i=0
    while [ $i -lt 5 ] && mounted_at $t && ours $t $f; do
        umount $t
        # busy while a process has the file loaded: detach it (that process keeps what it has
        # until the car restarts), and only while EQ Engine's file is still the one on top
        mounted_at $t && ours $t $f && [ -x $D/bin/eqe_lab ] && $D/bin/eqe_lab umount $t > /dev/null 2>&1
        i=$((i + 1))
    done
done
# (0.8.0) EQ on CarPlay's layer may be laid over in the zygote's mount namespace instead (act.sh
# cpw_ns: the CarPlay library reached through a NEMESIS LivePatch farm, the zygote in another mount
# namespace): taken off there too, while the file there is EQ Engine's own. Left there, the CarPlay
# app's next start in this car start would load a layer whose files are gone.
zygote_pid() {
    for _zf in $PROC/[0-9]*/stat; do
        [ -f $_zf ] || continue
        _zl=""
        { read -r _zl < $_zf; } 2>/dev/null
        set -f
        set -- $_zl
        set +f
        [ "$2" = "(zygote)" ] && [ "$4" = 1 ] || continue
        echo "$1"
        return 0
    done
    return 1
}
Z=$(zygote_pid)
if [ -n "$Z" ] && [ -x $D/bin/eqe_lab ] && [ -f $PROC/$Z/mounts ]; then
    real_path $R/system/lib/libCarPlayAndroid.so $PROC/$Z/root
    t=$RP
    f=$D/lib/eqe_cpwatch.so
    UM=$(command -v umount)
    i=0
    while [ $i -lt 5 ] && mt_has $PROC/$Z/mounts $t && ours $PROC/$Z/root$t $f; do
        $D/bin/eqe_lab ns $Z $UM $t > /dev/null 2>&1 || $D/bin/eqe_lab ns $Z $D/bin/eqe_lab umount $t > /dev/null 2>&1
        i=$((i + 1))
    done
fi
rm -f $D/state/lab_active $D/state/cpw_want
# 0.6.7's wrap property for the CarPlay app's next start, if an old install left it (it lasts one
# start)
case "$(getprop wrap.com.daudio.app.dipo)" in
    *eqe_cpwatch.so*) setprop wrap.com.daudio.app.dipo "" ;;
esac
# The 48 kHz keeper (act.sh keep) puts the main output back to 44.1 kHz and stops once it sees
# "disabled"; it gets some seconds for that (a change holds the output's tracks first), then it
# is stopped (during an update it was stopped above already). Its helper (Hold.java) is stopped
# too: Android then releases the helper's filters. (after 0.7.6) Not waited for while the factory
# CarPlay app plays to the main link itself (state=other): the keeper can change nothing then.
keep_other() {
    [ -f $D/state/output ] || return 1
    while IFS='=' read -r _ok _ov; do
        [ "$_ok" = state ] && [ "$_ov" = other ] && return 0
    done < $D/state/output
    return 1
}
if [ -z "$UPD" ] && [ -f $D/state/keep.pid ]; then
    read kp < $D/state/keep.pid
    i=0
    while [ -n "$kp" ] && [ -f $PROC/$kp/cmdline ] && [ $i -lt 15 ] && ! keep_other; do
        sleep 1
        i=$((i + 1))
    done
    stop_keeper
fi
if [ -f $D/state/hold/pid ]; then
    read hp < $D/state/hold/pid
    if [ -n "$hp" ] && [ -f $PROC/$hp/cmdline ]; then
        read c < $PROC/$hp/cmdline
        case "$c" in
            *app_process*) kill $hp 2>/dev/null ;;
        esac
    fi
fi
sleep 3
exit 0
