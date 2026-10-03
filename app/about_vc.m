#import "about_vc.h"

#import <QuartzCore/QuartzCore.h>
#include <sys/sysctl.h>

#import "account_vc.h"
#import "rewind_account.h"
#import "rewind_config.h"
#import "rewind_theme.h"
#import "rewind_chrome.h"
#import "rewind_l10n.h"

static NSString * const kAboutTitle = @"t";
static NSString * const kAboutValue = @"v";
static NSString * const kAboutGlyph = @"g";
static NSString * const kAboutImage = @"i";
static NSString * const kAboutAction = @"a";

/* cap the width so ipad landscape rows do not stretch across the screen */
static CGFloat AboutSideMargin(CGFloat width) {
    CGFloat m = floorf((width - 700.0f) * 0.5f);
    return m > 12.0f ? m : 12.0f;
}

/* ios 5 and 6 inset grouped rows themselves; from ios 7 they run edge to edge */
static BOOL AboutRowsInsetBySystem(void) {
    return ![UITableView instancesRespondToSelector:@selector(setSeparatorInset:)];
}

static CGFloat AboutRowInset(UITableView *tv) {
    if (!AboutRowsInsetBySystem()) return AboutSideMargin(tv.bounds.size.width);
    return [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad ? 45.0f : 10.0f;
}

static NSString *AboutModel(void) {
    char machine[64];
    size_t len = sizeof machine;
    if (sysctlbyname("hw.machine", machine, &len, NULL, 0) != 0 || len == 0 || len > sizeof machine)
        return [[UIDevice currentDevice] model];
    machine[sizeof machine - 1] = '\0';
    NSString *code = [NSString stringWithUTF8String:machine];
    return [code length] ? code : [[UIDevice currentDevice] model];
}

static NSString *AboutSlice(void) {
#if defined(__arm64__) || defined(__aarch64__)
    return @"arm64";
#else
    return @"armv7";
#endif
}

static NSString *AboutVersion(void) {
    return [REWIND_VERSION hasPrefix:@"v"] ? [REWIND_VERSION substringFromIndex:1] : REWIND_VERSION;
}

static UIImage *AboutTintedIcon(NSString *name, UIColor *color) {
    /* the ic- glyphs are 96px masks from art/icons; the theme scales them to the row */
    if ([name hasPrefix:@"ic-"]) return RewindIcon([name substringFromIndex:3], RW(22.0f), color);
    UIImage *mask = [UIImage imageNamed:name];
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

@interface RewindAboutPlate : UIView {
    UIRectCorner _corners;
}
- (id)initWithCorners:(UIRectCorner)corners;
@end

@implementation RewindAboutPlate

- (id)initWithCorners:(UIRectCorner)corners {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _corners = corners;
    self.opaque = NO;
    self.backgroundColor = [UIColor clearColor];
    self.contentMode = UIViewContentModeRedraw;
    return self;
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic) {
        RewindChromeDrawGroupedSegment(self.bounds, (_corners & UIRectCornerTopLeft) != 0,
                                       (_corners & UIRectCornerBottomLeft) != 0, NO);
        return;
    }
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                               byRoundingCorners:_corners
                                                     cornerRadii:CGSizeMake(14.0f, 14.0f)];
    [RewindColorSurface() setFill];
    [path fill];
    CGRect line = CGRectMake(16.0f, self.bounds.size.height - 0.5f, self.bounds.size.width - 16.0f, 0.5f);
    if (!(_corners & UIRectCornerBottomLeft)) {
        [RewindColorDivider() setFill];
        UIRectFill(line);
    }
}

@end

@interface RewindAboutCell : UITableViewCell {
@public
    UIImageView *icon;
    UILabel *titleLbl;
    UILabel *valueLbl;
}
@end

@implementation RewindAboutCell

- (id)initWithReuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid])) {
        self.backgroundColor = [UIColor clearColor];
        icon = [[UIImageView alloc] initWithFrame:CGRectZero];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:icon];
        titleLbl = [[UILabel alloc] initWithFrame:CGRectZero];
        titleLbl.backgroundColor = [UIColor clearColor];
        titleLbl.font = [UIFont boldSystemFontOfSize:15.0f];
        titleLbl.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:titleLbl];
        valueLbl = [[UILabel alloc] initWithFrame:CGRectZero];
        valueLbl.backgroundColor = [UIColor clearColor];
        valueLbl.font = [UIFont systemFontOfSize:14.0f];
        valueLbl.numberOfLines = 0;
        valueLbl.lineBreakMode = NSLineBreakByWordWrapping;
        [self.contentView addSubview:valueLbl];
    }
    return self;
}

- (void)dealloc {
    [icon release];
    [titleLbl release];
    [valueLbl release];
    [super dealloc];
}

/* ios 7 and later draw grouped rows edge to edge; the plates need the margin */
- (void)setFrame:(CGRect)frame {
    if (!AboutRowsInsetBySystem() && frame.origin.x < 1.0f) {
        CGFloat m = AboutSideMargin(frame.size.width);
        frame = CGRectInset(frame, m, 0.0f);
    }
    [super setFrame:frame];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat x = 16.0f;
    if (icon.image) {
        icon.frame = CGRectMake(16.0f, 14.0f, 24.0f, 24.0f);
        x = 52.0f;
    } else {
        icon.frame = CGRectZero;
    }
    CGFloat w = MAX(40.0f, b.size.width - x - 12.0f);
    titleLbl.frame = CGRectMake(x, 12.0f, w, 20.0f);
    CGFloat valueH = b.size.height - 36.0f - 10.0f;
    valueLbl.frame = CGRectMake(x, 34.0f, w, valueH > 0.0f ? valueH : 0.0f);
}

@end

enum { kAboutHeroHeight = 262 };

@interface RewindAboutHero : UIView {
@public
    UIImageView *icon;
    UILabel *name;
    UILabel *tagline;
    UIView *versionTile;
    UIView *systemTile;
    UILabel *versionCaption;
    UILabel *versionValue;
    UILabel *systemCaption;
    UILabel *systemValue;
}
- (void)applyTheme;
@end

static UILabel *AboutHeroLabel(UIView *host, UIFont *font) {
    UILabel *l = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    l.backgroundColor = [UIColor clearColor];
    l.font = font;
    l.textAlignment = NSTextAlignmentCenter;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    l.adjustsFontSizeToFitWidth = YES;
    [host addSubview:l];
    return l;
}

@implementation RewindAboutHero

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        NSString *path = [[NSBundle mainBundle] pathForResource:@"rewind-fall" ofType:@"png"];
        icon = [[UIImageView alloc] initWithImage:path ? [UIImage imageWithContentsOfFile:path] : nil];
        icon.contentMode = UIViewContentModeScaleAspectFill;
        [self addSubview:icon];
        name = [AboutHeroLabel(self, [UIFont boldSystemFontOfSize:30.0f]) retain];
        name.text = @"Rewind";
        tagline = [AboutHeroLabel(self, [UIFont systemFontOfSize:14.0f]) retain];
        versionTile = [[UIView alloc] initWithFrame:CGRectZero];
        systemTile = [[UIView alloc] initWithFrame:CGRectZero];
        versionTile.layer.cornerRadius = 14.0f;
        systemTile.layer.cornerRadius = 14.0f;
        [self addSubview:versionTile];
        [self addSubview:systemTile];
        versionCaption = [AboutHeroLabel(versionTile, [UIFont systemFontOfSize:12.0f]) retain];
        versionValue = [AboutHeroLabel(versionTile, [UIFont boldSystemFontOfSize:17.0f]) retain];
        systemCaption = [AboutHeroLabel(systemTile, [UIFont systemFontOfSize:12.0f]) retain];
        systemValue = [AboutHeroLabel(systemTile, [UIFont boldSystemFontOfSize:17.0f]) retain];
        versionValue.text = AboutVersion();
        systemCaption.text = @"iOS";
        systemValue.text = [NSString stringWithFormat:@"%@ · %@",
                            [[UIDevice currentDevice] systemVersion], AboutSlice()];
    }
    return self;
}

- (void)dealloc {
    [icon release];
    [name release];
    [tagline release];
    [versionTile release];
    [systemTile release];
    [versionCaption release];
    [versionValue release];
    [systemCaption release];
    [systemValue release];
    [super dealloc];
}

- (void)applyTheme {
    BOOL classic = RewindCurrentTheme() == RewindThemeSkeuomorphic;
    /* the black grouped look: embossed white text, the tiles dark groups with a grey rim */
    name.textColor = classic ? RewindChromeGroupedTextColor() : RewindColorText();
    tagline.textColor = classic ? RewindChromeGroupedCaptionColor() : RewindColorTextSecondary();
    versionCaption.textColor = classic ? RewindChromeGroupedCaptionColor() : RewindColorTextSecondary();
    systemCaption.textColor = classic ? RewindChromeGroupedCaptionColor() : RewindColorTextSecondary();
    versionValue.textColor = classic ? RewindChromeGroupedTextColor() : RewindColorText();
    systemValue.textColor = classic ? RewindChromeGroupedTextColor() : RewindColorText();
    for (UILabel *label in [NSArray arrayWithObjects:name, tagline, nil]) {
        label.shadowColor = classic ? [UIColor blackColor] : nil;
        label.shadowOffset = CGSizeMake(0.0f, -1.0f);
    }
    for (UIView *tile in [NSArray arrayWithObjects:versionTile, systemTile, nil]) {
        tile.backgroundColor = classic ? [UIColor colorWithWhite:0.15f alpha:1.0f] : RewindColorSurface();
        tile.layer.cornerRadius = classic ? 10.0f : 14.0f;
        tile.layer.borderWidth = classic ? 1.0f : 0.0f;
        tile.layer.borderColor = [UIColor colorWithWhite:0.30f alpha:1.0f].CGColor;
    }
    tagline.text = RewindL(@"about_tagline");
    versionCaption.text = RewindL(@"about_version");
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat side = AboutRowsInsetBySystem()
        ? ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad ? 45.0f : 10.0f)
        : AboutSideMargin(w);
    icon.frame = CGRectMake(floorf((w - 88.0f) * 0.5f), 22.0f, 88.0f, 88.0f);
    name.frame = CGRectMake(side, 118.0f, w - side * 2.0f, 38.0f);
    tagline.frame = CGRectMake(side, 156.0f, w - side * 2.0f, 18.0f);
    CGFloat gap = 10.0f;
    CGFloat tileW = floorf((w - side * 2.0f - gap) * 0.5f);
    versionTile.frame = CGRectMake(side, 188.0f, tileW, 66.0f);
    systemTile.frame = CGRectMake(w - side - tileW, 188.0f, tileW, 66.0f);
    versionCaption.frame = CGRectMake(8.0f, 11.0f, tileW - 16.0f, 16.0f);
    versionValue.frame = CGRectMake(8.0f, 29.0f, tileW - 16.0f, 24.0f);
    systemCaption.frame = versionCaption.frame;
    systemValue.frame = versionValue.frame;
}

@end

@interface RewindAboutVC ()
- (void)rebuildRows;
@end

@implementation RewindAboutVC

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _table.dataSource = nil;
    _table.delegate = nil;
    [_table release];
    [_hero release];
    [_backgroundGradient release];
    [_sections release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = RewindColorBackground();
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    CGRect b = self.view.bounds;
    _backgroundGradient = [[CAGradientLayer layer] retain];
    [self.view.layer insertSublayer:_backgroundGradient atIndex:0];

    _table = [[UITableView alloc] initWithFrame:b style:UITableViewStyleGrouped];
    _table.dataSource = self;
    _table.delegate = self;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.backgroundColor = [UIColor clearColor];
    _table.backgroundView = nil;
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_table];

    _hero = [[RewindAboutHero alloc] initWithFrame:CGRectMake(0, 0, b.size.width, kAboutHeroHeight)];
    _table.tableHeaderView = _hero;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(applyTheme:)
                   name:RewindThemeDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(reloadContent:)
                   name:REWIND_LANGUAGE_DID_CHANGE_NOTIFICATION object:nil];
    [center addObserver:self selector:@selector(reloadContent:)
                   name:RewindAccountDidChangeNotification object:nil];
    [self applyTheme:nil];
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    BOOL classic = RewindCurrentTheme() == RewindThemeSkeuomorphic;
    self.view.backgroundColor = classic ? RewindChromeGroupedBackground() : RewindColorCanvas();
    _backgroundGradient.hidden = classic;
    RewindStyleNavigationBar(self.navigationController.navigationBar);
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)RewindColorBackground().CGColor,
                                  (id)RewindColorBackground().CGColor,
                                  (id)RewindColorBackground().CGColor, nil];
    [_hero applyTheme];
    [self reloadContent:nil];
}

- (void)reloadContent:(NSNotification *)note {
    (void)note;
    self.title = RewindL(@"about");
    self.navigationItem.leftBarButtonItem =
        RewindBarButtonItem(RewindL(@"settings"), self, @selector(backPressed));
    [_hero applyTheme];
    [self rebuildRows];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    _backgroundGradient.frame = b;
    _table.frame = b;
/* uitableview only rereads the header height when the view is set again */
    if (fabsf((float)(_hero.frame.size.width - b.size.width)) > 0.5f) {
        _hero.frame = CGRectMake(0, 0, b.size.width, kAboutHeroHeight);
        _table.tableHeaderView = _hero;
        [_table reloadData];
    }
}

- (NSDictionary *)row:(NSString *)titleKey value:(NSString *)value
                glyph:(NSString *)glyph action:(SEL)action {
    NSMutableDictionary *row = [NSMutableDictionary dictionaryWithCapacity:4];
    [row setObject:RewindL(titleKey) forKey:kAboutTitle];
    [row setObject:value ?: @"" forKey:kAboutValue];
    if (glyph) [row setObject:glyph forKey:kAboutGlyph];
    if (action) [row setObject:NSStringFromSelector(action) forKey:kAboutAction];
    return row;
}

- (NSDictionary *)section:(NSString *)title rows:(NSArray *)rows {
    return [NSDictionary dictionaryWithObjectsAndKeys:title, kAboutTitle, rows, kAboutValue, nil];
}

- (void)rebuildRows {
    NSMutableDictionary *developer = [NSMutableDictionary dictionaryWithDictionary:
                                      [self row:@"about_developer" value:@"sqmrak" glyph:nil action:NULL]];
    UIImage *face = [UIImage imageNamed:@"sqmrak.jpg"];
    if (face) [developer setObject:face forKey:kAboutImage];

    NSString *account = RewindAccountIsSignedIn()
        ? [NSString stringWithFormat:RewindL(@"about_account_on"),
           RewindAccountEmail() ?: RewindAccountName() ?: @"YouTube"]
        : RewindL(@"about_account_off");

    NSArray *sections = [NSArray arrayWithObjects:
        [self section:RewindL(@"about_device") rows:[NSArray arrayWithObjects:
            [self row:@"about_model" value:AboutModel() glyph:nil action:NULL],
            [self row:@"about_ios" value:[[UIDevice currentDevice] systemVersion] glyph:nil action:NULL],
            [self row:@"about_arch" value:AboutSlice() glyph:nil action:NULL],
            nil]],
        [self section:@"Rewind" rows:[NSArray arrayWithObjects:
            [self row:@"about_how" value:RewindL(@"about_how_value") glyph:@"menu-mix.png" action:NULL],
            [self row:@"about_account" value:account glyph:@"menu-artist.png"
               action:RewindAccountIsSignedIn() ? NULL : @selector(signInPressed)],
            [self row:@"about_compat" value:@"iOS 5-16 · armv7 + arm64" glyph:@"menu-speed.png" action:NULL],
            nil]],
        [self section:RewindL(@"about_links") rows:[NSArray arrayWithObjects:
            [self row:@"about_github" value:@"github.com/sqmrak" glyph:@"ic-code"
               action:@selector(githubPressed)],
            [self row:@"about_telegram" value:@"t.me/sqmrakdev" glyph:@"ic-send"
               action:@selector(telegramPressed)],
            nil]],
        [self section:RewindL(@"about_credits") rows:[NSArray arrayWithObjects:
            developer,
            [self row:@"about_thanks" value:@"@menstry, @KirillPro671488, @inraxx, @anazerka, @shizotoaster, "
                                             @"@Lineysom, @not_a_modder, @s3dativee, @Vladus324"
                  glyph:nil action:NULL],
            [self row:@"about_disclaimer_title" value:RewindL(@"about_disclaimer") glyph:nil action:NULL],
            nil]],
        nil];
    [_sections release];
    _sections = [sections retain];
    [_table reloadData];
}

- (NSDictionary *)rowAtIndexPath:(NSIndexPath *)ip {
    NSArray *rows = [[_sections objectAtIndex:(NSUInteger)ip.section] objectForKey:kAboutValue];
    return [rows objectAtIndex:(NSUInteger)ip.row];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    (void)tv;
    return (NSInteger)[[[_sections objectAtIndex:(NSUInteger)s] objectForKey:kAboutValue] count];
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *row = [self rowAtIndexPath:ip];
    NSString *value = [row objectForKey:kAboutValue];
    if (![value length]) return 52.0f;
    BOOL leading = [row objectForKey:kAboutGlyph] || [row objectForKey:kAboutImage];
    CGFloat w = tv.bounds.size.width - AboutRowInset(tv) * 2.0f -
                (leading ? 52.0f : 16.0f) - 12.0f -
                ([row objectForKey:kAboutAction] ? 34.0f : 0.0f);
    if (w < 40.0f) w = 40.0f;
    CGSize size = RewindTextSize(value, [UIFont systemFontOfSize:14.0f], w);
    return MAX(56.0f, ceilf(size.height) + 36.0f + 12.0f);
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    (void)tv; (void)s;
    return 36.0f;
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    (void)tv; (void)s;
    return 4.0f;
}

/* ios 14 header views reset their text colour, so the label is our own */
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    CGFloat w = tv.bounds.size.width;
    UIView *wrap = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 36.0f)] autorelease];
    wrap.backgroundColor = [UIColor clearColor];
    CGFloat x = AboutRowInset(tv) + 16.0f;
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectMake(x, 12.0f, w - x * 2.0f, 20.0f)] autorelease];
    label.backgroundColor = [UIColor clearColor];
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic) {
        label.font = RewindChromeFont(17.0f, YES);
        label.frame = CGRectMake(x - 6.0f, 10.0f, w - (x - 6.0f) * 2.0f, 22.0f);
        label.textColor = RewindChromeGroupedCaptionColor();
        label.shadowColor = [UIColor blackColor];
        label.shadowOffset = CGSizeMake(0.0f, -1.0f);
    } else {
        label.font = [UIFont boldSystemFontOfSize:13.0f];
        label.textColor = RewindColorHeading();
    }
    label.text = [[_sections objectAtIndex:(NSUInteger)s] objectForKey:kAboutTitle];
    [wrap addSubview:label];
    return wrap;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    (void)tv; (void)s;
    return [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"about";
    RewindAboutCell *cell = (RewindAboutCell *)[tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[[RewindAboutCell alloc] initWithReuseIdentifier:cid] autorelease];
    NSDictionary *row = [self rowAtIndexPath:ip];
    BOOL tappable = [row objectForKey:kAboutAction] != nil;
    NSInteger count = [self tableView:tv numberOfRowsInSection:ip.section];
    UIRectCorner corners = 0;
    if (ip.row == 0) corners |= UIRectCornerTopLeft | UIRectCornerTopRight;
    if (ip.row == count - 1) corners |= UIRectCornerBottomLeft | UIRectCornerBottomRight;
    cell.backgroundView = [[[RewindAboutPlate alloc] initWithCorners:corners] autorelease];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic) {
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessoryView = tappable ? RewindChromeDisclosure() : nil;
    } else {
        cell.accessoryType = tappable ? UITableViewCellAccessoryDisclosureIndicator
                                      : UITableViewCellAccessoryNone;
    }

    BOOL classic = RewindCurrentTheme() == RewindThemeSkeuomorphic;
    cell->titleLbl.textColor = classic ? RewindChromeGroupedTextColor() : RewindColorText();
    cell->titleLbl.text = [row objectForKey:kAboutTitle];
    cell->valueLbl.textColor = classic ? RewindChromeGroupedValueColor() : RewindColorTextSecondary();
    cell->valueLbl.text = [row objectForKey:kAboutValue];

    UIImage *image = [row objectForKey:kAboutImage];
    NSString *glyph = [row objectForKey:kAboutGlyph];
    cell->icon.image = image ?: (glyph ? AboutTintedIcon(glyph, classic ? RewindChromeGroupedCaptionColor() : RewindColorText()) : nil);
    cell->icon.layer.cornerRadius = image ? 12.0f : 0.0f;
    cell->icon.layer.masksToBounds = image != nil;
    [cell setNeedsLayout];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *action = [[self rowAtIndexPath:ip] objectForKey:kAboutAction];
    if ([action length]) [self performSelector:NSSelectorFromString(action)];
}

- (void)signInPressed {
    RewindAccountLoginVC *login = [[[RewindAccountLoginVC alloc] init] autorelease];
    [self.navigationController pushViewController:login animated:YES];
}

- (void)githubPressed {
    NSURL *url = [NSURL URLWithString:@"https://github.com/sqmrak"];
    if (url) [[UIApplication sharedApplication] openURL:url];
}

- (void)telegramPressed {
    NSURL *url = [NSURL URLWithString:@"https://t.me/sqmrakdev"];
    if (url) [[UIApplication sharedApplication] openURL:url];
}

- (void)backPressed {
    [self.navigationController popViewControllerAnimated:YES];
}

@end
