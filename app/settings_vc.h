#ifndef TUNETUBE_SETTINGS_VC_H
#define TUNETUBE_SETTINGS_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface TuneSettingsVC : UIViewController <UITableViewDataSource, UITableViewDelegate,
                                              UIAlertViewDelegate, UIActionSheetDelegate> {
    UITableView *_table;
    CAGradientLayer *_backgroundGradient;
}
@end

#endif /* TUNETUBE_SETTINGS_VC_H */
