#!/bin/sh
# Builds EQ Engine stage 1: the native filter, the test app, the NEMESIS package and both sticks.
# Toolchain: Android NDK r25c, javac (API 16 stubs), d8, aapt2 linked against the car's own
# framework-res.apk, Google's apksig (v1 signature, min SDK 9, like the HMG-API app).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
# Build tools (devtools/, not in git: see README.md) and files copied from the car (car-files/,
# not in git: Hyundai's, never published). Both can be moved with EQE_TOOLS and EQE_CAR.
T=${EQE_TOOLS:-$HERE/devtools}
CAR=${EQE_CAR:-$HERE/car-files}
ANDROID_JAR=$T/android-4.1.1.4.jar
FRAMEWORK_RES=$CAR/framework-res.apk
JDK_HOME=$(dirname "$(dirname "$(readlink -f "$(which javac)")")")
D8="java -cp $T/r8-8.13.25.jar com.android.tools.r8.D8"
AAPT2=$T/aapt2/aapt2
APKSIG="$T/apksig-8.13.2.jar:$HERE/build/apktool"
KEYS=$HERE/keys
# The version, from the package. Every other place that carries it must say the same, or the build
# stops before it deletes anything. The stick zips are named with it.
VER=$(sed -n 's/^package-version=//p' "$HERE/pkg/NEMESIS.data")
[ -n "$VER" ] || { echo "no package-version in pkg/NEMESIS.data"; exit 1; }
# Reproducible zips (after 0.7.6): every file put in a zip (the APK too) gets one fixed time,
# SOURCE_DATE_EPOCH if set, else 2020-01-01 00:00 UTC, so the same source gives the same bytes
# wherever it is built: the package built from a release tag is then byte for byte the one tested.
# zip stores local time, so UTC.
EPOCH=${SOURCE_DATE_EPOCH:-1577836800}
export TZ=UTC
stamp() { find "$@" -exec touch -h -d "@$EPOCH" {} + ; }
for chk in \
    "app/src/com/eqengine/app/MainActivity.java:static final String VERSION = \"$VER\";" \
    "app/AndroidManifest.xml:android:versionName=\"$VER\"" \
    "pkg/bin/act.sh:VER=$VER" \
    "pkg/bin/boot.sh:VER=$VER" \
    "pkg/scripts/pre.sh:EQ Engine $VER preinstall" \
    "pkg/scripts/post.sh:EQ Engine $VER installed" \
    "stick/README-EQENGINE.txt:EQ Engine $VER (NEMESIS package"; do
    f=${chk%%:*}
    want=${chk#*:}
    grep -qF "$want" "$HERE/$f" || { echo "version mismatch: $f does not have '$want' (pkg/NEMESIS.data says $VER)"; exit 1; }
done
B=$HERE/build
rm -rf "$B"
mkdir -p "$B/classes" "$B/dex" "$B/res" "$B/apktool"

echo "== native filter"
sh "$HERE/native/build.sh"

echo "== app"
$AAPT2 compile --dir "$HERE/app/res" -o "$B/res/res.zip"
$AAPT2 link -I "$FRAMEWORK_RES" --manifest "$HERE/app/AndroidManifest.xml" \
    --min-sdk-version 19 --target-sdk-version 19 --no-auto-version -o "$B/res.apk" "$B/res/res.zip"
javac --release 8 -Xlint:-options -cp "$ANDROID_JAR" -d "$B/classes" $(find "$HERE/app/src" -name '*.java' | sort)
$D8 --min-api 19 --release --lib "$ANDROID_JAR" --lib "$JDK_HOME" --output "$B/dex" $(find "$B/classes" -name '*.class' | sort)
cp "$B/res.apk" "$B/unsigned.apk"
stamp "$B/dex"
(cd "$B/dex" && zip -q -X "$B/unsigned.apk" classes.dex)
# The app must keep its signing key, or updates will not install over the app on the car.
if [ ! -f "$KEYS/eqengine.keystore" ] && [ "${EQE_NEW_KEY:-}" != 1 ]; then
    echo "keys/eqengine.keystore is missing. Restore it (see README.md, Building from source); EQE_NEW_KEY=1 makes a new one." >&2
    exit 1
fi
if [ ! -f "$KEYS/eqengine.keystore" ]; then
    mkdir -p "$KEYS"
    keytool -genkeypair -keystore "$KEYS/eqengine.keystore" -alias eqengine -keyalg RSA -keysize 2048 \
        -validity 10000 -storepass eqengine -keypass eqengine -dname 'CN=EQ Engine,O=EQ Engine,C=US' 2>/dev/null
fi
javac --release 8 -Xlint:-options -cp "$T/apksig-8.13.2.jar" -d "$B/apktool" "$HERE/tools/apktool/ApkTool.java"
java -cp "$APKSIG" ApkTool sign "$B/unsigned.apk" "$B/EQEngine.apk" "$KEYS/eqengine.keystore" eqengine eqengine 9
java -cp "$APKSIG" ApkTool verify "$B/EQEngine.apk" 19

echo "== package"
P=$B/pkg
mkdir -p "$P/app" "$P/lib" "$P/conf" "$P/bin" "$P/scripts"
cp "$HERE/pkg/NEMESIS.data" "$P/"
# NEMESIS refuses a package whose NEMESIS.data breaks its rules (for example a description over 256
# characters) before running anything; check with the same rules here.
python3 "$HERE/tests/meta/check_meta.py" "$P/NEMESIS.data"
cp "$B/EQEngine.apk" "$P/app/"
cp "$HERE/native/out/libeqengine.so" "$HERE/native/out/libaudio-resampler.so" "$HERE/native/out/eqe_drvwatch.so" \
    "$HERE/native/out/eqe_cpwatch.so" "$P/lib/"
set -- $(md5sum "$HERE/native/out/libaudio-resampler.so")
echo "$1" > "$P/lib/libaudio-resampler.md5"
set -- $(md5sum "$HERE/native/out/eqe_drvwatch.so")
echo "$1" > "$P/lib/eqe_drvwatch.md5"
set -- $(md5sum "$HERE/native/out/eqe_cpwatch.so")
echo "$1" > "$P/lib/eqe_cpwatch.md5"
cp "$HERE/pkg/conf/audio_effects.conf" "$P/conf/"
# the package icon (descriptor 1.2 favicon; tools/icon/make_favicon.py draws it): NEMESIS shows the
# generic icon for anything but a PNG or JPEG of at most 256 KiB
cp "$HERE/pkg/favicon.png" "$P/"
[ $(stat -c %s "$P/favicon.png") -le 262144 ] || { echo "pkg/favicon.png is over 256 KiB"; exit 1; }
[ "$(head -c 8 "$P/favicon.png" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ] || { echo "pkg/favicon.png is not a PNG"; exit 1; }
cp "$HERE/pkg/bin/boot.sh" "$HERE/pkg/bin/act.sh" "$HERE/native/out/alsactl_dump" "$HERE/native/out/eqe_lab" "$P/bin/"
cp "$HERE/pkg/scripts/"*.sh "$P/scripts/"
# modes set here, not taken from the checkout (a Windows mount shows every file as 777)
find "$P" -type d -exec chmod 755 {} +
find "$P" -type f -exec chmod 644 {} +
chmod 755 "$P/bin/"* "$P/scripts/"*.sh
stamp "$P"
S=$B/stick
mkdir -p "$S/packages"
# in a sorted order (zip -r takes the filesystem's), NEMESIS.data first
(cd "$P" && { echo NEMESIS.data; find favicon.png app lib conf bin scripts -type f | LC_ALL=C sort; } | zip -q -X -D -@ "$S/packages/eqengine.zip")
printf '[nemesis]\nversion=1.0\ntype=install\npath=packages/eqengine.zip\n' > "$S/NEMESIS.data"
cp "$HERE/stick/README-EQENGINE.txt" "$S/"
mkdir -p "$S/EQENGINE-source"
cp -r "$HERE/native" "$S/EQENGINE-source/"
rm -rf "$S/EQENGINE-source/native/out"
cp -r "$HERE/app" "$HERE/pkg" "$HERE/rescue" "$HERE/tests" "$HERE/vhq" "$HERE/third_party" "$HERE/tools" \
    "$HERE/build.sh" "$S/EQENGINE-source/"
rm -f "$S/EQENGINE-source/tests/host_test" "$S/EQENGINE-source/tests/conf/parse"
rm -f "$S/EQENGINE-source/vhq/neon/"*.o "$S/EQENGINE-source/vhq/neon/"*.elf "$S/EQENGINE-source/vhq/neon/"*.bin
rm -f "$HERE"/eqengine-stick*.zip "$HERE"/eqengine-rescue-stick*.zip "$HERE"/eqengine-[0-9]*.zip
# the package on its own, for the NEMESIS Package Store (the portal takes the zip with NEMESIS.data
# at its root; it names downloads <id>-<version>.zip)
cp "$S/packages/eqengine.zip" "$HERE/eqengine-$VER.zip"
stamp "$S"
(cd "$S" && { echo NEMESIS.data; find README-EQENGINE.txt packages EQENGINE-source -type f | LC_ALL=C sort; } | zip -q -X -D -@ "$HERE/eqengine-stick-$VER.zip")
rm -rf "$B/rescue"; mkdir -p "$B/rescue"
cp "$HERE/rescue/NEMESIS.data" "$HERE/rescue/NEMESIS.emergency" "$HERE/rescue/eqengine-off.sh" "$HERE/rescue/README-RESCUE.txt" "$B/rescue/"
chmod 644 "$B/rescue/"*
stamp "$B/rescue"
(cd "$B/rescue" && zip -q -X -D -r "$HERE/eqengine-rescue-stick-$VER.zip" NEMESIS.data NEMESIS.emergency eqengine-off.sh README-RESCUE.txt)
echo "built $HERE/eqengine-stick-$VER.zip, $HERE/eqengine-$VER.zip (the package, for the store) and $HERE/eqengine-rescue-stick-$VER.zip"
