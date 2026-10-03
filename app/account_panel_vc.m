#import "account_panel_vc.h"

#import <QuartzCore/QuartzCore.h>

#import "about_vc.h"
#import "account_vc.h"
#import "rewind_account.h"
#import "rewind_api.h"
#import "rewind_image_cache.h"
#import "rewind_l10n.h"
#import "rewind_player.h"
#import "rewind_theme.h"
#import "rewind_ui.h"
#import "settings_vc.h"

@implementation RewindAccountPanelVC

- (id)initWithAPI:(RewindAPI *)api player:(RewindPlayer *)player {
    self = [super init];
    if (!self) return nil;
    _api = [api retain];
    _player = [player retain];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _table.delegate = nil;
    _table.dataSource = nil;
    [_table release];
    [_profile release];
    [_avatar release];
    [_name release];
    [_email release];
    [_manage release];
    [_api release];
    [_player release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = RewindColorCanvas();
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    RewindStyleNavigationBar(self.navigationController.navigationBar);
    self.title = RewindL(@"account_youtube");
    self.navigationItem.leftBarButtonItem = RewindIconBarItem(@"close", self, @selector(closePressed));
    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.backgroundColor = RewindColorCanvas();
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.delegate = self;
    _table.dataSource = self;
    [self.view addSubview:_table];

    _profile = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, RW(156.0f))];
    _profile.backgroundColor = RewindColorBackground();
    _avatar = [[UIImageView alloc] initWithFrame:CGRectZero];
    _avatar.contentMode = UIViewContentModeScaleAspectFill;
    _avatar.clipsToBounds = YES;
    _avatar.layer.cornerRadius = RW(24.0f);
    [_profile addSubview:_avatar];
    _name = [[UILabel alloc] initWithFrame:CGRectZero];
    _name.backgroundColor = [UIColor clearColor];
    _name.textColor = RewindColorText();
    _name.font = RewindFont(16.0f, RewindWeightMedium);
    [_profile addSubview:_name];
    _email = [[UILabel alloc] initWithFrame:CGRectZero];
    _email.backgroundColor = [UIColor clearColor];
    _email.textColor = RewindColorTextSecondary();
    _email.font = RewindFont(14.0f, RewindWeightRegular);
    [_profile addSubview:_email];
    _manage = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _manage.titleLabel.font = RewindFont(14.0f, RewindWeightMedium);
    [_manage setTitle:RewindL(@"account_manage") forState:UIControlStateNormal];
    [_manage setTitleColor:RewindColorLink() forState:UIControlStateNormal];
    _manage.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [_manage addTarget:self action:@selector(managePressed) forControlEvents:UIControlEventTouchUpInside];
    [_profile addSubview:_manage];
    _table.tableHeaderView = _profile;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(accountChanged:)
                                                 name:RewindAccountDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyTheme:)
                                                 name:RewindThemeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(languageChanged:)
                                                 name:REWIND_LANGUAGE_DID_CHANGE_NOTIFICATION object:nil];
    [self accountChanged:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (RewindAccountIsSignedIn()) {
        NSUInteger request = ++_profileRequest;
        RewindAccountRefreshProfile(^(NSError *error) {
            if (request == _profileRequest && error && RewindAccountIsSignedIn()) {
                NSLog(@"rewind: account panel profile failed: %@", error);
                _email.text = [error localizedDescription];
            }
        });
    }
}

- (void)languageChanged:(NSNotification *)note {
    (void)note;
    self.title = RewindL(@"account_youtube");
    [_manage setTitle:RewindL(@"account_manage") forState:UIControlStateNormal];
    [self accountChanged:nil];
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    self.view.backgroundColor = RewindColorCanvas();
    _table.backgroundColor = RewindColorCanvas();
    _profile.backgroundColor = RewindColorBackground();
    _name.textColor = RewindColorText();
    _name.font = RewindFont(16.0f, RewindWeightMedium);
    _email.textColor = RewindColorTextSecondary();
    _email.font = RewindFont(14.0f, RewindWeightRegular);
    [_manage setTitleColor:RewindColorLink() forState:UIControlStateNormal];
    _manage.titleLabel.font = RewindFont(14.0f, RewindWeightMedium);
    [self accountChanged:nil];
    RewindStyleNavigationBar(self.navigationController.navigationBar);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    if (fabs(_profile.bounds.size.width - width) > 0.5f) {
        _profile.frame = CGRectMake(0, 0, width, RW(156.0f));
        _table.tableHeaderView = _profile;
    }
    _avatar.frame = CGRectMake(RW(20.0f), RW(20.0f), RW(48.0f), RW(48.0f));
    _name.frame = CGRectMake(RW(82.0f), RW(20.0f), width - RW(118.0f), RW(24.0f));
    _email.frame = CGRectMake(RW(82.0f), RW(44.0f), width - RW(118.0f), RW(21.0f));
    _manage.frame = CGRectMake(RW(82.0f), RW(80.0f), width - RW(110.0f), RW(37.0f));
}

- (void)accountChanged:(NSNotification *)note {
    (void)note;
    ++_profileRequest;
    BOOL signedIn = RewindAccountIsSignedIn();
    _name.text = signedIn ? (RewindAccountName() ?: RewindL(@"account_signed_in"))
                          : RewindL(@"account_signed_out");
    _email.text = signedIn ? RewindAccountEmail() : RewindL(@"account_sign_in_detail");
    _manage.hidden = !signedIn;
    _avatar.image = RewindIcon(@"avatar", RW(36.0f), RewindColorText());
    NSString *photo = RewindAccountPhotoURL();
    if (signedIn && photo.length) {
        NSString *expected = [photo copy];
        RewindLoadImageSized(expected, 96.0f, ^(UIImage *image) {
            if (image && RewindAccountIsSignedIn() && [RewindAccountPhotoURL() isEqualToString:expected]) _avatar.image = image;
        });
        [expected release];
    }
    [_table reloadData];
}

/* the panel is pushed onto a stack as often as it is presented, and a dismiss does nothing to a pushed screen */
- (void)closePressed {
    if (self.navigationController.viewControllers.count > 1)
        [self.navigationController popViewControllerAnimated:YES];
    else
        [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)managePressed {
    NSURL *url = [NSURL URLWithString:@"https://myaccount.google.com/"];
    if (url) [[UIApplication sharedApplication] openURL:url];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return RewindAccountIsSignedIn() ? 4 : 3;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return RW(54.0f);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"account-action";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse] autorelease];
    cell.backgroundColor = RewindColorBackground();
    cell.backgroundView = nil;
    cell.selectedBackgroundView = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    cell.selectedBackgroundView.backgroundColor = RewindColorSurfaceHigh();
    cell.textLabel.textColor = RewindColorText();
    cell.textLabel.font = RewindFont(15.0f, RewindWeightMedium);
    /* liked music, playlists and recent already live under the library tab;
       repeating them here just duplicated that tab's own buttons */
    BOOL signedIn = RewindAccountIsSignedIn();
    NSArray *titles = signedIn
        ? [NSArray arrayWithObjects:RewindL(@"account_switch"), RewindL(@"settings"),
                                    RewindL(@"about"), RewindL(@"account_sign_out"), nil]
        : [NSArray arrayWithObjects:RewindL(@"account_sign_in_google"), RewindL(@"settings"),
                                    RewindL(@"about"), nil];
    NSArray *icons = signedIn
        ? [NSArray arrayWithObjects:@"switch-account", @"settings", @"info", @"logout", nil]
        : [NSArray arrayWithObjects:@"login", @"settings", @"info", nil];
    NSUInteger index = (NSUInteger)indexPath.row;
    cell.textLabel.text = [titles objectAtIndex:index];
    cell.imageView.image = RewindIcon([icons objectAtIndex:index], RW(23.0f), RewindColorText());
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    BOOL signedIn = RewindAccountIsSignedIn();
    NSUInteger index = (NSUInteger)indexPath.row;
    if (index == 0) {
        RewindAccountLoginVC *login = [[[RewindAccountLoginVC alloc] init] autorelease];
        [self.navigationController pushViewController:login animated:YES];
        return;
    }
    if (signedIn && index == 3) {
        UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:RewindL(@"account_sign_out")
                                                         message:nil delegate:self
                                               cancelButtonTitle:RewindL(@"cancel")
                                               otherButtonTitles:RewindL(@"account_sign_out"), nil] autorelease];
        [alert show];
        return;
    }
    if (index == 1) {
        RewindSettingsVC *settings = [[[RewindSettingsVC alloc] init] autorelease];
        [self.navigationController pushViewController:settings animated:YES];
    } else if (index == 2) {
        RewindAboutVC *about = [[[RewindAboutVC alloc] init] autorelease];
        [self.navigationController pushViewController:about animated:YES];
    }
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == alertView.cancelButtonIndex) return;
    RewindAccountSignOut();
}

@end
