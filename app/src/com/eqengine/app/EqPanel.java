package com.eqengine.app;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.view.MotionEvent;
import android.view.View;

/**
 * The EQ face: a preamp slider, ten vertical band sliders (31 Hz .. 16 kHz) with the EQ's real
 * response curve drawn behind them, and an output meter. Drag up or down anywhere in a slider's
 * column to move it from where it is (0.5 dB steps; a tap alone changes nothing); double-tap a
 * column to put it back to 0.
 * Columns: 0 = preamp, 1..10 = bands, 11 = output meter.
 */
final class EqPanel extends View {
    interface Listener {
        /** col 0 = preamp, 1..10 = bands; done = finger lifted */
        void onSlider(int col, int cdb, boolean done);
    }

    private static final int COLS = 12;
    private static final float METER_MIN_DB = -36f;

    private final Paint pBg = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pTrack = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pFill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pThumb = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pShadow = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pGrid = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pCurve = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pText = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pSub = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pValue = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pMeter = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF r = new RectF();
    private final Path path = new Path();

    private Listener listener;
    private int preamp;
    private final int[] bands = new int[EqSettings.NB];
    private int[] resp;
    private boolean eqOn = true;
    private float outDb = -100f, holdDb = -100f, grDb = 0f, avgDb = -100f;
    private long holdAt;
    private boolean meterLive;

    // geometry
    private float pad, gap, colW, trackTop, trackBottom, valueY, labelY, sub2Y, thumbH, trackW;
    private float textSize;
    // touch
    private int activeCol = -1;
    private long lastDownAt;
    private int lastDownCol = -1;
    private float downY;
    private int downValue;

    EqPanel(Context c) {
        super(c);
        pBg.setColor(Ui.SURFACE);
        pTrack.setColor(Ui.SURFACE_TOP);
        pFill.setColor(Ui.PRIMARY);
        pThumb.setColor(Ui.ON_SURFACE);
        pShadow.setColor(Color.argb(110, 0, 0, 0));
        pGrid.setColor(Ui.OUTLINE);
        pGrid.setStrokeWidth(1.5f);
        pCurve.setColor(Ui.CURVE);
        pCurve.setStyle(Paint.Style.STROKE);
        pCurve.setStrokeJoin(Paint.Join.ROUND);
        pCurve.setStrokeCap(Paint.Cap.ROUND);
        pText.setColor(Ui.ON_SURFACE);
        pText.setTextAlign(Paint.Align.CENTER);
        pSub.setColor(Ui.ON_SURFACE_VAR);
        pSub.setTextAlign(Paint.Align.CENTER);
        pValue.setColor(Color.WHITE);
        pValue.setTextAlign(Paint.Align.CENTER);
        pValue.setTypeface(Typeface.DEFAULT_BOLD);
    }

    void setListener(Listener l) {
        listener = l;
    }

    void setValues(EqSettings s) {
        preamp = s.preamp;
        System.arraycopy(s.bands, 0, bands, 0, EqSettings.NB);
        eqOn = s.eqOn;
        invalidate();
    }

    void setResponse(int[] resp) {
        this.resp = resp;
        invalidate();
    }

    /**
     * peak = output peak (0..32768), avgCdb = output average (RMS) level in 0.01 dBFS (-10000 =
     * silent), minGain = clip guard gain x10000; live = audio flowing. The bar shows the average
     * level (it moves with the music), the line the recent peak.
     */
    void setMeter(int peak, int avgCdb, int minGain, boolean live) {
        meterLive = live;
        avgDb = avgCdb > -10000 ? avgCdb / 100f : -100f;
        outDb = peak > 0 ? (float) (20 * Math.log10(peak / 32768.0)) : -100f;
        grDb = minGain > 0 && minGain < 10000 ? (float) (20 * Math.log10(minGain / 10000.0)) : 0f;
        long now = System.currentTimeMillis();
        if (outDb >= holdDb || now - holdAt > 1500) {
            holdDb = outDb;
            holdAt = now;
        }
        invalidate();
    }

    @Override
    protected void onSizeChanged(int w, int h, int ow, int oh) {
        float d = getResources().getDisplayMetrics().density;
        pad = 12 * d;
        gap = Math.max(16 * d, w * 0.02f);
        colW = (w - 2 * pad - 2 * gap) / COLS;
        textSize = Math.max(16 * d, Math.min(colW * 0.22f, h * 0.06f));
        pText.setTextSize(textSize);
        pSub.setTextSize(textSize * 0.82f);
        pValue.setTextSize(textSize * 1.1f);
        valueY = pad + textSize * 1.1f;
        trackTop = valueY + textSize * 0.9f;
        sub2Y = h - pad * 0.6f;
        labelY = sub2Y - pSub.getTextSize() * 1.3f - textSize;
        trackBottom = labelY - textSize * 0.35f;
        thumbH = Math.max(22 * d, (trackBottom - trackTop) * 0.07f);
        trackW = Math.max(6 * d, colW * 0.09f);
        pCurve.setStrokeWidth(Math.max(3f, 2.5f * d));
    }

    private float colLeft(int col) {
        return pad + col * colW + (col >= 1 ? gap : 0) + (col >= 11 ? gap : 0);
    }

    private float colCx(int col) {
        return colLeft(col) + colW / 2f;
    }

    private int colAt(float x) {
        for (int c = 0; c < COLS; c++) {
            float l = colLeft(c);
            if (x >= l && x < l + colW) return c;
        }
        return -1;
    }

    private float yFor(int col, float cdb) {
        float lo = col == 0 ? EqSettings.PRE_MIN : EqSettings.BAND_MIN;
        float hi = col == 0 ? EqSettings.PRE_MAX : EqSettings.BAND_MAX;
        float t = (hi - cdb) / (hi - lo);
        return trackTop + thumbH / 2 + t * (trackBottom - trackTop - thumbH);
    }

    private float bandXForHz(double hz) {
        // band k centre = colCx(1 + k); one octave per column
        double oct = Math.log(hz / EqSettings.CENTRES[0]) / Math.log(2.0);
        return (float) (colCx(1) + oct * colW);
    }

    @Override
    protected void onDraw(Canvas c) {
        int w = getWidth(), h = getHeight();
        r.set(0, 0, w, h);
        float rad = 16 * getResources().getDisplayMetrics().density;
        c.drawRoundRect(r, rad, rad, pBg);

        // band area grid: +12, +6, 0, -6, -12 dB
        float gl = colLeft(1) - gap * 0.4f, gr = colLeft(10) + colW + gap * 0.4f;
        for (int db = -12; db <= 12; db += 6) {
            float y = yFor(1, db * 100);
            pGrid.setAlpha(db == 0 ? 255 : 120);
            c.drawLine(gl, y, gr, y, pGrid);
        }
        pSub.setTextAlign(Paint.Align.RIGHT);
        for (int db = -12; db <= 12; db += 6) {
            float y = yFor(1, db * 100) + textSize * 0.3f;
            c.drawText((db > 0 ? "+" : "") + db, colLeft(1) - gap * 0.15f, y, pSub);
        }
        pSub.setTextAlign(Paint.Align.CENTER);

        // response curve behind the band sliders
        drawCurve(c);

        // preamp + bands
        for (int col = 0; col <= 10; col++) {
            int v = col == 0 ? preamp : bands[col - 1];
            drawSlider(c, col, v);
            String label = col == 0 ? "Preamp" : EqSettings.LABELS[col - 1];
            c.drawText(label, colCx(col), labelY + textSize, pText);
            if (col > 0) c.drawText("Hz", colCx(col), sub2Y, pSub);
            else c.drawText("-18..+6", colCx(col), sub2Y, pSub);
        }

        drawMeter(c);
    }

    private void drawSlider(Canvas c, int col, int v) {
        float cx = colCx(col);
        boolean dim = col > 0 && !eqOn;
        r.set(cx - trackW / 2, trackTop, cx + trackW / 2, trackBottom);
        c.drawRoundRect(r, trackW / 2, trackW / 2, pTrack);
        float y0 = yFor(col, 0), y = yFor(col, v);
        pFill.setAlpha(dim ? 70 : v >= 0 ? 255 : 170);
        r.set(cx - trackW / 2, Math.min(y0, y), cx + trackW / 2, Math.max(y0, y));
        c.drawRoundRect(r, trackW / 2, trackW / 2, pFill);
        // zero tick for the preamp column (its scale differs)
        if (col == 0) c.drawLine(cx - colW * 0.3f, y0, cx + colW * 0.3f, y0, pGrid);
        float tw = colW * 0.56f;
        boolean active = col == activeCol;
        float lift = getResources().getDisplayMetrics().density * 2;
        r.set(cx - tw / 2, y - thumbH / 2 + lift, cx + tw / 2, y + thumbH / 2 + lift);
        c.drawRoundRect(r, thumbH / 2, thumbH / 2, pShadow);
        pThumb.setColor(active ? Ui.PRIMARY : Ui.ON_SURFACE);
        pThumb.setAlpha(dim ? 110 : 255);
        r.set(cx - tw / 2, y - thumbH / 2, cx + tw / 2, y + thumbH / 2);
        c.drawRoundRect(r, thumbH / 2, thumbH / 2, pThumb);
        pFill.setAlpha(255);
        pGrid.setAlpha(255);
        c.drawLine(cx - tw * 0.22f, y, cx + tw * 0.22f, y, pGrid);
        pValue.setColor(active ? Ui.PRIMARY : Ui.ON_SURFACE);
        pValue.setAlpha(dim ? 120 : 255);
        c.drawText(EqSettings.db(v), cx, valueY, pValue);
    }

    private void drawCurve(Canvas c) {
        path.reset();
        boolean started = false;
        pCurve.setAlpha(eqOn ? 210 : 70);
        if (resp != null && resp.length == Engine.NRESP) {
            for (int k = 0; k < Engine.NRESP; k++) {
                if (resp[k] == Engine.RESP_NONE) continue;
                float x = bandXForHz(Engine.respHz(k));
                float y = yFor(1, Math.max(-1500, Math.min(1500, resp[k])));
                y = Math.max(trackTop, Math.min(trackBottom, y));
                if (!started) {
                    path.moveTo(x, y);
                    started = true;
                } else {
                    path.lineTo(x, y);
                }
            }
        } else {
            // not attached: connect the slider values
            for (int k = 0; k < EqSettings.NB; k++) {
                float x = colCx(1 + k), y = yFor(1, bands[k]);
                if (k == 0) path.moveTo(x, y);
                else path.lineTo(x, y);
            }
            pCurve.setAlpha(90);
            started = true;
        }
        if (started) c.drawPath(path, pCurve);
    }

    private void drawMeter(Canvas c) {
        float cx = colCx(11), mw = colW * 0.34f;
        float top = trackTop, bot = trackBottom;
        r.set(cx - mw / 2, top, cx + mw / 2, bot);
        c.drawRoundRect(r, mw / 2, mw / 2, pTrack);
        float level = meterLive ? Math.max(METER_MIN_DB, Math.min(0f, avgDb)) : METER_MIN_DB;
        float y = bot - (level - METER_MIN_DB) / -METER_MIN_DB * (bot - top);
        pMeter.setColor(Ui.SECONDARY);
        r.set(cx - mw / 2, y, cx + mw / 2, bot);
        if (meterLive && level > METER_MIN_DB) c.drawRoundRect(r, mw / 2, mw / 2, pMeter);
        if (meterLive && holdDb > METER_MIN_DB) {
            float hy = bot - (Math.min(0f, holdDb) - METER_MIN_DB) / -METER_MIN_DB * (bot - top);
            pThumb.setColor(Ui.ON_SURFACE);
            c.drawLine(cx - mw / 2, hy, cx + mw / 2, hy, pThumb);
        }
        // dBFS ticks
        pSub.setTextAlign(Paint.Align.LEFT);
        for (int db = 0; db >= (int) METER_MIN_DB; db -= 6) {
            float ty = bot - (db - METER_MIN_DB) / -METER_MIN_DB * (bot - top);
            c.drawText(String.valueOf(db), cx + mw / 2 + 6, ty + textSize * 0.3f, pSub);
        }
        pSub.setTextAlign(Paint.Align.CENTER);
        String v = !meterLive ? "--" : avgDb <= -99f ? "silent" : String.format(java.util.Locale.US, "%.1f", avgDb);
        c.drawText(v, cx, valueY, pValue);
        c.drawText("Output", cx, labelY + textSize, pText);
        c.drawText(grDb < -0.05f ? String.format(java.util.Locale.US, "guard %.1f dB", grDb) : "avg dBFS", cx, sub2Y, pSub);
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        switch (e.getActionMasked()) {
        case MotionEvent.ACTION_DOWN: {
            int col = colAt(e.getX());
            if (col < 0 || col > 10) return false;
            long now = e.getEventTime();
            if (col == lastDownCol && now - lastDownAt < 350) {
                // double tap: back to 0
                lastDownCol = -1;
                setCol(col, 0);
                if (listener != null) listener.onSlider(col, 0, true);
                activeCol = -1;
                return true;
            }
            lastDownCol = col;
            lastDownAt = now;
            activeCol = col;
            downY = e.getY();
            downValue = col == 0 ? preamp : bands[col - 1];
            getParent().requestDisallowInterceptTouchEvent(true);
            return true;
        }
        case MotionEvent.ACTION_MOVE:
            if (activeCol >= 0) moveTo(e.getY(), false);
            return true;
        case MotionEvent.ACTION_UP:
        case MotionEvent.ACTION_CANCEL:
            if (activeCol >= 0) moveTo(e.getY(), true);
            activeCol = -1;
            invalidate();
            return true;
        default:
            return true;
        }
    }

    /** Relative drag: the slider moves with the finger from where it was (a tap changes nothing). */
    private void moveTo(float y, boolean done) {
        float span = trackBottom - trackTop - thumbH;
        float lo = activeCol == 0 ? EqSettings.PRE_MIN : EqSettings.BAND_MIN;
        float hi = activeCol == 0 ? EqSettings.PRE_MAX : EqSettings.BAND_MAX;
        int v = EqSettings.clamp(EqSettings.snap(Math.round(downValue + (downY - y) / span * (hi - lo))), (int) lo, (int) hi);
        int old = activeCol == 0 ? preamp : bands[activeCol - 1];
        if (v != old) setCol(activeCol, v);
        if (listener != null && (v != old || done)) listener.onSlider(activeCol, v, done);
    }

    private void setCol(int col, int v) {
        if (col == 0) preamp = v;
        else bands[col - 1] = v;
        invalidate();
    }
}
