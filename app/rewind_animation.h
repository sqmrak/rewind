#import <UIKit/UIKit.h>

#include "rewind_motion.h"

/* true when the person asked the system for less motion; the entry is looked up at run time, since ios 5 to 7 have no such setting */
BOOL RewindReduceMotionEnabled(void);

/* moves a view to a transform and an alpha along a curve of rewind_motion. it retargets from the layer as it is drawn, so a leave that begins during an entry never jumps; the
   completion runs at once when the view is off screen, animations are off or motion is reduced */
void RewindAnimateView(UIView *view, CGAffineTransform transform, CGFloat alpha, rewind_motion_curve curve, void (^completion)(BOOL finished));
void RewindAnimateViewAfter(UIView *view, CGAffineTransform transform, CGFloat alpha, rewind_motion_curve curve, NSTimeInterval delay, void (^completion)(BOOL finished));

/* the view is already in its final state; this plays the way in from a transform and an alpha without touching it, and a later call replaces a run that has not ended. The
   curve follows the theme like every other: the spring of a spring request is the expressive one in the material theme */
void RewindAnimateEnter(UIView *view, CGAffineTransform from, CGFloat fromAlpha, rewind_motion_curve curve);
/* the pop of a control that turns on or changes its glyph: it swells from a fraction of its size and settles past its size and back. only the material theme moves; the
   skeuomorphic theme keeps its plain state change */
void RewindPopView(UIView *view, CGFloat from);

/* a card with rounded corners that clip its rows, or with a shadow, is drawn off screen again on every frame it moves, and an old gpu cannot keep up. drawn once into a bitmap it
   moves and fades as a picture; the bitmap is dropped when the move ends, since a card that changes inside a cache is drawn twice */
void RewindCacheForMotion(UIView *view);
void RewindUncacheAfterMotion(UIView *view);

/* the press of a button: it shrinks by depth (0.05 is five percent) within 60 ms while a finger is on it and springs back past its size when the finger leaves */
void RewindAttachBounce(UIControl *control, CGFloat depth);
/* the same for a control that already follows its own highlight, such as a button whose setHighlighted: runs it: pressed shrinks it by depth, and the other call springs it back */
void RewindBounceView(UIView *view, BOOL pressed, CGFloat depth);

/* the curves a popup, toast or sheet comes and goes on, which follow the theme: the emphasized curves of material 3 in the material theme and the plain ease out and ease in of
   the old system in the skeuomorphic one */
rewind_motion_curve RewindPopupCurve(BOOL entering);
/* the size a popup that scales in starts from and leaves to */
CGFloat RewindPopupScale(void);

/* the picture of a view as it is drawn now, in an image view at the view's frame, or nil when the view has no size or the picture would pass four million pixels (it is drawn
   smaller then, and the image view stretches it) */
UIImageView *RewindSnapshotOfView(UIView *view);

/* a screen swap: leaving is the picture of what was on the screen, laid over entering in the host, which is already in its final state. The picture slips away against the side the
   new screen comes from and fades, and the new screen slips in and fades up, on the curves of rewind_motion; direction is 1 when the new screen is to the right of the old one,
   -1 when it is to the left. The picture is taken out of the host when it is done, and nothing is done when motion is reduced */
void RewindSwapViews(UIView *leaving, UIView *entering, int direction);
