package com.eqengine.app;

/**
 * Expert bands' filters, for drawing their curves on the screen while a band moves: the same
 * formulas as eqengine.c (bell_bw, shelf with S = 1, lowcut), at the output's rate. The sound
 * comes from the filter itself; this only draws it.
 */
final class XDesign {
    private XDesign() {}

    /** {b0, b1, b2, a1, a2}, or null for no filter (0 dB, or past 0.45 x rate). */
    static double[] coefs(int[] b, double rate) {
        double f0 = b[1] / 100.0, g = b[2] / 100.0;
        if (rate <= 0 || f0 >= 0.45 * rate) return null;
        double w0 = 2 * Math.PI * f0 / rate, cw = Math.cos(w0), sw = Math.sin(w0);
        switch (b[0]) {
        case EqSettings.X_PEAK: {
            if (g == 0) return null;
            double A = Math.pow(10, g / 40), bw = b[3] / 1000.0;
            double alpha = sw * Math.sinh(0.5 * Math.log(2) * bw * w0 / sw);
            double a0 = 1 + alpha / A;
            return new double[] {(1 + alpha * A) / a0, -2 * cw / a0, (1 - alpha * A) / a0, -2 * cw / a0, (1 - alpha / A) / a0};
        }
        case EqSettings.X_LOW_SHELF:
        case EqSettings.X_HIGH_SHELF: {
            if (g == 0) return null;
            double A = Math.pow(10, g / 40), alpha = sw / 2 * Math.sqrt(2), sa = 2 * Math.sqrt(A) * alpha;
            double b0, b1, b2, a0, a1, a2;
            if (b[0] == EqSettings.X_LOW_SHELF) {
                b0 = A * ((A + 1) - (A - 1) * cw + sa);
                b1 = 2 * A * ((A - 1) - (A + 1) * cw);
                b2 = A * ((A + 1) - (A - 1) * cw - sa);
                a0 = (A + 1) + (A - 1) * cw + sa;
                a1 = -2 * ((A - 1) + (A + 1) * cw);
                a2 = (A + 1) + (A - 1) * cw - sa;
            } else {
                b0 = A * ((A + 1) + (A - 1) * cw + sa);
                b1 = -2 * A * ((A - 1) + (A + 1) * cw);
                b2 = A * ((A + 1) + (A - 1) * cw - sa);
                a0 = (A + 1) - (A - 1) * cw + sa;
                a1 = 2 * ((A - 1) - (A + 1) * cw);
                a2 = (A + 1) - (A - 1) * cw - sa;
            }
            return new double[] {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
        }
        case EqSettings.X_LOW_CUT: {
            double q = b[3] / 1000.0;
            if (q <= 0) return null;
            double alpha = sw / (2 * q), a0 = 1 + alpha;
            return new double[] {(1 + cw) / 2 / a0, -(1 + cw) / a0, (1 + cw) / 2 / a0, -2 * cw / a0, (1 - alpha) / a0};
        }
        default:
            return null;
        }
    }

    /** The filter's level at f in dB (0 for none). */
    static double db(double[] k, double f, double rate) {
        if (k == null) return 0;
        double w = 2 * Math.PI * f / rate;
        double c1 = Math.cos(w), s1 = Math.sin(w), c2 = Math.cos(2 * w), s2 = Math.sin(2 * w);
        double nr = k[0] + k[1] * c1 + k[2] * c2, ni = -(k[1] * s1 + k[2] * s2);
        double dr = 1 + k[3] * c1 + k[4] * c2, di = -(k[3] * s1 + k[4] * s2);
        double num = nr * nr + ni * ni, den = dr * dr + di * di;
        if (num <= 0 || den <= 0) return -200;
        return 10 * Math.log10(num / den);
    }

    /** The Q that a bandwidth in octaves corresponds to (the usual analog relation). */
    static double q(double bwOct) {
        double p = Math.pow(2, bwOct);
        return Math.sqrt(p) / (p - 1);
    }
}
