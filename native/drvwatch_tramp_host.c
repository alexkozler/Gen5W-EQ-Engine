/* PC test builds: no forwarders (they are ARM code). */
int drvwatch_tramp_count = 0;
int drvwatch_tramp_resolve(void *so) {
    (void)so;
    return 0;
}
