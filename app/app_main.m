#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <unistd.h>
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ucontext.h>

#import "main_vc.h"
#import "settings_vc.h"
#import "native_shell.h"
#import "rewind_chrome.h"
#import "rewind_api.h"
#import "rewind_theme.h"
#import "rewind_config.h"
#import "rewind_l10n.h"
#import "rewind_player.h"

@interface UIViewController (RewindRotation)
@end

@implementation UIViewController (RewindRotation)

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    /* ios 5/6 never call -supportedInterfaceOrientations, so the ipad's extra
       upside-down orientation has to be allowed here too, not just below */
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad)
        return YES;
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations {
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad)
        return UIInterfaceOrientationMaskAll;
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

@end

static UIWindow *RewindAppWindow;
/* one player and one api for the whole run: rebuilding the interface for another theme keeps the music going */
static RewindPlayer *RewindAppPlayer;
static RewindAPI *RewindAppAPI;

/* the stock-control shell for the system theme, the custom main screen for the others */
static UIViewController *RewindMakeRootController(void) {
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic) return RewindNativeRootController(RewindAppPlayer, RewindAppAPI);
    MainVC *main = [[[MainVC alloc] init] autorelease];
    [main adoptPlayer:RewindAppPlayer];
    return [[[UINavigationController alloc] initWithRootViewController:main] autorelease];
}

@interface AppDelegate : UIResponder <UIApplicationDelegate> {
    UIWindow *_window;
    BOOL _playing;
}
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)launchOptions;
    /* the stock shared cache has no disk space on ios 5, thumbnails would load again on every launch */
    [NSURLCache setSharedURLCache:[[[NSURLCache alloc] initWithMemoryCapacity:2 * 1024 * 1024
                                                                 diskCapacity:32 * 1024 * 1024
                                                                     diskPath:@"rewind-url-cache"] autorelease]];
    [application beginReceivingRemoteControlEvents];
    _window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    _window.backgroundColor = RewindColorBackground();
    RewindAppWindow = _window;
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] objectForKey:REWIND_API_KEY_DEFAULTS_KEY];
    RewindAppAPI = [[RewindAPI alloc] initWithAPIKey:apiKey.length ? apiKey : RewindDefaultAPIKey];
    RewindAppPlayer = [[RewindPlayer alloc] init];
    _window.rootViewController = RewindMakeRootController();
    [_window makeKeyAndVisible];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackChanged:)
                                                 name:RewindPlayerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screenSettingChanged:)
                                                 name:REWIND_KEEP_SCREEN_AWAKE_DID_CHANGE_NOTIFICATION object:nil];
    return YES;
}

- (void)updateIdleTimer {
    UIApplication *application = [UIApplication sharedApplication];
    application.idleTimerDisabled = _playing && application.applicationState == UIApplicationStateActive &&
        [[NSUserDefaults standardUserDefaults] boolForKey:REWIND_KEEP_SCREEN_AWAKE_DEFAULTS_KEY];
}

- (void)playbackChanged:(NSNotification *)note {
    _playing = [(RewindPlayer *)note.object isPlaying];
    [self updateIdleTimer];
}

- (void)screenSettingChanged:(NSNotification *)note {
    (void)note;
    [self updateIdleTimer];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application;
    [self updateIdleTimer];
}

/* ios 5 through 7.0 deliver lock screen and headset keys to the first responder and then up the chain; no
   screen holds the focus, so the delegate at the end of the chain takes them for every theme and screen */
- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    if (event.type != UIEventTypeRemoteControl) return;
    switch (event.subtype) {
        case UIEventSubtypeRemoteControlPlay: case UIEventSubtypeRemoteControlPause:
        case UIEventSubtypeRemoteControlTogglePlayPause: [RewindAppPlayer toggle]; break;
        case UIEventSubtypeRemoteControlNextTrack: [RewindAppPlayer nextTrack]; break;
        case UIEventSubtypeRemoteControlPreviousTrack: [RewindAppPlayer previousTrack]; break;
        default: break;
    }
}

- (void)applicationWillResignActive:(UIApplication *)application {
    application.idleTimerDisabled = NO;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [_window release];
    [super dealloc];
}

@end

static BOOL RewindReloading;

/* uikit may call unretained delegates during pending animations after a theme change */
static void RewindDetachDelegates(UIView *view) {
    if ([view isKindOfClass:[UITableView class]]) ((UITableView *)view).dataSource = nil;
    if ([view isKindOfClass:[UIScrollView class]]) ((UIScrollView *)view).delegate = nil;
    if ([view isKindOfClass:[UITextField class]]) ((UITextField *)view).delegate = nil;
    if ([view isKindOfClass:[UISearchBar class]]) ((UISearchBar *)view).delegate = nil;
    for (UIView *child in view.subviews) RewindDetachDelegates(child);
}

static void RewindDetachController(UIViewController *controller) {
    if ([controller isKindOfClass:[UINavigationController class]])
        for (UIViewController *inner in [(UINavigationController *)controller viewControllers]) RewindDetachController(inner);
    if ([controller isKindOfClass:[UITabBarController class]])
        for (UIViewController *inner in [(UITabBarController *)controller viewControllers]) RewindDetachController(inner);
    if ([controller isKindOfClass:[RewindChromeTabsController class]])
        for (UIViewController *inner in [(RewindChromeTabsController *)controller controllers]) RewindDetachController(inner);
    if (controller.presentedViewController) RewindDetachController(controller.presentedViewController);
    if ([controller isViewLoaded]) RewindDetachDelegates(controller.view);
}

void RewindReloadInterface(NSString *messageKey, void (^change)(void)) {
    UIWindow *window = RewindAppWindow;
    if (!window || !window.rootViewController || RewindReloading) {
        change();
        return;
    }
    RewindReloading = YES;
    UIView *shade = [[[UIView alloc] initWithFrame:window.bounds] autorelease];
    shade.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    /* before ios 8 window coordinates stay portrait, so rotate the overlay with the interface */
    if (![UIScreen instancesRespondToSelector:NSSelectorFromString(@"coordinateSpace")]) {
        UIInterfaceOrientation orientation = [UIApplication sharedApplication].statusBarOrientation;
        CGFloat angle = orientation == UIInterfaceOrientationLandscapeLeft ? (CGFloat)-M_PI_2
            : orientation == UIInterfaceOrientationLandscapeRight ? (CGFloat)M_PI_2
            : orientation == UIInterfaceOrientationPortraitUpsideDown ? (CGFloat)M_PI : 0.0f;
        if (angle != 0.0f) {
            CGRect bounds = window.bounds;
            BOOL sideways = UIInterfaceOrientationIsLandscape(orientation);
            shade.autoresizingMask = UIViewAutoresizingNone;
            shade.bounds = CGRectMake(0.0f, 0.0f, sideways ? bounds.size.height : bounds.size.width,
                                      sideways ? bounds.size.width : bounds.size.height);
            shade.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
            shade.transform = CGAffineTransformMakeRotation(angle);
        }
    }
    shade.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.0f];
    UIActivityIndicatorView *spinner = [[[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge] autorelease];
    spinner.center = CGPointMake(shade.bounds.size.width * 0.5f, shade.bounds.size.height * 0.5f - 18.0f);
    spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
        UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [spinner startAnimating];
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectMake(0, shade.bounds.size.height * 0.5f + 12.0f,
                                                                 shade.bounds.size.width, 24.0f)] autorelease];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleBottomMargin;
    label.backgroundColor = [UIColor clearColor];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont boldSystemFontOfSize:16.0f];
    spinner.alpha = 0.0f;
    label.alpha = 0.0f;
    [shade addSubview:spinner];
    [shade addSubview:label];
    [window addSubview:shade];
    /* the settings page stays open across the rebuild of the custom shell, where a language or theme is chosen */
    BOOL inSettings = NO;
    UIViewController *oldRoot = window.rootViewController;
    if ([oldRoot isKindOfClass:[UINavigationController class]])
        for (UIViewController *controller in [(UINavigationController *)oldRoot viewControllers])
            if ([controller isKindOfClass:[RewindSettingsVC class]]) inSettings = YES;
    void (^change_copy)(void) = [[change copy] autorelease];
    [UIView animateWithDuration:0.25 animations:^{
        shade.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.62f];
    } completion:^(BOOL finished) {
        (void)finished;
        change_copy();
        /* read after the change, so the message comes in the language just chosen */
        label.text = RewindL(messageKey);
        spinner.alpha = 1.0f;
        label.alpha = 1.0f;
        /* a pass of the run loop lets the dimmed screen and the spinner draw before the rebuild blocks it */
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *root = RewindMakeRootController();
            if (inSettings && [root isKindOfClass:[UINavigationController class]])
                [(UINavigationController *)root pushViewController:[[[RewindSettingsVC alloc] init] autorelease] animated:NO];
            RewindDetachController(window.rootViewController);
            window.backgroundColor = RewindColorBackground();
            window.rootViewController = root;
            [window bringSubviewToFront:shade];
            [UIView animateWithDuration:0.3 delay:0.6 options:0 animations:^{
                shade.alpha = 0.0f;
            } completion:^(BOOL done) {
                (void)done;
                [shade removeFromSuperview];
                RewindReloading = NO;
            }];
        });
    }];
}

/* enable senkotlsfix for old ios network stacks */
static void RewindEnableTLSFixForBundle(void) {
    NSString *path = @"/var/mobile/Library/Preferences/com.senko.senkotlsfix.plist";
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    [prefs setObject:[NSNumber numberWithBool:YES]
              forKey:@"enabled-com.sqmrak.rewind"];
    if (![prefs objectForKey:@"tls13"])
        [prefs setObject:[NSNumber numberWithBool:YES] forKey:@"tls13"];
    if (![prefs objectForKey:@"drainGuard"])
        [prefs setObject:[NSNumber numberWithBool:YES] forKey:@"drainGuard"];
    if (![prefs objectForKey:@"systemFallback"])
        [prefs setObject:[NSNumber numberWithBool:YES] forKey:@"systemFallback"];

    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:prefs
                                                               format:NSPropertyListXMLFormat_v1_0
                                                              options:0
                                                                error:NULL];
    if ([xml length]) [xml writeToFile:path atomically:YES];

    CFPreferencesSetAppValue(CFSTR("enabled-com.sqmrak.rewind"),
                             kCFBooleanTrue, CFSTR("com.senko.senkotlsfix"));
    CFPreferencesAppSynchronize(CFSTR("com.senko.senkotlsfix"));
}

static void RewindInstallTLSFix(void) {
    RewindEnableTLSFixForBundle();
    if (access("/usr/lib/senkotlsfix.dylib", F_OK) == 0)
        (void)dlopen("/usr/lib/senkotlsfix.dylib", RTLD_NOW | RTLD_GLOBAL);
    else if (access("/Library/MobileSubstrate/DynamicLibraries/senkotlsfix.dylib", F_OK) == 0)
        (void)dlopen("/Library/MobileSubstrate/DynamicLibraries/senkotlsfix.dylib",
                     RTLD_NOW | RTLD_GLOBAL);
}

/* the rename from tunetube moved the bundle id, so the old library and settings
   sit in another defaults domain that unsandboxed /Applications installs can read */
static void RewindMigrateTuneTubeDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *doneKey = @"RewindMigratedTuneTubeDefaults";
    if ([defaults boolForKey:doneKey]) return;
    NSDictionary *keys = [NSDictionary dictionaryWithObjectsAndKeys:
                          REWIND_API_KEY_DEFAULTS_KEY, @"TuneTubeAPIKey",
                          REWIND_LIBRARY_DEFAULTS_KEY, @"TuneTubeFavorites",
                          REWIND_HISTORY_DEFAULTS_KEY, @"TuneTubeRecentTracks",
                          REWIND_PLAYLISTS_DEFAULTS_KEY, @"TuneTubePlaylists",
                          REWIND_BACKGROUND_AUDIO_DEFAULTS_KEY, @"TuneTubeBackgroundAudio",
                          REWIND_LANGUAGE_DEFAULTS_KEY, @"TuneTubeLanguage", nil];
    for (NSString *oldKey in keys) {
        NSString *newKey = [keys objectForKey:oldKey];
        if ([defaults objectForKey:newKey]) continue;
        CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)oldKey,
                                                            CFSTR("com.sqmrak.tunetube"));
        if (!value) continue;
        [defaults setObject:(id)value forKey:newKey];
        CFRelease(value);
    }
    [defaults setBool:YES forKey:doneKey];
    [defaults synchronize];
}

/* log the exception before the default handler aborts the stripped release build */
static void RewindLogUncaughtException(NSException *exception) {
    RewindDebugLog(@"uncaught exception %@: %@ userInfo=%@\n%@",
                   exception.name, exception.reason, exception.userInfo,
                   [exception.callStackSymbols componentsJoinedByString:@"\n"]);
}

/* log the fault address and registers before the default crash handler */
static char RewindCrashLogPath[1024];

static void RewindLogSignal(int signalNumber, siginfo_t *info, void *context) {
    char line[512];
    void *frames[24];
    const void *pc = NULL, *lr = NULL;
    ucontext_t *uc = (ucontext_t *)context;
#if defined(__arm__) || defined(__arm64__)
    if (uc && uc->uc_mcontext) {
        pc = (const void *)(uintptr_t)uc->uc_mcontext->__ss.__pc;
        lr = (const void *)(uintptr_t)uc->uc_mcontext->__ss.__lr;
    }
#endif
    int fd = open(RewindCrashLogPath, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        Dl_info where;
        memset(&where, 0, sizeof(where));
        if (lr) dladdr(lr, &where);
        int length = snprintf(line, sizeof(line), "crash signal %d fault %p pc %p lr %p in %s (%s)\n", signalNumber,
                              info ? info->si_addr : NULL, pc, lr, where.dli_fname ? where.dli_fname : "?",
                              where.dli_sname ? where.dli_sname : "?");
        if (length > 0) write(fd, line, (size_t)length);
        int count = backtrace(frames, 24);
        int index;
        for (index = 0; index < count; ++index) {
            Dl_info frame;
            memset(&frame, 0, sizeof(frame));
            dladdr(frames[index], &frame);
            length = snprintf(line, sizeof(line), "  %p %s (%s)\n", frames[index],
                              frame.dli_fname ? frame.dli_fname : "?", frame.dli_sname ? frame.dli_sname : "?");
            if (length > 0) write(fd, line, (size_t)length);
        }
        close(fd);
    }
    signal(signalNumber, SIG_DFL);
}

static void RewindInstallCrashLog(void) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Rewind/debug.log"];
    strlcpy(RewindCrashLogPath, [path fileSystemRepresentation], sizeof(RewindCrashLogPath));
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = RewindLogSignal;
    action.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&action.sa_mask);
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGBUS, &action, NULL);
    sigaction(SIGILL, &action, NULL);
}

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSSetUncaughtExceptionHandler(&RewindLogUncaughtException);
    RewindInstallCrashLog();
    RewindInstallTLSFix();
    RewindMigrateTuneTubeDefaults();
    int rc = UIApplicationMain(argc, argv, nil, @"AppDelegate");
    [pool release];
    return rc;
}
