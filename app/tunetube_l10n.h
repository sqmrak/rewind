#ifndef TUNETUBE_L10N_H
#define TUNETUBE_L10N_H

#import <Foundation/Foundation.h>

#define TUNETUBE_LANGUAGE_DEFAULTS_KEY @"TuneTubeLanguage"
#define TUNETUBE_LANGUAGE_DID_CHANGE_NOTIFICATION @"TuneTubeLanguageDidChangeNotification"

// "en" or "ru"; default en
FOUNDATION_EXPORT NSString *TuneLanguageCode(void);
FOUNDATION_EXPORT void TuneSetLanguageCode(NSString *code);
FOUNDATION_EXPORT BOOL TuneLanguageIsRussian(void);

// look up a ui string for the active language
FOUNDATION_EXPORT NSString *TuneL(NSString *key);

#endif
