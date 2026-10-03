#import <Foundation/Foundation.h>
#import "rewind_api.h"
#include <stdio.h>

/* resolves tracks one after another the way the player does and prints when the preview and the full file
   arrive; later tracks show what a warm connection saves. run on a device */
int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    RewindAPI *api = [[RewindAPI alloc] initWithAPIKey:RewindDefaultAPIKey];
    if (getenv("WARM")) {
        RewindWarmPlaybackConnections();
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:4.0];
        while ([until timeIntervalSinceNow] > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        printf("warmed\n");
    }
    for (int i = 1; i < argc || i == 1; ++i) {
        NSString *video = argc > i ? [NSString stringWithUTF8String:argv[i]] : @"dQw4w9WgXcQ";
        RewindTrack *track = [[RewindTrack alloc] initWithVideoID:video title:@"probe" artist:@"" album:@"" thumbnailURL:nil duration:0];
        __block BOOL done = NO;
        NSDate *started = [NSDate date];
        RewindAudioRequest *request = [api streamURLForTrack:track excludingSources:nil completion:^(NSURL *url, NSError *error) {
            printf("[%s] first file at %.1fs: %s%s\n", [video UTF8String], -[started timeIntervalSinceNow],
                   url ? "ok" : "none", error ? [[NSString stringWithFormat:@" error %@", error] UTF8String] : "");
            if (!url) done = YES;
        }];
        request.allowsPreview = YES;
        request.onUpgrade = ^(NSURL *url, NSError *error) {
            printf("[%s] full file at %.1fs: %s\n", [video UTF8String], -[started timeIntervalSinceNow], url ? "ok" : [[error description] UTF8String]);
            done = YES;
        };
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:60];
        while (!done && [deadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        [track release];
    }
    [pool drain];
    return 0;
}
