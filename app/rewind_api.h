#ifndef REWIND_API_H
#define REWIND_API_H

#import <Foundation/Foundation.h>

/* keep a fallback for fresh installs; settings can replace it */
FOUNDATION_EXPORT NSString * const RewindDefaultAPIKey;

typedef void (^RewindTranslateCompletion)(NSArray *lines, NSError *error);

/* opens the https connections a track start needs (the player endpoint and the last sabr host) while nothing waits
   on them, a tls handshake on an old phone costs about a second; calls within twenty seconds do nothing */
void RewindWarmPlaybackConnections(void);
FOUNDATION_EXPORT NSString *RewindDisplayArtist(NSString *artist);
@class RewindTrack;
FOUNDATION_EXPORT NSString *RewindTrackArtistText(RewindTrack *track);
/* "3:07" or "1:02:03" to seconds, 0 when the text is not a clock */
FOUNDATION_EXPORT NSUInteger RewindClockSeconds(NSString *value);

@interface RewindTrack : NSObject {
    NSString *_videoID;
    NSString *_title;
    NSString *_artist;
    NSString *_album;
    NSString *_thumbnailURL;
    NSString *_playlistID;
    NSString *_artistID;
    NSString *_resultType;
    NSString *_detail;
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
/* the second line exactly as youtube words it, nil when the track came from storage */
@property(nonatomic, readonly) NSString *detail;

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
- (RewindTrack *)trackWithDetail:(NSString *)detail;

@end

/* result types the shelves add to the ones search already produces */
FOUNDATION_EXPORT NSString * const RewindResultTypeMix;
FOUNDATION_EXPORT NSString * const RewindResultTypeAlbum;
FOUNDATION_EXPORT NSString * const RewindResultTypeArtist;

/* a mood, genre, chip or chart button: a browse page reached with an id and params */
@interface RewindBrowseLink : NSObject {
    NSString *_title;
    NSString *_browseID;
    NSString *_params;
    uint32_t _stripeColor;
}
@property(nonatomic, readonly) NSString *title;
@property(nonatomic, readonly) NSString *browseID;
@property(nonatomic, readonly) NSString *params;
/* argb as youtube sends it, 0 when the button has no colour stripe */
@property(nonatomic, readonly) uint32_t stripeColor;
- (id)initWithTitle:(NSString *)title browseID:(NSString *)browseID params:(NSString *)params
        stripeColor:(uint32_t)stripeColor;
@end

typedef enum {
    RewindShelfStyleCards = 0,
    RewindShelfStyleList,
    RewindShelfStyleLinks
} RewindShelfStyle;

/* one row of a browse page: RewindTrack items, or RewindBrowseLink items for mood grids */
@interface RewindShelf : NSObject {
    NSString *_title;
    NSString *_caption;
    NSArray *_items;
    RewindShelfStyle _style;
}
@property(nonatomic, readonly) NSString *title;
/* the small line above the title, like the account name over quick picks */
@property(nonatomic, readonly) NSString *caption;
@property(nonatomic, readonly) NSArray *items;
@property(nonatomic, readonly) RewindShelfStyle style;
/* a shelf of music clips; youtube words its title differently per language, so the items decide */
@property(nonatomic, readonly, getter=isVideoLineup) BOOL videoLineup;
- (id)initWithTitle:(NSString *)title items:(NSArray *)items;
- (id)initWithTitle:(NSString *)title caption:(NSString *)caption items:(NSArray *)items
              style:(RewindShelfStyle)style;
@end

@interface RewindLyricLine : NSObject {
    NSString *_text;
    NSUInteger _startMS;
}
@property(nonatomic, readonly) NSString *text;
@property(nonatomic, readonly) NSUInteger startMS;
- (id)initWithText:(NSString *)text startMS:(NSUInteger)startMS;
@end

@interface RewindLyrics : NSObject {
    NSArray *_lines;
    BOOL _timed;
    NSString *_source;
}
@property(nonatomic, readonly) NSArray *lines;
@property(nonatomic, readonly, getter=isTimed) BOOL timed;
@property(nonatomic, readonly) NSString *source;
- (id)initWithLines:(NSArray *)lines timed:(BOOL)timed source:(NSString *)source;
@end

typedef void (^RewindSearchCompletion)(NSArray *tracks, NSError *error);
void RewindDebugLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/* a short, localized message for a toast or status label, in the voice the real
   youtube/youtube music apps use ("no internet connection", "something went
   wrong") rather than the internal failure text NSError carries for logging */
NSString *RewindFriendlyError(NSError *error);
/* YES when a lyrics lookup ended because the track has none, not because the network failed */
BOOL RewindLyricsMissing(NSError *error);

typedef void (^RewindAudioCompletion)(NSURL *url, NSError *error);
@interface RewindAudioRequest : NSObject {
    BOOL _cancelled;
    BOOL _allowsPreview;
    BOOL _upgradeExpected;
    void (^_onUpgrade)(NSURL *url, NSError *error);
    RewindAudioRequest *_parent;
}
@property(nonatomic, readonly, getter=isCancelled) BOOL cancelled;
/* the track being played starts early: a sabr or proxy track first answers with a short playable file, and a
   plain https file is handed over before its probe has finished. the complete file, the next candidate after a
   refused probe, or nil and an error comes later through onUpgrade */
@property(nonatomic, assign) BOOL allowsPreview;
@property(nonatomic, assign) BOOL upgradeExpected;
@property(nonatomic, copy) void (^onUpgrade)(NSURL *url, NSError *error);
- (void)cancel;
/* a request that is cancelled with this one but can also be cancelled alone, for the clients raced
   side by side; preview and upgrade settings are read from this request */
- (RewindAudioRequest *)branch;
@end
/* googlevideo ties a playback url to the client user-agent that requested it; AVPlayer's
   own request carries none of that, so the android and vr direct urls need it attached
   by hand or the cdn answers with a format AVPlayer reports as unplayable */
NSString *RewindAudioUserAgentForURL(NSURL *url);
NSString *RewindAudioSourceKeyForURL(NSURL *url);
typedef void (^RewindDurationCompletion)(NSUInteger duration, NSError *error);
/* the full artist page: header details plus every browse shelf (top songs, albums, singles, related artists) */
typedef void (^RewindArtistPageCompletion)(NSString *artist, NSString *avatarURL,
                                            NSString *subscriberText, BOOL subscribed,
                                            NSArray *shelves, NSError *error);
typedef void (^RewindShelvesCompletion)(NSArray *shelves, NSArray *chips, NSError *error);
typedef void (^RewindSuggestionsCompletion)(NSArray *suggestions, NSError *error);
typedef void (^RewindLyricsCompletion)(RewindLyrics *lyrics, NSError *error);

@interface RewindAPI : NSObject {
    NSString *_apiKey;
    NSMutableDictionary *_relatedCache;
    NSMutableArray *_relatedOrder;
}

- (id)initWithAPIKey:(NSString *)apiKey;
- (void)search:(NSString *)query completion:(RewindSearchCompletion)completion;
- (void)durationForTrack:(RewindTrack *)track completion:(RewindDurationCompletion)completion;
- (void)audioURLForTrack:(RewindTrack *)track completion:(RewindAudioCompletion)completion;
/* what the player opens: the aac file rebuilt as a plain m4a on 127.0.0.1, else the direct file */
- (void)streamURLForTrack:(RewindTrack *)track completion:(RewindAudioCompletion)completion;
/* failed AVPlayer sources are skipped even when youtube refreshes their signed urls */
- (RewindAudioRequest *)streamURLForTrack:(RewindTrack *)track excludingSources:(NSSet *)sources
              completion:(RewindAudioCompletion)completion;
- (void)playlistTracksForID:(NSString *)playlistID completion:(RewindSearchCompletion)completion;
- (void)artistPageForID:(NSString *)artistID completion:(RewindArtistPageCompletion)completion;

/* public youtube music pages: home and its mood chips, explore, moods, charts, albums */
- (void)browseShelves:(NSString *)browseID params:(NSString *)params
           completion:(RewindShelvesCompletion)completion;
- (void)searchSuggestions:(NSString *)query completion:(RewindSuggestionsCompletion)completion;
/* synced lines when youtube has them, plain text otherwise */
- (void)lyricsForTrack:(RewindTrack *)track completion:(RewindLyricsCompletion)completion;
/* YES for catalog songs and official clips, NO for plain uploads such as gameplay or vlogs */
- (void)isCatalogMusicForTrack:(RewindTrack *)track completion:(void (^)(BOOL music, NSError *error))completion;
/* one line in, one line out; the completion gets nil lines and an error when the counts differ */
- (void)translateLines:(NSArray *)lines toLanguage:(NSString *)language completion:(RewindTranslateCompletion)completion;
- (void)relatedForTrack:(RewindTrack *)track completion:(RewindShelvesCompletion)completion;

@end

#endif /* rewind_api_h */
