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
#  - Lab tests (act.sh lab): the driver watch and the 48 kHz output are in-memory bind mounts,
#    gone at the next car start (this step then clears state/lab_active). An unexpected audio
#    server restart while one is on removes them at once; such restarts (and those in the next
#    60 s) are put down to the test: they neither step the converter down nor count towards
#    "kept restarting".
#  - Once Android has finished starting, it starts the EQ Engine app's background service,
#    which attaches the EQ to all music and re-attaches it after an audio restart. A watchdog
#    checks every 60 s that the app's process is there and starts the service again if not.
# Toolbox only: no awk, sed, grep, head or busybox.

umask 022
VER=0.6.0
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

lab_off() {
    # removes both Lab overlays (driver watch, 48 kHz policy); 0 when none is left
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
MSR=0
APPLIED_AT=0
GOOD=0

write_status() {
    {
        echo "version=$VER"
        echo "boot_id=$BID"
        echo "state=$STATE"
        echo "reason=$REASON"
        echo "overlay=$OVERLAY"
        echo "strikes=$STRIKES"
        echo "audio_server_pid=$MSPID"
        echo "unexpected_restarts=$MSR"
        echo "applied_at=$APPLIED_AT"
        echo "good=$GOOD"
        echo "converter=$CONV"
        echo "service=$SVC_STARTED"
        echo "updated=$(up)"
    } > $S/status.tmp
    chmod 644 $S/status.tmp
    mv $S/status.tmp $S/status
}

set_lastboot() {
    echo "$BID $1" > $S/lastboot
    chmod 644 $S/lastboot
}

unmount_all() {
    lab_off
    _i=0
    while mounted && [ $_i -lt 5 ]; do
        umount $TARGET
        _i=$((_i + 1))
        mounted && sleep 1
    done
    mounted && return 1
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

mkdir -p $S
chmod 755 $D $S
# Stage 1 left some of these writable by everyone.
for _f in $S/*; do
    [ -f "$_f" ] && chmod 644 "$_f"
done

BID=""
[ -f $PROC/sys/kernel/random/boot_id ] && read BID < $PROC/sys/kernel/random/boot_id
[ -n "$BID" ] || BID="unknown-$(up)"

# First run in this start: drop what only meant something in the previous start (audio server
# pids and uptimes repeat across starts, so old converter lines or restart times would mislead).
_rb=""
[ -f $S/runboot ] && read _rb < $S/runboot
if [ "$_rb" != "$BID" ]; then
    rm -f $S/resampler.log $S/resampler.log.1 $S/resampler_now.log $S/last_restart $S/expected_restart
    rm -rf $S/restart.lock
    # Lab tests are in-memory: a new start has none
    rm -f $S/lab_active $S/lab_ended
    [ -f $S/lab_result ] && mv $S/lab_result $S/lab_result.prev
    echo "$BID" > $S/runboot
fi

# Size cap for the event log (toolbox ls -l: size is the 4th field).
if [ -f $S/events.log ]; then
    set -- $(ls -l $S/events.log)
    [ "$(num $4)" -gt 65536 ] && mv $S/events.log $S/events.old.log
fi

STRIKES=0
[ -f $S/strikes ] && read STRIKES < $S/strikes
STRIKES=$(num "$STRIKES")

# How did the previous start end?
if [ -f $S/lastboot ]; then
    read PBID PPHASE < $S/lastboot
    if [ "$PBID" != "$BID" ]; then
        case "$PPHASE" in
            applied|crashed)
                STRIKES=$((STRIKES + 1))
                event "previous start ended before it was confirmed good ($PPHASE): strike $STRIKES"
                ;;
            good)
                STRIKES=0
                ;;
        esac
        echo $STRIKES > $S/strikes
    fi
fi
event "EQ Engine boot step $VER starting (strikes $STRIKES)"

if [ -f $S/disabled ]; then
    read WHY < $S/disabled
    stop_here off "turned off ($WHY). Turn it back on in the EQ Engine app." off
fi
if [ $STRIKES -ge 2 ]; then
    echo "two starts in a row ended before EQ Engine was confirmed good" > $S/disabled
    stop_here off "two starts in a row ended before EQ Engine was confirmed good. Turn it back on in the app." off
fi
if [ -f $VENDOR ]; then
    stop_here refused "this unit has $VENDOR, which Android reads instead; not applying" refused
fi

if mounted; then
    # Already applied during this start (the service was restarted, for example by a reinstall).
    OVERLAY=1
    APPLIED_AT=$(up)
    STATE=applied
    REASON="effects list overlay was already in place"
    event "$REASON"
else
    [ -f $LIB ] || stop_here refused "the filter library is missing ($LIB)" refused
    [ -f $OURS ] || stop_here refused "EQ Engine's effects list is missing ($OURS)" refused
    O=$(md5of $TARGET)
    [ "$O" = "$EXPECT_ORIG" ] || stop_here refused "Android's effects list is not the one this package was built for (md5 $O); not applying" refused
    W=$(md5of $OURS)
    [ "$W" = "$EXPECT_OURS" ] || stop_here refused "EQ Engine's copy of the effects list is damaged (md5 $W); not applying" refused
    chmod 755 $D $D/lib $D/conf
    chmod 644 $LIB $OURS
    # Mark first: if the unit restarts during or right after this, the next start counts a strike.
    set_lastboot applied
    if ! mount -o bind $OURS $TARGET; then
        stop_here refused "the in-memory overlay could not be mounted" refused
    fi
    if ! mounted || [ "$(md5of $TARGET)" != "$EXPECT_OURS" ]; then
        unmount_all
        stop_here refused "the overlay did not check out after mounting; removed it" refused
    fi
    OVERLAY=1
    APPLIED_AT=$(up)
    STATE=applied
    REASON="effects list overlay applied; waiting $GOOD_AFTER s to confirm"
    event "effects list overlay applied"
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
event "audio server pid ${MSPID:-not found yet}"
LASTR=0
LASTWD=0
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
        EXP=0
        if [ -f $S/expected_restart ]; then
            read E < $S/expected_restart
            E=$(num "${E%%.*}")
            [ $((NOW - E)) -le 30 ] && EXP=1
            rm -f $S/expected_restart
        fi
        sleep 1
        NEW=$(ms_pid)
        if [ $EXP = 1 ]; then
            event "audio server restarted on request (pid $MSPID -> ${NEW:-?})"
        elif [ -f $S/lab_active ] || [ $NOW -lt $LAB_GRACE ] || lab_recent; then
            # a Lab test was on: take it off at once and put this (and the next 60 s) down to it
            _la=""
            [ -f $S/lab_active ] && read _la < $S/lab_active
            lab_off
            [ -n "$_la" ] && echo "$NOW ended:$_la was on when the audio server restarted unexpectedly; removed" >> $S/lab_result
            chmod 644 $S/lab_result 2>/dev/null
            [ -n "$_la" ] && LAB_GRACE=$((NOW + 60))
            event "audio server restarted unexpectedly during a Lab test (pid $MSPID -> ${NEW:-?}); Lab tests removed"
        else
            MSR=$((MSR + 1))
            event "audio server restarted unexpectedly ($MSR this start): pid $MSPID -> ${NEW:-?}"
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
    if [ $GOOD = 0 ] && [ $OVERLAY = 1 ] && [ $MSR = 0 ] && [ $((NOW - APPLIED_AT)) -ge $GOOD_AFTER ]; then
        GOOD=1
        STRIKES=0
        echo 0 > $S/strikes
        set_lastboot good
        REASON="effects list overlay applied and confirmed"
        event "confirmed good"
        if [ "$CONV" = 4 ] && [ -n "$MSPID" ]; then
            if maps_has $MSPID libaudio-resampler.so; then
                event "very high quality converter: EQ Engine's tables are loaded in the audio server ($MSPID)"
            else
                event "very high quality converter: EQ Engine's tables are not loaded in the audio server ($MSPID); it uses high quality's"
            fi
        fi
    fi
    # logcat creates its file readable by root only; the app shows the confirmation line
    [ -f $S/resampler.log ] && chmod 644 $S/resampler.log
    [ -f $S/resampler.log.1 ] && chmod 644 $S/resampler.log.1
    write_status
    # Start the EQ service only after this start's status is written, so it never reads the
    # previous run's status (for example "off" just after being turned back on).
    if [ $SVC_STARTED = 0 ] && [ "$(getprop sys.boot_completed)" = 1 ]; then
        SVC_STARTED=1
        LASTWD=$NOW
        event "Android has started; starting the EQ service: $(flat $(am startservice -n $SVC 2>&1))"
        write_status
    elif [ $SVC_STARTED = 1 ] && [ $((NOW - LASTWD)) -ge 60 ]; then
        LASTWD=$NOW
        if [ -z "$(app_running)" ]; then
            event "the EQ service was not running; starting it again: $(flat $(am startservice -n $SVC 2>&1))"
        fi
    fi
    if [ $GOOD = 1 ]; then sleep 5; else sleep 2; fi
done
