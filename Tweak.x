#import <Shared.h>
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <Dispatch/Dispatch.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <signal.h>
#include <execinfo.h>
#include <mach/mach.h>
#include <string.h>

// MARK: - File Logger
static const char *kLogPath = "/var/jb/var/mobile/log.txt";
static const off_t kMaxLogBytes = 10 * 1024;
static dispatch_queue_t logQueue;

static void ensureLogFile(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *dir = @"/var/jb/var/mobile";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        int fd = open(kLogPath, O_CREAT | O_APPEND, 0644);
        if (fd >= 0) close(fd);
    });
}

static void JBLogInternal(NSString *function, NSString *stage, NSString *message) {
    if (!logQueue) {
        logQueue = dispatch_queue_create("com.3h6-1.imread_log", DISPATCH_QUEUE_SERIAL);
    }
    pid_t pid = getpid();
    uint32_t tid = pthread_mach_thread_np(pthread_self());

    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tm; localtime_r(&tv.tv_sec, &tm);
    char timebuf[64];
    strftime(timebuf, sizeof(timebuf), "%Y-%m-%d %H:%M:%S", &tm);
    NSString *timeString = [NSString stringWithUTF8String:timebuf];
    int msec = (int)(tv.tv_usec/1000);

    NSData *msgData = [(message ?: @"") dataUsingEncoding:NSUTF8StringEncoding];

    dispatch_async(logQueue, ^{
        ensureLogFile();
        struct stat st;
        if (stat(kLogPath, &st) == 0) {
            if (st.st_size >= kMaxLogBytes) {
                return;
            }
        }
        const char *timeC = [timeString UTF8String];
        const char *funcC = function ? [function UTF8String] : "(null)";
        const char *stageC = stage ? [stage UTF8String] : "(null)";
        int fd = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            char prefix[512];
            int prefixLen = snprintf(prefix, sizeof(prefix), "%s.%03d pid=%d tid=%u [%s] {%s} ", timeC, msec, pid, tid, funcC, stageC);
            if (prefixLen > 0) write(fd, prefix, (size_t)prefixLen);
            if (msgData.length > 0) write(fd, msgData.bytes, msgData.length);
            write(fd, "\n", 1);
            close(fd);
        }
    });
}

static void JBLog(NSString *function, NSString *stage, NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *msg = nil;
    if (format && [format length] > 0) {
        msg = [[NSString alloc] initWithFormat:format arguments:args];
    } else {
        msg = @"";
    }
    va_end(args);
    JBLogInternal(function, stage, msg);
}

#define LOG_STAGE(stage, fmt, ...) JBLog(@(__PRETTY_FUNCTION__), @stage, @fmt, ##__VA_ARGS__)

// Minimal crash/exception logging
static void crash_signal_handler(int sig) {
    // Async-signal-safe logging: only use write/open/close
    int fd = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        const char *pfx = "CRASH SIGNAL: ";
        write(fd, pfx, strlen(pfx));
        char num[32];
        int n = snprintf(num, sizeof(num), "%d\n", sig);
        if (n > 0) write(fd, num, (size_t)n);
        close(fd);
    }
}

static void installCrashHandlers(void) {
    signal(SIGABRT, crash_signal_handler);
    signal(SIGSEGV, crash_signal_handler);
    signal(SIGBUS, crash_signal_handler);
    signal(SIGILL, crash_signal_handler);
}

static void uncaught_exception_handler(NSException *ex) {
    JBLog(@"uncaught_exception_handler", @"exception", @"Uncaught exception name=%@ reason=%@ userInfo=%@", ex.name, ex.reason, ex.userInfo);
}

// MARK: - Original tweak globals
static unsigned long long remainingNotificationsToProcess = 0;
static void (*original_dispatch_assert_queue)(dispatch_queue_t queue);
static dispatch_queue_t serialQueue;

// MARK: - Helpers
static void performWhileConnectedToImagent(dispatch_block_t imcoreBlock) {
    LOG_STAGE("start", "imcoreBlock=%p", imcoreBlock);
    @try {
        if ([[%c(IMDaemonController) sharedController] connectToDaemon]) {
            LOG_STAGE("connected", "scheduling block on serialQueue=%p", serialQueue);
            dispatch_async(serialQueue, ^{
                @try {
                    LOG_STAGE("imcoreBlock begin", "executing block=%p", imcoreBlock);
                    if (imcoreBlock) imcoreBlock();
                    LOG_STAGE("imcoreBlock end", "block complete");
                } @catch (NSException *ex) {
                    JBLog(@(__PRETTY_FUNCTION__), @"imcoreBlock exception", @"name=%@ reason=%@ userInfo=%@", ex.name, ex.reason, ex.userInfo);
                }
            });
        } else {
            JBLog(@(__PRETTY_FUNCTION__), @"connectToDaemon failed", @"Failed to connect to imagent :(");
        }
    } @catch (NSException *ex) {
        JBLog(@(__PRETTY_FUNCTION__), @"exception", @"name=%@ reason=%@ userInfo=%@", ex.name, ex.reason, ex.userInfo);
    }
}

%hook NCNotificationMasterList

- (void)removeNotificationRequest:(NCNotificationRequest*)notif {
    LOG_STAGE("start", "notif=%@ section=%@ remaining=%llu", notif, notif.sectionIdentifier, remainingNotificationsToProcess);
    @try {
        if (remainingNotificationsToProcess) {
            LOG_STAGE("branch", "remainingNotificationsToProcess > 0");
            if ([notif.sectionIdentifier isEqualToString:@"com.apple.MobileSMS"]) {
                LOG_STAGE("is MobileSMS", "processing iMessage/SMS notification");
                NSDictionary* userInfo = notif.context[@"userInfo"];
                NSString* full_guid = userInfo[@"CKBBContextKeyMessageGUID"];
                __NSCFString* chatId = userInfo[@"CKBBUserInfoKeyChatIdentifier"];

                JBLog(@(__PRETTY_FUNCTION__), @"context", @"chatId=%@ guid=%@ userInfoKeys=%@", chatId, full_guid, [userInfo allKeys]);

                // Fetching the IMChat may take a while, so we must do this in another thread for every notif clear in order to avoid freezing the main thread.
                performWhileConnectedToImagent(^{
                    @try {
                        LOG_STAGE("bg start", "chatId=%@ guid=%@", chatId, full_guid);
                        IMMessage* msg = nil;
                        NSDate* date = [NSDate date];
                        IMChat* imchat = [[%c(IMChatRegistry) sharedInstance] existingChatWithChatIdentifier:chatId];

                        if (imchat) {
                            JBLog(@(__PRETTY_FUNCTION__), @"imchat retrieved", @"in %F ms: %@", [date timeIntervalSinceNow] * -1000.0, imchat);
                        } else {
                            JBLog(@(__PRETTY_FUNCTION__), @"imchat nil", @"Failed to retrieve IMChat");
                            return;
                        }

                        // Sometimes these methods don't work on the first try, so we have to keep calling them until they do.
                        for (int x = 0; x < 8 && !msg; x++) {
                            [imchat loadMessagesUpToGUID:full_guid date:nil limit:0 loadImmediately:YES];
                            for (int i = 0; i < 1000 && !msg; i++) {
                                msg = [imchat messageForGUID:full_guid];
                            }
                            if (!msg) {
                                JBLog(@(__PRETTY_FUNCTION__), @"retry", @"attempt=%d still no message", x + 1);
                            }
                        }
                        JBLog(@(__PRETTY_FUNCTION__), @"message fetched", @"Message=%@", msg);
                        if (msg) {
                            [imchat markMessageAsRead:msg];
                            JBLog(@(__PRETTY_FUNCTION__), @"marked read", @"marked guid=%@ as read", full_guid);
                        } else {
                            JBLog(@(__PRETTY_FUNCTION__), @"message nil", @"Could not resolve message for guid=%@", full_guid);
                        }
                        LOG_STAGE("bg end", "done processing chatId=%@", chatId);
                    } @catch (NSException *ex) {
                        JBLog(@(__PRETTY_FUNCTION__), @"exception", @"name=%@ reason=%@ userInfo=%@", ex.name, ex.reason, ex.userInfo);
                    }
                });
            } else {
                LOG_STAGE("not MobileSMS", "section=%@", notif.sectionIdentifier);
            }
            remainingNotificationsToProcess--;
            JBLog(@(__PRETTY_FUNCTION__), @"decremented", @"remainingNotificationsToProcess=%llu", remainingNotificationsToProcess);
        }
    } @catch (NSException *ex) {
        JBLog(@(__PRETTY_FUNCTION__), @"exception", @"name=%@ reason=%@ userInfo=%@", ex.name, ex.reason, ex.userInfo);
    }
    %orig;
    LOG_STAGE("after %orig", "completed removeNotificationRequest");
}

%end

%hook IMDaemonController

// allows SpringBoard to use methods from IMCore
- (unsigned)_capabilities {
    LOG_STAGE("start", "");
    unsigned ret = 17159;
    JBLog(@(__PRETTY_FUNCTION__), @"return", @"%u", ret);
    return ret;
}

// for iOS 16+
- (unsigned long long)processCapabilities {
    LOG_STAGE("start", "");
    unsigned long long ret = 4485895ULL;
    JBLog(@(__PRETTY_FUNCTION__), @"return", @"%llu", ret);
    return ret;
}

%end

// These hooks are needed because sometimes removeNotificationRequest is called even when the user isn't explicitly clearing the notification.
%hook NCBulletinActionRunner

- (void)executeAction:(NCNotificationAction*)action fromOrigin:(NSString*)origin endpoint:(BSServiceConnectionEndpoint*)endpoint withParameters:(id)params completion:(id)block {
    LOG_STAGE("start", "action.id=%@ origin=%@ endpoint=%@ params=%@", action.identifier, origin, endpoint, params);
    @try {
        if ([action.identifier isEqualToString:UNNotificationDismissActionIdentifier]) {
            remainingNotificationsToProcess = 1;
            JBLog(@(__PRETTY_FUNCTION__), @"set remaining", @"remainingNotificationsToProcess=%llu", remainingNotificationsToProcess);
        }
    } @catch (NSException *ex) {
        JBLog(@(__PRETTY_FUNCTION__), @"exception", @"name=%@ reason=%@ userInfo=%@", ex.name, ex.reason, ex.userInfo);
    }
    %orig;
    LOG_STAGE("after %orig", "executeAction complete");
}

%end

%hook NCBulletinNotificationSource

- (void)dispatcher:(id)arg1 requestsClearingNotificationRequests:(__NSSetM*)requests {
    LOG_STAGE("start", "requests count=%lu", (unsigned long)[requests count]);
    @try {
        remainingNotificationsToProcess = [requests count];
        JBLog(@(__PRETTY_FUNCTION__), @"set remaining", @"Setting up to process %llu notifications", remainingNotificationsToProcess);
    } @catch (NSException *ex) {
        JBLog(@(__PRETTY_FUNCTION__), @"exception", @"name=%@ reason=%@ userInfo=%@", ex.name, ex.reason, ex.userInfo);
    }
    %orig;
    LOG_STAGE("after %orig", "dispatcher processed");
}

%end

static void hooked_dispatch_assert_queue(dispatch_queue_t queue) {
    LOG_STAGE("start", "queue=%p", queue);
    if (queue == dispatch_get_main_queue()) {
        LOG_STAGE("bypass", "main queue detected, returning early");
        return;
    }
    LOG_STAGE("forward", "calling original_dispatch_assert_queue=%p", original_dispatch_assert_queue);
    original_dispatch_assert_queue(queue);
}

%ctor {
    // Start logging as early as possible
    installCrashHandlers();
    NSSetUncaughtExceptionHandler(uncaught_exception_handler);

    NSString *osString = [[NSProcessInfo processInfo] operatingSystemVersionString];
    NSString *processName = [[NSProcessInfo processInfo] processName];
    JBLog(@"%ctor", @"startup", @"Process=%@ pid=%d iOS=%@", processName, getpid(), osString);

    // IMCore checks if its methods are being run in the main dispatch queue, so we have to force it to think it's running in there in order for our code to run in another thread.
    JBLog(@"%ctor", @"hooking", @"Hooking dispatch_assert_queue");
    MSHookFunction(dispatch_assert_queue, hooked_dispatch_assert_queue, (void**)&original_dispatch_assert_queue);
    JBLog(@"%ctor", @"hooked", @"original_dispatch_assert_queue=%p", original_dispatch_assert_queue);

    serialQueue = dispatch_queue_create("com.3h6-1.imread_queue", DISPATCH_QUEUE_SERIAL);
    JBLog(@"%ctor", @"queue", @"serialQueue created=%p", serialQueue);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        LOG_STAGE("bg setup", "refresh timer setup starting");
        // Chat ID can be anything. This is just to refresh the chat registry every so often so that it doesn't take like 15 sec to retrieve them when a message notif is cleared.
        void (^refresh)(NSTimer*) = ^(NSTimer* t) {
            LOG_STAGE("refresh tick", "timer=%@", t);
            performWhileConnectedToImagent(^{ [[%c(IMChatRegistry) sharedInstance] existingChatWithChatIdentifier:@"poop"]; });
        };
        refresh(nil);
        [NSTimer scheduledTimerWithTimeInterval:10800 repeats:YES block:refresh];
        LOG_STAGE("bg setup", "refresh timer scheduled");
    });
}

