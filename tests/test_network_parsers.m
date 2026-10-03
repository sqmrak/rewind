#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>

static void music_video_checks(void) {
    NSMutableDictionary *video = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"dQw4w9WgXcQ", @"videoId", @"MUSIC_VIDEO_TYPE_OMV", @"musicVideoType", nil];
    NSDictionary *primary = [NSDictionary dictionaryWithObject:
        [NSDictionary dictionaryWithObject:@"XnMiO4V3G58" forKey:@"videoId"]
        forKey:@"playlistPanelVideoRenderer"];
    NSDictionary *counterpart = [NSDictionary dictionaryWithObject:
        [NSDictionary dictionaryWithObject:video forKey:@"playlistPanelVideoRenderer"]
        forKey:@"counterpartRenderer"];
    NSMutableDictionary *wrapper = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        primary, @"primaryRenderer", [NSArray arrayWithObject:counterpart], @"counterpart", nil];
    NSDictionary *root = [NSDictionary dictionaryWithObject:wrapper forKey:@"playlistPanelVideoWrapperRenderer"];
    for (NSString *type in [NSArray arrayWithObjects:@"MUSIC_VIDEO_TYPE_OMV",
                            @"MUSIC_VIDEO_TYPE_UGC", @"MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE", nil]) {
        [video setObject:type forKey:@"musicVideoType"];
        assert([RewindMusicVideoCounterpart(root, @"XnMiO4V3G58") isEqualToString:@"dQw4w9WgXcQ"]);
    }
    assert(!RewindMusicVideoCounterpart(root, @"K4DyBUG242c"));
    assert(!RewindMusicVideoCounterpart(root, @"invalid"));
    assert(!RewindMusicVideoCounterpart([NSDictionary dictionary], @"XnMiO4V3G58"));
    assert(!RewindMusicVideoCounterpart([NSDictionary dictionaryWithObject:[NSNull null]
        forKey:@"playlistPanelVideoWrapperRenderer"], @"XnMiO4V3G58"));
    for (id type in [NSArray arrayWithObjects:@"MUSIC_VIDEO_TYPE_ATV", @"unknown_OMV",
                     @"", [NSNull null], nil]) {
        [video setObject:type forKey:@"musicVideoType"];
        assert(!RewindMusicVideoCounterpart(root, @"XnMiO4V3G58"));
    }
    [video setObject:@"MUSIC_VIDEO_TYPE_OMV" forKey:@"musicVideoType"];
    [video setObject:@"unavailable" forKey:@"unplayableText"];
    assert(!RewindMusicVideoCounterpart(root, @"XnMiO4V3G58"));
    [video removeObjectForKey:@"unplayableText"];
    for (id videoID in [NSArray arrayWithObjects:@"short", @"dQw4w9WgXcQ/", [NSNull null], nil]) {
        [video setObject:videoID forKey:@"videoId"];
        assert(!RewindMusicVideoCounterpart(root, @"XnMiO4V3G58"));
    }
    [wrapper setObject:[NSNull null] forKey:@"counterpart"];
    assert(!RewindMusicVideoCounterpart(root, @"XnMiO4V3G58"));

    NSString *mime = @"video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"";
    NSString *url = @"https://r1.googlevideo.com/videoplayback";
    NSMutableDictionary *format = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        mime, @"mimeType", url, @"url", [NSNumber numberWithInt:18], @"itag", nil];
    NSDictionary *media = [NSDictionary dictionaryWithObject:
        [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:format] forKey:@"formats"]
        forKey:@"streamingData"];
    NSArray *candidates = RewindMusicVideoCandidates(media, @"IOS");
    assert(candidates.count == 1);
    assert([[[candidates objectAtIndex:0] objectForKey:@"key"] isEqualToString:@"IOS:video:18"]);
    assert(!RewindMusicVideoCandidates([NSDictionary dictionary], @"IOS").count);
    assert(!RewindMusicVideoCandidates([NSDictionary dictionaryWithObject:
        [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:format] forKey:@"adaptiveFormats"]
        forKey:@"streamingData"], @"IOS").count);
    for (NSString *key in [NSArray arrayWithObjects:@"drmFamilies", @"cipher", @"signatureCipher", @"indexRange", nil]) {
        [format setObject:[NSDictionary dictionary] forKey:key];
        assert(!RewindMusicVideoCandidates(media, @"IOS").count);
        [format removeObjectForKey:key];
    }
    for (id badURL in [NSArray arrayWithObjects:@"http://r1.googlevideo.com/video",
                       @"https://googlevideo.com.evil.test/video", @"https://user@r1.googlevideo.com/video",
                       @"https://r1.googlevideo.com/video#fragment", @"", [NSNull null], nil]) {
        [format setObject:badURL forKey:@"url"];
        assert(!RewindMusicVideoCandidates(media, @"IOS").count);
    }
    [format setObject:url forKey:@"url"];
    for (id badMime in [NSArray arrayWithObjects:@"audio/mp4; codecs=\"mp4a.40.2\"",
                        @"video/mp4; codecs=\"avc1.42001E\"", @"video/mp4; codecs=\"vp09, mp4a.40.2\"",
                        @"video/mp4; codecs=\"avc1.42001E, opus\"", [NSNull null], nil]) {
        [format setObject:badMime forKey:@"mimeType"];
        assert(!RewindMusicVideoCandidates(media, @"IOS").count);
    }
    [format setObject:mime forKey:@"mimeType"];
    for (id itag in [NSArray arrayWithObjects:@"0", @"2147483648", @"18x", [NSNull null], nil]) {
        [format setObject:itag forKey:@"itag"];
        assert(!RewindMusicVideoCandidates(media, @"IOS").count);
    }
    [format setObject:@"18" forKey:@"itag"];
    assert(RewindMusicVideoCandidates(media, @"IOS").count == 1);
    NSMutableArray *formats = [NSMutableArray array];
    for (int i = 4; i > 0; --i) {
        NSMutableDictionary *item = [[format mutableCopy] autorelease];
        [item setObject:[NSNumber numberWithInt:i * 100] forKey:@"bitrate"];
        [item setObject:[NSNumber numberWithInt:i] forKey:@"itag"];
        [formats addObject:item];
    }
    NSDictionary *many = [NSDictionary dictionaryWithObject:
        [NSDictionary dictionaryWithObject:formats forKey:@"formats"] forKey:@"streamingData"];
    candidates = RewindMusicVideoCandidates(many, @"IOS");
    assert(candidates.count == 3);
    for (NSUInteger i = 0; i < candidates.count; ++i) {
        NSDictionary *item = [[candidates objectAtIndex:i] objectForKey:@"format"];
        assert([[item objectForKey:@"bitrate"] intValue] == (int)(i + 1) * 100);
    }
}

/* the runner prepends the actual production parsers and lyric model implementations */
int main(int argc, char **argv) {
    assert(argc == 2);
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *directory = [NSString stringWithUTF8String:argv[1]];
    NSError *error = nil;
    NSData *bytes = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"watch.json"]];
    NSDictionary *watch = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:&error];
    assert(watch && !error);
    assert([RewindWatchTabBrowseID(watch, @"MPLY") isEqualToString:@"lyrics-exact-track"]);
    assert([RewindWatchTabBrowseID(watch, @"MPTR") isEqualToString:@"related-exact-track"]);
    assert(!RewindWatchTabBrowseID([NSDictionary dictionary], @"MPTR"));
    NSMutableDictionary *selectable = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:NO], @"unselectable", [NSDictionary dictionaryWithObject:
            [NSDictionary dictionaryWithObject:@"MPLY-selectable" forKey:@"browseId"]
            forKey:@"browseEndpoint"], @"endpoint", nil];
    NSDictionary *selectableRoot = [NSDictionary dictionaryWithObject:
        [NSArray arrayWithObject:[NSDictionary dictionaryWithObject:selectable forKey:@"tabRenderer"]]
        forKey:@"tabs"];
    assert([RewindWatchTabBrowseID(selectableRoot, @"MPLY") isEqualToString:@"MPLY-selectable"]);
    [selectable setObject:[NSNumber numberWithBool:YES] forKey:@"unselectable"];
    assert(!RewindWatchTabBrowseID(selectableRoot, @"MPLY"));
    bytes = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"lyrics.json"]];
    NSDictionary *fixtures = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:&error];
    assert(fixtures && !error);
    RewindLyrics *timed = RewindTimedLyrics([fixtures objectForKey:@"timed"]);
    assert(timed.timed && timed.lines.count == 2);
    assert(((RewindLyricLine *)[timed.lines objectAtIndex:1]).startMS == 1200);
    for (NSString *key in [NSArray arrayWithObjects:@"untimed", @"malformed", nil]) {
        RewindLyrics *lyrics = RewindTimedLyrics([fixtures objectForKey:key]);
        assert(lyrics && !lyrics.timed && lyrics.lines.count == 2);
    }
    RewindLyrics *plain = RewindPlainLyrics([fixtures objectForKey:@"plain"]);
    assert(plain && !plain.timed && plain.lines.count == 2);
    assert(!RewindTimedLyrics([NSDictionary dictionary]));
    assert(!RewindPlainLyrics([NSDictionary dictionary]));
    NSMutableArray *entries = [NSMutableArray array];
    for (NSUInteger i = 0; i < 501; ++i)
        [entries addObject:[NSDictionary dictionaryWithObject:@"line" forKey:@"lyricLine"]];
    NSDictionary *many = [NSDictionary dictionaryWithObject:
        [NSDictionary dictionaryWithObject:entries forKey:@"timedLyricsData"] forKey:@"lyricsData"];
    assert(RewindTimedLyrics(many).lines.count == 500);
    uint64_t value = 0;
    assert(!RewindUnsigned(@"18446744073709551616", &value));
    assert(!RewindUnsigned(@"1x", &value));
    music_video_checks();
    [pool drain];
    puts("network parser checks passed");
    return 0;
}
