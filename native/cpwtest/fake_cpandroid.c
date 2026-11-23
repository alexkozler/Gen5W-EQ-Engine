/* A stand-in for the factory libCarPlayAndroid.so (built as libCarPlayAndroid.car.so, the name the
   watch loads the car's copy under, needing libCarPlayAudio.so like the car's). Its JNI_OnLoad notes
   what it was given and returns JNI_VERSION_1_6, as a JNI library does after registering its
   native methods. Built without -DNEEDS_AUDIO for the check's "does not need" case. */
#ifdef NEEDS_AUDIO
int cpa_play(double secs);
/* keeps the link to libCarPlayAudio.so (--as-needed would drop a library nothing uses) */
int (*fake_keep_audio)(double) = cpa_play;
#endif

static void *g_vm;
static int g_calls;

int JNI_OnLoad(void *vm, void *reserved) {
    (void)reserved;
    g_vm = vm;
    g_calls++;
    return 0x10006;
}

void *fake_onload_vm(void) { return g_vm; }
int fake_onload_calls(void) { return g_calls; }
