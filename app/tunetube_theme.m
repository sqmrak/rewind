#import "tunetube_theme.h"

#import "tunetube_config.h"

NSString * const TuneTubeThemeDidChangeNotification = @"TuneTubeThemeDidChangeNotification";
NSString * const TuneTubeFocusSearchNotification = @"TuneTubeFocusSearchNotification";

static UIColor *TuneThemeColor(CGFloat darkRed, CGFloat darkGreen, CGFloat darkBlue) {
    return [UIColor colorWithRed:darkRed green:darkGreen blue:darkBlue alpha:1.0f];
}

static UIImage *TuneTubeNavigationBackgroundImage(void) {
    CGSize size = CGSizeMake(1.0f, 44.0f);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0.0f);
    CGContextRef context = UIGraphicsGetCurrentContext();
    NSArray *colors = [NSArray arrayWithObjects:
                       (id)TuneThemeNavigationTop().CGColor,
                       (id)TuneThemeNavigationMiddle().CGColor,
                       (id)TuneThemeNavigationBottom().CGColor, nil];
    CGFloat locations[] = {0.0f, 0.48f, 1.0f};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(colorSpace,
                                                        (CFArrayRef)colors,
                                                        locations);
    CGContextDrawLinearGradient(context, gradient,
                                CGPointMake(0.0f, 0.0f),
                                CGPointMake(0.0f, size.height),
                                0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIColor *TuneThemeNavigationButtonColor(void) {
    return [UIColor whiteColor];
}

static UIImage *TuneTubeNavigationButtonImage(BOOL highlighted) {
    CGSize size = CGSizeMake(76.0f, 32.0f);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0f);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGRect rect = CGRectInset(CGRectMake(0.5f, 0.5f, size.width - 1.0f,
                                         size.height - 1.0f), 0.0f, 0.0f);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:7.0f];
    CGContextSaveGState(context);
    [path addClip];

    /* keep buttons brighter than the bar so they read as raised controls */
    UIColor *top = highlighted ? TuneThemeNavigationBottom()
                               : TuneThemeNavigationButtonTop();
    UIColor *middle = highlighted ? TuneThemeNavigationBottom()
                                  : TuneThemeNavigationButtonMiddle();
    UIColor *bottom = TuneThemeNavigationBottom();
    NSArray *colors = [NSArray arrayWithObjects:
                       (id)top.CGColor, (id)middle.CGColor, (id)bottom.CGColor, nil];
    CGFloat locations[] = {0.0f, 0.48f, 1.0f};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(colorSpace,
                                                        (CFArrayRef)colors,
                                                        locations);
    CGContextDrawLinearGradient(context, gradient,
                                CGPointMake(0.0f, 0.0f),
                                CGPointMake(0.0f, size.height), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);
    CGContextRestoreGState(context);

    [[TuneThemeNavigationBorder() colorWithAlphaComponent:0.95f] setStroke];
    path.lineWidth = 1.0f;
    [path stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(8.0f, 12.0f, 8.0f, 12.0f)];
}

void TuneTubeStyleNavigationBar(UINavigationBar *bar) {
    if (!bar) return;
    bar.barStyle = UIBarStyleBlack;
    bar.translucent = NO;
    UIColor *buttonColor = TuneThemeNavigationButtonColor();
    bar.tintColor = buttonColor;
    SEL barTintSelector = NSSelectorFromString(@"setBarTintColor:");
    if ([bar respondsToSelector:barTintSelector])
        [bar performSelector:barTintSelector withObject:TuneThemeNavigationBottom()];
    UIImage *background = TuneTubeNavigationBackgroundImage();
    [bar setBackgroundImage:background forBarMetrics:UIBarMetricsDefault];
    if ([bar respondsToSelector:@selector(setBackgroundImage:forBarMetrics:)])
        [bar setBackgroundImage:background forBarMetrics:UIBarMetricsLandscapePhone];
    bar.titleTextAttributes = [NSDictionary dictionaryWithObject:[UIColor whiteColor]
                                                              forKey:UITextAttributeTextColor];
    NSDictionary *buttonTitleAttributes =
        [NSDictionary dictionaryWithObject:[UIColor whiteColor]
                                    forKey:UITextAttributeTextColor];
    for (UINavigationItem *item in bar.items) {
        NSArray *buttons = [NSArray arrayWithObjects:
                            item.leftBarButtonItem ?: [NSNull null],
                            item.rightBarButtonItem ?: [NSNull null], nil];
        for (id object in buttons) {
            if (![object isKindOfClass:[UIBarButtonItem class]]) continue;
            UIBarButtonItem *button = (UIBarButtonItem *)object;
            button.tintColor = buttonColor;
            [button setTitleTextAttributes:buttonTitleAttributes
                                  forState:UIControlStateNormal];
            [button setTitleTextAttributes:buttonTitleAttributes
                                  forState:UIControlStateHighlighted];
            if ([button respondsToSelector:@selector(setBackgroundImage:forState:barMetrics:)]) {
                UIImage *normal = TuneTubeNavigationButtonImage(NO);
                UIImage *highlighted = TuneTubeNavigationButtonImage(YES);
                [button setBackgroundImage:normal
                                   forState:UIControlStateNormal
                                 barMetrics:UIBarMetricsDefault];
                [button setBackgroundImage:highlighted
                                   forState:UIControlStateHighlighted
                                 barMetrics:UIBarMetricsDefault];
                [button setBackgroundImage:normal
                                   forState:UIControlStateNormal
                                 barMetrics:UIBarMetricsLandscapePhone];
                [button setBackgroundImage:highlighted
                                   forState:UIControlStateHighlighted
                                 barMetrics:UIBarMetricsLandscapePhone];
            }
        }
    }
}

UIBarButtonItem *TuneTubeBarButtonItem(NSString *title, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    UIFont *font = [UIFont boldSystemFontOfSize:12.0f];
    CGSize textSize = [title sizeWithFont:font];
    CGFloat width = MAX(48.0f, textSize.width + 24.0f);
    button.frame = CGRectMake(0.0f, 0.0f, width, 32.0f);
    button.titleLabel.font = font;
    button.adjustsImageWhenHighlighted = NO;
    button.showsTouchWhenHighlighted = NO;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
    [button setBackgroundImage:TuneTubeNavigationButtonImage(NO)
                       forState:UIControlStateNormal];
    [button setBackgroundImage:TuneTubeNavigationButtonImage(YES)
                       forState:UIControlStateHighlighted];
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return [[[UIBarButtonItem alloc] initWithCustomView:button] autorelease];
}

UIColor *TuneThemeBackgroundTop(void) {
    return TuneThemeNavigationTop();
}

UIColor *TuneThemeBackgroundBottom(void) {
    return TuneThemeNavigationBottom();
}

UIColor *TuneThemePlayerBackgroundTop(void) {
    return TuneThemeColor(0.55f, 0.22f, 0.24f);
}

UIColor *TuneThemePlayerBackgroundBottom(void) {
    return TuneThemeColor(0.40f, 0.05f, 0.07f);
}

UIColor *TuneThemeSurface(void) {
    return TuneThemeNavigationBottom();
}

UIColor *TuneThemeSurfaceTop(void) {
    return TuneThemeNavigationTop();
}

UIColor *TuneThemeSurfaceBottom(void) {
    return TuneThemeNavigationBottom();
}

UIColor *TuneThemeHeader(void) {
    return TuneThemeNavigationBottom();
}

UIColor *TuneThemeHeaderText(void) {
    return TuneThemeColor(1.00f, 0.95f, 0.93f);
}

UIColor *TuneThemeNavigationTop(void) {
    return TuneThemeColor(0.62f, 0.30f, 0.31f);
}

UIColor *TuneThemeNavigationMiddle(void) {
    return TuneThemeColor(0.50f, 0.16f, 0.18f);
}

UIColor *TuneThemeNavigationBottom(void) {
    return TuneThemeColor(0.46f, 0.08f, 0.10f);
}

UIColor *TuneThemeNavigationButtonTop(void) {
    return TuneThemeColor(0.72f, 0.39f, 0.42f);
}

UIColor *TuneThemeNavigationButtonMiddle(void) {
    return TuneThemeColor(0.60f, 0.22f, 0.25f);
}

UIColor *TuneThemeNavigationBorder(void) {
    return TuneThemeColor(0.58f, 0.20f, 0.22f);
}

UIColor *TuneThemeRaisedTop(void) {
    return TuneThemeNavigationTop();
}

UIColor *TuneThemeRaisedBottom(void) {
    return TuneThemeNavigationBottom();
}

UIColor *TuneThemeRaisedBorder(void) {
    return TuneThemeColor(0.75f, 0.28f, 0.31f);
}

UIColor *TuneThemeRaisedText(void) {
    return TuneThemeColor(0.99f, 0.90f, 0.88f);
}

UIColor *TuneThemeAccent(void) {
    return TuneThemeNavigationTop();
}

UIColor *TuneThemePrimaryText(void) {
    return TuneThemeColor(1.00f, 0.95f, 0.93f);
}

UIColor *TuneThemeSecondaryText(void) {
    return TuneThemeColor(0.93f, 0.78f, 0.77f);
}

UIColor *TuneThemeMutedText(void) {
    return TuneThemeColor(0.82f, 0.62f, 0.62f);
}

UIColor *TuneThemeBorder(void) {
    return TuneThemeNavigationBorder();
}

UIColor *TuneThemeSearchBackground(void) {
    return TuneThemeNavigationBottom();
}

UIColor *TuneThemeSliderMinimum(void) {
    return TuneThemeNavigationTop();
}

UIColor *TuneThemeSliderMaximum(void) {
    return TuneThemeNavigationBottom();
}

UIColor *TuneThemeSliderThumb(void) {
    return TuneThemeColor(1.00f, 0.96f, 0.94f);
}
