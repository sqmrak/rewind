#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import "rewind_api.h"
#import "rewind_config.h"
#import "rewind_player.h"
#import "rewind_account.h"
#include "rewind_audio.h"
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#ifdef REWIND_STATE_FIXTURES_ONLY
/* the local fixture binary must not read the device account or request account radio */
BOOL RewindAccountIsSignedIn(void) { return NO; }
void RewindAccountLoadMix(RewindTrack *track, RewindSearchCompletion completion) {
    (void)track;
    completion(nil, [NSError errorWithDomain:@"RewindFixtureUnexpectedAccountRequest" code:1 userInfo:nil]);
}
#endif

static void probe_pump(NSTimeInterval interval) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:interval];
    while ([end timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];
}

@interface RewindPlayer (RewindProbeState)
- (void)itemDidFinish:(NSNotification *)note;
- (void)loadMoreTracks;
- (void)loadTimedOut:(NSTimer *)timer;
@end

@interface RewindFixtureAPI : RewindAPI {
    RewindShelvesCompletion _related;
    RewindSearchCompletion _search;
}
- (void)finishRelated;
- (void)finishSearch:(NSArray *)tracks error:(NSError *)error;
@end

@implementation RewindFixtureAPI
- (void)relatedForTrack:(RewindTrack *)track completion:(RewindShelvesCompletion)completion {
    (void)track;
    [_related release];
    _related = [completion copy];
}
- (void)search:(NSString *)query completion:(RewindSearchCompletion)completion {
    (void)query;
    [_search release];
    _search = [completion copy];
}
- (void)finishRelated {
    RewindShelvesCompletion completion = [[_related copy] autorelease];
    [_related release];
    _related = nil;
    if (completion) completion([NSArray array], nil, nil);
}
- (void)finishSearch:(NSArray *)tracks error:(NSError *)error {
    RewindSearchCompletion completion = [[_search copy] autorelease];
    [_search release];
    _search = nil;
    if (completion) completion(tracks, error);
}
- (void)dealloc {
    [_related release];
    [_search release];
    [super dealloc];
}
@end

@interface RewindFixturePlayer : RewindPlayer
- (BOOL)wantsPlayback;
- (void)seedTrack:(RewindTrack *)track api:(RewindAPI *)api;
@end

@implementation RewindFixturePlayer
/* deferred local callbacks exercise queue state without resolving network audio */
- (void)loadAudio { }
- (BOOL)wantsPlayback { return _wantsPlayback; }
- (void)seedTrack:(RewindTrack *)track api:(RewindAPI *)api {
    [self playTrack:track usingAPI:api];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:
        [NSURL fileURLWithPath:@"/rewind-probe-missing-fixture.m4a"]];
    _player = [[AVPlayer alloc] initWithPlayerItem:item];
    _buffering = YES;
}
@end

static BOOL probe_state_fixtures(void) {
    RewindFixtureAPI *api = [[RewindFixtureAPI alloc] initWithAPIKey:RewindDefaultAPIKey];
    RewindFixturePlayer *state = [[RewindFixturePlayer alloc] init];
    RewindTrack *track = [[RewindTrack alloc] initWithVideoID:@"XnMiO4V3G58"
        title:@"fixture" artist:nil album:nil thumbnailURL:nil duration:1];
    __block NSUInteger notifications = 0;
    __block BOOL sawLoading = NO;
    __block NSError *lastError = nil;
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:RewindPlayerDidChangeNotification
        object:state queue:nil usingBlock:^(NSNotification *note) {
        ++notifications;
        if (state.loading) sawLoading = YES;
        [lastError release];
        lastError = [[note.userInfo objectForKey:@"error"] retain];
    }];
    [state setContinuousPlayback:NO];
    [state seedTrack:track api:api];
    [state itemDidFinish:[NSNotification notificationWithName:AVPlayerItemDidPlayToEndTimeNotification
        object:[(AVPlayer *)state.nativePlayer currentItem]]];
    BOOL endOK = !state.wantsPlayback;
    [state toggle];
    endOK = endOK && state.wantsPlayback;
    [state stop];
    [state playTrack:track usingAPI:api];
    NSUInteger before = notifications;
    [state loadMoreTracks];
    BOOL startOK = state.loading && sawLoading && notifications > before;
    [api finishRelated];
    BOOL fallbackOK = state.loading;
    [api finishSearch:[NSArray arrayWithObject:track] error:nil];
    BOOL emptyOK = !state.loading && !state.wantsPlayback && lastError != nil;
    [state loadMoreTracks];
    [api finishRelated];
    NSError *failure = [NSError errorWithDomain:@"RewindFixture" code:1 userInfo:nil];
    [api finishSearch:nil error:failure];
    BOOL failureOK = !state.loading && !state.wantsPlayback && lastError == failure;
    [state loadMoreTracks];
    [state loadTimedOut:[state valueForKey:@"loadTimer"]];
    BOOL timeoutOK = !state.loading && !state.wantsPlayback && lastError.code == 12;
    before = notifications;
    [api finishRelated];
    BOOL staleOK = notifications == before && !state.loading;
    [state loadMoreTracks];
    [api finishRelated];
    RewindTrack *next = [[RewindTrack alloc] initWithVideoID:@"dQw4w9WgXcQ"
        title:@"next fixture" artist:nil album:nil thumbnailURL:nil duration:1];
    [api finishSearch:[NSArray arrayWithObjects:track, next, next, nil] error:nil];
    BOOL advanceOK = state.track == next && state.queue.count == 2 && state.wantsPlayback && !state.loading;
    [state stop];
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [lastError release];
    [next release];
    [track release];
    [state release];
    [api release];
    printf("state fixtures end %d start %d fallback %d empty %d failure %d timeout %d stale %d advance %d\n",
        endOK, startOK, fallbackOK, emptyOK, failureOK, timeoutOK, staleOK, advanceOK);
    return endOK && startOK && fallbackOK && emptyOK && failureOK && timeoutOK && staleOK && advanceOK;
}

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc == 2 && !strcmp(argv[1], "--state-fixtures")) {
#ifdef REWIND_STATE_FIXTURES_ONLY
        BOOL passed = probe_state_fixtures();
#else
        printf("build with tests/build_device_probe.sh --state-fixtures for isolated local cases\n");
        (void)probe_state_fixtures;
        BOOL passed = NO;
#endif
        [pool drain];
        return passed ? 0 : 1;
    }
#ifdef REWIND_STATE_FIXTURES_ONLY
    [pool drain];
    return 2;
#endif
    BOOL forceStall = NO;
    NSString *nextVideo = nil;
    BOOL argumentsOK = argc >= 2 && rewind_audio_video_id(argc >= 2 ? argv[1] : NULL);
    for (int i = 2; argumentsOK && i < argc; ++i) {
        if (!strcmp(argv[i], "--stall") && !forceStall) forceStall = YES;
        else if (!strcmp(argv[i], "--next-track") && !nextVideo && i + 1 < argc &&
                 rewind_audio_video_id(argv[i + 1])) nextVideo = [NSString stringWithUTF8String:argv[++i]];
        else argumentsOK = NO;
    }
    if (!argumentsOK) {
        printf("usage: RewindProbe <id> [--stall] [--next-track <id>]\n");
        [pool drain];
        return 2;
    }
    printf("bundle %s ios %s\n", [[[NSBundle mainBundle] bundleIdentifier] UTF8String], [[[UIDevice currentDevice] systemVersion] UTF8String]);
    void *tls = dlopen("/usr/lib/senkotlsfix.dylib", RTLD_NOW | RTLD_GLOBAL);
    printf("tls loaded %d\n", tls != NULL);
    NSString *video = [NSString stringWithUTF8String:argv[1]];
    RewindTrack *track = [[RewindTrack alloc] initWithVideoID:video title:video artist:nil album:nil thumbnailURL:nil duration:0];
    id key = [[NSUserDefaults standardUserDefaults] objectForKey:REWIND_API_KEY_DEFAULTS_KEY];
    RewindAPI *api = [[RewindAPI alloc] initWithAPIKey:[key isKindOfClass:[NSString class]] && [key length] ? key : RewindDefaultAPIKey];
    RewindPlayer *state = [[RewindPlayer alloc] init];
    [state setContinuousPlayback:NO];
    __block BOOL ended = NO;
    __block AVPlayerItem *transitionItem = nil;
    __block BOOL transitionEnded = NO;
    __block NSUInteger stateErrors = 0;
    __block NSTimeInterval transitionStarted = 0;
    __block RewindTrack *transitionTrack = nil;
    id endObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
        if (note.object == [(AVPlayer *)state.nativePlayer currentItem]) ended = YES;
        if (transitionItem && note.object == transitionItem) transitionEnded = YES;
    }];
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:RewindPlayerDidChangeNotification object:state queue:nil usingBlock:^(NSNotification *note) {
        NSError *problem = [note.userInfo objectForKey:@"error"];
        if (problem) ++stateErrors;
        if (transitionTrack && state.track == transitionTrack && !transitionStarted)
            transitionStarted = [NSDate timeIntervalSinceReferenceDate];
        if (problem) printf("state error %s:%ld %s\n", [problem.domain UTF8String], (long)problem.code, [problem.localizedDescription UTF8String]);
    }];
    [state playTrack:track usingAPI:api];
    NSDate *started = [NSDate date];
    while (state.loading && -[started timeIntervalSinceNow] < 100) probe_pump(0.1);
    printf("state resolved elapsed %.2f duration %.3f loading %d playing %d\n", -[started timeIntervalSinceNow], state.duration, state.loading, state.playing);
    for (int i = 0; i < 8; ++i) {
        probe_pump(1.0);
        printf("state play %d time %.3f rate %.2f loading %d playing %d\n", i, state.currentTime,
               [(AVPlayer *)state.nativePlayer rate], state.loading, state.playing);
    }
    double before = state.currentTime;
    [state toggle];
    double paused = state.currentTime;
    probe_pump(2.0);
    BOOL pauseOK = !state.playing && fabs(state.currentTime - paused) < 0.2;
    printf("state paused time %.3f unchanged %d\n", state.currentTime, pauseOK);
    [state toggle];
    [state seekToProgress:0.75];
    double firstSeekTime = 0;
    for (int i = 0; i < 5; ++i) {
        probe_pump(1.0);
        if (i == 0) firstSeekTime = state.currentTime;
        printf("state seek %d time %.3f rate %.2f loading %d playing %d\n", i, state.currentTime,
               [(AVPlayer *)state.nativePlayer rate], state.loading, state.playing);
    }
    double seekStart = state.currentTime;
    BOOL seekOK = seekStart > state.duration * 0.7 && seekStart > firstSeekTime + 2;
    if (forceStall) {
        AVPlayer *blocked = [(AVPlayer *)state.nativePlayer retain];
        NSString *blockedKey = [RewindAudioSourceKeyForURL([(AVURLAsset *)blocked.currentItem.asset URL]) copy];
        [blocked setRate:0];
        printf("state forced stall at %.3f\n", state.currentTime);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:100];
        while ([deadline timeIntervalSinceNow] > 0 && state.nativePlayer == blocked) probe_pump(0.1);
        while ([deadline timeIntervalSinceNow] > 0 && state.loading) probe_pump(0.1);
        double resumed = state.currentTime;
        probe_pump(3.0);
        BOOL recovered = state.nativePlayer != blocked && state.playing && state.currentTime > resumed + 1;
        printf("state stall recovery %d old %s new %s time %.3f\n", recovered, [blockedKey UTF8String], [RewindAudioSourceKeyForURL([(AVURLAsset *)[(AVPlayer *)state.nativePlayer currentItem].asset URL]) UTF8String], state.currentTime);
        [blockedKey release];
        [blocked release];
        seekOK = seekOK && recovered;
    }
    [state seekToProgress:0.98];
    NSDate *endDeadline = [NSDate dateWithTimeIntervalSinceNow:12];
    while (!ended && [endDeadline timeIntervalSinceNow] > 0) probe_pump(0.1);
    BOOL endOK = ended && !state.playing && !state.loading && state.currentTime > state.duration - 0.3;
    printf("state end reached %d time %.3f duration %.3f\n", endOK, state.currentTime, state.duration);
    [state toggle];
    probe_pump(3.0);
    BOOL restartOK = state.playing && state.currentTime > 1 && state.currentTime < state.duration * 0.5;
    printf("state single-tap restart %d time %.3f\n", restartOK, state.currentTime);
    endOK = endOK && restartOK;
    BOOL nextOK = YES;
    if (nextVideo) {
        RewindTrack *next = [[RewindTrack alloc] initWithVideoID:nextVideo title:nextVideo
            artist:nil album:nil thumbnailURL:nil duration:0];
        NSString *firstSource = [RewindAudioSourceKeyForURL(
            [(AVURLAsset *)[(AVPlayer *)state.nativePlayer currentItem].asset URL]) copy];
        transitionTrack = next;
        transitionItem = [[(AVPlayer *)state.nativePlayer currentItem] retain];
        NSUInteger errorsBefore = stateErrors;
        [state enqueueTrack:next usingAPI:api afterCurrent:YES];
        [state seekToProgress:state.duration > 2 ? (float)(1 - 2 / state.duration) : 0];
        NSDate *transitionDeadline = [NSDate dateWithTimeIntervalSinceNow:12];
        while ([transitionDeadline timeIntervalSinceNow] > 0 && !transitionStarted &&
               stateErrors == errorsBefore) probe_pump(0.1);
        BOOL switched = transitionStarted > 0 && transitionEnded && state.track == next && state.queueIndex == 1;
        NSDate *resolveDeadline = [NSDate dateWithTimeIntervalSinceNow:100];
        while (switched && state.loading && [resolveDeadline timeIntervalSinceNow] > 0 &&
               stateErrors == errorsBefore) probe_pump(0.1);
        NSTimeInterval elapsed = transitionStarted > 0
            ? [NSDate timeIntervalSinceReferenceDate] - transitionStarted : -1;
        double secondStart = state.currentTime;
        NSString *secondSource = RewindAudioSourceKeyForURL(
            [(AVURLAsset *)[(AVPlayer *)state.nativePlayer currentItem].asset URL]);
        printf("state next resolved switched %d elapsed %.2f old %s new %s loading %d errors %lu\n",
            switched, elapsed, firstSource ? [firstSource UTF8String] : "unregistered",
            secondSource ? [secondSource UTF8String] : "unregistered", state.loading,
            (unsigned long)(stateErrors - errorsBefore));
        for (int i = 0; i < 3; ++i) {
            probe_pump(1.0);
            printf("state next play %d time %.3f rate %.2f loading %d playing %d\n",
                i, state.currentTime, [(AVPlayer *)state.nativePlayer rate], state.loading, state.playing);
        }
        nextOK = switched && state.track == next && state.queueIndex == 1 && !state.loading &&
                 state.playing && [(AVPlayer *)state.nativePlayer rate] > 0 &&
                 state.currentTime > secondStart + 1 && stateErrors == errorsBefore;
        printf("state automatic next result %d\n", nextOK);
        [transitionItem release];
        transitionItem = nil;
        [firstSource release];
        transitionTrack = nil;
        [next release];
    }
    [state stop];
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [[NSNotificationCenter defaultCenter] removeObserver:endObserver];
    [state release];
    [track release];
    [api release];
    printf("state result advanced %d paused %d seek %d ended %d next %d\n", before > 3.0, pauseOK, seekOK, endOK, nextOK);
    [pool drain];
    return before > 3.0 && pauseOK && seekOK && endOK && nextOK ? 0 : 1;
}
