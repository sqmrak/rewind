#import "main_vc.h"

#import <QuartzCore/QuartzCore.h>
#include <math.h>

#import "tunetube_api.h"
#import "tunetube_player.h"
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
    switch (error.code) {
        case NSURLErrorSecureConnectionFailed:
        case NSURLErrorServerCertificateHasBadDate:
        case NSURLErrorServerCertificateUntrusted:
        case NSURLErrorServerCertificateHasUnknownRoot:
        case NSURLErrorServerCertificateNotYetValid:
            return TuneL(@"err_connect");
        default:
            break;
    }
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
        case NSURLErrorServerCertificateHasBadDate:
        case NSURLErrorServerCertificateUntrusted:
        case NSURLErrorServerCertificateHasUnknownRoot:
        case NSURLErrorServerCertificateNotYetValid:
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

static TuneTubeTrack *TuneTrackWithDuration(TuneTubeTrack *track, NSUInteger duration) {
    return [[[TuneTubeTrack alloc] initWithVideoID:track.videoID
                                             title:track.title
                                            artist:track.artist
                                             album:track.album
                                     thumbnailURL:track.thumbnailURL
                                          duration:duration
                                       playlistID:track.playlistID
                                         artistID:track.artistID
                                        resultType:track.resultType] autorelease];
}

@interface TuneTrackCell : UITableViewCell {
    UIView *_card;
    CAGradientLayer *_cardGradient;
    UIImageView *_artwork;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    UIButton *_menuButton;
    NSString *_imageURL;
    TuneTubeTrack *_track;
    id<TuneArtistTrackCellDelegate> _artistDelegate;
    UIButton *_artistButton;
}

@property(nonatomic, readonly) NSString *imageURL;
- (void)setArtistDelegate:(id<TuneArtistTrackCellDelegate>)delegate;
- (void)configureWithTrack:(TuneTubeTrack *)track;
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
    _menuButton.alpha = 0.72f;
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

    _menuButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    UIImage *menuImage = [UIImage imageNamed:@"menu-more.png"];
    if (menuImage)
        [_menuButton setImage:menuImage forState:UIControlStateNormal];
    _menuButton.adjustsImageWhenHighlighted = NO;
    _menuButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
    _menuButton.imageEdgeInsets = UIEdgeInsetsMake(7.0f, 7.0f, 7.0f, 7.0f);
    _menuButton.accessibilityLabel = TuneL(@"more");
    [_menuButton addTarget:self action:@selector(menuPressed:)
          forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_menuButton];

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
    [_menuButton release];
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
    _menuButton.hidden = YES;
}

- (void)setArtistDelegate:(id<TuneArtistTrackCellDelegate>)delegate {
    _artistDelegate = delegate;
}

- (void)configureWithTrack:(TuneTubeTrack *)track {
    [self applyTheme];
    [_track release];
    _track = [track retain];
    [_imageURL release];
    _imageURL = [track.thumbnailURL copy];
    _titleLabel.text = track.title;
    _artistLabel.text = TuneTubeTrackArtistText(track);
    if (!track.isPlaylist && track.album.length)
        _artistLabel.text = [NSString stringWithFormat:@"%@  ·  %@",
                             TuneTubeTrackArtistText(track), track.album];

    _menuButton.hidden = !track.videoID.length;
    NSString *artistName = TuneTubeTrackArtistText(track);
    BOOL hasArtist = artistName.length > 0 &&
        [artistName caseInsensitiveCompare:@"Various Artists"] != NSOrderedSame &&
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

- (void)menuPressed:(UIButton *)button {
    (void)button;
    if (_artistDelegate && [_artistDelegate respondsToSelector:@selector(tuneTrackCell:didPressMenuForTrack:)])
        [_artistDelegate tuneTrackCell:self didPressMenuForTrack:_track];
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
    _titleLabel.frame = CGRectMake(textX, textY, MAX(20.0f, right - textX - 40.0f), 22.0f);
    _artistLabel.frame = CGRectMake(textX, textY + 24.0f, MAX(20.0f, right - textX - 8.0f), 19.0f);
    _menuButton.frame = CGRectMake(right - 34.0f, textY - 3.0f, 34.0f, 34.0f);
    _artistButton.frame = _artistLabel.frame;
}

@end

@interface MainVC () <TuneArtistTrackCellDelegate, TunePlayerMenuDelegate,
                       UIActionSheetDelegate, UIGestureRecognizerDelegate>
- (void)refreshPlayerUI:(NSNotification *)note;
- (void)loadQuickPicks;
- (void)settingsPressed;
- (void)focusSearch:(NSNotification *)note;
- (void)searchBackgroundTapped:(UITapGestureRecognizer *)gesture;
- (void)restoreHomeAfterSearch;
- (void)applyTheme:(NSNotification *)note;
- (void)appDidBecomeActive:(NSNotification *)note;
- (void)favoritePressed;
- (void)buildRecommendationsForQuery:(NSString *)query tracks:(NSArray *)tracks;
- (void)loadPersonalizedRecommendations;
- (void)loadRecommendationQueries:(NSArray *)queries index:(NSUInteger)index;
- (void)appendPersonalizedTracks:(NSArray *)tracks;
- (void)hydrateDurationsForTracks:(NSArray *)tracks;
- (void)rebuildRecommendations;
- (void)recommendationPressed:(UIButton *)button;
- (void)recommendationMenuPressed:(UIButton *)button;
- (void)quickMenuPressed:(UIButton *)button;
- (NSUInteger)homeQuickPickCount;
- (TuneTubeTrack *)homeRecommendationTrackAtIndex:(NSUInteger)index;
- (CGFloat)homeQuickPickHeight;
- (NSUInteger)homeRecommendationCount;
- (CGFloat)homeRecommendationHeight;
- (void)rebuildRecommendationPages;
- (void)homeMorePressed;
- (void)updateRecommendationDots;
- (void)playlistSwipe:(UISwipeGestureRecognizer *)gesture;
- (void)showPlaylistPickerForTrack:(TuneTubeTrack *)track;
- (void)showTrackMenu:(TuneTubeTrack *)track;
- (void)performTrackMenuAction:(NSInteger)action;
- (void)showMessage:(NSString *)title message:(NSString *)message;
- (void)showPlaylistPickerForMenuTrack;
- (void)showRemovePlaylistPickerForMenuTrack;
- (void)showPlaybackSpeedPicker;
- (void)showSleepTimerPicker;
- (void)downloadMenuTrack;
- (void)libraryPressed;
- (void)playerPressed;
- (void)tuneArtistCell:(id)cell didSelectTrack:(TuneTubeTrack *)track;
- (void)tuneTrackCell:(id)cell didPressMenuForTrack:(TuneTubeTrack *)track;
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
    [_searchDismissGesture release];
    [_homeScroll release];
    [_sectionTitle release];
    [_table release];
    [_status release];
    [_recommendationScroll release];
    [_recommendationPages release];
    [_homeRecommendationTracks release];
    [_recommendationDots release];
    [_recommendationDotViews release];
    [_recommendations release];
    [_recommendationMore release];
    [_playlistTrack release];
    [_actionTrack release];
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
    BOOL searching = _search.text.length > 0;
    _brandLabel.text = TuneL(@"quick_picks");
    _sectionTitle.text = searching ? TuneL(@"search_results") : TuneL(@"recommendations");
    [_recommendationMore setTitle:TuneL(@"see_all") forState:UIControlStateNormal];
    if (![(TuneTubePlayer *)_player track]) {
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

    _homeScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _homeScroll.backgroundColor = [UIColor clearColor];
    _homeScroll.showsVerticalScrollIndicator = YES;
    _homeScroll.showsHorizontalScrollIndicator = NO;
    _homeScroll.alwaysBounceVertical = YES;
    _homeScroll.scrollsToTop = YES;
    [self.view addSubview:_homeScroll];

    NSString *key = [[NSUserDefaults standardUserDefaults]
                     objectForKey:TUNETUBE_API_KEY_DEFAULTS_KEY];
    _api = [[TuneTubeAPI alloc] initWithAPIKey:key.length ? key : TuneTubeDefaultAPIKey];
    _player = [[TuneTubePlayer alloc] init];

    _brandLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _brandLabel.backgroundColor = [UIColor clearColor];
    _brandLabel.textColor = TuneThemePrimaryText();
    _brandLabel.font = [UIFont boldSystemFontOfSize:25.0f];
    _brandLabel.text = @"TuneTube";
    _brandLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.65f];
    _brandLabel.shadowOffset = CGSizeMake(0.0f, 2.0f);
    _brandLabel.hidden = NO;
    _brandLabel.textAlignment = NSTextAlignmentLeft;
    [_homeScroll addSubview:_brandLabel];

    _taglineLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _taglineLabel.backgroundColor = [UIColor clearColor];
    _taglineLabel.textColor = TuneThemeSecondaryText();
    _taglineLabel.font = [UIFont systemFontOfSize:10.0f];
    _taglineLabel.text = TuneL(@"tagline");
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

    _searchDismissGesture = [[UITapGestureRecognizer alloc]
                             initWithTarget:self
                                     action:@selector(searchBackgroundTapped:)];
    _searchDismissGesture.delegate = self;
    _searchDismissGesture.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:_searchDismissGesture];

    _recommendations = [[NSMutableArray alloc] init];
    _homeRecommendationTracks = [[NSMutableArray alloc] init];
    _recommendationScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _recommendationScroll.backgroundColor = [UIColor clearColor];
    _recommendationScroll.showsHorizontalScrollIndicator = NO;
    _recommendationScroll.showsVerticalScrollIndicator = NO;
    _recommendationScroll.hidden = YES;
    [_homeScroll addSubview:_recommendationScroll];

    _recommendationPages = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _recommendationPages.backgroundColor = [UIColor clearColor];
    _recommendationPages.pagingEnabled = YES;
    _recommendationPages.showsHorizontalScrollIndicator = NO;
    _recommendationPages.showsVerticalScrollIndicator = NO;
    _recommendationPages.alwaysBounceHorizontal = YES;
    _recommendationPages.delegate = self;
    _recommendationPages.hidden = YES;
    [_homeScroll addSubview:_recommendationPages];

    _recommendationDots = [[UIView alloc] initWithFrame:CGRectZero];
    _recommendationDots.backgroundColor = [UIColor clearColor];
    _recommendationDots.hidden = YES;
    _recommendationDots.userInteractionEnabled = NO;
    _recommendationDotViews = [[NSMutableArray alloc] init];
    for (NSUInteger index = 0; index < 4; ++index) {
        UIView *dot = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
        dot.layer.cornerRadius = 3.0f;
        [_recommendationDotViews addObject:dot];
        [_recommendationDots addSubview:dot];
    }
    [_homeScroll addSubview:_recommendationDots];

    _sectionTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _sectionTitle.backgroundColor = [UIColor clearColor];
    _sectionTitle.textColor = TuneThemePrimaryText();
    _sectionTitle.font = [UIFont boldSystemFontOfSize:12.0f];
    _sectionTitle.text = TuneL(@"recommendations");
    [_homeScroll addSubview:_sectionTitle];

    _recommendationMore = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    [_recommendationMore setTitle:TuneL(@"see_all") forState:UIControlStateNormal];
    _recommendationMore.titleLabel.font = [UIFont boldSystemFontOfSize:11.0f];
    [_recommendationMore setTitleColor:TuneThemePrimaryText() forState:UIControlStateNormal];
    _recommendationMore.layer.cornerRadius = 16.0f;
    _recommendationMore.layer.borderWidth = 1.0f;
    _recommendationMore.layer.borderColor = TuneThemeBorder().CGColor;
    [_recommendationMore addTarget:self action:@selector(homeMorePressed)
                  forControlEvents:UIControlEventTouchUpInside];
    [_homeScroll addSubview:_recommendationMore];

    _status = [[UILabel alloc] initWithFrame:CGRectZero];
    _status.backgroundColor = [UIColor clearColor];
    _status.textColor = TuneThemeMutedText();
    _status.font = [UIFont systemFontOfSize:11.0f];
    _status.text = @"";
    _status.textAlignment = NSTextAlignmentRight;
    _status.lineBreakMode = UILineBreakModeTailTruncation;
    [_homeScroll addSubview:_status];

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
    [_homeScroll addSubview:_table];

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
                                                 name:TuneTubePlayerDidChangeNotification
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
    BOOL home = _search.text.length == 0;
    BOOL layoutChanged = !_hasLastLayoutSize ||
        !CGSizeEqualToSize(_lastLayoutSize, b.size) ||
        _lastLayoutHome != home;
    _lastLayoutSize = b.size;
    _lastLayoutHome = home;
    _hasLastLayoutSize = YES;
    if (layoutChanged && _recommendationScroll)
        [self rebuildRecommendations];
    BOOL showQuickPicks = home && _tracks.count > 0;
    CGFloat side = width > 700.0f ? 28.0f : 14.0f;
    CGFloat searchY = 6.0f;
    CGFloat searchHeight = landscape ? 34.0f : 38.0f;
    CGFloat quickTitleY = searchY + searchHeight + 8.0f;
    CGFloat quickTitleHeight = home ? 30.0f : 0.0f;
    CGFloat recommendationY = quickTitleY + quickTitleHeight + 4.0f;
    CGFloat recommendationHeight = 0.0f;
    CGFloat sectionY = 0.0f;
    CGFloat sectionHeight = home ? 30.0f : 19.0f;
    CGFloat pagesY = 0.0f;
    CGFloat pagesHeight = 0.0f;
    CGFloat dotsY = 0.0f;
    CGFloat dotsHeight = 0.0f;
    CGFloat tableY = 0.0f;
    if (home) {
        recommendationHeight = showQuickPicks ? [self homeQuickPickHeight] : 0.0f;
        sectionY = recommendationY + recommendationHeight + 10.0f;
        pagesY = sectionY + sectionHeight + 4.0f;
        pagesHeight = [self homeRecommendationHeight];
        if (pagesHeight > 0.0f) {
            dotsY = pagesY + pagesHeight + 5.0f;
            dotsHeight = 8.0f;
            tableY = dotsY + dotsHeight + 8.0f;
        } else {
            tableY = pagesY + 10.0f;
        }
    } else {
        recommendationHeight = _recommendationScroll.hidden ? 0.0f : 34.0f;
        sectionY = recommendationY + recommendationHeight + 8.0f;
        tableY = sectionY + 23.0f;
    }
    BOOL hasTrack = [(TuneTubePlayer *)_player track] != nil;
    CGFloat bottom = hasTrack ? (landscape ? (pad ? 76.0f : 70.0f) : 78.0f) : 0.0f;
    CGFloat contentSectionY = sectionY;
    CGFloat contentPagesY = pagesY;
    CGFloat contentTableY = tableY;
    CGFloat contentViewportHeight = MAX(1.0f, b.size.height - bottom);
    _homeScroll.frame = b;
    CGFloat optionsSize = landscape ? 30.0f : 34.0f;
    CGFloat librarySize = landscape ? 30.0f : 34.0f;
    _brandLabel.hidden = !home;
    _brandLabel.font = [UIFont boldSystemFontOfSize:landscape ? (pad ? 23.0f : 20.0f) : 25.0f];
    _brandLabel.textAlignment = NSTextAlignmentLeft;
    _brandLabel.frame = CGRectMake(side, quickTitleY,
                                   MAX(80.0f, width - side * 2.0f),
                                   quickTitleHeight);
    _taglineLabel.frame = CGRectZero;
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
    _recommendationPages.frame = CGRectMake(side, contentPagesY,
                                            MAX(80.0f, width - side * 2.0f),
                                            pagesHeight);
    _recommendationPages.hidden = !home || pagesHeight <= 0.0f;
    _recommendationDots.frame = CGRectMake(floorf((width - 44.0f) * 0.5f),
                                           dotsY, 44.0f, dotsHeight);
    _recommendationDots.hidden = !home || pagesHeight <= 0.0f;

    CGFloat moreWidth = home ? 92.0f : 0.0f;
    CGFloat titleWidth = home ? MAX(80.0f, width - side * 2.0f - moreWidth - 12.0f)
                              : MAX(80.0f, width * 0.55f);
    _sectionTitle.font = [UIFont boldSystemFontOfSize:home ? (pad ? 25.0f : 22.0f) : 12.0f];
    _sectionTitle.frame = CGRectMake(side + 2.0f, contentSectionY, titleWidth, sectionHeight);
    _status.hidden = home;
    _status.frame = CGRectMake(width * 0.40f, contentSectionY,
                               width * 0.60f - side, 19.0f);
    _recommendationMore.hidden = !home || _homeShowAll ||
        [self homeRecommendationCount] == 0;
    _recommendationMore.frame = CGRectMake(width - side - moreWidth,
                                           contentSectionY + 3.0f,
                                           moreWidth, 26.0f);

    CGFloat tableHeight = home
        ? 1.0f
        : MAX(1.0f, b.size.height - tableY - bottom);
    _homeScroll.scrollEnabled = home;
    _table.scrollEnabled = !home;
    _recommendationScroll.panGestureRecognizer.enabled = !home;
    _recommendationScroll.scrollEnabled = !home;
    if (!home) [_homeScroll setContentOffset:CGPointZero animated:NO];
    _table.frame = CGRectMake(0.0f, contentTableY, width, tableHeight);
    CGFloat homeContentHeight = MAX(contentViewportHeight,
                                   CGRectGetMaxY(_table.frame) + 8.0f);
    _homeScroll.contentSize = home
        ? CGSizeMake(width, homeContentHeight)
        : b.size;

    _miniPlayer.hidden = !hasTrack;
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
    [_recommendationMore setTitleColor:TuneThemePrimaryText() forState:UIControlStateNormal];
    _recommendationMore.layer.borderColor = TuneThemeBorder().CGColor;

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

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != _searchDismissGesture || !_searchEditing)
        return NO;
    UIView *view = touch.view;
    while (view) {
        if (view == _search || [view isKindOfClass:[UIControl class]] ||
            [view isKindOfClass:[UITableViewCell class]])
            return NO;
        view = view.superview;
    }
    return YES;
}

- (void)searchBackgroundTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded || !_searchEditing) return;
    [self restoreHomeAfterSearch];
}

- (void)restoreHomeAfterSearch {
    _searchEditing = NO;
    [_search resignFirstResponder];
    _search.text = @"";
    _homeShowAll = NO;
    [_recommendations removeAllObjects];
    [_tracks removeAllObjects];
    _sectionTitle.text = TuneL(@"recommendations");
    _status.text = @"";
    [_table reloadData];
    [self rebuildRecommendations];
    [self loadQuickPicks];
    [_homeScroll setContentOffset:CGPointZero animated:NO];
    [_recommendationPages setContentOffset:CGPointZero animated:NO];
    [self.view setNeedsLayout];
}

- (void)appDidBecomeActive:(NSNotification *)note {
    (void)note;
    [self applyTheme:nil];
    [_miniPlayer.layer setNeedsDisplay];
    [self.view setNeedsLayout];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    if (!_search.text.length) return 0;
    NSUInteger offset = [self homeQuickPickCount];
    return _tracks.count > offset ? (NSInteger)(_tracks.count - offset) : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"TuneTrackCell";
    TuneTrackCell *cell = (TuneTrackCell *)[tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell)
        cell = [[[TuneTrackCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:cellID] autorelease];
    [cell setArtistDelegate:self];
    NSUInteger trackIndex = _search.text.length
        ? [self homeQuickPickCount] + (NSUInteger)indexPath.row
        : (NSUInteger)indexPath.row;
    if (trackIndex >= _tracks.count) return cell;
    [cell configureWithTrack:[_tracks objectAtIndex:trackIndex]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSUInteger trackIndex = _search.text.length
        ? [self homeQuickPickCount] + (NSUInteger)indexPath.row
        : (NSUInteger)indexPath.row;
    if (trackIndex >= _tracks.count) return;
    TuneTubeTrack *track = [_tracks objectAtIndex:trackIndex];
    if (!track.videoID.length || track.isPlaylist) {
        _status.text = TuneL(@"choose_track");
        return;
    }
    _status.text = [NSString stringWithFormat:TuneL(@"loading_title"), track.title];
    TuneTubeRecordTrack(track);
    [_player setQueue:_tracks selectedIndex:trackIndex usingAPI:(TuneTubeAPI *)_api];
    [self.view endEditing:YES];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    NSString *query = [searchBar.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!query.length) return;

    _homeShowAll = NO;
    _sectionTitle.text = TuneL(@"search_results");
    _status.text = TuneL(@"searching");
    [searchBar resignFirstResponder];
    [_recommendations removeAllObjects];
    [self rebuildRecommendations];
    [_tracks removeAllObjects];
    [_table reloadData];
    [(TuneTubeAPI *)_api search:query completion:^(NSArray *tracks, NSError *error) {
        if (error) {
            if (TuneIsNetworkError(error)) {
                switch (error.code) {
                    case NSURLErrorNotConnectedToInternet:
                    case NSURLErrorNetworkConnectionLost:
                    case NSURLErrorCannotFindHost:
                    case NSURLErrorDNSLookupFailed:
                    case NSURLErrorCannotConnectToHost:
                    case NSURLErrorSecureConnectionFailed:
                    case NSURLErrorServerCertificateHasBadDate:
                    case NSURLErrorServerCertificateUntrusted:
                    case NSURLErrorServerCertificateHasUnknownRoot:
                    case NSURLErrorServerCertificateNotYetValid:
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

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    (void)searchBar;
    _searchEditing = YES;
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
    (void)searchBar;
    _searchEditing = NO;
}

- (void)hydrateDurationsForTracks:(NSArray *)tracks {
    if (![tracks isKindOfClass:[NSArray class]] || !tracks.count) return;
    TuneTubeAPI *api = (TuneTubeAPI *)_api;
    for (TuneTubeTrack *track in tracks) {
        if (track.duration || !track.videoID.length || track.isPlaylist) continue;
        [api durationForTrack:track completion:^(NSUInteger duration, NSError *error) {
            (void)error;
            if (!duration) return;
            for (NSUInteger index = 0; index < _tracks.count; ++index) {
                TuneTubeTrack *current = [_tracks objectAtIndex:index];
                if (![current.videoID isEqualToString:track.videoID] || current.duration) continue;
                [_tracks replaceObjectAtIndex:index withObject:TuneTrackWithDuration(current, duration)];
                [_table reloadData];
                [self.view setNeedsLayout];
                break;
            }
        }];
    }
}

- (void)buildRecommendationsForQuery:(NSString *)query tracks:(NSArray *)tracks {
    [_recommendations removeAllObjects];
    for (TuneTubeTrack *track in tracks) {
        if (track.isPlaylist || !track.resultType.length ||
            [track.resultType caseInsensitiveCompare:@"Song"] != NSOrderedSame)
            continue;
        NSString *clean = [TuneTubeDisplayArtist(track.artist)
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

- (NSUInteger)homeQuickPickCount {
    if (_search.text.length) return 0;
    if (_homeShowAll) return _tracks.count;
    BOOL landscape = self.view.bounds.size.width > self.view.bounds.size.height;
    BOOL pad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
    NSUInteger limit = pad ? 8 : (landscape ? 4 : 9);
    return MIN(_tracks.count, limit);
}

- (TuneTubeTrack *)homeRecommendationTrackAtIndex:(NSUInteger)index {
    if (index >= _homeRecommendationTracks.count || index >= 16)
        return nil;
    return [_homeRecommendationTracks objectAtIndex:index];
}

- (CGFloat)homeQuickPickHeight {
    NSUInteger count = [self homeQuickPickCount];
    if (!count) return 0.0f;

    CGRect bounds = self.view.bounds;
    CGFloat side = bounds.size.width > 700.0f ? 28.0f : 14.0f;
    CGFloat gap = 8.0f;
    BOOL landscape = bounds.size.width > bounds.size.height;
    BOOL pad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
    NSUInteger columns = landscape || pad ? 4 : 3;
    NSUInteger visibleCount = MIN(count, landscape ? (NSUInteger)4 :
                                  (pad ? (NSUInteger)8 : (NSUInteger)9));
    if (pad) visibleCount = MIN(count, (NSUInteger)8);
    NSUInteger rows = (visibleCount + columns - 1) / columns;
    CGFloat available = MAX(80.0f, bounds.size.width - side * 2.0f);
    CGFloat cardWidth = floorf((available - gap * (columns - 1)) / columns);
    if (bounds.size.width > 700.0f) cardWidth = MIN(cardWidth, 190.0f);
    return rows * cardWidth + MAX(0.0f, (CGFloat)(rows - 1) * gap);
}

- (NSUInteger)homeRecommendationCount {
    if (_search.text.length) return 0;
    return MIN(_homeRecommendationTracks.count, (NSUInteger)16);
}

- (void)updateRecommendationDots {
    NSUInteger pageCount = [self homeRecommendationCount]
        ? ([self homeRecommendationCount] + 3) / 4 : 0;
    if (pageCount > 4) pageCount = 4;
    CGFloat pageWidth = _recommendationPages.bounds.size.width;
    NSInteger page = pageWidth > 0.0f
        ? (NSInteger)floorf((_recommendationPages.contentOffset.x / pageWidth) + 0.5f)
        : 0;
    if (page < 0) page = 0;
    if (pageCount && page >= (NSInteger)pageCount) page = (NSInteger)pageCount - 1;
    for (NSUInteger index = 0; index < _recommendationDotViews.count; ++index) {
        UIView *dot = [_recommendationDotViews objectAtIndex:index];
        dot.hidden = index >= pageCount;
        dot.backgroundColor = index == (NSUInteger)page
            ? [UIColor colorWithWhite:1.0f alpha:1.0f]
            : [UIColor colorWithWhite:1.0f alpha:0.34f];
    }
    _recommendationDots.hidden = pageCount == 0 || _search.text.length != 0;
    CGFloat dotSize = 6.0f;
    CGFloat gap = 6.0f;
    CGFloat totalWidth = _recommendationDotViews.count * dotSize +
        (_recommendationDotViews.count - 1) * gap;
    for (NSUInteger index = 0; index < _recommendationDotViews.count; ++index) {
        UIView *dot = [_recommendationDotViews objectAtIndex:index];
        dot.frame = CGRectMake(index * (dotSize + gap), 1.0f, dotSize, dotSize);
    }
    _recommendationDots.bounds = CGRectMake(0.0f, 0.0f, totalWidth, 8.0f);
}

- (CGFloat)homeRecommendationHeight {
    NSUInteger count = [self homeRecommendationCount];
    if (!count) return 0.0f;
    CGRect bounds = self.view.bounds;
    CGFloat side = bounds.size.width > 700.0f ? 28.0f : 14.0f;
    CGFloat gap = 8.0f;
    BOOL landscape = self.view.bounds.size.width > self.view.bounds.size.height;
    NSUInteger columns = landscape ? 4 : 2;
    NSUInteger rows = landscape ? 1 : 2;
    CGFloat available = MAX(80.0f, bounds.size.width - side * 2.0f);
    CGFloat cardWidth = floorf((available - gap * (columns - 1)) / columns);
    if (bounds.size.width > 700.0f) cardWidth = MIN(cardWidth, 190.0f);
    else cardWidth = MIN(cardWidth, 116.0f);
    return cardWidth * rows + gap * MAX(0, rows - 1);
}

- (void)rebuildRecommendationPages {
    NSArray *oldViews = [_recommendationPages.subviews copy];
    for (UIView *view in oldViews) [view removeFromSuperview];
    [oldViews release];

    NSUInteger count = [self homeRecommendationCount];
    if (!count) {
        _recommendationPages.contentSize = CGSizeZero;
        _recommendationPages.hidden = YES;
        [self updateRecommendationDots];
        return;
    }

    CGRect bounds = self.view.bounds;
    CGFloat side = bounds.size.width > 700.0f ? 28.0f : 14.0f;
    CGFloat gap = 8.0f;
    BOOL landscape = bounds.size.width > bounds.size.height;
    NSUInteger columns = landscape ? 4 : 2;
    NSUInteger rows = landscape ? 1 : 2;
    CGFloat available = MAX(80.0f, bounds.size.width - side * 2.0f);
    CGFloat cardWidth = floorf((available - gap * (columns - 1)) / columns);
    if (bounds.size.width > 700.0f)
        cardWidth = MIN(cardWidth, 190.0f);
    else
        cardWidth = MIN(cardWidth, landscape ? 94.0f : 116.0f);
    CGFloat cardHeight = cardWidth;
    NSUInteger pageCount = (count + 3) / 4;

    NSUInteger trackIndex = 0;
    for (NSUInteger page = 0; page < pageCount; ++page) {
        for (NSUInteger row = 0; row < rows && trackIndex < count; ++row) {
            for (NSUInteger column = 0; column < columns && trackIndex < count; ++column) {
                NSUInteger cardIndex = trackIndex;
                TuneTubeTrack *track =
                    [self homeRecommendationTrackAtIndex:trackIndex];
                if (!track) break;

                UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
                card.tag = 7000 + (NSInteger)cardIndex;
                card.frame = CGRectMake(page * available +
                                        (available - cardWidth * columns -
                                         gap * (columns - 1)) * 0.5f +
                                        column * (cardWidth + gap),
                                        row * (cardHeight + gap),
                                        cardWidth, cardHeight);
                card.backgroundColor = TuneThemeSurface();
                card.layer.cornerRadius = 12.0f;
                card.layer.masksToBounds = YES;
                [card addTarget:self action:@selector(recommendationPressed:)
               forControlEvents:UIControlEventTouchUpInside];

                UIImageView *artwork = [[[UIImageView alloc]
                                         initWithFrame:card.bounds] autorelease];
                artwork.tag = 7101;
                artwork.image = [UIImage imageNamed:@"Icon.png"];
                artwork.contentMode = UIViewContentModeScaleAspectFill;
                artwork.clipsToBounds = YES;
                [card addSubview:artwork];

                UIView *shade = [[[UIView alloc] initWithFrame:
                                  CGRectMake(0.0f, cardHeight - 48.0f,
                                             cardWidth, 48.0f)] autorelease];
                shade.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.62f];
                shade.userInteractionEnabled = NO;
                [card addSubview:shade];

                UILabel *title = [[[UILabel alloc] initWithFrame:
                                   CGRectMake(9.0f, cardHeight - 43.0f,
                                              cardWidth - 18.0f, 21.0f)] autorelease];
                title.tag = 7102;
                title.backgroundColor = [UIColor clearColor];
                title.textColor = [UIColor whiteColor];
                title.font = [UIFont boldSystemFontOfSize:
                              bounds.size.width > 700.0f ? 15.0f : 12.0f];
                title.lineBreakMode = UILineBreakModeTailTruncation;
                title.text = track.title;
                title.userInteractionEnabled = NO;
                [card addSubview:title];

                UILabel *artist = [[[UILabel alloc] initWithFrame:
                                    CGRectMake(9.0f, cardHeight - 23.0f,
                                               cardWidth - 18.0f, 18.0f)] autorelease];
                artist.tag = 7103;
                artist.backgroundColor = [UIColor clearColor];
                artist.textColor = [UIColor colorWithWhite:1.0f alpha:0.78f];
                artist.font = [UIFont systemFontOfSize:
                               bounds.size.width > 700.0f ? 12.0f : 10.0f];
                artist.lineBreakMode = UILineBreakModeTailTruncation;
                artist.text = TuneTubeTrackArtistText(track);
                artist.userInteractionEnabled = NO;
                [card addSubview:artist];

                UIButton *menu = [UIButton buttonWithType:UIButtonTypeCustom];
                menu.tag = 8000 + (NSInteger)cardIndex;
                menu.frame = CGRectMake(cardWidth - 36.0f, 7.0f, 30.0f, 34.0f);
                UIImage *menuImage = [UIImage imageNamed:@"menu-more.png"];
                if (menuImage) [menu setImage:menuImage forState:UIControlStateNormal];
                menu.adjustsImageWhenHighlighted = NO;
                menu.imageView.contentMode = UIViewContentModeScaleAspectFit;
                menu.imageEdgeInsets = UIEdgeInsetsMake(7.0f, 7.0f, 7.0f, 7.0f);
                menu.accessibilityLabel = TuneL(@"more");
                [menu addTarget:self action:@selector(recommendationMenuPressed:)
                forControlEvents:UIControlEventTouchUpInside];
                [card addSubview:menu];

                [_recommendationPages addSubview:card];
                NSString *videoID = [track.videoID copy];
                NSString *requestedURL = [track.thumbnailURL copy];
                if (requestedURL.length) {
                    TuneLoadImage(requestedURL, ^(UIImage *image) {
                        if (!image) return;
                        UIButton *visibleCard =
                            (UIButton *)[_recommendationPages viewWithTag:
                                         7000 + (NSInteger)cardIndex];
                        if (!visibleCard) return;
                        TuneTubeTrack *visibleTrack =
                            [self homeRecommendationTrackAtIndex:cardIndex];
                        if (visibleCard && [visibleTrack.videoID isEqualToString:videoID])
                            [(UIImageView *)[visibleCard viewWithTag:7101] setImage:image];
                    });
                }
                [videoID release];
                [requestedURL release];
                trackIndex++;
            }
        }
    }
    _recommendationPages.contentSize =
        CGSizeMake(available * pageCount,
                   cardHeight * rows + gap * MAX(0, rows - 1));
    [_recommendationPages setContentOffset:CGPointZero animated:NO];
    _recommendationPages.hidden = NO;
    [self updateRecommendationDots];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == _recommendationPages)
        [self updateRecommendationDots];
}

- (void)rebuildRecommendations {
    NSArray *oldViews = [_recommendationScroll.subviews copy];
    for (UIView *view in oldViews) [view removeFromSuperview];
    [oldViews release];

    if (!_search.text.length) {
        NSUInteger count = [self homeQuickPickCount];
        CGFloat side = self.view.bounds.size.width > 700.0f ? 28.0f : 14.0f;
        CGFloat gap = 8.0f;
        BOOL landscape = self.view.bounds.size.width > self.view.bounds.size.height;
        BOOL pad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
        NSUInteger columns = landscape || pad ? 4 : 3;
        NSUInteger visibleColumns = landscape ? 4 : (pad ? 4 : 3);
        CGFloat available = MAX(80.0f, self.view.bounds.size.width - side * 2.0f);
        CGFloat cardWidth = floorf((available - gap * (visibleColumns - 1)) /
                                    visibleColumns);
        if (self.view.bounds.size.width > 700.0f) cardWidth = MIN(cardWidth, 190.0f);
        CGFloat cardHeight = cardWidth;

        for (NSUInteger index = 0; index < count; ++index) {
            TuneTubeTrack *track = [_tracks objectAtIndex:index];
            NSUInteger cardIndex = index;
            UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
            card.tag = 6000 + (NSInteger)index;
            card.backgroundColor = TuneThemeSurface();
            card.layer.cornerRadius = 12.0f;
            card.layer.masksToBounds = YES;
            [card addTarget:self action:@selector(recommendationPressed:)
           forControlEvents:UIControlEventTouchUpInside];

            UIImageView *artwork = [[[UIImageView alloc]
                                     initWithFrame:CGRectMake(0.0f, 0.0f,
                                                              cardWidth, cardHeight)] autorelease];
            artwork.tag = 6101;
            artwork.image = [UIImage imageNamed:@"Icon.png"];
            artwork.contentMode = UIViewContentModeScaleAspectFill;
            artwork.clipsToBounds = YES;
            [card addSubview:artwork];

            UIView *shade = [[[UIView alloc] initWithFrame:CGRectMake(0.0f,
                                                                       cardHeight - 38.0f,
                                                                       cardWidth, 38.0f)] autorelease];
            shade.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.58f];
            [card addSubview:shade];

            UILabel *title = [[[UILabel alloc] initWithFrame:CGRectMake(9.0f,
                                                                          cardHeight - 32.0f,
                                                                          cardWidth - 18.0f,
                                                                          24.0f)] autorelease];
            title.tag = 6102;
            title.backgroundColor = [UIColor clearColor];
            title.textColor = [UIColor whiteColor];
            title.font = [UIFont boldSystemFontOfSize:self.view.bounds.size.width > 700.0f ? 16.0f : 12.0f];
            title.lineBreakMode = UILineBreakModeTailTruncation;
            title.text = track.title;
            [card addSubview:title];

            UIButton *menu = [UIButton buttonWithType:UIButtonTypeCustom];
            menu.tag = 9000 + (NSInteger)index;
            menu.frame = CGRectMake(cardWidth - 36.0f, 7.0f, 30.0f, 34.0f);
            UIImage *menuImage = [UIImage imageNamed:@"menu-more.png"];
            if (menuImage) [menu setImage:menuImage forState:UIControlStateNormal];
            menu.adjustsImageWhenHighlighted = NO;
            menu.imageView.contentMode = UIViewContentModeScaleAspectFit;
            menu.imageEdgeInsets = UIEdgeInsetsMake(7.0f, 7.0f, 7.0f, 7.0f);
            menu.accessibilityLabel = TuneL(@"more");
            [menu addTarget:self action:@selector(quickMenuPressed:)
             forControlEvents:UIControlEventTouchUpInside];
            [card addSubview:menu];

            NSUInteger row = index / columns;
            NSUInteger column = index % columns;
            card.frame = CGRectMake(column * (cardWidth + gap),
                                    row * (cardHeight + gap),
                                    cardWidth, cardHeight);
            [_recommendationScroll addSubview:card];

            NSString *requestedURL = [track.thumbnailURL copy];
            if (requestedURL.length) {
                TuneLoadImage(requestedURL, ^(UIImage *image) {
                    if (!image || cardIndex >= _tracks.count) return;
                    TuneTubeTrack *visibleTrack = [_tracks objectAtIndex:cardIndex];
                    if (![visibleTrack.videoID isEqualToString:track.videoID]) return;
                    UIButton *visibleCard =
                        (UIButton *)[_recommendationScroll viewWithTag:6000 + (NSInteger)cardIndex];
                    UIImageView *visibleArtwork =
                        (UIImageView *)[visibleCard viewWithTag:6101];
                    visibleArtwork.image = image;
                });
            }
            [requestedURL release];
        }

        NSUInteger rows = (count + columns - 1) / columns;
        CGFloat contentWidth = landscape && !pad
            ? count * cardWidth + MAX(0.0f, (CGFloat)(count - 1) * gap)
            : available;
        _recommendationScroll.contentSize =
            CGSizeMake(contentWidth,
                       rows * cardHeight + MAX(0.0f, (CGFloat)(rows - 1) * gap));
        NSUInteger visibleRows = (MIN(count, (NSUInteger)9) + columns - 1) / columns;
        _recommendationScroll.scrollEnabled =
            (landscape && count > visibleColumns) ||
            (_homeShowAll && rows > visibleRows);
        _recommendationScroll.hidden = count == 0;
        [self rebuildRecommendationPages];
        [self.view setNeedsLayout];
        return;
    }

    _recommendationPages.hidden = YES;
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
    _recommendationScroll.scrollEnabled = YES;
    [self.view setNeedsLayout];
}

- (void)recommendationPressed:(UIButton *)button {
    if (button.tag >= 7000) {
        NSUInteger index = (NSUInteger)(button.tag - 7000);
        if (index >= [self homeRecommendationCount]) return;
        TuneTubeTrack *track = [self homeRecommendationTrackAtIndex:index];
        if (!track) return;
        _status.text = [NSString stringWithFormat:TuneL(@"loading_title"), track.title];
        TuneTubeRecordTrack(track);
        [(TuneTubePlayer *)_player playTrack:track usingAPI:(TuneTubeAPI *)_api];
        [self.view endEditing:YES];
        return;
    }
    if (button.tag >= 6000) {
        NSUInteger index = (NSUInteger)(button.tag - 6000);
        if (index >= _tracks.count) return;
        TuneTubeTrack *track = [_tracks objectAtIndex:index];
        if (!track.videoID.length || track.isPlaylist) {
            _status.text = TuneL(@"choose_track");
            return;
        }
        _status.text = [NSString stringWithFormat:TuneL(@"loading_title"), track.title];
        TuneTubeRecordTrack(track);
        [(TuneTubePlayer *)_player setQueue:_tracks selectedIndex:index usingAPI:(TuneTubeAPI *)_api];
        [self.view endEditing:YES];
        return;
    }
    NSString *query = button.titleLabel.text;
    if (!query.length) return;
    _search.text = query;
    [self searchBarSearchButtonClicked:_search];
}

- (void)recommendationMenuPressed:(UIButton *)button {
    if (button.tag < 8000) return;
    NSUInteger index = (NSUInteger)(button.tag - 8000);
    TuneTubeTrack *track = [self homeRecommendationTrackAtIndex:index];
    if (track) [self showTrackMenu:track];
}

- (void)quickMenuPressed:(UIButton *)button {
    if (button.tag < 9000) return;
    NSUInteger index = (NSUInteger)(button.tag - 9000);
    if (index < _tracks.count) [self showTrackMenu:[_tracks objectAtIndex:index]];
}

- (void)homeMorePressed {
    if (_search.text.length) return;
    NSMutableArray *queue = [NSMutableArray array];
    NSUInteger count = [self homeRecommendationCount];
    for (NSUInteger index = 0; index < count; ++index) {
        TuneTubeTrack *track = [self homeRecommendationTrackAtIndex:index];
        if (!track) continue;
        [queue addObject:track];
        if (queue.count >= 16) break;
    }
    if (!queue.count) return;
    TuneTubeTrack *first = [queue objectAtIndex:0];
    _status.text = [NSString stringWithFormat:TuneL(@"loading_title"), first.title];
    TuneTubeRecordTrack(first);
    [(TuneTubePlayer *)_player setQueue:queue selectedIndex:0 usingAPI:(TuneTubeAPI *)_api];
}

- (void)showTrackMenu:(TuneTubeTrack *)track {
    if (!track || !track.videoID.length) return;
    [_actionTrack release];
    _actionTrack = [track retain];
    TunePlayerMenuVC *menu = [[[TunePlayerMenuVC alloc]
                               initWithTrack:_actionTrack
                                      player:(TuneTubePlayer *)_player
                                         api:(TuneTubeAPI *)_api
                                    delegate:self] autorelease];
    menu.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)tunePlayerMenu:(TunePlayerMenuVC *)menu didSelectAction:(NSInteger)action {
    (void)menu;
    [self dismissViewControllerAnimated:YES completion:^{
        if (action != TunePlayerMenuActionClose)
            [self performTrackMenuAction:action];
    }];
}

- (void)performTrackMenuAction:(NSInteger)action {
    TuneTubeTrack *track = _actionTrack;
    if (!track) return;
    TuneTubePlayer *player = (TuneTubePlayer *)_player;
    TuneTubeAPI *api = (TuneTubeAPI *)_api;
    switch (action) {
        case TunePlayerMenuActionPlayNext:
            [player enqueueTrack:track usingAPI:api afterCurrent:YES];
            [self showMessage:TuneL(@"menu_play_next_added") message:track.title];
            break;
        case TunePlayerMenuActionPlaylist:
            [self showPlaylistPickerForMenuTrack];
            break;
        case TunePlayerMenuActionShare: {
            NSString *text = [NSString stringWithFormat:@"%@\n%@\nhttps://youtu.be/%@",
                              track.title ?: @"",
                              TuneTubeTrackArtistText(track) ?: @"",
                              track.videoID ?: @""];
            Class activityClass = NSClassFromString(@"UIActivityViewController");
            if (activityClass) {
                UIActivityViewController *activity =
                    [[activityClass alloc] initWithActivityItems:
                     [NSArray arrayWithObject:text] applicationActivities:nil];
                [self presentViewController:activity animated:YES completion:nil];
                [activity release];
            } else {
                [[UIPasteboard generalPasteboard] setString:text];
                [self showMessage:TuneL(@"menu_share_copied") message:text];
            }
            break;
        }
        case TunePlayerMenuActionMix:
            [player setContinuousPlayback:YES];
            [self showMessage:TuneL(@"menu_mix_enabled") message:nil];
            break;
        case TunePlayerMenuActionQueue:
            [player enqueueTrack:track usingAPI:api afterCurrent:NO];
            [self showMessage:TuneL(@"menu_queued") message:track.title];
            break;
        case TunePlayerMenuActionLibrary: {
            BOOL wasSaved = TuneTubeTrackIsSaved(track);
            if (wasSaved) TuneTubeRemoveTrack(track);
            else TuneTubeSaveTrack(track);
            [_favoriteButton setActive:TuneTubeTrackIsSaved(track)];
            [self showMessage:wasSaved ? TuneL(@"removed_library")
                                       : TuneL(@"added_library")
                          message:track.title];
            break;
        }
        case TunePlayerMenuActionDownload:
            [self downloadMenuTrack];
            break;
        case TunePlayerMenuActionRemovePlaylist:
            [self showRemovePlaylistPickerForMenuTrack];
            break;
        case TunePlayerMenuActionAlbum:
            TunePushAlbum(self, track, api, player);
            break;
        case TunePlayerMenuActionArtist:
            TunePushArtistProfile(self, track, api, player);
            break;
        case TunePlayerMenuActionClearQueue:
            [player clearQueue];
            [self showMessage:TuneL(@"menu_queue_cleared") message:nil];
            break;
        case TunePlayerMenuActionSpeed:
            [self showPlaybackSpeedPicker];
            break;
        case TunePlayerMenuActionSleep:
            [self showSleepTimerPicker];
            break;
        default:
            break;
    }
}

- (void)showPlaylistPickerForMenuTrack {
    if (!_actionTrack) return;
    NSArray *names = TuneTubePlaylistNames();
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:TuneL(@"menu_add_playlist")
                                                     message:_actionTrack.title
                                                    delegate:self
                                           cancelButtonTitle:TuneL(@"cancel")
                                           otherButtonTitles:TuneL(@"new_playlist"), nil] autorelease];
    for (NSString *name in names) [alert addButtonWithTitle:name];
    alert.tag = 9301;
    [alert show];
}

- (void)showRemovePlaylistPickerForMenuTrack {
    if (!_actionTrack) return;
    NSArray *names = TuneTubePlaylistsContainingTrack(_actionTrack);
    if (!names.count) {
        [self showMessage:TuneL(@"menu_no_playlists") message:_actionTrack.title];
        return;
    }
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:TuneL(@"menu_remove_playlist")
                                                     message:_actionTrack.title
                                                    delegate:self
                                           cancelButtonTitle:TuneL(@"cancel")
                                           otherButtonTitles:nil] autorelease];
    for (NSString *name in names) [alert addButtonWithTitle:name];
    alert.tag = 9303;
    [alert show];
}

- (void)showPlaybackSpeedPicker {
    UIActionSheet *sheet = [[[UIActionSheet alloc] initWithTitle:TuneL(@"menu_speed")
                                                         delegate:self
                                                cancelButtonTitle:TuneL(@"cancel")
                                           destructiveButtonTitle:nil
                                                otherButtonTitles:@"1x", @"1.25x",
                                                                  @"1.5x", @"2x", nil] autorelease];
    sheet.tag = 9401;
    [sheet showInView:self.view];
}

- (void)showSleepTimerPicker {
    UIActionSheet *sheet = [[[UIActionSheet alloc] initWithTitle:TuneL(@"menu_sleep")
                                                         delegate:self
                                                cancelButtonTitle:TuneL(@"cancel")
                                           destructiveButtonTitle:nil
                                                otherButtonTitles:TuneL(@"menu_off"),
                                                                  TuneL(@"menu_15"),
                                                                  TuneL(@"menu_30"),
                                                                  TuneL(@"menu_60"), nil] autorelease];
    sheet.tag = 9402;
    [sheet showInView:self.view];
}

- (void)showMessage:(NSString *)title message:(NSString *)message {
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:title
                                                     message:message
                                                    delegate:nil
                                           cancelButtonTitle:TuneL(@"done")
                                           otherButtonTitles:nil] autorelease];
    [alert show];
}

- (void)downloadMenuTrack {
    TuneTubeTrack *track = _actionTrack;
    if (!track || !_api) return;
    NSString *trackID = [track.videoID copy];
    NSString *trackTitle = [track.title copy];
    [self showMessage:TuneL(@"menu_download_started") message:track.title];
    [self retain];
    [(TuneTubeAPI *)_api audioURLForTrack:track completion:^(NSURL *audioURL, NSError *error) {
        if (error || !audioURL) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showMessage:TuneL(@"menu_download_failed")
                          message:[error localizedDescription]];
                [self release];
            });
            [trackID release];
            [trackTitle release];
            return;
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:audioURL];
            NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                        NSUserDomainMask,
                                                                        YES) lastObject];
            NSString *path = [documents stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"TuneTube-%@.audio", trackID]];
            BOOL saved = data.length > 0 && [data writeToFile:path atomically:YES];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showMessage:saved ? TuneL(@"menu_download_done")
                                         : TuneL(@"menu_download_failed")
                          message:trackTitle];
                [self release];
            });
        });
        [trackID release];
        [trackTitle release];
    }];
}

- (void)playlistSwipe:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    CGPoint point = [gesture locationInView:_table];
    NSIndexPath *indexPath = [_table indexPathForRowAtPoint:point];
    if (!indexPath || (NSUInteger)indexPath.row >= _tracks.count) return;
    NSUInteger trackIndex = [self homeQuickPickCount] + (NSUInteger)indexPath.row;
    if (trackIndex >= _tracks.count) return;
    TuneTubeTrack *track = [_tracks objectAtIndex:trackIndex];
    if (track.isPlaylist) return;
    [self showPlaylistPickerForTrack:track];
}

- (void)showPlaylistPickerForTrack:(TuneTubeTrack *)track {
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
    } else if (alertView.tag == 9301) {
        if (buttonIndex == alertView.cancelButtonIndex) return;
        if (buttonIndex == 1) {
            UIAlertView *newAlert = [[[UIAlertView alloc] initWithTitle:TuneL(@"new_playlist")
                                                                message:nil
                                                               delegate:self
                                                      cancelButtonTitle:TuneL(@"cancel")
                                                      otherButtonTitles:TuneL(@"create"), nil] autorelease];
            newAlert.alertViewStyle = UIAlertViewStylePlainTextInput;
            newAlert.tag = 9302;
            [newAlert textFieldAtIndex:0].placeholder = TuneL(@"name_placeholder");
            [newAlert show];
            return;
        }
        NSUInteger playlistIndex = (NSUInteger)(buttonIndex - 2);
        NSArray *names = TuneTubePlaylistNames();
        if (playlistIndex < names.count && _actionTrack)
            TuneTubeAddTrackToPlaylist(_actionTrack, [names objectAtIndex:playlistIndex]);
    } else if (alertView.tag == 9302 &&
               buttonIndex != alertView.cancelButtonIndex) {
        NSString *name = [[alertView textFieldAtIndex:0].text
                          stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length && _actionTrack) {
            TuneTubeCreatePlaylist(name);
            TuneTubeAddTrackToPlaylist(_actionTrack, name);
        }
    } else if (alertView.tag == 9303 &&
               buttonIndex != alertView.cancelButtonIndex) {
        NSArray *names = TuneTubePlaylistsContainingTrack(_actionTrack);
        NSUInteger playlistIndex = (NSUInteger)(buttonIndex - 1);
        if (playlistIndex < names.count && _actionTrack) {
            NSString *name = [names objectAtIndex:playlistIndex];
            TuneTubeRemoveTrackFromPlaylist(_actionTrack, name);
            [self showMessage:TuneL(@"menu_remove_playlist") message:name];
        }
    }
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == actionSheet.cancelButtonIndex) return;
    if (actionSheet.tag == 9401) {
        NSArray *rates = [NSArray arrayWithObjects:
                          [NSNumber numberWithFloat:1.0f],
                          [NSNumber numberWithFloat:1.25f],
                          [NSNumber numberWithFloat:1.5f],
                          [NSNumber numberWithFloat:2.0f], nil];
        if (buttonIndex < (NSInteger)rates.count)
            [(TuneTubePlayer *)_player setPlaybackRate:
             [[rates objectAtIndex:(NSUInteger)buttonIndex] floatValue]];
    } else if (actionSheet.tag == 9402) {
        if (buttonIndex == 0) {
            [(TuneTubePlayer *)_player cancelSleepTimer];
            [self showMessage:TuneL(@"menu_sleep_off") message:nil];
        } else {
            NSArray *durations = [NSArray arrayWithObjects:
                                  [NSNumber numberWithDouble:15.0 * 60.0],
                                  [NSNumber numberWithDouble:30.0 * 60.0],
                                  [NSNumber numberWithDouble:60.0 * 60.0], nil];
            NSUInteger durationIndex = (NSUInteger)(buttonIndex - 1);
            if (durationIndex < durations.count) {
                [(TuneTubePlayer *)_player setSleepTimer:
                 [[durations objectAtIndex:durationIndex] doubleValue]];
                [self showMessage:TuneL(@"menu_sleep")
                          message:[actionSheet buttonTitleAtIndex:buttonIndex]];
            }
        }
    }
}

- (void)playPressed {
    if (![(TuneTubePlayer *)_player track]) return;
    [(TuneTubePlayer *)_player toggle];
}

- (void)tuneArtistCell:(id)cell didSelectTrack:(TuneTubeTrack *)track {
    (void)cell;
    TunePushArtistProfile(self, track, (TuneTubeAPI *)_api, (TuneTubePlayer *)_player);
}

- (void)tuneTrackCell:(id)cell didPressMenuForTrack:(TuneTubeTrack *)track {
    (void)cell;
    [self showTrackMenu:track];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyTheme:nil];
    NSString *key = [[NSUserDefaults standardUserDefaults]
                     objectForKey:TUNETUBE_API_KEY_DEFAULTS_KEY];
    [_api release];
    _api = [[TuneTubeAPI alloc] initWithAPIKey:key.length ? key : TuneTubeDefaultAPIKey];
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
    TuneLibraryVC *library = [[[TuneLibraryVC alloc] initWithPlayer:(TuneTubePlayer *)_player
                                                                 api:(TuneTubeAPI *)_api] autorelease];
    UINavigationController *navigation =
        [[[UINavigationController alloc] initWithRootViewController:library] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)playerPressed {
    if (![(TuneTubePlayer *)_player track]) return;
    TunePlayerVC *player = [[[TunePlayerVC alloc] initWithPlayer:(TuneTubePlayer *)_player
                                                              api:(TuneTubeAPI *)_api] autorelease];
    UINavigationController *navigation =
        [[[UINavigationController alloc] initWithRootViewController:player] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)refreshPlayerUI:(NSNotification *)note {
    TuneTubePlayer *player = (TuneTubePlayer *)[note object];
    if (!player) player = (TuneTubePlayer *)_player;
    NSError *error = [[note userInfo] objectForKey:@"error"];
    if (error) {
        _status.text = TunePlaybackErrorText(error);
        _miniPlayer.hidden = player.track == nil;
        [_playButton setPlaying:NO];
        [self.view setNeedsLayout];
        return;
    }
    if (player.track) {
        _miniPlayer.hidden = NO;
        _nowTitle.text = player.track.title;
        _nowArtist.text = TuneTubeTrackArtistText(player.track);
        [_playButton setPlaying:player.isPlaying];
        _status.text = player.isPlaying ? TuneL(@"playing_now") : TuneL(@"paused");
        [_favoriteButton setActive:TuneTubeTrackIsSaved(player.track)];

        NSString *requestedURL = [player.track.thumbnailURL copy];
        TuneLoadImage(requestedURL, ^(UIImage *image) {
            if (image && [(TuneTubePlayer *)_player track] == player.track &&
                [requestedURL isEqualToString:player.track.thumbnailURL]) {
                _miniArtwork.image = image;
            }
        });
        [requestedURL release];
    } else {
        _miniPlayer.hidden = YES;
        _nowTitle.text = TuneL(@"nothing_playing");
        _nowArtist.text = TuneL(@"pick_song");
        _miniArtwork.image = [UIImage imageNamed:@"Icon.png"];
        [_favoriteButton setActive:NO];
        [_playButton setPlaying:NO];
    }
    [self.view setNeedsLayout];
}

- (void)appendPersonalizedTracks:(NSArray *)tracks {
    if (![tracks isKindOfClass:[NSArray class]]) return;
    for (TuneTubeTrack *track in tracks) {
        if (!track.videoID.length || track.isPlaylist) continue;
        if (track.resultType.length &&
            [track.resultType caseInsensitiveCompare:@"Song"] != NSOrderedSame)
            continue;
        NSString *artist = TuneTubeTrackArtistText(track);
        if ([artist caseInsensitiveCompare:@"Various Artists"] == NSOrderedSame ||
            [artist caseInsensitiveCompare:@"YouTube Music"] == NSOrderedSame)
            continue;
        BOOL duplicate = NO;
        for (TuneTubeTrack *existing in _tracks)
            if ([existing.videoID isEqualToString:track.videoID]) {
                duplicate = YES;
                break;
            }
        if (!duplicate)
            for (TuneTubeTrack *existing in _homeRecommendationTracks)
                if ([existing.videoID isEqualToString:track.videoID]) {
                    duplicate = YES;
                    break;
                }
        if (duplicate) continue;
        [_homeRecommendationTracks addObject:track];
        if (_homeRecommendationTracks.count >= 16) break;
    }
}

- (void)loadRecommendationQueries:(NSArray *)queries index:(NSUInteger)index {
    if (_search.text.length || index >= queries.count ||
        _homeRecommendationTracks.count >= 16) {
        [self rebuildRecommendationPages];
        return;
    }
    NSString *query = [queries objectAtIndex:index];
    [(TuneTubeAPI *)_api search:query completion:^(NSArray *tracks, NSError *error) {
        (void)error;
        if (_search.text.length) return;
        [self appendPersonalizedTracks:tracks];
        if (_homeRecommendationTracks.count >= 16 || index + 1 >= queries.count) {
            [self rebuildRecommendationPages];
            [self.view setNeedsLayout];
            return;
        }
        [self loadRecommendationQueries:queries index:index + 1];
    }];
}

- (void)loadPersonalizedRecommendations {
    [_homeRecommendationTracks removeAllObjects];
    NSMutableArray *queries = [NSMutableArray array];
    NSMutableArray *artists = [NSMutableArray array];
    NSArray *sources = [NSArray arrayWithObjects:TuneTubeRecentTracks(),
                                                  TuneTubeLibraryTracks(), nil];
    for (NSArray *source in sources) {
        for (TuneTubeTrack *track in source) {
            NSString *artist = TuneTubeDisplayArtist(track.artist);
            if (!TuneRecommendationArtistIsValid(artist) ||
                [artist caseInsensitiveCompare:@"Various Artists"] == NSOrderedSame ||
                [artist caseInsensitiveCompare:@"YouTube Music"] == NSOrderedSame)
                continue;
            BOOL duplicate = NO;
            for (NSString *existing in artists)
                if ([existing caseInsensitiveCompare:artist] == NSOrderedSame) {
                    duplicate = YES;
                    break;
                }
            if (duplicate) continue;
            [artists addObject:artist];
            [queries addObject:[NSString stringWithFormat:@"%@ music", artist]];
            if (queries.count >= 4) break;
        }
        if (queries.count >= 4) break;
    }
    if (!queries.count) [queries addObject:@"popular music"];
    [self loadRecommendationQueries:queries index:0];
}

- (void)loadQuickPicks {
    if (_search.text.length || _tracks.count) return;
    [_tracks addObjectsFromArray:TuneTubeRecentTracks()];
    _homeShowAll = NO;
    _sectionTitle.text = TuneL(@"recommendations");
    _status.text = _tracks.count ? TuneL(@"recently_played") : @"";
    [_table reloadData];
    [self rebuildRecommendations];
    if (!_homeRecommendationTracks.count)
        [self loadPersonalizedRecommendations];

    NSUInteger targetCount = 32;
    if (_tracks.count >= targetCount) return;
    [(TuneTubeAPI *)_api search:@"popular music" completion:^(NSArray *tracks, NSError *error) {
        if (error || _search.text.length || _tracks.count >= targetCount) return;
        for (TuneTubeTrack *track in tracks) {
            if (!track.videoID.length || track.isPlaylist) continue;
            BOOL duplicate = NO;
            for (TuneTubeTrack *existing in _tracks) {
                if ([existing.videoID isEqualToString:track.videoID]) {
                    duplicate = YES;
                    break;
                }
            }
            if (duplicate) continue;
            [_tracks addObject:track];
            if (_tracks.count >= targetCount) break;
        }
        _status.text = @"";
        [_table reloadData];
        [self rebuildRecommendations];
    }];
}

- (void)favoritePressed {
    TuneTubeTrack *track = [(TuneTubePlayer *)_player track];
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
            [(TuneTubePlayer *)_player toggle];
            break;
        case UIEventSubtypeRemoteControlNextTrack:
            [(TuneTubePlayer *)_player nextTrack];
            break;
        case UIEventSubtypeRemoteControlPreviousTrack:
            [(TuneTubePlayer *)_player previousTrack];
            break;
        default:
            break;
    }
}

@end
