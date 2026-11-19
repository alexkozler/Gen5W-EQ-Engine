#include "../../native/eqengine.c"
#include <stdio.h>
int main(int argc, char **argv) {
    eqe_ctx c; memset(&c, 0, sizeof(c)); c.rate = 44100; prepare_rate(&c);
    c.set.layout = 1; c.set.eq_on = 1;
    for (int i = 0; i < EQE_NB && i + 1 < argc; i++) c.set.band_cdb[i] = atoi(argv[i + 1]);
    apply_settings(&c, 1);
    for (int k = 0; k < EQE_NRESP; k++) { double f = eqe_resp_hz(k), d = 0; for (int j = 0; j < EQE_NB; j++) d += coefs_db(&c.band[j].tgt, f, 44100); printf("%d%s", (int)floor(d*100+0.5), k == EQE_NRESP-1 ? "\n" : ","); }
    return 0;
}
