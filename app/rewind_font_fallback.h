#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

/* fonts for the characters that neither the app's font nor the system's own fonts can draw, so that styled letters, rare symbols and scripts the system lacks never show as a
   box. The fonts are the files of app/fonts named in rewind_font_fallback.m, tried in that order */
void RewindApplyFontFallback(NSMutableAttributedString *string, CTFontRef base, CGFloat size);
