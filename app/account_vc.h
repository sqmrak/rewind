#ifndef REWIND_ACCOUNT_VC_H
#define REWIND_ACCOUNT_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class RewindDeviceCode;

/* google device sign in: a qr code for the page, the code to type, and polling until approval */
@interface RewindAccountLoginVC : UIViewController <UIAlertViewDelegate> {
    UIScrollView *_scroll;
    UIView *_card;
    UIImageView *_qr;
    UILabel *_steps;
    UILabel *_code;
    UILabel *_status;
    UIButton *_copyButton;
    UIButton *_openButton;
    UIButton *_retryButton;
    UIActivityIndicatorView *_spinner;
    CAGradientLayer *_backgroundGradient;
    RewindDeviceCode *_deviceCode;
    NSTimer *_pollTimer;
    NSTimeInterval _pollInterval;
    NSUInteger _attempt;
    BOOL _polling;
    BOOL _pollInFlight;
}
@end

/* a qr image with the four module quiet zone scanners need, nil when the text does not fit */
UIImage *RewindQRImage(NSString *text, CGFloat side);

#endif /* REWIND_ACCOUNT_VC_H */
