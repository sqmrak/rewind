#ifndef REWIND_CHROME_H
#define REWIND_CHROME_H

#import <UIKit/UIKit.h>

/* the ios 5 look of the skeuomorphic theme, drawn here instead of by uikit: ios 7 and later draw the stock
   bars, buttons and chevrons flat, and ios 15 crashed laying out the stock tab bar, whose icon styling asks
   coreimage for an opengl context that comes back null in an unsandboxed app */

UIFont *RewindChromeFont(CGFloat size, BOOL bold);

/* the red bar behind titles, sized for a bar of that height */
UIImage *RewindChromeBarImage(CGFloat height);

/* ios 13 moved bar styling to UINavigationBarAppearance, and from ios 15 a bar scrolled to the top uses its
   scroll edge appearance, which is transparent unless set: the red image showed the black window behind it */
void RewindChromeStyleNavigationBar(UINavigationBar *bar, UIImage *portrait, UIImage *landscape);

/* a bordered bar button, or the arrow shaped back button, carrying a title or a glyph */
UIBarButtonItem *RewindChromeBarItem(NSString *title, UIImage *glyph, BOOL back, id target, SEL action);

/* the grey chevron of an ios 5 row, and its blue check mark, as accessory views */
UIView *RewindChromeDisclosure(void);
UIView *RewindChromeCheckmark(void);

/* rows and separators that run to the edge on every ios, as ios 5 lays them out */
void RewindChromeStyleTable(UITableView *table);
void RewindChromeStyleCell(UITableViewCell *cell);

void RewindChromeStyleSearchBar(UISearchBar *bar);

/* grouped tables in the ios 5 settings layout, dressed for the black theme: rounded dark groups with a grey
   rim on black, white titles, pale blue values, a blue selection and embossed grey section titles */
UIColor *RewindChromeGroupedBackground(void);
UIColor *RewindChromeGroupedTextColor(void);
UIColor *RewindChromeGroupedValueColor(void);
UIColor *RewindChromeGroupedCaptionColor(void);
/* how far a grouped table has to sit in from each side for its groups to look inset: ios 5 and 6 inset the
   rows themselves (0 here), ios 7 and later run them edge to edge */
CGFloat RewindChromeGroupedMargin(void);
/* one row's part of its group, drawn into the current context */
void RewindChromeDrawGroupedSegment(CGRect bounds, BOOL first, BOOL last, BOOL selected);
void RewindChromeStyleGroupedCell(UITableViewCell *cell, BOOL first, BOOL last);
/* section titles above and notes below a group; width is the table's */
UIView *RewindChromeGroupedHeader(NSString *title, CGFloat width);
UIView *RewindChromeGroupedFooter(NSString *text, CGFloat width);
CGFloat RewindChromeGroupedFooterHeight(NSString *text, CGFloat width);

/* the ios 5 on/off switch; it answers -isOn and -setOn:animated: like UISwitch */
@interface RewindChromeSwitch : UIControl {
    BOOL _on;
    CGFloat _knob;
    CGFloat _dragStart;
    BOOL _dragged;
}
@property(nonatomic, getter=isOn) BOOL on;
- (void)setOn:(BOOL)on animated:(BOOL)animated;
@end

/* pushes put a drawn back button on screens that have no left item of their own */
@interface RewindChromeNavigationController : UINavigationController
@end

/* a tab bar and the navigation stacks it switches, standing in for UITabBarController */
@interface RewindChromeTabsController : UIViewController <UINavigationControllerDelegate> {
    NSArray *_controllers;
    NSArray *_titles;
    NSArray *_icons;
    UIView *_bar;
    UIView *_accessory;
    CGFloat _accessoryHeight;
    BOOL _accessoryShown;
    NSUInteger _selected;
    BOOL _barHidden;
}
/* controllers are RewindChromeNavigationController stacks, titles and icon names go with them in order */
- (id)initWithControllers:(NSArray *)controllers titles:(NSArray *)titles icons:(NSArray *)icons;
- (UINavigationController *)selectedNavigation;
/* every stack, the ones not on screen included */
- (NSArray *)controllers;
/* a strip above the tab bar, such as the mini player; it hides with the bar */
- (void)setAccessory:(UIView *)view height:(CGFloat)height;
- (void)setAccessoryShown:(BOOL)shown animated:(BOOL)animated;
@end

#endif /* REWIND_CHROME_H */
