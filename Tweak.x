#import <Shared.h>
#import <UserNotifications/UserNotifications.h>
#import <Dispatch/Dispatch.h>

static unsigned long long remainingNotificationsToProcess = 0;
static void (*original_dispatch_assert_queue)(dispatch_queue_t queue);
static NCNotificationStructuredListViewController* notifController;
static dispatch_queue_t serialQueue;
// These let us do message lookup in O(1) time complexity.
NSMutableDictionary* chats, * msgs;

BOOL isMsgNotif(NCNotificationRequest* notif) {
    return [notif.sectionIdentifier isEqualToString:@"com.apple.MobileSMS"];
}

void performWhileConnectedToImagent(dispatch_block_t imcoreBlock) {
    if ([[%c(IMDaemonController) sharedController] connectToDaemon])
        dispatch_async(serialQueue, imcoreBlock);
    else
        NSLog(@"Failed to connect to imagent :(");
}

void updateDictionaries() {
    [chats removeAllObjects];
    [msgs removeAllObjects];
    // Loading the chats and messages may take a while, so we must do this in a separate serial queue in order to avoid freezing the main thread.
    performWhileConnectedToImagent(^{
        for (NCNotificationStructuredSectionList* section in [[notifController masterList] notificationSections])
            for (NCNotificationRequest* notif in [section allNotificationRequests])
                if (isMsgNotif(notif)) {
                    NSDictionary* userInfo = notif.context[@"userInfo"];
                    NSString* full_guid = userInfo[@"CKBBContextKeyMessageGUID"];
                    __NSCFString* chatId = userInfo[@"CKBBUserInfoKeyChatIdentifier"];
                    IMChat* imchat = [[%c(IMChatRegistry) sharedInstance] existingChatWithChatIdentifier:chatId];
                    IMMessage* msg = nil;
                    
                    [chats setValue:imchat forKey:chatId];
                    // Sometimes these methods don't work on the first try, so we have to keep calling them until they do.
                    for (int x = 0; x < 4 && !msg; x++) {
                        [imchat loadMessagesUpToGUID:full_guid date:nil limit:0 loadImmediately:YES];
                        for (int i = 0; i < 500 && !msg; i++)
                            msg = [imchat messageForGUID:full_guid];
                    }
                    if (msg)
                        [msgs setValue:msg forKey:full_guid];
                }
    });
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
        if (isMsgNotif(notif))
            performWhileConnectedToImagent(^{
                NSDictionary* userInfo = notif.context[@"userInfo"];
                [chats[userInfo[@"CKBBUserInfoKeyChatIdentifier"]] markMessageAsRead:msgs[userInfo[@"CKBBContextKeyMessageGUID"]]];
            });
        remainingNotificationsToProcess--;
    } else
        updateDictionaries();
}

- (void)insertNotificationRequest:(NCNotificationRequest*)notif {
    %orig;
    if (isMsgNotif(notif))
        updateDictionaries();
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
    }
    %orig;
}

// Called when using clear button
- (void)clearAll {
    remainingNotificationsToProcess = self.notificationCount;
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
    MSHookFunction(dispatch_assert_queue, hooked_dispatch_assert_queue, (void**)&original_dispatch_assert_queue);
    serialQueue = dispatch_queue_create("com.3h6-1.imread_queue", DISPATCH_QUEUE_SERIAL);
    chats = [NSMutableDictionary dictionary];
    msgs = [NSMutableDictionary dictionary];
}
