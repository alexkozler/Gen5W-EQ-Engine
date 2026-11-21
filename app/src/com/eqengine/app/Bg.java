package com.eqengine.app;

import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.Process;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * One background thread for file work: settings saves (each one is synced to storage, which can
 * take tens of milliseconds on this unit), log appends and the screen's status reads. The screen's
 * own thread then only draws and talks to the filter. Jobs run one at a time, in the order they
 * were posted, so a read posted after a save sees that save.
 */
final class Bg {
    private static Handler io;
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    private Bg() {}

    private static synchronized Handler io() {
        if (io == null) {
            HandlerThread t = new HandlerThread("eqengine-io", Process.THREAD_PRIORITY_BACKGROUND);
            t.start();
            io = new Handler(t.getLooper());
        }
        return io;
    }

    /** Runs r on the background thread. */
    static void run(Runnable r) {
        io().post(r);
    }

    /** Runs r on the screen's (main) thread. */
    static void main(Runnable r) {
        MAIN.post(r);
    }

    /** Waits (at most timeoutMs) until everything posted so far has run; for the crash handler and log saves. */
    static void flush(long timeoutMs) {
        final CountDownLatch done = new CountDownLatch(1);
        io().post(new Runnable() {
            public void run() {
                done.countDown();
            }
        });
        try {
            done.await(timeoutMs, TimeUnit.MILLISECONDS);
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
    }
}
