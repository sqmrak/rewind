#ifndef REWIND_MAIN_VC_H
#define REWIND_MAIN_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class RewindAPI;
@class RewindPlayer;
@class RewindTrack;
@class RewindShelf;
@class RewindChipBar;
@class RewindArtworkView;
@class RewindIconButton;
@class RewindMarqueeLabel;

@interface MainVC : UIViewController <UIScrollViewDelegate, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, UIAlertViewDelegate> {
    RewindAPI *_api;
    RewindPlayer *_player;
    UIView *_header;
    UILabel *_brand;
    RewindIconButton *_searchButton;
    RewindIconButton *_accountButton;
    UIImageView *_accountAvatar;
    RewindChipBar *_chips;
    CALayer *_ambientGradient;
    CGFloat _ambientHueA, _ambientHueB, _ambientWidth, _ambientHeight;
    UIScrollView *_content;
    UIView *_bottom;
    UIView *_mini;
    RewindArtworkView *_miniArt;
    RewindMarqueeLabel *_miniTitle;
    UILabel *_miniArtist;
    RewindIconButton *_miniPlay;
    UIActivityIndicatorView *_miniSpinner;
    UIView *_miniProgress;
    NSMutableArray *_tabs;
    NSArray *_shelves;
    NSArray *_chipLinks;
    NSArray *_exploreShelves;
    RewindShelf *_personalAlbums;
    NSArray *_libraryTracks;
    RewindTrack *_actionTrack;
    NSUInteger _homeRequest;
    NSUInteger _exploreRequest;
    NSUInteger _searchRequest;
    NSInteger _selectedTab;
    CGFloat _laidWidth;
    NSUInteger _visibleShelfCount;
    NSArray *_pendingShelves;
    NSUInteger _builtShelfCount;
    CGFloat _contentBottom;
    UIView *_searchPanel;
    UITextField *_searchField;
    UITableView *_searchTable;
    NSArray *_searchResults;
    NSArray *_suggestions;
    BOOL _showingResults;
    BOOL _personalHome;
    UILabel *_searchHint;
}
/* the running player, kept when the interface is rebuilt so the music does not stop */
@property(nonatomic, readonly) RewindPlayer *player;
- (void)adoptPlayer:(RewindPlayer *)player;
@end

/* dims the screen under a spinner and a message, applies the change and rebuilds every screen, so a new
   language or theme shows everywhere without restarting the app; messageKey is read after the change */
void RewindReloadInterface(NSString *messageKey, void (^change)(void));

#endif /* REWIND_MAIN_VC_H */
