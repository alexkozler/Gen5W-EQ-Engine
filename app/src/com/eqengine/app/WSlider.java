package com.eqengine.app;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.MotionEvent;
import android.view.View;

/**
 * The Expert band card's Width slider (0.6.11): 0 .. 1000, the active track from the left to the
 * thumb, with a word under each end ("wide" / "narrow" for a peak). Disabled for the shelves,
 * whose slope is fixed.
 */
final class WSlider extends View {
    interface Listener {
        void onWidth(int pos, boolean done);
    }

    private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint t = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF r = new RectF();
    private Listener listener;
    private int pos;
    private boolean on = true, dragging;
    private String left = "wide", right = "narrow";

    WSlider(Context c) {
        super(c);
    }

    void setListener(Listener l) {
        listener = l;
    }

    void set(int v, boolean enabled, String leftWord, String rightWord) {
        pos = Math.max(0, Math.min(1000, v));
        on = enabled;
        left = leftWord;
        right = rightWord;
        invalidate();
    }

    private float d() {
        return getResources().getDisplayMetrics().density;
    }

    private float x0() {
        return 11 * d();
    }

    private float x1() {
        return getWidth() - 11 * d();
    }

    @Override
    protected void onDraw(Canvas c) {
        float d = d(), y = 15 * d;
        p.setStyle(Paint.Style.FILL);
        p.setColor(Ui.SURFACE_TOP);
        r.set(x0(), y - 3 * d, x1(), y + 3 * d);
        c.drawRoundRect(r, 3 * d, 3 * d, p);
        if (on) {
            float x = x0() + pos / 1000f * (x1() - x0());
            p.setColor(Ui.PRIMARY);
            r.set(x0(), y - 3 * d, x, y + 3 * d);
            c.drawRoundRect(r, 3 * d, 3 * d, p);
            p.setColor(dragging ? Ui.PRIMARY : Ui.ON_SURFACE);
            c.drawCircle(x, y, (dragging ? 12 : 11) * d, p);
        }
        t.setTextSize(12 * d);
        t.setColor(Ui.ON_SURFACE_VAR);
        t.setTextAlign(Paint.Align.LEFT);
        c.drawText(left, x0() - 11 * d, y + 27 * d, t);
        t.setTextAlign(Paint.Align.RIGHT);
        c.drawText(right, x1() + 11 * d, y + 27 * d, t);
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        if (!on) return false;
        int a = e.getActionMasked();
        if (a == MotionEvent.ACTION_DOWN) {
            getParent().requestDisallowInterceptTouchEvent(true);
            dragging = true;
        }
        if (a == MotionEvent.ACTION_DOWN || a == MotionEvent.ACTION_MOVE || a == MotionEvent.ACTION_UP) {
            int v = Math.round((e.getX() - x0()) / (x1() - x0()) * 1000f);
            v = Math.max(0, Math.min(1000, v));
            boolean done = a == MotionEvent.ACTION_UP;
            if (done) dragging = false;
            boolean changed = v != pos;
            pos = v;
            invalidate();
            if (listener != null && (changed || done)) listener.onWidth(v, done);
        }
        if (a == MotionEvent.ACTION_CANCEL) {
            dragging = false;
            invalidate();
            if (listener != null) listener.onWidth(pos, true);
        }
        return true;
    }
}
