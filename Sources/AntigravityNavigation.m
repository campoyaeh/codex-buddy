#import "AntigravityNavigation.h"
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

NSString * const AntigravityBundleID = @"com.google.antigravity";

NSString *AntigravityConversationID(NSString *taskID) {
    NSString *prefix = @"antigravity:";
    if (![taskID isKindOfClass:NSString.class] || ![taskID hasPrefix:prefix]) return nil;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:[taskID substringFromIndex:prefix.length]];
    return uuid.UUIDString.lowercaseString;
}

BOOL AntigravityMatchesConversationURL(NSURL *url, NSString *conversationID) {
    return conversationID.length && [url.scheme isEqualToString:@"https"] && [url.host isEqualToString:@"127.0.0.1"] &&
        url.port.integerValue > 0 && [url.path.lowercaseString isEqualToString:[@"/c/" stringByAppendingString:conversationID]];
}

static id AXValue(AXUIElementRef element, CFStringRef attribute) {
    if (!element) return nil;
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

static BOOL AXPress(AXUIElementRef element) {
    return element && AXUIElementPerformAction(element, kAXPressAction) == kAXErrorSuccess;
}

static BOOL AXHasRole(AXUIElementRef element, CFStringRef role) {
    return [AXValue(element,kAXRoleAttribute) isEqual:(__bridge NSString *)role];
}

static id FindInTree(id root, NSTimeInterval deadline, BOOL (^matches)(AXUIElementRef)) {
    if (!root) return nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger i=0; i<queue.count && i<950 && NSProcessInfo.processInfo.systemUptime < deadline; i++) {
        AXUIElementRef element = (__bridge AXUIElementRef)queue[i];
        if (matches(element)) return queue[i];
        NSArray *children = AXValue(element,kAXChildrenAttribute);
        if (children.count) [queue addObjectsFromArray:children];
    }
    return nil;
}

static BOOL ElementShowsConversation(AXUIElementRef element, NSString *conversationID, CFStringRef role) {
    if (!AXHasRole(element,role)) return NO;
    id value = AXValue(element,kAXURLAttribute);
    NSURL *url = [value isKindOfClass:NSURL.class] ? value : ([value isKindOfClass:NSString.class] ? [NSURL URLWithString:value] : nil);
    return AntigravityMatchesConversationURL(url,conversationID);
}

static id FocusedWindow(AXUIElementRef app) {
    return AXValue(app,kAXFocusedWindowAttribute) ?: AXValue(app,kAXMainWindowAttribute);
}

static BOOL HasLabel(AXUIElementRef element, NSArray<NSString *> *labels) {
    id title = AXValue(element,kAXTitleAttribute);
    id description = AXValue(element,kAXDescriptionAttribute);
    id placeholder = AXValue(element,kAXPlaceholderValueAttribute);
    return (title && [labels containsObject:title]) || (description && [labels containsObject:description]) ||
        (placeholder && [labels containsObject:placeholder]);
}

static BOOL IsConversationSearch(AXUIElementRef element) {
    return (AXHasRole(element,kAXComboBoxRole) || AXHasRole(element,kAXTextFieldRole)) &&
        HasLabel(element,@[@"Search for conversations...", @"搜索对话…", @"搜索对话..."]);
}

static BOOL IsSelectedResult(AXUIElementRef element, NSString *conversationID) {
    if (![AXValue(element,kAXSelectedAttribute) isEqual:@YES]) return NO;
    NSString *result = AXValue(element,kAXValueAttribute);
    if (![result isKindOfClass:NSString.class]) result = AXValue(element,kAXTitleAttribute);
    if (![result isKindOfClass:NSString.class] || !result.length) result = AXValue(element,kAXDescriptionAttribute);
    if (![result isKindOfClass:NSString.class]) return NO;
    for (NSString *part in [result componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if ([part.lowercaseString isEqualToString:conversationID]) return YES;
    }
    return NO;
}

static void SendKey(NSRunningApplication *app, CGKeyCode key, CGEventFlags flags, NSString *text) {
    for (int down=1; down>=0; down--) {
        CGEventRef event = CGEventCreateKeyboardEvent(NULL,key,down != 0);
        if (!event) continue;
        CGEventSetFlags(event,flags);
        if (text.length) {
            UniChar characters[36];
            [text getCharacters:characters range:NSMakeRange(0,text.length)];
            CGEventKeyboardSetUnicodeString(event,text.length,characters);
        }
        CGEventPostToPid(app.processIdentifier,event);
        CFRelease(event);
    }
}

static BOOL VerifyConversation(NSRunningApplication *app, AXUIElementRef accessibilityApp, NSString *conversationID, NSTimeInterval seconds) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + seconds;
    do {
        if (app.terminated || !app.active) return NO;
        if (FindInTree(FocusedWindow(accessibilityApp), deadline, ^BOOL(AXUIElementRef element) {
            return ElementShowsConversation(element,conversationID,CFSTR("AXWebArea"));
        })) return YES;
        [NSThread sleepForTimeInterval:0.08];
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    return NO;
}

static BOOL Navigate(NSRunningApplication *app, AXUIElementRef accessibilityApp, NSString *conversationID) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 5;
    id window;
    do {
        if (app.terminated) return NO;
        if (app.active) window = FocusedWindow(accessibilityApp);
        if (window) break;
        [NSThread sleepForTimeInterval:0.10];
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    if (!window) return NO;
    NSTimeInterval initialDeadline = NSProcessInfo.processInfo.systemUptime + 0.8;
    if (FindInTree(window,initialDeadline,^BOOL(AXUIElementRef element) {
        return ElementShowsConversation(element,conversationID,CFSTR("AXWebArea"));
    })) return YES;
    id link = FindInTree(window,NSProcessInfo.processInfo.systemUptime+0.9,^BOOL(AXUIElementRef element) {
        return ElementShowsConversation(element,conversationID,CFSTR("AXLink"));
    });
    if (app.active && AXPress((__bridge AXUIElementRef)link) && VerifyConversation(app,accessibilityApp,conversationID,1.4)) return YES;

    id searchButton = FindInTree(window,NSProcessInfo.processInfo.systemUptime+1.0,^BOOL(AXUIElementRef element) {
        return AXHasRole(element,kAXButtonRole) &&
            HasLabel(element,@[@"Search Conversations", @"Open Conversation Picker", @"搜索对话"]);
    });
    if (!app.active || !AXPress((__bridge AXUIElementRef)searchButton)) return NO;
    deadline = NSProcessInfo.processInfo.systemUptime + 2.5;
    id input = nil;
    while (app.active && !input && NSProcessInfo.processInfo.systemUptime < deadline) {
        input = FindInTree(window,deadline,^BOOL(AXUIElementRef element) { return IsConversationSearch(element); });
        if (!input) [NSThread sleepForTimeInterval:0.08];
    }
    AXUIElementRef field = (__bridge AXUIElementRef)input;
    id value = AXValue(field,kAXValueAttribute);
    if (!field || !app.active || ([value isKindOfClass:NSString.class] && [value length])) return NO;
    AXUIElementSetAttributeValue(field,kAXValueAttribute,(__bridge CFStringRef)conversationID);

    NSTimeInterval typedFallback = NSProcessInfo.processInfo.systemUptime + 0.45;
    deadline = typedFallback + 2.0;
    BOOL triedTyping = NO;
    while (app.active && NSProcessInfo.processInfo.systemUptime < deadline) {
        id query = AXValue(field,kAXValueAttribute);
        if ([query isEqual:conversationID]) {
            id focused = AXValue(accessibilityApp,kAXFocusedUIElementAttribute);
            id result = IsSelectedResult((__bridge AXUIElementRef)focused,conversationID) ? focused :
                FindInTree(window,MIN(deadline,NSProcessInfo.processInfo.systemUptime+0.4),^BOOL(AXUIElementRef element) {
                    return IsSelectedResult(element,conversationID);
                });
            if (result && app.active && (CFEqual((__bridge CFTypeRef)result,(__bridge CFTypeRef)(focused ?: input)) ||
                    [AXValue(field,kAXFocusedAttribute) isEqual:@YES])) {
                SendKey(app,kVK_Return,0,nil);
                return VerifyConversation(app,accessibilityApp,conversationID,2.5);
            }
        }
        if (!triedTyping && NSProcessInfo.processInfo.systemUptime >= typedFallback &&
                [AXValue(field,kAXFocusedAttribute) isEqual:@YES] &&
                ([query isEqual:conversationID] || ![query isKindOfClass:NSString.class] || ![query length])) {
            if ([query isEqual:conversationID]) SendKey(app,kVK_ANSI_A,kCGEventFlagMaskCommand,nil);
            SendKey(app,kVK_ANSI_A,0,conversationID);
            triedTyping = YES;
        }
        [NSThread sleepForTimeInterval:0.08];
    }
    return NO;
}

void OpenAntigravityConversation(NSRunningApplication *app, NSString *conversationID, void (^completion)(BOOL)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        BOOL opened = NO;
        if ([app.bundleIdentifier isEqualToString:AntigravityBundleID] &&
            [[NSUUID alloc] initWithUUIDString:conversationID] && AXIsProcessTrusted()) {
            AXUIElementRef accessibilityApp = AXUIElementCreateApplication(app.processIdentifier);
            AXUIElementSetMessagingTimeout(accessibilityApp,0.15);
            opened = Navigate(app,accessibilityApp,conversationID);
            CFRelease(accessibilityApp);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(opened); });
    });
}
