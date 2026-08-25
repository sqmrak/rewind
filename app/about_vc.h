#ifndef TUNETUBE_ABOUT_VC_H
#define TUNETUBE_ABOUT_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface TuneAboutVC : UIViewController {
    UIScrollView *_scroll;
    UIView *_card;
    UIView *_info;
    UILabel *_bodyLabel;
    UIButton *_githubButton;
    UIButton *_telegramButton;
    CAGradientLayer *_backgroundGradient;
    CAGradientLayer *_cardGradient;
    CAGradientLayer *_infoGradient;
}
@end

#endif /* TUNETUBE_ABOUT_VC_H */
