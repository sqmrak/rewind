#import <Foundation/Foundation.h>
#import "rewind_api.h"
#import "rewind_account.h"
#include <stdio.h>

/* lists the signed in account playlists the way the library loads them, run on a device as mobile */
int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    __block BOOL done = NO;
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("signed in: %d\n", RewindAccountIsSignedIn());
    RewindAccountLoadPlaylists(^(NSArray *playlists, NSError *error) {
        printf("%lu playlists, error: %s\n", (unsigned long)playlists.count, [[error description] UTF8String] ?: "none");
        for (RewindTrack *playlist in playlists)
            printf("- %s | %s | %s | type %s | thumb %s\n", [playlist.playlistID UTF8String] ?: "", [playlist.title UTF8String] ?: "",
                   [playlist.artist UTF8String] ?: "", [playlist.resultType UTF8String] ?: "", [playlist.thumbnailURL UTF8String] ?: "");
        done = YES;
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:60];
    while (!done && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    if (!done) printf("timed out\n");
    [pool drain];
    return 0;
}
