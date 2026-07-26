#import "tunetube_image_cache.h"

#import <dispatch/dispatch.h>

static NSCache *TuneImageStore(void) {
    static NSCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        [cache setCountLimit:48];
        [cache setTotalCostLimit:(NSUInteger)(16 * 1024 * 1024)];
    });
    return cache;
}

static NSOperationQueue *TuneImageQueue(void) {
    static NSOperationQueue *queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[NSOperationQueue alloc] init];
        [queue setMaxConcurrentOperationCount:2];
        [queue setName:@"com.sqmrak.tunetube.image-loader"];
    });
    return queue;
}

static NSMutableDictionary *TunePendingImages(void) {
    static NSMutableDictionary *pending = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pending = [[NSMutableDictionary alloc] init];
    });
    return pending;
}

UIImage *TuneCachedImage(NSString *urlString) {
    if (!urlString.length) return nil;
    return [TuneImageStore() objectForKey:urlString];
}

static void TuneFinishImageLoad(NSString *urlString, UIImage *image) {
    if (image) {
        NSUInteger width = (NSUInteger)MAX(1.0f, image.size.width * image.scale);
        NSUInteger height = (NSUInteger)MAX(1.0f, image.size.height * image.scale);
        NSUInteger cost = width * height * 4;
        [TuneImageStore() setObject:image forKey:urlString cost:cost];
    }

    NSArray *callbacks = nil;
    @synchronized (TunePendingImages()) {
        callbacks = [[TunePendingImages() objectForKey:urlString] copy];
        [TunePendingImages() removeObjectForKey:urlString];
    }
    if (!callbacks.count) {
        [callbacks release];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        for (TuneImageCompletion callback in callbacks) {
            callback(image);
        }
    });
    [callbacks release];
}

void TuneLoadImage(NSString *urlString, TuneImageCompletion completion) {
    if (!urlString.length || !completion) return;

    UIImage *cached = TuneCachedImage(urlString);
    if (cached) {
        /* invoke completion directly when already on main thread to speed up scrolling */
        if ([NSThread isMainThread]) {
            completion(cached);
        } else {
            TuneImageCompletion callback = [completion copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(cached);
            });
            [callback release];
        }
        return;
    }

    BOOL startRequest = NO;
    TuneImageCompletion callback = [completion copy];
    @synchronized (TunePendingImages()) {
        NSMutableArray *callbacks = [TunePendingImages() objectForKey:urlString];
        if (!callbacks) {
            callbacks = [NSMutableArray array];
            [TunePendingImages() setObject:callbacks forKey:urlString];
            startRequest = YES;
        }
        [callbacks addObject:callback];
    }
    [callback release];
    if (!startRequest) return;

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        TuneFinishImageLoad(urlString, nil);
        return;
    }

    NSURLRequest *request = [NSURLRequest requestWithURL:url
                                             cachePolicy:NSURLRequestReturnCacheDataElseLoad
                                         timeoutInterval:20.0f];
    [NSURLConnection sendAsynchronousRequest:request
                                       queue:TuneImageQueue()
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
        (void)response;
        UIImage *image = nil;
        if (!error && data.length) image = [UIImage imageWithData:data];
        TuneFinishImageLoad(urlString, image);
    }];
}
