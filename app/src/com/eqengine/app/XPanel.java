package com.eqengine.app;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.DashPathEffect;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.view.MotionEvent;
import android.view.View;

import java.util.ArrayList;

/**
 * Expert mode's left card (0.6.11): the preamp slider (the same column as the Easy page's, with
 * Auto under it) and the curve editor. Each Expert band is a numbered dot on a 20 Hz .. 20 kHz
 * graph: drag it sideways for its frequency and up or down for its gain (a low cut has no gain:
 * only sideways). The orange line is the whole EQ (the bands added up), each band's own curve is
 * drawn faintly, the selected band's filled, with dashed lines at its bandwidth's edges. The band
 * card beside this view (MainActivity) holds the selected band's values.
 * 0.7.4: the scale is +-15 dB, or +-27, +-39 or +-51 when the orange line needs it (bands that
 * overlap add up), and changes only while no finger is on the graph; the dots are numbered by
 * frequency, 1 to N from the left, also while one is dragged past another; Auto is amber while
 * the preamp leaves more than 3 dB of the boost to the clip guard.
 * The curves are drawn here from the same formulas as the filter (XDesign); the sound is the
 * filter's own.
 * 0.7.8: the orange line is the mid's (left and right bands plus the mid-only ones: what a centred
 * voice gets); while the stereo width, mono bass or a band on one channel is set, a dashed green
 * line shows the side's (left and right bands, the side-only ones, the width and the mono bass).
 */
final class XPanel extends View implements LiveLayer.Geometry {
    interface Listener {
        void onPreamp(int cdb, boolean done);

        void onAuto();

        /** A dot was touched: it becomes the selected band. */
        void onXSelect(int i);

        /** The selected dot moved (done = finger lifted). */
        void onXMove(int i, int centiHz, int cdb, boolean done);
    }

    private static final int NPTS = 300;
    /** the scales the graph can have, dB either side of 0, smallest first (0.7.4) */
    private static final float[] RANGES = {15f, 27f, 39f, 51f};
    /** Auto turns amber when the boost left over (largest boost plus the preamp) is more than this */
    static final float AUTO_WARN_DB = 3f;
    private static final double LO = Math.log10(20), HI = Math.log10(20000);
    private static final int[] GRID_HZ = {20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000};

    private final Paint pTrack = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pFill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pThumb = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pShadow = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pGrid = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pText = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pSub = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pValue = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pChip = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pChipText = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pSum = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pBand = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pSel = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pSelFill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pDash = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pDot = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pDotText = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pSide = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pLegend = new Paint(Paint.ANTI_ALIAS_FLAG);
    private static final int SIDE_COLOR = Color.rgb(108, 214, 140);
    private final RectF r = new RectF();
    private final Path path = new Path();

    private Listener listener;
    private int preamp;
    private boolean eqOn = true;
    private ArrayList<int[]> bands = new ArrayList<int[]>();
    private int sel;
    private double rate = 48000;
    // the curves, per band and summed, at NPTS log-spaced points
    private float[][] bandDb = new float[0][];
    private final float[] sumDb = new float[NPTS];
    // 0.7.8: the side's curve, each band's channel as summed, and the side's own width and mono bass
    private final float[] sideDb = new float[NPTS];
    private int[] bandCh = new int[0];
    private int width = 100, monoHz;
    private boolean ms;
    private final double[] ptHz = new double[NPTS];
    /** the scale now (dB either side of 0), and the summed curve's largest boost (20 Hz .. 20 kHz) */
    private float range = RANGES[0];
    private float sumMax;

    // geometry (the preamp column is the Easy page's, so the two modes line up)
    private final float extraPx;
    private float d, pad, pgap, colW, preW, textSize, valueY, trackTop, trackBottom, labelY, sub2Y, thumbH, trackW, preCx;
    private float gx0, gx1, gy0, gy1;
    // touch
    private int mode;              // 0 none, 1 preamp, 2 auto chip, 3 dot
    private float downY, offX, offY;
    private int downValue, dragBand = -1;
    private long lastPreDown;

    /** extraPx: how much wider the Easy page's face is than this card (the band card and the gap). */
    XPanel(Context c, float extraPx) {
        super(c);
        this.extraPx = extraPx;
        d = Ui.density(c);
        pTrack.setColor(Ui.SURFACE_TOP);
        pFill.setColor(Ui.PRIMARY);
        pThumb.setColor(Ui.ON_SURFACE);
        pShadow.setColor(Color.argb(110, 0, 0, 0));
        pGrid.setColor(Ui.OUTLINE);
        pGrid.setStrokeWidth(1.5f);
        pText.setColor(Ui.ON_SURFACE);
        pText.setTextAlign(Paint.Align.CENTER);
        pSub.setColor(Ui.ON_SURFACE_VAR);
        pSub.setTextAlign(Paint.Align.CENTER);
        pValue.setColor(Ui.ON_SURFACE);
        pValue.setTextAlign(Paint.Align.CENTER);
        pValue.setTypeface(Typeface.DEFAULT_BOLD);
        pChipText.setTextAlign(Paint.Align.CENTER);
        pChipText.setTypeface(Typeface.DEFAULT_BOLD);
        pSum.setColor(Ui.CURVE);
        pSum.setStyle(Paint.Style.STROKE);
        pSum.setStrokeJoin(Paint.Join.ROUND);
        pSum.setStrokeWidth(Math.max(3f, 2.5f * d));
        pBand.setColor(Color.rgb(70, 82, 98));
        pBand.setStyle(Paint.Style.STROKE);
        pBand.setStrokeWidth(Math.max(1.5f, 1.2f * d));
        pSel.setColor(Ui.PRIMARY);
        pSel.setStyle(Paint.Style.STROKE);
        pSel.setStrokeWidth(Math.max(2f, 1.5f * d));
        pSelFill.setColor(Ui.PRIMARY);
        pSelFill.setAlpha(60);
        pSelFill.setStyle(Paint.Style.FILL);
        pDash.setColor(Ui.PRIMARY);
        pDash.setStyle(Paint.Style.STROKE);
        pDash.setStrokeWidth(Math.max(1.5f, 1.2f * d));
        pDash.setPathEffect(new DashPathEffect(new float[] {5 * d, 5 * d}, 0));
        pDotText.setTextAlign(Paint.Align.CENTER);
        pDotText.setTypeface(Typeface.DEFAULT_BOLD);
        pDotText.setTextSize(13 * d);
        pSide.setColor(SIDE_COLOR);
        pSide.setStyle(Paint.Style.STROKE);
        pSide.setStrokeJoin(Paint.Join.ROUND);
        pSide.setStrokeWidth(Math.max(2.5f, 2f * d));
        pSide.setPathEffect(new DashPathEffect(new float[] {8 * d, 5 * d}, 0));
        pLegend.setTextAlign(Paint.Align.RIGHT);
        pLegend.setTypeface(Typeface.DEFAULT_BOLD);
        pLegend.setTextSize(13 * d);
        for (int i = 0; i < NPTS; i++) ptHz[i] = Math.pow(10, LO + (HI - LO) * i / (NPTS - 1));
    }

    void setListener(Listener l) {
        listener = l;
    }

    void setValues(EqSettings s) {
        preamp = s.preamp;
        eqOn = s.eqOn;
        ArrayList<int[]> nb = EqSettings.copyBands(s.xb);
        // 0.7.6: a change to one band (its width slider, a -/+ button) works out only that band's
        // curve again, as a drag does; anything more (bands added, removed, sorted) all of them
        int changed = -1, nchanged = 0;
        if (nb.size() == bands.size() && bandDb.length == nb.size()) {
            for (int j = 0; j < nb.size(); j++) {
                if (!java.util.Arrays.equals(nb.get(j), bands.get(j))) {
                    changed = j;
                    nchanged++;
                }
            }
        } else {
            nchanged = -1;
        }
        bands = nb;
        sel = s.xb.isEmpty() ? -1 : EqSettings.clamp(s.xSel, 0, s.xb.size() - 1);
        if (s.width != width || s.monoHz != monoHz) {
            width = s.width;
            monoHz = s.monoHz;
            nchanged = -1;
        }
        if (nchanged == 1) {
            recomputeBand(changed);
            fitRange();
        } else if (nchanged != 0) {
            recompute();
        }
        invalidate();
    }

    /** The output's sample rate, for drawing the curves as the filter makes them. */
    void setRate(double r) {
        if (r < 8000 || r == rate) return;
        rate = r;
        recompute();
        invalidate();
    }

    private void recompute() {
        if (bandDb.length != bands.size()) bandDb = new float[bands.size()][NPTS];
        if (bandCh.length != bands.size()) bandCh = new int[bands.size()];
        // the side's own part: the width (a level) and the mono bass (a low cut at its frequency)
        double[] mono = monoHz > 0 ? XDesign.coefs(new int[] {EqSettings.X_LOW_CUT, monoHz * 100, 0, 707}, rate) : null;
        float wdb = width > 0 ? (float) (20 * Math.log10(width / 100.0)) : -200f;
        ms = width != 100 || monoHz > 0;
        for (int i = 0; i < NPTS; i++) {
            sumDb[i] = 0f;
            sideDb[i] = wdb + (float) XDesign.db(mono, ptHz[i], rate);
        }
        for (int j = 0; j < bands.size(); j++) {
            double[] k = XDesign.coefs(bands.get(j), rate);
            int ch = EqSettings.ch(bands.get(j));
            bandCh[j] = ch;
            if (ch != EqSettings.CH_LR) ms = true;
            for (int i = 0; i < NPTS; i++) {
                float v = (float) XDesign.db(k, ptHz[i], rate);
                bandDb[j][i] = v;
                if (ch != EqSettings.CH_SIDE) sumDb[i] += v;
                if (ch != EqSettings.CH_MID) sideDb[i] += v;
            }
        }
        sumMaxNow();
        fitRange();
    }

    private void sumMaxNow() {
        float m = bands.isEmpty() && !ms ? 0f : -1e9f;
        for (int i = 0; i < NPTS; i++) {
            m = Math.max(m, sumDb[i]);
            if (ms) m = Math.max(m, sideDb[i]);
        }
        sumMax = m;
    }

    /**
     * The smallest scale that holds the summed curve and every dot with 1 dB to spare. Not while a
     * dot is being dragged (it would jump under the finger): the scale follows once it is let go.
     */
    private void fitRange() {
        if (mode == 3) return;
        float need = 0f;
        for (int i = 0; i < NPTS; i++) {
            need = Math.max(need, Math.abs(sumDb[i]));
            if (ms && sideDb[i] > -60f) need = Math.max(need, Math.abs(sideDb[i]));
        }
        for (int[] b : bands) if (b[0] != EqSettings.X_LOW_CUT) need = Math.max(need, Math.abs(b[2] / 100f));
        float r = RANGES[RANGES.length - 1];
        for (float c : RANGES) {
            if (need <= c - 1f) {
                r = c;
                break;
            }
        }
        range = r;
    }

    /** The preamp leaves more than AUTO_WARN_DB of the boost to the clip guard (EQ on, any band). */
    private boolean autoWarn() {
        return eqOn && !bands.isEmpty() && sumMax + preamp / 100f > AUTO_WARN_DB;
    }

    /** Each band's number on screen: its place by frequency (ties by their order), 0-based. */
    private int[] ranks() {
        int n = bands.size();
        int[] rk = new int[n];
        for (int i = 0; i < n; i++) {
            int r = 0;
            for (int j = 0; j < n; j++) {
                int fi = bands.get(i)[1], fj = bands.get(j)[1];
                if (fj < fi || (fj == fi && j < i)) r++;
            }
            rk[i] = r;
        }
        return rk;
    }

    /** One band changed (a drag): only its curve is worked out again, and the sum follows. */
    private void recomputeBand(int j) {
        // (0.7.8: a band moved to another channel changes which curves it is in: all again)
        if (j < 0 || j >= bandDb.length || j >= bandCh.length || bandCh[j] != EqSettings.ch(bands.get(j))) {
            recompute();
            return;
        }
        double[] k = XDesign.coefs(bands.get(j), rate);
        int ch = bandCh[j];
        for (int i = 0; i < NPTS; i++) {
            float v = (float) XDesign.db(k, ptHz[i], rate);
            if (ch != EqSettings.CH_SIDE) sumDb[i] += v - bandDb[j][i];
            if (ch != EqSettings.CH_MID) sideDb[i] += v - bandDb[j][i];
            bandDb[j][i] = v;
        }
        sumMaxNow();
    }

    @Override
    protected void onSizeChanged(int w, int h, int ow, int oh) {
        float refW = w + extraPx;
        pad = 12 * d;
        pgap = Math.max(16 * d, refW * 0.02f);
        // as the Easy page: twelve even columns of its width set the text and the slider's size
        colW = (refW - 2 * pad - 2 * pgap) / EqPanel.COLS;
        textSize = Math.max(16 * d, Math.min(colW * 0.22f, h * 0.06f));
        pText.setTextSize(textSize);
        pSub.setTextSize(textSize * 0.82f);
        pChipText.setTextSize(textSize * 0.78f);
        pValue.setTextSize(textSize * 1.1f);
        valueY = pad + textSize * 1.1f;
        trackTop = valueY + textSize * 0.9f;
        sub2Y = h - pad * 0.6f;
        labelY = sub2Y - pSub.getTextSize() * 1.3f - textSize;
        trackBottom = labelY - textSize * 0.35f;
        thumbH = Math.max(22 * d, (trackBottom - trackTop) * 0.07f);
        trackW = Math.max(6 * d, colW * 0.09f);
        preW = EqPanel.preampW(pText, pChipText, colW, d);
        preCx = pad + preW / 2f;
        // the dB scale EqPanel.PRE_GAP after the preamp column, then the graph
        gx0 = pad + preW + EqPanel.PRE_GAP * d + EqPanel.scaleW(pSub) + 8 * d;
        gx1 = w - pad - 4 * d;
        gy0 = 18 * d;
        gy1 = h - 34 * d;
    }

    private float x(double hz) {
        return (float) (gx0 + (Math.log10(Math.max(1e-3, hz)) - LO) / (HI - LO) * (gx1 - gx0));
    }

    private float y(float db) {
        return gy0 + (range - db) / (2 * range) * (gy1 - gy0);
    }

    private float yPre(int cdb) {
        float t = (EqSettings.PRE_MAX - cdb) / (float) (EqSettings.PRE_MAX - EqSettings.PRE_MIN);
        return trackTop + thumbH / 2 + t * (trackBottom - trackTop - thumbH);
    }

    /** Where a band's dot sits: its gain (a low cut: its own curve at its frequency). */
    private float dotY(int j) {
        int[] b = bands.get(j);
        if (b[0] == EqSettings.X_LOW_CUT) {
            return y(Math.max(-range, Math.min(range, (float) XDesign.db(XDesign.coefs(b, rate), b[1] / 100.0, rate))));
        }
        return y(Math.max(-range, Math.min(range, b[2] / 100f)));
    }

    @Override
    protected void onDraw(Canvas c) {
        drawPreamp(c);
        // grid and scales
        pSub.setTextAlign(Paint.Align.RIGHT);
        int step = range <= RANGES[0] ? 6 : 12, top = (int) ((range - 3) / step) * step;
        for (int db = -top; db <= top; db += step) {
            float yy = y(db);
            pGrid.setAlpha(db == 0 ? 255 : 120);
            c.drawLine(gx0, yy, gx1, yy, pGrid);
            c.drawText((db > 0 ? "+" : "") + db, gx0 - 8 * d, yy + textSize * 0.3f, pSub);
        }
        pGrid.setAlpha(120);
        pSub.setTextAlign(Paint.Align.CENTER);
        for (int f : GRID_HZ) {
            float xx = x(f);
            c.drawLine(xx, gy0, xx, gy1, pGrid);
            String s = f >= 1000 ? (f / 1000) + "k" : String.valueOf(f);
            float tw = pSub.measureText(s);
            float tx = Math.min(Math.max(xx, gx0), gx1 - tw / 2);
            c.drawText(s, tx, gy1 + 8 * d + pSub.getTextSize(), pSub);
        }
        pGrid.setAlpha(255);
        c.save();
        c.clipRect(gx0, gy0, gx1, gy1);
        // the selected band: filled to 0 dB
        if (sel >= 0 && sel < bandDb.length) {
            path.reset();
            path.moveTo(x(ptHz[0]), y(0));
            for (int i = 0; i < NPTS; i++) path.lineTo(x(ptHz[i]), y(clampDb(bandDb[sel][i])));
            path.lineTo(x(ptHz[NPTS - 1]), y(0));
            path.close();
            c.drawPath(path, pSelFill);
        }
        // each band's own curve, faintly
        for (int j = 0; j < bandDb.length; j++) {
            if (j == sel) continue;
            drawLine(c, bandDb[j], pBand);
        }
        if (sel >= 0 && sel < bandDb.length) drawLine(c, bandDb[sel], pSel);
        // the whole EQ (0.7.8: the mid's, and the side's when it differs)
        pSum.setAlpha(eqOn ? 230 : 80);
        if (bandDb.length > 0) drawLine(c, sumDb, pSum);
        else c.drawLine(gx0, y(0), gx1, y(0), pSum);
        if (ms) {
            pSide.setAlpha(eqOn ? 230 : 80);
            drawLine(c, sideDb, pSide);
        }
        c.restore();
        if (ms) {
            float ly = gy0 + pLegend.getTextSize() + 4 * d;
            pLegend.setColor(SIDE_COLOR);
            c.drawText("Side", gx1 - 6 * d, ly, pLegend);
            float sw = pLegend.measureText("Side") + 12 * d;
            pLegend.setColor(Ui.CURVE);
            c.drawText("Mid", gx1 - 6 * d - sw, ly, pLegend);
        }
        // the selected peak's bandwidth
        if (sel >= 0 && sel < bands.size() && bands.get(sel)[0] == EqSettings.X_PEAK) {
            int[] b = bands.get(sel);
            double half = b[3] / 2000.0, f0 = b[1] / 100.0;
            for (double fe : new double[] {f0 / Math.pow(2, half), f0 * Math.pow(2, half)}) {
                float xx = x(fe);
                if (xx < gx0 || xx > gx1) continue;
                c.drawLine(xx, y(range - 1), xx, y(-(range - 1)), pDash);
            }
        }
        // the dots, numbered by frequency
        int[] rk = ranks();
        for (int j = 0; j < bands.size(); j++) {
            float xx = x(bands.get(j)[1] / 100.0), yy = dotY(j);
            boolean s = j == sel;
            float rad = (s ? 13 : 11) * d;
            if (s) {
                pDot.setStyle(Paint.Style.STROKE);
                pDot.setStrokeWidth(Math.max(2f, 1.6f * d));
                pDot.setColor(Ui.PRIMARY);
                c.drawCircle(xx, yy, rad + 5 * d, pDot);
                pDot.setStyle(Paint.Style.FILL);
                c.drawCircle(xx, yy, rad, pDot);
                pDotText.setColor(Ui.ON_PRIMARY);
            } else {
                pDot.setStyle(Paint.Style.FILL);
                pDot.setColor(Ui.SURFACE_TOP);
                c.drawCircle(xx, yy, rad, pDot);
                pDot.setStyle(Paint.Style.STROKE);
                pDot.setStrokeWidth(Math.max(2f, 1.6f * d));
                pDot.setColor(Ui.ON_SURFACE);
                c.drawCircle(xx, yy, rad, pDot);
                pDotText.setColor(Ui.ON_SURFACE);
            }
            c.drawText(String.valueOf(rk[j] + 1), xx, yy + pDotText.getTextSize() * 0.36f, pDotText);
        }
    }

    private float clampDb(float v) {
        return Math.max(-range - 1, Math.min(range + 1, v));
    }

    private void drawLine(Canvas c, float[] db, Paint p) {
        path.reset();
        for (int i = 0; i < NPTS; i++) {
            float xx = x(ptHz[i]), yy = y(clampDb(db[i]));
            if (i == 0) path.moveTo(xx, yy);
            else path.lineTo(xx, yy);
        }
        c.drawPath(path, p);
    }

    private void drawPreamp(Canvas c) {
        float cx = preCx;
        r.set(cx - trackW / 2, trackTop, cx + trackW / 2, trackBottom);
        c.drawRoundRect(r, trackW / 2, trackW / 2, pTrack);
        float y0 = yPre(0), yv = yPre(preamp);
        pFill.setAlpha(preamp >= 0 ? 255 : 170);
        r.set(cx - trackW / 2, Math.min(y0, yv), cx + trackW / 2, Math.max(y0, yv));
        c.drawRoundRect(r, trackW / 2, trackW / 2, pFill);
        pFill.setAlpha(255);
        c.drawLine(cx - colW * 0.3f, y0, cx + colW * 0.3f, y0, pGrid);
        float tw = colW * 0.56f, lift = 2 * d;
        boolean active = mode == 1;
        r.set(cx - tw / 2, yv - thumbH / 2 + lift, cx + tw / 2, yv + thumbH / 2 + lift);
        c.drawRoundRect(r, thumbH / 2, thumbH / 2, pShadow);
        pThumb.setColor(active ? Ui.PRIMARY : Ui.ON_SURFACE);
        r.set(cx - tw / 2, yv - thumbH / 2, cx + tw / 2, yv + thumbH / 2);
        c.drawRoundRect(r, thumbH / 2, thumbH / 2, pThumb);
        c.drawLine(cx - tw * 0.22f, yv, cx + tw * 0.22f, yv, pGrid);
        pValue.setColor(active ? Ui.PRIMARY : Ui.ON_SURFACE);
        c.drawText(EqSettings.db(preamp), cx, valueY, pValue);
        c.drawText("Preamp", cx, labelY + textSize, pText);
        EqPanel.drawAuto(c, cx, mode == 2, autoWarn(), colW, sub2Y, pSub.getTextSize(), pChip, pChipText, r, d);
    }

    // ------------------------------------------------------------------ touch

    private boolean inPreamp(float px) {
        return px < pad + preW + EqPanel.PRE_GAP * d * 0.5f;
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        float ex = e.getX(), ey = e.getY();
        switch (e.getActionMasked()) {
        case MotionEvent.ACTION_DOWN:
            if (inPreamp(ex)) {
                if (ey > trackBottom + textSize * 0.2f) {
                    mode = 2;
                    invalidate();
                    return true;
                }
                long now = e.getEventTime();
                if (now - lastPreDown < 350) {
                    lastPreDown = 0;
                    preamp = 0;
                    mode = 0;
                    invalidate();
                    if (listener != null) listener.onPreamp(0, true);
                    return true;
                }
                lastPreDown = now;
                mode = 1;
                downY = ey;
                downValue = preamp;
                getParent().requestDisallowInterceptTouchEvent(true);
                invalidate();
                return true;
            }
            // the nearest dot within reach of a finger
            int best = -1;
            float bestD = 30 * d;
            for (int j = 0; j < bands.size(); j++) {
                float dx = x(bands.get(j)[1] / 100.0) - ex, dy = dotY(j) - ey;
                float dd = (float) Math.sqrt(dx * dx + dy * dy);
                if (dd <= bestD) {
                    bestD = dd;
                    best = j;
                }
            }
            if (best < 0) return true;
            mode = 3;
            dragBand = best;
            offX = x(bands.get(best)[1] / 100.0) - ex;
            offY = dotY(best) - ey;
            getParent().requestDisallowInterceptTouchEvent(true);
            if (best != sel) {
                sel = best;
                invalidate();
                if (listener != null) listener.onXSelect(best);
            }
            return true;
        case MotionEvent.ACTION_MOVE:
            if (mode == 1) movePreamp(ey, false);
            else if (mode == 3) moveDot(ex, ey, false);
            return true;
        case MotionEvent.ACTION_UP:
        case MotionEvent.ACTION_CANCEL: {
            boolean up = e.getActionMasked() == MotionEvent.ACTION_UP;
            if (mode == 1) movePreamp(ey, true);
            else if (mode == 3) moveDot(ex, ey, true);
            else if (mode == 2 && up && inPreamp(ex) && ey > trackBottom + textSize * 0.2f && listener != null) listener.onAuto();
            mode = 0;
            dragBand = -1;
            fitRange();
            invalidate();
            return true;
        }
        default:
            return true;
        }
    }

    private void movePreamp(float py, boolean done) {
        float span = trackBottom - trackTop - thumbH;
        int v = EqSettings.clamp(EqSettings.snap(Math.round(downValue + (downY - py) / span * (EqSettings.PRE_MAX - EqSettings.PRE_MIN))),
                EqSettings.PRE_MIN, EqSettings.PRE_MAX);
        boolean changed = v != preamp;
        preamp = v;
        if (changed) invalidate();
        if (listener != null && (changed || done)) listener.onPreamp(v, done);
    }

    private void moveDot(float px, float py, boolean done) {
        if (dragBand < 0 || dragBand >= bands.size()) return;
        int[] b = bands.get(dragBand);
        float xx = Math.max(gx0, Math.min(gx1, px + offX));
        double hz = Math.pow(10, LO + (xx - gx0) / (gx1 - gx0) * (HI - LO));
        int chz = EqSettings.clamp(EqSettings.round3(hz), EqSettings.X_FMIN, EqSettings.X_FMAX);
        int cdb = b[2];
        if (b[0] != EqSettings.X_LOW_CUT) {
            float yy = Math.max(gy0, Math.min(gy1, py + offY));
            float db = range - (yy - gy0) / (gy1 - gy0) * 2 * range;
            cdb = EqSettings.clamp(Math.round(db * 10) * 10, -EqSettings.X_GAIN, EqSettings.X_GAIN);
        }
        boolean changed = chz != b[1] || cdb != b[2];
        if (changed) {
            b[1] = chz;
            b[2] = cdb;
            recomputeBand(dragBand);
            invalidate();
        }
        if (listener != null && (changed || done)) listener.onXMove(dragBand, chz, cdb, done);
    }

    // ------------------------------------------------------------------ LiveLayer.Geometry

    public float specLeft() {
        return gx0;
    }

    public float specRight() {
        return gx1;
    }

    public float specTop() {
        return gy0;
    }

    public float specBottom() {
        return gy1;
    }

    public float xForHz(double hz) {
        return x(hz);
    }

    public boolean hasMeter() {
        return false;
    }

    public float meterCx() {
        return 0;
    }

    public float colWidth() {
        return colW;
    }

    public float trackTop() {
        return trackTop;
    }

    public float trackBottom() {
        return trackBottom;
    }

    public float textSize() {
        return textSize;
    }

    public float valueY() {
        return valueY;
    }

    public float labelY() {
        return labelY;
    }

    public float sub2Y() {
        return sub2Y;
    }
}
