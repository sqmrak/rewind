#import "rewind_download.h"
#import "rewind_api.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#include "rewind_audio.h"
#include "rewind_fmp4.h"
#include <sys/stat.h>
#include <sys/mman.h>

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

NSString * const RewindDownloadsDidChangeNotification = @"RewindDownloadsDidChangeNotification";

static NSError *RewindDownloadError(NSInteger code, NSString *text) {
    return [NSError errorWithDomain:@"RewindDownload" code:code
                          userInfo:[NSDictionary dictionaryWithObject:text forKey:NSLocalizedDescriptionKey]];
}

static void RewindDownloadRemove(NSString *path) {
    if (path && unlink([path fileSystemRepresentation]) && errno != ENOENT)
        RewindDebugLog(@"download cleanup %@: %s", path, strerror(errno));
}

static NSMutableSet *RewindDownloadActive(void) {
    static NSMutableSet *active;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ active = [[NSMutableSet alloc] init]; });
    return active;
}

static NSString *RewindDownloadDirectory(void) {
#ifdef REWIND_DOWNLOAD_TEST_DIRECTORY
    return REWIND_DOWNLOAD_TEST_DIRECTORY;
#endif
    NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    return documents ? [documents stringByAppendingPathComponent:@"RewindDownloads"] : nil;
}

static NSDictionary *RewindDownloadRecord(NSString *videoID) {
    if (videoID.length != 11 || !rewind_audio_video_id([videoID UTF8String])) return nil;
    NSString *directory = RewindDownloadDirectory();
    if (!directory) return nil;
    NSString *path = [directory stringByAppendingPathComponent:[videoID stringByAppendingString:@".plist"]];
    struct stat st;
    if (lstat([path fileSystemRepresentation], &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > 32768) return nil;
    /* read the checked descriptor so replacement cannot bypass the metadata bound */
    int fd = open([path fileSystemRepresentation], O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return nil;
    uint8_t buffer[32769];
    size_t length = 0;
    BOOL valid = !fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_size > 0 && st.st_size <= 32768;
    while (valid && length < sizeof(buffer)) {
        ssize_t count = read(fd, buffer + length, sizeof(buffer) - length);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { valid = NO; break; }
        if (!count) break;
        length += (size_t)count;
    }
    if (close(fd)) valid = NO;
    if (!valid || !length || length > 32768) return nil;
    NSDictionary *record = [NSPropertyListSerialization propertyListWithData:
        [NSData dataWithBytes:buffer length:length] options:NSPropertyListImmutable format:NULL error:NULL];
    if (![record isKindOfClass:[NSDictionary class]] || ![[record objectForKey:@"videoID"] isEqual:videoID] ||
        ![[record objectForKey:@"version"] isEqual:@1]) return nil;
    for (NSString *key in [NSArray arrayWithObjects:@"title", @"artist", @"album", @"thumbnailURL", nil]) {
        id value = [record objectForKey:key];
        if (![value isKindOfClass:[NSString class]] || [value length] > 4096) return nil;
    }
    id bytes = [record objectForKey:@"bytes"], duration = [record objectForKey:@"duration"];
    if (![bytes isKindOfClass:[NSNumber class]] || ![duration isKindOfClass:[NSNumber class]] ||
        [bytes longLongValue] <= 0 || [bytes longLongValue] > 100 * 1024 * 1024 ||
        [bytes doubleValue] != (double)[bytes longLongValue] ||
        [duration doubleValue] < 0 || [duration doubleValue] > UINT32_MAX ||
        [duration doubleValue] != (double)[duration unsignedLongLongValue]) return nil;
    path = [directory stringByAppendingPathComponent:[videoID stringByAppendingString:@".m4a"]];
    if (lstat([path fileSystemRepresentation], &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 ||
        st.st_size > 100 * 1024 * 1024 || (unsigned long long)st.st_size != [bytes unsignedLongLongValue]) return nil;
    return record;
}

NSURL *RewindDownloadedURLForTrack(NSString *videoID) {
    if (!RewindDownloadRecord(videoID)) return nil;
    return [NSURL fileURLWithPath:[RewindDownloadDirectory() stringByAppendingPathComponent:
                                 [videoID stringByAppendingString:@".m4a"]]];
}

NSArray *RewindDownloadedTracks(void) {
    NSMutableArray *tracks = [NSMutableArray array];
    NSError *error = nil;
    NSString *directory = RewindDownloadDirectory();
    if (!directory || ![[NSFileManager defaultManager] fileExistsAtPath:directory]) return tracks;
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:&error];
    if (error) RewindDebugLog(@"download index: %@", error);
    for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
        if (![[name pathExtension] isEqual:@"plist"]) continue;
        NSDictionary *record = RewindDownloadRecord([name stringByDeletingPathExtension]);
        if (!record) continue;
        RewindTrack *track = [[[RewindTrack alloc] initWithVideoID:[record objectForKey:@"videoID"]
            title:[record objectForKey:@"title"] artist:[record objectForKey:@"artist"]
            album:[record objectForKey:@"album"] thumbnailURL:[record objectForKey:@"thumbnailURL"]
            duration:[[record objectForKey:@"duration"] unsignedIntegerValue]] autorelease];
        [tracks addObject:track];
        if (tracks.count == 500) break;
    }
    return tracks;
}

static void RewindDownloadComplete(NSString *videoID, NSError *error, void (^completion)(NSError *)) {
    @synchronized(RewindDownloadActive()) { [RewindDownloadActive() removeObject:videoID]; }
    if (error) RewindDebugLog(@"download %@: %@", videoID, error);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!error) [[NSNotificationCenter defaultCenter] postNotificationName:RewindDownloadsDidChangeNotification
            object:nil userInfo:[NSDictionary dictionaryWithObject:videoID forKey:@"videoID"]];
        if (completion) completion(error);
    });
}

static BOOL RewindDownloadReserve(NSString *videoID, void (^completion)(NSError *)) {
    NSError *error = nil;
    @synchronized(RewindDownloadActive()) {
        if (videoID.length != 11 || !rewind_audio_video_id([videoID UTF8String])) error = RewindDownloadError(1, @"Invalid track identifier");
        else if ([RewindDownloadActive() containsObject:videoID]) error = RewindDownloadError(9, @"This track is already downloading");
        else if (RewindDownloadActive().count >= 2) error = RewindDownloadError(9, @"Two downloads are already running");
        else [RewindDownloadActive() addObject:videoID];
    }
    if (error) {
        RewindDebugLog(@"download rejected %@: %@", videoID, error);
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(error); });
        return NO;
    }
    return YES;
}

@interface RewindDownloadTask : NSObject <NSURLConnectionDataDelegate> {
    NSURL *_url;
    RewindTrack *_track;
    NSString *_userAgent;
    BOOL _loopback;
    BOOL _ownsSource;
    NSInteger _redirects;
    long long _expected;
    NSString *_videoID;
    NSString *_tempPath;
    NSString *_finalPath;
    NSURLConnection *_connection;
    void (^_completion)(NSError *error);
    int _fd;
    NSUInteger _bytes;
    BOOL _finished;
}
- (id)initWithURL:(NSURL *)url videoID:(NSString *)videoID completion:(void (^)(NSError *))completion;
- (void)start;
- (void)run;
- (void)setTrack:(RewindTrack *)track;
- (void)ownResolvedSource;
- (void)appendData:(NSData *)data;
- (void)loaded;
@end

@implementation RewindDownloadTask

- (id)initWithURL:(NSURL *)url videoID:(NSString *)videoID completion:(void (^)(NSError *))completion {
    self = [super init];
    if (!self) return nil;
    _url = [url retain];
    _videoID = [videoID copy];
    _completion = [completion copy];
    _fd = -1;
    _expected = -1;
    _userAgent = [RewindAudioUserAgentForURL(url) copy];
    _loopback = [[url.scheme lowercaseString] isEqual:@"http"] && [url.host isEqual:@"127.0.0.1"] &&
                url.port != nil && RewindAudioSourceKeyForURL(url).length > 0;
    return self;
}

- (void)dealloc {
    [_connection cancel];
    [_connection release];
    if (_fd >= 0) close(_fd);
    if (_tempPath) RewindDownloadRemove(_tempPath);
    [_track release];
    [_userAgent release];
    [_url release];
    [_videoID release];
    [_tempPath release];
    [_finalPath release];
    [_completion release];
    [super dealloc];
}

- (void)setTrack:(RewindTrack *)track { [track retain]; [_track release]; _track = track; }

- (void)ownResolvedSource {
    /* only the resolver's SABR scratch file transfers ownership to this task */
    _ownsSource = _url.isFileURL && [RewindAudioSourceKeyForURL(_url) hasSuffix:@":sabr"] &&
        [[[_url.path stringByDeletingLastPathComponent] stringByStandardizingPath] isEqual:[NSTemporaryDirectory() stringByStandardizingPath]] &&
        [[_url.path lastPathComponent] hasPrefix:@"rewind-sabr-"];
}

- (NSError *)commit {
    struct stat st;
    if (fstat(_fd, &st) || st.st_size <= 0 || st.st_size > 100 * 1024 * 1024)
        return RewindDownloadError(8, @"The audio file is empty or too large");
    size_t length = (size_t)st.st_size;
    uint8_t *data = mmap(NULL, length, PROT_READ, MAP_PRIVATE, _fd, 0);
    if (data == MAP_FAILED) return RewindDownloadError(errno, @"Could not validate the audio file");
    rewind_fmp4_t *file = NULL;
    size_t needed = 0;
    BOOL fragmented = NO, valid = rewind_audio_mp4(data, length);
    /* a complete box walk rejects a truncated tail before AVFoundation reads metadata */
    for (size_t offset = 0; valid && offset < length;) {
        if (length - offset < 8) { valid = NO; break; }
        uint64_t size = ((uint32_t)data[offset] << 24) | ((uint32_t)data[offset+1] << 16) |
                        ((uint32_t)data[offset+2] << 8) | data[offset+3];
        size_t header = 8;
        if (size == 1) {
            if (length - offset < 16) { valid = NO; break; }
            size = 0;
            for (size_t i = 8; i < 16; ++i) size = (size << 8) | data[offset+i];
            header = 16;
        } else if (!size) size = length - offset;
        if (size < header || size > length - offset) { valid = NO; break; }
        if (!memcmp(data + offset + 4, "moof", 4)) fragmented = YES;
        offset += (size_t)size;
    }
    NSString *converted = [_tempPath stringByAppendingString:@".m4a"];
    int output = -1;
    if (valid && fragmented) {
        valid = rewind_fmp4_open(data, length, &needed, &file) == REWIND_FMP4_OK;
        for (size_t i = 0; valid && i < rewind_fmp4_fragment_count(file); ++i) {
            uint64_t offset = rewind_fmp4_fragment_offset(file, i), size = rewind_fmp4_fragment_size(file, i);
            valid = offset < length && size <= length - offset &&
                rewind_fmp4_add_fragment(file, i, data + offset, (size_t)size, &needed) == REWIND_FMP4_OK;
        }
        valid = valid && rewind_fmp4_finish(file) == REWIND_FMP4_OK &&
                rewind_fmp4_output_size(file) <= 100 * 1024 * 1024;
        if (valid) output = open([converted fileSystemRepresentation], O_WRONLY | O_CREAT | O_EXCL, 0600);
        valid = valid && output >= 0;
        size_t headerLength = 0;
        const uint8_t *header = valid ? rewind_fmp4_header(file, &headerLength) : NULL;
        for (size_t i = 0; valid && i <= rewind_fmp4_chunk_count(file); ++i) {
            const uint8_t *bytes = header;
            size_t count = headerLength;
            if (i) {
                const rewind_fmp4_chunk_t *chunk = rewind_fmp4_chunk(file, i - 1);
                if (chunk->source_offset > length || chunk->length > length - chunk->source_offset) { valid = NO; break; }
                bytes = data + chunk->source_offset;
                count = (size_t)chunk->length;
            }
            while (valid && count) {
                ssize_t wrote = write(output, bytes, count);
                if (wrote < 0 && errno == EINTR) continue;
                if (wrote <= 0) { valid = NO; break; }
                bytes += wrote;
                count -= (size_t)wrote;
            }
        }
        if (output >= 0) {
            if (fsync(output)) valid = NO;
            if (close(output)) valid = NO;
        }
    }
    rewind_fmp4_free(file);
    munmap(data, length);
    if (!valid) {
        RewindDownloadRemove(converted);
        return RewindDownloadError(10, @"The download is not a complete supported MP4 audio file");
    }
    NSString *source = fragmented ? converted : _tempPath;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:source] options:nil];
    AVAssetTrack *audioTrack = nil;
    for (AVAssetTrack *track in [asset tracksWithMediaType:AVMediaTypeAudio]) {
        for (id format in track.formatDescriptions) {
            if (CMFormatDescriptionGetMediaSubType((CMFormatDescriptionRef)format) == 'aac ') audioTrack = track;
        }
    }
    if (!audioTrack || !asset.playable) {
        RewindDownloadRemove(converted);
        return RewindDownloadError(10, @"The download has no playable audio track");
    }
    NSError *readerError = nil;
    AVAssetReader *reader = [[[AVAssetReader alloc] initWithAsset:asset error:&readerError] autorelease];
    /* compressed passthrough does not detect corrupt AAC packets */
    NSDictionary *settings = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedInt:kAudioFormatLinearPCM], AVFormatIDKey,
        @16, AVLinearPCMBitDepthKey, @NO, AVLinearPCMIsFloatKey,
        @NO, AVLinearPCMIsBigEndianKey, nil];
    AVAssetReaderTrackOutput *trackOutput = [[[AVAssetReaderTrackOutput alloc]
        initWithTrack:audioTrack outputSettings:settings] autorelease];
    BOOL readable = reader && trackOutput && [reader canAddOutput:trackOutput];
    if (readable) {
        [reader addOutput:trackOutput];
        readable = [reader startReading];
    }
    NSUInteger sampleBuffers = 0;
    unsigned long long sampleBytes = 0;
    unsigned long long decodedSamples = 0;
    NSDate *readDeadline = [NSDate dateWithTimeIntervalSinceNow:60];
    while (readable && reader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sample = [trackOutput copyNextSampleBuffer];
        if (!sample) break;
        sampleBytes += CMSampleBufferGetTotalSampleSize(sample);
        decodedSamples += CMSampleBufferGetNumSamples(sample);
        CFRelease(sample);
        if (++sampleBuffers > 1000000 || sampleBytes > 2ULL * 1024 * 1024 * 1024 || readDeadline.timeIntervalSinceNow <= 0) {
            readable = NO;
            [reader cancelReading];
        }
    }
    if (!readable || !sampleBuffers || !decodedSamples || !sampleBytes || reader.status != AVAssetReaderStatusCompleted) {
        RewindDownloadRemove(converted);
        return reader.error ?: readerError ?: RewindDownloadError(10, @"The audio samples are incomplete or unsupported");
    }
    if (fsync(_fd) || stat([source fileSystemRepresentation], &st)) {
        RewindDownloadRemove(converted);
        return RewindDownloadError(errno, @"Could not save the audio file");
    }
    NSMutableDictionary *record = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @1, @"version", _videoID, @"videoID", [NSNumber numberWithLongLong:st.st_size], @"bytes",
        [NSNumber numberWithUnsignedLongLong:MIN((unsigned long long)_track.duration, (unsigned long long)UINT32_MAX)], @"duration", nil];
    NSArray *values = [NSArray arrayWithObjects:_track.title ?: _videoID, _track.artist ?: @"",
                      _track.album ?: @"", _track.thumbnailURL ?: @"", nil];
    NSArray *keys = [NSArray arrayWithObjects:@"title", @"artist", @"album", @"thumbnailURL", nil];
    for (NSUInteger i = 0; i < keys.count; ++i) {
        NSString *value = [values objectAtIndex:i];
        if (value.length > 4096) value = [value substringToIndex:4096];
        [record setObject:value forKey:[keys objectAtIndex:i]];
    }
    NSError *error = nil;
    NSData *metadata = [NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    NSString *recordPath = [[_finalPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"plist"];
    NSString *pending = [_tempPath stringByAppendingString:@".plist"];
    if (!metadata || metadata.length > 32768 || ![metadata writeToFile:pending options:NSDataWritingAtomic error:&error]) {
        RewindDownloadRemove(converted);
        RewindDownloadRemove(pending);
        return error ?: RewindDownloadError(11, @"Could not save download metadata");
    }
    int metadataFD = open([pending fileSystemRepresentation], O_RDONLY);
    BOOL synced = metadataFD >= 0 && fsync(metadataFD) == 0;
    if (metadataFD >= 0 && close(metadataFD)) synced = NO;
    @synchronized([RewindDownloadTask class]) {
        if (!synced) error = RewindDownloadError(errno, @"Could not sync download metadata");
        else if (RewindDownloadedTracks().count >= 500) error = RewindDownloadError(7, @"The offline library is full");
        int directoryFD = error ? -1 : open([RewindDownloadDirectory() fileSystemRepresentation], O_RDONLY);
        BOOL published = NO;
        if (!error && directoryFD < 0) error = RewindDownloadError(errno, @"Could not open the download folder");
        if (!error && rename([source fileSystemRepresentation], [_finalPath fileSystemRepresentation]))
            error = RewindDownloadError(errno, @"Could not commit the audio file");
        if (!error && fsync(directoryFD)) error = RewindDownloadError(errno, @"Could not sync the audio file name");
        if (!error && rename([pending fileSystemRepresentation], [recordPath fileSystemRepresentation]))
            error = RewindDownloadError(errno, @"Could not commit download metadata");
        else if (!error) published = YES;
        if (!error && fsync(directoryFD)) error = RewindDownloadError(errno, @"Could not sync the download folder");
        if (directoryFD >= 0 && close(directoryFD) && !error)
            error = RewindDownloadError(errno, @"Could not close the download folder");
        if (error && !published) RewindDownloadRemove(_finalPath);
    }
    RewindDownloadRemove(pending);
    RewindDownloadRemove(converted);
    return error;
}

- (void)finish:(NSError *)error {
    if (_finished) return;
    _finished = YES;
    [_connection cancel];
    [_connection autorelease];
    _connection = nil;
    if (!error) error = [self commit];
    if (_fd >= 0) {
        if (close(_fd) && !error) error = RewindDownloadError(errno, @"Could not close the download");
        _fd = -1;
    }
    if (_tempPath) RewindDownloadRemove(_tempPath);
    if (_ownsSource && unlink([_url.path fileSystemRepresentation]) && errno != ENOENT)
        RewindDebugLog(@"download resolver cleanup: %s", strerror(errno));
    RewindDownloadComplete(_videoID, error, _completion);
}

- (void)run {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [self start];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:180];
    while (!_finished && [deadline timeIntervalSinceNow] > 0) {
        NSAutoreleasePool *iteration = [[NSAutoreleasePool alloc] init];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        [iteration drain];
    }
    if (!_finished) [self finish:RewindDownloadError(12, @"The download timed out")];
    [pool drain];
}

- (void)start {
    /* video ids are the only remote input used in a Documents path */
    if (_videoID.length != 11 || !rewind_audio_video_id([_videoID UTF8String])) {
        [self finish:RewindDownloadError(1, @"Invalid track identifier")];
        return;
    }
    if (!_url.isFileURL && !_loopback && ![@"https" isEqualToString:[_url.scheme lowercaseString]]) {
        [self finish:RewindDownloadError(2, @"Audio URL must use HTTPS")];
        return;
    }
    NSString *directory = RewindDownloadDirectory();
    NSError *directoryError = nil;
    if (!directory || ![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        [self finish:directoryError ?: RewindDownloadError(3, @"Downloads folder is unavailable")];
        return;
    }
    if (RewindDownloadedURLForTrack(_videoID)) {
        _finished = YES;
        if (_ownsSource && unlink([_url.path fileSystemRepresentation]) && errno != ENOENT)
            RewindDebugLog(@"download resolver cleanup: %s", strerror(errno));
        RewindDownloadComplete(_videoID, nil, _completion);
        return;
    }
    if (RewindDownloadedTracks().count >= 500) {
        [self finish:RewindDownloadError(7, @"The offline library is full")];
        return;
    }
    NSString *name = [_videoID stringByAppendingString:@".m4a"];
    _finalPath = [[directory stringByAppendingPathComponent:name] copy];
    /* ios 5 AVFoundation rejects local AAC assets without the m4a extension */
    NSString *pattern = [directory stringByAppendingPathComponent:[name stringByAppendingString:@".XXXXXX.m4a"]];
    char *templatePath = strdup([pattern fileSystemRepresentation]);
    if (!templatePath) {
        [self finish:RewindDownloadError(ENOMEM, @"Could not prepare the download")];
        return;
    }
    _fd = mkstemps(templatePath, 4);
    if (_fd >= 0) _tempPath = [[[NSFileManager defaultManager] stringWithFileSystemRepresentation:templatePath
                                                                                             length:strlen(templatePath)] copy];
    free(templatePath);
    if (_fd < 0 || !_tempPath) {
        [self finish:RewindDownloadError(errno, @"Could not create the download file")];
        return;
    }
    if (_url.isFileURL) {
        int source = open([_url.path fileSystemRepresentation], O_RDONLY | O_NOFOLLOW);
        struct stat st;
        if (source < 0 || fstat(source, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > 100 * 1024 * 1024) {
            if (source >= 0) close(source);
            [self finish:RewindDownloadError(10, @"The local audio file is unavailable or too large")];
            return;
        }
        _expected = st.st_size;
        uint8_t buffer[65536];
        while (!_finished) {
            ssize_t count = read(source, buffer, sizeof(buffer));
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) { [self finish:RewindDownloadError(errno, @"Could not read local audio")]; break; }
            if (!count) break;
            NSAutoreleasePool *chunkPool = [[NSAutoreleasePool alloc] init];
            [self appendData:[NSData dataWithBytes:buffer length:(NSUInteger)count]];
            [chunkPool drain];
        }
        if (close(source) && !_finished) [self finish:RewindDownloadError(errno, @"Could not close local audio")];
        if (!_finished) [self loaded];
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_url
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                        timeoutInterval:30.0];
    NSString *userAgent = _userAgent;
    if (userAgent.length) [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    if (!_connection) {
        [self finish:RewindDownloadError(4, @"Could not start the download")];
        return;
    }
    [_connection start];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    (void)connection;
    if (_finished) return;
    if (_bytes || ![response isKindOfClass:[NSHTTPURLResponse class]] ||
        [(NSHTTPURLResponse *)response statusCode] != 200 ||
        (![@"https" isEqualToString:[response.URL.scheme lowercaseString]] &&
         !(_loopback && [response.URL isEqual:_url]))) {
        [self finish:RewindDownloadError(5, @"The audio server rejected the download")];
        return;
    }
    _expected = response.expectedContentLength;
    NSString *type = [[response MIMEType] lowercaseString];
    if (![type hasPrefix:@"audio/"] && ![type isEqualToString:@"video/mp4"] &&
        ![type isEqualToString:@"application/octet-stream"]) {
        [self finish:RewindDownloadError(6, @"The audio server returned a different format")];
        return;
    }
    if (response.expectedContentLength > 100 * 1024 * 1024)
        [self finish:RewindDownloadError(7, @"The download is too large")];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    (void)connection;
    [self appendData:data];
}

- (void)appendData:(NSData *)data {
    if (_finished) return;
    if (data.length > 100 * 1024 * 1024 - _bytes) {
        [self finish:RewindDownloadError(7, @"The download is too large")];
        return;
    }
    const unsigned char *bytes = [data bytes];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = write(_fd, bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            [self finish:RewindDownloadError(errno, @"Could not write the download")];
            return;
        }
        offset += (NSUInteger)count;
    }
    _bytes += data.length;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    (void)connection;
    [self finish:error];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    (void)connection;
    [self loaded];
}

- (void)loaded {
    [self finish:(_bytes && (_expected < 0 || (unsigned long long)_expected == _bytes)) ? nil :
                  RewindDownloadError(8, @"The audio file is empty or incomplete")];
}

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response {
    (void)connection;
    if (!response) return request;
    if (_loopback || ++_redirects > 5 || ![[request.URL.scheme lowercaseString] isEqual:@"https"]) {
        [self finish:RewindDownloadError(5, @"The audio redirect is unsafe or exceeds the limit")];
        return nil;
    }
    return request;
}

@end

static void RewindDownloadLaunch(NSURL *url, RewindTrack *track, NSString *videoID, void (^completion)(NSError *)) {
    RewindDownloadTask *task = [[RewindDownloadTask alloc] initWithURL:url videoID:videoID completion:completion];
    [task setTrack:track];
    if (track) [task ownResolvedSource];
    [NSThread detachNewThreadSelector:@selector(run) toTarget:task withObject:nil];
    [task release];
}

void RewindStartDownload(NSURL *url, NSString *videoID, void (^completion)(NSError *error)) {
    if (RewindDownloadReserve(videoID, completion)) RewindDownloadLaunch(url, nil, videoID, completion);
}

void RewindDownloadTrack(RewindTrack *track, RewindAPI *api, void (^completion)(NSError *error)) {
    if (!RewindDownloadReserve(track.videoID, completion)) return;
    if (RewindDownloadedURLForTrack(track.videoID)) {
        RewindDownloadComplete(track.videoID, nil, completion);
        return;
    }
    if (!api) {
        RewindDownloadComplete(track.videoID, RewindDownloadError(2, @"Audio resolver is unavailable"), completion);
        return;
    }
    __block BOOL resolved = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [api streamURLForTrack:track completion:^(NSURL *url, NSError *error) {
            @synchronized(track) {
                if (resolved) return;
                resolved = YES;
            }
            if (!url) RewindDownloadComplete(track.videoID, error ?: RewindDownloadError(2, @"No audio source is available"), completion);
            else RewindDownloadLaunch(url, track, track.videoID, completion);
        }];
    });
}
