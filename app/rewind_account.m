#import "rewind_account.h"

#include <stdio.h>
#include <math.h>

#import "rewind_api.h"
#import "rewind_l10n.h"
#import "rewind_http.h"

NSString * const RewindAccountDidChangeNotification = @"RewindAccountDidChangeNotification";
NSString * const RewindAccountLibraryDidChangeNotification = @"RewindAccountLibraryDidChangeNotification";

/* keep the tv client for existing tokens; configured oauth projects enable data api writes */
static NSString * const RewindOAuthClientID =
    @"861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com";
static NSString * const RewindOAuthClientSecret = @"SboVhoG9s0rNafixCSGGKXAT";
static NSString * const RewindOAuthScope = @"https://www.googleapis.com/auth/youtube";
static NSString * const RewindOAuthCodeURL = @"https://oauth2.googleapis.com/device/code";
static NSString * const RewindOAuthTokenURL = @"https://oauth2.googleapis.com/token";
static NSString * const RewindOAuthRevokeURL = @"https://oauth2.googleapis.com/revoke";
static NSString * const RewindTVEndpoint = @"https://www.youtube.com/youtubei/v1";
/* same google authority; older dns setups resolve it when youtube.com fails */
static NSString * const RewindTVEndpointFallback = @"https://youtubei.googleapis.com/youtubei/v1";
static NSString * const RewindTVClientName = @"TVHTML5";
static NSString * const RewindTVClientVersion = @"7.20250101.00.00";
static NSString * const RewindAccountErrorDomain = @"com.sqmrak.rewind.account";

/* a liked music list longer than this stops paging instead of looping on a bad token */
enum { RewindAccountMaxPages = 40 };
enum { RewindAccountMaxDepth = 48 };

typedef void (^RewindTokenCompletion)(NSString *token, NSError *error);
typedef void (^RewindJSONCompletion)(NSDictionary *root, NSError *error);

@implementation RewindDeviceCode

@synthesize userCode = _userCode;
@synthesize verificationURL = _verificationURL;
@synthesize deviceCode = _deviceCode;
@synthesize interval = _interval;
@synthesize expiresAt = _expiresAt;
@synthesize cancelled = _cancelled;
@synthesize clientID = _clientID;
@synthesize clientSecret = _clientSecret;

- (id)initWithUserCode:(NSString *)userCode verificationURL:(NSString *)url
            deviceCode:(NSString *)deviceCode interval:(NSTimeInterval)interval
             expiresIn:(NSTimeInterval)expiresIn clientID:(NSString *)clientID
          clientSecret:(NSString *)clientSecret {
    self = [super init];
    if (!self) return nil;
    _clientID = [clientID copy];
    _clientSecret = [clientSecret copy];
    _userCode = [userCode copy];
    _verificationURL = [url copy];
    _deviceCode = [deviceCode copy];
    _interval = interval;
    _expiresAt = [[NSDate alloc] initWithTimeIntervalSinceNow:expiresIn];
    return self;
}

- (void)dealloc {
    [_clientID release];
    [_clientSecret release];
    [_userCode release];
    [_verificationURL release];
    [_deviceCode release];
    [_expiresAt release];
    [super dealloc];
}

@end


typedef struct {
    BOOL loaded;
    NSUInteger generation;
    NSString *refreshToken;
    NSString *clientID;
    NSString *clientSecret;
    NSString *oauthClientID;
    NSString *oauthClientSecret;
    NSString *accessToken;
    NSTimeInterval accessExpiresAt;
    NSString *name;
    NSString *email;
    NSString *photoURL;
    NSMutableSet *likedIDs;
    NSMutableSet *dislikedIDs;
    NSArray *likedTracks;
    NSTimeInterval likedLoadedAt;
    NSArray *playlists;
    NSUInteger playlistsRequest;
    NSMutableArray *refreshWaiters;
} rewind_account_state_t;

static rewind_account_state_t g_account;

static NSError *RewindAccountError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:RewindAccountErrorDomain
                               code:code
                           userInfo:[NSDictionary dictionaryWithObject:message ?: @"account error"
                                                                forKey:NSLocalizedDescriptionKey]];
}

static NSString *RewindAccountString(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length] ? value : nil;
}

static NSDictionary *RewindAccountDict(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSArray *RewindAccountArray(id value) {
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static NSTimeInterval RewindAccountSeconds(id value, NSTimeInterval fallback) {
    if (![value isKindOfClass:[NSNumber class]]) return fallback;
    NSTimeInterval seconds = [value doubleValue];
    return isfinite(seconds) && seconds > 0 ? seconds : fallback;
}

static void RewindAccountSetString(NSString **slot, NSString *value) {
    if (*slot == value) return;
    [*slot release];
    *slot = [value copy];
}

static NSString *RewindAccountStorePath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Rewind/account.plist"];
}

static void RewindAccountLoadState(void) {
    if (g_account.loaded) return;
    g_account.loaded = YES;
    g_account.likedIDs = [[NSMutableSet alloc] init];
    g_account.dislikedIDs = [[NSMutableSet alloc] init];
    g_account.refreshWaiters = [[NSMutableArray alloc] init];
    NSData *data = [NSData dataWithContentsOfFile:RewindAccountStorePath()];
    if (!data.length) return;
    NSDictionary *stored = RewindAccountDict([NSPropertyListSerialization
                                              propertyListWithData:data options:0
                                              format:NULL error:NULL]);
    RewindAccountSetString(&g_account.oauthClientID, RewindAccountString([stored objectForKey:@"oauthClientID"]));
    RewindAccountSetString(&g_account.oauthClientSecret, RewindAccountString([stored objectForKey:@"oauthClientSecret"]));
    NSString *refresh = RewindAccountString([stored objectForKey:@"refresh"]);
    if (!refresh) return;
    RewindAccountSetString(&g_account.refreshToken, refresh);
    RewindAccountSetString(&g_account.clientID, RewindAccountString([stored objectForKey:@"clientID"]) ?: RewindOAuthClientID);
    RewindAccountSetString(&g_account.clientSecret, RewindAccountString([stored objectForKey:@"clientSecret"]) ?:
        ([g_account.clientID isEqualToString:RewindOAuthClientID] ? RewindOAuthClientSecret : @""));
    /* older stores used the first account entry, which could belong to another channel */
    id profileVersion = [stored objectForKey:@"profileVersion"];
    if (![profileVersion isKindOfClass:[NSNumber class]] || [profileVersion integerValue] != 2) return;
    RewindAccountSetString(&g_account.name, RewindAccountString([stored objectForKey:@"name"]));
    RewindAccountSetString(&g_account.email, RewindAccountString([stored objectForKey:@"email"]));
    RewindAccountSetString(&g_account.photoURL, RewindAccountString([stored objectForKey:@"photo"]));
}

/* the refresh token is a long lived credential; keep it out of the world readable defaults plist */
static BOOL RewindAccountWriteState(const rewind_account_state_t *account) {
    NSString *path = RewindAccountStorePath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!account->refreshToken.length && !account->oauthClientID.length) {
        NSError *error = nil;
        if ([fm fileExistsAtPath:path] && ![fm removeItemAtPath:path error:&error]) {
            NSLog(@"rewind: cannot remove account store: %@", error);
            return NO;
        }
        return YES;
    }
    NSMutableDictionary *stored = [NSMutableDictionary dictionary];
    if (account->oauthClientID) [stored setObject:account->oauthClientID forKey:@"oauthClientID"];
    if (account->oauthClientSecret) [stored setObject:account->oauthClientSecret forKey:@"oauthClientSecret"];
    if (account->refreshToken) {
        [stored setObject:account->refreshToken forKey:@"refresh"];
        if (account->clientID) [stored setObject:account->clientID forKey:@"clientID"];
        if (account->clientSecret) [stored setObject:account->clientSecret forKey:@"clientSecret"];
    }
    if (account->name) {
        [stored setObject:account->name forKey:@"name"];
        [stored setObject:[NSNumber numberWithInteger:2] forKey:@"profileVersion"];
    }
    if (account->email) [stored setObject:account->email forKey:@"email"];
    if (account->photoURL) [stored setObject:account->photoURL forKey:@"photo"];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:stored
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0 error:NULL];
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSDictionary *dirAttrs = [NSDictionary dictionaryWithObject:[NSNumber numberWithShort:0700]
                                                         forKey:NSFilePosixPermissions];
    if (!data || ![fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                                 attributes:dirAttrs error:NULL]) {
        NSLog(@"rewind: cannot prepare account store at %@", dir);
        return NO;
    }
    NSString *temp = [path stringByAppendingString:@".tmp"];
    NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
                           [NSNumber numberWithShort:0600], NSFilePosixPermissions,
                           NSFileProtectionCompleteUntilFirstUserAuthentication, NSFileProtectionKey,
                           nil];
    [fm removeItemAtPath:temp error:NULL];
    if (![fm createFileAtPath:temp contents:data attributes:attrs] ||
        rename([temp fileSystemRepresentation], [path fileSystemRepresentation]) != 0) {
        NSLog(@"rewind: cannot write account store at %@", path);
        [fm removeItemAtPath:temp error:NULL];
        return NO;
    }
    return YES;
}

static BOOL RewindAccountSaveState(void) {
    return RewindAccountWriteState(&g_account);
}

NSString *RewindAccountOAuthClientID(void) {
    RewindAccountLoadState();
    return g_account.oauthClientID;
}

static BOOL RewindAccountOAuthCredential(NSString *value, BOOL clientID) {
    if (![value isKindOfClass:[NSString class]] || !value.length || value.length > 512) return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"] invertedSet];
    if ([value rangeOfCharacterFromSet:invalid].location != NSNotFound) return NO;
    return !clientID || (value.length > [@".apps.googleusercontent.com" length] &&
        [value hasSuffix:@".apps.googleusercontent.com"]);
}

BOOL RewindAccountSetOAuthClient(NSString *clientID, NSString *clientSecret, NSError **error) {
    if (error) *error = nil;
    RewindAccountLoadState();
    BOOL reset = !clientID && !clientSecret;
    if (!reset && (!clientSecret || ([clientSecret isKindOfClass:[NSString class]] && !clientSecret.length)) &&
        [clientID isKindOfClass:[NSString class]] && [clientID isEqualToString:g_account.oauthClientID])
        clientSecret = g_account.oauthClientSecret;
    if (!reset && (!RewindAccountOAuthCredential(clientID, YES) ||
                   !RewindAccountOAuthCredential(clientSecret, NO))) {
        if (error) *error = RewindAccountError(400, RewindLanguageIsRussian()
            ? @"Введите ID клиента OAuth и секрет для типа TVs and Limited Input devices"
            : @"Enter an OAuth client ID and secret for TVs and Limited Input devices");
        return NO;
    }
    rewind_account_state_t candidate = g_account;
    candidate.oauthClientID = reset ? nil : clientID;
    candidate.oauthClientSecret = reset ? nil : clientSecret;
    if (!RewindAccountWriteState(&candidate)) {
        if (error) *error = RewindAccountError(500, RewindL(@"account_store_failed"));
        return NO;
    }
    RewindAccountSetString(&g_account.oauthClientID, candidate.oauthClientID);
    RewindAccountSetString(&g_account.oauthClientSecret, candidate.oauthClientSecret);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:@"RewindOAuthClientID"];
    [defaults removeObjectForKey:@"RewindOAuthClientSecret"];
    if (![defaults synchronize]) {
        if (error) *error = RewindAccountError(500, @"OAuth setup was saved, but the old defaults could not be removed");
        return NO;
    }
    return YES;
}

static void RewindAccountPost(NSString *name) {
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil];
}

static void RewindAccountClear(NSError *waiterError, BOOL removeStore) {
    NSArray *waiters = [g_account.refreshWaiters copy];
    ++g_account.generation;
    RewindAccountSetString(&g_account.refreshToken, nil);
    RewindAccountSetString(&g_account.accessToken, nil);
    RewindAccountSetString(&g_account.name, nil);
    RewindAccountSetString(&g_account.email, nil);
    RewindAccountSetString(&g_account.photoURL, nil);
    g_account.accessExpiresAt = 0;
    [g_account.likedIDs removeAllObjects];
    [g_account.dislikedIDs removeAllObjects];
    [g_account.likedTracks release];
    g_account.likedTracks = nil;
    g_account.likedLoadedAt = 0;
    [g_account.playlists release];
    g_account.playlists = nil;
    ++g_account.playlistsRequest;
    [g_account.refreshWaiters removeAllObjects];
    if (removeStore) RewindAccountSaveState();
    for (RewindTokenCompletion waiter in waiters) waiter(nil, waiterError);
    [waiters release];
    RewindAccountPost(RewindAccountDidChangeNotification);
    RewindAccountPost(RewindAccountLibraryDidChangeNotification);
}

static BOOL RewindAccountSignedInLoaded(void) {
    RewindAccountLoadState();
    return g_account.refreshToken.length > 0;
}

BOOL RewindAccountIsSignedIn(void) { return RewindAccountSignedInLoaded(); }
NSString *RewindAccountName(void) { RewindAccountLoadState(); return g_account.name; }
NSString *RewindAccountEmail(void) { RewindAccountLoadState(); return g_account.email; }
NSString *RewindAccountPhotoURL(void) { RewindAccountLoadState(); return g_account.photoURL; }

static NSString *RewindAccountEscape(NSString *value) {
    CFStringRef escaped = CFURLCreateStringByAddingPercentEscapes(
        NULL, (CFStringRef)value, NULL, CFSTR("!*'();:@&=+$,/?%#[]"), kCFStringEncodingUTF8);
    return [(NSString *)escaped autorelease];
}

static NSURLRequest *RewindAccountFormRequest(NSString *url, NSDictionary *fields) {
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *key in [[fields allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", key,
                          RewindAccountEscape([fields objectForKey:key])]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:20.0];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:[[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding]];
    return request;
}

typedef void (^RewindHTTPCompletion)(NSInteger status, id json, NSError *error);

/* tv browse pages run to half a megabyte of json; decoding waits off the main thread */
static NSOperationQueue *RewindAccountQueue(void) {
    static NSOperationQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [[NSOperationQueue alloc] init];
        [queue setMaxConcurrentOperationCount:4];
    });
    return queue;
}

static void RewindAccountSend(NSURLRequest *request, RewindHTTPCompletion completion) {
    RewindHTTPCompletion done = [[completion copy] autorelease];
    [RewindAccountQueue() addOperationWithBlock:^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSHTTPURLResponse *response = nil;
        NSError *error = nil;
        NSData *data = RewindHTTPFetch(request, 4 * 1024 * 1024, &response, &error);
        NSInteger status = response.statusCode;
        if (error && error.code == NSURLErrorUserCancelledAuthentication) {
            status = 401;
            error = nil;
        }
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(status, json, error); });
        [pool drain];
    }];
}

static NSError *RewindAccountResponseError(NSInteger status, id json) {
    NSDictionary *root = RewindAccountDict(json);
    NSDictionary *nested = RewindAccountDict([root objectForKey:@"error"]);
    NSString *message = RewindAccountString([nested objectForKey:@"message"]);
    if (!message) message = RewindAccountString([root objectForKey:@"error_description"]);
    if (!message) message = RewindAccountString([root objectForKey:@"error"]);
    if (!message) message = [NSString stringWithFormat:@"youtube answered HTTP %ld", (long)status];
    NSArray *details = RewindAccountArray([nested objectForKey:@"errors"]);
    NSDictionary *detail = details.count ? RewindAccountDict([details objectAtIndex:0]) : nil;
    NSString *reason = RewindAccountString([detail objectForKey:@"reason"]);
    if ([reason isEqualToString:@"accessNotConfigured"] || [reason isEqualToString:@"serviceDisabled"])
        message = [message stringByAppendingString:@" Open Settings, Account, YouTube OAuth setup. Enable YouTube Data API v3 in that project, save its TV client credentials, then sign in again"];
    NSString *credentials[] = { g_account.clientSecret, g_account.oauthClientSecret,
        g_account.refreshToken, g_account.accessToken, RewindOAuthClientSecret };
    for (NSUInteger index = 0; index < sizeof(credentials) / sizeof(credentials[0]); ++index)
        if (credentials[index].length)
            message = [message stringByReplacingOccurrencesOfString:credentials[index] withString:@"[redacted]"];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
    if (reason) [info setObject:reason forKey:@"YouTubeReason"];
    return [NSError errorWithDomain:RewindAccountErrorDomain code:status ? status : 500 userInfo:info];
}

static BOOL RewindAccountShouldUseFallback(NSError *error) {
    switch (error.code) {
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:
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

static void RewindAccountFinishRefresh(NSString *token, NSError *error) {
    NSArray *waiters = [g_account.refreshWaiters copy];
    [g_account.refreshWaiters removeAllObjects];
    for (RewindTokenCompletion waiter in waiters) waiter(token, error);
    [waiters release];
}

static void RewindAccountWithToken(BOOL force, RewindTokenCompletion completion) {
    if (!RewindAccountSignedInLoaded()) {
        completion(nil, RewindAccountError(401, RewindL(@"account_signed_out")));
        return;
    }
    if (!force && g_account.accessToken.length &&
        g_account.accessExpiresAt - [NSDate timeIntervalSinceReferenceDate] > 60.0) {
        completion(g_account.accessToken, nil);
        return;
    }
    [g_account.refreshWaiters addObject:[[completion copy] autorelease]];
    if (g_account.refreshWaiters.count > 1) return;

    NSUInteger generation = g_account.generation;
    NSDictionary *fields = [NSDictionary dictionaryWithObjectsAndKeys:
                            g_account.clientID, @"client_id",
                            g_account.clientSecret ?: @"", @"client_secret",
                            @"refresh_token", @"grant_type",
                            g_account.refreshToken, @"refresh_token", nil];
    RewindAccountSend(RewindAccountFormRequest(RewindOAuthTokenURL, fields),
                      ^(NSInteger status, id json, NSError *error) {
        if (generation != g_account.generation) return;
        NSDictionary *root = RewindAccountDict(json);
        NSString *token = RewindAccountString([root objectForKey:@"access_token"]);
        if (!error && status == 200 && token) {
            RewindAccountSetString(&g_account.accessToken, token);
            NSTimeInterval expiresIn = RewindAccountSeconds([root objectForKey:@"expires_in"], 3600.0);
            if (expiresIn <= 0) expiresIn = 3600.0;
            g_account.accessExpiresAt = [NSDate timeIntervalSinceReferenceDate] + expiresIn;
            RewindAccountFinishRefresh(token, nil);
            return;
        }
        /* the user revoked access in the google account; keeping the token would fail forever */
        if ([RewindAccountString([root objectForKey:@"error"]) isEqualToString:@"invalid_grant"]) {
            RewindAccountClear(RewindAccountError(401, RewindL(@"account_revoked")), YES);
            return;
        }
        RewindAccountFinishRefresh(nil, error ? error : RewindAccountResponseError(status, json));
    });
}

static NSDictionary *RewindTVBody(NSDictionary *body) {
    NSDictionary *client = [NSDictionary dictionaryWithObjectsAndKeys:
                            RewindTVClientName, @"clientName",
                            RewindTVClientVersion, @"clientVersion",
                            RewindLanguageCode(), @"hl", nil];
    NSMutableDictionary *full = [NSMutableDictionary dictionaryWithDictionary:body];
    [full setObject:[NSDictionary dictionaryWithObject:client forKey:@"client"] forKey:@"context"];
    return full;
}

static void RewindAccountAttempt(NSString *path, NSDictionary *body, BOOL retried, BOOL fallback,
                                 NSUInteger generation, RewindJSONCompletion completion) {
    RewindAccountWithToken(retried, ^(NSString *token, NSError *tokenError) {
        if (generation != g_account.generation || tokenError) {
            completion(nil, tokenError ?: RewindAccountError(401, RewindL(@"account_signed_out")));
            return;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:RewindTVBody(body) options:0 error:NULL];
        NSString *url = [NSString stringWithFormat:@"%@/%@?prettyPrint=false",
                         fallback ? RewindTVEndpointFallback : RewindTVEndpoint, path];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:20.0];
        [request setHTTPMethod:@"POST"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        [request setHTTPBody:data];
        RewindAccountSend(request, ^(NSInteger status, id json, NSError *error) {
            if (generation != g_account.generation) {
                completion(nil, RewindAccountError(401, RewindL(@"account_signed_out")));
                return;
            }
            if (error) {
                if (!fallback && RewindAccountShouldUseFallback(error)) {
                    RewindAccountAttempt(path, body, retried, YES, generation, completion);
                    return;
                }
                completion(nil, error);
                return;
            }
            if (status == 401 && !retried) {
                RewindAccountAttempt(path, body, YES, fallback, generation, completion);
                return;
            }
            NSDictionary *root = RewindAccountDict(json);
            if (status != 200 || !root || [root objectForKey:@"error"]) {
                completion(nil, status == 200 && !root
                    ? RewindAccountError(502, @"YouTube returned an invalid account response")
                    : RewindAccountResponseError(status, json));
                return;
            }
            completion(root, nil);
        });
    });
}

static void RewindAccountCall(NSString *path, NSDictionary *body, RewindJSONCompletion completion) {
    RewindAccountLoadState();
    RewindAccountAttempt(path, body, NO, NO, g_account.generation, completion);
}

/* the data api is the documented write path; a tv client's 403 remains a failure */
static BOOL RewindTVIsID(NSString *value, NSUInteger minLength, NSUInteger maxLength);

static void RewindAccountDataCall(NSString *path, NSDictionary *body, BOOL retried,
                                  NSUInteger generation, RewindJSONCompletion completion) {
    RewindAccountWithToken(retried, ^(NSString *token, NSError *tokenError) {
        if (generation != g_account.generation || tokenError) {
            completion(nil, tokenError ?: RewindAccountError(401, RewindL(@"account_signed_out")));
            return;
        }
        NSString *url = [@"https://www.googleapis.com/youtube/v3/" stringByAppendingString:path];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:20.0];
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        if (body) {
            NSError *encodingError = nil;
            NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:&encodingError];
            if (!data) { completion(nil, encodingError); return; }
            [request setHTTPMethod:@"POST"];
            [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            [request setHTTPBody:data];
        }
        RewindAccountSend(request, ^(NSInteger status, id json, NSError *error) {
            if (generation != g_account.generation) {
                completion(nil, RewindAccountError(401, RewindL(@"account_signed_out")));
                return;
            }
            if (!error && status == 401 && !retried) {
                RewindAccountDataCall(path, body, YES, generation, completion);
                return;
            }
            NSDictionary *root = RewindAccountDict(json);
            if (error || status < 200 || status >= 300 || !root || [root objectForKey:@"error"]) {
                completion(nil, error ?: (status >= 200 && status < 300 && !root
                    ? RewindAccountError(502, @"YouTube returned an invalid account response")
                    : RewindAccountResponseError(status, json)));
                return;
            }
            completion(root, nil);
        });
    });
}

void RewindAccountCreatePlaylist(NSString *name, RewindAccountListCompletion completion) {
    if (!completion) return;
    NSString *clean = [RewindAccountString(name) stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!clean.length || clean.length > 150) {
        completion(nil, RewindAccountError(400, @"Playlist name must contain 1 to 150 characters"));
        return;
    }
    RewindAccountLoadState();
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSDictionary dictionaryWithObject:clean forKey:@"title"], @"snippet",
        [NSDictionary dictionaryWithObject:@"private" forKey:@"privacyStatus"], @"status", nil];
    NSUInteger generation = g_account.generation;
    RewindAccountDataCall(@"playlists?part=snippet,status", body, NO, generation,
                         ^(NSDictionary *root, NSError *error) {
        NSString *playlistID = RewindAccountString([root objectForKey:@"id"]);
        NSDictionary *snippet = RewindAccountDict([root objectForKey:@"snippet"]);
        NSString *title = RewindAccountString([snippet objectForKey:@"title"]);
        if (error || ![playlistID hasPrefix:@"PL"] || !RewindTVIsID(playlistID, 3, 64) || !title) {
            completion(nil, error ?: RewindAccountError(502, @"YouTube returned no created playlist"));
            return;
        }
        RewindTrack *playlist = [[[RewindTrack alloc] initWithVideoID:nil title:title
            artist:RewindAccountName() ?: @"" album:@"" thumbnailURL:nil duration:0
            playlistID:playlistID artistID:nil resultType:@"Playlist"] autorelease];
        if (!playlist) {
            completion(nil, RewindAccountError(500, @"Playlist was created, but could not be loaded"));
            return;
        }
        NSMutableArray *playlists = [NSMutableArray arrayWithArray:g_account.playlists ?: [NSArray array]];
        [playlists addObject:playlist];
        [g_account.playlists release];
        g_account.playlists = [playlists copy];
        ++g_account.playlistsRequest;
        RewindAccountPost(RewindAccountLibraryDidChangeNotification);
        if (generation != g_account.generation) {
            completion(nil, RewindAccountError(401, @"Playlist was created, but the signed in account changed"));
            return;
        }
        completion([NSArray arrayWithObject:playlist], nil);
    });
}

/* responses carry one list container per page, so the first match is the list */
static id RewindTVFind(id node, NSString *key, NSUInteger depth) {
    if (depth > RewindAccountMaxDepth) return nil;
    if ([node isKindOfClass:[NSDictionary class]]) {
        id direct = [(NSDictionary *)node objectForKey:key];
        if (direct) return direct;
        for (id value in [(NSDictionary *)node allValues]) {
            id found = RewindTVFind(value, key, depth + 1);
            if (found) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            id found = RewindTVFind(value, key, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

static NSString *RewindTVText(id node) {
    NSDictionary *dict = RewindAccountDict(node);
    NSString *simple = RewindAccountString([dict objectForKey:@"simpleText"]);
    if (simple) return simple;
    NSMutableString *joined = [NSMutableString string];
    for (id run in RewindAccountArray([dict objectForKey:@"runs"])) {
        NSString *part = RewindAccountString([RewindAccountDict(run) objectForKey:@"text"]);
        if (part) [joined appendString:part];
    }
    NSString *clean = [joined stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return clean.length ? clean : nil;
}

static BOOL RewindTVIsID(NSString *value, NSUInteger minLength, NSUInteger maxLength) {
    if (![value isKindOfClass:[NSString class]] || value.length < minLength || value.length > maxLength) return NO;
    static NSCharacterSet *invalid;
    if (!invalid)
        invalid = [[[NSCharacterSet characterSetWithCharactersInString:
                     @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"] invertedSet] retain];
    return [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

void RewindAccountAddPlaylistTrack(NSString *playlistID, RewindTrack *track,
                                   RewindAccountDoneCompletion completion) {
    if (!completion) return;
    if (!RewindTVIsID(playlistID, 3, 64) || ![playlistID hasPrefix:@"PL"] ||
        !RewindTVIsID(track.videoID, 11, 11)) {
        completion(RewindAccountError(400, @"Invalid YouTube playlist or track"));
        return;
    }
    NSString *videoID = [[track.videoID copy] autorelease];
    NSDictionary *resource = [NSDictionary dictionaryWithObjectsAndKeys:
        @"youtube#video", @"kind", videoID, @"videoId", nil];
    NSDictionary *snippet = [NSDictionary dictionaryWithObjectsAndKeys:
        playlistID, @"playlistId", resource, @"resourceId", nil];
    RewindAccountLoadState();
    RewindAccountDataCall(@"playlistItems?part=snippet",
        [NSDictionary dictionaryWithObject:snippet forKey:@"snippet"], NO, g_account.generation,
        ^(NSDictionary *root, NSError *error) {
            NSDictionary *returned = RewindAccountDict([root objectForKey:@"snippet"]);
            NSDictionary *returnedResource = RewindAccountDict([returned objectForKey:@"resourceId"]);
            if (!error && (!RewindAccountString([root objectForKey:@"id"]) ||
                ![RewindAccountString([returned objectForKey:@"playlistId"]) isEqualToString:playlistID] ||
                ![RewindAccountString([returnedResource objectForKey:@"videoId"]) isEqualToString:videoID]))
                error = RewindAccountError(502, @"YouTube did not confirm the added track");
            if (!error) RewindAccountPost(RewindAccountLibraryDidChangeNotification);
            completion(error);
        });
}

/* a 226px tile reads sharp on retina without decoding the 544px original on old devices */
static NSString *RewindTVThumbnail(id node) {
    NSArray *thumbs = RewindAccountArray([RewindAccountDict(node) objectForKey:@"thumbnails"]);
    NSString *best = nil;
    for (id thumb in thumbs) {
        NSString *url = RewindAccountString([RewindAccountDict(thumb) objectForKey:@"url"]);
        if (!url) continue;
        best = url;
        if ([[RewindAccountDict(thumb) objectForKey:@"width"] integerValue] >= 200) break;
    }
    if ([best hasPrefix:@"//"]) best = [@"https:" stringByAppendingString:best];
    return [best hasPrefix:@"https://"] || [best hasPrefix:@"http://"] ? best : nil;
}

static NSArray *RewindTVLines(NSDictionary *metadata) {
    NSMutableArray *lines = [NSMutableArray array];
    for (id line in RewindAccountArray([metadata objectForKey:@"lines"])) {
        NSMutableArray *texts = [NSMutableArray array];
        NSDictionary *renderer = RewindAccountDict([RewindAccountDict(line) objectForKey:@"lineRenderer"]);
        for (id item in RewindAccountArray([renderer objectForKey:@"items"])) {
            NSDictionary *itemRenderer = RewindAccountDict([RewindAccountDict(item) objectForKey:@"lineItemRenderer"]);
            NSString *text = RewindTVText([itemRenderer objectForKey:@"text"]);
            if (text && ![text isEqualToString:@"•"]) [texts addObject:text];
        }
        [lines addObject:texts];
    }
    return lines;
}

/* the tv client labels songs by text, and the text follows the hl language */
static BOOL RewindTVLinesMarkSong(NSArray *lines) {
    NSArray *markers = [NSArray arrayWithObjects:@"Song", @"Композиция", @"Песня", nil];
    for (NSUInteger index = 1; index < lines.count; ++index) {
        for (NSString *text in [lines objectAtIndex:index]) {
            NSString *first = [[text componentsSeparatedByString:@" • "] objectAtIndex:0];
            for (NSString *marker in markers)
                if ([first caseInsensitiveCompare:marker] == NSOrderedSame) return YES;
        }
    }
    return NO;
}

/* youtube music words the row as "artist • plays"; the tv lines lead with the type instead */
static NSString *RewindTVDetail(NSString *artist, NSArray *lines) {
    NSMutableArray *parts = [NSMutableArray array];
    if (artist.length) [parts addObject:artist];
    NSArray *markers = [NSArray arrayWithObjects:@"Song", @"Video", @"Композиция", @"Песня", @"Видео", nil];
    for (NSUInteger index = 1; index < lines.count; ++index) {
        for (NSString *text in [lines objectAtIndex:index]) {
            for (NSString *piece in [text componentsSeparatedByString:@" • "]) {
                NSString *clean = [piece stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                BOOL marker = NO;
                for (NSString *m in markers)
                    if ([clean caseInsensitiveCompare:m] == NSOrderedSame) marker = YES;
                if (clean.length && !marker) [parts addObject:clean];
            }
        }
    }
    return [parts componentsJoinedByString:@" • "];
}

static NSUInteger RewindTVDuration(NSDictionary *header) {
    for (id overlay in RewindAccountArray([header objectForKey:@"thumbnailOverlays"])) {
        NSDictionary *time = RewindAccountDict([RewindAccountDict(overlay)
                                                objectForKey:@"thumbnailOverlayTimeStatusRenderer"]);
        NSUInteger seconds = RewindClockSeconds(RewindTVText([time objectForKey:@"text"]));
        if (seconds) return seconds;
    }
    return 0;
}

static RewindTrack *RewindTrackFromTile(NSDictionary *tile) {
    NSDictionary *metadata = RewindAccountDict([RewindAccountDict([tile objectForKey:@"metadata"])
                                                objectForKey:@"tileMetadataRenderer"]);
    NSDictionary *header = RewindAccountDict([RewindAccountDict([tile objectForKey:@"header"])
                                              objectForKey:@"tileHeaderRenderer"]);
    NSString *title = RewindTVText([metadata objectForKey:@"title"]);
    if (!metadata || !title) return nil;
    NSArray *lines = RewindTVLines(metadata);
    NSArray *firstLine = lines.count ? [lines objectAtIndex:0] : nil;
    NSString *subtitle = firstLine.count ? [firstLine objectAtIndex:0] : @"";
    NSString *thumbnail = RewindTVThumbnail([header objectForKey:@"thumbnail"]);
    NSString *type = RewindAccountString([tile objectForKey:@"contentType"]);
    NSString *contentID = RewindAccountString([tile objectForKey:@"contentId"]);
    NSDictionary *select = RewindAccountDict([tile objectForKey:@"onSelectCommand"]);
    NSDictionary *watch = RewindAccountDict([select objectForKey:@"watchEndpoint"]);
    NSDictionary *browse = RewindAccountDict([select objectForKey:@"browseEndpoint"]);

    if ([type isEqualToString:@"TILE_CONTENT_TYPE_VIDEO"]) {
        if (!RewindTVIsID(contentID, 11, 11)) return nil;
        NSString *videoType = RewindAccountString(RewindTVFind(tile, @"musicVideoType", 0));
        BOOL song = [videoType hasSuffix:@"_ATV"] || RewindTVLinesMarkSong(lines);
        RewindTrack *track = [[[RewindTrack alloc] initWithVideoID:contentID title:title artist:subtitle
                                                             album:@"" thumbnailURL:thumbnail
                                                          duration:RewindTVDuration(header)
                                                        playlistID:nil artistID:nil
                                                        resultType:song ? @"Song" : @"Video"] autorelease];
        return [track trackWithDetail:RewindTVDetail(subtitle, lines)];
    }
    if ([type isEqualToString:@"TILE_CONTENT_TYPE_PLAYLIST"]) {
        NSString *videoID = RewindAccountString([watch objectForKey:@"videoId"]);
        NSString *mixID = RewindAccountString([watch objectForKey:@"playlistId"]);
        if (RewindTVIsID(videoID, 11, 11) && RewindTVIsID(mixID, 2, 64))
            return [[[RewindTrack alloc] initWithVideoID:videoID title:title artist:subtitle
                                                   album:@"" thumbnailURL:thumbnail duration:0
                                              playlistID:mixID artistID:nil
                                              resultType:RewindResultTypeMix] autorelease];
        NSString *browseID = RewindAccountString([browse objectForKey:@"browseId"]);
        if (![browseID hasPrefix:@"VL"] || !RewindTVIsID([browseID substringFromIndex:2], 2, 64))
            return nil;
        NSString *pageType = RewindAccountString(RewindTVFind(browse, @"pageType", 0));
        return [[[RewindTrack alloc] initWithVideoID:nil title:title artist:subtitle album:@""
                                        thumbnailURL:thumbnail duration:0
                                          playlistID:[browseID substringFromIndex:2] artistID:nil
                                          resultType:[pageType hasSuffix:@"_ALBUM"]
                                                         ? RewindResultTypeAlbum : @"Playlist"] autorelease];
    }
    if ([type isEqualToString:@"TILE_CONTENT_TYPE_CHANNEL"]) {
        NSString *channelID = RewindAccountString([browse objectForKey:@"browseId"]);
        if (![channelID hasPrefix:@"UC"] || !RewindTVIsID(channelID, 3, 64)) return nil;
        return [[[RewindTrack alloc] initWithVideoID:nil title:title artist:title album:@""
                                        thumbnailURL:thumbnail duration:0 playlistID:nil
                                            artistID:channelID
                                          resultType:RewindResultTypeArtist] autorelease];
    }
    return nil;
}

static NSArray *RewindTracksFromItems(id items) {
    NSMutableArray *tracks = [NSMutableArray array];
    for (id item in RewindAccountArray(items)) {
        NSDictionary *tile = RewindAccountDict([RewindAccountDict(item) objectForKey:@"tileRenderer"]);
        RewindTrack *track = tile ? RewindTrackFromTile(tile) : nil;
        if (track) [tracks addObject:track];
    }
    return tracks;
}

static NSString *RewindTVContinuation(NSDictionary *list) {
    for (id entry in RewindAccountArray([list objectForKey:@"continuations"])) {
        NSDictionary *next = RewindAccountDict([RewindAccountDict(entry) objectForKey:@"nextContinuationData"]);
        NSString *token = RewindAccountString([next objectForKey:@"continuation"]);
        if (token) return token;
    }
    return nil;
}

static NSString *RewindShelfTitle(NSDictionary *shelf) {
    NSDictionary *header = RewindAccountDict([RewindAccountDict([shelf objectForKey:@"headerRenderer"])
                                              objectForKey:@"shelfHeaderRenderer"]);
    NSString *title = RewindTVText([header objectForKey:@"title"]);
    if (title) return title;
    NSDictionary *lockup = RewindAccountDict([RewindAccountDict([header objectForKey:@"avatarLockup"])
                                              objectForKey:@"avatarLockupRenderer"]);
    return RewindTVText([lockup objectForKey:@"title"]) ?: @"";
}

static void RewindAppendShelves(NSDictionary *sectionList, NSMutableArray *shelves) {
    for (id section in RewindAccountArray([sectionList objectForKey:@"contents"])) {
        NSDictionary *shelf = RewindAccountDict([RewindAccountDict(section) objectForKey:@"shelfRenderer"]);
        NSDictionary *list = RewindAccountDict([RewindAccountDict([shelf objectForKey:@"content"])
                                                objectForKey:@"horizontalListRenderer"]);
        NSArray *items = RewindTracksFromItems([list objectForKey:@"items"]);
        if (!items.count) continue;
        RewindShelf *row = [[RewindShelf alloc] initWithTitle:RewindShelfTitle(shelf) items:items];
        [shelves addObject:row];
        [row release];
    }
}

void RewindAccountLoadHome(RewindAccountListCompletion completion) {
    if (!completion) return;
    RewindAccountLoadState();
    NSUInteger generation = g_account.generation;
    RewindAccountCall(@"browse", [NSDictionary dictionaryWithObject:@"FEtopics_music" forKey:@"browseId"],
                      ^(NSDictionary *root, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSDictionary *sectionList = RewindAccountDict(RewindTVFind(root, @"sectionListRenderer", 0));
        NSMutableArray *shelves = [NSMutableArray array];
        RewindAppendShelves(sectionList, shelves);
        NSString *next = RewindTVContinuation(sectionList);
        if (!shelves.count && !next) {
            completion(nil, RewindAccountError(404, RewindL(@"account_home_empty")));
            return;
        }
        /* the first page is a usable home on its own; show it before the second arrives */
        if (shelves.count) completion([[shelves copy] autorelease], nil);
        if (!next || generation != g_account.generation) return;
        RewindAccountCall(@"browse", [NSDictionary dictionaryWithObject:next forKey:@"continuation"],
                          ^(NSDictionary *more, NSError *moreError) {
            if (moreError) {
                NSLog(@"rewind: second home page failed: %@", moreError);
                if (!shelves.count) completion(nil, moreError);
                return;
            }
            RewindAppendShelves(RewindAccountDict(RewindTVFind(more, @"sectionListContinuation", 0)), shelves);
            if (shelves.count) completion(shelves, nil);
            else completion(nil, RewindAccountError(404, RewindL(@"account_home_empty")));
        });
    });
}

static void RewindAccountPagePlaylist(NSString *continuation, NSMutableArray *tracks, NSUInteger page, NSUInteger maxPages,
                                      NSUInteger generation, RewindAccountListCompletion progress,
                                      RewindAccountListCompletion completion) {
    if (generation != g_account.generation) {
        completion(nil, RewindAccountError(401, RewindL(@"account_signed_out")));
        return;
    }
    if (!continuation || page >= maxPages) {
        completion(tracks, nil);
        return;
    }
    if (progress && tracks.count) progress([[tracks copy] autorelease], nil);
    RewindAccountCall(@"browse", [NSDictionary dictionaryWithObject:continuation forKey:@"continuation"],
                      ^(NSDictionary *root, NSError *error) {
        if (generation != g_account.generation) {
            completion(nil, RewindAccountError(401, RewindL(@"account_signed_out")));
            return;
        }
        if (error) {
            /* keep the pages that did load; the list is still correct up to here */
            NSLog(@"rewind: playlist page %lu failed: %@", (unsigned long)page, error);
            completion(tracks, tracks.count ? nil : error);
            return;
        }
        NSDictionary *list = RewindAccountDict(RewindTVFind(root, @"playlistVideoListContinuation", 0));
        [tracks addObjectsFromArray:RewindTracksFromItems([list objectForKey:@"contents"])];
        RewindAccountPagePlaylist(RewindTVContinuation(list), tracks, page + 1, maxPages, generation, progress, completion);
    });
}

static void RewindAccountLoadPlaylistPages(NSString *playlistID, NSUInteger maxPages, RewindAccountListCompletion progress,
                                           RewindAccountListCompletion completion) {
    if (!completion) return;
    if (!RewindTVIsID(playlistID, 2, 64)) {
        completion(nil, RewindAccountError(400, RewindL(@"err_generic")));
        return;
    }
    RewindAccountLoadState();
    NSUInteger generation = g_account.generation;
    progress = [[progress copy] autorelease];
    completion = [[completion copy] autorelease];
    RewindAccountCall(@"browse", [NSDictionary dictionaryWithObject:[@"VL" stringByAppendingString:playlistID]
                                                             forKey:@"browseId"],
                      ^(NSDictionary *root, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSDictionary *list = RewindAccountDict(RewindTVFind(root, @"playlistVideoListRenderer", 0));
        NSMutableArray *tracks = [NSMutableArray arrayWithArray:
                                  RewindTracksFromItems([list objectForKey:@"contents"])];
        RewindAccountPagePlaylist(RewindTVContinuation(list), tracks, 1, maxPages, generation, progress, completion);
    });
}

void RewindAccountLoadPlaylistTracks(NSString *playlistID, RewindAccountListCompletion completion) {
    RewindAccountLoadPlaylistPages(playlistID, RewindAccountMaxPages, nil, completion);
}

void RewindAccountLoadPlaylistTracksProgressive(NSString *playlistID, RewindAccountListCompletion progress,
                                                RewindAccountListCompletion completion) {
    RewindAccountLoadPlaylistPages(playlistID, RewindAccountMaxPages, progress, completion);
}

/* the tv playlist list holds every youtube playlist; the music app shows only playlists of songs. a playlist counts
   as music when one of its first three videos is catalog music, the verdict is kept per playlist */
static NSString *const RewindPlaylistKindsKey = @"RewindPlaylistMusicKinds";
static NSArray *g_rawPlaylists;
static BOOL g_classifyingPlaylists;

static BOOL RewindPlaylistNeedsKind(RewindTrack *playlist) {
    return [playlist.playlistID hasPrefix:@"PL"];
}

static NSArray *RewindMusicPlaylistsFrom(NSArray *raw) {
    NSDictionary *kinds = [[NSUserDefaults standardUserDefaults] dictionaryForKey:RewindPlaylistKindsKey];
    NSMutableArray *kept = [NSMutableArray array];
    for (RewindTrack *playlist in raw) {
        /* liked videos and watch later are video lists by definition */
        if ([playlist.playlistID isEqualToString:@"LL"] || [playlist.playlistID isEqualToString:@"WL"]) continue;
        if (RewindPlaylistNeedsKind(playlist) && ![[kinds objectForKey:playlist.playlistID] boolValue]) continue;
        [kept addObject:playlist];
    }
    return kept;
}

static void RewindStorePlaylistKind(NSString *playlistID, BOOL music) {
    NSMutableDictionary *kinds = [[[[NSUserDefaults standardUserDefaults] dictionaryForKey:RewindPlaylistKindsKey] mutableCopy] autorelease];
    if (!kinds) kinds = [NSMutableDictionary dictionary];
    [kinds setObject:[NSNumber numberWithBool:music] forKey:playlistID];
    [[NSUserDefaults standardUserDefaults] setObject:kinds forKey:RewindPlaylistKindsKey];
}

static void RewindClassifyNextPlaylist(void);

static void RewindCheckPlaylistTracks(RewindTrack *playlist, NSArray *tracks, NSUInteger index, RewindAPI *api) {
    if (index >= MIN((NSUInteger)3, tracks.count)) {
        RewindStorePlaylistKind(playlist.playlistID, NO);
        [g_account.playlists release];
        g_account.playlists = [RewindMusicPlaylistsFrom(g_rawPlaylists) retain];
        RewindAccountPost(RewindAccountLibraryDidChangeNotification);
        RewindClassifyNextPlaylist();
        return;
    }
    [api isCatalogMusicForTrack:[tracks objectAtIndex:index] completion:^(BOOL music, NSError *error) {
        if (error) {
            /* try again on the next load, a wrong verdict would hide the playlist for good */
            g_classifyingPlaylists = NO;
            return;
        }
        if (!music) {
            RewindCheckPlaylistTracks(playlist, tracks, index + 1, api);
            return;
        }
        RewindStorePlaylistKind(playlist.playlistID, YES);
        [g_account.playlists release];
        g_account.playlists = [RewindMusicPlaylistsFrom(g_rawPlaylists) retain];
        RewindAccountPost(RewindAccountLibraryDidChangeNotification);
        RewindClassifyNextPlaylist();
    }];
}

static void RewindClassifyNextPlaylist(void) {
    NSDictionary *kinds = [[NSUserDefaults standardUserDefaults] dictionaryForKey:RewindPlaylistKindsKey];
    for (RewindTrack *playlist in g_rawPlaylists) {
        if (!RewindPlaylistNeedsKind(playlist) || [kinds objectForKey:playlist.playlistID]) continue;
        g_classifyingPlaylists = YES;
        RewindAPI *api = [[[RewindAPI alloc] initWithAPIKey:RewindDefaultAPIKey] autorelease];
        /* the verdict reads three tracks, so only the first page is fetched: paging through every playlist on
           the first visit was dozens of heavy requests queued in front of what the user had asked for */
        RewindAccountLoadPlaylistPages(playlist.playlistID, 1, nil, ^(NSArray *tracks, NSError *error) {
            if (error) {
                g_classifyingPlaylists = NO;
                return;
            }
            if (!tracks.count) {
                /* an empty playlist has no verdict yet; it stays hidden until it holds something */
                RewindStorePlaylistKind(playlist.playlistID, NO);
                RewindClassifyNextPlaylist();
                return;
            }
            RewindCheckPlaylistTracks(playlist, tracks, 0, api);
        });
        return;
    }
    g_classifyingPlaylists = NO;
}

void RewindAccountLoadPlaylists(RewindAccountListCompletion completion) {
    RewindAccountLoadState();
    NSUInteger request = ++g_account.playlistsRequest;
    RewindAccountCall(@"browse", [NSDictionary dictionaryWithObject:@"FEplaylist_aggregation" forKey:@"browseId"],
                      ^(NSDictionary *root, NSError *error) {
        /* a list requested before creation must not erase the confirmed new playlist */
        if (!error && request != g_account.playlistsRequest) {
            if (completion) completion(RewindAccountCachedPlaylists(), nil);
            return;
        }
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        NSDictionary *grid = RewindAccountDict(RewindTVFind(root, @"gridRenderer", 0));
        NSMutableArray *playlists = [NSMutableArray array];
        RewindTrack *liked = [[RewindTrack alloc] initWithVideoID:nil title:RewindL(@"liked_music")
                                                           artist:RewindAccountName() ?: @"" album:@""
                                                     thumbnailURL:nil duration:0 playlistID:@"LM"
                                                         artistID:nil resultType:@"Playlist"];
        [playlists addObject:liked];
        [liked release];
        for (RewindTrack *playlist in RewindTracksFromItems([grid objectForKey:@"items"])) {
            /* saved shorts are video clips the audio player cannot use */
            if (!playlist.playlistID.length || [playlist.playlistID isEqualToString:@"YS"]) continue;
            [playlists addObject:playlist];
        }
        [g_rawPlaylists release];
        g_rawPlaylists = [playlists copy];
        NSArray *music = RewindMusicPlaylistsFrom(playlists);
        [g_account.playlists release];
        g_account.playlists = [music copy];
        RewindAccountPost(RewindAccountLibraryDidChangeNotification);
        if (completion) completion(music, nil);
        if (!g_classifyingPlaylists) RewindClassifyNextPlaylist();
    });
}

NSArray *RewindAccountCachedPlaylists(void) {
    RewindAccountLoadState();
    return g_account.playlists ?: [NSArray array];
}

BOOL RewindAccountPlaylistIsEditable(NSString *playlistID) {
    return [playlistID hasPrefix:@"PL"] || [playlistID isEqualToString:@"WL"];
}

void RewindAccountLoadMix(RewindTrack *seed, RewindAccountListCompletion completion) {
    if (!completion) return;
    if (!RewindTVIsID(seed.videoID, 11, 11)) {
        completion(nil, RewindAccountError(400, RewindL(@"err_generic")));
        return;
    }
    NSString *mixID = [seed.resultType isEqualToString:RewindResultTypeMix] && seed.playlistID.length
        ? seed.playlistID : [@"RDAMVM" stringByAppendingString:seed.videoID];
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          seed.videoID, @"videoId", mixID, @"playlistId", nil];
    RewindAccountCall(@"next", body, ^(NSDictionary *root, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        /* the first pivot shelf is the queue; later shelves are unrelated suggestions */
        NSDictionary *pivot = RewindAccountDict(RewindTVFind(root, @"pivot", 0));
        NSDictionary *sectionList = RewindAccountDict([pivot objectForKey:@"sectionListRenderer"]);
        NSMutableArray *shelves = [NSMutableArray array];
        RewindAppendShelves(sectionList, shelves);
        NSMutableArray *tracks = [NSMutableArray array];
        for (RewindTrack *track in shelves.count ? [[shelves objectAtIndex:0] items] : nil)
            if (track.videoID.length && !track.isPlaylist) [tracks addObject:track];
        completion(tracks, tracks.count ? nil : RewindAccountError(404, RewindL(@"account_mix_empty")));
    });
}

static void RewindAccountStoreLikedTracks(NSArray *tracks) {
    [g_account.likedTracks release];
    g_account.likedTracks = [tracks copy];
    [g_account.likedIDs removeAllObjects];
    for (RewindTrack *track in tracks) [g_account.likedIDs addObject:track.videoID];
}

void RewindAccountLoadLikes(BOOL force, RewindAccountListCompletion completion) {
    if (!RewindAccountSignedInLoaded()) {
        if (completion) completion(nil, RewindAccountError(401, RewindL(@"account_signed_out")));
        return;
    }
    /* liked music pages 15 tracks per request, too slow to repeat on every library visit */
    if (!force && g_account.likedTracks &&
        [NSDate timeIntervalSinceReferenceDate] - g_account.likedLoadedAt < 300.0) {
        if (completion) completion(g_account.likedTracks, nil);
        return;
    }
    NSUInteger generation = g_account.generation;
    RewindAccountLoadPlaylistTracks(@"LM", ^(NSArray *tracks, NSError *error) {
        if (!error && generation == g_account.generation) {
            RewindAccountStoreLikedTracks(tracks);
            g_account.likedLoadedAt = [NSDate timeIntervalSinceReferenceDate];
            RewindAccountPost(RewindAccountLibraryDidChangeNotification);
        }
        if (completion) completion(tracks, error);
    });
}

NSUInteger RewindAccountCachedLikedTrackCount(void) {
    RewindAccountLoadState();
    return g_account.likedTracks.count;
}

BOOL RewindAccountTrackIsLiked(RewindTrack *track) {
    RewindAccountLoadState();
    return track.videoID.length && [g_account.likedIDs containsObject:track.videoID];
}

void RewindAccountSetLiked(RewindTrack *track, BOOL liked, RewindAccountDoneCompletion completion) {
    if (!RewindTVIsID(track.videoID, 11, 11)) {
        if (completion) completion(RewindAccountError(400, RewindL(@"err_generic")));
        return;
    }
    NSString *videoID = [[track.videoID copy] autorelease];
    RewindTrack *likedTrack = [[track retain] autorelease];
    NSDictionary *body = [NSDictionary dictionaryWithObject:
                          [NSDictionary dictionaryWithObject:videoID forKey:@"videoId"]
                                                     forKey:@"target"];
    RewindAccountCall(liked ? @"like/like" : @"like/removelike", body, ^(NSDictionary *root, NSError *error) {
        (void)root;
        if (!error) {
            NSMutableArray *tracks = [NSMutableArray arrayWithArray:g_account.likedTracks ?: [NSArray array]];
            for (NSInteger index = (NSInteger)tracks.count - 1; index >= 0; --index)
                if ([[[tracks objectAtIndex:(NSUInteger)index] videoID] isEqualToString:videoID])
                    [tracks removeObjectAtIndex:(NSUInteger)index];
            /* youtube lists the newest like first */
            if (liked) [tracks insertObject:likedTrack atIndex:0];
            if (liked) [g_account.dislikedIDs removeObject:videoID];
            if (g_account.likedTracks) RewindAccountStoreLikedTracks(tracks);
            else if (liked) [g_account.likedIDs addObject:videoID];
            else [g_account.likedIDs removeObject:videoID];
            RewindAccountPost(RewindAccountLibraryDidChangeNotification);
        }
        if (completion) completion(error);
    });
}

BOOL RewindAccountTrackIsDisliked(RewindTrack *track) {
    RewindAccountLoadState();
    return track.videoID.length && [g_account.dislikedIDs containsObject:track.videoID];
}

void RewindAccountSetDisliked(RewindTrack *track, BOOL disliked, RewindAccountDoneCompletion completion) {
    if (!RewindTVIsID(track.videoID, 11, 11)) {
        if (completion) completion(RewindAccountError(400, RewindL(@"err_generic")));
        return;
    }
    NSString *videoID = [[track.videoID copy] autorelease];
    BOOL wasLiked = RewindAccountTrackIsLiked(track);
    NSDictionary *body = [NSDictionary dictionaryWithObject:
                          [NSDictionary dictionaryWithObject:videoID forKey:@"videoId"]
                                                     forKey:@"target"];
    RewindAccountCall(disliked ? @"like/dislike" : @"like/removelike", body, ^(NSDictionary *root, NSError *error) {
        (void)root;
        if (!error) {
            if (disliked) [g_account.dislikedIDs addObject:videoID];
            else [g_account.dislikedIDs removeObject:videoID];
            /* a dislike replaces a like on youtube's side */
            if (disliked && wasLiked) {
                [g_account.likedIDs removeObject:videoID];
                NSMutableArray *tracks = [NSMutableArray arrayWithArray:g_account.likedTracks ?: [NSArray array]];
                for (NSInteger index = (NSInteger)tracks.count - 1; index >= 0; --index)
                    if ([[[tracks objectAtIndex:(NSUInteger)index] videoID] isEqualToString:videoID])
                        [tracks removeObjectAtIndex:(NSUInteger)index];
                if (g_account.likedTracks) RewindAccountStoreLikedTracks(tracks);
            }
            RewindAccountPost(RewindAccountLibraryDidChangeNotification);
        }
        if (completion) completion(error);
    });
}

void RewindAccountSetSubscribed(NSString *artistID, BOOL subscribed, RewindAccountDoneCompletion completion) {
    if (!artistID.length) {
        if (completion) completion(RewindAccountError(400, RewindL(@"err_generic")));
        return;
    }
    NSDictionary *body = [NSDictionary dictionaryWithObject:
                          [NSArray arrayWithObject:artistID] forKey:@"channelIds"];
    RewindAccountCall(subscribed ? @"subscription/subscribe" : @"subscription/unsubscribe", body,
                      ^(NSDictionary *root, NSError *error) {
        (void)root;
        if (completion) completion(error);
    });
}

void RewindAccountEditPlaylist(NSString *playlistID, RewindTrack *track, BOOL add,
                               RewindAccountDoneCompletion completion) {
    if (!RewindAccountPlaylistIsEditable(playlistID) || !RewindTVIsID(track.videoID, 11, 11)) {
        if (completion) completion(RewindAccountError(400, RewindL(@"account_playlist_readonly")));
        return;
    }
    NSDictionary *action = add
        ? [NSDictionary dictionaryWithObjectsAndKeys:@"ACTION_ADD_VIDEO", @"action",
                                                     track.videoID, @"addedVideoId", nil]
        : [NSDictionary dictionaryWithObjectsAndKeys:@"ACTION_REMOVE_VIDEO_BY_VIDEO_ID", @"action",
                                                     track.videoID, @"removedVideoId", nil];
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          playlistID, @"playlistId",
                          [NSArray arrayWithObject:action], @"actions", nil];
    RewindAccountCall(@"browse/edit_playlist", body, ^(NSDictionary *root, NSError *error) {
        if (!error && ![RewindAccountString([root objectForKey:@"status"]) isEqualToString:@"STATUS_SUCCEEDED"])
            error = RewindAccountError(500, RewindL(@"account_edit_failed"));
        if (!error) RewindAccountPost(RewindAccountLibraryDidChangeNotification);
        if (completion) completion(error);
    });
}

static NSDictionary *RewindAccountSelectedItem(id node, NSUInteger depth) {
    if (depth > RewindAccountMaxDepth) return nil;
    NSDictionary *dict = RewindAccountDict(node);
    NSDictionary *item = RewindAccountDict([dict objectForKey:@"accountItem"]);
    id selected = [item objectForKey:@"isSelected"];
    if ([selected isKindOfClass:[NSNumber class]] && [selected boolValue]) return item;
    NSArray *children = dict ? [dict allValues] : RewindAccountArray(node);
    for (id child in children) {
        NSDictionary *found = RewindAccountSelectedItem(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void RewindAccountLoadTVProfile(RewindAccountDoneCompletion completion) {
    RewindAccountCall(@"account/accounts_list", [NSDictionary dictionary], ^(NSDictionary *root, NSError *error) {
        if (error) {
            NSLog(@"rewind: profile load failed: %@", error);
            completion(error);
            return;
        }
        NSDictionary *item = RewindAccountSelectedItem(root, 0);
        NSString *name = RewindTVText([item objectForKey:@"accountName"]);
        if (!name) {
            completion(RewindAccountError(502, @"YouTube did not identify the selected channel"));
            return;
        }
        RewindAccountSetString(&g_account.name, name);
        RewindAccountSetString(&g_account.email, RewindTVText([item objectForKey:@"accountByline"]));
        NSArray *thumbs = RewindAccountArray([RewindAccountDict([item objectForKey:@"accountPhoto"])
                                              objectForKey:@"thumbnails"]);
        NSString *photo = RewindAccountString([RewindAccountDict([thumbs lastObject]) objectForKey:@"url"]);
        if ([photo hasPrefix:@"//"]) photo = [@"https:" stringByAppendingString:photo];
        RewindAccountSetString(&g_account.photoURL, [photo hasPrefix:@"https://"] ? photo : nil);
        RewindAccountSaveState();
        RewindAccountPost(RewindAccountDidChangeNotification);
        completion(nil);
    });
}

/* mine identifies the authorized channel instead of an arbitrary accounts_list entry */
static void RewindAccountLoadProfile(RewindAccountDoneCompletion completion) {
    NSUInteger generation = g_account.generation;
    RewindAccountDataCall(@"channels?part=snippet&mine=true", nil, NO, g_account.generation,
                         ^(NSDictionary *root, NSError *error) {
        if (generation != g_account.generation) {
            completion(RewindAccountError(401, RewindL(@"account_signed_out")));
            return;
        }
        if (error) {
            NSString *reason = RewindAccountString([error.userInfo objectForKey:@"YouTubeReason"]);
            /* the bundled tv project can read its profile without enabling the data api */
            if ([reason isEqualToString:@"accessNotConfigured"] || [reason isEqualToString:@"serviceDisabled"]) {
                NSLog(@"rewind: data api profile unavailable: %@", error);
                RewindAccountLoadTVProfile(^(NSError *profileError) {
                    completion(profileError ?: ([g_account.clientID isEqualToString:RewindOAuthClientID] ? nil : error));
                });
            } else completion(error);
            return;
        }
        NSArray *items = RewindAccountArray([root objectForKey:@"items"]);
        NSDictionary *channel = items.count == 1 ? RewindAccountDict([items objectAtIndex:0]) : nil;
        NSDictionary *snippet = RewindAccountDict([channel objectForKey:@"snippet"]);
        NSString *name = RewindAccountString([snippet objectForKey:@"title"]);
        if (!name) {
            completion(RewindAccountError(403, @"YouTube did not return one authorized channel. Select the intended channel when signing in"));
            return;
        }
        NSDictionary *thumbs = RewindAccountDict([snippet objectForKey:@"thumbnails"]);
        NSString *photo = RewindAccountString([RewindAccountDict([thumbs objectForKey:@"medium"]) objectForKey:@"url"]);
        if (!photo) photo = RewindAccountString([RewindAccountDict([thumbs objectForKey:@"default"]) objectForKey:@"url"]);
        RewindAccountSetString(&g_account.name, name);
        RewindAccountSetString(&g_account.email, nil);
        RewindAccountSetString(&g_account.photoURL, [photo hasPrefix:@"https://"] ? photo : nil);
        RewindAccountSaveState();
        RewindAccountPost(RewindAccountDidChangeNotification);
        completion(nil);
    });
}

void RewindAccountRefreshProfile(RewindAccountDoneCompletion completion) {
    if (!completion) return;
    RewindAccountLoadState();
    RewindAccountLoadProfile(completion);
}

static NSString *RewindAccountVerificationURL(NSString *url) {
    NSURL *parsed = url ? [NSURL URLWithString:url] : nil;
    NSString *host = [[parsed host] lowercaseString];
    BOOL google = [host isEqualToString:@"google.com"] || [host hasSuffix:@".google.com"] ||
                  [host isEqualToString:@"youtube.com"] || [host hasSuffix:@".youtube.com"];
    /* the qr code sends people to this page, so it must be google's own */
    if ([[parsed scheme] isEqualToString:@"https"] && google) return url;
    return @"https://www.google.com/device";
}

void RewindAccountRequestDeviceCode(RewindDeviceCodeCompletion completion) {
    if (!completion) return;
    RewindAccountLoadState();
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id oldID = [defaults objectForKey:@"RewindOAuthClientID"];
    id oldSecret = [defaults objectForKey:@"RewindOAuthClientSecret"];
    if (oldID || oldSecret) {
        NSError *storeError = nil;
        if (!RewindAccountSetOAuthClient(oldID, oldSecret, &storeError)) {
            completion(nil, storeError);
            return;
        }
    }
    NSString *clientID = g_account.oauthClientID ?: RewindOAuthClientID;
    NSString *clientSecret = g_account.oauthClientID ? g_account.oauthClientSecret : RewindOAuthClientSecret;
    if (!RewindAccountOAuthCredential(clientID, YES) || !RewindAccountOAuthCredential(clientSecret, NO)) {
        completion(nil, RewindAccountError(400, @"Open Settings, Account, YouTube OAuth setup and configure both client ID and secret"));
        return;
    }
    NSDictionary *fields = [NSDictionary dictionaryWithObjectsAndKeys:
                            clientID, @"client_id",
                            RewindOAuthScope, @"scope", nil];
    RewindAccountSend(RewindAccountFormRequest(RewindOAuthCodeURL, fields),
                      ^(NSInteger status, id json, NSError *error) {
        NSDictionary *root = RewindAccountDict(json);
        NSString *userCode = RewindAccountString([root objectForKey:@"user_code"]);
        NSString *deviceCode = RewindAccountString([root objectForKey:@"device_code"]);
        if (error || status != 200 || !userCode || !deviceCode) {
            completion(nil, error ? error : RewindAccountResponseError(status, json));
            return;
        }
        NSTimeInterval interval = RewindAccountSeconds([root objectForKey:@"interval"], 5.0);
        NSTimeInterval expiresIn = RewindAccountSeconds([root objectForKey:@"expires_in"], 1800.0);
        RewindDeviceCode *code = [[[RewindDeviceCode alloc]
                                   initWithUserCode:userCode
                                    verificationURL:RewindAccountVerificationURL(
                                        RewindAccountString([root objectForKey:@"verification_url"]))
                                         deviceCode:deviceCode
                                           interval:interval >= 1.0 ? interval : 5.0
                                          expiresIn:expiresIn > 0 ? expiresIn : 1800.0
                                           clientID:clientID clientSecret:clientSecret] autorelease];
        completion(code, nil);
    });
}

void RewindAccountPollDeviceCode(RewindDeviceCode *code, RewindDevicePollCompletion completion) {
    if (!completion) return;
    if (code.cancelled || !code.deviceCode.length) {
        completion(RewindDevicePollFailed, RewindAccountError(400, RewindL(@"err_generic")));
        return;
    }
    if ([code.expiresAt timeIntervalSinceNow] <= 0) {
        completion(RewindDevicePollExpired, nil);
        return;
    }
    RewindAccountLoadState();
    NSUInteger generation = g_account.generation;
    NSDictionary *fields = [NSDictionary dictionaryWithObjectsAndKeys:
                            code.clientID, @"client_id",
                            code.clientSecret ?: @"", @"client_secret",
                            code.deviceCode, @"device_code",
                            @"urn:ietf:params:oauth:grant-type:device_code", @"grant_type", nil];
    RewindAccountSend(RewindAccountFormRequest(RewindOAuthTokenURL, fields),
                      ^(NSInteger status, id json, NSError *error) {
        if (code.cancelled || generation != g_account.generation) {
            completion(RewindDevicePollFailed, RewindAccountError(401, @"Sign in was cancelled"));
            return;
        }
        if (error) {
            completion(RewindDevicePollFailed, error);
            return;
        }
        NSDictionary *root = RewindAccountDict(json);
        NSString *refresh = RewindAccountString([root objectForKey:@"refresh_token"]);
        NSString *access = RewindAccountString([root objectForKey:@"access_token"]);
        if (status == 200 && refresh && access) {
            rewind_account_state_t candidate = g_account;
            candidate.refreshToken = refresh;
            candidate.clientID = code.clientID;
            candidate.clientSecret = code.clientSecret;
            candidate.name = nil;
            candidate.email = nil;
            candidate.photoURL = nil;
            /* a failed store must leave the previous signed in account intact */
            if (!RewindAccountWriteState(&candidate)) {
                completion(RewindDevicePollFailed, RewindAccountError(500, RewindL(@"account_store_failed")));
                return;
            }
            RewindAccountClear(RewindAccountError(401, RewindL(@"account_signed_out")), NO);
            RewindAccountSetString(&g_account.clientID, code.clientID);
            RewindAccountSetString(&g_account.clientSecret, code.clientSecret);
            RewindAccountSetString(&g_account.refreshToken, refresh);
            RewindAccountSetString(&g_account.accessToken, access);
            NSTimeInterval expiresIn = RewindAccountSeconds([root objectForKey:@"expires_in"], 3600.0);
            g_account.accessExpiresAt = [NSDate timeIntervalSinceReferenceDate] +
                (expiresIn > 0 ? expiresIn : 3600.0);
            NSUInteger signedInGeneration = g_account.generation;
            RewindAccountPost(RewindAccountDidChangeNotification);
            if (signedInGeneration != g_account.generation) {
                completion(RewindDevicePollFailed, RewindAccountError(401, @"Sign in was cancelled"));
                return;
            }
            RewindAccountLoadProfile(^(NSError *profileError) {
                if (signedInGeneration != g_account.generation) {
                    completion(RewindDevicePollFailed, profileError ?: RewindAccountError(401, RewindL(@"account_signed_out")));
                    return;
                }
                RewindAccountLoadLikes(YES, nil);
                RewindAccountLoadPlaylists(nil);
                completion(RewindDevicePollGranted, profileError);
            });
            return;
        }
        NSString *reason = RewindAccountString([root objectForKey:@"error"]);
        if ([reason isEqualToString:@"authorization_pending"]) completion(RewindDevicePollPending, nil);
        else if ([reason isEqualToString:@"slow_down"]) completion(RewindDevicePollSlowDown, nil);
        else if ([reason isEqualToString:@"access_denied"]) completion(RewindDevicePollDenied, nil);
        else if ([reason isEqualToString:@"expired_token"]) completion(RewindDevicePollExpired, nil);
        else completion(RewindDevicePollFailed, RewindAccountResponseError(status, json));
    });
}

void RewindAccountSignOut(void) {
    RewindAccountLoadState();
    NSString *token = [[g_account.refreshToken copy] autorelease];
    RewindAccountClear(RewindAccountError(401, RewindL(@"account_signed_out")), YES);
    if (!token.length) return;
    /* revoking also drops the tv entry from the google account's connected apps */
    RewindAccountSend(RewindAccountFormRequest(RewindOAuthRevokeURL,
                                               [NSDictionary dictionaryWithObject:token forKey:@"token"]),
                      ^(NSInteger status, id json, NSError *error) {
        (void)json;
        if (error || status != 200)
            NSLog(@"rewind: token revoke failed (%ld): %@", (long)status, error);
    });
}
