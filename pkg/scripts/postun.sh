#!/system/bin/sh
# EQ Engine postuninstall (root). Deletes EQ Engine's files. Always exits 0.
# NEMESIS also runs this when updating EQ Engine (old version out, new version in), so the EQ
# settings and presets are first copied somewhere the next version's postinstall restores them
# from:
# - during an update (NEMESIS has the new version unpacked in its staging folder, after 0.7.6):
#   /data/eqengine-keep, on flash, so a power cut between the two versions loses nothing. The
#   new version's postinstall restores and deletes it;
# - otherwise (a plain uninstall): /dev/eqengine-keep, in RAM, so a reinstall in the same car start
#   gets them back and nothing is left once the head unit restarts.

# Tests (tests/install/run.sh) point the paths at a simulated unit; on the car R is empty.
R=${EQE_TEST_ROOT:-}
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
KEEP=$R/dev/eqengine-keep
is_update && KEEP=$R/data/eqengine-keep
if [ -d $R/data/eqengine/settings ]; then
    rm -rf $R/dev/eqengine-keep $R/data/eqengine-keep
    mkdir -p $KEEP && chmod 700 $KEEP
    for f in $R/data/eqengine/settings/*; do
        [ -f "$f" ] && cat "$f" > "$KEEP/${f##*/}"
    done
    sync
fi
rm -rf $R/data/eqengine
# The boot step's NEMESIS service log (NEMESIS itself leaves it behind).
rm -rf $R/data/nemesis/logs/eqengine
exit 0
