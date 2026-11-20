package com.eqengine.app;

import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.media.audiofx.AudioEffect;

import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * act.sh's helper for the 48 kHz output, run as root from this app's package with app_process (it
 * is not part of the app's screens):
 *
 *   CLASSPATH=&lt;apk&gt; app_process /system/bin com.eqengine.app.Hold &lt;dir&gt; &lt;seconds&gt; [wake] &lt;session&gt;...
 *
 * Android 4.4's mixer frees an output's mix buffer and allocates a new one each time the output
 * changes rate (PlaybackThread::readOutputParameters). A track keeps a pointer to the old buffer
 * unless its audio session has an effect chain: chains are moved to the new buffer, and their
 * tracks with them. Any other track then goes on being mixed into freed memory: it is silent, and
 * the audio server's memory is overwritten. 0.6.2's first start after the install showed exactly
 * that (track main buffer B801AAE0, output mix buffer 0xb8034c88).
 *
 * This puts a disabled EQ Engine filter on each session given. Each of those sessions then has a
 * chain of its own, so its tracks are moved along when the rate changes. When the filter is
 * released, Android points the session's tracks at the output's mix buffer as it is then. A
 * disabled filter passes the sound through unchanged: Android adds its input to the output itself
 * and never calls the filter.
 *
 * With "wake" it also plays silence as music (a track of its own, held like the others), so the
 * main output's stream is active during the change. Hyundai's driver applies sampling_rate only to
 * an active stream; sent while the stream is in standby, Android takes the new rate and the driver
 * starts the link at the old one later (0.6.3 on the car: 7 s of slow music).
 *
 * Writes &lt;dir&gt;/state: "held &lt;n&gt; &lt;sessions&gt;[ silent &lt;session&gt;]" or "failed &lt;why&gt;". Keeps
 * the filters (and the silence) until &lt;dir&gt;/release exists or &lt;seconds&gt; have passed,
 * stops the silence, releases the filters, and writes "released &lt;n&gt;". If this process is
 * killed instead, Android stops the track and releases the filters itself.
 */
public final class Hold {
    private static final UUID TYPE = UUID.fromString("1de0ea4c-d55d-460b-a1e5-4a8c2e95c191");
    private static final UUID IMPL = UUID.fromString("64b3439e-9662-4040-9fd1-83f116f74988");
    private static final int SILENCE_RATE = 44100;

    private static volatile boolean quiet;

    private Hold() {
    }

    public static void main(String[] args) {
        if (args.length < 3) {
            System.err.println("usage: Hold <dir> <seconds> [wake] <session>...");
            System.exit(2);
        }
        File dir = new File(args[0]);
        long seconds = Math.max(5, Math.min(300, parse(args[1], 60)));
        boolean wake = "wake".equals(args[2]);
        List<Integer> sessions = new ArrayList<Integer>();
        String failed = null;
        for (int i = wake ? 3 : 2; i < args.length; i++) {
            int session = (int) parse(args[i], -1);
            if (session <= 0) {
                failed = "not an audio session: " + args[i];
                break;
            }
            sessions.add(session);
        }
        if (failed == null && sessions.isEmpty() && !wake) failed = "no audio session given";
        AudioTrack silence = null;
        Thread writer = null;
        int silent = 0;
        if (failed == null && wake) {
            try {
                int min = AudioTrack.getMinBufferSize(SILENCE_RATE, AudioFormat.CHANNEL_OUT_STEREO,
                        AudioFormat.ENCODING_PCM_16BIT);
                silence = new AudioTrack(AudioManager.STREAM_MUSIC, SILENCE_RATE, AudioFormat.CHANNEL_OUT_STEREO,
                        AudioFormat.ENCODING_PCM_16BIT, Math.max(min, 8192) * 2, AudioTrack.MODE_STREAM);
                if (silence.getState() != AudioTrack.STATE_INITIALIZED) {
                    failed = "the silent track could not be set up";
                } else {
                    silent = silence.getAudioSessionId();
                    sessions.add(silent);
                }
            } catch (Throwable t) {
                failed = "the silent track: " + t;
            }
        }
        List<AudioEffect> held = new ArrayList<AudioEffect>();
        StringBuilder ids = new StringBuilder();
        if (failed == null) {
            try {
                Constructor<AudioEffect> ctor =
                        AudioEffect.class.getConstructor(UUID.class, UUID.class, int.class, int.class);
                for (int session : sessions) {
                    try {
                        // priority 0, disabled: never set enabled
                        held.add(ctor.newInstance(TYPE, IMPL, 0, session));
                        if (session != silent) ids.append(' ').append(session);
                    } catch (InvocationTargetException e) {
                        failed = "session " + session + ": " + e.getCause();
                        break;
                    }
                }
            } catch (Throwable t) {
                failed = "the AudioEffect API: " + t;
            }
        }
        if (failed == null && silence != null) {
            try {
                final AudioTrack track = silence;
                track.play();
                writer = new Thread(new Runnable() {
                    public void run() {
                        short[] zeros = new short[4096];
                        while (!quiet) {
                            if (track.write(zeros, 0, zeros.length) < 0) break;
                        }
                    }
                }, "silence");
                writer.start();
            } catch (Throwable t) {
                failed = "the silent track: " + t;
            }
        }
        if (failed != null) {
            stop(silence, writer);
            release(held);
            write(dir, "failed " + failed.replace('\n', ' '));
            System.exit(1);
        }
        int others = held.size() - (silent != 0 ? 1 : 0);
        write(dir, "held " + others + ids + (silent != 0 ? " silent " + silent : ""));
        File release = new File(dir, "release");
        long end = System.nanoTime() + seconds * 1000000000L;
        while (!release.exists() && System.nanoTime() < end) {
            try {
                Thread.sleep(50);
            } catch (InterruptedException e) {
                break;
            }
        }
        // the silence ends first, then the filters go: each session's tracks are pointed at the
        // output's mix buffer as it is now
        stop(silence, writer);
        int n = release(held);
        write(dir, "released " + n);
        System.exit(0);
    }

    private static void stop(AudioTrack track, Thread writer) {
        quiet = true;
        if (track == null) return;
        try {
            track.stop();
        } catch (Throwable ignored) {
        }
        if (writer != null) {
            try {
                writer.join(1000);
            } catch (InterruptedException ignored) {
            }
        }
        try {
            track.release();
        } catch (Throwable ignored) {
        }
    }

    private static int release(List<AudioEffect> held) {
        int n = 0;
        for (AudioEffect fx : held) {
            try {
                fx.release();
                n++;
            } catch (Throwable ignored) {
            }
        }
        held.clear();
        return n;
    }

    private static long parse(String s, long dflt) {
        try {
            return Long.parseLong(s);
        } catch (NumberFormatException e) {
            return dflt;
        }
    }

    /** One line in dir/state, replaced in one step (written beside it, then renamed). */
    private static void write(File dir, String line) {
        System.out.println(line);
        File tmp = new File(dir, "state.tmp");
        try {
            FileOutputStream out = new FileOutputStream(tmp);
            try {
                out.write((line + "\n").getBytes("UTF-8"));
            } finally {
                out.close();
            }
            if (!tmp.renameTo(new File(dir, "state"))) System.err.println("could not write " + dir + "/state");
        } catch (Exception e) {
            System.err.println("could not write " + dir + "/state: " + e);
        }
    }
}
