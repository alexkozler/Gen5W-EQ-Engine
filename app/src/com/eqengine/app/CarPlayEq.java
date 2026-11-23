package com.eqengine.app;

import android.os.SystemClock;

import java.io.File;
import java.io.FileOutputStream;
import java.io.RandomAccessFile;
import java.nio.ByteOrder;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;

/**
 * EQ on CarPlay (0.7.3; on by default from 0.7.4; native/cpeq.h has the two files' layouts). The CarPlay watch
 * runs EQ Engine's filter inside the factory CarPlay app on CarPlay's music. This class
 * - writes the app's control file (the EQ settings, exactly what Android's filter gets, the
 *   Diagnostics switch, and how long the live view is wanted), on the background thread, latest
 *   first: a burst of slider moves becomes one write;
 * - maps the watch's live file read-only (on the background thread) and hands the screen its
 *   numbers (the level, the live view, the processing time) as the same arrays the audio server's
 *   filter gives, so the meter, the live view and Status show CarPlay's music while it plays.
 * Reading the mapping is a memory read; the screen's thread does no file work.
 */
final class CarPlayEq {
    static final String CTL = "/data/eqengine/share/cp_eq.bin";
    static final String LIVE = "/data/eqengine/cpw/live.bin";
    private static final int CPE_MAGIC = 0x31455043, CPE_VERSION = 1, CPE_HDR = 6, CPE_NSET = 99;
    private static final int CPL_MAGIC = 0x314c5043, CPL_BYTES = 4096;
    /* cpl_live, as int32 indexes */
    private static final int L_MAGIC = 0, L_SEQ = 2, L_STATE = 4, L_WHY = 5, L_RATE = 6, L_FRAMES = 7, L_BLKSEQ = 8,
            L_BLKMS = 9, L_PEAK = 10, L_RMS = 11, L_AVG = 12, L_MAX = 13, L_MING = 14, L_LIMITED = 15, L_CLIPPED = 16,
            L_INCLIP = 17, L_CTLSEQ = 18, L_LIB = 19, L_SPECSEQ = 20, L_SPECMS = 21, L_SPEC = 22;
    static final int NSPEC = 48, L_N = L_SPEC + NSPEC;
    static final int IDLE = 0, PASSING = 1, PROCESSING = 2;
    static final int WHY_NONE = 0, WHY_SWITCH = 1, WHY_NOSET = 2, WHY_OFF = 3, WHY_FORMAT = 4, WHY_MIC = 5, WHY_STARTED = 6;

    private static final Object LOCK = new Object();
    private static byte[] nextSet, lastSet;
    private static boolean nextOn, lastOn, queued, warned;
    private static int seq = (int) (SystemClock.uptimeMillis() & 0x3fffffff);
    private static volatile int liveUntil;
    private static long lastLive;
    private static volatile MappedByteBuffer map;
    private static volatile long mapTried;
    private static boolean mapping;

    private CarPlayEq() {}

    // ------------------------------------------------------------------ the control file

    /** The settings as they are now (called with every push to Android's filter, and at the start). */
    static void push(EqSettings s) {
        byte[] b = s.toParam(3);
        synchronized (LOCK) {
            lastSet = b;
            lastOn = s.cpEq;
        }
        post(b, s.cpEq);
    }

    /** While the live view is shown: keeps the watch analysing CarPlay's music (written once a second). */
    static void keepLive() {
        long now = SystemClock.uptimeMillis();
        if (now - lastLive < 1000) return;
        lastLive = now;
        liveUntil = (int) (now + 3000);
        byte[] b;
        boolean on;
        synchronized (LOCK) {
            b = lastSet;
            on = lastOn;
        }
        if (b != null) post(b, on);
    }

    /** Every few seconds: writes the file again if it went away (EQ Engine off and on), maps the live file. */
    static void tick(EqSettings s) {
        final byte[] b = s.toParam(3);
        final boolean on = s.cpEq;
        synchronized (LOCK) {
            lastSet = b;
            lastOn = on;
        }
        Bg.run(new Runnable() {
            public void run() {
                if (!new File(CTL).exists()) write(b, on);
                if (map == null || stale()) mapLive();
            }
        });
    }

    private static void post(byte[] b, boolean on) {
        synchronized (LOCK) {
            nextSet = b;
            nextOn = on;
            if (queued) return;
            queued = true;
        }
        Bg.run(new Runnable() {
            public void run() {
                byte[] x;
                boolean o;
                synchronized (LOCK) {
                    x = nextSet;
                    o = nextOn;
                    queued = false;
                }
                write(x, o);
            }
        });
    }

    /** On the background thread: a temporary file, then renamed, so the watch never reads half of one. */
    private static void write(byte[] set, boolean on) {
        if (set == null || set.length != CPE_NSET * 4) return;
        File f = new File(CTL), dir = f.getParentFile();
        if (dir == null || !dir.isDirectory()) return; // made by the installer (an older install has none yet)
        int[] h = {CPE_MAGIC, CPE_VERSION, ++seq, on ? 1 : 0, liveUntil, 0};
        byte[] all = new byte[(CPE_HDR + CPE_NSET) * 4];
        System.arraycopy(Engine.intsToBytes(h), 0, all, 0, CPE_HDR * 4);
        System.arraycopy(set, 0, all, CPE_HDR * 4, set.length);
        File tmp = new File(dir, "cp_eq.bin.tmp");
        FileOutputStream o = null;
        try {
            o = new FileOutputStream(tmp);
            o.write(all);
            o.close();
            o = null;
            tmp.setReadable(true, false); // the CarPlay app reads it (apps write with umask 077)
            if (!tmp.renameTo(f)) throw new java.io.IOException("rename failed");
        } catch (Throwable t) {
            if (!warned) EqLog.e("writing the CarPlay EQ's settings failed", t);
            warned = true;
        } finally {
            if (o != null) try {
                o.close();
            } catch (Throwable ignored) {
            }
        }
    }

    // ------------------------------------------------------------------ the live file

    /** Never mapped, or not playing through the EQ: mapped again every 30 s (a new CarPlay watch may have made a new file). */
    private static boolean stale() {
        int[] v = snapshot();
        return v == null || !playing(v) && SystemClock.uptimeMillis() - mapTried > 30000;
    }

    /** On the background thread, at most every 5 s. */
    private static void mapLive() {
        long now = SystemClock.uptimeMillis();
        if (now - mapTried < 5000) return;
        mapTried = now;
        File f = new File(LIVE);
        if (!f.exists() || f.length() < CPL_BYTES) {
            map = null;
            return;
        }
        RandomAccessFile r = null;
        try {
            r = new RandomAccessFile(f, "r");
            MappedByteBuffer m = r.getChannel().map(FileChannel.MapMode.READ_ONLY, 0, CPL_BYTES);
            m.order(ByteOrder.LITTLE_ENDIAN);
            map = m.getInt(4 * L_MAGIC) == CPL_MAGIC ? m : null;
        } catch (Throwable t) {
            map = null;
        } finally {
            if (r != null) try {
                r.close(); // the mapping stays
            } catch (Throwable ignored) {
            }
        }
    }

    /** One consistent copy of the live file's numbers (cpl_live as ints), or null. */
    static int[] snapshot() {
        MappedByteBuffer m = map;
        if (m == null) return null;
        int[] v = new int[L_N];
        for (int t = 0; t < 4; t++) {
            int s1 = m.getInt(4 * L_SEQ);
            if ((s1 & 1) != 0) continue;
            for (int i = 0; i < L_N; i++) v[i] = m.getInt(4 * i);
            if (m.getInt(4 * L_SEQ) == s1 && v[L_MAGIC] == CPL_MAGIC) return v;
        }
        return null;
    }

    /** ms since a CLOCK_MONOTONIC time in ms (low 32 bits), as the watch writes them. */
    private static int age(int ms) {
        return (int) SystemClock.uptimeMillis() - ms;
    }

    /** CarPlay's music is going through the EQ right now (a buffer in the last half second). */
    static boolean playing(int[] v) {
        return v != null && v[L_STATE] == PROCESSING && age(v[L_BLKMS]) >= 0 && age(v[L_BLKMS]) < 500;
    }

    /** As Engine.P_LEVEL: buffers, age ms, peak, average 0.01 dBFS, frames, rate. */
    static int[] level(int[] v) {
        return new int[] {v[L_BLKSEQ], age(v[L_BLKMS]), v[L_PEAK], v[L_RMS], v[L_FRAMES], v[L_RATE]};
    }

    /** As Engine.P_SPECTRUM: analyses, age ms (-1 none), bands, rate, band levels; null when there is none yet. */
    static int[] spectrum(int[] v) {
        if (v[L_SPECSEQ] == 0) return null;
        int[] s = new int[4 + NSPEC];
        s[0] = v[L_SPECSEQ];
        s[1] = age(v[L_SPECMS]);
        s[2] = NSPEC;
        s[3] = v[L_RATE];
        System.arraycopy(v, L_SPEC, s, 4, NSPEC);
        return s;
    }

    static int state(int[] v) {
        return v == null ? IDLE : v[L_STATE];
    }

    static int why(int[] v) {
        return v == null ? WHY_NONE : v[L_WHY];
    }

    static int rate(int[] v) {
        return v[L_RATE];
    }

    /** Processing per buffer over the last second (ns): {average, largest}, and the buffer's frames. */
    static int[] processing(int[] v) {
        return new int[] {v[L_AVG], v[L_MAX], v[L_FRAMES]};
    }

    /** The clip guard's lowest gain over the last second, x 10000 (10000 = idle). */
    static int minGain(int[] v) {
        return v[L_MING];
    }

    static int arrivedClipped(int[] v) {
        return v[L_INCLIP];
    }

    /** The live file says why a stream plays untouched, in a few words for the screen. */
    static String whyText(int why) {
        switch (why) {
        case WHY_SWITCH: return "switched off here";
        case WHY_NOSET: return "no settings sent yet";
        case WHY_OFF: return "EQ Engine is off";
        case WHY_FORMAT: return "not the music stream (Siri, a call)";
        case WHY_MIC: return "dry during Siri or a call";
        case WHY_STARTED: return "gets the EQ from the next track or resume";
        default: return "";
        }
    }
}
