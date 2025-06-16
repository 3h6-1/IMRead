#import <Shared.h>
#import <UserNotifications/UserNotifications.h>
#import <Dispatch/Dispatch.h>

static unsigned long long remainingNotificationsToProcess;
static void (*original_dispatch_assert_queue)(dispatch_queue_t queue);

%hook NCNotificationMasterList

- (void)removeNotificationRequest:(NCNotificationRequest*)notif {
    if (remainingNotificationsToProcess) {
        if ([notif.sectionIdentifier isEqualToString:@"com.apple.MobileSMS"]) {
            // Fetching the IMChat may take a while, so we must do this in a new thread for each notif clear in order to avoid freezing the main thread.
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                NSDate* date = [NSDate date];
                if ([[%c(IMDaemonController) sharedController] connectToDaemon]) {
                    NSLog(@"Connected to imagent in %F ms", [date timeIntervalSinceNow] * -1000.0);
                    NSDictionary* userInfo = notif.context[@"userInfo"];
                    NSString* full_guid = userInfo[@"CKBBContextKeyMessageGUID"];
                    __NSCFString* chatId = userInfo[@"CKBBUserInfoKeyChatIdentifier"];
                    IMMessage* msg;
                    
                    NSLog(@"ChatIdentifier: %@", chatId);
                    IMChat* imchat = [[%c(IMChatRegistry) sharedInstance] existingChatWithChatIdentifier:chatId];
                    NSLog(@"IMChat: %@", imchat);
                    
                    // Sometimes these methods don't work on the first try, so we have to keep calling them until they do.
                    for (int x = 0; x < 4 && !msg; x++) {
                        [imchat loadMessagesUpToGUID:full_guid date:nil limit:0 loadImmediately:YES];
                        for (int i = 0; i < 500 && !msg; i++)
                            msg = [imchat messageForGUID:full_guid];
                    }
                    NSLog(@"Message: %@", msg);
                    [imchat markMessageAsRead:msg];
                } else
                    NSLog(@"Couldn't connect to daemon :(");
            });
        }
        remainingNotificationsToProcess--;
    }
    %orig;
}

%end

%hook IMDaemonController

/*
// allows SpringBoard to use methods from IMCore
- (unsigned)_capabilities {
    return 17159;
}
*/

// for iOS 16+
- (unsigned long long)processCapabilities {
    return 4485895;
}

%end

%hook NCBulletinActionRunner

- (void)executeAction:(NCNotificationAction*)action fromOrigin:(NSString*)origin endpoint:(BSServiceConnectionEndpoint*)endpoint withParameters:(id)params completion:(id)block {
    if ([action.identifier isEqualToString:UNNotificationDismissActionIdentifier])
        // Single notification clear
        remainingNotificationsToProcess = 1;
    %orig;
}

%end

%hook NCNotificationGroupList

// Called when clearing a stack via swipe
- (void)setClearingAllNotificationRequestsForCellHorizontalSwipe:(BOOL)clearing {
    if (clearing) {
        remainingNotificationsToProcess = self.notificationCount;
        NSLog(@"Setting up to process %llu notifications", remainingNotificationsToProcess);
    }
    %orig;
}

// Called when using clear button
- (void)clearAll {
    remainingNotificationsToProcess = self.notificationCount;
    NSLog(@"clearAll: Setting up to process %llu notifications", remainingNotificationsToProcess);
    %orig;
}

%end

static void hooked_dispatch_assert_queue(dispatch_queue_t queue) {
    if (queue == dispatch_get_main_queue())
        return;
    
    original_dispatch_assert_queue(queue);
}

%ctor {
    // IMCore checks if its methods are being run in the main dispatch queue, so we have to force it to think it's running in there in order for our code to run in another thread.
    MSHookFunction(dispatch_assert_queue, hooked_dispatch_assert_queue, &original_dispatch_assert_queue);
}
