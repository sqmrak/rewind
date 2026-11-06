#import "rewind_font_fallback.h"

#include "rewind_text_class.h"

#define FALLBACK_COUNT 5
/* what a lookup answers: the base font or the system draws the character, a bundled font does (its index plus one), or nothing does */
#define FALLBACK_NONE 0
#define FALLBACK_MISSING 255
/* the coverage of a bundled font is read at this size, which is only a handle for the lookup */
#define PROBE_SIZE 12.0

/* in the order they are tried: math letters, symbols of the basic plane, symbols of the other planes */
static NSString *const RewindFallbackFiles[FALLBACK_COUNT] = {
    @"NotoSansMath-Regular.ttf", @"NotoSansSymbols-Regular.ttf", @"NotoSansSymbols2-Regular.ttf", @"Unifont.otf", @"UnifontUpper.otf",
};

static CGFontRef RewindFallbackGraphics[FALLBACK_COUNT];
static CTFontRef RewindFallbackProbes[FALLBACK_COUNT];
static BOOL RewindFallbackTried[FALLBACK_COUNT];
/* base font family -> (code point -> lookup answer), and "index@size" -> font of a bundled file at a size */
static NSMutableDictionary *RewindCoverage;
static NSMutableDictionary *RewindSizedFonts;
static BOOL RewindCoverageDirty;

/* a lookup of a character that no base font has opens the bundled fonts and asks each of them, which took seconds
   on the main thread for a name in an unusual script */
static NSString *RewindCoveragePath(void) {
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    return [caches stringByAppendingPathComponent:@"rewind-glyph-coverage.plist"];
}

static NSString *RewindCoverageSignature(void) {
    id build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
    /* the revision of the bundled fonts: Unifont lost the ideographs and the rare scripts of the upper planes, and an answer saved before that names glyphs it no longer has */
    return [NSString stringWithFormat:@"%@|%@|%@|fonts2", build ? build : @"", [[NSProcessInfo processInfo] operatingSystemVersionString],
            [[NSArray arrayWithObjects:RewindFallbackFiles count:FALLBACK_COUNT] componentsJoinedByString:@","]];
}

static void RewindLoadCoverage(void) {
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:RewindCoveragePath()];
    if (![[file objectForKey:@"signature"] isEqual:RewindCoverageSignature()]) return;
    NSDictionary *families = [file objectForKey:@"families"];
    if (![families isKindOfClass:[NSDictionary class]]) return;
    for (NSString *family in families) {
        NSDictionary *stored = [families objectForKey:family];
        if (![stored isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *answers = [NSMutableDictionary dictionaryWithCapacity:stored.count];
        for (NSString *key in stored) {
            NSNumber *answer = [stored objectForKey:key];
            if ([answer isKindOfClass:[NSNumber class]]) [answers setObject:answer forKey:[NSNumber numberWithUnsignedInt:(unsigned)[key intValue]]];
        }
        [RewindCoverage setObject:answers forKey:family];
    }
}

static NSObject *RewindFallbackLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [[NSObject alloc] init];
        RewindCoverage = [[NSMutableDictionary alloc] init];
        RewindSizedFonts = [[NSMutableDictionary alloc] init];
        RewindLoadCoverage();
    });
    return lock;
}

/* the new answers are written a few seconds after the first of them, in one file, off the thread that asked; the caller holds the lock */
static void RewindCoverageChanged(void) {
    if (RewindCoverageDirty) return;
    RewindCoverageDirty = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSMutableDictionary *families = [NSMutableDictionary dictionary];
        @synchronized (RewindFallbackLock()) {
            RewindCoverageDirty = NO;
            for (NSString *family in RewindCoverage) {
                NSDictionary *answers = [RewindCoverage objectForKey:family];
                NSMutableDictionary *stored = [NSMutableDictionary dictionaryWithCapacity:answers.count];
                for (NSNumber *cp in answers) [stored setObject:[answers objectForKey:cp] forKey:[NSString stringWithFormat:@"%u", [cp unsignedIntValue]]];
                [families setObject:stored forKey:family];
            }
        }
        NSDictionary *file = [NSDictionary dictionaryWithObjectsAndKeys:RewindCoverageSignature(), @"signature", families, @"families", nil];
        if (![file writeToFile:RewindCoveragePath() atomically:YES]) NSLog(@"rewind: the glyph coverage was not saved");
    });
}

/* a bundled file is loaded once, from the file itself, so the 11 MB of Unifont are not held in memory */
static CTFontRef RewindFallbackProbe(NSUInteger index) {
    if (!RewindFallbackTried[index]) {
        RewindFallbackTried[index] = YES;
        NSString *path = [[NSBundle mainBundle] pathForResource:RewindFallbackFiles[index] ofType:nil];
        CGDataProviderRef provider = path ? CGDataProviderCreateWithURL((CFURLRef)[NSURL fileURLWithPath:path]) : NULL;
        CGFontRef graphics = provider ? CGFontCreateWithDataProvider(provider) : NULL;
        if (provider) CGDataProviderRelease(provider);
        if (graphics) {
            RewindFallbackGraphics[index] = graphics;
            RewindFallbackProbes[index] = CTFontCreateWithGraphicsFont(graphics, PROBE_SIZE, NULL, NULL);
        }
        if (!RewindFallbackProbes[index]) NSLog(@"rewind: fallback font %@ did not load", RewindFallbackFiles[index]);
    }
    return RewindFallbackProbes[index];
}

static BOOL RewindFontHasGlyph(CTFontRef font, const UniChar *chars, CFIndex count) {
    CGGlyph glyphs[2] = {0, 0};
    CTFontGetGlyphsForCharacters(font, chars, glyphs, count);
    /* a pair of units maps to one glyph, kept at the first of them */
    return glyphs[0] != 0;
}

/* the font the system would substitute is the box font when it has nothing for the character, and the box font maps every code
   point, so its name has to be told apart */
static BOOL RewindSystemDraws(CTFontRef base, const UniChar *chars, CFIndex count) {
    CFStringRef text = CFStringCreateWithCharacters(NULL, chars, count);
    CTFontRef substitute = text ? CTFontCreateForString(base, text, CFRangeMake(0, count)) : NULL;
    BOOL draws = NO;
    if (substitute) {
        CFStringRef name = CTFontCopyPostScriptName(substitute);
        BOOL box = name && CFStringFind(name, CFSTR("LastResort"), 0).length > 0;
        if (name) CFRelease(name);
        draws = !box && RewindFontHasGlyph(substitute, chars, count);
        CFRelease(substitute);
    }
    if (text) CFRelease(text);
    return draws;
}

static NSUInteger RewindLookup(uint32_t cp, CTFontRef base, NSMutableDictionary *answers) {
    NSNumber *key = [NSNumber numberWithUnsignedInt:cp];
    NSNumber *known = [answers objectForKey:key];
    if (known) return [known unsignedIntegerValue];
    UniChar chars[2];
    CFIndex count = 1;
    if (cp > 0xFFFF) {
        chars[0] = (UniChar)(0xD800 + ((cp - 0x10000) >> 10));
        chars[1] = (UniChar)(0xDC00 + ((cp - 0x10000) & 0x3FF));
        count = 2;
    } else {
        chars[0] = (UniChar)cp;
    }
    NSUInteger answer = FALLBACK_MISSING;
    if (RewindFontHasGlyph(base, chars, count) || RewindSystemDraws(base, chars, count)) {
        answer = FALLBACK_NONE;
    } else {
        for (NSUInteger i = 0; i < FALLBACK_COUNT; ++i) {
            CTFontRef probe = RewindFallbackProbe(i);
            if (probe && RewindFontHasGlyph(probe, chars, count)) {
                answer = i + 1;
                break;
            }
        }
    }
    [answers setObject:[NSNumber numberWithUnsignedInteger:answer] forKey:key];
    RewindCoverageChanged();
    return answer;
}

static CTFontRef RewindSizedFallback(NSUInteger index, CGFloat size) {
    NSString *key = [NSString stringWithFormat:@"%lu@%.2f", (unsigned long)index, size];
    CTFontRef font = (CTFontRef)[RewindSizedFonts objectForKey:key];
    if (font) return font;
    if (!RewindFallbackProbe(index)) return NULL;
    font = CTFontCreateWithGraphicsFont(RewindFallbackGraphics[index], size, NULL, NULL);
    if (!font) return NULL;
    [RewindSizedFonts setObject:(id)font forKey:key];
    CFRelease(font);
    return font;
}

static void RewindSetFallbackRun(NSMutableAttributedString *string, NSUInteger from, NSUInteger to, NSUInteger answer, CGFloat size) {
    if (answer == FALLBACK_NONE || answer == FALLBACK_MISSING || to <= from) return;
    CTFontRef font = RewindSizedFallback(answer - 1, size);
    if (font) [string addAttribute:(id)kCTFontAttributeName value:(id)font range:NSMakeRange(from, to - from)];
}

/* the answers of one base font family; the caller holds the lock; the weights of a family cover the same
   characters, and a name set in the regular */
static NSMutableDictionary *RewindAnswersFor(CTFontRef base) {
    CFStringRef name = CTFontCopyFamilyName(base);
    NSString *baseName = name ? [NSString stringWithString:(NSString *)name] : @"";
    if (name) CFRelease(name);
    NSMutableDictionary *answers = [RewindCoverage objectForKey:baseName];
    if (!answers) {
        answers = [NSMutableDictionary dictionary];
        [RewindCoverage setObject:answers forKey:baseName];
    }
    return answers;
}

void RewindApplyFontFallback(NSMutableAttributedString *string, CTFontRef base, CGFloat size) {
    NSUInteger length = string.length;
    if (!length || !base) return;
    uint16_t *units = malloc(sizeof(uint16_t) * length);
    if (!units) {
        NSLog(@"rewind: no room to look for fallback fonts in %lu units of text", (unsigned long)length);
        return;
    }
    [string.string getCharacters:units range:NSMakeRange(0, length)];
    @synchronized (RewindFallbackLock()) {
        NSMutableDictionary *answers = RewindAnswersFor(base);
        NSUInteger runStart = 0, runAnswer = FALLBACK_NONE;
        size_t at = 0;
        while (at < length) {
            uint32_t cp;
            size_t used = rewind_utf16_next(units, length, at, &cp);
            NSUInteger want = FALLBACK_NONE;
            switch (rewind_cp_class_of(cp)) {
            case REWIND_CP_CHECK: want = RewindLookup(cp, base, answers); break;
            /* a joiner or a selector has no shape of its own and stays in the font of the character before it */
            case REWIND_CP_ATTACH: want = runAnswer; break;
            case REWIND_CP_PLAIN: break;
            }
            if (want != runAnswer) {
                RewindSetFallbackRun(string, runStart, at, runAnswer, size);
                runStart = at;
                runAnswer = want;
            }
            at += used;
        }
        RewindSetFallbackRun(string, runStart, length, runAnswer, size);
    }
    free(units);
}
