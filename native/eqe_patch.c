/*
 * eqe_patch <src> <dst> <offset> <old> <new>: copies src to dst with the bytes at offset
 * changed from old to new (same length), only if src has exactly old there. Used by the Lab's
 * 48 kHz test to make its in-memory copy of Android's audio policy (one number changed);
 * act.sh then checks the copy's md5. Exit 0 = written, 1 = refused, 2 = usage or I/O error.
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "usage: eqe_patch <src> <dst> <offset> <old> <new>\n");
        return 2;
    }
    static char buf[1 << 20];
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) {
        perror(argv[1]);
        return 2;
    }
    size_t n = 0;
    for (;;) {
        ssize_t r = read(fd, buf + n, sizeof(buf) - n);
        if (r < 0) {
            perror("read");
            close(fd);
            return 2;
        }
        if (r == 0) break;
        n += (size_t)r;
        if (n == sizeof(buf)) {
            fprintf(stderr, "%s is too big\n", argv[1]);
            close(fd);
            return 2;
        }
    }
    close(fd);
    char *end;
    unsigned long off = strtoul(argv[3], &end, 10);
    size_t lo = strlen(argv[4]), ln = strlen(argv[5]);
    if (*end != 0 || lo == 0 || lo != ln || off + lo > n) {
        fprintf(stderr, "bad offset or lengths\n");
        return 2;
    }
    if (memcmp(buf + off, argv[4], lo) != 0) {
        fprintf(stderr, "refused: %s does not have \"%s\" at %lu\n", argv[1], argv[4], off);
        return 1;
    }
    memcpy(buf + off, argv[5], ln);
    fd = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        perror(argv[2]);
        return 2;
    }
    size_t w = 0;
    while (w < n) {
        ssize_t r = write(fd, buf + w, n - w);
        if (r <= 0) {
            perror("write");
            close(fd);
            return 2;
        }
        w += (size_t)r;
    }
    fsync(fd);
    close(fd);
    return 0;
}
