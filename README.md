# EQ Engine

> [!WARNING]
> **Mostly written by AI. Use at your own risk.** The code, the measurements and this README were
> mostly written by an AI assistant. A person directed the work and tested it
> on one car. Tests on a PC and on that car have not shown problems, but this software runs inside
> Android's audio server on your head unit, and you are responsible for anything you install on
> your car.

A [NEMESIS](https://github.com/xwtk/hmg_nemesis) package for Hyundai's Gen5W head unit (Android
4.4). It adds a 10-band EQ, a clip guard and a listening-position delay to Android's main audio
output, where Android Auto's music plays. It also picks the audio converter Android uses to turn
Android Auto's 48 kHz music into the 44.1 kHz the head unit runs at. By default this is Android's
very-high-quality converter with EQ Engine's own filter tables, which keep the treble flat to
20 kHz.

It is a plain NEMESIS package. It is **not** an HMG-API mod and does not need HMG-API.

## Status

**0.6.1** is built but **not yet tested on a car**.

**0.6.0** was tested on the car below on 2026-11-19:
- The EQ and the Very high converter worked, and the converter status after a car start was right.
- Its Lab test "48 kHz output" showed that Hyundai's driver ignores the rate Android asks for when
  an output opens: the driver kept 44.1 kHz, and the test removed itself as designed.
- Its "Driver watch" did not report output streams. Hyundai's driver orders its function table
  differently from Android 4.4's, so the watch's hooks were one position off from `set_parameters`
  on. Audio was not affected.

**0.6.1** changes:
- The 48 kHz test uses the driver's run-time rate switch, through Android's own setting.
- The driver watch is rebuilt for Hyundai's table and measures the real link rate from the
  kernel's counters.
- The first start after an install no longer counts against the failsafe.

## Verified vehicles

| Car | Region | Audio system | Head unit software | Tested versions |
|---|---|---|---|---|
| 2022 Hyundai Ioniq 5 SEL | USA | Standard (non-Bose) | 260507 (`NEEV.USA.0000.V015.012.260507`) | 0.1.0 to 0.6.0 |

No other car or software version has been tested. Other cars may have a different amplifier (for
example Bose), audio driver or audio settings. The package is marked for US Ioniq 5 software
(`os="NEEV.USA.*"`). On other software NEMESIS shows it as only a partial match.

## What it does

- **10-band EQ** at 31 Hz to 16 kHz, one octave apart, ±15 dB per slider. The sliders are
  accurate: neighbouring bands overlap, so EQ Engine solves for the band gains that make the
  response at each band's centre match its slider. The orange line on the EQ page is the real
  response.
- **Preamp and Auto preamp**, which make room for boosts. **Presets** (Flat, Rock, Pop, Jazz,
  Classical, EDM, Hip-Hop, Acoustic, Vocal, Speech, Bass boost, Treble boost, Loudness) and your
  own presets.
- **Clip guard**, a look-ahead limiter that acts only on samples a boost would push past full
  scale.
- **Listening position**: Driver, Center, Passenger or anything between. EQ Engine delays the
  side nearer that seat so both sides arrive together there. This centres the sound for that
  seat; volumes stay with the car's balance and fader.
- **Audio converter choice**: Stock, High or Very high (the default). See
  [How it works](#how-it-works).
- **Lab**: Hyundai's own, partly hidden, sound pages; the converter choice; two driver tests
  (48 kHz output, Driver watch); and a 120 s audio trace.
- **Status page** and **Save logs to USB**.
- **Turning it off is bit-exact.** With the EQ switch off, the audio comes out unchanged, only
  1.4 ms later (the clip guard's look-ahead).

**What it processes**: Android's main output. That covers Android Auto's music and other media
Android plays there.

**What it does not touch:**
- Navigation guidance and Android Auto's directions voice, which use a second output. The
  converter choice still applies to them (see below).
- FM radio. It most likely goes to the amplifier without passing through Android; this has not
  been confirmed.
- Hyundai's own Bass, Mid, Treble, fader and balance. They are applied after Android, in the
  car's amplifier, and add to EQ Engine's EQ.

## Install

### Before you start

- **NEMESIS** must be installed on the head unit. Its
  [README](https://github.com/xwtk/hmg_nemesis#readme) covers that. EQ Engine needs nothing else.
- Get `eqengine-stick.zip` and `eqengine-rescue-stick.zip`, either from this repository's
  [Releases](https://github.com/alexkozler/Gen5W-EQ-Engine/releases) or by building them
  ([Building from source](#building-from-source)).
- Use one or two blank USB sticks formatted exFAT or FAT32.
- Do this **parked**. Installing and testing restart Android's audio, which gives a few seconds of
  silence. The rear camera service runs in the same Android process, so never do it while
  reversing.

### Steps

1. **Make the rescue stick first.** Unzip `eqengine-rescue-stick.zip` onto the top level of its
   own USB stick. Keep it in the glovebox, not plugged in. It turns EQ Engine off even when
   Android does not come up ([Rescue stick](#rescue-stick)).
2. **Make the install stick.** Unzip `eqengine-stick.zip` onto the top level of the other stick.
   `NEMESIS.data`, `README-EQENGINE.txt`, `packages/` and `EQENGINE-source/` must be at the root
   of the stick, not inside a folder.
3. With the car on and Android running, plug the install stick into the head unit's USB port.
4. Confirm the install when NEMESIS asks. Wait for "Operation completed successfully".
5. Remove the stick and restart the car. Android's audio server loads EQ Engine's filter when it
   starts.
6. Open EQ Engine from NEMESIS Manager > My Packages > EQ Engine > Launch. On the Status page, the
   converter tile should show "Audio server confirmed at ...".

The install also writes a diagnostic report and a 40-second system log to an `EQENGINE/` folder
on the install stick. That log can contain personal data ([Logs and privacy](#logs-and-privacy)).

`README-EQENGINE.txt` on the stick describes every page and setting.

## Updating

Install the new version the same way, over the old one. NEMESIS sees the same package id
(`eqengine`) and asks "Updating EQ Engine requires reinstalling". Answer Yes, wait for "Operation
completed successfully", then restart the car.

- Your EQ settings and presets are kept. The old version's uninstall step copies them to memory
  and the new version's install step puts them back.
- Until the restart, Android's audio server still has the old filter loaded. In that state the log
  on the Status page shows "EQ detached (wrong filter version)", which is expected.
- Each release must be signed with the same key as the installed app. A build signed with another
  key will not update the installed app; uninstall it first.

After a **head unit software update**, EQ Engine checks Android's effects list at every start. If
Hyundai's update changed that file, EQ Engine does not apply itself and the audio stays stock. The
Status page says why.

## Turning it off and uninstalling

- **Off, but still installed:** Settings > EQ Engine off. Audio is completely stock from the next
  start. Turn it back on in the same place.
- **Uninstall:** NEMESIS Manager > My Packages > EQ Engine > Uninstall, then restart the car.
  - The uninstall step stops the boot step, removes the in-memory overlay and any Lab test, and
    sets Android's converter back to its default.
  - NEMESIS then removes the app, and EQ Engine's folder (`/data/eqengine`) is deleted, including
    your settings and presets.
  - After the restart, Android's audio is completely stock.
  - Changes made on Hyundai's sound pages from the Lab are Hyundai settings. Uninstalling does not
    undo them: change them back on those pages.

### Rescue stick

Use it only if something is wrong and you cannot reach the EQ Engine app or NEMESIS Manager.

- **Android running:** plug the stick in and answer Yes.
- **Android not coming up:** plug it in. NEMESIS runs it without asking, because the stick holds a
  `NEMESIS.emergency` file.

Then restart the car. The rescue stick:
- turns EQ Engine off;
- removes the in-memory changes and the Lab tests;
- resets the converter;
- writes a report to `EQENGINE-RESCUE/` on the stick.

EQ Engine stays off until you turn it back on in the app, or uninstall it.

## How it works

### The audio path

```
Android Auto music, 48,000 Hz
  -> Android's converter, 48 kHz to 44.1 kHz (per track, before mixing)   <- the converter choice
  -> Android's mixer, 44,100 Hz, 16-bit
  -> EQ Engine: preamp, 10-band EQ, seat delay, clip guard, dither          <- the EQ
  -> Hyundai's audio driver -> the car's amplifier (Hyundai's Bass/Mid/Treble, fader, balance)
  -> speakers
```

**How EQ Engine gets in:** Android's audio server loads its effects from
`/system/etc/audio_effects.conf` when it starts.
- At each start, EQ Engine's boot step lays its own copy of that file over the original, in memory
  only, with a bind mount. The copy is Android's standard list plus one EQ Engine entry.
- The audio server then loads EQ Engine's filter, and the app attaches it to session 0 of the main
  output. Session 0 is Android's global session, so the filter processes the whole mix.
- Nothing in `/system` is written. A start without the boot step is completely stock.

### Why a converter is needed at all

**The two rates differ:**
- Android Auto sends music at 48,000 Hz (measured on the car from the audio server's state).
- Hyundai's audio policy opens Android's main output at 44,100 Hz only (read from the car's
  `audio_policy.conf`).
- So Android has to convert every sample of Android Auto's music before mixing. Whether it
  converts is not a choice; how well it converts is.

**What a converter has to do:**
- It has to work out new sample values between the original ones: 44,100 per second from 48,000.
  That means rebuilding the waveform between samples with a low-pass filter.
- 44.1 kHz audio can only hold frequencies up to 22.05 kHz. The filter must remove whatever the
  music has between 22.05 and 24 kHz. If it doesn't, that content folds back into the audible band
  as tones that were never in the music (aliasing).
- At the same time, the filter must not cut the treble you can hear.
- A short filter cannot do both. It either cuts treble or lets aliases through.

### The three converter choices

| Choice | What Android uses | Treble at 16 kHz / 20 kHz | Leftover with a 19 kHz tone | Audio server CPU on the car |
|---|---|---|---|---|
| Stock (quality 0) | Linear interpolation between neighbouring samples (Android 4.4's default) | -3.3 / -5.3 dB (calculated) | about -7 dB: an alias at 15.1 kHz (calculated) | not measured |
| High (quality 3) | Android's sinc converter with its built-in 16-tap tables | -3.5 / -16.7 dB | -72 dB | 2.61% of one core |
| **Very high (quality 4)**, default | Android's sinc converter with **EQ Engine's tables**: 80 taps, 512 phases | 0.0 / 0.0 dB | -89 dB | 4.25% of one core |

**How the numbers were obtained:**
- **High and Very high (treble and leftover):** measured on a PC by running Android 4.4's own
  converter code (`third_party/aosp-af`) from 48 kHz to 44.1 kHz. Levels are relative to each
  converter's own gain. Very high is flat within 0.05 dB up to 20 kHz.
- **Stock:** calculated for ideal linear interpolation, not measured. This assumes Hyundai's build
  of Android's audio server matches Android's source.
- **CPU:** the whole audio server, measured on the car with 0.5.0, EQ on.
- **Latency:** about 0.2 ms for High and 0.8 ms for Very high, estimated from the tap counts.

**What each one does:**
- **Stock** keeps more of the top octave than High. It does almost nothing against aliasing: a
  19 kHz tone leaves a false 15.1 kHz tone only about 7 dB below it, and a 10 kHz tone leaves one
  at 6.1 kHz about 23 dB below it (both calculated).
- **High** stops aliasing well, but cuts the treble from about 12 kHz up to do it: 0.2 dB down at
  12 kHz, 16.7 dB down at 20 kHz.
- **Very high** does both, with a longer filter.

### How EQ Engine's tables keep the frequencies intact

**How Android loads them:** Android 4.4's very-high-quality mode reads its filter tables from a
library named `libaudio-resampler.so`. Without that library, it falls back bit for bit to High's
built-in tables. EQ Engine supplies the library:
- Only Android's audio server loads it, from `/data/eqengine/lib/`.
- EQ Engine's own filter loads it, only while Very high is chosen, and only if its checksum matches
  the one recorded at install.
- The audio server loads EQ Engine's filter when it opens its outputs. In the logs this was about
  0.9 s before the first conversion, so the tables are always in place first.

**The design** (`vhq/gen_tables.py`): a Kaiser-windowed sinc filter, 40 taps on each side, with
512 phases that Android interpolates between.
- **Passband to 20 kHz.** Everything you can hear passes unchanged.
- **Stopband from 24.1 kHz.** The transition from 20 to 24.1 kHz sits where anything that folds
  back lands between 20.1 and 22.05 kHz, above the audible band. The audible band stays flat and
  clean.
- **The trade-off:** content in the music between 22.05 and about 23.5 kHz folds back with less
  suppression than High gives. Measured: a 22.5 kHz tone appears at 21.6 kHz at -12.5 dB with Very
  high, against -35 dB with High. It lands above 20 kHz, and music has little energy there. From
  23.5 kHz up, Very high suppresses more than High.
- **-1.6 dB gain:**
  - Android adds up tap times sample in a 32-bit integer without saturation. A long, sharp filter
    at full gain could overflow on extreme input, which would sound like a click. At -1.6 dB the
    sum always fits.
  - The same 1.6 dB also leaves room for peaks between samples. Converted music goes up to about
    1 dB over full scale, and Android's mixer would cut that off.
  - Measured on the car: 0 clipped samples per 30 s with Very high, against 588 to 1664 with High.
- **Voice prompts:** the choice applies to everything Android's audio server converts. That
  includes navigation prompts raised from 16 kHz to 44.1 kHz: Very high is flat to 6.5 kHz
  (-0.28 dB at 7 kHz), High is 7.45 dB down at 7 kHz (measured on a PC).

**How they were tested:**
- Against Android 4.4's own converter code on a PC (`vhq/host/run.sh`).
- The ARM NEON code path in an emulator (`vhq/neon/`).
- With full-scale noise and full-scale square waves at six input rates, without overflow.

### How the EQ and the converter work together

1. **The converter works first,** on each track before mixing. EQ Engine works on the finished mix
   at 44.1 kHz, so the EQ always starts from what the converter produced.
2. **Treble loss before the EQ looks like a treble cut you didn't make.** With High, 16 kHz is
   already 3.5 dB down before the EQ, so the 8 kHz and 16 kHz sliders would partly be making up for
   the converter. With Very high, the EQ starts from a response that is flat to 20 kHz, so the EQ
   page's response line is the change you hear.
3. **An EQ cannot undo aliasing or clipping.**
   - An alias is a new tone in the middle of the music, and no EQ setting removes it without also
     cutting the music around it.
   - A sample the mixer cut off at full scale is gone. EQ Engine's clip guard protects only against
     EQ Engine's own boosts.
   - Very high avoids both before the EQ sees the audio.
4. **EQ Engine's own boosts are handled in stages:**
   - the preamp (or Auto preamp) makes room for them;
   - the clip guard catches whatever still goes over full scale;
   - TPDF dither is applied when the result goes back to 16-bit.
   All of EQ Engine's arithmetic is in double precision.
5. **The car's amplifier comes last.** It applies Hyundai's own tone settings. If you want EQ
   Engine's EQ alone, leave Hyundai's Bass, Mid and Treble at the centre.

**Fallbacks:**
- If EQ Engine's tables fail their check at a start, that start uses High.
- Each unexpected restart of Android's audio server steps the choice down one level (Very high,
  High, Stock) and keeps it. The Lab page says why. Choosing again undoes it.

### Lab: driver tests (0.6.1, not yet tested on the car)

Both tests are off until you start one. Do them parked, never while reversing.

- **48 kHz output:** with Android Auto's music playing, asks Hyundai's driver to switch the main
  output from 44,100 to 48,000 Hz while it plays.
  - **How it asks:** through Android's own run-time setting (`sampling_rate=48000` for the main
    output). Android 4.4's mixer hands that to the driver, reads back the rate the driver reports
    and rebuilds itself at that rate. Hyundai's driver has its own handling for that setting.
  - **When it counts as working:** only if Android's output, the driver's link setting and the rate
    the hardware link really takes (counted by the kernel) all say 48,000. Then Android Auto's
    music plays with no conversion at all.
  - **Anything else** is put back to 44.1 kHz at once, and the Lab line says what was seen.
  - **Start at low volume:** if the amplifier does not follow the new rate, music can play off
    pitch or crackle until you stop the test.
  - No audio restart is needed, only a short gap in the sound. It lasts until you stop it, an audio
    restart or the next car start.
  - In 0.6.0 this test asked through a copy of Android's audio policy at the audio server's start.
    Hyundai's driver received the 48 kHz request and started the hardware at 44.1 kHz anyway, so
    that route cannot work on this car.
- **Driver watch:** a pass-through layer in front of Hyundai's audio driver that records what
  Android asks of it.
  - It records stream set-ups (rate asked for and returned), settings strings, volumes and modes.
    Every 30 s it also records the rate each hardware link really runs at, from the kernel's own
    counters.
  - It changes no audio and does not touch the output streams.
  - It loads an unchanged, checksum-checked copy of the driver, and checks every entry of the
    driver's function table before forwarding it. If anything looks unfamiliar, it hands
    everything over untouched and says so.
  - Switching it on or off needs one audio restart. It lasts until you stop it or the next car
    start.

If the audio server restarts unexpectedly while a test is on, EQ Engine removes the test at once.

## Safety and failsafes

- **Nothing is written to `/system`.** All changes are in-memory bind mounts or run-time settings
  that end at the next start.
- **Firmware check:** the overlay is applied only if Android's effects list is byte for byte the
  one the package was built from. The Lab tests check Hyundai's audio driver the same way.
- **Two-strike rule:** a start that is never confirmed good counts as a strike. Two in a row turn
  EQ Engine off.
- **Crash watch:** unexpected audio server restarts, twice within 60 s or three times in one start,
  turn EQ Engine off.
- **Audio restarts are gated:**
  - One at a time, at least 10 s apart.
  - After each one, EQ Engine checks that Android Auto's music plays again. Android 4.4 sometimes
    leaves it silent after an audio restart.
  - Do them parked only, never while reversing: the rear camera runs in the same Android process.
- **Ways back:** stop the Lab test, Settings > EQ Engine off, uninstall, the rescue stick, or a car
  restart (for Lab tests).

## Logs and privacy

Settings > Save logs to USB writes an `EQENGINE` folder to a USB stick. The install writes one too.

These logs contain personal data: your phone's name, Bluetooth addresses, song titles and possibly
navigation details. The head unit's kernel log also holds its serial number. Remove that data
before you post a log anywhere public, for example in a GitHub issue.

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
  `audio.primary.tcc803x.so`, copied from your own head unit.
  - They are Hyundai's files: never commit or publish them.
  - The app is linked against the car's own `framework-res.apk`, and the tests use the others.
- `keys/eqengine.keystore` (not in git): the app's signing key.
  - `build.sh` stops if it is missing.
  - `EQE_NEW_KEY=1` makes a new key, but an app signed with a new key cannot update one signed
    with another key.

`EQE_TOOLS` and `EQE_CAR` can point to `devtools/` and `car-files/` elsewhere.

```sh
sh build.sh                                   # native code, app, package and both stick zips
for s in dash bash mksh; do bash tests/boot/run.sh $s; bash tests/act/run.sh $s; done
bash vhq/host/run.sh 40 9                     # converter tables against Android's converter code
gcc -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -I tests -I native \
    -o tests/host_test tests/host_test.c -lm -ldl -lpthread && ./tests/host_test   # after vhq/host
sh native/drvtest/run.sh                      # driver watch against a stand-in driver
bash tests/lab/run.sh                         # the 48 kHz test's helper (link rates, Android's settings)
python3 native/drvtest/tramp_test.py native/out/eqe_drvwatch.so \
    $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf native/drvwatch_exports.txt
python3 tests/meta/check_meta.py pkg/NEMESIS.data
```

The outputs are `eqengine-stick.zip` (the install stick) and `eqengine-rescue-stick.zip`.

**Shell scripts** run on the head unit's `/system/bin/sh` (mksh) with toolbox only, so they use
shell builtins rather than grep, sed, awk, head or tail. The tests run them under dash, bash and
mksh.

## Repository layout

| Path | What |
|---|---|
| `native/eqengine.c` | the audio filter, loaded by Android's audio server |
| `vhq/` | EQ Engine's converter tables: the design script, the generated tables and their tests |
| `native/drvwatch.c`, `native/gen_tramp.py` | Lab driver watch, a pass-through layer in front of Hyundai's audio driver |
| `native/eqe_lab.c` | the 48 kHz test's helper: the links' real rate from the kernel's counters, and Android's own run-time settings |
| `native/aosp44/`, `third_party/aosp-af/` | Android 4.4.2 headers and audio code, for building and testing |
| `pkg/` | the NEMESIS package: `NEMESIS.data`, the boot step (`bin/boot.sh`), the app's root actions (`bin/act.sh`), install scripts, and the effects list overlay (`conf/audio_effects.conf`: Android's standard list plus EQ Engine's entry) |
| `app/` | the Android app (Java, no Gradle) |
| `rescue/` | the rescue stick |
| `stick/README-EQENGINE.txt` | the README that goes on the install stick |
| `tests/` | boot step, actions, filter, effects-list parsing and package metadata tests |
| `tools/` | the signing helper, a mockup renderer for the app's pages at the car's screen size, and the Docker build environment (`tools/build-env/`) |
| `docs/NOTES.md` | measurements, facts about the car and project history |

## License and credits

No license has been chosen for EQ Engine's own code yet.

Files in `third_party/aosp-af/`, `native/aosp44/`, `native/fx44.h` and `tests/conf/` come from or
follow the Android Open Source Project, under the Apache License 2.0 (see each file's header).

EQ Engine relies on [NEMESIS](https://github.com/xwtk/hmg_nemesis) by xwtk. The Gen5W community's
work, including [HMG-API](https://github.com/Open-HMG/HMG-API), was background reading for it.
