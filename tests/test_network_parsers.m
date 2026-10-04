#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>

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
    [pool drain];
    puts("network parser checks passed");
    return 0;
}
