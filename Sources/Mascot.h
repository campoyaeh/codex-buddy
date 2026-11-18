#import <AppKit/AppKit.h>

FOUNDATION_EXPORT NSArray<NSDictionary *> *MascotCatalog(void);
FOUNDATION_EXPORT NSDictionary *MascotDefinition(NSString *identifier);
FOUNDATION_EXPORT NSImage *MascotImage(NSString *identifier, CGFloat size);
FOUNDATION_EXPORT void DrawMascot(NSString *identifier, NSRect rect, NSString *state);

@interface MascotAvatarView : NSView
@property(copy) NSString *mascotID;
@property(copy) NSString *state;
@end

@interface MascotChoiceButton : NSButton
@property(copy) NSString *mascotID;
@property BOOL chosen;
@end

@interface MascotGalleryView : NSView
@end
