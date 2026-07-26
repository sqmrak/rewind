#ifndef YTM_MAIN_VC_H
#define YTM_MAIN_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class TunePlaybackButton;
@class TuneRoundButton;
@class YTMTrack;

@interface MainVC : UIViewController <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate> {
    id _api;
    id _player;
    NSMutableArray *_tracks;
    CAGradientLayer *_backgroundGradient;
    UISearchBar *_search;
    UIButton *_libraryButton;
    UIButton *_optionsButton;
    UILabel *_brandLabel;
    UILabel *_taglineLabel;
    UILabel *_sectionTitle;
    UITableView *_table;
    UILabel *_status;
    UIScrollView *_recommendationScroll;
    NSMutableArray *_recommendations;
    YTMTrack *_playlistTrack;
    UIControl *_miniPlayer;
    CAGradientLayer *_miniPlayerGradient;
    UIImageView *_miniArtwork;
    UILabel *_nowTitle;
    UILabel *_nowArtist;
    TuneRoundButton *_favoriteButton;
    TunePlaybackButton *_playButton;
}
@end

#endif /* ytm_main_vc_h */
