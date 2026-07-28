#ifndef TUNETUBE_PLAYER_VC_H
#define TUNETUBE_PLAYER_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class TuneTubePlayer;
@class TuneTubeAPI;
@class TuneTubeTrack;
@class TunePlaybackButton;
@class TuneRoundButton;

typedef enum {
    TunePlayerMenuActionClose = 0,
    TunePlayerMenuActionPlayNext,
    TunePlayerMenuActionPlaylist,
    TunePlayerMenuActionShare,
    TunePlayerMenuActionMix,
    TunePlayerMenuActionQueue,
    TunePlayerMenuActionLibrary,
    TunePlayerMenuActionDownload,
    TunePlayerMenuActionRemovePlaylist,
    TunePlayerMenuActionAlbum,
    TunePlayerMenuActionArtist,
    TunePlayerMenuActionClearQueue,
    TunePlayerMenuActionSpeed,
    TunePlayerMenuActionSleep
} TunePlayerMenuAction;

@protocol TunePlayerMenuDelegate;

@interface TunePlayerMenuVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    TuneTubePlayer *_player;
    TuneTubeAPI *_api;
    TuneTubeTrack *_track;
    id<TunePlayerMenuDelegate> _delegate;
    CAGradientLayer *_gradient;
    UITableView *_table;
    UIView *_header;
    UIButton *_closeButton;
    UIImageView *_headerArtwork;
    UILabel *_headerTitle;
    UILabel *_headerArtist;
    UILabel *_headerDuration;
    NSArray *_cardButtons;
    NSArray *_rows;
}

- (id)initWithPlayer:(TuneTubePlayer *)player
                 api:(TuneTubeAPI *)api
            delegate:(id<TunePlayerMenuDelegate>)delegate;
- (id)initWithTrack:(TuneTubeTrack *)track
             player:(TuneTubePlayer *)player
                api:(TuneTubeAPI *)api
           delegate:(id<TunePlayerMenuDelegate>)delegate;
@end

@protocol TunePlayerMenuDelegate <NSObject>
- (void)tunePlayerMenu:(TunePlayerMenuVC *)menu didSelectAction:(NSInteger)action;
@end

@interface TunePlayerVC : UIViewController {
    TuneTubePlayer *_player;
    TuneTubeAPI *_api;
    CAGradientLayer *_backgroundGradient;
    CAGradientLayer *_headerGradient;
    UIView *_headerBar;
    UIButton *_headerSearch;
    UIButton *_headerLibrary;
    UILabel *_headerTitle;
    UIImageView *_artwork;
    UIView *_titleViewport;
    UILabel *_titleLabel;
    UILabel *_titleLoopLabel;
    UILabel *_artistLabel;
    UIButton *_artistButton;
    UISlider *_progress;
    UILabel *_elapsedLabel;
    UILabel *_durationLabel;
    TuneRoundButton *_previousButton;
    TuneRoundButton *_nextButton;
    TuneRoundButton *_repeatButton;
    TuneRoundButton *_favoriteButton;
    TunePlaybackButton *_playButton;
    NSTimer *_progressTimer;
    NSTimer *_titleMarqueeTimer;
    NSString *_titleMarqueeText;
    TuneTubeTrack *_menuTrack;
    CGFloat _titleMarqueeTextWidth;
    CGFloat _titleMarqueeCycle;
    CGFloat _titleMarqueeOffset;
}

- (id)initWithPlayer:(TuneTubePlayer *)player;
- (id)initWithPlayer:(TuneTubePlayer *)player api:(TuneTubeAPI *)api;

@end

void TunePushAlbum(UIViewController *source,
                   TuneTubeTrack *track,
                   TuneTubeAPI *api,
                   TuneTubePlayer *player);

#endif
