/* The CarPlay watch's PC test program, in the place of Dalvik: it loads the watch under the name
   libCarPlayAndroid.so and calls its JNI_OnLoad, as Dalvik does when the app loads its JNI
   library. The watch loads the stand-in factory library (libCarPlayAndroid.car.so), which
   brings the stand-in libCarPlayAudio.so and libtinyalsa.so, and points the audio library's TinyALSA
   imports at itself. Then the audio library plays (cpa_play) and checks that nothing changed in what
   reaches TinyALSA. run.sh checks the watch's notes.

   Usage: test_cps <watch> <copy> normal|failed|guarded|eq <seconds of writes>
     eq:      EQ on CarPlay's music (cpa_eq: the control file from CPE_TEST_CTL, ...)
     normal:  JNI_OnLoad returns the factory library's result, which saw the same JavaVM pointer
     failed:  the factory library is not there: JNI_OnLoad returns -1 (Dalvik then refuses the load)
     guarded: the watch hands on to another TinyALSA than the one the audio library imports: nothing
              is pointed at the watch, and the music still plays */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fails;
#define CHECK(c, what)                   \
    do {                                 \
        if (!(c)) {                      \
            fails++;                     \
            printf("  FAIL %s\n", what); \
        } else {                         \
            printf("  ok   %s\n", what); \
        }                                \
    } while (0)

int main(int argc, char **argv) {
    if (argc < 5) return 2;
    const char *watch = argv[1], *copy = argv[2], *mode = argv[3];
    double secs = atof(argv[4]);
    void *h = dlopen(watch, RTLD_NOW);
    CHECK(h != NULL, "the watch loads in place of libCarPlayAndroid.so");
    if (h == NULL) {
        printf("       %s\n", dlerror());
        return 1;
    }
    void *p = dlsym(h, "JNI_OnLoad");
    int (*onload)(void *, void *);
    memcpy(&onload, &p, sizeof(p));
    CHECK(p != NULL, "it has JNI_OnLoad");
    if (p == NULL) return 1;
    void *vm = (void *)0x1234;
    int v = onload(vm, NULL);
    if (strcmp(mode, "failed") == 0) {
        CHECK(v == -1, "no factory library: JNI_OnLoad returns -1 (Dalvik refuses the load)");
        usleep(400000);
        return fails ? 1 : 0;
    }
    CHECK(v == 0x10006, "JNI_OnLoad returns the factory library's own result (JNI_VERSION_1_6)");
    void *c = dlopen(copy, RTLD_NOW | RTLD_NOLOAD);
    CHECK(c != NULL, "the factory library is loaded (under its own name)");
    if (c != NULL) {
        void *(*vmget)(void);
        int (*calls)(void);
        void *q = dlsym(c, "fake_onload_vm");
        memcpy(&vmget, &q, sizeof(q));
        q = dlsym(c, "fake_onload_calls");
        memcpy(&calls, &q, sizeof(q));
        CHECK(vmget != NULL && vmget() == vm && calls() == 1, "its JNI_OnLoad was called once, with Dalvik's JavaVM");
    }
    void *a = dlopen("libCarPlayAudio.so", RTLD_NOW | RTLD_NOLOAD);
    CHECK(a != NULL, "the audio library came with it");
    if (a == NULL) return 1;
    if (strcmp(mode, "eq") == 0) {
        /* EQ on CarPlay's music (0.7.3): the control file, the streams, the live file */
        int (*eq)(void);
        void *e = dlsym(a, "cpa_eq");
        memcpy(&eq, &e, sizeof(e));
        CHECK(e != NULL, "the audio library has the EQ test");
        if (e != NULL) fails += eq();
        usleep(600000);
        return fails ? 1 : 0;
    }
    int (*play)(double);
    void *q = dlsym(a, "cpa_play");
    memcpy(&play, &q, sizeof(q));
    fails += play(secs);
    /* the watch's own thread writes its notes once per tick */
    usleep(600000);
    return fails ? 1 : 0;
}
