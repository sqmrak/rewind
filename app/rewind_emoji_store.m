#import "rewind_emoji_store.h"

#include "src/webp/decode.h"

#define PACK_NAME @"emoji"
#define PACK_EXTENSION @"pack"
#define PACK_HEADER 12u
/* the pictures are 56 pixels in the pack; this keeps a crafted header from asking for gigabytes */
#define DECODE_PIXELS_MAX (512 * 512)
#define DECODE_SIDE 128.0f

/* the pack stays mapped, so its 7 MB cost no memory until a picture is read */
static NSData *RewindEmojiPack(void) {
    static NSData *pack;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:PACK_NAME ofType:PACK_EXTENSION];
        /* a build without the pack is a normal one: the text then uses the system's emoji */
        if (!path) return;
        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedAlways error:NULL];
        const uint8_t *bytes = data.bytes;
        uint32_t count = 0;
        if (data.length >= PACK_HEADER && !memcmp(bytes, "EXEM", 4)) memcpy(&count, bytes + 4, 4);
        /* the pack and the table are generated together, so a different count is a stale file */
        if (count == rewind_emoji_image_count && data.length >= PACK_HEADER + 8u * count) pack = [data retain];
        else NSLog(@"rewind: emoji picture pack does not match the table");
    });
    return pack;
}

static NSCache *RewindEmojiCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 300;
    });
    return cache;
}

static const rewind_emoji_entry *RewindEmojiEntry(size_t index) {
    if (index >= rewind_emoji_entry_count) return NULL;
    const rewind_emoji_entry *entry = &rewind_emoji_entries[index];
    return entry->image == REWIND_EMOJI_NO_IMAGE ? NULL : entry;
}

/* the webp bytes of a picture inside the pack, nil when the record points outside the file */
static NSData *RewindEmojiBytes(uint16_t image) {
    NSData *pack = RewindEmojiPack();
    if (!pack) return nil;
    uint32_t offset, length;
    const uint8_t *bytes = pack.bytes;
    memcpy(&offset, bytes + PACK_HEADER + 8u * image, 4);
    memcpy(&length, bytes + PACK_HEADER + 8u * image + 4, 4);
    if ((uint64_t)offset + length > pack.length) return nil;
    return [NSData dataWithBytesNoCopy:(void *)(bytes + offset) length:length freeWhenDone:NO];
}

/* a picture whose bytes do not decode is not asked for again, or every redraw would queue it again */
static NSMutableSet *RewindEmojiFailed(void) {
    static NSMutableSet *failed;
    if (!failed) failed = [[NSMutableSet alloc] init];
    return failed;
}

static void RewindReleasePixels(void *info, const void *data, size_t size) {
    (void)info;
    (void)size;
    free((void *)data);
}

static UIImage *RewindDecodeWebP(NSData *data) {
    WebPDecoderConfig config;
    if (!WebPInitDecoderConfig(&config)) return nil;
    if (WebPGetFeatures(data.bytes, data.length, &config.input) != VP8_STATUS_OK) return nil;
    int width = config.input.width, height = config.input.height;
    if (width <= 0 || height <= 0 || (int64_t)width * height > DECODE_PIXELS_MAX) return nil;
    CGFloat longest = width > height ? width : height;
    if (longest > DECODE_SIDE) {
        CGFloat scale = DECODE_SIDE / longest;
        width = MAX(1, (int)(width * scale + 0.5f));
        height = MAX(1, (int)(height * scale + 0.5f));
        config.options.use_scaling = 1;
        config.options.scaled_width = width;
        config.options.scaled_height = height;
    }
    size_t stride = (size_t)width * 4;
    uint8_t *pixels = calloc((size_t)height, stride);
    if (!pixels) return nil;
    /* premultiplied bgra is little endian alpha first, the layout CoreGraphics draws without a conversion */
    config.output.colorspace = MODE_bgrA;
    config.output.is_external_memory = 1;
    config.output.u.RGBA.rgba = pixels;
    config.output.u.RGBA.stride = (int)stride;
    config.output.u.RGBA.size = stride * (size_t)height;
    VP8StatusCode status = WebPDecode(data.bytes, data.length, &config);
    WebPFreeDecBuffer(&config.output);
    if (status != VP8_STATUS_OK) {
        NSLog(@"rewind: emoji webp decode failed, status %d", (int)status);
        free(pixels);
        return nil;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, stride * (size_t)height, RewindReleasePixels);
    if (!provider) {
        free(pixels);
        return nil;
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate((size_t)width, (size_t)height, 8, 32, stride, space,
                                     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    if (!image) return nil;
    UIImage *result = [UIImage imageWithCGImage:image];
    CGImageRelease(image);
    return result;
}

/* font bitmaps have different transparent margins, so the visible part is cut out and fitted to one square */
static UIImage *RewindFitEmojiImage(UIImage *image) {
    CGImageRef original = image.CGImage;
    if (!original) return image;
    size_t width = CGImageGetWidth(original), height = CGImageGetHeight(original);
    if (!width || !height || width > 512 || height > 512) return image;
    size_t stride = width * 4, bounds[4];
    uint8_t *pixels = calloc(height, stride);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = pixels && space ? CGBitmapContextCreate(pixels, width, height, 8, stride, space,
                                                                     kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
    if (space) CGColorSpaceRelease(space);
    if (!context) {
        free(pixels);
        return image;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), original);
    BOOL fitted = rewind_emoji_alpha_bounds(pixels, height * stride, width, height, stride, bounds);
    CGImageRef bitmap = fitted ? CGBitmapContextCreateImage(context) : NULL;
    CGContextRelease(context);
    free(pixels);
    CGImageRef cropped = bitmap ? CGImageCreateWithImageInRect(bitmap, CGRectMake((CGFloat)bounds[0], (CGFloat)bounds[1], (CGFloat)bounds[2], (CGFloat)bounds[3])) : NULL;
    if (bitmap) CGImageRelease(bitmap);
    if (!cropped) return image;
    CGFloat side = (CGFloat)MAX(width, height), scale = side * 0.93f / (CGFloat)MAX(bounds[2], bounds[3]);
    CGSize shown = CGSizeMake((CGFloat)bounds[2] * scale, (CGFloat)bounds[3] * scale);
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 1);
    [[UIImage imageWithCGImage:cropped] drawInRect:CGRectMake((side - shown.width) / 2, (side - shown.height) / 2, shown.width, shown.height)];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGImageRelease(cropped);
    return result ? result : image;
}

static NSMutableArray *sWaiting;
static NSMutableSet *sPending;
static NSUInteger sLoadedSinceRedraw;
static NSUInteger sMisses;

static void RewindEmojiRedrawWaiting(void) {
    NSArray *views = [sWaiting copy];
    [sWaiting removeAllObjects];
    sLoadedSinceRedraw = 0;
    for (UIView *view in views) [view setNeedsDisplay];
    [views release];
}

static void RewindEmojiDecoded(NSNumber *key, UIImage *image) {
    if (image) {
        [RewindEmojiCache() setObject:image forKey:key];
    } else {
        NSLog(@"rewind: emoji picture %@ does not decode", key);
        [RewindEmojiFailed() addObject:key];
    }
    [sPending removeObject:key];
    ++sLoadedSinceRedraw;
    /* the redraw waits for the queue to run dry, so a screenful of emoji repaints its views once and not per picture */
    if (!sPending.count || sLoadedSinceRedraw >= 16) RewindEmojiRedrawWaiting();
}

static UIImage *RewindDecodeEmoji(NSData *data, uint8_t group) {
    UIImage *image = RewindDecodeWebP(data);
    /* cropping would enlarge small squares, square flags and kneeling figures beyond their font metrics */
    if (group == 1 || group >= 7) return image;
    return RewindFitEmojiImage(image);
}

static void RewindEmojiSchedule(NSNumber *key, NSData *data, uint8_t group) {
    static dispatch_queue_t queue;
    if (!queue) {
        queue = dispatch_queue_create("rewind.emoji.decode", DISPATCH_QUEUE_SERIAL);
        sPending = [[NSMutableSet alloc] init];
        sWaiting = [[NSMutableArray alloc] init];
    }
    if ([sPending containsObject:key]) return;
    [sPending addObject:key];
    dispatch_async(queue, ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        UIImage *image = RewindDecodeEmoji(data, group);
        dispatch_async(dispatch_get_main_queue(), ^{ RewindEmojiDecoded(key, image); });
        [pool drain];
    });
}

BOOL RewindEmojiHasPicture(size_t index) {
    const rewind_emoji_entry *entry = RewindEmojiEntry(index);
    if (!entry || !RewindEmojiPack()) return NO;
    return ![RewindEmojiFailed() containsObject:[NSNumber numberWithUnsignedShort:entry->image]];
}

UIImage *RewindEmojiImage(size_t index) {
    const rewind_emoji_entry *entry = RewindEmojiEntry(index);
    if (!entry) return nil;
    NSNumber *key = [NSNumber numberWithUnsignedShort:entry->image];
    UIImage *image = [RewindEmojiCache() objectForKey:key];
    if (image || [RewindEmojiFailed() containsObject:key]) return image;
    NSData *data = RewindEmojiBytes(entry->image);
    if (!data) return nil;
    RewindEmojiSchedule(key, data, entry->group);
    ++sMisses;
    return nil;
}

NSUInteger RewindEmojiMissCount(void) { return sMisses; }

void RewindEmojiRedrawWhenLoaded(UIView *view) {
    if (!sWaiting || !sPending.count) return;
    if ([sWaiting indexOfObjectIdenticalTo:view] == NSNotFound) [sWaiting addObject:view];
}
