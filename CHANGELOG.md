# Changelog

## 0.7.5

The first release since 0.6.6. The versions in between (0.6.7 to 0.7.4) were test builds that were
only run on the test car. Version numbers now have one digit per part: after 0.6.9 came 0.7.0.

### New: EQ on CarPlay

- CarPlay's music, wired and wireless, gets EQ Engine's EQ (Easy or Expert), preamp, clip guard and
  listening position, with the same filter code as Android Auto, at CarPlay's own 44.1 kHz and with
  nothing converted. Added delay: 1.4 ms, plus the seat delay if set.
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
