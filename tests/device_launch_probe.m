#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <signal.h>
#include <unistd.h>

static void launch_timeout(int signal_number) {
    (void)signal_number;
    static const char message[] = "SpringBoard launch request timed out\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

int main(int argc, char **argv) {
    if (argc != 2 || !argv[1][0]) {
        fprintf(stderr, "usage: RewindDeviceLaunch bundle.identifier\n");
        return 2;
    }
    signal(SIGALRM, launch_timeout);
    alarm(15);
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    void *services = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    if (!services) {
        fprintf(stderr, "SpringBoardServices: %s\n", dlerror());
        [pool drain];
        return 2;
    }
    int (*launch)(CFStringRef, Boolean) = dlsym(services, "SBSLaunchApplicationWithIdentifier");
    mach_port_t (*server_port)(void) = dlsym(services, "SBSSpringBoardServerPort");
    void (*lock_status)(mach_port_t, bool *, bool *) = dlsym(services, "SBGetScreenLockStatus");
    CFStringRef (*error_string)(int) = dlsym(services, "SBSApplicationLaunchingErrorString");
    if (!launch || !server_port || !lock_status) {
        fprintf(stderr, "required SpringBoard launch or screen-lock symbol missing\n");
        dlclose(services);
        [pool drain];
        return 2;
    }
    mach_port_t port = server_port();
    bool locked = true, passcode = true;
    if (port == MACH_PORT_NULL) {
        fprintf(stderr, "SpringBoard server port unavailable\n");
        dlclose(services);
        [pool drain];
        return 2;
    }
    lock_status(port, &locked, &passcode);
    fprintf(stderr, "screen locked=%d passcode=%d\n", locked, passcode);
    if (locked || passcode) {
        fprintf(stderr, "unlock the device before launching the registered probe\n");
        dlclose(services);
        [pool drain];
        return 3;
    }
    NSString *identifier = [NSString stringWithUTF8String:argv[1]];
    if (!identifier) {
        fprintf(stderr, "bundle identifier is not UTF-8\n");
        dlclose(services);
        [pool drain];
        return 2;
    }
    int result = launch((CFStringRef)identifier, false);
    CFStringRef description = error_string ? error_string(result) : NULL;
    fprintf(stderr, "launch %s: %d %s\n", argv[1], result,
        description ? [(NSString *)description UTF8String] : "no error description");
    /* a successful request does not imply that the application's tests passed */
    dlclose(services);
    [pool drain];
    return result == 0 ? 0 : 1;
}
