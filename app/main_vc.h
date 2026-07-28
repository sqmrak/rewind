#ifndef TUNETUBE_MAIN_VC_H
#define TUNETUBE_MAIN_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class TunePlaybackButton;
@class TuneRoundButton;
@class TuneTubeTrack;
@class TunePlayerMenuVC;

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
    BOOL _searchEditing;
    UITapGestureRecognizer *_searchDismissGesture;
    UIScrollView *_homeScroll;
    CGSize _lastLayoutSize;
    BOOL _hasLastLayoutSize;
    BOOL _lastLayoutHome;
    UILabel *_sectionTitle;
    UITableView *_table;
    UILabel *_status;
    UIScrollView *_recommendationScroll;
    UIScrollView *_recommendationPages;
    NSMutableArray *_homeRecommendationTracks;
    UIView *_recommendationDots;
    NSMutableArray *_recommendationDotViews;
    NSMutableArray *_recommendations;
    UIButton *_recommendationMore;
    BOOL _homeShowAll;
    TuneTubeTrack *_playlistTrack;
    UIControl *_miniPlayer;
    CAGradientLayer *_miniPlayerGradient;
    UIImageView *_miniArtwork;
    UILabel *_nowTitle;
    UILabel *_nowArtist;
    TuneRoundButton *_favoriteButton;
    TunePlaybackButton *_playButton;
    TuneTubeTrack *_actionTrack;
}
@end

#endif /* tunetube_main_vc_h */
