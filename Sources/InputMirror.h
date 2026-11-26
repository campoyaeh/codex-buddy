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
FOUNDATION_EXPORT NSAttributedStringKey const InputMirrorChipColorAttributeName;
FOUNDATION_EXPORT NSAttributedStringKey const InputMirrorChipFillColorAttributeName;

FOUNDATION_EXPORT NSAttributedString *InputMirrorFormatAttributedText(NSString * _Nullable text,
                                                                      NSFont *baseFont,
                                                                      NSColor *textColor,
                                                                      NSColor *accentColor,
                                                                      NSColor *mutedColor,
                                                                      NSColor *codeBgColor,
                                                                      NSRange mirrorSelection,
                                                                      BOOL showMirrorSelection);

typedef struct {
    BOOL active;
    NSRange tokenRange;
    unichar triggerChar;
} InputMirrorSkillTrigger;

typedef NS_ENUM(NSInteger, InputMirrorItemKind) {
    InputMirrorItemKindSkill = 0,
    InputMirrorItemKindSlashCommand,
    InputMirrorItemKindWorkflow,
    InputMirrorItemKindFile,
    InputMirrorItemKindFolder,
    InputMirrorItemKindConversation,
    InputMirrorItemKindMCP,
    InputMirrorItemKindRule,
    InputMirrorItemKindAgent,
    InputMirrorItemKindContext,
    InputMirrorItemKindNativeHandoff,
};

@interface InputMirrorSkillItem : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *displayTitle;
@property(nonatomic, copy) NSString *displayDetail;
@property(nonatomic, copy) NSString *summary;
@property(nonatomic, copy) NSString *insertPrefix;
@property(nonatomic, copy) NSString *sourceLabel;
@property(nonatomic, copy) NSString *categoryKey;
@property(nonatomic, copy) NSString *searchKeywords;
@property(nonatomic, copy) NSString *symbolName;
@property(nonatomic, copy, nullable) NSString *filePath;
@property(nonatomic) double recencyScore;
@property(nonatomic) InputMirrorItemKind itemKind;
@property(nonatomic) BOOL isNativeHandoffAction;
@property(nonatomic) BOOL requiresNativeHandoff;
@property(nonatomic) BOOL autoConfirmOnNativeHandoff;
@end

@interface InputMirrorSyncSegment : NSObject
@property(nonatomic) BOOL isNativeChip;
@property(nonatomic) unichar triggerChar;
@property(nonatomic, copy) NSString *text;
@property(nonatomic) BOOL consumesTrailingSpace;
@end

FOUNDATION_EXPORT NSArray<InputMirrorSyncSegment *> *InputMirrorBuildSyncSegments(NSString * _Nullable text,
                                                                                  NSSet<NSString *> * _Nullable confirmedChipTokens);

FOUNDATION_EXPORT InputMirrorSkillTrigger InputMirrorParseSkillTrigger(NSString * _Nullable text,
                                                                       NSRange selection,
                                                                       NSString * _Nullable * _Nullable outQuery);

FOUNDATION_EXPORT NSArray<InputMirrorSkillItem *> *InputMirrorLoadSlashCommandsForApp(NSString * _Nullable bundleID,
                                                                                      NSString * _Nullable appName);

FOUNDATION_EXPORT NSArray<InputMirrorSkillItem *> *InputMirrorLoadSkillsForApp(NSString * _Nullable bundleID,
                                                                               NSString * _Nullable appName,
                                                                               NSString * _Nullable homeDirOverride);

FOUNDATION_EXPORT NSArray<InputMirrorSkillItem *> *InputMirrorLoadSkillsForAppInWorkspace(NSString * _Nullable bundleID,
                                                                                          NSString * _Nullable appName,
                                                                                          NSString * _Nullable workspaceRoot,
                                                                                          NSString * _Nullable homeDirOverride);

FOUNDATION_EXPORT NSString * _Nullable InputMirrorResolveWorkspaceRootForApp(NSString * _Nullable bundleID,
                                                                             NSString * _Nullable appName,
                                                                             NSString * _Nullable homeDirOverride);

FOUNDATION_EXPORT NSArray<InputMirrorSkillItem *> *InputMirrorLoadMentionsForApp(NSString * _Nullable bundleID,
                                                                                 NSString * _Nullable appName,
                                                                                 NSString * _Nullable workspaceRoot);

FOUNDATION_EXPORT NSArray<InputMirrorSkillItem *> *InputMirrorLoadExtraMentionsForApp(NSString * _Nullable bundleID,
                                                                                      NSString * _Nullable appName,
                                                                                      NSString * _Nullable workspaceRoot,
                                                                                      NSString * _Nullable homeDirOverride);

FOUNDATION_EXPORT NSArray<InputMirrorSkillItem *> *InputMirrorLoadConversationMentionsForApp(NSString * _Nullable bundleID,
                                                                                             NSString * _Nullable appName,
                                                                                             NSString * _Nullable homeDirOverride);

FOUNDATION_EXPORT NSArray<InputMirrorSkillItem *> *InputMirrorFilterSkills(NSArray<InputMirrorSkillItem *> *skills,
                                                                           NSString * _Nullable query);

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
@property(nonatomic, copy, nullable) BOOL (^onSkillMenuKeyDown)(NSEvent *event);
@property(nonatomic, copy, nullable) BOOL (^onAtomicChipBackspace)(void);
@property(nonatomic, copy, nullable) void (^onNativeSlashHandoffShortcut)(void);
@property(nonatomic, copy, nullable) void (^onNativeMentionHandoffShortcut)(void);
@end

@interface InputMirrorController : NSObject <NSWindowDelegate, NSTextViewDelegate>
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL previewMode;
@property(nonatomic) BOOL excludeIDEs;
@property(nonatomic, copy) NSSet<NSString *> *excludedAppTokens;
@property(nonatomic) InputMirrorStyle style;
@property(nonatomic, readonly) BOOL visible;
@property(nonatomic, readonly) BOOL skillMenuVisible;
@property(nonatomic, copy, readonly) NSString *activeSkillMenuCategoryKey;
@property(nonatomic, copy, readonly) NSArray<NSString *> *availableSkillMenuCategories;
@property(nonatomic, copy, readonly) NSSet<NSString *> *confirmedChipTokens;
@property(nonatomic, readonly) BOOL lastNativeHandoffAutoConfirmed;
@property(nonatomic, readonly) BOOL awaitingUserClickAfterJump;
@property(nonatomic, readonly) BOOL hasUnsyncedEdits;
@property(nonatomic, strong, readonly) InputMirrorPanel *panel;
@property(nonatomic, strong, readonly) InputMirrorTextView *textView;
@property(nonatomic, copy, readonly) NSString *mirroredText;
@property(nonatomic, readonly) NSRange mirroredSelection;
@property(nonatomic, copy, readonly) NSString *targetAppName;
@property(nonatomic, copy, readonly) NSString *targetBundleID;
@property(nonatomic, copy, nullable) NSArray<InputMirrorSkillItem *> *overrideSkillsForTesting;
@property(nonatomic, copy, nullable) NSArray<InputMirrorSkillItem *> *overrideSlashCommandsForTesting;
@property(nonatomic, copy, nullable) NSArray<InputMirrorSkillItem *> *overrideMentionsForTesting;
@property(nonatomic, copy, nullable) NSString *overrideWorkspaceRootForTesting;
@property(nonatomic, copy) NSString *defaultsKeyPrefix;
@property(nonatomic, copy, nullable) void (^onSyncBack)(NSString *text, BOOL shouldSend);
@property(nonatomic, copy, nullable) void (^onNativeSlashHandoff)(NSString *text);
@property(nonatomic, copy, nullable) void (^onNativeMentionHandoff)(NSString *text);

- (instancetype)init;
- (void)showPreviewSample;
- (void)resetSavedPosition;
- (void)updateMirroredText:(NSString *)text
                 selection:(NSRange)selection
                   appName:(NSString *)appName
                   appIcon:(NSImage * _Nullable)appIcon;
- (void)adjustHeightToFitContentAnimated:(BOOL)animated;
- (void)syncAndSend;
- (void)handoffToNativeSlashMenu;
- (void)handoffToNativeMentionMenu;
- (void)dismissTemporarily;
- (void)suppressAutoPopupUntilNextClick;
- (void)handleExternalMouseClick;
- (void)handleActiveSpaceChange;
- (BOOL)reconcileExternalFocusText:(NSString *)text
                         selection:(NSRange)selection
                          bundleID:(NSString *)bundleID
                           appName:(NSString *)appName
                               pid:(pid_t)pid
                           appIcon:(NSImage * _Nullable)appIcon
                        sameTarget:(BOOL)sameTarget;
- (NSString * _Nullable)savedDraftTextForBundleID:(NSString *)bundleID appName:(NSString *)appName pid:(pid_t)pid;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
