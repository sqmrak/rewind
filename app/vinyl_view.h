#ifndef REWIND_VINYL_VIEW_H
#define REWIND_VINYL_VIEW_H

#import <UIKit/UIKit.h>

@class RewindArtworkView;

/* a finger on the record turns it and the track follows: one turn is the 1.8 seconds a 33 rpm record takes */
@protocol RewindVinylScratchDelegate <NSObject>
- (void)vinylScratchBegan;
- (void)vinylScratchedByRadians:(CGFloat)radians interval:(NSTimeInterval)interval;
- (void)vinylScratchEnded;
@end

/* the cover as a spinning record, turned by hand to move through the track */
@interface RewindVinylView : UIView {
    RewindArtworkView *_label;
    BOOL _spinning;
    BOOL _scratching;
    CGFloat _angle;
    CGFloat _touchAngle;
    NSTimeInterval _touchTime;
    id<RewindVinylScratchDelegate> _scratchDelegate;
}
@property(nonatomic, assign) id<RewindVinylScratchDelegate> scratchDelegate;
- (void)setURL:(NSString *)url;
- (void)setPlaying:(BOOL)playing;
@end

#endif /* REWIND_VINYL_VIEW_H */
