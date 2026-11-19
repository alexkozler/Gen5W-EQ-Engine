/*
 * alsactl_dump: read-only listing of an ALSA card's mixer controls (what tinymix would show).
 * Usage: alsactl_dump [/dev/snd/controlC0]
 * Prints the card info, then one line per control: number, name, type, range or items, and the
 * current value(s). It only reads (ELEM_LIST / ELEM_INFO / ELEM_READ); it never writes a control.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <sound/asound.h>

static const char *type_name(int t) {
    switch (t) {
    case SNDRV_CTL_ELEM_TYPE_BOOLEAN: return "bool";
    case SNDRV_CTL_ELEM_TYPE_INTEGER: return "int";
    case SNDRV_CTL_ELEM_TYPE_ENUMERATED: return "enum";
    case SNDRV_CTL_ELEM_TYPE_BYTES: return "bytes";
    case SNDRV_CTL_ELEM_TYPE_IEC958: return "iec958";
    case SNDRV_CTL_ELEM_TYPE_INTEGER64: return "int64";
    default: return "other";
    }
}

int main(int argc, char **argv) {
    const char *dev = argc > 1 ? argv[1] : "/dev/snd/controlC0";
    int fd = open(dev, O_RDONLY);
    if (fd < 0) {
        printf("cannot open %s: %s\n", dev, strerror(errno));
        return 1;
    }
    struct snd_ctl_card_info info;
    memset(&info, 0, sizeof(info));
    if (ioctl(fd, SNDRV_CTL_IOCTL_CARD_INFO, &info) == 0)
        printf("card %d: id '%s', driver '%s', name '%s', mixer '%s'\n", info.card, (char *)info.id, (char *)info.driver,
               (char *)info.name, (char *)info.mixername);
    struct snd_ctl_elem_list list;
    memset(&list, 0, sizeof(list));
    if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &list) < 0) {
        printf("listing controls failed: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    unsigned n = list.count;
    printf("controls: %u\n", n);
    if (n == 0) {
        close(fd);
        return 0;
    }
    struct snd_ctl_elem_id *ids = calloc(n, sizeof(*ids));
    if (!ids) return 1;
    list.space = n;
    list.offset = 0;
    list.pids = ids;
    if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &list) < 0) {
        printf("listing controls failed: %s\n", strerror(errno));
        free(ids);
        close(fd);
        return 1;
    }
    for (unsigned i = 0; i < list.used; i++) {
        struct snd_ctl_elem_info ei;
        memset(&ei, 0, sizeof(ei));
        ei.id = ids[i];
        if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &ei) < 0) {
            printf("%u '%s': info failed (%s)\n", ids[i].numid, (char *)ids[i].name, strerror(errno));
            continue;
        }
        printf("%u '%s' %s x%u", ei.id.numid, (char *)ei.id.name, type_name(ei.type), ei.count);
        if (ei.type == SNDRV_CTL_ELEM_TYPE_INTEGER)
            printf(" range %ld..%ld step %ld", ei.value.integer.min, ei.value.integer.max, ei.value.integer.step);
        if (ei.type == SNDRV_CTL_ELEM_TYPE_ENUMERATED) {
            unsigned items = ei.value.enumerated.items;
            printf(" items:");
            for (unsigned k = 0; k < items && k < 32; k++) {
                struct snd_ctl_elem_info en;
                memset(&en, 0, sizeof(en));
                en.id = ei.id;
                en.value.enumerated.item = k;
                if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &en) == 0) printf(" [%u]'%s'", k, en.value.enumerated.name);
            }
        }
        if (ei.access & SNDRV_CTL_ELEM_ACCESS_READ) {
            struct snd_ctl_elem_value v;
            memset(&v, 0, sizeof(v));
            v.id = ei.id;
            if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_READ, &v) == 0) {
                printf(" =");
                unsigned cnt = ei.count > 32 ? 32 : ei.count;
                for (unsigned k = 0; k < cnt; k++) {
                    switch (ei.type) {
                    case SNDRV_CTL_ELEM_TYPE_BOOLEAN:
                    case SNDRV_CTL_ELEM_TYPE_INTEGER: printf(" %ld", v.value.integer.value[k]); break;
                    case SNDRV_CTL_ELEM_TYPE_INTEGER64: printf(" %lld", (long long)v.value.integer64.value[k]); break;
                    case SNDRV_CTL_ELEM_TYPE_ENUMERATED: printf(" %u", v.value.enumerated.item[k]); break;
                    case SNDRV_CTL_ELEM_TYPE_BYTES: printf(" %02x", v.value.bytes.data[k]); break;
                    default: break;
                    }
                }
            } else {
                printf(" (read failed: %s)", strerror(errno));
            }
        } else {
            printf(" (write-only)");
        }
        printf("\n");
    }
    free(ids);
    close(fd);
    return 0;
}
