#ifndef YTM_API_H
#define YTM_API_H

#import <Foundation/Foundation.h>

/* keep a fallback for fresh installs; settings can replace it */
FOUNDATION_EXPORT NSString * const YTMDefaultAPIKey;
FOUNDATION_EXPORT NSString *YTMDisplayArtist(NSString *artist);
@class YTMTrack;
FOUNDATION_EXPORT NSString *YTMTrackArtistText(YTMTrack *track);

@interface YTMTrack : NSObject {
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

typedef void (^YTMSearchCompletion)(NSArray *tracks, NSError *error);
typedef void (^YTMAudioCompletion)(NSURL *url, NSError *error);
typedef void (^YTMArtistCompletion)(NSString *artist, NSString *avatarURL, NSError *error);

@interface YTMAPI : NSObject {
    NSString *_apiKey;
}

- (id)initWithAPIKey:(NSString *)apiKey;
- (void)search:(NSString *)query completion:(YTMSearchCompletion)completion;
- (void)audioURLForTrack:(YTMTrack *)track completion:(YTMAudioCompletion)completion;
- (void)playlistTracksForID:(NSString *)playlistID completion:(YTMSearchCompletion)completion;
- (void)artistInfoForID:(NSString *)artistID completion:(YTMArtistCompletion)completion;

@end

#endif /* ytm_api_h */
