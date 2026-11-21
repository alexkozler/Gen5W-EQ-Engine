package com.eqengine.app;

import java.io.File;
import java.io.FileOutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.LinkedList;
import java.util.Locale;

/**
 * A small log: logcat (tag EQEngineApp), a file in the app's own folder, and the last lines for
 * the screen. Normal level keeps events, warnings and errors; detailed level (Status > Diagnostics
 * > Detailed logging) adds every slider release, root command and 30 s audio summaries.
 * The file is written on the background thread (Bg) and rolls over at 256 KB while it runs,
 * keeping one old copy, so it never takes more than about 512 KB.
 */
final class EqLog {
    static final String TAG = "EQEngineApp";
    private static final int TAIL_LINES = 60;
    private static final long MAX_BYTES = 256 * 1024;
    static volatile boolean detailed;
    private static final LinkedList<String> tail = new LinkedList<String>();
    private static final SimpleDateFormat FMT = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US);
    private static File file;
    private static int version;
    /** size of the file; touched on the background thread only */
    private static long fileBytes = -1;

    private EqLog() {}

    static synchronized void init(File dir) {
        if (file != null) return;
        file = new File(dir, "eqengine.log");
    }

    static synchronized File file() {
        return file;
    }

    /** Changes with every line, so the screen redraws the log only when there is something new. */
    static synchronized int version() {
        return version;
    }

    static void i(String msg) {
        line("I", msg);
    }

    /** Only kept with detailed logging on. */
    static void d(String msg) {
        if (detailed) line("D", msg);
    }

    static void w(String msg) {
        line("W", msg);
    }

    static void e(String msg, Throwable t) {
        StringWriter sw = new StringWriter();
        if (t != null) t.printStackTrace(new PrintWriter(sw));
        line("E", t == null ? msg : msg + "\n" + sw.toString().trim());
    }

    static synchronized String tailText() {
        StringBuilder sb = new StringBuilder();
        for (int i = tail.size() - 1; i >= 0; i--) sb.append(tail.get(i)).append('\n');
        return sb.toString();
    }

    /** Waits until the lines logged so far are in the file (before copying it, or in the crash handler). */
    static void flush(long timeoutMs) {
        Bg.flush(timeoutMs);
    }

    private static void line(String level, String msg) {
        final String s;
        final File f;
        synchronized (EqLog.class) {
            s = FMT.format(new Date()) + " " + level + " " + msg;
            tail.add(s.length() > 600 ? s.substring(0, 600) + " ..." : s);
            while (tail.size() > TAIL_LINES) tail.removeFirst();
            version++;
            f = file;
        }
        if ("E".equals(level)) android.util.Log.e(TAG, msg);
        else if ("W".equals(level)) android.util.Log.w(TAG, msg);
        else if ("D".equals(level)) android.util.Log.d(TAG, msg);
        else android.util.Log.i(TAG, msg);
        if (f == null) return;
        Bg.run(new Runnable() {
            public void run() {
                append(f, s + "\n");
            }
        });
    }

    /** On the background thread only. */
    private static void append(File f, String text) {
        FileOutputStream out = null;
        try {
            if (fileBytes < 0) fileBytes = f.length();
            if (fileBytes > MAX_BYTES) {
                File old = new File(f.getParentFile(), "eqengine.old.log");
                old.delete();
                f.renameTo(old);
                fileBytes = 0;
            }
            byte[] b = text.getBytes("UTF-8");
            out = new FileOutputStream(f, true);
            out.write(b);
            fileBytes += b.length;
        } catch (Throwable ignored) {
            // logging must never take the app down
        } finally {
            Root.close(out);
        }
    }
}
