#ifndef YTM_PLAYER_H
#define YTM_PLAYER_H

#import <Foundation/Foundation.h>

@class YTMAPI;
@class YTMTrack;

extern NSString * const YTMPlayerDidChangeNotification;

@interface YTMPlayer : NSObject {
    id _player;
    YTMTrack *_track;
    YTMAPI *_api;
    NSMutableArray *_queue;
    NSInteger _queueIndex;
    NSUInteger _generation;
    BOOL _repeating;
    BOOL _continuousPlayback;
    BOOL _loadingMore;
}

@property(nonatomic, readonly) YTMTrack *track;
@property(nonatomic, readonly, getter=isPlaying) BOOL playing;
@property(nonatomic, readonly) NSArray *queue;
@property(nonatomic, readonly, getter=isRepeating) BOOL repeating;

- (void)playTrack:(YTMTrack *)track usingAPI:(YTMAPI *)api;
- (void)setQueue:(NSArray *)tracks selectedIndex:(NSInteger)index usingAPI:(YTMAPI *)api;
- (void)nextTrack;
- (void)previousTrack;
- (void)toggle;
- (void)stop;
- (float)progress;
- (NSTimeInterval)currentTime;
- (NSTimeInterval)duration;
- (void)seekToProgress:(float)progress;
- (void)setRepeating:(BOOL)repeating;
- (id)nativePlayer;

@end

#endif /* ytm_player_h */
