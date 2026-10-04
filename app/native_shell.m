#import "native_shell.h"

#import <QuartzCore/QuartzCore.h>

#import "rewind_api.h"
#import "rewind_player.h"
#import "rewind_theme.h"
#import "rewind_l10n.h"
#import "rewind_ui.h"
#import "rewind_image_cache.h"
#import "rewind_account.h"
#import "library_vc.h"
#import "playlist_vc.h"
#import "artist_vc.h"
#import "settings_vc.h"
#import "about_vc.h"
#import "account_vc.h"
#import "vinyl_view.h"
#import "player_vc.h"
#import "rewind_download.h"
#import "rewind_chrome.h"

static NSString *const RewindNativeHomeID = @"FEmusic_home";
static NSString *const RewindNativeExploreID = @"FEmusic_explore";

#pragma mark - shared helpers

/* playable songs of a shelf, in order, without playlists, mixes or links */
static NSArray *RewindNativePlayable(NSArray *items) {
    NSMutableArray *tracks = [NSMutableArray array];
    for (id item in items) {
        if (![item isKindOfClass:[RewindTrack class]]) continue;
        RewindTrack *track = item;
        if (track.videoID.length && !track.isPlaylist && ![track.resultType isEqualToString:RewindResultTypeMix] &&
            ![track.resultType isEqualToString:RewindResultTypeArtist])
            [tracks addObject:track];
    }
    return tracks;
}

/* stock cells use the image size, so crop thumbnails to the row size */
static UIImage *RewindNativeThumb(UIImage *image, CGFloat points) {
    if (!image) return nil;
    CGFloat scale = [UIScreen mainScreen].scale;
    CGSize size = image.size;
    CGFloat side = MIN(size.width, size.height);
    CGRect crop = CGRectMake((size.width - side) * 0.5f, (size.height - side) * 0.5f, side, side);
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(points, points), YES, scale);
    CGFloat ratio = points / side;
    [image drawInRect:CGRectMake(-crop.origin.x * ratio, -crop.origin.y * ratio, size.width * ratio, size.height * ratio)];
    UIImage *thumb = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return thumb;
}

static UIImage *RewindNativeBlankThumb(CGFloat points) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(points, points), YES, [UIScreen mainScreen].scale);
    [RewindColorPlaceholder() setFill];
    UIRectFill(CGRectMake(0, 0, points, points));
    UIImage *blank = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return blank;
}

/* stock tables and cells draw white on ios 5; the dark theme paints both from the palette */
static void RewindNativeGradient(CGContextRef ctx, CGRect rect, const CGFloat *top, const CGFloat *bottom);

static const CGFloat RewindNativeHeaderHeight = 24.0f;

/* match the ios 5 section header to the navigation bar */
static UIView *RewindNativeSectionHeader(UITableView *table, NSString *title) {
    static UIImage *bar;
    if (!bar) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(1.0f, RewindNativeHeaderHeight), YES, 0.0f);
        const CGFloat top[4] = { 0.80f, 0.22f, 0.18f, 1.0f }, bottom[4] = { 0.56f, 0.10f, 0.08f, 1.0f };
        RewindNativeGradient(UIGraphicsGetCurrentContext(), CGRectMake(0.0f, 0.0f, 1.0f, RewindNativeHeaderHeight), top, bottom);
        [[UIColor colorWithWhite:0.0f alpha:0.7f] setFill];
        UIRectFill(CGRectMake(0.0f, RewindNativeHeaderHeight - 1.0f, 1.0f, 1.0f));
        bar = [UIGraphicsGetImageFromCurrentImageContext() retain];
        UIGraphicsEndImageContext();
    }
    UIImageView *header = [[[UIImageView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, table.bounds.size.width,
                                                                         RewindNativeHeaderHeight)] autorelease];
    header.image = bar;
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectMake(12.0f, 0.0f, header.bounds.size.width - 24.0f,
                                                                RewindNativeHeaderHeight - 1.0f)] autorelease];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    label.backgroundColor = [UIColor clearColor];
    label.font = RewindChromeFont(15.0f, YES);
    label.textColor = [UIColor whiteColor];
    label.shadowColor = [UIColor blackColor];
    label.shadowOffset = CGSizeMake(0.0f, -1.0f);
    label.text = title;
    [header addSubview:label];
    return header;
}

static void RewindNativeStyleTable(UITableView *table) {
    table.backgroundColor = RewindColorBackground();
    table.separatorColor = RewindColorDivider();
    RewindChromeStyleTable(table);
}

static void RewindNativeStyleCell(UITableViewCell *cell) {
    RewindChromeStyleCell(cell);
    /* the faces of an ios 5 cell, which ios 7 replaced with lighter and smaller ones */
    cell.textLabel.font = RewindChromeFont(17.0f, YES);
    cell.detailTextLabel.font = RewindChromeFont(14.0f, NO);
    cell.backgroundColor = RewindColorSurface();
    cell.textLabel.textColor = RewindColorText();
    cell.detailTextLabel.textColor = RewindColorTextSecondary();
    if (!cell.selectedBackgroundView) {
        UIView *selected = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
        selected.backgroundColor = RewindColorSurfaceHigh();
        cell.selectedBackgroundView = selected;
    }
}

@class RewindNativePlayerVC;

@interface RewindNativeContext : NSObject {
@public
    RewindPlayer *player;
    RewindAPI *api;
}
@end

@implementation RewindNativeContext
- (void)dealloc {
    [player release];
    [api release];
    [super dealloc];
}
@end

static RewindNativeContext *RewindNativeContextMake(RewindPlayer *player, RewindAPI *api) {
    RewindNativeContext *context = [[[RewindNativeContext alloc] init] autorelease];
    context->player = [player retain];
    context->api = [api retain];
    return context;
}

@interface RewindNativePlayerVC : UIViewController <RewindVinylScratchDelegate, UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate, UIActionSheetDelegate> {
    RewindNativeContext *_context;
    UILabel *_artistLabel, *_titleLabel, *_albumLabel, *_countLabel;
    UILabel *_elapsedLabel, *_remainingLabel;
    UISlider *_slider;
    UIButton *_repeatButton, *_shuffleButton, *_previousButton, *_playButton, *_nextButton;
    RewindVinylView *_vinyl;
    UIView *_panel;
    UIActivityIndicatorView *_playSpinner;
    UIButton *_likeButton, *_dislikeButton;
    RewindTrack *_menuTrack;
    UIView *_lyricsPanel;
    UIView *_lyricsHeader;
    UIImageView *_lyricsThumb;
    UILabel *_lyricsHeading;
    UITableView *_lyricsTable;
    UILabel *_lyricsStatus;
    UIActivityIndicatorView *_lyricsSpinner;
    RewindLyrics *_lyrics;
    NSError *_lyricsError;
    NSString *_lyricsVideoID;
    NSArray *_lyricHeights;
    CGFloat _lyricsWidth;
    NSInteger _lyricsActive;
    NSUInteger _lyricsRequest;
    BOOL _showingLyrics, _lyricsLoading, _lyricsAttempted, _lyricsUserScrolling;
    NSTimer *_timer;
    BOOL _dragging;
    NSString *_artworkURL;
}
- (id)initWithContext:(RewindNativeContext *)context;
@end

@interface RewindNativeQueueVC : UITableViewController {
    RewindNativeContext *_context;
}
- (id)initWithContext:(RewindNativeContext *)context;
@end

static void RewindNativePushPlayer(UINavigationController *navigation, RewindNativeContext *context) {
    if ([navigation.topViewController isKindOfClass:[RewindNativePlayerVC class]]) return;
    RewindNativePlayerVC *player = [[[RewindNativePlayerVC alloc] initWithContext:context] autorelease];
    [navigation pushViewController:player animated:YES];
}

@interface RewindNativeShelvesVC : UITableViewController <UISearchBarDelegate> {
    RewindNativeContext *_context;
    void (^_loader)(void (^done)(NSArray *shelves, NSError *error));
    NSArray *_shelves;
    NSArray *_results;
    UISearchBar *_searchBar;
    UIActivityIndicatorView *_spinner;
    UILabel *_status;
    NSUInteger _request;
    BOOL _loaded;
    NSArray *_tiles;
    UIView *_tilesView;
    NSMutableDictionary *_offsets;
}
- (id)initWithTitle:(NSString *)title context:(RewindNativeContext *)context searchable:(BOOL)searchable
             loader:(void (^)(void (^done)(NSArray *shelves, NSError *error)))loader;
/* big glyph buttons above the shelves, made by RewindNativeRow */
- (void)setTiles:(NSArray *)tiles;
@end

/* what a tap on an item of a shelf does: a page for a link, album, playlist or artist, the queue for songs */
static void RewindNativeOpen(id item, RewindShelf *shelf, UINavigationController *navigation, RewindNativeContext *context) {
    RewindPlayer *player = context->player;
    RewindAPI *api = context->api;
    if ([item isKindOfClass:[RewindBrowseLink class]]) {
        RewindBrowseLink *link = item;
        RewindNativeShelvesVC *page = [[[RewindNativeShelvesVC alloc] initWithTitle:link.title context:context searchable:NO
            loader:^(void (^done)(NSArray *, NSError *)) {
                [api browseShelves:link.browseID params:link.params completion:^(NSArray *shelves, NSArray *chips, NSError *error) {
                    (void)chips;
                    done(shelves, error);
                }];
            }] autorelease];
        [navigation pushViewController:page animated:YES];
        return;
    }
    if (![item isKindOfClass:[RewindTrack class]]) return;
    RewindTrack *track = item;
    if ([track.resultType isEqualToString:RewindResultTypeArtist]) {
        RewindArtistVC *artist = [[[RewindArtistVC alloc] initWithArtist:track.title artworkURL:track.thumbnailURL
                                                                     api:api player:player seedTrack:nil] autorelease];
        [navigation pushViewController:artist animated:YES];
        return;
    }
    if ([track.resultType isEqualToString:RewindResultTypeMix]) {
        [player setContinuousPlayback:YES];
        void (^play)(NSArray *, NSError *) = ^(NSArray *tracks, NSError *error) {
            tracks = RewindNativePlayable(tracks);
            if (error || !tracks.count) {
                RewindShowToast(navigation.view, RewindFriendlyError(error) ?: RewindL(@"account_mix_failed"), 24.0f);
                return;
            }
            RewindRecordTrack([tracks objectAtIndex:0]);
            [player setQueue:tracks selectedIndex:0 usingAPI:api];
            RewindNativePushPlayer(navigation, context);
        };
        if (RewindAccountIsSignedIn()) RewindAccountLoadMix(track, play);
        else if (track.playlistID.length) [api playlistTracksForID:track.playlistID completion:play];
        else play(nil, nil);
        return;
    }
    if (track.isPlaylist || [track.resultType isEqualToString:RewindResultTypeAlbum]) {
        RewindPlaylistVC *playlist = [[[RewindPlaylistVC alloc] initWithRemotePlaylist:track player:player api:api] autorelease];
        [navigation pushViewController:playlist animated:YES];
        return;
    }
    NSArray *queue = RewindNativePlayable(shelf.items);
    NSUInteger index = [queue indexOfObjectIdenticalTo:track];
    if (index == NSNotFound) {
        queue = [NSArray arrayWithObject:track];
        index = 0;
    }
    RewindRecordTrack(track);
    [player setQueue:queue selectedIndex:(NSInteger)index usingAPI:api];
    RewindNativePushPlayer(navigation, context);
}

#pragma mark - covers

static CGFloat RewindNativeCoverSide(void) {
    return RewindIsPad() ? 140.0f : 96.0f;
}

/* a cover with its title and artist under it, the way the ios 5 itunes store shows a shelf */
@interface RewindNativeCoverTile : UIControl {
@public
    id _item;
    RewindShelf *_shelf;
    UIImageView *_cover;
    UILabel *_title;
    UILabel *_detail;
    NSString *_url;
}
- (id)initWithItem:(id)item shelf:(RewindShelf *)shelf side:(CGFloat)side;
@end

@implementation RewindNativeCoverTile

- (id)initWithItem:(id)item shelf:(RewindShelf *)shelf side:(CGFloat)side {
    self = [super initWithFrame:CGRectMake(0.0f, 0.0f, side, side + 40.0f)];
    if (!self) return nil;
    _item = [item retain];
    _shelf = [shelf retain];
    _cover = [[UIImageView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, side, side)];
    _cover.contentMode = UIViewContentModeScaleAspectFill;
    _cover.clipsToBounds = YES;
    _cover.backgroundColor = RewindColorPlaceholder();
    _cover.layer.borderWidth = 1.0f;
    _cover.layer.borderColor = [UIColor colorWithWhite:0.0f alpha:0.6f].CGColor;
    [self addSubview:_cover];
    _title = [[UILabel alloc] initWithFrame:CGRectMake(0.0f, side + 4.0f, side, 17.0f)];
    _title.font = RewindChromeFont(13.0f, YES);
    _detail = [[UILabel alloc] initWithFrame:CGRectMake(0.0f, side + 21.0f, side, 15.0f)];
    _detail.font = RewindChromeFont(11.0f, NO);
    for (UILabel *label in [NSArray arrayWithObjects:_title, _detail, nil]) {
        label.backgroundColor = [UIColor clearColor];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.userInteractionEnabled = NO;
        [self addSubview:label];
    }
    _title.textColor = [UIColor whiteColor];
    _detail.textColor = RewindColorTextSecondary();

    if ([item isKindOfClass:[RewindTrack class]]) {
        RewindTrack *track = item;
        _title.text = track.title;
        _detail.text = track.detail.length ? track.detail : RewindTrackArtistText(track);
        /* people get a round photo, as everywhere in youtube music */
        BOOL artist = [track.resultType isEqualToString:RewindResultTypeArtist];
        _cover.layer.cornerRadius = artist ? side * 0.5f : 3.0f;
        if (artist) _title.textAlignment = _detail.textAlignment = NSTextAlignmentCenter;
        _url = [track.thumbnailURL copy];
        if (_url.length) {
            RewindNativeCoverTile *tile = self;
            NSString *expected = _url;
            [tile retain];
            RewindLoadImageSized(expected, side * 2.0f, ^(UIImage *image) {
                if (image && [tile->_url isEqualToString:expected]) tile->_cover.image = image;
                [tile release];
            });
        }
    } else if ([item isKindOfClass:[RewindBrowseLink class]]) {
        /* moods and genres have no picture; a red card with the name stands in for one */
        _cover.image = nil;
        _cover.backgroundColor = RewindColorChrome();
        _cover.layer.cornerRadius = 3.0f;
        UILabel *name = [[[UILabel alloc] initWithFrame:CGRectInset(_cover.bounds, 8.0f, 8.0f)] autorelease];
        name.backgroundColor = [UIColor clearColor];
        name.textColor = [UIColor whiteColor];
        name.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.5f];
        name.shadowOffset = CGSizeMake(0.0f, -1.0f);
        name.font = RewindChromeFont(15.0f, YES);
        name.numberOfLines = 0;
        name.textAlignment = NSTextAlignmentCenter;
        name.text = [(RewindBrowseLink *)item title];
        [_cover addSubview:name];
    }
    return self;
}

- (void)dealloc {
    [_item release];
    [_shelf release];
    [_cover release];
    [_title release];
    [_detail release];
    [_url release];
    [super dealloc];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    _cover.alpha = highlighted ? 0.6f : 1.0f;
}

@end

static const CGFloat RewindNativeKeyMargin = 3.0f;

static UIImage *RewindNativeKeyImage(BOOL pressed) {
    static UIImage *images[2];
    if (images[pressed ? 1 : 0]) return images[pressed ? 1 : 0];
    CGFloat margin = RewindNativeKeyMargin, radius = 10.0f;
    CGSize size = CGSizeMake(radius * 2.0f + 1.0f + margin * 2.0f, radius * 2.0f + 1.0f + margin * 2.0f);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0f);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect body = CGRectInset(CGRectMake(0.0f, 0.0f, size.width, size.height), margin, margin);
    body.origin.y -= pressed ? 0.0f : 1.0f;
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:body cornerRadius:radius];
    if (!pressed) {
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeMake(0.0f, 2.0f), 3.0f, [UIColor colorWithWhite:0.0f alpha:0.85f].CGColor);
        [[UIColor blackColor] setFill];
        [shape fill];
        CGContextRestoreGState(ctx);
    }
    CGContextSaveGState(ctx);
    [shape addClip];
    const CGFloat raised[8] = { 0.27f, 0.27f, 0.28f, 1.0f,  0.07f, 0.07f, 0.08f, 1.0f };
    const CGFloat sunk[8] = { 0.04f, 0.04f, 0.05f, 1.0f,  0.14f, 0.14f, 0.15f, 1.0f };
    const CGFloat *top = pressed ? sunk : raised, *bottom = pressed ? sunk + 4 : raised + 4;
    RewindNativeGradient(ctx, body, top, bottom);
    if (!pressed) {
        CGRect gloss = CGRectMake(body.origin.x, body.origin.y, body.size.width, floorf(body.size.height * 0.48f));
        const CGFloat glossTop[4] = { 1.0f, 1.0f, 1.0f, 0.10f }, glossBottom[4] = { 1.0f, 1.0f, 1.0f, 0.02f };
        RewindNativeGradient(ctx, gloss, glossTop, glossBottom);
    }
    UIBezierPath *bevel = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(body, 1.0f, 1.0f) cornerRadius:radius - 1.0f];
    bevel.lineWidth = 1.0f;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(0.0f, CGRectGetMidY(body), size.width, size.height));
    [[UIColor colorWithWhite:0.0f alpha:pressed ? 0.15f : 0.45f] setStroke];
    [bevel stroke];
    CGContextRestoreGState(ctx);
    CGContextRestoreGState(ctx);
    [[UIColor colorWithWhite:0.0f alpha:0.95f] setStroke];
    shape.lineWidth = 1.0f;
    [shape stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGFloat cap = radius + margin;
    images[pressed ? 1 : 0] = [[image resizableImageWithCapInsets:UIEdgeInsetsMake(cap, cap, cap, cap)] retain];
    return images[pressed ? 1 : 0];
}

#pragma mark - shelves

@implementation RewindNativeShelvesVC

- (id)initWithTitle:(NSString *)title context:(RewindNativeContext *)context searchable:(BOOL)searchable
             loader:(void (^)(void (^done)(NSArray *shelves, NSError *error)))loader {
    self = [super initWithStyle:UITableViewStylePlain];
    if (!self) return nil;
    self.title = title;
    _context = [context retain];
    _loader = [loader copy];
    if (searchable) {
        _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320.0f, 44.0f)];
        _searchBar.delegate = self;
        _searchBar.placeholder = RewindL(@"search_placeholder");
        RewindChromeStyleSearchBar(_searchBar);
    }
    return self;
}

- (void)dealloc {
    ++_request;
    _searchBar.delegate = nil;
    [_searchBar release];
    [_spinner release];
    [_status release];
    [_shelves release];
    [_results release];
    [_loader release];
    [_context release];
    [_tiles release];
    [_tilesView release];
    [_offsets release];
    [super dealloc];
}

- (void)setTiles:(NSArray *)tiles {
    [_tiles release];
    _tiles = [tiles copy];
    [_tilesView release];
    _tilesView = nil;
    if ([self isViewLoaded]) [self.view setNeedsLayout];
}

- (void)tilePressed:(UIButton *)button {
    NSUInteger index = (NSUInteger)button.tag;
    if (index >= _tiles.count) return;
    void (^action)(UINavigationController *) = [[_tiles objectAtIndex:index] objectForKey:@"action"];
    if (action) action(self.navigationController);
}

/* three keys a row on the phone, one row on the ipad */
- (void)layoutTilesForWidth:(CGFloat)width {
    if (!_tiles.count) return;
    if (_tilesView && fabsf((float)(_tilesView.bounds.size.width - width)) < 0.5f) return;
    NSUInteger perRow = RewindIsPad() ? MIN((NSUInteger)6, _tiles.count) : 3;
    CGFloat gap = 10.0f, side = 10.0f, keyH = RewindIsPad() ? 88.0f : 74.0f;
    CGFloat keyW = floorf((width - side * 2.0f - gap * (perRow - 1)) / perRow);
    NSUInteger rows = (_tiles.count + perRow - 1) / perRow;
    UIView *view = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, width, side * 2.0f + rows * keyH + (rows - 1) * gap)]
                    autorelease];
    view.backgroundColor = RewindColorBackground();
    for (NSUInteger index = 0; index < _tiles.count; ++index) {
        NSDictionary *tile = [_tiles objectAtIndex:index];
        NSUInteger row = index / perRow, column = index % perRow;
        UIButton *key = [UIButton buttonWithType:UIButtonTypeCustom];
        key.frame = CGRectMake(side + column * (keyW + gap), side + row * (keyH + gap), keyW, keyH);
        key.tag = (NSInteger)index;
        [key setBackgroundImage:RewindNativeKeyImage(NO) forState:UIControlStateNormal];
        [key setBackgroundImage:RewindNativeKeyImage(YES) forState:UIControlStateHighlighted];
        [key addTarget:self action:@selector(tilePressed:) forControlEvents:UIControlEventTouchUpInside];
        UIImageView *glyph = [[[UIImageView alloc] initWithImage:RewindIcon([tile objectForKey:@"icon"], 28.0f,
                                                                            [UIColor whiteColor])] autorelease];
        glyph.frame = CGRectMake(floorf((keyW - 28.0f) * 0.5f), floorf(keyH * 0.5f) - 24.0f, 28.0f, 28.0f);
        glyph.layer.shadowColor = [UIColor blackColor].CGColor;
        glyph.layer.shadowOffset = CGSizeMake(0.0f, -1.0f);
        glyph.layer.shadowOpacity = 0.9f;
        glyph.layer.shadowRadius = 0.5f;
        glyph.userInteractionEnabled = NO;
        [key addSubview:glyph];
        UILabel *name = [[[UILabel alloc] initWithFrame:CGRectMake(4.0f, floorf(keyH * 0.5f) + 8.0f, keyW - 8.0f, 16.0f)]
                         autorelease];
        name.backgroundColor = [UIColor clearColor];
        name.textColor = [UIColor whiteColor];
        name.shadowColor = [UIColor blackColor];
        name.shadowOffset = CGSizeMake(0.0f, -1.0f);
        name.font = RewindChromeFont(12.0f, YES);
        name.textAlignment = NSTextAlignmentCenter;
        name.adjustsFontSizeToFitWidth = YES;
        name.text = [tile objectForKey:@"title"];
        name.userInteractionEnabled = NO;
        [key addSubview:name];
        [view addSubview:key];
    }
    [_tilesView release];
    _tilesView = [view retain];
    self.tableView.tableHeaderView = _tilesView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _offsets = [[NSMutableDictionary alloc] init];
    self.tableView.rowHeight = 60.0f;
    RewindNativeStyleTable(self.tableView);
    if (_searchBar) {
        self.tableView.tableHeaderView = _searchBar;
        /* a tap anywhere puts the keyboard away; the tap still reaches the cover or row under it */
        UITapGestureRecognizer *tap = [[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(dismissKeyboard)] autorelease];
        tap.cancelsTouchesInView = NO;
        [self.tableView addGestureRecognizer:tap];
    }
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    [self.view addSubview:_spinner];
}

/* center the spinner after the ipad table receives its final width */
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    [self layoutTilesForWidth:width];
    CGFloat top = _searchBar ? 44.0f : (_tilesView ? _tilesView.bounds.size.height : 0.0f);
    _spinner.center = CGPointMake(floorf(width * 0.5f), 100.0f + top);
    _status.frame = CGRectMake(20.0f, 60.0f + top, MAX(40.0f, width - 40.0f), 60.0f);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_loaded || !_loader) return;
    _loaded = YES;
    /* clear the previous error before showing the retry spinner */
    [self showStatus:nil];
    [_spinner startAnimating];
    NSUInteger request = ++_request;
    _loader(^(NSArray *shelves, NSError *error) {
        if (request != _request) return;
        [_spinner stopAnimating];
        NSMutableArray *kept = [NSMutableArray array];
        for (RewindShelf *shelf in shelves)
            if ([shelf isKindOfClass:[RewindShelf class]] && shelf.items.count && !shelf.videoLineup) [kept addObject:shelf];
        [_shelves release];
        _shelves = [kept copy];
        [_offsets removeAllObjects];
        if (kept.count) {
            [self showStatus:nil];
        } else {
            _loaded = NO;
            [self showStatus:error ? RewindFriendlyError(error) : RewindL(@"no_tracks")];
        }
        [self.tableView reloadData];
    });
}

- (void)showStatus:(NSString *)text {
    if (!_status) {
        _status = [[UILabel alloc] initWithFrame:CGRectMake(20.0f, 60.0f + (_searchBar ? 44.0f : 0.0f),
                                                            MAX(40.0f, self.view.bounds.size.width - 40.0f), 60.0f)];
        _status.backgroundColor = [UIColor clearColor];
        _status.textColor = RewindColorTextSecondary();
        _status.textAlignment = NSTextAlignmentCenter;
        _status.numberOfLines = 0;
        _status.font = RewindChromeFont(15.0f, NO);
        [self.view addSubview:_status];
    }
    _status.text = text;
    _status.hidden = !text.length;
}

- (NSArray *)sections {
    if (_results) return [NSArray arrayWithObject:[[[RewindShelf alloc] initWithTitle:RewindL(@"search_results")
                                                                                items:_results] autorelease]];
    return _shelves;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (NSInteger)[self sections].count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = [[[self sections] objectAtIndex:(NSUInteger)section] title];
    return title.length ? RewindNativeSectionHeader(tableView, title) : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return [[[[self sections] objectAtIndex:(NSUInteger)section] title] length] ? RewindNativeHeaderHeight : 0.0f;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    NSUInteger count = [[[self sections] objectAtIndex:(NSUInteger)section] items].count;
    return (NSInteger)(_results ? count : (count ? 1 : 0));
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return _results ? 60.0f : RewindNativeCoverSide() + 58.0f;
}

- (void)coverPressed:(RewindNativeCoverTile *)tile {
    RewindNativeOpen(tile->_item, tile->_shelf, self.navigationController, _context);
}

- (void)dismissKeyboard {
    [_searchBar resignFirstResponder];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    (void)scrollView;
    [_searchBar resignFirstResponder];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == self.tableView) return;
    [_offsets setObject:[NSNumber numberWithFloat:(float)scrollView.contentOffset.x]
                 forKey:[NSNumber numberWithInteger:scrollView.tag]];
}

/* one shelf is one row: its covers scroll sideways under the red title */
- (UITableViewCell *)coverCellForSection:(NSInteger)section {
    static NSString *reuse = @"native-covers";
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:reuse];
    UIScrollView *strip = nil;
    for (UIView *child in cell.contentView.subviews)
        if ([child isKindOfClass:[UIScrollView class]]) strip = (UIScrollView *)child;
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse] autorelease];
        RewindNativeStyleCell(cell);
        cell.backgroundColor = RewindColorBackground();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        strip = [[[UIScrollView alloc] initWithFrame:cell.contentView.bounds] autorelease];
        strip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        strip.showsHorizontalScrollIndicator = NO;
        strip.scrollsToTop = NO;
        strip.delegate = self;
        [cell.contentView addSubview:strip];
    }
    for (UIView *old in [[strip.subviews copy] autorelease]) [old removeFromSuperview];
    /* the tag is set after the old tiles go, so their offset is not saved under the new shelf */
    strip.tag = -1;
    RewindShelf *shelf = [[self sections] objectAtIndex:(NSUInteger)section];
    CGFloat side = RewindNativeCoverSide(), gap = 12.0f, x = 10.0f;
    NSUInteger count = MIN((NSUInteger)24, shelf.items.count);
    for (NSUInteger index = 0; index < count; ++index) {
        RewindNativeCoverTile *tile = [[[RewindNativeCoverTile alloc] initWithItem:[shelf.items objectAtIndex:index]
                                                                              shelf:shelf side:side] autorelease];
        tile.frame = CGRectMake(x, 10.0f, side, side + 40.0f);
        [tile addTarget:self action:@selector(coverPressed:) forControlEvents:UIControlEventTouchUpInside];
        [strip addSubview:tile];
        x += side + gap;
    }
    strip.contentSize = CGSizeMake(x - gap + 10.0f, side + 50.0f);
    NSNumber *offset = [_offsets objectForKey:[NSNumber numberWithInteger:section]];
    strip.contentOffset = CGPointMake(offset ? [offset floatValue] : 0.0f, 0.0f);
    strip.tag = section;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!_results) return [self coverCellForSection:indexPath.section];
    static NSString *reuse = @"native-row";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse] autorelease];
        RewindNativeStyleCell(cell);
    }
    RewindShelf *shelf = [[self sections] objectAtIndex:(NSUInteger)indexPath.section];
    id item = [shelf.items objectAtIndex:(NSUInteger)indexPath.row];
    NSInteger key = indexPath.section * 10000 + indexPath.row + 1;
    cell.tag = key;
    if ([item isKindOfClass:[RewindTrack class]]) {
        RewindTrack *track = item;
        cell.textLabel.text = track.title;
        cell.detailTextLabel.text = track.detail.length ? track.detail : RewindTrackArtistText(track);
        cell.accessoryView = (track.isPlaylist || [track.resultType isEqualToString:RewindResultTypeAlbum] ||
                              [track.resultType isEqualToString:RewindResultTypeArtist])
            ? RewindChromeDisclosure() : nil;
        cell.imageView.image = RewindNativeBlankThumb(50.0f);
        NSString *url = track.thumbnailURL;
        if (url.length)
            RewindLoadImageSized(url, 100.0f, ^(UIImage *image) {
                if (cell.tag != key || !image) return;
                cell.imageView.image = RewindNativeThumb(image, 50.0f);
                [cell setNeedsLayout];
            });
    } else {
        cell.textLabel.text = [item isKindOfClass:[RewindBrowseLink class]] ? [(RewindBrowseLink *)item title] : @"";
        cell.detailTextLabel.text = nil;
        cell.imageView.image = nil;
        cell.accessoryView = RewindChromeDisclosure();
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_results) return;
    RewindShelf *shelf = [[self sections] objectAtIndex:(NSUInteger)indexPath.section];
    RewindNativeOpen([shelf.items objectAtIndex:(NSUInteger)indexPath.row], shelf, self.navigationController, _context);
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    NSString *query = [searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!query.length) return;
    NSUInteger request = ++_request;
    [_spinner startAnimating];
    [self showStatus:nil];
    [_context->api search:query completion:^(NSArray *tracks, NSError *error) {
        if (request != _request) return;
        [_spinner stopAnimating];
        [_results release];
        _results = [tracks copy];
        if (error || !tracks.count) [self showStatus:error ? RewindFriendlyError(error) : RewindL(@"no_tracks")];
        [self.tableView reloadData];
    }];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    (void)searchBar;
    if (searchText.length) return;
    ++_request;
    [_spinner stopAnimating];
    [_results release];
    _results = nil;
    [self showStatus:nil];
    [self.tableView reloadData];
}

@end

#pragma mark - menus

@interface RewindNativeMenuVC : UITableViewController {
    RewindNativeContext *_context;
    NSArray *_sections;
}
- (id)initWithTitle:(NSString *)title context:(RewindNativeContext *)context sections:(NSArray *)sections;
@end

/* a menu row: title, glyph name and what a tap does with the navigation stack */
static NSDictionary *RewindNativeRow(NSString *title, NSString *icon, void (^action)(UINavigationController *navigation)) {
    return [NSDictionary dictionaryWithObjectsAndKeys:title, @"title", icon, @"icon", [[action copy] autorelease], @"action", nil];
}

static NSDictionary *RewindNativeSection(NSString *title, NSArray *rows) {
    return [NSDictionary dictionaryWithObjectsAndKeys:title ?: @"", @"title", rows, @"rows", nil];
}

@implementation RewindNativeMenuVC

- (id)initWithTitle:(NSString *)title context:(RewindNativeContext *)context sections:(NSArray *)sections {
    self = [super initWithStyle:UITableViewStylePlain];
    if (!self) return nil;
    self.title = title;
    _context = [context retain];
    _sections = [sections copy];
    return self;
}

- (void)dealloc {
    [_sections release];
    [_context release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 52.0f;
    RewindNativeStyleTable(self.tableView);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (NSInteger)_sections.count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = [[_sections objectAtIndex:(NSUInteger)section] objectForKey:@"title"];
    return title.length ? RewindNativeSectionHeader(tableView, title) : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return [[[_sections objectAtIndex:(NSUInteger)section] objectForKey:@"title"] length] ? RewindNativeHeaderHeight : 0.0f;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return (NSInteger)[[[_sections objectAtIndex:(NSUInteger)section] objectForKey:@"rows"] count];
}

- (NSDictionary *)rowAt:(NSIndexPath *)indexPath {
    return [[[_sections objectAtIndex:(NSUInteger)indexPath.section] objectForKey:@"rows"] objectAtIndex:(NSUInteger)indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"native-menu";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse] autorelease];
        RewindNativeStyleCell(cell);
        cell.accessoryView = RewindChromeDisclosure();
        cell.textLabel.font = RewindChromeFont(18.0f, YES);
    }
    NSDictionary *row = [self rowAt:indexPath];
    cell.textLabel.text = [row objectForKey:@"title"];
    NSString *icon = [row objectForKey:@"icon"];
    cell.imageView.image = icon.length ? RewindIcon(icon, 26.0f, [UIColor colorWithWhite:0.85f alpha:1.0f]) : nil;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    void (^action)(UINavigationController *) = [[self rowAt:indexPath] objectForKey:@"action"];
    if (action) action(self.navigationController);
}

@end

#pragma mark - sliders

static void RewindNativeGradient(CGContextRef ctx, CGRect rect, const CGFloat *top, const CGFloat *bottom) {
    CGFloat parts[8] = { top[0], top[1], top[2], top[3], bottom[0], bottom[1], bottom[2], bottom[3] };
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, parts, NULL, 2);
    if (gradient) {
        CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0.0f, CGRectGetMinY(rect)),
                                    CGPointMake(0.0f, CGRectGetMaxY(rect)), 0);
        CGGradientRelease(gradient);
    }
    CGColorSpaceRelease(space);
}

/* a rounded bar, stretchable between its caps: a glossy blue fill or a white groove with a shaded top edge */
static UIImage *RewindNativeTrackImage(BOOL filled) {
    static UIImage *fill, *groove;
    UIImage **slot = filled ? &fill : &groove;
    if (*slot) return *slot;
    const CGFloat side = 10.0f;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side + 2.0f, side), NO, 0.0f);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect rect = CGRectMake(0.0f, 0.0f, side + 2.0f, side);
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 0.5f, 0.5f) cornerRadius:(side - 1.0f) * 0.5f];
    CGContextSaveGState(ctx);
    [shape addClip];
    if (filled) {
        const CGFloat top[4] = { 0.36f, 0.62f, 0.96f, 1.0f }, bottom[4] = { 0.13f, 0.38f, 0.82f, 1.0f };
        RewindNativeGradient(ctx, rect, top, bottom);
        [[UIColor colorWithWhite:1.0f alpha:0.3f] setFill];
        UIRectFill(CGRectMake(0.0f, 0.0f, rect.size.width, 2.0f));
    } else {
        const CGFloat top[4] = { 0.62f, 0.62f, 0.63f, 1.0f }, bottom[4] = { 0.92f, 0.92f, 0.93f, 1.0f };
        RewindNativeGradient(ctx, rect, top, bottom);
    }
    CGContextRestoreGState(ctx);
    [[UIColor colorWithWhite:0.0f alpha:0.45f] setStroke];
    shape.lineWidth = 1.0f;
    [shape stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    *slot = [[image resizableImageWithCapInsets:UIEdgeInsetsMake(0.0f, 4.0f, 0.0f, 4.0f)] retain];
    return *slot;
}

/* a lit metal ball with a soft drop shadow */
static UIImage *RewindNativeThumbImage(void) {
    static UIImage *thumb;
    if (thumb) return thumb;
    const CGFloat canvas = 34.0f, disc = 29.0f;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(canvas, canvas), NO, 0.0f);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect ball = CGRectMake((canvas - disc) * 0.5f, (canvas - disc) * 0.5f - 1.0f, disc, disc);
    [[UIColor colorWithWhite:0.0f alpha:0.18f] setFill];
    CGContextFillEllipseInRect(ctx, CGRectOffset(CGRectInset(ball, -1.0f, -1.0f), 0.0f, 2.0f));
    [[UIColor colorWithWhite:0.0f alpha:0.35f] setFill];
    CGContextFillEllipseInRect(ctx, CGRectOffset(ball, 0.0f, 1.0f));
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, ball);
    CGContextClip(ctx);
    const CGFloat top[4] = { 0.98f, 0.98f, 0.98f, 1.0f }, bottom[4] = { 0.60f, 0.60f, 0.62f, 1.0f };
    RewindNativeGradient(ctx, ball, top, bottom);
    CGRect gloss = CGRectInset(ball, 2.0f, 2.0f);
    gloss.size.height *= 0.5f;
    CGContextAddEllipseInRect(ctx, gloss);
    CGContextClip(ctx);
    const CGFloat glossTop[4] = { 1.0f, 1.0f, 1.0f, 0.95f }, glossBottom[4] = { 1.0f, 1.0f, 1.0f, 0.25f };
    RewindNativeGradient(ctx, gloss, glossTop, glossBottom);
    CGContextRestoreGState(ctx);
    [[UIColor colorWithWhite:0.0f alpha:0.55f] setStroke];
    CGContextSetLineWidth(ctx, 1.0f);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(ball, 0.5f, 0.5f));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    thumb = [image retain];
    return thumb;
}

/* the seek bar wears the glossy ios 5 track and ball */
static void RewindNativeStyleSlider(UISlider *slider) {
    [slider setMinimumTrackImage:RewindNativeTrackImage(YES) forState:UIControlStateNormal];
    [slider setMaximumTrackImage:RewindNativeTrackImage(NO) forState:UIControlStateNormal];
    [slider setThumbImage:RewindNativeThumbImage() forState:UIControlStateNormal];
    [slider setThumbImage:RewindNativeThumbImage() forState:UIControlStateHighlighted];
}

#pragma mark - player

static UIImage *RewindNativeListGlyph(void) {
    CGFloat scale = [UIScreen mainScreen].scale;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(22.0f, 18.0f), NO, scale);
    [[UIColor whiteColor] setFill];
    for (int i = 0; i < 3; ++i) {
        UIRectFill(CGRectMake(0, 1.0f + i * 7.0f, 3.0f, 3.0f));
        UIRectFill(CGRectMake(6.0f, 1.0f + i * 7.0f, 16.0f, 3.0f));
    }
    UIImage *glyph = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return glyph;
}

static NSString *RewindNativeClock(NSTimeInterval seconds) {
    NSInteger total = (NSInteger)MAX(0.0, seconds);
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

@implementation RewindNativePlayerVC

- (id)initWithContext:(RewindNativeContext *)context {
    self = [super init];
    if (!self) return nil;
    _context = [context retain];
    _lyricsActive = -1;
    self.hidesBottomBarWhenPushed = YES;
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_timer invalidate];
    [_artistLabel release]; [_titleLabel release]; [_albumLabel release]; [_countLabel release];
    [_elapsedLabel release]; [_remainingLabel release];
    [_slider release];
    [_repeatButton release]; [_shuffleButton release];
    [_previousButton release]; [_playButton release]; [_nextButton release];
    _vinyl.scratchDelegate = nil;
    [_vinyl release]; [_panel release];
    [_playSpinner release];
    _lyricsTable.delegate = nil;
    _lyricsTable.dataSource = nil;
    [_likeButton release]; [_dislikeButton release]; [_menuTrack release]; [_lyricsPanel release]; [_lyricsTable release];
    [_lyricsHeader release]; [_lyricsThumb release]; [_lyricsHeading release];
    [_lyricsStatus release]; [_lyricsSpinner release];
    [_lyrics release]; [_lyricsError release]; [_lyricsVideoID release]; [_lyricHeights release];
    [_artworkURL release];
    [_context release];
    [super dealloc];
}

- (UILabel *)labelWithSize:(CGFloat)size bold:(BOOL)bold color:(UIColor *)color align:(NSTextAlignment)align {
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.textColor = color;
    label.textAlignment = align;
    label.font = RewindChromeFont(size, bold);
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (UIButton *)buttonWithIcon:(NSString *)icon points:(CGFloat)points action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setImage:RewindIcon(icon, points, [UIColor whiteColor]) forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
    return button;
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = [UIColor colorWithWhite:0.07f alpha:1.0f];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIColor *white = [UIColor whiteColor], *gray = [UIColor colorWithWhite:0.72f alpha:1.0f];
    _titleLabel = [[self labelWithSize:RewindIsPad() ? 24.0f : 20.0f bold:YES color:white align:NSTextAlignmentCenter] retain];
    _artistLabel = [[self labelWithSize:RewindIsPad() ? 17.0f : 15.0f bold:NO color:gray align:NSTextAlignmentCenter] retain];
    _albumLabel = [[self labelWithSize:12.0f bold:NO color:gray align:NSTextAlignmentCenter] retain];
    for (UILabel *label in [NSArray arrayWithObjects:_titleLabel, _artistLabel, nil]) {
        label.shadowColor = [UIColor blackColor];
        label.shadowOffset = CGSizeMake(0.0f, -1.0f);
        [self.view addSubview:label];
    }
    _countLabel = [[self labelWithSize:17.0f bold:YES color:white align:NSTextAlignmentCenter] retain];
    _countLabel.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.5f];
    _countLabel.shadowOffset = CGSizeMake(0.0f, -1.0f);
    _countLabel.frame = CGRectMake(0.0f, 0.0f, 160.0f, 44.0f);
    self.navigationItem.titleView = _countLabel;
    self.navigationItem.leftBarButtonItem = RewindBackBarItem(self, @selector(backPressed));
    self.navigationItem.rightBarButtonItem = RewindChromeBarItem(nil, RewindNativeListGlyph(), NO, self,
                                                                 @selector(morePressed));

    _elapsedLabel = [[self labelWithSize:13.0f bold:YES color:white align:NSTextAlignmentLeft] retain];
    _remainingLabel = [[self labelWithSize:13.0f bold:YES color:white align:NSTextAlignmentRight] retain];
    [self.view addSubview:_elapsedLabel];
    [self.view addSubview:_remainingLabel];
    _slider = [[UISlider alloc] initWithFrame:CGRectZero];
    [_slider addTarget:self action:@selector(sliderBegan) forControlEvents:UIControlEventTouchDown];
    [_slider addTarget:self action:@selector(sliderMoved) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self action:@selector(sliderEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    RewindNativeStyleSlider(_slider);
    [self.view addSubview:_slider];
    _repeatButton = [[self buttonWithIcon:@"repeat" points:24.0f action:@selector(repeatPressed)] retain];
    _shuffleButton = [[self buttonWithIcon:@"shuffle" points:24.0f action:@selector(shufflePressed)] retain];
    _likeButton = [[self buttonWithIcon:@"thumb-up" points:24.0f action:@selector(likePressed)] retain];
    _dislikeButton = [[self buttonWithIcon:@"thumb-down" points:24.0f action:@selector(dislikePressed)] retain];

    _vinyl = [[RewindVinylView alloc] initWithFrame:CGRectZero];
    _vinyl.scratchDelegate = self;
    [self.view addSubview:_vinyl];

    _lyricsPanel = [[UIView alloc] initWithFrame:CGRectZero];
    _lyricsPanel.hidden = YES;
    _lyricsPanel.layer.cornerRadius = 8.0f;
    _lyricsPanel.layer.masksToBounds = YES;
    _lyricsPanel.layer.borderWidth = 1.0f;
    _lyricsPanel.layer.borderColor = [UIColor colorWithWhite:0.0f alpha:0.9f].CGColor;
    CAGradientLayer *well = [CAGradientLayer layer];
    well.name = @"well";
    well.colors = [NSArray arrayWithObjects:(id)[UIColor colorWithWhite:0.02f alpha:1.0f].CGColor,
                   (id)[UIColor colorWithWhite:0.12f alpha:1.0f].CGColor, nil];
    [_lyricsPanel.layer addSublayer:well];
    _lyricsTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _lyricsTable.backgroundColor = [UIColor clearColor];
    _lyricsTable.separatorStyle = UITableViewCellSeparatorStyleNone;
    _lyricsTable.dataSource = self;
    _lyricsTable.delegate = self;
    _lyricsTable.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [_lyricsPanel addSubview:_lyricsTable];
    _lyricsStatus = [[self labelWithSize:15.0f bold:NO color:gray align:NSTextAlignmentCenter] retain];
    _lyricsStatus.numberOfLines = 0;
    [_lyricsPanel addSubview:_lyricsStatus];
    _lyricsSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _lyricsSpinner.hidesWhenStopped = YES;
    [_lyricsPanel addSubview:_lyricsSpinner];
    _lyricsHeader = [[UIView alloc] initWithFrame:CGRectZero];
    CAGradientLayer *strip = [CAGradientLayer layer];
    strip.name = @"strip";
    strip.colors = [NSArray arrayWithObjects:(id)[UIColor colorWithWhite:0.42f alpha:1.0f].CGColor,
                    (id)[UIColor colorWithWhite:0.24f alpha:1.0f].CGColor,
                    (id)[UIColor colorWithWhite:0.15f alpha:1.0f].CGColor,
                    (id)[UIColor colorWithWhite:0.20f alpha:1.0f].CGColor, nil];
    strip.locations = [NSArray arrayWithObjects:@0.0f, @0.5f, @0.5f, @1.0f, nil];
    [_lyricsHeader.layer addSublayer:strip];
    _lyricsThumb = [[UIImageView alloc] initWithFrame:CGRectZero];
    _lyricsThumb.contentMode = UIViewContentModeScaleAspectFill;
    _lyricsThumb.clipsToBounds = YES;
    _lyricsThumb.layer.borderWidth = 1.0f;
    _lyricsThumb.layer.borderColor = [UIColor blackColor].CGColor;
    [_lyricsHeader addSubview:_lyricsThumb];
    _lyricsHeading = [[self labelWithSize:15.0f bold:YES color:white align:NSTextAlignmentLeft] retain];
    _lyricsHeading.shadowColor = [UIColor blackColor];
    _lyricsHeading.shadowOffset = CGSizeMake(0.0f, -1.0f);
    [_lyricsHeader addSubview:_lyricsHeading];
    UIView *done = RewindChromeBarItem(RewindL(@"done"), nil, NO, self, @selector(toggleLyrics)).customView;
    done.tag = 41;
    [_lyricsHeader addSubview:done];
    [_lyricsPanel addSubview:_lyricsHeader];
    [self.view addSubview:_lyricsPanel];

    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    _panel.layer.cornerRadius = 10.0f;
    _panel.layer.masksToBounds = YES;
    CAGradientLayer *glass = [CAGradientLayer layer];
    glass.name = @"glass";
    glass.colors = [NSArray arrayWithObjects:(id)[UIColor colorWithWhite:0.50f alpha:1.0f].CGColor,
                    (id)[UIColor colorWithWhite:0.30f alpha:1.0f].CGColor,
                    (id)[UIColor colorWithWhite:0.20f alpha:1.0f].CGColor,
                    (id)[UIColor colorWithWhite:0.28f alpha:1.0f].CGColor, nil];
    glass.locations = [NSArray arrayWithObjects:@0.0f, @0.48f, @0.52f, @1.0f, nil];
    [_panel.layer addSublayer:glass];
    [self.view addSubview:_panel];
    _previousButton = [[self buttonWithIcon:@"prev" points:36.0f action:@selector(previousPressed)] retain];
    _playButton = [[self buttonWithIcon:@"play" points:44.0f action:@selector(playPressed)] retain];
    _nextButton = [[self buttonWithIcon:@"next" points:36.0f action:@selector(nextPressed)] retain];
    /* repeat and shuffle were made before the slab, which would cover them */
    [self.view bringSubviewToFront:_repeatButton];
    [self.view bringSubviewToFront:_shuffleButton];
    _playSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _playSpinner.hidesWhenStopped = YES;
    _playSpinner.userInteractionEnabled = NO;
    [self.view addSubview:_playSpinner];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh:)
                                                 name:RewindPlayerDidChangeNotification object:_context->player];
    [self refresh:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    RewindStyleNavigationBar(self.navigationController.navigationBar);
    if (!_timer)
        _timer = [[NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(tick:)
                                                 userInfo:nil repeats:YES] retain];
    [self refresh:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_timer invalidate];
    [_timer release];
    _timer = nil;
    /* the other screens of the stack draw the steel bar again */
    RewindStyleNavigationBar(self.navigationController.navigationBar);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat fullW = self.view.bounds.size.width, fullH = self.view.bounds.size.height;
    CGFloat panelH = 64.0f, key = 44.0f, seekH = 34.0f;
    CGFloat titleH = RewindIsPad() ? 30.0f : 25.0f, artistH = RewindIsPad() ? 22.0f : 19.0f;
    CGFloat above = 8.0f;
    CGFloat below = 8.0f + titleH + artistH + 8.0f + seekH + 18.0f + panelH + 10.0f;
    CGFloat discMax = RewindIsPad() ? 480.0f : fullW - 40.0f;
    CGFloat side = MAX(100.0f, MIN(discMax, fullH - above - below));
    CGFloat column = above + side + below;
    CGFloat top = fullH > column ? floorf((fullH - column) * 0.5f) : 0.0f;
    CGFloat left = floorf((fullW - side) * 0.5f);
    CGFloat y = top + above;
    CGFloat discTop = y;
    /* setting frame on the rotated disc changes its size during scratching */
    _vinyl.bounds = CGRectMake(0.0f, 0.0f, side, side);
    _vinyl.center = CGPointMake(left + side * 0.5f, y + side * 0.5f);
    y += side + 8.0f;
    /* the names, the track and the transport keys use the width of the screen; the record is limited by height */
    CGFloat rowW = RewindIsPad() ? MIN(fullW - 48.0f, 560.0f) : fullW - 24.0f, rowLeft = floorf((fullW - rowW) * 0.5f);
    /* the thumbs flank the two name lines: like on the left, dislike on the right */
    CGFloat thumbY = y + floorf((titleH + artistH - key) * 0.5f);
    _likeButton.frame = CGRectMake(rowLeft, thumbY, key, key);
    _dislikeButton.frame = CGRectMake(rowLeft + rowW - key, thumbY, key, key);
    CGFloat nameX = rowLeft + key + 4.0f, nameW = rowW - (key + 4.0f) * 2.0f;
    _titleLabel.frame = CGRectMake(nameX, y, nameW, titleH);
    y += titleH;
    _artistLabel.frame = CGRectMake(nameX, y, nameW, artistH);
    y += artistH + 8.0f;
    CGFloat seekTop = y;
    /* the track is as long as the three transport keys, the times sit under its ends */
    _slider.frame = CGRectMake(rowLeft, y, rowW, seekH);
    _elapsedLabel.frame = CGRectMake(rowLeft, y + seekH - 2.0f, 60.0f, 16.0f);
    _remainingLabel.frame = CGRectMake(rowLeft + rowW - 60.0f, y + seekH - 2.0f, 60.0f, 16.0f);
    y += seekH + 18.0f;
    _panel.frame = CGRectMake(rowLeft, y, rowW, panelH);
    /* the lyrics drawer covers the record and the names, down to the seek bar */
    CGRect sheet = CGRectMake(left, discTop, side, MAX(120.0f, seekTop - 6.0f - discTop));
    for (CALayer *layer in _panel.layer.sublayers)
        if ([layer.name isEqualToString:@"glass"]) layer.frame = _panel.bounds;
    /* shuffle and repeat sit at the ends of the same slab as the three transport keys */
    CGFloat endW = 56.0f, third = (_panel.bounds.size.width - endW * 2.0f) / 3.0f, panelTop = _panel.frame.origin.y;
    CGFloat panelX = _panel.frame.origin.x;
    _shuffleButton.frame = CGRectMake(panelX, panelTop, endW, panelH);
    _previousButton.frame = CGRectMake(panelX + endW, panelTop, third, panelH);
    _playButton.frame = CGRectMake(panelX + endW + third, panelTop, third, panelH);
    _nextButton.frame = CGRectMake(panelX + endW + third * 2.0f, panelTop, third, panelH);
    _repeatButton.frame = CGRectMake(panelX + endW + third * 3.0f, panelTop, endW, panelH);
    _playSpinner.center = _playButton.center;
    CGFloat sheetH = sheet.size.height;
    if (!_showingLyrics) sheet.origin.y = fullH;
    _lyricsPanel.frame = sheet;
    CGFloat headerH = 48.0f;
    _lyricsHeader.frame = CGRectMake(0.0f, 0.0f, _lyricsPanel.bounds.size.width, headerH);
    for (CALayer *layer in _lyricsHeader.layer.sublayers)
        if ([layer.name isEqualToString:@"strip"]) layer.frame = _lyricsHeader.bounds;
    _lyricsThumb.frame = CGRectMake(8.0f, 6.0f, headerH - 12.0f, headerH - 12.0f);
    UIView *done = [_lyricsHeader viewWithTag:41];
    done.frame = CGRectMake(_lyricsHeader.bounds.size.width - done.bounds.size.width - 8.0f,
                            floorf((headerH - done.bounds.size.height) * 0.5f), done.bounds.size.width, done.bounds.size.height);
    CGFloat headingX = CGRectGetMaxX(_lyricsThumb.frame) + 10.0f;
    _lyricsHeading.frame = CGRectMake(headingX, 0.0f, MAX(20.0f, done.frame.origin.x - headingX - 8.0f), headerH);
    CGRect well = CGRectMake(0.0f, headerH, _lyricsPanel.bounds.size.width, sheetH - headerH);
    for (CALayer *layer in _lyricsPanel.layer.sublayers)
        if ([layer.name isEqualToString:@"well"]) layer.frame = well;
    _lyricsTable.frame = well;
    _lyricsStatus.frame = CGRectMake(16.0f, headerH + floorf(well.size.height * 0.5f) - 10.0f, well.size.width - 32.0f, 60.0f);
    _lyricsSpinner.center = CGPointMake(floorf(well.size.width * 0.5f), headerH + floorf(well.size.height * 0.5f) - 24.0f);
    if (fabsf((float)(_lyricsWidth - well.size.width)) > 0.5f) {
        _lyricsWidth = well.size.width;
        [self measureLyrics];
        [_lyricsTable reloadData];
    }
}

#pragma mark lyrics

- (UIFont *)lyricFont {
    return RewindChromeFont(18.0f, YES);
}

- (void)measureLyrics {
    NSMutableArray *heights = [NSMutableArray array];
    NSUInteger count = MIN((NSUInteger)500, _lyrics.lines.count);
    CGFloat width = MAX(40.0f, _lyricsWidth - 40.0f);
    for (NSUInteger index = 0; index < count; ++index) {
        NSString *text = [(RewindLyricLine *)[_lyrics.lines objectAtIndex:index] text];
        [heights addObject:[NSNumber numberWithFloat:(float)MAX(28.0f, RewindTextSize(text, [self lyricFont], width).height + 12.0f)]];
    }
    [_lyricHeights release];
    _lyricHeights = [heights copy];
}

- (void)applyLyricsState {
    BOOL hasLines = _lyrics.lines.count > 0;
    _lyricsTable.hidden = !hasLines;
    _lyricsStatus.hidden = hasLines;
    if (!hasLines)
        _lyricsStatus.text = _lyricsLoading ? @"" : (_lyricsError ? RewindFriendlyError(_lyricsError) : RewindL(@"lyrics_none"));
    if (_lyricsLoading && !hasLines && _showingLyrics) [_lyricsSpinner startAnimating];
    else [_lyricsSpinner stopAnimating];
}

- (void)loadLyrics {
    RewindTrack *track = _context->player.track;
    if (!track) return;
    NSUInteger request = ++_lyricsRequest;
    _lyricsAttempted = YES;
    _lyricsLoading = YES;
    [_lyricsError release]; _lyricsError = nil;
    [self applyLyricsState];
    [_context->api lyricsForTrack:track completion:^(RewindLyrics *lyrics, NSError *error) {
        if (request != _lyricsRequest) return;
        _lyricsLoading = NO;
        [_lyricsError release]; _lyricsError = [error retain];
        [_lyrics release]; _lyrics = [lyrics retain];
        _lyricsActive = -1;
        [self measureLyrics];
        [_lyricsTable reloadData];
        [self applyLyricsState];
        [self highlightLyric];
    }];
}

/* discard old lyrics before a pending response can reach the new track */
- (void)resetLyrics {
    ++_lyricsRequest;
    _lyricsAttempted = NO;
    _lyricsLoading = NO;
    [_lyrics release]; _lyrics = nil;
    [_lyricsError release]; _lyricsError = nil;
    [_lyricHeights release]; _lyricHeights = nil;
    _lyricsActive = -1;
    [_lyricsTable reloadData];
    [self applyLyricsState];
    /* the lookup is a chain of large responses parsed on the main thread, so it runs only for open lyrics */
    if (_showingLyrics && _context->player.track) [self loadLyrics];
}

/* a track without lyrics answers the menu item with a toast; a failed lookup is retried by choosing it again */
- (BOOL)lyricsMissing {
    return _lyricsAttempted && !_lyricsLoading &&
        (_lyrics ? !_lyrics.lines.count : RewindLyricsMissing(_lyricsError));
}

- (void)toggleLyrics {
    if (!_showingLyrics && [self lyricsMissing]) {
        RewindShowToast(self.view, RewindL(@"lyrics_none"), 24.0f);
        return;
    }
    _showingLyrics = !_showingLyrics;
    _lyricsPanel.hidden = NO;
    BOOL showing = _showingLyrics;
    [UIView animateWithDuration:0.3 animations:^{
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    } completion:^(BOOL finished) {
        (void)finished;
        if (!_showingLyrics && !showing) _lyricsPanel.hidden = YES;
    }];
    if (_showingLyrics && _lyricsError && !_lyricsLoading) _lyricsAttempted = NO;
    if (_showingLyrics && !_lyricsAttempted) [self loadLyrics];
    else [self applyLyricsState];
    _lyricsUserScrolling = NO;
    _lyricsActive = -1;
    [self highlightLyric];
}

- (void)styleLyricCell:(UITableViewCell *)cell row:(NSInteger)row {
    BOOL timed = _lyrics.timed;
    BOOL active = timed && row == _lyricsActive;
    cell.textLabel.textColor = !timed || active ? (active ? RewindColorLink() : [UIColor whiteColor])
                                                : [UIColor colorWithWhite:1.0f alpha:0.45f];
}

- (void)highlightLyric {
    if (!_showingLyrics || !_lyrics.timed || !_lyrics.lines.count) return;
    NSUInteger milliseconds = (NSUInteger)MAX(0.0, _context->player.currentTime * 1000.0);
    NSInteger active = -1;
    NSUInteger count = MIN((NSUInteger)500, _lyrics.lines.count);
    for (NSUInteger index = 0; index < count; ++index) {
        if ([(RewindLyricLine *)[_lyrics.lines objectAtIndex:index] startMS] > milliseconds) break;
        active = (NSInteger)index;
    }
    if (active == _lyricsActive) return;
    _lyricsActive = active;
    for (UITableViewCell *cell in _lyricsTable.visibleCells)
        [self styleLyricCell:cell row:[_lyricsTable indexPathForCell:cell].row];
    if (active >= 0 && !_lyricsUserScrolling)
        [_lyricsTable scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:active inSection:0]
                            atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)_lyricHeights.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    return (CGFloat)[[_lyricHeights objectAtIndex:(NSUInteger)indexPath.row] floatValue];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"native-lyric";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse] autorelease];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [self lyricFont];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.backgroundColor = [UIColor clearColor];
        /* the embossed text of ios 5 lists */
        cell.textLabel.shadowColor = [UIColor blackColor];
        cell.textLabel.shadowOffset = CGSizeMake(0.0f, -1.0f);
    }
    cell.textLabel.text = [(RewindLyricLine *)[_lyrics.lines objectAtIndex:(NSUInteger)indexPath.row] text];
    [self styleLyricCell:cell row:indexPath.row];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    NSTimeInterval duration = _context->player.duration;
    if (!_lyrics.timed || duration <= 0.0) return;
    RewindLyricLine *line = [_lyrics.lines objectAtIndex:(NSUInteger)indexPath.row];
    /* seek 50 ms past the stamp so 1/600 s rounding keeps the tapped line active */
    [_context->player seekToTime:line.startMS / 1000.0 + 0.05];
    _lyricsUserScrolling = NO;
    [self highlightLyric];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    (void)scrollView;
    _lyricsUserScrolling = YES;
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    (void)scrollView;
    if (!decelerate) _lyricsUserScrolling = NO;
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    (void)scrollView;
    _lyricsUserScrolling = NO;
}

#pragma mark menu

- (void)morePressed {
    RewindTrack *track = _context->player.track;
    if (!track) return;
    [_menuTrack release];
    _menuTrack = [track retain];
    __block RewindNativePlayerVC *owner = self;
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
        [RewindSheetItem itemWithIcon:@"queue-add" title:RewindL(@"player_next")
                                action:^{ [owner performMenuAction:RewindPlayerMenuActionUpNext]; }],
        [RewindSheetItem itemWithIcon:@"note" title:RewindL(@"player_lyrics")
                                action:^{ [owner performMenuAction:RewindPlayerMenuActionLyrics]; }],
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
    RewindPlayer *player = _context->player;
    RewindAPI *api = _context->api;
    if (!track) return;
    switch (action) {
        case RewindPlayerMenuActionPlayNext:
            [player enqueueTrack:track usingAPI:api afterCurrent:YES];
            RewindShowToast(self.view, RewindL(@"menu_play_next_added"), 24.0f);
            break;
        case RewindPlayerMenuActionPlaylist: [self showPlaylistPicker]; break;
        case RewindPlayerMenuActionShare: [self shareTrack:track]; break;
        case RewindPlayerMenuActionUpNext: [self queuePressed]; break;
        case RewindPlayerMenuActionLyrics: if (!_showingLyrics) [self toggleLyrics]; break;
        case RewindPlayerMenuActionMix: [self startMix:track]; break;
        case RewindPlayerMenuActionQueue:
            [player enqueueTrack:track usingAPI:api afterCurrent:NO];
            RewindShowToast(self.view, RewindL(@"menu_queued"), 24.0f);
            break;
        case RewindPlayerMenuActionLibrary: {
            BOOL saved = RewindTrackIsSaved(track);
            if (saved) RewindRemoveTrack(track);
            else RewindSaveTrack(track);
            RewindShowToast(self.view, RewindL(saved ? @"removed_library" : @"added_library"), 24.0f);
            break;
        }
        case RewindPlayerMenuActionDownload:
            RewindShowToast(self.view, RewindL(@"menu_download_started"), 24.0f);
            RewindDownloadTrack(track, api, ^(NSError *error) {
                RewindShowToast(self.view, error ? RewindFriendlyError(error) : RewindL(@"menu_download_done"), 24.0f);
            });
            break;
        case RewindPlayerMenuActionAlbum: RewindPushAlbum(self, track, api, player); break;
        case RewindPlayerMenuActionArtist: RewindPushArtistProfile(self, track, api, player); break;
        case RewindPlayerMenuActionClearQueue:
            [player clearQueue];
            RewindShowToast(self.view, RewindL(@"menu_queue_cleared"), 24.0f);
            break;
        case RewindPlayerMenuActionSpeed: [self showSpeedPicker]; break;
        case RewindPlayerMenuActionSleep: [self showSleepPicker]; break;
        default: break;
    }
}

- (void)startMix:(RewindTrack *)track {
    RewindPlayer *player = _context->player;
    RewindAPI *api = _context->api;
    [player setContinuousPlayback:YES];
    if (RewindAccountIsSignedIn()) {
        RewindAccountLoadMix(track, ^(NSArray *tracks, NSError *error) {
            if (error || !tracks.count) {
                RewindShowToast(self.view, RewindFriendlyError(error) ?: RewindL(@"account_mix_failed"), 24.0f);
                return;
            }
            if (player.track && [[[tracks objectAtIndex:0] videoID] isEqualToString:player.track.videoID]) {
                for (NSInteger index = (NSInteger)tracks.count - 1; index >= 1; --index)
                    [player enqueueTrack:[tracks objectAtIndex:(NSUInteger)index] usingAPI:api afterCurrent:YES];
            } else [player setQueue:tracks selectedIndex:0 usingAPI:api];
        });
        return;
    }
    [api relatedForTrack:track completion:^(NSArray *shelves, NSArray *links, NSError *error) {
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
            RewindShowToast(self.view, RewindFriendlyError(error) ?: RewindL(@"account_mix_failed"), 24.0f);
            return;
        }
        [player setQueue:tracks selectedIndex:0 usingAPI:api];
    }];
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
        RewindShowToast(self.view, RewindL(@"menu_share_copied"), 24.0f);
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
                RewindShowToast(self.view, error ? RewindFriendlyError(error) : RewindL(@"added_to_playlist"), 24.0f);
            });
        }
    } else if (alert.tag == 9302) {
        NSString *name = [[[alert textFieldAtIndex:0] text]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!name.length) return;
        RewindCreatePlaylistWithTrack(name, _menuTrack, ^(NSError *error) {
            RewindShowToast(self.view, error ? error.localizedDescription : RewindL(@"added_to_playlist"), 24.0f);
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
        if (index >= 0 && index < 4) [_context->player setPlaybackRate:rates[index]];
    } else if (sheet.tag == 9402) {
        static const NSTimeInterval times[] = {0, 900, 1800, 3600};
        if (index >= 0 && index < 4) {
            if (index == 0) [_context->player cancelSleepTimer];
            else [_context->player setSleepTimer:times[index]];
        }
    }
}

- (void)backPressed {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)queuePressed {
    RewindNativeQueueVC *queue = [[[RewindNativeQueueVC alloc] initWithContext:_context] autorelease];
    [self.navigationController pushViewController:queue animated:YES];
}

- (void)repeatPressed { [_context->player setRepeating:!_context->player.repeating]; }
- (void)shufflePressed { [_context->player setShuffling:!_context->player.shuffling]; }
- (void)previousPressed { [_context->player previousTrack]; }
- (void)nextPressed { [_context->player nextTrack]; }
- (void)playPressed { [_context->player toggle]; }

- (void)sliderBegan { _dragging = YES; }

- (void)sliderMoved {
    _elapsedLabel.text = RewindNativeClock(_slider.value * _context->player.duration);
    _remainingLabel.text = [@"-" stringByAppendingString:
                            RewindNativeClock((1.0f - _slider.value) * _context->player.duration)];
}

- (void)sliderEnded {
    [_context->player seekToProgress:_slider.value];
    _dragging = NO;
}

- (void)tick:(NSTimer *)timer {
    (void)timer;
    if (_dragging) return;
    NSTimeInterval duration = _context->player.duration, current = _context->player.currentTime;
    _slider.value = duration > 0.0 ? (float)MIN(1.0, current / duration) : 0.0f;
    _elapsedLabel.text = RewindNativeClock(current);
    _remainingLabel.text = [@"-" stringByAppendingString:RewindNativeClock(MAX(0.0, duration - current))];
    [self highlightLyric];
}

- (void)refresh:(NSNotification *)note {
    NSError *error = [[note userInfo] objectForKey:@"error"];
    if (error) RewindShowToast(self.view, RewindFriendlyError(error), 90.0f);
    RewindPlayer *player = _context->player;
    RewindTrack *track = player.track;
    _titleLabel.text = track.title ?: RewindL(@"nothing_playing");
    _lyricsHeading.text = track.title;
    _artistLabel.text = track ? RewindTrackArtistText(track) : @"";
    _albumLabel.text = track.album;
    NSUInteger count = player.queue.count;
    _countLabel.text = count ? [NSString stringWithFormat:RewindL(@"native_track_of"),
                                (unsigned long)(player.queueIndex + 1), (unsigned long)count] : RewindL(@"playing_now");
    /* while the stream is prepared the spinner takes the glyph's place; the key under it keeps answering */
    [_playButton setImage:player.loading ? nil : RewindIcon(player.playing ? @"pause" : @"play", 44.0f, [UIColor whiteColor])
                 forState:UIControlStateNormal];
    UIColor *on = RewindColorLink();
    [_repeatButton setImage:RewindIcon(player.repeating ? @"repeat-one" : @"repeat", 24.0f,
                                       player.repeating ? on : [UIColor whiteColor]) forState:UIControlStateNormal];
    [_shuffleButton setImage:RewindIcon(@"shuffle", 24.0f, player.shuffling ? on : [UIColor whiteColor])
                    forState:UIControlStateNormal];
    BOOL liked = track && (RewindAccountIsSignedIn() ? RewindAccountTrackIsLiked(track) : RewindTrackIsSaved(track));
    BOOL disliked = track && RewindAccountTrackIsDisliked(track);
    [_likeButton setImage:RewindIcon(liked ? @"thumb-up-on" : @"thumb-up", 24.0f, liked ? on : [UIColor whiteColor])
                 forState:UIControlStateNormal];
    [_dislikeButton setImage:RewindIcon(disliked ? @"thumb-down-on" : @"thumb-down", 24.0f,
                                        disliked ? on : [UIColor whiteColor]) forState:UIControlStateNormal];
    NSString *url = track.thumbnailURL;
    if (![url isEqualToString:_artworkURL ?: @""]) {
        [_artworkURL release];
        _artworkURL = [url copy];
        [_vinyl setURL:url];
        _lyricsThumb.image = nil;
        if (url.length) {
            NSString *expected = [[url copy] autorelease];
            [self retain];
            RewindLoadImageSized(expected, 80.0f, ^(UIImage *image) {
                if (image && [_artworkURL isEqualToString:expected]) _lyricsThumb.image = image;
                [self release];
            });
        }
    }
    [_vinyl setPlaying:player.playing];
    if (player.loading) [_playSpinner startAnimating];
    else [_playSpinner stopAnimating];
    if (![(track.videoID ?: @"") isEqualToString:_lyricsVideoID ?: @""]) {
        [_lyricsVideoID release];
        _lyricsVideoID = [track.videoID copy];
        [self resetLyrics];
    }
    [self tick:nil];
}

- (void)likePressed {
    RewindTrack *track = _context->player.track;
    if (!track) return;
    if (!RewindAccountIsSignedIn()) {
        /* signed out, the thumb keeps the local library, the only place a like can go */
        if (RewindTrackIsSaved(track)) RewindRemoveTrack(track);
        else RewindSaveTrack(track);
        [self refresh:nil];
        return;
    }
    RewindAccountSetLiked(track, !RewindAccountTrackIsLiked(track), ^(NSError *error) {
        if (error) RewindShowToast(self.view, RewindFriendlyError(error), 24.0f);
        [self refresh:nil];
    });
}

- (void)dislikePressed {
    RewindTrack *track = _context->player.track;
    if (!track) return;
    if (!RewindAccountIsSignedIn()) {
        RewindShowToast(self.view, RewindL(@"dislike_sign_in"), 24.0f);
        return;
    }
    BOOL disliked = !RewindAccountTrackIsDisliked(track);
    RewindAccountSetDisliked(track, disliked, ^(NSError *error) {
        if (error) RewindShowToast(self.view, RewindFriendlyError(error), 24.0f);
        else if (disliked) RewindShowToast(self.view, RewindL(@"dislike_done"), 24.0f);
        [self refresh:nil];
    });
}

- (void)vinylScratchBegan {
    _dragging = YES;
    [_context->player beginScratch];
}

- (void)vinylScratchedByRadians:(CGFloat)radians interval:(NSTimeInterval)interval {
    /* a scratch that crosses the end of a track loses its hold when the next track replaces the player, and
       the finger is still down; take the new track over on the next move, begin waits for its player */
    if (!_context->player.scratching) [_context->player beginScratch];
    [_context->player scratchByTime:radians / (CGFloat)(M_PI * 2.0) * 1.8 interval:interval];
    /* the slider and the clock follow the finger, a full refresh per touch would be too heavy */
    NSTimeInterval duration = _context->player.duration, current = _context->player.currentTime;
    _slider.value = duration > 0.0 ? (float)MIN(1.0, current / duration) : 0.0f;
    _elapsedLabel.text = RewindNativeClock(current);
    _remainingLabel.text = [@"-" stringByAppendingString:RewindNativeClock(MAX(0.0, duration - current))];
}

- (void)vinylScratchEnded {
    [_context->player endScratch];
    _dragging = NO;
}

@end

@implementation RewindNativeQueueVC

- (id)initWithContext:(RewindNativeContext *)context {
    self = [super initWithStyle:UITableViewStylePlain];
    if (!self) return nil;
    _context = [context retain];
    self.title = RewindL(@"player_next");
    return self;
}

- (void)dealloc {
    [_context release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem = RewindBackBarItem(self, @selector(backPressed));
    RewindNativeStyleTable(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    RewindStyleNavigationBar(self.navigationController.navigationBar);
}

- (void)backPressed {
    [self.navigationController popViewControllerAnimated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)_context->player.queue.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"native-queue";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse] autorelease];
        RewindNativeStyleCell(cell);
    }
    RewindTrack *track = [_context->player.queue objectAtIndex:(NSUInteger)indexPath.row];
    cell.textLabel.text = track.title;
    cell.detailTextLabel.text = RewindTrackArtistText(track);
    cell.accessoryView = indexPath.row == _context->player.queueIndex ? RewindChromeCheckmark() : nil;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [_context->player playQueueIndex:indexPath.row];
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - account

@interface RewindNativeAccountVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate> {
    UITableView *_table;
    NSUInteger _profileRequest;
    UIImage *_photo;
}
@end

@implementation RewindNativeAccountVC

- (id)init {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    self.title = RewindL(@"about_account");
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(accountChanged:)
                                                 name:RewindAccountDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    ++_profileRequest;
    _table.delegate = nil;
    _table.dataSource = nil;
    [_table release];
    [_photo release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]] autorelease];
    view.backgroundColor = RewindChromeGroupedBackground();
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    _table.backgroundView = nil;
    _table.backgroundColor = [UIColor clearColor];
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];
}

/* ios 7 and later run grouped rows to the edge; pulling the table in keeps them as rounded groups */
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _table.frame = CGRectInset(self.view.bounds, RewindChromeGroupedMargin(), 0.0f);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadProfile];
    if (!RewindAccountIsSignedIn()) return;
    NSUInteger request = ++_profileRequest;
    RewindAccountRefreshProfile(^(NSError *error) {
        if (request != _profileRequest) return;
        if (error) NSLog(@"rewind: account profile refresh failed: %@", error);
        [self reloadProfile];
    });
}

- (void)accountChanged:(NSNotification *)note {
    (void)note;
    [self reloadProfile];
}

- (void)reloadProfile {
    NSString *url = RewindAccountIsSignedIn() ? RewindAccountPhotoURL() : nil;
    if (!url.length) {
        [_photo release];
        _photo = nil;
    } else {
        NSString *expected = [[url copy] autorelease];
        RewindLoadImageSized(expected, 100.0f, ^(UIImage *image) {
            if (!image || ![RewindAccountPhotoURL() isEqualToString:expected]) return;
            [_photo release];
            _photo = [RewindNativeThumb(image, 50.0f) retain];
            [_table reloadData];
        });
    }
    [_table reloadData];
}

- (NSArray *)actionTitles {
    return RewindAccountIsSignedIn()
        ? [NSArray arrayWithObjects:RewindL(@"account_switch"), RewindL(@"account_manage"), nil]
        : [NSArray arrayWithObject:RewindL(@"account_sign_in_google")];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return RewindAccountIsSignedIn() ? 3 : 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 1 ? (NSInteger)[self actionTitles].count : 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    return indexPath.section == 0 ? 72.0f : 44.0f;
}

- (NSString *)footerForSection:(NSInteger)section {
    return section == 1 && !RewindAccountIsSignedIn() ? RewindL(@"account_sign_in_detail") : nil;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return RewindChromeGroupedFooter([self footerForSection:section], tableView.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return RewindChromeGroupedFooterHeight([self footerForSection:section], tableView.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 20.0f : 10.0f;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)section;
    return [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, tableView.bounds.size.width, 10.0f)] autorelease];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *reuse = indexPath.section == 0 ? @"account-profile" : @"account-row";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell)
        cell = [[[UITableViewCell alloc] initWithStyle:indexPath.section == 0 ? UITableViewCellStyleSubtitle
                                                                             : UITableViewCellStyleDefault
                                       reuseIdentifier:reuse] autorelease];
    NSInteger rows = [self tableView:tableView numberOfRowsInSection:indexPath.section];
    RewindChromeStyleGroupedCell(cell, indexPath.row == 0, indexPath.row == rows - 1);
    cell.accessoryView = nil;
    cell.textLabel.textAlignment = NSTextAlignmentLeft;
    if (indexPath.section == 0) {
        BOOL signedIn = RewindAccountIsSignedIn();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = RewindChromeFont(18.0f, YES);
        cell.textLabel.text = signedIn ? (RewindAccountName() ?: RewindL(@"account_signed_in"))
                                       : RewindL(@"account_signed_out");
        cell.detailTextLabel.font = RewindChromeFont(14.0f, NO);
        cell.detailTextLabel.textColor = RewindChromeGroupedCaptionColor();
        cell.detailTextLabel.text = signedIn ? RewindAccountEmail() : RewindL(@"account_youtube");
        cell.imageView.image = _photo ?: RewindIcon(@"avatar", 50.0f, [UIColor grayColor]);
        cell.imageView.layer.cornerRadius = 6.0f;
        cell.imageView.layer.masksToBounds = YES;
        return cell;
    }
    cell.imageView.image = nil;
    if (indexPath.section == 2) {
        /* the red centred title ios 5 gives a destructive row */
        cell.textLabel.text = RewindL(@"account_sign_out");
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor colorWithRed:0.75f green:0.10f blue:0.08f alpha:1.0f];
        return cell;
    }
    cell.textLabel.text = [[self actionTitles] objectAtIndex:(NSUInteger)indexPath.row];
    cell.accessoryView = RewindChromeDisclosure();
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    /* the cell sizes its background through the layer, which skips the redraw the segment needs */
    cell.backgroundView.frame = cell.bounds;
    cell.selectedBackgroundView.frame = cell.bounds;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2) {
        UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:RewindL(@"account_sign_out") message:nil delegate:self
                                               cancelButtonTitle:RewindL(@"cancel")
                                               otherButtonTitles:RewindL(@"account_sign_out"), nil] autorelease];
        [alert show];
        return;
    }
    if (indexPath.section != 1) return;
    if (RewindAccountIsSignedIn() && indexPath.row == 1) {
        NSURL *url = [NSURL URLWithString:@"https://myaccount.google.com/"];
        if (url) [[UIApplication sharedApplication] openURL:url];
        return;
    }
    [self.navigationController pushViewController:[[[RewindAccountLoginVC alloc] init] autorelease] animated:YES];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == alertView.cancelButtonIndex) return;
    RewindAccountSignOut();
}

@end

#pragma mark - mini player

@interface RewindNativeMiniPlayer : UIControl {
    RewindNativeContext *_context;
    RewindChromeTabsController *_tabs;
    UIImageView *_art;
    UILabel *_title, *_artist;
    UIButton *_play;
    UIActivityIndicatorView *_spinner;
    NSString *_artURL;
}
- (id)initWithContext:(RewindNativeContext *)context tabs:(RewindChromeTabsController *)tabs;
@end

@implementation RewindNativeMiniPlayer

- (id)initWithContext:(RewindNativeContext *)context tabs:(RewindChromeTabsController *)tabs {
    self = [super initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 46.0f)];
    if (!self) return nil;
    _context = [context retain];
    /* the tabs own this strip, so it only borrows them */
    _tabs = tabs;
    self.contentMode = UIViewContentModeRedraw;
    _art = [[UIImageView alloc] initWithFrame:CGRectZero];
    _art.contentMode = UIViewContentModeScaleAspectFill;
    _art.clipsToBounds = YES;
    _art.backgroundColor = RewindColorPlaceholder();
    _art.layer.borderWidth = 1.0f;
    _art.layer.borderColor = [UIColor blackColor].CGColor;
    [self addSubview:_art];
    _title = [[UILabel alloc] initWithFrame:CGRectZero];
    _title.font = RewindChromeFont(14.0f, YES);
    _title.textColor = [UIColor whiteColor];
    _artist = [[UILabel alloc] initWithFrame:CGRectZero];
    _artist.font = RewindChromeFont(12.0f, NO);
    _artist.textColor = [UIColor colorWithWhite:0.7f alpha:1.0f];
    for (UILabel *label in [NSArray arrayWithObjects:_title, _artist, nil]) {
        label.backgroundColor = [UIColor clearColor];
        label.shadowColor = [UIColor blackColor];
        label.shadowOffset = CGSizeMake(0.0f, -1.0f);
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.userInteractionEnabled = NO;
        [self addSubview:label];
    }
    _play = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _play.showsTouchWhenHighlighted = YES;
    [_play addTarget:self action:@selector(playPressed) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_play];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _spinner.hidesWhenStopped = YES;
    _spinner.userInteractionEnabled = NO;
    [self addSubview:_spinner];
    [self addTarget:self action:@selector(openPressed) forControlEvents:UIControlEventTouchUpInside];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerChanged:)
                                                 name:RewindPlayerDidChangeNotification object:context->player];
    [self playerChanged:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_art release]; [_title release]; [_artist release]; [_play release]; [_spinner release];
    [_artURL release];
    [_context release];
    [super dealloc];
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGRect bounds = self.bounds;
    const CGFloat top[4] = { 0.27f, 0.27f, 0.28f, 1.0f }, bottom[4] = { 0.10f, 0.10f, 0.11f, 1.0f };
    RewindNativeGradient(UIGraphicsGetCurrentContext(), bounds, top, bottom);
    [[UIColor blackColor] setFill];
    UIRectFill(CGRectMake(0.0f, 0.0f, bounds.size.width, 1.0f));
    [[UIColor colorWithWhite:1.0f alpha:0.15f] setFill];
    UIRectFill(CGRectMake(0.0f, 1.0f, bounds.size.width, 1.0f));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    CGFloat art = height - 10.0f;
    _art.frame = CGRectMake(6.0f, 5.0f, art, art);
    _play.frame = CGRectMake(width - 50.0f, 0.0f, 50.0f, height);
    _spinner.center = _play.center;
    CGFloat x = CGRectGetMaxX(_art.frame) + 10.0f, w = MAX(20.0f, width - x - 56.0f);
    _title.frame = CGRectMake(x, floorf(height * 0.5f) - 17.0f, w, 18.0f);
    _artist.frame = CGRectMake(x, floorf(height * 0.5f) + 1.0f, w, 16.0f);
}

- (void)playerChanged:(NSNotification *)note {
    (void)note;
    RewindPlayer *player = _context->player;
    RewindTrack *track = player.track;
    [_tabs setAccessoryShown:track != nil animated:YES];
    if (!track) return;
    _title.text = track.title;
    _artist.text = RewindTrackArtistText(track);
    /* while the stream is prepared the key turns into a spinner, so a tapped song visibly starts loading */
    if (player.loading) {
        [_spinner startAnimating];
        _play.hidden = YES;
    } else {
        [_spinner stopAnimating];
        _play.hidden = NO;
        [_play setImage:RewindIcon(player.playing ? @"pause" : @"play", 26.0f, [UIColor whiteColor])
               forState:UIControlStateNormal];
    }
    NSString *url = track.thumbnailURL;
    if ([url isEqualToString:_artURL]) return;
    [_artURL release];
    _artURL = [url copy];
    _art.image = nil;
    if (!url.length) return;
    NSString *expected = [[url copy] autorelease];
    [self retain];
    RewindLoadImageSized(expected, 100.0f, ^(UIImage *image) {
        if (image && [_artURL isEqualToString:expected]) _art.image = image;
        [self release];
    });
}

- (void)playPressed {
    [_context->player toggle];
}

/* detach the player observer when the borrowed tab controller goes away */
- (void)willMoveToSuperview:(UIView *)superview {
    [super willMoveToSuperview:superview];
    if (superview) return;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _tabs = nil;
}

- (void)openPressed {
    UINavigationController *navigation = [_tabs selectedNavigation];
    if (navigation) RewindNativePushPlayer(navigation, _context);
}

@end

#pragma mark - root

/* the account home when signed in, the public one otherwise */
static void RewindNativeLoadHome(RewindAPI *api, void (^done)(NSArray *shelves, NSError *error)) {
    void (^publicHome)(void) = ^{
        [api browseShelves:RewindNativeHomeID params:nil completion:^(NSArray *shelves, NSArray *chips, NSError *error) {
            (void)chips;
            done(shelves, error);
        }];
    };
    if (!RewindAccountIsSignedIn()) {
        publicHome();
        return;
    }
    RewindAccountLoadHome(^(NSArray *shelves, NSError *error) {
        if (shelves.count) done(shelves, nil);
        else {
            (void)error;
            publicHome();
        }
    });
}

static UINavigationController *RewindNativeNavigation(UIViewController *root) {
    UINavigationController *navigation = [[[RewindChromeNavigationController alloc] initWithRootViewController:root]
                                          autorelease];
    RewindStyleNavigationBar(navigation.navigationBar);
    return navigation;
}

UIViewController *RewindNativeRootController(RewindPlayer *player, RewindAPI *api) {
    RewindNativeContext *context = RewindNativeContextMake(player, api);

    NSArray *homeTiles = [NSArray arrayWithObjects:
        RewindNativeRow(RewindL(@"tab_explore"), @"explore", ^(UINavigationController *navigation) {
            [navigation pushViewController:[[[RewindNativeShelvesVC alloc] initWithTitle:RewindL(@"tab_explore") context:context
                searchable:NO loader:^(void (^done)(NSArray *, NSError *)) {
                    [api browseShelves:RewindNativeExploreID params:nil completion:^(NSArray *shelves, NSArray *chips, NSError *error) {
                        (void)chips;
                        done(shelves, error);
                    }];
                }] autorelease] animated:YES];
        }),
        RewindNativeRow(RewindL(@"quick_picks"), @"history", ^(UINavigationController *navigation) {
            [navigation pushViewController:[[[RewindLibraryVC alloc] initWithPlayer:player api:api
                mode:RewindLibraryModeRecent] autorelease] animated:YES];
        }),
        RewindNativeRow(RewindL(@"favorites"), @"save", ^(UINavigationController *navigation) {
            [navigation pushViewController:[[[RewindLibraryVC alloc] initWithPlayer:player api:api
                mode:RewindLibraryModeFavorites] autorelease] animated:YES];
        }),
        /* the full "liked music" name does not fit a key */
        RewindNativeRow(RewindL(@"likes_short"), @"thumb-up", ^(UINavigationController *navigation) {
            [navigation pushViewController:[[[RewindLibraryVC alloc] initWithPlayer:player api:api
                mode:RewindLibraryModeLiked] autorelease] animated:YES];
        }),
        RewindNativeRow(RewindL(@"playlists"), @"playlist-add", ^(UINavigationController *navigation) {
            [navigation pushViewController:[[[RewindPlaylistsVC alloc] initWithPlayer:player api:api] autorelease] animated:YES];
        }),
        RewindNativeRow(RewindL(@"downloads"), @"download", ^(UINavigationController *navigation) {
            [navigation pushViewController:[[[RewindLibraryVC alloc] initWithPlayer:player api:api
                mode:RewindLibraryModeDownloads] autorelease] animated:YES];
        }), nil];
    /* the first tab is the music itself: the library keys on top, the home shelves as covers below */
    RewindNativeShelvesVC *home = [[[RewindNativeShelvesVC alloc] initWithTitle:RewindL(@"tab_home") context:context
        searchable:NO loader:^(void (^done)(NSArray *, NSError *)) { RewindNativeLoadHome(api, done); }] autorelease];
    [home setTiles:homeTiles];

    RewindNativeShelvesVC *search = [[[RewindNativeShelvesVC alloc] initWithTitle:RewindL(@"search") context:context
        searchable:YES loader:^(void (^done)(NSArray *, NSError *)) {
            [api browseShelves:RewindNativeExploreID params:nil completion:^(NSArray *shelves, NSArray *chips, NSError *error) {
                (void)chips;
                done(shelves, error);
            }];
        }] autorelease];

    NSArray *moreRows = [NSArray arrayWithObjects:
        RewindNativeRow(RewindL(@"about_account"), @"avatar", ^(UINavigationController *navigation) {
            [navigation pushViewController:[[[RewindNativeAccountVC alloc] init] autorelease] animated:YES];
        }),
        RewindNativeRow(RewindL(@"settings"), @"settings", ^(UINavigationController *navigation) {
            [navigation pushViewController:[[[RewindSettingsVC alloc] init] autorelease] animated:YES];
        }),
        RewindNativeRow(RewindL(@"about"), @"info", ^(UINavigationController *navigation) {
            [navigation pushViewController:[[[RewindAboutVC alloc] init] autorelease] animated:YES];
        }), nil];
    RewindNativeMenuVC *more = [[[RewindNativeMenuVC alloc] initWithTitle:RewindL(@"more") context:context sections:
        [NSArray arrayWithObject:RewindNativeSection(nil, moreRows)]] autorelease];

    /* the library rows already sit on the home menu, so the bar keeps no tab of its own for them */
    NSArray *stacks = [NSArray arrayWithObjects:RewindNativeNavigation(home), RewindNativeNavigation(search),
                       RewindNativeNavigation(more), nil];
    NSArray *titles = [NSArray arrayWithObjects:RewindL(@"tab_home"), RewindL(@"search"), RewindL(@"more"), nil];
    NSArray *icons = [NSArray arrayWithObjects:@"home", @"search", @"more", nil];
    RewindChromeTabsController *tabs = [[[RewindChromeTabsController alloc] initWithControllers:stacks titles:titles
                                                                                          icons:icons] autorelease];
    RewindNativeMiniPlayer *mini = [[[RewindNativeMiniPlayer alloc] initWithContext:context tabs:tabs] autorelease];
    [tabs setAccessory:mini height:RewindIsPad() ? 52.0f : 46.0f];
    [tabs setAccessoryShown:player.track != nil animated:NO];
    return tabs;
}
