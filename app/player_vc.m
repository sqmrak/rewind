#import "player_vc.h"

#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>
#include <math.h>
#include "rewind_layout.h"

#import "rewind_api.h"
#import "rewind_player.h"
#import "library_vc.h"
#import "playlist_vc.h"
#import "artist_vc.h"
#import "rewind_image_cache.h"
#import "rewind_theme.h"
#import "rewind_l10n.h"
#import "rewind_account.h"
#import "rewind_download.h"
#import "rewind_ui.h"

static NSString *PlayerTime(NSUInteger seconds) {
    return [NSString stringWithFormat:@"%lu:%02lu",
            (unsigned long)(seconds / 60), (unsigned long)(seconds % 60)];
}

/* sample saturated cells, a whole-cover average loses the accent colour */
static void RewindPlayerTint(UIImage *image, UIColor **top, UIColor **bottom) {
    *top = [UIColor colorWithWhite:0.16f alpha:1.0f];
    *bottom = [UIColor colorWithWhite:0.07f alpha:1.0f];
    CGImageRef source = image.CGImage;
    if (!source) return;

    const int grid = 12;
    unsigned char pixels[12 * 12 * 4];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, grid, grid, 8, grid * 4, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return;
    /* keep sampled colours separate instead of blending neighbouring cells */
    CGContextSetInterpolationQuality(context, kCGInterpolationNone);
    CGContextDrawImage(context, CGRectMake(0, 0, grid, grid), source);
    CGContextRelease(context);

    CGFloat bestHue = 0.0f, bestSaturation = 0.0f;
    BOOL found = NO;
    for (int i = 0; i < grid * grid; ++i) {
        unsigned char *p = pixels + i * 4;
        UIColor *sample = [UIColor colorWithRed:p[0] / 255.0f green:p[1] / 255.0f
                                            blue:p[2] / 255.0f alpha:1.0f];
        CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 1;
        if (![sample getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha]) continue;
        /* near-black and near-white cells (letterboxing, blown highlights) carry no usable colour */
        if (brightness < 0.12f || brightness > 0.92f) continue;
        if (!found || saturation > bestSaturation) {
            bestHue = hue;
            bestSaturation = saturation;
            found = YES;
        }
    }
    if (!found) return;
    CGFloat saturation = MIN(0.75f, MAX(0.35f, bestSaturation));
    *top = [UIColor colorWithHue:bestHue saturation:saturation brightness:0.46f alpha:1.0f];
    *bottom = [UIColor colorWithHue:bestHue saturation:saturation brightness:0.16f alpha:1.0f];
}

@interface RewindSeekBar : UIControl {
    UIView *_track;
    UIView *_fill;
    UIView *_thumb;
    float _value;
    BOOL _dragging;
    BOOL _styled;
    BOOL _styledDragging;
}
@property(nonatomic, assign) float value;
@property(nonatomic, readonly, getter=isDragging) BOOL dragging;
@end

@implementation RewindSeekBar

@synthesize dragging = _dragging;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _track = [[UIView alloc] initWithFrame:CGRectZero];
    _track.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.25f];
    _track.userInteractionEnabled = NO;
    [self addSubview:_track];
    _fill = [[UIView alloc] initWithFrame:CGRectZero];
    _fill.backgroundColor = RewindColorText();
    _fill.userInteractionEnabled = NO;
    [self addSubview:_fill];
    _thumb = [[UIView alloc] initWithFrame:CGRectZero];
    _thumb.backgroundColor = RewindColorText();
    _thumb.userInteractionEnabled = NO;
    /* cache the thumb bitmap to avoid rerasterizing its shadow on every 0.4 s tick */
    _thumb.layer.shouldRasterize = YES;
    _thumb.layer.rasterizationScale = [UIScreen mainScreen].scale;
    [self addSubview:_thumb];
    return self;
}

- (void)dealloc {
    [_track release];
    [_fill release];
    [_thumb release];
    [super dealloc];
}

- (float)value {
    return _value;
}

- (void)setValue:(float)value {
    _value = MAX(0.0f, MIN(1.0f, value));
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat line = RW(2.0f), mid = floorf(b.size.height * 0.5f);
    CGFloat x = floorf(b.size.width * _value);
    CGFloat thumb = _dragging ? RW(18.0f) : RW(12.0f);
    _track.frame = CGRectMake(0, mid - line * 0.5f, b.size.width, line);
    _fill.frame = CGRectMake(0, mid - line * 0.5f, x, line);
    _thumb.bounds = CGRectMake(0, 0, thumb, thumb);
    _thumb.center = CGPointMake(MAX(thumb * 0.5f, MIN(b.size.width - thumb * 0.5f, x)), mid);

    /* rebuild the thumb only when its size changes */
    if (_styled && _styledDragging == _dragging) return;
    _styled = YES;
    _styledDragging = _dragging;

    _track.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.25f];
    _track.layer.cornerRadius = line * 0.5f;
    _fill.backgroundColor = RewindColorText();
    _fill.layer.cornerRadius = line * 0.5f;
    _thumb.layer.cornerRadius = thumb * 0.5f;
    _thumb.backgroundColor = RewindColorText();
}

- (void)trackTouch:(UITouch *)touch {
    CGFloat width = MAX(1.0f, self.bounds.size.width);
    _value = MAX(0.0f, MIN(1.0f, [touch locationInView:self].x / width));
    [self layoutSubviews];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    (void)event;
    _dragging = YES;
    RewindAnimate(0.15, ^{ [self layoutSubviews]; }, nil);
    [self trackTouch:touch];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    (void)event;
    [self trackTouch:touch];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    (void)event;
    if (touch) [self trackTouch:touch];
    _dragging = NO;
    RewindSpring(0.3, ^{ [self layoutSubviews]; }, nil);
    [self sendActionsForControlEvents:UIControlEventEditingDidEnd];
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    (void)event;
    _dragging = NO;
    [self setNeedsLayout];
}

@end

@interface RewindAlbumVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    RewindTrack *_seedTrack;
    RewindAPI *_api;
    RewindPlayer *_player;
    NSString *_albumName;
    NSString *_artistName;
    NSMutableArray *_tracks;
    UITableView *_table;
    UILabel *_status;
    CAGradientLayer *_gradient;
}
- (id)initWithTrack:(RewindTrack *)track api:(RewindAPI *)api player:(RewindPlayer *)player;
@end

@implementation RewindAlbumVC

- (id)initWithTrack:(RewindTrack *)track api:(RewindAPI *)api player:(RewindPlayer *)player {
    self = [super init];
    if (self) {
        _seedTrack = [track retain];
        _api = [api retain];
        _player = [player retain];
        _albumName = [(track.album.length ? track.album : track.title) copy];
        _artistName = [RewindTrackArtistText(track) copy];
        _tracks = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
    view.backgroundColor = RewindColorBackground();
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _albumName;
    self.navigationItem.leftBarButtonItem = RewindBarButtonItem(RewindL(@"back"),
                                                                    self,
                                                                    @selector(backPressed));
    _gradient = [[CAGradientLayer layer] retain];
    [self.view.layer insertSublayer:_gradient atIndex:0];
    _status = [[UILabel alloc] initWithFrame:CGRectZero];
    _status.backgroundColor = [UIColor clearColor];
    _status.textColor = [UIColor whiteColor];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.font = [UIFont systemFontOfSize:14.0f];
    _status.text = RewindL(@"loading_tracks");
    [self.view addSubview:_status];
    _table = [[RewindTableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = [UIColor clearColor];
    _table.backgroundView = nil;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.rowHeight = RW(68.0f);
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyTheme:)
                                                 name:RewindThemeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(languageChanged:)
                                                 name:REWIND_LANGUAGE_DID_CHANGE_NOTIFICATION object:nil];
    [self applyTheme:nil];

    NSString *query = _artistName.length
        ? [NSString stringWithFormat:@"%@ %@", _artistName, _albumName]
        : _albumName;
    [_api search:query completion:^(NSArray *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                _status.text = RewindL(@"couldnt_load_tracks");
                return;
            }
            [_tracks removeAllObjects];
            for (RewindTrack *track in tracks) {
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
    self.view.backgroundColor = RewindColorBackground();
    RewindStyleNavigationBar(self.navigationController.navigationBar);
    _gradient.colors = [NSArray arrayWithObjects:
                        (id)[UIColor colorWithWhite:0.12f alpha:1.0f].CGColor,
                        (id)RewindColorBackground().CGColor, nil];
    _status.textColor = RewindColorText();
    [_table reloadData];
}

- (void)languageChanged:(NSNotification *)note {
    (void)note;
    self.navigationItem.leftBarButtonItem = RewindBarButtonItem(RewindL(@"back"), self, @selector(backPressed));
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
    static NSString *cellID = @"RewindAlbumTrackCell";
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
        title.textColor = RewindColorText();
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
    RewindTrack *track = [_tracks objectAtIndex:(NSUInteger)indexPath.row];
    cell.backgroundColor = [UIColor clearColor];
    cell.backgroundView = nil;
    cell.contentView.backgroundColor = [UIColor clearColor];
    CGFloat textWidth = MAX(80.0f, tableView.bounds.size.width - 90.0f);
    UIImageView *artwork = (UIImageView *)[cell.contentView viewWithTag:3001];
    UILabel *title = (UILabel *)[cell.contentView viewWithTag:3002];
    UILabel *detail = (UILabel *)[cell.contentView viewWithTag:3003];
    title.textColor = RewindColorText();
    detail.textColor = [UIColor colorWithWhite:1.0f alpha:0.7f];
    artwork.layer.borderWidth = 0.0f;
    title.frame = CGRectMake(78.0f, 10.0f, textWidth, 22.0f);
    detail.frame = CGRectMake(78.0f, 36.0f, textWidth, 18.0f);
    title.text = track.title;
    detail.text = [NSString stringWithFormat:@"%@  %lu:%02lu",
                   RewindTrackArtistText(track),
                   (unsigned long)(track.duration / 60),
                   (unsigned long)(track.duration % 60)];
    artwork.image = [UIImage imageNamed:@"Icon.png"];
    NSString *requestedURL = [track.thumbnailURL copy];
    RewindLoadImage(requestedURL, ^(UIImage *image) {
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
    RewindTrack *track = [_tracks objectAtIndex:(NSUInteger)indexPath.row];
    [_player setQueue:_tracks selectedIndex:indexPath.row usingAPI:_api];
    RewindRecordTrack(track);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

/* lines that are not sung yet stay readable but clearly behind the active white one */
static UIColor *RewindLyricDimColor(void) { return [UIColor colorWithWhite:1.0f alpha:0.36f]; }

@interface RewindPlayerVC ()
- (void)updatePanelPills;
- (CGFloat)panelHeaderHeight;
- (void)layoutPanelUnderline:(BOOL)animated;
- (void)shareLyricsPressed;
- (void)translatePressed;
- (void)refresh:(NSNotification *)note;
- (void)showTab:(NSInteger)tab;
- (void)loadLyrics;
- (void)updateLyricsTabs;
- (void)lyricTapped:(UITapGestureRecognizer *)tap;
- (void)rebuildPanel;
- (void)performMenuAction:(NSInteger)action;
- (void)showPlaylistPicker;
@end

@implementation RewindPlayerVC

- (id)initWithPlayer:(RewindPlayer *)player {
    return [self initWithPlayer:player api:nil];
}

- (id)initWithPlayer:(RewindPlayer *)player api:(RewindAPI *)api {
    self = [super init];
    if (!self) return nil;
    _player = [player retain];
    _api = [api retain];
    _selectedTab = -1;
    _lastLyricIndex = -1;
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_progressTimer invalidate];
    [_progressTimer release];
    [_player release];
    [_api release];
    [_background release];
    [_closeButton release];
    [_moreButton release];
    [_artwork release];
    [_titleLabel release];
    [_artistLabel release];
    [_artistTap release];
    [_actions release];
    [_likePill release];
    [_likeButton release];
    [_dislikeButton release];
    [_actionPills release];
    [_progress release];
    [_elapsedLabel release];
    [_durationLabel release];
    [_shuffleButton release];
    [_previousButton release];
    [_playButton release];
    [_playSpinner release];
    [_nextButton release];
    [_repeatButton release];
    [_tabBar release];
    [_tabButtons release];
    [_panel release];
    [_panelBackground release];
    [_panelTitle release];
    [_panelPlay release];
    [_panelPlaySpinner release];
    [_panelScroll release];
    [_panelArt release];
    [_panelArtist release];
    [_panelUnderline release];
    [_panelFade release];
    [_panelShare release];
    [_panelTranslate release];
    [_translatedLines release];
    [_lyrics release];
    [_related release];
    [_lyricsError release];
    [_relatedError release];
    [_menuTrack release];
    [_displayTrack release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = RewindColorBackground();
    self.view = view;
}

- (RewindIconButton *)addIcon:(NSString *)name points:(CGFloat)points selector:(SEL)selector {
    RewindIconButton *button = [[RewindIconButton buttonWithIcon:name points:points] retain];
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
    return button;
}

- (UILabel *)addLabel:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.backgroundColor = [UIColor clearColor];
    label.textColor = color;
    label.font = font;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.view addSubview:label];
    return label;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.navigationController setNavigationBarHidden:YES animated:NO];
    _background = [[CAGradientLayer layer] retain];
    UIColor *top = nil, *bottom = nil;
    RewindPlayerTint(nil, &top, &bottom);
    _background.colors = [NSArray arrayWithObjects:(id)top.CGColor, (id)bottom.CGColor, nil];
    [self.view.layer insertSublayer:_background atIndex:0];
    UIColor *soft = [UIColor colorWithWhite:1.0f alpha:0.7f];
    _closeButton = [self addIcon:@"chevron-down" points:RW(30.0f) selector:@selector(closePressed)];
    _moreButton = [self addIcon:@"more" points:RW(26.0f) selector:@selector(morePressed)];
    _artwork = [[RewindArtworkView alloc] initWithFrame:CGRectZero];
    [_artwork setCornerRadius:RW(8.0f)];
    [self.view addSubview:_artwork];
    _titleLabel = [[RewindMarqueeLabel alloc] initWithFrame:CGRectZero];
    [_titleLabel setFont:RewindFont(24.0f, RewindWeightBold)];
    [_titleLabel setTextColor:RewindColorText()];
    [self.view addSubview:_titleLabel];
    _artistLabel = [self addLabel:RewindFont(17.0f, RewindWeightRegular) color:soft];
    _artistTap = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    [_artistTap addTarget:self action:@selector(artistPressed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_artistTap];

    /* the action pills scroll sideways like the youtube music chip row */
    _actions = [[RewindScrollView alloc] initWithFrame:CGRectZero];
    _actions.showsHorizontalScrollIndicator = NO;
    _actions.alwaysBounceHorizontal = YES;
    _actions.scrollsToTop = NO;
    [self.view addSubview:_actions];
    _likePill = [[UIView alloc] initWithFrame:CGRectZero];
    _likePill.backgroundColor = RewindColorOverlay();
    [_actions addSubview:_likePill];
    _likeButton = [[RewindIconButton buttonWithIcon:@"thumb-up" points:RW(22.0f)] retain];
    [_likeButton addTarget:self action:@selector(likePressed) forControlEvents:UIControlEventTouchUpInside];
    [_likePill addSubview:_likeButton];
    UIView *divider = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    divider.tag = 77;
    divider.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.25f];
    [_likePill addSubview:divider];
    _dislikeButton = [[RewindIconButton buttonWithIcon:@"thumb-down" points:RW(22.0f)] retain];
    [_dislikeButton addTarget:self action:@selector(dislikePressed) forControlEvents:UIControlEventTouchUpInside];
    [_likePill addSubview:_dislikeButton];
    _actionPills = [[NSMutableArray alloc] init];
    NSArray *pillIcons = [NSArray arrayWithObjects:@"playlist-add", @"share", @"mix", @"download", nil];
    NSArray *pillTitles = [NSArray arrayWithObjects:RewindL(@"player_save"), RewindL(@"menu_share"),
                           RewindL(@"player_mix"), RewindL(@"menu_download"), nil];
    SEL pillActions[4] = { @selector(savePressed), @selector(sharePressed), @selector(mixPressed), @selector(downloadPressed) };
    for (NSUInteger index = 0; index < pillIcons.count; ++index) {
        RewindPillButton *pill = [[[RewindPillButton alloc] initWithStyle:RewindPillStyleFilled
                                                                     icon:[pillIcons objectAtIndex:index]
                                                                    title:[pillTitles objectAtIndex:index]] autorelease];
        [pill addTarget:self action:pillActions[index] forControlEvents:UIControlEventTouchUpInside];
        [_actions addSubview:pill];
        [_actionPills addObject:pill];
    }

    _progress = [[RewindSeekBar alloc] initWithFrame:CGRectZero];
    [_progress addTarget:self action:@selector(progressDragged:) forControlEvents:UIControlEventValueChanged];
    [_progress addTarget:self action:@selector(progressChanged:) forControlEvents:UIControlEventEditingDidEnd];
    [self.view addSubview:_progress];
    _elapsedLabel = [self addLabel:RewindFont(12.0f, RewindWeightRegular) color:soft];
    _durationLabel = [self addLabel:RewindFont(12.0f, RewindWeightRegular) color:soft];
    _durationLabel.textAlignment = NSTextAlignmentRight;
    _shuffleButton = [self addIcon:@"shuffle" points:RW(28.0f) selector:@selector(shufflePressed)];
    _previousButton = [self addIcon:@"prev" points:RW(40.0f) selector:@selector(previousPressed)];
    _playButton = [self addIcon:@"play" points:RW(38.0f) selector:@selector(playPressed)];
    _nextButton = [self addIcon:@"next" points:RW(40.0f) selector:@selector(nextPressed)];
    _repeatButton = [self addIcon:@"repeat" points:RW(28.0f) selector:@selector(repeatPressed)];
    _playButton.backgroundColor = RewindColorText();
    [_playButton setIconColor:[UIColor blackColor]];
    _playSpinner = [[UIActivityIndicatorView alloc]
                    initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    _playSpinner.hidesWhenStopped = YES;
    _playSpinner.userInteractionEnabled = NO;
    [self.view addSubview:_playSpinner];

    _tabBar = [[UIView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_tabBar];
    _tabButtons = [[NSMutableArray alloc] init];
    NSArray *labels = [NSArray arrayWithObjects:RewindL(@"player_next"), RewindL(@"player_lyrics"),
                       RewindL(@"player_related"), nil];
    for (NSUInteger index = 0; index < labels.count; ++index) {
        UIButton *tab = [UIButton buttonWithType:UIButtonTypeCustom];
        tab.tag = (NSInteger)index;
        tab.titleLabel.font = RewindFont(14.0f, RewindWeightMedium);
        [tab setTitle:[[labels objectAtIndex:index] uppercaseString] forState:UIControlStateNormal];
        [tab setTitleColor:soft forState:UIControlStateNormal];
        [tab setTitleColor:RewindColorText() forState:UIControlStateHighlighted];
        [tab addTarget:self action:@selector(tabPressed:) forControlEvents:UIControlEventTouchUpInside];
        [_tabBar addSubview:tab];
        [_tabButtons addObject:tab];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh:)
                                                 name:RewindPlayerDidChangeNotification object:_player];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh:)
                                                 name:RewindAccountLibraryDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(languageChanged:)
                                                 name:REWIND_LANGUAGE_DID_CHANGE_NOTIFICATION object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged:)
                                                 name:RewindThemeDidChangeNotification object:nil];
    [self refresh:nil];
}

- (void)themeChanged:(NSNotification *)note {
    (void)note;
    [_titleLabel setFont:RewindFont(24.0f, RewindWeightBold)];
    [_titleLabel setTextColor:RewindColorText()];
    _artistLabel.font = RewindFont(17.0f, RewindWeightRegular);
    _artistLabel.textColor = RewindColorTextSecondary();
    _likePill.backgroundColor = RewindColorOverlay();
    [_likePill viewWithTag:77].backgroundColor = RewindColorDivider();
    UIColor *top = nil, *bottom = nil;
    RewindPlayerTint(_artwork.image, &top, &bottom);
    _background.colors = [NSArray arrayWithObjects:(id)top.CGColor, (id)bottom.CGColor, nil];
    _panelBackground.colors = _background.colors;
    for (UIButton *tab in _tabButtons) {
        tab.titleLabel.font = RewindFont(14.0f, RewindWeightMedium);
        [tab setTitleColor:RewindColorTextSecondary() forState:UIControlStateNormal];
    }
    [self refresh:nil];
    [self.view setNeedsLayout];
    [self rebuildPanel];
}

- (void)languageChanged:(NSNotification *)note {
    (void)note;
    NSArray *labels = [NSArray arrayWithObjects:RewindL(@"player_next"), RewindL(@"player_lyrics"),
                       RewindL(@"player_related"), nil];
    for (NSUInteger index = 0; index < _tabButtons.count && index < labels.count; ++index)
        [(UIButton *)[_tabButtons objectAtIndex:index] setTitle:[[labels objectAtIndex:index] uppercaseString]
                                                        forState:UIControlStateNormal];
    [self refresh:nil];
    if (_panel && _selectedTab >= 0) [self rebuildPanel];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    if (!_progressTimer)
        _progressTimer = [[NSTimer scheduledTimerWithTimeInterval:0.4 target:self
                                                          selector:@selector(progressTick:) userInfo:nil repeats:YES] retain];
}

- (void)viewWillDisappear:(BOOL)animated {
    [_progressTimer invalidate];
    [_progressTimer release];
    _progressTimer = nil;
    [super viewWillDisappear:animated];
}

- (void)layoutActionsInWidth:(CGFloat)width atY:(CGFloat)y inset:(CGFloat)inset height:(CGFloat)h {
    CGFloat gap = RW(8.0f), icon = RW(50.0f);
    CGFloat padding = RW(4.0f);
    _actions.frame = CGRectMake(0, y - padding, width, h + padding * 2.0f);
    CGFloat x = inset + padding;
    _likePill.frame = CGRectMake(x, padding, icon * 2.0f + 1.0f, h);
    _likePill.layer.cornerRadius = h * 0.5f;
    _likeButton.frame = CGRectMake(0, 0, icon, h);
    [_likePill viewWithTag:77].frame = CGRectMake(icon, floorf(h * 0.25f), 1.0f, ceilf(h * 0.5f));
    _dislikeButton.frame = CGRectMake(icon + 1.0f, 0, icon, h);
    x = CGRectGetMaxX(_likePill.frame) + gap;
    for (RewindPillButton *pill in _actionPills) {
        CGFloat w = [pill preferredWidthForHeight:h];
        pill.frame = CGRectMake(x, padding, w, h);
        x += w + gap;
    }
    _actions.contentSize = CGSizeMake(x - gap + inset + padding, h + padding * 2.0f);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    _background.frame = b;
    CGFloat width = b.size.width, height = b.size.height;
    CGFloat top = RewindStatusBarInset();
    BOOL landscape = width > height;
    /* short screens need tighter vertical spacing */
    BOOL compact = height - top < 520.0f;
    CGFloat side = RW(24.0f), header = compact ? RW(46.0f) : RW(56.0f);
    CGFloat tabsRowH = compact ? RW(40.0f) : RW(48.0f);
    /* keep tab titles above the home indicator */
    CGFloat tabsH = tabsRowH + RewindBottomSafeInset();
    CGFloat play = compact ? RW(64.0f) : RW(72.0f);
    CGFloat big = RW(52.0f), small = RW(48.0f), controlGap = RW(8.0f);
    CGFloat controlsWidth = rewind_player_controls_width(small, big, play, controlGap);
    CGFloat gapArt = compact ? RW(12.0f) : RW(22.0f);
    CGFloat gapMeta = compact ? RW(10.0f) : RW(18.0f);
    CGFloat pillsH = compact ? RW(36.0f) : RW(40.0f);
    CGFloat gapPills = compact ? RW(14.0f) : RW(24.0f);
    CGFloat seekH = RW(24.0f), timesH = RW(16.0f);
    CGFloat gapControls = compact ? RW(6.0f) : RW(14.0f);
    _closeButton.frame = CGRectMake(RW(6.0f), top, RW(48.0f), header);
    _moreButton.frame = CGRectMake(width - RW(54.0f), top, RW(48.0f), header);
    CGFloat titleH = ceilf(_titleLabel.font.lineHeight), artistH = ceilf(_artistLabel.font.lineHeight);
    CGFloat below = gapArt + titleH + RW(2.0f) + artistH + gapMeta + pillsH + gapPills +
                    seekH + timesH + gapControls + play + RW(6.0f) + tabsH;
    CGFloat metaX = side, metaW = width - side * 2.0f;
    CGFloat y;
    if (landscape) {
        /* center both columns between the header and tabs on tall ipads */
        CGFloat areaTop = top + header, areaH = height - tabsH - areaTop;
        CGFloat art = MAX(1.0f, MIN(MIN(areaH - RW(16.0f), width * 0.42f),
                                  width - side * 2.0f - RW(24.0f) - controlsWidth));
        _artwork.frame = CGRectMake(side, areaTop + floorf(MAX(0.0f, areaH - art) * 0.5f), art, art);
        metaX = CGRectGetMaxX(_artwork.frame) + RW(24.0f);
        metaW = MAX(RW(120.0f), width - metaX - side);
        CGFloat block = below - gapArt - RW(6.0f) - tabsH;
        y = areaTop + floorf(MAX(0.0f, areaH - block) * 0.5f);
    } else {
        CGFloat art = floorf(MIN(width - side * 2.0f, height - top - header - below));
        art = MAX(RW(120.0f), art);
        if (_panel) art = MIN(art, MAX(RW(96.0f), MIN(RW(200.0f), height * 0.28f)));
        _artwork.frame = CGRectMake(floorf((width - art) * 0.5f), top + header, art, art);
        y = CGRectGetMaxY(_artwork.frame) + gapArt;
    }
    _titleLabel.frame = CGRectMake(metaX, y, metaW, titleH);
    y += titleH + RW(2.0f);
    _artistLabel.frame = CGRectMake(metaX, y, metaW, artistH);
    _artistTap.frame = _artistLabel.frame;
    y += artistH + gapMeta;
    if (landscape) {
        [self layoutActionsInWidth:metaW atY:y inset:0.0f height:pillsH];
        _actions.frame = CGRectMake(metaX, y - RW(4.0f), metaW, pillsH + RW(8.0f));
    } else {
        [self layoutActionsInWidth:width atY:y inset:metaX height:pillsH];
    }
    y += pillsH + gapPills;
    _progress.frame = CGRectMake(metaX, y, metaW, seekH);
    y += seekH;
    _elapsedLabel.frame = CGRectMake(metaX, y - RW(2.0f), RW(80.0f), timesH);
    _durationLabel.frame = CGRectMake(metaX + metaW - RW(80.0f), y - RW(2.0f), RW(80.0f), timesH);
    y += timesH + gapControls;
    /* equal gaps between button edges keep the wider play circle clear on landscape phones */
    CGFloat centerY = y + floorf(play * 0.5f);
    double controlX[5];
    if (!rewind_player_controls(metaW, small, big, play, controlGap, controlX)) {
        /* leave room for rounding so rotation does not keep the previous button frames */
        CGFloat scale = (metaW - RW(2.0f)) / controlsWidth;
        small *= scale; big *= scale; play *= scale; controlGap *= scale;
        if (!rewind_player_controls(metaW, small, big, play, controlGap, controlX)) {
            NSLog(@"rewind: player controls cannot fit width %.1f", metaW);
            return;
        }
    }
    _shuffleButton.frame = CGRectMake(metaX + controlX[0], centerY - small * 0.5f, small, small);
    _previousButton.frame = CGRectMake(metaX + controlX[1], centerY - big * 0.5f, big, big);
    _playButton.frame = CGRectMake(metaX + controlX[2], centerY - play * 0.5f, play, play);
    _playButton.layer.cornerRadius = play * 0.5f;
    _playSpinner.center = _playButton.center;
    _nextButton.frame = CGRectMake(metaX + controlX[3], centerY - big * 0.5f, big, big);
    _repeatButton.frame = CGRectMake(metaX + controlX[4], centerY - small * 0.5f, small, small);
    NSArray *controls = [NSArray arrayWithObjects:_shuffleButton, _previousButton,
                         _nextButton, _repeatButton, nil];
    for (RewindIconButton *button in controls) {
        button.layer.cornerRadius = button.bounds.size.width * 0.5f;
    }
    _playButton.backgroundColor = RewindColorText();
    [_playButton setIconColor:[UIColor blackColor]];
    CGFloat tabsX = landscape ? metaX : 0.0f, tabsW = landscape ? metaW : width;
    _tabBar.frame = CGRectMake(tabsX, height - tabsH, tabsW, tabsH);
    for (NSUInteger index = 0; index < _tabButtons.count; ++index)
        ((UIView *)[_tabButtons objectAtIndex:index]).frame = CGRectMake(index * tabsW / 3.0f, 0, tabsW / 3.0f, tabsRowH);
    if (_panel) {
        /* in portrait the panel takes the whole screen, the artwork row inside it replaces the player's own */
        CGRect panelFrame = landscape
            ? CGRectMake(metaX, top + header, metaW, height - top - header)
            : CGRectMake(0, 0, width, height);
        _panel.bounds = CGRectMake(0, 0, panelFrame.size.width, panelFrame.size.height);
        _panel.center = CGPointMake(CGRectGetMidX(panelFrame), CGRectGetMidY(panelFrame));
    }
    [self layoutPanel];
}

- (void)refresh:(NSNotification *)note {
    NSError *error = [[note userInfo] objectForKey:@"error"];
    if (error) RewindShowToast(self.view, RewindFriendlyError(error), RW(28.0f));
    RewindTrack *track = _player.track;
    if (track != _displayTrack) {
        [_displayTrack release];
        _displayTrack = [track retain];
        ++_request;
        _lyricsAttempted = NO;
        _relatedAttempted = NO;
        _lyricsLoading = _relatedLoading = NO;
        [_lyricsError release]; _lyricsError = nil;
        [_relatedError release]; _relatedError = nil;
        [_lyrics release]; _lyrics = nil;
        [_translatedLines release]; _translatedLines = nil;
        _showingTranslation = _translating = NO;
        [_related release]; _related = nil;
        _lastLyricIndex = -1;
        /* delay the main-thread lyrics lookup until the track settles, unless its tab opens sooner */
        if (track) {
            NSUInteger lyricsRequest = _request;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (lyricsRequest == _request && !_lyricsAttempted) [self loadLyrics];
            });
        }
        [self updateLyricsTabs];
        [_panelArt setURL:track.thumbnailURL];
        [_panelArtist setText:RewindTrackArtistText(track)];
        [_artwork setURL:track.thumbnailURL];
        NSUInteger request = _request;
        if (track.thumbnailURL.length)
            RewindLoadImageSized(track.thumbnailURL, 64.0f, ^(UIImage *image) {
                if (request != _request || !image) return;
                UIColor *top = nil, *bottom = nil;
                RewindPlayerTint(image, &top, &bottom);
                /* the gradient eases between covers instead of snapping */
                CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"colors"];
                fade.fromValue = _background.colors;
                fade.duration = 0.45;
                _background.colors = [NSArray arrayWithObjects:(id)top.CGColor, (id)bottom.CGColor, nil];
                [_background addAnimation:fade forKey:@"colors"];
                if (_panelBackground) {
                    _panelBackground.colors = _background.colors;
                    [_panelBackground addAnimation:fade forKey:@"colors"];
                }
            });
        if (_panel && _selectedTab >= 0) [self showTab:_selectedTab];
    }
    _titleLabel.text = track.title ?: RewindL(@"nothing_playing");
    _artistLabel.text = track ? RewindTrackArtistText(track) : @"";
    _playButton.hidden = _player.loading;
    if (_player.loading) [_playSpinner startAnimating];
    else [_playSpinner stopAnimating];
    [_playButton setIconName:_player.playing ? @"pause" : @"play"];
    UIColor *dim = [UIColor colorWithWhite:1.0f alpha:0.6f];
    [_shuffleButton setIconColor:_player.shuffling ? RewindColorText() : dim];
    [_repeatButton setIconName:_player.repeating ? @"repeat-one" : @"repeat"];
    [_repeatButton setIconColor:_player.repeating ? RewindColorText() : dim];
    BOOL liked = track && (RewindAccountIsSignedIn() ? RewindAccountTrackIsLiked(track) : RewindTrackIsSaved(track));
    [_likeButton setIconName:liked ? @"thumb-up-on" : @"thumb-up"];
    [_dislikeButton setIconName:track && RewindAccountTrackIsDisliked(track) ? @"thumb-down-on" : @"thumb-down"];
    _panelPlay.hidden = _player.loading;
    if (_player.loading) [_panelPlaySpinner startAnimating];
    else [_panelPlaySpinner stopAnimating];
    [_panelPlay setIconName:_player.playing ? @"pause" : @"play"];
    _panelTitle.text = track.title;
    if (_panel && _selectedTab == 0 && track == _displayTrack) [self rebuildPanel];
    [self progressTick:nil];
}

- (void)progressTick:(NSTimer *)timer {
    (void)timer;
    NSTimeInterval duration = _player.duration;
    NSTimeInterval current = _player.currentTime;
    if (_progress.dragging) return;
    _progress.value = duration > 0 ? (float)MIN(1.0, current / duration) : 0;
    _elapsedLabel.text = PlayerTime((NSUInteger)MAX(0, current));
    _durationLabel.text = PlayerTime((NSUInteger)MAX(0, duration));
    if (_panel && _selectedTab == 1) [self highlightLyric];
}

- (void)progressDragged:(RewindSeekBar *)bar {
    _elapsedLabel.text = PlayerTime((NSUInteger)MAX(0.0, bar.value * _player.duration));
}

- (void)progressChanged:(RewindSeekBar *)bar { [_player seekToProgress:bar.value]; }
- (void)mixPressed {
    [_menuTrack release];
    _menuTrack = [_player.track retain];
    [self performMenuAction:RewindPlayerMenuActionMix];
}
- (void)downloadPressed {
    [_menuTrack release];
    _menuTrack = [_player.track retain];
    [self performMenuAction:RewindPlayerMenuActionDownload];
}
- (void)closePressed { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)playPressed { [_player toggle]; }
- (void)nextPressed { [_player nextTrack]; }
- (void)previousPressed { [_player previousTrack]; }
- (void)shufflePressed { [_player setShuffling:!_player.shuffling]; [self refresh:nil]; }
- (void)repeatPressed { [_player setRepeating:!_player.repeating]; [self refresh:nil]; }
- (void)artistPressed {
    if (_player.track) RewindPushArtistProfile(self, _player.track, _api, _player);
}

- (void)likePressed {
    RewindTrack *track = _player.track;
    if (!track) return;
    if (RewindAccountIsSignedIn()) {
        BOOL liked = !RewindAccountTrackIsLiked(track);
        RewindAccountSetLiked(track, liked, ^(NSError *error) {
            if (error) RewindShowToast(self.view, RewindFriendlyError(error), RW(28.0f));
            [self refresh:nil];
        });
    } else {
        if (RewindTrackIsSaved(track)) RewindRemoveTrack(track);
        else RewindSaveTrack(track);
        [self refresh:nil];
    }
}

- (void)dislikePressed {
    RewindTrack *track = _player.track;
    if (!track) return;
    if (!RewindAccountIsSignedIn()) {
        RewindShowToast(self.view, RewindL(@"dislike_sign_in"), RW(28.0f));
        return;
    }
    BOOL disliked = !RewindAccountTrackIsDisliked(track);
    RewindAccountSetDisliked(track, disliked, ^(NSError *error) {
        if (error) RewindShowToast(self.view, RewindFriendlyError(error), RW(28.0f));
        else if (disliked) RewindShowToast(self.view, RewindL(@"dislike_done"), RW(28.0f));
        [self refresh:nil];
    });
}

- (void)saveTrack:(RewindTrack *)track {
    if (!track) return;
    BOOL saved = RewindTrackIsSaved(track);
    if (saved) RewindRemoveTrack(track);
    else RewindSaveTrack(track);
    RewindShowToast(self.view, RewindL(saved ? @"removed_library" : @"added_library"), RW(28.0f));
    [self refresh:nil];
}

/* "save" in youtube music adds the track to a playlist; the library toggle lives in the menu */
- (void)savePressed {
    if (!_player.track) return;
    [_menuTrack release];
    _menuTrack = [_player.track retain];
    [self showPlaylistPicker];
}

- (void)shareTrack:(RewindTrack *)track {
    if (!track.videoID.length) return;
    NSString *url = [@"https://youtu.be/" stringByAppendingString:track.videoID];
    Class activity = NSClassFromString(@"UIActivityViewController");
    if (activity) {
        id controller = [[[activity alloc] initWithActivityItems:[NSArray arrayWithObject:url]
                                             applicationActivities:nil] autorelease];
        [self presentViewController:controller animated:YES completion:nil];
    } else {
        [UIPasteboard generalPasteboard].string = url;
        RewindShowToast(self.view, RewindL(@"menu_share_copied"), RW(28.0f));
    }
}

- (void)sharePressed { [self shareTrack:_player.track]; }

- (void)tabPressed:(UIButton *)button {
    if (button.tag == 1 && _lyricsError && !_lyricsLoading) _lyricsAttempted = NO;
    if (button.tag == 2 && _relatedError && !_relatedLoading) _relatedAttempted = NO;
    [self showTab:button.tag];
}

- (void)showTab:(NSInteger)tab {
    if (tab < 0 || tab > 2) return;
    BOOL first = _panel == nil;
    _selectedTab = tab;
    if (first) {
        _panel = [[UIView alloc] initWithFrame:self.view.bounds];
        _panel.clipsToBounds = YES;
        _panel.backgroundColor = [UIColor clearColor];
        [self.view addSubview:_panel];
        _panelBackground = [[CAGradientLayer layer] retain];
        _panelBackground.colors = _background.colors;
        [_panel.layer insertSublayer:_panelBackground atIndex:0];
        UIView *plate = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
        plate.tag = 398;
        plate.userInteractionEnabled = NO;
        plate.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.07f];
        plate.layer.cornerRadius = RW(22.0f);
        [_panel addSubview:plate];
        RewindPressControl *headerTap = [[[RewindPressControl alloc] initWithFrame:CGRectZero] autorelease];
        headerTap.tag = 399;
        headerTap.pressScales = NO;
        [headerTap addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:headerTap];
        _panelArt = [[RewindArtworkView alloc] initWithFrame:CGRectZero];
        [_panelArt setCornerRadius:RW(4.0f)];
        [_panelArt setURL:_player.track.thumbnailURL];
        [_panel addSubview:_panelArt];
        _panelTitle = [[UILabel alloc] initWithFrame:CGRectZero];
        _panelTitle.backgroundColor = [UIColor clearColor];
        _panelTitle.textColor = RewindColorText();
        _panelTitle.font = RewindFont(18.0f, RewindWeightBold);
        _panelTitle.text = _player.track.title;
        [_panel addSubview:_panelTitle];
        _panelArtist = [[UILabel alloc] initWithFrame:CGRectZero];
        _panelArtist.backgroundColor = [UIColor clearColor];
        _panelArtist.textColor = RewindColorTextSecondary();
        _panelArtist.font = RewindFont(15.0f, RewindWeightRegular);
        _panelArtist.text = RewindTrackArtistText(_player.track);
        [_panel addSubview:_panelArtist];
        _panelPlay = [[RewindIconButton buttonWithIcon:_player.playing ? @"pause" : @"play" points:RW(24.0f)] retain];
        [_panelPlay addTarget:self action:@selector(playPressed) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:_panelPlay];
        /* the panel covers the player's own close key, and on the ipad nothing else hides it */
        RewindIconButton *hide = [RewindIconButton buttonWithIcon:@"chevron-down" points:RW(26.0f)];
        hide.tag = 396;
        [hide addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:hide];
        _panelPlaySpinner = [[UIActivityIndicatorView alloc]
                             initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        _panelPlaySpinner.hidesWhenStopped = YES;
        _panelPlaySpinner.userInteractionEnabled = NO;
        _panelPlay.hidden = _player.loading;
        if (_player.loading) [_panelPlaySpinner startAnimating];
        [_panel addSubview:_panelPlaySpinner];
        for (NSUInteger index = 0; index < 3; ++index) {
            UIButton *tabButton = [UIButton buttonWithType:UIButtonTypeCustom];
            tabButton.tag = 410 + (NSInteger)index;
            tabButton.titleLabel.font = RewindFont(15.0f, RewindWeightMedium);
            NSString *key = index == 0 ? @"player_next" : index == 1 ? @"player_lyrics" : @"player_related";
            [tabButton setTitle:[RewindL(key) uppercaseString] forState:UIControlStateNormal];
            [tabButton addTarget:self action:@selector(panelTabPressed:) forControlEvents:UIControlEventTouchUpInside];
            [_panel addSubview:tabButton];
        }
        _panelUnderline = [[UIView alloc] initWithFrame:CGRectZero];
        _panelUnderline.backgroundColor = RewindColorText();
        _panelUnderline.layer.cornerRadius = RW(1.5f);
        [_panel addSubview:_panelUnderline];
        UIView *divider = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
        divider.tag = 397;
        divider.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.14f];
        [_panel addSubview:divider];
        _panelScroll = [[RewindScrollView alloc] initWithFrame:CGRectZero];
        _panelScroll.showsVerticalScrollIndicator = NO;
        [_panel addSubview:_panelScroll];
        /* lyric actions float over the bottom of the text on a soft fade */
        _panelFade = [[UIView alloc] initWithFrame:CGRectZero];
        _panelFade.userInteractionEnabled = NO;
        CAGradientLayer *fade = [CAGradientLayer layer];
        fade.colors = [NSArray arrayWithObjects:(id)[UIColor colorWithWhite:0.0f alpha:0.0f].CGColor,
                       (id)[UIColor colorWithWhite:0.0f alpha:0.55f].CGColor, nil];
        [_panelFade.layer addSublayer:fade];
        [_panel addSubview:_panelFade];
        _panelShare = [[RewindPillButton alloc] initWithStyle:RewindPillStyleFilled icon:@"share" title:RewindL(@"menu_share")];
        [_panelShare addTarget:self action:@selector(shareLyricsPressed) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:_panelShare];
        _panelTranslate = [[RewindPillButton alloc] initWithStyle:RewindPillStyleFilled icon:@"translate" title:RewindL(@"player_translate")];
        [_panelTranslate addTarget:self action:@selector(translatePressed) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:_panelTranslate];
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        _panel.transform = CGAffineTransformMakeTranslation(0, self.view.bounds.size.height);
        RewindSpring(0.43, ^{ _panel.transform = CGAffineTransformIdentity; }, nil);
    }
    for (NSUInteger index = 0; index < 3; ++index) {
        UIButton *button = (UIButton *)[_panel viewWithTag:410 + (NSInteger)index];
        [button setTitleColor:index == (NSUInteger)tab ? RewindColorText() : RewindColorTextSecondary()
                    forState:UIControlStateNormal];
    }
    [self updateLyricsTabs];
    [self rebuildPanel];
    [self layoutPanelUnderline:!first];
    RewindTrack *track = _player.track;
    NSUInteger request = _request;
    if (tab == 1 && track && !_lyricsAttempted) {
        [self loadLyrics];
        [self rebuildPanel];
    } else if (tab == 2 && track && !_relatedAttempted) {
        _relatedAttempted = YES;
        _relatedLoading = YES;
        [_relatedError release]; _relatedError = nil;
        [self rebuildPanel];
        [_api relatedForTrack:track completion:^(NSArray *shelves, NSArray *chips, NSError *error) {
            (void)chips;
            if (request != _request) return;
            _relatedLoading = NO;
            [_relatedError release]; _relatedError = [error retain];
            if (error) NSLog(@"rewind: related music: %@", error);
            NSMutableArray *items = [NSMutableArray array];
            NSMutableSet *seen = [NSMutableSet setWithObject:track.videoID];
            for (RewindShelf *shelf in shelves) {
                for (id item in shelf.items) {
                    if (![item isKindOfClass:[RewindTrack class]]) continue;
                    RewindTrack *candidate = item;
                    if (candidate.videoID.length && !candidate.isPlaylist &&
                        ![seen containsObject:candidate.videoID]) {
                        [items addObject:candidate];
                        [seen addObject:candidate.videoID];
                    }
                    if (items.count >= 40) break;
                }
                if (items.count >= 40) break;
            }
            [_related release]; _related = [items copy];
            if (_panel && _selectedTab == 2) [self rebuildPanel];
        }];
    }
}

- (void)loadLyrics {
    RewindTrack *track = _player.track;
    if (!track) return;
    NSUInteger request = _request;
    _lyricsAttempted = YES;
    _lyricsLoading = YES;
    [_lyricsError release]; _lyricsError = nil;
    [_api lyricsForTrack:track completion:^(RewindLyrics *lyrics, NSError *error) {
        if (request != _request) return;
        _lyricsLoading = NO;
        [_lyricsError release]; _lyricsError = [error retain];
        if (error) NSLog(@"rewind: lyrics: %@", error);
        [_lyrics release]; _lyrics = [lyrics retain];
        [self updateLyricsTabs];
        if (_panel && _selectedTab == 1) [self rebuildPanel];
    }];
}

/* a track without lyrics leaves the tab dimmed and dead, a failed lookup keeps it so a tap can retry */
- (void)updateLyricsTabs {
    BOOL missing = _lyricsAttempted && !_lyricsLoading &&
        (_lyrics ? !_lyrics.lines.count : RewindLyricsMissing(_lyricsError));
    NSMutableArray *buttons = [NSMutableArray array];
    if (_tabButtons.count > 1) [buttons addObject:[_tabButtons objectAtIndex:1]];
    UIButton *panelButton = (UIButton *)[_panel viewWithTag:411];
    if (panelButton) [buttons addObject:panelButton];
    for (UIButton *button in buttons) {
        button.enabled = !missing;
        button.alpha = missing ? 0.4f : 1.0f;
    }
}

- (void)panelTabPressed:(UIButton *)button {
    NSInteger tab = button.tag - 410;
    if (tab == 1 && _lyricsError && !_lyricsLoading) _lyricsAttempted = NO;
    if (tab == 2 && _relatedError && !_relatedLoading) _relatedAttempted = NO;
    [self showTab:tab];
}

/* the artwork row sits under the status bar on ios 7 and later, where the app draws behind it */
- (CGFloat)panelHeaderHeight {
    return RW(88.0f) + (_panel.bounds.size.width == self.view.bounds.size.width ? RewindStatusBarInset() : 0.0f);
}

- (void)layoutPanelUnderline:(BOOL)animated {
    if (!_panel || _selectedTab < 0) return;
    CGFloat tabW = _panel.bounds.size.width / 3.0f, top = [self panelHeaderHeight], tabs = RW(52.0f);
    CGRect frame = CGRectMake(_selectedTab * tabW + RW(8.0f), top + tabs - RW(3.0f), tabW - RW(16.0f), RW(3.0f));
    if (animated) RewindAnimate(0.22, ^{ _panelUnderline.frame = frame; }, nil);
    else _panelUnderline.frame = frame;
}

- (void)layoutPanel {
    if (!_panel) return;
    CGRect b = _panel.bounds;
    CGFloat previousWidth = _panelScroll.bounds.size.width;
    _panelBackground.frame = b;
    CGFloat top = [self panelHeaderHeight], tabs = RW(52.0f), inset = top - RW(88.0f);
    [_panel viewWithTag:398].frame = CGRectMake(0, top, b.size.width, b.size.height - top + RW(40.0f));
    [_panel viewWithTag:399].frame = CGRectMake(0, 0, b.size.width - RW(116.0f), top);
    [_panel viewWithTag:396].frame = CGRectMake(b.size.width - RW(58.0f), inset + RW(20.0f), RW(48.0f), RW(48.0f));
    _panelArt.frame = CGRectMake(RW(16.0f), inset + RW(14.0f), RW(60.0f), RW(60.0f));
    _panelTitle.frame = CGRectMake(RW(92.0f), inset + RW(20.0f), b.size.width - RW(92.0f) - RW(116.0f), RW(26.0f));
    _panelArtist.frame = CGRectMake(RW(92.0f), inset + RW(46.0f), b.size.width - RW(92.0f) - RW(116.0f), RW(22.0f));
    _panelPlay.frame = CGRectMake(b.size.width - RW(110.0f), inset + RW(20.0f), RW(48.0f), RW(48.0f));
    _panelPlaySpinner.center = _panelPlay.center;
    for (NSUInteger index = 0; index < 3; ++index)
        [_panel viewWithTag:410 + (NSInteger)index].frame = CGRectMake(index * b.size.width / 3.0f,
                          top, b.size.width / 3.0f, tabs);
    [_panel viewWithTag:397].frame = CGRectMake(RW(16.0f), top + tabs - 0.5f, b.size.width - RW(32.0f), 0.5f);
    [self layoutPanelUnderline:NO];
    _panelScroll.frame = CGRectMake(0, top + tabs, b.size.width, MAX(0, b.size.height - top - tabs));
    CGFloat pillH = RW(44.0f), gap = RW(12.0f);
    CGFloat shareW = [_panelShare preferredWidthForHeight:pillH], translateW = [_panelTranslate preferredWidthForHeight:pillH];
    CGFloat x = floorf((b.size.width - shareW - gap - translateW) * 0.5f), y = b.size.height - pillH - RW(18.0f);
    _panelShare.frame = CGRectMake(x, y, shareW, pillH);
    _panelTranslate.frame = CGRectMake(x + shareW + gap, y, translateW, pillH);
    _panelFade.frame = CGRectMake(0, b.size.height - RW(110.0f), b.size.width, RW(110.0f));
    ((CALayer *)[_panelFade.layer.sublayers objectAtIndex:0]).frame = _panelFade.bounds;
    [self updatePanelPills];
    if (fabs(previousWidth - b.size.width) > 0.5f) [self rebuildPanel];
}

/* the lyric actions only make sense over lyrics that loaded */
- (void)updatePanelPills {
    BOOL show = _selectedTab == 1 && _lyrics.lines.count > 0;
    _panelShare.hidden = _panelTranslate.hidden = _panelFade.hidden = !show;
    [_panelTranslate setTitle:_showingTranslation ? RewindL(@"player_original") : RewindL(@"player_translate")];
    [_panelTranslate setNeedsLayout];
}

- (void)shareLyricsPressed {
    RewindTrack *track = _player.track;
    if (!_lyrics.lines.count || !track) { [self shareTrack:track]; return; }
    NSMutableString *text = [NSMutableString stringWithFormat:@"%@ \u2013 %@\n\n", track.title, RewindTrackArtistText(track)];
    for (RewindLyricLine *line in _lyrics.lines) [text appendFormat:@"%@\n", line.text];
    Class activity = NSClassFromString(@"UIActivityViewController");
    if (activity) {
        id controller = [[[activity alloc] initWithActivityItems:[NSArray arrayWithObject:text] applicationActivities:nil] autorelease];
        [self presentViewController:controller animated:YES completion:nil];
    } else {
        [UIPasteboard generalPasteboard].string = text;
        RewindShowToast(self.view, RewindL(@"menu_share_copied"), RW(28.0f));
    }
}

- (void)translatePressed {
    if (_translating || !_lyrics.lines.count) return;
    if (_showingTranslation) {
        _showingTranslation = NO;
        [self rebuildPanel];
        [self updatePanelPills];
        return;
    }
    if (_translatedLines.count == _lyrics.lines.count) {
        _showingTranslation = YES;
        [self rebuildPanel];
        [self updatePanelPills];
        return;
    }
    _translating = YES;
    NSMutableArray *source = [NSMutableArray array];
    for (RewindLyricLine *line in _lyrics.lines) [source addObject:line.text ?: @""];
    NSUInteger request = _request;
    [_api translateLines:source toLanguage:RewindLanguageCode() completion:^(NSArray *lines, NSError *error) {
        _translating = NO;
        if (request != _request) return;
        if (!lines) {
            NSLog(@"rewind: translate: %@", error);
            RewindShowToast(self.view, RewindL(@"translate_failed"), RW(28.0f));
            return;
        }
        [_translatedLines release];
        _translatedLines = [lines retain];
        _showingTranslation = YES;
        [self rebuildPanel];
        [self updatePanelPills];
    }];
}

- (void)hidePanel {
    if (!_panel) return;
    UIView *panel = [_panel retain];
    [_panel release];
    _panel = nil;
    _selectedTab = -1;
    [self.view setNeedsLayout];
    RewindAnimate(0.22, ^{ panel.transform = CGAffineTransformMakeTranslation(0, panel.bounds.size.height); },
                  ^(BOOL finished) { (void)finished; [panel removeFromSuperview]; [panel release]; });
    [_panelBackground release]; _panelBackground = nil;
    [_panelTitle release]; _panelTitle = nil;
    [_panelPlay release]; _panelPlay = nil;
    [_panelPlaySpinner release]; _panelPlaySpinner = nil;
    [_panelScroll release]; _panelScroll = nil;
    [_panelArt release]; _panelArt = nil;
    [_panelArtist release]; _panelArtist = nil;
    [_panelUnderline release]; _panelUnderline = nil;
    [_panelFade release]; _panelFade = nil;
    [_panelShare release]; _panelShare = nil;
    [_panelTranslate release]; _panelTranslate = nil;
}

- (void)rebuildPanel {
    if (!_panelScroll) return;
    NSArray *views = [_panelScroll.subviews copy];
    for (UIView *view in views) [view removeFromSuperview];
    [views release];
    CGFloat width = _panelScroll.bounds.size.width;
    CGFloat y = RW(18.0f);
    if (_selectedTab == 0) {
        NSInteger current = _player.queueIndex;
        NSArray *queue = _player.queue;
        NSUInteger count = MIN((NSUInteger)100, queue.count);
        for (NSUInteger index = 0; index < count; ++index) {
            RewindTrack *track = [queue objectAtIndex:index];
            RewindTrackRow *row = [[[RewindTrackRow alloc] initWithFrame:
                                    CGRectMake(0, y, width, [RewindTrackRow rowHeight])] autorelease];
            [row setTrack:track];
            [row setPlaying:(NSInteger)index == current animating:_player.playing];
            [row setOnMore:nil];
            __block RewindPlayerVC *owner = self;
            [row setOnTap:^{ [owner->_player playQueueIndex:(NSInteger)index]; }];
            [_panelScroll addSubview:row];
            y += [RewindTrackRow rowHeight];
        }
        if (!count) [self addPanelStatus:RewindL(@"queue_empty") atY:y];
    } else if (_selectedTab == 1) {
        if (!_lyrics) [self addPanelStatus:_lyricsLoading ? RewindL(@"loading_tracks") :
                       (_lyricsError ? RewindFriendlyError(_lyricsError) : RewindL(@"lyrics_none")) atY:y];
        else {
            NSUInteger count = MIN((NSUInteger)500, _lyrics.lines.count);
            for (NSUInteger index = 0; index < count; ++index) {
                RewindLyricLine *line = [_lyrics.lines objectAtIndex:index];
                CGFloat inset = RW(24.0f);
                UIFont *font = RewindFont(26.0f, RewindWeightBold);
                NSString *shown = _showingTranslation && index < _translatedLines.count
                    ? [_translatedLines objectAtIndex:index] : line.text;
                CGFloat textH = RewindTextSize(shown, font, width - inset * 2.0f).height;
                UILabel *label = [[[UILabel alloc] initWithFrame:
                                    CGRectMake(inset, y, width - inset * 2.0f, MAX(RW(32.0f), textH + RW(4.0f)))] autorelease];
                label.tag = 5000 + (NSInteger)index;
                label.backgroundColor = [UIColor clearColor];
                label.font = font;
                label.textColor = _lyrics.timed ? RewindLyricDimColor() : RewindColorText();
                label.numberOfLines = 0;
                label.text = shown;
                if (_lyrics.timed) {
                    label.userInteractionEnabled = YES;
                    [label addGestureRecognizer:[[[UITapGestureRecognizer alloc]
                        initWithTarget:self action:@selector(lyricTapped:)] autorelease]];
                }
                [_panelScroll addSubview:label];
                y += label.bounds.size.height + RW(20.0f);
            }
            _lastLyricIndex = -1;
            [self highlightLyric];
        }
    } else {
        if (!_related || !_related.count) [self addPanelStatus:_relatedLoading ? RewindL(@"loading_tracks") :
                       (_relatedError ? RewindFriendlyError(_relatedError) : RewindL(@"related_none")) atY:y];
        for (RewindTrack *track in _related) {
            RewindTrackRow *row = [[[RewindTrackRow alloc] initWithFrame:
                                    CGRectMake(0, y, width, [RewindTrackRow rowHeight])] autorelease];
            [row setTrack:track];
            __block RewindPlayerVC *owner = self;
            [row setOnTap:^{ [owner->_player playTrack:track usingAPI:owner->_api]; }];
            [row setOnMore:^{ [owner showTrackMenu:track]; }];
            [_panelScroll addSubview:row];
            y += [RewindTrackRow rowHeight];
        }
    }
    for (UIView *view in _panelScroll.subviews) y = MAX(y, CGRectGetMaxY(view.frame));
    /* the last lyric line must be able to scroll clear of the floating actions */
    _panelScroll.contentSize = CGSizeMake(width, y + (_selectedTab == 1 ? RW(120.0f) : RW(28.0f)));
    [self updatePanelPills];
}

- (void)addPanelStatus:(NSString *)text atY:(CGFloat)y {
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectMake(RW(24.0f), y,
                                _panelScroll.bounds.size.width - RW(48.0f), RW(60.0f))] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.textColor = RewindColorTextSecondary();
    label.font = RewindFont(16.0f, RewindWeightRegular);
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.text = text;
    [_panelScroll addSubview:label];
}

- (void)lyricTapped:(UITapGestureRecognizer *)tap {
    NSInteger index = tap.view.tag - 5000;
    NSTimeInterval duration = _player.duration;
    if (!_lyrics.timed || index < 0 || (NSUInteger)index >= _lyrics.lines.count || duration <= 0.0) return;
    RewindLyricLine *line = [_lyrics.lines objectAtIndex:(NSUInteger)index];
    /* seek 50 ms past the stamp so 1/600 s rounding keeps the tapped line active */
    [_player seekToTime:line.startMS / 1000.0 + 0.05];
    [self highlightLyric];
}

- (void)highlightLyric {
    if (!_lyrics.timed || !_lyrics.lines.count) return;
    NSUInteger milliseconds = (NSUInteger)MAX(0.0, _player.currentTime * 1000.0);
    NSInteger active = -1;
    for (NSUInteger index = 0; index < _lyrics.lines.count && index < 500; ++index) {
        RewindLyricLine *line = [_lyrics.lines objectAtIndex:index];
        if (line.startMS > milliseconds) break;
        active = (NSInteger)index;
    }
    if (active == _lastLyricIndex) return;
    NSInteger previous = _lastLyricIndex;
    _lastLyricIndex = active;
    UILabel *old = (UILabel *)[_panelScroll viewWithTag:5000 + previous];
    UILabel *now = (UILabel *)[_panelScroll viewWithTag:5000 + active];
    RewindAnimate(0.2, ^{
        if (previous >= 0) old.textColor = RewindLyricDimColor();
        if (active >= 0) now.textColor = RewindColorText();
    }, nil);
    if (active >= 0 && now) {
        CGFloat target = CGRectGetMidY(now.frame) - _panelScroll.bounds.size.height * 0.45f;
        CGFloat maxOffset = MAX(0, _panelScroll.contentSize.height - _panelScroll.bounds.size.height);
        [_panelScroll setContentOffset:CGPointMake(0, MAX(0, MIN(target, maxOffset))) animated:YES];
    }
}


- (void)morePressed { [self showTrackMenu:_player.track]; }

- (void)showTrackMenu:(RewindTrack *)track {
    if (!track) return;
    [_menuTrack release]; _menuTrack = [track retain];
    __block RewindPlayerVC *owner = self;
    RewindSheet *sheet = [[[RewindSheet alloc] initWithFrame:self.view.bounds] autorelease];
    [sheet setHeaderTitle:track.title subtitle:RewindTrackArtistText(track) accessories:nil];
    [sheet setTiles:[NSArray arrayWithObjects:
        [RewindSheetItem itemWithIcon:@"play-next" title:RewindL(@"menu_play_next")
                                action:^{ [owner performMenuAction:RewindPlayerMenuActionPlayNext]; }],
        [RewindSheetItem itemWithIcon:@"playlist-add" title:RewindL(@"menu_add_playlist")
                                action:^{ [owner performMenuAction:RewindPlayerMenuActionPlaylist]; }],
        [RewindSheetItem itemWithIcon:@"share" title:RewindL(@"menu_share")
                                action:^{ [owner performMenuAction:RewindPlayerMenuActionShare]; }], nil]];
    [sheet setItems:[NSArray arrayWithObjects:
        [RewindSheetItem itemWithIcon:@"mix" title:RewindL(@"menu_mix")
                                action:^{ [owner performMenuAction:RewindPlayerMenuActionMix]; }],
        [RewindSheetItem itemWithIcon:@"queue-add" title:RewindL(@"menu_queue")
                                action:^{ [owner performMenuAction:RewindPlayerMenuActionQueue]; }],
        [RewindSheetItem itemWithIcon:@"save" title:RewindL(@"menu_save_library")
                                action:^{ [owner performMenuAction:RewindPlayerMenuActionLibrary]; }],
        [RewindSheetItem itemWithIcon:@"download" title:RewindL(@"menu_download")
                                action:^{ [owner performMenuAction:RewindPlayerMenuActionDownload]; }],
        [RewindSheetItem itemWithIcon:@"album" title:RewindL(@"menu_album")
                                action:^{ [owner performMenuAction:RewindPlayerMenuActionAlbum]; }],
        [RewindSheetItem itemWithIcon:@"artist" title:RewindL(@"menu_artist")
                                action:^{ [owner performMenuAction:RewindPlayerMenuActionArtist]; }],
        [RewindSheetItem itemWithIcon:@"queue-clear" title:RewindL(@"menu_clear_queue")
                                action:^{ [owner performMenuAction:RewindPlayerMenuActionClearQueue]; }],
        [RewindSheetItem itemWithIcon:@"speed" title:RewindL(@"menu_speed")
                                action:^{ [owner performMenuAction:RewindPlayerMenuActionSpeed]; }],
        [RewindSheetItem itemWithIcon:@"sleep" title:RewindL(@"menu_sleep")
                                action:^{ [owner performMenuAction:RewindPlayerMenuActionSleep]; }], nil]];
    [sheet showInView:self.view];
}

- (void)performMenuAction:(NSInteger)action {
    RewindTrack *track = _menuTrack;
    if (!track) return;
    switch (action) {
        case RewindPlayerMenuActionPlayNext:
            [_player enqueueTrack:track usingAPI:_api afterCurrent:YES];
            RewindShowToast(self.view, RewindL(@"menu_play_next_added"), RW(24.0f));
            break;
        case RewindPlayerMenuActionPlaylist: [self showPlaylistPicker]; break;
        case RewindPlayerMenuActionShare: [self shareTrack:track]; break;
        case RewindPlayerMenuActionMix:
            [_player setContinuousPlayback:YES];
            if (RewindAccountIsSignedIn()) {
                RewindAccountLoadMix(track, ^(NSArray *tracks, NSError *error) {
                    if (error || !tracks.count) {
                        RewindShowToast(self.view, RewindFriendlyError(error) ?: RewindL(@"account_mix_failed"), RW(24.0f));
                        return;
                    }
                    if (_player.track && [[[tracks objectAtIndex:0] videoID] isEqualToString:_player.track.videoID]) {
                        for (NSInteger index = (NSInteger)tracks.count - 1; index >= 1; --index)
                            [_player enqueueTrack:[tracks objectAtIndex:(NSUInteger)index] usingAPI:_api afterCurrent:YES];
                    } else [_player setQueue:tracks selectedIndex:0 usingAPI:_api];
                });
            } else [_api relatedForTrack:track completion:^(NSArray *shelves, NSArray *links, NSError *error) {
                (void)links;
                NSMutableArray *tracks = [NSMutableArray array];
                for (RewindShelf *shelf in shelves) {
                    for (id item in shelf.items) {
                        if (![item isKindOfClass:[RewindTrack class]]) continue;
                        RewindTrack *candidate = item;
                        if (candidate.videoID.length && !candidate.isPlaylist) [tracks addObject:candidate];
                        if (tracks.count >= 20) break;
                    }
                    if (tracks.count >= 20) break;
                }
                if (!tracks.count) {
                    RewindShowToast(self.view, RewindFriendlyError(error) ?: RewindL(@"account_mix_failed"), RW(24.0f));
                    return;
                }
                [_player setQueue:tracks selectedIndex:0 usingAPI:_api];
            }];
            break;
        case RewindPlayerMenuActionQueue:
            [_player enqueueTrack:track usingAPI:_api afterCurrent:NO];
            RewindShowToast(self.view, RewindL(@"menu_queued"), RW(24.0f));
            break;
        case RewindPlayerMenuActionLibrary: [self saveTrack:track]; break;
        case RewindPlayerMenuActionDownload:
            RewindShowToast(self.view, RewindL(@"menu_download_started"), RW(24.0f));
            RewindDownloadTrack(track, _api, ^(NSError *error) {
                RewindShowToast(self.view, error ? RewindFriendlyError(error) : RewindL(@"menu_download_done"), RW(24.0f));
            });
            break;
        case RewindPlayerMenuActionAlbum:
            [self.navigationController setNavigationBarHidden:NO animated:YES];
            RewindPushAlbum(self, track, _api, _player);
            break;
        case RewindPlayerMenuActionArtist:
            [self.navigationController setNavigationBarHidden:NO animated:YES];
            RewindPushArtistProfile(self, track, _api, _player);
            break;
        case RewindPlayerMenuActionClearQueue:
            [_player clearQueue];
            RewindShowToast(self.view, RewindL(@"menu_queue_cleared"), RW(24.0f));
            break;
        case RewindPlayerMenuActionSpeed: [self showSpeedPicker]; break;
        case RewindPlayerMenuActionSleep: [self showSleepPicker]; break;
        default: break;
    }
}

- (void)showPlaylistPicker {
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:RewindL(@"menu_add_playlist")
                                                     message:_menuTrack.title delegate:self
                                           cancelButtonTitle:RewindL(@"cancel")
                                           otherButtonTitles:RewindL(@"new_playlist"), nil] autorelease];
    alert.tag = 9301;
    for (NSString *name in RewindPlaylistPickerTitles()) [alert addButtonWithTitle:name];
    [alert show];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
    if (index == alert.cancelButtonIndex) return;
    if (alert.tag == 9301) {
        if (index == 1) {
            UIAlertView *create = [[[UIAlertView alloc] initWithTitle:RewindL(@"new_playlist")
                                                               message:nil delegate:self
                                                     cancelButtonTitle:RewindL(@"cancel")
                                                     otherButtonTitles:RewindL(@"create"), nil] autorelease];
            create.alertViewStyle = UIAlertViewStylePlainTextInput;
            create.tag = 9302;
            [create show];
        } else {
            RewindAddTrackToPickedPlaylist(_menuTrack, [alert buttonTitleAtIndex:index], ^(NSError *error) {
                RewindShowToast(self.view, error ? RewindFriendlyError(error) : RewindL(@"added_to_playlist"), RW(24.0f));
            });
        }
    } else if (alert.tag == 9302) {
        NSString *name = [[[alert textFieldAtIndex:0] text]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!name.length) return;
        RewindCreatePlaylistWithTrack(name, _menuTrack, ^(NSError *error) {
            RewindShowToast(self.view, error ? error.localizedDescription : RewindL(@"added_to_playlist"), RW(24.0f));
        });
    }
}

- (void)showSpeedPicker {
    UIActionSheet *sheet = [[[UIActionSheet alloc] initWithTitle:RewindL(@"menu_speed") delegate:self
                                               cancelButtonTitle:RewindL(@"cancel") destructiveButtonTitle:nil
                                               otherButtonTitles:@"1x", @"1.25x", @"1.5x", @"2x", nil] autorelease];
    sheet.tag = 9401;
    [sheet showInView:self.view.window ?: self.view];
}

- (void)showSleepPicker {
    UIActionSheet *sheet = [[[UIActionSheet alloc] initWithTitle:RewindL(@"menu_sleep") delegate:self
                                               cancelButtonTitle:RewindL(@"cancel") destructiveButtonTitle:nil
                                               otherButtonTitles:RewindL(@"menu_off"), RewindL(@"menu_15"),
                                                                 RewindL(@"menu_30"), RewindL(@"menu_60"), nil] autorelease];
    sheet.tag = 9402;
    [sheet showInView:self.view.window ?: self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
    if (index == sheet.cancelButtonIndex) return;
    if (sheet.tag == 9401) {
        static const float rates[] = {1.0f, 1.25f, 1.5f, 2.0f};
        if (index >= 0 && index < 4) [_player setPlaybackRate:rates[index]];
    } else if (sheet.tag == 9402) {
        static const NSTimeInterval times[] = {0, 900, 1800, 3600};
        if (index >= 0 && index < 4) {
            if (index == 0) [_player cancelSleepTimer];
            else [_player setSleepTimer:times[index]];
        }
    }
}

@end

void RewindPushAlbum(UIViewController *source,
                   RewindTrack *track,
                   RewindAPI *api,
                   RewindPlayer *player) {
    if (!source || !track || !api || !player) return;
    RewindAlbumVC *album = [[[RewindAlbumVC alloc] initWithTrack:track
                                                          api:api
                                                       player:player] autorelease];
    [source.navigationController pushViewController:album animated:YES];
}
