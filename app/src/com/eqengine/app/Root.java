package com.eqengine.app;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.List;

/**
 * Root commands through NEMESIS's root channel (/system/xbin/nemesis root -c ..., which any app
 * may use), plus small helpers that read /proc. Call run() off the main thread.
 */
final class Root {
    static final String NEMESIS = "/system/xbin/nemesis";

    private Root() {}

    /** What the screen says when NEMESIS's root channel, or EQ Engine's part on the unit, is not there. */
    static final String CHANNEL_DOWN = "EQ Engine could not reach NEMESIS's root access, or its own files on the unit are "
            + "missing. Install EQ Engine again (or update NEMESIS), then restart the head unit.";

    /** NEMESIS's root channel refuses longer commands (SU_MAX_ARG 768, including the terminator). */
    static final int MAX_COMMAND = 767;

    /** Runs a shell command as root; returns its output with "(exit N)" appended. */
    static String run(String command) {
        if (command.length() > MAX_COMMAND) {
            EqLog.w("root command too long for NEMESIS (" + command.length() + " bytes)");
            return "internal error: command too long for NEMESIS (" + command.length() + " bytes)\n(exit 1)";
        }
        Process p = null;
        try {
            p = new ProcessBuilder(NEMESIS, "root", "-c", command).redirectErrorStream(true).start();
            p.getOutputStream().close();
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) {
                if (sb.length() < 8000) sb.append(line).append('\n');
            }
            int rc = p.waitFor();
            String out = sb.toString();
            // (after 0.7.6) the root channel itself failed: one plain line for the screen (the raw
            // text goes to the log)
            if (rc != 0 && (out.contains("daemon not running") || out.contains("act.sh: not found")
                    || out.contains("act.sh: No such file") || out.contains("can't open /data/eqengine/bin/act.sh"))) {
                EqLog.w("root channel: " + out.trim());
                return CHANNEL_DOWN + "\n(exit " + rc + ")";
            }
            return out + "(exit " + rc + ")";
        } catch (Throwable t) {
            EqLog.w("could not run " + NEMESIS + ": " + t);
            return CHANNEL_DOWN + "\n(exit 1)";
        } finally {
            if (p != null) {
                try {
                    p.destroy();
                } catch (Throwable ignored) {
                }
            }
        }
    }

    /** run() on its own thread, waiting at most timeoutMs (for the crash handler). */
    static void runBlocking(final String command, long timeoutMs) {
        Thread t = new Thread(new Runnable() {
            public void run() {
                try {
                    Root.run(command);
                } catch (Throwable ignored) {
                }
            }
        }, "eqengine-root");
        t.setDaemon(true);
        t.start();
        try {
            t.join(timeoutMs);
        } catch (InterruptedException ignored) {
        }
    }

    /** pid of /system/bin/mediaserver, or -1. /proc/<pid>/cmdline is readable by apps. */
    private static volatile int lastMsPid = -1;

    /** Android's audio server process, or -1. The last answer is checked first (one small read). */
    static int mediaserverPid() {
        int c = lastMsPid;
        if (c > 0 && isMediaserver(new File("/proc/" + c))) return c;
        int p = scanMediaserver();
        lastMsPid = p;
        return p;
    }

    private static boolean isMediaserver(File dir) {
        String cmd = readFirstLine(new File(dir, "cmdline"));
        if (cmd == null) return false;
        int nul = cmd.indexOf('\0');
        if (nul >= 0) cmd = cmd.substring(0, nul);
        return "/system/bin/mediaserver".equals(cmd);
    }

    private static int scanMediaserver() {
        File[] procs = new File("/proc").listFiles();
        if (procs == null) return -1;
        for (File f : procs) {
            String name = f.getName();
            if (name.length() == 0 || name.charAt(0) < '0' || name.charAt(0) > '9') continue;
            String cmd = readFirstLine(new File(f, "cmdline"));
            if (cmd == null) continue;
            int nul = cmd.indexOf('\0');
            if (nul >= 0) cmd = cmd.substring(0, nul);
            if ("/system/bin/mediaserver".equals(cmd)) {
                try {
                    return Integer.parseInt(name);
                } catch (NumberFormatException ignored) {
                }
            }
        }
        return -1;
    }

    static long uptimeSeconds() {
        String s = readFirstLine(new File("/proc/uptime"));
        if (s == null) return 0;
        int dot = s.indexOf('.');
        try {
            return Long.parseLong(dot > 0 ? s.substring(0, dot) : s.trim().split(" ")[0]);
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    /** Mounted USB sticks, raw vold mounts first. */
    static List<String> usbRoots() {
        List<String> media = new ArrayList<String>();
        List<String> storage = new ArrayList<String>();
        BufferedReader r = null;
        try {
            r = new BufferedReader(new FileReader("/proc/mounts"));
            String line;
            while ((line = r.readLine()) != null) {
                String[] f = line.split(" ");
                if (f.length < 2) continue;
                if (f[1].startsWith("/mnt/media_rw/usb") && !media.contains(f[1])) media.add(f[1]);
                else if (f[1].startsWith("/storage/usb") && !storage.contains(f[1])) storage.add(f[1]);
            }
        } catch (Throwable ignored) {
        } finally {
            close(r);
        }
        media.addAll(storage);
        return media;
    }

    static String readFirstLine(File f) {
        BufferedReader r = null;
        try {
            r = new BufferedReader(new FileReader(f));
            return r.readLine();
        } catch (Throwable t) {
            return null;
        } finally {
            close(r);
        }
    }

    /** The last max lines of a small text file (empty if it cannot be read). */
    static List<String> readLines(File f, int max) {
        List<String> out = new ArrayList<String>();
        BufferedReader r = null;
        try {
            r = new BufferedReader(new FileReader(f));
            String l;
            while ((l = r.readLine()) != null) {
                out.add(l);
                if (out.size() > max) out.remove(0);
            }
        } catch (Throwable ignored) {
        } finally {
            close(r);
        }
        return out;
    }

    static void close(java.io.Closeable c) {
        if (c == null) return;
        try {
            c.close();
        } catch (Throwable ignored) {
        }
    }
}
