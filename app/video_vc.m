#import "video_vc.h"
#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>
#import "rewind_api.h"
#import "rewind_ui.h"
#import "rewind_theme.h"
#import "rewind_l10n.h"

static char rewind_video_status_context;
static char rewind_video_rate_context;

@interface RewindVideoVC ()
- (void)updateState;
- (void)showError:(NSError *)error;
- (void)stopLoadTimer;
- (void)releaseVideoViews;
@end

@implementation RewindVideoVC

- (id)initWithURL:(NSURL *)url userAgent:(NSString *)userAgent {
    self = [super init];
    if (!self) return nil;
    NSDictionary *options = userAgent.length ? [NSDictionary dictionaryWithObject:
        [NSDictionary dictionaryWithObject:userAgent forKey:@"User-Agent"]
        forKey:@"AVURLAssetHTTPHeaderFieldsKey"] : nil;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:options];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    _player = [[AVPlayer alloc] initWithPlayerItem:item];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:&rewind_video_status_context];
    _observing = YES;
    [_player addObserver:self forKeyPath:@"rate" options:NSKeyValueObservingOptionNew
                context:&rewind_video_rate_context];
    _observingRate = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ended:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(failed:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationInactive:)
                                                 name:UIApplicationWillResignActiveNotification object:nil];
    return self;
}

- (void)stopLoadTimer {
    [_loadTimer invalidate];
    [_loadTimer release]; _loadTimer = nil;
}

- (void)releaseVideoViews {
    _video.player = nil;
    [_video removeFromSuperlayer];
    [_video release]; _video = nil;
    [_close removeFromSuperview];
    [_close release]; _close = nil;
    [_play removeFromSuperview];
    [_play release]; _play = nil;
    [_spinner stopAnimating];
    [_spinner removeFromSuperview];
    [_spinner release]; _spinner = nil;
    [_errorLabel removeFromSuperview];
    [_errorLabel release]; _errorLabel = nil;
}

- (void)dealloc {
    [self stopLoadTimer];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_observing) [_player.currentItem removeObserver:self forKeyPath:@"status"];
    if (_observingRate) [_player removeObserver:self forKeyPath:@"rate"];
    [_player pause];
    [self releaseVideoViews];
    [_player release];
    [_error release];
    [super dealloc];
}

- (void)loadView {
    self.view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    self.view.backgroundColor = [UIColor blackColor];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _video = [[AVPlayerLayer playerLayerWithPlayer:_player] retain];
    _video.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.view.layer addSublayer:_video];
    _close = [[RewindIconButton buttonWithIcon:@"close" points:RW(26.0f)] retain];
    [_close addTarget:self action:@selector(closePressed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_close];
    _play = [[RewindIconButton buttonWithIcon:@"play" points:RW(30.0f)] retain];
    [_play addTarget:self action:@selector(playPressed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_play];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];
    _errorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _errorLabel.backgroundColor = [UIColor clearColor];
    _errorLabel.textColor = RewindColorText();
    _errorLabel.font = RewindFont(16.0f, RewindWeightRegular);
    _errorLabel.numberOfLines = 0;
    _errorLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_errorLabel];
    [self updateState];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _video.frame = self.view.bounds;
    [CATransaction commit];
    CGFloat size = RW(48.0f);
    _close.frame = CGRectMake(RW(8.0f), RewindStatusBarInset() + RW(8.0f), size, size);
    _play.frame = CGRectMake((self.view.bounds.size.width - size) * 0.5f,
        self.view.bounds.size.height - size - RW(12.0f) - RewindBottomSafeInset(), size, size);
    _spinner.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
    CGFloat messageWidth = MAX(0, self.view.bounds.size.width - RW(48.0f));
    CGFloat messageHeight = RewindTextSize(_errorLabel.text, _errorLabel.font, messageWidth).height;
    _errorLabel.frame = CGRectMake(RW(24.0f), (self.view.bounds.size.height - messageHeight) * 0.5f,
                                   messageWidth, messageHeight);
    for (UIView *button in [NSArray arrayWithObjects:_close, _play, nil]) {
        button.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55f];
        button.layer.cornerRadius = size * 0.5f;
    }
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return RewindIsPad() || orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (BOOL)shouldAutorotate { return YES; }

- (NSUInteger)supportedInterfaceOrientations {
    return RewindIsPad() ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _visible = YES;
    _wantsPlayback = !_failed;
    AVPlayerItemStatus status = _player.currentItem.status;
    if (status == AVPlayerItemStatusFailed) [self showError:_player.currentItem.error];
    else if (!_failed && status == AVPlayerItemStatusUnknown && !_loadTimer)
        _loadTimer = [[NSTimer scheduledTimerWithTimeInterval:20 target:self selector:@selector(loadTimedOut:)
                                                   userInfo:nil repeats:NO] retain];
    else if (!_failed && status == AVPlayerItemStatusReadyToPlay) [_player play];
    [self updateState];
}

- (void)viewWillDisappear:(BOOL)animated {
    _visible = NO;
    _wantsPlayback = NO;
    [self stopLoadTimer];
    [_player pause];
    [super viewWillDisappear:animated];
}

- (void)viewDidUnload {
    /* ios 5 can unload a hidden controller's view and later call viewDidLoad again */
    _visible = NO;
    _wantsPlayback = NO;
    [self stopLoadTimer];
    [_player pause];
    [self releaseVideoViews];
    [super viewDidUnload];
}

- (void)applicationInactive:(NSNotification *)note {
    (void)note;
    _wantsPlayback = NO;
    [_player pause];
    [self updateState];
}

- (void)updateState {
    BOOL loading = !_failed && _player.currentItem.status == AVPlayerItemStatusUnknown;
    if (!loading) [self stopLoadTimer];
    /* late AVPlayer callbacks must not reload a dismissed view on ios 5 */
    if (![self isViewLoaded]) return;
    _play.hidden = loading;
    _play.enabled = !_failed;
    if (loading && _visible) [_spinner startAnimating];
    else [_spinner stopAnimating];
    _errorLabel.hidden = !_failed;
    _errorLabel.text = _failed ? (_error ? RewindFriendlyError(_error) : RewindL(@"err_playback")) : nil;
    [_play setIconName:_player.rate > 0 ? @"pause" : @"play"];
    [self.view setNeedsLayout];
}

- (void)showError:(NSError *)error {
    if (!_failed) {
        _failed = YES;
        _error = [error retain];
        RewindDebugLog(@"music video failed: %@", error ?: RewindL(@"err_playback"));
    }
    _wantsPlayback = NO;
    [self stopLoadTimer];
    [_player pause];
    [self updateState];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context == &rewind_video_rate_context && object == _player) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateState]; });
        return;
    }
    if (context != &rewind_video_status_context || object != _player.currentItem) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_player.currentItem.status == AVPlayerItemStatusFailed) [self showError:_player.currentItem.error];
        else {
            if (!_failed && _player.currentItem.status == AVPlayerItemStatusReadyToPlay &&
                _visible && _wantsPlayback) [_player play];
            [self updateState];
        }
    });
}

- (void)ended:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{ _ended = YES; [self updateState]; });
}

- (void)failed:(NSNotification *)note {
    NSError *error = [note.userInfo objectForKey:AVPlayerItemFailedToPlayToEndTimeErrorKey];
    dispatch_async(dispatch_get_main_queue(), ^{ [self showError:error]; });
}

- (void)playPressed {
    if (_failed || !_visible || _player.currentItem.status != AVPlayerItemStatusReadyToPlay) return;
    _wantsPlayback = _player.rate <= 0;
    if (!_wantsPlayback) [_player pause];
    else {
        if (_ended) { [_player seekToTime:kCMTimeZero]; _ended = NO; }
        [_player play];
    }
    [self updateState];
}

- (void)loadTimedOut:(NSTimer *)timer {
    if (timer != _loadTimer || !_visible || _failed) return;
    if (_player.currentItem.status != AVPlayerItemStatusUnknown) {
        [self updateState];
        return;
    }
    [self stopLoadTimer];
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut
        userInfo:[NSDictionary dictionaryWithObject:RewindL(@"err_playback") forKey:NSLocalizedDescriptionKey]];
    [self showError:error];
}

- (void)closePressed {
    _wantsPlayback = NO;
    [self stopLoadTimer];
    [_player pause];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
