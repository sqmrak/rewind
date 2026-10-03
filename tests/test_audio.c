#include "rewind_audio.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void test_api_fields(void) {
    uint64_t start = 9, end = 9;
    const char *bad[] = {NULL, "", "3", "1-0", "0-3 junk", "0--3", "0-18446744073709551616", "0-3/10"};
    assert(rewind_audio_index_range("731-1014", &start, &end) && start == 731 && end == 1014);
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i) {
        assert(!rewind_audio_index_range(bad[i], &start, &end));
        assert(start == 0 && end == 0);
    }
    assert(!rewind_audio_index_range("0-2", NULL, &end));
    assert(rewind_audio_video_id("K4DyBUG242c"));
    assert(rewind_audio_video_id("yJg-Y5byMMw"));
    assert(!rewind_audio_video_id(NULL));
    assert(!rewind_audio_video_id(""));
    assert(!rewind_audio_video_id("K4DyBUG242c/"));
    assert(!rewind_audio_video_id("../BUG242c"));
}

static void test_ranges(void) {
    const char *bad[] = {
        NULL, "", "bytes 0-1023/*", "bytes 0-1023/1023", "bytes 1-1024/4096",
        "bytes 0-1023/4096 junk", "bytes 0-1023/18446744073709551616",
        "bytes -1-1023/4096", "bytes 0-1023/4096, bytes 0-1023/4096"
    };
    uint64_t total = 99;
    size_t i;
    assert(rewind_audio_content_range("bytes 0-1023/4096", 0, 1023, 1024, &total));
    assert(total == 4096);
    assert(rewind_audio_content_range("bytes 4095-4095/4096\t", 4095, 4095, 1, &total));
    assert(!rewind_audio_content_range("bytes 0-1023/4096", 0, 1023, 1023, &total));
    assert(total == 0);
    assert(!rewind_audio_content_range("bytes 0-1023/4096", 1023, 0, 1024, NULL));
    assert(!rewind_audio_content_range("bytes 0-1023/4096", 0, UINT64_MAX, 0, NULL));
    for (i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i) {
        total = 99;
        assert(!rewind_audio_content_range(bad[i], 0, 1023, 1024, &total));
        assert(total == 0);
    }
}

static void test_media(void) {
    uint8_t mp4[24] = {0, 0, 0, 24, 'f', 't', 'y', 'p', 'd', 'a', 's', 'h'};
    uint8_t ts[376] = {0x47};
    uint8_t aac[7] = {0xff, 0xf1};
    assert(rewind_audio_mp4(mp4, sizeof(mp4)));
    assert(!rewind_audio_mp4(mp4, 16));
    assert(!rewind_audio_mp4(NULL, 100));
    assert(!rewind_audio_mp4((const uint8_t *)"<html>server error</html>", 25));
    ts[188] = 0x47;
    assert(rewind_audio_segment(ts, sizeof(ts)));
    ts[188] = 0;
    assert(!rewind_audio_segment(ts, sizeof(ts)));
    assert(rewind_audio_segment(aac, sizeof(aac)));
    assert(!rewind_audio_segment(aac, 2));
    uint8_t packed[30] = {'I', 'D', '3', 3, 0, 0, 0, 0, 0, 13};
    packed[23] = 0xff; packed[24] = 0xf1;
    assert(rewind_audio_segment(packed, sizeof(packed)));
    assert(!rewind_audio_segment(packed, 24));
    packed[9] = 0x80;
    assert(!rewind_audio_segment(packed, sizeof(packed)));
}

static void test_hls(void) {
    char first[128], last[128];
    const char *master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,NAME=\"low, aac\",URI=\"audio.m3u8\"\n";
    const char *media = "#EXTM3U\r\n#EXT-X-VERSION:3\r\n#EXTINF:5.24,\r\nfirst.ts\r\n"
                        "#EXTINF:4,\r\nlast.ts\r\n#EXT-X-ENDLIST\r\n";
    const char *bad[] = {
        "", "<html>error</html>", "#EXTM3Uevil\n",
        "#EXTM3U\n#EXTINF:4,\nx.ts\n", /* no end, cannot verify a full track */
        "#EXTM3U\nx.ts\n#EXT-X-ENDLIST\n",
        "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI=\"unterminated\n",
        "#EXTM3U\n#EXT-X-MEDIA:TYPE=VIDEO,URI=\"video.m3u8\"\n",
        "#EXTM3U\n#EXTINF:4,\nx.ts\n#EXT-X-ENDLIST\n#EXTINF:4,\ny.ts\n",
        "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:4,\nx.ts\n#EXT-X-ENDLIST\n",
        "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128\n#EXTINF:4,\nx.ts\n#EXT-X-ENDLIST\n",
        "#EXTM3U\n#EXTINF:4,\nx ts\n#EXT-X-ENDLIST\n"
    };
    size_t i;
    assert(rewind_audio_hls(master, strlen(master), first, sizeof(first), last, sizeof(last)) == REWIND_AUDIO_HLS_MASTER);
    assert(strcmp(first, "audio.m3u8") == 0);
    assert(rewind_audio_hls(media, strlen(media), first, sizeof(first), last, sizeof(last)) == REWIND_AUDIO_HLS_MEDIA);
    assert(strcmp(first, "first.ts") == 0 && strcmp(last, "last.ts") == 0);
    assert(rewind_audio_hls(media, strlen(media), first, 4, last, sizeof(last)) == REWIND_AUDIO_HLS_INVALID);
    for (i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i)
        assert(rewind_audio_hls(bad[i], strlen(bad[i]), first, sizeof(first), last, sizeof(last)) == REWIND_AUDIO_HLS_INVALID);
}

int main(void) {
    test_api_fields();
    test_ranges();
    test_media();
    test_hls();
    puts("all audio checks passed");
    return 0;
}
