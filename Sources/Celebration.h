// Native, click-through completion artwork and user-configurable presentation.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

FOUNDATION_EXPORT const CGFloat CelebrationArtworkCornerRadius;
FOUNDATION_EXPORT NSArray<NSString *> *CelebrationStyleTitles(void);
FOUNDATION_EXPORT NSArray<NSString *> *CelebrationMessages(void);
FOUNDATION_EXPORT NSString *CelebrationRandomMessage(NSString *previous);

@interface CelebrationView : NSView
@property CFTimeInterval startTime;
@property NSTimeInterval duration;
@property CGFloat intensity;
@property NSInteger palette;
@property NSInteger style;
@property BOOL reducedMotion;
@property BOOL stillFrame;
@property(copy) NSString *message;
@end

@interface CelebrationController : NSObject <NSWindowDelegate>
@property(strong) NSMutableDictionary *settings;
@property(strong) NSMutableArray<NSPanel *> *overlays;
@property(strong) NSTimer *animationTimer;
@property(strong) NSTimer *previewTimer;
@property(strong) CelebrationView *previewView;
@property(strong) NSWindow *settingsWindow;
@property(copy) NSString *settingsPath;
@property(copy) NSString *lastMessage;
@property(copy) void (^settingDidChange)(NSString *key);
@property(strong) NSTextField *durationLabel;
@property(strong) NSTextField *saveStatus;
- (instancetype)initWithDirectory:(NSString *)directory;
- (void)showOnScreen:(NSScreen *)screen;
- (void)stop;
- (void)showSettings:(id)sender;
- (void)changeSetting:(NSControl *)sender;
- (void)preview:(id)sender;
@end
