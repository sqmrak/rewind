#ifndef REWIND_SABR_H
#define REWIND_SABR_H

#include "rewind_fmp4.h"

typedef struct rewind_sabr rewind_sabr_t;
typedef enum {
    REWIND_SABR_PROGRESS = 0,
    REWIND_SABR_READY,
    REWIND_SABR_NO_PROGRESS,
    REWIND_SABR_INVALID,
    REWIND_SABR_REMOTE_ERROR,
    REWIND_SABR_NO_MEMORY,
    REWIND_SABR_AUTH_REQUIRED
} rewind_sabr_status_t;

/* one request asks for one segment: it declares segments 1..claimed_segments as already
   buffered (claimed_ms of the track timeline) and the server answers with the next one.
   segment 0 is the first request, with no claims, which brings the init segment and segment 1.
   a request must not claim an init segment the client does not have, the server then never sends it */
typedef struct {
    int64_t segment;
    int64_t claimed_segments;
    int64_t claimed_ms;
} rewind_sabr_request_t;

typedef enum {
    REWIND_SABR_PLAN_REQUEST = 0,   /* *out is a request to send now */
    REWIND_SABR_PLAN_WAIT,          /* nothing to ask until an in flight request is done */
    REWIND_SABR_PLAN_DONE,
    REWIND_SABR_PLAN_EXHAUSTED      /* a segment used up its attempts */
} rewind_sabr_plan_t;

rewind_sabr_t *rewind_sabr_create(int32_t itag);
void rewind_sabr_free(rewind_sabr_t *stream);
rewind_sabr_status_t rewind_sabr_feed(rewind_sabr_t *stream, const uint8_t *data, size_t length,
                                     char *redirect, size_t redirect_capacity);
int64_t rewind_sabr_segment(const rewind_sabr_t *stream);
int64_t rewind_sabr_duration_ms(const rewind_sabr_t *stream);
const rewind_fmp4_t *rewind_sabr_file(const rewind_sabr_t *stream);
const uint8_t *rewind_sabr_source(const rewind_sabr_t *stream);

/* none of these are thread safe, the caller serializes feed, planning and completion */
rewind_sabr_plan_t rewind_sabr_next_request(rewind_sabr_t *stream, rewind_sabr_request_t *out);
void rewind_sabr_request_done(rewind_sabr_t *stream, const rewind_sabr_request_t *request);
size_t rewind_sabr_have_count(const rewind_sabr_t *stream);
/* segments received in order from the start, the part a preview can cover */
size_t rewind_sabr_contiguous(const rewind_sabr_t *stream);
/* a plain m4a of the first count segments, to be freed by the caller; its chunks point into
   rewind_sabr_data, which stays valid while the stream lives. NULL when that many are not in yet */
rewind_fmp4_t *rewind_sabr_prefix(const rewind_sabr_t *stream, size_t count);
const uint8_t *rewind_sabr_data(const rewind_sabr_t *stream);
size_t rewind_sabr_expected(const rewind_sabr_t *stream);

#endif
