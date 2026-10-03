#import "rewind_theme.h"
#import "rewind_l10n.h"
#import "rewind_chrome.h"
#import <QuartzCore/QuartzCore.h>

NSString * const RewindThemeDidChangeNotification = @"RewindThemeDidChangeNotification";
NSString * const RewindFocusSearchNotification = @"RewindFocusSearchNotification";
static NSString * const RewindThemeDefaultsKey = @"RewindTheme";

RewindTheme RewindCurrentTheme(void) {
    /* 1 was the old hatched classic theme and 2 an early name of this one; both read as the skeuomorphic theme */
    return [[NSUserDefaults standardUserDefaults] integerForKey:RewindThemeDefaultsKey] == RewindThemeMaterialDesign3
        ? RewindThemeMaterialDesign3 : RewindThemeSkeuomorphic;
}

void RewindSetTheme(RewindTheme theme) {
    if (theme != RewindThemeSkeuomorphic && theme != RewindThemeMaterialDesign3) return;
    if (theme == RewindCurrentTheme()) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:theme forKey:RewindThemeDefaultsKey];
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:RewindThemeDidChangeNotification object:nil];
}

static UIColor *RewindHex(unsigned rgb, CGFloat alpha) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0f
                           green:((rgb >> 8) & 0xFF) / 255.0f
                            blue:(rgb & 0xFF) / 255.0f
                           alpha:alpha];
}

/* one value per theme: material, skeuomorphic */
static unsigned RewindPick(unsigned material, unsigned skeuomorphic) {
    return RewindCurrentTheme() == RewindThemeSkeuomorphic ? skeuomorphic : material;
}

UIColor *RewindColorBackground(void) { return RewindHex(RewindPick(0x000000, 0x161616), 1.0f); }
UIColor *RewindColorCanvas(void) { return RewindColorBackground(); }
UIColor *RewindColorSurface(void) { return RewindHex(RewindPick(0x1a1a1a, 0x222222), 1.0f); }
UIColor *RewindColorSurfaceHigh(void) { return RewindHex(RewindPick(0x272727, 0x303030), 1.0f); }
UIColor *RewindColorOverlay(void) {
    return RewindCurrentTheme() == RewindThemeSkeuomorphic ? [UIColor colorWithWhite:1.0f alpha:0.08f]
                                                           : [UIColor colorWithWhite:1.0f alpha:0.10f];
}
UIColor *RewindColorDivider(void) { return RewindHex(RewindPick(0x333333, 0x3a3a3a), 1.0f); }
UIColor *RewindColorText(void) { return RewindHex(RewindPick(0xffffff, 0xffffff), 1.0f); }
UIColor *RewindColorTextSecondary(void) { return RewindHex(RewindPick(0xaaaaaa, 0xa4a4a9), 1.0f); }
UIColor *RewindColorTextTertiary(void) { return RewindHex(RewindPick(0x717171, 0x707075), 1.0f); }
UIColor *RewindColorLink(void) { return RewindHex(RewindPick(0x3ea6ff, 0xe5483f), 1.0f); }
/* section titles: plain text on material, the red of the skeuomorphic theme */
UIColor *RewindColorHeading(void) { return RewindCurrentTheme() == RewindThemeSkeuomorphic ? RewindColorLink() : RewindColorText(); }
UIColor *RewindColorPlaceholder(void) { return RewindHex(RewindPick(0x212121, 0x2c2c2c), 1.0f); }
UIColor *RewindColorAccentFill(void) {
    return RewindCurrentTheme() == RewindThemeSkeuomorphic ? RewindHex(0xb82a22, 1.0f) : RewindColorText();
}
UIColor *RewindColorOnAccent(void) {
    return RewindCurrentTheme() == RewindThemeSkeuomorphic ? [UIColor whiteColor] : [UIColor blackColor];
}
/* the red the ios 5 bars are tinted with; the stock bar draws its own gloss from it */
UIColor *RewindColorChrome(void) {
    return RewindCurrentTheme() == RewindThemeSkeuomorphic ? RewindHex(0xa8231c, 1.0f) : RewindColorBackground();
}

BOOL RewindIsPad(void) {
    return [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
}

/* the screenshots come from a 412dp phone; a 320pt iphone at that ratio reads too small,
   so phones scale by width with a floor and tablets get a little larger type */
CGFloat RewindScale(void) {
    static CGFloat scale;
    if (scale > 0.0f) return scale;
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat shortSide = MIN(screen.width, screen.height);
    if (RewindIsPad()) scale = 1.15f;
    else scale = MAX(0.87f, MIN(1.0f, shortSide / 412.0f));
    return scale;
}

CGFloat RW(CGFloat dp) {
    CGFloat pixel = [UIScreen mainScreen].scale;
    return roundf(dp * RewindScale() * pixel) / pixel;
}

/* -safeAreaInsets does not exist before ios 11, so it has to be reached
   through the runtime instead of called directly */
static UIEdgeInsets RewindSafeAreaInsets(void) {
    UIEdgeInsets zero = UIEdgeInsetsZero;
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return zero;
    SEL sel = NSSelectorFromString(@"safeAreaInsets");
    if (![window respondsToSelector:sel]) return zero;
    IMP imp = [window methodForSelector:sel];
    if (!imp) return zero;
    UIEdgeInsets (*call)(id, SEL) = (UIEdgeInsets (*)(id, SEL))imp;
    UIEdgeInsets insets = call(window, sel);
    if (insets.top < 0.0f || insets.left < 0.0f || insets.bottom < 0.0f || insets.right < 0.0f)
        return zero;
    return insets;
}

CGFloat RewindStatusBarInset(void) {
    UIEdgeInsets safe = RewindSafeAreaInsets();
    /* a notched or dynamic island device reports its true inset here; a
       plain rectangular screen reports zero and falls through to the bar */
    if (safe.top > 0.0f) return safe.top;
    if (![UIViewController instancesRespondToSelector:@selector(setNeedsStatusBarAppearanceUpdate)])
        return 0.0f;
    CGRect bar = [UIApplication sharedApplication].statusBarFrame;
    /* the shorter edge stays the bar thickness after a landscape axis swap */
    CGFloat edge = bar.size.height;
    if (bar.size.width > 0.0f && bar.size.width < edge) edge = bar.size.width;
    return edge >= 1.0f ? edge : 20.0f;
}

CGFloat RewindBottomSafeInset(void) {
    return RewindSafeAreaInsets().bottom;
}

UIFont *RewindFont(CGFloat dp, RewindWeight weight) {
    static NSString *names[3] = { @"Roboto-Regular", @"Roboto-Medium", @"Roboto-Bold" };
    CGFloat size = RW(dp);
    /* ios 5 draws its own interface in helvetica, so the skeuomorphic theme does too */
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic) return RewindChromeFont(size, weight != RewindWeightRegular);
    UIFont *font = [UIFont fontWithName:names[weight] size:size];
    if (font) return font;
    return weight == RewindWeightRegular ? [UIFont systemFontOfSize:size] : [UIFont boldSystemFontOfSize:size];
}

UIImage *RewindIcon(NSString *name, CGFloat points, UIColor *color) {
    static NSCache *cache;
    if (!cache) {
        cache = [[NSCache alloc] init];
        [cache setCountLimit:160];
    }
    if (!name.length || points <= 0.0f) return nil;
    CGFloat r = 1, g = 1, b = 1, a = 1;
    if (color && ![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat white = 1;
        if ([color getWhite:&white alpha:&a]) r = g = b = white;
    }
    NSString *key = [NSString stringWithFormat:@"%@|%.1f|%.3f,%.3f,%.3f,%.3f", name, points, r, g, b, a];
    UIImage *hit = [cache objectForKey:key];
    if (hit) return hit;

    NSString *path = [[NSBundle mainBundle] pathForResource:[@"ic-" stringByAppendingString:name] ofType:@"png"];
    UIImage *mask = path ? [UIImage imageWithContentsOfFile:path] : nil;
    if (!mask) return nil;
    CGRect rect = CGRectMake(0.0f, 0.0f, points, points);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0.0f);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    [mask drawInRect:rect];
    CGContextSetBlendMode(context, kCGBlendModeSourceIn);
    CGContextSetFillColorWithColor(context, (color ?: [UIColor whiteColor]).CGColor);
    CGContextFillRect(context, rect);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (image) [cache setObject:image forKey:key];
    return image;
}

UIImage *RewindSolidImage(UIColor *color) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1.0f, 1.0f), YES, 0.0f);
    [color setFill];
    UIRectFill(CGRectMake(0.0f, 0.0f, 1.0f, 1.0f));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

void RewindStyleNavigationBar(UINavigationBar *bar) {
    if (!bar) return;
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic) {
        /* the red bar is drawn by rewind_chrome, since ios 7 and later draw a tinted stock bar flat */
        UIImage *portrait = RewindChromeBarImage(44.0f);
        NSDictionary *title = [NSDictionary dictionaryWithObjectsAndKeys:
                               [UIColor whiteColor], UITextAttributeTextColor,
                               [UIColor colorWithWhite:0.0f alpha:0.5f], UITextAttributeTextShadowColor,
                               [NSValue valueWithUIOffset:UIOffsetMake(0.0f, -1.0f)], UITextAttributeTextShadowOffset,
                               RewindChromeFont(20.0f, YES), UITextAttributeFont, nil];
        /* every screen restyles the bar as it appears; ios 5 rebuilds the title on each assignment, and doing that
           in the middle of a push drew the new title over the old title view */
        if ([bar backgroundImageForBarMetrics:UIBarMetricsDefault] == portrait && [bar.titleTextAttributes isEqual:title])
            return;
        bar.barStyle = UIBarStyleDefault;
        bar.translucent = NO;
        bar.tintColor = RewindColorChrome();
        RewindChromeStyleNavigationBar(bar, portrait, RewindChromeBarImage(32.0f));
        /* the bar image carries its own dark bottom line; the hairline ios 6 adds would double it */
        if ([bar respondsToSelector:@selector(setShadowImage:)])
            [bar setShadowImage:[[[UIImage alloc] init] autorelease]];
        bar.titleTextAttributes = title;
        return;
    }
    bar.barStyle = UIBarStyleBlack;
    bar.translucent = NO;
    bar.tintColor = RewindColorText();
    SEL barTint = NSSelectorFromString(@"setBarTintColor:");
    if ([bar respondsToSelector:barTint])
        [bar performSelector:barTint withObject:RewindColorChrome()];
    UIImage *background = [RewindSolidImage(RewindColorBackground()) resizableImageWithCapInsets:UIEdgeInsetsZero];
    [bar setBackgroundImage:background forBarMetrics:UIBarMetricsDefault];
    [bar setBackgroundImage:background forBarMetrics:UIBarMetricsLandscapePhone];
    /* the hairline under the bar arrived in ios 6; youtube music draws none */
    if ([bar respondsToSelector:@selector(setShadowImage:)])
        [bar setShadowImage:[[[UIImage alloc] init] autorelease]];
    bar.titleTextAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
                               RewindColorText(), UITextAttributeTextColor,
                               [NSValue valueWithUIOffset:UIOffsetZero], UITextAttributeTextShadowOffset,
                               [UIColor clearColor], UITextAttributeTextShadowColor,
                               RewindFont(20.0f, RewindWeightMedium), UITextAttributeFont, nil];
}

UIBarButtonItem *RewindIconBarItem(NSString *icon, id target, SEL action) {
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic)
        return RewindChromeBarItem(nil, RewindIcon(icon, 20.0f, [UIColor whiteColor]), NO, target, action);
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(0.0f, 0.0f, 40.0f, 40.0f);
    button.showsTouchWhenHighlighted = YES;
    [button setImage:RewindIcon(icon, RW(24.0f), RewindColorText()) forState:UIControlStateNormal];
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return [[[UIBarButtonItem alloc] initWithCustomView:button] autorelease];
}

UIBarButtonItem *RewindBackBarItem(id target, SEL action) {
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic) return RewindChromeBarItem(RewindL(@"back"), nil, YES, target, action);
    return RewindIconBarItem(@"back", target, action);
}

/* plain tinted text, no chip: a "Done"/"Add" label reads as a nav action, not
   a physical button, on the old youtube bar this theme is modeled on */
UIBarButtonItem *RewindBarButtonItem(NSString *title, id target, SEL action) {
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic) return RewindChromeBarItem(title, nil, NO, target, action);
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    UIFont *font = RewindFont(15.0f, RewindWeightMedium);
    CGSize size = RewindTextSize(title, font, 200.0f);
    button.frame = CGRectMake(0.0f, 0.0f, MAX(44.0f, ceilf(size.width) + 16.0f), 40.0f);
    button.titleLabel.font = font;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:RewindColorText() forState:UIControlStateNormal];
    [button setTitleColor:RewindColorTextSecondary() forState:UIControlStateHighlighted];
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return [[[UIBarButtonItem alloc] initWithCustomView:button] autorelease];
}

/* -sizeWithFont:constrainedToSize:lineBreakMode: takes an unbounded height that newer
   text layout does not accept (ios 15 crashes on the first bar button title it measures,
   right after launch); senko hit the same call on the same ios 5-16 range and replaced
   it with a label gauge (SenkoTextSize in app/ui_style.m), so this mirrors that fix */
CGSize RewindTextSize(NSString *text, UIFont *font, CGFloat width) {
    static UILabel *gauge = nil;
    if (!text.length || !font || width < 1.0f) return CGSizeZero;
    if (!gauge) {
        gauge = [[UILabel alloc] initWithFrame:CGRectZero];
        gauge.numberOfLines = 0;
        gauge.lineBreakMode = NSLineBreakByWordWrapping;
        gauge.backgroundColor = [UIColor clearColor];
    }
    gauge.font = font;
    gauge.text = text;
    CGSize fit = [gauge sizeThatFits:CGSizeMake(width, 100000.0f)];
    if (fit.width > width) fit.width = width;
    return CGSizeMake(ceilf(fit.width), ceilf(fit.height));
}
