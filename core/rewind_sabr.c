#include "rewind_sabr.h"
#include "rewind_ump.h"

#include <stdlib.h>
#include <string.h>

struct rewind_sabr {
    int32_t itag;
    rewind_fmp4_t *file;
    uint8_t *source;
    size_t source_length;
    size_t expected;
    size_t init_length;
    int64_t last_segment;
    int64_t duration_ms;
    int ready;
    /* per segment, index = segment number - 1 */
    uint8_t *state;
    uint8_t *attempts;
    size_t have_count;
    int bootstrap_inflight;
    int bootstrap_attempts;
};

enum { SEGMENT_MISSING = 0, SEGMENT_INFLIGHT, SEGMENT_HAVE };
enum { MAX_ATTEMPTS = 3 };

typedef struct {
    rewind_ump_media_header_t header;
    uint8_t *bytes;
    size_t used;
    int ended;
} segment_t;

typedef struct {
    rewind_sabr_t *stream;
    segment_t segments[32];
    size_t count;
    size_t allocated;
    rewind_sabr_status_t error;
    char *redirect;
    size_t redirect_capacity;
} round_t;

rewind_sabr_t *rewind_sabr_create(int32_t itag) {
    if (itag <= 0) return NULL;
    rewind_sabr_t *stream = calloc(1, sizeof(*stream));
    if (stream) stream->itag = itag;
    return stream;
}

void rewind_sabr_free(rewind_sabr_t *stream) {
    if (!stream) return;
    free(stream->state);
    free(stream->attempts);
    rewind_fmp4_free(stream->file);
    free(stream->source);
    free(stream);
}

static void on_part(const rewind_ump_part_t *part, void *context) {
    round_t *round = context;
    size_t i;
    uint64_t id = 0;
    if (round->error != REWIND_SABR_PROGRESS) return;
    if (part->type == REWIND_UMP_STREAM_PROTECTION) {
        uint32_t status;
        if (!rewind_ump_parse_stream_protection(part->data, part->length, &status))
            round->error = REWIND_SABR_INVALID;
        /* 2 is attestation pending, the first segments still come; 3 means the token is required now */
        else if (status == 3) round->error = REWIND_SABR_AUTH_REQUIRED;
    } else if (part->type == REWIND_UMP_SABR_ERROR) {
        round->error = REWIND_SABR_REMOTE_ERROR;
    } else if (part->type == REWIND_UMP_SABR_REDIRECT) {
        if (!rewind_ump_parse_sabr_redirect(part->data, part->length, round->redirect, round->redirect_capacity))
            round->error = REWIND_SABR_INVALID;
    } else if (part->type == REWIND_UMP_MEDIA_HEADER) {
        rewind_ump_media_header_t header;
        if (round->count == 32 || !rewind_ump_parse_media_header(part->data, part->length, &header) ||
            header.header_id < 0 || header.header_id > 255) {
            round->error = REWIND_SABR_INVALID;
            return;
        }
        for (i = 0; i < round->count; ++i) {
            if (round->segments[i].header.header_id == header.header_id) {
                round->error = REWIND_SABR_INVALID;
                return;
            }
        }
        segment_t *segment = &round->segments[round->count++];
        segment->header = header;
        if (header.itag == round->stream->itag) {
            if (header.segment_length_bytes <= 0 || (uint64_t)header.segment_length_bytes > 4 * 1024 * 1024 - round->allocated) {
                round->error = REWIND_SABR_INVALID;
                return;
            }
            round->allocated += (size_t)header.segment_length_bytes;
            segment->bytes = malloc((size_t)header.segment_length_bytes);
            if (!segment->bytes) round->error = REWIND_SABR_NO_MEMORY;
        }
    } else if (part->type == REWIND_UMP_MEDIA || part->type == REWIND_UMP_MEDIA_END) {
        if (!rewind_ump_media_header_id(part->data, part->length, &id) ||
            (part->type == REWIND_UMP_MEDIA_END && part->length != 1)) {
            round->error = REWIND_SABR_INVALID;
            return;
        }
        for (i = 0; i < round->count; ++i) {
            segment_t *segment = &round->segments[i];
            if ((uint64_t)segment->header.header_id != id) continue;
            if (!segment->bytes) return;
            if (segment->ended || part->length - 1 > (size_t)segment->header.segment_length_bytes - segment->used) {
                round->error = REWIND_SABR_INVALID;
                return;
            }
            if (part->type == REWIND_UMP_MEDIA_END) {
                segment->ended = 1;
            } else {
                memcpy(segment->bytes + segment->used, part->data + 1, part->length - 1);
                segment->used += part->length - 1;
            }
            return;
        }
        round->error = REWIND_SABR_INVALID;
    }
}

static rewind_sabr_status_t initialize(rewind_sabr_t *stream, const segment_t *segment) {
    rewind_fmp4_t *file = NULL;
    size_t needed = 0, count;
    uint64_t total;
    if (rewind_fmp4_open(segment->bytes, segment->used, &needed, &file) != REWIND_FMP4_OK)
        return REWIND_SABR_INVALID;
    count = rewind_fmp4_fragment_count(file);
    if (!count) {
        rewind_fmp4_free(file);
        return REWIND_SABR_INVALID;
    }
    total = rewind_fmp4_fragment_offset(file, count - 1) + rewind_fmp4_fragment_size(file, count - 1);
    if (total < segment->used || total > 32 * 1024 * 1024) {
        rewind_fmp4_free(file);
        return REWIND_SABR_INVALID;
    }
    stream->source = calloc(1, (size_t)total);
    stream->state = calloc(count, 1);
    stream->attempts = calloc(count, 1);
    if (!stream->source || !stream->state || !stream->attempts) {
        free(stream->source);
        free(stream->state);
        free(stream->attempts);
        stream->source = NULL;
        stream->state = NULL;
        stream->attempts = NULL;
        rewind_fmp4_free(file);
        return REWIND_SABR_NO_MEMORY;
    }
    stream->file = file;
    stream->expected = count;
    stream->init_length = segment->used;
    stream->source_length = (size_t)total;
    memcpy(stream->source, segment->bytes, segment->used);
    return REWIND_SABR_PROGRESS;
}

/* the sidx knows every fragment's size and place, so a segment may arrive in any order */
static rewind_sabr_status_t add_segment(rewind_sabr_t *stream, const segment_t *segment) {
    const rewind_ump_media_header_t *header = &segment->header;
    uint64_t offset, size;
    int64_t start;
    if (header->segment_number <= 0 || (uint64_t)header->segment_number > stream->expected)
        return REWIND_SABR_INVALID;
    size_t index = (size_t)header->segment_number - 1;
    offset = rewind_fmp4_fragment_offset(stream->file, index);
    size = rewind_fmp4_fragment_size(stream->file, index);
    if (size != segment->used || offset > stream->source_length || size > stream->source_length - offset)
        return REWIND_SABR_INVALID;
    if (stream->state[index] == SEGMENT_HAVE)
        return memcmp(stream->source + offset, segment->bytes, segment->used) == 0
            ? REWIND_SABR_NO_PROGRESS : REWIND_SABR_INVALID;
    start = rewind_fmp4_fragment_start_ms(stream->file, index);
    if (header->start_ms < 0 || header->duration_ms <= 0 || start < 0 ||
        header->start_ms < start - 3 || header->start_ms > start + 3 ||
        header->duration_ms > INT64_MAX - header->start_ms)
        return REWIND_SABR_INVALID;
    memcpy(stream->source + offset, segment->bytes, segment->used);
    stream->state[index] = SEGMENT_HAVE;
    ++stream->have_count;
    return REWIND_SABR_PROGRESS;
}

/* the plain m4a rebuild reads fragments strictly in order */
static rewind_sabr_status_t commit_prefix(rewind_sabr_t *stream) {
    while ((size_t)stream->last_segment < stream->expected &&
           stream->state[stream->last_segment] == SEGMENT_HAVE) {
        size_t index = (size_t)stream->last_segment, needed = 0;
        uint64_t offset = rewind_fmp4_fragment_offset(stream->file, index);
        uint64_t size = rewind_fmp4_fragment_size(stream->file, index);
        if (rewind_fmp4_add_fragment(stream->file, index, stream->source + offset, (size_t)size, &needed) != REWIND_FMP4_OK)
            return REWIND_SABR_INVALID;
        stream->last_segment = (int64_t)index + 1;
        stream->duration_ms = rewind_fmp4_fragment_start_ms(stream->file, index + 1);
    }
    return REWIND_SABR_PROGRESS;
}

rewind_sabr_status_t rewind_sabr_feed(rewind_sabr_t *stream, const uint8_t *data, size_t length,
                                     char *redirect, size_t redirect_capacity) {
    round_t round;
    size_t i;
    size_t have_before;
    int stored = 0;
    rewind_sabr_status_t status = REWIND_SABR_NO_PROGRESS;
    if (redirect && redirect_capacity) redirect[0] = 0;
    if (!stream || stream->ready || !data || !length || length > 4 * 1024 * 1024 || !redirect || !redirect_capacity)
        return REWIND_SABR_INVALID;
    memset(&round, 0, sizeof(round));
    round.stream = stream;
    round.redirect = redirect;
    round.redirect_capacity = redirect_capacity;
    have_before = stream->have_count;
    if (rewind_ump_parse(data, length, on_part, &round) != length && round.error == REWIND_SABR_PROGRESS)
        round.error = REWIND_SABR_INVALID;
    if (round.error != REWIND_SABR_PROGRESS) {
        status = round.error;
        goto cleanup;
    }
    for (i = 0; i < round.count && !stream->file; ++i) {
        segment_t *segment = &round.segments[i];
        if (segment->bytes && segment->header.is_init_segment == 1 && segment->ended &&
            segment->used == (size_t)segment->header.segment_length_bytes) {
            status = initialize(stream, segment);
            if (status != REWIND_SABR_PROGRESS) goto cleanup;
        }
    }
    if (!stream->file) goto cleanup;
    for (i = 0; i < round.count; ++i) {
        segment_t *segment = &round.segments[i];
        if (!segment->bytes || segment->header.is_init_segment != 0 || !segment->ended ||
            segment->used != (size_t)segment->header.segment_length_bytes) continue;
        status = add_segment(stream, segment);
        if (status != REWIND_SABR_PROGRESS && status != REWIND_SABR_NO_PROGRESS) goto cleanup;
        if (status == REWIND_SABR_PROGRESS) stored = 1;
    }
    status = commit_prefix(stream);
    if (status != REWIND_SABR_PROGRESS) goto cleanup;
    status = stored || stream->have_count != have_before ? REWIND_SABR_PROGRESS : REWIND_SABR_NO_PROGRESS;
    if ((size_t)stream->last_segment == stream->expected) {
        if (rewind_fmp4_finish(stream->file) != REWIND_FMP4_OK) status = REWIND_SABR_INVALID;
        else {
            stream->ready = 1;
            status = REWIND_SABR_READY;
        }
    }
cleanup:
    for (i = 0; i < round.count; ++i) free(round.segments[i].bytes);
    return status;
}

int64_t rewind_sabr_segment(const rewind_sabr_t *stream) { return stream ? stream->last_segment : 0; }
int64_t rewind_sabr_duration_ms(const rewind_sabr_t *stream) { return stream ? stream->duration_ms : 0; }
const rewind_fmp4_t *rewind_sabr_file(const rewind_sabr_t *stream) { return stream && stream->ready ? stream->file : NULL; }
const uint8_t *rewind_sabr_source(const rewind_sabr_t *stream) { return stream && stream->ready ? stream->source : NULL; }

rewind_sabr_plan_t rewind_sabr_next_request(rewind_sabr_t *stream, rewind_sabr_request_t *out) {
    size_t i;
    int inflight = 0;
    if (out) memset(out, 0, sizeof(*out));
    if (!stream || !out) return REWIND_SABR_PLAN_EXHAUSTED;
    if (stream->ready) return REWIND_SABR_PLAN_DONE;
    if (!stream->file) {
        if (stream->bootstrap_inflight) return REWIND_SABR_PLAN_WAIT;
        if (stream->bootstrap_attempts >= MAX_ATTEMPTS) return REWIND_SABR_PLAN_EXHAUSTED;
        ++stream->bootstrap_attempts;
        stream->bootstrap_inflight = 1;
        return REWIND_SABR_PLAN_REQUEST;
    }
    for (i = 0; i < stream->expected; ++i) {
        if (stream->state[i] == SEGMENT_INFLIGHT) inflight = 1;
        if (stream->state[i] != SEGMENT_MISSING || stream->attempts[i] >= MAX_ATTEMPTS) continue;
        ++stream->attempts[i];
        stream->state[i] = SEGMENT_INFLIGHT;
        out->segment = (int64_t)i + 1;
        out->claimed_segments = (int64_t)i;
        out->claimed_ms = i ? rewind_fmp4_fragment_start_ms(stream->file, i) : 0;
        return REWIND_SABR_PLAN_REQUEST;
    }
    return inflight ? REWIND_SABR_PLAN_WAIT : REWIND_SABR_PLAN_EXHAUSTED;
}

void rewind_sabr_request_done(rewind_sabr_t *stream, const rewind_sabr_request_t *request) {
    if (!stream || !request) return;
    if (request->segment == 0) {
        stream->bootstrap_inflight = 0;
        return;
    }
    if (stream->state && request->segment <= (int64_t)stream->expected &&
        stream->state[request->segment - 1] == SEGMENT_INFLIGHT)
        stream->state[request->segment - 1] = SEGMENT_MISSING;
}

size_t rewind_sabr_have_count(const rewind_sabr_t *stream) { return stream ? stream->have_count : 0; }
size_t rewind_sabr_expected(const rewind_sabr_t *stream) { return stream ? stream->expected : 0; }

rewind_fmp4_t *rewind_sabr_prefix(const rewind_sabr_t *stream, size_t count) {
    rewind_fmp4_t *preview = NULL;
    size_t needed = 0, i;
    if (!stream || !stream->file || !count || count > stream->expected || (int64_t)count > stream->last_segment ||
        !stream->init_length) return NULL;
    if (rewind_fmp4_open(stream->source, stream->init_length, &needed, &preview) != REWIND_FMP4_OK) return NULL;
    for (i = 0; i < count; ++i) {
        uint64_t offset = rewind_fmp4_fragment_offset(stream->file, i), size = rewind_fmp4_fragment_size(stream->file, i);
        if (rewind_fmp4_add_fragment(preview, i, stream->source + offset, (size_t)size, &needed) != REWIND_FMP4_OK) break;
    }
    if (i != count || !rewind_fmp4_truncate(preview, count) || rewind_fmp4_finish(preview) != REWIND_FMP4_OK) {
        rewind_fmp4_free(preview);
        return NULL;
    }
    return preview;
}

const uint8_t *rewind_sabr_data(const rewind_sabr_t *stream) { return stream ? stream->source : NULL; }
size_t rewind_sabr_contiguous(const rewind_sabr_t *stream) { return stream && stream->last_segment > 0 ? (size_t)stream->last_segment : 0; }
