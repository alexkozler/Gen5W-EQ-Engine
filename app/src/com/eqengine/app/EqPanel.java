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
 * The EQ face: a preamp slider and ten vertical band sliders (31 Hz .. 16 kHz) with the EQ's real
 * response curve drawn behind them. Drag up or down anywhere in a slider's column to move it from
 * where it is (0.5 dB steps; a tap alone changes nothing); double-tap a column to put it back to 0.
 * Under the 31 Hz and 16 kHz sliders a chip shows Peak or Shelf; a tap on the label area under
 * either one switches it. Under the preamp slider, Auto sets the preamp to minus the EQ's largest
 * boost (0.6.11: it was the header's Auto preamp button). The preamp column sits at the card's
 * padding (its widest item starts there), the band columns where they always were.
 * Columns: 0 = preamp, 1..10 = bands, 11 = the output meter, which LiveLayer draws (behind this
 * view, with the live view), so the sliders are not redrawn 20 times a second.
 */
final class EqPanel extends View implements LiveLayer.Geometry {
    interface Listener {
        /** col 0 = preamp, 1..10 = bands; done = finger lifted */
        void onSlider(int col, int cdb, boolean done);

        /** The Peak/Shelf chip under col 1 (31 Hz) or col 10 (16 kHz) was tapped. */
        void onEndType(int col);

        /** The Auto chip under the preamp was tapped. */
        void onAuto();
    }

    static final int COLS = 12;

    private final Paint pTrack = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pFill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pThumb = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pShadow = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pGrid = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pCurve = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pText = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pSub = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pChip = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pChipText = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pValue = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF r = new RectF();
    private final Path path = new Path();

    private Listener listener;
    private int preamp;
    private final int[] bands = new int[EqSettings.NB];
    private int[] resp;
    private boolean eqOn = true;
    private boolean lowShelf, highShelf;

    // geometry
    private float pad, gap, colW, kw, x1, preW, trackTop, trackBottom, valueY, labelY, sub2Y, thumbH, trackW, preCx;
    private float textSize;
    // touch
    private int activeCol = -1;
    private int chipCol = -1;
    private long lastDownAt;
    private int lastDownCol = -1;
    private float downY;
    private int downValue;

    EqPanel(Context c) {
        super(c);
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
        pChipText.setTextAlign(Paint.Align.CENTER);
        pChipText.setTypeface(Typeface.DEFAULT_BOLD);
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
        lowShelf = s.lowShelf;
        highShelf = s.highShelf;
        invalidate();
    }

    void setResponse(int[] resp) {
        if (resp == this.resp) return;
        this.resp = resp;
        invalidate();
    }

    @Override
    protected void onSizeChanged(int w, int h, int ow, int oh) {
        float d = getResources().getDisplayMetrics().density;
        pad = 12 * d;
        gap = Math.max(16 * d, w * 0.02f);
        // kw: twelve even columns, as up to 0.6.11; it sets the text and the sliders' size
        kw = (w - 2 * pad - 2 * gap) / COLS;
        textSize = Math.max(16 * d, Math.min(kw * 0.22f, h * 0.06f));
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
        trackW = Math.max(6 * d, kw * 0.09f);
        pCurve.setStrokeWidth(Math.max(3f, 2.5f * d));
        // the preamp column is only as wide as its widest item; the band columns, the dB scale
        // PRE_GAP after it, and the meter share the rest
        preW = preampW(pText, pChipText, kw, d);
        preCx = pad + preW / 2f;
        x1 = pad + preW + PRE_GAP * d + scaleW(pSub) + gap * 0.15f;
        colW = (w - pad - gap - x1) / (COLS - 1);
    }

    /** The space between the preamp column and the dB scale (dp), on both EQ pages. */
    static final float PRE_GAP = 10;

    /** The dB scale's widest label. */
    static float scaleW(Paint sub) {
        return Math.max(sub.measureText("+12"), sub.measureText("-12"));
    }

    /** The preamp column's width: its widest item, "Preamp" or the Auto chip. Starts at the padding. */
    static float preampW(Paint text, Paint chip, float kw, float d) {
        return Math.max(text.measureText("Preamp"), Math.min(kw * 0.92f, chip.measureText("Auto") + 28 * d));
    }

    private float cxOf(int col) {
        return col == 0 ? preCx : colCx(col);
    }

    // geometry for LiveLayer, which draws behind this view at the same size
    float colLeft(int col) {
        if (col == 0) return pad;
        return x1 + (col - 1) * colW + (col >= 11 ? gap : 0);
    }

    float colCx(int col) {
        return colLeft(col) + colW / 2f;
    }

    public float colWidth() {
        return colW;
    }

    float gapWidth() {
        return gap;
    }

    public float trackTop() {
        return trackTop;
    }

    public float trackBottom() {
        return trackBottom;
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

    public float textSize() {
        return textSize;
    }

    // LiveLayer.Geometry
    public float specLeft() {
        return colLeft(1) - gap * 0.4f;
    }

    public float specRight() {
        return colLeft(10) + colW + gap * 0.4f;
    }

    public float specTop() {
        return trackTop;
    }

    public float specBottom() {
        return trackBottom;
    }

    public float xForHz(double hz) {
        return bandXForHz(hz);
    }

    public boolean hasMeter() {
        return true;
    }

    public float meterCx() {
        return colCx(11);
    }

    /** x of a frequency: band k's centre is colCx(1 + k), one octave per column. */
    float bandXForHz(double hz) {
        double oct = Math.log(hz / EqSettings.CENTRES[0]) / Math.log(2.0);
        return (float) (colCx(1) + oct * colW);
    }

    private int colAt(float x) {
        // the preamp: its column and the first half of the space before the dB scale
        if (x < pad + preW + PRE_GAP * getResources().getDisplayMetrics().density * 0.5f) return 0;
        for (int c = 1; c < COLS; c++) {
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

    @Override
    protected void onDraw(Canvas c) {
        // band area grid: +12, +6, 0, -6, -12 dB
        float gl = colLeft(1) - gap * 0.4f, gr = colLeft(10) + colW + gap * 0.4f;
        for (int db = -12; db <= 12; db += 6) {
            float y = yFor(1, db * 100);
            pGrid.setAlpha(db == 0 ? 255 : 120);
            c.drawLine(gl, y, gr, y, pGrid);
        }
        pGrid.setAlpha(255);
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
            c.drawText(label, cxOf(col), labelY + textSize, pText);
            if (col == 1) drawChip(c, col, lowShelf);
            else if (col == 10) drawChip(c, col, highShelf);
            else if (col > 0) c.drawText("Hz", colCx(col), sub2Y, pSub);
            else drawAuto(c, preCx, chipCol == 0, autoWarn(), kw, sub2Y, pSub.getTextSize(), pChip, pChipText, r, getResources().getDisplayMetrics().density);
        }
    }

    /** "Auto" under the preamp: an outlined chip with the accent's text (an action, not a state). */
    /**
     * The preamp leaves more than XPanel.AUTO_WARN_DB of the boost to the clip guard (0.7.4): the
     * largest point of the filter's own response (20 Hz .. 20 kHz) plus the preamp.
     */
    private boolean autoWarn() {
        if (!eqOn || resp == null || resp.length != Engine.NRESP) return false;
        int m = Integer.MIN_VALUE;
        for (int v : resp) if (v != Engine.RESP_NONE) m = Math.max(m, v);
        return m != Integer.MIN_VALUE && (m + preamp) / 100f > XPanel.AUTO_WARN_DB;
    }

    /** warn: amber, filled (the preamp leaves boost to the clip guard; tapping Auto takes it away). */
    static void drawAuto(Canvas c, float cx, boolean pressed, boolean warn, float colW, float sub2Y, float subSize, Paint pChip,
                         Paint pChipText, RectF r, float d) {
        String label = "Auto";
        float w = Math.min(colW * 0.92f, pChipText.measureText(label) + 28 * d);
        float h = pChipText.getTextSize() * 1.55f;
        float cy = sub2Y - subSize * 0.33f;
        r.set(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2);
        if (pressed || warn) {
            pChip.setStyle(Paint.Style.FILL);
            pChip.setColor(warn ? Ui.SECONDARY_CONTAINER : Ui.SURFACE_HI);
            c.drawRoundRect(r, h / 2, h / 2, pChip);
        }
        pChip.setStyle(Paint.Style.STROKE);
        pChip.setStrokeWidth(Math.max(1.5f, 1.2f * d));
        pChip.setColor(warn ? Ui.SECONDARY : Ui.OUTLINE);
        c.drawRoundRect(r, h / 2, h / 2, pChip);
        pChipText.setColor(warn ? Ui.SECONDARY : Ui.PRIMARY);
        c.drawText(label, cx, cy + pChipText.getTextSize() * 0.36f, pChipText);
    }

    /** "Peak" (outlined) or "Shelf" (filled) on the Hz line. */
    private void drawChip(Canvas c, int col, boolean shelf) {
        float d = getResources().getDisplayMetrics().density;
        String label = shelf ? "Shelf" : "Peak";
        float cx = colCx(col);
        float w = Math.min(colW * 0.92f, pChipText.measureText(label) + 20 * d);
        float h = pChipText.getTextSize() * 1.55f;
        float cy = sub2Y - pSub.getTextSize() * 0.33f;
        r.set(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2);
        boolean pressed = chipCol == col;
        if (shelf) {
            pChip.setStyle(Paint.Style.FILL);
            pChip.setColor(pressed ? Ui.PRIMARY : Ui.PRIMARY_CONTAINER);
            c.drawRoundRect(r, h / 2, h / 2, pChip);
            pChipText.setColor(pressed ? Ui.ON_PRIMARY : Ui.ON_PRIMARY_CONTAINER);
        } else {
            if (pressed) {
                pChip.setStyle(Paint.Style.FILL);
                pChip.setColor(Ui.SURFACE_HI);
                c.drawRoundRect(r, h / 2, h / 2, pChip);
            }
            pChip.setStyle(Paint.Style.STROKE);
            pChip.setStrokeWidth(Math.max(1.5f, 1.2f * d));
            pChip.setColor(Ui.OUTLINE);
            c.drawRoundRect(r, h / 2, h / 2, pChip);
            pChipText.setColor(Ui.ON_SURFACE);
        }
        c.drawText(label, cx, cy + pChipText.getTextSize() * 0.36f, pChipText);
    }

    private void drawSlider(Canvas c, int col, int v) {
        float cx = cxOf(col);
        boolean dim = col > 0 && !eqOn;
        r.set(cx - trackW / 2, trackTop, cx + trackW / 2, trackBottom);
        c.drawRoundRect(r, trackW / 2, trackW / 2, pTrack);
        float y0 = yFor(col, 0), y = yFor(col, v);
        pFill.setAlpha(dim ? 70 : v >= 0 ? 255 : 170);
        r.set(cx - trackW / 2, Math.min(y0, y), cx + trackW / 2, Math.max(y0, y));
        c.drawRoundRect(r, trackW / 2, trackW / 2, pFill);
        // zero tick for the preamp column (its scale differs)
        if (col == 0) c.drawLine(cx - kw * 0.3f, y0, cx + kw * 0.3f, y0, pGrid);
        float tw = kw * 0.56f;
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

    /** The label area under a slider (where the Peak/Shelf chips are). */
    private boolean inLabels(float y) {
        return y > trackBottom + textSize * 0.2f;
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        switch (e.getActionMasked()) {
        case MotionEvent.ACTION_DOWN: {
            int col = colAt(e.getX());
            if (col < 0 || col > 10) return false;
            if ((col == 0 || col == 1 || col == 10) && inLabels(e.getY())) {
                // the Auto or Peak/Shelf chip: a tap there acts and never moves the slider
                chipCol = col;
                lastDownCol = -1;
                invalidate();
                return true;
            }
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
            if (chipCol >= 0) {
                int col = chipCol;
                chipCol = -1;
                invalidate();
                if (colAt(e.getX()) == col && inLabels(e.getY()) && listener != null) {
                    if (col == 0) listener.onAuto();
                    else listener.onEndType(col);
                }
                return true;
            }
            if (activeCol >= 0) moveTo(e.getY(), true);
            activeCol = -1;
            invalidate();
            return true;
        case MotionEvent.ACTION_CANCEL:
            chipCol = -1;
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
