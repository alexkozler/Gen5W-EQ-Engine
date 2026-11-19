/* Stand-ins for the car's libutils (String8) and libmedia (AudioSystem::set/getParameters), with the
 * same symbol names, for tests/lab/run.sh. Each call is written to $FAKE_LOG.
 * Built twice: as libutils (-DUTILS) and as libmedia (-DMEDIA; -DNO_GET leaves getParameters out). */
#define _POSIX_C_SOURCE 200809L /* strdup */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char *str;
} string8;

static void note(const char *fmt, const char *a, int io) {
    const char *p = getenv("FAKE_LOG");
    FILE *f = p ? fopen(p, "a") : NULL;
    if (!f) return;
    fprintf(f, fmt, io, a);
    fputc('\n', f);
    fclose(f);
}

#ifdef UTILS
void s8_ctor(string8 *s, const char *t) __asm__("_ZN7android7String8C1EPKc");
void s8_dtor(string8 *s) __asm__("_ZN7android7String8D1Ev");
void s8_ctor(string8 *s, const char *t) { s->str = strdup(t); }
void s8_dtor(string8 *s) {
    free((void *)s->str);
    s->str = NULL;
}
#endif

#ifdef MEDIA
int as_set(int io, const string8 *kv) __asm__("_ZN7android11AudioSystem13setParametersEiRKNS_7String8E");
int as_set(int io, const string8 *kv) {
    note("set io %d \"%s\"", kv->str, io);
    const char *st = getenv("FAKE_SET_STATUS");
    return st ? atoi(st) : 0;
}
#ifndef NO_GET
void as_get(string8 *ret, int io, const string8 *keys) __asm__("_ZN7android11AudioSystem13getParametersEiRKNS_7String8E");
void as_get(string8 *ret, int io, const string8 *keys) {
    note("get io %d \"%s\"", keys->str, io);
    char b[200];
    snprintf(b, sizeof(b), "%s=44100", keys->str);
    ret->str = strdup(b);
}
#endif
#endif
