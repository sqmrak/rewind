#import "tunetube_player.h"

#import <dispatch/dispatch.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import "tunetube_api.h"
#import "tunetube_image_cache.h"
#import "tunetube_config.h"

#include <math.h>

NSString * const TuneTubePlayerDidChangeNotification = @"TuneTubePlayerDidChangeNotification";
static NSString * const TuneTubePlaybackAudioCategory = @"AVAudioSessionCategoryPlayback";

/* the ios 6 headers do not declare the initializer added in ios 10 */
@interface MPMediaItemArtwork (TuneTubeIOS10)
- (id)initWithBoundsSize:(CGSize)size
          requestHandler:(UIImage *(^)(CGSize size))handler;
@end

static MPMediaItemArtwork *TuneTubeArtworkForImage(UIImage *image) {
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

static void TuneTubeConfigureAudioSession(void) {
    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:TuneTubePlaybackAudioCategory error:&sessionError];
    if ([session respondsToSelector:@selector(setMode:error:)])
        [session setMode:@"AVAudioSessionModeMoviePlayback" error:&sessionError];
    [session setActive:YES error:&sessionError];
}

static void TuneTubeUpdateNowPlaying(TuneTubePlayer *player) {
    Class centerClass = NSClassFromString(@"MPNowPlayingInfoCenter");
    if (!centerClass) return;
    id center = [centerClass performSelector:@selector(defaultCenter)];
    if (!center) return;

    TuneTubeTrack *track = player.track;
    if (!track) {
        [center setValue:nil forKey:@"nowPlayingInfo"];
        return;
    }

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (track.title.length) [info setObject:track.title forKey:@"title"];
    if (track.artist.length)
        [info setObject:TuneTubeTrackArtistText(track) forKey:@"artist"];
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

static void TuneTubeUpdateNowPlayingArtwork(TuneTubePlayer *player, TuneTubeTrack *track,
                                       NSUInteger generation) {
    if (!track.thumbnailURL.length) return;
    NSString *requestedURL = [track.thumbnailURL copy];
    TuneLoadImage(requestedURL, ^(UIImage *image) {
        if (!image || player.track != track || generation == 0) return;
        Class centerClass = NSClassFromString(@"MPNowPlayingInfoCenter");
        if (![MPMediaItemArtwork class] || !centerClass) return;
        MPMediaItemArtwork *artwork = TuneTubeArtworkForImage(image);
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

static NSError *TuneTubePlayerError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"TuneTubePlayerError"
                               code:code
                           userInfo:[NSDictionary dictionaryWithObject:message
                                                                forKey:NSLocalizedDescriptionKey]];
}

static void TuneTubePlayerNotify(TuneTubePlayer *player, NSError *error) {
    if (![NSThread isMainThread]) {
        [player retain];
        [error retain];
        dispatch_async(dispatch_get_main_queue(), ^{
            TuneTubePlayerNotify(player, error);
            [error release];
            [player release];
        });
        return;
    }
    TuneTubeUpdateNowPlaying(player);
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:player
                                                                        forKey:@"player"];
    if (error) [info setObject:error forKey:@"error"];
    [[NSNotificationCenter defaultCenter] postNotificationName:TuneTubePlayerDidChangeNotification
                                                        object:player
                                                      userInfo:info];
}

@interface TuneTubePlayer ()
- (void)itemFailedToPlay:(NSNotification *)note;
- (void)itemPlaybackStalled:(NSNotification *)note;
- (void)removeItemStatusObserver;
@end

@implementation TuneTubePlayer

- (id)init {
    self = [super init];
    if (self) {
        _continuousPlayback = YES;
        _playbackRate = 1.0f;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(backgroundAudioChanged:)
                                                     name:TUNETUBE_BACKGROUND_AUDIO_DID_CHANGE_NOTIFICATION
                                                   object:nil];
    }
    return self;
}

- (TuneTubeTrack *)track { return _track; }
- (NSArray *)queue { return _queue; }
- (BOOL)isRepeating { return _repeating; }
- (BOOL)continuousPlayback { return _continuousPlayback; }
- (float)playbackRate { return _playbackRate; }
- (id)nativePlayer { return _player; }

- (BOOL)isPlaying {
    return [_player isKindOfClass:[AVPlayer class]] && [(AVPlayer *)_player rate] > 0.0f;
}

- (NSTimeInterval)currentTime {
    if (![_player isKindOfClass:[AVPlayer class]]) return 0.0;
    Float64 seconds = CMTimeGetSeconds([(AVPlayer *)_player currentTime]);
    return isfinite(seconds) && seconds > 0.0 ? seconds : 0.0;
}

- (NSTimeInterval)duration {
    if (_track.duration) return (NSTimeInterval)_track.duration;
    if (![_player isKindOfClass:[AVPlayer class]]) return 0.0;
    AVPlayerItem *item = [(AVPlayer *)_player currentItem];
    if (!item) return 0.0;
    Float64 seconds = CMTimeGetSeconds(item.duration);
    return isfinite(seconds) && seconds > 0.0 ? seconds : 0.0;
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
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self removeItemStatusObserver];
    [_player pause];
    [_player release];
    [_track release];
    [_api release];
    [_queue release];
    [_sleepTimer invalidate];
    [_sleepTimer release];
    [super dealloc];
}

- (void)backgroundAudioChanged:(NSNotification *)note {
    (void)note;
    if (_player) TuneTubeConfigureAudioSession();
}

- (void)playTrack:(TuneTubeTrack *)track usingAPI:(TuneTubeAPI *)api {
    NSUInteger generation;
    TuneTubeTrack *selectedTrack;
    TuneTubeAPI *selectedAPI;
    if (!track || !api) return;
    if (!track.videoID.length || track.isPlaylist) {
        [_track release];
        _track = [track retain];
        TuneTubePlayerNotify(self, TuneTubePlayerError(6, @"this item has no playable audio"));
        return;
    }
    selectedTrack = [track retain];
    selectedAPI = [api retain];
    ++_generation;
    generation = _generation;
    [_api release];
    _api = selectedAPI;
    [_track release];
    _track = selectedTrack;
    for (NSUInteger index = 0; index < _queue.count; ++index) {
        TuneTubeTrack *queued = [_queue objectAtIndex:index];
        if ([queued.videoID isEqualToString:selectedTrack.videoID]) {
            _queueIndex = (NSInteger)index;
            break;
        }
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemDidPlayToEndTimeNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemPlaybackStalledNotification
                                                  object:nil];
    [self removeItemStatusObserver];
    [_player pause];
    [_player release];
    _player = nil;
    TuneTubePlayerNotify(self, nil);

    TuneTubeConfigureAudioSession();

    // audio only - no music video / clip playback
    [selectedAPI audioURLForTrack:selectedTrack completion:^(NSURL *audioURL, NSError *audioError) {
        if (generation != _generation) return;
        if (audioError || !audioURL) {
            TuneTubePlayerNotify(self, audioError ? audioError :
                            TuneTubePlayerError(8, @"track url could not be loaded"));
            return;
        }
        AVPlayer *av = [[AVPlayer alloc] initWithURL:audioURL];
        if (!av) {
            TuneTubePlayerNotify(self, TuneTubePlayerError(9, @"media player could not be created"));
            return;
        }
        TuneTubeConfigureAudioSession();
        [_player release];
        _player = av;
        AVPlayerItem *item = [(AVPlayer *)_player currentItem];
        if (item) {
            [item addObserver:self
                   forKeyPath:@"status"
                      options:NSKeyValueObservingOptionNew
                      context:NULL];
            _observingItemStatus = YES;
        }
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(itemDidFinish:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:[(AVPlayer *)_player currentItem]];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(itemFailedToPlay:)
                                                     name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                   object:[(AVPlayer *)_player currentItem]];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(itemPlaybackStalled:)
                                                     name:AVPlayerItemPlaybackStalledNotification
                                                   object:[(AVPlayer *)_player currentItem]];
        [(AVPlayer *)_player play];
        if (_playbackRate != 1.0f)
            [(AVPlayer *)_player setRate:_playbackRate];
        TuneTubeUpdateNowPlayingArtwork(self, selectedTrack, generation);
        TuneTubePlayerNotify(self, nil);
    }];
}

- (void)removeItemStatusObserver {
    if (!_observingItemStatus || ![_player isKindOfClass:[AVPlayer class]]) return;
    AVPlayerItem *item = [(AVPlayer *)_player currentItem];
    if (item) [item removeObserver:self forKeyPath:@"status"];
    _observingItemStatus = NO;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    (void)change;
    (void)context;
    if (![keyPath isEqualToString:@"status"] ||
        object != [(AVPlayer *)_player currentItem]) {
        return;
    }

    AVPlayerItem *item = (AVPlayerItem *)object;
    if (item.status == AVPlayerItemStatusReadyToPlay) {
        [(AVPlayer *)_player play];
        if (_playbackRate != 1.0f)
            [(AVPlayer *)_player setRate:_playbackRate];
        TuneTubePlayerNotify(self, nil);
    } else if (item.status == AVPlayerItemStatusFailed) {
        TuneTubePlayerNotify(self, item.error ? item.error :
                              TuneTubePlayerError(12, @"audio could not be loaded"));
    }
}

- (void)itemFailedToPlay:(NSNotification *)note {
    if (![note object] || [note object] != [(AVPlayer *)_player currentItem]) return;
    NSError *error = [[note userInfo] objectForKey:AVPlayerItemFailedToPlayToEndTimeErrorKey];
    TuneTubePlayerNotify(self, error ? error :
                         TuneTubePlayerError(12, @"audio could not be loaded"));
}

- (void)itemPlaybackStalled:(NSNotification *)note {
    if (![note object] || [note object] != [(AVPlayer *)_player currentItem]) return;
    TuneTubePlayerNotify(self, TuneTubePlayerError(10, @"audio is still loading"));
}

- (void)setQueue:(NSArray *)tracks selectedIndex:(NSInteger)index usingAPI:(TuneTubeAPI *)api {
    NSMutableArray *newQueue;
    TuneTubeTrack *selectedTrack;
    TuneTubeAPI *selectedAPI;
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
    if (!_queue.count || !_api) return;
    if (_queueIndex > 0) --_queueIndex;
    [self playTrack:[_queue objectAtIndex:(NSUInteger)_queueIndex] usingAPI:_api];
}

- (void)itemDidFinish:(NSNotification *)note {
    (void)note;
    if (_repeating && _track && _api) {
        [self playTrack:_track usingAPI:_api];
    } else if (_queue.count && _queueIndex + 1 < (NSInteger)_queue.count) {
        [self nextTrack];
    } else if (_continuousPlayback) {
        [self loadMoreTracks];
    } else {
        [_player pause];
        TuneTubePlayerNotify(self, nil);
    }
}

- (void)loadMoreTracks {
    if (_loadingMore || !_api || !_track) return;
    _loadingMore = YES;

    NSString *query = _track.artist.length ? _track.artist : _track.title;
    TuneTubeAPI *api = [_api retain];
    [api search:query completion:^(NSArray *tracks, NSError *error) {
        NSMutableArray *fresh = [NSMutableArray array];
        if (!error) {
            for (TuneTubeTrack *candidate in tracks) {
                BOOL duplicate = NO;
                for (TuneTubeTrack *queued in _queue) {
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
        }
        if (fresh.count) {
            [_queue addObjectsFromArray:fresh];
            _loadingMore = NO;
            [api release];
            [self nextTrack];
        } else {
            _loadingMore = NO;
            [api release];
            [_player pause];
            TuneTubePlayerNotify(self, error);
        }
    }];
}

- (void)setRepeating:(BOOL)repeating {
    if (_repeating == repeating) return;
    _repeating = repeating;
    TuneTubePlayerNotify(self, nil);
}

- (void)enqueueTrack:(TuneTubeTrack *)track usingAPI:(TuneTubeAPI *)api afterCurrent:(BOOL)afterCurrent {
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
    TuneTubePlayerNotify(self, nil);
}

- (void)setContinuousPlayback:(BOOL)enabled {
    if (_continuousPlayback == enabled) return;
    _continuousPlayback = enabled;
    TuneTubePlayerNotify(self, nil);
}

- (void)setPlaybackRate:(float)rate {
    if (rate < 0.5f) rate = 0.5f;
    if (rate > 2.0f) rate = 2.0f;
    _playbackRate = rate;
    if ([_player isKindOfClass:[AVPlayer class]] && [self isPlaying])
        [(AVPlayer *)_player setRate:_playbackRate];
    TuneTubePlayerNotify(self, nil);
}

- (void)sleepTimerFired:(NSTimer *)timer {
    (void)timer;
    [_sleepTimer invalidate];
    [_sleepTimer release];
    _sleepTimer = nil;
    if ([_player isKindOfClass:[AVPlayer class]]) [(AVPlayer *)_player pause];
    TuneTubePlayerNotify(self, nil);
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
    TuneTubePlayerNotify(self, nil);
}

- (void)cancelSleepTimer {
    [self setSleepTimer:0.0];
}

- (void)toggle {
    if (!_track) return;
    if (![_player isKindOfClass:[AVPlayer class]]) {
        TuneTubePlayerNotify(self, TuneTubePlayerError(10, @"audio is still loading"));
        return;
    }
    AVPlayer *player = (AVPlayer *)_player;
    AVPlayerItem *item = [player currentItem];
    if (!item) {
        TuneTubePlayerNotify(self, TuneTubePlayerError(11, @"audio item is missing"));
        return;
    }
    if (item.status == AVPlayerItemStatusFailed) {
        TuneTubePlayerNotify(self, item.error ? item.error : TuneTubePlayerError(12, @"audio could not be loaded"));
        return;
    }
    if (item.status != AVPlayerItemStatusReadyToPlay) {
        TuneTubePlayerNotify(self, TuneTubePlayerError(10, @"audio is still loading"));
        return;
    }
    if ([player rate] > 0.0f) [player pause];
    else {
        [player play];
        if (_playbackRate != 1.0f) [player setRate:_playbackRate];
    }
    TuneTubePlayerNotify(self, nil);
}

- (void)seekToProgress:(float)progress {
    if (![_player isKindOfClass:[AVPlayer class]]) return;
    NSTimeInterval duration = [self duration];
    if (duration <= 0.0) return;
    if (progress < 0.0f) progress = 0.0f;
    if (progress > 1.0f) progress = 1.0f;
    CMTime time = CMTimeMakeWithSeconds((Float64)duration * progress, 600);
    [(AVPlayer *)_player seekToTime:time
                    toleranceBefore:kCMTimeZero
                     toleranceAfter:kCMTimeZero];
    TuneTubePlayerNotify(self, nil);
}

- (void)stop {
    ++_generation;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemDidPlayToEndTimeNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemPlaybackStalledNotification
                                                  object:nil];
    [self removeItemStatusObserver];
    [_player pause];
    [_player release];
    _player = nil;
    [_track release];
    _track = nil;
    [_queue release];
    _queue = nil;
    _queueIndex = 0;
    TuneTubePlayerNotify(self, nil);
}

- (void)clearQueue {
    NSMutableArray *currentQueue = [NSMutableArray array];
    if (_track) [currentQueue addObject:_track];
    [_queue release];
    _queue = [currentQueue mutableCopy];
    _queueIndex = 0;
    TuneTubePlayerNotify(self, nil);
}

@end
