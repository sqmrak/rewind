#ifndef TUNETUBE_MODEL_H
#define TUNETUBE_MODEL_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TUNETUBE_VIDEO_ID_MAX 32
#define TUNETUBE_TITLE_MAX    256
#define TUNETUBE_ARTIST_MAX   256
#define TUNETUBE_ALBUM_MAX    256

typedef struct {
    char video_id[TUNETUBE_VIDEO_ID_MAX];
    char title[TUNETUBE_TITLE_MAX];
    char artist[TUNETUBE_ARTIST_MAX];
    char album[TUNETUBE_ALBUM_MAX];
    unsigned duration_sec;
} tunetube_track_t;

/* clear the fixed record so old callers can reuse one stack object */
void tunetube_track_init(tunetube_track_t *track);

/* avoid hidden allocations so callers can use fixed buffers */
int tunetube_track_set_text(char *dst, size_t cap, const char *src);

/* keep duration parsing here because api responses use ISO-8601 strings */
int tunetube_duration_parse(const char *text, unsigned *out_seconds);

#ifdef __cplusplus
}
#endif

#endif /* tunetube_model_h */
