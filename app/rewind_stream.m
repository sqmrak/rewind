#import "rewind_stream.h"
#import "rewind_api.h"
#import "rewind_http.h"

#include "rewind_fmp4.h"
#include "rewind_audio.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static NSError *RewindStreamError(NSInteger code, NSString *text) {
    return [NSError errorWithDomain:@"RewindStream" code:code
                           userInfo:[NSDictionary dictionaryWithObject:text forKey:NSLocalizedDescriptionKey]];
}

@interface RewindStreamSession : NSObject {
@public
    NSURL *_source;
    NSString *_userAgent;
    rewind_fmp4_t *_file;
}
@end

@implementation RewindStreamSession
- (void)dealloc {
    [_source release];
    [_userAgent release];
    rewind_fmp4_free(_file);
    [super dealloc];
}
@end

/* a track holds a preview and a complete session; the previous track, the next one and the current one all stay
   servable so going back in the queue or a replay does not rebuild them */
static const NSUInteger RewindStreamKeep = 8;
static NSMutableDictionary *RewindStreamSessions;
static NSMutableArray *RewindStreamOrder;
static int RewindStreamPort;

/* a header probe during index build is a few kb and should answer in well under this;
   a stalled connection here is cheaper to retry than to wait out, since one straggling
   fragment otherwise holds up every other fragment's already-finished result */
static const NSTimeInterval RewindStreamIndexTimeout = 5.0;
/* the serve loop hands real audio bytes to the player and needs room for slow links */
static const NSTimeInterval RewindStreamServeTimeout = 10.0;

static NSData *RewindStreamFetch(NSURL *url, NSString *userAgent, unsigned long long start,
                                 unsigned long long end, NSTimeInterval timeout, NSError **error, BOOL (^cancelled)(void)) {
    if (error) *error = nil;
    if (end < start || end - start >= 1024 * 1024) {
        if (error) *error = RewindStreamError(1, @"audio range exceeds its size limit");
        return nil;
    }
    NSUInteger attempt;
    for (attempt = 0; attempt < 2; ++attempt) {
        if (cancelled && cancelled()) {
            if (error) *error = RewindStreamError(1, @"audio range cancelled or timed out");
            return nil;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:timeout];
        NSHTTPURLResponse *response = nil;
        NSError *failure = nil;
        NSData *data;
        [request setValue:[NSString stringWithFormat:@"bytes=%llu-%llu", start, end] forHTTPHeaderField:@"Range"];
        [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
        if (userAgent) [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
        data = RewindHTTPFetchCancellable(request, (NSUInteger)(end - start + 1), &response, &failure, cancelled);
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [response statusCode] : 0;
        if (data && status == 206 && rewind_audio_content_range(
            [RewindHTTPHeader(response, @"Content-Range") UTF8String], start, end, data.length, NULL)) {
            if (error) *error = nil;
            return data;
        }
        if (error) *error = status == 403
            ? RewindStreamError(7, @"audio range answered 403")
            : (failure ?: RewindStreamError(1, [NSString stringWithFormat:@"audio range answered %ld",
                                                                      (long)status]));
        if ((status && status != 408 && status != 429 && status < 500) ||
            (failure && failure.code != NSURLErrorTimedOut && failure.code != NSURLErrorNetworkConnectionLost) ||
            (cancelled && cancelled())) break;
    }
    return nil;
}

/* fetches a fragment's capped first chunk, then, if the moof's own declared size says
   that was not enough, fetches the rest in the same call; this is what used to happen
   one fragment at a time in a serial pass after every fragment's chunk already came
   back, turning a handful of moofs larger than the cap into that many serial round
   trips tacked onto the end instead of running alongside everything else */
static NSData *RewindStreamFetchFragmentHead(NSURL *source, NSString *userAgent,
                                             unsigned long long offset, unsigned long long fullSize,
                                             NSError **error, BOOL (^cancelled)(void)) {
    unsigned long long capped = MIN(fullSize, 16384ULL);
    NSData *data = RewindStreamFetch(source, userAgent, offset, offset + capped - 1,
                                     RewindStreamIndexTimeout, error, cancelled);
    if (!data) return nil;
    size_t needed = rewind_fmp4_probe_box_size(data.bytes, data.length);
    if (needed > data.length && needed <= fullSize) {
        data = RewindStreamFetch(source, userAgent, offset, offset + needed - 1,
                                 RewindStreamIndexTimeout, error, cancelled);
    }
    return data;
}

static int RewindStreamSendAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len) {
        ssize_t sent = send(fd, p, len, 0);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return 0;
        p += sent;
        len -= (size_t)sent;
    }
    return 1;
}

static void RewindStreamReply(int fd, NSString *status) {
    NSString *text = [NSString stringWithFormat:@"HTTP/1.1 %@\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status];
    const char *bytes = [text UTF8String];
    RewindStreamSendAll(fd, bytes, strlen(bytes));
}

static void RewindStreamServe(int fd) {
    char request[8192];
    size_t used = 0;
    while (used < sizeof(request) - 1) {
        ssize_t got = recv(fd, request + used, sizeof(request) - 1 - used, 0);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return;
        used += (size_t)got;
        request[used] = 0;
        if (strstr(request, "\r\n\r\n")) break;
    }
    request[used] = 0;

    char method[16] = "", path[512] = "";
    if (sscanf(request, "%15s %511s", method, path) != 2) {
        RewindStreamReply(fd, @"400 Bad Request");
        return;
    }
    BOOL head = strcmp(method, "HEAD") == 0;
    if (!head && strcmp(method, "GET") != 0) {
        RewindStreamReply(fd, @"405 Method Not Allowed");
        return;
    }
    NSString *token = [[[NSString stringWithUTF8String:path] lastPathComponent] stringByDeletingPathExtension];
    RewindStreamSession *session = nil;
    @synchronized (RewindStreamSessions) {
        session = [[[RewindStreamSessions objectForKey:token] retain] autorelease];
    }
    if (!session) {
        RewindStreamReply(fd, @"404 Not Found");
        return;
    }

    rewind_fmp4_t *file = session->_file;
    unsigned long long total = rewind_fmp4_output_size(file);
    unsigned long long start = 0, end = total - 1;
    BOOL ranged = NO;
    const char *range = strcasestr(request, "\r\nRange:");
    if (range) {
        unsigned long long a = 0, b = 0;
        const char *spec = strstr(range, "bytes=");
        if (spec) {
            spec += 6;
            if (*spec == '-') {
                /* suffix range: the last n bytes */
                if (sscanf(spec, "-%llu", &b) == 1 && b) {
                    start = b >= total ? 0 : total - b;
                    ranged = YES;
                }
            } else {
                int fields = sscanf(spec, "%llu-%llu", &a, &b);
                if (fields >= 1) {
                    start = a;
                    if (fields == 2 && b < end) end = b;
                    ranged = YES;
                }
            }
        }
    }
    if (start >= total || start > end) {
        NSString *text = [NSString stringWithFormat:
                          @"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */%llu\r\n"
                          @"Content-Length: 0\r\nConnection: close\r\n\r\n", total];
        RewindStreamSendAll(fd, [text UTF8String], strlen([text UTF8String]));
        return;
    }

    NSMutableString *headers = [NSMutableString stringWithFormat:@"HTTP/1.1 %@\r\n",
                                ranged ? @"206 Partial Content" : @"200 OK"];
    [headers appendString:@"Content-Type: audio/mp4\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"];
    [headers appendFormat:@"Content-Length: %llu\r\n", end - start + 1];
    if (ranged) [headers appendFormat:@"Content-Range: bytes %llu-%llu/%llu\r\n", start, end, total];
    [headers appendString:@"\r\n"];
    if (!RewindStreamSendAll(fd, [headers UTF8String], strlen([headers UTF8String])) || head) return;

    size_t header_len = 0;
    const uint8_t *header = rewind_fmp4_header(file, &header_len);
    unsigned long long position = start;
    size_t chunk_index = 0, chunk_count = rewind_fmp4_chunk_count(file);
    /* small first piece so playback starts quickly, larger ones after */
    unsigned long long piece = 64 * 1024;
    while (position <= end) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        BOOL ok = YES;
        if (position < header_len) {
            unsigned long long stop = MIN(end + 1, (unsigned long long)header_len);
            ok = RewindStreamSendAll(fd, header + position, (size_t)(stop - position));
            position = stop;
        } else {
            const rewind_fmp4_chunk_t *chunk = NULL;
            while (chunk_index < chunk_count) {
                chunk = rewind_fmp4_chunk(file, chunk_index);
                if (position < chunk->output_offset + chunk->length) break;
                ++chunk_index;
                chunk = NULL;
            }
            if (!chunk) {
                ok = NO;
            } else {
                unsigned long long inside = position - chunk->output_offset;
                unsigned long long take = MIN(piece, MIN(chunk->length - inside, end + 1 - position));
                NSError *error = nil;
                NSData *data = RewindStreamFetch(session->_source, session->_userAgent,
                                                 chunk->source_offset + inside,
                                                 chunk->source_offset + inside + take - 1,
                                                 RewindStreamServeTimeout, &error, nil);
                if (!data) {
                    RewindDebugLog(@"stream: upstream failed at %llu: %@", position, error);
                    ok = NO;
                } else {
                    ok = RewindStreamSendAll(fd, data.bytes, data.length);
                    position += take;
                    piece = 512 * 1024;
                }
            }
        }
        [pool drain];
        if (!ok) break;
    }
}

static void *RewindStreamConnection(void *arg) {
    int fd = (int)(intptr_t)arg;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    RewindStreamServe(fd);
    [pool drain];
    close(fd);
    return NULL;
}

static void *RewindStreamAcceptLoop(void *arg) {
    int listener = (int)(intptr_t)arg;
    for (;;) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            usleep(100000);
            continue;
        }
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        struct timeval timeout = { 30, 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        pthread_t thread;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&thread, &attr, RewindStreamConnection, (void *)(intptr_t)fd) != 0) close(fd);
        pthread_attr_destroy(&attr);
    }
    return NULL;
}

static int RewindStreamStartServer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        RewindStreamSessions = [[NSMutableDictionary alloc] init];
        RewindStreamOrder = [[NSMutableArray alloc] init];
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        if (listener < 0) return;
        int on = 1;
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_len = sizeof(addr);
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        socklen_t addr_len = sizeof(addr);
        if (bind(listener, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(listener, 16) != 0 ||
            getsockname(listener, (struct sockaddr *)&addr, &addr_len) != 0) {
            close(listener);
            return;
        }
        pthread_t thread;
        if (pthread_create(&thread, NULL, RewindStreamAcceptLoop, (void *)(intptr_t)listener) != 0) {
            close(listener);
            return;
        }
        pthread_detach(thread);
        RewindStreamPort = ntohs(addr.sin_port);
    });
    return RewindStreamPort;
}

/* feeds fragment i to the file; a moof longer than the prefetched head is fetched whole and kept in heads, since a
   second file built from the same fragments needs the same bytes */
static rewind_fmp4_status_t RewindStreamAddFragment(rewind_fmp4_t *file, NSMutableArray *heads, size_t i,
                                                    NSURL *source, NSString *userAgent, NSError **error,
                                                    BOOL (^cancelled)(void)) {
    NSData *data = [heads objectAtIndex:i];
    unsigned long long offset = rewind_fmp4_fragment_offset(file, i);
    size_t needed = 0;
    rewind_fmp4_status_t status = REWIND_FMP4_INVALID;
    NSUInteger attempt;
    for (attempt = 0; attempt < 3; ++attempt) {
        if (![data isKindOfClass:[NSData class]]) {
            if (error) *error = RewindStreamError(3, @"audio fragment prefetch is incomplete");
            return REWIND_FMP4_INVALID;
        }
        status = rewind_fmp4_add_fragment(file, i, data.bytes, data.length, &needed);
        if (status != REWIND_FMP4_NEED_MORE || needed <= data.length ||
            needed > rewind_fmp4_fragment_size(file, i))
            break;
        data = RewindStreamFetch(source, userAgent, offset, offset + needed - 1,
                                 RewindStreamIndexTimeout, error, cancelled);
        if (!data) break;
        [heads replaceObjectAtIndex:i withObject:data];
    }
    if (status != REWIND_FMP4_OK && error && (status != REWIND_FMP4_NEED_MORE || !*error))
        *error = RewindStreamError(3, [NSString stringWithFormat:@"audio fragment %lu is unreadable",
                                                                  (unsigned long)i]);
    return status;
}

/* a playable file of the first count fragments, which are all in heads already */
static rewind_fmp4_t *RewindStreamBuildPreview(NSData *head, NSMutableArray *heads, size_t count, NSURL *source,
                                               NSString *userAgent, BOOL (^cancelled)(void)) {
    rewind_fmp4_t *early = NULL;
    size_t needed = 0, i;
    NSError *error = nil;
    if (rewind_fmp4_open(head.bytes, head.length, &needed, &early) != REWIND_FMP4_OK) return NULL;
    for (i = 0; i < count; ++i) {
        if (RewindStreamAddFragment(early, heads, i, source, userAgent, &error, cancelled) != REWIND_FMP4_OK) {
            RewindDebugLog(@"stream: preview fragment %lu failed: %@", (unsigned long)i, error);
            rewind_fmp4_free(early);
            return NULL;
        }
    }
    if (!rewind_fmp4_truncate(early, count) || rewind_fmp4_finish(early) != REWIND_FMP4_OK) {
        rewind_fmp4_free(early);
        return NULL;
    }
    return early;
}

/* reads the moov and sidx, then every fragment's moof, and builds the plain file's layout. with previewCount set
   the first fragments are read before the rest and handed to preview as a short file of their own; preview owns it */
static rewind_fmp4_t *RewindStreamBuild(NSURL *source, unsigned long long indexEnd, NSString *userAgent,
                                        NSError **error, BOOL (^cancelled)(void),
                                        size_t previewCount, void (^preview)(rewind_fmp4_t *early)) {
    unsigned long long headEnd = indexEnd;
    rewind_fmp4_t *file = NULL;
    NSData *head = nil;
    NSUInteger attempt;
    for (attempt = 0; attempt < 4; ++attempt) {
        if (headEnd >= 1024 * 1024) {
            if (error) *error = RewindStreamError(2, @"audio index exceeds its size limit");
            return NULL;
        }
        head = RewindStreamFetch(source, userAgent, 0, headEnd, RewindStreamIndexTimeout, error, cancelled);
        size_t needed = 0;
        if (!head) return NULL;
        rewind_fmp4_status_t status = rewind_fmp4_open(head.bytes, head.length, &needed, &file);
        if (status == REWIND_FMP4_OK) break;
        if (status != REWIND_FMP4_NEED_MORE || needed <= head.length) {
            if (error) *error = RewindStreamError(2, @"audio file layout is not supported");
            return NULL;
        }
        headEnd = needed - 1;
    }
    if (!file) {
        if (error) *error = RewindStreamError(2, @"audio file index could not be read");
        return NULL;
    }

    size_t count = rewind_fmp4_fragment_count(file);
    if (!count || count > 2048) {
        if (error) *error = RewindStreamError(2, @"audio index has too many fragments");
        rewind_fmp4_free(file);
        return NULL;
    }
    NSMutableArray *heads = [NSMutableArray arrayWithCapacity:count];
    size_t i;
    for (i = 0; i < count; ++i) [heads addObject:[NSNull null]];
    /* without a po token youtube answers 403 past roughly the first minute of some tracks;
       reading the last fragment first finds that before anything else is fetched */
    {
        unsigned long long offset = rewind_fmp4_fragment_offset(file, count - 1);
        unsigned long long full = rewind_fmp4_fragment_size(file, count - 1);
        NSData *last = RewindStreamFetchFragmentHead(source, userAgent, offset, full, error, cancelled);
        if (!last) {
            rewind_fmp4_free(file);
            return NULL;
        }
        [heads replaceObjectAtIndex:count - 1 withObject:last];
    }
    NSOperationQueue *queue = [[[NSOperationQueue alloc] init] autorelease];
    __block NSError *firstFailure = nil;
    BOOL (^stopped)(void) = ^BOOL {
        @synchronized (heads) {
            return firstFailure != nil || (cancelled && cancelled());
        }
    };
    /* four connections bound cfnetwork memory while old devices build the sample tables */
    [queue setMaxConcurrentOperationCount:4];
    void (^fetchHeads)(size_t, size_t) = ^(size_t from, size_t to) {
        size_t index;
        for (index = from; index < to; ++index) {
            unsigned long long offset = rewind_fmp4_fragment_offset(file, index);
            unsigned long long full = rewind_fmp4_fragment_size(file, index);
            [queue addOperationWithBlock:^{
                NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
                NSError *failure = nil;
                NSData *data = RewindStreamFetchFragmentHead(source, userAgent, offset, full, &failure, stopped);
                if (data || failure) {
                    @synchronized (heads) {
                        if (data) [heads replaceObjectAtIndex:index withObject:data];
                        else if (!firstFailure) firstFailure = [failure retain];
                    }
                }
                [pool drain];
            }];
        }
        [queue waitUntilAllOperationsAreFinished];
    };
    /* the preview needs fragments before the last, and the last must not be the only one left over */
    size_t early = preview && previewCount && count > previewCount + 1 ? previewCount : 0;
    if (early) {
        fetchHeads(0, early);
        if (!firstFailure) {
            rewind_fmp4_t *previewFile = RewindStreamBuildPreview(head, heads, early, source, userAgent, cancelled);
            if (previewFile) preview(previewFile);
        }
    }
    fetchHeads(early, count - 1);
    if (firstFailure) {
        if (error) *error = [[firstFailure retain] autorelease];
        [firstFailure release];
        rewind_fmp4_free(file);
        return NULL;
    }

    /* the index-building parser must run in fragment order, so this pass stays serial;
       the network fetches above already ran in parallel, so this is cheap in-memory
       parsing except on the rare fragment the prefetch above still undershot */
    for (i = 0; i < count; ++i) {
        rewind_fmp4_status_t status = RewindStreamAddFragment(file, heads, i, source, userAgent, error, cancelled);
        if (status != REWIND_FMP4_OK) {
            rewind_fmp4_free(file);
            return NULL;
        }
    }
    if (rewind_fmp4_finish(file) != REWIND_FMP4_OK) {
        if (error) *error = RewindStreamError(4, @"audio file could not be rebuilt");
        rewind_fmp4_free(file);
        return NULL;
    }
    return file;
}

/* hands the file to the proxy under a fresh token; the session owns it from here */
static NSURL *RewindStreamRegister(rewind_fmp4_t *file, NSURL *source, NSString *userAgent, int port) {
    RewindStreamSession *session = [[[RewindStreamSession alloc] init] autorelease];
    session->_source = [source retain];
    session->_userAgent = [userAgent copy];
    session->_file = file;
    NSString *token = [NSString stringWithFormat:@"%08x%08x", arc4random(), arc4random()];
    @synchronized (RewindStreamSessions) {
        [RewindStreamSessions setObject:session forKey:token];
        [RewindStreamOrder addObject:token];
        while (RewindStreamOrder.count > RewindStreamKeep) {
            [RewindStreamSessions removeObjectForKey:[RewindStreamOrder objectAtIndex:0]];
            [RewindStreamOrder removeObjectAtIndex:0];
        }
    }
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/%@.m4a", port, token]];
}

BOOL RewindStreamHasSession(NSURL *localURL) {
    if (!RewindStreamPort || !localURL || ![[localURL host] isEqualToString:@"127.0.0.1"] ||
        [[localURL port] intValue] != RewindStreamPort)
        return NO;
    NSString *token = [[localURL lastPathComponent] stringByDeletingPathExtension];
    @synchronized (RewindStreamSessions) {
        return [RewindStreamSessions objectForKey:token] != nil;
    }
}

void RewindStreamPrepare(NSURL *source, unsigned long long indexEnd, NSString *userAgent,
                         void (^completion)(NSURL *localURL, NSError *error)) {
    RewindStreamPrepareCancellable(source, indexEnd, userAgent, nil, completion);
}

void RewindStreamPrepareCancellable(NSURL *source, unsigned long long indexEnd, NSString *userAgent,
                                    BOOL (^cancelled)(void),
                                    void (^completion)(NSURL *localURL, NSError *error)) {
    RewindStreamPrepareProgressive(source, indexEnd, userAgent, 0, cancelled, nil, completion);
}

void RewindStreamPrepareProgressive(NSURL *source, unsigned long long indexEnd, NSString *userAgent,
                                    size_t previewFragments, BOOL (^cancelled)(void),
                                    void (^previewReady)(NSURL *previewURL),
                                    void (^completion)(NSURL *localURL, NSError *error)) {
    void (^done)(NSURL *, NSError *) = [[completion copy] autorelease];
    void (^early)(NSURL *) = [[previewReady copy] autorelease];
    if (!source || !indexEnd) {
        done(nil, RewindStreamError(5, @"audio format has no index"));
        return;
    }
    [source retain];
    [userAgent retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSError *error = nil;
        NSURL *local = nil;
        NSDate *started = [NSDate date];
        BOOL (^expired)(void) = ^BOOL { return (cancelled && cancelled()) || -[started timeIntervalSinceNow] > 30.0; };
        int port = RewindStreamStartServer();
        void (^deliver)(rewind_fmp4_t *) = ^(rewind_fmp4_t *previewFile) {
            NSURL *previewURL = RewindStreamRegister(previewFile, source, userAgent, port);
            RewindDebugLog(@"stream: preview %@ at %.2fs, %.1fs of audio", previewURL,
                           -[started timeIntervalSinceNow], rewind_fmp4_duration(previewFile));
            [previewURL retain];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!cancelled || !cancelled()) early(previewURL);
                [previewURL release];
            });
        };
        rewind_fmp4_t *file = port ? RewindStreamBuild(source, indexEnd, userAgent, &error, expired,
                                                       early ? previewFragments : 0, early ? deliver : nil) : NULL;
        if (expired()) {
            rewind_fmp4_free(file);
            file = NULL;
            error = RewindStreamError(1, @"audio index preparation cancelled or timed out");
        }
        if (!port) error = RewindStreamError(6, @"local audio server could not start");
        if (file) local = RewindStreamRegister(file, source, userAgent, port);
        RewindDebugLog(@"stream: built %@ in %.2fs, %.1fs of audio, error %@", local,
                       -[started timeIntervalSinceNow], file ? rewind_fmp4_duration(file) : 0.0, error);
        [local retain];
        [error retain];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!cancelled || !cancelled()) done(local, error);
            [local release];
            [error release];
        });
        [source release];
        [userAgent release];
        [pool drain];
    });
}
