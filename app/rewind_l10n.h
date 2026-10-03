#ifndef REWIND_L10N_H
#define REWIND_L10N_H

#import <Foundation/Foundation.h>

#define REWIND_LANGUAGE_DEFAULTS_KEY @"RewindLanguage"
#define REWIND_LANGUAGE_DID_CHANGE_NOTIFICATION @"RewindLanguageDidChangeNotification"

// "en" or "ru"; defaults to the device language until the user picks one
FOUNDATION_EXPORT NSString *RewindLanguageCode(void);
FOUNDATION_EXPORT void RewindSetLanguageCode(NSString *code);
FOUNDATION_EXPORT BOOL RewindLanguageIsRussian(void);

// look up a ui string for the active language
FOUNDATION_EXPORT NSString *RewindL(NSString *key);

#endif
