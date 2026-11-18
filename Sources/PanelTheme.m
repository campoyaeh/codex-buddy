#import "PanelTheme.h"
#import <QuartzCore/QuartzCore.h>

NSArray<NSString *> *PanelThemeTitles(void) {
    return @[@"深色", @"浅色", @"跟随系统"];
}

BOOL PanelIsDark(NSAppearance *appearance) {
    return [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
        isEqual:NSAppearanceNameDarkAqua];
}

NSColor *PanelColor(uint32_t light, uint32_t dark, CGFloat alpha) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        uint32_t rgb = PanelIsDark(appearance) ? dark : light;
        return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
            green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:alpha];
    }];
}

@implementation PanelSurface
- (void)setFillColor:(NSColor *)fillColor {
    _fillColor = fillColor;
    [self applyLayerColors];
}
- (void)setOutlineColor:(NSColor *)outlineColor {
    _outlineColor = outlineColor;
    [self applyLayerColors];
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self applyLayerColors];
}
- (void)applyLayerColors {
    self.wantsLayer = YES;
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.layer.backgroundColor = self.fillColor.CGColor;
        self.layer.borderColor = self.outlineColor.CGColor;
    }];
}
@end
