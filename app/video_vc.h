#ifndef REWIND_VIDEO_VC_H
#define REWIND_VIDEO_VC_H

#import <UIKit/UIKit.h>
@class AVPlayer, AVPlayerLayer, RewindIconButton;

@interface RewindVideoVC : UIViewController {
    AVPlayer *_player;
    AVPlayerLayer *_video;
    RewindIconButton *_close;
    RewindIconButton *_play;
    UIActivityIndicatorView *_spinner;
    UILabel *_errorLabel;
    NSError *_error;
    BOOL _observing;
    BOOL _observingRate;
    BOOL _failed;
    BOOL _ended;
    BOOL _visible;
    BOOL _wantsPlayback;
    NSTimer *_loadTimer;
}
- (id)initWithURL:(NSURL *)url userAgent:(NSString *)userAgent;
@end

#endif
