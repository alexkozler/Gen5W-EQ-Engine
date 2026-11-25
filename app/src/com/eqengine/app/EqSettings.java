package com.eqengine.app;

import android.content.Context;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Locale;

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
    // down to -24 dB, as far as the filter goes: the solved filters can boost up to about +22 dB
    // (a 31 Hz shelf at +12 next to 63 Hz at -12, at 0 Hz), and Auto preamp must cover that
    static final int PRE_MIN = -2400, PRE_MAX = 600;
    static final int STEP = 50;                         // 0.5 dB
    static final String SHARED_DIR = "/data/eqengine/settings";

    // 0.6.11: no built-in genre presets (written without hearing them on the car); Flat stays,
    // and four user slots that both modes share
    static final int USER_SLOTS = 4;

    // Expert mode (0.6.11): up to NX bands of its own. Each band is int[4] {type, frequency in
    // 0.01 Hz, gain in 0.01 dB (not for the low cut), width: peak = bandwidth in 0.001 octave,
    // low cut = Q x 1000, shelves = unused}, as the filter's settings layout 3 has them.
    static final int NX = 20;
    static final int X_PEAK = 1, X_LOW_SHELF = 2, X_HIGH_SHELF = 3, X_LOW_CUT = 4;
    static final String[] X_TYPES = {"", "Peak", "Low shelf", "High shelf", "Low cut"};
    static final int X_FMIN = 2000, X_FMAX = 2000000;
    static final int X_GAIN = 1500;
    static final int X_BWMIN = 100, X_BWMAX = 4000, X_BW_DEFAULT = 1000;
    static final int X_QMIN = 500, X_QMAX = 2000, X_Q_DEFAULT = 707;
    /** The Easy page's end bands as shelves: their midpoints, in 0.01 Hz (eqengine.c). */
    static final int LOW_SHELF_CHZ = 5000, HIGH_SHELF_CHZ = 1130000;
    /**
     * 0.7.8 (filter 0x326, settings layout 4): an Expert band's channel, a fifth value b[4]: left and
     * right alike (every band before), the mid only ((L + R) / 2, what both sides share) or the side
     * only ((L - R) / 2, what differs). The stereo width (percent) and the mono bass (Hz, 0 = off)
     * are Position-page settings, like the seat, not part of the EQ or its presets.
     */
    static final int CH_LR = 0, CH_MID = 1, CH_SIDE = 2;
    static final String[] CH_NAMES = {"L+R", "Mid", "Side"};
    static final int WIDTH_MIN = 0, WIDTH_MAX = 150, WIDTH_STEP = 10;
    static final int[] MONO_CHOICES = {0, 80, 120, 150};

    boolean eqOn = true;
    int preamp = 0;
    boolean guard = true;
    int[] bands = new int[NB];
    boolean hq = true;
    String preset = "Flat";       // name shown on the EQ page: Flat, User 1-4, or Custom after a change
    boolean detailedLog = false;  // troubleshooting log level; off again after every install or update
    int position = 0;             // listening position: -100 driver's seat .. 0 centre .. +100 passenger's seat
    int seatDelayUs = 1700;       // delay at a full seat offset (about 58 cm of path difference)
    boolean lowShelf, highShelf;  // 0.6.6: the 31 Hz / 16 kHz band as a shelf (one setting, not part of presets)
    boolean expert;               // 0.6.11: Expert mode (xb) plays instead of the ten sliders
    boolean expertSeen;           // the first switch to Expert (Copy Easy EQ or Start flat) is done
    ArrayList<int[]> xb = new ArrayList<int[]>(); // Expert bands, in frequency order
    String xPreset = "Flat";      // Expert's name on the EQ page (each mode keeps its own)
    int xSel;                     // the selected Expert band
    boolean cpEq = true;          // EQ on CarPlay (Settings; 0.7.4: on by default, one switch for the watch and its EQ)
    String cpwAck = "";           // 0.7.4: the last state/cpw_failed the app has told the user about (its id)
    String crashAck = "";         // after 0.7.6: the car start whose "kept restarting" the app has told the user about (its boot id)
    int width = 100;              // 0.7.8: stereo width, percent (100 = as recorded)
    int monoHz = 0;               // 0.7.8: mono bass below this frequency (0 = off)
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
        s.expert = expert;
        s.expertSeen = expertSeen;
        s.xb = copyBands(xb);
        s.xSel = xSel;
        s.xPreset = xPreset;
        s.cpEq = cpEq;
        s.cpwAck = cpwAck;
        s.crashAck = crashAck;
        s.width = width;
        s.monoHz = monoHz;
        return s;
    }

    /** An Expert band's channel (CH_*): its fifth value, left and right when it has none. */
    static int ch(int[] b) {
        return b.length > 4 ? clamp(b[4], CH_LR, CH_SIDE) : CH_LR;
    }

    /** 0.7.8: the stereo width, mono bass or a band on the mid or the side only is set. */
    boolean usesMs() {
        if (width != 100 || monoHz != 0) return true;
        if (expert) for (int[] b : xb) if (ch(b) != CH_LR) return true;
        return false;
    }

    static ArrayList<int[]> copyBands(ArrayList<int[]> from) {
        ArrayList<int[]> out = new ArrayList<int[]>();
        for (int[] b : from) out.add(b.clone());
        return out;
    }

    /** The EQ itself (not the switches, the position or logging): what Undo steps back through. */
    String eqKey() {
        StringBuilder sb = new StringBuilder().append(expert ? 'x' : 'e').append(preamp).append('|').append(ends());
        for (int v : bands) sb.append(',').append(v);
        sb.append('|').append(xbText(xb));
        return sb.toString();
    }

    /** Takes the EQ itself from o (Undo). */
    void takeEq(EqSettings o) {
        preamp = o.preamp;
        bands = o.bands.clone();
        lowShelf = o.lowShelf;
        highShelf = o.highShelf;
        expert = o.expert;
        xb = copyBands(o.xb);
        xSel = o.xSel;
        preset = o.preset;
        xPreset = o.xPreset;
    }

    /** The playing mode's name: Flat, User 1-4 or Custom. */
    String name() {
        return expert ? xPreset : preset;
    }

    void setName(String n) {
        if (expert) xPreset = n;
        else preset = n;
    }

    /** The filter's end-band types: 1 = 31 Hz shelf, 2 = 16 kHz shelf. */
    int ends() {
        return (lowShelf ? 1 : 0) | (highShelf ? 2 : 0);
    }

    /** The selected Expert band, or null when there is none. */
    int[] sel() {
        if (xb.isEmpty()) return null;
        xSel = clamp(xSel, 0, xb.size() - 1);
        return xb.get(xSel);
    }

    /** A band's values put in range for its type (as the filter checks them). */
    static int[] clampBand(int[] b) {
        int[] o = new int[5];
        System.arraycopy(b, 0, o, 0, Math.min(5, b.length));
        o[4] = ch(o);
        o[0] = clamp(o[0], X_PEAK, X_LOW_CUT);
        o[1] = clamp(o[1], X_FMIN, X_FMAX);
        o[2] = o[0] == X_LOW_CUT ? 0 : clamp(o[2], -X_GAIN, X_GAIN);
        if (o[0] == X_PEAK) o[3] = clamp(o[3], X_BWMIN, X_BWMAX);
        else if (o[0] == X_LOW_CUT) o[3] = clamp(o[3], X_QMIN, X_QMAX);
        else o[3] = 0;
        return o;
    }

    /** Puts the Expert bands in frequency order, keeping the selected one selected. */
    /** Band i's place by frequency (ties by their order), 0-based: its number on screen (0.7.4). */
    int rankOf(int i) {
        if (i < 0 || i >= xb.size()) return 0;
        int r = 0, fi = xb.get(i)[1];
        for (int j = 0; j < xb.size(); j++) {
            int fj = xb.get(j)[1];
            if (fj < fi || (fj == fi && j < i)) r++;
        }
        return r;
    }

    void sortBands() {
        final int[] s0 = sel();
        Collections.sort(xb, new Comparator<int[]>() {
            public int compare(int[] a, int[] b) {
                return a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0;
            }
        });
        if (s0 != null) xSel = Math.max(0, xb.indexOf(s0));
    }

    /**
     * The Easy EQ as Expert bands with the same sound: the filter's solved gains (gains, 0.01 dB;
     * the sliders themselves when the filter cannot tell) on the same filters, one-octave bells at
     * the ten centres and the end bands' shelves. Gains past +-15 dB are set to +-15 (counted in
     * clamped[0]).
     */
    static ArrayList<int[]> fromEasy(EqSettings e, int[] gains, int[] clamped) {
        ArrayList<int[]> out = new ArrayList<int[]>();
        int n = 0;
        for (int j = 0; j < NB; j++) {
            boolean lo = j == 0 && e.lowShelf, hi = j == NB - 1 && e.highShelf;
            int g = gains != null && gains.length == NB ? gains[j] : e.bands[j];
            if (g > X_GAIN || g < -X_GAIN) n++;
            out.add(clampBand(new int[] {lo ? X_LOW_SHELF : hi ? X_HIGH_SHELF : X_PEAK,
                    lo ? LOW_SHELF_CHZ : hi ? HIGH_SHELF_CHZ : (int) Math.round(CENTRES[j] * 100), g, lo || hi ? 0 : X_BW_DEFAULT}));
        }
        if (clamped != null) clamped[0] = n;
        return out;
    }

    /** "630 Hz", "1.10 kHz", "31.3 Hz", "11.3 kHz". */
    static String hz(int centiHz) {
        double f = centiHz / 100.0;
        if (f >= 10000) return String.format(Locale.US, "%.1f kHz", f / 1000);
        if (f >= 1000) return String.format(Locale.US, "%.2f kHz", f / 1000);
        if (f >= 100) return String.format(Locale.US, "%.0f Hz", f);
        return String.format(Locale.US, "%.1f Hz", f);
    }

    /** A frequency rounded to three significant figures, in 0.01 Hz (the -/+ steps). */
    static int round3(double hz) {
        double step = hz >= 10000 ? 100 : hz >= 1000 ? 10 : hz >= 100 ? 1 : 0.1;
        return (int) Math.round(Math.round(hz / step) * step * 100);
    }

    static String xbText(ArrayList<int[]> list) {
        StringBuilder sb = new StringBuilder();
        for (int[] b : list) {
            if (sb.length() > 0) sb.append(';');
            sb.append(b[0]).append(':').append(b[1]).append(':').append(b[2]).append(':').append(b[3]);
            // 0.7.8: the channel only when it is not left and right, so older versions keep reading
            // every band they can play (they leave out a band with five values)
            if (ch(b) != CH_LR) sb.append(':').append(ch(b));
        }
        return sb.toString();
    }

    static ArrayList<int[]> parseBands(String v) {
        ArrayList<int[]> out = new ArrayList<int[]>();
        if (v == null) return out;
        for (String t : v.trim().split(";")) {
            String[] f = t.trim().split(":");
            if (f.length != 4 && f.length != 5) continue;
            try {
                int[] b = new int[5];
                for (int i = 0; i < f.length; i++) b[i] = Integer.parseInt(f[i].trim());
                if (out.size() < NX) out.add(clampBand(b));
            } catch (NumberFormatException ignored) {
                // a damaged band is left out
            }
        }
        return out;
    }

    /**
     * The engine's settings parameter, little-endian: layout 4 (int32[101]: layout 3 with each band's
     * channel in its type's upper bits, then the stereo width and the mono bass) for 0.7.8's filter;
     * layout 3 (int32[99]: layout 2, then the mode,
     * the band count and 20 Expert bands) for 0.6.11's filter; layout 2 (int32[17], with the
     * end-band types) for 0.6.6 .. 0.6.10's; layout 1 (int32[16]) for an older one still in the
     * audio server. The older layouts carry the Easy EQ only.
     */
    byte[] toParam(int layout) {
        int[] v = new int[layout >= 4 ? 21 + 4 * NX : layout == 3 ? 19 + 4 * NX : layout == 2 ? 17 : 16];
        v[0] = layout >= 4 ? 4 : layout == 3 ? 3 : layout == 2 ? 2 : 1;
        v[1] = eqOn ? 1 : 0;
        v[2] = clamp(preamp, PRE_MIN, PRE_MAX);
        v[3] = guard ? 1 : 0;
        for (int i = 0; i < NB; i++) v[4 + i] = clamp(bands[i], BAND_MIN, BAND_MAX);
        v[14] = delayUs(true);
        v[15] = delayUs(false);
        if (layout >= 2) v[16] = ends();
        if (layout >= 3) {
            v[17] = expert ? 1 : 0;
            int n = Math.min(NX, xb.size());
            v[18] = n;
            for (int j = 0; j < n; j++) {
                int[] b = clampBand(xb.get(j));
                System.arraycopy(b, 0, v, 19 + 4 * j, 4);
                // layout 4: the channel in the type's upper bits (an older filter plays every band on both)
                if (layout >= 4) v[19 + 4 * j] |= b[4] << 4;
            }
        }
        if (layout >= 4) {
            v[19 + 4 * NX] = clamp(width, WIDTH_MIN, WIDTH_MAX);
            v[20 + 4 * NX] = monoHz <= 0 ? 0 : clamp(monoHz, 40, 250);
        }
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
        // (0.7.8: title case, as the Position page's card title)
        if (position <= -100) return "Driver's Seat";
        if (position >= 100) return "Passenger's Seat";
        return Math.abs(position) + "% Toward the " + (position < 0 ? "Driver" : "Passenger");
    }

    String describe() {
        StringBuilder sb = new StringBuilder();
        sb.append("eq ").append(eqOn ? "on" : "off").append(", preamp ").append(db(preamp)).append(", clip guard ")
                .append(guard ? "on" : "off").append(", position ").append(position).append(" (L ").append(delayUs(true))
                .append(" us, R ").append(delayUs(false)).append(" us)");
        if (width != 100 || monoHz != 0)
            sb.append(", width ").append(width).append("%, mono bass ").append(monoHz > 0 ? "below " + monoHz + " Hz" : "off");
        if (expert) {
            sb.append(", Expert, ").append(xb.size()).append(" bands:");
            for (int[] b : xb) {
                sb.append(' ').append(X_TYPES[clamp(b[0], 1, 4)].toLowerCase(Locale.US).replace(" ", ""));
                if (ch(b) != CH_LR) sb.append('(').append(CH_NAMES[ch(b)].toLowerCase(Locale.US)).append(')');
                sb.append(' ').append(hz(b[1]));
                if (b[0] != X_LOW_CUT) sb.append(' ').append(db(b[2]));
                if (b[0] == X_PEAK) sb.append(' ').append(String.format(Locale.US, "%.2foct", b[3] / 1000.0));
                if (b[0] == X_LOW_CUT) sb.append(String.format(Locale.US, " Q%.2f", b[3] / 1000.0));
                sb.append(';');
            }
            return sb.toString();
        }
        sb.append(", bands");
        for (int i = 0; i < NB; i++) sb.append(' ').append(LABELS[i]).append('=').append(db(bands[i]));
        sb.append(", 31 Hz ").append(lowShelf ? "shelf" : "peak").append(", 16 kHz ").append(highShelf ? "shelf" : "peak");
        return sb.toString();
    }

    static String db(int cdb) {
        String s = String.valueOf(Math.abs(cdb) / 100) + (Math.abs(cdb) % 100 == 0 ? "" : "." + (Math.abs(cdb) % 100) / 10);
        return (cdb > 0 ? "+" : cdb < 0 ? "-" : "") + s;
    }

    /** Gain with one decimal always ("-7.0"), for the Expert band card. */
    static String db1(int cdb) {
        return (cdb > 0 ? "+" : cdb < 0 ? "-" : "") + String.format(Locale.US, "%.1f", Math.abs(cdb) / 100.0);
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
                    else if (k.equals("mode")) s.expert = "expert".equals(v);
                    else if (k.equals("expert_seen")) s.expertSeen = "1".equals(v);
                    else if (k.equals("xbands")) s.xb = parseBands(v);
                    else if (k.equals("xsel")) s.xSel = Integer.parseInt(v);
                    else if (k.equals("xpreset")) s.xPreset = v.length() > 0 && v.length() < 40 ? v : "Custom";
                    else if (k.equals("cp_eq")) s.cpEq = !"0".equals(v);
                    else if (k.equals("cpw_ack")) s.cpwAck = v.length() < 120 ? v : "";
                    else if (k.equals("crash_ack")) s.crashAck = v.length() < 120 ? v : "";
                    else if (k.equals("width")) s.width = clamp(Integer.parseInt(v), WIDTH_MIN, WIDTH_MAX);
                    else if (k.equals("mono_bass")) {
                        int m = Integer.parseInt(v);
                        s.monoHz = m <= 0 ? 0 : clamp(m, 40, 250);
                    }
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
        // the built-in genre presets are gone (0.6.11): a curve loaded from one stays, as Custom
        if (!s.preset.equals("Flat") && !s.preset.equals("Custom") && !s.preset.matches("User [1-" + USER_SLOTS + "]")) {
            boolean flat = s.preamp == 0;
            for (int v : s.bands) if (v != 0) flat = false;
            s.preset = flat ? "Flat" : "Custom";
        }
        if (s.expert) s.expertSeen = true;
        s.sortBands();
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
        sb.append("mode=").append(expert ? "expert" : "easy").append('\n');
        sb.append("expert_seen=").append(expertSeen ? 1 : 0).append('\n');
        sb.append("xbands=").append(xbText(xb)).append('\n');
        sb.append("xsel=").append(xSel).append('\n');
        sb.append("xpreset=").append(xPreset).append('\n');
        sb.append("cp_eq=").append(cpEq ? 1 : 0).append('\n');
        sb.append("cpw_ack=").append(cpwAck).append('\n');
        sb.append("crash_ack=").append(crashAck).append('\n');
        sb.append("width=").append(width).append('\n');
        sb.append("mono_bass=").append(monoHz).append('\n');
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

    /** A user slot (both modes share the four): an Easy EQ or an Expert one, with its preamp. */
    static final class Slot {
        boolean expert;
        int preamp;
        int[] bands = new int[NB];
        ArrayList<int[]> xb = new ArrayList<int[]>();
    }

    /**
     * User slot, or null if it is empty or damaged. One line: "preamp,10 bands" for an Easy EQ
     * (as before 0.6.11), "x;preamp;type:Hz:gain:width;..." for an Expert one.
     */
    static Slot loadUser(Context ctx, int slot) {
        return parseSlot(Root.readFirstLine(new File(dir(ctx), "preset" + slot + ".txt")));
    }

    static Slot parseSlot(String line) {
        if (line == null) return null;
        line = line.trim();
        Slot sl = new Slot();
        try {
            if (line.startsWith("x;")) {
                int at = line.indexOf(';', 2);
                sl.expert = true;
                sl.preamp = clamp(Integer.parseInt((at < 0 ? line.substring(2) : line.substring(2, at)).trim()), PRE_MIN, PRE_MAX);
                sl.xb = parseBands(at < 0 ? "" : line.substring(at + 1));
                return sl;
            }
            String[] f = line.split(",");
            if (f.length != NB + 1) return null;
            sl.preamp = clamp(Integer.parseInt(f[0].trim()), PRE_MIN, PRE_MAX);
            for (int i = 0; i < NB; i++) sl.bands[i] = clamp(Integer.parseInt(f[i + 1].trim()), BAND_MIN, BAND_MAX);
            return sl;
        } catch (NumberFormatException e) {
            return null;
        }
    }

    static void saveUser(Context ctx, int slot, EqSettings s, Saved done) {
        StringBuilder sb = new StringBuilder();
        if (s.expert) {
            sb.append("x;").append(s.preamp).append(';').append(xbText(s.xb));
        } else {
            sb.append(s.preamp);
            for (int i = 0; i < NB; i++) sb.append(',').append(s.bands[i]);
        }
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
