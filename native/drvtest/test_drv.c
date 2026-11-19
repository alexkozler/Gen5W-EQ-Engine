/*
 * Driver watch test: plays Android's part (as AudioFlinger 4.4 does) against the watch layer
 * with the fake driver behind it. Checks that every call reaches the driver unchanged, that the
 * layer writes down what it should, and that it hands an unfamiliar device over untouched.
 * Usage: test_drv <shim.so> <fake_hal.so> <out dir> [corrupt]
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <hardware/audio.h>
#include <hardware/hardware.h>

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

struct stress {
    struct audio_hw_device *d;
    int stop;
};
static void *stress_main(void *a) {
    struct stress *s = a;
    for (int i = 0; i < 300 && !s->stop; i++) {
        s->d->set_parameters(s->d, "stress=1");
        free(s->d->get_parameters(s->d, "stress"));
    }
    return NULL;
}

int main(int argc, char **argv) {
    int corrupt = argc > 4;
    char path[512];
    void *so = dlopen(argv[1], RTLD_NOW);
    if (!so) {
        printf("dlopen: %s\n", dlerror());
        return 2;
    }
    struct hw_module_t *mod = dlsym(so, HAL_MODULE_INFO_SYM_AS_STR);
    CHECK(mod && strcmp(mod->id, AUDIO_HARDWARE_MODULE_ID) == 0 && mod->tag == HARDWARE_MODULE_TAG,
          "the layer is an audio driver module (id \"%s\")", mod ? mod->id : "?");
    mod->dso = so;
    struct audio_hw_device *dev = NULL;
    int rc = mod->methods->open(mod, AUDIO_HARDWARE_INTERFACE, (struct hw_device_t **)&dev);
    void *fake = dlopen(argv[2], RTLD_NOW | RTLD_NOLOAD);
    struct audio_hw_device **fake_device = fake ? dlsym(fake, "fake_device") : NULL;
    char *calls = fake ? dlsym(fake, "fake_calls") : NULL;
    float *ff = fake ? dlsym(fake, "fake_last_float") : NULL;
    const void **fp = fake ? dlsym(fake, "fake_last_ptr") : NULL;
    unsigned *fu = fake ? dlsym(fake, "fake_last_u") : NULL;
    CHECK(rc == 0 && fake && fake_device && dev == *fake_device, "open returns Hyundai's own device object (rc %d)", rc);
    CHECK(dev->common.version == AUDIO_DEVICE_API_VERSION_2_0 && dev->common.module != mod,
          "the device still names Hyundai's module, version 2.0");

    if (corrupt) {
        CHECK(lib_of((void *)dev->set_parameters) == lib_of((void *)dlsym(fake, "HMI")),
              "unfamiliar table: set_parameters still goes straight to the driver");
        CHECK(lib_of((void *)dev->open_output_stream) == lib_of((void *)dlsym(fake, "HMI")),
              "unfamiliar table: open_output_stream still goes straight to the driver");
        usleep(300000);
        snprintf(path, sizeof(path), "%s/drv.log", argv[3]);
        char *log = slurp(path);
        CHECK(strstr(log, "looks unfamiliar") && strstr(log, "handed to Android untouched"), "the log says why");
        snprintf(path, sizeof(path), "%s/status", argv[3]);
        char *st = slurp(path);
        CHECK(strstr(st, "state=pass-through") != NULL, "status: pass-through");
        printf("%d failed\n", fails);
        return fails != 0;
    }

    CHECK(lib_of((void *)dev->set_parameters) == lib_of((void *)mod), "set_parameters is watched (goes through the layer)");
    CHECK(lib_of((void *)dev->get_master_mute) != lib_of((void *)mod), "slots the layer does not need stay Hyundai's own");

    /* what AudioFlinger does at start */
    CHECK(dev->init_check(dev) == 0, "init_check forwarded");
    CHECK(dev->set_master_volume(dev, 0.75f) != 0 && fabsf(ff[0] - 0.75f) < 1e-6, "set_master_volume: the float arrives (%.3f)", ff[0]);
    CHECK(dev->set_voice_volume(dev, 0.5f) == 0 && fabsf(ff[0] - 0.5f) < 1e-6, "set_voice_volume: the float arrives (%.3f)", ff[0]);
    CHECK(dev->set_mode(dev, AUDIO_MODE_IN_CALL) == 0 && strstr(calls, "set_mode 2"), "set_mode forwarded");
    CHECK(dev->set_parameters(dev, "routing=2;tcc_test=1") == 0 && strstr(calls, "set_parameters routing=2;tcc_test=1"),
          "device set_parameters forwarded exactly");
    char *a1 = dev->get_parameters(dev, "sampling_rate");
    char *a2 = dev->get_parameters(dev, "sampling_rate");
    CHECK(a1 && strcmp(a1, "sampling_rate=44100") == 0 && a2, "get_parameters answers come back unchanged");
    free(a1);
    free(a2);
    CHECK(dev->set_parameters(dev, (const char *)16) == -22 && strstr(calls, "set_parameters (bad pointer)"),
          "a bad parameter pointer is forwarded, not read (no crash)");

    struct audio_config cfg = {.sample_rate = 48000, .channel_mask = AUDIO_CHANNEL_OUT_STEREO, .format = AUDIO_FORMAT_PCM_16_BIT};
    struct audio_stream_out *out = NULL;
    rc = dev->open_output_stream(dev, 13, 0x2, AUDIO_OUTPUT_FLAG_PRIMARY, &cfg, &out);
    CHECK(rc == 0 && out && fp[0] == &cfg && fp[1] == &out && fu[0] == 13 && fu[1] == 0x2 && fu[2] == AUDIO_OUTPUT_FLAG_PRIMARY,
          "open_output_stream: all six arguments arrive exactly");
    CHECK(lib_of((void *)out->write) == lib_of((void *)mod) && lib_of((void *)out->get_latency) != lib_of((void *)mod),
          "the stream's write is watched; its other slots stay Hyundai's");
    CHECK(out->common.get_sample_rate(&out->common) == 48000 && out->get_latency(out) == 85, "stream answers unchanged");

    /* play: -6 dBFS square wave, 1024-frame writes, about 1 s */
    static int16_t buf[1024 * 2];
    for (int i = 0; i < 2048; i++) buf[i] = (i / 64) % 2 ? 16384 : -16384;
    buf[100] = 32767; /* one full-scale sample per buffer */
    struct stress st = {dev, 0};
    pthread_t th;
    pthread_create(&th, NULL, stress_main, &st);
    int okw = 1;
    for (int i = 0; i < 47; i++) {
        ssize_t w = out->write(out, buf, sizeof(buf));
        if (w != (ssize_t)sizeof(buf) || fp[2] != buf) okw = 0;
    }
    st.stop = 1;
    pthread_join(th, NULL);
    CHECK(okw, "writes: buffer and size arrive unchanged, results come back");
    CHECK(out->set_volume(out, 0.25f, 0.5f) == 0 && fabsf(ff[1] - 0.25f) < 1e-6 && fabsf(ff[2] - 0.5f) < 1e-6,
          "set_volume: both floats arrive");
    CHECK(out->common.set_parameters(&out->common, "sampling_rate=48000") == 0 && strstr(calls, "out set_parameters sampling_rate=48000"),
          "stream set_parameters forwarded");
    char *a3 = out->common.get_parameters(&out->common, "sampling_rate");
    CHECK(a3 && strcmp(a3, "sampling_rate=48000") == 0, "stream get_parameters answer unchanged");
    free(a3);
    CHECK(out->common.standby(&out->common) == 0 && strstr(calls, "out standby"), "standby forwarded");
    dev->close_output_stream(dev, out);
    CHECK(strstr(calls, "close_output_stream secret 0x5ec2e7") != NULL, "close reaches the driver with its own private fields intact");

    /* a refused rate is reported as such */
    setenv("FAKE_REJECT_48K", "1", 1);
    struct audio_config cfg2 = {.sample_rate = 48000, .channel_mask = AUDIO_CHANNEL_OUT_STEREO, .format = AUDIO_FORMAT_PCM_16_BIT};
    struct audio_stream_out *out2 = NULL;
    rc = dev->open_output_stream(dev, 21, 0x10000000, AUDIO_OUTPUT_FLAG_PRIMARY, &cfg2, &out2);
    CHECK(rc != 0 && cfg2.sample_rate == 44100, "a refusal and the driver's suggested rate come back unchanged");
    unsetenv("FAKE_REJECT_48K");

    usleep(500000);
    snprintf(path, sizeof(path), "%s/drv.log", argv[3]);
    char *log = slurp(path);
    CHECK(strstr(log, "watching Hyundai's driver: module \"fake Telechips audio\"") != NULL, "log: watching, with the driver's name");
    CHECK(strstr(log, "device set_parameters \"routing=2;tcc_test=1\" -> 0") != NULL, "log: the parameter string");
    CHECK(strstr(log, "(unreadable 0x10)") != NULL, "log: the bad pointer is noted, not read");
    CHECK(strstr(log, "open_output_stream handle 13 devices 0x2 flags 0x2: asked 48000 Hz mask 0x3 format 0x1 -> 0") != NULL,
          "log: the stream set-up as asked");
    CHECK(strstr(log, "out 13 watched: 48000 Hz") != NULL, "log: the driver's own answer");
    CHECK(strstr(log, "asked 48000 Hz") && strstr(log, "-> -22, config now 44100 Hz") != NULL, "log: the refusal and suggestion");
    CHECK(strstr(log, "device set_master_volume 0.750") && strstr(log, "set_voice_volume 0.500"), "log: volumes (floats read right)");
    CHECK(strstr(log, "out 13 set_volume 0.250 0.500") != NULL, "log: stream volume");
    int n_q = 0;
    for (char *p = log; (p = strstr(p, "device get_parameters \"sampling_rate\"")) != NULL; p++) n_q++;
    CHECK(n_q == 1, "log: a repeated question is written once (%d)", n_q);
    /* the measured rate: windows of 300 ms in this build */
    char *w = strstr(log, "out 13 last window:");
    double fps = 0, peak = 0, avg = 0;
    unsigned long long fsc = 0;
    if (w) {
        char *f = strstr(w, "frames, ");
        if (f) fps = atof(f + 8);
        char *pk = strstr(w, "peak ");
        if (pk) peak = atof(pk + 5);
        char *av = strstr(w, "average ");
        if (av) avg = atof(av + 8);
        char *fs = strstr(w, "full-scale samples ");
        if (fs) fsc = strtoull(fs + 19, NULL, 10);
    }
    CHECK(w && fabs(fps - 48000) < 48000 * 0.03, "measured rate %.0f frames/s (the fake driver takes 48000)", fps);
    CHECK(w && fabs(peak - 0.0) < 0.05 && fabs(avg - (-6.02)) < 0.1, "levels: peak %.2f dBFS, average %.2f dBFS", peak, avg);
    CHECK(w && fsc > 0, "full-scale samples counted (%llu)", fsc);
    CHECK(strstr(log, "close_output_stream out 13") != NULL, "log: close");
    snprintf(path, sizeof(path), "%s/status", argv[3]);
    char *stt = slurp(path);
    CHECK(strstr(stt, "state=watching") && strstr(stt, "mode=2"), "status file: watching, mode");
    printf("%d failed\n", fails);
    return fails != 0;
}
