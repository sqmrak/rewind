#ifndef TUNETUBE_LIBRARY_VC_H
#define TUNETUBE_LIBRARY_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class TuneTubeAPI;
@class TuneTubePlayer;
@class TuneTubeTrack;

NSArray *TuneTubeLibraryTracks(void);
NSArray *TuneTubeRecentTracks(void);
void TuneTubeRecordTrack(TuneTubeTrack *track);
BOOL TuneTubeTrackIsSaved(TuneTubeTrack *track);
void TuneTubeSaveTrack(TuneTubeTrack *track);
void TuneTubeRemoveTrack(TuneTubeTrack *track);

@interface TuneLibraryVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    TuneTubePlayer *_player;
    TuneTubeAPI *_api;
    NSMutableArray *_tracks;
    UITableView *_table;
    UILabel *_emptyLabel;
    UILabel *_emptyDescription;
    UIImageView *_emptyIcon;
    UIButton *_findButton;
    CAGradientLayer *_backgroundGradient;
}

- (id)initWithPlayer:(TuneTubePlayer *)player api:(TuneTubeAPI *)api;

@end

#endif
