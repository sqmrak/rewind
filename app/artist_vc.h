#ifndef TUNETUBE_ARTIST_VC_H
#define TUNETUBE_ARTIST_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class YTMAPI;
@class YTMPlayer;
@class YTMTrack;

@protocol TuneArtistTrackCellDelegate <NSObject>
- (void)tuneArtistCell:(id)cell didSelectTrack:(YTMTrack *)track;
@end

@interface TuneArtistVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    NSString *_artistName;
    NSString *_artworkURL;
    YTMAPI *_api;
    YTMPlayer *_player;
    YTMTrack *_seedTrack;
    NSMutableArray *_tracks;
    UIView *_profileCard;
    CAGradientLayer *_backgroundGradient;
    CAGradientLayer *_profileGradient;
    UIImageView *_artwork;
    UILabel *_artistLabel;
    UILabel *_status;
    UITableView *_table;
}

- (id)initWithArtist:(NSString *)artist
          artworkURL:(NSString *)artworkURL
                 api:(YTMAPI *)api
             player:(YTMPlayer *)player
          seedTrack:(YTMTrack *)seedTrack;

@end

void TunePushArtistProfile(UIViewController *source,
                           YTMTrack *track,
                           YTMAPI *api,
                           YTMPlayer *player);

#endif /* TUNETUBE_ARTIST_VC_H */
