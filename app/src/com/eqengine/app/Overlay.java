package com.eqengine.app;

import android.content.Context;
import android.graphics.Color;
import android.os.Handler;
import android.text.InputType;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.LinkedList;

/**
 * Sits above the screen: messages that slide in at the bottom right (one at a time, queued) and
 * a Material-style confirmation dialog for actions that interrupt audio or change EQ Engine.
 */
final class Overlay extends FrameLayout {
    static final int INFO = 0, OK = 1, WARN = 2, ERROR = 3;

    private final Handler h = new Handler();
    private final LinkedList<Object[]> queue = new LinkedList<Object[]>();
    private LinearLayout toast;
    private View dialog;
    private boolean showing;

    Overlay(Context c) {
        super(c);
        setClickable(false);
    }

    private int dp(float v) {
        return Ui.dp(getContext(), v);
    }

    /** Shows a message in the bottom-right corner for a few seconds. */
    void show(String msg, int kind) {
        // the same message again replaces nothing; drop exact repeats waiting in the queue
        for (Object[] q : queue) if (msg.equals(q[0])) return;
        queue.add(new Object[] {msg, kind});
        if (!showing) next();
    }

    private void next() {
        final Object[] m = queue.poll();
        if (m == null) {
            showing = false;
            return;
        }
        showing = true;
        int kind = (Integer) m[1];
        int accent = kind == OK ? Ui.OK : kind == WARN ? Ui.WARN : kind == ERROR ? Ui.ERROR : Ui.PRIMARY;
        final LinearLayout card = new LinearLayout(getContext());
        card.setOrientation(LinearLayout.HORIZONTAL);
        card.setGravity(Gravity.CENTER_VERTICAL);
        card.setBackground(Ui.outlined(Ui.SURFACE_TOP, Ui.OUTLINE, dp(1), dp(12)));
        card.setPadding(dp(14), dp(12), dp(18), dp(12));
        View bar = new View(getContext());
        bar.setBackground(Ui.round(accent, dp(2)));
        card.addView(bar, new LinearLayout.LayoutParams(dp(4), dp(34)));
        TextView t = Ui.text(getContext(), (String) m[0], 18, Ui.ON_SURFACE, false);
        t.setPadding(dp(12), 0, 0, 0);
        t.setMaxLines(4);
        card.addView(t, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
        LayoutParams lp = new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM | Gravity.RIGHT);
        lp.setMargins(dp(140), 0, dp(20), dp(20));
        card.setMinimumWidth(dp(320));
        t.setMaxWidth(dp(600));
        card.setAlpha(0f);
        card.setTranslationY(dp(24));
        card.setClickable(true);
        card.setOnClickListener(new OnClickListener() {
            public void onClick(View v) {
                dismissToast(card);
            }
        });
        addView(card, lp);
        toast = card;
        card.animate().alpha(1f).translationY(0).setDuration(180).start();
        long ms = kind == ERROR ? 8000 : kind == WARN ? 6000 : 4000;
        h.postDelayed(new Runnable() {
            public void run() {
                dismissToast(card);
            }
        }, ms);
    }

    private void dismissToast(final View card) {
        if (toast != card) return;
        toast = null;
        card.animate().alpha(0f).translationY(dp(24)).setDuration(160).withEndAction(new Runnable() {
            public void run() {
                removeView(card);
                next();
            }
        }).start();
    }

    /** A modal confirmation: title, text, Cancel and the action button. */
    void confirm(String title, String body, String action, final Runnable onYes) {
        confirm(title, body, null, null, action, onYes);
    }

    /** With a second, lower-key action (altAction / onAlt) between Cancel and the main one. */
    void confirm(String title, String body, String altAction, final Runnable onAlt, String action, final Runnable onYes) {
        if (dialog != null) removeView(dialog);
        final FrameLayout scrim = new FrameLayout(getContext());
        scrim.setBackgroundColor(Color.argb(150, 0, 0, 0));
        scrim.setClickable(true);
        LinearLayout card = new LinearLayout(getContext());
        card.setOrientation(LinearLayout.VERTICAL);
        card.setBackground(Ui.round(Ui.SURFACE_HI, dp(24)));
        card.setPadding(dp(24), dp(22), dp(16), dp(14));
        card.setClickable(true);
        card.addView(Ui.text(getContext(), title, 24, Ui.ON_SURFACE, true));
        TextView b = Ui.text(getContext(), body, 18, Ui.ON_SURFACE_VAR, false);
        b.setPadding(0, dp(14), dp(8), dp(18));
        b.setLineSpacing(0, 1.15f);
        card.addView(b);
        LinearLayout buttons = new LinearLayout(getContext());
        buttons.setGravity(Gravity.RIGHT);
        buttons.addView(Ui.button(getContext(), "Cancel", Ui.TEXT, new OnClickListener() {
            public void onClick(View v) {
                closeDialog(scrim);
            }
        }));
        View gap = new View(getContext());
        buttons.addView(gap, new LinearLayout.LayoutParams(dp(8), 1));
        if (altAction != null) {
            buttons.addView(Ui.button(getContext(), altAction, Ui.TONAL, new OnClickListener() {
                public void onClick(View v) {
                    closeDialog(scrim);
                    onAlt.run();
                }
            }));
            View gap2 = new View(getContext());
            buttons.addView(gap2, new LinearLayout.LayoutParams(dp(8), 1));
        }
        buttons.addView(Ui.button(getContext(), action, Ui.FILLED, new OnClickListener() {
            public void onClick(View v) {
                closeDialog(scrim);
                onYes.run();
            }
        }));
        card.addView(buttons);
        scrim.addView(card, new LayoutParams(dp(600), LayoutParams.WRAP_CONTENT, Gravity.CENTER));
        scrim.setOnClickListener(new OnClickListener() {
            public void onClick(View v) {
                closeDialog(scrim);
            }
        });
        scrim.setAlpha(0f);
        addView(scrim, new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT));
        dialog = scrim;
        scrim.animate().alpha(1f).setDuration(150).start();
    }

    interface Answer {
        void answer(String text);
    }

    /** A modal question with a number field (Expert's frequency): Cancel and the action button. */
    void prompt(String title, String body, String initial, String action, final Answer onAnswer) {
        if (dialog != null) removeView(dialog);
        final FrameLayout scrim = new FrameLayout(getContext());
        scrim.setBackgroundColor(Color.argb(150, 0, 0, 0));
        scrim.setClickable(true);
        LinearLayout card = new LinearLayout(getContext());
        card.setOrientation(LinearLayout.VERTICAL);
        card.setBackground(Ui.round(Ui.SURFACE_HI, dp(24)));
        card.setPadding(dp(24), dp(22), dp(16), dp(14));
        card.setClickable(true);
        card.addView(Ui.text(getContext(), title, 24, Ui.ON_SURFACE, true));
        if (body != null) {
            TextView b = Ui.text(getContext(), body, 18, Ui.ON_SURFACE_VAR, false);
            b.setPadding(0, dp(12), dp(8), 0);
            card.addView(b);
        }
        final EditText field = new EditText(getContext());
        field.setText(initial);
        field.setSelectAllOnFocus(true);
        field.setSingleLine(true);
        field.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL);
        field.setImeOptions(EditorInfo.IME_ACTION_DONE);
        field.setTextSize(TypedValue.COMPLEX_UNIT_SP, 24);
        field.setTextColor(Ui.ON_SURFACE);
        field.setBackground(Ui.outlined(Ui.SURFACE, Ui.PRIMARY, dp(2), dp(10)));
        field.setPadding(dp(14), dp(10), dp(14), dp(10));
        LinearLayout.LayoutParams fl = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        fl.setMargins(0, dp(16), dp(8), dp(16));
        card.addView(field, fl);
        final Runnable done = new Runnable() {
            public void run() {
                hideKeyboard(field);
                closeDialog(scrim);
                onAnswer.answer(field.getText().toString());
            }
        };
        field.setOnEditorActionListener(new TextView.OnEditorActionListener() {
            public boolean onEditorAction(TextView v, int id, KeyEvent ev) {
                if (id == EditorInfo.IME_ACTION_DONE || (ev != null && ev.getKeyCode() == KeyEvent.KEYCODE_ENTER)) {
                    done.run();
                    return true;
                }
                return false;
            }
        });
        LinearLayout buttons = new LinearLayout(getContext());
        buttons.setGravity(Gravity.RIGHT);
        buttons.addView(Ui.button(getContext(), "Cancel", Ui.TEXT, new OnClickListener() {
            public void onClick(View v) {
                hideKeyboard(field);
                closeDialog(scrim);
            }
        }));
        View gap = new View(getContext());
        buttons.addView(gap, new LinearLayout.LayoutParams(dp(8), 1));
        buttons.addView(Ui.button(getContext(), action, Ui.FILLED, new OnClickListener() {
            public void onClick(View v) {
                done.run();
            }
        }));
        card.addView(buttons);
        scrim.addView(card, new LayoutParams(dp(520), LayoutParams.WRAP_CONTENT, Gravity.CENTER_HORIZONTAL | Gravity.TOP));
        ((LayoutParams) card.getLayoutParams()).topMargin = dp(40);
        addView(scrim, new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT));
        dialog = scrim;
        field.requestFocus();
        field.postDelayed(new Runnable() {
            public void run() {
                InputMethodManager im = (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
                if (im != null) im.showSoftInput(field, InputMethodManager.SHOW_IMPLICIT);
            }
        }, 150);
    }

    private void hideKeyboard(View v) {
        InputMethodManager im = (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (im != null) im.hideSoftInputFromWindow(v.getWindowToken(), 0);
    }

    private void closeDialog(View scrim) {
        if (dialog == scrim) dialog = null;
        removeView(scrim);
    }

    /** Back closes an open dialog first. */
    boolean handleBack() {
        if (dialog == null) return false;
        closeDialog(dialog);
        return true;
    }
}
