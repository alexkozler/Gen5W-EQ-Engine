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
              is pointed at the watch, and the music still plays
     badphoff, badphnum, baddyn (after 0.7.6): the audio library is loaded first and its headers
              are changed in memory so that they point where it is not loaded (program headers
              elsewhere, too many of them, the dynamic section elsewhere); the watch must leave it
              alone without reading there, and the music still plays */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <elf.h>
#include <link.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
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

/* the protection of the mapping that holds addr, from /proc/self/maps; -1 if none */
static int prot_of(uintptr_t addr) {
    FILE *f = fopen("/proc/self/maps", "r");
    if (f == NULL) return -1;
    char line[600], perms[8];
    unsigned long s, e;
    int p = -1;
    while (fgets(line, sizeof(line), f) != NULL) {
        if (sscanf(line, "%lx-%lx %7s", &s, &e, perms) != 3) continue;
        if (addr >= s && addr < e) {
            p = (perms[0] == 'r' ? PROT_READ : 0) | (perms[1] == 'w' ? PROT_WRITE : 0) | (perms[2] == 'x' ? PROT_EXEC : 0);
            break;
        }
    }
    fclose(f);
    return p;
}

/* the bad* modes: the audio library loaded before the watch, its first page's headers changed in
   place; *undo puts them back (after JNI_OnLoad, before the music plays) */
static unsigned char g_saved[4096];
static unsigned char *g_hdr;
static size_t g_hlen;

static int spoil(const char *mode) {
    void *a = dlopen("libCarPlayAudio.so", RTLD_NOW);
    if (a == NULL) return 0;
    Dl_info di;
    void *sym = dlsym(a, "cpa_play");
    if (sym == NULL || dladdr(sym, &di) == 0 || di.dli_fbase == NULL) return 0;
    ElfW(Ehdr) *eh = (ElfW(Ehdr) *)di.dli_fbase;
    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0 || pg > (long)sizeof(g_saved)) return 0;
    int prot = prot_of((uintptr_t)eh);
    if (prot < 0 || eh->e_phoff + (size_t)eh->e_phnum * sizeof(ElfW(Phdr)) > (size_t)pg) return 0;
    g_hdr = (unsigned char *)eh;
    g_hlen = (size_t)pg;
    memcpy(g_saved, g_hdr, g_hlen);
    if (mprotect(g_hdr, g_hlen, PROT_READ | PROT_WRITE) != 0) return 0;
    ElfW(Phdr) *ph = (ElfW(Phdr) *)(g_hdr + eh->e_phoff);
    int done = 1;
    if (strcmp(mode, "badphoff") == 0) {
        eh->e_phoff = 0x7ff00000; /* far past anything loaded */
    } else if (strcmp(mode, "badphnum") == 0) {
        eh->e_phnum = 0xffff; /* the table would run on past the first page and the file */
    } else {
        done = 0;
        for (int i = 0; i < eh->e_phnum; i++)
            if (ph[i].p_type == PT_DYNAMIC) {
                ph[i].p_vaddr += 0x40000000; /* the dynamic section where nothing is loaded */
                done = 1;
            }
    }
    mprotect(g_hdr, g_hlen, prot);
    return done;
}

static void unspoil(void) {
    if (g_hdr == NULL) return;
    int prot = prot_of((uintptr_t)g_hdr);
    if (prot < 0 || mprotect(g_hdr, g_hlen, PROT_READ | PROT_WRITE) != 0) return;
    memcpy(g_hdr, g_saved, g_hlen);
    mprotect(g_hdr, g_hlen, prot);
}

int main(int argc, char **argv) {
    if (argc < 5) return 2;
    const char *watch = argv[1], *copy = argv[2], *mode = argv[3];
    double secs = atof(argv[4]);
    int bad = strncmp(mode, "bad", 3) == 0;
    if (bad) {
        int sp = spoil(mode);
        CHECK(sp, "the audio library is loaded first and its headers changed in memory");
        if (!sp) return 1;
    }
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
    if (bad) unspoil();
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
