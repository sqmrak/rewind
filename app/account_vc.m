#import "account_vc.h"

/* ios 5 sdk uses UIKit names for these text enums */
#if __IPHONE_OS_VERSION_MAX_ALLOWED < 60000
#define NSTextAlignmentCenter UITextAlignmentCenter
#define NSLineBreakByWordWrapping UILineBreakModeWordWrap
#endif

#import "rewind_qr.h"
#import "rewind_account.h"
#import "rewind_theme.h"
#import "rewind_l10n.h"
#import "rewind_api.h"

UIImage *RewindQRImage(NSString *text, CGFloat side) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    rewind_qr_t *qr = calloc(1, sizeof *qr);
    if (!qr) return nil;
    if (!data || rewind_qr_encode((const unsigned char *)data.bytes, data.length,
                                  REWIND_QR_ECC_M, -1, qr) != REWIND_QR_OK) {
        free(qr);
        return nil;
    }
    int modules = qr->size + 8;
    CGFloat scale = [UIScreen mainScreen].scale;
    /* whole pixels per module keep edges crisp enough for old phone cameras */
    CGFloat unit = floorf(side * scale / modules) / scale;
    if (unit <= 0.0f) unit = 1.0f / scale;
    CGSize size = CGSizeMake(unit * modules, unit * modules);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0.0f);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context, [UIColor whiteColor].CGColor);
    CGContextFillRect(context, CGRectMake(0.0f, 0.0f, size.width, size.height));
    CGContextSetFillColorWithColor(context, [UIColor blackColor].CGColor);
    for (int y = 0; y < qr->size; ++y)
        for (int x = 0; x < qr->size; ++x)
            if (rewind_qr_module(qr, x, y))
                CGContextFillRect(context, CGRectMake((x + 4) * unit, (y + 4) * unit, unit, unit));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    free(qr);
    return image;
}

static UIButton *RewindLoginButton(id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:14.0f];
    button.layer.cornerRadius = 10.0f;
    button.layer.borderWidth = 1.0f;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

static UILabel *RewindLoginLabel(UIFont *font) {
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.font = font;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    return label;
}

@interface RewindAccountLoginVC ()
- (void)requestCode;
- (void)schedulePoll;
- (void)stopPolling;
@end

@implementation RewindAccountLoginVC

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_pollTimer invalidate];
    [_pollTimer release];
    [_scroll release];
    [_card release];
    [_qr release];
    [_steps release];
    [_code release];
    [_status release];
    [_copyButton release];
    [_openButton release];
    [_retryButton release];
    [_spinner release];
    [_backgroundGradient release];
    [_deviceCode release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = RewindColorBackground();
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RewindL(@"account_sign_in");
    self.navigationItem.leftBarButtonItem =
        RewindBarButtonItem(RewindL(@"back"), self, @selector(backPressed));
    _backgroundGradient = [[CAGradientLayer layer] retain];
    [self.view.layer insertSublayer:_backgroundGradient atIndex:0];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.layer.cornerRadius = 16.0f;
    _card.layer.borderWidth = 1.0f;
    [_scroll addSubview:_card];

    _qr = [[UIImageView alloc] initWithFrame:CGRectZero];
    _qr.contentMode = UIViewContentModeCenter;
    _qr.backgroundColor = [UIColor whiteColor];
    _qr.layer.cornerRadius = 8.0f;
    _qr.layer.masksToBounds = YES;
    [_card addSubview:_qr];

    _spinner = [[UIActivityIndicatorView alloc]
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    _spinner.hidesWhenStopped = YES;
    [_card addSubview:_spinner];

    _steps = [RewindLoginLabel([UIFont systemFontOfSize:14.0f]) retain];
    [_card addSubview:_steps];

    _code = [RewindLoginLabel([UIFont fontWithName:@"Courier-Bold" size:30.0f]
                               ?: [UIFont boldSystemFontOfSize:30.0f]) retain];
    _code.adjustsFontSizeToFitWidth = YES;
    _code.numberOfLines = 1;
    [_card addSubview:_code];

    _status = [RewindLoginLabel([UIFont systemFontOfSize:13.0f]) retain];
    [_card addSubview:_status];

    _copyButton = [RewindLoginButton(self, @selector(copyPressed)) retain];
    [_card addSubview:_copyButton];
    _openButton = [RewindLoginButton(self, @selector(openPressed)) retain];
    [_card addSubview:_openButton];
    _retryButton = [RewindLoginButton(self, @selector(retryPressed)) retain];
    [_card addSubview:_retryButton];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyTheme:)
                                                 name:RewindThemeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(languageChanged:)
                                                 name:REWIND_LANGUAGE_DID_CHANGE_NOTIFICATION object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appBecameActive:)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];
    [self applyTheme:nil];
    [self requestCode];
}

/* the title, back button and the three button titles below are the only static
   chrome here; the code, steps and status text reflect live polling state and
   stay in whatever language they were already fetched/built in */
- (void)languageChanged:(NSNotification *)note {
    (void)note;
    self.title = RewindL(@"account_sign_in");
    self.navigationItem.leftBarButtonItem =
        RewindBarButtonItem(RewindL(@"back"), self, @selector(backPressed));
    [self applyTheme:nil];
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = RewindColorBackground();
    RewindStyleNavigationBar(self.navigationController.navigationBar);
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)RewindColorBackground().CGColor,
                                  (id)RewindColorBackground().CGColor, nil];
    _card.backgroundColor = RewindColorSurface();
    _card.layer.borderColor = RewindColorDivider().CGColor;
    _steps.textColor = RewindColorTextSecondary();
    _code.textColor = RewindColorText();
    _status.textColor = RewindColorTextTertiary();
    for (UIButton *button in [NSArray arrayWithObjects:_copyButton, _openButton, _retryButton, nil]) {
        BOOL primary = button == _retryButton;
        button.backgroundColor = primary ? RewindColorAccentFill() : RewindColorSurface();
        button.layer.borderColor = RewindColorDivider().CGColor;
        [button setTitleColor:primary ? RewindColorOnAccent() : RewindColorText()
                     forState:UIControlStateNormal];
    }
    [_copyButton setTitle:RewindL(@"account_copy_code") forState:UIControlStateNormal];
    [_openButton setTitle:RewindL(@"account_open_page") forState:UIControlStateNormal];
    [_retryButton setTitle:RewindL(@"account_new_code") forState:UIControlStateNormal];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    _backgroundGradient.frame = bounds;
    _scroll.frame = bounds;
    CGFloat width = MIN(bounds.size.width - 24.0f, 420.0f);
    CGFloat inner = width - 32.0f;
    CGFloat y = 16.0f;
    CGFloat qrSide = MIN(inner, 220.0f);
    _qr.frame = CGRectMake(floorf((width - qrSide) * 0.5f), y, qrSide, qrSide);
    _spinner.center = _qr.center;
    y += qrSide + 14.0f;
    CGSize steps = RewindTextSize(_steps.text, _steps.font, inner);
    _steps.frame = CGRectMake(16.0f, y, inner, ceilf(steps.height));
    y += ceilf(steps.height) + 8.0f;
    _code.frame = CGRectMake(16.0f, y, inner, 40.0f);
    y += 48.0f;
    CGFloat half = floorf((inner - 10.0f) * 0.5f);
    _copyButton.frame = CGRectMake(16.0f, y, half, 40.0f);
    _openButton.frame = CGRectMake(16.0f + half + 10.0f, y, half, 40.0f);
    y += 50.0f;
    _retryButton.frame = CGRectMake(16.0f, y, inner, 40.0f);
    if (!_retryButton.hidden) y += 50.0f;
    CGSize status = RewindTextSize(_status.text, _status.font, inner);
    _status.frame = CGRectMake(16.0f, y, inner, ceilf(status.height));
    y += ceilf(status.height) + 16.0f;
    _card.frame = CGRectMake(floorf((bounds.size.width - width) * 0.5f), 14.0f, width, y);
    _scroll.contentSize = CGSizeMake(bounds.size.width, CGRectGetMaxY(_card.frame) + 20.0f);
}

- (void)setStatus:(NSString *)text {
    _status.text = text;
    [self.view setNeedsLayout];
}

- (void)showCode:(RewindDeviceCode *)code {
    [_deviceCode release];
    _deviceCode = [code retain];
    NSString *page = [[code.verificationURL stringByReplacingOccurrencesOfString:@"https://" withString:@""]
                      stringByReplacingOccurrencesOfString:@"www." withString:@""];
    _steps.text = [[NSString stringWithFormat:RewindL(@"account_steps"), page]
        stringByAppendingString:@"\nSign in with the intended Google account. Select the YouTube channel if Google offers a choice. Rewind uses the channel authorized by this sign-in."];
    _code.text = code.userCode;
    _qr.image = RewindQRImage(code.verificationURL, _qr.bounds.size.width > 0 ? _qr.bounds.size.width : 220.0f);
    _copyButton.enabled = YES;
    _openButton.enabled = YES;
    _retryButton.hidden = YES;
    [_spinner stopAnimating];
    [self setStatus:RewindL(@"account_waiting")];
}

- (void)showFailure:(NSString *)message {
    [self stopPolling];
    [_spinner stopAnimating];
    _retryButton.hidden = NO;
    [self setStatus:message];
}

- (void)requestCode {
    [self stopPolling];
    NSUInteger attempt = ++_attempt;
    _pollInFlight = NO;
    _qr.image = nil;
    _code.text = @"";
    _steps.text = RewindL(@"account_intro");
    _copyButton.enabled = NO;
    _openButton.enabled = NO;
    _retryButton.hidden = YES;
    [_spinner startAnimating];
    [self setStatus:RewindL(@"account_getting_code")];
    RewindAccountRequestDeviceCode(^(RewindDeviceCode *code, NSError *error) {
        if (attempt != _attempt) return;
        if (error || !code) {
            [self showFailure:RewindFriendlyError(error) ?: RewindL(@"account_failed")];
            return;
        }
        _pollInterval = code.interval;
        [self showCode:code];
        _polling = YES;
        [self schedulePoll];
    });
}

- (void)schedulePoll {
    [_pollTimer invalidate];
    [_pollTimer release];
    _pollTimer = nil;
    if (!_polling) return;
    _pollTimer = [[NSTimer scheduledTimerWithTimeInterval:_pollInterval target:self
                                                 selector:@selector(pollFired:)
                                                 userInfo:nil repeats:NO] retain];
}

- (void)stopPolling {
    ++_attempt;
    _deviceCode.cancelled = YES;
    _polling = NO;
    [_pollTimer invalidate];
    [_pollTimer release];
    _pollTimer = nil;
}

- (void)pollFired:(NSTimer *)timer {
    (void)timer;
    [_pollTimer release];
    _pollTimer = nil;
    if (!_polling || !_deviceCode || _pollInFlight) return;
    NSUInteger attempt = _attempt;
    _pollInFlight = YES;
    RewindAccountPollDeviceCode(_deviceCode, ^(RewindDevicePollStatus status, NSError *error) {
        if (attempt == _attempt) _pollInFlight = NO;
        if (attempt != _attempt || !_polling) return;
        switch (status) {
            case RewindDevicePollPending:
                [self schedulePoll];
                break;
            case RewindDevicePollSlowDown:
                /* rfc 8628 asks clients to back off by five seconds on slow_down */
                _pollInterval += 5.0;
                [self schedulePoll];
                break;
            case RewindDevicePollGranted:
                [self stopPolling];
                [self setStatus:RewindL(@"account_signed_in")];
                UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:RewindL(@"account_signed_in")
                    message:error ? [error localizedDescription] :
                        [NSString stringWithFormat:@"YouTube channel: %@\nTo use another channel, sign in again. Select it if Google offers a channel choice. If no choice is offered, set your default YouTube channel before signing in again.",
                            RewindAccountName() ?: RewindL(@"account_signed_in")]
                    delegate:self cancelButtonTitle:RewindL(@"done") otherButtonTitles:
                        RewindLanguageIsRussian() ? @"Выбор канала" : @"Channel help", nil] autorelease];
                alert.tag = 940;
                [alert show];
                break;
            case RewindDevicePollDenied:
                [self showFailure:RewindL(@"account_denied")];
                break;
            case RewindDevicePollExpired:
                [self showFailure:RewindL(@"account_expired")];
                break;
            case RewindDevicePollFailed:
                /* a dropped connection is worth another try while the code is still valid */
                if ([error.domain isEqualToString:NSURLErrorDomain] &&
                    [_deviceCode.expiresAt timeIntervalSinceNow] > _pollInterval) {
                    [self setStatus:RewindL(@"account_waiting_offline")];
                    [self schedulePoll];
                } else {
                    [self showFailure:RewindFriendlyError(error) ?: RewindL(@"account_failed")];
                }
                break;
        }
    });
}

/* timers do not fire in the background; check right away when the user comes back from the browser */
- (void)appBecameActive:(NSNotification *)note {
    (void)note;
    if (!_polling || !_deviceCode) return;
    [_pollTimer invalidate];
    [_pollTimer release];
    _pollTimer = nil;
    [self pollFired:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    /* the timer retains this controller, so it has to stop before the pop can free it */
    if (self.isMovingFromParentViewController || self.isBeingDismissed ||
        self.navigationController.isBeingDismissed ||
        ![self.navigationController.viewControllers containsObject:self])
        [self stopPolling];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == 940 && buttonIndex == alertView.firstOtherButtonIndex)
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:
            @"https://support.google.com/youtube/answer/6019090"]];
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)copyPressed {
    if (!_deviceCode.userCode.length) return;
    [UIPasteboard generalPasteboard].string = _deviceCode.userCode;
    [self setStatus:RewindL(@"account_code_copied")];
}

- (void)openPressed {
    NSURL *url = [NSURL URLWithString:_deviceCode.verificationURL];
    if (url) [[UIApplication sharedApplication] openURL:url];
}

- (void)retryPressed {
    [self requestCode];
}

- (void)backPressed {
    [self stopPolling];
    [self.navigationController popViewControllerAnimated:YES];
}

@end
