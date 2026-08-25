#import "about_vc.h"

#import <QuartzCore/QuartzCore.h>
#import "tunetube_config.h"
#import "tunetube_theme.h"
#import "tunetube_l10n.h"

@interface TuneAboutVC ()
- (void)githubPressed;
- (void)telegramPressed;
- (void)backPressed;
- (void)applyTheme:(NSNotification *)note;
- (void)languageChanged:(NSNotification *)note;
- (void)reloadLocalizedUI;
@end

@implementation TuneAboutVC

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_scroll release];
    [_card release];
    [_info release];
    [_bodyLabel release];
    [_githubButton release];
    [_telegramButton release];
    [_backgroundGradient release];
    [_cardGradient release];
    [_infoGradient release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = TuneThemeBackgroundBottom();
    _backgroundGradient = [[CAGradientLayer layer] retain];
    [view.layer insertSublayer:_backgroundGradient atIndex:0];
    self.view = view;
}

- (void)reloadLocalizedUI {
    self.title = TuneL(@"about");
    self.navigationItem.leftBarButtonItem =
        TuneTubeBarButtonItem(TuneL(@"settings"), self, @selector(backPressed));
    _bodyLabel.text = TuneL(@"about_body");
    [self layoutAbout];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    TuneTubeStyleNavigationBar(self.navigationController.navigationBar);
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyTheme:)
                                                 name:TuneTubeThemeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageChanged:)
                                                 name:TUNETUBE_LANGUAGE_DID_CHANGE_NOTIFICATION
                                               object:nil];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.backgroundColor = [UIColor clearColor];
    _scroll.alwaysBounceVertical = YES;
    _scroll.showsHorizontalScrollIndicator = NO;
    [self.view addSubview:_scroll];

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.layer.cornerRadius = 16.0f;
    _card.layer.masksToBounds = YES;
    _card.layer.borderWidth = 1.0f;
    _card.layer.borderColor = TuneThemeBorder().CGColor;
    _cardGradient = [[CAGradientLayer layer] retain];
    _cardGradient.cornerRadius = 16.0f;
    [_card.layer insertSublayer:_cardGradient atIndex:0];
    [_scroll addSubview:_card];

    UIImageView *avatar = [[[UIImageView alloc] initWithImage:[UIImage imageNamed:@"sqmrak.jpg"]] autorelease];
    avatar.tag = 1;
    avatar.backgroundColor = TuneThemeSurface();
    avatar.contentMode = UIViewContentModeScaleAspectFill;
    avatar.layer.cornerRadius = 14.0f;
    avatar.layer.masksToBounds = YES;
    avatar.layer.borderWidth = 2.0f;
    avatar.layer.borderColor = TuneThemeBorder().CGColor;
    [_card addSubview:avatar];

    UILabel *name = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    name.tag = 2;
    name.backgroundColor = [UIColor clearColor];
    name.textColor = TuneThemePrimaryText();
    name.numberOfLines = 3;
    name.font = [UIFont boldSystemFontOfSize:15.0f];
    name.lineBreakMode = UILineBreakModeWordWrap;
    name.text = [NSString stringWithFormat:@"TuneTube\n%@\nLegacy YouTube Music", TUNETUBE_VERSION];
    [_card addSubview:name];

    _githubButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    [_githubButton setTitle:@"github.com/sqmrak" forState:UIControlStateNormal];
    [_githubButton setTitleColor:TuneThemePrimaryText()
                        forState:UIControlStateNormal];
    _githubButton.titleLabel.font = [UIFont systemFontOfSize:13.0f];
    _githubButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [_githubButton addTarget:self action:@selector(githubPressed)
            forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_githubButton];

    _telegramButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    [_telegramButton setTitle:@"t.me/sqmrakdev" forState:UIControlStateNormal];
    [_telegramButton setTitleColor:TuneThemePrimaryText()
                         forState:UIControlStateNormal];
    _telegramButton.titleLabel.font = [UIFont systemFontOfSize:13.0f];
    _telegramButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [_telegramButton addTarget:self action:@selector(telegramPressed)
              forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_telegramButton];

    _info = [[UIView alloc] initWithFrame:CGRectZero];
    _info.layer.cornerRadius = 16.0f;
    _info.layer.masksToBounds = YES;
    _info.layer.borderWidth = 1.0f;
    _info.layer.borderColor = TuneThemeBorder().CGColor;
    _infoGradient = [[CAGradientLayer layer] retain];
    _infoGradient.cornerRadius = 16.0f;
    [_info.layer insertSublayer:_infoGradient atIndex:0];
    [_scroll addSubview:_info];

    _bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _bodyLabel.backgroundColor = [UIColor clearColor];
    _bodyLabel.textColor = TuneThemeSecondaryText();
    _bodyLabel.font = [UIFont systemFontOfSize:14.0f];
    _bodyLabel.numberOfLines = 0;
    _bodyLabel.lineBreakMode = UILineBreakModeWordWrap;
    [_info addSubview:_bodyLabel];

    [self reloadLocalizedUI];
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = TuneThemeBackgroundBottom();
    TuneTubeStyleNavigationBar(self.navigationController.navigationBar);
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)TuneThemeBackgroundTop().CGColor,
                                  (id)TuneThemeHeader().CGColor,
                                  (id)TuneThemeBackgroundBottom().CGColor, nil];
    _card.layer.borderColor = TuneThemeBorder().CGColor;
    _info.layer.borderColor = TuneThemeBorder().CGColor;
    ((UIImageView *)[_card viewWithTag:1]).layer.borderColor = TuneThemeBorder().CGColor;
    ((UILabel *)[_card viewWithTag:2]).textColor = TuneThemePrimaryText();
    [_githubButton setTitleColor:TuneThemePrimaryText()
                        forState:UIControlStateNormal];
    [_telegramButton setTitleColor:TuneThemePrimaryText()
                         forState:UIControlStateNormal];
    _bodyLabel.textColor = TuneThemeSecondaryText();
    [self layoutAbout];
}

- (void)languageChanged:(NSNotification *)note {
    (void)note;
    [self reloadLocalizedUI];
}

- (void)layoutAbout {
    CGRect bounds = self.view.bounds;
    _scroll.frame = bounds;

    CGFloat contentWidth = MIN(bounds.size.width, 700.0f);
    CGFloat contentX = floorf((bounds.size.width - contentWidth) * 0.5f);
    CGFloat side = bounds.size.width > 700.0f ? 22.0f : 12.0f;
    CGFloat cardWidth = MAX(160.0f, contentWidth - side * 2.0f);

    _card.frame = CGRectMake(contentX + side, 16.0f, cardWidth, 128.0f);
    _cardGradient.frame = _card.bounds;
    _cardGradient.colors = [NSArray arrayWithObjects:
                            (id)TuneThemeSurfaceTop().CGColor,
                            (id)TuneThemeSurfaceBottom().CGColor, nil];
    UIImageView *avatar = (UIImageView *)[_card viewWithTag:1];
    UILabel *name = (UILabel *)[_card viewWithTag:2];
    avatar.frame = CGRectMake(14.0f, 14.0f, 100.0f, 100.0f);
    name.font = [UIFont boldSystemFontOfSize:15.0f];
    name.frame = CGRectMake(128.0f, 16.0f, MAX(40.0f, cardWidth - 140.0f), 52.0f);
    _githubButton.frame = CGRectMake(128.0f, 72.0f, MAX(40.0f, cardWidth - 140.0f), 20.0f);
    _telegramButton.frame = CGRectMake(128.0f, 94.0f, MAX(40.0f, cardWidth - 140.0f), 20.0f);

    CGFloat textWidth = cardWidth - 32.0f;
    CGSize textSize = [_bodyLabel.text sizeWithFont:_bodyLabel.font
                                  constrainedToSize:CGSizeMake(textWidth, 5000.0f)
                                      lineBreakMode:UILineBreakModeWordWrap];
    if (textSize.height < 60.0f) textSize.height = 60.0f;
    CGFloat infoY = CGRectGetMaxY(_card.frame) + 12.0f;
    CGFloat infoHeight = textSize.height + 32.0f;
    _info.frame = CGRectMake(contentX + side, infoY, cardWidth, infoHeight);
    _infoGradient.frame = _info.bounds;
    _infoGradient.colors = [NSArray arrayWithObjects:
                            (id)TuneThemeSurfaceTop().CGColor,
                            (id)TuneThemeSurfaceBottom().CGColor, nil];
    _bodyLabel.frame = CGRectMake(16.0f, 16.0f, textWidth, textSize.height + 2.0f);
    _scroll.contentSize = CGSizeMake(bounds.size.width, CGRectGetMaxY(_info.frame) + 24.0f);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutAbout];
}

- (void)githubPressed {
    NSURL *url = [NSURL URLWithString:@"https://github.com/sqmrak"];
    if ([[UIApplication sharedApplication] canOpenURL:url])
        [[UIApplication sharedApplication] openURL:url];
}

- (void)telegramPressed {
    NSURL *url = [NSURL URLWithString:@"https://t.me/sqmrakdev"];
    if ([[UIApplication sharedApplication] canOpenURL:url])
        [[UIApplication sharedApplication] openURL:url];
}

- (void)backPressed {
    [self.navigationController popViewControllerAnimated:YES];
}

@end
