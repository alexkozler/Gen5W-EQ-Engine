/* Parse audio_effects.conf with Android 4.4.2's own config_utils, the way EffectsFactory.c walks it. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <cutils/config_utils.h>
#include <cutils/misc.h>
#include "../../native/fx44.h"
#include "stringToUuid.inc"
int main(int argc, char **argv) {
    char *data = load_file(argv[1], NULL);
    if (!data) { printf("cannot read\n"); return 1; }
    cnode *root = config_node("", "");
    config_load(root, data);
    cnode *libs = config_find(root, "libraries"), *fx = config_find(root, "effects");
    printf("libraries:");
    for (cnode *n = libs ? libs->first_child : NULL; n; n = n->next) {
        cnode *p = config_find(n, "path");
        printf(" %s=%s", n->name, p ? p->value : "(no path)");
    }
    printf("\neffects:");
    int found = 0;
    for (cnode *n = fx ? fx->first_child : NULL; n; n = n->next) {
        cnode *l = config_find(n, "library"), *u = config_find(n, "uuid");
        printf(" %s(%s)", n->name, l ? l->value : "?");
        if (!strcmp(n->name, "eqengine") && u) {
            effect_uuid_t id;
            static const effect_uuid_t want = { 0x64b3439e, 0x9662, 0x4040, 0x9fd1, { 0x83, 0xf1, 0x16, 0xf7, 0x49, 0x88 } };
            if (stringToUuid(u->value, &id) == 0 && memcmp(&id, &want, sizeof(id)) == 0) found = 1;
        }
    }
    printf("\neqengine uuid parses and matches the library: %s\n", found ? "yes" : "no");
    return 0;
}
