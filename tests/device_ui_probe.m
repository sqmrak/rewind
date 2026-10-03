#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "player_vc.h"
#import "settings_vc.h"
#import "rewind_player.h"
#import "rewind_api.h"
#import "rewind_ui.h"
#import "rewind_theme.h"
#import "rewind_account.h"
#include <stdlib.h>
#include <unistd.h>
#include <math.h>
#include <signal.h>
#include <string.h>

static void probe_timeout(int signal_number) {
    (void)signal_number;
    static const char message[] = "FAIL: UI probe exceeded 90 second launch/test deadline\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

/* this executable owns a temporary home before foundation initializes account paths */
static char probe_home[] = "/tmp/rewind-ui-probe.XXXXXX";
static NSString *png_directory;
static unsigned checks, failures;

static void check(BOOL ok, NSString *message) {
    ++checks;
    if (!ok) {
        ++failures;
        fprintf(stderr, "FAIL: %s\n", [message UTF8String]);
    }
}
static BOOL probe_isolated(void) {
    check([NSHomeDirectory() isEqualToString:[NSString stringWithUTF8String:probe_home]], @"temporary Foundation home");
    check([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.sqmrak.rewind.ui-probe"], @"test bundle identifier");
    if (failures) return NO;
    check(!RewindAccountIsSignedIn(), @"isolated account is signed out");
    return failures == 0;
}
static id field(id object, NSString *key) { return [object valueForKey:key]; }
static BOOL near(CGFloat a, CGFloat b) { return fabs(a - b) <= 1.0f; }
static BOOL inside(CGRect outer, CGRect inner) {
    return isfinite(inner.origin.x) && isfinite(inner.origin.y) &&
        isfinite(inner.size.width) && isfinite(inner.size.height) &&
        inner.size.width > 0 && inner.size.height > 0 &&
        CGRectContainsRect(CGRectInset(outer, -1, -1), inner);
}
static void layout_tree(UIView *view) {
    [view setNeedsLayout];
    [view layoutIfNeeded];
    for (UIView *child in view.subviews) layout_tree(child);
}
static void theme(RewindTheme value) {
    /* NSArgumentDomain is volatile on ios 5, so production theme readers never write defaults */
    [[NSUserDefaults standardUserDefaults] setVolatileDomain:
        [NSDictionary dictionaryWithObject:[NSNumber numberWithInteger:value] forKey:@"RewindTheme"]
        forName:NSArgumentDomain];
    [[NSNotificationCenter defaultCenter] postNotificationName:RewindThemeDidChangeNotification object:nil];
    check(RewindCurrentTheme() == value, @"isolated theme override");
}
static void snapshot(UIView *view, NSString *name) {
    if (!png_directory) return;
    CGFloat scale = MIN(1.0f, 384.0f / view.bounds.size.width);
    UIGraphicsBeginImageContextWithOptions(view.bounds.size, YES, scale);
    [view.layer renderInContext:UIGraphicsGetCurrentContext()];
    NSData *data = UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext());
    UIGraphicsEndImageContext();
    NSError *error = nil;
    BOOL saved = [data writeToFile:[png_directory stringByAppendingPathComponent:
        [name stringByAppendingString:@".png"]] options:NSDataWritingAtomic error:&error];
    check(saved, [NSString stringWithFormat:@"PNG %@: %@", name, error]);
}

@interface RewindUIFixturePlayer : RewindPlayer {
    RewindTrack *fixture_track;
    NSArray *fixture_queue;
@public
    NSTimeInterval clock;
}
@end
@implementation RewindUIFixturePlayer
- (id)init {
    self = [super init];
    if (self) {
        fixture_track = [[RewindTrack alloc] initWithVideoID:@"ui-fixture" title:@"A deterministic long player title"
            artist:@"Fixture artist" album:@"Fixture album" thumbnailURL:nil duration:180];
        NSMutableArray *tracks = [NSMutableArray array];
        for (unsigned i = 0; i < 24; ++i) [tracks addObject:fixture_track];
        fixture_queue = [tracks copy];
    }
    return self;
}
- (RewindTrack *)track { return fixture_track; }
- (NSArray *)queue { return fixture_queue; }
- (NSInteger)queueIndex { return 0; }
- (BOOL)isPlaying { return NO; }
- (BOOL)isLoading { return NO; }
- (BOOL)isRepeating { return NO; }
- (BOOL)isShuffling { return NO; }
- (NSTimeInterval)currentTime { return clock; }
- (NSTimeInterval)duration { return 180; }
- (float)progress { return clock / 180.0f; }
- (void)dealloc {
    [fixture_track release];
    [fixture_queue release];
    [super dealloc];
}
@end

@interface RewindUIFixtureAPI : RewindAPI {
@public
    unsigned lyric_calls, related_calls;
    RewindLyricsCompletion lyric_completion;
    RewindShelvesCompletion related_completion;
}
- (void)finishLyrics:(BOOL)success;
- (void)finishRelated:(BOOL)success track:(RewindTrack *)track;
@end
@implementation RewindUIFixtureAPI
- (void)lyricsForTrack:(RewindTrack *)track completion:(RewindLyricsCompletion)completion {
    (void)track;
    check(lyric_completion == nil, @"no duplicate pending lyrics request");
    ++lyric_calls;
    [lyric_completion release];
    lyric_completion = [completion copy];
}
- (void)relatedForTrack:(RewindTrack *)track completion:(RewindShelvesCompletion)completion {
    (void)track;
    check(related_completion == nil, @"no duplicate pending related request");
    ++related_calls;
    [related_completion release];
    related_completion = [completion copy];
}
- (void)finishLyrics:(BOOL)success {
    check(lyric_completion != nil, @"lyrics completion exists");
    if (!lyric_completion) return;
    RewindLyricsCompletion completion = lyric_completion;
    lyric_completion = nil;
    NSMutableArray *lines = [NSMutableArray array];
    for (unsigned i = 0; i < 12; ++i) {
        [lines addObject:[[[RewindLyricLine alloc] initWithText:
            [NSString stringWithFormat:@"Line %u: long words wrap when this panel changes its width", i]
            startMS:1000 + i * 2000] autorelease]];
    }
    RewindLyrics *lyrics = [[[RewindLyrics alloc] initWithLines:lines timed:YES source:@"fixture"] autorelease];
    completion(success ? lyrics : nil, success ? nil : [NSError errorWithDomain:NSURLErrorDomain
        code:NSURLErrorNotConnectedToInternet userInfo:nil]);
    [completion release];
}
- (void)finishRelated:(BOOL)success track:(RewindTrack *)track {
    check(related_completion != nil, @"related completion exists");
    if (!related_completion) return;
    RewindShelvesCompletion completion = related_completion;
    related_completion = nil;
    RewindTrack *other = [[[RewindTrack alloc] initWithVideoID:@"related-fixture" title:@"Related fixture"
        artist:@"Artist" album:@"Album" thumbnailURL:nil duration:60] autorelease];
    RewindShelf *shelf = [[[RewindShelf alloc] initWithTitle:@"Fixture" items:
        [NSArray arrayWithObjects:track, other, other, nil]] autorelease];
    completion(success ? [NSArray arrayWithObject:shelf] : nil, nil,
        success ? nil : [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]);
    [completion release];
}
- (void)dealloc {
    [lyric_completion release];
    [related_completion release];
    [super dealloc];
}
@end

/* these declarations expose existing controller entry points only in this test translation unit */
@interface RewindPlayerVC (RewindUIProbe)
- (void)showTab:(NSInteger)tab;
- (void)hidePanel;
- (void)progressTick:(NSTimer *)timer;
@end

static void scroll_content(UIScrollView *scroll, NSString *context) {
    check(near(scroll.contentSize.width, scroll.bounds.size.width), [context stringByAppendingString:@" content width"]);
    CGFloat bottom = 0;
    for (UIView *child in scroll.subviews) {
        if ([child isKindOfClass:[UIImageView class]]) continue;
        check(inside(CGRectMake(0, 0, scroll.contentSize.width, scroll.contentSize.height), child.frame),
            [context stringByAppendingString:@" content child bounds"]);
        if ([child isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)child;
            CGSize fit = [label sizeThatFits:CGSizeMake(label.bounds.size.width, 100000)];
            check(fit.height <= label.bounds.size.height + 1, [context stringByAppendingString:@" wrapped text height"]);
        }
        if ([child isKindOfClass:[RewindTrackRow class]])
            check(near(child.bounds.size.width, scroll.bounds.size.width), [context stringByAppendingString:@" row width updates"]);
        bottom = MAX(bottom, CGRectGetMaxY(child.frame));
    }
    check(scroll.contentSize.height >= bottom, [context stringByAppendingString:@" content height covers rows"]);
}
static void controls(RewindPlayerVC *vc, NSString *context) {
    NSArray *keys = [NSArray arrayWithObjects:@"shuffleButton", @"previousButton", @"playButton", @"nextButton", @"repeatButton", nil];
    CGFloat last = -1;
    UIView *tabs = field(vc, @"tabBar");
    for (NSString *key in keys) {
        UIView *button = field(vc, key);
        check(inside(vc.view.bounds, button.frame), [NSString stringWithFormat:@"%@ %@ in bounds", context, key]);
        check(CGRectGetMinX(button.frame) >= last, [context stringByAppendingString:@" transport nonoverlap"]);
        check(CGRectGetMaxY(button.frame) <= CGRectGetMinY(tabs.frame) + 1, [context stringByAppendingString:@" transport above tabs"]);
        last = CGRectGetMaxX(button.frame);
    }
}
static void panel_geometry(RewindPlayerVC *vc, NSString *context) {
    UIView *panel = field(vc, @"panel");
    UIView *cover = field(vc, @"artwork");
    UIScrollView *scroll = field(vc, @"panelScroll");
    check(panel && cover && scroll, [context stringByAppendingString:@" production panel views exist"]);
    if (!panel || !cover || !scroll) return;
    check(inside(vc.view.bounds, panel.frame), [context stringByAppendingString:@" panel bounds"]);
    check(!CGRectIntersectsRect(panel.frame, cover.frame), [context stringByAppendingString:@" panel clear of cover"]);
    check(inside(panel.bounds, scroll.frame), [context stringByAppendingString:@" panel scroll bounds"]);
    check(near(scroll.bounds.size.width, panel.bounds.size.width), [context stringByAppendingString:@" panel scroll width"]);
    scroll_content(scroll, context);
    for (NSInteger tag = 410; tag < 413; ++tag) {
        UIView *tab = [panel viewWithTag:tag];
        check(near(tab.bounds.size.width, panel.bounds.size.width / 3), [context stringByAppendingString:@" panel tab width"]);
    }
}
static void clear_style(UIView *view) {
    check(view != nil, @"styled production view exists");
    if (!view) return;
    check(view.layer.borderWidth == 0 && view.layer.shadowOpacity == 0 && view.layer.shadowPath == NULL,
        @"MD3 draws no border or shadow");
}

@interface RewindUIProbeDelegate : NSObject <UIApplicationDelegate> {
    UIWindow *window;
}
- (void)run;
@end
@implementation RewindUIProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    fprintf(stderr, "UI probe: delegate entered\n");
    fflush(stderr);
    window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.rootViewController = [[[UIViewController alloc] init] autorelease];
    [window makeKeyAndVisible];
    [self performSelector:@selector(run) withObject:nil afterDelay:0];
    return YES;
}
- (void)run {
    @try {
        if (!probe_isolated()) exit(2);
        [UIView setAnimationsEnabled:NO];
        RewindUIFixturePlayer *player = [[[RewindUIFixturePlayer alloc] init] autorelease];
        RewindUIFixtureAPI *api = [[[RewindUIFixtureAPI alloc] initWithAPIKey:@"fixture"] autorelease];
        RewindPlayerVC *vc = [[[RewindPlayerVC alloc] initWithPlayer:player api:api] autorelease];
        [window.rootViewController.view addSubview:vc.view];
        CGSize sizes[] = {{320,460}, {480,300}, {768,1004}, {1024,748}, {320,460}, {1024,748}, {480,300}, {768,1004}};
        for (unsigned style = 0; style < 1; ++style) {
            theme(RewindThemeMaterialDesign3);
            for (unsigned s = 0; s < sizeof(sizes)/sizeof(sizes[0]); ++s) {
                [vc hidePanel];
                vc.view.frame = (CGRect){CGPointZero, sizes[s]};
                layout_tree(vc.view);
                NSString *context = [NSString stringWithFormat:@"style%u %.0fx%.0f", style, sizes[s].width, sizes[s].height];
                controls(vc, context);
                {
                    for (NSString *key in [NSArray arrayWithObjects:@"shuffleButton", @"previousButton", @"playButton", @"nextButton", @"repeatButton", @"tabBar", nil])
                        clear_style(field(vc, key));
                }
                for (NSInteger tab = 0; tab < 3; ++tab) {
                    [vc showTab:tab];
                    if (api->lyric_completion) [api finishLyrics:YES];
                    if (api->related_completion) [api finishRelated:YES track:player.track];
                    layout_tree(vc.view);
                    panel_geometry(vc, context);
                    CGSize next = sizes[(s + 1) % (sizeof(sizes)/sizeof(sizes[0]))];
                    vc.view.frame = (CGRect){CGPointZero, next};
                    layout_tree(vc.view);
                    panel_geometry(vc, [context stringByAppendingString:@" same panel rotated"]);
                    vc.view.frame = (CGRect){CGPointZero, sizes[s]};
                    layout_tree(vc.view);
                    panel_geometry(vc, [context stringByAppendingString:@" same panel restored"]);
                    if (s < 4) snapshot(vc.view, [NSString stringWithFormat:@"player-%u-%u-tab%ld", style, s, (long)tab]);
                }
                [vc hidePanel];
                layout_tree(vc.view);
            }
        }
        [vc showTab:1];
        NSTimeInterval times[] = {0, 1, 2.999, 3, 23, 1, 0};
        NSInteger expected[] = {-1, 0, 0, 1, 11, 0, -1};
        for (unsigned i = 0; i < sizeof(times)/sizeof(times[0]); ++i) {
            player->clock = times[i];
            [vc progressTick:nil];
            check([field(vc, @"lastLyricIndex") integerValue] == expected[i], @"timed lyric boundary and backwards seek");
            UIScrollView *scroll = field(vc, @"panelScroll");
            for (NSInteger line = 0; line < 12; ++line) {
                UILabel *label = (UILabel *)[scroll viewWithTag:5000 + line];
                check(label && [label.textColor isEqual:line == expected[i] ? RewindColorText() : RewindColorTextTertiary()],
                    @"exactly the active lyric has highlighted color");
            }
        }
        [vc hidePanel];
        [vc.view removeFromSuperview];
        RewindUIFixtureAPI *errors = [[[RewindUIFixtureAPI alloc] initWithAPIKey:@"fixture"] autorelease];
        RewindPlayerVC *retry = [[[RewindPlayerVC alloc] initWithPlayer:player api:errors] autorelease];
        [window.rootViewController.view addSubview:retry.view];
        retry.view.frame = CGRectMake(0, 0, 320, 460);
        for (NSInteger tab = 1; tab <= 2; ++tab) {
            [retry showTab:tab];
            NSString *loading = tab == 1 ? @"lyricsLoading" : @"relatedLoading";
            NSString *errorKey = tab == 1 ? @"lyricsError" : @"relatedError";
            check([field(retry, loading) boolValue], @"request visibly pending before fixture completion");
            if (tab == 1) [errors finishLyrics:NO]; else [errors finishRelated:NO track:player.track];
            check(![field(retry, loading) boolValue] && field(retry, errorKey), @"failure completion clears loading and preserves error");
            UIScrollView *scroll = field(retry, @"panelScroll");
            UILabel *status = nil;
            for (UIView *child in scroll.subviews) if ([child isKindOfClass:[UILabel class]]) status = (UILabel *)child;
            check([status.text isEqualToString:RewindFriendlyError(field(retry, errorKey))], @"failure text reaches actual panel");
            UIButton *button = (UIButton *)[field(retry, @"panel") viewWithTag:410 + tab];
            [button sendActionsForControlEvents:UIControlEventTouchUpInside];
            check((tab == 1 ? errors->lyric_calls : errors->related_calls) == 2, @"actual tab action retries failed request once");
            [button sendActionsForControlEvents:UIControlEventTouchUpInside];
            check((tab == 1 ? errors->lyric_calls : errors->related_calls) == 2, @"pending retry does not duplicate request");
            if (tab == 1) [errors finishLyrics:YES]; else [errors finishRelated:YES track:player.track];
            check(![field(retry, loading) boolValue] && !field(retry, errorKey), @"successful retry clears error");
            check(tab == 1 ? field(retry, @"lyrics") != nil : [field(retry, @"related") count] == 1,
                @"retry renders lyrics or deduplicated related result");
        }
        [retry hidePanel];
        [retry.view removeFromSuperview];
        RewindSheet *sheet = [[[RewindSheet alloc] initWithFrame:CGRectZero] autorelease];
        NSMutableArray *items = [NSMutableArray array];
        for (unsigned i = 0; i < 20; ++i) [items addObject:[RewindSheetItem itemWithIcon:@"play" title:@"Fixture row" action:nil]];
        [sheet setHeaderTitle:@"Fixture sheet" subtitle:@"Rotation keeps internal content aligned" accessories:nil];
        [sheet setTiles:[items subarrayWithRange:NSMakeRange(0, 3)]];
        [sheet setItems:items];
        UIView *host = [[[UIView alloc] initWithFrame:CGRectMake(0,0,320,460)] autorelease];
        [window.rootViewController.view addSubview:host];
        [sheet showInView:host];
        for (unsigned s = 0; s < sizeof(sizes)/sizeof(sizes[0]); ++s) {
            host.frame = (CGRect){CGPointZero, sizes[s]};
            sheet.frame = host.bounds;
            layout_tree(sheet);
            UIView *panel = field(sheet, @"panel");
            UIScrollView *scroll = field(sheet, @"scroll");
            CGFloat width = MIN(sizes[s].width - RW(16), 560);
            check(near(panel.bounds.size.width, width), @"sheet width follows current host");
            check(near(CGRectGetMidX(panel.frame), sizes[s].width / 2), @"sheet remains centered");
            check(near(CGRectGetMaxY(panel.frame), sizes[s].height + panel.layer.cornerRadius), @"sheet bottom corner overhang only");
            check(inside(panel.bounds, scroll.frame), @"sheet scroll within panel");
            check(near(scroll.bounds.size.width, width), @"sheet internal scroll resizes");
            check(scroll.scrollEnabled, @"long sheet scrolls");
            scroll_content(scroll, @"rotated sheet");
            if (s < 4) snapshot(host, [NSString stringWithFormat:@"sheet-%u", s]);
        }
        [sheet dismiss];
        [host removeFromSuperview];
        RewindSettingsVC *settings = [[[RewindSettingsVC alloc] init] autorelease];
        [window.rootViewController.view addSubview:settings.view];
        for (unsigned s = 0; s < 4; ++s) {
            settings.view.frame = (CGRect){CGPointZero, sizes[s]};
            layout_tree(settings.view);
            UITableView *table = field(settings, @"table");
            for (NSInteger section = 0; section < [settings numberOfSectionsInTableView:table]; ++section) {
                UIView *header = [settings tableView:table viewForHeaderInSection:section];
                /* keep the same header alive across a second resize, like UITableView during rotation */
                for (unsigned h = 0; h < 2; ++h) {
                    header.frame = CGRectMake(0, 0, h ? sizes[(s + 1) % 4].width : table.bounds.size.width, 34);
                    layout_tree(header);
                    check(header.subviews.count > 0, @"settings header has text child");
                    if (!header.subviews.count) continue;
                    id child = [header.subviews objectAtIndex:0];
                    check([child isKindOfClass:[UILabel class]], @"settings header child is a label");
                    if (![child isKindOfClass:[UILabel class]]) continue;
                    UILabel *label = child;
                    check(label.text.length && label.textAlignment == NSTextAlignmentCenter, @"settings section title is centered text");
                    check(near(CGRectGetMidX(label.frame), header.bounds.size.width / 2), @"settings title centers across entire header");
                    check(near(label.frame.size.width, header.bounds.size.width - 32), @"settings header uses full available text width");
                }
            }
            snapshot(settings.view, [NSString stringWithFormat:@"settings-%u", s]);
        }
        [settings.view removeFromSuperview];
    } @catch (NSException *exception) {
        check(NO, [NSString stringWithFormat:@"unexpected exception: %@", exception]);
    }
    fprintf(stderr, "UI probe: %u checks, %u failures; home=%s\n", checks, failures, probe_home);
    exit(failures ? 1 : 0);
}
- (void)dealloc { [window release]; [super dealloc]; }
@end

int main(int argc, char **argv) {
    if (argc > 2 || (argc == 2 && argv[1][0] != '/')) {
        fprintf(stderr, "usage: RewindUIProbe [absolute PNG output directory]\n");
        return 2;
    }
    const char *png_path = argc == 2 ? argv[1] : NULL;
    if (!mkdtemp(probe_home) || setenv("CFFIXED_USER_HOME", probe_home, 1)) {
        perror("isolated probe home");
        return 2;
    }
    signal(SIGALRM, probe_timeout);
    alarm(90);
    char log_path[sizeof(probe_home) + 16];
    snprintf(log_path, sizeof(log_path), "%s/run.log", probe_home);
    if (!freopen(log_path, "w", stderr)) {
        perror("probe log");
        return 2;
    }
    setvbuf(stderr, NULL, _IONBF, 0);
    fprintf(stderr, "UI probe: starting; home=%s\n", probe_home);
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    png_directory = png_path ? [[NSString alloc] initWithUTF8String:png_path] :
        [[[NSString stringWithUTF8String:probe_home] stringByAppendingPathComponent:@"pngs"] retain];
    fprintf(stderr, "UI probe: PNG directory=%s\n", [png_directory UTF8String]);
    NSLog(@"UI probe: log=%s PNGs=%@", log_path, png_directory);
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:png_directory
        withIntermediateDirectories:YES attributes:nil error:&error]) {
        fprintf(stderr, "PNG directory: %s\n", [[error description] UTF8String]);
        return 2;
    }
    int result = UIApplicationMain(1, argv, nil, NSStringFromClass([RewindUIProbeDelegate class]));
    [pool drain];
    return result;
}
