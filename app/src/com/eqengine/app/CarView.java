package com.eqengine.app;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.view.MotionEvent;
import android.view.View;

/**
 * Overhead view of a car interior (front at the top, driver on the left) with its six speakers
 * and the listener. The listener moves across the front row with the position (-100 = driver's
 * seat, 0 = centre, +100 = passenger's seat); the speakers whose sound is delayed light up in the
 * second accent colour, with lines to the listener. Dragging sideways on the car moves the position.
 */
final class CarView extends View {
    interface Listener {
        void onPosition(int pos, boolean done);
    }

    private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint t = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF r = new RectF();
    private final Path path = new Path();
    private Listener listener;
    private int pos;
    private float delayMs;
    // geometry of the last draw
    private float cx, top, W, H;

    CarView(Context c) {
        super(c);
        t.setTextAlign(Paint.Align.CENTER);
    }

    void setListener(Listener l) {
        listener = l;
    }

    /** pos -100..100; delayMs = delay applied to the nearer side */
    void setPosition(int pos, float delayMs) {
        this.pos = pos;
        this.delayMs = delayMs;
        invalidate();
    }

    private float d() {
        return getResources().getDisplayMetrics().density;
    }

    @Override
    protected void onDraw(Canvas c) {
        float d = d();
        float w = getWidth(), h = getHeight();
        float labelH = 26 * d;
        H = h - labelH - 10 * d;
        W = H * 0.44f;
        if (W > w * 0.8f) {
            W = w * 0.8f;
            H = W / 0.44f;
        }
        cx = w / 2f;
        top = labelH + (h - labelH - H) / 2f;
        t.setTextSize(15 * d);
        t.setColor(Ui.ON_SURFACE_VAR);
        c.drawText("FRONT", cx, top - 9 * d, t);

        // mirrors
        p.setStyle(Paint.Style.FILL);
        p.setColor(Ui.SURFACE_TOP);
        r.set(cx - W / 2 - 0.09f * W, top + 0.25f * H, cx - W / 2 + 0.02f * W, top + 0.29f * H);
        c.drawRoundRect(r, 4 * d, 4 * d, p);
        r.set(cx + W / 2 - 0.02f * W, top + 0.25f * H, cx + W / 2 + 0.09f * W, top + 0.29f * H);
        c.drawRoundRect(r, 4 * d, 4 * d, p);
        // body
        r.set(cx - W / 2, top, cx + W / 2, top + H);
        p.setColor(Ui.SURFACE_HI);
        c.drawRoundRect(r, 0.22f * W, 0.22f * W, p);
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(2 * d);
        p.setColor(Ui.OUTLINE);
        c.drawRoundRect(r, 0.22f * W, 0.22f * W, p);
        // windshield and rear window
        p.setStyle(Paint.Style.FILL);
        p.setColor(Ui.SURFACE_TOP);
        trapezoid(c, 0.19f, 0.29f, 0.66f, 0.84f);
        trapezoid(c, 0.84f, 0.91f, 0.82f, 0.66f);
        // dashboard
        p.setColor(Color.rgb(28, 33, 41));
        r.set(cx - 0.44f * W, top + 0.29f * H, cx + 0.44f * W, top + 0.33f * H);
        c.drawRoundRect(r, 3 * d, 3 * d, p);
        // front seats, console, rear bench
        p.setColor(Ui.SURFACE_TOP);
        seat(c, -0.22f, 0.37f, 0.30f, 0.17f);
        seat(c, 0.22f, 0.37f, 0.30f, 0.17f);
        r.set(cx - 0.055f * W, top + 0.36f * H, cx + 0.055f * W, top + 0.56f * H);
        p.setColor(Color.rgb(28, 33, 41));
        c.drawRoundRect(r, 4 * d, 4 * d, p);
        p.setColor(Ui.SURFACE_TOP);
        r.set(cx - 0.40f * W, top + 0.63f * H, cx + 0.40f * W, top + 0.78f * H);
        c.drawRoundRect(r, 0.06f * W, 0.06f * W, p);
        // steering wheel (left-hand drive)
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(2.5f * d);
        p.setColor(Ui.ON_SURFACE_VAR);
        c.drawCircle(cx - 0.22f * W, top + 0.345f * H, 0.085f * W, p);

        // speakers: tweeters, front doors, rear doors (left then right)
        float hx = cx + pos / 100f * 0.22f * W, hy = top + 0.455f * H;
        boolean leftDelayed = pos < 0 && delayMs > 0, rightDelayed = pos > 0 && delayMs > 0;
        float[][] spk = {{-0.41f, 0.285f, 0.035f}, {-0.49f, 0.44f, 0.06f}, {-0.49f, 0.69f, 0.05f},
                {0.41f, 0.285f, 0.035f}, {0.49f, 0.44f, 0.06f}, {0.49f, 0.69f, 0.05f}};
        for (int i = 0; i < spk.length; i++) {
            boolean left = i < 3;
            boolean delayed = left ? leftDelayed : rightDelayed;
            float sx = cx + spk[i][0] * W, sy = top + spk[i][1] * H;
            if (pos != 0) {
                p.setStyle(Paint.Style.STROKE);
                p.setStrokeWidth(1.5f * d);
                p.setColor(delayed ? Color.argb(150, 255, 183, 77) : Color.argb(90, 79, 195, 247));
                c.drawLine(sx, sy, hx, hy, p);
            }
            p.setStyle(Paint.Style.FILL);
            p.setColor(delayed ? Ui.SECONDARY : Ui.PRIMARY);
            c.drawCircle(sx, sy, spk[i][2] * W, p);
            p.setColor(Ui.SURFACE_HI);
            c.drawCircle(sx, sy, spk[i][2] * W * 0.45f, p);
        }
        // listener (head, with a soft halo)
        p.setStyle(Paint.Style.FILL);
        p.setColor(Color.argb(60, 255, 183, 77));
        c.drawCircle(hx, hy, 0.13f * W, p);
        p.setColor(Ui.SECONDARY);
        c.drawCircle(hx, hy, 0.07f * W, p);
        // delay label next to the delayed side
        if (delayMs > 0 && pos != 0) {
            t.setTextSize(15 * d);
            t.setColor(Ui.SECONDARY);
            t.setFakeBoldText(true);
            String s = String.format(java.util.Locale.US, "+%.1f ms", delayMs);
            // outside the door speakers (their outer edge is 0.55 W from the centre), with a gap
            float edge = 0.55f * W + 12 * d;
            t.setTextAlign(pos < 0 ? Paint.Align.RIGHT : Paint.Align.LEFT);
            float sx = pos < 0 ? Math.max(t.measureText(s), cx - edge) : Math.min(getWidth() - t.measureText(s), cx + edge);
            c.drawText(s, sx, top + 0.44f * H + 5 * d, t);
            t.setTextAlign(Paint.Align.CENTER);
            t.setFakeBoldText(false);
        }
    }

    private void trapezoid(Canvas c, float y0, float y1, float w0, float w1) {
        path.reset();
        path.moveTo(cx - w0 * W / 2, top + y0 * H);
        path.lineTo(cx + w0 * W / 2, top + y0 * H);
        path.lineTo(cx + w1 * W / 2, top + y1 * H);
        path.lineTo(cx - w1 * W / 2, top + y1 * H);
        path.close();
        c.drawPath(path, p);
    }

    private void seat(Canvas c, float x, float y, float sw, float sh) {
        r.set(cx + (x - sw / 2) * W, top + y * H, cx + (x + sw / 2) * W, top + (y + sh) * H);
        c.drawRoundRect(r, 0.06f * W, 0.06f * W, p);
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        int a = e.getActionMasked();
        if (a == MotionEvent.ACTION_DOWN) getParent().requestDisallowInterceptTouchEvent(true);
        if (a == MotionEvent.ACTION_DOWN || a == MotionEvent.ACTION_MOVE || a == MotionEvent.ACTION_UP) {
            if (W <= 0) return true;
            int v = Math.round((e.getX() - cx) / (0.22f * W) * 100f / 5f) * 5;
            v = Math.max(-100, Math.min(100, v));
            boolean done = a == MotionEvent.ACTION_UP;
            if (v != pos || done) {
                pos = v;
                invalidate();
                if (listener != null) listener.onPosition(v, done);
            }
        }
        return true;
    }
}
