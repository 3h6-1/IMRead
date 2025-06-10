#import <Shared.h>
#import <UserNotifications/UserNotifications.h>

unsigned long long remainingNotificationsToProcess;

%hook NCNotificationMasterList

- (void)removeNotificationRequest:(NCNotificationRequest*)notif {
    if (remainingNotificationsToProcess) {
        if ([notif.sectionIdentifier isEqualToString:@"com.apple.MobileSMS"]) {
            if ([[%c(IMDaemonController) sharedController] connectToDaemon]) {
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
        }
        remainingNotificationsToProcess--;
    }
    
    %orig;
}

%end

%hook IMDaemonController

// allows SpringBoard to use methods from IMCore
- (unsigned)_capabilities {
    return 17159;
}

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
