#ifndef REWIND_UMP_H
#define REWIND_UMP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* youtube's sabr streaming answers with a sequence of ump parts: a type, a size,
   then that many bytes. the size (and the type) use a variable length integer that
   looks like utf-8's lead byte, not protobuf's 7-bit continuation scheme: the top
   bits of the first byte pick how many bytes the value spans (1 to 5), and the
   remaining bytes hold the value low byte first. everything inside a part's own
   body (media_header, sabr_error, ...) is normal proto2 wire format instead */

typedef enum {
    REWIND_UMP_MEDIA_HEADER = 20,
    REWIND_UMP_MEDIA = 21,
    REWIND_UMP_MEDIA_END = 22,
    REWIND_UMP_NEXT_REQUEST_POLICY = 35,
    REWIND_UMP_FORMAT_INIT_METADATA = 42,
    REWIND_UMP_SABR_REDIRECT = 43,
    REWIND_UMP_SABR_ERROR = 44,
    REWIND_UMP_STREAM_PROTECTION = 58
} rewind_ump_part_id_t;

typedef struct {
    uint32_t type;
    const uint8_t *data;
    size_t length;
} rewind_ump_part_t;

/* reads one ump-style variable length integer at buf[*pos]; advances *pos past it.
   fails (returns 0) on a truncated or reserved (all five top bits set) prefix */
int rewind_ump_read_varint(const uint8_t *buf, size_t len, size_t *pos, uint64_t *out);

/* walks buf calling on_part for every complete part. a part whose declared size
   runs past the end of buf is not an error: sabr responses legitimately end mid
   part, and the caller repeats the tail against the next response. returns the
   number of bytes consumed by whole parts, always <= len */
size_t rewind_ump_parse(const uint8_t *buf, size_t len,
                        void (*on_part)(const rewind_ump_part_t *part, void *ctx), void *ctx);

/* fields decoded from a media_header part's body; -1 means the field was absent.
   start_ms/duration_ms place this segment on the track's own timeline, and drive
   the next request's buffered_ranges once a segment is confirmed complete */
typedef struct {
    int64_t header_id;
    int64_t itag;
    int64_t is_init_segment;
    int64_t segment_number;
    int64_t segment_length_bytes;
    int64_t start_ms;
    int64_t duration_ms;
} rewind_ump_media_header_t;

/* returns 0 if the body could not be read as a media_header at all */
int rewind_ump_parse_media_header(const uint8_t *data, size_t len, rewind_ump_media_header_t *out);

/* a media part's body starts with the owning header's id as one byte; the
   return value is the offset where the raw media bytes begin, or 0 on failure
   (a media part always has at least one byte, so 0 never occurs on success) */
size_t rewind_ump_media_header_id(const uint8_t *data, size_t len, uint64_t *header_id);

typedef struct {
    char type[64];
    int64_t code;
} rewind_ump_sabr_error_t;

int rewind_ump_parse_stream_protection(const uint8_t *data, size_t len, uint32_t *status);

int rewind_ump_parse_sabr_error(const uint8_t *data, size_t len, rewind_ump_sabr_error_t *out);

/* url_cap includes the terminating nul; a url that cannot fit is rejected */
int rewind_ump_parse_sabr_redirect(const uint8_t *data, size_t len, char *url, size_t url_cap);

/* the player response hands over the ustreamer config and the po token in
   base64url (RFC 4648 with '-'/'_' instead of '+'/'/', padding optional); an
   invalid character anywhere in text fails the whole decode */
size_t rewind_base64url_decoded_size(size_t encoded_len);
int rewind_base64url_decode(const char *text, size_t len, uint8_t *out, size_t out_cap,
                            size_t *out_len);

/* --- a small proto2 wire-format writer for the outgoing abr request --- */

typedef struct {
    uint8_t *buf;
    size_t len;
    size_t cap;
} rewind_pb_writer_t;

void rewind_pb_writer_init(rewind_pb_writer_t *writer, uint8_t *buf, size_t cap);

/* every writer below returns 0 and leaves the writer unchanged when it would
   overflow cap; callers size buffers generously and check the return value once
   after building a whole message rather than after each field */
int rewind_pb_write_varint_field(rewind_pb_writer_t *writer, uint32_t field, uint64_t value);
int rewind_pb_write_string_field(rewind_pb_writer_t *writer, uint32_t field,
                                 const char *data, size_t len);
/* writes field as length-delimited, with sub's current bytes as the payload */
int rewind_pb_write_message_field(rewind_pb_writer_t *writer, uint32_t field,
                                  const rewind_pb_writer_t *sub);

#ifdef __cplusplus
}
#endif

#endif /* REWIND_UMP_H */
