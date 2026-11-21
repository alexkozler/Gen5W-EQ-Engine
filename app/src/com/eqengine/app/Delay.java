package com.eqengine.app;

/**
 * Lines the live view and the meter up with what is heard. The filter reports each buffer when it
 * processes it; the speakers play it about one hardware buffer later (about 0.15 s on the test
 * car). This keeps the last readings with the time each was processed and hands back the one
 * that is playing now.
 */
final class Delay {
    private static final int N = 32;
    private final long[] at = new long[N];
    private final int[][] val = new int[N][];
    private int head, count;
    private int lastSeq = Integer.MIN_VALUE;

    /** A reading: seq (the filter's counter), processedAt (uptime ms), the values. Repeats are ignored. */
    void add(int seq, long processedAt, int[] v) {
        if (seq == lastSeq) return;
        lastSeq = seq;
        if (count == N) {
            head = (head + 1) % N;
            count--;
        }
        int i = (head + count) % N;
        at[i] = processedAt;
        val[i] = v;
        count++;
    }

    /** The newest reading processed at or before t, or null if there is none within maxAgeMs before t. */
    int[] at(long t, long maxAgeMs) {
        for (int k = count - 1; k >= 0; k--) {
            int i = (head + k) % N;
            if (at[i] <= t) return t - at[i] <= maxAgeMs ? val[i] : null;
        }
        return null;
    }

    void clear() {
        head = count = 0;
        lastSeq = Integer.MIN_VALUE;
    }
}
