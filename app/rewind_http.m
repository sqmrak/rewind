#import "rewind_http.h"
#include <math.h>

static NSError *RewindHTTPError(NSInteger code, NSString *text) {
    return [NSError errorWithDomain:NSURLErrorDomain code:code
                           userInfo:[NSDictionary dictionaryWithObject:text forKey:NSLocalizedDescriptionKey]];
}

NSString *RewindHTTPHeader(NSHTTPURLResponse *response, NSString *name) {
    for (id key in response.allHeaderFields) {
        if ([key isKindOfClass:[NSString class]] && [key caseInsensitiveCompare:name] == NSOrderedSame) {
            id value = [response.allHeaderFields objectForKey:key];
            return [value isKindOfClass:[NSString class]] ? value : nil;
        }
    }
    return nil;
}

@interface RewindHTTPTransfer : NSObject <NSURLConnectionDataDelegate> {
@public
    NSMutableData *data;
    NSHTTPURLResponse *response;
    NSError *error;
    BOOL done;
    NSUInteger capacity;
    NSUInteger redirects;
}
@end

@implementation RewindHTTPTransfer
- (void)dealloc {
    [data release];
    [response release];
    [error release];
    [super dealloc];
}

- (void)fail:(NSError *)failure connection:(NSURLConnection *)connection {
    if (done) return;
    error = [failure retain];
    done = YES;
    [connection cancel];
}

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)redirect {
    if (![@"https" isEqualToString:[request.URL.scheme lowercaseString]] || (redirect && ++redirects > 5)) {
        [self fail:RewindHTTPError(NSURLErrorBadServerResponse, @"invalid secure redirect") connection:connection];
        return nil;
    }
    return request;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)reply {
    if (![reply isKindOfClass:[NSHTTPURLResponse class]] ||
        ![@"https" isEqualToString:[reply.URL.scheme lowercaseString]]) {
        [self fail:RewindHTTPError(NSURLErrorBadServerResponse, @"invalid HTTP response") connection:connection];
        return;
    }
    [response release];
    response = [(NSHTTPURLResponse *)reply retain];
    [data setLength:0];
    if (reply.expectedContentLength > (long long)capacity)
        [self fail:RewindHTTPError(NSURLErrorDataLengthExceedsMaximum, @"response exceeds its size limit")
        connection:connection];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)bytes {
    if (done) return;
    if (bytes.length > capacity - data.length) {
        [self fail:RewindHTTPError(NSURLErrorDataLengthExceedsMaximum, @"response exceeds its size limit")
        connection:connection];
        return;
    }
    [data appendData:bytes];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)failure {
    [self fail:failure connection:connection];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    (void)connection;
    done = YES;
}
@end

NSData *RewindHTTPFetch(NSURLRequest *request, NSUInteger capacity,
                        NSHTTPURLResponse **response, NSError **error) {
    return RewindHTTPFetchCancellable(request, capacity, response, error, nil);
}

NSData *RewindHTTPFetchCancellable(NSURLRequest *request, NSUInteger capacity,
                                   NSHTTPURLResponse **response, NSError **error, BOOL (^cancelled)(void)) {
    if (response) *response = nil;
    if (error) *error = nil;
    if (!request || !capacity || [NSThread isMainThread] ||
        !isfinite(request.timeoutInterval) || request.timeoutInterval <= 0 ||
        ![@"https" isEqualToString:[request.URL.scheme lowercaseString]]) {
        if (error) *error = RewindHTTPError(NSURLErrorBadURL, @"invalid background HTTPS request");
        return nil;
    }
    RewindHTTPTransfer *transfer = [[[RewindHTTPTransfer alloc] init] autorelease];
    transfer->data = [[NSMutableData alloc] init];
    transfer->capacity = capacity;
    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:request delegate:transfer startImmediately:NO];
    if (!connection) {
        if (error) *error = RewindHTTPError(NSURLErrorCannotConnectToHost, @"HTTP connection could not start");
        return nil;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:request.timeoutInterval];
    [connection scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [connection start];
    while (!transfer->done && [deadline timeIntervalSinceNow] > 0) {
        if (cancelled && cancelled()) {
            [transfer fail:RewindHTTPError(NSURLErrorCancelled, @"HTTP transfer cancelled") connection:connection];
            break;
        }
        NSDate *tick = [NSDate dateWithTimeIntervalSinceNow:MIN(0.1, [deadline timeIntervalSinceNow])];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:tick];
    }
    if (!transfer->done)
        [transfer fail:RewindHTTPError(NSURLErrorTimedOut, @"HTTP transfer timed out") connection:connection];
    [connection cancel];
    [connection release];
    if (response) *response = [[transfer->response retain] autorelease];
    if (error) *error = [[transfer->error retain] autorelease];
    return transfer->error ? nil : [[transfer->data retain] autorelease];
}
