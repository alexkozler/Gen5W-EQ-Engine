#pragma once
#include <stdio.h>
#include <stdlib.h>
#ifndef LOG_TAG
#define LOG_TAG "?"
#endif
#define ALOGV(...) ((void)0)
#define ALOGD(...) (fprintf(stderr, "D/" LOG_TAG ": " __VA_ARGS__), fputc('\n', stderr))
#define ALOGI(...) (fprintf(stderr, "I/" LOG_TAG ": " __VA_ARGS__), fputc('\n', stderr))
#define ALOGW(...) (fprintf(stderr, "W/" LOG_TAG ": " __VA_ARGS__), fputc('\n', stderr))
#define ALOGE(...) (fprintf(stderr, "E/" LOG_TAG ": " __VA_ARGS__), fputc('\n', stderr))
#define LOG_ALWAYS_FATAL_IF(c, ...) do { if (c) { ALOGE(__VA_ARGS__); abort(); } } while (0)
