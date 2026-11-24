package com.eqengine.app;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.view.MotionEvent;
import android.view.View;

/**
 * Material-style horizontal slider for the listening position: -100 (driver's seat) .. 0 (centre)
 * .. +100 (passenger's seat), in steps of 5. The active track runs from the centre to the thumb.
 * Double-tap returns to the centre.
 */
final class HSlider extends View {
    interface Listener {
        void onSlide(int value, boolean done);
    }

    private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint t = new Paint(Paint.ANTI_ALIAS_FLAG);
    private Listener listener;
    private int value;
    private boolean dragging;
    private long lastDown;
    private boolean centred;

    HSlider(Context c) {
        super(c);
        t.setTextAlign(Paint.Align.CENTER);
    }

    void setListener(Listener l) {
        listener = l;
    }

    void setValue(int v) {
        value = v;
        invalidate();
    }

    private float d() {
        return getResources().getDisplayMetrics().density;
    }

    private float left() {
        return 40 * d();
    }

    private float right() {
        return getWidth() - 40 * d();
    }

    private float xFor(int v) {
        return left() + (v + 100) / 200f * (right() - left());
    }

    @Override
    protected void onDraw(Canvas c) {
        float d = d();
        float y = 22 * d;
        // track
        p.setStyle(Paint.Style.FILL);
        p.setColor(Ui.SURFACE_TOP);
        c.drawRoundRect(new android.graphics.RectF(left(), y - 4 * d, right(), y + 4 * d), 4 * d, 4 * d, p);
        float x0 = xFor(0), x = xFor(value);
        p.setColor(Ui.PRIMARY);
        c.drawRoundRect(new android.graphics.RectF(Math.min(x0, x), y - 4 * d, Math.max(x0, x), y + 4 * d), 4 * d, 4 * d, p);
        // ticks
        for (int v = -100; v <= 100; v += 50) {
            p.setColor(v == 0 ? Ui.ON_SURFACE_VAR : Ui.OUTLINE);
            c.drawCircle(xFor(v), y, 2.5f * d, p);
        }
        // thumb
        p.setColor(dragging ? Ui.ON_PRIMARY_CONTAINER : Ui.PRIMARY);
        c.drawCircle(x, y, (dragging ? 14 : 12) * d, p);
        // labels
        t.setTextSize(16 * d);
        t.setColor(value <= -95 ? Ui.ON_SURFACE : Ui.ON_SURFACE_VAR);
        c.drawText("Driver", xFor(-100), y + 34 * d, t);
        t.setColor(value == 0 ? Ui.ON_SURFACE : Ui.ON_SURFACE_VAR);
        c.drawText("Center", xFor(0), y + 34 * d, t);
        t.setColor(value >= 95 ? Ui.ON_SURFACE : Ui.ON_SURFACE_VAR);
        c.drawText("Passenger", xFor(100), y + 34 * d, t);
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        int a = e.getActionMasked();
        if (a == MotionEvent.ACTION_DOWN) {
            getParent().requestDisallowInterceptTouchEvent(true);
            long now = e.getEventTime();
            if (now - lastDown < 350) {
                lastDown = 0;
                set(0, true);
                // (after 0.7.6) the rest of this touch is ignored: its lift used to put the slider
                // back under the finger at once, so a double tap never centred it
                centred = true;
                return true;
            }
            lastDown = now;
            centred = false;
            dragging = true;
        }
        if (centred) {
            if (a == MotionEvent.ACTION_UP || a == MotionEvent.ACTION_CANCEL) centred = false;
            return true;
        }
        if (a == MotionEvent.ACTION_DOWN || a == MotionEvent.ACTION_MOVE || a == MotionEvent.ACTION_UP) {
            float f = (e.getX() - left()) / (right() - left());
            int v = Math.round((f * 200f - 100f) / 5f) * 5;
            v = Math.max(-100, Math.min(100, v));
            boolean done = a == MotionEvent.ACTION_UP;
            if (done) dragging = false;
            set(v, done);
        }
        if (a == MotionEvent.ACTION_CANCEL) {
            dragging = false;
            invalidate();
        }
        return true;
    }

    private void set(int v, boolean done) {
        boolean changed = v != value;
        value = v;
        invalidate();
        if (listener != null && (changed || done)) listener.onSlide(v, done);
    }
}
