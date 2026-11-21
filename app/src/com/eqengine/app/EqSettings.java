package com.eqengine.app;

import android.content.Context;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileReader;

/**
 * EQ settings and presets. Stored in /data/eqengine/settings (a folder the installer gives to
 * this app, kept across EQ Engine updates), or in the app's own folder if that is not writable.
 * Files are read on whichever thread asks (the screen reads them on the background thread, Bg)
 * and written on the background thread. "hq" is a leftover from 0.4 and is not saved.
 */
final class EqSettings {
    static final int NB = 10;
    static final String[] LABELS = {"31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"};
    static final double[] CENTRES = {31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
    static final int BAND_MIN = -1200, BAND_MAX = 1200; // slider range, 0.01 dB
    static final int PRE_MIN = -1800, PRE_MAX = 600;
    static final int STEP = 50;                         // 0.5 dB
    static final String SHARED_DIR = "/data/eqengine/settings";

    // Genre presets in the spirit of car head units, in 0.01 dB for 31 Hz .. 16 kHz. Kept within
    // +-6 dB; loading one also sets the preamp to minus its largest boost.
    static final String[] BUILTIN_NAMES = {"Flat", "Rock", "Pop", "Jazz", "Classical", "EDM", "Hip-Hop", "Acoustic",
            "Vocal", "Speech", "Bass boost", "Treble boost", "Loudness"};
    static final int[][] BUILTIN = {
            {0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
            {500, 400, 200, -100, -200, -100, 100, 300, 400, 400},
            {-100, 100, 250, 300, 150, 0, -50, 50, 150, 200},
            {300, 250, 100, 150, -100, -100, 0, 100, 200, 300},
            {250, 200, 100, 0, 0, 0, 0, 50, 150, 250},
            {600, 550, 300, 0, -150, -50, 50, 200, 400, 450},
            {600, 500, 250, 100, -100, -100, 50, 0, 100, 200},
            {250, 200, 100, 150, 200, 150, 200, 250, 200, 100},
            {-200, -150, -50, 100, 250, 350, 300, 150, 0, -100},
            {-600, -450, -200, 0, 200, 400, 400, 200, 0, -200},
            {600, 500, 350, 150, 0, 0, 0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 100, 300, 500, 600},
            {600, 450, 200, 0, -100, 0, 0, 200, 350, 450},
    };
    static final int USER_SLOTS = 4;

    boolean eqOn = true;
    int preamp = 0;
    boolean guard = true;
    int[] bands = new int[NB];
    boolean hq = true;
    String preset = "Flat";       // name shown on the EQ page; "Custom" after a manual change
    boolean detailedLog = false;  // troubleshooting log level; off again after every install or update
    int position = 0;             // listening position: -100 driver's seat .. 0 centre .. +100 passenger's seat
    int seatDelayUs = 1700;       // delay at a full seat offset (about 58 cm of path difference)
    boolean lowShelf, highShelf;  // 0.6.6: the 31 Hz / 16 kHz band as a shelf (one setting, not part of presets)
    /** Loaded from settings another app version saved (or from none): detailed logging was reset. */
    boolean fromOtherVersion;
    static final int SEAT_DELAY_MIN = 500, SEAT_DELAY_MAX = 3000, SEAT_DELAY_STEP = 100;
    static final double SPEED_OF_SOUND = 343.0; // m/s at 20 C

    EqSettings copy() {
        EqSettings s = new EqSettings();
        s.eqOn = eqOn;
        s.preamp = preamp;
        s.guard = guard;
        s.bands = bands.clone();
        s.hq = hq;
        s.preset = preset;
        s.detailedLog = detailedLog;
        s.position = position;
        s.seatDelayUs = seatDelayUs;
        s.lowShelf = lowShelf;
        s.highShelf = highShelf;
        return s;
    }

    /** The filter's end-band types: 1 = 31 Hz shelf, 2 = 16 kHz shelf. */
    int ends() {
        return (lowShelf ? 1 : 0) | (highShelf ? 2 : 0);
    }

    /**
     * The engine's settings parameter, little-endian: layout 2 (int32[17], with the end-band
     * types) for the 0.6.6 filter, layout 1 (int32[16]) for an older one still in the audio server.
     */
    byte[] toParam(boolean layout2) {
        int[] v = new int[layout2 ? 17 : 16];
        v[0] = layout2 ? 2 : 1;
        v[1] = eqOn ? 1 : 0;
        v[2] = clamp(preamp, PRE_MIN, PRE_MAX);
        v[3] = guard ? 1 : 0;
        for (int i = 0; i < NB; i++) v[4 + i] = clamp(bands[i], BAND_MIN, BAND_MAX);
        v[14] = delayUs(true);
        v[15] = delayUs(false);
        if (layout2) v[16] = ends();
        return Engine.intsToBytes(v);
    }

    /** Delay for the left (true) or right channel: the side nearer the chosen seat is delayed. */
    int delayUs(boolean left) {
        int pos = clamp(position, -100, 100);
        int d = Math.abs(pos) * clamp(seatDelayUs, SEAT_DELAY_MIN, SEAT_DELAY_MAX) / 100;
        if (left) return pos < 0 ? d : 0;
        return pos > 0 ? d : 0;
    }

    String positionName() {
        if (position == 0) return "Center";
        if (position <= -100) return "Driver's seat";
        if (position >= 100) return "Passenger's seat";
        return Math.abs(position) + "% toward the " + (position < 0 ? "driver" : "passenger");
    }

    String describe() {
        StringBuilder sb = new StringBuilder();
        sb.append("eq ").append(eqOn ? "on" : "off").append(", preamp ").append(db(preamp)).append(", clip guard ")
                .append(guard ? "on" : "off").append(", position ").append(position).append(" (L ").append(delayUs(true))
                .append(" us, R ").append(delayUs(false)).append(" us)").append(", bands");
        for (int i = 0; i < NB; i++) sb.append(' ').append(LABELS[i]).append('=').append(db(bands[i]));
        sb.append(", 31 Hz ").append(lowShelf ? "shelf" : "peak").append(", 16 kHz ").append(highShelf ? "shelf" : "peak");
        return sb.toString();
    }

    static String db(int cdb) {
        String s = String.valueOf(Math.abs(cdb) / 100) + (Math.abs(cdb) % 100 == 0 ? "" : "." + (Math.abs(cdb) % 100) / 10);
        return (cdb > 0 ? "+" : cdb < 0 ? "-" : "") + s;
    }

    static int clamp(int v, int lo, int hi) {
        return v < lo ? lo : v > hi ? hi : v;
    }

    static int snap(int v) {
        return Math.round(v / (float) STEP) * STEP;
    }

    // ------------------------------------------------------------------ storage

    static File dir(Context ctx) {
        File shared = new File(SHARED_DIR);
        if (shared.isDirectory() && shared.canWrite()) return shared;
        return ctx.getFilesDir();
    }

    static EqSettings load(Context ctx) {
        EqSettings s = new EqSettings();
        File d = dir(ctx);
        boolean presetSeen = false;
        String savedBy = null;
        BufferedReader r = null;
        try {
            r = new BufferedReader(new FileReader(new File(d, "current.txt")));
            String line;
            while ((line = r.readLine()) != null) {
                int eq = line.indexOf('=');
                if (eq <= 0) continue;
                String k = line.substring(0, eq).trim(), v = line.substring(eq + 1).trim();
                try {
                    if (k.equals("eq_on")) s.eqOn = !"0".equals(v);
                    else if (k.equals("preset")) {
                        s.preset = v.length() > 0 && v.length() < 40 ? v : "Custom";
                        presetSeen = true;
                    }
                    else if (k.equals("log")) s.detailedLog = "1".equals(v);
                    else if (k.equals("app")) savedBy = v;
                    else if (k.equals("ends")) {
                        int e = Integer.parseInt(v);
                        s.lowShelf = (e & 1) != 0;
                        s.highShelf = (e & 2) != 0;
                    }
                    else if (k.equals("position")) s.position = clamp(Integer.parseInt(v), -100, 100);
                    else if (k.equals("seat_delay")) s.seatDelayUs = clamp(Integer.parseInt(v), SEAT_DELAY_MIN, SEAT_DELAY_MAX);
                    else if (k.equals("preamp")) s.preamp = clamp(Integer.parseInt(v), PRE_MIN, PRE_MAX);
                    else if (k.equals("guard")) s.guard = !"0".equals(v);
                    else if (k.equals("bands")) {
                        String[] f = v.split(",");
                        for (int i = 0; i < NB && i < f.length; i++)
                            s.bands[i] = clamp(Integer.parseInt(f[i].trim()), BAND_MIN, BAND_MAX);
                    }
                } catch (NumberFormatException ignored) {
                    // keep the default for a damaged value
                }
            }
        } catch (Throwable ignored) {
            // no settings yet
        } finally {
            Root.close(r);
        }
        // settings from 0.2 have no preset name: call a non-flat EQ "Custom"
        if (!presetSeen) {
            for (int v : s.bands) if (v != 0) s.preset = "Custom";
        }
        // detailed logging starts off after every install and update (settings are kept across them)
        if (!MainActivity.VERSION.equals(savedBy)) {
            s.detailedLog = false;
            s.fromOtherVersion = true;
        }
        s.hq = true;
        return s;
    }

    /**
     * The converter choice (Settings), in its own file ("converter": 4 very high quality, the default;
     * 3 high; 0 Android's default), read by the boot step at every start. Written only when the
     * choice is changed in the app, so the boot step's step-down after an unexpected audio restart
     * (which writes the file too) is never overwritten by a later save. 0.5's "vhq" file is read
     * when there is no choice yet (1 -> 4, 0 -> 3).
     */
    static String readConverter(Context ctx) {
        String v = Root.readFirstLine(converterFile(ctx));
        if (v != null) {
            v = v.trim();
            if (v.equals("0") || v.equals("3") || v.equals("4")) return v;
        }
        String old = Root.readFirstLine(vhqFile(ctx));
        if (old != null && old.trim().equals("0")) return "3";
        return "4";
    }

    /** On the background thread; done (may be null) runs on the screen's thread. */
    static void writeConverter(Context ctx, final String q, final Saved done) {
        final File f = converterFile(ctx), old = vhqFile(ctx);
        Bg.run(new Runnable() {
            public void run() {
                final boolean ok = writeAtomic(f, q + "\n");
                if (ok) old.delete();
                if (done != null) Bg.main(new Runnable() {
                    public void run() {
                        done.saved(ok);
                    }
                });
            }
        });
    }

    static File converterFile(Context ctx) {
        return new File(dir(ctx), "converter");
    }

    /** 48 kHz output (act.sh keep reads settings/rate48): on unless the file says 0. */
    static boolean readRate48(Context ctx) {
        String v = Root.readFirstLine(rate48File(ctx));
        return v == null || !v.trim().equals("0");
    }

    static void writeRate48(Context ctx, boolean on, Saved done) {
        writeAsync(rate48File(ctx), (on ? "1" : "0") + "\n", done);
    }

    static File rate48File(Context ctx) {
        return new File(dir(ctx), "rate48");
    }

    static File vhqFile(Context ctx) {
        return new File(dir(ctx), "vhq");
    }

    private String text() {
        StringBuilder sb = new StringBuilder();
        sb.append("eq_on=").append(eqOn ? 1 : 0).append('\n');
        sb.append("preamp=").append(preamp).append('\n');
        sb.append("guard=").append(guard ? 1 : 0).append('\n');
        sb.append("preset=").append(preset).append('\n');
        sb.append("log=").append(detailedLog ? 1 : 0).append('\n');
        sb.append("position=").append(position).append('\n');
        sb.append("seat_delay=").append(seatDelayUs).append('\n');
        sb.append("ends=").append(ends()).append('\n');
        sb.append("app=").append(MainActivity.VERSION).append('\n');
        sb.append("bands=");
        for (int i = 0; i < NB; i++) sb.append(i == 0 ? "" : ",").append(bands[i]);
        sb.append('\n');
        return sb.toString();
    }

    /** Saves on the background thread (the write is synced to storage); saves keep their order. */
    void saveAsync(Context ctx) {
        final File f = new File(dir(ctx), "current.txt");
        final String t = text();
        Bg.run(new Runnable() {
            public void run() {
                writeAtomic(f, t);
            }
        });
    }

    interface Saved {
        /** On the screen's thread. */
        void saved(boolean ok);
    }

    /** Writes text to f on the background thread, then calls back on the screen's thread. */
    static void writeAsync(final File f, final String text, final Saved done) {
        Bg.run(new Runnable() {
            public void run() {
                final boolean ok = writeAtomic(f, text);
                if (done != null) Bg.main(new Runnable() {
                    public void run() {
                        done.saved(ok);
                    }
                });
            }
        });
    }

    /** User preset: preamp + bands, or null if the slot is empty. */
    static int[] loadUser(Context ctx, int slot) {
        String line = Root.readFirstLine(new File(dir(ctx), "preset" + slot + ".txt"));
        if (line == null) return null;
        String[] f = line.trim().split(",");
        if (f.length != NB + 1) return null;
        int[] v = new int[NB + 1];
        try {
            for (int i = 0; i <= NB; i++) v[i] = Integer.parseInt(f[i].trim());
        } catch (NumberFormatException e) {
            return null;
        }
        v[0] = clamp(v[0], PRE_MIN, PRE_MAX);
        for (int i = 1; i <= NB; i++) v[i] = clamp(v[i], BAND_MIN, BAND_MAX);
        return v;
    }

    static void saveUser(Context ctx, int slot, EqSettings s, Saved done) {
        StringBuilder sb = new StringBuilder().append(s.preamp);
        for (int i = 0; i < NB; i++) sb.append(',').append(s.bands[i]);
        writeAsync(new File(dir(ctx), "preset" + slot + ".txt"), sb.append('\n').toString(), done);
    }

    private static boolean writeAtomic(File f, String text) {
        File tmp = new File(f.getPath() + ".tmp");
        FileOutputStream out = null;
        try {
            out = new FileOutputStream(tmp);
            out.write(text.getBytes("UTF-8"));
            out.getFD().sync();
            out.close();
            out = null;
            return tmp.renameTo(f);
        } catch (Throwable t) {
            EqLog.e("saving " + f + " failed", t);
            return false;
        } finally {
            Root.close(out);
        }
    }
}
