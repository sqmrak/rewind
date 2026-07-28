#ifndef TUNETUBE_ARTIST_VC_H
#define TUNETUBE_ARTIST_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class TuneTubeAPI;
@class TuneTubePlayer;
@class TuneTubeTrack;

@protocol TuneArtistTrackCellDelegate <NSObject>
- (void)tuneArtistCell:(id)cell didSelectTrack:(TuneTubeTrack *)track;
@optional
- (void)tuneTrackCell:(id)cell didPressMenuForTrack:(TuneTubeTrack *)track;
@end

@interface TuneArtistVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    NSString *_artistName;
    NSString *_artworkURL;
    TuneTubeAPI *_api;
    TuneTubePlayer *_player;
    TuneTubeTrack *_seedTrack;
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
                 api:(TuneTubeAPI *)api
             player:(TuneTubePlayer *)player
          seedTrack:(TuneTubeTrack *)seedTrack;

@end

void TunePushArtistProfile(UIViewController *source,
                           TuneTubeTrack *track,
                           TuneTubeAPI *api,
                           TuneTubePlayer *player);

#endif /* TUNETUBE_ARTIST_VC_H */
