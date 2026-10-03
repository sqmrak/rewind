#ifndef REWIND_IMAGE_CACHE_H
#define REWIND_IMAGE_CACHE_H

#import <UIKit/UIKit.h>

typedef void (^RewindImageCompletion)(UIImage *image);

UIImage *RewindCachedImage(NSString *urlString);
void RewindLoadImage(NSString *urlString, RewindImageCompletion completion);
/* decodes off the main thread and shrinks the longest side to maxPixels */
void RewindLoadImageSized(NSString *urlString, CGFloat maxPixels, RewindImageCompletion completion);

#endif
