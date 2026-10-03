#import <Foundation/Foundation.h>
#import "rewind_api.h"
#import "rewind_account.h"
#include <stdio.h>

/* prints the shelves the signed in home returns, run on a device as mobile */
int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    __block BOOL done = NO;
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("signed in: %d\n", RewindAccountIsSignedIn());
    if (getenv("PROBE_ACCOUNT")) RewindAccountLoadHome(^(NSArray *shelves, NSError *error) {
        printf("callback: %lu shelves, error: %s\n", (unsigned long)shelves.count, [[error description] UTF8String] ?: "none");
        for (RewindShelf *shelf in shelves) {
            id first = shelf.items.count ? [shelf.items objectAtIndex:0] : nil;
            printf("- [%d] \"%s\" caption \"%s\" items %lu first %s\n", (int)shelf.style, [shelf.title UTF8String] ?: "",
                   [shelf.caption UTF8String] ?: "", (unsigned long)shelf.items.count, first ? [NSStringFromClass([first class]) UTF8String] : "-");
        }
        done = YES;
    });
    RewindAPI *api = [[RewindAPI alloc] initWithAPIKey:RewindDefaultAPIKey];
    [api browseShelves:@"FEmusic_home" params:nil completion:^(NSArray *shelves, NSArray *chips, NSError *error) {
        done = YES; printf("public home: %lu shelves, %lu chips, error: %s\n", (unsigned long)shelves.count, (unsigned long)chips.count, [[error description] UTF8String] ?: "none");
        for (RewindBrowseLink *chip in chips) printf("chip: %s\n", [chip.title UTF8String] ?: "");
        for (RewindShelf *shelf in shelves) {
            id first = shelf.items.count ? [shelf.items objectAtIndex:0] : nil;
            printf("- [%d] \"%s\" caption \"%s\" items %lu first %s\n", (int)shelf.style, [shelf.title UTF8String] ?: "",
                   [shelf.caption UTF8String] ?: "", (unsigned long)shelf.items.count, first ? [NSStringFromClass([first class]) UTF8String] : "-");
        }
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:40];
    if (!getenv("PROBE_ACCOUNT")) done = NO;
    while (!done && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    if (!done) printf("timed out\n");
    [pool drain];
    return 0;
}
