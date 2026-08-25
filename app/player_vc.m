#import "player_vc.h"

#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>
#include <math.h>

#import "tunetube_api.h"
#import "tunetube_player.h"
#import "library_vc.h"
#import "playlist_vc.h"
#import "artist_vc.h"
#import "play_button.h"
#import "tunetube_image_cache.h"
#import "tunetube_theme.h"
#import "tunetube_l10n.h"

static NSString *PlayerTime(NSUInteger seconds) {
    return [NSString stringWithFormat:@"%lu:%02lu",
            (unsigned long)(seconds / 60), (unsigned long)(seconds % 60)];
}

static UIColor *TunePlayerArtworkColor(UIImage *image) {
    CGImageRef source = image.CGImage;
    if (!source) return TuneThemePlayerBackgroundTop();

    unsigned char pixel[4] = {0, 0, 0, 255};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace,
                                                  kCGImageAlphaPremultipliedLast |
                                                  kCGBitmapByteOrder32Big);
    if (!context) {
        CGColorSpaceRelease(colorSpace);
        return TuneThemePlayerBackgroundTop();
    }
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), source);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);

    CGFloat red = pixel[0] / 255.0f;
    CGFloat green = pixel[1] / 255.0f;
    CGFloat blue = pixel[2] / 255.0f;
    CGFloat brightest = MAX(red, MAX(green, blue));
    CGFloat factor = brightest > 0.01f ? MIN(0.72f, 0.46f / brightest) : 1.0f;
    return [UIColor colorWithRed:MIN(1.0f, red * factor + 0.015f)
                           green:MIN(1.0f, green * factor + 0.015f)
                            blue:MIN(1.0f, blue * factor + 0.015f)
                           alpha:1.0f];
}

static UIColor *TunePlayerArtworkTopColor(UIImage *image) {
    UIColor *base = TunePlayerArtworkColor(image);
    CGFloat red = 0.0f;
    CGFloat green = 0.0f;
    CGFloat blue = 0.0f;
    CGFloat alpha = 1.0f;
    if (![base getRed:&red green:&green blue:&blue alpha:&alpha])
        return base;
    return [UIColor colorWithRed:MIN(1.0f, red * 1.42f + 0.02f)
                           green:MIN(1.0f, green * 1.42f + 0.02f)
                            blue:MIN(1.0f, blue * 1.42f + 0.02f)
                           alpha:1.0f];
}

static UIColor *TunePlayerArtworkMiddleColor(UIImage *image) {
    UIColor *base = TunePlayerArtworkColor(image);
    CGFloat red = 0.0f;
    CGFloat green = 0.0f;
    CGFloat blue = 0.0f;
    CGFloat alpha = 1.0f;
    if (![base getRed:&red green:&green blue:&blue alpha:&alpha])
        return base;
    return [UIColor colorWithRed:red * 0.78f
                           green:green * 0.78f
                            blue:blue * 0.78f
                           alpha:1.0f];
}

static UIImage *TunePlayerMaskImage(UIImage *mask, UIColor *color) {
    if (!mask) return nil;
    UIGraphicsBeginImageContextWithOptions(mask.size, NO, mask.scale);
    CGRect rect = CGRectMake(0.0f, 0.0f, mask.size.width, mask.size.height);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context, color.CGColor);
    CGContextFillRect(context, rect);
    [mask drawInRect:rect blendMode:kCGBlendModeDestinationIn alpha:1.0f];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIImage *TunePlayerLibraryImage(CGFloat size) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0.0f);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(context, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(context, MAX(1.3f, size * 0.075f));
    CGContextSetLineJoin(context, kCGLineJoinRound);
    CGContextSetLineCap(context, kCGLineCapRound);

    CGRect rear = CGRectMake(size * 0.18f, size * 0.14f, size * 0.58f, size * 0.66f);
    CGRect front = CGRectMake(size * 0.31f, size * 0.25f, size * 0.56f, size * 0.62f);
    CGContextStrokeRect(context, rear);
    CGContextStrokeRect(context, front);
    CGContextMoveToPoint(context, size * 0.43f, size * 0.45f);
    CGContextAddLineToPoint(context, size * 0.76f, size * 0.45f);
    CGContextMoveToPoint(context, size * 0.43f, size * 0.58f);
    CGContextAddLineToPoint(context, size * 0.76f, size * 0.58f);
    CGContextStrokePath(context);

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIImage *TunePlayerSearchImage(CGFloat size) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0.0f);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(context, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(context, MAX(1.3f, size * 0.075f));
    CGContextSetLineCap(context, kCGLineCapRound);

    CGContextStrokeEllipseInRect(context,
                                 CGRectMake(size * 0.16f, size * 0.14f,
                                            size * 0.48f, size * 0.48f));
    CGContextMoveToPoint(context, size * 0.56f, size * 0.56f);
    CGContextAddLineToPoint(context, size * 0.84f, size * 0.84f);
    CGContextStrokePath(context);

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@interface TunePlayerHeaderButton : UIButton {
    CAGradientLayer *_gradient;
}
- (void)applyTheme;
@end

@implementation TunePlayerHeaderButton

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _gradient = [[CAGradientLayer layer] retain];
    _gradient.cornerRadius = 8.0f;
    [self.layer insertSublayer:_gradient atIndex:0];
    self.backgroundColor = [UIColor clearColor];
    self.layer.cornerRadius = 8.0f;
    self.layer.borderWidth = 1.0f;
    self.layer.borderColor = TuneThemeNavigationBorder().CGColor;
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.24f;
    self.layer.shadowOffset = CGSizeMake(0.0f, 2.0f);
    self.layer.shadowRadius = 1.5f;
    self.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    self.adjustsImageWhenHighlighted = NO;
    return self;
}

- (void)dealloc {
    [_gradient release];
    [super dealloc];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _gradient.frame = self.bounds;
}

- (void)applyTheme {
    _gradient.colors = [NSArray arrayWithObjects:
                        (id)TuneThemeNavigationTop().CGColor,
                        (id)TuneThemeNavigationBottom().CGColor, nil];
    self.backgroundColor = [UIColor clearColor];
    self.layer.borderColor = TuneThemeNavigationBorder().CGColor;
    self.layer.shadowOpacity = 0.24f;
    [self setTitleColor:TuneThemeHeaderText() forState:UIControlStateNormal];
}

@end

static void PlayerStyleSlider(UISlider *slider) {
    if ([slider respondsToSelector:@selector(setMinimumTrackTintColor:)]) {
        slider.minimumTrackTintColor = [UIColor colorWithWhite:1.0f alpha:0.92f];
        slider.maximumTrackTintColor = [UIColor colorWithWhite:1.0f alpha:0.28f];
    }
    if ([slider respondsToSelector:@selector(setThumbTintColor:)])
        slider.thumbTintColor = [UIColor whiteColor];
}

static BOOL PlayerIsPad(void) {
    return [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
}

static BOOL PlayerIsCompactPhone(CGFloat height) {
    return !PlayerIsPad() && height <= 568.0f;
}

@interface TunePlayerBackButton : UIButton
@end

@implementation TunePlayerBackButton

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGFloat centerY = floorf(CGRectGetMidY(rect));
    CGContextSetStrokeColorWithColor(context, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(context, 2.2f);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetLineJoin(context, kCGLineJoinRound);

    CGContextMoveToPoint(context, 29.0f, centerY);
    CGContextAddLineToPoint(context, 12.0f, centerY);
    CGContextMoveToPoint(context, 12.0f, centerY);
    CGContextAddLineToPoint(context, 20.0f, centerY - 8.0f);
    CGContextMoveToPoint(context, 12.0f, centerY);
    CGContextAddLineToPoint(context, 20.0f, centerY + 8.0f);
    CGContextStrokePath(context);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.55f : 1.0f;
}

@end

@interface TunePlayerDotsButton : UIButton
@end

@implementation TunePlayerDotsButton

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context, [UIColor whiteColor].CGColor);
    CGFloat centerX = floorf(CGRectGetMidX(rect));
    CGFloat radius = 2.1f;
    for (NSUInteger index = 0; index < 3; ++index) {
        CGFloat centerY = floorf(CGRectGetMidY(rect) - 8.0f + index * 8.0f);
        CGContextFillEllipseInRect(context,
                                   CGRectMake(centerX - radius, centerY - radius,
                                              radius * 2.0f, radius * 2.0f));
    }
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.55f : 1.0f;
}

@end

static UIBarButtonItem *TunePlayerBackBarButton(id target, SEL action) {
    UIButton *button = [TunePlayerBackButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(0.0f, 0.0f, 38.0f, 32.0f);
    button.accessibilityLabel = TuneL(@"back");
    button.adjustsImageWhenHighlighted = NO;
    button.showsTouchWhenHighlighted = NO;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return [[[UIBarButtonItem alloc] initWithCustomView:button] autorelease];
}

static UIBarButtonItem *TunePlayerMoreBarButton(id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(0.0f, 0.0f, 34.0f, 32.0f);
    button.accessibilityLabel = @"More";
    UIImage *image = [UIImage imageNamed:@"menu-more.png"];
    if (image) {
        [button setImage:image forState:UIControlStateNormal];
        button.imageView.contentMode = UIViewContentModeScaleAspectFit;
        button.imageEdgeInsets = UIEdgeInsetsMake(6.0f, 6.0f, 6.0f, 6.0f);
    }
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return [[[UIBarButtonItem alloc] initWithCustomView:button] autorelease];
}

static UIImage *TunePlayerBlackNavigationImage(void) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1.0f, 44.0f), YES, 0.0f);
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = CGRectMake(0.0f, 0.0f, 1.0f, 44.0f);
    gradient.colors = [NSArray arrayWithObjects:
                       (id)[UIColor colorWithWhite:0.11f alpha:1.0f].CGColor,
                       (id)[UIColor colorWithWhite:0.015f alpha:1.0f].CGColor, nil];
    gradient.locations = [NSArray arrayWithObjects:@0.0f, @1.0f, nil];
    [gradient renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static void TunePlayerStyleNavigationBar(UINavigationBar *bar) {
    if (!bar) return;
    bar.barStyle = UIBarStyleBlack;
    bar.translucent = NO;
    bar.tintColor = [UIColor whiteColor];
    SEL barTintSelector = NSSelectorFromString(@"setBarTintColor:");
    if ([bar respondsToSelector:barTintSelector])
        [bar performSelector:barTintSelector withObject:[UIColor blackColor]];
    UIImage *background = TunePlayerBlackNavigationImage();
    [bar setBackgroundImage:background forBarMetrics:UIBarMetricsDefault];
    if ([bar respondsToSelector:@selector(setBackgroundImage:forBarMetrics:)])
        [bar setBackgroundImage:background forBarMetrics:UIBarMetricsLandscapePhone];
    bar.titleTextAttributes = [NSDictionary dictionaryWithObject:[UIColor whiteColor]
                                                              forKey:UITextAttributeTextColor];
}

@implementation TunePlayerMenuVC

- (id)initWithPlayer:(TuneTubePlayer *)player
                 api:(TuneTubeAPI *)api
            delegate:(id<TunePlayerMenuDelegate>)delegate {
    return [self initWithTrack:player.track player:player api:api delegate:delegate];
}

- (id)initWithTrack:(TuneTubeTrack *)track
             player:(TuneTubePlayer *)player
                api:(TuneTubeAPI *)api
           delegate:(id<TunePlayerMenuDelegate>)delegate {
    self = [super init];
    if (self) {
        _player = [player retain];
        _api = [api retain];
        _track = [track retain];
        _delegate = delegate;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_player release];
    [_api release];
    [_track release];
    [_gradient release];
    [_table release];
    [_header release];
    [_closeButton release];
    [_headerArtwork release];
    [_headerTitle release];
    [_headerArtist release];
    [_headerDuration release];
    [_cardButtons release];
    [_rows release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = [UIColor blackColor];
    self.view = view;
}

- (UIButton *)cardWithTitle:(NSString *)title icon:(NSString *)iconName action:(NSInteger)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.backgroundColor = [UIColor colorWithWhite:0.105f alpha:1.0f];
    button.layer.cornerRadius = 12.0f;
    button.layer.masksToBounds = YES;
    button.tag = action;
    [button addTarget:self action:@selector(cardPressed:)
     forControlEvents:UIControlEventTouchUpInside];

    UIImageView *iconView = [[[UIImageView alloc] initWithFrame:CGRectZero] autorelease];
    iconView.tag = 1001;
    iconView.backgroundColor = [UIColor clearColor];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.image = [UIImage imageNamed:iconName];
    iconView.userInteractionEnabled = NO;
    [button addSubview:iconView];

    UILabel *titleLabel = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    titleLabel.tag = 1002;
    titleLabel.backgroundColor = [UIColor clearColor];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.font = [UIFont boldSystemFontOfSize:13.0f];
    titleLabel.numberOfLines = 2;
    titleLabel.lineBreakMode = UILineBreakModeWordWrap;
    titleLabel.text = title;
    titleLabel.userInteractionEnabled = NO;
    [button addSubview:titleLabel];
    return button;
}

- (UIView *)buildHeader {
    UIView *header = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f,
                                                                 320.0f, 218.0f)] autorelease];
    header.backgroundColor = [UIColor clearColor];

    _closeButton = [[TunePlayerBackButton buttonWithType:UIButtonTypeCustom] retain];
    _closeButton.frame = CGRectZero;
    _closeButton.accessibilityLabel = TuneL(@"back");
    _closeButton.adjustsImageWhenHighlighted = NO;
    _closeButton.showsTouchWhenHighlighted = NO;
    [_closeButton addTarget:self action:@selector(closePressed)
           forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:_closeButton];

    _headerArtwork = [[UIImageView alloc] initWithFrame:CGRectZero];
    _headerArtwork.backgroundColor = [UIColor colorWithWhite:0.12f alpha:1.0f];
    _headerArtwork.contentMode = UIViewContentModeScaleAspectFill;
    _headerArtwork.clipsToBounds = YES;
    _headerArtwork.layer.cornerRadius = 4.0f;
    [header addSubview:_headerArtwork];

    _headerTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _headerTitle.backgroundColor = [UIColor clearColor];
    _headerTitle.textColor = [UIColor whiteColor];
    _headerTitle.font = [UIFont boldSystemFontOfSize:17.0f];
    _headerTitle.lineBreakMode = UILineBreakModeTailTruncation;
    [header addSubview:_headerTitle];

    _headerArtist = [[UILabel alloc] initWithFrame:CGRectZero];
    _headerArtist.backgroundColor = [UIColor clearColor];
    _headerArtist.textColor = [UIColor colorWithWhite:1.0f alpha:0.7f];
    _headerArtist.font = [UIFont systemFontOfSize:14.0f];
    _headerArtist.lineBreakMode = UILineBreakModeTailTruncation;
    [header addSubview:_headerArtist];

    _headerDuration = [[UILabel alloc] initWithFrame:CGRectZero];
    _headerDuration.backgroundColor = [UIColor clearColor];
    _headerDuration.textColor = [UIColor colorWithWhite:1.0f alpha:0.7f];
    _headerDuration.font = [UIFont systemFontOfSize:14.0f];
    _headerDuration.textAlignment = NSTextAlignmentRight;
    [header addSubview:_headerDuration];

    UIButton *playNext = [self cardWithTitle:TuneL(@"menu_play_next")
                                        icon:@"menu-play-next.png"
                                      action:TunePlayerMenuActionPlayNext];
    UIButton *playlist = [self cardWithTitle:TuneL(@"menu_add_playlist")
                                        icon:@"menu-playlist-add.png"
                                      action:TunePlayerMenuActionPlaylist];
    UIButton *share = [self cardWithTitle:TuneL(@"menu_share")
                                    icon:@"menu-share.png"
                                  action:TunePlayerMenuActionShare];
    _cardButtons = [[NSArray alloc] initWithObjects:playNext, playlist, share, nil];
    for (UIButton *button in _cardButtons) [header addSubview:button];
    return header;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    _gradient = [[CAGradientLayer layer] retain];
    [self.view.layer insertSublayer:_gradient atIndex:0];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = [UIColor blackColor];
    _table.backgroundView = nil;
    _table.separatorColor = [UIColor colorWithWhite:1.0f alpha:0.08f];
    _table.rowHeight = 56.0f;
    _table.dataSource = self;
    _table.delegate = self;
    _header = [[self buildHeader] retain];
    _table.tableHeaderView = _header;
    [self.view addSubview:_table];

    _rows = [[NSArray alloc] initWithObjects:
             [NSDictionary dictionaryWithObjectsAndKeys:TuneL(@"menu_mix"), @"title", @"menu-mix.png", @"icon", [NSNumber numberWithInteger:TunePlayerMenuActionMix], @"action", nil],
             [NSDictionary dictionaryWithObjectsAndKeys:TuneL(@"menu_queue"), @"title", @"menu-queue-add.png", @"icon", [NSNumber numberWithInteger:TunePlayerMenuActionQueue], @"action", nil],
             [NSDictionary dictionaryWithObjectsAndKeys:TuneL(@"menu_remove_library"), @"title", @"menu-library-remove.png", @"icon", [NSNumber numberWithInteger:TunePlayerMenuActionLibrary], @"action", nil],
             [NSDictionary dictionaryWithObjectsAndKeys:TuneL(@"menu_download"), @"title", @"menu-download.png", @"icon", [NSNumber numberWithInteger:TunePlayerMenuActionDownload], @"action", nil],
             [NSDictionary dictionaryWithObjectsAndKeys:TuneL(@"menu_remove_playlist"), @"title", @"menu-playlist-remove.png", @"icon", [NSNumber numberWithInteger:TunePlayerMenuActionRemovePlaylist], @"action", nil],
             [NSDictionary dictionaryWithObjectsAndKeys:TuneL(@"menu_album"), @"title", @"menu-album.png", @"icon", [NSNumber numberWithInteger:TunePlayerMenuActionAlbum], @"action", nil],
             [NSDictionary dictionaryWithObjectsAndKeys:TuneL(@"menu_artist"), @"title", @"menu-artist.png", @"icon", [NSNumber numberWithInteger:TunePlayerMenuActionArtist], @"action", nil],
             [NSDictionary dictionaryWithObjectsAndKeys:TuneL(@"menu_clear_queue"), @"title", @"menu-queue-clear.png", @"icon", [NSNumber numberWithInteger:TunePlayerMenuActionClearQueue], @"action", nil],
             [NSDictionary dictionaryWithObjectsAndKeys:TuneL(@"menu_speed"), @"title", @"menu-speed.png", @"icon", [NSNumber numberWithInteger:TunePlayerMenuActionSpeed], @"action", nil],
             [NSDictionary dictionaryWithObjectsAndKeys:TuneL(@"menu_sleep"), @"title", @"menu-sleep.png", @"icon", [NSNumber numberWithInteger:TunePlayerMenuActionSleep], @"action", nil],
             nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerChanged:)
                                                 name:TuneTubePlayerDidChangeNotification
                                               object:_player];
    [self refreshTrack];
}

- (void)playerChanged:(NSNotification *)note {
    if ([note object] == _player && !_track) [self refreshTrack];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    _gradient.frame = bounds;
    _table.frame = bounds;
    CGFloat width = bounds.size.width;
    CGFloat side = width > 700.0f ? 24.0f : 12.0f;
    BOOL headerWidthChanged = fabs(_header.frame.size.width - width) > 0.5f;
    _header.frame = CGRectMake(0.0f, 0.0f, width, 218.0f);
    _closeButton.frame = CGRectMake(8.0f, 12.0f, 38.0f, 34.0f);
    _headerArtwork.frame = CGRectMake(side + 42.0f, 10.0f, 42.0f, 42.0f);
    CGFloat textX = CGRectGetMaxX(_headerArtwork.frame) + 12.0f;
    CGFloat textWidth = width - textX - side;
    _headerTitle.frame = CGRectMake(textX, 7.0f, textWidth, 25.0f);
    _headerArtist.frame = CGRectMake(textX, 34.0f, textWidth - 55.0f, 20.0f);
    _headerDuration.frame = CGRectMake(width - side - 55.0f, 34.0f, 55.0f, 20.0f);

    CGFloat gap = width > 700.0f ? 16.0f : 12.0f;
    CGFloat cardWidth = floorf((width - side * 2.0f - gap * 2.0f) / 3.0f);
    if (width > 600.0f) cardWidth = MIN(cardWidth, 190.0f);
    CGFloat cardsWidth = cardWidth * 3.0f + gap * 2.0f;
    CGFloat cardsX = floorf((width - cardsWidth) * 0.5f);
    for (NSUInteger index = 0; index < _cardButtons.count; ++index) {
        UIButton *button = [_cardButtons objectAtIndex:index];
        button.frame = CGRectMake(cardsX + index * (cardWidth + gap), 78.0f,
                                  cardWidth, 92.0f);
        UIImageView *icon = (UIImageView *)[button viewWithTag:1001];
        UILabel *title = (UILabel *)[button viewWithTag:1002];
        icon.frame = CGRectMake(0.0f, 9.0f, cardWidth, 28.0f);
        title.frame = CGRectMake(6.0f, 43.0f, cardWidth - 12.0f, 34.0f);
    }
    if (headerWidthChanged) _table.tableHeaderView = _header;
}

- (void)refreshTrack {
    TuneTubeTrack *track = _track ? _track : _player.track;
    _headerTitle.text = track.title.length ? track.title : TuneL(@"nothing_playing");
    _headerArtist.text = track ? TuneTubeTrackArtistText(track) : TuneL(@"choose_track");
    NSUInteger duration = track.duration;
    if (!duration && [_player duration] > 0.0)
        duration = (NSUInteger)[_player duration];
    _headerDuration.text = track ? PlayerTime(duration) : @"0:00";
    _headerArtwork.image = [UIImage imageNamed:@"Icon.png"];
    [self applyGradient];
    if (!track.thumbnailURL.length) return;
    NSString *requestedURL = [track.thumbnailURL copy];
    TuneLoadImage(requestedURL, ^(UIImage *image) {
        if (!image || (_track ? _track != track : _player.track != track) ||
            ![requestedURL isEqualToString:track.thumbnailURL]) return;
        _headerArtwork.image = image;
        [self applyGradient];
    });
    [requestedURL release];
}

- (void)applyGradient {
    UIColor *top = TunePlayerArtworkColor(_headerArtwork.image);
    _gradient.colors = [NSArray arrayWithObjects:
                        (id)[top colorWithAlphaComponent:0.84f].CGColor,
                        (id)[UIColor blackColor].CGColor, nil];
    _gradient.locations = [NSArray arrayWithObjects:@0.0f, @0.70f, nil];
}

- (void)closePressed {
    if ([_delegate respondsToSelector:@selector(tunePlayerMenu:didSelectAction:)])
        [_delegate tunePlayerMenu:self didSelectAction:TunePlayerMenuActionClose];
}

- (void)cardPressed:(UIButton *)button {
    if ([_delegate respondsToSelector:@selector(tunePlayerMenu:didSelectAction:)])
        [_delegate tunePlayerMenu:self didSelectAction:button.tag];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)_rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"TunePlayerMenuCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:cellID] autorelease];
        cell.backgroundColor = [UIColor blackColor];
        cell.contentView.backgroundColor = [UIColor blackColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UIImageView *icon = [[[UIImageView alloc] initWithFrame:CGRectMake(16.0f, 12.0f,
                                                                            32.0f, 32.0f)] autorelease];
        icon.tag = 2001;
        icon.backgroundColor = [UIColor clearColor];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [cell.contentView addSubview:icon];
        UILabel *title = [[[UILabel alloc] initWithFrame:CGRectMake(62.0f, 0.0f,
                                                                      220.0f, 56.0f)] autorelease];
        title.tag = 2002;
        title.backgroundColor = [UIColor clearColor];
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:15.0f];
        title.lineBreakMode = UILineBreakModeTailTruncation;
        title.adjustsFontSizeToFitWidth = YES;
        title.minimumFontSize = 11.0f;
        [cell.contentView addSubview:title];
    }
    NSDictionary *row = [_rows objectAtIndex:(NSUInteger)indexPath.row];
    UIImageView *icon = (UIImageView *)[cell.contentView viewWithTag:2001];
    UILabel *title = (UILabel *)[cell.contentView viewWithTag:2002];
    icon.image = [UIImage imageNamed:[row objectForKey:@"icon"]];
    title.text = [row objectForKey:@"title"];
    title.font = [UIFont boldSystemFontOfSize:15.0f];
    title.frame = CGRectMake(62.0f, 0.0f, tableView.bounds.size.width - 74.0f, 56.0f);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= _rows.count) return;
    NSDictionary *row = [_rows objectAtIndex:(NSUInteger)indexPath.row];
    if ([_delegate respondsToSelector:@selector(tunePlayerMenu:didSelectAction:)])
        [_delegate tunePlayerMenu:self
                didSelectAction:[[row objectForKey:@"action"] integerValue]];
}

@end

@interface TuneAlbumVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    TuneTubeTrack *_seedTrack;
    TuneTubeAPI *_api;
    TuneTubePlayer *_player;
    NSString *_albumName;
    NSString *_artistName;
    NSMutableArray *_tracks;
    UITableView *_table;
    UILabel *_status;
    CAGradientLayer *_gradient;
}
- (id)initWithTrack:(TuneTubeTrack *)track api:(TuneTubeAPI *)api player:(TuneTubePlayer *)player;
@end

@implementation TuneAlbumVC

- (id)initWithTrack:(TuneTubeTrack *)track api:(TuneTubeAPI *)api player:(TuneTubePlayer *)player {
    self = [super init];
    if (self) {
        _seedTrack = [track retain];
        _api = [api retain];
        _player = [player retain];
        _albumName = [(track.album.length ? track.album : track.title) copy];
        _artistName = [TuneTubeTrackArtistText(track) copy];
        _tracks = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_seedTrack release];
    [_api release];
    [_player release];
    [_albumName release];
    [_artistName release];
    [_tracks release];
    [_table release];
    [_status release];
    [_gradient release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = [UIColor blackColor];
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _albumName;
    self.navigationItem.leftBarButtonItem = TuneTubeBarButtonItem(TuneL(@"back"),
                                                                    self,
                                                                    @selector(backPressed));
    _gradient = [[CAGradientLayer layer] retain];
    [self.view.layer insertSublayer:_gradient atIndex:0];
    _status = [[UILabel alloc] initWithFrame:CGRectZero];
    _status.backgroundColor = [UIColor clearColor];
    _status.textColor = [UIColor whiteColor];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.font = [UIFont systemFontOfSize:14.0f];
    _status.text = TuneL(@"loading_tracks");
    [self.view addSubview:_status];
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = [UIColor clearColor];
    _table.backgroundView = nil;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.rowHeight = 68.0f;
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];
    [self applyTheme:nil];

    NSString *query = _artistName.length
        ? [NSString stringWithFormat:@"%@ %@", _artistName, _albumName]
        : _albumName;
    [_api search:query completion:^(NSArray *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                _status.text = TuneL(@"couldnt_load_tracks");
                return;
            }
            [_tracks removeAllObjects];
            for (TuneTubeTrack *track in tracks) {
                if (!track.isPlaylist && track.videoID.length)
                    [_tracks addObject:track];
                if (_tracks.count >= 30) break;
            }
            _status.hidden = _tracks.count > 0;
            [_table reloadData];
        });
    }];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _gradient.frame = self.view.bounds;
    CGFloat top = 8.0f;
    _status.frame = CGRectMake(12.0f, top, self.view.bounds.size.width - 24.0f, 30.0f);
    _table.frame = CGRectMake(0.0f, top, self.view.bounds.size.width,
                              self.view.bounds.size.height - top);
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = [UIColor blackColor];
    TuneTubeStyleNavigationBar(self.navigationController.navigationBar);
    _gradient.colors = [NSArray arrayWithObjects:
                        (id)[UIColor colorWithWhite:0.12f alpha:1.0f].CGColor,
                        (id)[UIColor blackColor].CGColor, nil];
    _status.textColor = [UIColor whiteColor];
    [_table reloadData];
}

- (void)backPressed {
    [self.navigationController popViewControllerAnimated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)_tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"TuneAlbumTrackCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:cellID] autorelease];
        cell.selectionStyle = UITableViewCellSelectionStyleGray;

        UIImageView *artwork = [[[UIImageView alloc] initWithFrame:CGRectMake(12.0f,
                                                                                8.0f,
                                                                                52.0f,
                                                                                52.0f)] autorelease];
        artwork.tag = 3001;
        artwork.backgroundColor = [UIColor colorWithWhite:0.10f alpha:1.0f];
        artwork.contentMode = UIViewContentModeScaleAspectFill;
        artwork.clipsToBounds = YES;
        artwork.layer.cornerRadius = 8.0f;
        artwork.layer.masksToBounds = YES;
        artwork.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
        [cell.contentView addSubview:artwork];

        UILabel *title = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
        title.tag = 3002;
        title.backgroundColor = [UIColor clearColor];
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:15.0f];
        title.lineBreakMode = UILineBreakModeTailTruncation;
        title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:title];

        UILabel *detail = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
        detail.tag = 3003;
        detail.backgroundColor = [UIColor clearColor];
        detail.textColor = [UIColor colorWithWhite:1.0f alpha:0.7f];
        detail.font = [UIFont systemFontOfSize:12.0f];
        detail.lineBreakMode = UILineBreakModeTailTruncation;
        detail.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:detail];
    }
    TuneTubeTrack *track = [_tracks objectAtIndex:(NSUInteger)indexPath.row];
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    CGFloat textWidth = MAX(80.0f, tableView.bounds.size.width - 90.0f);
    UIImageView *artwork = (UIImageView *)[cell.contentView viewWithTag:3001];
    UILabel *title = (UILabel *)[cell.contentView viewWithTag:3002];
    UILabel *detail = (UILabel *)[cell.contentView viewWithTag:3003];
    title.frame = CGRectMake(78.0f, 10.0f, textWidth, 22.0f);
    detail.frame = CGRectMake(78.0f, 36.0f, textWidth, 18.0f);
    title.text = track.title;
    detail.text = [NSString stringWithFormat:@"%@  %lu:%02lu",
                   TuneTubeTrackArtistText(track),
                   (unsigned long)(track.duration / 60),
                   (unsigned long)(track.duration % 60)];
    artwork.image = [UIImage imageNamed:@"Icon.png"];
    NSString *requestedURL = [track.thumbnailURL copy];
    TuneLoadImage(requestedURL, ^(UIImage *image) {
        if (!image || (NSUInteger)indexPath.row >= _tracks.count ||
            [_tracks objectAtIndex:(NSUInteger)indexPath.row] != track) return;
        UITableViewCell *visible = [_table cellForRowAtIndexPath:indexPath];
        UIImageView *visibleArtwork = (UIImageView *)[visible.contentView viewWithTag:3001];
        visibleArtwork.image = image;
        [visible setNeedsLayout];
    });
    [requestedURL release];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= _tracks.count || !_api || !_player) return;
    TuneTubeTrack *track = [_tracks objectAtIndex:(NSUInteger)indexPath.row];
    [_player setQueue:_tracks selectedIndex:indexPath.row usingAPI:_api];
    TuneTubeRecordTrack(track);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

@interface TunePlayerVC () <TunePlayerMenuDelegate, UIAlertViewDelegate, UIActionSheetDelegate>
- (void)refresh:(NSNotification *)note;
- (void)updateProgress:(NSTimer *)timer;
- (void)progressChanged:(UISlider *)slider;
- (void)searchPressed;
- (void)libraryPressed;
- (void)backPressed;
- (void)togglePressed;
- (void)favoritePressed;
- (void)nextTrackPressed;
- (void)previousTrackPressed;
- (void)repeatPressed;
- (void)artistPressed;
- (void)morePressed;
- (void)performMenuAction:(NSInteger)action;
- (void)showPlaylistPicker;
- (void)showRemovePlaylistPicker;
- (void)showSleepTimerPicker;
- (void)showPlaybackSpeedPicker;
- (void)downloadCurrentTrack;
- (void)openAlbum;
- (void)showMessage:(NSString *)title message:(NSString *)message;
- (void)applyTheme:(NSNotification *)note;
- (void)updateTitleMarquee;
- (void)titleMarqueeTick:(NSTimer *)timer;
- (void)stopTitleMarquee;
- (void)applyArtworkGradient;
@end

@implementation TunePlayerVC

- (id)initWithPlayer:(TuneTubePlayer *)player {
    return [self initWithPlayer:player api:nil];
}

- (id)initWithPlayer:(TuneTubePlayer *)player api:(TuneTubeAPI *)api {
    self = [super init];
    if (self) {
        _player = [player retain];
        _api = [api retain];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_player release];
    [_api release];
    [_backgroundGradient release];
    [_headerGradient release];
    [_headerBar release];
    [_headerSearch release];
    [_headerLibrary release];
    [_headerTitle release];
    [_artwork release];
    [_titleViewport release];
    [_titleLabel release];
    [_titleLoopLabel release];
    [_artistLabel release];
    [_artistButton release];
    [_progress release];
    [_elapsedLabel release];
    [_durationLabel release];
    [_previousButton release];
    [_nextButton release];
    [_repeatButton release];
    [_favoriteButton release];
    [_playButton release];
    [_progressTimer invalidate];
    [_progressTimer release];
    [_titleMarqueeTimer invalidate];
    [_titleMarqueeTimer release];
    [_titleMarqueeText release];
    [_menuTrack release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = TuneThemePlayerBackgroundBottom();
    self.view = view;
}

- (UIButton *)textButton:(NSString *)title size:(CGFloat)size {
    UIButton *button = [[[TunePlayerHeaderButton alloc] initWithFrame:CGRectZero] autorelease];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:TuneThemeHeaderText() forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:size];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBarHidden = NO;
    self.title = @"TuneTube";
    self.navigationItem.leftBarButtonItem =
        TunePlayerBackBarButton(self, @selector(backPressed));
    self.navigationItem.rightBarButtonItem =
        TunePlayerMoreBarButton(self, @selector(morePressed));
    _backgroundGradient = [[CAGradientLayer layer] retain];
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)TuneThemePlayerBackgroundTop().CGColor,
                                  (id)TuneThemePlayerBackgroundBottom().CGColor, nil];
    _backgroundGradient.locations = [NSArray arrayWithObjects:@0.0f, @1.0f, nil];
    [self.view.layer insertSublayer:(CAGradientLayer *)_backgroundGradient atIndex:0];

    _headerBar = [[UIView alloc] initWithFrame:CGRectZero];
    _headerBar.backgroundColor = [UIColor clearColor];
    _headerBar.hidden = YES;
    _headerBar.layer.borderWidth = 1.0f;
    _headerBar.layer.borderColor = TuneThemeNavigationBorder().CGColor;
    _headerGradient = [[CAGradientLayer layer] retain];
    [_headerBar.layer insertSublayer:_headerGradient atIndex:0];
    [self.view addSubview:_headerBar];

    _headerSearch = [[self textButton:@"Search" size:12.0f] retain];
    [_headerSearch setTitle:nil forState:UIControlStateNormal];
    [_headerSearch setImage:TunePlayerMaskImage(TunePlayerSearchImage(24.0f),
                                                TuneThemeHeaderText())
                    forState:UIControlStateNormal];
    _headerSearch.imageEdgeInsets = UIEdgeInsetsMake(5.0f, 5.0f, 5.0f, 5.0f);
    _headerSearch.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    _headerSearch.accessibilityLabel = @"Search";
    [_headerSearch addTarget:self action:@selector(searchPressed)
            forControlEvents:UIControlEventTouchUpInside];
    [_headerBar addSubview:_headerSearch];

    _headerLibrary = [[self textButton:@"Library" size:12.0f] retain];
    [_headerLibrary setTitle:nil forState:UIControlStateNormal];
    [_headerLibrary setImage:TunePlayerMaskImage(TunePlayerLibraryImage(24.0f),
                                                 TuneThemeHeaderText())
                     forState:UIControlStateNormal];
    _headerLibrary.imageEdgeInsets = UIEdgeInsetsMake(5.0f, 5.0f, 5.0f, 5.0f);
    _headerLibrary.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    _headerLibrary.accessibilityLabel = @"Library";
    [_headerLibrary addTarget:self action:@selector(libraryPressed)
              forControlEvents:UIControlEventTouchUpInside];
    [_headerBar addSubview:_headerLibrary];

    _headerTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _headerTitle.backgroundColor = [UIColor clearColor];
    _headerTitle.textColor = TuneThemePrimaryText();
    _headerTitle.font = [UIFont boldSystemFontOfSize:17.0f];
    _headerTitle.textAlignment = NSTextAlignmentCenter;
    _headerTitle.text = @"TuneTube";
    _headerTitle.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.65f];
    _headerTitle.shadowOffset = CGSizeMake(0.0f, 2.0f);
    [_headerBar addSubview:_headerTitle];

    _artwork = [[UIImageView alloc] initWithFrame:CGRectZero];
    _artwork.image = [UIImage imageNamed:@"Icon.png"];
    _artwork.contentMode = UIViewContentModeScaleAspectFill;
    _artwork.clipsToBounds = YES;
    _artwork.backgroundColor = [UIColor colorWithWhite:0.08f alpha:1.0f];
    _artwork.layer.cornerRadius = 14.0f;
    _artwork.layer.masksToBounds = YES;
    _artwork.layer.borderWidth = 0.0f;
    _artwork.layer.borderColor = [UIColor clearColor].CGColor;
    [self.view addSubview:_artwork];

    _titleViewport = [[UIView alloc] initWithFrame:CGRectZero];
    _titleViewport.backgroundColor = [UIColor clearColor];
    _titleViewport.clipsToBounds = YES;
    [self.view addSubview:_titleViewport];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.textColor = TuneThemePrimaryText();
    _titleLabel.font = [UIFont boldSystemFontOfSize:20.0f];
    _titleLabel.textAlignment = NSTextAlignmentLeft;
    _titleLabel.lineBreakMode = UILineBreakModeClip;
    _titleLabel.numberOfLines = 1;
    [_titleViewport addSubview:_titleLabel];

    _titleLoopLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLoopLabel.backgroundColor = [UIColor clearColor];
    _titleLoopLabel.textColor = TuneThemePrimaryText();
    _titleLoopLabel.font = _titleLabel.font;
    _titleLoopLabel.textAlignment = NSTextAlignmentLeft;
    _titleLoopLabel.lineBreakMode = UILineBreakModeClip;
    _titleLoopLabel.numberOfLines = 1;
    _titleLoopLabel.hidden = YES;
    [_titleViewport addSubview:_titleLoopLabel];

    _artistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _artistLabel.backgroundColor = [UIColor clearColor];
    _artistLabel.textColor = [UIColor whiteColor];
    _artistLabel.font = [UIFont systemFontOfSize:13.0f];
    _artistLabel.textAlignment = NSTextAlignmentLeft;
    _artistLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [self.view addSubview:_artistLabel];

    _artistButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _artistButton.adjustsImageWhenHighlighted = NO;
    _artistButton.accessibilityLabel = TuneL(@"artist_profile");
    [_artistButton addTarget:self action:@selector(artistPressed)
            forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_artistButton];


    _progress = [[UISlider alloc] initWithFrame:CGRectZero];
    _progress.minimumValue = 0.0f;
    _progress.maximumValue = 1.0f;
    _progress.value = 0.0f;
    PlayerStyleSlider(_progress);
    _progress.userInteractionEnabled = YES;
    [_progress addTarget:self action:@selector(progressChanged:)
        forControlEvents:UIControlEventValueChanged | UIControlEventTouchUpInside |
                         UIControlEventTouchUpOutside];
    [self.view addSubview:_progress];

    _elapsedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _elapsedLabel.backgroundColor = [UIColor clearColor];
    _elapsedLabel.textColor = [UIColor whiteColor];
    _elapsedLabel.font = [UIFont systemFontOfSize:11.0f];
    [self.view addSubview:_elapsedLabel];

    _durationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _durationLabel.backgroundColor = [UIColor clearColor];
    _durationLabel.textColor = [UIColor whiteColor];
    _durationLabel.font = [UIFont systemFontOfSize:11.0f];
    _durationLabel.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:_durationLabel];

    _playButton = [[TunePlaybackButton alloc] initWithFrame:CGRectZero];
    [_playButton setLightStyle:NO];
    [_playButton addTarget:self action:@selector(togglePressed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_playButton];

    _previousButton = [[TuneRoundButton alloc] initWithKind:TuneRoundButtonKindPrevious];
    [_previousButton addTarget:self action:@selector(previousTrackPressed)
              forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_previousButton];

    _nextButton = [[TuneRoundButton alloc] initWithKind:TuneRoundButtonKindNext];
    [_nextButton addTarget:self action:@selector(nextTrackPressed)
          forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_nextButton];

    _repeatButton = [[TuneRoundButton alloc] initWithKind:TuneRoundButtonKindRepeat];
    [_repeatButton addTarget:self action:@selector(repeatPressed)
            forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_repeatButton];

    _favoriteButton = [[TuneRoundButton alloc] initWithKind:TuneRoundButtonKindStar];
    [_favoriteButton addTarget:self action:@selector(favoritePressed)
              forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_favoriteButton];

    _artwork.userInteractionEnabled = YES;
    UISwipeGestureRecognizer *nextSwipe = [[[UISwipeGestureRecognizer alloc]
                                             initWithTarget:self action:@selector(nextTrackPressed)] autorelease];
    nextSwipe.direction = UISwipeGestureRecognizerDirectionLeft;
    [_artwork addGestureRecognizer:nextSwipe];
    UISwipeGestureRecognizer *previousSwipe = [[[UISwipeGestureRecognizer alloc]
                                                 initWithTarget:self action:@selector(previousTrackPressed)] autorelease];
    previousSwipe.direction = UISwipeGestureRecognizerDirectionRight;
    [_artwork addGestureRecognizer:previousSwipe];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refresh:)
                                                 name:TuneTubePlayerDidChangeNotification
                                               object:_player];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyTheme:)
                                                 name:TuneTubeThemeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageChanged:)
                                                 name:TUNETUBE_LANGUAGE_DID_CHANGE_NOTIFICATION
                                               object:nil];
    [self applyTheme:nil];
    [self refresh:nil];
}

- (void)languageChanged:(NSNotification *)note {
    (void)note;
    self.navigationItem.leftBarButtonItem =
        TunePlayerBackBarButton(self, @selector(backPressed));
    self.navigationItem.rightBarButtonItem =
        TunePlayerMoreBarButton(self, @selector(morePressed));
    [self refresh:nil];
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = TuneThemePlayerBackgroundBottom();
    TunePlayerStyleNavigationBar(self.navigationController.navigationBar);
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)TuneThemePlayerBackgroundTop().CGColor,
                                  (id)TuneThemePlayerBackgroundBottom().CGColor, nil];
    _backgroundGradient.locations = [NSArray arrayWithObjects:@0.0f, @1.0f, nil];
    _headerGradient.frame = _headerBar.bounds;
    _headerGradient.colors = [NSArray arrayWithObjects:
                              (id)TuneThemeNavigationTop().CGColor,
                              (id)TuneThemeNavigationBottom().CGColor, nil];
    _headerBar.backgroundColor = [UIColor clearColor];
    _headerBar.layer.borderColor = TuneThemeNavigationBorder().CGColor;
    [_headerSearch setImage:TunePlayerMaskImage(TunePlayerSearchImage(24.0f),
                                                TuneThemeHeaderText())
                    forState:UIControlStateNormal];
    [_headerLibrary setImage:TunePlayerMaskImage(TunePlayerLibraryImage(24.0f),
                                                 TuneThemeHeaderText())
                     forState:UIControlStateNormal];
    [(TunePlayerHeaderButton *)_headerSearch applyTheme];
    [(TunePlayerHeaderButton *)_headerLibrary applyTheme];
    _headerTitle.textColor = TuneThemePrimaryText();
    _artwork.layer.borderWidth = 0.0f;
    _artwork.layer.borderColor = [UIColor clearColor].CGColor;
    _titleLabel.textColor = TuneThemePrimaryText();
    _titleLoopLabel.textColor = TuneThemePrimaryText();
    _artistLabel.textColor = [UIColor whiteColor];
    _elapsedLabel.textColor = [UIColor whiteColor];
    _durationLabel.textColor = [UIColor whiteColor];
    [_previousButton applyTheme];
    [_nextButton applyTheme];
    [_repeatButton applyTheme];
    [_favoriteButton applyTheme];
    [_playButton applyTheme];
    PlayerStyleSlider(_progress);
    [self applyArtworkGradient];
    [self updateTitleMarquee];
    [self.view setNeedsLayout];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!_progressTimer) {
        _progressTimer = [[NSTimer scheduledTimerWithTimeInterval:0.5f
                                                            target:self
                                                          selector:@selector(updateProgress:)
                                                          userInfo:nil
                                                            repeats:YES] retain];
    }
    [self becomeFirstResponder];
}

- (void)viewWillDisappear:(BOOL)animated {
    [_progressTimer invalidate];
    [_progressTimer release];
    _progressTimer = nil;
    [self resignFirstResponder];
    [self stopTitleMarquee];
    [super viewWillDisappear:animated];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    _backgroundGradient.frame = b;
    BOOL landscape = b.size.width > b.size.height;
    BOOL compact = PlayerIsCompactPhone(b.size.height);
    _headerBar.frame = CGRectZero;

    if (landscape) {
        CGFloat side = PlayerIsPad() ? 28.0f : 14.0f;
        CGFloat top = PlayerIsPad() ? 18.0f : 10.0f;
        CGFloat leftWidth = MIN(b.size.height - 40.0f, b.size.width * 0.44f);
        if (leftWidth < 160.0f) leftWidth = 160.0f;

        CGFloat artSize = MIN(leftWidth - 12.0f, b.size.height - 72.0f);
        if (artSize < 120.0f) artSize = 120.0f;
        CGFloat artX = side + floorf((leftWidth - artSize) * 0.5f);
        CGFloat artY = top + floorf((b.size.height - top - artSize - 52.0f) * 0.35f);
        _artwork.frame = CGRectMake(artX, artY, artSize, artSize);
        _artwork.layer.cornerRadius = 12.0f;

        CGFloat titleY = CGRectGetMaxY(_artwork.frame) + 8.0f;
        CGFloat leftTextWidth = leftWidth - 8.0f;
        _titleLabel.font = [UIFont boldSystemFontOfSize:compact ? 18.0f : 20.0f];
        _titleLoopLabel.font = _titleLabel.font;
        _titleViewport.frame = CGRectMake(side + 4.0f, titleY, leftTextWidth, 25.0f);
        _artistLabel.font = [UIFont systemFontOfSize:15.0f];
        _artistLabel.frame = CGRectMake(side + 4.0f, titleY + 26.0f, leftTextWidth, 20.0f);
        _artistButton.frame = _artistLabel.frame;

        CGFloat rightX = side + leftWidth + (PlayerIsPad() ? 28.0f : 16.0f);
        CGFloat rightWidth = MAX(120.0f, b.size.width - rightX - side);
        CGFloat playSize = compact ? 54.0f : (PlayerIsPad() ? 74.0f : 66.0f);
        CGFloat small = compact ? 32.0f : (PlayerIsPad() ? 46.0f : 40.0f);
        CGFloat gap = compact ? 4.0f : 8.0f;
        CGFloat sliderBlock = 44.0f;
        CGFloat stackGap = 12.0f;
        CGFloat blockHeight = sliderBlock + stackGap + playSize;
        CGFloat blockTop = floorf((b.size.height - blockHeight) * 0.5f);
        if (blockTop < 14.0f) blockTop = 14.0f;
        if (blockTop + blockHeight > b.size.height - 10.0f)
            blockTop = MAX(10.0f, b.size.height - 10.0f - blockHeight);

        _progress.frame = CGRectMake(rightX, blockTop, rightWidth, 24.0f);
        _elapsedLabel.frame = CGRectMake(rightX + 2.0f, blockTop + 22.0f, 70.0f, 16.0f);
        _durationLabel.frame = CGRectMake(rightX + rightWidth - 72.0f, blockTop + 22.0f,
                                          70.0f, 16.0f);

        CGFloat controlY = blockTop + sliderBlock + stackGap;
        CGFloat groupWidth = playSize + (small * 4.0f) + (gap * 4.0f);
        CGFloat groupX = floorf(rightX + (rightWidth - groupWidth) * 0.5f);
        groupX = MAX(rightX, MIN(groupX, rightX + rightWidth - groupWidth));
        CGFloat playX = groupX + small + gap + small + gap;
        _playButton.frame = CGRectMake(playX, controlY, playSize, playSize);
        CGFloat smallY = controlY + floorf((playSize - small) * 0.5f);
        _favoriteButton.frame = CGRectMake(groupX, smallY, small, small);
        _previousButton.frame = CGRectMake(groupX + small + gap, smallY, small, small);
        _nextButton.frame = CGRectMake(CGRectGetMaxX(_playButton.frame) + gap,
                                       smallY, small, small);
        _repeatButton.frame = CGRectMake(CGRectGetMaxX(_nextButton.frame) + gap,
                                         smallY, small, small);
    } else {
        CGFloat side = PlayerIsPad() ? 48.0f : 22.0f;
        CGFloat playSize = PlayerIsPad() ? 80.0f : (compact ? 58.0f : 64.0f);
        CGFloat small = PlayerIsPad() ? 48.0f : (compact ? 38.0f : 42.0f);
        CGFloat gap = PlayerIsPad() ? 10.0f : 7.0f;
        CGFloat bottomPad = 16.0f;
        CGFloat transportH = playSize;
        CGFloat sliderH = 44.0f;
        CGFloat metaH = 58.0f;
        CGFloat usedBottom = bottomPad + transportH + 10.0f + sliderH + 8.0f + metaH;
        CGFloat artTop = PlayerIsPad() ? 16.0f : 8.0f;
        CGFloat artMax = b.size.height - artTop - usedBottom;
        CGFloat artSize = MIN(b.size.width - side * 2.0f, artMax);
        if (PlayerIsPad())
            artSize = MIN(artSize, 560.0f);
        else
            artSize = MIN(artSize, compact ? 270.0f : 300.0f);
        if (artSize < 120.0f) artSize = 120.0f;
        CGFloat artX = floorf((b.size.width - artSize) * 0.5f);
        _artwork.frame = CGRectMake(artX, artTop, artSize, artSize);
        _artwork.layer.cornerRadius = 14.0f;

        CGFloat titleY = CGRectGetMaxY(_artwork.frame) + 10.0f;
        _titleLabel.font = [UIFont boldSystemFontOfSize:PlayerIsPad() ? 26.0f : 22.0f];
        _titleLoopLabel.font = _titleLabel.font;
        _titleViewport.frame = CGRectMake(side, titleY, b.size.width - side * 2.0f, 29.0f);
        _artistLabel.font = [UIFont systemFontOfSize:PlayerIsPad() ? 17.0f : 16.0f];
        _artistLabel.frame = CGRectMake(side, titleY + 30.0f, b.size.width - side * 2.0f, 21.0f);
        _artistButton.frame = _artistLabel.frame;

        CGFloat controlY = b.size.height - bottomPad - playSize;
        CGFloat sliderY = controlY - 10.0f - sliderH;
        if (sliderY < CGRectGetMaxY(_artistLabel.frame) + 6.0f)
            sliderY = CGRectGetMaxY(_artistLabel.frame) + 6.0f;

        CGFloat availableProgressWidth = b.size.width - side * 2.0f;
        _progress.frame = CGRectMake(side, sliderY, availableProgressWidth, 24.0f);
        _elapsedLabel.frame = CGRectMake(side + 2.0f, sliderY + 22.0f, 70.0f, 16.0f);
        _durationLabel.frame = CGRectMake(b.size.width - side - 72.0f, sliderY + 22.0f,
                                          70.0f, 16.0f);

        CGFloat groupWidth = playSize + (small * 4.0f) + (gap * 4.0f);
        CGFloat groupX = floorf((b.size.width - groupWidth) * 0.5f);
        CGFloat playX = groupX + small + gap + small + gap;
        _playButton.frame = CGRectMake(playX, controlY, playSize, playSize);
        CGFloat smallY = controlY + floorf((playSize - small) * 0.5f);
        _favoriteButton.frame = CGRectMake(groupX, smallY, small, small);
        _previousButton.frame = CGRectMake(groupX + small + gap, smallY, small, small);
        _nextButton.frame = CGRectMake(CGRectGetMaxX(_playButton.frame) + gap,
                                       smallY, small, small);
        _repeatButton.frame = CGRectMake(CGRectGetMaxX(_nextButton.frame) + gap,
                                         smallY, small, small);
    }
    [self updateTitleMarquee];
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)orientation
                                          duration:(NSTimeInterval)duration {
    (void)orientation;
    (void)duration;
    [self.view setNeedsLayout];
}

- (void)refresh:(NSNotification *)note {
    NSError *error = [[note userInfo] objectForKey:@"error"];
    TuneTubeTrack *track = _player.track;
    if (!track) {
        _titleLabel.text = TuneL(@"nothing_playing");
        _artistLabel.text = TuneL(@"choose_track");
        _elapsedLabel.text = @"0:00";
        _durationLabel.text = @"0:00";
        _progress.value = 0.0f;
        [_playButton setPlaying:NO];
        [_favoriteButton setActive:NO];
        [_repeatButton setActive:_player.isRepeating];
        _artwork.image = [UIImage imageNamed:@"Icon.png"];
        _artistButton.hidden = YES;
        [self updateTitleMarquee];
        [self applyArtworkGradient];
        return;
    }

    _titleLabel.text = track.title;
    _titleLoopLabel.text = track.title;
    if (error) {
        _artistLabel.text = TuneTubeTrackArtistText(track);
        _elapsedLabel.text = @"0:00";
        _durationLabel.text = PlayerTime(track.duration);
        _progress.value = 0.0f;
        [_playButton setPlaying:NO];
        return;
    }
    NSString *artistName = TuneTubeTrackArtistText(track);
    _artistLabel.text = artistName;
    BOOL hasArtist = artistName.length > 0 &&
        [artistName caseInsensitiveCompare:@"Various Artists"] != NSOrderedSame &&
        [artistName caseInsensitiveCompare:@"YouTube Music"] != NSOrderedSame;
    _artistButton.hidden = !hasArtist;
    _progress.value = [_player progress];
    _elapsedLabel.text = PlayerTime((NSUInteger)[_player currentTime]);
    _durationLabel.text = PlayerTime((NSUInteger)[_player duration]);
    [_playButton setPlaying:_player.isPlaying];
    [_favoriteButton setActive:TuneTubeTrackIsSaved(track)];
    [_repeatButton setActive:_player.isRepeating];

    [self.view setNeedsLayout];

    NSString *requestedURL = [track.thumbnailURL copy];
    TuneLoadImage(requestedURL, ^(UIImage *image) {
        if (image && _player.track == track &&
            [requestedURL isEqualToString:track.thumbnailURL])
            _artwork.image = image;
        if (image && _player.track == track &&
            [requestedURL isEqualToString:track.thumbnailURL]) {
            [self applyArtworkGradient];
            [self.view setNeedsLayout];
        }
    });
    [requestedURL release];
}

- (void)applyArtworkGradient {
    if (!_backgroundGradient) return;
    UIColor *top = TunePlayerArtworkColor(_artwork.image);
    UIColor *highlight = TunePlayerArtworkTopColor(_artwork.image);
    UIColor *middle = TunePlayerArtworkMiddleColor(_artwork.image);
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)[highlight colorWithAlphaComponent:0.96f].CGColor,
                                  (id)[top colorWithAlphaComponent:0.82f].CGColor,
                                  (id)[middle colorWithAlphaComponent:0.58f].CGColor,
                                  (id)[UIColor blackColor].CGColor, nil];
    _backgroundGradient.locations = [NSArray arrayWithObjects:@0.0f, @0.24f, @0.58f, @1.0f, nil];
}

- (void)stopTitleMarquee {
    [_titleMarqueeTimer invalidate];
    [_titleMarqueeTimer release];
    _titleMarqueeTimer = nil;
    _titleMarqueeOffset = 0.0f;
    _titleLoopLabel.hidden = YES;
}

- (void)updateTitleMarquee {
    if (!_titleViewport || _titleViewport.bounds.size.width < 1.0f) return;
    NSString *text = _titleLabel.text ?: @"";
    CGFloat availableWidth = _titleViewport.bounds.size.width;
    CGFloat textWidth = ceilf([text sizeWithFont:_titleLabel.font].width);
    if (!text.length || textWidth <= availableWidth + 1.0f) {
        [self stopTitleMarquee];
        _titleLabel.textAlignment = NSTextAlignmentLeft;
        _titleLabel.frame = _titleViewport.bounds;

        CGRect artistFrame = _artistLabel.frame;
        artistFrame.origin.x = CGRectGetMinX(_titleViewport.frame);
        artistFrame.size.width = availableWidth;
        _artistLabel.frame = artistFrame;
        _artistButton.frame = artistFrame;
        return;
    }

    CGFloat gap = 34.0f;
    CGFloat cycle = textWidth + gap;
    BOOL sameTitle = [_titleMarqueeText isEqualToString:text] &&
        fabs(_titleMarqueeCycle - cycle) < 0.5f;
    if (!sameTitle) {
        [_titleMarqueeText release];
        _titleMarqueeText = [text copy];
        _titleMarqueeTextWidth = textWidth;
        _titleMarqueeCycle = cycle;
        _titleMarqueeOffset = 0.0f;
    }

    _titleLabel.textAlignment = NSTextAlignmentLeft;
    _titleLoopLabel.text = text;
    _titleLoopLabel.font = _titleLabel.font;
    _titleLoopLabel.hidden = NO;
    CGRect artistFrame = _artistLabel.frame;
    artistFrame.origin.x = CGRectGetMinX(_titleViewport.frame);
    artistFrame.size.width = availableWidth;
    _artistLabel.frame = artistFrame;
    _artistButton.frame = artistFrame;
    CGFloat height = _titleViewport.bounds.size.height;
    _titleLabel.frame = CGRectMake(-_titleMarqueeOffset, 0.0f,
                                   _titleMarqueeTextWidth, height);
    _titleLoopLabel.frame = CGRectMake(_titleMarqueeCycle - _titleMarqueeOffset,
                                       0.0f, _titleMarqueeTextWidth, height);
    if (!_titleMarqueeTimer)
        _titleMarqueeTimer = [[NSTimer scheduledTimerWithTimeInterval:0.045f
                                                                 target:self
                                                               selector:@selector(titleMarqueeTick:)
                                                               userInfo:nil
                                                                repeats:YES] retain];
}

- (void)titleMarqueeTick:(NSTimer *)timer {
    (void)timer;
    if (!_titleLoopLabel || _titleLoopLabel.hidden || _titleMarqueeCycle <= 0.0f)
        return;
    _titleMarqueeOffset += 0.75f;
    if (_titleMarqueeOffset >= _titleMarqueeCycle)
        _titleMarqueeOffset -= _titleMarqueeCycle;
    CGFloat height = _titleViewport.bounds.size.height;
    _titleLabel.frame = CGRectMake(-_titleMarqueeOffset, 0.0f,
                                   _titleMarqueeTextWidth, height);
    _titleLoopLabel.frame = CGRectMake(_titleMarqueeCycle - _titleMarqueeOffset,
                                       0.0f, _titleMarqueeTextWidth, height);
}

- (void)updateProgress:(NSTimer *)timer {
    (void)timer;
    if (!_player.track) return;
    _progress.value = [_player progress];
    _elapsedLabel.text = PlayerTime((NSUInteger)[_player currentTime]);
    _durationLabel.text = PlayerTime((NSUInteger)[_player duration]);
}

- (void)progressChanged:(UISlider *)slider {
    [_player seekToProgress:slider.value];
    [self updateProgress:nil];
}

- (void)searchPressed {
    [[NSNotificationCenter defaultCenter]
     postNotificationName:TuneTubeFocusSearchNotification object:nil];
}

- (void)libraryPressed {
    if (!_player || !_api) return;
    TuneLibraryVC *library = [[[TuneLibraryVC alloc] initWithPlayer:_player api:_api] autorelease];
    UINavigationController *navigation =
        [[[UINavigationController alloc] initWithRootViewController:library] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)morePressed {
    if (!_player.track) return;
    TunePlayerMenuVC *menu = [[[TunePlayerMenuVC alloc] initWithPlayer:_player
                                                                    api:_api
                                                               delegate:self] autorelease];
    menu.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)tunePlayerMenu:(TunePlayerMenuVC *)menu didSelectAction:(NSInteger)action {
    (void)menu;
    [self dismissViewControllerAnimated:YES completion:^{
        if (action != TunePlayerMenuActionClose)
            [self performMenuAction:action];
    }];
}

- (void)performMenuAction:(NSInteger)action {
    TuneTubeTrack *track = _player.track;
    if (!track) return;
    switch (action) {
        case TunePlayerMenuActionPlayNext:
            [_player enqueueTrack:track usingAPI:_api afterCurrent:YES];
            [self showMessage:TuneL(@"menu_play_next_added") message:track.title];
            break;
        case TunePlayerMenuActionPlaylist:
            [self showPlaylistPicker];
            break;
        case TunePlayerMenuActionShare: {
            NSString *text = [NSString stringWithFormat:@"%@\n%@\nhttps://youtu.be/%@",
                              track.title ?: @"",
                              TuneTubeTrackArtistText(track) ?: @"",
                              track.videoID ?: @""];
            Class activityClass = NSClassFromString(@"UIActivityViewController");
            if (activityClass) {
                UIActivityViewController *activity =
                    [[activityClass alloc] initWithActivityItems:
                     [NSArray arrayWithObject:text] applicationActivities:nil];
                [self presentViewController:activity animated:YES completion:nil];
                [activity release];
            } else {
                [[UIPasteboard generalPasteboard] setString:text];
                [self showMessage:TuneL(@"menu_share_copied") message:text];
            }
            break;
        }
        case TunePlayerMenuActionMix:
            [_player setContinuousPlayback:YES];
            [self showMessage:TuneL(@"menu_mix_enabled") message:nil];
            break;
        case TunePlayerMenuActionQueue:
            [_player enqueueTrack:track usingAPI:_api afterCurrent:NO];
            [self showMessage:TuneL(@"menu_queued") message:track.title];
            break;
        case TunePlayerMenuActionLibrary:
            if (TuneTubeTrackIsSaved(track)) TuneTubeRemoveTrack(track);
            else TuneTubeSaveTrack(track);
            [_favoriteButton setActive:TuneTubeTrackIsSaved(track)];
            [self showMessage:TuneTubeTrackIsSaved(track)
                     ? TuneL(@"added_library") : TuneL(@"removed_library")
                     message:track.title];
            break;
        case TunePlayerMenuActionDownload:
            [self downloadCurrentTrack];
            break;
        case TunePlayerMenuActionRemovePlaylist:
            [self showRemovePlaylistPicker];
            break;
        case TunePlayerMenuActionAlbum:
            [self openAlbum];
            break;
        case TunePlayerMenuActionArtist:
            [self artistPressed];
            break;
        case TunePlayerMenuActionClearQueue:
            [_player clearQueue];
            [self showMessage:TuneL(@"menu_queue_cleared") message:nil];
            break;
        case TunePlayerMenuActionSpeed:
            [self showPlaybackSpeedPicker];
            break;
        case TunePlayerMenuActionSleep:
            [self showSleepTimerPicker];
            break;
        default:
            break;
    }
}

- (void)showPlaylistPicker {
    TuneTubeTrack *track = _player.track;
    if (!track) return;
    [_menuTrack release];
    _menuTrack = [track retain];
    NSArray *names = TuneTubePlaylistNames();
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:TuneL(@"menu_add_playlist")
                                                     message:track.title
                                                    delegate:self
                                           cancelButtonTitle:TuneL(@"cancel")
                                           otherButtonTitles:TuneL(@"new_playlist"), nil] autorelease];
    for (NSString *name in names) [alert addButtonWithTitle:name];
    alert.tag = 9301;
    [alert show];
}

- (void)showRemovePlaylistPicker {
    TuneTubeTrack *track = _player.track;
    if (!track) return;
    [_menuTrack release];
    _menuTrack = [track retain];
    NSArray *names = TuneTubePlaylistsContainingTrack(track);
    if (!names.count) {
        [self showMessage:TuneL(@"menu_no_playlists") message:track.title];
        return;
    }
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:TuneL(@"menu_remove_playlist")
                                                     message:track.title
                                                    delegate:self
                                           cancelButtonTitle:TuneL(@"cancel")
                                           otherButtonTitles:nil] autorelease];
    for (NSString *name in names) [alert addButtonWithTitle:name];
    alert.tag = 9303;
    [alert show];
}

- (void)showPlaybackSpeedPicker {
    UIActionSheet *sheet = [[[UIActionSheet alloc] initWithTitle:TuneL(@"menu_speed")
                                                         delegate:self
                                                cancelButtonTitle:TuneL(@"cancel")
                                           destructiveButtonTitle:nil
                                                otherButtonTitles:@"1x", @"1.25x", @"1.5x", @"2x", nil] autorelease];
    sheet.tag = 9401;
    [sheet showInView:self.view];
}

- (void)showSleepTimerPicker {
    UIActionSheet *sheet = [[[UIActionSheet alloc] initWithTitle:TuneL(@"menu_sleep")
                                                         delegate:self
                                                cancelButtonTitle:TuneL(@"cancel")
                                           destructiveButtonTitle:nil
                                                otherButtonTitles:TuneL(@"menu_off"),
                                                                  TuneL(@"menu_15"),
                                                                  TuneL(@"menu_30"),
                                                                  TuneL(@"menu_60"), nil] autorelease];
    sheet.tag = 9402;
    [sheet showInView:self.view];
}

- (void)showMessage:(NSString *)title message:(NSString *)message {
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:title
                                                     message:message
                                                    delegate:nil
                                           cancelButtonTitle:TuneL(@"done")
                                           otherButtonTitles:nil] autorelease];
    [alert show];
}

- (void)downloadCurrentTrack {
    TuneTubeTrack *track = _player.track;
    if (!track || !_api) return;
    NSString *trackID = [track.videoID copy];
    NSString *trackTitle = [track.title copy];
    [self showMessage:TuneL(@"menu_download_started") message:track.title];
    [self retain];
    [_api audioURLForTrack:track completion:^(NSURL *audioURL, NSError *error) {
        if (error || !audioURL) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showMessage:TuneL(@"menu_download_failed")
                          message:error.localizedDescription];
                [self release];
            });
            [trackID release];
            [trackTitle release];
            return;
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:audioURL];
            NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                        NSUserDomainMask,
                                                                        YES) lastObject];
            NSString *fileName = [NSString stringWithFormat:@"TuneTube-%@.audio", trackID];
            NSString *path = [documents stringByAppendingPathComponent:fileName];
            BOOL saved = data.length > 0 && [data writeToFile:path atomically:YES];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showMessage:saved ? TuneL(@"menu_download_done")
                                      : TuneL(@"menu_download_failed")
                          message:trackTitle];
                [self release];
            });
        });
        [trackID release];
        [trackTitle release];
    }];
}

- (void)openAlbum {
    TuneTubeTrack *track = _player.track;
    if (!track || !_api) return;
    TuneAlbumVC *album = [[[TuneAlbumVC alloc] initWithTrack:track
                                                          api:_api
                                                       player:_player] autorelease];
    [self.navigationController pushViewController:album animated:YES];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == 9301) {
        if (buttonIndex == alertView.cancelButtonIndex) return;
        if (buttonIndex == 1) {
            UIAlertView *newAlert = [[[UIAlertView alloc] initWithTitle:TuneL(@"new_playlist")
                                                                message:nil
                                                               delegate:self
                                                      cancelButtonTitle:TuneL(@"cancel")
                                                      otherButtonTitles:TuneL(@"create"), nil] autorelease];
            newAlert.alertViewStyle = UIAlertViewStylePlainTextInput;
            newAlert.tag = 9302;
            [newAlert textFieldAtIndex:0].placeholder = TuneL(@"name_placeholder");
            [newAlert show];
            return;
        }
        NSUInteger playlistIndex = (NSUInteger)(buttonIndex - 2);
        NSArray *names = TuneTubePlaylistNames();
        if (playlistIndex < names.count && _menuTrack)
            TuneTubeAddTrackToPlaylist(_menuTrack, [names objectAtIndex:playlistIndex]);
    } else if (alertView.tag == 9302 && buttonIndex != alertView.cancelButtonIndex) {
        NSString *name = [[alertView textFieldAtIndex:0].text
                          stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length && _menuTrack) {
            TuneTubeCreatePlaylist(name);
            TuneTubeAddTrackToPlaylist(_menuTrack, name);
        }
    } else if (alertView.tag == 9303 && buttonIndex != alertView.cancelButtonIndex) {
        NSArray *names = TuneTubePlaylistsContainingTrack(_menuTrack);
        NSUInteger playlistIndex = (NSUInteger)(buttonIndex - 1);
        if (playlistIndex < names.count && _menuTrack) {
            NSString *name = [names objectAtIndex:playlistIndex];
            TuneTubeRemoveTrackFromPlaylist(_menuTrack, name);
            [self showMessage:TuneL(@"menu_remove_playlist") message:name];
        }
    }
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == actionSheet.cancelButtonIndex) return;
    if (actionSheet.tag == 9401) {
        NSArray *rates = [NSArray arrayWithObjects:
                          [NSNumber numberWithFloat:1.0f],
                          [NSNumber numberWithFloat:1.25f],
                          [NSNumber numberWithFloat:1.5f],
                          [NSNumber numberWithFloat:2.0f], nil];
        if (buttonIndex < (NSInteger)rates.count)
            [_player setPlaybackRate:[[rates objectAtIndex:(NSUInteger)buttonIndex] floatValue]];
    } else if (actionSheet.tag == 9402) {
        if (buttonIndex == 0) {
            [_player cancelSleepTimer];
            [self showMessage:TuneL(@"menu_sleep_off") message:nil];
        } else {
            NSArray *durations = [NSArray arrayWithObjects:
                                  [NSNumber numberWithDouble:15.0 * 60.0],
                                  [NSNumber numberWithDouble:30.0 * 60.0],
                                  [NSNumber numberWithDouble:60.0 * 60.0], nil];
            NSUInteger durationIndex = (NSUInteger)(buttonIndex - 1);
            if (durationIndex < durations.count) {
                [_player setSleepTimer:[[durations objectAtIndex:durationIndex] doubleValue]];
                [self showMessage:TuneL(@"menu_sleep")
                          message:[actionSheet buttonTitleAtIndex:buttonIndex]];
            }
        }
    }
}

- (void)backPressed {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)togglePressed {
    if (!_player.track) return;
    [_player toggle];
}

- (void)favoritePressed {
    TuneTubeTrack *track = _player.track;
    if (!track) return;
    if (TuneTubeTrackIsSaved(track)) TuneTubeRemoveTrack(track);
    else TuneTubeSaveTrack(track);
    [_favoriteButton setActive:TuneTubeTrackIsSaved(track)];
}

- (void)artistPressed {
    TuneTubeTrack *track = _player.track;
    TunePushArtistProfile(self, track, _api, _player);
}

- (void)nextTrackPressed {
    [_player nextTrack];
    if (_player.track) TuneTubeRecordTrack(_player.track);
}

- (void)previousTrackPressed {
    [_player previousTrack];
    if (_player.track) TuneTubeRecordTrack(_player.track);
}

- (void)repeatPressed {
    [_player setRepeating:!_player.isRepeating];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    if (event.type != UIEventTypeRemoteControl) return;
    switch (event.subtype) {
        case UIEventSubtypeRemoteControlPlay:
        case UIEventSubtypeRemoteControlPause:
        case UIEventSubtypeRemoteControlTogglePlayPause:
            [_player toggle];
            break;
        case UIEventSubtypeRemoteControlNextTrack:
            [_player nextTrack];
            break;
        case UIEventSubtypeRemoteControlPreviousTrack:
            [_player previousTrack];
            break;
        default:
            break;
    }
}

@end

void TunePushAlbum(UIViewController *source,
                   TuneTubeTrack *track,
                   TuneTubeAPI *api,
                   TuneTubePlayer *player) {
    if (!source || !track || !api || !player) return;
    TuneAlbumVC *album = [[[TuneAlbumVC alloc] initWithTrack:track
                                                          api:api
                                                       player:player] autorelease];
    [source.navigationController pushViewController:album animated:YES];
}
