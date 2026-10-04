#import "rewind_api.h"
#import "rewind_stream.h"
#import "rewind_config.h"
#import "rewind_http.h"

#import "../core/rewind_model.h"
#import "../core/rewind_ump.h"
#import "../core/rewind_fmp4.h"
#import "../core/rewind_audio.h"
#import "../core/rewind_sabr.h"
#import "rewind_l10n.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <time.h>
#include <errno.h>
#include <stdlib.h>
#include <unistd.h>

static NSString * const RewindErrorDomain = @"com.sqmrak.rewind.api";
static NSString * const RewindEndpoint = @"https://music.youtube.com/youtubei/v1";
static NSString * const RewindEndpointFallback = @"https://youtubei.googleapis.com/youtubei/v1";
static NSString * const RewindEndpointWebFallback = @"https://www.youtube.com/youtubei/v1";
static NSString * const RewindClientName = @"WEB_REMIX";
static NSString * const RewindClientVersion = @"1.20260707.12.00";
static NSString * const RewindPlayerEndpoint = @"https://www.youtube.com/youtubei/v1";
static NSString * const RewindPlayerEndpointFallback = @"https://youtubei.googleapis.com/youtubei/v1";
static NSString * const RewindIOSClientName = @"IOS";
/* IOS 21.02 still returns direct AAC for part of the catalogue */
static NSString * const RewindIOSClientVersion = @"21.02.3";
static NSString * const RewindPublicAudioUserAgent = @"Rewind/1.0";
static NSString * const RewindIOSSABRClientVersion = @"21.26.4";
static NSString * const RewindAndroidClientName = @"ANDROID";
static NSString * const RewindAndroidClientVersion = @"21.26.364";
static NSString * const RewindAndroidMusicClientName = @"ANDROID_MUSIC";
static NSString * const RewindAndroidMusicClientVersion = @"7.27.52";
@implementation RewindAudioRequest
@synthesize upgradeExpected = _upgradeExpected;
- (void)dealloc {
    [_onUpgrade release];
    [_parent release];
    [super dealloc];
}
- (BOOL)isCancelled {
    @synchronized (self) {
        if (_cancelled) return YES;
    }
    return [_parent isCancelled];
}
- (void)cancel {
    @synchronized (self) { _cancelled = YES; }
}
- (BOOL)allowsPreview {
    return _parent ? _parent.allowsPreview : _allowsPreview;
}
- (void)setAllowsPreview:(BOOL)allowed {
    _allowsPreview = allowed;
}
- (void (^)(NSURL *, NSError *))onUpgrade {
    return _parent ? _parent.onUpgrade : _onUpgrade;
}
- (void)setOnUpgrade:(void (^)(NSURL *, NSError *))block {
    if (block == _onUpgrade) return;
    [_onUpgrade release];
    _onUpgrade = [block copy];
}
- (RewindAudioRequest *)branch {
    RewindAudioRequest *child = [[[RewindAudioRequest alloc] init] autorelease];
    child->_parent = [self retain];
    return child;
}
@end
/* keep a fallback so a fresh install can search before settings is opened */
NSString * const RewindDefaultAPIKey = @"AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";

static NSError *RewindError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:RewindErrorDomain
                                code:code
                            userInfo:[NSDictionary dictionaryWithObject:message
                                                                 forKey:NSLocalizedDescriptionKey]];
}

/* code 19 is the one lyrics lookup answer for a track without a lyrics tab or text */
BOOL RewindLyricsMissing(NSError *error) {
    return [error.domain isEqualToString:RewindErrorDomain] && error.code == 19;
}

/* the api, player and stream domains carry plumbing text ("sabr segment never
   completed") meant for RewindDebugLog, not a toast; the account and playlist
   domains already build their message with RewindL, so those pass straight
   through instead of losing the specific, already-localized reason */
NSString *RewindFriendlyError(NSError *error) {
    if (!error) return RewindL(@"err_generic");
    NSString *domain = error.domain;
    if ([domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorNoPermissionsToReadFile:
                return RewindL(@"err_audio_denied");
            case NSURLErrorNotConnectedToInternet:
            case NSURLErrorNetworkConnectionLost:
            case NSURLErrorDataNotAllowed:
            case NSURLErrorInternationalRoamingOff:
            case NSURLErrorCallIsActive:
                return RewindL(@"err_offline");
            default:
                return RewindL(@"err_connect");
        }
    }
    if ([domain isEqualToString:@"RewindPlayerError"])
        return (error.code == 6 || error.code == 8) ? RewindL(@"err_unavailable") : RewindL(@"err_playback");
    if ([domain isEqualToString:@"RewindStream"])
        return error.code == 7 ? RewindL(@"err_audio_denied") : RewindL(@"err_playback");
    if ([domain isEqualToString:RewindErrorDomain]) {
        if (error.code == 24) return RewindL(@"err_audio_denied");
        if (error.code == 22) return RewindL(@"err_youtube_verify");
        if (error.code == 23) return RewindL(@"err_youtube_login");
        return (error.code == 7 || error.code == 8) ? RewindL(@"err_unavailable") : RewindL(@"err_generic");
    }
    NSString *message = error.localizedDescription;
    return message.length ? message : RewindL(@"err_generic");
}

static NSString *RewindString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *RewindCleanText(NSString *value) {
    if (!value) return nil;
    NSString *clean = [value stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return clean.length ? clean : nil;
}

static BOOL RewindIsErrorText(NSString *value) {
    if (!value.length) return YES;
    NSString *text = [[value lowercaseString]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [text rangeOfString:@"the operation could not be completed"].location != NSNotFound ||
           [text rangeOfString:@"operation could not be completed"].location != NSNotFound ||
           [text rangeOfString:@"nsurlerrordomain"].location != NSNotFound;
}

static BOOL RewindIsPlaceholderArtist(NSString *value) {
    NSString *text = [[RewindCleanText(value) lowercaseString]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [text isEqualToString:@"unknown artist"] ||
           [text isEqualToString:@"unknown"] ||
           [text isEqualToString:@"неизвестный артист"] ||
           [text isEqualToString:@"неизвестный исполнитель"];
}

static NSString *RewindText(id node) {
    if ([node isKindOfClass:[NSString class]]) return RewindCleanText(node);
    if (![node isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *dict = (NSDictionary *)node;
    NSString *simple = RewindString([dict objectForKey:@"simpleText"]);
    if (simple) return RewindCleanText(simple);

    NSArray *runs = [dict objectForKey:@"runs"];
    if ([runs isKindOfClass:[NSArray class]]) {
        NSMutableString *text = [NSMutableString string];
        for (id run in runs) {
            NSString *part = RewindText(run);
            if (part) [text appendString:part];
        }
        if ([text length] > 0) return RewindCleanText(text);
    }

    NSString *value = RewindText([dict objectForKey:@"text"]);
    if (value) return RewindCleanText(value);

    NSDictionary *accessibility = [dict objectForKey:@"accessibility"];
    NSDictionary *accessibilityData = [accessibility objectForKey:@"accessibilityData"];
    NSString *label = RewindString([accessibilityData objectForKey:@"label"]);
    if (label) return RewindCleanText(label);

    return nil;
}

/* remote json is hostile; a bounded walk keeps a nested payload from exhausting the stack */
enum { RewindMaxJSONDepth = 48 };

static id RewindFindValueForKey(id node, NSString *key, NSUInteger depth) {
    if (depth > RewindMaxJSONDepth) return nil;
    if ([node isKindOfClass:[NSDictionary class]]) {
        id direct = [(NSDictionary *)node objectForKey:key];
        if (direct) return direct;
        for (id value in [(NSDictionary *)node allValues]) {
            id found = RewindFindValueForKey(value, key, depth + 1);
            if (found) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            id found = RewindFindValueForKey(value, key, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

static void RewindCollectValuesForKey(id node, NSString *key, NSMutableArray *out, NSUInteger depth) {
    if (depth > RewindMaxJSONDepth) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        for (NSString *name in (NSDictionary *)node) {
            id value = [(NSDictionary *)node objectForKey:name];
            if ([name isEqualToString:key]) [out addObject:value];
            else RewindCollectValuesForKey(value, key, out, depth + 1);
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) RewindCollectValuesForKey(value, key, out, depth + 1);
    }
}

static NSString *RewindFindTextForKey(id node, NSString *key) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSString *text = RewindText([dict objectForKey:key]);
        if (text.length) return text;
        for (id value in [dict allValues]) {
            NSString *found = RewindFindTextForKey(value, key);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = RewindFindTextForKey(value, key);
            if (found.length) return found;
        }
    }
    return nil;
}

static NSString *RewindFindStringForKey(id node, NSString *key) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSString *direct = RewindString([dict objectForKey:key]);
        if (direct) return direct;
        for (id value in [dict allValues]) {
            NSString *found = RewindFindStringForKey(value, key);
            if (found) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = RewindFindStringForKey(value, key);
            if (found) return found;
        }
    }
    return nil;
}

static NSString *RewindThumbnail(id node) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSArray *thumbs = [dict objectForKey:@"thumbnails"];
        if ([thumbs isKindOfClass:[NSArray class]]) {
            NSString *url = nil;
            for (id thumb in thumbs) {
                NSString *candidate = RewindString([thumb objectForKey:@"url"]);
                if (candidate) url = candidate;
            }
            if (url) return url;
        }
        for (id value in [dict allValues]) {
            NSString *found = RewindThumbnail(value);
            if (found) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = RewindThumbnail(value);
            if (found) return found;
        }
    }
    return nil;
}

static BOOL RewindURLLooksLikeChannelAvatar(NSString *url) {
    if (!url.length) return NO;
    // channel / artist avatars live on yt3; album art is usually i.ytimg.com
    return [url rangeOfString:@"yt3.ggpht.com"].location != NSNotFound ||
           [url rangeOfString:@"yt3.googleusercontent.com"].location != NSNotFound ||
           [url rangeOfString:@"googleusercontent.com/ytc"].location != NSNotFound;
}

static NSString *RewindBestAvatarThumbnail(id node) {
    // prefer channel-style hosts so we do not show album covers as avatars
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSArray *thumbs = [dict objectForKey:@"thumbnails"];
        if ([thumbs isKindOfClass:[NSArray class]]) {
            NSString *best = nil;
            NSString *any = nil;
            for (id thumb in thumbs) {
                NSString *candidate = RewindString([thumb objectForKey:@"url"]);
                if (!candidate.length) continue;
                any = candidate;
                if (RewindURLLooksLikeChannelAvatar(candidate)) best = candidate;
            }
            if (best.length) return best;
            if (any.length) return any;
        }
        for (id value in [dict allValues]) {
            NSString *found = RewindBestAvatarThumbnail(value);
            if (found.length && RewindURLLooksLikeChannelAvatar(found)) return found;
        }
        for (id value in [dict allValues]) {
            NSString *found = RewindBestAvatarThumbnail(value);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = RewindBestAvatarThumbnail(value);
            if (found.length && RewindURLLooksLikeChannelAvatar(found)) return found;
        }
        for (id value in (NSArray *)node) {
            NSString *found = RewindBestAvatarThumbnail(value);
            if (found.length) return found;
        }
    }
    return nil;
}

static NSString *RewindHeaderThumbnail(id node) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        for (NSString *key in [NSArray arrayWithObjects:
                               @"musicImmersiveHeaderRenderer",
                               @"musicVisualHeaderRenderer",
                               @"musicDetailHeaderRenderer",
                               @"musicHeaderRenderer",
                               @"avatar",
                               @"thumbnail",
                               @"foregroundThumbnail", nil]) {
            id header = [dict objectForKey:key];
            if (!header) continue;
            NSString *url = RewindBestAvatarThumbnail(header);
            if (url.length) return url;
            url = RewindThumbnail(header);
            if (url.length) return url;
        }
        for (id value in [dict allValues]) {
            NSString *found = RewindHeaderThumbnail(value);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = RewindHeaderThumbnail(value);
            if (found.length) return found;
        }
    }
    return nil;
}

NSUInteger RewindClockSeconds(NSString *value) {
    NSArray *parts = [(RewindCleanText(value) ?: @"")
                      componentsSeparatedByString:@":"];
    NSUInteger result = 0;
    for (NSString *part in parts) {
        NSInteger n = [(RewindCleanText(part) ?: @"") integerValue];
        if (n < 0 || n > 3600) return 0;
        result = result * 60u + (NSUInteger)n;
    }
    return result;
}

static BOOL RewindLooksLikeClock(NSString *value) {
    NSArray *parts = [(RewindCleanText(value) ?: @"")
                      componentsSeparatedByString:@":"];
    if ([parts count] < 2 || [parts count] > 3) return NO;
    NSCharacterSet *notDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    for (NSString *part in parts) {
        NSString *clean = RewindCleanText(part);
        if (![clean length] || [clean rangeOfCharacterFromSet:notDigits].location != NSNotFound)
            return NO;
    }
    NSUInteger seconds = [[parts lastObject] integerValue];
    return seconds < 60;
}

/* youtube words the type column in the request language; hl follows the app language */
static NSString *RewindCanonicalType(NSString *value) {
    static NSDictionary *types;
    if (!types) {
        types = [[NSDictionary alloc] initWithObjectsAndKeys:
                 @"Song", @"song", @"Song", @"трек", @"Song", @"песня", @"Song", @"композиция",
                 @"Video", @"video", @"Video", @"видео", @"Video", @"клип",
                 @"Album", @"album", @"Album", @"альбом", @"Album", @"single", @"Album", @"сингл",
                 @"Album", @"ep", @"Album", @"мини-альбом",
                 @"Playlist", @"playlist", @"Playlist", @"плейлист",
                 @"Episode", @"episode", @"Episode", @"выпуск", @"Episode", @"эпизод",
                 @"Artist", @"artist", @"Artist", @"исполнитель", @"Artist", @"артист",
                 @"Profile", @"profile", @"Profile", @"профиль",
                 @"Podcast", @"podcast", @"Podcast", @"подкаст",
                 @"Mix", @"mix", @"Mix", @"микс",
                 @"Music", @"music", @"Music", @"музыка", nil];
    }
    NSString *key = [RewindCleanText(value) lowercaseString];
    return key.length ? [types objectForKey:key] : nil;
}

static BOOL RewindIsTypeLabel(NSString *value) {
    return RewindCanonicalType(value) != nil;
}

static NSString *RewindResultTypeFromText(NSString *value) {
    NSString *clean = RewindCleanText(value);
    if (!clean.length) return nil;
    NSString *type = RewindCanonicalType([[clean componentsSeparatedByString:@"•"] objectAtIndex:0]);
    return [type isEqualToString:@"Music"] ? nil : type;
}

static BOOL RewindIsCountText(NSString *value) {
    NSString *text = [[RewindCleanText(value) lowercaseString]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [text hasSuffix:@" view"] || [text hasSuffix:@" views"] ||
           [text hasSuffix:@" play"] || [text hasSuffix:@" plays"] ||
           [text rangeOfString:@"просмотр"].location != NSNotFound ||
           [text rangeOfString:@"прослушиван"].location != NSNotFound;
}

static NSString *RewindArtistFromMetadataText(NSString *value) {
    NSString *clean = RewindCleanText(value);
    if (!clean || RewindIsErrorText(clean) || RewindIsPlaceholderArtist(clean) ||
        RewindLooksLikeClock(clean) ||
        RewindIsCountText(clean)) return nil;

    NSArray *parts = [clean componentsSeparatedByString:@"•"];
    if ([parts count] > 1) {
        BOOL typeLabel = RewindIsTypeLabel(RewindCleanText([parts objectAtIndex:0]));
        NSString *artist = RewindCleanText([parts objectAtIndex:typeLabel ? 1 : 0]);
        if (!artist || RewindIsErrorText(artist) || RewindIsPlaceholderArtist(artist) ||
            RewindLooksLikeClock(artist) ||
            RewindIsCountText(artist)) return nil;
        return artist;
    }

    return RewindIsTypeLabel(clean) ? nil : clean;
}

static NSString *RewindAlbumFromMetadataText(NSString *value) {
    NSString *clean = RewindCleanText(value);
    if (!clean) return nil;

    NSArray *parts = [clean componentsSeparatedByString:@"•"];
    if ([parts count] < 2) return nil;

    BOOL typeLabel = RewindIsTypeLabel(RewindCleanText([parts objectAtIndex:0]));
    NSUInteger albumIndex = typeLabel ? 2 : 1;
    if ([parts count] <= albumIndex)
        return nil;

    NSString *album = RewindCleanText([parts objectAtIndex:albumIndex]);
    return RewindIsErrorText(album) || RewindLooksLikeClock(album) || RewindIsCountText(album)
        ? nil : album;
}

NSString *RewindDisplayArtist(NSString *artist) {
    if (!artist.length || RewindIsPlaceholderArtist(artist)) return @"Unknown artist";
    NSString *displayArtist = RewindArtistFromMetadataText(artist);
    if (displayArtist.length) return displayArtist;
    NSString *clean = RewindCleanText(artist);
    if (clean.length && !RewindIsErrorText(clean) && !RewindIsPlaceholderArtist(clean) &&
        !RewindIsTypeLabel(clean))
        return clean;
    return @"Unknown artist";
}

NSString *RewindTrackArtistText(RewindTrack *track) {
    NSString *artist = RewindDisplayArtist(track.artist);
    if ([artist caseInsensitiveCompare:@"Unknown artist"] != NSOrderedSame)
        return artist;
    if (track.isPlaylist) return @"YouTube Music";
    return @"Various Artists";
}

static BOOL RewindBrowseLooksLikeArtist(NSDictionary *browse) {
    if (![browse isKindOfClass:[NSDictionary class]]) return NO;
    NSString *browseID = RewindString([browse objectForKey:@"browseId"]);
    if ([browseID hasPrefix:@"UC"] || [browseID hasPrefix:@"MPLA"] ||
        [browseID hasPrefix:@"FEmusic_library_privately_owned_artist"])
        return YES;
    NSDictionary *context = [browse objectForKey:@"browseEndpointContextSupportedConfigs"];
    NSDictionary *musicConfig = [context objectForKey:@"browseEndpointContextMusicConfig"];
    NSString *pageType = RewindString([musicConfig objectForKey:@"pageType"]);
    if ([pageType rangeOfString:@"ARTIST" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return YES;
    return NO;
}

static NSString *RewindArtistBrowseID(id node) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSString *label = RewindText([dict objectForKey:@"text"]);
        if (!label) label = RewindText([dict objectForKey:@"defaultText"]);
        NSDictionary *endpoint = [dict objectForKey:@"navigationEndpoint"];
        if (![endpoint isKindOfClass:[NSDictionary class]])
            endpoint = [dict objectForKey:@"defaultNavigationEndpoint"];
        NSDictionary *browse = [endpoint objectForKey:@"browseEndpoint"];
        if (RewindBrowseLooksLikeArtist(browse)) {
            NSString *browseID = RewindString([browse objectForKey:@"browseId"]);
            if (browseID.length) return browseID;
        }
        if ([label rangeOfString:@"go to artist" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            NSString *browseID = RewindString([browse objectForKey:@"browseId"]);
            if (browseID.length) return browseID;
        }
        for (id value in [dict allValues]) {
            NSString *found = RewindArtistBrowseID(value);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = RewindArtistBrowseID(value);
            if (found.length) return found;
        }
    }
    return nil;
}

// pick artist name from a run that links to an artist page
static NSString *RewindArtistNameFromRuns(id node) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSArray *runs = [dict objectForKey:@"runs"];
        if ([runs isKindOfClass:[NSArray class]]) {
            for (id run in runs) {
                if (![run isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *endpoint = [run objectForKey:@"navigationEndpoint"];
                NSDictionary *browse = [endpoint objectForKey:@"browseEndpoint"];
                if (!RewindBrowseLooksLikeArtist(browse)) continue;
                NSString *text = RewindText(run);
                if (text.length && !RewindIsTypeLabel(text) && !RewindLooksLikeClock(text) &&
                    !RewindIsCountText(text) && !RewindIsPlaceholderArtist(text))
                    return text;
            }
        }
        for (id value in [dict allValues]) {
            NSString *found = RewindArtistNameFromRuns(value);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = RewindArtistNameFromRuns(value);
            if (found.length) return found;
        }
    }
    return nil;
}

static NSString *RewindResolveResultType(NSString *musicVideoType, NSArray *texts) {
    if (musicVideoType.length) {
        // official audio tracks with album art are ATV, not videos
        if ([musicVideoType rangeOfString:@"ATV" options:NSCaseInsensitiveSearch].location != NSNotFound)
            return @"Song";
        if ([musicVideoType rangeOfString:@"OMV" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [musicVideoType rangeOfString:@"UGC" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [musicVideoType rangeOfString:@"OFFICIAL_SOURCE"
                                 options:NSCaseInsensitiveSearch].location != NSNotFound)
            return @"Video";
    }
    for (NSString *text in texts) {
        NSString *type = RewindResultTypeFromText(text);
        if (type.length) return type;
    }
    // playable items without a video marker stay songs
    return @"Song";
}

static NSString *RewindFindClockText(id node) {
    if ([node isKindOfClass:[NSString class]]) {
        NSString *text = RewindCleanText((NSString *)node);
        if (RewindLooksLikeClock(text)) return text;
        for (NSString *part in [text componentsSeparatedByString:@"•"]) {
            NSString *candidate = RewindCleanText(part);
            if (RewindLooksLikeClock(candidate)) return candidate;
        }
    } else if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        for (NSString *key in [NSArray arrayWithObjects:@"text", @"simpleText", nil]) {
            NSString *text = RewindText([dict objectForKey:key]);
            if (text && RewindLooksLikeClock(text)) return text;
        }
        for (id value in [dict allValues]) {
            NSString *found = RewindFindClockText(value);
            if (found) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = RewindFindClockText(value);
            if (found) return found;
        }
    }
    return nil;
}

static RewindTrack *RewindTrackFromRenderer(NSDictionary *renderer) {
    NSDictionary *columns = [renderer objectForKey:@"flexColumns"];
    if (![columns isKindOfClass:[NSArray class]] || [columns count] == 0) return nil;

    NSMutableArray *texts = [NSMutableArray array];
    for (NSDictionary *column in columns) {
        NSDictionary *columnRenderer = [column objectForKey:@"musicResponsiveListItemFlexColumnRenderer"];
        NSString *text = RewindText([columnRenderer objectForKey:@"text"]);
        if (text) [texts addObject:text];
    }

    if ([texts count] == 0) return nil;

    NSString *title = [texts objectAtIndex:0];
    BOOL isPlaylist = NO;
    NSString *musicVideoType = RewindFindStringForKey(renderer, @"musicVideoType");
    NSString *resultType = RewindResolveResultType(musicVideoType, texts);
    /* a substring match also fired on song titles that contain the word */
    for (NSUInteger index = 1; index < texts.count; ++index)
        if ([RewindResultTypeFromText([texts objectAtIndex:index]) isEqualToString:@"Playlist"])
            isPlaylist = YES;
    NSString *playlistID = RewindFindStringForKey(renderer, @"playlistId");
    if (!playlistID.length) {
        NSString *browseID = RewindFindStringForKey(renderer, @"browseId");
        if ([browseID hasPrefix:@"VL"] && browseID.length > 2)
            playlistID = [browseID substringFromIndex:2];
    }
    NSString *videoID = RewindFindStringForKey(renderer, @"videoId");
    if (!videoID.length && !isPlaylist) return nil;
    NSMutableArray *metadata = [NSMutableArray array];
    for (NSUInteger index = 1; index < [texts count]; ++index) {
        NSString *text = [texts objectAtIndex:index];
        /* keep duration separate because some responses put it in its own column */
        if (!RewindLooksLikeClock(text)) [metadata addObject:text];
    }

    // prefer the run that actually links to an artist page
    NSString *artist = RewindArtistNameFromRuns(renderer);
    NSString *album = @"";
    NSUInteger artistIndex = NSNotFound;

    if (!artist.length) {
        for (NSUInteger index = 0; index < metadata.count; ++index) {
            NSString *candidate = RewindArtistFromMetadataText([metadata objectAtIndex:index]);
            if (!candidate) continue;
            artist = candidate;
            artistIndex = index;
            album = RewindAlbumFromMetadataText([metadata objectAtIndex:index]) ?: @"";
            break;
        }
    } else {
        // still try to pull album from the first metadata line
        for (NSUInteger index = 0; index < metadata.count; ++index) {
            album = RewindAlbumFromMetadataText([metadata objectAtIndex:index]) ?: @"";
            if (album.length) {
                artistIndex = index;
                break;
            }
        }
    }
    if (artistIndex != NSNotFound && !album.length) {
        for (NSUInteger index = artistIndex + 1; index < metadata.count; ++index) {
            NSString *candidate = RewindArtistFromMetadataText([metadata objectAtIndex:index]);
            if (candidate && ![candidate isEqualToString:artist]) {
                album = candidate;
                break;
            }
        }
    }

    // byline / secondary line often has the clean artist when flex columns do not
    if (!artist.length) {
        for (NSString *key in [NSArray arrayWithObjects:
                               @"longBylineText", @"shortBylineText", @"bylineText",
                               @"ownerText", @"subtitle", @"artist", nil]) {
            NSString *byline = RewindFindTextForKey(renderer, key);
            NSString *candidate = RewindArtistFromMetadataText(byline);
            if (candidate.length) {
                artist = candidate;
                if (!album.length) album = RewindAlbumFromMetadataText(byline) ?: @"";
                break;
            }
        }
    }
    if (!artist.length) artist = @"";

    /* split title when artist metadata is missing from YouTube Music response */
    if ((!artist.length || [artist caseInsensitiveCompare:@"Unknown artist"] == NSOrderedSame) &&
        title.length) {
        NSArray *separators = [NSArray arrayWithObjects:@" - ", @" – ", @" — ", @" | ", nil];
        for (NSString *sep in separators) {
            NSRange range = [title rangeOfString:sep];
            if (range.location != NSNotFound && range.location > 0 &&
                range.location + range.length < title.length) {
                NSString *left = RewindCleanText([title substringToIndex:range.location]);
                NSString *right = RewindCleanText([title substringFromIndex:range.location + range.length]);
                // "artist - title" is the usual form
                if (left.length && right.length && !RewindLooksLikeClock(left)) {
                    artist = left;
                    title = right;
                }
                break;
            }
        }
    }

    NSUInteger duration = 0;
    NSString *clock = RewindFindClockText(renderer);
    if (clock)
        duration = RewindClockSeconds(clock);

    NSString *artistID = isPlaylist ? nil : RewindArtistBrowseID(renderer);
    NSString *displayArtist = RewindDisplayArtist(artist);
    // last resort: accessibility label often has "title by artist"
    if ([displayArtist caseInsensitiveCompare:@"Unknown artist"] == NSOrderedSame) {
        NSString *access = RewindFindTextForKey(renderer, @"accessibilityData");
        if (!access.length) access = RewindFindTextForKey(renderer, @"label");
        if (access.length) {
            NSRange byRange = [access rangeOfString:@" by " options:NSCaseInsensitiveSearch];
            if (byRange.location != NSNotFound) {
                NSString *after = RewindCleanText([access substringFromIndex:byRange.location + byRange.length]);
                // strip trailing " and n more" / duration junk
                NSArray *cut = [after componentsSeparatedByString:@","];
                NSString *maybe = RewindCleanText([cut objectAtIndex:0]);
                NSArray *cut2 = [maybe componentsSeparatedByString:@"•"];
                maybe = RewindCleanText([cut2 objectAtIndex:0]);
                if (maybe.length && !RewindIsTypeLabel(maybe) && !RewindLooksLikeClock(maybe))
                    displayArtist = maybe;
            }
        }
    }

    RewindTrack *track = [[[RewindTrack alloc] initWithVideoID:videoID
                                        title:title
                                       artist:displayArtist
                                        album:album
                                thumbnailURL:RewindThumbnail(renderer)
                                     duration:duration
                                  playlistID:isPlaylist ? playlistID : nil
                                    artistID:artistID
                                 resultType:resultType] autorelease];
    return texts.count > 1 ? [track trackWithDetail:[texts objectAtIndex:1]] : track;
}

static void RewindCollectTracks(id node, NSMutableArray *tracks) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSDictionary *renderer = [dict objectForKey:@"musicResponsiveListItemRenderer"];
        if ([renderer isKindOfClass:[NSDictionary class]]) {
            RewindTrack *track = RewindTrackFromRenderer(renderer);
            if (track) {
                [tracks addObject:track];
                return;
            }
        }
        for (id value in [dict allValues]) RewindCollectTracks(value, tracks);
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) RewindCollectTracks(value, tracks);
    }
}

/* youtube's gl decides which catalogue/region answers search and browse;
   without it russian results stay pinned to the us catalogue even when hl is russian */
static NSString *RewindRegionCode(void) {
    return RewindLanguageIsRussian() ? @"RU" : @"US";
}

static NSDictionary *RewindClientContext(void) {
    NSDictionary *client = [NSDictionary dictionaryWithObjectsAndKeys:
                            RewindClientName, @"clientName",
                            RewindClientVersion, @"clientVersion",
                            RewindLanguageCode(), @"hl",
                            RewindRegionCode(), @"gl",
                            nil];
    return [NSDictionary dictionaryWithObject:client forKey:@"client"];
}

static NSDictionary *RewindPlayerContext(NSString *clientName, NSString *clientVersion) {
    NSMutableDictionary *client = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                   clientName, @"clientName",
                                   clientVersion, @"clientVersion",
                                   @"en", @"hl",
                                   @"US", @"gl",
                                   nil];

    if ([clientName isEqualToString:RewindIOSClientName]) {
        [client setObject:@"Apple" forKey:@"deviceMake"];
        [client setObject:@"iPhone16,2" forKey:@"deviceModel"];
        [client setObject:@"iPhone" forKey:@"osName"];
        [client setObject:@"18.3.2.22D82" forKey:@"osVersion"];
        [client setObject:[NSString stringWithFormat:@"com.google.ios.youtube/%@ (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)", clientVersion]
                  forKey:@"userAgent"];
    } else if ([clientName isEqualToString:RewindAndroidClientName]) {
        [client setObject:@30 forKey:@"androidSdkVersion"];
        [client setObject:@"Android" forKey:@"osName"];
        [client setObject:@"11" forKey:@"osVersion"];
        [client setObject:@"com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip" forKey:@"userAgent"];
    } else {
        [client setObject:@"Oculus" forKey:@"deviceMake"];
        [client setObject:@"Quest 3" forKey:@"deviceModel"];
        [client setObject:@32 forKey:@"androidSdkVersion"];
        [client setObject:@"Android" forKey:@"osName"];
        [client setObject:@"12L" forKey:@"osVersion"];
        [client setObject:@"com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip" forKey:@"userAgent"];
    }
    return [NSDictionary dictionaryWithObject:client forKey:@"client"];
}

static NSURLRequest *RewindRequestForEndpoint(NSString *endpoint,
                                           NSString *origin,
                                           NSString *clientHeaderName,
                                           NSString *clientVersion,
                                           NSString *userAgent,
                                           NSString *path,
                                           NSString *apiKey,
                                           NSDictionary *body,
                                           NSError **error) {
    if (![apiKey length]) {
        if (error) *error = RewindError(1, @"YouTube Music API key is empty");
        return nil;
    }

    NSString *escapedKey = [apiKey stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@?key=%@",
                                       endpoint, path, escapedKey]];
    if (!url) {
        if (error) *error = RewindError(2, @"invalid YouTube Music endpoint");
        return nil;
    }

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (!data) {
        if (error) *error = jsonError;
        return nil;
    }

    NSMutableURLRequest *request = [[[NSMutableURLRequest alloc] initWithURL:url] autorelease];
    [request setHTTPMethod:@"POST"];
    /* each unavailable player client must release its slot promptly */
    [request setTimeoutInterval:8.0];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:origin forHTTPHeaderField:@"Origin"];
    [request setValue:clientHeaderName forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [request setValue:clientVersion forHTTPHeaderField:@"X-YouTube-Client-Version"];
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    [request setHTTPBody:data];
    return request;
}

static NSURLRequest *RewindRequest(NSString *path, NSString *apiKey, NSDictionary *body,
                                NSError **error) {
    return RewindRequestForEndpoint(RewindEndpoint,
                                 @"https://music.youtube.com",
                                 @"67",
                                 RewindClientVersion,
                                 @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
                                 path, apiKey, body, error);
}

typedef void (^RewindNetworkCompletion)(id decoded, NSError *error);

static BOOL RewindIsCertificateError(NSError *error) {
    if (!error) return NO;
    switch (error.code) {
        case NSURLErrorSecureConnectionFailed:
        case NSURLErrorServerCertificateHasBadDate:
        case NSURLErrorServerCertificateUntrusted:
        case NSURLErrorServerCertificateHasUnknownRoot:
        case NSURLErrorServerCertificateNotYetValid:
            return YES;
        default:
            return NO;
    }
}

static BOOL RewindShouldTryFallback(NSError *error) {
    if (RewindIsCertificateError(error)) return YES;
    switch (error.code) {
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorTimedOut:
            return YES;
        default:
            return NO;
    }
}

/* try the google endpoint when an older dns setup cannot resolve youtube */
/* json from youtube runs to half a megabyte; parsing it on the main thread stalls an iphone 4s,
   so the body is decoded here and only the parsed tree reaches the main queue */
static NSCache *RewindAudioUserAgentStore(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        [cache setCountLimit:64];
    });
    return cache;
}

static void RewindRegisterAudioSource(NSURL *url, NSString *userAgent, NSString *sourceKey) {
    if (!url || !userAgent.length || !sourceKey.length) return;
    NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
                          userAgent, @"userAgent", sourceKey, @"sourceKey", nil];
    [RewindAudioUserAgentStore() setObject:info forKey:[url absoluteString]];
    [RewindAudioUserAgentStore() setObject:[NSDictionary dictionaryWithObjectsAndKeys:
        sourceKey, @"key", [NSDate date], @"date", nil] forKey:@"preferredSource"];
}

static NSString *RewindPreferredAudioSource(void) {
    NSDictionary *info = [RewindAudioUserAgentStore() objectForKey:@"preferredSource"];
    NSDate *date = [info objectForKey:@"date"];
    return date && -[date timeIntervalSinceNow] < 600.0 ? [info objectForKey:@"key"] : nil;
}

/* a plain url stays valid until its expire stamp, so going back to a track or replaying it can skip the
   player request and the probe; a url the player later rejects lands in the excluded sources and is dropped */
static NSMutableDictionary *RewindAudioURLCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSMutableDictionary alloc] init]; });
    return cache;
}

static NSDate *RewindAudioURLExpiry(NSURL *url) {
    NSTimeInterval limit = 1800.0;
    for (NSString *pair in [url.query componentsSeparatedByString:@"&"]) {
        if (![pair hasPrefix:@"expire="]) continue;
        NSTimeInterval stamp = [[pair substringFromIndex:7] doubleValue];
        if (stamp > 0) limit = MIN(limit, stamp - 600.0 - [[NSDate date] timeIntervalSince1970]);
    }
    return limit > 60.0 ? [NSDate dateWithTimeIntervalSinceNow:limit] : nil;
}

static void RewindCacheAudioURL(NSString *videoID, NSURL *url, NSString *userAgent, NSString *sourceKey) {
    NSDate *expiry = [@"https" isEqualToString:[url.scheme lowercaseString]] ? RewindAudioURLExpiry(url) : nil;
    if (!videoID.length || !userAgent.length || !sourceKey.length || !expiry) return;
    NSMutableDictionary *cache = RewindAudioURLCache();
    @synchronized (cache) {
        for (NSString *key in [cache allKeys])
            if ([[[cache objectForKey:key] objectForKey:@"expiry"] timeIntervalSinceNow] <= 0) [cache removeObjectForKey:key];
        if (cache.count >= 32) [cache removeAllObjects];
        [cache setObject:[NSDictionary dictionaryWithObjectsAndKeys:url, @"url", userAgent, @"userAgent",
                          sourceKey, @"key", expiry, @"expiry", nil] forKey:videoID];
    }
}

static NSDictionary *RewindCachedAudioURL(NSString *videoID, NSSet *excluded) {
    NSMutableDictionary *cache = RewindAudioURLCache();
    @synchronized (cache) {
        NSDictionary *entry = [cache objectForKey:videoID];
        if (!entry) return nil;
        if ([[entry objectForKey:@"expiry"] timeIntervalSinceNow] <= 0 ||
            [excluded containsObject:[entry objectForKey:@"key"]]) {
            [cache removeObjectForKey:videoID];
            return nil;
        }
        return [[entry retain] autorelease];
    }
}

NSString *RewindAudioUserAgentForURL(NSURL *url) {
    if (!url) return nil;
    return [[RewindAudioUserAgentStore() objectForKey:[url absoluteString]] objectForKey:@"userAgent"];
}

NSString *RewindAudioSourceKeyForURL(NSURL *url) {
    return url ? [[RewindAudioUserAgentStore() objectForKey:[url absoluteString]] objectForKey:@"sourceKey"] : nil;
}

static NSOperationQueue *RewindNetworkQueue(void) {
    static NSOperationQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [[NSOperationQueue alloc] init];
        /* one sabr track alone runs six segment requests, raced next to two url clients and their probes */
        [queue setMaxConcurrentOperationCount:12];
    });
    return queue;
}

static NSOperationQueue *RewindMetadataQueue(void) {
    static NSOperationQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [[NSOperationQueue alloc] init];
        [queue setMaxConcurrentOperationCount:4];
    });
    return queue;
}

static void RewindSendRequestBeforeDate(NSURLRequest *request, NSURLRequest *fallback,
                                      RewindAudioRequest *audioRequest, NSDate *deadline,
                                      RewindNetworkCompletion completion) {
    RewindNetworkCompletion done = [[completion copy] autorelease];
    NSOperationQueue *queue = audioRequest ? RewindNetworkQueue() : RewindMetadataQueue();
    [queue addOperationWithBlock:^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSHTTPURLResponse *response = nil;
        NSError *error = nil;
        NSMutableURLRequest *bounded = [[request mutableCopy] autorelease];
        NSTimeInterval remaining = [deadline timeIntervalSinceNow];
        NSData *data = nil;
        if (remaining <= 0) {
            error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
        } else {
            [bounded setTimeoutInterval:remaining];
            data = RewindHTTPFetchCancellable(bounded, 4 * 1024 * 1024, &response, &error,
                                              ^{ return audioRequest.cancelled; });
        }
        if (audioRequest.cancelled) {
            [pool drain];
            return;
        }
        if (error && fallback && [deadline timeIntervalSinceNow] > 0 && RewindShouldTryFallback(error)) {
            dispatch_async(dispatch_get_main_queue(), ^{ RewindSendRequestBeforeDate(fallback, nil, audioRequest, deadline, done); });
            [pool drain];
            return;
        }
        id decoded = nil;
        NSError *jsonError = nil;
        if (!error) {
            if (response.statusCode != 200) {
                error = RewindError(3, [NSString stringWithFormat:@"API answered HTTP %ld", (long)response.statusCode]);
            } else {
                decoded = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
                if (![decoded isKindOfClass:[NSDictionary class]])
                    error = jsonError ?: RewindError(3, @"invalid JSON response");
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(decoded, error); });
        [pool drain];
    }];
}

static void RewindSendRequestWithCancellation(NSURLRequest *request, NSURLRequest *fallback,
                                               RewindAudioRequest *audioRequest, RewindNetworkCompletion completion) {
    NSTimeInterval timeout = request ? request.timeoutInterval : 8.0;
    __block BOOL settled = NO;
    RewindNetworkCompletion done = [[^(id root, NSError *error) {
        if (settled || audioRequest.cancelled) return;
        settled = YES;
        completion(root, error);
    } copy] autorelease];
    /* queued lyrics must finish even while earlier metadata occupies every slot */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        done(nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]);
    });
    RewindSendRequestBeforeDate(request, fallback, audioRequest,
                               [NSDate dateWithTimeIntervalSinceNow:timeout], done);
}

static void RewindSendRequest(NSURLRequest *request, NSURLRequest *fallback,
                               RewindNetworkCompletion completion) {
    RewindSendRequestWithCancellation(request, fallback, nil, completion);
}

static void RewindDecodeResponse(id decoded, void (^completion)(id root, NSError *error)) {
    if (!decoded) {
        completion(nil, RewindError(3, @"invalid JSON response"));
        return;
    }
    completion(decoded, nil);
}


/* shelf titles are shown as youtube words them, so these pages ask in the app language;
   gl matters too, home/explore shelf headers stay english without a matching region */
static NSDictionary *RewindLocalizedContext(NSString *clientName, NSString *clientVersion) {
    NSDictionary *client = [NSDictionary dictionaryWithObjectsAndKeys:
                            clientName, @"clientName",
                            clientVersion, @"clientVersion",
                            RewindLanguageCode(), @"hl",
                            RewindRegionCode(), @"gl", nil];
    return [NSDictionary dictionaryWithObject:client forKey:@"client"];
}

static NSDictionary *RewindWebBody(NSDictionary *fields) {
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:fields];
    [body setObject:RewindLocalizedContext(RewindClientName, RewindClientVersion) forKey:@"context"];
    return body;
}

static void RewindWebCall(NSString *path, NSString *apiKey, NSDictionary *fields,
                          void (^completion)(NSDictionary *root, NSError *error)) {
    NSDictionary *body = RewindWebBody(fields);
    NSError *error = nil;
    NSURLRequest *request = RewindRequest(path, apiKey, body, &error);
    NSURLRequest *fallback = RewindRequestForEndpoint(
        RewindEndpointFallback, @"https://youtubei.googleapis.com", @"67", RewindClientVersion,
        @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
        path, apiKey, body, NULL);
    if (!request) {
        completion(nil, error);
        return;
    }
    RewindSendRequest(request, fallback, ^(id decoded, NSError *networkError) {
        if (networkError) {
            completion(nil, networkError);
            return;
        }
        RewindDecodeResponse(decoded, ^(id root, NSError *jsonError) {
            if (jsonError || ![root isKindOfClass:[NSDictionary class]]) {
                completion(nil, jsonError ? jsonError : RewindError(3, @"invalid JSON response"));
                return;
            }
            completion(root, nil);
        });
    });
}

static NSDictionary *RewindDict(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSArray *RewindArray(id value) {
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

/* the largest thumbnail is 544px or more; decoding that per card stalls old devices */
static NSString *RewindThumbnailNear(id node, NSInteger width) {
    NSArray *thumbs = RewindArray(RewindFindValueForKey(node, @"thumbnails", 0));
    NSString *best = nil;
    for (id thumb in thumbs) {
        NSString *url = RewindString([RewindDict(thumb) objectForKey:@"url"]);
        if (!url) continue;
        best = url;
        if ([[RewindDict(thumb) objectForKey:@"width"] integerValue] >= width) break;
    }
    if ([best hasPrefix:@"//"]) best = [@"https:" stringByAppendingString:best];
    return best;
}

static RewindTrack *RewindTrackFromTwoRow(NSDictionary *renderer) {
    NSString *title = RewindText([renderer objectForKey:@"title"]);
    if (!title) return nil;
    NSString *subtitle = RewindText([renderer objectForKey:@"subtitle"]) ?: @"";
    NSArray *parts = [subtitle componentsSeparatedByString:@"•"];
    NSString *typeText = parts.count > 1 ? RewindCanonicalType([parts objectAtIndex:0]) : nil;
    NSString *artist = RewindArtistNameFromRuns([renderer objectForKey:@"subtitle"]);
    if (!artist.length) {
        NSString *last = RewindCleanText([parts lastObject]);
        artist = last && !RewindIsTypeLabel(last) && !RewindIsCountText(last) ? last : @"";
    }
    NSString *thumbnail = RewindThumbnailNear([renderer objectForKey:@"thumbnailRenderer"], 226);
    NSDictionary *navigation = RewindDict([renderer objectForKey:@"navigationEndpoint"]);
    NSDictionary *watch = RewindDict([navigation objectForKey:@"watchEndpoint"]);
    NSDictionary *browse = RewindDict([navigation objectForKey:@"browseEndpoint"]);
    RewindTrack *track = nil;
    NSString *videoID = RewindString([watch objectForKey:@"videoId"]);
    if (videoID.length) {
        NSString *videoType = RewindFindStringForKey(watch, @"musicVideoType");
        NSString *type = typeText ?: RewindResolveResultType(videoType, [NSArray arrayWithObject:subtitle]);
        track = [[[RewindTrack alloc] initWithVideoID:videoID title:title artist:artist album:@""
                                         thumbnailURL:thumbnail duration:0 playlistID:nil
                                             artistID:RewindArtistBrowseID([renderer objectForKey:@"subtitle"])
                                           resultType:type] autorelease];
    } else if (browse) {
        NSString *browseID = RewindString([browse objectForKey:@"browseId"]);
        NSString *pageType = RewindString(RewindFindValueForKey(browse, @"pageType", 0));
        if ([browseID hasPrefix:@"UC"] || [pageType hasSuffix:@"_ARTIST"]) {
            track = [[[RewindTrack alloc] initWithVideoID:nil title:title artist:title album:@""
                                             thumbnailURL:thumbnail duration:0 playlistID:nil
                                                 artistID:browseID resultType:RewindResultTypeArtist] autorelease];
        } else if ([browseID hasPrefix:@"MPRE"]) {
            track = [[[RewindTrack alloc] initWithVideoID:nil title:title artist:artist album:title
                                             thumbnailURL:thumbnail duration:0 playlistID:browseID
                                                 artistID:nil resultType:RewindResultTypeAlbum] autorelease];
        } else if ([browseID hasPrefix:@"VL"] && browseID.length > 2) {
            track = [[[RewindTrack alloc] initWithVideoID:nil title:title artist:artist album:@""
                                             thumbnailURL:thumbnail duration:0
                                               playlistID:[browseID substringFromIndex:2]
                                                 artistID:nil resultType:@"Playlist"] autorelease];
        }
    }
    return [track trackWithDetail:subtitle];
}

static RewindBrowseLink *RewindLinkFromEndpoint(NSString *title, NSDictionary *endpoint, uint32_t color) {
    NSDictionary *browse = RewindDict([endpoint objectForKey:@"browseEndpoint"]);
    NSString *browseID = RewindString([browse objectForKey:@"browseId"]);
    if (!title.length || !browseID.length) return nil;
    return [[[RewindBrowseLink alloc] initWithTitle:title browseID:browseID
                                             params:RewindString([browse objectForKey:@"params"])
                                        stripeColor:color] autorelease];
}

static id RewindShelfItem(NSDictionary *item) {
    NSDictionary *twoRow = RewindDict([item objectForKey:@"musicTwoRowItemRenderer"]);
    if (twoRow) return RewindTrackFromTwoRow(twoRow);
    NSDictionary *listItem = RewindDict([item objectForKey:@"musicResponsiveListItemRenderer"]);
    if (listItem) return RewindTrackFromRenderer(listItem);
    NSDictionary *button = RewindDict([item objectForKey:@"musicNavigationButtonRenderer"]);
    if (button) {
        NSDictionary *solid = RewindDict([button objectForKey:@"solid"]);
        uint32_t color = (uint32_t)[[solid objectForKey:@"leftStripeColor"] unsignedLongLongValue];
        return RewindLinkFromEndpoint(RewindText([button objectForKey:@"buttonText"]),
                                      RewindDict([button objectForKey:@"clickCommand"]), color);
    }
    return nil;
}

static RewindShelf *RewindShelfFromSection(NSDictionary *section) {
    NSDictionary *renderer = nil;
    NSString *title = nil, *caption = nil;
    NSArray *items = nil;
    if ((renderer = RewindDict([section objectForKey:@"musicCarouselShelfRenderer"]))) {
        NSDictionary *header = RewindDict([RewindDict([renderer objectForKey:@"header"])
                                           objectForKey:@"musicCarouselShelfBasicHeaderRenderer"]);
        title = RewindText([header objectForKey:@"title"]);
        caption = RewindText([header objectForKey:@"strapline"]);
        items = RewindArray([renderer objectForKey:@"contents"]);
    } else if ((renderer = RewindDict([section objectForKey:@"musicShelfRenderer"]))) {
        title = RewindText([renderer objectForKey:@"title"]);
        items = RewindArray([renderer objectForKey:@"contents"]);
    } else if ((renderer = RewindDict([section objectForKey:@"gridRenderer"]))) {
        NSDictionary *header = RewindDict([RewindDict([renderer objectForKey:@"header"])
                                           objectForKey:@"gridHeaderRenderer"]);
        title = RewindText([header objectForKey:@"title"]);
        items = RewindArray([renderer objectForKey:@"items"]);
    }
    if (!items.count) return nil;
    NSMutableArray *parsed = [NSMutableArray array];
    BOOL list = NO, links = NO;
    for (id item in items) {
        NSDictionary *dict = RewindDict(item);
        id value = dict ? RewindShelfItem(dict) : nil;
        if (!value) continue;
        [parsed addObject:value];
        if ([dict objectForKey:@"musicResponsiveListItemRenderer"]) list = YES;
        if ([value isKindOfClass:[RewindBrowseLink class]]) links = YES;
    }
    if (!parsed.count) return nil;
    RewindShelfStyle style = links ? RewindShelfStyleLinks : (list ? RewindShelfStyleList : RewindShelfStyleCards);
    return [[[RewindShelf alloc] initWithTitle:title ?: @"" caption:caption items:parsed style:style] autorelease];
}

static NSArray *RewindShelvesFromRoot(NSDictionary *root) {
    NSMutableArray *shelves = [NSMutableArray array];
    NSDictionary *sectionList = RewindDict(RewindFindValueForKey(root, @"sectionListRenderer", 0));
    for (id section in RewindArray([sectionList objectForKey:@"contents"])) {
        RewindShelf *shelf = RewindDict(section) ? RewindShelfFromSection(section) : nil;
        if (shelf) [shelves addObject:shelf];
    }
    return shelves;
}

static NSArray *RewindChipsFromRoot(NSDictionary *root) {
    NSMutableArray *chips = [NSMutableArray array];
    NSDictionary *cloud = RewindDict(RewindFindValueForKey(root, @"chipCloudRenderer", 0));
    for (id chip in RewindArray([cloud objectForKey:@"chips"])) {
        NSDictionary *renderer = RewindDict([RewindDict(chip) objectForKey:@"chipCloudChipRenderer"]);
        RewindBrowseLink *link = RewindLinkFromEndpoint(RewindText([renderer objectForKey:@"text"]),
                                                        RewindDict([renderer objectForKey:@"navigationEndpoint"]), 0);
        if (link) [chips addObject:link];
    }
    return chips;
}

/* the watch page names the lyrics and related browse ids in its tabs */
static NSString *RewindWatchTabBrowseID(NSDictionary *root, NSString *prefix) {
    NSDictionary *tabs = RewindDict(RewindFindValueForKey(root, @"tabbedRenderer", 0));
    NSArray *list = RewindArray(RewindFindValueForKey(tabs ?: root, @"tabs", 0));
    for (id tab in list) {
        NSDictionary *renderer = RewindDict([RewindDict(tab) objectForKey:@"tabRenderer"]);
        id unselectable = [renderer objectForKey:@"unselectable"];
        if ([unselectable isKindOfClass:[NSNumber class]] && [unselectable boolValue]) continue;
        NSDictionary *browse = RewindDict([RewindDict([renderer objectForKey:@"endpoint"])
                                           objectForKey:@"browseEndpoint"]);
        NSString *browseID = RewindString([browse objectForKey:@"browseId"]);
        NSString *pageType = RewindString(RewindFindValueForKey(browse, @"pageType", 0));
        NSString *expected = [prefix isEqualToString:@"MPLY"]
            ? @"MUSIC_PAGE_TYPE_TRACK_LYRICS" : @"MUSIC_PAGE_TYPE_TRACK_RELATED";
        if ([pageType isEqualToString:expected] || (!pageType && [browseID hasPrefix:prefix])) return browseID;
    }
    return nil;
}

@implementation RewindTrack

@synthesize videoID = _videoID;
@synthesize title = _title;
@synthesize artist = _artist;
@synthesize album = _album;
@synthesize thumbnailURL = _thumbnailURL;
@synthesize playlistID = _playlistID;
@synthesize artistID = _artistID;
@synthesize resultType = _resultType;
@synthesize duration = _duration;
- (BOOL)isPlaylist { return _playlistID.length > 0; }

- (id)initWithVideoID:(NSString *)videoID
                title:(NSString *)title
               artist:(NSString *)artist
                album:(NSString *)album
                thumbnailURL:(NSString *)thumbnailURL
                duration:(NSUInteger)duration {
    return [self initWithVideoID:videoID
                            title:title
                           artist:artist
                            album:album
                    thumbnailURL:thumbnailURL
                      duration:duration
                      playlistID:nil
                        artistID:nil
                     resultType:nil];
}

- (id)initWithVideoID:(NSString *)videoID
                title:(NSString *)title
               artist:(NSString *)artist
                album:(NSString *)album
        thumbnailURL:(NSString *)thumbnailURL
             duration:(NSUInteger)duration
          playlistID:(NSString *)playlistID
            artistID:(NSString *)artistID
         resultType:(NSString *)resultType {
    self = [super init];
    if (!self) return nil;
    _videoID = [videoID copy];
    _title = [title copy];
    _artist = [artist copy];
    _album = [album copy];
    _thumbnailURL = [thumbnailURL copy];
    _playlistID = [playlistID copy];
    _artistID = [artistID copy];
    _resultType = [resultType copy];
    _duration = duration;
    return self;
}

- (void)dealloc {
    [_videoID release];
    [_title release];
    [_artist release];
    [_album release];
    [_thumbnailURL release];
    [_playlistID release];
    [_artistID release];
    [_resultType release];
    [_detail release];
    [super dealloc];
}

- (NSString *)detail {
    return _detail;
}

- (RewindTrack *)trackWithDetail:(NSString *)detail {
    RewindTrack *copy = [[[RewindTrack alloc] initWithVideoID:_videoID title:_title artist:_artist
                                                        album:_album thumbnailURL:_thumbnailURL
                                                     duration:_duration playlistID:_playlistID
                                                     artistID:_artistID resultType:_resultType] autorelease];
    copy->_detail = [RewindCleanText(detail) copy];
    return copy;
}

@end

NSString * const RewindResultTypeMix = @"Mix";
NSString * const RewindResultTypeAlbum = @"Album";
NSString * const RewindResultTypeArtist = @"Artist";

@implementation RewindBrowseLink

@synthesize title = _title;
@synthesize browseID = _browseID;
@synthesize params = _params;
@synthesize stripeColor = _stripeColor;

- (id)initWithTitle:(NSString *)title browseID:(NSString *)browseID params:(NSString *)params
        stripeColor:(uint32_t)stripeColor {
    self = [super init];
    if (!self) return nil;
    _title = [title copy];
    _browseID = [browseID copy];
    _params = [params copy];
    _stripeColor = stripeColor;
    return self;
}

- (void)dealloc {
    [_title release];
    [_browseID release];
    [_params release];
    [super dealloc];
}

@end

@implementation RewindShelf

@synthesize title = _title;
@synthesize caption = _caption;
@synthesize items = _items;
@synthesize style = _style;

- (BOOL)isVideoLineup {
    NSUInteger videos = 0, total = 0;
    for (id item in _items) {
        if (![item isKindOfClass:[RewindTrack class]]) continue;
        ++total;
        if ([((RewindTrack *)item).resultType isEqualToString:@"Video"]) ++videos;
    }
    return total >= 3 && videos * 10 >= total * 8;
}

- (id)initWithTitle:(NSString *)title items:(NSArray *)items {
    return [self initWithTitle:title caption:nil items:items style:RewindShelfStyleCards];
}

- (id)initWithTitle:(NSString *)title caption:(NSString *)caption items:(NSArray *)items
              style:(RewindShelfStyle)style {
    self = [super init];
    if (!self) return nil;
    _title = [title copy];
    _caption = [caption copy];
    _items = [items copy];
    _style = style;
    return self;
}

- (void)dealloc {
    [_title release];
    [_caption release];
    [_items release];
    [super dealloc];
}

@end

@implementation RewindLyricLine

@synthesize text = _text;
@synthesize startMS = _startMS;

- (id)initWithText:(NSString *)text startMS:(NSUInteger)startMS {
    self = [super init];
    if (!self) return nil;
    _text = [text copy];
    _startMS = startMS;
    return self;
}

- (void)dealloc {
    [_text release];
    [super dealloc];
}

@end

@implementation RewindLyrics

@synthesize lines = _lines;
@synthesize timed = _timed;
@synthesize source = _source;

- (id)initWithLines:(NSArray *)lines timed:(BOOL)timed source:(NSString *)source {
    self = [super init];
    if (!self) return nil;
    _lines = [lines copy];
    _timed = timed;
    _source = [source copy];
    return self;
}

- (void)dealloc {
    [_lines release];
    [_source release];
    [super dealloc];
}

@end

@interface RewindSABRSession : NSObject {
@public
    NSURL *sabrURL;
    NSData *ustreamerConfig;
    int32_t itag;
    uint64_t lastModified;
    int32_t clientNameNumber;
    NSString *clientVersion;
    NSString *osName;
    NSString *osVersion;
    NSString *userAgent;
    RewindAudioCompletion completion;

    rewind_sabr_t *audio;
    NSString *sourceKey;
    BOOL previewDelivered;
    NSError *lastError;
    RewindAudioRequest *request;
    NSDate *started;
    BOOL finished;
}
@end

@implementation RewindSABRSession

- (id)init {
    self = [super init];
    if (!self) return nil;
    started = [[NSDate alloc] init];
    return self;
}

- (void)dealloc {
    [sabrURL release];
    [ustreamerConfig release];
    [clientVersion release];
    [osName release];
    [osVersion release];
    [userAgent release];
    [completion release];
    [lastError release];
    [sourceKey release];
    rewind_sabr_free(audio);
    [request release];
    [started release];
    [super dealloc];
}

@end

@implementation RewindAPI

- (id)initWithAPIKey:(NSString *)apiKey {
    self = [super init];
    if (!self) return nil;
    _apiKey = [apiKey copy];
    return self;
}

- (void)durationForTrack:(RewindTrack *)track completion:(RewindDurationCompletion)completion {
    if (!completion) return;
    if (!track.videoID.length) {
        completion(0, RewindError(6, @"track has no video id"));
        return;
    }

    NSString *iosUA = @"com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)";
    NSString *androidUA = @"com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip";
    /* same order as audio: android answers without a bot check today */
    RewindDurationWithPlayerClient(track.videoID, _apiKey,
                                   RewindAndroidClientName, RewindAndroidClientVersion,
                                   @"3", androidUA, ^(NSUInteger duration, NSError *androidError) {
        if (duration) {
            completion(duration, nil);
            return;
        }
        RewindDurationWithPlayerClient(track.videoID, _apiKey,
                                       RewindIOSClientName, RewindIOSClientVersion,
                                       @"5", iosUA, ^(NSUInteger iosDuration, NSError *iosError) {
            completion(iosDuration, iosDuration ? nil : (androidError ?: iosError));
        });
    });
}

- (void)dealloc {
    [_apiKey release];
    [_relatedCache release];
    [_relatedOrder release];
    [super dealloc];
}

- (void)search:(NSString *)query completion:(RewindSearchCompletion)completion {
    if (!completion) return;
    if (![query length]) {
        completion(nil, RewindError(4, @"search query is empty"));
        return;
    }

    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          RewindClientContext(), @"context",
                          query, @"query",
                          nil];
    NSError *error = nil;
    NSURLRequest *request = RewindRequest(@"search", _apiKey, body, &error);
    NSError *fallbackError = nil;
    NSURLRequest *fallbackRequest = RewindRequestForEndpoint(
        RewindEndpointFallback, @"https://youtubei.googleapis.com", @"67",
        RewindClientVersion,
        @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
        @"search", _apiKey, body, &fallbackError);
    NSError *webFallbackError = nil;
    NSURLRequest *webFallbackRequest = RewindRequestForEndpoint(
        RewindEndpointWebFallback, @"https://www.youtube.com", @"67",
        RewindClientVersion,
        @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
        @"search", _apiKey, body, &webFallbackError);
    if (!request) {
        completion(nil, error);
        return;
    }

    void (^finish)(id, NSError *) = ^(id decoded, NSError *networkError) {
        if (networkError) {
            completion(nil, networkError);
            return;
        }
        RewindDecodeResponse(decoded, ^(id root, NSError *jsonError) {
            if (jsonError) {
                completion(nil, jsonError);
                return;
            }
            NSMutableArray *tracks = [NSMutableArray array];
            RewindCollectTracks(root, tracks);
            if ([tracks count] == 0) {
                completion(nil, RewindError(5, @"no playable music results in response"));
                return;
            }
            completion(tracks, nil);
        });
    };

    RewindSendRequest(request, fallbackRequest, ^(id decoded, NSError *networkError) {
        if (networkError && webFallbackRequest && RewindShouldTryFallback(networkError)) {
            RewindSendRequest(webFallbackRequest, nil, finish);
            return;
        }
        finish(decoded, networkError);
    });
}

- (void)playlistTracksForID:(NSString *)playlistID completion:(RewindSearchCompletion)completion {
    if (!completion) return;
    if (!playlistID.length) {
        completion(nil, RewindError(13, @"playlist has no id"));
        return;
    }
    /* browse answers 400 for a bare playlist id; the page id carries a VL prefix */
    NSString *browseID = [playlistID hasPrefix:@"VL"] || [playlistID hasPrefix:@"MPRE"]
        ? playlistID : [@"VL" stringByAppendingString:playlistID];
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          RewindClientContext(), @"context",
                          browseID, @"browseId", nil];
    NSError *error = nil;
    NSURLRequest *request = RewindRequest(@"browse", _apiKey, body, &error);
    NSError *fallbackError = nil;
    NSURLRequest *fallback = RewindRequestForEndpoint(
        RewindEndpointFallback, @"https://youtubei.googleapis.com", @"67",
        RewindClientVersion,
        @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
        @"browse", _apiKey, body, &fallbackError);
    if (!request) {
        completion(nil, error);
        return;
    }
    RewindSendRequest(request, fallback, ^(id decoded, NSError *networkError) {
        if (networkError) {
            completion(nil, networkError);
            return;
        }
        RewindDecodeResponse(decoded, ^(id root, NSError *jsonError) {
            if (jsonError) {
                completion(nil, jsonError);
                return;
            }
            NSMutableArray *tracks = [NSMutableArray array];
            RewindCollectTracks(root, tracks);
            if (!tracks.count) {
                completion(nil, RewindError(14, @"playlist has no playable tracks"));
                return;
            }
            completion(tracks, nil);
        });
    });
}

- (void)artistPageForID:(NSString *)artistID completion:(RewindArtistPageCompletion)completion {
    if (!completion) return;
    if (!artistID.length) {
        completion(nil, nil, nil, NO, nil, RewindError(15, @"artist has no id"));
        return;
    }
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          RewindClientContext(), @"context",
                          artistID, @"browseId", nil];
    NSError *error = nil;
    NSURLRequest *request = RewindRequest(@"browse", _apiKey, body, &error);
    NSError *fallbackError = nil;
    NSURLRequest *fallback = RewindRequestForEndpoint(
        RewindEndpointFallback, @"https://youtubei.googleapis.com", @"67",
        RewindClientVersion,
        @"Mozilla/5.0 (iPhone; CPU iOS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
        @"browse", _apiKey, body, &fallbackError);
    if (!request) {
        completion(nil, nil, nil, NO, nil, error);
        return;
    }
    RewindSendRequest(request, fallback, ^(id decoded, NSError *networkError) {
        if (networkError) {
            completion(nil, nil, nil, NO, nil, networkError);
            return;
        }
        RewindDecodeResponse(decoded, ^(id root, NSError *jsonError) {
            if (jsonError) {
                completion(nil, nil, nil, NO, nil, jsonError);
                return;
            }
            [RewindMetadataQueue() addOperationWithBlock:^{
                NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
                NSString *name = RewindFindTextForKey(root, @"title");
                // prefer true channel avatar urls over album art
                NSString *avatar = RewindBestAvatarThumbnail(root);
                if (!avatar.length) avatar = RewindHeaderThumbnail(root);
                if (!avatar.length) avatar = RewindThumbnail(root);
                NSString *subscribers = RewindFindTextForKey(root, @"subscriberCountText");
                NSDictionary *subscribeButton = RewindDict(RewindFindValueForKey(root, @"subscribeButtonRenderer", 0));
                BOOL subscribed = [[subscribeButton objectForKey:@"subscribed"] boolValue];
                NSArray *shelves = RewindShelvesFromRoot(root);
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(name, avatar, subscribers, subscribed, shelves, nil);
                });
                [pool drain];
            }];
        });
    });
}

static BOOL RewindUnsigned(id value, uint64_t *out) {
    NSString *text = [value isKindOfClass:[NSNumber class]] ? [value stringValue] : RewindString(value);
    const char *p = [text UTF8String];
    uint64_t number = 0;
    if (!p || !*p) return NO;
    while (*p) {
        if (*p < '0' || *p > '9' || number > (UINT64_MAX - (unsigned)(*p - '0')) / 10) return NO;
        number = number * 10 + (unsigned)(*p++ - '0');
    }
    *out = number;
    return YES;
}

static uint64_t RewindFormatBitrate(NSDictionary *format) {
    uint64_t value = 0;
    RewindUnsigned([format objectForKey:@"bitrate"], &value);
    return value;
}

static NSData *RewindAudioRange(NSURL *url, NSString *userAgent, uint64_t start, uint64_t end,
                                uint64_t *total, NSError **error, RewindAudioRequest *audioRequest) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:8.0];
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:[NSString stringWithFormat:@"bytes=%llu-%llu", (unsigned long long)start,
                      (unsigned long long)end] forHTTPHeaderField:@"Range"];
    NSHTTPURLResponse *response = nil;
    NSData *data = RewindHTTPFetchCancellable(request, (NSUInteger)(end - start + 1), &response, error, ^{ return audioRequest.cancelled; });
    if (!data) return nil;
    if (response.statusCode != 206 ||
        !rewind_audio_content_range([RewindHTTPHeader(response, @"Content-Range") UTF8String],
                                    start, end, data.length, total)) {
        if (error) *error = RewindError(response.statusCode == 403 ? 24 : 8,
                                      [NSString stringWithFormat:@"audio range answered HTTP %ld or wrong bytes",
                                       (long)response.statusCode]);
        return nil;
    }
    return data;
}

static BOOL RewindProbeAudioFile(NSURL *source, NSDictionary *format, NSString *userAgent, NSError **error, RewindAudioRequest *audioRequest) {
    uint64_t declared = 0, total = 0;
    if (![@"https" isEqualToString:[source.scheme lowercaseString]] ||
        (RewindUnsigned([format objectForKey:@"contentLength"], &declared) &&
         (declared < 24 || declared > 512ULL * 1024 * 1024))) {
        if (error) *error = RewindError(8, @"audio format has no valid secure file length");
        return NO;
    }
    uint64_t count = declared ? MIN(declared, 1024ULL) : 1024;
    /* a declared length gives the tail range up front, so both probes cost one round trip; a stalled
       cdn answered each after the 8s timeout in turn */
    __block NSData *tail = nil;
    __block uint64_t tailTotal = 0;
    __block NSError *tailError = nil;
    dispatch_group_t group = dispatch_group_create();
    if (declared) {
        dispatch_group_async(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
            NSError *failure = nil;
            NSData *bytes = RewindAudioRange(source, userAgent, declared - count, declared - 1, &tailTotal, &failure, audioRequest);
            tail = [bytes retain];
            tailError = [failure retain];
            [pool drain];
        });
    }
    NSError *headError = nil;
    NSData *head = RewindAudioRange(source, userAgent, 0, count - 1, &total, &headError, audioRequest);
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    dispatch_release(group);
    [tail autorelease];
    [tailError autorelease];
    if (!head) {
        if (error) *error = headError;
        return NO;
    }
    if ((declared && total != declared) || total > 512ULL * 1024 * 1024 || !rewind_audio_mp4(head.bytes, head.length)) {
        if (error) *error = RewindError(8, @"audio response is not the requested MP4 file");
        return NO;
    }
    /* vr can serve the first minute and deny every later range without a po token */
    if (!declared) tail = RewindAudioRange(source, userAgent, total - count, total - 1, &tailTotal, &tailError, audioRequest);
    if (!tail) {
        if (error) *error = tailError;
        return NO;
    }
    if (tailTotal != total) {
        if (error) *error = RewindError(8, @"audio file changed between byte ranges");
        return NO;
    }
    return YES;
}

static NSURL *RewindProbeHLS(NSURL *source, NSString *userAgent, NSError **error, RewindAudioRequest *audioRequest) {
    if (![@"https" isEqualToString:[source.scheme lowercaseString]]) {
        if (error) *error = RewindError(8, @"HLS source must use HTTPS");
        return nil;
    }
    NSUInteger depth;
    for (depth = 0; depth < 3; ++depth) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:source
                                                              cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                          timeoutInterval:8.0];
        [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
        [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
        NSHTTPURLResponse *response = nil;
        NSData *data = RewindHTTPFetchCancellable(request, 512 * 1024, &response, error, ^{ return audioRequest.cancelled; });
        if (!data) return nil;
        char first[8192], last[8192];
        rewind_audio_hls_kind_t kind = response.statusCode == 200
            ? rewind_audio_hls(data.bytes, data.length, first, sizeof(first), last, sizeof(last))
            : REWIND_AUDIO_HLS_INVALID;
        if (kind == REWIND_AUDIO_HLS_INVALID) break;
        source = response.URL;
        NSURL *firstURL = [[NSURL URLWithString:[NSString stringWithUTF8String:first] relativeToURL:source] absoluteURL];
        if (![@"https" isEqualToString:[firstURL.scheme lowercaseString]]) break;
        if (kind == REWIND_AUDIO_HLS_MASTER) {
            source = firstURL;
            continue;
        }
        NSURL *lastURL = [[NSURL URLWithString:[NSString stringWithUTF8String:last] relativeToURL:source] absoluteURL];
        if (![@"https" isEqualToString:[lastURL.scheme lowercaseString]]) break;
        for (NSURL *segment in [NSArray arrayWithObjects:firstURL, lastURL, nil]) {
            [request setURL:segment];
            NSData *bytes = RewindHTTPFetchCancellable(request, 2 * 1024 * 1024, &response, error, ^{ return audioRequest.cancelled; });
            if (!bytes) return nil;
            if (response.statusCode != 200 || !rewind_audio_segment(bytes.bytes, bytes.length)) {
                if (error) *error = RewindError(response.statusCode == 403 ? 24 : 8,
                                              @"HLS segment did not contain playable audio");
                return nil;
            }
        }
        return source;
    }
    if (error) *error = RewindError(8, @"HLS response has no complete AAC playlist");
    return nil;
}

static NSArray *RewindAudioCandidates(id root, NSString *clientName, NSSet *excluded, BOOL stream) {
    NSDictionary *streaming = RewindDict([RewindDict(root) objectForKey:@"streamingData"]);
    NSMutableArray *audio = [NSMutableArray array], *candidates = [NSMutableArray array];
    for (id value in RewindArray([streaming objectForKey:@"adaptiveFormats"])) {
        NSDictionary *format = RewindDict(value);
        NSString *mime = RewindString([format objectForKey:@"mimeType"]);
        if (![mime hasPrefix:@"audio/mp4"] || [mime rangeOfString:@"mp4a."].location == NSNotFound ||
            !RewindString([format objectForKey:@"url"]).length ||
            [format objectForKey:@"drmFamilies"]) continue;
        [audio addObject:format];
    }
    [audio sortUsingComparator:^NSComparisonResult(id a, id b) {
        uint64_t x = RewindFormatBitrate(a), y = RewindFormatBitrate(b);
        return x > y ? NSOrderedAscending : (x < y ? NSOrderedDescending : NSOrderedSame);
    }];
    NSUInteger count = 0;
    for (NSDictionary *format in audio) {
        uint64_t itag = 0;
        if (!RewindUnsigned([format objectForKey:@"itag"], &itag) || ++count > 3) continue;
        NSString *key = [NSString stringWithFormat:@"%@:%llu", clientName, (unsigned long long)itag];
        if (![excluded containsObject:key])
            [candidates addObject:[NSDictionary dictionaryWithObjectsAndKeys:format, @"format", key, @"key", nil]];
    }
    NSString *hls = RewindString([streaming objectForKey:@"hlsManifestUrl"]);
    NSString *hlsKey = [clientName stringByAppendingString:@":hls"];
    if (stream && hls.length && ![excluded containsObject:hlsKey])
        [candidates addObject:[NSDictionary dictionaryWithObjectsAndKeys:hls, @"hls", hlsKey, @"key", nil]];
    NSDictionary *progressive = nil;
    for (id value in RewindArray([streaming objectForKey:@"formats"])) {
        NSDictionary *format = RewindDict(value);
        NSString *mime = RewindString([format objectForKey:@"mimeType"]);
        if (![mime hasPrefix:@"video/mp4"] ||
            [mime rangeOfString:@"mp4a."].location == NSNotFound ||
            !RewindString([format objectForKey:@"url"]).length || [format objectForKey:@"drmFamilies"]) continue;
        if (!progressive || RewindFormatBitrate(format) < RewindFormatBitrate(progressive)) progressive = format;
    }
    NSString *key = [clientName stringByAppendingString:@":progressive"];
    if (progressive && ![excluded containsObject:key])
        [candidates addObject:[NSDictionary dictionaryWithObjectsAndKeys:progressive, @"format", key, @"key", nil]];
    /* a validated format is a preference, every other format remains a fallback */
    NSString *preferred = RewindPreferredAudioSource();
    for (NSUInteger i = 0; i < candidates.count; ++i) {
        NSDictionary *candidate = [candidates objectAtIndex:i];
        if ([[candidate objectForKey:@"key"] isEqualToString:preferred]) {
            [[candidate retain] autorelease];
            [candidates removeObjectAtIndex:i];
            [candidates insertObject:candidate atIndex:0];
            break;
        }
    }
    return candidates;
}

static BOOL RewindNeedsPlainM4A(void) {
    /* ios 5 and 6 cannot play the youtube fragmented aac file through avplayer */
    return [[[UIDevice currentDevice] systemVersion] integerValue] < 7;
}

static void RewindDurationWithPlayerClient(NSString *videoID,
                                              NSString *apiKey,
                                              NSString *clientName,
                                              NSString *clientVersion,
                                              NSString *clientHeaderName,
                                              NSString *userAgent,
                                              RewindDurationCompletion completion) {
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          RewindPlayerContext(clientName, clientVersion), @"context",
                          videoID, @"videoId",
                          @YES, @"contentCheckOk",
                          @YES, @"racyCheckOk",
                          nil];
    NSError *error = nil;
    NSURLRequest *request = RewindRequestForEndpoint(RewindPlayerEndpoint,
                                                       @"https://www.youtube.com",
                                                       clientHeaderName,
                                                       clientVersion,
                                                       userAgent,
                                                       @"player",
                                                       apiKey,
                                                       body,
                                                       &error);
    NSError *fallbackError = nil;
    NSURLRequest *fallbackRequest = RewindRequestForEndpoint(
        RewindPlayerEndpointFallback, @"https://youtubei.googleapis.com",
        clientHeaderName, clientVersion, userAgent, @"player", apiKey, body,
        &fallbackError);
    if (!request) {
        completion(0, error);
        return;
    }

    RewindSendRequest(request, fallbackRequest, ^(id decoded, NSError *networkError) {
        if (networkError) {
            completion(0, networkError);
            return;
        }
        RewindDecodeResponse(decoded, ^(id root, NSError *jsonError) {
            if (jsonError) {
                completion(0, jsonError);
                return;
            }
            NSDictionary *details = [root isKindOfClass:[NSDictionary class]]
                ? [(NSDictionary *)root objectForKey:@"videoDetails"] : nil;
            NSString *length = RewindString([details objectForKey:@"lengthSeconds"]);
            NSUInteger duration = (NSUInteger)[length integerValue];
            if (!duration) {
                NSDictionary *microformat = [root isKindOfClass:[NSDictionary class]]
                    ? [(NSDictionary *)root objectForKey:@"microformat"] : nil;
                NSDictionary *renderer = [microformat objectForKey:@"playerMicroformatRenderer"];
                duration = (NSUInteger)[RewindString([renderer objectForKey:@"lengthSeconds"]) integerValue];
            }
            if (duration) {
                completion(duration, nil);
            } else {
                completion(0, RewindError(16, @"track duration is missing"));
            }
        });
    });
}

/* playback problems on old phones leave nothing in syslog; keep the last runs in a file */
void RewindDebugLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *text = [[[NSString alloc] initWithFormat:format arguments:args] autorelease];
    va_end(args);
    NSLog(@"rewind: %@", text);
    @synchronized ([NSFileManager class]) {
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Rewind"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                   attributes:nil error:NULL];
        NSString *path = [dir stringByAppendingPathComponent:@"debug.log"];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        if ([attrs fileSize] > 256 * 1024) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        FILE *file = fopen([path fileSystemRepresentation], "a");
        if (file) {
            fprintf(file, "%s %s\n", [[[NSDate date] description] UTF8String], [text UTF8String]);
            fclose(file);
        }
    }
}

#pragma mark - sabr

/* SABR media headers carry the real timeline; SIDX declares the complete track */
static const NSUInteger RewindSABRWorkers = 6;
/* twenty seconds of audio, enough to start playing while the rest of the track downloads */
static const size_t RewindSABRPreviewSegments = 2;
/* fragments of the proxy preview: the first seconds, read before the index of the whole file is built */
static const size_t RewindStreamPreviewFragments = 3;
static const NSTimeInterval RewindSABRDeadline = 30.0;

static BOOL RewindBestAudioFormatID(id root, int32_t *itag, uint64_t *lastModified) {
    NSDictionary *streaming = RewindDict([RewindDict(root) objectForKey:@"streamingData"]);
    uint64_t bestBitrate = 0, selectedItag = 0, selectedModified = 0;
    for (id value in RewindArray([streaming objectForKey:@"adaptiveFormats"])) {
        NSDictionary *format = RewindDict(value);
        NSString *mime = RewindString([format objectForKey:@"mimeType"]);
        uint64_t bitrate = 0, formatItag = 0, modified = 0;
        if (![mime hasPrefix:@"audio/mp4"] || [mime rangeOfString:@"mp4a."].location == NSNotFound ||
            !RewindUnsigned([format objectForKey:@"bitrate"], &bitrate) || !bitrate ||
            !RewindUnsigned([format objectForKey:@"itag"], &formatItag) || !formatItag || formatItag > INT32_MAX ||
            !RewindUnsigned([format objectForKey:@"lastModified"], &modified)) continue;
        if (bitrate > bestBitrate) {
            bestBitrate = bitrate;
            selectedItag = formatItag;
            selectedModified = modified;
        }
    }
    if (!bestBitrate) return NO;
    *itag = (int32_t)selectedItag;
    *lastModified = selectedModified;
    return YES;
}

/* the first request carries no claims, so the server sends the init segment and segment 1.
   claiming an initialized format there makes it skip the init segment for good. later requests
   claim segments 1..n as buffered and get segment n + 1, which lets several run at once */
static NSData *RewindSABRRequestBody(RewindSABRSession *session, const rewind_sabr_request_t *request) {
    uint8_t clientInfoBuf[256];
    uint8_t streamerCtxBuf[512];
    uint8_t formatIdBuf[32];
    uint8_t clientAbrBuf[32];
    uint8_t bufferedRangeBuf[64];
    uint8_t outerBuf[8192];
    rewind_pb_writer_t clientInfo, streamerCtx, formatId, clientAbr, bufferedRange, outer;
    NSString *locale = [NSString stringWithFormat:@"%@_US", RewindLanguageCode() ?: @"en"];
    const char *localeUTF8 = [locale UTF8String];
    const char *versionUTF8 = [session->clientVersion UTF8String];
    const char *osNameUTF8 = [session->osName UTF8String];
    const char *osVersionUTF8 = [session->osVersion UTF8String];

    rewind_pb_writer_init(&clientInfo, clientInfoBuf, sizeof(clientInfoBuf));
    rewind_pb_write_string_field(&clientInfo, 1, localeUTF8, strlen(localeUTF8));
    rewind_pb_write_varint_field(&clientInfo, 16, (uint64_t)session->clientNameNumber);
    rewind_pb_write_string_field(&clientInfo, 17, versionUTF8, strlen(versionUTF8));
    rewind_pb_write_string_field(&clientInfo, 18, osNameUTF8, strlen(osNameUTF8));
    rewind_pb_write_string_field(&clientInfo, 19, osVersionUTF8, strlen(osVersionUTF8));

    rewind_pb_writer_init(&streamerCtx, streamerCtxBuf, sizeof(streamerCtxBuf));
    rewind_pb_write_message_field(&streamerCtx, 1, &clientInfo);

    rewind_pb_writer_init(&formatId, formatIdBuf, sizeof(formatIdBuf));
    rewind_pb_write_varint_field(&formatId, 1, (uint64_t)session->itag);
    if (session->lastModified) rewind_pb_write_varint_field(&formatId, 2, session->lastModified);

    rewind_pb_writer_init(&clientAbr, clientAbrBuf, sizeof(clientAbrBuf));
    rewind_pb_write_varint_field(&clientAbr, 28, (uint64_t)request->claimed_ms);
    rewind_pb_write_varint_field(&clientAbr, 34, 1); /* foreground visibility */
    rewind_pb_write_varint_field(&clientAbr, 40, 1); /* enabled_track_types_bitfield: audio only */

    rewind_pb_writer_init(&outer, outerBuf, sizeof(outerBuf));
    BOOL ok = rewind_pb_write_message_field(&outer, 1, &clientAbr);
    if (ok && request->segment) {
        rewind_pb_writer_init(&bufferedRange, bufferedRangeBuf, sizeof(bufferedRangeBuf));
        rewind_pb_write_message_field(&bufferedRange, 1, &formatId);
        rewind_pb_write_varint_field(&bufferedRange, 2, 0);                              /* start_time_ms */
        rewind_pb_write_varint_field(&bufferedRange, 3, (uint64_t)request->claimed_ms);  /* duration_ms */
        rewind_pb_write_varint_field(&bufferedRange, 4, request->claimed_segments ? 1 : 0);
        rewind_pb_write_varint_field(&bufferedRange, 5, (uint64_t)request->claimed_segments);
        ok = rewind_pb_write_message_field(&outer, 2, &formatId) &&                      /* initialized_format_ids */
             rewind_pb_write_message_field(&outer, 3, &bufferedRange);
    }
    if (!ok ||
        !rewind_pb_write_message_field(&outer, 16, &formatId) ||  /* selected_audio_format_ids */
        !rewind_pb_write_message_field(&outer, 19, &streamerCtx) ||
        !rewind_pb_write_string_field(&outer, 5, (const char *)session->ustreamerConfig.bytes, session->ustreamerConfig.length))
        return nil;

    return [NSData dataWithBytes:outer.buf length:outer.len];
}

static BOOL RewindSABRWriteBytes(int fd, const uint8_t *bytes, size_t length) {
    while (length) {
        ssize_t written = write(fd, bytes, length);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        bytes += (size_t)written;
        length -= (size_t)written;
    }
    return YES;
}

static NSURL *RewindSABRWriteFile(const rewind_fmp4_t *file, const uint8_t *bytes, NSError **error) {
    size_t headerLength = 0;
    const uint8_t *header = rewind_fmp4_header(file, &headerLength);
    if (!header || !bytes) {
        if (error) *error = RewindError(21, @"sabr audio is incomplete");
        return nil;
    }
    NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rewind-sabr-XXXXXX"];
    char *templatePath = strdup([pattern fileSystemRepresentation]);
    int fd = templatePath ? mkstemp(templatePath) : -1;
    if (fd < 0) {
        free(templatePath);
        if (error) *error = RewindError(21, @"sabr audio file could not be created");
        return nil;
    }
    NSString *path = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:templatePath
                                                                                length:strlen(templatePath)];
    BOOL written = path && RewindSABRWriteBytes(fd, header, headerLength);
    for (size_t i = 0; written && i < rewind_fmp4_chunk_count(file); ++i) {
        const rewind_fmp4_chunk_t *chunk = rewind_fmp4_chunk(file, i);
        written = RewindSABRWriteBytes(fd, bytes + chunk->source_offset, (size_t)chunk->length);
    }
    if (close(fd) != 0) written = NO;
    if (!written) {
        if (unlink(templatePath) != 0) RewindDebugLog(@"sabr incomplete file cleanup: %s", strerror(errno));
        if (error) *error = RewindError(21, @"sabr audio could not be saved");
    }
    free(templatePath);
    return written ? [NSURL fileURLWithPath:path] : nil;
}

static NSURL *RewindSABRWriteLocalFile(rewind_sabr_t *audio, NSError **error) {
    return RewindSABRWriteFile(rewind_sabr_file(audio), rewind_sabr_source(audio), error);
}

static NSString *const RewindSABRHostDefaultsKey = @"RewindSABRHost";

static void RewindWarmConnection(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    [RewindMetadataQueue() addOperationWithBlock:^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:8.0];
        [request setHTTPMethod:@"HEAD"];
        NSHTTPURLResponse *response = nil;
        NSError *error = nil;
        /* the answer is irrelevant, the open connection and the cached tls session are the point */
        RewindHTTPFetch(request, 4096, &response, &error);
        [pool drain];
    }];
}

void RewindWarmPlaybackConnections(void) {
    static NSDate *last;
    if (last && -[last timeIntervalSinceNow] < 20.0) return;
    [last release];
    last = [[NSDate alloc] init];
    RewindWarmConnection(@"https://www.youtube.com/generate_204");
    NSString *host = [[NSUserDefaults standardUserDefaults] stringForKey:RewindSABRHostDefaultsKey];
    if (host.length) RewindWarmConnection([NSString stringWithFormat:@"https://%@/generate_204", host]);
}

static void RewindSABRFail(RewindSABRSession *session, NSError *error) {
    if (session->finished || session->request.cancelled) return;
    session->finished = YES;
    RewindDebugLog(@"sabr failed after %.1fs: %@", -[session->started timeIntervalSinceNow], error);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (session->request.cancelled) return;
        /* the preview already plays, so the failure belongs to the upgrade that will not come */
        if (session->previewDelivered) {
            if (session->request.onUpgrade) session->request.onUpgrade(nil, error);
        } else session->completion(nil, error);
    });
}

/* the first seconds as a short playable file, delivered through the normal completion */
static void RewindSABRDeliverPreview(RewindSABRSession *session) {
    rewind_fmp4_t *prefix = rewind_sabr_prefix(session->audio, RewindSABRPreviewSegments);
    if (!prefix) return;
    NSError *error = nil;
    NSURL *url = RewindSABRWriteFile(prefix, rewind_sabr_data(session->audio), &error);
    rewind_fmp4_free(prefix);
    if (!url) {
        RewindDebugLog(@"sabr preview failed: %@", error);
        return;
    }
    session->previewDelivered = YES;
    session->request.upgradeExpected = YES;
    RewindRegisterAudioSource(url, session->userAgent, session->sourceKey);
    RewindDebugLog(@"sabr preview at %.1fs", -[session->started timeIntervalSinceNow]);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!session->request.cancelled) session->completion(url, nil);
        else [[NSFileManager defaultManager] removeItemAtPath:url.path error:NULL];
    });
}

static void RewindSABRFinish(RewindSABRSession *session) {
    NSError *fileError = nil;
    NSURL *localURL = RewindSABRWriteLocalFile(session->audio, &fileError);
    if (localURL) {
        session->finished = YES;
        RewindDebugLog(@"sabr ready in %.1fs, %lu segments", -[session->started timeIntervalSinceNow],
                       (unsigned long)rewind_sabr_have_count(session->audio));
        RewindRegisterAudioSource(localURL, session->userAgent, session->sourceKey);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (session->request.cancelled) {
                [[NSFileManager defaultManager] removeItemAtPath:localURL.path error:NULL];
            } else if (session->previewDelivered) {
                if (session->request.onUpgrade) session->request.onUpgrade(localURL, nil);
                else [[NSFileManager defaultManager] removeItemAtPath:localURL.path error:NULL];
            } else session->completion(localURL, nil);
        });
    } else RewindSABRFail(session, fileError);
}

static void RewindSABRWorker(RewindSABRSession *session);

/* the planner and the feed are not thread safe, every touch holds the session lock */
static void RewindSABRSpawnWorkers(RewindSABRSession *session, NSUInteger count) {
    for (NSUInteger i = 0; i < count; ++i)
        [RewindNetworkQueue() addOperationWithBlock:^{
            NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
            RewindSABRWorker(session);
            [pool drain];
        }];
}

static void RewindSABRWorker(RewindSABRSession *session) {
    for (;;) {
        rewind_sabr_request_t next;
        NSMutableURLRequest *request;
        @synchronized (session) {
            if (session->finished || session->request.cancelled) return;
            if (-[session->started timeIntervalSinceNow] > RewindSABRDeadline) {
                RewindSABRFail(session, session->lastError ?: RewindError(20, @"sabr track took too long to finish"));
                return;
            }
            rewind_sabr_plan_t plan = rewind_sabr_next_request(session->audio, &next);
            if (plan == REWIND_SABR_PLAN_EXHAUSTED) {
                RewindSABRFail(session, session->lastError ?:
                               RewindError(20, @"sabr server stopped before the track was complete"));
                return;
            }
            /* nothing to ask while other requests are out, whoever finishes last asks again */
            if (plan != REWIND_SABR_PLAN_REQUEST) return;
            NSData *body = RewindSABRRequestBody(session, &next);
            if (!body) {
                rewind_sabr_request_done(session->audio, &next);
                RewindSABRFail(session, RewindError(20, @"sabr request could not be built"));
                return;
            }
            request = [[[NSMutableURLRequest alloc] initWithURL:session->sabrURL] autorelease];
            [request setHTTPMethod:@"POST"];
            [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
            [request setValue:session->userAgent forHTTPHeaderField:@"User-Agent"];
            [request setHTTPBody:body];
            [request setTimeoutInterval:20.0];
        }
        NSHTTPURLResponse *response = nil;
        NSError *networkError = nil;
        NSDate *requestStarted = [NSDate date];
        NSData *data = RewindHTTPFetchCancellable(request, 4 * 1024 * 1024, &response, &networkError,
                                                  ^BOOL { return session->request.cancelled ||
                                                      -[session->started timeIntervalSinceNow] >= RewindSABRDeadline; });
        RewindDebugLog(@"sabr segment %lld: %.2fs, %lu bytes at %.2fs", (long long)next.segment,
                       -[requestStarted timeIntervalSinceNow], (unsigned long)data.length,
                       -[session->started timeIntervalSinceNow]);
        if (!networkError && response.statusCode != 200)
            networkError = RewindError(20, @"sabr endpoint rejected the request");
        BOOL bootstrapped = NO;
        @synchronized (session) {
            if (session->finished || session->request.cancelled) return;
            rewind_sabr_status_t status = REWIND_SABR_NO_PROGRESS;
            char redirectURL[8192] = "";
            if (!networkError && data.length)
                status = rewind_sabr_feed(session->audio, data.bytes, data.length, redirectURL, sizeof(redirectURL));
            else if (!networkError) networkError = RewindError(20, @"sabr endpoint returned no data");
            rewind_sabr_request_done(session->audio, &next);
            if (networkError) {
                /* a failed segment goes back to the planner, which gives up after its attempts */
                RewindDebugLog(@"sabr request for segment %lld failed: %@", (long long)next.segment, networkError);
                [session->lastError release];
                session->lastError = [networkError retain];
                continue;
            }
            if (status == REWIND_SABR_AUTH_REQUIRED) {
                RewindSABRFail(session, RewindError(22, @"youtube requires proof of origin for this stream"));
                return;
            }
            if (status == REWIND_SABR_INVALID || status == REWIND_SABR_REMOTE_ERROR || status == REWIND_SABR_NO_MEMORY) {
                RewindSABRFail(session, RewindError(20, status == REWIND_SABR_REMOTE_ERROR
                    ? @"sabr server rejected the stream" : @"sabr audio is malformed or exceeds its limits"));
                return;
            }
            if (redirectURL[0]) {
                NSURL *redirect = [NSURL URLWithString:[NSString stringWithUTF8String:redirectURL]];
                if (![@"https" isEqualToString:[redirect.scheme lowercaseString]] || !redirect.host.length) {
                    RewindSABRFail(session, RewindError(20, @"sabr redirect url is invalid"));
                    return;
                }
                [session->sabrURL release];
                session->sabrURL = [redirect retain];
            }
            if (status == REWIND_SABR_READY) {
                RewindSABRFinish(session);
                return;
            }
            /* the init segment tells how many segments exist, only now can they be fetched side by side */
            bootstrapped = next.segment == 0 && rewind_sabr_expected(session->audio) > 0;
            if (!session->previewDelivered && session->request.allowsPreview &&
                rewind_sabr_expected(session->audio) > RewindSABRPreviewSegments &&
                rewind_sabr_contiguous(session->audio) >= RewindSABRPreviewSegments)
                RewindSABRDeliverPreview(session);
        }
        if (bootstrapped) RewindSABRSpawnWorkers(session, RewindSABRWorkers - 1);
    }
}

static void RewindSABRAudioURL(id root, NSString *clientName, NSString *clientVersion,
                               NSString *clientHeaderName, NSString *userAgent,
                               RewindAudioRequest *audioRequest,
                               RewindAudioCompletion completion) {
    NSDictionary *streaming = RewindDict([RewindDict(root) objectForKey:@"streamingData"]);
    NSString *sabrURLString = RewindString([streaming objectForKey:@"serverAbrStreamingUrl"]);
    NSString *configB64 = RewindFindTextForKey(root, @"videoPlaybackUstreamerConfig");
    int32_t itag = 0;
    uint64_t lastModified = 0;
    NSURL *sabrURL;
    NSData *config;
    const char *configUTF8;
    uint8_t configBuf[8192];
    size_t configLen = 0;

    if (!sabrURLString.length || !configB64.length ||
        !RewindBestAudioFormatID(root, &itag, &lastModified)) {
        RewindDebugLog(@"sabr unavailable: url %d config %d format %d", (int)sabrURLString.length, (int)configB64.length,
                       RewindBestAudioFormatID(root, &itag, &lastModified));
        completion(nil, RewindError(20, @"no sabr stream available"));
        return;
    }
    sabrURL = [NSURL URLWithString:sabrURLString];
    if ([@"https" isEqualToString:[sabrURL.scheme lowercaseString]] && sabrURL.host.length)
        [[NSUserDefaults standardUserDefaults] setObject:sabrURL.host forKey:RewindSABRHostDefaultsKey];
    if (![@"https" isEqualToString:[sabrURL.scheme lowercaseString]] || !sabrURL.host.length) {
        completion(nil, RewindError(20, @"sabr stream url is invalid"));
        return;
    }
    configUTF8 = [configB64 UTF8String];
    if (!rewind_base64url_decode(configUTF8, strlen(configUTF8), configBuf, sizeof(configBuf), &configLen)) {
        completion(nil, RewindError(20, @"sabr stream config could not be decoded"));
        return;
    }
    config = [NSData dataWithBytes:configBuf length:configLen];

    NSDictionary *client = [RewindPlayerContext(clientName, clientVersion) objectForKey:@"client"];
    RewindSABRSession *session = [[[RewindSABRSession alloc] init] autorelease];
    session->sabrURL = [sabrURL retain];
    session->ustreamerConfig = [config retain];
    session->itag = itag;
    session->lastModified = lastModified;
    session->audio = rewind_sabr_create(itag);
    if (!session->audio) {
        completion(nil, RewindError(21, @"sabr audio could not be allocated"));
        return;
    }
    session->clientNameNumber = [clientHeaderName intValue];
    session->clientVersion = [clientVersion copy];
    session->osName = [[client objectForKey:@"osName"] copy];
    session->osVersion = [[client objectForKey:@"osVersion"] copy];
    session->userAgent = [userAgent copy];
    session->sourceKey = [[NSString stringWithFormat:@"%@:%@:sabr", clientName, clientVersion] copy];
    session->completion = [completion copy];
    session->request = [audioRequest retain];

    RewindSABRSpawnWorkers(session, 1);
}

static void RewindTryAudioCandidate(NSArray *candidates, NSUInteger index, NSString *userAgent,
                                    BOOL stream, NSError *lastError, RewindAudioRequest *audioRequest, RewindAudioCompletion completion) {
    if (audioRequest.cancelled) return;
    if (index >= candidates.count) {
        completion(nil, lastError);
        return;
    }
    NSDictionary *candidate = [candidates objectAtIndex:index];
    NSDictionary *format = [candidate objectForKey:@"format"];
    NSString *key = [candidate objectForKey:@"key"];
    NSString *hls = [candidate objectForKey:@"hls"];
    NSURL *source = [NSURL URLWithString:hls ?: RewindString([format objectForKey:@"url"])];
    BOOL needsProxy = stream && !hls && RewindNeedsPlainM4A() &&
        [RewindString([format objectForKey:@"mimeType"]) hasPrefix:@"audio/"];
    /* avplayer reads the file in the media server over a connection of its own, so the probe's two small ranges
       only delay it: on a slow link they cost 3 to 8 seconds and often ended in a timeout and the slower sabr
       source. the track being played starts at once and the probe runs beside it; a definitive refusal moves to
       the next candidate through the upgrade, a transport failure leaves avplayer to judge the file */
    if (source && !hls && !needsProxy && audioRequest.allowsPreview) {
        audioRequest.upgradeExpected = YES;
        RewindRegisterAudioSource(source, userAgent, key);
        RewindDebugLog(@"audio %@ started before validation", key);
        completion(source, nil);
        [RewindNetworkQueue() addOperationWithBlock:^{
            NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
            NSError *probeError = nil;
            BOOL valid = RewindProbeAudioFile(source, format, userAgent, &probeError, audioRequest);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (audioRequest.cancelled) return;
                if (valid || [probeError.domain isEqualToString:NSURLErrorDomain]) {
                    audioRequest.upgradeExpected = NO;
                    RewindDebugLog(@"audio %@ %@", key, valid ? @"validated" : [NSString stringWithFormat:@"probe inconclusive: %@", probeError]);
                    return;
                }
                RewindDebugLog(@"audio %@ rejected after start: %@", key, probeError);
                RewindTryAudioCandidate(candidates, index + 1, userAgent, stream, probeError, audioRequest,
                                        ^(NSURL *next, NSError *failure) {
                    if (audioRequest.cancelled) return;
                    if (audioRequest.onUpgrade) audioRequest.onUpgrade(next, next ? nil : failure);
                });
            });
            [pool drain];
        }];
        return;
    }
    [RewindNetworkQueue() addOperationWithBlock:^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSError *error = nil;
        NSURL *url = nil;
        if (hls) url = RewindProbeHLS(source, userAgent, &error, audioRequest);
        else if (RewindProbeAudioFile(source, format, userAgent, &error, audioRequest)) url = source;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (audioRequest.cancelled) return;
            __block BOOL previewDelivered = NO;
            void (^resolved)(NSURL *, NSError *) = ^(NSURL *prepared, NSError *failure) {
                if (audioRequest.cancelled) return;
                /* the preview already plays, so the complete file or its failure belongs to the upgrade */
                if (previewDelivered) {
                    if (prepared) RewindRegisterAudioSource(prepared, userAgent, key);
                    if (audioRequest.onUpgrade) audioRequest.onUpgrade(prepared, prepared ? nil : failure);
                    return;
                }
                if (prepared) {
                    RewindRegisterAudioSource(prepared, userAgent, key);
                    RewindDebugLog(@"audio %@ validated", key);
                    completion(prepared, nil);
                } else {
                    RewindDebugLog(@"audio %@ rejected: %@", key, failure);
                    RewindTryAudioCandidate(candidates, index + 1, userAgent, stream,
                                            failure ?: lastError, audioRequest, completion);
                }
            };
            if (url && needsProxy) {
                uint64_t indexEnd = 0;
                if (!RewindUnsigned([RewindDict([format objectForKey:@"indexRange"]) objectForKey:@"end"], &indexEnd) ||
                    !indexEnd || indexEnd >= 1024 * 1024) {
                    resolved(nil, RewindError(8, @"fragmented audio has no bounded index"));
                } else {
                    /* only the track being played starts from a preview; a prefetch or download waits for the whole file */
                    BOOL wantsPreview = audioRequest.allowsPreview;
                    RewindStreamPrepareProgressive(url, indexEnd, userAgent, wantsPreview ? RewindStreamPreviewFragments : 0,
                                                   ^{ return audioRequest.cancelled; },
                                                   wantsPreview ? ^(NSURL *early) {
                        if (audioRequest.cancelled || previewDelivered) return;
                        previewDelivered = YES;
                        audioRequest.upgradeExpected = YES;
                        RewindRegisterAudioSource(early, userAgent, key);
                        RewindDebugLog(@"audio %@ preview", key);
                        completion(early, nil);
                    } : nil, resolved);
                }
            } else {
                resolved(url, error);
            }
        });
        [pool drain];
    }];
}

static void RewindAudioURLWithPlayerClient(NSString *videoID, NSString *apiKey,
                                          NSString *clientName, NSString *clientVersion,
                                          NSString *clientHeaderName, NSString *userAgent,
                                          BOOL stream, NSSet *excluded, RewindAudioRequest *audioRequest,
                                          RewindAudioCompletion completion) {
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          RewindPlayerContext(clientName, clientVersion), @"context",
                          videoID, @"videoId", @YES, @"contentCheckOk", @YES, @"racyCheckOk", nil];
    NSError *error = nil;
    NSURLRequest *request = RewindRequestForEndpoint(RewindPlayerEndpoint, @"https://www.youtube.com",
                                                    clientHeaderName, clientVersion, userAgent,
                                                    @"player", apiKey, body, &error);
    NSURLRequest *fallback = RewindRequestForEndpoint(RewindPlayerEndpointFallback, @"https://youtubei.googleapis.com",
                                                     clientHeaderName, clientVersion, userAgent,
                                                     @"player", apiKey, body, NULL);
    if (!request) {
        completion(nil, error);
        return;
    }
    RewindSendRequestWithCancellation(request, fallback, audioRequest, ^(id root, NSError *networkError) {
        if (audioRequest.cancelled) return;
        if (networkError) {
            completion(nil, networkError);
            return;
        }
        NSDictionary *playability = RewindDict([RewindDict(root) objectForKey:@"playabilityStatus"]);
        NSString *status = RewindString([playability objectForKey:@"status"]);
        NSString *reason = RewindString([playability objectForKey:@"reason"]);
        RewindDebugLog(@"%@ player %@: status=%@ reason=%@", clientName, videoID, status, reason);
        if (![status isEqualToString:@"OK"]) {
            BOOL login = [status isEqualToString:@"LOGIN_REQUIRED"];
            BOOL bot = login && reason.length && [reason rangeOfString:@"bot" options:NSCaseInsensitiveSearch].location != NSNotFound;
            completion(nil, RewindError(bot ? 22 : (login ? 23 : 8), reason ?: @"player returned no playable audio"));
            return;
        }
        NSString *sourceClient = [NSString stringWithFormat:@"%@:%@", clientName, clientVersion];
        /* this client lists an hls manifest next to sabr, and a validated manifest would win before sabr is tried */
        NSString *sabrSourceKey = [sourceClient stringByAppendingString:@":sabr"];
        if (stream && [clientVersion isEqualToString:RewindIOSSABRClientVersion] &&
            ![excluded containsObject:sabrSourceKey] &&
            RewindString([RewindDict([RewindDict(root) objectForKey:@"streamingData"]) objectForKey:@"serverAbrStreamingUrl"]).length) {
            RewindSABRAudioURL(root, clientName, clientVersion, clientHeaderName, userAgent, audioRequest,
                              ^(NSURL *local, NSError *sabrError) {
                if (local) RewindRegisterAudioSource(local, userAgent, sabrSourceKey);
                completion(local, local ? nil : sabrError);
            });
            return;
        }
        NSArray *candidates = RewindAudioCandidates(root, sourceClient, excluded, stream);
        RewindTryAudioCandidate(candidates, 0, userAgent, stream, nil, audioRequest, ^(NSURL *url, NSError *failure) {
            if (url) {
                completion(url, nil);
                return;
            }
            NSString *sabrKey = [sourceClient stringByAppendingString:@":sabr"];
            NSDictionary *streaming = RewindDict([RewindDict(root) objectForKey:@"streamingData"]);
            if (stream && [clientVersion isEqualToString:RewindIOSSABRClientVersion] &&
                ![excluded containsObject:sabrKey] &&
                RewindString([streaming objectForKey:@"serverAbrStreamingUrl"]).length) {
                RewindSABRAudioURL(root, clientName, clientVersion, clientHeaderName, userAgent, audioRequest,
                                  ^(NSURL *local, NSError *sabrError) {
                    if (local) RewindRegisterAudioSource(local, userAgent, sabrKey);
                    completion(local, local ? nil : (sabrError ?: failure));
                });
            } else {
                completion(nil, failure ?: RewindError(8, @"player has no accessible AAC source"));
            }
        });
    });
}

/* plain playback asks android first: its progressive file is the one source that delivers a whole track
   (sabr stops answering with media after the first minute without a po token), and it is one player request
   and one probe. sabr follows only when android fails. downloads need plain urls, so their clients race and
   the first to deliver cancels the rest */
static void RewindResolveAudioClients(NSString *videoID, NSString *apiKey, BOOL stream, NSSet *excluded,
                                      RewindAudioRequest *audioRequest, RewindAudioCompletion completion) {
    if (audioRequest.cancelled) return;
    if (stream) {
        NSString *androidAgent = [[RewindPlayerContext(RewindAndroidClientName, RewindAndroidClientVersion)
                                   objectForKey:@"client"] objectForKey:@"userAgent"];
        NSString *sabrAgent = [[RewindPlayerContext(RewindIOSClientName, RewindIOSSABRClientVersion)
                                objectForKey:@"client"] objectForKey:@"userAgent"];
        RewindAudioURLWithPlayerClient(videoID, apiKey, RewindAndroidClientName, RewindAndroidClientVersion, @"3",
                                      androidAgent, stream, excluded, audioRequest,
                                      ^(NSURL *url, NSError *error) {
            if (url || audioRequest.cancelled) {
                completion(url, error);
                return;
            }
            RewindDebugLog(@"android audio failed for %@, trying sabr: %@", videoID, error);
            RewindAudioURLWithPlayerClient(videoID, apiKey, RewindIOSClientName, RewindIOSSABRClientVersion, @"5",
                                          sabrAgent, stream, excluded, audioRequest, completion);
        });
        return;
    }
    NSMutableArray *names = [NSMutableArray array], *versions = [NSMutableArray array], *headers = [NSMutableArray array];
    [names addObject:RewindIOSClientName];
    [versions addObject:RewindIOSClientVersion];
    [headers addObject:@"5"];
    [names addObject:RewindAndroidClientName];
    [versions addObject:RewindAndroidClientVersion];
    [headers addObject:@"3"];
    NSUInteger count = names.count;
    NSMutableArray *branches = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray *errors = [NSMutableArray arrayWithCapacity:count];
    __block NSUInteger pending = count;
    __block BOOL settled = NO;
    for (NSUInteger i = 0; i < count; ++i) {
        [branches addObject:[audioRequest branch]];
        [errors addObject:[NSNull null]];
    }
    for (NSUInteger i = 0; i < count; ++i) {
        NSString *name = [names objectAtIndex:i], *version = [versions objectAtIndex:i];
        NSString *userAgent = [[RewindPlayerContext(name, version) objectForKey:@"client"] objectForKey:@"userAgent"];
        RewindAudioRequest *branch = [branches objectAtIndex:i];
        RewindAudioURLWithPlayerClient(videoID, apiKey, name, version, [headers objectAtIndex:i], userAgent,
                                      stream, excluded, branch, ^(NSURL *url, NSError *error) {
            if (settled || audioRequest.cancelled) return;
            if (url) {
                audioRequest.upgradeExpected = branch.upgradeExpected;
            } else {
                if (error) [errors replaceObjectAtIndex:i withObject:error];
                if (--pending) return;
            }
            settled = YES;
            for (RewindAudioRequest *other in branches) if (other != branch) [other cancel];
            if (url) {
                completion(url, nil);
                return;
            }
            NSError *reported = nil;
            for (id value in errors) if (!reported && value != [NSNull null]) reported = value;
            completion(nil, reported ?: RewindError(8, @"no accessible audio source"));
        });
    }
}

static NSDictionary *RewindInvidiousFormat(id value, NSURL *server) {
    NSDictionary *input = RewindDict(value);
    NSString *urlString = RewindString([input objectForKey:@"url"]);
    NSString *mime = RewindString([input objectForKey:@"type"]);
    if (!urlString.length || urlString.length > 8192 || !mime.length || mime.length > 256) return nil;
    NSURL *url = [NSURL URLWithString:urlString];
    NSString *host = [url.host lowercaseString];
    uint64_t itag = 0, length = 0;
    if (![@"https" isEqualToString:[url.scheme lowercaseString]] || !host.length ||
        url.user.length || url.password.length || url.fragment.length ||
        (![[server.host lowercaseString] isEqualToString:host] && ![host hasSuffix:@".googlevideo.com"]) ||
        !mime.length || !RewindUnsigned([input objectForKey:@"itag"], &itag) || !itag || itag > INT32_MAX) return nil;
    NSMutableDictionary *format = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                   urlString, @"url", mime, @"mimeType",
                                   [NSNumber numberWithUnsignedLongLong:itag], @"itag", nil];
    uint64_t bitrate = 0;
    if (RewindUnsigned([input objectForKey:@"bitrate"], &bitrate))
        [format setObject:[NSNumber numberWithUnsignedLongLong:bitrate] forKey:@"bitrate"];
    if (RewindUnsigned([input objectForKey:@"clen"], &length)) {
        if (length < 24 || length > 512ULL * 1024 * 1024) return nil;
        [format setObject:[NSNumber numberWithUnsignedLongLong:length] forKey:@"contentLength"];
    }
    uint64_t start = 0, end = 0;
    if (rewind_audio_index_range([RewindString([input objectForKey:@"index"]) UTF8String], &start, &end) &&
        end < 1024 * 1024) {
        [format setObject:[NSDictionary dictionaryWithObjectsAndKeys:
                           [NSNumber numberWithUnsignedLongLong:start], @"start",
                           [NSNumber numberWithUnsignedLongLong:end], @"end", nil] forKey:@"indexRange"];
    }
    return format;
}

static void RewindAudioURLWithPublicServer(NSString *videoID, BOOL stream, NSSet *excluded,
                                           RewindAudioRequest *audioRequest, RewindAudioCompletion completion) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:REWIND_AUDIO_SERVER_DEFAULTS_KEY];
    NSString *base = stored ? RewindString(stored) : REWIND_AUDIO_SERVER_URL;
    if (!base.length || base.length > 2048) {
        completion(nil, RewindError(8, @"audio server origin is empty"));
        return;
    }
    NSURL *server = [NSURL URLWithString:base];
    if (![@"https" isEqualToString:[server.scheme lowercaseString]] || !server.host.length ||
        server.user.length || server.password.length || server.query.length || server.fragment.length ||
        (server.path.length && ![server.path isEqualToString:@"/"]) ||
        !rewind_audio_video_id([videoID UTF8String])) {
        completion(nil, RewindError(8, @"audio server or video id is invalid"));
        return;
    }
    NSString *sourceClient = [@"Invidious:" stringByAppendingString:server.absoluteString];
    NSString *path = [NSString stringWithFormat:@"/api/v1/videos/%@?local=false", videoID];
    NSURL *url = [NSURL URLWithString:path relativeToURL:server];
    NSString *userAgent = RewindPublicAudioUserAgent;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:8.0];
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    RewindSendRequestWithCancellation(request, nil, audioRequest, ^(id root, NSError *networkError) {
        if (audioRequest.cancelled) return;
        if (networkError) {
            completion(nil, networkError);
            return;
        }
        if (![RewindString([root objectForKey:@"videoId"]) isEqualToString:videoID]) {
            completion(nil, RewindError(8, RewindString([root objectForKey:@"error"]) ?: @"audio server returned a different track"));
            return;
        }
        NSMutableDictionary *streaming = [NSMutableDictionary dictionary];
        for (NSString *key in [NSArray arrayWithObjects:@"adaptiveFormats", @"formatStreams", nil]) {
            NSMutableArray *formats = [NSMutableArray array];
            for (id value in RewindArray([root objectForKey:key])) {
                NSDictionary *format = RewindInvidiousFormat(value, server);
                if (format) [formats addObject:format];
            }
            [streaming setObject:formats forKey:[key isEqualToString:@"formatStreams"] ? @"formats" : key];
        }
        NSDictionary *mapped = [NSDictionary dictionaryWithObject:streaming forKey:@"streamingData"];
        NSArray *candidates = RewindAudioCandidates(mapped, sourceClient, excluded, stream);
        RewindTryAudioCandidate(candidates, 0, userAgent, stream,
                                RewindError(8, @"audio server has no accessible AAC source"), audioRequest, completion);
    });
}

static void RewindResolveAudio(NSString *videoID, NSString *apiKey, BOOL stream, NSSet *excluded,
                               RewindAudioRequest *audioRequest, RewindAudioCompletion completion) {
    /* public Googlevideo links return 403 on the device even when the server API returns JSON */
    RewindResolveAudioClients(videoID, apiKey, stream, excluded, audioRequest, ^(NSURL *url, NSError *error) {
        if (audioRequest.cancelled) return;
        if (url) completion(url, nil);
        else {
            RewindDebugLog(@"native audio sources rejected %@: %@", videoID, error);
            /* the public server's googlevideo links are refused on the device, so it only backs downloads */
            if (stream) completion(nil, error);
            else RewindAudioURLWithPublicServer(videoID, stream, excluded, audioRequest, completion);
        }
    });
}

- (void)audioURLForTrack:(RewindTrack *)track completion:(RewindAudioCompletion)completion {
    if (!completion) return;
    if (!rewind_audio_video_id([track.videoID UTF8String])) {
        completion(nil, RewindError(6, @"track has no valid video id"));
        return;
    }
    RewindResolveAudio(track.videoID, _apiKey, NO, nil,
                              [[[RewindAudioRequest alloc] init] autorelease], completion);
}

- (void)streamURLForTrack:(RewindTrack *)track completion:(RewindAudioCompletion)completion {
    [self streamURLForTrack:track excludingSources:nil completion:completion];
}

- (RewindAudioRequest *)streamURLForTrack:(RewindTrack *)track excludingSources:(NSSet *)sources
              completion:(RewindAudioCompletion)completion {
    if (!completion) return nil;
    if (!rewind_audio_video_id([track.videoID UTF8String])) {
        completion(nil, RewindError(6, @"track has no valid video id"));
        return nil;
    }
    NSSet *excluded = [[sources copy] autorelease];
    RewindAudioRequest *request = [[[RewindAudioRequest alloc] init] autorelease];
    NSDictionary *cached = RewindCachedAudioURL(track.videoID, excluded);
    if (cached) {
        NSURL *url = [cached objectForKey:@"url"];
        RewindRegisterAudioSource(url, [cached objectForKey:@"userAgent"], [cached objectForKey:@"key"]);
        RewindDebugLog(@"audio %@ from cache", [cached objectForKey:@"key"]);
        /* the caller stores the returned request before its completion may run */
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!request.cancelled) completion(url, nil);
        });
        return request;
    }
    NSString *videoID = [[track.videoID copy] autorelease];
    RewindResolveAudio(track.videoID, _apiKey, YES, excluded, request, ^(NSURL *url, NSError *error) {
        if (url) RewindCacheAudioURL(videoID, url, RewindAudioUserAgentForURL(url), RewindAudioSourceKeyForURL(url));
        completion(url, error);
    });
    return request;
}

- (void)browseShelves:(NSString *)browseID params:(NSString *)params
           completion:(RewindShelvesCompletion)completion {
    if (!completion) return;
    if (!browseID.length) {
        completion(nil, nil, RewindError(17, @"page has no id"));
        return;
    }
    NSMutableDictionary *fields = [NSMutableDictionary dictionaryWithObject:browseID forKey:@"browseId"];
    if (params.length) [fields setObject:params forKey:@"params"];
    RewindWebCall(@"browse", _apiKey, fields, ^(NSDictionary *root, NSError *error) {
        if (error) {
            completion(nil, nil, error);
            return;
        }
        /* walking a home page is hundreds of nested dictionaries, on the main thread it froze a 4s */
        [RewindMetadataQueue() addOperationWithBlock:^{
            NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
            NSArray *shelves = RewindShelvesFromRoot(root);
            NSArray *chips = RewindChipsFromRoot(root);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(shelves, chips, shelves.count || chips.count ? nil : RewindError(18, @"page has no shelves"));
            });
            [pool drain];
        }];
    });
}

- (void)searchSuggestions:(NSString *)query completion:(RewindSuggestionsCompletion)completion {
    if (!completion) return;
    NSString *clean = RewindCleanText(query);
    if (!clean.length) {
        completion([NSArray array], nil);
        return;
    }
    RewindWebCall(@"music/get_search_suggestions", _apiKey,
                  [NSDictionary dictionaryWithObject:clean forKey:@"input"],
                  ^(NSDictionary *root, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSMutableArray *suggestions = [NSMutableArray array];
        NSMutableArray *renderers = [NSMutableArray array];
        RewindCollectValuesForKey(root, @"searchSuggestionRenderer", renderers, 0);
        for (id renderer in renderers) {
            NSString *text = RewindText([RewindDict(renderer) objectForKey:@"suggestion"]);
            if (text.length && ![suggestions containsObject:text]) [suggestions addObject:text];
            if (suggestions.count >= 8) break;
        }
        completion(suggestions, nil);
    });
}

static NSDictionary *RewindWatchFields(RewindTrack *track) {
    return [NSDictionary dictionaryWithObjectsAndKeys:
                            track.videoID, @"videoId", [@"RDAMVM" stringByAppendingString:track.videoID], @"playlistId",
                            @YES, @"isAudioOnly", @YES, @"enablePersistentPlaylistPanel",
                            @"AUTOMIX_SETTING_NORMAL", @"tunerSettingValue",
                            [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                @YES, @"hasPersistentPlaylistPanel", @"MUSIC_VIDEO_TYPE_ATV", @"musicVideoType", nil]
                                forKey:@"watchEndpointMusicConfig"], @"watchEndpointMusicSupportedConfigs", nil];
}

- (void)watchTabForTrack:(RewindTrack *)track prefix:(NSString *)prefix
              completion:(void (^)(NSString *browseID, NSError *error))completion {
    if (!rewind_audio_video_id([track.videoID UTF8String])) {
        completion(nil, RewindError(6, @"track has no valid video id"));
        return;
    }
    RewindWebCall(@"next", _apiKey, RewindWatchFields(track), ^(NSDictionary *root, NSError *error) {
        NSString *browseID = error ? nil : RewindWatchTabBrowseID(root, prefix);
        completion(browseID, error ? error : (browseID ? nil : RewindError(19, @"track watch tab is unavailable")));
    });
}

static RewindLyrics *RewindTimedLyrics(NSDictionary *root) {
    NSDictionary *data = RewindDict(RewindFindValueForKey(root, @"lyricsData", 0));
    NSMutableArray *lines = [NSMutableArray array];
    BOOL timed = YES;
    NSUInteger previous = 0;
    for (id entry in RewindArray([data objectForKey:@"timedLyricsData"])) {
        if (lines.count >= 500) break;
        NSDictionary *line = RewindDict(entry);
        NSString *text = RewindString([line objectForKey:@"lyricLine"]);
        NSDictionary *cue = RewindDict([line objectForKey:@"cueRange"]);
        id start = [cue objectForKey:@"startTimeMilliseconds"];
        if (!text) continue;
        uint64_t ms = 0;
        if (!RewindUnsigned(start, &ms) || ms > 24ULL * 3600 * 1000 || ms < previous) {
            timed = NO;
            ms = 0;
        }
        previous = (NSUInteger)ms;
        RewindLyricLine *parsed = [[RewindLyricLine alloc] initWithText:text startMS:(NSUInteger)ms];
        [lines addObject:parsed];
        [parsed release];
    }
    if (!lines.count) return nil;
    NSString *source = RewindText([data objectForKey:@"sourceMessage"]) ?:
                       RewindString([data objectForKey:@"sourceMessage"]);
    return [[[RewindLyrics alloc] initWithLines:lines timed:timed source:source] autorelease];
}

static RewindLyrics *RewindPlainLyrics(NSDictionary *root) {
    NSDictionary *shelf = RewindDict(RewindFindValueForKey(root, @"musicDescriptionShelfRenderer", 0));
    NSString *text = RewindText([shelf objectForKey:@"description"]);
    if (!text.length) return nil;
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *part in [text componentsSeparatedByString:@"\n"]) {
        if (lines.count >= 500) break;
        RewindLyricLine *line = [[RewindLyricLine alloc] initWithText:part startMS:0];
        [lines addObject:line];
        [line release];
    }
    return [[[RewindLyrics alloc] initWithLines:lines timed:NO
                                         source:RewindText([shelf objectForKey:@"footer"])] autorelease];
}

- (void)lyricsForTrack:(RewindTrack *)track completion:(RewindLyricsCompletion)completion {
    if (!completion) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self lyricsForTrack:track completion:completion]; });
        return;
    }
    NSString *apiKey = [[_apiKey copy] autorelease];
    [self watchTabForTrack:track prefix:@"MPLY" completion:^(NSString *browseID, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        /* only the music apps' client gets line timings; the web page carries plain text */
        NSDictionary *client = [NSDictionary dictionaryWithObjectsAndKeys:
                                RewindAndroidMusicClientName, @"clientName",
                                RewindAndroidMusicClientVersion, @"clientVersion",
                                RewindLanguageCode(), @"hl",
                                [NSNumber numberWithInt:30], @"androidSdkVersion",
                                @"Android", @"osName", @"11", @"osVersion", nil];
        NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                              [NSDictionary dictionaryWithObject:client forKey:@"client"], @"context",
                              browseID, @"browseId", nil];
        NSURLRequest *request = RewindRequestForEndpoint(
            RewindPlayerEndpointFallback, @"https://music.youtube.com", @"21", RewindAndroidMusicClientVersion,
            @"com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 11) gzip",
            @"browse", apiKey, body, NULL);
        void (^plain)(void) = ^{
            RewindWebCall(@"browse", apiKey, [NSDictionary dictionaryWithObject:browseID forKey:@"browseId"],
                          ^(NSDictionary *root, NSError *webError) {
                RewindLyrics *lyrics = webError ? nil : RewindPlainLyrics(root);
                completion(lyrics, lyrics ? nil : (webError ?: RewindError(19, RewindL(@"lyrics_none"))));
            });
        };
        if (!request) {
            plain();
            return;
        }
        RewindSendRequest(request, nil, ^(id decoded, NSError *networkError) {
            id root = networkError ? nil : decoded;
            RewindLyrics *timed = RewindDict(root) ? (RewindTimedLyrics(root) ?: RewindPlainLyrics(root)) : nil;
            if (timed) completion(timed, nil);
            else {
                if (networkError) RewindDebugLog(@"mobile lyrics failed: %@", networkError);
                plain();
            }
        });
    }];
}

- (void)isCatalogMusicForTrack:(RewindTrack *)track completion:(void (^)(BOOL music, NSError *error))completion {
    if (!completion) return;
    if (!track.videoID.length) {
        completion(NO, RewindError(6, @"track has no video id"));
        return;
    }
    RewindWebCall(@"next", _apiKey, RewindWatchFields(track), ^(NSDictionary *root, NSError *error) {
        if (error) {
            completion(NO, error);
            return;
        }
        NSString *type = RewindFindStringForKey(root, @"musicVideoType");
        completion([type isEqualToString:@"MUSIC_VIDEO_TYPE_ATV"] || [type isEqualToString:@"MUSIC_VIDEO_TYPE_OMV"], nil);
    });
}

- (void)translateLines:(NSArray *)lines toLanguage:(NSString *)language completion:(RewindTranslateCompletion)completion {
    if (!completion) return;
    NSString *joined = [lines componentsJoinedByString:@"\n"];
    if (!lines.count || !joined.length || joined.length > 7000 || language.length != 2) {
        completion(nil, RewindError(26, @"nothing to translate"));
        return;
    }
    NSString *escaped = [(NSString *)CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault, (CFStringRef)joined, NULL,
                                       CFSTR("!*'();:@&=+$,/?#[]%"), kCFStringEncodingUTF8) autorelease];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://clients5.google.com/translate_a/single?client=dict-chrome-ex&sl=auto&tl=%@&dt=t", language]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setTimeoutInterval:15.0];
    [request setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3"
   forHTTPHeaderField:@"User-Agent"];
    [request setHTTPBody:[[@"q=" stringByAppendingString:escaped] dataUsingEncoding:NSUTF8StringEncoding]];
    RewindTranslateCompletion done = [[completion copy] autorelease];
    NSUInteger expected = lines.count;
    [RewindMetadataQueue() addOperationWithBlock:^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSHTTPURLResponse *response = nil;
        NSError *error = nil;
        NSData *data = RewindHTTPFetch(request, 512 * 1024, &response, &error);
        NSArray *result = nil;
        if (!error && response.statusCode != 200)
            error = RewindError(3, [NSString stringWithFormat:@"translation answered HTTP %ld", (long)response.statusCode]);
        if (!error) {
            id root = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
            NSArray *segments = [root isKindOfClass:[NSArray class]] && [root count] ? RewindArray([root objectAtIndex:0]) : nil;
            NSMutableString *text = [NSMutableString string];
            for (id segment in segments) {
                NSArray *parts = RewindArray(segment);
                NSString *piece = parts.count ? RewindString([parts objectAtIndex:0]) : nil;
                if (piece.length) [text appendString:piece];
            }
            NSArray *split = [text componentsSeparatedByString:@"\n"];
            if (split.count == expected) result = split;
            else if (!error) error = RewindError(26, @"translation did not keep the line count");
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(result, result ? nil : error); });
        [pool drain];
    }];
}

- (void)relatedForTrack:(RewindTrack *)track completion:(RewindShelvesCompletion)completion {
    if (!completion) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self relatedForTrack:track completion:completion]; });
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%@:%@:%@", track.videoID, RewindLanguageCode(), RewindRegionCode()];
    NSDictionary *cached = [_relatedCache objectForKey:key];
    if (cached && -[[cached objectForKey:@"date"] timeIntervalSinceNow] < 600.0) {
        completion([cached objectForKey:@"shelves"], [NSArray array], nil);
        return;
    }
    [self watchTabForTrack:track prefix:@"MPTR" completion:^(NSString *browseID, NSError *error) {
        if (error) {
            completion(nil, nil, error);
            return;
        }
        [self browseShelves:browseID params:nil completion:^(NSArray *shelves, NSArray *chips, NSError *failure) {
            NSMutableArray *bounded = [NSMutableArray array];
            NSUInteger remaining = 64;
            for (RewindShelf *shelf in shelves) {
                if (!remaining || bounded.count >= 8) break;
                NSUInteger count = MIN(remaining, shelf.items.count);
                [bounded addObject:[[[RewindShelf alloc] initWithTitle:shelf.title caption:shelf.caption
                    items:[shelf.items subarrayWithRange:NSMakeRange(0, count)] style:shelf.style] autorelease]];
                remaining -= count;
            }
            if (!failure && !bounded.count) failure = RewindError(18, @"track related page has no shelves");
            if (!failure && bounded.count) {
                if (!_relatedCache) {
                    _relatedCache = [[NSMutableDictionary alloc] init];
                    _relatedOrder = [[NSMutableArray alloc] init];
                }
                [_relatedOrder removeObject:key];
                [_relatedOrder addObject:key];
                [_relatedCache setObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    bounded, @"shelves", [NSDate date], @"date", nil] forKey:key];
                while (_relatedOrder.count > 16) {
                    [_relatedCache removeObjectForKey:[_relatedOrder objectAtIndex:0]];
                    [_relatedOrder removeObjectAtIndex:0];
                }
            }
            completion(failure ? nil : bounded, chips, failure);
        }];
    }];
}

@end
