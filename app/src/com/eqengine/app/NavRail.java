package com.eqengine.app;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.view.MotionEvent;
import android.view.View;

/**
 * Material 3 navigation rail with large items spread down the left edge (icon in a pill when
 * selected, label below). Icons are drawn, since Android 4.4 has no vector icons. There is no
 * close item: the car's own Back and Home buttons leave the screen.
 */
final class NavRail extends View {
    interface Listener {
        void onRail(int item);
    }

    static final int EQ = 0, POSITION = 1, SETTINGS = 2, STATUS = 3, LAB = 4;
    private static final String[] LABELS = {"EQ", "Position", "Settings", "Status", "Lab"};

    private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint t = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF r = new RectF();
    private final Path path = new Path();
    private Listener listener;
    private int selected = EQ;
    private int pressed = -1;
    private final boolean[] badge = new boolean[LABELS.length];

    NavRail(Context c) {
        super(c);
        t.setTextAlign(Paint.Align.CENTER);
        setBackgroundColor(Ui.RAIL);
    }

    void setListener(Listener l) {
        listener = l;
    }

    void select(int item) {
        selected = item;
        invalidate();
    }

    /** A small dot on an item (for example Status when something needs attention). */
    void setBadge(int item, boolean on) {
        if (badge[item] != on) {
            badge[item] = on;
            invalidate();
        }
    }

    private float d() {
        return getResources().getDisplayMetrics().density;
    }

    /** Item height: up to 104 dp, spread over the rail's height. */
    private float step() {
        return Math.min(104 * d(), (getHeight() - 12 * d()) / LABELS.length);
    }

    private float itemTop(int i) {
        return 6 * d() + i * step();
    }

    @Override
    protected void onDraw(Canvas c) {
        float d = d();
        float cx = getWidth() / 2f;
        float st = step();
        float label = Math.min(17 * d, st * 0.21f);
        t.setTextSize(label);
        float pillH = Math.min(44 * d, st * 0.52f);
        for (int i = 0; i < LABELS.length; i++) {
            float top = itemTop(i) + (st - (pillH + label * 1.9f)) / 2;
            boolean sel = i == selected;
            r.set(cx - 36 * d, top, cx + 36 * d, top + pillH);
            if (sel || i == pressed) {
                p.setStyle(Paint.Style.FILL);
                p.setColor(sel ? Ui.PRIMARY_CONTAINER : Ui.SURFACE_HI);
                c.drawRoundRect(r, pillH / 2, pillH / 2, p);
            }
            int fg = sel ? Ui.ON_PRIMARY_CONTAINER : Ui.ON_SURFACE_VAR;
            float iy = top + pillH / 2;
            float scale = pillH / (44 * d) * 1.3f;
            c.save();
            c.scale(scale, scale, cx, iy);
            drawIcon(c, i, cx, iy, d, fg);
            c.restore();
            if (badge[i]) {
                p.setStyle(Paint.Style.FILL);
                p.setColor(Ui.ERROR);
                c.drawCircle(cx + 22 * d, top + 7 * d, 5 * d, p);
            }
            t.setColor(sel ? Ui.ON_SURFACE : Ui.ON_SURFACE_VAR);
            t.setFakeBoldText(sel);
            c.drawText(LABELS[i], cx, top + pillH + label * 1.35f, t);
        }
    }

    private void stroke(int color, float w) {
        p.setColor(color);
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(w);
        p.setStrokeCap(Paint.Cap.ROUND);
        p.setStrokeJoin(Paint.Join.ROUND);
    }

    private void fill(int color) {
        p.setColor(color);
        p.setStyle(Paint.Style.FILL);
    }

    private void drawIcon(Canvas c, int i, float cx, float cy, float d, int color) {
        stroke(color, 2.2f * d);
        switch (i) {
        case EQ: {
            // three sliders with knobs at different heights
            float[] knob = {-4f, 4f, -1f};
            for (int k = 0; k < 3; k++) {
                float x = cx + (k - 1) * 7.5f * d;
                stroke(color, 2.2f * d);
                c.drawLine(x, cy - 10 * d, x, cy + 10 * d, p);
                fill(color);
                r.set(x - 4 * d, cy + (knob[k] - 2.2f) * d, x + 4 * d, cy + (knob[k] + 2.2f) * d);
                c.drawRoundRect(r, 1.5f * d, 1.5f * d, p);
            }
            break;
        }
        case POSITION: {
            // top-down car with the listener in the left front seat
            r.set(cx - 7.5f * d, cy - 11 * d, cx + 7.5f * d, cy + 11 * d);
            c.drawRoundRect(r, 5 * d, 5 * d, p);
            c.drawLine(cx - 5.5f * d, cy - 4.5f * d, cx + 5.5f * d, cy - 4.5f * d, p);
            fill(color);
            c.drawCircle(cx - 3 * d, cy + 0.5f * d, 2.6f * d, p);
            stroke(color, 1.6f * d);
            c.drawCircle(cx - 3 * d, cy + 0.5f * d, 5.2f * d, p);
            break;
        }
        case SETTINGS: {
            // gear: 8 teeth as one outline, with a hole
            path.reset();
            int teeth = 8;
            float ro = 10.5f * d, ri = 7.8f * d;
            for (int k = 0; k < teeth * 4; k++) {
                double a = (k / (double) (teeth * 4)) * 2 * Math.PI - Math.PI / 2;
                int q = k % 4;
                float rad = q == 1 || q == 2 ? ro : ri;
                float x = cx + (float) Math.cos(a) * rad, y = cy + (float) Math.sin(a) * rad;
                if (k == 0) path.moveTo(x, y);
                else path.lineTo(x, y);
            }
            path.close();
            stroke(color, 2f * d);
            c.drawPath(path, p);
            c.drawCircle(cx, cy, 3.3f * d, p);
            break;
        }
        case STATUS: {
            // pulse line in a rounded frame
            r.set(cx - 11 * d, cy - 9 * d, cx + 11 * d, cy + 9 * d);
            stroke(color, 1.8f * d);
            c.drawRoundRect(r, 3.5f * d, 3.5f * d, p);
            path.reset();
            path.moveTo(cx - 8 * d, cy + 1 * d);
            path.lineTo(cx - 4 * d, cy + 1 * d);
            path.lineTo(cx - 1.5f * d, cy - 5 * d);
            path.lineTo(cx + 1.5f * d, cy + 5 * d);
            path.lineTo(cx + 4 * d, cy + 1 * d);
            path.lineTo(cx + 8 * d, cy + 1 * d);
            stroke(color, 2.2f * d);
            c.drawPath(path, p);
            break;
        }
        case LAB: {
            // flask with liquid
            path.reset();
            path.moveTo(cx - 3.5f * d, cy - 10 * d);
            path.lineTo(cx - 3.5f * d, cy - 3 * d);
            path.lineTo(cx - 9.5f * d, cy + 9 * d);
            path.lineTo(cx + 9.5f * d, cy + 9 * d);
            path.lineTo(cx + 3.5f * d, cy - 3 * d);
            path.lineTo(cx + 3.5f * d, cy - 10 * d);
            c.drawPath(path, p);
            c.drawLine(cx - 6 * d, cy - 10 * d, cx + 6 * d, cy - 10 * d, p);
            path.reset();
            path.moveTo(cx - 6.6f * d, cy + 3.5f * d);
            path.lineTo(cx + 6.6f * d, cy + 3.5f * d);
            path.lineTo(cx + 8.6f * d, cy + 8 * d);
            path.lineTo(cx - 8.6f * d, cy + 8 * d);
            path.close();
            fill(color);
            c.drawPath(path, p);
            break;
        }
        default:
            break;
        }
    }

    private int hit(float y) {
        float st = step();
        for (int i = 0; i < LABELS.length; i++) {
            float top = itemTop(i);
            if (y >= top && y < top + st) return i;
        }
        return -1;
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        switch (e.getActionMasked()) {
        case MotionEvent.ACTION_DOWN:
            pressed = hit(e.getY());
            invalidate();
            return pressed >= 0;
        case MotionEvent.ACTION_UP: {
            int h = hit(e.getY());
            int was = pressed;
            pressed = -1;
            invalidate();
            if (h >= 0 && h == was && listener != null) listener.onRail(h);
            return true;
        }
        case MotionEvent.ACTION_CANCEL:
            pressed = -1;
            invalidate();
            return true;
        default:
            return true;
        }
    }
}
