#!/system/bin/sh
# EQ Engine postinstall (root, cwd = /data/nemesis/apps/eqengine). Always exits 0.
# Copies the filter and EQ Engine's effects list to /data/eqengine, where Android's audio server
# (user "media") can read them: /data/nemesis/apps is root-only on this unit. Each file is copied
# to a new name and then moved into place, so an audio server that already has an older copy
# loaded keeps using it safely until it restarts. A new install starts with a clean failsafe
# state (no strikes, not turned off). NEMESIS starts the boot step right after this.
#
# /data/eqengine/settings belongs to the EQ Engine app (its EQ settings and presets live there,
# and the boot step reads the converter choice from it). Settings saved by the previous version's
# uninstall step (kept in RAM under /dev, see postun.sh) are put back.

umask 022
D=/data/eqengine
SET=$D/settings
KEEP=/dev/eqengine-keep
mkdir -p $D/lib $D/conf $D/state $D/bin $SET
cp bin/act.sh $D/bin/act.sh.new && mv $D/bin/act.sh.new $D/bin/act.sh
cp bin/alsactl_dump $D/bin/alsactl_dump.new && mv $D/bin/alsactl_dump.new $D/bin/alsactl_dump
cp bin/eqe_lab $D/bin/eqe_lab.new && mv $D/bin/eqe_lab.new $D/bin/eqe_lab
# 0.6.0 had a policy-copy 48 kHz test; its files are not used any more
rm -f $D/bin/eqe_patch $D/conf/audio_policy_48k.conf
chown root:root $D/bin $D/bin/act.sh $D/bin/alsactl_dump $D/bin/eqe_lab
chmod 755 $D/bin $D/bin/act.sh $D/bin/alsactl_dump $D/bin/eqe_lab
cp lib/libeqengine.so $D/lib/libeqengine.so.new && mv $D/lib/libeqengine.so.new $D/lib/libeqengine.so
cp conf/audio_effects.conf $D/conf/audio_effects.conf.new && mv $D/conf/audio_effects.conf.new $D/conf/audio_effects.conf
# Very high quality converter tables (Lab test) and their md5 from the build: the boot step only
# uses them when the Lab switch is on and the file still matches.
cp lib/libaudio-resampler.so $D/lib/libaudio-resampler.so.new && mv $D/lib/libaudio-resampler.so.new $D/lib/libaudio-resampler.so
cp lib/libaudio-resampler.md5 $D/conf/libaudio-resampler.md5.new && mv $D/conf/libaudio-resampler.md5.new $D/conf/libaudio-resampler.md5
# Driver watch (Lab test, used only when started from the Lab) and its md5 from the build.
cp lib/eqe_drvwatch.so $D/lib/eqe_drvwatch.so.new && mv $D/lib/eqe_drvwatch.so.new $D/lib/eqe_drvwatch.so
cp lib/eqe_drvwatch.md5 $D/conf/eqe_drvwatch.md5.new && mv $D/conf/eqe_drvwatch.md5.new $D/conf/eqe_drvwatch.md5
# CarPlay watch (Lab test, used only when started from Diagnostics) and its md5 from the build. The
# factory CarPlay app reads it as its own user, so it is readable by all.
cp lib/eqe_cpwatch.so $D/lib/eqe_cpwatch.so.new && mv $D/lib/eqe_cpwatch.so.new $D/lib/eqe_cpwatch.so
cp lib/eqe_cpwatch.md5 $D/conf/eqe_cpwatch.md5.new && mv $D/conf/eqe_cpwatch.md5.new $D/conf/eqe_cpwatch.md5
chown root:root $D $D/lib $D/conf $D/state $D/lib/libeqengine.so $D/conf/audio_effects.conf \
    $D/lib/libaudio-resampler.so $D/conf/libaudio-resampler.md5 $D/lib/eqe_drvwatch.so $D/conf/eqe_drvwatch.md5 \
    $D/lib/eqe_cpwatch.so $D/conf/eqe_cpwatch.md5
chmod 755 $D $D/lib $D/conf $D/state
chmod 644 $D/lib/libeqengine.so $D/conf/audio_effects.conf $D/lib/libaudio-resampler.so $D/conf/libaudio-resampler.md5 \
    $D/lib/eqe_drvwatch.so $D/conf/eqe_drvwatch.md5 $D/lib/eqe_cpwatch.so $D/conf/eqe_cpwatch.md5
rm -f $D/state/disabled $D/state/strikes $D/state/lastboot $D/state/expected_restart $D/state/vhq_load $D/state/vhq_cut \
    $D/state/conv_cut $D/state/conv_fallback $D/state/lab_active $D/state/rate48_cut $D/state/idle48_bad
# The boot step NEMESIS starts next runs alongside an audio server that cannot load the new filter
# until it restarts: it marks that start "installed", so a car restart before it is confirmed good
# is not counted as a strike (see boot.sh).
echo installed > $D/state/fresh_install
for f in $D/state/*; do
    [ -f "$f" ] && chmod 644 "$f"
done

RESTORED=no
if [ -d $KEEP ]; then
    for f in $KEEP/*; do
        [ -f "$f" ] && cat "$f" > "$SET/${f##*/}" && RESTORED=yes
    done
    rm -rf $KEEP
fi
# Owner of the app's data folder (toolbox ls -ld: owner is the 2nd field).
OWNER=""
if [ -d /data/data/com.eqengine.app ]; then
    set -- $(ls -ld /data/data/com.eqengine.app)
    OWNER=$2
fi
if [ -n "$OWNER" ]; then
    chown $OWNER:$OWNER $SET
    for f in $SET/*; do
        [ -f "$f" ] && chown $OWNER:$OWNER "$f" && chmod 600 "$f"
    done
    chmod 700 $SET
fi
# EQ on CarPlay's music (0.7.3): the app writes its settings for the CarPlay watch here, and the
# CarPlay app (another user) reads them; without the app's owner it stays root's (no CarPlay EQ)
mkdir -p $D/share
[ -n "$OWNER" ] && chown $OWNER:$OWNER $D/share
chmod 755 $D/share
read up rest < /proc/uptime
echo "${up%%.*} installed EQ Engine 0.7.5 (settings folder owner ${OWNER:-unknown}, kept settings restored: $RESTORED)" >> $D/state/events.log
chmod 644 $D/state/events.log
# EQ on CarPlay (0.7.4) is on by default: unless the app's settings have it off, it is checked and
# prepared now for the next car start (nothing is laid over or restarted now). If that fails, the
# app says so the next time its screen opens (state/cpw_failed); a unit without the factory
# CarPlay app is simply left without it.
CPEQ=1
if [ -f $SET/current.txt ]; then
    while IFS='=' read -r k v; do
        [ "$k" = cp_eq ] && [ "$v" = 0 ] && CPEQ=0
    done < $SET/current.txt
fi
CPEQ_RES="off in the settings"
if [ $CPEQ = 1 ]; then
    EQE_CPW_NOTIFY=1 sh $D/bin/act.sh cpwatch 1 > $D/state/cpw_install.txt 2>&1 < /dev/null
    CPEQ_RES=""
    while read -r k rest; do
        [ "$k" = EQE_CPW ] && CPEQ_RES=$rest
    done < $D/state/cpw_install.txt
    chmod 644 $D/state/cpw_install.txt
fi
echo "${up%%.*} EQ on CarPlay: ${CPEQ_RES:-no answer}" >> $D/state/events.log

# Note the result on the install stick, if it is still plugged in.
for d in /mnt/media_rw/usb0 /mnt/media_rw/usb1 /mnt/media_rw/usb2 /mnt/media_rw/usb3 \
         /storage/usb0 /storage/usb1 /storage/usb2 /storage/usb3; do
    if [ -f "$d/README-EQENGINE.txt" ]; then
        mkdir -p "$d/EQENGINE" && {
            echo "EQ Engine 0.7.5 installed"
            echo "EQ on CarPlay: ${CPEQ_RES:-no answer}"
            date
            pm path com.eqengine.app
            echo "settings folder owner: ${OWNER:-unknown}; kept settings restored: $RESTORED"
            ls -l $D $D/lib $D/conf
            ls -ld $SET
        } > "$d/EQENGINE/install_ok_${up%%.*}.txt" 2>&1 < /dev/null
        break
    fi
done
sync
exit 0
