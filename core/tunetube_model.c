#include "tunetube_model.h"

#include <ctype.h>
#include <string.h>

void tunetube_track_init(tunetube_track_t *track) {
    if (!track) return;
    memset(track, 0, sizeof *track);
}

int tunetube_track_set_text(char *dst, size_t cap, const char *src) {
    size_t n;
    if (!dst || cap == 0 || !src) return -1;
    n = strlen(src);
    if (n >= cap) n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
    return src[n] == '\0' ? 0 : 1;
}

static int duration_value(const char **p, unsigned *out, char unit) {
    unsigned long value = 0;
    const char *s = *p;
    if (!isdigit((unsigned char)*s)) return -1;
    while (isdigit((unsigned char)*s)) {
        value = value * 10ul + (unsigned long)(*s - '0');
        if (value > 86400ul) return -1;
        ++s;
    }
    if (*s != unit) return -1;
    if (value > 86400ul) return -1;
    *out = (unsigned)value;
    *p = s + 1;
    return 0;
}

int tunetube_duration_parse(const char *text, unsigned *out_seconds) {
    const char *p;
    unsigned seconds = 0;
    int seen = 0;
    if (!text || !out_seconds || text[0] != 'P' || text[1] != 'T') return -1;
    p = text + 2;
    while (*p) {
        const char *number = p;
        unsigned value = 0;
        char unit;
        while (isdigit((unsigned char)*p)) ++p;
        if (p == number) return -1;
        unit = *p;
        if (unit != 'H' && unit != 'M' && unit != 'S') return -1;
        p = number;
        if (duration_value(&p, &value, unit) != 0) return -1;
        if (unit == 'H') {
            if (value > 24 || seconds > 86400u - value * 3600u) return -1;
            seconds += value * 3600u;
        } else if (unit == 'M') {
            if (value > 59 || seconds > 86400u - value * 60u) return -1;
            seconds += value * 60u;
        } else {
            if (value > 59 || seconds > 86400u - value) return -1;
            seconds += value;
        }
        seen = 1;
    }
    if (!seen) return -1;
    *out_seconds = seconds;
    return 0;
}
