#import "rewind_ui.h"

#import <QuartzCore/QuartzCore.h>
#include <objc/message.h>

#import "rewind_api.h"
#import "rewind_image_cache.h"
#import "rewind_theme.h"
#import "rewind_l10n.h"

void RewindAnimate(NSTimeInterval duration, void (^animations)(void), void (^completion)(BOOL finished)) {
    [UIView animateWithDuration:duration delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:animations completion:completion];
}

void RewindSpring(NSTimeInterval duration, void (^animations)(void), void (^completion)(BOOL finished)) {
    SEL spring = NSSelectorFromString(@"animateWithDuration:delay:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:");
    /* the armv7 sdk predates the spring api, so it is reached through the runtime on ios 7 and later */
    if ([UIView respondsToSelector:spring]) {
        typedef void (*spring_fn)(id, SEL, NSTimeInterval, NSTimeInterval, CGFloat, CGFloat,
                                  UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
        ((spring_fn)objc_msgSend)([UIView class], spring, duration, 0.0, 0.82f, 0.0f,
                                  UIViewAnimationOptionBeginFromCurrentState |
                                  UIViewAnimationOptionAllowUserInteraction,
                                  animations, completion);
        return;
    }
    RewindAnimate(duration, animations, completion);
}

NSString *RewindImageURLForSize(NSString *url, CGFloat pixels) {
    if (!url.length) return nil;
    int size = (int)MAX(60.0f, ceilf(pixels));
    NSRange host = [url rangeOfString:@"googleusercontent.com"];
    if (host.location == NSNotFound) host = [url rangeOfString:@"ggpht.com"];
    if (host.location != NSNotFound) {
        NSRegularExpression *wh = [NSRegularExpression regularExpressionWithPattern:@"=w\\d+-h\\d+"
                                                                            options:0 error:NULL];
        NSString *out = [wh stringByReplacingMatchesInString:url options:0 range:NSMakeRange(0, url.length)
                                                withTemplate:[NSString stringWithFormat:@"=w%d-h%d", size, size]];
        NSRegularExpression *sq = [NSRegularExpression regularExpressionWithPattern:@"=s\\d+"
                                                                            options:0 error:NULL];
        return [sq stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length)
                                       withTemplate:[NSString stringWithFormat:@"=s%d", size]];
    }
    /* hqdefault letterboxes 16:9 video inside 4:3, which shows black bars in a square crop */
    NSRegularExpression *ytimg = [NSRegularExpression
        regularExpressionWithPattern:@"^(https?://i\\d?\\.ytimg\\.com/vi(?:_webp)?/[A-Za-z0-9_-]{11}/)[a-z0-9]+\\.(?:jpg|webp)(\\?.*)?$"
                             options:0 error:NULL];
    NSTextCheckingResult *match = [ytimg firstMatchInString:url options:0 range:NSMakeRange(0, url.length)];
    if (match) {
        NSString *base = [[url substringWithRange:[match rangeAtIndex:1]]
                          stringByReplacingOccurrencesOfString:@"/vi_webp/" withString:@"/vi/"];
        return [base stringByAppendingString:size <= 320 ? @"mqdefault.jpg" : @"hq720.jpg"];
    }
    return url;
}

@implementation RewindPressControl

@synthesize pressScales = _pressScales;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _pressScales = YES;
    self.exclusiveTouch = YES;
    [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)dealloc {
    [_onTap release];
    [super dealloc];
}

- (void)setOnTap:(RewindAction)onTap {
    if (_onTap == onTap) return;
    [_onTap release];
    _onTap = [onTap copy];
}

- (void)tapped {
    if (_onTap) _onTap();
}

- (void)setHighlighted:(BOOL)highlighted {
    BOOL changed = highlighted != self.highlighted;
    [super setHighlighted:highlighted];
    if (!changed || !_pressScales) return;
    if (highlighted) {
        RewindAnimate(0.10, ^{
            self.transform = CGAffineTransformMakeScale(0.96f, 0.96f);
            self.alpha = 0.82f;
        }, nil);
    } else {
        RewindSpring(0.35, ^{
            self.transform = CGAffineTransformIdentity;
            self.alpha = 1.0f;
        }, nil);
    }
}

@end

@implementation RewindScrollView
- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    (void)view;
    return YES;
}
@end

@implementation RewindTableView
- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    (void)view;
    return YES;
}
@end


@implementation RewindIconButton

+ (RewindIconButton *)buttonWithIcon:(NSString *)name points:(CGFloat)points {
    RewindIconButton *button = [[[RewindIconButton alloc] initWithFrame:CGRectZero] autorelease];
    button->_iconPoints = points;
    [button setIconName:name];
    return button;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.pressScales = NO;
    _iconColor = [RewindColorText() retain];
    _halo = [[UIView alloc] initWithFrame:CGRectZero];
    _halo.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.14f];
    _halo.alpha = 0.0f;
    _halo.userInteractionEnabled = NO;
    [self addSubview:_halo];
    _icon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _icon.contentMode = UIViewContentModeCenter;
    [self addSubview:_icon];
    return self;
}

- (void)dealloc {
    [_icon release];
    [_halo release];
    [_iconName release];
    [_iconColor release];
    [super dealloc];
}

- (void)refreshIcon {
    _icon.image = RewindIcon(_iconName, _iconPoints > 0.0f ? _iconPoints : RW(24.0f), _iconColor);
}

- (void)setIconName:(NSString *)name {
    if ([_iconName isEqualToString:name]) return;
    [_iconName release];
    _iconName = [name copy];
    [self refreshIcon];
}

- (void)setIconColor:(UIColor *)color {
    [_iconColor release];
    _iconColor = [color retain];
    [self refreshIcon];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _icon.frame = self.bounds;
    CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);
    _halo.frame = CGRectMake(floorf((self.bounds.size.width - side) * 0.5f),
                             floorf((self.bounds.size.height - side) * 0.5f), side, side);
    _halo.layer.cornerRadius = side * 0.5f;
}

/* youtube music circles the icon while it is held instead of shrinking it */
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    RewindAnimate(highlighted ? 0.08 : 0.25, ^{
        _halo.alpha = highlighted ? 1.0f : 0.0f;
    }, nil);
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.alpha = enabled ? 1.0f : 0.35f;
}

@end

@implementation RewindPillButton

- (id)initWithStyle:(RewindPillStyle)style icon:(NSString *)icon title:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _style = style;
    _icon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _icon.contentMode = UIViewContentModeCenter;
    [self addSubview:_icon];
    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.backgroundColor = [UIColor clearColor];
    _label.font = RewindFont(14.0f, RewindWeightMedium);
    [self addSubview:_label];
    [self setIconName:icon];
    [self setTitle:title];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged:)
                                                 name:RewindThemeDidChangeNotification object:nil];
    [self refreshStyle];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_icon release];
    [_label release];
    [_iconName release];
    [super dealloc];
}

- (void)themeChanged:(NSNotification *)note {
    (void)note;
    [self refreshStyle];
    [self setNeedsLayout];
    [self.superview setNeedsLayout];
}

- (void)refreshStyle {
    _label.font = RewindFont(14.0f, RewindWeightMedium);
    _label.textColor = _style == RewindPillStyleLight ? RewindColorOnAccent() : RewindColorText();
    /* the filled pill sits on the artwork tinted player, a solid grey plate hides that tint */
    self.backgroundColor = _style == RewindPillStyleLight ? RewindColorAccentFill()
        : (_style == RewindPillStyleFilled ? [UIColor colorWithWhite:1.0f alpha:0.14f] : [UIColor clearColor]);
    self.layer.borderWidth = _style == RewindPillStyleOutlined ? 1.0f : 0.0f;
    self.layer.borderColor = RewindColorDivider().CGColor;
    _icon.image = _iconName ? RewindIcon(_iconName, RW(22.0f), _label.textColor) : nil;
}

- (void)setTitle:(NSString *)title {
    _label.text = title;
    [self setNeedsLayout];
}

- (void)setIconName:(NSString *)icon {
    [_iconName release];
    _iconName = [icon copy];
    _icon.image = icon ? RewindIcon(icon, RW(22.0f), _label.textColor ?: RewindColorText()) : nil;
    [self setNeedsLayout];
}

- (CGFloat)preferredWidthForHeight:(CGFloat)height {
    CGFloat pad = RW(16.0f);
    CGFloat width = pad * 2.0f;
    if (_icon.image) width += _icon.image.size.width + (_label.text.length ? RW(8.0f) : 0.0f);
    width += RewindTextSize(_label.text, _label.font, 400.0f).width;
    return MAX(width, height);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    self.layer.cornerRadius = b.size.height * 0.5f;
    [self refreshStyle];
    CGFloat iconW = _icon.image ? _icon.image.size.width : 0.0f;
    CGFloat textW = RewindTextSize(_label.text, _label.font, 400.0f).width;
    CGFloat gap = iconW > 0.0f && textW > 0.0f ? RW(8.0f) : 0.0f;
    textW = MIN(textW, MAX(0.0f, b.size.width - RW(24.0f) - iconW - gap));
    CGFloat x = MAX(0.0f, floorf((b.size.width - iconW - gap - textW) * 0.5f));
    _icon.frame = CGRectMake(x, 0.0f, iconW, b.size.height);
    _label.frame = CGRectMake(x + iconW + gap, 0.0f, MIN(textW, MAX(0.0f, b.size.width - x - iconW - gap)), b.size.height);
}

@end

@implementation RewindMarqueeLabel

static const CGFloat RewindMarqueeSpeed = 36.0f;
/* separate consecutive copies so the title stays readable */
static const CGFloat RewindMarqueeGap = 40.0f;
/* hold the title still before scrolling */
static const CGFloat RewindMarqueeHold = 1.4;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.clipsToBounds = YES;
    self.backgroundColor = [UIColor clearColor];
    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.backgroundColor = [UIColor clearColor];
    _label.numberOfLines = 1;
    _label.lineBreakMode = NSLineBreakByClipping;
    [self addSubview:_label];
    _labelCopy = [[UILabel alloc] initWithFrame:CGRectZero];
    _labelCopy.backgroundColor = [UIColor clearColor];
    _labelCopy.numberOfLines = 1;
    _labelCopy.lineBreakMode = NSLineBreakByClipping;
    _labelCopy.hidden = YES;
    [self addSubview:_labelCopy];
    return self;
}

- (void)dealloc {
    [_label release];
    [_labelCopy release];
    [_text release];
    [super dealloc];
}

- (UIFont *)font {
    return _label.font;
}

- (void)setFont:(UIFont *)font {
    _label.font = font;
    _labelCopy.font = font;
    [self restart];
}

- (void)setTextColor:(UIColor *)color {
    _label.textColor = color;
    _labelCopy.textColor = color;
}

- (void)setText:(NSString *)text {
    if (_text == text || [_text isEqualToString:text]) return;
    [_text release];
    _text = [text copy];
    _label.text = _text;
    _labelCopy.text = _text;
    [self restart];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self restart];
}

/* space the second copy by one lap so it replaces the first when the animation wraps */
- (void)restart {
    [_label.layer removeAnimationForKey:@"marquee"];
    [_labelCopy.layer removeAnimationForKey:@"marquee"];
    CGFloat height = self.bounds.size.height;
    CGSize natural = _label.text.length && _label.font
        ? [_label sizeThatFits:CGSizeMake(CGFLOAT_MAX, height)]
        : CGSizeZero;
    CGFloat overflow = natural.width - self.bounds.size.width;
    _scrolling = overflow > 1.0f && self.bounds.size.width > 0.0f;
    if (!_scrolling) {
        _label.frame = CGRectMake(0.0f, 0.0f, self.bounds.size.width, height);
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        _labelCopy.hidden = YES;
        return;
    }
    _label.lineBreakMode = NSLineBreakByClipping;
    _label.frame = CGRectMake(0.0f, 0.0f, natural.width, height);
    CGFloat lap = natural.width + RewindMarqueeGap;
    _labelCopy.hidden = NO;
    _labelCopy.frame = CGRectMake(lap, 0.0f, natural.width, height);

    CGFloat duration = lap / RewindMarqueeSpeed;
    CAKeyframeAnimation *drift = [CAKeyframeAnimation animationWithKeyPath:@"position.x"];
    drift.values = [NSArray arrayWithObjects:[NSNumber numberWithFloat:0.0f],
                    [NSNumber numberWithFloat:0.0f],
                    [NSNumber numberWithFloat:-lap], nil];
    CGFloat holdFraction = RewindMarqueeHold / (RewindMarqueeHold + duration);
    drift.keyTimes = [NSArray arrayWithObjects:[NSNumber numberWithFloat:0.0f],
                      [NSNumber numberWithFloat:holdFraction],
                      [NSNumber numberWithFloat:1.0f], nil];
    drift.duration = RewindMarqueeHold + duration;
    drift.repeatCount = HUGE_VALF;
    drift.removedOnCompletion = NO;
    drift.additive = YES;
    [_label.layer addAnimation:drift forKey:@"marquee"];
    [_labelCopy.layer addAnimation:drift forKey:@"marquee"];
}

@end

@implementation RewindArtworkView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = RewindColorPlaceholder();
    self.clipsToBounds = YES;
    /* artwork fills the cards it sits in; taking touches here swallowed the card's tap */
    self.userInteractionEnabled = NO;
    _placeholder = [[UIImageView alloc] initWithFrame:CGRectZero];
    _placeholder.contentMode = UIViewContentModeCenter;
    [self addSubview:_placeholder];
    _imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _imageView.contentMode = UIViewContentModeScaleAspectFill;
    _imageView.clipsToBounds = YES;
    [self addSubview:_imageView];
    return self;
}

- (void)dealloc {
    [_imageView release];
    [_placeholder release];
    [_urls release];
    [super dealloc];
}

- (UIImage *)image {
    return _imageView.image;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.clipsToBounds = YES;
    self.layer.borderWidth = 0.0f;
    self.layer.shadowOpacity = 0.0f;
    self.layer.shadowPath = nil;
    _imageView.frame = self.bounds;
    _placeholder.frame = self.bounds;
    /* a second image mask doubles offscreen passes while scrolling on the 4s */
    _imageView.clipsToBounds = NO;
    _imageView.layer.cornerRadius = 0.0f;
    _placeholder.layer.cornerRadius = 0.0f;
    _placeholder.layer.masksToBounds = NO;
    /* a rounded clip is redrawn every frame unless the finished card is kept as a bitmap */
    self.layer.shouldRasterize = self.layer.cornerRadius > 0.0f;
    self.layer.rasterizationScale = [UIScreen mainScreen].scale;
    CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);
    if (side > 1.0f && !_placeholder.image)
        _placeholder.image = RewindIcon(@"note", floorf(side * 0.4f), RewindColorTextTertiary());
}

- (void)setCornerRadius:(CGFloat)radius {
    self.layer.cornerRadius = radius;
    [self setNeedsLayout];
}

- (void)setImage:(UIImage *)image {
    ++_generation;
    [_urls release];
    _urls = nil;
    _imageView.image = image;
    _imageView.alpha = 1.0f;
}

- (void)loadAttempt:(NSUInteger)generation pixels:(CGFloat)pixels {
    if (generation != _generation || _attempt >= _urls.count) return;
    NSString *url = [_urls objectAtIndex:_attempt];
    __block BOOL synchronous = YES;
    RewindLoadImageSized(url, pixels, ^(UIImage *image) {
        if (generation != _generation) return;
        if (!image) {
            ++_attempt;
            [self loadAttempt:generation pixels:pixels];
            return;
        }
        _imageView.image = image;
        /* cached images arrive inside this call; fading those would flicker while scrolling */
        if (synchronous) {
            _imageView.alpha = 1.0f;
        } else {
            _imageView.alpha = 0.0f;
            RewindAnimate(0.25, ^{ _imageView.alpha = 1.0f; }, nil);
        }
    });
    synchronous = NO;
}

- (void)setURL:(NSString *)url {
    ++_generation;
    _imageView.image = nil;
    _attempt = 0;
    CGFloat side = MAX(self.bounds.size.width, self.bounds.size.height);
    /* the player sets artwork before its first layout; request enough pixels for its final square */
    if (side <= 1.0f) {
        CGSize screen = [UIScreen mainScreen].bounds.size;
        side = RewindIsPad() ? 480.0f : MIN(screen.width, screen.height);
    }
    CGFloat pixels = side * [UIScreen mainScreen].scale;
    NSMutableArray *urls = [NSMutableArray array];
    NSString *sized = RewindImageURLForSize(url, pixels);
    if (sized.length) [urls addObject:sized];
    if (url.length && ![url isEqualToString:sized]) [urls addObject:url];
    [_urls release];
    _urls = [urls copy];
    [self loadAttempt:_generation pixels:pixels];
}

@end

@implementation RewindChipBar

@synthesize selectedIndex = _selectedIndex;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.showsHorizontalScrollIndicator = NO;
    self.alwaysBounceHorizontal = YES;
    self.alwaysBounceVertical = NO;
    self.directionalLockEnabled = YES;
    self.scrollsToTop = NO;
    _chips = [[NSMutableArray alloc] init];
    _selectedIndex = -1;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged:)
                                                 name:RewindThemeDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_chips release];
    [_onSelect release];
    [super dealloc];
}

/* restyle cached chips when the theme changes */
- (void)themeChanged:(NSNotification *)note {
    (void)note;
    for (UIButton *chip in _chips) [self styleChip:chip selected:chip.tag == _selectedIndex];
}

- (void)setOnSelect:(void (^)(NSInteger))onSelect {
    [_onSelect release];
    _onSelect = [onSelect copy];
}

/* match the row and content heights to prevent vertical scrolling */
static CGFloat RewindChipHeight(void) { return RW(32.0f); }
static CGFloat RewindChipTopPadding(void) { return RW(12.0f); }

- (CGFloat)preferredHeight {
    return RewindChipHeight() + RewindChipTopPadding() * 2.0f;
}

- (void)styleChip:(UIButton *)chip selected:(BOOL)selected {
    chip.backgroundColor = selected ? RewindColorText() : RewindColorOverlay();
    [chip setTitleColor:selected ? RewindColorBackground() : RewindColorText() forState:UIControlStateNormal];
    chip.titleLabel.font = RewindFont(14.0f, RewindWeightMedium);
}

- (void)setTitles:(NSArray *)titles {
    for (UIView *chip in _chips) [chip removeFromSuperview];
    [_chips removeAllObjects];
    _selectedIndex = -1;
    CGFloat x = RW(16.0f), height = RewindChipHeight(), top = RewindChipTopPadding();
    UIFont *font = RewindFont(14.0f, RewindWeightMedium);
    NSInteger index = 0;
    for (NSString *title in titles) {
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
        chip.titleLabel.font = font;
        [chip setTitle:title forState:UIControlStateNormal];
        chip.layer.cornerRadius = RW(8.0f);
        chip.tag = index++;
        CGFloat width = RewindTextSize(title, font, 400.0f).width + RW(24.0f);
        chip.frame = CGRectMake(x, top, width, height);
        [chip addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self styleChip:chip selected:NO];
        [self addSubview:chip];
        [_chips addObject:chip];
        x += width + RW(8.0f);
    }
    self.contentSize = CGSizeMake(x - RW(8.0f) + RW(16.0f), [self preferredHeight]);
}

- (void)setSelectedIndex:(NSInteger)index animated:(BOOL)animated {
    _selectedIndex = index;
    void (^apply)(void) = ^{
        for (UIButton *chip in _chips) [self styleChip:chip selected:chip.tag == index];
    };
    if (animated) [UIView transitionWithView:self duration:0.2
                                     options:UIViewAnimationOptionTransitionCrossDissolve
                                  animations:apply completion:nil];
    else apply();
}

- (void)chipTapped:(UIButton *)chip {
    NSInteger index = chip.tag == _selectedIndex ? -1 : chip.tag;
    [self setSelectedIndex:index animated:YES];
    if (_onSelect) _onSelect(index);
}

@end

@implementation RewindSectionHeader

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _tapArea = [[RewindPressControl alloc] initWithFrame:CGRectZero];
    _tapArea.pressScales = NO;
    _tapArea.userInteractionEnabled = NO;
    [self addSubview:_tapArea];
    _avatar = [[RewindArtworkView alloc] initWithFrame:CGRectZero];
    _avatar.hidden = YES;
    _avatar.userInteractionEnabled = NO;
    [self addSubview:_avatar];
    _caption = [[UILabel alloc] initWithFrame:CGRectZero];
    _caption.backgroundColor = [UIColor clearColor];
    _caption.font = RewindFont(14.0f, RewindWeightRegular);
    _caption.textColor = RewindColorTextSecondary();
    [self addSubview:_caption];
    _title = [[UILabel alloc] initWithFrame:CGRectZero];
    _title.backgroundColor = [UIColor clearColor];
    _title.font = RewindFont(24.0f, RewindWeightBold);
    _title.textColor = RewindColorHeading();
    /* shrinking roboto to fit squeezed the glyphs together on ios 5; long titles wrap instead */
    _title.numberOfLines = 2;
    _title.lineBreakMode = NSLineBreakByWordWrapping;
    [self addSubview:_title];
    _chevron = [[UIImageView alloc] initWithImage:RewindIcon(@"chevron-right", RW(28.0f), RewindColorText())];
    _chevron.hidden = YES;
    [self addSubview:_chevron];
    return self;
}

- (void)dealloc {
    [_avatar release];
    [_caption release];
    [_title release];
    [_more release];
    [_chevron release];
    [_tapArea release];
    [super dealloc];
}

- (void)setTitle:(NSString *)title caption:(NSString *)caption avatarURL:(NSString *)avatar {
    _title.text = title;
    _caption.text = [caption uppercaseString];
    _avatar.hidden = !avatar.length;
    if (avatar.length) [_avatar setURL:avatar];
    [self setNeedsLayout];
}

- (void)setMoreTitle:(NSString *)title action:(RewindAction)action {
    [_more removeFromSuperview];
    [_more release];
    _more = nil;
    if (title.length) {
        _more = [[RewindPillButton alloc] initWithStyle:RewindPillStyleOutlined icon:nil title:title];
        [_more setOnTap:action];
        [self addSubview:_more];
    }
    [self setNeedsLayout];
}

- (void)setChevronAction:(RewindAction)action {
    _chevron.hidden = action == nil;
    _tapArea.userInteractionEnabled = action != nil;
    [_tapArea setOnTap:action];
}

- (CGFloat)textLeftForWidth:(CGFloat)width {
    (void)width;
    return _avatar.hidden ? RW(16.0f) : RW(16.0f) + RW(36.0f) + RW(12.0f);
}

- (CGFloat)textRightForWidth:(CGFloat)width {
    CGFloat right = width - RW(16.0f);
    if (_more) right -= [_more preferredWidthForHeight:RW(32.0f)] + RW(12.0f);
    else if (!_chevron.hidden) right -= _chevron.image.size.width;
    return right;
}

- (CGFloat)titleHeightForWidth:(CGFloat)width {
    CGFloat textW = MAX(RW(60.0f), [self textRightForWidth:width] - [self textLeftForWidth:width]);
    CGFloat lineH = ceilf(_title.font.lineHeight);
    CGFloat textH = RewindTextSize(_title.text, _title.font, textW).height;
    return MIN(lineH * 2.0f, MAX(lineH, textH));
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    CGFloat captionH = _caption.text.length ? ceilf(_caption.font.lineHeight) : 0.0f;
    CGFloat content = captionH + [self titleHeightForWidth:width];
    CGFloat minimum = _avatar.hidden ? RW(40.0f) : RW(44.0f);
    return MAX(minimum, content) + RW(8.0f);
}

- (CGFloat)preferredHeight {
    return [self preferredHeightForWidth:self.bounds.size.width];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat side = RW(16.0f);
    _tapArea.frame = b;
    CGFloat x = side;
    if (!_avatar.hidden) {
        CGFloat a = RW(36.0f);
        _avatar.frame = CGRectMake(side, floorf((b.size.height - a) * 0.5f) + RW(2.0f), a, a);
        [_avatar setCornerRadius:a * 0.5f];
        x = CGRectGetMaxX(_avatar.frame) + RW(12.0f);
    }
    CGFloat right = b.size.width - side;
    if (_more) {
        CGFloat h = RW(32.0f);
        CGFloat w = [_more preferredWidthForHeight:h];
        _more.frame = CGRectMake(right - w, floorf((b.size.height - h) * 0.5f), w, h);
        right = CGRectGetMinX(_more.frame) - RW(8.0f);
    } else if (!_chevron.hidden) {
        CGSize c = _chevron.image.size;
        _chevron.frame = CGRectMake(right - c.width + RW(6.0f), floorf((b.size.height - c.height) * 0.5f),
                                    c.width, c.height);
        right = CGRectGetMinX(_chevron.frame) - RW(4.0f);
    }
    CGFloat titleH = [self titleHeightForWidth:b.size.width];
    if (_caption.text.length) {
        CGFloat captionH = ceilf(_caption.font.lineHeight);
        CGFloat top = floorf((b.size.height - captionH - titleH) * 0.5f);
        _caption.frame = CGRectMake(x, top, right - x, captionH);
        _title.frame = CGRectMake(x, top + captionH, right - x, titleH);
    } else {
        _caption.frame = CGRectZero;
        _title.frame = CGRectMake(x, floorf((b.size.height - titleH) * 0.5f), right - x, titleH);
    }
}

@end

@implementation RewindPageDots

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _dots = [[NSMutableArray alloc] init];
    self.userInteractionEnabled = NO;
    return self;
}

- (void)dealloc {
    [_dots release];
    [super dealloc];
}

- (void)setCount:(NSUInteger)count {
    while (_dots.count > count) {
        [[_dots lastObject] removeFromSuperview];
        [_dots removeLastObject];
    }
    while (_dots.count < count) {
        UIView *dot = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
        [self addSubview:dot];
        [_dots addObject:dot];
    }
    self.hidden = count < 2;
    [self setCurrent:MIN(_current, count ? count - 1 : 0)];
    [self setNeedsLayout];
}

- (NSUInteger)current { return _current; }

- (void)setCurrent:(NSUInteger)current {
    _current = current;
    RewindAnimate(0.2, ^{
        for (NSUInteger index = 0; index < _dots.count; ++index)
            [[_dots objectAtIndex:index] setBackgroundColor:index == current
                ? [UIColor colorWithWhite:0.945f alpha:1.0f] : [UIColor colorWithWhite:0.30f alpha:1.0f]];
    }, nil);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat d = RW(8.0f), gap = RW(5.0f);
    CGFloat total = _dots.count * d + (_dots.count ? (_dots.count - 1) * gap : 0.0f);
    CGFloat x = floorf((self.bounds.size.width - total) * 0.5f);
    for (UIView *dot in _dots) {
        dot.frame = CGRectMake(x, floorf((self.bounds.size.height - d) * 0.5f), d, d);
        dot.layer.cornerRadius = d * 0.5f;
        x += d + gap;
    }
}

@end

@implementation RewindEqualizerView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    _bars = [[NSMutableArray alloc] init];
    for (int index = 0; index < 3; ++index) {
        CALayer *bar = [CALayer layer];
        bar.backgroundColor = [UIColor whiteColor].CGColor;
        bar.anchorPoint = CGPointMake(0.5f, 1.0f);
        [self.layer addSublayer:bar];
        [_bars addObject:bar];
    }
    return self;
}

- (void)dealloc {
    [_bars release];
    [super dealloc];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = RW(3.0f), gap = RW(2.0f);
    CGFloat total = w * 3.0f + gap * 2.0f;
    CGFloat x = floorf((self.bounds.size.width - total) * 0.5f);
    CGFloat h = floorf(self.bounds.size.height * 0.5f);
    CGFloat bottom = floorf((self.bounds.size.height + h) * 0.5f);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *bar in _bars) {
        bar.bounds = CGRectMake(0.0f, 0.0f, w, h);
        bar.position = CGPointMake(x + w * 0.5f, bottom);
        x += w + gap;
    }
    [CATransaction commit];
}

- (void)setAnimating:(BOOL)animating {
    if (_animating == animating) return;
    _animating = animating;
    NSUInteger index = 0;
    for (CALayer *bar in _bars) {
        if (!animating) {
            [bar removeAllAnimations];
            bar.transform = CATransform3DMakeScale(1.0f, index == 1 ? 0.8f : 0.45f, 1.0f);
        } else {
            CABasicAnimation *bounce = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
            bounce.fromValue = [NSNumber numberWithFloat:0.25f];
            bounce.toValue = [NSNumber numberWithFloat:1.0f];
            bounce.duration = 0.34 + 0.11 * index;
            bounce.autoreverses = YES;
            bounce.repeatCount = HUGE_VALF;
            bounce.timeOffset = 0.13 * index;
            bounce.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [bar addAnimation:bounce forKey:@"bounce"];
        }
        ++index;
    }
}

@end

@implementation RewindTrackRow

@synthesize track = _track;

+ (CGFloat)rowHeight {
    return RW(72.0f);
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.pressScales = NO;
    _artwork = [[RewindArtworkView alloc] initWithFrame:CGRectZero];
    [_artwork setCornerRadius:RW(4.0f)];
    _artwork.userInteractionEnabled = NO;
    [self addSubview:_artwork];
    _playingShade = [[UIView alloc] initWithFrame:CGRectZero];
    _playingShade.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.5f];
    _playingShade.hidden = YES;
    _playingShade.userInteractionEnabled = NO;
    [self addSubview:_playingShade];
    _equalizer = [[RewindEqualizerView alloc] initWithFrame:CGRectZero];
    [_playingShade addSubview:_equalizer];
    _title = [[UILabel alloc] initWithFrame:CGRectZero];
    _title.backgroundColor = [UIColor clearColor];
    _title.font = RewindFont(16.0f, RewindWeightRegular);
    _title.textColor = RewindColorText();
    _title.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_title];
    _detail = [[UILabel alloc] initWithFrame:CGRectZero];
    _detail.backgroundColor = [UIColor clearColor];
    _detail.font = RewindFont(14.0f, RewindWeightRegular);
    _detail.textColor = RewindColorTextSecondary();
    _detail.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_detail];
    _more = [[RewindIconButton buttonWithIcon:@"more" points:RW(24.0f)] retain];
    [self addSubview:_more];
    return self;
}

- (void)dealloc {
    [_artwork release];
    [_playingShade release];
    [_equalizer release];
    [_title release];
    [_detail release];
    [_explicit release];
    [_more release];
    [_track release];
    [super dealloc];
}

/* a highlight band like the youtube music list instead of a shrinking row */
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    RewindAnimate(highlighted ? 0.05 : 0.3, ^{
        self.backgroundColor = highlighted ? RewindColorSurface() : [UIColor clearColor];
    }, nil);
}

- (void)setOnMore:(RewindAction)onMore {
    [_more setOnTap:onMore];
    _more.hidden = onMore == nil;
}

- (void)setRoundArtwork:(BOOL)round {
    _roundArtwork = round;
    [self setNeedsLayout];
}

- (void)setTrack:(RewindTrack *)track {
    [_track release];
    _track = [track retain];
    _title.text = track.title;
    NSString *detail = track.detail.length ? track.detail : RewindTrackArtistText(track);
    if (!track.detail.length && track.album.length && !track.isPlaylist)
        detail = [NSString stringWithFormat:@"%@ • %@", detail, track.album];
    _detail.text = detail;
    [_artwork setURL:track.thumbnailURL.length ? track.thumbnailURL
                    : (track.videoID.length ? [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg",
                                               track.videoID] : nil)];
    [self setNeedsLayout];
}

- (void)setPlaying:(BOOL)playing animating:(BOOL)animating {
    _playingShade.hidden = !playing;
    [_equalizer setAnimating:playing && animating];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat side = RW(16.0f);
    CGFloat art = RW(56.0f);
    _artwork.frame = CGRectMake(side, floorf((b.size.height - art) * 0.5f), art, art);
    [_artwork setCornerRadius:_roundArtwork ? art * 0.5f : RW(4.0f)];
    _playingShade.frame = _artwork.frame;
    _playingShade.layer.cornerRadius = _artwork.layer.cornerRadius;
    _equalizer.frame = _playingShade.bounds;
    CGFloat moreW = _more.hidden ? 0.0f : RW(44.0f);
    _more.frame = CGRectMake(b.size.width - moreW - RW(4.0f), floorf((b.size.height - RW(44.0f)) * 0.5f),
                             moreW, RW(44.0f));
    CGFloat x = CGRectGetMaxX(_artwork.frame) + RW(16.0f);
    CGFloat w = MAX(20.0f, (_more.hidden ? b.size.width - side : CGRectGetMinX(_more.frame)) - x);
    CGFloat titleH = ceilf(_title.font.lineHeight), detailH = ceilf(_detail.font.lineHeight);
    CGFloat top = floorf((b.size.height - titleH - detailH - RW(2.0f)) * 0.5f);
    _title.frame = CGRectMake(x, top, w, titleH);
    _detail.frame = CGRectMake(x, top + titleH + RW(2.0f), w, detailH);
}

@end

@implementation RewindSheetItem

@synthesize icon = _icon;
@synthesize title = _title;
@synthesize action = _action;

+ (RewindSheetItem *)itemWithIcon:(NSString *)icon title:(NSString *)title action:(RewindAction)action {
    RewindSheetItem *item = [[[RewindSheetItem alloc] init] autorelease];
    item->_icon = [icon copy];
    item->_title = [title copy];
    item->_action = [action copy];
    return item;
}

- (void)dealloc {
    [_icon release];
    [_title release];
    [_action release];
    [super dealloc];
}

@end

/* frame is undefined while a press control is scaled, bounds and center stay usable */
static void rewind_sheet_set_rect(UIView *view, CGRect rect) {
    view.bounds = CGRectMake(0.0f, 0.0f, rect.size.width, rect.size.height);
    view.center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
}

@implementation RewindSheet

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _dim = [[UIView alloc] initWithFrame:CGRectZero];
    _dim.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.6f];
    _dim.alpha = 0.0f;
    [_dim addGestureRecognizer:[[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(dismiss)] autorelease]];
    [self addSubview:_dim];
    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    _panel.backgroundColor = RewindColorBackground();
    _panel.layer.cornerRadius = RW(12.0f);
    [_panel addGestureRecognizer:[[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(panned:)] autorelease]];
    [self addSubview:_panel];
    _scroll = [[RewindScrollView alloc] initWithFrame:CGRectZero];
    _scroll.showsVerticalScrollIndicator = NO;
    [_panel addSubview:_scroll];
    _tiles = [[NSMutableArray alloc] init];
    _items = [[NSMutableArray alloc] init];
    return self;
}

- (void)dealloc {
    [_dim release];
    [_panel release];
    [_scroll release];
    [_header release];
    [_tiles release];
    [_items release];
    [super dealloc];
}

- (void)setHeaderTitle:(NSString *)title subtitle:(NSString *)subtitle accessories:(NSArray *)accessoryButtons {
    [_header removeFromSuperview];
    [_header release];
    _header = [[UIView alloc] initWithFrame:CGRectZero];
    UILabel *titleLabel = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    titleLabel.tag = 1;
    titleLabel.backgroundColor = [UIColor clearColor];
    titleLabel.font = RewindFont(18.0f, RewindWeightMedium);
    titleLabel.textColor = RewindColorText();
    titleLabel.text = title;
    [_header addSubview:titleLabel];
    UILabel *subtitleLabel = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    subtitleLabel.tag = 2;
    subtitleLabel.backgroundColor = [UIColor clearColor];
    subtitleLabel.font = RewindFont(15.0f, RewindWeightRegular);
    subtitleLabel.textColor = RewindColorTextSecondary();
    subtitleLabel.text = subtitle;
    [_header addSubview:subtitleLabel];
    NSInteger tag = 10;
    for (UIView *button in accessoryButtons) {
        button.tag = tag++;
        [_header addSubview:button];
    }
    UIView *divider = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    divider.tag = 3;
    divider.backgroundColor = RewindColorDivider();
    [_header addSubview:divider];
    [_panel addSubview:_header];
    _laidSize = CGSizeZero;
    [self setNeedsLayout];
}

- (UIView *)tileForItem:(RewindSheetItem *)item index:(NSUInteger)index {
    RewindPressControl *tile = [[[RewindPressControl alloc] initWithFrame:CGRectZero] autorelease];
    tile.tag = 100 + (NSInteger)index;
    UIView *plate = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    plate.tag = 1;
    plate.userInteractionEnabled = NO;
    plate.backgroundColor = RewindColorSurface();
    plate.layer.cornerRadius = RW(12.0f);
    [tile addSubview:plate];
    UIImageView *icon = [[[UIImageView alloc] initWithImage:RewindIcon(item.icon, RW(24.0f), RewindColorText())] autorelease];
    icon.tag = 2;
    icon.contentMode = UIViewContentModeCenter;
    [plate addSubview:icon];
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    label.tag = 3;
    label.backgroundColor = [UIColor clearColor];
    label.font = RewindFont(15.0f, RewindWeightRegular);
    label.textColor = RewindColorText();
    label.numberOfLines = 2;
    label.textAlignment = NSTextAlignmentCenter;
    label.text = item.title;
    [tile addSubview:label];
    [tile addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
    return tile;
}

- (UIView *)rowForItem:(RewindSheetItem *)item index:(NSUInteger)index {
    RewindPressControl *row = [[[RewindPressControl alloc] initWithFrame:CGRectZero] autorelease];
    row.pressScales = NO;
    row.tag = 1000 + (NSInteger)index;
    UIImageView *icon = [[[UIImageView alloc] initWithImage:RewindIcon(item.icon, RW(24.0f), RewindColorText())] autorelease];
    icon.tag = 2;
    icon.contentMode = UIViewContentModeCenter;
    [row addSubview:icon];
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    label.tag = 3;
    label.backgroundColor = [UIColor clearColor];
    label.font = RewindFont(16.0f, RewindWeightRegular);
    label.textColor = RewindColorText();
    label.text = item.title;
    [row addSubview:label];
    [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
    [row addTarget:self action:@selector(rowDown:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [row addTarget:self action:@selector(rowUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                                                                  UIControlEventTouchCancel | UIControlEventTouchDragExit];
    return row;
}

- (void)rowDown:(UIView *)row {
    row.backgroundColor = RewindColorSurface();
}

- (void)rowUp:(UIView *)row {
    RewindAnimate(0.3, ^{ row.backgroundColor = [UIColor clearColor]; }, nil);
}

- (void)setTiles:(NSArray *)items {
    for (UIView *tile in [_scroll subviews]) if (tile.tag < 1000 && [tile isKindOfClass:[RewindPressControl class]]) [tile removeFromSuperview];
    [_tiles removeAllObjects];
    [_tiles addObjectsFromArray:items];
    NSUInteger index = 0;
    for (RewindSheetItem *item in items) [_scroll addSubview:[self tileForItem:item index:index++]];
    _laidSize = CGSizeZero;
    [self setNeedsLayout];
}

- (void)setItems:(NSArray *)items {
    for (UIView *row in [_scroll subviews]) if (row.tag >= 1000) [row removeFromSuperview];
    [_items removeAllObjects];
    [_items addObjectsFromArray:items];
    NSUInteger index = 0;
    for (RewindSheetItem *item in items) [_scroll addSubview:[self rowForItem:item index:index++]];
    _laidSize = CGSizeZero;
    [self setNeedsLayout];
}

- (CGFloat)layoutContentForWidth:(CGFloat)width {
    CGFloat y = 0.0f;
    CGFloat side = RW(20.0f);
    if (_header) {
        CGFloat h = RW(72.0f);
        _header.frame = CGRectMake(0.0f, 0.0f, width, h);
        CGFloat right = width - RW(8.0f);
        for (UIView *button in [[_header subviews] reverseObjectEnumerator]) {
            if (button.tag < 10) continue;
            CGFloat s = RW(48.0f);
            button.frame = CGRectMake(right - s, floorf((h - s) * 0.5f), s, s);
            right -= s;
        }
        UILabel *title = (UILabel *)[_header viewWithTag:1];
        UILabel *subtitle = (UILabel *)[_header viewWithTag:2];
        CGFloat th = ceilf(title.font.lineHeight), sh = subtitle.text.length ? ceilf(subtitle.font.lineHeight) : 0.0f;
        CGFloat top = floorf((h - th - sh) * 0.5f);
        title.frame = CGRectMake(side, top, right - side, th);
        subtitle.frame = CGRectMake(side, top + th, right - side, sh);
        [_header viewWithTag:3].frame = CGRectMake(0.0f, h - 1.0f, width, 1.0f);
        y = h;
    }
    _scroll.frame = CGRectMake(0.0f, y, width, 0.0f);
    CGFloat inner = 0.0f;
    if (_tiles.count) {
        inner += RW(20.0f);
        CGFloat gap = RW(12.0f);
        CGFloat tileW = floorf((width - side * 2.0f - gap * (_tiles.count - 1)) / _tiles.count);
        CGFloat plateH = RW(68.0f);
        CGFloat labelH = ceilf(RewindFont(15.0f, RewindWeightRegular).lineHeight * 2.0f);
        for (UIView *tile in [_scroll subviews]) {
            if (tile.tag >= 1000 || ![tile isKindOfClass:[RewindPressControl class]]) continue;
            rewind_sheet_set_rect(tile, CGRectMake(side + (tile.tag - 100) * (tileW + gap), inner,
                                    tileW, plateH + RW(10.0f) + labelH));
            UIView *plate = [tile viewWithTag:1];
            plate.frame = CGRectMake(0.0f, 0.0f, tileW, plateH);
            [plate viewWithTag:2].frame = plate.bounds;
            [tile viewWithTag:3].frame = CGRectMake(0.0f, plateH + RW(8.0f), tileW, labelH);
        }
        inner += plateH + RW(10.0f) + labelH + RW(12.0f);
    } else {
        inner += RW(8.0f);
    }
    CGFloat rowH = RW(54.0f);
    for (UIView *row in [_scroll subviews]) {
        if (row.tag < 1000) continue;
        row.frame = CGRectMake(0.0f, inner + (row.tag - 1000) * rowH, width, rowH);
        [row viewWithTag:2].frame = CGRectMake(side, 0.0f, RW(24.0f), rowH);
        [row viewWithTag:3].frame = CGRectMake(side + RW(24.0f) + RW(32.0f), 0.0f,
                                               width - side * 2.0f - RW(56.0f), rowH);
    }
    inner += _items.count * rowH + RW(12.0f);
    _scroll.contentSize = CGSizeMake(width, inner);
    return y + inner;
}

- (void)layoutPanelVisible:(BOOL)visible {
    CGRect b = self.bounds;
    _dim.frame = b;
    CGFloat inset = RW(8.0f);
    CGFloat width = MAX(0.0f, MIN(b.size.width - inset * 2.0f, 560.0f));
    CGFloat content = [self layoutContentForWidth:width];
    CGFloat maxH = MAX(0.0f, b.size.height - RewindStatusBarInset() - RW(64.0f));
    CGFloat visibleH = MIN(content, maxH);
    CGFloat radius = _panel.layer.cornerRadius;
    /* the panel runs past the bottom edge so only its top corners show rounded */
    rewind_sheet_set_rect(_panel, CGRectMake(floorf((b.size.width - width) * 0.5f),
                              visible ? b.size.height - visibleH : b.size.height,
                              width, visibleH + radius));
    CGFloat headerH = _header ? _header.frame.size.height : 0.0f;
    _scroll.frame = CGRectMake(0.0f, headerH, width, MAX(0.0f, visibleH - headerH));
    _scroll.scrollEnabled = content > maxH;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (CGSizeEqualToSize(_laidSize, self.bounds.size)) return;
    _laidSize = self.bounds.size;
    /* autoresizing changes only this view, so rotate the panel and its content here */
    [self layoutPanelVisible:_visible && !_dismissing];
    _panY = _panel.center.y - _panel.bounds.size.height * 0.5f;
    if (_visible && !_dismissing) _dim.alpha = 1.0f;
    for (UIGestureRecognizer *gesture in _panel.gestureRecognizers) {
        if ([gesture isKindOfClass:[UIPanGestureRecognizer class]])
            [(UIPanGestureRecognizer *)gesture setTranslation:CGPointZero inView:self];
    }
}

- (void)showNativeInView:(UIView *)host {
    NSString *title = ((UILabel *)[_header viewWithTag:1]).text;
    NSString *subtitle = ((UILabel *)[_header viewWithTag:2]).text;
    if (subtitle.length) title = title.length ? [NSString stringWithFormat:@"%@\n%@", title, subtitle] : subtitle;
    UIActionSheet *sheet = [[[UIActionSheet alloc] initWithTitle:title delegate:self cancelButtonTitle:nil
                                           destructiveButtonTitle:nil otherButtonTitles:nil] autorelease];
    sheet.actionSheetStyle = UIActionSheetStyleBlackOpaque;
    for (RewindSheetItem *item in _tiles) [sheet addButtonWithTitle:item.title];
    for (RewindSheetItem *item in _items) [sheet addButtonWithTitle:item.title];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:RewindL(@"cancel")];
    [self retain];
    /* ios 5 drops touches over the tab bar unless the sheet uses the full window */
    [sheet showInView:host.window ?: host];
}

- (void)actionSheet:(UIActionSheet *)sheet didDismissWithButtonIndex:(NSInteger)index {
    RewindAction action = nil;
    if (index >= 0 && index != sheet.cancelButtonIndex) {
        NSUInteger tiles = _tiles.count;
        RewindSheetItem *item = (NSUInteger)index < tiles ? [_tiles objectAtIndex:(NSUInteger)index]
            : ((NSUInteger)index - tiles < _items.count ? [_items objectAtIndex:(NSUInteger)index - tiles] : nil);
        action = [[item.action copy] autorelease];
    }
    if (action) action();
    [self release];
}

- (void)showInView:(UIView *)host {
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic) {
        [self showNativeInView:host];
        return;
    }
    rewind_sheet_set_rect(self, host.bounds);
    [host addSubview:self];
    _visible = NO;
    [self layoutPanelVisible:NO];
    _laidSize = self.bounds.size;
    _visible = YES;
    RewindSpring(0.4, ^{
        _dim.alpha = 1.0f;
        [self layoutPanelVisible:YES];
    }, nil);
}

- (void)dismissThen:(RewindAction)action {
    if (_dismissing) return;
    _dismissing = YES;
    RewindAction after = [[action copy] autorelease];
    [self retain];
    RewindAnimate(0.22, ^{
        _dim.alpha = 0.0f;
        _panel.center = CGPointMake(_panel.center.x, self.bounds.size.height + _panel.bounds.size.height * 0.5f);
    }, ^(BOOL finished) {
        (void)finished;
        [self removeFromSuperview];
        if (after) after();
        [self release];
    });
}

- (void)dismiss {
    [self dismissThen:nil];
}

- (void)tileTapped:(UIView *)tile {
    NSUInteger index = (NSUInteger)(tile.tag - 100);
    if (index < _tiles.count) [self dismissThen:((RewindSheetItem *)[_tiles objectAtIndex:index]).action];
}

- (void)rowTapped:(UIView *)row {
    NSUInteger index = (NSUInteger)(row.tag - 1000);
    if (index < _items.count) [self dismissThen:((RewindSheetItem *)[_items objectAtIndex:index]).action];
}

- (void)panned:(UIPanGestureRecognizer *)pan {
    CGFloat restY = self.bounds.size.height - (_panel.bounds.size.height - _panel.layer.cornerRadius);
    CGFloat dy = [pan translationInView:self].y;
    if (pan.state == UIGestureRecognizerStateBegan) _panY = _panel.center.y - _panel.bounds.size.height * 0.5f;
    if (pan.state == UIGestureRecognizerStateChanged) {
        CGFloat y = MAX(restY, _panY + dy);
        _panel.center = CGPointMake(_panel.center.x, y + _panel.bounds.size.height * 0.5f);
        _dim.alpha = 1.0f - MIN(1.0f, (y - restY) / MAX(1.0f, _panel.bounds.size.height));
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        CGFloat velocity = [pan velocityInView:self].y;
        if (dy > RW(90.0f) || velocity > 900.0f) {
            [self dismiss];
        } else {
            RewindSpring(0.35, ^{
                _panel.center = CGPointMake(_panel.center.x, restY + _panel.bounds.size.height * 0.5f);
                _dim.alpha = 1.0f;
            }, nil);
        }
    }
}

@end

void RewindUpdateStatusSpinner(UILabel *status, BOOL loading) {
    static const NSInteger tag = 7201;
    UIView *host = status.superview;
    if (!host) return;
    UIActivityIndicatorView *spinner = (UIActivityIndicatorView *)[host viewWithTag:tag];
    if (!loading || RewindCurrentTheme() != RewindThemeSkeuomorphic) {
        [spinner removeFromSuperview];
        return;
    }
    if (!spinner) {
        spinner = [[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite] autorelease];
        spinner.tag = tag;
        [host addSubview:spinner];
    }
    /* the label centres one line of text in its frame, so the top of the frame is free */
    spinner.center = CGPointMake(CGRectGetMidX(status.frame), CGRectGetMinY(status.frame) + spinner.bounds.size.height * 0.5f);
    [spinner startAnimating];
}

void RewindShowToast(UIView *host, NSString *text, CGFloat bottomInset) {
    if (!host || !text.length) return;
    UIFont *font = RewindFont(14.0f, RewindWeightRegular);
    CGFloat side = RW(12.0f);
    CGFloat width = MIN(host.bounds.size.width - side * 2.0f, 560.0f);
    CGFloat textH = RewindTextSize(text, font, width - RW(32.0f)).height;
    CGFloat height = MAX(RW(48.0f), textH + RW(28.0f));
    UIView *toast = [[[UIView alloc] initWithFrame:CGRectMake(floorf((host.bounds.size.width - width) * 0.5f),
                                                              host.bounds.size.height - bottomInset - height - side,
                                                              width, height)] autorelease];
    toast.backgroundColor = [UIColor colorWithRed:0.20f green:0.20f blue:0.20f alpha:1.0f];
    toast.layer.cornerRadius = RW(4.0f);
    toast.userInteractionEnabled = NO;
    toast.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin |
                             UIViewAutoresizingFlexibleRightMargin;
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectInset(toast.bounds, RW(16.0f), 0.0f)] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.font = font;
    label.textColor = RewindColorText();
    label.numberOfLines = 0;
    label.text = text;
    [toast addSubview:label];
    toast.alpha = 0.0f;
    toast.transform = CGAffineTransformMakeTranslation(0.0f, RW(16.0f));
    [host addSubview:toast];
    RewindSpring(0.35, ^{
        toast.alpha = 1.0f;
        toast.transform = CGAffineTransformIdentity;
    }, ^(BOOL finished) {
        (void)finished;
        [UIView animateWithDuration:0.25 delay:2.4 options:UIViewAnimationOptionCurveEaseIn
                         animations:^{ toast.alpha = 0.0f; }
                         completion:^(BOOL done) { (void)done; [toast removeFromSuperview]; }];
    });
}
