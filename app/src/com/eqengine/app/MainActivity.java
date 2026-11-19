package com.eqengine.app;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Typeface;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.text.TextUtils;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * EQ Engine 0.4. A navigation rail on the left (EQ, Position, Settings, Status, Lab) and five pages:
 * EQ (sliders, response curve, meter, presets), Position (listening position: an overhead view of
 * the car and a slider that times the speakers for one seat), Settings (switches and actions),
 * Status (what the boot step and the filter report, plus the log) and Lab (Hyundai's hidden sound
 * pages, an audio trace recorder and a converter comparison). Important events pop up in the bottom-right corner. The car's own top
 * bar stays visible; Back/Home leave the screen while the EQ keeps running in its service.
 * Every change is saved as soon as it is made, so the EQ is the same after leaving the screen
 * or restarting the car, whether or not it was saved as a preset.
 */
public class MainActivity extends Activity implements Engine.Listener, EqPanel.Listener, NavRail.Listener,
        CarView.Listener, HSlider.Listener {
    static final String VERSION = "0.6.1";
    private static final String ACT = "sh /data/eqengine/bin/act.sh";
    private static final String STATE = BootStatus.STATE_DIR;
    private static final String LAB = "/data/eqengine/lab";
    private static final int TRACE_SECONDS = 120;
    private static final String SS = "com.android.soundsettings/";

    private static boolean crashHandlerSet;

    private final Handler handler = new Handler();
    private Engine engine;
    private EqSettings s;
    private volatile boolean busy;
    private boolean restarting;
    private boolean labSwitch48; // the running Lab action only switches the 48 kHz output (no audio restart)
    private String convTarget;
    private TextView convLine, watchInfo, rateInfo;
    private final TextView[] convChips = new TextView[3];
    private static final int RESTART_COOLDOWN_S = 10;
    private boolean turningOff;
    private long turnedOnAt;
    private boolean autoRestarted;
    private String lastEngineState = "";
    private boolean wasAttached;
    private long traceEndsAt;
    private int page = NavRail.EQ;

    private NavRail rail;
    private Overlay overlay;
    private final View[] pages = new View[5];
    private EqPanel panel;
    private TextView eqSubtitle;
    private MSwitch eqSwitch, swEq, swGuard, swWatch, swRate48, swMaster, swLog;
    private CarView car;
    private HSlider posSlider;
    private TextView posTitle, posDetail, seatValue;
    private final TextView[] posChips = new TextView[3];
    private final TextView[] builtinChips = new TextView[EqSettings.BUILTIN_NAMES.length];
    private final TextView[] userChips = new TextView[EqSettings.USER_SLOTS];
    private HorizontalScrollView presetScroll;
    private String revealedPreset;
    private final TextView[] tileValue = new TextView[6];
    private final TextView[] tileDetail = new TextView[6];
    private TextView logView, logLevel, traceStatus, traceInfo;
    private TextView traceBtn;

    private final Runnable uiTick = new Runnable() {
        public void run() {
            refresh();
            handler.postDelayed(this, 1000);
        }
    };


    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        EqLog.init(getFilesDir());
        installCrashHandler();
        engine = Engine.get(this);
        s = engine.settings().copy();
        EqLog.i("EQ Engine " + VERSION + " screen opened (" + Build.DISPLAY + ")");
        buildUi();
        applyToViews();
        showPage(NavRail.EQ);
        startService(new Intent(this, EqService.class));
    }

    @Override
    protected void onResume() {
        super.onResume();
        engine.setListener(this);
        handler.post(uiTick);
    }

    @Override
    protected void onPause() {
        engine.setListener(null);
        handler.removeCallbacks(uiTick);
        s.save(this);
        super.onPause();
    }

    @Override
    public void onBackPressed() {
        if (overlay.handleBack()) return;
        super.onBackPressed();
    }

    // ------------------------------------------------------------------ navigation

    public void onRail(int item) {
        showPage(item);
    }

    private void showPage(int p) {
        page = p;
        for (int i = 0; i < pages.length; i++) pages[i].setVisibility(i == p ? View.VISIBLE : View.GONE);
        rail.select(p);
        refresh();
    }

    // ------------------------------------------------------------------ EQ

    public void onSlider(int col, int cdb, boolean done) {
        if (col == 0) s.preamp = cdb;
        else s.bands[col - 1] = cdb;
        if (col != 0) s.preset = "Custom";
        engine.update(s);
        if (done) {
            EqLog.d("slider " + (col == 0 ? "preamp" : EqSettings.LABELS[col - 1]) + " = " + EqSettings.db(cdb) + " dB");
            saveNow();
            updateEqHeader();
        }
    }

    public void onEngine() {
        int[] st = engine.stats();
        if (st != null) panel.setMeter(st[16], st[25], st[17], st[13] >= 0 && st[13] < 1500);
        else panel.setMeter(0, -10000, 10000, false);
        panel.setResponse(engine.response());
    }

    /** Saves the current EQ right away (a small file, written atomically), so every change survives. */
    private void saveNow() {
        s.save(this);
        EqLog.d("settings saved: " + s.describe());
    }

    private void applyAll(String why, boolean important) {
        applyToViews();
        engine.update(s);
        saveNow();
        if (important) EqLog.i(why + ": " + s.describe());
        else EqLog.d(why + ": " + s.describe());
    }

    /** Puts the settings into every view that shows them. */
    private void applyToViews() {
        panel.setValues(s);
        eqSwitch.setOn(s.eqOn, true);
        swEq.setOn(s.eqOn, true);
        swGuard.setOn(s.guard, true);
        swLog.setOn(s.detailedLog, true);
        updateEqHeader();
        updatePositionViews();
    }

    private void updateEqHeader() {
        eqSubtitle.setText(s.preset + "  ·  Preamp " + EqSettings.db(s.preamp) + " dB" + (s.eqOn ? "" : "  ·  EQ off"));
        for (int i = 0; i < builtinChips.length; i++) Ui.chipSelected(builtinChips[i], s.preset.equals(EqSettings.BUILTIN_NAMES[i]));
        if (!s.preset.equals(revealedPreset)) {
            revealedPreset = s.preset;
            revealPreset(s.preset, 0);
        }
        for (int i = 0; i < userChips.length; i++) {
            boolean has = EqSettings.loadUser(this, i + 1) != null;
            Ui.chipSelected(userChips[i], s.preset.equals("User " + (i + 1)));
            if (!has && !userChips[i].isSelected()) userChips[i].setTextColor(Ui.ON_SURFACE_VAR);
        }
    }

    /** Scrolls the built-in preset strip so the selected preset is in view (only when the preset changes). */
    private void revealPreset(final String name, final int tries) {
        presetScroll.post(new Runnable() {
            public void run() {
                if (!name.equals(s.preset)) return;
                int idx = -1;
                for (int i = 0; i < builtinChips.length; i++) if (EqSettings.BUILTIN_NAMES[i].equals(name)) idx = i;
                if (idx < 0) return;
                int w = presetScroll.getWidth();
                if (w == 0) {
                    if (tries < 10) revealPreset(name, tries + 1); // not laid out yet
                    return;
                }
                View c = builtinChips[idx];
                int x = presetScroll.getScrollX(), margin = dp(48); // the faded edge
                if (c.getLeft() < x + (idx == 0 ? 0 : margin)) presetScroll.smoothScrollTo(Math.max(0, c.getLeft() - margin), 0);
                else if (c.getRight() > x + w - margin) presetScroll.smoothScrollTo(c.getRight() - w + margin, 0);
            }
        });
    }

    private void setEq(boolean on) {
        s.eqOn = on;
        applyAll(on ? "EQ on" : "EQ off (bypass)", true);
    }

    /** Preamp = minus the EQ's largest boost, so nothing the EQ adds can clip. */
    private int largestBoost() {
        int peak = 0;
        int[] r = engine.response();
        if (r != null) {
            for (int v : r) if (v != Engine.RESP_NONE && v > peak) peak = v;
        } else {
            for (int v : s.bands) if (v > peak) peak = v;
        }
        return peak;
    }

    private void autoPreamp() {
        int peak = largestBoost();
        s.preamp = EqSettings.clamp(-((peak + EqSettings.STEP - 1) / EqSettings.STEP) * EqSettings.STEP, EqSettings.PRE_MIN, 0);
        applyAll("auto preamp", true);
        overlay.show(peak == 0 ? "No boost in this EQ: preamp set to 0 dB."
                : "Preamp " + EqSettings.db(s.preamp) + " dB makes room for the largest boost (" + EqSettings.db(peak)
                        + " dB). Turn the volume up a little to make up the level.", Overlay.INFO);
    }

    private void loadBuiltin(int i) {
        System.arraycopy(EqSettings.BUILTIN[i], 0, s.bands, 0, EqSettings.NB);
        int peak = 0;
        for (int v : s.bands) if (v > peak) peak = v;
        s.preamp = -peak;
        s.eqOn = true;
        s.preset = EqSettings.BUILTIN_NAMES[i];
        applyAll("preset " + s.preset, true);
    }

    private void loadUser(int slot) {
        int[] v = EqSettings.loadUser(this, slot);
        if (v == null) {
            overlay.show("User " + slot + " is empty. Press and hold it to save the current EQ there.", Overlay.INFO);
            return;
        }
        s.preamp = v[0];
        System.arraycopy(v, 1, s.bands, 0, EqSettings.NB);
        s.eqOn = true;
        s.preset = "User " + slot;
        applyAll("preset User " + slot, true);
    }

    private void saveUser(int slot) {
        boolean ok = EqSettings.saveUser(this, slot, s);
        if (ok) {
            s.preset = "User " + slot;
            saveNow();
            updateEqHeader();
        }
        overlay.show(ok ? "Saved the current EQ as User " + slot + "." : "Saving User " + slot + " failed.",
                ok ? Overlay.OK : Overlay.ERROR);
        EqLog.i("saved User " + slot + ": " + ok);
    }

    // ------------------------------------------------------------------ settings actions

    private void setGuard(boolean on) {
        s.guard = on;
        applyAll(on ? "clip guard on" : "clip guard off", true);
    }

    private void setLog(boolean on) {
        s.detailedLog = on;
        EqLog.detailed = on;
        applyAll(on ? "detailed logging on" : "detailed logging off", true);
    }

    // ------------------------------------------------------------------ listening position

    public void onPosition(int pos, boolean done) {
        setPosition(pos, done);
    }

    public void onSlide(int value, boolean done) {
        setPosition(value, done);
    }

    private void setPosition(int pos, boolean done) {
        s.position = pos;
        engine.update(s);
        updatePositionViews();
        if (done) {
            saveNow();
            EqLog.i("listening position " + s.positionName() + " (L " + s.delayUs(true) + " us, R " + s.delayUs(false) + " us)");
        }
    }

    private void stepSeatDelay(int dir) {
        s.seatDelayUs = EqSettings.clamp(s.seatDelayUs + dir * EqSettings.SEAT_DELAY_STEP, EqSettings.SEAT_DELAY_MIN,
                EqSettings.SEAT_DELAY_MAX);
        engine.update(s);
        saveNow();
        updatePositionViews();
    }

    private void updatePositionViews() {
        int dl = s.delayUs(true), dr = s.delayUs(false);
        int d = Math.max(dl, dr);
        car.setPosition(s.position, d / 1000f);
        posSlider.setValue(s.position);
        posTitle.setText(s.positionName());
        posDetail.setText(d == 0 ? "No delay: both sides play at the same time."
                : (dl > 0 ? "Left" : "Right") + " speakers delayed " + String.format(Locale.US, "%.2f ms", d / 1000.0)
                        + String.format(Locale.US, " (%.0f cm)", d / 1e6 * EqSettings.SPEED_OF_SOUND * 100)
                        + (s.eqOn ? "" : "\nEQ is off on the EQ page, so nothing is applied now."));
        seatValue.setText(String.format(Locale.US, "%.1f ms  (%.0f cm)", s.seatDelayUs / 1000.0,
                s.seatDelayUs / 1e6 * EqSettings.SPEED_OF_SOUND * 100));
        Ui.chipSelected(posChips[0], s.position == -100);
        Ui.chipSelected(posChips[1], s.position == 0);
        Ui.chipSelected(posChips[2], s.position == 100);
    }

    // ------------------------------------------------------------------ converter comparison (Lab)

    /**
     * The converter the running audio server uses. Android reads af.resampler.quality once per audio
     * server start, when it first converts audio, and logs "forcing AudioResampler quality to N"
     * then. That line (matched to the running server by its pid) is the truth; until it exists, the
     * property is what the server will use.
     */
    static final class ConvState {
        int pid = -1;
        String confirmed, confirmedAt, pending;
        /** This audio server set up its converter without EQ Engine's tables (Android logs it once). */
        boolean sincMissed;
        /** Confirmed by EQ Engine's tables converting audio in this server, not by its log line. */
        boolean byTables;

        /** " (audio server, 19:16:43)", or how it was confirmed. */
        String where() {
            return byTables ? " (EQ Engine's tables are converting)" : " (audio server, " + confirmedAt + ")";
        }

        String now() {
            return confirmed != null ? confirmed : pending;
        }

        boolean defaultActive() {
            return "0".equals(now());
        }
    }

    static String convName(String q) {
        return "4".equals(q) ? "very high quality" : "3".equals(q) ? "high quality" : "0".equals(q) ? "Android default"
                : q == null || q.length() == 0 ? "not set" : "quality " + q;
    }

    /** pid in a "-v time" log line: "... E/Tag(  123): ..." after the given tag, or -1. */
    private static int logPid(String line, String tag) {
        int a = line.indexOf(tag + "(");
        int b = a < 0 ? -1 : line.indexOf(')', a);
        if (b < 0) return -1;
        try {
            return Integer.parseInt(line.substring(a + tag.length() + 1, b).trim());
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    private static String sysprop(String key) {
        try {
            Class<?> sp = Class.forName("android.os.SystemProperties");
            return (String) sp.getMethod("get", String.class).invoke(null, key);
        } catch (Throwable t) {
            return null;
        }
    }

    static ConvState convState() {
        ConvState c = new ConvState();
        c.pending = sysprop("af.resampler.quality");
        c.pid = Root.mediaserverPid();
        if (c.pid <= 0) return c;
        for (String name : new String[] {"resampler.log.1", "resampler.log", "resampler_now.log"}) {
            BufferedReader r = null;
            try {
                r = new BufferedReader(new FileReader(STATE + "/" + name));
                String line;
                while ((line = r.readLine()) != null) {
                    if (line.indexOf("Could not open audio-resampler") >= 0) {
                        if (logPid(line, "AudioResamplerSinc") == c.pid) c.sincMissed = true;
                        continue;
                    }
                    int i = line.indexOf("forcing AudioResampler quality to ");
                    if (i < 0) continue;
                    if (logPid(line, "AudioResampler") != c.pid) continue;
                    c.confirmed = line.substring(i + 34).trim();
                    c.confirmedAt = line.length() >= 14 ? line.substring(6, 14) : "";
                }
            } catch (Throwable ignored) {
            } finally {
                Root.close(r);
            }
        }
        return c;
    }

    /**
     * convState(), plus what the filter in the audio server knows: EQ Engine's tables are asked for
     * only while Android converts with very high quality, so converted blocks confirm it even when
     * the audio server's own log line is missing.
     */
    private ConvState convStateNow() {
        ConvState c = convState();
        if (c.confirmed == null) {
            int[] st = engine.vhqStatus();
            if (st != null && st[0] == 1 && st[2] + st[3] > 0) {
                c.confirmed = "4";
                c.byTables = true;
            }
        }
        return c;
    }

    // ------------------------------------------------------------------ converter (Lab)

    private static final String[] CONV_Q = {"0", "3", "4"};
    private static final String[] CONV_LABEL = {"Stock", "High", "Very high"};

    /** Why the boot step stepped the converter down, while that is still the last change. */
    private String convCutReason() {
        File cut = new File(STATE + "/conv_cut");
        String why = Root.readFirstLine(cut);
        if (why == null) return null;
        // the boot step writes the reason and the setting together; a later change in the app hides it
        long d = EqSettings.converterFile(this).lastModified() - cut.lastModified();
        return d > 5000 || d < -5000 ? null : why.trim();
    }

    /**
     * What the converter does in the running audio server:
     * {line for the Status tile (null = nothing to add), line for the Lab, "warn" or ""}.
     */
    private String[] convStatus(ConvState c, String want) {
        String run = c.now();
        String where = c.confirmed != null && !c.byTables ? c.where() : "";
        String cut = convCutReason();
        if (cut != null) {
            return new String[] {"Stepped down to " + convName(want), "Stepped down to " + convName(want) + ": " + cut, "warn"};
        }
        String fallback = Root.readFirstLine(new File(STATE + "/conv_fallback"));
        if ("4".equals(want) && fallback != null && !"4".equals(run)) {
            return new String[] {"High quality this start", "Very high quality is not available this start (" + fallback.trim()
                    + "): high quality", "warn"};
        }
        if (run != null && !run.equals(want)) {
            return new String[] {null, "Now " + convName(run) + where + "; " + convName(want) + " from the next audio restart or car start", ""};
        }
        if ("3".equals(run)) return new String[] {null, "Using high quality" + where + ": Android's own tables", ""};
        if ("0".equals(run)) return new String[] {null, "Using Android's default converter" + where, ""};
        if (!"4".equals(run)) return new String[] {null, "Converter not set yet", ""};
        int[] st = engine.vhqStatus();
        // st[2], st[3]: blocks Android converted with the tables (it asks for them only in very high quality)
        if (st != null && st[0] == 1 && st[2] + st[3] > 0) {
            return new String[] {"EQ Engine's tables in use", "In use: EQ Engine's tables, " + st[4] + " taps a side" + where, ""};
        }
        if (c.sincMissed) {
            return new String[] {"Tables missed: high quality's in use", "Android set up its converter before EQ Engine's tables "
                    + "loaded: high quality's tables until the next audio restart", "warn"};
        }
        if (st != null && st[0] == -1) {
            return new String[] {"Tables did not load", "EQ Engine's tables did not load: high quality's tables", "warn"};
        }
        if (st != null && st[0] == 0) {
            return new String[] {"Tables not loaded", "This audio server started without EQ Engine's tables: high quality's tables", "warn"};
        }
        if (c.confirmed == null) {
            return new String[] {"Waiting for audio", (st != null ? "Tables loaded; " : "") + "starts when Android first converts audio", ""};
        }
        if (st != null && st[0] == 1) {
            return new String[] {"Tables ready, nothing converted yet", "Tables ready" + where + "; no audio converted with them yet", ""};
        }
        if (st == null) {
            return new String[] {"Table use shows with the EQ", "Very high quality" + where + "; table use shows once the EQ is connected", ""};
        }
        return new String[] {"Table use not confirmed", "Very high quality" + where + "; Android's use of the tables is not confirmed", ""};
    }

    private void syncConverterViews() {
        ConvState c = convStateNow();
        String want = EqSettings.readConverter(this);
        String shown = restarting && convTarget != null ? convTarget : want;
        for (int i = 0; i < 3; i++) {
            if (convChips[i] == null) continue;
            Ui.chipSelected(convChips[i], CONV_Q[i].equals(shown));
            convChips[i].setAlpha(restarting ? 0.45f : 1f);
        }
        LabState lab = labState();
        if (convLine != null) {
            String[] v = convStatus(c, want);
            if (restarting) {
                convLine.setText(labSwitch48 ? "Switching the main output's rate"
                        : convTarget != null ? "Switching to " + convName(convTarget) + ": audio is restarting"
                        : "Android's audio is restarting");
                convLine.setTextColor(Ui.SECONDARY);
            } else {
                convLine.setText(lab.rate48Live ? "48 kHz output test: Android Auto's 48 kHz music is not converted. " + v[1] : v[1]);
                convLine.setTextColor("warn".equals(v[2]) ? Ui.WARN : Ui.ON_SURFACE_VAR);
            }
        }
        syncLabViews(lab);
    }

    private void askConverter(final String q) {
        syncConverterViews(); // the chips show the saved choice until a choice is made
        if (busy || restarting) {
            overlay.show("Still working on the last action.", Overlay.WARN);
            return;
        }
        if (q.equals(EqSettings.readConverter(this))) return;
        if (!swMaster.isOn()) {
            overlay.show("EQ Engine is off. Turn it on in Settings first; the converter is set by EQ Engine's boot step.", Overlay.WARN);
            return;
        }
        String body = "4".equals(q)
                ? "Android's very high quality converter with EQ Engine's own filter tables: flat to 20 kHz, where Android's own "
                        + "tables are already 3 dB down at about 16 kHz. Converted audio plays 1.6 dB quieter (room so the "
                        + "conversion cannot overflow), and it costs about 1.6% of one processor core (measured on this car)."
                : "3".equals(q)
                ? "Android's high-quality converter with its own tables: the treble is 3 dB down at about 16 kHz and 17 dB "
                        + "down at 20 kHz."
                : "Android's default converter, the one the car uses without EQ Engine (lower quality), for comparisons.";
        body += " The choice stays for later car starts. If Android's audio restarts unexpectedly, EQ Engine steps it down "
                + "one level (very high, high, stock). Restarting gives a few seconds of silence: parked only.";
        overlay.confirm("Switch to " + convName(q) + "?", body, "Later", new Runnable() {
            public void run() {
                setConverter(q, false);
            }
        }, "Restart audio now", new Runnable() {
            public void run() {
                setConverter(q, true);
            }
        });
    }

    /** Saves the converter choice; now = restart Android's audio with it, else from the next audio server start. */
    private void setConverter(final String q, boolean now) {
        if (now && !canRestartNow()) return;
        final String before = EqSettings.readConverter(this);
        if (!EqSettings.writeConverter(this, q)) {
            overlay.show("The setting could not be saved.", Overlay.ERROR);
            return;
        }
        if (now) {
            EqLog.i("converter set to " + convName(q) + "; restarting Android's audio");
            convTarget = q;
            restartAudio(q, "Now using " + convName(q) + ".");
        } else {
            EqLog.i("converter set to " + convName(q) + " from the next audio restart or car start");
            rootAsync(ACT + " conv " + q, null, null, new Done() {
                public void done(boolean ok, String out) {
                    // (a failure is shown by rootAsync; the choice goes back to what it was)
                    if (!ok) EqSettings.writeConverter(MainActivity.this, before);
                    if (ok) overlay.show(cap(convName(q)) + " from the next audio restart or car start.", Overlay.OK);
                    syncConverterViews();
                }
            });
        }
        syncConverterViews();
    }

    // ------------------------------------------------------------------ Lab tests (driver watch, 48 kHz output)

    static final class LabState {
        boolean watch, rate48;   // in place now (state/lab_active)
        boolean rate48Live;      // the running audio server's main output runs at 48 kHz
        String rateLast, watchLast, ended; // last results from act.sh / the boot step
        String drvState, drvReason, drvMain;
    }

    private static final String DRV = "/data/eqengine/drv";

    private LabState labState() {
        LabState l = new LabState();
        String a = Root.readFirstLine(new File(STATE + "/lab_active"));
        if (a != null) {
            l.watch = a.contains("watch");
            l.rate48 = a.contains("rate48");
        }
        for (String line : Root.readLines(new File(STATE + "/lab_result"), 12)) {
            int sp = line.indexOf(' ');
            String t = sp > 0 ? line.substring(sp + 1) : line;
            if (t.startsWith("rate48 ")) l.rateLast = t.substring(7);
            else if (t.startsWith("watch ")) l.watchLast = t.substring(6);
            else if (t.startsWith("failed") || t.startsWith("ended")) l.ended = t;
            else if (t.startsWith("off")) l.ended = null;
        }
        l.rate48Live = l.rate48 && l.rateLast != null && l.rateLast.startsWith("accepted");
        if (l.watch) {
            for (String line : Root.readLines(new File(DRV + "/status"), 40)) {
                if (line.startsWith("state=")) l.drvState = line.substring(6);
                else if (line.startsWith("reason=")) l.drvReason = line.substring(7);
                else if (line.startsWith("link=pcm2p ") || line.startsWith("link=") && l.drvMain == null) {
                    l.drvMain = drvSummary(line);
                }
            }
        }
        return l;
    }

    /** "link=pcm2p card=0 owner=4258 rate=44100 fps=44100" -> "link pcm2p 44100 Hz, measured 44100 frames/s" */
    private static String drvSummary(String line) {
        String link = null, rate = null, fps = null;
        for (String f : line.split(" ")) {
            if (f.startsWith("link=")) link = f.substring(5);
            else if (f.startsWith("rate=")) rate = f.substring(5);
            else if (f.startsWith("fps=")) fps = f.substring(4);
        }
        StringBuilder b = new StringBuilder();
        if (link != null) b.append("link ").append(link);
        if (rate != null) b.append(b.length() > 0 ? " " : "").append(rate).append(" Hz");
        if (fps != null && !fps.equals("0")) b.append(", measured ").append(fps).append(" frames/s");
        return b.toString();
    }

    private void syncLabViews(LabState l) {
        if (swWatch == null) return;
        swWatch.setOn(l.watch, true);
        swRate48.setOn(l.rate48, true);
        swWatch.setAlpha(restarting ? 0.45f : 1f);
        swRate48.setAlpha(restarting ? 0.45f : 1f);
        String w, r;
        boolean ww = false, rw = false;
        if (l.watch) {
            if ("watching".equals(l.drvState)) w = "Watching" + (l.drvMain != null && l.drvMain.length() > 0 ? ": " + l.drvMain : "");
            else if ("pass-through".equals(l.drvState)) {
                w = "Pass-through only: " + (l.drvReason != null ? l.drvReason : "the driver's table looked unfamiliar");
                ww = true;
            } else if ("error".equals(l.drvState)) {
                w = "Error: " + (l.drvReason != null ? l.drvReason : "see the saved logs");
                ww = true;
            } else w = "On; no notes yet";
        } else if (l.ended != null && l.ended.contains("watch")) {
            w = cap(l.ended);
            ww = true;
        } else w = "Off. Writes down Android's calls to Hyundai's driver and measures the link, until the next car start";
        if (l.rate48) {
            r = l.rateLast != null ? rateShort(l.rateLast) : "On";
        } else if (l.ended != null && (l.ended.contains("rate48") || l.ended.contains("48 kHz"))) {
            r = cap(l.ended);
            rw = true;
        } else if (l.rateLast != null && l.rateLast.startsWith("refused")) {
            r = "Last try: " + rateShort(l.rateLast);
            rw = true;
        } else r = "Off. Asks Hyundai's driver to switch the main output to 48 kHz while music plays";
        watchInfo.setText(w);
        watchInfo.setTextColor(ww ? Ui.WARN : Ui.ON_SURFACE_VAR);
        rateInfo.setText(r);
        rateInfo.setTextColor(rw ? Ui.WARN : Ui.ON_SURFACE_VAR);
    }

    /**
     * act.sh's 48 kHz result, short enough for the Lab line (the whole line stays in the saved logs):
     * "accepted: output 101 at 48000 Hz, link pcm2p at 48000 Hz, measured 47998 frames/s; driver: ..." ->
     * "Accepted: link pcm2p at 48000 Hz, measured 47998 frames/s";
     * "refused: the driver kept 44.1 kHz (driver answered -22; ...); driver: ...; back at 44.1 kHz" ->
     * "refused: the driver kept 44.1 kHz; back at 44.1 kHz".
     */
    static String rateShort(String t) {
        if (t.startsWith("accepted: ")) {
            int a = t.indexOf("link "), b = t.indexOf(';', a < 0 ? 0 : a);
            return a < 0 ? "Accepted" : "Accepted: " + (b < 0 ? t.substring(a) : t.substring(a, b));
        }
        if (t.startsWith("refused: ")) {
            int a = t.indexOf(" (driver answered");
            int b = t.lastIndexOf("; ");
            String what = a < 0 ? t : t.substring(0, a);
            return b > a && a >= 0 ? what + t.substring(b) : what;
        }
        return cap(t);
    }

    /** which: 0 = driver watch, 1 = 48 kHz output */
    private void askLab(final int which, final boolean on) {
        syncConverterViews(); // the switches show what is in place until the test has changed
        if (busy || restarting) {
            overlay.show("Still working on the last action.", Overlay.WARN);
            return;
        }
        if (!swMaster.isOn()) {
            overlay.show("EQ Engine is off. Turn it on in Settings first.", Overlay.WARN);
            return;
        }
        if (!canRestartNow()) return;
        LabState l = labState();
        final boolean w = which == 0 ? on : l.watch;
        final boolean r = which == 1 ? on : l.rate48;
        String title, body;
        if (which == 1 && on) {
            title = "Try a 48 kHz main output?";
            body = "Play Android Auto's music first. EQ Engine then asks Hyundai's driver, through Android's own run-time setting, "
                    + "to switch the main output (Android Auto's music and EQ Engine) from 44,100 to 48,000 Hz while it plays. "
                    + "It counts as working only if Android, the driver's link setting and the rate the hardware really takes all "
                    + "say 48,000; then Android Auto's 48 kHz music plays with no conversion at all. Anything else is put back to "
                    + "44.1 kHz at once. Start at low volume: if the car's amplifier does not follow, music can play off pitch or "
                    + "crackle until you switch this off. Lasts until you switch it off, an audio restart or the next car start. "
                    + "No audio restart, a short gap in the sound. Parked only.";
        } else if (which == 0 && on) {
            title = "Watch Hyundai's audio driver?";
            body = "A pass-through layer in front of Hyundai's audio driver writes down what Android asks of it: stream set-ups, "
                    + "settings strings, volumes and modes. It also measures the rate each hardware link really runs at, from the "
                    + "kernel's own counters. It changes nothing in the audio. It runs inside Android's audio server, which also "
                    + "runs the rear camera; if the audio server stops unexpectedly, EQ Engine removes the layer at once. Lasts "
                    + "until you switch it off or the next car start.";
        } else if (which == 1) {
            title = "Back to 44.1 kHz?";
            body = "Puts the main output back to 44,100 Hz. No audio restart, a short gap in the sound.";
        } else {
            title = "Stop watching the driver?";
            body = "Takes the layer away and restarts Android's audio without it.";
        }
        if (which == 0) body += " Restarts Android's audio: a few seconds of silence. Parked only, never while reversing (the "
                + "camera service restarts too).";
        overlay.confirm(title, body, on ? "Start test" : "Stop test", new Runnable() {
            public void run() {
                runLab(w, r);
            }
        });
    }

    private void runLab(boolean w, boolean r) {
        if (!canRestartNow()) return;
        restarting = true;
        labSwitch48 = w == labState().watch;
        engine.detachForRestart();
        EqLog.i("Lab tests: driver watch " + (w ? "on" : "off") + ", 48 kHz output " + (r ? "on" : "off"));
        syncConverterViews();
        rootAsync(ACT + " lab " + (w ? 1 : 0) + " " + (r ? 1 : 0), null, null, new Done() {
            public void done(boolean ok, String out) {
                restarting = false;
                labSwitch48 = false;
                engine.restartFinished();
                List<String> res = new ArrayList<String>();
                boolean bad = false;
                for (String l : out.split("\n")) {
                    l = l.trim();
                    if (!l.startsWith("EQE_LAB ")) continue;
                    String t = l.substring(8);
                    res.add(t.startsWith("rate48 ") ? "48 kHz " + rateShort(t.substring(7)) : t);
                    EqLog.i("Lab: " + t);
                    if (t.startsWith("failed") || t.contains("refused") || t.contains("not-loaded") || t.contains("pass-through")
                            || t.contains("error")) bad = true;
                }
                if (ok && !res.isEmpty()) overlay.show("Lab: " + TextUtils.join("; ", res), bad ? Overlay.WARN : Overlay.OK);
                else if (ok) overlay.show(messageLine(out), Overlay.OK);
                if (!ok && !res.isEmpty()) overlay.show("Lab: " + TextUtils.join("; ", res), Overlay.WARN);
                syncConverterViews();
            }
        });
    }

    // ------------------------------------------------------------------ audio restarts

    /** Seconds until act.sh allows another audio restart (0 = now); it keeps 10 s between them. */
    private static int restartWait() {
        String t = Root.readFirstLine(new File(STATE + "/last_restart"));
        if (t == null) return 0;
        try {
            long w = Long.parseLong(t.trim()) + RESTART_COOLDOWN_S - Root.uptimeSeconds();
            return w > 0 && w <= RESTART_COOLDOWN_S ? (int) w : 0;
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    private boolean canRestartNow() {
        if (busy || restarting) {
            overlay.show("Still working on the last action.", Overlay.WARN);
            return false;
        }
        int w = restartWait();
        if (w > 0) {
            overlay.show("Android's audio was restarted moments ago. Wait " + w + " s so the car's audio can finish reconnecting.",
                    Overlay.WARN);
            return false;
        }
        return true;
    }

    /**
     * Restarts Android's audio server through act.sh: one at a time, 10 s apart at least, and it
     * returns once Android has reconnected. act.sh also checks that whatever was playing plays again.
     */
    private void restartAudio(String converter, final String okText) {
        if (!canRestartNow()) return;
        final String fConverter = converter;
        restarting = true;
        engine.detachForRestart();
        rootAsync(ACT + " restart" + (converter == null ? "" : " " + converter), null, null, new Done() {
            public void done(boolean ok, String out) {
                restarting = false;
                convTarget = null;
                engine.restartFinished();
                List<String> stuck = new ArrayList<String>();
                String vhq = null;
                for (String l : out.split("\n")) {
                    l = l.trim();
                    if (l.startsWith("EQE_STUCK ")) stuck.add(appName(l.substring(10).trim()));
                    if (l.startsWith("EQE_VHQ ")) vhq = l.substring(8).trim();
                }
                if (vhq != null) EqLog.i("very high quality converter after the restart: " + vhq);
                // tables that fail their check: high quality instead (act.sh changed nothing)
                if (!ok && "4".equals(fConverter) && out.contains("failed their check")) {
                    EqSettings.writeConverter(MainActivity.this, "3");
                }
                if (!stuck.isEmpty()) {
                    String who = TextUtils.join(", ", stuck);
                    EqLog.w("after the audio restart, these streams did not play again: " + who);
                    overlay.show(who + " did not resume after the audio restart (an Android 4.4 issue). Try pause and play, or "
                            + "switch to Radio and back; if it stays silent, reconnect the phone.", Overlay.WARN);
                } else if (ok && "missed".equals(vhq)) {
                    overlay.show("Android set up its converter before EQ Engine's tables loaded, so it still uses high quality's tables. "
                            + "Another audio restart (parked) may catch it.", Overlay.WARN);
                } else if (ok && "not-loaded".equals(vhq)) {
                    overlay.show("EQ Engine's tables did not load into Android's audio server, so it uses high quality's tables. "
                            + "Saved logs would show why.", Overlay.WARN);
                } else if (ok && okText != null) {
                    overlay.show(okText, Overlay.OK);
                }
                syncConverterViews();
                if (ok) EqLog.i("audio restart: " + messageLine(out));
            }
        });
    }

    private static String appName(String pkg) {
        if (pkg.equals("com.google.android.projection.sink")) return "Android Auto's audio";
        if (pkg.startsWith("com.hkmc.bluetooth") || pkg.contains("bluetooth")) return "Bluetooth audio";
        if (pkg.equals("com.mnsoft.navi")) return "Navigation voice";
        return pkg;
    }

    private void askRestart() {
        if (!canRestartNow()) return;
        overlay.confirm("Restart Android audio?", "A few seconds of silence. Best done parked, never while reversing (the camera "
                + "service restarts too). Android Auto's music sometimes stays silent afterwards; EQ Engine checks and tells you.",
                "Restart", new Runnable() {
            public void run() {
                doRestart("on request");
            }
        });
    }

    private void doRestart(String why) {
        EqLog.i("restarting Android's audio server (" + why + ")");
        restartAudio(null, "Android audio restarted. The EQ reconnects by itself.");
    }

    private void askMaster(final boolean on) {
        if (on) {
            setMaster(true);
            return;
        }
        swMaster.setOn(true, false);
        overlay.confirm("Turn EQ Engine off?", "The EQ and the high-quality converter stop now, and later starts are completely "
                + "stock until you turn it back on here.", "Turn off", new Runnable() {
                    public void run() {
                        setMaster(false);
                    }
                });
    }

    private void setMaster(boolean on) {
        swMaster.setOn(on, true);
        if (on) {
            EqLog.i("turning EQ Engine back on");
            turnedOnAt = System.currentTimeMillis();
            autoRestarted = false;
            rootAsync(ACT + " on", "EQ Engine is on. It loads at every start.", null);
        } else {
            EqLog.i("turning EQ Engine off");
            turningOff = true;
            stopService(new Intent(this, EqService.class));
            engine.stop("turned off in the app");
            rootAsync(ACT + " off", "EQ Engine is off. The next start is completely stock.", null);
        }
    }

    private void openHyundai(String component, String name) {
        EqLog.i("opening Hyundai's " + name + " page (" + component + ")");
        rootAsync(ACT + " open " + SS + component, null, name);
    }

    private void startTrace() {
        if (traceEndsAt > System.currentTimeMillis()) return;
        traceEndsAt = System.currentTimeMillis() + (TRACE_SECONDS + 6) * 1000L;
        EqLog.i("audio trace started (" + TRACE_SECONDS + " s)");
        overlay.show("Recording " + TRACE_SECONDS + " seconds. Change sound settings, volume or sources now.", Overlay.INFO);
        final String cmd = ACT + " trace " + TRACE_SECONDS;
        new Thread(new Runnable() {
            public void run() {
                final String out = Root.run(cmd);
                EqLog.i("trace: " + out.trim());
                handler.post(new Runnable() {
                    public void run() {
                        traceEndsAt = 0;
                        overlay.show(out.contains("EQE_OK") ? "Audio trace saved. Settings > Save logs to USB copies it to the stick."
                                : "The audio trace failed: " + lastLine(out), out.contains("EQE_OK") ? Overlay.OK : Overlay.ERROR);
                        refresh();
                    }
                });
            }
        }, "eqengine-trace").start();
    }

    interface Done {
        void done(boolean ok, String out);
    }

    /** Runs a root action off the main thread; okText (or "Opened <name>") pops up when it worked. */
    private void rootAsync(final String cmd, final String okText, final String openedName) {
        rootAsync(cmd, okText, openedName, null);
    }

    private void rootAsync(final String cmd, final String okText, final String openedName, final Done after) {
        if (busy) {
            overlay.show("Still working on the last action.", Overlay.WARN);
            return;
        }
        busy = true;
        new Thread(new Runnable() {
            public void run() {
                final String out = Root.run(cmd);
                if (out.contains("EQE_OK")) EqLog.d("root: " + out.trim());
                else if (out.contains("EQE_WAIT")) EqLog.i("root command refused for now: " + lastLine(out));
                else EqLog.w("root command failed: " + cmd + " -> " + out.trim());
                handler.post(new Runnable() {
                    public void run() {
                        busy = false;
                        turningOff = false;
                        boolean ok = out.contains("EQE_OK");
                        if (out.contains("EQE_WAIT")) overlay.show(lastLine(out), Overlay.WARN);
                        else if (ok && okText != null) overlay.show(okText, Overlay.OK);
                        else if (!ok) overlay.show((openedName != null ? "Couldn't open " + openedName + ": " : "That didn't work: ")
                                + lastLine(out), Overlay.ERROR);
                        if (after != null) after.done(ok, out);
                        refresh();
                    }
                });
            }
        }, "eqengine-action").start();
    }

    /** The last line of an act.sh answer that is not one of its markers (EQE_OK, EQE_WAIT, exit code). */
    private static String messageLine(String out) {
        String[] l = out.trim().split("\n");
        for (int i = l.length - 1; i >= 0; i--) {
            String t = l[i].trim();
            if (t.length() > 0 && !t.startsWith("(exit") && !t.startsWith("EQE_")) return t;
        }
        return out.trim();
    }

    private static String lastLine(String out) {
        String[] l = out.trim().split("\n");
        for (int i = l.length - 1; i >= 0; i--) {
            String t = l[i].trim();
            if (t.length() > 0 && !t.startsWith("(exit")) return t;
        }
        return out.trim();
    }

    private void saveLogs() {
        List<String> roots = Root.usbRoots();
        if (roots.isEmpty()) {
            overlay.show("No USB stick is mounted. Plug one in (not the rescue stick) and tap Save again.", Overlay.WARN);
            return;
        }
        File log = EqLog.file();
        String appDir = log != null ? log.getParentFile().getAbsolutePath() : getFilesDir().getAbsolutePath();
        EqLog.i("saving logs to USB");
        overlay.show("Saving logs to USB (about 10 seconds)...", Overlay.INFO);
        rootAsync(ACT + " save '" + roots.get(0) + "' '" + appDir + "' 1", "Logs saved to the USB stick, in the EQENGINE folder.", null);
    }

    private void installCrashHandler() {
        if (crashHandlerSet) return;
        crashHandlerSet = true;
        final Thread.UncaughtExceptionHandler previous = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {
            public void uncaughtException(Thread th, Throwable ex) {
                try {
                    EqLog.e("CRASH in thread " + th.getName(), ex);
                    List<String> roots = Root.usbRoots();
                    if (!roots.isEmpty())
                        Root.runBlocking(ACT + " save '" + roots.get(0) + "' '" + getFilesDir().getAbsolutePath() + "' 0", 8000);
                } catch (Throwable ignored) {
                }
                if (previous != null) previous.uncaughtException(th, ex);
                else System.exit(2);
            }
        });
    }

    // ------------------------------------------------------------------ periodic refresh

    private void refresh() {
        BootStatus bs = BootStatus.read();
        String est = engine.state();
        boolean attached = engine.attached();

        // events worth a pop-up
        if (attached && !wasAttached && lastEngineState.length() > 0) overlay.show("EQ connected to all music.", Overlay.OK);
        if (!attached && !est.equals(lastEngineState) && (est.startsWith("Android doesn't list") || est.startsWith("attaching failed")
                || est.startsWith("the stage 1") || est.startsWith("unexpected")))
            overlay.show(est, Overlay.WARN);
        if (!est.equals(lastEngineState) && est.startsWith("EQ Engine is off (crashed")) {
            overlay.show("EQ Engine turned itself off because Android's audio server kept restarting. Save logs and send them.",
                    Overlay.ERROR);
        }
        wasAttached = attached;
        lastEngineState = est;

        // EQ Engine was turned back on: make sure the service runs
        if (bs.allowed() && !engine.isRunning() && !turningOff) startService(new Intent(this, EqService.class));
        // Turned back on, but the audio server was restarted while EQ Engine was off and read the
        // stock effects list: restart it once more so it loads EQ Engine's.
        if (turnedOnAt > 0 && !autoRestarted && !busy && est.startsWith("Android doesn't list")) {
            if (System.currentTimeMillis() - turnedOnAt < 30000) {
                autoRestarted = true;
                overlay.show("Restarting Android audio once so it loads EQ Engine (about 2 seconds of silence).", Overlay.INFO);
                doRestart("after turning back on, the audio server didn't list EQ Engine");
            } else {
                turnedOnAt = 0;
            }
        }

        if (!turningOff && !busy) swMaster.setOn(!bs.finalOff(), true);
        rail.setBadge(NavRail.STATUS, est.startsWith("Android doesn't list") || bs.state().equals("crashed")
                || bs.state().equals("error") || bs.state().equals("refused"));

        if (page == NavRail.STATUS) refreshStatus(bs);
        if (page == NavRail.LAB) refreshLab();
        if (page == NavRail.POSITION) updatePositionViews();
    }

    private void refreshStatus(BootStatus bs) {
        String st = bs.state();
        String reason = bs.get("reason");
        boolean applied = "applied".equals(st);
        tile(0, st.length() == 0 ? "No status yet" : cap(st) + (applied && "1".equals(bs.get("good")) ? ", confirmed" : ""),
                (applied ? "Effects list in place \u00b7 strikes " + bs.get("strikes") : cap(reason))
                        + "\nUnexpected restarts " + bs.get("unexpected_restarts") + " \u00b7 service "
                        + ("1".equals(bs.get("service")) ? "started" : "not started yet"));
        long since = engine.attachedAt();
        tile(1, engine.attached() ? (s.eqOn ? "On all music" : "Connected, EQ off") : "Not connected",
                (since > 0 ? "Since " + new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date(since)) : cap(engine.state()))
                        + "\n" + s.preset + ", preamp " + EqSettings.db(s.preamp) + " dB");
        int[] x = engine.stats();
        ConvState cv = convStateNow();
        String q = cv.now();
        String[] vq = convStatus(cv, EqSettings.readConverter(this));
        LabState lab = labState();
        tile(2, restarting ? "Switching" : lab.rate48Live ? "48 kHz output (Lab)" : cap(convName(q)),
                (cv.byTables ? "Confirmed: EQ Engine's tables are converting"
                        : cv.confirmed != null ? "Audio server confirmed at " + cv.confirmedAt : "Not used yet by this audio server")
                        + "\n" + (cv.confirmed != null && cv.pending != null && !cv.pending.equals(cv.confirmed)
                        ? "Next audio restart: " + convName(cv.pending)
                        : lab.rate48Live ? "Android Auto plays unconverted"
                        : vq[0] != null ? vq[0] : "Converts Android Auto's 48 kHz audio"));
        if (x == null) {
            tile(3, "-", "No numbers while the EQ is not connected");
            tile(4, "-", "");
        } else {
            double bufUs = x[1] > 0 ? x[4] * 1e6 / x[1] : 0;
            tile(3, String.format(Locale.US, "%.1f%% of real time", bufUs > 0 ? x[9] / 10.0 / bufUs : 0),
                    String.format(Locale.US, "%.2f ms per %.0f ms buffer (max %.2f ms)\n%d Hz %s, %s", x[9] / 1e6, bufUs / 1000, x[10] / 1e6,
                            x[1], x[2] == 3 ? "stereo" : "ch 0x" + Integer.toHexString(x[2]),
                            x[13] < 0 ? "no audio yet" : x[13] > 1500 ? "no audio for " + (x[13] / 1000) + " s" : "audio flowing"));
            // average (RMS) level moves with the music; the input's peaks are at full scale on this car
            tile(4, x[25] <= -10000 ? "Silent" : String.format(Locale.US, "Average %.1f dBFS", x[25] / 100.0),
                    "Peaks: in " + Engine.dbfsShort(Math.max(x[11], x[12])) + ", out " + Engine.dbfsShort(x[16]) + " dBFS"
                            + "\nArrived clipped " + x[27] + " \u00b7 guard "
                            + (x[17] >= 9999 ? "idle" : String.format(Locale.US, "%.1f dB", 20 * Math.log10(x[17] / 10000.0))));
        }
        tile(5, engine.isRunning() ? "Service running" : "Service stopped",
                "EQ Engine " + VERSION + " · log " + (s.detailedLog ? "detailed" : "normal") + "\nFilter "
                        + (x != null ? Integer.toHexString(x[19]) : "-") + " · " + (x != null && x[23] == 1 ? "processing" : "bit-exact path"));
        logLevel.setText(s.detailedLog ? "Detailed" : "Normal");
        logView.setText(EqLog.tailText());
    }

    private void tile(int i, String value, String detail) {
        tileValue[i].setText(value);
        tileDetail[i].setText(detail);
    }

    private static String cap(String t) {
        return t.length() == 0 ? t : Character.toUpperCase(t.charAt(0)) + t.substring(1);
    }

    private void refreshLab() {
        long left = (traceEndsAt - System.currentTimeMillis()) / 1000;
        if (traceEndsAt > 0 && left > 0) {
            traceStatus.setText("Recording... " + Math.max(0, left - 6) + " s left");
            traceStatus.setTextColor(Ui.SECONDARY);
            traceBtn.setEnabled(false);
        } else {
            traceBtn.setEnabled(true);
            String last = lastTrace();
            traceStatus.setText(last == null ? "No trace recorded yet." : "Last trace: " + last);
            traceStatus.setTextColor(Ui.ON_SURFACE_VAR);
        }
        syncConverterViews();
        String alsa = Root.readFirstLine(new File(LAB + "/alsa_summary.txt"));
        traceInfo.setText(alsa == null ? "" : "ALSA mixer: " + alsa);
    }

    private static String lastTrace() {
        String[] names = new File(LAB).list();
        if (names == null) return null;
        String best = null;
        for (String n : names) if (n.startsWith("trace_") && (best == null || n.compareTo(best) > 0)) best = n;
        if (best == null) return null;
        String t = best.substring(6);
        if (t.length() >= 15) t = t.substring(9, 11) + ":" + t.substring(11, 13) + ":" + t.substring(13, 15) + " (" + t.substring(0, 4)
                + "-" + t.substring(4, 6) + "-" + t.substring(6, 8) + ")";
        return t;
    }

    // ------------------------------------------------------------------ layout

    private int dp(float v) {
        return Ui.dp(this, v);
    }

    private LinearLayout.LayoutParams lp(int w, int h, float weight) {
        return new LinearLayout.LayoutParams(w, h, weight);
    }

    private static final int MATCH = ViewGroup.LayoutParams.MATCH_PARENT, WRAP = ViewGroup.LayoutParams.WRAP_CONTENT;

    private void buildUi() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Ui.BG);
        LinearLayout main = new LinearLayout(this);
        main.setOrientation(LinearLayout.HORIZONTAL);
        rail = new NavRail(this);
        rail.setListener(this);
        main.addView(rail, lp(dp(116), MATCH, 0));
        FrameLayout content = new FrameLayout(this);
        main.addView(content, lp(0, MATCH, 1f));
        root.addView(main, new FrameLayout.LayoutParams(MATCH, MATCH));
        overlay = new Overlay(this);
        root.addView(overlay, new FrameLayout.LayoutParams(MATCH, MATCH));

        pages[NavRail.EQ] = buildEqPage();
        pages[NavRail.POSITION] = buildPositionPage();
        pages[NavRail.SETTINGS] = buildSettingsPage();
        pages[NavRail.STATUS] = buildStatusPage();
        pages[NavRail.LAB] = buildLabPage();
        for (View p : pages) content.addView(p, new FrameLayout.LayoutParams(MATCH, MATCH));
        setContentView(root);
    }

    private LinearLayout pageLayout() {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        l.setPadding(dp(20), dp(10), dp(20), dp(10));
        return l;
    }

    private LinearLayout header(String title, String sub, TextView[] subOut) {
        LinearLayout h = new LinearLayout(this);
        h.setOrientation(LinearLayout.HORIZONTAL);
        h.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout t = new LinearLayout(this);
        t.setOrientation(LinearLayout.VERTICAL);
        t.addView(Ui.text(this, title, 24, Ui.ON_SURFACE, true));
        TextView st = Ui.text(this, sub, 16, Ui.ON_SURFACE_VAR, false);
        st.setPadding(0, dp(4), 0, 0);
        t.addView(st);
        if (subOut != null) subOut[0] = st;
        h.addView(t, lp(0, WRAP, 1f));
        return h;
    }

    private View buildEqPage() {
        LinearLayout pg = pageLayout();
        TextView[] sub = new TextView[1];
        LinearLayout h = header("Equalizer", "", sub);
        eqSubtitle = sub[0];
        h.addView(Ui.button(this, "Auto preamp", Ui.OUTLINED, new View.OnClickListener() {
            public void onClick(View v) {
                autoPreamp();
            }
        }), lp(WRAP, dp(46), 0));
        View g = new View(this);
        h.addView(g, lp(dp(24), 1, 0));
        h.addView(Ui.text(this, "EQ", 18, Ui.ON_SURFACE, true));
        eqSwitch = new MSwitch(this);
        eqSwitch.setListener(new MSwitch.Listener() {
            public void onSwitch(MSwitch sw, boolean on) {
                setEq(on);
            }
        });
        h.addView(eqSwitch, lp(dp(68), dp(44), 0));
        pg.addView(h, lp(MATCH, dp(52), 0));

        panel = new EqPanel(this);
        panel.setListener(this);
        LinearLayout.LayoutParams plp = lp(MATCH, 0, 1f);
        plp.setMargins(0, dp(8), 0, dp(10));
        pg.addView(panel, plp);

        // preset row: the User presets stay put on the left; the built-in presets scroll by themselves
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        for (int i = 0; i < EqSettings.USER_SLOTS; i++) {
            final int slot = i + 1;
            TextView c = Ui.chip(this, "User " + slot, new View.OnClickListener() {
                public void onClick(View v) {
                    loadUser(slot);
                }
            }, true);
            c.setOnLongClickListener(new View.OnLongClickListener() {
                public boolean onLongClick(View v) {
                    saveUser(slot);
                    return true;
                }
            });
            userChips[i] = c;
            LinearLayout.LayoutParams cl = lp(WRAP, dp(42), 0);
            cl.setMargins(0, 0, dp(8), 0);
            row.addView(c, cl);
        }
        View sep = new View(this);
        sep.setBackgroundColor(Ui.OUTLINE);
        LinearLayout.LayoutParams sl = lp(dp(1), dp(28), 0);
        sl.setMargins(dp(6), 0, dp(14), 0);
        row.addView(sep, sl);
        HorizontalScrollView hs = new HorizontalScrollView(this);
        presetScroll = hs;
        hs.setHorizontalScrollBarEnabled(false);
        hs.setHorizontalFadingEdgeEnabled(true);
        hs.setFadingEdgeLength(dp(48));
        hs.setOverScrollMode(View.OVER_SCROLL_NEVER);
        LinearLayout chips = new LinearLayout(this);
        chips.setOrientation(LinearLayout.HORIZONTAL);
        chips.setGravity(Gravity.CENTER_VERTICAL);
        for (int i = 0; i < EqSettings.BUILTIN_NAMES.length; i++) {
            final int idx = i;
            TextView c = Ui.chip(this, EqSettings.BUILTIN_NAMES[i], new View.OnClickListener() {
                public void onClick(View v) {
                    loadBuiltin(idx);
                }
            });
            builtinChips[i] = c;
            LinearLayout.LayoutParams cl = lp(WRAP, dp(42), 0);
            cl.setMargins(0, 0, i == EqSettings.BUILTIN_NAMES.length - 1 ? 0 : dp(8), 0);
            chips.addView(c, cl);
        }
        hs.addView(chips);
        row.addView(hs, lp(0, dp(46), 1f));
        pg.addView(row, lp(MATCH, dp(46), 0));
        return pg;
    }

    private View buildSettingsPage() {
        LinearLayout pg = pageLayout();
        pg.addView(header("Settings", "Sound processing and EQ Engine itself", null), lp(MATCH, dp(52), 0));
        LinearLayout cols = new LinearLayout(this);
        cols.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams clp = lp(MATCH, 0, 1f);
        clp.setMargins(0, dp(10), 0, 0);
        pg.addView(cols, clp);

        LinearLayout sound = Ui.card(this, "Sound");
        swEq = new MSwitch(this);
        swEq.setListener(new MSwitch.Listener() {
            public void onSwitch(MSwitch sw, boolean on) {
                setEq(on);
            }
        });
        sound.addView(Ui.switchRow(this, "Equalizer", "Off passes the audio through untouched (bit-exact)", swEq));
        swGuard = new MSwitch(this);
        swGuard.setListener(new MSwitch.Listener() {
            public void onSwitch(MSwitch sw, boolean on) {
                setGuard(on);
            }
        });
        sound.addView(Ui.switchRow(this, "Clip guard", "Catches peaks that boosts push past full scale", swGuard));
        sound.addView(Ui.actionRow(this, "Audio converter", "Very high quality by default. Choose it, and try 48 kHz, in Lab",
                Ui.button(this, "Lab", Ui.TONAL, new View.OnClickListener() {
                    public void onClick(View v) {
                        showPage(NavRail.LAB);
                    }
                })));
        cols.addView(sound, lp(0, WRAP, 1f));
        View gap = new View(this);
        cols.addView(gap, lp(dp(16), 1, 0));

        LinearLayout eng = Ui.card(this, "EQ Engine");
        swMaster = new MSwitch(this);
        swMaster.setOn(true, false);
        swMaster.setListener(new MSwitch.Listener() {
            public void onSwitch(MSwitch sw, boolean on) {
                askMaster(on);
            }
        });
        eng.addView(Ui.switchRow(this, "EQ Engine", "Loads at every start. Off = stock audio", swMaster));
        swLog = new MSwitch(this);
        swLog.setListener(new MSwitch.Listener() {
            public void onSwitch(MSwitch sw, boolean on) {
                setLog(on);
            }
        });
        eng.addView(Ui.switchRow(this, "Detailed logging", "Logs every change, for troubleshooting", swLog));
        eng.addView(Ui.actionRow(this, "Restart Android audio", "A few seconds of silence. Parked only",
                Ui.button(this, "Restart", Ui.TONAL, new View.OnClickListener() {
                    public void onClick(View v) {
                        askRestart();
                    }
                })));
        eng.addView(Ui.actionRow(this, "Save logs to USB", "Into the EQENGINE folder on the stick",
                Ui.button(this, "Save", Ui.TONAL, new View.OnClickListener() {
                    public void onClick(View v) {
                        saveLogs();
                    }
                })));
        cols.addView(eng, lp(0, WRAP, 1f));

        TextView tip = Ui.text(this, "Tip: set the car's own Bass, Midrange and Treble to Center (Sound Settings > Tone) so EQ Engine is "
                + "the only tone control.", 15, Ui.ON_SURFACE_VAR, false);
        tip.setPadding(dp(4), dp(10), 0, 0);
        pg.addView(tip);
        return pg;
    }

    private static final String[] TILE_NAMES = {"Boot step", "EQ filter", "Converter", "Processing", "Levels", "App"};

    private View buildStatusPage() {
        LinearLayout pg = pageLayout();
        pg.addView(header("Status", "What the boot step and the filter report", null), lp(MATCH, dp(52), 0));
        LinearLayout cols = new LinearLayout(this);
        cols.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams clp = lp(MATCH, 0, 1f);
        clp.setMargins(0, dp(10), 0, 0);
        pg.addView(cols, clp);

        LinearLayout grid = new LinearLayout(this);
        grid.setOrientation(LinearLayout.VERTICAL);
        for (int row = 0; row < 3; row++) {
            LinearLayout r = new LinearLayout(this);
            r.setOrientation(LinearLayout.HORIZONTAL);
            for (int col = 0; col < 2; col++) {
                int i = row * 2 + col;
                LinearLayout t = new LinearLayout(this);
                t.setOrientation(LinearLayout.VERTICAL);
                t.setBackground(Ui.round(Ui.SURFACE, dp(14)));
                t.setPadding(dp(14), dp(8), dp(14), dp(6));
                t.addView(Ui.text(this, TILE_NAMES[i], 15, Ui.ON_SURFACE_VAR, false));
                tileValue[i] = Ui.text(this, "-", 21, Ui.ON_SURFACE, true);
                tileValue[i].setPadding(0, dp(3), 0, dp(3));
                tileValue[i].setSingleLine(true);
                tileValue[i].setEllipsize(android.text.TextUtils.TruncateAt.END);
                t.addView(tileValue[i]);
                tileDetail[i] = Ui.text(this, "", 14.5f, Ui.ON_SURFACE_VAR, false);
                tileDetail[i].setMaxLines(2);
                tileDetail[i].setEllipsize(android.text.TextUtils.TruncateAt.END);
                tileDetail[i].setLineSpacing(0, 1.1f);
                t.addView(tileDetail[i]);
                LinearLayout.LayoutParams tl = lp(0, MATCH, 1f);
                tl.setMargins(col == 0 ? 0 : dp(5), row == 0 ? 0 : dp(5), col == 0 ? dp(5) : 0, row == 2 ? 0 : dp(5));
                r.addView(t, tl);
            }
            grid.addView(r, lp(MATCH, 0, 1f));
        }
        cols.addView(grid, lp(0, MATCH, 1.25f));
        View gap = new View(this);
        cols.addView(gap, lp(dp(12), 1, 0));

        LinearLayout logCard = Ui.card(this, null);
        LinearLayout lh = new LinearLayout(this);
        lh.setGravity(Gravity.CENTER_VERTICAL);
        lh.addView(Ui.text(this, "Log", 19, Ui.ON_SURFACE, true), lp(0, WRAP, 1f));
        logLevel = Ui.text(this, "Normal", 15, Ui.ON_SURFACE_VAR, false);
        lh.addView(logLevel);
        logCard.addView(lh);
        ScrollView sv = new ScrollView(this);
        logView = Ui.text(this, "", 13.5f, Ui.ON_SURFACE_VAR, false);
        logView.setTypeface(Typeface.MONOSPACE);
        logView.setPadding(0, dp(8), 0, 0);
        sv.addView(logView);
        logCard.addView(sv, lp(MATCH, 0, 1f));
        cols.addView(logCard, lp(0, MATCH, 1f));
        return pg;
    }

    private View buildLabPage() {
        LinearLayout pg = pageLayout();
        pg.addView(header("Lab", "Experiments: Hyundai's hidden sound pages, the converter, driver tests and an audio trace", null),
                lp(MATCH, dp(52), 0));
        LinearLayout cols = new LinearLayout(this);
        cols.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams clp = lp(MATCH, 0, 1f);
        clp.setMargins(0, dp(10), 0, 0);
        pg.addView(cols, clp);

        LinearLayout hy = Ui.card(this, "Hyundai sound pages");
        TextView note = Ui.text(this, "Hyundai's own screens, including hidden ones. Changes there stay until you change them back.",
                15, Ui.ON_SURFACE_VAR, false);
        note.setLineSpacing(0, 1.1f);
        note.setPadding(0, 0, 0, dp(6));
        hy.addView(note);
        String[][] pages = {{"Premium Sound", "What the amplifier reports", ".sound.PremiumSound"},
                {"Sound Tuning", "Tone, fader and balance", ".sound.AudioTune"},
                {"Sound defaults", "Hyundai's sound reset", ".SoundDefault"}};
        for (final String[] pgi : pages) {
            LinearLayout.LayoutParams rl = lp(MATCH, WRAP, 0);
            rl.setMargins(0, dp(8), 0, 0);
            hy.addView(Ui.actionRow(this, pgi[0], pgi[1], Ui.button(this, "Open", Ui.TONAL, new View.OnClickListener() {
                public void onClick(View v) {
                    openHyundai(pgi[2], pgi[0]);
                }
            })), rl);
        }
        cols.addView(hy, lp(0, WRAP, 1f));
        View gap = new View(this);
        cols.addView(gap, lp(dp(16), 1, 0));

        LinearLayout cv = Ui.card(this, "Converter and driver");
        LinearLayout chips = new LinearLayout(this);
        for (int i = 0; i < 3; i++) {
            final String q = CONV_Q[i];
            convChips[i] = Ui.chip(this, CONV_LABEL[i], new View.OnClickListener() {
                public void onClick(View v) {
                    askConverter(q);
                }
            });
            LinearLayout.LayoutParams cl = lp(WRAP, dp(42), 0);
            cl.setMargins(0, 0, dp(8), 0);
            chips.addView(convChips[i], cl);
        }
        cv.addView(chips);
        convLine = Ui.text(this, "", 15, Ui.ON_SURFACE_VAR, false);
        convLine.setLineSpacing(0, 1.1f);
        convLine.setPadding(0, dp(8), 0, dp(8));
        cv.addView(convLine);
        cv.addView(Ui.divider(this));
        swRate48 = new MSwitch(this);
        swRate48.setListener(new MSwitch.Listener() {
            public void onSwitch(MSwitch sw, boolean on) {
                askLab(1, on);
            }
        });
        LinearLayout rateRow = Ui.switchRow(this, "48 kHz output (test)", "", swRate48);
        rateInfo = (TextView) ((LinearLayout) rateRow.getChildAt(0)).getChildAt(1);
        cv.addView(rateRow);
        swWatch = new MSwitch(this);
        swWatch.setListener(new MSwitch.Listener() {
            public void onSwitch(MSwitch sw, boolean on) {
                askLab(0, on);
            }
        });
        LinearLayout watchRow = Ui.switchRow(this, "Driver watch (test)", "", swWatch);
        watchInfo = (TextView) ((LinearLayout) watchRow.getChildAt(0)).getChildAt(1);
        cv.addView(watchRow);
        cols.addView(cv, lp(0, WRAP, 1.1f));
        View gap2 = new View(this);
        cols.addView(gap2, lp(dp(16), 1, 0));

        LinearLayout tr = Ui.card(this, "Audio trace");
        TextView d = Ui.text(this, "Records " + TRACE_SECONDS + " s of Android's system log and before/after snapshots of the "
                + "audio system. Change sound settings, volume or sources while it records. Settings > Save logs to USB copies "
                + "it to the stick with everything else.", 15, Ui.ON_SURFACE_VAR, false);
        d.setLineSpacing(0, 1.15f);
        tr.addView(d);
        LinearLayout br = new LinearLayout(this);
        br.setGravity(Gravity.CENTER_VERTICAL);
        br.setPadding(0, dp(14), 0, dp(6));
        traceBtn = Ui.button(this, "Record " + TRACE_SECONDS + " s", Ui.FILLED, new View.OnClickListener() {
            public void onClick(View v) {
                startTrace();
            }
        });
        br.addView(traceBtn, lp(WRAP, dp(46), 0));
        tr.addView(br);
        traceStatus = Ui.text(this, "", 16, Ui.ON_SURFACE_VAR, false);
        traceStatus.setPadding(0, dp(6), 0, 0);
        tr.addView(traceStatus);
        traceInfo = Ui.text(this, "", 15, Ui.ON_SURFACE_VAR, false);
        traceInfo.setPadding(0, dp(6), 0, dp(6));
        tr.addView(traceInfo);
        cols.addView(tr, lp(0, WRAP, 1f));
        return pg;
    }

    private View buildPositionPage() {
        LinearLayout pg = pageLayout();
        pg.addView(header("Listening position", "Times the speakers for one seat by delaying the side that is closer to it", null),
                lp(MATCH, dp(52), 0));
        LinearLayout cols = new LinearLayout(this);
        cols.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams clp = lp(MATCH, 0, 1f);
        clp.setMargins(0, dp(10), 0, 0);
        pg.addView(cols, clp);

        LinearLayout carCard = Ui.card(this, null);
        car = new CarView(this);
        car.setListener(this);
        carCard.addView(car, lp(MATCH, 0, 1f));
        posSlider = new HSlider(this);
        posSlider.setListener(this);
        carCard.addView(posSlider, lp(MATCH, dp(66), 0));
        cols.addView(carCard, lp(0, MATCH, 1.15f));
        View gap = new View(this);
        cols.addView(gap, lp(dp(16), 1, 0));

        LinearLayout info = Ui.card(this, null);
        posTitle = Ui.text(this, "", 26, Ui.SECONDARY, true);
        info.addView(posTitle);
        posDetail = Ui.text(this, "", 17, Ui.ON_SURFACE, false);
        posDetail.setPadding(0, dp(8), 0, dp(12));
        posDetail.setLineSpacing(0, 1.15f);
        info.addView(posDetail);
        LinearLayout chips = new LinearLayout(this);
        String[] names = {"Driver", "Center", "Passenger"};
        final int[] vals = {-100, 0, 100};
        for (int i = 0; i < 3; i++) {
            final int v = vals[i];
            posChips[i] = Ui.chip(this, names[i], new View.OnClickListener() {
                public void onClick(View vw) {
                    setPosition(v, true);
                }
            });
            LinearLayout.LayoutParams cl = lp(WRAP, dp(42), 0);
            cl.setMargins(0, 0, dp(8), 0);
            chips.addView(posChips[i], cl);
        }
        info.addView(chips);
        View g2 = new View(this);
        info.addView(g2, lp(1, dp(10), 0));
        info.addView(Ui.divider(this));
        LinearLayout seat = new LinearLayout(this);
        seat.setGravity(Gravity.CENTER_VERTICAL);
        seat.setPadding(0, dp(10), 0, dp(4));
        LinearLayout st = new LinearLayout(this);
        st.setOrientation(LinearLayout.VERTICAL);
        st.addView(Ui.text(this, "Seat offset", 18, Ui.ON_SURFACE, false));
        seatValue = Ui.text(this, "", 15, Ui.ON_SURFACE_VAR, false);
        seatValue.setPadding(0, dp(4), 0, 0);
        st.addView(seatValue);
        seat.addView(st, lp(0, WRAP, 1f));
        seat.addView(Ui.button(this, "\u2212", Ui.TONAL, new View.OnClickListener() {
            public void onClick(View v) {
                stepSeatDelay(-1);
            }
        }), lp(dp(64), dp(46), 0));
        View g3 = new View(this);
        seat.addView(g3, lp(dp(8), 1, 0));
        seat.addView(Ui.button(this, "+", Ui.TONAL, new View.OnClickListener() {
            public void onClick(View v) {
                stepSeatDelay(1);
            }
        }), lp(dp(64), dp(46), 0));
        info.addView(seat);
        TextView note = Ui.text(this, "How much farther the far side is from that seat. Tune it by ear from that seat with a "
                + "centered voice: too much pulls the voice toward the far side, too little leaves it on the near side. Each "
                + "side's front and rear speakers move together; the car's balance and fader still set the volumes.",
                14, Ui.ON_SURFACE_VAR, false);
        note.setLineSpacing(0, 1.15f);
        note.setPadding(0, dp(8), 0, 0);
        info.addView(note);
        cols.addView(info, lp(0, MATCH, 1f));
        return pg;
    }
}
