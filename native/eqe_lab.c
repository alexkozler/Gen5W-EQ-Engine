/*
 * eqe_lab: root helper for the 48 kHz output (act.sh keep), the car report and diagnostics, 0.6.7.
 *
 *   eqe_lab check              are Android's AudioSystem functions there? Looks them up and calls
 *                              nothing: "symbols 4 of 4"
 *   eqe_lab imports <file>     a 32-bit ARM library's dynamic symbol table (the car report's CarPlay
 *                              probe), one line each: "needed NAME" (DT_NEEDED), "import NAME"
 *                              (undefined symbol), "export NAME" (defined global or weak function
 *                              or object). Reads the ELF program headers, the dynamic section and
 *                              the symbol and string tables only: no code is read or disassembled.
 *                              The file is untrusted: every offset and size is checked, files over
 *                              64 MB are refused, and an error prints one "EQE_LAB_ERR" line.
 *
 *   eqe_lab rate [ms]          the hardware links that are playing, from the kernel's own counters:
 *                              "link pcm2p state=RUNNING owner=4258 rate=44100 fps=44100.0"
 *                              (ms: how long to count, default 3000; 0 = one reading, counted
 *                              from the link's start). "link none" if nothing plays.
 *   eqe_lab get <io> <keys>    Android's AudioSystem::getParameters(io, keys): prints the answer
 *   eqe_lab set <io> <kv>      Android's AudioSystem::setParameters(io, kv): prints "status <n>"
 *   eqe_lab umount <path>      detaches one of EQ Engine's bind mounts (the driver watch, the
 *                              effects list, or the CarPlay watch) even while a process still has
 *                              the file open: a plain umount says "busy" then. A running process
 *                              keeps the copy it has loaded; the next one opens the file underneath.
 *   eqe_lab cpcheck <watch> <copy>
 *                              the CarPlay watch's check before use (act.sh cpwatch): loads the
 *                              watch in this process (not in the CarPlay app), asks it to find the
 *                              car's TinyALSA functions and to read the copy of the factory
 *                              libCarPlayAndroid.so as a file (nothing of it runs here): "cpcheck ok
 *                              the factory library exports JNI_OnLoad and needs libCarPlayAudio.so;
 *                              TinyALSA: 7 of 7 functions"
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
#define _POSIX_C_SOURCE 200809L /* nanosleep and pread on PC test builds */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef MNT_DETACH
#define MNT_DETACH 2
#endif

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

/* "check": are Android's audio functions there? Loads the libraries and looks them up; calls nothing. */
static int cmd_check(void) {
    const char *ml = getenv("EQE_MEDIA_LIB"), *ul = getenv("EQE_UTILS_LIB");
    void *utils = dlopen(ul && *ul ? ul : EQE_UTILS_LIB, RTLD_NOW);
    void *media = dlopen(ml && *ml ? ml : EQE_MEDIA_LIB, RTLD_NOW);
    if (utils == NULL || media == NULL) {
        const char *e = dlerror();
        printf("EQE_LAB_ERR could not load Android's audio library: %s\n", e ? e : "?");
        return 2;
    }
    int n = 0;
    n += sym(utils, "_ZN7android7String8C1EPKc") != NULL;
    n += sym(utils, "_ZN7android7String8D1Ev") != NULL;
    n += sym(media, "_ZN7android11AudioSystem13setParametersEiRKNS_7String8E") != NULL;
    n += sym(media, "_ZN7android11AudioSystem13getParametersEiRKNS_7String8E") != NULL;
    printf("symbols %d of 4\n", n);
    return n == 4 ? 0 : 2;
}

/* ------------------------------------------------------------------ imports (symbol tables only) */

/* ELF32 little-endian, read field by field (no structs laid over the file). */
#define ELF_MAX_FILE (64u << 20) /* larger files are refused */
#define ELF_MAX_PH 512u          /* program headers */
#define ELF_MAX_DYN (1u << 20)   /* bytes of the dynamic segment */
#define ELF_MAX_SYMS 1000000u
#define ELF_MAX_NEEDED 1024u
#define ELF_MAX_PRINT 1024u /* characters of one name printed */

#define PT_LOAD_ 1u
#define PT_DYNAMIC_ 2u
#define DT_NULL_ 0
#define DT_NEEDED_ 1
#define DT_HASH_ 4
#define DT_STRTAB_ 5
#define DT_SYMTAB_ 6
#define DT_STRSZ_ 10
#define DT_SYMENT_ 11
#define DT_GNU_HASH_ 0x6ffffef5

typedef struct {
    uint32_t type, offset, vaddr, filesz;
} eph_t;

typedef struct {
    int fd;
    uint64_t size;
    unsigned nph;
    eph_t ph[ELF_MAX_PH];
} elf_t;

static uint32_t le32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint16_t le16(const unsigned char *p) {
    return (uint16_t)(p[0] | p[1] << 8);
}

/* reads [off, off + len) of the file; -1 if any of it lies outside the file or cannot be read */
static int elf_read(const elf_t *e, uint64_t off, uint64_t len, void *buf) {
    uint64_t got = 0;
    if (off > e->size || len > e->size - off) return -1;
    while (got < len) {
        ssize_t r = pread(e->fd, (char *)buf + got, (size_t)(len - got), (off_t)(off + got));
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        got += (uint64_t)r;
    }
    return 0;
}

/* file offset of the address range [va, va + len), which must lie in the file part of one PT_LOAD */
static int elf_v2o(const elf_t *e, uint64_t va, uint64_t len, uint64_t *off) {
    for (unsigned i = 0; i < e->nph; i++) {
        const eph_t *p = &e->ph[i];
        if (p->type != PT_LOAD_ || va < p->vaddr) continue;
        uint64_t in = va - p->vaddr;
        if (in > p->filesz || len > p->filesz - in) continue;
        *off = (uint64_t)p->offset + in;
        return 0;
    }
    return -1;
}

/* reads len bytes at the address va into a new buffer (one spare zero byte at the end) */
static unsigned char *elf_load(const elf_t *e, uint64_t va, uint64_t len) {
    uint64_t off;
    if (len > ELF_MAX_FILE || elf_v2o(e, va, len, &off) != 0) return NULL;
    unsigned char *b = malloc((size_t)len + 1);
    if (b == NULL) return NULL;
    if (elf_read(e, off, len, b) != 0) {
        free(b);
        return NULL;
    }
    b[len] = 0;
    return b;
}

static int elf_word(const elf_t *e, uint64_t va, uint32_t *w) {
    unsigned char b[4];
    uint64_t off;
    if (elf_v2o(e, va, 4, &off) != 0 || elf_read(e, off, 4, b) != 0) return -1;
    *w = le32(b);
    return 0;
}

/* the number of dynamic symbols from a DT_GNU_HASH table (there is no count in it: the highest
 * symbol in any bucket, then that symbol's chain to its end). -1 if the table is inconsistent. */
static int64_t gnu_hash_count(const elf_t *e, uint64_t va) {
    unsigned char h[16];
    uint64_t off;
    if (elf_v2o(e, va, 16, &off) != 0 || elf_read(e, off, 16, h) != 0) return -1;
    uint32_t nbuckets = le32(h), symoffset = le32(h + 4), bloom = le32(h + 8);
    if (nbuckets > ELF_MAX_SYMS || bloom > ELF_MAX_SYMS || symoffset > ELF_MAX_SYMS) return -1;
    uint64_t bva = va + 16 + (uint64_t)bloom * 4; /* ELF32: 32-bit bloom words */
    uint32_t top = 0;
    for (uint32_t i = 0; i < nbuckets; i++) {
        uint32_t b;
        if (elf_word(e, bva + (uint64_t)i * 4, &b) != 0) return -1;
        if (b > top) top = b;
    }
    if (top == 0) return symoffset; /* every bucket empty: only the symbols before symoffset */
    if (top < symoffset || top >= ELF_MAX_SYMS) return -1;
    uint64_t cva = bva + (uint64_t)nbuckets * 4;
    for (uint64_t s = top; s < ELF_MAX_SYMS; s++) {
        uint32_t c;
        if (elf_word(e, cva + (s - symoffset) * 4, &c) != 0) return -1;
        if (c & 1) return (int64_t)s + 1;
    }
    return -1;
}

static void put_name(const char *kind, const unsigned char *s) {
    char out[ELF_MAX_PRINT + 1];
    size_t n = 0;
    for (; n < ELF_MAX_PRINT && s[n]; n++) out[n] = (char)(s[n] > 0x20 && s[n] < 0x7f ? s[n] : '?');
    out[n] = 0;
    printf("%s %s\n", kind, out);
}

static int cmd_imports(const char *path) {
    static elf_t e;
    unsigned char h[52], *ph = NULL, *dyn = NULL, *str = NULL, *sym = NULL;
    uint32_t needed[ELF_MAX_NEEDED];
    unsigned nneeded = 0;
    const char *err = NULL;
    struct stat st;

    memset(&e, 0, sizeof(e));
    e.fd = open(path, O_RDONLY | O_NONBLOCK);
    if (e.fd < 0) {
        printf("EQE_LAB_ERR imports: cannot open %s: %s\n", path, strerror(errno));
        return 1;
    }
    if (fstat(e.fd, &st) != 0 || !S_ISREG(st.st_mode)) { err = "not a regular file"; goto out; }
    if (st.st_size < 0 || (uint64_t)st.st_size > ELF_MAX_FILE) { err = "larger than 64 MB"; goto out; }
    e.size = (uint64_t)st.st_size;
    if (elf_read(&e, 0, sizeof h, h) != 0) { err = "too short for an ELF header"; goto out; }
    if (h[0] != 0x7f || h[1] != 'E' || h[2] != 'L' || h[3] != 'F') { err = "not an ELF file"; goto out; }
    if (h[4] != 1) { err = "not a 32-bit ELF file"; goto out; }
    if (h[5] != 1) { err = "not a little-endian ELF file"; goto out; }
    uint32_t phoff = le32(h + 28);
    unsigned phent = le16(h + 42), phnum = le16(h + 44);
    if (phent != 32) { err = "unexpected program header size"; goto out; }
    if (phnum == 0 || phnum > ELF_MAX_PH) { err = "no program headers, or too many"; goto out; }
    ph = malloc((size_t)phnum * 32);
    if (ph == NULL) { err = "out of memory"; goto out; }
    if (elf_read(&e, phoff, (uint64_t)phnum * 32, ph) != 0) { err = "program headers outside the file"; goto out; }
    uint32_t dyn_off = 0, dyn_size = 0;
    int have_dyn = 0;
    for (unsigned i = 0; i < phnum; i++) {
        const unsigned char *p = ph + (size_t)i * 32;
        eph_t *x = &e.ph[e.nph++];
        x->type = le32(p);
        x->offset = le32(p + 4);
        x->vaddr = le32(p + 8);
        x->filesz = le32(p + 16);
        if (x->type == PT_DYNAMIC_ && !have_dyn) {
            have_dyn = 1;
            dyn_off = x->offset;
            dyn_size = x->filesz;
        }
    }
    if (!have_dyn) { err = "no dynamic section"; goto out; }
    if (dyn_size < 8 || dyn_size > ELF_MAX_DYN) { err = "unexpected dynamic section size"; goto out; }
    dyn = malloc(dyn_size);
    if (dyn == NULL) { err = "out of memory"; goto out; }
    if (elf_read(&e, dyn_off, dyn_size, dyn) != 0) { err = "dynamic section outside the file"; goto out; }

    uint32_t strtab = 0, strsz = 0, symtab = 0, syment = 16, hash = 0, gnuhash = 0;
    int have_strtab = 0, have_strsz = 0, have_symtab = 0, have_hash = 0, have_gnuhash = 0;
    for (uint32_t i = 0; i + 8 <= dyn_size; i += 8) {
        int32_t tag = (int32_t)le32(dyn + i);
        uint32_t val = le32(dyn + i + 4);
        if (tag == DT_NULL_) break;
        switch (tag) {
        case DT_NEEDED_:
            if (nneeded >= ELF_MAX_NEEDED) { err = "too many needed libraries"; goto out; }
            needed[nneeded++] = val;
            break;
        case DT_STRTAB_: if (!have_strtab) { strtab = val; have_strtab = 1; } break;
        case DT_STRSZ_: if (!have_strsz) { strsz = val; have_strsz = 1; } break;
        case DT_SYMTAB_: if (!have_symtab) { symtab = val; have_symtab = 1; } break;
        case DT_SYMENT_: syment = val; break;
        case DT_HASH_: if (!have_hash) { hash = val; have_hash = 1; } break;
        case DT_GNU_HASH_: if (!have_gnuhash) { gnuhash = val; have_gnuhash = 1; } break;
        default: break;
        }
    }
    if (!have_strtab || !have_strsz || strsz == 0) { err = "no dynamic string table"; goto out; }
    str = elf_load(&e, strtab, strsz);
    if (str == NULL) { err = "dynamic string table outside the file"; goto out; }
    for (unsigned i = 0; i < nneeded; i++)
        if (needed[i] >= strsz) { err = "a needed library's name lies outside the string table"; goto out; }

    uint64_t nsyms = 0;
    if (have_symtab) {
        if (syment != 16) { err = "unexpected symbol entry size"; goto out; }
        if (have_hash) {
            uint32_t nchain;
            if (elf_word(&e, (uint64_t)hash + 4, &nchain) != 0) { err = "hash table outside the file"; goto out; }
            nsyms = nchain;
        } else if (have_gnuhash) {
            int64_t n = gnu_hash_count(&e, gnuhash);
            if (n < 0) { err = "GNU hash table outside the file or inconsistent"; goto out; }
            nsyms = (uint64_t)n;
        } else {
            err = "no hash table, so the number of symbols is not known";
            goto out;
        }
        if (nsyms > ELF_MAX_SYMS) { err = "too many symbols"; goto out; }
        if (nsyms > 0) {
            sym = elf_load(&e, symtab, nsyms * 16);
            if (sym == NULL) { err = "symbol table outside the file"; goto out; }
            for (uint64_t i = 0; i < nsyms; i++)
                if (le32(sym + i * 16) >= strsz) { err = "a symbol's name lies outside the string table"; goto out; }
        }
    }

    /* everything checked: print */
    for (unsigned i = 0; i < nneeded; i++)
        if (str[needed[i]]) put_name("needed", str + needed[i]);
    for (uint64_t i = 1; i < nsyms; i++) {
        const unsigned char *s = sym + i * 16;
        const unsigned char *name = str + le32(s);
        unsigned bind = s[12] >> 4, type = s[12] & 0xf, vis = s[13] & 3, shndx = le16(s + 14);
        if (!*name) continue;
        if (shndx == 0)
            put_name("import", name);
        else if ((bind == 1 || bind == 2) && (type == 1 || type == 2) && vis != 1 && vis != 2)
            put_name("export", name);
    }

out:
    if (err != NULL) printf("EQE_LAB_ERR imports: %s\n", err);
    free(ph);
    free(dyn);
    free(str);
    free(sym);
    close(e.fd);
    return err != NULL ? 1 : 0;
}

static int usage(void) {
    fprintf(stderr, "usage: eqe_lab rate [ms] | get <io> <keys> | set <io> <key=value> | check | umount <path> | imports <file>"
                    " | cpcheck <watch> <copy>\n");
    return 2;
}

/* "cpcheck <watch> <copy>": the CarPlay watch loads here, finds all 7 of the car's TinyALSA functions
   it hands its calls on to, and checks the copy of the factory library it loads in the CarPlay app
   (eqe_cpw_check). 0 = all good. */
static int cmd_cpcheck(const char *path, const char *copy) {
    if (path[0] != '/' || copy[0] != '/') return usage();
    void *h = dlopen(path, RTLD_NOW);
    if (h == NULL) {
        const char *e = dlerror();
        printf("cpcheck failed: it does not load: %s\n", e ? e : "?");
        return 1;
    }
    void *p = dlsym(h, "eqe_cpw_check");
    int (*check)(const char *, char *, int);
    if (p == NULL) {
        printf("cpcheck failed: it is not the CarPlay watch (no eqe_cpw_check)\n");
        return 1;
    }
    memcpy(&check, &p, sizeof(p));
    char msg[400];
    msg[0] = 0;
    int good = check(copy, msg, (int)sizeof(msg));
    printf("cpcheck %s %s\n", good ? "ok" : "failed:", msg);
    return good ? 0 : 1;
}

/* "umount <path>": only the files EQ Engine lays bind mounts over (tests put them under a root). */
static int cmd_umount(const char *path) {
    static const char *const kOurs[] = {"/system/lib/hw/audio.primary.tcc803x.so",
                                        "/system/etc/audio_effects.conf", "/system/etc/audio_policy.conf",
                                        "/system/lib/libCarPlayAndroid.so"};
    size_t n = strlen(path), i;
    int ours = 0;
    if (path[0] != '/' || strstr(path, "..") != NULL) return usage();
    for (i = 0; i < sizeof kOurs / sizeof kOurs[0]; i++) {
        size_t m = strlen(kOurs[i]);
        if (n >= m && strcmp(path + n - m, kOurs[i]) == 0) ours = 1;
    }
    if (!ours) return usage();
    if (umount2(path, MNT_DETACH) != 0) {
        printf("failed: %s\n", strerror(errno));
        return 1;
    }
    printf("detached %s\n", path);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "check") == 0) return cmd_check();
    if (argc == 3 && strcmp(argv[1], "umount") == 0) return cmd_umount(argv[2]);
    if (argc == 3 && strcmp(argv[1], "imports") == 0) return cmd_imports(argv[2]);
    if (argc == 4 && strcmp(argv[1], "cpcheck") == 0) return cmd_cpcheck(argv[2], argv[3]);
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
