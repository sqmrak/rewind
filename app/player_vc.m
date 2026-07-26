#import "player_vc.h"

#import <QuartzCore/QuartzCore.h>

#import "ytm_api.h"
#import "ytm_player.h"
#import "library_vc.h"
#import "artist_vc.h"
#import "play_button.h"
#import "tunetube_image_cache.h"
#import "tunetube_theme.h"
#import "tunetube_l10n.h"

static NSString *PlayerTime(NSUInteger seconds) {
    return [NSString stringWithFormat:@"%lu:%02lu",
            (unsigned long)(seconds / 60), (unsigned long)(seconds % 60)];
}

static UIImage *TunePlayerMaskImage(UIImage *mask, UIColor *color) {
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

static UIImage *TunePlayerLibraryImage(CGFloat size) {
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

static UIImage *TunePlayerSearchImage(CGFloat size) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0.0f);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(context, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(context, MAX(1.3f, size * 0.075f));
    CGContextSetLineCap(context, kCGLineCapRound);

    CGContextStrokeEllipseInRect(context,
                                 CGRectMake(size * 0.16f, size * 0.14f,
                                            size * 0.48f, size * 0.48f));
    CGContextMoveToPoint(context, size * 0.56f, size * 0.56f);
    CGContextAddLineToPoint(context, size * 0.84f, size * 0.84f);
    CGContextStrokePath(context);

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@interface TunePlayerHeaderButton : UIButton {
    CAGradientLayer *_gradient;
}
- (void)applyTheme;
@end

@implementation TunePlayerHeaderButton

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _gradient = [[CAGradientLayer layer] retain];
    _gradient.cornerRadius = 8.0f;
    [self.layer insertSublayer:_gradient atIndex:0];
    self.backgroundColor = [UIColor clearColor];
    self.layer.cornerRadius = 8.0f;
    self.layer.borderWidth = 1.0f;
    self.layer.borderColor = TuneThemeNavigationBorder().CGColor;
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.24f;
    self.layer.shadowOffset = CGSizeMake(0.0f, 2.0f);
    self.layer.shadowRadius = 1.5f;
    self.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    self.adjustsImageWhenHighlighted = NO;
    return self;
}

- (void)dealloc {
    [_gradient release];
    [super dealloc];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _gradient.frame = self.bounds;
}

- (void)applyTheme {
    _gradient.colors = [NSArray arrayWithObjects:
                        (id)TuneThemeNavigationTop().CGColor,
                        (id)TuneThemeNavigationBottom().CGColor, nil];
    self.backgroundColor = [UIColor clearColor];
    self.layer.borderColor = TuneThemeNavigationBorder().CGColor;
    self.layer.shadowOpacity = 0.24f;
    [self setTitleColor:TuneThemeHeaderText() forState:UIControlStateNormal];
}

@end

static void PlayerStyleSlider(UISlider *slider) {
    if ([slider respondsToSelector:@selector(setMinimumTrackTintColor:)]) {
        slider.minimumTrackTintColor = TuneThemeSliderMinimum();
        slider.maximumTrackTintColor = TuneThemeSliderMaximum();
    }
    if ([slider respondsToSelector:@selector(setThumbTintColor:)])
        slider.thumbTintColor = TuneThemeSliderThumb();
}

static BOOL PlayerIsPad(void) {
    return [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
}

static BOOL PlayerIsCompactPhone(CGFloat height) {
    return !PlayerIsPad() && height <= 568.0f;
}

@interface TunePlayerVC ()
- (void)refresh:(NSNotification *)note;
- (void)updateProgress:(NSTimer *)timer;
- (void)progressChanged:(UISlider *)slider;
- (void)searchPressed;
- (void)libraryPressed;
- (void)backPressed;
- (void)togglePressed;
- (void)favoritePressed;
- (void)nextTrackPressed;
- (void)previousTrackPressed;
- (void)repeatPressed;
- (void)artistPressed;
- (void)applyTheme:(NSNotification *)note;
@end

@implementation TunePlayerVC

- (id)initWithPlayer:(YTMPlayer *)player {
    return [self initWithPlayer:player api:nil];
}

- (id)initWithPlayer:(YTMPlayer *)player api:(YTMAPI *)api {
    self = [super init];
    if (self) {
        _player = [player retain];
        _api = [api retain];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_player release];
    [_api release];
    [_backgroundGradient release];
    [_headerGradient release];
    [_headerBar release];
    [_headerSearch release];
    [_headerLibrary release];
    [_headerTitle release];
    [_artwork release];
    [_titleLabel release];
    [_artistLabel release];
    [_artistButton release];
    [_progress release];
    [_elapsedLabel release];
    [_durationLabel release];
    [_previousButton release];
    [_nextButton release];
    [_repeatButton release];
    [_favoriteButton release];
    [_playButton release];
    [_progressTimer invalidate];
    [_progressTimer release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = TuneThemePlayerBackgroundBottom();
    self.view = view;
}

- (UIButton *)textButton:(NSString *)title size:(CGFloat)size {
    UIButton *button = [[[TunePlayerHeaderButton alloc] initWithFrame:CGRectZero] autorelease];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:TuneThemeHeaderText() forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:size];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBarHidden = NO;
    self.title = @"TuneTube";
    self.navigationItem.leftBarButtonItem =
        [[[UIBarButtonItem alloc] initWithTitle:TuneL(@"back")
                                          style:UIBarButtonItemStyleBordered
                                         target:self
                                         action:@selector(backPressed)] autorelease];
    self.navigationItem.rightBarButtonItem =
        [[[UIBarButtonItem alloc] initWithTitle:TuneL(@"library")
                                          style:UIBarButtonItemStyleBordered
                                         target:self
                                         action:@selector(libraryPressed)] autorelease];
    _backgroundGradient = [[CAGradientLayer layer] retain];
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)TuneThemePlayerBackgroundTop().CGColor,
                                  (id)TuneThemePlayerBackgroundBottom().CGColor, nil];
    _backgroundGradient.locations = [NSArray arrayWithObjects:@0.0f, @1.0f, nil];
    [self.view.layer insertSublayer:(CAGradientLayer *)_backgroundGradient atIndex:0];

    _headerBar = [[UIView alloc] initWithFrame:CGRectZero];
    _headerBar.backgroundColor = [UIColor clearColor];
    _headerBar.hidden = YES;
    _headerBar.layer.borderWidth = 1.0f;
    _headerBar.layer.borderColor = TuneThemeNavigationBorder().CGColor;
    _headerGradient = [[CAGradientLayer layer] retain];
    [_headerBar.layer insertSublayer:_headerGradient atIndex:0];
    [self.view addSubview:_headerBar];

    _headerSearch = [[self textButton:@"Search" size:12.0f] retain];
    [_headerSearch setTitle:nil forState:UIControlStateNormal];
    [_headerSearch setImage:TunePlayerMaskImage(TunePlayerSearchImage(24.0f),
                                                TuneThemeHeaderText())
                    forState:UIControlStateNormal];
    _headerSearch.imageEdgeInsets = UIEdgeInsetsMake(5.0f, 5.0f, 5.0f, 5.0f);
    _headerSearch.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    _headerSearch.accessibilityLabel = @"Search";
    [_headerSearch addTarget:self action:@selector(searchPressed)
            forControlEvents:UIControlEventTouchUpInside];
    [_headerBar addSubview:_headerSearch];

    _headerLibrary = [[self textButton:@"Library" size:12.0f] retain];
    [_headerLibrary setTitle:nil forState:UIControlStateNormal];
    [_headerLibrary setImage:TunePlayerMaskImage(TunePlayerLibraryImage(24.0f),
                                                 TuneThemeHeaderText())
                     forState:UIControlStateNormal];
    _headerLibrary.imageEdgeInsets = UIEdgeInsetsMake(5.0f, 5.0f, 5.0f, 5.0f);
    _headerLibrary.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    _headerLibrary.accessibilityLabel = @"Library";
    [_headerLibrary addTarget:self action:@selector(libraryPressed)
              forControlEvents:UIControlEventTouchUpInside];
    [_headerBar addSubview:_headerLibrary];

    _headerTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _headerTitle.backgroundColor = [UIColor clearColor];
    _headerTitle.textColor = TuneThemePrimaryText();
    _headerTitle.font = [UIFont boldSystemFontOfSize:17.0f];
    _headerTitle.textAlignment = NSTextAlignmentCenter;
    _headerTitle.text = @"TuneTube";
    _headerTitle.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.65f];
    _headerTitle.shadowOffset = CGSizeMake(0.0f, 2.0f);
    [_headerBar addSubview:_headerTitle];

    _artwork = [[UIImageView alloc] initWithFrame:CGRectZero];
    _artwork.image = [UIImage imageNamed:@"Icon.png"];
    _artwork.contentMode = UIViewContentModeScaleAspectFill;
    _artwork.clipsToBounds = YES;
    _artwork.backgroundColor = [UIColor colorWithWhite:0.08f alpha:1.0f];
    _artwork.layer.cornerRadius = 14.0f;
    _artwork.layer.masksToBounds = YES;
    _artwork.layer.borderWidth = 1.0f;
    _artwork.layer.borderColor = TuneThemeBorder().CGColor;
    [self.view addSubview:_artwork];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.textColor = TuneThemePrimaryText();
    _titleLabel.font = [UIFont boldSystemFontOfSize:20.0f];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
    _titleLabel.numberOfLines = 2;
    [self.view addSubview:_titleLabel];

    _artistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _artistLabel.backgroundColor = [UIColor clearColor];
    _artistLabel.textColor = TuneThemeSecondaryText();
    _artistLabel.font = [UIFont systemFontOfSize:13.0f];
    _artistLabel.textAlignment = NSTextAlignmentCenter;
    _artistLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [self.view addSubview:_artistLabel];

    _artistButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _artistButton.adjustsImageWhenHighlighted = NO;
    _artistButton.accessibilityLabel = TuneL(@"artist_profile");
    [_artistButton addTarget:self action:@selector(artistPressed)
            forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_artistButton];


    _progress = [[UISlider alloc] initWithFrame:CGRectZero];
    _progress.minimumValue = 0.0f;
    _progress.maximumValue = 1.0f;
    _progress.value = 0.0f;
    PlayerStyleSlider(_progress);
    _progress.userInteractionEnabled = YES;
    [_progress addTarget:self action:@selector(progressChanged:)
        forControlEvents:UIControlEventValueChanged | UIControlEventTouchUpInside |
                         UIControlEventTouchUpOutside];
    [self.view addSubview:_progress];

    _elapsedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _elapsedLabel.backgroundColor = [UIColor clearColor];
    _elapsedLabel.textColor = TuneThemeMutedText();
    _elapsedLabel.font = [UIFont systemFontOfSize:11.0f];
    [self.view addSubview:_elapsedLabel];

    _durationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _durationLabel.backgroundColor = [UIColor clearColor];
    _durationLabel.textColor = TuneThemeMutedText();
    _durationLabel.font = [UIFont systemFontOfSize:11.0f];
    _durationLabel.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:_durationLabel];

    _playButton = [[TunePlaybackButton alloc] initWithFrame:CGRectZero];
    [_playButton setLightStyle:NO];
    [_playButton addTarget:self action:@selector(togglePressed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_playButton];

    _previousButton = [[TuneRoundButton alloc] initWithKind:TuneRoundButtonKindPrevious];
    [_previousButton addTarget:self action:@selector(previousTrackPressed)
              forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_previousButton];

    _nextButton = [[TuneRoundButton alloc] initWithKind:TuneRoundButtonKindNext];
    [_nextButton addTarget:self action:@selector(nextTrackPressed)
          forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_nextButton];

    _repeatButton = [[TuneRoundButton alloc] initWithKind:TuneRoundButtonKindRepeat];
    [_repeatButton addTarget:self action:@selector(repeatPressed)
            forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_repeatButton];

    _favoriteButton = [[TuneRoundButton alloc] initWithKind:TuneRoundButtonKindStar];
    [_favoriteButton addTarget:self action:@selector(favoritePressed)
              forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_favoriteButton];

    _artwork.userInteractionEnabled = YES;
    UISwipeGestureRecognizer *nextSwipe = [[[UISwipeGestureRecognizer alloc]
                                             initWithTarget:self action:@selector(nextTrackPressed)] autorelease];
    nextSwipe.direction = UISwipeGestureRecognizerDirectionLeft;
    [_artwork addGestureRecognizer:nextSwipe];
    UISwipeGestureRecognizer *previousSwipe = [[[UISwipeGestureRecognizer alloc]
                                                 initWithTarget:self action:@selector(previousTrackPressed)] autorelease];
    previousSwipe.direction = UISwipeGestureRecognizerDirectionRight;
    [_artwork addGestureRecognizer:previousSwipe];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refresh:)
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
    [self applyTheme:nil];
    [self refresh:nil];
}

- (void)languageChanged:(NSNotification *)note {
    (void)note;
    self.navigationItem.leftBarButtonItem =
        [[[UIBarButtonItem alloc] initWithTitle:TuneL(@"back")
                                          style:UIBarButtonItemStyleBordered
                                         target:self
                                         action:@selector(backPressed)] autorelease];
    self.navigationItem.rightBarButtonItem =
        [[[UIBarButtonItem alloc] initWithTitle:TuneL(@"library")
                                          style:UIBarButtonItemStyleBordered
                                         target:self
                                         action:@selector(libraryPressed)] autorelease];
    [self refresh:nil];
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = TuneThemePlayerBackgroundBottom();
    TuneTubeStyleNavigationBar(self.navigationController.navigationBar);
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)TuneThemePlayerBackgroundTop().CGColor,
                                  (id)TuneThemePlayerBackgroundBottom().CGColor, nil];
    _backgroundGradient.locations = [NSArray arrayWithObjects:@0.0f, @1.0f, nil];
    _headerGradient.frame = _headerBar.bounds;
    _headerGradient.colors = [NSArray arrayWithObjects:
                              (id)TuneThemeNavigationTop().CGColor,
                              (id)TuneThemeNavigationBottom().CGColor, nil];
    _headerBar.backgroundColor = [UIColor clearColor];
    _headerBar.layer.borderColor = TuneThemeNavigationBorder().CGColor;
    [_headerSearch setImage:TunePlayerMaskImage(TunePlayerSearchImage(24.0f),
                                                TuneThemeHeaderText())
                    forState:UIControlStateNormal];
    [_headerLibrary setImage:TunePlayerMaskImage(TunePlayerLibraryImage(24.0f),
                                                 TuneThemeHeaderText())
                     forState:UIControlStateNormal];
    [(TunePlayerHeaderButton *)_headerSearch applyTheme];
    [(TunePlayerHeaderButton *)_headerLibrary applyTheme];
    _headerTitle.textColor = TuneThemePrimaryText();
    _artwork.layer.borderColor = TuneThemeBorder().CGColor;
    _titleLabel.textColor = TuneThemePrimaryText();
    _artistLabel.textColor = TuneThemeSecondaryText();
    _elapsedLabel.textColor = TuneThemeMutedText();
    _durationLabel.textColor = TuneThemeMutedText();
    [_previousButton applyTheme];
    [_nextButton applyTheme];
    [_repeatButton applyTheme];
    [_favoriteButton applyTheme];
    [_playButton applyTheme];
    PlayerStyleSlider(_progress);
    [self.view setNeedsLayout];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!_progressTimer) {
        _progressTimer = [[NSTimer scheduledTimerWithTimeInterval:0.5f
                                                            target:self
                                                          selector:@selector(updateProgress:)
                                                          userInfo:nil
                                                            repeats:YES] retain];
    }
    [self becomeFirstResponder];
}

- (void)viewWillDisappear:(BOOL)animated {
    [_progressTimer invalidate];
    [_progressTimer release];
    _progressTimer = nil;
    [self resignFirstResponder];
    [super viewWillDisappear:animated];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    _backgroundGradient.frame = b;
    BOOL landscape = b.size.width > b.size.height;
    BOOL compact = PlayerIsCompactPhone(b.size.height);
    _headerBar.frame = CGRectZero;

    if (landscape) {
        CGFloat side = PlayerIsPad() ? 28.0f : 14.0f;
        CGFloat top = PlayerIsPad() ? 18.0f : 10.0f;
        CGFloat leftWidth = MIN(b.size.height - 40.0f, b.size.width * 0.44f);
        if (leftWidth < 160.0f) leftWidth = 160.0f;

        // square cover, max that still fits title under it
        CGFloat artSize = MIN(leftWidth - 12.0f, b.size.height - 72.0f);
        if (artSize < 120.0f) artSize = 120.0f;
        CGFloat artX = side + floorf((leftWidth - artSize) * 0.5f);
        CGFloat artY = top + floorf((b.size.height - top - artSize - 52.0f) * 0.35f);
        _artwork.frame = CGRectMake(artX, artY, artSize, artSize);
        _artwork.layer.cornerRadius = 12.0f;

        CGFloat titleY = CGRectGetMaxY(_artwork.frame) + 8.0f;
        CGFloat leftTextWidth = leftWidth - 8.0f;
        _titleLabel.font = [UIFont boldSystemFontOfSize:compact ? 15.0f : 17.0f];
        _titleLabel.numberOfLines = 1;
        _titleLabel.frame = CGRectMake(side + 4.0f, titleY, leftTextWidth, 22.0f);
        _artistLabel.font = [UIFont systemFontOfSize:12.0f];
        _artistLabel.frame = CGRectMake(side + 4.0f, titleY + 22.0f, leftTextWidth, 18.0f);
        _artistButton.frame = _artistLabel.frame;

        CGFloat rightX = side + leftWidth + (PlayerIsPad() ? 28.0f : 16.0f);
        CGFloat rightWidth = MAX(120.0f, b.size.width - rightX - side);
        CGFloat playSize = compact ? 54.0f : (PlayerIsPad() ? 74.0f : 66.0f);
        CGFloat small = compact ? 32.0f : (PlayerIsPad() ? 46.0f : 40.0f);
        CGFloat gap = compact ? 4.0f : 8.0f;
        CGFloat sliderBlock = 44.0f;
        CGFloat stackGap = 12.0f;
        CGFloat blockHeight = sliderBlock + stackGap + playSize;
        CGFloat blockTop = floorf((b.size.height - blockHeight) * 0.5f);
        if (blockTop < 14.0f) blockTop = 14.0f;
        if (blockTop + blockHeight > b.size.height - 10.0f)
            blockTop = MAX(10.0f, b.size.height - 10.0f - blockHeight);

        _progress.frame = CGRectMake(rightX, blockTop, rightWidth, 24.0f);
        _elapsedLabel.frame = CGRectMake(rightX + 2.0f, blockTop + 22.0f, 70.0f, 16.0f);
        _durationLabel.frame = CGRectMake(rightX + rightWidth - 72.0f, blockTop + 22.0f,
                                          70.0f, 16.0f);

        CGFloat controlY = blockTop + sliderBlock + stackGap;
        CGFloat groupWidth = playSize + (small * 4.0f) + (gap * 4.0f);
        CGFloat groupX = floorf(rightX + (rightWidth - groupWidth) * 0.5f);
        groupX = MAX(rightX, MIN(groupX, rightX + rightWidth - groupWidth));
        CGFloat playX = groupX + small + gap + small + gap;
        _playButton.frame = CGRectMake(playX, controlY, playSize, playSize);
        CGFloat smallY = controlY + floorf((playSize - small) * 0.5f);
        _favoriteButton.frame = CGRectMake(groupX, smallY, small, small);
        _previousButton.frame = CGRectMake(groupX + small + gap, smallY, small, small);
        _nextButton.frame = CGRectMake(CGRectGetMaxX(_playButton.frame) + gap,
                                       smallY, small, small);
        _repeatButton.frame = CGRectMake(CGRectGetMaxX(_nextButton.frame) + gap,
                                         smallY, small, small);
    } else {
        // portrait: cover, then title/artist, then slider, then transport near bottom
        CGFloat side = PlayerIsPad() ? 48.0f : 22.0f;
        CGFloat playSize = PlayerIsPad() ? 80.0f : (compact ? 58.0f : 64.0f);
        CGFloat small = PlayerIsPad() ? 48.0f : (compact ? 38.0f : 42.0f);
        CGFloat gap = PlayerIsPad() ? 10.0f : 7.0f;
        CGFloat bottomPad = 16.0f;
        CGFloat transportH = playSize;
        CGFloat sliderH = 44.0f;
        CGFloat metaH = 52.0f;
        CGFloat usedBottom = bottomPad + transportH + 10.0f + sliderH + 8.0f + metaH;
        CGFloat artTop = PlayerIsPad() ? 16.0f : 8.0f;
        CGFloat artMax = b.size.height - artTop - usedBottom;
        CGFloat artSize = MIN(b.size.width - side * 2.0f, artMax);
        if (PlayerIsPad())
            artSize = MIN(artSize, 480.0f);
        else
            artSize = MIN(artSize, compact ? 200.0f : 240.0f);
        if (artSize < 120.0f) artSize = 120.0f;
        CGFloat artX = floorf((b.size.width - artSize) * 0.5f);
        _artwork.frame = CGRectMake(artX, artTop, artSize, artSize);
        _artwork.layer.cornerRadius = 14.0f;

        CGFloat titleY = CGRectGetMaxY(_artwork.frame) + 10.0f;
        _titleLabel.font = [UIFont boldSystemFontOfSize:PlayerIsPad() ? 22.0f : 18.0f];
        _titleLabel.numberOfLines = 2;
        _titleLabel.frame = CGRectMake(side, titleY, b.size.width - side * 2.0f, 40.0f);
        _artistLabel.font = [UIFont systemFontOfSize:PlayerIsPad() ? 14.0f : 13.0f];
        _artistLabel.frame = CGRectMake(side, titleY + 40.0f, b.size.width - side * 2.0f, 18.0f);
        _artistButton.frame = _artistLabel.frame;

        CGFloat controlY = b.size.height - bottomPad - playSize;
        CGFloat sliderY = controlY - 10.0f - sliderH;
        // if meta collides with slider, pull slider down chain is already bottom-up
        if (sliderY < CGRectGetMaxY(_artistLabel.frame) + 6.0f)
            sliderY = CGRectGetMaxY(_artistLabel.frame) + 6.0f;

        _progress.frame = CGRectMake(side, sliderY, b.size.width - side * 2.0f, 24.0f);
        _elapsedLabel.frame = CGRectMake(side + 2.0f, sliderY + 22.0f, 70.0f, 16.0f);
        _durationLabel.frame = CGRectMake(b.size.width - side - 72.0f, sliderY + 22.0f,
                                          70.0f, 16.0f);

        CGFloat groupWidth = playSize + (small * 4.0f) + (gap * 4.0f);
        CGFloat groupX = floorf((b.size.width - groupWidth) * 0.5f);
        CGFloat playX = groupX + small + gap + small + gap;
        _playButton.frame = CGRectMake(playX, controlY, playSize, playSize);
        CGFloat smallY = controlY + floorf((playSize - small) * 0.5f);
        _favoriteButton.frame = CGRectMake(groupX, smallY, small, small);
        _previousButton.frame = CGRectMake(groupX + small + gap, smallY, small, small);
        _nextButton.frame = CGRectMake(CGRectGetMaxX(_playButton.frame) + gap,
                                       smallY, small, small);
        _repeatButton.frame = CGRectMake(CGRectGetMaxX(_nextButton.frame) + gap,
                                         smallY, small, small);
    }
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)orientation
                                          duration:(NSTimeInterval)duration {
    (void)orientation;
    (void)duration;
    [self.view setNeedsLayout];
}

- (void)refresh:(NSNotification *)note {
    NSError *error = [[note userInfo] objectForKey:@"error"];
    YTMTrack *track = _player.track;
    if (!track) {
        _titleLabel.text = TuneL(@"nothing_playing");
        _artistLabel.text = TuneL(@"choose_track");
        _elapsedLabel.text = @"0:00";
        _durationLabel.text = @"0:00";
        _progress.value = 0.0f;
        [_playButton setPlaying:NO];
        [_favoriteButton setActive:NO];
        [_repeatButton setActive:_player.isRepeating];
        _artwork.image = [UIImage imageNamed:@"Icon.png"];
        _artistButton.hidden = YES;
        return;
    }

    _titleLabel.text = track.title;
    if (error) {
        _artistLabel.text = YTMTrackArtistText(track);
        _elapsedLabel.text = @"0:00";
        _durationLabel.text = PlayerTime(track.duration);
        _progress.value = 0.0f;
        [_playButton setPlaying:NO];
        return;
    }
    NSString *artistName = YTMTrackArtistText(track);
    _artistLabel.text = [artistName caseInsensitiveCompare:@"Unknown artist"] == NSOrderedSame
        ? TuneL(@"unknown_artist") : artistName;
    BOOL hasArtist = artistName.length > 0 &&
        [artistName caseInsensitiveCompare:@"Unknown artist"] != NSOrderedSame &&
        [artistName caseInsensitiveCompare:@"YouTube Music"] != NSOrderedSame;
    _artistButton.hidden = !hasArtist;
    _progress.value = [_player progress];
    _elapsedLabel.text = PlayerTime((NSUInteger)[_player currentTime]);
    _durationLabel.text = PlayerTime((NSUInteger)[_player duration]);
    [_playButton setPlaying:_player.isPlaying];
    [_favoriteButton setActive:TuneTubeTrackIsSaved(track)];
    [_repeatButton setActive:_player.isRepeating];

    [self.view setNeedsLayout];

    NSString *requestedURL = [track.thumbnailURL copy];
    TuneLoadImage(requestedURL, ^(UIImage *image) {
        if (image && _player.track == track &&
            [requestedURL isEqualToString:track.thumbnailURL])
            _artwork.image = image;
    });
    [requestedURL release];
}

- (void)updateProgress:(NSTimer *)timer {
    (void)timer;
    if (!_player.track) return;
    _progress.value = [_player progress];
    _elapsedLabel.text = PlayerTime((NSUInteger)[_player currentTime]);
    _durationLabel.text = PlayerTime((NSUInteger)[_player duration]);
}

- (void)progressChanged:(UISlider *)slider {
    [_player seekToProgress:slider.value];
    [self updateProgress:nil];
}

- (void)searchPressed {
    [[NSNotificationCenter defaultCenter]
     postNotificationName:TuneTubeFocusSearchNotification object:nil];
}

- (void)libraryPressed {
    if (!_player || !_api) return;
    TuneLibraryVC *library = [[[TuneLibraryVC alloc] initWithPlayer:_player api:_api] autorelease];
    UINavigationController *navigation =
        [[[UINavigationController alloc] initWithRootViewController:library] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)backPressed {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)togglePressed {
    if (!_player.track) return;
    [_player toggle];
}

- (void)favoritePressed {
    YTMTrack *track = _player.track;
    if (!track) return;
    if (TuneTubeTrackIsSaved(track)) TuneTubeRemoveTrack(track);
    else TuneTubeSaveTrack(track);
    [_favoriteButton setActive:TuneTubeTrackIsSaved(track)];
}

- (void)artistPressed {
    YTMTrack *track = _player.track;
    TunePushArtistProfile(self, track, _api, _player);
}

- (void)nextTrackPressed {
    [_player nextTrack];
    if (_player.track) TuneTubeRecordTrack(_player.track);
}

- (void)previousTrackPressed {
    [_player previousTrack];
    if (_player.track) TuneTubeRecordTrack(_player.track);
}

- (void)repeatPressed {
    [_player setRepeating:!_player.isRepeating];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    if (event.type != UIEventTypeRemoteControl) return;
    switch (event.subtype) {
        case UIEventSubtypeRemoteControlPlay:
        case UIEventSubtypeRemoteControlPause:
        case UIEventSubtypeRemoteControlTogglePlayPause:
            [_player toggle];
            break;
        case UIEventSubtypeRemoteControlNextTrack:
            [_player nextTrack];
            break;
        case UIEventSubtypeRemoteControlPreviousTrack:
            [_player previousTrack];
            break;
        default:
            break;
    }
}

@end
