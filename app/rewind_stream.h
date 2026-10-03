#ifndef REWIND_STREAM_H
#define REWIND_STREAM_H

#import <Foundation/Foundation.h>

/* serves youtube's fragmented audio file as a plain m4a on 127.0.0.1, rebuilt on the fly;
   the ios 5 and 6 media server cannot play the fragmented file, and every ios can play this.
   indexEnd is the last byte of the format's indexRange (the sidx) */
void RewindStreamPrepare(NSURL *source, unsigned long long indexEnd, NSString *userAgent,
                         void (^completion)(NSURL *localURL, NSError *error));
void RewindStreamPrepareCancellable(NSURL *source, unsigned long long indexEnd, NSString *userAgent,
                                    BOOL (^cancelled)(void),
                                    void (^completion)(NSURL *localURL, NSError *error));

/* the same, but a source with enough fragments first delivers a short playable preview of its first
   previewFragments, long before the index of the whole file is built; the complete file then arrives through
   completion. previewReady runs only when a preview exists, and completion then carries the upgrade or its failure */
void RewindStreamPrepareProgressive(NSURL *source, unsigned long long indexEnd, NSString *userAgent,
                                    size_t previewFragments, BOOL (^cancelled)(void),
                                    void (^previewReady)(NSURL *previewURL),
                                    void (^completion)(NSURL *localURL, NSError *error));

/* YES while the proxy still holds the session behind a local url it handed out */
BOOL RewindStreamHasSession(NSURL *localURL);

#endif /* REWIND_STREAM_H */
