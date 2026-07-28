#import "tunetube_api.h"

#import "../core/tunetube_model.h"
#import <CommonCrypto/CommonDigest.h>
#import <time.h>

static NSString * const TuneTubeErrorDomain = @"com.sqmrak.tunetube.api";
static NSString * const TuneTubeEndpoint = @"https://music.youtube.com/youtubei/v1";
static NSString * const TuneTubeEndpointFallback = @"https://youtubei.googleapis.com/youtubei/v1";
static NSString * const TuneTubeEndpointWebFallback = @"https://www.youtube.com/youtubei/v1";
static NSString * const TuneTubeClientName = @"WEB_REMIX";
static NSString * const TuneTubeClientVersion = @"1.20260707.12.00";
static NSString * const TuneTubePlayerEndpoint = @"https://www.youtube.com/youtubei/v1";
static NSString * const TuneTubePlayerEndpointFallback = @"https://youtubei.googleapis.com/youtubei/v1";
static NSString * const TuneTubeIOSClientName = @"IOS";
static NSString * const TuneTubeIOSClientVersion = @"21.26.4";
static NSString * const TuneTubeAndroidClientName = @"ANDROID";
static NSString * const TuneTubeAndroidClientVersion = @"21.26.364";
static NSString * const TuneTubeAndroidVRClientName = @"ANDROID_VR";
static NSString * const TuneTubeAndroidVRClientVersion = @"1.65.10";
/* keep a fallback so a fresh install can search before settings is opened */
NSString * const TuneTubeDefaultAPIKey = @"AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";

static NSError *TuneTubeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:TuneTubeErrorDomain
                                code:code
                            userInfo:[NSDictionary dictionaryWithObject:message
                                                                 forKey:NSLocalizedDescriptionKey]];
}

static NSString *TuneTubeString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *TuneTubeCleanText(NSString *value) {
    if (!value) return nil;
    NSString *clean = [value stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return clean.length ? clean : nil;
}

static BOOL TuneTubeIsErrorText(NSString *value) {
    if (!value.length) return YES;
    NSString *text = [[value lowercaseString]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [text rangeOfString:@"the operation could not be completed"].location != NSNotFound ||
           [text rangeOfString:@"operation could not be completed"].location != NSNotFound ||
           [text rangeOfString:@"nsurlerrordomain"].location != NSNotFound;
}

static BOOL TuneTubeIsPlaceholderArtist(NSString *value) {
    NSString *text = [[TuneTubeCleanText(value) lowercaseString]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [text isEqualToString:@"unknown artist"] ||
           [text isEqualToString:@"unknown"] ||
           [text isEqualToString:@"неизвестный артист"] ||
           [text isEqualToString:@"неизвестный исполнитель"];
}

static NSString *TuneTubeText(id node) {
    if ([node isKindOfClass:[NSString class]]) return TuneTubeCleanText(node);
    if (![node isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *dict = (NSDictionary *)node;
    NSString *simple = TuneTubeString([dict objectForKey:@"simpleText"]);
    if (simple) return TuneTubeCleanText(simple);

    NSArray *runs = [dict objectForKey:@"runs"];
    if ([runs isKindOfClass:[NSArray class]]) {
        NSMutableString *text = [NSMutableString string];
        for (id run in runs) {
            NSString *part = TuneTubeText(run);
            if (part) [text appendString:part];
        }
        if ([text length] > 0) return TuneTubeCleanText(text);
    }

    NSString *value = TuneTubeText([dict objectForKey:@"text"]);
    if (value) return TuneTubeCleanText(value);

    NSDictionary *accessibility = [dict objectForKey:@"accessibility"];
    NSDictionary *accessibilityData = [accessibility objectForKey:@"accessibilityData"];
    NSString *label = TuneTubeString([accessibilityData objectForKey:@"label"]);
    if (label) return TuneTubeCleanText(label);

    return nil;
}

static NSString *TuneTubeFindTextForKey(id node, NSString *key) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSString *text = TuneTubeText([dict objectForKey:key]);
        if (text.length) return text;
        for (id value in [dict allValues]) {
            NSString *found = TuneTubeFindTextForKey(value, key);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = TuneTubeFindTextForKey(value, key);
            if (found.length) return found;
        }
    }
    return nil;
}

static NSString *TuneTubeFindStringForKey(id node, NSString *key) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSString *direct = TuneTubeString([dict objectForKey:key]);
        if (direct) return direct;
        for (id value in [dict allValues]) {
            NSString *found = TuneTubeFindStringForKey(value, key);
            if (found) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = TuneTubeFindStringForKey(value, key);
            if (found) return found;
        }
    }
    return nil;
}

static NSString *TuneTubeThumbnail(id node) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSArray *thumbs = [dict objectForKey:@"thumbnails"];
        if ([thumbs isKindOfClass:[NSArray class]]) {
            NSString *url = nil;
            for (id thumb in thumbs) {
                NSString *candidate = TuneTubeString([thumb objectForKey:@"url"]);
                if (candidate) url = candidate;
            }
            if (url) return url;
        }
        for (id value in [dict allValues]) {
            NSString *found = TuneTubeThumbnail(value);
            if (found) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = TuneTubeThumbnail(value);
            if (found) return found;
        }
    }
    return nil;
}

static BOOL TuneTubeURLLooksLikeChannelAvatar(NSString *url) {
    if (!url.length) return NO;
    // channel / artist avatars live on yt3; album art is usually i.ytimg.com
    return [url rangeOfString:@"yt3.ggpht.com"].location != NSNotFound ||
           [url rangeOfString:@"yt3.googleusercontent.com"].location != NSNotFound ||
           [url rangeOfString:@"googleusercontent.com/ytc"].location != NSNotFound;
}

static NSString *TuneTubeBestAvatarThumbnail(id node) {
    // prefer channel-style hosts so we do not show album covers as avatars
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSArray *thumbs = [dict objectForKey:@"thumbnails"];
        if ([thumbs isKindOfClass:[NSArray class]]) {
            NSString *best = nil;
            NSString *any = nil;
            for (id thumb in thumbs) {
                NSString *candidate = TuneTubeString([thumb objectForKey:@"url"]);
                if (!candidate.length) continue;
                any = candidate;
                if (TuneTubeURLLooksLikeChannelAvatar(candidate)) best = candidate;
            }
            if (best.length) return best;
            if (any.length) return any;
        }
        for (id value in [dict allValues]) {
            NSString *found = TuneTubeBestAvatarThumbnail(value);
            if (found.length && TuneTubeURLLooksLikeChannelAvatar(found)) return found;
        }
        for (id value in [dict allValues]) {
            NSString *found = TuneTubeBestAvatarThumbnail(value);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = TuneTubeBestAvatarThumbnail(value);
            if (found.length && TuneTubeURLLooksLikeChannelAvatar(found)) return found;
        }
        for (id value in (NSArray *)node) {
            NSString *found = TuneTubeBestAvatarThumbnail(value);
            if (found.length) return found;
        }
    }
    return nil;
}

static NSString *TuneTubeHeaderThumbnail(id node) {
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
            NSString *url = TuneTubeBestAvatarThumbnail(header);
            if (url.length) return url;
            url = TuneTubeThumbnail(header);
            if (url.length) return url;
        }
        for (id value in [dict allValues]) {
            NSString *found = TuneTubeHeaderThumbnail(value);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = TuneTubeHeaderThumbnail(value);
            if (found.length) return found;
        }
    }
    return nil;
}

static NSUInteger TuneTubeClockSeconds(NSString *value) {
    NSArray *parts = [(TuneTubeCleanText(value) ?: @"")
                      componentsSeparatedByString:@":"];
    NSUInteger result = 0;
    for (NSString *part in parts) {
        NSInteger n = [(TuneTubeCleanText(part) ?: @"") integerValue];
        if (n < 0 || n > 3600) return 0;
        result = result * 60u + (NSUInteger)n;
    }
    return result;
}

static BOOL TuneTubeLooksLikeClock(NSString *value) {
    NSArray *parts = [(TuneTubeCleanText(value) ?: @"")
                      componentsSeparatedByString:@":"];
    if ([parts count] < 2 || [parts count] > 3) return NO;
    NSCharacterSet *notDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    for (NSString *part in parts) {
        NSString *clean = TuneTubeCleanText(part);
        if (![clean length] || [clean rangeOfCharacterFromSet:notDigits].location != NSNotFound)
            return NO;
    }
    NSUInteger seconds = [[parts lastObject] integerValue];
    return seconds < 60;
}

static BOOL TuneTubeIsTypeLabel(NSString *value) {
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

static NSString *TuneTubeResultTypeFromText(NSString *value) {
    NSString *clean = TuneTubeCleanText(value);
    if (!clean.length) return nil;
    NSString *first = TuneTubeCleanText([[clean componentsSeparatedByString:@"•"] objectAtIndex:0]);
    NSArray *types = [NSArray arrayWithObjects:
                      @"Song", @"Video", @"Album", @"Playlist", @"Episode",
                      @"Artist", @"Profile", @"Podcast", @"Mix", nil];
    for (NSString *type in types)
        if ([first caseInsensitiveCompare:type] == NSOrderedSame) return type;
    return nil;
}

static BOOL TuneTubeIsCountText(NSString *value) {
    NSString *text = [[TuneTubeCleanText(value) lowercaseString]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [text hasSuffix:@" view"] || [text hasSuffix:@" views"] ||
           [text hasSuffix:@" play"] || [text hasSuffix:@" plays"];
}

static NSString *TuneTubeArtistFromMetadataText(NSString *value) {
    NSString *clean = TuneTubeCleanText(value);
    if (!clean || TuneTubeIsErrorText(clean) || TuneTubeIsPlaceholderArtist(clean) ||
        TuneTubeLooksLikeClock(clean) ||
        TuneTubeIsCountText(clean)) return nil;

    NSArray *parts = [clean componentsSeparatedByString:@"•"];
    if ([parts count] > 1) {
        BOOL typeLabel = TuneTubeIsTypeLabel(TuneTubeCleanText([parts objectAtIndex:0]));
        NSString *artist = TuneTubeCleanText([parts objectAtIndex:typeLabel ? 1 : 0]);
        if (!artist || TuneTubeIsErrorText(artist) || TuneTubeIsPlaceholderArtist(artist) ||
            TuneTubeLooksLikeClock(artist) ||
            TuneTubeIsCountText(artist)) return nil;
        return artist;
    }

    return TuneTubeIsTypeLabel(clean) ? nil : clean;
}

static NSString *TuneTubeAlbumFromMetadataText(NSString *value) {
    NSString *clean = TuneTubeCleanText(value);
    if (!clean) return nil;

    NSArray *parts = [clean componentsSeparatedByString:@"•"];
    if ([parts count] < 2) return nil;

    BOOL typeLabel = TuneTubeIsTypeLabel(TuneTubeCleanText([parts objectAtIndex:0]));
    NSUInteger albumIndex = typeLabel ? 2 : 1;
    if ([parts count] <= albumIndex)
        return nil;

    NSString *album = TuneTubeCleanText([parts objectAtIndex:albumIndex]);
    return TuneTubeIsErrorText(album) || TuneTubeLooksLikeClock(album) || TuneTubeIsCountText(album)
        ? nil : album;
}

NSString *TuneTubeDisplayArtist(NSString *artist) {
    if (!artist.length || TuneTubeIsPlaceholderArtist(artist)) return @"Unknown artist";
    NSString *displayArtist = TuneTubeArtistFromMetadataText(artist);
    if (displayArtist.length) return displayArtist;
    NSString *clean = TuneTubeCleanText(artist);
    if (clean.length && !TuneTubeIsErrorText(clean) && !TuneTubeIsPlaceholderArtist(clean) &&
        !TuneTubeIsTypeLabel(clean))
        return clean;
    return @"Unknown artist";
}

NSString *TuneTubeTrackArtistText(TuneTubeTrack *track) {
    NSString *artist = TuneTubeDisplayArtist(track.artist);
    if ([artist caseInsensitiveCompare:@"Unknown artist"] != NSOrderedSame)
        return artist;
    if (track.isPlaylist) return @"YouTube Music";
    return @"Various Artists";
}

static BOOL TuneTubeBrowseLooksLikeArtist(NSDictionary *browse) {
    if (![browse isKindOfClass:[NSDictionary class]]) return NO;
    NSString *browseID = TuneTubeString([browse objectForKey:@"browseId"]);
    if ([browseID hasPrefix:@"UC"] || [browseID hasPrefix:@"MPLA"] ||
        [browseID hasPrefix:@"FEmusic_library_privately_owned_artist"])
        return YES;
    NSDictionary *context = [browse objectForKey:@"browseEndpointContextSupportedConfigs"];
    NSDictionary *musicConfig = [context objectForKey:@"browseEndpointContextMusicConfig"];
    NSString *pageType = TuneTubeString([musicConfig objectForKey:@"pageType"]);
    if ([pageType rangeOfString:@"ARTIST" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return YES;
    return NO;
}

static NSString *TuneTubeArtistBrowseID(id node) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSString *label = TuneTubeText([dict objectForKey:@"text"]);
        if (!label) label = TuneTubeText([dict objectForKey:@"defaultText"]);
        NSDictionary *endpoint = [dict objectForKey:@"navigationEndpoint"];
        if (![endpoint isKindOfClass:[NSDictionary class]])
            endpoint = [dict objectForKey:@"defaultNavigationEndpoint"];
        NSDictionary *browse = [endpoint objectForKey:@"browseEndpoint"];
        if (TuneTubeBrowseLooksLikeArtist(browse)) {
            NSString *browseID = TuneTubeString([browse objectForKey:@"browseId"]);
            if (browseID.length) return browseID;
        }
        if ([label rangeOfString:@"go to artist" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            NSString *browseID = TuneTubeString([browse objectForKey:@"browseId"]);
            if (browseID.length) return browseID;
        }
        for (id value in [dict allValues]) {
            NSString *found = TuneTubeArtistBrowseID(value);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = TuneTubeArtistBrowseID(value);
            if (found.length) return found;
        }
    }
    return nil;
}

// pick artist name from a run that links to an artist page
static NSString *TuneTubeArtistNameFromRuns(id node) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSArray *runs = [dict objectForKey:@"runs"];
        if ([runs isKindOfClass:[NSArray class]]) {
            for (id run in runs) {
                if (![run isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *endpoint = [run objectForKey:@"navigationEndpoint"];
                NSDictionary *browse = [endpoint objectForKey:@"browseEndpoint"];
                if (!TuneTubeBrowseLooksLikeArtist(browse)) continue;
                NSString *text = TuneTubeText(run);
                if (text.length && !TuneTubeIsTypeLabel(text) && !TuneTubeLooksLikeClock(text) &&
                    !TuneTubeIsCountText(text) && !TuneTubeIsPlaceholderArtist(text))
                    return text;
            }
        }
        for (id value in [dict allValues]) {
            NSString *found = TuneTubeArtistNameFromRuns(value);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = TuneTubeArtistNameFromRuns(value);
            if (found.length) return found;
        }
    }
    return nil;
}

static NSString *TuneTubeResolveResultType(NSString *musicVideoType, NSArray *texts) {
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
        NSString *type = TuneTubeResultTypeFromText(text);
        if (type.length) return type;
    }
    // playable items without a video marker stay songs
    return @"Song";
}

static NSString *TuneTubeFindClockText(id node) {
    if ([node isKindOfClass:[NSString class]]) {
        NSString *text = TuneTubeCleanText((NSString *)node);
        if (TuneTubeLooksLikeClock(text)) return text;
        for (NSString *part in [text componentsSeparatedByString:@"•"]) {
            NSString *candidate = TuneTubeCleanText(part);
            if (TuneTubeLooksLikeClock(candidate)) return candidate;
        }
    } else if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        for (NSString *key in [NSArray arrayWithObjects:@"text", @"simpleText", nil]) {
            NSString *text = TuneTubeText([dict objectForKey:key]);
            if (text && TuneTubeLooksLikeClock(text)) return text;
        }
        for (id value in [dict allValues]) {
            NSString *found = TuneTubeFindClockText(value);
            if (found) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = TuneTubeFindClockText(value);
            if (found) return found;
        }
    }
    return nil;
}

static TuneTubeTrack *TuneTubeTrackFromRenderer(NSDictionary *renderer) {
    NSDictionary *columns = [renderer objectForKey:@"flexColumns"];
    if (![columns isKindOfClass:[NSArray class]] || [columns count] == 0) return nil;

    NSMutableArray *texts = [NSMutableArray array];
    for (NSDictionary *column in columns) {
        NSDictionary *columnRenderer = [column objectForKey:@"musicResponsiveListItemFlexColumnRenderer"];
        NSString *text = TuneTubeText([columnRenderer objectForKey:@"text"]);
        if (text) [texts addObject:text];
    }

    if ([texts count] == 0) return nil;

    NSString *title = [texts objectAtIndex:0];
    BOOL isPlaylist = NO;
    NSString *musicVideoType = TuneTubeFindStringForKey(renderer, @"musicVideoType");
    NSString *resultType = TuneTubeResolveResultType(musicVideoType, texts);
    for (NSString *text in texts)
        if ([text rangeOfString:@"Playlist" options:NSCaseInsensitiveSearch].location != NSNotFound)
            isPlaylist = YES;
    NSString *playlistID = TuneTubeFindStringForKey(renderer, @"playlistId");
    if (!playlistID.length) {
        NSString *browseID = TuneTubeFindStringForKey(renderer, @"browseId");
        if ([browseID hasPrefix:@"VL"] && browseID.length > 2)
            playlistID = [browseID substringFromIndex:2];
    }
    NSString *videoID = TuneTubeFindStringForKey(renderer, @"videoId");
    if (!videoID.length && !isPlaylist) return nil;
    NSMutableArray *metadata = [NSMutableArray array];
    for (NSUInteger index = 1; index < [texts count]; ++index) {
        NSString *text = [texts objectAtIndex:index];
        /* keep duration separate because some responses put it in its own column */
        if (!TuneTubeLooksLikeClock(text)) [metadata addObject:text];
    }

    // prefer the run that actually links to an artist page
    NSString *artist = TuneTubeArtistNameFromRuns(renderer);
    NSString *album = @"";
    NSUInteger artistIndex = NSNotFound;

    if (!artist.length) {
        for (NSUInteger index = 0; index < metadata.count; ++index) {
            NSString *candidate = TuneTubeArtistFromMetadataText([metadata objectAtIndex:index]);
            if (!candidate) continue;
            artist = candidate;
            artistIndex = index;
            album = TuneTubeAlbumFromMetadataText([metadata objectAtIndex:index]) ?: @"";
            break;
        }
    } else {
        // still try to pull album from the first metadata line
        for (NSUInteger index = 0; index < metadata.count; ++index) {
            album = TuneTubeAlbumFromMetadataText([metadata objectAtIndex:index]) ?: @"";
            if (album.length) {
                artistIndex = index;
                break;
            }
        }
    }
    if (artistIndex != NSNotFound && !album.length) {
        for (NSUInteger index = artistIndex + 1; index < metadata.count; ++index) {
            NSString *candidate = TuneTubeArtistFromMetadataText([metadata objectAtIndex:index]);
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
            NSString *byline = TuneTubeFindTextForKey(renderer, key);
            NSString *candidate = TuneTubeArtistFromMetadataText(byline);
            if (candidate.length) {
                artist = candidate;
                if (!album.length) album = TuneTubeAlbumFromMetadataText(byline) ?: @"";
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
                NSString *left = TuneTubeCleanText([title substringToIndex:range.location]);
                NSString *right = TuneTubeCleanText([title substringFromIndex:range.location + range.length]);
                // "artist - title" is the usual form
                if (left.length && right.length && !TuneTubeLooksLikeClock(left)) {
                    artist = left;
                    title = right;
                }
                break;
            }
        }
    }

    NSUInteger duration = 0;
    NSString *clock = TuneTubeFindClockText(renderer);
    if (clock)
        duration = TuneTubeClockSeconds(clock);

    NSString *artistID = isPlaylist ? nil : TuneTubeArtistBrowseID(renderer);
    NSString *displayArtist = TuneTubeDisplayArtist(artist);
    // last resort: accessibility label often has "title by artist"
    if ([displayArtist caseInsensitiveCompare:@"Unknown artist"] == NSOrderedSame) {
        NSString *access = TuneTubeFindTextForKey(renderer, @"accessibilityData");
        if (!access.length) access = TuneTubeFindTextForKey(renderer, @"label");
        if (access.length) {
            NSRange byRange = [access rangeOfString:@" by " options:NSCaseInsensitiveSearch];
            if (byRange.location != NSNotFound) {
                NSString *after = TuneTubeCleanText([access substringFromIndex:byRange.location + byRange.length]);
                // strip trailing " and n more" / duration junk
                NSArray *cut = [after componentsSeparatedByString:@","];
                NSString *maybe = TuneTubeCleanText([cut objectAtIndex:0]);
                NSArray *cut2 = [maybe componentsSeparatedByString:@"•"];
                maybe = TuneTubeCleanText([cut2 objectAtIndex:0]);
                if (maybe.length && !TuneTubeIsTypeLabel(maybe) && !TuneTubeLooksLikeClock(maybe))
                    displayArtist = maybe;
            }
        }
    }

    return [[[TuneTubeTrack alloc] initWithVideoID:videoID
                                        title:title
                                       artist:displayArtist
                                        album:album
                                thumbnailURL:TuneTubeThumbnail(renderer)
                                     duration:duration
                                  playlistID:isPlaylist ? playlistID : nil
                                    artistID:artistID
                                 resultType:resultType] autorelease];
}

static void TuneTubeCollectTracks(id node, NSMutableArray *tracks) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSDictionary *renderer = [dict objectForKey:@"musicResponsiveListItemRenderer"];
        if ([renderer isKindOfClass:[NSDictionary class]]) {
            TuneTubeTrack *track = TuneTubeTrackFromRenderer(renderer);
            if (track) {
                [tracks addObject:track];
                return;
            }
        }
        for (id value in [dict allValues]) TuneTubeCollectTracks(value, tracks);
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) TuneTubeCollectTracks(value, tracks);
    }
}

static NSDictionary *TuneTubeClientContext(void) {
    NSDictionary *client = [NSDictionary dictionaryWithObjectsAndKeys:
                            TuneTubeClientName, @"clientName",
                            TuneTubeClientVersion, @"clientVersion",
                            @"en", @"hl",
                            @"US", @"gl",
                            nil];
    return [NSDictionary dictionaryWithObject:client forKey:@"client"];
}

static NSDictionary *TuneTubePlayerContext(NSString *clientName, NSString *clientVersion) {
    NSMutableDictionary *client = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                   clientName, @"clientName",
                                   clientVersion, @"clientVersion",
                                   @"en", @"hl",
                                   @"US", @"gl",
                                   nil];

    if ([clientName isEqualToString:TuneTubeIOSClientName]) {
        [client setObject:@"Apple" forKey:@"deviceMake"];
        [client setObject:@"iPhone16,2" forKey:@"deviceModel"];
        [client setObject:@"iPhone" forKey:@"osName"];
        [client setObject:@"18.3.2.22D82" forKey:@"osVersion"];
        [client setObject:@"com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)" forKey:@"userAgent"];
    } else if ([clientName isEqualToString:TuneTubeAndroidClientName]) {
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

static NSURLRequest *TuneTubeRequestForEndpoint(NSString *endpoint,
                                           NSString *origin,
                                           NSString *clientHeaderName,
                                           NSString *clientVersion,
                                           NSString *userAgent,
                                           NSString *path,
                                           NSString *apiKey,
                                           NSDictionary *body,
                                           NSError **error) {
    if (![apiKey length]) {
        if (error) *error = TuneTubeError(1, @"YouTube Music API key is empty");
        return nil;
    }

    NSString *escapedKey = [apiKey stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@?key=%@",
                                       endpoint, path, escapedKey]];
    if (!url) {
        if (error) *error = TuneTubeError(2, @"invalid YouTube Music endpoint");
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

static NSURLRequest *TuneTubeRequest(NSString *path, NSString *apiKey, NSDictionary *body,
                                NSError **error) {
    return TuneTubeRequestForEndpoint(TuneTubeEndpoint,
                                 @"https://music.youtube.com",
                                 @"67",
                                 TuneTubeClientVersion,
                                 @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
                                 path, apiKey, body, error);
}

typedef void (^TuneTubeNetworkCompletion)(NSData *data, NSError *error);

static BOOL TuneTubeShouldTryFallback(NSError *error) {
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
static void TuneTubeSendRequest(NSURLRequest *request, NSURLRequest *fallback,
                           TuneTubeNetworkCompletion completion) {
    [NSURLConnection sendAsynchronousRequest:request
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
        (void)response;
        if (error && fallback && TuneTubeShouldTryFallback(error)) {
            TuneTubeSendRequest(fallback, nil, completion);
            return;
        }
        completion(data, error);
    }];
}

static void TuneTubeDecodeResponse(NSData *data, void (^completion)(id root, NSError *error)) {
    NSError *error = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (!root) {
        completion(nil, error ? error : TuneTubeError(3, @"invalid JSON response"));
        return;
    }
    completion(root, nil);
}

@implementation TuneTubeTrack

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

@implementation TuneTubeAPI

- (id)initWithAPIKey:(NSString *)apiKey {
    self = [super init];
    if (!self) return nil;
    _apiKey = [apiKey copy];
    return self;
}

- (void)durationForTrack:(TuneTubeTrack *)track completion:(TuneTubeDurationCompletion)completion {
    if (!completion) return;
    if (!track.videoID.length) {
        completion(0, TuneTubeError(6, @"track has no video id"));
        return;
    }

    NSString *iosUA = @"com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)";
    NSString *androidUA = @"com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip";
    NSString *vrUA = @"com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";
    TuneTubeDurationWithPlayerClient(track.videoID, _apiKey,
                                     TuneTubeAndroidVRClientName, TuneTubeAndroidVRClientVersion,
                                     @"28", vrUA, ^(NSUInteger duration, NSError *vrError) {
        if (duration) {
            completion(duration, nil);
            return;
        }
        TuneTubeDurationWithPlayerClient(track.videoID, _apiKey,
                                         TuneTubeIOSClientName, TuneTubeIOSClientVersion,
                                         @"5", iosUA, ^(NSUInteger iosDuration, NSError *iosError) {
            if (iosDuration) {
                completion(iosDuration, nil);
                return;
            }
            TuneTubeDurationWithPlayerClient(track.videoID, _apiKey,
                                             TuneTubeAndroidClientName, TuneTubeAndroidClientVersion,
                                             @"3", androidUA, ^(NSUInteger androidDuration,
                                                               NSError *androidError) {
                completion(androidDuration,
                           androidDuration ? nil :
                           (androidError ? androidError :
                            (iosError ? iosError : vrError)));
            });
        });
    });
}

- (void)dealloc {
    [_apiKey release];
    [super dealloc];
}

- (void)search:(NSString *)query completion:(TuneTubeSearchCompletion)completion {
    if (!completion) return;
    if (![query length]) {
        completion(nil, TuneTubeError(4, @"search query is empty"));
        return;
    }

    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          TuneTubeClientContext(), @"context",
                          query, @"query",
                          nil];
    NSError *error = nil;
    NSURLRequest *request = TuneTubeRequest(@"search", _apiKey, body, &error);
    NSError *fallbackError = nil;
    NSURLRequest *fallbackRequest = TuneTubeRequestForEndpoint(
        TuneTubeEndpointFallback, @"https://youtubei.googleapis.com", @"67",
        TuneTubeClientVersion,
        @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
        @"search", _apiKey, body, &fallbackError);
    NSError *webFallbackError = nil;
    NSURLRequest *webFallbackRequest = TuneTubeRequestForEndpoint(
        TuneTubeEndpointWebFallback, @"https://www.youtube.com", @"67",
        TuneTubeClientVersion,
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
        TuneTubeDecodeResponse(data, ^(id root, NSError *jsonError) {
            if (jsonError) {
                completion(nil, jsonError);
                return;
            }
            NSMutableArray *tracks = [NSMutableArray array];
            TuneTubeCollectTracks(root, tracks);
            if ([tracks count] == 0) {
                completion(nil, TuneTubeError(5, @"no playable music results in response"));
                return;
            }
            completion(tracks, nil);
        });
    };

    TuneTubeSendRequest(request, fallbackRequest, ^(NSData *data, NSError *networkError) {
        if (networkError && webFallbackRequest && TuneTubeShouldTryFallback(networkError)) {
            TuneTubeSendRequest(webFallbackRequest, nil, finish);
            return;
        }
        finish(data, networkError);
    });
}

- (void)playlistTracksForID:(NSString *)playlistID completion:(TuneTubeSearchCompletion)completion {
    if (!completion) return;
    if (!playlistID.length) {
        completion(nil, TuneTubeError(13, @"playlist has no id"));
        return;
    }
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          TuneTubeClientContext(), @"context",
                          playlistID, @"browseId", nil];
    NSError *error = nil;
    NSURLRequest *request = TuneTubeRequest(@"browse", _apiKey, body, &error);
    NSError *fallbackError = nil;
    NSURLRequest *fallback = TuneTubeRequestForEndpoint(
        TuneTubeEndpointFallback, @"https://youtubei.googleapis.com", @"67",
        TuneTubeClientVersion,
        @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
        @"browse", _apiKey, body, &fallbackError);
    if (!request) {
        completion(nil, error);
        return;
    }
    TuneTubeSendRequest(request, fallback, ^(NSData *data, NSError *networkError) {
        if (networkError) {
            completion(nil, networkError);
            return;
        }
        TuneTubeDecodeResponse(data, ^(id root, NSError *jsonError) {
            if (jsonError) {
                completion(nil, jsonError);
                return;
            }
            NSMutableArray *tracks = [NSMutableArray array];
            TuneTubeCollectTracks(root, tracks);
            if (!tracks.count) {
                completion(nil, TuneTubeError(14, @"playlist has no playable tracks"));
                return;
            }
            completion(tracks, nil);
        });
    });
}

- (void)artistInfoForID:(NSString *)artistID completion:(TuneTubeArtistCompletion)completion {
    if (!completion) return;
    if (!artistID.length) {
        completion(nil, nil, TuneTubeError(15, @"artist has no id"));
        return;
    }
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          TuneTubeClientContext(), @"context",
                          artistID, @"browseId", nil];
    NSError *error = nil;
    NSURLRequest *request = TuneTubeRequest(@"browse", _apiKey, body, &error);
    NSError *fallbackError = nil;
    NSURLRequest *fallback = TuneTubeRequestForEndpoint(
        TuneTubeEndpointFallback, @"https://youtubei.googleapis.com", @"67",
        TuneTubeClientVersion,
        @"Mozilla/5.0 (iPhone; CPU iOS 6_0 like Mac OS X) AppleWebKit/534.46 Mobile/9A334 Safari/7534.48.3",
        @"browse", _apiKey, body, &fallbackError);
    if (!request) {
        completion(nil, nil, error);
        return;
    }
    TuneTubeSendRequest(request, fallback, ^(NSData *data, NSError *networkError) {
        if (networkError) {
            completion(nil, nil, networkError);
            return;
        }
        TuneTubeDecodeResponse(data, ^(id root, NSError *jsonError) {
            if (jsonError) {
                completion(nil, nil, jsonError);
                return;
            }
            NSString *name = TuneTubeFindTextForKey(root, @"title");
            // prefer true channel avatar urls over album art
            NSString *avatar = TuneTubeBestAvatarThumbnail(root);
            if (!avatar.length) avatar = TuneTubeHeaderThumbnail(root);
            if (!avatar.length) avatar = TuneTubeThumbnail(root);
            completion(name, avatar, nil);
        });
    });
}

static NSURL *TuneTubeDirectAudioURL(id root, BOOL *ciphered) {
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
            NSString *mime = TuneTubeString([format objectForKey:@"mimeType"]);
            BOOL audioOnly = [mime hasPrefix:@"audio/"];
            BOOL iOSAudio = [mime rangeOfString:@"audio/mp4"
                                         options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [mime rangeOfString:@"mp4a."
                             options:NSCaseInsensitiveSearch].location != NSNotFound;
            BOOL combinedMP4 = listIndex == 1 &&
                [mime hasPrefix:@"video/"] &&
                [mime rangeOfString:@"mp4a."].location != NSNotFound;
            if ((!audioOnly || !iOSAudio) && !combinedMP4) continue;
            NSString *url = TuneTubeString([format objectForKey:@"url"]);
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
    if (best) return [NSURL URLWithString:TuneTubeString([best objectForKey:@"url"])];

    /* accept hls because ios may return a manifest instead of adaptive formats */
    return [NSURL URLWithString:TuneTubeString([streaming objectForKey:@"hlsManifestUrl"])];
}

static void TuneTubeDurationWithPlayerClient(NSString *videoID,
                                              NSString *apiKey,
                                              NSString *clientName,
                                              NSString *clientVersion,
                                              NSString *clientHeaderName,
                                              NSString *userAgent,
                                              TuneTubeDurationCompletion completion) {
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          TuneTubePlayerContext(clientName, clientVersion), @"context",
                          videoID, @"videoId",
                          @YES, @"contentCheckOk",
                          @YES, @"racyCheckOk",
                          nil];
    NSError *error = nil;
    NSURLRequest *request = TuneTubeRequestForEndpoint(TuneTubePlayerEndpoint,
                                                       @"https://www.youtube.com",
                                                       clientHeaderName,
                                                       clientVersion,
                                                       userAgent,
                                                       @"player",
                                                       apiKey,
                                                       body,
                                                       &error);
    NSError *fallbackError = nil;
    NSURLRequest *fallbackRequest = TuneTubeRequestForEndpoint(
        TuneTubePlayerEndpointFallback, @"https://youtubei.googleapis.com",
        clientHeaderName, clientVersion, userAgent, @"player", apiKey, body,
        &fallbackError);
    if (!request) {
        completion(0, error);
        return;
    }

    TuneTubeSendRequest(request, fallbackRequest, ^(NSData *data, NSError *networkError) {
        if (networkError) {
            completion(0, networkError);
            return;
        }
        TuneTubeDecodeResponse(data, ^(id root, NSError *jsonError) {
            if (jsonError) {
                completion(0, jsonError);
                return;
            }
            NSDictionary *details = [root isKindOfClass:[NSDictionary class]]
                ? [(NSDictionary *)root objectForKey:@"videoDetails"] : nil;
            NSString *length = TuneTubeString([details objectForKey:@"lengthSeconds"]);
            NSUInteger duration = (NSUInteger)[length integerValue];
            if (!duration) {
                NSDictionary *microformat = [root isKindOfClass:[NSDictionary class]]
                    ? [(NSDictionary *)root objectForKey:@"microformat"] : nil;
                NSDictionary *renderer = [microformat objectForKey:@"playerMicroformatRenderer"];
                duration = (NSUInteger)[TuneTubeString([renderer objectForKey:@"lengthSeconds"]) integerValue];
            }
            if (duration) {
                completion(duration, nil);
            } else {
                completion(0, TuneTubeError(16, @"track duration is missing"));
            }
        });
    });
}

static void TuneTubeAudioURLWithPlayerClient(NSString *videoID,
                                        NSString *apiKey,
                                        NSString *clientName,
                                        NSString *clientVersion,
                                        NSString *clientHeaderName,
                                        NSString *userAgent,
                                        TuneTubeAudioCompletion completion) {
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          TuneTubePlayerContext(clientName, clientVersion), @"context",
                          videoID, @"videoId",
                          @YES, @"contentCheckOk",
                          @YES, @"racyCheckOk",
                          nil];
    NSError *error = nil;
    NSURLRequest *request = TuneTubeRequestForEndpoint(TuneTubePlayerEndpoint,
                                                   @"https://www.youtube.com",
                                                   clientHeaderName,
                                                   clientVersion,
                                                   userAgent,
                                                   @"player",
                                                   apiKey,
                                                   body,
                                                   &error);
    NSError *fallbackError = nil;
    NSURLRequest *fallbackRequest = TuneTubeRequestForEndpoint(
        TuneTubePlayerEndpointFallback, @"https://youtubei.googleapis.com",
        clientHeaderName, clientVersion, userAgent, @"player", apiKey, body,
        &fallbackError);
    if (!request) {
        completion(nil, error);
        return;
    }

    TuneTubeSendRequest(request, fallbackRequest, ^(NSData *data, NSError *networkError) {
        if (networkError) {
            completion(nil, networkError);
            return;
        }
        TuneTubeDecodeResponse(data, ^(id root, NSError *jsonError) {
            BOOL ciphered = NO;
            NSURL *url;
            if (jsonError) {
                completion(nil, jsonError);
                return;
            }
            url = TuneTubeDirectAudioURL(root, &ciphered);
            if (url) {
                completion(url, nil);
                return;
            }

            NSDictionary *playability = [root isKindOfClass:[NSDictionary class]]
                ? [(NSDictionary *)root objectForKey:@"playabilityStatus"] : nil;
            NSString *reason = TuneTubeString([playability objectForKey:@"reason"]);
            if ([reason length]) {
                completion(nil, TuneTubeError(8, [NSString stringWithFormat:@"%@ player: %@", clientName, reason]));
            } else if (ciphered) {
                completion(nil, TuneTubeError(7, @"audio format is ciphered; decipher support is not enabled yet"));
            } else {
                completion(nil, TuneTubeError(8, [NSString stringWithFormat:@"%@ player response has no audio format", clientName]));
            }
        });
    });
}

- (void)audioURLForTrack:(TuneTubeTrack *)track completion:(TuneTubeAudioCompletion)completion {
    if (!completion) return;
    if (![track.videoID length]) {
        completion(nil, TuneTubeError(6, @"track has no video id"));
        return;
    }

    NSString *iosUA = @"com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)";
    NSString *androidUA = @"com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip";
    NSString *vrUA = @"com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";
    TuneTubeAudioURLWithPlayerClient(track.videoID, _apiKey,
                                TuneTubeAndroidVRClientName, TuneTubeAndroidVRClientVersion, @"28", vrUA,
                                ^(NSURL *vrURL, NSError *vrError) {
        if (vrURL) {
            completion(vrURL, nil);
            return;
        }
        TuneTubeAudioURLWithPlayerClient(track.videoID, _apiKey,
                                TuneTubeIOSClientName, TuneTubeIOSClientVersion, @"5", iosUA,
                                ^(NSURL *url, NSError *iosError) {
        if (url) {
            completion(url, nil);
            return;
        }
        TuneTubeAudioURLWithPlayerClient(track.videoID, _apiKey,
                                    TuneTubeAndroidClientName, TuneTubeAndroidClientVersion, @"3", androidUA,
                                    ^(NSURL *androidURL, NSError *androidError) {
            if (androidURL) {
                completion(androidURL, nil);
                return;
            }
            TuneTubeAudioURLWithPlayerClient(track.videoID, _apiKey,
                                        TuneTubeAndroidVRClientName, TuneTubeAndroidVRClientVersion, @"28", vrUA,
                                        ^(NSURL *fallbackURL, NSError *fallbackError) {
                completion(fallbackURL, fallbackURL ? nil :
                           (fallbackError ? fallbackError :
                            (androidError ? androidError :
                             (iosError ? iosError : vrError))));
            });
        });
        });
    });
}

@end
