/*
 * Test-only: Hyundai's audio_hw_device as the car logs showed it. It has 19 function entries after
 * "common", where Android 4.4 has 18. Entries 0 to 5 are where Android 4.4 has them; from
 * set_parameters on, everything sits one further. Entry 8 is Hyundai's extra one,
 * set_mic_control(type, value) (0.6.1 logs); 6 and 7 are presumably the microphone mute pair.
 */
#pragma once
#include <stdbool.h>
#include <hardware/audio.h>

struct hy_dev {
    struct hw_device_t common;
    uint32_t (*get_supported_devices)(const struct hy_dev *d);
    int (*init_check)(const struct hy_dev *d);
    int (*set_voice_volume)(struct hy_dev *d, float v);
    int (*set_master_volume)(struct hy_dev *d, float v);
    int (*get_master_volume)(struct hy_dev *d, float *v);
    int (*set_mode)(struct hy_dev *d, audio_mode_t m);
    int (*set_mic_mute)(struct hy_dev *d, bool m);
    int (*get_mic_mute)(const struct hy_dev *d, bool *m);
    int (*set_mic_control)(struct hy_dev *d, int type, int value); /* Hyundai's extra entry */
    int (*set_parameters)(struct hy_dev *d, const char *kv);
    char *(*get_parameters)(const struct hy_dev *d, const char *keys);
    size_t (*get_input_buffer_size)(const struct hy_dev *d, const struct audio_config *c);
    int (*open_output_stream)(struct hy_dev *d, audio_io_handle_t h, audio_devices_t devs, audio_output_flags_t flags,
                              struct audio_config *c, struct audio_stream_out **out);
    void (*close_output_stream)(struct hy_dev *d, struct audio_stream_out *s);
    int (*open_input_stream)(struct hy_dev *d, audio_io_handle_t h, audio_devices_t devs, struct audio_config *c,
                             struct audio_stream_in **in);
    void (*close_input_stream)(struct hy_dev *d, struct audio_stream_in *s);
    int (*dump)(const struct hy_dev *d, int fd);
    int (*set_master_mute)(struct hy_dev *d, bool m);
    int (*get_master_mute)(struct hy_dev *d, bool *m);
};
