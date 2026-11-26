#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <sys/file.h>
#import <unistd.h>
#import <sqlite3.h>
#import "Celebration.h"
#import "PanelTheme.h"
#import "AntigravityNavigation.h"
#import "InputMirror.h"
#import "Updater.h"

static NSString *DataDirectory(void) { return NSProcessInfo.processInfo.environment[@"TASK_PANEL_DATA_DIR"] ?: [NSHomeDirectory() stringByAppendingPathComponent:@".codex/task-manager"]; }
static BOOL IsBuddyBundle(void) { return [NSBundle.mainBundle.bundleIdentifier isEqual:@"com.campoyaeh.codex-buddy"]; }
static NSString *PanelScriptsDirectory(void) {
    NSString *resources = NSBundle.mainBundle.resourcePath;
    if (resources.length && [NSFileManager.defaultManager fileExistsAtPath:[resources stringByAppendingPathComponent:@"task_monitor.py"]]) {
        return resources;
    }
    if (IsBuddyBundle()) return [NSHomeDirectory() stringByAppendingPathComponent:@".codex/bin"];
    return NSProcessInfo.processInfo.arguments.firstObject.stringByDeletingLastPathComponent;
}
static NSString *LaunchAgentLabel(void) { return @"com.openai.codex-task-complete-popup.watch"; }
static NSString *LaunchAgentPlistPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:[@"Library/LaunchAgents" stringByAppendingPathComponent:[LaunchAgentLabel() stringByAppendingPathExtension:@"plist"]]];
}
static BOOL IsLaunchAtLoginEnabled(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:LaunchAgentPlistPath()];
}
static BOOL SetLaunchAtLoginEnabled(BOOL enabled, NSError **errorOut) {
    NSString *plistPath = LaunchAgentPlistPath();
    NSString *domain = [NSString stringWithFormat:@"gui/%u", getuid()];
    NSString *service = [NSString stringWithFormat:@"%@/%@", domain, LaunchAgentLabel()];
    if (!enabled) {
        NSTask *bootout = [NSTask new];
        bootout.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
        bootout.arguments = @[@"bootout", service];
        bootout.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        bootout.standardError = NSFileHandle.fileHandleWithNullDevice;
        [bootout launchAndReturnError:NULL];
        [bootout waitUntilExit];
        if ([NSFileManager.defaultManager fileExistsAtPath:plistPath]) {
            return [NSFileManager.defaultManager removeItemAtPath:plistPath error:errorOut];
        }
        return YES;
    }
    NSString *agentsDir = plistPath.stringByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager createDirectoryAtPath:agentsDir withIntermediateDirectories:YES attributes:nil error:errorOut]) {
        return NO;
    }
    NSString *codexDir = [NSHomeDirectory() stringByAppendingPathComponent:@".codex"];
    [NSFileManager.defaultManager createDirectoryAtPath:codexDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *executable = NSBundle.mainBundle.executablePath ?: NSProcessInfo.processInfo.arguments.firstObject;
    NSString *logPath = [codexDir stringByAppendingPathComponent:@"task-complete-popup-watch.log"];
    NSDictionary *plist = @{
        @"Label": LaunchAgentLabel(),
        @"ProgramArguments": @[executable, @"--watch"],
        @"RunAtLoad": @YES,
        @"KeepAlive": @{@"SuccessfulExit": @NO},
        @"ProcessType": @"Interactive",
        @"LimitLoadToSessionType": @"Aqua",
        @"ThrottleInterval": @5,
        @"StandardOutPath": logPath,
        @"StandardErrorPath": logPath,
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:errorOut];
    if (!data || ![data writeToFile:plistPath options:NSDataWritingAtomic error:errorOut]) return NO;
    NSTask *bootstrap = [NSTask new];
    bootstrap.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    bootstrap.arguments = @[@"bootstrap", domain, plistPath];
    bootstrap.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    bootstrap.standardError = NSFileHandle.fileHandleWithNullDevice;
    [bootstrap launchAndReturnError:NULL];
    [bootstrap waitUntilExit];
    return YES;
}
static BOOL HasSystemPython3(void) {
    if (![NSFileManager.defaultManager isExecutableFileAtPath:@"/usr/bin/python3"]) return NO;
    NSTask *check = [NSTask new];
    check.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
    check.arguments = @[@"-p"];
    check.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    check.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![check launchAndReturnError:NULL]) return NO;
    [check waitUntilExit];
    return check.terminationStatus == 0;
}
static id ReadJSON(NSString *name) {
    NSData *data = [NSData dataWithContentsOfFile:[DataDirectory() stringByAppendingPathComponent:name]];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
}
@interface CenteredLabel : NSTextField
@end
@implementation CenteredLabel
- (void)drawRect:(NSRect)dirtyRect {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attributes = @{NSFontAttributeName:self.font, NSForegroundColorAttributeName:self.textColor, NSParagraphStyleAttributeName:style};
    CGFloat height = [self.stringValue sizeWithAttributes:attributes].height;
    [self.stringValue drawInRect:NSMakeRect(0,(self.bounds.size.height-height)/2,self.bounds.size.width,height) withAttributes:attributes];
}
@end
static NSTextField *Label(NSString *text, CGFloat size, NSColor *color) {
    NSTextField *field = [CenteredLabel labelWithString:text ?: @""];
    field.font = [NSFont systemFontOfSize:size];
    field.textColor = color;
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    return field;
}
static NSString *DismissalKey(NSDictionary *task) {
    NSString *turn = task[@"turn"] ?: @"";
    if ([task[@"status"] isEqual:@"completed"]) return [turn stringByAppendingString:@":completed"];
    if ([task[@"status"] isEqual:@"running"]) return [turn stringByAppendingString:@":running"];
    return turn;
}
static NSColor *StatusColor(NSString *status) {
    if ([status isEqual:@"waiting"]) return NSColor.systemYellowColor;
    if ([status isEqual:@"completed"]) return NSColor.systemBlueColor;
    return NSColor.systemGreenColor;
}
static PanelSurface *StatusDot(NSString *status, NSRect frame) {
    PanelSurface *dot = [[PanelSurface alloc] initWithFrame:frame];
    dot.fillColor = StatusColor(status);
    dot.layer.cornerRadius = frame.size.width / 2;
    dot.toolTip = [status isEqual:@"waiting"] ? @"待输入" : ([status isEqual:@"completed"] ? @"已完成" : @"进行中");
    return dot;
}
static void ApplyWaitingDotAnimation(PanelSurface *dot, NSAppearance *appearance) {
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) return;
    dot.wantsLayer = YES;
    dot.layer.masksToBounds = NO;
    dot.fillColor = NSColor.clearColor;
    CGFloat diameter = MIN(NSWidth(dot.bounds), NSHeight(dot.bounds));
    CGPoint center = CGPointMake(NSMidX(dot.bounds), NSMidY(dot.bounds));
    CGRect circle = CGRectMake(0, 0, diameter, diameter);
    NSColor *waitingColor = StatusColor(@"waiting");
    NSColor *amberColor = PanelColor(0xf5a623, 0xffd60a, 1.0);
    CFTimeInterval duration = 1.8;
    CFTimeInterval phase = fmod(CACurrentMediaTime(), duration);

    CALayer *halo = [CALayer layer];
    halo.bounds = circle;
    halo.position = center;
    halo.anchorPoint = CGPointMake(0.5, 0.5);
    halo.cornerRadius = diameter / 2;
    halo.opacity = 0;

    CALayer *core = [CALayer layer];
    core.bounds = circle;
    core.position = center;
    core.anchorPoint = CGPointMake(0.5, 0.5);
    core.cornerRadius = diameter / 2;
    core.shadowOffset = CGSizeZero;
    core.shadowRadius = 4.0;
    core.shadowOpacity = 0.65;

    [(appearance ?: dot.effectiveAppearance) performAsCurrentDrawingAppearance:^{
        halo.backgroundColor = amberColor.CGColor;
        core.backgroundColor = waitingColor.CGColor;
        core.shadowColor = amberColor.CGColor;
    }];

    CABasicAnimation *haloScale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    haloScale.fromValue = @1.0;
    haloScale.toValue = @2.45;
    CABasicAnimation *haloOpacity = [CABasicAnimation animationWithKeyPath:@"opacity"];
    haloOpacity.fromValue = @0.65;
    haloOpacity.toValue = @0.0;
    CAAnimationGroup *haloGroup = [CAAnimationGroup animation];
    haloGroup.animations = @[haloScale, haloOpacity];
    haloGroup.duration = duration;
    haloGroup.repeatCount = HUGE_VALF;
    haloGroup.removedOnCompletion = NO;
    haloGroup.timeOffset = phase;
    haloGroup.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.22f :1.0f :0.36f :1.0f];
    [halo addAnimation:haloGroup forKey:@"waitingHalo"];
    [dot.layer addSublayer:halo];

    CAMediaTimingFunction *ease = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    CAKeyframeAnimation *coreOpacity = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    coreOpacity.values = @[@1.0, @0.48, @1.0];
    coreOpacity.keyTimes = @[@0.0, @0.5, @1.0];
    coreOpacity.timingFunctions = @[ease, ease];
    CAKeyframeAnimation *coreScale = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    coreScale.values = @[@1.0, @1.14, @1.0];
    coreScale.keyTimes = @[@0.0, @0.5, @1.0];
    coreScale.timingFunctions = @[ease, ease];
    CAKeyframeAnimation *coreGlowRadius = [CAKeyframeAnimation animationWithKeyPath:@"shadowRadius"];
    coreGlowRadius.values = @[@2.0, @6.5, @2.0];
    coreGlowRadius.keyTimes = @[@0.0, @0.5, @1.0];
    coreGlowRadius.timingFunctions = @[ease, ease];
    CAKeyframeAnimation *coreGlowOpacity = [CAKeyframeAnimation animationWithKeyPath:@"shadowOpacity"];
    coreGlowOpacity.values = @[@0.25, @0.9, @0.25];
    coreGlowOpacity.keyTimes = @[@0.0, @0.5, @1.0];
    coreGlowOpacity.timingFunctions = @[ease, ease];
    CAAnimationGroup *coreGroup = [CAAnimationGroup animation];
    coreGroup.animations = @[coreOpacity, coreScale, coreGlowRadius, coreGlowOpacity];
    coreGroup.duration = duration;
    coreGroup.repeatCount = HUGE_VALF;
    coreGroup.removedOnCompletion = NO;
    coreGroup.timeOffset = phase;
    [core addAnimation:coreGroup forKey:@"waitingPulse"];
    [dot.layer addSublayer:core];
}
static void ApplyWaitingRowAnimation(PanelSurface *row, NSAppearance *appearance) {
    NSColor *amber = PanelColor(0xe5a000, 0xffd60a, 1.0);
    row.fillColor = [amber colorWithAlphaComponent:0.08];
    row.outlineColor = [amber colorWithAlphaComponent:0.28];
    row.layer.borderWidth = 0.75;
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) return;
    CFTimeInterval duration = 1.8;
    CFTimeInterval phase = fmod(CACurrentMediaTime(), duration);
    CAMediaTimingFunction *ease = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [(appearance ?: row.effectiveAppearance) performAsCurrentDrawingAppearance:^{
        id lowBg = (id)[amber colorWithAlphaComponent:0.05].CGColor;
        id highBg = (id)[amber colorWithAlphaComponent:0.155].CGColor;
        id lowBorder = (id)[amber colorWithAlphaComponent:0.14].CGColor;
        id highBorder = (id)[amber colorWithAlphaComponent:0.52].CGColor;
        CAKeyframeAnimation *bgPulse = [CAKeyframeAnimation animationWithKeyPath:@"backgroundColor"];
        bgPulse.values = @[lowBg, highBg, lowBg];
        bgPulse.keyTimes = @[@0.0, @0.5, @1.0];
        bgPulse.timingFunctions = @[ease, ease];
        CAKeyframeAnimation *borderPulse = [CAKeyframeAnimation animationWithKeyPath:@"borderColor"];
        borderPulse.values = @[lowBorder, highBorder, lowBorder];
        borderPulse.keyTimes = @[@0.0, @0.5, @1.0];
        borderPulse.timingFunctions = @[ease, ease];
        CAAnimationGroup *rowGroup = [CAAnimationGroup animation];
        rowGroup.animations = @[bgPulse, borderPulse];
        rowGroup.duration = duration;
        rowGroup.repeatCount = HUGE_VALF;
        rowGroup.removedOnCompletion = NO;
        rowGroup.timeOffset = phase;
        [row.layer addAnimation:rowGroup forKey:@"waitingRowPulse"];
    }];
}
static NSImage *SourceIcon(NSDictionary *task) {
    static NSCache<NSString *, NSImage *> *cache;
    if (!cache) cache = [NSCache new];
    NSString *provider = task[@"provider"] ?: @"";
    NSString *key = [NSString stringWithFormat:@"%@:%@:%@",provider,task[@"bundle_id"] ?: @"",task[@"app"] ?: @""];
    NSImage *cached = [cache objectForKey:key];
    if (cached) return cached;
    NSURL *application = nil;
    if ([provider isEqual:@"codex"])
        application = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:[NSURL URLWithString:@"codex://threads/"]];
    if (!application && [task[@"bundle_id"] length])
        application = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:task[@"bundle_id"]];
    if (!application && [task[@"app"] length]) {
        for (NSString *root in @[@"/Applications",[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]]) {
            NSString *path = [root stringByAppendingPathComponent:[task[@"app"] stringByAppendingPathExtension:@"app"]];
            if ([NSFileManager.defaultManager fileExistsAtPath:path]) { application = [NSURL fileURLWithPath:path]; break; }
        }
    }
    if (!application && ![provider isEqual:@"codex"]) {
        for (NSDictionary *source in ReadJSON(@"snapshot.json")[@"sources"]) {
            if (![source[@"id"] isEqual:provider]) continue;
            for (NSString *path in source[@"apps"]) {
                if ([NSFileManager.defaultManager fileExistsAtPath:path]) { application = [NSURL fileURLWithPath:path]; break; }
            }
            break;
        }
    }
    NSImage *icon = application ? [NSWorkspace.sharedWorkspace iconForFile:application.path] : nil;
    if (!icon) {
        BOOL terminal = [@[@"qwencode",@"gemini",@"copilot",@"opencode"] containsObject:provider];
        icon = [NSImage imageWithSystemSymbolName:terminal ? @"terminal" : @"app.dashed" accessibilityDescription:task[@"source"]];
    }
    if (icon && application) [cache setObject:icon forKey:key];
    return icon;
}
@interface TaskButton : NSButton
@property(copy) NSString *threadID;
@end
@implementation TaskButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    if (self.bordered) {
        NSColor *fill = self.highlighted ? PanelColor(0xdce3eb,0x4d4d4d,1) : PanelColor(0xe8edf4,0x383838,1);
        [fill setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:6 yRadius:6] fill];
    }
    if ([self.title isEqual:@"展开"] || [self.title isEqual:@"收起"]) {
        CGFloat direction = [self.title isEqual:@"展开"] ? 1 : -1;
        NSPoint center = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
        NSBezierPath *chevron = [NSBezierPath bezierPath];
        [chevron moveToPoint:NSMakePoint(center.x-3.5,center.y-direction*1.5)];
        [chevron lineToPoint:NSMakePoint(center.x,center.y+direction*2)];
        [chevron lineToPoint:NSMakePoint(center.x+3.5,center.y-direction*1.5)];
        chevron.lineWidth = 1.4;
        chevron.lineCapStyle = NSLineCapStyleRound;
        [NSColor.secondaryLabelColor setStroke];
        [chevron stroke];
        return;
    }
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = self.alignment;
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attributes = @{NSFontAttributeName:self.font ?: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName:self.contentTintColor ?: NSColor.labelColor, NSParagraphStyleAttributeName:style};
    CGFloat textHeight = [self.title sizeWithAttributes:attributes].height;
    [self.title drawInRect:NSMakeRect(3,(self.bounds.size.height-textHeight)/2,self.bounds.size.width-6,textHeight) withAttributes:attributes];
}
@end
@interface FlippedDocument : NSView
@end
@implementation FlippedDocument
- (BOOL)isFlipped { return YES; }
@end
@interface PanelScroller : NSScroller
@end
@implementation PanelScroller
+ (BOOL)isCompatibleWithOverlayScrollers { return self == PanelScroller.class; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)drawKnob {
    NSRect knob = [self rectForPart:NSScrollerKnob];
    if (!self.enabled || NSIsEmptyRect(knob)) return;
    CGFloat width = MIN(4, NSWidth(knob));
    knob = NSInsetRect(knob, (NSWidth(knob) - width) / 2, 0);
    BOOL highContrast = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast;
    [PanelColor(0x172131,0xffffff,highContrast ? 0.72 : 0.42) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:knob xRadius:width / 2 yRadius:width / 2] fill];
}
- (void)drawKnobSlotInRect:(NSRect)slot highlight:(BOOL)highlight {
    if (!self.enabled || NSIsEmptyRect(slot)) return;
    NSRect rail = NSMakeRect(NSMidX([self rectForPart:NSScrollerKnob]) - 1, NSMinY(slot), 2, NSHeight(slot));
    [PanelColor(0x172131,0xffffff,highlight ? 0.15 : 0.07) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rail xRadius:1 yRadius:1] fill];
}
@end

static NSScrollView *PanelScrollView(NSRect frame, CGFloat documentHeight) {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:frame];
    scroll.drawsBackground = NO;
    if (documentHeight > NSHeight(frame)) {
        PanelScroller *scroller = [[PanelScroller alloc] initWithFrame:NSMakeRect(0,0,12,NSHeight(frame))];
        scroller.controlSize = NSControlSizeSmall;
        scroll.verticalScroller = scroller;
        scroll.hasVerticalScroller = YES;
    }
    NSView *document = [[FlippedDocument alloc] initWithFrame:NSMakeRect(0,0,scroll.contentSize.width,documentHeight)];
    document.autoresizingMask = NSViewWidthSizable;
    scroll.documentView = document;
    return scroll;
}

@interface HoverPanelSurface : PanelSurface
@property(nonatomic, copy) void (^onMouseEntered)(void);
@property(nonatomic, copy) void (^onMouseExited)(void);
@end
@implementation HoverPanelSurface {
    NSTrackingArea *_hoverArea;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) [self removeTrackingArea:_hoverArea];
    _hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                              options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                owner:self
                                             userInfo:nil];
    [self addTrackingArea:_hoverArea];
}
- (void)mouseEntered:(NSEvent *)event {
    if (self.onMouseEntered) self.onMouseEntered();
}
- (void)mouseExited:(NSEvent *)event {
    if (self.onMouseExited) self.onMouseExited();
}
@end

@interface FloatingPanel : NSPanel
@property BOOL allowKeyWindow;
@end
@implementation FloatingPanel
- (BOOL)canBecomeKeyWindow { return self.allowKeyWindow; }
- (BOOL)canBecomeMainWindow { return NO; }
@end
@interface PanelController : NSObject <NSApplicationDelegate, NSWindowDelegate, NSSearchFieldDelegate>
@property(strong) FloatingPanel *panel;
@property(strong) CelebrationController *celebration;
@property(strong) InputMirrorController *inputMirror;
@property(strong) AppUpdater *updater;
@property(strong) NSStatusItem *statusItem;
@property(strong) NSTask *monitor;
@property(strong) NSTimer *timer;
@property(copy) NSArray *tasks;
@property(copy) NSArray *history;
@property BOOL showingHistory;
@property NSUInteger historyLimit;
@property(copy) NSString *historyQuery;
@property(strong) NSSearchField *historySearchField;
@property(copy) NSString *signature;
@property(strong) NSNumber *lastSnapshotInode;
@property(strong) NSNumber *lastSnapshotSize;
@property(strong) NSDate *lastDismissedMtime;
@property(copy) NSString *monitorError;
@property(copy) NSString *toastMessage;
@property BOOL toastIsError;
@property(strong) NSTimer *toastTimer;
@property BOOL collapsed;
@property BOOL preview;
@property BOOL launchedInteractively;
@property BOOL rebuilding;
@property BOOL animateResize;
@property BOOL completionPulse;
@property(strong) NSMutableSet *removingTasks;
@property(strong) NSMutableSet *openingTasks;
@property(strong) NSMutableSet *expandedTasks;
@property(strong) NSMutableDictionary *dismissed;
@property(strong) NSWindow *integrationsWindow;
@property(strong) NSTask *integrationSetup;
@property(copy) NSString *sourcesSignature;
@property(weak) NSButton *floatingVisibilityButton;
@property(weak) NSButton *launchAtLoginButton;
@property(weak) NSButton *accessibilityButton;
@property(weak) NSButton *integrationsAccessibilityButton;
@property(weak) NSButton *updateCheckButton;
@property BOOL navigatingAntigravity;
@property(copy) NSString *antigravityNotice;
@property BOOL antigravityNeedsPermission;
@property(strong) NSTimer *autoCollapseTimer;
@property BOOL pointerInsidePanel;
@property NSTimeInterval autoCollapseDelay;
@property NSTimeInterval hoverExitCollapseDelay;
@property EventHotKeyRef mirrorHotKeyRef;
@property EventHandlerRef mirrorHotKeyHandler;
- (void)refresh;
- (void)rebuild;
- (void)updateStatusItemVisibility;
- (BOOL)isAutoCollapseEnabled;
- (BOOL)isDoNotDisturbEnabled;
- (void)showToast:(NSString *)message isError:(BOOL)isError duration:(NSTimeInterval)duration;
- (void)panelPointerDidEnter;
- (void)panelPointerDidExit;
- (void)scheduleAutoCollapseTimer;
- (void)scheduleAutoCollapseAfterDelay:(NSTimeInterval)delay;
- (void)cancelAutoCollapseTimer;
- (void)toggleInputMirrorFromMenu:(id)sender;
@end

static OSStatus MirrorHotKeyCallback(EventHandlerCallRef nextHandler, EventRef theEvent, void *userData) {
    PanelController *controller = (__bridge PanelController *)userData;
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller toggleInputMirrorFromMenu:nil];
        BOOL enabled = [controller.celebration.settings[@"inputMirrorEnabled"] boolValue];
        [controller showToast:enabled ? @"已开启全局输入镜像（⌥⌘M）" : @"已关闭全局输入镜像（⌥⌘M）" isError:NO duration:2.2];
    });
    return noErr;
}
@implementation PanelController
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.removingTasks = [NSMutableSet set];
    self.openingTasks = [NSMutableSet set];
    self.expandedTasks = [NSMutableSet set];
    self.dismissed = [ReadJSON(@"dismissed.json") mutableCopy] ?: [NSMutableDictionary dictionary];
    self.collapsed = YES;
    self.historyLimit = 10;
    self.autoCollapseDelay = 10.0;
    self.hoverExitCollapseDelay = 1.0;
    self.celebration = [[CelebrationController alloc] initWithDirectory:DataDirectory()];
    [self.celebration applyTheme];
    self.inputMirror = [[InputMirrorController alloc] init];
    self.inputMirror.previewMode = self.preview;
    self.inputMirror.style = (InputMirrorStyle)[self.celebration.settings[@"inputMirrorStyle"] integerValue];
    self.inputMirror.excludeIDEs = [self.celebration.settings[@"inputMirrorExcludeIDEs"] boolValue];
    self.inputMirror.enabled = [self.celebration.settings[@"inputMirrorEnabled"] boolValue];
    self.updater = [[AppUpdater alloc] init];
    __weak PanelController *weakSelf = self;
    self.updater.onStatusChange = ^(NSString *status) {
        if (weakSelf.celebration.saveStatus) weakSelf.celebration.saveStatus.stringValue = status;
        if (weakSelf.updater.latestVersion.length && UpdaterCompareVersions(weakSelf.updater.latestVersion, UpdaterCurrentVersion()) == NSOrderedDescending) {
            weakSelf.updateCheckButton.title = [NSString stringWithFormat:@"更新至 v%@", weakSelf.updater.latestVersion];
            weakSelf.updateCheckButton.contentTintColor = NSColor.systemBlueColor;
        }
    };
    self.celebration.settingDidChange = ^(NSString *key) {
        if ([key isEqual:@"showStatusItem"]) [weakSelf updateStatusItemVisibility];
        if ([key isEqual:@"mascotID"] || [key isEqual:@"theme"] || [key isEqual:@"doNotDisturb"]) [weakSelf rebuild];
        if ([key isEqual:@"inputMirrorEnabled"]) [weakSelf applyInputMirrorSettingFromUser:YES];
        if ([key isEqual:@"inputMirrorExcludeIDEs"]) {
            weakSelf.inputMirror.excludeIDEs = [weakSelf.celebration.settings[@"inputMirrorExcludeIDEs"] boolValue];
        }
        if ([key isEqual:@"inputMirrorStyle"]) {
            weakSelf.inputMirror.style = (InputMirrorStyle)[weakSelf.celebration.settings[@"inputMirrorStyle"] integerValue];
            if (!weakSelf.preview) [weakSelf.inputMirror showPreviewSample];
        }
        if ([key isEqual:@"autoCollapsePanel"]) [weakSelf applyAutoCollapseSetting];
    };
    self.celebration.previewInputMirror = ^{
        [weakSelf.inputMirror showPreviewSample];
    };
    self.celebration.resetInputMirrorPosition = ^{
        [weakSelf.inputMirror resetSavedPosition];
        if (!weakSelf.preview) [weakSelf.inputMirror showPreviewSample];
        if (weakSelf.celebration.saveStatus) weakSelf.celebration.saveStatus.stringValue = @"输入镜像浮窗位置已重置";
    };
    self.panel = [[FloatingPanel alloc] initWithContentRect:NSMakeRect(0,0,360,80)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    self.panel.becomesKeyOnlyIfNeeded = YES;
    self.panel.delegate = self;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.opaque = NO;
    self.panel.hasShadow = YES;
    self.panel.hidesOnDeactivate = NO;
    self.panel.movableByWindowBackground = YES;
    self.panel.releasedWhenClosed = NO;
    [self updateStatusItemVisibility];
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"TaskPanelFrame"];
    if (!saved && IsBuddyBundle()) {
        saved = [NSUserDefaults.standardUserDefaults persistentDomainForName:@"codex-task-complete-popup"][@"TaskPanelFrame"];
    }
    NSRect frame = saved ? NSRectFromString(saved) : NSMakeRect(NSMaxX(screen)-380, NSMaxY(screen)-110,360,80);
    BOOL onScreen = NO;
    for (NSScreen *display in NSScreen.screens) if (NSIntersectsRect(display.visibleFrame, frame)) onScreen = YES;
    if (!onScreen) frame.origin = NSMakePoint(NSMaxX(screen)-380,NSMaxY(screen)-110);
    [self.panel setFrame:frame display:NO];
    if (!self.preview) {
        if (HasSystemPython3()) {
            [self startMonitor];
            NSString *integrationsPath = [DataDirectory() stringByAppendingPathComponent:@"integrations.json"];
            if (![NSFileManager.defaultManager fileExistsAtPath:integrationsPath]) {
                [self setupIntegrations:nil];
            }
        } else {
            self.monitorError = @"缺少 Python 3，请在终端运行 xcode-select --install";
        }
    }
    [self refresh];
    if (!self.preview) [self.panel orderFrontRegardless];
    if (self.launchedInteractively && !self.preview) {
        [self showMainPanel:nil];
        if (!HasSystemPython3()) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"需要安装 Python 3 运行环境";
            alert.informativeText = @"工头喵依赖系统 Python 3 来读取本地任务状态。请在「终端」运行：\n\nxcode-select --install\n\n安装完成后重新打开工头喵即可。";
            [alert addButtonWithTitle:@"好"];
            [alert runModal];
        }
    }
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screenChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    if (!self.preview) {
        [self registerMirrorHotKey];
        // Silent background update check at most once every 24 hours
        NSTimeInterval lastCheck = [NSUserDefaults.standardUserDefaults doubleForKey:@"LastUpdateCheckTime"];
        if (NSDate.date.timeIntervalSince1970 - lastCheck > 86400) {
            [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970 forKey:@"LastUpdateCheckTime"];
            [self.updater checkForUpdatesInteractive:NO completion:nil];
        }
    }
}
- (void)registerMirrorHotKey {
    EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
    EventHandlerRef handler = NULL;
    if (InstallApplicationEventHandler(&MirrorHotKeyCallback, 1, &spec, (__bridge void *)self, &handler) == noErr) {
        self.mirrorHotKeyHandler = handler;
        EventHotKeyID hotKeyID = { 'CBIM', 1 };
        EventHotKeyRef ref = NULL;
        // Option + Command + M
        if (RegisterEventHotKey(kVK_ANSI_M, cmdKey | optionKey, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr) {
            self.mirrorHotKeyRef = ref;
        }
    }
}
- (void)unregisterMirrorHotKey {
    if (self.mirrorHotKeyRef) {
        UnregisterEventHotKey(self.mirrorHotKeyRef);
        self.mirrorHotKeyRef = NULL;
    }
    if (self.mirrorHotKeyHandler) {
        RemoveEventHandler(self.mirrorHotKeyHandler);
        self.mirrorHotKeyHandler = NULL;
    }
}
- (void)startMonitor {
    NSString *directory = PanelScriptsDirectory();
    self.monitor = [[NSTask alloc] init];
    self.monitor.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
    self.monitor.arguments = @[[directory stringByAppendingPathComponent:@"task_monitor.py"], @"--parent", [NSString stringWithFormat:@"%d",getpid()]];
    NSError *error;
    if (![self.monitor launchAndReturnError:&error]) self.monitorError = error.localizedDescription;
}
- (void)refresh {
    if (self.integrationsWindow.visible) {
        [self updateIntegrations];
        [self updateAccessibilityButtons];
    }
    if (self.celebration.settingsWindow.visible) {
        [self applyInputMirrorSettingFromUser:NO];
        [self updateAccessibilityButtons];
    }
    if (self.preview || self.removingTasks.count) return;
    if (self.monitor && !self.monitor.running) [self startMonitor];
    NSString *snapshotPath = [DataDirectory() stringByAppendingPathComponent:@"snapshot.json"];
    NSString *dismissedPath = [DataDirectory() stringByAppendingPathComponent:@"dismissed.json"];
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:snapshotPath error:NULL];
    NSDictionary *dismissedAttrs = [NSFileManager.defaultManager attributesOfItemAtPath:dismissedPath error:NULL];
    BOOL snapshotStale = (!attrs || [attrs.fileModificationDate timeIntervalSinceNow] < -8);
    NSNumber *inode = attrs[NSFileSystemFileNumber];
    NSNumber *fileSize = attrs[NSFileSize];
    NSDate *dismissedMtime = dismissedAttrs.fileModificationDate;
    // Fast path: skip parsing large snapshot.json when only heartbeat mtime changed
    if (self.signature && !snapshotStale && !self.monitorError.length &&
        inode && [inode isEqual:self.lastSnapshotInode] &&
        fileSize && [fileSize isEqual:self.lastSnapshotSize] &&
        ((!dismissedMtime && !self.lastDismissedMtime) || [dismissedMtime isEqual:self.lastDismissedMtime])) {
        return;
    }
    self.lastSnapshotInode = inode;
    self.lastSnapshotSize = fileSize;
    self.lastDismissedMtime = dismissedMtime;
    NSDictionary *snapshot = ReadJSON(@"snapshot.json");
    NSArray *incoming = [snapshot[@"tasks"] isKindOfClass:NSArray.class] ? snapshot[@"tasks"] : @[];
    NSArray *history = [snapshot[@"history"] isKindOfClass:NSArray.class] ? snapshot[@"history"] : @[];
    NSMutableArray *tasks = [NSMutableArray array];
    for (NSDictionary *task in incoming) {
        BOOL active = [@[@"running", @"waiting", @"completed"] containsObject:task[@"status"]];
        BOOL dismissed = [self.dismissed[task[@"id"]] isEqual:DismissalKey(task)];
        if (!active || dismissed) continue;
        NSArray *rawSubs = [task[@"subtasks"] isKindOfClass:NSArray.class] ? task[@"subtasks"] : nil;
        if (rawSubs.count) {
            NSMutableArray *filteredSubs = [NSMutableArray array];
            for (NSDictionary *sub in rawSubs) {
                BOOL subActive = [@[@"running", @"waiting", @"completed"] containsObject:sub[@"status"]];
                BOOL subDismissed = [self.dismissed[sub[@"id"]] isEqual:DismissalKey(sub)];
                if (subActive && !subDismissed) [filteredSubs addObject:sub];
            }
            if (filteredSubs.count != rawSubs.count) {
                NSMutableDictionary *copy = [task mutableCopy];
                if (filteredSubs.count) copy[@"subtasks"] = filteredSubs;
                else [copy removeObjectForKey:@"subtasks"];
                [tasks addObject:copy];
                continue;
            }
        }
        [tasks addObject:task];
    }
    NSString *error = snapshot[@"error"] ?: @"";
    if (!snapshot || snapshotStale) error = @"正在连接任务状态…";
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[tasks,history,error] options:NSJSONWritingSortedKeys error:NULL];
    NSString *signature = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ([self.signature isEqual:signature]) return;
    self.completionPulse = NO;
    for (NSDictionary *task in tasks) {
        if (![task[@"status"] isEqual:@"completed"]) continue;
        BOOL alreadyCompleted = NO;
        for (NSDictionary *previous in self.tasks) {
            if ([previous[@"id"] isEqual:task[@"id"]] && [previous[@"turn"] isEqual:task[@"turn"]] && [previous[@"status"] isEqual:@"completed"]) alreadyCompleted = YES;
        }
        if (self.signature && !alreadyCompleted) self.completionPulse = YES;
    }
    BOOL hadTasks = self.tasks.count > 0;
    BOOL hasNewActivity = NO;
    for (NSDictionary *task in tasks) {
        BOOL known = NO;
        for (NSDictionary *previous in self.tasks) {
            if ([previous[@"id"] isEqual:task[@"id"]] && [previous[@"turn"] isEqual:task[@"turn"]] && [previous[@"status"] isEqual:task[@"status"]]) known = YES;
        }
        if (!known) hasNewActivity = YES;
    }
    BOOL dnd = [self isDoNotDisturbEnabled];
    BOOL autoCollapse = [self isAutoCollapseEnabled];
    if (autoCollapse) {
        if (!self.signature) {
            self.collapsed = YES;
        } else if (!tasks.count && !self.showingHistory) {
            self.collapsed = YES;
            [self cancelAutoCollapseTimer];
        } else if (hasNewActivity && !dnd) {
            self.collapsed = NO;
            [self scheduleAutoCollapseTimer];
        }
    } else {
        if (!tasks.count && !self.showingHistory) self.collapsed = YES;
        else if ((!hadTasks || hasNewActivity) && !dnd) self.collapsed = NO;
    }
    self.animateResize = self.signature != nil;
    self.signature = signature;
    self.tasks = tasks;
    self.history = history;
    self.monitorError = error;
    [self rebuild];
    if (self.completionPulse && !dnd) [self.celebration showOnScreen:self.panel.screen ?: NSScreen.mainScreen];
    self.animateResize = NO;
    self.completionPulse = NO;
}
- (void)updateStatusItemVisibility {
    if (![self.celebration.settings[@"showStatusItem"] boolValue]) {
        if (self.statusItem) {
            [NSStatusBar.systemStatusBar removeStatusItem:self.statusItem];
            self.statusItem = nil;
            // Keep the floating panel reachable when its menu-bar entry is removed.
            if (!self.preview) [self.panel orderFrontRegardless];
        }
        [self updateFloatingVisibilityButton];
        return;
    }
    if (self.statusItem) return;
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = MascotImage(self.celebration.settings[@"mascotID"],20);
    self.statusItem.button.imagePosition = NSImageLeft;
    self.statusItem.button.title = [NSString stringWithFormat:@" %lu", (unsigned long)self.tasks.count];
    self.statusItem.button.toolTip = @"点击进入主面板，右键显示菜单";
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusClicked:);
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp|NSEventMaskRightMouseUp];
    [self updateFloatingVisibilityButton];
}
- (NSMenu *)statusMenu {
    NSMenu *menu = [NSMenu new];
    [menu addItemWithTitle:@"进入主面板" action:@selector(showMainPanel:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *collapseItem = [menu addItemWithTitle:@"单屏自动收起" action:@selector(toggleAutoCollapseFromMenu:) keyEquivalent:@""];
    collapseItem.target = self;
    collapseItem.state = [self isAutoCollapseEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *mirrorItem = [menu addItemWithTitle:@"全局输入镜像（⌥⌘M）" action:@selector(toggleInputMirrorFromMenu:) keyEquivalent:@""];
    mirrorItem.target = self;
    mirrorItem.state = [self.celebration.settings[@"inputMirrorEnabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *dndItem = [menu addItemWithTitle:@"勿扰模式（暂停庆祝与弹出）" action:@selector(toggleDoNotDisturbFromMenu:) keyEquivalent:@""];
    dndItem.target = self;
    dndItem.state = [self isDoNotDisturbEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"检查更新…" action:@selector(checkForUpdates:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"退出应用" action:@selector(quitApplication:) keyEquivalent:@""].target = self;
    return menu;
}
- (BOOL)isDoNotDisturbEnabled {
    return [self.celebration.settings[@"doNotDisturb"] boolValue];
}
- (void)toggleDoNotDisturbFromMenu:(id)sender {
    BOOL next = ![self isDoNotDisturbEnabled];
    self.celebration.settings[@"doNotDisturb"] = @(next);
    [self.celebration saveChange:@"doNotDisturb"];
    [self showToast:next ? @"已开启勿扰模式（暂停庆祝与自动弹出）" : @"已关闭勿扰模式" isError:NO duration:2.4];
}
- (void)checkForUpdates:(id)sender {
    [self.updater checkForUpdatesInteractive:YES completion:nil];
}
- (void)showToast:(NSString *)message isError:(BOOL)isError duration:(NSTimeInterval)duration {
    [self.toastTimer invalidate];
    self.toastTimer = nil;
    self.toastMessage = message;
    self.toastIsError = isError;
    [self rebuild];
    if (duration > 0) {
        __weak PanelController *weakSelf = self;
        self.toastTimer = [NSTimer scheduledTimerWithTimeInterval:duration repeats:NO block:^(NSTimer *timer) {
            PanelController *owner = weakSelf;
            if (!owner) return;
            owner.toastMessage = nil;
            owner.toastIsError = NO;
            owner.toastTimer = nil;
            [owner rebuild];
        }];
    }
}
- (BOOL)isAutoCollapseEnabled {
    return [self.celebration.settings[@"autoCollapsePanel"] boolValue];
}
- (void)toggleAutoCollapseFromMenu:(id)sender {
    BOOL next = ![self isAutoCollapseEnabled];
    self.celebration.settings[@"autoCollapsePanel"] = @(next);
    self.celebration.autoCollapseCheckbox.state = next ? NSControlStateValueOn : NSControlStateValueOff;
    [self.celebration saveChange:@"autoCollapsePanel"];
}
- (void)applyAutoCollapseSetting {
    if (![self isAutoCollapseEnabled]) {
        [self cancelAutoCollapseTimer];
        return;
    }
    if (!self.pointerInsidePanel && !self.collapsed) {
        self.collapsed = YES;
        self.animateResize = !self.preview;
        [self rebuild];
        self.animateResize = NO;
    }
}
- (void)cancelAutoCollapseTimer {
    [self.autoCollapseTimer invalidate];
    self.autoCollapseTimer = nil;
}
- (void)scheduleAutoCollapseTimer {
    NSTimeInterval delay = self.autoCollapseDelay > 0 ? self.autoCollapseDelay : 10.0;
    [self scheduleAutoCollapseAfterDelay:delay];
}
- (void)scheduleAutoCollapseAfterDelay:(NSTimeInterval)delay {
    [self cancelAutoCollapseTimer];
    if (![self isAutoCollapseEnabled] || self.pointerInsidePanel || self.collapsed) return;
    __weak PanelController *weakSelf = self;
    self.autoCollapseTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        PanelController *owner = weakSelf;
        if (!owner || ![owner isAutoCollapseEnabled] || owner.pointerInsidePanel || owner.collapsed) return;
        owner.collapsed = YES;
        owner.animateResize = !owner.preview;
        [owner rebuild];
        owner.animateResize = NO;
    }];
    [NSRunLoop.mainRunLoop addTimer:self.autoCollapseTimer forMode:NSRunLoopCommonModes];
}
- (void)panelPointerDidEnter {
    self.pointerInsidePanel = YES;
    [self cancelAutoCollapseTimer];
    if ([self isAutoCollapseEnabled] && self.collapsed) {
        self.collapsed = NO;
        self.animateResize = !self.preview;
        [self rebuild];
        self.animateResize = NO;
    }
}
- (void)panelPointerDidExit {
    self.pointerInsidePanel = NO;
    if ([self isAutoCollapseEnabled] && !self.collapsed) {
        NSTimeInterval exitDelay = self.hoverExitCollapseDelay > 0 ? self.hoverExitCollapseDelay : 1.0;
        [self scheduleAutoCollapseAfterDelay:exitDelay];
    }
}
- (void)toggleInputMirrorFromMenu:(id)sender {
    BOOL next = ![self.celebration.settings[@"inputMirrorEnabled"] boolValue];
    self.celebration.settings[@"inputMirrorEnabled"] = @(next);
    self.celebration.inputMirrorCheckbox.state = next ? NSControlStateValueOn : NSControlStateValueOff;
    [self.celebration saveChange:@"inputMirrorEnabled"];
}
- (void)applyInputMirrorSettingFromUser:(BOOL)fromUser {
    BOOL enabled = [self.celebration.settings[@"inputMirrorEnabled"] boolValue];
    self.inputMirror.enabled = enabled;
    if (!enabled) {
        self.celebration.inputMirrorHint.stringValue = @"已关闭 · 开启后仅对已支持的 AI 应用输入框生效";
        return;
    }
    if (!self.preview && !AXIsProcessTrusted()) {
        if (fromUser) {
            NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
            AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
        }
        self.celebration.inputMirrorHint.stringValue = @"需在「系统设置 → 隐私与安全性 → 辅助功能」勾选工头喵后生效";
    } else {
        self.celebration.inputMirrorHint.stringValue = @"已开启 · 仅对已支持的 AI 应用输入框生效，支持跨屏拖动记忆";
    }
}
- (void)statusClicked:(id)sender {
    if (NSApp.currentEvent.type == NSEventTypeRightMouseUp) {
        [[self statusMenu] popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,self.statusItem.button.bounds.size.height) inView:self.statusItem.button];
        return;
    }
    [self showMainPanel:sender];
}
- (void)updateAccessibilityButtons {
    BOOL trusted = AXIsProcessTrusted();
    NSString *title = trusted ? @"辅助功能 · 已授权" : @"辅助功能 · 未授权";
    NSColor *tint = trusted ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
    if (self.accessibilityButton) {
        self.accessibilityButton.title = title;
        self.accessibilityButton.contentTintColor = tint;
    }
    if (self.integrationsAccessibilityButton) {
        self.integrationsAccessibilityButton.title = title;
        self.integrationsAccessibilityButton.contentTintColor = tint;
    }
}
- (void)addMainPanelActions {
    if (self.floatingVisibilityButton) return;
    NSView *root = self.celebration.settingsWindow.contentView;
    // Top-right persistent utility actions (visible across all tabs)
    // Add extra gap before "退出应用" and tint it red so users don't misclick quit.
    NSButton *integrations = [NSButton buttonWithTitle:@"兼容与接入" target:self action:@selector(showIntegrations:)];
    integrations.frame = NSMakeRect(442,508,100,28);
    [root addSubview:integrations];
    NSButton *history = [NSButton buttonWithTitle:@"历史对话" target:self action:@selector(showHistory:)];
    history.frame = NSMakeRect(548,508,86,28);
    [root addSubview:history];
    NSButton *quit = [NSButton buttonWithTitle:@"退出应用" target:self action:@selector(quitApplication:)];
    quit.frame = NSMakeRect(666,508,90,28);
    quit.contentTintColor = NSColor.systemRedColor;
    [root addSubview:quit];

    // Bottom-right version & update check (visible across all tabs)
    NSTextField *versionLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"v%@", UpdaterCurrentVersion()]];
    versionLabel.font = [NSFont systemFontOfSize:11.5];
    versionLabel.textColor = NSColor.tertiaryLabelColor;
    versionLabel.alignment = NSTextAlignmentRight;
    versionLabel.frame = NSMakeRect(548, 18, 96, 18);
    [root addSubview:versionLabel];
    NSButton *updateBtn = [NSButton buttonWithTitle:@"检查更新" target:self action:@selector(checkForUpdates:)];
    updateBtn.bezelStyle = NSBezelStyleRounded;
    updateBtn.controlSize = NSControlSizeSmall;
    updateBtn.frame = NSMakeRect(652, 15, 104, 24);
    [root addSubview:updateBtn];
    self.updateCheckButton = updateBtn;

    // Tab 0 (伙伴与外观) — Row 2 right: Floating task panel visibility
    NSButton *floating = [NSButton buttonWithTitle:@"显示任务浮窗" target:self action:@selector(toggleVisible:)];
    floating.frame = NSMakeRect(592,119,144,28);
    [root addSubview:floating];
    [self.celebration registerTabView:floating forTab:0];
    self.floatingVisibilityButton = floating;

    // Tab 0 (伙伴与外观) — Row 3 right: Launch at login + Accessibility permission
    NSButton *launchAtLogin = [NSButton checkboxWithTitle:@"登录时自动启动" target:self action:@selector(toggleLaunchAtLogin:)];
    launchAtLogin.frame = NSMakeRect(384,70,194,22);
    launchAtLogin.state = IsLaunchAtLoginEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    [root addSubview:launchAtLogin];
    [self.celebration registerTabView:launchAtLogin forTab:0];
    self.launchAtLoginButton = launchAtLogin;

    NSButton *antigravity = [NSButton buttonWithTitle:@"辅助功能授权" target:self action:@selector(requestAntigravityAccess:)];
    antigravity.toolTip = @"在系统设置中允许「工头喵」使用辅助功能（Antigravity 跳转与全局输入镜像）";
    antigravity.frame = NSMakeRect(592,67,144,28);
    [root addSubview:antigravity];
    [self.celebration registerTabView:antigravity forTab:0];
    self.accessibilityButton = antigravity;
    [self updateAccessibilityButtons];
}
- (void)toggleLaunchAtLogin:(NSButton *)sender {
    BOOL enable = sender.state == NSControlStateValueOn;
    NSError *error = nil;
    if (!SetLaunchAtLoginEnabled(enable, &error)) {
        sender.state = enable ? NSControlStateValueOff : NSControlStateValueOn;
        [self showToast:error.localizedDescription ?: @"更新登录自启动设置失败" isError:YES duration:3.0];
    }
}
- (void)showMainPanel:(id)sender {
    [self.celebration showSettings:sender];
    [self addMainPanelActions];
    [self updateFloatingVisibilityButton];
    [self updateAccessibilityButtons];
    [self applyInputMirrorSettingFromUser:NO];
}
- (void)quitApplication:(id)sender { [NSApp terminate:sender]; }
- (void)updateFloatingVisibilityButton {
    self.floatingVisibilityButton.title = self.panel.visible ? @"隐藏任务浮窗" : @"显示任务浮窗";
    self.floatingVisibilityButton.enabled = self.statusItem != nil || !self.panel.visible;
    self.floatingVisibilityButton.toolTip = self.floatingVisibilityButton.enabled ? nil : @"开启菜单栏入口后可隐藏浮窗";
}
- (void)toggleVisible:(id)sender {
    if (self.panel.visible && !self.statusItem) return;
    if (self.panel.visible) [self.panel orderOut:nil];
    else [self.panel orderFrontRegardless];
    [self updateFloatingVisibilityButton];
}
- (void)showHistory:(id)sender {
    [self showListWithHistory:YES];
    [self.panel orderFrontRegardless];
    [self updateFloatingVisibilityButton];
}
- (void)toggleCollapsed:(id)sender {
    self.collapsed = !self.collapsed;
    self.animateResize = YES;
    [self rebuild];
    self.animateResize = NO;
}
- (void)selectList:(NSButton *)sender {
    [self showListWithHistory:sender.tag == 1];
}
- (void)showListWithHistory:(BOOL)showHistory {
    self.showingHistory = showHistory;
    self.historyLimit = 10;
    if (!showHistory) {
        self.historyQuery = @"";
        self.historySearchField.stringValue = @"";
    }
    self.collapsed = NO;
    [self rebuild];
}
- (NSArray *)filteredHistory {
    NSString *q = [self.historyQuery stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if (!q.length) return self.history ?: @[];
    NSMutableArray *matches = [NSMutableArray array];
    for (NSDictionary *entry in self.history) {
        NSString *title = [entry[@"title"] isKindOfClass:NSString.class] ? [entry[@"title"] lowercaseString] : @"";
        NSString *project = [entry[@"project"] isKindOfClass:NSString.class] ? [entry[@"project"] lowercaseString] : @"";
        NSString *source = [entry[@"source"] isKindOfClass:NSString.class] ? [entry[@"source"] lowercaseString] : @"";
        NSString *provider = [entry[@"provider"] isKindOfClass:NSString.class] ? [entry[@"provider"] lowercaseString] : @"";
        BOOL matched = ([title containsString:q] || [project containsString:q] || [source containsString:q] || [provider containsString:q]);
        if (!matched && [entry[@"subtasks"] isKindOfClass:NSArray.class]) {
            for (NSDictionary *sub in entry[@"subtasks"]) {
                NSString *st = [sub[@"title"] isKindOfClass:NSString.class] ? [sub[@"title"] lowercaseString] : @"";
                NSString *sp = [sub[@"project"] isKindOfClass:NSString.class] ? [sub[@"project"] lowercaseString] : @"";
                NSString *ss = [sub[@"source"] isKindOfClass:NSString.class] ? [sub[@"source"] lowercaseString] : @"";
                NSString *sv = [sub[@"provider"] isKindOfClass:NSString.class] ? [sub[@"provider"] lowercaseString] : @"";
                if ([st containsString:q] || [sp containsString:q] || [ss containsString:q] || [sv containsString:q]) {
                    matched = YES;
                    break;
                }
            }
        }
        if (matched) [matches addObject:entry];
    }
    return matches;
}
- (NSDictionary *)findTaskByID:(NSString *)threadID inList:(NSArray *)list {
    if (!threadID.length) return nil;
    for (NSDictionary *entry in list) {
        if ([entry[@"id"] isEqual:threadID]) return entry;
        NSArray *subs = [entry[@"subtasks"] isKindOfClass:NSArray.class] ? entry[@"subtasks"] : nil;
        for (NSDictionary *sub in subs) {
            if ([sub[@"id"] isEqual:threadID]) return sub;
        }
    }
    return nil;
}
- (void)toggleSubtasks:(TaskButton *)sender {
    NSString *threadID = sender.threadID;
    if (!threadID.length) return;
    if ([self.expandedTasks containsObject:threadID]) [self.expandedTasks removeObject:threadID];
    else [self.expandedTasks addObject:threadID];
    self.animateResize = YES;
    [self rebuild];
    self.animateResize = NO;
}
- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object == self.historySearchField) {
        self.historyQuery = self.historySearchField.stringValue ?: @"";
        self.historyLimit = 10;
        [self rebuild];
    }
}
- (void)loadMoreHistory:(id)sender {
    self.historyLimit += 10;
    [self rebuild];
}
- (void)showNavigationError:(NSString *)message {
    [self showToast:message isError:YES duration:3.0];
}

- (void)showAntigravityNotice:(NSString *)message permission:(BOOL)permission {
    self.antigravityNotice = message;
    self.antigravityNeedsPermission = permission;
    [self rebuild];
}

- (void)dismissAntigravityNotice:(id)sender {
    if (self.antigravityNeedsPermission) {
        self.celebration.settings[@"suppressAntigravityPermissionPrompt"] = @YES;
        [self.celebration saveChange:@"suppressAntigravityPermissionPrompt"];
    }
    self.antigravityNotice = nil;
    self.antigravityNeedsPermission = NO;
    [self rebuild];
}

- (void)requestAntigravityAccess:(id)sender {
    if ([self.celebration.settings[@"suppressAntigravityPermissionPrompt"] boolValue]) {
        self.celebration.settings[@"suppressAntigravityPermissionPrompt"] = @NO;
        [self.celebration saveChange:@"suppressAntigravityPermissionPrompt"];
    }
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    if (!trusted) [self showAntigravityNotice:@"请在系统设置中开启「工头喵」，再点击任务。" permission:YES];
    NSURL *accessibility = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [NSWorkspace.sharedWorkspace openURL:accessibility];
}

- (void)copyAntigravitySearchID:(NSString *)conversationID permission:(BOOL)permission rebuild:(BOOL)shouldRebuild {
    NSPasteboard *clipboard = NSPasteboard.generalPasteboard;
    [clipboard clearContents];
    BOOL copied = [clipboard setString:conversationID forType:NSPasteboardTypeString];
    if (copied && permission && [self.celebration.settings[@"suppressAntigravityPermissionPrompt"] boolValue]) {
        self.antigravityNotice = nil;
        self.antigravityNeedsPermission = NO;
        if (shouldRebuild) [self rebuild];
        return;
    }
    NSString *message = @"无法复制会话 ID，请重试。";
    if (copied) {
        message = permission ? @"「工头喵」尚未授权。已复制会话 ID，按 ⌘K 粘贴搜索。" :
            @"已复制会话 ID，在 Antigravity 按 ⌘K 粘贴搜索。";
    }
    self.antigravityNotice = message;
    self.antigravityNeedsPermission = permission;
    if (shouldRebuild) [self rebuild];
}

- (void)openAntigravityTask:(NSDictionary *)task row:(NSView *)row {
    if (self.navigatingAntigravity) return;
    NSString *conversationID = AntigravityConversationID(task[@"navigation_id"]) ?: AntigravityConversationID(task[@"id"]);
    if (!conversationID) {
        [self showAntigravityNotice:@"这条 Antigravity 记录缺少有效的会话 ID。" permission:NO];
        return;
    }
    NSURL *application = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:AntigravityBundleID];
    if (!application) {
        [self showAntigravityNotice:@"未找到 Antigravity 桌面应用。" permission:NO];
        return;
    }
    self.antigravityNotice = nil;
    self.antigravityNeedsPermission = NO;
    self.navigatingAntigravity = YES;
    [self.openingTasks addObject:task[@"id"]];
    void (^finish)(void) = ^{
        self.navigatingAntigravity = NO;
        [self.openingTasks removeObject:task[@"id"]];
    };
    [NSWorkspace.sharedWorkspace openApplicationAtURL:application configuration:NSWorkspaceOpenConfiguration.configuration
        completionHandler:^(NSRunningApplication *app, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!app || error) {
                    finish();
                    [self showAntigravityNotice:@"打开 Antigravity 失败，请重试。" permission:NO];
                    return;
                }
                if (!AXIsProcessTrusted()) {
                    finish();
                    [self copyAntigravitySearchID:conversationID permission:YES rebuild:NO];
                    [self finishOpeningTask:task row:row opened:YES];
                    if (!self.removingTasks.count) [self rebuild];
                    return;
                }
                OpenAntigravityConversation(app,conversationID,^(BOOL opened) {
                    finish();
                    if (!opened) [self copyAntigravitySearchID:conversationID permission:!AXIsProcessTrusted() rebuild:NO];
                    [self finishOpeningTask:task row:row opened:YES];
                    if (!self.removingTasks.count) [self rebuild];
                });
            });
        }];
}
- (void)openTask:(TaskButton *)sender {
    if ([self.removingTasks containsObject:sender.threadID] || [self.openingTasks containsObject:sender.threadID]) return;
    NSDictionary *task = [self findTaskByID:sender.threadID inList:self.showingHistory ? self.history : self.tasks];
    if (!task) return;
    [self.inputMirror suppressAutoPopupUntilNextClick];
    if (!self.preview && [task[@"provider"] isEqual:@"antigravity"]) {
        [self openAntigravityTask:task row:sender.superview];
        return;
    }
    NSString *link = task[@"open_url"];
    if (!task[@"provider"]) link = [@"codex://threads/" stringByAppendingString:sender.threadID];
    BOOL opened = self.preview;
    if (!self.preview && [task[@"provider"] isEqual:@"qianwen"] && [task[@"navigation"] isEqual:@"session"]) {
        NSURL *url = [NSURL URLWithString:link ?: @""];
        NSURL *application = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.alibaba.tongyi"];
        if (!application || ![url.scheme isEqual:@"https"] || ![url.host isEqual:@"www.qianwen.com"] ||
            ![url.path isEqual:@"/chat/workbench"]) {
            [self finishOpeningTask:task row:sender.superview opened:NO];
            return;
        }
        [self.openingTasks addObject:sender.threadID];
        [NSWorkspace.sharedWorkspace openURLs:@[url] withApplicationAtURL:application
            configuration:NSWorkspaceOpenConfiguration.configuration completionHandler:^(NSRunningApplication *app, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self finishOpeningTask:task row:sender.superview opened:app != nil && error == nil];
                });
            }];
        return;
    }
    if (!self.preview && link.length) {
        NSURL *url = [NSURL URLWithString:link];
        if (url) opened = [NSWorkspace.sharedWorkspace openURL:url];
    } else if (!self.preview) {
        NSURL *application = task[@"bundle_id"] ? [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:task[@"bundle_id"]] : nil;
        NSString *app = task[@"app"];
        if (!application && app.length) {
            for (NSString *root in @[@"/Applications",[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]]) {
                NSString *path = [root stringByAppendingPathComponent:[app stringByAppendingPathExtension:@"app"]];
                if ([NSFileManager.defaultManager fileExistsAtPath:path]) { application = [NSURL fileURLWithPath:path]; break; }
            }
        }
        if (application) {
            [self.openingTasks addObject:sender.threadID];
            [NSWorkspace.sharedWorkspace openApplicationAtURL:application configuration:NSWorkspaceOpenConfiguration.configuration completionHandler:^(NSRunningApplication *app, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self finishOpeningTask:task row:sender.superview opened:app != nil && error == nil];
                });
            }];
            return;
        } else if ([task[@"resume_command"] length]) {
            NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
            [pasteboard clearContents];
            [pasteboard setString:task[@"resume_command"] forType:NSPasteboardTypeString];
            [self showToast:@"已复制会话恢复命令，请粘贴到终端运行" isError:NO duration:2.8];
            [self finishOpeningTask:task row:sender.superview opened:YES];
            return;
        }
    }
    [self finishOpeningTask:task row:sender.superview opened:opened];
}
- (void)finishOpeningTask:(NSDictionary *)task row:(NSView *)row opened:(BOOL)opened {
    [self.openingTasks removeObject:task[@"id"]];
    if (!opened) {
        [self showNavigationError:@"打开聊天失败，请重试"];
        return;
    }
    if ([task[@"status"] isEqual:@"running"]) return;
    // A successful jump acknowledges this panel's reminder, including app-only
    // navigation. A later turn or status must survive a delayed launch callback.
    NSDictionary *current = [self findTaskByID:task[@"id"] inList:self.tasks];
    if (current && [current[@"turn"] isEqual:task[@"turn"]] && [current[@"status"] isEqual:task[@"status"]]) {
        [self dismissEntry:current row:row];
        return;
    }
}
- (void)markTaskRead:(NSMenuItem *)sender {
    NSDictionary *task = [self findTaskByID:sender.representedObject inList:self.tasks];
    if (task) [self dismissEntry:task row:nil allowRunning:YES];
}
- (void)copyResume:(NSMenuItem *)sender {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:sender.representedObject forType:NSPasteboardTypeString];
    [self showToast:@"已复制会话恢复命令" isError:NO duration:2.2];
}
- (void)showIntegrations:(id)sender {
    if (!self.integrationsWindow) {
        self.integrationsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,720,650)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.integrationsWindow.title = @"工头喵 · 兼容与接入";
        self.integrationsWindow.releasedWhenClosed = NO;
        [self.integrationsWindow center];
    }
    self.sourcesSignature = nil;
    [self updateIntegrations];
    [self.integrationsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
static NSInteger SourceSortRank(NSDictionary *source) {
    NSString *state = source[@"state"] ?: @"";
    if ([@[@"已连接", @"已收到任务"] containsObject:state]) return 0;
    if ([state hasPrefix:@"已配置"] || [source[@"error"] length] || [source[@"setup_error"] length]) return 1;
    if ([state hasPrefix:@"已安装"]) return 2;
    if ([state isEqual:@"已屏蔽"]) return 3;
    return 4;
}
- (void)toggleHideUninstalledSources:(NSButton *)sender {
    self.celebration.settings[@"hideUninstalledSources"] = @(sender.state == NSControlStateValueOn);
    [self.celebration saveChange:@"hideUninstalledSources"];
    self.sourcesSignature = nil;
    [self updateIntegrations];
}
- (void)toggleProviderEnabled:(NSButton *)sender {
    NSString *providerID = sender.identifier;
    if (!providerID.length) return;
    NSMutableArray *disabled = [NSMutableArray arrayWithArray:[self.celebration.settings[@"disabledProviders"] isKindOfClass:NSArray.class] ? self.celebration.settings[@"disabledProviders"] : @[]];
    BOOL enabled = sender.state == NSControlStateValueOn;
    if (enabled) [disabled removeObject:providerID];
    else if (![disabled containsObject:providerID]) [disabled addObject:providerID];
    self.celebration.settings[@"disabledProviders"] = disabled;
    [self.celebration saveChange:@"disabledProviders"];
    self.sourcesSignature = nil;
    [self updateIntegrations];
}
- (void)updateIntegrations {
    NSDictionary *snapshot = ReadJSON(@"snapshot.json");
    NSArray *rawSources = snapshot[@"sources"] ?: @[];
    BOOL hideUninstalled = [self.celebration.settings[@"hideUninstalledSources"] boolValue];
    NSArray *disabledList = [self.celebration.settings[@"disabledProviders"] isKindOfClass:NSArray.class] ? self.celebration.settings[@"disabledProviders"] : @[];
    NSString *signature = [NSString stringWithFormat:@"%@|%d|%@", [rawSources description], hideUninstalled, [disabledList description]];
    if ([signature isEqual:self.sourcesSignature]) return;
    self.sourcesSignature = signature;

    NSInteger activeCount = 0;
    for (NSDictionary *source in rawSources) {
        NSString *st = source[@"state"] ?: @"";
        if ([@[@"已连接", @"已收到任务"] containsObject:st] || [st hasPrefix:@"已配置"]) activeCount++;
    }
    NSArray *sortedSources = [rawSources sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger ra = SourceSortRank(a), rb = SourceSortRank(b);
        if (ra != rb) return ra < rb ? NSOrderedAscending : NSOrderedDescending;
        return [(a[@"name"] ?: @"") compare:(b[@"name"] ?: @"")];
    }];
    NSMutableArray *sources = [NSMutableArray array];
    for (NSDictionary *source in sortedSources) {
        if (hideUninstalled && [source[@"state"] isEqual:@"未检测到客户端"]) continue;
        [sources addObject:source];
    }

    PanelSurface *root = [[PanelSurface alloc] initWithFrame:NSMakeRect(0,0,720,650)];
    root.fillColor = PanelColor(0xf7f8fb,0x171a1f,1);
    self.integrationsWindow.contentView = root;
    NSTextField *title = Label(@"让不同 AI 助手的任务汇集到同一个浮窗",18,NSColor.labelColor);
    title.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    title.frame = NSMakeRect(22,602,520,28); [root addSubview:title];
    NSButton *hideToggle = [NSButton checkboxWithTitle:@"隐藏未安装客户端" target:self action:@selector(toggleHideUninstalledSources:)];
    hideToggle.frame = NSMakeRect(558,604,142,22);
    hideToggle.state = hideUninstalled ? NSControlStateValueOn : NSControlStateValueOff;
    [root addSubview:hideToggle];
    NSString *summary = [NSString stringWithFormat:@"已接入 %ld / %lu 款助手 · 配置事件接入后，请在对应客户端开启新会话（取消勾选可屏蔽该端任务）。", (long)activeCount, (unsigned long)rawSources.count];
    NSTextField *help = Label(summary,11,NSColor.secondaryLabelColor);
    help.frame = NSMakeRect(22,575,676,24); [root addSubview:help];
    NSScrollView *scroll = PanelScrollView(NSMakeRect(18,124,684,440), MAX(440,sources.count*38));
    NSView *document = scroll.documentView;
    [root addSubview:scroll];
    NSInteger index = 0;
    for (NSDictionary *source in sources) {
        CGFloat y = (index++) * 38;
        NSString *providerID = source[@"id"] ?: @"";
        BOOL isDisabled = [disabledList containsObject:providerID] || [source[@"disabled"] boolValue];
        NSButton *toggle = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleProviderEnabled:)];
        toggle.identifier = providerID;
        toggle.state = isDisabled ? NSControlStateValueOff : NSControlStateValueOn;
        toggle.toolTip = isDisabled ? @"已屏蔽该客户端的任务提醒，勾选以恢复" : @"取消勾选可单独屏蔽该客户端的任务提醒";
        toggle.frame = NSMakeRect(4,y+9,20,20);
        [document addSubview:toggle];
        BOOL connected = [@[@"已连接",@"已收到任务"] containsObject:source[@"state"]];
        NSColor *color = isDisabled ? NSColor.tertiaryLabelColor : ([source[@"error"] length] || [source[@"setup_error"] length] ? NSColor.systemOrangeColor : (connected ? NSColor.systemGreenColor : ([source[@"state"] hasPrefix:@"已配置"] ? NSColor.systemBlueColor : NSColor.secondaryLabelColor)));
        NSTextField *name = Label(source[@"name"],12,isDisabled ? NSColor.tertiaryLabelColor : NSColor.labelColor);
        name.frame = NSMakeRect(28,y,204,38); [document addSubview:name];
        NSString *displayState = isDisabled ? @"已屏蔽" : (source[@"state"] ?: @"");
        NSTextField *state = Label(displayState,11,color);
        state.frame = NSMakeRect(236,y,252,38);
        state.toolTip = [NSString stringWithFormat:@"%@\n%@\n%@",source[@"detail"] ?: @"",source[@"error"] ?: @"",source[@"setup_error"] ?: @""];
        [document addSubview:state];
        NSTextField *mode = Label(source[@"mode"],11,NSColor.tertiaryLabelColor);
        mode.frame = NSMakeRect(490,y,174,38); [document addSubview:mode];
    }
    NSTextField *note = Label(@"Antigravity 自动跳转与全局输入镜像需要在系统设置中允许「工头喵」使用辅助功能。临时签名版更新后可能需重新授权。",11,NSColor.secondaryLabelColor);
    note.frame = NSMakeRect(22,89,676,25); [root addSubview:note];
    NSButton *setup = [NSButton buttonWithTitle:self.integrationSetup.running ? @"正在接入…" : @"接入已安装客户端" target:self action:@selector(setupIntegrations:)];
    setup.frame = NSMakeRect(22,35,168,32); setup.enabled = !self.integrationSetup.running; [root addSubview:setup];
    NSButton *antigravity = [NSButton buttonWithTitle:@"辅助功能授权" target:self action:@selector(requestAntigravityAccess:)];
    antigravity.frame = NSMakeRect(198,35,170,32); [root addSubview:antigravity];
    self.integrationsAccessibilityButton = antigravity;
    [self updateAccessibilityButtons];
    NSButton *remove = [NSButton buttonWithTitle:@"移除接入配置" target:self action:@selector(removeIntegrations:)];
    remove.frame = NSMakeRect(376,35,130,32); remove.enabled = !self.integrationSetup.running;
    remove.toolTip = @"仅移除工头喵添加的观察事件，保留客户端原有配置";
    [root addSubview:remove];
    NSButton *refresh = [NSButton buttonWithTitle:@"刷新" target:self action:@selector(refreshIntegrations:)];
    refresh.frame = NSMakeRect(608,35,88,32); [root addSubview:refresh];
}
- (void)refreshIntegrations:(id)sender { self.sourcesSignature = nil; [self updateIntegrations]; }
- (void)runIntegrationScriptWithArgs:(NSArray<NSString *> *)extraArgs {
    if (self.integrationSetup.running) return;
    NSString *directory = PanelScriptsDirectory();
    NSMutableArray *arguments = [NSMutableArray arrayWithObjects:[directory stringByAppendingPathComponent:@"integrations.py"], @"--data-dir", DataDirectory(), nil];
    if (extraArgs.count) [arguments addObjectsFromArray:extraArgs];
    self.integrationSetup = [NSTask new];
    self.integrationSetup.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
    self.integrationSetup.arguments = arguments;
    self.integrationSetup.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    self.integrationSetup.standardError = NSFileHandle.fileHandleWithNullDevice;
    __weak PanelController *weakSelf = self;
    self.integrationSetup.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.sourcesSignature = nil; [weakSelf updateIntegrations]; });
    };
    NSError *error = nil;
    if (![self.integrationSetup launchAndReturnError:&error]) {
        self.monitorError = @"接入程序启动失败，请检查 Python 3 是否已安装";
        [self rebuild];
    }
    self.sourcesSignature = nil; [self updateIntegrations];
}
- (void)setupIntegrations:(id)sender { [self runIntegrationScriptWithArgs:nil]; }
- (void)removeIntegrations:(id)sender { [self runIntegrationScriptWithArgs:@[@"--remove"]]; }
- (void)dismissEntry:(NSDictionary *)task row:(NSView *)row {
    [self dismissEntry:task row:row allowRunning:NO];
}
- (void)dismissEntry:(NSDictionary *)task row:(NSView *)row allowRunning:(BOOL)allowRunning {
    if ((!allowRunning && [task[@"status"] isEqual:@"running"]) || [self.removingTasks containsObject:task[@"id"]]) return;
    NSString *threadID = task[@"id"];
    NSMutableDictionary *dismissed = [ReadJSON(@"dismissed.json") mutableCopy] ?: [NSMutableDictionary dictionary];
    dismissed[threadID] = DismissalKey(task);
    NSArray *childTasks = [task[@"subtasks"] isKindOfClass:NSArray.class] ? task[@"subtasks"] : nil;
    for (NSDictionary *sub in childTasks) {
        if (allowRunning || ![sub[@"status"] isEqual:@"running"]) {
            dismissed[sub[@"id"]] = DismissalKey(sub);
        }
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:dismissed options:0 error:NULL];
    NSError *error;
    if (![data writeToFile:[DataDirectory() stringByAppendingPathComponent:@"dismissed.json"] options:NSDataWritingAtomic error:&error]) {
        [self showToast:@"保存跳转状态失败，请重试" isError:YES duration:3.0];
        return;
    }
    self.dismissed = dismissed;
    [self.removingTasks addObject:threadID];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.2;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        row.animator.alphaValue = 0;
        [row.animator setFrame:NSOffsetRect(row.frame, 18, 0)];
    } completionHandler:^{
        NSMutableArray *remaining = [NSMutableArray array];
        for (NSDictionary *entry in self.tasks) {
            if ([entry[@"id"] isEqual:threadID] && [DismissalKey(entry) isEqual:DismissalKey(task)]) {
                continue;
            }
            NSArray *subs = [entry[@"subtasks"] isKindOfClass:NSArray.class] ? entry[@"subtasks"] : nil;
            if (subs.count) {
                NSMutableArray *keptSubs = [NSMutableArray array];
                for (NSDictionary *sub in subs) {
                    if ([sub[@"id"] isEqual:threadID] && [DismissalKey(sub) isEqual:DismissalKey(task)]) continue;
                    [keptSubs addObject:sub];
                }
                if (keptSubs.count != subs.count) {
                    NSMutableDictionary *copy = [entry mutableCopy];
                    if (keptSubs.count) copy[@"subtasks"] = keptSubs;
                    else [copy removeObjectForKey:@"subtasks"];
                    [remaining addObject:copy];
                    continue;
                }
            }
            [remaining addObject:entry];
        }
        self.tasks = remaining;
        if (!remaining.count && !self.showingHistory) self.collapsed = YES;
        [self.removingTasks removeObject:threadID];
        self.animateResize = YES;
        [self rebuild];
        self.animateResize = NO;
    }];
}
- (void)windowDidMove:(NSNotification *)notification {
    if (!self.rebuilding && !self.preview) [[NSUserDefaults standardUserDefaults] setObject:NSStringFromRect(self.panel.frame) forKey:@"TaskPanelFrame"];
}
- (void)screenChanged:(NSNotification *)notification { [self.celebration stop]; [self rebuild]; }
- (void)rebuild {
    self.tasks = [self.tasks filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *task, NSDictionary *bindings) {
        return [@[@"running", @"waiting", @"completed"] containsObject:task[@"status"]];
    }]];
    NSInteger waiting = 0;
    for (NSDictionary *task in self.tasks) {
        if ([task[@"status"] isEqual:@"waiting"]) waiting++;
        NSArray *subs = [task[@"subtasks"] isKindOfClass:NSArray.class] ? task[@"subtasks"] : nil;
        for (NSDictionary *sub in subs) {
            if ([sub[@"status"] isEqual:@"waiting"]) waiting++;
        }
    }
    self.statusItem.button.image = MascotImage(self.celebration.settings[@"mascotID"],20);
    self.statusItem.button.imagePosition = NSImageLeft;
    BOOL dnd = [self isDoNotDisturbEnabled];
    self.statusItem.button.title = dnd
        ? [NSString stringWithFormat:@" 🌙 %lu", (unsigned long)self.tasks.count]
        : [NSString stringWithFormat:@" %lu", (unsigned long)self.tasks.count];
    NSString *roleName = MascotDefinition(self.celebration.settings[@"mascotID"])[@"name"];
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"%@%@\n点击进入主面板，右键显示菜单",roleName, dnd ? @"（勿扰中）" : @""];
    NSScreen *screen = self.panel.screen ?: NSScreen.mainScreen;
    NSArray *historyPool = self.showingHistory ? [self filteredHistory] : @[];
    NSArray *displayed = self.showingHistory ? [historyPool subarrayWithRange:NSMakeRange(0,MIN(self.historyLimit,historyPool.count))] : self.tasks;
    BOOL hasMore = self.showingHistory && historyPool.count > displayed.count;
    CGFloat width = self.collapsed ? 206 : 360;
    CGFloat rowsHeight = 0;
    for (NSDictionary *task in displayed) {
        rowsHeight += 38;
        NSArray *subs = [task[@"subtasks"] isKindOfClass:NSArray.class] ? task[@"subtasks"] : nil;
        if (subs.count && [self.expandedTasks containsObject:task[@"id"]]) {
            rowsHeight += subs.count * 32 + 2;
        }
    }
    if (hasMore) rowsHeight += 32;
    CGFloat searchHeight = (!self.collapsed && self.showingHistory) ? 32 : 0;
    CGFloat toastHeight = (!self.collapsed && self.toastMessage.length) ? 34 : 0;
    CGFloat noticeHeight = self.antigravityNotice.length ? 48 : 0;
    CGFloat bottomInset = toastHeight + noticeHeight;
    CGFloat listHeight = MIN(rowsHeight, MIN(380, screen.visibleFrame.size.height - 100 - bottomInset - searchHeight));
    CGFloat height = self.collapsed ? 40 : 50 + searchHeight + bottomInset + (displayed.count ? listHeight : 30);
    self.panel.allowKeyWindow = (!self.collapsed && self.showingHistory);
    BOOL keepSearchFocus = (self.historySearchField && self.panel.firstResponder == self.historySearchField.currentEditor);
    NSRect old = self.panel.frame;
    NSRect frame = NSMakeRect(NSMaxX(old)-width, NSMaxY(old)-height, width, height);
    frame.origin.x = MIN(MAX(frame.origin.x, NSMinX(screen.visibleFrame)+8), NSMaxX(screen.visibleFrame)-width-8);
    frame.origin.y = MIN(MAX(frame.origin.y, NSMinY(screen.visibleFrame)+8), NSMaxY(screen.visibleFrame)-height-8);
    self.rebuilding = YES;
    [self.panel setFrame:frame display:YES animate:self.animateResize];
    self.rebuilding = NO;
    HoverPanelSurface *root = [[HoverPanelSurface alloc] initWithFrame:NSMakeRect(0,0,width,height)];
    __weak PanelController *weakHover = self;
    root.onMouseEntered = ^{ [weakHover panelPointerDidEnter]; };
    root.onMouseExited = ^{ [weakHover panelPointerDidExit]; };
    root.fillColor = PanelColor(0xf8faff,0x1a1c21,0.98);
    root.layer.cornerRadius = self.collapsed ? 20 : 16;
    root.layer.masksToBounds = YES;
    root.layer.borderWidth = 0.5;
    root.outlineColor = [NSColor.separatorColor colorWithAlphaComponent:0.5];
    CGFloat previousScroll = 0;
    for (NSView *view in self.panel.contentView.subviews) if ([view isKindOfClass:NSScrollView.class]) previousScroll = ((NSScrollView *)view).contentView.bounds.origin.y;
    NSMenu *panelMenu = [NSMenu new];
    [panelMenu addItemWithTitle:@"进入主面板" action:@selector(showMainPanel:) keyEquivalent:@""].target = self;
    NSMenuItem *themesItem = [panelMenu addItemWithTitle:@"界面主题" action:NULL keyEquivalent:@""];
    NSMenu *themes = [[NSMenu alloc] initWithTitle:themesItem.title];
    NSArray<NSString *> *themeTitles = PanelThemeTitles();
    for (NSInteger index = 0; index < (NSInteger)themeTitles.count; index++) {
        NSMenuItem *item = [themes addItemWithTitle:themeTitles[index] action:@selector(changeTheme:) keyEquivalent:@""];
        item.target = self.celebration;
        item.tag = index;
        item.state = index == [self.celebration.settings[@"theme"] integerValue] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    themesItem.submenu = themes;
    [panelMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *collapseMenuItem = [panelMenu addItemWithTitle:@"单屏自动收起" action:@selector(toggleAutoCollapseFromMenu:) keyEquivalent:@""];
    collapseMenuItem.target = self;
    collapseMenuItem.state = [self isAutoCollapseEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *mirrorMenuItem = [panelMenu addItemWithTitle:@"全局输入镜像（⌥⌘M）" action:@selector(toggleInputMirrorFromMenu:) keyEquivalent:@""];
    mirrorMenuItem.target = self;
    mirrorMenuItem.state = [self.celebration.settings[@"inputMirrorEnabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *dndMenuItem = [panelMenu addItemWithTitle:@"勿扰模式" action:@selector(toggleDoNotDisturbFromMenu:) keyEquivalent:@""];
    dndMenuItem.target = self;
    dndMenuItem.state = dnd ? NSControlStateValueOn : NSControlStateValueOff;
    [panelMenu addItem:[NSMenuItem separatorItem]];
    if (self.statusItem) {
        [panelMenu addItemWithTitle:@"隐藏任务浮窗" action:@selector(toggleVisible:) keyEquivalent:@""].target = self;
    }
    [panelMenu addItemWithTitle:@"退出应用" action:@selector(quitApplication:) keyEquivalent:@""].target = self;
    root.menu = panelMenu;
    self.panel.contentView = root;
    NSString *summaryStatus = waiting ? @"waiting" : @"running";
    BOOL allCompleted = self.tasks.count > 0;
    for (NSDictionary *task in self.tasks) if (![task[@"status"] isEqual:@"completed"]) allCompleted = NO;
    if (allCompleted) summaryStatus = @"completed";
    NSString *heading = self.collapsed && self.tasks.count
        ? [NSString stringWithFormat:@"%@ · %lu",roleName,(unsigned long)self.tasks.count] : roleName;
    if (self.collapsed && dnd) heading = [heading stringByAppendingString:@" · 勿扰"];
    NSTextField *title = Label(heading, self.collapsed ? 12 : 14, NSColor.labelColor);
    title.font = [NSFont systemFontOfSize:self.collapsed ? 12 : 14 weight:NSFontWeightSemibold];
    title.frame = self.collapsed ? NSMakeRect(46,0,width-88,height) : NSMakeRect(48,height-36,156,24);
    title.toolTip = roleName;
    [root addSubview:title];
    MascotAvatarView *mascot = [[MascotAvatarView alloc] initWithFrame:self.collapsed ? NSMakeRect(8,4,32,32) : NSMakeRect(12,height-39,30,30)];
    mascot.mascotID = self.celebration.settings[@"mascotID"];
    mascot.state = allCompleted ? @"completed" : summaryStatus;
    mascot.toolTip = title.toolTip;
    mascot.accessibilityElement = YES; mascot.accessibilityLabel = title.toolTip;
    [root addSubview:mascot];
    if (self.collapsed) {
        PanelSurface *dot = StatusDot(summaryStatus, NSMakeRect(33,7,6,6));
        if (!self.tasks.count) dot.fillColor = NSColor.tertiaryLabelColor;
        [root addSubview:dot];
        if (self.tasks.count && [summaryStatus isEqual:@"waiting"]) {
            ApplyWaitingDotAnimation(dot, self.panel.effectiveAppearance);
        }
    }
    TaskButton *collapse = [TaskButton buttonWithTitle:self.collapsed ? @"展开" : @"收起" target:self action:@selector(toggleCollapsed:)];
    collapse.bordered = NO;
    collapse.frame = NSMakeRect(width-38,height-(self.collapsed ? 32 : 36),26,24);
    collapse.toolTip = self.collapsed ? @"展开任务" : @"收起任务";
    collapse.accessibilityLabel = collapse.toolTip;
    [root addSubview:collapse];
    if (self.completionPulse && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        self.statusItem.button.wantsLayer = YES;
        CABasicAnimation *bounce = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        bounce.fromValue = @1;
        bounce.toValue = @1.16;
        bounce.duration = 0.22;
        bounce.autoreverses = YES;
        bounce.repeatCount = 2;
        [self.statusItem.button.layer addAnimation:bounce forKey:@"taskCompleted"];
    }
    if (self.collapsed) return;
    if (noticeHeight) {
        NSTextField *notice = [NSTextField wrappingLabelWithString:self.antigravityNotice];
        notice.font = [NSFont systemFontOfSize:12];
        notice.textColor = NSColor.secondaryLabelColor;
        notice.frame = NSMakeRect(16,8,width - (self.antigravityNeedsPermission ? 118 : 50),34);
        [root addSubview:notice];
        if (self.antigravityNeedsPermission) {
            NSButton *authorize = [TaskButton buttonWithTitle:@"去授权" target:self action:@selector(requestAntigravityAccess:)];
            authorize.frame = NSMakeRect(width-96,12,62,26);
            [root addSubview:authorize];
        }
        TaskButton *dismiss = [TaskButton buttonWithTitle:@"×" target:self action:@selector(dismissAntigravityNotice:)];
        dismiss.bordered = NO;
        dismiss.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
        dismiss.contentTintColor = NSColor.secondaryLabelColor;
        dismiss.accessibilityLabel = @"关闭提示";
        dismiss.toolTip = self.antigravityNeedsPermission ? @"关闭并不再提示授权" : @"关闭提示";
        dismiss.frame = NSMakeRect(width-30,13,22,24);
        [root addSubview:dismiss];
    }
    if (toastHeight) {
        PanelSurface *toastBar = [[PanelSurface alloc] initWithFrame:NSMakeRect(10, 8 + noticeHeight, width - 20, 26)];
        NSColor *accent = self.toastIsError ? NSColor.systemOrangeColor : NSColor.systemBlueColor;
        toastBar.fillColor = [accent colorWithAlphaComponent:0.16];
        toastBar.outlineColor = [accent colorWithAlphaComponent:0.42];
        toastBar.layer.borderWidth = 0.75;
        toastBar.layer.cornerRadius = 7;
        NSTextField *toastLabel = Label(self.toastMessage, 11.5, self.toastIsError ? NSColor.systemOrangeColor : NSColor.labelColor);
        toastLabel.frame = NSMakeRect(10, 0, width - 40, 26);
        [toastBar addSubview:toastLabel];
        [root addSubview:toastBar];
    }
    if (searchHeight) {
        if (!self.historySearchField) {
            self.historySearchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(12, height - 74, width - 24, 24)];
            self.historySearchField.controlSize = NSControlSizeSmall;
            self.historySearchField.font = [NSFont systemFontOfSize:12];
            self.historySearchField.placeholderString = @"搜索历史（标题 / 项目 / 应用）";
            self.historySearchField.sendsWholeSearchString = NO;
            self.historySearchField.sendsSearchStringImmediately = YES;
            self.historySearchField.delegate = self;
        }
        self.historySearchField.frame = NSMakeRect(12, height - 74, width - 24, 24);
        [root addSubview:self.historySearchField];
        if (keepSearchFocus) {
            [self.panel makeFirstResponder:self.historySearchField];
            NSText *editor = self.historySearchField.currentEditor;
            if (editor) editor.selectedRange = NSMakeRange(self.historySearchField.stringValue.length, 0);
        }
    }
    if (self.monitorError.length) {
        title.textColor = NSColor.systemOrangeColor;
        title.toolTip = [NSString stringWithFormat:@"%@\n%@",heading,self.monitorError];
    }
    for (NSInteger tab = 0; tab < 2; tab++) {
        TaskButton *button = [TaskButton buttonWithTitle:tab ? @"历史" : @"当前" target:self action:@selector(selectList:)];
        button.tag = tab;
        button.bordered = self.showingHistory == (tab == 1);
        button.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        button.contentTintColor = button.bordered ? NSColor.labelColor : NSColor.secondaryLabelColor;
        button.frame = NSMakeRect(212 + tab * 50,height-37,46,26);
        [root addSubview:button];
    }
    if (!displayed.count) {
        NSString *emptyText = self.showingHistory
            ? (self.historyQuery.length ? @"没有匹配的历史对话" : @"暂无历史对话")
            : @"当前没有进行中的任务";
        NSTextField *empty = Label(emptyText,12,NSColor.tertiaryLabelColor);
        empty.frame = NSMakeRect(16,17+bottomInset,width-32,20);
        [root addSubview:empty];
        return;
    }
    NSScrollView *scroll = PanelScrollView(NSMakeRect(8,8+bottomInset,width-16,listHeight), rowsHeight);
    NSView *document = scroll.documentView;
    // Reserve the hit area even when macOS overlays the scroller on the document.
    CGFloat scrollerGutter = scroll.hasVerticalScroller ? MAX(
        [PanelScroller scrollerWidthForControlSize:NSControlSizeSmall scrollerStyle:NSScrollerStyleOverlay],
        [PanelScroller scrollerWidthForControlSize:NSControlSizeSmall scrollerStyle:NSScrollerStyleLegacy]) : 0;
    CGFloat rowWidth = NSWidth(scroll.frame) - scrollerGutter - 4;
    [scroll.contentView scrollToPoint:NSMakePoint(0,MIN(previousScroll,MAX(0,rowsHeight-listHeight)))];
    [scroll reflectScrolledClipView:scroll.contentView];
    [root addSubview:scroll];
    CGFloat y = 0;
    for (NSDictionary *task in displayed) {
        BOOL needsInput = [task[@"status"] isEqual:@"waiting"];
        BOOL completed = [task[@"status"] isEqual:@"completed"];
        NSArray *subtasks = [task[@"subtasks"] isKindOfClass:NSArray.class] ? task[@"subtasks"] : nil;
        BOOL hasSubtasks = subtasks.count > 0;
        BOOL isExpanded = hasSubtasks && [self.expandedTasks containsObject:task[@"id"]];
        NSColor *color = StatusColor(task[@"status"]);
        PanelSurface *row = [[PanelSurface alloc] initWithFrame:NSMakeRect(0,y,rowWidth,34)];
        row.fillColor = [color colorWithAlphaComponent:0.055];
        row.layer.cornerRadius = 8;
        NSMenu *rowMenu = [NSMenu new];
        if (!self.showingHistory) {
            NSString *title = [@"running" isEqual:task[@"status"]] ? @"移出列表" : @"标为已读";
            NSMenuItem *read = [rowMenu addItemWithTitle:title action:@selector(markTaskRead:) keyEquivalent:@""];
            read.target = self; read.representedObject = task[@"id"];
        }
        if ([task[@"resume_command"] length]) {
            NSMenuItem *resume = [rowMenu addItemWithTitle:@"复制会话恢复命令" action:@selector(copyResume:) keyEquivalent:@""];
            resume.target = self; resume.representedObject = task[@"resume_command"];
        }
        row.menu = rowMenu;
        [document addSubview:row];
        if (!self.showingHistory && needsInput) {
            ApplyWaitingRowAnimation(row, self.panel.effectiveAppearance);
        }
        PanelSurface *state = StatusDot(task[@"status"], NSMakeRect(11,13.5,7,7));
        if (self.showingHistory) {
            state.fillColor = NSColor.tertiaryLabelColor;
            state.toolTip = @"历史对话";
        }
        [row addSubview:state];
        if (!self.showingHistory && needsInput) {
            ApplyWaitingDotAnimation(state, self.panel.effectiveAppearance);
        }
        TaskButton *open = [TaskButton buttonWithTitle:task[@"title"] ?: @"Codex 任务" target:self action:@selector(openTask:)];
        open.threadID = task[@"id"];
        open.bordered = NO;
        open.alignment = NSTextAlignmentLeft;
        open.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        BOOL hasSource = [task[@"source"] length] > 0;
        CGFloat rightReserve = (hasSource ? 58 : 28) + (hasSubtasks ? 42 : 0);
        open.frame = NSMakeRect(23,0,MAX(40, rowWidth - rightReserve),34);
        open.toolTip = [NSString stringWithFormat:@"%@%@%@",task[@"source"] ?: @"Codex",@" · ",task[@"title"] ?: @""];
        if ([task[@"navigation"] isEqual:@"application"]) open.toolTip = [open.toolTip stringByAppendingString:[task[@"status"] isEqual:@"running"] ? @"\n点击返回应用；运行中任务继续保留" : @"\n点击返回应用并标为已读"];
        if (self.showingHistory) {
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:[task[@"updated"] doubleValue]];
            NSString *updated = [task[@"updated"] doubleValue] > 0 ? [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle] : @"";
            open.toolTip = [NSString stringWithFormat:@"%@ · %@\n%@",task[@"source"] ?: @"Codex",task[@"title"] ?: @"",updated];
        }
        if ([task[@"provider"] isEqual:@"antigravity"]) {
            open.toolTip = [NSString stringWithFormat:@"%@ · %@\n点击打开对应对话",task[@"source"] ?: @"Antigravity",task[@"title"] ?: @""];
        }
        open.menu = rowMenu;
        open.accessibilityLabel = [NSString stringWithFormat:@"%@，打开聊天 %@", self.showingHistory ? @"历史对话" : needsInput ? @"待输入" : (completed ? @"已完成" : @"进行中"), open.title];
        [row addSubview:open];
        if (hasSubtasks) {
            BOOL subWaiting = NO;
            NSInteger subRunning = 0;
            for (NSDictionary *sub in subtasks) {
                if ([sub[@"status"] isEqual:@"waiting"]) subWaiting = YES;
                else if ([sub[@"status"] isEqual:@"running"]) subRunning++;
            }
            CGFloat pillX = hasSource ? (rowWidth - 70) : (rowWidth - 44);
            PanelSurface *pill = [[PanelSurface alloc] initWithFrame:NSMakeRect(pillX, 7, 38, 20)];
            NSColor *pillTint = (!self.showingHistory && subWaiting) ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
            pill.fillColor = [pillTint colorWithAlphaComponent:(!self.showingHistory && subWaiting) ? 0.18 : 0.10];
            pill.layer.cornerRadius = 10;
            [row addSubview:pill];
            NSString *pillTitle = [NSString stringWithFormat:@"%@ %lu", isExpanded ? @"▾" : @"▸", (unsigned long)subtasks.count];
            TaskButton *toggle = [TaskButton buttonWithTitle:pillTitle target:self action:@selector(toggleSubtasks:)];
            toggle.threadID = task[@"id"];
            toggle.bordered = NO;
            toggle.alignment = NSTextAlignmentCenter;
            toggle.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium];
            toggle.contentTintColor = (!self.showingHistory && subWaiting) ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
            toggle.frame = NSMakeRect(0, 0, 38, 20);
            NSString *subDetail = (!self.showingHistory && subRunning > 0)
                ? [NSString stringWithFormat:@"（含 %ld 个进行中）", (long)subRunning]
                : @"";
            toggle.toolTip = [NSString stringWithFormat:@"%lu 个协同子任务%@，点击%@", (unsigned long)subtasks.count, subDetail, isExpanded ? @"收起" : @"展开"];
            toggle.accessibilityLabel = toggle.toolTip;
            [pill addSubview:toggle];
        }
        if (hasSource) {
            NSImageView *source = [[NSImageView alloc] initWithFrame:NSMakeRect(rowWidth-28,7,20,20)];
            source.image = SourceIcon(task);
            source.imageScaling = NSImageScaleProportionallyUpOrDown;
            source.contentTintColor = NSColor.secondaryLabelColor;
            source.toolTip = task[@"source"];
            source.accessibilityElement = YES;
            source.accessibilityLabel = [NSString stringWithFormat:@"应用：%@",task[@"source"]];
            [row addSubview:source];
        }
        if (!self.showingHistory && completed && self.completionPulse && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
            CABasicAnimation *flash = [CABasicAnimation animationWithKeyPath:@"backgroundColor"];
            [row.effectiveAppearance performAsCurrentDrawingAppearance:^{
                flash.fromValue = (id)[color colorWithAlphaComponent:0.28].CGColor;
            }];
            flash.toValue = (id)row.layer.backgroundColor;
            flash.duration = 0.8;
            [row.layer addAnimation:flash forKey:@"completionHighlight"];
        }
        y += 38;
        if (isExpanded) {
            CGFloat childX = 18;
            CGFloat childWidth = rowWidth - childX;
            PanelSurface *connector = [[PanelSurface alloc] initWithFrame:NSMakeRect(11, y - 4, 1.5, subtasks.count * 32 - 12)];
            connector.fillColor = [NSColor.separatorColor colorWithAlphaComponent:0.45];
            connector.layer.cornerRadius = 0.75;
            [document addSubview:connector];
            for (NSDictionary *sub in subtasks) {
                BOOL subNeedsInput = [sub[@"status"] isEqual:@"waiting"];
                BOOL subCompleted = [sub[@"status"] isEqual:@"completed"];
                NSColor *subColor = StatusColor(sub[@"status"]);
                PanelSurface *subRow = [[PanelSurface alloc] initWithFrame:NSMakeRect(childX, y, childWidth, 28)];
                subRow.fillColor = [subColor colorWithAlphaComponent:0.045];
                subRow.layer.cornerRadius = 6;
                NSMenu *subMenu = [NSMenu new];
                if (!self.showingHistory) {
                    NSString *subMenuTitle = [@"running" isEqual:sub[@"status"]] ? @"移出列表" : @"标为已读";
                    NSMenuItem *subRead = [subMenu addItemWithTitle:subMenuTitle action:@selector(markTaskRead:) keyEquivalent:@""];
                    subRead.target = self; subRead.representedObject = sub[@"id"];
                }
                if ([sub[@"resume_command"] length]) {
                    NSMenuItem *subResume = [subMenu addItemWithTitle:@"复制会话恢复命令" action:@selector(copyResume:) keyEquivalent:@""];
                    subResume.target = self; subResume.representedObject = sub[@"resume_command"];
                }
                subRow.menu = subMenu;
                [document addSubview:subRow];
                if (!self.showingHistory && subNeedsInput) {
                    ApplyWaitingRowAnimation(subRow, self.panel.effectiveAppearance);
                }
                PanelSurface *subDot = StatusDot(sub[@"status"], NSMakeRect(9, 11, 6, 6));
                if (self.showingHistory) {
                    subDot.fillColor = NSColor.tertiaryLabelColor;
                    subDot.toolTip = @"历史协同子任务";
                }
                [subRow addSubview:subDot];
                if (!self.showingHistory && subNeedsInput) {
                    ApplyWaitingDotAnimation(subDot, self.panel.effectiveAppearance);
                }
                TaskButton *subOpen = [TaskButton buttonWithTitle:sub[@"title"] ?: @"协同子任务" target:self action:@selector(openTask:)];
                subOpen.threadID = sub[@"id"];
                subOpen.bordered = NO;
                subOpen.alignment = NSTextAlignmentLeft;
                subOpen.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
                subOpen.contentTintColor = NSColor.secondaryLabelColor;
                BOOL subHasSource = [sub[@"source"] length] > 0;
                subOpen.frame = NSMakeRect(20, 0, MAX(40, childWidth - (subHasSource ? 46 : 24)), 28);
                subOpen.toolTip = [NSString stringWithFormat:@"协同子任务 · %@ · %@", sub[@"source"] ?: @"", sub[@"title"] ?: @""];
                if ([sub[@"provider"] isEqual:@"antigravity"]) {
                    subOpen.toolTip = [subOpen.toolTip stringByAppendingString:@"\n点击打开对应对话"];
                }
                subOpen.menu = subMenu;
                subOpen.accessibilityLabel = [NSString stringWithFormat:@"协同子任务，%@，%@", self.showingHistory ? @"历史" : subNeedsInput ? @"待输入" : (subCompleted ? @"已完成" : @"进行中"), subOpen.title];
                [subRow addSubview:subOpen];
                if (subHasSource) {
                    NSImageView *subSource = [[NSImageView alloc] initWithFrame:NSMakeRect(childWidth - 22, 6, 16, 16)];
                    subSource.image = SourceIcon(sub);
                    subSource.imageScaling = NSImageScaleProportionallyUpOrDown;
                    subSource.contentTintColor = NSColor.secondaryLabelColor;
                    subSource.toolTip = sub[@"source"];
                    subSource.accessibilityElement = YES;
                    subSource.accessibilityLabel = [NSString stringWithFormat:@"应用：%@", sub[@"source"]];
                    [subRow addSubview:subSource];
                }
                y += 32;
            }
            y += 2;
        }
    }
    if (hasMore) {
        TaskButton *more = [TaskButton buttonWithTitle:@"再显示 10 条" target:self action:@selector(loadMoreHistory:)];
        more.bordered = NO;
        more.font = [NSFont systemFontOfSize:12];
        more.frame = NSMakeRect(0,y,rowWidth,30);
        [document addSubview:more];
    }
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self unregisterMirrorHotKey];
    [self.celebration stop];
    if (self.monitor.running) [self.monitor terminate];
}
@end
@interface CelebrationTestView : CelebrationView
@property(strong) NSValue *testPointer;
@end
@implementation CelebrationTestView
- (NSValue *)pointerInEffect { return self.testPointer; }
@end

static NSBitmapImageRep *RenderCelebration(CelebrationView *scene) {
    NSBitmapImageRep *card = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:NSWidth(scene.bounds) pixelsHigh:NSHeight(scene.bounds)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:card];
    [scene drawRect:scene.bounds];
    [NSGraphicsContext restoreGraphicsState];
    return card;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray *args = NSProcessInfo.processInfo.arguments;
        // Legacy notify invocations are consumed by the shared event monitor.
        if (args.count > 1 && ![args[1] isEqual:@"--watch"] && ![args[1] isEqual:@"--preview"] && ![args[1] hasPrefix:@"-psn_"]) return 0;
        NSString *codexDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@".codex"];
        [NSFileManager.defaultManager createDirectoryAtPath:codexDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
        int lock = open([[codexDirectory stringByAppendingPathComponent:@"task-complete-popup-watch.lock"] fileSystemRepresentation], O_CREAT|O_RDWR,0600);
        if (![args containsObject:@"--preview"] && (lock < 0 || flock(lock,LOCK_EX|LOCK_NB) != 0)) return 0;
        [NSApplication sharedApplication];
        PanelController *controller = [PanelController new];
        controller.preview = args.count > 1 && [args[1] isEqual:@"--preview"];
        controller.launchedInteractively = !controller.preview && ![args containsObject:@"--watch"];
        NSApp.delegate = controller;
        if (controller.preview) {
            [NSFileManager.defaultManager createDirectoryAtPath:DataDirectory() withIntermediateDirectories:YES attributes:nil error:NULL];
            if ([args containsObject:@"--quit-ui-test"]) {
                [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
                    object:NSApp queue:nil usingBlock:^(NSNotification *notification) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            NSMenuItem *quit = [controller statusMenu].itemArray.lastObject;
                            if (![NSApp sendAction:quit.action to:quit.target from:quit]) exit(1);
                        });
                    }];
                [NSApp run];
                return 1;
            }
            [controller applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp]];
            controller.collapsed = NO;
            controller.tasks = @[
                @{@"id":@"preview-input",@"turn":@"one",@"status":@"waiting",@"title":@"确认运营平台销售功能清单",@"project":@"Tuntas SmartBiz",@"detail":@"需要确认功能范围，请打开聊天选择。"},
                @{@"id":@"preview-running",@"turn":@"two",@"status":@"running",@"title":@"优化全局任务浮窗",@"project":@"Codex任务管理器",@"detail":@"正在整合任务状态与紧凑提醒。"},
                @{@"id":@"preview-done",@"turn":@"three",@"status":@"completed",@"title":@"更新移动端页面",@"project":@"Tuntas Mobile",@"detail":@"页面更新已完成，等待你确认。"}
            ];
            if ([args containsObject:@"--current"]) controller.tasks = ReadJSON(@"snapshot.json")[@"tasks"] ?: @[];
            if ([args containsObject:@"--history"]) {
                controller.history = ReadJSON(@"snapshot.json")[@"history"] ?: @[];
                controller.showingHistory = YES;
            }
            if ([args containsObject:@"--collapsed"]) controller.collapsed = YES;
            if ([args containsObject:@"--empty"]) controller.tasks = @[];
            NSUInteger mascotArgument = [args indexOfObject:@"--mascot"];
            if (mascotArgument != NSNotFound && mascotArgument+1 < args.count)
                controller.celebration.settings[@"mascotID"] = MascotDefinition(args[mascotArgument+1])[@"id"];
            [controller rebuild];
            if ([args containsObject:@"--mascot-sheet"] || [args containsObject:@"--settings-preview"]) {
                NSView *view;
                if ([args containsObject:@"--mascot-sheet"]) view = [[MascotGalleryView alloc] initWithFrame:NSMakeRect(0,0,900,620)];
                else {
                    [controller.celebration buildSettings];
                    [controller addMainPanelActions];
                    [controller updateFloatingVisibilityButton];
                    [controller.celebration.settingsWindow display];
                    view = controller.celebration.settingsWindow.contentView;
                }
                NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
                [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:args[2] atomically:YES];
                return 0;
            }
            if ([args containsObject:@"--history-ui-test"]) {
                NSMutableArray *history = [NSMutableArray array];
                for (NSInteger index = 0; index < 25; index++)
                    [history addObject:@{@"id":[NSString stringWithFormat:@"history-%ld",(long)index],@"turn":@"old",@"status":@"completed",@"title":[NSString stringWithFormat:@"历史对话 %ld",(long)index+1],@"updated":@(1794960000-index)}];
                controller.history = history;
                TaskButton *tab = [TaskButton new]; tab.tag = 1;
                [controller selectList:tab];
                NSScrollView *(^list)(void) = ^{
                    for (NSView *view in controller.panel.contentView.subviews)
                        if ([view isKindOfClass:NSScrollView.class]) return (NSScrollView *)view;
                    return (NSScrollView *)nil;
                };
                MascotAvatarView *avatar = nil;
                NSMutableArray *tabs = [NSMutableArray array];
                NSTextField *name = nil;
                NSString *expectedName = MascotDefinition(controller.celebration.settings[@"mascotID"])[@"name"];
                for (NSView *view in controller.panel.contentView.subviews) {
                    if ([view isKindOfClass:NSTextField.class] && [((NSTextField *)view).stringValue isEqual:expectedName]) name = (NSTextField *)view;
                    if ([view isKindOfClass:MascotAvatarView.class]) avatar = (MascotAvatarView *)view;
                    if ([view isKindOfClass:TaskButton.class] && [@[@"当前",@"历史"] containsObject:((TaskButton *)view).title]) [tabs addObject:view];
                }
                NSCAssert(avatar && name && !name.hidden && tabs.count == 2, @"Header shows the cat, its full name and two short tab labels");
                NSCAssert(NSMinX(name.frame) > NSMaxX(avatar.frame), @"The cat name appears next to the avatar");
                for (NSView *button in tabs)
                    NSCAssert(NSMinX(button.frame) > NSMaxX(name.frame) && fabs(NSMidY(button.frame)-NSMidY(avatar.frame)) < 1, @"Tabs sit to the right of the cat name on the same line");
                NSCAssert(controller.panel.frame.size.height == 462, @"Single-line header + compact search bar keeps the history panel compact");
                NSCAssert(controller.showingHistory && !controller.collapsed && list().documentView.subviews.count == 11, @"History defaults to ten rows plus load more");
                controller.historyQuery = @"历史对话 25"; [controller rebuild];
                NSCAssert(list().documentView.subviews.count == 1, @"History search must filter matching entries");
                controller.historyQuery = @""; [controller rebuild];
                [controller loadMoreHistory:nil];
                NSCAssert(list().documentView.subviews.count == 21, @"Load more adds ten rows");
                [controller loadMoreHistory:nil];
                NSCAssert(list().documentView.subviews.count == 25, @"Last page hides load more");
                TaskButton *open = nil;
                for (NSView *view in list().documentView.subviews.firstObject.subviews)
                    if ([view isKindOfClass:TaskButton.class]) open = (TaskButton *)view;
                [open performClick:nil];
                NSCAssert(controller.history.count == 25, @"Opening history retains the conversation");
                controller.tasks = @[];
                [controller selectList:tab];
                NSCAssert(!controller.collapsed && list().documentView.subviews.count == 11, @"History remains available without active tasks and resets to ten");
                controller.history = @[]; [controller rebuild];
                NSCAssert(!controller.collapsed && !list(), @"Empty history displays an expanded empty state");
                puts("History UI passed: default ten, pagination, navigation, reset and empty state");
                return 0;
            }
            if ([args containsObject:@"--mascot-ui-test"]) {
                CelebrationController *owner = controller.celebration;
                [owner buildSettings];
                NSMutableSet *identifiers = [NSMutableSet set], *artwork = [NSMutableSet set];
                NSArray<NSDictionary *> *builtInRoles = [MascotCatalog() arrayByAddingObjectsFromArray:PresetAvatarCatalog()];
                for (NSDictionary *role in builtInRoles) {
                    [identifiers addObject:role[@"id"]];
                    NSCAssert([role[@"name"] length] && [role[@"description"] length], @"Every role must have a name and personality");
                    MascotChoiceButton *choice = nil;
                    for (NSView *view in owner.settingsWindow.contentView.subviews)
                        if ([view isKindOfClass:MascotChoiceButton.class] && [((MascotChoiceButton *)view).mascotID isEqual:role[@"id"]]) choice = (MascotChoiceButton *)view;
                    NSCAssert(choice, @"Every role must have a selectable card");
                    [choice performClick:nil];
                    CelebrationController *restored = [[CelebrationController alloc] initWithDirectory:DataDirectory()];
                    NSCAssert([restored.settings[@"mascotID"] isEqual:role[@"id"]] && [owner.previewView.mascotID isEqual:role[@"id"]], @"Selection must persist and update the preview immediately");
                    NSInteger selected = 0;
                    for (NSView *view in owner.settingsWindow.contentView.subviews) if ([view isKindOfClass:MascotChoiceButton.class] && ((MascotChoiceButton *)view).chosen) selected++;
                    NSCAssert(selected == 1, @"Exactly one role must be selected");
                    NSCAssert([controller.statusItem.button.toolTip containsString:role[@"name"]] && controller.statusItem.button.image, @"Menu bar identity must follow selection");
                    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:128 pixelsHigh:128 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
                    [NSGraphicsContext saveGraphicsState]; NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
                    DrawMascot(role[@"id"],NSMakeRect(0,0,128,128),@"idle"); [NSGraphicsContext restoreGraphicsState];
                    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                    NSCAssert(png.length > 200, @"Rendered mascot/avatar PNG must be non-empty");
                    [artwork addObject:png];
                }
                NSCAssert(identifiers.count == 12 && artwork.count == 12, @"All 12 built-in mascots and cutout avatars must have distinct identifiers and artwork");

                // Test custom avatar import + automatic solid-background removal + persistence + clear
                NSString *syntheticSrc = [DataDirectory() stringByAppendingPathComponent:@"synthetic-upload.png"];
                NSBitmapImageRep *srcRep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:128 pixelsHigh:128 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
                [NSGraphicsContext saveGraphicsState];
                NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:srcRep];
                [NSColor.blackColor setFill];
                NSRectFill(NSMakeRect(0, 0, 128, 128));
                [[NSColor colorWithSRGBRed:0.95 green:0.55 blue:0.20 alpha:1.0] setFill];
                [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(24, 24, 80, 80)] fill];
                [NSGraphicsContext restoreGraphicsState];
                [[srcRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:syntheticSrc atomically:YES];

                NSCAssert([owner importCustomAvatarAtURL:[NSURL fileURLWithPath:syntheticSrc]], @"Custom avatar import must succeed");
                NSCAssert(MascotHasCustomAvatar() && [owner.settings[@"mascotID"] isEqual:@"custom"], @"Importing custom avatar must activate custom mascotID");
                CelebrationController *restoredCustom = [[CelebrationController alloc] initWithDirectory:DataDirectory()];
                NSCAssert([restoredCustom.settings[@"mascotID"] isEqual:@"custom"], @"Custom avatar selection must persist across reload");
                NSBitmapImageRep *cutRep = [NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfFile:[DataDirectory() stringByAppendingPathComponent:@"custom-avatar.png"]]];
                NSCAssert(cutRep && [cutRep colorAtX:0 y:0].alphaComponent < 0.05 && [cutRep colorAtX:cutRep.pixelsWide/2 y:cutRep.pixelsHigh/2].alphaComponent > 0.9,
                          @"Automatic background removal must strip black exterior corners while preserving centered subject");
                [owner clearCustomAvatar:nil];
                NSCAssert(!MascotHasCustomAvatar() && [owner.settings[@"mascotID"] isEqual:@"foreman"], @"Clearing custom avatar must fall back cleanly to foreman");

                controller.collapsed = YES; [controller rebuild];
                NSCAssert(controller.panel.frame.size.width == 206 && controller.panel.frame.size.height == 40, @"Identity changes must preserve compact capsule geometry");
                puts("Mascots passed: 12 built-in designs, custom upload with auto background removal, persistence, menu and preview updates, and compact layout");
                return 0;
            }
            if ([args containsObject:@"--integration-ui-test"]) {
                NSString *uuid = @"01234567-89ab-cdef-0123-456789abcdef";
                NSString *antigravityTask = [@"antigravity:" stringByAppendingString:uuid.uppercaseString];
                NSCAssert([AntigravityConversationID(antigravityTask) isEqual:uuid] && !AntigravityConversationID(@"antigravity:malformed"), @"Antigravity must use the canonical conversation UUID from existing task records");
                NSString *path = [@"/c/" stringByAppendingString:uuid];
                NSURL *localConversation = [NSURL URLWithString:[@"https://127.0.0.1:50000" stringByAppendingFormat:@"%@?project=sample",path]];
                NSURL *externalConversation = [NSURL URLWithString:[@"https://example.com:50000" stringByAppendingString:path]];
                NSCAssert(AntigravityMatchesConversationURL(localConversation,uuid) &&
                    !AntigravityMatchesConversationURL(externalConversation,uuid) &&
                    !AntigravityMatchesConversationURL(localConversation,@"01234567-89ab-cdef-0123-456789abcdff"),
                    @"Acknowledge only a local Antigravity view displaying the exact target conversation");
                for (NSString *provider in @[@"claude",@"cursor",@"copilot",@"antigravity",@"gemini",@"windsurf",@"opencode",@"trae",@"codebuddy",@"qoder",@"qwencode",@"qianwen",@"deepseek",@"minimax",@"kimi"]) {
                    for (NSString *status in @[@"running",@"waiting",@"completed"]) {
                        NSString *taskID = [NSString stringWithFormat:@"%@:test-%@",provider,status];
                        NSDictionary *task = @{@"id":taskID,@"provider":provider,@"source":provider,@"turn":@"round",@"status":status,@"title":@"其他软件任务",@"navigation":@"application",@"app":@"Test"};
                        controller.tasks = @[task];
                        controller.collapsed = NO;
                        [controller rebuild];
                        TaskButton *button = [TaskButton new]; button.threadID = taskID;
                        [controller openTask:button];
                        if ([status isEqual:@"running"]) {
                            NSCAssert(controller.tasks.count == 1 && !controller.removingTasks.count && !ReadJSON(@"dismissed.json")[taskID], @"Opening a running app task must retain it");
                        } else {
                            NSCAssert([controller.removingTasks containsObject:taskID], @"Successful app navigation must animate reminder removal");
                            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
                            NSCAssert(!controller.tasks.count && [ReadJSON(@"dismissed.json")[taskID] isEqual:DismissalKey(task)], @"App navigation must persist a per-turn acknowledgement");
                            PanelController *restored = [PanelController new];
                            restored.dismissed = [ReadJSON(@"dismissed.json") mutableCopy];
                            restored.removingTasks = [NSMutableSet set];
                            NSDictionary *snapshot = @{@"tasks":@[task]};
                            [[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:NULL] writeToFile:[DataDirectory() stringByAppendingPathComponent:@"snapshot.json"] atomically:YES];
                            [restored refresh];
                            NSCAssert(!restored.tasks.count, @"A stale snapshot after restart must not restore an acknowledged reminder");
                        }
                    }
                }
                NSDictionary *pending = @{@"id":@"launch:test",@"turn":@"one",@"status":@"completed",@"title":@"打开失败重试"};
                controller.tasks = @[pending];
                [controller.openingTasks addObject:pending[@"id"]];
                [controller finishOpeningTask:pending row:nil opened:NO];
                NSCAssert(controller.tasks.count == 1 && !controller.removingTasks.count && !controller.openingTasks.count && !ReadJSON(@"dismissed.json")[pending[@"id"]], @"Failed launches must retain the reminder and permit retry");
                NSDictionary *nextTurn = @{@"id":@"launch:test",@"turn":@"two",@"status":@"completed",@"title":@"后续任务"};
                controller.tasks = @[nextTurn];
                [controller finishOpeningTask:pending row:nil opened:YES];
                NSCAssert(controller.tasks.count == 1 && !controller.removingTasks.count && !ReadJSON(@"dismissed.json")[pending[@"id"]], @"A delayed launch callback must not acknowledge a newer turn");
                NSMenuItem *read = [NSMenuItem new]; read.representedObject = pending[@"id"];
                [controller markTaskRead:read];
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
                NSCAssert(!controller.tasks.count && [ReadJSON(@"dismissed.json")[pending[@"id"]] isEqual:@"two:completed"], @"Explicit mark-read must still persist");
                puts("Multi-client UI passed: 15 app sources, navigation acknowledgement, running retention, restart filtering, failed launch retry, late callbacks and manual read state");
                return 0;
            }
            if ([args containsObject:@"--integrations-preview"]) {
                controller.integrationsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,720,650) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
                [controller updateIntegrations];
                [controller.integrationsWindow display];
                NSView *view = controller.integrationsWindow.contentView;
                NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
                [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:args[2] atomically:YES];
                return 0;
            }
            if ([args containsObject:@"--celebration-preview"]) {
                CelebrationView *art = [[CelebrationView alloc] initWithFrame:NSMakeRect(0,0,600,460)];
                art.duration = 4; art.startTime = CACurrentMediaTime()-1.0; art.intensity = 0.8;
                art.style = CelebrationPlaybackStyle([controller.celebration.settings[@"style"] integerValue], CelebrationRandomStyle);
                art.mascotID = controller.celebration.settings[@"mascotID"];
                NSUInteger styleArgument = [args indexOfObject:@"--style"];
                if (styleArgument != NSNotFound && styleArgument+1 < args.count) art.style = [args[styleArgument+1] integerValue];
                art.message = CelebrationRandomMessage(nil);
                NSUInteger messageArgument = [args indexOfObject:@"--message-index"];
                if (messageArgument != NSNotFound && messageArgument+1 < args.count)
                    art.message = CelebrationMessages()[(NSUInteger)[args[messageArgument+1] integerValue]%CelebrationMessages().count];
                art.reducedMotion = [args containsObject:@"--reduced-motion"];
                if ([args containsObject:@"--cool"] || [args containsObject:@"--warm"]) art.palette = 1;
                BOOL global = [args containsObject:@"--global"];
                NSSize canvasSize = global ? NSMakeSize(1200,800) : art.bounds.size;
                NSRect canvasBounds = NSMakeRect(0,0,canvasSize.width,canvasSize.height);
                NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:canvasSize.width pixelsHigh:canvasSize.height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
                [NSGraphicsContext saveGraphicsState];
                NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
                [[NSColor colorWithCalibratedRed:0.12 green:0.14 blue:0.18 alpha:1] setFill];
                NSRectFill(canvasBounds);
                if ([args containsObject:@"--busy-background"]) {
                    [[NSColor colorWithWhite:0.96 alpha:1] setFill]; NSRectFill(canvasBounds);
                    NSDictionary *textAttributes = @{NSFontAttributeName:[NSFont systemFontOfSize:16], NSForegroundColorAttributeName:NSColor.blackColor};
                    for (NSInteger row=0;row<25;row++)
                        [@"背景文档  项目进度  正在处理的内容  1234567890  Background document" drawAtPoint:NSMakePoint(180,row*32) withAttributes:textAttributes];
                }
                CGContextRef previewContext = NSGraphicsContext.currentContext.CGContext;
                CGContextBeginTransparencyLayer(previewContext,NULL);
                if (global) {
                    NSRect overlayFrame = CelebrationOverlayFrame(canvasBounds);
                    NSAffineTransform *placement = [NSAffineTransform transform];
                    [placement translateXBy:NSMinX(overlayFrame) yBy:NSMinY(overlayFrame)];
                    [placement scaleXBy:NSWidth(overlayFrame)/NSWidth(art.bounds) yBy:NSHeight(overlayFrame)/NSHeight(art.bounds)];
                    [placement concat];
                }
                [art drawRect:art.bounds];
                CGContextEndTransparencyLayer(previewContext);
                [NSGraphicsContext restoreGraphicsState];
                [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:args[2] atomically:YES];
                return 0;
            }
            if ([args containsObject:@"--input-mirror-ui-test"]) {
                // 1. Default OFF
                NSCAssert(![controller.celebration.settings[@"inputMirrorEnabled"] boolValue], @"Input mirror must be disabled by default");
                NSCAssert(!controller.inputMirror.enabled && !controller.inputMirror.visible, @"Input mirror must start inactive and hidden");

                // 2. Supported AI app allowlist, password exclusion & editable input classification
                NSCAssert(InputMirrorIsSupportedAIApp(@"com.google.antigravity", @"Antigravity"), @"Antigravity must be supported");
                NSCAssert(InputMirrorIsSupportedAIApp(@"com.openai.codex", @"Codex"), @"Codex must be supported");
                NSCAssert(InputMirrorIsSupportedAIApp(@"com.todesktop.230313mzl4w4u92", @"Cursor"), @"Cursor must be supported");
                NSCAssert(InputMirrorIsSupportedAIApp(@"com.alibaba.tongyi", @"千问"), @"Qianwen must be supported");
                NSCAssert(!InputMirrorIsSupportedAIApp(@"com.apple.Safari", @"Safari"), @"Non-AI browser Safari must be ignored");
                NSCAssert(!InputMirrorIsSupportedAIApp(@"com.tencent.xinWeChat", @"WeChat"), @"Non-AI app WeChat must be ignored");
                NSCAssert(!InputMirrorIsSupportedAIApp(@"com.apple.finder", @"Finder"), @"Non-AI app Finder must be ignored");
                NSCAssert(InputMirrorIsPlaceholderText(@"和 Codex 一起工作", nil, nil, nil, NSMakeRange(0, 0)), @"Codex placeholder must be filtered out when empty");
                NSCAssert(InputMirrorIsPlaceholderText(@"Ask anything...", nil, @"Ask anything…", nil, NSMakeRange(0, 0)), @"Description-matching placeholder must be filtered out");
                NSCAssert(!InputMirrorIsPlaceholderText(@"和 Codex 一起工作，帮我写测试", nil, nil, nil, NSMakeRange(14, 0)), @"Real user text must never be filtered out");
                NSCAssert(InputMirrorIsSecureMetadata(@"AXSecureTextField", nil, nil, NO), @"AXSecureTextField role must be excluded");
                NSCAssert(InputMirrorIsSecureMetadata(@"AXTextField", @"AXSecureTextField", nil, NO), @"AXSecureTextField subrole must be excluded");
                NSCAssert(InputMirrorIsSecureMetadata(@"AXTextField", nil, @"secure text field", NO), @"Secure role description must be excluded");
                NSCAssert(InputMirrorIsSecureMetadata(@"AXTextField", nil, nil, YES), @"Protected field must be excluded");
                NSCAssert(!InputMirrorIsEditableMetadata(@"AXTextField", @"AXSecureTextField", nil, NO, YES, YES, YES), @"Secure text field must never be mirrored");
                NSCAssert(InputMirrorIsEditableMetadata(@"AXTextField", nil, nil, NO, NO, YES, YES), @"Standard AXTextField must be mirrored");
                NSCAssert(InputMirrorIsEditableMetadata(@"AXTextArea", nil, nil, NO, NO, YES, YES), @"Standard AXTextArea must be mirrored");
                NSCAssert(InputMirrorIsEditableMetadata(@"AXGroup", nil, nil, NO, YES, NO, YES), @"Editable contenteditable AXGroup must be mirrored");
                NSCAssert(!InputMirrorIsEditableMetadata(@"AXButton", nil, nil, NO, NO, NO, NO), @"Non-editable AXButton must not be mirrored");

                // 3. Control panel toggle & persistence
                [controller showMainPanel:nil];
                NSCAssert(controller.celebration.inputMirrorCheckbox != nil, @"Main panel must show input mirror checkbox");
                NSCAssert(controller.celebration.inputMirrorCheckbox.state == NSControlStateValueOff, @"Checkbox must start unchecked");
                controller.celebration.inputMirrorCheckbox.state = NSControlStateValueOn;
                [controller.celebration changeSetting:controller.celebration.inputMirrorCheckbox];
                NSCAssert(controller.inputMirror.enabled, @"Enabling checkbox must enable input mirror");
                CelebrationController *reloaded = [[CelebrationController alloc] initWithDirectory:DataDirectory()];
                NSCAssert([reloaded.settings[@"inputMirrorEnabled"] boolValue], @"Input mirror enabled state must persist");

                // 4. Mirror display, rich list formatting, larger typography & direct interactivity
                controller.inputMirror.defaultsKeyPrefix = @"InputMirrorUITest";
                [controller.inputMirror resetSavedPosition];
                NSString *formattedSample = @"1. 有序列表一\n2. 有序列表二\n- 一级无序列表与 `代码`\n  ◦ 二级无序列表\n    ▪ 三级无序列表\n\t+ Tab 缩进二级\n\t\t* Tab 缩进三级";
                [controller.inputMirror updateMirroredText:formattedSample selection:NSMakeRange(3, 2) appName:@"Codex" appIcon:nil];
                [controller.inputMirror showPreviewSample];
                NSCAssert(controller.inputMirror.visible, @"Preview must display input mirror panel");
                NSCAssert(controller.inputMirror.panel.becomesKeyOnlyIfNeeded, @"Panel must only become key when user interacts with text view");
                NSCAssert(controller.inputMirror.textView.editable && controller.inputMirror.textView.selectable, @"Mirror text view must support direct deletion, newline and cursor movement without an Edit button");
                NSCAssert(controller.inputMirror.textView.font.pointSize == 15.0, @"Body font must be comfortable 15pt size");
                NSCAssert([InputMirrorSummaryText(@"第一行\n第二行") isEqualToString:@"7 字 · 2 行"], @"Summary must count characters and lines");
                NSAttributedString *rich = InputMirrorFormatAttributedText(formattedSample,
                                                                           [NSFont systemFontOfSize:17.0],
                                                                           NSColor.labelColor,
                                                                           NSColor.systemBlueColor,
                                                                           NSColor.secondaryLabelColor,
                                                                           NSColor.quaternaryLabelColor,
                                                                           NSMakeRange(0, 0),
                                                                           NO);
                NSCAssert([rich.string isEqualToString:formattedSample], @"Rich formatting must preserve exact string length and indices");
                NSParagraphStyle *olPara = [rich attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL];
                NSUInteger ul1Index = [formattedSample rangeOfString:@"- 一级"].location;
                NSUInteger ul2Index = [formattedSample rangeOfString:@"  ◦ 二级"].location;
                NSUInteger ul3Index = [formattedSample rangeOfString:@"    ▪ 三级"].location;
                NSUInteger tab2Index = [formattedSample rangeOfString:@"\t+ Tab"].location;
                NSUInteger tab3Index = [formattedSample rangeOfString:@"\t\t* Tab"].location;
                NSParagraphStyle *ul1Para = [rich attribute:NSParagraphStyleAttributeName atIndex:ul1Index effectiveRange:NULL];
                NSParagraphStyle *ul2Para = [rich attribute:NSParagraphStyleAttributeName atIndex:ul2Index effectiveRange:NULL];
                NSParagraphStyle *ul3Para = [rich attribute:NSParagraphStyleAttributeName atIndex:ul3Index effectiveRange:NULL];
                NSParagraphStyle *tab2Para = [rich attribute:NSParagraphStyleAttributeName atIndex:tab2Index effectiveRange:NULL];
                NSParagraphStyle *tab3Para = [rich attribute:NSParagraphStyleAttributeName atIndex:tab3Index effectiveRange:NULL];
                NSCAssert(olPara.headIndent > olPara.firstLineHeadIndent && ul1Para.headIndent > ul1Para.firstLineHeadIndent, @"Ordered and unordered lists must render with hanging indentation");
                NSCAssert(ul2Para.firstLineHeadIndent > ul1Para.firstLineHeadIndent && ul3Para.firstLineHeadIndent > ul2Para.firstLineHeadIndent, @"Nested unordered lists must progressively increase first-line indentation");
                NSCAssert(ul2Para.headIndent > ul1Para.headIndent && ul3Para.headIndent > ul2Para.headIndent, @"Nested unordered lists must progressively increase hanging indentation");
                NSCAssert(tab2Para.headIndent > ul1Para.headIndent && tab3Para.headIndent > tab2Para.headIndent, @"Tab-indented nested unordered lists must progressively increase hanging indentation");
                NSColor *ul1Color = [rich attribute:InputMirrorListBulletColorAttributeName atIndex:ul1Index effectiveRange:NULL];
                NSColor *ul2Color = [rich attribute:InputMirrorListBulletColorAttributeName atIndex:ul2Index + 2 effectiveRange:NULL];
                NSColor *ul3Color = [rich attribute:InputMirrorListBulletColorAttributeName atIndex:ul3Index + 4 effectiveRange:NULL];
                NSCAssert(ul1Color.alphaComponent > ul2Color.alphaComponent && ul2Color.alphaComponent > ul3Color.alphaComponent, @"Nested unordered list bullets must visually step down in emphasis by level");

                // 5. Cross-screen drag memory & unplug fallback
                NSRect customFrame = NSMakeRect(NSMinX(NSScreen.mainScreen.visibleFrame) + 90,
                                                NSMinY(NSScreen.mainScreen.visibleFrame) + 120,
                                                600, 216);
                [controller.inputMirror.panel setFrame:customFrame display:YES];
                [controller.inputMirror windowDidMove:[NSNotification notificationWithName:NSWindowDidMoveNotification object:controller.inputMirror.panel]];
                NSString *savedFrameStr = [NSUserDefaults.standardUserDefaults stringForKey:@"InputMirrorUITestFrame"];
                NSCAssert(savedFrameStr.length > 0 && NSEqualRects(NSRectFromString(savedFrameStr), customFrame), @"Moved frame must be persisted");
                NSRect offscreenSaved = NSMakeRect(-99999, -99999, 600, 216);
                NSRect recovered = InputMirrorRestoredFrame(offscreenSaved, 999999, NSScreen.screens, NSScreen.mainScreen);
                NSCAssert(NSIntersectsRect(NSScreen.mainScreen.visibleFrame, recovered), @"Disconnected screen frame must fall back to visible main screen");

                // 6. Direct Shift+Enter newline, Backspace deletion & Enter send-to-auto-close
                __block NSString *syncedText = nil;
                __block BOOL sentFlag = NO;
                controller.inputMirror.onSyncBack = ^(NSString *text, BOOL shouldSend) {
                    syncedText = text;
                    sentFlag = shouldSend;
                };
                [controller.inputMirror updateMirroredText:@"Hello!" selection:NSMakeRange(6, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror.textView setSelectedRange:NSMakeRange(6, 0)];
                [controller.inputMirror.textView deleteBackward:nil];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"Hello"], @"Direct deletion must work inside floating input");
                NSEvent *shiftReturn = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagShift timestamp:0 windowNumber:0 context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
                [controller.inputMirror.textView keyDown:shiftReturn];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"Hello\n"] && !sentFlag, @"Shift+Enter must insert newline without sending");
                NSEvent *plainReturn = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
                [controller.inputMirror.textView keyDown:plainReturn];
                NSCAssert(sentFlag && [syncedText isEqualToString:@"Hello\n"], @"Enter must sync text and trigger send");
                NSCAssert(!controller.inputMirror.visible, @"Mirror panel must automatically close after send");

                // 6b. Smart multi-level list editing (Shift+Enter continue/outdent/exit, Tab/Shift+Tab indent/outdent, Backspace outdent/exit)
                NSEvent *tabKey = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"\t" charactersIgnoringModifiers:@"\t" isARepeat:NO keyCode:48];
                NSEvent *shiftTabKey = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagShift timestamp:0 windowNumber:0 context:nil characters:@"\x19" charactersIgnoringModifiers:@"\t" isARepeat:NO keyCode:48];
                NSEvent *deleteKey = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"\x7f" charactersIgnoringModifiers:@"\x7f" isARepeat:NO keyCode:51];

                // Unordered list: continue -> Tab indent x2 -> Backspace outdent x2 -> exit list
                [controller.inputMirror updateMirroredText:@"- 第一项" selection:NSMakeRange(5, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror.textView setSelectedRange:NSMakeRange(5, 0)];
                [controller.inputMirror.textView keyDown:shiftReturn];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"- 第一项\n- "], @"Shift+Enter on unordered list must continue unordered list");
                [controller.inputMirror.textView keyDown:tabKey];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"- 第一项\n  - "], @"Tab must indent to level-2 unordered list");
                [controller.inputMirror.textView keyDown:tabKey];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"- 第一项\n    - "], @"Second Tab must indent to level-3 unordered list");
                [controller.inputMirror.textView keyDown:deleteKey];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"- 第一项\n  - "], @"Backspace at level-3 prefix must outdent to level-2");
                [controller.inputMirror.textView keyDown:deleteKey];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"- 第一项\n- "], @"Backspace at level-2 prefix must outdent to level-1");
                [controller.inputMirror.textView keyDown:deleteKey];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"- 第一项\n"], @"Backspace at level-1 prefix must exit unordered list");

                // Unicode bullet cycling (• -> ◦ -> ▪) on Tab / Shift+Tab
                [controller.inputMirror updateMirroredText:@"• 主项" selection:NSMakeRange(4, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror.textView setSelectedRange:NSMakeRange(4, 0)];
                [controller.inputMirror.textView keyDown:shiftReturn];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"• 主项\n• "], @"Shift+Enter must preserve Unicode bullet");
                [controller.inputMirror.textView keyDown:tabKey];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"• 主项\n  ◦ "], @"Tab on • must cycle to level-2 ◦");
                [controller.inputMirror.textView keyDown:tabKey];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"• 主项\n    ▪ "], @"Second Tab on ◦ must cycle to level-3 ▪");
                [controller.inputMirror.textView keyDown:shiftTabKey];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"• 主项\n  ◦ "], @"Shift+Tab on ▪ must outdent back to ◦");

                // Non-empty nested item Backspace at prefix boundary preserves item text while outdenting
                [controller.inputMirror updateMirroredText:@"  - 子项" selection:NSMakeRange(4, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror.textView setSelectedRange:NSMakeRange(4, 0)];
                [controller.inputMirror.textView keyDown:deleteKey];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"- 子项"] && controller.inputMirror.textView.selectedRange.location == 2, @"Backspace at nested prefix boundary must outdent while keeping text");
                [controller.inputMirror.textView keyDown:deleteKey];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"子项"] && controller.inputMirror.textView.selectedRange.location == 0, @"Backspace at top-level prefix boundary must exit list while keeping text");

                // Empty nested item Shift+Enter outdents then exits
                [controller.inputMirror updateMirroredText:@"  - " selection:NSMakeRange(4, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror.textView setSelectedRange:NSMakeRange(4, 0)];
                [controller.inputMirror.textView keyDown:shiftReturn];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"- "], @"Shift+Enter on empty nested item must outdent");
                [controller.inputMirror.textView keyDown:shiftReturn];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@""], @"Shift+Enter on empty top-level item must exit list");

                // Ordered list & task list smart continuation + indent/outdent renumbering
                [controller.inputMirror updateMirroredText:@"1. 第一步" selection:NSMakeRange(6, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror.textView setSelectedRange:NSMakeRange(6, 0)];
                [controller.inputMirror.textView keyDown:shiftReturn];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"1. 第一步\n2. "], @"Shift+Enter on ordered list must auto-increment number");
                [controller.inputMirror.textView keyDown:tabKey];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"1. 第一步\n  1. "], @"Tab on ordered list must start sub-list at 1.");
                [controller.inputMirror.textView keyDown:shiftTabKey];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"1. 第一步\n2. "], @"Shift+Tab on ordered list must restore parent sequence number");

                [controller.inputMirror updateMirroredText:@"- [x] 已完成" selection:NSMakeRange(9, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror.textView setSelectedRange:NSMakeRange(9, 0)];
                [controller.inputMirror.textView keyDown:shiftReturn];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"- [x] 已完成\n- [ ] "], @"Shift+Enter on checked task item must create unchecked next task");

                // 7. Task jump suppression until next external mouse click
                [controller.inputMirror showPreviewSample];
                NSCAssert(controller.inputMirror.visible, @"Panel visible before task jump");
                [controller.inputMirror suppressAutoPopupUntilNextClick];
                NSCAssert(!controller.inputMirror.visible && controller.inputMirror.awaitingUserClickAfterJump, @"Task jump must hide mirror and suppress auto-popup until next click");
                [controller.inputMirror handleExternalMouseClick];
                NSCAssert(!controller.inputMirror.awaitingUserClickAfterJump, @"External mouse click must clear jump suppression");

                // 7b. IME placeholder hiding, auto-height growth clamp, Cmd+A select-all & 4 designer styles
                [controller.inputMirror updateMirroredText:@"" selection:NSMakeRange(0, 0) appName:@"Codex" appIcon:nil];
                NSCAssert(controller.inputMirror.textView.showingMirrorPlaceholder, @"Placeholder must show when empty");
                [controller.inputMirror.textView setMarkedText:@"nihao" selectedRange:NSMakeRange(5, 0) replacementRange:NSMakeRange(0, 0)];
                NSCAssert(!controller.inputMirror.textView.showingMirrorPlaceholder, @"Placeholder must hide immediately during Pinyin/IME composition");
                [controller.inputMirror.textView unmarkText];

                NSCAssert(InputMirrorTargetHeightForContentHeight(20) == 112.0, @"Short text must use compact min height");
                NSCAssert(InputMirrorTargetHeightForContentHeight(200) > 180.0 && InputMirrorTargetHeightForContentHeight(200) < 360.0, @"Multi-line text must grow height adaptively");
                NSCAssert(InputMirrorTargetHeightForContentHeight(900) == 360.0, @"Tall text must clamp to max height");

                [controller.inputMirror updateMirroredText:@"Select me all" selection:NSMakeRange(0, 0) appName:@"Codex" appIcon:nil];
                NSEvent *cmdA = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:0 context:nil characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:0];
                BOOL handledCmdA = [controller.inputMirror.textView performKeyEquivalent:cmdA];
                NSCAssert(handledCmdA && NSEqualRanges(controller.inputMirror.textView.selectedRange, NSMakeRange(0, 13)), @"Cmd+A must select all text in accessory app");

                NSCAssert(InputMirrorStyleTitles().count == 4 && controller.celebration.inputMirrorStyleControl.numberOfItems == 4, @"Must provide 4 selectable input mirror styles");
                [controller.celebration.inputMirrorStyleControl selectItemAtIndex:InputMirrorStyleTerminal];
                [controller.celebration changeSetting:controller.celebration.inputMirrorStyleControl];
                NSCAssert(controller.inputMirror.style == InputMirrorStyleTerminal, @"Style selector must update mirror style");
                CelebrationController *styleReloaded = [[CelebrationController alloc] initWithDirectory:DataDirectory()];
                NSCAssert([styleReloaded.settings[@"inputMirrorStyle"] integerValue] == InputMirrorStyleTerminal, @"Selected input mirror style must persist");

                // 7c. Slash / dollar skill autocomplete & native menu handoff
                NSString *parsedQuery = nil;
                InputMirrorSkillTrigger trig1 = InputMirrorParseSkillTrigger(@"/git", NSMakeRange(4, 0), &parsedQuery);
                NSCAssert(trig1.active && trig1.triggerChar == '/' && NSEqualRanges(trig1.tokenRange, NSMakeRange(0, 4)) && [parsedQuery isEqualToString:@"git"], @"Leading /query must trigger skill picker");
                InputMirrorSkillTrigger trig2 = InputMirrorParseSkillTrigger(@"请用 /prd 帮我写", NSMakeRange(7, 0), &parsedQuery);
                NSCAssert(trig2.active && trig2.triggerChar == '/' && NSEqualRanges(trig2.tokenRange, NSMakeRange(3, 4)) && [parsedQuery isEqualToString:@"prd"], @"Mid-sentence /query after space must trigger skill picker");
                InputMirrorSkillTrigger trig3 = InputMirrorParseSkillTrigger(@"https://example.com", NSMakeRange(19, 0), &parsedQuery);
                NSCAssert(!trig3.active, @"URL must not trigger skill picker");
                InputMirrorSkillTrigger trig4 = InputMirrorParseSkillTrigger(@"/Users/yeah", NSMakeRange(11, 0), &parsedQuery);
                NSCAssert(!trig4.active, @"File path must not trigger skill picker");
                InputMirrorSkillTrigger trig5 = InputMirrorParseSkillTrigger(@"$m5", NSMakeRange(3, 0), &parsedQuery);
                NSCAssert(trig5.active && trig5.triggerChar == '$' && [parsedQuery isEqualToString:@"m5"], @"Dollar trigger must activate skill picker");

                // Temp directory SKILL.md scanning & fuzzy/Chinese filtering
                NSString *tmpSkillHome = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"im-skill-test-%d", getpid()]];
                NSString *tmpGitSkillDir = [tmpSkillHome stringByAppendingPathComponent:@".codex/skills/git-sync"];
                NSString *tmpSysSkillDir = [tmpSkillHome stringByAppendingPathComponent:@".codex/skills/.system/imagegen"];
                [NSFileManager.defaultManager createDirectoryAtPath:tmpGitSkillDir withIntermediateDirectories:YES attributes:nil error:nil];
                [NSFileManager.defaultManager createDirectoryAtPath:tmpSysSkillDir withIntermediateDirectories:YES attributes:nil error:nil];
                [@"---\nname: git-sync\ndescription: 同步 GitHub 仓库与分支\n---\nBody" writeToFile:[tmpGitSkillDir stringByAppendingPathComponent:@"SKILL.md"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [@"---\nname: \"imagegen\"\ndescription: \"Generate bitmap visuals\"\n---\n" writeToFile:[tmpSysSkillDir stringByAppendingPathComponent:@"SKILL.md"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                NSArray<InputMirrorSkillItem *> *loadedSkills = InputMirrorLoadSkillsForApp(@"com.openai.codex", @"Codex", tmpSkillHome);
                NSCAssert(loadedSkills.count == 2, @"Must scan user and .system Codex skills");
                NSArray<InputMirrorSkillItem *> *fuzzyHits = InputMirrorFilterSkills(loadedSkills, @"gs");
                NSCAssert(fuzzyHits.count == 1 && [fuzzyHits.firstObject.name isEqualToString:@"git-sync"], @"Subsequence fuzzy match must find git-sync");
                NSArray<InputMirrorSkillItem *> *zhHits = InputMirrorFilterSkills(loadedSkills, @"仓库");
                NSCAssert(zhHits.count == 1 && [zhHits.firstObject.name isEqualToString:@"git-sync"], @"Chinese description search must match git-sync");
                [NSFileManager.defaultManager removeItemAtPath:tmpSkillHome error:nil];

                // Interactive popover selection, Esc dismissal & native handoff
                controller.inputMirror.overrideSkillsForTesting = loadedSkills;
                __block NSString *handoffCaptured = nil;
                controller.inputMirror.onNativeSlashHandoff = ^(NSString *text) {
                    handoffCaptured = text;
                };
                [controller.inputMirror showPreviewSample];
                [controller.inputMirror updateMirroredText:@"帮我 /git" selection:NSMakeRange(7, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:controller.inputMirror.textView]];
                NSCAssert(controller.inputMirror.skillMenuVisible, @"Typing /git must display skill picker popover");
                // Esc closes ONLY skill popover, not mirror panel
                NSEvent *escKey = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"\x1b" charactersIgnoringModifiers:@"\x1b" isARepeat:NO keyCode:53];
                [controller.inputMirror.textView keyDown:escKey];
                NSCAssert(!controller.inputMirror.skillMenuVisible && controller.inputMirror.visible, @"Esc must close only skill menu while keeping input mirror open");

                // Re-trigger and confirm with Enter -> inserts "$git-sync "
                [controller.inputMirror updateMirroredText:@"帮我 /g" selection:NSMakeRange(5, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:controller.inputMirror.textView]];
                [controller.inputMirror.textView setSelectedRange:NSMakeRange(5, 0)];
                [controller.inputMirror.textView insertText:@"i" replacementRange:NSMakeRange(NSNotFound, 0)];
                NSCAssert(controller.inputMirror.skillMenuVisible, @"Typing /gi must open skill menu");
                [controller.inputMirror.textView keyDown:plainReturn];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"帮我 $git-sync "], @"Enter on skill menu must replace /gi with $git-sync ");
                NSCAssert(!controller.inputMirror.skillMenuVisible && controller.inputMirror.visible, @"Confirming skill must close popover and keep panel open");

                // Unmatched /command still offers native handoff row and Enter triggers handoff
                [controller.inputMirror updateMirroredText:@"/model" selection:NSMakeRange(6, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:controller.inputMirror.textView]];
                NSCAssert(controller.inputMirror.skillMenuVisible, @"Unmatched /command must still show native handoff action");
                [controller.inputMirror.textView keyDown:plainReturn];
                NSCAssert([handoffCaptured isEqualToString:@"/model"] && !controller.inputMirror.visible, @"Confirming native handoff must pass /model and hide mirror panel");

                // Price like $100 must NOT open skill menu
                [controller.inputMirror showPreviewSample];
                [controller.inputMirror updateMirroredText:@"价格 $100" selection:NSMakeRange(7, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:controller.inputMirror.textView]];
                NSCAssert(!controller.inputMirror.skillMenuVisible, @"Unmatched $100 must not open skill popover");

                // Cmd+/ shortcut directly triggers native slash handoff with appended /
                handoffCaptured = nil;
                [controller.inputMirror updateMirroredText:@"请检查" selection:NSMakeRange(3, 0) appName:@"Codex" appIcon:nil];
                NSEvent *cmdSlash = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:0 context:nil characters:@"/" charactersIgnoringModifiers:@"/" isARepeat:NO keyCode:44];
                BOOL handledCmdSlash = [controller.inputMirror.textView performKeyEquivalent:cmdSlash];
                NSCAssert(handledCmdSlash && [handoffCaptured isEqualToString:@"请检查 /"], @"Cmd+/ must hand off to native slash menu with trailing /");
                controller.inputMirror.overrideSkillsForTesting = nil;
                controller.inputMirror.onNativeSlashHandoff = nil;

                // 7d. @ mention parsing, multi-app compatibility, workspace file discovery & native @ handoff
                InputMirrorSkillTrigger atTrig1 = InputMirrorParseSkillTrigger(@"@Input", NSMakeRange(6, 0), &parsedQuery);
                NSCAssert(atTrig1.active && atTrig1.triggerChar == '@' && NSEqualRanges(atTrig1.tokenRange, NSMakeRange(0, 6)) && [parsedQuery isEqualToString:@"Input"], @"Leading @query must trigger mention picker");
                InputMirrorSkillTrigger atTrig2 = InputMirrorParseSkillTrigger(@"帮我看看 @Sources/Input", NSMakeRange(19, 0), &parsedQuery);
                NSCAssert(atTrig2.active && atTrig2.triggerChar == '@' && NSEqualRanges(atTrig2.tokenRange, NSMakeRange(5, 14)) && [parsedQuery isEqualToString:@"Sources/Input"], @"@path/to/file with inner slash must trigger mention picker");
                InputMirrorSkillTrigger atTrig3 = InputMirrorParseSkillTrigger(@"帮我看看@Task", NSMakeRange(9, 0), &parsedQuery);
                NSCAssert(atTrig3.active && atTrig3.triggerChar == '@' && NSEqualRanges(atTrig3.tokenRange, NSMakeRange(4, 5)) && [parsedQuery isEqualToString:@"Task"], @"Chinese text followed directly by @query must trigger mention picker");
                InputMirrorSkillTrigger atTrigEmail = InputMirrorParseSkillTrigger(@"user@example.com", NSMakeRange(16, 0), &parsedQuery);
                NSCAssert(!atTrigEmail.active, @"Email address must not trigger @ mention picker");
                InputMirrorSkillTrigger atTrigEmail2 = InputMirrorParseSkillTrigger(@"foo.bar@test.io", NSMakeRange(15, 0), &parsedQuery);
                NSCAssert(!atTrigEmail2.active, @"Dotted email address must not trigger @ mention picker");

                // Multi-app built-in @ mentions & workspace file scanning
                NSString *tmpWsRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"im-mention-ws-%d", getpid()]];
                NSString *tmpSrcDir = [tmpWsRoot stringByAppendingPathComponent:@"Sources"];
                [NSFileManager.defaultManager createDirectoryAtPath:tmpSrcDir withIntermediateDirectories:YES attributes:nil error:nil];
                [@"int main() { return 0; }\n" writeToFile:[tmpSrcDir stringByAppendingPathComponent:@"InputMirror.m"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [@"# Readme\n" writeToFile:[tmpWsRoot stringByAppendingPathComponent:@"README.md"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

                NSArray<InputMirrorSkillItem *> *cursorMentions = InputMirrorLoadMentionsForApp(@"com.todesktop.230313mzl4w4u92", @"Cursor", tmpWsRoot);
                NSCAssert(InputMirrorFilterSkills(cursorMentions, @"Codebase").count >= 1, @"Cursor must provide built-in @Codebase mention");
                NSArray<InputMirrorSkillItem *> *fileHits = InputMirrorFilterSkills(cursorMentions, @"Input");
                NSCAssert(fileHits.count >= 1 && [fileHits.firstObject.name isEqualToString:@"Sources/InputMirror.m"] && [fileHits.firstObject.insertPrefix isEqualToString:@"@"], @"Basename prefix search must rank Sources/InputMirror.m first");

                NSArray<InputMirrorSkillItem *> *vscodeMentions = InputMirrorLoadMentionsForApp(@"com.microsoft.vscode", @"Visual Studio Code", tmpWsRoot);
                NSCAssert(InputMirrorFilterSkills(vscodeMentions, @"workspace").count >= 1, @"VS Code must provide built-in @workspace mention");
                NSArray<InputMirrorSkillItem *> *windsurfMentions = InputMirrorLoadMentionsForApp(@"com.exafunction.windsurf", @"Windsurf", tmpWsRoot);
                NSCAssert(InputMirrorFilterSkills(windsurfMentions, @"mcp").count >= 1, @"Windsurf must provide built-in @mcp mention");
                NSArray<InputMirrorSkillItem *> *traeMentions = InputMirrorLoadMentionsForApp(@"com.trae.app", @"TRAE", tmpWsRoot);
                NSCAssert(InputMirrorFilterSkills(traeMentions, @"Builder").count >= 1, @"TRAE must provide built-in @Builder mention");
                NSArray<InputMirrorSkillItem *> *codebuddyMentions = InputMirrorLoadMentionsForApp(@"com.tencent.codebuddy", @"CodeBuddy", tmpWsRoot);
                NSCAssert(InputMirrorFilterSkills(codebuddyMentions, @"codebase").count >= 1, @"CodeBuddy must provide built-in @codebase mention");
                NSArray<InputMirrorSkillItem *> *qoderMentions = InputMirrorLoadMentionsForApp(@"com.alibaba.qoder", @"Qoder", tmpWsRoot);
                NSCAssert(InputMirrorFilterSkills(qoderMentions, @"workspace").count >= 1, @"Qoder must provide built-in @workspace mention");
                NSArray<InputMirrorSkillItem *> *opencodeMentions = InputMirrorLoadMentionsForApp(@"ai.opencode.desktop", @"OpenCode", tmpWsRoot);
                NSCAssert(InputMirrorFilterSkills(opencodeMentions, @"explore").count >= 1, @"OpenCode must provide built-in @explore mention");
                NSArray<InputMirrorSkillItem *> *agMentions = InputMirrorLoadMentionsForApp(@"com.google.antigravity", @"Antigravity", tmpWsRoot);
                NSCAssert(InputMirrorFilterSkills(agMentions, @"README").count >= 1 && InputMirrorFilterSkills(agMentions, @"terminal").count >= 1, @"Antigravity must provide workspace files and @terminal mention without fake @Files text");
                NSArray<InputMirrorSkillItem *> *codexMentions = InputMirrorLoadMentionsForApp(@"com.openai.codex", @"Codex", tmpWsRoot);
                NSArray<InputMirrorSkillItem *> *codexImHits = InputMirrorFilterSkills(codexMentions, @"im");
                NSCAssert(codexImHits.count >= 1 && [codexImHits.firstObject.name isEqualToString:@"Sources/InputMirror.m"] && [codexImHits.firstObject.displayTitle isEqualToString:@"InputMirror.m"] && [codexImHits.firstObject.displayDetail isEqualToString:@"Sources/"], @"Codex @ mention must support camelCase acronym 'im' -> InputMirror.m with clean filename + directory detail");

                // Workspace root resolution from Codex global state & VSCode-style storage.json
                NSString *tmpResolverHome = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"im-ws-resolve-%d", getpid()]];
                NSString *tmpCodexDir = [tmpResolverHome stringByAppendingPathComponent:@".codex"];
                NSString *tmpCursorStorageDir = [tmpResolverHome stringByAppendingPathComponent:@"Library/Application Support/Cursor/User/globalStorage"];
                [NSFileManager.defaultManager createDirectoryAtPath:tmpCodexDir withIntermediateDirectories:YES attributes:nil error:nil];
                [NSFileManager.defaultManager createDirectoryAtPath:tmpCursorStorageDir withIntermediateDirectories:YES attributes:nil error:nil];
                NSDictionary *codexState = @{
                    @"electron-owner-value:selected-project:test": @{ @"type": @"local", @"projectId": @"proj-1" },
                    @"local-projects": @{ @"proj-1": @{ @"id": @"proj-1", @"rootPaths": @[tmpWsRoot] } }
                };
                NSData *codexStateData = [NSJSONSerialization dataWithJSONObject:codexState options:0 error:nil];
                [codexStateData writeToFile:[tmpCodexDir stringByAppendingPathComponent:@".codex-global-state.json"] atomically:YES];
                NSDictionary *cursorStorage = @{
                    @"windowsState": @{ @"lastActiveWindow": @{ @"folder": [NSURL fileURLWithPath:tmpWsRoot].absoluteString } }
                };
                NSData *cursorStorageData = [NSJSONSerialization dataWithJSONObject:cursorStorage options:0 error:nil];
                [cursorStorageData writeToFile:[tmpCursorStorageDir stringByAppendingPathComponent:@"storage.json"] atomically:YES];
                NSString *resolvedCodexWs = InputMirrorResolveWorkspaceRootForApp(@"com.openai.codex", @"Codex", tmpResolverHome);
                NSString *resolvedCursorWs = InputMirrorResolveWorkspaceRootForApp(@"com.todesktop.230313mzl4w4u92", @"Cursor", tmpResolverHome);
                NSCAssert([resolvedCodexWs isEqualToString:tmpWsRoot], @"Must resolve Codex active workspace root from .codex-global-state.json");
                NSCAssert([resolvedCursorWs isEqualToString:tmpWsRoot], @"Must resolve Cursor active workspace root from storage.json");

                // Also verify live .codex-global-state.sqlite takes priority over stale .codex-global-state.json
                NSString *tmpLiveWsRoot = [tmpResolverHome stringByAppendingPathComponent:@"live-codex-ws"];
                [NSFileManager.defaultManager createDirectoryAtPath:tmpLiveWsRoot withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *sqliteStatePath = [tmpCodexDir stringByAppendingPathComponent:@".codex-global-state.sqlite"];
                sqlite3 *testStateDB = NULL;
                if (sqlite3_open(sqliteStatePath.fileSystemRepresentation, &testStateDB) == SQLITE_OK && testStateDB) {
                    sqlite3_exec(testStateDB, "CREATE TABLE settings (scope TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (scope, key)) WITHOUT ROWID;", NULL, NULL, NULL);
                    NSString *selVal = @"{\"type\":\"local\",\"projectId\":\"live-proj\"}";
                    NSString *lpVal = [NSString stringWithFormat:@"{\"live-proj\":{\"id\":\"live-proj\",\"rootPaths\":[\"%@\"]}}", tmpLiveWsRoot];
                    NSString *insSql = [NSString stringWithFormat:@"INSERT INTO settings VALUES ('global','electron-owner-value:selected-project:u1','%@'),('global','local-projects','%@');", selVal, lpVal];
                    sqlite3_exec(testStateDB, insSql.UTF8String, NULL, NULL, NULL);
                    sqlite3_close(testStateDB);
                }
                NSString *resolvedLiveCodexWs = InputMirrorResolveWorkspaceRootForApp(@"com.openai.codex", @"ChatGPT", tmpResolverHome);
                NSCAssert([resolvedLiveCodexWs isEqualToString:tmpLiveWsRoot], @"Live .codex-global-state.sqlite must override stale .codex-global-state.json");
                [NSFileManager.defaultManager removeItemAtPath:tmpResolverHome error:nil];
                [NSFileManager.defaultManager removeItemAtPath:tmpWsRoot error:nil];

                // Interactive @ popover selection, unmatched native @ handoff & Cmd+Shift+2 shortcut
                controller.inputMirror.overrideMentionsForTesting = codexMentions;
                __block NSString *mentionHandoffCaptured = nil;
                controller.inputMirror.onNativeMentionHandoff = ^(NSString *text) {
                    mentionHandoffCaptured = text;
                };
                [controller.inputMirror showPreviewSample];
                [controller.inputMirror updateMirroredText:@"请检查 @Input" selection:NSMakeRange(10, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:controller.inputMirror.textView]];
                NSCAssert(controller.inputMirror.skillMenuVisible, @"Typing @Input must display mention picker popover");
                [controller.inputMirror.textView keyDown:plainReturn];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"请检查 @Sources/InputMirror.m "], @"Enter on @ mention menu must replace @Input with @Sources/InputMirror.m ");
                NSCAssert(!controller.inputMirror.skillMenuVisible && controller.inputMirror.visible, @"Confirming @ mention must close popover and keep panel open");

                // Unmatched @query offers native @ handoff and Enter triggers it
                [controller.inputMirror updateMirroredText:@"引用 @未命中项" selection:NSMakeRange(8, 0) appName:@"Antigravity" appIcon:nil];
                [controller.inputMirror textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:controller.inputMirror.textView]];
                NSCAssert(controller.inputMirror.skillMenuVisible, @"Unmatched @query must still show native @ handoff action");
                [controller.inputMirror.textView keyDown:plainReturn];
                NSCAssert([mentionHandoffCaptured isEqualToString:@"引用 @未命中项"] && !controller.inputMirror.visible, @"Confirming native @ handoff must pass @query and hide mirror panel");

                // Cmd+Shift+2 (Cmd+@) shortcut directly triggers native @ handoff with appended @
                mentionHandoffCaptured = nil;
                [controller.inputMirror showPreviewSample];
                [controller.inputMirror updateMirroredText:@"请检查" selection:NSMakeRange(3, 0) appName:@"Cursor" appIcon:nil];
                NSEvent *cmdAt = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:(NSEventModifierFlagCommand | NSEventModifierFlagShift) timestamp:0 windowNumber:0 context:nil characters:@"@" charactersIgnoringModifiers:@"2" isARepeat:NO keyCode:19];
                BOOL handledCmdAt = [controller.inputMirror.textView performKeyEquivalent:cmdAt];
                NSCAssert(handledCmdAt && [mentionHandoffCaptured isEqualToString:@"请检查 @"], @"Cmd+Shift+2 must hand off to native @ menu with trailing @");

                // Conversation @ mentions loaded from snapshot.json trigger native @ handoff on Enter
                NSString *tmpConvHome = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"im-conv-test-%d", getpid()]];
                NSString *tmpTaskMgrDir = [tmpConvHome stringByAppendingPathComponent:@".codex/task-manager"];
                [NSFileManager.defaultManager createDirectoryAtPath:tmpTaskMgrDir withIntermediateDirectories:YES attributes:nil error:nil];
                NSDictionary *snapPayload = @{
                    @"tasks": @[
                        @{ @"provider": @"antigravity", @"title": @"修复登录超时问题", @"project": @"Codex任务管理器", @"updated": @(2000.0) },
                        @{ @"provider": @"codex", @"title": @"Codex 独立会话", @"project": @"other", @"updated": @(3000.0) }
                    ],
                    @"history": @[
                        @{ @"provider": @"antigravity", @"title": @"优化输入镜像浮窗", @"project": @"Codex任务管理器", @"updated": @(1500.0) }
                    ]
                };
                NSData *snapData = [NSJSONSerialization dataWithJSONObject:snapPayload options:0 error:nil];
                [snapData writeToFile:[tmpTaskMgrDir stringByAppendingPathComponent:@"snapshot.json"] atomically:YES];
                NSArray<InputMirrorSkillItem *> *agConvs = InputMirrorLoadConversationMentionsForApp(@"com.google.antigravity", @"Antigravity", tmpConvHome);
                [NSFileManager.defaultManager removeItemAtPath:tmpConvHome error:nil];
                NSCAssert(agConvs.count == 2 && [agConvs.firstObject.name isEqualToString:@"修复登录超时问题"] && agConvs.firstObject.requiresNativeHandoff && [agConvs.firstObject.sourceLabel isEqualToString:@"对话"], @"Must load provider-filtered conversation mentions sorted by recency with requiresNativeHandoff");
                mentionHandoffCaptured = nil;
                controller.inputMirror.overrideMentionsForTesting = agConvs;
                [controller.inputMirror showPreviewSample];
                [controller.inputMirror updateMirroredText:@"请参考 @登录" selection:NSMakeRange(7, 0) appName:@"Antigravity" appIcon:nil];
                [controller.inputMirror textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:controller.inputMirror.textView]];
                NSCAssert(controller.inputMirror.skillMenuVisible, @"Typing @登录 must match conversation mention");
                [controller.inputMirror.textView keyDown:plainReturn];
                NSCAssert([mentionHandoffCaptured isEqualToString:@"请参考 @修复登录超时问题"] && !controller.inputMirror.visible, @"Selecting a conversation mention must hand off @<title> to native @ picker");

                // Conversation title with spaces must extract a space-free native query token without appending duplicate @
                InputMirrorSkillItem *spacedConv = [[InputMirrorSkillItem alloc] init];
                spacedConv.name = @"App Mention Feature Compatibility";
                spacedConv.summary = @"对话 · Codex任务管理器 · 回车在原应用绑定";
                spacedConv.insertPrefix = @"@";
                spacedConv.sourceLabel = @"对话";
                spacedConv.requiresNativeHandoff = YES;
                mentionHandoffCaptured = nil;
                controller.inputMirror.overrideMentionsForTesting = @[spacedConv];
                [controller.inputMirror showPreviewSample];
                [controller.inputMirror updateMirroredText:@"请参考 @Mention" selection:NSMakeRange(12, 0) appName:@"Antigravity" appIcon:nil];
                [controller.inputMirror textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:controller.inputMirror.textView]];
                NSCAssert(controller.inputMirror.skillMenuVisible, @"Typing @Mention must match spaced conversation title");
                [controller.inputMirror.textView keyDown:plainReturn];
                NSCAssert([mentionHandoffCaptured isEqualToString:@"请参考 @Compatibility"] && !controller.inputMirror.visible, @"Spaced conversation title must hand off a single space-free query token without duplicate @");

                controller.inputMirror.overrideMentionsForTesting = nil;
                controller.inputMirror.overrideWorkspaceRootForTesting = nil;
                controller.inputMirror.onNativeMentionHandoff = nil;

                // 7d-extra. Deep Codex & Antigravity @ and / parity: official slash commands, ~/.agents/skills, category tabs, CJK auto-space, capsule chips, atomic chip backspace & structured native segment replay
                NSArray<InputMirrorSkillItem *> *codexSlashCmds = InputMirrorLoadSlashCommandsForApp(@"com.openai.codex", @"Codex");
                NSCAssert(codexSlashCmds.count >= 20 && [InputMirrorFilterSkills(codexSlashCmds, @"审查").firstObject.name isEqualToString:@"review"] && [InputMirrorFilterSkills(codexSlashCmds, @"压缩").firstObject.name isEqualToString:@"compact"], @"Codex must expose official slash commands with Chinese keyword search");
                NSArray<InputMirrorSkillItem *> *agSlashCmds = InputMirrorLoadSlashCommandsForApp(@"com.google.antigravity", @"Antigravity");
                NSCAssert(agSlashCmds.count >= 10 && [InputMirrorFilterSkills(agSlashCmds, @"规划").firstObject.name isEqualToString:@"plan"] && [InputMirrorFilterSkills(agSlashCmds, @"浏览器").firstObject.name isEqualToString:@"browser"], @"Antigravity must expose official slash commands with Chinese keyword search");

                // ~/.agents/skills & workspace .agent/workflows discovery + Chinese display_name (agents/openai.yaml & # H1)
                NSString *tmpAgentsHome = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"im-agents-home-%d", getpid()]];
                NSString *tmpProdSkillDir = [tmpAgentsHome stringByAppendingPathComponent:@".agents/skills/prod-rd"];
                NSString *tmpProdAgentsDir = [tmpProdSkillDir stringByAppendingPathComponent:@"agents"];
                NSString *tmpTuntasSkillDir = [tmpAgentsHome stringByAppendingPathComponent:@".gemini/config/skills/tuntas-testing"];
                NSString *tmpAgWfDir = [tmpAgentsHome stringByAppendingPathComponent:@"ws/.agent/workflows"];
                [NSFileManager.defaultManager createDirectoryAtPath:tmpProdAgentsDir withIntermediateDirectories:YES attributes:nil error:nil];
                [NSFileManager.defaultManager createDirectoryAtPath:tmpTuntasSkillDir withIntermediateDirectories:YES attributes:nil error:nil];
                [NSFileManager.defaultManager createDirectoryAtPath:tmpAgWfDir withIntermediateDirectories:YES attributes:nil error:nil];
                [@"---\nname: prod-rd\ndescription: 生产研发全流程技能\n---\n# 多agent协同\n" writeToFile:[tmpProdSkillDir stringByAppendingPathComponent:@"SKILL.md"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [@"interface:\n  display_name: \"多agent协同\"\n  short_description: \"Antigravity 定方案，Codex 实施\"\n" writeToFile:[tmpProdAgentsDir stringByAppendingPathComponent:@"openai.yaml"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [@"---\nname: tuntas-testing\ndescription: 自动化回归测试\n---\n\n# Tuntas 日常功能回归测试技能\n" writeToFile:[tmpTuntasSkillDir stringByAppendingPathComponent:@"SKILL.md"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [@"---\ndescription: 发布工作流\n---\n# 线上发布核验\nSteps" writeToFile:[tmpAgWfDir stringByAppendingPathComponent:@"deploy-check.md"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                NSArray<InputMirrorSkillItem *> *codexSharedSkills = InputMirrorLoadSkillsForAppInWorkspace(@"com.openai.codex", @"Codex", nil, tmpAgentsHome);
                NSCAssert(codexSharedSkills.count == 1 && [codexSharedSkills.firstObject.name isEqualToString:@"prod-rd"] && [codexSharedSkills.firstObject.displayTitle isEqualToString:@"多agent协同"] && [codexSharedSkills.firstObject.displayDetail isEqualToString:@"$prod-rd"] && [codexSharedSkills.firstObject.insertPrefix isEqualToString:@"$"], @"Codex must parse Chinese display_name from agents/openai.yaml alongside $slug");
                NSCAssert([InputMirrorFilterSkills(codexSharedSkills, @"多agent").firstObject.name isEqualToString:@"prod-rd"] && [InputMirrorFilterSkills(codexSharedSkills, @"协同").firstObject.name isEqualToString:@"prod-rd"], @"Chinese display_name prefix and substring search must rank prod-rd first");
                NSArray<InputMirrorSkillItem *> *agWfSkills = InputMirrorLoadSkillsForAppInWorkspace(@"com.google.antigravity", @"Antigravity", [tmpAgentsHome stringByAppendingPathComponent:@"ws"], tmpAgentsHome);
                InputMirrorSkillItem *wfHit = InputMirrorFilterSkills(agWfSkills, @"线上发布").firstObject;
                InputMirrorSkillItem *tuntasHit = InputMirrorFilterSkills(agWfSkills, @"回归测试").firstObject;
                NSCAssert(wfHit != nil && [wfHit.name isEqualToString:@"deploy-check"] && [wfHit.displayTitle isEqualToString:@"线上发布核验"] && [wfHit.sourceLabel isEqualToString:@"工作流"], @"Antigravity must extract Chinese # H1 title for workflows");
                NSCAssert(tuntasHit != nil && [tuntasHit.name isEqualToString:@"tuntas-testing"] && [tuntasHit.displayTitle isEqualToString:@"Tuntas 日常功能回归测试技能"], @"Antigravity must extract Chinese # H1 title for SKILL.md without openai.yaml");
                [NSFileManager.defaultManager removeItemAtPath:tmpAgentsHome error:nil];

                // Category tabs on Codex '/' (commands + skills), auto-confirmed command handoff vs inline $skill chip
                controller.inputMirror.overrideSlashCommandsForTesting = codexSlashCmds;
                controller.inputMirror.overrideSkillsForTesting = codexSharedSkills;
                __block NSString *slashExecCaptured = nil;
                controller.inputMirror.onNativeSlashHandoff = ^(NSString *text) {
                    slashExecCaptured = text;
                };
                [controller.inputMirror reconcileExternalFocusText:@"" selection:NSMakeRange(0, 0) bundleID:@"com.openai.codex" appName:@"Codex" pid:42001 appIcon:nil sameTarget:NO];
                [controller.inputMirror showPreviewSample];
                [controller.inputMirror updateMirroredText:@"/" selection:NSMakeRange(1, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:controller.inputMirror.textView]];
                NSArray<NSString *> *slashCats = controller.inputMirror.availableSkillMenuCategories;
                NSCAssert(controller.inputMirror.skillMenuVisible && [slashCats containsObject:@"commands"] && [slashCats containsObject:@"skills"], @"Codex '/' menu must expose commands and skills category tabs");
                NSEvent *optRight = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagOption timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:124];
                [controller.inputMirror.textView keyDown:optRight];
                NSCAssert([controller.inputMirror.activeSkillMenuCategoryKey isEqualToString:@"commands"], @"Option+Right must switch category tab to commands");
                [controller.inputMirror.textView keyDown:optRight];
                NSCAssert([controller.inputMirror.activeSkillMenuCategoryKey isEqualToString:@"skills"], @"Second Option+Right must switch category tab to skills");
                [controller.inputMirror.textView keyDown:plainReturn];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"$prod-rd "] && [controller.inputMirror.confirmedChipTokens containsObject:@"$prod-rd"], @"Confirming skill under '/' in Codex must insert $prod-rd chip and keep mirror open");

                // Confirming Codex built-in '/compact' command triggers auto-confirmed native handoff
                [controller.inputMirror updateMirroredText:@"/compact" selection:NSMakeRange(8, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:controller.inputMirror.textView]];
                [controller.inputMirror.textView keyDown:plainReturn];
                NSCAssert([slashExecCaptured isEqualToString:@"/compact"] && controller.inputMirror.lastNativeHandoffAutoConfirmed && !controller.inputMirror.visible, @"Selecting Codex /compact command must trigger auto-confirmed native execution");
                controller.inputMirror.overrideSlashCommandsForTesting = nil;
                controller.inputMirror.overrideSkillsForTesting = nil;
                controller.inputMirror.onNativeSlashHandoff = nil;

                // CJK auto-spacing before @chip, capsule chip attributes, atomic chip backspace & multi-chip sync segments
                InputMirrorSkillItem *mockFileItem = [[InputMirrorSkillItem alloc] init];
                mockFileItem.name = @"Sources/InputMirror.m";
                mockFileItem.displayTitle = @"InputMirror.m";
                mockFileItem.displayDetail = @"Sources/";
                mockFileItem.insertPrefix = @"@";
                mockFileItem.sourceLabel = @"文件";
                mockFileItem.categoryKey = @"files";
                mockFileItem.itemKind = InputMirrorItemKindFile;
                controller.inputMirror.overrideMentionsForTesting = @[mockFileItem];
                [controller.inputMirror showPreviewSample];
                [controller.inputMirror updateMirroredText:@"请检查@Input" selection:NSMakeRange(9, 0) appName:@"Codex" appIcon:nil];
                [controller.inputMirror textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:controller.inputMirror.textView]];
                [controller.inputMirror.textView keyDown:tabKey];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"请检查 @Sources/InputMirror.m "], @"Tab on CJK-adjacent @Input must auto-insert a space before @Sources/InputMirror.m chip");
                NSColor *chipAttr = [controller.inputMirror.textView.textStorage attribute:InputMirrorChipColorAttributeName atIndex:5 effectiveRange:NULL];
                NSCAssert(chipAttr != nil, @"Confirmed @ mention must carry capsule chip border styling");

                // Verify structured sync segments with both $skill and @file chips
                NSSet<NSString *> *testChipTokens = [NSSet setWithArray:@[@"$prod-rd", @"@Sources/InputMirror.m"]];
                NSArray<InputMirrorSyncSegment *> *segs = InputMirrorBuildSyncSegments(@"请用 $prod-rd 检查 @Sources/InputMirror.m 的逻辑", testChipTokens);
                NSCAssert(segs.count == 5 && !segs[0].isNativeChip && [segs[0].text isEqualToString:@"请用 "] &&
                          segs[1].isNativeChip && segs[1].triggerChar == '$' && [segs[1].text isEqualToString:@"prod-rd"] && segs[1].consumesTrailingSpace &&
                          !segs[2].isNativeChip && [segs[2].text isEqualToString:@"检查 "] &&
                          segs[3].isNativeChip && segs[3].triggerChar == '@' && [segs[3].text isEqualToString:@"Sources/InputMirror.m"] && segs[3].consumesTrailingSpace &&
                          !segs[4].isNativeChip && [segs[4].text isEqualToString:@"的逻辑"],
                          @"Sync segment builder must split plain text and native @/$ chips while consuming auto-inserted trailing space");

                // Atomic single-Backspace deletion of confirmed @Sources/InputMirror.m chip
                [controller.inputMirror.textView keyDown:deleteKey];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"请检查 "], @"Single Backspace after confirmed @chip must atomically delete the entire chip");
                controller.inputMirror.overrideMentionsForTesting = nil;

                // 7e. Draft protection across Space switch, focus loss, multi-app switching & false likelySent prevention
                controller.inputMirror.onSyncBack = nil;
                BOOL sent0 = [controller.inputMirror reconcileExternalFocusText:@""
                                                                      selection:NSMakeRange(0, 0)
                                                                       bundleID:@"com.openai.codex"
                                                                        appName:@"Codex"
                                                                            pid:41001
                                                                        appIcon:nil
                                                                     sameTarget:NO];
                NSCAssert(!sent0, @"Initial empty focus must not be treated as sent");
                [controller.inputMirror.panel orderFrontRegardless];
                [controller.inputMirror.textView setString:@"这是一段很长的输入内容，切桌面绝对不能丢"];
                [controller.inputMirror.textView setSelectedRange:NSMakeRange(8, 0)];
                [controller.inputMirror textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:controller.inputMirror.textView]];
                NSCAssert(controller.inputMirror.hasUnsyncedEdits, @"Typing in mirror must mark unsynced edits");
                NSCAssert([[controller.inputMirror savedDraftTextForBundleID:@"com.openai.codex" appName:@"Codex" pid:41001] isEqualToString:@"这是一段很长的输入内容，切桌面绝对不能丢"], @"Typing in mirror must immediately persist draft for target app");

                // Losing key focus (e.g. clicking outside) must NOT wipe text or falsely trigger likelySent on empty AX read
                [controller.inputMirror windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:controller.inputMirror.panel]];
                BOOL sentAfterResign = [controller.inputMirror reconcileExternalFocusText:@""
                                                                              selection:NSMakeRange(0, 0)
                                                                               bundleID:@"com.openai.codex"
                                                                                appName:@"Codex"
                                                                                    pid:41001
                                                                                appIcon:nil
                                                                             sameTarget:YES];
                NSCAssert(!sentAfterResign, @"Empty AX read while unsynced draft exists must NEVER trigger likelySent");
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"这是一段很长的输入内容，切桌面绝对不能丢"], @"Resign + empty AX poll must preserve typed text");

                // Desktop / Space switch hides panel cleanly but preserves draft; returning to AI app restores exact text & cursor
                [controller.inputMirror handleActiveSpaceChange];
                NSCAssert(!controller.inputMirror.visible, @"Space switch must hide floating mirror cleanly");
                NSCAssert([[controller.inputMirror savedDraftTextForBundleID:@"com.openai.codex" appName:@"Codex" pid:41001] isEqualToString:@"这是一段很长的输入内容，切桌面绝对不能丢"], @"Space switch must preserve unsynced draft");
                BOOL sentAfterSpace = [controller.inputMirror reconcileExternalFocusText:@""
                                                                             selection:NSMakeRange(0, 0)
                                                                              bundleID:@"com.openai.codex"
                                                                               appName:@"Codex"
                                                                                   pid:41001
                                                                               appIcon:nil
                                                                            sameTarget:NO];
                NSCAssert(!sentAfterSpace && [controller.inputMirror.textView.string isEqualToString:@"这是一段很长的输入内容，切桌面绝对不能丢"] && controller.inputMirror.textView.selectedRange.location == 8 && controller.inputMirror.hasUnsyncedEdits, @"Returning after Space switch must restore exact draft, cursor position, and pending sync flag");

                // Multi-app isolation: switching to Antigravity keeps Codex draft intact and maintains Antigravity's own draft
                [controller.inputMirror reconcileExternalFocusText:@""
                                                         selection:NSMakeRange(0, 0)
                                                          bundleID:@"com.google.antigravity"
                                                           appName:@"Antigravity"
                                                               pid:41002
                                                           appIcon:nil
                                                        sameTarget:NO];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@""], @"Switching to a different AI app without a draft must start clean");
                [controller.inputMirror.textView setString:@"Antigravity 独立草稿"];
                [controller.inputMirror.textView setSelectedRange:NSMakeRange(16, 0)];
                [controller.inputMirror textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:controller.inputMirror.textView]];
                // Switch back to Codex -> Codex draft restored
                [controller.inputMirror reconcileExternalFocusText:@""
                                                         selection:NSMakeRange(0, 0)
                                                          bundleID:@"com.openai.codex"
                                                           appName:@"Codex"
                                                               pid:41001
                                                           appIcon:nil
                                                        sameTarget:NO];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"这是一段很长的输入内容，切桌面绝对不能丢"], @"Switching back to Codex must restore Codex draft");
                // Switch back to Antigravity -> Antigravity draft restored
                [controller.inputMirror reconcileExternalFocusText:@""
                                                         selection:NSMakeRange(0, 0)
                                                          bundleID:@"com.google.antigravity"
                                                           appName:@"Antigravity"
                                                               pid:41002
                                                           appIcon:nil
                                                        sameTarget:NO];
                NSCAssert([controller.inputMirror.textView.string isEqualToString:@"Antigravity 独立草稿"], @"Switching back to Antigravity must restore Antigravity draft");

                // Deliberately deleting all text clears the draft (must not resurrect deleted text)
                [controller.inputMirror.textView setString:@""];
                [controller.inputMirror textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:controller.inputMirror.textView]];
                NSCAssert([controller.inputMirror savedDraftTextForBundleID:@"com.google.antigravity" appName:@"Antigravity" pid:41002] == nil, @"Clearing all text in mirror must clear saved draft");

                // Sending via Enter clears Codex draft
                [controller.inputMirror reconcileExternalFocusText:@""
                                                         selection:NSMakeRange(0, 0)
                                                          bundleID:@"com.openai.codex"
                                                           appName:@"Codex"
                                                               pid:41001
                                                           appIcon:nil
                                                        sameTarget:NO];
                __block NSString *draftSentText = nil;
                controller.inputMirror.onSyncBack = ^(NSString *text, BOOL shouldSend) {
                    if (shouldSend) draftSentText = text;
                };
                [controller.inputMirror syncAndSend];
                NSCAssert([draftSentText isEqualToString:@"这是一段很长的输入内容，切桌面绝对不能丢"], @"Enter after draft restore must send the full restored draft");
                NSCAssert([controller.inputMirror savedDraftTextForBundleID:@"com.openai.codex" appName:@"Codex" pid:41001] == nil, @"Sending must clear saved draft");
                controller.inputMirror.onSyncBack = nil;

                // 8. Auto-collapse (single-screen mode): default OFF, hover expand, 10s idle collapse, task change expand
                NSCAssert(![controller isAutoCollapseEnabled], @"Auto-collapse must be disabled by default");
                NSCAssert(controller.celebration.autoCollapseCheckbox != nil && controller.celebration.autoCollapseCheckbox.state == NSControlStateValueOff, @"Auto-collapse checkbox must be present and unchecked by default");
                controller.autoCollapseDelay = 0.08;
                controller.hoverExitCollapseDelay = 0.05;
                controller.collapsed = NO;
                controller.celebration.autoCollapseCheckbox.state = NSControlStateValueOn;
                [controller.celebration changeSetting:controller.celebration.autoCollapseCheckbox];
                NSCAssert([controller isAutoCollapseEnabled] && controller.collapsed, @"Enabling auto-collapse must collapse the panel by default");
                CelebrationController *autoCollapseReloaded = [[CelebrationController alloc] initWithDirectory:DataDirectory()];
                NSCAssert([autoCollapseReloaded.settings[@"autoCollapsePanel"] boolValue], @"Auto-collapse setting must persist");

                // Hover enter expands, hover exit shrinks after idle delay
                [controller panelPointerDidEnter];
                NSCAssert(!controller.collapsed && controller.pointerInsidePanel, @"Pointer enter must expand the list");
                [controller panelPointerDidExit];
                NSCAssert(!controller.collapsed && !controller.pointerInsidePanel, @"Pointer exit must keep list open during idle grace period");
                NSDate *collapseDeadline1 = [NSDate dateWithTimeIntervalSinceNow:0.5];
                while (!controller.collapsed && collapseDeadline1.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
                NSCAssert(controller.collapsed, @"Panel must automatically collapse after idle timeout");

                // Task status change expands and collapses again after idle timeout
                NSString *snapPath = [DataDirectory() stringByAppendingPathComponent:@"snapshot.json"];
                NSDictionary *snap1 = @{@"tasks":@[@{@"id":@"t1",@"turn":@"1",@"status":@"running",@"title":@"Task 1"}],@"history":@[]};
                [[NSJSONSerialization dataWithJSONObject:snap1 options:0 error:NULL] writeToFile:snapPath atomically:YES];
                controller.signature = nil;
                controller.preview = NO; [controller refresh]; controller.preview = YES;
                NSCAssert(controller.collapsed, @"Initial snapshot in auto-collapse mode must remain collapsed");
                NSDictionary *snap2 = @{@"tasks":@[@{@"id":@"t1",@"turn":@"1",@"status":@"waiting",@"title":@"Task 1"}],@"history":@[]};
                [[NSJSONSerialization dataWithJSONObject:snap2 options:0 error:NULL] writeToFile:snapPath atomically:YES];
                controller.preview = NO; [controller refresh]; controller.preview = YES;
                NSCAssert(!controller.collapsed, @"Task status change must automatically expand the list");
                NSDate *collapseDeadline2 = [NSDate dateWithTimeIntervalSinceNow:0.5];
                while (!controller.collapsed && collapseDeadline2.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
                NSCAssert(controller.collapsed, @"Panel must automatically collapse again after task-change idle timeout");

                // Cleanup test defaults
                [NSUserDefaults.standardUserDefaults removeObjectForKey:@"InputMirrorUITestFrame"];
                [NSUserDefaults.standardUserDefaults removeObjectForKey:@"InputMirrorUITestScreenID"];
                [controller.inputMirror stop];
                [controller.celebration.settingsWindow orderOut:nil];
                [controller.panel orderOut:nil];
                puts("Input mirror UI passed: default OFF, secure exclusion, settings toggle persistence, rich list formatting, direct delete/newline/cursor, cross-screen position memory and auto-close on send");
                return 0;
            }
            if ([args containsObject:@"--ui-test"]) {
                NSCAssert([controller.celebration.settings[@"enabled"] boolValue] && [controller.celebration.settings[@"style"] integerValue] == CelebrationRandomStyle, @"New installs must enable random effects by default");
                NSCAssert([controller.celebration.settings[@"theme"] integerValue] == PanelThemeDark &&
                    PanelIsDark(controller.panel.effectiveAppearance), @"New installs must use dark appearance");
                NSInteger styleCount = (NSInteger)CelebrationStyleTitles().count;
                NSCAssert(styleCount == 10, @"Offer five new interactions alongside the original effects");
                NSString *legacyDirectory = [DataDirectory() stringByAppendingPathComponent:@"legacy-settings"];
                [NSFileManager.defaultManager createDirectoryAtPath:legacyDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
                NSDictionary *legacySettings = @{@"style":@5,@"duration":@4,@"opacity":@0.9,@"showStatusItem":@NO};
                NSString *legacyPath = [legacyDirectory stringByAppendingPathComponent:@"settings.json"];
                [[NSJSONSerialization dataWithJSONObject:legacySettings options:0 error:NULL] writeToFile:legacyPath atomically:YES];
                CelebrationController *migrated = [[CelebrationController alloc] initWithDirectory:legacyDirectory];
                NSCAssert([migrated.settings[@"style"] integerValue] == CelebrationRandomStyle && ![migrated.settings[@"showStatusItem"] boolValue], @"Unsupported effects use random playback and preserve visibility settings");
                for (NSNumber *oldStyle in @[@0,@2]) {
                    NSDictionary *versionTwo = @{@"style":oldStyle,@"styleVersion":@2};
                    [[NSJSONSerialization dataWithJSONObject:versionTwo options:0 error:NULL] writeToFile:legacyPath atomically:YES];
                    migrated = [[CelebrationController alloc] initWithDirectory:legacyDirectory];
                    NSInteger expected = oldStyle.integerValue == 0 ? CelebrationRandomStyle : oldStyle.integerValue;
                    NSCAssert([migrated.settings[@"style"] integerValue] == expected, @"Migrate the old default while retaining explicitly selected non-default styles");
                }
                NSRect smallDisplay = NSMakeRect(-700,-150,510,320);
                NSCAssert(NSContainsRect(smallDisplay, CelebrationOverlayFrame(smallDisplay)), @"Keep the raised overlay inside small displays with an offset origin");
                NSArray<NSString *> *messages = CelebrationMessages();
                NSCAssert(messages.count == 150 && [NSSet setWithArray:messages].count == 150, @"Completion copy must contain exactly 150 unique reminders");
                NSString *previousMessage = nil;
                for (NSInteger i=0;i<1000;i++) {
                    NSString *message = CelebrationRandomMessage(previousMessage);
                    NSCAssert([messages containsObject:message] && ![message isEqual:previousMessage], @"Random reminders must be valid and avoid adjacent repeats");
                    previousMessage = message;
                }
                for (NSInteger style=0;style<styleCount;style++) {
                    CelebrationTestView *scene = [[CelebrationTestView alloc] initWithFrame:NSMakeRect(0,0,600,460)];
                    scene.duration = 4; scene.stillFrame = YES; scene.style = style;
                    scene.intensity = 0.8; scene.message = messages[73];
                    NSBitmapImageRep *card = RenderCelebration(scene);
                    NSColor *surface = [[card colorAtX:100 y:100] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
                    NSCAssert(fabs(surface.alphaComponent-0.9) < 0.02 && surface.redComponent < 0.3 && surface.blueComponent < 0.35 && [card colorAtX:0 y:0].alphaComponent < 0.01, @"Game scenes must use a 90 percent background with clear rounded corners");
                    for (NSValue *corner in @[[NSValue valueWithPoint:NSMakePoint(2,2)],[NSValue valueWithPoint:NSMakePoint(597,2)],[NSValue valueWithPoint:NSMakePoint(2,457)],[NSValue valueWithPoint:NSMakePoint(597,457)]]) {
                        NSPoint point = corner.pointValue;
                        NSCAssert([card colorAtX:point.x y:point.y].alphaComponent < 0.01, @"All four rendered corners must be transparent");
                    }
                    NSCAssert([card colorAtX:0 y:230].alphaComponent > 0.88 && [card colorAtX:300 y:0].alphaComponent > 0.88, @"Rounded clipping must retain the straight edge midpoints");
                    if (style >= 5) {
                        NSData *idle = [card representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                        scene.testPointer = [NSValue valueWithPoint:NSMakePoint(154,238)];
                        NSData *hover = [RenderCelebration(scene) representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                        NSCAssert(![idle isEqual:hover], @"Each new effect must react to the pointer");
                        scene.reducedMotion = YES;
                        NSData *staticHover = [RenderCelebration(scene) representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                        scene.testPointer = nil;
                        NSData *staticIdle = [RenderCelebration(scene) representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                        NSCAssert([staticHover isEqual:staticIdle], @"Reduced motion must suppress pointer-driven motion");
                    }
                }
                puts("Ten scenes passed drawing checks. Five new scenes respond to the pointer and respect reduced motion.");
                NSCAssert(controller.tasks.count == 3, @"All three states must be visible");
                CGFloat initialHeight = controller.panel.frame.size.height;
                NSScrollView *scroll = nil;
                for (NSView *view in controller.panel.contentView.subviews) if ([view isKindOfClass:NSScrollView.class]) scroll = (NSScrollView *)view;
                NSView *row = scroll.documentView.subviews.firstObject;
                TaskButton *button = nil;
                for (NSView *view in row.subviews) if ([view isKindOfClass:TaskButton.class]) button = (TaskButton *)view;
                NSCAssert(button && row.subviews.count == 2, @"Each row has only a status dot and clickable title");
                NSView *dot = row.subviews.firstObject;
                NSCAssert(fabs(NSMidY(dot.frame)-NSMidY(button.frame)) < 0.1, @"Dot and title must share a vertical center");
                for (NSView *taskRow in scroll.documentView.subviews) {
                    for (NSView *view in taskRow.subviews) {
                        if ([view isKindOfClass:TaskButton.class] && [((TaskButton *)view).threadID isEqual:@"preview-running"]) button = (TaskButton *)view;
                    }
                }
                [button performClick:nil];
                NSCAssert(controller.tasks.count == 3 && !controller.removingTasks.count, @"Running tasks must remain after navigation");
                NSCAssert(!ReadJSON(@"dismissed.json")[@"preview-running"], @"Running navigation must not persist a dismissal");
                NSCAssert(controller.panel.frame.size.height == initialHeight, @"Running navigation must preserve panel height");
                NSUInteger expectedCount = 3;
                for (NSString *threadID in @[@"preview-input", @"preview-done"]) {
                    for (NSView *view in controller.panel.contentView.subviews) if ([view isKindOfClass:NSScrollView.class]) scroll = (NSScrollView *)view;
                    button = nil;
                    for (NSView *taskRow in scroll.documentView.subviews) {
                        for (NSView *view in taskRow.subviews) {
                            if ([view isKindOfClass:TaskButton.class] && [((TaskButton *)view).threadID isEqual:threadID]) button = (TaskButton *)view;
                        }
                    }
                    NSCAssert(button, @"Task must be available for navigation");
                    [button performClick:nil];
                    NSCAssert([controller.removingTasks containsObject:threadID], @"Waiting and completed navigation must start disappearance animation");
                    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
                    while (controller.removingTasks.count && deadline.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
                    expectedCount--;
                    NSCAssert(controller.tasks.count == expectedCount, @"Waiting and completed navigation must remove the clicked row");
                }
                NSCAssert(controller.panel.frame.size.height < initialHeight, @"Panel must shrink after removal");
                NSCAssert([ReadJSON(@"dismissed.json")[@"preview-input"] isEqual:@"one"], @"Waiting dismissal must persist");
                NSCAssert([ReadJSON(@"dismissed.json")[@"preview-done"] isEqual:@"three:completed"], @"Completed dismissal must persist");
                controller.tasks = @[]; [controller rebuild];
                NSCAssert(!controller.collapsed, @"An explicitly expanded empty panel must keep history reachable");
                controller.collapsed = YES; [controller rebuild];
                controller.tasks = @[@{@"id":@"new", @"status":@"running", @"title":@"新任务"}];
                [controller toggleCollapsed:nil];
                NSCAssert(!controller.collapsed, @"Tasks can expand");
                [controller toggleCollapsed:nil];
                NSCAssert(controller.panel.frame.size.height == 40, @"Collapsed height");
                NSDictionary *incoming = @{@"tasks":@[@{@"id":@"fresh",@"turn":@"next",@"status":@"running",@"title":@"新任务"}]};
                NSData *snapshot = [NSJSONSerialization dataWithJSONObject:incoming options:0 error:NULL];
                [snapshot writeToFile:[DataDirectory() stringByAppendingPathComponent:@"snapshot.json"] atomically:YES];
                controller.dismissed[@"fresh"] = @"next";
                controller.preview = NO;
                [controller refresh];
                NSCAssert(!controller.collapsed && controller.tasks.count == 1, @"New activity must automatically expand");
                controller.preview = YES;
                NSDictionary *completed = @{@"tasks":@[@{@"id":@"fresh",@"turn":@"next",@"status":@"completed",@"title":@"新任务"}]};
                [[NSJSONSerialization dataWithJSONObject:completed options:0 error:NULL] writeToFile:[DataDirectory() stringByAppendingPathComponent:@"snapshot.json"] atomically:YES];
                controller.celebration.settings[@"enabled"] = @YES;
                controller.celebration.settings[@"duration"] = @1;
                NSWindow *previousKey = NSApp.keyWindow;
                controller.preview = NO; [controller refresh]; controller.preview = YES;
                NSCAssert(controller.celebration.overlays.count == 1, @"Completion transition must launch celebration");
                NSPanel *overlay = controller.celebration.overlays.firstObject;
                NSCAssert(fabs(overlay.alphaValue-1) < 0.001, @"Completion window must be fully opaque");
                NSCAssert(overlay.ignoresMouseEvents && !overlay.opaque, @"Artwork must be transparent and click-through");
                NSRect displayFrame = (controller.panel.screen ?: NSScreen.mainScreen).visibleFrame;
                CGFloat targetY = NSMaxY(displayFrame) - NSHeight(displayFrame) / 3;
                NSCAssert(fabs(NSMidX(overlay.frame)-NSMidX(displayFrame)) < 1 && fabs(NSMidY(overlay.frame)-targetY) < 1, @"Celebration must sit one third down the visible display");
                NSCAssert(overlay.frame.size.width <= 440 && overlay.frame.size.height <= 340, @"Completion must use a compact panel");
                CelebrationView *artwork = (CelebrationView *)overlay.contentView.subviews.lastObject;
                NSCAssert([overlay.contentView isKindOfClass:NSVisualEffectView.class] && ((NSVisualEffectView *)overlay.contentView).blendingMode == NSVisualEffectBlendingModeBehindWindow, @"Live completion must use the system frosted background");
                NSVisualEffectView *glass = (NSVisualEffectView *)overlay.contentView;
                NSCAssert(glass.maskImage && glass.layer.cornerRadius >= 25 && artwork.layer.cornerRadius == CelebrationArtworkCornerRadius, @"Backdrop and artwork must share prominent scaled rounded corners");
                NSCAssert(artwork.frame.size.width <= 600 && artwork.frame.size.height <= 460, @"Main artwork must stay compact");
                NSCAssert(artwork.alphaValue == 1, @"Artwork must remain fully opaque");
                NSCAssert([CelebrationMessages() containsObject:artwork.message], @"Completion must draw a random reminder");
                NSString *completionMessage = artwork.message;
                NSInteger firstStyle = artwork.style;
                NSCAssert(firstStyle >= 0 && firstStyle < styleCount, @"A random celebration must resolve to a playable effect");
                NSCAssert(NSApp.keyWindow == previousKey, @"Celebration must preserve keyboard focus");
                controller.preview = NO; [controller refresh]; controller.preview = YES;
                NSCAssert(controller.celebration.overlays.firstObject == overlay, @"Duplicate refresh must not restart celebration");
                NSCAssert([artwork.message isEqual:completionMessage] && artwork.style == firstStyle, @"Redraws and duplicate events must keep the same reminder and effect");
                NSDate *effectDeadline = [NSDate dateWithTimeIntervalSinceNow:1.3];
                while (controller.celebration.overlays.count && effectDeadline.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
                NSCAssert(!controller.celebration.overlays.count && !controller.celebration.animationTimer, @"Celebration must release windows and timer at deadline");
                [controller.celebration showOnScreen:NSScreen.mainScreen];
                CelebrationView *nextArtwork = (CelebrationView *)controller.celebration.overlays.firstObject.contentView.subviews.lastObject;
                NSCAssert(nextArtwork && nextArtwork.style != firstStyle, @"Consecutive random celebrations must use different effects");
                [controller.celebration stop];
                controller.celebration.settings[@"enabled"] = @NO;
                [controller.celebration showOnScreen:NSScreen.mainScreen];
                NSCAssert(!controller.celebration.overlays.count, @"Disabled celebration must stay hidden");
                BOOL wasPanelVisible = controller.panel.visible;
                [controller.statusItem.button performClick:nil];
                NSCAssert(controller.celebration.settingsWindow.visible && [controller.celebration.settingsWindow.title containsString:@"主面板"], @"Menu bar click opens the main panel");
                NSCAssert(controller.panel.visible == wasPanelVisible, @"Opening the control panel preserves the floating panel visibility");
                NSMenu *statusMenu = [controller statusMenu];
                NSCAssert(statusMenu.numberOfItems >= 4, @"Status menu must expose main panel, quick toggles, update check and quit");
                NSCAssert(statusMenu.itemArray.firstObject.action == @selector(showMainPanel:) && statusMenu.itemArray.lastObject.action == @selector(quitApplication:), @"Status menu must start with main panel and end with quit");
                NSPopUpButton *themeControl = nil;
                for (NSView *view in controller.celebration.settingsWindow.contentView.subviews) {
                    if ([view isKindOfClass:NSPopUpButton.class] && [(NSPopUpButton *)view action] == @selector(changeTheme:))
                        themeControl = (NSPopUpButton *)view;
                }
                NSCAssert(themeControl.numberOfItems == 3 && themeControl.indexOfSelectedItem == PanelThemeDark, @"The main panel initially selects dark from all three themes");
                [themeControl selectItemAtIndex:PanelThemeLight];
                [themeControl sendAction:themeControl.action to:themeControl.target];
                NSCAssert(!PanelIsDark(controller.panel.effectiveAppearance) &&
                    !PanelIsDark(controller.celebration.settingsWindow.effectiveAppearance), @"Light applies to both windows immediately");
                NSMenu *themeMenu = [controller.panel.contentView.menu itemWithTitle:@"界面主题"].submenu;
                NSCAssert(themeMenu.itemArray[PanelThemeLight].state == NSControlStateValueOn, @"The floating menu tracks selection in the main panel");
                NSMenuItem *systemTheme = themeMenu.itemArray[PanelThemeSystem];
                [NSApp sendAction:systemTheme.action to:systemTheme.target from:systemTheme];
                CelebrationController *themeRestored = [[CelebrationController alloc] initWithDirectory:DataDirectory()];
                NSCAssert(NSApp.appearance == nil && themeControl.indexOfSelectedItem == PanelThemeSystem &&
                    [themeRestored.settings[@"theme"] integerValue] == PanelThemeSystem, @"System theme follows macOS and persists from the floating menu");
                [themeControl selectItemAtIndex:PanelThemeDark];
                [themeControl sendAction:themeControl.action to:themeControl.target];
                NSButton *statusControl = nil;
                NSButton *historyButton = nil;
                NSButton *integrationsButton = nil;
                NSButton *antigravityButton = nil;
                NSButton *quitButton = nil;
                for (NSView *view in controller.celebration.settingsWindow.contentView.subviews) {
                    if ([view isKindOfClass:NSButton.class] && view.tag == 6) statusControl = (NSButton *)view;
                    if (![view isKindOfClass:NSButton.class]) continue;
                    NSButton *button = (NSButton *)view;
                    if (button.action == @selector(showHistory:)) historyButton = button;
                    if (button.action == @selector(showIntegrations:)) integrationsButton = button;
                    if (button.action == @selector(requestAntigravityAccess:)) antigravityButton = button;
                    if (button.action == @selector(quitApplication:)) quitButton = button;
                }
                NSCAssert(controller.floatingVisibilityButton && historyButton && integrationsButton && quitButton, @"The main panel must expose the functionality directly");
                NSCAssert([antigravityButton.title hasPrefix:@"辅助功能"] && antigravityButton.enabled &&
                          NSContainsRect(antigravityButton.superview.bounds,antigravityButton.frame),
                          @"The main panel must show the unified accessibility authorization button with live status");
                [historyButton performClick:nil];
                NSCAssert(controller.panel.visible && controller.showingHistory && !controller.collapsed, @"History opens an expanded visible list");
                [controller.floatingVisibilityButton performClick:nil];
                NSCAssert(!controller.panel.visible, @"The main panel can hide the floating task list");
                [controller.floatingVisibilityButton performClick:nil];
                NSCAssert(controller.panel.visible, @"The main panel can restore the floating task list");
                [integrationsButton performClick:nil];
                NSCAssert(controller.integrationsWindow.visible, @"Compatibility is accessible from the main panel");
                BOOL hasAntigravityAccess = NO;
                for (NSView *view in controller.integrationsWindow.contentView.subviews) {
                    if ([view isKindOfClass:NSButton.class] && [(NSButton *)view action] == @selector(requestAntigravityAccess:)) hasAntigravityAccess = YES;
                }
                NSCAssert(hasAntigravityAccess, @"Compatibility must offer the same Antigravity authorization action");
                [controller.integrationsWindow orderOut:nil];
                NSCAssert(statusControl && controller.statusItem, @"Status item must be enabled by default and configurable");
                statusControl.state = NSControlStateValueOff;
                [controller.celebration changeSetting:statusControl];
                NSCAssert(!controller.statusItem, @"Disabling status entry must remove it immediately");
                NSCAssert(!controller.floatingVisibilityButton.enabled && controller.panel.visible, @"Keep a route to the main panel when the menu icon is hidden");
                CelebrationController *hiddenStatus = [[CelebrationController alloc] initWithDirectory:DataDirectory()];
                NSCAssert(![hiddenStatus.settings[@"showStatusItem"] boolValue], @"Hidden status setting must survive restart");
                [controller rebuild];
                NSCAssert(!controller.statusItem, @"Task refresh must respect hidden status entry");
                NSMenuItem *fallbackSettings = controller.panel.contentView.menu.itemArray.firstObject;
                NSCAssert(controller.panel.contentView.menu.numberOfItems >= 6 && fallbackSettings.target == controller && fallbackSettings.action == @selector(showMainPanel:), @"Floating panel background provides main panel, theme selector, quick toggles and quit");
                NSCAssert(UpdaterCompareVersions(@"0.4.0", @"0.3.8") == NSOrderedDescending && UpdaterCompareVersions(@"0.3.8", @"0.3.8") == NSOrderedSame, @"Updater semantic version comparison must work");
                statusControl.state = NSControlStateValueOn;
                [controller.celebration changeSetting:statusControl];
                NSCAssert(controller.statusItem && controller.statusItem.button.target == controller, @"Enabling status entry must restore working controls");
                NSStatusItem *restoredItem = controller.statusItem;
                [controller updateStatusItemVisibility];
                NSCAssert(controller.statusItem == restoredItem, @"Repeated updates must reuse the status entry");
                CelebrationController *visibleStatus = [[CelebrationController alloc] initWithDirectory:DataDirectory()];
                NSCAssert([visibleStatus.settings[@"showStatusItem"] boolValue], @"Visible status setting must persist");
                puts("Status item passed default visibility, immediate toggling, persistence, refresh and floating-panel settings access");
                NSCAssert(!controller.celebration.settings[@"opacity"], @"Legacy opacity must be ignored");
                NSSlider *durationControl = nil;
                for (NSView *view in controller.celebration.settingsWindow.contentView.subviews) if ([view isKindOfClass:NSSlider.class] && view.tag == 2) durationControl = (NSSlider *)view;
                durationControl.doubleValue = 4;
                [controller.celebration changeSetting:durationControl];
                CelebrationView *durationPreview = controller.celebration.previewView;
                NSCAssert(durationControl.maxValue == 4 && fabs(durationPreview.duration-3.90) < 0.001, @"Duration control and automatic preview must support four seconds");
                CelebrationController *restored = [[CelebrationController alloc] initWithDirectory:DataDirectory()];
                NSCAssert([restored.settings[@"duration"] doubleValue] == 4 && ![restored.settings[@"enabled"] boolValue], @"Settings must persist and restore");
                NSCAssert([restored.settings[@"style"] integerValue] == CelebrationRandomStyle, @"Random selection must persist");
                NSPopUpButton *styleControl = nil;
                for (NSView *view in controller.celebration.settingsWindow.contentView.subviews)
                    if ([view isKindOfClass:NSPopUpButton.class] && view.tag == 5) styleControl = (NSPopUpButton *)view;
                NSCAssert(styleControl.numberOfItems == styleCount + 1 && [styleControl.titleOfSelectedItem isEqual:@"随机"], @"Settings must default to random and list each fixed effect");
                controller.celebration.settings[@"duration"] = @1;
                for (NSInteger style=0;style<styleCount;style++) {
                    NSString *previousMessage = controller.celebration.previewView.message;
                    NSWindow *keyBeforeEffect = NSApp.keyWindow;
                    [styleControl selectItemAtIndex:style + 1];
                    [controller.celebration changeSetting:styleControl];
                    CelebrationController *selection = [[CelebrationController alloc] initWithDirectory:DataDirectory()];
                    NSCAssert([selection.settings[@"style"] integerValue] == style, @"Every effect must survive settings reload");
                    CelebrationView *preview = controller.celebration.previewView;
                    NSCAssert(!controller.celebration.overlays.count && controller.celebration.previewTimer && preview.style == style, @"Settings must preview inline without opening desktop overlays");
                    NSCAssert(![preview.message isEqual:previousMessage] && ![selection.settings[@"enabled"] boolValue], @"Preview must draw fresh copy and preserve the completion switch");
                    NSCAssert(NSApp.keyWindow == keyBeforeEffect, @"Settings preview must preserve focus");
                    NSCAssert(preview.layer.cornerRadius == CelebrationArtworkCornerRadius && ((NSVisualEffectView *)preview.superview).maskImage, @"Inline preview must use the same rounded mask as live playback");
                    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.2];
                    while (controller.celebration.previewTimer && deadline.timeIntervalSinceNow > 0)
                        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
                    NSCAssert(!controller.celebration.previewTimer && preview.stillFrame, @"Inline preview must stop its timer and retain a visible final frame");
                }
                controller.celebration.settings[@"enabled"] = @YES;
                [controller.celebration showOnScreen:NSScreen.mainScreen];
                CelebrationView *fixedArtwork = (CelebrationView *)controller.celebration.overlays.firstObject.contentView.subviews.lastObject;
                NSCAssert(fixedArtwork && fixedArtwork.style == styleCount - 1, @"A fixed choice must be used for live playback");
                [styleControl selectItemAtIndex:0];
                [controller.celebration changeSetting:styleControl];
                NSInteger previewStyle = controller.celebration.previewView.style;
                [controller.celebration preview:nil];
                NSCAssert(controller.celebration.previewView.style != previewStyle, @"Replaying a random preview must draw a different effect");
                puts("Random and fixed effects passed selection, persistence, preview and live playback");
                [controller.celebration.settingsWindow orderOut:nil];
                [controller.panel orderOut:nil];
                controller.showingHistory = NO;
                controller.signature = nil;
                controller.tasks = @[];
                controller.preview = NO; [controller refresh]; controller.preview = YES;
                NSCAssert(!controller.celebration.overlays.count, @"Restored completed tasks must not celebrate at startup");
                controller.celebration.settings[@"enabled"] = @YES;
                controller.celebration.settings[@"allScreens"] = @YES;
                controller.celebration.settings[@"duration"] = @4;
                [controller.celebration showOnScreen:NSScreen.mainScreen];
                NSCAssert(controller.celebration.overlays.count == NSScreen.screens.count, @"All-screen setting must cover each connected screen");
                CelebrationView *firstArtwork = (CelebrationView *)controller.celebration.overlays.firstObject.contentView.subviews.lastObject;
                for (NSPanel *displayOverlay in controller.celebration.overlays) {
                    CelebrationView *view = (CelebrationView *)displayOverlay.contentView.subviews.lastObject;
                    NSCAssert([view.message isEqual:firstArtwork.message] && view.style == firstArtwork.style, @"All screens must share the same reminder and effect for one completion");
                }
                CFTimeInterval fullStart = CACurrentMediaTime();
                NSDate *fullDeadline = [NSDate dateWithTimeIntervalSinceNow:4.15];
                while (controller.celebration.overlays.count && fullDeadline.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
                NSCAssert(!controller.celebration.overlays.count && CACurrentMediaTime()-fullStart < 4, @"Maximum duration must clean up within four seconds");
                printf("Maximum-duration playback cleaned up in %.3f seconds across %lu screen(s)\n", CACurrentMediaTime()-fullStart, (unsigned long)NSScreen.screens.count);
                puts("Celebration passed: completion transition, compact frosted panel, upper-third placement, click-through, focus preservation, duplicate suppression, timed cleanup, disabled mode and persistent settings");
                puts("Native UI passed: three status colors, centered dots, navigation animation, persistent removal, auto collapse and expansion");
                [controller.panel orderOut:nil];
                return 0;
            }
            NSBitmapImageRep *rep = [controller.panel.contentView bitmapImageRepForCachingDisplayInRect:controller.panel.contentView.bounds];
            [controller.panel.contentView cacheDisplayInRect:controller.panel.contentView.bounds toBitmapImageRep:rep];
            NSString *path = args.count > 2 ? args[2] : @"/tmp/task-panel-preview.png";
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
            [controller.panel orderOut:nil];
            return 0;
        }
        [NSApp run];
    }
    return 0;
}
