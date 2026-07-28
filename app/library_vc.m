#import "library_vc.h"

#import <QuartzCore/QuartzCore.h>

#import "tunetube_config.h"
#import "tunetube_image_cache.h"
#import "tunetube_theme.h"
#import "tunetube_l10n.h"
#import "tunetube_api.h"
#import "tunetube_player.h"
#import "artist_vc.h"
#import "playlist_vc.h"

static NSDictionary *TuneTubeDictionaryForTrack(TuneTubeTrack *track) {
    if (!track.videoID.length) return nil;
    return [NSDictionary dictionaryWithObjectsAndKeys:
            track.videoID, @"id",
            track.title ?: @"", @"title",
            TuneTubeTrackArtistText(track), @"artist",
            track.album ?: @"", @"album",
            track.thumbnailURL ?: @"", @"thumbnail",
            [NSNumber numberWithUnsignedInteger:track.duration], @"duration", nil];
}

static NSArray *TuneTubeTracksFromEntries(NSArray *saved) {
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSDictionary *entry in saved) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *videoID = [entry objectForKey:@"id"];
        if (!videoID.length) continue;
        NSString *savedArtist = [entry objectForKey:@"artist"];
        NSString *savedAlbum = [entry objectForKey:@"album"] ?: @"";
        NSString *artist = TuneTubeDisplayArtist(savedArtist);
        if ([artist caseInsensitiveCompare:@"Unknown artist"] == NSOrderedSame) {
            artist = @"Various Artists";
            savedAlbum = @"";
        }
        TuneTubeTrack *track = [[[TuneTubeTrack alloc]
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

static NSMutableArray *TuneTubeEntriesForKey(NSString *key) {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (![saved isKindOfClass:[NSArray class]]) saved = [NSArray array];
    return [NSMutableArray arrayWithArray:saved];
}

static void TuneTubeWriteEntries(NSMutableArray *entries, NSString *key) {
    [[NSUserDefaults standardUserDefaults] setObject:entries forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

NSArray *TuneTubeLibraryTracks(void) {
    return TuneTubeTracksFromEntries([[NSUserDefaults standardUserDefaults]
                                      objectForKey:TUNETUBE_LIBRARY_DEFAULTS_KEY]);
}

NSArray *TuneTubeRecentTracks(void) {
    return TuneTubeTracksFromEntries([[NSUserDefaults standardUserDefaults]
                                      objectForKey:TUNETUBE_HISTORY_DEFAULTS_KEY]);
}

static void TuneTubeInsertTrack(TuneTubeTrack *track, NSString *key, NSUInteger limit) {
    NSDictionary *entry = TuneTubeDictionaryForTrack(track);
    if (!entry) return;

    NSMutableArray *saved = TuneTubeEntriesForKey(key);
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
    TuneTubeWriteEntries(saved, key);
}

void TuneTubeSaveTrack(TuneTubeTrack *track) {
    TuneTubeInsertTrack(track, TUNETUBE_LIBRARY_DEFAULTS_KEY, 200);
}

void TuneTubeRecordTrack(TuneTubeTrack *track) {
    TuneTubeInsertTrack(track, TUNETUBE_HISTORY_DEFAULTS_KEY, 12);
}

BOOL TuneTubeTrackIsSaved(TuneTubeTrack *track) {
    if (!track.videoID.length) return NO;
    for (NSDictionary *entry in TuneTubeEntriesForKey(TUNETUBE_LIBRARY_DEFAULTS_KEY)) {
        if ([[entry objectForKey:@"id"] isEqualToString:track.videoID]) return YES;
    }
    return NO;
}

void TuneTubeRemoveTrack(TuneTubeTrack *track) {
    if (!track.videoID.length) return;
    NSMutableArray *saved = TuneTubeEntriesForKey(TUNETUBE_LIBRARY_DEFAULTS_KEY);
    for (NSInteger index = (NSInteger)saved.count - 1; index >= 0; --index) {
        NSDictionary *entry = [saved objectAtIndex:(NSUInteger)index];
        if ([[entry objectForKey:@"id"] isEqualToString:track.videoID])
            [saved removeObjectAtIndex:(NSUInteger)index];
    }
    TuneTubeWriteEntries(saved, TUNETUBE_LIBRARY_DEFAULTS_KEY);
}

static NSString *TuneTubeLibraryThumbnailURL(TuneTubeTrack *track) {
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

@interface TuneLibraryCell : UITableViewCell {
    UIView *_card;
    CAGradientLayer *_cardGradient;
    UIImageView *_artwork;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    NSString *_imageURL;
    TuneTubeTrack *_track;
    id<TuneArtistTrackCellDelegate> _artistDelegate;
    UIButton *_artistButton;
}
- (void)setArtistDelegate:(id<TuneArtistTrackCellDelegate>)delegate;
- (void)configureWithTrack:(TuneTubeTrack *)track;
@end

@implementation TuneLibraryCell

- (void)applyTheme {
    _card.layer.borderColor = TuneThemeBorder().CGColor;
    _cardGradient.colors = [NSArray arrayWithObjects:
                            (id)TuneThemeSurfaceTop().CGColor,
                            (id)TuneThemeSurfaceBottom().CGColor, nil];
    _artwork.backgroundColor = TuneThemeSurface();
    _titleLabel.textColor = TuneThemePrimaryText();
    _artistLabel.textColor = TuneThemeSecondaryText();
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.layer.cornerRadius = 10.0f;
    _card.layer.borderWidth = 1.0f;
    _card.layer.shadowColor = [UIColor blackColor].CGColor;
    _card.layer.shadowOpacity = 0.35f;
    _card.layer.shadowOffset = CGSizeMake(0.0f, 2.0f);
    _card.layer.shadowRadius = 2.0f;
    _card.layer.shouldRasterize = YES;
    _card.layer.rasterizationScale = [UIScreen mainScreen].scale;
    _cardGradient = [[CAGradientLayer layer] retain];
    _cardGradient.cornerRadius = 10.0f;
    [_card.layer insertSublayer:_cardGradient atIndex:0];
    [self.contentView addSubview:_card];

    _artwork = [[UIImageView alloc] initWithFrame:CGRectZero];
    _artwork.layer.cornerRadius = 7.0f;
    _artwork.layer.masksToBounds = YES;
    _artwork.contentMode = UIViewContentModeScaleAspectFill;
    _artwork.image = [UIImage imageNamed:@"Icon.png"];
    [_card addSubview:_artwork];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.font = [UIFont boldSystemFontOfSize:15.0f];
    _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [_card addSubview:_titleLabel];

    _artistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _artistLabel.backgroundColor = [UIColor clearColor];
    _artistLabel.font = [UIFont systemFontOfSize:13.0f];
    _artistLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [_card addSubview:_artistLabel];

    _artistButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _artistButton.adjustsImageWhenHighlighted = NO;
    _artistButton.accessibilityLabel = TuneL(@"artist_profile");
    [_artistButton addTarget:self action:@selector(artistPressed:)
            forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_artistButton];
    [self applyTheme];
    return self;
}

- (void)dealloc {
    [_card release];
    [_cardGradient release];
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

- (void)setArtistDelegate:(id<TuneArtistTrackCellDelegate>)delegate {
    _artistDelegate = delegate;
}

- (void)configureWithTrack:(TuneTubeTrack *)track {
    [self applyTheme];
    [_track release];
    _track = [track retain];
    [_imageURL release];
    _imageURL = [TuneTubeLibraryThumbnailURL(track) copy];
    _artwork.image = [UIImage imageNamed:@"Icon.png"];
    _titleLabel.text = track.title;
    NSString *artistName = TuneTubeTrackArtistText(track);
    _artistLabel.text = artistName;
    if (track.album.length)
        _artistLabel.text = [NSString stringWithFormat:@"%@  ·  %@", artistName, track.album];
    if (!_imageURL.length) return;

    NSString *requestedURL = [_imageURL copy];
    TuneLoadImage(requestedURL, ^(UIImage *image) {
        if (image && [_imageURL isEqualToString:requestedURL])
            _artwork.image = image;
        [requestedURL release];
    });
}

- (void)artistPressed:(UIButton *)button {
    (void)button;
    if (_artistDelegate && [_artistDelegate respondsToSelector:@selector(tuneArtistCell:didSelectTrack:)])
        [_artistDelegate tuneArtistCell:self didSelectTrack:_track];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    _card.frame = CGRectMake(8.0f, 5.0f, MAX(80.0f, bounds.size.width - 16.0f),
                             MAX(66.0f, bounds.size.height - 10.0f));
    _cardGradient.frame = _card.bounds;
    CGFloat artworkSize = MIN(58.0f, _card.bounds.size.height - 12.0f);
    CGFloat artworkY = floorf((_card.bounds.size.height - artworkSize) * 0.5f);
    _artwork.frame = CGRectMake(8.0f, artworkY, artworkSize, artworkSize);
    CGFloat textX = CGRectGetMaxX(_artwork.frame) + 12.0f;
    CGFloat textY = floorf((_card.bounds.size.height - 43.0f) * 0.5f);
    CGFloat right = _card.bounds.size.width - 30.0f;
    _titleLabel.frame = CGRectMake(textX, textY, MAX(20.0f, right - textX), 22.0f);
    _artistLabel.frame = CGRectMake(textX, textY + 24.0f, MAX(20.0f, right - textX), 19.0f);
    _artistButton.frame = _artistLabel.frame;
}

@end

@interface TuneLibraryVC () <TuneArtistTrackCellDelegate>
- (void)donePressed;
- (void)playlistsPressed;
- (void)reloadLibrary;
- (void)applyTheme:(NSNotification *)note;
- (void)findMusicPressed;
- (void)tuneArtistCell:(id)cell didSelectTrack:(TuneTubeTrack *)track;
@end

@implementation TuneLibraryVC

- (id)initWithPlayer:(TuneTubePlayer *)player api:(TuneTubeAPI *)api {
    self = [super init];
    if (self) {
        _player = [player retain];
        _api = [api retain];
        _tracks = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_player release];
    [_api release];
    [_tracks release];
    [_table release];
    [_emptyLabel release];
    [_emptyDescription release];
    [_emptyIcon release];
    [_findButton release];
    [_backgroundGradient release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = TuneThemeBackgroundBottom();
    self.view = view;
}

- (void)reloadLocalizedChrome {
    self.title = TuneL(@"library");
    self.navigationItem.leftBarButtonItem =
        TuneTubeBarButtonItem(TuneL(@"done"), self, @selector(donePressed));
    self.navigationItem.rightBarButtonItem =
        TuneTubeBarButtonItem(TuneL(@"playlists"), self, @selector(playlistsPressed));
    _emptyLabel.text = TuneL(@"nothing_here");
    _emptyDescription.text = TuneL(@"library_empty_desc");
    [_findButton setTitle:TuneL(@"find_music") forState:UIControlStateNormal];
    [_table reloadData];
}

- (void)languageChanged:(NSNotification *)note {
    (void)note;
    [self reloadLocalizedChrome];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = TuneL(@"library");
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyTheme:)
                                                 name:TuneTubeThemeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageChanged:)
                                                 name:TUNETUBE_LANGUAGE_DID_CHANGE_NOTIFICATION
                                               object:nil];
    self.navigationItem.leftBarButtonItem =
        TuneTubeBarButtonItem(TuneL(@"done"), self, @selector(donePressed));
    self.navigationItem.rightBarButtonItem =
        TuneTubeBarButtonItem(TuneL(@"playlists"), self, @selector(playlistsPressed));

    _backgroundGradient = [[CAGradientLayer layer] retain];
    [self.view.layer insertSublayer:_backgroundGradient atIndex:0];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = [UIColor clearColor];
    _table.backgroundView = nil;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = 76.0f;
    _table.contentInset = UIEdgeInsetsMake(10.0f, 0.0f, 10.0f, 0.0f);
    [self.view addSubview:_table];

    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyLabel.backgroundColor = [UIColor clearColor];
    _emptyLabel.textColor = TuneThemePrimaryText();
    _emptyLabel.font = [UIFont boldSystemFontOfSize:18.0f];
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.text = TuneL(@"nothing_here");
    [self.view addSubview:_emptyLabel];

    _emptyIcon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"player-star-off.png"]];
    _emptyIcon.backgroundColor = [UIColor clearColor];
    _emptyIcon.contentMode = UIViewContentModeCenter;
    [self.view addSubview:_emptyIcon];

    _emptyDescription = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyDescription.backgroundColor = [UIColor clearColor];
    _emptyDescription.textColor = TuneThemeSecondaryText();
    _emptyDescription.font = [UIFont systemFontOfSize:13.0f];
    _emptyDescription.numberOfLines = 0;
    _emptyDescription.textAlignment = NSTextAlignmentCenter;
    _emptyDescription.text = TuneL(@"library_empty_desc");
    [self.view addSubview:_emptyDescription];

    _findButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    [_findButton setTitle:TuneL(@"find_music") forState:UIControlStateNormal];
    _findButton.titleLabel.font = [UIFont boldSystemFontOfSize:14.0f];
    _findButton.layer.cornerRadius = 10.0f;
    _findButton.layer.borderWidth = 1.0f;
    [_findButton addTarget:self action:@selector(findMusicPressed)
          forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_findButton];
    [self applyTheme:nil];
    [self reloadLibrary];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    _backgroundGradient.frame = bounds;
    _table.frame = bounds;
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
}

- (void)reloadLibrary {
    [_tracks removeAllObjects];
    [_tracks addObjectsFromArray:TuneTubeLibraryTracks()];
    BOOL empty = _tracks.count == 0;
    _emptyLabel.hidden = !empty;
    _emptyIcon.hidden = !empty;
    _emptyDescription.hidden = !empty;
    _findButton.hidden = !empty;
    [_table reloadData];
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = TuneThemeBackgroundBottom();
    TuneTubeStyleNavigationBar(self.navigationController.navigationBar);
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)TuneThemeBackgroundTop().CGColor,
                                  (id)TuneThemeBackgroundBottom().CGColor, nil];
    _emptyLabel.textColor = TuneThemePrimaryText();
    _emptyDescription.textColor = TuneThemeSecondaryText();
    _findButton.backgroundColor = TuneThemeAccent();
    [_findButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _findButton.layer.borderColor = TuneThemeBorder().CGColor;
    [_table reloadData];
}

- (void)donePressed {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)playlistsPressed {
    TunePlaylistsVC *playlists = [[[TunePlaylistsVC alloc]
                                   initWithPlayer:_player api:_api] autorelease];
    [self.navigationController pushViewController:playlists animated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)_tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"TuneLibraryCell";
    TuneLibraryCell *cell = (TuneLibraryCell *)[tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell)
        cell = [[[TuneLibraryCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:cellID] autorelease];
    TuneTubeTrack *track = [_tracks objectAtIndex:(NSUInteger)indexPath.row];
    [cell setArtistDelegate:self];
    [cell configureWithTrack:track];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tuneArtistCell:(id)cell didSelectTrack:(TuneTubeTrack *)track {
    (void)cell;
    TunePushArtistProfile(self, track, _api, _player);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSUInteger row;
    TuneTubeTrack *track;
    TuneTubeAPI *api;
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    row = (NSUInteger)indexPath.row;
    if (row >= _tracks.count || !_player || !_api) return;
    track = [[_tracks objectAtIndex:row] retain];
    api = [_api retain];
    TuneTubeRecordTrack(track);
    [_player setQueue:_tracks selectedIndex:(NSInteger)row usingAPI:api];
    [api release];
    [track release];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView
 commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSMutableArray *saved = [NSMutableArray arrayWithArray:
                             [[NSUserDefaults standardUserDefaults]
                              objectForKey:TUNETUBE_LIBRARY_DEFAULTS_KEY] ?: [NSArray array]];
    if ((NSUInteger)indexPath.row < saved.count) {
        [saved removeObjectAtIndex:(NSUInteger)indexPath.row];
        [[NSUserDefaults standardUserDefaults] setObject:saved
                                                   forKey:TUNETUBE_LIBRARY_DEFAULTS_KEY];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    [_tracks removeObjectAtIndex:(NSUInteger)indexPath.row];
    [_table deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
    _emptyLabel.hidden = _tracks.count != 0;
    _emptyIcon.hidden = _tracks.count != 0;
    _emptyDescription.hidden = _tracks.count != 0;
    _findButton.hidden = _tracks.count != 0;
}

- (void)findMusicPressed {
    [[NSNotificationCenter defaultCenter]
     postNotificationName:TuneTubeFocusSearchNotification object:nil];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return YES;
}

@end
