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
#   act.sh lab <w>         Lab driver watch until the next car start: 1 = a pass-through layer in
#                          front of Hyundai's audio driver, 0 = removed; switching it needs one
#                          audio restart
#   act.sh cpwatch <w>     Lab CarPlay watch, from the next car start: 1 = a pass-through layer in
#                          place of the factory CarPlay app's JNI library, which watches its
#                          TinyALSA calls, laid over at every car start until it is turned off;
#                          0 = off. Nothing is restarted now (see "CarPlay watch" below)
#   act.sh cpwboot         the boot step's part of the CarPlay watch: lays it over at the car start
#   act.sh cpwguard        one round of the keeper's check on the CarPlay watch
#   act.sh keep            the 48 kHz output keeper: runs in the background, started by the boot
#                          step (see "48 kHz output" below)
#   act.sh report <usb root> <app files dir> <seconds>
#                          the car report: one text file on the stick, for sharing (no personal data)
#   act.sh off             turn EQ Engine off (later starts are stock)
#   act.sh on              turn EQ Engine back on and start the boot step
#   act.sh open <pkg/cls>  open one of Hyundai's Sound Settings screens (Lab page)
#   act.sh trace <seconds> record the system log and before/after audio snapshots (Lab page)
#   act.sh curves save|load <usb root>
#                          the four user slots to or from the stick's EQENGINE_CURVES folder
#   act.sh factory <usb root>
#                          copy the factory CarPlay app, the apps it works with, the libraries they
#                          load and Android's framework to the stick, for study on a PC (private;
#                          see "Factory files" below)
# Prints EQE_OK at the end when the action completed, or EQE_WAIT (then the reason) when a restart
# was refused because another one is running or the last one was too recent.

VER=0.7.6
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
EFX_T=$SYS/system/etc/audio_effects.conf
# the stock effects list this package was built for (the same value as in boot.sh)
EFX_MD5=4d98c1b38bd1d9eaf929d9b616c0d118
LABBIN=$D/bin/eqe_lab
LAB_SETTLE=${EQE_LAB_SETTLE:-6}
# 48 kHz output: "<audio server pid> <io handle>" while the main output runs at 48 kHz
R48=$S/rate48
OUTST=$S/output
OUTLOG=$S/output.log
SENT=$S/rate48_sent
KEEP_PID=$S/keep.pid
KEEP_POLL=${EQE_KEEP_POLL:-1}
KEEP_TRIES=3
# counts of the link's frames that may get nothing before the rate is left "not measured"
KEEP_MTRIES=${EQE_KEEP_MTRIES:-5}
# 0.6.3's marker (a switch made while nothing played did not reach the link); removed by the keeper
IDLE_BAD=$S/idle48_bad
# a new audio server gets this long (s) for its clients to reconnect before a switch while idle
IDLE_AFTER=${EQE_IDLE_AFTER:-8}
# the main link (I2S_3), which Android's main output plays on; another process may open it itself
MAIN_PCM=pcm2p
# no switch while nothing plays until the main link has been free of other processes this long (s)
OTHER_QUIET=${EQE_OTHER_QUIET:-60}
# Hold.java (in the app's package) keeps the main output's tracks safe during a rate change
HOLD_D=$S/hold
HOLD_MAX=90
APP_PROCESS=${EQE_APP_PROCESS:-/system/bin/app_process}

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

# 0 = the file at $1 is now EQ Engine's own $2, byte for byte (0.7.6: EQ Engine unmounts only its
# own mounts, never another package's at the same path)
ours() {
    [ -f "$2" ] || return 1
    set -- $(md5 "$1" 2>/dev/null) $(md5 "$2" 2>/dev/null)
    [ -n "$1" ] && [ "$1" = "$3" ]
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
    while read _ma _mp _mo _md _mi _mf; do
        case "$_mf" in
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

# While the audio server has the file open (the driver watch is loaded in it), a plain umount
# says "busy" (0.6.2 on the car): then it is detached instead (eqe_lab umount). The running audio
# server keeps what it has loaded until the restart that follows; the next one opens Hyundai's file.
unmount_at() {
    mounted_at $1 || return 0
    umount $1 2>/dev/null
    if mounted_at $1 && [ -x $LABBIN ]; then
        $LABBIN umount $1 > /dev/null 2>&1
    fi
    _i=0
    while mounted_at $1 && [ $_i -lt 3 ]; do
        sleep 1
        umount $1 2>/dev/null
        _i=$((_i + 1))
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
        echo "the factory audio driver is not the one this was built for (md5 $(md5of $HAL_T)); not starting the driver watch"
        return 1
    }
    mkdir -p $D/lib/hal
    chmod 755 $D/lib/hal
    if [ "$(md5of $HAL_COPY)" != "$HAL_MD5" ]; then
        cat $HAL_T > $HAL_COPY.new && mv $HAL_COPY.new $HAL_COPY
        chmod 644 $HAL_COPY
        [ "$(md5of $HAL_COPY)" = "$HAL_MD5" ] || { rm -f $HAL_COPY; echo "copying the factory audio driver failed"; return 1; }
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

# ------------------------------------------------------------------ 48 kHz output (act.sh keep)
#
# Android 4.4's mixer thread takes "sampling_rate=N" for one output, hands it to Hyundai's driver,
# reads back the rate the driver reports and rebuilds its mixer at that rate. On the test car the
# driver then restarts the main link (I2S_3) at 48 kHz, so Android Auto's 48 kHz music plays with
# no conversion. No file changes and no audio restart.
#
# "act.sh keep" runs in the background, started by the boot step. Once a second it reads the main
# link's state from the kernel (/proc/asound; nothing is started for that).
#  - While nothing plays (a new audio server, after IDLE_AFTER s), it switches the main output to
#    the rate wanted with a silent track of its own running the link (Hold.java "wake"), so the
#    music then starts at that rate with no gap. Hyundai's driver applies sampling_rate only to an
#    active stream: sent while the stream is in standby, Android takes the new rate but the link
#    later starts at the old one (0.6.3: 7 s of slow music). So nothing is ever sent while the
#    main link is not running.
#  - Each time the link starts playing or changes rate, it checks that Android's output and the
#    link agree, and:
#    - 48 kHz wanted (settings/rate48, on unless it says 0) and both at 44100: switches, and
#      accepts only if Android's output, the link's setting and the frames per second the link
#      really takes (eqe_lab rate) all say 48000. Anything else is put back to 44100 and held
#      there for the rest of this audio server's life.
#    - 48 kHz not wanted (or EQ Engine off) and both at 48000: puts 44100 back the same way.
#    - Android and the link disagree (music would play at the wrong speed): sets both to the rate
#      wanted, or else to 44100.
#  - Every rate change is made with the main output's tracks held (hold_begin, below), and the
#    tracks' buffers are checked after it and at every link start.
#  - While a process other than the audio server has the main link open itself (the factory
#    CarPlay app, wired CarPlay), it changes nothing (link_other, below; state=other).
# At most KEEP_TRIES switches per audio server. It never restarts the audio server. state/output
# tells the app what it found and state/output.log what it did; state/rate48_sent (the time of
# the last switch) lets the boot step put an audio server crash right after a switch down to it.

# 1 = 48 kHz wanted (the default), 0 = not (the setting is 0, or EQ Engine is off)
rate48_wanted() {
    _v=1
    [ -f $D/settings/rate48 ] && read _v < $D/settings/rate48
    [ -f $S/disabled ] && _v=0
    case "$_v" in
        0) echo 0 ;;
        *) echo 1 ;;
    esac
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

# "<pcm> <state> <rate>" of the playback link the thread $1 has open (nothing if none), read
# straight from the kernel's files: cheap enough to do every second
link_now() {
    for _f in $PROC/asound/card*/pcm*p/sub0/status; do
        [ -f $_f ] || continue
        _st=""
        _ow=""
        while read -r _k _a _b _c; do
            case "$_k" in
                state:) _st=$_a ;;
                owner_pid) _ow=$_b ;;
            esac
        done < $_f
        [ -n "$_ow" ] && [ "$_ow" = "$1" ] || continue
        _d=${_f%/sub0/status}
        _r=""
        if [ -f $_d/sub0/hw_params ]; then
            while read -r _k _a _b; do
                [ "$_k" = "rate:" ] && _r=$_a
            done < $_d/sub0/hw_params
        fi
        echo "${_d##*/} ${_st:-unknown} ${_r:-unknown}"
        return 0
    done
    return 1
}

# ---- another process on the main link
#
# Wired CarPlay (0.6.4 on the car): the factory CarPlay app (com.daudio.app.dipo, Hyundai's DiPO)
# opens the main link (pcm2p, I2S_3) itself through TinyALSA, at 44.1 kHz; its music never goes
# through Android's audio server. While it has the link open, the audio server's own opens fail
# ("Device or resource busy"). A silent track or a switch can then do nothing but make the driver
# retry its opens (0.6.4: about 1,050 failed opens a second for 4 s). So while a process other than
# the audio server has the main link open, the keeper changes nothing, spends none of its tries and
# says who has the link (state=other, owner=<process name>). When the link is free again it carries
# on as before; the switch while nothing plays waits OTHER_QUIET s more, because the other process
# may take the link back (a pause) and a silent track would then be in its way.

# 0 = a process other than the current audio server has the main link open (any state): LO_TID
# (the thread the kernel names as the link's owner), LO_STATE and LO_RATE (its hw_params rate),
# and K_OTHER_AT is now; 1 = not (closed, or opened by one of the audio server's own threads)
link_other() {
    LO_TID=""; LO_STATE=""; LO_RATE=""
    [ -n "$K_PID" ] || return 1
    for _of in $PROC/asound/card*/$MAIN_PCM/sub0/status; do
        [ -f $_of ] || continue
        _ost=""; _oow=""
        while read -r _ok _oa _ob _oc; do
            case "$_ok" in
                state:) _ost=$_oa ;;
                owner_pid) _oow=$_ob ;;
            esac
        done < $_of
        case "$_oow" in
            ''|0|*[!0-9]*) continue ;;
        esac
        [ -d $PROC/$K_PID/task/$_oow ] && return 1
        LO_TID=$_oow
        LO_STATE=$_ost
        _od=${_of%/sub0/status}
        if [ -f $_od/sub0/hw_params ]; then
            while read -r _ok _oa _ob; do
                [ "$_ok" = "rate:" ] && LO_RATE=$_oa
            done < $_od/sub0/hw_params
        fi
        K_OTHER_AT=$(uptime_s)
        return 0
    done
    return 1
}

# LO_PID and LO_NAME: the process of the thread LO_TID ("thread N of <name>", as in the report's
# link_owners), looked up once per thread
other_name() {
    [ -n "$LO_TID" ] && [ "$LO_TID" = "$LO_NTID" ] && return 0
    LO_NTID=$LO_TID
    _otg=""
    if [ -f $PROC/$LO_TID/status ]; then
        while read -r _ok _oa _orest; do
            [ "$_ok" = "Tgid:" ] && _otg=$_oa
        done < $PROC/$LO_TID/status
    fi
    LO_PID=${_otg:-$LO_TID}
    LO_NAME=$(proc_name $LO_PID)
}

# Another process has the main link (link_other said so): one log line when it appears, and the
# app is told who has it.
keep_other() {
    other_name
    if [ "$K_OTHER" != "$LO_PID" ]; then
        # what the app was shown before, for when the link is free again
        [ -z "$K_OTHER" ] && { K_PREV_STATE=$K_STATE; K_PREV_NOTE=$K_NOTE; }
        K_OTHER=$LO_PID
        K_OTHER_NAME=$LO_NAME
        # the link's frames/s since it started (one reading of the kernel's counters, no wait)
        O_FPS=""
        if [ -x $LABBIN ]; then
            set -- $($LABBIN rate 0 2>/dev/null | {
                _of=""
                while read -r _ok _opcm _ocard _ost _oow _ora _ofp _onote; do
                    [ "$_ok" = link ] && [ "$_opcm" = $MAIN_PCM ] && [ "$_oow" = "owner=$LO_TID" ] && [ -z "$_of" ] && _of=${_ofp#fps=}
                done
                echo "$_of"
            })
            O_FPS=${1%%.*}
        fi
        out_log "the main link ($MAIN_PCM) is in use by $LO_NAME (thread $LO_TID, ${LO_STATE:-?} at ${LO_RATE:-?} Hz), which plays to it directly, not through Android's audio server; the keeper changes nothing while it has the link"
    fi
    K_LAST=""
    keep_note other "the main speaker link is in use by $LO_NAME, which plays to it directly, not through Android's audio server; EQ Engine cannot process that sound"
}

# The other process has let go of the main link: the app is shown what it was shown before (or
# that the keeper waits for music); a link start of Android's is then checked as usual.
keep_other_gone() {
    out_log "the main link ($MAIN_PCM) is no longer in use by $K_OTHER_NAME; the keeper carries on"
    K_OTHER=""; K_OTHER_NAME=""; K_LAST=""; LO_NTID=""
    # the switch while nothing plays counts its OTHER_QUIET s from here
    K_OTHER_AT=$(uptime_s)
    if [ -n "$K_PREV_STATE" ] && [ "$K_PREV_STATE" != other ]; then
        keep_note "$K_PREV_STATE" "$K_PREV_NOTE"
    else
        keep_note waiting "Waiting for music"
    fi
}

# Hyundai's driver's own lines about its rate, from the system log (newest last)
hal_rate_lines() {
    logcat -d -v time -s audio_hw_primary:V 2>/dev/null | {
        while read _l; do
            case "$_l" in
                *"is changed to"*|*"same samplerate"*|*"sampling_rate error"*|*" rate : "*|*"samplerate("*) echo "$_l" ;;
            esac
        done
    }
}

# the time of day as HHMMSS, on the system log's clock (the driver's lines are picked by it, so
# no log is read before a switch: logcat -d takes seconds on the car)
hms_now() {
    date +%H%M%S 2>/dev/null
}

# hal_rate_lines from the time $1 (HHMMSS) on, without the log prefix, one per line
hal_from() {
    hal_rate_lines > $S/r48_hal.txt
    while read -r _d _t _rest; do
        _c=${_t%%.*}
        _h=${_c%%:*}; _c=${_c#*:}
        _m=${_c%%:*}; _c=${_c#*:}
        [ "1$_h$_m$_c" -ge "1$1" ] 2>/dev/null || continue
        echo "${_rest#*): }"
    done < $S/r48_hal.txt
    rm -f $S/r48_hal.txt
}

# the newest driver line about its rate since the time $1
hal_new() {
    _last=""
    hal_from "$1" > $S/r48_haln.txt
    while IFS= read -r _l; do _last=$_l; done < $S/r48_haln.txt
    rm -f $S/r48_haln.txt
    [ -n "$_last" ] && echo "$_last"
}

# all driver lines about its rate since the time $1, joined by " | "
hal_since() {
    _all=""
    hal_from "$1" > $S/r48_haln.txt
    while IFS= read -r _l; do _all="${_all:+$_all | }$_l"; done < $S/r48_haln.txt
    rm -f $S/r48_haln.txt
    echo "$_all"
}

out_log() {
    echo "$(uptime_s) $*" >> $OUTLOG
    chmod 644 $OUTLOG
}

# keep_note <state> <note>: what the app shows. state: 48k | 44k | held | mismatch | unsafe |
# waiting | off | other. With "other" (another process plays to the main link itself), link,
# link_rate and fps are that process's, and owner= names it.
keep_note() {
    _nl=$K_LINK; _nr=$K_LR; _nf=$K_FPS; _no=""
    if [ "$1" = other ]; then
        _nl=$MAIN_PCM; _nr=$LO_RATE; _nf=$O_FPS; _no=$LO_NAME
    fi
    [ "$1|$2|$_nf|$_nr|$_no" = "$K_NOTED" ] && return
    K_NOTED="$1|$2|$_nf|$_nr|$_no"
    K_STATE=$1
    K_NOTE=$2
    {
        echo "want=$K_WANT"
        echo "state=$1"
        echo "server=$K_PID"
        echo "out=$K_OUT"
        echo "link=$_nl"
        echo "link_rate=$_nr"
        echo "fps=$_nf"
        [ -n "$_no" ] && echo "owner=$_no"
        echo "at=$(uptime_s)"
        echo "note=$2"
    } > $OUTST.tmp
    chmod 644 $OUTST.tmp
    mv $OUTST.tmp $OUTST
}

# r48_send <rate>: sends sampling_rate=<rate> to the main output, then reads back what Android's
# output (SR1), the link's setting (LP, LR) and the link's measured frames/s (LF) say; SEEN sums
# it up and HL is the driver's own line. 0: all say <rate>; 1: they do not; 2: Android says <rate>
# but nothing plays, so the link could not be checked; 3: the audio server stopped.
r48_send() {
    _want=$1
    R48_T0=$(hms_now)
    uptime_s > $SENT
    chmod 644 $SENT
    ANS=$($LABBIN set $K_IO sampling_rate=$_want 2>&1)
    SR1=""; LP=""; LR=""; LF=""; HL=""
    # A driver that takes the rate restarts the link at it within a fraction of a second. Until
    # then Android may already mix at the new rate (wrong speed), so look at once, twice at most.
    _i=0
    while [ $_i -lt 2 ]; do
        sleep 1
        _i=$((_i + 1))
        if [ "$(ms_pid)" != "$K_PID" ]; then
            SEEN="the audio server stopped"
            return 3
        fi
        set -- $(link_now $K_TID)
        LP=$1; LR=$3
        [ "$2" = RUNNING ] || { LR=""; break; }
        [ "$LR" = $_want ] && break
    done
    set -- $(main_out)
    SR1=$3
    # R48_QUICK (a switch made with the silent track): the frames/s are counted when music next
    # plays and the driver's line is read after the silence, so the silence lasts only seconds
    if [ -z "$R48_QUICK" ] && [ -n "$LR" ] && [ "$LR" = $_want ] && [ "$SR1" = $_want ]; then
        set -- $(link_of $K_TID 3000)
        [ -n "$1" ] && { LP=$1; LR=$2; LF=${3%%.*}; }
        # the driver's own line; on a failure it is read after the put-back (logcat takes a while)
        HL=$(hal_new "$R48_T0")
    fi
    if [ -z "$LR" ]; then
        SEEN="output $K_IO at ${SR1:-?} Hz; the link is not playing"
    else
        SEEN="output $K_IO at ${SR1:-?} Hz, link ${LP:-?} at $LR Hz${LF:+, measured $LF frames/s}"
    fi
    case "$ANS" in
        "status "*) ;;
        *) SEEN="the setting could not be sent: $ANS"; return 1 ;;
    esac
    [ "$SR1" = $_want ] || return 1
    [ -n "$LR" ] || return 2
    [ "$LR" = $_want ] || return 1
    [ -n "$R48_QUICK" ] && return 0
    [ -n "$LF" ] && [ "$LF" -ge $((_want - _want / 200)) ] && [ "$LF" -le $((_want + _want / 200)) ]
}

# why a switch to 48 kHz did not take, from what r48_send read back
r48_why() {
    case "$SR1/$LR" in
        44100/44100|44100/) echo "the driver kept 44.1 kHz" ;;
        48000/44100) echo "Android went to 48 kHz but the link stayed at 44.1 kHz" ;;
        44100/48000) echo "the link went to 48 kHz but Android's mixer stayed at 44.1 kHz" ;;
        48000/48000) echo "the link took ${LF:-?} frames/s instead of 48000" ;;
        *) echo "unexpected result ($SEEN)" ;;
    esac
}

# keep_switch <rate>: one switch with its check. 0 = done (or done and checked when music plays
# again); 1 = it did not take (K_PID is emptied if the audio server stopped)
keep_switch() {
    _to=$1
    K_TRIES=$((K_TRIES + 1))
    out_log "switching the main output to $_to Hz"
    r48_send $_to
    _rc=$?
    case $_rc in
        0)
            K_OUT=$_to; K_LINK=$LP; K_LR=$LR; K_FPS=$LF; K_MEASURED="$K_PID $_to"
            # with the silent track the frames/s are counted when music plays
            [ -n "$R48_QUICK" ] && K_MEASURED=""
            out_log "switched to $_to Hz: $SEEN${R48_QUICK:+ (a silent track ran the link)}${HL:+; driver: $HL}"
            if [ $_to = 48000 ]; then
                echo "$K_PID $K_IO" > $R48
                chmod 644 $R48
                keep_note 48k "48 kHz: Android Auto's music is not converted"
            else
                rm -f $R48
                keep_note 44k "44.1 kHz"
            fi
            return 0
            ;;
        2)
            K_OUT=$_to
            out_log "switched to $_to Hz while nothing played (output $K_IO at $SR1 Hz); the link is checked when music plays"
            K_LAST=""
            keep_note waiting "Switched to $_to Hz; checked when music plays"
            return 0
            ;;
        3)
            out_log "the audio server stopped right after the switch to $_to Hz"
            [ $_to = 48000 ] && K_NO48="the audio server stopped right after a switch to 48 kHz"
            K_PID=""
            return 1
            ;;
    esac
    out_log "the switch to $_to Hz did not take: $(r48_why) (driver answered ${ANS#status }; $SEEN)"
    return 1
}

# keep_hold <why>: 44100 back, held there for this audio server; if even that does not work, says
# that the rates disagree
keep_hold() {
    K_HELD=$1
    if [ "$SR1" = 44100 ] && [ "$LR" != 48000 ]; then
        # the switch changed nothing: Android is still at 44100 (and the link too, or idle)
        K_OUT=44100
        rm -f $R48
        out_log "nothing to put back: Android's output stayed at 44.1 kHz; held there until the next audio restart or car start: $K_HELD"
        keep_note held "$K_HELD; 44.1 kHz"
        return 0
    fi
    r48_send 44100
    _rc=$?
    case $_rc in
        0)
            K_OUT=44100; K_LINK=$LP; K_LR=$LR; K_FPS=$LF; K_MEASURED="$K_PID 44100"
            rm -f $R48
            out_log "back at 44.1 kHz ($SEEN); held there until the next audio restart or car start: $K_HELD"
            keep_note held "$K_HELD; back at 44.1 kHz"
            ;;
        2)
            K_OUT=44100
            rm -f $R48
            K_LAST=""
            keep_note held "$K_HELD; back at 44.1 kHz"
            ;;
        3)
            out_log "the audio server stopped while putting 44.1 kHz back"
            K_PID=""
            ;;
        *)
            K_OUT=$SR1; K_LR=$LR
            if [ -n "$SR1" ] && [ "$SR1" = "$LR" ]; then
                out_log "44.1 kHz did not come back: $SEEN"
                keep_note held "$K_HELD; stays at $SR1 Hz until the next audio restart or car start"
            else
                out_log "could not bring Android and the link back together: $SEEN"
                keep_note mismatch "Android at ${SR1:-?} Hz, link at ${LR:-?} Hz: wrong speed. Restart Android audio (parked)"
            fi
            ;;
    esac
}

# ---- the main output's tracks during a rate change
#
# Android 4.4's mixer frees the output's mix buffer at a rate change and allocates a new one
# (PlaybackThread::readOutputParameters). A track whose audio session has an effect chain is
# moved to the new buffer with its chain. Every other track keeps a pointer to the freed buffer,
# and the mixer goes on writing it there: the track is silent and the audio server's memory is
# overwritten, which can crash it. It mostly goes unseen because the new buffer usually lands at
# the old address. 0.6.2 hit it on the car (the first start after the install: the tracks at
# B801AAE0, the mix buffer at 0xb8034c88, Android Auto's music silent until an audio restart).
# So each change is made with every session that has a track on the main output "held":
# Hold.java (in the app's package, run as root with app_process) puts a disabled EQ Engine filter
# on each, which gives the session a chain of its own; releasing the filters afterwards points the
# session's tracks at the output's buffer as it is then. A disabled filter passes the sound
# through unchanged. Without the hold there is no rate change.

# 0xb8034c88 or B8034C88 -> B8034C88 (the dump prints buffers both ways)
hexup() {
    _h=${1#0x}
    _o=""
    while [ -n "$_h" ]; do
        _c=${_h%"${_h#?}"}
        _h=${_h#?}
        case "$_c" in
            a) _c=A ;; b) _c=B ;; c) _c=C ;; d) _c=D ;; e) _c=E ;; f) _c=F ;;
        esac
        [ -z "$_o" ] && [ "$_c" = 0 ] && continue
        _o=$_o$_c
    done
    echo "${_o:-0}"
}

# af_scan <io>: that output's buffers in the audio server's dump, one per line:
#   mix <buffer>               the output's mix buffer
#   track <session> <buffer>   each of its tracks, and the buffer the mixer writes it into
#   chain <session> <buffer>   each of its effect chains, and the chain's input buffer
af_scan() {
    _want=$1
    dumpsys media.audio_flinger 2>/dev/null | {
        set -f
        _io=""; _sec=""; _mix=""; _cs=""
        while IFS= read -r _l; do
            set -- $_l
            case "$1 $2" in
                "Output thread")
                    case "$4" in
                        internals) _sec=int; _io=""; _mix="" ;;
                        tracks) _sec=trk ;;
                        *) _sec="" ;;
                    esac
                    continue ;;
                "Input thread"|"Record thread") _sec=""; _io=""; continue ;;
                "mix buffer") [ "$_sec" = int ] && _mix=$4; continue ;;
                "io handle:")
                    if [ "$_sec" = int ]; then
                        _io=$3
                        [ "$_io" = "$_want" ] && [ -n "$_mix" ] && echo "mix $(hexup $_mix)"
                    fi
                    continue ;;
                "Effects for") _cs=${4%:}; _sec=chain; continue ;;
            esac
            [ -n "$_io" ] && [ "$_io" = "$_want" ] || continue
            case "$_sec" in
                trk)
                    case "$1" in ''|*[!0-9]*) continue ;; esac
                    [ $# -ge 14 ] && echo "track $6 $(hexup ${14})" ;;
                chain)
                    case "$2" in
                        0x*) echo "chain $_cs $(hexup $2)"; _sec="" ;;
                    esac ;;
            esac
        done
    }
}

# the installed app's package (Hold.java is in it)
hold_apk() {
    _apk=""
    for _f in $SYS/data/app/com.eqengine.app-*.apk; do
        [ -f "$_f" ] && _apk=$_f
    done
    echo "$_apk"
}

hold_is_ours() {
    _c=""
    [ -f $PROC/$1/cmdline ] && read -r _c < $PROC/$1/cmdline
    case "$_c" in
        *app_process*) return 0 ;;
    esac
    return 1
}

# hold_start [wake] <session>...: Hold.java on those sessions (and with "wake" a silent track of
# its own); waits for its answer (15 s at most). 0 = held (HOLD_STATE: "held <n> <sessions>
# [silent <session>]"); 1 = not (HOLD_WHY), and nothing is left held
hold_start() {
    HOLD_WHY=""; HOLD_STATE=""
    _apk=$(hold_apk)
    [ -n "$_apk" ] || { HOLD_WHY="EQ Engine's app package was not found"; return 1; }
    rm -rf $HOLD_D
    mkdir -p $HOLD_D
    CLASSPATH=$_apk $APP_PROCESS /system/bin com.eqengine.app.Hold $HOLD_D $HOLD_MAX "$@" < /dev/null > $HOLD_D/out.txt 2>&1 &
    echo $! > $HOLD_D/pid
    _i=0
    while [ $_i -lt 15 ]; do
        sleep 1
        _i=$((_i + 1))
        [ -f $HOLD_D/state ] || continue
        _hs=""
        read -r _hs < $HOLD_D/state
        case "$_hs" in
            held*) HOLD_STATE=$_hs; return 0 ;;
        esac
        HOLD_WHY=${_hs#failed }
        break
    done
    [ -n "$HOLD_WHY" ] || HOLD_WHY="the helper did not answer within 15 s"
    hold_end
    return 1
}

# hold_end: Hold.java releases its filters and stops (or is stopped after 5 s: Android then
# releases them itself)
hold_end() {
    [ -d $HOLD_D ] || return 0
    : > $HOLD_D/release
    _hp=""
    [ -f $HOLD_D/pid ] && read _hp < $HOLD_D/pid
    _i=0
    while [ $_i -lt 5 ]; do
        _hs=""
        [ -f $HOLD_D/state ] && read -r _hs < $HOLD_D/state
        case "$_hs" in
            released*|failed*) break ;;
        esac
        [ -n "$_hp" ] && [ -d $PROC/$_hp ] || [ $_i -lt 1 ] || break
        sleep 1
        _i=$((_i + 1))
    done
    case "$_hs" in
        released*|failed*) ;;
        *) [ -n "$_hp" ] && hold_is_ours $_hp && kill $_hp 2>/dev/null ;;
    esac
    rm -rf $HOLD_D
}

# hold_begin [wake]: holds every session with a track on the main output (not session 0, nor one
# that already has a chain), then checks in the dump that none of those tracks plays into the mix
# buffer any more. A track that appeared in between (a new session) spoils that: the hold is made
# again, 3 times at most. With "wake", Hold.java also plays silence, and the main link must be
# running before this returns. 0 = ready for a rate change (HOLD_N sessions held, HOLD_SILENT the
# silent track's session); 1 = not (HOLD_WHY; HOLD_NOFX when EQ Engine's filter is not in this
# audio server, so trying again cannot help; HOLD_OTHER when another process took the main link
# while the silent track was starting)
hold_begin() {
    _wake=$1
    HOLD_N=0; HOLD_SESS=""; HOLD_SILENT=""; HOLD_WHY=""; HOLD_NOFX=""; HOLD_OTHER=""
    hold_end
    # the hold is made of EQ Engine filters: none if the audio server read its effects list
    # before the boot step's overlay
    if [ -n "$K_PID" ] && [ -f $PROC/$K_PID/maps ] && ! maps_has $K_PID libeqengine.so; then
        HOLD_WHY="EQ Engine's filter is not loaded in this audio server"
        HOLD_NOFX=1
        return 1
    fi
    _att=0
    while :; do
        _att=$((_att + 1))
        af_scan $K_IO > $S/af.txt
        _mix=""; _chs=""; _ss=""
        while read -r _k _a _b; do
            case "$_k" in
                mix) _mix=$_a ;;
                chain) _chs="$_chs $_a" ;;
            esac
        done < $S/af.txt
        if [ -z "$_mix" ]; then
            HOLD_WHY="the audio server's dump does not show the main output's buffers"
            return 1
        fi
        while read -r _k _a _b; do
            [ "$_k" = track ] || continue
            case "$_a" in
                ''|*[!0-9]*|0) continue ;;
            esac
            case " $_chs $_ss " in
                *" $_a "*) continue ;;
            esac
            _ss="$_ss $_a"
        done < $S/af.txt
        [ -n "$_ss$_wake" ] || return 0
        hold_start $_wake $_ss || return 1
        # "held <n> <sessions> [silent <session>]"
        set -- $HOLD_STATE
        shift 2
        HOLD_SESS=""; HOLD_SILENT=""
        while [ $# -gt 0 ]; do
            if [ "$1" = silent ]; then
                HOLD_SILENT=$2
                break
            fi
            HOLD_SESS="${HOLD_SESS:+$HOLD_SESS }$1"
            shift
        done
        if [ -n "$_wake" ]; then
            # the silent track starts the main link within a fraction of a second
            _i=0; _run=""
            while [ $_i -lt 3 ]; do
                set -- $(link_now $K_TID)
                [ "$2" = RUNNING ] && { _run=1; break; }
                # taken by another process meanwhile: the silent track cannot have it
                link_other && { HOLD_OTHER=1; break; }
                sleep 1
                _i=$((_i + 1))
            done
            if [ -z "$_run" ]; then
                if [ -n "$HOLD_OTHER" ]; then
                    other_name
                    HOLD_WHY="the main link was taken by $LO_NAME"
                else
                    HOLD_WHY="the main output's link did not start with the silent track"
                fi
                hold_end
                return 1
            fi
        fi
        af_scan $K_IO > $S/af.txt
        _bad=""
        while read -r _k _a _b; do
            [ "$_k" = track ] && [ "$_b" = "$_mix" ] && _bad="$_bad $_a"
        done < $S/af.txt
        if [ -z "$_bad" ]; then
            set -- $HOLD_SESS
            HOLD_N=$#
            return 0
        fi
        HOLD_WHY="tracks of session(s)$_bad still play into the mix buffer (new ones, or the hold did not reach them)"
        hold_end
        HOLD_SESS=""; HOLD_SILENT=""
        [ $_att -lt 3 ] || return 1
        out_log "a track came up during the hold (session(s)$_bad): holding again"
    done
}

# buffers_check: 0 = each track on the main output plays into its mix buffer or its session's
# chain (BUF_N tracks); 1 = some do not (STALE: their sessions); 2 = the dump does not show them
buffers_check() {
    STALE=""; BUF_N=0
    af_scan $K_IO > $S/af.txt
    _mix=""
    while read -r _k _a _b; do
        [ "$_k" = mix ] && _mix=$_a
    done < $S/af.txt
    [ -n "$_mix" ] || return 2
    while read -r _k _a _b; do
        [ "$_k" = track ] || continue
        BUF_N=$((BUF_N + 1))
        [ "$_b" = "$_mix" ] && continue
        _okc=0
        while read -r _k2 _a2 _b2; do
            [ "$_k2" = chain ] && [ "$_a2" = "$_a" ] && [ "$_b2" = "$_b" ] && _okc=1
        done < $S/af.txt
        [ $_okc = 1 ] && continue
        case " $STALE " in
            *" $_a "*) ;;
            *) STALE="$STALE $_a" ;;
        esac
    done < $S/af.txt
    STALE=${STALE# }
    [ -z "$STALE" ]
}

# Tracks found pointing at a buffer the main output no longer uses are moved back with a short
# hold on their sessions. 0 = all fine (or the dump does not show it); 1 = some are left (K_UNSAFE)
keep_buffers() {
    buffers_check
    [ $? = 1 ] || return 0
    out_log "tracks of session(s) $STALE play into a buffer the main output no longer uses (Android lost them at a rate change); moving them back"
    uptime_s > $SENT
    chmod 644 $SENT
    hold_start $STALE && hold_end
    if buffers_check; then
        out_log "moved back: all $BUF_N tracks on the main output play into its buffer"
        return 0
    fi
    out_log "not moved back (${HOLD_WHY:-session(s) $STALE still elsewhere})"
    K_UNSAFE="After a rate change some tracks play into a freed buffer. Restart Android audio (parked)"
    keep_note unsafe "$K_UNSAFE"
    return 1
}

# keep_change <rate> <why> [1] [wake]: switches the main output to <rate> with its check; if that
# does not take, puts 44100 back and holds it, saying <why> (with 1: and what did not take). All of
# it with the main output's tracks held; their buffers are checked afterwards. With "wake" (nothing
# plays), Hold.java's silent track runs the main link during the change, and the frames/s are
# counted when music next plays. 0 = <rate> in place (or checked when music plays); 1 = not
# (K_HOLDFAIL: the tracks could not be held; tried again unless K_HELD says why not).
keep_change() {
    _to=$1; _why=$2; _add=$3; _kw=$4
    K_HOLDFAIL=""; HOLD_OTHER=""
    # Another process has the main link (the factory CarPlay app), or took it while the silent
    # track was starting: nothing is changed and no try is spent; the next round says who has it,
    # and the change is made once Android has the link again.
    if link_other; then
        other_name
        K_HOLDFAIL=1; HOLD_OTHER=1
        out_log "no rate change: the main link is in use by $LO_NAME"
        return 1
    fi
    uptime_s > $SENT
    chmod 644 $SENT
    if ! hold_begin $_kw; then
        K_HOLDFAIL=1
        if [ -n "$HOLD_OTHER" ]; then
            out_log "no rate change: $HOLD_WHY"
            return 1
        fi
        K_TRIES=$((K_TRIES + 1))
        out_log "no rate change: the main output's tracks could not be held for it ($HOLD_WHY)"
        # tried again (while music plays at the next check; after a silent try when music starts),
        # unless the filter is missing or the tries are used up
        _again=""
        [ -z "$HOLD_NOFX" ] && { [ -n "$_kw" ] || [ $K_TRIES -lt $KEEP_TRIES ]; } && _again=1
        if [ -n "$HOLD_NOFX" ]; then
            K_HELD="48 kHz not used: EQ Engine's filter is not loaded in this audio server. Restart Android audio once (parked)"
        elif [ -z "$_again" ]; then
            K_HELD="48 kHz not used: the tracks could not be held for the switch (see the logs)"
        fi
        case "$K_OUT/$K_LR" in
            48000/44100|44100/48000) keep_note mismatch "Android at $K_OUT Hz, link at $K_LR Hz: wrong speed. Restart Android audio (parked)" ;;
            48000/48000) [ -n "$_again" ] || keep_note held "44.1 kHz not put back: the tracks could not be held (see the logs); 48 kHz until the next audio restart" ;;
            *)
                if [ -n "$_again" ]; then
                    keep_note waiting "The tracks could not be held for the switch; trying again"
                else
                    keep_note held "$K_HELD"
                fi ;;
        esac
        return 1
    fi
    # (no apostrophe inside ${...:+...}: bash takes it for a quote there, dash and mksh do not)
    if [ -n "$HOLD_SILENT" ] && [ $HOLD_N -gt 0 ]; then
        out_log "a silent track (session $HOLD_SILENT) runs the main link for the change; holding the main output's audio sessions ($HOLD_SESS)"
    elif [ -n "$HOLD_SILENT" ]; then
        out_log "a silent track (session $HOLD_SILENT) runs the main link for the change"
    elif [ $HOLD_N -gt 0 ]; then
        out_log "holding the main output's audio sessions ($HOLD_SESS) for the change"
    fi
    R48_QUICK=$_kw
    _kc=0; _t0=""
    if [ -z "$_to" ]; then
        _kc=1
        SR1=""; LR=""
        keep_hold "$_why"
    elif ! keep_switch $_to; then
        _kc=1
        _t0=$R48_T0
        if [ -n "$K_PID" ] && [ -n "$_why" ]; then
            [ "$_add" = 1 ] && _why="$_why: $(r48_why)"
            keep_hold "$_why"
        fi
    else
        _t0=$R48_T0
        [ -n "$_kw" ] && K_IDLESW="$K_PID $_to"
    fi
    R48_QUICK=""
    # the silence ends here; the driver's lines are read only now (logcat takes seconds on the car)
    hold_end
    if [ -n "$K_PID" ] && [ -n "$_t0" ]; then
        if [ $_kc = 1 ]; then
            _hl=$(hal_since "$_t0")
            [ -n "$_hl" ] && out_log "the driver's lines about its rate since the switch: $_hl"
        elif [ -n "$_kw" ]; then
            _hl=$(hal_new "$_t0")
            [ -n "$_hl" ] && out_log "the driver's line for that switch: $_hl"
        fi
    fi
    [ -n "$K_PID" ] && keep_buffers
    return $_kc
}

# Nothing plays on the main link: switch now, with a silent track running the link (the driver
# ignores a rate sent to a stream in standby), so that the music starts at the rate wanted with
# no gap. Once per audio server and setting, IDLE_AFTER s after the audio server appeared, and
# OTHER_QUIET s after another process last had the main link (it may take it back: a pause).
keep_idle() {
    [ -n "$K_PID" ] && [ -n "$K_IO" ] || return 0
    [ "$K_IDLED" = "$K_PID $K_WANT" ] && return 0
    [ -n "$K_HELD$K_NO48$K_UNSAFE" ] && return 0
    [ $K_TRIES -lt $KEEP_TRIES ] || return 0
    [ $(($(uptime_s) - K_SINCE)) -ge $IDLE_AFTER ] || return 0
    [ -n "$K_OTHER_AT" ] && [ $(($(uptime_s) - K_OTHER_AT)) -lt $OTHER_QUIET ] && return 0
    set -- $(main_out)
    [ "$2" = "$K_TID" ] || return 0
    K_OUT=$3
    K_IDLED="$K_PID $K_WANT"
    HOLD_OTHER=""
    if [ $K_WANT = 1 ] && [ "$K_OUT" = 44100 ]; then
        out_log "nothing plays: switching the main output to 48 kHz now, so the music starts at it"
        keep_change 48000 "48 kHz did not take" 1 wake
    elif [ $K_WANT = 0 ] && [ "$K_OUT" = 48000 ]; then
        out_log "nothing plays: putting 44.1 kHz back now"
        keep_change 44100 "44.1 kHz did not come back at the first try" "" wake
    fi
    # another process took the main link meanwhile: tried again once it has been free for a while
    [ -n "$HOLD_OTHER" ] && K_IDLED=""
    return 0
}

# The main link ($1) started playing or changed rate ($2). 0 = done; 1 = look again next time.
keep_check() {
    _pcm=$1
    _lr=$2
    set -- $(main_out)
    [ -n "$3" ] || return 1
    [ "$2" = "$K_TID" ] || { K_TID=$2; return 1; }
    K_IO=$1; K_OUT=$3; K_LINK=$_pcm; K_LR=$_lr
    # tracks left on a freed buffer first: no rate change while that is so
    keep_buffers || return 0
    if [ "$K_OUT" != "$_lr" ]; then
        # said once per disagreement (a hold that failed is tried again at the next round)
        [ "$K_MISSAID" = "$K_PID $K_OUT $_lr" ] || out_log "Android's output runs at $K_OUT Hz but link $_pcm at $_lr Hz"
        K_MISSAID="$K_PID $K_OUT $_lr"
        if [ $K_WANT = 1 ] && [ -z "$K_HELD" ] && [ -z "$K_NO48" ] && [ $K_TRIES -lt $KEEP_TRIES ]; then
            keep_change 48000 "Android and the link disagreed ($K_OUT and $_lr Hz)"
        else
            keep_change "" "Android and the link disagreed ($K_OUT and $_lr Hz)"
        fi
        [ -n "$K_HOLDFAIL" ] && [ -z "$K_HELD" ] && return 1
        return 0
    fi
    if [ $K_WANT = 1 ] && [ "$_lr" = 44100 ]; then
        [ -n "$K_NO48" ] && K_HELD=$K_NO48
        if [ -z "$K_HELD" ] && [ $K_TRIES -ge $KEEP_TRIES ]; then
            K_HELD="$KEEP_TRIES switches already made in this audio server"
        fi
        if [ -n "$K_HELD" ]; then
            keep_note held "$K_HELD; 44.1 kHz"
            return 0
        fi
        keep_change 48000 "48 kHz did not take" 1
        # the tracks could not be held: tried again next round, while the tries last
        [ -n "$K_HOLDFAIL" ] && [ -z "$K_HELD" ] && return 1
        return 0
    fi
    if [ $K_WANT = 0 ] && [ "$_lr" = 48000 ]; then
        if [ $K_TRIES -ge $KEEP_TRIES ]; then
            keep_note held "${K_HELD:-$KEEP_TRIES changes already made in this audio server}; stays at 48 kHz until the next audio restart or car start"
            return 0
        fi
        keep_change 44100 "44.1 kHz did not come back at the first try"
        [ -n "$K_HOLDFAIL" ] && [ -z "$K_HELD" ] && return 1
        return 0
    fi
    # Android and the link agree on the rate wanted: count the link's frames once per audio
    # server and rate. Until a count succeeds the rate is not called checked (fps= stays empty,
    # and the app says so); a count that gets nothing (the link stopped during it) is tried again
    # at the next rounds, KEEP_MTRIES times, and again at the link's next start.
    if [ "$K_MEASURED" != "$K_PID $_lr" ]; then
        set -- $(link_of $K_TID 3000)
        if [ -n "$3" ]; then
            K_FPS=${3%%.*}
            K_MEASURED="$K_PID $_lr"
            K_MTRY=0
            if [ $K_FPS -lt $((_lr - _lr / 200)) ] || [ $K_FPS -gt $((_lr + _lr / 200)) ]; then
                out_log "link $_pcm is set to $_lr Hz but took $K_FPS frames/s"
                if [ "$_lr" != 44100 ]; then
                    # 44.1 kHz back like every other rate change: with the main output's tracks
                    # held (keep_change), never straight through keep_hold
                    keep_note waiting "Link $_pcm runs at $K_FPS frames/s at $_lr Hz: putting 44.1 kHz back"
                    keep_change "" "the link took $K_FPS frames/s at $_lr Hz"
                    if [ -n "$K_HOLDFAIL" ]; then
                        # not put back: counted and put back at the next round, while the tries last
                        K_MEASURED=""
                        [ -z "$K_HELD" ] && return 1
                        keep_note mismatch "Link $_pcm runs at $K_FPS frames/s at $_lr Hz: wrong speed. Restart Android audio (parked)"
                    fi
                    return 0
                fi
            else
                if [ "$K_IDLESW" = "$K_PID $_lr" ]; then
                    out_log "the music started at $_lr Hz (switched while nothing played); measured $K_FPS frames/s"
                else
                    out_log "Android and link $_pcm agree on $_lr Hz; measured $K_FPS frames/s"
                fi
            fi
        else
            K_FPS=""
            K_MTRY=$((K_MTRY + 1))
            if [ $K_MTRY -lt $KEEP_MTRIES ]; then
                [ $K_MTRY = 1 ] && out_log "link $_pcm at $_lr Hz: its frames could not be counted; counted again while it plays"
                _ns=44k
                [ "$_lr" = 48000 ] && _ns=48k
                keep_note $_ns "$_lr Hz; the link's speed is not measured yet"
                return 1
            fi
            out_log "link $_pcm at $_lr Hz: its frames could not be counted $KEEP_MTRIES times; counted again at its next start"
            K_MTRY=0
        fi
    fi
    if [ "$_lr" = 48000 ]; then
        echo "$K_PID $K_IO" > $R48
        chmod 644 $R48
    fi
    case "$_lr" in
        48000) keep_note 48k "48 kHz: Android Auto's music is not converted" ;;
        44100) if [ $K_WANT = 0 ]; then keep_note 44k "44.1 kHz (48 kHz output is off)"; else keep_note 44k "44.1 kHz"; fi ;;
        *) keep_note 44k "$_lr Hz" ;;
    esac
    return 0
}

keep_loop() {
    echo $$ > $KEEP_PID
    chmod 644 $KEEP_PID
    if [ -f $OUTLOG ]; then
        set -- $(ls -l $OUTLOG)
        [ "$(num $4)" -gt 32768 ] && mv $OUTLOG $S/output.old.log
    fi
    K_PID=""; K_IO=""; K_TID=""; K_OUT=""; K_LINK=""; K_LR=""; K_FPS=""; K_STATE=""; K_NOTED=""
    K_TRIES=0; K_HELD=""; K_LAST=""; K_MEASURED=""; K_WANT=""; K_NO48=""; K_MTRY=0
    K_SINCE=0; K_IDLED=""; K_IDLESW=""; K_UNSAFE=""; K_MISSAID=""; K_HOLDFAIL=""
    K_NOTE=""; K_OTHER=""; K_OTHER_NAME=""; K_OTHER_AT=""; K_PREV_STATE=""; K_PREV_NOTE=""
    LO_TID=""; LO_NTID=""; LO_PID=""; LO_NAME=""; LO_STATE=""; LO_RATE=""; O_FPS=""; HOLD_OTHER=""
    SR1=""; LR=""
    # 0.6.3 marked "no switch while nothing plays" here; 0.6.4 switches with a silent track instead
    rm -f $IDLE_BAD
    hold_end
    out_log "48 kHz keeper started (pid $$)"
    _round=0
    while :; do
        _round=$((_round + 1))
        # tests stop it after a number of rounds
        [ -n "$EQE_KEEP_ROUNDS" ] && [ $_round -gt $EQE_KEEP_ROUNDS ] && exit 0
        _kp=""
        [ -f $KEEP_PID ] && read _kp < $KEEP_PID
        [ "$_kp" = $$ ] || exit 0
        [ $((_round % 3)) = 0 ] && cpw_guard > /dev/null 2>&1
        _w=$(rate48_wanted)
        if [ "$_w" != "$K_WANT" ]; then
            if [ -n "$K_WANT" ]; then
                if [ $_w = 1 ]; then out_log "48 kHz output turned on"; else out_log "48 kHz output turned off"; fi
            fi
            # turned (back) on: one more go, even after a refusal or a crash, and idle again
            [ $_w = 1 ] && [ -n "$K_WANT" ] && { K_HELD=""; K_TRIES=0; K_NO48=""; }
            K_WANT=$_w
            K_LAST=""
            K_NOTED=""
        fi
        # an audio restart (or a Lab action) is under way: wait for it
        if [ -d $S/restart.lock ]; then
            sleep $KEEP_POLL
            continue
        fi
        if [ -z "$K_PID" ] || [ ! -d $PROC/$K_PID ]; then
            K_PID=$(ms_pid)
            K_IO=""; K_TID=""; K_OUT=""; K_LINK=""; K_LR=""; K_FPS=""
            K_TRIES=0; K_HELD=""; K_LAST=""; K_MEASURED=""; K_NOTED=""; K_MTRY=0
            K_SINCE=$(uptime_s); K_IDLED=""; K_IDLESW=""; K_UNSAFE=""; K_MISSAID=""
            # what was shown for the last audio server is not restored for this one
            K_PREV_STATE=""; K_PREV_NOTE=""
            hold_end
            rm -f $R48
            [ -n "$K_PID" ] && out_log "audio server $K_PID"
        fi
        if [ -n "$K_PID" ] && { [ -z "$K_TID" ] || [ ! -d $PROC/$K_PID/task/$K_TID ]; }; then
            set -- $(main_out)
            K_IO=$1; K_TID=$2; K_OUT=$3; K_LAST=""
        fi
        if [ -f $S/disabled ] && [ "$K_OUT" != 48000 ]; then
            # EQ Engine is off and the main output is not left at 48 kHz: nothing more to do
            out_log "EQ Engine is off; the keeper stops"
            keep_note off "EQ Engine is off"
            rm -f $KEEP_PID
            exit 0
        fi
        # another process (the factory CarPlay app) plays to the main link itself: hands off
        if link_other; then
            keep_other
            sleep $KEEP_POLL
            continue
        fi
        # (without an audio server nothing can be told: an audio restart is not the link let go)
        [ -n "$K_OTHER" ] && [ -n "$K_PID" ] && keep_other_gone
        if [ -z "$K_TID" ]; then
            sleep $KEEP_POLL
            continue
        fi
        set -- $(link_now $K_TID)
        if [ "$2" != RUNNING ]; then
            K_LAST=""
            [ -z "$K_STATE" ] && keep_note waiting "Waiting for music"
            keep_idle
            sleep $KEEP_POLL
            continue
        fi
        if [ "$1 $3" != "$K_LAST" ]; then
            if keep_check $1 $3 && [ -n "$K_PID" ]; then
                # remember the link as it is now, so only a new start or a new rate is checked again
                set -- $(link_now $K_TID)
                [ "$2" = RUNNING ] && K_LAST="$1 $3"
            fi
        fi
        sleep $KEEP_POLL
    done
}

# ------------------------------------------------------------------ car report
#
# One text file for sharing: what this car is, what EQ Engine finds on it and a short audio log.
# It is meant to hold nothing personal: lines that could carry Bluetooth addresses or device
# names, song details, a location, serial numbers or a VIN are dropped, and the kernel command
# line is never read. Hyundai's files are not copied: only their checksums, the sample rates
# their audio policy declares and (the CarPlay probe) names from their dynamic symbol tables.

# passes only lines that cannot carry personal data
safe() {
    while IFS= read -r _l; do
        case "$_l" in
            *"- name: "*) echo "$_l"; continue ;;
            *[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:*) continue ;;
            *[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-*) continue ;;
            *[Nn]ame=*|*[Nn]ame:*|*[Nn]ame\ :*|*NAME*|*[Aa]ddr*|*ADDR*|*[Ss]erial*|*SERIAL*|*[Ii][Mm][Ee][Ii]*|*[Ii][Cc][Cc][Ii][Dd]*) continue ;;
            *[Ss][Ss][Ii][Dd]*|*VIN*|*[Vv]in=*|*[Ss]ong*|*SONG*|*[Tt]itle*|*TITLE*|*[Aa]rtist*|*ARTIST*|*[Aa]lbum*|*ALBUM*) continue ;;
            *[Ll]atitude*|*[Ll]ongitude*|*[Ll]ongtitude*|*[Ll]at=*|*[Ll]on=*|*GPS*|*[Gg]ps*|*[Nn]umber=*|*[Cc]ontact*|*[Ee]mail*|*@*.*) continue ;;
            *[Cc]ommand\ line*|*androidboot*|*[Pp]assword*|*[Tt]oken*|*[Pp]airing*) continue ;;
        esac
        echo "$_l"
    done
}

# the build and audio properties, by an allowlist of names (and never ones that could be personal)
report_props() {
    getprop 2>/dev/null | while read -r _l; do
        _n=${_l%%]*}
        _n=${_n#[}
        case "$_n" in
            *serial*|*vin*|*imei*|*iccid*|*mac*|*addr*|*ssid*|*bt.*|*bluetooth*|*wifi*|*wlan*|*phone*|*imsi*|*msisdn*) continue ;;
            *key*|*token*|*pass*|*user*|*account*|*gps*|*location*|*name*|*host*|*cmdline*|*sim*|*number*|*boot.*) continue ;;
        esac
        case "$_n" in
            ro.build.*|ro.product.*|ro.board.*|ro.hardware|ro.chipname|ro.daudio.*|ro.config.*|af.*|audio.*|tcc.audio.*) echo "$_l" ;;
            persist.audio.*|persist.sys.audio*|*amp*|*sound*|*arkam*|*dsp*|*spdif*|*resampler*|*speaker*|*bose*|*premium*) echo "$_l" ;;
            *vehicle*|*model*|*region*|*country*|*variant*|*nemesis*|*hmg*|sys.boot_completed) echo "$_l" ;;
            ro.debuggable|ro.secure|wrap.$CP_APP) echo "$_l" ;;
        esac
    done | safe
}

# ---- the factory CarPlay app's audio code (the report's CarPlay probe, and carplay_probe.txt in
# All logs). Wired CarPlay's music does not go through Android's audio server (0.6.4 on the car):
# the factory CarPlay app opens the main link itself through TinyALSA. This lists the libraries the
# app has loaded, what each needs and which TinyALSA (pcm_*) and mixer (mixer_*) functions it
# imports, from their dynamic symbol tables (eqe_lab imports): no file is copied and no code is
# read or disassembled. libtinyalsa.so is a factory file: only its md5 and its exported names.
CP_APP=com.daudio.app.dipo
CP_TMP=$S/cp_probe

# the pid of the process whose command line is $1 (an app's main process: its name), from
# /proc/<pid>/cmdline (nothing if none)
pid_named() {
    for _cf in $PROC/[0-9]*/cmdline; do
        [ -f $_cf ] || continue
        _cc=""
        { read -r _cc < $_cf; } 2>/dev/null
        [ "$_cc" = "$1" ] || continue
        _cf=${_cf%/cmdline}
        echo "${_cf##*/}"
        return 0
    done
    return 1
}

# The zygote's pid (nothing if none), from /proc/<pid>/stat: its name there is "(zygote)" and its
# parent is init. Its cmdline cannot be compared: app_process writes "zygote" over the start of
# its first argument only, so the rest of the old arguments follows after a NUL, and the shell's
# read drops NULs (on the car the probe said "the zygote was not found", 2026-11-21).
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

# the pid of the factory CarPlay app's main process (nothing if none)
cp_pid() {
    pid_named $CP_APP
}

# the app's running services ("com.daudio.app.dipo/.Name"), from Android's own list
cp_services() {
    dumpsys activity services $CP_APP 2>/dev/null | {
        _so=""
        while read -r _sl; do
            case "$_sl" in
                *ServiceRecord\{*"$CP_APP/"*)
                    _sw=${_sl#*"$CP_APP/"}
                    _sw="$CP_APP/${_sw%%\}*}"
                    case " $_so " in
                        *" $_sw "*) ;;
                        *) _so="$_so $_sw" ;;
                    esac ;;
            esac
        done
        echo $_so
    }
}

# the CarPlay app's process (pid $1): its user, when it started, whether the CarPlay watch is in
# it, how Android keeps it (persistent: started again at once when it stops) and its services
cp_process_probe() {
    _pp=$1
    _pu=""; _pg=""; _ps=""; _ppp=""; _pgr=""; _pce=""; _pper=""
    if [ -f $PROC/$_pp/status ]; then
        while read -r _pk _pa _pb; do
            case "$_pk" in
                Uid:) _pu=$_pa ;;
                Gid:) _pg=$_pa ;;
                PPid:) _ppp=$_pa ;;
                Groups:) _pgr="$_pa${_pb:+ $_pb}" ;;
                CapEff:) _pce=$_pa ;;
            esac
        done < $PROC/$_pp/status
    fi
    [ -f $PROC/$_pp/personality ] && read -r _pper < $PROC/$_pp/personality
    if [ -f $PROC/$_pp/stat ]; then
        _pl=""
        read -r _pl < $PROC/$_pp/stat
        set -f
        set -- $_pl
        set +f
        [ $# -ge 22 ] && _ps=${22}
    fi
    case "$_ps" in
        ''|*[!0-9]*) _ps="?" ;;
        *) _ps=$((_ps / 100)) ;;
    esac
    echo "  its process: uid ${_pu:-?}, gid ${_pg:-?}, started at uptime $_ps s"
    # how it was started: a normal start is forked from the zygote (its parent); a start through the
    # wrap property runs a shell and app_process instead (CarPlay watch)
    _pz=$(zygote_pid)
    _ppn=""
    [ -n "$_ppp" ] && [ "$_ppp" = "$_pz" ] && _ppn=" (the zygote)"
    echo "  its parent: pid ${_ppp:-?}$_ppn; groups: ${_pgr:-none}; effective capabilities: ${_pce:-?}; personality: ${_pper:-?}"
    maps_has $_pp ${CPW_COPY##*/} && echo "  EQ Engine's CarPlay watch is loaded in it (in place of libCarPlayAndroid.so; started from the zygote as usual)"
    dumpsys package $CP_APP 2>/dev/null | {
        _pn=0
        while read -r _pl; do
            case "$_pl" in
                userId=*|sharedUser=*|pkgFlags=*|flags=*|codePath=*)
                    _pn=$((_pn + 1))
                    [ $_pn -le 8 ] && echo "  package: $_pl" ;;
            esac
        done
    }
    dumpsys activity processes 2>/dev/null > $CP_TMP/procs
    _pers=no; _pn=0
    while read -r _pl; do
        case "$_pl" in
            *"$_pp:$CP_APP/"*)
                _pn=$((_pn + 1))
                [ $_pn -le 4 ] && echo "  process list: $_pl"
                case "$_pl" in
                    *PERS*) _pers=yes ;;
                esac ;;
        esac
    done < $CP_TMP/procs
    echo "  persistent (Android starts it again at once when it stops): $_pers"
    _psv=$(cp_services)
    echo "  its running services: ${_psv:-none listed}"
    # a connected CarPlay session shows as established TCP connections of the app (0.6.10: logged
    # to check that on the car)
    cp_session $_pp
    if [ $CPS_OK = 1 ]; then
        echo "  its established network connections (a connected CarPlay session has some): $CPS_N"
    else
        echo "  its established network connections: could not be read"
    fi
}

# the distinct libraries (.so) mapped into the process $1, in the order they appear
cp_libs() {
    _cl=" "
    [ -f $PROC/$1/maps ] || return 0
    while read -r _ma _mp _mo _md _mi _mf _mx; do
        case "$_mf" in
            /*.so) ;;
            *) continue ;;
        esac
        case "$_cl" in
            *" $_mf "*) ;;
            *) _cl="$_cl$_mf "; echo "$_mf" ;;
        esac
    done < $PROC/$1/maps
}

# carplay_probe [list]: the probe, one item per line (with "list", for All logs: also the plain
# list of the mapped libraries and the CarPlay, DiPO, iAP and Telechips properties with their
# values; the report, which is for sharing, gets neither). Only symbol tables, checksums and
# properties are read: never a factory file's contents.
carplay_probe() {
    _cpmode=$1
    rm -rf $CP_TMP
    mkdir -p $CP_TMP
    _cpp=$(cp_pid)
    if [ -z "$_cpp" ]; then
        echo "  the factory CarPlay app ($CP_APP) is not running"
    else
        cp_libs $_cpp > $CP_TMP/libs
        _cpn=0; _cpa=""
        while read -r _cpl; do
            _cpn=$((_cpn + 1))
            case "$_cpl" in
                */libleafiaaac.so) _cpa=$_cpl ;;
            esac
        done < $CP_TMP/libs
        echo "  the factory CarPlay app ($CP_APP) runs as pid $_cpp, with $_cpn libraries mapped"
        if [ -n "$_cpa" ]; then
            echo "  HMG-API's AAC decoder libleafiaaac.so is mapped: $_cpa"
        else
            echo "  HMG-API's AAC decoder libleafiaaac.so is not mapped"
        fi
        if [ "$_cpmode" = list ]; then
            echo "  mapped libraries:"
            while read -r _cpl; do
                echo "    $_cpl"
            done < $CP_TMP/libs
        fi
        if [ ! -x $LABBIN ]; then
            echo "  eqe_lab is not installed: the symbol tables were not read"
        else
            while read -r _cpl; do
                echo "  library $_cpl"
                $LABBIN imports "$SYS$_cpl" < /dev/null > $CP_TMP/imp 2>&1
                _cpr=$?
                _cpd=""; _cpe=""
                _cpc=0
                case "$_cpl" in
                    */libCarPlay*.so) _cpc=1 ;;
                esac
                _cpx2=0
                : > $CP_TMP/pcm
                while read -r _cpk _cpv _cpx; do
                    case "$_cpk" in
                        needed) _cpd="$_cpd $_cpv" ;;
                        import)
                            case "$_cpv" in
                                pcm_*|mixer_*) echo "    imports $_cpv" >> $CP_TMP/pcm ;;
                                *AudioTrack*|*AudioSystem*|*AudioRecord*|*AudioEffect*|*AudioFlinger*|*AudioPolicy*|*IAudio*)
                                    [ $_cpc = 1 ] && echo "    imports (Android audio) $_cpv" >> $CP_TMP/pcm ;;
                            esac ;;
                        export)
                            [ $_cpc = 1 ] || continue
                            case "$_cpv" in
                                *[Tt][Ii][Nn][Yy]*|*[Aa][Ll][Ss][Aa]*|*[Aa]udio[Tt]rack*|*[Aa]udio[Ss]ystem*|*[Bb]ackend*)
                                    _cpx2=$((_cpx2 + 1))
                                    [ $_cpx2 -le 40 ] && echo "    exports (audio backend) $_cpv" >> $CP_TMP/pcm ;;
                            esac ;;
                        EQE_LAB_ERR) _cpe="$_cpv $_cpx"; [ "$_cpv" = "imports:" ] && _cpe=$_cpx ;;
                    esac
                done < $CP_TMP/imp
                [ $_cpx2 -gt 40 ] && echo "    ($((_cpx2 - 40)) more such exports not listed)" >> $CP_TMP/pcm
                if [ $_cpr != 0 ]; then
                    echo "    not read (${_cpe:-eqe_lab answered $_cpr})"
                    continue
                fi
                echo "    needs:${_cpd:- nothing}"
                cat $CP_TMP/pcm
            done < $CP_TMP/libs
        fi
        cp_process_probe $_cpp
    fi
    _cpt=$SYS/system/lib/libtinyalsa.so
    if [ ! -f $_cpt ]; then
        echo "  /system/lib/libtinyalsa.so is not there"
    else
        echo "  /system/lib/libtinyalsa.so (factory file, not copied): md5 $(md5of $_cpt)"
        if [ -x $LABBIN ]; then
            $LABBIN imports $_cpt < /dev/null > $CP_TMP/imp 2>&1
            while read -r _cpk _cpv _cpx; do
                case "$_cpk" in
                    export) echo "    exports $_cpv" ;;
                    EQE_LAB_ERR) [ "$_cpv" = "imports:" ] && _cpv=""; echo "    not read (${_cpv:+$_cpv }$_cpx)" ;;
                esac
            done < $CP_TMP/imp
        fi
    fi
    # config files named for CarPlay, DiPO or iAP (factory files: checksums only)
    for _cpf in $SYS/system/etc/* $SYS/system/etc/*/* $SYS/vendor/etc/*; do
        [ -f "$_cpf" ] || continue
        case "${_cpf##*/}" in
            *[Dd][Ii][Pp][Oo]*|*[Cc][Aa][Rr][Pp][Ll][Aa][Yy]*|*[Ii][Aa][Pp]2*|*[Ii][Aa][Pp]_*) ;;
            *) continue ;;
        esac
        echo "  config file ${_cpf#$SYS} (factory file): md5 $(md5of $_cpf)"
    done
    if [ "$_cpmode" = list ]; then
        echo "  properties for CarPlay, DiPO, iAP and Telechips:"
        getprop 2>/dev/null > $CP_TMP/props
        _cpn=0
        while IFS= read -r _cpl; do
            _cpk=${_cpl%%]*}
            _cpk=${_cpk#?}
            case "$_cpk" in
                *[Dd][Ii][Pp][Oo]*|*[Cc][Aa][Rr][Pp][Ll][Aa][Yy]*|*[Ii][Aa][Pp]*|tcc.*|*.tcc.*|*daudio*|wrap.*)
                    _cpn=$((_cpn + 1))
                    [ $_cpn -le 150 ] && echo "    $_cpl" ;;
            esac
        done < $CP_TMP/props
        [ $_cpn = 0 ] && echo "    none"
        [ $_cpn -gt 150 ] && echo "    ($((_cpn - 150)) more not listed)"
    fi
    # Hyundai's libmedia.so needs libbtsound.so, which needs libtinyalsa.so: loaded in the zygote,
    # every app has it from there (so a file laid over libtinyalsa.so would not reach the app)
    _zp=$(zygote_pid)
    if [ -z "$_zp" ]; then
        echo "  the zygote was not found"
    elif maps_has $_zp libtinyalsa.so; then
        echo "  libtinyalsa.so is loaded in the zygote (pid $_zp): every app has it from there"
    else
        echo "  libtinyalsa.so is not loaded in the zygote (pid $_zp)"
    fi
    for _cpk in ro.debuggable ro.secure wrap.$CP_APP; do
        echo "  $_cpk = [$(getprop $_cpk)]"
    done
    rm -rf $CP_TMP
    return 0
}

# ---- EQ on CarPlay, the CarPlay watch (act.sh cpwatch 1|0, cpwboot, cpwguard; 0.6.9, at the car start
# from 0.6.10, with the EQ from 0.7.3, on by default from 0.7.4)
#
# Wired CarPlay's music does not go through Android's audio server (0.6.4 on the car): the factory
# CarPlay app writes it to the main link itself, with Telechips' libCarPlayAudio.so and TinyALSA.
# The watch (native/cpwatch.c) runs EQ Engine's filter on that music from inside the app, and
# hands every other stream (Siri, calls) on untouched.
#
# It stands in for the app's JNI library: it is laid over /system/lib/libCarPlayAndroid.so (an
# in-memory bind mount; /system is never written), loads an unchanged copy of the car's own file
# (CPW_COPY, made here and checked by md5) and passes everything to it. The app starts from the
# zygote as always, so HMG-API's hooks and its checked library patches stay (0.6.9 on the car).
#
# 0.6.10: the watch is laid over at the car start (act.sh cpwboot, run by the boot step before the
# CarPlay app starts), never by restarting the app. 0.6.9 restarted the app to load and unload it,
# and a restart while a CarPlay session was connected (paused) lost the session (wired: until the
# cable was plugged in again) or left the car's source on the radio while CarPlay played into the
# link (wireless). So
# "cpwatch 1" only checks and records the choice (state/cpw_want) for the next car start, and
# "cpwatch 0" takes the mount off for the app's next start; the app running then keeps what it has
# loaded until the car restarts. The choice lasts across car starts until it is turned off.
#
# The keeper (cpw_guard) notes each start of the app. A second new start within two minutes takes
# the watch off (the mount and the choice), and so does a watch that says the factory library did
# not load; only in that last case is the app restarted (CarPlay cannot work in that start of the
# app, so no session can be connected), and only if cp_session finds no connection.
CPW=$D/lib/eqe_cpwatch.so
CPWSUM=$D/conf/eqe_cpwatch.md5
CPW_D=$D/cpw
CPW_ST=$S/cpwatch
CPW_T=$SYS/system/lib/libCarPlayAndroid.so
# the copy the watch loads (the same path as CPS_COPY in cpwatch.c)
CPW_COPY=$D/lib/libCarPlayAndroid.car.so
CPW_RS=$S/cpw_restarts
# "1 <md5 of the factory library that was checked> <the app's uid>" while the watch is on
CPW_WANT=$S/cpw_want
# 0.6.7's wrap property: not kept across car starts, cleared wherever one could be left
CPW_WRAP=wrap.$CP_APP
CPW_WAIT=${EQE_CPW_WAIT:-60}
# the app's services are started again after this long (s) if Android has not restarted it itself
CPW_NUDGE=${EQE_CPW_NUDGE:-15}

cpw_result() {
    echo "EQE_CPW $*"
    echo "$(uptime_s) $*" >> $S/cpw_result
    chmod 644 $S/cpw_result
}

# EQ on CarPlay is on by default (0.7.4). When it turns itself off (a check failed at the car
# start, the factory library did not load, the CarPlay app kept restarting with it, or the install
# could not prepare it), state/cpw_failed says when and why, once per occurrence (id), and the app
# tells the user the next time its screen opens. It is kept across car starts (All logs copies it).
# the reason in the words the app shows (the logs keep the full text)
cpw_user_why() {
    case "$1" in
        *"twice within 2 minutes"*) echo "the CarPlay app started again twice within 2 minutes with it" ;;
        *"could not load the factory library"*) echo "it could not load the factory CarPlay library" ;;
        *"CarPlay watch failed its check"*|*"not installed or failed its check"*)
            echo "its files failed their check (installing EQ Engine again fixes that)" ;;
        *"could not be laid over"*) echo "it could not be laid over the CarPlay app's library" ;;
        *) echo "$1" ;;
    esac
}

cpw_fail_note() {
    _fb=""
    [ -f $PROC/sys/kernel/random/boot_id ] && read -r _fb < $PROC/sys/kernel/random/boot_id
    {
        echo "id=${_fb:-boot}-$(uptime_s)"
        echo "when=$(date '+%Y-%m-%d %H:%M' 2>/dev/null)"
        echo "why=$(cpw_user_why "$1")"
    } > $S/cpw_failed.tmp
    mv $S/cpw_failed.tmp $S/cpw_failed
    chmod 644 $S/cpw_failed
}

# a refusal of "cpwatch 1": said to the app, and noted for it when nobody is looking (the install)
cpw_refuse() {
    cpw_result "refused: $1"
    [ "$EQE_CPW_NOTIFY" = 1 ] && cpw_fail_note "it could not be prepared: $(cpw_user_why "$1")"
    return 1
}

# state/cpwatch for the app: cpw_state <state> <pid> <note>. The states: pending (on from the next
# car start), waiting (laid over at this car start, the app has not loaded it yet), on (loaded in
# the app <pid>), ending (off from the next car start; the app <pid> keeps it until then), off,
# failed (the note says why).
cpw_state() {
    {
        echo "state=$1"
        echo "pid=$2"
        echo "since=$(uptime_s)"
        echo "note=$3"
    } > $CPW_ST.tmp
    mv $CPW_ST.tmp $CPW_ST
    chmod 644 $CPW_ST
}

# a field of state/cpwatch
cpw_get() {
    _cg=""
    if [ -f $CPW_ST ]; then
        while IFS='=' read -r _ck _cv; do
            [ "$_ck" = "$1" ] && _cg=$_cv
        done < $CPW_ST
    fi
    echo "$_cg"
}

cpw_prop_clear() {
    case "$(getprop $CPW_WRAP)" in
        *eqe_cpwatch.so*) setprop $CPW_WRAP "" ;;
    esac
}

# 0 = one of the process $1's threads has the main link open (CarPlay plays)
cp_has_link() {
    for _hf in $PROC/asound/card*/$MAIN_PCM/sub0/status; do
        [ -f $_hf ] || continue
        _how=""
        while read -r _hk _ha _hb _hc; do
            [ "$_hk" = owner_pid ] && _how=$_hb
        done < $_hf
        case "$_how" in
            ''|0|*[!0-9]*) continue ;;
        esac
        [ -d $PROC/$1/task/$_how ] && return 0
    done
    return 1
}

cp_uid() {
    _cu=""
    if [ -f $PROC/$1/status ]; then
        while read -r _ck _ca _crest; do
            [ "$_ck" = "Uid:" ] && _cu=$_ca
        done < $PROC/$1/status
    fi
    echo "$_cu"
}

# The CarPlay app's connections to a phone (0.6.10): established TCP connections whose socket is one
# of the process $1's open files. CarPlay runs over IP both ways (wired: the USB link's network,
# ncm0; wireless: the projection hotspot), with its session's control and screen on TCP. CPS_N =
# how many, CPS_OK = 1 when the app's files and the kernel's tables could be read. A connected
# session counts at least one (presumed from CarPlay's design; 0.6.10 logs it to check on the car).
cp_session() {
    CPS_N=0
    CPS_OK=0
    [ -d $PROC/$1/fd ] || return 1
    _sfl=$(ls -l $PROC/$1/fd 2>/dev/null)
    _sin=" "
    _sn=0
    while read -r _sl; do
        case "$_sl" in
            *"socket:["*"]"*)
                _si=${_sl##*"socket:["}
                _si=${_si%%"]"*}
                _sin="$_sin$_si "
                _sn=$((_sn + 1)) ;;
        esac
    done <<EOL
$_sfl
EOL
    _sread=0
    for _stf in $PROC/net/tcp $PROC/net/tcp6; do
        [ -f $_stf ] || continue
        _sread=1
        [ $_sn = 0 ] && continue
        # sl local remote st tx:rx tr:when retrnsmt uid timeout inode ...; st 01 = established
        while read -r _s0 _s1 _s2 _s3 _s4 _s5 _s6 _s7 _s8 _s9 _srest; do
            [ "$_s3" = 01 ] || continue
            case "$_sin" in
                *" $_s9 "*) CPS_N=$((CPS_N + 1)) ;;
            esac
        done < $_stf
    done
    [ $_sread = 1 ] && [ -n "$_sfl" ] && CPS_OK=1
    return 0
}

# the connection count of the process $1 as words, for notes
cp_conn() {
    cp_session $1
    if [ $CPS_OK = 1 ]; then
        echo "$CPS_N established connections"
    else
        echo "connections could not be read"
    fi
}

# 0 = the process $1 runs the watch (it has the copy of the factory library mapped)
cpw_in() {
    maps_has $1 ${CPW_COPY##*/}
}

# the watch's own state in the process $1 (its status file), "" before it wrote one
cpw_wstate() {
    _ws=""
    if [ -f $CPW_D/status.$1 ]; then
        while IFS='=' read -r _wk _wv; do
            [ "$_wk" = state ] && _ws=$_wv
        done < $CPW_D/status.$1
    fi
    echo "$_ws"
}

# Waits up to CPW_WAIT s for the CarPlay app to run again with a pid other than $1 (CPW_NEW). If
# Android has not started it again after CPW_NUDGE s, its services (CPW_SVCS) are started.
cp_wait_new() {
    CPW_NEW=""
    _wt0=$(uptime_s)
    _wn=0
    while [ $(($(uptime_s) - _wt0)) -lt $CPW_WAIT ]; do
        sleep 1
        _wp=$(cp_pid)
        if [ -n "$_wp" ] && [ "$_wp" != "$1" ]; then
            CPW_NEW=$_wp
            return 0
        fi
        if [ $_wn = 0 ] && [ $(($(uptime_s) - _wt0)) -ge $CPW_NUDGE ] && [ -n "$CPW_SVCS" ]; then
            _wn=1
            for _ws in $CPW_SVCS; do
                am startservice -n $_ws > /dev/null 2>&1
            done
            echo "EQE_CPW_NOTE the app had not started again after $CPW_NUDGE s; started its services: $CPW_SVCS"
        fi
    done
    return 1
}

# Restarts the app $1 (it runs the watch); with the mount gone it comes back stock. 0 = back
# without the watch (CPW_NEW); 1 = not back within CPW_WAIT s (CPW_NEW empty) or still with it.
cpw_restart_stock() {
    CPW_SVCS=$(cp_services)
    kill -9 $1
    cp_wait_new $1 || return 1
    ! cpw_in $CPW_NEW
}

# Takes the watch off for good: the mount and the choice, so the app's next start and the next car
# start are without it. $1 = the app's pid ("" if none), $2 = why. The app is restarted only when
# the watch in it says the factory library did not load (CarPlayService cannot start in that app
# start, so CarPlay cannot work there) and nothing is connected or playing.
cpw_takeoff() {
    rm -f $CPW_WANT $CPW_RS
    if ! cpw_unmount; then
        _tn="$2; turned off, but its mount could not be removed now (it is gone at the next car start); restart the car (parked)"
        cpw_state failed "" "$_tn"
        cpw_result "taken off: $_tn"
        cpw_fail_note "$2"
        return 1
    fi
    _tn="$2; taken off (the CarPlay app's next start and the next car start are without it)"
    if [ -n "$1" ] && [ -d $PROC/$1 ] && [ "$(cpw_wstate $1)" = failed ]; then
        cp_session $1
        if ! cp_has_link $1 && [ $CPS_OK = 1 ] && [ $CPS_N = 0 ]; then
            if cpw_restart_stock $1; then
                _tn="$2; taken off, and the CarPlay app restarted without it (pid $CPW_NEW)"
            else
                _tn="$2; taken off, but the CarPlay app did not start again without it; restart the car (parked)"
            fi
        else
            _tn="$2; taken off; the CarPlay app was not restarted ($(cp_conn $1)); restart the car (parked) to bring CarPlay back"
        fi
    fi
    cpw_state failed "" "$_tn"
    cpw_result "taken off: $_tn"
    cpw_fail_note "$2"
}

cpw_lock() {
    if ! mkdir $S/cpwatch.lock 2>/dev/null; then
        _lt=""
        [ -f $S/cpwatch.lock/at ] && read _lt < $S/cpwatch.lock/at
        _lt=$(num "$_lt")
        if [ $(($(uptime_s) - _lt)) -lt $((CPW_WAIT + 30)) ]; then
            echo EQE_WAIT
            echo "The CarPlay watch is already being switched. Try again in a minute."
            return 1
        fi
        rm -rf $S/cpwatch.lock
        mkdir $S/cpwatch.lock 2>/dev/null || { echo EQE_WAIT; echo "The CarPlay watch is already being switched."; return 1; }
    fi
    uptime_s > $S/cpwatch.lock/at
    trap 'rm -rf $S/cpwatch.lock' EXIT
    return 0
}

# the watch installed and unchanged since the install (its md5 then): 0, else 1
cpw_file_ok() {
    [ -f $CPW ] && [ -f $CPWSUM ] || return 1
    _cw=""
    read _cw < $CPWSUM
    [ -n "$_cw" ] && [ "$(md5of $CPW)" = "$_cw" ]
}

# 0.7.6: what is mounted at the CarPlay app's JNI library path is checked by whose file it is.
# 0 = EQ Engine's watch is the file there now (the top of anything mounted there).
cpw_mounted() {
    mounted_at $CPW_T || return 1
    _mw=""
    [ -f $CPWSUM ] && read _mw < $CPWSUM
    [ -n "$_mw" ] && [ "$(md5of $CPW_T)" = "$_mw" ]
}

# 0 = something that is not EQ Engine's watch is mounted there (another package's file)
cpw_foreign() {
    mounted_at $CPW_T && ! cpw_mounted
}

# Takes EQ Engine's watch off that path, and only it: one mount at a time while the file on top is
# the watch, never another package's mount there. A plain umount says "busy" while a process has
# the file mapped: then it is detached (eqe_lab umount). 0 = the watch is not mounted there now.
cpw_unmount() {
    _ui=0
    while cpw_mounted && [ $_ui -lt 4 ]; do
        umount $CPW_T 2>/dev/null || { [ -x $LABBIN ] && $LABBIN umount $CPW_T > /dev/null 2>&1; }
        _ui=$((_ui + 1))
        cpw_mounted && sleep 1
    done
    ! cpw_mounted
}

# Makes CPW_COPY the same as the factory file, whose md5 is $1: 0 when it is
cpw_copy() {
    if [ ! -f $CPW_COPY ] || [ "$(md5of $CPW_COPY)" != "$1" ]; then
        cat $CPW_T > $CPW_COPY.tmp 2>/dev/null && mv $CPW_COPY.tmp $CPW_COPY
        rm -f $CPW_COPY.tmp
    fi
    [ -f $CPW_COPY ] && [ "$(md5of $CPW_COPY)" = "$1" ] || return 1
    chmod 644 $CPW_COPY $CPW
}

# Lays the watch over the CarPlay app's JNI library and checks that what is there now is the watch
# (its md5 from the install): 0, else the mount is taken off again and 1.
cpw_mount() {
    if ! mount -o bind $CPW $CPW_T || ! cpw_mounted; then
        cpw_unmount
        return 1
    fi
    return 0
}

# act.sh cpwatch 1: checks the watch and the copy now, and records the choice for the next car start.
# Nothing is restarted and nothing is laid over now.
cpwatch_on() {
    [ -f $S/disabled ] && { cpw_result "refused: EQ Engine is off; turn it on first"; return 1; }
    cpw_prop_clear
    cpe_share
    # a unit without the factory CarPlay app: nothing to do, and nothing failed
    if [ ! -f $CPW_T ] && ! mounted_at $CPW_T; then
        cpw_state absent "" "this unit has no factory CarPlay app ($CPW_T)"
        cpw_result "refused: this unit has no $CPW_T"
        return 1
    fi
    cpw_file_ok || { cpw_refuse "the CarPlay watch is not installed or failed its check"; return 1; }
    [ -x $LABBIN ] || { cpw_refuse "eqe_lab is not installed"; return 1; }
    _cpp=$(cp_pid)
    if cpw_foreign; then
        cpw_refuse "another package has a file laid over $CPW_T; EQ on CarPlay stays off so it does not undo that"
        return 1
    fi
    if cpw_mounted; then
        # laid over at this car start and still there (the choice is kept or written again)
        [ -f $CPW_WANT ] || {
            _cu=1000
            [ -n "$_cpp" ] && _cu=$(cp_uid $_cpp)
            echo "1 $(md5of $CPW_COPY) ${_cu:-1000}" > $CPW_WANT
            chmod 644 $CPW_WANT
        }
        cpw_result "already on"
        return 0
    fi
    # the unchanged copy of the car's own file that the watch loads in the app
    _fm=$(md5of $CPW_T)
    cpw_copy $_fm || { cpw_refuse "the copy of the factory CarPlay library could not be made"; return 1; }
    # checked before use, in a process of its own: the watch loads, finds TinyALSA's functions, and
    # reads the copy as a file
    _cc=$($LABBIN cpcheck $CPW $CPW_COPY 2>&1)
    case "$_cc" in
        "cpcheck ok "*) ;;
        *) cpw_refuse "the CarPlay watch did not pass its check before use (${_cc#cpcheck })"; return 1 ;;
    esac
    # the app's user: the notes folder is made its own at the car start (the CarPlay app runs as
    # the system user, 1000, on this unit)
    _cu=""
    [ -n "$_cpp" ] && _cu=$(cp_uid $_cpp)
    case "$_cu" in
        ''|*[!0-9]*) _cu=1000 ;;
    esac
    echo "1 $_fm $_cu" > $CPW_WANT.tmp && mv $CPW_WANT.tmp $CPW_WANT
    chmod 644 $CPW_WANT
    if [ -n "$_cpp" ] && cpw_in $_cpp; then
        # 0.7.5: turned off and on again within one car start (or EQ Engine off and on): the CarPlay
        # app running now still has the watch loaded, and its EQ follows the switch at once. It is
        # laid over again for that app's next start, as at the car start, and the guard watches it.
        [ -n "$_cpp" ] && echo "EQE_CPW_NOTE the CarPlay app (pid $_cpp) has $(cp_conn $_cpp) now"
        rm -f $CPW_RS
        if cpw_mount; then
            cpw_state on $_cpp "watching (still loaded since the car start; turned on again)"
            cpw_result "on: still loaded in the CarPlay app (pid $_cpp); laid over again for its next start. Nothing was restarted"
        else
            cpw_state on $_cpp "watching (still loaded since the car start); laid over again from the next car start"
            cpw_result "on: still loaded in the CarPlay app (pid $_cpp); laid over again from the next car start. Nothing was restarted"
        fi
        return 0
    else
        cpw_state pending "" "on from the next car start"
    fi
    [ -n "$_cpp" ] && echo "EQE_CPW_NOTE the CarPlay app (pid $_cpp) has $(cp_conn $_cpp) now"
    cpw_result "on from the next car start; restart the car (parked) to start it. Nothing was restarted now"
}

# act.sh cpwatch 0: the choice and the mount off. The app running now keeps the watch until the car
# restarts (with the EQ on CarPlay's music, unless its switch is off); its next start, and the next car start, are without it.
cpwatch_off() {
    cpw_prop_clear
    rm -f $CPW_WANT $CPW_RS
    _cpp=$(cp_pid)
    [ -n "$_cpp" ] && echo "EQE_CPW_NOTE the CarPlay app (pid $_cpp) has $(cp_conn $_cpp) now"
    if ! cpw_unmount; then
        cpw_state ending "$_cpp" "off from the next car start (the mount could not be removed now)"
        cpw_result "off from the next car start; the watch's mount could not be removed now"
        return 1
    fi
    if [ -n "$_cpp" ] && cpw_in $_cpp; then
        cpw_state ending $_cpp "off from the next car start; the CarPlay app running now keeps it until then (the EQ on CarPlay's music too, unless its switch is off)"
        cpw_result "off from the next car start; the CarPlay app running now keeps it until then (the EQ on CarPlay's music too, unless its switch is off). Nothing was restarted"
    else
        cpw_state off "" "off"
        cpw_result "off"
    fi
    return 0
}

# act.sh cpwboot (the boot step, at the car start, before the CarPlay app starts): lays the watch
# over the app's JNI library when it is on, after checking that the watch, the factory file and the
# copy are the ones checked when it was turned on.
cpw_boot_fail() {
    rm -f $CPW_WANT
    cpw_state failed "" "$1; it stays off until it is turned on again"
    cpw_result "not laid over at this start: $1"
    cpw_fail_note "$1"
}

# EQ on CarPlay's music (0.7.3): the folder the app writes the CarPlay watch's settings to
# (share/cp_eq.bin, native/cpeq.h): the app's own, readable by the CarPlay app (another user)
cpe_share() {
    mkdir -p $D/share
    _so=$(owner_of $D/settings)
    [ -n "$_so" ] && chown $_so:$_so $D/share 2>/dev/null
    chmod 755 $D/share
}

cpw_boot() {
    [ -f $CPW_WANT ] || return 0
    _bw=""; _bm=""; _bu=""
    read -r _bw _bm _bu < $CPW_WANT
    [ "$_bw" = 1 ] || return 0
    [ -f $S/disabled ] && return 0
    case "$_bu" in
        ''|*[!0-9]*) _bu=1000 ;;
    esac
    # already laid over at this car start (the boot step runs again when EQ Engine is turned on)
    cpw_mounted && return 0
    if cpw_foreign; then
        cpw_boot_fail "another package has a file laid over $CPW_T, so EQ on CarPlay stays off and does not undo that"
        return 1
    fi
    _bp=$(cp_pid)
    # (an app that already runs the watch, from an earlier mount that was taken off, is laid over
    # for as usual: the watch is what it has; its maps show the watch under the factory name or,
    # once the mount was detached, under none)
    if [ -n "$_bp" ] && ! cpw_in $_bp && maps_has $_bp ${CPW_T##*/}; then
        cpw_state pending "" "on from the next car start (the CarPlay app had already loaded its library at this start)"
        cpw_result "not laid over at this start: the CarPlay app (pid $_bp) had already loaded its library; on from the next car start"
        return 0
    fi
    cpw_file_ok || { cpw_boot_fail "the CarPlay watch failed its check"; return 1; }
    [ -f $CPW_T ] || { cpw_boot_fail "this unit has no $CPW_T"; return 1; }
    _fm=$(md5of $CPW_T)
    cpw_copy $_fm || { cpw_boot_fail "the copy of the factory CarPlay library could not be made"; return 1; }
    if [ "$_fm" != "$_bm" ]; then
        # 0.7.4: the factory library changed since it was checked (a software update): the new one
        # is checked the same way before use, and the choice follows it
        _cc=$($LABBIN cpcheck $CPW $CPW_COPY 2>&1)
        case "$_cc" in
            "cpcheck ok "*) ;;
            *) cpw_boot_fail "the factory CarPlay library changed (a software update?) and the new one did not pass the check before use (${_cc#cpcheck })"; return 1 ;;
        esac
        echo "1 $_fm $_bu" > $CPW_WANT.tmp && mv $CPW_WANT.tmp $CPW_WANT
        chmod 644 $CPW_WANT
        cpw_result "the factory CarPlay library changed (a software update?); the new one passed the check before use"
    fi
    # the last start's notes are kept once; the watch writes its notes as the app's own user. Not
    # while the app runs the watch: its notes and its live file (mapped by path) stay where they are
    if [ -z "$_bp" ] || ! cpw_in $_bp; then
        rm -rf $CPW_D.prev
        [ -d $CPW_D ] && mv $CPW_D $CPW_D.prev
    fi
    mkdir -p $CPW_D
    cpe_share
    if chown $_bu:$_bu $CPW_D 2>/dev/null; then
        chmod 755 $CPW_D
    else
        chmod 777 $CPW_D
    fi
    rm -f $CPW_RS
    if ! cpw_mount; then
        cpw_boot_fail "the CarPlay watch could not be laid over $CPW_T"
        return 1
    fi
    cpw_state waiting "" "laid over at the car start; waiting for the CarPlay app to load it"
    cpw_result "laid over the CarPlay app's JNI library at the car start (uptime $(uptime_s))"
}

# The keeper's check (every few seconds; act.sh cpwguard runs it once) while the watch is laid
# over: the app's first start with it is noted (on), a later start too (it keeps the watch, the
# mount is still there), a second later start within two minutes takes it off, and so does a watch
# that says the factory library did not load.
cpw_guard() {
    case "$(cpw_get state)" in
        waiting|on) ;;
        *) return 0 ;;
    esac
    cpw_mounted || return 0
    _gp=$(cpw_get pid)
    _gn=$(cp_pid)
    [ -n "$_gn" ] || return 0
    # 0.7.6: the watch's own status in this app process first. When the factory library did not
    # load at all, its copy is never mapped, so the mapping test below would wait for it forever.
    if [ "$(cpw_wstate $_gn)" = failed ]; then
        cpw_takeoff $_gn "the watch could not load the factory library (pid $_gn)"
        return 0
    fi
    [ "$_gn" = "$_gp" ] && return 0
    # a start of the app that has not loaded its JNI library yet: looked at again next round
    cpw_in $_gn || return 0
    if [ -n "$_gp" ]; then
        _now=$(uptime_s)
        echo $_now >> $CPW_RS
        chmod 644 $CPW_RS
        _gc=0
        while read -r _gt; do
            case "$_gt" in
                ''|*[!0-9]*) continue ;;
            esac
            [ $((_now - _gt)) -le 120 ] && _gc=$((_gc + 1))
        done < $CPW_RS
        if [ $_gc -ge 2 ]; then
            cpw_takeoff $_gn "the factory CarPlay app started again twice within 2 minutes with the watch"
            return 0
        fi
        cpw_state on $_gn "watching (the app started again: pid $_gp -> $_gn)"
        cpw_result "the factory CarPlay app started again (pid $_gp -> $_gn); the watch stays on"
        return 0
    fi
    cpw_state on $_gn "watching"
    cpw_result "loaded in the factory CarPlay app (pid $_gn), started from the zygote as usual"
    return 0
}

# EQ Engine off, and the start of an uninstall: the choice and the mount off; the app running then
# keeps the watch until the car restarts (its EQ passes the music through untouched: EQ Engine is off). Nothing is restarted.
cpw_all_off() {
    cpw_prop_clear
    [ -f $CPW_WANT ] || cpw_mounted || [ "$(cpw_get state)" = on ] || return 0
    rm -f $CPW_WANT $CPW_RS
    cpw_unmount
    _ap=$(cp_pid)
    if [ -n "$_ap" ] && cpw_in $_ap; then
        cpw_state ending $_ap "off (EQ Engine turned off); the CarPlay app running now keeps it until the next car start"
    else
        cpw_state off "" "off (EQ Engine turned off)"
    fi
}

cpwatch_action() {
    case "$1" in
        0|1) ;;
        *) echo "usage: act.sh cpwatch <watch 0|1>"; return 2 ;;
    esac
    cpw_lock || return 3
    if [ $1 = 1 ]; then cpwatch_on; else cpwatch_off; fi
}

# "<section>: <rates>" for each part of an audio policy file that declares sampling rates
policy_rates() {
    _sec=""
    while read -r _k _v _r; do
        [ "$_v" = "{" ] && _sec=$_k
        [ "$_k" = sampling_rates ] && echo "  $_sec: $_v"
    done < $1
}

# the audio lines of the kernel log (never its command line)
dmesg_audio() {
    dmesg 2>/dev/null | while read -r _l; do
        case "$_l" in
            *[Cc]ommand\ line*|*androidboot*) continue ;;
            *I2S*|*AUDIO*|*[Aa]udio*|*ASoC*|*asoc*|*snd*|*SND*|*pcm*|*PCM*|*codec*|*CODEC*|*[Aa]mplifier*|*\ AMP*|*DSP*|*SPDIF*|*spdif*|*1288*|*tcc-snd*|*tcc_snd*) echo "$_l" ;;
        esac
    done | safe
}

# process names of the audio server's clients (which app plays what)
client_names() {
    _pids=""
    for _p in $(dumpsys media.audio_flinger 2>/dev/null | {
        while read _a _b _rest; do
            [ "$_a" = "pid:" ] && echo "$_b"
        done
    }); do
        case " $_pids " in
            *" $_p "*) ;;
            *) _pids="$_pids $_p" ;;
        esac
    done
    for _p in $_pids; do
        echo "  $_p $(proc_name $_p)"
    done
}

# who plays on each hardware link: "pcm2p: RUNNING, played by thread 397 of /system/bin/mediaserver"
link_owners() {
    for _f in $PROC/asound/card*/pcm*p/sub0/status; do
        [ -f $_f ] || continue
        _st=""; _ow=""
        while read -r _k _a _b _c; do
            case "$_k" in
                state:) _st=$_a ;;
                owner_pid) _ow=$_b ;;
            esac
        done < $_f
        _d=${_f%/sub0/status}
        if [ -z "$_ow" ]; then
            echo "  ${_d##*/}: closed"
            continue
        fi
        _tg=""
        if [ -f $PROC/$_ow/status ]; then
            while read -r _k _a _rest; do
                [ "$_k" = "Tgid:" ] && _tg=$_a
            done < $PROC/$_ow/status
        fi
        echo "  ${_d##*/}: $_st, played by thread $_ow of $(proc_name ${_tg:-$_ow})"
    done
}

# squeeze: a line already seen more than 3 times (apart from its time) is counted, not repeated.
# Android 4.4 logs some warnings at every mix cycle (25 a second) and they would fill the report.
squeeze() {
    _m1=""; _c1=0; _m2=""; _c2=0; _m3=""; _c3=0; _next=1
    while IFS= read -r _l; do
        _m=${_l#* }
        _m=${_m#* }
        if [ "$_m" = "$_m1" ]; then _c1=$((_c1 + 1)); _n=$_c1
        elif [ "$_m" = "$_m2" ]; then _c2=$((_c2 + 1)); _n=$_c2
        elif [ "$_m" = "$_m3" ]; then _c3=$((_c3 + 1)); _n=$_c3
        else
            case $_next in
                1) [ $_c1 -gt 3 ] && echo "(the line \"$_m1\" came $((_c1 - 3)) more times)"; _m1=$_m; _c1=1; _next=2 ;;
                2) [ $_c2 -gt 3 ] && echo "(the line \"$_m2\" came $((_c2 - 3)) more times)"; _m2=$_m; _c2=1; _next=3 ;;
                *) [ $_c3 -gt 3 ] && echo "(the line \"$_m3\" came $((_c3 - 3)) more times)"; _m3=$_m; _c3=1; _next=1 ;;
            esac
            _n=1
        fi
        [ $_n -le 3 ] && echo "$_l"
        [ $_n = 3 ] && echo "(the same line again from here on is counted, not shown)"
    done
    [ $_c1 -gt 3 ] && echo "(the line \"$_m1\" came $((_c1 - 3)) more times)"
    [ $_c2 -gt 3 ] && echo "(the line \"$_m2\" came $((_c2 - 3)) more times)"
    [ $_c3 -gt 3 ] && echo "(the line \"$_m3\" came $((_c3 - 3)) more times)"
    return 0
}

# check <ok|NO|?> <text>
check() {
    case "$1" in
        ok) echo "  ok    $2" ;;
        NO) echo "  NO    $2" ;;
        *) echo "  ?     $2" ;;
    esac
}

report_checks() {
    _rel=$(getprop ro.build.version.release)
    _sdk=$(getprop ro.build.version.sdk)
    if [ "$_sdk" = 19 ]; then check ok "Android $_rel (API $_sdk)"; else check NO "Android $_rel (API $_sdk); EQ Engine is built for Android 4.4 (API 19)"; fi
    _prod=$(getprop ro.build.product)
    case "$_prod" in
        NEEV.USA.*) check ok "head unit software $_prod (the package is marked for NEEV.USA.*)" ;;
        *) check ? "head unit software $_prod: not the car EQ Engine was tested on (2022 Ioniq 5, USA)" ;;
    esac
    _st=$(state_now)
    _why=""
    if [ -f $S/status ]; then
        while read -r _l; do
            case "$_l" in
                reason=*) _why=${_l#reason=} ;;
            esac
        done < $S/status
    fi
    case "$_st" in
        applied) check ok "boot step: applied ($_why)" ;;
        "") check NO "boot step: no status (it has not run)" ;;
        *) check NO "boot step: $_st ($_why)" ;;
    esac
    [ -f $SYS/vendor/etc/audio_effects.conf ] && check NO "/vendor/etc/audio_effects.conf exists: Android reads it instead of the one EQ Engine lays over"
    _m=$(md5of $EFX_T)
    if [ ! -f $EFX_T ]; then
        check NO "effects list: $EFX_T is missing"
    elif mounted_at $EFX_T; then
        check ok "effects list: EQ Engine's copy is laid over Android's (md5 $_m)"
    elif [ "$_m" = $EFX_MD5 ]; then
        check ok "effects list: the stock one EQ Engine was built for (md5 $_m), not laid over now"
    else
        check NO "effects list: md5 $_m, not the one EQ Engine was built for ($EFX_MD5)"
    fi
    _p=$(ms_pid)
    if [ -z "$_p" ]; then
        check NO "Android's audio server is not running"
    else
        if maps_has $_p libeqengine.so; then check ok "EQ Engine's filter is loaded in the audio server ($_p)"
        else check NO "EQ Engine's filter is not loaded in the audio server ($_p)"; fi
        if dumpsys media.audio_flinger 2>/dev/null | {
            _f=1
            while read -r _l; do
                case "$_l" in
                    *"name: EQ Engine"*) _f=0 ;;
                esac
            done
            exit $_f
        }; then check ok "the EQ is attached to the main output's mix (session 0)"
        else check NO "the EQ is not attached to any output (the app attaches it once the filter is loaded)"; fi
        _q=$(getprop af.resampler.quality)
        if [ "$_q" = 4 ]; then
            if maps_has $_p libaudio-resampler.so; then check ok "converter: very high quality with EQ Engine's tables (loaded)"
            else check NO "converter: very high quality asked for, but EQ Engine's tables are not loaded"; fi
        else
            check ok "converter: af.resampler.quality=${_q:-unset}"
        fi
    fi
    _drv=$HAL_T
    mounted_at $HAL_T && _drv=$HAL_COPY
    _hm=$(md5of $_drv)
    if [ "$_hm" = $HAL_MD5 ]; then check ok "audio driver: the same one as on the tested car (md5 $_hm)"
    else check ? "audio driver: md5 ${_hm:-missing}, not the tested car's; the driver watch will not start"; fi
    [ -f $SYS/vendor/lib/hw/audio.primary.tcc803x.so ] && check NO "a vendor audio driver exists; Android loads it first"
    if [ -x $LABBIN ]; then
        _c=$($LABBIN check 2>&1)
        case "$_c" in
            *"symbols 4 of 4"*) check ok "the 48 kHz switch can reach Android's audio server (AudioSystem functions found)" ;;
            *) check NO "the 48 kHz switch cannot reach the audio server: $(flat $_c)" ;;
        esac
    else
        check NO "eqe_lab is not installed"
    fi
    if [ -n "$_p" ]; then
        set -- $(main_out)
        _io=$1; _tid=$2; _sr=$3
        if [ -n "$_sr" ]; then
            set -- $(link_of $_tid 3000)
            if [ -n "$1" ]; then
                check ok "main output: io $_io at $_sr Hz; link $1 set to $2 Hz, measured ${3%%.*} frames/s"
            else
                check ? "main output: io $_io at $_sr Hz; nothing was playing, so the link was not measured"
            fi
            K_IO=$_io
            buffers_check
            case $? in
                0) check ok "track buffers: all $BUF_N tracks on the main output play into its mix buffer or their own effect chain" ;;
                1) check NO "track buffers: tracks of session(s) $STALE play into a buffer the main output no longer uses (Android 4.4 loses them at a rate change): restart Android audio (parked)" ;;
                *) check ? "track buffers: the audio server's dump does not show them" ;;
            esac
        else
            check NO "main output: not found in the audio server's dump"
        fi
    fi
    if [ -f $OUTST ]; then
        _os=""; _on=""
        while read -r _l; do
            case "$_l" in
                state=*) _os=${_l#state=} ;;
                note=*) _on=${_l#note=} ;;
            esac
        done < $OUTST
        case "$_os" in
            48k) check ok "48 kHz output: $_on" ;;
            44k|waiting|off|other) check ? "48 kHz output: $_on" ;;
            *) check NO "48 kHz output: $_on" ;;
        esac
    else
        check ? "48 kHz output: no report from the keeper yet"
    fi
}

flat() {
    set -- $*
    echo "$*"
}

report_section() {
    echo
    echo "==================== $*"
}

report() {
    U=$1
    A=$2
    N=$3
    case "$N" in
        ''|*[!0-9]*) N=30 ;;
    esac
    [ $N -gt 120 ] && N=120
    [ -d "$U" ] || { echo "no USB stick at $U"; return 1; }
    _prod=$(getprop ro.build.product)
    case "$_prod" in
        ''|*[!A-Za-z0-9._-]*) _prod=unknown ;;
    esac
    mkdir -p "$U/EQENGINE" || { echo "cannot write to the stick"; return 1; }
    F="$U/EQENGINE/report_${_prod}_$(date +%Y%m%d_%H%M%S).txt"
    TMPL=$S/report_log.txt
    rm -f $TMPL
    # the audio log while the report runs (plus whatever the log still holds from before)
    logcat -v time -f $TMPL -s AudioFlinger:V AudioPolicyManagerBase:V AudioPolicyService:V AudioResampler:V \
        AudioResamplerSinc:V audio_hw_primary:V audio_hw_fm1288:V EQEDrv:V AudioService:V MicomAudioService:V \
        MicomAudioManager:V AudioTrack:V < /dev/null > /dev/null 2>&1 &
    _lp=$!
    {
        echo "EQ Engine car report"
        echo
        echo "Made by EQ Engine $VER on $(date)."
        echo "It is meant to hold nothing personal: lines that could carry Bluetooth addresses or device"
        echo "names, song details, a location, serial numbers or a VIN are left out, and the car maker's"
        echo "files are not copied (only their checksums, declared sample rates and the names in their"
        echo "symbol tables). Please read it through before you post it anywhere public."
        report_section "Car"
        for _k in ro.build.product ro.product.device ro.product.model ro.build.description ro.build.version.release; do
            echo "  $_k = $(getprop $_k)"
        done
        report_section "Checks"
        report_checks
        report_section "Audio hardware at the start"
        echo "-- who plays on each output link"
        link_owners
        for _f in $PROC/asound/cards $PROC/asound/pcm $PROC/asound/card*/pcm*/sub0/hw_params $PROC/asound/card*/pcm*/sub0/status; do
            [ -f $_f ] && { echo "== $_f"; cat $_f; }
        done
        report_section "Factory audio files (checksums only)"
        for _f in $SYS/system/etc/audio_policy.conf $SYS/vendor/etc/audio_policy.conf $EFX_T $SYS/vendor/etc/audio_effects.conf \
                  $SYS/system/lib/hw/audio.primary.*.so $SYS/vendor/lib/hw/audio.*.so $SYS/system/lib/libmedia.so; do
            [ -f $_f ] || continue
            set -- $(ls -l $_f)
            echo "  $(md5of $_f) $4 bytes $_f"
        done
        mounted_at $HAL_T && echo "  (the driver watch is laid over the driver; the factory driver's copy: $(md5of $HAL_COPY))"
        mounted_at $EFX_T && echo "  (EQ Engine's effects list is laid over Android's)"
        for _f in $SYS/system/etc/audio_policy.conf $SYS/vendor/etc/audio_policy.conf; do
            [ -f $_f ] && { echo "  sample rates declared in $_f:"; policy_rates $_f; }
        done
        echo "  driver folders:"
        ls -l $SYS/system/lib/hw $SYS/vendor/lib/hw 2>&1 | safe
        echo "-- CarPlay app's audio code (symbol tables only)"
        carplay_probe | safe
        report_section "Properties (build and audio only)"
        report_props
        report_section "Apps playing through Android's audio server"
        client_names
        report_section "Android's audio server"
        dumpsys media.audio_flinger 2>&1 | safe
        report_section "Android's audio policy"
        dumpsys media.audio_policy 2>&1 | safe
        report_section "EQ Engine: boot step"
        [ -f $S/status ] && cat $S/status
        echo "-- events"
        [ -f $S/events.log ] && safe < $S/events.log
        report_section "EQ Engine: 48 kHz output"
        [ -f $OUTST ] && cat $OUTST
        echo "-- what the keeper did"
        [ -f $S/output.prev.log ] && { echo "(the previous car start)"; safe < $S/output.prev.log; echo "(this car start)"; }
        [ -f $OUTLOG ] && safe < $OUTLOG
        report_section "EQ Engine: Lab"
        cat $S/lab_active $S/lab_result 2>/dev/null
        if [ -f $DRV/status ]; then
            echo "-- driver watch"
            cat $DRV/status
            [ -f $DRV/drv.log ] && safe < $DRV/drv.log
        fi
        if [ -f $CPW_ST ] || [ -d $CPW_D ]; then
            echo "-- CarPlay watch"
            cat $CPW_ST $S/cpw_result 2>/dev/null
            for _f in $CPW_D/status.* $CPW_D/cpw_*.log; do
                [ -f $_f ] && { echo "== ${_f##*/}"; safe < $_f; }
            done
        fi
        report_section "EQ Engine: app log"
        [ -f "$A/eqengine.log" ] && safe < "$A/eqengine.log"
        report_section "Kernel log: audio lines"
        dmesg_audio
    } > "$F.part" 2>&1
    # let the audio log run for the time asked for
    sleep $N
    {
        report_section "Audio hardware after $N s (link rate measured over 3 s)"
        echo "-- who plays on each output link"
        link_owners
        for _f in $PROC/asound/card*/pcm*/sub0/hw_params $PROC/asound/card*/pcm*/sub0/status; do
            [ -f $_f ] && { echo "== $_f"; cat $_f; }
        done
        [ -x $LABBIN ] && $LABBIN rate 3000 2>&1
        report_section "Audio log (audio tags only, filtered)"
        kill $_lp 2>/dev/null
        safe < $TMPL | squeeze
    } >> "$F.part" 2>&1
    kill $_lp 2>/dev/null
    rm -f $TMPL
    mv "$F.part" "$F"
    sync
    echo "EQE_REPORT ${F##*/}"
    echo "saved to $F"
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
    # act.sh lab <watch 0|1> (a second argument, from 0.6.1's app, is ignored)
    case "$1" in
        0|1) ;;
        *) echo "usage: act.sh lab <watch 0|1>"; return 2 ;;
    esac
    [ -f $S/disabled ] && { echo "EQ Engine is off; turn it on first"; return 1; }
    WANT_W=$1
    HAD_W=0
    mounted_at $HAL_T && HAD_W=1
    if [ $WANT_W = $HAD_W ]; then
        lab_write_active
        if [ $HAD_W = 1 ]; then echo "already on: watch"; else echo "no Lab test is on"; fi
        return 0
    fi
    restart_lock || return 3
    # the driver watch is a file in place before the audio server starts: one restart (the 48 kHz
    # keeper switches the new audio server's output again once music plays)
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
    lab_write_active
    [ $WANT_W = 0 ] && lab_result "off: outputs $(output_rates)"
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

# ------------------------------------------------------------------ curves on USB
#
# act.sh curves save|load <usb root> (the EQ page's Curves on USB, 0.6.11): the four user slots
# (settings/preset1..4.txt, which Easy and Expert share) to or from <usb>/EQENGINE_CURVES as
# user1..user4.txt, to keep them or to share them with other owners. A slot file is one line:
# "preamp,10 slider values" (Easy) or "x;preamp;type:frequency:gain:width;..." (Expert), in
# 0.01 dB and 0.01 Hz. Load takes a file only when it looks like that (one short line of digits,
# signs, commas, colons, semicolons and the x; a PC's line ending is allowed), and leaves alone a
# slot the stick has no file for. The files written as root get the app's owner, as the
# installer gives the settings folder's.
CURVES_DIR=EQENGINE_CURVES
# a carriage return, for a PC's line endings: the car's mksh has print but no printf (and the car
# has no printf program; 0.6.11 on the car: "printf: not found"); dash and bash have printf
CR=$(print -n '\r' 2>/dev/null)
[ ${#CR} = 1 ] || CR=$(printf '\r' 2>/dev/null)

# the owner of $1 (toolbox ls -ld: mode, owner, group ...; a PC's ls has the link count first)
owner_of() {
    set -- $(ls -ld "$1" 2>/dev/null)
    case "$2" in
        ''|*[!0-9]*) echo "$2" ;;
        *) echo "$3" ;;
    esac
}

# 0 when $1 holds one slot line; it is left in CURVE_LINE
curve_ok() {
    CURVE_LINE=""
    [ -f "$1" ] || return 1
    _cn=0
    while IFS= read -r _cx || [ -n "$_cx" ]; do
        _cx=${_cx%"$CR"}
        _cn=$((_cn + 1))
        if [ $_cn = 1 ]; then
            CURVE_LINE=$_cx
        elif [ -n "$_cx" ]; then
            return 1
        fi
    done < "$1"
    [ -n "$CURVE_LINE" ] && [ ${#CURVE_LINE} -le 1200 ] || return 1
    case "$CURVE_LINE" in
        *[!0-9x,:\;-]*) return 1 ;;
        x\;*) ;;
        *x*) return 1 ;;
    esac
    return 0
}

curves_action() {
    _cw=$1
    _cu=$2
    [ -n "$_cu" ] && [ -d "$_cu" ] || { echo "no USB stick at $_cu"; return 1; }
    _cd="$_cu/$CURVES_DIR"
    case "$_cw" in
    save)
        mkdir -p "$_cd" || { echo "cannot write to $_cd"; return 1; }
        _cnum=0
        for _ci in 1 2 3 4; do
            [ -f $D/settings/preset$_ci.txt ] || continue
            cat $D/settings/preset$_ci.txt > "$_cd/user$_ci.txt" || { echo "cannot write $_cd/user$_ci.txt (the stick may be full)"; return 1; }
            _cnum=$((_cnum + 1))
        done
        {
            echo "EQ Engine curves: User 1 to 4 as user1.txt .. user4.txt, saved $(date +%Y-%m-%d) by EQ Engine $VER."
            echo "To use them: EQ page, Curves on USB, Load from stick (it replaces User 1 to 4)."
            echo "Each file is one line: the preamp and the ten sliders, in 0.01 dB (Easy), or"
            echo "x;preamp;type:frequency:gain:width;... (Expert: type 1 peak, 2 low shelf, 3 high shelf, 4 low cut;"
            echo "frequency in 0.01 Hz, gain in 0.01 dB; width: a peak's bandwidth in 0.001 octave, a low cut's Q x 1000)."
        } > "$_cd/README.txt"
        sync
        if [ $_cnum = 0 ]; then
            echo "EQE_CURVES No user slot is saved yet, so there was nothing to copy (press and hold User 1 to 4 to save one)."
        else
            echo "EQE_CURVES Saved $_cnum of the 4 user slots to the stick ($CURVES_DIR)."
        fi
        ;;
    load)
        [ -d "$_cd" ] || { echo "the stick has no $CURVES_DIR folder (Save to stick makes one)"; return 1; }
        _cown=$(owner_of $D/settings)
        _cnum=0
        _cbad=""
        for _ci in 1 2 3 4; do
            [ -f "$_cd/user$_ci.txt" ] || continue
            if ! curve_ok "$_cd/user$_ci.txt"; then
                _cbad="${_cbad:+$_cbad, }User $_ci"
                continue
            fi
            # echo is safe here: the line holds only digits, x , : ; and - (curve_ok), and no
            # echo takes a word like "-500,..." for an option
            echo "$CURVE_LINE" > $D/settings/preset$_ci.txt.tmp || { echo "cannot write the settings folder"; return 1; }
            [ -n "$_cown" ] && chown $_cown:$_cown $D/settings/preset$_ci.txt.tmp 2>/dev/null
            chmod 600 $D/settings/preset$_ci.txt.tmp
            mv $D/settings/preset$_ci.txt.tmp $D/settings/preset$_ci.txt
            _cnum=$((_cnum + 1))
        done
        _cmsg="Loaded $_cnum curve(s) from the stick into the user slots."
        [ -n "$_cbad" ] && _cmsg="$_cmsg Left alone, not a curve file: $_cbad."
        [ $_cnum = 0 ] && [ -z "$_cbad" ] && _cmsg="The stick's $CURVES_DIR folder has no user1..user4.txt."
        echo "EQE_CURVES $_cmsg"
        ;;
    *)
        echo "usage: act.sh curves save|load <usb root>"
        return 2
        ;;
    esac
    return 0
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
    for f in $CPW_D/* $CPW_D.prev/*; do
        [ -f "$f" ] || continue
        case "$f" in
            *.bin) continue ;; # the live file (levels for the app's meter), not text
            $CPW_D.prev/*) cat "$f" > "cpw_prev_${f##*/}.txt" ;;
            *) cat "$f" > "cpw_${f##*/}.txt" ;;
        esac
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
    TOMB=$SYS/data/tombstones
    ls -l $TOMB > tombstones_list.txt 2>&1
    for t in $LAB/trace_*; do
        [ -d "$t" ] || continue
        mkdir -p "lab/${t##*/}"
        for f in "$t"/*; do
            [ -f "$f" ] && cat "$f" > "lab/${t##*/}/${f##*/}"
        done
    done
    if [ "$4" = 1 ]; then
        # Only the tombstones written since this install (act.sh is written by the install): the
        # older ones were in earlier saves. All of them are listed in tombstones_list.txt.
        REF=$D/bin/act.sh
        TN=""
        for f in $TOMB/tombstone_*; do
            [ -f "$f" ] || continue
            [ ! -f $REF ] || [ "$f" -nt $REF ] || continue
            cat "$f" > "${f##*/}.txt"
            TN="$TN ${f##*/}"
        done
        echo "copied here (written since this install of EQ Engine):${TN:- none}" >> tombstones_list.txt
        # the factory CarPlay app's libraries and their TinyALSA and mixer imports
        carplay_probe list > carplay_probe.txt 2>&1
        # the CarPlay app's process as it runs (to compare a start with the CarPlay watch, through
        # the wrap property, with a normal one): its status, personality, command line,
        # environment and maps
        _sp=$(cp_pid)
        if [ -n "$_sp" ]; then
            for f in status personality cmdline environ maps; do
                cat $PROC/$_sp/$f > "dipo_$f.txt" 2>/dev/null
            done
        fi
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
    # act.sh lab <watch 0|1>: the driver watch, in memory until the next car start.
    lab_action "$2" || exit $?
    ;;
cpwatch)
    # act.sh cpwatch <watch 0|1>: the CarPlay watch, from the next car start.
    cpwatch_action "$2" || exit $?
    ;;
cpwboot)
    # the boot step, at the car start: lays the CarPlay watch over the app's JNI library if it is on
    cpw_boot || exit 1
    ;;
cpwguard)
    cpw_guard
    ;;
keep)
    # the 48 kHz output keeper (started by the boot step); runs until EQ Engine is turned off
    keep_loop
    exit 0
    ;;
report)
    # act.sh report <usb root> <app files dir> <seconds>
    report "$2" "$3" "$4" || exit 1
    ;;
off)
    echo "turned off in the app" > $D/state/disabled
    chmod 644 $S/disabled
    setprop af.resampler.quality 0
    # the boot step notices within 5 s; make sure the overlay is gone either way
    sleep 6
    i=0
    while mounted && ours $TARGET $D/conf/audio_effects.conf && [ $i -lt 5 ]; do
        umount $TARGET
        i=$((i + 1))
        mounted && sleep 1
    done
    lab_unmount_all
    cpw_all_off
    mounted && ours $TARGET $D/conf/audio_effects.conf && { echo "the overlay could not be removed; it goes away at the next start"; exit 1; }
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
    # keep the newest 2 traces (names sort by time)
    set -- $LAB/trace_*
    while [ $# -gt 2 ]; do
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
shot)
    # A screenshot $3 seconds from now (default 5, at most 30), written by Android's screencap
    # straight to the stick ($2): nothing is kept on the head unit, and the app never loads it.
    # It shows whatever is in front by then. A hardware video layer (Android Auto's or CarPlay's
    # picture) may come out black.
    U=$2
    N=$3
    case "$N" in
        ''|*[!0-9]*) N=5 ;;
    esac
    [ $N -gt 30 ] && N=30
    [ -d "$U" ] || { echo "no USB stick at $U"; exit 1; }
    [ -x $SYS/system/bin/screencap ] || { echo "this head unit has no screencap tool"; exit 1; }
    sleep $N
    [ -d "$U" ] || { echo "the USB stick was removed"; exit 1; }
    mkdir -p "$U/EQENGINE" || { echo "cannot write to $U/EQENGINE"; exit 1; }
    F=screen_$(date +%Y%m%d_%H%M%S).png
    $SYS/system/bin/screencap -p "$U/EQENGINE/$F" 2>&1
    if [ ! -s "$U/EQENGINE/$F" ]; then
        rm -f "$U/EQENGINE/$F"
        echo "the screenshot failed"
        exit 1
    fi
    sync
    echo "EQE_SHOT EQENGINE/$F"
    ;;
curves)
    # act.sh curves save|load <usb root>: the user slots to or from the stick (see "curves on USB")
    curves_action "$2" "$3"
    _crc=$?
    [ $_crc = 0 ] || exit $_crc
    ;;
*)
    echo "usage: act.sh save|restart|conv|lab|cpwatch|cpwboot|cpwguard|keep|report|off|on|open|trace|shot|curves"
    exit 2
    ;;
esac
echo EQE_OK
exit 0
