EQ Engine 0.6.0 (NEMESIS package "eqengine")
=============================================

A 10-band EQ and a listening-position delay for Android's main audio output
(Android Auto music goes there; navigation and Android Auto's directions
voice use a second output that EQ Engine does not touch), and Android's
best audio converter for Android Auto's 48 kHz audio. Loads at every start.

Install over an earlier version
Plug in this stick, answer Yes to "Updating EQ Engine requires reinstalling",
wait for "Operation completed successfully", then restart the car.
Your EQ settings and User presets are kept.

Pages (rail on the left)
- EQ: drag a slider up or down anywhere in its column (a tap alone changes
  nothing); double-tap to reset it. The orange line is the EQ's real response.
  EQ switch = on/off (off is bit-exact). Auto preamp makes room for boosts;
  turn the car's volume up to make up the level. Presets at the bottom; hold a
  User preset to save the current EQ there.
- Position: pick Driver, Center or Passenger (or anything between) on the
  slider or by dragging on the car. The side nearer that seat is delayed so
  both sides arrive together (1.7 ms by default; Seat offset adjusts it).
  It does not steer the sound toward that seat: it centers the sound for
  someone sitting there. Tune Seat offset by ear from that seat with a
  centered voice: too much pulls the voice toward the far side, too little
  leaves it on the near side.
  Volumes are still set by the car's balance and fader. Applies while the EQ
  switch is on.
- Settings: equalizer, clip guard, EQ Engine on/off, detailed logging,
  restart Android audio, and Save logs to USB (the one place to save logs;
  it includes the Lab's traces and the driver watch's notes).
- Status: boot step, filter, converter, processing time, levels, and the log.
- Lab: Hyundai's own (partly hidden) sound pages (Premium Sound, Sound
  Tuning, Sound defaults; changes there are Hyundai settings and stay until
  you change them back), the converter and the driver tests (below), and a
  120 s audio trace (system log + before/after snapshots).
  Each audio restart gives a few seconds of silence: parked only, never while
  reversing (the rear camera runs in the same Android service). At most one
  restart every 10 s. Android Auto's music sometimes stays silent after an
  audio restart (an Android 4.4 issue); EQ Engine checks and tells you.

Converter (Lab: Stock, High, Very high; Very high is the default)
- Android Auto's 48 kHz music is converted to the car's 44.1 kHz.
  Stock = Android's default converter (what the car uses without EQ Engine).
  High = Android's high-quality converter with its own tables: the treble is
  1 dB down at about 14 kHz, 3 dB down at about 16 kHz, 17 dB down at 20 kHz.
  Very high = Android's very high quality converter with EQ Engine's own
  filter tables (40 taps a side, 512 phases): flat (within 0.05 dB) to 20 kHz.
- Very high costs: converted audio plays 1.6 dB quieter (room so the
  conversion can never overflow; your logs showed this also stopped the
  clipped samples that High let through). Measured on this car: about 1.6% of
  one processor core more than High.
- A choice asks "Restart audio now" or "Later" (from the next audio restart
  or car start) and stays for later starts.
- Fallbacks: if EQ Engine's tables fail their check, that start uses High.
  Each unexpected audio server restart steps the choice down one level (Very
  high, High, Stock) and keeps it; the Lab line says why. Choose again to undo.
- Where it lives: /data/eqengine/lib/libaudio-resampler.so, loaded only into
  Android's audio server, only by EQ Engine's own filter, and only while Very
  high is chosen and the file matches its checksum. Nothing in /system changes.

Driver tests (Lab, new in 0.6.0, off until you start one; each lasts until you
stop it or the next car start, and needs one audio restart, parked)
- 48 kHz output: asks Hyundai's audio driver to run Android's main output at
  48,000 Hz instead of 44,100 (an in-memory copy of Android's audio policy with
  that one number changed, checked against the original first). If the driver
  and the car's amplifier take it, Android Auto's 48 kHz music plays with no
  conversion at all. EQ Engine checks the result: if the driver keeps
  44.1 kHz, or the audio server does not keep running, it removes the test and
  restarts audio again. Start at LOW volume: if the amplifier does not follow
  the new rate, music can play off pitch or crackle until you stop the test.
- Driver watch: a pass-through layer in front of Hyundai's audio driver
  (loaded from an unchanged copy, checked first) writes down what Android
  sends it: stream set-ups, settings strings, volumes, modes, and every 30 s
  what reaches each output (the rate the driver really takes the audio at,
  how long each write waits, levels). It changes nothing in the audio. If the
  driver's tables look unfamiliar it hands everything over untouched and says
  so. The notes go into Settings > Save logs to USB (drv_*.txt).
- Both run inside Android's audio server, which also runs the rear camera.
  If the audio server restarts unexpectedly while a test is on, EQ Engine
  removes the test at once (and that restart does not count against the
  converter or the failsafes).

Undo, any of these: stop the test or choose another converter in the Lab; a
car restart (driver tests); EQ Engine off in Settings; uninstall; the rescue
stick.

Failsafes: firmware check, two-strike rule, crash watch, rescue stick (it also
removes the driver tests and resets the converter). Off = completely stock at
the next start.

Removing it: NEMESIS Manager > My Packages > EQ Engine > Uninstall, then
restart the car.
