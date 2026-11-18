#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, PanelTheme) {
    PanelThemeDark,
    PanelThemeLight,
    PanelThemeSystem,
};

NSArray<NSString *> *PanelThemeTitles(void);
BOOL PanelIsDark(NSAppearance *appearance);
NSColor *PanelColor(uint32_t light, uint32_t dark, CGFloat alpha);

@interface PanelSurface : NSView
@property(nonatomic,strong) NSColor *fillColor;
@property(nonatomic,strong) NSColor *outlineColor;
@end
