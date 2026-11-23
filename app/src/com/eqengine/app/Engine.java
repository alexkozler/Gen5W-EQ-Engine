package com.eqengine.app;

import android.app.Service;
import android.content.Context;
import android.media.audiofx.AudioEffect;
import android.os.Handler;
import android.os.Looper;

import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.Locale;
import java.util.UUID;

/**
 * Keeps the EQ Engine filter attached to all music output (session 0) and in step with the
 * settings. Runs on the main thread. Started by EqService (at every start, by the boot step) and
 * by the screen. Re-attaches by itself after Android's audio server restarts.
 */
final class Engine {
    static final UUID TYPE = UUID.fromString("1de0ea4c-d55d-460b-a1e5-4a8c2e95c191");
    static final UUID IMPL = UUID.fromString("64b3439e-9662-4040-9fd1-83f116f74988");
    static final int P_STATS = 2, P_VERSION = 3, P_SETTINGS = 10, P_RESPONSE = 11, P_GAINS = 12, P_VHQ = 13,
            P_SPECTRUM = 14, P_LEVEL = 15, P_PEAK = 16;
    /**
     * 0x324 = this filter (0.7.6: P_PEAK is the largest boost over its rate, 44.1 and 48 kHz);
     * 0x323 = 0.7.4-0.7.5's filter (the bands run a chunk at a time; the same sound as 0x322);
     * 0x322 = 0.7.1-0.7.3's filter (settings layout 3: Expert mode, up to 20 bands of its own);
     * 0x321 = 0.6.10's filter (adds P_PEAK, the largest boost of any settings from the solved filters);
     * 0x320 = 0.6.6 filter (settings layout 2 with the end-band types, P_SPECTRUM, P_LEVEL);
     * 0x310 = 0.5 filter (adds P_VHQ); 0x300 = 0.4 filter. The older ones stay in the audio server
     * after an update until it restarts, so they are still driven (without the new parts).
     */
    static final int LIB_VERSION = 0x324, LIB_VERSION_074 = 0x323, LIB_VERSION_0611 = 0x322, LIB_VERSION_0610 = 0x321, LIB_VERSION_066 = 0x320, LIB_VERSION_05 = 0x310,
            LIB_VERSION_04 = 0x300;
    static final int NRESP = 96, NSTATS = 28, NSPEC = 48;
    static final int RESP_NONE = 0x80000000;
    private static final long TICK_MS = 3000, STATS_MS = 250, SUMMARY_MS = 30000, SUMMARY_QUIET_MS = 600000;
    /** How often the screen reads the filter: Status tiles only, the EQ page's meter, or the meter and the live view. */
    static final int POLL_STATS = 0, POLL_METER = 1, POLL_LIVE = 2;
    private static final long[] POLL_MS = {250, 50, 40};

    interface Listener {
        void onEngine();
    }

    private static Engine instance;

    static synchronized Engine get(Context c) {
        if (instance == null) instance = new Engine(c.getApplicationContext());
        return instance;
    }

    private final Context ctx;
    private final Handler h = new Handler(Looper.getMainLooper());
    private Method setP, getP;
    private Constructor<AudioEffect> ctor;
    private AudioEffect fx;
    private EqSettings settings;
    private boolean running;
    private Service service;
    private Listener listener;
    private int failures;
    private int[] stats;
    private int[] response;
    private String state = "not started";
    private boolean oldLibrary;
    private int oldLibraryPid = -1;
    private volatile boolean restartPending;
    private volatile int restartOldPid = -1;
    private volatile long restartAskedAt, newServerSince;
    private long attachedAt;
    private long lastPushAt;
    private boolean pushPending;
    // 30-second summary for the log
    private long sumStart;
    private int sumMaxNs, sumAvgNs, sumOutPeak, sumMinGain = 10000, sumFrameCount, sumRate;
    private boolean sumAudio;
    private int lastLimited = -1, lastClipped = -1, lastInClip = -1;
    private boolean changedInApp;
    private int pollMode = POLL_STATS;
    private boolean freshlyLoaded;
    private long lastStatsAt;
    private int[] level, spectrum;
    private int[] cpLive;

    private Engine(Context ctx) {
        this.ctx = ctx;
        try {
            setP = AudioEffect.class.getMethod("setParameter", byte[].class, byte[].class);
            getP = AudioEffect.class.getMethod("getParameter", byte[].class, byte[].class);
            ctor = AudioEffect.class.getConstructor(UUID.class, UUID.class, int.class, int.class);
        } catch (Throwable t) {
            EqLog.e("AudioEffect methods not found", t);
        }
        settings = loadSettings(ctx);
        freshlyLoaded = true;
        EqLog.detailed = settings.detailedLog;
    }

    /** Loads the settings; after an install or update, saves them back with detailed logging off. */
    private static EqSettings loadSettings(Context ctx) {
        EqSettings s = EqSettings.load(ctx);
        if (s.fromOtherVersion) {
            s.fromOtherVersion = false;
            s.saveAsync(ctx);
            EqLog.i("settings from another version (or none): detailed logging starts off in " + MainActivity.VERSION);
        }
        return s;
    }

    // ------------------------------------------------------------------ lifecycle

    void start(Service s) {
        if (s != null) service = s;
        if (running) return;
        running = true;
        // (just loaded by the constructor: reading again would see the same file before its save lands)
        if (!changedInApp && !freshlyLoaded) settings = loadSettings(ctx);
        freshlyLoaded = false;
        EqLog.detailed = settings.detailedLog;
        EqLog.i("engine started; settings: " + settings.describe());
        CarPlayEq.push(settings);
        h.post(tick);
    }

    void stop(String why) {
        running = false;
        service = null;
        h.removeCallbacks(tick);
        release(why);
        state = "stopped (" + why + ")";
    }

    boolean isRunning() {
        return running;
    }

    void setListener(Listener l) {
        listener = l;
        h.removeCallbacks(fast);
        if (l != null) h.post(fast);
        else {
            level = null;
            spectrum = null;
        }
    }

    /** POLL_STATS, POLL_METER or POLL_LIVE (the live view is read only in POLL_LIVE, so it stops otherwise). */
    void setPoll(int mode) {
        if (mode == pollMode) return;
        pollMode = mode;
        if (mode != POLL_LIVE) spectrum = null;
        if (mode == POLL_STATS) level = null;
        if (listener != null) {
            h.removeCallbacks(fast);
            h.post(fast);
        }
    }

    private final Runnable tick = new Runnable() {
        public void run() {
            if (!running) return;
            check();
            if (listener == null) readStats();
            CarPlayEq.tick(settings);
            h.postDelayed(this, TICK_MS);
        }
    };

    /**
     * While the screen is open. Each read is one short call to the filter in the audio server
     * (it answers from numbers it already has); the statistics, which also reset its "since the
     * last read" counters, are read every 250 ms whatever the mode.
     */
    private final Runnable fast = new Runnable() {
        public void run() {
            if (listener == null) return;
            long now = android.os.SystemClock.uptimeMillis();
            if (now - lastStatsAt >= STATS_MS - 5) {
                readStats();
                lastStatsAt = now;
            }
            // CarPlay's music through the CarPlay watch's EQ (0.7.3): its level and live view instead
            // (while CarPlay has the speaker link, Android's output cannot play). 0.7.6: Android's
            // filter is then not asked at all (two calls into the audio server every 40 ms, on this
            // thread, for numbers that were thrown away)
            if (pollMode == POLL_LIVE) CarPlayEq.keepLive();
            int[] cv = CarPlayEq.snapshot();
            cpLive = cv;
            if (CarPlayEq.playing(cv)) {
                level = pollMode >= POLL_METER ? CarPlayEq.level(cv) : null;
                spectrum = pollMode == POLL_LIVE ? CarPlayEq.spectrum(cv) : null;
            } else {
                boolean nw = newFilter();
                level = nw && pollMode >= POLL_METER ? readInts(P_LEVEL, 6) : null;
                spectrum = nw && pollMode == POLL_LIVE ? readInts(P_SPECTRUM, 4 + NSPEC) : null;
            }
            Listener l = listener;
            if (l != null) l.onEngine();
            h.postDelayed(this, POLL_MS[pollMode]);
        }
    };

    /** The CarPlay watch's live file as last read (CarPlayEq.snapshot), or null; read now when the screen polls nothing. */
    int[] cpLive() {
        return listener != null ? cpLive : CarPlayEq.snapshot();
    }

    /** The last buffer's output level from the 0.6.6 filter (see eqengine.c level_read), or null. */
    int[] level() {
        return level;
    }

    /** The live view's band levels from the 0.6.6 filter (see eqengine.c spec_read), or null. */
    int[] spectrum() {
        return spectrum;
    }

    /** The running audio server has the 0.6.6 filter or a later one (end-band shelves, live view, buffer level). */
    boolean newFilter() {
        return fx != null && (expertLib(libVersion) || libVersion == LIB_VERSION_0610 || libVersion == LIB_VERSION_066);
    }

    /** The running audio server has a filter that plays Expert mode (this version's or 0.7.1-0.7.3's). */
    boolean expertFilter() {
        return fx != null && expertLib(libVersion);
    }

    /** Filters that take settings layout 3 (Expert mode): 0x323 and 0x322 behave the same to the app. */
    static boolean expertLib(int v) {
        return v == LIB_VERSION || v == LIB_VERSION_074 || v == LIB_VERSION_0611;
    }

    /** The settings layout the running filter takes: 3 (Expert mode), 2 (end-band types) or 1. */
    private int layout() {
        return expertLib(libVersion) ? 3 : newFilter() ? 2 : 1;
    }

    /** The Easy page's solved filter gains in 0.01 dB (what the ten bands really do), or null. */
    int[] gains() {
        return newFilter() ? readInts(P_GAINS, EqSettings.NB) : null;
    }

    /** The output's sample rate as the filter has it, or 0. */
    int rate() {
        int[] st = stats();
        return st != null && st.length > 1 ? st[1] : 0;
    }

    /**
     * The largest boost of settings x's solved band filters, 0 Hz to half the sample rate, as
     * {0.01 dB, Hz (0 = 0 Hz), sample rate}; null when the filter cannot tell (an older one, not
     * attached, or no rate yet). Nothing is applied: the filter works it out on the side.
     */
    int[] peakFor(EqSettings x) {
        if (fx == null || (!expertLib(libVersion) && libVersion != LIB_VERSION_0610) || setP == null) return null;
        try {
            int rc = (Integer) setP.invoke(fx, intsToBytes(new int[] {P_PEAK}), x.toParam(layout()));
            if (rc != 0) return null;
        } catch (Throwable t) {
            EqLog.e("asking the filter for the largest boost failed", unwrap(t));
            return null;
        }
        return readInts(P_PEAK, 3);
    }

    /** Attached to a filter older than Expert mode (the audio server started before the update). */
    boolean olderFilter() {
        return fx != null && !expertLib(libVersion);
    }

    private void check() {
        BootStatus bs = BootStatus.read();
        if (!bs.allowed()) {
            if (fx != null) release("EQ Engine is " + (bs.state().length() == 0 ? "not set up" : bs.state()));
            setState(bs.finalOff() ? "EQ Engine is off (" + bs.state() + ")" : "waiting for the boot step ("
                    + (bs.state().length() == 0 ? "no status yet" : bs.state()) + ")");
            if (bs.finalOff() && service != null) {
                EqLog.i("EQ Engine is off (" + bs.state() + "); the EQ service stops");
                Service s = service;
                stop("EQ Engine is off");
                s.stopSelf();
            }
            return;
        }
        if (restartPending) {
            // An audio restart was asked for: the EQ keeps working on the old audio server until it is
            // stopped, then attaches to the new one once that has been up for 3 s (Android Auto and the
            // car's own software reconnect within about a second).
            long now = System.currentTimeMillis();
            int p = Root.mediaserverPid();
            if (now - restartAskedAt > 60000) {
                restartPending = false;
            } else if (p == restartOldPid) {
                if (fx != null) check2();
                return;
            } else {
                if (fx != null) release("audio server restarting");
                if (p <= 0) {
                    newServerSince = 0;
                    return;
                }
                if (newServerSince == 0) newServerSince = now;
                if (now - newServerSince < 3000) return;
                restartPending = false;
            }
        }
        if (fx == null) {
            // The stage 1 filter stays loaded until Android's audio server restarts: don't retry before that.
            if (oldLibrary && Root.mediaserverPid() == oldLibraryPid) return;
            attach();
            return;
        }
        check2();
    }

    private static boolean known(int v) {
        return expertLib(v) || v == LIB_VERSION_0610 || v == LIB_VERSION_066 || v == LIB_VERSION_05 || v == LIB_VERSION_04;
    }

    private void check2() {
        int v = version();
        if (known(v)) {
            failures = 0;
        } else if (++failures >= 2) {
            EqLog.w("the filter stopped answering (" + v + "); Android's audio server probably restarted");
            release("filter stopped answering");
            state = "re-attaching after an audio restart";
        }
    }

    private void attach() {
        if (ctor == null || setP == null || getP == null) {
            state = "this Android has no usable AudioEffect API";
            return;
        }
        boolean listed = false;
        try {
            AudioEffect.Descriptor[] all = AudioEffect.queryEffects();
            if (all != null)
                for (AudioEffect.Descriptor d : all)
                    if (IMPL.equals(d.uuid)) listed = true;
        } catch (Throwable t) {
            EqLog.e("queryEffects failed", t);
        }
        if (!listed) {
            setState("Android doesn't list the EQ Engine filter: restart Android audio once (Status tab)");
            return;
        }
        try {
            fx = ctor.newInstance(TYPE, IMPL, 0, 0);
        } catch (Throwable t) {
            Throwable c = unwrap(t);
            if (!state.startsWith("attaching failed")) EqLog.e("creating the EQ on session 0 failed", c);
            state = "attaching failed: " + c;
            fx = null;
            return;
        }
        int v = version();
        libVersion = v;
        if (!known(v)) {
            release("wrong filter version");
            oldLibrary = v == 0x100 || v == 0x200;
            oldLibraryPid = oldLibrary ? Root.mediaserverPid() : -1;
            setState(oldLibrary ? "an earlier EQ Engine filter is still loaded: restart the car (or Android audio in Settings)"
                    : "unexpected filter version " + Integer.toHexString(v));
            return;
        }
        oldLibrary = false;
        // a new filter instance counts from zero
        lastLimited = -1;
        lastClipped = -1;
        lastInClip = -1;
        int rc = pushNow();
        int en = -1;
        try {
            en = fx.setEnabled(true);
        } catch (Throwable t) {
            EqLog.e("enabling failed", t);
        }
        failures = 0;
        attachedAt = System.currentTimeMillis();
        boolean control = false;
        try {
            control = fx.hasControl();
        } catch (Throwable ignored) {
        }
        state = en == 0 && rc == 0 ? "EQ attached to all music" : "EQ attached, but enable returned " + en + ", settings " + rc;
        EqLog.i("attached to session 0: id " + safeId() + ", filter " + Integer.toHexString(v) + ", control " + control
                + ", settings rc " + rc + ", enable rc " + en + "; " + settings.describe());
        sumStart = System.currentTimeMillis();
    }

    private void setState(String s) {
        if (!s.equals(state)) EqLog.i("EQ: " + s);
        state = s;
    }

    private void release(String why) {
        if (fx == null) return;
        try {
            fx.release();
        } catch (Throwable t) {
            EqLog.e("release failed", t);
        }
        fx = null;
        stats = null;
        response = null;
        level = null;
        spectrum = null;
        EqLog.i("EQ detached (" + why + ")");
    }

    /** Releases now; the next check re-attaches (used before a deliberate audio restart). */
    /** An audio restart is about to be asked for (see check()). */
    void detachForRestart() {
        restartOldPid = Root.mediaserverPid();
        restartAskedAt = System.currentTimeMillis();
        newServerSince = 0;
        restartPending = true;
    }

    /** act.sh has returned: if it did not restart anything (refused), carry on as before. */
    void restartFinished() {
        if (Root.mediaserverPid() == restartOldPid) restartPending = false;
    }

    // ------------------------------------------------------------------ settings

    EqSettings settings() {
        return settings;
    }

    /** New settings from the screen; pushes at most every 50 ms (the last one always goes through). */
    void update(EqSettings s) {
        settings = s.copy();
        changedInApp = true;
        long now = System.currentTimeMillis();
        if (now - lastPushAt >= 50) {
            pushNow();
        } else if (!pushPending) {
            pushPending = true;
            h.postDelayed(pushLater, 50 - (now - lastPushAt));
        }
    }

    private final Runnable pushLater = new Runnable() {
        public void run() {
            pushPending = false;
            pushNow();
        }
    };

    private int pushNow() {
        lastPushAt = System.currentTimeMillis();
        // the CarPlay watch's EQ gets the same settings, whether Android's filter is attached or not
        CarPlayEq.push(settings);
        if (fx == null) return -1;
        int rc;
        try {
            // an older filter (until the next car start) gets the Easy settings in its own layout
            rc = (Integer) setP.invoke(fx, intsToBytes(new int[] {P_SETTINGS}), settings.toParam(layout()));
        } catch (Throwable t) {
            EqLog.e("sending settings failed", unwrap(t));
            return -2;
        }
        if (rc != 0) EqLog.w("the filter refused the settings (" + rc + "): " + settings.describe());
        else EqLog.d("settings sent: " + settings.describe());
        // the Easy graph's response (0.7.6: not in Expert, which draws its own curves; the next push
        // in Easy reads it again)
        if (!settings.expert || response == null) response = readInts(P_RESPONSE, NRESP);
        return rc;
    }

    // ------------------------------------------------------------------ reading

    boolean attached() {
        return fx != null;
    }

    String state() {
        return state;
    }

    long attachedAt() {
        return fx == null ? 0 : attachedAt;
    }

    int[] stats() {
        return stats;
    }

    private volatile int libVersion = -1;

    /**
     * Very high quality converter status from the filter in the audio server, or null (not attached,
     * or a 0.4 filter that cannot tell): [0] 0 not asked for / 1 tables loaded / -1 load failed,
     * [1] times Android set the tables up, [2] blocks converted down, [3] blocks converted up,
     * [4] taps per side, [5] phase bits, [6] table version.
     */
    int[] vhqStatus() {
        if (fx == null || (!expertLib(libVersion) && libVersion != LIB_VERSION_0610 && libVersion != LIB_VERSION_066
                && libVersion != LIB_VERSION_05)) return null;
        return readInts(P_VHQ, 8);
    }

    /** True when the audio server still runs a 0.4 filter (a car restart loads the new one). */
    boolean oldFilter04() {
        return fx != null && libVersion == LIB_VERSION_04;
    }

    /** EQ response in 0.01 dB at Engine.respHz(k), or null when not attached. */
    int[] response() {
        if (fx != null && response == null) response = readInts(P_RESPONSE, NRESP);
        return response;
    }

    static double respHz(int k) {
        return 20.0 * Math.pow(1000.0, k / (double) (NRESP - 1));
    }

    private int version() {
        int[] v = readInts(P_VERSION, 1);
        return v == null ? -1 : v[0];
    }

    private int safeId() {
        try {
            return fx.getId();
        } catch (Throwable t) {
            return -1;
        }
    }

    private int[] readInts(int id, int n) {
        if (fx == null) return null;
        try {
            byte[] v = new byte[n * 4];
            int r = (Integer) getP.invoke(fx, intsToBytes(new int[] {id}), v);
            if (r < v.length) return null;
            return bytesToInts(v, n);
        } catch (Throwable t) {
            return null;
        }
    }

    private void readStats() {
        if (fx == null) {
            stats = null;
            return;
        }
        int[] s = readInts(P_STATS, NSTATS);
        if (s == null) return;
        stats = s;
        summarise(s);
    }

    private void summarise(int[] s) {
        boolean flowing = s[13] >= 0 && s[13] < 1500;
        if (flowing) {
            sumAudio = true;
            sumMaxNs = Math.max(sumMaxNs, s[10]);
            sumAvgNs = s[9];
            sumOutPeak = Math.max(sumOutPeak, s[16]);
            sumMinGain = Math.min(sumMinGain, s[17]);
            sumFrameCount = s[4];
            sumRate = s[1];
        }
        long now = System.currentTimeMillis();
        if (now - sumStart < (EqLog.detailed ? SUMMARY_MS : SUMMARY_QUIET_MS)) return;
        if (sumAudio && sumRate > 0 && sumFrameCount > 0) {
            double bufUs = sumFrameCount * 1e6 / sumRate;
            EqLog.i(String.format(Locale.US,
                    "audio (last %d s): %d Hz, processing avg %.0f us, max %.0f us per %.0f ms buffer (%.2f%% / %.2f%% of real time), "
                            + "output peak %s, clip guard %s, limited samples %d, clipped %d, arrived clipped %d",
                    (now - sumStart) / 1000, sumRate, sumAvgNs / 1000.0, sumMaxNs / 1000.0, bufUs / 1000.0,
                    sumAvgNs / 10.0 / bufUs, sumMaxNs / 10.0 / bufUs, dbfs(sumOutPeak),
                    sumMinGain >= 9999 ? "idle" : String.format(Locale.US, "down to %.1f dB", 20 * Math.log10(sumMinGain / 10000.0)),
                    s[18] - (lastLimited < 0 ? 0 : lastLimited), s[22] - (lastClipped < 0 ? 0 : lastClipped),
                    s[27] - (lastInClip < 0 ? 0 : lastInClip)));
        }
        lastLimited = s[18];
        lastClipped = s[22];
        lastInClip = s[27];
        sumStart = now;
        sumAudio = false;
        sumMaxNs = 0;
        sumOutPeak = 0;
        sumMinGain = 10000;
    }

    /** "0.0" / "-12.3" / "silent", for a peak 0..32768. */
    static String dbfsShort(int peak) {
        if (peak <= 0) return "silent";
        return String.format(Locale.US, "%.1f", 20 * Math.log10(peak / 32768.0));
    }

    static String dbfs(int peak) {
        if (peak <= 0) return "silent";
        return String.format(Locale.US, "%.1f dBFS", 20 * Math.log10(peak / 32768.0));
    }

    // ------------------------------------------------------------------ helpers

    static byte[] intsToBytes(int[] v) {
        byte[] b = new byte[v.length * 4];
        for (int i = 0; i < v.length; i++) {
            b[4 * i] = (byte) v[i];
            b[4 * i + 1] = (byte) (v[i] >> 8);
            b[4 * i + 2] = (byte) (v[i] >> 16);
            b[4 * i + 3] = (byte) (v[i] >> 24);
        }
        return b;
    }

    static int[] bytesToInts(byte[] b, int n) {
        int[] v = new int[n];
        for (int i = 0; i < n; i++)
            v[i] = (b[4 * i] & 0xff) | (b[4 * i + 1] & 0xff) << 8 | (b[4 * i + 2] & 0xff) << 16 | (b[4 * i + 3] & 0xff) << 24;
        return v;
    }

    static Throwable unwrap(Throwable t) {
        if (t instanceof InvocationTargetException && t.getCause() != null) return t.getCause();
        return t;
    }
}
