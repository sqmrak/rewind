#include "rewind_link.h"
#include <string.h>

#define VIDEO_ID_LEN 11
#define LIST_ID_MIN 2
#define URL_MAX 8192

static int id_char(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
}

static char lower(char c) {
    return c >= 'A' && c <= 'Z' ? (char)(c - 'A' + 'a') : c;
}

static int starts_with(const char *s, size_t len, const char *prefix) {
    size_t n = strlen(prefix);
    if (len < n) return 0;
    for (size_t i = 0; i < n; ++i) if (lower(s[i]) != prefix[i]) return 0;
    return 1;
}

static int host_is(const char *host, size_t len, const char *name) {
    size_t n = strlen(name);
    if (len != n) return 0;
    for (size_t i = 0; i < n; ++i) if (lower(host[i]) != name[i]) return 0;
    return 1;
}

static int host_in_youtube(const char *host, size_t len) {
    static const char *const names[] = { "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
                                         "youtube-nocookie.com", "www.youtube-nocookie.com" };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; ++i) if (host_is(host, len, names[i])) return 1;
    return 0;
}

/* copies a run of id characters; an id of a wrong length is rejected whole, never cut */
static int take_id(const char *s, size_t len, size_t min, size_t max, char *dst) {
    size_t n = 0;
    while (n < len && id_char(s[n])) ++n;
    if (n < min || n > max || n >= REWIND_LINK_ID_MAX) return 0;
    memcpy(dst, s, n);
    dst[n] = '\0';
    return 1;
}

static int video_id_at(const char *s, size_t len, char *dst) {
    return take_id(s, len, VIDEO_ID_LEN, VIDEO_ID_LEN, dst);
}

/* the value of one query key; a key must match whole, so "xlist" never reads as "list" */
static int query_value(const char *query, size_t len, const char *key, const char **value, size_t *value_len) {
    size_t key_len = strlen(key);
    size_t i = 0;
    while (i < len) {
        size_t end = i;
        while (end < len && query[end] != '&') ++end;
        if (end - i > key_len && memcmp(query + i, key, key_len) == 0 && query[i + key_len] == '=') {
            *value = query + i + key_len + 1;
            *value_len = end - i - key_len - 1;
            return 1;
        }
        i = end + 1;
    }
    return 0;
}

int rewind_link_parse(const char *text, size_t len, rewind_link *out) {
    if (!out) return 0;
    memset(out, 0, sizeof *out);
    if (!text || len == 0 || len > URL_MAX) return 0;

    while (len && (text[0] == ' ' || text[0] == '\t' || text[0] == '\n' || text[0] == '\r')) { ++text; --len; }
    while (len && (text[len - 1] == ' ' || text[len - 1] == '\t' || text[len - 1] == '\n' || text[len - 1] == '\r')) --len;

    if (starts_with(text, len, "https://")) { text += 8; len -= 8; }
    else if (starts_with(text, len, "http://")) { text += 7; len -= 7; }
    else if (starts_with(text, len, "rewind://")) { text += 9; len -= 9; }


    size_t host_len = 0;
    while (host_len < len && text[host_len] != '/' && text[host_len] != '?' && text[host_len] != '#') ++host_len;
    const char *host = text;
    const char *rest = text + host_len;
    size_t rest_len = len - host_len;

    /* a port or credentials in the host would hide a different server behind a youtube name */
    for (size_t i = 0; i < host_len; ++i) if (host[i] == '@' || host[i] == ':') return 0;

    const char *value;
    size_t value_len;
    const char *path = rest;
    size_t path_len = 0;
    while (path_len < rest_len && path[path_len] != '?' && path[path_len] != '#') ++path_len;
    const char *query = path + path_len;
    size_t query_len = rest_len - path_len;
    if (query_len && query[0] == '?') { ++query; --query_len; } else query_len = 0;
    for (size_t i = 0; i < query_len; ++i) if (query[i] == '#') { query_len = i; break; }

    rewind_link link;
    memset(&link, 0, sizeof link);

    if (host_is(host, host_len, "youtu.be") || host_is(host, host_len, "www.youtu.be")) {
        if (path_len < 2 || path[0] != '/') return 0;
        if (!video_id_at(path + 1, path_len - 1, link.video_id)) return 0;
    } else if (host_in_youtube(host, host_len)) {
        if (path_len >= 6 && memcmp(path, "/watch", 6) == 0 && (path_len == 6 || path[6] == '/')) {
            if (query_value(query, query_len, "v", &value, &value_len)) video_id_at(value, value_len, link.video_id);
        } else if (path_len == 9 && memcmp(path, "/playlist", 9) == 0) {
            /* the list alone is the whole link */
        } else if (path_len > 1 && (starts_with(path, path_len, "/shorts/") || starts_with(path, path_len, "/embed/") ||
                                    starts_with(path, path_len, "/live/") || starts_with(path, path_len, "/v/"))) {
            const char *slash = memchr(path + 1, '/', path_len - 1);
            if (!slash || !video_id_at(slash + 1, path_len - (size_t)(slash + 1 - path), link.video_id)) return 0;
        } else {
            return 0;
        }
    } else {
        return 0;
    }

    if (query_value(query, query_len, "list", &value, &value_len))
        take_id(value, value_len, LIST_ID_MIN, REWIND_LINK_ID_MAX - 1, link.list_id);
    if (!link.video_id[0] && !link.list_id[0]) return 0;
    *out = link;
    return 1;
}
