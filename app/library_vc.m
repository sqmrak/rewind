#import "library_vc.h"

/* ios 5 sdk uses UIKit names for these text enums */
#if __IPHONE_OS_VERSION_MAX_ALLOWED < 60000
#define NSTextAlignmentCenter UITextAlignmentCenter
#define NSLineBreakByTruncatingTail UILineBreakModeTailTruncation
#endif
#import "rewind_download.h"

#import <QuartzCore/QuartzCore.h>

#import "rewind_config.h"
#import "rewind_image_cache.h"
#import "rewind_theme.h"
#import "rewind_l10n.h"
#import "rewind_api.h"
#import "rewind_player.h"
#import "artist_vc.h"
#import "playlist_vc.h"
#import "rewind_account.h"
#import "rewind_ui.h"

static NSDictionary *RewindDictionaryForTrack(RewindTrack *track) {
    if (!track.videoID.length) return nil;
    return [NSDictionary dictionaryWithObjectsAndKeys:
            track.videoID, @"id",
            track.title ?: @"", @"title",
            RewindTrackArtistText(track), @"artist",
            track.album ?: @"", @"album",
            track.thumbnailURL ?: @"", @"thumbnail",
            [NSNumber numberWithUnsignedInteger:track.duration], @"duration", nil];
}

static NSArray *RewindTracksFromEntries(NSArray *saved) {
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSDictionary *entry in saved) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *videoID = [entry objectForKey:@"id"];
        if (!videoID.length) continue;
        NSString *savedArtist = [entry objectForKey:@"artist"];
        NSString *savedAlbum = [entry objectForKey:@"album"] ?: @"";
        NSString *artist = RewindDisplayArtist(savedArtist);
        if ([artist caseInsensitiveCompare:@"Unknown artist"] == NSOrderedSame) {
            artist = @"Various Artists";
            savedAlbum = @"";
        }
        RewindTrack *track = [[[RewindTrack alloc]
                            initWithVideoID:videoID
                            title:[entry objectForKey:@"title"] ?: @"Untitled"
                            artist:artist
                            album:savedAlbum
                            thumbnailURL:[entry objectForKey:@"thumbnail"] ?: @""
                            duration:[[entry objectForKey:@"duration"] unsignedIntegerValue]] autorelease];
        [tracks addObject:track];
    }
    return tracks;
}

static NSMutableArray *RewindEntriesForKey(NSString *key) {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (![saved isKindOfClass:[NSArray class]]) saved = [NSArray array];
    return [NSMutableArray arrayWithArray:saved];
}

static void RewindWriteEntries(NSMutableArray *entries, NSString *key) {
    [[NSUserDefaults standardUserDefaults] setObject:entries forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

NSArray *RewindLibraryTracks(void) {
    return RewindTracksFromEntries([[NSUserDefaults standardUserDefaults]
                                      objectForKey:REWIND_LIBRARY_DEFAULTS_KEY]);
}

NSArray *RewindRecentTracks(void) {
    return RewindTracksFromEntries([[NSUserDefaults standardUserDefaults]
                                      objectForKey:REWIND_HISTORY_DEFAULTS_KEY]);
}

static void RewindInsertTrack(RewindTrack *track, NSString *key, NSUInteger limit) {
    NSDictionary *entry = RewindDictionaryForTrack(track);
    if (!entry) return;

    NSMutableArray *saved = RewindEntriesForKey(key);
    NSString *videoID = track.videoID;
    NSUInteger existing = NSNotFound;
    for (NSUInteger index = 0; index < saved.count; ++index) {
        NSDictionary *item = [saved objectAtIndex:index];
        if ([[item objectForKey:@"id"] isEqualToString:videoID]) {
            existing = index;
            break;
        }
    }
    if (existing != NSNotFound) [saved removeObjectAtIndex:existing];
    [saved insertObject:entry atIndex:0];
    while (saved.count > limit) [saved removeLastObject];
    RewindWriteEntries(saved, key);
}

static void RewindLogLikeFailure(NSError *error) {
    if (error) NSLog(@"rewind: youtube like sync failed: %@", error);
}

/* the local copy keeps the track when signed out or when the like request fails */
void RewindSaveTrack(RewindTrack *track) {
    RewindInsertTrack(track, REWIND_LIBRARY_DEFAULTS_KEY, 200);
    if (RewindAccountIsSignedIn()) RewindAccountSetLiked(track, YES, ^(NSError *error) {
        RewindLogLikeFailure(error);
    });
}

void RewindRecordTrack(RewindTrack *track) {
    RewindInsertTrack(track, REWIND_HISTORY_DEFAULTS_KEY, 12);
}

BOOL RewindTrackIsSaved(RewindTrack *track) {
    if (!track.videoID.length) return NO;
    if (RewindAccountTrackIsLiked(track)) return YES;
    for (NSDictionary *entry in RewindEntriesForKey(REWIND_LIBRARY_DEFAULTS_KEY)) {
        if ([[entry objectForKey:@"id"] isEqualToString:track.videoID]) return YES;
    }
    return NO;
}

void RewindRemoveTrack(RewindTrack *track) {
    if (!track.videoID.length) return;
    NSMutableArray *saved = RewindEntriesForKey(REWIND_LIBRARY_DEFAULTS_KEY);
    for (NSInteger index = (NSInteger)saved.count - 1; index >= 0; --index) {
        NSDictionary *entry = [saved objectAtIndex:(NSUInteger)index];
        if ([[entry objectForKey:@"id"] isEqualToString:track.videoID])
            [saved removeObjectAtIndex:(NSUInteger)index];
    }
    RewindWriteEntries(saved, REWIND_LIBRARY_DEFAULTS_KEY);
    if (RewindAccountIsSignedIn()) RewindAccountSetLiked(track, NO, ^(NSError *error) {
        RewindLogLikeFailure(error);
    });
}

static NSString *RewindLibraryThumbnailURL(RewindTrack *track) {
    NSString *url = track.thumbnailURL;
    if (url.length) {
        if ([url hasPrefix:@"//"])
            return [NSString stringWithFormat:@"https:%@", url];
        return url;
    }
    if (!track.videoID.length) return nil;
    return [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg",
            track.videoID];
}

@interface RewindLibraryCell : UITableViewCell {
    UIImageView *_artwork;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    NSString *_imageURL;
    RewindTrack *_track;
    id<RewindArtistTrackCellDelegate> _artistDelegate;
    UIButton *_artistButton;
}
- (void)setArtistDelegate:(id<RewindArtistTrackCellDelegate>)delegate;
- (void)configureWithTrack:(RewindTrack *)track;
@end

@implementation RewindLibraryCell

- (void)applyTheme {
    _artwork.backgroundColor = RewindColorSurface();
    _titleLabel.textColor = RewindColorText();
    _artistLabel.textColor = RewindColorTextSecondary();
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _artwork = [[UIImageView alloc] initWithFrame:CGRectZero];
    _artwork.layer.cornerRadius = RW(4.0f);
    _artwork.layer.masksToBounds = YES;
    _artwork.contentMode = UIViewContentModeScaleAspectFill;
    _artwork.image = [UIImage imageNamed:@"Icon.png"];
    [self.contentView addSubview:_artwork];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.font = RewindFont(16.0f, RewindWeightMedium);
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_titleLabel];

    _artistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _artistLabel.backgroundColor = [UIColor clearColor];
    _artistLabel.font = RewindFont(14.0f, RewindWeightRegular);
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_artistLabel];

    _artistButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _artistButton.adjustsImageWhenHighlighted = NO;
    _artistButton.accessibilityLabel = RewindL(@"artist_profile");
    [_artistButton addTarget:self action:@selector(artistPressed:)
            forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_artistButton];
    [self applyTheme];
    return self;
}

- (void)dealloc {
    [_artwork release];
    [_titleLabel release];
    [_artistLabel release];
    [_imageURL release];
    [_track release];
    [_artistButton release];
    [super dealloc];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [_imageURL release];
    _imageURL = nil;
    [_track release];
    _track = nil;
    _artwork.image = [UIImage imageNamed:@"Icon.png"];
    _titleLabel.text = nil;
    _artistLabel.text = nil;
}

- (void)setArtistDelegate:(id<RewindArtistTrackCellDelegate>)delegate {
    _artistDelegate = delegate;
}

- (void)configureWithTrack:(RewindTrack *)track {
    [self applyTheme];
    [_track release];
    _track = [track retain];
    [_imageURL release];
    _imageURL = [RewindLibraryThumbnailURL(track) copy];
    _artwork.image = [UIImage imageNamed:@"Icon.png"];
    _titleLabel.text = track.title;
    NSString *artistName = RewindTrackArtistText(track);
    _artistLabel.text = artistName;
    if (track.album.length)
        _artistLabel.text = [NSString stringWithFormat:@"%@  ·  %@", artistName, track.album];
    if (!_imageURL.length) return;

    NSString *requestedURL = [_imageURL copy];
    RewindLoadImage(requestedURL, ^(UIImage *image) {
        if (image && [_imageURL isEqualToString:requestedURL])
            _artwork.image = image;
        [requestedURL release];
    });
}

- (void)artistPressed:(UIButton *)button {
    (void)button;
    if (_artistDelegate && [_artistDelegate respondsToSelector:@selector(rewindArtistCell:didSelectTrack:)])
        [_artistDelegate rewindArtistCell:self didSelectTrack:_track];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    CGFloat artworkSize = RW(56.0f);
    CGFloat artworkY = floorf((bounds.size.height - artworkSize) * 0.5f);
    _artwork.frame = CGRectMake(RW(16.0f), artworkY, artworkSize, artworkSize);
    CGFloat textX = CGRectGetMaxX(_artwork.frame) + RW(12.0f);
    CGFloat textY = floorf((bounds.size.height - RW(43.0f)) * 0.5f);
    CGFloat right = bounds.size.width - RW(8.0f);
    _titleLabel.frame = CGRectMake(textX, textY, MAX(RW(20.0f), right - textX), RW(22.0f));
    _artistLabel.frame = CGRectMake(textX, textY + RW(24.0f), MAX(RW(20.0f), right - textX), RW(19.0f));
    _artistButton.frame = _artistLabel.frame;
}

@end

@interface RewindLibraryVC () <RewindArtistTrackCellDelegate>
- (void)donePressed;
- (void)playlistsPressed;
- (void)reloadLibrary;
- (void)applyTheme:(NSNotification *)note;
- (void)findMusicPressed;
- (void)rewindArtistCell:(id)cell didSelectTrack:(RewindTrack *)track;
- (void)trackMorePressed:(UIButton *)button;
- (void)playAllPressed;
@end

@implementation RewindLibraryVC

- (id)initWithPlayer:(RewindPlayer *)player api:(RewindAPI *)api {
    return [self initWithPlayer:player api:api mode:RewindLibraryModeAll];
}

- (id)initWithPlayer:(RewindPlayer *)player api:(RewindAPI *)api mode:(RewindLibraryMode)mode {
    self = [super init];
    if (self) {
        _player = [player retain];
        _api = [api retain];
        _tracks = [[NSMutableArray alloc] init];
        _mode = mode;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_player release];
    [_api release];
    [_tracks release];
    [_likedTracks release];
    [_table release];
    [_listHeader release];
    [_countLabel release];
    [_playAllButton release];
    [_emptyLabel release];
    [_emptyDescription release];
    [_emptyIcon release];
    [_findButton release];
    [_backgroundGradient release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = RewindColorBackground();
    self.view = view;
}

- (void)reloadLocalizedChrome {
    self.title = RewindL(_mode == RewindLibraryModeLiked ? @"liked_music" :
                         _mode == RewindLibraryModeRecent ? @"recent" :
                         _mode == RewindLibraryModeFavorites ? @"favorites" :
                         _mode == RewindLibraryModeDownloads ? @"downloads" : @"library");
    self.navigationItem.leftBarButtonItem =
        RewindBarButtonItem(RewindL(@"done"), self, @selector(donePressed));
    self.navigationItem.rightBarButtonItems = _mode == RewindLibraryModeAll
        ? [NSArray arrayWithObjects:
            RewindBarButtonItem(RewindL(@"playlists"), self, @selector(playlistsPressed)),
            RewindBarButtonItem(RewindL(@"downloads"), self, @selector(downloadsPressed)), nil] : nil;
    _emptyLabel.text = RewindL(@"nothing_here");
    _emptyDescription.text = RewindL(@"library_empty_desc");
    [_findButton setTitle:RewindL(@"find_music") forState:UIControlStateNormal];
    [_table reloadData];
}

- (void)languageChanged:(NSNotification *)note {
    (void)note;
    [self reloadLocalizedChrome];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyTheme:)
                                                 name:RewindThemeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageChanged:)
                                                 name:REWIND_LANGUAGE_DID_CHANGE_NOTIFICATION
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(accountChanged:)
                                                 name:RewindAccountDidChangeNotification
                                               object:nil];
    if (RewindDownloadsDidChangeNotification)
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(downloadsChanged:)
                                                     name:RewindDownloadsDidChangeNotification
                                                   object:nil];
    _backgroundGradient = [[CAGradientLayer layer] retain];
    [self.view.layer insertSublayer:_backgroundGradient atIndex:0];

    _table = [[RewindTableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = [UIColor clearColor];
    _table.backgroundView = nil;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = RW(72.0f);
    _table.contentInset = UIEdgeInsetsMake(0.0f, 0.0f, RW(12.0f), 0.0f);
    [self.view addSubview:_table];

    _listHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, RW(72.0f))];
    _countLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countLabel.backgroundColor = [UIColor clearColor];
    _countLabel.font = RewindFont(14.0f, RewindWeightMedium);
    [_listHeader addSubview:_countLabel];
    _playAllButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    [_playAllButton setImage:RewindIcon(@"play", RW(22.0f), RewindColorOnAccent()) forState:UIControlStateNormal];
    [_playAllButton addTarget:self action:@selector(playAllPressed) forControlEvents:UIControlEventTouchUpInside];
    _playAllButton.layer.cornerRadius = RW(22.0f);
    [_listHeader addSubview:_playAllButton];
    _table.tableHeaderView = _listHeader;

    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyLabel.backgroundColor = [UIColor clearColor];
    _emptyLabel.textColor = RewindColorText();
    _emptyLabel.font = [UIFont boldSystemFontOfSize:18.0f];
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.text = RewindL(@"nothing_here");
    [self.view addSubview:_emptyLabel];

    _emptyIcon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"player-star-off.png"]];
    _emptyIcon.backgroundColor = [UIColor clearColor];
    _emptyIcon.contentMode = UIViewContentModeCenter;
    [self.view addSubview:_emptyIcon];

    _emptyDescription = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyDescription.backgroundColor = [UIColor clearColor];
    _emptyDescription.textColor = RewindColorTextSecondary();
    _emptyDescription.font = [UIFont systemFontOfSize:13.0f];
    _emptyDescription.numberOfLines = 0;
    _emptyDescription.textAlignment = NSTextAlignmentCenter;
    _emptyDescription.text = RewindL(@"library_empty_desc");
    [self.view addSubview:_emptyDescription];

    _findButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    [_findButton setTitle:RewindL(@"find_music") forState:UIControlStateNormal];
    _findButton.titleLabel.font = [UIFont boldSystemFontOfSize:14.0f];
    _findButton.layer.cornerRadius = 10.0f;
    _findButton.layer.borderWidth = 1.0f;
    [_findButton addTarget:self action:@selector(findMusicPressed)
          forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_findButton];
    [self applyTheme:nil];
    [self reloadLocalizedChrome];
    [self reloadLibrary];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    _backgroundGradient.frame = bounds;
    _table.frame = bounds;
    _listHeader.frame = CGRectMake(0, 0, bounds.size.width,
                                   _tracks.count ? RW(72.0f) : 0.0f);
    _table.tableHeaderView = _listHeader;
    _countLabel.frame = CGRectMake(RW(16.0f), RW(25.0f),
                                   MAX(0.0f, bounds.size.width - RW(90.0f)), RW(22.0f));
    _playAllButton.frame = CGRectMake(bounds.size.width - RW(60.0f), RW(14.0f), RW(44.0f), RW(44.0f));
    CGFloat center = floorf(bounds.size.height * 0.45f);
    _emptyIcon.frame = CGRectMake(floorf((bounds.size.width - 72.0f) * 0.5f),
                                  center - 112.0f, 72.0f, 72.0f);
    _emptyLabel.frame = CGRectMake(20.0f, center - 28.0f,
                                   bounds.size.width - 40.0f, 28.0f);
    _emptyDescription.frame = CGRectMake(28.0f, center + 8.0f,
                                         bounds.size.width - 56.0f, 46.0f);
    _findButton.frame = CGRectMake(floorf((bounds.size.width - 164.0f) * 0.5f),
                                   center + 68.0f, 164.0f, 40.0f);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadLibrary];
    if (_mode == RewindLibraryModeAll || _mode == RewindLibraryModeLiked) [self loadLikedMusic];
}

- (void)loadLikedMusic {
    if (!RewindAccountIsSignedIn()) {
        ++_likesRequest;
        [_likedTracks release];
        _likedTracks = nil;
        [self reloadLibrary];
        return;
    }
    NSUInteger request = ++_likesRequest;
    [self retain];
    RewindAccountLoadLikes(NO, ^(NSArray *tracks, NSError *error) {
        if (request == _likesRequest) {
            if (error) {
                NSLog(@"rewind: liked music load failed: %@", error);
                if (!_tracks.count) _emptyDescription.text = RewindFriendlyError(error);
            } else {
                [_likedTracks release];
                _likedTracks = [tracks copy];
                [self reloadLibrary];
            }
        }
        [self release];
    });
}

- (void)accountChanged:(NSNotification *)note {
    (void)note;
    ++_likesRequest;
    [_likedTracks release];
    _likedTracks = nil;
    [self reloadLibrary];
    if (_mode == RewindLibraryModeAll || _mode == RewindLibraryModeLiked) [self loadLikedMusic];
}

- (void)downloadsChanged:(NSNotification *)note {
    (void)note;
    if (_mode != RewindLibraryModeDownloads) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self reloadLibrary]; });
        return;
    }
    [self reloadLibrary];
}

- (void)reloadLibrary {
    [_tracks removeAllObjects];
    if (_mode == RewindLibraryModeDownloads) {
        [_tracks addObjectsFromArray:RewindDownloadedTracks() ?: [NSArray array]];
    } else if (_mode == RewindLibraryModeRecent) {
        [_tracks addObjectsFromArray:RewindRecentTracks()];
    } else if (_mode == RewindLibraryModeFavorites) {
        [_tracks addObjectsFromArray:RewindLibraryTracks()];
    } else if (_mode == RewindLibraryModeLiked) {
        [_tracks addObjectsFromArray:_likedTracks ?: [NSArray array]];
    } else {
        [_tracks addObjectsFromArray:_likedTracks ?: [NSArray array]];
        for (RewindTrack *local in RewindLibraryTracks()) {
            BOOL duplicate = NO;
            for (RewindTrack *liked in _likedTracks)
                if ([liked.videoID isEqualToString:local.videoID]) {
                    duplicate = YES;
                    break;
                }
            if (!duplicate) [_tracks addObject:local];
        }
    }
    BOOL empty = _tracks.count == 0;
    _listHeader.hidden = empty;
    _listHeader.frame = CGRectMake(0, 0, _table.bounds.size.width,
                                   empty ? 0.0f : RW(72.0f));
    _table.tableHeaderView = _listHeader;
    _countLabel.text = [NSString stringWithFormat:RewindL(@"tracks_count"), (unsigned long)_tracks.count];
    _emptyLabel.hidden = !empty;
    _emptyIcon.hidden = !empty;
    _emptyDescription.hidden = !empty;
    _findButton.hidden = !empty;
    [_table reloadData];
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = RewindColorCanvas();
    RewindStyleNavigationBar(self.navigationController.navigationBar);
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)RewindColorBackground().CGColor,
                                  (id)RewindColorBackground().CGColor, nil];
    _emptyLabel.textColor = RewindColorText();
    _emptyDescription.textColor = RewindColorTextSecondary();
    _countLabel.textColor = RewindColorTextSecondary();
    _playAllButton.backgroundColor = RewindColorAccentFill();
    [_playAllButton setImage:RewindIcon(@"play", RW(22.0f), RewindColorOnAccent()) forState:UIControlStateNormal];
    _findButton.backgroundColor = RewindColorAccentFill();
    [_findButton setTitleColor:RewindColorOnAccent() forState:UIControlStateNormal];
    _findButton.layer.borderColor = RewindColorDivider().CGColor;
    _findButton.layer.borderWidth = 1.0f;
    [_table reloadData];
}

- (void)donePressed {
    if (self.navigationController.viewControllers.count > 1)
        [self.navigationController popViewControllerAnimated:YES];
    else [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)playlistsPressed {
    RewindPlaylistsVC *playlists = [[[RewindPlaylistsVC alloc]
                                   initWithPlayer:_player api:_api] autorelease];
    [self.navigationController pushViewController:playlists animated:YES];
}

- (void)downloadsPressed {
    RewindLibraryVC *downloads = [[[RewindLibraryVC alloc] initWithPlayer:_player api:_api
        mode:RewindLibraryModeDownloads] autorelease];
    [self.navigationController pushViewController:downloads animated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)_tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"RewindLibraryCell";
    RewindLibraryCell *cell = (RewindLibraryCell *)[tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell)
        cell = [[[RewindLibraryCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:cellID] autorelease];
    RewindTrack *track = [_tracks objectAtIndex:(NSUInteger)indexPath.row];
    [cell setArtistDelegate:self];
    [cell configureWithTrack:track];
    UIButton *more = [UIButton buttonWithType:UIButtonTypeCustom];
    more.frame = CGRectMake(0, 0, RW(48.0f), RW(48.0f));
    more.tag = indexPath.row;
    [more setImage:RewindIcon(@"more", RW(23.0f), RewindColorText()) forState:UIControlStateNormal];
    [more addTarget:self action:@selector(trackMorePressed:) forControlEvents:UIControlEventTouchUpInside];
    cell.accessoryView = more;
    return cell;
}

- (void)playAllPressed {
    if (!_tracks.count || !_player || !_api) return;
    [_player setQueue:_tracks selectedIndex:0 usingAPI:_api];
    RewindRecordTrack([_tracks objectAtIndex:0]);
}

- (void)trackMorePressed:(UIButton *)button {
    NSUInteger index = (NSUInteger)button.tag;
    if (index >= _tracks.count) return;
    RewindTrack *track = [_tracks objectAtIndex:index];
    __block RewindLibraryVC *owner = self;
    RewindSheet *sheet = [[[RewindSheet alloc] initWithFrame:self.view.bounds] autorelease];
    [sheet setHeaderTitle:track.title subtitle:RewindTrackArtistText(track) accessories:nil];
    [sheet setTiles:[NSArray arrayWithObject:
        [RewindSheetItem itemWithIcon:@"play-next" title:RewindL(@"menu_play_next")
                                action:^{ [owner->_player enqueueTrack:track usingAPI:owner->_api afterCurrent:YES]; }]]];
    NSMutableArray *items = [NSMutableArray arrayWithObject:
        [RewindSheetItem itemWithIcon:@"queue-add" title:RewindL(@"menu_queue")
                                action:^{ [owner->_player enqueueTrack:track usingAPI:owner->_api afterCurrent:NO]; }]];
    if (_mode != RewindLibraryModeDownloads && !RewindDownloadedURLForTrack(track.videoID))
        [items addObject:[RewindSheetItem itemWithIcon:@"download" title:RewindL(@"menu_download")
                                              action:^{ [owner downloadTrack:track]; }]];
    if (_mode != RewindLibraryModeRecent && _mode != RewindLibraryModeDownloads)
        [items addObject:[RewindSheetItem itemWithIcon:@"delete" title:RewindL(@"menu_remove_library")
                                              action:^{ [owner removeTrackAtIndex:index]; }]];
    [sheet setItems:items];
    [sheet showInView:self.view];
}

- (void)downloadTrack:(RewindTrack *)track {
    RewindShowToast(self.view, RewindL(@"menu_download_started"), RW(24.0f));
    RewindDownloadTrack(track, _api, ^(NSError *error) {
        RewindShowToast(self.view, error ? RewindFriendlyError(error) : RewindL(@"menu_download_done"), RW(24.0f));
    });
}

- (void)removeTrackAtIndex:(NSUInteger)index {
    if (index >= _tracks.count) return;
    NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)index inSection:0];
    [self tableView:_table commitEditingStyle:UITableViewCellEditingStyleDelete forRowAtIndexPath:path];
}

- (void)rewindArtistCell:(id)cell didSelectTrack:(RewindTrack *)track {
    (void)cell;
    RewindPushArtistProfile(self, track, _api, _player);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSUInteger row;
    RewindTrack *track;
    RewindAPI *api;
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    row = (NSUInteger)indexPath.row;
    if (row >= _tracks.count || !_player || !_api) return;
    track = [[_tracks objectAtIndex:row] retain];
    api = [_api retain];
    RewindRecordTrack(track);
    [_player setQueue:_tracks selectedIndex:(NSInteger)row usingAPI:api];
    [api release];
    [track release];
    [self donePressed];
}

- (void)tableView:(UITableView *)tableView
 commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete || _mode == RewindLibraryModeDownloads) return;
    if ((NSUInteger)indexPath.row >= _tracks.count) return;
    RewindTrack *track = [_tracks objectAtIndex:(NSUInteger)indexPath.row];
    /* merged rows no longer line up with the stored order, so remove by id */
    RewindRemoveTrack(track);
    if (_likedTracks.count) {
        NSMutableArray *liked = [NSMutableArray arrayWithArray:_likedTracks];
        for (NSInteger index = (NSInteger)liked.count - 1; index >= 0; --index)
            if ([[[liked objectAtIndex:(NSUInteger)index] videoID] isEqualToString:track.videoID])
                [liked removeObjectAtIndex:(NSUInteger)index];
        [_likedTracks release];
        _likedTracks = [liked copy];
    }
    [_tracks removeObjectAtIndex:(NSUInteger)indexPath.row];
    [_table deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
    _emptyLabel.hidden = _tracks.count != 0;
    _emptyIcon.hidden = _tracks.count != 0;
    _emptyDescription.hidden = _tracks.count != 0;
    _findButton.hidden = _tracks.count != 0;
    _listHeader.hidden = _tracks.count == 0;
    _listHeader.frame = CGRectMake(0, 0, _table.bounds.size.width,
                                   _tracks.count ? RW(72.0f) : 0.0f);
    _table.tableHeaderView = _listHeader;
    _countLabel.text = [NSString stringWithFormat:RewindL(@"tracks_count"), (unsigned long)_tracks.count];
}

- (void)findMusicPressed {
    [[NSNotificationCenter defaultCenter]
     postNotificationName:RewindFocusSearchNotification object:nil];
    /* always reached by a push from the library tab, never presented */
    if (self.navigationController.viewControllers.count > 1)
        [self.navigationController popViewControllerAnimated:YES];
    else [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return _mode != RewindLibraryModeRecent && _mode != RewindLibraryModeDownloads;
}

@end
