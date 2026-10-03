#ifndef REWIND_ABOUT_VC_H
#define REWIND_ABOUT_VC_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class RewindAboutHero;

/* a phone style about page: hero with version tiles and grouped rows */
@interface RewindAboutVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    UITableView *_table;
    RewindAboutHero *_hero;
    CAGradientLayer *_backgroundGradient;
    NSArray *_sections;
}
@end

#endif /* REWIND_ABOUT_VC_H */
