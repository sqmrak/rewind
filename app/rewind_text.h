#import <UIKit/UIKit.h>

/* a label for text that comes from outside the app (titles, names, lyrics). Text of letters, digits and ordinary punctuation is left to UILabel and costs nothing more. Text with
   emoji, symbols, styled letters or scripts the system lacks is set with CoreText instead: every emoji the app has a picture of is drawn as that picture, the same on every
   system, and a character no system font has is drawn from the bundled fallback fonts and not as a box. It takes the same properties and measures itself, so it stands wherever a
   UILabel stood; adjustsFontSizeToFitWidth, which the CoreText path does not do, sends the label back to UILabel */
@interface RewindTextLabel : UILabel
@end
