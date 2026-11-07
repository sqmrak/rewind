#import "rewind_openlink.h"
#import "playlist_vc.h"
#import "rewind_api.h"
#import "rewind_l10n.h"
#include "rewind_link.h"

BOOL RewindOpenPlaylistLink(NSString *text, UINavigationController *navigation, RewindPlayer *player, RewindAPI *api) {
    if (![text isKindOfClass:[NSString class]] || !navigation) return NO;
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    rewind_link link;
    if (!rewind_link_parse((const char *)bytes.bytes, bytes.length, &link) || !link.list_id[0]) return NO;
    NSString *listID = [NSString stringWithUTF8String:link.list_id];
    /* the link carries no title; the page names itself generically until the tracks arrive */
    RewindTrack *playlist = [[[RewindTrack alloc] initWithVideoID:nil title:RewindL(@"playlist") artist:nil album:nil
                                                     thumbnailURL:nil duration:0 playlistID:listID artistID:nil
                                                       resultType:nil] autorelease];
    RewindPlaylistVC *page = [[[RewindPlaylistVC alloc] initWithRemotePlaylist:playlist player:player api:api] autorelease];
    [navigation setNavigationBarHidden:NO animated:NO];
    [navigation pushViewController:page animated:YES];
    return YES;
}

NSString *RewindClipboardLinkText(void) {
    NSString *text = [[[UIPasteboard generalPasteboard] string] stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) return nil;
    for (NSString *scheme in [NSArray arrayWithObjects:@"https://", @"http://", nil]) {
        if ([text rangeOfString:scheme options:NSAnchoredSearch | NSCaseInsensitiveSearch].location == NSNotFound) continue;
        return [@"rewind://" stringByAppendingString:[text substringFromIndex:scheme.length]];
    }
    return text;
}
