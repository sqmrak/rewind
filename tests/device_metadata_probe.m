#import <Foundation/Foundation.h>
#import "rewind_api.h"
#import "rewind_account.h"
#include <dlfcn.h>
#include <stdio.h>

static BOOL probe_wait(BOOL *done, NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!*done && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    return *done;
}

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc != 2) { [pool drain]; return 2; }
    (void)dlopen("/usr/lib/senkotlsfix.dylib", RTLD_NOW | RTLD_GLOBAL);
    RewindAPI *api = [[RewindAPI alloc] initWithAPIKey:RewindDefaultAPIKey];
    RewindTrack *track = [[RewindTrack alloc] initWithVideoID:[NSString stringWithUTF8String:argv[1]]
        title:@"probe" artist:nil album:nil thumbnailURL:nil duration:0];
    int failures = 0;
    __block BOOL profileDone = NO;
    if (RewindAccountIsSignedIn()) {
        RewindAccountRefreshProfile(^(NSError *error) {
            printf("profile main %d name %d avatar %d error %s\n", [NSThread isMainThread],
                   RewindAccountName().length > 0, RewindAccountPhotoURL().length > 0,
                   error ? [error.localizedDescription UTF8String] : "none");
            profileDone = YES;
        });
        if (!probe_wait(&profileDone, 50)) ++failures;
    }
    __block BOOL lyricsDone = NO, relatedDone = NO;
    __block NSUInteger lyricCalls = 0, relatedCalls = 0;
    NSDate *start = [NSDate date];
    [api lyricsForTrack:track completion:^(RewindLyrics *lyrics, NSError *error) {
        ++lyricCalls;
        printf("lyrics %.2fs calls %lu main %d lines %lu timed %d error %s\n", -[start timeIntervalSinceNow],
               (unsigned long)lyricCalls, [NSThread isMainThread], (unsigned long)lyrics.lines.count, lyrics.timed,
               error ? [error.localizedDescription UTF8String] : "none");
        lyricsDone = YES;
    }];
    __block NSArray *firstIDs = nil;
    [api relatedForTrack:track completion:^(NSArray *shelves, NSArray *chips, NSError *error) {
        (void)chips;
        ++relatedCalls;
        NSMutableArray *ids = [NSMutableArray array];
        for (RewindShelf *shelf in shelves)
            for (RewindTrack *item in shelf.items) if (item.videoID.length) [ids addObject:item.videoID];
        firstIDs = [ids copy];
        printf("related %.2fs calls %lu main %d shelves %lu tracks %lu error %s\n", -[start timeIntervalSinceNow],
               (unsigned long)relatedCalls, [NSThread isMainThread], (unsigned long)shelves.count,
               (unsigned long)ids.count, error ? [error.localizedDescription UTF8String] : "none");
        relatedDone = YES;
    }];
    if (!probe_wait(&lyricsDone, 30) || !probe_wait(&relatedDone, 20)) ++failures;
    if (firstIDs.count) {
        __block BOOL cached = NO;
        [api relatedForTrack:track completion:^(NSArray *shelves, NSArray *chips, NSError *error) {
            (void)chips;
            NSMutableArray *ids = [NSMutableArray array];
            for (RewindShelf *shelf in shelves)
                for (RewindTrack *item in shelf.items) if (item.videoID.length) [ids addObject:item.videoID];
            cached = !error && [ids isEqual:firstIDs];
            printf("related cache stable %d\n", cached);
        }];
        if (!cached) ++failures;
    }
    NSDate *settle = [NSDate dateWithTimeIntervalSinceNow:2];
    [[NSRunLoop currentRunLoop] runUntilDate:settle];
    if (lyricCalls != 1 || relatedCalls != 1) ++failures;
    [firstIDs release];
    [track release];
    [api release];
    printf("metadata completion checks %s\n", failures ? "FAILED" : "passed");
    [pool drain];
    return failures ? 1 : 0;
}
