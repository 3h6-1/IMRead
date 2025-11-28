#import <Shared.h>
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <Dispatch/Dispatch.h>
#include <stdio.h>
#include <sys/time.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <signal.h>
#include <execinfo.h>
#include <mach/mach.h>
#include <string.h>
#include <sys/utsname.h>
#include <stdlib.h>
#include <sys/ucontext.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <sys/stat.h>

// Unified accessors for arm64 vs arm64e opaque thread state fields
#if defined(__arm64__)
  #if defined(__arm64e__)
    // On arm64e SDKs, registers may be exposed as opaque fields
    #define REG_FP(ss) ((unsigned long long)(ss).__opaque_fp)
    #define REG_LR(ss) ((unsigned long long)(ss).__opaque_lr)
    #define REG_SP(ss) ((unsigned long long)(ss).__opaque_sp)
    #define REG_PC(ss) ((unsigned long long)(ss).__opaque_pc)
  #else
    // On arm64 (non-e), use the standard field names
    #define REG_FP(ss) ((unsigned long long)(ss).__fp)
    #define REG_LR(ss) ((unsigned long long)(ss).__lr)
    #define REG_SP(ss) ((unsigned long long)(ss).__sp)
    #define REG_PC(ss) ((unsigned long long)(ss).__pc)
  #endif
#endif

static unsigned long long remainingNotificationsToProcess = 0;
static void (*original_dispatch_assert_queue)(dispatch_queue_t queue);
static void (*original_dispatch_assert_queue_barrier)(dispatch_queue_t queue);
static dispatch_queue_t serialQueue;

static const char *kLogPath = "/var/jb/var/mobile/log.txt";
static volatile sig_atomic_t g_sigill_reporting = 0;
BOOL stopLogging = NO;
BOOL imcoreCallee = NO;

static void performWhileConnectedToImagent(dispatch_block_t imcoreBlock) {
    if ([[%c(IMDaemonController) sharedController] connectToDaemon])
        dispatch_async(serialQueue, imcoreBlock);
    else
        NSLog(@"Failed to connect to imagent :(");
}

%hook NCNotificationMasterList

- (void)removeNotificationRequest:(NCNotificationRequest*)notif {
    if (remainingNotificationsToProcess) {
        if ([notif.sectionIdentifier isEqualToString:@"com.apple.MobileSMS"]) {
            NSDictionary* userInfo = notif.context[@"userInfo"];
            NSString* full_guid = userInfo[@"CKBBContextKeyMessageGUID"];
            __NSCFString* chatId = userInfo[@"CKBBUserInfoKeyChatIdentifier"];
            
            NSLog(@"ChatIdentifier: %@", chatId);
            // Fetching the IMChat may take a while, so we must do this in another thread for every notif clear in order to avoid freezing the main thread.
            performWhileConnectedToImagent(^{
                IMMessage* msg = nil;
                NSDate* date = [NSDate date];
                imcoreCallee = YES;
                IMChat* imchat = [[%c(IMChatRegistry) sharedInstance] existingChatWithChatIdentifier:chatId];
                
                if (imchat)
                    NSLog(@"IMChat retrieved in %F ms: %@", [date timeIntervalSinceNow] * -1000.0, imchat);
                else {
                    NSLog(@"Failed to retrieve IMChat");
                    return;
                }
                
                // Sometimes these methods don't work on the first try, so we have to keep calling them until they do.
                for (int x = 0; x < 8 && !msg; x++) {
                    [imchat loadMessagesUpToGUID:full_guid date:nil limit:0 loadImmediately:YES];
                    for (int i = 0; i < 1000 && !msg; i++)
                        msg = [imchat messageForGUID:full_guid];
                }
                NSLog(@"Message: %@", msg);
                [imchat markMessageAsRead:msg];
                imcoreCallee = NO;
            });
        }
        remainingNotificationsToProcess--;
    }
    %orig;
}

%end

%hook IMDaemonController

// allows SpringBoard to use methods from IMCore
- (unsigned)_capabilities {
    %log;
    return 17159;
}

// for iOS 16+
- (unsigned long long)processCapabilities {
    %log;
    return 4485895;
}

%end

// These hooks are needed because sometimes removeNotificationRequest is called even when the user isn't explicitly clearing the notification.
%hook NCBulletinActionRunner

- (void)executeAction:(NCNotificationAction*)action fromOrigin:(NSString*)origin endpoint:(BSServiceConnectionEndpoint*)endpoint withParameters:(id)params completion:(id)block {
    %log;
    if ([action.identifier isEqualToString:UNNotificationDismissActionIdentifier])
        remainingNotificationsToProcess = 1;
    %orig;
}

%end

%hook NCBulletinNotificationSource

- (void)dispatcher:(id)arg1 requestsClearingNotificationRequests:(__NSSetM*)requests {
    %log;
    remainingNotificationsToProcess = [requests count];
    NSLog(@"Setting up to process %llu notifications", remainingNotificationsToProcess);
    %orig;
}

%end

static void hooked_dispatch_assert_queue(dispatch_queue_t queue) {
    if (imcoreCallee)
        return;
    original_dispatch_assert_queue(queue);
}

static void hooked_dispatch_assert_queue_barrier(dispatch_queue_t queue) {
    if (imcoreCallee)
        return;
    original_dispatch_assert_queue_barrier(queue);
}

static void signalHandler(int sig, siginfo_t *info, void *uap) {
    if (stopLogging || __sync_lock_test_and_set(&g_sigill_reporting, 1)) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    FILE* log = fopen(kLogPath, "w");
    if (log)
        fclose(log);
    int fd = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        char buf[256];
        int n;
        struct utsname systemInfo;
        uname(&systemInfo);
        const char *pname = getprogname();
        n = snprintf(buf, sizeof(buf), "Process=%s pid=%d OS=%s Model=%s\n",
                     pname ? pname : "(null)",
                     getpid(),
                     [[[NSProcessInfo processInfo] operatingSystemVersionString] UTF8String],
                     systemInfo.machine);
        if (n > 0)
            write(fd, buf, (size_t)n);

        uint32_t tid = pthread_mach_thread_np(pthread_self());
        n = snprintf(buf, sizeof(buf), "CRASH SIGNAL: %d code=%d addr=%p pid=%d tid=%u\n",
                         sig,
                         info ? info->si_code : 0,
                         info ? info->si_addr : NULL,
                         getpid(),
                         tid);
        if (n > 0)
            write(fd, buf, (size_t)n);

        ucontext_t *ctx = (ucontext_t *)uap;
        if (ctx && ctx->uc_mcontext) {
            const struct __darwin_arm_thread_state64 ss = ctx->uc_mcontext->__ss;
            // General purpose registers x0-x28
            for (int i = 0; i < 29; i++) {
                n = snprintf(buf, sizeof(buf), "x%-2d: 0x%016llx\n", i, (unsigned long long)ss.__x[i]);
                if (n > 0) write(fd, buf, (size_t)n);
            }
            n = snprintf(buf, sizeof(buf),
                         "fp : 0x%016llx\n"
                         "lr : 0x%016llx\n"
                         "sp : 0x%016llx\n"
                         "pc : 0x%016llx\n"
                         "cpsr: 0x%08x\n",
                         REG_FP(ss),
                         REG_LR(ss),
                         REG_SP(ss),
                         REG_PC(ss),
                         ss.__cpsr);
            if (n > 0) write(fd, buf, (size_t)n);

            // Attempt to resolve image/symbol for PC (not strictly async-signal-safe, but useful for diagnostics)
            Dl_info dli;
            if (dladdr((void *)(uintptr_t)REG_PC(ss), &dli)) {
                n = snprintf(buf, sizeof(buf), "pc image: %s symbol: %s\n",
                             dli.dli_fname ? dli.dli_fname : "(null)",
                             dli.dli_sname ? dli.dli_sname : "(null)");
                if (n > 0)
                    write(fd, buf, (size_t)n);
            }
            // Also log dyld image slide/base so you can undo ASLR in a disassembler
            {
                Dl_info d2;
                if (dladdr((void *)(uintptr_t)REG_PC(ss), &d2) && d2.dli_fbase) {
                    int imageCount = _dyld_image_count();
                    int foundIndex = -1;
                    for (int i = 0; i < imageCount; i++) {
                        const struct mach_header *hdr = _dyld_get_image_header(i);
                        if ((const void *)hdr == d2.dli_fbase) { foundIndex = i; break; }
                    }
                    if (foundIndex >= 0) {
                        intptr_t slide = _dyld_get_image_vmaddr_slide(foundIndex);
                        uintptr_t pc_val = (uintptr_t)REG_PC(ss);
                        uintptr_t unslid_pc = pc_val - (uintptr_t)slide; // vmaddr without ASLR slide
                        uintptr_t offset_from_base = pc_val - (uintptr_t)d2.dli_fbase; // offset into loaded image
                        n = snprintf(buf, sizeof(buf),
                                     "dyld image index: %d\n"
                                     "image: %s\n"
                                     "header(load addr): %p\n"
                                     "vmaddr slide: 0x%lx\n"
                                     "pc_unslid(vmaddr): 0x%016llx\n"
                                     "pc_offset_in_image: 0x%016llx\n",
                                     foundIndex,
                                     d2.dli_fname ? d2.dli_fname : "(null)",
                                     d2.dli_fbase,
                                     (unsigned long)slide,
                                     (unsigned long long)unslid_pc,
                                     (unsigned long long)offset_from_base);
                        if (n > 0) write(fd, buf, (size_t)n);
                    }
                }
            }
        }

        // Best-effort backtrace; may not be async-signal-safe but useful
        void *bt[64];
        int count = backtrace(bt, 64);
        if (count > 0) {
            write(fd, "backtrace:\n", 11);
            for (int i = 0; i < count; i++) {
                n = snprintf(buf, sizeof(buf), "%02d 0x%016llx\n", i, (unsigned long long)(uintptr_t)bt[i]);
                if (n > 0) write(fd, buf, (size_t)n);
            }
        }

        write(fd, "-- end of sigill report --\n", 28);
        close(fd);
    }
    g_sigill_reporting = 0;

    // Restore default and re-raise to preserve system crash handling if desired
    signal(sig, SIG_DFL);
    raise(sig);
    stopLogging = YES;
    // abort();
}

%ctor {
    struct sigaction sa;
    
    memset(&sa, 0, sizeof(sa));
    sigemptyset(&sa.sa_mask);
    sa.sa_sigaction = signalHandler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGQUIT, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
    sigaction(SIGKILL, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGPIPE, &sa, NULL);
    sigaction(SIGALRM, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    // IMCore checks if its methods are being run in the main dispatch queue, so we have to force it to think it's running in there in order for our code to run in another thread.
    MSHookFunction(dispatch_assert_queue, hooked_dispatch_assert_queue, (void**)&original_dispatch_assert_queue);
    MSHookFunction(dispatch_assert_queue_barrier, hooked_dispatch_assert_queue_barrier, (void**)&original_dispatch_assert_queue_barrier);
    serialQueue = dispatch_queue_create("com.3h6-1.imread_queue", DISPATCH_QUEUE_SERIAL);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        // Chat ID can be anything. This is just to refresh the chat registry every so often so that it doesn't take like 15 sec to retrieve them when a message notif is cleared.
        void (^refresh)(NSTimer*) = ^(NSTimer* t) { performWhileConnectedToImagent(^{
            imcoreCallee = YES;
            [[%c(IMChatRegistry) sharedInstance] existingChatWithChatIdentifier:@"poop"];
            imcoreCallee = NO;
        }); };
        refresh(nil);
        [NSTimer scheduledTimerWithTimeInterval:10800 repeats:YES block:refresh];
    });
}

