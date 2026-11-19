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
 * A small log: logcat (tag EQEngineApp), a file in the app's own folder (256 KB, one old copy),
 * and the last lines for the screen. Normal level keeps events, warnings and errors; detailed
 * level (Settings > Detailed logging) adds every slider move, root command and 30 s audio summaries.
 */
final class EqLog {
    static final String TAG = "EQEngineApp";
    private static final int TAIL_LINES = 60;
    private static final long MAX_BYTES = 256 * 1024;
    static volatile boolean detailed;
    private static final LinkedList<String> tail = new LinkedList<String>();
    private static final SimpleDateFormat FMT = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US);
    private static File file;

    private EqLog() {}

    static synchronized void init(File dir) {
        if (file != null) return;
        file = new File(dir, "eqengine.log");
        if (file.length() > MAX_BYTES) {
            File old = new File(dir, "eqengine.old.log");
            old.delete();
            file.renameTo(old);
        }
    }

    static synchronized File file() {
        return file;
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

    private static synchronized void line(String level, String msg) {
        String s = FMT.format(new Date()) + " " + level + " " + msg;
        if ("E".equals(level)) android.util.Log.e(TAG, msg);
        else if ("W".equals(level)) android.util.Log.w(TAG, msg);
        else if ("D".equals(level)) android.util.Log.d(TAG, msg);
        else android.util.Log.i(TAG, msg);
        tail.add(s.length() > 600 ? s.substring(0, 600) + " ..." : s);
        while (tail.size() > TAIL_LINES) tail.removeFirst();
        if (file == null) return;
        FileOutputStream out = null;
        try {
            out = new FileOutputStream(file, true);
            out.write((s + "\n").getBytes("UTF-8"));
        } catch (Throwable ignored) {
            // logging must never take the app down
        } finally {
            if (out != null) {
                try {
                    out.close();
                } catch (Throwable ignored) {
                }
            }
        }
    }
}
