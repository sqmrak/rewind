#import "artist_vc.h"

#import <QuartzCore/QuartzCore.h>

#import "tunetube_image_cache.h"
#import "tunetube_theme.h"
#import "tunetube_l10n.h"
#import "library_vc.h"
#import "tunetube_api.h"
#import "tunetube_player.h"

static NSString *TuneArtistImageURL(NSString *url) {
    if (!url.length) return nil;
    if ([url hasPrefix:@"//"])
        return [NSString stringWithFormat:@"https:%@", url];
    return url;
}

static UIImage *TuneArtistAvatarFallback(NSString *artist, CGFloat size) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0.0f);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context, TuneThemeNavigationTop().CGColor);
    CGContextFillEllipseInRect(context, CGRectMake(0.0f, 0.0f, size, size));

    NSString *letter = artist.length ? [[artist substringToIndex:1] uppercaseString] : @"♪";
    UIFont *font = [UIFont boldSystemFontOfSize:size * 0.42f];
    CGSize textSize = [letter sizeWithFont:font];
    [TuneThemeHeaderText() set];
    [letter drawAtPoint:CGPointMake((size - textSize.width) * 0.5f,
                                    (size - textSize.height) * 0.5f)
               withFont:font];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@interface TuneArtistCell : UITableViewCell {
    UIView *_card;
    CAGradientLayer *_cardGradient;
    UIImageView *_artwork;
    UILabel *_titleLabel;
    UILabel *_albumLabel;
    UILabel *_durationLabel;
    NSString *_imageURL;
}
- (void)configureWithTrack:(TuneTubeTrack *)track artist:(NSString *)artist;
@end

@implementation TuneArtistCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.layer.cornerRadius = 10.0f;
    _card.layer.borderWidth = 1.0f;
    _card.layer.masksToBounds = YES;
    _card.layer.shouldRasterize = YES;
    _card.layer.rasterizationScale = [UIScreen mainScreen].scale;
    _cardGradient = [[CAGradientLayer layer] retain];
    _cardGradient.cornerRadius = 10.0f;
    [_card.layer insertSublayer:_cardGradient atIndex:0];
    [self.contentView addSubview:_card];

    _artwork = [[UIImageView alloc] initWithFrame:CGRectZero];
    _artwork.image = [UIImage imageNamed:@"Icon.png"];
    _artwork.contentMode = UIViewContentModeScaleAspectFill;
    _artwork.layer.cornerRadius = 7.0f;
    _artwork.layer.masksToBounds = YES;
    _artwork.layer.borderWidth = 1.0f;
    [_card addSubview:_artwork];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.font = [UIFont boldSystemFontOfSize:15.0f];
    _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [_card addSubview:_titleLabel];

    _albumLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _albumLabel.backgroundColor = [UIColor clearColor];
    _albumLabel.font = [UIFont systemFontOfSize:12.0f];
    _albumLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [_card addSubview:_albumLabel];

    _durationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _durationLabel.backgroundColor = [UIColor clearColor];
    _durationLabel.font = [UIFont systemFontOfSize:11.0f];
    _durationLabel.textAlignment = NSTextAlignmentRight;
    [_card addSubview:_durationLabel];
    return self;
}

- (void)dealloc {
    [_card release];
    [_cardGradient release];
    [_artwork release];
    [_titleLabel release];
    [_albumLabel release];
    [_durationLabel release];
    [_imageURL release];
    [super dealloc];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [_imageURL release];
    _imageURL = nil;
    _artwork.image = [UIImage imageNamed:@"Icon.png"];
    _titleLabel.text = nil;
    _albumLabel.text = nil;
    _durationLabel.text = nil;
}

- (void)configureWithTrack:(TuneTubeTrack *)track artist:(NSString *)artist {
    [_imageURL release];
    _imageURL = [TuneArtistImageURL(track.thumbnailURL) copy];
    _artwork.image = [UIImage imageNamed:@"Icon.png"];
    _titleLabel.text = track.title;
    _albumLabel.text = artist.length ? artist : @"Various Artists";
    if (track.duration) {
        _durationLabel.text = [NSString stringWithFormat:@"%lu:%02lu",
                               (unsigned long)(track.duration / 60),
                               (unsigned long)(track.duration % 60)];
    } else {
        _durationLabel.text = @"0:00";
    }
    _card.layer.borderColor = TuneThemeBorder().CGColor;
    _cardGradient.colors = [NSArray arrayWithObjects:
                            (id)TuneThemeSurfaceTop().CGColor,
                            (id)TuneThemeSurfaceBottom().CGColor, nil];
    _titleLabel.textColor = TuneThemePrimaryText();
    _albumLabel.textColor = TuneThemeSecondaryText();
    _durationLabel.textColor = TuneThemeMutedText();
    _artwork.layer.borderColor = TuneThemeBorder().CGColor;

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
    CGRect bounds = self.contentView.bounds;
    _card.frame = CGRectMake(8.0f, 4.0f, MAX(80.0f, bounds.size.width - 16.0f),
                             MAX(58.0f, bounds.size.height - 8.0f));
    _cardGradient.frame = _card.bounds;
    CGFloat right = _card.bounds.size.width - 12.0f;
    CGFloat imageSize = MIN(48.0f, _card.bounds.size.height - 12.0f);
    CGFloat imageY = floorf((_card.bounds.size.height - imageSize) * 0.5f);
    _artwork.frame = CGRectMake(10.0f, imageY, imageSize, imageSize);
    CGFloat textX = CGRectGetMaxX(_artwork.frame) + 12.0f;
    _titleLabel.frame = CGRectMake(textX, 9.0f, MAX(20.0f, right - textX - 64.0f), 22.0f);
    _albumLabel.frame = CGRectMake(textX, 34.0f, MAX(20.0f, right - textX), 18.0f);
    _durationLabel.frame = CGRectMake(right - 58.0f, 11.0f, 58.0f, 18.0f);
}

@end

@interface TuneArtistVC ()
- (void)applyTheme:(NSNotification *)note;
- (void)loadTracks;
- (void)loadAvatar;
- (void)applyAvatarURL:(NSString *)url;
- (void)backPressed;
@end

@implementation TuneArtistVC

- (id)initWithArtist:(NSString *)artist
          artworkURL:(NSString *)artworkURL
                 api:(TuneTubeAPI *)api
             player:(TuneTubePlayer *)player
          seedTrack:(TuneTubeTrack *)seedTrack {
    self = [super init];
    if (!self) return nil;
    _artistName = [artist copy];
    _artworkURL = [artworkURL copy];
    _api = [api retain];
    _player = [player retain];
    _seedTrack = [seedTrack retain];
    _tracks = [[NSMutableArray alloc] init];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_artistName release];
    [_artworkURL release];
    [_api release];
    [_player release];
    [_seedTrack release];
    [_tracks release];
    [_profileCard release];
    [_backgroundGradient release];
    [_profileGradient release];
    [_artwork release];
    [_artistLabel release];
    [_status release];
    [_table release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = TuneThemeBackgroundBottom();
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = TuneL(@"artist");
    self.navigationItem.leftBarButtonItem =
        TuneTubeBarButtonItem(TuneL(@"done"), self, @selector(backPressed));

    _backgroundGradient = [[CAGradientLayer layer] retain];
    [self.view.layer insertSublayer:_backgroundGradient atIndex:0];

    _profileCard = [[UIView alloc] initWithFrame:CGRectZero];
    _profileCard.layer.cornerRadius = 12.0f;
    _profileCard.layer.borderWidth = 1.0f;
    _profileCard.layer.masksToBounds = YES;
    _profileGradient = [[CAGradientLayer layer] retain];
    _profileGradient.cornerRadius = 12.0f;
    [_profileCard.layer insertSublayer:_profileGradient atIndex:0];
    [self.view addSubview:_profileCard];

    _artwork = [[UIImageView alloc] initWithFrame:CGRectZero];
    _artwork.image = TuneArtistAvatarFallback(_artistName, 128.0f);
    _artwork.contentMode = UIViewContentModeScaleAspectFill;
    _artwork.layer.cornerRadius = 10.0f;
    _artwork.layer.masksToBounds = YES;
    _artwork.layer.borderWidth = 1.0f;
    [_profileCard addSubview:_artwork];

    _artistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _artistLabel.backgroundColor = [UIColor clearColor];
    _artistLabel.font = [UIFont boldSystemFontOfSize:22.0f];
    _artistLabel.textColor = TuneThemePrimaryText();
    _artistLabel.text = _artistName;
    _artistLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [_profileCard addSubview:_artistLabel];

    _status = [[UILabel alloc] initWithFrame:CGRectZero];
    _status.backgroundColor = [UIColor clearColor];
    _status.font = [UIFont systemFontOfSize:12.0f];
    _status.textColor = TuneThemeSecondaryText();
    _status.text = TuneL(@"loading_tracks");
    [_profileCard addSubview:_status];

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
    [self loadTracks];
    if (_artworkURL.length) [self loadAvatar];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    _backgroundGradient.frame = bounds;

    CGFloat side = bounds.size.width > 700.0f ? 28.0f : 12.0f;
    CGFloat contentWidth = MIN(760.0f, bounds.size.width - side * 2.0f);
    CGFloat contentX = floorf((bounds.size.width - contentWidth) * 0.5f);
    CGFloat cardHeight = bounds.size.width > bounds.size.height ? 106.0f : 116.0f;
    _profileCard.frame = CGRectMake(contentX, 12.0f, contentWidth, cardHeight);
    _profileGradient.frame = _profileCard.bounds;
    CGFloat imageSize = bounds.size.width > bounds.size.height ? 78.0f : 88.0f;
    _artwork.frame = CGRectMake(12.0f, floorf((cardHeight - imageSize) * 0.5f),
                                imageSize, imageSize);
    _artwork.layer.cornerRadius = imageSize * 0.5f;
    CGFloat textX = CGRectGetMaxX(_artwork.frame) + 16.0f;
    CGFloat textWidth = MAX(60.0f, contentWidth - textX - 16.0f);
    _artistLabel.frame = CGRectMake(textX, cardHeight * 0.5f - 25.0f,
                                    textWidth, 30.0f);
    _status.frame = CGRectMake(textX, cardHeight * 0.5f + 10.0f,
                               textWidth, 20.0f);
    _table.frame = CGRectMake(0.0f, CGRectGetMaxY(_profileCard.frame) + 8.0f,
                              bounds.size.width,
                              MAX(1.0f, bounds.size.height - CGRectGetMaxY(_profileCard.frame) - 8.0f));
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = TuneThemeBackgroundBottom();
    TuneTubeStyleNavigationBar(self.navigationController.navigationBar);
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)TuneThemeBackgroundTop().CGColor,
                                  (id)TuneThemeBackgroundBottom().CGColor, nil];
    _profileGradient.colors = [NSArray arrayWithObjects:
                               (id)TuneThemeSurfaceTop().CGColor,
                               (id)TuneThemeSurfaceBottom().CGColor, nil];
    _profileCard.layer.borderColor = TuneThemeBorder().CGColor;
    _artwork.layer.borderColor = TuneThemeBorder().CGColor;
    _artwork.layer.borderWidth = 2.0f;
    _artistLabel.textColor = TuneThemePrimaryText();
    _status.textColor = TuneThemeSecondaryText();
    [_table reloadData];
}

- (void)applyAvatarURL:(NSString *)url {
    NSString *clean = TuneArtistImageURL(url);
    if (!clean.length) return;
    [_artworkURL release];
    _artworkURL = [clean copy];
    [self loadAvatar];
}

- (void)loadTracks {
    [_tracks removeAllObjects];
    if (_seedTrack) [_tracks addObject:_seedTrack];
    [_table reloadData];

    if (!_api || !_artistName.length ||
        [_artistName caseInsensitiveCompare:@"Various Artists"] == NSOrderedSame ||
        [_artistName caseInsensitiveCompare:@"YouTube Music"] == NSOrderedSame) {
        _status.text = _tracks.count ? TuneL(@"tracks") : TuneL(@"no_tracks");
        return;
    }

    // resolve real artist avatar first (not album cover from the seed track)
    if (_seedTrack.artistID.length) {
        [_api artistInfoForID:_seedTrack.artistID completion:^(NSString *name, NSString *avatarURL,
                                                               NSError *infoError) {
            (void)infoError;
            if (name.length) {
                [_artistName release];
                _artistName = [name copy];
                _artistLabel.text = _artistName;
            }
            if (avatarURL.length) [self applyAvatarURL:avatarURL];
        }];
    }

    [_api search:_artistName completion:^(NSArray *tracks, NSError *error) {
        if (error) {
            _status.text = _tracks.count ? TuneL(@"saved_track") : TuneL(@"couldnt_load_tracks");
            return;
        }

        // if we still have no browse id, steal one from matching search hits
        if (!_seedTrack.artistID.length) {
            for (TuneTubeTrack *track in tracks) {
                if (!track.artistID.length) continue;
                NSString *trackArtist = TuneTubeTrackArtistText(track);
                if ([trackArtist caseInsensitiveCompare:_artistName] != NSOrderedSame)
                    continue;
                [_api artistInfoForID:track.artistID completion:^(NSString *name,
                                                                  NSString *avatarURL,
                                                                  NSError *infoError) {
                    (void)name; (void)infoError;
                    if (avatarURL.length) [self applyAvatarURL:avatarURL];
                }];
                break;
            }
        }

        // last resort: channel-host thumbnail from results (never plain album art)
        if (!_artworkURL.length) {
            for (TuneTubeTrack *track in tracks) {
                NSString *url = track.thumbnailURL;
                if ([url rangeOfString:@"yt3.ggpht.com"].location != NSNotFound ||
                    [url rangeOfString:@"yt3.googleusercontent.com"].location != NSNotFound) {
                    [self applyAvatarURL:url];
                    break;
                }
            }
        }

        for (TuneTubeTrack *track in tracks) {
            BOOL duplicate = NO;
            for (TuneTubeTrack *existing in _tracks) {
                if (existing.videoID.length && [existing.videoID isEqualToString:track.videoID]) {
                    duplicate = YES;
                    break;
                }
            }
            if (!duplicate) [_tracks addObject:track];
            if (_tracks.count >= 30) break;
        }
        _status.text = [NSString stringWithFormat:TuneL(@"tracks_count"),
                        (unsigned long)_tracks.count];
        [_table reloadData];
    }];
}

- (void)loadAvatar {
    NSString *requestedURL = [TuneArtistImageURL(_artworkURL) copy];
    if (!requestedURL.length) {
        [requestedURL release];
        return;
    }
    TuneLoadImage(requestedURL, ^(UIImage *image) {
        if (image && [TuneArtistImageURL(_artworkURL) isEqualToString:requestedURL])
            _artwork.image = image;
        [requestedURL release];
    });
}

- (void)backPressed {
    if (self.navigationController.viewControllers.count > 1)
        [self.navigationController popViewControllerAnimated:YES];
    else
        [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)_tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"TuneArtistCell";
    TuneArtistCell *cell = (TuneArtistCell *)[tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell)
        cell = [[[TuneArtistCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:cellID] autorelease];
    [cell configureWithTrack:[_tracks objectAtIndex:(NSUInteger)indexPath.row]
                       artist:_artistName];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= _tracks.count) return;
    TuneTubeTrack *track = [_tracks objectAtIndex:(NSUInteger)indexPath.row];
    if (_player && _api) {
        [_player setQueue:_tracks selectedIndex:indexPath.row usingAPI:_api];
        TuneTubeRecordTrack(track);
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end

void TunePushArtistProfile(UIViewController *source,
                           TuneTubeTrack *track,
                           TuneTubeAPI *api,
                           TuneTubePlayer *player) {
    if (!source || !track) return;
    NSString *artist = TuneTubeTrackArtistText(track);
    if (!artist.length || [artist caseInsensitiveCompare:@"Various Artists"] == NSOrderedSame ||
        [artist caseInsensitiveCompare:@"YouTube Music"] == NSOrderedSame)
        return;
    TuneArtistVC *profile = [[[TuneArtistVC alloc]
                              initWithArtist:artist
                              artworkURL:nil
                              api:api
                              player:player
                              seedTrack:track] autorelease];
    [source.navigationController pushViewController:profile animated:YES];
}
