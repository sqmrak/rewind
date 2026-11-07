#include "rewind_link.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int parse(const char *text, rewind_link *out) {
    return rewind_link_parse(text, text ? strlen(text) : 0, out);
}

static void expect(const char *text, const char *video, const char *list) {
    rewind_link link;
    assert(parse(text, &link) == 1);
    assert(strcmp(link.video_id, video) == 0);
    assert(strcmp(link.list_id, list) == 0);
}

static void reject(const char *text) {
    rewind_link link;
    memset(&link, 0x7f, sizeof link);
    assert(parse(text, &link) == 0);
    assert(link.video_id[0] == '\0' && link.list_id[0] == '\0');
}

int main(void) {
    expect("https://www.youtube.com/watch?v=ciu0YMYdD7o&list=TLGGjXG9iEhKSZEwNTExMjAyNg&index=23",
           "ciu0YMYdD7o", "TLGGjXG9iEhKSZEwNTExMjAyNg");
    expect("https://www.youtube.com/playlist?list=PLabc123_-xyz", "", "PLabc123_-xyz");
    expect("https://music.youtube.com/playlist?list=OLAK5uy_kabc&si=zz", "", "OLAK5uy_kabc");
    expect("https://music.youtube.com/watch?v=ciu0YMYdD7o", "ciu0YMYdD7o", "");
    expect("https://m.youtube.com/watch?feature=share&list=PL12&v=ciu0YMYdD7o", "ciu0YMYdD7o", "PL12");
    expect("https://youtu.be/ciu0YMYdD7o?list=PL12", "ciu0YMYdD7o", "PL12");
    expect("https://youtu.be/ciu0YMYdD7o", "ciu0YMYdD7o", "");
    expect("https://www.youtube.com/shorts/ciu0YMYdD7o", "ciu0YMYdD7o", "");
    expect("HTTPS://WWW.YOUTUBE.COM/watch?v=ciu0YMYdD7o#t=5", "ciu0YMYdD7o", "");
    expect("  youtube.com/playlist?list=PL12\n", "", "PL12");
    expect("rewind://www.youtube.com/watch?v=ciu0YMYdD7o&list=PL12", "ciu0YMYdD7o", "PL12");

    /* a list id sits beside a bad video id: the list still opens */
    expect("https://www.youtube.com/watch?v=short&list=PL12", "", "PL12");

    reject("");
    reject("hello world");
    reject("https://example.com/watch?v=ciu0YMYdD7o");
    reject("https://youtube.com.evil.net/watch?v=ciu0YMYdD7o");
    reject("https://evil.net@www.youtube.com/watch?v=ciu0YMYdD7o");
    reject("https://www.youtube.com:8080/watch?v=ciu0YMYdD7o");
    reject("javascript:alert(1)");
    reject("ftp://www.youtube.com/watch?v=ciu0YMYdD7o");
    reject("https://www.youtube.com/");
    reject("https://www.youtube.com/watch");
    reject("https://www.youtube.com/watch?xlist=PL12");
    reject("https://www.youtube.com/watch?v=ciu0YMYdD7oX");
    reject("https://www.youtube.com/playlist?list=");
    reject("https://www.youtube.com/playlist?list=P");
    reject("https://youtu.be/");
    reject("https://youtu.be/short");

    /* ids over the cap, a link over the length bound, and a missing result struct */
    char long_link[4200];
    strcpy(long_link, "https://www.youtube.com/playlist?list=");
    memset(long_link + strlen(long_link), 'a', 64);
    long_link[strlen("https://www.youtube.com/playlist?list=") + 64] = '\0';
    reject(long_link);
    memset(long_link, 'a', sizeof long_link - 1);
    long_link[sizeof long_link - 1] = '\0';
    reject(long_link);
    /* a share link padded with tracking parameters is still a playlist link */
    char padded[3000];
    strcpy(padded, "https://www.youtube.com/playlist?list=PLabc123&x=");
    memset(padded + strlen(padded), 'b', 2500);
    padded[strlen("https://www.youtube.com/playlist?list=PLabc123&x=") + 2500] = '\0';
    expect(padded, "", "PLabc123");
    assert(rewind_link_parse("https://youtu.be/ciu0YMYdD7o", 28, NULL) == 0);
    assert(rewind_link_parse(NULL, 5, &(rewind_link){{0}, {0}}) == 0);

    /* the length bounds every read: a prefix of a link is a different link */
    rewind_link link;
    assert(rewind_link_parse("https://youtu.be/ciu0YMYdD7oZZZ", 28, &link) == 1);
    assert(strcmp(link.video_id, "ciu0YMYdD7o") == 0);
    assert(rewind_link_parse("https://youtu.be/ciu0YMYdD7oZZZ", 27, &link) == 0);

    puts("test_link ok");
    return 0;
}
