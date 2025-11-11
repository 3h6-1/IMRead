#import <Shared.h>
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <Dispatch/Dispatch.h>

static unsigned long long remainingNotificationsToProcess = 0;
static dispatch_queue_t serialQueue;

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

// IMCore checks if its methods are being run in the main dispatch queue, so we have to force it to think it's running in there in order for our code to run in another thread. But hooking dispatch_assert_queue and calling %orig if it's not the main queue will SIGILL on 16.7. Since this function is mainly used for testing, I think it's best to just disable it entirely.
%hookf(void, dispatch_assert_queue, dispatch_queue_t queue) {}

%ctor {
    serialQueue = dispatch_queue_create("com.3h6-1.imread_queue", DISPATCH_QUEUE_SERIAL);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        // Chat ID can be anything. This is just to refresh the chat registry every so often so that it doesn't take like 15 sec to retrieve them when a message notif is cleared.
        void (^refresh)(NSTimer*) = ^(NSTimer* t) { performWhileConnectedToImagent(^{ [[%c(IMChatRegistry) sharedInstance] existingChatWithChatIdentifier:@"poop"]; }); };
        refresh(nil);
        [NSTimer scheduledTimerWithTimeInterval:10800 repeats:YES block:refresh];
    });
}
