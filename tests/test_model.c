#include "rewind_model.h"

#include <stdio.h>
#include <string.h>

static int g_fail;

static void ok(const char *name, int condition) {
    if (condition) return;
    fprintf(stderr, "FAIL %s\n", name);
    ++g_fail;
}

int main(void) {
    rewind_track_t track;
    unsigned seconds = 0;
    char text[5];

    rewind_track_init(&track);
    ok("track starts empty", track.video_id[0] == '\0' && track.title[0] == '\0');
    ok("copy full text", rewind_track_set_text(text, sizeof text, "abcd") == 0 && strcmp(text, "abcd") == 0);
    ok("copy truncates explicitly", rewind_track_set_text(text, sizeof text, "abcdef") == 1 && strcmp(text, "abcd") == 0);
    ok("parse seconds", rewind_duration_parse("PT42S", &seconds) == 0 && seconds == 42);
    ok("parse minutes", rewind_duration_parse("PT3M7S", &seconds) == 0 && seconds == 187);
    ok("parse hours", rewind_duration_parse("PT1H2M3S", &seconds) == 0 && seconds == 3723);
    ok("reject bad duration", rewind_duration_parse("3:07", &seconds) != 0);

    if (g_fail) {
        fprintf(stderr, "%d model check(s) failed\n", g_fail);
        return 1;
    }
    puts("all model checks passed");
    return 0;
}
