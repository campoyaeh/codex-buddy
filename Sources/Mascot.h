#import <AppKit/AppKit.h>

FOUNDATION_EXPORT NSArray<NSDictionary *> *MascotCatalog(void);
FOUNDATION_EXPORT NSArray<NSDictionary *> *PresetAvatarCatalog(void);
FOUNDATION_EXPORT NSArray<NSDictionary *> *AllMascotCatalog(void);
FOUNDATION_EXPORT NSDictionary *MascotDefinition(NSString *identifier);
FOUNDATION_EXPORT NSImage *MascotImage(NSString *identifier, CGFloat size);
FOUNDATION_EXPORT void DrawMascot(NSString *identifier, NSRect rect, NSString *state);

FOUNDATION_EXPORT void MascotSetCustomAvatarDirectory(NSString *directory);
FOUNDATION_EXPORT NSString *MascotCustomAvatarDirectory(void);
FOUNDATION_EXPORT void MascotSetCustomAvatarName(NSString *name);
FOUNDATION_EXPORT NSString *MascotCustomAvatarName(void);
FOUNDATION_EXPORT BOOL MascotHasCustomAvatar(void);
FOUNDATION_EXPORT BOOL MascotHasCustomAvatarOriginal(void);
FOUNDATION_EXPORT BOOL MascotImportCustomAvatarFromURL(NSURL *url, BOOL removeBackground, NSError **error);
FOUNDATION_EXPORT BOOL MascotReprocessCustomAvatar(BOOL removeBackground, NSError **error);
FOUNDATION_EXPORT void MascotClearCustomAvatar(void);

@interface MascotAvatarView : NSView
@property(copy) NSString *mascotID;
@property(copy) NSString *state;
@end

@interface MascotChoiceButton : NSButton
@property(copy) NSString *mascotID;
@property BOOL chosen;
@property BOOL uploadPlaceholder;
@end

@interface MascotGalleryView : NSView
@end
