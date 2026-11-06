#import <UIKit/UIKit.h>

#include "rewind_emoji.h"

/* the pictures of the emoji pack, when the build carries one (emoji.pack in the app bundle, see README). Without it every call answers that there is no picture, and the text is
   left to the system's own emoji font */

/* whether the pack has a picture for the emoji, which the layout needs to reserve its room */
BOOL RewindEmojiHasPicture(size_t entry);

/* the decoded picture when it is in memory; otherwise nil, and the decode starts */
UIImage *RewindEmojiImage(size_t entry);

/* how many times a picture was asked for and not yet in memory; a view reads it before and after drawing, and when it changed calls RewindEmojiRedrawWhenLoaded */
NSUInteger RewindEmojiMissCount(void);

/* sets the view to redraw once the pictures that are being decoded are in memory; asking twice before the redraw is the same as once */
void RewindEmojiRedrawWhenLoaded(UIView *view);
