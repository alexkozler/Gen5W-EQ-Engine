EQ Engine 0.6.4 (NEMESIS package "eqengine")
=============================================

A 10-band EQ and a listening-position delay for Android's main audio output
(Android Auto's music goes there; navigation and Android Auto's directions
voice use a second output that EQ Engine does not touch). The main output
runs at 48 kHz, so Android Auto's 48 kHz music is not converted at all.
CarPlay's music did not go through EQ Engine on the tested car (where it goes
is not known yet; see Car report). Loads at every start. Do everything below
parked, never while reversing.

Install
1. Make the rescue stick first: unzip eqengine-rescue-stick.zip onto the top
   level of its own USB stick and keep it in the glovebox.
2. Unzip eqengine-stick.zip onto the top level of this stick (NEMESIS.data,
   README-EQENGINE.txt, packages/ and EQENGINE-source/ at the root).
3. With the car on and Android running, plug this stick in, confirm the
   install, and wait for "Operation completed successfully".
4. Remove the stick and restart the car.
5. Open EQ Engine (NEMESIS Manager > My Packages > EQ Engine > Launch) and
   play some music. Status > Output should show "48 kHz, unconverted" within
   about 10 s.
If NEMESIS Manager shows "Warning: Activity not started, its current task
has been brought to the front", EQ Engine was already running: that is the
output of Android's am command, and EQ Engine opens normally.

Install over an earlier version
Plug in this stick, answer Yes to "Updating EQ Engine requires reinstalling",
wait for "Operation completed successfully", then restart the car. Your EQ
settings and User presets are kept.

Pages (rail on the left)
- EQ: drag a slider up or down anywhere in its column (a tap alone changes
  nothing); double-tap to reset it. The orange line is the EQ's real response.
  EQ switch = on/off (off is bit-exact). Auto preamp makes room for boosts;
  turn the car's volume up to make up the level. Presets at the bottom; hold a
  User preset to save the current EQ there.
- Position: pick Driver, Center or Passenger (or anything between). The side
  nearer that seat is delayed so both sides arrive together there (1.7 ms by
  default; Seat offset adjusts it). Tune it by ear from that seat with a
  centered voice: too much pulls the voice toward the far side, too little
  leaves it on the near side. Volumes stay with the car's balance and fader.
- Settings:
  - Equalizer, Clip guard.
  - 48 kHz output (on by default). At every car start and after every audio
    restart the main output switches to 48 kHz: while nothing plays if it
    can (a silent track of EQ Engine's keeps the link running for a few
    seconds, and the music then starts at 48 kHz with no gap), otherwise a
    few seconds after the music starts (a short gap in the sound). No audio
    restart. It is accepted only if Android, the driver's link setting and
    the rate the hardware really takes all say 48,000, and it is checked
    again each time the music starts. If anything is off, both go back to
    44.1 kHz for that audio server and the Lab line says why. If Android's
    audio server crashes right after a switch, 48 kHz output turns itself
    off here. At 48 kHz music that reaches full scale plays about 1.6 dB
    louder than at 44.1 kHz with Very high.
    Android 4.4 can leave audio tracks on a freed buffer when the output
    changes rate (silence, and possibly a crash of Android's audio). So for
    each change EQ Engine puts a disabled copy of its filter on every audio
    session of the main output, which makes Android move those tracks along,
    and checks afterwards that every track is on the new buffer. Without that
    hold there is no change. If a track is ever found on a freed buffer and
    cannot be moved back, the app says to restart Android audio (parked).
  - Audio converter (Lab): for voice prompts, and for music when the output
    is at 44.1 kHz.
  - EQ Engine on/off, detailed logging, Restart Android audio (parked only).
  - Save to USB: Report = the car report (see below); All logs = everything,
    private.
- Status: boot step, filter, output rate, processing time, levels, the log.
- Lab: Hyundai's own (partly hidden) sound pages (changes there are Hyundai
  settings and stay until you change them back), the converter, the driver
  watch, and a 120 s audio trace.

Converter (Lab: Stock, High, Very high; Very high is the default)
It converts the navigation and voice prompts (16 kHz up to 44.1 kHz), Android
Auto's music whenever the output is at 44.1 kHz, and anything not at 48 kHz.
- Stock = Android's default converter.
- High = Android's high-quality converter: at 44.1 kHz, the treble is 3.5 dB
  down at 16 kHz and 17 dB down at 20 kHz.
- Very high = Android's very high quality converter with EQ Engine's own
  filter tables: flat to 20 kHz (48 to 44.1 kHz), flat to 19 kHz (44.1 to
  48 kHz). It converts 1.6 dB quieter, so the conversion can never overflow.
- A choice asks "Restart audio now" or "Later" (from the next audio restart or
  car start). If EQ Engine's tables fail their check, that start uses High.
  Each unexpected audio server restart steps the choice down one level and
  keeps it; the Lab line says why.

Driver watch (Lab, off until you start it)
A pass-through layer in front of Hyundai's audio driver (an unchanged copy,
checked first) writes down what Android asks of the driver, and every 30 s the
rate each hardware link really runs at. It changes nothing in the audio. If
the driver's table looks unfamiliar, it hands everything over untouched and
says so. Switching it on or off restarts Android's audio (parked only); it
lasts until you stop it or the next car start. Its notes go into All logs.
(Switching it off detaches it while the audio server still has it loaded;
the restart then loads Hyundai's driver.)

Car report (Settings > Save to USB > Report)
Play some music first. It records 30 s and writes one text file,
EQENGINE/report_<software>_<time>.txt: the head unit's model and software, a
list of checks, the sound hardware, its rates and which process plays on each
link, and EQ Engine's own logs. For CarPlay, make one while CarPlay plays
music: it shows where CarPlay's sound goes.
Lines that could carry Bluetooth names or addresses, song details, a location,
serial numbers or a VIN are left out, and Hyundai's files are not copied. Read
it before you post it anywhere public. All logs, unlike the report, contain
your phone's name, Bluetooth addresses, song titles and possibly navigation
details: share them only privately.

Failsafes: firmware check, two-strike rule, crash watch, rescue stick. Off =
completely stock at the next start.

Turning it off: Settings > EQ Engine off (stock from the next start).
Removing it: NEMESIS Manager > My Packages > EQ Engine > Uninstall, then
restart the car.
Rescue stick (only if you cannot reach the app or NEMESIS Manager): plug it
in (with Android running, answer Yes), then restart the car. It turns EQ
Engine off, removes its in-memory changes and the driver watch, and resets the
converter.
