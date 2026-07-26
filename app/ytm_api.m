#import "ytm_api.h"

#import "../core/ytm_model.h"
#import <CommonCrypto/CommonDigest.h>
#import <time.h>

static NSString * const YTMErrorDomain = @"com.sqmrak.tunetube.api";
static NSString * const YTMEndpoint = @"https://music.youtube.com/youtubei/v1";
static NSString * const YTMEndpointFallback = @"https://youtubei.googleapis.com/youtubei/v1";
static NSString * const YTMEndpointWebFallback = @"https://www.youtube.com/youtubei/v1";
static NSString * const YTMClientName = @"WEB_REMIX";
static NSString * const YTMClientVersion = @"1.20260707.12.00";
static NSString * const YTMPlayerEndpoint = @"https://www.youtube.com/youtubei/v1";
static NSString * const YTMPlayerEndpointFallback = @"https://youtubei.googleapis.com/youtubei/v1";
static NSString * const YTMIOSClientName = @"IOS";
static NSString * const YTMIOSClientVersion = @"21.26.4";
static NSString * const YTMAndroidClientName = @"ANDROID";
static NSString * const YTMAndroidClientVersion = @"21.26.364";
static NSString * const YTMAndroidVRClientName = @"ANDROID_VR";
static NSString * const YTMAndroidVRClientVersion = @"1.65.10";
/* keep a fallback so a fresh install can search before settings is opened */
NSString * const YTMDefaultAPIKey = @"AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";

static NSError *YTMError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:YTMErrorDomain
                                code:code
                            userInfo:[NSDictionary dictionaryWithObject:message
                                                                 forKey:NSLocalizedDescriptionKey]];
}

static NSString *YTMString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *YTMCleanText(NSString *value) {
    if (!value) return nil;
    NSString *clean = [value stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return clean.length ? clean : nil;
}

static BOOL YTMIsErrorText(NSString *value) {
    if (!value.length) return YES;
    NSString *text = [[value lowercaseString]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [text rangeOfString:@"the operation could not be completed"].location != NSNotFound ||
           [text rangeOfString:@"operation could not be completed"].location != NSNotFound ||
           [text rangeOfString:@"nsurlerrordomain"].location != NSNotFound;
}

static BOOL YTMIsPlaceholderArtist(NSString *value) {
    NSString *text = [[YTMCleanText(value) lowercaseString]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [text isEqualToString:@"unknown artist"];
}

static NSString *YTMText(id node) {
    if ([node isKindOfClass:[NSString class]]) return YTMCleanText(node);
    if (![node isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *dict = (NSDictionary *)node;
    NSString *simple = YTMString([dict objectForKey:@"simpleText"]);
    if (simple) return YTMCleanText(simple);

    NSArray *runs = [dict objectForKey:@"runs"];
    if ([runs isKindOfClass:[NSArray class]]) {
        NSMutableString *text = [NSMutableString string];
        for (id run in runs) {
            NSString *part = YTMText(run);
            if (part) [text appendString:part];
        }
        if ([text length] > 0) return YTMCleanText(text);
    }

    NSString *value = YTMText([dict objectForKey:@"text"]);
    if (value) return YTMCleanText(value);

    NSDictionary *accessibility = [dict objectForKey:@"accessibility"];
    NSDictionary *accessibilityData = [accessibility objectForKey:@"accessibilityData"];
    NSString *label = YTMString([accessibilityData objectForKey:@"label"]);
    if (label) return YTMCleanText(label);

    return nil;
}

static NSString *YTMFindTextForKey(id node, NSString *key) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSString *text = YTMText([dict objectForKey:key]);
        if (text.length) return text;
        for (id value in [dict allValues]) {
            NSString *found = YTMFindTextForKey(value, key);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = YTMFindTextForKey(value, key);
            if (found.length) return found;
        }
    }
    return nil;
}

static NSString *YTMFindStringForKey(id node, NSString *key) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSString *direct = YTMString([dict objectForKey:key]);
        if (direct) return direct;
        for (id value in [dict allValues]) {
            NSString *found = YTMFindStringForKey(value, key);
            if (found) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = YTMFindStringForKey(value, key);
            if (found) return found;
        }
    }
    return nil;
}

static NSString *YTMThumbnail(id node) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSArray *thumbs = [dict objectForKey:@"thumbnails"];
        if ([thumbs isKindOfClass:[NSArray class]]) {
            NSString *url = nil;
            for (id thumb in thumbs) {
                NSString *candidate = YTMString([thumb objectForKey:@"url"]);
                if (candidate) url = candidate;
            }
            if (url) return url;
        }
        for (id value in [dict allValues]) {
            NSString *found = YTMThumbnail(value);
            if (found) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = YTMThumbnail(value);
            if (found) return found;
        }
    }
    return nil;
}

static BOOL YTMURLLooksLikeChannelAvatar(NSString *url) {
    if (!url.length) return NO;
    // channel / artist avatars live on yt3; album art is usually i.ytimg.com
    return [url rangeOfString:@"yt3.ggpht.com"].location != NSNotFound ||
           [url rangeOfString:@"yt3.googleusercontent.com"].location != NSNotFound ||
           [url rangeOfString:@"googleusercontent.com/ytc"].location != NSNotFound;
}

static NSString *YTMBestAvatarThumbnail(id node) {
    // prefer channel-style hosts so we do not show album covers as avatars
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSArray *thumbs = [dict objectForKey:@"thumbnails"];
        if ([thumbs isKindOfClass:[NSArray class]]) {
            NSString *best = nil;
            NSString *any = nil;
            for (id thumb in thumbs) {
                NSString *candidate = YTMString([thumb objectForKey:@"url"]);
                if (!candidate.length) continue;
                any = candidate;
                if (YTMURLLooksLikeChannelAvatar(candidate)) best = candidate;
            }
            if (best.length) return best;
            if (any.length) return any;
        }
        for (id value in [dict allValues]) {
            NSString *found = YTMBestAvatarThumbnail(value);
            if (found.length && YTMURLLooksLikeChannelAvatar(found)) return found;
        }
        for (id value in [dict allValues]) {
            NSString *found = YTMBestAvatarThumbnail(value);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = YTMBestAvatarThumbnail(value);
            if (found.length && YTMURLLooksLikeChannelAvatar(found)) return found;
        }
        for (id value in (NSArray *)node) {
            NSString *found = YTMBestAvatarThumbnail(value);
            if (found.length) return found;
        }
    }
    return nil;
}

static NSString *YTMHeaderThumbnail(id node) {
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
            NSString *url = YTMBestAvatarThumbnail(header);
            if (url.length) return url;
            url = YTMThumbnail(header);
            if (url.length) return url;
        }
        for (id value in [dict allValues]) {
            NSString *found = YTMHeaderThumbnail(value);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = YTMHeaderThumbnail(value);
            if (found.length) return found;
        }
    }
    return nil;
}

static NSUInteger YTMClockSeconds(NSString *value) {
    NSArray *parts = [(YTMCleanText(value) ?: @"")
                      componentsSeparatedByString:@":"];
    NSUInteger result = 0;
    for (NSString *part in parts) {
        NSInteger n = [(YTMCleanText(part) ?: @"") integerValue];
        if (n < 0 || n > 3600) return 0;
        result = result * 60u + (NSUInteger)n;
    }
    return result;
}

static BOOL YTMLooksLikeClock(NSString *value) {
    NSArray *parts = [(YTMCleanText(value) ?: @"")
                      componentsSeparatedByString:@":"];
    if ([parts count] < 2 || [parts count] > 3) return NO;
    NSCharacterSet *notDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    for (NSString *part in parts) {
        NSString *clean = YTMCleanText(part);
        if (![clean length] || [clean rangeOfCharacterFromSet:notDigits].location != NSNotFound)
            return NO;
    }
    NSUInteger seconds = [[parts lastObject] integerValue];
    return seconds < 60;
}

static BOOL YTMIsTypeLabel(NSString *value) {
    return [value caseInsensitiveCompare:@"Song"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"Video"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"Album"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"Playlist"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"Music"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"Episode"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"Artist"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"Profile"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"Podcast"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"Mix"] == NSOrderedSame;
}

static NSString *YTMResultTypeFromText(NSString *value) {
    NSString *clean = YTMCleanText(value);
    if (!clean.length) return nil;
    NSString *first = YTMCleanText([[clean componentsSeparatedByString:@"•"] objectAtIndex:0]);
    NSArray *types = [NSArray arrayWithObjects:
                      @"Song", @"Video", @"Album", @"Playlist", @"Episode",
                      @"Artist", @"Profile", @"Podcast", @"Mix", nil];
    for (NSString *type in types)
        if ([first caseInsensitiveCompare:type] == NSOrderedSame) return type;
    return nil;
}

static BOOL YTMIsCountText(NSString *value) {
    NSString *text = [[YTMCleanText(value) lowercaseString]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [text hasSuffix:@" view"] || [text hasSuffix:@" views"] ||
           [text hasSuffix:@" play"] || [text hasSuffix:@" plays"];
}

static NSString *YTMArtistFromMetadataText(NSString *value) {
    NSString *clean = YTMCleanText(value);
    if (!clean || YTMIsErrorText(clean) || YTMIsPlaceholderArtist(clean) ||
        YTMLooksLikeClock(clean) ||
        YTMIsCountText(clean)) return nil;

    NSArray *parts = [clean componentsSeparatedByString:@"•"];
    if ([parts count] > 1) {
        BOOL typeLabel = YTMIsTypeLabel(YTMCleanText([parts objectAtIndex:0]));
        NSString *artist = YTMCleanText([parts objectAtIndex:typeLabel ? 1 : 0]);
        if (!artist || YTMIsErrorText(artist) || YTMIsPlaceholderArtist(artist) ||
            YTMLooksLikeClock(artist) ||
            YTMIsCountText(artist)) return nil;
        return artist;
    }

    return YTMIsTypeLabel(clean) ? nil : clean;
}

static NSString *YTMAlbumFromMetadataText(NSString *value) {
    NSString *clean = YTMCleanText(value);
    if (!clean) return nil;

    NSArray *parts = [clean componentsSeparatedByString:@"•"];
    if ([parts count] < 2) return nil;

    BOOL typeLabel = YTMIsTypeLabel(YTMCleanText([parts objectAtIndex:0]));
    NSUInteger albumIndex = typeLabel ? 2 : 1;
    if ([parts count] <= albumIndex)
        return nil;

    NSString *album = YTMCleanText([parts objectAtIndex:albumIndex]);
    return YTMIsErrorText(album) || YTMLooksLikeClock(album) || YTMIsCountText(album)
        ? nil : album;
}

NSString *YTMDisplayArtist(NSString *artist) {
    if (!artist.length || YTMIsPlaceholderArtist(artist)) return @"Unknown artist";
    NSString *displayArtist = YTMArtistFromMetadataText(artist);
    if (displayArtist.length) return displayArtist;
    NSString *clean = YTMCleanText(artist);
    if (clean.length && !YTMIsErrorText(clean) && !YTMIsPlaceholderArtist(clean))
        return clean;
    return @"Unknown artist";
}

NSString *YTMTrackArtistText(YTMTrack *track) {
    NSString *artist = YTMDisplayArtist(track.artist);
    if ([artist caseInsensitiveCompare:@"Unknown artist"] != NSOrderedSame)
        return artist;
    if (track.isPlaylist) return @"YouTube Music";
    // keep english token for comparisons; ui localizes separately when needed
    return @"Unknown artist";
}

static BOOL YTMBrowseLooksLikeArtist(NSDictionary *browse) {
    if (![browse isKindOfClass:[NSDictionary class]]) return NO;
    NSString *browseID = YTMString([browse objectForKey:@"browseId"]);
    if ([browseID hasPrefix:@"UC"] || [browseID hasPrefix:@"MPLA"] ||
        [browseID hasPrefix:@"FEmusic_library_privately_owned_artist"])
        return YES;
    NSDictionary *context = [browse objectForKey:@"browseEndpointContextSupportedConfigs"];
    NSDictionary *musicConfig = [context objectForKey:@"browseEndpointContextMusicConfig"];
    NSString *pageType = YTMString([musicConfig objectForKey:@"pageType"]);
    if ([pageType rangeOfString:@"ARTIST" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return YES;
    return NO;
}

static NSString *YTMArtistBrowseID(id node) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSString *label = YTMText([dict objectForKey:@"text"]);
        if (!label) label = YTMText([dict objectForKey:@"defaultText"]);
        NSDictionary *endpoint = [dict objectForKey:@"navigationEndpoint"];
        if (![endpoint isKindOfClass:[NSDictionary class]])
            endpoint = [dict objectForKey:@"defaultNavigationEndpoint"];
        NSDictionary *browse = [endpoint objectForKey:@"browseEndpoint"];
        if (YTMBrowseLooksLikeArtist(browse)) {
            NSString *browseID = YTMString([browse objectForKey:@"browseId"]);
            if (browseID.length) return browseID;
        }
        if ([label rangeOfString:@"go to artist" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            NSString *browseID = YTMString([browse objectForKey:@"browseId"]);
            if (browseID.length) return browseID;
        }
        for (id value in [dict allValues]) {
            NSString *found = YTMArtistBrowseID(value);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = YTMArtistBrowseID(value);
            if (found.length) return found;
        }
    }
    return nil;
}

// pick artist name from a run that links to an artist page
static NSString *YTMArtistNameFromRuns(id node) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSArray *runs = [dict objectForKey:@"runs"];
        if ([runs isKindOfClass:[NSArray class]]) {
            for (id run in runs) {
                if (![run isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *endpoint = [run objectForKey:@"navigationEndpoint"];
                NSDictionary *browse = [endpoint objectForKey:@"browseEndpoint"];
                if (!YTMBrowseLooksLikeArtist(browse)) continue;
                NSString *text = YTMText(run);
                if (text.length && !YTMIsTypeLabel(text) && !YTMLooksLikeClock(text) &&
                    !YTMIsCountText(text) && !YTMIsPlaceholderArtist(text))
                    return text;
            }
        }
        for (id value in [dict allValues]) {
            NSString *found = YTMArtistNameFromRuns(value);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = YTMArtistNameFromRuns(value);
            if (found.length) return found;
        }
    }
    return nil;
}

static NSString *YTMResolveResultType(NSString *musicVideoType, NSArray *texts) {
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
        NSString *type = YTMResultTypeFromText(text);
        if (type.length) return type;
    }
    // playable items without a video marker stay songs
    return @"Song";
}

static NSString *YTMFindClockText(id node) {
    if ([node isKindOfClass:[NSString class]]) {
        NSString *text = YTMCleanText((NSString *)node);
        if (YTMLooksLikeClock(text)) return text;
        for (NSString *part in [text componentsSeparatedByString:@"•"]) {
            NSString *candidate = YTMCleanText(part);
            if (YTMLooksLikeClock(candidate)) return candidate;
        }
    } else if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        for (NSString *key in [NSArray arrayWithObjects:@"text", @"simpleText", nil]) {
            NSString *text = YTMText([dict objectForKey:key]);
            if (text && YTMLooksLikeClock(text)) return text;
        }
        for (id value in [dict allValues]) {
            NSString *found = YTMFindClockText(value);
            if (found) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = YTMFindClockText(value);
            if (found) return found;
        }
    }
    return nil;
}

static YTMTrack *YTMTrackFromRenderer(NSDictionary *renderer) {
    NSDictionary *columns = [renderer objectForKey:@"flexColumns"];
    if (![columns isKindOfClass:[NSArray class]] || [columns count] == 0) return nil;

    NSMutableArray *texts = [NSMutableArray array];
    for (NSDictionary *column in columns) {
        NSDictionary *columnRenderer = [column objectForKey:@"musicResponsiveListItemFlexColumnRenderer"];
        NSString *text = YTMText([columnRenderer objectForKey:@"text"]);
        if (text) [texts addObject:text];
    }

    if ([texts count] == 0) return nil;

    NSString *title = [texts objectAtIndex:0];
    BOOL isPlaylist = NO;
    NSString *musicVideoType = YTMFindStringForKey(renderer, @"musicVideoType");
    NSString *resultType = YTMResolveResultType(musicVideoType, texts);
    for (NSString *text in texts)
        if ([text rangeOfString:@"Playlist" options:NSCaseInsensitiveSearch].location != NSNotFound)
            isPlaylist = YES;
    NSString *playlistID = YTMFindStringForKey(renderer, @"playlistId");
    if (!playlistID.length) {
        NSString *browseID = YTMFindStringForKey(renderer, @"browseId");
        if ([browseID hasPrefix:@"VL"] && browseID.length > 2)
            playlistID = [browseID substringFromIndex:2];
    }
    NSString *videoID = YTMFindStringForKey(renderer, @"videoId");
    if (!videoID.length && !isPlaylist) return nil;
    NSMutableArray *metadata = [NSMutableArray array];
    for (NSUInteger index = 1; index < [texts count]; ++index) {
        NSString *text = [texts objectAtIndex:index];
        /* keep duration separate because some responses put it in its own column */
        if (!YTMLooksLikeClock(text)) [metadata addObject:text];
    }

    // prefer the run that actually links to an artist page
    NSString *artist = YTMArtistNameFromRuns(renderer);
    NSString *album = @"";
    NSUInteger artistIndex = NSNotFound;

    if (!artist.length) {
        for (NSUInteger index = 0; index < metadata.count; ++index) {
            NSString *candidate = YTMArtistFromMetadataText([metadata objectAtIndex:index]);
            if (!candidate) continue;
            artist = candidate;
            artistIndex = index;
            album = YTMAlbumFromMetadataText([metadata objectAtIndex:index]) ?: @"";
            break;
        }
    } else {
        // still try to pull album from the first metadata line
        for (NSUInteger index = 0; index < metadata.count; ++index) {
            album = YTMAlbumFromMetadataText([metadata objectAtIndex:index]) ?: @"";
            if (album.length) {
                artistIndex = index;
                break;
            }
        }
    }
    if (artistIndex != NSNotFound && !album.length) {
        for (NSUInteger index = artistIndex + 1; index < metadata.count; ++index) {
            NSString *candidate = YTMArtistFromMetadataText([metadata objectAtIndex:index]);
            if (candidate && ![candidate isEqualToString:artist]) {
                album = candidate;
                break;
            }
        }
    }

    // byline / secondary line often has the clean artist when flex columns do not
    if (!artist.length) {
        for (NSString *key in [NSArray arrayWithObjects:
                               @"longBylineText", @"shortBylineText", @"subtitle", nil]) {
            NSString *byline = YTMText([renderer objectForKey:key]);
            NSString *candidate = YTMArtistFromMetadataText(byline);
            if (candidate.length) {
                artist = candidate;
                if (!album.length) album = YTMAlbumFromMetadataText(byline) ?: @"";
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
                NSString *left = YTMCleanText([title substringToIndex:range.location]);
                NSString *right = YTMCleanText([title substringFromIndex:range.location + range.length]);
                // "artist - title" is the usual form
                if (left.length && right.length && !YTMLooksLikeClock(left)) {
                    artist = left;
                    title = right;
                }
                break;
            }
        }
    }

    NSUInteger duration = 0;
    NSString *clock = YTMFindClockText(renderer);
    if (clock)
        duration = YTMClockSeconds(clock);

    NSString *artistID = isPlaylist ? nil : YTMArtistBrowseID(renderer);
    NSString *displayArtist = YTMDisplayArtist(artist);
    // last resort: accessibility label often has "title by artist"
    if ([displayArtist caseInsensitiveCompare:@"Unknown artist"] == NSOrderedSame) {
        NSString *access = YTMFindTextForKey(renderer, @"accessibilityData");
        if (!access.length) access = YTMFindTextForKey(renderer, @"label");
        if (access.length) {
            NSRange byRange = [access rangeOfString:@" by " options:NSCaseInsensitiveSearch];
            if (byRange.location != NSNotFound) {
                NSString *after = YTMCleanText([access substringFromIndex:byRange.location + byRange.length]);
                // strip trailing " and n more" / duration junk
                NSArray *cut = [after componentsSeparatedByString:@","];
                NSString *maybe = YTMCleanText([cut objectAtIndex:0]);
                NSArray *cut2 = [maybe componentsSeparatedByString:@"•"];
                maybe = YTMCleanText([cut2 objectAtIndex:0]);
                if (maybe.length && !YTMIsTypeLabel(maybe) && !YTMLooksLikeClock(maybe))
                    displayArtist = maybe;
            }
        }
    }

    return [[[YTMTrack alloc] initWithVideoID:videoID
                                        title:title
                                       artist:displayArtist
                                        album:album
                                thumbnailURL:YTMThumbnail(renderer)
                                     duration:duration
                                  playlistID:isPlaylist ? playlistID : nil
                                    artistID:artistID
                                 resultType:resultType] autorelease];
}

static void YTMCollectTracks(id node, NSMutableArray *tracks) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSDictionary *renderer = [dict objectForKey:@"musicResponsiveListItemRenderer"];
        if ([renderer isKindOfClass:[NSDictionary class]]) {
            YTMTrack *track = YTMTrackFromRenderer(renderer);
            if (track) {
                [tracks addObject:track];
                return;
            }
        }
        for (id value in [dict allValues]) YTMCollectTracks(value, tracks);
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) YTMCollectTracks(value, tracks);
    }
}

static NSDictionary *YTMClientContext(void) {
    NSDictionary *client = [NSDictionary dictionaryWithObjectsAndKeys:
                            YTMClientName, @"clientName",
                            YTMClientVersion, @"clientVersion",
                            @"en", @"hl",
                            @"US", @"gl",
                            nil];
    return [NSDictionary dictionaryWithObject:client forKey:@"client"];
}

static NSDictionary *YTMPlayerContext(NSString *clientName, NSString *clientVersion) {
    NSMutableDictionary *client = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                   clientName, @"clientName",
                                   clientVersion, @"clientVersion",
                                   @"en", @"hl",
                                   @"US", @"gl",
                                   nil];

    if ([clientName isEqualToString:YTMIOSClientName]) {
        [client setObject:@"Apple" forKey:@"deviceMake"];
        [client setObject:@"iPhone16,2" forKey:@"deviceModel"];
        [client setObject:@"iPhone" forKey:@"osName"];
        [client setObject:@"18.3.2.22D82" forKey:@"osVersion"];
        [client setObject:@"com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)" forKey:@"userAgent"];
    } else if ([clientName isEqualToString:YTMAndroidClientName]) {
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

static NSURLRequest *YTMRequestForEndpoint(NSString *endpoint,
                                           NSString *origin,
                                           NSString *clientHeaderName,
                                           NSString *clientVersion,
                                           NSString *userAgent,
                                           NSString *path,
                                           NSString *apiKey,
                                           NSDictionary *body,
                                           NSError **error) {
    if (![apiKey length]) {
        if (error) *error = YTMError(1, @"YouTube Music API key is empty");
        return nil;
    }

    NSString *escapedKey = [apiKey stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@?key=%@",
                                       endpoint, path, escapedKey]];
    if (!url) {
        if (error) *error = YTMError(2, @"invalid YouTube Music endpoint");
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
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:origin forHTTPHeaderField:@"Origin"];
    [request setValue:clientHeaderName forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [request setValue:clientVersion forHTTPHeaderField:@"X-YouTube-Client-Version"];
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    [request setHTTPBody:data];
    return request;
}

static NSURLRequest *YTMRequest(NSString *path, NSString *apiKey, NSDictionary *body,
                                NSError **error) {
    return YTMRequestForEndpoint(YTMEndpoint,
                                 @"https://music.youtube.com",
                                 @"67",
                                 YTMClientVersion,
                                 @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
                                 path, apiKey, body, error);
}

typedef void (^YTMNetworkCompletion)(NSData *data, NSError *error);

static BOOL YTMShouldTryFallback(NSError *error) {
    switch (error.code) {
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorTimedOut:
        case NSURLErrorSecureConnectionFailed:
            return YES;
        default:
            return NO;
    }
}

/* try the google endpoint when an older dns setup cannot resolve youtube */
static void YTMSendRequest(NSURLRequest *request, NSURLRequest *fallback,
                           YTMNetworkCompletion completion) {
    [NSURLConnection sendAsynchronousRequest:request
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
        (void)response;
        if (error && fallback && YTMShouldTryFallback(error)) {
            YTMSendRequest(fallback, nil, completion);
            return;
        }
        completion(data, error);
    }];
}

static void YTMDecodeResponse(NSData *data, void (^completion)(id root, NSError *error)) {
    NSError *error = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (!root) {
        completion(nil, error ? error : YTMError(3, @"invalid JSON response"));
        return;
    }
    completion(root, nil);
}

@implementation YTMTrack

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
    [super dealloc];
}

@end

@implementation YTMAPI

- (id)initWithAPIKey:(NSString *)apiKey {
    self = [super init];
    if (!self) return nil;
    _apiKey = [apiKey copy];
    return self;
}

- (void)dealloc {
    [_apiKey release];
    [super dealloc];
}

- (void)search:(NSString *)query completion:(YTMSearchCompletion)completion {
    if (!completion) return;
    if (![query length]) {
        completion(nil, YTMError(4, @"search query is empty"));
        return;
    }

    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          YTMClientContext(), @"context",
                          query, @"query",
                          nil];
    NSError *error = nil;
    NSURLRequest *request = YTMRequest(@"search", _apiKey, body, &error);
    NSError *fallbackError = nil;
    NSURLRequest *fallbackRequest = YTMRequestForEndpoint(
        YTMEndpointFallback, @"https://youtubei.googleapis.com", @"67",
        YTMClientVersion,
        @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
        @"search", _apiKey, body, &fallbackError);
    NSError *webFallbackError = nil;
    NSURLRequest *webFallbackRequest = YTMRequestForEndpoint(
        YTMEndpointWebFallback, @"https://www.youtube.com", @"67",
        YTMClientVersion,
        @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
        @"search", _apiKey, body, &webFallbackError);
    if (!request) {
        completion(nil, error);
        return;
    }

    void (^finish)(NSData *, NSError *) = ^(NSData *data, NSError *networkError) {
        if (networkError) {
            completion(nil, networkError);
            return;
        }
        YTMDecodeResponse(data, ^(id root, NSError *jsonError) {
            if (jsonError) {
                completion(nil, jsonError);
                return;
            }
            NSMutableArray *tracks = [NSMutableArray array];
            YTMCollectTracks(root, tracks);
            if ([tracks count] == 0) {
                completion(nil, YTMError(5, @"no playable music results in response"));
                return;
            }
            completion(tracks, nil);
        });
    };

    YTMSendRequest(request, fallbackRequest, ^(NSData *data, NSError *networkError) {
        if (networkError && webFallbackRequest && YTMShouldTryFallback(networkError)) {
            YTMSendRequest(webFallbackRequest, nil, finish);
            return;
        }
        finish(data, networkError);
    });
}

- (void)playlistTracksForID:(NSString *)playlistID completion:(YTMSearchCompletion)completion {
    if (!completion) return;
    if (!playlistID.length) {
        completion(nil, YTMError(13, @"playlist has no id"));
        return;
    }
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          YTMClientContext(), @"context",
                          playlistID, @"browseId", nil];
    NSError *error = nil;
    NSURLRequest *request = YTMRequest(@"browse", _apiKey, body, &error);
    NSError *fallbackError = nil;
    NSURLRequest *fallback = YTMRequestForEndpoint(
        YTMEndpointFallback, @"https://youtubei.googleapis.com", @"67",
        YTMClientVersion,
        @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
        @"browse", _apiKey, body, &fallbackError);
    if (!request) {
        completion(nil, error);
        return;
    }
    YTMSendRequest(request, fallback, ^(NSData *data, NSError *networkError) {
        if (networkError) {
            completion(nil, networkError);
            return;
        }
        YTMDecodeResponse(data, ^(id root, NSError *jsonError) {
            if (jsonError) {
                completion(nil, jsonError);
                return;
            }
            NSMutableArray *tracks = [NSMutableArray array];
            YTMCollectTracks(root, tracks);
            if (!tracks.count) {
                completion(nil, YTMError(14, @"playlist has no playable tracks"));
                return;
            }
            completion(tracks, nil);
        });
    });
}

- (void)artistInfoForID:(NSString *)artistID completion:(YTMArtistCompletion)completion {
    if (!completion) return;
    if (!artistID.length) {
        completion(nil, nil, YTMError(15, @"artist has no id"));
        return;
    }
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          YTMClientContext(), @"context",
                          artistID, @"browseId", nil];
    NSError *error = nil;
    NSURLRequest *request = YTMRequest(@"browse", _apiKey, body, &error);
    NSError *fallbackError = nil;
    NSURLRequest *fallback = YTMRequestForEndpoint(
        YTMEndpointFallback, @"https://youtubei.googleapis.com", @"67",
        YTMClientVersion,
        @"Mozilla/5.0 (iPhone; CPU iOS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
        @"browse", _apiKey, body, &fallbackError);
    if (!request) {
        completion(nil, nil, error);
        return;
    }
    YTMSendRequest(request, fallback, ^(NSData *data, NSError *networkError) {
        if (networkError) {
            completion(nil, nil, networkError);
            return;
        }
        YTMDecodeResponse(data, ^(id root, NSError *jsonError) {
            if (jsonError) {
                completion(nil, nil, jsonError);
                return;
            }
            NSString *name = YTMFindTextForKey(root, @"title");
            // prefer true channel avatar urls over album art
            NSString *avatar = YTMBestAvatarThumbnail(root);
            if (!avatar.length) avatar = YTMHeaderThumbnail(root);
            if (!avatar.length) avatar = YTMThumbnail(root);
            completion(name, avatar, nil);
        });
    });
}

static NSURL *YTMDirectAudioURL(id root, BOOL *ciphered) {
    NSDictionary *streaming = [root isKindOfClass:[NSDictionary class]]
        ? [(NSDictionary *)root objectForKey:@"streamingData"] : nil;
    if (![streaming isKindOfClass:[NSDictionary class]]) return nil;

    NSArray *lists = [NSArray arrayWithObjects:
                      [streaming objectForKey:@"adaptiveFormats"],
                      [streaming objectForKey:@"formats"], nil];
    NSDictionary *best = nil;
    NSDictionary *combined = nil;
    NSUInteger listIndex = 0;
    for (NSArray *formats in lists) {
        if (![formats isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *format in formats) {
            NSString *mime = YTMString([format objectForKey:@"mimeType"]);
            BOOL audioOnly = [mime hasPrefix:@"audio/"];
            BOOL combinedMP4 = listIndex == 1 &&
                [mime hasPrefix:@"video/"] &&
                [mime rangeOfString:@"mp4a."].location != NSNotFound;
            if (!audioOnly && !combinedMP4) continue;
            NSString *url = YTMString([format objectForKey:@"url"]);
            if (!url) {
                if ([format objectForKey:@"signatureCipher"] || [format objectForKey:@"cipher"])
                    *ciphered = YES;
                continue;
            }
            if (audioOnly) {
                if (!best || [[format objectForKey:@"bitrate"] integerValue] > [[best objectForKey:@"bitrate"] integerValue])
                    best = format;
            } else if (!combined ||
                       [[format objectForKey:@"bitrate"] integerValue] > [[combined objectForKey:@"bitrate"] integerValue]) {
                combined = format;
            }
        }
        ++listIndex;
    }
    if (!best) best = combined;
    if (best) return [NSURL URLWithString:YTMString([best objectForKey:@"url"])];

    /* accept hls because ios may return a manifest instead of adaptive formats */
    return [NSURL URLWithString:YTMString([streaming objectForKey:@"hlsManifestUrl"])];
}

static void YTMAudioURLWithPlayerClient(NSString *videoID,
                                        NSString *apiKey,
                                        NSString *clientName,
                                        NSString *clientVersion,
                                        NSString *clientHeaderName,
                                        NSString *userAgent,
                                        YTMAudioCompletion completion) {
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          YTMPlayerContext(clientName, clientVersion), @"context",
                          videoID, @"videoId",
                          @YES, @"contentCheckOk",
                          @YES, @"racyCheckOk",
                          nil];
    NSError *error = nil;
    NSURLRequest *request = YTMRequestForEndpoint(YTMPlayerEndpoint,
                                                   @"https://www.youtube.com",
                                                   clientHeaderName,
                                                   clientVersion,
                                                   userAgent,
                                                   @"player",
                                                   apiKey,
                                                   body,
                                                   &error);
    NSError *fallbackError = nil;
    NSURLRequest *fallbackRequest = YTMRequestForEndpoint(
        YTMPlayerEndpointFallback, @"https://youtubei.googleapis.com",
        clientHeaderName, clientVersion, userAgent, @"player", apiKey, body,
        &fallbackError);
    if (!request) {
        completion(nil, error);
        return;
    }

    YTMSendRequest(request, fallbackRequest, ^(NSData *data, NSError *networkError) {
        if (networkError) {
            completion(nil, networkError);
            return;
        }
        YTMDecodeResponse(data, ^(id root, NSError *jsonError) {
            BOOL ciphered = NO;
            NSURL *url;
            if (jsonError) {
                completion(nil, jsonError);
                return;
            }
            url = YTMDirectAudioURL(root, &ciphered);
            if (url) {
                completion(url, nil);
                return;
            }

            NSDictionary *playability = [root isKindOfClass:[NSDictionary class]]
                ? [(NSDictionary *)root objectForKey:@"playabilityStatus"] : nil;
            NSString *reason = YTMString([playability objectForKey:@"reason"]);
            if ([reason length]) {
                completion(nil, YTMError(8, [NSString stringWithFormat:@"%@ player: %@", clientName, reason]));
            } else if (ciphered) {
                completion(nil, YTMError(7, @"audio format is ciphered; decipher support is not enabled yet"));
            } else {
                completion(nil, YTMError(8, [NSString stringWithFormat:@"%@ player response has no audio format", clientName]));
            }
        });
    });
}

- (void)audioURLForTrack:(YTMTrack *)track completion:(YTMAudioCompletion)completion {
    if (!completion) return;
    if (![track.videoID length]) {
        completion(nil, YTMError(6, @"track has no video id"));
        return;
    }

    NSString *iosUA = @"com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)";
    NSString *androidUA = @"com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip";
    NSString *vrUA = @"com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";
    YTMAudioURLWithPlayerClient(track.videoID, _apiKey,
                                YTMIOSClientName, YTMIOSClientVersion, @"5", iosUA,
                                ^(NSURL *url, NSError *iosError) {
        if (url) {
            completion(url, nil);
            return;
        }
        YTMAudioURLWithPlayerClient(track.videoID, _apiKey,
                                    YTMAndroidClientName, YTMAndroidClientVersion, @"3", androidUA,
                                    ^(NSURL *androidURL, NSError *androidError) {
            if (androidURL) {
                completion(androidURL, nil);
                return;
            }
            YTMAudioURLWithPlayerClient(track.videoID, _apiKey,
                                        YTMAndroidVRClientName, YTMAndroidVRClientVersion, @"28", vrUA,
                                        ^(NSURL *fallbackURL, NSError *fallbackError) {
                completion(fallbackURL, fallbackURL ? nil :
                           (fallbackError ? fallbackError :
                            (androidError ? androidError : iosError)));
            });
        });
    });
}

@end
