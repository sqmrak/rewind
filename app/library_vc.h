#ifndef REWIND_LIBRARY_VC_H
#define REWIND_LIBRARY_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class RewindAPI;
@class RewindPlayer;
@class RewindTrack;

NSArray *RewindLibraryTracks(void);
NSArray *RewindRecentTracks(void);
void RewindRecordTrack(RewindTrack *track);
BOOL RewindTrackIsSaved(RewindTrack *track);
void RewindSaveTrack(RewindTrack *track);
void RewindRemoveTrack(RewindTrack *track);

typedef enum {
    RewindLibraryModeAll = 0,
    RewindLibraryModeLiked,
    RewindLibraryModeRecent,
    RewindLibraryModeFavorites,
    RewindLibraryModeDownloads
} RewindLibraryMode;

@interface RewindLibraryVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    RewindPlayer *_player;
    RewindAPI *_api;
    NSMutableArray *_tracks;
    NSArray *_likedTracks;
    NSUInteger _likesRequest;
    UITableView *_table;
    UIView *_listHeader;
    UILabel *_countLabel;
    UIButton *_playAllButton;
    UILabel *_emptyLabel;
    UILabel *_emptyDescription;
    UIImageView *_emptyIcon;
    UIButton *_findButton;
    CAGradientLayer *_backgroundGradient;
    RewindLibraryMode _mode;
}

- (id)initWithPlayer:(RewindPlayer *)player api:(RewindAPI *)api;
- (id)initWithPlayer:(RewindPlayer *)player api:(RewindAPI *)api mode:(RewindLibraryMode)mode;

@end

#endif
