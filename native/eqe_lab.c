/*
 * eqe_lab: root helper for the Lab's 48 kHz test (act.sh), 0.6.1.
 *
 *   eqe_lab rate [ms]          the hardware links that are playing, from the kernel's own counters:
 *                              "link pcm2p state=RUNNING owner=4258 rate=44100 fps=44100.0"
 *                              (ms: how long to count, default 3000; 0 = one reading, counted
 *                              from the link's start). "link none" if nothing plays.
 *   eqe_lab get <io> <keys>    Android's AudioSystem::getParameters(io, keys): prints the answer
 *   eqe_lab set <io> <kv>      Android's AudioSystem::setParameters(io, kv): prints "status <n>"
 *
 * The rate comes from /proc/asound/cardN/pcmMp/sub0/status: hw_ptr is the number of frames the
 * hardware has taken since the link started and tstamp is when the kernel last updated it, so the
 * change in hw_ptr over the change in tstamp is the rate the link really runs at. Nothing in the
 * audio server is touched for that.
 *
 * get and set call Android's own libmedia (the car's /system/lib/libmedia.so), found by symbol
 * name: no binder codes are guessed. If a symbol is missing it says so and does nothing.
 * set with an io handle sends the setting to that output's mixer thread, which hands it to
 * Hyundai's driver and, for "sampling_rate", reads the driver's rate back and rebuilds its mixer
 * at that rate (Android 4.4.2, MixerThread::checkForNewParameters_l).
 */
#define _POSIX_C_SOURCE 200809L /* nanosleep on PC test builds */
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifndef EQE_ASOUND
#define EQE_ASOUND "/proc/asound"
#endif
#ifndef EQE_MEDIA_LIB
#define EQE_MEDIA_LIB "libmedia.so"
#endif
#ifndef EQE_UTILS_LIB
#define EQE_UTILS_LIB "libutils.so"
#endif

/* ------------------------------------------------------------------ links */

typedef struct {
    char name[16];
    int card, dev, running, owner;
    unsigned rate;
    long long hw_ptr;
    double tstamp, trigger;
} link_t;

#define MAXL 32

static const char *asound_root(void) {
    const char *e = getenv("EQE_ASOUND");
    return e && *e ? e : EQE_ASOUND;
}

/* "key  : value" or "key: value" lines; returns the value text after the colon */
static const char *field(const char *line, const char *key) {
    size_t n = strlen(key);
    if (strncmp(line, key, n) != 0) return NULL;
    const char *p = line + n;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != ':') return NULL;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    return p;
}

static int read_link(link_t *l, int card, int dev) {
    char path[256], line[256];
    memset(l, 0, sizeof(*l));
    l->card = card;
    l->dev = dev;
    snprintf(l->name, sizeof(l->name), "pcm%dp", dev);
    snprintf(path, sizeof(path), "%s/card%d/pcm%dp/sub0/status", asound_root(), card, dev);
    FILE *f = fopen(path, "r");
    if (f == NULL) return -1;
    while (fgets(line, sizeof(line), f)) {
        const char *v;
        if ((v = field(line, "state"))) l->running = strncmp(v, "RUNNING", 7) == 0;
        else if ((v = field(line, "owner_pid"))) l->owner = atoi(v);
        else if ((v = field(line, "hw_ptr"))) l->hw_ptr = atoll(v);
        else if ((v = field(line, "tstamp"))) l->tstamp = atof(v);
        else if ((v = field(line, "trigger_time"))) l->trigger = atof(v);
    }
    fclose(f);
    snprintf(path, sizeof(path), "%s/card%d/pcm%dp/sub0/hw_params", asound_root(), card, dev);
    f = fopen(path, "r");
    if (f != NULL) {
        while (fgets(line, sizeof(line), f)) {
            const char *v = field(line, "rate");
            if (v) l->rate = (unsigned)strtoul(v, NULL, 10);
        }
        fclose(f);
    }
    return 0;
}

static int read_links(link_t *out, int max) {
    int n = 0;
    for (int card = 0; card < 4; card++)
        for (int dev = 0; dev < 16 && n < max; dev++)
            if (read_link(&out[n], card, dev) == 0 && out[n].running) n++;
    return n;
}

static int cmd_rate(int ms) {
    link_t a[MAXL];
    int na = read_links(a, MAXL);
    if (ms > 0 && na > 0) {
        struct timespec t = {ms / 1000, (long)(ms % 1000) * 1000000L};
        while (nanosleep(&t, &t) != 0 && errno == EINTR) {
        }
    }
    int any = 0;
    for (int i = 0; i < na; i++) {
        link_t *x = &a[i], y;
        double fps = 0;
        const char *note = "";
        if (ms > 0) {
            if (read_link(&y, x->card, x->dev) != 0 || !y.running) {
                note = " stopped";
            } else if (y.owner != x->owner || y.hw_ptr < x->hw_ptr || y.tstamp <= x->tstamp) {
                note = " restarted"; /* new owner, or the counter started again: no rate this time */
            } else {
                fps = (double)(y.hw_ptr - x->hw_ptr) / (y.tstamp - x->tstamp);
                x = &y;
            }
        } else if (x->tstamp > x->trigger && x->trigger > 0) {
            fps = (double)x->hw_ptr / (x->tstamp - x->trigger);
        }
        printf("link %s card%d state=RUNNING owner=%d rate=%u fps=%.1f%s\n", x->name, x->card, x->owner, x->rate, fps, note);
        any = 1;
    }
    if (!any) printf("link none\n");
    return 0;
}

/* ------------------------------------------------------------------ Android's AudioSystem */

/* android::String8 holds one pointer (mString). Its constructor and destructor come from the car's
 * libutils; a String8 returned by value comes back through a hidden pointer (it has a destructor,
 * so the ARM C++ ABI returns it in memory, address in r0). */
typedef struct {
    const char *str;
} string8;

typedef void (*s8_ctor_t)(string8 *, const char *);
typedef void (*s8_dtor_t)(string8 *);
typedef int (*as_set_t)(int, const string8 *);
typedef void (*as_get_t)(string8 *, int, const string8 *);

static void *sym(void *lib, const char *name) {
    void *p = lib ? dlsym(lib, name) : NULL;
    if (p == NULL) printf("EQE_LAB_ERR missing %s\n", name);
    return p;
}

static int cmd_param(int set, int io, const char *text) {
    const char *ml = getenv("EQE_MEDIA_LIB"), *ul = getenv("EQE_UTILS_LIB");
    void *utils = dlopen(ul && *ul ? ul : EQE_UTILS_LIB, RTLD_NOW);
    void *media = dlopen(ml && *ml ? ml : EQE_MEDIA_LIB, RTLD_NOW);
    if (utils == NULL || media == NULL) {
        const char *e = dlerror();
        printf("EQE_LAB_ERR could not load Android's audio library: %s\n", e ? e : "?");
        return 2;
    }
    s8_ctor_t ctor = (s8_ctor_t)sym(utils, "_ZN7android7String8C1EPKc");
    s8_dtor_t dtor = (s8_dtor_t)sym(utils, "_ZN7android7String8D1Ev");
    as_set_t setp = (as_set_t)sym(media, "_ZN7android11AudioSystem13setParametersEiRKNS_7String8E");
    as_get_t getp = (as_get_t)sym(media, "_ZN7android11AudioSystem13getParametersEiRKNS_7String8E");
    if (ctor == NULL || dtor == NULL || (set && setp == NULL) || (!set && getp == NULL)) return 2;
    string8 arg;
    ctor(&arg, text);
    if (set) {
        int st = setp(io, &arg);
        printf("status %d\n", st);
    } else {
        string8 ans = {NULL};
        getp(&ans, io, &arg);
        printf("answer %s\n", ans.str ? ans.str : "");
        dtor(&ans);
    }
    dtor(&arg);
    return 0;
}

static int usage(void) {
    fprintf(stderr, "usage: eqe_lab rate [ms] | get <io> <keys> | set <io> <key=value>\n");
    return 2;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "rate") == 0) {
        int ms = argc >= 3 ? atoi(argv[2]) : 3000;
        if (ms < 0 || ms > 60000) return usage();
        return cmd_rate(ms);
    }
    if (argc == 4 && (strcmp(argv[1], "get") == 0 || strcmp(argv[1], "set") == 0)) {
        char *end;
        long io = strtol(argv[2], &end, 10);
        if (*end != 0 || io < 0 || io > 1000000) return usage();
        /* only plain key=value text: what Android itself sends */
        for (const char *p = argv[3]; *p; p++)
            if (!(*p == '_' || *p == '=' || *p == ';' || *p == '.' || (*p >= '0' && *p <= '9') ||
                  (*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z')))
                return usage();
        return cmd_param(argv[1][0] == 's', (int)io, argv[3]);
    }
    return usage();
}
