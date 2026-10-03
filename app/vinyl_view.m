#import "vinyl_view.h"

#import <QuartzCore/QuartzCore.h>

#import "rewind_ui.h"

@implementation RewindVinylView

@synthesize scratchDelegate = _scratchDelegate;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentMode = UIViewContentModeRedraw;
    _label = [[RewindArtworkView alloc] initWithFrame:CGRectZero];
    _label.layer.borderWidth = 1.0f;
    _label.layer.borderColor = [UIColor colorWithWhite:0.0f alpha:0.6f].CGColor;
    _label.userInteractionEnabled = NO;
    [self addSubview:_label];
    return self;
}

- (void)dealloc {
    _scratchDelegate = nil;
    [_label release];
    [super dealloc];
}

- (void)setURL:(NSString *)url {
    [_label setURL:url];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat side = MIN(b.size.width, b.size.height);
    CGFloat labelSide = floorf(side * 0.38f);
    _label.frame = CGRectMake(floorf((b.size.width - labelSide) * 0.5f),
                              floorf((b.size.height - labelSide) * 0.5f), labelSide, labelSide);
    [_label setCornerRadius:labelSide * 0.5f];
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect b = self.bounds;
    CGFloat side = MIN(b.size.width, b.size.height);
    CGRect disc = CGRectMake(floorf((b.size.width - side) * 0.5f), floorf((b.size.height - side) * 0.5f),
                             side, side);
    CGFloat radius = side * 0.5f;
    CGPoint center = CGPointMake(CGRectGetMidX(disc), CGRectGetMidY(disc));

    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.06f alpha:1.0f].CGColor);
    CGContextFillEllipseInRect(ctx, disc);

    CGFloat innerRadius = radius * 0.42f, outerRadius = radius * 0.94f;
    NSUInteger grooveCount = 16;
    CGContextSetLineWidth(ctx, 1.0f);
    NSUInteger index;
    for (index = 0; index < grooveCount; ++index) {
        CGFloat t = (CGFloat)index / (CGFloat)(grooveCount - 1);
        CGFloat r = innerRadius + (outerRadius - innerRadius) * t;
        CGFloat shade = (index % 2 == 0) ? 0.14f : 0.09f;
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:shade alpha:1.0f].CGColor);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(center.x - r, center.y - r, r * 2.0f, r * 2.0f));
    }

    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGFloat components[] = { 1.0f, 0.10f, 1.0f, 0.0f };
    CGFloat locations[] = { 0.0f, 1.0f };
    CGGradientRef sheen = CGGradientCreateWithColorComponents(gray, components, locations, 2);
    CGPoint glint = CGPointMake(center.x - radius * 0.35f, center.y - radius * 0.4f);
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, disc);
    CGContextClip(ctx);
    CGContextDrawRadialGradient(ctx, sheen, glint, 0.0f, glint, radius * 0.9f, 0);
    CGContextRestoreGState(ctx);
    CGGradientRelease(sheen);
    CGColorSpaceRelease(gray);

    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.0f alpha:0.6f].CGColor);
    CGContextSetLineWidth(ctx, 1.0f);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(disc, 0.5f, 0.5f));
}

- (CGFloat)shownAngle {
    CALayer *shown = [self.layer presentationLayer];
    NSNumber *angle = [(shown ?: self.layer) valueForKeyPath:@"transform.rotation.z"];
    return angle ? (CGFloat)[angle doubleValue] : _angle;
}

- (void)startSpin {
    [self.layer removeAnimationForKey:@"spin"];
    self.layer.transform = CATransform3DMakeRotation(_angle, 0.0f, 0.0f, 1.0f);
    /* 33 1/3 rpm takes 1.8 s per turn */
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = [NSNumber numberWithDouble:_angle];
    spin.toValue = [NSNumber numberWithDouble:_angle + M_PI * 2.0];
    spin.duration = 1.8;
    spin.repeatCount = HUGE_VALF;
    spin.removedOnCompletion = NO;
    [self.layer addAnimation:spin forKey:@"spin"];
}

/* preserve the displayed angle when pausing */
- (void)stopSpin {
    _angle = [self shownAngle];
    [self.layer removeAnimationForKey:@"spin"];
    self.layer.transform = CATransform3DMakeRotation(_angle, 0.0f, 0.0f, 1.0f);
}

- (void)setPlaying:(BOOL)playing {
    if (_spinning == playing) return;
    _spinning = playing;
    /* scratching owns the rotation until the touch ends */
    if (_scratching) return;
    if (playing) [self startSpin];
    else [self stopSpin];
}

#pragma mark - scratch

/* the rotated square must not intercept corner buttons outside the round disc */
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    CGRect bounds = self.bounds;
    CGFloat radius = MIN(bounds.size.width, bounds.size.height) * 0.5f;
    return hypotf(point.x - CGRectGetMidX(bounds), point.y - CGRectGetMidY(bounds)) <= radius;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    /* use superview coordinates because the disc rotates during the gesture */
    CGPoint point = [touch locationInView:self.superview];
    CGPoint center = self.center;
    if (_scratching || hypotf(point.x - center.x, point.y - center.y) > MIN(self.bounds.size.width, self.bounds.size.height) * 0.5f) {
        [super touchesBegan:touches withEvent:event];
        return;
    }
    _scratching = YES;
    [self stopSpin];
    _touchAngle = atan2f(point.y - center.y, point.x - center.x);
    _touchTime = touch.timestamp;
    [_scratchDelegate vinylScratchBegan];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!_scratching) {
        [super touchesMoved:touches withEvent:event];
        return;
    }
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self.superview];
    CGPoint center = self.center;
    CGFloat angle = atan2f(point.y - center.y, point.x - center.x);
    CGFloat delta = angle - _touchAngle;
    /* the angle wraps at a half turn; the shorter way round is the one the finger took */
    while (delta > M_PI) delta -= (CGFloat)(M_PI * 2.0);
    while (delta < -M_PI) delta += (CGFloat)(M_PI * 2.0);
    NSTimeInterval interval = touch.timestamp - _touchTime;
    _touchAngle = angle;
    _touchTime = touch.timestamp;
    /* bound the angle to one turn to preserve float precision during long scratches */
    _angle = fmodf(_angle + delta, (CGFloat)(M_PI * 2.0));
    self.layer.transform = CATransform3DMakeRotation(_angle, 0.0f, 0.0f, 1.0f);
    [_scratchDelegate vinylScratchedByRadians:delta interval:interval];
}

- (void)finishScratch {
    if (!_scratching) return;
    _scratching = NO;
    [_scratchDelegate vinylScratchEnded];
    if (_spinning) [self startSpin];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!_scratching) {
        [super touchesEnded:touches withEvent:event];
        return;
    }
    [self finishScratch];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!_scratching) {
        [super touchesCancelled:touches withEvent:event];
        return;
    }
    [self finishScratch];
}

@end
