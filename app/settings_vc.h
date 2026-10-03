#ifndef REWIND_SETTINGS_VC_H
#define REWIND_SETTINGS_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface RewindSettingsVC : UIViewController <UITableViewDataSource, UITableViewDelegate,
                                              UIAlertViewDelegate, UIActionSheetDelegate> {
    UITableView *_table;
    CAGradientLayer *_backgroundGradient;
}
@end

#endif /* REWIND_SETTINGS_VC_H */
