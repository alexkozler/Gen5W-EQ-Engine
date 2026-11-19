/*
 * Driver watch 2 test: plays Android's part against the watch layer, with the fake driver behind
 * it, through Hyundai's 19-entry device table (hy_audio.h), the way Hyundai's own audio server
 * calls it. Checks that every call reaches the driver unchanged, that output streams are left
 * untouched, that the layer writes down what it should (by Hyundai's positions), that it measures
 * the hardware link from the kernel's counters (a simulated /proc/asound), and that it hands an
 * unfamiliar device over untouched.
 * Usage: test_drv <shim.so> <fake_hal.so> <out dir> [corrupt]
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <hardware/audio.h>
#include <hardware/hardware.h>

#include "hy_audio.h"

static int fails;
#define CHECK(c, ...)                         \
    do {                                      \
        if (c) {                              \
            printf("  ok   ");                \
        } else {                              \
            printf("  FAIL ");                \
            fails++;                          \
        }                                     \
        printf(__VA_ARGS__);                  \
        printf("\n");                         \
    } while (0)

static char *slurp(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return strdup("");
    static char buf[1 << 20];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    buf[n] = 0;
    fclose(f);
    return strdup(buf);
}

static void *lib_of(const void *p) {
    Dl_info i;
    return dladdr(p, &i) ? i.dli_fbase : NULL;
}

/* the kernel side: pcm2p plays at 48000 frames/s, owned by thread 4258 */
static char g_asound[600];
static volatile int g_alsa_stop;
static double mono(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static void *alsa_main(void *a) {
    (void)a;
    char dir[700], f[800], tmp[800];
    snprintf(dir, sizeof(dir), "%s/card0/pcm2p/sub0", g_asound);
    snprintf(f, sizeof(f), "%s/hw_params", dir);
    FILE *h = fopen(f, "w");
    fprintf(h, "access: RW_INTERLEAVED\nformat: S16_LE\nsubformat: STD\nchannels: 2\nrate: 48000 (48000/1)\nperiod_size: 2048\n");
    fclose(h);
    double t0 = mono();
    while (!g_alsa_stop) {
        double e = mono() - t0;
        snprintf(tmp, sizeof(tmp), "%s/status.tmp", dir);
        snprintf(f, sizeof(f), "%s/status", dir);
        h = fopen(tmp, "w");
        fprintf(h, "state: RUNNING\nowner_pid   : 4258\ntrigger_time: 100.000000000\ntstamp      : %.9f\ndelay       : 6576\n"
                   "-----\nhw_ptr      : %lld\nappl_ptr    : %lld\n",
                100 + e, (long long)(48000 * e), (long long)(48000 * e) + 6000);
        fclose(h);
        rename(tmp, f);
        usleep(20000);
    }
    return NULL;
}

static void mkdirs(const char *base) {
    char p[700];
    const char *parts[] = {"", "/card0", "/card0/pcm2p", "/card0/pcm2p/sub0"};
    for (int i = 0; i < 4; i++) {
        snprintf(p, sizeof(p), "%s%s", base, parts[i]);
        mkdir(p, 0755);
    }
}

int main(int argc, char **argv) {
    int corrupt = argc > 4;
    char path[512];
    snprintf(g_asound, sizeof(g_asound), "%s/asound", argv[3]);
    mkdirs(g_asound);
    pthread_t alsa;
    pthread_create(&alsa, NULL, alsa_main, NULL);

    void *so = dlopen(argv[1], RTLD_NOW);
    if (!so) {
        printf("dlopen: %s\n", dlerror());
        return 2;
    }
    struct hw_module_t *mod = dlsym(so, HAL_MODULE_INFO_SYM_AS_STR);
    CHECK(mod && strcmp(mod->id, AUDIO_HARDWARE_MODULE_ID) == 0 && mod->tag == HARDWARE_MODULE_TAG,
          "the layer is an audio driver module (id \"%s\")", mod ? mod->id : "?");
    mod->dso = so;
    struct hy_dev *dev = NULL;
    int rc = mod->methods->open(mod, AUDIO_HARDWARE_INTERFACE, (struct hw_device_t **)&dev);
    void *fake = dlopen(argv[2], RTLD_NOW | RTLD_NOLOAD);
    struct hy_dev **fake_device = fake ? dlsym(fake, "fake_device") : NULL;
    char *calls = fake ? dlsym(fake, "fake_calls") : NULL;
    float *ff = fake ? dlsym(fake, "fake_last_float") : NULL;
    const void **fp = fake ? dlsym(fake, "fake_last_ptr") : NULL;
    unsigned *fu = fake ? dlsym(fake, "fake_last_u") : NULL;
    void *drv = lib_of(dlsym(fake, "HMI")), *shim = lib_of(mod);
    CHECK(rc == 0 && fake && fake_device && dev == *fake_device, "open returns Hyundai's own device object (rc %d)", rc);
    CHECK(dev->common.version == AUDIO_DEVICE_API_VERSION_2_0 && dev->common.module != mod,
          "the device still names Hyundai's module, version 2.0");
    void **e = (void **)&dev->get_supported_devices;

    if (corrupt) {
        int untouched = 1;
        for (int i = 0; i < 18; i++)
            if (lib_of(e[i]) != drv) untouched = 0;
        CHECK(untouched, "unfamiliar table: every entry still goes straight to the driver");
        usleep(300000);
        snprintf(path, sizeof(path), "%s/drv.log", argv[3]);
        char *log = slurp(path);
        CHECK(strstr(log, "looks unfamiliar") && strstr(log, "entry 18 is not a function in the driver") &&
                  strstr(log, "handed to Android untouched"),
              "the log says why");
        snprintf(path, sizeof(path), "%s/status", argv[3]);
        char *st = slurp(path);
        CHECK(strstr(st, "state=pass-through") != NULL, "status: pass-through");
        CHECK(strstr(st, "link=pcm2p card=0 owner=4258 rate=48000") != NULL, "status: the link is still measured");
        g_alsa_stop = 1;
        pthread_join(alsa, NULL);
        printf("%d failed\n", fails);
        return fails != 0;
    }

    int all = 1;
    for (int i = 0; i < 19; i++)
        if (e[i] && lib_of(e[i]) != shim) all = 0;
    CHECK(all, "all 19 of Hyundai's device entries go through the layer");

    /* what Hyundai's audio server does at start, by Hyundai's positions */
    CHECK(dev->init_check(dev) == 0, "init_check forwarded");
    CHECK(dev->set_master_volume(dev, 0.75f) != 0 && fabsf(ff[0] - 0.75f) < 1e-6, "set_master_volume: the float arrives (%.3f)", ff[0]);
    CHECK(dev->set_voice_volume(dev, 0.5f) == 0 && fabsf(ff[0] - 0.5f) < 1e-6, "set_voice_volume: the float arrives (%.3f)", ff[0]);
    CHECK(dev->set_mode(dev, AUDIO_MODE_IN_CALL) == 0 && strstr(calls, "set_mode 2"), "set_mode forwarded");
    CHECK(dev->hy_extra(dev, 5) == 7 && strstr(calls, "hy_extra 5"), "Hyundai's extra entry forwarded, result back");
    CHECK(dev->set_parameters(dev, "restarting=true") == 0 && strstr(calls, "set_parameters restarting=true"),
          "set_parameters (entry 9) forwarded exactly");
    CHECK(dev->set_parameters(dev, "routing=2;tcc_test=1") == 0 && strstr(calls, "set_parameters routing=2;tcc_test=1"),
          "a second parameter string forwarded exactly");
    char *a1 = dev->get_parameters(dev, "sampling_rate");
    char *a2 = dev->get_parameters(dev, "sampling_rate");
    CHECK(a1 && strcmp(a1, "sampling_rate=44100") == 0 && a2, "get_parameters answers come back unchanged");
    free(a1);
    free(a2);
    CHECK(dev->set_parameters(dev, (const char *)16) == -22 && strstr(calls, "set_parameters (bad pointer)"),
          "a bad parameter pointer is forwarded, not read (no crash)");
    struct audio_config ic = {.sample_rate = 16000, .channel_mask = AUDIO_CHANNEL_IN_MONO, .format = AUDIO_FORMAT_PCM_16_BIT};
    CHECK(dev->get_input_buffer_size(dev, &ic) == 2048 && strstr(calls, "get_input_buffer_size 16000"),
          "get_input_buffer_size forwarded (entry 11)");
    CHECK(dev->dump(dev, 30) == 0, "dump forwarded (entry 16)");

    struct audio_config cfg = {.sample_rate = 48000, .channel_mask = AUDIO_CHANNEL_OUT_STEREO, .format = AUDIO_FORMAT_PCM_16_BIT};
    struct audio_stream_out *out = NULL;
    rc = dev->open_output_stream(dev, 101, 0x10000000, AUDIO_OUTPUT_FLAG_PRIMARY, &cfg, &out);
    CHECK(rc == 0 && out && fp[0] == &cfg && fp[1] == &out && fu[0] == 101 && fu[1] == 0x10000000 &&
              fu[2] == AUDIO_OUTPUT_FLAG_PRIMARY,
          "open_output_stream (entry 12): all six arguments arrive exactly");
    void **se = (void **)out;
    int mine = 1;
    for (size_t i = 0; i < sizeof(struct audio_stream_out) / sizeof(void *); i++)
        if (se[i] && lib_of(se[i]) != drv) mine = 0;
    CHECK(mine, "the output stream is left untouched: every entry is Hyundai's own");
    static int16_t buf[1024 * 2];
    CHECK(out->write(out, buf, sizeof(buf)) == (ssize_t)sizeof(buf) && fp[2] == buf, "the stream works as before");
    dev->close_output_stream(dev, out);
    CHECK(strstr(calls, "close_output_stream secret 0x5ec2e7") != NULL, "close reaches the driver with its own private fields intact");

    /* a refused rate is reported as such */
    setenv("FAKE_REJECT_48K", "1", 1);
    struct audio_config cfg2 = {.sample_rate = 48000, .channel_mask = AUDIO_CHANNEL_OUT_STEREO, .format = AUDIO_FORMAT_PCM_16_BIT};
    struct audio_stream_out *out2 = NULL;
    rc = dev->open_output_stream(dev, 21, 0x10000000, AUDIO_OUTPUT_FLAG_PRIMARY, &cfg2, &out2);
    CHECK(rc != 0 && cfg2.sample_rate == 44100, "a refusal and the driver's suggested rate come back unchanged");
    unsetenv("FAKE_REJECT_48K");

    usleep(1200000); /* the link is measured every 100 ms, reported every 300 ms in this build */
    snprintf(path, sizeof(path), "%s/drv.log", argv[3]);
    char *log = slurp(path);
    CHECK(strstr(log, "watching Hyundai's driver: module \"fake Telechips audio\"") &&
              strstr(log, "19 of its 19 device entries forwarded (Hyundai's layout); output streams left untouched"),
          "log: watching, with the driver's name and its layout");
    CHECK(strstr(log, "device set_parameters \"restarting=true\" -> 0") != NULL, "log: set_parameters named right (entry 9)");
    CHECK(strstr(log, "(unreadable 0x10)") != NULL, "log: the bad pointer is noted, not read");
    CHECK(strstr(log, "open_output_stream handle 101 devices 0x10000000 flags 0x2: asked 48000 Hz mask 0x3 format 0x1 -> 0, "
                      "config now 48000 Hz") != NULL,
          "log: the stream set-up, asked and returned (entry 12)");
    CHECK(strstr(log, "open_output_stream handle 21") && strstr(log, "-> -22, config now 44100 Hz") != NULL,
          "log: the refusal and the driver's suggestion");
    CHECK(strstr(log, "device set_master_volume 0.750") && strstr(log, "set_voice_volume 0.500"), "log: volumes (floats read right)");
    CHECK(strstr(log, "device entry 7 (not named): 0x5 ") != NULL, "log: the unnamed entry, as numbers");
    CHECK(strstr(log, "device dump: 0x1e ") != NULL, "log: dump named right (entry 16), with its file descriptor");
    CHECK(strstr(log, "device close_output_stream: ") != NULL, "log: close named right (entry 13)");
    /* the notes come every window; the three set_parameters calls may fall into more than one */
    int n_sp = 0;
    for (char *p = log; (p = strstr(p, "device calls since the last note:")) != NULL; p++) {
        char *eol = strchr(p, '\n'), *q = strstr(p, " set_parameters ");
        if (q && (!eol || q < eol)) n_sp += atoi(q + strlen(" set_parameters "));
    }
    CHECK(n_sp == 3, "log: the calls are counted (set_parameters %d times; it was called 3 times)", n_sp);
    int n_q = 0;
    for (char *p = log; (p = strstr(p, "device get_parameters \"sampling_rate\"")) != NULL; p++) n_q++;
    CHECK(n_q == 1, "log: a repeated question is written once (%d)", n_q);
    char *ln = strstr(log, "link pcm2p (card0, played by thread 4258): set to 48000 Hz, took ");
    double fps = ln ? atof(ln + strlen("link pcm2p (card0, played by thread 4258): set to 48000 Hz, took ")) : 0;
    CHECK(ln && fabs(fps - 48000) < 48000 * 0.01, "log: the link's measured rate (%.0f frames/s; it takes 48000)", fps);
    snprintf(path, sizeof(path), "%s/status", argv[3]);
    char *stt = slurp(path);
    char *sl = strstr(stt, "link=pcm2p card=0 owner=4258 rate=48000 fps=");
    double sfps = sl ? atof(sl + strlen("link=pcm2p card=0 owner=4258 rate=48000 fps=")) : 0;
    CHECK(strstr(stt, "state=watching") && strstr(stt, "mode=2") && strstr(stt, "layout=hyundai-19"), "status file: watching, mode, layout");
    CHECK(sl && fabs(sfps - 48000) < 48000 * 0.01, "status file: the link and its rate (%.0f)", sfps);

    /* the link stops: gone from the status */
    g_alsa_stop = 1;
    pthread_join(alsa, NULL);
    snprintf(path, sizeof(path), "%s/card0/pcm2p/sub0/status", g_asound);
    FILE *c = fopen(path, "w");
    fprintf(c, "closed\n");
    fclose(c);
    usleep(400000);
    snprintf(path, sizeof(path), "%s/status", argv[3]);
    stt = slurp(path);
    CHECK(strstr(stt, "link=") == NULL, "status file: a stopped link is no longer listed");
    printf("%d failed\n", fails);
    return fails != 0;
}
