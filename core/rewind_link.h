#ifndef REWIND_LINK_H
#define REWIND_LINK_H

#include <stddef.h>

#define REWIND_LINK_ID_MAX 64

typedef struct {
    /* "" when the link names no video or no list */
    char video_id[REWIND_LINK_ID_MAX];
    char list_id[REWIND_LINK_ID_MAX];
} rewind_link;

/* reads a youtube watch, playlist, short or youtu.be link, or the same link behind the rewind:// scheme; returns 1 when it holds a
   video id or a list id, else 0 with an empty result. the text is not a c string: len bounds every read */
int rewind_link_parse(const char *text, size_t len, rewind_link *out);

#endif
