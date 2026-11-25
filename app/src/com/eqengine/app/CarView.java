package com.eqengine.app;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Shader;
import android.view.MotionEvent;
import android.view.View;

/**
 * Overhead view of a car's cabin (front at the top, the car's left on the left) with its six speakers
 * and the listener. The view shows the cabin only (0.7.8): the hood runs off the top (the card's top
 * edge) and the trunk fades out at the bottom. The listener moves across the front row with the
 * position (-100 = left seat, 0 = centre, +100 = right seat); the speakers whose sound is delayed
 * light up in the second accent colour, with lines to the listener. The stereo width is a dimension
 * line across the windshield, from tweeter to tweeter at 100 % (grey: off, as recorded), green when
 * changed. Dragging sideways on the car moves the position; a drag that starts on the windshield (above
 * the dashboard) sets the width instead.
 */
final class CarView extends View {
    interface Listener {
        void onPosition(int pos, boolean done);

        void onStereoWidth(int pct, boolean done);
    }

    /** The part of the car's length shown (fractions of the car's length): from the hood to past the rear bench. */
    private static final float YA = 0.14f, YB = 0.82f;
    /** The listener's head, over the front of the seat back. */
    private static final float HY = 0.47f;
    /** The tweeters' distance from the centre line, as a fraction of the car's width: the width line's ends at 100 %. */
    private static final float TW = 0.41f;
    private static final int BACK = Color.rgb(56, 65, 78);
    private static final int GREEN = Color.rgb(108, 214, 140);

    private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint t = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint fade = new Paint();
    private final RectF r = new RectF();
    private final Path path = new Path();
    private Listener listener;
    private int pos, width = 100;
    private float delayMs;
    private boolean widthDrag;
    private float downX;
    private int downWidth;
    // geometry of the last draw
    private float cx, top, W, H;
    private int fadeH = -1;

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

    /** The stereo width, percent (100 = as recorded). */
    void setWidth(int pct) {
        if (width == pct) return;
        width = pct;
        invalidate();
    }

    private float d() {
        return getResources().getDisplayMetrics().density;
    }

    @Override
    protected void onDraw(Canvas c) {
        float d = d();
        float w = getWidth(), h = getHeight();
        H = h / (YB - YA);
        W = H * 0.44f;
        float slack = 0;
        if (W > w * 0.8f) {
            W = w * 0.8f;
            H = W / 0.44f;
            slack = (h - (YB - YA) * H) / 2f;
        }
        cx = w / 2f;
        top = -YA * H + slack;

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
        // dashboard and console
        p.setColor(Color.rgb(28, 33, 41));
        r.set(cx - 0.44f * W, top + 0.29f * H, cx + 0.44f * W, top + 0.33f * H);
        c.drawRoundRect(r, 3 * d, 3 * d, p);
        r.set(cx - 0.055f * W, top + 0.36f * H, cx + 0.055f * W, top + 0.56f * H);
        c.drawRoundRect(r, 4 * d, 4 * d, p);
        // seats from above: the cushion, then the seat back (about 30 % of the seat's length), a little lighter
        for (float sx : new float[]{-0.22f, 0.22f}) {
            p.setColor(Ui.SURFACE_TOP);
            box(c, sx - 0.15f, 0.37f, sx + 0.15f, 0.483f, 0.05f);
            p.setColor(BACK);
            box(c, sx - 0.15f, 0.489f, sx + 0.15f, 0.54f, 0.04f);
        }
        p.setColor(Ui.SURFACE_TOP);
        box(c, -0.40f, 0.63f, 0.40f, 0.728f, 0.05f);
        p.setColor(BACK);
        box(c, -0.40f, 0.734f, 0.40f, 0.78f, 0.04f);

        // the stereo width: a dimension line across the windshield with its value above
        int col = width == 100 ? Ui.ON_SURFACE_VAR : GREEN;
        float ys = top + 0.235f * H, hs = TW * W * width / 100f, tk = 7 * d;
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(2 * d);
        p.setColor(col);
        if (hs > 0) c.drawLine(cx - hs, ys, cx + hs, ys, p);
        c.drawLine(cx - hs, ys - tk, cx - hs, ys + tk, p);
        if (hs > 0) c.drawLine(cx + hs, ys - tk, cx + hs, ys + tk, p);
        t.setTextSize(14 * d);
        t.setFakeBoldText(true);
        t.setColor(col);
        c.drawText("Width " + width + "%", cx, ys - 11 * d, t);
        t.setFakeBoldText(false);

        // LEFT and RIGHT at the sides, on the listener's row
        float rowY = top + 0.44f * H + 5 * d;
        t.setTextSize(15 * d);
        t.setColor(Ui.ON_SURFACE_VAR);
        t.setTextAlign(Paint.Align.LEFT);
        c.drawText("LEFT", 0, rowY, t);
        float leftW = t.measureText("LEFT"), rightW = t.measureText("RIGHT");
        t.setTextAlign(Paint.Align.RIGHT);
        c.drawText("RIGHT", w, rowY, t);
        t.setTextAlign(Paint.Align.CENTER);

        // speakers: tweeters, front doors, rear doors (left then right)
        float hx = cx + pos / 100f * 0.22f * W, hy = top + HY * H;
        boolean leftDelayed = pos < 0 && delayMs > 0, rightDelayed = pos > 0 && delayMs > 0;
        float[][] spk = {{-TW, 0.285f, 0.035f}, {-0.49f, 0.44f, 0.06f}, {-0.49f, 0.69f, 0.05f},
                {TW, 0.285f, 0.035f}, {0.49f, 0.44f, 0.06f}, {0.49f, 0.69f, 0.05f}};
        if (pos != 0) {
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(1.5f * d);
            for (int i = 0; i < spk.length; i++) {
                boolean delayed = i < 3 ? leftDelayed : rightDelayed;
                p.setColor(delayed ? Color.argb(150, 255, 183, 77) : Color.argb(90, 79, 195, 247));
                c.drawLine(cx + spk[i][0] * W, top + spk[i][1] * H, hx, hy, p);
            }
        }
        p.setStyle(Paint.Style.FILL);
        for (int i = 0; i < spk.length; i++) {
            boolean delayed = i < 3 ? leftDelayed : rightDelayed;
            float sx = cx + spk[i][0] * W, sy = top + spk[i][1] * H;
            p.setColor(delayed ? Ui.SECONDARY : Ui.PRIMARY);
            c.drawCircle(sx, sy, spk[i][2] * W, p);
            p.setColor(Ui.SURFACE_HI);
            c.drawCircle(sx, sy, spk[i][2] * W * 0.45f, p);
        }
        // listener (head, with a soft halo)
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
            // outside the door speakers (their outer edge is 0.55 W from the centre), with a gap, clear of LEFT/RIGHT
            float edge = 0.55f * W + 12 * d, tw = t.measureText(s);
            t.setTextAlign(pos < 0 ? Paint.Align.RIGHT : Paint.Align.LEFT);
            float sx = pos < 0 ? Math.max(leftW + 12 * d + tw, cx - edge) : Math.min(w - rightW - 12 * d - tw, cx + edge);
            c.drawText(s, sx, rowY, t);
            t.setTextAlign(Paint.Align.CENTER);
            t.setFakeBoldText(false);
        }

        // the cut-off rear fades into the card over the last 36 dp
        int fh = Math.round(36 * d);
        if (fh != fadeH) {
            fadeH = fh;
            fade.setShader(new LinearGradient(0, 0, 0, fh, Color.argb(0, Color.red(Ui.SURFACE), Color.green(Ui.SURFACE),
                    Color.blue(Ui.SURFACE)), Ui.SURFACE, Shader.TileMode.CLAMP));
        }
        c.save();
        c.translate(0, h - fh);
        c.drawRect(0, 0, w, fh, fade);
        c.restore();
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

    private void box(Canvas c, float x0, float y0, float x1, float y1, float rad) {
        r.set(cx + x0 * W, top + y0 * H, cx + x1 * W, top + y1 * H);
        c.drawRoundRect(r, rad * W, rad * W, p);
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        int a = e.getActionMasked();
        if (a == MotionEvent.ACTION_DOWN) {
            getParent().requestDisallowInterceptTouchEvent(true);
            // a touch on the windshield (above the dashboard) sets the width; anywhere else, the position
            widthDrag = W > 0 && e.getY() < top + 0.29f * H;
            downX = e.getX();
            downWidth = width;
        }
        if (a == MotionEvent.ACTION_DOWN || a == MotionEvent.ACTION_MOVE || a == MotionEvent.ACTION_UP) {
            if (W <= 0) return true;
            boolean done = a == MotionEvent.ACTION_UP;
            if (widthDrag) {
                // relative to where the finger went down, so a tap changes nothing: moving away from the
                // centre line widens, toward it narrows (grabbing an end of the line moves that end)
                float span = downWidth / 100f * TW * W + Math.abs(e.getX() - cx) - Math.abs(downX - cx);
                int v = Math.round(span / (TW * W) * 100f / EqSettings.WIDTH_STEP) * EqSettings.WIDTH_STEP;
                v = Math.max(EqSettings.WIDTH_MIN, Math.min(EqSettings.WIDTH_MAX, v));
                if (v != width || done) {
                    width = v;
                    invalidate();
                    if (listener != null) listener.onStereoWidth(v, done);
                }
                return true;
            }
            int v = Math.round((e.getX() - cx) / (0.22f * W) * 100f / 5f) * 5;
            v = Math.max(-100, Math.min(100, v));
            if (v != pos || done) {
                pos = v;
                invalidate();
                if (listener != null) listener.onPosition(v, done);
            }
        }
        return true;
    }
}
