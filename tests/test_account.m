#import <Foundation/Foundation.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

/* the runner prepends production helpers; store fixtures redirect only the home path */
int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *text = @"{\"actions\":[{\"accountItem\":{\"accountName\":{\"simpleText\":\"other channel\"},\"isSelected\":false}},{\"accountItem\":{\"accountName\":{\"runs\":[{\"text\":\"selected channel\"}]},\"isSelected\":true}}]}";
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    NSDictionary *selected = RewindAccountSelectedItem(root, 0);
    assert([RewindTVText([selected objectForKey:@"accountName"]) isEqualToString:@"selected channel"]);
    assert(!RewindAccountSelectedItem([NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:@"true" forKey:@"isSelected"] forKey:@"accountItem"],0));
    assert(!RewindAccountSelectedItem([NSNull null],0));
    assert(!RewindAccountSelectedItem(root,49));
    assert(!RewindTVIsID(nil,11,11));
    assert(!RewindTVIsID((id)[NSNull null],11,11));
    assert(!RewindTVIsID(@"abcdefghij!",11,11));
    assert(!RewindTVIsID(@"abcdefghij",11,11));
    assert(RewindTVIsID(@"abcdefgh_-1",11,11));
    assert(RewindAccountSeconds([NSNull null],5)==5);
    assert(RewindAccountSeconds(@"12",5)==5);
    assert(RewindAccountSeconds([NSNumber numberWithDouble:NAN],5)==5);
    assert(RewindAccountSeconds([NSNumber numberWithDouble:INFINITY],5)==5);
    assert(RewindAccountSeconds([NSNumber numberWithInt:-1],5)==5);
    assert(RewindAccountSeconds([NSNumber numberWithInt:12],5)==12);
    assert(RewindAccountOAuthCredential(@"123-fixture.apps.googleusercontent.com",YES));
    assert(!RewindAccountOAuthCredential(@".apps.googleusercontent.com",YES));
    assert(!RewindAccountOAuthCredential(@"123.apps.googleusercontent.com.attacker.test",YES));
    assert(!RewindAccountOAuthCredential(@"bad\nvalue",NO));
    assert(!RewindAccountOAuthCredential((id)[NSNull null],NO));
    assert(!RewindAccountOAuthCredential(nil,NO));
    assert(!RewindAccountOAuthCredential(@"",NO));
    assert(RewindAccountOAuthCredential(@"GOCSPX-fixture_secret",NO));
    text = @"{\"error\":{\"code\":403,\"message\":\"Access Not Configured\",\"errors\":[{\"reason\":\"accessNotConfigured\"}]}}";
    root = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    NSError *error = RewindAccountResponseError(403,root);
    assert(error.code==403);
    assert([[error.userInfo objectForKey:@"YouTubeReason"] isEqualToString:@"accessNotConfigured"]);
    assert([[error localizedDescription] rangeOfString:@"YouTube OAuth setup"].location!=NSNotFound);
    g_account.oauthClientSecret = @"fixture_secret";
    root = [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:@"fixture_secret" forKey:@"message"] forKey:@"error"];
    assert([[RewindAccountResponseError(403,root) localizedDescription] isEqualToString:@"[redacted]"]);
    g_account.oauthClientSecret = nil;
    if (argc == 3) {
        NSData *bytes = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        root = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
        selected = RewindAccountSelectedItem(root,0);
        assert([RewindTVText([selected objectForKey:@"accountName"]) isEqualToString:[NSString stringWithUTF8String:argv[2]]]);
    }
    char temporary[] = "/tmp/rewind-oauth-fixture-XXXXXX";
    assert(mkdtemp(temporary));
    fixture_home = [NSString stringWithUTF8String:temporary];
    rewind_account_state_t candidate = {0};
    candidate.oauthClientID = @"123-fixture.apps.googleusercontent.com";
    candidate.oauthClientSecret = @"fixture_config_secret";
    candidate.refreshToken = @"fixture_refresh";
    candidate.clientID = @"456-active.apps.googleusercontent.com";
    candidate.clientSecret = @"fixture_active_secret";
    assert(RewindAccountWriteState(&candidate));
    struct stat metadata;
    assert(!stat([RewindAccountStorePath() fileSystemRepresentation], &metadata));
    assert((metadata.st_mode & 0777)==0600);
    RewindAccountLoadState();
    assert([g_account.oauthClientID isEqualToString:candidate.oauthClientID]);
    assert([g_account.clientID isEqualToString:candidate.clientID]);
    assert([g_account.oauthClientSecret isEqualToString:candidate.oauthClientSecret]);
    candidate.refreshToken = nil;
    assert(RewindAccountWriteState(&candidate));
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:RewindAccountStorePath()];
    assert(![stored objectForKey:@"refresh"]);
    assert(![stored objectForKey:@"clientID"]);
    assert(![stored objectForKey:@"clientSecret"]);
    assert([[stored objectForKey:@"oauthClientID"] isEqualToString:candidate.oauthClientID]);
    candidate.oauthClientID = nil;
    candidate.oauthClientSecret = nil;
    assert(RewindAccountWriteState(&candidate));
    assert(![[NSFileManager defaultManager] fileExistsAtPath:RewindAccountStorePath()]);
    assert([[NSFileManager defaultManager] removeItemAtPath:fixture_home error:NULL]);
    [pool drain];
    puts("production account authorization, selected-name and secure-store fixtures passed");
    return 0;
}
