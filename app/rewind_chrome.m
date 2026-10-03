#import "rewind_chrome.h"

#import <QuartzCore/QuartzCore.h>
#include <objc/message.h>

#import "rewind_theme.h"
#import "rewind_l10n.h"

static const CGFloat RewindChromeButtonHeight = 30.0f;
static const CGFloat RewindChromeTabHeight = 49.0f;

UIFont *RewindChromeFont(CGFloat size, BOOL bold) {
    /* ios 9 swapped the system face for san francisco; ios 5 drew this interface in helvetica */
    UIFont *font = [UIFont fontWithName:bold ? @"Helvetica-Bold" : @"Helvetica" size:size];
    if (font) return font;
    return bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
}

/* colors run top to bottom; locations may be NULL for an even spread */
static void RewindChromeGradient(CGContextRef ctx, CGRect rect, const CGFloat *components, const CGFloat *locations,
                                 size_t count) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, count);
    if (gradient) {
        CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0.0f, CGRectGetMinY(rect)),
                                    CGPointMake(0.0f, CGRectGetMaxY(rect)), 0);
        CGGradientRelease(gradient);
    }
    CGColorSpaceRelease(space);
}

UIImage *RewindChromeBarImage(CGFloat height) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [[NSMutableDictionary alloc] init];
    NSNumber *key = [NSNumber numberWithFloat:(float)height];
    UIImage *hit = [cache objectForKey:key];
    if (hit) return hit;
    CGRect rect = CGRectMake(0.0f, 0.0f, 1.0f, height);
    UIGraphicsBeginImageContextWithOptions(rect.size, YES, 0.0f);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    /* the glossy tinted bar: a lit upper half over a deeper lower half */
    const CGFloat colors[16] = { 0.86f, 0.38f, 0.34f, 1.0f,   0.73f, 0.20f, 0.16f, 1.0f,
                                 0.66f, 0.13f, 0.10f, 1.0f,   0.55f, 0.08f, 0.06f, 1.0f };
    const CGFloat stops[4] = { 0.0f, 0.5f, 0.5f, 1.0f };
    RewindChromeGradient(ctx, rect, colors, stops, 4);
    [[UIColor colorWithWhite:1.0f alpha:0.35f] setFill];
    UIRectFill(CGRectMake(0.0f, 0.0f, 1.0f, 1.0f));
    [[UIColor colorWithWhite:0.0f alpha:0.6f] setFill];
    UIRectFill(CGRectMake(0.0f, height - 1.0f, 1.0f, 1.0f));
    UIImage *image = [UIGraphicsGetImageFromCurrentImageContext() resizableImageWithCapInsets:UIEdgeInsetsZero];
    UIGraphicsEndImageContext();
    if (image) [cache setObject:image forKey:key];
    return image;
}

void RewindChromeStyleNavigationBar(UINavigationBar *bar, UIImage *portrait, UIImage *landscape) {
    [bar setBackgroundImage:portrait forBarMetrics:UIBarMetricsDefault];
    [bar setBackgroundImage:landscape forBarMetrics:UIBarMetricsLandscapePhone];
    Class appearanceClass = NSClassFromString(@"UINavigationBarAppearance");
    SEL standard = NSSelectorFromString(@"setStandardAppearance:");
    if (!appearanceClass || ![bar respondsToSelector:standard]) return;
    id appearance = [[[appearanceClass alloc] init] autorelease];
    [appearance performSelector:NSSelectorFromString(@"configureWithOpaqueBackground")];
    [appearance performSelector:NSSelectorFromString(@"setBackgroundColor:") withObject:RewindColorChrome()];
    [appearance performSelector:NSSelectorFromString(@"setBackgroundImage:") withObject:portrait];
    [appearance performSelector:NSSelectorFromString(@"setShadowColor:") withObject:nil];
    /* the appearance takes the current attribute names only; NSShadow exists from ios 6 */
    NSShadow *shadow = [[[NSClassFromString(@"NSShadow") alloc] init] autorelease];
    [shadow setShadowColor:[UIColor colorWithWhite:0.0f alpha:0.5f]];
    [shadow setShadowOffset:CGSizeMake(0.0f, -1.0f)];
    NSDictionary *title = [NSDictionary dictionaryWithObjectsAndKeys:
                           [UIColor whiteColor], @"NSColor", RewindChromeFont(20.0f, YES), @"NSFont",
                           shadow, @"NSShadow", nil];
    [appearance performSelector:NSSelectorFromString(@"setTitleTextAttributes:") withObject:title];
    [bar performSelector:standard withObject:appearance];
    SEL edge = NSSelectorFromString(@"setScrollEdgeAppearance:");
    if ([bar respondsToSelector:edge]) [bar performSelector:edge withObject:appearance];
    SEL compact = NSSelectorFromString(@"setCompactAppearance:");
    if ([bar respondsToSelector:compact]) [bar performSelector:compact withObject:appearance];
    SEL compactEdge = NSSelectorFromString(@"setCompactScrollEdgeAppearance:");
    if ([bar respondsToSelector:compactEdge]) [bar performSelector:compactEdge withObject:appearance];
}

static UIBezierPath *RewindChromeButtonPath(CGRect rect, BOOL back) {
    CGFloat radius = 5.0f;
    if (!back) return [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
    CGFloat minX = CGRectGetMinX(rect), maxX = CGRectGetMaxX(rect);
    CGFloat minY = CGRectGetMinY(rect), maxY = CGRectGetMaxY(rect), midY = CGRectGetMidY(rect);
    CGFloat tip = 11.0f;
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(minX + tip, minY)];
    [path addLineToPoint:CGPointMake(maxX - radius, minY)];
    [path addArcWithCenter:CGPointMake(maxX - radius, minY + radius) radius:radius startAngle:(CGFloat)(-M_PI_2)
                  endAngle:0.0f clockwise:YES];
    [path addLineToPoint:CGPointMake(maxX, maxY - radius)];
    [path addArcWithCenter:CGPointMake(maxX - radius, maxY - radius) radius:radius startAngle:0.0f
                  endAngle:(CGFloat)M_PI_2 clockwise:YES];
    [path addLineToPoint:CGPointMake(minX + tip, maxY)];
    [path addLineToPoint:CGPointMake(minX + 1.0f, midY + 1.0f)];
    [path addQuadCurveToPoint:CGPointMake(minX + 1.0f, midY - 1.0f) controlPoint:CGPointMake(minX, midY)];
    [path closePath];
    path.lineJoinStyle = kCGLineJoinRound;
    return path;
}

/* the darker red pill set into the bar, with the light lip ios 5 puts under a pressed in control */
static UIImage *RewindChromeButtonImage(BOOL back, BOOL pressed) {
    static UIImage *images[4];
    UIImage **slot = &images[(back ? 2 : 0) + (pressed ? 1 : 0)];
    if (*slot) return *slot;
    CGFloat left = back ? 14.0f : 6.0f, right = 6.0f;
    CGSize size = CGSizeMake(left + right + 1.0f, RewindChromeButtonHeight);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0f);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect body = CGRectMake(0.5f, 0.5f, size.width - 1.0f, size.height - 2.0f);
    UIBezierPath *lip = RewindChromeButtonPath(CGRectOffset(body, 0.0f, 1.0f), back);
    [[UIColor colorWithWhite:1.0f alpha:0.22f] setStroke];
    [lip stroke];
    UIBezierPath *shape = RewindChromeButtonPath(body, back);
    CGContextSaveGState(ctx);
    [shape addClip];
    CGFloat dim = pressed ? 0.62f : 1.0f;
    const CGFloat colors[16] = { 0.74f * dim, 0.23f * dim, 0.19f * dim, 1.0f,  0.60f * dim, 0.12f * dim, 0.09f * dim, 1.0f,
                                 0.52f * dim, 0.07f * dim, 0.05f * dim, 1.0f,  0.47f * dim, 0.05f * dim, 0.04f * dim, 1.0f };
    const CGFloat stops[4] = { 0.0f, 0.5f, 0.5f, 1.0f };
    RewindChromeGradient(ctx, body, colors, stops, 4);
    CGContextRestoreGState(ctx);
    [[UIColor colorWithWhite:0.0f alpha:0.65f] setStroke];
    shape.lineWidth = 1.0f;
    [shape stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    *slot = [[image resizableImageWithCapInsets:UIEdgeInsetsMake(0.0f, left, 0.0f, right)] retain];
    return *slot;
}

UIBarButtonItem *RewindChromeBarItem(NSString *title, UIImage *glyph, BOOL back, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    UIFont *font = RewindChromeFont(12.0f, YES);
    CGFloat leftPad = back ? 15.0f : 10.0f, rightPad = 10.0f;
    CGFloat width;
    if (glyph) {
        [button setImage:glyph forState:UIControlStateNormal];
        width = MAX(40.0f, glyph.size.width + leftPad + rightPad);
    } else {
        button.titleLabel.font = font;
        button.titleLabel.shadowOffset = CGSizeMake(0.0f, -1.0f);
        button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [button setTitle:title forState:UIControlStateNormal];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [button setTitleShadowColor:[UIColor colorWithWhite:0.0f alpha:0.5f] forState:UIControlStateNormal];
        width = MIN(140.0f, MAX(50.0f, ceilf(RewindTextSize(title, font, 300.0f).width) + leftPad + rightPad));
    }
    button.contentEdgeInsets = UIEdgeInsetsMake(0.0f, leftPad, 0.0f, rightPad);
    button.adjustsImageWhenHighlighted = NO;
    [button setBackgroundImage:RewindChromeButtonImage(back, NO) forState:UIControlStateNormal];
    [button setBackgroundImage:RewindChromeButtonImage(back, YES) forState:UIControlStateHighlighted];
    button.frame = CGRectMake(0.0f, 0.0f, width, RewindChromeButtonHeight);
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return [[[UIBarButtonItem alloc] initWithCustomView:button] autorelease];
}

UIView *RewindChromeDisclosure(void) {
    static UIImage *chevron;
    if (!chevron) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(11.0f, 15.0f), NO, 0.0f);
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(2.0f, 2.0f)];
        [path addLineToPoint:CGPointMake(8.0f, 7.5f)];
        [path addLineToPoint:CGPointMake(2.0f, 13.0f)];
        path.lineWidth = 3.0f;
        path.lineCapStyle = kCGLineCapSquare;
        path.lineJoinStyle = kCGLineJoinMiter;
        [[UIColor colorWithWhite:0.55f alpha:1.0f] setStroke];
        [path stroke];
        chevron = [UIGraphicsGetImageFromCurrentImageContext() retain];
        UIGraphicsEndImageContext();
    }
    return [[[UIImageView alloc] initWithImage:chevron] autorelease];
}

UIView *RewindChromeCheckmark(void) {
    static UIImage *check;
    if (!check) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(16.0f, 14.0f), NO, 0.0f);
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(2.0f, 7.5f)];
        [path addLineToPoint:CGPointMake(6.0f, 11.5f)];
        [path addLineToPoint:CGPointMake(14.0f, 2.0f)];
        path.lineWidth = 3.0f;
        path.lineCapStyle = kCGLineCapRound;
        path.lineJoinStyle = kCGLineJoinRound;
        [[UIColor colorWithRed:0.27f green:0.55f blue:0.95f alpha:1.0f] setStroke];
        [path stroke];
        check = [UIGraphicsGetImageFromCurrentImageContext() retain];
        UIGraphicsEndImageContext();
    }
    return [[[UIImageView alloc] initWithImage:check] autorelease];
}

/* ios 7 indents separators, ios 8 adds layout margins and ios 9 narrows ipad rows to a reading width;
   ios 5 has none of these, so each is reset where the running uikit has it */
static void RewindChromeZeroInsets(id view, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (![view respondsToSelector:sel]) return;
    ((void (*)(id, SEL, UIEdgeInsets))objc_msgSend)(view, sel, UIEdgeInsetsZero);
}

static void RewindChromeSetFlag(id view, NSString *selector, BOOL value) {
    SEL sel = NSSelectorFromString(selector);
    if (![view respondsToSelector:sel]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(view, sel, value);
}

void RewindChromeStyleTable(UITableView *table) {
    RewindChromeZeroInsets(table, @"setSeparatorInset:");
    RewindChromeZeroInsets(table, @"setLayoutMargins:");
    RewindChromeSetFlag(table, @"setCellLayoutMarginsFollowReadableWidth:", NO);
}

void RewindChromeStyleCell(UITableViewCell *cell) {
    RewindChromeZeroInsets(cell, @"setSeparatorInset:");
    RewindChromeZeroInsets(cell, @"setLayoutMargins:");
    RewindChromeSetFlag(cell, @"setPreservesSuperviewLayoutMargins:", NO);
}

static UIImage *RewindChromeSearchField(void) {
    static UIImage *field;
    if (field) return field;
    CGFloat height = 31.0f, radius = 15.0f;
    CGSize size = CGSizeMake(radius * 2.0f + 1.0f, height);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0f);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect body = CGRectMake(0.5f, 0.5f, size.width - 1.0f, height - 2.0f);
    UIBezierPath *lip = [UIBezierPath bezierPathWithRoundedRect:CGRectOffset(body, 0.0f, 1.0f) cornerRadius:radius];
    [[UIColor colorWithWhite:1.0f alpha:0.25f] setStroke];
    [lip stroke];
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:body cornerRadius:radius];
    [[UIColor whiteColor] setFill];
    [shape fill];
    /* the inset shadow along the top edge of an ios 5 text well */
    CGContextSaveGState(ctx);
    [shape addClip];
    UIBezierPath *shade = [UIBezierPath bezierPathWithRoundedRect:CGRectOffset(body, 0.0f, 1.5f) cornerRadius:radius];
    shade.lineWidth = 2.0f;
    [[UIColor colorWithWhite:0.0f alpha:0.3f] setStroke];
    [shade stroke];
    CGContextRestoreGState(ctx);
    [[UIColor colorWithWhite:0.0f alpha:0.55f] setStroke];
    [shape stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    field = [[image resizableImageWithCapInsets:UIEdgeInsetsMake(0.0f, radius, 0.0f, radius)] retain];
    return field;
}

static UITextField *RewindChromeFindField(UIView *view) {
    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:[UITextField class]]) return (UITextField *)child;
        UITextField *found = RewindChromeFindField(child);
        if (found) return found;
    }
    return nil;
}

void RewindChromeStyleSearchBar(UISearchBar *bar) {
    if (!bar) return;
    [bar setBackgroundImage:RewindChromeBarImage(44.0f)];
    [bar setSearchFieldBackgroundImage:RewindChromeSearchField() forState:UIControlStateNormal];
    [bar setImage:RewindIcon(@"search", 15.0f, [UIColor colorWithWhite:0.45f alpha:1.0f])
        forSearchBarIcon:UISearchBarIconSearch state:UIControlStateNormal];
    /* ios 13 dark mode would paint white text into the white well */
    SEL style = NSSelectorFromString(@"setOverrideUserInterfaceStyle:");
    if ([bar respondsToSelector:style]) ((void (*)(id, SEL, NSInteger))objc_msgSend)(bar, style, 1);
    UITextField *field = RewindChromeFindField(bar);
    field.textColor = [UIColor blackColor];
    field.font = RewindChromeFont(14.0f, NO);
}

#pragma mark - grouped tables

UIColor *RewindChromeGroupedBackground(void) {
    return [UIColor colorWithWhite:0.05f alpha:1.0f];
}

UIColor *RewindChromeGroupedTextColor(void) {
    return [UIColor whiteColor];
}

UIColor *RewindChromeGroupedValueColor(void) {
    return [UIColor colorWithRed:0.56f green:0.66f blue:0.82f alpha:1.0f];
}

UIColor *RewindChromeGroupedCaptionColor(void) {
    return [UIColor colorWithWhite:0.62f alpha:1.0f];
}

static BOOL RewindChromeSystemInsetsGroups(void) {
    return ![UITableView instancesRespondToSelector:@selector(setSeparatorInset:)];
}

CGFloat RewindChromeGroupedMargin(void) {
    if (RewindChromeSystemInsetsGroups()) return 0.0f;
    return RewindIsPad() ? 45.0f : 10.0f;
}

void RewindChromeDrawGroupedSegment(CGRect bounds, BOOL first, BOOL last, BOOL selected) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat radius = 10.0f;
    /* a row below another lets its top rim fall outside, so the row above's bottom rim is the one separator */
    CGRect body = bounds;
    if (!first) {
        body.origin.y -= 1.0f;
        body.size.height += 1.0f;
    }
    body = CGRectInset(body, 0.5f, 0.5f);
    UIRectCorner corners = (first ? UIRectCornerTopLeft | UIRectCornerTopRight : 0) |
                           (last ? UIRectCornerBottomLeft | UIRectCornerBottomRight : 0);
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:body byRoundingCorners:corners
                                                      cornerRadii:CGSizeMake(radius, radius)];
    CGContextSaveGState(ctx);
    [shape addClip];
    if (selected) {
        const CGFloat colors[8] = { 0.02f, 0.55f, 0.96f, 1.0f,  0.00f, 0.37f, 0.90f, 1.0f };
        RewindChromeGradient(ctx, body, colors, NULL, 2);
    } else {
        const CGFloat colors[8] = { 0.17f, 0.17f, 0.18f, 1.0f,  0.12f, 0.12f, 0.13f, 1.0f };
        RewindChromeGradient(ctx, body, colors, NULL, 2);
    }
    CGContextRestoreGState(ctx);
    [[UIColor colorWithWhite:0.30f alpha:1.0f] setStroke];
    shape.lineWidth = 1.0f;
    [shape stroke];
}

@interface RewindChromeSegmentView : UIView {
    BOOL _first, _last, _selected;
}
- (id)initWithFirst:(BOOL)first last:(BOOL)last selected:(BOOL)selected;
@end

@implementation RewindChromeSegmentView

- (id)initWithFirst:(BOOL)first last:(BOOL)last selected:(BOOL)selected {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _first = first;
    _last = last;
    _selected = selected;
    self.opaque = NO;
    self.backgroundColor = [UIColor clearColor];
    self.contentMode = UIViewContentModeRedraw;
    return self;
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    RewindChromeDrawGroupedSegment(self.bounds, _first, _last, _selected);
}

@end

void RewindChromeStyleGroupedCell(UITableViewCell *cell, BOOL first, BOOL last) {
    cell.backgroundColor = [UIColor clearColor];
    cell.backgroundView = [[[RewindChromeSegmentView alloc] initWithFirst:first last:last selected:NO] autorelease];
    cell.selectedBackgroundView = [[[RewindChromeSegmentView alloc] initWithFirst:first last:last selected:YES] autorelease];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.textColor = RewindChromeGroupedTextColor();
    cell.textLabel.highlightedTextColor = [UIColor whiteColor];
    cell.textLabel.font = RewindChromeFont(17.0f, YES);
    cell.detailTextLabel.backgroundColor = [UIColor clearColor];
    cell.detailTextLabel.textColor = RewindChromeGroupedValueColor();
    cell.detailTextLabel.highlightedTextColor = [UIColor whiteColor];
    cell.detailTextLabel.font = RewindChromeFont(17.0f, NO);
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
}

/* the groups start this far from the table's own edge, where the titles line up with them */
static CGFloat RewindChromeGroupedTextInset(void) {
    CGFloat system = RewindChromeSystemInsetsGroups() ? (RewindIsPad() ? 45.0f : 10.0f) : 0.0f;
    return system + 10.0f;
}

static UILabel *RewindChromeEmbossedLabel(CGFloat size, BOOL bold) {
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.textColor = RewindChromeGroupedCaptionColor();
    label.shadowColor = [UIColor blackColor];
    label.shadowOffset = CGSizeMake(0.0f, -1.0f);
    label.font = RewindChromeFont(size, bold);
    return label;
}

UIView *RewindChromeGroupedHeader(NSString *title, CGFloat width) {
    UIView *header = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, width, 44.0f)] autorelease];
    header.backgroundColor = [UIColor clearColor];
    if (!title.length) return header;
    CGFloat inset = RewindChromeGroupedTextInset();
    UILabel *label = RewindChromeEmbossedLabel(17.0f, YES);
    label.frame = CGRectMake(inset, 16.0f, MAX(0.0f, width - inset * 2.0f), 22.0f);
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    label.text = title;
    [header addSubview:label];
    return header;
}

CGFloat RewindChromeGroupedFooterHeight(NSString *text, CGFloat width) {
    if (!text.length) return 10.0f;
    CGFloat inset = RewindChromeGroupedTextInset();
    return ceilf(RewindTextSize(text, RewindChromeFont(15.0f, NO), MAX(40.0f, width - inset * 2.0f)).height) + 16.0f;
}

UIView *RewindChromeGroupedFooter(NSString *text, CGFloat width) {
    CGFloat height = RewindChromeGroupedFooterHeight(text, width);
    UIView *footer = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, width, height)] autorelease];
    footer.backgroundColor = [UIColor clearColor];
    if (!text.length) return footer;
    CGFloat inset = RewindChromeGroupedTextInset();
    UILabel *label = RewindChromeEmbossedLabel(15.0f, NO);
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.frame = CGRectMake(inset, 6.0f, MAX(0.0f, width - inset * 2.0f), height - 10.0f);
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    label.text = text;
    [footer addSubview:label];
    return footer;
}

#pragma mark - switch

static const CGFloat RewindChromeSwitchWidth = 79.0f, RewindChromeSwitchHeight = 27.0f;

@interface RewindChromeSwitch ()
- (UIView *)strip;
- (void)placeKnob:(CGFloat)position;
@end

@implementation RewindChromeSwitch

@synthesize on = _on;

/* blue "on" half, a gap the knob covers, grey "off" half; it slides under a rounded window */
static UIImage *RewindChromeSwitchStrip(void) {
    static UIImage *strip;
    if (strip) return strip;
    CGFloat w = RewindChromeSwitchWidth, h = RewindChromeSwitchHeight, d = h, side = w - d * 0.5f;
    CGSize size = CGSizeMake(side * 2.0f, h);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0.0f);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    const CGFloat blue[12] = { 0.16f, 0.45f, 0.90f, 1.0f,  0.25f, 0.56f, 0.97f, 1.0f,  0.42f, 0.70f, 1.0f, 1.0f };
    const CGFloat grey[12] = { 0.80f, 0.80f, 0.80f, 1.0f,  0.93f, 0.93f, 0.93f, 1.0f,  0.99f, 0.99f, 0.99f, 1.0f };
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(0.0f, 0.0f, side, h));
    RewindChromeGradient(ctx, CGRectMake(0.0f, 0.0f, side, h), blue, NULL, 3);
    CGContextRestoreGState(ctx);
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(side, 0.0f, side, h));
    RewindChromeGradient(ctx, CGRectMake(side, 0.0f, side, h), grey, NULL, 3);
    CGContextRestoreGState(ctx);
    /* russian ios 5 marks the halves with I and O instead of words */
    BOOL symbols = RewindLanguageIsRussian();
    NSString *onText = symbols ? @"I" : @"ON", *offText = symbols ? @"O" : @"OFF";
    UIFont *font = RewindChromeFont(16.0f, YES);
    CGFloat textY = floorf((h - font.lineHeight) * 0.5f);
    CGFloat textWidth = w - d;
    CGContextSetShadowWithColor(ctx, CGSizeMake(0.0f, -1.0f), 0.0f, [UIColor colorWithWhite:0.0f alpha:0.4f].CGColor);
    [[UIColor whiteColor] set];
    [onText drawInRect:CGRectMake(0.0f, textY, textWidth, font.lineHeight) withFont:font
         lineBreakMode:NSLineBreakByClipping alignment:NSTextAlignmentCenter];
    CGContextSetShadowWithColor(ctx, CGSizeZero, 0.0f, NULL);
    [[UIColor colorWithWhite:0.45f alpha:1.0f] set];
    [offText drawInRect:CGRectMake(side * 2.0f - textWidth, textY, textWidth, font.lineHeight) withFont:font
          lineBreakMode:NSLineBreakByClipping alignment:NSTextAlignmentCenter];
    strip = [UIGraphicsGetImageFromCurrentImageContext() retain];
    UIGraphicsEndImageContext();
    return strip;
}

static UIImage *RewindChromeSwitchKnob(void) {
    static UIImage *knob;
    if (knob) return knob;
    CGFloat d = RewindChromeSwitchHeight;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(d, d), NO, 0.0f);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect disc = CGRectMake(0.5f, 0.5f, d - 1.0f, d - 1.0f);
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, disc);
    CGContextClip(ctx);
    const CGFloat colors[8] = { 0.99f, 0.99f, 0.99f, 1.0f,  0.80f, 0.80f, 0.81f, 1.0f };
    RewindChromeGradient(ctx, disc, colors, NULL, 2);
    CGContextRestoreGState(ctx);
    [[UIColor colorWithWhite:0.0f alpha:0.45f] setStroke];
    CGContextSetLineWidth(ctx, 1.0f);
    CGContextStrokeEllipseInRect(ctx, disc);
    knob = [UIGraphicsGetImageFromCurrentImageContext() retain];
    UIGraphicsEndImageContext();
    return knob;
}

static UIImage *RewindChromeSwitchFrame(void) {
    static UIImage *frame;
    if (frame) return frame;
    CGFloat w = RewindChromeSwitchWidth, h = RewindChromeSwitchHeight;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0.0f);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect body = CGRectMake(0.5f, 0.5f, w - 1.0f, h - 1.0f);
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:body cornerRadius:h * 0.5f];
    CGContextSaveGState(ctx);
    [shape addClip];
    UIBezierPath *shade = [UIBezierPath bezierPathWithRoundedRect:CGRectOffset(body, 0.0f, 1.5f) cornerRadius:h * 0.5f];
    shade.lineWidth = 2.0f;
    [[UIColor colorWithWhite:0.0f alpha:0.3f] setStroke];
    [shade stroke];
    CGContextRestoreGState(ctx);
    [[UIColor colorWithWhite:0.0f alpha:0.5f] setStroke];
    [shape stroke];
    frame = [UIGraphicsGetImageFromCurrentImageContext() retain];
    UIGraphicsEndImageContext();
    return frame;
}

- (id)initWithFrame:(CGRect)frame {
    frame.size = CGSizeMake(RewindChromeSwitchWidth, RewindChromeSwitchHeight);
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    UIView *window = [[[UIView alloc] initWithFrame:self.bounds] autorelease];
    window.userInteractionEnabled = NO;
    window.layer.cornerRadius = RewindChromeSwitchHeight * 0.5f;
    window.layer.masksToBounds = YES;
    window.tag = 1;
    UIImageView *strip = [[[UIImageView alloc] initWithImage:RewindChromeSwitchStrip()] autorelease];
    strip.tag = 2;
    [window addSubview:strip];
    UIImageView *knob = [[[UIImageView alloc] initWithImage:RewindChromeSwitchKnob()] autorelease];
    knob.tag = 3;
    [window addSubview:knob];
    [self addSubview:window];
    UIImageView *rim = [[[UIImageView alloc] initWithImage:RewindChromeSwitchFrame()] autorelease];
    rim.userInteractionEnabled = NO;
    [self addSubview:rim];
    [self placeKnob:0.0f];
    return self;
}

- (UIView *)strip {
    return [[self viewWithTag:1] viewWithTag:2];
}

/* 0 is off, 1 is on */
- (void)placeKnob:(CGFloat)position {
    CGFloat travel = RewindChromeSwitchWidth - RewindChromeSwitchHeight;
    position = MAX(0.0f, MIN(1.0f, position));
    _knob = position;
    CGFloat x = -(1.0f - position) * travel;
    UIView *strip = [self strip];
    CGRect frame = strip.frame;
    frame.origin.x = x;
    strip.frame = frame;
    UIView *knob = [[self viewWithTag:1] viewWithTag:3];
    knob.frame = CGRectMake(position * travel, 0.0f, RewindChromeSwitchHeight, RewindChromeSwitchHeight);
}

- (void)setOn:(BOOL)on {
    [self setOn:on animated:NO];
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    _on = on;
    if (!animated) {
        [self placeKnob:on ? 1.0f : 0.0f];
        return;
    }
    [UIView animateWithDuration:0.2 animations:^{ [self placeKnob:on ? 1.0f : 0.0f]; }];
}

- (CGSize)sizeThatFits:(CGSize)size {
    (void)size;
    return CGSizeMake(RewindChromeSwitchWidth, RewindChromeSwitchHeight);
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    (void)event;
    _dragStart = [touch locationInView:self].x;
    _dragged = NO;
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    (void)event;
    CGFloat x = [touch locationInView:self].x;
    CGFloat travel = RewindChromeSwitchWidth - RewindChromeSwitchHeight;
    if (!_dragged && fabsf((float)(x - _dragStart)) < 4.0f) return YES;
    _dragged = YES;
    [self placeKnob:(_on ? 1.0f : 0.0f) + (x - _dragStart) / travel];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    (void)touch;
    (void)event;
    BOOL next = _dragged ? _knob >= 0.5f : !_on;
    BOOL changed = next != _on;
    [self setOn:next animated:YES];
    if (changed) [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    (void)event;
    [self setOn:_on animated:YES];
}

@end

#pragma mark - navigation

@implementation RewindChromeNavigationController

- (void)chromeBackPressed {
    [self popViewControllerAnimated:YES];
}

- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated {
    UIViewController *top = self.topViewController;
    UINavigationItem *item = controller.navigationItem;
    if (top && !item.leftBarButtonItem && !item.hidesBackButton) {
        NSString *title = top.navigationItem.title.length ? top.navigationItem.title : top.title;
        /* a long title squeezes the new screen's own title the way ios 5 falls back to "back" */
        if (!title.length || title.length > 12) title = RewindL(@"back");
        item.leftBarButtonItem = RewindChromeBarItem(title, nil, YES, self, @selector(chromeBackPressed));
    }
    [super pushViewController:controller animated:animated];
}

@end

#pragma mark - tabs

@interface RewindChromeTabBar : UIView {
    NSArray *_titles;
    NSArray *_icons;
    NSUInteger _selected;
    void (^_onSelect)(NSUInteger index);
}
- (id)initWithTitles:(NSArray *)titles icons:(NSArray *)icons onSelect:(void (^)(NSUInteger index))onSelect;
- (void)setSelected:(NSUInteger)selected;
@end

@implementation RewindChromeTabBar

- (id)initWithTitles:(NSArray *)titles icons:(NSArray *)icons onSelect:(void (^)(NSUInteger index))onSelect {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _titles = [titles copy];
    _icons = [icons copy];
    _onSelect = [onSelect copy];
    self.contentMode = UIViewContentModeRedraw;
    self.opaque = YES;
    return self;
}

- (void)dealloc {
    [_titles release];
    [_icons release];
    [_onSelect release];
    [super dealloc];
}

- (void)setSelected:(NSUInteger)selected {
    _selected = selected;
    [self setNeedsDisplay];
}

/* ios 5 spreads the items over the phone and gathers them in the middle of the ipad */
- (CGRect)slotAtIndex:(NSUInteger)index {
    NSUInteger count = MAX((NSUInteger)1, _titles.count);
    CGFloat width = self.bounds.size.width;
    CGFloat step = RewindIsPad() ? MIN(110.0f, width / count) : width / count;
    CGFloat start = floorf((width - step * count) * 0.5f);
    return CGRectMake(start + step * index, 0.0f, step, RewindChromeTabHeight);
}

- (void)drawGlyph:(NSString *)name inRect:(CGRect)rect selected:(BOOL)selected context:(CGContextRef)ctx {
    UIImage *glyph = RewindIcon(name, rect.size.width, [UIColor whiteColor]);
    if (!glyph.CGImage) return;
    CGContextSaveGState(ctx);
    /* the mask is drawn in core graphics space, which runs bottom up */
    CGContextTranslateCTM(ctx, rect.origin.x, rect.origin.y + rect.size.height);
    CGContextScaleCTM(ctx, 1.0f, -1.0f);
    CGRect box = CGRectMake(0.0f, 0.0f, rect.size.width, rect.size.height);
    CGContextClipToMask(ctx, box, glyph.CGImage);
    if (selected) {
        const CGFloat colors[12] = { 0.03f, 0.40f, 0.84f, 1.0f,  0.20f, 0.60f, 0.98f, 1.0f,  0.62f, 0.86f, 1.0f, 1.0f };
        const CGFloat stops[3] = { 0.0f, 0.5f, 1.0f };
        RewindChromeGradient(ctx, box, colors, stops, 3);
    } else {
        const CGFloat colors[8] = { 0.40f, 0.40f, 0.40f, 1.0f,  0.60f, 0.60f, 0.60f, 1.0f };
        RewindChromeGradient(ctx, box, colors, NULL, 2);
    }
    CGContextRestoreGState(ctx);
}

- (void)drawRect:(CGRect)dirty {
    (void)dirty;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect bounds = self.bounds;
    CGRect bar = CGRectMake(0.0f, 0.0f, bounds.size.width, RewindChromeTabHeight);
    const CGFloat colors[16] = { 0.24f, 0.24f, 0.24f, 1.0f,  0.13f, 0.13f, 0.13f, 1.0f,
                                 0.05f, 0.05f, 0.05f, 1.0f,  0.0f, 0.0f, 0.0f, 1.0f };
    const CGFloat stops[4] = { 0.0f, 0.5f, 0.5f, 1.0f };
    [[UIColor blackColor] setFill];
    UIRectFill(bounds);
    RewindChromeGradient(ctx, bar, colors, stops, 4);
    [[UIColor blackColor] setFill];
    UIRectFill(CGRectMake(0.0f, 0.0f, bounds.size.width, 1.0f));
    [[UIColor colorWithWhite:1.0f alpha:0.1f] setFill];
    UIRectFill(CGRectMake(0.0f, 1.0f, bounds.size.width, 1.0f));

    UIFont *font = RewindChromeFont(10.0f, YES);
    for (NSUInteger index = 0; index < _titles.count; ++index) {
        CGRect slot = [self slotAtIndex:index];
        BOOL selected = index == _selected;
        if (selected) {
            CGRect plate = CGRectInset(CGRectMake(CGRectGetMidX(slot) - 38.0f, 0.0f, 76.0f, RewindChromeTabHeight), 2.0f, 2.0f);
            if (plate.size.width > slot.size.width - 4.0f) plate = CGRectInset(slot, 2.0f, 2.0f);
            UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:plate cornerRadius:3.0f];
            [[UIColor colorWithWhite:1.0f alpha:0.12f] setFill];
            [path fill];
        }
        CGFloat glyph = 26.0f;
        [self drawGlyph:[_icons objectAtIndex:index]
                 inRect:CGRectMake(floorf(CGRectGetMidX(slot) - glyph * 0.5f), 4.0f, glyph, glyph)
               selected:selected context:ctx];
        [(selected ? [UIColor whiteColor] : [UIColor colorWithWhite:0.6f alpha:1.0f]) set];
        [[_titles objectAtIndex:index] drawInRect:CGRectMake(slot.origin.x + 2.0f, 33.0f, slot.size.width - 4.0f, 13.0f)
                                         withFont:font lineBreakMode:NSLineBreakByTruncatingTail
                                        alignment:NSTextAlignmentCenter];
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)event;
    CGPoint point = [[touches anyObject] locationInView:self];
    for (NSUInteger index = 0; index < _titles.count; ++index) {
        if (!CGRectContainsPoint([self slotAtIndex:index], point)) continue;
        if (_onSelect) _onSelect(index);
        return;
    }
}

@end

@interface RewindChromeTabsController ()
- (void)selectIndex:(NSUInteger)index;
- (void)layoutContent;
@end

@implementation RewindChromeTabsController

- (id)initWithControllers:(NSArray *)controllers titles:(NSArray *)titles icons:(NSArray *)icons {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _controllers = [controllers copy];
    _titles = [titles copy];
    _icons = [icons copy];
    _selected = NSNotFound;
    for (UINavigationController *navigation in _controllers) navigation.delegate = self;
    return self;
}

- (void)dealloc {
    for (UINavigationController *navigation in _controllers)
        if (navigation.delegate == self) navigation.delegate = nil;
    [_controllers release];
    [_titles release];
    [_icons release];
    [_bar release];
    /* the strip may outlive these tabs (an image load holds it); leaving the view tells it to let go of them */
    [_accessory removeFromSuperview];
    [_accessory release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]] autorelease];
    /* from ios 7 the status bar sits over the app; black under it is the opaque bar of ios 5 */
    view.backgroundColor = [UIColor blackColor];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    /* __block keeps the bar's block from retaining its owner under manual reference counting */
    __block RewindChromeTabsController *owner = self;
    _bar = [[RewindChromeTabBar alloc] initWithTitles:_titles icons:_icons onSelect:^(NSUInteger index) {
        [owner selectIndex:index];
    }];
    [self.view addSubview:_bar];
    if (_accessory) [self.view insertSubview:_accessory belowSubview:_bar];
    [self selectIndex:0];
}

- (void)setAccessory:(UIView *)view height:(CGFloat)height {
    if (_accessory != view) {
        [_accessory removeFromSuperview];
        [_accessory release];
        _accessory = [view retain];
        if (_accessory && [self isViewLoaded]) [self.view insertSubview:_accessory belowSubview:_bar];
    }
    _accessoryHeight = height;
    if ([self isViewLoaded]) [self layoutContent];
}

- (void)setAccessoryShown:(BOOL)shown animated:(BOOL)animated {
    if (shown == _accessoryShown) return;
    _accessoryShown = shown;
    if (![self isViewLoaded]) return;
    if (!animated) {
        [self layoutContent];
        return;
    }
    [UIView animateWithDuration:0.25 animations:^{ [self layoutContent]; }];
}

- (NSArray *)controllers {
    return _controllers;
}

- (UINavigationController *)selectedNavigation {
    return _selected < _controllers.count ? [_controllers objectAtIndex:_selected] : nil;
}

/* a screen that hides the bar, like the player, keeps it hidden for everything pushed above it */
- (BOOL)barHiddenFor:(UINavigationController *)navigation upTo:(UIViewController *)shown {
    NSArray *stack = navigation.viewControllers;
    for (NSUInteger index = 1; index < stack.count; ++index) {
        UIViewController *controller = [stack objectAtIndex:index];
        if (controller.hidesBottomBarWhenPushed) return YES;
        if (controller == shown) break;
    }
    return NO;
}

- (void)selectIndex:(NSUInteger)index {
    if (index >= _controllers.count) return;
    if (index == _selected) {
        [[self selectedNavigation] popToRootViewControllerAnimated:YES];
        return;
    }
    UINavigationController *old = [self selectedNavigation];
    if (old) {
        [old willMoveToParentViewController:nil];
        [old.view removeFromSuperview];
        [old removeFromParentViewController];
    }
    _selected = index;
    UINavigationController *next = [self selectedNavigation];
    [self addChildViewController:next];
    _barHidden = [self barHiddenFor:next upTo:next.topViewController];
    [self layoutContent];
    [self.view insertSubview:next.view belowSubview:_accessory ? _accessory : _bar];
    [next didMoveToParentViewController:self];
    [(RewindChromeTabBar *)_bar setSelected:index];
}

- (void)layoutContent {
    CGRect bounds = self.view.bounds;
    CGFloat top = RewindStatusBarInset();
    CGFloat barHeight = RewindChromeTabHeight + RewindBottomSafeInset();
    BOOL accessory = _accessory && _accessoryShown && !_barHidden;
    CGFloat bottom = _barHidden ? 0.0f : barHeight + (accessory ? _accessoryHeight : 0.0f);
    [self selectedNavigation].view.frame = CGRectMake(0.0f, top, bounds.size.width, bounds.size.height - top - bottom);
    CGFloat barTop = bounds.size.height - (_barHidden ? 0.0f : barHeight);
    _bar.frame = CGRectMake(0.0f, barTop, bounds.size.width, barHeight);
    /* the strip slides down behind the bar rather than off the screen edge */
    _accessory.frame = CGRectMake(0.0f, accessory ? barTop - _accessoryHeight : barTop, bounds.size.width, _accessoryHeight);
    _accessory.alpha = accessory ? 1.0f : 0.0f;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutContent];
}

- (void)navigationController:(UINavigationController *)navigation willShowViewController:(UIViewController *)shown
                    animated:(BOOL)animated {
    if (navigation != [self selectedNavigation]) return;
    BOOL hidden = [self barHiddenFor:navigation upTo:shown];
    if (hidden == _barHidden) return;
    _barHidden = hidden;
    if (!animated) {
        [self layoutContent];
        return;
    }
    [UIView animateWithDuration:0.3 animations:^{ [self layoutContent]; }];
}

@end
