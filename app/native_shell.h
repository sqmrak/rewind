#ifndef REWIND_NATIVE_SHELL_H
#define REWIND_NATIVE_SHELL_H

#import <UIKit/UIKit.h>

@class RewindAPI;
@class RewindPlayer;

/* the system theme: a tab bar, navigation stacks and tables made of stock uikit controls, the way ios 5
   draws them; it shares the api, the player and the detail screens with the other themes */
UIViewController *RewindNativeRootController(RewindPlayer *player, RewindAPI *api);

#endif /* REWIND_NATIVE_SHELL_H */
