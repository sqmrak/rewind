#import "main_vc.h"

#import <QuartzCore/QuartzCore.h>

#import "account_vc.h"
#import "account_panel_vc.h"
#import "artist_vc.h"
#import "library_vc.h"
#import "playlist_vc.h"
#import "player_vc.h"
#import "rewind_account.h"
#import "rewind_api.h"
#import "rewind_config.h"
#import "rewind_download.h"
#import "rewind_image_cache.h"
#import "rewind_l10n.h"
#import "rewind_player.h"
#import "rewind_theme.h"
#import "rewind_ui.h"
#import "settings_vc.h"

enum { RewindTabHome = 0, RewindTabExplore = 1, RewindTabLibrary = 2 };
enum { RewindAlertPlaylist = 8101, RewindAlertCreatePlaylist = 8102 };

static NSString *RewindHomeID(void) { return @"FEmusic_home"; }
static NSString *RewindExploreID(void) { return @"FEmusic_explore"; }
/* face id devices reserve the home indicator strip below the tab icons */
static CGFloat RewindBottomHeight(void) { return RW(56.0f) + RewindBottomSafeInset(); }

static UILabel *RewindLabel(CGFloat size, RewindWeight weight, UIColor *color) {
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.font = RewindFont(size, weight);
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

/* the music video lineup is clips, which the audio player plays badly as songs; youtube
   words its title differently per language, so it is recognised by its items. explore keeps them,
   its trending and new clips shelves are made of them */
static BOOL RewindShelfIsVideoLineup(RewindShelf *shelf) {
    NSUInteger videos = 0, total = 0;
    for (id item in shelf.items) {
        if (![item isKindOfClass:[RewindTrack class]]) continue;
        ++total;
        if ([((RewindTrack *)item).resultType isEqualToString:@"Video"]) ++videos;
    }
    return total >= 3 && videos * 10 >= total * 8;
}

static NSUInteger RewindTrackCount(NSArray *items) {
    NSUInteger count = 0;
    for (id item in items) if ([item isKindOfClass:[RewindTrack class]]) ++count;
    return count;
}
static RewindShelf *RewindFirstSongShelf(NSArray *shelves, RewindShelf *skip) {
    for (RewindShelf *shelf in shelves) {
        if (shelf == skip || RewindShelfIsVideoLineup(shelf)) continue;
        NSUInteger playable = 0;
        for (id item in shelf.items) {
            if ([item isKindOfClass:[RewindTrack class]] &&
                ((RewindTrack *)item).videoID.length && !((RewindTrack *)item).isPlaylist)
                ++playable;
        }
        if (playable >= 3 && playable * 2 >= shelf.items.count) return shelf;
    }
    return nil;
}

/* the account home lists the new releases picked for this listener as a shelf of albums; nothing else on it
   holds only albums, so it is found by its content and not by a title that follows the app language */
static RewindShelf *RewindAlbumShelf(NSArray *shelves) {
    for (RewindShelf *shelf in shelves) {
        NSUInteger albums = 0, others = 0;
        for (id item in shelf.items) {
            if (![item isKindOfClass:[RewindTrack class]]) { ++others; continue; }
            if ([[(RewindTrack *)item resultType] isEqualToString:RewindResultTypeAlbum]) ++albums;
            else ++others;
        }
        if (albums >= 4 && !others) return shelf;
    }
    return nil;
}

static NSArray *RewindPlayableTracks(NSArray *items) {
    NSMutableArray *tracks = [NSMutableArray array];
    for (id item in items) {
        if (![item isKindOfClass:[RewindTrack class]]) continue;
        RewindTrack *track = item;
        if (track.videoID.length && !track.isPlaylist &&
            ![track.resultType isEqualToString:RewindResultTypeArtist] &&
            ![track.resultType isEqualToString:RewindResultTypeAlbum]) [tracks addObject:track];
    }
    return tracks;
}

/* ios 5 and 6 draw a placeholder at the top of its rect, and roboto's tall line box leaves
   it visibly high; the field centres both the text and the placeholder itself */
@interface RewindSearchField : UITextField
@end

@implementation RewindSearchField

- (void)drawPlaceholderInRect:(CGRect)rect {
    UIFont *font = self.font;
    CGFloat lineHeight = ceilf(font.lineHeight);
    CGRect line = CGRectMake(rect.origin.x, rect.origin.y + floorf((rect.size.height - lineHeight) * 0.5f),
                             rect.size.width, lineHeight);
    [RewindColorTextSecondary() setFill];
    [self.placeholder drawInRect:line withFont:font lineBreakMode:NSLineBreakByTruncatingTail];
}

@end

@interface RewindShelfListVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    RewindShelf *_shelf;
    MainVC *_owner;
    UITableView *_table;
}
- (id)initWithShelf:(RewindShelf *)shelf owner:(MainVC *)owner;
@end

/* a browse page (new releases, charts, a mood) opened over the current screen, one section per shelf */
@interface RewindBrowsePageVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    RewindBrowseLink *_link;
    MainVC *_owner;
    RewindAPI *_api;
    NSArray *_shelves;
    UITableView *_table;
    UIActivityIndicatorView *_spinner;
    NSUInteger _request;
}
- (id)initWithLink:(RewindBrowseLink *)link owner:(MainVC *)owner api:(RewindAPI *)api;
@end

@interface MainVC ()
- (void)startPersonalMix;
- (NSArray *)exploreShelvesForDisplay;
- (void)loadHome;
- (void)loadExplore;
- (void)openItem:(id)item inShelf:(RewindShelf *)shelf;
- (void)showTrackMenu:(RewindTrack *)track;
- (void)refreshMini:(NSNotification *)note;
- (void)applyTheme:(NSNotification *)note;
- (void)closeSearch;
- (void)showAllShelf:(RewindShelf *)shelf;
- (void)downloadTrack:(RewindTrack *)track;
@end

@implementation MainVC

- (RewindPlayer *)player {
    return _player;
}

- (void)adoptPlayer:(RewindPlayer *)player {
    if (player == _player) return;
    [_player release];
    _player = [player retain];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    _searchTable.delegate = nil;
    _searchTable.dataSource = nil;
    _searchField.delegate = nil;
    _content.delegate = nil;
    [_api release];
    [_player release];
    [_ambientGradient release];
    [_header release];
    [_brand release];
    [_searchButton release];
    [_accountButton release];
    [_accountAvatar release];
    [_chips release];
    [_content release];
    [_bottom release];
    [_mini release];
    [_miniArt release];
    [_miniTitle release];
    [_miniArtist release];
    [_miniPlay release];
    [_miniSpinner release];
    [_miniProgress release];
    [_tabs release];
    [_shelves release];
    [_chipLinks release];
    [_exploreShelves release];
    [_personalAlbums release];
    [_libraryTracks release];
    [_pendingShelves release];
    [_actionTrack release];
    [_searchPanel release];
    [_searchField release];
    [_searchTable release];
    [_searchResults release];
    [_suggestions release];
    [_searchHint release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = RewindColorCanvas();
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSString *key = [[NSUserDefaults standardUserDefaults] objectForKey:REWIND_API_KEY_DEFAULTS_KEY];
    _api = [[RewindAPI alloc] initWithAPIKey:key.length ? key : RewindDefaultAPIKey];
    if (!_player) _player = [[RewindPlayer alloc] init];
    _tabs = [[NSMutableArray alloc] init];
    _selectedTab = RewindTabHome;
    _visibleShelfCount = 6;

    /* material design 3 had nothing behind the top of the feed but flat black;
       the real app washes it with a soft fade into the canvas for some depth */
    _ambientGradient = [[CALayer layer] retain];
    _ambientGradient.contentsScale = [UIScreen mainScreen].scale;
    [self pickAmbientColors];

    /* the header scrolls away with the feed in the real app, so like _chips it is
       added inside _content (by rebuildContent) instead of pinned to self.view */
    _header = [[UIView alloc] initWithFrame:CGRectZero];
    _header.backgroundColor = RewindColorBackground();
    _brand = [RewindLabel(22.0f, RewindWeightBold, RewindColorText()) retain];
    _brand.text = @"Rewind";
    [_header addSubview:_brand];
    _searchButton = [[RewindIconButton buttonWithIcon:@"search" points:RW(25.0f)] retain];
    __block MainVC *owner = self;
    [_searchButton setOnTap:^{ [owner showSearch]; }];
    [_header addSubview:_searchButton];
    _accountButton = [[RewindIconButton buttonWithIcon:@"avatar" points:RW(24.0f)] retain];
    [_accountButton setOnTap:^{ [owner showAccount]; }];
    [_header addSubview:_accountButton];
    _accountAvatar = [[UIImageView alloc] initWithFrame:CGRectZero];
    _accountAvatar.contentMode = UIViewContentModeScaleAspectFill;
    _accountAvatar.clipsToBounds = YES;
    _accountAvatar.layer.cornerRadius = RW(16.0f);
    _accountAvatar.userInteractionEnabled = NO;
    [_accountButton addSubview:_accountAvatar];

    /* the mood chips scroll away with the rest of the home feed in the real app,
       so this lives inside _content (added by rebuildContent) instead of sitting
       fixed under the header */
    _chips = [[RewindChipBar alloc] initWithFrame:CGRectZero];
    _chips.hidden = YES;
    [_chips setOnSelect:^(NSInteger index) { [owner selectChip:index]; }];
    _content = [[RewindScrollView alloc] initWithFrame:CGRectZero];
    _content.backgroundColor = [UIColor clearColor];
    _content.showsVerticalScrollIndicator = NO;
    _content.alwaysBounceVertical = YES;
    _content.delegate = self;
    [self.view addSubview:_content];
    /* the wash belongs to the feed: it rides in the scroll view so it moves away with the header */
    [_content.layer insertSublayer:_ambientGradient atIndex:0];

    _bottom = [[UIView alloc] initWithFrame:CGRectZero];
    _bottom.backgroundColor = RewindColorBackground();
    [self.view addSubview:_bottom];
    NSArray *names = [NSArray arrayWithObjects:@"home", @"explore", @"library", nil];
    NSArray *titles = [NSArray arrayWithObjects:RewindL(@"tab_home"), RewindL(@"tab_explore"), RewindL(@"library"), nil];
    for (NSUInteger index = 0; index < names.count; ++index) {
        RewindPressControl *tab = [[[RewindPressControl alloc] initWithFrame:CGRectZero] autorelease];
        tab.pressScales = NO;
        tab.tag = 100 + (NSInteger)index;
        UIImageView *icon = [[[UIImageView alloc] initWithFrame:CGRectZero] autorelease];
        icon.tag = 1;
        icon.contentMode = UIViewContentModeCenter;
        [tab addSubview:icon];
        UILabel *title = RewindLabel(11.0f, RewindWeightRegular, RewindColorTextSecondary());
        title.tag = 2;
        title.text = [titles objectAtIndex:index];
        title.textAlignment = NSTextAlignmentCenter;
        [tab addSubview:title];
        [tab setOnTap:^{ [owner selectTab:(NSInteger)index]; }];
        [_bottom addSubview:tab];
        [_tabs addObject:tab];
    }
    [self updateTabs];

    _mini = [[UIView alloc] initWithFrame:CGRectZero];
    _mini.backgroundColor = RewindColorSurfaceHigh();
    _mini.layer.cornerRadius = RW(9.0f);
    _mini.clipsToBounds = YES;
    _mini.hidden = YES;
    [self.view addSubview:_mini];
    RewindPressControl *miniTap = [[[RewindPressControl alloc] initWithFrame:CGRectZero] autorelease];
    miniTap.tag = 50;
    miniTap.pressScales = NO;
    [miniTap setOnTap:^{ [owner showPlayer]; }];
    [_mini addSubview:miniTap];
    _miniArt = [[RewindArtworkView alloc] initWithFrame:CGRectZero];
    [_miniArt setCornerRadius:RW(4.0f)];
    _miniArt.userInteractionEnabled = NO;
    [miniTap addSubview:_miniArt];
    _miniTitle = [[RewindMarqueeLabel alloc] initWithFrame:CGRectZero];
    [_miniTitle setFont:RewindFont(14.0f, RewindWeightMedium)];
    [_miniTitle setTextColor:RewindColorText()];
    [miniTap addSubview:_miniTitle];
    _miniArtist = [RewindLabel(12.0f, RewindWeightRegular, RewindColorTextSecondary()) retain];
    [miniTap addSubview:_miniArtist];
    _miniPlay = [[RewindIconButton buttonWithIcon:@"play" points:RW(26.0f)] retain];
    [_miniPlay setOnTap:^{ [owner->_player toggle]; }];
    [_mini addSubview:_miniPlay];
    _miniSpinner = [[UIActivityIndicatorView alloc]
                    initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _miniSpinner.hidesWhenStopped = YES;
    _miniSpinner.userInteractionEnabled = NO;
    [_mini addSubview:_miniSpinner];
    _miniProgress = [[UIView alloc] initWithFrame:CGRectZero];
    _miniProgress.backgroundColor = RewindColorText();
    [_mini addSubview:_miniProgress];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshMini:)
                                                 name:RewindPlayerDidChangeNotification object:_player];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(accountChanged:)
                                                 name:RewindAccountDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(accountLibraryChanged:)
                                                 name:RewindAccountLibraryDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(languageChanged:)
                                                 name:REWIND_LANGUAGE_DID_CHANGE_NOTIFICATION object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(focusSearch:)
                                                 name:RewindFocusSearchNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyTheme:)
                                                 name:RewindThemeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadsChanged:)
                                                 name:RewindDownloadsDidChangeNotification object:nil];
    [self applyTheme:nil];
    [self accountChanged:nil];
    [self refreshMini:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    RewindWarmPlaybackConnections();
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    NSString *key = [[NSUserDefaults standardUserDefaults] objectForKey:REWIND_API_KEY_DEFAULTS_KEY];
    [_api release];
    _api = [[RewindAPI alloc] initWithAPIKey:key.length ? key : RewindDefaultAPIKey];
    [self refreshMini:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    CGFloat width = b.size.width;
    /* ios 7 and later draw the status bar over the app; the header starts under it */
    CGFloat top = RewindStatusBarInset();
    CGFloat headerH = RW(54.0f);
    CGFloat bottomH = RewindBottomHeight();
    [self refreshAmbientForWidth:width];
    CGFloat miniH = _mini.hidden ? 0.0f : RW(64.0f);
    _header.frame = CGRectMake(0, 0, width, top + headerH);
    _brand.frame = CGRectMake(RW(16.0f), top, width - RW(130.0f), headerH);
    _searchButton.frame = CGRectMake(width - RW(100.0f), top, RW(44.0f), headerH);
    _accountButton.frame = CGRectMake(width - RW(52.0f), top, RW(44.0f), headerH);
    _accountAvatar.frame = CGRectMake(RW(6.0f), floorf((headerH - RW(32.0f)) * 0.5f), RW(32.0f), RW(32.0f));
    _bottom.frame = CGRectMake(0, b.size.height - bottomH, width, bottomH);
    CGFloat tabW = width / 3.0f;
    for (NSUInteger index = 0; index < _tabs.count; ++index) {
        UIView *tab = [_tabs objectAtIndex:index];
        tab.frame = CGRectMake(index * tabW, 0, tabW, bottomH);
        [tab viewWithTag:1].frame = CGRectMake(0, RW(4.0f), tabW, RW(28.0f));
        [tab viewWithTag:2].frame = CGRectMake(0, RW(33.0f), tabW, RW(18.0f));
    }
    _mini.frame = CGRectMake(RW(8.0f), CGRectGetMinY(_bottom.frame) - miniH - RW(4.0f),
                             width - RW(16.0f), miniH);
    UIView *miniTap = [_mini viewWithTag:50];
    miniTap.frame = CGRectMake(0, 0, _mini.bounds.size.width - RW(54.0f), miniH);
    _miniArt.frame = CGRectMake(RW(8.0f), RW(8.0f), RW(48.0f), RW(48.0f));
    CGFloat textX = RW(64.0f);
    _miniTitle.frame = CGRectMake(textX, RW(9.0f), miniTap.bounds.size.width - textX, RW(21.0f));
    _miniArtist.frame = CGRectMake(textX, RW(31.0f), miniTap.bounds.size.width - textX, RW(18.0f));
    _miniPlay.frame = CGRectMake(_mini.bounds.size.width - RW(54.0f), RW(6.0f), RW(48.0f), RW(48.0f));
    _miniSpinner.center = _miniPlay.center;
    _miniProgress.frame = CGRectMake(0, miniH - RW(2.0f), _mini.bounds.size.width * _player.progress, RW(2.0f));
    _content.frame = CGRectMake(0, 0, width,
                                MAX(0.0f, CGRectGetMinY(_mini.hidden ? _bottom.frame : _mini.frame)));
    _searchPanel.frame = b;
    if (fabs(_laidWidth - width) > 0.5f) {
        _laidWidth = width;
        [self rebuildContent];
    }
    if (_searchPanel) [self layoutSearch];
}

- (void)updateTabs {
    NSArray *names = [NSArray arrayWithObjects:@"home", @"explore", @"library", nil];
    for (NSUInteger index = 0; index < _tabs.count; ++index) {
        UIView *tab = [_tabs objectAtIndex:index];
        BOOL selected = index == (NSUInteger)_selectedTab;
        NSString *icon = [[names objectAtIndex:index] stringByAppendingString:selected ? @"-on" : @""];
        ((UIImageView *)[tab viewWithTag:1]).image = RewindIcon(icon, RW(24.0f),
                                          selected ? RewindColorText() : RewindColorTextSecondary());
        ((UILabel *)[tab viewWithTag:2]).textColor = selected ? RewindColorText() : RewindColorTextSecondary();
    }
}

- (void)selectTab:(NSInteger)tab {
    if (tab < RewindTabHome || tab > RewindTabLibrary) return;
    if (_selectedTab == tab) {
        [_content setContentOffset:CGPointZero animated:YES];
        return;
    }
    _selectedTab = tab;
    _visibleShelfCount = 6;
    [self updateTabs];
    _chips.hidden = tab != RewindTabHome || !_chipLinks.count;
    [_content setContentOffset:CGPointZero animated:NO];
    [self rebuildContent];
    [self.view setNeedsLayout];
    if (tab == RewindTabExplore && !_exploreShelves) [self loadExplore];
    if (tab == RewindTabLibrary) [self loadLibrary];
}

- (void)loadHome {
    NSUInteger request = ++_homeRequest;
    if (RewindAccountIsSignedIn()) {
        __block BOOL libraryQueued = NO;
        RewindAccountLoadHome(^(NSArray *shelves, NSError *error) {
            if (request != _homeRequest) return;
            if (error) NSLog(@"rewind: personal home: %@", error);
            /* liked music pages sixteen requests deep; it waits so the home is not queued behind it */
            if (!libraryQueued) {
                libraryQueued = YES;
                RewindAccountLoadLikes(NO, nil);
                RewindAccountLoadPlaylists(nil);
            }
            if (shelves.count) {
                _personalHome = YES;
                [_shelves release];
                _shelves = [shelves copy];
                [_personalAlbums release];
                _personalAlbums = [RewindAlbumShelf(shelves) retain];
                if (_selectedTab != RewindTabLibrary) [self rebuildContent];
            } else [self loadPublicHomeForRequest:request];
        });
        /* mood links are public even when the home shelves are personal */
        [_api browseShelves:RewindHomeID() params:nil completion:^(NSArray *shelves, NSArray *chips, NSError *error) {
            (void)shelves;
            if (request != _homeRequest) return;
            if (error) NSLog(@"rewind: home chips: %@", error);
            [self setChipLinks:chips];
        }];
    } else [self loadPublicHomeForRequest:request];
}

- (void)loadPublicHomeForRequest:(NSUInteger)request {
    [_api browseShelves:RewindHomeID() params:nil completion:^(NSArray *shelves, NSArray *chips, NSError *error) {
        if (request != _homeRequest) return;
        if (error) NSLog(@"rewind: public home: %@", error);
        _personalHome = NO;
        [_shelves release];
        _shelves = [shelves copy];
        [self setChipLinks:chips];
        if (_selectedTab == RewindTabHome) [self rebuildContent];
    }];
}

- (void)setChipLinks:(NSArray *)links {
    [_chipLinks release];
    _chipLinks = [links copy];
    NSMutableArray *titles = [NSMutableArray array];
    for (RewindBrowseLink *link in links) [titles addObject:link.title ?: @""];
    [_chips setTitles:titles];
    _chips.hidden = _selectedTab != RewindTabHome || !links.count;
    /* signed in, the personal shelves and the public mood chips are two requests; when the shelves win, the
       page was built without the chip row and a relayout alone never adds it */
    if (_selectedTab == RewindTabHome && _shelves.count) [self rebuildContent];
    [self.view setNeedsLayout];
}

- (void)selectChip:(NSInteger)index {
    if (index < 0) {
        [self loadHome];
        return;
    }
    if ((NSUInteger)index >= _chipLinks.count) return;
    RewindBrowseLink *link = [_chipLinks objectAtIndex:(NSUInteger)index];
    [self loadBrowseLink:link];
}

- (void)loadBrowseLink:(RewindBrowseLink *)link {
    NSUInteger request = ++_homeRequest;
    [_api browseShelves:link.browseID params:link.params completion:^(NSArray *shelves, NSArray *chips, NSError *error) {
        (void)chips;
        if (request != _homeRequest) return;
        if (error) {
            RewindShowToast(self.view, RewindFriendlyError(error), RewindBottomHeight());
            return;
        }
        _personalHome = NO;
        [_shelves release];
        _shelves = [shelves copy];
        if (_selectedTab == RewindTabHome) [self rebuildContent];
    }];
}

- (void)loadExplore {
    NSUInteger request = ++_exploreRequest;
    [_api browseShelves:RewindExploreID() params:nil completion:^(NSArray *shelves, NSArray *chips, NSError *error) {
        (void)chips;
        if (request != _exploreRequest) return;
        if (error) {
            NSLog(@"rewind: explore: %@", error);
            RewindShowToast(self.view, RewindFriendlyError(error), RewindBottomHeight());
        }
        [_exploreShelves release];
        _exploreShelves = [shelves copy];
        if (_selectedTab == RewindTabExplore) [self rebuildContent];
    }];
}

/* the public explore page lists new albums for everyone; a signed in listener sees the releases picked for
   them from the account home in that slot instead */
- (NSArray *)exploreShelvesForDisplay {
    RewindShelf *mine = _personalAlbums;
    if (!RewindAccountIsSignedIn() || !mine) return _exploreShelves;
    NSMutableArray *shelves = [NSMutableArray array];
    BOOL replaced = NO;
    for (RewindShelf *shelf in _exploreShelves) {
        if (!replaced && RewindAlbumShelf([NSArray arrayWithObject:shelf]) == shelf) {
            [shelves addObject:[[[RewindShelf alloc] initWithTitle:shelf.title caption:shelf.caption items:mine.items
                                                             style:RewindShelfStyleCards] autorelease]];
            replaced = YES;
        } else [shelves addObject:shelf];
    }
    return replaced ? shelves : _exploreShelves;
}

- (void)loadLibrary {
    NSMutableArray *tracks = [NSMutableArray arrayWithArray:RewindLibraryTracks()];
    [_libraryTracks release];
    _libraryTracks = [tracks copy];
    if (_selectedTab == RewindTabLibrary) [self rebuildContent];
}

- (void)accountChanged:(NSNotification *)note {
    (void)note;
    [_shelves release]; _shelves = nil;
    _accountAvatar.image = nil;
    NSString *photo = RewindAccountPhotoURL();
    _accountAvatar.hidden = !RewindAccountIsSignedIn() || !photo.length;
    if (!_accountAvatar.hidden) {
        NSString *requested = [photo copy];
        RewindLoadImageSized(requested, 96.0f, ^(UIImage *image) {
            if (image && [RewindAccountPhotoURL() isEqualToString:requested]) _accountAvatar.image = image;
        });
        [requested release];
    }
    [self loadHome];
    [self loadLibrary];
}

- (void)accountLibraryChanged:(NSNotification *)note {
    (void)note;
    if (_selectedTab == RewindTabLibrary) [self rebuildContent];
}

- (void)languageChanged:(NSNotification *)note {
    (void)note;
    NSArray *titles = [NSArray arrayWithObjects:RewindL(@"tab_home"), RewindL(@"tab_explore"), RewindL(@"library"), nil];
    for (NSUInteger i = 0; i < _tabs.count; ++i)
        ((UILabel *)[[_tabs objectAtIndex:i] viewWithTag:2]).text = [titles objectAtIndex:i];
    /* the shelf titles and chips ("quick picks", "new releases", mood chips...) are
       not our strings, they come from the api's own response in whatever language
       the "hl" parameter asked for; rebuildContent alone just relays out the same
       stale response, so the feed needs a fresh fetch to actually come back translated */
    [_shelves release]; _shelves = nil;
    [_exploreShelves release]; _exploreShelves = nil;
    [self rebuildContent];
    [self loadHome];
    [self loadExplore];
}

/* a new wash every launch: a hue from a short list that stays rich on black, and a second hue
   a little further round the wheel so the fade is not a single flat tint */
- (void)pickAmbientColors {
    static const CGFloat hues[] = { 0.60f, 0.66f, 0.72f, 0.78f, 0.85f, 0.93f, 0.99f, 0.04f, 0.47f, 0.53f };
    CGFloat hue = hues[arc4random() % (sizeof(hues) / sizeof(hues[0]))];
    hue += ((CGFloat)(arc4random() % 100) / 100.0f - 0.5f) * 0.05f;
    CGFloat other = hue + 0.07f + (CGFloat)(arc4random() % 60) / 1000.0f;
    _ambientHueA = hue - floorf(hue);
    _ambientHueB = other - floorf(other);
    _ambientWidth = 0.0f;
}

/* colour that fades out like a lamp: alpha follows a steep curve instead of a straight ramp, which is
   what makes a two stop gradient look like a flat band */
static CGGradientRef RewindEasedGradient(UIColor *color, CGFloat peak) {
    enum { stops = 10 };
    CGFloat r = 0, g = 0, b = 0, a = 1, components[stops * 4], locations[stops];
    [color getRed:&r green:&g blue:&b alpha:&a];
    for (int i = 0; i < stops; ++i) {
        CGFloat t = (CGFloat)i / (stops - 1);
        components[i * 4] = r; components[i * 4 + 1] = g; components[i * 4 + 2] = b;
        components[i * 4 + 3] = peak * powf(1.0f - t, 2.4f);
        locations[i] = t;
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, stops);
    CGColorSpaceRelease(space);
    return gradient;
}

static UIImage *RewindAmbientImage(CGSize size, CGFloat hueA, CGFloat hueB) {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0f);
    CGContextRef context = UIGraphicsGetCurrentContext();
    UIColor *first = [UIColor colorWithHue:hueA saturation:0.72f brightness:0.58f alpha:1.0f];
    UIColor *second = [UIColor colorWithHue:hueB saturation:0.66f brightness:0.62f alpha:1.0f];
    CGGradientRef lamp = RewindEasedGradient(first, 0.62f);
    CGContextDrawRadialGradient(context, lamp, CGPointMake(size.width * 0.12f, -size.height * 0.05f), 0.0f,
                                CGPointMake(size.width * 0.12f, -size.height * 0.05f), size.width * 1.05f, 0);
    CGGradientRelease(lamp);
    CGGradientRef lamp2 = RewindEasedGradient(second, 0.52f);
    CGContextDrawRadialGradient(context, lamp2, CGPointMake(size.width * 0.96f, size.height * 0.10f), 0.0f,
                                CGPointMake(size.width * 0.96f, size.height * 0.10f), size.width * 0.95f, 0);
    CGGradientRelease(lamp2);
    /* both glows end in nothing at the bottom edge, no cut line against the canvas */
    CGContextSetBlendMode(context, kCGBlendModeDestinationIn);
    CGGradientRef mask = RewindEasedGradient([UIColor whiteColor], 1.0f);
    CGContextDrawLinearGradient(context, mask, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
    CGGradientRelease(mask);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (void)refreshAmbientForWidth:(CGFloat)width {
    CGSize size = CGSizeMake(width, MAX(RW(400.0f), _ambientHeight));
    CGFloat previousHeight = _ambientGradient.frame.size.height;
    _ambientGradient.frame = CGRectMake(0, 0, size.width, size.height);
    if (fabsf(width - _ambientWidth) < 0.5f && fabsf(size.height - previousHeight) < 0.5f) return;
    if (width <= 0.0f) return;
    _ambientWidth = width;
    _ambientGradient.contents = (id)RewindAmbientImage(size, _ambientHueA, _ambientHueB).CGImage;
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = RewindColorCanvas();
    _ambientGradient.hidden = NO;
    /* the header scrolls over the ambient gradient, so it is no solid chrome plate the way the fixed
       bottom bar is */
    _header.backgroundColor = [UIColor clearColor];
    _bottom.backgroundColor = RewindColorChrome();
    _header.layer.borderColor = RewindColorDivider().CGColor;
    _bottom.layer.borderColor = RewindColorDivider().CGColor;
    _header.layer.borderWidth = 0.0f;
    _bottom.layer.borderWidth = 0.0f;
    _brand.textColor = RewindColorText();
    _brand.font = RewindFont(22.0f, RewindWeightBold);
    [_searchButton setIconColor:RewindColorText()];
    [_accountButton setIconColor:RewindColorText()];
    _mini.backgroundColor = RewindColorSurfaceHigh();
    _mini.clipsToBounds = YES;
    _mini.layer.borderWidth = 0.0f;
    _miniTitle.textColor = RewindColorText();
    _miniTitle.font = RewindFont(14.0f, RewindWeightMedium);
    _miniArtist.textColor = RewindColorTextSecondary();
    _miniArtist.font = RewindFont(12.0f, RewindWeightRegular);
    _miniProgress.backgroundColor = RewindColorText();
    [_miniPlay setIconColor:RewindColorText()];
    [self updateTabs];
    for (UIView *tab in _tabs)
        ((UILabel *)[tab viewWithTag:2]).font = RewindFont(11.0f, RewindWeightRegular);
    if (_searchPanel) {
        _searchPanel.backgroundColor = RewindColorCanvas();
        [_searchPanel viewWithTag:302].backgroundColor = RewindColorSurfaceHigh();
        _searchField.textColor = RewindColorText();
        _searchTable.backgroundColor = RewindColorBackground();
        _searchHint.textColor = RewindColorTextSecondary();
        [_searchTable reloadData];
    }
    [self rebuildContent];
}

- (void)refreshMini:(NSNotification *)note {
    NSError *error = [[note userInfo] objectForKey:@"error"];
    if (error) RewindShowToast(self.view, RewindFriendlyError(error), RewindBottomHeight());
    RewindTrack *track = _player.track;
    BOOL wasHidden = _mini.hidden;
    _mini.hidden = !track;
    if (track) {
        _miniTitle.text = track.title;
        _miniArtist.text = RewindTrackArtistText(track);
        [_miniArt setURL:track.thumbnailURL];
        _miniPlay.hidden = _player.loading;
        if (_player.loading) [_miniSpinner startAnimating];
        else [_miniSpinner stopAnimating];
        [_miniPlay setIconName:_player.playing ? @"pause" : @"play"];
    }
    if (wasHidden != _mini.hidden) [self.view setNeedsLayout];
    _miniProgress.frame = CGRectMake(0, _mini.bounds.size.height - RW(2.0f),
                                     _mini.bounds.size.width * _player.progress, RW(2.0f));
}

- (void)showPlayer {
    if (!_player.track) return;
    RewindPlayerVC *controller = [[[RewindPlayerVC alloc] initWithPlayer:_player api:_api] autorelease];
    UINavigationController *navigation = [[[UINavigationController alloc] initWithRootViewController:controller] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)showAccount {
    RewindAccountPanelVC *account = [[[RewindAccountPanelVC alloc] initWithAPI:_api player:_player] autorelease];
    UINavigationController *navigation = [[[UINavigationController alloc] initWithRootViewController:account] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)openItem:(id)item inShelf:(RewindShelf *)shelf {
    if ([item isKindOfClass:[RewindBrowseLink class]]) {
        /* a page of its own: loading it into the home feed replaced the feed with no way back */
        RewindBrowsePageVC *page = [[[RewindBrowsePageVC alloc] initWithLink:item owner:self api:_api] autorelease];
        [self.navigationController setNavigationBarHidden:NO animated:YES];
        [self.navigationController pushViewController:page animated:YES];
        return;
    }
    if (![item isKindOfClass:[RewindTrack class]]) return;
    RewindTrack *track = item;
    if ([track.resultType isEqualToString:RewindResultTypeArtist]) {
        RewindArtistVC *artist = [[[RewindArtistVC alloc] initWithArtist:track.title
                                                             artworkURL:track.thumbnailURL
                                                                    api:_api player:_player seedTrack:nil] autorelease];
        [self.navigationController setNavigationBarHidden:NO animated:YES];
        [self.navigationController pushViewController:artist animated:YES];
        return;
    }
    if ([track.resultType isEqualToString:RewindResultTypeMix]) {
        void (^playMix)(NSArray *, NSError *) = ^(NSArray *tracks, NSError *error) {
            tracks = RewindPlayableTracks(tracks);
            if (error || !tracks.count) {
                RewindShowToast(self.view, RewindFriendlyError(error) ?: RewindL(@"account_mix_failed"), RewindBottomHeight());
                return;
            }
            RewindRecordTrack([tracks objectAtIndex:0]);
            [_player setQueue:tracks selectedIndex:0 usingAPI:_api];
        };
        if (RewindAccountIsSignedIn()) RewindAccountLoadMix(track, playMix);
        else if (track.playlistID.length) [_api playlistTracksForID:track.playlistID completion:playMix];
        else if (track.videoID.length) [_api relatedForTrack:track completion:^(NSArray *related, NSArray *links, NSError *error) {
            (void)links;
            RewindShelf *songs = RewindFirstSongShelf(related, nil);
            playMix(songs.items, error);
        }];
        else playMix(nil, nil);
        return;
    }
    if (track.isPlaylist || [track.resultType isEqualToString:RewindResultTypeAlbum]) {
        RewindPlaylistVC *playlist = [[[RewindPlaylistVC alloc] initWithRemotePlaylist:track player:_player api:_api] autorelease];
        [self.navigationController setNavigationBarHidden:NO animated:YES];
        [self.navigationController pushViewController:playlist animated:YES];
        return;
    }
    NSArray *queue = RewindPlayableTracks(shelf.items);
    NSUInteger index = [queue indexOfObjectIdenticalTo:track];
    if (index == NSNotFound) {
        /* a song that came from elsewhere than the shelf, like a filled up quick picks square, plays on its own */
        queue = [NSArray arrayWithObject:track];
        index = 0;
    }
    RewindRecordTrack(track);
    [_player setQueue:queue selectedIndex:(NSInteger)index usingAPI:_api];
}

- (void)clearContent {
    NSArray *subviews = [_content.subviews copy];
    for (UIView *view in subviews) [view removeFromSuperview];
    [subviews release];
}

- (void)rebuildContent {
    if (!_content || _content.bounds.size.width < 1.0f) return;
    [self clearContent];
    [_pendingShelves release];
    _pendingShelves = nil;
    _builtShelfCount = 0;
    _ambientHeight = 0.0f;
    CGFloat width = _content.bounds.size.width;
    [_content addSubview:_header];
    /* addHeader: already adds its own 20pt of breathing room above a section
       title, so stacking another gap here just doubled up the air between the
       top bar, the chips and "quick picks" */
    CGFloat y = CGRectGetMaxY(_header.frame) + RW(2.0f);
    BOOL showChips = _selectedTab == RewindTabHome && _chipLinks.count > 0;
    _chips.hidden = !showChips;
    if (showChips) {
        _chips.frame = CGRectMake(0, y, width, [_chips preferredHeight]);
        [_content addSubview:_chips];
        /* addHeader: below adds its own 20pt of breathing room before "quick
           picks"; trim it back so the chips sit close under it like the real app */
        y = CGRectGetMaxY(_chips.frame) - RW(12.0f);
    }
    if (_selectedTab == RewindTabLibrary) y = [self buildLibraryFromY:y width:width];
    else {
        NSArray *shelves = _selectedTab == RewindTabHome ? _shelves : [self exploreShelvesForDisplay];
        if (!shelves.count) {
            UILabel *status = RewindLabel(15.0f, RewindWeightRegular, RewindColorTextSecondary());
            status.text = RewindL(@"loading_tracks");
            status.textAlignment = NSTextAlignmentCenter;
            status.frame = CGRectMake(RW(16.0f), RW(80.0f), width - RW(32.0f), RW(40.0f));
            [_content addSubview:status];
            y = CGRectGetMaxY(status.frame);
        } else if (_selectedTab == RewindTabHome) y = [self buildHome:shelves fromY:y width:width];
        else y = [self buildShelves:shelves skip:nil skipOther:nil fromY:y width:width];
    }
    _content.contentSize = CGSizeMake(width, y + RW(48.0f));
    [self refreshAmbientForWidth:width];
}

- (CGFloat)addHeader:(NSString *)title caption:(NSString *)caption atY:(CGFloat)y width:(CGFloat)width
                more:(RewindAction)more {
    /* sections need air above them; the header also sizes itself for a two line title */
    if (y > RW(24.0f)) y += RW(20.0f);
    RewindSectionHeader *header = [[[RewindSectionHeader alloc] initWithFrame:
                                    CGRectMake(0, y, width, RW(62.0f))] autorelease];
    [header setTitle:title caption:caption avatarURL:caption.length ? RewindAccountPhotoURL() : nil];
    if (more) [header setMoreTitle:RewindL(@"see_all") action:more];
    CGFloat height = [header preferredHeightForWidth:width];
    header.frame = CGRectMake(0, y, width, height);
    [_content addSubview:header];
    return y + height + RW(6.0f);
}

- (CGFloat)buildHome:(NSArray *)shelves fromY:(CGFloat)y width:(CGFloat)width {
    /* the account api owns shelf order and membership, including artist mixes */
    return [self buildShelves:shelves skip:nil skipOther:nil fromY:y width:width];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    /* a finger on the feed usually ends on a track, keep the connections a start needs open */
    RewindWarmPlaybackConnections();
    if (scrollView.tag >= 7000) {
        RewindPageDots *dots = (RewindPageDots *)[_content viewWithTag:scrollView.tag + 1];
        NSUInteger page = (NSUInteger)MAX(0.0f, floorf(scrollView.contentOffset.x / scrollView.bounds.size.width + 0.5f));
        if ([dots isKindOfClass:[RewindPageDots class]] && page != [dots current]) [dots setCurrent:page];
        return;
    }
    if (scrollView == _content) {
        NSArray *shelves = _selectedTab == RewindTabHome ? _shelves : _exploreShelves;
        (void)shelves;
        if (_selectedTab == RewindTabLibrary || _builtShelfCount >= _pendingShelves.count ||
            scrollView.contentOffset.y < RW(24.0f)) return;
        if (scrollView.contentOffset.y + scrollView.bounds.size.height >= scrollView.contentSize.height - RW(320.0f)) {
            _visibleShelfCount = MIN(_pendingShelves.count, _visibleShelfCount + 5);
            CGFloat bottom = [self appendPendingShelvesFromY:_contentBottom width:_content.bounds.size.width];
            _content.contentSize = CGSizeMake(_content.bounds.size.width, bottom + RW(48.0f));
        }
        return;
    }
}

- (CGFloat)buildShelves:(NSArray *)shelves skip:(RewindShelf *)skip
              skipOther:(RewindShelf *)other fromY:(CGFloat)y width:(CGFloat)width {
    NSMutableArray *pending = [NSMutableArray array];
    for (RewindShelf *shelf in shelves)
        if (shelf != skip && shelf != other && shelf.items.count &&
            (_selectedTab == RewindTabExplore || !RewindShelfIsVideoLineup(shelf)))
            [pending addObject:shelf];
    [_pendingShelves release];
    _pendingShelves = [pending copy];
    _builtShelfCount = 0;
    for (RewindShelf *shelf in _pendingShelves) {
        RewindDebugLog(@"home shelf \"%@\" style %d, %lu items", shelf.title, (int)shelf.style, (unsigned long)shelf.items.count);
    }
    return [self appendPendingShelvesFromY:y width:width];
}

/* scrolling near the end adds the next shelves below; rebuilding every shelf there
   recreated hundreds of views mid scroll and stuttered on an iphone 4s */
- (CGFloat)appendPendingShelvesFromY:(CGFloat)y width:(CGFloat)width {
    NSUInteger limit = MIN(_pendingShelves.count, _visibleShelfCount);
    while (_builtShelfCount < limit) {
        RewindShelf *shelf = [_pendingShelves objectAtIndex:_builtShelfCount++];
        y = [self addShelf:shelf atY:y width:width compact:shelf.style == RewindShelfStyleList];
    }
    _contentBottom = y;
    return y;
}

/* the explore page the way the real app lays it out: three nav tiles, big cards, mood pills in three rows
   that scroll sideways, a ranked chart list and wide video cards; -1 leaves the shelf to the generic builder */
- (CGFloat)addExploreShelf:(RewindShelf *)shelf atY:(CGFloat)y width:(CGFloat)width {
    __block MainVC *owner = self;
    CGFloat side = RW(16.0f), gap = RW(8.0f);
    if (shelf.style == RewindShelfStyleLinks) {
        NSMutableArray *links = [NSMutableArray array];
        for (id item in shelf.items)
            if ([item isKindOfClass:[RewindBrowseLink class]]) [links addObject:item];
        if (!links.count) return -1.0f;
        if (!shelf.title.length) {
            CGFloat tileW = floorf((width - side * 2.0f - gap * 2.0f) / 3.0f), tileH = RW(96.0f);
            y += RW(10.0f);
            for (NSUInteger index = 0; index < MIN((NSUInteger)3, links.count); ++index) {
                RewindBrowseLink *link = [links objectAtIndex:index];
                NSString *id_ = link.browseID ?: @"";
                NSString *icon = [id_ rangeOfString:@"new_releases"].location != NSNotFound ? @"new-releases"
                    : ([id_ rangeOfString:@"charts"].location != NSNotFound ? @"charts"
                    : ([id_ rangeOfString:@"moods"].location != NSNotFound ? @"moods" : @"note"));
                RewindPressControl *tile = [[[RewindPressControl alloc] initWithFrame:
                    CGRectMake(side + index * (tileW + gap), y, tileW, tileH)] autorelease];
                tile.backgroundColor = RewindColorSurfaceHigh();
                tile.layer.cornerRadius = RW(16.0f);
                UIImageView *glyph = [[[UIImageView alloc] initWithImage:RewindIcon(icon, RW(26.0f), RewindColorText())] autorelease];
                glyph.frame = CGRectMake(RW(14.0f), RW(14.0f), RW(26.0f), RW(26.0f));
                [tile addSubview:glyph];
                UILabel *title = RewindLabel(15.0f, RewindWeightMedium, RewindColorText());
                title.frame = CGRectMake(RW(14.0f), tileH - RW(46.0f), tileW - RW(22.0f), RW(38.0f));
                title.numberOfLines = 2;
                title.text = link.title;
                [tile addSubview:title];
                [tile setOnTap:^{ [owner openItem:link inShelf:shelf]; }];
                [_content addSubview:tile];
            }
            return y + tileH + RW(14.0f);
        }
        y = [self addHeader:shelf.title caption:nil atY:y width:width more:nil];
        CGFloat pillW = floorf(width * 0.42f), pillH = RW(46.0f), rowGap = RW(8.0f);
        NSUInteger count = MIN((NSUInteger)30, links.count), columns = (count + 2) / 3;
        RewindScrollView *scroll = [[[RewindScrollView alloc] initWithFrame:
            CGRectMake(0, y, width, pillH * 3.0f + rowGap * 2.0f)] autorelease];
        scroll.showsHorizontalScrollIndicator = NO;
        scroll.alwaysBounceHorizontal = YES;
        for (NSUInteger index = 0; index < count; ++index) {
            RewindBrowseLink *link = [links objectAtIndex:index];
            RewindPressControl *pill = [[[RewindPressControl alloc] initWithFrame:
                CGRectMake(side + (index / 3) * (pillW + gap), (index % 3) * (pillH + rowGap), pillW, pillH)] autorelease];
            pill.backgroundColor = RewindColorSurfaceHigh();
            pill.layer.cornerRadius = RW(8.0f);
            pill.layer.masksToBounds = YES;
            UIView *stripe = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, RW(5.0f), pillH)] autorelease];
            unsigned rgb = link.stripeColor;
            stripe.backgroundColor = rgb ? [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0f
                                                           green:((rgb >> 8) & 255) / 255.0f
                                                            blue:(rgb & 255) / 255.0f alpha:1] : RewindColorTextSecondary();
            [pill addSubview:stripe];
            UILabel *title = RewindLabel(15.0f, RewindWeightMedium, RewindColorText());
            title.frame = CGRectMake(RW(18.0f), 0, pillW - RW(26.0f), pillH);
            title.text = link.title;
            [pill addSubview:title];
            [pill setOnTap:^{ [owner openItem:link inShelf:shelf]; }];
            [scroll addSubview:pill];
        }
        scroll.contentSize = CGSizeMake(side * 2.0f + columns * (pillW + gap) - gap, scroll.bounds.size.height);
        [_content addSubview:scroll];
        return y + scroll.bounds.size.height + RW(18.0f);
    }
    NSMutableArray *tracks = [NSMutableArray array];
    for (id item in shelf.items)
        if ([item isKindOfClass:[RewindTrack class]]) [tracks addObject:item];
    if (!tracks.count) return -1.0f;
    if (shelf.style == RewindShelfStyleList) {
        NSUInteger count = MIN((NSUInteger)4, tracks.count);
        CGFloat rowH = RW(86.0f), artW = RW(100.0f), artH = RW(56.0f);
        y = [self addHeader:shelf.title caption:shelf.caption atY:y width:width
                       more:tracks.count > count ? ^{ [owner showAllShelf:shelf]; } : nil];
        for (NSUInteger index = 0; index < count; ++index) {
            RewindTrack *track = [tracks objectAtIndex:index];
            RewindPressControl *row = [[[RewindPressControl alloc] initWithFrame:
                CGRectMake(0, y + index * rowH, width, rowH)] autorelease];
            UILabel *rank = RewindLabel(28.0f, RewindWeightRegular, RewindColorTextTertiary());
            rank.frame = CGRectMake(side, 0, RW(40.0f), rowH);
            rank.textAlignment = NSTextAlignmentCenter;
            rank.text = [NSString stringWithFormat:@"%lu", (unsigned long)index + 1];
            [row addSubview:rank];
            RewindArtworkView *art = [[[RewindArtworkView alloc] initWithFrame:
                CGRectMake(side + RW(52.0f), (rowH - artH) * 0.5f, artW, artH)] autorelease];
            [art setCornerRadius:RW(4.0f)];
            [art setURL:track.thumbnailURL];
            [row addSubview:art];
            CGFloat textX = CGRectGetMaxX(art.frame) + RW(12.0f), textW = width - textX - RW(52.0f);
            UILabel *title = RewindLabel(15.0f, RewindWeightMedium, RewindColorText());
            title.frame = CGRectMake(textX, RW(12.0f), textW, RW(40.0f));
            title.numberOfLines = 2;
            title.text = track.title;
            [row addSubview:title];
            UILabel *detail = RewindLabel(13.0f, RewindWeightRegular, RewindColorTextSecondary());
            detail.frame = CGRectMake(textX, RW(54.0f), textW, RW(18.0f));
            detail.text = track.detail.length ? track.detail : track.artist;
            [row addSubview:detail];
            RewindIconButton *more = [RewindIconButton buttonWithIcon:@"more" points:RW(23.0f)];
            more.frame = CGRectMake(width - RW(48.0f), (rowH - RW(44.0f)) * 0.5f, RW(44.0f), RW(44.0f));
            [more setOnTap:^{ [owner showTrackMenu:track]; }];
            [row addSubview:more];
            [row setOnTap:^{ [owner openItem:track inShelf:shelf]; }];
            [_content addSubview:row];
        }
        return y + count * rowH + RW(14.0f);
    }
    RewindTrack *leading = [tracks objectAtIndex:0];
    BOOL video = [leading.resultType isEqualToString:@"Video"];
    CGFloat cardW = floorf(width * (video ? 0.88f : 0.53f)), artH = video ? floorf(cardW * 9.0f / 16.0f) : cardW;
    CGFloat textH = video ? RW(56.0f) : RW(78.0f);
    NSUInteger count = MIN((NSUInteger)10, tracks.count);
    y = [self addHeader:shelf.title caption:shelf.caption atY:y width:width
                   more:tracks.count > count ? ^{ [owner showAllShelf:shelf]; } : nil];
    RewindScrollView *scroll = [[[RewindScrollView alloc] initWithFrame:
        CGRectMake(0, y, width, artH + textH)] autorelease];
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.alwaysBounceHorizontal = YES;
    for (NSUInteger index = 0; index < count; ++index) {
        RewindTrack *track = [tracks objectAtIndex:index];
        RewindPressControl *card = [[[RewindPressControl alloc] initWithFrame:
            CGRectMake(side + index * (cardW + gap), 0, cardW, artH + textH)] autorelease];
        RewindArtworkView *art = [[[RewindArtworkView alloc] initWithFrame:CGRectMake(0, 0, cardW, artH)] autorelease];
        [art setCornerRadius:[track.resultType isEqualToString:RewindResultTypeArtist] ? artH * 0.5f : RW(8.0f)];
        [art setURL:track.thumbnailURL];
        [card addSubview:art];
        UILabel *title = RewindLabel(15.0f, RewindWeightMedium, RewindColorText());
        title.frame = CGRectMake(0, artH + RW(8.0f), cardW, RW(20.0f));
        title.text = track.title;
        [card addSubview:title];
        UILabel *detail = RewindLabel(13.0f, RewindWeightRegular, RewindColorTextSecondary());
        detail.frame = CGRectMake(0, artH + RW(30.0f), cardW, video ? RW(18.0f) : RW(36.0f));
        detail.numberOfLines = video ? 1 : 2;
        detail.text = track.detail.length ? track.detail : track.artist;
        [card addSubview:detail];
        [card setOnTap:^{ [owner openItem:track inShelf:shelf]; }];
        [scroll addSubview:card];
    }
    scroll.contentSize = CGSizeMake(side * 2.0f + count * (cardW + gap) - gap, scroll.bounds.size.height);
    [_content addSubview:scroll];
    return y + scroll.bounds.size.height + RW(22.0f);
}

- (CGFloat)addShelf:(RewindShelf *)shelf atY:(CGFloat)y width:(CGFloat)width compact:(BOOL)compact {
    __block MainVC *owner = self;
    if (_selectedTab == RewindTabExplore) {
        CGFloat laid = [self addExploreShelf:shelf atY:y width:width];
        if (laid >= 0.0f) return laid;
    }
    NSString *caption = shelf.caption;
    if (_selectedTab == RewindTabHome && _personalHome && _pendingShelves.count && shelf == [_pendingShelves objectAtIndex:0])
        caption = caption.length ? [NSString stringWithFormat:@"%@ • %@", RewindL(@"recommendations"), caption]
                                 : RewindL(@"recommendations");
    BOOL grid = _selectedTab == RewindTabHome && _pendingShelves.count && shelf == [_pendingShelves objectAtIndex:0] &&
        RewindTrackCount(shelf.items) >= 4;
    /* a "see all" that opens the same few items already on screen only adds a dead end */
    NSUInteger shown = grid ? 8 + 2 * 9 : (shelf.style == RewindShelfStyleLinks ? 10 : (compact ? 9 : 8));
    y = [self addHeader:shelf.title caption:caption atY:y width:width
                 more:shelf.items.count > shown ? ^{ [owner showAllShelf:shelf]; } : nil];
    if (shelf.style == RewindShelfStyleLinks) {
        CGFloat side = RW(16.0f), gap = RW(8.0f);
        CGFloat cardW = (width - side * 2.0f - gap) * 0.5f;
        NSUInteger count = MIN((NSUInteger)10, shelf.items.count);
        for (NSUInteger index = 0; index < count; ++index) {
            RewindBrowseLink *link = [shelf.items objectAtIndex:index];
            if (![link isKindOfClass:[RewindBrowseLink class]]) continue;
            CGFloat x = side + (index % 2) * (cardW + gap);
            CGFloat top = y + (index / 2) * RW(62.0f);
            RewindPressControl *card = [[[RewindPressControl alloc] initWithFrame:CGRectMake(x, top, cardW, RW(54.0f))] autorelease];
            card.backgroundColor = RewindColorSurfaceHigh();
            card.layer.cornerRadius = RW(5.0f);
            UIView *stripe = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, RW(5.0f), card.bounds.size.height)] autorelease];
            unsigned rgb = link.stripeColor;
            stripe.backgroundColor = rgb ? [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0f
                                                       green:((rgb >> 8) & 255) / 255.0f
                                                        blue:(rgb & 255) / 255.0f alpha:1] : RewindColorTextSecondary();
            [card addSubview:stripe];
            UILabel *title = RewindLabel(14.0f, RewindWeightMedium, RewindColorText());
            title.frame = CGRectMake(RW(14.0f), 0, cardW - RW(22.0f), card.bounds.size.height);
            title.text = link.title;
            [card addSubview:title];
            [card setOnTap:^{ [owner openItem:link inShelf:shelf]; }];
            [_content addSubview:card];
        }
        return y + ((count + 1) / 2) * RW(62.0f) + RW(18.0f);
    }
    /* the first shelf of the home feed, whether it arrives as a list or as cards, is shown the way the real
       app shows its quick picks: pages of three by three squares */
    if (grid) return [self addSquareGridForShelf:shelf atY:y width:width];
    CGFloat rowH = compact ? [RewindTrackRow rowHeight] : RW(202.0f);
    CGFloat cardW = compact ? MIN(width - RW(48.0f), RW(326.0f)) : RW(144.0f);
    CGFloat side = RW(16.0f), gap = compact ? RW(8.0f) : RW(12.0f);
    UIScrollView *scroll = [[[RewindScrollView alloc] initWithFrame:
                             CGRectMake(0, y, width, compact ? rowH * 3.0f : rowH)] autorelease];
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.alwaysBounceHorizontal = YES;
    [_content addSubview:scroll];
    NSUInteger count = MIN(compact ? (NSUInteger)9 : (NSUInteger)8, shelf.items.count);
    for (NSUInteger index = 0; index < count; ++index) {
        id item = [shelf.items objectAtIndex:index];
        if (![item isKindOfClass:[RewindTrack class]]) continue;
        if (compact) {
            NSUInteger page = index / 3, row = index % 3;
            CGFloat x = side + page * (cardW + gap);
            RewindTrackRow *trackRow = [[[RewindTrackRow alloc] initWithFrame:
                                        CGRectMake(x, row * rowH, cardW, rowH)] autorelease];
            trackRow.backgroundColor = RewindColorSurface();
            [trackRow setTrack:item];
            [trackRow setOnTap:^{ [owner openItem:item inShelf:shelf]; }];
            [trackRow setOnMore:^{ [owner showTrackMenu:item]; }];
            [scroll addSubview:trackRow];
        } else {
            CGFloat x = side + index * (cardW + gap);
            RewindPressControl *card = [[[RewindPressControl alloc] initWithFrame:
                                         CGRectMake(x, 0, cardW, rowH)] autorelease];
            RewindArtworkView *art = [[[RewindArtworkView alloc] initWithFrame:CGRectMake(0, 0, cardW, cardW)] autorelease];
            RewindTrack *track = item;
            [art setCornerRadius:[track.resultType isEqualToString:RewindResultTypeArtist] ? cardW * 0.5f : RW(5.0f)];
            [art setURL:track.thumbnailURL];
            [card addSubview:art];
            UILabel *title = RewindLabel(14.0f, RewindWeightMedium, RewindColorText());
            title.frame = CGRectMake(0, cardW + RW(8.0f), cardW, RW(19.0f));
            title.text = track.title;
            [card addSubview:title];
            UILabel *detail = RewindLabel(12.0f, RewindWeightRegular, RewindColorTextSecondary());
            detail.frame = CGRectMake(0, cardW + RW(29.0f), cardW, RW(17.0f));
            detail.text = track.detail.length ? track.detail : track.artist;
            [card addSubview:detail];
            [card setOnTap:^{ [owner openItem:item inShelf:shelf]; }];
            [scroll addSubview:card];
        }
    }
    NSUInteger columns = compact ? (count + 2) / 3 : count;
    scroll.contentSize = CGSizeMake(side * 2 + columns * (cardW + gap), scroll.bounds.size.height);
    return y + scroll.bounds.size.height + RW(22.0f);
}

- (UIView *)gridTileForTrack:(RewindTrack *)track frame:(CGRect)frame shelf:(RewindShelf *)shelf {
    __block MainVC *owner = self;
    RewindPressControl *card = [[[RewindPressControl alloc] initWithFrame:frame] autorelease];
    RewindArtworkView *art = [[[RewindArtworkView alloc] initWithFrame:card.bounds] autorelease];
    [art setCornerRadius:RW(8.0f)];
    [art setURL:track.thumbnailURL];
    [card addSubview:art];
    /* the title sits on a fade so it reads over any cover */
    UIView *shade = [[[UIView alloc] initWithFrame:CGRectMake(0, frame.size.height * 0.45f, frame.size.width,
                                                              frame.size.height * 0.55f)] autorelease];
    shade.userInteractionEnabled = NO;
    CAGradientLayer *fade = [CAGradientLayer layer];
    fade.frame = shade.bounds;
    fade.colors = [NSArray arrayWithObjects:(id)[UIColor colorWithWhite:0.0f alpha:0.0f].CGColor,
                   (id)[UIColor colorWithWhite:0.0f alpha:0.80f].CGColor, nil];
    [shade.layer addSublayer:fade];
    [art addSubview:shade];
    UILabel *title = RewindLabel(14.0f, RewindWeightBold, [UIColor whiteColor]);
    title.frame = CGRectMake(RW(8.0f), frame.size.height - RW(30.0f), frame.size.width - RW(16.0f), RW(22.0f));
    title.text = track.title;
    title.userInteractionEnabled = NO;
    [card addSubview:title];
    [card setOnTap:^{ [owner openItem:track inShelf:shelf]; }];
    return card;
}

/* three dots on a dim wash, the way the real app ends the first page */
- (UIView *)gridMoreTileWithFrame:(CGRect)frame {
    __block MainVC *owner = self;
    RewindPressControl *card = [[[RewindPressControl alloc] initWithFrame:frame] autorelease];
    card.layer.cornerRadius = RW(8.0f);
    card.layer.masksToBounds = YES;
    CAGradientLayer *wash = [CAGradientLayer layer];
    wash.frame = card.bounds;
    wash.colors = [NSArray arrayWithObjects:(id)[UIColor colorWithRed:0.06f green:0.05f blue:0.10f alpha:1.0f].CGColor,
                   (id)[UIColor colorWithRed:0.24f green:0.19f blue:0.40f alpha:1.0f].CGColor, nil];
    wash.startPoint = CGPointMake(0.2f, 0.0f);
    wash.endPoint = CGPointMake(0.9f, 1.0f);
    [card.layer addSublayer:wash];
    CGFloat d = frame.size.width * 0.19f;
    CGFloat centers[3][2] = { {0.26f, 0.27f}, {0.50f, 0.52f}, {0.76f, 0.77f} };
    for (int i = 0; i < 3; ++i) {
        UIView *dot = [[[UIView alloc] initWithFrame:CGRectMake(frame.size.width * centers[i][0] - d * 0.5f,
                                                                frame.size.height * centers[i][1] - d * 0.5f, d, d)] autorelease];
        dot.backgroundColor = [UIColor colorWithRed:0.69f green:0.70f blue:0.90f alpha:1.0f];
        dot.layer.cornerRadius = d * 0.5f;
        dot.userInteractionEnabled = NO;
        [card addSubview:dot];
    }
    card.accessibilityLabel = RewindL(@"menu_mix");
    [card setOnTap:^{ [owner startPersonalMix]; }];
    return card;
}

/* the mix youtube builds from this listener's history ("my supermix", ids start with RDTMAK5uy_) */
- (RewindTrack *)personalMixItem {
    if (!_personalHome) return nil;
    for (RewindShelf *shelf in _shelves)
        for (id item in shelf.items)
            if ([item isKindOfClass:[RewindTrack class]] && [[(RewindTrack *)item playlistID] hasPrefix:@"RDTMAK5uy_"])
                return item;
    return nil;
}

- (void)startPersonalMix {
    [_player setContinuousPlayback:YES];
    RewindTrack *mix = RewindAccountIsSignedIn() ? [self personalMixItem] : nil;
    void (^fromHistory)(void) = ^{
        /* no account mix: the radio of the song heard last, then of the first saved one */
        RewindTrack *seed = nil;
        for (id item in [RewindRecentTracks() arrayByAddingObjectsFromArray:_libraryTracks ?: [NSArray array]])
            if ([item isKindOfClass:[RewindTrack class]] && [(RewindTrack *)item videoID].length) { seed = item; break; }
        if (!seed) {
            RewindShowToast(self.view, RewindL(@"account_mix_failed"), RewindBottomHeight());
            return;
        }
        [self openMix:seed];
    };
    if (!mix) {
        fromHistory();
        return;
    }
    RewindAccountLoadPlaylistTracks(mix.playlistID, ^(NSArray *tracks, NSError *error) {
        tracks = RewindPlayableTracks(tracks);
        if (error || !tracks.count) {
            fromHistory();
            return;
        }
        RewindRecordTrack([tracks objectAtIndex:0]);
        [_player setQueue:tracks selectedIndex:0 usingAPI:_api];
    });
}

- (CGFloat)addSquareGridForShelf:(RewindShelf *)shelf atY:(CGFloat)y width:(CGFloat)width {
    NSMutableArray *tracks = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^take)(id) = ^(id item) {
        if (![item isKindOfClass:[RewindTrack class]] || tracks.count >= 8 + 2 * 9) return;
        RewindTrack *track = item;
        NSString *key = track.videoID.length ? track.videoID : track.playlistID;
        if (!key.length || [seen containsObject:key]) return;
        [seen addObject:key];
        [tracks addObject:track];
    };
    for (id item in shelf.items) take(item);
    /* a shelf rarely brings enough songs for three full pages: the songs of the shelves below it and then the
       listening history fill the rest, so the grid is never left with empty squares */
    for (RewindShelf *other in _pendingShelves) {
        if (other == shelf || other.style == RewindShelfStyleLinks) continue;
        for (RewindTrack *song in RewindPlayableTracks(other.items))
            if (![song.resultType isEqualToString:RewindResultTypeMix]) take(song);
    }
    for (id item in RewindRecentTracks()) take(item);
    for (id item in _libraryTracks) take(item);
    /* the tiles queue one another: a tap plays the squares as a list, wherever each came from */
    RewindShelf *queueShelf = [[[RewindShelf alloc] initWithTitle:shelf.title items:tracks] autorelease];
    CGFloat side = RW(16.0f), gap = RW(8.0f);
    CGFloat tile = floorf((width - side * 2.0f - gap * 2.0f) / 3.0f);
    CGFloat height = tile * 3.0f + gap * 2.0f;
    /* the first page gives its ninth square to the mixes tile, later pages hold nine tracks */
    NSUInteger count = MIN((NSUInteger)(8 + 2 * 9), tracks.count);
    NSUInteger pages = count <= 8 ? 1 : 1 + (count - 8 + 8) / 9;
    RewindScrollView *scroll = [[[RewindScrollView alloc] initWithFrame:CGRectMake(0, y, width, height)] autorelease];
    scroll.tag = 7000 + 2 * (NSInteger)_builtShelfCount;
    scroll.pagingEnabled = YES;
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.alwaysBounceHorizontal = pages > 1;
    scroll.delegate = self;
    scroll.contentSize = CGSizeMake(width * pages, height);
    for (NSUInteger index = 0; index < count; ++index) {
        NSUInteger page = index < 8 ? 0 : 1 + (index - 8) / 9;
        NSUInteger slot = index < 8 ? index : (index - 8) % 9;
        CGRect frame = CGRectMake(page * width + side + (slot % 3) * (tile + gap), (slot / 3) * (tile + gap), tile, tile);
        [scroll addSubview:[self gridTileForTrack:[tracks objectAtIndex:index] frame:frame shelf:queueShelf]];
    }
    CGRect moreFrame = CGRectMake(side + 2 * (tile + gap), 2 * (tile + gap), tile, tile);
    [scroll addSubview:[self gridMoreTileWithFrame:moreFrame]];
    [_content addSubview:scroll];
    RewindPageDots *dots = [[[RewindPageDots alloc] initWithFrame:CGRectMake(0, y + height + RW(8.0f), width, RW(14.0f))] autorelease];
    dots.tag = scroll.tag + 1;
    [dots setCount:pages];
    [_content addSubview:dots];
    /* the wash runs on past the squares and under the next section title, the way the real feed does */
    CGFloat end = y + height + RW(8.0f) + RW(14.0f) + RW(22.0f);
    _ambientHeight = end + RW(110.0f);
    return end;
}

- (CGFloat)buildLibraryFromY:(CGFloat)y width:(CGFloat)width {
    y = [self addHeader:RewindL(@"library") caption:nil atY:y width:width more:nil];
    NSArray *titles = [NSArray arrayWithObjects:RewindL(@"liked_music"), RewindL(@"playlists"),
                       RewindL(@"recent"), RewindL(@"favorites"), RewindL(@"downloads"), nil];
    NSArray *icons = [NSArray arrayWithObjects:@"thumb-up", @"playlist-add", @"history", @"save", @"download", nil];
    NSUInteger playlistCount = RewindPlaylistNames().count +
                               (RewindAccountIsSignedIn() ? RewindAccountCachedPlaylists().count : 0);
    NSArray *details = [NSArray arrayWithObjects:
                        [NSString stringWithFormat:RewindL(@"tracks_count"),
                                                   (unsigned long)RewindAccountCachedLikedTrackCount()],
                        [NSString stringWithFormat:RewindL(@"playlists_count"), (unsigned long)playlistCount],
                        [NSString stringWithFormat:RewindL(@"tracks_count"), (unsigned long)RewindRecentTracks().count],
                        [NSString stringWithFormat:RewindL(@"tracks_count"), (unsigned long)_libraryTracks.count],
                        [NSString stringWithFormat:RewindL(@"tracks_count"), (unsigned long)RewindDownloadedTracks().count], nil];
    __block MainVC *owner = self;
    for (NSUInteger index = 0; index < titles.count; ++index) {
        RewindPressControl *row = [[[RewindPressControl alloc] initWithFrame:
                                    CGRectMake(0, y, width, RW(72.0f))] autorelease];
        row.pressScales = NO;
        UIView *plate = [[[UIView alloc] initWithFrame:CGRectMake(RW(16.0f), RW(8.0f), RW(56.0f), RW(56.0f))] autorelease];
        plate.backgroundColor = RewindColorSurface();
        plate.layer.cornerRadius = RW(4.0f);
        plate.userInteractionEnabled = NO;
        [row addSubview:plate];
        UIImageView *icon = [[[UIImageView alloc] initWithFrame:CGRectMake(RW(30.0f), RW(22.0f), RW(28.0f), RW(28.0f))] autorelease];
        icon.image = RewindIcon([icons objectAtIndex:index], RW(26.0f), RewindColorText());
        [row addSubview:icon];
        UILabel *label = RewindLabel(16.0f, RewindWeightMedium, RewindColorText());
        label.text = [titles objectAtIndex:index];
        label.frame = CGRectMake(RW(84.0f), RW(14.0f), width - RW(140.0f), RW(24.0f));
        [row addSubview:label];
        UILabel *detail = RewindLabel(14.0f, RewindWeightRegular, RewindColorTextSecondary());
        detail.text = [details objectAtIndex:index];
        detail.frame = CGRectMake(RW(84.0f), RW(39.0f), width - RW(140.0f), RW(20.0f));
        [row addSubview:detail];
        UIImageView *more = [[[UIImageView alloc] initWithFrame:CGRectMake(width - RW(44.0f), RW(24.0f), RW(24.0f), RW(24.0f))] autorelease];
        more.image = RewindIcon(@"chevron-right", RW(20.0f), RewindColorTextSecondary());
        [row addSubview:more];
        [row setOnTap:^{ [owner openLibrarySection:index]; }];
        [_content addSubview:row];
        y += RW(72.0f);
    }
    if (_libraryTracks.count) {
        RewindShelf *saved = [[[RewindShelf alloc] initWithTitle:RewindL(@"favorites") caption:nil
                                                           items:_libraryTracks style:RewindShelfStyleList] autorelease];
        y += RW(18.0f);
        y = [self addShelf:saved atY:y width:width compact:YES];
    }
    return y;
}

- (void)openLibrarySection:(NSUInteger)section {
    if (section == 1) {
        RewindPlaylistsVC *playlists = [[[RewindPlaylistsVC alloc] initWithPlayer:_player api:_api] autorelease];
        [self.navigationController setNavigationBarHidden:NO animated:YES];
        [self.navigationController pushViewController:playlists animated:YES];
        return;
    }
    RewindLibraryMode mode = section == 0 ? RewindLibraryModeLiked :
                             section == 2 ? RewindLibraryModeRecent :
                             section == 4 ? RewindLibraryModeDownloads : RewindLibraryModeFavorites;
    RewindLibraryVC *library = [[[RewindLibraryVC alloc] initWithPlayer:_player api:_api mode:mode] autorelease];
    [self.navigationController setNavigationBarHidden:NO animated:YES];
    [self.navigationController pushViewController:library animated:YES];
}

- (void)downloadsChanged:(NSNotification *)note {
    (void)note;
    if (_selectedTab == RewindTabLibrary) [self rebuildContent];
}

- (void)showSearch {
    if (_searchPanel) {
        _searchPanel.hidden = NO;
        [_searchField becomeFirstResponder];
        return;
    }
    _searchPanel = [[UIView alloc] initWithFrame:self.view.bounds];
    _searchPanel.backgroundColor = RewindColorBackground();
    _searchPanel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_searchPanel];
    RewindIconButton *back = [RewindIconButton buttonWithIcon:@"back" points:RW(24.0f)];
    back.tag = 301;
    __block MainVC *owner = self;
    [back setOnTap:^{ [owner closeSearch]; }];
    [_searchPanel addSubview:back];
    UIView *fieldBackground = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    fieldBackground.tag = 302;
    fieldBackground.backgroundColor = RewindColorSurfaceHigh();
    fieldBackground.layer.cornerRadius = RW(22.0f);
    [_searchPanel addSubview:fieldBackground];
    _searchField = [[RewindSearchField alloc] initWithFrame:CGRectZero];
    _searchField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _searchField.delegate = self;
    _searchField.returnKeyType = UIReturnKeySearch;
    _searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    _searchField.textColor = RewindColorText();
    /* the caret colour is ios 7 api that the armv7 sdk does not declare */
    SEL caretTint = NSSelectorFromString(@"setTintColor:");
    if ([_searchField respondsToSelector:caretTint])
        [_searchField performSelector:caretTint withObject:RewindColorText()];
    _searchField.font = RewindFont(16.0f, RewindWeightRegular);
    _searchField.placeholder = RewindL(@"search_placeholder");
    [_searchField addTarget:self action:@selector(searchChanged:) forControlEvents:UIControlEventEditingChanged];
    [fieldBackground addSubview:_searchField];
    _searchTable = [[RewindTableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _searchTable.dataSource = self;
    _searchTable.delegate = self;
    _searchTable.backgroundColor = RewindColorBackground();
    _searchTable.separatorStyle = UITableViewCellSeparatorStyleNone;
    [_searchPanel addSubview:_searchTable];
    _searchHint = [RewindLabel(13.0f, RewindWeightRegular, RewindColorTextSecondary()) retain];
    _searchHint.text = RewindL(@"recent_searches");
    [_searchPanel addSubview:_searchHint];
    [self restoreRecentSearches];
    [self layoutSearch];
    [_searchField becomeFirstResponder];
}

- (void)layoutSearch {
    if (!_searchPanel || _searchPanel.hidden) return;
    CGFloat w = _searchPanel.bounds.size.width;
    CGFloat top = RewindStatusBarInset();
    CGFloat h = top + RW(56.0f);
    [_searchPanel viewWithTag:301].frame = CGRectMake(0, top, RW(52.0f), RW(56.0f));
    UIView *background = [_searchPanel viewWithTag:302];
    background.frame = CGRectMake(RW(52.0f), top + RW(7.0f), w - RW(68.0f), RW(42.0f));
    _searchField.frame = CGRectInset(background.bounds, RW(14.0f), 0);
    _searchHint.frame = CGRectMake(RW(18.0f), h + RW(8.0f), w - RW(36.0f), RW(26.0f));
    _searchTable.frame = CGRectMake(0, CGRectGetMaxY(_searchHint.frame), w,
                                    _searchPanel.bounds.size.height - CGRectGetMaxY(_searchHint.frame));
}

- (void)closeSearch {
    [_searchField resignFirstResponder];
    _searchPanel.hidden = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(loadSuggestions) object:nil];
    ++_searchRequest;
}

- (void)restoreRecentSearches {
    NSArray *history = [[NSUserDefaults standardUserDefaults] objectForKey:@"RewindSearchHistory"];
    if (![history isKindOfClass:[NSArray class]]) history = [NSArray array];
    [_suggestions release];
    _suggestions = [history copy];
    _showingResults = NO;
    _searchHint.text = RewindL(@"recent_searches");
    [_searchTable reloadData];
}

- (void)searchChanged:(UITextField *)field {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(loadSuggestions) object:nil];
    ++_searchRequest;
    NSString *query = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!query.length) {
        [self restoreRecentSearches];
        return;
    }
    _showingResults = NO;
    _searchHint.text = RewindL(@"search_suggestions");
    [self performSelector:@selector(loadSuggestions) withObject:nil afterDelay:0.28];
}

- (void)loadSuggestions {
    NSString *query = [_searchField.text copy];
    NSUInteger request = _searchRequest;
    [_api searchSuggestions:query completion:^(NSArray *suggestions, NSError *error) {
        if (request != _searchRequest || _searchPanel.hidden || ![_searchField.text isEqualToString:query]) return;
        if (error) NSLog(@"rewind: search suggestions: %@", error);
        [_suggestions release];
        _suggestions = [suggestions copy];
        [_searchTable reloadData];
    }];
    [query release];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [self executeSearch:field.text];
    return YES;
}

- (void)executeSearch:(NSString *)text {
    NSString *query = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!query.length) return;
    _searchField.text = query;
    [_searchField resignFirstResponder];
    NSMutableArray *history = [NSMutableArray array];
    [history addObject:query];
    NSArray *old = [[NSUserDefaults standardUserDefaults] objectForKey:@"RewindSearchHistory"];
    if ([old isKindOfClass:[NSArray class]]) for (NSString *entry in old) {
        if (![entry isKindOfClass:[NSString class]] || [entry isEqualToString:query]) continue;
        [history addObject:entry];
        if (history.count >= 12) break;
    }
    [[NSUserDefaults standardUserDefaults] setObject:history forKey:@"RewindSearchHistory"];
    NSUInteger request = ++_searchRequest;
    _showingResults = YES;
    _searchHint.text = RewindL(@"searching");
    [_searchResults release]; _searchResults = nil;
    [_searchTable reloadData];
    [_api search:query completion:^(NSArray *tracks, NSError *error) {
        if (request != _searchRequest || _searchPanel.hidden) return;
        if (error) {
            _searchHint.text = RewindFriendlyError(error);
            NSLog(@"rewind: search: %@", error);
        } else {
            _searchHint.text = RewindL(@"search_results");
            [_searchResults release];
            _searchResults = [tracks copy];
        }
        [_searchTable reloadData];
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)(_showingResults ? _searchResults.count : _suggestions.count);
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return _showingResults ? [RewindTrackRow rowHeight] : RW(52.0f);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_showingResults) {
        static NSString *resultID = @"result";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:resultID];
        if (!cell) {
            cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:resultID] autorelease];
            cell.backgroundColor = RewindColorBackground();
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            RewindTrackRow *row = [[[RewindTrackRow alloc] initWithFrame:CGRectZero] autorelease];
            row.tag = 11;
            row.pressScales = NO;
            [cell.contentView addSubview:row];
        }
        RewindTrack *track = [_searchResults objectAtIndex:(NSUInteger)indexPath.row];
        RewindTrackRow *row = (RewindTrackRow *)[cell.contentView viewWithTag:11];
        row.frame = CGRectMake(0, 0, tableView.bounds.size.width, [RewindTrackRow rowHeight]);
        [row setTrack:track];
        __block MainVC *owner = self;
        [row setOnTap:^{ [owner playSearchTrack:track]; }];
        [row setOnMore:^{ [owner showTrackMenu:track]; }];
        return cell;
    }
    static NSString *suggestionID = @"suggestion";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:suggestionID];
    if (!cell) cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:suggestionID] autorelease];
    cell.backgroundColor = RewindColorBackground();
    cell.textLabel.textColor = RewindColorText();
    cell.textLabel.font = RewindFont(15.0f, RewindWeightRegular);
    cell.textLabel.text = [_suggestions objectAtIndex:(NSUInteger)indexPath.row];
    cell.imageView.image = RewindIcon(@"history", RW(20.0f), RewindColorTextSecondary());
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_showingResults) [self playSearchTrack:[_searchResults objectAtIndex:(NSUInteger)indexPath.row]];
    else [self executeSearch:[_suggestions objectAtIndex:(NSUInteger)indexPath.row]];
}

- (void)playSearchTrack:(RewindTrack *)track {
    if (track.isPlaylist || [track.resultType isEqualToString:RewindResultTypeArtist] ||
        [track.resultType isEqualToString:RewindResultTypeAlbum]) {
        RewindShelf *shelf = [[[RewindShelf alloc] initWithTitle:@"" items:_searchResults] autorelease];
        [self closeSearch];
        [self openItem:track inShelf:shelf];
        return;
    }
    if (!track.videoID.length) return;
    NSMutableArray *playable = [NSMutableArray array];
    NSUInteger selected = NSNotFound;
    for (RewindTrack *candidate in _searchResults) {
        if (!candidate.videoID.length || candidate.isPlaylist ||
            [candidate.resultType isEqualToString:RewindResultTypeArtist] ||
            [candidate.resultType isEqualToString:RewindResultTypeAlbum]) continue;
        if (candidate == track) selected = playable.count;
        [playable addObject:candidate];
    }
    if (selected == NSNotFound) return;
    RewindRecordTrack(track);
    [_player setQueue:playable selectedIndex:(NSInteger)selected usingAPI:_api];
    [self closeSearch];
}

- (void)focusSearch:(NSNotification *)note { (void)note; [self showSearch]; }

- (void)showTrackMenu:(RewindTrack *)track {
    if (!track) return;
    [_actionTrack release];
    _actionTrack = [track retain];
    __block MainVC *owner = self;
    RewindSheet *sheet = [[[RewindSheet alloc] initWithFrame:self.view.bounds] autorelease];
    [sheet setHeaderTitle:track.title subtitle:RewindTrackArtistText(track) accessories:nil];
    [sheet setTiles:[NSArray arrayWithObjects:
        [RewindSheetItem itemWithIcon:@"play-next" title:RewindL(@"menu_play_next")
                                action:^{ [owner->_player enqueueTrack:track usingAPI:owner->_api afterCurrent:YES];
                                          RewindShowToast(owner.view, RewindL(@"menu_play_next_added"), RewindBottomHeight()); }],
        [RewindSheetItem itemWithIcon:@"playlist-add" title:RewindL(@"menu_add_playlist")
                                action:^{ [owner showPlaylistPicker]; }],
        [RewindSheetItem itemWithIcon:@"share" title:RewindL(@"menu_share")
                                action:^{ [owner shareTrack:track]; }], nil]];
    [sheet setItems:[NSArray arrayWithObjects:
        [RewindSheetItem itemWithIcon:@"mix" title:RewindL(@"menu_mix")
                                action:^{ [owner openMix:track]; }],
        [RewindSheetItem itemWithIcon:@"queue-add" title:RewindL(@"menu_queue")
                                action:^{ [owner->_player enqueueTrack:track usingAPI:owner->_api afterCurrent:NO];
                                          RewindShowToast(owner.view, RewindL(@"menu_queued"), RewindBottomHeight()); }],
        [RewindSheetItem itemWithIcon:@"save" title:RewindL(@"menu_save_library")
                                action:^{ [owner toggleSaved:track]; }],
        [RewindSheetItem itemWithIcon:@"download" title:RewindL(@"menu_download")
                                action:^{ [owner downloadTrack:track]; }],
        [RewindSheetItem itemWithIcon:@"album" title:RewindL(@"menu_album")
                                action:^{ RewindPushAlbum(owner, track, owner->_api, owner->_player); }],
        [RewindSheetItem itemWithIcon:@"artist" title:RewindL(@"menu_artist")
                                action:^{ RewindPushArtistProfile(owner, track, owner->_api, owner->_player); }], nil]];
    [sheet showInView:self.view];
}

- (void)openMix:(RewindTrack *)track {
    [_player setContinuousPlayback:YES];
    if (!RewindAccountIsSignedIn()) {
        [_api relatedForTrack:track completion:^(NSArray *shelves, NSArray *links, NSError *error) {
            (void)links;
            RewindShelf *songs = RewindFirstSongShelf(shelves, nil);
            NSArray *tracks = RewindPlayableTracks(songs.items);
            if (!tracks.count) {
                RewindShowToast(self.view, RewindFriendlyError(error) ?: RewindL(@"account_mix_failed"), RewindBottomHeight());
                return;
            }
            [_player setQueue:tracks selectedIndex:0 usingAPI:_api];
        }];
        return;
    }
    RewindAccountLoadMix(track, ^(NSArray *tracks, NSError *error) {
        if (error || !tracks.count) {
            RewindShowToast(self.view, RewindFriendlyError(error) ?: RewindL(@"account_mix_failed"), RewindBottomHeight());
            return;
        }
        [_player setQueue:tracks selectedIndex:0 usingAPI:_api];
    });
}

- (void)toggleSaved:(RewindTrack *)track {
    BOOL saved = RewindTrackIsSaved(track);
    if (saved) RewindRemoveTrack(track);
    else RewindSaveTrack(track);
    RewindShowToast(self.view, saved ? RewindL(@"removed_library") : RewindL(@"added_library"),
                    RewindBottomHeight());
    if (_selectedTab == RewindTabLibrary) [self loadLibrary];
}

- (void)shareTrack:(RewindTrack *)track {
    NSString *url = track.videoID.length ? [@"https://youtu.be/" stringByAppendingString:track.videoID] : @"";
    Class activity = NSClassFromString(@"UIActivityViewController");
    if (activity) {
        id controller = [[[activity alloc] initWithActivityItems:[NSArray arrayWithObject:url]
                                             applicationActivities:nil] autorelease];
        [self presentViewController:controller animated:YES completion:nil];
    } else {
        [UIPasteboard generalPasteboard].string = url;
        RewindShowToast(self.view, RewindL(@"menu_share_copied"), RewindBottomHeight());
    }
}

- (void)showPlaylistPicker {
    if (!_actionTrack) return;
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:RewindL(@"menu_add_playlist")
                                                     message:_actionTrack.title delegate:self
                                           cancelButtonTitle:RewindL(@"cancel")
                                           otherButtonTitles:RewindL(@"new_playlist"), nil] autorelease];
    alert.tag = RewindAlertPlaylist;
    for (NSString *title in RewindPlaylistPickerTitles()) [alert addButtonWithTitle:title];
    [alert show];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
    if (index == alert.cancelButtonIndex) return;
    if (alert.tag == RewindAlertPlaylist) {
        if (index == 1) {
            UIAlertView *create = [[[UIAlertView alloc] initWithTitle:RewindL(@"new_playlist")
                                                               message:nil delegate:self
                                                     cancelButtonTitle:RewindL(@"cancel")
                                                     otherButtonTitles:RewindL(@"create"), nil] autorelease];
            create.alertViewStyle = UIAlertViewStylePlainTextInput;
            create.tag = RewindAlertCreatePlaylist;
            [create show];
            return;
        }
        NSString *title = [alert buttonTitleAtIndex:index];
        RewindAddTrackToPickedPlaylist(_actionTrack, title, ^(NSError *error) {
            RewindShowToast(self.view, error ? RewindFriendlyError(error) : RewindL(@"added_to_playlist"),
                            RewindBottomHeight());
        });
    } else if (alert.tag == RewindAlertCreatePlaylist) {
        NSString *title = [[[alert textFieldAtIndex:0] text]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!title.length) return;
        RewindCreatePlaylistWithTrack(title, _actionTrack, ^(NSError *error) {
            RewindShowToast(self.view, error ? error.localizedDescription : RewindL(@"added_to_playlist"),
                            RewindBottomHeight());
        });
    }
}

- (void)showAllShelf:(RewindShelf *)shelf {
    RewindShelfListVC *list = [[[RewindShelfListVC alloc] initWithShelf:shelf owner:self] autorelease];
    [self.navigationController setNavigationBarHidden:NO animated:YES];
    [self.navigationController pushViewController:list animated:YES];
}

- (void)downloadTrack:(RewindTrack *)track {
    if (!track.videoID.length) return;
    RewindShowToast(self.view, RewindL(@"menu_download_started"), RewindBottomHeight());
    [_api audioURLForTrack:track completion:^(NSURL *url, NSError *error) {
        if (!url || error) {
            RewindShowToast(self.view, RewindFriendlyError(error) ?: RewindL(@"menu_download_failed"),
                            RewindBottomHeight());
            return;
        }
        RewindStartDownload(url, track.videoID, ^(NSError *downloadError) {
            RewindShowToast(self.view, downloadError ? RewindFriendlyError(downloadError)
                                                      : RewindL(@"menu_download_done"), RewindBottomHeight());
        });
    }];
}

- (BOOL)canBecomeFirstResponder { return YES; }

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    if (event.type != UIEventTypeRemoteControl) return;
    switch (event.subtype) {
        case UIEventSubtypeRemoteControlPlay: case UIEventSubtypeRemoteControlPause:
        case UIEventSubtypeRemoteControlTogglePlayPause: [_player toggle]; break;
        case UIEventSubtypeRemoteControlNextTrack: [_player nextTrack]; break;
        case UIEventSubtypeRemoteControlPreviousTrack: [_player previousTrack]; break;
        default: break;
    }
}

@end

@implementation RewindShelfListVC

- (id)initWithShelf:(RewindShelf *)shelf owner:(MainVC *)owner {
    self = [super init];
    if (!self) return nil;
    _shelf = [shelf retain];
    _owner = owner;
    self.title = shelf.title;
    return self;
}

- (void)dealloc {
    _table.delegate = nil;
    _table.dataSource = nil;
    [_table release];
    [_shelf release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = RewindColorBackground();
    self.view = view;
}

- (void)backPressed {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    RewindStyleNavigationBar(self.navigationController.navigationBar);
    /* mainvc hides its own bar and never sets a title, so without this the
       system back button falls back to the untranslated literal "Back" */
    self.navigationItem.leftBarButtonItem = RewindBackBarItem(self, @selector(backPressed));
    _table = [[RewindTableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.backgroundColor = RewindColorBackground();
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.delegate = self;
    _table.dataSource = self;
    [self.view addSubview:_table];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)_shelf.items.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return [RewindTrackRow rowHeight];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"shelf-row";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse] autorelease];
        cell.backgroundColor = RewindColorBackground();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        RewindTrackRow *row = [[[RewindTrackRow alloc] initWithFrame:CGRectZero] autorelease];
        row.tag = 11;
        [cell.contentView addSubview:row];
    }
    id item = [_shelf.items objectAtIndex:(NSUInteger)indexPath.row];
    if ([item isKindOfClass:[RewindTrack class]]) {
        RewindTrackRow *row = (RewindTrackRow *)[cell.contentView viewWithTag:11];
        row.hidden = NO;
        row.frame = CGRectMake(0, 0, tableView.bounds.size.width, [RewindTrackRow rowHeight]);
        [row setTrack:item];
        __block MainVC *owner = _owner;
        RewindShelf *shelf = _shelf;
        [row setOnTap:^{ [owner openItem:item inShelf:shelf]; }];
        [row setOnMore:^{ [owner showTrackMenu:item]; }];
        cell.textLabel.text = nil;
    } else {
        [cell.contentView viewWithTag:11].hidden = YES;
        cell.textLabel.textColor = RewindColorText();
        cell.textLabel.font = RewindFont(16.0f, RewindWeightMedium);
        cell.textLabel.text = [item isKindOfClass:[RewindBrowseLink class]] ? [item title] : @"";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [_owner openItem:[_shelf.items objectAtIndex:(NSUInteger)indexPath.row] inShelf:_shelf];
}

@end

@implementation RewindBrowsePageVC

- (id)initWithLink:(RewindBrowseLink *)link owner:(MainVC *)owner api:(RewindAPI *)api {
    self = [super init];
    if (!self) return nil;
    _link = [link retain];
    _owner = owner;
    _api = [api retain];
    self.title = link.title;
    return self;
}

- (void)dealloc {
    ++_request;
    _table.delegate = nil;
    _table.dataSource = nil;
    [_table release];
    [_spinner release];
    [_shelves release];
    [_link release];
    [_api release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = RewindColorBackground();
    self.view = view;
}

- (void)backPressed {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    RewindStyleNavigationBar(self.navigationController.navigationBar);
    self.navigationItem.leftBarButtonItem = RewindBackBarItem(self, @selector(backPressed));
    _table = [[RewindTableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.backgroundColor = RewindColorBackground();
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.delegate = self;
    _table.dataSource = self;
    [self.view addSubview:_table];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.center = CGPointMake(self.view.bounds.size.width * 0.5f, RW(120.0f));
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:_spinner];
    [_spinner startAnimating];
    NSUInteger request = ++_request;
    [_api browseShelves:_link.browseID params:_link.params completion:^(NSArray *shelves, NSArray *chips, NSError *error) {
        (void)chips;
        if (request != _request) return;
        [_spinner stopAnimating];
        if (error) RewindShowToast(self.view, RewindFriendlyError(error), RewindBottomHeight());
        NSMutableArray *kept = [NSMutableArray array];
        for (RewindShelf *shelf in shelves)
            if (shelf.items.count) [kept addObject:shelf];
        [_shelves release];
        _shelves = [kept copy];
        [_table reloadData];
    }];
}

/* a shelf of a page is long, the first rows of it show and the rest stays one tap away on its own screen */
static const NSUInteger RewindBrowsePageRows = 8;

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (NSInteger)_shelves.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return (NSInteger)MIN(RewindBrowsePageRows, [[_shelves objectAtIndex:(NSUInteger)section] items].count);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return [[[_shelves objectAtIndex:(NSUInteger)section] title] length] ? RW(44.0f) : 0.0f;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *text = [[_shelves objectAtIndex:(NSUInteger)section] title];
    if (!text.length) return nil;
    UIView *header = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, RW(44.0f))] autorelease];
    header.backgroundColor = RewindColorBackground();
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectMake(RW(16.0f), RW(10.0f),
                                                                 tableView.bounds.size.width - RW(32.0f), RW(30.0f))] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.textColor = RewindColorText();
    label.font = RewindFont(20.0f, RewindWeightBold);
    label.text = text;
    [header addSubview:label];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return [RewindTrackRow rowHeight];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"browse-row";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse] autorelease];
        cell.backgroundColor = RewindColorBackground();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        RewindTrackRow *row = [[[RewindTrackRow alloc] initWithFrame:CGRectZero] autorelease];
        row.tag = 11;
        [cell.contentView addSubview:row];
    }
    RewindShelf *shelf = [_shelves objectAtIndex:(NSUInteger)indexPath.section];
    id item = [shelf.items objectAtIndex:(NSUInteger)indexPath.row];
    RewindTrackRow *row = (RewindTrackRow *)[cell.contentView viewWithTag:11];
    if ([item isKindOfClass:[RewindTrack class]]) {
        row.hidden = NO;
        row.frame = CGRectMake(0, 0, tableView.bounds.size.width, [RewindTrackRow rowHeight]);
        [row setTrack:item];
        __block MainVC *owner = _owner;
        [row setOnTap:^{ [owner openItem:item inShelf:shelf]; }];
        [row setOnMore:^{ [owner showTrackMenu:item]; }];
        cell.textLabel.text = nil;
    } else {
        row.hidden = YES;
        cell.textLabel.textColor = RewindColorText();
        cell.textLabel.font = RewindFont(16.0f, RewindWeightMedium);
        cell.textLabel.text = [item isKindOfClass:[RewindBrowseLink class]] ? [item title] : @"";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    RewindShelf *shelf = [_shelves objectAtIndex:(NSUInteger)indexPath.section];
    [_owner openItem:[shelf.items objectAtIndex:(NSUInteger)indexPath.row] inShelf:shelf];
}

@end
