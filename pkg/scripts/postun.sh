#!/system/bin/sh
# EQ Engine postuninstall (root). Deletes EQ Engine's files. Always exits 0.
# NEMESIS also runs this when updating EQ Engine (old version out, new version in), so the EQ
# settings and presets are first copied to /dev/eqengine-keep. /dev is in RAM: the next version's
# postinstall restores them, and after a plain uninstall they are gone at the next restart.
if [ -d /data/eqengine/settings ]; then
    rm -rf /dev/eqengine-keep
    mkdir -p /dev/eqengine-keep && chmod 700 /dev/eqengine-keep
    for f in /data/eqengine/settings/*; do
        [ -f "$f" ] && cat "$f" > "/dev/eqengine-keep/${f##*/}"
    done
fi
rm -rf /data/eqengine
# The boot step's NEMESIS service log (NEMESIS itself leaves it behind).
rm -rf /data/nemesis/logs/eqengine
exit 0
