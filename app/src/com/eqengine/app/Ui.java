package com.eqengine.app;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.StateListDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * A small Material-style (dark) look for Android 4.4, which has no Material widgets: colours,
 * rounded shapes and text styles, plus factories for cards, buttons, chips and switch rows.
 */
final class Ui {
    // colours (Material 3 dark on black, cyan accent close to the car's own UI, amber second accent)
    static final int BG = Color.BLACK;
    static final int RAIL = Color.rgb(13, 16, 20);
    static final int SURFACE = Color.rgb(24, 29, 36);
    static final int SURFACE_HI = Color.rgb(33, 39, 48);
    static final int SURFACE_TOP = Color.rgb(43, 50, 61);
    static final int OUTLINE = Color.rgb(52, 61, 73);
    static final int PRIMARY = Color.rgb(79, 195, 247);
    static final int ON_PRIMARY = Color.rgb(0, 42, 60);
    static final int PRIMARY_CONTAINER = Color.rgb(13, 61, 84);
    static final int ON_PRIMARY_CONTAINER = Color.rgb(196, 236, 255);
    static final int ON_SURFACE = Color.rgb(230, 234, 240);
    static final int ON_SURFACE_VAR = Color.rgb(156, 166, 178);
    // second accent (amber): things that show rather than control: the EQ curve, the listener
    // position, recording in progress, user presets
    static final int SECONDARY = Color.rgb(255, 183, 77);
    static final int SECONDARY_CONTAINER = Color.rgb(78, 52, 10);
    static final int ON_SECONDARY_CONTAINER = Color.rgb(255, 222, 176);
    static final int CURVE = SECONDARY;
    static final int OK = Color.rgb(108, 214, 140);
    static final int WARN = Color.rgb(255, 203, 107);
    static final int ERROR = Color.rgb(255, 138, 128);

    private Ui() {}

    static float density(Context c) {
        return c.getResources().getDisplayMetrics().density;
    }

    static int dp(Context c, float v) {
        return (int) (v * density(c) + 0.5f);
    }

    static GradientDrawable round(int color, float radiusPx) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(color);
        g.setCornerRadius(radiusPx);
        return g;
    }

    static GradientDrawable outlined(int fill, int stroke, int strokePx, float radiusPx) {
        GradientDrawable g = round(fill, radiusPx);
        g.setStroke(strokePx, stroke);
        return g;
    }

    /** normal / pressed / selected (or checked) / disabled backgrounds */
    static Drawable states(Drawable normal, Drawable pressed, Drawable selected, Drawable disabled) {
        StateListDrawable s = new StateListDrawable();
        if (disabled != null) s.addState(new int[] {-android.R.attr.state_enabled}, disabled);
        s.addState(new int[] {android.R.attr.state_pressed}, pressed);
        if (selected != null) s.addState(new int[] {android.R.attr.state_selected}, selected);
        s.addState(new int[] {}, normal);
        return s;
    }

    static TextView text(Context c, String s, float sp, int color, boolean bold) {
        TextView t = new TextView(c);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        t.setTypeface(bold ? Typeface.DEFAULT_BOLD : Typeface.DEFAULT);
        t.setIncludeFontPadding(false);
        return t;
    }

    static final int FILLED = 0, TONAL = 1, OUTLINED = 2, TEXT = 3;

    /** A Material-style button (a TextView with a rounded background). */
    static TextView button(Context c, String label, int style, View.OnClickListener l) {
        TextView b = text(c, label, 18, Ui.ON_SURFACE, true);
        float r = dp(c, 20);
        int sw = dp(c, 1.5f);
        Drawable n, p, d;
        switch (style) {
        case FILLED:
            n = round(PRIMARY, r);
            p = round(Color.rgb(130, 214, 250), r);
            d = round(SURFACE_TOP, r);
            b.setTextColor(ON_PRIMARY);
            break;
        case TONAL:
            n = round(PRIMARY_CONTAINER, r);
            p = round(Color.rgb(22, 86, 116), r);
            d = round(SURFACE_HI, r);
            b.setTextColor(ON_PRIMARY_CONTAINER);
            break;
        case OUTLINED:
            n = outlined(Color.TRANSPARENT, OUTLINE, sw, r);
            p = outlined(SURFACE_HI, OUTLINE, sw, r);
            d = outlined(Color.TRANSPARENT, SURFACE_HI, sw, r);
            b.setTextColor(PRIMARY);
            break;
        default:
            n = round(Color.TRANSPARENT, r);
            p = round(SURFACE_HI, r);
            d = round(Color.TRANSPARENT, r);
            b.setTextColor(PRIMARY);
            break;
        }
        b.setBackground(states(n, p, null, d));
        b.setGravity(Gravity.CENTER);
        b.setPadding(dp(c, 20), 0, dp(c, 20), 0);
        b.setMinHeight(dp(c, 46));
        b.setClickable(true);
        b.setOnClickListener(l);
        return b;
    }

    /** A filter-chip: outlined, or filled with the tonal colour when selected (setSelected). */
    static TextView chip(Context c, String label, View.OnClickListener l) {
        return chip(c, label, l, false);
    }

    /** secondary = selected in the second accent (used for the User presets). */
    static TextView chip(Context c, String label, View.OnClickListener l, boolean secondary) {
        TextView t = text(c, label, 17, ON_SURFACE, false);
        float r = dp(c, 10);
        int sw = dp(c, 1);
        t.setTag(secondary ? "secondary" : null);
        t.setBackground(states(outlined(Color.TRANSPARENT, OUTLINE, sw, r), outlined(SURFACE_HI, OUTLINE, sw, r),
                round(secondary ? SECONDARY_CONTAINER : PRIMARY_CONTAINER, r), null));
        t.setGravity(Gravity.CENTER);
        t.setPadding(dp(c, 16), 0, dp(c, 16), 0);
        t.setMinHeight(dp(c, 42));
        t.setClickable(true);
        t.setOnClickListener(l);
        return t;
    }

    static void chipSelected(TextView chip, boolean sel) {
        chip.setSelected(sel);
        boolean secondary = "secondary".equals(chip.getTag());
        chip.setTextColor(sel ? (secondary ? ON_SECONDARY_CONTAINER : ON_PRIMARY_CONTAINER) : ON_SURFACE);
        chip.setTypeface(sel ? Typeface.DEFAULT_BOLD : Typeface.DEFAULT);
    }

    /** A card: rounded surface with an optional title. Children go into the returned layout. */
    static LinearLayout card(Context c, String title) {
        LinearLayout l = new LinearLayout(c);
        l.setOrientation(LinearLayout.VERTICAL);
        l.setBackground(round(SURFACE, dp(c, 16)));
        l.setPadding(dp(c, 18), dp(c, 14), dp(c, 18), dp(c, 12));
        if (title != null) {
            TextView t = text(c, title, 19, ON_SURFACE, true);
            t.setPadding(0, 0, 0, dp(c, 8));
            l.addView(t);
        }
        return l;
    }

    /** Title + subtitle on the left, an MSwitch on the right; tapping the row toggles. */
    static LinearLayout switchRow(Context c, String title, String sub, MSwitch sw) {
        LinearLayout row = new LinearLayout(c);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setMinimumHeight(dp(c, 62));
        row.setPadding(0, dp(c, 4), 0, dp(c, 4));
        LinearLayout texts = new LinearLayout(c);
        texts.setOrientation(LinearLayout.VERTICAL);
        TextView t = text(c, title, 18, ON_SURFACE, false);
        texts.addView(t);
        if (sub != null) {
            TextView s = text(c, sub, 15, ON_SURFACE_VAR, false);
            s.setPadding(0, dp(c, 4), dp(c, 12), 0);
            texts.addView(s);
        }
        row.addView(texts, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        row.addView(sw, new LinearLayout.LayoutParams(dp(c, 56), dp(c, 36)));
        row.setBackground(states(round(Color.TRANSPARENT, dp(c, 10)), round(SURFACE_HI, dp(c, 10)), null, null));
        row.setClickable(true);
        final MSwitch fsw = sw;
        row.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                fsw.performClick();
            }
        });
        return row;
    }

    /** Title + subtitle on the left, a button on the right. */
    static LinearLayout actionRow(Context c, String title, String sub, View button) {
        LinearLayout row = new LinearLayout(c);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setMinimumHeight(dp(c, 56));
        // room between rows whose text wraps to several lines
        row.setPadding(0, dp(c, 6), 0, dp(c, 6));
        LinearLayout texts = new LinearLayout(c);
        texts.setOrientation(LinearLayout.VERTICAL);
        texts.addView(text(c, title, 18, ON_SURFACE, false));
        if (sub != null) {
            TextView s = text(c, sub, 15, ON_SURFACE_VAR, false);
            s.setPadding(0, dp(c, 4), dp(c, 12), 0);
            texts.addView(s);
        }
        row.addView(texts, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        row.addView(button, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(c, 46)));
        return row;
    }

    static View divider(Context c) {
        View v = new View(c);
        v.setBackgroundColor(OUTLINE);
        v.setLayoutParams(new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, Math.max(1, dp(c, 1))));
        return v;
    }
}
