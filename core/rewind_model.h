#ifndef REWIND_MODEL_H
#define REWIND_MODEL_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define REWIND_VIDEO_ID_MAX 32
#define REWIND_TITLE_MAX    256
#define REWIND_ARTIST_MAX   256
#define REWIND_ALBUM_MAX    256

typedef struct {
    char video_id[REWIND_VIDEO_ID_MAX];
    char title[REWIND_TITLE_MAX];
    char artist[REWIND_ARTIST_MAX];
    char album[REWIND_ALBUM_MAX];
    unsigned duration_sec;
} rewind_track_t;

/* clear the fixed record so old callers can reuse one stack object */
void rewind_track_init(rewind_track_t *track);

/* avoid hidden allocations so callers can use fixed buffers */
int rewind_track_set_text(char *dst, size_t cap, const char *src);

/* keep duration parsing here because api responses use ISO-8601 strings */
int rewind_duration_parse(const char *text, unsigned *out_seconds);

#ifdef __cplusplus
}
#endif

#endif /* rewind_model_h */
