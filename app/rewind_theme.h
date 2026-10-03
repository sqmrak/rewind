#ifndef REWIND_THEME_H
#define REWIND_THEME_H

#import <UIKit/UIKit.h>

extern NSString * const RewindThemeDidChangeNotification;
extern NSString * const RewindFocusSearchNotification;

typedef enum {
    RewindThemeMaterialDesign3 = 0,
    /* the ios 5 look: bars, tables and controls drawn by rewind_chrome on every ios */
    RewindThemeSkeuomorphic = 1
} RewindTheme;

RewindTheme RewindCurrentTheme(void);
void RewindSetTheme(RewindTheme theme);

/* colors for the selected interface theme */
UIColor *RewindColorBackground(void);
UIColor *RewindColorCanvas(void);
UIColor *RewindColorSurface(void);
UIColor *RewindColorSurfaceHigh(void);
UIColor *RewindColorOverlay(void);
UIColor *RewindColorDivider(void);
UIColor *RewindColorText(void);
UIColor *RewindColorTextSecondary(void);
UIColor *RewindColorTextTertiary(void);
UIColor *RewindColorLink(void);
UIColor *RewindColorHeading(void);
UIColor *RewindColorPlaceholder(void);
UIColor *RewindColorChrome(void);
/* a filled button and the glyph or title drawn on it: white with black on material, red with white
   on the skeuomorphic theme */
UIColor *RewindColorAccentFill(void);
UIColor *RewindColorOnAccent(void);

/* layout is specified in android dp; this maps it to points for the current screen */
CGFloat RewindScale(void);
CGFloat RW(CGFloat dp);
BOOL RewindIsPad(void);
/* ios 7 and later draw the status bar over the app; ios 11+ notched/dynamic
   island devices need the real safe area, not the fixed 20pt bar */
CGFloat RewindStatusBarInset(void);
/* home indicator reserved strip on ios 11+ face id devices, 0 elsewhere */
CGFloat RewindBottomSafeInset(void);

typedef enum {
    RewindWeightRegular = 0,
    RewindWeightMedium,
    RewindWeightBold
} RewindWeight;

/* roboto from the bundle, system fonts when a face failed to register */
UIFont *RewindFont(CGFloat dp, RewindWeight weight);

/* a bundled glyph from art/icons tinted and scaled to size, cached */
UIImage *RewindIcon(NSString *name, CGFloat points, UIColor *color);

/* a solid-color 1x1 image, tileable as a bar or view background */
UIImage *RewindSolidImage(UIColor *color);

/* navigation bars on pushed screens */
void RewindStyleNavigationBar(UINavigationBar *bar);
UIBarButtonItem *RewindBackBarItem(id target, SEL action);
UIBarButtonItem *RewindIconBarItem(NSString *icon, id target, SEL action);
UIBarButtonItem *RewindBarButtonItem(NSString *title, id target, SEL action);

/* text measurement for ios 5 through 10 */
CGSize RewindTextSize(NSString *text, UIFont *font, CGFloat width);

#endif /* REWIND_THEME_H */
