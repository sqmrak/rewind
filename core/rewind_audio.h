#ifndef REWIND_AUDIO_H
#define REWIND_AUDIO_H

#include <stddef.h>
#include <stdint.h>

int rewind_audio_index_range(const char *text, uint64_t *start, uint64_t *end);
int rewind_audio_video_id(const char *text);

int rewind_audio_content_range(const char *text, uint64_t start, uint64_t end,
                                size_t length, uint64_t *total);
int rewind_audio_mp4(const uint8_t *data, size_t length);
int rewind_audio_segment(const uint8_t *data, size_t length);

typedef enum {
    REWIND_AUDIO_HLS_INVALID = 0,
    REWIND_AUDIO_HLS_MASTER,
    REWIND_AUDIO_HLS_MEDIA
} rewind_audio_hls_kind_t;

/* audio rendition for a master, first and last segment for a complete media playlist */
rewind_audio_hls_kind_t rewind_audio_hls(const char *text, size_t length,
                                        char *first, size_t first_capacity,
                                        char *last, size_t last_capacity);

#endif
