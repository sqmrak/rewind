#ifndef REWIND_ARTIST_VC_H
#define REWIND_ARTIST_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class RewindAPI;
@class RewindPlayer;
@class RewindTrack;
@class RewindArtworkView;
@class RewindIconButton;
@class RewindPillButton;

@protocol RewindArtistTrackCellDelegate <NSObject>
- (void)rewindArtistCell:(id)cell didSelectTrack:(RewindTrack *)track;
@optional
- (void)rewindTrackCell:(id)cell didPressMenuForTrack:(RewindTrack *)track;
@end

@interface RewindArtistVC : UIViewController <UIScrollViewDelegate, UIAlertViewDelegate> {
    NSString *_artistName;
    NSString *_artistID;
    NSString *_artworkURL;
    NSString *_subscriberText;
    BOOL _subscribed;
    RewindAPI *_api;
    RewindPlayer *_player;
    NSArray *_shelves;
    RewindTrack *_menuTrack;
    CGFloat _laidWidth;
    CGFloat _headerHeight;

    UIView *_headerView;
    RewindArtworkView *_headerArt;
    CAGradientLayer *_headerScrimTop;
    CAGradientLayer *_headerScrimBottom;
    UIView *_backBacking;
    RewindIconButton *_backButton;
    RewindIconButton *_radioButton;
    RewindIconButton *_playButton;
    RewindPillButton *_subscribeButton;
    UILabel *_nameLabel;
    UILabel *_subLabel;

    UIScrollView *_content;
    UILabel *_status;
}

- (id)initWithArtist:(NSString *)artist
          artworkURL:(NSString *)artworkURL
                 api:(RewindAPI *)api
             player:(RewindPlayer *)player
          seedTrack:(RewindTrack *)seedTrack;

@end

void RewindPushArtistProfile(UIViewController *source,
                           RewindTrack *track,
                           RewindAPI *api,
                           RewindPlayer *player);

#endif /* REWIND_ARTIST_VC_H */
