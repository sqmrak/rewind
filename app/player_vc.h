#ifndef REWIND_PLAYER_VC_H
#define REWIND_PLAYER_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class RewindPlayer;
@class RewindAPI;
@class RewindTrack;

typedef enum {
    RewindPlayerMenuActionClose = 0,
    RewindPlayerMenuActionPlayNext,
    RewindPlayerMenuActionPlaylist,
    RewindPlayerMenuActionShare,
    RewindPlayerMenuActionMix,
    RewindPlayerMenuActionQueue,
    RewindPlayerMenuActionLibrary,
    RewindPlayerMenuActionDownload,
    RewindPlayerMenuActionRemovePlaylist,
    RewindPlayerMenuActionAlbum,
    RewindPlayerMenuActionArtist,
    RewindPlayerMenuActionClearQueue,
    RewindPlayerMenuActionSpeed,
    RewindPlayerMenuActionSleep,
    RewindPlayerMenuActionLyrics,
    RewindPlayerMenuActionUpNext
} RewindPlayerMenuAction;

@class RewindArtworkView;
@class RewindIconButton;
@class RewindPillButton;
@class RewindLyrics;
@class RewindSeekBar;
@class RewindMarqueeLabel;

@interface RewindPlayerVC : UIViewController <UIAlertViewDelegate, UIActionSheetDelegate> {
    RewindPlayer *_player;
    RewindAPI *_api;
    CAGradientLayer *_background;
    RewindIconButton *_closeButton;
    RewindIconButton *_moreButton;
    RewindArtworkView *_artwork;
    RewindMarqueeLabel *_titleLabel;
    UILabel *_artistLabel;
    UIButton *_artistTap;
    UIScrollView *_actions;
    UIView *_likePill;
    RewindIconButton *_likeButton;
    RewindIconButton *_dislikeButton;
    NSMutableArray *_actionPills;
    RewindSeekBar *_progress;
    UILabel *_elapsedLabel;
    UILabel *_durationLabel;
    RewindIconButton *_shuffleButton;
    RewindIconButton *_previousButton;
    RewindIconButton *_playButton;
    UIActivityIndicatorView *_playSpinner;
    RewindIconButton *_nextButton;
    RewindIconButton *_repeatButton;
    UIView *_tabBar;
    NSMutableArray *_tabButtons;
    UIView *_panel;
    CAGradientLayer *_panelBackground;
    UILabel *_panelTitle;
    RewindIconButton *_panelPlay;
    UIActivityIndicatorView *_panelPlaySpinner;
    UIScrollView *_panelScroll;
    RewindArtworkView *_panelArt;
    UILabel *_panelArtist;
    UIView *_panelUnderline;
    UIView *_panelFade;
    RewindPillButton *_panelShare, *_panelTranslate;
    NSArray *_translatedLines;
    BOOL _showingTranslation, _translating;
    RewindLyrics *_lyrics;
    NSArray *_related;
    RewindTrack *_menuTrack;
    RewindTrack *_displayTrack;
    NSTimer *_progressTimer;
    BOOL _lyricsAttempted;
    BOOL _relatedAttempted;
    BOOL _lyricsLoading;
    BOOL _relatedLoading;
    NSError *_lyricsError;
    NSError *_relatedError;
    NSUInteger _request;
    NSInteger _selectedTab;
    NSInteger _lastLyricIndex;
}

- (id)initWithPlayer:(RewindPlayer *)player;
- (id)initWithPlayer:(RewindPlayer *)player api:(RewindAPI *)api;

@end

void RewindPushAlbum(UIViewController *source,
                   RewindTrack *track,
                   RewindAPI *api,
                   RewindPlayer *player);

#endif
