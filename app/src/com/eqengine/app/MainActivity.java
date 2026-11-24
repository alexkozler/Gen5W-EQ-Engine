package com.eqengine.app;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.SystemClock;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.text.SimpleDateFormat;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * EQ Engine 0.7.7. A navigation rail on the left (EQ, Position, Settings, Status) and the pages:
 * EQ (Easy: ten sliders with the response curve and the output meter; Expert: a parametric curve
 * editor with up to 20 bands and a band card; the live view in both; Flat, four user slots both
 * modes share, Curves on USB and Undo), Position (listening position),
 * Settings (sound switches, the converter, EQ Engine itself), Status (what the boot step and the
 * filter report, plus the log) and Diagnostics, opened from Status (logging, saving to USB, the
 * audio trace, the driver watch). Important events pop up in the bottom-right corner. The car's
 * own top bar stays visible; Back/Home leave the screen while the EQ keeps running in its service.
 *
 * Threads: this screen's thread draws and makes the short calls to the filter in the audio
 * server. Everything that reads or writes files (the status shown here, settings, the log) runs on
 * one background thread (Bg), and root actions run on threads of their own, so a slow storage
 * write never holds up a slider. Every change is saved as soon as it is made.
 */
public class MainActivity extends Activity implements Engine.Listener, EqPanel.Listener, NavRail.Listener,
        CarView.Listener, HSlider.Listener, XPanel.Listener, WSlider.Listener {
    static final String VERSION = "0.7.7";
    private static final String ACT = "sh /data/eqengine/bin/act.sh";
    private static final String STATE = BootStatus.STATE_DIR;
    private static final String LAB = "/data/eqengine/lab";
    private static final int TRACE_SECONDS = 120;
    private static final int REPORT_SECONDS = 30;
    private static final String SS = "com.android.soundsettings/";
    /** The Diagnostics page: opened from Status, not on the rail. */
    private static final int DIAG = 4;
    private static final String JUST_INSTALLED = "EQ Engine was just installed. Restart the car (parked) and Android's audio "
            + "loads it; until then the EQ is not applied.";
    /** From the filter to the speakers when the link's own figure is not readable (0.6.4 car: about 150 ms). */
    private static final int DEFAULT_LATENCY_MS = 150;

    private static boolean crashHandlerSet;

    private final Handler handler = new Handler();
    private Engine engine;
    private EqSettings s;
    /*
     * (after 0.7.6) for the whole app, not this screen: a root action or an audio restart started on a
     * screen that was then closed (Back) still runs, and a new screen must not start a second one
     * alongside it
     */
    private static volatile boolean busy;
    private static volatile boolean restarting;
    /* (after 0.7.6) a result that came while no screen was in front: shown when one is again (never a
       pop-up over another app, which could cover the rear camera's picture) */
    private static String unseenText;
    private static int unseenKind;
    /* (after 0.7.6) the screen in front now, if any (a result from a closed one is shown there) */
    private static MainActivity front;
    private boolean resumed;
    private String lastOutWarn = "";
    private String convTarget;
    private TextView convLine, cpSub, cpInfoApp, cpInfoMusic, cpInfoEq, rate48Sub;
    /** EQ on CarPlay (0.7.4): a cpwatch action running; tried to bring it in step this screen; failure shown */
    private boolean cpBusy, cpSyncTried;
    private String cpFailShown = "";
    private String crashShown = "";
    private final TextView[] convChips = new TextView[3];
    private static final int RESTART_COOLDOWN_S = 10;
    private boolean turningOff;
    private long turnedOnAt;
    /** When the restart after turning back on was offered (0 = not yet); it is never made unasked. */
    private long onOfferedAt;
    private String lastEngineState = "";
    private boolean wasAttached;
    private long traceEndsAt;
    private int page = NavRail.EQ;
    /** The latest status read on the background thread. */
    private Snap snap = new Snap();
    /** The late-list prompt is offered once per audio server ("<boot id> <pid>"), for as long as the app runs. */
    private static String latePrompted = "";
    private boolean snapPending, snapAgain;
    /** Choices saved by this screen and not yet seen in a status read (null: none pending). */
    private String convWant;
    private Boolean rate48Want;
    private final boolean[] userHas = new boolean[EqSettings.USER_SLOTS];
    private boolean liveOn;
    private int[] lastResp;
    private final Delay levelQ = new Delay(), specQ = new Delay();
    private int logVersion = -1;

    private NavRail rail;
    private Overlay overlay;
    private final View[] pages = new View[5];
    private EqPanel panel;
    private LiveLayer live;
    private TextView eqSubtitle;
    private MSwitch eqSwitch, eqGuard, swLive, swEq, swGuard, swCp, swRate48, swMaster, swLog;
    private CarView car;
    private HSlider posSlider;
    private TextView posTitle, posDetail, seatValue;
    private final TextView[] posChips = new TextView[3];
    private final TextView[] userChips = new TextView[EqSettings.USER_SLOTS];
    private TextView flatChip, undoBtn, addBandBtn, delBandBtn;
    // Expert mode (0.6.11): the curve editor and its live view, the band card
    private XPanel xpanel;
    private LiveLayer liveX;
    private View easyBody, expertBody, bandRows;
    private Ui.Seg modeSeg;
    private TextView bandTitle, bandPrev, bandNext, bandEmpty, freqValue, gainValue, widthValue, widthNote;
    private TextView freqMinus, freqPlus, gainMinus, gainPlus;
    private final TextView[] typeChips = new TextView[4];
    private WSlider widthSlider;
    /** Undo: the EQ as it was before each change (newest first), and what a change in progress started from. */
    private final ArrayDeque<EqSettings> undo = new ArrayDeque<EqSettings>();
    private EqSettings undoBase;
    private static final int UNDO_MAX = 30;
    private final TextView[] tileValue = new TextView[6];
    private final TextView[] tileDetail = new TextView[6];
    private TextView logView, logLevel, traceStatus, traceInfo;
    private TextView traceBtn, shotBtn;
    private static final int SHOT_SECONDS = 5;
    private long shotAt;

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
        resumed = true;
        front = this;
        engine.setListener(this);
        updatePoll();
        handler.post(uiTick);
        String t = unseenText;
        if (t != null) {
            unseenText = null;
            overlay.show(t, unseenKind);
        }
    }

    /** An action's result: on this screen now, or (after 0.7.6) kept for when a screen is in front again. */
    private void tell(String text, int kind) {
        MainActivity f = front;
        if (f != null && f.resumed && !f.isFinishing()) {
            f.overlay.show(text, kind);
        } else {
            // the latest one counts, but a warning or error is not replaced by a plain "done"
            if (unseenText == null || kind != Overlay.OK || unseenKind == Overlay.OK) {
                unseenText = text;
                unseenKind = kind;
            }
        }
    }

    @Override
    protected void onPause() {
        resumed = false;
        if (front == this) front = null;
        engine.setListener(null);
        handler.removeCallbacks(uiTick);
        // the live view is off again whenever the screen is left
        if (liveOn) {
            liveOn = false;
            swLive.setOn(false, false);
            live.setSpectrumOn(false);
            liveX.setSpectrumOn(false);
            EqLog.d("live view off (left the screen)");
        }
        engine.setPoll(Engine.POLL_STATS);
        s.saveAsync(this);
        super.onPause();
    }

    @Override
    public void onBackPressed() {
        if (overlay.handleBack()) return;
        if (page == DIAG) {
            showPage(NavRail.STATUS);
            return;
        }
        super.onBackPressed();
    }

    // ------------------------------------------------------------------ navigation

    public void onRail(int item) {
        showPage(item);
    }

    private void showPage(int p) {
        page = p;
        for (int i = 0; i < pages.length; i++) pages[i].setVisibility(i == p ? View.VISIBLE : View.GONE);
        rail.select(p == DIAG ? NavRail.STATUS : p);
        updatePoll();
        applyViews();
        refresh();
    }

    /** How often the filter is read: fast for the EQ page's meter (and the live view), slow elsewhere. */
    private void updatePoll() {
        int mode = !resumed ? Engine.POLL_STATS : page != NavRail.EQ ? Engine.POLL_STATS
                : liveOn ? Engine.POLL_LIVE : Engine.POLL_METER;
        engine.setPoll(mode);
        if (mode == Engine.POLL_STATS) levelQ.clear();
        if (mode != Engine.POLL_LIVE) specQ.clear();
    }

    // ------------------------------------------------------------------ EQ

    public void onSlider(int col, int cdb, boolean done) {
        beginEdit();
        if (col == 0) s.preamp = cdb;
        else s.bands[col - 1] = cdb;
        if (col != 0) s.preset = "Custom";
        engine.update(s);
        if (done) {
            EqLog.d("slider " + (col == 0 ? "preamp" : EqSettings.LABELS[col - 1]) + " = " + EqSettings.db(cdb) + " dB");
            saveNow();
            updateEqHeader();
            endEdit();
        }
    }

    /** The Auto chip under the preamp (both modes). */
    public void onAuto() {
        autoPreamp();
    }

    public void onEndType(int col) {
        // (the 0.6.6 filter has the end-band types too: only an older one needs the next start)
        if (engine.olderFilter() && !engine.newFilter()) {
            overlay.show("Peak or shelf needs EQ Engine " + VERSION + "'s filter. Android's audio loads it at the next car start, "
                    + "or restart Android audio once (Settings, parked).", Overlay.WARN);
            return;
        }
        beginEdit();
        if (col == 1) s.lowShelf = !s.lowShelf;
        else s.highShelf = !s.highShelf;
        boolean shelf = col == 1 ? s.lowShelf : s.highShelf;
        applyAll((col == 1 ? "31 Hz" : "16 kHz") + " band: " + (shelf ? "shelf" : "peak"), true);
        endEdit();
        overlay.show(col == 1
                ? (shelf ? "31 Hz shelf: the slider also lifts or cuts everything below 31 Hz." : "31 Hz peak: the slider sets the octave around 31 Hz.")
                : (shelf ? "16 kHz shelf: the slider also lifts or cuts everything above 16 kHz." : "16 kHz peak: the slider sets the octave around 16 kHz."),
                Overlay.INFO);
    }

    public void onEngine() {
        int[] resp = engine.response();
        if (resp != lastResp) {
            lastResp = resp;
            panel.setResponse(resp);
        }
        if (page != NavRail.EQ) return;
        long now = SystemClock.uptimeMillis();
        int lat = snap.latencyMs > 0 ? snap.latencyMs : DEFAULT_LATENCY_MS;
        int[] st = engine.stats();
        // the Expert graph at the rate the music plays at: CarPlay's own while it plays (0.7.6)
        int[] cpr = engine.cpLive();
        if (CarPlayEq.playing(cpr) && CarPlayEq.rate(cpr) >= 8000) xpanel.setRate(CarPlayEq.rate(cpr));
        else if (st != null && st.length > 1) xpanel.setRate(st[1]);
        int[] lv = engine.level();
        if (lv != null) {
            // the 0.6.6 filter: each buffer's level, shown when it reaches the speakers
            if (lv[1] >= 0) levelQ.add(lv[0], now - lv[1], lv);
            int[] show = levelQ.at(now - lat, 400);
            if (show != null) live.setMeter(show[2], show[3], st != null ? st[17] : 10000, true);
            else live.setMeter(0, -10000, 10000, false);
        } else if (st != null) {
            live.setMeter(st[16], st[25], st[17], st[13] >= 0 && st[13] < 1500);
        } else {
            live.setMeter(0, -10000, 10000, false);
        }
        if (liveOn) {
            int[] sp = engine.spectrum();
            if (sp != null && sp[0] > 0 && sp[1] >= 0) specQ.add(sp[0], now - sp[1], sp);
            (s.expert ? liveX : live).setSpectrum(specQ.at(now - lat, 400));
        }
    }

    /** Saves the current EQ (on the background thread), so every change survives. */
    private void saveNow() {
        s.saveAsync(this);
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
        xpanel.setValues(s);
        eqSwitch.setOn(s.eqOn, true);
        eqGuard.setOn(s.guard, true);
        swEq.setOn(s.eqOn, true);
        swGuard.setOn(s.guard, true);
        swLog.setOn(s.detailedLog, true);
        swRate48.setOn(rate48(), true);
        syncMode();
        syncBandCard();
        syncUndo();
        updateEqHeader();
        updatePositionViews();
    }

    /** The headline: the playing mode's name (Expert: and its band count); the preamp is on its slider. */
    private void updateEqHeader() {
        String extra = s.eqOn ? "" : "  ·  EQ off";
        String src = sourceTag();
        if (src.length() > 0) extra += "  ·  " + src;
        String name = s.name();
        if (s.expert) name += "  ·  " + s.xb.size() + (s.xb.size() == 1 ? " band" : " bands");
        setText(eqSubtitle, name + extra);
        if (flatChip != null) Ui.chipSelected(flatChip, s.name().equals("Flat"));
        for (int i = 0; i < userChips.length; i++) {
            Ui.chipSelected(userChips[i], s.name().equals("User " + (i + 1)));
            if (!userHas[i] && !userChips[i].isSelected()) userChips[i].setTextColor(Ui.ON_SURFACE_VAR);
        }
    }

    /** Where the music comes from when it is CarPlay (0.7.4): "CarPlay" through EQ Engine, else "CarPlay, no EQ". */
    private String sourceTag() {
        int[] v = engine.cpLive();
        if (CarPlayEq.playing(v)) return CarPlayEq.why(v) == CarPlayEq.WHY_NONE ? "CarPlay" : "CarPlay, no EQ now";
        if (snap.out.other()) {
            String n = ownerName(snap.out.owner);
            return n + ", no EQ";
        }
        return "";
    }

    private void setEq(boolean on) {
        s.eqOn = on;
        applyAll(on ? "EQ on" : "EQ off (bypass)", true);
    }

    /** Live view on or off (EQ page). Off by default, and off again whenever the screen is left. */
    private void setLive(boolean on) {
        // (after 0.7.6) CarPlay's EQ shows its own live view: Android's filter is not needed for it
        if (on && !engine.attached() && !CarPlayEq.present()) {
            swLive.setOn(false, true);
            overlay.show("The live view needs the EQ connected to the music (Status shows why it is not).", Overlay.WARN);
            return;
        }
        if (on && engine.olderFilter() && !engine.newFilter()) {
            swLive.setOn(false, true);
            overlay.show("The live view needs EQ Engine " + VERSION + "'s filter. Android's audio loads it at the next car start, "
                    + "or restart Android audio once (Settings, parked).", Overlay.WARN);
            return;
        }
        liveOn = on;
        live.setSpectrumOn(on);
        liveX.setSpectrumOn(on);
        updatePoll();
        EqLog.d("live view " + (on ? "on" : "off"));
    }

    /**
     * The EQ's largest boost for settings x in 0.01 dB, and where in Hz ({cdb, hz}; hz -1 when not
     * known). From the filter's solved filters, 0 Hz to half the sample rate (Engine.peakFor): a
     * low shelf's boost goes on rising below the graph's 20 Hz, and the solver can set it well
     * above its slider. An older filter (until the next car start) cannot answer: then the graph's
     * points for the settings that play, or the sliders.
     */
    private int[] largestBoost(EqSettings x) {
        int[] q = engine.peakFor(x);
        if (q != null) return new int[] {Math.max(0, q[0]), q[1]};
        // (after 0.7.6) Android's filter cannot answer (not loaded in this start, an older one): the
        // CarPlay watch works the same answer out for the settings in use
        int[] a = CarPlayEq.answers(x);
        if (a != null) return new int[] {Math.max(0, a[0]), a[1]};
        int peak = 0;
        if (x.expert) {
            // Expert without the filter's answer: the bands' own curves, drawn from the same formulas
            double rate = engine.rate() > 0 ? engine.rate() : 48000;
            for (int i = 0; i <= 600; i++) {
                double f = i == 0 ? 0.0 : 20 * Math.pow(1000, (i - 1) / 599.0);
                double sum = 0;
                for (int[] b : x.xb) sum += XDesign.db(XDesign.coefs(b, rate), f, rate);
                peak = Math.max(peak, (int) Math.ceil(sum * 100));
            }
            return new int[] {peak, -1};
        }
        int[] r = x == s ? engine.response() : null;
        if (r != null) {
            for (int v : r) if (v != Engine.RESP_NONE && v > peak) peak = v;
        } else {
            for (int v : x.bands) if (v > peak) peak = v;
        }
        return new int[] {peak, -1};
    }

    /** Minus the boost, rounded down to the preamp's 0.5 dB steps (0.05 dB over is let through). */
    private static int preampFor(int peak) {
        int p = Math.max(0, peak - 5);
        return EqSettings.clamp(-((p + EqSettings.STEP - 1) / EqSettings.STEP) * EqSettings.STEP, EqSettings.PRE_MIN, 0);
    }

    private void autoPreamp() {
        int[] b = largestBoost(s);
        int peak = b[0];
        beginEdit();
        s.preamp = preampFor(peak);
        applyAll("auto preamp", true);
        endEdit();
        String where = b[1] < 0 ? "" : b[1] < 20 ? ", below 20 Hz" : b[1] > 20000 ? ", above 20 kHz" : "";
        EqLog.d("auto preamp: largest boost " + EqSettings.db(peak) + " dB" + (b[1] >= 0 ? " at " + b[1] + " Hz" : " (graph)"));
        overlay.show(peak <= 0 ? "No boost in this EQ: preamp set to 0 dB."
                : "Preamp " + EqSettings.db(s.preamp) + " dB makes room for the largest boost (" + EqSettings.db(peak)
                        + " dB" + where + "). Turn the volume up a little to make up the level.", Overlay.INFO);
    }

    /** Flat: Easy's sliders and the preamp to 0; in Expert, no bands. */
    private void doFlat() {
        beginEdit();
        if (s.expert) {
            s.xb.clear();
            s.xSel = 0;
        } else {
            s.bands = new int[EqSettings.NB];
        }
        s.preamp = 0;
        s.eqOn = true;
        s.setName("Flat");
        applyAll(s.expert ? "flat (Expert: no bands)" : "flat", true);
        endEdit();
    }

    private void loadUser(final int slot) {
        final Context ctx = getApplicationContext();
        Bg.run(new Runnable() {
            public void run() {
                final EqSettings.Slot v = EqSettings.loadUser(ctx, slot);
                Bg.main(new Runnable() {
                    public void run() {
                        applyUser(slot, v);
                    }
                });
            }
        });
    }

    /** A user slot: both modes share the four; one saved in the other mode switches to that mode. */
    private void applyUser(int slot, EqSettings.Slot v) {
        userHas[slot - 1] = v != null;
        if (v == null) {
            overlay.show("User " + slot + " is empty. Press and hold it to save the current EQ there.", Overlay.INFO);
            updateEqHeader();
            return;
        }
        if (v.expert && engine.attached() && !engine.expertFilter()) {
            overlay.show("User " + slot + " holds an Expert EQ, which needs EQ Engine " + VERSION + "'s filter. Android's audio "
                    + "loads it at the next car start, or restart Android audio once (Settings, parked).", Overlay.WARN);
            return;
        }
        beginEdit();
        s.preamp = v.preamp;
        s.expert = v.expert;
        if (v.expert) {
            s.expertSeen = true;
            s.xb = EqSettings.copyBands(v.xb);
            s.xSel = 0;
            s.sortBands();
        } else {
            System.arraycopy(v.bands, 0, s.bands, 0, EqSettings.NB);
        }
        s.eqOn = true;
        s.setName("User " + slot);
        applyAll("preset User " + slot + (v.expert ? " (Expert)" : ""), true);
        endEdit();
    }

    private void saveUser(final int slot) {
        final boolean expert = s.expert;
        EqSettings.saveUser(this, slot, s, new EqSettings.Saved() {
            public void saved(boolean ok) {
                if (ok) {
                    userHas[slot - 1] = true;
                    if (s.expert == expert) s.setName("User " + slot);
                    saveNow();
                    updateEqHeader();
                }
                overlay.show(ok ? "Saved the current " + (expert ? "Expert" : "Easy") + " EQ as User " + slot + "."
                        : "Saving User " + slot + " failed.", ok ? Overlay.OK : Overlay.ERROR);
                EqLog.i("saved User " + slot + " (" + (expert ? "Expert" : "Easy") + "): " + ok);
            }
        });
    }

    // ------------------------------------------------------------------ Undo

    /** Before a change to the EQ: remembers the EQ as it was (once for a whole drag). */
    private void beginEdit() {
        if (undoBase == null) undoBase = s.copy();
    }

    /** After it: the EQ as it was goes on the Undo list, if anything changed. */
    private void endEdit() {
        if (undoBase != null && !undoBase.eqKey().equals(s.eqKey())) {
            undo.push(undoBase);
            while (undo.size() > UNDO_MAX) undo.removeLast();
        }
        undoBase = null;
        syncUndo();
    }

    private void syncUndo() {
        if (undoBtn == null) return;
        undoBtn.setEnabled(!undo.isEmpty());
        undoBtn.setTextColor(undo.isEmpty() ? Ui.ON_SURFACE_VAR : Ui.ON_SURFACE);
    }

    /** Steps back one change of the EQ (its mode, bands, preamp and end-band types). */
    private void doUndo() {
        EqSettings p = undo.poll();
        if (p == null) {
            overlay.show("Nothing to undo.", Overlay.INFO);
            return;
        }
        s.takeEq(p);
        applyAll("undo", true);
    }

    // ------------------------------------------------------------------ Easy and Expert

    private void syncMode() {
        if (modeSeg == null) return;
        modeSeg.select(s.expert ? 1 : 0);
        easyBody.setVisibility(s.expert ? View.GONE : View.VISIBLE);
        expertBody.setVisibility(s.expert ? View.VISIBLE : View.GONE);
        addBandBtn.setVisibility(s.expert ? View.VISIBLE : View.GONE);
        delBandBtn.setVisibility(s.expert ? View.VISIBLE : View.GONE);
    }

    private void setMode(boolean expert) {
        if (expert == s.expert) {
            syncMode();
            return;
        }
        if (expert && engine.attached() && !engine.expertFilter()) {
            syncMode();
            overlay.show("Expert mode needs EQ Engine " + VERSION + "'s filter. Android's audio loads it at the next car start, "
                    + "or restart Android audio once (Settings, parked).", Overlay.WARN);
            return;
        }
        // the first switch, and any switch to an Expert EQ with no bands (nothing to lose there): start
        // flat or from the Easy EQ (0.7.3; switching modes never changes the other mode's EQ)
        if (expert && (!s.expertSeen || s.xb.isEmpty())) {
            syncMode();
            askExpertStart();
            return;
        }
        s.expert = expert;
        applyAll(expert ? "Expert mode" : "Easy mode", true);
    }

    private void askExpertStart() {
        overlay.confirm("Switch to Expert mode?", "Expert mode is a parametric EQ: up to 20 bands, each with its own frequency, "
                + "gain and width, for curves the 10 sliders cannot follow. Copy your Easy EQ to start from it: its 10 bands "
                + "become 10 bands here, with the same sound. The Easy EQ keeps its own settings; switch back at any time.",
                "Start flat", new Runnable() {
                    public void run() {
                        startExpert(false);
                    }
                }, "Copy Easy EQ", new Runnable() {
                    public void run() {
                        startExpert(true);
                    }
                });
    }

    /** The first switch to Expert: from the Easy EQ (the filter's solved bands) or flat. */
    private void startExpert(boolean copy) {
        beginEdit();
        int[] clamped = {0};
        // the solved gains from Android's filter, else (after 0.7.6) from the CarPlay watch, which has
        // the same solver; without either the sliders are copied as they are (close, not the same)
        int[] gains = copy ? engine.gains() : null;
        if (copy && gains == null) {
            int[] a = CarPlayEq.answers(s);
            if (a != null) {
                gains = new int[EqSettings.NB];
                System.arraycopy(a, 3, gains, 0, EqSettings.NB);
            }
        }
        final boolean same = gains != null;
        s.xb = copy ? EqSettings.fromEasy(s, gains, clamped) : new ArrayList<int[]>();
        s.xSel = 0;
        s.expert = true;
        s.expertSeen = true;
        if (copy) {
            s.xPreset = s.preset;
        } else {
            s.xPreset = "Flat";
            s.preamp = 0;
        }
        applyAll(copy ? "Expert mode, from the Easy EQ" : "Expert mode, flat", true);
        endEdit();
        if (clamped[0] > 0) {
            overlay.show(clamped[0] + (clamped[0] == 1 ? " band" : " bands") + " of the Easy EQ went past 15 dB and "
                    + (clamped[0] == 1 ? "was" : "were") + " set to 15 dB, the most a band takes here.", Overlay.WARN);
        } else {
            overlay.show(!copy ? "Expert mode: add bands with + Add band."
                    : same ? "Expert mode: your Easy EQ as 10 bands, with the same sound."
                    : "Expert mode: your Easy EQ's sliders as 10 bands. The EQ was not reachable to copy its exact curve, "
                            + "so it can sound a little different; check it on the graph.", Overlay.INFO);
        }
    }

    /** The band card: the selected band's values (or a note when there is none). */
    private void syncBandCard() {
        if (bandTitle == null) return;
        int[] b = s.sel();
        int n = s.xb.size();
        boolean has = b != null;
        // numbered by frequency, as the dots (0.7.4: also while one is dragged past another)
        setText(bandTitle, has ? "Band " + (s.rankOf(s.xSel) + 1) + " of " + n : "No bands");
        bandPrev.setEnabled(n > 1);
        bandNext.setEnabled(n > 1);
        bandPrev.setAlpha(n > 1 ? 1f : 0.4f);
        bandNext.setAlpha(n > 1 ? 1f : 0.4f);
        bandRows.setVisibility(has ? View.VISIBLE : View.INVISIBLE);
        bandEmpty.setVisibility(has ? View.GONE : View.VISIBLE);
        if (delBandBtn != null) {
            delBandBtn.setEnabled(has);
            delBandBtn.setAlpha(has ? 1f : 0.4f);
        }
        if (addBandBtn != null) addBandBtn.setAlpha(n < EqSettings.NX ? 1f : 0.4f);
        if (!has) return;
        for (int t = 0; t < 4; t++) Ui.chipSelected(typeChips[t], b[0] == t + 1);
        setText(freqValue, EqSettings.hz(b[1]));
        boolean cut = b[0] == EqSettings.X_LOW_CUT;
        setText(gainValue, cut ? "none (a cut)" : EqSettings.db1(b[2]) + " dB");
        gainMinus.setEnabled(!cut);
        gainPlus.setEnabled(!cut);
        gainMinus.setAlpha(cut ? 0.4f : 1f);
        gainPlus.setAlpha(cut ? 0.4f : 1f);
        // a shelf's slope is fixed: no slider, so the text has the whole row
        widthSlider.setVisibility(b[0] == EqSettings.X_PEAK || cut ? View.VISIBLE : View.GONE);
        if (b[0] == EqSettings.X_PEAK) {
            double bw = b[3] / 1000.0;
            setText(widthValue, String.format(Locale.US, "Q %.1f", XDesign.q(bw)));
            setText(widthNote, String.format(Locale.US, "%.2f octave", bw));
            widthSlider.set(widthPos(bw), true, "wide", "narrow");
        } else if (cut) {
            setText(widthValue, String.format(Locale.US, "Q %.2f", b[3] / 1000.0));
            setText(widthNote, b[3] == 707 ? "flattest" : "");
            widthSlider.set(Math.round((b[3] - EqSettings.X_QMIN) * 1000f / (EqSettings.X_QMAX - EqSettings.X_QMIN)), true,
                    "gentle", "peaked");
        } else {
            setText(widthValue, "Fixed slope");
            setText(widthNote, "as on the Easy page");
            widthSlider.set(0, false, "", "");
        }
    }

    /** A peak's bandwidth (octaves) on the Width slider: 4 octaves at the left, 0.1 at the right. */
    private static int widthPos(double bw) {
        return (int) Math.round((Math.log(4.0) - Math.log(bw)) / (Math.log(4.0) - Math.log(0.1)) * 1000);
    }

    /** A change to the selected band: made, put in range, played, and on the Undo list once done. */
    private void editBand(String why, boolean done, int[] b) {
        s.xb.set(s.xSel, EqSettings.clampBand(b));
        s.setName("Custom");
        if (done) {
            s.sortBands();
            applyAll(why, false);
            endEdit();
        } else {
            engine.update(s);
            xpanel.setValues(s);
            syncBandCard();
        }
    }

    // XPanel.Listener
    public void onPreamp(int cdb, boolean done) {
        beginEdit();
        s.preamp = cdb;
        engine.update(s);
        if (done) {
            EqLog.d("preamp = " + EqSettings.db(cdb) + " dB");
            saveNow();
            updateEqHeader();
            endEdit();
        }
    }

    public void onXSelect(int i) {
        s.xSel = i;
        xpanel.setValues(s);
        syncBandCard();
        saveNow();
    }

    public void onXMove(int i, int centiHz, int cdb, boolean done) {
        if (i < 0 || i >= s.xb.size()) return;
        beginEdit();
        s.xSel = i;
        int[] b = s.xb.get(i).clone();
        b[1] = centiHz;
        b[2] = cdb;
        s.xb.set(i, EqSettings.clampBand(b));
        s.setName("Custom");
        engine.update(s);
        syncBandCard();
        if (done) {
            s.sortBands();
            applyAll("band moved", false);
            endEdit();
        }
    }

    // WSlider.Listener: the selected band's width
    public void onWidth(int pos, boolean done) {
        int[] b = s.sel();
        if (b == null || (b[0] != EqSettings.X_PEAK && b[0] != EqSettings.X_LOW_CUT)) return;
        beginEdit();
        b = b.clone();
        if (b[0] == EqSettings.X_PEAK) {
            double bw = 4.0 * Math.pow(0.1 / 4.0, pos / 1000.0);
            b[3] = (int) Math.round(bw * 1000);
        } else {
            b[3] = Math.round(EqSettings.X_QMIN + pos / 1000f * (EqSettings.X_QMAX - EqSettings.X_QMIN));
        }
        editBand("band width", done, b);
    }

    private void stepBand(int dir) {
        int n = s.xb.size();
        if (n < 2) return;
        s.xSel = (s.sel() == null ? 0 : s.xSel + dir + n) % n;
        xpanel.setValues(s);
        syncBandCard();
        saveNow();
    }

    private void setType(int t) {
        int[] b = s.sel();
        if (b == null || b[0] == t) return;
        beginEdit();
        b = b.clone();
        b[0] = t;
        if (t == EqSettings.X_PEAK) b[3] = EqSettings.X_BW_DEFAULT;
        else if (t == EqSettings.X_LOW_CUT) b[3] = EqSettings.X_Q_DEFAULT;
        editBand("band type " + EqSettings.X_TYPES[t], true, b);
    }

    /** Frequency -/+: a 24th of an octave, rounded to three figures. */
    private void stepFreq(int dir) {
        int[] b = s.sel();
        if (b == null) return;
        beginEdit();
        b = b.clone();
        double hz = b[1] / 100.0 * Math.pow(2, dir / 24.0);
        int next = EqSettings.round3(hz);
        if (next == b[1]) next = b[1] + dir * 10;
        b[1] = next;
        editBand("band frequency", true, b);
    }

    private void typeFreq() {
        final int[] b = s.sel();
        if (b == null) return;
        String now = String.format(Locale.US, b[1] % 100 == 0 ? "%.0f" : "%.1f", b[1] / 100.0);
        overlay.prompt("Frequency", "In Hz, 20 to 20000.", now, "Set", new Overlay.Answer() {
            public void answer(String text) {
                double hz;
                try {
                    hz = Double.parseDouble(text.trim().replace(',', '.'));
                } catch (NumberFormatException e) {
                    overlay.show("\"" + text + "\" is not a frequency.", Overlay.WARN);
                    return;
                }
                if (hz < 20 || hz > 20000) {
                    overlay.show("The frequency must be between 20 and 20000 Hz.", Overlay.WARN);
                    return;
                }
                int[] c = s.sel();
                if (c == null) return;
                beginEdit();
                c = c.clone();
                c[1] = (int) Math.round(hz * 100);
                editBand("band frequency typed", true, c);
            }
        });
    }

    /** Gain -/+: 0.5 dB. */
    private void stepGain(int dir) {
        int[] b = s.sel();
        if (b == null || b[0] == EqSettings.X_LOW_CUT) return;
        beginEdit();
        b = b.clone();
        b[2] = EqSettings.snap(b[2] + dir * EqSettings.STEP);
        editBand("band gain", true, b);
    }

    /** + Add band: a 0 dB, one-octave peak in the widest gap between the bands there are. */
    private void addBand() {
        if (s.xb.size() >= EqSettings.NX) {
            overlay.show("Expert mode has " + EqSettings.NX + " bands at most. Delete one to add another.", Overlay.INFO);
            return;
        }
        double lo = Math.log(20), hi = Math.log(20000), at = Math.log(1000);
        if (!s.xb.isEmpty()) {
            double prev = lo, best = -1;
            for (int i = 0; i <= s.xb.size(); i++) {
                double next = i < s.xb.size() ? Math.log(s.xb.get(i)[1] / 100.0) : hi;
                if (next - prev > best) {
                    best = next - prev;
                    at = (prev + next) / 2;
                }
                prev = next;
            }
        }
        beginEdit();
        int[] b = EqSettings.clampBand(new int[] {EqSettings.X_PEAK, EqSettings.round3(Math.exp(at)), 0, EqSettings.X_BW_DEFAULT});
        s.xb.add(b);
        s.xSel = s.xb.size() - 1;
        s.sortBands();
        s.setName("Custom");
        applyAll("band added at " + EqSettings.hz(b[1]), false);
        endEdit();
    }

    private void deleteBand() {
        if (s.sel() == null) return;
        beginEdit();
        s.xb.remove(s.xSel);
        s.xSel = Math.max(0, s.xSel - 1);
        s.setName(s.xb.isEmpty() && s.preamp == 0 ? "Flat" : "Custom");
        applyAll("band deleted", false);
        endEdit();
    }

    // ------------------------------------------------------------------ Curves on USB

    /** The four user slots to or from the stick's EQENGINE_CURVES folder (act.sh curves), to keep or share. */
    private void askCurves() {
        withUsb(new Usb() {
            public void found(final List<String> roots) {
                if (roots.isEmpty()) {
                    overlay.show("No USB stick is mounted. Plug one in (not the rescue stick) and tap Curves on USB again.",
                            Overlay.WARN);
                    return;
                }
                overlay.confirm("Curves on USB", "Save copies User 1 to 4 to the stick's EQENGINE_CURVES folder, to keep them "
                        + "or to share them with other owners. Load puts the stick's curves into User 1 to 4, replacing what is "
                        + "there; a slot the stick has no curve for is left as it is.",
                        "Load from stick", new Runnable() {
                            public void run() {
                                runCurves("load", roots.get(0));
                            }
                        }, "Save to stick", new Runnable() {
                            public void run() {
                                runCurves("save", roots.get(0));
                            }
                        });
            }
        });
    }

    private void runCurves(final String what, String usb) {
        EqLog.i("curves " + what + " (USB)");
        rootAsync(ACT + " curves " + what + " '" + usb + "'", null, null, new Done() {
            public void done(boolean ok, String out) {
                if (!ok) return;
                String msg = null;
                for (String l : out.split("\n")) {
                    l = l.trim();
                    if (l.startsWith("EQE_CURVES ")) msg = l.substring(11);
                }
                tell(msg != null ? msg : what.equals("save") ? "Curves saved to the stick." : "Curves loaded from the stick.",
                        Overlay.OK);
                refresh();
            }
        });
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
        setText(posTitle, s.positionName());
        setText(posDetail, d == 0 ? "No delay: both sides play at the same time."
                : (dl > 0 ? "Left" : "Right") + " speakers delayed " + String.format(Locale.US, "%.2f ms", d / 1000.0)
                        + String.format(Locale.US, " (%.0f cm)", d / 1e6 * EqSettings.SPEED_OF_SOUND * 100)
                        + (s.eqOn ? "" : "\nEQ is off on the EQ page, so nothing is applied now."));
        setText(seatValue, String.format(Locale.US, "%.1f ms  (%.0f cm)", s.seatDelayUs / 1000.0,
                s.seatDelayUs / 1e6 * EqSettings.SPEED_OF_SOUND * 100));
        Ui.chipSelected(posChips[0], s.position == -100);
        Ui.chipSelected(posChips[1], s.position == 0);
        Ui.chipSelected(posChips[2], s.position == 100);
    }

    // ------------------------------------------------------------------ status read on the background thread

    /** Everything the screen shows that comes from files. Read by gather() on the background thread. */
    static final class Snap {
        BootStatus bs = BootStatus.empty();
        int msPid = -1;
        OutState out = new OutState();
        CpwFail cpwFail = new CpwFail();
        CpwState cpw = new CpwState();
        ConvState conv = new ConvState();
        String want = "4";
        boolean rate48 = true;
        String rate48Cut, convCut, convFallback;
        String lastTrace, alsa;
        boolean[] userHas = new boolean[EqSettings.USER_SLOTS];
        long lastRestart = -1;
        int latencyMs = -1;
        /** This start is the install's: its audio server cannot have EQ Engine's filter yet. */
        boolean justInstalled;
        /** The running audio server read the factory effects list before the boot step's overlay (state/late_list). */
        boolean lateList;
        String lateKey = "";
        boolean read;
    }

    private static int lastLatencyMs = -1;

    /** On the background thread only. */
    static Snap gather(Context ctx) {
        Snap n = new Snap();
        n.bs = BootStatus.read();
        n.msPid = Root.mediaserverPid();
        n.out = readOut(n.msPid);
        n.cpwFail = readCpwFail();
        n.cpw = readCpw();
        n.conv = convState(n.msPid);
        n.want = EqSettings.readConverter(ctx);
        n.rate48 = EqSettings.readRate48(ctx);
        n.rate48Cut = n.rate48 ? null : cutReason(EqSettings.rate48File(ctx), new File(STATE + "/rate48_cut"));
        n.convCut = cutReason(EqSettings.converterFile(ctx), new File(STATE + "/conv_cut"));
        String fb = Root.readFirstLine(new File(STATE + "/conv_fallback"));
        n.convFallback = fb == null ? null : fb.trim();
        n.lastTrace = lastTrace();
        n.alsa = Root.readFirstLine(new File(LAB + "/alsa_summary.txt"));
        for (int i = 0; i < n.userHas.length; i++) n.userHas[i] = EqSettings.loadUser(ctx, i + 1) != null;
        String lr = Root.readFirstLine(new File(STATE + "/last_restart"));
        try {
            n.lastRestart = lr == null ? -1 : Long.parseLong(lr.trim());
        } catch (NumberFormatException ignored) {
        }
        n.latencyMs = linkLatencyMs();
        // the boot step marks the install's start "installed" (state/lastboot) and says so in its reason
        String lb = Root.readFirstLine(new File(STATE + "/lastboot"));
        String bid = n.bs.get("boot_id");
        n.justInstalled = n.bs.get("reason").contains("just installed")
                || lb != null && bid.length() > 0 && lb.trim().equals(bid + " installed");
        // "<boot id> <audio server pid>": only while that audio server is the running one
        String ll = Root.readFirstLine(new File(STATE + "/late_list"));
        if (ll != null && bid.length() > 0) {
            String[] p = ll.trim().split(" ");
            if (p.length == 2 && p[0].equals(bid) && p[1].equals(String.valueOf(n.msPid))) {
                n.lateList = true;
                n.lateKey = ll.trim();
            }
        }
        n.read = true;
        return n;
    }

    /** Why the boot step changed a setting, while that is still the last change to it (they are written together). */
    private static String cutReason(File setting, File cut) {
        String why = Root.readFirstLine(cut);
        if (why == null) return null;
        long d = setting.lastModified() - cut.lastModified();
        return d > 5000 || d < -5000 ? null : why.trim();
    }

    /**
     * How long the main link takes to play what is written to it now: the frames waiting in its
     * buffer ("delay" in the kernel's status) over its rate. Kept from the last time it ran.
     */
    private static int linkLatencyMs() {
        int delay = -1, rate = -1;
        boolean running = false;
        for (String l : Root.readLines(new File("/proc/asound/card0/pcm2p/sub0/status"), 20)) {
            if (l.startsWith("state:")) running = l.contains("RUNNING");
            else if (l.startsWith("delay")) delay = parseAfterColon(l);
        }
        if (running && delay >= 0) {
            for (String l : Root.readLines(new File("/proc/asound/card0/pcm2p/sub0/hw_params"), 20))
                if (l.startsWith("rate:")) rate = parseAfterColon(l);
        }
        if (running && delay >= 0 && rate >= 8000) lastLatencyMs = (int) (delay * 1000L / rate);
        return lastLatencyMs;
    }

    private static int parseAfterColon(String l) {
        int c = l.indexOf(':');
        if (c < 0) return -1;
        String t = l.substring(c + 1).trim();
        int sp = t.indexOf(' ');
        if (sp > 0) t = t.substring(0, sp);
        try {
            return Integer.parseInt(t);
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    /** Reads the status again on the background thread, then shows it. */
    private void refresh() {
        if (snapPending) {
            snapAgain = true;
            return;
        }
        snapPending = true;
        final Context ctx = getApplicationContext();
        Bg.run(new Runnable() {
            public void run() {
                final Snap n = gather(ctx);
                Bg.main(new Runnable() {
                    public void run() {
                        snapPending = false;
                        applySnap(n);
                        if (snapAgain) {
                            snapAgain = false;
                            refresh();
                        }
                    }
                });
            }
        });
    }

    private String converter() {
        return convWant != null ? convWant : snap.want;
    }

    private boolean rate48() {
        return rate48Want != null ? rate48Want : snap.rate48;
    }

    // ------------------------------------------------------------------ converter

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

    /** On the background thread: the converter state of audio server msPid from its log copies. */
    static ConvState convState(int msPid) {
        ConvState c = new ConvState();
        c.pending = sysprop("af.resampler.quality");
        c.pid = msPid;
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
     * The snapshot's converter state, plus what the filter in the audio server knows: EQ Engine's
     * tables are asked for only while Android converts with very high quality, so converted blocks
     * confirm it even when the audio server's own log line is missing.
     */
    private ConvState convStateNow() {
        ConvState c = snap.conv;
        if (c.confirmed == null) {
            int[] st = engine.vhqStatus();
            if (st != null && st[0] == 1 && st[2] + st[3] > 0) {
                c.confirmed = "4";
                c.byTables = true;
            }
        }
        return c;
    }

    private static final String[] CONV_Q = {"0", "3", "4"};
    private static final String[] CONV_LABEL = {"Stock", "High", "Very high"};

    /**
     * What the converter does in the running audio server:
     * {line for the Status tile (null = nothing to add), line for Settings, "warn" or ""}.
     */
    private String[] convStatus(ConvState c, String want) {
        String run = c.now();
        String where = c.confirmed != null && !c.byTables ? c.where() : "";
        String cut = snap.convCut;
        if (cut != null) {
            return new String[] {"Stepped down to " + convName(want), "Stepped down to " + convName(want) + ": " + cut, "warn"};
        }
        String fallback = snap.convFallback;
        if ("4".equals(want) && fallback != null && !"4".equals(run)) {
            return new String[] {"High quality this start", "Very high quality is not available this start (" + fallback
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
        String want = converter();
        String shown = restarting && convTarget != null ? convTarget : want;
        for (int i = 0; i < 3; i++) {
            Ui.chipSelected(convChips[i], CONV_Q[i].equals(shown));
            convChips[i].setAlpha(restarting ? 0.45f : 1f);
        }
        String[] v = convStatus(c, want);
        if (restarting) {
            setText(convLine, convTarget != null ? "Switching to " + convName(convTarget) + ": audio is restarting"
                    : "Android's audio is restarting");
            convLine.setTextColor(Ui.SECONDARY);
        } else {
            // (at 48 kHz Android Auto's music is not converted at all; the 48 kHz row says so)
            // the converter is for Android's audio only: CarPlay plays at its own rate, never converted (0.7.3)
            setText(convLine, v[1] + (v[1].length() > 0 ? " · " : "") + "CarPlay is never converted");
            convLine.setTextColor("warn".equals(v[2]) ? Ui.WARN : Ui.ON_SURFACE_VAR);
        }
    }

    private void askConverter(final String q) {
        syncConverterViews(); // the chips show the saved choice until a choice is made
        if (busy || restarting) {
            overlay.show("Still working on the last action.", Overlay.WARN);
            return;
        }
        if (q.equals(converter())) return;
        if (!swMaster.isOn()) {
            overlay.show("EQ Engine is off. Turn it on first; the converter is set by EQ Engine's boot step.", Overlay.WARN);
            return;
        }
        String body = "4".equals(q)
                ? "Android's very high quality converter with EQ Engine's own filter tables: flat to 20 kHz, where Android's own "
                        + "tables are already 3 dB down at about 16 kHz. Converted audio plays 1.6 dB quieter (room so the "
                        + "conversion cannot overflow), and it costs about 1.6% of one processor core (measured on the test car)."
                : "3".equals(q)
                ? "Android's high-quality converter with its own tables: the treble is 3 dB down at about 16 kHz and 17 dB "
                        + "down at 20 kHz."
                : "Android's default converter, the one the car uses without EQ Engine (lower quality), for comparisons.";
        body += " With 48 kHz output on, Android Auto's music is not converted at all; this converter handles Bluetooth "
                + "audio and anything else at 44.1 kHz (voice prompts always get Android's simple converter). The choice stays for later car starts. If Android's audio "
                + "restarts unexpectedly, EQ Engine steps it down one level (very high, high, stock). Restarting gives a few "
                + "seconds of silence: parked only.";
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
    private void setConverter(final String q, final boolean now) {
        if (now && !canRestartNow()) return;
        final String before = converter();
        convWant = q;
        syncConverterViews();
        EqSettings.writeConverter(this, q, new EqSettings.Saved() {
            public void saved(boolean ok) {
                convWant = null;
                if (!ok) {
                    overlay.show("The setting could not be saved.", Overlay.ERROR);
                    snap.want = before;
                    syncConverterViews();
                    return;
                }
                snap.want = q;
                if (now) {
                    EqLog.i("converter set to " + convName(q) + "; restarting Android's audio");
                    convTarget = q;
                    restartAudio(q, "Now using " + convName(q) + ".");
                } else {
                    EqLog.i("converter set to " + convName(q) + " from the next audio restart or car start");
                    rootAsync(ACT + " conv " + q, null, null, new Done() {
                        public void done(boolean ok2, String out) {
                            // (a failure is shown by rootAsync; the choice goes back to what it was)
                            if (!ok2) {
                                snap.want = before;
                                EqSettings.writeConverter(MainActivity.this, before, null);
                            } else {
                                overlay.show(cap(convName(q)) + " from the next audio restart or car start.", Overlay.OK);
                            }
                            syncConverterViews();
                        }
                    });
                }
                syncConverterViews();
            }
        });
    }

    // ------------------------------------------------------------------ EQ on CarPlay (Settings, Diagnostics)

    /** act.sh cpwatch's state (state/cpwatch) and the watch's own status in the CarPlay app. */
    static final class CpwState {
        String state = "", note = "", pid = "";
        /** the stream on the main link (or the newest output), as one line; null before any */
        String main;
        int streams = -1;
        /** the watch's own state in the app (watching, not watching, failed) and HMG-API's hooks there (yes, no, ?) */
        String wstate = "", hmgapi = "";

        /** Turned on (0.6.10: it is laid over at each car start until it is turned off). */
        boolean on() {
            return "on".equals(state) || "waiting".equals(state) || "pending".equals(state);
        }
    }

    private static final String CPW = "/data/eqengine/cpw";

    /** On the background thread. */
    private static CpwState readCpw() {
        CpwState c = new CpwState();
        for (String line : Root.readLines(new File(STATE + "/cpwatch"), 10)) {
            int eq = line.indexOf('=');
            if (eq <= 0) continue;
            String k = line.substring(0, eq), v = line.substring(eq + 1).trim();
            if (k.equals("state")) c.state = v;
            else if (k.equals("note")) c.note = v;
            else if (k.equals("pid")) c.pid = v;
        }
        if ("on".equals(c.state) && c.pid.matches("[0-9]+")) {
            for (String line : Root.readLines(new File(CPW + "/status." + c.pid), 40)) {
                if (line.startsWith("main=")) c.main = cpwSummary(line.substring(5));
                else if (line.startsWith("state=")) c.wstate = line.substring(6).trim();
                else if (line.startsWith("hmgapi=")) c.hmgapi = line.substring(7).trim();
                else if (line.startsWith("streams=")) {
                    try {
                        c.streams = Integer.parseInt(line.substring(8).trim());
                    } catch (NumberFormatException ignored) {
                    }
                }
            }
        }
        return c;
    }

    /** "s1 card=0 device=2 dir=out rate=44100 ... state=open ... fps=44098 peak_db=-3.1" -> one line */
    static String cpwSummary(String line) {
        String card = "", dev = "", rate = "", fps = null, peak = null, st = "";
        for (String f : line.split(" ")) {
            if (f.startsWith("card=")) card = f.substring(5);
            else if (f.startsWith("device=")) dev = f.substring(7);
            else if (f.startsWith("rate=")) rate = f.substring(5);
            else if (f.startsWith("fps=")) fps = f.substring(4);
            else if (f.startsWith("peak_db=")) peak = f.substring(8);
            else if (f.startsWith("state=")) st = f.substring(6);
        }
        StringBuilder b = new StringBuilder();
        b.append("0".equals(card) && "2".equals(dev) ? "main link" : "card " + card + " device " + dev);
        b.append(' ').append(rate).append(" Hz");
        if (fps != null && !fps.equals("0")) b.append(", measured ").append(fps).append(" frames/s");
        if (peak != null) b.append(", peak ").append(peak).append(" dBFS");
        if (st.equals("closed")) b.append(" (closed)");
        return b.toString();
    }

    /** state/cpw_failed (act.sh, 0.7.4): the last time EQ on CarPlay turned itself off; id "" when never. */
    static final class CpwFail {
        String id = "", when = "", why = "";
    }

    /** On the background thread. */
    private static CpwFail readCpwFail() {
        CpwFail f = new CpwFail();
        for (String line : Root.readLines(new File(STATE + "/cpw_failed"), 10)) {
            int eq = line.indexOf('=');
            if (eq <= 0) continue;
            String k = line.substring(0, eq), v = line.substring(eq + 1).trim();
            if (k.equals("id")) f.id = v;
            else if (k.equals("when")) f.when = v;
            else if (k.equals("why")) f.why = v;
        }
        return f;
    }

    /** The Settings switch and its line, and the Diagnostics CarPlay card. */
    private void syncCpwViews() {
        CpwState c = snap.cpw;
        int[] v = engine.cpLive();
        if (swCp != null) {
            if (!cpBusy) swCp.setOn(s.cpEq, true);
            setText(cpSub, cpLine(c, v));
            cpSub.setTextColor(!s.cpEq && "failed".equals(c.state) ? Ui.WARN : Ui.ON_SURFACE_VAR);
        }
        if (cpInfoApp != null) {
            String app;
            boolean warn = false;
            if ("on".equals(c.state)) {
                if ("not watching".equals(c.wstate)) {
                    app = "Loaded at the car start, but it found no audio to work on (All logs say why)";
                    warn = true;
                } else app = "Loaded at the car start" + ("yes".equals(c.hmgapi) ? "; HMG-API's hooks are in the app too" : "");
            } else if ("waiting".equals(c.state)) app = "Laid over at the car start; the CarPlay app has not loaded it yet";
            else if ("pending".equals(c.state)) app = "Not loaded yet: from the next car start";
            else if ("ending".equals(c.state)) app = "Loaded until the next car start (the switch is off)";
            else if ("failed".equals(c.state)) {
                app = cap(snap.cpwFail.why.length() > 0 ? snap.cpwFail.why : c.note.length() > 0 ? c.note : "it failed; All logs say why");
                warn = true;
            } else if ("absent".equals(c.state)) app = "This unit has no factory CarPlay app";
            else app = "Not loaded";
            setText(cpInfoApp, app);
            cpInfoApp.setTextColor(warn ? Ui.WARN : Ui.ON_SURFACE_VAR);
            setText(cpInfoMusic, c.main != null ? cap(c.main) : "on".equals(c.state) ? "CarPlay has not played yet" : "-");
            setText(cpInfoEq, cpEqNow(c, v));
        }
    }

    /** The Settings row's line: what EQ on CarPlay does now. */
    private String cpLine(CpwState c, int[] v) {
        if (!swMaster.isOn()) return "EQ Engine is off";
        if ("absent".equals(c.state)) return "This unit has no factory CarPlay app";
        if (cpBusy) return s.cpEq ? "Turning on..." : "Turning off...";
        boolean loaded = "on".equals(c.state) || "waiting".equals(c.state) || "ending".equals(c.state);
        if (!s.cpEq) {
            if (loaded) return "Off: CarPlay is flat now; EQ Engine leaves the CarPlay app at the next car start";
            if ("failed".equals(c.state)) return "Turned itself off at this start; turn it on to try again from the next car start";
            return "Off: CarPlay plays without EQ Engine";
        }
        if ("on".equals(c.state)) {
            if (CarPlayEq.playing(v) && CarPlayEq.why(v) == CarPlayEq.WHY_NONE)
                return "On: CarPlay's music goes through EQ Engine, " + rateName(CarPlayEq.rate(v)) + ", unconverted";
            return "On: CarPlay's music, at its own rate, unconverted. Siri and calls never";
        }
        if ("waiting".equals(c.state)) return "On: waiting for the CarPlay app to start";
        return "On from the next car start (restart the car, parked)";
    }

    /** The CarPlay card's EQ line: what happens to CarPlay's music now (from the watch's live file). */
    private String cpEqNow(CpwState c, int[] v) {
        if (!"on".equals(c.state) && !"ending".equals(c.state)) return "-";
        if (!s.cpEq) return "Off: CarPlay's music plays untouched";
        if (CarPlayEq.playing(v)) {
            int w = CarPlayEq.why(v);
            if (w == CarPlayEq.WHY_MIC) return "Dry for now: Siri or a call has the microphone";
            if (w != CarPlayEq.WHY_NONE) return "Untouched now: " + CarPlayEq.whyText(w);
            int[] pr = CarPlayEq.processing(v);
            double bufUs = CarPlayEq.rate(v) > 0 ? pr[2] * 1e6 / CarPlayEq.rate(v) : 0;
            return String.format(Locale.US, "On, %s: %.2f ms per %.0f ms write", rateName(CarPlayEq.rate(v)), pr[0] / 1e6, bufUs / 1000);
        }
        if (CarPlayEq.state(v) == CarPlayEq.PASSING) return "Untouched now: " + CarPlayEq.whyText(CarPlayEq.why(v));
        return "On; CarPlay's music gets it when it plays";
    }

    private static String rateName(int hz) {
        return hz == 44100 ? "44.1 kHz" : hz == 48000 ? "48 kHz" : hz + " Hz";
    }

    /** The Settings switch. Off: CarPlay is flat at once, and the layer leaves at the next car start. On: from the next car start. */
    private void setCarPlay(boolean on) {
        if (on == s.cpEq) {
            syncCpwViews();
            return;
        }
        if (cpBusy) {
            overlay.show("Still working on the last change.", Overlay.WARN);
            syncCpwViews();
            return;
        }
        if (on && !swMaster.isOn()) {
            overlay.show("EQ Engine is off. Turn it on first.", Overlay.WARN);
            syncCpwViews();
            return;
        }
        s.cpEq = on;
        applyAll("EQ on CarPlay " + (on ? "on" : "off"), true);
        cpSyncTried = true; // the user's own choice: nothing to bring in step on this screen
        runCpw(on, true);
    }

    /** act.sh cpwatch 1|0 on a thread of its own; loud = said on screen (the switch), else only logged. */
    private void runCpw(final boolean on, final boolean loud) {
        if (cpBusy) return;
        cpBusy = true;
        EqLog.i((loud ? "" : "bringing it in step: ") + "EQ on CarPlay " + (on ? "on" : "off"));
        syncCpwViews();
        new Thread(new Runnable() {
            public void run() {
                // (after 0.7.6) a quiet "bring it in step" that is refused writes state/cpw_failed, so
                // the one-time notice says why the switch went off, as every other way it turns
                // itself off does
                final String out = Root.run((!loud && on ? "EQE_CPW_NOTIFY=1 " : "") + ACT + " cpwatch " + (on ? 1 : 0));
                handler.post(new Runnable() {
                    public void run() {
                        cpBusy = false;
                        cpwDone(on, loud, out);
                        refresh();
                    }
                });
            }
        }).start();
    }

    private void cpwDone(boolean on, boolean loud, String out) {
        // (after 0.7.6) a screen closed meanwhile: the one in front applies it to its own settings, or,
        // with none in front, this one starts from the engine's settings (not its own old copy)
        MainActivity f = front;
        if (f != null && f != this) {
            f.cpwDone(on, loud, out);
            return;
        }
        if (f == null) s = engine.settings().copy();
        String res = null;
        boolean wait = false;
        for (String l : out.split("\n")) {
            l = l.trim();
            if (l.startsWith("EQE_CPW_NOTE ")) EqLog.i("EQ on CarPlay: " + l.substring(13));
            else if (l.startsWith("EQE_CPW ")) {
                res = l.substring(8);
                EqLog.i("EQ on CarPlay: " + res);
            } else if (l.startsWith("EQE_WAIT")) wait = true;
        }
        if (wait) {
            if (loud) overlay.show("EQ on CarPlay is already being changed. Try again in a minute.", Overlay.WARN);
            return;
        }
        if (res == null) {
            // (after 0.7.6) act.sh gave no answer (the root channel down, act.sh missing): nothing is
            // known to have changed, so the switch stays as it is
            EqLog.w("EQ on CarPlay: no answer: " + lastLine(out));
            if (loud) tell("EQ on CarPlay could not be changed: " + lastLine(out), Overlay.ERROR);
            return;
        }
        if (on && res.startsWith("refused")) {
            String why = res.substring(Math.min(res.length(), 9));
            if (why.startsWith("this unit has no ")) {
                if (loud) overlay.show("This unit has no factory CarPlay app.", Overlay.INFO);
                return;
            }
            if (why.startsWith("EQ Engine is off")) {
                if (loud) overlay.show("EQ Engine is off. Turn it on first.", Overlay.WARN);
                return;
            }
            // could not be prepared: the switch goes back off and says why
            s.cpEq = false;
            applyAll("EQ on CarPlay off (it could not be turned on: " + why + ")", true);
            if (loud) overlay.show("EQ on CarPlay could not be turned on: " + why + ". If it keeps happening, save All logs "
                    + "(Diagnostics) and send them.", Overlay.WARN);
            return;
        }
        if (!loud) return;
        if (on) overlay.show(res.startsWith("already on") || res.startsWith("on: still loaded") ? "EQ on CarPlay is on."
                : "EQ on CarPlay is on from the next car start. Nothing restarts now.", Overlay.OK);
        else overlay.show(res.startsWith("off from the next car start")
                ? "EQ on CarPlay is off: CarPlay is flat now, and EQ Engine leaves the CarPlay app at the next car start."
                : "EQ on CarPlay is off.", Overlay.OK);
    }

    /**
     * (after 0.7.6) The boot step turned EQ Engine off because Android's audio server kept restarting
     * (state "crashed"): said once for that car start, with Save logs. (Before, the engine's own state
     * text was checked, which the service's stop overwrote at once, so this was never shown.)
     */
    private void crashCheck(BootStatus bs) {
        // the start that crashed ("crashed"), or a later one where it is still off for that reason
        boolean kr = "crashed".equals(bs.state())
                || "off".equals(bs.state()) && bs.get("reason").contains("audio server kept restarting");
        if (!kr || "kr".equals(s.crashAck) || "kr".equals(crashShown)) return;
        // once until EQ Engine is turned back on (setMaster clears it), then again at a new crash
        crashShown = "kr";
        s.crashAck = "kr";
        applyAll("told: EQ Engine turned itself off (Android's audio server kept restarting)", true);
        overlay.confirm("EQ Engine turned itself off",
                "Android's audio server kept restarting during this start, so EQ Engine took itself out: the sound is stock "
                        + "now, and it stays off until you turn it back on (Settings). Please save the logs to a USB stick "
                        + "(Diagnostics, All logs) and send them so this can be fixed. They hold your phone's name, Bluetooth "
                        + "addresses and song titles, so share them privately.",
                "Settings", new Runnable() {
                    public void run() {
                        showPage(NavRail.SETTINGS);
                    }
                }, "Save logs", new Runnable() {
                    public void run() {
                        saveLogs();
                    }
                });
    }

    /**
     * EQ on CarPlay turned itself off since the user last heard (state/cpw_failed has a new id): the
     * switch goes off, and the screen says why, once, with Save logs and Settings.
     */
    private void cpFailCheck() {
        CpwFail f = snap.cpwFail;
        if (f.id.length() == 0 || f.id.equals(s.cpwAck) || f.id.equals(cpFailShown)) return;
        cpFailShown = f.id;
        s.cpEq = false;
        s.cpwAck = f.id;
        applyAll("EQ on CarPlay turned itself off: " + f.why, true);
        overlay.confirm("EQ on CarPlay turned itself off",
                cap(f.why.length() > 0 ? f.why : "it did not work this time") + (f.when.length() > 0 ? " (" + f.when + ")" : "")
                        + ". CarPlay plays as it does without EQ Engine; nothing else changed. You can turn it on again in Settings: "
                        + "it starts at the next car start. Please save the logs to a USB stick (Diagnostics, All logs) and send "
                        + "them so this can be fixed. They hold your phone's name, Bluetooth addresses and song titles, so share "
                        + "them privately.",
                "Settings", new Runnable() {
                    public void run() {
                        showPage(NavRail.SETTINGS);
                    }
                }, "Save logs", new Runnable() {
                    public void run() {
                        saveLogs();
                    }
                });
    }

    /**
     * Keeps what is prepared for the car start in step with the switch, once per screen: on by
     * default (an install, EQ Engine turned back on), or off left over. Never after it turned itself
     * off (the switch is off then), and never on a unit without the factory CarPlay app.
     */
    private void cpReconcile() {
        if (cpBusy || cpSyncTried || busy || turningOff || !snap.read || !swMaster.isOn() || !snap.bs.allowed()) return;
        String st = snap.cpw.state;
        boolean prepared = "on".equals(st) || "waiting".equals(st) || "pending".equals(st);
        if (s.cpEq && !prepared && !"failed".equals(st) && !"absent".equals(st)) {
            cpSyncTried = true;
            runCpw(true, false);
        } else if (!s.cpEq && prepared) {
            cpSyncTried = true;
            runCpw(false, false);
        }
    }

    // ------------------------------------------------------------------ 48 kHz output (act.sh keep)

    /** What the 48 kHz keeper last found (state/output). */
    static final class OutState {
        String state = "", note = "", link = "", linkRate = "", fps = "", out = "", owner = "";
        int server = -1;
        /** written for the audio server that runs now */
        boolean current;

        /** The running audio server's main output runs at 48 kHz, checked by the keeper. */
        boolean at48() {
            return "48k".equals(state) && current;
        }

        boolean trouble() {
            return current && ("held".equals(state) || "mismatch".equals(state) || "unsafe".equals(state));
        }

        /** Something the driver should act on now (wrong speed, or tracks on a freed buffer). */
        boolean urgent() {
            return current && ("mismatch".equals(state) || "unsafe".equals(state));
        }

        /** Another process (CarPlay) plays to the main link directly: the keeper leaves it alone. */
        boolean other() {
            return "other".equals(state) && current;
        }
    }

    /** On the background thread. */
    private static OutState readOut(int msPid) {
        OutState o = new OutState();
        for (String line : Root.readLines(new File(STATE + "/output"), 20)) {
            int eq = line.indexOf('=');
            if (eq <= 0) continue;
            String k = line.substring(0, eq), v = line.substring(eq + 1).trim();
            if (k.equals("state")) o.state = v;
            else if (k.equals("note")) o.note = v;
            else if (k.equals("link")) o.link = v;
            else if (k.equals("link_rate")) o.linkRate = v;
            else if (k.equals("fps")) o.fps = v;
            else if (k.equals("out")) o.out = v;
            else if (k.equals("owner")) o.owner = v;
            else if (k.equals("server")) {
                try {
                    o.server = Integer.parseInt(v);
                } catch (NumberFormatException ignored) {
                }
            }
        }
        o.current = o.server > 0 && o.server == msPid;
        return o;
    }

    /** A process name as people know it. */
    static String ownerName(String proc) {
        if (proc == null || proc.length() == 0) return "Another app";
        if (proc.startsWith("com.daudio.app.dipo")) return "CarPlay";
        if (proc.startsWith("com.google.android.projection")) return "Android Auto";
        return proc;
    }

    /** One line about the main output's rate, for the Settings subtitle. */
    private String outLine(OutState o) {
        boolean want = rate48();
        if (!swMaster.isOn()) return "EQ Engine is off: 44.1 kHz";
        String cut = snap.rate48Cut;
        if (cut != null) return "Turned off: " + cut;
        if (!o.current) return want ? "On: switches within a few seconds" : "Off: 44.1 kHz with the converter";
        if (o.other()) return ownerName(o.owner) + " has the speaker link at its own rate; the switch waits";
        if (o.at48()) return "48 kHz: link " + o.link + (o.fps.length() > 0 ? ", measured " + o.fps + " frames/s"
                : ", its speed is measured when music plays");
        if ("44k".equals(o.state)) return want ? "44.1 kHz for now: switches within a few seconds" : "Off: 44.1 kHz with the converter";
        return o.note.length() > 0 ? cap(o.note) : want ? "On: switches within a few seconds" : "Off";
    }

    private void syncOutputViews() {
        OutState o = snap.out;
        String ol = outLine(o);
        boolean warn = o.trouble() || snap.rate48Cut != null;
        String t;
        if (warn || o.other()) t = ol;
        else if (o.at48()) t = (o.fps.length() > 0 ? "Measured " + o.fps + " frames/s" : "48 kHz; measured when music plays")
                + ". CarPlay keeps its own rate";
        else t = "For Android Auto and Bluetooth. CarPlay keeps its own rate";
        setText(rate48Sub, t);
        rate48Sub.setTextColor(warn ? Ui.WARN : Ui.ON_SURFACE_VAR);
    }

    private void setRate48(final boolean on) {
        if (on == rate48()) return;
        rate48Want = on;
        EqSettings.writeRate48(this, on, new EqSettings.Saved() {
            public void saved(boolean ok) {
                rate48Want = null;
                if (!ok) {
                    overlay.show("The setting could not be saved.", Overlay.ERROR);
                    swRate48.setOn(!on, true);
                    return;
                }
                snap.rate48 = on;
                EqLog.i("48 kHz output " + (on ? "on" : "off"));
                overlay.show(on ? "48 kHz output on. The main output switches within a few seconds; while music plays that is a "
                        + "short gap in the sound." : "48 kHz output off. The main output goes back to 44.1 kHz within a few seconds.",
                        Overlay.OK);
                refresh();
            }
        });
    }

    // ------------------------------------------------------------------ audio restarts

    /** Seconds until act.sh allows another audio restart (0 = now); it keeps 10 s between them. */
    private int restartWait() {
        if (snap.lastRestart < 0) return 0;
        long w = snap.lastRestart + RESTART_COOLDOWN_S - SystemClock.elapsedRealtime() / 1000;
        return w > 0 && w <= RESTART_COOLDOWN_S ? (int) w : 0;
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
        if (liveOn) specQ.clear();
        levelQ.clear();
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
                    snap.want = "3";
                    EqSettings.writeConverter(MainActivity.this, "3", null);
                }
                if (!stuck.isEmpty()) {
                    String who = TextUtils.join(", ", stuck);
                    EqLog.w("after the audio restart, these streams did not play again: " + who);
                    tell(who + " did not resume after the audio restart (an Android 4.4 issue). Try pause and play, or "
                            + "switch to Radio and back; if it stays silent, reconnect the phone.", Overlay.WARN);
                } else if (ok && "missed".equals(vhq)) {
                    tell("Android set up its converter before EQ Engine's tables loaded, so it still uses high quality's tables. "
                            + "Another audio restart (parked) may catch it.", Overlay.WARN);
                } else if (ok && "not-loaded".equals(vhq)) {
                    tell("EQ Engine's tables did not load into Android's audio server, so it uses high quality's tables. "
                            + "Saved logs would show why.", Overlay.WARN);
                } else if (ok && okText != null) {
                    tell(okText, Overlay.OK);
                }
                if (ok) EqLog.i("audio restart: " + messageLine(out));
                refresh();
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

    /**
     * (after 0.7.6) Another root action or an audio restart is running: EQ Engine's switch is put back
     * and nothing is stopped. (Turning it off used to stop the EQ first; act.sh off was then refused,
     * so EQ Engine stayed on for later starts while the switch came back on by itself.)
     */
    private boolean masterRefused(boolean on) {
        if (!busy && !restarting) return false;
        swMaster.setOn(!on, true);
        overlay.show("Still working on the last action. Try again when it has finished.", Overlay.WARN);
        return true;
    }

    private void askMaster(final boolean on) {
        if (masterRefused(on)) return;
        if (on) {
            setMaster(true);
            return;
        }
        swMaster.setOn(true, false);
        overlay.confirm("Turn EQ Engine off?", "The EQ, 48 kHz output and the high-quality converter stop now, and later starts "
                + "are completely stock until you turn it back on here.", "Turn off", new Runnable() {
                    public void run() {
                        setMaster(false);
                    }
                });
    }

    private void setMaster(boolean on) {
        // (an action may have started while the question was open)
        if (masterRefused(on)) return;
        swMaster.setOn(on, true);
        if (on) {
            EqLog.i("turning EQ Engine back on");
            turnedOnAt = System.currentTimeMillis();
            onOfferedAt = 0;
            // (after 0.7.6) EQ Engine off took EQ on CarPlay's preparation away: bring it in step
            // again on this screen (cpReconcile waits until "on" has finished)
            cpSyncTried = false;
            // (after 0.7.6) a later "kept restarting" is told again
            if (s.crashAck.length() > 0) {
                s.crashAck = "";
                saveNow();
            }
            crashShown = "";
            rootAsync(ACT + " on", "EQ Engine is on. It loads at every start.", null);
        } else {
            EqLog.i("turning EQ Engine off");
            turningOff = true;
            stopService(new Intent(this, EqService.class));
            engine.stop("turned off in the app");
            rootAsync(ACT + " off", "EQ Engine is off. The next start is completely stock.", null);
        }
    }

    private void openFactory(String component, String name) {
        EqLog.i("opening the factory " + name + " page (" + component + ")");
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
                        tell(out.contains("EQE_OK") ? "Audio trace saved. Save to USB > All logs copies it to the stick."
                                : "The audio trace failed: " + lastLine(out), out.contains("EQE_OK") ? Overlay.OK : Overlay.ERROR);
                        refresh();
                    }
                });
            }
        }, "eqengine-trace").start();
    }

    /**
     * A screenshot SHOT_SECONDS after the tap, of whatever is in front by then (act.sh shot). The
     * screencap tool writes it straight to the stick: nothing is kept on the head unit and this
     * app never loads it. The result is a system toast, so it shows over another app too.
     */
    private void takeShot() {
        if (shotAt > System.currentTimeMillis()) return;
        withUsb(new Usb() {
            public void found(List<String> roots) {
                if (roots.isEmpty()) {
                    overlay.show("No USB stick is mounted. Plug one in (not the rescue stick) and tap again.", Overlay.WARN);
                    return;
                }
                shotAt = System.currentTimeMillis() + SHOT_SECONDS * 1000L;
                refreshDiag();
                overlay.show("Screenshot in " + SHOT_SECONDS + " s: switch to the screen you want now.", Overlay.INFO);
                EqLog.i("screenshot in " + SHOT_SECONDS + " s");
                final String cmd = ACT + " shot '" + roots.get(0) + "' " + SHOT_SECONDS;
                final Context app = getApplicationContext();
                new Thread(new Runnable() {
                    public void run() {
                        final String out = Root.run(cmd);
                        handler.post(new Runnable() {
                            public void run() {
                                shotAt = 0;
                                String name = null;
                                for (String l : out.split("\n")) {
                                    l = l.trim();
                                    if (l.startsWith("EQE_SHOT ")) name = l.substring(9);
                                }
                                boolean ok = out.contains("EQE_OK") && name != null;
                                String msg = ok ? "EQ Engine: screenshot saved to the USB stick, " + name
                                        : "EQ Engine: the screenshot failed (" + lastLine(out) + ")";
                                EqLog.i(ok ? "screenshot saved: " + name : "screenshot failed: " + out.trim());
                                android.widget.Toast.makeText(app, msg, android.widget.Toast.LENGTH_LONG).show();
                                if (resumed && page == DIAG) refreshDiag();
                            }
                        });
                    }
                }, "eqengine-shot").start();
            }
        });
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
                // the log lines written just before (for example "saving logs to USB") are in the file first
                EqLog.flush(1000);
                final String out = Root.run(cmd);
                if (out.contains("EQE_OK")) EqLog.d("root: " + out.trim());
                else if (out.contains("EQE_WAIT")) EqLog.i("root command refused for now: " + lastLine(out));
                else EqLog.w("root command failed: " + cmd + " -> " + out.trim());
                handler.post(new Runnable() {
                    public void run() {
                        busy = false;
                        turningOff = false;
                        boolean ok = out.contains("EQE_OK");
                        if (out.contains("EQE_WAIT")) tell(lastLine(out), Overlay.WARN);
                        else if (ok && okText != null) tell(okText, Overlay.OK);
                        else if (!ok) tell((openedName != null ? "Couldn't open " + openedName + ": " : "That didn't work: ")
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

    interface Usb {
        void found(List<String> roots);
    }

    /** Finds the mounted USB sticks on the background thread. */
    private void withUsb(final Usb then) {
        Bg.run(new Runnable() {
            public void run() {
                final List<String> roots = Root.usbRoots();
                Bg.main(new Runnable() {
                    public void run() {
                        then.found(roots);
                    }
                });
            }
        });
    }

    /** The car report: one text file on the stick, meant for sharing (act.sh report). */
    private void askReport() {
        withUsb(new Usb() {
            public void found(final List<String> roots) {
                if (roots.isEmpty()) {
                    overlay.show("No USB stick is mounted. Plug one in (not the rescue stick) and tap Report again.", Overlay.WARN);
                    return;
                }
                overlay.confirm("Make a car report?", "Play some music first (Android Auto, CarPlay, Bluetooth or USB). The report "
                        + "records " + REPORT_SECONDS + " s of the audio system's log and measures the hardware link, then writes "
                        + "one text file to the EQENGINE folder on the stick: what this car is, what EQ Engine finds on it, and the "
                        + "audio log. Lines that could hold personal data (Bluetooth names and addresses, song details, location, "
                        + "serial numbers, VIN) are left out, and the car maker's own files are not copied. Read it through before "
                        + "you post it anywhere public.",
                        "Make report", new Runnable() {
                            public void run() {
                                runReport(roots.get(0));
                            }
                        });
            }
        });
    }

    private void runReport(String usb) {
        File log = EqLog.file();
        String appDir = log != null ? log.getParentFile().getAbsolutePath() : getFilesDir().getAbsolutePath();
        EqLog.i("making a car report");
        overlay.show("Making the car report (about " + (REPORT_SECONDS + 20) + " s). Keep the music playing.", Overlay.INFO);
        rootAsync(ACT + " report '" + usb + "' '" + appDir + "' " + REPORT_SECONDS, null, null, new Done() {
            public void done(boolean ok, String out) {
                if (!ok) return;
                String name = null;
                for (String l : out.split("\n")) {
                    l = l.trim();
                    if (l.startsWith("EQE_REPORT ")) name = l.substring(11);
                }
                tell("Car report saved to the stick: EQENGINE/" + (name != null ? name : "report_...txt"), Overlay.OK);
            }
        });
    }

    private void saveLogs() {
        withUsb(new Usb() {
            public void found(List<String> roots) {
                if (roots.isEmpty()) {
                    overlay.show("No USB stick is mounted. Plug one in (not the rescue stick) and tap Save again.", Overlay.WARN);
                    return;
                }
                File log = EqLog.file();
                String appDir = log != null ? log.getParentFile().getAbsolutePath() : getFilesDir().getAbsolutePath();
                EqLog.i("saving logs to USB");
                overlay.show("Saving logs to USB (about 15 seconds)...", Overlay.INFO);
                rootAsync(ACT + " save '" + roots.get(0) + "' '" + appDir + "' 1", "Logs saved to the USB stick, in the EQENGINE folder.",
                        null);
            }
        });
    }

    private void installCrashHandler() {
        if (crashHandlerSet) return;
        crashHandlerSet = true;
        final Thread.UncaughtExceptionHandler previous = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {
            public void uncaughtException(Thread th, Throwable ex) {
                try {
                    if (Bg.isIoThread(th)) {
                        // (after 0.7.6) the background thread itself: nothing posted to it runs any more
                        EqLog.eNow("CRASH in thread " + th.getName(), ex);
                    } else {
                        EqLog.e("CRASH in thread " + th.getName(), ex);
                        EqLog.flush(1500);
                    }
                    // (after 0.7.6) only to a stick already used for EQ Engine (its install stick, or
                    // one that has EQ Engine's logs on it), never to any stick that happens to be
                    // plugged in (a music stick): the logs are private. With none, nothing is copied;
                    // the crash stays in the app's own log on the unit for the next All logs. act.sh
                    // looks as root (this app cannot see the raw USB mounts), within the time limit.
                    List<String> roots = Root.usbRoots();
                    if (!roots.isEmpty()) {
                        StringBuilder c = new StringBuilder(ACT + " crashsave '" + getFilesDir().getAbsolutePath() + "'");
                        for (String r : roots) c.append(" '").append(r).append('\'');
                        Root.runBlocking(c.toString(), 8000);
                    }
                } catch (Throwable ignored) {
                }
                if (previous != null) previous.uncaughtException(th, ex);
                else System.exit(2);
            }
        });
    }

    // ------------------------------------------------------------------ showing the status

    private void applySnap(Snap n) {
        snap = n;
        if (!resumed) return;
        BootStatus bs = n.bs;
        String est = engine.state();
        boolean attached = engine.attached();

        // events worth a pop-up
        boolean notListed = est.startsWith("Android doesn't list");
        if (attached && !wasAttached && lastEngineState.length() > 0) overlay.show("EQ connected to all music.", Overlay.OK);
        // Both cases below are offered, never done unasked (the rear camera's service runs in the
        // audio server's process), and only inside EQ Engine's own screen (a pop-up over other apps
        // could cover the camera's picture):
        // - turned back on in the app while this audio server has the factory effects list (it
        //   started while EQ Engine was off): once per turn-on, within 30 s of it;
        // - the audio server read the factory list before the boot step's overlay: once per audio
        //   server. The boot step that turning on starts writes the same late list, so it is not
        //   asked a second time then.
        long nowMs = System.currentTimeMillis();
        boolean onRecently = turnedOnAt > 0 && nowMs - turnedOnAt < 30000;
        if (turnedOnAt > 0 && !onRecently) turnedOnAt = 0;
        if (n.lateList && !n.lateKey.equals(latePrompted) && onOfferedAt > 0 && nowMs - onOfferedAt < 60000)
            latePrompted = n.lateKey;
        boolean offerOn = onRecently && onOfferedAt == 0 && notListed;
        boolean offerLate = n.lateList && !n.lateKey.equals(latePrompted);
        if ((offerOn || offerLate) && !busy && !restarting) {
            if (n.lateList) latePrompted = n.lateKey;
            if (onRecently) {
                onOfferedAt = nowMs;
                EqLog.i("turned back on, but the audio server has the factory effects list: restart offered");
                overlay.confirm("EQ Engine is on from the next car start",
                        "Android's audio was started while EQ Engine was off and has the factory effects list. EQ Engine loads "
                                + "at the next car start, or restart Android audio now to load it: a few seconds of silence. "
                                + "Parked only, never while reversing (the camera service restarts too).",
                        "Restart audio", new Runnable() {
                    public void run() {
                        doRestart("after turning back on, the audio server had the factory effects list");
                    }
                });
            } else {
                EqLog.i("this start's audio server read the factory effects list before the overlay: restart offered");
                overlay.confirm("EQ Engine is not active this start",
                        "Android's audio started a moment before EQ Engine and read the factory effects list, so the EQ, EQ "
                                + "Engine's converter and 48 kHz output are not in it. Restart Android audio once to load them: a "
                                + "few seconds of silence. Parked only, never while reversing (the camera service restarts too).",
                        "Restart audio", new Runnable() {
                    public void run() {
                        doRestart("the audio server read the factory effects list before the overlay");
                    }
                });
            }
        }
        if (!attached && !est.equals(lastEngineState) && notListed && n.justInstalled)
            overlay.show(JUST_INSTALLED, Overlay.INFO);
        else if (!attached && !est.equals(lastEngineState) && (notListed && !n.lateList && !onRecently || est.startsWith("attaching failed")
                || est.startsWith("the stage 1") || est.startsWith("unexpected")))
            overlay.show(est, Overlay.WARN);
        crashCheck(bs);
        wasAttached = attached;
        lastEngineState = est;
        OutState os = n.out;
        if (os.urgent() && !os.note.equals(lastOutWarn)) overlay.show(cap(os.note), Overlay.WARN);
        lastOutWarn = os.urgent() ? os.note : "";

        // EQ Engine was turned back on: make sure the service runs
        if (bs.allowed() && !engine.isRunning() && !turningOff) startService(new Intent(this, EqService.class));

        if (!turningOff && !busy) swMaster.setOn(!bs.finalOff(), true);
        // (right after an install the filter is expected to be missing until the car restarts: no badge)
        rail.setBadge(NavRail.STATUS, notListed && !n.justInstalled || bs.state().equals("crashed")
                || bs.state().equals("error") || bs.state().equals("refused"));
        System.arraycopy(n.userHas, 0, userHas, 0, userHas.length);
        if (rate48Want == null) swRate48.setOn(n.rate48, true);
        cpFailCheck();
        cpReconcile();
        applyViews();
    }

    /** Updates the visible page from the snapshot (no file reads). */
    private void applyViews() {
        if (page == NavRail.EQ) updateEqHeader();
        else if (page == NavRail.SETTINGS) {
            syncConverterViews();
            syncOutputViews();
            syncCpwViews();
        } else if (page == NavRail.STATUS) refreshStatus();
        else if (page == DIAG) refreshDiag();
        else if (page == NavRail.POSITION) updatePositionViews();
    }

    private void refreshStatus() {
        BootStatus bs = snap.bs;
        String st = bs.state();
        String reason = bs.get("reason");
        boolean applied = "applied".equals(st);
        tile(0, st.length() == 0 ? (snap.read ? "No status yet" : "-") : cap(st) + (applied && "1".equals(bs.get("good")) ? ", confirmed" : ""),
                (applied ? "Effects list in place · strikes " + bs.get("strikes") : cap(reason))
                        + "\nUnexpected restarts " + bs.get("unexpected_restarts") + " · service "
                        + ("1".equals(bs.get("service")) ? "started" : "not started yet"));
        long since = engine.attachedAt();
        boolean waitInstall = !engine.attached() && snap.justInstalled && engine.state().startsWith("Android doesn't list");
        // CarPlay's music through the CarPlay watch's EQ (0.7.3)
        int[] cpv = engine.cpLive();
        boolean cpPlay = CarPlayEq.playing(cpv);
        tile(1, cpPlay ? (s.eqOn && CarPlayEq.why(cpv) == CarPlayEq.WHY_NONE ? "On CarPlay's music" : "CarPlay, EQ off for now")
                        : engine.attached() ? (s.eqOn ? "On all music" : "Connected, EQ off") : waitInstall ? "Restart the car" : "Not connected",
                (since > 0 ? "Since " + new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date(since))
                        : waitInstall ? "Just installed: Android's audio loads EQ Engine at the next start" : cap(engine.state()))
                        + "\n" + (s.expert ? "Expert, " : "") + s.name() + ", preamp " + EqSettings.db(s.preamp) + " dB"
                        + (engine.olderFilter() ? " · previous filter until the next car start" : ""));
        int[] x = engine.stats();
        ConvState cv = convStateNow();
        String q = cv.now();
        String[] vq = convStatus(cv, converter());
        OutState o = snap.out;
        if (cpPlay) {
            tile(2, "CarPlay, " + rateName(CarPlayEq.rate(cpv)), "Through EQ Engine in the CarPlay app,\nunconverted");
        } else if (o.other()) {
            boolean cp = "CarPlay".equals(ownerName(o.owner));
            int lr = 0;
            try {
                lr = Integer.parseInt(o.linkRate);
            } catch (NumberFormatException ignored) {
            }
            tile(2, cp ? (lr > 0 ? "CarPlay, " + rateName(lr) : "CarPlay has the link") : ownerName(o.owner) + " has the link",
                    !cp ? "It plays to the speakers itself,\nso EQ Engine can't process it"
                            : !s.cpEq ? "Without EQ Engine:\nEQ on CarPlay is off (Settings)"
                            : "on".equals(snap.cpw.state) ? "Without EQ Engine for now"
                            : "Without EQ Engine until\nthe next car start");
        } else if (o.at48()) {
            // checked only once the keeper has counted the link's frames (fps= empty until then)
            boolean measured = o.fps.length() > 0;
            tile(2, restarting ? "Switching" : measured ? "48 kHz, unconverted" : "48 kHz, checking",
                    "Link " + o.link + (measured ? " measured " + o.fps + " frames/s" : ": speed checked when music plays")
                            + "\nOther rates: " + convName(q));
        } else {
            tile(2, restarting ? "Switching" : "44.1 kHz, " + ("4".equals(q) ? "very high" : "3".equals(q) ? "high" : "0".equals(q) ? "stock" : convName(q)),
                    (cv.byTables ? "Confirmed: EQ Engine's tables are converting"
                            : cv.confirmed != null ? "Audio server confirmed at " + cv.confirmedAt : "Not used yet by this audio server")
                            + "\n" + (cv.confirmed != null && cv.pending != null && !cv.pending.equals(cv.confirmed)
                            ? "Next audio restart: " + convName(cv.pending)
                            : rate48() && swMaster.isOn() ? "48 kHz: " + outLine(o)
                            : vq[0] != null ? vq[0] : "Converts Android Auto's 48 kHz audio"));
        }
        if (cpPlay) {
            int[] pr = CarPlayEq.processing(cpv), lv = CarPlayEq.level(cpv);
            double bufUs = CarPlayEq.rate(cpv) > 0 ? pr[2] * 1e6 / CarPlayEq.rate(cpv) : 0;
            tile(3, String.format(Locale.US, "%.1f%% of real time", bufUs > 0 ? pr[0] / 10.0 / bufUs : 0),
                    String.format(Locale.US, "%.2f ms per %.0f ms buffer (max %.2f ms)\nCarPlay, %d Hz stereo, audio flowing",
                            pr[0] / 1e6, bufUs / 1000, pr[1] / 1e6, CarPlayEq.rate(cpv)));
            int mg = CarPlayEq.minGain(cpv);
            tile(4, lv[3] <= -10000 ? "Silent" : String.format(Locale.US, "Average %.1f dBFS", lv[3] / 100.0),
                    "Peak out " + Engine.dbfsShort(lv[2]) + " dBFS (CarPlay)\nArrived clipped " + CarPlayEq.arrivedClipped(cpv)
                            + " · guard " + (mg >= 9999 ? "idle" : String.format(Locale.US, "%.1f dB", 20 * Math.log10(mg / 10000.0))));
        } else if (x == null) {
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
                            + "\nArrived clipped " + x[27] + " · guard "
                            + (x[17] >= 9999 ? "idle" : String.format(Locale.US, "%.1f dB", 20 * Math.log10(x[17] / 10000.0))));
        }
        tile(5, engine.isRunning() ? "Service running" : "Service stopped",
                "EQ Engine " + VERSION + " · log " + (s.detailedLog ? "detailed" : "normal") + "\nFilter "
                        + (x != null ? Integer.toHexString(x[19]) : "-") + " · " + (x != null && x[23] == 1 ? "processing" : "bit-exact path"));
        setText(logLevel, s.detailedLog ? "Detailed" : "Normal");
        int lv = EqLog.version();
        if (lv != logVersion) {
            logVersion = lv;
            logView.setText(EqLog.tailText());
        }
    }

    private void refreshDiag() {
        long left = (traceEndsAt - System.currentTimeMillis()) / 1000;
        if (traceEndsAt > 0 && left > 0) {
            setText(traceStatus, "Recording... " + Math.max(0, left - 6) + " s left");
            traceStatus.setTextColor(Ui.SECONDARY);
            traceBtn.setEnabled(false);
        } else {
            traceBtn.setEnabled(true);
            String last = snap.lastTrace;
            setText(traceStatus, last == null ? "No trace recorded yet." : "Last trace: " + last);
            traceStatus.setTextColor(Ui.ON_SURFACE_VAR);
        }
        setText(traceInfo, snap.alsa == null ? "" : "ALSA mixer: " + snap.alsa);
        long shotLeft = (shotAt - System.currentTimeMillis() + 999) / 1000;
        shotBtn.setEnabled(shotLeft <= 0);
        setText(shotBtn, shotLeft > 0 ? "In " + shotLeft + " s" : "In " + SHOT_SECONDS + " s");
        syncCpwViews();
    }

    private void tile(int i, String value, String detail) {
        setText(tileValue[i], value);
        setText(tileDetail[i], detail);
    }

    /** Sets the text only when it changed (setText alone lays the view out again). */
    private static void setText(TextView t, String v) {
        if (!v.contentEquals(t.getText())) t.setText(v);
    }

    private static String cap(String t) {
        return t.length() == 0 ? t : Character.toUpperCase(t.charAt(0)) + t.substring(1);
    }

    /** On the background thread. */
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
        main.addView(rail, lp(dp(NavRail.WIDTH_DP), MATCH, 0));
        FrameLayout content = new FrameLayout(this);
        main.addView(content, lp(0, MATCH, 1f));
        root.addView(main, new FrameLayout.LayoutParams(MATCH, MATCH));
        overlay = new Overlay(this);
        root.addView(overlay, new FrameLayout.LayoutParams(MATCH, MATCH));

        pages[NavRail.EQ] = buildEqPage();
        pages[NavRail.POSITION] = buildPositionPage();
        pages[NavRail.SETTINGS] = buildSettingsPage();
        pages[NavRail.STATUS] = buildStatusPage();
        pages[DIAG] = buildDiagPage();
        for (View p : pages) content.addView(p, new FrameLayout.LayoutParams(MATCH, MATCH));
        setContentView(root);
    }

    private LinearLayout pageLayout() {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        l.setPadding(dp(20), dp(10), dp(20), dp(10));
        return l;
    }

    /** Height of a one-line page header (title and description side by side), and of its buttons. */
    private static final int HEADER_DP = 44, HEADER_BUTTON_DP = 40;

    /** The EQ page's header: the title with the preset line under it (the header holds its switches). */
    private LinearLayout header(String title, String sub, TextView[] subOut) {
        LinearLayout h = new LinearLayout(this);
        h.setOrientation(LinearLayout.HORIZONTAL);
        h.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout t = new LinearLayout(this);
        t.setOrientation(LinearLayout.VERTICAL);
        t.addView(Ui.text(this, title, 24, Ui.ON_SURFACE, true));
        TextView st = Ui.text(this, sub, 16, Ui.ON_SURFACE_VAR, false);
        st.setPadding(0, dp(4), 0, 0);
        st.setSingleLine(true);
        st.setEllipsize(TextUtils.TruncateAt.END);
        t.addView(st);
        if (subOut != null) subOut[0] = st;
        h.addView(t, lp(0, WRAP, 1f));
        return h;
    }

    /**
     * The other pages' header: the title and its description on one line (their baselines lined
     * up), which leaves more height for the page. Buttons added to it go on the right.
     */
    private LinearLayout headerLine(String title, String sub) {
        LinearLayout h = new LinearLayout(this);
        h.setOrientation(LinearLayout.HORIZONTAL);
        h.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout t = new LinearLayout(this);
        t.setOrientation(LinearLayout.HORIZONTAL); // top gravity: the two texts share a baseline
        t.addView(Ui.text(this, title, 24, Ui.ON_SURFACE, true));
        TextView st = Ui.text(this, sub, 16, Ui.ON_SURFACE_VAR, false);
        st.setSingleLine(true);
        st.setEllipsize(TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams sl = lp(0, WRAP, 1f);
        sl.setMargins(dp(16), 0, dp(12), 0);
        t.addView(st, sl);
        h.addView(t, lp(0, WRAP, 1f));
        return h;
    }

    private void headerButton(LinearLayout h, String label, int style, View.OnClickListener l) {
        h.addView(Ui.button(this, label, style, l), lp(WRAP, dp(HEADER_BUTTON_DP), 0));
    }

    /** A label and a switch in a page header; tapping the label toggles too. */
    private void headerSwitch(LinearLayout h, String label, final MSwitch sw) {
        h.addView(new View(this), lp(dp(20), 1, 0));
        TextView t = Ui.text(this, label, 18, Ui.ON_SURFACE, true);
        t.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                sw.performClick();
            }
        });
        h.addView(t);
        h.addView(sw, lp(dp(68), dp(44), 0));
    }

    private View buildEqPage() {
        LinearLayout pg = pageLayout();
        TextView[] sub = new TextView[1];
        LinearLayout h = header("Equalizer", "", sub);
        eqSubtitle = sub[0];
        // Easy | Expert (0.6.11; Auto is under the preamp slider now)
        modeSeg = new Ui.Seg(this, new String[] {"Easy", "Expert"}, new Ui.Seg.Listener() {
            public void onPick(int i) {
                setMode(i == 1);
            }
        });
        h.addView(modeSeg, lp(WRAP, dp(46), 0));
        swLive = new MSwitch(this);
        swLive.setListener(new MSwitch.Listener() {
            public void onSwitch(MSwitch sw, boolean on) {
                setLive(on);
            }
        });
        headerSwitch(h, "Live", swLive);
        eqGuard = new MSwitch(this);
        eqGuard.setListener(new MSwitch.Listener() {
            public void onSwitch(MSwitch sw, boolean on) {
                setGuard(on);
            }
        });
        headerSwitch(h, "Clip guard", eqGuard);
        eqSwitch = new MSwitch(this);
        eqSwitch.setListener(new MSwitch.Listener() {
            public void onSwitch(MSwitch sw, boolean on) {
                setEq(on);
            }
        });
        headerSwitch(h, "EQ", eqSwitch);
        pg.addView(h, lp(MATCH, dp(52), 0));

        FrameLayout body = new FrameLayout(this);
        // Easy: the live layer (meter, live view) behind the sliders
        FrameLayout face = new FrameLayout(this);
        face.setBackground(Ui.round(Ui.SURFACE, dp(16)));
        panel = new EqPanel(this);
        panel.setListener(this);
        live = new LiveLayer(this, panel);
        face.addView(live, new FrameLayout.LayoutParams(MATCH, MATCH));
        face.addView(panel, new FrameLayout.LayoutParams(MATCH, MATCH));
        easyBody = face;
        body.addView(face, new FrameLayout.LayoutParams(MATCH, MATCH));
        // Expert: two cards side by side, the preamp and curve editor, and the band card
        LinearLayout xrow = new LinearLayout(this);
        xrow.setOrientation(LinearLayout.HORIZONTAL);
        FrameLayout left = new FrameLayout(this);
        left.setBackground(Ui.round(Ui.SURFACE, dp(16)));
        xpanel = new XPanel(this, dp(BAND_CARD_DP + CARD_GAP_DP));
        xpanel.setListener(this);
        liveX = new LiveLayer(this, xpanel);
        left.addView(liveX, new FrameLayout.LayoutParams(MATCH, MATCH));
        left.addView(xpanel, new FrameLayout.LayoutParams(MATCH, MATCH));
        xrow.addView(left, lp(0, MATCH, 1f));
        LinearLayout.LayoutParams bcl = lp(dp(BAND_CARD_DP), MATCH, 0);
        bcl.setMargins(dp(CARD_GAP_DP), 0, 0, 0);
        xrow.addView(buildBandCard(), bcl);
        expertBody = xrow;
        body.addView(xrow, new FrameLayout.LayoutParams(MATCH, MATCH));
        LinearLayout.LayoutParams plp = lp(MATCH, 0, 1f);
        plp.setMargins(0, dp(8), 0, dp(10));
        pg.addView(body, plp);

        // the bottom row, the same in both modes: Flat | User 1-4 | Curves on USB (in the middle of
        // the free space) and, on the right, Expert's band buttons, then Undo
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        flatChip = Ui.chip(this, "Flat", new View.OnClickListener() {
            public void onClick(View v) {
                doFlat();
            }
        });
        row.addView(flatChip, lp(WRAP, dp(42), 0));
        row.addView(separator(), separatorLp());
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
            if (i < EqSettings.USER_SLOTS - 1) cl.setMargins(0, 0, dp(8), 0);
            row.addView(c, cl);
        }
        row.addView(separator(), separatorLp());
        row.addView(new View(this), lp(0, 1, 1f));
        row.addView(Ui.chip(this, "Curves on USB", new View.OnClickListener() {
            public void onClick(View v) {
                askCurves();
            }
        }), lp(WRAP, dp(42), 0));
        row.addView(new View(this), lp(0, 1, 1f));
        addBandBtn = chipButton("+ Add band", true, new View.OnClickListener() {
            public void onClick(View v) {
                addBand();
            }
        });
        LinearLayout.LayoutParams al = lp(WRAP, dp(42), 0);
        al.setMargins(0, 0, dp(8), 0);
        row.addView(addBandBtn, al);
        delBandBtn = chipButton("Delete band", false, new View.OnClickListener() {
            public void onClick(View v) {
                deleteBand();
            }
        });
        Ui.TrashIcon trash = new Ui.TrashIcon(Ui.ON_SURFACE, Math.max(2, dp(1.6f)));
        trash.setBounds(0, 0, dp(18), dp(18));
        delBandBtn.setCompoundDrawables(trash, null, null, null);
        delBandBtn.setCompoundDrawablePadding(dp(8));
        LinearLayout.LayoutParams dl = lp(WRAP, dp(42), 0);
        dl.setMargins(0, 0, dp(16), 0);
        row.addView(delBandBtn, dl);
        undoBtn = Ui.chip(this, "Undo", new View.OnClickListener() {
            public void onClick(View v) {
                doUndo();
            }
        });
        row.addView(undoBtn, lp(WRAP, dp(42), 0));
        pg.addView(row, lp(MATCH, dp(46), 0));
        return pg;
    }

    /** The Expert band card's width, and the gap between the two Expert cards. */
    private static final int BAND_CARD_DP = 372, CARD_GAP_DP = 12;

    private View separator() {
        View sep = new View(this);
        sep.setBackgroundColor(Ui.OUTLINE);
        return sep;
    }

    /** The same space on both sides of a divider. */
    private LinearLayout.LayoutParams separatorLp() {
        LinearLayout.LayoutParams sl = lp(dp(1), dp(28), 0);
        sl.setMargins(dp(12), 0, dp(12), 0);
        return sl;
    }

    /** A chip-shaped action: filled with the accent, or outlined in white (Delete band: plainly an action, not red). */
    private TextView chipButton(String label, boolean filled, View.OnClickListener l) {
        TextView t = Ui.text(this, label, 17, filled ? Ui.ON_PRIMARY : Ui.ON_SURFACE, false);
        float r = dp(10);
        int sw = Math.max(2, dp(1.5f));
        if (filled) {
            t.setBackground(Ui.states(Ui.round(Ui.PRIMARY, r), Ui.round(Color.rgb(130, 214, 250), r), null, Ui.round(Ui.SURFACE_TOP, r)));
        } else {
            t.setBackground(Ui.states(Ui.outlined(Color.TRANSPARENT, Ui.ON_SURFACE, sw, r), Ui.outlined(Ui.SURFACE_HI, Ui.ON_SURFACE, sw, r),
                    null, Ui.outlined(Color.TRANSPARENT, Ui.OUTLINE, sw, r)));
        }
        t.setGravity(Gravity.CENTER);
        t.setPadding(dp(16), 0, dp(16), 0);
        t.setMinHeight(dp(42));
        t.setClickable(true);
        t.setOnClickListener(l);
        return t;
    }

    /** A small tonal button for the band card (the arrows, - and +). */
    private TextView smallButton(String label, View.OnClickListener l) {
        TextView b = Ui.button(this, label, Ui.TONAL, l);
        b.setPadding(0, 0, 0, 0);
        b.setMinHeight(0);
        b.setMinimumHeight(0);
        return b;
    }

    /** Expert's band card: the selected band's number, type, frequency, gain and width, rows spread evenly. */
    private View buildBandCard() {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setBackground(Ui.round(Ui.SURFACE, dp(16)));
        card.setPadding(dp(14), dp(14), dp(14), dp(14));
        // row 1: the previous band, "Band 3 of 7", the next band
        LinearLayout r1 = new LinearLayout(this);
        r1.setOrientation(LinearLayout.HORIZONTAL);
        r1.setGravity(Gravity.CENTER_VERTICAL);
        bandPrev = smallButton("◀", new View.OnClickListener() {
            public void onClick(View v) {
                stepBand(-1);
            }
        });
        r1.addView(bandPrev, lp(dp(56), dp(40), 0));
        bandTitle = Ui.text(this, "", 19, Ui.ON_SURFACE, true);
        bandTitle.setGravity(Gravity.CENTER);
        r1.addView(bandTitle, lp(0, WRAP, 1f));
        bandNext = smallButton("▶", new View.OnClickListener() {
            public void onClick(View v) {
                stepBand(1);
            }
        });
        r1.addView(bandNext, lp(dp(56), dp(40), 0));
        card.addView(r1, lp(MATCH, dp(40), 0));
        // the rows below, hidden while there is no band (a note shows instead)
        FrameLayout below = new FrameLayout(this);
        LinearLayout rows = new LinearLayout(this);
        rows.setOrientation(LinearLayout.VERTICAL);
        rows.addView(new View(this), lp(1, 0, 1f));
        LinearLayout r2 = new LinearLayout(this);
        r2.setOrientation(LinearLayout.HORIZONTAL);
        for (int t = 1; t <= 4; t++) {
            final int type = t;
            TextView c = Ui.chip(this, EqSettings.X_TYPES[t], new View.OnClickListener() {
                public void onClick(View v) {
                    setType(type);
                }
            });
            c.setMinHeight(dp(36));
            c.setSingleLine(true);
            typeChips[t - 1] = c;
        }
        // one line at the largest size that fits the card (the car's font is wider than the mockups')
        float[] cw = fitTypeChips(dp(BAND_CARD_DP - 28), dp(6), dp(8));
        for (int t = 0; t < 4; t++) {
            LinearLayout.LayoutParams cl = lp(0, dp(36), cw[t]);
            if (t < 3) cl.setMargins(0, 0, dp(6), 0);
            r2.addView(typeChips[t], cl);
        }
        rows.addView(r2, lp(MATCH, dp(36), 0));
        rows.addView(new View(this), lp(1, 0, 1f));
        TextView[] fv = new TextView[3];
        rows.addView(valueRow("Frequency", "tap to type", fv, new View.OnClickListener() {
            public void onClick(View v) {
                stepFreq(-1);
            }
        }, new View.OnClickListener() {
            public void onClick(View v) {
                stepFreq(1);
            }
        }), lp(MATCH, dp(46), 0));
        freqValue = fv[0];
        freqMinus = fv[1];
        freqPlus = fv[2];
        freqValue.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                typeFreq();
            }
        });
        rows.addView(new View(this), lp(1, 0, 1f));
        TextView[] gv = new TextView[3];
        rows.addView(valueRow("Gain", null, gv, new View.OnClickListener() {
            public void onClick(View v) {
                stepGain(-1);
            }
        }, new View.OnClickListener() {
            public void onClick(View v) {
                stepGain(1);
            }
        }), lp(MATCH, dp(46), 0));
        gainValue = gv[0];
        gainMinus = gv[1];
        gainPlus = gv[2];
        rows.addView(new View(this), lp(1, 0, 1f));
        // row 5: Width, its value, and the slider
        LinearLayout r5 = new LinearLayout(this);
        r5.setOrientation(LinearLayout.HORIZONTAL);
        r5.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout wl = new LinearLayout(this);
        wl.setOrientation(LinearLayout.VERTICAL);
        wl.addView(Ui.text(this, "Width", 15, Ui.ON_SURFACE_VAR, false));
        LinearLayout wv = new LinearLayout(this);
        wv.setOrientation(LinearLayout.HORIZONTAL);
        wv.setGravity(Gravity.BOTTOM);
        widthValue = Ui.text(this, "", 22, Ui.ON_SURFACE, true);
        wv.addView(widthValue);
        widthValue.setSingleLine(true);
        widthNote = Ui.text(this, "", 13, Ui.ON_SURFACE_VAR, false);
        widthNote.setSingleLine(true);
        widthNote.setPadding(dp(10), 0, 0, dp(2));
        wv.addView(widthNote);
        LinearLayout.LayoutParams wvl = lp(WRAP, WRAP, 0);
        wvl.setMargins(0, dp(4), 0, 0);
        wl.addView(wv, wvl);
        r5.addView(wl, lp(0, WRAP, 1f));
        widthSlider = new WSlider(this);
        widthSlider.setListener(this);
        r5.addView(widthSlider, lp(dp(150), dp(51), 0));
        rows.addView(r5, lp(MATCH, dp(51), 0));
        below.addView(rows, new FrameLayout.LayoutParams(MATCH, MATCH));
        bandRows = rows;
        bandEmpty = Ui.text(this, "No bands yet. Add one with + Add band below; each band is a dot on the curve to drag.",
                17, Ui.ON_SURFACE_VAR, false);
        bandEmpty.setPadding(dp(4), dp(24), dp(4), 0);
        bandEmpty.setLineSpacing(0, 1.15f);
        below.addView(bandEmpty, new FrameLayout.LayoutParams(MATCH, WRAP));
        card.addView(below, lp(MATCH, 0, 1f));
        return card;
    }

    /**
     * The band card's four type chips on one line: the largest text size from 16 sp down to 12 sp
     * at which all four fit in avail px (measured bold, as the selected one is drawn), each chip as
     * wide as its own text. Returns the chips' weights for the row.
     */
    private float[] fitTypeChips(int avail, int margin, int padX) {
        android.graphics.Paint p = new android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG);
        p.setTypeface(Typeface.DEFAULT_BOLD);
        float sd = getResources().getDisplayMetrics().scaledDensity;
        float[] w = new float[4];
        float size = 16f;
        while (true) {
            p.setTextSize(size * sd);
            float sum = 3 * margin;
            for (int i = 0; i < 4; i++) {
                w[i] = p.measureText(typeChips[i].getText().toString()) + 2 * padX + dp(2);
                sum += w[i];
            }
            if (sum <= avail || size <= 12f) break;
            size -= 0.5f;
        }
        for (int i = 0; i < 4; i++) {
            typeChips[i].setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, size);
            typeChips[i].setPadding(padX, 0, padX, 0);
        }
        return w;
    }

    /** A band card row: the label, the value (and a hint), and - / + on the right. out = {value, -, +}. */
    private LinearLayout valueRow(String label, String hint, TextView[] out, View.OnClickListener minus, View.OnClickListener plus) {
        LinearLayout r = new LinearLayout(this);
        r.setOrientation(LinearLayout.HORIZONTAL);
        r.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        l.addView(Ui.text(this, label, 15, Ui.ON_SURFACE_VAR, false));
        LinearLayout v = new LinearLayout(this);
        v.setOrientation(LinearLayout.HORIZONTAL);
        v.setGravity(Gravity.BOTTOM);
        TextView val = Ui.text(this, "", 22, Ui.ON_SURFACE, true);
        v.addView(val);
        if (hint != null) {
            TextView ht = Ui.text(this, hint, 13, Ui.ON_SURFACE_VAR, false);
            ht.setSingleLine(true);
            ht.setPadding(dp(10), 0, 0, dp(2));
            v.addView(ht);
        }
        LinearLayout.LayoutParams vl = lp(WRAP, WRAP, 0);
        vl.setMargins(0, dp(4), 0, 0);
        l.addView(v, vl);
        r.addView(l, lp(0, WRAP, 1f));
        TextView m = smallButton("−", minus);
        r.addView(m, lp(dp(56), dp(40), 0));
        r.addView(new View(this), lp(dp(8), 1, 0));
        TextView p = smallButton("+", plus);
        r.addView(p, lp(dp(56), dp(40), 0));
        out[0] = val;
        out[1] = m;
        out[2] = p;
        return r;
    }

    /** Page content that scrolls if it is taller than the screen. */
    private ScrollView scroller(View content) {
        ScrollView sv = new ScrollView(this);
        sv.setFillViewport(true);
        sv.setVerticalScrollBarEnabled(false);
        sv.setOverScrollMode(View.OVER_SCROLL_NEVER);
        sv.addView(content);
        return sv;
    }

    private View buildSettingsPage() {
        LinearLayout pg = pageLayout();
        pg.addView(headerLine("Settings", "Sound processing and EQ Engine itself"), lp(MATCH, dp(HEADER_DP), 0));
        LinearLayout cols = new LinearLayout(this);
        cols.setOrientation(LinearLayout.HORIZONTAL);
        cols.setPadding(0, dp(10), 0, 0);
        pg.addView(scroller(cols), lp(MATCH, 0, 1f));

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
        swRate48 = new MSwitch(this);
        swRate48.setListener(new MSwitch.Listener() {
            public void onSwitch(MSwitch sw, boolean on) {
                setRate48(on);
            }
        });
        LinearLayout r48 = Ui.switchRow(this, "48 kHz output", "Android Auto's music without conversion. Checked every time; "
                + "falls back to 44.1 kHz", swRate48);
        rate48Sub = (TextView) ((LinearLayout) r48.getChildAt(0)).getChildAt(1);
        sound.addView(r48);
        // the converter: three chips with its status underneath
        LinearLayout chips = new LinearLayout(this);
        chips.setGravity(Gravity.CENTER_VERTICAL);
        for (int i = 0; i < 3; i++) {
            final String q = CONV_Q[i];
            convChips[i] = Ui.chip(this, CONV_LABEL[i], new View.OnClickListener() {
                public void onClick(View v) {
                    askConverter(q);
                }
            });
            LinearLayout.LayoutParams cl = lp(WRAP, dp(42), 0);
            cl.setMargins(i == 0 ? 0 : dp(8), 0, 0, 0);
            chips.addView(convChips[i], cl);
        }
        LinearLayout convRow = Ui.actionRow(this, "Audio converter", null, chips);
        sound.addView(convRow);
        convLine = Ui.text(this, "", 15, Ui.ON_SURFACE_VAR, false);
        convLine.setLineSpacing(0, 1.1f);
        convLine.setPadding(0, 0, 0, dp(4));
        convLine.setMaxLines(3);
        convLine.setEllipsize(TextUtils.TruncateAt.END);
        sound.addView(convLine);
        cols.addView(sound, lp(0, WRAP, 1.1f));
        cols.addView(new View(this), lp(dp(16), 1, 0));

        LinearLayout eng = Ui.card(this, "EQ Engine");
        swMaster = new MSwitch(this);
        swMaster.setOn(true, false);
        swMaster.setListener(new MSwitch.Listener() {
            public void onSwitch(MSwitch sw, boolean on) {
                askMaster(on);
            }
        });
        eng.addView(Ui.switchRow(this, "EQ Engine", "Loads at every start. Off = stock audio", swMaster));
        // EQ on CarPlay (0.7.4: on by default; one switch for the layer in the CarPlay app and its EQ)
        swCp = new MSwitch(this);
        swCp.setOn(s.cpEq, false);
        swCp.setListener(new MSwitch.Listener() {
            public void onSwitch(MSwitch sw, boolean on) {
                setCarPlay(on);
            }
        });
        LinearLayout cpRow = Ui.switchRow(this, "EQ on CarPlay", "", swCp);
        cpSub = (TextView) ((LinearLayout) cpRow.getChildAt(0)).getChildAt(1);
        eng.addView(cpRow);
        eng.addView(Ui.actionRow(this, "Restart Android audio", "A few seconds of silence. Parked only",
                Ui.button(this, "Restart", Ui.TONAL, new View.OnClickListener() {
                    public void onClick(View v) {
                        askRestart();
                    }
                })));
        eng.addView(Ui.actionRow(this, "Factory sound settings", "The car's own tone, fader and balance. Set Bass, Midrange "
                + "and Treble to Center so EQ Engine is the only tone control",
                Ui.button(this, "Open", Ui.TONAL, new View.OnClickListener() {
                    public void onClick(View v) {
                        openFactory(".sound.AudioTune", "sound settings");
                    }
                })));
        cols.addView(eng, lp(0, WRAP, 1f));
        return pg;
    }

    private static final String[] TILE_NAMES = {"Boot step", "EQ filter", "Output", "Processing", "Levels", "App"};

    private View buildStatusPage() {
        LinearLayout pg = pageLayout();
        LinearLayout h = headerLine("Status", "What the boot step and the filter report");
        headerButton(h, "Diagnostics", Ui.TONAL, new View.OnClickListener() {
            public void onClick(View v) {
                showPage(DIAG);
            }
        });
        pg.addView(h, lp(MATCH, dp(HEADER_DP), 0));
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
                tileValue[i].setEllipsize(TextUtils.TruncateAt.END);
                t.addView(tileValue[i]);
                tileDetail[i] = Ui.text(this, "", 14.5f, Ui.ON_SURFACE_VAR, false);
                tileDetail[i].setMaxLines(2);
                tileDetail[i].setEllipsize(TextUtils.TruncateAt.END);
                tileDetail[i].setLineSpacing(0, 1.1f);
                t.addView(tileDetail[i]);
                LinearLayout.LayoutParams tl = lp(0, MATCH, 1f);
                tl.setMargins(col == 0 ? 0 : dp(5), row == 0 ? 0 : dp(5), col == 0 ? dp(5) : 0, row == 2 ? 0 : dp(5));
                r.addView(t, tl);
            }
            grid.addView(r, lp(MATCH, 0, 1f));
        }
        cols.addView(grid, lp(0, MATCH, 1.25f));
        cols.addView(new View(this), lp(dp(12), 1, 0));

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

    private View buildDiagPage() {
        LinearLayout pg = pageLayout();
        LinearLayout h = headerLine("Diagnostics", "Logs and reports for troubleshooting");
        headerButton(h, "Back to Status", Ui.OUTLINED, new View.OnClickListener() {
            public void onClick(View v) {
                showPage(NavRail.STATUS);
            }
        });
        pg.addView(h, lp(MATCH, dp(HEADER_DP), 0));
        LinearLayout cols = new LinearLayout(this);
        cols.setOrientation(LinearLayout.HORIZONTAL);
        cols.setPadding(0, dp(10), 0, 0);
        pg.addView(scroller(cols), lp(MATCH, 0, 1f));

        LinearLayout logs = Ui.card(this, "Logs");
        swLog = new MSwitch(this);
        swLog.setListener(new MSwitch.Listener() {
            public void onSwitch(MSwitch sw, boolean on) {
                setLog(on);
            }
        });
        logs.addView(Ui.switchRow(this, "Detailed logging", "Every change, and an audio summary every 30 s. Off again "
                + "after each update", swLog));
        LinearLayout saveBtns = new LinearLayout(this);
        saveBtns.setGravity(Gravity.CENTER_VERTICAL);
        saveBtns.addView(Ui.button(this, "Report", Ui.TONAL, new View.OnClickListener() {
            public void onClick(View v) {
                askReport();
            }
        }), lp(WRAP, dp(46), 0));
        saveBtns.addView(new View(this), lp(dp(8), 1, 0));
        saveBtns.addView(Ui.button(this, "All logs", Ui.TONAL, new View.OnClickListener() {
            public void onClick(View v) {
                saveLogs();
            }
        }), lp(WRAP, dp(46), 0));
        logs.addView(Ui.actionRow(this, "Save to USB", "Report: for sharing. All logs: private", saveBtns));
        shotBtn = Ui.button(this, "In " + SHOT_SECONDS + " s", Ui.TONAL, new View.OnClickListener() {
            public void onClick(View v) {
                takeShot();
            }
        });
        logs.addView(Ui.actionRow(this, "Screenshot to USB", "Of whatever is on screen " + SHOT_SECONDS + " s after the "
                + "tap; saved to the stick only", shotBtn));
        TextView ln = Ui.text(this, "All logs hold the phone's name, Bluetooth addresses and song titles; share them only "
                + "with someone you trust. The report leaves those out.", 14, Ui.ON_SURFACE_VAR, false);
        ln.setLineSpacing(0, 1.1f);
        ln.setPadding(0, dp(6), 0, 0);
        logs.addView(ln);
        cols.addView(logs, lp(0, WRAP, 1.4f));
        cols.addView(new View(this), lp(dp(16), 1, 0));

        LinearLayout tr = Ui.card(this, "Audio trace");
        TextView d = Ui.text(this, "Records " + TRACE_SECONDS + " s of Android's system log, with snapshots of the audio "
                + "system before and after. All logs copies it to the stick.",
                15, Ui.ON_SURFACE_VAR, false);
        d.setLineSpacing(0, 1.15f);
        tr.addView(d);
        LinearLayout br = new LinearLayout(this);
        br.setGravity(Gravity.CENTER_VERTICAL);
        br.setPadding(0, dp(12), 0, dp(4));
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
        traceInfo.setPadding(0, dp(6), 0, dp(4));
        tr.addView(traceInfo);
        cols.addView(tr, lp(0, WRAP, 1f));
        cols.addView(new View(this), lp(dp(16), 1, 0));

        LinearLayout cpc = Ui.card(this, "CarPlay");
        cpInfoApp = cpItem(cpc, "In the CarPlay app");
        cpInfoMusic = cpItem(cpc, "Music");
        cpInfoEq = cpItem(cpc, "EQ");
        setText(cpItem(cpc, "Siri and calls"), "Never processed");
        TextView cn = Ui.text(this, "The switch is in Settings (EQ on CarPlay).", 14, Ui.ON_SURFACE_VAR, false);
        cn.setPadding(0, dp(4), 0, 0);
        cpc.addView(cn);
        cols.addView(cpc, lp(0, WRAP, 1f));
        return pg;
    }

    /** One item of the Diagnostics CarPlay card: its name, then the text view for its value. */
    private TextView cpItem(LinearLayout card, String name) {
        TextView n = Ui.text(this, name, 17, Ui.ON_SURFACE, false);
        n.setPadding(0, dp(4), 0, dp(2));
        card.addView(n);
        TextView v = Ui.text(this, "-", 15, Ui.ON_SURFACE_VAR, false);
        v.setLineSpacing(0, 1.1f);
        v.setPadding(0, 0, 0, dp(6));
        card.addView(v);
        return v;
    }

    private View buildPositionPage() {
        LinearLayout pg = pageLayout();
        pg.addView(headerLine("Listening position", "Times the speakers for one seat by delaying the side that is closer to it"),
                lp(MATCH, dp(HEADER_DP), 0));
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
        cols.addView(new View(this), lp(dp(16), 1, 0));

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
        info.addView(new View(this), lp(1, dp(10), 0));
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
        seat.addView(Ui.button(this, "−", Ui.TONAL, new View.OnClickListener() {
            public void onClick(View v) {
                stepSeatDelay(-1);
            }
        }), lp(dp(64), dp(46), 0));
        seat.addView(new View(this), lp(dp(8), 1, 0));
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
