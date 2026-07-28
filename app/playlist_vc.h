#ifndef TUNETUBE_PLAYLIST_VC_H
#define TUNETUBE_PLAYLIST_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class TuneTubeAPI;
@class TuneTubePlayer;
@class TuneTubeTrack;

NSArray *TuneTubePlaylistNames(void);
void TuneTubeCreatePlaylist(NSString *name);
void TuneTubeAddTrackToPlaylist(TuneTubeTrack *track, NSString *name);
NSArray *TuneTubePlaylistsContainingTrack(TuneTubeTrack *track);
void TuneTubeRemoveTrackFromPlaylist(TuneTubeTrack *track, NSString *name);
NSArray *TuneTubeTracksForPlaylist(NSString *name);

@interface TunePlaylistsVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate> {
    TuneTubePlayer *_player;
    TuneTubeAPI *_api;
    NSMutableArray *_names;
    UITableView *_table;
    CAGradientLayer *_backgroundGradient;
}

- (id)initWithPlayer:(TuneTubePlayer *)player api:(TuneTubeAPI *)api;

@end

@interface TunePlaylistVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    NSString *_playlistName;
    TuneTubePlayer *_player;
    TuneTubeAPI *_api;
    NSMutableArray *_tracks;
    UITableView *_table;
    CAGradientLayer *_backgroundGradient;
}

- (id)initWithName:(NSString *)name player:(TuneTubePlayer *)player api:(TuneTubeAPI *)api;

@end

#endif
