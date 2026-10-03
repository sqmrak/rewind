#import "settings_vc.h"

/* ios 5 sdk uses UIKit names for text alignment */
#if __IPHONE_OS_VERSION_MAX_ALLOWED < 60000
#define NSTextAlignmentCenter UITextAlignmentCenter
#endif

#import <QuartzCore/QuartzCore.h>
#include <objc/message.h>

#import "account_vc.h"
#import "rewind_account.h"
#import "rewind_image_cache.h"
#import "rewind_config.h"
#import "rewind_theme.h"
#import "rewind_chrome.h"
#import "rewind_l10n.h"
#import "rewind_api.h"
#import "rewind_ui.h"
#import "main_vc.h"

/* rows of one section share a single plate: only the first row rounds its top corners and only
   the last row its bottom ones, the rows between are square and split by a hairline */
@interface RewindSettingsChromeView : UIView {
    BOOL _selected;
    UIRectCorner _corners;
    BOOL _divider;
    UIView *_line;
}
- (id)initWithSelected:(BOOL)selected corners:(UIRectCorner)corners divider:(BOOL)divider;
@end

@implementation RewindSettingsChromeView

- (id)initWithSelected:(BOOL)selected corners:(UIRectCorner)corners divider:(BOOL)divider {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _selected = selected;
    _corners = corners;
    _divider = divider;
    _line = [[UIView alloc] initWithFrame:CGRectZero];
    _line.userInteractionEnabled = NO;
    [self addSubview:_line];
    return self;
}

- (void)dealloc {
    [_line release];
    [super dealloc];
}

- (void)refreshChrome {
    _line.hidden = !_divider || _selected;
    _line.backgroundColor = RewindColorDivider();
    _line.frame = CGRectMake(RW(16.0f), self.bounds.size.height - 0.5f, MAX(0.0f, self.bounds.size.width - RW(16.0f)), 0.5f);
    self.layer.cornerRadius = 0.0f;
    self.backgroundColor = _selected ? RewindColorSurfaceHigh() : RewindColorSurface();
    self.layer.borderWidth = 0.0f;
    if (self.bounds.size.width > 0.0f && self.bounds.size.height > 0.0f) {
        CAShapeLayer *mask = [CAShapeLayer layer];
        mask.path = [UIBezierPath bezierPathWithRoundedRect:self.bounds byRoundingCorners:_corners
                                                cornerRadii:CGSizeMake(RW(16.0f), RW(16.0f))].CGPath;
        self.layer.mask = mask;
    }
}

/* a table view cell resizes its backgroundView by setting bounds directly,
   which does not always schedule a fresh layoutSubviews pass before the next
   draw; refreshing here as well keeps the gradient from being stuck at
   whatever size the view had the first time it was laid out */
- (void)setBounds:(CGRect)bounds {
    [super setBounds:bounds];
    [self refreshChrome];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self refreshChrome];
}

@end

@implementation RewindSettingsVC

- (void)reloadLocalizedUI {
    self.title = RewindL(@"settings");
    self.navigationItem.leftBarButtonItem =
        RewindBarButtonItem(RewindL(@"done"), self, @selector(donePressed));
    [_table reloadData];
}

- (void)applyTheme:(NSNotification *)note {
    (void)note;
    BOOL classic = RewindCurrentTheme() == RewindThemeSkeuomorphic;
    self.view.backgroundColor = classic ? RewindChromeGroupedBackground() : RewindColorCanvas();
    _backgroundGradient.hidden = classic;
    [self.view setNeedsLayout];
    RewindStyleNavigationBar(self.navigationController.navigationBar);
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)RewindColorBackground().CGColor,
                                  (id)RewindColorBackground().CGColor, nil];
    [self reloadLocalizedUI];
}

- (void)languageChanged:(NSNotification *)note {
    (void)note;
    [self reloadLocalizedUI];
}

- (void)backgroundAudioChanged:(UISwitch *)toggle {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:toggle.on forKey:REWIND_BACKGROUND_AUDIO_DEFAULTS_KEY];
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter]
     postNotificationName:REWIND_BACKGROUND_AUDIO_DID_CHANGE_NOTIFICATION object:nil];
}

- (void)keepScreenAwakeChanged:(UISwitch *)toggle {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:toggle.on forKey:REWIND_KEEP_SCREEN_AWAKE_DEFAULTS_KEY];
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter]
     postNotificationName:REWIND_KEEP_SCREEN_AWAKE_DID_CHANGE_NOTIFICATION object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _table.delegate = nil;
    _table.dataSource = nil;
    [_table release];
    [_backgroundGradient release];
    [super dealloc];
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    view.backgroundColor = RewindColorCanvas();
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RewindL(@"settings");
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyTheme:)
                                                 name:RewindThemeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageChanged:)
                                                 name:REWIND_LANGUAGE_DID_CHANGE_NOTIFICATION
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(accountChanged:)
                                                 name:RewindAccountDidChangeNotification
                                               object:nil];
    self.navigationItem.leftBarButtonItem =
        RewindBarButtonItem(RewindL(@"done"), self, @selector(donePressed));

    _backgroundGradient = [[CAGradientLayer layer] retain];
    _backgroundGradient.colors = [NSArray arrayWithObjects:
                                  (id)RewindColorBackground().CGColor,
                                  (id)RewindColorBackground().CGColor, nil];
    [self.view.layer insertSublayer:(CAGradientLayer *)_backgroundGradient atIndex:0];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _table.dataSource = self;
    _table.delegate = self;
    _table.backgroundColor = [UIColor clearColor];
    _table.backgroundView = nil;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.sectionHeaderHeight = 34.0f;
    _table.sectionFooterHeight = 8.0f;
    [self.view addSubview:_table];
    /* the "account" header is laid out ourselves below, not by uikit's own
       scroll view inset guess, so that guess must not also push it down;
       both properties postdate the armv7 sdk, so the runtime reaches them */
    SEL autoInsets = @selector(setAutomaticallyAdjustsScrollViewInsets:);
    if ([self respondsToSelector:autoInsets])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, autoInsets, NO);
    SEL insetBehavior = @selector(setContentInsetAdjustmentBehavior:);
    if ([_table respondsToSelector:insetBehavior])
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(_table, insetBehavior, 2 /* .never */);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _backgroundGradient.frame = self.view.bounds;
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic) {
        /* the opaque red bar ends above this view, so nothing sits under it to inset past */
        CGFloat margin = RewindChromeGroupedMargin();
        _table.frame = CGRectInset(self.view.bounds, margin, 0.0f);
        _table.contentInset = UIEdgeInsetsZero;
        _table.scrollIndicatorInsets = UIEdgeInsetsZero;
        return;
    }
    _table.frame = self.view.bounds;
    /* the bar sits over the table's own coordinate space; without this the first
       section header ("account") is drawn half hidden under it. converting the bar's
       own bounds through the view hierarchy reads a stale frame while the push
       transition is still animating, so this uses the bar's own height directly
       instead, the same way the bar's own content already positions below it */
    CGFloat topInset = RewindStatusBarInset() + self.navigationController.navigationBar.frame.size.height;
    _table.contentInset = UIEdgeInsetsMake(topInset, 0.0f, 0.0f, 0.0f);
    _table.scrollIndicatorInsets = _table.contentInset;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyTheme:nil];
    [_table reloadData];
}

- (void)donePressed {
    if ([self.navigationController.viewControllers count] > 1)
        [self.navigationController popViewControllerAnimated:YES];
    else
        [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 5;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return 3; // account
    if (section == 1) return 2;
    if (section == 2) return 1; // theme
    if (section == 3) return 1; // language
    return 3; // api
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return RewindCurrentTheme() == RewindThemeSkeuomorphic ? 44.0f : 34.0f;
}

- (NSString *)titleForSection:(NSInteger)section {
    if (section == 0) return RewindL(@"section_account");
    if (section == 1) return RewindL(@"section_playback");
    if (section == 2) return RewindL(@"section_appearance");
    if (section == 3) return RewindL(@"section_language");
    return RewindL(@"section_search");
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic)
        return RewindChromeGroupedHeader([self titleForSection:section], tableView.bounds.size.width);
    UIView *header = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 34.0f)] autorelease];
    header.backgroundColor = [UIColor clearColor];

    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.textColor = RewindColorHeading();
    label.font = RewindFont(11.0f, RewindWeightMedium);
    label.textAlignment = NSTextAlignmentCenter;
    label.text = [self titleForSection:section];
    label.frame = CGRectMake(16.0f, 12.0f, MAX(0, header.bounds.size.width - 32.0f), 18.0f);
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:label];
    return header;
}

- (UIView *)darkCellBackground:(BOOL)selected atIndexPath:(NSIndexPath *)indexPath {
    NSInteger count = [self tableView:_table numberOfRowsInSection:indexPath.section];
    BOOL first = indexPath.row == 0, last = indexPath.row == count - 1;
    UIRectCorner corners = (first ? UIRectCornerTopLeft | UIRectCornerTopRight : 0) |
                           (last ? UIRectCornerBottomLeft | UIRectCornerBottomRight : 0);
    return [[[RewindSettingsChromeView alloc] initWithSelected:selected corners:corners divider:!last] autorelease];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
          cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"RewindSettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell)
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                       reuseIdentifier:cellID] autorelease];

    BOOL classic = RewindCurrentTheme() == RewindThemeSkeuomorphic;
    if (classic) {
        NSInteger rows = [self tableView:tableView numberOfRowsInSection:indexPath.section];
        RewindChromeStyleGroupedCell(cell, indexPath.row == 0, indexPath.row == rows - 1);
    } else {
        cell.backgroundColor = [UIColor clearColor];
        cell.backgroundView = [self darkCellBackground:NO atIndexPath:indexPath];
        cell.selectedBackgroundView = [self darkCellBackground:YES atIndexPath:indexPath];
        cell.textLabel.textColor = RewindColorText();
        cell.textLabel.font = RewindFont(14.0f, RewindWeightMedium);
        cell.detailTextLabel.textColor = RewindColorTextSecondary();
        cell.detailTextLabel.font = RewindFont(12.0f, RewindWeightRegular);
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.imageView.image = nil;

    if (indexPath.section == 0) {
        if (indexPath.row > 0) {
            BOOL setup = indexPath.row == 1;
            cell.textLabel.text = setup
                ? (RewindLanguageIsRussian() ? @"Настройка YouTube OAuth" : @"YouTube OAuth setup")
                : (RewindLanguageIsRussian() ? @"Сбросить YouTube OAuth" : @"Reset YouTube OAuth");
            /* the setup row is a plain entry point; only the reset row says which client is in use */
            cell.detailTextLabel.text = setup ? nil
                : (RewindAccountOAuthClientID().length ? RewindL(@"custom") : RewindL(@"built_in"));
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        if (RewindAccountIsSignedIn()) {
            cell.textLabel.text = RewindAccountName() ?: RewindL(@"account_signed_in");
            cell.detailTextLabel.text = RewindAccountEmail() ?: RewindL(@"account_youtube");
            cell.imageView.image = RewindIcon(@"avatar", RW(32.0f),
                                              classic ? RewindChromeGroupedCaptionColor() : RewindColorText());
            cell.imageView.layer.cornerRadius = 8.0f;
            cell.imageView.layer.masksToBounds = YES;
            NSString *photo = [[RewindAccountPhotoURL() copy] autorelease];
            if (photo.length) {
                RewindLoadImage(photo, ^(UIImage *image) {
                    /* the cell may have been reused for another row while the photo loaded */
                    NSIndexPath *visiblePath = [_table indexPathForCell:cell];
                    if (image && visiblePath && visiblePath.section == 0 && visiblePath.row == 0 &&
                        RewindAccountIsSignedIn() && [photo isEqualToString:RewindAccountPhotoURL()]) {
                        UIGraphicsBeginImageContextWithOptions(CGSizeMake(RW(32.0f), RW(32.0f)), NO, 0);
                        [image drawInRect:CGRectMake(0, 0, RW(32.0f), RW(32.0f))];
                        cell.imageView.image = UIGraphicsGetImageFromCurrentImageContext();
                        UIGraphicsEndImageContext();
                        [cell setNeedsLayout];
                    }
                });
            }
        } else {
            cell.textLabel.text = RewindL(@"account_sign_in_google");
            cell.detailTextLabel.text = RewindL(@"account_sign_in_detail");
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1) {
        BOOL backgroundAudio = indexPath.row == 0;
        cell.textLabel.text = RewindL(backgroundAudio ? @"background_audio" : @"keep_screen_awake");
        cell.detailTextLabel.text = nil;
        /* both answer -on, which is all the change handlers read */
        UISwitch *toggle = RewindCurrentTheme() == RewindThemeSkeuomorphic
            ? (UISwitch *)[[[RewindChromeSwitch alloc] initWithFrame:CGRectZero] autorelease]
            : [[[UISwitch alloc] initWithFrame:CGRectZero] autorelease];
        id value = [[NSUserDefaults standardUserDefaults] objectForKey:
                    backgroundAudio ? REWIND_BACKGROUND_AUDIO_DEFAULTS_KEY : REWIND_KEEP_SCREEN_AWAKE_DEFAULTS_KEY];
        toggle.on = value ? [value boolValue] : backgroundAudio;
        if ([toggle isKindOfClass:[UISwitch class]]) toggle.onTintColor = RewindColorLink();
        [toggle addTarget:self action:backgroundAudio ? @selector(backgroundAudioChanged:) : @selector(keepScreenAwakeChanged:)
         forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if (indexPath.section == 2) {
        cell.textLabel.text = RewindL(@"theme");
        cell.detailTextLabel.text = RewindL(RewindCurrentTheme() == RewindThemeSkeuomorphic ? @"theme_skeuomorphic"
                                                                                      : @"theme_material");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 3) {
        cell.textLabel.text = RewindL(@"language");
        cell.detailTextLabel.text = RewindLanguageIsRussian() ? RewindL(@"russian") : RewindL(@"english");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSString *customKey = [[NSUserDefaults standardUserDefaults]
                                objectForKey:REWIND_API_KEY_DEFAULTS_KEY];
        if (indexPath.row == 0) {
            cell.textLabel.text = RewindL(@"api_key");
            cell.detailTextLabel.text = customKey.length ? RewindL(@"custom") : RewindL(@"built_in");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = RewindL(@"reset_api_key");
            cell.detailTextLabel.text = customKey.length ? RewindL(@"use_builtin_key")
                                                         : RewindL(@"already_default");
            cell.accessoryType = customKey.length
                ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            NSString *potURL = [[NSUserDefaults standardUserDefaults]
                                objectForKey:REWIND_POT_PROVIDER_DEFAULTS_KEY];
            cell.textLabel.text = RewindL(@"pot_provider");
            cell.detailTextLabel.text = potURL.length ? potURL : RewindL(@"pot_provider_off");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    }
    return cell;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic)
        return RewindChromeGroupedFooter(section == 4 ? RewindL(@"footer_tagline") : nil, tableView.bounds.size.width);
    if (section != 4) return nil;
    UILabel *footer = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    footer.backgroundColor = [UIColor clearColor];
    footer.textColor = RewindColorTextTertiary();
    footer.font = [UIFont systemFontOfSize:11.0f];
    footer.numberOfLines = 0;
    footer.textAlignment = NSTextAlignmentCenter;
    footer.text = RewindL(@"footer_tagline");
    return footer;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic)
        return RewindChromeGroupedFooterHeight(section == 4 ? RewindL(@"footer_tagline") : nil, tableView.bounds.size.width);
    return section == 4 ? 38.0f : 8.0f;
}

- (void)showLanguagePicker {
    UIActionSheet *sheet = [[[UIActionSheet alloc]
                             initWithTitle:RewindL(@"language")
                             delegate:self
                             cancelButtonTitle:RewindL(@"cancel")
                             destructiveButtonTitle:nil
                             otherButtonTitles:RewindL(@"english"), RewindL(@"russian"), nil]
                            autorelease];
    sheet.tag = 900;
    [sheet showInView:self.view.window ?: self.view];
}

- (void)showThemePicker {
    UIActionSheet *sheet = [[[UIActionSheet alloc]
                             initWithTitle:RewindL(@"theme")
                             delegate:self
                             cancelButtonTitle:RewindL(@"cancel")
                             destructiveButtonTitle:nil
                             otherButtonTitles:RewindL(@"theme_skeuomorphic"), RewindL(@"theme_material"), nil]
                            autorelease];
    sheet.tag = 902;
    [sheet showInView:self.view.window ?: self.view];
}

- (void)showAccountSheet {
    UIActionSheet *sheet = [[[UIActionSheet alloc]
                             initWithTitle:RewindAccountEmail() ?: RewindAccountName()
                             delegate:self
                             cancelButtonTitle:RewindL(@"cancel")
                             destructiveButtonTitle:RewindL(@"account_sign_out")
                             otherButtonTitles:nil] autorelease];
    sheet.tag = 901;
    [sheet showInView:self.view.window ?: self.view];
}

- (void)accountChanged:(NSNotification *)note {
    (void)note;
    [_table reloadData];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (actionSheet.tag == 901 && buttonIndex == actionSheet.destructiveButtonIndex) RewindAccountSignOut();
}

/* language and theme rebuild every screen, this one included, so they wait for the sheet to finish
   dismissing: uikit still messages its delegate during the animation and this page is that delegate */
- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex {
    if (buttonIndex == actionSheet.cancelButtonIndex) return;
    if (actionSheet.tag == 900) {
        NSString *code = buttonIndex == 0 ? @"en" : (buttonIndex == 1 ? @"ru" : nil);
        if (!code || [code isEqualToString:RewindLanguageCode()]) return;
        actionSheet.delegate = nil;
        RewindReloadInterface(@"reload_language", ^{ RewindSetLanguageCode(code); });
    } else if (actionSheet.tag == 902) {
        RewindTheme theme = buttonIndex == 0 ? RewindThemeSkeuomorphic : RewindThemeMaterialDesign3;
        if (buttonIndex > 1 || theme == RewindCurrentTheme()) return;
        actionSheet.delegate = nil;
        RewindReloadInterface(@"reload_theme", ^{ RewindSetTheme(theme); });
    }
}

- (void)showAPIKeyEditor {
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:RewindL(@"api_key")
                                                     message:RewindL(@"api_key_hint")
                                                    delegate:self
                                           cancelButtonTitle:RewindL(@"cancel")
                                           otherButtonTitles:RewindL(@"save"), nil] autorelease];
    alert.tag = 920;
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    UITextField *field = [alert textFieldAtIndex:0];
    field.text = [[NSUserDefaults standardUserDefaults]
                  objectForKey:REWIND_API_KEY_DEFAULTS_KEY];
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.keyboardType = UIKeyboardTypeASCIICapable;
    [alert show];
}

- (void)showPOTProviderEditor {
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:RewindL(@"pot_provider")
                                                     message:RewindL(@"pot_provider_hint")
                                                    delegate:self
                                           cancelButtonTitle:RewindL(@"cancel")
                                           otherButtonTitles:RewindL(@"save"), nil] autorelease];
    alert.tag = 921;
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    UITextField *field = [alert textFieldAtIndex:0];
    field.text = [[NSUserDefaults standardUserDefaults]
                  objectForKey:REWIND_POT_PROVIDER_DEFAULTS_KEY];
    field.placeholder = @"http://127.0.0.1:4416";
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.keyboardType = UIKeyboardTypeURL;
    [alert show];
}

- (void)showOAuthSetup {
    NSString *message = RewindLanguageIsRussian()
        ? @"В Google Cloud включите YouTube Data API v3 и создайте клиент OAuth типа TVs and Limited Input devices. Вставьте его ID и секрет. Для прежнего ID можно оставить секрет пустым. После сохранения войдите заново."
        : @"In Google Cloud, enable YouTube Data API v3 and create an OAuth client of type TVs and Limited Input devices. Paste its ID and secret. For the saved ID, leave the secret empty to keep it. Sign in again after saving.";
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:RewindLanguageIsRussian()
        ? @"Настройка YouTube OAuth" : @"YouTube OAuth setup" message:message delegate:self
        cancelButtonTitle:RewindL(@"cancel") otherButtonTitles:RewindL(@"save"), nil] autorelease];
    alert.tag = 930;
    alert.alertViewStyle = UIAlertViewStyleLoginAndPasswordInput;
    UITextField *clientID = [alert textFieldAtIndex:0];
    clientID.text = RewindAccountOAuthClientID();
    clientID.placeholder = @"OAuth client ID";
    UITextField *secret = [alert textFieldAtIndex:1];
    secret.placeholder = @"OAuth client secret";
    secret.secureTextEntry = YES;
    for (UITextField *field in [NSArray arrayWithObjects:clientID, secret, nil]) {
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.keyboardType = UIKeyboardTypeASCIICapable;
    }
    [alert show];
}

- (void)showOAuthSaved {
    NSString *message = RewindLanguageIsRussian()
        ? @"Сохранено. Текущий вход использует прежний клиент. Войдите заново, чтобы применить настройку. Доступ к API проверяется при входе; плейлисты сейчас не создаются."
        : @"Saved. The current sign-in keeps its original client. Sign in again to apply this setup. API access is checked during sign-in; no playlist is created now.";
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:RewindL(@"section_account")
        message:message delegate:self cancelButtonTitle:RewindL(@"done")
        otherButtonTitles:RewindL(@"account_sign_in"), nil] autorelease];
    alert.tag = 932;
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == 930 || alertView.tag == 931) {
        if (buttonIndex != alertView.firstOtherButtonIndex) {
            if (alertView.tag == 930) [alertView textFieldAtIndex:1].text = @"";
            return;
        }
        NSString *clientID = alertView.tag == 930 ? [[alertView textFieldAtIndex:0].text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
        NSString *secret = alertView.tag == 930 ? [[alertView textFieldAtIndex:1].text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
        NSError *error = nil;
        BOOL saved = RewindAccountSetOAuthClient(clientID, secret, &error);
        if (alertView.tag == 930) [alertView textFieldAtIndex:1].text = @"";
        if (!saved) {
            [[[[UIAlertView alloc] initWithTitle:RewindL(@"section_account")
                message:[error localizedDescription] delegate:nil cancelButtonTitle:RewindL(@"done")
                otherButtonTitles:nil] autorelease] show];
            return;
        }
        [_table reloadData];
        [self showOAuthSaved];
        return;
    }
    if (alertView.tag == 932) {
        if (buttonIndex == alertView.firstOtherButtonIndex) {
            RewindAccountLoginVC *login = [[[RewindAccountLoginVC alloc] init] autorelease];
            [self.navigationController pushViewController:login animated:YES];
        }
        return;
    }
    if (buttonIndex != alertView.firstOtherButtonIndex) return;
    NSString *value = [[alertView textFieldAtIndex:0].text
                       stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *key = alertView.tag == 921 ? REWIND_POT_PROVIDER_DEFAULTS_KEY : REWIND_API_KEY_DEFAULTS_KEY;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (value.length)
        [defaults setObject:value forKey:key];
    else
        [defaults removeObjectForKey:key];
    [defaults synchronize];
    [_table reloadData];
}

/* uitableviewcell resizes backgroundView/selectedBackgroundView by poking
   their CALayer directly, which skips our -setBounds: override entirely; see
   the identical fix and comment in account_panel_vc.m */
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    if ([cell.backgroundView isKindOfClass:[RewindSettingsChromeView class]])
        cell.backgroundView.frame = cell.bounds;
    if ([cell.selectedBackgroundView isKindOfClass:[RewindSettingsChromeView class]])
        cell.selectedBackgroundView.frame = cell.bounds;
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic) {
        cell.backgroundView.frame = cell.bounds;
        cell.selectedBackgroundView.frame = cell.bounds;
    }
    if (RewindCurrentTheme() == RewindThemeSkeuomorphic &&
        cell.accessoryType == UITableViewCellAccessoryDisclosureIndicator) {
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessoryView = RewindChromeDisclosure();
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 1) { [self showOAuthSetup]; return; }
        if (indexPath.row == 2) {
            UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:RewindLanguageIsRussian()
                ? @"Сбросить YouTube OAuth" : @"Reset YouTube OAuth"
                message:RewindLanguageIsRussian()
                    ? @"Следующий вход будет использовать встроенный TV-клиент. Он не может создавать плейлисты через Data API. Текущий вход сохранится."
                    : @"The next sign-in will use the built-in TV client, which cannot create Data API playlists. Your current sign-in is kept."
                delegate:self cancelButtonTitle:RewindL(@"cancel") otherButtonTitles:RewindLanguageIsRussian() ? @"Сбросить" : @"Reset", nil] autorelease];
            alert.tag = 931;
            [alert show];
            return;
        }
        if (RewindAccountIsSignedIn()) {
            [self showAccountSheet];
        } else {
            RewindAccountLoginVC *login = [[[RewindAccountLoginVC alloc] init] autorelease];
            [self.navigationController pushViewController:login animated:YES];
        }
    } else if (indexPath.section == 2) {
        [self showThemePicker];
    } else if (indexPath.section == 3) {
        [self showLanguagePicker];
    } else if (indexPath.section == 4 && indexPath.row == 0) {
        [self showAPIKeyEditor];
    } else if (indexPath.section == 4 && indexPath.row == 1) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:REWIND_API_KEY_DEFAULTS_KEY];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [tableView reloadData];
    } else if (indexPath.section == 4 && indexPath.row == 2) {
        [self showPOTProviderEditor];
    }
}

@end
