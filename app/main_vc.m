#import "main_vc.h"

#import <QuartzCore/QuartzCore.h>

#import "ytm_api.h"
#import "ytm_player.h"
#import "settings_vc.h"
#import "player_vc.h"
#import "library_vc.h"
#import "playlist_vc.h"
#import "artist_vc.h"
#import "play_button.h"
#import "tunetube_config.h"
#import "tunetube_image_cache.h"
#import "tunetube_theme.h"
#import "tunetube_l10n.h"

static UIImage *TuneMaskImage(UIImage *mask, UIColor *color) {
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

static UIImage *TuneLibraryImage(CGFloat size) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0.0f);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(context, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(context, MAX(1.3f, size * 0.075f));
    CGContextSetLineJoin(context, kCGLineJoinRound);
    CGContextSetLineCap(context, kCGLineCapRound);

    CGRect rear = CGRectMake(size * 0.18f, size * 0.14f, size * 0.58f, size * 0.66f);
    CGRect front = CGRectMake(size * 0.31f, size * 0.25f, size * 0.56f, size * 0.62f);
    CGContextStrokeRect(context, rear);
    CGContextStrokeRect(context, front);
    CGContextMoveToPoint(context, size * 0.43f, size * 0.45f);
    CGContextAddLineToPoint(context, size * 0.76f, size * 0.45f);
    CGContextMoveToPoint(context, size * 0.43f, size * 0.58f);
    CGContextAddLineToPoint(context, size * 0.76f, size * 0.58f);
    CGContextStrokePath(context);

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static NSString *TunePlaybackErrorText(NSError *error) {
    NSString *text = [error localizedDescription];
    NSString *lower = [text lowercaseString];
    if ([lower rangeOfString:@"operation could not be completed"].location != NSNotFound ||
        [lower rangeOfString:@"nsurlerrordomain"].location != NSNotFound)
        return TuneL(@"err_load_song");
    return text;
}

static BOOL TuneIsNetworkError(NSError *error) {
    if (!error) return NO;
    switch (error.code) {
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorTimedOut:
        case NSURLErrorSecureConnectionFailed:
            return YES;
        default:
            break;
    }
    NSString *lower = [[error localizedDescription] lowercaseString];
    return [lower rangeOfString:@"internet connection"].location != NSNotFound ||
           [lower rangeOfString:@"network connection"].location != NSNotFound ||
           [lower rangeOfString:@"nsurlerrordomain"].location != NSNotFound;
}

static BOOL TuneRecommendationArtistIsValid(NSString *value) {
    NSString *clean = [value stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lower = [clean lowercaseString];
    NSArray *labels = [NSArray arrayWithObjects:
                       @"unknown artist", @"episode", @"song", @"video",
                       @"album", @"playlist", @"music", @"youtube music", nil];
    NSArray *months = [NSArray arrayWithObjects:
                       @"jan", @"feb", @"mar", @"apr", @"may", @"jun",
                       @"jul", @"aug", @"sep", @"oct", @"nov", @"dec", nil];
    NSArray *parts = [clean componentsSeparatedByString:@" "];
    if (!clean.length || [labels containsObject:lower] ||
        [clean rangeOfString:@"•"].location != NSNotFound ||
        [lower rangeOfString:@" plays"].location != NSNotFound ||
        [lower rangeOfString:@" views"].location != NSNotFound)
        return NO;
    if (parts.count == 3 && [months containsObject:[[parts objectAtIndex:0] lowercaseString]] &&
        [[parts objectAtIndex:2] integerValue] >= 1900)
        return NO;
    return YES;
}

@interface TuneTrackCell : UITableViewCell {
    UIView *_card;
    CAGradientLayer *_cardGradient;
    UIImageView *_artwork;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    UILabel *_durationLabel;
    NSString *_imageURL;
    YTMTrack *_track;
    id<TuneArtistTrackCellDelegate> _artistDelegate;
    UIButton *_artistButton;
}

@property(nonatomic, readonly) NSString *imageURL;
- (void)setArtistDelegate:(id<TuneArtistTrackCellDelegate>)delegate;
- (void)configureWithTrack:(YTMTrack *)track;
@end

@implementation TuneTrackCell

- (NSString *)imageURL {
    return _imageURL;
}

- (void)applyTheme {
    _card.layer.borderColor = TuneThemeBorder().CGColor;
    _cardGradient.colors = [NSArray arrayWithObjects:
                            (id)TuneThemeSurfaceTop().CGColor,
                            (id)TuneThemeSurfaceBottom().CGColor, nil];
    _artwork.backgroundColor = TuneThemeSurface();
    _titleLabel.textColor = TuneThemePrimaryText();
    _artistLabel.textColor = TuneThemeSecondaryText();
    _durationLabel.textColor = TuneThemeMutedText();
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
    _card.layer.borderColor = TuneThemeBorder().CGColor;
    _card.layer.shadowColor = [UIColor blackColor].CGColor;
    _card.layer.shadowOpacity = 0.38f;
    _card.layer.shadowOffset = CGSizeMake(0.0f, 2.0f);
    _card.layer.shadowRadius = 2.0f;
    _card.layer.shouldRasterize = YES;
    _card.layer.rasterizationScale = [UIScreen mainScreen].scale;
    _cardGradient = [[CAGradientLayer layer] retain];
    _cardGradient.cornerRadius = 10.0f;
    _cardGradient.colors = [NSArray arrayWithObjects:
                            (id)TuneThemeSurfaceTop().CGColor,
                            (id)TuneThemeSurfaceBottom().CGColor, nil];
    [_card.layer insertSublayer:_cardGradient atIndex:0];
    [self.contentView addSubview:_card];

    _artwork = [[UIImageView alloc] initWithFrame:CGRectZero];
    _artwork.backgroundColor = TuneThemeSurface();
    _artwork.layer.cornerRadius = 7.0f;
    _artwork.layer.masksToBounds = YES;
    _artwork.contentMode = UIViewContentModeScaleAspectFill;
    _artwork.image = [UIImage imageNamed:@"Icon.png"];
    [_card addSubview:_artwork];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.textColor = TuneThemePrimaryText();
    _titleLabel.font = [UIFont boldSystemFontOfSize:15.0f];
    _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [_card addSubview:_titleLabel];

    _artistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _artistLabel.backgroundColor = [UIColor clearColor];
    _artistLabel.textColor = TuneThemeSecondaryText();
    _artistLabel.font = [UIFont systemFontOfSize:13.0f];
    _artistLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [_card addSubview:_artistLabel];

    _durationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _durationLabel.backgroundColor = [UIColor clearColor];
    _durationLabel.textColor = TuneThemeMutedText();
    _durationLabel.font = [UIFont systemFontOfSize:11.0f];
    _durationLabel.textAlignment = NSTextAlignmentRight;
    [_card addSubview:_durationLabel];

    _artistButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _artistButton.adjustsImageWhenHighlighted = NO;
    _artistButton.accessibilityLabel = TuneL(@"artist_profile");
    [_artistButton addTarget:self action:@selector(artistPressed:)
            forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_artistButton];
    return self;
}

- (void)dealloc {
    [_card release];
    [_cardGradient release];
    [_artwork release];
    [_titleLabel release];
    [_artistLabel release];
    [_durationLabel release];
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
    _durationLabel.text = nil;
}

- (void)setArtistDelegate:(id<TuneArtistTrackCellDelegate>)delegate {
    _artistDelegate = delegate;
}

- (void)configureWithTrack:(YTMTrack *)track {
    [self applyTheme];
    [_track release];
    _track = [track retain];
    [_imageURL release];
    _imageURL = [track.thumbnailURL copy];
    _titleLabel.text = track.title;
    _artistLabel.text = YTMTrackArtistText(track);
    if (!track.isPlaylist && track.album.length)
        _artistLabel.text = [NSString stringWithFormat:@"%@  ·  %@",
                             YTMTrackArtistText(track), track.album];

    NSUInteger seconds = track.duration;
    if (seconds) {
        _durationLabel.text = [NSString stringWithFormat:@"%lu:%02lu",
                               (unsigned long)(seconds / 60),
                               (unsigned long)(seconds % 60)];
    } else {
        _durationLabel.text = track.isPlaylist ? TuneL(@"playlist") : TuneL(@"music");
    }
    NSString *artistName = YTMTrackArtistText(track);
    if ([artistName caseInsensitiveCompare:@"Unknown artist"] == NSOrderedSame)
        _artistLabel.text = track.album.length
            ? [NSString stringWithFormat:@"%@  ·  %@", TuneL(@"unknown_artist"), track.album]
            : TuneL(@"unknown_artist");
    BOOL hasArtist = artistName.length > 0 &&
        [artistName caseInsensitiveCompare:@"Unknown artist"] != NSOrderedSame &&
        [artistName caseInsensitiveCompare:@"YouTube Music"] != NSOrderedSame;
    _artistButton.hidden = track.isPlaylist || !hasArtist;

    if (!_imageURL.length) return;
    NSString *requestedURL = _imageURL;
    TuneLoadImage(requestedURL, ^(UIImage *image) {
        if (image && [_imageURL isEqualToString:requestedURL]) {
            _artwork.image = image;
        }
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
                             MAX(64.0f, bounds.size.height - 10.0f));
    _cardGradient.frame = _card.bounds;
    CGFloat artworkY = floorf((_card.bounds.size.height - 58.0f) * 0.5f);
    _artwork.frame = CGRectMake(8.0f, artworkY, 58.0f, 58.0f);
    CGFloat textX = 78.0f;
    CGFloat right = _card.bounds.size.width - 12.0f;
    CGFloat textY = floorf((_card.bounds.size.height - 45.0f) * 0.5f);
    _titleLabel.frame = CGRectMake(textX, textY, MAX(20.0f, right - textX - 48.0f), 22.0f);
    _artistLabel.frame = CGRectMake(textX, textY + 24.0f, MAX(20.0f, right - textX - 8.0f), 19.0f);
    _durationLabel.frame = CGRectMake(right - 48.0f, textY, 48.0f, 18.0f);
    _artistButton.frame = _artistLabel.frame;
}

@end

@interface MainVC () <TuneArtistTrackCellDelegate>
- (void)refreshPlayerUI:(NSNotification *)note;
- (void)loadQuickPicks;
- (void)settingsPressed;
- (void)focusSearch:(NSNotification *)note;
- (void)applyTheme:(NSNotification *)note;
- (void)appDidBecomeActive:(NSNotification *)note;
- (void)favoritePressed;
- (void)buildRecommendationsForQuery:(NSString *)query tracks:(NSArray *)tracks;
- (void)rebuildRecommendations;
- (void)recommendationPressed:(UIButton *)button;
- (void)playlistSwipe:(UISwipeGestureRecognizer *)gesture;
- (void)showPlaylistPickerForTrack:(YTMTrack *)track;
- (void)libraryPressed;
- (void)playerPressed;
- (void)tuneArtistCell:(id)cell didSelectTrack:(YTMTrack *)track;
@end

@implementation MainVC

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_api release];
    [_player release];
    [_tracks release];
    [_backgroundGradient release];
    [_search release];
    [_libraryButton release];
    [_optionsButton release];
    [_brandLabel release];
    [_taglineLabel release];
    [_sectionTitle release];
    [_table release];
    [_status release];
    [_recommendationScroll release];
    [_recommendations release];
    [_playlistTrack release];
    [_miniPlayer release];
    [_miniPlayerGradient release];
    [_miniArtwork release];
    [_nowTitle release];
    [_nowArtist release];
    [_favoriteButton release];
    [_playButton release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = TuneThemeBackgroundBottom();
    self.view = view;
}

- (void)reloadLocalizedChrome {
    self.navigationItem.leftBarButtonItem =
        [[[UIBarButtonItem alloc] initWithTitle:TuneL(@"library")
                                          style:UIBarButtonItemStyleBordered
                                         target:self
                                         action:@selector(libraryPressed)] autorelease];
    self.navigationItem.rightBarButtonItem =
        [[[UIBarButtonItem alloc] initWithTitle:TuneL(@"settings")
                                          style:UIBarButtonItemStyleBordered
                                         target:self
                                         action:@selector(settingsPressed)] autorelease];
    _taglineLabel.text = TuneL(@"tagline");
    _libraryButton.accessibilityLabel = TuneL(@"library");
    _optionsButton.accessibilityLabel = TuneL(@"settings");
    _search.placeholder = TuneL(@"search_placeholder");
    if (!_search.text.length && (!_tracks.count || !_sectionTitle.text.length ||
        [_sectionTitle.text isEqualToString:TuneL(@"search_results")] == NO)) {
        // keep search results label if user is mid-search
    }
    BOOL searching = _search.text.length > 0;
    _sectionTitle.text = searching ? TuneL(@"search_results") : TuneL(@"quick_picks");
    if (![(YTMPlayer *)_player track]) {
        _nowTitle.text = TuneL(@"nothing_playing");
        _nowArtist.text = TuneL(@"pick_song");
    }
    [_table reloadData];
}

- (void)languageChanged:(NSNotification *)note {
    (void)note;
    [self reloadLocalizedChrome];
    [self refreshPlayerUI:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"TuneTube";
    self.navigationController.navigationBarHidden = NO;
    _tracks = [[NSMutableArray alloc] init];

    _backgroundGradient = [[CAGradientLayer layer] retain];
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)TuneThemeBackgroundTop().CGColor,
                                  (id)TuneThemeBackgroundBottom().CGColor, nil];
    _backgroundGradient.locations = [NSArray arrayWithObjects:@0.0f, @1.0f, nil];
    [self.view.layer insertSublayer:(CAGradientLayer *)_backgroundGradient atIndex:0];

    NSString *key = [[NSUserDefaults standardUserDefaults]
                     objectForKey:TUNETUBE_API_KEY_DEFAULTS_KEY];
    _api = [[YTMAPI alloc] initWithAPIKey:key.length ? key : YTMDefaultAPIKey];
    _player = [[YTMPlayer alloc] init];

    _brandLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _brandLabel.backgroundColor = [UIColor clearColor];
    _brandLabel.textColor = TuneThemePrimaryText();
    _brandLabel.font = [UIFont boldSystemFontOfSize:25.0f];
    _brandLabel.text = @"TuneTube";
    _brandLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.65f];
    _brandLabel.shadowOffset = CGSizeMake(0.0f, 2.0f);
    [self.view addSubview:_brandLabel];

    _taglineLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _taglineLabel.backgroundColor = [UIColor clearColor];
    _taglineLabel.textColor = TuneThemeSecondaryText();
    _taglineLabel.font = [UIFont systemFontOfSize:10.0f];
    _taglineLabel.text = TuneL(@"tagline");
    _brandLabel.hidden = YES;
    _taglineLabel.hidden = YES;
    [self.view addSubview:_taglineLabel];

    _libraryButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    [_libraryButton setImage:TuneMaskImage(TuneLibraryImage(24.0f), TuneThemePrimaryText())
                    forState:UIControlStateNormal];
    _libraryButton.accessibilityLabel = TuneL(@"library");
    _libraryButton.hidden = YES;
    _libraryButton.imageEdgeInsets = UIEdgeInsetsMake(5.0f, 5.0f, 5.0f, 5.0f);
    _libraryButton.layer.cornerRadius = 8.0f;
    _libraryButton.layer.borderWidth = 1.0f;
    _libraryButton.layer.borderColor = TuneThemeBorder().CGColor;
    _libraryButton.backgroundColor = TuneThemeSurface();
    _libraryButton.layer.shadowColor = [UIColor blackColor].CGColor;
    _libraryButton.layer.shadowOpacity = 0.24f;
    _libraryButton.layer.shadowOffset = CGSizeMake(0.0f, 2.0f);
    _libraryButton.layer.shadowRadius = 1.5f;
    [_libraryButton addTarget:self action:@selector(libraryPressed)
             forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_libraryButton];

    _optionsButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    UIImage *settingsImage = [UIImage imageNamed:@"icon-settings.png"];
    if (settingsImage)
        [_optionsButton setImage:TuneMaskImage(settingsImage, TuneThemePrimaryText())
                        forState:UIControlStateNormal];
    else
        [_optionsButton setTitle:@"⚙" forState:UIControlStateNormal];
    _optionsButton.accessibilityLabel = TuneL(@"settings");
    _optionsButton.hidden = YES;
    _optionsButton.imageEdgeInsets = UIEdgeInsetsMake(6.0f, 6.0f, 6.0f, 6.0f);
    _optionsButton.layer.cornerRadius = 8.0f;
    _optionsButton.layer.borderWidth = 1.0f;
    _optionsButton.layer.borderColor = TuneThemeBorder().CGColor;
    _optionsButton.backgroundColor = TuneThemeSurface();
    [_optionsButton addTarget:self action:@selector(settingsPressed)
             forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_optionsButton];

    _search = [[UISearchBar alloc] initWithFrame:CGRectZero];
    _search.placeholder = TuneL(@"search_placeholder");
    _search.delegate = self;
    _search.barStyle = UIBarStyleBlack;
    _search.tintColor = TuneThemeHeaderText();
    _search.backgroundColor = TuneThemeSearchBackground();
    _search.layer.cornerRadius = 8.0f;
    _search.layer.borderWidth = 1.0f;
    _search.layer.borderColor = TuneThemeBorder().CGColor;
    _search.layer.masksToBounds = YES;
    [self.view addSubview:_search];

    _recommendations = [[NSMutableArray alloc] init];
    _recommendationScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _recommendationScroll.backgroundColor = [UIColor clearColor];
    _recommendationScroll.showsHorizontalScrollIndicator = NO;
    _recommendationScroll.showsVerticalScrollIndicator = NO;
    _recommendationScroll.hidden = YES;
    [self.view addSubview:_recommendationScroll];

    _sectionTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _sectionTitle.backgroundColor = [UIColor clearColor];
    _sectionTitle.textColor = TuneThemePrimaryText();
    _sectionTitle.font = [UIFont boldSystemFontOfSize:12.0f];
    _sectionTitle.text = TuneL(@"quick_picks");
    [self.view addSubview:_sectionTitle];

    _status = [[UILabel alloc] initWithFrame:CGRectZero];
    _status.backgroundColor = [UIColor clearColor];
    _status.textColor = TuneThemeMutedText();
    _status.font = [UIFont systemFontOfSize:11.0f];
    _status.text = @"";
    _status.textAlignment = NSTextAlignmentRight;
    _status.lineBreakMode = UILineBreakModeTailTruncation;
    [self.view addSubview:_status];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = 76.0f;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.backgroundColor = [UIColor clearColor];
    _table.backgroundView = nil;
    _table.contentInset = UIEdgeInsetsMake(2.0f, 0.0f, 4.0f, 0.0f);
    UISwipeGestureRecognizer *playlistSwipe = [[[UISwipeGestureRecognizer alloc]
                                                 initWithTarget:self
                                                 action:@selector(playlistSwipe:)] autorelease];
    playlistSwipe.direction = UISwipeGestureRecognizerDirectionLeft;
    playlistSwipe.cancelsTouchesInView = NO;
    [_table addGestureRecognizer:playlistSwipe];
    [self.view addSubview:_table];

    _miniPlayer = [[UIControl alloc] initWithFrame:CGRectZero];
    _miniPlayer.backgroundColor = TuneThemeSurface();
    _miniPlayer.opaque = YES;
    _miniPlayer.layer.borderWidth = 1.0f;
    _miniPlayer.layer.borderColor = TuneThemeBorder().CGColor;
    _miniPlayer.layer.shadowColor = [UIColor blackColor].CGColor;
    _miniPlayer.layer.shadowOpacity = 0.65f;
    _miniPlayer.layer.shadowOffset = CGSizeMake(0.0f, -2.0f);
    _miniPlayer.layer.shadowRadius = 5.0f;
    _miniPlayer.layer.shouldRasterize = YES;
    _miniPlayer.layer.rasterizationScale = [UIScreen mainScreen].scale;
    [_miniPlayer addTarget:self action:@selector(playerPressed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_miniPlayer];

    _miniPlayerGradient = [[CAGradientLayer layer] retain];
    [_miniPlayer.layer insertSublayer:_miniPlayerGradient atIndex:0];

    _miniArtwork = [[UIImageView alloc] initWithFrame:CGRectZero];
    _miniArtwork.image = [UIImage imageNamed:@"Icon.png"];
    _miniArtwork.contentMode = UIViewContentModeScaleAspectFill;
    _miniArtwork.layer.cornerRadius = 7.0f;
    _miniArtwork.layer.masksToBounds = YES;
    [_miniPlayer addSubview:_miniArtwork];

    _nowTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _nowTitle.backgroundColor = [UIColor clearColor];
    _nowTitle.textColor = TuneThemePrimaryText();
    _nowTitle.font = [UIFont boldSystemFontOfSize:14.0f];
    _nowTitle.text = TuneL(@"nothing_playing");
    _nowTitle.lineBreakMode = UILineBreakModeTailTruncation;
    [_miniPlayer addSubview:_nowTitle];

    _nowArtist = [[UILabel alloc] initWithFrame:CGRectZero];
    _nowArtist.backgroundColor = [UIColor clearColor];
    _nowArtist.textColor = TuneThemeSecondaryText();
    _nowArtist.font = [UIFont systemFontOfSize:12.0f];
    _nowArtist.text = TuneL(@"pick_song");
    _nowArtist.lineBreakMode = UILineBreakModeTailTruncation;
    [_miniPlayer addSubview:_nowArtist];

    _favoriteButton = [[TuneRoundButton alloc] initWithKind:TuneRoundButtonKindStar];
    [_favoriteButton addTarget:self action:@selector(favoritePressed)
              forControlEvents:UIControlEventTouchUpInside];
    [_miniPlayer addSubview:_favoriteButton];

    _playButton = [[TunePlaybackButton alloc] initWithFrame:CGRectZero];
    [_playButton setLightStyle:YES];
    [_playButton addTarget:self action:@selector(playPressed) forControlEvents:UIControlEventTouchUpInside];
    [_miniPlayer addSubview:_playButton];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshPlayerUI:)
                                                 name:YTMPlayerDidChangeNotification
                                               object:_player];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyTheme:)
                                                 name:TuneTubeThemeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageChanged:)
                                                 name:TUNETUBE_LANGUAGE_DID_CHANGE_NOTIFICATION
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(focusSearch:)
                                                 name:TuneTubeFocusSearchNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [self loadQuickPicks];
    [self applyTheme:nil];
    [self reloadLocalizedChrome];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    _backgroundGradient.frame = b;

    CGFloat width = b.size.width;
    BOOL landscape = b.size.width > b.size.height;
    BOOL pad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
    CGFloat side = width > 700.0f ? 28.0f : 14.0f;
    CGFloat searchY = 6.0f;
    CGFloat searchHeight = landscape ? 34.0f : 38.0f;
    CGFloat recommendationY = searchY + searchHeight + 4.0f;
    CGFloat recommendationHeight = _recommendationScroll.hidden ? 0.0f : 34.0f;
    CGFloat sectionY = recommendationY + recommendationHeight + 8.0f;
    CGFloat bottom = landscape ? (pad ? 76.0f : 70.0f) : 78.0f;
    CGFloat tableY = sectionY + 23.0f;
    CGFloat optionsSize = landscape ? 30.0f : 34.0f;
    CGFloat librarySize = landscape ? 30.0f : 34.0f;
    CGFloat titleX = side + librarySize + 8.0f;
    CGFloat titleRight = side + optionsSize + 8.0f;
    _brandLabel.font = [UIFont boldSystemFontOfSize:landscape ? (pad ? 23.0f : 20.0f) : 25.0f];
    CGFloat titleWidth = MAX(80.0f, width - titleX - titleRight);
    _brandLabel.textAlignment = NSTextAlignmentCenter;
    _brandLabel.frame = CGRectMake(titleX, landscape ? 3.0f : 5.0f,
                                   titleWidth, landscape ? 27.0f : 31.0f);
    _taglineLabel.textAlignment = NSTextAlignmentCenter;
    _taglineLabel.frame = CGRectMake(titleX, landscape ? 29.0f : 36.0f,
                                     titleWidth, 13.0f);
    _libraryButton.frame = CGRectMake(side, landscape ? 7.0f : 12.0f,
                                      librarySize, librarySize);
    _optionsButton.frame = CGRectMake(width - side - optionsSize,
                                      landscape ? 7.0f : 12.0f,
                                      optionsSize, optionsSize);
    _search.frame = CGRectMake(side, searchY,
                               MAX(80.0f, width - side * 2.0f),
                               searchHeight);
    _recommendationScroll.frame = CGRectMake(side, recommendationY,
                                             MAX(80.0f, width - side * 2.0f),
                                             recommendationHeight);

    _sectionTitle.frame = CGRectMake(side + 2.0f, sectionY, width * 0.55f, 19.0f);
    _status.frame = CGRectMake(width * 0.40f, sectionY, width * 0.60f - side, 19.0f);

    CGFloat tableHeight = MAX(1.0f, b.size.height - tableY - bottom);
    _table.frame = CGRectMake(0.0f, tableY, width, tableHeight);

    _miniPlayer.frame = CGRectMake(0.0f, b.size.height - bottom, width, bottom);
    _miniPlayerGradient.frame = _miniPlayer.bounds;
    CGFloat miniArt = landscape ? 50.0f : 58.0f;
    _miniArtwork.frame = CGRectMake(side, landscape ? 9.0f : 10.0f, miniArt, miniArt);
    CGFloat buttonSize = landscape ? 48.0f : 52.0f;
    CGFloat playX = width - side - buttonSize;
    CGFloat controlSize = buttonSize;
    CGFloat controlY = floorf((bottom - controlSize) * 0.5f);
    _playButton.frame = CGRectMake(playX, controlY, buttonSize, buttonSize);
    _favoriteButton.frame = CGRectMake(playX - controlSize - 5.0f,
                                       controlY, controlSize, controlSize);
    CGFloat textX = side + miniArt + 12.0f;
    CGFloat textWidth = MAX(30.0f, CGRectGetMinX(_favoriteButton.frame) - textX - 8.0f);
    _nowTitle.frame = CGRectMake(textX, landscape ? 13.0f : 17.0f, textWidth, 22.0f);
    _nowArtist.frame = CGRectMake(textX, landscape ? 37.0f : 41.0f, textWidth, 18.0f);
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = TuneThemeBackgroundBottom();
    TuneTubeStyleNavigationBar(self.navigationController.navigationBar);
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)TuneThemeBackgroundTop().CGColor,
                                  (id)TuneThemeBackgroundBottom().CGColor, nil];

    [_libraryButton setImage:TuneMaskImage(TuneLibraryImage(24.0f), TuneThemePrimaryText())
                    forState:UIControlStateNormal];
    _libraryButton.backgroundColor = TuneThemeSurface();
    _libraryButton.layer.borderColor = TuneThemeBorder().CGColor;

    UIImage *settingsImage = [UIImage imageNamed:@"icon-settings.png"];
    if (settingsImage)
        [_optionsButton setImage:TuneMaskImage(settingsImage, TuneThemePrimaryText())
                        forState:UIControlStateNormal];
    _optionsButton.backgroundColor = TuneThemeSurface();
    _optionsButton.layer.borderColor = TuneThemeBorder().CGColor;

    _brandLabel.textColor = TuneThemePrimaryText();
    _taglineLabel.textColor = TuneThemeSecondaryText();
    _search.barStyle = UIBarStyleBlack;
    _search.tintColor = TuneThemeHeaderText();
    _search.backgroundColor = TuneThemeSearchBackground();
    SEL searchBarTintSelector = NSSelectorFromString(@"setBarTintColor:");
    if ([_search respondsToSelector:searchBarTintSelector])
        [_search performSelector:searchBarTintSelector withObject:TuneThemeNavigationBottom()];
    _search.layer.borderColor = TuneThemeBorder().CGColor;
    _sectionTitle.textColor = TuneThemePrimaryText();
    _status.textColor = TuneThemeMutedText();

    _miniPlayer.backgroundColor = TuneThemeSurface();
    _miniPlayer.layer.borderColor = TuneThemeBorder().CGColor;
    [_favoriteButton applyTheme];
    [_playButton applyTheme];
    _miniPlayerGradient.colors = [NSArray arrayWithObjects:
                                  (id)TuneThemeSurfaceTop().CGColor,
                                  (id)TuneThemeSurfaceBottom().CGColor, nil];
    _nowTitle.textColor = TuneThemePrimaryText();
    _nowArtist.textColor = TuneThemeSecondaryText();
    _miniPlayer.opaque = YES;
    _miniPlayer.layer.shouldRasterize = NO;
    [_table reloadData];
    [self rebuildRecommendations];
    [self.view setNeedsLayout];
}

- (void)focusSearch:(NSNotification *)note {
    (void)note;
    [self dismissViewControllerAnimated:YES completion:^{
        [_search becomeFirstResponder];
    }];
}

- (void)appDidBecomeActive:(NSNotification *)note {
    (void)note;
    [self applyTheme:nil];
    [_miniPlayer.layer setNeedsDisplay];
    [self.view setNeedsLayout];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return [_tracks count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"TuneTrackCell";
    TuneTrackCell *cell = (TuneTrackCell *)[tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell)
        cell = [[[TuneTrackCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:cellID] autorelease];
    [cell setArtistDelegate:self];
    [cell configureWithTrack:[_tracks objectAtIndex:(NSUInteger)indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    YTMTrack *track = [_tracks objectAtIndex:(NSUInteger)indexPath.row];
    _status.text = [NSString stringWithFormat:TuneL(@"loading_title"), track.title];
    TuneTubeRecordTrack(track);
    [_player setQueue:_tracks selectedIndex:indexPath.row usingAPI:(YTMAPI *)_api];
    [self.view endEditing:YES];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    NSString *query = [searchBar.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!query.length) return;

    _sectionTitle.text = TuneL(@"search_results");
    _status.text = TuneL(@"searching");
    [searchBar resignFirstResponder];
    [_recommendations removeAllObjects];
    [self rebuildRecommendations];
    [_tracks removeAllObjects];
    [_table reloadData];
    [(YTMAPI *)_api search:query completion:^(NSArray *tracks, NSError *error) {
        if (error) {
            if (TuneIsNetworkError(error)) {
                switch (error.code) {
                    case NSURLErrorNotConnectedToInternet:
                    case NSURLErrorNetworkConnectionLost:
                    case NSURLErrorCannotFindHost:
                    case NSURLErrorDNSLookupFailed:
                    case NSURLErrorCannotConnectToHost:
                    case NSURLErrorSecureConnectionFailed:
                        _status.text = TuneL(@"err_connect");
                        break;
                    case NSURLErrorTimedOut:
                        _status.text = TuneL(@"err_timeout");
                        break;
                    default:
                        _status.text = TuneL(@"err_search");
                        break;
                }
            } else {
                _status.text = [error localizedDescription];
            }
            return;
        }
        [_tracks addObjectsFromArray:tracks];
        [self buildRecommendationsForQuery:query tracks:tracks];
        _status.text = [NSString stringWithFormat:TuneL(@"songs_count"),
                        (unsigned long)_tracks.count];
        [_table reloadData];
    }];
}

- (void)buildRecommendationsForQuery:(NSString *)query tracks:(NSArray *)tracks {
    [_recommendations removeAllObjects];
    for (YTMTrack *track in tracks) {
        if (track.isPlaylist || !track.resultType.length ||
            [track.resultType caseInsensitiveCompare:@"Song"] != NSOrderedSame)
            continue;
        NSString *clean = [YTMDisplayArtist(track.artist)
                           stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!TuneRecommendationArtistIsValid(clean) ||
            [clean caseInsensitiveCompare:query] == NSOrderedSame)
            continue;
        BOOL duplicate = NO;
        for (NSString *existing in _recommendations)
            if ([existing caseInsensitiveCompare:clean] == NSOrderedSame) {
                duplicate = YES;
                break;
            }
        if (!duplicate) [_recommendations addObject:clean];
        if (_recommendations.count >= 8) break;
    }
    [self rebuildRecommendations];
}

- (void)rebuildRecommendations {
    NSArray *oldViews = [_recommendationScroll.subviews copy];
    for (UIView *view in oldViews) [view removeFromSuperview];
    [oldViews release];

    CGFloat x = 0.0f;
    for (NSString *query in _recommendations) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        [button setTitle:query forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont boldSystemFontOfSize:11.0f];
        button.titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
        button.contentEdgeInsets = UIEdgeInsetsMake(0.0f, 10.0f, 0.0f, 10.0f);
        [button sizeToFit];
        button.frame = CGRectMake(x, 2.0f, MAX(72.0f, button.bounds.size.width), 30.0f);
        button.layer.cornerRadius = 8.0f;
        button.layer.borderWidth = 1.0f;
        button.layer.borderColor = TuneThemeBorder().CGColor;
        button.backgroundColor = TuneThemeSurface();
        [button setTitleColor:TuneThemePrimaryText() forState:UIControlStateNormal];
        [button addTarget:self action:@selector(recommendationPressed:)
         forControlEvents:UIControlEventTouchUpInside];
        [_recommendationScroll addSubview:button];
        x = CGRectGetMaxX(button.frame) + 6.0f;
    }
    _recommendationScroll.contentSize = CGSizeMake(x, 34.0f);
    _recommendationScroll.hidden = _recommendations.count == 0;
    [self.view setNeedsLayout];
}

- (void)recommendationPressed:(UIButton *)button {
    NSString *query = button.titleLabel.text;
    if (!query.length) return;
    _search.text = query;
    [self searchBarSearchButtonClicked:_search];
}

- (void)playlistSwipe:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    CGPoint point = [gesture locationInView:_table];
    NSIndexPath *indexPath = [_table indexPathForRowAtPoint:point];
    if (!indexPath || (NSUInteger)indexPath.row >= _tracks.count) return;
    YTMTrack *track = [_tracks objectAtIndex:(NSUInteger)indexPath.row];
    if (track.isPlaylist) return;
    [self showPlaylistPickerForTrack:track];
}

- (void)showPlaylistPickerForTrack:(YTMTrack *)track {
    [_playlistTrack release];
    _playlistTrack = [track retain];
    NSArray *names = TuneTubePlaylistNames();
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:TuneL(@"add_to_playlist")
                                                     message:track.title
                                                    delegate:self
                                           cancelButtonTitle:TuneL(@"cancel")
                                           otherButtonTitles:TuneL(@"new_playlist"), nil] autorelease];
    for (NSString *name in names) [alert addButtonWithTitle:name];
    alert.tag = 7401;
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == 7401) {
        if (buttonIndex == alertView.cancelButtonIndex) return;
        if (buttonIndex == 1) {
            UIAlertView *newAlert = [[[UIAlertView alloc] initWithTitle:TuneL(@"new_playlist")
                                                                message:nil
                                                               delegate:self
                                                      cancelButtonTitle:TuneL(@"cancel")
                                                      otherButtonTitles:TuneL(@"create"), nil] autorelease];
            newAlert.alertViewStyle = UIAlertViewStylePlainTextInput;
            newAlert.tag = 7402;
            [newAlert textFieldAtIndex:0].placeholder = TuneL(@"name_placeholder");
            [newAlert show];
            return;
        }
        NSUInteger playlistIndex = (NSUInteger)(buttonIndex - 2);
        NSArray *names = TuneTubePlaylistNames();
        if (playlistIndex < names.count && _playlistTrack)
            TuneTubeAddTrackToPlaylist(_playlistTrack, [names objectAtIndex:playlistIndex]);
    } else if (alertView.tag == 7402 &&
               buttonIndex != alertView.cancelButtonIndex) {
        NSString *name = [[alertView textFieldAtIndex:0].text
                          stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length && _playlistTrack) {
            TuneTubeCreatePlaylist(name);
            TuneTubeAddTrackToPlaylist(_playlistTrack, name);
        }
    }
}

- (void)playPressed {
    if (![(YTMPlayer *)_player track]) return;
    [(YTMPlayer *)_player toggle];
}

- (void)tuneArtistCell:(id)cell didSelectTrack:(YTMTrack *)track {
    (void)cell;
    TunePushArtistProfile(self, track, (YTMAPI *)_api, (YTMPlayer *)_player);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyTheme:nil];
    NSString *key = [[NSUserDefaults standardUserDefaults]
                     objectForKey:TUNETUBE_API_KEY_DEFAULTS_KEY];
    [_api release];
    _api = [[YTMAPI alloc] initWithAPIKey:key.length ? key : YTMDefaultAPIKey];
    [self becomeFirstResponder];
    [self refreshPlayerUI:nil];
}

- (void)settingsPressed {
    TuneSettingsVC *settings = [[[TuneSettingsVC alloc] init] autorelease];
    UINavigationController *navigation =
        [[[UINavigationController alloc] initWithRootViewController:settings] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)libraryPressed {
    TuneLibraryVC *library = [[[TuneLibraryVC alloc] initWithPlayer:(YTMPlayer *)_player
                                                                 api:(YTMAPI *)_api] autorelease];
    UINavigationController *navigation =
        [[[UINavigationController alloc] initWithRootViewController:library] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)playerPressed {
    if (![(YTMPlayer *)_player track]) return;
    TunePlayerVC *player = [[[TunePlayerVC alloc] initWithPlayer:(YTMPlayer *)_player
                                                              api:(YTMAPI *)_api] autorelease];
    UINavigationController *navigation =
        [[[UINavigationController alloc] initWithRootViewController:player] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)refreshPlayerUI:(NSNotification *)note {
    YTMPlayer *player = (YTMPlayer *)[note object];
    if (!player) player = (YTMPlayer *)_player;
    NSError *error = [[note userInfo] objectForKey:@"error"];
    if (error) {
        _status.text = TunePlaybackErrorText(error);
        [_playButton setPlaying:NO];
        return;
    }
    if (player.track) {
        _nowTitle.text = player.track.title;
        NSString *artistName = YTMTrackArtistText(player.track);
        _nowArtist.text = [artistName caseInsensitiveCompare:@"Unknown artist"] == NSOrderedSame
            ? TuneL(@"unknown_artist") : artistName;
        [_playButton setPlaying:player.isPlaying];
        _status.text = player.isPlaying ? TuneL(@"playing_now") : TuneL(@"paused");
        [_favoriteButton setActive:TuneTubeTrackIsSaved(player.track)];

        NSString *requestedURL = [player.track.thumbnailURL copy];
        TuneLoadImage(requestedURL, ^(UIImage *image) {
            if (image && [(YTMPlayer *)_player track] == player.track &&
                [requestedURL isEqualToString:player.track.thumbnailURL]) {
                _miniArtwork.image = image;
            }
        });
        [requestedURL release];
    } else {
        _nowTitle.text = TuneL(@"nothing_playing");
        _nowArtist.text = TuneL(@"pick_song");
        _miniArtwork.image = [UIImage imageNamed:@"Icon.png"];
        [_favoriteButton setActive:NO];
        [_playButton setPlaying:NO];
    }
}

- (void)loadQuickPicks {
    if (_search.text.length || _tracks.count) return;
    [_tracks addObjectsFromArray:TuneTubeRecentTracks()];
    _sectionTitle.text = TuneL(@"quick_picks");
    _status.text = _tracks.count ? TuneL(@"recently_played") : @"";
    [_table reloadData];
}

- (void)favoritePressed {
    YTMTrack *track = [(YTMPlayer *)_player track];
    if (!track) return;
    if (TuneTubeTrackIsSaved(track)) {
        TuneTubeRemoveTrack(track);
        _status.text = TuneL(@"removed_library");
    } else {
        TuneTubeSaveTrack(track);
        _status.text = TuneL(@"added_library");
    }
    [_favoriteButton setActive:TuneTubeTrackIsSaved(track)];
}

- (void)viewWillDisappear:(BOOL)animated {
    [self resignFirstResponder];
    [super viewWillDisappear:animated];
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    if (event.type != UIEventTypeRemoteControl) return;
    switch (event.subtype) {
        case UIEventSubtypeRemoteControlPlay:
        case UIEventSubtypeRemoteControlPause:
        case UIEventSubtypeRemoteControlTogglePlayPause:
            [(YTMPlayer *)_player toggle];
            break;
        case UIEventSubtypeRemoteControlNextTrack:
            [(YTMPlayer *)_player nextTrack];
            break;
        case UIEventSubtypeRemoteControlPreviousTrack:
            [(YTMPlayer *)_player previousTrack];
            break;
        default:
            break;
    }
}

@end
