#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import "rewind_api.h"
#import "video_vc.h"
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char probe_home[] = "/tmp/rewind-video-probe.XXXXXX";
static unsigned checks, failures;
static void deadline(int number) {
    (void)number;
    static const char text[] = "FAIL: video probe exceeded 150 second deadline\n";
    write(STDERR_FILENO, text, sizeof(text) - 1);
    _exit(124);
}
static void check(BOOL passed, NSString *text) {
    ++checks;
    fprintf(stderr, "%s: %s\n", passed ? "PASS" : "FAIL", [text UTF8String]);
    if (!passed) ++failures;
}
static void pump(NSTimeInterval seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([end timeIntervalSinceNow] > 0) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];
        [pool drain];
    }
}
static double time_seconds(AVPlayer *player) { return CMTimeGetSeconds(player.currentTime); }

static BOOL playback(AVPlayer *player) {
    CALayer *host = [[CALayer alloc] init];
    AVPlayerLayer *videoLayer = [[AVPlayerLayer playerLayerWithPlayer:player] retain];
    videoLayer.frame = CGRectMake(0, 0, 320, 240);
    [host addSublayer:videoLayer];
    AVPlayerItem *item = player.currentItem;
    __block NSError *failure = nil;
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:
        AVPlayerItemFailedToPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [failure release];
        failure = [[note.userInfo objectForKey:AVPlayerItemFailedToPlayToEndTimeErrorKey] retain];
        if (!failure) failure = [[NSError alloc] initWithDomain:@"VideoProbe" code:1 userInfo:nil];
    }];
    NSDate *start = [NSDate date];
    while (item.status == AVPlayerItemStatusUnknown && -[start timeIntervalSinceNow] < 25) pump(0.1);
    check(item.status == AVPlayerItemStatusReadyToPlay && !item.error, @"AVPlayerItem ready without error within 25 seconds");
    if (item.status == AVPlayerItemStatusReadyToPlay) {
        __block BOOL loadedTracks = NO;
        [item.asset loadValuesAsynchronouslyForKeys:[NSArray arrayWithObject:@"tracks"] completionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{ loadedTracks = YES; });
        }];
        start = [NSDate date];
        while (!loadedTracks && -[start timeIntervalSinceNow] < 20) pump(0.1);
        NSError *tracksError = nil;
        check(loadedTracks && [item.asset statusOfValueForKey:@"tracks" error:&tracksError] == AVKeyValueStatusLoaded,
              @"asset track metadata loads within twenty seconds");
        NSMutableArray *tracks = [NSMutableArray array];
        start = [NSDate date];
        while (!tracks.count && -[start timeIntervalSinceNow] < 5) {
            for (AVPlayerItemTrack *track in item.tracks)
                if ([track.assetTrack.mediaType isEqualToString:AVMediaTypeVideo] && track.enabled)
                    [tracks addObject:track.assetTrack];
            if (!tracks.count) pump(0.1);
        }
        fprintf(stderr, "status=%ld enabled video tracks=%lu\n", (long)item.status, (unsigned long)tracks.count);

        if (tracks.count) {
            AVAssetTrack *videoTrack = [tracks objectAtIndex:0];
            NSError *decodeError = nil;
            AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:videoTrack.asset error:&decodeError];
            AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
                initWithTrack:videoTrack outputSettings:[NSDictionary dictionaryWithObject:
                    [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA] forKey:(NSString *)kCVPixelBufferPixelFormatTypeKey]];
            BOOL decoded = NO;
            if (reader && [reader canAddOutput:output]) {
                [reader addOutput:output];
                if ([reader startReading]) {
                    CMSampleBufferRef sample = [output copyNextSampleBuffer];
                    decoded = sample && CMSampleBufferGetImageBuffer(sample) != NULL;
                    if (sample) CFRelease(sample);
                }
            }
            check(decoded, @"native decoder produces an actual video frame");
            [reader cancelReading];
            [output release];
            [reader release];
        }
        [player play];
        double before = time_seconds(player), current = before;
        start = [NSDate date];
        while (-[start timeIntervalSinceNow] < 10 && !failure && item.status != AVPlayerItemStatusFailed) {
            pump(0.2);
            current = time_seconds(player);
            if (isfinite(before) && isfinite(current) && current - before >= 1.0) break;
        }
        fprintf(stderr, "clock before=%.3f after=%.3f rate=%.2f\n", before, current, player.rate);
        check(isfinite(before) && isfinite(current) && current - before >= 1.0,
            @"native playback clock advances at least one second within ten seconds");
        check(!failure && !item.error && item.status == AVPlayerItemStatusReadyToPlay,
            @"playback has no item or end failure");
        if (!tracks.count) {
            start = [NSDate date];
            while (!videoLayer.readyForDisplay && -[start timeIntervalSinceNow] < 10) pump(0.1);
            check(videoLayer.readyForDisplay, @"remote video layer has a decoded frame for display");
        }
        [player pause];
        pump(0.2);
        double paused = time_seconds(player);
        pump(1.0);
        check(player.rate == 0 && isfinite(paused) && fabs(time_seconds(player) - paused) < 0.15,
            @"pause stops native clock");
    } else {
        fprintf(stderr, "item error domain=%s code=%ld\n", [item.error.domain UTF8String] ?: "none", (long)item.error.code);
    }
    [player pause];
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [failure release];
    videoLayer.player = nil;
    [videoLayer removeFromSuperlayer];
    [videoLayer release];
    [host release];
    return failures == 0;
}

static NSURL *resolve_video(void) {
    RewindAPI *api = [[RewindAPI alloc] initWithAPIKey:RewindDefaultAPIKey];
    /* Video results select their own id; songs require an exact counterpart */
    RewindTrack *track = [[RewindTrack alloc] initWithVideoID:@"dQw4w9WgXcQ" title:@"video probe"
        artist:nil album:nil thumbnailURL:nil duration:0 playlistID:nil artistID:nil resultType:@"Video"];
    __block BOOL completed = NO;
    __block NSURL *resolved = nil;
    [api musicVideoStreamForTrack:track completion:^(NSURL *url, NSError *error) {
        check([NSThread isMainThread], @"production resolver completion on main thread");
        completed = YES;
        resolved = [url retain];
        check(url != nil && error == nil, @"production video resolver succeeds");
        if (error) fprintf(stderr, "resolver error domain=%s code=%ld\n", [error.domain UTF8String], (long)error.code);
    }];
    NSDate *start = [NSDate date];
    while (!completed && -[start timeIntervalSinceNow] < 90) pump(0.1);
    check(completed, @"production resolver completes within 90 seconds");
    [track release];
    [api release];
    /* the API has no cancellation handle; exit after a timeout before late callbacks can run */
    if (!completed) exit(1);
    return [resolved autorelease];
}
static int finish(void) {
    fprintf(stderr, "video probe: %u checks, %u failures; home=%s\n", checks, failures, probe_home);
    return failures ? 1 : 0;
}

@interface RewindVideoProbeDelegate : NSObject <UIApplicationDelegate> {
    UIWindow *window;
    RewindVideoVC *controller;
}
@end
@implementation RewindVideoProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    fprintf(stderr, "registered local-video UI delegate entered\n");
    window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.rootViewController = [[[UIViewController alloc] init] autorelease];
    [window makeKeyAndVisible];
    [self performSelector:@selector(run) withObject:nil afterDelay:0];
    return YES;
}
- (void)run {
    @try {
        NSString *clip = [[NSBundle mainBundle] pathForResource:@"fixture" ofType:@"mp4"];
        check(clip != nil, @"bundled deterministic H.264/AAC fixture exists");
        if (!clip) exit(finish());
        controller = [[RewindVideoVC alloc] initWithURL:[NSURL fileURLWithPath:clip] userAgent:nil];
        [window.rootViewController presentViewController:controller animated:NO completion:nil];
        pump(0.2);
        AVPlayer *native = [[controller valueForKey:@"player"] retain];
        playback(native);
        CGSize sizes[] = {{320,460}, {480,300}, {768,1004}, {1024,748}, {320,460}};
        for (unsigned i = 0; i < sizeof(sizes)/sizeof(sizes[0]); ++i) {
            controller.view.bounds = (CGRect){CGPointZero, sizes[i]};
            [controller.view setNeedsLayout];
            [controller.view layoutIfNeeded];
            AVPlayerLayer *layer = [controller valueForKey:@"video"];
            check(CGRectEqualToRect(layer.frame, controller.view.bounds), @"real video layer follows host bounds");
            for (NSString *key in [NSArray arrayWithObjects:@"close", @"play", nil]) {
                UIView *button = [controller valueForKey:key];
                check(button && CGRectContainsRect(controller.view.bounds, button.frame), @"video control stays within host");
            }
        }
        check([controller shouldAutorotateToInterfaceOrientation:UIInterfaceOrientationLandscapeLeft],
            @"production controller admits iOS 5 landscape rotation");
        UIControl *play_button = [controller valueForKey:@"play"];
        [play_button sendActionsForControlEvents:UIControlEventTouchUpInside];
        pump(0.2);
        check(native.rate > 0, @"production play button resumes paused native player");
        [play_button sendActionsForControlEvents:UIControlEventTouchUpInside];
        pump(0.2);
        check(native.rate == 0, @"production play button pauses native player");
        [native play];
        [window.rootViewController dismissViewControllerAnimated:NO completion:nil];
        pump(0.2);
        check(native.rate == 0 && ![[controller valueForKey:@"visible"] boolValue], @"actual modal dismissal pauses video");
        check([controller valueForKey:@"loadTimer"] == nil, @"dismissal clears load timer");
        [controller release]; controller = nil;
        pump(0.2);
        [native replaceCurrentItemWithPlayerItem:nil];
        check(native.currentItem == nil, @"retained native player item can be detached after controller teardown");
        [native release];
    } @catch (NSException *exception) {
        check(NO, [NSString stringWithFormat:@"UI exception: %@", exception.name]);
    }
    exit(finish());
}
- (void)dealloc { [controller release]; [window release]; [super dealloc]; }
@end

int main(int argc, char **argv) {
    BOOL cli = argc == 2 && !strcmp(argv[1], "--network");
    BOOL local = argc == 3 && !strcmp(argv[1], "--local") && argv[2][0] == '/';
    if (argc != 1 && !cli && !local) {
        fprintf(stderr, "usage: RewindVideoProbe --network | --local /absolute/clip.mp4\nno arguments: registered local UIKit app\n");
        return 2;
    }
    if (!mkdtemp(probe_home) || setenv("CFFIXED_USER_HOME", probe_home, 1)) {
        perror("isolated video probe home");
        return 2;
    }
    signal(SIGALRM, deadline);
    alarm(150);
    char log_path[sizeof(probe_home) + 16];
    snprintf(log_path, sizeof(log_path), "%s/run.log", probe_home);
    if (!cli && !local && !freopen(log_path, "w", stderr)) return 2;
    setvbuf(stderr, NULL, _IONBF, 0);
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    check([NSHomeDirectory() isEqualToString:[NSString stringWithUTF8String:probe_home]], @"isolated Foundation home");
    check([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.sqmrak.rewind.video-probe"], @"isolated bundle identifier");
    if (failures) return 2;
    if (!cli && !local) {
        NSLog(@"video probe log=%s", log_path);
        int result = UIApplicationMain(argc, argv, nil, NSStringFromClass([RewindVideoProbeDelegate class]));
        [pool drain];
        return result;
    }
    NSURL *url = local ? [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]] : resolve_video();
    if (url) {
        NSString *agent = local ? nil : RewindAudioUserAgentForURL(url);
        NSDictionary *options = agent.length ? [NSDictionary dictionaryWithObject:
            [NSDictionary dictionaryWithObject:agent forKey:@"User-Agent"] forKey:@"AVURLAssetHTTPHeaderFieldsKey"] : nil;
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:options];
        AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
        AVPlayer *player = [[AVPlayer alloc] initWithPlayerItem:item];
        @try { playback(player); }
        @catch (NSException *exception) { check(NO, [NSString stringWithFormat:@"playback exception: %@", exception.name]); }
        [player pause];
        [player replaceCurrentItemWithPlayerItem:nil];
        check(player.currentItem == nil, @"native playback item detached during cleanup");
        [player release];
    }
    int result = finish();
    [pool drain];
    return result;
}
