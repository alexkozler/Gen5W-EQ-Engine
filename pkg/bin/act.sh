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
#   act.sh lab <w> <r>     Lab tests until the next car start: w = 1 driver watch (pass-through
#                          layer in front of Hyundai's audio driver; switching it needs one audio
#                          restart), r = 1 48 kHz main output (Android's run-time switch, no
#                          restart; an audio restart ends it). 0 0 removes both.
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
# 0.6.0's 48 kHz test laid a policy copy here; still taken off if one is ever found mounted
POL_T=$SYS/system/etc/audio_policy.conf
# 48 kHz test (0.6.1): "<audio server pid> <io handle>" while the switch is made
R48=$S/rate48
LABBIN=$D/bin/eqe_lab
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
    r48_live && _a="$_a rate48"
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

# ------------------------------------------------------------------ 48 kHz test (run-time switch)
#
# Android 4.4's mixer thread takes "sampling_rate=N" for one output, hands it to Hyundai's driver,
# reads back the rate the driver reports and rebuilds its mixer at that rate. Hyundai's driver has
# its own handling for that key ("sample rate %d is changed to %d"). No file changes and no audio
# restart; an audio restart or a car start brings back the policy's 44100. The test counts as
# accepted only if Android's output, the hardware link's setting and the frames per second the
# link really takes (the kernel's counters, eqe_lab rate) all say 48000; anything else is put
# back to 44100 at once.

# the switch was made in the audio server that is running now
r48_live() {
    [ -f $R48 ] || return 1
    read _rp _rio < $R48
    [ -n "$_rp" ] && [ "$_rp" = "$(ms_pid)" ]
}

# "<io> <tid> <rate>" of the main output: the first output thread in the audio server's dump
# (Android opens the primary output first and lists threads by io handle)
main_out() {
    dumpsys media.audio_flinger 2>/dev/null | {
        _in=0; _io=""; _tid=""; _sr=""
        while read _a _b _c _rest; do
            case "$_a $_b" in
                "Output thread")
                    # "Output thread 0xb5ae3008 internals" starts a thread's block
                    [ $_in = 1 ] && break
                    [ "$_rest" = internals ] && _in=1
                    ;;
                "io handle:") [ $_in = 1 ] && [ -z "$_io" ] && _io=$_c ;;
                "Sample rate:") [ $_in = 1 ] && [ -z "$_sr" ] && _sr=$_c ;;
                *) [ $_in = 1 ] && [ "$_a" = "TID:" ] && [ -z "$_tid" ] && _tid=$_b ;;
            esac
        done
        echo "$_io $_tid $_sr"
    }
}

# "<pcm> <rate> <frames/s>" of the hardware link the thread $1 plays on (nothing if none), counted
# over $2 ms by the kernel's own counters
link_of() {
    $LABBIN rate ${2:-3000} 2>/dev/null | {
        while read _k _pcm _card _st _ow _ra _fp _note; do
            [ "$_k" = link ] && [ "$_ow" = "owner=$1" ] && [ -z "$_note" ] && { echo "$_pcm ${_ra#rate=} ${_fp#fps=}"; break; }
        done
    }
}

# Hyundai's driver's own lines about its rate, from the system log (newest last)
hal_rate_lines() {
    logcat -d -v time -s audio_hw_primary:V 2>/dev/null | {
        while read _l; do
            case "$_l" in
                *"is changed to"*|*"same samplerate"*|*"sampling_rate error"*|*" rate : "*) echo "$_l" ;;
            esac
        done
    }
}

hal_count() {
    hal_rate_lines > $S/r48_hal.txt
    _n=0
    while read _l; do _n=$((_n + 1)); done < $S/r48_hal.txt
    rm -f $S/r48_hal.txt
    echo $_n
}

# the newest line hal_rate_lines has gained since it had $1, without the log prefix
hal_new() {
    hal_rate_lines > $S/r48_hal.txt
    _n=0; _last=""
    while read _l; do
        _n=$((_n + 1))
        [ $_n -gt $1 ] && _last=$_l
    done < $S/r48_hal.txt
    rm -f $S/r48_hal.txt
    [ -n "$_last" ] && echo "${_last#*): }"
}

# puts output $1 back to 44100 if it or its link is elsewhere; restarts audio if that does not work
rate48_back() {
    set -- $1 $(main_out)
    _io=$1; _tid=$3; _sr=$4
    set -- $(link_of $_tid 1000)
    if [ "$_sr" != 44100 ] || { [ -n "$2" ] && [ "$2" != 44100 ]; }; then
        $LABBIN set $_io sampling_rate=44100 > /dev/null 2>&1
        sleep 2
        set -- $(main_out)
        _sr=$3
        set -- $(link_of $_tid 1000)
        if [ "$_sr" != 44100 ] || { [ -n "$2" ] && [ "$2" != 44100 ]; }; then
            rm -f $R48
            restart_now "" > /dev/null
            return 1
        fi
    fi
    rm -f $R48
    return 0
}

# 0 = done (accepted, or refused and put back: lab_result says which); 1 = not started, or failed
rate48_start() {
    [ -x $LABBIN ] || { echo "the 48 kHz test is not installed"; return 1; }
    _drv=$HAL_T
    mounted_at $HAL_T && _drv=$HAL_COPY
    [ "$(md5of $_drv)" = "$HAL_MD5" ] || {
        echo "Hyundai's audio driver is not the one this was built for (md5 $(md5of $_drv)); not starting the 48 kHz test"
        return 1
    }
    set -- $(main_out)
    IO=$1; TID=$2; SR0=$3
    [ -n "$IO" ] && [ -n "$TID" ] && [ -n "$SR0" ] || { echo "the audio server's main output was not found"; return 1; }
    set -- $(link_of $TID 2000)
    [ -n "$1" ] || { echo "nothing is playing on the main output: start Android Auto's music first, then the test"; return 1; }
    [ "$SR0" = 44100 ] && [ "$2" = 44100 ] || {
        echo "the main output runs at $SR0 Hz and its link at $2 Hz, not 44100; not starting the 48 kHz test"
        return 1
    }
    N0=$(hal_count)
    P0=$(ms_pid)
    # marked first: if the audio server stops during the switch, the boot step puts it down to the test
    echo "$P0 $IO" > $R48
    chmod 644 $R48
    lab_write_active
    ANS=$($LABBIN set $IO sampling_rate=48000 2>&1)
    case "$ANS" in
        "status "*) ;;
        *)
            rm -f $R48
            lab_write_active
            echo "the 48 kHz switch could not be sent: $ANS"
            return 1
            ;;
    esac
    sleep 2
    if [ "$(ms_pid)" != "$P0" ]; then
        uptime_s > $S/lab_ended
        chmod 644 $S/lab_ended
        rm -f $R48
        lab_write_active
        lab_result "failed: the audio server stopped after the 48 kHz switch; it started again at 44.1 kHz"
        return 1
    fi
    set -- $(main_out)
    SR1=$3
    set -- $(link_of $TID 3000)
    LP=$1; LR=$2; LF=${3%%.*}
    HL=$(hal_new $N0)
    SEEN="output $IO at ${SR1:-?} Hz, link ${LP:-?} at ${LR:-?} Hz, measured ${LF:-?} frames/s"
    if [ "$SR1" = 48000 ] && [ "$LR" = 48000 ] && [ -n "$LF" ] && [ "$LF" -ge 47760 ] && [ "$LF" -le 48240 ]; then
        lab_result "rate48 accepted: $SEEN${HL:+; driver: $HL}"
        return 0
    fi
    case "$SR1/$LR" in
        44100/44100) WHAT="the driver kept 44.1 kHz" ;;
        48000/44100) WHAT="Android runs at 48 kHz but the link stays at 44.1 kHz (the driver converts)" ;;
        44100/48000) WHAT="the link switched but Android's mixer did not follow" ;;
        *) WHAT="unexpected result" ;;
    esac
    _b="back at 44.1 kHz"
    rate48_back $IO || _b="audio restarted to get 44.1 kHz back"
    lab_write_active
    lab_result "rate48 refused: $WHAT (driver answered ${ANS#status }; $SEEN)${HL:+; driver: $HL}; $_b"
    return 0
}

rate48_stop() {
    read _rp _rio < $R48
    _b="back at 44.1 kHz"
    rate48_back $_rio || _b="audio restarted to get 44.1 kHz back"
    lab_write_active
    lab_result "rate48 off: $_b"
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
    HAD_W=0
    mounted_at $HAL_T && HAD_W=1
    HAD_R=0
    if r48_live; then HAD_R=1; else rm -f $R48; fi
    if [ $WANT_W = $HAD_W ] && [ $WANT_R = $HAD_R ]; then
        lab_write_active
        _on=""
        [ $HAD_W = 1 ] && _on="$_on watch"
        [ $HAD_R = 1 ] && _on="$_on rate48"
        if [ -n "$_on" ]; then echo "already on:$_on"; else echo "no Lab test is on"; fi
        return 0
    fi
    restart_lock || return 3
    if [ $WANT_W != $HAD_W ]; then
        # the driver watch is a file in place before the audio server starts: one restart, which
        # also ends a 48 kHz switch (the new audio server starts at 44.1 kHz)
        rm -f $R48
        if [ $WANT_W = 0 ]; then
            unmount_at $HAL_T || { echo "the driver watch could not be removed"; return 1; }
        elif ! watch_on; then
            lab_write_active
            return 1
        fi
        lab_write_active
        restart_now "" || return 1
        if [ $WANT_W = 1 ]; then
            if ! server_steady $NP || [ -z "$(output_rates)" ]; then
                # tells the boot step that the audio server restarts around now belong to the Lab test
                uptime_s > $S/lab_ended
                chmod 644 $S/lab_ended
                lab_unmount_all
                lab_result "failed: the audio server did not keep running with the driver watch; removed it and restarted audio"
                sleep 2
                restart_now "" || return 1
                return 1
            fi
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
        HAD_R=0
    fi
    if [ $WANT_R = 1 ] && [ $HAD_R = 0 ]; then
        rate48_start || { lab_write_active; return 1; }
    elif [ $WANT_R = 0 ] && [ $HAD_R = 1 ]; then
        rate48_stop
    fi
    lab_write_active
    [ $WANT_W = 0 ] && [ $WANT_R = 0 ] && lab_result "off: outputs $(output_rates)"
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
    # a 48 kHz switch ends with the audio server it was made in
    if [ -f $R48 ]; then
        rm -f $R48
        lab_write_active
    fi
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
