#ifndef REWIND_ACCOUNT_PANEL_VC_H
#define REWIND_ACCOUNT_PANEL_VC_H

#import <UIKit/UIKit.h>

@class RewindAPI;
@class RewindPlayer;

@interface RewindAccountPanelVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate> {
    RewindAPI *_api;
    RewindPlayer *_player;
    UITableView *_table;
    UIView *_profile;
    UIImageView *_avatar;
    UILabel *_name;
    UILabel *_email;
    UIButton *_manage;
    NSUInteger _profileRequest;
}
- (id)initWithAPI:(RewindAPI *)api player:(RewindPlayer *)player;
@end

#endif /* REWIND_ACCOUNT_PANEL_VC_H */
