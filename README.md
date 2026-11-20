# EQ Engine

> [!WARNING]
> **Mostly written by AI. Use at your own risk.** The code, the measurements and this README were
> mostly written by an AI assistant. A person directed the work and tested it
> on one car. Tests on a PC and on that car have not shown problems, but this software runs inside
> Android's audio server on your head unit, and you are responsible for anything you install on
> your car.

EQ Engine is a [NEMESIS](https://github.com/xwtk/hmg_nemesis) package for Hyundai's Gen5W head
unit (Android 4.4). It works on Android's main audio output, where Android Auto's music plays,
and does two separate things:

1. **Sound quality, with no EQ needed.** It runs that output at 48 kHz instead of Hyundai's
   44.1 kHz, so Android Auto's 48 kHz music goes to the head unit's audio hardware without being
   resampled. What still has to be resampled (Bluetooth audio, voice prompts) goes through a
   better converter.
2. **Tone and imaging, if you want them.** A 10-band EQ, a preamp, a clip guard and a
   listening-position delay.

You can use the first without the second: see [Using it for 48 kHz only](#using-it-for-48-khz-only).

It is a plain NEMESIS package. It is **not** an HMG-API mod and does not need HMG-API (it works
alongside it).

> [!NOTE]
> **Android Auto first.** EQ Engine has been written and tested for Android Auto (tested over
> wireless; wired Android Auto uses the same receiver app and audio path). **CarPlay is not covered
> yet.** On the tested car CarPlay's music did not go through
> EQ Engine at all, and where Hyundai's CarPlay receiver plays it is still being worked out.

**Current version: 0.6.4.** It has not been on a car yet. The car below ran the build before it.

## Verified vehicles

| Car | Region | Audio system | Head unit software | Tested with |
|---|---|---|---|---|
| 2022 Hyundai Ioniq 5 SEL | USA | Standard (non-Bose) | 260507 (`NEEV.USA.0000.V015.012.260507`) | 0.6.3, partly (2026-11-20) |

No other car or software version has been tested. Other cars may have a different amplifier (for
example Bose), audio driver or audio settings. The package is marked for US Ioniq 5 software
(`os="NEEV.USA.*"`); on other software NEMESIS shows it as a partial match. If you try it on
another car, please send a [car report](#reporting-a-problem).

## What it does

### 48 kHz output (on by default)

Android Auto sends its music to the car at 48,000 samples a second. Hyundai's head unit runs
Android's main output at 44,100. So on a stock car Android resamples every sample of Android
Auto's music from 48 to 44.1 kHz before it is played, and Android 4.4's converters lose treble
doing it ([measurements](#the-converter)).

EQ Engine switches the main output, and the hardware link behind it, to 48 kHz while the car
runs. Android Auto's music then plays at its own rate, sample for sample. The switch:
- uses Android's own run-time setting: nothing in `/system` is changed, and Android's audio
  server is not restarted for it;
- is accepted only if Android, the audio driver and the hardware's real rate (counted by the
  kernel) all say 48,000; otherwise everything goes back to 44.1 kHz;
- is checked again every time music starts.

On the tested car the hardware link ran at 47,995-48,004 frames a second at 48 kHz (the kernel's
own counters), and the music played at the right pitch with no clicks.

### Converter choice (Lab, Very high by default)

For whatever Android still has to resample: Stock (Android's default), High, or Very high. Very
high is Android's own very-high-quality converter with EQ Engine's filter tables, flat to
19-20 kHz ([table](#the-converter)).

### EQ and listening position (optional)

- **10-band EQ**, 31 Hz to 16 kHz, ±15 dB. The sliders are accurate: EQ Engine solves for the
  band gains that make the response at each band's centre match its slider. The orange line on
  the EQ page is the real response.
- **Preamp and Auto preamp**, built-in presets and four of your own.
- **Clip guard**: a look-ahead limiter that acts only on samples a boost would push past full
  scale.
- **Listening position**: delays the side nearer the chosen seat so both sides arrive there
  together (1.7 ms by default, with a seat offset to adjust it). Volumes stay with the car's
  balance and fader.
- **EQ off is bit-exact**: the audio comes out unchanged, 1.3-1.4 ms later (63 samples, the
  clip guard's look-ahead).

### Car report

One text file for sharing, meant to hold no personal data ([Reporting a problem](#reporting-a-problem)).

### What goes through it

| Source | Where it plays | EQ Engine's EQ | Sample rate |
|---|---|---|---|
| Android Auto music (wired or wireless) | Android's main output | yes | 48 kHz, not converted |
| Bluetooth audio (for example an iPhone) | main output (Hyundai's Bluetooth receiver plays it there) | yes | 44.1 kHz, converted up to 48 kHz (Very high) |
| Android Auto's directions voice, the car's navigation prompts | Android's second output | no | 44.1 kHz; voice at 16 or 22 kHz is converted with the converter choice |
| Phone calls (hands-free) | the hands-free chip's own link | no | not touched |
| CarPlay | not through EQ Engine on the tested car | no | not touched |
| FM and SiriusXM radio | most likely not through Android (not confirmed) | no | not touched |
| USB music, other apps | not checked yet | | |

Hyundai's own Bass, Midrange, Treble, fader and balance still work: the car applies them after
Android. To have EQ Engine as the only tone control, set Bass, Midrange and Treble to Center
(Sound Settings > Tone).

## Using it for 48 kHz only

You don't have to touch the EQ. With the equalizer switched off, EQ Engine's filter passes the
audio through bit-exact, and the 48 kHz output and the converter work exactly as with the EQ on.

1. [Install](#install) it and restart the car.
2. EQ page: switch the EQ off (or Settings > Equalizer off). The preamp, clip guard and seat delay
   are part of the EQ and are off with it.
3. Leave **Settings > 48 kHz output** on and **Lab > converter** on Very high (both defaults).
4. Leave **Settings > EQ Engine** on. That is the master switch: off turns everything off,
   including the 48 kHz output.
5. Play Android Auto music. **Status > Output** should say "48 kHz, unconverted".

What you get then:
- Android Auto's music is not resampled in Android.
- Bluetooth audio and voice prompts are resampled with EQ Engine's tables instead of Android's.
- Nothing else changes: no EQ, no limiter, no delay, no added gain.

Whether you can hear the difference depends on the music, the car and your ears. What can be
measured is in [Upsides and downsides](#upsides-and-downsides) and [The converter](#the-converter).

## Does it change system files?

**No. EQ Engine writes nothing to `/system`, and leaves nothing behind outside its own files.**
That makes it safe to try: turn it off or uninstall it, restart the car, and the head unit is
stock again. In detail:

- **Two system files are covered in memory, never changed.**
  - Covered: `/system/etc/audio_effects.conf` (always, to add EQ Engine's filter to Android's
    list), and `/system/lib/hw/audio.primary.tcc803x.so` (only while the Lab driver watch is on).
  - Both are bind mounts: the original files stay byte for byte as they are underneath.
  - The cover ends at the next restart, or when EQ Engine is turned off. `/system` is never
    remounted writable.
- **Run-time settings only.** The main output's 48 kHz rate and Android's converter property
  (`af.resampler.quality`, not a persistent property) last only until the head unit restarts.
  While EQ Engine is on, it sets them again at every start.
- **Its own files:** the app, and `/data/eqengine` (settings, logs, the filter and its converter
  tables). Uninstalling removes them.
- **Nothing else:**
  - No Android settings are written, and nothing is sent to the car's audio controller or
    amplifier.
  - The Lab can open Hyundai's own sound pages. Anything changed there is a Hyundai setting that
    you changed yourself, and it stays until you change it back on those pages.
- **During the install only:** if NEMESIS's own `/data/nemesis/apps` folder is readable by root
  only, it is opened (0711) for 40 s so Android can read the app, then closed again.

Using it is not risk-free: it runs inside Android's audio server, and restarting that server (on
request, parked) also restarts the rear camera service. See [Upsides and
downsides](#upsides-and-downsides) and [Safety and failsafes](#safety-and-failsafes).

## Upsides and downsides

### Upsides

- **No resampling of Android Auto's music in Android.** At 44.1 kHz, Android's converters lose
  treble. Measured with Android 4.4's own converter code: High is down 3.5 dB at 16 kHz and
  16.7 dB at 20 kHz. Stock is down an estimated 3.3 and 5.3 dB (calculated). In the car's logs,
  High also let 588-1664 clipped samples through every 30 s of music.
- **Better conversion for what is still converted.** Very high is flat to 19 kHz in both
  directions. Its leftover noise and aliasing is -87 dB or lower up to 20 kHz.
- **The EQ is optional, and off means untouched.** EQ off is bit-exact.
- **Light on the head unit.** EQ Engine's own processing, EQ on, measured 1.8-2.1% of real time on
  one core at 48 kHz.
- **Nothing written to `/system`.** Everything is undone by turning it off, uninstalling, or the
  rescue stick ([Does it change system files?](#does-it-change-system-files)).
- **Your car's controls keep working:** volume, balance, fader and Hyundai's tone controls.

### Downsides and limits

- **Android Auto only for now.** CarPlay's music does not go through it. Navigation prompts and
  calls are not EQ'd.
- **A short gap when the rate changes during music.**
  - EQ Engine tries to switch while nothing plays, so the music starts at 48 kHz with no gap.
  - When music is already playing (Android Auto starts its music before the switch, after an
    audio restart, or when you turn 48 kHz output on or off), there is one short gap in the
    sound at the switch.
- **About 1.6 dB louder.** At 44.1 kHz the Very high converter runs 1.6 dB below full scale. At
  48 kHz nothing is converted, so loud music reaches full scale.
  - Measured on the car: peaks at 0.0 dBFS instead of -0.9 to -1.6 dBFS.
  - With EQ boosts, use the preamp or Auto preamp sooner.
  - Music whose peaks are already clipped arrives clipped: no player can undo that.
- **44.1 kHz sources are converted up instead.** Bluetooth audio is a 44.1 kHz stream, so at
  48 kHz output it is converted 44.1 to 48 kHz. With Very high that is flat to 19 kHz and down
  3.2 dB at 20 kHz. With 48 kHz output off, Bluetooth plays unconverted but Android Auto is
  converted. You choose which.
- **The amplifier side cannot be seen.** EQ Engine controls Android and the head unit's audio
  link. The head unit drives that link's clock and sends 48,000 samples a second. Whether
  Hyundai's amplifier or DSP converts internally after that cannot be seen from Android.
- **Sometimes not active after a car start.**
  - If Android's audio server reads its effects list before EQ Engine's boot step is in place,
    EQ Engine is not loaded for that start. That was seen once in three starts on the tested car.
  - The app says so. Restart Android's audio once (Settings > Restart Android audio, parked).
  - EQ Engine never restarts it by itself (see the next point).
- **Audio restarts are tied to the rear camera.** Hyundai runs the rear camera service in the same
  Android process as the audio server.
  - The audio server is restarted by Settings > Restart Android audio, a converter change, and
    the Lab driver watch, and only when you ask.
  - Do those parked, never while reversing.
- **One car tested, mostly written by AI.** See the warning above and
  [Verified vehicles](#verified-vehicles).

## Install

### Before you start

- **NEMESIS** must be installed on the head unit. Its
  [README](https://github.com/xwtk/hmg_nemesis#readme) covers that. EQ Engine needs nothing else.
- Get `eqengine-stick.zip` and `eqengine-rescue-stick.zip` from
  [Releases](https://github.com/alexkozler/Gen5W-EQ-Engine/releases), or build them
  ([Building from source](#building-from-source)).
- Use one or two blank USB sticks formatted exFAT or FAT32.
- Do this **parked**. Installing restarts Android's audio, which gives a few seconds of silence.
  The rear camera service runs in the same Android process, so never do it while reversing.

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
6. Open EQ Engine from NEMESIS Manager > My Packages > EQ Engine > Launch. Play some music. On
   the Status page, the Output tile should show "48 kHz, unconverted" within about 10 s.

When EQ Engine is opened again while it is already running, NEMESIS Manager may show "Warning:
Activity not started, its current task has been brought to the front". That is the output of
Android's `am start` command, which NEMESIS Manager uses to open apps. EQ Engine opens normally.

The install also writes a diagnostic report and a 40-second system log to an `EQENGINE/` folder
on the install stick. That log can contain personal data ([Reporting a problem](#reporting-a-problem)).

## Updating

Install the new version the same way, over the old one. NEMESIS asks "Updating EQ Engine requires
reinstalling": answer Yes, wait for "Operation completed successfully", then restart the car.

- Your EQ settings and presets are kept.
- Until the restart, Android's audio server still has the old filter loaded, and the Status log
  shows "EQ detached (wrong filter version)". That is expected.
- An update must be signed with the same key as the installed app. A build signed with another key
  will not install over it; uninstall first.

After a **head unit software update**, EQ Engine checks Android's effects list at every start. If
the update changed that file, EQ Engine does not apply itself, the audio stays stock, and the
Status page says why.

## Turning it off and uninstalling

- **Off, but still installed:** Settings > EQ Engine off. Audio is completely stock from the next
  start. Turn it back on in the same place.
- **Uninstall:** NEMESIS Manager > My Packages > EQ Engine > Uninstall, then restart the car.
  - The uninstall step turns the boot step and the 48 kHz output off, removes the in-memory
    overlay and the driver watch, and sets Android's converter back to its default.
  - NEMESIS then removes the app and `/data/eqengine`, including your settings and presets.
  - Changes made on Hyundai's sound pages from the Lab are Hyundai settings: change them back on
    those pages.

### Rescue stick

Use it only if something is wrong and you cannot reach the EQ Engine app or NEMESIS Manager.

- **Android running:** plug the stick in and answer Yes.
- **Android not coming up:** plug it in. NEMESIS runs it without asking, because the stick holds a
  `NEMESIS.emergency` file.

Then restart the car. The rescue stick turns EQ Engine off, removes its in-memory changes and the
driver watch, resets the converter, and writes a report to `EQENGINE-RESCUE/` on the stick. EQ
Engine stays off until you turn it back on in the app, or uninstall it.

## How it works

### The audio path

```
Android Auto music, 48,000 Hz
  -> Android's mixer, 48,000 Hz (no conversion)              <- 48 kHz output
  -> EQ Engine's filter: preamp, 10-band EQ, seat delay,
     clip guard, dither (or bit-exact pass-through, EQ off)
  -> Hyundai's audio driver -> link I2S_3 at 48 kHz
  -> the car's amplifier (Hyundai's Bass/Mid/Treble, fader, balance) -> speakers
```

EQ Engine has three parts on the head unit:
- **The filter** (`libeqengine.so`), which Android's audio server loads from Android's effects
  list. EQ Engine adds itself to that list with an in-memory overlay of
  `/system/etc/audio_effects.conf` at every start. The filter works on the finished mix of the
  main output (Android's session 0).
- **The boot step**, which applies the overlay, picks the converter and watches for trouble.
- **The app**, for the settings and the pages. Its root actions run as `pkg/bin/act.sh`,
  including the background 48 kHz keeper (`act.sh keep`).

### The 48 kHz output

Hyundai's audio policy opens Android's main output at 44.1 kHz, and Hyundai's audio driver ignores
any other rate asked for when the output opens. It does follow Android's run-time setting
`sampling_rate=48000`. Android passes that to the driver, then rebuilds its mixer at the rate the
driver reports, and the driver restarts its hardware link at the new rate.

**Hyundai's driver applies the new rate only while its stream is active.** Sent while nothing
plays, Android takes the new rate but the link starts at the old one later, so the music would
play slow. EQ Engine never sends it then. Instead:
- **While nothing plays** (8 s after Android's audio server starts, at a car start or after an
  audio restart), a small helper in the
  app's package plays a few seconds of silence as music, so the link runs. EQ Engine switches
  during it and checks the result at once. The music then starts at 48 kHz with no gap.
  - The silent track asks for no audio focus, so nothing is paused or ducked.
  - A sound that starts meanwhile is mixed with it as usual.
- **While music plays**, it switches at once, with one short gap.

**Android 4.4 has a fault at a rate change, and EQ Engine works around it.**
- Android frees the output's mix buffer and allocates a new one. Only tracks whose audio session
  has an effect chain are moved to the new buffer.
- Every other track is still mixed into the freed one: it goes silent, and the audio server's
  memory is overwritten. It usually goes unseen because the new buffer tends to land at the old
  address. On the tested car it once left Android Auto's music silent until Android's audio was
  restarted.
- So for every change, EQ Engine's helper puts a disabled copy of its filter on every audio
  session with a track on the main output. That gives each session a chain, and Android moves its
  tracks along.
- After the change the copies are removed, which points the tracks at the new buffer. A disabled
  filter passes the sound through unchanged: Android never calls it.
- EQ Engine checks Android's own dump before and after: every track must play into the right
  buffer.
  - A track that appears during the hold is held too, and the hold is made again.
  - A track found on the wrong buffer later is moved back (if that fails, the app says to
    restart Android's audio).
  - Without the hold, no rate change is made.

**Checks and fallbacks:**
- A switch is accepted only if three things say 48,000: Android's output, the driver's link
  setting, and the rate the link really takes (counted by the kernel).
- A switch the link does not follow is put back within about 3 s; until then the music plays at
  the wrong speed.
- Each time the music starts, EQ Engine checks that Android and the link still agree.
- If anything is off, both go back to 44.1 kHz for that audio server, and the Lab page says why.
- If Android's audio server crashes within 20 s of a switch, 48 kHz output is turned off in the
  settings.
- EQ Engine never restarts the audio server for this.

### The converter

The converter choice (Lab page) applies to everything Android still converts:
- Bluetooth audio and any other 44.1 kHz source while the output is at 48 kHz;
- navigation and voice prompts on the second output (16 up to 44.1 kHz);
- Android Auto's music whenever the output is at 44.1 kHz (48 kHz output off, or not accepted).

Measured with Android 4.4's own converter code on a PC, levels relative to each converter's gain:

| Converter | 48 → 44.1 kHz, at 16 / 20 kHz | 44.1 → 48 kHz, at 16 / 20 kHz | 16 → 44.1 kHz, at 7 kHz |
|---|---|---|---|
| Stock (Android's default) | -3.3 / -5.3 dB (calculated) | not measured | not measured |
| High | -3.5 / -16.7 dB | -1.2 / -10.0 dB | -7.45 dB |
| **Very high** (default) | 0.0 / 0.0 dB | 0.0 / -3.2 dB | -0.28 dB |

- **Very high** is Android's very-high-quality converter with EQ Engine's own filter tables, in
  `/data/eqengine/lib/libaudio-resampler.so`: a Kaiser-windowed sinc with 40 taps a side and 512
  phases.
- **Leftover noise and aliases** with Very high: -87 dB or lower up to 20 kHz for both music
  directions, and -85 dB or lower up to 7 kHz for voice. With High it rises to about -72 dB
  (48 to 44.1) and -30 dB (44.1 to 48) near 19-20 kHz.
- **Headroom:** the tables have -1.6 dB of gain, so Android's 32-bit sum cannot overflow. That
  also leaves room for peaks between samples: in the car's logs, High let 588-1664 clipped
  samples through per 30 s, Very high none.
- **Who loads the tables:** only Android's audio server, through EQ Engine's filter, and only
  while Very high is chosen and the file matches its install checksum. Without them Android falls
  back, bit for bit, to High.
- **Fallbacks:** tables that fail their check make that start use High. Each unexpected audio
  server restart steps the choice down one level (Very high, High, Stock) and keeps it.
- **On the car:** with Very high, Android's audio server used about 1.6% more of one core than
  with High.

### The EQ

- EQ Engine works on the finished mix of the main output, after any conversion. Its arithmetic is
  in double precision.
- Its own boosts are handled in three stages:
  - the preamp makes room;
  - the clip guard catches what still goes over full scale;
  - TPDF dither is added on the way back to 16-bit.
- With the EQ off it switches to a bit-exact path (after a short crossfade), and none of that
  runs.
- It cannot undo clipping that is already in the music: those samples arrive flat-topped. The
  Status page counts them as "Arrived clipped".

### Lab

- **Hyundai's sound pages:** Hyundai's own screens, some of them hidden. Changes there are
  Hyundai settings and stay until you change them back.
- **Converter choice:** see [The converter](#the-converter).
- **Driver watch:** a pass-through layer in front of Hyundai's audio driver that writes down what
  Android asks of it, plus every 30 s the rate each hardware link really runs at.
  - It changes no audio and does not touch the output streams.
  - It loads an unchanged, checksum-checked copy of the driver and checks every entry of the
    driver's function table first. If anything looks unfamiliar, it hands everything over
    untouched and says so.
  - It needs one audio restart to switch on or off, and lasts until the next car start. Switching
    it off detaches it while the audio server still has it loaded; the restart then loads
    Hyundai's driver.
- **Audio trace:** 120 s of the system log plus before and after snapshots of the audio system.

### Safety and failsafes

- **Nothing is written to `/system`.** Changes are in-memory bind mounts or run-time settings
  that end at the next start.
- **Firmware check:** the overlay is applied only if Android's effects list is byte for byte the
  one the package was built for. The driver watch checks Hyundai's driver the same way.
- **Loaded check:** at every start the boot step checks that the audio server has EQ Engine's
  filter loaded, and says so if it does not.
- **Two-strike rule:** a start that is never confirmed good counts as a strike. Two in a row turn
  EQ Engine off.
- **Crash watch:** unexpected audio server restarts, twice within 60 s or three times in one
  start, turn EQ Engine off.
- **Audio restarts** (converter change, driver watch, Settings > Restart Android audio) happen only
  when you ask:
  - one at a time, at least 10 s apart;
  - each is followed by a check that Android Auto's music plays again;
  - do them parked, never while reversing.
- **Ways back:** Settings > EQ Engine off, uninstall, the rescue stick, or a car restart (for the
  driver watch).

## Reporting a problem

Settings > Save to USB has two buttons.

- **Report** makes the car report, a single text file in the `EQENGINE` folder on the stick. Play
  some music first: the report records 30 s of the audio system's log and measures the hardware
  link. It holds:
  - the head unit's model, region and software version;
  - a list of checks (ok / NO / ?): Android version, effects list, audio driver, the 48 kHz switch,
    the filter and the converter tables, the tracks' buffers, the boot step;
  - the sound hardware, its link rates and which process plays on each link (for CarPlay, make
    the report while CarPlay plays music);
  - which apps play at what rate;
  - EQ Engine's own logs.

  Lines that could carry Bluetooth names or addresses, song details, a location, serial numbers or
  a VIN are left out. Hyundai's files are not copied, only their checksums and the sample rates
  their audio policy declares. Read the file before you post it anywhere public, for example in a
  GitHub issue.
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
  `audio.primary.tcc803x.so`, copied from your own head unit. They are Hyundai's files: never
  commit or publish them. The app is linked against the car's `framework-res.apk`, and the tests
  use the others.
- `keys/eqengine.keystore` (not in git): the app's signing key. `build.sh` stops if it is missing.
  `EQE_NEW_KEY=1` makes a new one, but an app signed with a new key cannot update one signed with
  another.

`EQE_TOOLS` and `EQE_CAR` can point to `devtools/` and `car-files/` elsewhere.

```sh
sh build.sh                                   # native code, app, package and the stick zips
for s in dash bash mksh; do bash tests/boot/run.sh $s; bash tests/act/run.sh $s; done
bash vhq/host/run.sh 40 9                     # converter tables against Android's converter code
gcc -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -I tests -I native \
    -o tests/host_test tests/host_test.c -lm -ldl -lpthread && ./tests/host_test   # after vhq/host
sh native/drvtest/run.sh                      # driver watch against a stand-in driver
bash tests/lab/run.sh                         # eqe_lab: link rates, Android's settings, the report's check
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
| `native/eqe_lab.c` | root helper: the links' real rate from the kernel's counters, Android's run-time settings, and the report's check |
| `native/drvwatch.c`, `native/gen_tramp.py` | the Lab driver watch |
| `native/aosp44/`, `third_party/aosp-af/` | Android 4.4.2 headers and audio code, for building and testing |
| `pkg/` | the NEMESIS package: `NEMESIS.data`, the boot step (`bin/boot.sh`), the app's root actions and the 48 kHz keeper (`bin/act.sh`), install scripts, and the effects list overlay (`conf/audio_effects.conf`: Android's standard list plus EQ Engine's entry) |
| `app/` | the Android app (Java, no Gradle), and `Hold.java`, the 48 kHz switch's helper (it holds the main output's audio sessions and plays the silent track) |
| `rescue/` | the rescue stick |
| `stick/README-EQENGINE.txt` | the README that goes on the install stick |
| `tests/` | boot step, actions, filter, effects-list parsing and package metadata tests |
| `tools/` | the signing helper, a mockup renderer for the app's pages at the car's screen size, and the Docker build environment |

## License and credits

No license has been chosen for EQ Engine's own code yet.

Files in `third_party/aosp-af/`, `native/aosp44/`, `native/fx44.h` and `tests/conf/` come from or
follow the Android Open Source Project, under the Apache License 2.0 (see each file's header).

EQ Engine relies on [NEMESIS](https://github.com/xwtk/hmg_nemesis) by xwtk. The Gen5W community's
work, including [HMG-API](https://github.com/Open-HMG/HMG-API), was background reading for it.
