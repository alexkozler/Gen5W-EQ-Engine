#!/system/bin/sh
# EQ Engine preinstall (runs as root before NEMESIS calls pm install). Always exits 0.
#
# 1. Lets Android's package reader reach the apk. NEMESIS creates /data/nemesis/apps with
#    mkdir(..., 0755) but never forces the mode, and on this unit it ended up 0700 (root only).
#    pm hands the file to com.android.defcontainer, which runs as an app user, can't get in,
#    and logs "Failed to parse package". If (and only if) the folder is exactly 0700, this
#    sets it to 0711 (enter a known path; no listing, no writing) and puts 0700 back after 40 s.
#    pm copies the apk into /data/app, so the original path isn't needed after the install.
# 2. Saves install diagnostics to EQENGINE/ on this USB stick and records the system log for
#    40 seconds, so the package manager's full reason is kept if pm refuses the app. That log
#    holds personal data (phone names, Bluetooth addresses, songs): after a successful install
#    postinstall stops it and deletes it (/dev/eqengine-install-log says which), so it stays on
#    the stick only when the install failed.

# Tests (tests/install/run.sh) point the paths at a simulated unit; on the car R is empty.
R=${EQE_TEST_ROOT:-}
APPS=$R/data/nemesis/apps
OPENED=""
# (an earlier install's note, if its postinstall never ran: never acted on)
rm -f $R/dev/eqengine-install-log
set -- $(ls -ld "$APPS" 2>/dev/null)
WAS="$1"
if [ "$WAS" = "drwx------" ]; then
    chmod 711 "$APPS" && OPENED=1
fi

U=""
for d in $R/mnt/media_rw/usb0 $R/mnt/media_rw/usb1 $R/mnt/media_rw/usb2 $R/mnt/media_rw/usb3 \
         $R/storage/usb0 $R/storage/usb1 $R/storage/usb2 $R/storage/usb3; do
    if [ -f "$d/README-EQENGINE.txt" ]; then
        U="$d"
        break
    fi
done

LP=""
if [ -n "$U" ] && mkdir -p "$U/EQENGINE" 2>/dev/null; then
    O="$U/EQENGINE"
    read up rest < /proc/uptime
    T="${up%%.*}"
    {
        echo "EQ Engine 0.7.7 preinstall"
        date
        id
        echo "product=$(getprop ro.build.product) sdk=$(getprop ro.build.version.sdk) boot_completed=$(getprop sys.boot_completed)"
        echo "selinux: $(getenforce 2>&1)"
        echo "apps folder was: $WAS   opened for this install (0711): ${OPENED:-no}"
        echo "--- staged package ($PWD)"
        ls -l "$PWD" "$PWD/app" 2>&1
        echo "--- folders pm reads through"
        ls -ld /data /data/nemesis "$APPS" 2>&1
        echo "--- free space"
        df /data 2>&1
        echo "--- already installed?"
        pm path com.eqengine.app 2>&1
    } > "$O/install_${T}.txt" 2>&1 < /dev/null
    logcat -v time -f "$O/logcat_install_${T}.txt" < /dev/null > /dev/null 2>&1 &
    LP=$!
    # for postinstall: "<pid> <file>" (in RAM, gone at the next restart)
    echo "$LP $O/logcat_install_${T}.txt" > $R/dev/eqengine-install-log
fi

# After 40 s: stop the log capture and put the folder back the way it was.
( sleep 40
  # only that logcat (postinstall may have stopped it already, and its pid used again since)
  if [ -n "$LP" ] && [ -f /proc/$LP/cmdline ]; then
    LC=""
    read -r LC < /proc/$LP/cmdline
    case "$LC" in
      *logcat*logcat_install_${T}.txt*) kill $LP ;;
    esac
  fi
  [ -n "$OPENED" ] && chmod 700 "$APPS"
  sync ) < /dev/null > /dev/null 2>&1 &
sync
exit 0
