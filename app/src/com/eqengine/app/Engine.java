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
    static final int P_STATS = 2, P_VERSION = 3, P_SETTINGS = 10, P_RESPONSE = 11, P_GAINS = 12, P_VHQ = 13;
    /** 0x310 = 0.5 filter (adds P_VHQ); 0x300 = 0.4 filter (same layout otherwise), still accepted. */
    static final int LIB_VERSION = 0x310, LIB_VERSION_04 = 0x300;
    static final int NRESP = 96, NSTATS = 28;
    static final int RESP_NONE = 0x80000000;
    private static final long TICK_MS = 3000, FAST_MS = 250, SUMMARY_MS = 30000, SUMMARY_QUIET_MS = 600000;

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

    private Engine(Context ctx) {
        this.ctx = ctx;
        try {
            setP = AudioEffect.class.getMethod("setParameter", byte[].class, byte[].class);
            getP = AudioEffect.class.getMethod("getParameter", byte[].class, byte[].class);
            ctor = AudioEffect.class.getConstructor(UUID.class, UUID.class, int.class, int.class);
        } catch (Throwable t) {
            EqLog.e("AudioEffect methods not found", t);
        }
        settings = EqSettings.load(ctx);
        EqLog.detailed = settings.detailedLog;
    }

    // ------------------------------------------------------------------ lifecycle

    void start(Service s) {
        if (s != null) service = s;
        if (running) return;
        running = true;
        if (!changedInApp) settings = EqSettings.load(ctx);
        EqLog.detailed = settings.detailedLog;
        EqLog.i("engine started; settings: " + settings.describe());
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
    }

    private final Runnable tick = new Runnable() {
        public void run() {
            if (!running) return;
            check();
            if (listener == null) readStats();
            h.postDelayed(this, TICK_MS);
        }
    };

    private final Runnable fast = new Runnable() {
        public void run() {
            if (listener == null) return;
            readStats();
            Listener l = listener;
            if (l != null) l.onEngine();
            h.postDelayed(this, FAST_MS);
        }
    };

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

    private void check2() {
        int v = version();
        if (v == LIB_VERSION || v == LIB_VERSION_04) {
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
        if (v != LIB_VERSION && v != LIB_VERSION_04) {
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
        EqLog.i("attached to session 0: id " + safeId() + ", control " + control + ", settings rc " + rc + ", enable rc " + en
                + "; " + settings.describe());
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
        if (fx == null) return -1;
        int rc;
        try {
            rc = (Integer) setP.invoke(fx, intsToBytes(new int[] {P_SETTINGS}), settings.toParam());
        } catch (Throwable t) {
            EqLog.e("sending settings failed", unwrap(t));
            return -2;
        }
        if (rc != 0) EqLog.w("the filter refused the settings (" + rc + "): " + settings.describe());
        else EqLog.d("settings sent: " + settings.describe());
        response = readInts(P_RESPONSE, NRESP);
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
        if (fx == null || libVersion != LIB_VERSION) return null;
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
