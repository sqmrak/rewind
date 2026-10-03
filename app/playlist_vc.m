#import "playlist_vc.h"

/* ios 5 sdk uses UIKit names for these text enums */
#if __IPHONE_OS_VERSION_MAX_ALLOWED < 60000
#define NSTextAlignmentCenter UITextAlignmentCenter
#define NSLineBreakByTruncatingTail UILineBreakModeTailTruncation
#endif

#import <QuartzCore/QuartzCore.h>

#import "rewind_image_cache.h"
#import "rewind_theme.h"
#import "rewind_l10n.h"
#import "rewind_api.h"
#import "rewind_player.h"
#import "rewind_ui.h"
#import "library_vc.h"
#import "rewind_config.h"
#import "rewind_account.h"
#import "rewind_audio.h"

static NSDictionary *RewindPlaylistEntry(RewindTrack *track) {
    if (!track.videoID.length) return nil;
    return [NSDictionary dictionaryWithObjectsAndKeys:
            track.videoID, @"id",
            track.title ?: @"Untitled", @"title",
            RewindTrackArtistText(track), @"artist",
            track.album ?: @"", @"album",
            track.thumbnailURL ?: @"", @"thumbnail",
            [NSNumber numberWithUnsignedInteger:track.duration], @"duration", nil];
}

static RewindTrack *RewindTrackFromEntry(NSDictionary *entry) {
    NSString *videoID = [entry objectForKey:@"id"];
    if (!videoID.length) return nil;
    NSString *artist = RewindDisplayArtist([entry objectForKey:@"artist"]);
    if ([artist caseInsensitiveCompare:@"Unknown artist"] == NSOrderedSame)
        artist = @"Various Artists";
    return [[[RewindTrack alloc] initWithVideoID:videoID
                                        title:[entry objectForKey:@"title"] ?: @"Untitled"
                                       artist:artist
                                        album:[entry objectForKey:@"album"] ?: @""
                                thumbnailURL:[entry objectForKey:@"thumbnail"] ?: @""
                                     duration:[[entry objectForKey:@"duration"] unsignedIntegerValue]]
            autorelease];
}

static NSMutableArray *RewindPlaylistRecords(void) {
    NSArray *records = [[NSUserDefaults standardUserDefaults]
                        objectForKey:REWIND_PLAYLISTS_DEFAULTS_KEY];
    if (![records isKindOfClass:[NSArray class]]) records = [NSArray array];
    return [NSMutableArray arrayWithArray:records];
}

static void RewindWritePlaylistRecords(NSArray *records) {
    [[NSUserDefaults standardUserDefaults] setObject:records forKey:REWIND_PLAYLISTS_DEFAULTS_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

NSArray *RewindPlaylistNames(void) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *record in RewindPlaylistRecords()) {
        NSString *name = [record objectForKey:@"name"];
        if (name.length) [names addObject:name];
    }
    return names;
}

void RewindCreatePlaylist(NSString *name) {
    NSString *clean = [name stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!clean.length) return;
    NSMutableArray *records = RewindPlaylistRecords();
    for (NSDictionary *record in records) {
        if ([[record objectForKey:@"name"] caseInsensitiveCompare:clean] == NSOrderedSame)
            return;
    }
    [records addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                        clean, @"name", [NSArray array], @"tracks", nil]];
    RewindWritePlaylistRecords(records);
}

void RewindCreatePlaylistWithTrack(NSString *name, RewindTrack *track,
                                   void (^completion)(NSError *error)) {
    if (!completion) return;
    if (track && (![track isKindOfClass:[RewindTrack class]] ||
                  ![track.videoID isKindOfClass:[NSString class]] || !track.videoID.length)) {
        completion([NSError errorWithDomain:@"com.sqmrak.rewind.playlists" code:400
            userInfo:[NSDictionary dictionaryWithObject:@"Track identifier is required" forKey:NSLocalizedDescriptionKey]]);
        return;
    }
    if (RewindAccountIsSignedIn()) {
        if (track && !rewind_audio_video_id([track.videoID UTF8String])) {
            completion([NSError errorWithDomain:@"com.sqmrak.rewind.playlists" code:400
                userInfo:[NSDictionary dictionaryWithObject:@"Invalid YouTube track identifier" forKey:NSLocalizedDescriptionKey]]);
            return;
        }
        RewindAccountCreatePlaylist(name, ^(NSArray *items, NSError *error) {
            if (error) { completion(error); return; }
            RewindTrack *playlist = [items isKindOfClass:[NSArray class]] && items.count == 1
                ? [items objectAtIndex:0] : nil;
            if (![playlist isKindOfClass:[RewindTrack class]] || !playlist.playlistID.length) {
                completion([NSError errorWithDomain:@"com.sqmrak.rewind.playlists" code:502
                    userInfo:[NSDictionary dictionaryWithObject:@"YouTube returned no created playlist" forKey:NSLocalizedDescriptionKey]]);
                return;
            }
            if (!track) { completion(nil); return; }
            RewindAccountAddPlaylistTrack(playlist.playlistID, track, ^(NSError *addError) {
                if (!addError) { completion(nil); return; }
                NSString *message = [NSString stringWithFormat:
                    @"YouTube playlist \"%@\" was created, but the track could not be added: %@",
                    playlist.title, [addError localizedDescription]];
                completion([NSError errorWithDomain:addError.domain code:addError.code
                    userInfo:[NSDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey]]);
            });
        });
        return;
    }
    NSString *clean = [name isKindOfClass:[NSString class]]
        ? [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
    if (!clean.length) {
        completion([NSError errorWithDomain:@"com.sqmrak.rewind.playlists" code:400
            userInfo:[NSDictionary dictionaryWithObject:@"Playlist name is required" forKey:NSLocalizedDescriptionKey]]);
        return;
    }
    RewindCreatePlaylist(clean);
    if (track) RewindAddTrackToPlaylist(track, clean);
    completion(nil);
}

static void RewindDeletePlaylist(NSString *name) {
    NSMutableArray *records = RewindPlaylistRecords();
    for (NSInteger index = (NSInteger)records.count - 1; index >= 0; --index)
        if ([[[records objectAtIndex:(NSUInteger)index] objectForKey:@"name"]
             caseInsensitiveCompare:name] == NSOrderedSame)
            [records removeObjectAtIndex:(NSUInteger)index];
    RewindWritePlaylistRecords(records);
}

void RewindAddTrackToPlaylist(RewindTrack *track, NSString *name) {
    NSDictionary *entry = RewindPlaylistEntry(track);
    if (!entry || !name.length) return;
    NSMutableArray *records = RewindPlaylistRecords();
    for (NSUInteger index = 0; index < records.count; ++index) {
        NSMutableDictionary *record = [[records objectAtIndex:index] mutableCopy];
        if ([[record objectForKey:@"name"] caseInsensitiveCompare:name] != NSOrderedSame) {
            [record release];
            continue;
        }
        NSMutableArray *tracks = [NSMutableArray arrayWithArray:
                                  [record objectForKey:@"tracks"] ?: [NSArray array]];
        for (NSInteger trackIndex = (NSInteger)tracks.count - 1; trackIndex >= 0; --trackIndex) {
            if ([[[tracks objectAtIndex:(NSUInteger)trackIndex] objectForKey:@"id"]
                 isEqualToString:[entry objectForKey:@"id"]])
                [tracks removeObjectAtIndex:(NSUInteger)trackIndex];
        }
        [tracks addObject:entry];
        [record setObject:tracks forKey:@"tracks"];
        [records replaceObjectAtIndex:index withObject:record];
        [record release];
        RewindWritePlaylistRecords(records);
        return;
    }
}

NSArray *RewindPlaylistsContainingTrack(RewindTrack *track) {
    NSMutableArray *names = [NSMutableArray array];
    if (!track.videoID.length) return names;
    for (NSDictionary *record in RewindPlaylistRecords()) {
        NSString *name = [record objectForKey:@"name"];
        for (NSDictionary *entry in [record objectForKey:@"tracks"]) {
            if ([[entry objectForKey:@"id"] isEqualToString:track.videoID]) {
                if (name.length) [names addObject:name];
                break;
            }
        }
    }
    return names;
}

void RewindRemoveTrackFromPlaylist(RewindTrack *track, NSString *name) {
    if (!track.videoID.length || !name.length) return;
    NSMutableArray *records = RewindPlaylistRecords();
    for (NSUInteger index = 0; index < records.count; ++index) {
        NSMutableDictionary *record = [[records objectAtIndex:index] mutableCopy];
        if ([[record objectForKey:@"name"] caseInsensitiveCompare:name] != NSOrderedSame) {
            [record release];
            continue;
        }
        NSMutableArray *tracks = [NSMutableArray arrayWithArray:
                                  [record objectForKey:@"tracks"] ?: [NSArray array]];
        for (NSInteger trackIndex = (NSInteger)tracks.count - 1; trackIndex >= 0; --trackIndex) {
            NSDictionary *entry = [tracks objectAtIndex:(NSUInteger)trackIndex];
            if ([[entry objectForKey:@"id"] isEqualToString:track.videoID])
                [tracks removeObjectAtIndex:(NSUInteger)trackIndex];
        }
        [record setObject:tracks forKey:@"tracks"];
        [records replaceObjectAtIndex:index withObject:record];
        [record release];
        RewindWritePlaylistRecords(records);
        return;
    }
}

NSArray *RewindTracksForPlaylist(NSString *name) {
    for (NSDictionary *record in RewindPlaylistRecords()) {
        if ([[record objectForKey:@"name"] caseInsensitiveCompare:name] != NSOrderedSame)
            continue;
        NSMutableArray *tracks = [NSMutableArray array];
        for (NSDictionary *entry in [record objectForKey:@"tracks"])
            if ([entry isKindOfClass:[NSDictionary class]]) {
                RewindTrack *track = RewindTrackFromEntry(entry);
                if (track) [tracks addObject:track];
            }
        return tracks;
    }
    return [NSArray array];
}

static NSString *RewindRemotePickerTitle(RewindTrack *playlist) {
    return [NSString stringWithFormat:@"%@ · YouTube", playlist.title];
}

NSArray *RewindPlaylistPickerTitles(void) {
    NSMutableArray *titles = [NSMutableArray arrayWithArray:RewindPlaylistNames()];
    if (!RewindAccountIsSignedIn()) return titles;
    for (RewindTrack *playlist in RewindAccountCachedPlaylists())
        if (RewindAccountPlaylistIsEditable(playlist.playlistID))
            [titles addObject:RewindRemotePickerTitle(playlist)];
    return titles;
}

void RewindAddTrackToPickedPlaylist(RewindTrack *track, NSString *title,
                                    void (^completion)(NSError *error)) {
    for (NSString *name in RewindPlaylistNames()) {
        if ([name caseInsensitiveCompare:title] != NSOrderedSame) continue;
        RewindAddTrackToPlaylist(track, name);
        if (completion) completion(nil);
        return;
    }
    if (RewindAccountIsSignedIn()) {
        for (RewindTrack *playlist in RewindAccountCachedPlaylists()) {
            if (!RewindAccountPlaylistIsEditable(playlist.playlistID) ||
                ![RewindRemotePickerTitle(playlist) isEqualToString:title])
                continue;
            RewindAccountEditPlaylist(playlist.playlistID, track, YES, completion);
            return;
        }
    }
    /* the picker listed a playlist that is gone now, so the add has nowhere to go */
    if (completion)
        completion([NSError errorWithDomain:@"com.sqmrak.rewind.playlists" code:404
                                   userInfo:[NSDictionary dictionaryWithObject:RewindL(@"playlist_gone")
                                                                        forKey:NSLocalizedDescriptionKey]]);
}

static UILabel *RewindPlaylistStatusLabel(void) {
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.font = [UIFont systemFontOfSize:13.0f];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.hidden = YES;
    return label;
}

@interface RewindPlaylistCell : UITableViewCell {
    RewindArtworkView *_artwork[4];
    NSUInteger _artworkCount;
    UILabel *_titleLabel;
    UILabel *_detailLabel;
}
- (void)configureWithName:(NSString *)name detail:(NSString *)detail artworkURLs:(NSArray *)urls;
@end

@implementation RewindPlaylistCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    for (NSUInteger index = 0; index < 4; ++index) {
        _artwork[index] = [[RewindArtworkView alloc] initWithFrame:
                           CGRectMake(RW(16.0f), RW(10.0f), RW(28.0f), RW(28.0f))];
        [self.contentView addSubview:_artwork[index]];
    }
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.font = RewindFont(16.0f, RewindWeightMedium);
    [self.contentView addSubview:_titleLabel];
    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.backgroundColor = [UIColor clearColor];
    _detailLabel.font = RewindFont(14.0f, RewindWeightRegular);
    [self.contentView addSubview:_detailLabel];
    return self;
}

- (void)dealloc {
    for (NSUInteger index = 0; index < 4; ++index) [_artwork[index] release];
    [_titleLabel release];
    [_detailLabel release];
    [super dealloc];
}

- (void)configureWithName:(NSString *)name detail:(NSString *)detail artworkURLs:(NSArray *)urls {
    _titleLabel.text = name;
    _detailLabel.text = detail;
    _artworkCount = MIN((NSUInteger)4, urls.count);
    for (NSUInteger index = 0; index < 4; ++index) {
        _artwork[index].hidden = index > 0 && _artworkCount < 2;
        if (_artworkCount >= 2) _artwork[index].hidden = index >= _artworkCount;
        [_artwork[index] setURL:index < _artworkCount ? [urls objectAtIndex:index] : nil];
    }
    _titleLabel.textColor = RewindColorText();
    _detailLabel.textColor = RewindColorTextSecondary();
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    CGFloat size = RW(56.0f);
    CGFloat artY = floorf((bounds.size.height - size) * 0.5f);
    BOOL collage = _artworkCount >= 2;
    for (NSUInteger index = 0; index < 4; ++index) {
        CGFloat tile = collage ? size * 0.5f : size;
        _artwork[index].frame = CGRectMake(RW(16.0f) + (collage ? (index % 2) * tile : 0.0f),
                                            artY + (collage ? (index / 2) * tile : 0.0f), tile, tile);
        [_artwork[index] setCornerRadius:collage ? 0.0f : RW(4.0f)];
    }
    CGFloat textX = RW(16.0f) + size + RW(12.0f);
    CGFloat width = MAX(RW(20.0f), bounds.size.width - textX - RW(8.0f));
    CGFloat y = floorf((bounds.size.height - RW(43.0f)) * 0.5f);
    _titleLabel.frame = CGRectMake(textX, y, width, RW(22.0f));
    _detailLabel.frame = CGRectMake(textX, y + RW(24.0f), width, RW(19.0f));
}

@end

@interface RewindPlaylistsVC ()
- (void)donePressed;
- (void)addPressed;
- (void)applyTheme:(NSNotification *)note;
- (void)languageChanged:(NSNotification *)note;
- (void)reloadRemote;
- (void)playlistMorePressed:(UIButton *)button;
@end

@implementation RewindPlaylistsVC

- (id)initWithPlayer:(RewindPlayer *)player api:(RewindAPI *)api {
    self = [super init];
    if (self) {
        _player = [player retain];
        _api = [api retain];
        _names = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_player release];
    [_api release];
    [_names release];
    [_remote release];
    [_deleteName release];
    [_table release];
    [_status release];
    [_backgroundGradient release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = RewindColorBackground();
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RewindL(@"playlists");
    self.navigationItem.leftBarButtonItem = RewindBarButtonItem(RewindL(@"done"), self, @selector(donePressed));
    self.navigationItem.rightBarButtonItem = RewindBarButtonItem(RewindL(@"add"), self, @selector(addPressed));
    _backgroundGradient = [[CAGradientLayer layer] retain];
    [self.view.layer insertSublayer:_backgroundGradient atIndex:0];
    _table = [[RewindTableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = [UIColor clearColor];
    _table.backgroundView = nil;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.rowHeight = RW(76.0f);
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];
    _status = [RewindPlaylistStatusLabel() retain];
    [self.view addSubview:_status];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(applyTheme:)
                   name:RewindThemeDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(languageChanged:)
                   name:REWIND_LANGUAGE_DID_CHANGE_NOTIFICATION object:nil];
    [center addObserver:self selector:@selector(accountLibraryChanged:)
                   name:RewindAccountLibraryDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(accountLibraryChanged:)
                   name:RewindAccountDidChangeNotification object:nil];
    [self applyTheme:nil];
}

- (void)languageChanged:(NSNotification *)note {
    (void)note;
    self.title = RewindL(@"playlists");
    self.navigationItem.leftBarButtonItem = RewindBarButtonItem(RewindL(@"done"), self, @selector(donePressed));
    self.navigationItem.rightBarButtonItem = RewindBarButtonItem(RewindL(@"add"), self, @selector(addPressed));
    _status.text = RewindL(@"no_playlists");
    [_table reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _backgroundGradient.frame = self.view.bounds;
    _table.frame = self.view.bounds;
    _status.frame = CGRectMake(24.0f, floorf(self.view.bounds.size.height * 0.4f),
                               self.view.bounds.size.width - 48.0f, 60.0f);
}

- (BOOL)showsRemote {
    return RewindAccountIsSignedIn();
}

- (void)reloadRows {
    [_names removeAllObjects];
    [_names addObjectsFromArray:RewindPlaylistNames()];
    [_remote release];
    _remote = [self showsRemote] ? [RewindAccountCachedPlaylists() copy] : nil;
    _status.hidden = _names.count || _remote.count;
    [_table reloadData];
}

- (void)reloadRemote {
    if (![self showsRemote]) return;
    NSUInteger request = ++_remoteRequest;
    [self retain];
    RewindAccountLoadPlaylists(^(NSArray *items, NSError *error) {
        (void)items;
        if (request == _remoteRequest && [self showsRemote] && error && !_remote.count) {
            _status.text = RewindFriendlyError(error);
            _status.hidden = NO;
        }
        [self release];
    });
}

- (void)accountLibraryChanged:(NSNotification *)note {
    (void)note;
    ++_remoteRequest;
    [self reloadRows];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _status.text = RewindL(@"no_playlists");
    [self reloadRows];
    [self reloadRemote];
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = RewindColorCanvas();
    RewindStyleNavigationBar(self.navigationController.navigationBar);
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)RewindColorBackground().CGColor,
                                  (id)RewindColorBackground().CGColor, nil];
    _status.textColor = RewindColorTextSecondary();
    [_table reloadData];
}

- (void)donePressed {
    /* always reached by a push (from the library or account screens), never
       presented, so dismissViewControllerAnimated: had nothing to dismiss */
    if (self.navigationController.viewControllers.count > 1)
        [self.navigationController popViewControllerAnimated:YES];
    else [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)addPressed {
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:RewindL(@"new_playlist")
                                                     message:[self showsRemote] ? @"YouTube · Private" : nil
                                                    delegate:self
                                           cancelButtonTitle:RewindL(@"cancel")
                                           otherButtonTitles:RewindL(@"create"), nil] autorelease];
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    [alert textFieldAtIndex:0].placeholder = RewindL(@"name_placeholder");
    alert.tag = 7301;
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == 7302) {
        if (buttonIndex != alertView.cancelButtonIndex) {
            RewindDeletePlaylist(_deleteName);
            [self reloadRows];
        }
        [_deleteName release];
        _deleteName = nil;
        return;
    }
    if (alertView.tag != 7301 || buttonIndex == alertView.cancelButtonIndex) return;
    NSString *name = [[alertView textFieldAtIndex:0].text
                      stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) return;
    if ([self showsRemote]) {
        self.navigationItem.rightBarButtonItem.enabled = NO;
        RewindCreatePlaylistWithTrack(name, nil, ^(NSError *error) {
            self.navigationItem.rightBarButtonItem.enabled = YES;
            if (error) {
                [[[[UIAlertView alloc] initWithTitle:RewindL(@"new_playlist")
                    message:[error localizedDescription] delegate:nil
                    cancelButtonTitle:RewindL(@"done") otherButtonTitles:nil] autorelease] show];
            } else [self reloadRows];
        });
    } else {
        RewindCreatePlaylist(name);
        [self reloadRows];
    }
}

/* youtube playlists come first, the way the youtube music library lists them */
- (BOOL)isRemoteSection:(NSInteger)section {
    return _remote.count && section == 0;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return _remote.count ? 2 : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return (NSInteger)([self isRemoteSection:section] ? _remote.count : _names.count);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (!_remote.count) return 0.0f;
    return [self isRemoteSection:section] || _names.count ? 30.0f : 0.0f;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if ([self tableView:tableView heightForHeaderInSection:section] <= 0.0f) return nil;
    UIView *header = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, tableView.bounds.size.width, 30.0f)] autorelease];
    header.backgroundColor = [UIColor clearColor];
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectMake(16.0f, 8.0f,
                                                                tableView.bounds.size.width - 32.0f, 18.0f)] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.font = [UIFont boldSystemFontOfSize:11.0f];
    label.textColor = RewindColorText();
    label.text = [self isRemoteSection:section] ? RewindL(@"section_youtube") : RewindL(@"section_on_device");
    [header addSubview:label];
    return header;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"RewindPlaylistCell";
    RewindPlaylistCell *cell = (RewindPlaylistCell *)[tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell)
        cell = [[[RewindPlaylistCell alloc] initWithStyle:UITableViewCellStyleDefault
                                        reuseIdentifier:cellID] autorelease];
    if ([self isRemoteSection:indexPath.section]) {
        RewindTrack *playlist = [_remote objectAtIndex:(NSUInteger)indexPath.row];
        [cell configureWithName:playlist.title
                         detail:playlist.artist.length ? playlist.artist : @"YouTube"
                    artworkURLs:playlist.thumbnailURL.length
                        ? [NSArray arrayWithObject:playlist.thumbnailURL] : [NSArray array]];
    } else {
        NSString *name = [_names objectAtIndex:(NSUInteger)indexPath.row];
        NSArray *tracks = RewindTracksForPlaylist(name);
        NSMutableArray *urls = [NSMutableArray array];
        for (RewindTrack *track in tracks) {
            if (track.thumbnailURL.length) [urls addObject:track.thumbnailURL];
            if (urls.count == 4) break;
        }
        if (urls.count > 1) {
            NSUInteger found = urls.count;
            while (urls.count < 4) [urls addObject:[urls objectAtIndex:urls.count % found]];
        }
        [cell configureWithName:name
                         detail:[NSString stringWithFormat:RewindL(@"tracks_count"),
                                 (unsigned long)tracks.count]
                    artworkURLs:urls];
    }
    UIButton *more = [UIButton buttonWithType:UIButtonTypeCustom];
    more.frame = CGRectMake(0, 0, RW(48.0f), RW(48.0f));
    more.tag = indexPath.section * 100000 + indexPath.row;
    [more setImage:RewindIcon(@"more", RW(23.0f), RewindColorText()) forState:UIControlStateNormal];
    [more addTarget:self action:@selector(playlistMorePressed:) forControlEvents:UIControlEventTouchUpInside];
    cell.accessoryView = more;
    return cell;
}

- (void)playlistMorePressed:(UIButton *)button {
    NSInteger section = button.tag / 100000;
    NSUInteger row = (NSUInteger)(button.tag % 100000);
    BOOL remote = [self isRemoteSection:section];
    if (row >= (remote ? _remote.count : _names.count)) return;
    RewindTrack *playlist = remote ? [_remote objectAtIndex:row] : nil;
    NSString *name = remote ? playlist.title : [_names objectAtIndex:row];
    __block RewindPlaylistsVC *owner = self;
    RewindSheet *sheet = [[[RewindSheet alloc] initWithFrame:self.view.bounds] autorelease];
    [sheet setHeaderTitle:name subtitle:remote ? @"YouTube" : RewindL(@"section_on_device") accessories:nil];
    NSMutableArray *items = [NSMutableArray array];
    if (!remote) {
        [items addObject:[RewindSheetItem itemWithIcon:@"shuffle" title:RewindL(@"shuffle")
                                             action:^{ [owner playLocalPlaylist:name shuffled:YES]; }]];
        [items addObject:[RewindSheetItem itemWithIcon:@"play" title:RewindL(@"play")
                                             action:^{ [owner playLocalPlaylist:name shuffled:NO]; }]];
        [items addObject:[RewindSheetItem itemWithIcon:@"delete" title:RewindL(@"delete_playlist")
                                             action:^{ [owner confirmDeletePlaylist:name]; }]];
    } else {
        [items addObject:[RewindSheetItem itemWithIcon:@"play" title:RewindL(@"open_playlist")
                                             action:^{ [owner openRemotePlaylist:playlist]; }]];
    }
    [sheet setItems:items];
    [sheet showInView:self.view];
}

- (void)playLocalPlaylist:(NSString *)name shuffled:(BOOL)shuffled {
    NSArray *tracks = RewindTracksForPlaylist(name);
    if (!tracks.count) {
        RewindShowToast(self.view, RewindL(@"no_tracks"), RewindBottomSafeInset());
        return;
    }
    [_player setQueue:tracks selectedIndex:0 usingAPI:_api];
    [_player setShuffling:shuffled];
    RewindRecordTrack([tracks objectAtIndex:0]);
}

- (void)openRemotePlaylist:(RewindTrack *)playlist {
    RewindPlaylistVC *page = [[[RewindPlaylistVC alloc] initWithRemotePlaylist:playlist
                                                                        player:_player api:_api] autorelease];
    [self.navigationController pushViewController:page animated:YES];
}

- (void)confirmDeletePlaylist:(NSString *)name {
    [_deleteName release];
    _deleteName = [name copy];
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:RewindL(@"delete_playlist")
                                                     message:name delegate:self
                                           cancelButtonTitle:RewindL(@"cancel")
                                           otherButtonTitles:RewindL(@"delete_playlist"), nil] autorelease];
    alert.tag = 7302;
    [alert show];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    RewindPlaylistVC *playlist = nil;
    if ([self isRemoteSection:indexPath.section]) {
        if ((NSUInteger)indexPath.row >= _remote.count) return;
        playlist = [[[RewindPlaylistVC alloc] initWithRemotePlaylist:[_remote objectAtIndex:(NSUInteger)indexPath.row]
                                                              player:_player api:_api] autorelease];
    } else {
        if ((NSUInteger)indexPath.row >= _names.count) return;
        playlist = [[[RewindPlaylistVC alloc] initWithName:[_names objectAtIndex:(NSUInteger)indexPath.row]
                                                    player:_player api:_api] autorelease];
    }
    [self.navigationController pushViewController:playlist animated:YES];
}

@end

static UILabel *RewindPlaylistLabel(CGFloat size, RewindWeight weight, UIColor *color) {
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.font = RewindFont(size, weight);
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

@interface RewindPlaylistVC ()
- (void)applyTheme:(NSNotification *)note;
- (void)languageChanged:(NSNotification *)note;
- (void)reloadData;
- (void)rebuildContent;
- (void)removeTrackAtIndex:(NSUInteger)index;
@end

@implementation RewindPlaylistVC

- (id)initWithName:(NSString *)name player:(RewindPlayer *)player api:(RewindAPI *)api {
    self = [super init];
    if (self) {
        _playlistName = [name copy];
        _player = [player retain];
        _api = [api retain];
        _tracks = [[NSMutableArray alloc] init];
    }
    return self;
}

- (id)initWithRemotePlaylist:(RewindTrack *)playlist player:(RewindPlayer *)player api:(RewindAPI *)api {
    self = [self initWithName:playlist.title player:player api:api];
    if (self) _remotePlaylist = [playlist retain];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_playlistName release];
    [_remotePlaylist release];
    [_player release];
    [_api release];
    [_tracks release];
    [_headerView release];
    [_headerArt release];
    [_headerScrimTop release];
    [_headerScrimBottom release];
    [_backBacking release];
    [_backButton release];
    [_playButton release];
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
       on pull down the way the artist header photo does */
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

    _nameLabel = [RewindPlaylistLabel(28.0f, RewindWeightBold, RewindColorText()) retain];
    _nameLabel.numberOfLines = 2;
    _nameLabel.text = _playlistName;
    [_headerView addSubview:_nameLabel];

    _subLabel = [RewindPlaylistLabel(13.0f, RewindWeightRegular,
                                     [UIColor colorWithWhite:1.0f alpha:0.75f]) retain];
    _subLabel.text = RewindL(@"loading_tracks");
    [_headerView addSubview:_subLabel];

    _playButton = [[RewindIconButton buttonWithIcon:@"play" points:RW(20.0f)] retain];
    _playButton.backgroundColor = RewindColorAccentFill();
    [_playButton setIconColor:RewindColorOnAccent()];
    [_playButton addTarget:self action:@selector(playPressed) forControlEvents:UIControlEventTouchUpInside];
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

    _status = [RewindPlaylistStatusLabel() retain];
    [_content addSubview:_status];

    if (_remotePlaylist.thumbnailURL.length) [_headerArt setURL:_remotePlaylist.thumbnailURL];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyTheme:)
                                                 name:RewindThemeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageChanged:)
                                                 name:REWIND_LANGUAGE_DID_CHANGE_NOTIFICATION
                                               object:nil];
    [self applyTheme:nil];
    [self reloadData];
}

- (void)languageChanged:(NSNotification *)note {
    (void)note;
    [self reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    if (!_remotePlaylist || !_tracks.count) [self reloadData];
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

    BOOL compact = height - top < RW(520.0f);
    _headerHeight = MAX(RW(240.0f), MIN(RW(420.0f), width * (compact ? 0.85f : 1.1f) + top));
    _headerView.frame = CGRectMake(0, 0, width, _headerHeight);
    _headerArt.frame = _headerView.bounds;
    [self scrollViewDidScroll:_content];
    CGFloat scrimH = MIN(_headerHeight, RW(210.0f));
    _headerScrimBottom.frame = CGRectMake(0, _headerHeight - scrimH, width, scrimH);

    CGFloat backSize = RW(40.0f);
    _backBacking.frame = CGRectMake(RW(10.0f), top + RW(6.0f), backSize, backSize);
    _backBacking.layer.cornerRadius = backSize * 0.5f;
    _backButton.frame = _backBacking.frame;

    CGFloat side = RW(16.0f), playSize = RW(48.0f);
    CGFloat rowY = _headerHeight - side - playSize;
    _playButton.frame = CGRectMake(side, rowY, playSize, playSize);
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

/* pulling past the top stretches the photo upward instead of leaving a blank gap */
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != _content) return;
    rewind_playlist_header_geometry_t geometry = RewindPlaylistHeaderGeometry(
        _headerHeight, scrollView.contentOffset.y, RW(110.0f));
    CGFloat width = _headerView.bounds.size.width;
    /* implicit layer animations lag behind the artwork during scroll and bounce */
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _headerArt.frame = CGRectMake(0, geometry.artwork_y, width, geometry.artwork_height);
    _headerScrimTop.frame = CGRectMake(0, geometry.scrim_y, width, geometry.scrim_height);
    [CATransaction commit];
}

/* albums are public pages; the tv client only renders the signed in user's lists */
- (BOOL)loadsFromPublicAPI {
    return [_remotePlaylist.resultType isEqualToString:RewindResultTypeAlbum] || !RewindAccountIsSignedIn();
}

- (BOOL)canEditTracks {
    if (!_remotePlaylist) return YES;
    if (!RewindAccountIsSignedIn() || [self loadsFromPublicAPI]) return NO;
    return [_remotePlaylist.playlistID isEqualToString:@"LM"] ||
           RewindAccountPlaylistIsEditable(_remotePlaylist.playlistID);
}

- (void)showRemoteTracks:(NSArray *)tracks error:(NSError *)error {
    [_tracks removeAllObjects];
    if (tracks) [_tracks addObjectsFromArray:tracks];
    _status.text = error ? RewindFriendlyError(error) : RewindL(@"no_tracks");
    _status.hidden = _tracks.count > 0;
    if (!_headerArt.image && _tracks.count)
        [_headerArt setURL:((RewindTrack *)[_tracks objectAtIndex:0]).thumbnailURL];
    [self rebuildContent];
}

- (void)reloadData {
    if (!_remotePlaylist) {
        [_tracks removeAllObjects];
        [_tracks addObjectsFromArray:RewindTracksForPlaylist(_playlistName)];
        _status.text = RewindL(@"no_tracks");
        _status.hidden = _tracks.count > 0;
        if (!_headerArt.image && _tracks.count)
            [_headerArt setURL:((RewindTrack *)[_tracks objectAtIndex:0]).thumbnailURL];
        [self rebuildContent];
        return;
    }
    NSUInteger request = ++_request;
    if (!_tracks.count) {
        _status.text = RewindL(@"loading_tracks");
        _status.hidden = NO;
    }
    [self retain];
    void (^finish)(NSArray *, NSError *) = ^(NSArray *tracks, NSError *error) {
        if (request == _request) [self showRemoteTracks:tracks error:error];
        [self release];
    };
    if ([self loadsFromPublicAPI]) {
        [_api playlistTracksForID:_remotePlaylist.playlistID completion:finish];
        return;
    }
    /* a long playlist is many pages; its first page shows at once instead of after the last one */
    RewindAccountLoadPlaylistTracksProgressive(_remotePlaylist.playlistID, ^(NSArray *tracks, NSError *error) {
        if (request == _request) [self showRemoteTracks:tracks error:error];
    }, finish);
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = RewindColorCanvas();
    _nameLabel.textColor = RewindColorText();
    _status.textColor = RewindColorTextSecondary();
    _headerScrimBottom.colors = [NSArray arrayWithObjects:
        (id)[RewindColorCanvas() colorWithAlphaComponent:0.0f].CGColor,
        (id)RewindColorCanvas().CGColor, nil];
    [self rebuildContent];
}

- (void)rebuildContent {
    if (!_content || _content.bounds.size.width < 1.0f) return;
    NSArray *old = [_content.subviews copy];
    for (UIView *view in old) if (view != _headerView) [view removeFromSuperview];
    [old release];
    CGFloat width = _content.bounds.size.width;
    CGFloat y = _headerHeight + RW(16.0f);
    _subLabel.text = [NSString stringWithFormat:RewindL(@"tracks_count"), (unsigned long)_tracks.count];

    if (!_tracks.count) {
        _status.frame = CGRectMake(RW(24.0f), y + RW(8.0f), width - RW(48.0f), RW(60.0f));
        [_content addSubview:_status];
        RewindUpdateStatusSpinner(_status, [_status.text isEqualToString:RewindL(@"loading_tracks")]);
        y = CGRectGetMaxY(_status.frame);
    } else {
        CGFloat rowH = [RewindTrackRow rowHeight];
        RewindTrack *current = _player.track;
        BOOL editable = [self canEditTracks];
        __block RewindPlaylistVC *owner = self;
        for (NSUInteger index = 0; index < _tracks.count; ++index) {
            RewindTrack *track = [_tracks objectAtIndex:index];
            RewindTrackRow *row = [[[RewindTrackRow alloc] initWithFrame:
                                    CGRectMake(0, y, width, rowH)] autorelease];
            [row setTrack:track];
            BOOL playing = current.videoID.length && [current.videoID isEqualToString:track.videoID];
            [row setPlaying:playing animating:_player.playing];
            [row setOnTap:^{ [owner playTrackAtIndex:index]; }];
            if (editable) [row setOnMore:^{ [owner confirmRemoveTrackAtIndex:index]; }];
            [_content addSubview:row];
            y += rowH;
        }
    }
    _content.contentSize = CGSizeMake(width, y + RW(32.0f));
}

- (void)playTrackAtIndex:(NSUInteger)index {
    if (index >= _tracks.count || !_player || !_api) return;
    RewindTrack *track = [_tracks objectAtIndex:index];
    [_player setQueue:_tracks selectedIndex:(NSInteger)index usingAPI:_api];
    RewindRecordTrack(track);
}

- (void)playPressed {
    [self playTrackAtIndex:0];
}

- (void)confirmRemoveTrackAtIndex:(NSUInteger)index {
    if (index >= _tracks.count) return;
    UIActionSheet *sheet = [[[UIActionSheet alloc]
                             initWithTitle:((RewindTrack *)[_tracks objectAtIndex:index]).title
                             delegate:self
                             cancelButtonTitle:RewindL(@"cancel")
                             destructiveButtonTitle:RewindL(@"menu_remove_playlist")
                             otherButtonTitles:nil] autorelease];
    sheet.tag = (NSInteger)(9700 + index);
    [sheet showInView:self.view.window ?: self.view];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex != actionSheet.destructiveButtonIndex) return;
    NSUInteger index = (NSUInteger)(actionSheet.tag - 9700);
    [self removeTrackAtIndex:index];
}

- (void)removeTrackAtIndex:(NSUInteger)index {
    if (index >= _tracks.count) return;
    RewindTrack *track = [[[_tracks objectAtIndex:index] retain] autorelease];
    if (!_remotePlaylist) {
        RewindRemoveTrackFromPlaylist(track, _playlistName);
    } else {
        void (^restore)(NSError *) = ^(NSError *error) {
            if (!error) return;
            /* the row went away optimistically; bring the list back to what youtube holds */
            [[[[UIAlertView alloc] initWithTitle:RewindL(@"menu_remove_playlist")
                                         message:RewindFriendlyError(error)
                                        delegate:nil cancelButtonTitle:RewindL(@"done")
                               otherButtonTitles:nil] autorelease] show];
            [self reloadData];
        };
        if ([_remotePlaylist.playlistID isEqualToString:@"LM"])
            RewindAccountSetLiked(track, NO, restore);
        else
            RewindAccountEditPlaylist(_remotePlaylist.playlistID, track, NO, restore);
    }
    [_tracks removeObjectAtIndex:index];
    [self rebuildContent];
}

- (void)backPressed {
    if (self.navigationController.viewControllers.count > 1)
        [self.navigationController popViewControllerAnimated:YES];
    else
        [self dismissViewControllerAnimated:YES completion:nil];
}

@end
