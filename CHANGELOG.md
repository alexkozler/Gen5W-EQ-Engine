# Changelog

## 0.7.7

All the changes from 0.7.6, and fixes from a full code review of EQ Engine and of how it works with
NEMESIS, HMG-API and their wireless packages (tested on the Ioniq 5: Android Auto, CarPlay wired
and wireless, an update over the previous version, an uninstall and a reinstall):

### Installing, updating and uninstalling

- An update keeps your settings on the unit's storage while it runs, so they survive the power
  going off in the middle of it (a plain uninstall still keeps them in memory only, until the next
  restart). 48 kHz output carries on through an update.
- The install's system log on the stick is deleted again when the install works; it is kept only
  when the install fails, for the package manager's reason.
- Uninstalling and the rescue stick no longer wait 15 s for the 48 kHz output to be put back while
  CarPlay is playing (nothing can be changed then).
- EQ Engine refuses to start, and says why, when another package's file is laid over Android's
  effects list; it never takes another package's file over the audio driver for its own either.
- The package is marked for any head unit software (it was US Ioniq 5 software only), so NEMESIS
  no longer shows it as a partial match on other cars. The README's Verified vehicles lists the
  cars it has been tested on.
- The package has its own icon in NEMESIS Manager's Store and package lists (NEMESIS 1.17's
  descriptor 1.2; older NEMESIS installs it as before and shows its usual icon).

### EQ on CarPlay

- Before it changes anything in the CarPlay app, the CarPlay layer checks that the CarPlay
  library is laid out the way it expects in memory. If it is not, the layer leaves CarPlay
  untouched and EQ on CarPlay stays off.
- Auto preamp and Copy Easy EQ also work while only CarPlay is playing.
- The CarPlay layer picks its live file and notes up again when an update replaces them.
- A lock left by a power cut no longer blocks the EQ on CarPlay switch, and a refusal while
  the app sets it up in the background is now shown.

### EQ engine (filter 325)

- With the EQ off, or a microphone open, and the clip guard off, samples over full scale are
  clamped instead of wrapping round.

### App

- An action that finishes while EQ Engine's screen is closed shows its result when you come back,
  never as a pop-up over another app.
- The "kept restarting" notice is shown once per car start that needs it.
- Double-tapping the Position slider centres it.
- The converter's explanation no longer says it handles voice prompts (Android always gives
  those its simple converter), and the 48 kHz line says CarPlay keeps its own rate (44.1 or
  48 kHz).
- After a crash, the app copies its logs only to a stick already used for EQ Engine, never to
  another stick that happens to be plugged in.

### Car report and logs

- The report's effects-list check showed the wrong file's checksum, and its list of properties was
  empty on the car. Both are fixed.
- The report's 48 kHz check no longer says EQ Engine cannot process CarPlay's sound (EQ on CarPlay
  has done that since 0.7.3); it says 48 kHz output waits while CarPlay has the speaker link.
- The report finishes, and says so, when Android's audio server does not answer; a full stick is
  reported instead of a cut-off file.
- Files that can hold personal data (crash logs, the Lab's log lines, audio traces, a restart's log
  lines, an interrupted report's raw files) are readable by root only from the moment they are
  made.

### Lighter on the head unit

- The 48 kHz output check and the CarPlay check no longer start programs every second.
- The converter's log capture stops once it has the line it needs.
- An audio restart's wait follows one log stream instead of reading the whole system log every
  second.
- EQ Engine's own mounts use Android's mount program directly.

### Releases and docs

- Each release also has `eqengine-<version>.zip`, the bare package for the NEMESIS Package Store.
  For installing by hand from a USB stick, use `eqengine-stick-<version>.zip` as before.
- The build is reproducible: the same source gives byte for byte the same package, so the store's
  file and the release's are the same bytes.
- The install steps say how NEMESIS 1.17 shows a finished install (Package Manager lists EQ Engine
  under Installed, where 1.16 said "Operation completed successfully"), and to leave the stick in
  until then.

## 0.7.6

All the changes from 0.7.5, and fixes from two code reviews (tested on a PC; the car-tested build
is 0.7.4):

### EQ on CarPlay

- If the car's CarPlay library failed to load at all, EQ on CarPlay did not notice and stayed on,
  which could leave CarPlay unable to start at every car start. It now turns itself off, restarts
  the CarPlay app without it when nothing is connected, and tells you; it restarts the app only once
  its own mount is confirmed gone.
- EQ Engine now removes only its own mounts (checked by md5), when it is turned off, when EQ on
  CarPlay turns off, at uninstall and with the rescue stick, for both the CarPlay layer and the
  effects list. If another package has laid a file over the CarPlay app's library, EQ on CarPlay
  stays off rather than covering it.
- A stream closing while another opened, once more than 64 had been opened in one car start, could
  lose track of the microphone or of the music stream. A closing stream now keeps its place until
  its close is done.
- The once-a-second "the live view is shown" message from the app no longer makes the CarPlay
  filter redesign every band; only settings that changed are applied.
- Its notes now show how long the music waited for a settings change, apart from the filter's own
  time.

### EQ page

- Auto preamp now covers the larger boost of 44.1 and 48 kHz (filter 324): a band near 20 kHz is
  left out at CarPlay's 44.1 kHz, so a 20 kHz cut next to a 19 kHz boost could leave up to 12 dB of
  boost on CarPlay.
- The Expert graph is drawn at CarPlay's rate while CarPlay plays.
- Changing a band's width (or a -/+ button) redraws only that band's curve, not all of them.
- While CarPlay plays, the app no longer asks Android's audio server for levels and the live view
  it does not show (two calls every 40 ms with Live on); Expert mode no longer reads the Easy
  graph after each change.

### Privacy and housekeeping

- The crash logs EQ Engine keeps (they hold the raw system log) stay readable by root only; the
  next start, and an install, made them readable by every app.
- The boot step writes its status file only when it changes (it was every 5 s while the car ran).

## 0.7.5

The first release since 0.6.6. The versions in between (0.6.7 to 0.7.4) were test builds that were
only run on the test car. Version numbers now have one digit per part: after 0.6.9 came 0.7.0.

### New: EQ on CarPlay

- CarPlay's music, wired and wireless, gets EQ Engine's EQ (Easy or Expert), preamp, clip guard and
  listening position, with the same filter code as Android Auto, at CarPlay's own rate (44.1 or
  48 kHz) and with nothing converted. Added delay: 1.4 ms, plus the seat delay if set.
- On by default: Settings > EQ on CarPlay. Off makes CarPlay flat at once; on takes effect at the
  next car start, or at once when it was on at this car start.
- It works from inside the factory CarPlay app: at each car start, before that app starts, a small
  library is laid over the app's JNI library in memory; it loads an unchanged copy of the car's own
  file and runs the filter on the music stream it writes to the speakers. Nothing on the car is
  written, and the CarPlay app is never restarted for it. [How it works](README.md#how-eq-on-carplay-works).
- Siri, calls and the microphone are never processed; the music goes dry while the microphone is
  open.
- Checked before use in a separate process, at the install and again after a factory software
  update changes the CarPlay app's library.
- If it cannot load, or the CarPlay app restarts twice within two minutes with it, it turns itself
  off; the app then says so the next time it opens and asks for the logs. A unit without the
  factory CarPlay app is left alone.
- Works alongside HMG-API and its wireless CarPlay and Android Auto package (their hooks and library
  patches stay in place); it does not need HMG-API.
- The meter, the live view and the Status page show CarPlay's music while it plays; Diagnostics
  has a CarPlay card with what it is doing.
- 48 kHz output and the converter are now labelled as being for Android Auto and Bluetooth audio
  only: CarPlay is never converted.

### New: Expert mode

- "Easy | Expert" at the top of the EQ page. Easy is the 10-band EQ as before; Expert is a
  parametric EQ with up to 20 bands. Each mode keeps its own EQ; switching never changes the other.
- Band types: peak (0.1 to 4 octaves wide, shown as Q and octaves), low shelf and high shelf at any
  frequency, low cut (12 dB an octave, Q 0.5 to 2).
- The graph is the editor: each band is a dot, numbered by frequency from the left (also while one
  is dragged past another); drag it for frequency and gain. Each band's own curve is drawn faintly,
  the selected one filled, with its bandwidth's edges dashed.
- The band card: the previous and next band, the type, frequency (-/+ a 24th of an octave, or tap
  to type it), gain (-/+ 0.5 dB) and width.
- The graph's scale grows (±15, 27, 39 or 51 dB) so the summed curve always fits; it changes when
  the finger lets go of a dot, never under it.
- Starting Expert offers Copy Easy EQ (the same sound, as 10 bands), Start flat or Cancel,
  whenever Expert has no bands.

### EQ page

- User 1-4 are shared by both modes: a slot saved in Expert switches the page to Expert when loaded.
- Curves on USB: saves User 1-4 to the stick's EQENGINE_CURVES folder, or loads them from it.
- Undo steps back through up to 30 changes (until Android closes the app's screen).
- The built-in genre presets are gone. An EQ loaded from one stays as it is, shown as Custom.
- Auto preamp is now "Auto" under the preamp slider. It covers the largest boost from 0 Hz to half
  the sample rate (shelves keep rising below 20 Hz and above 20 kHz; 0.6.6 looked only from 20 Hz to
  20 kHz and could leave several dB), and the preamp now goes down to -24 dB.
- Auto turns amber when the preamp leaves more than 3 dB of boost to the clip guard.
- The headline names CarPlay when it plays ("CarPlay", or "CarPlay, no EQ").
- The navigation rail is narrower, which gives the EQ graph more room, and the graph starts closer
  to the preamp on both pages.

### Filter

- Filter version 323. Each band now runs over a block of samples at a time: the same output bit
  for bit (checked against the previous code on random settings), with 8-12% fewer instructions
  for the bands.
- Settings layout 3 (Expert's bands); the earlier layouts are still taken.
- The filter accepts only 16-bit stereo, the format Android 4.4's mixer uses; any other format is
  handed on unchanged and sized by its own layout.

### Starts and restarts

- At each car start the effects-list overlay is applied first, before anything else, and the boot
  step logs how close Android's audio server came to reading the list before it.
- If the audio server did read the factory list first, EQ Engine's screen offers to restart
  Android audio once (parked), in its own screen only, never as a pop-up over other apps.
- Turning EQ Engine back on no longer restarts Android audio by itself: it is offered with the
  usual parked-only confirmation.
- An audio server restart that comes with a restart of Android's whole framework is told apart from
  an audio server crash: it no longer steps the converter down. Every unexpected restart saves
  that moment's system log (All logs copies it).

### 48 kHz output

- The check of the link's real rate now puts 44.1 kHz back with the audio tracks held, like every
  other rate change (0.6.6 could skip the hold there).
- Status says "48 kHz, checking" until the link's rate has been measured.

### Settings, Status, Diagnostics

- Settings: EQ on CarPlay.
- Status: CarPlay's processing time, levels and rate while CarPlay plays.
- Diagnostics: the driver watch is no longer in the app. A CarPlay card shows what EQ on CarPlay
  is doing.
- The car report also shows whether EQ on CarPlay is loaded in the CarPlay app and how that app
  was started (symbol tables, checksums and properties only; no factory file is copied).

### Fixes (bugs in 0.6.6)

- Auto preamp could leave several dB of boost with shelves (see EQ page above).
- Turning EQ Engine back on could restart Android audio without asking.
- One of the 48 kHz put-backs could change the rate without holding the audio tracks.
- With a format other than 16-bit stereo (which this car does not use), the filter assumed 16-bit
  stereo when copying the audio through.

## 0.6.6

See the [0.6.6 release](https://github.com/alexkozler/Gen5W-EQ-Engine/releases/tag/v0.6.6).
