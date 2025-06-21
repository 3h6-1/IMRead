#import <Shared.h>
#import <UserNotifications/UserNotifications.h>
#import <Dispatch/Dispatch.h>

static unsigned long long remainingNotificationsToProcess = 0;
static void (*original_dispatch_assert_queue)(dispatch_queue_t queue);
static dispatch_queue_t serialQueue = dispatch_queue_create("com.3h6-1.imread_queue", DISPATCH_QUEUE_SERIAL);
static NCNotificationStructuredListViewController* notifController;
// This lets us lookup chats in O(1) time complexity.
static NSMutableDictionary* chats = [NSMutableDictionary dictionary];

BOOL isMsgNotif(NCNotificationRequest* notif) {
    return [notif.sectionIdentifier isEqualToString:@"com.apple.MobileSMS"];
}

void performWhileConnectedToImagent(dispatch_block_t imcoreBlock) {
    if ([[%c(IMDaemonController) sharedController] connectToDaemon])
        dispatch_async(serialQueue, imcoreBlock);
    else
        NSLog(@"Failed to connect to imagent :(");
}

void updateChatDictionary() {
    [chats removeAllObjects];
    for (NCNotificationStructuredSectionList* section in [[notifController masterList] notificationSections])
        for (NCNotificationRequest* notif in [section allNotificationRequests])
            if (isMsgNotif(notif))
                // Fetching the IMChat may take a while, so we must do this in a separate serial queue for each notif clear in order to avoid freezing the main thread.
                performWhileConnectedToImagent(^{
                    __NSCFString* chatId = notif.context[@"userInfo"][@"CKBBUserInfoKeyChatIdentifier"];
                    [chats setValue:[[%c(IMChatRegistry) sharedInstance] existingChatWithChatIdentifier:chatId] forKey:chatId];
                });
    NSLog(@"updateChatDictionary: chats = %@", chats);
}

%hook NCNotificationStructuredListViewController

- (id)init {
    self = %orig;
    notifController = self;
    return self;
}

%end

%hook NCNotificationMasterList

- (void)removeNotificationRequest:(NCNotificationRequest*)notif {
    %orig;
    if (remainingNotificationsToProcess) {
        if (isMsgNotif(notif)) {
            if ([[%c(IMDaemonController) sharedController] connectToDaemon]) {
                performWhileConnectedToImagent(^{
                    NSDictionary* userInfo = notif.context[@"userInfo"];
                    NSString* full_guid = userInfo[@"CKBBContextKeyMessageGUID"];
                    __NSCFString* chatId = userInfo[@"CKBBUserInfoKeyChatIdentifier"];
                    IMChat* imchat = chats[chatId];
                    IMMessage* msg = nil;
                    
                    NSLog(@"removeNotificationRequest: chats = %@", chats);
                    // Sometimes these methods don't work on the first try, so we have to keep calling them until they do.
                    for (int x = 0; x < 4 && !msg; x++) {
                        [imchat loadMessagesUpToGUID:full_guid date:nil limit:0 loadImmediately:YES];
                        for (int i = 0; i < 500 && !msg; i++)
                            msg = [imchat messageForGUID:full_guid];
                    }
                    NSLog(@"Message: %@", msg);
                    [imchat markMessageAsRead:msg];
                });
            } else
                NSLog(@"Failed to connect to imagent :(");
        }
        remainingNotificationsToProcess--;
    } else
        updateChatDictionary();
}

- (void)insertNotificationRequest:(NCNotificationRequest*)notif {
    %orig;
    updateChatDictionary();
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

// These hooks are needed because sometimes removeNotificationRequest is called even when the user isn't explicitly clearing the notification.
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
