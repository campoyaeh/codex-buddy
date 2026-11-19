#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ApplicationServices/ApplicationServices.h>
#import <sys/file.h>
#import <unistd.h>
#import "Celebration.h"
#import "PanelTheme.h"
#import "AntigravityNavigation.h"

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

@interface FloatingPanel : NSPanel
@end
@implementation FloatingPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end
@interface PanelController : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(strong) FloatingPanel *panel;
@property(strong) CelebrationController *celebration;
@property(strong) NSStatusItem *statusItem;
@property(strong) NSTask *monitor;
@property(strong) NSTimer *timer;
@property(copy) NSArray *tasks;
@property(copy) NSArray *history;
@property BOOL showingHistory;
@property NSUInteger historyLimit;
@property(copy) NSString *signature;
@property(copy) NSString *monitorError;
@property BOOL collapsed;
@property BOOL preview;
@property BOOL launchedInteractively;
@property BOOL rebuilding;
@property BOOL animateResize;
@property BOOL completionPulse;
@property(strong) NSMutableSet *removingTasks;
@property(strong) NSMutableSet *openingTasks;
@property(strong) NSMutableDictionary *dismissed;
@property(strong) NSWindow *integrationsWindow;
@property(strong) NSTask *integrationSetup;
@property(copy) NSString *sourcesSignature;
@property(weak) NSButton *floatingVisibilityButton;
@property(weak) NSButton *launchAtLoginButton;
@property BOOL navigatingAntigravity;
@property(copy) NSString *antigravityNotice;
@property BOOL antigravityNeedsPermission;
- (void)refresh;
- (void)rebuild;
- (void)updateStatusItemVisibility;
@end
@implementation PanelController
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.removingTasks = [NSMutableSet set];
    self.openingTasks = [NSMutableSet set];
    self.dismissed = [ReadJSON(@"dismissed.json") mutableCopy] ?: [NSMutableDictionary dictionary];
    self.collapsed = YES;
    self.historyLimit = 10;
    self.celebration = [[CelebrationController alloc] initWithDirectory:DataDirectory()];
    [self.celebration applyTheme];
    __weak PanelController *weakSelf = self;
    self.celebration.settingDidChange = ^(NSString *key) {
        if ([key isEqual:@"showStatusItem"]) [weakSelf updateStatusItemVisibility];
        if ([key isEqual:@"mascotID"] || [key isEqual:@"theme"]) [weakSelf rebuild];
    };
    self.panel = [[FloatingPanel alloc] initWithContentRect:NSMakeRect(0,0,360,80)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
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
    if (self.integrationsWindow.visible) [self updateIntegrations];
    if (self.preview || self.removingTasks.count) return;
    if (self.monitor && !self.monitor.running) [self startMonitor];
    NSDictionary *snapshot = ReadJSON(@"snapshot.json");
    NSArray *incoming = [snapshot[@"tasks"] isKindOfClass:NSArray.class] ? snapshot[@"tasks"] : @[];
    NSArray *history = [snapshot[@"history"] isKindOfClass:NSArray.class] ? snapshot[@"history"] : @[];
    NSMutableArray *tasks = [NSMutableArray array];
    for (NSDictionary *task in incoming) {
        BOOL active = [@[@"running", @"waiting", @"completed"] containsObject:task[@"status"]];
        BOOL dismissed = [self.dismissed[task[@"id"]] isEqual:DismissalKey(task)];
        if (active && !dismissed) [tasks addObject:task];
    }
    NSString *error = snapshot[@"error"] ?: self.monitorError ?: @"";
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:[DataDirectory() stringByAppendingPathComponent:@"snapshot.json"] error:NULL];
    if (!snapshot || [attrs.fileModificationDate timeIntervalSinceNow] < -8) error = @"正在连接任务状态…";
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
    if (!tasks.count && !self.showingHistory) self.collapsed = YES;
    else if (!hadTasks || hasNewActivity) self.collapsed = NO;
    self.animateResize = self.signature != nil;
    self.signature = signature;
    self.tasks = tasks;
    self.history = history;
    self.monitorError = error;
    [self rebuild];
    if (self.completionPulse) [self.celebration showOnScreen:self.panel.screen ?: NSScreen.mainScreen];
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
    [menu addItemWithTitle:@"退出应用" action:@selector(quitApplication:) keyEquivalent:@""].target = self;
    return menu;
}
- (void)statusClicked:(id)sender {
    if (NSApp.currentEvent.type == NSEventTypeRightMouseUp) {
        [[self statusMenu] popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,self.statusItem.button.bounds.size.height) inView:self.statusItem.button];
        return;
    }
    [self showMainPanel:sender];
}
- (void)addMainPanelActions {
    if (self.floatingVisibilityButton) return;
    NSView *root = self.celebration.settingsWindow.contentView;
    NSButton *antigravity = [NSButton buttonWithTitle:@"任务跳转授权" target:self action:@selector(requestAntigravityAccess:)];
    antigravity.toolTip = @"在系统设置中允许「工头喵」自动打开 Antigravity 会话";
    antigravity.frame = NSMakeRect(256,708,170,32);
    [root addSubview:antigravity];
    NSButton *floating = [NSButton buttonWithTitle:@"显示任务浮窗" target:self action:@selector(toggleVisible:)];
    floating.frame = NSMakeRect(434,708,120,32);
    [root addSubview:floating];
    self.floatingVisibilityButton = floating;
    NSButton *history = [NSButton buttonWithTitle:@"历史对话" target:self action:@selector(showHistory:)];
    history.frame = NSMakeRect(562,708,92,32);
    [root addSubview:history];
    NSButton *integrations = [NSButton buttonWithTitle:@"兼容与接入" target:self action:@selector(showIntegrations:)];
    integrations.frame = NSMakeRect(662,708,112,32);
    [root addSubview:integrations];
    NSButton *quit = [NSButton buttonWithTitle:@"退出应用" target:self action:@selector(quitApplication:)];
    quit.frame = NSMakeRect(782,708,90,32);
    [root addSubview:quit];
    NSButton *launchAtLogin = [NSButton checkboxWithTitle:@"登录时自动启动" target:self action:@selector(toggleLaunchAtLogin:)];
    launchAtLogin.frame = NSMakeRect(326,93,150,22);
    launchAtLogin.state = IsLaunchAtLoginEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    [root addSubview:launchAtLogin];
    self.launchAtLoginButton = launchAtLogin;
}
- (void)toggleLaunchAtLogin:(NSButton *)sender {
    BOOL enable = sender.state == NSControlStateValueOn;
    NSError *error = nil;
    if (!SetLaunchAtLoginEnabled(enable, &error)) {
        sender.state = enable ? NSControlStateValueOff : NSControlStateValueOn;
        self.monitorError = error.localizedDescription ?: @"更新登录自启动设置失败";
        [self rebuild];
    }
}
- (void)showMainPanel:(id)sender {
    [self.celebration showSettings:sender];
    [self addMainPanelActions];
    [self updateFloatingVisibilityButton];
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
    self.collapsed = NO;
    [self rebuild];
}
- (void)loadMoreHistory:(id)sender {
    self.historyLimit += 10;
    [self rebuild];
}
- (void)showNavigationError:(NSString *)message {
    self.monitorError = message;
    [self rebuild];
}

- (void)showAntigravityNotice:(NSString *)message permission:(BOOL)permission {
    self.antigravityNotice = message;
    self.antigravityNeedsPermission = permission;
    [self rebuild];
}

- (void)requestAntigravityAccess:(id)sender {
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
    NSDictionary *task = nil;
    for (NSDictionary *entry in self.showingHistory ? self.history : self.tasks) if ([entry[@"id"] isEqual:sender.threadID]) task = entry;
    if (!task) return;
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
            self.monitorError = @"已复制会话恢复命令，请粘贴到终端运行";
            [self finishOpeningTask:task row:sender.superview opened:YES];
            if (!self.removingTasks.count) [self rebuild];
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
    for (NSDictionary *current in self.tasks) {
        if ([current[@"id"] isEqual:task[@"id"]] && [current[@"turn"] isEqual:task[@"turn"]] && [current[@"status"] isEqual:task[@"status"]]) {
            [self dismissEntry:current row:row];
            return;
        }
    }
}
- (void)markTaskRead:(NSMenuItem *)sender {
    for (NSDictionary *task in self.tasks) if ([task[@"id"] isEqual:sender.representedObject]) {
        [self dismissEntry:task row:nil allowRunning:YES];
        return;
    }
}
- (void)copyResume:(NSMenuItem *)sender {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:sender.representedObject forType:NSPasteboardTypeString];
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
- (void)updateIntegrations {
    NSDictionary *snapshot = ReadJSON(@"snapshot.json");
    NSArray *sources = snapshot[@"sources"] ?: @[];
    NSString *signature = [sources description];
    if ([signature isEqual:self.sourcesSignature]) return;
    self.sourcesSignature = signature;
    PanelSurface *root = [[PanelSurface alloc] initWithFrame:NSMakeRect(0,0,720,650)];
    root.fillColor = PanelColor(0xf7f8fb,0x171a1f,1);
    self.integrationsWindow.contentView = root;
    NSTextField *title = Label(@"让不同 AI 助手的任务汇集到同一个浮窗",18,NSColor.labelColor);
    title.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    title.frame = NSMakeRect(22,602,676,28); [root addSubview:title];
    NSTextField *help = Label(@"配置事件接入后，请在对应客户端开启新会话。",11,NSColor.secondaryLabelColor);
    help.frame = NSMakeRect(22,575,676,24); [root addSubview:help];
    NSScrollView *scroll = PanelScrollView(NSMakeRect(18,124,684,440), MAX(440,sources.count*38));
    NSView *document = scroll.documentView;
    [root addSubview:scroll];
    NSInteger index = 0;
    for (NSDictionary *source in sources) {
        CGFloat y = (index++) * 38;
        BOOL connected = [@[@"已连接",@"已收到任务"] containsObject:source[@"state"]];
        NSColor *color = [source[@"error"] length] || [source[@"setup_error"] length] ? NSColor.systemOrangeColor : (connected ? NSColor.systemGreenColor : ([source[@"state"] hasPrefix:@"已配置"] ? NSColor.systemBlueColor : NSColor.secondaryLabelColor));
        NSTextField *name = Label(source[@"name"],12,NSColor.labelColor);
        name.frame = NSMakeRect(6,y,218,38); [document addSubview:name];
        NSTextField *state = Label(source[@"state"],11,color);
        state.frame = NSMakeRect(228,y,260,38);
        state.toolTip = [NSString stringWithFormat:@"%@\n%@\n%@",source[@"detail"] ?: @"",source[@"error"] ?: @"",source[@"setup_error"] ?: @""];
        [document addSubview:state];
        NSTextField *mode = Label(source[@"mode"],11,NSColor.tertiaryLabelColor);
        mode.frame = NSMakeRect(490,y,174,38); [document addSubview:mode];
    }
    NSTextField *note = Label(@"Antigravity 自动跳转需要在系统设置中允许「工头喵」。临时签名版更新后可能需重新授权。",11,NSColor.secondaryLabelColor);
    note.frame = NSMakeRect(22,89,676,25); [root addSubview:note];
    NSButton *setup = [NSButton buttonWithTitle:self.integrationSetup.running ? @"正在接入…" : @"接入已安装客户端" target:self action:@selector(setupIntegrations:)];
    setup.frame = NSMakeRect(22,35,168,32); setup.enabled = !self.integrationSetup.running; [root addSubview:setup];
    NSButton *antigravity = [NSButton buttonWithTitle:@"任务跳转授权" target:self action:@selector(requestAntigravityAccess:)];
    antigravity.frame = NSMakeRect(198,35,170,32); [root addSubview:antigravity];
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
    NSData *data = [NSJSONSerialization dataWithJSONObject:dismissed options:0 error:NULL];
    NSError *error;
    if (![data writeToFile:[DataDirectory() stringByAppendingPathComponent:@"dismissed.json"] options:NSDataWritingAtomic error:&error]) {
        self.monitorError = @"保存跳转状态失败，请重试";
        [self rebuild];
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
        NSMutableArray *remaining = [self.tasks mutableCopy];
        NSIndexSet *matches = [remaining indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry, NSUInteger idx, BOOL *stop) {
            return [entry[@"id"] isEqual:threadID] && [DismissalKey(entry) isEqual:DismissalKey(task)];
        }];
        [remaining removeObjectsAtIndexes:matches];
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
    }
    self.statusItem.button.image = MascotImage(self.celebration.settings[@"mascotID"],20);
    self.statusItem.button.imagePosition = NSImageLeft;
    self.statusItem.button.title = [NSString stringWithFormat:@" %lu", (unsigned long)self.tasks.count];
    NSString *roleName = MascotDefinition(self.celebration.settings[@"mascotID"])[@"name"];
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"%@\n点击进入主面板，右键显示菜单",roleName];
    NSScreen *screen = self.panel.screen ?: NSScreen.mainScreen;
    NSArray *displayed = self.showingHistory ? [self.history subarrayWithRange:NSMakeRange(0,MIN(self.historyLimit,self.history.count))] : self.tasks;
    BOOL hasMore = self.showingHistory && self.history.count > displayed.count;
    CGFloat width = self.collapsed ? 206 : 360;
    CGFloat rowsHeight = displayed.count * 38 + (hasMore ? 32 : 0);
    CGFloat noticeHeight = self.antigravityNotice.length ? 48 : 0;
    CGFloat listHeight = MIN(rowsHeight, MIN(380, screen.visibleFrame.size.height - 100 - noticeHeight));
    CGFloat height = self.collapsed ? 40 : 50 + noticeHeight + (displayed.count ? listHeight : 30);
    NSRect old = self.panel.frame;
    NSRect frame = NSMakeRect(NSMaxX(old)-width, NSMaxY(old)-height, width, height);
    frame.origin.x = MIN(MAX(frame.origin.x, NSMinX(screen.visibleFrame)+8), NSMaxX(screen.visibleFrame)-width-8);
    frame.origin.y = MIN(MAX(frame.origin.y, NSMinY(screen.visibleFrame)+8), NSMaxY(screen.visibleFrame)-height-8);
    self.rebuilding = YES;
    [self.panel setFrame:frame display:YES animate:self.animateResize];
    self.rebuilding = NO;
    PanelSurface *root = [[PanelSurface alloc] initWithFrame:NSMakeRect(0,0,width,height)];
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
    root.menu = panelMenu;
    self.panel.contentView = root;
    NSString *summaryStatus = waiting ? @"waiting" : @"running";
    BOOL allCompleted = self.tasks.count > 0;
    for (NSDictionary *task in self.tasks) if (![task[@"status"] isEqual:@"completed"]) allCompleted = NO;
    if (allCompleted) summaryStatus = @"completed";
    NSString *heading = self.collapsed && self.tasks.count
        ? [NSString stringWithFormat:@"%@ · %lu",roleName,(unsigned long)self.tasks.count] : roleName;
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
        notice.frame = NSMakeRect(16,8,width - (self.antigravityNeedsPermission ? 98 : 32),34);
        [root addSubview:notice];
        if (self.antigravityNeedsPermission) {
            NSButton *authorize = [TaskButton buttonWithTitle:@"去授权" target:self action:@selector(requestAntigravityAccess:)];
            authorize.frame = NSMakeRect(width-74,12,62,26);
            [root addSubview:authorize];
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
        NSTextField *empty = Label(self.showingHistory ? @"暂无历史对话" : @"当前没有进行中的任务",12,NSColor.tertiaryLabelColor);
        empty.frame = NSMakeRect(16,17+noticeHeight,width-32,20);
        [root addSubview:empty];
        return;
    }
    NSScrollView *scroll = PanelScrollView(NSMakeRect(8,8+noticeHeight,width-16,listHeight), rowsHeight);
    NSView *document = scroll.documentView;
    // Reserve the hit area even when macOS overlays the scroller on the document.
    CGFloat scrollerGutter = scroll.hasVerticalScroller ? MAX(
        [PanelScroller scrollerWidthForControlSize:NSControlSizeSmall scrollerStyle:NSScrollerStyleOverlay],
        [PanelScroller scrollerWidthForControlSize:NSControlSizeSmall scrollerStyle:NSScrollerStyleLegacy]) : 0;
    CGFloat rowWidth = NSWidth(scroll.frame) - scrollerGutter - 4;
    [scroll.contentView scrollToPoint:NSMakePoint(0,MIN(previousScroll,MAX(0,rowsHeight-listHeight)))];
    [scroll reflectScrolledClipView:scroll.contentView];
    [root addSubview:scroll];
    NSInteger index = 0;
    for (NSDictionary *task in displayed) {
        CGFloat y = (index++)*38;
        BOOL needsInput = [task[@"status"] isEqual:@"waiting"];
        BOOL completed = [task[@"status"] isEqual:@"completed"];
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
        open.frame = NSMakeRect(23,0,rowWidth-(hasSource ? 58 : 28),34);
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
    }
    if (hasMore) {
        TaskButton *more = [TaskButton buttonWithTitle:@"再显示 10 条" target:self action:@selector(loadMoreHistory:)];
        more.bordered = NO;
        more.font = [NSFont systemFontOfSize:12];
        more.frame = NSMakeRect(0,displayed.count*38,rowWidth,30);
        [document addSubview:more];
    }
}
- (void)applicationWillTerminate:(NSNotification *)notification {
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
                NSCAssert(controller.panel.frame.size.height == 430, @"Single-line header keeps the history panel compact");
                NSCAssert(controller.showingHistory && !controller.collapsed && list().documentView.subviews.count == 11, @"History defaults to ten rows plus load more");
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
                for (NSDictionary *role in MascotCatalog()) {
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
                    [artwork addObject:[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]];
                }
                NSCAssert(identifiers.count == 6 && artwork.count == 6, @"All six mascots must have distinct identifiers and artwork");
                controller.collapsed = YES; [controller rebuild];
                NSCAssert(controller.panel.frame.size.width == 206 && controller.panel.frame.size.height == 40, @"Identity changes must preserve compact capsule geometry");
                puts("Mascots passed: six distinct designs, exclusive selection, persistence, menu and preview updates, and compact layout");
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
                NSCAssert(statusMenu.numberOfItems == 2, @"Status menu must have just two entries");
                NSCAssert(statusMenu.itemArray.firstObject.action == @selector(showMainPanel:) && statusMenu.itemArray.lastObject.action == @selector(quitApplication:), @"Status menu must offer just showing the main panel and quitting");
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
                NSCAssert([antigravityButton.title isEqualToString:@"任务跳转授权"] && antigravityButton.enabled &&
                          NSContainsRect(antigravityButton.superview.bounds,antigravityButton.frame),
                          @"The main panel must show the Antigravity authorization button");
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
                NSCAssert(controller.panel.contentView.menu.numberOfItems == 2 && fallbackSettings.target == controller && fallbackSettings.action == @selector(showMainPanel:), @"Floating panel background provides a main panel entry and theme selector");
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
