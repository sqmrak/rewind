#ifndef TUNETUBE_THEME_H
#define TUNETUBE_THEME_H

#import <UIKit/UIKit.h>

extern NSString * const TuneTubeThemeDidChangeNotification;
extern NSString * const TuneTubeFocusSearchNotification;

void TuneTubeStyleNavigationBar(UINavigationBar *bar);
UIBarButtonItem *TuneTubeBarButtonItem(NSString *title, id target, SEL action);

UIColor *TuneThemeBackgroundTop(void);
UIColor *TuneThemeBackgroundBottom(void);
UIColor *TuneThemePlayerBackgroundTop(void);
UIColor *TuneThemePlayerBackgroundBottom(void);
UIColor *TuneThemeSurface(void);
UIColor *TuneThemeSurfaceTop(void);
UIColor *TuneThemeSurfaceBottom(void);
UIColor *TuneThemeHeader(void);
UIColor *TuneThemeHeaderText(void);
UIColor *TuneThemeNavigationTop(void);
UIColor *TuneThemeNavigationMiddle(void);
UIColor *TuneThemeNavigationBottom(void);
UIColor *TuneThemeNavigationButtonTop(void);
UIColor *TuneThemeNavigationButtonMiddle(void);
UIColor *TuneThemeNavigationBorder(void);
UIColor *TuneThemeRaisedTop(void);
UIColor *TuneThemeRaisedBottom(void);
UIColor *TuneThemeRaisedBorder(void);
UIColor *TuneThemeRaisedText(void);
UIColor *TuneThemeAccent(void);
UIColor *TuneThemePrimaryText(void);
UIColor *TuneThemeSecondaryText(void);
UIColor *TuneThemeMutedText(void);
UIColor *TuneThemeBorder(void);
UIColor *TuneThemeSearchBackground(void);
UIColor *TuneThemeSliderMinimum(void);
UIColor *TuneThemeSliderMaximum(void);
UIColor *TuneThemeSliderThumb(void);

#endif /* TUNETUBE_THEME_H */
