#import <AppKit/AppKit.h>

extern NSString * const AntigravityBundleID;
NSString *AntigravityConversationID(NSString *taskID);
BOOL AntigravityMatchesConversationURL(NSURL *url, NSString *conversationID);
void OpenAntigravityConversation(NSRunningApplication *app, NSString *conversationID, void (^completion)(BOOL));
