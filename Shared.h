#import <Foundation/Foundation.h>

@interface NCNotificationAction : NSObject
@property (nonatomic, readonly, copy) NSString* identifier;
@end

@interface NCNotificationMasterList : NSObject
@property NSArray* notificationSections;
@end

@interface NCNotificationGroupList : NSObject
@property (nonatomic,readonly) unsigned long long notificationCount;
@end

@interface NCNotificationStructuredListViewController : NSObject
@property NCNotificationMasterList* masterList;
@end

@interface NCNotificationStructuredSectionList : NSObject
- (NSArray*)allNotificationRequests;
@end

@interface BSServiceConnectionEndpoint : NSObject
@end

@interface NCNotificationRequest : NSObject
@property (nonatomic, readonly, copy) NSDictionary* context;
@property NSString* sectionIdentifier; // eg. com.apple.MobileSMS
@end

@interface IMDaemonController : NSObject
+ (IMDaemonController*)sharedController;
- (BOOL)connectToDaemon;
@end

@interface IMMessage : NSObject
@end

@interface IMChat : NSObject
- (id)loadMessagesUpToGUID:(NSString*)arg1 date:(id)date limit:(unsigned long long)arg2 loadImmediately:(BOOL)loadImmediately;
- (IMMessage*)messageForGUID:(NSString*)guid;
- (void)markMessageAsRead:(IMMessage*)msg;
@end

@interface IMChatRegistry : NSObject
+ (IMChatRegistry*)sharedInstance;
- (IMChat*)existingChatWithChatIdentifier:(NSString*)chat_id;
@end

@interface __NSCFString : NSMutableString
@end

@interface __NSSetM : NSMutableSet
- (unsigned long long)count;
@end
