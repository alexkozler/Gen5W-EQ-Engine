#!/system/bin/sh
# EQ Engine app actions (run as root through NEMESIS's root channel, which limits a command to
# 767 bytes; that is why these live here instead of in the app).
#
#   act.sh save <usb root> <app files dir> <1 = with Android dumps | 0>
#   act.sh restart [4|3|0] restart Android's audio server (optionally setting the converter first:
#                          4 very high quality with EQ Engine's tables, 3 high, 0 Android default);
#                          one at a time, COOLDOWN seconds apart at least, and it returns only after
#                          Android reports its audio reconnected (or RECONNECT_MAX seconds)
#   act.sh conv 4|3|0      converter choice without a restart: the next audio server start (an
#                          audio restart or a car start) uses it (4 very high, 3 high, 0 stock)
#   act.sh lab <w> <r>     Lab tests until the next car start, applied with one audio restart:
#                          w = 1 driver watch (pass-through layer in front of Hyundai's audio driver),
#                          r = 1 48 kHz main output. 0 0 removes both.
#   act.sh off             turn EQ Engine off (later starts are stock)
#   act.sh on              turn EQ Engine back on and start the boot step
#   act.sh open <pkg/cls>  open one of Hyundai's Sound Settings screens (Lab page)
#   act.sh trace <seconds> record the system log and before/after audio snapshots (Lab page)
# Prints EQE_OK at the end when the action completed, or EQE_WAIT (then the reason) when a restart
# was refused because another one is running or the last one was too recent.

D=/data/eqengine
S=$D/state
TARGET=/system/etc/audio_effects.conf
NEM=/system/xbin/nemesis
LAB=$D/lab
umask 022
COOLDOWN=10
RECONNECT_MAX=25
SETTLE=3
PROC=/proc
# Tests (tests/act/run.sh) point these at a simulated unit.
if [ -n "$EQE_TEST_ROOT" ]; then
    D=$EQE_TEST_ROOT/data/eqengine
    S=$D/state
    LAB=$D/lab
    PROC=$EQE_TEST_ROOT/proc
    kill() { "$EQE_TEST_ROOT/stubs/kill" "$@"; }
fi
VHQLIB=$D/lib/libaudio-resampler.so
VHQSUM=$D/conf/libaudio-resampler.md5
# Lab tests (in-memory bind mounts, like the effects list; gone at the next car start)
SYS=${EQE_TEST_ROOT:-}
HAL_T=$SYS/system/lib/hw/audio.primary.tcc803x.so
HAL_V=$SYS/vendor/lib/hw/audio.primary.tcc803x.so
HAL_MD5=4e23b3753aecde59b180b374745653a7
HAL_COPY=$D/lib/hal/eqe_hal_orig.so
WATCH=$D/lib/eqe_drvwatch.so
WATCHSUM=$D/conf/eqe_drvwatch.md5
DRV=$D/drv
POL_T=$SYS/system/etc/audio_policy.conf
POL_V=$SYS/vendor/etc/audio_policy.conf
POL_MD5=e99f7849076cd3767f5d93b2200ab8aa
POL48=$D/conf/audio_policy_48k.conf
POL48_MD5=6b669d485f1f07d85cc925724de6697d
POL_OFF=1514
LAB_SETTLE=${EQE_LAB_SETTLE:-6}

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

mounted() {
    while read _d _m _rest; do
        [ "$_m" = "$TARGET" ] && return 0
    done < /proc/mounts
    return 1
}

snapshot() {
    # $1 = before | after
    /system/bin/dumpsys media.audio_flinger > "af_$1.txt" 2>&1
    /system/bin/dumpsys media.audio_policy > "ap_$1.txt" 2>&1
    {
        for f in /proc/asound/cards /proc/asound/pcm /proc/asound/card0/pcm*/sub0/hw_params /proc/asound/card0/pcm*/sub0/status; do
            [ -f "$f" ] && { echo "== $f"; cat "$f"; }
        done
    } > "asound_$1.txt" 2>&1
    $D/bin/alsactl_dump > "alsa_$1.txt" 2>&1
    getprop | while read _l; do
        case "$_l" in
            *audio*|*sound*|*amp*|*arkam*|*resampler*|*spdif*|*dsp*) echo "$_l" ;;
        esac
    done > "props_$1.txt"
    # The audio server's processor time (whole process and each thread, in clock ticks), so a
    # trace shows what a converter costs: compare 'after' with 'before'.
    _mp=$(ms_pid)
    if [ -n "$_mp" ]; then
        {
            echo "audio server $_mp"
            cat /proc/$_mp/stat
            for _t in /proc/$_mp/task/*; do
                [ -f $_t/stat ] && cat $_t/stat
            done
            read _c < /proc/stat
            echo "$_c"
        } > "cpu_$1.txt" 2>&1
    fi
    # the driver watch's own summary, when it is on
    [ -f $DRV/status ] && cat $DRV/status > "drv_status_$1.txt"
    read _up _r < /proc/uptime
    echo "$1 at uptime $_up, $(date)" >> times.txt
}

uptime_s() {
    read _u _r < $PROC/uptime
    echo "${_u%%.*}"
}

num() {
    case "$1" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$1" ;;
    esac
}

# The last "Media server started." line of Android's AudioService: it logs that once it has
# reconnected to a restarted audio server and sent it the system's audio settings again.
started_marker() {
    logcat -d -v time -s AudioService 2>/dev/null | {
        _m=""
        while read _l; do
            case "$_l" in
                *"Media server started"*) _m=$_l ;;
            esac
        done
        echo "$_m"
    }
}

# Client pids of the tracks Android's mixer is playing now (the "active tracks" tables).
playing_clients() {
    dumpsys media.audio_flinger 2>/dev/null | {
        _in=0
        _out=""
        while read _a _b _c _rest; do
            case "$_a $_b $_c $_rest" in
                *"active tracks") _in=1; continue ;;
            esac
            [ $_in = 1 ] || continue
            case "$_a" in
                Name) continue ;;
                ''|*[!0-9]*) _in=0; continue ;;
            esac
            case " $_out " in
                *" $_b "*) ;;
                *) _out="$_out $_b" ;;
            esac
        done
        echo $_out
    }
}

proc_name() {
    ps | {
        _f=""
        while read _u _p _pp _v _r _w _pc _s _n _x; do
            [ "$_p" = "$1" ] && _f=$_n
        done
        echo "${_f:-pid $1}"
    }
}

md5of() {
    set -- $(md5 "$1" 2>/dev/null)
    echo "$1"
}

vhq_ok() {
    # EQ Engine's converter tables are there and are the ones installed (md5 recorded at install)
    [ -f $VHQLIB ] && [ -f $VHQSUM ] || return 1
    _want=""
    read _want < $VHQSUM
    [ -n "$_want" ] && [ "$(md5of $VHQLIB)" = "$_want" ]
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

sinc_missed() {
    # $1 = audio server pid: did its converter look for the tables before they were loaded?
    # (A here-document keeps the loop in this shell in every sh flavour, so return works.)
    _log=$(logcat -d -v time -s AudioResamplerSinc:E 2>/dev/null)
    while read _l; do
        case "$_l" in
            *"Could not open audio-resampler"*)
                case "$_l" in
                    *"($1)"*|*" $1)"*) return 0 ;;
                esac ;;
        esac
    done <<EOL
$_log
EOL
    return 1
}

# ------------------------------------------------------------------ Lab tests

mounted_at() {
    while read _d _m _rest; do
        [ "$_m" = "$1" ] && return 0
    done < $PROC/mounts
    return 1
}

unmount_at() {
    _i=0
    while mounted_at $1 && [ $_i -lt 5 ]; do
        umount $1
        _i=$((_i + 1))
        mounted_at $1 && sleep 1
    done
    ! mounted_at $1
}

lab_unmount_all() {
    # both Lab overlays; 0 when neither is left
    _ok=0
    unmount_at $HAL_T || _ok=1
    unmount_at $POL_T || _ok=1
    rm -f $S/lab_active
    return $_ok
}

lab_write_active() {
    _a=""
    mounted_at $HAL_T && _a="$_a watch"
    mounted_at $POL_T && _a="$_a rate48"
    if [ -n "$_a" ]; then
        echo "$_a" > $S/lab_active
        chmod 644 $S/lab_active
    else
        rm -f $S/lab_active
    fi
}

lab_result() {
    # one line for the app (state/lab_result keeps the last few) and for act.sh's answer
    echo "EQE_LAB $*"
    echo "$(uptime_s) $*" >> $S/lab_result
    chmod 644 $S/lab_result
}

# Prepares and mounts the driver watch. 0 = mounted (or already), 1 = refused (message printed).
watch_on() {
    mounted_at $HAL_T && return 0
    [ -f $HAL_V ] && { echo "this unit has $HAL_V, which Android would load instead; not starting the driver watch"; return 1; }
    [ -f $WATCH ] && [ -f $WATCHSUM ] || { echo "the driver watch is not installed"; return 1; }
    read _w < $WATCHSUM
    [ "$(md5of $WATCH)" = "$_w" ] || { echo "the driver watch failed its check; not starting it"; return 1; }
    [ "$(md5of $HAL_T)" = "$HAL_MD5" ] || {
        echo "Hyundai's audio driver is not the one this was built for (md5 $(md5of $HAL_T)); not starting the driver watch"
        return 1
    }
    mkdir -p $D/lib/hal
    chmod 755 $D/lib/hal
    if [ "$(md5of $HAL_COPY)" != "$HAL_MD5" ]; then
        cat $HAL_T > $HAL_COPY.new && mv $HAL_COPY.new $HAL_COPY
        chmod 644 $HAL_COPY
        [ "$(md5of $HAL_COPY)" = "$HAL_MD5" ] || { rm -f $HAL_COPY; echo "copying Hyundai's audio driver failed"; return 1; }
    fi
    # the watch writes its notes here, as the audio server's user
    mkdir -p $DRV
    rm -f $DRV/drv_prev.log $DRV/drv.log.1 $DRV/status $DRV/status.tmp
    [ -f $DRV/drv.log ] && mv $DRV/drv.log $DRV/drv_prev.log
    chown media:media $DRV 2>/dev/null
    chmod 755 $DRV
    chmod 644 $WATCH
    mount -o bind $WATCH $HAL_T || { echo "the driver watch could not be mounted"; return 1; }
    [ "$(md5of $HAL_T)" = "$_w" ] || { unmount_at $HAL_T; echo "the driver watch did not check out after mounting; removed it"; return 1; }
    return 0
}

# Prepares and mounts the 48 kHz policy copy (one number changed). 0 = mounted, 1 = refused.
rate48_on() {
    mounted_at $POL_T && return 0
    [ -f $POL_V ] && { echo "this unit has $POL_V, which Android reads instead; not starting the 48 kHz test"; return 1; }
    [ "$(md5of $POL_T)" = "$POL_MD5" ] || {
        echo "Android's audio policy is not the one this was built for (md5 $(md5of $POL_T)); not starting the 48 kHz test"
        return 1
    }
    if [ "$(md5of $POL48)" != "$POL48_MD5" ]; then
        $D/bin/eqe_patch $POL_T $POL48.new $POL_OFF 44100 48000 || { rm -f $POL48.new; echo "making the 48 kHz policy copy failed"; return 1; }
        mv $POL48.new $POL48
    fi
    chmod 644 $POL48
    [ "$(md5of $POL48)" = "$POL48_MD5" ] || { rm -f $POL48; echo "the 48 kHz policy copy did not check out"; return 1; }
    mount -o bind $POL48 $POL_T || { echo "the 48 kHz policy could not be mounted"; return 1; }
    [ "$(md5of $POL_T)" = "$POL48_MD5" ] || { unmount_at $POL_T; echo "the 48 kHz policy did not check out after mounting; removed it"; return 1; }
    return 0
}

# What the audio server's output threads run at ("44100 48000"), from its own dump.
output_rates() {
    dumpsys media.audio_flinger 2>/dev/null | {
        _r=""
        while read _a _b _c _rest; do
            [ "$_a $_b" = "Sample rate:" ] && _r="$_r $_c"
        done
        echo $_r
    }
}

# The hardware links' rates while playing ("pcm2p 48000"), from the kernel.
hw_rates() {
    _o=""
    for _f in $PROC/asound/card0/pcm*p/sub0/hw_params; do
        [ -f $_f ] || continue
        while read _k _v _rest; do
            [ "$_k" = "rate:" ] && { _p=${_f%/sub0/hw_params}; _o="$_o ${_p##*/}=$_v"; }
        done < $_f
    done
    echo $_o
}

# stays alive for LAB_SETTLE s: 0; died or replaced: 1
server_steady() {
    _n=0
    while [ $_n -lt $LAB_SETTLE ]; do
        sleep 1
        [ -d $PROC/$1 ] || return 1
        _n=$((_n + 1))
    done
    [ "$(ms_pid)" = "$1" ]
}

lab_action() {
    case "$1$2" in
        00|01|10|11) ;;
        *) echo "usage: act.sh lab <watch 0|1> <rate48 0|1>"; return 2 ;;
    esac
    [ -f $S/disabled ] && { echo "EQ Engine is off; turn it on first"; return 1; }
    WANT_W=$1
    WANT_R=$2
    HAD=""
    mounted_at $HAL_T && HAD="$HAD watch"
    mounted_at $POL_T && HAD="$HAD rate48"
    WANTED=""
    [ $WANT_W = 1 ] && WANTED="$WANTED watch"
    [ $WANT_R = 1 ] && WANTED="$WANTED rate48"
    if [ "$WANTED" = "$HAD" ]; then
        lab_write_active
        if [ -n "$HAD" ]; then echo "already on:$HAD"; else echo "no Lab test is on"; fi
        return 0
    fi
    restart_lock || return 3
    # take off what is no longer wanted, put on what is (nothing changes if a check fails)
    [ $WANT_W = 0 ] && { unmount_at $HAL_T || { echo "the driver watch could not be removed"; return 1; }; }
    [ $WANT_R = 0 ] && { unmount_at $POL_T || { echo "the 48 kHz policy could not be removed"; return 1; }; }
    if [ $WANT_W = 1 ] && ! watch_on; then
        lab_write_active
        return 1
    fi
    if [ $WANT_R = 1 ] && ! rate48_on; then
        [ $WANT_W = 1 ] && [ -z "$HAD" ] && unmount_at $HAL_T
        lab_write_active
        return 1
    fi
    lab_write_active
    NOWA=""
    mounted_at $HAL_T && NOWA="$NOWA watch"
    mounted_at $POL_T && NOWA="$NOWA rate48"
    restart_now "" || return 1
    # Lab tests have to keep the audio server running, with outputs
    RATES=""
    if [ -n "$NOWA" ]; then
        if ! server_steady $NP || [ -z "$(output_rates)" ]; then
            # tells the boot step that the audio server restarts around now belong to the Lab test
            uptime_s > $S/lab_ended
            chmod 644 $S/lab_ended
            lab_unmount_all
            lab_result "failed: the audio server did not keep running with$NOWA; removed the Lab test and restarted audio"
            sleep 2
            restart_now "" || return 1
            return 1
        fi
    fi
    RATES=$(output_rates)
    if [ $WANT_W = 1 ]; then
        if maps_has $NP eqe_hal_orig.so; then
            _st=""
            [ -f $DRV/status ] && while read _l; do
                case "$_l" in
                    state=*) _st=${_l#state=} ;;
                esac
            done < $DRV/status
            lab_result "watch ${_st:-started}"
        else
            lab_result "watch not-loaded"
        fi
    fi
    if [ $WANT_R = 1 ]; then
        case " $RATES " in
            *" 48000 "*) lab_result "rate48 accepted: outputs $RATES; hardware $(hw_rates)" ;;
            *)
                # the driver kept another rate: take the copy away and restart once more, so the
                # audio server runs exactly as before
                unmount_at $POL_T
                lab_write_active
                lab_result "rate48 refused: outputs $RATES; removed the 48 kHz policy and restarted audio"
                sleep 2
                restart_now "" || return 1
                ;;
        esac
    fi
    [ -z "$NOWA" ] && lab_result "off: outputs $RATES"
    logcat -d -v time -s audio_hw_primary:V EQEDrv:V AudioFlinger:V AudioPolicyManagerBase:V > $S/lab_now.log 2>/dev/null
    chmod 644 $S/lab_now.log 2>/dev/null
    return 0
}

# ------------------------------------------------------------------ audio restarts

# One restart at a time, COOLDOWN seconds apart. A second restart while the car's audio software
# is still reconnecting to the first can leave it disconnected (music stops until the car
# restarts). Prints EQE_WAIT and the reason, and returns 1, when it has to wait.
restart_lock() {
    L=$S/restart.lock
    NOW=$(uptime_s)
    if ! mkdir $L 2>/dev/null; then
        _lp=""
        _lt=0
        [ -f $L/info ] && read _lp _lt < $L/info
        _lt=$(num "$_lt")
        if [ -n "$_lp" ] && [ -d $PROC/$_lp ] && [ $((NOW - _lt)) -lt 120 ]; then
            echo EQE_WAIT
            echo "Android's audio is already restarting. Try again in a minute."
            return 1
        fi
        # left over from an interrupted restart
        rm -rf $L
        if ! mkdir $L 2>/dev/null; then
            echo EQE_WAIT
            echo "Android's audio is already restarting. Try again in a minute."
            return 1
        fi
    fi
    echo "$$ $NOW" > $L/info
    trap 'rm -rf $L' EXIT
    if [ -f $S/last_restart ]; then
        read LR < $S/last_restart
        LR=$(num "$LR")
        AGO=$((NOW - LR))
        if [ $AGO -ge 0 ] && [ $AGO -lt $COOLDOWN ]; then
            echo EQE_WAIT
            echo "Android's audio was restarted $AGO s ago. Wait $((COOLDOWN - AGO)) s so the car's audio can finish reconnecting."
            return 1
        fi
    fi
    return 0
}

# restart_now <converter: 4|3|0 or empty to keep>: stops Android's audio server and waits until
# Android has reconnected to the new one; sets NP (the new pid). Call after restart_lock.
restart_now() {
    P=$(ms_pid)
    [ -n "$P" ] || { echo "Android's audio server was not found"; return 1; }
    M0=$(started_marker)
    BEFORE=$(playing_clients)
    case "$1" in
        4) echo 1 > $S/vhq_load; chmod 644 $S/vhq_load ;;
        0|3) rm -f $S/vhq_load ;;
    esac
    case "$1" in
        0|3|4) setprop af.resampler.quality $1 ;;
    esac
    echo "$NOW" > $S/expected_restart
    kill $P
    i=0
    while [ -d $PROC/$P ] && [ $i -lt 3 ]; do
        sleep 1
        i=$((i + 1))
    done
    [ -d $PROC/$P ] && kill -9 $P
    # wait for the new audio server, then for Android to report it has reconnected
    T0=$(uptime_s)
    NP=""
    OK=0
    while [ $(($(uptime_s) - T0)) -lt $RECONNECT_MAX ]; do
        sleep 1
        [ -n "$NP" ] || NP=$(ms_pid)
        [ -n "$NP" ] || continue
        M1=$(started_marker)
        if [ -n "$M1" ] && [ "$M1" != "$M0" ]; then
            OK=1
            break
        fi
    done
    sleep $SETTLE
    # Android 4.4 recreates each app's playing stream on the new audio server, but does not always
    # start it again (seen with Android Auto: the stream sits idle and the music is silent while
    # the phone shows it playing). Check that whatever was playing before is playing again.
    MISSING=""
    if [ -n "$NP" ] && [ -n "$BEFORE" ]; then
        j=0
        while :; do
            AFTER=" $(playing_clients) "
            MISSING=""
            for c in $BEFORE; do
                case "$AFTER" in
                    *" $c "*) ;;
                    *) [ -d $PROC/$c ] && MISSING="$MISSING $c" ;;
                esac
            done
            [ -z "$MISSING" ] && break
            j=$((j + 1))
            [ $j -ge 8 ] && break
            sleep 1
        done
    fi
    WAITED=$(($(uptime_s) - T0))
    uptime_s > $S/last_restart
    chmod 644 $S/last_restart
    # the new audio server's converter line (it logs it when it first converts audio; the boot
    # step's capture records later ones). Matched to the server by its pid in the app.
    logcat -d -v time -s AudioResampler:D AudioResamplerSinc:E > $S/resampler_now.log 2>/dev/null
    chmod 644 $S/resampler_now.log 2>/dev/null
    if [ -z "$NP" ]; then
        echo "the audio server ($P) was stopped but has not come back after $WAITED s"
        return 1
    fi
    for c in $MISSING; do
        echo "EQE_STUCK $(proc_name $c)"
    done
    if [ -f $S/vhq_load ]; then
        if ! maps_has $NP libaudio-resampler.so; then
            echo "EQE_VHQ not-loaded"
        elif sinc_missed $NP; then
            echo "EQE_VHQ missed"
        else
            echo "EQE_VHQ loaded"
        fi
    fi
    if [ $OK = 1 ]; then
        echo "audio server $P restarted as $NP; Android reconnected (ready after $WAITED s)"
    else
        echo "audio server $P restarted as $NP; Android did not report reconnecting within $RECONNECT_MAX s"
    fi
    return 0
}

state_now() {
    _st=""
    if [ -f $S/status ]; then
        while read _l; do
            case "$_l" in
                state=*) _st=${_l#state=} ;;
            esac
        done < $S/status
    fi
    echo "$_st"
}

case "$1" in
save)
    U=$2
    A=$3
    [ -d "$U" ] || { echo "no USB stick at $U"; exit 1; }
    O="$U/EQENGINE/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$O" && cd "$O" || { echo "cannot write to $O"; exit 1; }
    [ -f "$A/eqengine.log" ] && cat "$A/eqengine.log" > app.log
    [ -f "$A/eqengine.old.log" ] && cat "$A/eqengine.old.log" > app.old.log
    for f in $S/*; do
        [ -f "$f" ] && cat "$f" > "state_${f##*/}.txt"
    done
    for f in $D/settings/*; do
        [ -f "$f" ] && cat "$f" > "settings_${f##*/}"
    done
    for f in $DRV/*; do
        [ -f "$f" ] && cat "$f" > "drv_${f##*/}.txt"
    done
    cat /data/nemesis/logs/eqengine/boot.log > boot_step.log 2>&1
    for f in /data/nemesis/logs/*.log; do
        [ -f "$f" ] && cat "$f" > "nemesis_${f##*/}"
    done
    cat /proc/mounts > mounts.txt
    cat /proc/meminfo > meminfo.txt
    getprop af.resampler.quality > converter_prop.txt
    P=$(ms_pid)
    if [ -n "$P" ]; then
        if maps_has $P libaudio-resampler.so; then
            echo "EQ Engine's converter tables are loaded in the audio server ($P)"
        else
            echo "EQ Engine's converter tables are not loaded in the audio server ($P)"
        fi
    fi > converter_tables.txt
    ps > ps.txt 2>&1
    ls -l $D $D/lib $D/conf $D/state $D/settings $D/bin > files.txt 2>&1
    ls -l /data/tombstones > tombstones_list.txt 2>&1
    for t in $LAB/trace_*; do
        [ -d "$t" ] || continue
        mkdir -p "lab/${t##*/}"
        for f in "$t"/*; do
            [ -f "$f" ] && cat "$f" > "lab/${t##*/}/${f##*/}"
        done
    done
    if [ "$4" = 1 ]; then
        for f in /data/tombstones/tombstone_*; do
            [ -f "$f" ] && cat "$f" > "${f##*/}.txt"
        done
        /system/bin/dumpsys media.audio_flinger > audioflinger.txt 2>&1
        /system/bin/dumpsys meminfo > meminfo_apps.txt 2>&1
        /system/bin/logcat -d -v time > logcat.txt 2>&1
        /system/bin/logcat -d -v time -b events > logcat_events.txt 2>&1
        dmesg > dmesg.txt 2>&1
    fi
    sync
    echo "saved to $O"
    ;;
restart)
    case "$2" in
        ''|0|3|4) ;;
        *) echo "unknown converter setting '$2'"; exit 2 ;;
    esac
    restart_lock || exit 3
    P=$(ms_pid)
    [ -n "$P" ] || { echo "Android's audio server was not found"; exit 1; }
    if [ "$2" = 4 ] && ! vhq_ok; then
        echo "EQ Engine's converter tables failed their check; not switching to very high quality"
        exit 1
    fi
    restart_now "$2" || exit 1
    ;;
lab)
    # act.sh lab <watch 0|1> <rate48 0|1>: Lab tests, in memory until the next car start.
    lab_action "$2" "$3" || exit $?
    ;;
off)
    echo "turned off in the app" > $D/state/disabled
    chmod 644 $S/disabled
    setprop af.resampler.quality 0
    # the boot step notices within 5 s; make sure the overlay is gone either way
    sleep 6
    i=0
    while mounted && [ $i -lt 5 ]; do
        umount $TARGET
        i=$((i + 1))
        mounted && sleep 1
    done
    lab_unmount_all
    mounted && { echo "the overlay could not be removed; it goes away at the next start"; exit 1; }
    echo "off"
    ;;
on)
    rm -f $S/disabled $S/strikes $S/lastboot $S/expected_restart
    # stop first: a leftover instance would make "start" do nothing
    $NEM service stop eqengine/boot > /dev/null 2>&1
    $NEM service start eqengine/boot
    i=0
    while [ $i -lt 10 ]; do
        sleep 1
        [ "$(state_now)" = applied ] && break
        i=$((i + 1))
    done
    ST=$(state_now)
    echo "boot step state: ${ST:-none}"
    [ "$ST" = applied ] || exit 1
    ;;
open)
    case "$2" in
        com.android.soundsettings/*) ;;
        *) echo "only Sound Settings screens can be opened here"; exit 2 ;;
    esac
    O=$(am start -n "$2" 2>&1)
    echo "$O"
    case "$O" in
        *Error*|*rror:*|*xception*) exit 1 ;;
    esac
    ;;
trace)
    N=$2
    case "$N" in
        ''|*[!0-9]*) N=60 ;;
    esac
    [ $N -gt 300 ] && N=300
    T=$LAB/trace_$(date +%Y%m%d_%H%M%S)
    mkdir -p $T && cd $T || { echo "cannot create $T"; exit 1; }
    snapshot before
    logcat -v time -f $T/logcat.txt < /dev/null > /dev/null 2>&1 &
    LP=$!
    sleep $N
    kill $LP 2>/dev/null
    snapshot after
    $D/bin/alsactl_dump 2>&1 | {
        read _a
        read _b
        echo "$_a; $_b"
    } > $LAB/alsa_summary.txt
    # keep the newest 3 traces (names sort by time)
    set -- $LAB/trace_*
    while [ $# -gt 3 ]; do
        rm -rf "$1"
        shift
    done
    chmod 755 $LAB $T
    for f in $LAB/* $T/*; do
        [ -f "$f" ] && chmod 644 "$f"
    done
    ls -l $T
    echo "trace saved to $T"
    ;;
conv)
    # The running audio server keeps what it has; the next one (an audio restart or a car start)
    # uses this.
    case "$2" in
        4)
            vhq_ok || { echo "EQ Engine's converter tables failed their check; not switching to very high quality"; exit 1; }
            echo 1 > $S/vhq_load
            chmod 644 $S/vhq_load
            ;;
        0|3) rm -f $S/vhq_load ;;
        *) echo "usage: act.sh conv 4|3|0"; exit 2 ;;
    esac
    setprop af.resampler.quality $2
    echo "converter $2 from the next audio server start"
    ;;
*)
    echo "usage: act.sh save|restart|conv|lab|off|on|open|trace"
    exit 2
    ;;
esac
echo EQE_OK
exit 0
