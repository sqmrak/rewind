#import "rewind_image_cache.h"

#import <ImageIO/ImageIO.h>
#import <dispatch/dispatch.h>

enum { RewindImageLimit = 4 * 1024 * 1024 };

static NSCache *RewindImageStore(void) {
    static NSCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        [cache setCountLimit:160];
        [cache setTotalCostLimit:(NSUInteger)(16 * 1024 * 1024)];
    });
    return cache;
}

static NSOperationQueue *RewindImageQueue(void) {
    static NSOperationQueue *queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[NSOperationQueue alloc] init];
        /* dozens of thumbnails per page; two at a time left the home grey on slow networks */
        [queue setMaxConcurrentOperationCount:4];
        [queue setName:@"com.sqmrak.rewind.image-loader"];
    });
    return queue;
}

static NSMutableDictionary *RewindPendingImages(void) {
    static NSMutableDictionary *pending = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ pending = [[NSMutableDictionary alloc] init]; });
    return pending;
}

UIImage *RewindCachedImage(NSString *urlString) {
    if (!urlString.length) return nil;
    return [RewindImageStore() objectForKey:urlString];
}

static void RewindFinishImageLoad(NSString *key, UIImage *image) {
    if (image) {
        NSUInteger width = (NSUInteger)MAX(1.0f, image.size.width * image.scale);
        NSUInteger height = (NSUInteger)MAX(1.0f, image.size.height * image.scale);
        [RewindImageStore() setObject:image forKey:key cost:width * height * 4];
    }
    NSArray *callbacks = nil;
    @synchronized (RewindPendingImages()) {
        callbacks = [[RewindPendingImages() objectForKey:key] copy];
        [RewindPendingImages() removeObjectForKey:key];
    }
    if (!callbacks.count) {
        [callbacks release];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (RewindImageCompletion callback in callbacks) callback(image);
    });
    [callbacks release];
}

/* imageio makes the small bitmap before uikit can decode the full remote image */
static UIImage *RewindDecodedImage(NSData *data, CGFloat maxPixels) {
    CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *properties = (NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    NSUInteger width = [[properties objectForKey:(id)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    NSUInteger height = [[properties objectForKey:(id)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    [properties release];
    if (!width || !height || width > 8192 || height > 8192) {
        CFRelease(source);
        return nil;
    }
    NSUInteger side = (NSUInteger)MAX(48.0f, maxPixels > 0 ? maxPixels : 512.0f);
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                             (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailFromImageAlways,
                             (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailWithTransform,
                             [NSNumber numberWithUnsignedInteger:side], (id)kCGImageSourceThumbnailMaxPixelSize,
                             (id)kCFBooleanFalse, (id)kCGImageSourceShouldCache, nil];
    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (CFDictionaryRef)options);
    CFRelease(source);
    if (!thumbnail) return nil;
    UIImage *image = [UIImage imageWithCGImage:thumbnail];
    CGImageRelease(thumbnail);
    return image;
}

@class RewindImageRequest;

/* a home page asks for dozens of thumbnails at once; unbounded connections each pay a tls
   handshake on iOS 5 and starve the ones the visible rows wait for. main thread only */
enum { RewindImageMaxActive = 6 };
static NSUInteger RewindImageActive;

static NSMutableArray *RewindImageWaiting(void) {
    static NSMutableArray *waiting = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ waiting = [[NSMutableArray alloc] init]; });
    return waiting;
}

static void RewindImageStartWaiting(void);

@interface RewindImageRequest : NSObject <NSURLConnectionDataDelegate> {
    NSString *_key;
    NSURL *_url;
    CGFloat _maxPixels;
    NSMutableData *_data;
    NSURLConnection *_connection;
    BOOL _finished;
}
- (id)initWithURL:(NSURL *)url key:(NSString *)key maxPixels:(CGFloat)maxPixels;
- (void)start;
@end

@implementation RewindImageRequest

- (id)initWithURL:(NSURL *)url key:(NSString *)key maxPixels:(CGFloat)maxPixels {
    self = [super init];
    if (!self) return nil;
    _url = [url retain];
    _key = [key copy];
    _maxPixels = maxPixels;
    _data = [[NSMutableData alloc] init];
    return self;
}

- (void)dealloc {
    [_connection cancel];
    [_connection release];
    [_data release];
    [_key release];
    [_url release];
    [super dealloc];
}

- (void)fail {
    if (_finished) return;
    _finished = YES;
    [_connection cancel];
    [_connection autorelease];
    _connection = nil;
    RewindFinishImageLoad(_key, nil);
    --RewindImageActive;
    RewindImageStartWaiting();
    [self release];
}

- (void)start {
    if (![@"https" isEqualToString:[_url.scheme lowercaseString]]) {
        [self fail];
        return;
    }
    NSURLRequest *request = [NSURLRequest requestWithURL:_url
                                             cachePolicy:NSURLRequestReturnCacheDataElseLoad
                                         timeoutInterval:20.0f];
    _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    if (!_connection) {
        [self fail];
        return;
    }
    /* default scheduling only services the connection in NSDefaultRunLoopMode, which the
       main run loop stops pumping while a scroll view is being dragged (UITrackingRunLoopMode);
       every thumbnail fetch would stall mid-scroll and only catch up once the finger lifted */
    [_connection scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    [_connection start];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    (void)connection;
    if (![response isKindOfClass:[NSHTTPURLResponse class]] ||
        [(NSHTTPURLResponse *)response statusCode] != 200 ||
        ![@"https" isEqualToString:[response.URL.scheme lowercaseString]] ||
        ![[[response MIMEType] lowercaseString] hasPrefix:@"image/"] ||
        response.expectedContentLength > RewindImageLimit) [self fail];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    (void)connection;
    if (_finished) return;
    if (data.length > RewindImageLimit - _data.length) {
        [self fail];
        return;
    }
    [_data appendData:data];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    (void)connection; (void)error;
    [self fail];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    (void)connection;
    if (_finished) return;
    _finished = YES;
    [_connection autorelease];
    _connection = nil;
    --RewindImageActive;
    NSData *data = [_data copy];
    NSString *key = [_key copy];
    CGFloat maxPixels = _maxPixels;
    [RewindImageQueue() addOperationWithBlock:^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        UIImage *image = data.length ? RewindDecodedImage(data, maxPixels) : nil;
        RewindFinishImageLoad(key, image);
        [data release];
        [key release];
        [pool release];
    }];
    RewindImageStartWaiting();
    [self release];
}

@end

/* the newest request goes first: rows scrolled into view matter more than rows left behind */
static void RewindImageStartWaiting(void) {
    NSMutableArray *waiting = RewindImageWaiting();
    while (RewindImageActive < RewindImageMaxActive && waiting.count) {
        RewindImageRequest *request = [[waiting lastObject] retain];
        [waiting removeLastObject];
        ++RewindImageActive;
        [request start];
        [request release];
    }
}

void RewindLoadImage(NSString *urlString, RewindImageCompletion completion) {
    RewindLoadImageSized(urlString, 0.0f, completion);
}

void RewindLoadImageSized(NSString *requestURL, CGFloat maxPixels, RewindImageCompletion completion) {
    if (!requestURL.length || !completion) return;
    NSString *key = maxPixels > 0.0f
        ? [NSString stringWithFormat:@"%@#%d", requestURL, (int)maxPixels] : requestURL;
    UIImage *cached = RewindCachedImage(key);
    if (cached) {
        if ([NSThread isMainThread]) completion(cached);
        else {
            RewindImageCompletion callback = [completion copy];
            dispatch_async(dispatch_get_main_queue(), ^{ callback(cached); [callback release]; });
        }
        return;
    }
    BOOL startRequest = NO;
    RewindImageCompletion callback = [completion copy];
    @synchronized (RewindPendingImages()) {
        NSMutableArray *callbacks = [RewindPendingImages() objectForKey:key];
        if (!callbacks) {
            callbacks = [NSMutableArray array];
            [RewindPendingImages() setObject:callbacks forKey:key];
            startRequest = YES;
        }
        [callbacks addObject:callback];
    }
    [callback release];
    if (!startRequest) return;
    NSURL *url = [NSURL URLWithString:requestURL];
    RewindImageRequest *request = [[RewindImageRequest alloc] initWithURL:url key:key maxPixels:maxPixels];
    /* connections are scheduled on the calling run loop, a background thread has none that runs */
    dispatch_async(dispatch_get_main_queue(), ^{
        [RewindImageWaiting() addObject:request];
        RewindImageStartWaiting();
    });
}
