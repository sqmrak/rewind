#ifndef TUNETUBE_PLAYER_H
#define TUNETUBE_PLAYER_H

#import <Foundation/Foundation.h>

@class TuneTubeAPI;
@class TuneTubeTrack;

extern NSString * const TuneTubePlayerDidChangeNotification;

@interface TuneTubePlayer : NSObject {
    id _player;
    TuneTubeTrack *_track;
    TuneTubeAPI *_api;
    NSMutableArray *_queue;
    NSInteger _queueIndex;
    NSUInteger _generation;
    BOOL _repeating;
    BOOL _continuousPlayback;
    BOOL _loadingMore;
    BOOL _observingItemStatus;
    float _playbackRate;
    NSTimer *_sleepTimer;
}

@property(nonatomic, readonly) TuneTubeTrack *track;
@property(nonatomic, readonly, getter=isPlaying) BOOL playing;
@property(nonatomic, readonly) NSArray *queue;
@property(nonatomic, readonly, getter=isRepeating) BOOL repeating;
@property(nonatomic, readonly) BOOL continuousPlayback;
@property(nonatomic, readonly) float playbackRate;

- (void)playTrack:(TuneTubeTrack *)track usingAPI:(TuneTubeAPI *)api;
- (void)setQueue:(NSArray *)tracks selectedIndex:(NSInteger)index usingAPI:(TuneTubeAPI *)api;
- (void)nextTrack;
- (void)previousTrack;
- (void)toggle;
- (void)stop;
- (void)clearQueue;
- (void)enqueueTrack:(TuneTubeTrack *)track usingAPI:(TuneTubeAPI *)api afterCurrent:(BOOL)afterCurrent;
- (void)setContinuousPlayback:(BOOL)enabled;
- (void)setPlaybackRate:(float)rate;
- (void)setSleepTimer:(NSTimeInterval)seconds;
- (void)cancelSleepTimer;
- (float)progress;
- (NSTimeInterval)currentTime;
- (NSTimeInterval)duration;
- (void)seekToProgress:(float)progress;
- (void)setRepeating:(BOOL)repeating;
- (id)nativePlayer;

@end

#endif /* tunetube_player_h */
