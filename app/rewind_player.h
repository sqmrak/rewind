#ifndef REWIND_PLAYER_H
#define REWIND_PLAYER_H

#import <Foundation/Foundation.h>
#include "rewind_playback.h"

@class RewindAPI;
@class RewindTrack;
@class RewindAudioRequest;

extern NSString * const RewindPlayerDidChangeNotification;

@interface RewindPlayer : NSObject {
    id _player;
    RewindTrack *_track;
    RewindAPI *_api;
    NSMutableArray *_queue;
    NSInteger _queueIndex;
    /* a finger on the record: the track follows it back and forth */
    BOOL _scratching, _scratchWasPlaying, _scratchSeeking;
    CFTimeInterval _scratchSeekTime;
    NSTimeInterval _scratchTarget;
    float _scratchVelocity;
    /* the last rate a scratch set and when, so avplayer is not retimed on every touch */
    float _scratchRate;
    CFTimeInterval _scratchRateTime;
    NSUInteger _generation;
    BOOL _repeating;
    BOOL _continuousPlayback;
    BOOL _loadingMore;
    BOOL _observingItemStatus;
    float _playbackRate;
    NSTimer *_sleepTimer;
    NSArray *_orderedQueue;
    BOOL _shuffling;
    RewindAudioRequest *_audioRequest;
    /* the next queued track is resolved while the current one plays, so the switch has no wait */
    RewindAudioRequest *_prefetchRequest;
    RewindTrack *_prefetchTrack;
    NSURL *_prefetchURL;
    id _prefetchAsset;
    BOOL _prefetchScheduled;
    NSMutableSet *_failedAudioSources;
    NSString *_audioSourceKey;
    NSString *_localAudioPath;
    NSTimer *_loadTimer;
    CFRunLoopTimerRef _playbackTimer;
    rewind_playback_t _playbackProgress;
    BOOL _playbackStarted;
    NSUInteger _audioAttempt;
    NSUInteger _audioAttempts;
    BOOL _resolvingAudio;
    BOOL _buffering;
    BOOL _audioFailed;
    BOOL _wantsPlayback;
    NSTimeInterval _resumeTime;
    NSURL *_audioURL;
    BOOL _audioIsPreview;
    NSMutableArray *_recentAudio;
}

@property(nonatomic, readonly) RewindTrack *track;
@property(nonatomic, readonly, getter=isPlaying) BOOL playing;
/* a track is selected but the stream url has not resolved, or the item has not
   reported ready yet; the mini player and full player show a spinner for this */
@property(nonatomic, readonly, getter=isLoading) BOOL loading;
@property(nonatomic, readonly) NSArray *queue;
@property(nonatomic, readonly, getter=isRepeating) BOOL repeating;
@property(nonatomic, readonly) BOOL continuousPlayback;
@property(nonatomic, readonly) float playbackRate;
@property(nonatomic, readonly) NSInteger queueIndex;
@property(nonatomic, readonly, getter=isShuffling) BOOL shuffling;
/* a held record; a track change drops it while the finger is still down */
@property(nonatomic, readonly, getter=isScratching) BOOL scratching;

- (void)playTrack:(RewindTrack *)track usingAPI:(RewindAPI *)api;
- (void)setQueue:(NSArray *)tracks selectedIndex:(NSInteger)index usingAPI:(RewindAPI *)api;
- (void)nextTrack;
- (void)previousTrack;
- (void)toggle;
- (void)stop;
- (void)clearQueue;
- (void)enqueueTrack:(RewindTrack *)track usingAPI:(RewindAPI *)api afterCurrent:(BOOL)afterCurrent;
- (void)setContinuousPlayback:(BOOL)enabled;
- (void)setPlaybackRate:(float)rate;
- (void)setSleepTimer:(NSTimeInterval)seconds;
- (void)cancelSleepTimer;
- (float)progress;
- (NSTimeInterval)currentTime;
- (NSTimeInterval)duration;
- (void)seekToProgress:(float)progress;
- (void)seekToTime:(NSTimeInterval)time;
/* record scratching: begin holds the track, each move shifts it by a number of seconds (negative goes back)
   over the given real time interval, end lets it go on from where the finger left it */
- (void)beginScratch;
- (void)scratchByTime:(NSTimeInterval)delta interval:(NSTimeInterval)interval;
- (void)endScratch;
- (void)setRepeating:(BOOL)repeating;
/* shuffles what is left after the current track; turning it off restores the order */
- (void)setShuffling:(BOOL)shuffling;
- (void)playQueueIndex:(NSInteger)index;
- (id)nativePlayer;

@end

#endif /* rewind_player_h */
