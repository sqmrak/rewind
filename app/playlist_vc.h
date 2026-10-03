#ifndef REWIND_PLAYLIST_VC_H
#define REWIND_PLAYLIST_VC_H

#include "rewind_layout.h"

#ifdef __OBJC__
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class RewindAPI;
@class RewindPlayer;
@class RewindTrack;

NSArray *RewindPlaylistNames(void);
void RewindCreatePlaylist(NSString *name);
/* a nil track creates an empty list; online failures never create a local replacement */
void RewindCreatePlaylistWithTrack(NSString *name, RewindTrack *track,
                                   void (^completion)(NSError *error));
void RewindAddTrackToPlaylist(RewindTrack *track, NSString *name);
NSArray *RewindPlaylistsContainingTrack(RewindTrack *track);
void RewindRemoveTrackFromPlaylist(RewindTrack *track, NSString *name);
NSArray *RewindTracksForPlaylist(NSString *name);

/* picker rows: local playlists first, then editable youtube playlists when signed in */
NSArray *RewindPlaylistPickerTitles(void);
/* adds to whichever playlist the picker title names; the completion reports youtube failures */
void RewindAddTrackToPickedPlaylist(RewindTrack *track, NSString *title,
                                    void (^completion)(NSError *error));

@interface RewindPlaylistsVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate> {
    RewindPlayer *_player;
    RewindAPI *_api;
    NSMutableArray *_names;
    NSArray *_remote;
    NSUInteger _remoteRequest;
    NSString *_deleteName;
    UITableView *_table;
    UILabel *_status;
    CAGradientLayer *_backgroundGradient;
}

- (id)initWithPlayer:(RewindPlayer *)player api:(RewindAPI *)api;

@end

@class RewindArtworkView;
@class RewindIconButton;

@interface RewindPlaylistVC : UIViewController <UIScrollViewDelegate, UIActionSheetDelegate> {
    NSString *_playlistName;
    RewindTrack *_remotePlaylist;
    NSUInteger _request;
    RewindPlayer *_player;
    RewindAPI *_api;
    NSMutableArray *_tracks;
    CGFloat _laidWidth;
    CGFloat _headerHeight;

    UIView *_headerView;
    RewindArtworkView *_headerArt;
    CAGradientLayer *_headerScrimTop;
    CAGradientLayer *_headerScrimBottom;
    UIView *_backBacking;
    RewindIconButton *_backButton;
    RewindIconButton *_playButton;
    UILabel *_nameLabel;
    UILabel *_subLabel;

    UIScrollView *_content;
    UILabel *_status;
}

- (id)initWithName:(NSString *)name player:(RewindPlayer *)player api:(RewindAPI *)api;
/* a youtube playlist, album or liked music; tracks load from the network */
- (id)initWithRemotePlaylist:(RewindTrack *)playlist player:(RewindPlayer *)player api:(RewindAPI *)api;

@end

#endif /* __OBJC__ */

#endif
