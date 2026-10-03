#ifndef REWIND_DOWNLOAD_H
#define REWIND_DOWNLOAD_H

#import <Foundation/Foundation.h>
@class RewindTrack, RewindAPI;

/* posted on main after a successful download; userInfo contains videoID */
FOUNDATION_EXPORT NSString * const RewindDownloadsDidChangeNotification;

/* only committed, bounded metadata is read; missing audio files are excluded */
NSArray *RewindDownloadedTracks(void);
NSURL *RewindDownloadedURLForTrack(NSString *videoID);
/* completions run on main; duplicate requests and more than two active tasks fail */
void RewindDownloadTrack(RewindTrack *track, RewindAPI *api, void (^completion)(NSError *error));
void RewindStartDownload(NSURL *url, NSString *videoID, void (^completion)(NSError *error));

#endif
