// Native, click-through completion artwork and user-configurable presentation.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "Mascot.h"

FOUNDATION_EXPORT const CGFloat CelebrationArtworkCornerRadius;
FOUNDATION_EXPORT const NSInteger CelebrationRandomStyle;
FOUNDATION_EXPORT NSArray<NSString *> *CelebrationStyleTitles(void);
FOUNDATION_EXPORT NSInteger CelebrationPlaybackStyle(NSInteger selection, NSInteger previous);
FOUNDATION_EXPORT NSRect CelebrationOverlayFrame(NSRect visibleFrame);
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
@property(copy) NSString *mascotID;
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
@property(copy) void (^previewInputMirror)(void);
@property(copy) void (^resetInputMirrorPosition)(void);
@property(strong) NSTextField *durationLabel;
@property(strong) NSTextField *saveStatus;
@property(strong) NSTextField *mascotDescription;
@property(strong) NSButton *inputMirrorCheckbox;
@property(strong) NSButton *inputMirrorExcludeIDEsCheckbox;
@property(strong) NSButton *inputMirrorPreviewButton;
@property(strong) NSButton *inputMirrorResetButton;
@property(strong) NSPopUpButton *inputMirrorStyleControl;
@property(strong) NSTextField *inputMirrorHint;
@property(strong) NSButton *autoCollapseCheckbox;
@property(strong) NSSegmentedControl *settingsTabControl;
@property(strong) NSArray<NSMutableArray<NSView *> *> *settingsTabGroups;
- (void)selectSettingsTab:(NSInteger)index;
- (void)registerTabView:(NSView *)view forTab:(NSInteger)tabIndex;
- (void)changeMascot:(MascotChoiceButton *)sender;
- (void)changeTheme:(id)sender;
- (void)applyTheme;
- (void)buildSettings;
- (instancetype)initWithDirectory:(NSString *)directory;
- (void)showOnScreen:(NSScreen *)screen;
- (void)stop;
- (void)showSettings:(id)sender;
- (void)changeSetting:(NSControl *)sender;
- (void)saveChange:(NSString *)key;
- (void)preview:(id)sender;
@end
