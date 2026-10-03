#import "artist_vc.h"

#import <QuartzCore/QuartzCore.h>

#import "rewind_theme.h"
#import "rewind_ui.h"
#import "rewind_l10n.h"
#import "library_vc.h"
#import "rewind_api.h"
#import "rewind_player.h"
#import "rewind_account.h"
#import "playlist_vc.h"
#import "player_vc.h"

enum { RewindArtistAlertPlaylist = 9601, RewindArtistAlertCreatePlaylist = 9602 };

/* youtube sometimes serves channel avatars as scheme-relative urls */
static NSString *RewindArtistImageURL(NSString *url) {
    if (!url.length) return nil;
    if ([url hasPrefix:@"//"])
        return [NSString stringWithFormat:@"https:%@", url];
    return url;
}

static UILabel *RewindArtistLabel(CGFloat size, RewindWeight weight, UIColor *color) {
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.font = RewindFont(size, weight);
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

/* the artist page's own song list drives the header play/radio buttons, not a carousel */
static RewindShelf *RewindArtistTopSongsShelf(NSArray *shelves) {
    for (RewindShelf *shelf in shelves) {
        if (shelf.style != RewindShelfStyleList) continue;
        for (id item in shelf.items)
            if ([item isKindOfClass:[RewindTrack class]] && ((RewindTrack *)item).videoID.length)
                return shelf;
    }
    return nil;
}

static NSArray *RewindArtistPlayableTracks(NSArray *items) {
    NSMutableArray *tracks = [NSMutableArray array];
    for (id item in items) {
        if (![item isKindOfClass:[RewindTrack class]]) continue;
        RewindTrack *track = item;
        if (track.videoID.length && !track.isPlaylist) [tracks addObject:track];
    }
    return tracks;
}

@interface RewindArtistVC ()
- (void)applyTheme:(NSNotification *)note;
- (void)languageChanged:(NSNotification *)note;
- (void)resolveArtist;
- (void)loadArtistPage;
- (void)applyAvatarURL:(NSString *)url;
- (void)rebuildContent;
- (CGFloat)addSectionTitle:(NSString *)title atY:(CGFloat)y width:(CGFloat)width;
- (CGFloat)addShelf:(RewindShelf *)shelf atY:(CGFloat)y width:(CGFloat)width;
- (void)openItem:(id)item inShelf:(RewindShelf *)shelf;
- (void)playFromTopSongs;
- (void)radioPressed;
- (void)subscribePressed;
- (void)startRadioFromTrack:(RewindTrack *)seed;
- (void)showTrackMenu:(RewindTrack *)track;
- (void)showPlaylistPicker;
- (void)shareTrack:(RewindTrack *)track;
- (void)refreshPlaying:(NSNotification *)note;
- (void)backPressed;
@end

@implementation RewindArtistVC

- (id)initWithArtist:(NSString *)artist
          artworkURL:(NSString *)artworkURL
                 api:(RewindAPI *)api
             player:(RewindPlayer *)player
          seedTrack:(RewindTrack *)seedTrack {
    self = [super init];
    if (!self) return nil;
    _artistName = [artist copy];
    _artistID = [seedTrack.artistID copy];
    _artworkURL = [RewindArtistImageURL(artworkURL) copy];
    _api = [api retain];
    _player = [player retain];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_artistName release];
    [_artistID release];
    [_artworkURL release];
    [_subscriberText release];
    [_api release];
    [_player release];
    [_shelves release];
    [_menuTrack release];
    [_headerView release];
    [_headerArt release];
    [_headerScrimTop release];
    [_headerScrimBottom release];
    [_backBacking release];
    [_backButton release];
    [_radioButton release];
    [_playButton release];
    [_subscribeButton release];
    [_nameLabel release];
    [_subLabel release];
    [_content release];
    [_status release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = RewindColorCanvas();
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _content = [[RewindScrollView alloc] initWithFrame:CGRectZero];
    _content.showsVerticalScrollIndicator = NO;
    _content.delegate = self;
    [self.view addSubview:_content];

    /* lives inside the scroll content, not pinned, so it scrolls away and stretches
       on pull down the way the real app's artist photo does */
    _headerView = [[UIView alloc] initWithFrame:CGRectZero];
    _headerView.clipsToBounds = NO;
    [_content addSubview:_headerView];

    _headerArt = [[RewindArtworkView alloc] initWithFrame:CGRectZero];
    [_headerView addSubview:_headerArt];

    _headerScrimTop = [[CAGradientLayer layer] retain];
    _headerScrimTop.colors = [NSArray arrayWithObjects:
                              (id)[UIColor colorWithWhite:0.0f alpha:0.55f].CGColor,
                              (id)[UIColor colorWithWhite:0.0f alpha:0.0f].CGColor, nil];
    [_headerView.layer addSublayer:_headerScrimTop];

    _headerScrimBottom = [[CAGradientLayer layer] retain];
    [_headerView.layer addSublayer:_headerScrimBottom];

    _nameLabel = [RewindArtistLabel(28.0f, RewindWeightBold, RewindColorText()) retain];
    _nameLabel.numberOfLines = 2;
    _nameLabel.text = _artistName;
    [_headerView addSubview:_nameLabel];

    _subLabel = [RewindArtistLabel(13.0f, RewindWeightRegular,
                                   [UIColor colorWithWhite:1.0f alpha:0.75f]) retain];
    _subLabel.text = RewindL(@"loading_tracks");
    [_headerView addSubview:_subLabel];

    _subscribeButton = [[RewindPillButton alloc] initWithStyle:RewindPillStyleOutlined icon:nil
                                                          title:RewindL(@"subscribe")];
    [_subscribeButton addTarget:self action:@selector(subscribePressed) forControlEvents:UIControlEventTouchUpInside];
    [_headerView addSubview:_subscribeButton];

    _radioButton = [[RewindIconButton buttonWithIcon:@"mix" points:RW(20.0f)] retain];
    [_radioButton setIconColor:[UIColor whiteColor]];
    _radioButton.layer.borderWidth = 1.0f;
    _radioButton.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.4f].CGColor;
    [_radioButton addTarget:self action:@selector(radioPressed) forControlEvents:UIControlEventTouchUpInside];
    [_headerView addSubview:_radioButton];

    _playButton = [[RewindIconButton buttonWithIcon:@"play" points:RW(20.0f)] retain];
    _playButton.backgroundColor = RewindColorAccentFill();
    [_playButton setIconColor:RewindColorOnAccent()];
    [_playButton addTarget:self action:@selector(playFromTopSongs) forControlEvents:UIControlEventTouchUpInside];
    [_headerView addSubview:_playButton];

    /* fixed over the scroll content, never affected by the header stretch or scroll */
    _backBacking = [[UIView alloc] initWithFrame:CGRectZero];
    _backBacking.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.35f];
    _backBacking.userInteractionEnabled = NO;
    [self.view addSubview:_backBacking];
    _backButton = [[RewindIconButton buttonWithIcon:@"back" points:RW(22.0f)] retain];
    [_backButton setIconColor:[UIColor whiteColor]];
    [_backButton addTarget:self action:@selector(backPressed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_backButton];

    _status = [RewindArtistLabel(15.0f, RewindWeightRegular, RewindColorTextSecondary()) retain];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 0;
    _status.text = RewindL(@"loading_tracks");
    [_content addSubview:_status];

    if (_artworkURL.length) [_headerArt setURL:_artworkURL];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyTheme:)
                                                 name:RewindThemeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshPlaying:)
                                                 name:RewindPlayerDidChangeNotification
                                               object:_player];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageChanged:)
                                                 name:REWIND_LANGUAGE_DID_CHANGE_NOTIFICATION
                                               object:nil];
    [self applyTheme:nil];
    [self resolveArtist];
}

- (void)languageChanged:(NSNotification *)note {
    (void)note;
    [_subscribeButton setTitle:RewindL(_subscribed ? @"subscribed" : @"subscribe")];
    [self rebuildContent];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
    [self.navigationController setNavigationBarHidden:NO animated:animated];
    [super viewWillDisappear:animated];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGFloat width = bounds.size.width, height = bounds.size.height;
    CGFloat top = RewindStatusBarInset();
    _content.frame = bounds;

    /* a 3.5 inch screen cannot spare a tall hero photo and still show any shelf beneath it */
    BOOL compact = height - top < RW(520.0f);
    _headerHeight = MAX(RW(240.0f), MIN(RW(420.0f), width * (compact ? 0.85f : 1.1f) + top));
    _headerView.frame = CGRectMake(0, 0, width, _headerHeight);
    _headerArt.frame = _headerView.bounds;
    _headerScrimTop.frame = CGRectMake(0, 0, width, RW(110.0f));
    CGFloat scrimH = MIN(_headerHeight, RW(210.0f));
    _headerScrimBottom.frame = CGRectMake(0, _headerHeight - scrimH, width, scrimH);

    CGFloat backSize = RW(40.0f);
    _backBacking.frame = CGRectMake(RW(10.0f), top + RW(6.0f), backSize, backSize);
    _backBacking.layer.cornerRadius = backSize * 0.5f;
    _backButton.frame = _backBacking.frame;

    CGFloat side = RW(16.0f), playSize = RW(48.0f), radioSize = RW(40.0f), pillH = RW(40.0f);
    CGFloat rowY = _headerHeight - side - playSize;
    CGFloat rowCenterY = rowY + playSize * 0.5f;
    CGFloat pillW = [_subscribeButton preferredWidthForHeight:pillH];
    _subscribeButton.frame = CGRectMake(side, rowCenterY - pillH * 0.5f, pillW, pillH);
    CGFloat radioX = CGRectGetMaxX(_subscribeButton.frame) + RW(10.0f);
    _radioButton.frame = CGRectMake(radioX, rowCenterY - radioSize * 0.5f, radioSize, radioSize);
    _radioButton.layer.cornerRadius = radioSize * 0.5f;
    CGFloat playX = CGRectGetMaxX(_radioButton.frame) + RW(10.0f);
    _playButton.frame = CGRectMake(playX, rowCenterY - playSize * 0.5f, playSize, playSize);
    _playButton.layer.cornerRadius = playSize * 0.5f;

    CGFloat textWidth = MAX(RW(80.0f), width - side * 2.0f);
    CGFloat subH = RW(18.0f);
    CGFloat maxNameH = ceilf(_nameLabel.font.lineHeight) * 2.0f + RW(4.0f);
    CGFloat nameH = MAX(RW(30.0f), MIN(maxNameH, RewindTextSize(_nameLabel.text, _nameLabel.font, textWidth).height));
    _subLabel.frame = CGRectMake(side, rowY - RW(8.0f) - subH, textWidth, subH);
    _nameLabel.frame = CGRectMake(side, _subLabel.frame.origin.y - nameH - RW(2.0f), textWidth, nameH);

    if (fabs(_laidWidth - width) > 0.5f) {
        _laidWidth = width;
        [self rebuildContent];
    }
}

/* pulling past the top stretches the photo upward instead of leaving a blank gap;
   the bottom edge stays put since the name/subtitle/buttons never move */
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != _content) return;
    CGFloat stretch = MAX(0.0f, -scrollView.contentOffset.y);
    CGFloat width = _headerView.bounds.size.width;
    _headerArt.frame = CGRectMake(0, -stretch, width, _headerHeight + stretch);
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = RewindColorCanvas();
    _nameLabel.textColor = RewindColorText();
    _status.textColor = RewindColorTextSecondary();
    [self rebuildContent];
}

- (void)applyAvatarURL:(NSString *)url {
    NSString *clean = RewindArtistImageURL(url);
    if (!clean.length) return;
    [_artworkURL release];
    _artworkURL = [clean copy];
    [_headerArt setURL:_artworkURL];
}

- (void)resolveArtist {
    if (_artistID.length) {
        [self loadArtistPage];
        return;
    }
    if (!_api || !_artistName.length ||
        [_artistName caseInsensitiveCompare:@"Various Artists"] == NSOrderedSame ||
        [_artistName caseInsensitiveCompare:@"YouTube Music"] == NSOrderedSame) {
        _status.text = RewindL(@"no_tracks");
        return;
    }
    // no browse id on the seed track; steal one from a matching search hit
    [_api search:_artistName completion:^(NSArray *tracks, NSError *error) {
        if (error || !tracks.count) {
            _status.text = RewindL(@"couldnt_load_tracks");
            [self rebuildContent];
            return;
        }
        for (RewindTrack *track in tracks) {
            if (!track.artistID.length) continue;
            if ([RewindTrackArtistText(track) caseInsensitiveCompare:_artistName] != NSOrderedSame) continue;
            [_artistID release];
            _artistID = [track.artistID copy];
            [self loadArtistPage];
            return;
        }
        _status.text = RewindL(@"couldnt_load_tracks");
        [self rebuildContent];
    }];
}

- (void)loadArtistPage {
    [_api artistPageForID:_artistID completion:^(NSString *name, NSString *avatarURL,
                                                  NSString *subscriberText, BOOL subscribed,
                                                  NSArray *shelves, NSError *error) {
        if (error) {
            _status.text = RewindL(@"couldnt_load_tracks");
            [self rebuildContent];
            return;
        }
        if (name.length) {
            [_artistName release];
            _artistName = [name copy];
            _nameLabel.text = _artistName;
            [self.view setNeedsLayout];
        }
        if (avatarURL.length) [self applyAvatarURL:avatarURL];
        if (!subscriberText.length) {
            RewindShelf *songs = RewindArtistTopSongsShelf(shelves);
            if (songs.items.count)
                subscriberText = [NSString stringWithFormat:RewindL(@"tracks_count"),
                                  (unsigned long)songs.items.count];
        }
        [_subscriberText release];
        _subscriberText = [subscriberText copy];
        _subLabel.text = _subscriberText;
        _subscribed = subscribed;
        [_subscribeButton setTitle:RewindL(_subscribed ? @"subscribed" : @"subscribe")];
        [self.view setNeedsLayout];
        [_shelves release];
        _shelves = [shelves copy];
        [self rebuildContent];
    }];
}

- (void)rebuildContent {
    if (!_content || _content.bounds.size.width < 1.0f) return;
    NSArray *old = [_content.subviews copy];
    for (UIView *view in old) if (view != _headerView) [view removeFromSuperview];
    [old release];
    CGFloat width = _content.bounds.size.width;
    CGFloat y = _headerHeight + RW(16.0f);
    BOOL hasShelf = NO;
    for (RewindShelf *shelf in _shelves) if (shelf.items.count && shelf.style != RewindShelfStyleLinks) hasShelf = YES;
    if (!hasShelf) {
        _status.frame = CGRectMake(RW(24.0f), y + RW(8.0f), width - RW(48.0f), RW(60.0f));
        [_content addSubview:_status];
        RewindUpdateStatusSpinner(_status, [_status.text isEqualToString:RewindL(@"loading_tracks")]);
        y = CGRectGetMaxY(_status.frame);
    } else {
        for (RewindShelf *shelf in _shelves) {
            if (!shelf.items.count || shelf.style == RewindShelfStyleLinks) continue;
            y = [self addShelf:shelf atY:y width:width];
        }
    }
    _content.contentSize = CGSizeMake(width, y + RW(32.0f));
}

- (CGFloat)addSectionTitle:(NSString *)title atY:(CGFloat)y width:(CGFloat)width {
    if (!title.length) return y;
    if (y > _headerHeight + RW(24.0f)) y += RW(18.0f);
    UILabel *label = RewindArtistLabel(19.0f, RewindWeightBold, RewindColorText());
    label.frame = CGRectMake(RW(16.0f), y, width - RW(32.0f), RW(26.0f));
    label.text = title;
    [_content addSubview:label];
    return y + RW(26.0f) + RW(8.0f);
}

- (CGFloat)addShelf:(RewindShelf *)shelf atY:(CGFloat)y width:(CGFloat)width {
    __block RewindArtistVC *owner = self;
    y = [self addSectionTitle:shelf.title atY:y width:width];
    if (shelf.style == RewindShelfStyleList) {
        NSUInteger count = MIN((NSUInteger)10, shelf.items.count);
        CGFloat rowH = [RewindTrackRow rowHeight];
        RewindTrack *current = _player.track;
        for (NSUInteger index = 0; index < count; ++index) {
            id item = [shelf.items objectAtIndex:index];
            if (![item isKindOfClass:[RewindTrack class]]) continue;
            RewindTrack *track = item;
            RewindTrackRow *row = [[[RewindTrackRow alloc] initWithFrame:
                                    CGRectMake(0, y, width, rowH)] autorelease];
            [row setTrack:track];
            BOOL playing = current.videoID.length && [current.videoID isEqualToString:track.videoID];
            [row setPlaying:playing animating:_player.playing];
            [row setOnTap:^{ [owner openItem:item inShelf:shelf]; }];
            [row setOnMore:^{ [owner showTrackMenu:track]; }];
            [_content addSubview:row];
            y += rowH;
        }
        return y + RW(12.0f);
    }

    CGFloat cardW = RW(140.0f), rowH = RW(198.0f), side = RW(16.0f), gap = RW(12.0f);
    UIScrollView *scroll = [[[RewindScrollView alloc] initWithFrame:CGRectMake(0, y, width, rowH)] autorelease];
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.alwaysBounceHorizontal = YES;
    [_content addSubview:scroll];
    NSUInteger count = MIN((NSUInteger)12, shelf.items.count);
    NSUInteger placed = 0;
    for (NSUInteger index = 0; index < count; ++index) {
        id item = [shelf.items objectAtIndex:index];
        if (![item isKindOfClass:[RewindTrack class]]) continue;
        RewindTrack *track = item;
        BOOL circular = [track.resultType isEqualToString:RewindResultTypeArtist];
        CGFloat x = side + placed * (cardW + gap);
        RewindPressControl *card = [[[RewindPressControl alloc] initWithFrame:
                                     CGRectMake(x, 0, cardW, rowH)] autorelease];
        RewindArtworkView *art = [[[RewindArtworkView alloc] initWithFrame:CGRectMake(0, 0, cardW, cardW)] autorelease];
        [art setCornerRadius:circular ? cardW * 0.5f : RW(6.0f)];
        [art setURL:track.thumbnailURL];
        [card addSubview:art];
        UILabel *title = RewindArtistLabel(14.0f, RewindWeightMedium, RewindColorText());
        title.frame = CGRectMake(0, cardW + RW(8.0f), cardW, RW(19.0f));
        title.textAlignment = circular ? NSTextAlignmentCenter : NSTextAlignmentLeft;
        title.text = track.title;
        [card addSubview:title];
        UILabel *detail = RewindArtistLabel(12.0f, RewindWeightRegular, RewindColorTextSecondary());
        detail.frame = CGRectMake(0, cardW + RW(29.0f), cardW, RW(17.0f));
        detail.textAlignment = title.textAlignment;
        detail.text = track.detail.length ? track.detail : track.artist;
        [card addSubview:detail];
        [card setOnTap:^{ [owner openItem:item inShelf:shelf]; }];
        [scroll addSubview:card];
        ++placed;
    }
    scroll.contentSize = CGSizeMake(side * 2.0f + placed * (cardW + gap), rowH);
    return y + rowH + RW(22.0f);
}

- (void)openItem:(id)item inShelf:(RewindShelf *)shelf {
    if (![item isKindOfClass:[RewindTrack class]]) return;
    RewindTrack *track = item;
    if ([track.resultType isEqualToString:RewindResultTypeArtist]) {
        RewindPushArtistProfile(self, track, _api, _player);
        return;
    }
    if (track.isPlaylist || [track.resultType isEqualToString:RewindResultTypeAlbum]) {
        RewindPushAlbum(self, track, _api, _player);
        return;
    }
    NSArray *queue = RewindArtistPlayableTracks(shelf.items);
    NSUInteger index = [queue indexOfObjectIdenticalTo:track];
    if (index == NSNotFound || !_player || !_api) return;
    RewindRecordTrack(track);
    [_player setQueue:queue selectedIndex:(NSInteger)index usingAPI:_api];
}

- (void)playFromTopSongs {
    NSArray *tracks = RewindArtistPlayableTracks(RewindArtistTopSongsShelf(_shelves).items);
    if (!tracks.count || !_player || !_api) return;
    RewindTrack *track = [tracks objectAtIndex:0];
    RewindRecordTrack(track);
    [_player setQueue:tracks selectedIndex:0 usingAPI:_api];
}

- (void)radioPressed {
    NSArray *tracks = RewindArtistPlayableTracks(RewindArtistTopSongsShelf(_shelves).items);
    if (!tracks.count) return;
    RewindTrack *seed = [tracks objectAtIndex:0];
    RewindRecordTrack(seed);
    [self startRadioFromTrack:seed];
}

/* the same mix machinery the rest of the app uses to start a radio from a track */
- (void)startRadioFromTrack:(RewindTrack *)seed {
    if (!seed || !_player || !_api) return;
    [_player setContinuousPlayback:YES];
    if (!RewindAccountIsSignedIn()) {
        [_api relatedForTrack:seed completion:^(NSArray *shelves, NSArray *chips, NSError *error) {
            (void)chips;
            NSArray *tracks = RewindArtistPlayableTracks(RewindArtistTopSongsShelf(shelves).items);
            if (!tracks.count) {
                RewindShowToast(self.view, RewindFriendlyError(error) ?: RewindL(@"account_mix_failed"), RW(24.0f));
                return;
            }
            [_player setQueue:tracks selectedIndex:0 usingAPI:_api];
        }];
        return;
    }
    RewindAccountLoadMix(seed, ^(NSArray *tracks, NSError *error) {
        if (error || !tracks.count) {
            RewindShowToast(self.view, RewindFriendlyError(error) ?: RewindL(@"account_mix_failed"), RW(24.0f));
            return;
        }
        [_player setQueue:tracks selectedIndex:0 usingAPI:_api];
    });
}

- (void)subscribePressed {
    if (!_artistID.length) return;
    if (!RewindAccountIsSignedIn()) {
        RewindShowToast(self.view, RewindL(@"account_sign_in_detail"), RW(28.0f));
        return;
    }
    BOOL target = !_subscribed;
    _subscribed = target;
    [_subscribeButton setTitle:RewindL(target ? @"subscribed" : @"subscribe")];
    NSString *artistID = [[_artistID copy] autorelease];
    RewindAccountSetSubscribed(artistID, target, ^(NSError *error) {
        if (!error || ![_artistID isEqualToString:artistID]) return;
        _subscribed = !target;
        [_subscribeButton setTitle:RewindL(_subscribed ? @"subscribed" : @"subscribe")];
        RewindShowToast(self.view, RewindFriendlyError(error), RW(28.0f));
    });
}

- (void)refreshPlaying:(NSNotification *)note {
    (void)note;
    if (_shelves.count) [self rebuildContent];
}

- (void)showTrackMenu:(RewindTrack *)track {
    if (!track) return;
    [_menuTrack release];
    _menuTrack = [track retain];
    __block RewindArtistVC *owner = self;
    RewindSheet *sheet = [[[RewindSheet alloc] initWithFrame:self.view.bounds] autorelease];
    [sheet setHeaderTitle:track.title subtitle:RewindTrackArtistText(track) accessories:nil];
    NSMutableArray *items = [NSMutableArray array];
    [items addObject:[RewindSheetItem itemWithIcon:@"play-next" title:RewindL(@"menu_play_next")
                            action:^{
        [owner->_player enqueueTrack:track usingAPI:owner->_api afterCurrent:YES];
        RewindShowToast(owner.view, RewindL(@"menu_play_next_added"), RW(24.0f));
    }]];
    [items addObject:[RewindSheetItem itemWithIcon:@"playlist-add" title:RewindL(@"menu_add_playlist")
                            action:^{ [owner showPlaylistPicker]; }]];
    [items addObject:[RewindSheetItem itemWithIcon:@"share" title:RewindL(@"menu_share")
                            action:^{ [owner shareTrack:track]; }]];
    [items addObject:[RewindSheetItem itemWithIcon:@"mix" title:RewindL(@"artist_radio")
                            action:^{ [owner startRadioFromTrack:track]; }]];
    [items addObject:[RewindSheetItem itemWithIcon:@"queue-add" title:RewindL(@"menu_queue")
                            action:^{
        [owner->_player enqueueTrack:track usingAPI:owner->_api afterCurrent:NO];
        RewindShowToast(owner.view, RewindL(@"menu_queued"), RW(24.0f));
    }]];
    [items addObject:[RewindSheetItem itemWithIcon:@"save"
                                             title:RewindL(RewindTrackIsSaved(track) ? @"menu_remove_library" : @"menu_save_library")
                            action:^{
        BOOL saved = RewindTrackIsSaved(track);
        if (saved) RewindRemoveTrack(track); else RewindSaveTrack(track);
        RewindShowToast(owner.view, RewindL(saved ? @"removed_library" : @"added_library"), RW(24.0f));
    }]];
    if (track.album.length && !track.isPlaylist)
        [items addObject:[RewindSheetItem itemWithIcon:@"album" title:RewindL(@"menu_album")
                                action:^{ RewindPushAlbum(owner, track, owner->_api, owner->_player); }]];
    [sheet setItems:items];
    [sheet showInView:self.view];
}

- (void)showPlaylistPicker {
    if (!_menuTrack) return;
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:RewindL(@"menu_add_playlist")
                                                     message:_menuTrack.title delegate:self
                                           cancelButtonTitle:RewindL(@"cancel")
                                           otherButtonTitles:RewindL(@"new_playlist"), nil] autorelease];
    alert.tag = RewindArtistAlertPlaylist;
    for (NSString *title in RewindPlaylistPickerTitles()) [alert addButtonWithTitle:title];
    [alert show];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
    if (index == alert.cancelButtonIndex) return;
    if (alert.tag == RewindArtistAlertPlaylist) {
        if (index == 1) {
            UIAlertView *create = [[[UIAlertView alloc] initWithTitle:RewindL(@"new_playlist")
                                                               message:nil delegate:self
                                                     cancelButtonTitle:RewindL(@"cancel")
                                                     otherButtonTitles:RewindL(@"create"), nil] autorelease];
            create.alertViewStyle = UIAlertViewStylePlainTextInput;
            create.tag = RewindArtistAlertCreatePlaylist;
            [create show];
        } else {
            RewindAddTrackToPickedPlaylist(_menuTrack, [alert buttonTitleAtIndex:index], ^(NSError *error) {
                RewindShowToast(self.view, error ? RewindFriendlyError(error) : RewindL(@"added_to_playlist"), RW(24.0f));
            });
        }
    } else if (alert.tag == RewindArtistAlertCreatePlaylist) {
        NSString *name = [[[alert textFieldAtIndex:0] text]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!name.length) return;
        RewindCreatePlaylist(name);
        RewindAddTrackToPlaylist(_menuTrack, name);
        RewindShowToast(self.view, RewindL(@"added_to_playlist"), RW(24.0f));
    }
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
        RewindShowToast(self.view, RewindL(@"menu_share_copied"), RW(24.0f));
    }
}

- (void)backPressed {
    if (self.navigationController.viewControllers.count > 1)
        [self.navigationController popViewControllerAnimated:YES];
    else
        [self dismissViewControllerAnimated:YES completion:nil];
}

@end

void RewindPushArtistProfile(UIViewController *source,
                           RewindTrack *track,
                           RewindAPI *api,
                           RewindPlayer *player) {
    if (!source || !track) return;
    NSString *artist = RewindTrackArtistText(track);
    if (!artist.length || [artist caseInsensitiveCompare:@"Various Artists"] == NSOrderedSame ||
        [artist caseInsensitiveCompare:@"YouTube Music"] == NSOrderedSame)
        return;
    RewindArtistVC *profile = [[[RewindArtistVC alloc]
                              initWithArtist:artist
                              artworkURL:nil
                              api:api
                              player:player
                              seedTrack:track] autorelease];
    [source.navigationController pushViewController:profile animated:YES];
}
