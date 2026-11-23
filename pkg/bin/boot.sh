#!/system/bin/sh
# EQ Engine boot step (NEMESIS service eqengine/boot, runs as root at every start).
#
# What it does: lays EQ Engine's copy of Android's effects list over the stock one, in memory
# only (a bind mount), so Android's audio server can load the EQ Engine filter. /system is never
# written. A restart without this step running gives the stock list back.
#
# Failsafes:
#  - Applies only if the stock list is byte-for-byte the one this package was built from (md5).
#  - Two-strike rule: it marks "applied" before mounting and "good" after GOOD_AFTER seconds
#    with no unexpected audio-server restart. A start that never reached "good" is a strike;
#    two strikes in a row turn EQ Engine off until the app turns it back on.
#  - Crash watch: if Android's audio server restarts unexpectedly twice within 60 seconds, or
#    three times in one start, it removes the overlay and turns EQ Engine off.
#  - /data/eqengine/state/disabled (written by the app or the rescue stick) turns it off: the
#    overlay is removed within seconds and later starts skip this step.
#
# Stage 2 additions:
#  - Audio converter: sets af.resampler.quality before music starts, from settings/converter
#    (the Lab's choice: 4 very high quality, the default; 3 high; 0 Android's default), and
#    records the audio server's own confirmation line to state/resampler.log. Turning off or the
#    crash watch put it back to 0. It is a run-time property: a start without this step has
#    Android's default. Fallbacks: tables that fail their check make that start use 3
#    (state/conv_fallback says why); each unexpected audio server restart steps the choice down
#    one level (4 -> 3 -> 0), kept in settings/converter with the reason in state/conv_cut.
#  - Very high quality: with EQ Engine's converter tables (lib/libaudio-resampler.so) matching
#    the md5 recorded at install, it sets af.resampler.quality=4 and leaves state/vhq_load. The
#    EQ Engine filter, which
#    Android's audio server loads with its effect list when it opens its outputs (before any app
#    can play, so before it converts any audio), then loads those tables into the audio server
#    (only there). Without the marker nothing is loaded and 4 behaves like 3. The marker stays
#    between starts, so it is already there when the next start's audio server comes up.
#  - 48 kHz output: once Android has started, this step starts "act.sh keep" in the background
#    (and again if it stops). The keeper switches the main output to 48 kHz while music plays and
#    checks it every time (see act.sh). An unexpected audio server restart within 20 s of one of
#    its switches (state/rate48_sent) is put down to the switch: 48 kHz output is turned off in
#    the settings (state/rate48_cut says why), and the restart neither steps the converter down
#    nor counts towards "kept restarting".
#  - Lab CarPlay watch (act.sh cpwatch, 0.6.10): when it is on (state/cpw_want), "act.sh cpwboot"
#    lays it over the CarPlay app's JNI library before Android starts that app.
#  - Lab driver watch (act.sh lab): an in-memory bind mount, gone at the next car start (this step
#    then clears state/lab_active). An unexpected audio server restart while it is on removes it
#    at once; such restarts (and those in the next 60 s) are put down to it: they neither step the
#    converter down nor count towards "kept restarting".
#  - Once Android has finished starting, it starts the EQ Engine app's background service,
#    which attaches the EQ to all music and re-attaches it after an audio restart. A watchdog
#    checks every 60 s that the app's process is there and starts the service again if not.
# Toolbox only: no awk, sed, grep, head or busybox.

umask 022
VER=0.7.6
D=/data/eqengine
S=$D/state
TARGET=/system/etc/audio_effects.conf
VENDOR=/vendor/etc/audio_effects.conf
OURS=$D/conf/audio_effects.conf
LIB=$D/lib/libeqengine.so
VHQLIB=$D/lib/libaudio-resampler.so
VHQSUM=$D/conf/libaudio-resampler.md5
SET=$D/settings
HAL_T=/system/lib/hw/audio.primary.tcc803x.so
POL_T=/system/etc/audio_policy.conf
SVC=com.eqengine.app/.EqService
KEEP_CMD="sh $D/bin/act.sh keep"
CPW_CMD="sh $D/bin/act.sh cpwboot"
EXPECT_ORIG=4d98c1b38bd1d9eaf929d9b616c0d118
EXPECT_OURS=69613834029b0e891c927e5843077c0d
GOOD_AFTER=45
# Tests can point these elsewhere.
[ -n "$EQE_TEST_ROOT" ] && {
    D=$EQE_TEST_ROOT/data/eqengine; S=$D/state; OURS=$D/conf/audio_effects.conf; LIB=$D/lib/libeqengine.so; SET=$D/settings
    VHQLIB=$D/lib/libaudio-resampler.so; VHQSUM=$D/conf/libaudio-resampler.md5
    HAL_T=$EQE_TEST_ROOT/system/lib/hw/audio.primary.tcc803x.so; POL_T=$EQE_TEST_ROOT/system/etc/audio_policy.conf
    TARGET=$EQE_TEST_ROOT/system/etc/audio_effects.conf; VENDOR=$EQE_TEST_ROOT/vendor/etc/audio_effects.conf
    [ -n "$EQE_GOOD_AFTER" ] && GOOD_AFTER=$EQE_GOOD_AFTER
    [ -n "$EQE_KEEP_CMD" ] && KEEP_CMD=$EQE_KEEP_CMD
    [ -n "$EQE_CPW_CMD" ] && CPW_CMD=$EQE_CPW_CMD
}
PROC=${EQE_PROC:-/proc}

up() { read _u _r < $PROC/uptime; echo "${_u%%.*}"; }

event() {
    echo "$(up) $*"
    echo "$(up) $*" >> $S/events.log
}

mounted() {
    while read _d _m _rest; do
        [ "$_m" = "$TARGET" ] && return 0
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

md5of() {
    set -- $(md5 "$1" 2>/dev/null)
    echo "$1"
}

ms_pid() {
    # Reads all of ps's output: stopping early would kill ps with SIGPIPE (and leave a tombstone).
    ps | {
        _f=""
        while read _u _p _pp _v _r _w _pc _s _n _x; do
            [ -z "$_f" ] && [ "$_n" = /system/bin/mediaserver ] && _f=$_p
        done
        [ -n "$_f" ] && echo "$_f"
    }
}

# Android's zygote: /proc/<pid>/stat names it "(zygote)", its parent is init (as act.sh's
# zygote_pid; the shells drop the NUL bytes of cmdline, so it is not read)
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

# The log at an unexpected audio server restart (0.6.12): Android's log holds about a minute, so
# by the next All logs save the cause is gone (0.6.11: a start that restarted the audio server at
# 17 s and then the whole unit left nothing). state/crash.log, the one before as crash.prev.log;
# root only (it holds what the log holds: logs are private), copied by All logs.
crash_snapshot() {
    [ -f $S/crash.log ] && mv $S/crash.log $S/crash.prev.log
    {
        echo "$(up) $1"
        echo "--- logcat (main, system, events)"
        logcat -d -v threadtime -b main -b system -b events 2>&1
        echo "--- kernel log"
        dmesg 2>&1
    } > $S/crash.log
    chmod 600 $S/crash.log
}

flat() {
    # one line, for the event log
    set -- $*
    echo "$*"
}

vhq_ok() {
    # EQ Engine's converter tables are there and are the ones installed (md5 recorded at install)
    [ -f $VHQLIB ] && [ -f $VHQSUM ] || return 1
    _want=""
    read _want < $VHQSUM
    [ -n "$_want" ] && [ "$(md5of $VHQLIB)" = "$_want" ]
}

conv_want() {
    # The Lab's converter choice: 4 very high quality (the default), 3 high, 0 Android's default.
    # Settings from 0.5: vhq=1 -> 4, vhq=0 -> 3.
    _w=""
    [ -f $SET/converter ] && read _w < $SET/converter
    case "$_w" in
        0|3|4) echo "$_w"; return ;;
    esac
    _v=""
    [ -f $SET/vhq ] && read _v < $SET/vhq
    case "$_v" in
        0) echo 3 ;;
        *) echo 4 ;;
    esac
}

conv_quality() {
    # Sets CONV to what this start uses. Leaves $S/vhq_load (read by the EQ Engine filter in the
    # audio server) exactly when it is 4; the marker is rewritten in place, never removed first,
    # so an audio server starting right now sees it. Falls back to 3 when the tables fail their
    # check. (Called directly, not in $(...): its event lines must not end up in CONV.)
    rm -f $S/conv_fallback
    CONV=$(conv_want)
    if [ "$CONV" = 4 ]; then
        if vhq_ok; then
            echo 1 > $S/vhq_load
            chmod 644 $S/vhq_load
            return
        fi
        CONV=3
        echo "EQ Engine's converter tables failed their check" > $S/conv_fallback
        chmod 644 $S/conv_fallback
        event "very high quality converter: EQ Engine's converter tables failed their check; using high quality"
    fi
    rm -f $S/vhq_load
}

maps_has() {
    # $1 = pid, $2 = file name: is it mapped into that process?
    [ -f $PROC/$1/maps ] || return 1
    while read _a _p _o _d _i _f; do
        case "$_f" in
            */$2) return 0 ;;
        esac
    done < $PROC/$1/maps
    return 1
}

conv_step_down() {
    # $1 = why. One level down from what the audio server was using (very high -> high ->
    # Android's default), kept in the settings until changed in the app; the app shows why.
    _q=$(getprop af.resampler.quality)
    if [ -f $S/vhq_load ] || [ "$_q" = 4 ]; then
        _to=3
    elif [ "$_q" = 3 ]; then
        _to=0
    else
        return
    fi
    rm -f $S/vhq_load
    echo "$1" > $S/conv_cut
    chmod 644 $S/conv_cut
    if [ -d $SET ]; then
        echo $_to > $SET/converter
        chmod 644 $SET/converter
    fi
    setprop af.resampler.quality $_to
    CONV=$_to
    event "audio converter stepped down to $_to: $1"
}

lab_mounted() {
    while read _d _m _rest; do
        [ "$_m" = "$HAL_T" ] || [ "$_m" = "$POL_T" ] && return 0
    done < $PROC/mounts
    return 1
}

lab_recent() {
    # act.sh ended a failed Lab test less than 60 s ago
    [ -f $S/lab_ended ] || return 1
    read _le < $S/lab_ended
    _le=$(num "${_le%%.*}")
    [ $((NOW - _le)) -ge 0 ] && [ $((NOW - _le)) -le 60 ]
}

rate48_recent() {
    # the 48 kHz keeper switched the main output less than 20 s ago
    [ -f $S/rate48_sent ] || return 1
    read _rs < $S/rate48_sent
    _rs=$(num "${_rs%%.*}")
    [ $((NOW - _rs)) -ge 0 ] && [ $((NOW - _rs)) -le 20 ]
}

keep_alive() {
    [ -f $S/keep.pid ] || return 1
    read _kp < $S/keep.pid
    _kp=$(num "$_kp")
    [ $_kp -gt 0 ] && [ -d $PROC/$_kp ]
}

keep_start() {
    $KEEP_CMD < /dev/null > /dev/null 2>&1 &
    echo $! > $S/keep.pid
    chmod 644 $S/keep.pid
}

lab_off() {
    # removes both Lab overlays (driver watch, 0.6.0's 48 kHz policy); 0 when none is left
    for _t in $HAL_T $POL_T; do
        _i=0
        while [ $_i -lt 5 ]; do
            _m=0
            while read _d _mp _rest; do
                [ "$_mp" = "$_t" ] && _m=1
            done < $PROC/mounts
            [ $_m = 0 ] && break
            umount $_t
            _i=$((_i + 1))
        done
    done
    rm -f $S/lab_active
    ! lab_mounted
}

stop_capture() {
    if [ -f $S/resampler.pid ]; then
        read _p < $S/resampler.pid
        if [ -n "$_p" ] && [ -f $PROC/$_p/cmdline ]; then
            read _c < $PROC/$_p/cmdline
            case "$_c" in
                *logcat*) kill $_p 2>/dev/null ;;
            esac
        fi
        rm -f $S/resampler.pid
    fi
}

start_capture() {
    # The audio server logs "forcing AudioResampler quality to N" when it first converts.
    # Android 4.4's logcat stops reading options at the first filter (tag:level), so every option
    # comes first and the filters last; without rotation (a few lines per audio server start, and
    # a new start begins a new file).
    stop_capture
    logcat -v time -f $S/resampler.log -s AudioResampler:D AudioResamplerSinc:E < /dev/null > /dev/null 2>&1 &
    echo $! > $S/resampler.pid
}

reset_conv() {
    rm -f $S/vhq_load
    setprop af.resampler.quality 0
    stop_capture
    CONV=0
}

app_running() {
    ps | {
        _f=""
        while read _u _p _pp _v _r _w _pc _s _n _x; do
            [ "$_n" = com.eqengine.app ] && _f=yes
        done
        [ -n "$_f" ] && echo yes
    }
}

num() {
    case "$1" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$1" ;;
    esac
}

STATE=starting
REASON=""
CONV=""
SVC_STARTED=0
OVERLAY=0
MSPID=""
ZYPID=""
MSR=0
APPLIED_AT=0
GOOD=0

# The status for the app, written only when it changes (0.7.6: it was written every round, every
# 5 s for as long as the car ran). "updated" is when it last changed.
STATUS_LAST=""
write_status() {
    _st="version=$VER
boot_id=$BID
state=$STATE
reason=$REASON
overlay=$OVERLAY
strikes=$STRIKES
audio_server_pid=$MSPID
unexpected_restarts=$MSR
applied_at=$APPLIED_AT
good=$GOOD
converter=$CONV
service=$SVC_STARTED"
    [ -f $S/status ] && [ "$_st" = "$STATUS_LAST" ] && return 0
    {
        echo "$_st"
        echo "updated=$(up)"
    } > $S/status.tmp
    chmod 644 $S/status.tmp
    mv $S/status.tmp $S/status
    STATUS_LAST=$_st
}

set_lastboot() {
    echo "$BID $1" > $S/lastboot
    chmod 644 $S/lastboot
}

unmount_all() {
    lab_off
    _i=0
    while mounted && ours $TARGET $OURS && [ $_i -lt 5 ]; do
        umount $TARGET
        _i=$((_i + 1))
        mounted && sleep 1
    done
    mounted && ours $TARGET $OURS && return 1
    return 0
}

stop_here() {
    # $1 = state, $2 = reason, $3 = lastboot phase
    STATE=$1
    REASON=$2
    [ -n "$3" ] && set_lastboot "$3"
    event "$STATE: $REASON"
    write_status
    exit 0
}

# uptime with its decimals ("3.12"), with no subshell
up_at() { read _ua _ur < $PROC/uptime; UP_AT=$_ua; }

# clock ticks (1/100 s, as in /proc/<pid>/stat) -> seconds with two decimals (CS_SECS)
cs_secs() {
    _ct=$(($1 / 100))
    _cc=$(($1 % 100))
    [ $_cc -lt 10 ] && _cc=0$_cc
    CS_SECS=$_ct.$_cc
}

# $1 = pid: STAT_START = when it started, seconds after power-on ("" if not known)
stat_start() {
    STAT_START=""
    [ -f $PROC/$1/stat ] || return 0
    _sl=""
    { read -r _sl < $PROC/$1/stat; } 2>/dev/null
    set -f
    set -- $_sl
    set +f
    [ $# -ge 22 ] || return 0
    case "${22}" in
        ''|*[!0-9]*) return 0 ;;
    esac
    cs_secs ${22}
    STAT_START=$CS_SECS
}

# $1 = pid: FX = ours (EQ Engine's filter is loaded, so it read EQ Engine's list), factory (effect
# libraries from the factory list and not EQ Engine's) or none (no effect library loaded yet)
fx_now() {
    FX=none
    [ -f $PROC/$1/maps ] || return 0
    while read _a _p _o _d _i _f; do
        case "$_f" in
            */libeqengine.so) FX=ours; return 0 ;;
            */soundfx/*) FX=factory ;;
        esac
    done < $PROC/$1/maps
}

# Where Android's audio server was when the overlay went in (0.6.9): state/boot_timing and one
# event line. If it had already loaded the factory list, this start has no EQ Engine until Android's
# audio restarts: state/late_list tells the app, which offers that restart (parked). Not right
# after an install: that audio server started before EQ Engine existed (expected, and the install
# says to restart the car).
# Right after the mount (0.6.10), with builtins only: the audio server's pid and what it has
# loaded at that moment (SNAP_MS, SNAP_FX, T_CHECK). 0.6.9 looked after the housekeeping, so a list
# read in between could not be told from one read before the overlay.
snap_ms() {
    SNAP_MS=""
    for _sf in $PROC/[0-9]*/stat; do
        [ -f $_sf ] || continue
        _sl=""
        { read -r _sl < $_sf; } 2>/dev/null
        case "$_sl" in
            *" (mediaserver) "*) SNAP_MS=${_sl%% *}; break ;;
        esac
    done
    SNAP_FX=unknown
    if [ -n "$SNAP_MS" ]; then
        fx_now $SNAP_MS
        SNAP_FX=$FX
    fi
    up_at
    T_CHECK=$UP_AT
}

early_check() {
    _ms=$SNAP_MS
    stat_start $$
    T_PROC=$STAT_START
    MS_START=""
    FX_AT=$SNAP_FX
    [ -n "$_ms" ] || FX_AT=unknown
    if [ -n "$_ms" ]; then
        stat_start $_ms
        MS_START=$STAT_START
    fi
    RESULT=unknown
    case "$FX_AT" in
        ours|none) RESULT=in_time ;;
        factory)
            # it may be loading the list right now: look again in a moment
            sleep 1
            fx_now $_ms
            if [ "$FX" = ours ]; then RESULT=in_time; else RESULT=late; fi
            ;;
    esac
    case "$FX_AT" in
        ours) _fxt="EQ Engine's effects list" ;;
        factory) _fxt="the factory effects list" ;;
        none) _fxt="no effect library yet" ;;
        *) _fxt="? (not found)" ;;
    esac
    {
        echo "boot_id=$BID"
        echo "step_start=$T_START"
        echo "step_process=$T_PROC"
        echo "overlay_at=$T_MOUNT"
        echo "checked_at=$T_CHECK"
        echo "audio_server_pid=$_ms"
        echo "audio_server_start=$MS_START"
        echo "loaded_at_overlay=$FX_AT"
        echo "result=$RESULT"
        echo "fresh_install=$FRESH"
    } > $S/boot_timing
    chmod 644 $S/boot_timing
    event "timing: this step started at ${T_START} s (its process at ${T_PROC:-?} s), the overlay was in place at ${T_MOUNT} s; Android's audio server (pid ${_ms:-not found}) started at ${MS_START:-?} s and had loaded at ${T_CHECK:-?} s: $_fxt"
    if [ "$RESULT" = late ] && [ $FRESH = 0 ]; then
        echo "$BID $_ms" > $S/late_list
        chmod 644 $S/late_list
        REASON="effects list overlay applied, but the audio server read its effects list before it: EQ Engine is not active until Android's audio is restarted (parked)"
        event "Android's audio server ($_ms) read the factory effects list before the overlay was in place: EQ Engine is not active this start. Restart Android audio once (parked); the EQ Engine app offers it"
    fi
}

# ---- The overlay first (0.6.9). Android's audio server is started by init at the same moment as
# NEMESIS (class main, about 2.9 s after power-on) and reads its effects list once, early. Until
# the mount, this step does only what guards it, with shell builtins where it can (two md5s are
# the exception): no event lines, no chmod, no housekeeping. Those come right after.
up_at
T_START=$UP_AT
T_MOUNT=""
SNAP_MS=""
SNAP_FX=unknown
T_CHECK=""
[ -d $S ] || mkdir -p $S

BID=""
[ -f $PROC/sys/kernel/random/boot_id ] && read BID < $PROC/sys/kernel/random/boot_id
[ -n "$BID" ] || BID="unknown-${T_START%%.*}"

# Started by NEMESIS right after an install? (postinstall leaves this; only this run uses it)
FRESH=0
[ -f $S/fresh_install ] && FRESH=1

STRIKES=0
[ -f $S/strikes ] && read STRIKES < $S/strikes
case "$STRIKES" in
    ''|*[!0-9]*) STRIKES=0 ;;
esac

# How did the previous start end? (its event line is written after the mount)
EV_PREV=""
if [ -f $S/lastboot ]; then
    read PBID PPHASE < $S/lastboot
    if [ "$PBID" != "$BID" ]; then
        case "$PPHASE" in
            applied|crashed)
                STRIKES=$((STRIKES + 1))
                EV_PREV="previous start ended before it was confirmed good ($PPHASE): strike $STRIKES"
                ;;
            installed)
                EV_PREV="previous start was the install's (the running audio server could not load the filter yet): not counted"
                ;;
            good)
                STRIKES=0
                ;;
        esac
        echo $STRIKES > $S/strikes
    fi
fi

# A start that lays no overlay: NM_STATE, NM_REASON, NM_PHASE (stop_here after the housekeeping)
NM_STATE=""
PRE_MOUNTED=0
if [ -f $S/disabled ]; then
    read WHY < $S/disabled
    NM_STATE=off; NM_REASON="turned off ($WHY). Turn it back on in the EQ Engine app."; NM_PHASE=off
elif [ $STRIKES -ge 2 ]; then
    echo "two starts in a row ended before EQ Engine was confirmed good" > $S/disabled
    NM_STATE=off; NM_REASON="two starts in a row ended before EQ Engine was confirmed good. Turn it back on in the app."; NM_PHASE=off
elif [ -f $VENDOR ]; then
    NM_STATE=refused; NM_REASON="this unit has $VENDOR, which Android reads instead; not applying"; NM_PHASE=refused
elif mounted; then
    # Already applied during this start (the service was restarted, for example by a reinstall).
    PRE_MOUNTED=1
elif [ ! -f $LIB ]; then
    NM_STATE=refused; NM_REASON="the filter library is missing ($LIB)"; NM_PHASE=refused
elif [ ! -f $OURS ]; then
    NM_STATE=refused; NM_REASON="EQ Engine's effects list is missing ($OURS)"; NM_PHASE=refused
else
    O=$(md5of $TARGET)
    W=""
    [ "$O" = "$EXPECT_ORIG" ] && W=$(md5of $OURS)
    if [ "$O" != "$EXPECT_ORIG" ]; then
        NM_STATE=refused; NM_REASON="Android's effects list is not the one this package was built for (md5 $O); not applying"; NM_PHASE=refused
    elif [ "$W" != "$EXPECT_OURS" ]; then
        NM_STATE=refused; NM_REASON="EQ Engine's copy of the effects list is damaged (md5 $W); not applying"; NM_PHASE=refused
    else
        # Mark first: if the unit restarts during or right after this, the next start counts a
        # strike. Except right after an install (state/fresh_install, from postinstall): the audio
        # server that is running then started before the install and cannot load the filter until
        # it restarts, so that start can never be confirmed good, and restarting the car after
        # installing is the instruction. That start is marked "installed" and does not count.
        PHASE=applied
        [ $FRESH = 1 ] && PHASE=installed
        echo "$BID $PHASE" > $S/lastboot
        if mount -o bind $OURS $TARGET; then
            up_at
            T_MOUNT=$UP_AT
            snap_ms
        else
            NM_STATE=refused; NM_REASON="the in-memory overlay could not be mounted"; NM_PHASE=refused
        fi
    fi
fi

# ---- Housekeeping (after the mount)
chmod 755 $D $S
# Stage 1 left some of these writable by everyone. The crash logs (raw system and kernel logs,
# with personal data) stay readable by root only (0.7.6: they were made 644 here too).
for _f in $S/*; do
    case "${_f##*/}" in
        crash.log|crash.prev.log) [ -f "$_f" ] && chmod 600 "$_f" ;;
        *) [ -f "$_f" ] && chmod 644 "$_f" ;;
    esac
done
rm -f $S/fresh_install

# First run in this start: drop what only meant something in the previous start (audio server
# pids and uptimes repeat across starts, so old converter lines or restart times would mislead).
_rb=""
[ -f $S/runboot ] && read _rb < $S/runboot
if [ "$_rb" != "$BID" ]; then
    # the previous start's timing and late-list note
    rm -f $S/late_list $S/boot_timing
    rm -f $S/resampler.log $S/resampler.log.1 $S/resampler_now.log $S/last_restart $S/expected_restart
    rm -rf $S/restart.lock
    # Lab tests and the 48 kHz switch are in memory: a new start has neither
    rm -f $S/lab_active $S/lab_ended $S/rate48 $S/rate48_sent $S/output $S/keep.pid $S/af.txt
    # Hold.java (48 kHz switches) does not outlive a car start
    rm -rf $S/hold
    [ -f $S/output.log ] && mv $S/output.log $S/output.prev.log
    [ -f $S/lab_result ] && mv $S/lab_result $S/lab_result.prev
    # the CarPlay watch's mount is gone at a car start (act.sh cpwboot below lays it over again if
    # it is on: state/cpw_want stays); its notes stay for All logs
    rm -f $S/cpwatch $S/cpwatch.tmp $S/cpw_restarts
    [ -f $S/cpw_result ] && mv $S/cpw_result $S/cpw_result.prev
    echo "$BID" > $S/runboot
fi

# Size cap for the event log (toolbox ls -l: size is the 4th field).
if [ -f $S/events.log ]; then
    set -- $(ls -l $S/events.log)
    [ "$(num $4)" -gt 65536 ] && mv $S/events.log $S/events.old.log
fi

[ -n "$EV_PREV" ] && event "$EV_PREV"
event "EQ Engine boot step $VER starting (strikes $STRIKES)"
[ -n "$NM_STATE" ] && stop_here "$NM_STATE" "$NM_REASON" "$NM_PHASE"

if [ $PRE_MOUNTED = 1 ]; then
    OVERLAY=1
    APPLIED_AT=$(up)
    STATE=applied
    REASON="effects list overlay was already in place"
    event "$REASON"
else
    chmod 755 $D $D/lib $D/conf
    chmod 644 $LIB $OURS
    if ! mounted || [ "$(md5of $TARGET)" != "$EXPECT_OURS" ]; then
        unmount_all
        stop_here refused "the overlay did not check out after mounting; removed it" refused
    fi
    OVERLAY=1
    APPLIED_AT=${T_MOUNT%%.*}
    STATE=applied
    REASON="effects list overlay applied; waiting $GOOD_AFTER s to confirm"
    event "effects list overlay applied"
    early_check
fi

conv_quality
setprop af.resampler.quality $CONV
start_capture
if [ "$CONV" = 4 ]; then
    event "audio converter: very high quality requested (af.resampler.quality=4, EQ Engine's tables)"
elif [ "$CONV" = 3 ]; then
    event "audio converter: high quality requested (af.resampler.quality=3)"
else
    event "audio converter: Android default requested (af.resampler.quality=0)"
fi
MSPID=$(ms_pid)
# right after an install: the audio server running now (it started before the install)
FRESH_MS=""
[ $FRESH = 1 ] && FRESH_MS=$MSPID
event "audio server pid ${MSPID:-not found yet}"
# The CarPlay watch, when it is on (0.6.10): laid over the CarPlay app's JNI library now, before
# Android starts the app (about 10 s after power-on), so the app is never restarted for it.
if [ -f $S/cpw_want ]; then
    _cpo=$($CPW_CMD 2>/dev/null)
    while read -r _cpl; do
        case "$_cpl" in
            "EQE_CPW "*) event "CarPlay watch: ${_cpl#EQE_CPW }" ;;
        esac
    done <<EOL
$_cpo
EOL
fi
LASTR=0
LASTWD=0
LASTCH=0
LAB_GRACE=0
while :; do
    NOW=$(up)
    if [ -f $S/disabled ]; then
        read WHY < $S/disabled
        reset_conv
        if unmount_all; then
            OVERLAY=0
            stop_here off "turned off ($WHY); overlay removed" off
        fi
        OVERLAY=1
        stop_here error "turned off ($WHY), but the overlay could not be removed; it goes away at the next start" off
    fi
    if [ -n "$MSPID" ] && [ ! -d $PROC/$MSPID ]; then
        # a new audio server reads the list again, with the overlay in place
        rm -f $S/late_list
        EXP=0
        if [ -f $S/expected_restart ]; then
            read E < $S/expected_restart
            E=$(num "${E%%.*}")
            [ $((NOW - E)) -le 30 ] && EXP=1
            rm -f $S/expected_restart
        fi
        sleep 1
        NEW=$(ms_pid)
        # init restarts the audio server whenever Android's framework (the zygote) restarts
        # (init.rc: zygote "onrestart restart media"): then the cause is not in the audio server
        ZYNEW=""
        if [ -n "$ZYPID" ] && [ ! -d $PROC/$ZYPID ]; then
            ZYNEW=$(zygote_pid)
            ZYNEW=${ZYNEW:-?}
        fi
        if [ $EXP = 1 ]; then
            event "audio server restarted on request (pid $MSPID -> ${NEW:-?})"
        elif [ -n "$ZYNEW" ]; then
            event "audio server restarted with Android's framework (zygote $ZYPID -> $ZYNEW, audio server $MSPID -> ${NEW:-?}): init restarts the audio server with it, so it is not counted against EQ Engine and the converter is kept; the log is in state/crash.log"
            crash_snapshot "Android's framework restarted: zygote $ZYPID -> $ZYNEW, audio server $MSPID -> ${NEW:-?}"
            ZYPID=""
            [ "$ZYNEW" != "?" ] && ZYPID=$ZYNEW
        elif rate48_recent; then
            # right after a 48 kHz switch: turn 48 kHz output off and put the restart down to it
            rm -f $S/rate48_sent $S/rate48
            echo "the audio server restarted right after a switch to 48 kHz" > $S/rate48_cut
            chmod 644 $S/rate48_cut
            if [ -d $SET ]; then
                echo 0 > $SET/rate48
                chmod 644 $SET/rate48
            fi
            LAB_GRACE=$((NOW + 60))
            event "audio server restarted unexpectedly right after a 48 kHz switch (pid $MSPID -> ${NEW:-?}); 48 kHz output turned off"
            crash_snapshot "the audio server restarted right after a 48 kHz switch: pid $MSPID -> ${NEW:-?}"
        elif [ -f $S/lab_active ] || [ $NOW -lt $LAB_GRACE ] || lab_recent; then
            # a Lab test was on: take it off at once and put this (and the next 60 s) down to it
            _la=""
            [ -f $S/lab_active ] && read _la < $S/lab_active
            lab_off
            [ -n "$_la" ] && echo "$NOW ended:$_la was on when the audio server restarted unexpectedly; removed" >> $S/lab_result
            chmod 644 $S/lab_result 2>/dev/null
            [ -n "$_la" ] && LAB_GRACE=$((NOW + 60))
            event "audio server restarted unexpectedly during a Lab test (pid $MSPID -> ${NEW:-?}); Lab tests removed"
            crash_snapshot "the audio server restarted during a Lab test: pid $MSPID -> ${NEW:-?}"
        else
            MSR=$((MSR + 1))
            event "audio server restarted unexpectedly ($MSR this start): pid $MSPID -> ${NEW:-?}; the log is in state/crash.log"
            crash_snapshot "the audio server restarted unexpectedly: pid $MSPID -> ${NEW:-?}"
            conv_step_down "the audio server restarted unexpectedly"
            if [ $MSR -ge 3 ] || { [ $LASTR -gt 0 ] && [ $((NOW - LASTR)) -le 60 ]; }; then
                echo "Android's audio server kept restarting" > $S/disabled
                reset_conv
                if unmount_all; then OVERLAY=0; fi
                stop_here crashed "Android's audio server kept restarting; EQ Engine removed itself and is off until you turn it back on" crashed
            fi
            LASTR=$NOW
        fi
        MSPID=$NEW
    elif [ -z "$MSPID" ]; then
        MSPID=$(ms_pid)
    fi
    # Android's zygote, to tell a framework restart from an audio server crash (looked up again
    # only while not known)
    [ -z "$ZYPID" ] && ZYPID=$(zygote_pid)
    if [ $GOOD = 0 ] && [ $OVERLAY = 1 ] && [ $MSR = 0 ] && [ $((NOW - APPLIED_AT)) -ge $GOOD_AFTER ]; then
        GOOD=1
        STRIKES=0
        echo 0 > $S/strikes
        set_lastboot good
        REASON="effects list overlay applied and confirmed"
        event "confirmed good"
        if [ -n "$MSPID" ] && [ -f $PROC/$MSPID/maps ] && ! maps_has $MSPID libeqengine.so && \
           [ $FRESH = 1 ] && [ "$MSPID" = "$FRESH_MS" ]; then
            # Right after an install, the audio server that was already running started before EQ
            # Engine existed: expected, and the install's instructions say to restart the car.
            REASON="effects list overlay applied; just installed: the running audio server started before EQ Engine was installed and loads it at the next car start or audio restart (parked)"
            event "just installed: the running audio server ($MSPID) started before EQ Engine was installed; it loads EQ Engine at the next car start or audio restart (parked)"
        elif [ -n "$MSPID" ] && [ -f $PROC/$MSPID/maps ] && ! maps_has $MSPID libeqengine.so; then
            # The audio server read its effects list before the overlay was in place (0.6.3, one car
            # start in three): no EQ, no converter tables, no 48 kHz output in it. No restart from
            # here: the rear camera runs in the same process.
            REASON="effects list overlay applied, but the audio server read its effects list before it: EQ Engine is not active until Android's audio is restarted (parked)"
            # already noted at the mount (early_check) or not: the app offers the restart either way
            _ll=""
            [ -f $S/late_list ] && read _ll < $S/late_list
            if [ "$_ll" != "$BID $MSPID" ]; then
                echo "$BID $MSPID" > $S/late_list
                chmod 644 $S/late_list
                event "EQ Engine's filter is not loaded in the audio server ($MSPID): it read its effects list before the overlay. Restart Android audio once (parked)"
            fi
        elif [ "$CONV" = 4 ] && [ -n "$MSPID" ]; then
            if maps_has $MSPID libaudio-resampler.so; then
                event "very high quality converter: EQ Engine's tables are loaded in the audio server ($MSPID)"
            else
                event "very high quality converter: EQ Engine's tables are not loaded in the audio server ($MSPID); it uses high quality's"
            fi
        fi
    fi
    # logcat creates its file readable by root only; the app shows the confirmation line. Put
    # right every round until the start is confirmed good, then once a minute (0.7.6: every
    # round, two processes every 5 s)
    if [ $GOOD = 0 ] || [ $((NOW - LASTCH)) -ge 60 ]; then
        LASTCH=$NOW
        [ -f $S/resampler.log ] && chmod 644 $S/resampler.log
        [ -f $S/resampler.log.1 ] && chmod 644 $S/resampler.log.1
    fi
    write_status
    # Start the EQ service only after this start's status is written, so it never reads the
    # previous run's status (for example "off" just after being turned back on).
    if [ $SVC_STARTED = 0 ] && [ "$(getprop sys.boot_completed)" = 1 ]; then
        SVC_STARTED=1
        LASTWD=$NOW
        event "Android has started; starting the EQ service: $(flat $(am startservice -n $SVC 2>&1))"
        keep_start
        event "48 kHz output keeper started"
        write_status
    elif [ $SVC_STARTED = 1 ] && [ $((NOW - LASTWD)) -ge 60 ]; then
        LASTWD=$NOW
        if [ -z "$(app_running)" ]; then
            event "the EQ service was not running; starting it again: $(flat $(am startservice -n $SVC 2>&1))"
        fi
        if ! keep_alive; then
            keep_start
            event "the 48 kHz output keeper was not running; started it again"
        fi
    fi
    if [ $GOOD = 1 ]; then sleep 5; else sleep 2; fi
done
