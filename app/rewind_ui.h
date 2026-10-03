#ifndef REWIND_UI_H
#define REWIND_UI_H

#import <UIKit/UIKit.h>

@class RewindTrack;

typedef void (^RewindAction)(void);

/* ease out everywhere; a spring from ios 7 where uikit has one */
void RewindAnimate(NSTimeInterval duration, void (^animations)(void), void (^completion)(BOOL finished));
void RewindSpring(NSTimeInterval duration, void (^animations)(void), void (^completion)(BOOL finished));

/* youtube thumbnails come in fixed sizes; ask for the one that fits instead of the largest */
NSString *RewindImageURLForSize(NSString *url, CGFloat pixels);

/* shrinks a little while pressed, the way the youtube music ios app answers a touch */
@interface RewindPressControl : UIControl {
    BOOL _pressScales;
    RewindAction _onTap;
}
@property(nonatomic, assign) BOOL pressScales;
- (void)setOnTap:(RewindAction)onTap;
@end

/* uiscrollview's default -touchesShouldCancelInContentView: answers NO for a
   uicontrol, so a drag that starts on a track row (a RewindPressControl, which
   covers the whole row including its title) never turns into a scroll; every
   row in this app is exactly that kind of control, so these always cancel */
@interface RewindScrollView : UIScrollView
@end

@interface RewindTableView : UITableView
@end

@interface RewindIconButton : RewindPressControl {
    UIImageView *_icon;
    UIView *_halo;
    NSString *_iconName;
    CGFloat _iconPoints;
    UIColor *_iconColor;
}
+ (RewindIconButton *)buttonWithIcon:(NSString *)name points:(CGFloat)points;
- (void)setIconName:(NSString *)name;
- (void)setIconColor:(UIColor *)color;
@end

typedef enum {
    RewindPillStyleFilled = 0,
    RewindPillStyleOutlined,
    RewindPillStyleLight
} RewindPillStyle;

@interface RewindPillButton : RewindPressControl {
    UIImageView *_icon;
    UILabel *_label;
    NSString *_iconName;
    RewindPillStyle _style;
}
- (id)initWithStyle:(RewindPillStyle)style icon:(NSString *)icon title:(NSString *)title;
- (void)setTitle:(NSString *)title;
- (void)setIconName:(NSString *)icon;
- (CGFloat)preferredWidthForHeight:(CGFloat)height;
@end

/* a now-playing title too wide for its row scrolls in place instead of ending in an
   ellipsis; a title that already fits just sits still like a normal label */
@interface RewindMarqueeLabel : UIView {
    UILabel *_label;
    UILabel *_labelCopy;
    NSString *_text;
    BOOL _scrolling;
}
@property(nonatomic, readonly) UIFont *font;
- (void)setText:(NSString *)text;
- (void)setFont:(UIFont *)font;
- (void)setTextColor:(UIColor *)color;
@end

@interface RewindArtworkView : UIView {
    UIImageView *_imageView;
    UIImageView *_placeholder;
    NSArray *_urls;
    NSUInteger _attempt;
    NSUInteger _generation;
}
@property(nonatomic, readonly) UIImage *image;
/* tries the sized url first, then the original; fades the picture in */
- (void)setURL:(NSString *)url;
- (void)setImage:(UIImage *)image;
- (void)setCornerRadius:(CGFloat)radius;
@end

@interface RewindChipBar : UIScrollView {
    NSMutableArray *_chips;
    NSInteger _selectedIndex;
    void (^_onSelect)(NSInteger index);
}
@property(nonatomic, readonly) NSInteger selectedIndex;
- (void)setTitles:(NSArray *)titles;
- (void)setSelectedIndex:(NSInteger)index animated:(BOOL)animated;
- (void)setOnSelect:(void (^)(NSInteger index))onSelect;
- (CGFloat)preferredHeight;
@end

/* "sqmrak" over "Quick picks" with the avatar, or a title with a "see all" pill */
@interface RewindSectionHeader : UIView {
    RewindArtworkView *_avatar;
    UILabel *_caption;
    UILabel *_title;
    RewindPillButton *_more;
    UIImageView *_chevron;
    RewindPressControl *_tapArea;
}
- (void)setTitle:(NSString *)title caption:(NSString *)caption avatarURL:(NSString *)avatar;
- (void)setMoreTitle:(NSString *)title action:(RewindAction)action;
- (void)setChevronAction:(RewindAction)action;
- (CGFloat)preferredHeight;
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
@end

@interface RewindPageDots : UIView {
    NSMutableArray *_dots;
    NSUInteger _current;
}
- (void)setCount:(NSUInteger)count;
- (void)setCurrent:(NSUInteger)current;
- (NSUInteger)current;
@end

/* the three bouncing bars youtube music puts over the playing row */
@interface RewindEqualizerView : UIView {
    NSMutableArray *_bars;
    BOOL _animating;
}
- (void)setAnimating:(BOOL)animating;
@end

@interface RewindTrackRow : RewindPressControl {
    RewindArtworkView *_artwork;
    UIView *_playingShade;
    RewindEqualizerView *_equalizer;
    UILabel *_title;
    UILabel *_detail;
    UIImageView *_explicit;
    RewindIconButton *_more;
    RewindTrack *_track;
    BOOL _roundArtwork;
}
@property(nonatomic, readonly) RewindTrack *track;
- (void)setTrack:(RewindTrack *)track;
- (void)setPlaying:(BOOL)playing animating:(BOOL)animating;
- (void)setOnMore:(RewindAction)onMore;
- (void)setRoundArtwork:(BOOL)round;
+ (CGFloat)rowHeight;
@end

/* a row of the track menu or any list sheet */
@interface RewindSheetItem : NSObject {
    NSString *_icon;
    NSString *_title;
    RewindAction _action;
}
@property(nonatomic, readonly) NSString *icon;
@property(nonatomic, readonly) NSString *title;
@property(nonatomic, readonly) RewindAction action;
+ (RewindSheetItem *)itemWithIcon:(NSString *)icon title:(NSString *)title action:(RewindAction)action;
@end

/* the black bottom sheet with rounded top corners: slides up over a dim, drags down to close */
@interface RewindSheet : UIView <UIActionSheetDelegate> {
    UIView *_dim;
    UIView *_panel;
    UIScrollView *_scroll;
    UIView *_header;
    NSMutableArray *_tiles;
    NSMutableArray *_items;
    CGFloat _panY;
    BOOL _dismissing;
    BOOL _visible;
    CGSize _laidSize;
}
- (void)setHeaderTitle:(NSString *)title subtitle:(NSString *)subtitle
           accessories:(NSArray *)accessoryButtons;
/* up to three large tiles above the list, as the track menu has */
- (void)setTiles:(NSArray *)items;
- (void)setItems:(NSArray *)items;
- (void)showInView:(UIView *)host;
- (void)dismiss;
@end

void RewindShowToast(UIView *host, NSString *text, CGFloat bottomInset);

/* the skeuomorphic theme draws no skeleton, so a "loading" status label gets a spinner above its text; the
   spinner lives beside the label and goes away with it when the content is rebuilt */
void RewindUpdateStatusSpinner(UILabel *status, BOOL loading);

#endif /* REWIND_UI_H */
