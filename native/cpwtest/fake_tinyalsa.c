/* A stand-in for the car's libtinyalsa.so (built as libtinyalsa.so for the CarPlay watch's PC
   tests): the functions the watch hands its calls on to, plus accessors for the test. A write
   blocks as long as the link would take to play it, like a real stream. */
#define _DEFAULT_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct pcm_config {
    unsigned int channels, rate, period_size, period_count;
    int format;
    unsigned int start_threshold, stop_threshold, silence_threshold;
    int avail_min;
};

struct pcm {
    int ready;
    unsigned int flags;
    struct pcm_config c;
    char error[128];
};

static unsigned char last[65536];
static unsigned int last_count;
static int writes, reads, closes, fail_next;

/* one function behind both opens: on the PC a call inside this library would otherwise go through
   the LD_PRELOAD watch too (glibc looks every library's calls up globally; Android 4.4 looks in the
   library itself first) */
static struct pcm *open_impl(unsigned int card, unsigned int device, unsigned int flags, struct pcm_config *config) {
    struct pcm *p = calloc(1, sizeof(*p));
    p->flags = flags;
    if (config) p->c = *config;
    if (card == 9) {
        snprintf(p->error, sizeof(p->error), "cannot open device '/dev/snd/pcmC%uD%u%c': Device or resource busy", card,
                 device, (flags & 0x10000000u) ? 'c' : 'p');
        return p;
    }
    p->ready = 1;
    return p;
}

struct pcm *pcm_open(unsigned int card, unsigned int device, unsigned int flags, struct pcm_config *config) {
    return open_impl(card, device, flags, config);
}

int pcm_close(struct pcm *pcm) {
    closes++;
    free(pcm);
    return 0;
}

int pcm_is_ready(struct pcm *pcm) {
    return pcm->ready;
}

const char *pcm_get_error(struct pcm *pcm) {
    return pcm->error;
}

unsigned int pcm_get_buffer_size(struct pcm *pcm) {
    return pcm->c.period_size * pcm->c.period_count;
}

static void play_time(struct pcm *pcm, unsigned int count) {
    unsigned int bpf = pcm->c.channels * 2;
    if (bpf && pcm->c.rate) usleep((useconds_t)((unsigned long long)(count / bpf) * 1000000ull / pcm->c.rate));
}

/* everything written while capturing (the CarPlay EQ test), 16-bit samples */
#define CAP_MAX (44100 * 2 * 8)
static short cap[CAP_MAX];
static unsigned int cap_n;
static const void *last_ptr;

int pcm_write(struct pcm *pcm, const void *data, unsigned int count) {
    writes++;
    if (fail_next) {
        int rc = fail_next;
        fail_next = 0;
        return rc;
    }
    last_count = count;
    last_ptr = data;
    memcpy(last, data, count < sizeof(last) ? count : sizeof(last));
    unsigned int ns = count / 2;
    if (cap_n + ns <= CAP_MAX) {
        memcpy(cap + cap_n, data, ns * 2);
        cap_n += ns;
    }
    play_time(pcm, count);
    return 0;
}

/* the CarPlay EQ test: what reached TinyALSA, and from which buffer */
void fake_cap_reset(void) { cap_n = 0; }
const short *fake_cap(unsigned int *n) { *n = cap_n; return cap; }
const void *fake_last_ptr(void) { return last_ptr; }

int pcm_read(struct pcm *pcm, void *data, unsigned int count) {
    reads++;
    short *s = data;
    for (unsigned int i = 0; i < count / 2; i++) s[i] = (short)((i % 2) ? 1000 : -2000);
    play_time(pcm, count);
    return 0;
}

/* for the test */
int fake_writes(void) { return writes; }
int fake_reads(void) { return reads; }
int fake_closes(void) { return closes; }
unsigned int fake_last_count(void) { return last_count; }
const void *fake_last_data(void) { return last; }
void fake_fail_next(int rc) { fail_next = rc; }
/* a stream opened past the watch (it does not know it) */
struct pcm *fake_open_direct(void) {
    struct pcm_config c = {2, 48000, 960, 2, 0, 0, 0, 0, 0};
    return open_impl(0, 5, 0, &c);
}
