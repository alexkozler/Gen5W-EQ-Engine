package com.eqengine.app;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.View;

/** A Material 3 style switch (Android 4.4's own Switch is the old Holo one). */
final class MSwitch extends View {
    interface Listener {
        void onSwitch(MSwitch s, boolean on);
    }

    private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF r = new RectF();
    private boolean on;
    private float pos; // 0 = off, 1 = on (animated)
    private Listener listener;
    private ValueAnimator anim;

    MSwitch(Context c) {
        super(c);
        setClickable(true);
        setOnClickListener(new OnClickListener() {
            public void onClick(View v) {
                if (!isEnabled()) return;
                setOn(!on, true);
                if (listener != null) listener.onSwitch(MSwitch.this, on);
            }
        });
    }

    void setListener(Listener l) {
        listener = l;
    }

    boolean isOn() {
        return on;
    }

    /** Sets the state without calling the listener. */
    void setOn(boolean v, boolean animate) {
        if (v == on && (anim == null || !anim.isRunning()) && pos == (v ? 1f : 0f)) return;
        if (anim != null) anim.cancel();
        on = v;
        float target = v ? 1f : 0f;
        if (!animate || getWindowToken() == null) {
            pos = target;
            invalidate();
            return;
        }
        anim = ValueAnimator.ofFloat(pos, target);
        anim.setDuration(160);
        anim.addUpdateListener(new ValueAnimator.AnimatorUpdateListener() {
            public void onAnimationUpdate(ValueAnimator a) {
                pos = (Float) a.getAnimatedValue();
                invalidate();
            }
        });
        anim.start();
    }

    @Override
    public void setEnabled(boolean enabled) {
        super.setEnabled(enabled);
        invalidate();
    }

    @Override
    protected void onDraw(Canvas c) {
        float d = getResources().getDisplayMetrics().density;
        float w = 52 * d, h = 32 * d;
        float left = (getWidth() - w) / 2f, top = (getHeight() - h) / 2f;
        boolean en = isEnabled();
        // track
        r.set(left, top, left + w, top + h);
        if (pos > 0.5f) {
            p.setStyle(Paint.Style.FILL);
            p.setColor(en ? Ui.PRIMARY : Ui.SURFACE_TOP);
            c.drawRoundRect(r, h / 2, h / 2, p);
        } else {
            p.setStyle(Paint.Style.FILL);
            p.setColor(Ui.SURFACE_HI);
            c.drawRoundRect(r, h / 2, h / 2, p);
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(2 * d);
            p.setColor(en ? Ui.ON_SURFACE_VAR : Ui.OUTLINE);
            r.inset(d, d);
            c.drawRoundRect(r, h / 2 - d, h / 2 - d, p);
        }
        // thumb: 16 dp off, 24 dp on
        float rad = (8 + 4 * pos) * d;
        float cx = left + h / 2 + pos * (w - h);
        float cy = top + h / 2;
        p.setStyle(Paint.Style.FILL);
        p.setColor(pos > 0.5f ? (en ? Ui.ON_PRIMARY : Ui.ON_SURFACE_VAR) : (en ? Ui.ON_SURFACE_VAR : Ui.OUTLINE));
        c.drawCircle(cx, cy, rad, p);
    }
}
