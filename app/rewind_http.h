#ifndef REWIND_HTTP_H
#define REWIND_HTTP_H

#import <Foundation/Foundation.h>

/* caller runs off the main thread; capacity and request timeout bound the entire transfer */
NSData *RewindHTTPFetch(NSURLRequest *request, NSUInteger capacity,
                        NSHTTPURLResponse **response, NSError **error);
NSData *RewindHTTPFetchCancellable(NSURLRequest *request, NSUInteger capacity,
                                   NSHTTPURLResponse **response, NSError **error, BOOL (^cancelled)(void));
NSString *RewindHTTPHeader(NSHTTPURLResponse *response, NSString *name);

#endif
