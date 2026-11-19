package com.eqengine.app;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.util.HashMap;
import java.util.Map;

/** What the NEMESIS boot step reported (/data/eqengine/state/status). */
final class BootStatus {
    static final String STATE_DIR = "/data/eqengine/state";

    final Map<String, String> v;

    private BootStatus(Map<String, String> v) {
        this.v = v;
    }

    static BootStatus read() {
        Map<String, String> m = new HashMap<String, String>();
        BufferedReader r = null;
        try {
            r = new BufferedReader(new FileReader(STATE_DIR + "/status"));
            String line;
            while ((line = r.readLine()) != null) {
                int eq = line.indexOf('=');
                if (eq > 0) m.put(line.substring(0, eq), line.substring(eq + 1));
            }
        } catch (Throwable ignored) {
            // no status yet
        } finally {
            Root.close(r);
        }
        return new BootStatus(m);
    }

    String get(String k) {
        String s = v.get(k);
        return s == null ? "" : s;
    }

    String state() {
        return get("state");
    }

    boolean disabledFlag() {
        return new File(STATE_DIR + "/disabled").exists();
    }

    /** The EQ may be attached: the effects list overlay is in place and nothing turned it off. */
    boolean allowed() {
        return "applied".equals(state()) && "1".equals(get("overlay")) && !disabledFlag();
    }

    /** A state the boot step will not leave by itself during this start. */
    boolean finalOff() {
        String s = state();
        return s.equals("off") || s.equals("crashed") || s.equals("refused") || s.equals("error") || disabledFlag();
    }
}
