EQ Engine 0.7.7 (NEMESIS package "eqengine")
===========================================

A 10-band EQ (or a parametric one with up to 20 bands), clip guard and
listening-position delay for Android Auto, CarPlay (wired and wireless) and
Bluetooth audio. Android's main output runs at 48 kHz, so Android Auto's
48 kHz music is not converted at all; CarPlay plays at the rate the phone
sends (44.1 or 48 kHz), also unconverted. Navigation and Android Auto's
directions voice use a second output that EQ Engine does not touch; Siri and
calls are never processed.
Gen5W head units are in Hyundai, Kia and Genesis cars; see the project page
for the cars it has been tested on. Loads at every start. Do everything below
parked, never while reversing.

Install
1. Make the rescue stick first: unzip eqengine-rescue-stick-<version>.zip
   onto the top level of its own USB stick and keep it in the glovebox.
2. Unzip eqengine-stick-<version>.zip onto the top level of this stick
   (NEMESIS.data, README-EQENGINE.txt, packages/ and EQENGINE-source/ at the
   root). Always the -stick zip: the plain eqengine-<version>.zip of a
   release is the bare package for the NEMESIS Package Store, and does
   nothing on a stick by itself.
3. With the car on and Android running, plug this stick in, confirm the
   install, and leave the stick in until it has finished (the install writes
   its notes here): NEMESIS 1.16 says "Operation completed successfully";
   from NEMESIS 1.17, Package Manager lists EQ Engine under Installed.
4. Remove the stick and restart the head unit: turn the car off and on again
   (or use its reset pinhole). Until then EQ Engine is not loaded.
5. Open EQ Engine (NEMESIS Manager > My Packages > EQ Engine > Launch) and
   play some music. Status > Output should show "48 kHz, unconverted" within
   about 10 s with Android Auto, or "CarPlay, 44.1 kHz" (or 48 kHz) with
   CarPlay.
If NEMESIS Manager shows "Warning: Activity not started, its current task
has been brought to the front", EQ Engine was already running: that is the
output of Android's am command, and EQ Engine opens normally.
Other audio add-ons: EQ Engine never undoes another package's changes. If a
package or mod has changed Android's audio effects list
(/system/etc/audio_effects.conf, or added /vendor/etc/audio_effects.conf),
EQ Engine does not start at all (Android Auto, Bluetooth audio and CarPlay
alike), and its Status page says why. If one has laid its own file over the
CarPlay app's library, only EQ on CarPlay stays off, and the app tells you.
HMG-API and its wireless package are fine: the tested car runs them.

Install over an earlier version
Plug in this stick, answer Yes to "Updating EQ Engine requires reinstalling",
wait until it has finished (as in step 3 above), then restart the head unit
(turn the car off and on again). Your EQ
settings and User presets are kept (when the version you update from is this
one or later, even if the power goes off during the update). During the
install the EQ drops out for a few seconds, then comes back. Until the restart
Android's audio still has the old filter: 48 kHz output carries on, and the
new filter's features wait for the restart. If EQ on CarPlay was already
running, the CarPlay app keeps the old version's layer, with your EQ, until
then; otherwise CarPlay gets the EQ from that restart on. Detailed logging is
switched off by every update. There are no built-in genre presets since 0.7.5
(0.6.6 had them): an EQ loaded from one stays as it is (shown as Custom).
NEMESIS reinstalls the app at every update, so the signing key does not
matter here. A head unit software update (USB or over the air) normally
removes NEMESIS itself: reinstall NEMESIS (see its own README), and EQ Engine
if NEMESIS does not bring it back.
The install writes a diagnostic note to EQENGINE/ on this stick. It also
records a system log during the install, deleted again when the install
works; a log left there after a failed install holds personal data (phone
names, Bluetooth addresses, songs), so share it only privately.

Pages (rail on the left)
- EQ, Easy (the default): drag a slider up or down anywhere in its column (a
  tap alone changes nothing); double-tap to reset it. The orange line is the
  EQ's real response.
  - Peak/Shelf under the 31 Hz and 16 kHz sliders: tap to switch. A shelf
    also lifts or cuts everything below 31 Hz (or above 16 kHz); the slider
    still sets the level at 31 Hz (16 kHz). One setting, not part of presets.
  - Auto, under the preamp slider, makes room for the largest boost; turn the
    car's volume up to make up the level. It turns amber when the preamp
    leaves more than 3 dB of boost to the clip guard.
  - Switches at the top: Easy / Expert, Live (how loud each part of the range
    is, behind the curve; off by default and off again when you leave the
    app), Clip guard, and EQ on/off (off is bit-exact).
- EQ, Expert: a parametric EQ with up to 20 bands, for curves the 10 sliders
  cannot follow (a measured correction, say). The first switch asks whether
  to start from your Easy EQ (the same sound, as 10 bands) or flat; each mode
  keeps its own EQ, and switching never changes the other one. Each band is
  a dot, numbered by frequency from the left: drag it sideways for its
  frequency and up or down for its gain. The card on the right holds the
  selected band: the arrows step through the bands; type (Peak, Low shelf,
  High shelf, Low cut); frequency (-/+, or tap the value to type it); gain
  (-/+); width (a peak's bandwidth, shown as Q and octaves; a low cut's Q).
  + Add band and Delete band are at the bottom right.
  - Each dot shows its own band's gain; the orange line is all the bands
    added together, which is what you hear. Bands may overlap: where they
    do, their boosts and cuts add up, so several wide boosts side by side
    make a much bigger total than any one dot. The graph's scale grows
    (+-15, 27, 39 or 51 dB) so the orange line always fits; it changes when
    you let go of a dot, never under your finger.
- Both modes, bottom row: Flat (everything back to 0 dB; in Expert, no
  bands), User 1-4 (hold one to save the current EQ there; the four are
  shared, and one saved in the other mode switches to it), Curves on USB
  (save User 1-4 to the stick's EQENGINE_CURVES folder, to keep or share
  them, or load them from it) and Undo (steps back through up to 30 EQ
  changes; the list is lost when Android closes the app's screen).
- Position: pick Driver, Center or Passenger (or anything between). The side
  nearer that seat is delayed so both sides arrive together there (1.7 ms by
  default; Seat offset adjusts it). Tune it by ear from that seat with a
  centered voice: too much pulls the voice toward the far side, too little
  leaves it on the near side. Volumes stay with the car's balance and fader.
- Settings:
  - Equalizer, Clip guard.
  - 48 kHz output (on by default), for what plays through Android (Android
    Auto, Bluetooth audio). On a stock car Android converts Android Auto's
    48 kHz music to 44.1 kHz with its simplest converter (duller treble and
    false tones; see Converter below); at 48 kHz it is not converted at all.
    At every car start and after every audio restart the main output
    switches to 48 kHz: while nothing plays if it can (a
    silent track of EQ Engine's keeps the link running for a few seconds, and
    the music then starts at 48 kHz with no gap), otherwise a few seconds
    after the music starts (a short gap in the sound). No audio restart. It
    is accepted only if Android, the driver's link setting and the rate the
    hardware really takes all say 48,000, and it is checked again each time
    the music starts. If anything is off, both go back to 44.1 kHz for that
    audio server and the line under the switch says why. If Android's audio
    server crashes right after a switch, 48 kHz output turns itself off here.
    At 48 kHz music that reaches full scale plays about 1.6 dB louder than at
    44.1 kHz with Very high. CarPlay keeps its own rate (44.1 or 48 kHz).
    Each change works around an Android 4.4 fault that could leave audio
    tracks silent: EQ Engine holds every audio session of the main output for
    the change and checks every track afterwards. If one can't be moved back,
    the app says to restart Android audio (parked).
  - Audio converter (Stock, High, Very high): see below.
  - EQ Engine on/off, EQ on CarPlay (see below), Restart Android audio
    (parked only), and Factory sound settings (the car's own tone, fader and
    balance; set Bass, Midrange and Treble to Center so EQ Engine is the only
    tone control).
- Status: boot step, filter, output rate, processing time, levels, the log
  (CarPlay's figures while CarPlay plays). Its Diagnostics button opens:
  detailed logging, Save to USB (Report, All logs), Screenshot to USB (taken
  5 s after the tap, of whatever is on screen then, written to the stick
  only), a 120 s audio trace, and what EQ on CarPlay is doing.

Converter (Settings: Stock, High, Very high; Very high is the default)
It is used for Bluetooth audio (44.1 kHz up to 48 kHz) and for Android Auto's
music whenever the output is at 44.1 kHz. In Android 4.4's code it applies
only between 44.1 and 48 kHz: every other rate (navigation and voice prompts,
for example) gets Android's linear converter whatever this choice is, as on a
stock car. CarPlay is never converted.
- Stock = Android's default converter, linear interpolation, the one a stock
  car uses. It has no low-pass filter: from 48 to 44.1 kHz the treble is
  3.3 dB down at 16 kHz and 5.3 dB at 20 kHz, and each tone also comes out
  3.9 kHz lower (23 dB below a 10 kHz tone, 6 dB below a 20 kHz one).
- High = Android's high-quality converter: at 44.1 kHz, the treble is 3.5 dB
  down at 16 kHz and 17 dB down at 20 kHz.
- Very high = Android's very high quality converter with EQ Engine's own
  filter tables: flat to 20 kHz (48 to 44.1 kHz), flat to 19 kHz (44.1 to
  48 kHz). It converts 1.6 dB quieter, so the conversion can never overflow.
- A choice asks "Restart audio now" or "Later" (from the next audio restart or
  car start). If EQ Engine's tables fail their check, that start uses High.
  Each unexpected audio server restart steps the choice down one level and
  keeps it; the line under the choice says why.

EQ on CarPlay (Settings; on by default; wired or wireless CarPlay)
CarPlay's music does not go through Android's audio server: the factory
CarPlay app plays it to the speaker link itself. So at each car start, before
the CarPlay app starts, EQ Engine lays a layer over the app's JNI library (in
memory; nothing on the car is written). The app starts as it always does and
is not restarted for it (one exception: if the layer could not load, CarPlay
cannot work in that run of the app anyway, so EQ Engine takes the layer off
and restarts the app once, only with no phone connected; otherwise it asks
you to restart the car). The layer loads an unchanged copy of the car's own
library, hands everything to it, and runs EQ Engine's own filter on CarPlay's
music: the EQ page's settings (Easy or Expert), the preamp, clip guard and
listening position. It is checked first in a separate process, at the install
and again after a factory software update.
- CarPlay plays at the rate the phone sends, usually 44.1 kHz and sometimes
  48 kHz, so nothing is converted, and 48 kHz output and the converter do
  not apply to it. Added delay: 1.4 ms (the clip guard's look-ahead), plus
  the seat delay if you set one. The meter, live view and Status show
  CarPlay's music while it plays.
- Siri, calls and the microphone are never processed: while the microphone
  is open the music goes untouched until it closes.
- Off: CarPlay is flat at once (a short crossfade), and EQ Engine leaves the
  CarPlay app at the next car start. On: from the next car start (restart the
  car, parked), or at once when it was on at this car start (it is still in
  the CarPlay app until the next car start). EQ Engine off does the same as
  the switch off.
- Add-ons that hook the CarPlay app keep working with it: it was tested with
  HMG-API and its wireless CarPlay and Android Auto package, whose hooks and
  patches of the CarPlay libraries stay in place. It does not need HMG-API.
- If it cannot load, or the CarPlay app restarts twice within two minutes
  with it, it turns itself off (CarPlay then plays as without EQ Engine), and
  the app says so the next time you open it. If another package has laid a
  file over the CarPlay app's library, it stays off rather than covering it;
  EQ Engine only ever removes its own mounts. Please save All logs then and
  send them. If CarPlay misbehaves with it, turn it off and restart the car
  (parked), or use the rescue stick.
Its notes go into All logs and the report.

Car report (Status > Diagnostics > Save to USB > Report)
Play some music first. It records 30 s and writes one text file,
EQENGINE/report_<software>_<time>.txt: the head unit's model and software, a
list of checks, the sound hardware, its rates and which process plays on each
link, and EQ Engine's own logs.
Lines that could carry Bluetooth names or addresses, song details, a location,
serial numbers or a VIN are left out, and the car maker's files are not
copied. Read it before you post it anywhere public. All logs, unlike the
report, contain your phone's name, Bluetooth addresses, song titles and
possibly navigation details: share them only privately.

Logs on the head unit stay small: EQ Engine's own log rolls over at 256 KB
(one old copy is kept), and audio traces keep the newest two.

Failsafes: firmware check, two-strike rule, crash watch, rescue stick. Off =
completely stock at the next start.

Turning it off: Settings > EQ Engine off (stock from the next start).
Removing it: NEMESIS Manager > My Packages > EQ Engine > Uninstall, then
restart the head unit.
Rescue stick (only if you cannot reach the app or NEMESIS Manager): plug it
in (with Android running, answer Yes), then restart the head unit. It turns EQ
Engine off, removes its in-memory changes (the CarPlay layer from the next car
start), and resets the converter.
