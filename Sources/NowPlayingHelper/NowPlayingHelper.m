// macOS's system "Now Playing" info (what Control Center shows) lives in the
// private MediaRemote framework. Since macOS 15.4 it only answers Apple-signed
// processes, so GeissMac doesn't call it itself: TrackWatcher runs
// /usr/bin/perl, which loads this library and calls the function below as a
// perl XSUB. It prints one JSON line whenever the track changes, and exits
// once GeissMac is gone — even if it was killed outright, when the pipe alone
// wouldn't tell until the next track change.
//
// Private API: fine for the GitHub-release app (not the App Store), but any
// macOS update could break it — the app then just shows no song titles.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
#include "NowPlayingHelper.h"

typedef void (*GetNowPlayingInfo)(dispatch_queue_t, void (^)(NSDictionary *));

void geissmac_now_playing_loop(void *perl, void *cv) {
    void *mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    GetNowPlayingInfo getInfo = mediaRemote ? (GetNowPlayingInfo)dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    if (!getInfo) {
        return;
    }
    NSString *last = nil;
    pid_t parent = getppid();
    while (getppid() == parent) {
        @autoreleasepool {
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block NSDictionary *latest = @{};
            getInfo(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(NSDictionary *info) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
                NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
                NSNumber *rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
                if ([title isKindOfClass:[NSString class]]) out[@"title"] = title;
                if ([artist isKindOfClass:[NSString class]]) out[@"artist"] = artist;
                if ([rate isKindOfClass:[NSNumber class]]) out[@"playing"] = @(rate.doubleValue > 0);
                latest = out;
                dispatch_semaphore_signal(done);
            });
            dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
            NSData *json = [NSJSONSerialization dataWithJSONObject:latest options:NSJSONWritingSortedKeys error:nil];
            NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
            if (line && ![line isEqualToString:last]) {
                printf("%s\n", line.UTF8String);
                fflush(stdout);
                last = line;
            }
        }
        usleep(1000000);
    }
}
