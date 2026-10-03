#import "rewind_player.h"

#include <objc/message.h>

#import <dispatch/dispatch.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "rewind_api.h"
#import "rewind_account.h"
#import "rewind_image_cache.h"
#import "rewind_config.h"
#import "rewind_download.h"
#import "rewind_stream.h"

#include <math.h>
#include <dlfcn.h>

NSString * const RewindPlayerDidChangeNotification = @"RewindPlayerDidChangeNotification";

static NSString *RewindStalledNotificationName(void) {
    /* ios 5 has no playback stalled notification; a nil name removes every observer */
    NSString *const *name = dlsym(RTLD_DEFAULT, "AVPlayerItemPlaybackStalledNotification");
    return name ? *name : nil;
}

/* the ios 6 headers do not declare the initializer added in ios 10 */
@interface MPMediaItemArtwork (RewindIOS10)
- (id)initWithBoundsSize:(CGSize)size
          requestHandler:(UIImage *(^)(CGSize size))handler;
@end

static MPMediaItemArtwork *RewindArtworkForImage(UIImage *image) {
    if (!image || ![MPMediaItemArtwork class]) return nil;

    if ([MPMediaItemArtwork instancesRespondToSelector:
         @selector(initWithBoundsSize:requestHandler:)]) {
        return [[MPMediaItemArtwork alloc]
                initWithBoundsSize:image.size
                requestHandler:^UIImage *(CGSize size) {
                    (void)size;
                    return image;
                }];
    }

    return [[MPMediaItemArtwork alloc] initWithImage:image];
}

static void RewindConfigureAudioSession(void) {
    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&sessionError])
        RewindDebugLog(@"audio session category failed: %@", sessionError);
    sessionError = nil;
    /* ios 5 exposes setMode:error: but rejects MoviePlayback with OSStatus -50 */
    if ([session respondsToSelector:@selector(setMode:error:)] &&
        ![session setMode:AVAudioSessionModeDefault error:&sessionError])
        RewindDebugLog(@"audio session mode failed: %@", sessionError);
    sessionError = nil;
    if (![session setActive:YES error:&sessionError])
        RewindDebugLog(@"audio session activation failed: %@", sessionError);
}

static void RewindUpdateNowPlaying(RewindPlayer *player) {
    Class centerClass = NSClassFromString(@"MPNowPlayingInfoCenter");
    if (!centerClass) return;
    id center = [centerClass performSelector:@selector(defaultCenter)];
    if (!center) return;

    RewindTrack *track = player.track;
    if (!track) {
        [center setValue:nil forKey:@"nowPlayingInfo"];
        return;
    }

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (track.title.length) [info setObject:track.title forKey:@"title"];
    if (track.artist.length)
        [info setObject:RewindTrackArtistText(track) forKey:@"artist"];
    if (track.album.length) [info setObject:track.album forKey:@"albumTitle"];
    NSTimeInterval duration = [player duration];
    if (duration > 0.0) {
        [info setObject:[NSNumber numberWithDouble:duration] forKey:@"playbackDuration"];
        [info setObject:[NSNumber numberWithDouble:[player currentTime]]
                 forKey:@"elapsedPlaybackTime"];
    }
    [info setObject:[NSNumber numberWithFloat:player.isPlaying ? 1.0f : 0.0f]
             forKey:@"playbackRate"];
    if (player.queue.count) {
        [info setObject:[NSNumber numberWithUnsignedInteger:player.queue.count]
                 forKey:@"playbackQueueCount"];
    }
    [center setValue:info forKey:@"nowPlayingInfo"];
}

static void RewindUpdateNowPlayingArtwork(RewindPlayer *player, RewindTrack *track,
                                       NSUInteger generation) {
    if (!track.thumbnailURL.length) return;
    NSString *requestedURL = [track.thumbnailURL copy];
    RewindLoadImage(requestedURL, ^(UIImage *image) {
        if (!image || player.track != track || generation == 0) return;
        Class centerClass = NSClassFromString(@"MPNowPlayingInfoCenter");
        if (![MPMediaItemArtwork class] || !centerClass) return;
        MPMediaItemArtwork *artwork = RewindArtworkForImage(image);
        id center = [centerClass performSelector:@selector(defaultCenter)];
        if (!artwork || !center || player.track != track) {
            [artwork release];
            return;
        }
        NSMutableDictionary *info = [[[center valueForKey:@"nowPlayingInfo"] mutableCopy]
                                     autorelease];
        if (!info) info = [NSMutableDictionary dictionary];
        [info setObject:artwork forKey:@"artwork"];
        [center setValue:info forKey:@"nowPlayingInfo"];
        [artwork release];
    });
    [requestedURL release];
}

static NSError *RewindPlayerError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"RewindPlayerError"
                               code:code
                           userInfo:[NSDictionary dictionaryWithObject:message
                                                                forKey:NSLocalizedDescriptionKey]];
}

static void RewindPlayerNotify(RewindPlayer *player, NSError *error) {
    if (![NSThread isMainThread]) {
        [player retain];
        [error retain];
        dispatch_async(dispatch_get_main_queue(), ^{
            RewindPlayerNotify(player, error);
            [error release];
            [player release];
        });
        return;
    }
    RewindUpdateNowPlaying(player);
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:player
                                                                        forKey:@"player"];
    if (error) [info setObject:error forKey:@"error"];
    [[NSNotificationCenter defaultCenter] postNotificationName:RewindPlayerDidChangeNotification
                                                        object:player
                                                      userInfo:info];
}

@interface RewindPlayer ()
- (void)itemFailedToPlay:(NSNotification *)note;
- (void)itemPlaybackStalled:(NSNotification *)note;
- (void)removeItemStatusObserver;
- (void)clearNativePlayer;
- (void)loadAudio;
- (void)startItemWithURL:(NSURL *)audioURL track:(RewindTrack *)selectedTrack generation:(NSUInteger)generation;
- (void)upgradeAudio:(NSURL *)url error:(NSError *)error generation:(NSUInteger)generation attempt:(NSUInteger)attempt;
- (void)clearPrefetch;
- (void)startPrefetch;
- (void)stashAudio;
- (NSURL *)takeRecentAudioForTrack:(RewindTrack *)track;
- (BOOL)hasRecentAudioForTrack:(RewindTrack *)track;
- (void)pruneRecentAudio;
- (void)audioFailed:(NSError *)error;
- (void)itemStatusChanged:(AVPlayerItem *)item;
- (void)setLoadTimeout:(NSTimeInterval)timeout;
- (void)playbackTick;
- (void)clearPlaybackTimer;
@end

/* a finished track stays playable for this long after it is left, so a step back or a replay skips resolving,
   probing and the index build; two tracks bound the temporary files a sabr result leaves behind */
static const NSTimeInterval RewindRecentAudioLifetime = 600.0;
static const NSUInteger RewindRecentAudioKeep = 2;

static BOOL RewindIsTemporaryAudio(NSURL *url) {
    return url.isFileURL && [url.path hasPrefix:NSTemporaryDirectory()];
}

static void RewindPlaybackTick(CFRunLoopTimerRef timer, void *context) {
    (void)timer;
    [(RewindPlayer *)context playbackTick];
}

@implementation RewindPlayer

- (id)init {
    self = [super init];
    if (self) {
        _continuousPlayback = YES;
        _playbackRate = 1.0f;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(backgroundAudioChanged:)
                                                     name:REWIND_BACKGROUND_AUDIO_DID_CHANGE_NOTIFICATION
                                                   object:nil];
        [self setRemoteCommandsRegistered:YES];
    }
    return self;
}

/* newer ios versions route lock screen and headset buttons through MPRemoteCommandCenter
   (ios 7.1 and later); the armv7 sdk does not declare it, so it is reached at runtime.
   ios 5 through 7.0 keep delivering remoteControlReceivedWithEvent to the first responder */
- (void)setRemoteCommandsRegistered:(BOOL)registered {
    Class centerClass = NSClassFromString(@"MPRemoteCommandCenter");
    SEL shared = NSSelectorFromString(@"sharedCommandCenter");
    if (!centerClass || ![centerClass respondsToSelector:shared]) return;
    id center = [centerClass performSelector:shared];
    NSArray *commands = [NSArray arrayWithObjects:@"playCommand", @"pauseCommand", @"togglePlayPauseCommand",
                         @"nextTrackCommand", @"previousTrackCommand", nil];
    NSArray *handlers = [NSArray arrayWithObjects:@"remotePlay:", @"remotePause:", @"remoteToggle:",
                         @"remoteNext:", @"remotePrevious:", nil];
    SEL add = NSSelectorFromString(@"addTarget:action:");
    SEL remove = NSSelectorFromString(@"removeTarget:");
    for (NSUInteger index = 0; index < commands.count; ++index) {
        id command = [center valueForKey:[commands objectAtIndex:index]];
        if (!command) continue;
        if (!registered) {
            if ([command respondsToSelector:remove]) [command performSelector:remove withObject:self];
        } else if ([command respondsToSelector:add]) {
            typedef id (*add_target_fn)(id, SEL, id, SEL);
            ((add_target_fn)objc_msgSend)(command, add, self,
                                          NSSelectorFromString([handlers objectAtIndex:index]));
        }
    }
}

- (NSInteger)remotePlay:(id)event {
    (void)event;
    if (!_wantsPlayback || _audioFailed) [self toggle];
    return 0;
}

- (NSInteger)remotePause:(id)event {
    (void)event;
    if (_wantsPlayback) [self toggle];
    return 0;
}

- (NSInteger)remoteToggle:(id)event {
    (void)event;
    [self toggle];
    return 0;
}

- (NSInteger)remoteNext:(id)event {
    (void)event;
    [self nextTrack];
    return 0;
}

- (NSInteger)remotePrevious:(id)event {
    (void)event;
    [self previousTrack];
    return 0;
}

- (RewindTrack *)track { return _track; }
- (NSArray *)queue { return _queue; }
- (BOOL)isRepeating { return _repeating; }
- (BOOL)continuousPlayback { return _continuousPlayback; }
- (float)playbackRate { return _playbackRate; }
- (NSInteger)queueIndex { return _queueIndex; }
- (BOOL)isShuffling { return _shuffling; }
- (id)nativePlayer { return _player; }

- (BOOL)isPlaying {
    if (_scratching) return _scratchWasPlaying;
    return _wantsPlayback && !_audioFailed && [_player isKindOfClass:[AVPlayer class]] &&
           [(AVPlayer *)_player currentItem].status == AVPlayerItemStatusReadyToPlay &&
           [(AVPlayer *)_player rate] > 0.0f;
}

- (BOOL)isLoading {
    if (!_track || _audioFailed) return NO;
    if (_loadingMore || _resolvingAudio || _buffering) return YES;
    if (![_player isKindOfClass:[AVPlayer class]]) return NO;
    AVPlayerItem *item = [(AVPlayer *)_player currentItem];
    return !item || item.status == AVPlayerItemStatusUnknown;
}

- (NSTimeInterval)currentTime {
    if (![_player isKindOfClass:[AVPlayer class]]) return 0.0;
    Float64 seconds = CMTimeGetSeconds([(AVPlayer *)_player currentTime]);
    return isfinite(seconds) && seconds > 0.0 ? seconds : 0.0;
}

- (NSTimeInterval)duration {
    if ([_player isKindOfClass:[AVPlayer class]]) {
        AVPlayerItem *item = [(AVPlayer *)_player currentItem];
        Float64 seconds = item ? CMTimeGetSeconds(item.duration) : 0.0;
        if (isfinite(seconds) && seconds > 0.0) return seconds;
    }
    return (NSTimeInterval)_track.duration;
}

- (float)progress {
    NSTimeInterval duration = [self duration];
    if (duration <= 0.0) return 0.0f;
    float value = (float)([self currentTime] / duration);
    if (value < 0.0f) return 0.0f;
    if (value > 1.0f) return 1.0f;
    return value;
}

- (void)dealloc {
    [self clearPrefetch];
    [self clearPlaybackTimer];
    [_audioRequest cancel];
    [_audioRequest release];
    [_failedAudioSources release];
    [_audioSourceKey release];
    [_loadTimer invalidate];
    [_loadTimer release];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self setRemoteCommandsRegistered:NO];
    [self removeItemStatusObserver];
    [_player pause];
    [_player release];
    if (_localAudioPath) [[NSFileManager defaultManager] removeItemAtPath:_localAudioPath error:NULL];
    [_localAudioPath release];
    for (NSDictionary *entry in _recentAudio) {
        NSURL *url = [entry objectForKey:@"url"];
        if (RewindIsTemporaryAudio(url)) [[NSFileManager defaultManager] removeItemAtPath:url.path error:NULL];
    }
    [_recentAudio release];
    [_audioURL release];
    [_track release];
    [_api release];
    [_queue release];
    [_orderedQueue release];
    [_sleepTimer invalidate];
    [_sleepTimer release];
    [super dealloc];
}

- (void)backgroundAudioChanged:(NSNotification *)note {
    (void)note;
    if (_player) RewindConfigureAudioSession();
}

- (void)clearNativePlayer {
    /* a finger still on the record now holds a player that is gone */
    _scratching = NO;
    _scratchSeeking = NO;
    [self clearPlaybackTimer];
    _playbackStarted = NO;
    _buffering = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
    NSString *stalledName = RewindStalledNotificationName();
    if (stalledName) [[NSNotificationCenter defaultCenter] removeObserver:self name:stalledName object:nil];
    [self removeItemStatusObserver];
    [_player pause];
    [_player release];
    _player = nil;
    if (_localAudioPath) [[NSFileManager defaultManager] removeItemAtPath:_localAudioPath error:NULL];
    [_localAudioPath release];
    _localAudioPath = nil;
    [_audioSourceKey release];
    _audioSourceKey = nil;
}

- (void)clearPlaybackTimer {
    if (!_playbackTimer) return;
    CFRunLoopTimerInvalidate(_playbackTimer);
    CFRelease(_playbackTimer);
    _playbackTimer = NULL;
}

- (void)playbackTick {
    /* the clock is moved by hand while the record is held, that is not a stalled player */
    if (_scratching) return;
    AVPlayerItem *item = [(AVPlayer *)_player currentItem];
    if (item.status != AVPlayerItemStatusReadyToPlay) return;
    rewind_playback_status_t status = rewind_playback_update(&_playbackProgress, CACurrentMediaTime(),
                                                             [self currentTime], _wantsPlayback);
    if (status == REWIND_PLAYBACK_ADVANCED) {
        if (!_playbackStarted) RewindDebugLog(@"playback started: %@, time %.2f", _audioSourceKey, [self currentTime]);
        if (!_prefetchScheduled) {
            _prefetchScheduled = YES;
            [self startPrefetch];
        }
        BOOL notify = _buffering || !_playbackStarted;
        _playbackStarted = YES;
        _buffering = NO;
        if (notify) RewindPlayerNotify(self, nil);
    } else if (status == REWIND_PLAYBACK_STALLED) {
        [self audioFailed:RewindPlayerError(12, @"audio playback stopped making progress")];
    }
}

- (void)setLoadTimeout:(NSTimeInterval)timeout {
    [_loadTimer invalidate];
    [_loadTimer release];
    _loadTimer = nil;
    if (timeout > 0) {
        _loadTimer = [[NSTimer timerWithTimeInterval:timeout target:self selector:@selector(loadTimedOut:)
                                           userInfo:nil repeats:NO] retain];
        [[NSRunLoop mainRunLoop] addTimer:_loadTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)loadTimedOut:(NSTimer *)timer {
    if (timer != _loadTimer) return;
    if (_loadingMore) {
        ++_generation;
        _loadingMore = NO;
        _wantsPlayback = NO;
        _buffering = NO;
        [self setLoadTimeout:0];
        [self clearPlaybackTimer];
        [_player pause];
        RewindPlayerNotify(self, RewindPlayerError(12, @"continuous playback request timed out"));
        return;
    }
    [self audioFailed:RewindPlayerError(12, @"audio preparation timed out")];
}

static AVURLAsset *RewindAssetForURL(NSURL *audioURL);

/* a sabr result is a temporary local file nobody else will delete */
- (void)clearPrefetch {
    [_prefetchRequest cancel];
    [_prefetchRequest release];
    _prefetchRequest = nil;
    if (_prefetchURL.isFileURL && [_prefetchURL.path hasPrefix:NSTemporaryDirectory()])
        [[NSFileManager defaultManager] removeItemAtPath:_prefetchURL.path error:NULL];
    [_prefetchURL release];
    _prefetchURL = nil;
    [_prefetchAsset release];
    _prefetchAsset = nil;
    [_prefetchTrack release];
    _prefetchTrack = nil;
}

- (void)startPrefetch {
    if (_prefetchTrack || _repeating || !_api || !_queue.count || _queueIndex + 1 >= (NSInteger)_queue.count) return;
    RewindTrack *next = [_queue objectAtIndex:(NSUInteger)_queueIndex + 1];
    if (!next.videoID.length || next.isPlaylist || RewindDownloadedURLForTrack(next.videoID)) return;
    _prefetchTrack = [next retain];
    NSUInteger generation = _generation;
    RewindAudioRequest *request = [_api streamURLForTrack:next excludingSources:nil
                                               completion:^(NSURL *url, NSError *error) {
        if (generation != _generation || _prefetchTrack != next) {
            /* the queue moved on while this resolved, its file would never be played */
            if (url.isFileURL) [[NSFileManager defaultManager] removeItemAtPath:url.path error:NULL];
            return;
        }
        if (url) {
            _prefetchURL = [url retain];
            if (!url.isFileURL) {
                _prefetchAsset = [RewindAssetForURL(url) retain];
                [_prefetchAsset loadValuesAsynchronouslyForKeys:[NSArray arrayWithObjects:@"playable", @"duration", nil]
                                              completionHandler:^{}];
            }
        } else RewindDebugLog(@"prefetch %@ failed: %@", next.videoID, error);
        [_prefetchRequest release];
        _prefetchRequest = nil;
    }];
    _prefetchRequest = [request retain];
}

- (void)playTrack:(RewindTrack *)track usingAPI:(RewindAPI *)api {
    if (!track || !api) return;
    RewindTrack *selectedTrack = [track retain];
    RewindAPI *selectedAPI = [api retain];
    /* a finished prefetch of this very track is kept, one still resolving would only race the new load */
    if (!_prefetchURL || ![_prefetchTrack.videoID isEqualToString:selectedTrack.videoID]) [self clearPrefetch];
    _prefetchScheduled = NO;
    ++_generation;
    _loadingMore = NO;
    [_audioRequest cancel];
    [_audioRequest release];
    _audioRequest = nil;
    [self setLoadTimeout:0];
    [self stashAudio];
    [self clearNativePlayer];
    [_api release];
    _api = selectedAPI;
    [_track release];
    _track = selectedTrack;
    [_failedAudioSources release];
    _failedAudioSources = [[NSMutableSet alloc] init];
    _audioAttempts = 0;
    _resumeTime = 0;
    _resolvingAudio = NO;
    _audioFailed = NO;
    _wantsPlayback = YES;
    for (NSUInteger index = 0; index < _queue.count; ++index) {
        RewindTrack *queued = [_queue objectAtIndex:index];
        if ([queued.videoID isEqualToString:selectedTrack.videoID]) {
            _queueIndex = (NSInteger)index;
            break;
        }
    }
    if (!track.videoID.length || track.isPlaylist) {
        _audioFailed = YES;
        _wantsPlayback = NO;
        RewindPlayerNotify(self, RewindPlayerError(6, @"this item has no playable audio"));
        return;
    }
    BOOL instant = RewindDownloadedURLForTrack(selectedTrack.videoID) || [self hasRecentAudioForTrack:selectedTrack] ||
        (_prefetchURL && [_prefetchTrack.videoID isEqualToString:selectedTrack.videoID]);
    if (instant) {
        [self loadAudio];
        return;
    }
    /* each resolve is a player request, a probe and maybe a sabr session; skipping through the queue started one per
       tap, a dozen in two seconds, and starved the ui and the network of a 4s. only the track the finger stops on
       resolves */
    _resolvingAudio = YES;
    RewindPlayerNotify(self, nil);
    NSUInteger generation = _generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == _generation && !_audioFailed) [self loadAudio];
    });
}

/* googlevideo ties the url to the client user-agent, which AVPlayer would not send on its own */
static AVURLAsset *RewindAssetForURL(NSURL *audioURL) {
    NSString *userAgent = RewindAudioUserAgentForURL(audioURL);
    NSDictionary *options = userAgent.length && [audioURL.scheme isEqualToString:@"https"]
        ? [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:userAgent forKey:@"User-Agent"]
                                      forKey:@"AVURLAssetHTTPHeaderFieldsKey"] : nil;
    return [AVURLAsset URLAssetWithURL:audioURL options:options];
}

/* builds the native player for a resolved file or url; also the second half of a preview upgrade */
- (void)startItemWithURL:(NSURL *)audioURL track:(RewindTrack *)selectedTrack generation:(NSUInteger)generation {
    RewindDebugLog(@"open %@ %@", selectedTrack.videoID, audioURL.isFileURL ? @"file" : audioURL.host);
    BOOL offline = audioURL.isFileURL && [audioURL isEqual:RewindDownloadedURLForTrack(selectedTrack.videoID)];
    _audioSourceKey = [offline ? @"offline" : RewindAudioSourceKeyForURL(audioURL) copy];
    if (RewindIsTemporaryAudio(audioURL)) _localAudioPath = [audioURL.path copy];
    [_audioURL release];
    _audioURL = [audioURL retain];
    /* a preview is only the first seconds, never worth keeping for a later play */
    _audioIsPreview = _audioRequest.upgradeExpected;
    /* the asset a prefetch already opened has its index loaded, so the item turns ready without another round trip */
    AVURLAsset *asset = [_prefetchAsset isKindOfClass:[AVURLAsset class]] && [[_prefetchAsset URL] isEqual:audioURL]
        ? [[_prefetchAsset retain] autorelease] : RewindAssetForURL(audioURL);
    [_prefetchAsset release];
    _prefetchAsset = nil;
    AVPlayerItem *item = asset ? [AVPlayerItem playerItemWithAsset:asset] : nil;
    _player = item ? [[AVPlayer alloc] initWithPlayerItem:item] : nil;
    if (!_player) {
        [self audioFailed:RewindPlayerError(9, @"media player could not be created")];
        return;
    }
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:NULL];
    [item addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:NSKeyValueObservingOptionNew context:NULL];
    _observingItemStatus = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemDidFinish:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemFailedToPlay:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    NSString *stalledName = RewindStalledNotificationName();
    if (stalledName) [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemPlaybackStalled:)
                                                                 name:stalledName object:item];
    [self setLoadTimeout:20.0];
    RewindUpdateNowPlayingArtwork(self, selectedTrack, generation);
    /* a cached item may be ready before the observer is installed */
    [self itemStatusChanged:item];
}

/* the complete file of a track that began playing from a short preview, or the failure that ended its download */
- (void)upgradeAudio:(NSURL *)url error:(NSError *)error generation:(NSUInteger)generation attempt:(NSUInteger)attempt {
    if (generation != _generation || attempt != _audioAttempt) {
        if (url.isFileURL) [[NSFileManager defaultManager] removeItemAtPath:url.path error:NULL];
        return;
    }
    _audioRequest.upgradeExpected = NO;
    [_audioRequest release];
    _audioRequest = nil;
    if (!url) {
        [self audioFailed:error ?: RewindPlayerError(8, @"track audio download stopped")];
        return;
    }
    _resumeTime = [self currentTime];
    /* drops the preview player and deletes its file; the clock restarts from the same second on the full one */
    [self clearNativePlayer];
    [self startItemWithURL:url track:_track generation:generation];
}

/* keeps the audio of the track being left; a result in the temporary directory changes hands from the player to
   this list so clearNativePlayer does not delete it. https urls are left to the api's own url cache */
- (void)stashAudio {
    if (!_track.videoID.length || !_audioURL || _audioIsPreview || _audioFailed || !_playbackStarted) return;
    if (!RewindIsTemporaryAudio(_audioURL) && !RewindStreamHasSession(_audioURL)) return;
    [self pruneRecentAudio];
    for (NSUInteger index = 0; index < _recentAudio.count; ++index) {
        NSDictionary *old = [_recentAudio objectAtIndex:index];
        if (![[old objectForKey:@"id"] isEqualToString:_track.videoID]) continue;
        NSURL *oldURL = [old objectForKey:@"url"];
        if (![oldURL isEqual:_audioURL] && RewindIsTemporaryAudio(oldURL))
            [[NSFileManager defaultManager] removeItemAtPath:oldURL.path error:NULL];
        [_recentAudio removeObjectAtIndex:index];
        break;
    }
    if (!_recentAudio) _recentAudio = [[NSMutableArray alloc] init];
    [_recentAudio addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                             _track.videoID, @"id", _audioURL, @"url",
                             [NSDate dateWithTimeIntervalSinceNow:RewindRecentAudioLifetime], @"expires", nil]];
    if (RewindIsTemporaryAudio(_audioURL)) {
        [_localAudioPath release];
        _localAudioPath = nil;
    }
    while (_recentAudio.count > RewindRecentAudioKeep) {
        NSURL *url = [[_recentAudio objectAtIndex:0] objectForKey:@"url"];
        if (RewindIsTemporaryAudio(url)) [[NSFileManager defaultManager] removeItemAtPath:url.path error:NULL];
        [_recentAudio removeObjectAtIndex:0];
    }
    [self retain];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((RewindRecentAudioLifetime + 1.0) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self pruneRecentAudio];
        [self release];
    });
}

/* drops what expired, and what can no longer be served: a deleted file or a proxy session that was evicted */
- (void)pruneRecentAudio {
    for (NSInteger index = (NSInteger)_recentAudio.count - 1; index >= 0; --index) {
        NSDictionary *entry = [_recentAudio objectAtIndex:(NSUInteger)index];
        NSURL *url = [entry objectForKey:@"url"];
        BOOL alive = [[entry objectForKey:@"expires"] timeIntervalSinceNow] > 0 &&
            (url.isFileURL ? [[NSFileManager defaultManager] fileExistsAtPath:url.path] : RewindStreamHasSession(url));
        if (alive) continue;
        if (RewindIsTemporaryAudio(url)) [[NSFileManager defaultManager] removeItemAtPath:url.path error:NULL];
        [_recentAudio removeObjectAtIndex:(NSUInteger)index];
    }
}

- (BOOL)hasRecentAudioForTrack:(RewindTrack *)track {
    [self pruneRecentAudio];
    for (NSDictionary *entry in _recentAudio)
        if ([[entry objectForKey:@"id"] isEqualToString:track.videoID]) return YES;
    return NO;
}

/* the stashed audio of a track about to play again; it leaves the list because the player owns it once more */
- (NSURL *)takeRecentAudioForTrack:(RewindTrack *)track {
    [self pruneRecentAudio];
    for (NSUInteger index = 0; index < _recentAudio.count; ++index) {
        NSDictionary *entry = [_recentAudio objectAtIndex:index];
        if (![[entry objectForKey:@"id"] isEqualToString:track.videoID]) continue;
        NSURL *url = [[[entry objectForKey:@"url"] retain] autorelease];
        [_recentAudio removeObjectAtIndex:index];
        RewindDebugLog(@"reuse audio of %@", track.videoID);
        return url;
    }
    return nil;
}

- (void)loadAudio {
    NSUInteger generation = _generation, attempt = ++_audioAttempt;
    ++_audioAttempts;
    RewindDebugLog(@"resolve %@ attempt %lu", _track.videoID, (unsigned long)_audioAttempts);
    _resolvingAudio = YES;
    _audioFailed = NO;
    /* each resolver stage has its own deadline; 45s cancelled working Android fallback on ios 5 */
    [self setLoadTimeout:0];
    RewindPlayerNotify(self, nil);
    RewindConfigureAudioSession();
    RewindTrack *selectedTrack = _track;
    void (^resolved)(NSURL *, NSError *) = ^(NSURL *audioURL, NSError *audioError) {
        if (generation != _generation || attempt != _audioAttempt) return;
        if (!_audioRequest.upgradeExpected) {
            [_audioRequest release];
            _audioRequest = nil;
        }
        _resolvingAudio = NO;
        if (audioError || !audioURL) {
            [self audioFailed:audioError ?: RewindPlayerError(8, @"track audio could not be loaded")];
            return;
        }
        [self startItemWithURL:audioURL track:selectedTrack generation:generation];
    };
    NSURL *offline = [_failedAudioSources containsObject:@"offline"] ? nil : RewindDownloadedURLForTrack(selectedTrack.videoID);
    /* only the first attempt may use it, a retry means that source already failed */
    NSURL *prefetched = _audioAttempts == 1 && _prefetchURL &&
        [_prefetchTrack.videoID isEqualToString:selectedTrack.videoID] ? [[_prefetchURL retain] autorelease] : nil;
    if (prefetched) {
        [_prefetchURL release];
        _prefetchURL = nil;
        [_prefetchTrack release];
        _prefetchTrack = nil;
    }
    NSURL *recent = !offline && !prefetched && _audioAttempts == 1 ? [self takeRecentAudioForTrack:selectedTrack] : nil;
    if (offline) resolved(offline, nil);
    else if (prefetched) resolved(prefetched, nil);
    else if (recent) resolved(recent, nil);
    else {
        _audioRequest = [[_api streamURLForTrack:selectedTrack excludingSources:_failedAudioSources
                                      completion:resolved] retain];
        _audioRequest.allowsPreview = YES;
        _audioRequest.onUpgrade = ^(NSURL *url, NSError *error) {
            [self upgradeAudio:url error:error generation:generation attempt:attempt];
        };
    }
}

- (void)audioFailed:(NSError *)error {
    RewindDebugLog(@"play %@ source %@ failed: %@", _track.videoID, _audioSourceKey, error);
    if (!_track) return;
    NSTimeInterval elapsed = [self currentTime];
    if (elapsed > 0) _resumeTime = elapsed;
    BOOL tryNext = _audioSourceKey.length && _audioAttempts < 30 &&
                   ![_failedAudioSources containsObject:_audioSourceKey];
    if (tryNext) [_failedAudioSources addObject:_audioSourceKey];
    ++_audioAttempt;
    [_audioRequest cancel];
    [_audioRequest release];
    _audioRequest = nil;
    [self setLoadTimeout:0];
    [self clearNativePlayer];
    _resolvingAudio = NO;
    if (tryNext) {
        [self loadAudio];
    } else {
        _audioFailed = YES;
        _wantsPlayback = NO;
        RewindPlayerNotify(self, error);
    }
}

- (void)removeItemStatusObserver {
    if (!_observingItemStatus || ![_player isKindOfClass:[AVPlayer class]]) return;
    AVPlayerItem *item = [(AVPlayer *)_player currentItem];
    if (item) {
        [item removeObserver:self forKeyPath:@"status"];
        [item removeObserver:self forKeyPath:@"playbackLikelyToKeepUp"];
    }
    _observingItemStatus = NO;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    (void)change;
    (void)context;
    if (![keyPath isEqualToString:@"status"] && ![keyPath isEqualToString:@"playbackLikelyToKeepUp"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (object != [(AVPlayer *)_player currentItem]) return;
        if ([keyPath isEqualToString:@"status"] || [(AVPlayerItem *)object isPlaybackLikelyToKeepUp])
            [self itemStatusChanged:object];
    });
}

- (void)itemStatusChanged:(AVPlayerItem *)item {
    if (item != [(AVPlayer *)_player currentItem]) return;
    if (item.status == AVPlayerItemStatusReadyToPlay) {
        NSTimeInterval resumePosition = _resumeTime;
        _buffering = _wantsPlayback && !_playbackStarted;
        if (!_loadingMore) [self setLoadTimeout:0];
        if (_resumeTime > 0) {
            [(AVPlayer *)_player seekToTime:CMTimeMakeWithSeconds(_resumeTime, 600)];
            _resumeTime = 0;
        }
        /* a held record owns the rate; a buffering flip while scratching used to restart full speed playback under the finger */
        if (_wantsPlayback && !_scratching) [(AVPlayer *)_player setRate:_playbackRate];
        if (!_playbackTimer) {
            /* the seek jump restores position but does not prove audio has started */
            rewind_playback_reset(&_playbackProgress, CACurrentMediaTime(),
                                  resumePosition > 0 ? resumePosition : [self currentTime], _wantsPlayback);
            /* ios 5 has no stalled notification and can report ready while its clock stays at zero */
            CFRunLoopTimerContext context = {0, self, NULL, NULL, NULL};
            _playbackTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 0.5, 0.5,
                                                 0, 0, RewindPlaybackTick, &context);
            if (!_playbackTimer) {
                [self audioFailed:RewindPlayerError(12, @"playback progress monitor could not start")];
                return;
            }
            CFRunLoopAddTimer(CFRunLoopGetMain(), _playbackTimer, kCFRunLoopCommonModes);
        }
        RewindDebugLog(@"item ready: %@, duration %.2f", _audioSourceKey, [self duration]);
        RewindPlayerNotify(self, nil);
    } else if (item.status == AVPlayerItemStatusFailed) {
        [self audioFailed:item.error ?: RewindPlayerError(12, @"audio could not be loaded")];
    } else {
        RewindPlayerNotify(self, nil);
    }
}

- (void)itemFailedToPlay:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![note object] || [note object] != [(AVPlayer *)_player currentItem]) return;
        NSError *error = [[note userInfo] objectForKey:AVPlayerItemFailedToPlayToEndTimeErrorKey];
        [self audioFailed:error ?: RewindPlayerError(12, @"audio could not be loaded")];
    });
}

- (void)itemPlaybackStalled:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![note object] || [note object] != [(AVPlayer *)_player currentItem]) return;
        _buffering = YES;
        RewindPlayerNotify(self, nil);
    });
}

- (void)setQueue:(NSArray *)tracks selectedIndex:(NSInteger)index usingAPI:(RewindAPI *)api {
    NSMutableArray *newQueue;
    RewindTrack *selectedTrack;
    RewindAPI *selectedAPI;
    if (![tracks isKindOfClass:[NSArray class]] || !tracks.count || !api) return;

    newQueue = [tracks mutableCopy];
    if (!newQueue.count) {
        [newQueue release];
        return;
    }
    if (index < 0) index = 0;
    if ((NSUInteger)index >= newQueue.count) index = (NSInteger)newQueue.count - 1;
    selectedTrack = [[newQueue objectAtIndex:(NSUInteger)index] retain];
    selectedAPI = [api retain];

    [_queue release];
    _queue = newQueue;
    _queueIndex = index;
    if (_shuffling) {
        [_orderedQueue release];
        _orderedQueue = [_queue copy];
        [self shuffleUpcoming];
    }
    [self playTrack:selectedTrack usingAPI:selectedAPI];
    [selectedTrack release];
    [selectedAPI release];
}

- (void)nextTrack {
    if (!_queue.count || _queueIndex + 1 >= (NSInteger)_queue.count) {
        if (_continuousPlayback) [self loadMoreTracks];
        return;
    }
    ++_queueIndex;
    [self playTrack:[_queue objectAtIndex:(NSUInteger)_queueIndex] usingAPI:_api];
}

- (void)previousTrack {
    /* past the first 15 seconds the button restarts the track, the way the original client does */
    if ([self currentTime] > 15.0) {
        [self seekToTime:0.0];
        return;
    }
    if (!_queue.count || !_api) return;
    if (_queueIndex > 0) --_queueIndex;
    [self playTrack:[_queue objectAtIndex:(NSUInteger)_queueIndex] usingAPI:_api];
}

- (void)itemDidFinish:(NSNotification *)note {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self itemDidFinish:note]; });
        return;
    }
    if (!note.object || note.object != [(AVPlayer *)_player currentItem]) return;
    /* a short preview ended before the complete file arrived: wait for it instead of skipping the track */
    if (_audioRequest.upgradeExpected) {
        _buffering = YES;
        RewindPlayerNotify(self, nil);
        return;
    }
    [self clearPlaybackTimer];
    _buffering = NO;
    _wantsPlayback = NO;
    if (_repeating && _track && _api) {
        [self playTrack:_track usingAPI:_api];
    } else if (_queue.count && _queueIndex + 1 < (NSInteger)_queue.count) {
        [self nextTrack];
    } else if (_continuousPlayback) {
        [self loadMoreTracks];
    } else {
        [_player pause];
        RewindPlayerNotify(self, nil);
    }
}

- (void)appendFreshTracks:(NSArray *)tracks error:(NSError *)error api:(RewindAPI *)api
              generation:(NSUInteger)generation {
    if (generation != _generation) {
        [api release];
        return;
    }
    NSMutableArray *fresh = [NSMutableArray array];
    for (id value in tracks) {
        if (![value isKindOfClass:[RewindTrack class]]) continue;
        RewindTrack *candidate = value;
        BOOL duplicate = [candidate.videoID isEqualToString:_track.videoID];
        for (RewindTrack *added in fresh)
            if ([candidate.videoID isEqualToString:added.videoID]) duplicate = YES;
        for (RewindTrack *queued in _queue) {
            if ([candidate.videoID isEqualToString:queued.videoID]) {
                duplicate = YES;
                break;
            }
        }
        if (!duplicate && candidate.videoID.length && !candidate.isPlaylist) {
            [fresh addObject:candidate];
            if (fresh.count >= 8) break;
        }
    }
    _loadingMore = NO;
    [self setLoadTimeout:0];
    [api release];
    if (fresh.count) {
        if (!_queue) {
            _queue = [[NSMutableArray alloc] init];
            [_queue addObject:_track];
            _queueIndex = 0;
        }
        [_queue addObjectsFromArray:fresh];
        [self nextTrack];
    } else {
        _wantsPlayback = NO;
        _buffering = NO;
        [self clearPlaybackTimer];
        [_player pause];
        RewindPlayerNotify(self, error ?: RewindPlayerError(8, @"continuous playback returned no new tracks"));
    }
}

- (void)loadMoreBySearch:(RewindAPI *)api generation:(NSUInteger)generation {
    NSString *query = _track.artist.length ? _track.artist : _track.title;
    [api search:query completion:^(NSArray *tracks, NSError *error) {
        [self appendFreshTracks:error ? nil : tracks error:error api:api generation:generation];
    }];
}

- (void)loadMoreByRelated:(RewindAPI *)api generation:(NSUInteger)generation {
    [api relatedForTrack:_track completion:^(NSArray *shelves, NSArray *links, NSError *error) {
        (void)links;
        if (generation != _generation) {
            [api release];
            return;
        }
        NSMutableArray *tracks = [NSMutableArray array];
        for (RewindShelf *shelf in shelves) {
            for (id item in shelf.items) {
                if (![item isKindOfClass:[RewindTrack class]]) continue;
                RewindTrack *track = item;
                if (track.videoID.length && !track.isPlaylist) [tracks addObject:track];
                if (tracks.count >= 24) break;
            }
            if (tracks.count >= 24) break;
        }
        if (!tracks.count) {
            if (error) NSLog(@"rewind: related tracks failed, using search: %@", error);
            [self loadMoreBySearch:api generation:generation];
            return;
        }
        [self appendFreshTracks:tracks error:nil api:api generation:generation];
    }];
}

- (void)loadMoreTracks {
    if (_loadingMore || !_api || !_track) return;
    _loadingMore = YES;
    [self setLoadTimeout:30.0];
    RewindPlayerNotify(self, nil);

    RewindAPI *api = [_api retain];
    NSUInteger generation = _generation;
    if (!RewindAccountIsSignedIn()) {
        [self loadMoreByRelated:api generation:generation];
        return;
    }
    /* the account radio follows listening history; artist search is the signed out fallback */
    RewindAccountLoadMix(_track, ^(NSArray *tracks, NSError *error) {
        if (generation != _generation) {
            [api release];
            return;
        }
        if (error) {
            NSLog(@"rewind: account radio failed, using search: %@", error);
            [self loadMoreByRelated:api generation:generation];
            return;
        }
        [self appendFreshTracks:tracks error:nil api:api generation:generation];
    });
}

- (void)shuffleUpcoming {
    NSUInteger start = _queueIndex >= 0 ? (NSUInteger)_queueIndex + 1 : 0;
    for (NSUInteger index = _queue.count; index > start + 1; --index) {
        NSUInteger pick = start + arc4random_uniform((u_int32_t)(index - start));
        [_queue exchangeObjectAtIndex:index - 1 withObjectAtIndex:pick];
    }
}

- (void)setShuffling:(BOOL)shuffling {
    if (_shuffling == shuffling) return;
    _shuffling = shuffling;
    if (shuffling) {
        [_orderedQueue release];
        _orderedQueue = [_queue copy];
        [self shuffleUpcoming];
    } else if (_orderedQueue) {
        /* tracks queued while shuffled have no original slot; they follow the restored order */
        NSMutableArray *restored = [NSMutableArray array];
        for (RewindTrack *track in _orderedQueue)
            if ([_queue indexOfObjectIdenticalTo:track] != NSNotFound) [restored addObject:track];
        for (RewindTrack *track in _queue)
            if ([restored indexOfObjectIdenticalTo:track] == NSNotFound) [restored addObject:track];
        [_queue removeAllObjects];
        [_queue addObjectsFromArray:restored];
        NSUInteger current = _track ? [_queue indexOfObjectIdenticalTo:_track] : NSNotFound;
        if (current != NSNotFound) _queueIndex = (NSInteger)current;
        [_orderedQueue release];
        _orderedQueue = nil;
    }
    RewindPlayerNotify(self, nil);
}

- (void)playQueueIndex:(NSInteger)index {
    if (index < 0 || (NSUInteger)index >= _queue.count || !_api) return;
    _queueIndex = index;
    [self playTrack:[_queue objectAtIndex:(NSUInteger)index] usingAPI:_api];
}

- (void)setRepeating:(BOOL)repeating {
    if (_repeating == repeating) return;
    _repeating = repeating;
    RewindPlayerNotify(self, nil);
}

- (void)enqueueTrack:(RewindTrack *)track usingAPI:(RewindAPI *)api afterCurrent:(BOOL)afterCurrent {
    if (!track || !api) return;
    if (!_queue) {
        _queue = [[NSMutableArray alloc] init];
        if (_track) [_queue addObject:_track];
        _queueIndex = _queue.count ? (NSInteger)_queue.count - 1 : 0;
    }
    NSUInteger index = _queue.count;
    if (afterCurrent && _queueIndex >= 0 &&
        _queueIndex < (NSInteger)_queue.count)
        index = (NSUInteger)_queueIndex + 1;
    [_queue insertObject:track atIndex:index];
    if (![_api isEqual:api]) {
        [_api release];
        _api = [api retain];
    }
    RewindPlayerNotify(self, nil);
}

- (void)setContinuousPlayback:(BOOL)enabled {
    if (_continuousPlayback == enabled) return;
    _continuousPlayback = enabled;
    RewindPlayerNotify(self, nil);
}

- (void)setPlaybackRate:(float)rate {
    if (rate < 0.5f) rate = 0.5f;
    if (rate > 2.0f) rate = 2.0f;
    _playbackRate = rate;
    if ([_player isKindOfClass:[AVPlayer class]] && [self isPlaying])
        [(AVPlayer *)_player setRate:_playbackRate];
    RewindPlayerNotify(self, nil);
}

- (void)sleepTimerFired:(NSTimer *)timer {
    (void)timer;
    [_sleepTimer invalidate];
    [_sleepTimer release];
    _sleepTimer = nil;
    _wantsPlayback = NO;
    if ([_player isKindOfClass:[AVPlayer class]]) [(AVPlayer *)_player pause];
    RewindPlayerNotify(self, nil);
}

- (void)setSleepTimer:(NSTimeInterval)seconds {
    [_sleepTimer invalidate];
    [_sleepTimer release];
    _sleepTimer = nil;
    if (seconds <= 0.0) return;
    _sleepTimer = [[NSTimer scheduledTimerWithTimeInterval:seconds
                                                     target:self
                                                   selector:@selector(sleepTimerFired:)
                                                   userInfo:nil
                                                    repeats:NO] retain];
    RewindPlayerNotify(self, nil);
}

- (void)cancelSleepTimer {
    [self setSleepTimer:0.0];
}

- (void)toggle {
    if (!_track) return;
    if (_audioFailed) {
        [self playTrack:_track usingAPI:_api];
        return;
    }
    _wantsPlayback = !_wantsPlayback;
    rewind_playback_reset(&_playbackProgress, CACurrentMediaTime(), [self currentTime], _wantsPlayback);
    if (!_wantsPlayback) _buffering = NO;
    if (_wantsPlayback) {
        NSTimeInterval duration = [self duration];
        if (!_loadingMore && duration > 0 && [self currentTime] >= duration - 0.1) {
            [(AVPlayer *)_player seekToTime:kCMTimeZero];
            _playbackStarted = NO;
            rewind_playback_reset(&_playbackProgress, CACurrentMediaTime(), 0, YES);
            [self itemStatusChanged:[(AVPlayer *)_player currentItem]];
        }
        if ([(AVPlayer *)_player currentItem].status == AVPlayerItemStatusReadyToPlay)
            [(AVPlayer *)_player setRate:_playbackRate];
    } else {
        [_player pause];
    }
    RewindPlayerNotify(self, nil);
}

- (void)beginScratch {
    if (_scratching || ![_player isKindOfClass:[AVPlayer class]]) return;
    AVPlayer *player = _player;
    _scratching = YES;
    _scratchWasPlaying = _wantsPlayback && player.rate > 0.0f;
    _scratchTarget = [self currentTime];
    _scratchVelocity = 0.0f;
    _scratchSeeking = NO;
    _scratchSeekTime = 0.0;
    _scratchRate = 0.0f;
    _scratchRateTime = 0.0;
    [player setRate:0.0f];
}

- (void)scratchByTime:(NSTimeInterval)delta interval:(NSTimeInterval)interval {
    if (!_scratching || ![_player isKindOfClass:[AVPlayer class]]) return;
    AVPlayer *player = _player;
    NSTimeInterval limit = MAX(0.0, [self duration] - 0.3);
    _scratchTarget = MAX(0.0, MIN(limit, _scratchTarget + delta));
    /* audio seconds per real second, smoothed: 1 is the speed of a normal play */
    float velocity = interval > 0.001 ? (float)(delta / interval) : 0.0f;
    _scratchVelocity = _scratchVelocity * 0.6f + velocity * 0.4f;
    /* a drag at a speed the player can voice is heard, so the record sounds like a record. backward is heard
       only where the item plays in reverse; faking it with forward bursts pulled back by seeks sent avplayer a
       seek and a rate change several times a second, each a blocking call into the ios 5 media server, and
       the main thread stalled behind them until the screen stopped answering */
    float speed = fabsf(_scratchVelocity);
    float rate = speed > 0.4f ? MIN(2.0f, floorf(speed * 4.0f + 0.5f) / 4.0f) : 0.0f;
    if (rate > 0.0f && _scratchVelocity < 0.0f) {
        AVPlayerItem *item = player.currentItem;
        BOOL reverse = [item respondsToSelector:@selector(canPlayReverse)] && item.canPlayReverse;
        BOOL fastReverse = reverse && [item respondsToSelector:@selector(canPlayFastReverse)] && item.canPlayFastReverse;
        rate = reverse ? -(fastReverse ? rate : MIN(1.0f, rate)) : 0.0f;
    }
    NSTimeInterval drift = fabs([self currentTime] - _scratchTarget);
    CFTimeInterval now = CACurrentMediaTime();
    /* every seek on the stream proxy is a new range request; one per touch event, 60 a second, starved the whole
       device on a long scratch. a seek runs at most four times a second and endScratch lands the exact position */
    if (drift > 0.5 && !_scratchSeeking && now - _scratchSeekTime > 0.25) {
        _scratchSeeking = YES;
        _scratchSeekTime = now;
        CMTime time = CMTimeMakeWithSeconds(_scratchTarget, 600);
        /* the handler outlives this call, a block literal on the stack would be gone when it runs */
        void (^done)(BOOL) = [[^(BOOL finished) {
            (void)finished;
            _scratchSeeking = NO;
        } copy] autorelease];
        if ([player respondsToSelector:@selector(seekToTime:toleranceBefore:toleranceAfter:completionHandler:)])
            [player seekToTime:time toleranceBefore:CMTimeMakeWithSeconds(0.04, 600)
                toleranceAfter:CMTimeMakeWithSeconds(0.04, 600) completionHandler:done];
        else {
            [player seekToTime:time];
            _scratchSeeking = NO;
        }
    }
    /* the rate moves in quarter steps and at most every 150 ms: a new value on every touch kept avplayer
       retiming itself, and each change is a synchronous call into the media server */
    if (fabsf(_scratchRate - rate) > 0.01f && (rate == 0.0f || now - _scratchRateTime > 0.15)) {
        _scratchRate = rate;
        _scratchRateTime = now;
        [player setRate:rate];
    }
}

- (void)endScratch {
    if (!_scratching) return;
    _scratching = NO;
    if ([_player isKindOfClass:[AVPlayer class]]) {
        AVPlayer *player = _player;
        [player seekToTime:CMTimeMakeWithSeconds(_scratchTarget, 600)
           toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
        rewind_playback_reset(&_playbackProgress, CACurrentMediaTime(), _scratchTarget, _wantsPlayback);
        [player setRate:_scratchWasPlaying ? _playbackRate : 0.0f];
    }
    RewindPlayerNotify(self, nil);
}

- (void)seekToProgress:(float)progress {
    NSTimeInterval duration = [self duration];
    if (duration <= 0.0) return;
    if (progress < 0.0f) progress = 0.0f;
    if (progress > 1.0f) progress = 1.0f;
    [self seekToTime:duration * progress];
}

- (void)seekToTime:(NSTimeInterval)time {
    if (![_player isKindOfClass:[AVPlayer class]]) return;
    NSTimeInterval duration = [self duration];
    if (duration <= 0.0) return;
    time = MAX(0.0, MIN(time, duration));
    rewind_playback_reset(&_playbackProgress, CACurrentMediaTime(), time, _wantsPlayback);
    [(AVPlayer *)_player seekToTime:CMTimeMakeWithSeconds((Float64)time, 600)
                    toleranceBefore:kCMTimeZero
                     toleranceAfter:kCMTimeZero];
    RewindPlayerNotify(self, nil);
}

- (void)stop {
    ++_generation;
    ++_audioAttempt;
    _loadingMore = NO;
    _resolvingAudio = NO;
    _buffering = NO;
    _audioFailed = NO;
    _wantsPlayback = NO;
    [_audioRequest cancel];
    [_audioRequest release];
    _audioRequest = nil;
    [self setLoadTimeout:0];
    [self clearNativePlayer];
    [_track release];
    _track = nil;
    [_queue release];
    _queue = nil;
    _queueIndex = 0;
    RewindPlayerNotify(self, nil);
}

- (void)clearQueue {
    NSMutableArray *currentQueue = [NSMutableArray array];
    if (_track) [currentQueue addObject:_track];
    [_queue release];
    _queue = [currentQueue mutableCopy];
    _queueIndex = 0;
    RewindPlayerNotify(self, nil);
}

@end
