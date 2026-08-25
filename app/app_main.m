#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <unistd.h>

#import "main_vc.h"
#import "tunetube_api.h"
#import "tunetube_theme.h"

@interface UIViewController (TuneTubeRotation)
@end

@implementation UIViewController (TuneTubeRotation)

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad)
        return orientation != UIInterfaceOrientationPortraitUpsideDown;
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

@interface AppDelegate : UIResponder <UIApplicationDelegate> {
    UIWindow *_window;
}
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)launchOptions;
    [application beginReceivingRemoteControlEvents];
    _window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    _window.backgroundColor = TuneThemeBackgroundBottom();
    MainVC *main = [[[MainVC alloc] init] autorelease];
    UINavigationController *navigation =
        [[[UINavigationController alloc] initWithRootViewController:main] autorelease];
    _window.rootViewController = navigation;
    [_window makeKeyAndVisible];
    return YES;
}

- (void)dealloc {
    [_window release];
    [super dealloc];
}

@end

/* enable senkotlsfix for old ios network stacks */
static void TuneTubeEnableTLSFixForBundle(void) {
    NSString *path = @"/var/mobile/Library/Preferences/com.senko.senkotlsfix.plist";
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    [prefs setObject:[NSNumber numberWithBool:YES]
              forKey:@"enabled-com.sqmrak.tunetube"];
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

    CFPreferencesSetAppValue(CFSTR("enabled-com.sqmrak.tunetube"),
                             kCFBooleanTrue, CFSTR("com.senko.senkotlsfix"));
    CFPreferencesAppSynchronize(CFSTR("com.senko.senkotlsfix"));
}

static void TuneTubeInstallTLSFix(void) {
    TuneTubeEnableTLSFixForBundle();
    if (access("/usr/lib/senkotlsfix.dylib", F_OK) == 0)
        (void)dlopen("/usr/lib/senkotlsfix.dylib", RTLD_NOW | RTLD_GLOBAL);
    else if (access("/Library/MobileSubstrate/DynamicLibraries/senkotlsfix.dylib", F_OK) == 0)
        (void)dlopen("/Library/MobileSubstrate/DynamicLibraries/senkotlsfix.dylib",
                     RTLD_NOW | RTLD_GLOBAL);
}

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    TuneTubeInstallTLSFix();
    int rc = UIApplicationMain(argc, argv, nil, @"AppDelegate");
    [pool release];
    return rc;
}
