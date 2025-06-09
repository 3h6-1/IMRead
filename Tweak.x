#import <Shared.h>
#import <UserNotifications/UserNotifications.h>

static NSInteger remainingNotificationsToProcess = 0;
static BOOL isProcessingStack = NO;

%hook NCNotificationMasterList

- (void)removeNotificationRequest:(NCNotificationRequest*)notif {
    BOOL shouldProcess = NO;
    
    if ([notif.sectionIdentifier isEqualToString:@"com.apple.MobileSMS"] && (remainingNotificationsToProcess > 0 || isProcessingStack)) {
            shouldProcess = YES;
            if (remainingNotificationsToProcess > 0)
                remainingNotificationsToProcess--;
    }
    
    if (shouldProcess && [[%c(IMDaemonController) sharedController] connectToDaemon]) {
        NSDictionary* userInfo = notif.context[@"userInfo"];
        NSString* full_guid = userInfo[@"CKBBContextKeyMessageGUID"];
        __NSCFString* chatId = userInfo[@"CKBBUserInfoKeyChatIdentifier"];
        IMMessage* msg;
        
        NSLog(@"ChatIdentifier: %@", chatId);
        IMChat* imchat = [[%c(IMChatRegistry) sharedInstance] existingChatWithChatIdentifier:chatId];
        NSLog(@"IMChat: %@", imchat);
        
        for (int x = 0; x < 2 && !msg; x++) {
            // credit to libsmserver for this
            [imchat loadMessagesUpToGUID:full_guid date:nil limit:0 loadImmediately:YES];
            for (int i = 0; i < 1000 && !msg; i++)
                msg = [imchat messageForGUID:full_guid];
        }
        NSLog(@"Message: %@", msg);
        [imchat markMessageAsRead:msg];
    } else {
        NSLog(@"Couldn't connect to daemon :(");
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
    if (clearing && [[self sectionIdentifier] isEqualToString:@"com.apple.MobileSMS"]) {
        remainingNotificationsToProcess = self.notificationCount;
        NSLog(@"Setting up to process %lu notifications", (unsigned long)remainingNotificationsToProcess);
    }
    %orig;
}

// Called when using clear button
- (void)clearAll {
    if ([[self sectionIdentifier] isEqualToString:@"com.apple.MobileSMS"]) {
        remainingNotificationsToProcess = self.notificationCount;
        isProcessingStack = YES;
        NSLog(@"clearAll: Setting up to process %lu notifications", (unsigned long)remainingNotificationsToProcess);
    }
    %orig;
    isProcessingStack = NO;
}

%end
