#import <Foundation/Foundation.h>
#import "rewind_api.h"
#import "rewind_player.h"
#import "rewind_account.h"
#include <math.h>
static NSString *downloadProbeDirectory;
#define REWIND_DOWNLOAD_TEST_DIRECTORY downloadProbeDirectory
#import "../app/rewind_download.m"

static NSURL *probeSource;
@interface RewindDownloadProbeAPI : RewindAPI {
    RewindAudioCompletion _heldCompletion;
}
@property(nonatomic) BOOL hold;
- (void)resolve;
@end
@implementation RewindDownloadProbeAPI
@synthesize hold;
- (void)dealloc { [_heldCompletion release]; [super dealloc]; }
- (void)resolve {
    RewindAudioCompletion callback = [_heldCompletion autorelease];
    _heldCompletion = nil;
    if (callback) callback(probeSource, nil);
}
- (void)streamURLForTrack:(RewindTrack *)track completion:(RewindAudioCompletion)completion {
    (void)track;
    if (hold) _heldCompletion = [completion copy];
    else completion(probeSource, nil);
}
@end

static int failures;
#define CHECK(value) do { if (!(value)) { fprintf(stderr, "failed: %s\n", #value); ++failures; } } while (0)

/* the fixture process must not load account state from the real Library directory */
static NSUInteger accountMixRequests;
BOOL RewindAccountIsSignedIn(void) { return NO; }
void RewindAccountLoadMix(RewindTrack *track, RewindAccountListCompletion completion) {
    (void)track;
    ++accountMixRequests;
    if (completion) completion(nil, [NSError errorWithDomain:@"RewindOfflineProbeUnexpectedAccountRequest"
        code:1 userInfo:nil]);
}

@interface RewindOfflineProbeAPI : RewindAPI {
    NSUInteger _resolutions;
}
@property(nonatomic, readonly) NSUInteger resolutions;
@end
@implementation RewindOfflineProbeAPI
- (NSUInteger)resolutions { return _resolutions; }
- (void)streamURLForTrack:(RewindTrack *)track completion:(RewindAudioCompletion)completion {
    [self streamURLForTrack:track excludingSources:nil completion:completion];
}
- (RewindAudioRequest *)streamURLForTrack:(RewindTrack *)track excludingSources:(NSSet *)sources
                             completion:(RewindAudioCompletion)completion {
    (void)track;
    (void)sources;
    ++_resolutions;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(nil, [NSError errorWithDomain:@"RewindOfflineProbeUnexpectedResolution"
            code:1 userInfo:nil]);
    });
    return nil;
}
@end

static void probe_pump(NSTimeInterval seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];
        [pool drain];
    }
}

static BOOL probe_wait_playing(RewindPlayer *player, NSURL *expected) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:15];
    while (end.timeIntervalSinceNow > 0) {
        AVPlayerItem *item = [(AVPlayer *)player.nativePlayer currentItem];
        if (item.status == AVPlayerItemStatusFailed) break;
        if (item.status == AVPlayerItemStatusReadyToPlay && player.playing && !player.loading &&
            player.currentTime >= 0.2 && player.duration > 1.5) {
            NSURL *actual = [(AVURLAsset *)item.asset URL];
            BOOL local = actual.isFileURL && [actual isEqual:expected];
            fprintf(stderr, "offline ready: %s time=%.3f duration=%.3f local=%d\n",
                [player.track.videoID UTF8String], player.currentTime, player.duration, local);
            return local;
        }
        probe_pump(0.025);
    }
    fprintf(stderr, "offline readiness failed: %s time=%.3f loading=%d playing=%d\n",
        [player.track.videoID UTF8String], player.currentTime, player.loading, player.playing);
    return NO;
}

static BOOL probe_wait_seek(RewindPlayer *player, NSTimeInterval target) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:5];
    while (end.timeIntervalSinceNow > 0) {
        if (fabs(player.currentTime - target) < 0.08) return YES;
        probe_pump(0.025);
    }
    fprintf(stderr, "offline seek failed: target=%.3f actual=%.3f\n", target, player.currentTime);
    return NO;
}

static RewindTrack *probe_stored_track(NSString *videoID) {
    for (RewindTrack *track in RewindDownloadedTracks())
        if ([track.videoID isEqual:videoID]) return track;
    return nil;
}

static void probe_check_files(NSArray *paths, NSArray *contents) {
    for (NSUInteger i = 0; i < paths.count; ++i) {
        NSData *current = [NSData dataWithContentsOfFile:[paths objectAtIndex:i]];
        CHECK(current && [current isEqual:[contents objectAtIndex:i]]);
    }
    CHECK(RewindDownloadedURLForTrack(@"DlProb00001") != nil);
    CHECK(RewindDownloadedURLForTrack(@"DlProb00002") != nil);
}

static void probe_offline_player(void) {
    RewindTrack *plainTrack = [probe_stored_track(@"DlProb00001") retain];
    RewindTrack *convertedTrack = [probe_stored_track(@"DlProb00002") retain];
    NSURL *plainURL = [RewindDownloadedURLForTrack(@"DlProb00001") retain];
    NSURL *convertedURL = [RewindDownloadedURLForTrack(@"DlProb00002") retain];
    CHECK(plainTrack && convertedTrack && plainURL && convertedURL);
    if (!plainTrack || !convertedTrack || !plainURL || !convertedURL) {
        [plainTrack release]; [convertedTrack release]; [plainURL release]; [convertedURL release];
        return;
    }
    NSUInteger storedCount = RewindDownloadedTracks().count;
    NSArray *paths = [NSArray arrayWithObjects:plainURL.path, convertedURL.path,
        [[plainURL.path stringByDeletingPathExtension] stringByAppendingPathExtension:@"plist"],
        [[convertedURL.path stringByDeletingPathExtension] stringByAppendingPathExtension:@"plist"], nil];
    NSMutableArray *contents = [NSMutableArray array];
    for (NSString *path in paths) {
        NSData *bytes = [NSData dataWithContentsOfFile:path];
        CHECK(bytes != nil);
        if (bytes) [contents addObject:bytes];
    }
    if (contents.count != paths.count) {
        [plainTrack release]; [convertedTrack release]; [plainURL release]; [convertedURL release];
        return;
    }
    RewindOfflineProbeAPI *api = [[RewindOfflineProbeAPI alloc] initWithAPIKey:@""];
    __block NSUInteger errors = 0;
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:RewindPlayerDidChangeNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            CHECK([NSThread isMainThread]);
            NSError *error = [note.userInfo objectForKey:@"error"];
            if (error) {
                ++errors;
                fprintf(stderr, "offline player error: %s\n", [error.description UTF8String]);
            }
        }];
    RewindPlayer *player = [[RewindPlayer alloc] init];
    [player setContinuousPlayback:NO];
    [player playTrack:plainTrack usingAPI:api];
    BOOL plainReady = probe_wait_playing(player, plainURL);
    CHECK(plainReady);
    if (plainReady) {
        [player toggle];
        NSTimeInterval paused = player.currentTime;
        probe_pump(0.2);
        CHECK(!player.playing && fabs(player.currentTime - paused) < 0.05);
        NSTimeInterval target = player.duration * 0.6;
        [player seekToProgress:0.6];
        CHECK(probe_wait_seek(player, target));
        CHECK(!player.playing);
        NSTimeInterval sought = player.currentTime;
        [player toggle];
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:5];
        while (player.currentTime < sought + 0.15 && end.timeIntervalSinceNow > 0) probe_pump(0.025);
        CHECK(player.playing && player.currentTime >= sought + 0.15);
        fprintf(stderr, "offline pause/seek/resume: paused=%.3f sought=%.3f resumed=%.3f\n",
            paused, sought, player.currentTime);
    }
    [player playTrack:convertedTrack usingAPI:api];
    CHECK(probe_wait_playing(player, convertedURL));
    probe_check_files(paths, contents);
    [player stop];
    [player release];
    probe_pump(0.1);
    probe_check_files(paths, contents);
    CHECK(RewindDownloadedTracks().count == storedCount);
    RewindTrack *reloaded = [probe_stored_track(@"DlProb00001") retain];
    CHECK(reloaded && reloaded != plainTrack && [reloaded.title isEqual:plainTrack.title]);
    player = [[RewindPlayer alloc] init];
    [player setContinuousPlayback:NO];
    if (reloaded) [player playTrack:reloaded usingAPI:api];
    CHECK(reloaded && probe_wait_playing(player, plainURL));
    [player stop];
    [player release];
    probe_pump(0.1);
    probe_check_files(paths, contents);
    CHECK(RewindDownloadedTracks().count == storedCount);
    CHECK(errors == 0 && api.resolutions == 0 && accountMixRequests == 0);
    fprintf(stderr, "offline lifecycle: playerErrors=%lu resolutions=%lu accountMix=%lu records=%lu\n",
        (unsigned long)errors, (unsigned long)api.resolutions, (unsigned long)accountMixRequests,
        (unsigned long)RewindDownloadedTracks().count);
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [api release];
    [reloaded release];
    [plainTrack release];
    [convertedTrack release];
    [plainURL release];
    [convertedURL release];
}

static NSError *download(NSURL *url, NSString *videoID) {
    __block BOOL done = NO;
    __block NSError *result = nil;
    fprintf(stderr, "download check: %s <- %s\n", [videoID UTF8String], [[url path] fileSystemRepresentation]);
    RewindStartDownload(url, videoID, ^(NSError *error) {
        CHECK([NSThread isMainThread]);
        result = [error retain];
        done = YES;
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:190];
    while (!done && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CHECK(done);
    return [result autorelease];
}

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    BOOL offlinePlayer = argc == 4 && !strcmp(argv[3], "--offline-player");
    if (argc != 3 && !offlinePlayer) {
        fprintf(stderr, "usage: DownloadProbe plain.m4a fragmented.m4a [--offline-player]\n");
        [pool drain];
        return 2;
    }
    downloadProbeDirectory = [[NSTemporaryDirectory() stringByAppendingPathComponent:
                              [[NSProcessInfo processInfo] globallyUniqueString]] retain];
    NSURL *plain = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
    NSURL *fragmented = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
    fprintf(stderr, "download probe: plain=%s fragmented=%s staging=%s\n",
        [plain.path fileSystemRepresentation], [fragmented.path fileSystemRepresentation],
        [downloadProbeDirectory fileSystemRepresentation]);
    __block NSUInteger notifications = 0;
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:RewindDownloadsDidChangeNotification
        object:nil queue:nil usingBlock:^(NSNotification *notification) {
            CHECK([NSThread isMainThread]);
            CHECK(rewind_audio_video_id([[notification.userInfo objectForKey:@"videoID"] UTF8String]));
            ++notifications;
        }];
    CHECK(download(plain, @"DlProb00001") == nil);
    CHECK(notifications == 1);
    NSURL *offline = RewindDownloadedURLForTrack(@"DlProb00001");
    CHECK(offline.isFileURL);
    CHECK([[NSFileManager defaultManager] fileExistsAtPath:plain.path]);
    CHECK(RewindDownloadedTracks().count == 1);
    if (RewindDownloadedTracks().count)
        CHECK([[[RewindDownloadedTracks() objectAtIndex:0] videoID] isEqual:@"DlProb00001"]);
    CHECK(download(fragmented, @"DlProb00002") == nil);
    CHECK(RewindDownloadedTracks().count == 2);
    NSURL *rebuiltURL = RewindDownloadedURLForTrack(@"DlProb00002");
    NSData *rebuilt = rebuiltURL ? [NSData dataWithContentsOfURL:rebuiltURL] : nil;
    const uint8_t *boxes = rebuilt.bytes;
    NSUInteger offset = 0;
    while (offset + 8 <= rebuilt.length) {
        uint32_t size = ((uint32_t)boxes[offset] << 24) | ((uint32_t)boxes[offset+1] << 16) |
                        ((uint32_t)boxes[offset+2] << 8) | boxes[offset+3];
        CHECK(memcmp(boxes + offset + 4, "moof", 4) != 0);
        CHECK(size >= 8 && size <= rebuilt.length - offset);
        if (size < 8 || size > rebuilt.length - offset) break;
        offset += size;
    }
    CHECK(rebuilt.length > 0 && offset == rebuilt.length);
    CHECK([[NSFileManager defaultManager] fileExistsAtPath:fragmented.path]);
    probeSource = plain;
    RewindTrack *metadataTrack = [[[RewindTrack alloc] initWithVideoID:@"DlProb00004" title:@"offline title"
        artist:@"offline artist" album:@"offline album" thumbnailURL:@"https://example.invalid/image" duration:2] autorelease];
    RewindAPI *api = [[[RewindDownloadProbeAPI alloc] initWithAPIKey:@""] autorelease];
    __block NSUInteger callbacks = 0;
    __block NSUInteger errors = 0;
    RewindDownloadTrack(metadataTrack, api, ^(NSError *error) {
        CHECK([NSThread isMainThread]);
        if (error) ++errors;
        ++callbacks;
    });
    RewindDownloadTrack(metadataTrack, api, ^(NSError *error) {
        CHECK(error != nil);
        if (error) ++errors;
        ++callbacks;
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:190];
    while (callbacks < 2 && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CHECK(callbacks == 2 && errors == 1);
    CHECK(RewindDownloadedTracks().count == 3);
    BOOL found = NO;
    for (RewindTrack *track in RewindDownloadedTracks()) {
        if ([track.videoID isEqual:@"DlProb00004"]) {
            found = YES;
            CHECK([track.title isEqual:metadataTrack.title]);
            CHECK([track.artist isEqual:metadataTrack.artist]);
            CHECK(track.duration == 2);
        }
    }
    CHECK(found);
    RewindDownloadProbeAPI *held[2];
    __block NSUInteger limitedCallbacks = 0;
    for (NSUInteger i = 0; i < 2; ++i) {
        held[i] = [[[RewindDownloadProbeAPI alloc] initWithAPIKey:@""] autorelease];
        held[i].hold = YES;
        RewindTrack *track = [[[RewindTrack alloc] initWithVideoID:i ? @"DlProb00006" : @"DlProb00005"
            title:@"limit" artist:@"" album:@"" thumbnailURL:@"" duration:2] autorelease];
        RewindDownloadTrack(track, held[i], ^(NSError *error) {
            CHECK([NSThread isMainThread]);
            CHECK(error == nil);
            ++limitedCallbacks;
        });
    }
    CHECK(download(plain, @"DlProb00007") != nil);
    CHECK(RewindDownloadActive().count == 2);
    [held[0] resolve];
    [held[1] resolve];
    deadline = [NSDate dateWithTimeIntervalSinceNow:190];
    while (limitedCallbacks < 2 && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CHECK(limitedCallbacks == 2);
    CHECK(RewindDownloadActive().count == 0);
    CHECK(RewindDownloadedTracks().count == 5);
    CHECK(download(plain, @"DlProb00007") == nil);
    CHECK(RewindDownloadedTracks().count == 6);
    NSString *recordPath = [downloadProbeDirectory stringByAppendingPathComponent:@"DlProb00007.plist"];
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:recordPath];
    NSMutableDictionary *invalid = [[saved mutableCopy] autorelease];
    [invalid setObject:@(-1) forKey:@"duration"];
    CHECK([invalid writeToFile:recordPath atomically:YES]);
    CHECK(RewindDownloadedURLForTrack(@"DlProb00007") == nil);
    CHECK([saved writeToFile:recordPath atomically:YES]);
    CHECK([[NSFileManager defaultManager] removeItemAtPath:recordPath error:NULL]);
    CHECK(symlink([plain.path fileSystemRepresentation], [recordPath fileSystemRepresentation]) == 0);
    CHECK(RewindDownloadedURLForTrack(@"DlProb00007") == nil);
    CHECK(unlink([recordPath fileSystemRepresentation]) == 0);
    CHECK([saved writeToFile:recordPath atomically:YES]);
    unichar embeddedID[] = {'D', 'l', 'P', 'r', 'o', 'b', '0', '0', '0', '0', '8', 0, 'x'};
    NSString *invalidID = [NSString stringWithCharacters:embeddedID length:sizeof(embeddedID) / sizeof(embeddedID[0])];
    CHECK(download(plain, invalidID) != nil);
    CHECK(RewindDownloadedURLForTrack(invalidID) == nil);
    CHECK(download(plain, @"../../badid") != nil);
    CHECK(RewindDownloadedURLForTrack(@"../../badid") == nil);
    NSString *junk = [downloadProbeDirectory stringByAppendingPathComponent:@"junk"];
    CHECK([@"<html>not audio</html>" writeToFile:junk atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    CHECK(download([NSURL fileURLWithPath:junk], @"DlProb00003") != nil);
    CHECK(RewindDownloadedURLForTrack(@"DlProb00003") == nil);
    NSData *fixture = [NSData dataWithContentsOfURL:plain];
    CHECK(fixture.length > 1 && fixture.length < 1024 * 1024);
    if (fixture.length > 1 && fixture.length < 1024 * 1024) {
        CHECK([[fixture subdataWithRange:NSMakeRange(0, fixture.length - 1)] writeToFile:junk atomically:YES]);
        CHECK(download([NSURL fileURLWithPath:junk], @"DlProb00003") != nil);
    }
    int oversized = open([junk fileSystemRepresentation], O_WRONLY | O_TRUNC);
    CHECK(oversized >= 0);
    if (oversized >= 0) {
        CHECK(ftruncate(oversized, 100 * 1024 * 1024 + 1) == 0);
        CHECK(close(oversized) == 0);
        CHECK(download([NSURL fileURLWithPath:junk], @"DlProb00003") != nil);
    }
    CHECK(download([NSURL URLWithString:@"http://example.invalid/audio"], @"DlProb00003") != nil);
    CHECK(download(plain, @"DlProb00001") == nil);
    CHECK(RewindDownloadedTracks().count == 6);
    if (offlinePlayer) probe_offline_player();
    /* a missing payload must disappear from both synchronous helpers */
    CHECK(offline && [[NSFileManager defaultManager] removeItemAtPath:offline.path error:NULL]);
    CHECK(RewindDownloadedURLForTrack(@"DlProb00001") == nil);
    CHECK(RewindDownloadedTracks().count == 5);
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:downloadProbeDirectory error:NULL])
        CHECK([name isEqual:@"junk"] || [[name pathExtension] isEqual:@"m4a"] || [[name pathExtension] isEqual:@"plist"]);
    NSError *cleanup = nil;
    CHECK([[NSFileManager defaultManager] removeItemAtPath:downloadProbeDirectory error:&cleanup]);
    if (cleanup) fprintf(stderr, "cleanup: %s\n", [[cleanup description] UTF8String]);
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [downloadProbeDirectory release];
    fprintf(stderr, "download checks: %s\n", failures ? "FAILED" : "passed");
    [pool drain];
    return failures ? 1 : 0;
}
