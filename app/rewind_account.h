#ifndef REWIND_ACCOUNT_H
#define REWIND_ACCOUNT_H

#import <Foundation/Foundation.h>

#import "rewind_api.h"

/* posted after sign in, sign out and profile updates */
FOUNDATION_EXPORT NSString * const RewindAccountDidChangeNotification;
/* posted when the liked set or the playlist list is reloaded or edited */
FOUNDATION_EXPORT NSString * const RewindAccountLibraryDidChangeNotification;

typedef enum {
    RewindDevicePollPending = 0,
    RewindDevicePollSlowDown,
    RewindDevicePollGranted,
    RewindDevicePollDenied,
    RewindDevicePollExpired,
    RewindDevicePollFailed
} RewindDevicePollStatus;

@interface RewindDeviceCode : NSObject {
    NSString *_clientID;
    NSString *_clientSecret;
    NSString *_userCode;
    NSString *_verificationURL;
    NSString *_deviceCode;
    BOOL _cancelled;
    NSTimeInterval _interval;
    NSDate *_expiresAt;
}
@property(nonatomic, readonly) NSString *clientID;
@property(nonatomic, readonly) NSString *clientSecret;
@property(nonatomic, readonly) NSString *userCode;
@property(nonatomic, readonly) NSString *verificationURL;
@property(nonatomic, readonly) NSString *deviceCode;
@property(nonatomic, readonly) NSTimeInterval interval;
@property(nonatomic, readonly) NSDate *expiresAt;
@property(nonatomic, assign) BOOL cancelled;
@end

typedef void (^RewindDeviceCodeCompletion)(RewindDeviceCode *code, NSError *error);
typedef void (^RewindDevicePollCompletion)(RewindDevicePollStatus status, NSError *error);
typedef void (^RewindAccountListCompletion)(NSArray *items, NSError *error);
typedef void (^RewindAccountDoneCompletion)(NSError *error);

BOOL RewindAccountIsSignedIn(void);
NSString *RewindAccountName(void);
NSString *RewindAccountEmail(void);
NSString *RewindAccountPhotoURL(void);

/* configuration applies to the next sign in; active tokens keep their original client */
NSString *RewindAccountOAuthClientID(void);
BOOL RewindAccountSetOAuthClient(NSString *clientID, NSString *clientSecret, NSError **error);

void RewindAccountRequestDeviceCode(RewindDeviceCodeCompletion completion);
void RewindAccountPollDeviceCode(RewindDeviceCode *code, RewindDevicePollCompletion completion);
void RewindAccountSignOut(void);
void RewindAccountRefreshProfile(RewindAccountDoneCompletion completion);

/* items are RewindShelf; called once with the first page and again when the second page lands */
void RewindAccountLoadHome(RewindAccountListCompletion completion);
/* items are RewindTrack with playlistID set */
/* creates a private youtube playlist, returns one RewindTrack only after server confirmation */
void RewindAccountCreatePlaylist(NSString *name, RewindAccountListCompletion completion);
void RewindAccountAddPlaylistTrack(NSString *playlistID, RewindTrack *track,
                                   RewindAccountDoneCompletion completion);
void RewindAccountLoadPlaylists(RewindAccountListCompletion completion);
void RewindAccountLoadPlaylistTracks(NSString *playlistID, RewindAccountListCompletion completion);
/* the same list, with progress called with the tracks so far after each page but the last */
void RewindAccountLoadPlaylistTracksProgressive(NSString *playlistID, RewindAccountListCompletion progress,
                                                RewindAccountListCompletion completion);
/* personal radio seeded by a track, or the mix a home tile points at */
void RewindAccountLoadMix(RewindTrack *seed, RewindAccountListCompletion completion);

/* liked music, newest first; answers from a five minute cache unless forced.
   RewindAccountTrackIsLiked reads the same set */
void RewindAccountLoadLikes(BOOL force, RewindAccountListCompletion completion);
NSUInteger RewindAccountCachedLikedTrackCount(void);
BOOL RewindAccountTrackIsLiked(RewindTrack *track);
void RewindAccountSetLiked(RewindTrack *track, BOOL liked, RewindAccountDoneCompletion completion);
/* dislikes are remembered for this session only; youtube offers no list of them */
BOOL RewindAccountTrackIsDisliked(RewindTrack *track);
void RewindAccountSetDisliked(RewindTrack *track, BOOL disliked, RewindAccountDoneCompletion completion);

/* youtube keeps no local subscription list; the artist page itself reports the
   current state each time it loads */
void RewindAccountSetSubscribed(NSString *artistID, BOOL subscribed, RewindAccountDoneCompletion completion);

/* the last playlist list loaded, for pickers that cannot wait on the network */
NSArray *RewindAccountCachedPlaylists(void);
BOOL RewindAccountPlaylistIsEditable(NSString *playlistID);
void RewindAccountEditPlaylist(NSString *playlistID, RewindTrack *track, BOOL add,
                               RewindAccountDoneCompletion completion);

#endif /* REWIND_ACCOUNT_H */
