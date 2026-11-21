# EQ Engine

> [!WARNING]
> **Mostly written by AI. Use at your own risk.** The code, the measurements and this README were
> mostly written by an AI assistant. A person directed the work and tested it on one car. Tests on
> a PC and on that car have not shown problems, but this software runs inside Android's audio
> server on your head unit, and you are responsible for anything you install on your car.

EQ Engine is a [NEMESIS](https://github.com/xwtk/hmg_nemesis) package for the Gen5W head unit
(Android 4.4), which is fitted to Hyundai, Kia and Genesis cars. It works on Android's main audio
output and does two separate things:

1. **Sound quality, with no EQ needed.** It runs that output at 48 kHz instead of the factory
   44.1 kHz, so Android Auto's 48 kHz music reaches the audio hardware without being resampled.
   What still has to be resampled (Bluetooth audio, voice prompts) goes through a better converter.
2. **Tone and imaging, if you want them.** An accurate 10-band EQ whose end bands can be shelves,
   a preamp, a clip guard, a listening-position delay, and a live view of the music behind the EQ
   curve.

![The EQ page with the live view on](images/eq-live.png)

> [!IMPORTANT]
> **Android Auto only, for now.** EQ Engine processes Android Auto's music (tested over wireless;
> wired uses the same receiver and audio path) and Bluetooth audio. **CarPlay is not processed:**
> it plays exactly as it does without EQ Engine. Work on CarPlay is ongoing.

It is a plain NEMESIS package. It is **not** an HMG-API mod and does not need HMG-API (it works
alongside it).

**Current version: 0.6.6**, tested on the car below on 2026-11-20.

## Verified vehicles

| Car | Region | Audio system | Head unit software | Tested with |
|---|---|---|---|---|
| 2022 Hyundai Ioniq 5 SEL | USA | Standard (non-Bose) | 260507 (`NEEV.USA.0000.V015.012.260507`) | 0.6.6 (2026-11-20) |

No other car or software version has been tested, including Kia and Genesis cars with the same
head unit. Other cars may have a different amplifier (for example Bose), audio driver or audio
settings. The package is marked for US Ioniq 5 software (`os="NEEV.USA.*"`); on other software
NEMESIS shows it as a partial match. If you try it on another car, please send a
[car report](#reporting-a-problem).

## What it does

### 48 kHz output (on by default)

Android Auto sends its music at 48,000 samples a second, and the factory software runs Android's
main output at 44,100. On a stock car every sample is resampled, and Android 4.4's converters lose
treble doing it ([measurements](#the-converter)). EQ Engine switches the output and the hardware
link behind it to 48 kHz while the car runs:
- with Android's own run-time setting: nothing in `/system` changes and the audio server is not
  restarted for it;
- accepted only if Android, the audio driver and the rate the hardware really takes (counted by
  the kernel) all say 48,000, and checked again whenever music starts. Otherwise it goes back to
  44.1 kHz.

On the tested car the link ran at 47,995-48,004 frames a second, at the right pitch, with no
clicks. [How the switch works](#the-48-khz-switch).

### The EQ

- **10 bands**, 31 Hz to 16 kHz, ±12 dB in 0.5 dB steps. The sliders are accurate (see
  [How the EQ works](#how-the-eq-works)), and the orange line is the filter's real response.
- **Peak or shelf at the ends:** tap Peak/Shelf under the 31 Hz or 16 kHz slider. A peak lifts or
  cuts the octave around its band. A shelf also lifts or cuts everything below 31 Hz, or above
  16 kHz, and the slider still sets the level at 31 Hz or 16 kHz. It is one setting, not part of
  the presets.
- **Preamp and Auto preamp**, 13 built-in presets and four of your own (hold one to save).
- **Clip guard:** a look-ahead limiter that acts only on samples a boost would push past full
  scale. Its switch is on the EQ page and in Settings.
- **Live view:** the Live switch shows how loud each part of the range is, behind the curve, in
  time with what you hear. It is off by default and off again whenever you leave the app.
- **Output meter** that follows the music in time with what you hear.
- **EQ off is bit-exact:** the audio comes out unchanged, 1.3-1.4 ms later (the clip guard's
  look-ahead).

### Listening position

The side nearer the chosen seat is delayed, so both sides arrive there together (1.7 ms by
default; a seat offset adjusts it). Volumes stay with the car's balance and fader.

<img src="images/position.png" alt="The Position page" width="640">

### Settings, Status and Diagnostics

- **Settings:** the EQ, clip guard and 48 kHz output switches, the [converter](#the-converter)
  (Stock, High or Very high), EQ Engine on/off, Restart Android audio, and a shortcut to the car's
  own tone, fader and balance page.
- **Status:** the boot step, the filter, the output rate, processing time, levels and the log.
- **Diagnostics** (from Status): detailed logging, Save to USB (a car report for sharing, or all
  logs), Screenshot to USB (taken 5 s after the tap and written straight to the stick), a 120 s
  audio trace, and a driver watch for troubleshooting.

<img src="images/settings.png" alt="The Settings page" width="640">

<img src="images/status.png" alt="The Status page" width="640">

### What goes through it

| Source | EQ Engine's EQ | Sample rate |
|---|---|---|
| Android Auto music (wired or wireless) | yes | 48 kHz, not converted |
| Bluetooth audio (for example an iPhone) | yes | 44.1 kHz, converted up to 48 kHz (Very high) |
| Android Auto's directions voice, the car's navigation prompts | no (Android's second output) | voice converted with the converter choice |
| Phone calls (hands-free) | no | not touched |
| CarPlay | no | not touched |
| FM and SiriusXM radio | no (most likely not through Android) | not touched |

The car's own Bass, Midrange, Treble, fader and balance still work after EQ Engine. To have
EQ Engine as the only tone control, set Bass, Midrange and Treble to Center (Settings > Factory
sound settings opens that page).

## How the EQ works

**Accurate sliders.** A plain graphic EQ puts one filter on each slider, and neighbouring bands
overlap, so raising several sliders overshoots: with all ten at +6 dB a plain octave EQ is off by
up to 2.8 dB at the band centres. EQ Engine solves for the filter gains that make the response at
each band's centre match its slider (an interaction matrix, then three refinement passes). For
random settings within ±12 dB the centres are within 0.04 dB (PC tests). Sliders far apart on
neighbouring bands (25 dB or more) cannot all be matched; the curve then shows what you get.

**Bands one octave wide, all the way up.** The common filter formula makes bands narrower near
the top of the range, so the 8 kHz and 16 kHz bands were narrower than the rest and left a dip of
about 2 dB around 11-12 kHz when both were raised. The width is now corrected, and the shelves
turn over at 50 Hz and 11.3 kHz.

All ten sliders at +4 dB, at 48 kHz (calculated with the filter's own code):

| | 15 Hz | 20 Hz | 12.5 kHz | 18 kHz | 20 kHz |
|---|---|---|---|---|---|
| Earlier bands | 0.7 dB | 1.5 dB | 2.1 dB | 2.1 dB | 0.6 dB |
| Peaks now | 0.7 dB | 1.5 dB | 3.7 dB | 3.4 dB | 2.1 dB |
| Shelves | 4.1 dB | 4.1 dB | 3.6 dB | 4.0 dB | 4.0 dB |

**Clean processing.**
- Double-precision arithmetic.
- Your boosts are handled in three stages: the preamp makes room, the clip guard catches what
  still goes over full scale, and TPDF dither is added only to samples that were changed.
- Changes are click-free: filter settings glide over 1024 samples, and EQ on/off crossfades.
- EQ off switches to a bit-exact path.
- Clipping already in the music cannot be undone: those samples arrive flat-topped, and Status
  counts them as "Arrived clipped".

**Light on the head unit** (measured on the car):
- 0.4-0.5% of one core with a flat EQ, against 2.3% before 0.6.6.
- With the EQ in use it does about 30% less work than before, and about half while the clip
  guard limits (PC measurement).
- The live view, a 4096-point FFT of the output in 48 bands about 22 times a second, adds about
  1.5% of one core while the EQ page shows it. It is shown when that audio reaches the speakers,
  about 0.15 s after the filter sees it.

## The 48 kHz switch

- The factory driver ignores the rate asked for when an output opens, but follows Android's
  run-time `sampling_rate` setting while its stream is active.
- **While nothing plays** (at a car start or after an audio restart), a small helper plays a few
  seconds of silence so the link runs. It asks for no audio focus, so nothing is paused or
  ducked. EQ Engine switches during it, and the music then starts at 48 kHz with no gap.
- **While music plays**, it switches at once, with one short gap.
- **Android 4.4 can leave audio tracks on a freed buffer** at a rate change, which can silence
  them. For every change EQ Engine holds each audio session of the main output with a disabled
  copy of its filter, so Android moves its tracks along, then checks every track's buffer.
  Without the hold, no change is made.
- **Fallbacks:**
  - a switch the link does not follow is put back within about 3 s;
  - anything that disagrees goes back to 44.1 kHz;
  - an audio server crash within 20 s of a switch turns the setting off;
  - EQ Engine never restarts the audio server for this, and does not switch while another app is
    playing to the speaker link directly.

## The converter

The converter choice (Settings) applies to what Android still converts:
- Bluetooth audio while the output is at 48 kHz;
- voice and navigation prompts;
- Android Auto's music whenever the output is at 44.1 kHz.

Measured with Android 4.4's own converter code on a PC, relative to each converter's gain:

| Converter | 48 → 44.1 kHz, at 16 / 20 kHz | 44.1 → 48 kHz, at 16 / 20 kHz | 16 → 44.1 kHz, at 7 kHz |
|---|---|---|---|
| Stock (Android's default) | -3.3 / -5.3 dB (calculated) | not measured | not measured |
| High | -3.5 / -16.7 dB | -1.2 / -10.0 dB | -7.45 dB |
| **Very high** (default) | 0.0 / 0.0 dB | 0.0 / -3.2 dB | -0.28 dB |

- **Very high** is Android's very-high-quality converter with EQ Engine's own filter tables (a
  Kaiser-windowed sinc, 40 taps a side, 512 phases).
- **Noise and aliasing:** -87 dB or lower up to 20 kHz, against about -72 dB (48 to 44.1) and
  -30 dB (44.1 to 48) with High near 19-20 kHz.
- **Headroom:** the tables have -1.6 dB of gain, so the conversion cannot overflow. In the car's
  logs, High let 588-1664 clipped samples through per 30 s of music; Very high let none.
- **Cost:** about 1.6% more of one core than High, on the car.
- **Fallbacks:** if the tables fail their checksum, Android uses High, bit for bit. Each
  unexpected audio server restart steps the choice down one level and keeps it.

## Using it for 48 kHz only

Switch the EQ off (EQ page, or Settings > Equalizer). The filter then passes the audio through
bit-exact, while the 48 kHz output and the converter work as before. Leave Settings > 48 kHz
output on and the converter on Very high (both defaults), and keep Settings > EQ Engine on (it is
the master switch). Status > Output should say "48 kHz, unconverted" while Android Auto plays.

## Does it change system files?

**No. EQ Engine writes nothing to `/system` and leaves nothing behind outside its own files.**
- Two system files are covered in memory, never changed: `/system/etc/audio_effects.conf` (to add
  EQ Engine's filter to Android's list) and, only while the driver watch is on,
  `/system/lib/hw/audio.primary.tcc803x.so`. Both are bind mounts that end at the next restart or
  when EQ Engine is turned off.
- The 48 kHz rate and Android's converter property last only until the head unit restarts; EQ
  Engine sets them again at every start while it is on.
- Its own files are the app and `/data/eqengine`; uninstalling removes them.
- Nothing is sent to the car's audio controller or amplifier.

## Upsides and downsides

**Upsides**
- No resampling of Android Auto's music, and better conversion for what is still converted.
- An accurate EQ, and bit-exact when it is off.
- Light on the head unit, and nothing written to `/system`.
- The car's own volume, balance, fader and tone controls keep working.

**Downsides and limits**
- **Android Auto only for now.** CarPlay is not processed; navigation prompts and calls are not
  EQ'd.
- **A short gap** when the rate changes while music already plays (after an audio restart, or
  when 48 kHz output is turned on or off).
- **About 1.6 dB louder at 48 kHz:** nothing is converted, so loud music reaches full scale.
  With EQ boosts, use the preamp or Auto preamp.
- **44.1 kHz sources are converted up**, for example Bluetooth audio: flat to 19 kHz, down 3.2 dB at
  20 kHz. With 48 kHz output off, Bluetooth plays unconverted and Android Auto is converted
  instead.
- **The amplifier side cannot be seen.** Whether the car's amplifier converts internally cannot be
  seen from Android.
- **Sometimes not loaded after a car start.** If Android's audio server reads its effects list
  before EQ Engine's boot step, EQ Engine is not loaded for that start; the app says so. Restart
  Android audio once (Settings, parked). EQ Engine never does that by itself (see the next point).
- **Audio restarts are tied to the rear camera.** The factory software runs the rear camera
  service in the same process as the audio server. Audio restarts (Settings > Restart Android
  audio, a converter change, the driver watch) happen only when you ask: do them parked, never
  while reversing.
- **One car tested, mostly written by AI.** See the warning above and
  [Verified vehicles](#verified-vehicles).

## Install

### Before you start

- **NEMESIS** must be installed on the head unit. Its
  [README](https://github.com/xwtk/hmg_nemesis#readme) covers that. EQ Engine needs nothing else.
- Get `eqengine-stick-<version>.zip` and `eqengine-rescue-stick-<version>.zip` (the same version)
  from [Releases](https://github.com/alexkozler/Gen5W-EQ-Engine/releases), or build them
  ([Building from source](#building-from-source)).
- Use one or two blank USB sticks formatted exFAT or FAT32.
- Do this **parked**. Installing restarts Android's audio, which gives a few seconds of silence.
  The rear camera service runs in the same Android process, so never do it while reversing.

### Steps

1. **Make the rescue stick first.** Unzip `eqengine-rescue-stick-<version>.zip` onto the top level
   of its own USB stick. Keep it in the glovebox, not plugged in. It turns EQ Engine off even when
   Android does not come up ([Rescue stick](#rescue-stick)).
2. **Make the install stick.** Unzip `eqengine-stick-<version>.zip` onto the top level of the other
   stick. `NEMESIS.data`, `README-EQENGINE.txt`, `packages/` and `EQENGINE-source/` must be at the
   root of the stick, not inside a folder.
3. With the car on and Android running, plug the install stick into the head unit's USB port.
4. Confirm the install when NEMESIS asks. Wait for "Operation completed successfully".
5. Remove the stick and restart the car. Android's audio server loads EQ Engine's filter when it
   starts.
6. Open EQ Engine from NEMESIS Manager > My Packages > EQ Engine > Launch. Play some music. On
   the Status page, the Output tile should show "48 kHz, unconverted" within about 10 s.

If NEMESIS Manager shows "Warning: Activity not started, its current task has been brought to the
front", EQ Engine was already running: that is the output of Android's `am start` command, and EQ
Engine opens normally.

The install also writes a diagnostic report and a 40-second system log to an `EQENGINE/` folder
on the install stick. That log can contain personal data ([Reporting a problem](#reporting-a-problem)).

## Updating

Install the new version the same way, over the old one. NEMESIS asks "Updating EQ Engine requires
reinstalling": answer Yes, wait for "Operation completed successfully", then restart the car.

- Your EQ settings and presets are kept. Detailed logging is switched off by every update.
- Until the restart, Android's audio server still has the old filter loaded. The EQ keeps working;
  features that need the new filter (in 0.6.6: Peak/Shelf and the live view) say so and work after
  the restart.
- An update must be signed with the same key as the installed app. A build signed with another key
  will not install over it; uninstall first.

After a **head unit software update**, EQ Engine checks Android's effects list at every start. If
the update changed that file, EQ Engine does not apply itself, the audio stays stock, and the
Status page says why.

## Turning it off and uninstalling

- **Off, but still installed:** Settings > EQ Engine off. Audio is completely stock from the next
  start. Turn it back on in the same place.
- **Uninstall:** NEMESIS Manager > My Packages > EQ Engine > Uninstall, then restart the car. The
  uninstall step turns the boot step and the 48 kHz output off, removes the in-memory overlay and
  the driver watch, and sets Android's converter back to its default. NEMESIS then removes the app
  and `/data/eqengine`, including your settings and presets. Changes made on the car's own sound
  page are car settings: change them back on that page.

### Rescue stick

Use it only if something is wrong and you cannot reach the EQ Engine app or NEMESIS Manager.

- **Android running:** plug the stick in and answer Yes.
- **Android not coming up:** plug it in. NEMESIS runs it without asking, because the stick holds a
  `NEMESIS.emergency` file.

Then restart the car. The rescue stick turns EQ Engine off, removes its in-memory changes and the
driver watch, resets the converter, and writes a report to `EQENGINE-RESCUE/` on the stick. EQ
Engine stays off until you turn it back on in the app, or uninstall it.

## Safety and failsafes

- **Firmware check:** the overlay is applied only if Android's effects list is byte for byte the
  one the package was built for. The driver watch checks the factory driver the same way.
- **Loaded check:** at every start the boot step checks that the audio server has EQ Engine's
  filter loaded, and says so if it does not.
- **Two-strike rule:** two starts in a row that are never confirmed good turn EQ Engine off.
- **Crash watch:** unexpected audio server restarts, twice within 60 s or three times in one start,
  turn EQ Engine off.
- **Audio restarts** happen only when you ask, one at a time and at least 10 s apart, each followed
  by a check that Android Auto's music plays again.
- **Ways back:** Settings > EQ Engine off, uninstall, the rescue stick, or a car restart (for the
  driver watch).

## Reporting a problem

Status > Diagnostics > Save to USB has two buttons.

- **Report** makes the car report: one text file in the `EQENGINE` folder on the stick. Play some
  music first; it records 30 s of the audio system's log and measures the hardware link.
  - It holds: the head unit's model and software, a list of checks, the sound hardware and its
    rates, which apps play at what rate, and EQ Engine's own logs.
  - Lines that could carry Bluetooth names or addresses, song details, a location, serial numbers
    or a VIN are left out, and the car maker's files are not copied (only their checksums).
  - Read it before you post it anywhere public, for example in a GitHub issue.
- **All logs** saves everything for debugging, including the full system log. It contains your
  phone's name, Bluetooth addresses, song titles and possibly navigation details: share it only
  privately, and only when asked.

## Building from source

The build runs on Linux x86_64, on Windows with WSL, or in Docker. It was built and tested on Ubuntu
24.04 with OpenJDK 21.

**With Docker** (Windows or macOS): `tools/build-env/Dockerfile` has everything except the NDK.
Keep the NDK in a Docker volume:

```sh
docker build -t eqengine-build tools/build-env
docker volume create eqengine-ndk
docker run --rm -v eqengine-ndk:/opt/ndk eqengine-build sh -c 'cd /opt/ndk && curl -sSLO https://dl.google.com/android/repository/android-ndk-r25c-linux.zip && echo "53af80a1cce9144025b81c78c8cd556bff42bd0e  android-ndk-r25c-linux.zip" | sha1sum -c - && unzip -q android-ndk-r25c-linux.zip && rm android-ndk-r25c-linux.zip'
docker run --rm -v "$PWD:/src" -v eqengine-ndk:/opt/ndk eqengine-build sh build.sh
```

The checksum is Google's published SHA-1 for that file. Run the tests below the same way, with
`bash -c '...'` after `eqengine-build`.

**What it needs:**
- The Android NDK r25c for Linux (`NDK=`, default `~/ndk/android-ndk-r25c`) and a JDK (`javac`,
  `keytool`).
- python3 with numpy, unicorn and Pillow; gcc with AddressSanitizer; zip, unzip, git, dash and
  mksh.
- `devtools/` (not in git): aapt2 8.13.2, `android-4.1.1.4.jar`, r8 8.13.25 and apksig 8.13.2.
- `car-files/` (not in git): `framework-res.apk`, `audio_effects.conf`, `audio_policy.conf` and
  `audio.primary.tcc803x.so`, copied from your own head unit. They are the car maker's files: never
  commit or publish them. The app is linked against the car's `framework-res.apk`, and the tests
  use the others.
- `keys/eqengine.keystore` (not in git): the app's signing key. `build.sh` stops if it is missing.
  `EQE_NEW_KEY=1` makes a new one, but an app signed with a new key cannot update one signed with
  another.

`EQE_TOOLS` and `EQE_CAR` can point to `devtools/` and `car-files/` elsewhere. The stick zips are
named with the version from `pkg/NEMESIS.data`; the build stops if any other file says otherwise.

```sh
sh build.sh                                   # native code, app, package and the stick zips
for s in dash bash mksh; do bash tests/boot/run.sh $s; bash tests/act/run.sh $s; done
bash vhq/host/run.sh 40 9                     # converter tables against Android's converter code
gcc -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -I tests -I native \
    -o tests/host_test tests/host_test.c -lm -ldl -lpthread && ./tests/host_test   # after vhq/host
sh native/drvtest/run.sh                      # driver watch against a stand-in driver
bash tests/lab/run.sh                         # eqe_lab: link rates, Android's settings, symbol tables
python3 native/drvtest/tramp_test.py native/out/eqe_drvwatch.so \
    $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf native/drvwatch_exports.txt
python3 tests/meta/check_meta.py pkg/NEMESIS.data
```

**Shell scripts** run on the head unit's `/system/bin/sh` (mksh) with toolbox only, so they use
shell builtins rather than grep, sed, awk, head or tail. The tests run them under dash, bash and
mksh.

## Repository layout

| Path | What |
|---|---|
| `native/eqengine.c` | the audio filter, loaded by Android's audio server |
| `vhq/` | EQ Engine's converter tables: the design script, the generated tables and their tests |
| `native/eqe_lab.c` | root helper: the links' real rate, Android's run-time settings, symbol tables for the report |
| `native/drvwatch.c`, `native/gen_tramp.py` | the driver watch |
| `native/aosp44/`, `third_party/aosp-af/` | Android 4.4.2 headers and audio code, for building and testing |
| `pkg/` | the NEMESIS package: `NEMESIS.data`, the boot step (`bin/boot.sh`), the app's root actions and the 48 kHz keeper (`bin/act.sh`), install scripts, and the effects list overlay |
| `app/` | the Android app (Java, no Gradle), and `Hold.java`, the 48 kHz switch's helper |
| `rescue/` | the rescue stick |
| `stick/README-EQENGINE.txt` | the README that goes on the install stick |
| `tests/` | boot step, actions, filter, effects-list parsing and package metadata tests |
| `tools/` | the signing helper, a mockup renderer for the app's pages, and the Docker build environment |
| `images/` | screenshots for this README |

## License and credits

No license has been chosen for EQ Engine's own code yet.

Files in `third_party/aosp-af/`, `native/aosp44/`, `native/fx44.h` and `tests/conf/` come from or
follow the Android Open Source Project, under the Apache License 2.0 (see each file's header).

EQ Engine relies on [NEMESIS](https://github.com/xwtk/hmg_nemesis) by xwtk. The Gen5W community's
work, including [HMG-API](https://github.com/Open-HMG/HMG-API), was background reading for it.
