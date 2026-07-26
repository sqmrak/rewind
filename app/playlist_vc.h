#ifndef TUNETUBE_PLAYLIST_VC_H
#define TUNETUBE_PLAYLIST_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class YTMAPI;
@class YTMPlayer;
@class YTMTrack;

NSArray *TuneTubePlaylistNames(void);
void TuneTubeCreatePlaylist(NSString *name);
void TuneTubeAddTrackToPlaylist(YTMTrack *track, NSString *name);
NSArray *TuneTubeTracksForPlaylist(NSString *name);

@interface TunePlaylistsVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate> {
    YTMPlayer *_player;
    YTMAPI *_api;
    NSMutableArray *_names;
    UITableView *_table;
    CAGradientLayer *_backgroundGradient;
}

- (id)initWithPlayer:(YTMPlayer *)player api:(YTMAPI *)api;

@end

@interface TunePlaylistVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    NSString *_playlistName;
    YTMPlayer *_player;
    YTMAPI *_api;
    NSMutableArray *_tracks;
    UITableView *_table;
    CAGradientLayer *_backgroundGradient;
}

- (id)initWithName:(NSString *)name player:(YTMPlayer *)player api:(YTMAPI *)api;

@end

#endif
