#import "rewind_text.h"

#import <CoreText/CoreText.h>

#include "rewind_emoji.h"
#import "rewind_emoji_store.h"
#import "rewind_font_fallback.h"

/* an emoji picture is a little wider than the letters around it, as the system's own emoji are */
#define EMOJI_SCALE 1.25f
/* the line a label measures at when its width is not limited */
#define UNLIMITED_WIDTH 100000.0f

static NSString *const RewindEmojiAttribute = @"RewindEmoji";

/* the CoreText path is for text a system label gets wrong: a surrogate pair (emoji, styled letters, rare scripts), a joiner or selector, a keycap mark, or a character from the
   arrows up (symbols, dingbats, the BMP emoji, CJK); letters, digits and the general punctuation before that are the label's own */
static BOOL RewindTextNeedsCoreText(NSString *text) {
    NSUInteger length = text.length;
    for (NSUInteger i = 0; i < length; ++i) {
        unichar unit = [text characterAtIndex:i];
        if (unit >= 0x2190 || unit == 0x200D || (unit >= 0xD800 && unit <= 0xDFFF)) return YES;
    }
    return NO;
}

static CTFontRef RewindCreateFont(UIFont *font) {
    /* the system font is San Francisco from ios 9 and its name starts with a dot; CoreText resolves it by name only up to ios 12, and from ios 13 hands back Times */
    if ([font respondsToSelector:@selector(fontDescriptor)]) return CTFontCreateCopyWithAttributes((CTFontRef)font, font.pointSize, NULL, NULL);
    CTFontRef created = CTFontCreateWithName((CFStringRef)font.fontName, font.pointSize, NULL);
    if (!created) created = CTFontCreateWithName(CFSTR("HelveticaNeue"), font.pointSize, NULL);
    return created;
}

static CGFloat RewindEmojiSide(void *refcon) { return (CGFloat)(((uintptr_t)refcon >> 16) & 0xffff) / 100.0f; }
static CGFloat RewindEmojiAscent(void *refcon) { return RewindEmojiSide(refcon) * 0.82f; }
static CGFloat RewindEmojiDescent(void *refcon) { return RewindEmojiSide(refcon) * 0.23f; }
static CGFloat RewindEmojiWidth(void *refcon) { return RewindEmojiSide(refcon); }
static void RewindEmojiRelease(void *refcon) { (void)refcon; }

/* the run delegate carries the side in hundredths of a point */
static CTRunDelegateRef RewindCreateEmojiDelegate(CGFloat side) {
    CTRunDelegateCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.version = kCTRunDelegateCurrentVersion;
    callbacks.getAscent = RewindEmojiAscent;
    callbacks.getDescent = RewindEmojiDescent;
    callbacks.getWidth = RewindEmojiWidth;
    callbacks.dealloc = RewindEmojiRelease;
    return CTRunDelegateCreate(&callbacks, (void *)(((uintptr_t)(side * 100)) << 16));
}

/* every emoji that has a picture becomes one placeholder character with its own room, back to front so earlier ranges stay put */
static void RewindPlaceEmoji(NSMutableAttributedString *string, NSString *text, CGFloat fontSize) {
    NSUInteger length = text.length;
    uint16_t *units = malloc(sizeof(uint16_t) * (length ? length : 1));
    rewind_emoji_span *spans = malloc(sizeof(rewind_emoji_span) * (length ? length : 1));
    if (units && spans) {
        [text getCharacters:units range:NSMakeRange(0, length)];
        size_t count = rewind_emoji_scan(units, length, spans, length);
        for (size_t i = count; i > 0; --i) {
            const rewind_emoji_span *span = &spans[i - 1];
            if (!RewindEmojiHasPicture(span->entry)) continue;
            NSRange place = NSMakeRange(span->start, 1);
            [string replaceCharactersInRange:NSMakeRange(span->start, span->length) withString:@"￼"];
            /* the picture is drawn over this character; a font with no glyph for it would show its empty-glyph mark under the picture */
            [string addAttribute:(id)kCTForegroundColorAttributeName value:(id)[UIColor clearColor].CGColor range:place];
            CTRunDelegateRef delegate = RewindCreateEmojiDelegate(fontSize * EMOJI_SCALE);
            [string addAttribute:(id)kCTRunDelegateAttributeName value:(id)delegate range:place];
            CFRelease(delegate);
            [string addAttribute:RewindEmojiAttribute value:[NSNumber numberWithUnsignedInteger:span->entry] range:place];
        }
    } else {
        NSLog(@"rewind: no room to look for emoji in %lu units of text", (unsigned long)length);
    }
    free(units);
    free(spans);
}

/* text set in lines: what a label draws and measures */
@interface RewindTextLayout : NSObject {
    CTLineRef *_lines;
    CGPoint *_origins;
    CGFloat *_ascents;
    CGFloat *_descents;
    NSUInteger _lineCount;
    CGSize _size;
}
@property (nonatomic, readonly) CGSize size;
+ (RewindTextLayout *)layoutForText:(NSString *)text font:(UIFont *)font color:(UIColor *)color width:(CGFloat)width maxLines:(NSUInteger)maxLines
                             flush:(CGFloat)flush ellipsis:(BOOL)ellipsis;
- (void)drawAtPoint:(CGPoint)origin width:(CGFloat)width;
@end

@implementation RewindTextLayout

@synthesize size = _size;

+ (RewindTextLayout *)layoutForText:(NSString *)text font:(UIFont *)font color:(UIColor *)color width:(CGFloat)width maxLines:(NSUInteger)maxLines
                             flush:(CGFloat)flush ellipsis:(BOOL)ellipsis {
    RewindTextLayout *layout = [[[RewindTextLayout alloc] init] autorelease];
    CTFontRef base = RewindCreateFont(font);
    if (!base) {
        NSLog(@"rewind: no font for the text of a label");
        return layout;
    }
    NSMutableAttributedString *string = [[[NSMutableAttributedString alloc] initWithString:text] autorelease];
    [string addAttribute:(id)kCTFontAttributeName value:(id)base range:NSMakeRange(0, string.length)];
    [string addAttribute:(id)kCTForegroundColorAttributeName value:(id)(color ? color : [UIColor blackColor]).CGColor range:NSMakeRange(0, string.length)];
    RewindPlaceEmoji(string, text, font.pointSize);
    RewindApplyFontFallback(string, base, font.pointSize);
    CFRelease(base);

    CTLineBreakMode breakMode = kCTLineBreakByWordWrapping;
    CTParagraphStyleSetting settings[] = {{kCTParagraphStyleSpecifierLineBreakMode, sizeof(breakMode), &breakMode}};
    CTParagraphStyleRef paragraph = CTParagraphStyleCreate(settings, 1);
    [string addAttribute:(id)kCTParagraphStyleAttributeName value:(id)paragraph range:NSMakeRange(0, string.length)];
    CFRelease(paragraph);

    CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString((CFAttributedStringRef)string);
    CFIndex length = (CFIndex)string.length;
    NSUInteger capacity = 8;
    layout->_lines = calloc(capacity, sizeof(CTLineRef));
    layout->_origins = calloc(capacity, sizeof(CGPoint));
    layout->_ascents = calloc(capacity, sizeof(CGFloat));
    layout->_descents = calloc(capacity, sizeof(CGFloat));
    CGFloat baseline = 0, widest = 0, previousDescent = 0, room = MAX(1, width);
    CFIndex start = 0;
    while (start < length && layout->_lines && layout->_origins && layout->_ascents && layout->_descents) {
        if (layout->_lineCount == capacity) {
            capacity *= 2;
            layout->_lines = realloc(layout->_lines, capacity * sizeof(CTLineRef));
            layout->_origins = realloc(layout->_origins, capacity * sizeof(CGPoint));
            layout->_ascents = realloc(layout->_ascents, capacity * sizeof(CGFloat));
            layout->_descents = realloc(layout->_descents, capacity * sizeof(CGFloat));
            if (!layout->_lines || !layout->_origins || !layout->_ascents || !layout->_descents) break;
        }
        CFIndex fit = CTTypesetterSuggestLineBreak(typesetter, start, room);
        if (fit <= 0) break;
        BOOL lastAllowed = maxLines && layout->_lineCount + 1 == maxLines;
        CTLineRef line;
        if (lastAllowed && start + fit < length) {
            /* the rest of the text goes into one line that is cut to the width, and ends in an ellipsis unless the label clips */
            CTLineRef rest = CTTypesetterCreateLine(typesetter, CFRangeMake(start, length - start));
            NSMutableDictionary *tokenAttributes = [NSMutableDictionary dictionaryWithDictionary:[string attributesAtIndex:(NSUInteger)start effectiveRange:NULL]];
            /* an emoji at the start must not turn the ellipsis into another emoji */
            [tokenAttributes removeObjectForKey:(id)kCTRunDelegateAttributeName];
            [tokenAttributes removeObjectForKey:RewindEmojiAttribute];
            [tokenAttributes setObject:(id)(color ? color : [UIColor blackColor]).CGColor forKey:(id)kCTForegroundColorAttributeName];
            CFAttributedStringRef token = CFAttributedStringCreate(NULL, (CFStringRef)(ellipsis ? @"…" : @""), (CFDictionaryRef)tokenAttributes);
            CTLineRef mark = CTLineCreateWithAttributedString(token);
            CFRelease(token);
            line = CTLineCreateTruncatedLine(rest, room, kCTLineTruncationEnd, mark);
            CFRelease(mark);
            CFRelease(rest);
            if (!line) line = CTTypesetterCreateLine(typesetter, CFRangeMake(start, fit));
            fit = length - start;
        } else {
            line = CTTypesetterCreateLine(typesetter, CFRangeMake(start, fit));
        }
        CGFloat ascent, descent, leading;
        CGFloat lineWidth = (CGFloat)CTLineGetTypographicBounds(line, &ascent, &descent, &leading) - (CGFloat)CTLineGetTrailingWhitespaceWidth(line);
        baseline += (layout->_lineCount ? previousDescent : 0) + ascent + (layout->_lineCount ? leading : 0);
        NSUInteger i = layout->_lineCount++;
        layout->_lines[i] = line;
        layout->_origins[i] = CGPointMake((CGFloat)CTLineGetPenOffsetForFlush(line, flush, room), baseline);
        layout->_ascents[i] = ascent;
        layout->_descents[i] = descent;
        previousDescent = descent;
        if (lineWidth > widest) widest = lineWidth;
        start += fit;
    }
    CFRelease(typesetter);
    layout->_size = CGSizeMake(ceilf((float)widest), ceilf((float)(baseline + previousDescent)) + 1);
    return layout;
}

- (void)dealloc {
    for (NSUInteger i = 0; i < _lineCount; ++i) CFRelease(_lines[i]);
    free(_lines);
    free(_origins);
    free(_ascents);
    free(_descents);
    [super dealloc];
}

/* draws with the top left corner of the text box at origin, in the current UIKit context */
- (void)drawAtPoint:(CGPoint)origin width:(CGFloat)width {
    (void)width;
    if (!_lineCount) return;
    CGContextRef context = UIGraphicsGetCurrentContext();
    for (NSUInteger i = 0; i < _lineCount; ++i) {
        CGContextSaveGState(context);
        /* CoreText draws with the origin at the bottom left, so each line is drawn in a flipped frame of its own */
        CGContextTranslateCTM(context, origin.x + _origins[i].x, origin.y + _origins[i].y);
        CGContextScaleCTM(context, 1, -1);
        CGContextSetTextMatrix(context, CGAffineTransformIdentity);
        CGContextSetTextPosition(context, 0, 0);
        CTLineDraw(_lines[i], context);
        CGContextRestoreGState(context);
        CFArrayRef runs = CTLineGetGlyphRuns(_lines[i]);
        for (CFIndex j = 0; j < CFArrayGetCount(runs); ++j) {
            CTRunRef run = CFArrayGetValueAtIndex(runs, j);
            NSNumber *entry = [(NSDictionary *)CTRunGetAttributes(run) objectForKey:RewindEmojiAttribute];
            if (!entry) continue;
            CGPoint position;
            CGFloat ascent, descent;
            CTRunGetPositions(run, CFRangeMake(0, 1), &position);
            CGFloat side = (CGFloat)CTRunGetTypographicBounds(run, CFRangeMake(0, 0), &ascent, &descent, NULL);
            /* a square of the side the line reserved, centered in its room, which is a little taller than wide */
            CGRect room = CGRectMake(origin.x + _origins[i].x + position.x, origin.y + _origins[i].y - ascent, side, ascent + descent);
            UIImage *picture = RewindEmojiImage([entry unsignedIntegerValue]);
            if (picture) [picture drawInRect:CGRectMake(CGRectGetMidX(room) - side / 2, CGRectGetMidY(room) - side / 2, side, side)];
        }
    }
}

@end

@implementation RewindTextLabel {
    RewindTextLayout *_layout;
    NSString *_layoutKey;
}

- (void)dealloc {
    [_layout release];
    [_layoutKey release];
    [super dealloc];
}

- (BOOL)usesCoreText {
    return !self.adjustsFontSizeToFitWidth && self.text.length && RewindTextNeedsCoreText(self.text);
}

- (CGFloat)flush {
    switch (self.textAlignment) {
    case NSTextAlignmentCenter: return 0.5f;
    case NSTextAlignmentRight: return 1.0f;
    default: return 0.0f;
    }
}

/* the layout of the text at a width, kept until something that shapes it changes; a row that scrolls back asks for the same one many times */
- (RewindTextLayout *)layoutForWidth:(CGFloat)width {
    UIColor *color = self.highlighted && self.highlightedTextColor ? self.highlightedTextColor : self.textColor;
    NSString *key = [NSString stringWithFormat:@"%.2f|%ld|%ld|%@ %.2f|%@|%@", width, (long)self.numberOfLines, (long)self.lineBreakMode, self.font.fontName, self.font.pointSize,
                     color, self.text];
    if (_layout && [key isEqualToString:_layoutKey]) return _layout;
    [_layout release];
    _layout = [[RewindTextLayout layoutForText:self.text font:self.font color:color width:width maxLines:(NSUInteger)MAX(0, (int)self.numberOfLines)
                                        flush:[self flush] ellipsis:self.lineBreakMode != NSLineBreakByClipping] retain];
    [_layoutKey release];
    _layoutKey = [key copy];
    return _layout;
}

- (CGSize)sizeThatFits:(CGSize)size {
    if (![self usesCoreText]) return [super sizeThatFits:size];
    RewindTextLayout *layout = [self layoutForWidth:size.width > 0 ? size.width : UNLIMITED_WIDTH];
    return CGSizeMake(MIN(size.width > 0 ? size.width : UNLIMITED_WIDTH, layout.size.width), layout.size.height);
}

- (CGRect)textRectForBounds:(CGRect)bounds limitedToNumberOfLines:(NSInteger)numberOfLines {
    (void)numberOfLines;
    if (![self usesCoreText]) return [super textRectForBounds:bounds limitedToNumberOfLines:numberOfLines];
    RewindTextLayout *layout = [self layoutForWidth:bounds.size.width];
    /* the full width, so the alignment is the layout's own; the height is the text's, centered in the bounds */
    CGFloat height = MIN(bounds.size.height, layout.size.height);
    return CGRectMake(bounds.origin.x, bounds.origin.y + floorf((float)(bounds.size.height - height) / 2), bounds.size.width, height);
}

- (void)drawTextInRect:(CGRect)rect {
    if (![self usesCoreText]) {
        [super drawTextInRect:rect];
        return;
    }
    RewindTextLayout *layout = [self layoutForWidth:rect.size.width];
    NSUInteger misses = RewindEmojiMissCount();
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    if (self.shadowColor) CGContextSetShadowWithColor(context, self.shadowOffset, 0, self.shadowColor.CGColor);
    /* the text sits on the vertical middle of the rect, as a label's does */
    [layout drawAtPoint:CGPointMake(rect.origin.x, rect.origin.y + floorf((float)(rect.size.height - layout.size.height) / 2)) width:rect.size.width];
    CGContextRestoreGState(context);
    if (RewindEmojiMissCount() != misses) RewindEmojiRedrawWhenLoaded(self);
}

@end
