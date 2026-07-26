#import <UIKit/UIKit.h>

#import "main_vc.h"
#import "ytm_api.h"
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

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int rc = UIApplicationMain(argc, argv, nil, @"AppDelegate");
    [pool release];
    return rc;
}
