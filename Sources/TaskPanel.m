#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <sys/file.h>
#import <unistd.h>
#import "Celebration.h"

static NSString *DataDirectory(void) { return NSProcessInfo.processInfo.environment[@"TASK_PANEL_DATA_DIR"] ?: [NSHomeDirectory() stringByAppendingPathComponent:@".codex/task-manager"]; }
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
    return [task[@"status"] isEqual:@"completed"] ? [turn stringByAppendingString:@":completed"] : turn;
}
static NSColor *StatusColor(NSString *status) {
    if ([status isEqual:@"waiting"]) return NSColor.systemYellowColor;
    if ([status isEqual:@"completed"]) return NSColor.systemBlueColor;
    return NSColor.systemGreenColor;
}
static NSView *StatusDot(NSString *status, NSRect frame) {
    NSView *dot = [[NSView alloc] initWithFrame:frame];
    dot.wantsLayer = YES;
    dot.layer.cornerRadius = frame.size.width / 2;
    dot.layer.backgroundColor = StatusColor(status).CGColor;
    dot.toolTip = [status isEqual:@"waiting"] ? @"待输入" : ([status isEqual:@"completed"] ? @"已完成" : @"进行中");
    return dot;
}
@interface TaskButton : NSButton
@property(copy) NSString *threadID;
@end
@implementation TaskButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    if (self.bordered) {
        [[NSColor colorWithWhite:self.highlighted ? 0.30 : 0.22 alpha:1] setFill];
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
    NSDictionary *attributes = @{NSFontAttributeName:self.font ?: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName:self.contentTintColor ?: [NSColor colorWithWhite:0.94 alpha:1], NSParagraphStyleAttributeName:style};
    CGFloat textHeight = [self.title sizeWithAttributes:attributes].height;
    [self.title drawInRect:NSMakeRect(3,(self.bounds.size.height-textHeight)/2,self.bounds.size.width-6,textHeight) withAttributes:attributes];
}
@end
@interface FlippedDocument : NSView
@end
@implementation FlippedDocument
- (BOOL)isFlipped { return YES; }
@end
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
@property(copy) NSString *signature;
@property(copy) NSString *monitorError;
@property BOOL collapsed;
@property BOOL preview;
@property BOOL rebuilding;
@property BOOL animateResize;
@property BOOL completionPulse;
@property(strong) NSMutableSet *removingTasks;
@property(strong) NSMutableDictionary *dismissed;
- (void)refresh;
- (void)rebuild;
- (void)updateStatusItemVisibility;
@end
@implementation PanelController
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.removingTasks = [NSMutableSet set];
    self.dismissed = [ReadJSON(@"dismissed.json") mutableCopy] ?: [NSMutableDictionary dictionary];
    self.collapsed = YES;
    self.celebration = [[CelebrationController alloc] initWithDirectory:DataDirectory()];
    __weak PanelController *weakSelf = self;
    self.celebration.settingDidChange = ^(NSString *key) {
        if ([key isEqual:@"showStatusItem"]) [weakSelf updateStatusItemVisibility];
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
    NSRect frame = saved ? NSRectFromString(saved) : NSMakeRect(NSMaxX(screen)-380, NSMaxY(screen)-110,360,80);
    BOOL onScreen = NO;
    for (NSScreen *display in NSScreen.screens) if (NSIntersectsRect(display.visibleFrame, frame)) onScreen = YES;
    if (!onScreen) frame.origin = NSMakePoint(NSMaxX(screen)-380,NSMaxY(screen)-110);
    [self.panel setFrame:frame display:NO];
    if (!self.preview) [self startMonitor];
    [self refresh];
    if (!self.preview) [self.panel orderFrontRegardless];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screenChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
}
- (void)startMonitor {
    NSString *directory = NSProcessInfo.processInfo.arguments.firstObject.stringByDeletingLastPathComponent;
    self.monitor = [[NSTask alloc] init];
    self.monitor.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
    self.monitor.arguments = @[[directory stringByAppendingPathComponent:@"task_monitor.py"], @"--parent", [NSString stringWithFormat:@"%d",getpid()]];
    NSError *error;
    if (![self.monitor launchAndReturnError:&error]) self.monitorError = error.localizedDescription;
}
- (void)refresh {
    if (self.preview || self.removingTasks.count) return;
    if (self.monitor && !self.monitor.running) [self startMonitor];
    NSDictionary *snapshot = ReadJSON(@"snapshot.json");
    NSArray *incoming = [snapshot[@"tasks"] isKindOfClass:NSArray.class] ? snapshot[@"tasks"] : @[];
    NSMutableArray *tasks = [NSMutableArray array];
    for (NSDictionary *task in incoming) {
        BOOL active = [@[@"running", @"waiting", @"completed"] containsObject:task[@"status"]];
        BOOL dismissed = ![task[@"status"] isEqual:@"running"] && [self.dismissed[task[@"id"]] isEqual:DismissalKey(task)];
        if (active && !dismissed) [tasks addObject:task];
    }
    NSString *error = snapshot[@"error"] ?: self.monitorError ?: @"";
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:[DataDirectory() stringByAppendingPathComponent:@"snapshot.json"] error:NULL];
    if (!snapshot || [attrs.fileModificationDate timeIntervalSinceNow] < -8) error = @"正在连接任务状态…";
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[tasks,error] options:NSJSONWritingSortedKeys error:NULL];
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
    if (!tasks.count) self.collapsed = YES;
    else if (!hadTasks || hasNewActivity) self.collapsed = NO;
    self.animateResize = self.signature != nil;
    self.signature = signature;
    self.tasks = tasks;
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
        return;
    }
    if (self.statusItem) return;
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = [NSString stringWithFormat:@"◉ %lu", (unsigned long)self.tasks.count];
    self.statusItem.button.toolTip = @"点击显示或隐藏任务，右键打开设置";
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusClicked:);
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp|NSEventMaskRightMouseUp];
}
- (void)statusClicked:(id)sender {
    if (NSApp.currentEvent.type == NSEventTypeRightMouseUp) {
        NSMenu *menu = [NSMenu new];
        NSMenuItem *settings = [menu addItemWithTitle:@"设置…" action:@selector(showSettings:) keyEquivalent:@""];
        settings.target = self.celebration;
        NSMenuItem *visible = [menu addItemWithTitle:self.panel.visible ? @"隐藏任务浮窗" : @"显示任务浮窗" action:@selector(toggleVisible:) keyEquivalent:@""];
        visible.target = self;
        [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,self.statusItem.button.bounds.size.height) inView:self.statusItem.button];
        return;
    }
    [self toggleVisible:sender];
}
- (void)toggleVisible:(id)sender {
    if (self.panel.visible) [self.panel orderOut:nil];
    else [self.panel orderFrontRegardless];
}
- (void)toggleCollapsed:(id)sender {
    self.collapsed = !self.collapsed;
    self.animateResize = YES;
    [self rebuild];
    self.animateResize = NO;
}
- (void)openTask:(TaskButton *)sender {
    if ([self.removingTasks containsObject:sender.threadID]) return;
    NSURL *url = [NSURL URLWithString:[@"codex://threads/" stringByAppendingString:sender.threadID]];
    if (!url || (!self.preview && ![NSWorkspace.sharedWorkspace openURL:url])) {
        self.monitorError = @"打开聊天失败，请重试";
        [self rebuild];
        return;
    }
    NSDictionary *task = nil;
    for (NSDictionary *entry in self.tasks) if ([entry[@"id"] isEqual:sender.threadID]) task = entry;
    if (!task || [task[@"status"] isEqual:@"running"]) return;
    NSMutableDictionary *dismissed = [self.dismissed mutableCopy];
    dismissed[sender.threadID] = DismissalKey(task);
    NSData *data = [NSJSONSerialization dataWithJSONObject:dismissed options:0 error:NULL];
    NSError *error;
    if (![data writeToFile:[DataDirectory() stringByAppendingPathComponent:@"dismissed.json"] options:NSDataWritingAtomic error:&error]) {
        self.monitorError = @"保存跳转状态失败，请重试";
        [self rebuild];
        return;
    }
    self.dismissed = dismissed;
    [self.removingTasks addObject:sender.threadID];
    NSView *row = sender.superview;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.2;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        row.animator.alphaValue = 0;
        [row.animator setFrame:NSOffsetRect(row.frame, 18, 0)];
    } completionHandler:^{
        NSMutableArray *remaining = [self.tasks mutableCopy];
        [remaining removeObject:task];
        self.tasks = remaining;
        if (!remaining.count) self.collapsed = YES;
        [self.removingTasks removeObject:sender.threadID];
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
    self.statusItem.button.title = [NSString stringWithFormat:@"◉ %lu", (unsigned long)self.tasks.count];
    self.statusItem.button.toolTip = @"点击显示或隐藏任务，右键打开设置";
    NSScreen *screen = self.panel.screen ?: NSScreen.mainScreen;
    if (!self.tasks.count) self.collapsed = YES;
    CGFloat width = self.collapsed ? 206 : 360;
    CGFloat rowsHeight = self.tasks.count * 38;
    CGFloat listHeight = MIN(rowsHeight, MIN(380, screen.visibleFrame.size.height - 100));
    CGFloat height = self.collapsed ? 40 : 50 + (self.tasks.count ? listHeight : 30);
    NSRect old = self.panel.frame;
    NSRect frame = NSMakeRect(NSMaxX(old)-width, NSMaxY(old)-height, width, height);
    frame.origin.x = MIN(MAX(frame.origin.x, NSMinX(screen.visibleFrame)+8), NSMaxX(screen.visibleFrame)-width-8);
    frame.origin.y = MIN(MAX(frame.origin.y, NSMinY(screen.visibleFrame)+8), NSMaxY(screen.visibleFrame)-height-8);
    self.rebuilding = YES;
    [self.panel setFrame:frame display:YES animate:self.animateResize];
    self.rebuilding = NO;
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0,0,width,height)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.10 green:0.11 blue:0.13 alpha:0.98].CGColor;
    root.layer.cornerRadius = self.collapsed ? 20 : 16;
    root.layer.masksToBounds = YES;
    root.layer.borderWidth = 0.5;
    root.layer.borderColor = [NSColor.separatorColor colorWithAlphaComponent:0.5].CGColor;
    CGFloat previousScroll = 0;
    for (NSView *view in self.panel.contentView.subviews) if ([view isKindOfClass:NSScrollView.class]) previousScroll = ((NSScrollView *)view).contentView.bounds.origin.y;
    NSMenu *panelMenu = [NSMenu new];
    NSMenuItem *settingsItem = [panelMenu addItemWithTitle:@"设置…" action:@selector(showSettings:) keyEquivalent:@""];
    settingsItem.target = self.celebration;
    root.menu = panelMenu;
    self.panel.contentView = root;
    NSString *summaryStatus = waiting ? @"waiting" : @"running";
    BOOL allCompleted = self.tasks.count > 0;
    for (NSDictionary *task in self.tasks) if (![task[@"status"] isEqual:@"completed"]) allCompleted = NO;
    if (allCompleted) summaryStatus = @"completed";
    NSString *heading = @"Codex 任务";
    if (self.collapsed) heading = self.tasks.count ? [NSString stringWithFormat:@"Codex · %lu", (unsigned long)self.tasks.count] : @"Codex · 空闲";
    NSTextField *title = Label(heading, self.collapsed ? 12 : 14, NSColor.labelColor);
    title.font = [NSFont systemFontOfSize:self.collapsed ? 12 : 14 weight:NSFontWeightSemibold];
    title.frame = self.collapsed ? NSMakeRect(36,0,width-76,height) : NSMakeRect(16,height-33,width-64,21);
    [root addSubview:title];
    if (self.collapsed) {
        NSView *halo = StatusDot(summaryStatus, NSMakeRect(11,11,18,18));
        halo.layer.backgroundColor = (self.tasks.count ? [StatusColor(summaryStatus) colorWithAlphaComponent:0.12] : [NSColor colorWithWhite:0.6 alpha:0.08]).CGColor;
        [root addSubview:halo];
        NSView *dot = StatusDot(summaryStatus, NSMakeRect(16.5,16.5,7,7));
        if (!self.tasks.count) dot.layer.backgroundColor = NSColor.tertiaryLabelColor.CGColor;
        [root addSubview:dot];
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
    if (self.monitorError.length) {
        title.stringValue = @"任务状态连接异常";
        title.textColor = NSColor.systemOrangeColor;
        title.toolTip = self.monitorError;
    }
    if (!self.tasks.count) {
        NSTextField *empty = Label(@"当前没有进行中的任务",12,NSColor.tertiaryLabelColor);
        empty.frame = NSMakeRect(16,17,width-32,20);
        [root addSubview:empty];
        return;
    }
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(8,8,width-16,listHeight)];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    NSView *document = [[FlippedDocument alloc] initWithFrame:NSMakeRect(0,0,width-16,rowsHeight)];
    scroll.documentView = document;
    [scroll.contentView scrollToPoint:NSMakePoint(0,MIN(previousScroll,MAX(0,rowsHeight-listHeight)))];
    [scroll reflectScrolledClipView:scroll.contentView];
    [root addSubview:scroll];
    NSInteger index = 0;
    for (NSDictionary *task in self.tasks) {
        CGFloat y = (index++)*38;
        BOOL needsInput = [task[@"status"] isEqual:@"waiting"];
        BOOL completed = [task[@"status"] isEqual:@"completed"];
        NSColor *color = StatusColor(task[@"status"]);
        NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0,y,width-20,34)];
        row.wantsLayer = YES;
        row.layer.cornerRadius = 8;
        row.layer.backgroundColor = [color colorWithAlphaComponent:0.055].CGColor;
        [document addSubview:row];
        NSView *state = StatusDot(task[@"status"], NSMakeRect(11,13.5,7,7));
        [row addSubview:state];
        TaskButton *open = [TaskButton buttonWithTitle:task[@"title"] ?: @"Codex 任务" target:self action:@selector(openTask:)];
        open.threadID = task[@"id"];
        open.bordered = NO;
        open.alignment = NSTextAlignmentLeft;
        open.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        open.frame = NSMakeRect(23,0,width-48,34);
        open.toolTip = task[@"title"];
        open.accessibilityLabel = [NSString stringWithFormat:@"%@，打开聊天 %@", needsInput ? @"待输入" : (completed ? @"已完成" : @"进行中"), open.title];
        [row addSubview:open];
        if (completed && self.completionPulse && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
            CABasicAnimation *flash = [CABasicAnimation animationWithKeyPath:@"backgroundColor"];
            flash.fromValue = (id)[color colorWithAlphaComponent:0.28].CGColor;
            flash.toValue = (id)row.layer.backgroundColor;
            flash.duration = 0.8;
            [row.layer addAnimation:flash forKey:@"completionHighlight"];
        }
    }
}
- (void)applicationWillTerminate:(NSNotification *)notification { [self.celebration stop]; if (self.monitor.running) [self.monitor terminate]; }
@end
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray *args = NSProcessInfo.processInfo.arguments;
        // Legacy notify invocations are consumed by the shared event monitor.
        if (args.count > 1 && ![args[1] isEqual:@"--watch"] && ![args[1] isEqual:@"--preview"]) return 0;
        int lock = open([[NSHomeDirectory() stringByAppendingPathComponent:@".codex/task-complete-popup-watch.lock"] fileSystemRepresentation], O_CREAT|O_RDWR,0600);
        if (![args containsObject:@"--preview"] && (lock < 0 || flock(lock,LOCK_EX|LOCK_NB) != 0)) return 0;
        [NSApplication sharedApplication];
        PanelController *controller = [PanelController new];
        controller.preview = args.count > 1 && [args[1] isEqual:@"--preview"];
        NSApp.delegate = controller;
        if (controller.preview) {
            [NSFileManager.defaultManager createDirectoryAtPath:DataDirectory() withIntermediateDirectories:YES attributes:nil error:NULL];
            [controller applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp]];
            controller.collapsed = NO;
            controller.tasks = @[
                @{@"id":@"preview-input",@"turn":@"one",@"status":@"waiting",@"title":@"确认运营平台销售功能清单",@"project":@"Tuntas SmartBiz",@"detail":@"需要确认功能范围，请打开聊天选择。"},
                @{@"id":@"preview-running",@"turn":@"two",@"status":@"running",@"title":@"优化全局任务浮窗",@"project":@"Codex任务管理器",@"detail":@"正在整合任务状态与紧凑提醒。"},
                @{@"id":@"preview-done",@"turn":@"three",@"status":@"completed",@"title":@"更新移动端页面",@"project":@"Tuntas Mobile",@"detail":@"页面更新已完成，等待你确认。"}
            ];
            if ([args containsObject:@"--current"]) controller.tasks = ReadJSON(@"snapshot.json")[@"tasks"] ?: @[];
            if ([args containsObject:@"--collapsed"]) controller.collapsed = YES;
            if ([args containsObject:@"--empty"]) controller.tasks = @[];
            [controller rebuild];
            if ([args containsObject:@"--celebration-preview"]) {
                CelebrationView *art = [[CelebrationView alloc] initWithFrame:NSMakeRect(0,0,600,460)];
                art.duration = 4; art.startTime = CACurrentMediaTime()-1.0; art.intensity = 0.8;
                art.style = [controller.celebration.settings[@"style"] integerValue];
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
                    NSAffineTransform *center = [NSAffineTransform transform];
                    [center translateXBy:(canvasSize.width-440)/2 yBy:(canvasSize.height-340)/2];
                    [center scaleXBy:440.0/600 yBy:340.0/460];
                    [center concat];
                }
                [art drawRect:art.bounds];
                CGContextEndTransparencyLayer(previewContext);
                [NSGraphicsContext restoreGraphicsState];
                [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:args[2] atomically:YES];
                return 0;
            }
            if ([args containsObject:@"--ui-test"]) {
                NSCAssert([controller.celebration.settings[@"enabled"] boolValue] && [controller.celebration.settings[@"style"] integerValue] == 0, @"New installs must enable the pixel effect by default");
                NSCAssert(CelebrationStyleTitles().count == 5, @"Settings must contain pixel clear and exactly four new effects");
                NSString *legacyDirectory = [DataDirectory() stringByAppendingPathComponent:@"legacy-settings"];
                [NSFileManager.defaultManager createDirectoryAtPath:legacyDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
                NSDictionary *legacySettings = @{@"style":@5,@"duration":@4,@"opacity":@0.9,@"showStatusItem":@NO};
                [[NSJSONSerialization dataWithJSONObject:legacySettings options:0 error:NULL] writeToFile:[legacyDirectory stringByAppendingPathComponent:@"settings.json"] atomically:YES];
                CelebrationController *migrated = [[CelebrationController alloc] initWithDirectory:legacyDirectory];
                NSCAssert([migrated.settings[@"style"] integerValue] == 0 && [migrated.settings[@"styleVersion"] integerValue] == 2 && ![migrated.settings[@"showStatusItem"] boolValue], @"Old style selections must migrate to pixel clear and preserve visibility settings");
                NSArray<NSString *> *messages = CelebrationMessages();
                NSCAssert(messages.count == 100 && [NSSet setWithArray:messages].count == 100, @"Completion copy must contain exactly 100 unique reminders");
                NSString *previousMessage = nil;
                for (NSInteger i=0;i<1000;i++) {
                    NSString *message = CelebrationRandomMessage(previousMessage);
                    NSCAssert([messages containsObject:message] && ![message isEqual:previousMessage], @"Random reminders must be valid and avoid adjacent repeats");
                    previousMessage = message;
                }
                for (NSInteger style=0;style<(NSInteger)CelebrationStyleTitles().count;style++) {
                    CelebrationView *scene = [[CelebrationView alloc] initWithFrame:NSMakeRect(0,0,600,460)];
                    scene.duration = 4; scene.stillFrame = YES; scene.style = style;
                    scene.intensity = 0.8; scene.message = messages[73];
                    NSBitmapImageRep *card = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:600 pixelsHigh:460 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
                    [NSGraphicsContext saveGraphicsState];
                    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:card];
                    [scene drawRect:scene.bounds];
                    [NSGraphicsContext restoreGraphicsState];
                    NSColor *surface = [[card colorAtX:100 y:100] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
                    NSCAssert(fabs(surface.alphaComponent-0.9) < 0.02 && surface.redComponent < 0.3 && surface.blueComponent < 0.35 && [card colorAtX:0 y:0].alphaComponent < 0.01, @"Game scenes must use a 90 percent background with clear rounded corners");
                    for (NSValue *corner in @[[NSValue valueWithPoint:NSMakePoint(2,2)],[NSValue valueWithPoint:NSMakePoint(597,2)],[NSValue valueWithPoint:NSMakePoint(2,457)],[NSValue valueWithPoint:NSMakePoint(597,457)]]) {
                        NSPoint point = corner.pointValue;
                        NSCAssert([card colorAtX:point.x y:point.y].alphaComponent < 0.01, @"All four rendered corners must be transparent");
                    }
                    NSCAssert([card colorAtX:0 y:230].alphaComponent > 0.88 && [card colorAtX:300 y:0].alphaComponent > 0.88, @"Rounded clipping must retain the straight edge midpoints");
                }
                puts("100 unique reminders and 1000 random selections passed, all five scenes use 90 percent background opacity");
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
                NSCAssert(controller.collapsed && controller.panel.frame.size.height == 40, @"Empty panel must auto collapse");
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
                NSRect displayFrame = controller.panel.screen.frame;
                NSCAssert(fabs(NSMidX(overlay.frame)-NSMidX(displayFrame)) < 1 && fabs(NSMidY(overlay.frame)-NSMidY(displayFrame)) < 1, @"Celebration must sit at the display center");
                NSCAssert(overlay.frame.size.width <= 440 && overlay.frame.size.height <= 340, @"Completion must use a compact centered panel");
                CelebrationView *artwork = (CelebrationView *)overlay.contentView.subviews.lastObject;
                NSCAssert([overlay.contentView isKindOfClass:NSVisualEffectView.class] && ((NSVisualEffectView *)overlay.contentView).blendingMode == NSVisualEffectBlendingModeBehindWindow, @"Live completion must use the system frosted background");
                NSVisualEffectView *glass = (NSVisualEffectView *)overlay.contentView;
                NSCAssert(glass.maskImage && glass.layer.cornerRadius >= 25 && artwork.layer.cornerRadius == CelebrationArtworkCornerRadius, @"Backdrop and artwork must share prominent scaled rounded corners");
                NSCAssert(artwork.frame.size.width <= 600 && artwork.frame.size.height <= 460, @"Main artwork must stay compact");
                NSCAssert(artwork.alphaValue == 1, @"Artwork must remain fully opaque");
                NSCAssert([CelebrationMessages() containsObject:artwork.message], @"Completion must draw a random reminder");
                NSString *completionMessage = artwork.message;
                NSCAssert(NSApp.keyWindow == previousKey, @"Celebration must preserve keyboard focus");
                controller.preview = NO; [controller refresh]; controller.preview = YES;
                NSCAssert(controller.celebration.overlays.firstObject == overlay, @"Duplicate refresh must not restart celebration");
                NSCAssert([artwork.message isEqual:completionMessage], @"Redraws and duplicate events must keep the same reminder");
                NSDate *effectDeadline = [NSDate dateWithTimeIntervalSinceNow:1.3];
                while (controller.celebration.overlays.count && effectDeadline.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
                NSCAssert(!controller.celebration.overlays.count && !controller.celebration.animationTimer, @"Celebration must release windows and timer at deadline");
                controller.celebration.settings[@"enabled"] = @NO;
                [controller.celebration showOnScreen:NSScreen.mainScreen];
                NSCAssert(!controller.celebration.overlays.count, @"Disabled celebration must stay hidden");
                [controller.celebration showSettings:nil];
                NSButton *statusControl = nil;
                for (NSView *view in controller.celebration.settingsWindow.contentView.subviews)
                    if ([view isKindOfClass:NSButton.class] && view.tag == 6) statusControl = (NSButton *)view;
                NSCAssert(statusControl && controller.statusItem, @"Status item must be enabled by default and configurable");
                statusControl.state = NSControlStateValueOff;
                [controller.celebration changeSetting:statusControl];
                NSCAssert(!controller.statusItem, @"Disabling status entry must remove it immediately");
                CelebrationController *hiddenStatus = [[CelebrationController alloc] initWithDirectory:DataDirectory()];
                NSCAssert(![hiddenStatus.settings[@"showStatusItem"] boolValue], @"Hidden status setting must survive restart");
                [controller rebuild];
                NSCAssert(!controller.statusItem, @"Task refresh must respect hidden status entry");
                NSMenuItem *fallbackSettings = controller.panel.contentView.menu.itemArray.firstObject;
                NSCAssert(fallbackSettings.target == controller.celebration && fallbackSettings.action == @selector(showSettings:), @"Floating panel must provide a settings entry");
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
                NSCAssert([restored.settings[@"style"] integerValue] == 0, @"Effect selection must persist");
                NSPopUpButton *styleControl = nil;
                for (NSView *view in controller.celebration.settingsWindow.contentView.subviews)
                    if ([view isKindOfClass:NSPopUpButton.class] && view.tag == 5) styleControl = (NSPopUpButton *)view;
                NSCAssert(styleControl.numberOfItems == (NSInteger)CelebrationStyleTitles().count, @"Settings must list every effect");
                controller.celebration.settings[@"duration"] = @1;
                for (NSInteger style=0;style<(NSInteger)CelebrationStyleTitles().count;style++) {
                    NSString *previousMessage = controller.celebration.previewView.message;
                    NSWindow *keyBeforeEffect = NSApp.keyWindow;
                    [styleControl selectItemAtIndex:style];
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
                puts("All five styles passed selection, persistence, live playback and timed cleanup");
                [controller.celebration.settingsWindow orderOut:nil];
                controller.signature = nil;
                controller.tasks = @[];
                controller.preview = NO; [controller refresh]; controller.preview = YES;
                NSCAssert(!controller.celebration.overlays.count, @"Restored completed tasks must not celebrate at startup");
                controller.celebration.settings[@"enabled"] = @YES;
                controller.celebration.settings[@"allScreens"] = @YES;
                controller.celebration.settings[@"duration"] = @4;
                [controller.celebration showOnScreen:NSScreen.mainScreen];
                NSCAssert(controller.celebration.overlays.count == NSScreen.screens.count, @"All-screen setting must cover each connected screen");
                for (NSPanel *displayOverlay in controller.celebration.overlays)
                    NSCAssert([((CelebrationView *)displayOverlay.contentView.subviews.lastObject).message isEqual:controller.celebration.lastMessage], @"All screens must share the same reminder for one completion");
                CFTimeInterval fullStart = CACurrentMediaTime();
                NSDate *fullDeadline = [NSDate dateWithTimeIntervalSinceNow:4.15];
                while (controller.celebration.overlays.count && fullDeadline.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
                NSCAssert(!controller.celebration.overlays.count && CACurrentMediaTime()-fullStart < 4, @"Maximum duration must clean up within four seconds");
                printf("Maximum-duration playback cleaned up in %.3f seconds across %lu screen(s)\n", CACurrentMediaTime()-fullStart, (unsigned long)NSScreen.screens.count);
                puts("Celebration passed: completion transition, compact frosted panel, centered artwork, click-through, focus preservation, duplicate suppression, timed cleanup, disabled mode and persistent settings");
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
