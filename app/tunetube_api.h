#ifndef TUNETUBE_API_H
#define TUNETUBE_API_H

#import <Foundation/Foundation.h>

/* keep a fallback for fresh installs; settings can replace it */
FOUNDATION_EXPORT NSString * const TuneTubeDefaultAPIKey;
FOUNDATION_EXPORT NSString *TuneTubeDisplayArtist(NSString *artist);
@class TuneTubeTrack;
FOUNDATION_EXPORT NSString *TuneTubeTrackArtistText(TuneTubeTrack *track);

@interface TuneTubeTrack : NSObject {
    NSString *_videoID;
    NSString *_title;
    NSString *_artist;
    NSString *_album;
    NSString *_thumbnailURL;
    NSString *_playlistID;
    NSString *_artistID;
    NSString *_resultType;
    NSUInteger _duration;
}

@property(nonatomic, readonly) NSString *videoID;
@property(nonatomic, readonly) NSString *title;
@property(nonatomic, readonly) NSString *artist;
@property(nonatomic, readonly) NSString *album;
@property(nonatomic, readonly) NSString *thumbnailURL;
@property(nonatomic, readonly) NSString *playlistID;
@property(nonatomic, readonly) NSString *artistID;
@property(nonatomic, readonly) NSString *resultType;
@property(nonatomic, readonly) NSUInteger duration;
@property(nonatomic, readonly, getter=isPlaylist) BOOL playlist;

- (id)initWithVideoID:(NSString *)videoID
                title:(NSString *)title
               artist:(NSString *)artist
                album:(NSString *)album
        thumbnailURL:(NSString *)thumbnailURL
             duration:(NSUInteger)duration;
- (id)initWithVideoID:(NSString *)videoID
                title:(NSString *)title
               artist:(NSString *)artist
                album:(NSString *)album
        thumbnailURL:(NSString *)thumbnailURL
             duration:(NSUInteger)duration
          playlistID:(NSString *)playlistID
            artistID:(NSString *)artistID
         resultType:(NSString *)resultType;

@end

typedef void (^TuneTubeSearchCompletion)(NSArray *tracks, NSError *error);
typedef void (^TuneTubeAudioCompletion)(NSURL *url, NSError *error);
typedef void (^TuneTubeDurationCompletion)(NSUInteger duration, NSError *error);
typedef void (^TuneTubeArtistCompletion)(NSString *artist, NSString *avatarURL, NSError *error);

@interface TuneTubeAPI : NSObject {
    NSString *_apiKey;
}

- (id)initWithAPIKey:(NSString *)apiKey;
- (void)search:(NSString *)query completion:(TuneTubeSearchCompletion)completion;
- (void)durationForTrack:(TuneTubeTrack *)track completion:(TuneTubeDurationCompletion)completion;
- (void)audioURLForTrack:(TuneTubeTrack *)track completion:(TuneTubeAudioCompletion)completion;
- (void)playlistTracksForID:(NSString *)playlistID completion:(TuneTubeSearchCompletion)completion;
- (void)artistInfoForID:(NSString *)artistID completion:(TuneTubeArtistCompletion)completion;

@end

#endif /* tunetube_api_h */
