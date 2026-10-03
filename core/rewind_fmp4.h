#ifndef REWIND_FMP4_H
#define REWIND_FMP4_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* youtube's audio only files are fragmented mp4 (ftyp, moov, sidx, then moof+mdat pairs),
   which the ios 5 and 6 media server cannot play over http. this rebuilds them as a plain
   m4a: a new moov with full sample tables in front of one mdat that is the fragments' sample
   data laid end to end, so the payload can be streamed straight from the original file */

typedef enum {
    REWIND_FMP4_OK = 0,
    REWIND_FMP4_INVALID,     /* not a fragmented audio file this code understands */
    REWIND_FMP4_NEED_MORE,   /* the buffer ends before the box; *needed says how much to pass */
    REWIND_FMP4_NO_MEMORY
} rewind_fmp4_status_t;

typedef struct rewind_fmp4 rewind_fmp4_t;

/* one fragment's samples: where they sit in the original file and in the rebuilt one */
typedef struct {
    uint64_t source_offset;
    uint64_t output_offset;
    uint64_t length;
} rewind_fmp4_chunk_t;

/* head holds the file from byte 0 through the end of the sidx (the format's indexRange) */
rewind_fmp4_status_t rewind_fmp4_open(const uint8_t *head, size_t len, size_t *needed,
                                      rewind_fmp4_t **out);
void rewind_fmp4_free(rewind_fmp4_t *file);

/* fragments come from the sidx; each one starts with its moof */
size_t rewind_fmp4_fragment_count(const rewind_fmp4_t *file);
uint64_t rewind_fmp4_fragment_offset(const rewind_fmp4_t *file, size_t index);
uint64_t rewind_fmp4_fragment_size(const rewind_fmp4_t *file, size_t index);
/* where the sidx puts fragment index on the track timeline, index == count is the track end, -1 beyond */
int64_t rewind_fmp4_fragment_start_ms(const rewind_fmp4_t *file, size_t index);

/* buf holds the start of fragment index; NEED_MORE sets *needed when the moof is longer */
rewind_fmp4_status_t rewind_fmp4_add_fragment(rewind_fmp4_t *file, size_t index,
                                              const uint8_t *buf, size_t len, size_t *needed);

/* the moof's own declared box size, read without touching any fragment's place in
   the sequence; lets a concurrent prefetch learn how much more to fetch for a
   fragment before that fragment's turn comes up in rewind_fmp4_add_fragment */
size_t rewind_fmp4_probe_box_size(const uint8_t *buf, size_t len);

/* ends the file after its first count fragments, which must all be added already: a playable
   preview of a download that has not finished. call it before rewind_fmp4_finish */
int rewind_fmp4_truncate(rewind_fmp4_t *file, size_t count);

/* after every fragment is added: builds ftyp, moov and the mdat header */
rewind_fmp4_status_t rewind_fmp4_finish(rewind_fmp4_t *file);

const uint8_t *rewind_fmp4_header(const rewind_fmp4_t *file, size_t *len);
uint64_t rewind_fmp4_output_size(const rewind_fmp4_t *file);
size_t rewind_fmp4_chunk_count(const rewind_fmp4_t *file);
const rewind_fmp4_chunk_t *rewind_fmp4_chunk(const rewind_fmp4_t *file, size_t index);
double rewind_fmp4_duration(const rewind_fmp4_t *file);

#ifdef __cplusplus
}
#endif

#endif /* REWIND_FMP4_H */
