#import "ytm_player.h"

#import <dispatch/dispatch.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import "ytm_api.h"
#import "tunetube_image_cache.h"
#import "tunetube_config.h"

#include <math.h>

NSString * const YTMPlayerDidChangeNotification = @"YTMPlayerDidChangeNotification";
static NSString * const YTMPlaybackAudioCategory = @"AVAudioSessionCategoryPlayback";
static NSString * const YTMAmbientAudioCategory = @"AVAudioSessionCategoryAmbient";

/* the ios 6 headers do not declare the initializer added in ios 10 */
@interface MPMediaItemArtwork (TuneTubeIOS10)
- (id)initWithBoundsSize:(CGSize)size
          requestHandler:(UIImage *(^)(CGSize size))handler;
@end

static MPMediaItemArtwork *YTMArtworkForImage(UIImage *image) {
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

static BOOL YTMBackgroundAudioEnabled(void) {
    id value = [[NSUserDefaults standardUserDefaults]
                objectForKey:TUNETUBE_BACKGROUND_AUDIO_DEFAULTS_KEY];
    return !value || [value boolValue];
}

static void YTMConfigureAudioSession(void) {
    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSString *category = YTMBackgroundAudioEnabled()
        ? YTMPlaybackAudioCategory : YTMAmbientAudioCategory;
    [session setCategory:category error:&sessionError];
    [session setActive:YES error:&sessionError];
}

static void YTMUpdateNowPlaying(YTMPlayer *player) {
    Class centerClass = NSClassFromString(@"MPNowPlayingInfoCenter");
    if (!centerClass) return;
    id center = [centerClass performSelector:@selector(defaultCenter)];
    if (!center) return;

    YTMTrack *track = player.track;
    if (!track) {
        [center setValue:nil forKey:@"nowPlayingInfo"];
        return;
    }

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (track.title.length) [info setObject:track.title forKey:@"title"];
    if (track.artist.length)
        [info setObject:YTMTrackArtistText(track) forKey:@"artist"];
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

static void YTMUpdateNowPlayingArtwork(YTMPlayer *player, YTMTrack *track,
                                       NSUInteger generation) {
    if (!track.thumbnailURL.length) return;
    NSString *requestedURL = [track.thumbnailURL copy];
    TuneLoadImage(requestedURL, ^(UIImage *image) {
        if (!image || player.track != track || generation == 0) return;
        Class centerClass = NSClassFromString(@"MPNowPlayingInfoCenter");
        if (![MPMediaItemArtwork class] || !centerClass) return;
        MPMediaItemArtwork *artwork = YTMArtworkForImage(image);
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

static NSError *YTMPlayerError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"TuneTubePlayerError"
                               code:code
                           userInfo:[NSDictionary dictionaryWithObject:message
                                                                forKey:NSLocalizedDescriptionKey]];
}

static void YTMPlayerNotify(YTMPlayer *player, NSError *error) {
    if (![NSThread isMainThread]) {
        [player retain];
        [error retain];
        dispatch_async(dispatch_get_main_queue(), ^{
            YTMPlayerNotify(player, error);
            [error release];
            [player release];
        });
        return;
    }
    YTMUpdateNowPlaying(player);
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:player
                                                                        forKey:@"player"];
    if (error) [info setObject:error forKey:@"error"];
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMPlayerDidChangeNotification
                                                        object:player
                                                      userInfo:info];
}

@implementation YTMPlayer

- (id)init {
    self = [super init];
    if (self) {
        _continuousPlayback = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(backgroundAudioChanged:)
                                                     name:TUNETUBE_BACKGROUND_AUDIO_DID_CHANGE_NOTIFICATION
                                                   object:nil];
    }
    return self;
}

- (YTMTrack *)track { return _track; }
- (NSArray *)queue { return _queue; }
- (BOOL)isRepeating { return _repeating; }
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
    [_player pause];
    [_player release];
    [_track release];
    [_api release];
    [_queue release];
    [super dealloc];
}

- (void)backgroundAudioChanged:(NSNotification *)note {
    (void)note;
    if (_player) YTMConfigureAudioSession();
}

- (void)playTrack:(YTMTrack *)track usingAPI:(YTMAPI *)api {
    NSUInteger generation;
    YTMTrack *selectedTrack;
    YTMAPI *selectedAPI;
    if (!track || !api) return;
    selectedTrack = [track retain];
    selectedAPI = [api retain];
    ++_generation;
    generation = _generation;
    [_api release];
    _api = selectedAPI;
    [_track release];
    _track = selectedTrack;
    for (NSUInteger index = 0; index < _queue.count; ++index) {
        YTMTrack *queued = [_queue objectAtIndex:index];
        if ([queued.videoID isEqualToString:selectedTrack.videoID]) {
            _queueIndex = (NSInteger)index;
            break;
        }
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemDidPlayToEndTimeNotification
                                                  object:nil];
    [_player pause];
    [_player release];
    _player = nil;
    YTMPlayerNotify(self, nil);

    YTMConfigureAudioSession();

    // audio only - no music video / clip playback
    [selectedAPI audioURLForTrack:selectedTrack completion:^(NSURL *audioURL, NSError *audioError) {
        if (generation != _generation) return;
        if (audioError || !audioURL) {
            YTMPlayerNotify(self, audioError ? audioError :
                            YTMPlayerError(8, @"track url could not be loaded"));
            return;
        }
        AVPlayer *av = [[AVPlayer alloc] initWithURL:audioURL];
        if (!av) {
            YTMPlayerNotify(self, YTMPlayerError(9, @"media player could not be created"));
            return;
        }
        [_player release];
        _player = av;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(itemDidFinish:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:[(AVPlayer *)_player currentItem]];
        [(AVPlayer *)_player play];
        YTMUpdateNowPlayingArtwork(self, selectedTrack, generation);
        YTMPlayerNotify(self, nil);
    }];
}

- (void)setQueue:(NSArray *)tracks selectedIndex:(NSInteger)index usingAPI:(YTMAPI *)api {
    NSMutableArray *newQueue;
    YTMTrack *selectedTrack;
    YTMAPI *selectedAPI;
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
        YTMPlayerNotify(self, nil);
    }
}

- (void)loadMoreTracks {
    if (_loadingMore || !_api || !_track) return;
    _loadingMore = YES;

    NSString *query = _track.artist.length ? _track.artist : _track.title;
    YTMAPI *api = [_api retain];
    [api search:query completion:^(NSArray *tracks, NSError *error) {
        NSMutableArray *fresh = [NSMutableArray array];
        if (!error) {
            for (YTMTrack *candidate in tracks) {
                BOOL duplicate = NO;
                for (YTMTrack *queued in _queue) {
                    if ([candidate.videoID isEqualToString:queued.videoID]) {
                        duplicate = YES;
                        break;
                    }
                }
                if (!duplicate && candidate.videoID.length) {
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
            YTMPlayerNotify(self, error);
        }
    }];
}

- (void)setRepeating:(BOOL)repeating {
    if (_repeating == repeating) return;
    _repeating = repeating;
    YTMPlayerNotify(self, nil);
}

- (void)toggle {
    if (!_track) return;
    if (![_player isKindOfClass:[AVPlayer class]]) {
        YTMPlayerNotify(self, YTMPlayerError(10, @"audio is still loading"));
        return;
    }
    AVPlayer *player = (AVPlayer *)_player;
    AVPlayerItem *item = [player currentItem];
    if (!item) {
        YTMPlayerNotify(self, YTMPlayerError(11, @"audio item is missing"));
        return;
    }
    if (item.status == AVPlayerItemStatusFailed) {
        YTMPlayerNotify(self, item.error ? item.error : YTMPlayerError(12, @"audio could not be loaded"));
        return;
    }
    if (item.status != AVPlayerItemStatusReadyToPlay) {
        YTMPlayerNotify(self, YTMPlayerError(10, @"audio is still loading"));
        return;
    }
    if ([player rate] > 0.0f) [player pause];
    else [player play];
    YTMPlayerNotify(self, nil);
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
    YTMPlayerNotify(self, nil);
}

- (void)stop {
    ++_generation;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemDidPlayToEndTimeNotification
                                                  object:nil];
    [_player pause];
    [_player release];
    _player = nil;
    [_track release];
    _track = nil;
    [_queue release];
    _queue = nil;
    _queueIndex = 0;
    YTMPlayerNotify(self, nil);
}

@end
