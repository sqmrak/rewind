#ifndef TUNETUBE_PLAYER_VC_H
#define TUNETUBE_PLAYER_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class YTMPlayer;
@class YTMAPI;
@class TunePlaybackButton;
@class TuneRoundButton;

@interface TunePlayerVC : UIViewController {
    YTMPlayer *_player;
    YTMAPI *_api;
    CAGradientLayer *_backgroundGradient;
    CAGradientLayer *_headerGradient;
    UIView *_headerBar;
    UIButton *_headerSearch;
    UIButton *_headerLibrary;
    UILabel *_headerTitle;
    UIImageView *_artwork;
    UILabel *_titleLabel;
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
}

- (id)initWithPlayer:(YTMPlayer *)player;
- (id)initWithPlayer:(YTMPlayer *)player api:(YTMAPI *)api;

@end

#endif
