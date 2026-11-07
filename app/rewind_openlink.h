#ifndef REWIND_OPENLINK_H
#define REWIND_OPENLINK_H

#import <UIKit/UIKit.h>

@class RewindAPI;
@class RewindPlayer;

/* opens what a pasted or tapped youtube link names: the playlist on the given navigation stack, or else the track, which starts playing
   once its title is known; NO when the text holds no youtube link, which a search field then treats as an ordinary query */
BOOL RewindOpenLink(NSString *text, UINavigationController *navigation, RewindPlayer *player, RewindAPI *api);

/* the clipboard text for the paste buttons, trimmed; a web link comes back with its https:// or http:// swapped for rewind://,
   the same form another app opens, and any other text comes back as it is. nil when the clipboard holds no text */
NSString *RewindClipboardLinkText(void);

#endif
