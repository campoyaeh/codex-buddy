#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, InputMirrorStyle) {
    InputMirrorStyleGlass = 0,
    InputMirrorStyleObsidian = 1,
    InputMirrorStylePaper = 2,
    InputMirrorStyleTerminal = 3,
};

FOUNDATION_EXPORT NSArray<NSString *> *InputMirrorStyleTitles(void);

FOUNDATION_EXPORT BOOL InputMirrorIsSupportedAIApp(NSString * _Nullable bundleID,
                                                   NSString * _Nullable appName);
FOUNDATION_EXPORT BOOL InputMirrorIsIDEApp(NSString * _Nullable bundleID,
                                           NSString * _Nullable appName);
FOUNDATION_EXPORT BOOL InputMirrorIsAppExcluded(NSString * _Nullable bundleID,
                                                NSString * _Nullable appName,
                                                BOOL excludeIDEs,
                                                NSSet<NSString *> * _Nullable excludedTokens);

FOUNDATION_EXPORT BOOL InputMirrorIsPlaceholderText(NSString * _Nullable text,
                                                    NSString * _Nullable placeholderAttr,
                                                    NSString * _Nullable descriptionAttr,
                                                    NSString * _Nullable titleAttr,
                                                    NSRange selection);

FOUNDATION_EXPORT BOOL InputMirrorIsSecureMetadata(NSString * _Nullable role,
                                                   NSString * _Nullable subrole,
                                                   NSString * _Nullable roleDescription,
                                                   BOOL isProtected);

FOUNDATION_EXPORT BOOL InputMirrorIsEditableMetadata(NSString * _Nullable role,
                                                     NSString * _Nullable subrole,
                                                     NSString * _Nullable roleDescription,
                                                     BOOL isProtected,
                                                     BOOL editableAttr,
                                                     BOOL valueSettable,
                                                     BOOL hasSelectedRange);

FOUNDATION_EXPORT NSRect InputMirrorRestoredFrame(NSRect savedFrame,
                                                  CGDirectDisplayID savedScreenID,
                                                  NSArray<NSScreen *> *screens,
                                                  NSScreen * _Nullable fallbackScreen);

FOUNDATION_EXPORT CGFloat InputMirrorTargetHeightForContentHeight(CGFloat contentHeight);

FOUNDATION_EXPORT NSString *InputMirrorSummaryText(NSString * _Nullable text);

FOUNDATION_EXPORT NSAttributedStringKey const InputMirrorListBulletLevelAttributeName;
FOUNDATION_EXPORT NSAttributedStringKey const InputMirrorListBulletColorAttributeName;

FOUNDATION_EXPORT NSAttributedString *InputMirrorFormatAttributedText(NSString * _Nullable text,
                                                                      NSFont *baseFont,
                                                                      NSColor *textColor,
                                                                      NSColor *accentColor,
                                                                      NSColor *mutedColor,
                                                                      NSColor *codeBgColor,
                                                                      NSRange mirrorSelection,
                                                                      BOOL showMirrorSelection);

@interface InputMirrorPanel : NSPanel
@end

@interface InputMirrorTextView : NSTextView
@property(nonatomic) BOOL mirrorCaretVisible;
@property(nonatomic) BOOL mirrorCaretBlinkOn;
@property(nonatomic) NSRange mirrorSelectionRange;
@property(nonatomic, strong, nullable) NSColor *mirrorCaretColor;
@property(nonatomic, copy, nullable) NSString *mirrorPlaceholder;
@property(nonatomic, strong, nullable) NSColor *mirrorPlaceholderColor;
@property(nonatomic, readonly) BOOL showingMirrorPlaceholder;
@property(nonatomic, copy, nullable) void (^onSubmit)(void);
@property(nonatomic, copy, nullable) void (^onCancelEdit)(void);
@property(nonatomic, copy, nullable) void (^onCompositionChanged)(void);
@end

@interface InputMirrorController : NSObject <NSWindowDelegate, NSTextViewDelegate>
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL previewMode;
@property(nonatomic) BOOL excludeIDEs;
@property(nonatomic, copy) NSSet<NSString *> *excludedAppTokens;
@property(nonatomic) InputMirrorStyle style;
@property(nonatomic, readonly) BOOL visible;
@property(nonatomic, readonly) BOOL awaitingUserClickAfterJump;
@property(nonatomic, strong, readonly) InputMirrorPanel *panel;
@property(nonatomic, strong, readonly) InputMirrorTextView *textView;
@property(nonatomic, copy, readonly) NSString *mirroredText;
@property(nonatomic, readonly) NSRange mirroredSelection;
@property(nonatomic, copy, readonly) NSString *targetAppName;
@property(nonatomic, copy) NSString *defaultsKeyPrefix;
@property(nonatomic, copy, nullable) void (^onSyncBack)(NSString *text, BOOL shouldSend);

- (instancetype)init;
- (void)showPreviewSample;
- (void)resetSavedPosition;
- (void)updateMirroredText:(NSString *)text
                 selection:(NSRange)selection
                   appName:(NSString *)appName
                   appIcon:(NSImage * _Nullable)appIcon;
- (void)adjustHeightToFitContentAnimated:(BOOL)animated;
- (void)syncAndSend;
- (void)dismissTemporarily;
- (void)suppressAutoPopupUntilNextClick;
- (void)handleExternalMouseClick;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
