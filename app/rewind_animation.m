#import "rewind_animation.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <dlfcn.h>

#import "rewind_theme.h"

/* a sample every 8 ms or less at the longest motion, so the spring is smooth on a 120 Hz screen too */
#define MOTION_SAMPLES 121

BOOL RewindReduceMotionEnabled(void) {
    BOOL (*enabled)(void) = (BOOL (*)(void))dlsym(RTLD_DEFAULT, "UIAccessibilityIsReduceMotionEnabled");
    return enabled ? enabled() : NO;
}

@interface RewindMotionCompletion : NSObject {
    void (^_completion)(BOOL);
}
- (id)initWithCompletion:(void (^)(BOOL))completion;
@end

@implementation RewindMotionCompletion
- (id)initWithCompletion:(void (^)(BOOL))completion {
    self = [super init];
    if (self) _completion = [completion copy];
    return self;
}
- (void)dealloc {
    [_completion release];
    [super dealloc];
}
- (void)animationDidStop:(CAAnimation *)animation finished:(BOOL)finished {
    (void)animation;
    if (_completion) _completion(finished);
}
@end

void RewindAnimateView(UIView *view, CGAffineTransform transform, CGFloat alpha,
                        rewind_motion_curve curve, void (^completion)(BOOL finished)) {
    RewindAnimateViewAfter(view, transform, alpha, curve, 0, completion);
}

void RewindAnimateViewAfter(UIView *view, CGAffineTransform transform, CGFloat alpha,
                             rewind_motion_curve curve, NSTimeInterval delay, void (^completion)(BOOL finished)) {
    CALayer *layer = view.layer;
    CALayer *visible = [layer animationForKey:@"rewind.motion"] ? [layer presentationLayer] : nil;
    CGAffineTransform from = visible ? CATransform3DGetAffineTransform(visible.transform) : view.transform;
    CGFloat fromAlpha = visible ? visible.opacity : view.alpha;
    [layer removeAnimationForKey:@"rewind.motion"];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    view.transform = transform;
    view.alpha = alpha;
    [CATransaction commit];
    BOOL reduced = RewindReduceMotionEnabled();
    if (!view.window || ![UIView areAnimationsEnabled] || (reduced && !(delay > 0 && alpha < fromAlpha))) {
        if (completion) completion(YES);
        return;
    }
    if (reduced) {
        /* keep delayed notices readable when reduce motion disables their fade */
        CABasicAnimation *hold = [CABasicAnimation animationWithKeyPath:@"opacity"];
        hold.fromValue = hold.toValue = [NSNumber numberWithDouble:fromAlpha];
        hold.duration = delay;
        if (completion) hold.delegate = (id)[[[RewindMotionCompletion alloc] initWithCompletion:completion] autorelease];
        [layer addAnimation:hold forKey:@"rewind.motion"];
        return;
    }
    NSMutableArray *transforms = [NSMutableArray arrayWithCapacity:MOTION_SAMPLES];
    NSMutableArray *opacities = [NSMutableArray arrayWithCapacity:MOTION_SAMPLES];
    for (NSUInteger i = 0; i < MOTION_SAMPLES; ++i) {
        CGFloat progress = (CGFloat)rewind_motion_progress(curve, (double)i / (MOTION_SAMPLES - 1));
        CGAffineTransform value = CGAffineTransformMake(
            from.a + (transform.a - from.a) * progress, from.b + (transform.b - from.b) * progress,
            from.c + (transform.c - from.c) * progress, from.d + (transform.d - from.d) * progress,
            from.tx + (transform.tx - from.tx) * progress, from.ty + (transform.ty - from.ty) * progress);
        [transforms addObject:[NSValue valueWithCATransform3D:CATransform3DMakeAffineTransform(value)]];
        CGFloat opacity = fromAlpha + (alpha - fromAlpha) * MIN(1, MAX(0, progress));
        [opacities addObject:[NSNumber numberWithDouble:opacity]];
    }
    /* sampled springs keep the same motion on ios 5, where CASpringAnimation is absent */
    CAKeyframeAnimation *movement = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    movement.values = transforms;
    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fade.values = opacities;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.duration = rewind_motion_duration(curve);
    movement.duration = fade.duration = group.duration;
    group.animations = [NSArray arrayWithObjects:movement, fade, nil];
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    if (delay > 0) {
        group.beginTime = [layer convertTime:CACurrentMediaTime() fromLayer:nil] + delay;
        group.fillMode = kCAFillModeBackwards;
    }
    if (completion) group.delegate = (id)[[[RewindMotionCompletion alloc] initWithCompletion:completion] autorelease];
    [layer addAnimation:group forKey:@"rewind.motion"];
}

void RewindCacheForMotion(UIView *view) {
    if (RewindReduceMotionEnabled()) return;
    view.layer.rasterizationScale = [UIScreen mainScreen].scale;
    view.layer.shouldRasterize = YES;
}

void RewindUncacheAfterMotion(UIView *view) {
    view.layer.shouldRasterize = NO;
}

#define BOUNCE_PRESS_SECONDS 0.06
#define BOUNCE_RELEASE_SECONDS 0.35
#define BOUNCE_OVERSHOOT 5.0
static NSString *const RewindBounceKey = @"rewind.bounce";

@interface RewindBounceTarget : NSObject
+ (RewindBounceTarget *)shared;
- (void)press:(UIControl *)control;
- (void)lift:(UIControl *)control;
@end

/* the scale the layer shows at this moment, which is where a new bounce starts from */
static CGFloat RewindBounceShownScale(CALayer *layer) {
    CALayer *shown = [layer animationForKey:RewindBounceKey] ? [layer presentationLayer] : nil;
    NSNumber *scale = shown ? [shown valueForKeyPath:@"transform.scale"] : nil;
    return scale ? (CGFloat)scale.doubleValue : 1;
}

static BOOL RewindBounceAnimates(UIView *view) {
    return view.window && [UIView areAnimationsEnabled] && !RewindReduceMotionEnabled();
}

void RewindBounceView(UIView *view, BOOL pressed, CGFloat depth) {
    CALayer *layer = view.layer;
    if (pressed) {
        if (!RewindBounceAnimates(view)) return;
        CABasicAnimation *shrink = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        shrink.fromValue = [NSNumber numberWithDouble:RewindBounceShownScale(layer)];
        shrink.toValue = [NSNumber numberWithDouble:1 - depth];
        shrink.duration = BOUNCE_PRESS_SECONDS;
        shrink.fillMode = kCAFillModeForwards;
        shrink.removedOnCompletion = NO;
        /* ease in out with the control points 0.25, 0.1, 0.25, 1 */
        shrink.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.25f:0.1f:0.25f:1];
        [layer addAnimation:shrink forKey:RewindBounceKey];
        return;
    }
    if (![layer animationForKey:RewindBounceKey]) return;
    CGFloat from = RewindBounceShownScale(layer);
    if (!RewindBounceAnimates(view)) {
        [layer removeAnimationForKey:RewindBounceKey];
        return;
    }
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:MOTION_SAMPLES];
    for (NSUInteger i = 0; i < MOTION_SAMPLES; ++i) {
        double t = (double)i / (MOTION_SAMPLES - 1) - 1;
        double overshoot = t * t * ((BOUNCE_OVERSHOOT + 1) * t + BOUNCE_OVERSHOOT) + 1;
        [values addObject:[NSNumber numberWithDouble:from + (1 - from) * overshoot]];
    }
    CAKeyframeAnimation *spring = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    spring.values = values;
    spring.duration = BOUNCE_RELEASE_SECONDS;
    spring.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [layer addAnimation:spring forKey:RewindBounceKey];
}

@implementation RewindBounceTarget

+ (RewindBounceTarget *)shared {
    static RewindBounceTarget *target;
    if (!target) target = [[RewindBounceTarget alloc] init];
    return target;
}

- (void)press:(UIControl *)control {
    RewindBounceView(control, YES, (CGFloat)[objc_getAssociatedObject(control, &RewindBounceKey) doubleValue]);
}

- (void)lift:(UIControl *)control {
    RewindBounceView(control, NO, 0);
}

@end

void RewindAttachBounce(UIControl *control, CGFloat depth) {
    RewindBounceTarget *target = [RewindBounceTarget shared];
    objc_setAssociatedObject(control, &RewindBounceKey, [NSNumber numberWithDouble:depth], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [control addTarget:target action:@selector(press:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [control addTarget:target action:@selector(lift:)
      forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
}

rewind_motion_curve RewindPopupCurve(BOOL entering) {
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic) return entering ? REWIND_MOTION_POPUP_CLASSIC_ENTER : REWIND_MOTION_POPUP_CLASSIC_EXIT;
    return entering ? REWIND_MOTION_POPUP_MODERN_ENTER : REWIND_MOTION_POPUP_MODERN_EXIT;
}

CGFloat RewindPopupScale(void) {
    return RewindCurrentTheme() == RewindThemeSkeuomorphic ? 0.95f : 0.9f;
}

/* a picture may hold this many pixels, which keeps a full screen tablet picture from asking for 30 MB */
#define SNAPSHOT_PIXELS_MAX 4000000.0
/* how far a screen travels as it comes in or goes away, in points */
#define SWAP_DISTANCE 36.0f

UIImageView *RewindSnapshotOfView(UIView *view) {
    CGSize size = view.bounds.size;
    if (size.width < 1 || size.height < 1) return nil;
    CGFloat scale = [UIScreen mainScreen].scale;
    CGFloat limit = (CGFloat)sqrt(SNAPSHOT_PIXELS_MAX / ((double)size.width * (double)size.height));
    if (scale > limit) scale = limit;
    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) {
        UIGraphicsEndImageContext();
        return nil;
    }
    [view.layer renderInContext:context];
    UIImage *picture = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!picture) return nil;
    UIImageView *shot = [[[UIImageView alloc] initWithImage:picture] autorelease];
    shot.frame = view.frame;
    shot.userInteractionEnabled = NO;
    return shot;
}

void RewindSwapViews(UIView *leaving, UIView *entering, int direction) {
    if (!leaving) return;
    if (!entering.window || ![UIView areAnimationsEnabled] || RewindReduceMotionEnabled()) {
        [leaving removeFromSuperview];
        return;
    }
    CGFloat side = direction < 0 ? -1.0f : 1.0f;
    entering.alpha = 0.0f;
    entering.transform = CGAffineTransformMakeTranslation(side * SWAP_DISTANCE, 0.0f);
    RewindAnimateView(entering, CGAffineTransformIdentity, 1.0f, REWIND_MOTION_ENTER, nil);
    RewindAnimateView(leaving, CGAffineTransformMakeTranslation(-side * SWAP_DISTANCE, 0.0f), 0.0f, REWIND_MOTION_EXIT, ^(BOOL finished) {
        (void)finished;
        [leaving removeFromSuperview];
    });
}
