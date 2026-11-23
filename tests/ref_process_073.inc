/* process_frames as it was in 0.7.3 (one sample at a time through every band), kept as the
 * reference the block version is checked against bit for bit (host_test.c, "bands a block at a
 * time"). Included after eqengine.c. */
/* One buffer. The per-sample work is only what the settings need (0.6.6):
 * - "transparent" (EQ on but flat, preamp 0 dB, no seat delay, the guard idle): the input goes
 *   through the look-ahead delay as in the bit-exact path, which gives exactly the same samples
 *   as the full path would;
 * - only bands that are not at 0 dB are run;
 * - the guard's bookkeeping is skipped while it is idle and the sample needs no limiting;
 * - a channel without seat delay skips the delay line's reads.
 * sp: the live view's buffer while the app shows it, else NULL. */
static void process_frames_ref(eqe_ctx *c, const int16_t *src, int16_t *dst, size_t frames, int accumulate, spec_t *sp) {
    int32_t ipl = c->in_peak_l, ipr = c->in_peak_r, bpk = 0;
    uint64_t iss = 0, oss = 0;
    uint32_t clip = 0;
    band_t *act[EQE_NBAND];
    int nb = 0;
    for (int j = 0; j < EQE_NBAND; j++)
        if (c->band[j].active) act[nb++] = &c->band[j];
    int transparent = c->processing && nb == 0 && c->ramp_left == 0 && c->pre_cur == 1.0 && c->pre_tgt == 1.0 &&
                      c->w == 1.0 && c->w_tgt == 1.0 && c->dcur[0] == 0 && c->dcur[1] == 0 && c->dfade[0] == 0 &&
                      c->dfade[1] == 0 && c->gq_n == 0 && c->box_low == 0 && c->g2 == 1.0;
    for (size_t f = 0; f < frames; f++) {
        int32_t il = src[2 * f], ir = src[2 * f + 1];
        int32_t al = il < 0 ? -il : il, ar = ir < 0 ? -ir : ir;
        if (al > ipl) ipl = al;
        if (ar > ipr) ipr = ar;
        iss += (uint64_t)(il * il) + (uint64_t)(ir * ir);
        if (al >= 32767 || ar >= 32767 || c->rail_sign[0] || c->rail_sign[1])
            clip += rail_count(c, 0, il) + rail_count(c, 1, ir);
        double xl = il * (1.0 / 32768.0), xr = ir * (1.0 / 32768.0);
        int32_t ol, orr;

        if (!c->processing || transparent) {
            /* Bit-exact path: the input, delayed by LA - 1 samples. */
            int w = c->li, rd = (w + 1) & (LA - 1);
            double dl = c->dl[0][rd], dr = c->dl[1][rd];
            c->dl[0][w] = xl;
            c->dl[1][w] = xr;
            c->li = rd;
            ol = (int32_t)(dl * 32768.0);
            orr = (int32_t)(dr * 32768.0);
            if (transparent) {
                /* the seat delay keeps its history, for a later change */
                c->dbuf[0][c->dpos] = xl;
                c->dbuf[1][c->dpos] = xr;
                c->dpos = (c->dpos + 1) & (DMAX - 1);
            } else if (c->w_tgt > 0.0) {
                /* EQ turned on: start the processing path; the crossfade begins at w = 0. */
                c->processing = 1;
            }
        } else {
            /* preamp */
            if (c->pre_cur != c->pre_tgt) {
                c->pre_cur += (c->pre_tgt - c->pre_cur) * c->pre_k;
                if (fabs(c->pre_tgt - c->pre_cur) < 1e-12) c->pre_cur = c->pre_tgt;
            }
            double yl = xl * c->pre_cur, yr = xr * c->pre_cur;
            /* filters */
            for (int n = 0; n < nb; n++) {
                band_t *b = act[n];
                yl = biquad(b, 0, yl);
                yr = biquad(b, 1, yr);
            }
            if (c->ramp_left > 0) {
                for (int n = 0; n < nb; n++) {
                    band_t *b = act[n];
                    b->cur.b0 += b->inc.b0;
                    b->cur.b1 += b->inc.b1;
                    b->cur.b2 += b->inc.b2;
                    b->cur.a1 += b->inc.a1;
                    b->cur.a2 += b->inc.a2;
                }
                if (--c->ramp_left == 0)
                    for (int j = 0; j < EQE_NBAND; j++) c->band[j].cur = c->band[j].tgt;
            }
            /* listening position: per-channel delay, crossfading between taps when it changes */
            {
                int wp = c->dpos;
                c->dbuf[0][wp] = yl;
                c->dbuf[1][wp] = yr;
                for (int ch = 0; ch < 2; ch++) {
                    if (c->dcur[ch] == 0 && c->dfade[ch] == 0) continue; /* tap 0 is the sample itself */
                    double a = c->dbuf[ch][(unsigned)(wp - c->dcur[ch]) & (DMAX - 1)];
                    if (c->dfade[ch] > 0) {
                        double b = c->dbuf[ch][(unsigned)(wp - c->dnew[ch]) & (DMAX - 1)];
                        double t = 1.0 - (double)c->dfade[ch] / DFADE_LEN;
                        a += (b - a) * t;
                        if (--c->dfade[ch] == 0) c->dcur[ch] = c->dnew[ch];
                    }
                    if (ch == 0) yl = a;
                    else yr = a;
                }
                c->dpos = (wp + 1) & (DMAX - 1);
            }
            /* EQ on/off crossfade (the dry signal has no preamp) */
            if (c->w != c->w_tgt) {
                if (c->w < c->w_tgt) { c->w += c->w_step; if (c->w > c->w_tgt) c->w = c->w_tgt; }
                else { c->w -= c->w_step; if (c->w < c->w_tgt) c->w = c->w_tgt; }
            }
            double ml = xl + (yl - xl) * c->w, mr = xr + (yr - xr) * c->w;
            /* clip guard (look-ahead peak limiter) */
            int w = c->li, rd = (w + 1) & (LA - 1);
            double dl = c->dl[0][rd], dr = c->dl[1][rd];
            c->dl[0][w] = ml;
            c->dl[1][w] = mr;
            c->li = rd;
            double pk = fabs(ml) > fabs(mr) ? fabs(ml) : fabs(mr);
            int over = c->set.guard_on && pk > GUARD_THR;
            double gl;
            if (!over && c->gq_n == 0 && c->box_low == 0 && c->g2 == 1.0) {
                /* idle: nothing to limit now or anywhere in the look-ahead */
                gl = 1.0;
            } else {
                double m = guard_min_push(c, over ? GUARD_THR / pk : 1.0);
                if (c->box[w] < 1.0) c->box_low--;
                c->boxsum += m - c->box[w];
                c->box[w] = m;
                if (m < 1.0) c->box_low++;
                double g = c->boxsum * (1.0 / LA);
                if (g > 1.0) g = 1.0;
                if (g < c->g2) c->g2 = g;
                else c->g2 += (g - c->g2) * c->krel;
                if (c->g2 > 1.0 || (g == 1.0 && c->g2 > 1.0 - 1e-9)) c->g2 = 1.0;
                gl = c->g2;
                if (gl < 0.99999) c->limited++;
                if (gl < c->min_gain) c->min_gain = gl;
            }
            ol = quantise(c, dl * gl, c->set.guard_on);
            orr = quantise(c, dr * gl, c->set.guard_on);
            /* Back to the bit-exact path once fully off and settled. */
            if (c->w == 0.0 && c->w_tgt == 0.0 && c->gq_n == 0 && c->g2 >= 0.99999 &&
                c->boxsum >= LA - 1e-9) {
                c->processing = 0;
                c->g2 = 1.0;
                reset_states(c);
            }
        }
        if (accumulate) {
            ol += dst[2 * f];
            orr += dst[2 * f + 1];
            if (ol > 32767) ol = 32767; else if (ol < -32768) ol = -32768;
            if (orr > 32767) orr = 32767; else if (orr < -32768) orr = -32768;
        }
        int32_t aol = ol < 0 ? -ol : ol, aor = orr < 0 ? -orr : orr;
        if (aol > bpk) bpk = aol;
        if (aor > bpk) bpk = aor;
        oss += (uint64_t)(ol * ol) + (uint64_t)(orr * orr);
        dst[2 * f] = (int16_t)ol;
        dst[2 * f + 1] = (int16_t)orr;
        if (sp) {
            sp->ring[sp->pos] = (float)((ol + orr) * (0.5 / 32768.0));
            sp->pos = (sp->pos + 1) & (SPEC_N - 1);
        }
    }
    if (sp) {
        sp->fresh += (int)frames;
        sp->filled = sp->filled + (int)frames > SPEC_N ? SPEC_N : sp->filled + (int)frames;
    }
    c->in_peak_l = ipl;
    c->in_peak_r = ipr;
    if (bpk > c->out_peak) c->out_peak = bpk;
    c->blk_peak = bpk;
    c->blk_ss = oss;
    c->blk_frames = (uint32_t)frames;
    c->blk_seq++;
    c->in_ss += iss;
    c->out_ss += oss;
    c->ss_frames += frames;
    c->in_clip_sr += clip;
    c->in_clip_total += clip;
    /* keep the filter states out of the denormal range, and the running sum exact */
    for (int j = 0; j < EQE_NBAND; j++) {
        band_t *b = &c->band[j];
        for (int ch = 0; ch < 2; ch++) {
            if (fabs(b->z1[ch]) < 1e-25) b->z1[ch] = 0.0;
            if (fabs(b->z2[ch]) < 1e-25) b->z2[ch] = 0.0;
        }
        if (b->active && c->ramp_left == 0 && is_identity(&b->cur) && is_identity(&b->tgt) &&
            b->z1[0] == 0.0 && b->z1[1] == 0.0 && b->z2[0] == 0.0 && b->z2[1] == 0.0)
            b->active = 0;
    }
    double s = 0.0;
    for (int i = 0; i < LA; i++) s += c->box[i];
    c->boxsum = s;
}
