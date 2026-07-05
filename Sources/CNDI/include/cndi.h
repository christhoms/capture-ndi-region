// Minimal declarations of the NDI 5.x C ABI (Processing.NDI.Lib.h subset).
// The runtime library is loaded with dlopen at launch, so no NDI SDK is
// required to build. Struct layouts must match the official headers exactly.
#ifndef CNDI_H
#define CNDI_H

#include <stdbool.h>
#include <stdint.h>

typedef struct NDIlib_send_create_t {
    const char *p_ndi_name;
    const char *p_groups;
    bool clock_video;
    bool clock_audio;
} NDIlib_send_create_t;

// NDIlib_frame_format_type_e
#define CNDI_FRAME_FORMAT_PROGRESSIVE 1

// NDIlib_send_timecode_synthesize
#define CNDI_TIMECODE_SYNTHESIZE INT64_MAX

typedef struct NDIlib_video_frame_v2_t {
    int xres;
    int yres;
    uint32_t FourCC;
    int frame_rate_N;
    int frame_rate_D;
    float picture_aspect_ratio;
    int frame_format_type;
    int64_t timecode;
    uint8_t *p_data;
    int line_stride_in_bytes;
    const char *p_metadata;
    int64_t timestamp;
} NDIlib_video_frame_v2_t;

typedef bool (*NDIlib_initialize_fn)(void);
typedef void (*NDIlib_destroy_fn)(void);
typedef void *(*NDIlib_send_create_fn)(const NDIlib_send_create_t *);
typedef void (*NDIlib_send_destroy_fn)(void *);
typedef void (*NDIlib_send_send_video_v2_fn)(void *, const NDIlib_video_frame_v2_t *);

#endif
