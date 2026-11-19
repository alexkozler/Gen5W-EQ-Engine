/* Host stand-in for <android/log.h> */
#pragma once
#include <stdarg.h>
#include <stdio.h>
#define ANDROID_LOG_INFO 4
#define ANDROID_LOG_WARN 5
static inline int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    va_list ap;
    (void)prio;
    fprintf(stderr, "[%s] ", tag);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
    return 0;
}
