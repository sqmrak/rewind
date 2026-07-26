#import "playlist_vc.h"

#import <QuartzCore/QuartzCore.h>

#import "tunetube_image_cache.h"
#import "tunetube_theme.h"
#import "tunetube_l10n.h"
#import "ytm_api.h"
#import "ytm_player.h"
#import "library_vc.h"

static NSString * const TuneTubePlaylistsKey = @"TuneTubePlaylists";

static NSDictionary *TunePlaylistEntry(YTMTrack *track) {
    if (!track.videoID.length) return nil;
    return [NSDictionary dictionaryWithObjectsAndKeys:
            track.videoID, @"id",
            track.title ?: @"Untitled", @"title",
            YTMDisplayArtist(track.artist), @"artist",
            track.album ?: @"", @"album",
            track.thumbnailURL ?: @"", @"thumbnail",
            [NSNumber numberWithUnsignedInteger:track.duration], @"duration", nil];
}

static YTMTrack *TuneTrackFromEntry(NSDictionary *entry) {
    NSString *videoID = [entry objectForKey:@"id"];
    if (!videoID.length) return nil;
    return [[[YTMTrack alloc] initWithVideoID:videoID
                                        title:[entry objectForKey:@"title"] ?: @"Untitled"
                                       artist:YTMDisplayArtist([entry objectForKey:@"artist"])
                                        album:[entry objectForKey:@"album"] ?: @""
                                thumbnailURL:[entry objectForKey:@"thumbnail"] ?: @""
                                     duration:[[entry objectForKey:@"duration"] unsignedIntegerValue]]
            autorelease];
}

static NSMutableArray *TunePlaylistRecords(void) {
    NSArray *records = [[NSUserDefaults standardUserDefaults]
                        objectForKey:TuneTubePlaylistsKey];
    if (![records isKindOfClass:[NSArray class]]) records = [NSArray array];
    return [NSMutableArray arrayWithArray:records];
}

static void TuneWritePlaylistRecords(NSArray *records) {
    [[NSUserDefaults standardUserDefaults] setObject:records forKey:TuneTubePlaylistsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

NSArray *TuneTubePlaylistNames(void) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *record in TunePlaylistRecords()) {
        NSString *name = [record objectForKey:@"name"];
        if (name.length) [names addObject:name];
    }
    return names;
}

void TuneTubeCreatePlaylist(NSString *name) {
    NSString *clean = [name stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!clean.length) return;
    NSMutableArray *records = TunePlaylistRecords();
    for (NSDictionary *record in records) {
        if ([[record objectForKey:@"name"] caseInsensitiveCompare:clean] == NSOrderedSame)
            return;
    }
    [records addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                        clean, @"name", [NSArray array], @"tracks", nil]];
    TuneWritePlaylistRecords(records);
}

void TuneTubeAddTrackToPlaylist(YTMTrack *track, NSString *name) {
    NSDictionary *entry = TunePlaylistEntry(track);
    if (!entry || !name.length) return;
    NSMutableArray *records = TunePlaylistRecords();
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
        TuneWritePlaylistRecords(records);
        return;
    }
}

NSArray *TuneTubeTracksForPlaylist(NSString *name) {
    for (NSDictionary *record in TunePlaylistRecords()) {
        if ([[record objectForKey:@"name"] caseInsensitiveCompare:name] != NSOrderedSame)
            continue;
        NSMutableArray *tracks = [NSMutableArray array];
        for (NSDictionary *entry in [record objectForKey:@"tracks"])
            if ([entry isKindOfClass:[NSDictionary class]]) {
                YTMTrack *track = TuneTrackFromEntry(entry);
                if (track) [tracks addObject:track];
            }
        return tracks;
    }
    return [NSArray array];
}

@interface TunePlaylistCell : UITableViewCell {
    UIView *_card;
    CAGradientLayer *_gradient;
    UILabel *_titleLabel;
    UILabel *_detailLabel;
}
- (void)configureWithName:(NSString *)name count:(NSUInteger)count;
@end

@implementation TunePlaylistCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.layer.cornerRadius = 10.0f;
    _card.layer.masksToBounds = YES;
    _card.layer.borderWidth = 1.0f;
    _gradient = [[CAGradientLayer layer] retain];
    _gradient.cornerRadius = 10.0f;
    [_card.layer insertSublayer:_gradient atIndex:0];
    [self.contentView addSubview:_card];
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.font = [UIFont boldSystemFontOfSize:16.0f];
    [_card addSubview:_titleLabel];
    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.backgroundColor = [UIColor clearColor];
    _detailLabel.font = [UIFont systemFontOfSize:12.0f];
    [_card addSubview:_detailLabel];
    return self;
}

- (void)dealloc {
    [_card release];
    [_gradient release];
    [_titleLabel release];
    [_detailLabel release];
    [super dealloc];
}

- (void)configureWithName:(NSString *)name count:(NSUInteger)count {
    _titleLabel.text = name;
    _detailLabel.text = [NSString stringWithFormat:@"%lu tracks", (unsigned long)count];
    _card.layer.borderColor = TuneThemeBorder().CGColor;
    _gradient.colors = [NSArray arrayWithObjects:
                        (id)TuneThemeSurfaceTop().CGColor,
                        (id)TuneThemeSurfaceBottom().CGColor, nil];
    _titleLabel.textColor = TuneThemePrimaryText();
    _detailLabel.textColor = TuneThemeSecondaryText();
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _card.frame = CGRectMake(8.0f, 5.0f, self.contentView.bounds.size.width - 16.0f,
                             self.contentView.bounds.size.height - 10.0f);
    _gradient.frame = _card.bounds;
    _titleLabel.frame = CGRectMake(14.0f, 10.0f, _card.bounds.size.width - 28.0f, 23.0f);
    _detailLabel.frame = CGRectMake(14.0f, 34.0f, _card.bounds.size.width - 28.0f, 18.0f);
}

@end

@interface TunePlaylistTrackCell : UITableViewCell {
    UIView *_card;
    CAGradientLayer *_gradient;
    UIImageView *_artwork;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    NSString *_imageURL;
}
- (void)configureWithTrack:(YTMTrack *)track;
@end

@implementation TunePlaylistTrackCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.layer.cornerRadius = 10.0f;
    _card.layer.masksToBounds = YES;
    _card.layer.borderWidth = 1.0f;
    _gradient = [[CAGradientLayer layer] retain];
    _gradient.cornerRadius = 10.0f;
    [_card.layer insertSublayer:_gradient atIndex:0];
    [self.contentView addSubview:_card];
    _artwork = [[UIImageView alloc] initWithFrame:CGRectZero];
    _artwork.image = [UIImage imageNamed:@"Icon.png"];
    _artwork.contentMode = UIViewContentModeScaleAspectFill;
    _artwork.layer.cornerRadius = 7.0f;
    _artwork.layer.masksToBounds = YES;
    [_card addSubview:_artwork];
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.font = [UIFont boldSystemFontOfSize:15.0f];
    [_card addSubview:_titleLabel];
    _artistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _artistLabel.backgroundColor = [UIColor clearColor];
    _artistLabel.font = [UIFont systemFontOfSize:12.0f];
    [_card addSubview:_artistLabel];
    return self;
}

- (void)dealloc {
    [_card release];
    [_gradient release];
    [_artwork release];
    [_titleLabel release];
    [_artistLabel release];
    [_imageURL release];
    [super dealloc];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [_imageURL release];
    _imageURL = nil;
    _artwork.image = [UIImage imageNamed:@"Icon.png"];
    _titleLabel.text = nil;
    _artistLabel.text = nil;
}

- (void)configureWithTrack:(YTMTrack *)track {
    [_imageURL release];
    _imageURL = [track.thumbnailURL copy];
    _artwork.image = [UIImage imageNamed:@"Icon.png"];
    _titleLabel.text = track.title;
    _artistLabel.text = YTMDisplayArtist(track.artist);
    _card.layer.borderColor = TuneThemeBorder().CGColor;
    _gradient.colors = [NSArray arrayWithObjects:
                        (id)TuneThemeSurfaceTop().CGColor,
                        (id)TuneThemeSurfaceBottom().CGColor, nil];
    _titleLabel.textColor = TuneThemePrimaryText();
    _artistLabel.textColor = TuneThemeSecondaryText();
    if (_imageURL.length) {
        NSString *requestedURL = [_imageURL copy];
        TuneLoadImage(requestedURL, ^(UIImage *image) {
            if (image && [_imageURL isEqualToString:requestedURL])
                _artwork.image = image;
            [requestedURL release];
        });
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _card.frame = CGRectMake(8.0f, 5.0f, self.contentView.bounds.size.width - 16.0f,
                             self.contentView.bounds.size.height - 10.0f);
    _gradient.frame = _card.bounds;
    _artwork.frame = CGRectMake(9.0f, 8.0f, 58.0f, 58.0f);
    _titleLabel.frame = CGRectMake(79.0f, 12.0f, _card.bounds.size.width - 92.0f, 22.0f);
    _artistLabel.frame = CGRectMake(79.0f, 37.0f, _card.bounds.size.width - 92.0f, 18.0f);
}

@end

@interface TunePlaylistsVC ()
- (void)donePressed;
- (void)addPressed;
- (void)applyTheme:(NSNotification *)note;
@end

@implementation TunePlaylistsVC

- (id)initWithPlayer:(YTMPlayer *)player api:(YTMAPI *)api {
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
    [_table release];
    [_backgroundGradient release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = TuneThemeBackgroundBottom();
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = TuneL(@"playlists");
    self.navigationItem.leftBarButtonItem = TuneTubeBarButtonItem(TuneL(@"done"), self, @selector(donePressed));
    self.navigationItem.rightBarButtonItem = TuneTubeBarButtonItem(TuneL(@"add"), self, @selector(addPressed));
    _backgroundGradient = [[CAGradientLayer layer] retain];
    [self.view.layer insertSublayer:_backgroundGradient atIndex:0];
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = [UIColor clearColor];
    _table.backgroundView = nil;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.rowHeight = 68.0f;
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyTheme:)
                                                 name:TuneTubeThemeDidChangeNotification
                                               object:nil];
    [self applyTheme:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _backgroundGradient.frame = self.view.bounds;
    _table.frame = self.view.bounds;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_names removeAllObjects];
    [_names addObjectsFromArray:TuneTubePlaylistNames()];
    [_table reloadData];
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = TuneThemeBackgroundBottom();
    TuneTubeStyleNavigationBar(self.navigationController.navigationBar);
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)TuneThemeBackgroundTop().CGColor,
                                  (id)TuneThemeBackgroundBottom().CGColor, nil];
    [_table reloadData];
}

- (void)donePressed {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)addPressed {
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:TuneL(@"new_playlist")
                                                     message:nil
                                                    delegate:self
                                           cancelButtonTitle:TuneL(@"cancel")
                                           otherButtonTitles:TuneL(@"create"), nil] autorelease];
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    [alert textFieldAtIndex:0].placeholder = TuneL(@"name_placeholder");
    alert.tag = 7301;
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag != 7301 || buttonIndex == alertView.cancelButtonIndex) return;
    NSString *name = [[alertView textFieldAtIndex:0].text
                      stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) return;
    TuneTubeCreatePlaylist(name);
    [_names removeAllObjects];
    [_names addObjectsFromArray:TuneTubePlaylistNames()];
    [_table reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)_names.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"TunePlaylistCell";
    TunePlaylistCell *cell = (TunePlaylistCell *)[tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell)
        cell = [[[TunePlaylistCell alloc] initWithStyle:UITableViewCellStyleDefault
                                        reuseIdentifier:cellID] autorelease];
    NSString *name = [_names objectAtIndex:(NSUInteger)indexPath.row];
    [cell configureWithName:name count:TuneTubeTracksForPlaylist(name).count];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= _names.count) return;
    TunePlaylistVC *playlist = [[[TunePlaylistVC alloc]
                                 initWithName:[_names objectAtIndex:(NSUInteger)indexPath.row]
                                 player:_player api:_api] autorelease];
    [self.navigationController pushViewController:playlist animated:YES];
}

@end

@interface TunePlaylistVC ()
- (void)applyTheme:(NSNotification *)note;
@end

@implementation TunePlaylistVC

- (id)initWithName:(NSString *)name player:(YTMPlayer *)player api:(YTMAPI *)api {
    self = [super init];
    if (self) {
        _playlistName = [name copy];
        _player = [player retain];
        _api = [api retain];
        _tracks = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_playlistName release];
    [_player release];
    [_api release];
    [_tracks release];
    [_table release];
    [_backgroundGradient release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = TuneThemeBackgroundBottom();
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _playlistName;
    self.navigationItem.leftBarButtonItem = TuneTubeBarButtonItem(TuneL(@"back"), self, @selector(backPressed));
    _backgroundGradient = [[CAGradientLayer layer] retain];
    [self.view.layer insertSublayer:_backgroundGradient atIndex:0];
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = [UIColor clearColor];
    _table.backgroundView = nil;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.rowHeight = 76.0f;
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyTheme:)
                                                 name:TuneTubeThemeDidChangeNotification
                                               object:nil];
    [self applyTheme:nil];
    [self reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _backgroundGradient.frame = self.view.bounds;
    _table.frame = self.view.bounds;
}

- (void)reloadData {
    [_tracks removeAllObjects];
    [_tracks addObjectsFromArray:TuneTubeTracksForPlaylist(_playlistName)];
    [_table reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadData];
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = TuneThemeBackgroundBottom();
    TuneTubeStyleNavigationBar(self.navigationController.navigationBar);
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)TuneThemeBackgroundTop().CGColor,
                                  (id)TuneThemeBackgroundBottom().CGColor, nil];
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
    static NSString *cellID = @"TunePlaylistTrackCell";
    TunePlaylistTrackCell *cell = (TunePlaylistTrackCell *)[tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell)
        cell = [[[TunePlaylistTrackCell alloc] initWithStyle:UITableViewCellStyleDefault
                                             reuseIdentifier:cellID] autorelease];
    [cell configureWithTrack:[_tracks objectAtIndex:(NSUInteger)indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= _tracks.count || !_player || !_api) return;
    YTMTrack *track = [_tracks objectAtIndex:(NSUInteger)indexPath.row];
    [_player setQueue:_tracks selectedIndex:indexPath.row usingAPI:_api];
    TuneTubeRecordTrack(track);
    [self.navigationController popViewControllerAnimated:YES];
}

@end
