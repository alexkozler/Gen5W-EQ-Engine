package com.eqengine.app;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.os.SystemClock;
import android.view.View;

import java.util.Locale;

/**
 * Drawn behind the EQ face, at the same size (EqPanel in Easy mode, XPanel in Expert mode): the
 * output meter (Easy's column 11) and, when the Live switch is on, the live view: how loud each
 * part of the range is (48 bands, 20 Hz .. 20 kHz) as a filled shape on the face's frequency
 * axis. Only this view is redrawn as the music moves (about 20-25 times a second); the sliders
 * and curves in front of it are not.
 * The readings come lined up with what is heard (Delay); here they get meter-like movement: a
 * quick rise and a slower fall, so the shape does not flicker.
 */
final class LiveLayer extends View {
    /** Where the face in front draws: the live view's area and frequency axis, and the meter's column. */
    interface Geometry {
        float specLeft();
        float specRight();
        float specTop();
        float specBottom();
        float xForHz(double hz);
        boolean hasMeter();
        float meterCx();
        float colWidth();
        float trackTop();
        float trackBottom();
        float textSize();
        float valueY();
        float labelY();
        float sub2Y();
    }

    private static final float METER_MIN_DB = -36f;
    /**
     * The live view's scale: band level in dBFS from the bottom of the slider tracks to the top.
     * A top at -12 dBFS was too low: loud music (about -7 dBFS average) pressed against it.
     */
    private static final float SPEC_BOT_DB = -72f, SPEC_TOP_DB = -6f;
    private static final float RISE_MS = 25f, FALL_MS = 300f, SPEC_FALL_MS = 350f;

    private final Geometry panel;
    private final Paint pTrack = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pMeter = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pHold = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pText = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pSub = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pValue = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pSpecFill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pSpecLine = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF r = new RectF();
    private final Path fill = new Path(), line = new Path();

    // meter
    private boolean meterLive;
    private float avgDb = -100f, shownDb = -100f, holdDb = -100f, grDb = 0f;
    private long holdAt, meterAt;
    // live view
    private boolean specOn;
    private final float[] spec = new float[Engine.NSPEC];
    private final boolean[] specHas = new boolean[Engine.NSPEC];
    private final float[] specX = new float[Engine.NSPEC];
    private long specAt;
    private boolean specVisible;

    LiveLayer(Context c, Geometry panel) {
        super(c);
        this.panel = panel;
        pTrack.setColor(Ui.SURFACE_TOP);
        pMeter.setColor(Ui.SECONDARY);
        pHold.setColor(Ui.ON_SURFACE);
        pHold.setStrokeWidth(Math.max(2f, 1.5f * Ui.density(c)));
        pText.setColor(Ui.ON_SURFACE);
        pText.setTextAlign(Paint.Align.CENTER);
        pSub.setColor(Ui.ON_SURFACE_VAR);
        pValue.setColor(Ui.ON_SURFACE);
        pValue.setTextAlign(Paint.Align.CENTER);
        pValue.setTypeface(Typeface.DEFAULT_BOLD);
        pSpecFill.setColor(Ui.PRIMARY);
        pSpecFill.setAlpha(46);
        pSpecFill.setStyle(Paint.Style.FILL);
        pSpecLine.setColor(Ui.PRIMARY);
        pSpecLine.setAlpha(150);
        pSpecLine.setStyle(Paint.Style.STROKE);
        pSpecLine.setStrokeWidth(Math.max(2f, 1.5f * Ui.density(c)));
        pSpecLine.setStrokeJoin(Paint.Join.ROUND);
        for (int b = 0; b < spec.length; b++) spec[b] = SPEC_BOT_DB - 10f;
    }

    private static float ease(float from, float to, float dtMs) {
        float tc = to > from ? RISE_MS : FALL_MS;
        return from + (to - from) * (float) (1.0 - Math.exp(-dtMs / tc));
    }

    /**
     * The meter. peak 0..32768, avgCdb = average (RMS) in 0.01 dBFS (-10000 = silent), minGain =
     * clip guard gain x10000 (from the statistics); live = audio is playing at this moment.
     */
    void setMeter(int peak, int avgCdb, int minGain, boolean live) {
        long now = SystemClock.uptimeMillis();
        float dt = meterAt == 0 ? 1000f : Math.min(1000f, now - meterAt);
        meterAt = now;
        meterLive = live;
        avgDb = live && avgCdb > -10000 ? avgCdb / 100f : -100f;
        shownDb = ease(shownDb, avgDb, dt);
        float pk = live && peak > 0 ? (float) (20 * Math.log10(peak / 32768.0)) : -100f;
        if (pk >= holdDb) {
            holdDb = pk;
            holdAt = now;
        } else if (now - holdAt > 1200) {
            holdDb = Math.max(pk, holdDb - 20f * dt / 1000f); // the peak mark falls 20 dB/s after 1.2 s
        }
        grDb = minGain > 0 && minGain < 10000 ? (float) (20 * Math.log10(minGain / 10000.0)) : 0f;
        invalidate();
    }

    /** Live view on or off; off clears it. */
    void setSpectrumOn(boolean on) {
        specOn = on;
        if (!on) {
            for (int b = 0; b < spec.length; b++) spec[b] = SPEC_BOT_DB - 10f;
            specVisible = false;
            specAt = 0;
        }
        invalidate();
    }

    /** One live-view reading lined up with the sound (see eqengine.c spec_read), or null for silence. */
    void setSpectrum(int[] v) {
        if (!specOn) return;
        long now = SystemClock.uptimeMillis();
        float dt = specAt == 0 ? 1000f : Math.min(1000f, now - specAt);
        specAt = now;
        boolean any = false;
        for (int b = 0; b < spec.length; b++) {
            boolean has = v != null && v.length >= 4 + spec.length && v[4 + b] != Engine.RESP_NONE;
            float target = has ? v[4 + b] / 100f : SPEC_BOT_DB - 10f;
            if (v != null) specHas[b] = has;
            float tc = target > spec[b] ? RISE_MS : SPEC_FALL_MS;
            spec[b] += (target - spec[b]) * (float) (1.0 - Math.exp(-dt / tc));
            if (specHas[b] && spec[b] > SPEC_BOT_DB) any = true;
        }
        if (any || specVisible) invalidate();
        specVisible = any;
    }

    @Override
    protected void onDraw(Canvas c) {
        if (specOn && specVisible) drawSpectrum(c);
        drawMeter(c);
    }

    private float specY(float db) {
        float top = panel.specTop(), bot = panel.specBottom();
        float t = (Math.max(SPEC_BOT_DB, Math.min(SPEC_TOP_DB, db)) - SPEC_BOT_DB) / (SPEC_TOP_DB - SPEC_BOT_DB);
        return bot - t * (bot - top);
    }

    private void drawSpectrum(Canvas c) {
        float gl = panel.specLeft(), gr = panel.specRight();
        float bot = panel.specBottom();
        fill.reset();
        line.reset();
        int first = -1, last = -1;
        for (int b = 0; b < spec.length; b++) {
            if (!specHas[b]) continue;
            float x = panel.xForHz(20.0 * Math.pow(1000.0, b / (double) (spec.length - 1)));
            specX[b] = x;
            float y = specY(spec[b]);
            if (first < 0) {
                first = b;
                fill.moveTo(x, bot);
                fill.lineTo(x, y);
                line.moveTo(x, y);
            } else {
                fill.lineTo(x, y);
                line.lineTo(x, y);
            }
            last = b;
        }
        if (first < 0) return;
        fill.lineTo(specX[last], bot);
        fill.close();
        c.save();
        c.clipRect(gl, panel.specTop(), gr, bot);
        c.drawPath(fill, pSpecFill);
        c.drawPath(line, pSpecLine);
        c.restore();
    }

    private void drawMeter(Canvas c) {
        if (!panel.hasMeter()) return;
        float cx = panel.meterCx(), mw = panel.colWidth() * 0.34f;
        float top = panel.trackTop(), bot = panel.trackBottom(), ts = panel.textSize();
        if (bot <= top) return;
        pText.setTextSize(ts);
        pSub.setTextSize(ts * 0.82f);
        pValue.setTextSize(ts * 1.1f);
        r.set(cx - mw / 2, top, cx + mw / 2, bot);
        c.drawRoundRect(r, mw / 2, mw / 2, pTrack);
        float level = meterLive ? Math.max(METER_MIN_DB, Math.min(0f, shownDb)) : METER_MIN_DB;
        float y = bot - (level - METER_MIN_DB) / -METER_MIN_DB * (bot - top);
        r.set(cx - mw / 2, y, cx + mw / 2, bot);
        if (meterLive && level > METER_MIN_DB) c.drawRoundRect(r, mw / 2, mw / 2, pMeter);
        if (meterLive && holdDb > METER_MIN_DB) {
            float hy = bot - (Math.min(0f, holdDb) - METER_MIN_DB) / -METER_MIN_DB * (bot - top);
            c.drawLine(cx - mw / 2, hy, cx + mw / 2, hy, pHold);
        }
        // dBFS ticks
        pSub.setTextAlign(Paint.Align.LEFT);
        for (int db = 0; db >= (int) METER_MIN_DB; db -= 6) {
            float ty = bot - (db - METER_MIN_DB) / -METER_MIN_DB * (bot - top);
            c.drawText(String.valueOf(db), cx + mw / 2 + 6, ty + ts * 0.3f, pSub);
        }
        pSub.setTextAlign(Paint.Align.CENTER);
        String v = !meterLive ? "--" : avgDb <= -99f ? "silent" : String.format(Locale.US, "%.1f", shownDb);
        c.drawText(v, cx, panel.valueY(), pValue);
        c.drawText("Output", cx, panel.labelY() + ts, pText);
        c.drawText(grDb < -0.05f ? String.format(Locale.US, "guard %.1f dB", grDb) : "avg dBFS", cx, panel.sub2Y(), pSub);
    }
}
