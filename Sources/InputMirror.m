#import "InputMirror.h"
#import "PanelTheme.h"
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>
#import <sqlite3.h>
#import <sys/stat.h>

static const CGFloat kMirrorDefaultWidth = 600.0;
static const CGFloat kMirrorMinWidth = 380.0;
static const CGFloat kMirrorMinHeight = 112.0;
static const CGFloat kMirrorMaxHeight = 360.0;
static const CGFloat kMirrorHeaderHeight = 34.0;
static const CGFloat kMirrorBottomPadding = 12.0;
static const CGFloat kMirrorBodyFontSize = 15.0;
static const NSTimeInterval kMirrorPollInterval = 0.08;
static const NSTimeInterval kMirrorHideGraceInterval = 0.22;

NSArray<NSString *> *InputMirrorStyleTitles(void) {
    return @[@"毛玻璃极简", @"墨玉暗夜", @"柔纸暖光", @"霓虹终端"];
}

BOOL InputMirrorIsSupportedAIApp(NSString *bundleID, NSString *appName) {
    NSString *bid = bundleID.lowercaseString ?: @"";
    NSString *name = appName.lowercaseString ?: @"";
    if (!bid.length && !name.length) return NO;

    static NSArray<NSString *> *bundlePrefixes = nil;
    static NSArray<NSString *> *nameTokens = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundlePrefixes = @[
            @"com.openai.codex",
            @"com.openai.chat",
            @"com.anthropic.claude",
            @"com.todesktop.230313mzl4w4u92",
            @"com.cursor.",
            @"com.microsoft.vscode",
            @"com.google.antigravity",
            @"com.exafunction.windsurf",
            @"ai.devin.",
            @"ai.opencode.",
            @"com.trae.",
            @"cn.trae.",
            @"com.tencent.codebuddy",
            @"cn.tencent.codebuddy",
            @"com.codebuddy.",
            @"com.qoder.",
            @"com.alibaba.qoder",
            @"com.alibaba.lingma",
            @"com.alibaba.tongyi",
            @"com.alibaba.qianwen",
            @"com.deepseek.",
            @"com.minimax.",
            @"com.moonshot.kimi",
            @"ai.kimi."
        ];
        nameTokens = @[
            @"codex",
            @"chatgpt",
            @"claude",
            @"cursor",
            @"visual studio code",
            @"github copilot",
            @"antigravity",
            @"windsurf",
            @"devin",
            @"opencode",
            @"trae",
            @"codebuddy",
            @"qoder",
            @"lingma",
            @"qianwen",
            @"千问",
            @"deepseek",
            @"minimax",
            @"kimi"
        ];
    });

    for (NSString *prefix in bundlePrefixes) {
        if ([bid hasPrefix:prefix]) return YES;
    }
    for (NSString *token in nameTokens) {
        if ([name containsString:token]) return YES;
    }
    return NO;
}

BOOL InputMirrorIsIDEApp(NSString *bundleID, NSString *appName) {
    NSString *bid = bundleID.lowercaseString ?: @"";
    NSString *name = appName.lowercaseString ?: @"";
    static NSArray<NSString *> *idePrefixes = nil;
    static NSArray<NSString *> *ideTokens = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        idePrefixes = @[
            @"com.microsoft.vscode",
            @"com.todesktop.230313mzl4w4u92",
            @"com.cursor.",
            @"com.exafunction.windsurf",
            @"com.trae.",
            @"cn.trae.",
            @"com.qoder.",
            @"com.alibaba.qoder",
            @"com.alibaba.lingma",
            @"com.tencent.codebuddy",
            @"cn.tencent.codebuddy",
            @"com.codebuddy."
        ];
        ideTokens = @[
            @"visual studio code",
            @"cursor",
            @"windsurf",
            @"trae",
            @"qoder",
            @"lingma",
            @"codebuddy"
        ];
    });
    for (NSString *prefix in idePrefixes) {
        if ([bid hasPrefix:prefix]) return YES;
    }
    for (NSString *token in ideTokens) {
        if ([name containsString:token]) return YES;
    }
    return NO;
}

BOOL InputMirrorIsAppExcluded(NSString *bundleID, NSString *appName, BOOL excludeIDEs, NSSet<NSString *> *excludedTokens) {
    if (excludeIDEs && InputMirrorIsIDEApp(bundleID, appName)) return YES;
    if (!excludedTokens.count) return NO;
    NSString *bid = bundleID.lowercaseString ?: @"";
    NSString *name = appName.lowercaseString ?: @"";
    for (NSString *token in excludedTokens) {
        NSString *lower = token.lowercaseString;
        if (!lower.length) continue;
        if ([bid containsString:lower] || [name containsString:lower]) return YES;
    }
    return NO;
}

static NSString *IMNormalizePlaceholderCandidate(NSString *s) {
    if (!s.length) return @"";
    NSMutableCharacterSet *trim = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
    [trim addCharactersInString:@".…。"];
    return [[s stringByTrimmingCharactersInSet:trim] lowercaseString];
}

BOOL InputMirrorIsPlaceholderText(NSString *text,
                                  NSString *placeholderAttr,
                                  NSString *descriptionAttr,
                                  NSString *titleAttr,
                                  NSRange selection) {
    NSString *normText = IMNormalizePlaceholderCandidate(text);
    if (!normText.length) return NO;

    NSArray<NSString *> *attrs = @[
        placeholderAttr ?: @"",
        descriptionAttr ?: @"",
        titleAttr ?: @""
    ];
    for (NSString *attr in attrs) {
        NSString *normAttr = IMNormalizePlaceholderCandidate(attr);
        if (normAttr.length && [normText isEqualToString:normAttr]) {
            return YES;
        }
    }

    // Only apply known AI-app placeholder fallback when cursor is still at {0, 0} (empty input with CSS ::before placeholder)
    if (selection.location == 0 && selection.length == 0) {
        static NSSet<NSString *> *knownPlaceholders = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            knownPlaceholders = [NSSet setWithArray:@[
                @"和 codex 一起工作",
                @"ask codex",
                @"ask codex anything",
                @"ask anything",
                @"ask anything, @ to mention, / for workflows",
                @"ask anything, @ to mention",
                @"ask antigravity",
                @"message claude",
                @"reply to claude",
                @"how can i help you today?",
                @"how can i help you today",
                @"plan, search, build anything",
                @"plan, @ for context, / for commands",
                @"ask cursor",
                @"ask windsurf",
                @"ask trae",
                @"ask codebuddy",
                @"ask qoder",
                @"输入消息",
                @"请输入消息",
                @"输入你的问题",
                @"请输入你的问题",
                @"发消息",
                @"给千问发消息",
                @"向千问提问",
                @"问点什么",
                @"随便问点什么"
            ]];
        });
        if ([knownPlaceholders containsObject:normText]) {
            return YES;
        }
    }
    return NO;
}

static CGDirectDisplayID DisplayIDForScreen(NSScreen *screen) {
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    return number ? (CGDirectDisplayID)number.unsignedIntValue : 0;
}

static NSRect ClampRectToVisibleFrame(NSRect rect, NSRect visible) {
    if (NSIsEmptyRect(visible)) return rect;
    rect.size.width = MIN(MAX(rect.size.width, kMirrorMinWidth), MAX(kMirrorMinWidth, visible.size.width - 24.0));
    rect.size.height = MIN(MAX(rect.size.height, kMirrorMinHeight), MAX(kMirrorMinHeight, MIN(kMirrorMaxHeight, visible.size.height - 24.0)));
    CGFloat maxX = NSMaxX(visible) - rect.size.width;
    CGFloat maxY = NSMaxY(visible) - rect.size.height;
    rect.origin.x = MIN(MAX(rect.origin.x, NSMinX(visible)), MAX(NSMinX(visible), maxX));
    rect.origin.y = MIN(MAX(rect.origin.y, NSMinY(visible)), MAX(NSMinY(visible), maxY));
    return rect;
}

static NSRect DefaultFrameForScreen(NSScreen *screen) {
    NSRect visible = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
    CGFloat width = MIN(kMirrorDefaultWidth, MAX(kMirrorMinWidth, visible.size.width - 80.0));
    CGFloat height = kMirrorMinHeight;
    CGFloat x = NSMinX(visible) + floor((visible.size.width - width) * 0.5);
    CGFloat y = NSMinY(visible) + floor(visible.size.height * 0.24);
    return ClampRectToVisibleFrame(NSMakeRect(x, y, width, height), visible);
}

CGFloat InputMirrorTargetHeightForContentHeight(CGFloat contentHeight) {
    CGFloat desired = ceil(contentHeight) + kMirrorHeaderHeight + kMirrorBottomPadding + 22.0;
    return MIN(kMirrorMaxHeight, MAX(kMirrorMinHeight, desired));
}

BOOL InputMirrorIsSecureMetadata(NSString *role, NSString *subrole, NSString *roleDescription, BOOL isProtected) {
    if (isProtected) return YES;
    if ([role isEqualToString:@"AXSecureTextField"]) return YES;
    if ([subrole isEqualToString:@"AXSecureTextField"]) return YES;
    if (roleDescription.length) {
        NSString *lower = roleDescription.lowercaseString;
        if ([lower containsString:@"secure"] || [lower containsString:@"password"] || [lower containsString:@"密码"]) {
            return YES;
        }
    }
    return NO;
}

BOOL InputMirrorIsEditableMetadata(NSString *role,
                                   NSString *subrole,
                                   NSString *roleDescription,
                                   BOOL isProtected,
                                   BOOL editableAttr,
                                   BOOL valueSettable,
                                   BOOL hasSelectedRange) {
    if (InputMirrorIsSecureMetadata(role, subrole, roleDescription, isProtected)) return NO;
    if (!role.length) return NO;
    if ([role isEqualToString:(__bridge NSString *)kAXTextFieldRole] ||
        [role isEqualToString:(__bridge NSString *)kAXTextAreaRole] ||
        [role isEqualToString:(__bridge NSString *)kAXComboBoxRole] ||
        [role isEqualToString:@"AXSearchField"]) {
        return YES;
    }
    if ([subrole isEqualToString:(__bridge NSString *)kAXSearchFieldSubrole]) return YES;
    if (editableAttr) return YES;
    if (([role isEqualToString:(__bridge NSString *)kAXGroupRole] ||
         [role isEqualToString:@"AXWebArea"]) && valueSettable && hasSelectedRange) {
        return YES;
    }
    return NO;
}

NSRect InputMirrorRestoredFrame(NSRect savedFrame,
                                CGDirectDisplayID savedScreenID,
                                NSArray<NSScreen *> *screens,
                                NSScreen *fallbackScreen) {
    NSScreen *resolvedFallback = fallbackScreen ?: screens.firstObject;
    if (NSWidth(savedFrame) < 1.0 || NSHeight(savedFrame) < 1.0) {
        return DefaultFrameForScreen(resolvedFallback);
    }
    if (savedScreenID != 0) {
        for (NSScreen *screen in screens) {
            if (DisplayIDForScreen(screen) == savedScreenID) {
                return ClampRectToVisibleFrame(savedFrame, screen.visibleFrame);
            }
        }
    }
    for (NSScreen *screen in screens) {
        if (NSIntersectsRect(screen.visibleFrame, savedFrame)) {
            return ClampRectToVisibleFrame(savedFrame, screen.visibleFrame);
        }
    }
    if (!resolvedFallback) return savedFrame;
    NSRect visible = resolvedFallback.visibleFrame;
    NSRect moved = NSMakeRect(NSMinX(visible) + floor((visible.size.width - savedFrame.size.width) * 0.5),
                              NSMinY(visible) + floor(visible.size.height * 0.24),
                              savedFrame.size.width,
                              savedFrame.size.height);
    return ClampRectToVisibleFrame(moved, visible);
}

NSString *InputMirrorSummaryText(NSString *text) {
    NSString *value = text ?: @"";
    NSUInteger chars = value.length;
    NSUInteger lines = 1;
    for (NSUInteger i = 0; i < chars; i++) {
        if ([value characterAtIndex:i] == '\n') lines++;
    }
    return [NSString stringWithFormat:@"%lu 字 · %lu 行", (unsigned long)chars, (unsigned long)lines];
}

#pragma mark - Rich Text Formatting (Preserves Exact Character Indices)

NSAttributedStringKey const InputMirrorListBulletLevelAttributeName = @"InputMirrorListBulletLevel";
NSAttributedStringKey const InputMirrorListBulletColorAttributeName = @"InputMirrorListBulletColor";
NSAttributedStringKey const InputMirrorChipColorAttributeName = @"InputMirrorChipColor";
NSAttributedStringKey const InputMirrorChipFillColorAttributeName = @"InputMirrorChipFillColor";

static NSRegularExpression *IMRegex(NSString *pattern) {
    static NSMutableDictionary<NSString *, NSRegularExpression *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    NSRegularExpression *re = cache[pattern];
    if (!re) {
        re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        if (re) cache[pattern] = re;
    }
    return re;
}

static const CGFloat kMirrorListTabInterval = 20.0;

static NSUInteger IMIndentColumns(NSString *indent) {
    NSUInteger cols = 0;
    for (NSUInteger i = 0; i < indent.length; i++) {
        unichar c = [indent characterAtIndex:i];
        if (c == '\t') cols += 4;
        else if (c == 0x3000) cols += 2;
        else cols += 1;
    }
    return cols;
}

static NSUInteger IMListNestingLevel(NSString *indent) {
    if (!indent.length) return 0;
    BOOL hasNonTab = NO;
    for (NSUInteger i = 0; i < indent.length; i++) {
        if ([indent characterAtIndex:i] != '\t') {
            hasNonTab = YES;
            break;
        }
    }
    if (!hasNonTab) return indent.length;
    NSUInteger cols = IMIndentColumns(indent);
    return (cols == 0) ? 0 : (cols + 1) / 2;
}

static CGFloat IMLeadingFirstLineIndent(NSString *indent, NSFont *bodyFont) {
    if (!indent.length) return 0.0;
    // Literal tabs already advance by kMirrorListTabInterval; monospaced spaces already have full glyph width.
    if (bodyFont.isFixedPitch) return 0.0;
    CGFloat spaceCols = 0.0;
    for (NSUInteger i = 0; i < indent.length; i++) {
        unichar c = [indent characterAtIndex:i];
        if (c == '\t') continue;
        spaceCols += (c == 0x3000) ? 2.0 : 1.0;
    }
    return MIN(spaceCols * 4.5, 72.0);
}

static CGFloat IMRenderedPrefixWidth(NSString *indentStr,
                                     NSArray<NSString *> *segments,
                                     NSArray<NSFont *> *segmentFonts,
                                     NSFont *bodyFont,
                                     CGFloat firstLineHeadIndent,
                                     CGFloat tabInterval) {
    CGFloat x = firstLineHeadIndent;
    NSDictionary *bodyAttrs = @{NSFontAttributeName: bodyFont};
    for (NSUInteger i = 0; i < indentStr.length; i++) {
        unichar c = [indentStr characterAtIndex:i];
        if (c == '\t') {
            x = (floor(x / tabInterval) + 1.0) * tabInterval;
        } else {
            NSString *ch = [indentStr substringWithRange:NSMakeRange(i, 1)];
            x += [ch sizeWithAttributes:bodyAttrs].width;
        }
    }
    NSUInteger segCount = MIN(segments.count, segmentFonts.count);
    for (NSUInteger s = 0; s < segCount; s++) {
        NSString *seg = segments[s];
        NSFont *segFont = segmentFonts[s] ?: bodyFont;
        NSDictionary *segAttrs = @{NSFontAttributeName: segFont};
        for (NSUInteger i = 0; i < seg.length; i++) {
            unichar c = [seg characterAtIndex:i];
            if (c == '\t') {
                x = (floor(x / tabInterval) + 1.0) * tabInterval;
            } else {
                NSString *ch = [seg substringWithRange:NSMakeRange(i, 1)];
                x += [ch sizeWithAttributes:segAttrs].width;
            }
        }
    }
    return ceil(x);
}

static NSColor *IMBulletColorForLevel(NSUInteger level, NSColor *accentColor, NSColor *mutedColor) {
    if (level == 0) return accentColor;
    if (level == 1) return [accentColor colorWithAlphaComponent:0.80];
    if (level == 2) return [accentColor colorWithAlphaComponent:0.60];
    return mutedColor ?: [accentColor colorWithAlphaComponent:0.48];
}

NSAttributedString *InputMirrorFormatAttributedText(NSString *text,
                                                    NSFont *baseFont,
                                                    NSColor *textColor,
                                                    NSColor *accentColor,
                                                    NSColor *mutedColor,
                                                    NSColor *codeBgColor,
                                                    NSRange mirrorSelection,
                                                    BOOL showMirrorSelection) {
    NSString *safeText = text ?: @"";
    NSFont *font = baseFont ?: [NSFont systemFontOfSize:kMirrorBodyFontSize weight:NSFontWeightRegular];
    CGFloat fontSize = font.pointSize;
    NSFont *semiboldFont = [NSFont systemFontOfSize:fontSize weight:NSFontWeightSemibold];
    NSFont *mediumFont = [NSFont systemFontOfSize:fontSize weight:NSFontWeightMedium];
    NSFont *monoAccentFont = [NSFont monospacedDigitSystemFontOfSize:fontSize weight:NSFontWeightSemibold];
    NSFont *codeFont = [NSFont monospacedSystemFontOfSize:MAX(13.0, fontSize - 1.5) weight:NSFontWeightRegular];

    NSMutableParagraphStyle *defaultPara = [[NSMutableParagraphStyle alloc] init];
    defaultPara.lineSpacing = 5.0;
    defaultPara.paragraphSpacing = 2.5;
    defaultPara.tabStops = @[];
    defaultPara.defaultTabInterval = kMirrorListTabInterval;

    NSDictionary *baseAttrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: textColor ?: NSColor.labelColor,
        NSParagraphStyleAttributeName: defaultPara
    };
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:safeText attributes:baseAttrs];
    if (!safeText.length) return attr;

    NSRegularExpression *taskRe = IMRegex(@"^([ \\t\\u00A0\\u3000]*)([-*+•◦▪▫●○■□‣⁃·–—])([ \\t\\u00A0\\u3000]+)(\\[[ xX]\\])([ \\t\\u00A0\\u3000]+)");
    NSRegularExpression *ulRe = IMRegex(@"^([ \\t\\u00A0\\u3000]*)([-*+•◦▪▫●○■□‣⁃·–—])([ \\t\\u00A0\\u3000]+)");
    NSRegularExpression *olRe = IMRegex(@"^([ \\t\\u00A0\\u3000]*)(\\d+[.)、])([ \\t\\u00A0\\u3000]+)");
    NSRegularExpression *quoteRe = IMRegex(@"^([ \\t\\u00A0\\u3000]*)(>)([ \\t\\u00A0\\u3000]*)");
    NSRegularExpression *headingRe = IMRegex(@"^(#{1,3})([ \\t\\u00A0\\u3000]+)");
    NSRegularExpression *codeRe = IMRegex(@"`[^`\\n]+`");
    NSRegularExpression *boldRe = IMRegex(@"\\*\\*[^*\\n]+\\*\\*");
    NSRegularExpression *mentionRe = IMRegex(@"(?:^|(?<=[\\s(\\[{<,:;，。：、（）【\\p{Han}]))@[A-Za-z0-9_./\\-\\p{Han}]+");
    NSRegularExpression *skillTokenRe = IMRegex(@"(?:^|(?<=[\\s(\\[{]))\\$[A-Za-z_\\p{Han}][A-Za-z0-9_.\\-\\p{Han}]*");
    NSRegularExpression *slashCmdRe = IMRegex(@"(?:^|(?<=\\s))/[A-Za-z][A-Za-z0-9_.\\-]*(?=\\s|$)");

    NSUInteger pos = 0;
    NSUInteger len = safeText.length;
    while (pos < len) {
        NSRange lineRange = [safeText lineRangeForRange:NSMakeRange(pos, 0)];
        NSUInteger contentLen = lineRange.length;
        while (contentLen > 0) {
            unichar ch = [safeText characterAtIndex:lineRange.location + contentLen - 1];
            if (ch == '\n' || ch == '\r') contentLen--;
            else break;
        }
        NSRange contentRange = NSMakeRange(lineRange.location, contentLen);
        NSString *line = [safeText substringWithRange:contentRange];
        NSRange localAll = NSMakeRange(0, line.length);

        NSTextCheckingResult *match = nil;
        if ((match = [taskRe firstMatchInString:line options:0 range:localAll])) {
            NSString *indentStr = [line substringWithRange:[match rangeAtIndex:1]];
            NSRange bulletR = [match rangeAtIndex:2];
            NSString *bulletStr = [line substringWithRange:bulletR];
            NSString *midSpaceStr = [line substringWithRange:[match rangeAtIndex:3]];
            NSRange boxR = [match rangeAtIndex:4];
            NSString *boxStr = [line substringWithRange:boxR];
            NSString *afterSpaceStr = [line substringWithRange:[match rangeAtIndex:5]];
            BOOL checked = [boxStr containsString:@"x"] || [boxStr containsString:@"X"];

            NSUInteger level = IMListNestingLevel(indentStr);
            NSFont *bulletFont = (level == 0) ? semiboldFont : mediumFont;
            NSColor *bulletColor = IMBulletColorForLevel(level, accentColor, mutedColor);
            CGFloat firstIndent = IMLeadingFirstLineIndent(indentStr, font);
            CGFloat headIndent = IMRenderedPrefixWidth(indentStr,
                                                       @[bulletStr, midSpaceStr, boxStr, afterSpaceStr],
                                                       @[bulletFont, font, monoAccentFont, font],
                                                       font,
                                                       firstIndent,
                                                       kMirrorListTabInterval);
            NSMutableParagraphStyle *p = [defaultPara mutableCopy];
            p.firstLineHeadIndent = firstIndent;
            p.headIndent = MAX(firstIndent + 24.0, headIndent);
            if (level > 0) p.paragraphSpacing = 1.5;
            [attr addAttribute:NSParagraphStyleAttributeName value:p range:lineRange];

            [attr addAttribute:NSForegroundColorAttributeName value:bulletColor range:NSMakeRange(contentRange.location + bulletR.location, bulletR.length)];
            [attr addAttribute:NSFontAttributeName value:bulletFont range:NSMakeRange(contentRange.location + bulletR.location, bulletR.length)];
            [attr addAttribute:NSForegroundColorAttributeName value:(checked ? mutedColor : accentColor) range:NSMakeRange(contentRange.location + boxR.location, boxR.length)];
            [attr addAttribute:NSFontAttributeName value:monoAccentFont range:NSMakeRange(contentRange.location + boxR.location, boxR.length)];
            if (checked && match.range.length < contentRange.length) {
                NSRange rest = NSMakeRange(contentRange.location + match.range.length, contentRange.length - match.range.length);
                [attr addAttribute:NSForegroundColorAttributeName value:mutedColor range:rest];
                [attr addAttribute:NSStrikethroughStyleAttributeName value:@(NSUnderlineStyleSingle) range:rest];
            }
        } else if ((match = [ulRe firstMatchInString:line options:0 range:localAll])) {
            NSRange indentR = [match rangeAtIndex:1];
            NSString *indentStr = [line substringWithRange:indentR];
            NSRange bulletR = [match rangeAtIndex:2];
            NSString *bulletStr = [line substringWithRange:bulletR];
            NSRange afterSpaceR = [match rangeAtIndex:3];
            NSString *afterSpaceStr = [line substringWithRange:afterSpaceR];

            NSUInteger level = IMListNestingLevel(indentStr);
            BOOL hasTabIndent = [indentStr containsString:@"\t"];
            NSFont *bulletFont = (level == 0) ? semiboldFont : mediumFont;
            NSFont *tinyIndentFont = [NSFont systemFontOfSize:0.5 weight:NSFontWeightRegular];
            NSColor *bulletColor = IMBulletColorForLevel(level, accentColor, mutedColor);

            // Codex-style clean 20pt per-level nesting gutter:
            // Collapse literal leading spaces to 0.5pt clear glyphs so every nesting level aligns to an exact 20pt grid.
            CGFloat firstIndent = hasTabIndent ? 6.0 : MIN(6.0 + level * 20.0, 126.0);
            CGFloat afterSpaceKern = 3.5;
            CGFloat headIndent = IMRenderedPrefixWidth(hasTabIndent ? indentStr : @"",
                                                       @[bulletStr, afterSpaceStr],
                                                       @[bulletFont, font],
                                                       font,
                                                       firstIndent,
                                                       kMirrorListTabInterval) + afterSpaceKern;
            if (!hasTabIndent && indentR.length > 0) {
                NSRange absIndent = NSMakeRange(contentRange.location + indentR.location, indentR.length);
                [attr addAttribute:NSFontAttributeName value:tinyIndentFont range:absIndent];
                [attr addAttribute:NSForegroundColorAttributeName value:NSColor.clearColor range:absIndent];
            }

            NSMutableParagraphStyle *p = [defaultPara mutableCopy];
            p.firstLineHeadIndent = firstIndent;
            p.headIndent = MAX(firstIndent + 15.0, headIndent);
            if (level > 0) p.paragraphSpacing = 1.5;
            [attr addAttribute:NSParagraphStyleAttributeName value:p range:lineRange];

            // Hide raw ASCII/Unicode bullet glyph and attach vector bullet metadata for crisp Codex-style rendering in drawRect:
            NSRange absBullet = NSMakeRange(contentRange.location + bulletR.location, bulletR.length);
            [attr addAttribute:NSForegroundColorAttributeName value:NSColor.clearColor range:absBullet];
            [attr addAttribute:NSFontAttributeName value:bulletFont range:absBullet];
            [attr addAttribute:InputMirrorListBulletLevelAttributeName value:@(level) range:absBullet];
            if (bulletColor) {
                [attr addAttribute:InputMirrorListBulletColorAttributeName value:bulletColor range:absBullet];
            }
            if (afterSpaceR.length > 0) {
                NSRange absLastSpace = NSMakeRange(contentRange.location + NSMaxRange(afterSpaceR) - 1, 1);
                [attr addAttribute:NSKernAttributeName value:@(afterSpaceKern) range:absLastSpace];
            }
        } else if ((match = [olRe firstMatchInString:line options:0 range:localAll])) {
            NSString *indentStr = [line substringWithRange:[match rangeAtIndex:1]];
            NSRange numR = [match rangeAtIndex:2];
            NSString *numStr = [line substringWithRange:numR];
            NSString *afterSpaceStr = [line substringWithRange:[match rangeAtIndex:3]];

            NSUInteger level = IMListNestingLevel(indentStr);
            NSColor *numColor = IMBulletColorForLevel(level, accentColor, mutedColor);
            CGFloat firstIndent = IMLeadingFirstLineIndent(indentStr, font);
            CGFloat headIndent = IMRenderedPrefixWidth(indentStr,
                                                       @[numStr, afterSpaceStr],
                                                       @[monoAccentFont, font],
                                                       font,
                                                       firstIndent,
                                                       kMirrorListTabInterval);
            NSMutableParagraphStyle *p = [defaultPara mutableCopy];
            p.firstLineHeadIndent = firstIndent;
            p.headIndent = MAX(firstIndent + 18.0, headIndent);
            if (level > 0) p.paragraphSpacing = 1.5;
            [attr addAttribute:NSParagraphStyleAttributeName value:p range:lineRange];

            NSRange absNum = NSMakeRange(contentRange.location + numR.location, numR.length);
            [attr addAttribute:NSForegroundColorAttributeName value:numColor range:absNum];
            [attr addAttribute:NSFontAttributeName value:monoAccentFont range:absNum];
        } else if ((match = [quoteRe firstMatchInString:line options:0 range:localAll])) {
            NSString *indentStr = [line substringWithRange:[match rangeAtIndex:1]];
            NSRange barR = [match rangeAtIndex:2];
            NSString *barStr = [line substringWithRange:barR];
            NSString *afterSpaceStr = [line substringWithRange:[match rangeAtIndex:3]];

            CGFloat firstIndent = IMLeadingFirstLineIndent(indentStr, font) + 10.0;
            CGFloat headIndent = IMRenderedPrefixWidth(indentStr,
                                                       @[barStr, afterSpaceStr],
                                                       @[semiboldFont, font],
                                                       font,
                                                       firstIndent,
                                                       kMirrorListTabInterval);
            NSMutableParagraphStyle *p = [defaultPara mutableCopy];
            p.firstLineHeadIndent = firstIndent;
            p.headIndent = MAX(firstIndent + 12.0, headIndent);
            [attr addAttribute:NSParagraphStyleAttributeName value:p range:lineRange];

            [attr addAttribute:NSForegroundColorAttributeName value:mutedColor range:contentRange];
            NSRange absBar = NSMakeRange(contentRange.location + barR.location, barR.length);
            [attr addAttribute:NSForegroundColorAttributeName value:accentColor range:absBar];
            [attr addAttribute:NSFontAttributeName value:semiboldFont range:absBar];
        } else if ((match = [headingRe firstMatchInString:line options:0 range:localAll])) {
            NSRange hashR = [match rangeAtIndex:1];
            CGFloat boost = (hashR.length == 1) ? 4.0 : (hashR.length == 2 ? 2.5 : 1.0);
            NSFont *hFont = [NSFont systemFontOfSize:fontSize + boost weight:NSFontWeightSemibold];
            [attr addAttribute:NSFontAttributeName value:hFont range:contentRange];
            [attr addAttribute:NSForegroundColorAttributeName value:mutedColor range:NSMakeRange(contentRange.location + hashR.location, hashR.length)];
        }

        NSColor *chipBorder = [accentColor colorWithAlphaComponent:0.38];
        NSColor *chipFill = [accentColor colorWithAlphaComponent:0.13];
        for (NSTextCheckingResult *mm in [mentionRe matchesInString:line options:0 range:localAll]) {
            NSRange absR = NSMakeRange(contentRange.location + mm.range.location, mm.range.length);
            [attr addAttribute:NSForegroundColorAttributeName value:accentColor range:absR];
            [attr addAttribute:NSFontAttributeName value:semiboldFont range:absR];
            if (mm.range.length >= 2) {
                [attr addAttribute:InputMirrorChipColorAttributeName value:chipBorder range:absR];
                [attr addAttribute:InputMirrorChipFillColorAttributeName value:chipFill range:absR];
            }
        }

        for (NSTextCheckingResult *sm in [skillTokenRe matchesInString:line options:0 range:localAll]) {
            NSRange absR = NSMakeRange(contentRange.location + sm.range.location, sm.range.length);
            [attr addAttribute:NSForegroundColorAttributeName value:accentColor range:absR];
            [attr addAttribute:NSFontAttributeName value:semiboldFont range:absR];
            [attr addAttribute:InputMirrorChipColorAttributeName value:chipBorder range:absR];
            [attr addAttribute:InputMirrorChipFillColorAttributeName value:chipFill range:absR];
        }

        for (NSTextCheckingResult *slm in [slashCmdRe matchesInString:line options:0 range:localAll]) {
            NSRange absR = NSMakeRange(contentRange.location + slm.range.location, slm.range.length);
            [attr addAttribute:NSForegroundColorAttributeName value:accentColor range:absR];
            [attr addAttribute:NSFontAttributeName value:semiboldFont range:absR];
            [attr addAttribute:InputMirrorChipColorAttributeName value:chipBorder range:absR];
            [attr addAttribute:InputMirrorChipFillColorAttributeName value:chipFill range:absR];
        }

        for (NSTextCheckingResult *cm in [codeRe matchesInString:line options:0 range:localAll]) {
            NSRange absR = NSMakeRange(contentRange.location + cm.range.location, cm.range.length);
            [attr addAttribute:NSFontAttributeName value:codeFont range:absR];
            if (codeBgColor) [attr addAttribute:NSBackgroundColorAttributeName value:codeBgColor range:absR];
        }

        for (NSTextCheckingResult *bm in [boldRe matchesInString:line options:0 range:localAll]) {
            NSRange absR = NSMakeRange(contentRange.location + bm.range.location, bm.range.length);
            [attr addAttribute:NSFontAttributeName value:semiboldFont range:absR];
            if (bm.range.length >= 4) {
                [attr addAttribute:NSForegroundColorAttributeName value:mutedColor range:NSMakeRange(absR.location, 2)];
                [attr addAttribute:NSForegroundColorAttributeName value:mutedColor range:NSMakeRange(NSMaxRange(absR) - 2, 2)];
            }
        }

        pos = NSMaxRange(lineRange);
        if (lineRange.length == 0) break;
    }

    if (showMirrorSelection && mirrorSelection.length > 0 && NSMaxRange(mirrorSelection) <= safeText.length) {
        [attr addAttribute:NSBackgroundColorAttributeName
                     value:[accentColor colorWithAlphaComponent:0.28]
                     range:mirrorSelection];
    }
    return attr;
}

#pragma mark - Accessibility Helpers

static id IMAxCopyAttribute(AXUIElementRef element, CFStringRef attribute) {
    if (!element) return nil;
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

static BOOL IMAxIsAttributeSettable(AXUIElementRef element, CFStringRef attribute) {
    if (!element) return NO;
    Boolean settable = false;
    if (AXUIElementIsAttributeSettable(element, attribute, &settable) != kAXErrorSuccess) return NO;
    return settable ? YES : NO;
}

static BOOL IMAxReadSelectedRange(AXUIElementRef element, NSRange *outRange) {
    if (!element) return NO;
    id raw = IMAxCopyAttribute(element, kAXSelectedTextRangeAttribute);
    if (!raw || CFGetTypeID((__bridge CFTypeRef)raw) != AXValueGetTypeID()) return NO;
    CFRange cfRange = CFRangeMake(0, 0);
    if (!AXValueGetValue((__bridge AXValueRef)raw, kAXValueCFRangeType, &cfRange)) return NO;
    if (outRange) {
        NSUInteger loc = cfRange.location >= 0 ? (NSUInteger)cfRange.location : 0;
        NSUInteger len = cfRange.length >= 0 ? (NSUInteger)cfRange.length : 0;
        *outRange = NSMakeRange(loc, len);
    }
    return YES;
}

static NSString *IMTrimWhitespaceAndNBSP(NSString *s) {
    if (!s.length) return @"";
    static NSCharacterSet *trimSet = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *set = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
        [set addCharactersInString:@"\u00A0\u200B\uFEFF"];
        trimSet = [set copy];
    });
    return [s stringByTrimmingCharactersInSet:trimSet];
}

static NSUInteger IMAxExtraIndentLevel(AXUIElementRef element) {
    if (!element) return 0;
    id classes = IMAxCopyAttribute(element, CFSTR("AXDOMClassList"));
    if ([classes isKindOfClass:NSArray.class]) {
        for (id cls in (NSArray *)classes) {
            if (![cls isKindOfClass:NSString.class]) continue;
            NSString *c = (NSString *)cls;
            if ([c hasPrefix:@"ql-indent-"]) {
                NSInteger lvl = [[c substringFromIndex:10] integerValue];
                if (lvl > 0 && lvl <= 8) return (NSUInteger)lvl;
            }
        }
    }
    return 0;
}

static BOOL IMAxHasListChildren(AXUIElementRef element, NSUInteger depth) {
    if (!element || depth > 5) return NO;
    NSArray *children = IMAxCopyAttribute(element, kAXChildrenAttribute);
    if (![children isKindOfClass:NSArray.class] || !children.count) return NO;
    NSUInteger limit = MIN(children.count, (NSUInteger)32);
    for (NSUInteger i = 0; i < limit; i++) {
        AXUIElementRef child = (__bridge AXUIElementRef)children[i];
        id roleObj = IMAxCopyAttribute(child, kAXRoleAttribute);
        NSString *role = [roleObj isKindOfClass:NSString.class] ? roleObj : nil;
        if ([role isEqualToString:@"AXList"] || [role isEqualToString:@"AXListMarker"]) {
            return YES;
        }
        if (depth < 4 && ([role isEqualToString:@"AXGroup"] || [role isEqualToString:@"AXWebArea"])) {
            if (IMAxHasListChildren(child, depth + 1)) return YES;
        }
    }
    return NO;
}

static BOOL IMAxNodeLooksLikePlaceholder(AXUIElementRef element) {
    if (!element) return NO;
    id classes = IMAxCopyAttribute(element, CFSTR("AXDOMClassList"));
    if ([classes isKindOfClass:NSArray.class]) {
        for (id cls in (NSArray *)classes) {
            if ([cls isKindOfClass:NSString.class]) {
                NSString *lower = [(NSString *)cls lowercaseString];
                if ([lower containsString:@"placeholder"] || [lower isEqualToString:@"is-empty"] || [lower isEqualToString:@"is-editor-empty"]) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

static void IMAxCollectStructuredText(AXUIElementRef element, NSUInteger depth, NSUInteger *nodeBudget, NSMutableArray<NSString *> *lines) {
    if (!element || depth > 16 || !nodeBudget || *nodeBudget == 0) return;
    if (IMAxNodeLooksLikePlaceholder(element)) return;
    (*nodeBudget)--;

    id roleObj = IMAxCopyAttribute(element, kAXRoleAttribute);
    NSString *role = [roleObj isKindOfClass:NSString.class] ? roleObj : @"";

    if ([role isEqualToString:@"AXStaticText"]) {
        id val = IMAxCopyAttribute(element, kAXValueAttribute);
        if ([val isKindOfClass:NSString.class] && [(NSString *)val length] > 0) {
            [lines addObject:(NSString *)val];
        }
        return;
    }

    NSArray *children = IMAxCopyAttribute(element, kAXChildrenAttribute);
    if (![children isKindOfClass:NSArray.class] || !children.count) {
        id val = IMAxCopyAttribute(element, kAXValueAttribute);
        if ([val isKindOfClass:NSString.class] && [(NSString *)val length] > 0) {
            [lines addObject:(NSString *)val];
        }
        return;
    }

    if ([role isEqualToString:@"AXList"]) {
        for (id childObj in children) {
            if (*nodeBudget == 0) break;
            AXUIElementRef item = (__bridge AXUIElementRef)childObj;
            id itemRoleObj = IMAxCopyAttribute(item, kAXRoleAttribute);
            NSString *itemRole = [itemRoleObj isKindOfClass:NSString.class] ? itemRoleObj : @"";
            if ([itemRole isEqualToString:@"AXList"]) {
                // Direct nested AXList inside AXList (e.g. Lexical / rich web editors)
                NSMutableArray<NSString *> *nested = [NSMutableArray array];
                IMAxCollectStructuredText(item, depth + 1, nodeBudget, nested);
                for (NSString *nl in nested) {
                    [lines addObject:[@"  " stringByAppendingString:nl]];
                }
                continue;
            }
            NSUInteger extraLevels = IMAxExtraIndentLevel(item);
            NSString *extraPrefix = extraLevels > 0 ? [@"" stringByPaddingToLength:(extraLevels * 2) withString:@" " startingAtIndex:0] : @"";

            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            NSArray *itemChildren = IMAxCopyAttribute(item, kAXChildrenAttribute);
            if ([itemChildren isKindOfClass:NSArray.class] && itemChildren.count) {
                for (id subObj in itemChildren) {
                    if (*nodeBudget == 0) break;
                    AXUIElementRef sub = (__bridge AXUIElementRef)subObj;
                    id subRoleObj = IMAxCopyAttribute(sub, kAXRoleAttribute);
                    NSString *subRole = [subRoleObj isKindOfClass:NSString.class] ? subRoleObj : @"";
                    if ([subRole isEqualToString:@"AXListMarker"]) {
                        id m = IMAxCopyAttribute(sub, kAXValueAttribute) ?: IMAxCopyAttribute(sub, kAXTitleAttribute);
                        if ([m isKindOfClass:NSString.class] && [(NSString *)m length] > 0) {
                            NSString *marker = IMTrimWhitespaceAndNBSP((NSString *)m);
                            if (marker.length) [parts addObject:[marker stringByAppendingString:@" "]];
                        }
                    } else if ([subRole isEqualToString:@"AXList"]) {
                        if (parts.count) {
                            [lines addObject:[extraPrefix stringByAppendingString:[parts componentsJoinedByString:@""]]];
                            [parts removeAllObjects];
                        }
                        NSMutableArray<NSString *> *nested = [NSMutableArray array];
                        IMAxCollectStructuredText(sub, depth + 1, nodeBudget, nested);
                        for (NSString *nl in nested) {
                            [lines addObject:[extraPrefix stringByAppendingString:[@"  " stringByAppendingString:nl]]];
                        }
                    } else if (IMAxHasListChildren(sub, 0)) {
                        // Wrapper AXGroup inside <li> containing item text plus nested AXList(s)
                        NSMutableArray<NSString *> *subLines = [NSMutableArray array];
                        IMAxCollectStructuredText(sub, depth + 1, nodeBudget, subLines);
                        for (NSUInteger idx = 0; idx < subLines.count; idx++) {
                            NSString *sl = subLines[idx];
                            if (idx == 0 && parts.count > 0) {
                                [parts addObject:sl];
                                [lines addObject:[extraPrefix stringByAppendingString:[parts componentsJoinedByString:@""]]];
                                [parts removeAllObjects];
                            } else {
                                if (parts.count) {
                                    [lines addObject:[extraPrefix stringByAppendingString:[parts componentsJoinedByString:@""]]];
                                    [parts removeAllObjects];
                                }
                                [lines addObject:[extraPrefix stringByAppendingString:[@"  " stringByAppendingString:sl]]];
                            }
                        }
                    } else {
                        NSMutableArray<NSString *> *subParts = [NSMutableArray array];
                        IMAxCollectStructuredText(sub, depth + 1, nodeBudget, subParts);
                        if (subParts.count) [parts addObject:[subParts componentsJoinedByString:@""]];
                    }
                }
            } else {
                IMAxCollectStructuredText(item, depth + 1, nodeBudget, parts);
            }
            if (parts.count) {
                [lines addObject:[extraPrefix stringByAppendingString:[parts componentsJoinedByString:@""]]];
            }
        }
        return;
    }

    for (id childObj in children) {
        if (*nodeBudget == 0) break;
        AXUIElementRef child = (__bridge AXUIElementRef)childObj;
        id childRoleObj = IMAxCopyAttribute(child, kAXRoleAttribute);
        NSString *childRole = [childRoleObj isKindOfClass:NSString.class] ? childRoleObj : @"";
        if ([childRole isEqualToString:@"AXList"] || IMAxHasListChildren(child, 0)) {
            IMAxCollectStructuredText(child, depth + 1, nodeBudget, lines);
        } else if ([childRole isEqualToString:@"AXGroup"] || [childRole isEqualToString:@"AXHeading"]) {
            NSMutableArray<NSString *> *inlineParts = [NSMutableArray array];
            IMAxCollectStructuredText(child, depth + 1, nodeBudget, inlineParts);
            if (inlineParts.count) {
                [lines addObject:[inlineParts componentsJoinedByString:@""]];
            }
        } else {
            IMAxCollectStructuredText(child, depth + 1, nodeBudget, lines);
        }
    }
}

static void IMAxCollectInlineChipLabels(AXUIElementRef element, NSUInteger depth, NSUInteger *budget, NSMutableArray<NSString *> *labels) {
    if (!element || depth > 10 || !budget || *budget == 0) return;
    (*budget)--;
    id roleObj = IMAxCopyAttribute(element, kAXRoleAttribute);
    NSString *role = [roleObj isKindOfClass:NSString.class] ? roleObj : @"";
    if ([role isEqualToString:@"AXButton"] || [role isEqualToString:@"AXLink"]) {
        id titleObj = IMAxCopyAttribute(element, kAXTitleAttribute) ?: IMAxCopyAttribute(element, kAXDescriptionAttribute) ?: IMAxCopyAttribute(element, kAXValueAttribute);
        if ([titleObj isKindOfClass:NSString.class]) {
            NSString *label = IMTrimWhitespaceAndNBSP((NSString *)titleObj);
            if (label.length > 0) {
                if (![label hasPrefix:@"@"] && ![label hasPrefix:@"$"] && ![label hasPrefix:@"/"]) {
                    label = [@"@" stringByAppendingString:label];
                }
                [labels addObject:label];
                return;
            }
        }
    }
    NSArray *children = IMAxCopyAttribute(element, kAXChildrenAttribute);
    if (![children isKindOfClass:NSArray.class]) return;
    for (id child in children) {
        if (*budget == 0) break;
        IMAxCollectInlineChipLabels((__bridge AXUIElementRef)child, depth + 1, budget, labels);
    }
}

static NSString *IMReplaceObjectReplacementWithChipLabels(NSString *raw, AXUIElementRef element) {
    if (!raw.length || [raw rangeOfString:@"\uFFFC"].location == NSNotFound) return raw;
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    NSUInteger budget = 240;
    IMAxCollectInlineChipLabels(element, 0, &budget, labels);
    NSMutableString *rebuilt = [NSMutableString stringWithCapacity:raw.length + 32];
    NSUInteger labelIdx = 0;
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c == 0xFFFC) {
            if (labelIdx < labels.count) {
                [rebuilt appendString:labels[labelIdx++]];
            }
        } else {
            [rebuilt appendFormat:@"%C", c];
        }
    }
    return rebuilt;
}

static NSString *IMAxReadTextValue(AXUIElementRef element, BOOL *outUsedStructuredList) {
    if (outUsedStructuredList) *outUsedStructuredList = NO;
    if (!element) return @"";

    id placeholderObj = IMAxCopyAttribute(element, kAXPlaceholderValueAttribute);
    id descObj = IMAxCopyAttribute(element, kAXDescriptionAttribute);
    id titleObj = IMAxCopyAttribute(element, kAXTitleAttribute);
    NSString *placeholder = [placeholderObj isKindOfClass:NSString.class] ? placeholderObj : nil;
    NSString *desc = [descObj isKindOfClass:NSString.class] ? descObj : nil;
    NSString *title = [titleObj isKindOfClass:NSString.class] ? titleObj : nil;
    NSRange sel = NSMakeRange(0, 0);
    IMAxReadSelectedRange(element, &sel);

    // If AXNumberOfCharacters is explicitly 0 on a contenteditable/text input, any AXValue string is a CSS ::before placeholder!
    id charCountObj = IMAxCopyAttribute(element, kAXNumberOfCharactersAttribute);
    if ([charCountObj isKindOfClass:NSNumber.class] && [charCountObj integerValue] == 0) {
        return @"";
    }

    if (IMAxHasListChildren(element, 0)) {
        NSUInteger budget = 480;
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        IMAxCollectStructuredText(element, 0, &budget, lines);
        if (lines.count > 0) {
            NSString *joined = [lines componentsJoinedByString:@"\n"];
            if (InputMirrorIsPlaceholderText(joined, placeholder, desc, title, sel)) return @"";
            if (joined.length > 0) {
                if (outUsedStructuredList) *outUsedStructuredList = YES;
                return IMReplaceObjectReplacementWithChipLabels(joined, element);
            }
        }
    }

    id value = IMAxCopyAttribute(element, kAXValueAttribute);
    if ([value isKindOfClass:NSString.class]) {
        NSString *str = (NSString *)value;
        if (InputMirrorIsPlaceholderText(str, placeholder, desc, title, sel)) return @"";
        if (str.length > 0) {
            if ([str rangeOfString:@"\uFFFC"].location != NSNotFound && outUsedStructuredList) {
                *outUsedStructuredList = YES;
            }
            return IMReplaceObjectReplacementWithChipLabels(str, element);
        }
    }
    if ([charCountObj isKindOfClass:NSNumber.class]) {
        NSInteger count = [charCountObj integerValue];
        if (count > 0 && count < 200000) {
            CFRange range = CFRangeMake(0, count);
            AXValueRef rangeVal = AXValueCreate(kAXValueCFRangeType, &range);
            if (rangeVal) {
                CFTypeRef outStr = NULL;
                AXError err = AXUIElementCopyParameterizedAttributeValue(
                    element, kAXStringForRangeParameterizedAttribute, rangeVal, &outStr);
                CFRelease(rangeVal);
                if (err == kAXErrorSuccess && outStr) {
                    id bridged = CFBridgingRelease(outStr);
                    if ([bridged isKindOfClass:NSString.class]) {
                        NSString *s = (NSString *)bridged;
                        if (InputMirrorIsPlaceholderText(s, placeholder, desc, title, sel)) return @"";
                        if ([s rangeOfString:@"\uFFFC"].location != NSNotFound && outUsedStructuredList) {
                            *outUsedStructuredList = YES;
                        }
                        return IMReplaceObjectReplacementWithChipLabels(s, element);
                    }
                }
            }
        }
    }
    if ([value isKindOfClass:NSString.class]) {
        NSString *str = (NSString *)value;
        if (InputMirrorIsPlaceholderText(str, placeholder, desc, title, sel)) return @"";
        return IMReplaceObjectReplacementWithChipLabels(str, element);
    }
    return @"";
}

static BOOL IMAxIsEditableElement(AXUIElementRef element) {
    if (!element) return NO;
    id roleObj = IMAxCopyAttribute(element, kAXRoleAttribute);
    id subroleObj = IMAxCopyAttribute(element, kAXSubroleAttribute);
    id descObj = IMAxCopyAttribute(element, kAXRoleDescriptionAttribute);
    id protectedObj = IMAxCopyAttribute(element, CFSTR("AXProtected"));
    id editableObj = IMAxCopyAttribute(element, CFSTR("AXEditable"));
    NSString *role = [roleObj isKindOfClass:NSString.class] ? roleObj : nil;
    NSString *subrole = [subroleObj isKindOfClass:NSString.class] ? subroleObj : nil;
    NSString *desc = [descObj isKindOfClass:NSString.class] ? descObj : nil;
    BOOL isProtected = [protectedObj isKindOfClass:NSNumber.class] && [protectedObj boolValue];
    BOOL editableAttr = [editableObj isKindOfClass:NSNumber.class] && [editableObj boolValue];
    BOOL valueSettable = IMAxIsAttributeSettable(element, kAXValueAttribute);
    BOOL hasSelectedRange = IMAxReadSelectedRange(element, NULL);
    return InputMirrorIsEditableMetadata(role, subrole, desc, isProtected, editableAttr, valueSettable, hasSelectedRange);
}

static void IMSendKeyToPid(pid_t pid, CGKeyCode keyCode, CGEventFlags flags) {
    if (pid <= 0) return;
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    for (int down = 1; down >= 0; down--) {
        CGEventRef event = CGEventCreateKeyboardEvent(source, keyCode, down != 0);
        if (!event) continue;
        CGEventSetFlags(event, flags);
        CGEventPostToPid(pid, event);
        CFRelease(event);
    }
    if (source) CFRelease(source);
}

static void IMSendUnicodeTextToPidEx(pid_t pid, NSString *text, BOOL sendTriggerAsKeyCode) {
    if (pid <= 0 || !text.length) return;
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    NSUInteger len = text.length;
    NSUInteger i = 0;
    while (i < len) {
        unichar ch = [text characterAtIndex:i];
        if (ch == '\r') { i++; continue; }
        if (ch == '\n') {
            IMSendKeyToPid(pid, kVK_Return, kCGEventFlagMaskShift);
            i++;
            continue;
        }
        if (sendTriggerAsKeyCode && (ch == '/' || ch == '$' || ch == '@')) {
            CGKeyCode code = (ch == '/') ? kVK_ANSI_Slash : ((ch == '$') ? kVK_ANSI_4 : kVK_ANSI_2);
            CGEventFlags flags = (ch == '/') ? 0 : kCGEventFlagMaskShift;
            UniChar single = ch;
            for (int down = 1; down >= 0; down--) {
                CGEventRef event = CGEventCreateKeyboardEvent(source, code, down != 0);
                if (!event) continue;
                CGEventSetFlags(event, flags);
                CGEventKeyboardSetUnicodeString(event, 1, &single);
                CGEventPostToPid(pid, event);
                CFRelease(event);
            }
            i++;
            continue;
        }
        NSUInteger start = i;
        while (i < len && (i - start) < 16) {
            unichar c = [text characterAtIndex:i];
            if (c == '\n' || c == '\r') break;
            if (sendTriggerAsKeyCode && (c == '/' || c == '$' || c == '@')) break;
            // Avoid splitting a UTF-16 surrogate pair (e.g. Emoji) across chunk boundaries
            if ((i - start) == 15 && c >= 0xD800 && c <= 0xDBFF) break;
            i++;
        }
        NSUInteger chunkLen = i - start;
        if (chunkLen == 0) { i++; continue; }
        UniChar buf[16];
        [text getCharacters:buf range:NSMakeRange(start, chunkLen)];
        for (int down = 1; down >= 0; down--) {
            CGEventRef event = CGEventCreateKeyboardEvent(source, 0, down != 0);
            if (!event) continue;
            CGEventSetFlags(event, 0);
            CGEventKeyboardSetUnicodeString(event, (UniCharCount)chunkLen, buf);
            CGEventPostToPid(pid, event);
            CFRelease(event);
        }
    }
    if (source) CFRelease(source);
}

#pragma mark - Skill Discovery, Trigger Parsing & Filtering

@implementation InputMirrorSkillItem
- (instancetype)init {
    if ((self = [super init])) {
        _name = @"";
        _displayTitle = @"";
        _displayDetail = @"";
        _summary = @"";
        _insertPrefix = @"/";
        _sourceLabel = @"";
        _categoryKey = @"skills";
        _searchKeywords = @"";
        _symbolName = @"sparkles";
    }
    return self;
}
@end

@implementation InputMirrorSyncSegment
- (instancetype)init {
    if ((self = [super init])) {
        _text = @"";
    }
    return self;
}
@end

static BOOL IMIsTriggerBoundaryChar(unichar c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0x00A0 || c == 0x3000;
}

static BOOL IMIsNativeChipPrefixBoundary(unichar c) {
    return IMIsTriggerBoundaryChar(c) || c == '(' || c == '[' || c == '{';
}

static BOOL IMIsChipTokenTerminator(unichar c) {
    return IMIsTriggerBoundaryChar(c) || c == ')' || c == ']' || c == '}' || c == ',' || c == ';' ||
           c == 0x3001 || c == 0x3002 || c == 0xFF0C || c == 0xFF1B || c == 0xFF09 || c == 0x3011;
}

NSArray<InputMirrorSyncSegment *> *InputMirrorBuildSyncSegments(NSString *text,
                                                                NSSet<NSString *> *confirmedChipTokens) {
    NSString *safeText = text ?: @"";
    if (!safeText.length) return @[];
    if (!confirmedChipTokens.count) {
        InputMirrorSyncSegment *plain = [[InputMirrorSyncSegment alloc] init];
        plain.isNativeChip = NO;
        plain.text = safeText;
        return @[plain];
    }

    NSMutableArray<InputMirrorSyncSegment *> *segments = [NSMutableArray array];
    NSUInteger len = safeText.length;
    NSUInteger plainStart = 0;
    NSUInteger i = 0;

    while (i < len) {
        unichar ch = [safeText characterAtIndex:i];
        BOOL canTrigger = (ch == '@' || ch == '$' || ch == '/') &&
                          (i == 0 || IMIsNativeChipPrefixBoundary([safeText characterAtIndex:i - 1]));
        if (canTrigger) {
            NSUInteger end = i + 1;
            while (end < len && !IMIsChipTokenTerminator([safeText characterAtIndex:end])) {
                end++;
            }
            if (end > i + 1) {
                NSString *candidate = [safeText substringWithRange:NSMakeRange(i, end - i)];
                if ([confirmedChipTokens containsObject:candidate]) {
                    if (i > plainStart) {
                        InputMirrorSyncSegment *plain = [[InputMirrorSyncSegment alloc] init];
                        plain.isNativeChip = NO;
                        plain.text = [safeText substringWithRange:NSMakeRange(plainStart, i - plainStart)];
                        [segments addObject:plain];
                    }
                    InputMirrorSyncSegment *chip = [[InputMirrorSyncSegment alloc] init];
                    chip.isNativeChip = YES;
                    chip.triggerChar = ch;
                    chip.text = [candidate substringFromIndex:1];
                    if (end < len && [safeText characterAtIndex:end] == ' ') {
                        chip.consumesTrailingSpace = YES;
                        end += 1;
                    }
                    [segments addObject:chip];
                    i = end;
                    plainStart = end;
                    continue;
                }
            }
        }
        i++;
    }

    if (plainStart < len) {
        InputMirrorSyncSegment *tail = [[InputMirrorSyncSegment alloc] init];
        tail.isNativeChip = NO;
        tail.text = [safeText substringFromIndex:plainStart];
        [segments addObject:tail];
    }
    return segments;
}

static BOOL IMIsAtTriggerBoundaryChar(unichar c) {
    if (IMIsTriggerBoundaryChar(c)) return YES;
    if (c == '(' || c == '[' || c == '{' || c == '<' || c == ',' || c == ';' || c == ':') return YES;
    if (c == 0x3001 || c == 0x3002 || c == 0xFF0C || c == 0xFF1A || c == 0xFF08 || c == 0x3010) return YES;
    // Allow CJK ideographs directly before '@' (e.g. "帮我看看@README.md") while rejecting ASCII email local parts
    if (c >= 0x4E00 && c <= 0x9FFF) return YES;
    return NO;
}

InputMirrorSkillTrigger InputMirrorParseSkillTrigger(NSString *text,
                                                     NSRange selection,
                                                     NSString **outQuery) {
    InputMirrorSkillTrigger result = { NO, NSMakeRange(NSNotFound, 0), 0 };
    if (outQuery) *outQuery = @"";
    if (!text.length || selection.length != 0 || selection.location == 0 || selection.location > text.length) {
        return result;
    }

    NSUInteger caret = selection.location;
    NSUInteger minScan = (caret > 96) ? (caret - 96) : 0;
    BOOL sawInnerSlash = NO;
    for (NSInteger idx = (NSInteger)caret - 1; idx >= (NSInteger)minScan; idx--) {
        unichar c = [text characterAtIndex:(NSUInteger)idx];
        if (IMIsTriggerBoundaryChar(c)) {
            return result;
        }
        if (c == '@') {
            if (idx > 0 && !IMIsAtTriggerBoundaryChar([text characterAtIndex:(NSUInteger)(idx - 1)])) {
                return result;
            }
            NSUInteger tokenLoc = (NSUInteger)idx;
            NSUInteger tokenLen = caret - tokenLoc;
            result.active = YES;
            result.tokenRange = NSMakeRange(tokenLoc, tokenLen);
            result.triggerChar = '@';
            if (outQuery) {
                *outQuery = (tokenLen > 1) ? [text substringWithRange:NSMakeRange(tokenLoc + 1, tokenLen - 1)] : @"";
            }
            return result;
        }
        if (c == '/' || c == '$') {
            if (!sawInnerSlash && (idx == 0 || IMIsTriggerBoundaryChar([text characterAtIndex:(NSUInteger)(idx - 1)]))) {
                NSUInteger tokenLoc = (NSUInteger)idx;
                NSUInteger tokenLen = caret - tokenLoc;
                result.active = YES;
                result.tokenRange = NSMakeRange(tokenLoc, tokenLen);
                result.triggerChar = c;
                if (outQuery) {
                    *outQuery = (tokenLen > 1) ? [text substringWithRange:NSMakeRange(tokenLoc + 1, tokenLen - 1)] : @"";
                }
                return result;
            }
            if (c == '/') {
                // Keep scanning backwards in case this is a path inside an @ mention (e.g. "@Sources/InputMirror.m")
                sawInnerSlash = YES;
                continue;
            }
            return result;
        }
    }
    return result;
}

static NSString *IMStripYAMLQuotes(NSString *raw) {
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length >= 2) {
        unichar first = [trimmed characterAtIndex:0];
        unichar last = [trimmed characterAtIndex:trimmed.length - 1];
        if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
            trimmed = [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
        }
    }
    return [trimmed stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL IMStringContainsCJK(NSString *str) {
    for (NSUInteger i = 0; i < str.length; i++) {
        unichar c = [str characterAtIndex:i];
        if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF)) {
            return YES;
        }
    }
    return NO;
}

static void IMParseOpenAIYamlMetadata(NSString *skillDirPath,
                                      NSString **outDisplayName,
                                      NSString **outShortDescription) {
    NSString *displayName = @"";
    NSString *shortDesc = @"";
    if (skillDirPath.length > 0) {
        NSString *yamlPath = [[skillDirPath stringByAppendingPathComponent:@"agents"] stringByAppendingPathComponent:@"openai.yaml"];
        NSData *data = [NSData dataWithContentsOfFile:yamlPath];
        if (data.length > 0) {
            NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            for (NSString *line in [content componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                NSString *lower = trimmed.lowercaseString;
                if ([lower hasPrefix:@"display_name:"]) {
                    NSString *val = IMStripYAMLQuotes([trimmed substringFromIndex:13]);
                    if (val.length > 0) displayName = val;
                } else if ([lower hasPrefix:@"short_description:"]) {
                    NSString *val = IMStripYAMLQuotes([trimmed substringFromIndex:18]);
                    if (val.length > 0) shortDesc = val;
                }
            }
        }
    }
    if (outDisplayName) *outDisplayName = displayName;
    if (outShortDescription) *outShortDescription = shortDesc;
}

static void IMParseSkillMarkdownFileEx(NSString *mdPath,
                                       NSString *fallbackName,
                                       NSString **outName,
                                       NSString **outDisplayName,
                                       NSString **outSummary) {
    NSString *resolvedName = fallbackName ?: @"";
    NSString *resolvedDisplayName = @"";
    NSString *resolvedSummary = @"";
    NSString *firstH1 = @"";

    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:mdPath];
    NSData *data = nil;
    if (fh) {
        data = [fh readDataOfLength:8192];
        [fh closeFile];
    }
    if (data.length > 0) {
        NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!content) {
            content = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        }
        if (content.length > 0) {
            NSArray<NSString *> *lines = [content componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
            BOOL inFrontmatter = NO;
            BOOL finishedFrontmatter = NO;
            BOOL collectingDesc = NO;
            NSMutableArray<NSString *> *descParts = [NSMutableArray array];
            for (NSUInteger i = 0; i < lines.count; i++) {
                NSString *line = lines[i];
                NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (i == 0 && [trimmed isEqualToString:@"---"]) {
                    inFrontmatter = YES;
                    continue;
                }
                if (inFrontmatter) {
                    if ([trimmed isEqualToString:@"---"]) {
                        inFrontmatter = NO;
                        finishedFrontmatter = YES;
                        collectingDesc = NO;
                        continue;
                    }
                    if (collectingDesc) {
                        BOOL isIndented = (line.length > 0 && ([line characterAtIndex:0] == ' ' || [line characterAtIndex:0] == '\t'));
                        if (isIndented && trimmed.length > 0) {
                            [descParts addObject:trimmed];
                            continue;
                        } else if (!isIndented && trimmed.length > 0) {
                            collectingDesc = NO;
                        }
                    }
                    NSString *lower = trimmed.lowercaseString;
                    if ([lower hasPrefix:@"name:"]) {
                        NSString *val = IMStripYAMLQuotes([trimmed substringFromIndex:5]);
                        if (val.length > 0) resolvedName = val;
                    } else if ([lower hasPrefix:@"display_name:"]) {
                        NSString *val = IMStripYAMLQuotes([trimmed substringFromIndex:13]);
                        if (val.length > 0) resolvedDisplayName = val;
                    } else if ([lower hasPrefix:@"title:"]) {
                        NSString *val = IMStripYAMLQuotes([trimmed substringFromIndex:6]);
                        if (val.length > 0) resolvedDisplayName = val;
                    } else if ([lower hasPrefix:@"description:"]) {
                        NSString *rawVal = [[trimmed substringFromIndex:12] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                        if ([rawVal isEqualToString:@">"] || [rawVal isEqualToString:@"|"] ||
                            [rawVal isEqualToString:@">-"] || [rawVal isEqualToString:@"|-"] ||
                            rawVal.length == 0) {
                            collectingDesc = YES;
                        } else {
                            [descParts addObject:IMStripYAMLQuotes(rawVal)];
                            collectingDesc = YES;
                        }
                    }
                } else {
                    if (!firstH1.length && [trimmed hasPrefix:@"# "] && trimmed.length > 2) {
                        firstH1 = [[trimmed substringFromIndex:2] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                        if (!finishedFrontmatter && resolvedSummary.length > 0) break;
                        if (finishedFrontmatter) break;
                        continue;
                    }
                    // Fallback: grab first non-heading prose line if no YAML frontmatter
                    if (!finishedFrontmatter && !resolvedSummary.length && trimmed.length > 0 && ![trimmed hasPrefix:@"#"] && ![trimmed hasPrefix:@"---"]) {
                        resolvedSummary = trimmed;
                        if (firstH1.length > 0) break;
                    }
                }
            }
            if (descParts.count > 0) {
                resolvedSummary = [descParts componentsJoinedByString:@" "];
            }
        }
    }

    if (!resolvedDisplayName.length && firstH1.length > 0 && firstH1.length <= 36 && IMStringContainsCJK(firstH1)) {
        resolvedDisplayName = firstH1;
    }
    if (!resolvedDisplayName.length && resolvedSummary.length > 0) {
        NSRange colonRange = [resolvedSummary rangeOfString:@"："];
        if (colonRange.location != NSNotFound && colonRange.location >= 2 && colonRange.location <= 22) {
            NSString *prefix = [resolvedSummary substringToIndex:colonRange.location];
            if (IMStringContainsCJK(prefix) && ![prefix containsString:@" "]) {
                resolvedDisplayName = prefix;
            }
        }
    }

    if (resolvedSummary.length > 140) {
        resolvedSummary = [[resolvedSummary substringToIndex:139] stringByAppendingString:@"…"];
    }
    if (outName) *outName = resolvedName;
    if (outDisplayName) *outDisplayName = resolvedDisplayName;
    if (outSummary) *outSummary = resolvedSummary;
}

static void IMConfigureSkillOrWorkflowItem(InputMirrorSkillItem *item,
                                           NSString *name,
                                           NSString *humanTitle,
                                           NSString *shortSummary,
                                           NSString *fullSummary,
                                           NSString *insertPrefix,
                                           NSString *sourceLabel,
                                           NSString *filePath,
                                           BOOL isWorkflow) {
    NSString *safeName = name ?: @"";
    NSString *pref = insertPrefix ?: @"/";
    NSString *tokenLabel = [NSString stringWithFormat:@"%@%@", pref, safeName];
    BOOL hasDistinctHumanTitle = (humanTitle.length > 0 && ![humanTitle.lowercaseString isEqualToString:safeName.lowercaseString]);

    item.name = safeName;
    item.displayTitle = hasDistinctHumanTitle ? humanTitle : tokenLabel;
    item.displayDetail = hasDistinctHumanTitle ? tokenLabel : @"";
    item.summary = shortSummary.length ? shortSummary : (fullSummary ?: @"");
    item.searchKeywords = [NSString stringWithFormat:@"%@ %@ %@", humanTitle ?: @"", fullSummary ?: @"", shortSummary ?: @""];
    item.insertPrefix = pref;
    item.sourceLabel = sourceLabel ?: (isWorkflow ? @"工作流" : @"技能");
    item.categoryKey = @"skills";
    item.symbolName = isWorkflow ? @"arrow.triangle.branch" : @"sparkles";
    item.filePath = filePath;
    item.itemKind = isWorkflow ? InputMirrorItemKindWorkflow : InputMirrorItemKindSkill;
}

static void IMScanSkillDirectoryEx(NSString *dirPath,
                                   NSString *sourceLabel,
                                   NSString *insertPrefix,
                                   NSInteger maxSubdirDepth,
                                   BOOL treatLooseMarkdownAsWorkflow,
                                   NSMutableDictionary<NSString *, InputMirrorSkillItem *> *seen,
                                   NSMutableArray<InputMirrorSkillItem *> *outItems) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!dirPath.length || ![fm fileExistsAtPath:dirPath isDirectory:&isDir] || !isDir) return;

    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    if (!entries.count) return;
    entries = [entries sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"."]) continue;
        NSString *fullPath = [dirPath stringByAppendingPathComponent:entry];
        NSString *resolvedPath = [fullPath stringByResolvingSymlinksInPath];
        BOOL entryIsDir = NO;
        if (![fm fileExistsAtPath:resolvedPath isDirectory:&entryIsDir]) continue;

        if (entryIsDir) {
            NSString *skillMd = [resolvedPath stringByAppendingPathComponent:@"SKILL.md"];
            if ([fm fileExistsAtPath:skillMd]) {
                NSString *name = nil;
                NSString *mdDisplayName = nil;
                NSString *summary = nil;
                IMParseSkillMarkdownFileEx(skillMd, entry, &name, &mdDisplayName, &summary);
                NSString *yamlDisplayName = nil;
                NSString *yamlShortDesc = nil;
                IMParseOpenAIYamlMetadata(resolvedPath, &yamlDisplayName, &yamlShortDesc);
                NSString *humanTitle = yamlDisplayName.length ? yamlDisplayName : mdDisplayName;
                NSString *key = name.lowercaseString;
                if (name.length > 0 && !seen[key]) {
                    InputMirrorSkillItem *item = [[InputMirrorSkillItem alloc] init];
                    IMConfigureSkillOrWorkflowItem(item, name, humanTitle, yamlShortDesc, summary, insertPrefix, sourceLabel, skillMd, NO);
                    seen[key] = item;
                    [outItems addObject:item];
                }
            } else if (maxSubdirDepth > 0) {
                IMScanSkillDirectoryEx(resolvedPath, sourceLabel, insertPrefix, maxSubdirDepth - 1, treatLooseMarkdownAsWorkflow, seen, outItems);
            }
        } else if ([entry.pathExtension.lowercaseString isEqualToString:@"md"] &&
                   ![entry.lowercaseString isEqualToString:@"readme.md"]) {
            NSString *fallback = [entry stringByDeletingPathExtension];
            NSString *name = nil;
            NSString *mdDisplayName = nil;
            NSString *summary = nil;
            IMParseSkillMarkdownFileEx(resolvedPath, fallback, &name, &mdDisplayName, &summary);
            NSString *key = name.lowercaseString;
            if (name.length > 0 && !seen[key]) {
                InputMirrorSkillItem *item = [[InputMirrorSkillItem alloc] init];
                IMConfigureSkillOrWorkflowItem(item, name, mdDisplayName, nil, summary, insertPrefix, sourceLabel, resolvedPath, treatLooseMarkdownAsWorkflow);
                seen[key] = item;
                [outItems addObject:item];
            }
        }
    }
}

static void IMScanSkillDirectory(NSString *dirPath,
                                 NSString *sourceLabel,
                                 NSString *insertPrefix,
                                 NSInteger maxSubdirDepth,
                                 NSMutableDictionary<NSString *, InputMirrorSkillItem *> *seen,
                                 NSMutableArray<InputMirrorSkillItem *> *outItems) {
    IMScanSkillDirectoryEx(dirPath, sourceLabel, insertPrefix, maxSubdirDepth, NO, seen, outItems);
}

static NSString *IMSkillAppFamilyKey(NSString *bundleID, NSString *appName) {
    NSString *bid = bundleID.lowercaseString ?: @"";
    NSString *name = appName.lowercaseString ?: @"";
    if ([bid hasPrefix:@"com.openai.codex"] || [name containsString:@"codex"]) return @"codex";
    if ([bid hasPrefix:@"com.google.antigravity"] || [name containsString:@"antigravity"]) return @"antigravity";
    if ([bid hasPrefix:@"com.anthropic.claude"] || [name containsString:@"claude"]) return @"claude";
    if ([bid hasPrefix:@"com.todesktop.230313mzl4w4u92"] || [bid hasPrefix:@"com.cursor."] || [name containsString:@"cursor"]) return @"cursor";
    if ([bid hasPrefix:@"com.microsoft.vscode"] || [name containsString:@"visual studio code"] || [name containsString:@"github copilot"]) return @"vscode";
    if ([bid hasPrefix:@"com.exafunction.windsurf"] || [bid hasPrefix:@"ai.devin."] || [name containsString:@"windsurf"] || [name containsString:@"devin"]) return @"windsurf";
    if ([bid hasPrefix:@"com.trae."] || [bid hasPrefix:@"cn.trae."] || [name containsString:@"trae"]) return @"trae";
    if ([bid hasPrefix:@"com.tencent.codebuddy"] || [bid hasPrefix:@"cn.tencent.codebuddy"] || [bid hasPrefix:@"com.codebuddy."] || [name containsString:@"codebuddy"]) return @"codebuddy";
    if ([bid hasPrefix:@"com.qoder."] || [bid hasPrefix:@"com.alibaba.qoder"] || [bid hasPrefix:@"com.alibaba.lingma"] || [name containsString:@"qoder"] || [name containsString:@"lingma"]) return @"qoder";
    if ([bid hasPrefix:@"ai.opencode."] || [name containsString:@"opencode"]) return @"opencode";
    if ([bid hasPrefix:@"com.openai.chat"] || [name containsString:@"chatgpt"]) return @"chatgpt";
    if ([bid hasPrefix:@"com.alibaba.tongyi"] || [bid hasPrefix:@"com.alibaba.qianwen"] || [name containsString:@"qianwen"] || [name containsString:@"千问"]) return @"qianwen";
    if ([bid hasPrefix:@"com.deepseek."] || [name containsString:@"deepseek"]) return @"deepseek";
    if ([bid hasPrefix:@"com.minimax."] || [name containsString:@"minimax"]) return @"minimax";
    if ([bid hasPrefix:@"com.moonshot.kimi"] || [bid hasPrefix:@"ai.kimi."] || [name containsString:@"kimi"]) return @"kimi";
    return @"generic";
}

static InputMirrorSkillItem *IMMakeSlashCommand(NSString *name,
                                                NSString *detailTitle,
                                                NSString *summary,
                                                NSString *keywords,
                                                NSString *symbolName,
                                                BOOL requiresNativeHandoff,
                                                BOOL autoConfirm) {
    InputMirrorSkillItem *item = [[InputMirrorSkillItem alloc] init];
    item.name = name;
    item.displayTitle = [@"/" stringByAppendingString:name];
    item.displayDetail = detailTitle ?: @"";
    item.summary = summary ?: @"";
    item.insertPrefix = @"/";
    item.sourceLabel = @"命令";
    item.categoryKey = @"commands";
    item.searchKeywords = keywords ?: @"";
    item.symbolName = symbolName.length ? symbolName : @"terminal";
    item.itemKind = InputMirrorItemKindSlashCommand;
    item.requiresNativeHandoff = requiresNativeHandoff;
    item.autoConfirmOnNativeHandoff = autoConfirm;
    return item;
}

NSArray<InputMirrorSkillItem *> *InputMirrorLoadSlashCommandsForApp(NSString *bundleID,
                                                                     NSString *appName) {
    NSString *family = IMSkillAppFamilyKey(bundleID, appName);
    if ([family isEqualToString:@"codex"]) {
        // Official Codex Desktop composer slash commands (executes or opens native submenu in Codex)
        return @[
            IMMakeSlashCommand(@"review", @"代码审查", @"审查当前工作区或分支的代码变更", @"review cr diff 代码审查 检视", @"magnifyingglass", YES, YES),
            IMMakeSlashCommand(@"plan", @"计划模式", @"开启或关闭 Plan 规划模式", @"plan mode 计划 规划 方案", @"list.bullet.clipboard", YES, YES),
            IMMakeSlashCommand(@"compact", @"压缩上下文", @"压缩当前对话上下文，释放窗口空间", @"compact summarize 压缩 总结 上下文", @"arrow.down.right.and.arrow.up.left", YES, YES),
            IMMakeSlashCommand(@"fast", @"快速模式", @"切换高速推理档位与标准速度", @"fast speed 快速 加速 速度", @"bolt", YES, YES),
            IMMakeSlashCommand(@"model", @"切换模型", @"选择或切换当前对话使用的模型", @"model 模型 切换 gpt codex o3", @"cpu", YES, YES),
            IMMakeSlashCommand(@"reasoning", @"推理强度", @"调整模型思考与推理深度档位", @"reasoning effort 推理 思考 深度", @"brain", YES, YES),
            IMMakeSlashCommand(@"new", @"新建对话", @"在当前工作区开启空白新对话", @"new chat 新建 新对话 清空", @"plus.bubble", YES, YES),
            IMMakeSlashCommand(@"fork", @"分支对话", @"从当前对话创建分支或隔离 Worktree 对话", @"fork branch 分支 派生", @"arrow.triangle.branch", YES, YES),
            IMMakeSlashCommand(@"worktree", @"Worktree 模式", @"切换在独立 Git Worktree 中运行当前对话", @"worktree git 隔离 分支目录", @"folder.badge.gearshape", YES, YES),
            IMMakeSlashCommand(@"local", @"本地运行", @"切换在当前本地工作区直接运行对话", @"local 本地 工作区", @"laptopcomputer", YES, YES),
            IMMakeSlashCommand(@"status", @"会话状态", @"查看会话 ID、上下文占用与速率限制", @"status token context 状态 额度 上下文", @"chart.bar", YES, YES),
            IMMakeSlashCommand(@"mcp", @"MCP 状态", @"查看已连接的 MCP 服务与工具状态", @"mcp server tools 工具 服务", @"server.rack", YES, YES),
            IMMakeSlashCommand(@"memories", @"对话记忆", @"管理当前对话的记忆读取与生成开关", @"memories memory 记忆", @"memorychip", YES, YES),
            IMMakeSlashCommand(@"init", @"初始化指引", @"扫描仓库并生成 AGENTS.md 项目指引文件", @"init agents.md 初始化", @"doc.badge.plus", YES, YES),
            IMMakeSlashCommand(@"goal", @"持续目标", @"设定让 Codex 持续追踪推进的目标任务", @"goal 目标 巡航", @"target", YES, YES),
            IMMakeSlashCommand(@"side", @"侧边对话", @"开启不打断主线程的侧边快速问答窗口", @"side chat 侧边 副对话 旁路", @"sidebar.right", YES, YES),
            IMMakeSlashCommand(@"ide", @"IDE 上下文", @"开关自动附带 IDE 当前选中代码与打开文件", @"ide context vscode cursor 编辑器 选中", @"curlybraces", YES, YES),
            IMMakeSlashCommand(@"rename", @"重命名对话", @"修改当前对话标题", @"rename title 重命名 改名", @"pencil", YES, YES),
            IMMakeSlashCommand(@"pin", @"置顶对话", @"将当前对话固定在侧边栏顶部", @"pin star 置顶 收藏", @"pin", YES, YES),
            IMMakeSlashCommand(@"archive", @"归档对话", @"归档当前对话", @"archive 归档", @"archivebox", YES, YES),
            IMMakeSlashCommand(@"pet", @"桌面宠物", @"唤醒或收起 Codex 桌面宠物", @"pet 宠物", @"pawprint", YES, YES),
            IMMakeSlashCommand(@"usage", @"用量与账单", @"打开用量统计与账单设置", @"usage billing 用量 额度 账单", @"gauge.medium", YES, YES),
        ];
    } else if ([family isEqualToString:@"antigravity"]) {
        // Official Antigravity slash workflows & commands
        return @[
            IMMakeSlashCommand(@"plan", @"分步规划", @"先输出可审阅的分步实施计划再执行", @"plan 计划 规划 方案", @"list.bullet.clipboard", NO, NO),
            IMMakeSlashCommand(@"goal", @"目标巡航", @"长时深度执行复杂任务直至目标达成", @"goal 目标 巡航 挂机 长任务", @"target", NO, NO),
            IMMakeSlashCommand(@"compact", @"压缩上下文", @"总结并压缩当前对话上下文以释放窗口空间", @"compact 压缩 总结 上下文", @"arrow.down.right.and.arrow.up.left", YES, YES),
            IMMakeSlashCommand(@"browser", @"浏览器代理", @"启动内置浏览器访问网页、调试本地端口或自动化操作", @"browser web 浏览器 网页 自动化", @"safari", NO, NO),
            IMMakeSlashCommand(@"grill-me", @"方案拷问", @"通过结构化追问压测需求与架构假设，对齐关键决策", @"grill 拷问 追问 评审 决策", @"questionmark.bubble", NO, NO),
            IMMakeSlashCommand(@"boost", @"深度增强", @"多视角深度思考、策略拆解与严格验证", @"boost 深度 增强 思考 验证", @"bolt.shield", NO, NO),
            IMMakeSlashCommand(@"teamwork", @"多智能体协作", @"组建自主协作子代理团队并行推进大型任务", @"teamwork team 协作 团队 多代理", @"person.3", NO, NO),
            IMMakeSlashCommand(@"swarm", @"Swarm 蜂群", @"启动共享消息板的多 Worker 蜂群会话", @"swarm 蜂群 并发", @"point.3.connected.trianglepath.dotted", NO, NO),
            IMMakeSlashCommand(@"schedule", @"定时执行", @"设置周期性计划任务或一次性倒计时提醒", @"schedule cron timer 定时 计划", @"clock.arrow.circlepath", NO, NO),
            IMMakeSlashCommand(@"automation", @"后台自动化", @"交互式创建定时运行的后台自动化工作流", @"automation 自动化 后台 每天", @"gearshape.2", NO, NO),
            IMMakeSlashCommand(@"learn", @"沉淀记忆", @"将本次纠正或配置经验持久化为长期规则与技能", @"learn 记忆 学习 沉淀 规则", @"book.closed", NO, NO),
            IMMakeSlashCommand(@"plugin", @"插件管理", @"启用、禁用、安装或打包 Antigravity 插件", @"plugin 插件 市场 扩展", @"puzzlepiece.extension", NO, NO),
        ];
    } else if ([family isEqualToString:@"claude"]) {
        return @[
            IMMakeSlashCommand(@"compact", @"压缩上下文", @"压缩当前会话上下文", @"compact 压缩 上下文", @"arrow.down.right.and.arrow.up.left", YES, YES),
            IMMakeSlashCommand(@"clear", @"清空会话", @"清空当前对话历史重新开始", @"clear reset 清空 新建", @"trash", YES, YES),
            IMMakeSlashCommand(@"review", @"代码审查", @"审查当前变更或 PR", @"review 审查 代码", @"magnifyingglass", NO, NO),
            IMMakeSlashCommand(@"init", @"初始化 CLAUDE.md", @"分析仓库并生成 CLAUDE.md 指引文件", @"init claude.md 初始化", @"doc.badge.plus", YES, YES),
            IMMakeSlashCommand(@"model", @"切换模型", @"切换 Claude 模型", @"model 模型", @"cpu", YES, YES),
            IMMakeSlashCommand(@"mcp", @"MCP 状态", @"查看和管理 MCP 服务连接", @"mcp 工具 服务", @"server.rack", YES, YES),
            IMMakeSlashCommand(@"memory", @"编辑记忆", @"查看或编辑 CLAUDE.md 记忆文件", @"memory 记忆", @"memorychip", YES, YES),
            IMMakeSlashCommand(@"cost", @"用量统计", @"查看当前会话 Token 消耗与费用", @"cost usage 费用 用量", @"gauge.medium", YES, YES),
        ];
    }
    return @[];
}

NSArray<InputMirrorSkillItem *> *InputMirrorLoadSkillsForAppInWorkspace(NSString *bundleID,
                                                                         NSString *appName,
                                                                         NSString *workspaceRoot,
                                                                         NSString *homeDirOverride) {
    NSString *home = homeDirOverride.length ? homeDirOverride : NSHomeDirectory();
    NSString *family = IMSkillAppFamilyKey(bundleID, appName);
    NSMutableDictionary<NSString *, InputMirrorSkillItem *> *seen = [NSMutableDictionary dictionary];
    NSMutableArray<InputMirrorSkillItem *> *items = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;

    if ([family isEqualToString:@"codex"]) {
        if (workspaceRoot.length > 0) {
            IMScanSkillDirectory([workspaceRoot stringByAppendingPathComponent:@".agents/skills"], @"项目", @"$", 1, seen, items);
            IMScanSkillDirectory([workspaceRoot stringByAppendingPathComponent:@".codex/skills"], @"项目", @"$", 1, seen, items);
        }
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".agents/skills"], @"通用", @"$", 1, seen, items);
        NSString *codexSkills = [home stringByAppendingPathComponent:@".codex/skills"];
        IMScanSkillDirectory(codexSkills, @"Codex", @"$", 1, seen, items);
        NSString *codexPluginCache = [home stringByAppendingPathComponent:@".codex/plugins/cache"];
        for (NSString *mkt in [fm contentsOfDirectoryAtPath:codexPluginCache error:nil]) {
            if ([mkt hasPrefix:@"."]) continue;
            NSString *mktDir = [codexPluginCache stringByAppendingPathComponent:mkt];
            for (NSString *plug in [fm contentsOfDirectoryAtPath:mktDir error:nil]) {
                if ([plug hasPrefix:@"."]) continue;
                NSString *plugDir = [mktDir stringByAppendingPathComponent:plug];
                IMScanSkillDirectory([plugDir stringByAppendingPathComponent:@"skills"], @"插件", @"$", 1, seen, items);
                for (NSString *ver in [fm contentsOfDirectoryAtPath:plugDir error:nil]) {
                    if ([ver hasPrefix:@"."]) continue;
                    IMScanSkillDirectory([[plugDir stringByAppendingPathComponent:ver] stringByAppendingPathComponent:@"skills"], @"插件", @"$", 1, seen, items);
                }
            }
        }
        IMScanSkillDirectory([codexSkills stringByAppendingPathComponent:@".system"], @"系统", @"$", 0, seen, items);
    } else if ([family isEqualToString:@"antigravity"]) {
        if (workspaceRoot.length > 0) {
            IMScanSkillDirectoryEx([workspaceRoot stringByAppendingPathComponent:@".agent/workflows"], @"工作流", @"/", 1, YES, seen, items);
            IMScanSkillDirectoryEx([workspaceRoot stringByAppendingPathComponent:@".agents/workflows"], @"工作流", @"/", 1, YES, seen, items);
            IMScanSkillDirectory([workspaceRoot stringByAppendingPathComponent:@".agents/skills"], @"项目", @"/", 1, seen, items);
            IMScanSkillDirectory([workspaceRoot stringByAppendingPathComponent:@".agent/skills"], @"项目", @"/", 1, seen, items);
        }
        IMScanSkillDirectoryEx([home stringByAppendingPathComponent:@".gemini/antigravity/global_workflows"], @"工作流", @"/", 1, YES, seen, items);
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".gemini/config/skills"], @"自定义", @"/", 1, seen, items);
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".agents/skills"], @"通用", @"/", 1, seen, items);
        NSString *pluginsRoot = [home stringByAppendingPathComponent:@".gemini/config/plugins"];
        for (NSString *plugin in [fm contentsOfDirectoryAtPath:pluginsRoot error:nil]) {
            if ([plugin hasPrefix:@"."]) continue;
            NSString *pluginSkills = [[pluginsRoot stringByAppendingPathComponent:plugin] stringByAppendingPathComponent:@"skills"];
            IMScanSkillDirectory(pluginSkills, @"插件", @"/", 1, seen, items);
        }
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".gemini/antigravity/skills"], @"Antigravity", @"/", 1, seen, items);
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".gemini/antigravity/builtin/skills"], @"内置", @"/", 1, seen, items);
    } else if ([family isEqualToString:@"claude"]) {
        if (workspaceRoot.length > 0) {
            IMScanSkillDirectory([workspaceRoot stringByAppendingPathComponent:@".claude/commands"], @"项目命令", @"/", 1, seen, items);
            IMScanSkillDirectory([workspaceRoot stringByAppendingPathComponent:@".claude/skills"], @"项目", @"/", 1, seen, items);
        }
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".claude/skills"], @"Claude", @"/", 1, seen, items);
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".claude/commands"], @"命令", @"/", 1, seen, items);
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".agents/skills"], @"通用", @"/", 1, seen, items);
    } else if ([family isEqualToString:@"cursor"]) {
        if (workspaceRoot.length > 0) {
            IMScanSkillDirectory([workspaceRoot stringByAppendingPathComponent:@".cursor/commands"], @"项目", @"/", 1, seen, items);
            IMScanSkillDirectory([workspaceRoot stringByAppendingPathComponent:@".cursor/skills"], @"项目", @"/", 1, seen, items);
        }
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".cursor/commands"], @"Cursor", @"/", 1, seen, items);
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".cursor/skills"], @"Cursor", @"/", 1, seen, items);
    } else if ([family isEqualToString:@"codebuddy"]) {
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".codebuddy/skills"], @"CodeBuddy", @"/", 1, seen, items);
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".codebuddy/commands"], @"命令", @"/", 1, seen, items);
    } else if ([family isEqualToString:@"qoder"]) {
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".qoder/skills"], @"Qoder", @"/", 1, seen, items);
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".qoder-cn/skills"], @"Qoder", @"/", 1, seen, items);
    } else {
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".agents/skills"], @"通用", @"/", 1, seen, items);
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".codex/skills"], @"Codex", @"/", 1, seen, items);
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".claude/skills"], @"Claude", @"/", 1, seen, items);
        IMScanSkillDirectory([home stringByAppendingPathComponent:@".gemini/config/skills"], @"技能", @"/", 1, seen, items);
    }
    return items;
}

NSArray<InputMirrorSkillItem *> *InputMirrorLoadSkillsForApp(NSString *bundleID,
                                                             NSString *appName,
                                                             NSString *homeDirOverride) {
    return InputMirrorLoadSkillsForAppInWorkspace(bundleID, appName, nil, homeDirOverride);
}

static InputMirrorSkillItem *IMAddMentionItemEx(NSString *name,
                                                NSString *displayTitle,
                                                NSString *displayDetail,
                                                NSString *summary,
                                                NSString *sourceLabel,
                                                NSString *categoryKey,
                                                NSString *symbolName,
                                                InputMirrorItemKind kind,
                                                NSMutableDictionary<NSString *, InputMirrorSkillItem *> *seen,
                                                NSMutableArray<InputMirrorSkillItem *> *outItems) {
    if (!name.length) return nil;
    NSString *key = name.lowercaseString;
    if (seen[key]) return seen[key];
    InputMirrorSkillItem *item = [[InputMirrorSkillItem alloc] init];
    item.name = name;
    item.displayTitle = displayTitle.length ? displayTitle : [@"@" stringByAppendingString:name];
    item.displayDetail = displayDetail ?: @"";
    item.summary = summary ?: @"";
    item.insertPrefix = @"@";
    item.sourceLabel = sourceLabel ?: @"引用";
    item.categoryKey = categoryKey ?: @"context";
    item.symbolName = symbolName ?: @"at";
    item.itemKind = kind;
    seen[key] = item;
    [outItems addObject:item];
    return item;
}

static void IMAddMentionItem(NSString *name,
                             NSString *summary,
                             NSString *sourceLabel,
                             NSMutableDictionary<NSString *, InputMirrorSkillItem *> *seen,
                             NSMutableArray<InputMirrorSkillItem *> *outItems) {
    IMAddMentionItemEx(name, [@"@" stringByAppendingString:name], @"", summary, sourceLabel, @"context", @"sparkles.rectangle.stack", InputMirrorItemKindContext, seen, outItems);
}

static NSSet<NSString *> *IMIgnoredWorkspaceDirs(void) {
    static NSSet<NSString *> *ignored = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ignored = [NSSet setWithArray:@[
            @".git", @".hg", @".svn", @"node_modules", @"build", @"dist", @".build",
            @"deriveddata", @"__pycache__", @".venv", @"venv", @"target", @".next",
            @".nuxt", @"pods", @"backups", @"coverage", @".cache", @".turbo", @"vendor"
        ]];
    });
    return ignored;
}

static BOOL IMShouldIgnoreRelativeFile(NSString *relPath, NSSet<NSString *> *ignoredDirs) {
    if (!relPath.length) return YES;
    NSString *lower = relPath.lowercaseString;
    if ([lower hasSuffix:@".ds_store"] || [lower hasSuffix:@".dmg"] || [lower hasSuffix:@".zip"] ||
        [lower hasSuffix:@".o"] || [lower hasSuffix:@".pyc"] || [lower hasSuffix:@".icns"] ||
        [lower hasSuffix:@".asar"]) {
        return YES;
    }
    NSArray<NSString *> *parts = [relPath componentsSeparatedByString:@"/"];
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *comp = parts[i];
        if (!comp.length) continue;
        if ([comp hasPrefix:@"."] && ![comp isEqualToString:@".github"] && ![comp isEqualToString:@".gitignore"] && ![comp isEqualToString:@".env.example"]) {
            return YES;
        }
        if (i + 1 < parts.count && [ignoredDirs containsObject:comp.lowercaseString]) {
            return YES;
        }
    }
    return NO;
}

static NSString *IMFileSymbolForExtension(NSString *ext) {
    NSString *e = ext.lowercaseString ?: @"";
    if ([e isEqualToString:@"m"] || [e isEqualToString:@"mm"] || [e isEqualToString:@"h"] ||
        [e isEqualToString:@"c"] || [e isEqualToString:@"cpp"] || [e isEqualToString:@"swift"] ||
        [e isEqualToString:@"py"] || [e isEqualToString:@"js"] || [e isEqualToString:@"ts"] ||
        [e isEqualToString:@"tsx"] || [e isEqualToString:@"jsx"] || [e isEqualToString:@"go"] ||
        [e isEqualToString:@"rs"] || [e isEqualToString:@"java"] || [e isEqualToString:@"sh"]) {
        return @"chevron.left.forwardslash.chevron.right";
    }
    if ([e isEqualToString:@"md"] || [e isEqualToString:@"txt"] || [e isEqualToString:@"rst"]) {
        return @"doc.text";
    }
    if ([e isEqualToString:@"json"] || [e isEqualToString:@"yaml"] || [e isEqualToString:@"yml"] ||
        [e isEqualToString:@"toml"] || [e isEqualToString:@"plist"]) {
        return @"gearshape";
    }
    return @"doc";
}

static NSArray<NSString *> *IMGitListWorkspaceFiles(NSString *workspaceRoot) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:[workspaceRoot stringByAppendingPathComponent:@".git"]]) return nil;
    if (![fm isExecutableFileAtPath:@"/usr/bin/git"]) return nil;

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/git"];
    task.arguments = @[@"-C", workspaceRoot, @"ls-files", @"-co", @"--exclude-standard"];
    NSPipe *outPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) return nil;

    NSData *data = [outPipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0 || !data.length) return nil;

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text.length) return nil;
    return [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
}

static void IMScanWorkspaceMentions(NSString *workspaceRoot,
                                    NSMutableDictionary<NSString *, InputMirrorSkillItem *> *seen,
                                    NSMutableArray<InputMirrorSkillItem *> *outItems) {
    if (!workspaceRoot.length) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:workspaceRoot isDirectory:&isDir] || !isDir) return;

    NSSet<NSString *> *ignoredDirs = IMIgnoredWorkspaceDirs();
    const NSUInteger kMaxFiles = 2400;
    NSMutableArray<InputMirrorSkillItem *> *fileItems = [NSMutableArray array];
    NSMutableArray<InputMirrorSkillItem *> *folderItems = [NSMutableArray array];
    NSMutableSet<NSString *> *seenFolders = [NSMutableSet set];

    NSArray<NSString *> *gitFiles = IMGitListWorkspaceFiles(workspaceRoot);
    NSUInteger statBudget = 520;

    if (gitFiles.count > 0) {
        for (NSString *rawRel in gitFiles) {
            if (fileItems.count >= kMaxFiles) break;
            if (!rawRel.length || IMShouldIgnoreRelativeFile(rawRel, ignoredDirs)) continue;
            NSString *absPath = [workspaceRoot stringByAppendingPathComponent:rawRel];
            BOOL subDir = NO;
            if (![fm fileExistsAtPath:absPath isDirectory:&subDir] || subDir) continue;

            // Collect top 2 directory levels as mentionable folders (just like Codex & Antigravity)
            NSArray<NSString *> *comps = [rawRel componentsSeparatedByString:@"/"];
            if (comps.count >= 2) {
                NSString *d1 = [comps[0] stringByAppendingString:@"/"];
                if (![seenFolders containsObject:d1.lowercaseString]) {
                    [seenFolders addObject:d1.lowercaseString];
                    InputMirrorSkillItem *fItem = [[InputMirrorSkillItem alloc] init];
                    fItem.name = d1;
                    fItem.displayTitle = d1;
                    fItem.displayDetail = @"工作区目录";
                    fItem.summary = [NSString stringWithFormat:@"引用目录 · %@", d1];
                    fItem.insertPrefix = @"@";
                    fItem.sourceLabel = @"目录";
                    fItem.categoryKey = @"files";
                    fItem.symbolName = @"folder";
                    fItem.filePath = [workspaceRoot stringByAppendingPathComponent:comps[0]];
                    fItem.itemKind = InputMirrorItemKindFolder;
                    [folderItems addObject:fItem];
                }
                if (comps.count >= 3 && folderItems.count < 60) {
                    NSString *d2 = [NSString stringWithFormat:@"%@/%@/", comps[0], comps[1]];
                    if (![seenFolders containsObject:d2.lowercaseString]) {
                        [seenFolders addObject:d2.lowercaseString];
                        InputMirrorSkillItem *fItem2 = [[InputMirrorSkillItem alloc] init];
                        fItem2.name = d2;
                        fItem2.displayTitle = [comps[1] stringByAppendingString:@"/"];
                        fItem2.displayDetail = [comps[0] stringByAppendingString:@"/"];
                        fItem2.summary = [NSString stringWithFormat:@"引用子目录 · %@", d2];
                        fItem2.insertPrefix = @"@";
                        fItem2.sourceLabel = @"目录";
                        fItem2.categoryKey = @"files";
                        fItem2.symbolName = @"folder";
                        fItem2.filePath = [[workspaceRoot stringByAppendingPathComponent:comps[0]] stringByAppendingPathComponent:comps[1]];
                        fItem2.itemKind = InputMirrorItemKindFolder;
                        [folderItems addObject:fItem2];
                    }
                }
            }

            NSString *baseName = rawRel.lastPathComponent ?: rawRel;
            NSString *parentRel = [rawRel stringByDeletingLastPathComponent];
            InputMirrorSkillItem *item = [[InputMirrorSkillItem alloc] init];
            item.name = rawRel;
            item.displayTitle = baseName;
            item.displayDetail = parentRel.length ? [parentRel stringByAppendingString:@"/"] : @"根目录";
            item.summary = parentRel.length ? [NSString stringWithFormat:@"%@/", parentRel] : @"工作区根目录文件";
            item.insertPrefix = @"@";
            item.sourceLabel = @"文件";
            item.categoryKey = @"files";
            item.symbolName = IMFileSymbolForExtension(baseName.pathExtension);
            item.filePath = absPath;
            item.itemKind = InputMirrorItemKindFile;
            if (statBudget > 0) {
                statBudget--;
                struct stat st;
                if (stat(absPath.fileSystemRepresentation, &st) == 0) {
                    item.recencyScore = (double)st.st_mtimespec.tv_sec + (double)st.st_mtimespec.tv_nsec * 1e-9;
                }
            }
            [fileItems addObject:item];
        }
    } else {
        const NSUInteger kMaxDepth = 5;
        NSMutableArray<NSDictionary *> *queue = [NSMutableArray arrayWithObject:@{
            @"abs": workspaceRoot,
            @"rel": @"",
            @"depth": @(0)
        }];
        NSUInteger cursor = 0;
        while (cursor < queue.count && (fileItems.count + folderItems.count) < kMaxFiles) {
            NSDictionary *node = queue[cursor++];
            NSString *absDir = node[@"abs"];
            NSString *relDir = node[@"rel"];
            NSUInteger depth = [node[@"depth"] unsignedIntegerValue];

            NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:absDir error:nil];
            if (!entries.count) continue;
            entries = [entries sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

            for (NSString *entry in entries) {
                if ((fileItems.count + folderItems.count) >= kMaxFiles) break;
                if ([entry hasPrefix:@"."]) continue;
                NSString *lower = entry.lowercaseString;
                NSString *fullPath = [absDir stringByAppendingPathComponent:entry];
                BOOL entryIsDir = NO;
                if (![fm fileExistsAtPath:fullPath isDirectory:&entryIsDir]) continue;
                if (entryIsDir && [ignoredDirs containsObject:lower]) continue;
                if (!entryIsDir && ([lower isEqualToString:@".ds_store"] || [lower hasSuffix:@".dmg"] || [lower hasSuffix:@".zip"])) continue;

                NSString *relPath = relDir.length ? [relDir stringByAppendingPathComponent:entry] : entry;
                if (entryIsDir) {
                    if (depth <= 1) {
                        NSString *dirName = [relPath stringByAppendingString:@"/"];
                        InputMirrorSkillItem *fItem = [[InputMirrorSkillItem alloc] init];
                        fItem.name = dirName;
                        fItem.displayTitle = [entry stringByAppendingString:@"/"];
                        fItem.displayDetail = relDir.length ? [relDir stringByAppendingString:@"/"] : @"工作区目录";
                        fItem.summary = [NSString stringWithFormat:@"引用目录 · %@", dirName];
                        fItem.insertPrefix = @"@";
                        fItem.sourceLabel = @"目录";
                        fItem.categoryKey = @"files";
                        fItem.symbolName = @"folder";
                        fItem.filePath = fullPath;
                        fItem.itemKind = InputMirrorItemKindFolder;
                        [folderItems addObject:fItem];
                    }
                    if (depth < kMaxDepth) {
                        [queue addObject:@{ @"abs": fullPath, @"rel": relPath, @"depth": @(depth + 1) }];
                    }
                } else {
                    InputMirrorSkillItem *item = [[InputMirrorSkillItem alloc] init];
                    item.name = relPath;
                    item.displayTitle = entry;
                    item.displayDetail = relDir.length ? [relDir stringByAppendingString:@"/"] : @"根目录";
                    item.summary = relDir.length ? [NSString stringWithFormat:@"%@/", relDir] : @"工作区根目录文件";
                    item.insertPrefix = @"@";
                    item.sourceLabel = @"文件";
                    item.categoryKey = @"files";
                    item.symbolName = IMFileSymbolForExtension(entry.pathExtension);
                    item.filePath = fullPath;
                    item.itemKind = InputMirrorItemKindFile;
                    if (statBudget > 0) {
                        statBudget--;
                        struct stat st;
                        if (stat(fullPath.fileSystemRepresentation, &st) == 0) {
                            item.recencyScore = (double)st.st_mtimespec.tv_sec + (double)st.st_mtimespec.tv_nsec * 1e-9;
                        }
                    }
                    [fileItems addObject:item];
                }
            }
        }
    }

    // Sort files by recent modification time descending so empty '@' immediately surfaces active files (just like Codex & Antigravity)
    [fileItems sortUsingComparator:^NSComparisonResult(InputMirrorSkillItem *a, InputMirrorSkillItem *b) {
        if (a.recencyScore > b.recencyScore) return NSOrderedAscending;
        if (a.recencyScore < b.recencyScore) return NSOrderedDescending;
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];

    for (InputMirrorSkillItem *fi in fileItems) {
        NSString *k = fi.name.lowercaseString;
        if (k.length && !seen[k]) {
            seen[k] = fi;
            [outItems addObject:fi];
        }
    }
    for (InputMirrorSkillItem *di in folderItems) {
        NSString *k = di.name.lowercaseString;
        if (k.length && !seen[k]) {
            seen[k] = di;
            [outItems addObject:di];
        }
    }
}

static NSString *IMExistingDirectoryPathFromURIOrPath(NSString *raw) {
    if (!raw.length) return nil;
    NSString *candidate = raw;
    if ([raw hasPrefix:@"file://"]) {
        NSURL *url = [NSURL URLWithString:raw];
        if (url && url.isFileURL && url.path.length) {
            candidate = url.path;
        }
    }
    candidate = [candidate stringByExpandingTildeInPath];
    BOOL isDir = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:candidate isDirectory:&isDir] && isDir) {
        return candidate;
    }
    return nil;
}

static NSString *IMQuerySingleSQLiteText(NSString *dbPath, const char *sql) {
    if (!dbPath.length || ![NSFileManager.defaultManager fileExistsAtPath:dbPath]) return nil;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK || !db) {
        if (db) sqlite3_close(db);
        return nil;
    }
    sqlite3_busy_timeout(db, 80);
    sqlite3_stmt *stmt = NULL;
    NSString *result = nil;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK && stmt) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *txt = sqlite3_column_text(stmt, 0);
            if (txt) result = [NSString stringWithUTF8String:(const char *)txt];
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
    return result;
}

static NSString *IMResolveVSCodeStorageWorkspace(NSString *home, NSArray<NSString *> *appSupportNames) {
    NSString *appSupport = [home stringByAppendingPathComponent:@"Library/Application Support"];
    for (NSString *appDir in appSupportNames) {
        NSString *storagePath = [[appSupport stringByAppendingPathComponent:appDir]
                                 stringByAppendingPathComponent:@"User/globalStorage/storage.json"];
        NSData *data = [NSData dataWithContentsOfFile:storagePath];
        if (!data.length) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *winState = [obj[@"windowsState"] isKindOfClass:NSDictionary.class] ? obj[@"windowsState"] : nil;
        if (!winState) continue;

        NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
        if ([winState[@"lastActiveWindow"] isKindOfClass:NSDictionary.class]) {
            [candidates addObject:winState[@"lastActiveWindow"]];
        }
        if ([winState[@"openedWindows"] isKindOfClass:NSArray.class]) {
            for (id w in (NSArray *)winState[@"openedWindows"]) {
                if ([w isKindOfClass:NSDictionary.class]) [candidates addObject:w];
            }
        }
        for (NSDictionary *win in candidates) {
            id folder = win[@"folder"];
            if ([folder isKindOfClass:NSString.class]) {
                NSString *dir = IMExistingDirectoryPathFromURIOrPath((NSString *)folder);
                if (dir.length) return dir;
            }
            id wsIdent = win[@"workspaceIdentifier"];
            if ([wsIdent isKindOfClass:NSDictionary.class]) {
                id configURI = ((NSDictionary *)wsIdent)[@"configURIPath"];
                if ([configURI isKindOfClass:NSString.class]) {
                    NSString *uriPath = IMExistingDirectoryPathFromURIOrPath([(NSString *)configURI stringByDeletingLastPathComponent]);
                    if (uriPath.length) return uriPath;
                }
            }
        }
    }
    return nil;
}

static NSString *IMQueryBoundSQLiteText(NSString *dbPath, const char *sql, NSString *param1) {
    if (!dbPath.length || !param1.length || ![NSFileManager.defaultManager fileExistsAtPath:dbPath]) return nil;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK || !db) {
        if (db) sqlite3_close(db);
        return nil;
    }
    sqlite3_busy_timeout(db, 80);
    sqlite3_stmt *stmt = NULL;
    NSString *result = nil;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK && stmt) {
        sqlite3_bind_text(stmt, 1, param1.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *txt = sqlite3_column_text(stmt, 0);
            if (txt) result = [NSString stringWithUTF8String:(const char *)txt];
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
    return result;
}

NSString *InputMirrorResolveWorkspaceRootForApp(NSString *bundleID,
                                                NSString *appName,
                                                NSString *homeDirOverride) {
    NSString *home = homeDirOverride.length ? homeDirOverride : NSHomeDirectory();
    NSString *family = IMSkillAppFamilyKey(bundleID, appName);

    if ([family isEqualToString:@"codex"]) {
        NSString *codexStateDB = [home stringByAppendingPathComponent:@".codex/.codex-global-state.sqlite"];
        NSString *codexDB = [home stringByAppendingPathComponent:@".codex/state_5.sqlite"];

        // 1. Live Codex SQLite global state (.codex-global-state.sqlite -> selected-project -> local-projects or state_5.project_roots)
        NSString *selJson = IMQuerySingleSQLiteText(codexStateDB, "SELECT value FROM settings WHERE scope = 'global' AND key LIKE 'electron-owner-value:selected-project:%' LIMIT 1;");
        if (selJson.length) {
            id selObj = [NSJSONSerialization JSONObjectWithData:[selJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([selObj isKindOfClass:NSDictionary.class]) {
                NSString *projId = [((NSDictionary *)selObj)[@"projectId"] isKindOfClass:NSString.class] ? ((NSDictionary *)selObj)[@"projectId"] : nil;
                if (projId.length) {
                    NSString *lpJson = IMQuerySingleSQLiteText(codexStateDB, "SELECT value FROM settings WHERE scope = 'global' AND key = 'local-projects' LIMIT 1;");
                    if (lpJson.length) {
                        id lpObj = [NSJSONSerialization JSONObjectWithData:[lpJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                        NSDictionary *proj = ([lpObj isKindOfClass:NSDictionary.class] && [((NSDictionary *)lpObj)[projId] isKindOfClass:NSDictionary.class]) ? ((NSDictionary *)lpObj)[projId] : nil;
                        NSArray *roots = [proj[@"rootPaths"] isKindOfClass:NSArray.class] ? proj[@"rootPaths"] : nil;
                        for (id r in roots) {
                            if ([r isKindOfClass:NSString.class]) {
                                NSString *dir = IMExistingDirectoryPathFromURIOrPath((NSString *)r);
                                if (dir.length) return dir;
                            }
                        }
                    }
                    NSString *projRoot = IMQueryBoundSQLiteText(codexDB, "SELECT path FROM project_roots WHERE project_id = ? ORDER BY position ASC LIMIT 1;", projId);
                    NSString *resolvedRoot = IMExistingDirectoryPathFromURIOrPath(projRoot);
                    if (resolvedRoot.length) return resolvedRoot;
                }
            }
        }
        NSString *activeRootsJson = IMQuerySingleSQLiteText(codexStateDB, "SELECT value FROM settings WHERE scope = 'global' AND key LIKE 'electron-owner-value:active-workspace-roots:%' LIMIT 1;");
        if (activeRootsJson.length) {
            id rootsObj = [NSJSONSerialization JSONObjectWithData:[activeRootsJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([rootsObj isKindOfClass:NSArray.class]) {
                for (id r in (NSArray *)rootsObj) {
                    if ([r isKindOfClass:NSString.class]) {
                        NSString *dir = IMExistingDirectoryPathFromURIOrPath((NSString *)r);
                        if (dir.length) return dir;
                    }
                }
            }
        }

        // 2. Legacy JSON state (.codex-global-state.json)
        NSString *statePath = [home stringByAppendingPathComponent:@".codex/.codex-global-state.json"];
        NSData *data = [NSData dataWithContentsOfFile:statePath];
        if (data.length) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:NSDictionary.class]) {
                NSDictionary *dict = (NSDictionary *)obj;
                NSDictionary *localProjects = [dict[@"local-projects"] isKindOfClass:NSDictionary.class] ? dict[@"local-projects"] : nil;
                for (NSString *k in dict) {
                    if ([k hasPrefix:@"electron-owner-value:selected-project:"]) {
                        id sel = dict[k];
                        if ([sel isKindOfClass:NSDictionary.class]) {
                            NSString *projId = [sel[@"projectId"] isKindOfClass:NSString.class] ? sel[@"projectId"] : nil;
                            NSDictionary *proj = (projId.length && [localProjects[projId] isKindOfClass:NSDictionary.class]) ? localProjects[projId] : nil;
                            NSArray *roots = [proj[@"rootPaths"] isKindOfClass:NSArray.class] ? proj[@"rootPaths"] : nil;
                            for (id r in roots) {
                                if ([r isKindOfClass:NSString.class]) {
                                    NSString *dir = IMExistingDirectoryPathFromURIOrPath((NSString *)r);
                                    if (dir.length) return dir;
                                }
                            }
                        }
                    }
                }
                for (NSString *k in dict) {
                    if ([k hasPrefix:@"electron-owner-value:active-workspace-roots:"]) {
                        id roots = dict[k];
                        if ([roots isKindOfClass:NSArray.class]) {
                            for (id r in (NSArray *)roots) {
                                if ([r isKindOfClass:NSString.class]) {
                                    NSString *dir = IMExistingDirectoryPathFromURIOrPath((NSString *)r);
                                    if (dir.length) return dir;
                                }
                            }
                        }
                    }
                }
            }
        }
        // 3. Fallback: most recently updated thread cwd in ~/.codex/state_5.sqlite
        NSString *cwd = IMQuerySingleSQLiteText(codexDB, "SELECT cwd FROM threads WHERE cwd IS NOT NULL AND cwd != '' ORDER BY updated_at DESC LIMIT 1;");
        NSString *dir = IMExistingDirectoryPathFromURIOrPath(cwd);
        if (dir.length) return dir;
    } else if ([family isEqualToString:@"antigravity"]) {
        NSString *agDB = [home stringByAppendingPathComponent:@".gemini/antigravity/conversation_summaries.db"];
        NSString *urisJson = IMQuerySingleSQLiteText(agDB, "SELECT workspace_uris FROM conversation_summaries WHERE workspace_uris IS NOT NULL AND workspace_uris != '' AND workspace_uris != '[]' ORDER BY last_modified_time DESC LIMIT 1;");
        if (urisJson.length) {
            id arr = [NSJSONSerialization JSONObjectWithData:[urisJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([arr isKindOfClass:NSArray.class]) {
                for (id uri in (NSArray *)arr) {
                    if ([uri isKindOfClass:NSString.class]) {
                        NSString *dir = IMExistingDirectoryPathFromURIOrPath((NSString *)uri);
                        if (dir.length) return dir;
                    }
                }
            }
        }
    } else if ([family isEqualToString:@"cursor"]) {
        return IMResolveVSCodeStorageWorkspace(home, @[@"Cursor"]);
    } else if ([family isEqualToString:@"vscode"]) {
        return IMResolveVSCodeStorageWorkspace(home, @[@"Code", @"Code - Insiders"]);
    } else if ([family isEqualToString:@"windsurf"]) {
        return IMResolveVSCodeStorageWorkspace(home, @[@"Windsurf"]);
    } else if ([family isEqualToString:@"trae"]) {
        return IMResolveVSCodeStorageWorkspace(home, @[@"Trae CN", @"Trae"]);
    } else if ([family isEqualToString:@"codebuddy"]) {
        return IMResolveVSCodeStorageWorkspace(home, @[@"CodeBuddy CN", @"CodeBuddy"]);
    } else if ([family isEqualToString:@"qoder"]) {
        return IMResolveVSCodeStorageWorkspace(home, @[@"Qoder CN", @"Qoder"]);
    }
    return nil;
}

static NSString *IMSnapshotProviderForFamily(NSString *family) {
    if ([family isEqualToString:@"vscode"]) return @"copilot";
    if ([family isEqualToString:@"chatgpt"] || [family isEqualToString:@"generic"]) return nil;
    return family;
}

static NSString *IMCleanConversationTitle(NSString *raw) {
    if (!raw.length) return @"";
    NSArray<NSString *> *parts = [raw componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *nonEmpty = [NSMutableArray array];
    for (NSString *p in parts) {
        if (p.length) [nonEmpty addObject:p];
    }
    NSString *joined = [nonEmpty componentsJoinedByString:@" "];
    if (joined.length > 48) {
        joined = [joined substringToIndex:48];
    }
    return joined;
}

static NSString *IMNativeMentionQueryToken(NSString *rawTitle) {
    NSString *clean = IMCleanConversationTitle(rawTitle);
    if (!clean.length) return @"";
    if (![clean containsString:@" "]) {
        return (clean.length > 24) ? [clean substringToIndex:24] : clean;
    }
    NSArray<NSString *> *parts = [clean componentsSeparatedByString:@" "];
    NSString *best = @"";
    for (NSString *part in parts) {
        if (part.length > best.length) best = part;
    }
    if (!best.length) best = clean;
    return (best.length > 24) ? [best substringToIndex:24] : best;
}

static void IMLoadAntigravityDBConversations(NSString *home,
                                             NSUInteger maxCount,
                                             NSMutableDictionary<NSString *, InputMirrorSkillItem *> *seen,
                                             NSMutableArray<InputMirrorSkillItem *> *items) {
    NSString *dbPath = [home stringByAppendingPathComponent:@".gemini/antigravity/conversation_summaries.db"];
    const char *sql = "SELECT title, workspace_uris FROM conversation_summaries WHERE title IS NOT NULL AND title != '' AND (parent_conversation_id IS NULL OR parent_conversation_id = '') ORDER BY last_modified_time DESC LIMIT 35;";
    sqlite3 *db = NULL;
    if (![NSFileManager.defaultManager fileExistsAtPath:dbPath] ||
        sqlite3_open_v2(dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK || !db) {
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_busy_timeout(db, 80);
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK && stmt) {
        while (sqlite3_step(stmt) == SQLITE_ROW && items.count < maxCount) {
            const unsigned char *txt = sqlite3_column_text(stmt, 0);
            if (!txt) continue;
            NSString *title = IMCleanConversationTitle([NSString stringWithUTF8String:(const char *)txt]);
            if (title.length < 2) continue;
            NSString *dedupKey = title.lowercaseString;
            if (seen[dedupKey]) continue;

            NSString *project = @"";
            const unsigned char *uriTxt = sqlite3_column_text(stmt, 1);
            if (uriTxt) {
                NSString *uriJson = [NSString stringWithUTF8String:(const char *)uriTxt];
                if (uriJson.length > 2) {
                    id arr = [NSJSONSerialization JSONObjectWithData:[uriJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                    if ([arr isKindOfClass:NSArray.class] && [(NSArray *)arr count] > 0) {
                        id first = [(NSArray *)arr firstObject];
                        if ([first isKindOfClass:NSString.class]) {
                            NSURL *u = [NSURL URLWithString:(NSString *)first];
                            NSString *p = (u && u.isFileURL) ? u.path : (NSString *)first;
                            if (p.length) project = p.lastPathComponent ?: @"";
                        }
                    }
                }
            }
            InputMirrorSkillItem *item = [[InputMirrorSkillItem alloc] init];
            item.name = title;
            item.displayTitle = title;
            item.displayDetail = project ?: @"";
            item.summary = project.length
                ? [NSString stringWithFormat:@"历史对话 · %@ · 回车在原应用绑定", project]
                : @"历史对话 · 回车在原应用绑定";
            item.insertPrefix = @"@";
            item.sourceLabel = @"对话";
            item.categoryKey = @"chats";
            item.symbolName = @"bubble.left.and.bubble.right";
            item.itemKind = InputMirrorItemKindConversation;
            item.requiresNativeHandoff = YES;
            seen[dedupKey] = item;
            [items addObject:item];
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
}

static void IMLoadCodexDBConversations(NSString *home,
                                       NSUInteger maxCount,
                                       NSMutableDictionary<NSString *, InputMirrorSkillItem *> *seen,
                                       NSMutableArray<InputMirrorSkillItem *> *items) {
    NSString *dbPath = [home stringByAppendingPathComponent:@".codex/state_5.sqlite"];
    const char *sql = "SELECT COALESCE(NULLIF(name,''), title), cwd FROM threads WHERE archived = 0 AND COALESCE(NULLIF(name,''), title) != '' ORDER BY updated_at DESC LIMIT 35;";
    sqlite3 *db = NULL;
    if (![NSFileManager.defaultManager fileExistsAtPath:dbPath] ||
        sqlite3_open_v2(dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK || !db) {
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_busy_timeout(db, 80);
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK && stmt) {
        while (sqlite3_step(stmt) == SQLITE_ROW && items.count < maxCount) {
            const unsigned char *txt = sqlite3_column_text(stmt, 0);
            if (!txt) continue;
            NSString *title = IMCleanConversationTitle([NSString stringWithUTF8String:(const char *)txt]);
            if (title.length < 2) continue;
            NSString *dedupKey = title.lowercaseString;
            if (seen[dedupKey]) continue;

            NSString *project = @"";
            const unsigned char *cwdTxt = sqlite3_column_text(stmt, 1);
            if (cwdTxt) {
                NSString *cwd = [NSString stringWithUTF8String:(const char *)cwdTxt];
                if (cwd.length) project = cwd.lastPathComponent ?: @"";
            }
            InputMirrorSkillItem *item = [[InputMirrorSkillItem alloc] init];
            item.name = title;
            item.displayTitle = title;
            item.displayDetail = project ?: @"";
            item.summary = project.length
                ? [NSString stringWithFormat:@"Codex 对话 · %@ · 回车在原应用绑定", project]
                : @"Codex 历史对话 · 回车在原应用绑定";
            item.insertPrefix = @"@";
            item.sourceLabel = @"对话";
            item.categoryKey = @"chats";
            item.symbolName = @"bubble.left.and.bubble.right";
            item.itemKind = InputMirrorItemKindConversation;
            item.requiresNativeHandoff = YES;
            seen[dedupKey] = item;
            [items addObject:item];
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
}

NSArray<InputMirrorSkillItem *> *InputMirrorLoadConversationMentionsForApp(NSString *bundleID,
                                                                           NSString *appName,
                                                                           NSString *homeDirOverride) {
    NSString *home = homeDirOverride.length ? homeDirOverride : NSHomeDirectory();
    NSString *family = IMSkillAppFamilyKey(bundleID, appName);
    NSString *targetProvider = IMSnapshotProviderForFamily(family);
    NSMutableDictionary<NSString *, InputMirrorSkillItem *> *seen = [NSMutableDictionary dictionary];
    NSMutableArray<InputMirrorSkillItem *> *items = [NSMutableArray array];
    const NSUInteger kMaxConversations = 25;

    // Prefer native conversation/thread databases FIRST for Antigravity & Codex
    // (snapshot.json stores raw first-turn prompts which do not match native @ chat search titles).
    if ([family isEqualToString:@"antigravity"]) {
        IMLoadAntigravityDBConversations(home, kMaxConversations, seen, items);
        if (items.count > 0) return items;
    } else if ([family isEqualToString:@"codex"]) {
        IMLoadCodexDBConversations(home, kMaxConversations, seen, items);
        if (items.count > 0) return items;
    }

    NSString *snapPath = [home stringByAppendingPathComponent:@".codex/task-manager/snapshot.json"];
    NSData *data = [NSData dataWithContentsOfFile:snapPath];
    if (data.length) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:NSDictionary.class]) {
            NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
            for (NSString *key in @[@"tasks", @"history"]) {
                id arr = ((NSDictionary *)obj)[key];
                if (![arr isKindOfClass:NSArray.class]) continue;
                for (id entry in (NSArray *)arr) {
                    if (![entry isKindOfClass:NSDictionary.class]) continue;
                    NSDictionary *rec = (NSDictionary *)entry;
                    if (targetProvider.length) {
                        NSString *prov = [rec[@"provider"] isKindOfClass:NSString.class] ? [rec[@"provider"] lowercaseString] : @"";
                        if (![prov isEqualToString:targetProvider]) continue;
                    }
                    [records addObject:rec];
                }
            }
            [records sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                double ta = [a[@"updated"] isKindOfClass:NSNumber.class] ? [a[@"updated"] doubleValue] : 0.0;
                double tb = [b[@"updated"] isKindOfClass:NSNumber.class] ? [b[@"updated"] doubleValue] : 0.0;
                if (ta > tb) return NSOrderedAscending;
                if (ta < tb) return NSOrderedDescending;
                return NSOrderedSame;
            }];
            for (NSDictionary *rec in records) {
                if (items.count >= kMaxConversations) break;
                NSString *rawTitle = [rec[@"title"] isKindOfClass:NSString.class] ? rec[@"title"] : @"";
                NSString *title = IMCleanConversationTitle(rawTitle);
                if (title.length < 2) continue;
                NSString *dedupKey = title.lowercaseString;
                if (seen[dedupKey]) continue;
                NSString *project = [rec[@"project"] isKindOfClass:NSString.class] ? rec[@"project"] : @"";
                InputMirrorSkillItem *item = [[InputMirrorSkillItem alloc] init];
                item.name = title;
                item.displayTitle = title;
                item.displayDetail = project ?: @"";
                item.summary = project.length
                    ? [NSString stringWithFormat:@"对话 · %@ · 回车在原应用绑定", project]
                    : @"历史对话 · 回车在原应用绑定";
                item.insertPrefix = @"@";
                item.sourceLabel = @"对话";
                item.categoryKey = @"chats";
                item.symbolName = @"bubble.left.and.bubble.right";
                item.itemKind = InputMirrorItemKindConversation;
                item.requiresNativeHandoff = YES;
                seen[dedupKey] = item;
                [items addObject:item];
            }
        }
    }
    return items;
}

NSArray<InputMirrorSkillItem *> *InputMirrorLoadExtraMentionsForApp(NSString *bundleID,
                                                                    NSString *appName,
                                                                    NSString *workspaceRoot,
                                                                    NSString *homeDirOverride) {
    NSString *home = homeDirOverride.length ? homeDirOverride : NSHomeDirectory();
    NSString *family = IMSkillAppFamilyKey(bundleID, appName);
    NSMutableDictionary<NSString *, InputMirrorSkillItem *> *seen = [NSMutableDictionary dictionary];
    NSMutableArray<InputMirrorSkillItem *> *items = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;

    if ([family isEqualToString:@"codex"]) {
        // 1. Parse MCP servers & enabled plugins from ~/.codex/config.toml
        NSString *tomlPath = [home stringByAppendingPathComponent:@".codex/config.toml"];
        NSString *toml = [NSString stringWithContentsOfFile:tomlPath encoding:NSUTF8StringEncoding error:nil];
        if (toml.length > 0) {
            NSRegularExpression *mcpRe = IMRegex(@"^\\[mcp_servers\\.\"?([A-Za-z0-9_.-]+)\"?\\]$");
            NSRegularExpression *plugRe = IMRegex(@"^\\[plugins\\.\"([A-Za-z0-9_.-]+)@([^\"]+)\"\\]$");
            for (NSString *rawLine in [toml componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (!line.length || [line characterAtIndex:0] != '[') continue;
                NSTextCheckingResult *mm = [mcpRe firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
                if (mm) {
                    NSString *srv = [line substringWithRange:[mm rangeAtIndex:1]];
                    InputMirrorSkillItem *it = IMAddMentionItemEx(srv, [@"@" stringByAppendingString:srv], @"MCP 服务", [NSString stringWithFormat:@"引用 MCP 服务 · %@（回车打开原生资源选择）", srv], @"MCP", @"mcp", @"server.rack", InputMirrorItemKindMCP, seen, items);
                    it.requiresNativeHandoff = YES;
                    continue;
                }
                NSTextCheckingResult *pm = [plugRe firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
                if (pm) {
                    NSString *plugName = [line substringWithRange:[pm rangeAtIndex:1]];
                    NSString *mkt = [line substringWithRange:[pm rangeAtIndex:2]];
                    if ([plugName isEqualToString:@"codex-app-tools"] || [plugName isEqualToString:@"unified-computer-use"]) continue;
                    InputMirrorSkillItem *it = IMAddMentionItemEx(plugName, [@"@" stringByAppendingString:plugName], mkt, [NSString stringWithFormat:@"Codex 插件能力 · %@", plugName], @"插件", @"mcp", @"puzzlepiece.extension", InputMirrorItemKindMCP, seen, items);
                    it.requiresNativeHandoff = YES;
                }
            }
        }
        // 2. Recent named subagents from state_5.sqlite
        NSString *dbPath = [home stringByAppendingPathComponent:@".codex/state_5.sqlite"];
        sqlite3 *db = NULL;
        if ([fm fileExistsAtPath:dbPath] && sqlite3_open_v2(dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK && db) {
            sqlite3_busy_timeout(db, 60);
            sqlite3_stmt *stmt = NULL;
            const char *sql = "SELECT DISTINCT agent_nickname, COALESCE(agent_role, '') FROM threads WHERE agent_nickname IS NOT NULL AND agent_nickname != '' ORDER BY updated_at DESC LIMIT 10;";
            if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK && stmt) {
                while (sqlite3_step(stmt) == SQLITE_ROW) {
                    const unsigned char *nickTxt = sqlite3_column_text(stmt, 0);
                    if (!nickTxt) continue;
                    NSString *nick = [NSString stringWithUTF8String:(const char *)nickTxt];
                    const unsigned char *roleTxt = sqlite3_column_text(stmt, 1);
                    NSString *role = roleTxt ? [NSString stringWithUTF8String:(const char *)roleTxt] : @"";
                    InputMirrorSkillItem *it = IMAddMentionItemEx(nick, [@"@" stringByAppendingString:nick], role, role.length ? [NSString stringWithFormat:@"子代理 · %@", role] : @"Codex 子代理", @"智能体", @"mcp", @"cpu", InputMirrorItemKindAgent, seen, items);
                    it.requiresNativeHandoff = YES;
                }
                sqlite3_finalize(stmt);
            }
            sqlite3_close(db);
        }
    } else if ([family isEqualToString:@"antigravity"]) {
        // 1. MCP Servers from ~/.gemini/config/mcp_config.json
        NSString *mcpPath = [home stringByAppendingPathComponent:@".gemini/config/mcp_config.json"];
        NSData *mcpData = [NSData dataWithContentsOfFile:mcpPath];
        if (mcpData.length > 0) {
            id obj = [NSJSONSerialization JSONObjectWithData:mcpData options:0 error:nil];
            if ([obj isKindOfClass:NSDictionary.class]) {
                NSDictionary *servers = [((NSDictionary *)obj)[@"mcpServers"] isKindOfClass:NSDictionary.class] ? ((NSDictionary *)obj)[@"mcpServers"] : nil;
                for (NSString *srv in [servers.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
                    InputMirrorSkillItem *it = IMAddMentionItemEx(srv, [@"@" stringByAppendingString:srv], @"MCP 服务", [NSString stringWithFormat:@"引用 MCP 服务工具与上下文 · %@", srv], @"MCP", @"mcp", @"server.rack", InputMirrorItemKindMCP, seen, items);
                    it.requiresNativeHandoff = YES;
                }
            }
        }
        // 2. Rules (Workspace & Global GEMINI.md / .agents/rules)
        if (workspaceRoot.length > 0) {
            for (NSString *ruleRel in @[@"GEMINI.md", @"AGENTS.md", @".cursorrules"]) {
                NSString *absRule = [workspaceRoot stringByAppendingPathComponent:ruleRel];
                if ([fm fileExistsAtPath:absRule]) {
                    IMAddMentionItemEx(ruleRel, ruleRel, @"项目规则", [NSString stringWithFormat:@"引用项目规则文件 · %@", ruleRel], @"规则", @"mcp", @"doc.badge.gearshape", InputMirrorItemKindRule, seen, items);
                }
            }
            for (NSString *rulesSub in @[@".agents/rules", @".agent/rules"]) {
                NSString *rDir = [workspaceRoot stringByAppendingPathComponent:rulesSub];
                for (NSString *entry in [fm contentsOfDirectoryAtPath:rDir error:nil]) {
                    if ([entry hasPrefix:@"."]) continue;
                    NSString *rel = [rulesSub stringByAppendingPathComponent:entry];
                    IMAddMentionItemEx(rel, entry, rulesSub, @"项目自定义规则", @"规则", @"mcp", @"doc.badge.gearshape", InputMirrorItemKindRule, seen, items);
                }
            }
        }
        if ([fm fileExistsAtPath:[home stringByAppendingPathComponent:@".gemini/GEMINI.md"]]) {
            InputMirrorSkillItem *gRule = IMAddMentionItemEx(@"GEMINI.md", @"GEMINI.md", @"全局规则", @"全局 Antigravity 规则 · ~/.gemini/GEMINI.md", @"规则", @"mcp", @"doc.badge.gearshape", InputMirrorItemKindRule, seen, items);
            gRule.requiresNativeHandoff = YES;
        }
        // 3. Terminal context handoff
        InputMirrorSkillItem *termItem = IMAddMentionItemEx(@"terminal", @"@terminal", @"终端会话", @"在 Antigravity 原生 @ 菜单中选择活跃终端会话上下文", @"终端", @"mcp", @"terminal", InputMirrorItemKindContext, seen, items);
        termItem.searchKeywords = @"terminal shell 终端 命令行";
        termItem.requiresNativeHandoff = YES;
    }
    return items;
}

NSArray<InputMirrorSkillItem *> *InputMirrorLoadMentionsForApp(NSString *bundleID,
                                                               NSString *appName,
                                                               NSString *workspaceRoot) {
    NSString *family = IMSkillAppFamilyKey(bundleID, appName);
    NSMutableDictionary<NSString *, InputMirrorSkillItem *> *seen = [NSMutableDictionary dictionary];
    NSMutableArray<InputMirrorSkillItem *> *items = [NSMutableArray array];

    if ([family isEqualToString:@"cursor"]) {
        IMAddMentionItem(@"Files", @"引用工作区文件", @"上下文", seen, items);
        IMAddMentionItem(@"Folders", @"引用目录结构与内容", @"上下文", seen, items);
        IMAddMentionItem(@"Code", @"引用函数、类或代码符号", @"上下文", seen, items);
        IMAddMentionItem(@"Codebase", @"检索整个代码库上下文", @"上下文", seen, items);
        IMAddMentionItem(@"Docs", @"引用已索引文档", @"上下文", seen, items);
        IMAddMentionItem(@"Git", @"引用 Git 提交与变更差异", @"上下文", seen, items);
        IMAddMentionItem(@"Web", @"联网搜索最新资料", @"上下文", seen, items);
        IMAddMentionItem(@"Rules", @"引用项目或全局规则", @"上下文", seen, items);
        IMAddMentionItem(@"Past Chats", @"引用历史对话上下文", @"上下文", seen, items);
    } else if ([family isEqualToString:@"vscode"]) {
        IMAddMentionItem(@"workspace", @"查询当前工作区代码与结构", @"参与者", seen, items);
        IMAddMentionItem(@"vscode", @"查询 VS Code 设置与命令", @"参与者", seen, items);
        IMAddMentionItem(@"terminal", @"引用终端命令与输出", @"参与者", seen, items);
        IMAddMentionItem(@"github", @"查询 GitHub 仓库、Issue 与 PR", @"参与者", seen, items);
    } else if ([family isEqualToString:@"windsurf"]) {
        IMAddMentionItem(@"codebase", @"检索整个代码库上下文", @"上下文", seen, items);
        IMAddMentionItem(@"web", @"联网搜索网页资料", @"上下文", seen, items);
        IMAddMentionItem(@"docs", @"引用技术文档", @"上下文", seen, items);
        IMAddMentionItem(@"diff", @"引用当前未提交变更差异", @"上下文", seen, items);
        IMAddMentionItem(@"terminal", @"引用终端输出内容", @"上下文", seen, items);
        IMAddMentionItem(@"mcp", @"引用 MCP 工具与资源", @"上下文", seen, items);
    } else if ([family isEqualToString:@"trae"]) {
        IMAddMentionItem(@"Builder", @"调用 Builder 智能体执行开发任务", @"智能体", seen, items);
        IMAddMentionItem(@"Chat", @"切换到通用问答对话模式", @"智能体", seen, items);
        IMAddMentionItem(@"Codebase", @"检索整个代码库上下文", @"上下文", seen, items);
        IMAddMentionItem(@"Web", @"联网搜索参考信息", @"上下文", seen, items);
    } else if ([family isEqualToString:@"codebuddy"]) {
        IMAddMentionItem(@"codebase", @"检索当前代码库上下文", @"上下文", seen, items);
        IMAddMentionItem(@"git", @"引用 Git 变更与提交记录", @"上下文", seen, items);
        IMAddMentionItem(@"terminal", @"引用终端命令输出", @"上下文", seen, items);
        IMAddMentionItem(@"docs", @"引用参考文档", @"上下文", seen, items);
    } else if ([family isEqualToString:@"qoder"]) {
        IMAddMentionItem(@"workspace", @"检索当前工作区上下文", @"上下文", seen, items);
        IMAddMentionItem(@"terminal", @"引用终端命令输出", @"上下文", seen, items);
        IMAddMentionItem(@"git", @"引用 Git 变更差异", @"上下文", seen, items);
    } else if ([family isEqualToString:@"opencode"]) {
        IMAddMentionItem(@"general", @"委派给通用子代理处理复杂任务", @"智能体", seen, items);
        IMAddMentionItem(@"explore", @"委派给代码探索子代理检索仓库", @"智能体", seen, items);
    }

    if (workspaceRoot.length > 0) {
        IMScanWorkspaceMentions(workspaceRoot, seen, items);
    }
    if ([family isEqualToString:@"antigravity"] || [family isEqualToString:@"codex"]) {
        for (InputMirrorSkillItem *extra in InputMirrorLoadExtraMentionsForApp(bundleID, appName, workspaceRoot, nil)) {
            NSString *k = extra.name.lowercaseString;
            if (k.length && !seen[k]) {
                seen[k] = extra;
                [items addObject:extra];
            }
        }
    }
    return items;
}

static BOOL IMIsSubsequenceMatch(NSString *haystack, NSString *needle) {
    if (!needle.length) return YES;
    NSUInteger hLen = haystack.length;
    NSUInteger nLen = needle.length;
    if (nLen > hLen) return NO;
    NSUInteger ni = 0;
    for (NSUInteger hi = 0; hi < hLen && ni < nLen; hi++) {
        if ([haystack characterAtIndex:hi] == [needle characterAtIndex:ni]) {
            ni++;
        }
    }
    return ni == nLen;
}

static NSString *IMIdentifierAcronym(NSString *raw) {
    if (!raw.length) return @"";
    NSMutableString *out = [NSMutableString string];
    BOOL prevBoundary = YES;
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c == '-' || c == '_' || c == '.' || c == '/' || c == ' ') {
            prevBoundary = YES;
            continue;
        }
        BOOL isUpper = (c >= 'A' && c <= 'Z');
        if (prevBoundary || isUpper) {
            unichar lower = isUpper ? (unichar)(c + 32) : c;
            [out appendFormat:@"%C", lower];
        }
        prevBoundary = NO;
    }
    return out;
}

static NSInteger IMScoreSkillItemForQuery(InputMirrorSkillItem *item, NSString *q) {
    NSString *nameRaw = item.name ?: @"";
    NSString *nameLower = nameRaw.lowercaseString;
    NSString *trimmedSlash = [nameLower hasSuffix:@"/"] ? [nameLower substringToIndex:nameLower.length - 1] : nameLower;
    NSString *baseRaw = (nameRaw.lastPathComponent ?: nameRaw);
    NSString *baseLower = trimmedSlash.lastPathComponent ?: trimmedSlash;
    NSString *stemLower = [baseLower stringByDeletingPathExtension];
    NSString *titleRaw = item.displayTitle ?: @"";
    if ([titleRaw hasPrefix:@"@"] || [titleRaw hasPrefix:@"/"] || [titleRaw hasPrefix:@"$"]) {
        titleRaw = [titleRaw substringFromIndex:1];
    }
    NSString *titleLower = titleRaw.lowercaseString;
    NSString *detailLower = item.displayDetail.lowercaseString ?: @"";
    NSString *keywordsLower = item.searchKeywords.lowercaseString ?: @"";
    NSString *summaryLower = item.summary.lowercaseString ?: @"";

    NSInteger lengthPenalty = (NSInteger)MIN((NSUInteger)40, baseLower.length);
    NSInteger titlePenalty = (NSInteger)MIN((NSUInteger)36, titleLower.length);
    if ([baseLower isEqualToString:q] || [stemLower isEqualToString:q] || [trimmedSlash isEqualToString:q] ||
        (titleLower.length && [titleLower isEqualToString:q])) {
        return 1000 - MIN(lengthPenalty, titlePenalty > 0 ? titlePenalty : lengthPenalty);
    }
    if (titleLower.length && [titleLower hasPrefix:q]) {
        return 900 - titlePenalty;
    }
    if (baseLower.length && [baseLower hasPrefix:q]) {
        return 880 - lengthPenalty;
    }
    if ([trimmedSlash hasPrefix:q]) {
        return 840 - (NSInteger)MIN((NSUInteger)50, trimmedSlash.length);
    }
    if (titleLower.length && [titleLower containsString:q]) {
        return 760 - titlePenalty;
    }
    NSString *acronym = IMIdentifierAcronym([baseRaw stringByDeletingPathExtension]);
    if (acronym.length >= 2 && [acronym hasPrefix:q]) {
        return 740 - lengthPenalty;
    }
    if (baseLower.length && [baseLower containsString:q]) {
        return 620 - lengthPenalty;
    }
    if ([nameLower containsString:q]) {
        return 500 - (NSInteger)MIN((NSUInteger)60, nameLower.length);
    }
    if (q.length >= 2 && ((baseLower.length && IMIsSubsequenceMatch(baseLower, q)) ||
                          (titleLower.length && IMIsSubsequenceMatch(titleLower, q)))) {
        return 380 - lengthPenalty;
    }
    if (q.length >= 2 && IMIsSubsequenceMatch(nameLower, q)) {
        return 320 - (NSInteger)MIN((NSUInteger)60, nameLower.length);
    }
    if ((keywordsLower.length && [keywordsLower containsString:q]) ||
        (detailLower.length && [detailLower containsString:q])) {
        return 260;
    }
    if (summaryLower.length && [summaryLower containsString:q]) {
        return 200;
    }
    return 0;
}

NSArray<InputMirrorSkillItem *> *InputMirrorFilterSkills(NSArray<InputMirrorSkillItem *> *skills,
                                                         NSString *query) {
    if (!skills.count) return @[];
    NSString *q = [[query ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (!q.length) return skills;

    NSMutableArray<NSDictionary *> *scored = [NSMutableArray arrayWithCapacity:skills.count];
    for (NSUInteger idx = 0; idx < skills.count; idx++) {
        InputMirrorSkillItem *item = skills[idx];
        NSInteger score = IMScoreSkillItemForQuery(item, q);
        if (score > 0) {
            [scored addObject:@{ @"item": item, @"score": @(score), @"idx": @(idx) }];
        }
    }
    [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger sa = [a[@"score"] integerValue];
        NSInteger sb = [b[@"score"] integerValue];
        if (sa != sb) return (sa > sb) ? NSOrderedAscending : NSOrderedDescending;
        InputMirrorSkillItem *ia = a[@"item"];
        InputMirrorSkillItem *ib = b[@"item"];
        if (ia.recencyScore != ib.recencyScore) {
            return (ia.recencyScore > ib.recencyScore) ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a[@"idx"] compare:b[@"idx"]];
    }];

    NSMutableArray<InputMirrorSkillItem *> *result = [NSMutableArray arrayWithCapacity:scored.count];
    for (NSDictionary *entry in scored) {
        [result addObject:entry[@"item"]];
    }
    return result;
}

#pragma mark - Skill Popover Panel, Category Pills & Row Views

@interface InputMirrorSkillMenuPanel : NSPanel
@end

@implementation InputMirrorSkillMenuPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface InputMirrorCategoryTabView : NSView
@property(nonatomic, copy) NSString *categoryKey;
@property(nonatomic, copy) NSString *titleText;
@property(nonatomic) BOOL activeTab;
@property(nonatomic) BOOL hovered;
@property(nonatomic, strong) NSColor *accentColor;
@property(nonatomic, strong) NSColor *mutedColor;
@property(nonatomic, copy, nullable) void (^onSelect)(NSString *key);
@property(nonatomic, strong, nullable) NSTrackingArea *hoverArea;
@end

@implementation InputMirrorCategoryTabView

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverArea) [self removeTrackingArea:self.hoverArea];
    self.hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                  options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                    owner:self
                                                 userInfo:nil];
    [self addTrackingArea:self.hoverArea];
}

- (void)mouseEntered:(NSEvent *)event {
    self.hovered = YES;
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
    self.hovered = NO;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    if (self.onSelect && self.categoryKey.length) self.onSelect(self.categoryKey);
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect pill = NSInsetRect(self.bounds, 1.0, 2.5);
    NSColor *accent = self.accentColor ?: NSColor.controlAccentColor;
    NSColor *muted = self.mutedColor ?: NSColor.secondaryLabelColor;
    if (self.activeTab) {
        [[accent colorWithAlphaComponent:0.16] setFill];
        NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:pill xRadius:6.5 yRadius:6.5];
        [bp fill];
        [[accent colorWithAlphaComponent:0.38] setStroke];
        bp.lineWidth = 0.85;
        [bp stroke];
    } else if (self.hovered) {
        [[muted colorWithAlphaComponent:0.12] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:6.5 yRadius:6.5] fill];
    }
    NSFont *font = [NSFont systemFontOfSize:11.5 weight:(self.activeTab ? NSFontWeightSemibold : NSFontWeightMedium)];
    NSColor *fg = self.activeTab ? accent : muted;
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: fg };
    NSSize sz = [(self.titleText ?: @"") sizeWithAttributes:attrs];
    NSPoint pt = NSMakePoint(floor((NSWidth(self.bounds) - sz.width) * 0.5),
                             floor((NSHeight(self.bounds) - sz.height) * 0.5));
    [(self.titleText ?: @"") drawAtPoint:pt withAttributes:attrs];
}

@end

@interface InputMirrorSkillRowView : NSView
@property(nonatomic) NSInteger rowIndex;
@property(nonatomic) BOOL selectedRow;
@property(nonatomic, strong) NSColor *selectionColor;
@property(nonatomic, copy, nullable) void (^onHover)(NSInteger idx);
@property(nonatomic, copy, nullable) void (^onClick)(NSInteger idx);
@property(nonatomic, strong, nullable) NSTrackingArea *hoverArea;
@end

@implementation InputMirrorSkillRowView

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverArea) [self removeTrackingArea:self.hoverArea];
    self.hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                  options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                    owner:self
                                                 userInfo:nil];
    [self addTrackingArea:self.hoverArea];
}

- (void)mouseEntered:(NSEvent *)event {
    if (self.onHover) self.onHover(self.rowIndex);
}

- (void)mouseDown:(NSEvent *)event {
    if (self.onClick) self.onClick(self.rowIndex);
}

- (void)setSelectedRow:(BOOL)selectedRow {
    if (_selectedRow == selectedRow) return;
    _selectedRow = selectedRow;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (self.selectedRow && self.selectionColor) {
        [self.selectionColor setFill];
        NSRect pill = NSInsetRect(self.bounds, 6.0, 2.0);
        [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:8.0 yRadius:8.0] fill];
    }
}

@end

#pragma mark - InputMirrorPanel

@implementation InputMirrorPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

#pragma mark - Smart List Editing Helpers

typedef NS_ENUM(NSInteger, IMListLineKind) {
    IMListLineKindNone = 0,
    IMListLineKindUnordered,
    IMListLineKindOrdered,
    IMListLineKindTask,
};

@interface IMParsedListLine : NSObject
@property(nonatomic) IMListLineKind kind;
@property(nonatomic, copy) NSString *indent;
@property(nonatomic, copy) NSString *marker;
@property(nonatomic, copy) NSString *taskBox;
@property(nonatomic) NSInteger orderedNumber;
@property(nonatomic) NSUInteger prefixLength;
@property(nonatomic, copy) NSString *body;
@end

@implementation IMParsedListLine
@end

static IMParsedListLine *IMParseListLine(NSString *line) {
    IMParsedListLine *info = [[IMParsedListLine alloc] init];
    info.kind = IMListLineKindNone;
    info.indent = @"";
    info.marker = @"";
    info.taskBox = @"";
    info.body = line ?: @"";
    if (!line.length) return info;

    NSRange all = NSMakeRange(0, line.length);
    NSRegularExpression *taskRe = IMRegex(@"^([ \\t\\u00A0\\u3000]*)([-*+•◦▪▫●○■□‣⁃·–—])([ \\t\\u00A0\\u3000]+)(\\[[ xX]\\])([ \\t\\u00A0\\u3000]+)");
    NSRegularExpression *ulRe = IMRegex(@"^([ \\t\\u00A0\\u3000]*)([-*+•◦▪▫●○■□‣⁃·–—])([ \\t\\u00A0\\u3000]+)");
    NSRegularExpression *olRe = IMRegex(@"^([ \\t\\u00A0\\u3000]*)(\\d+)([.)、])([ \\t\\u00A0\\u3000]+)");

    NSTextCheckingResult *m = nil;
    if ((m = [taskRe firstMatchInString:line options:0 range:all])) {
        info.kind = IMListLineKindTask;
        info.indent = [line substringWithRange:[m rangeAtIndex:1]];
        info.marker = [line substringWithRange:[m rangeAtIndex:2]];
        info.taskBox = [line substringWithRange:[m rangeAtIndex:4]];
        info.prefixLength = NSMaxRange(m.range);
        info.body = [line substringFromIndex:info.prefixLength];
    } else if ((m = [ulRe firstMatchInString:line options:0 range:all])) {
        info.kind = IMListLineKindUnordered;
        info.indent = [line substringWithRange:[m rangeAtIndex:1]];
        info.marker = [line substringWithRange:[m rangeAtIndex:2]];
        info.prefixLength = NSMaxRange(m.range);
        info.body = [line substringFromIndex:info.prefixLength];
    } else if ((m = [olRe firstMatchInString:line options:0 range:all])) {
        info.kind = IMListLineKindOrdered;
        info.indent = [line substringWithRange:[m rangeAtIndex:1]];
        info.orderedNumber = [[line substringWithRange:[m rangeAtIndex:2]] integerValue];
        info.marker = [line substringWithRange:[m rangeAtIndex:3]];
        info.prefixLength = NSMaxRange(m.range);
        info.body = [line substringFromIndex:info.prefixLength];
    }
    return info;
}

static BOOL IMIsUnicodeCycleBullet(NSString *marker) {
    return [marker isEqualToString:@"•"] ||
           [marker isEqualToString:@"◦"] ||
           [marker isEqualToString:@"▪"];
}

static NSString *IMBulletForLevel(NSString *originalMarker, NSUInteger level) {
    if (!IMIsUnicodeCycleBullet(originalMarker)) return originalMarker;
    if (level == 0) return @"•";
    if (level == 1) return @"◦";
    return @"▪";
}

static NSString *IMOutdentOneLevel(NSString *indent) {
    if (!indent.length) return @"";
    unichar last = [indent characterAtIndex:indent.length - 1];
    if (last == '\t' || last == 0x3000) {
        return [indent substringToIndex:indent.length - 1];
    }
    if (indent.length >= 2) {
        unichar prev = [indent characterAtIndex:indent.length - 2];
        if (prev == ' ' || prev == 0x00A0) {
            return [indent substringToIndex:indent.length - 2];
        }
    }
    return [indent substringToIndex:indent.length - 1];
}

static NSInteger IMNextOrderedNumberBeforeLine(NSString *text, NSUInteger lineStart, NSUInteger targetIndentCols) {
    NSUInteger pos = lineStart;
    while (pos > 0) {
        NSRange prevLineRange = [text lineRangeForRange:NSMakeRange(pos - 1, 0)];
        NSUInteger contentLen = prevLineRange.length;
        while (contentLen > 0) {
            unichar ch = [text characterAtIndex:prevLineRange.location + contentLen - 1];
            if (ch == '\n' || ch == '\r') contentLen--;
            else break;
        }
        NSString *prevLine = [text substringWithRange:NSMakeRange(prevLineRange.location, contentLen)];
        IMParsedListLine *prev = IMParseListLine(prevLine);
        if (prev.kind == IMListLineKindNone) break;
        NSUInteger prevCols = IMIndentColumns(prev.indent);
        if (prevCols == targetIndentCols && prev.kind == IMListLineKindOrdered) {
            return prev.orderedNumber + 1;
        }
        if (prevCols < targetIndentCols) {
            return 1;
        }
        if (prevLineRange.location == 0) break;
        pos = prevLineRange.location;
    }
    return 1;
}

static NSString *IMBuildListPrefix(IMParsedListLine *info, NSString *newIndent, NSInteger orderedNumOverride, BOOL resetTaskUnchecked) {
    NSUInteger level = IMListNestingLevel(newIndent);
    switch (info.kind) {
        case IMListLineKindUnordered: {
            NSString *bullet = IMBulletForLevel(info.marker, level);
            return [NSString stringWithFormat:@"%@%@ ", newIndent, bullet];
        }
        case IMListLineKindTask: {
            NSString *bullet = IMBulletForLevel(info.marker, level);
            NSString *box = resetTaskUnchecked ? @"[ ]" : (info.taskBox.length ? info.taskBox : @"[ ]");
            return [NSString stringWithFormat:@"%@%@ %@ ", newIndent, bullet, box];
        }
        case IMListLineKindOrdered: {
            NSInteger num = orderedNumOverride > 0 ? orderedNumOverride : MAX(1, info.orderedNumber);
            return [NSString stringWithFormat:@"%@%ld%@ ", newIndent, (long)num, info.marker];
        }
        default:
            return newIndent;
    }
}

#pragma mark - InputMirrorTextView

@interface InputMirrorTextView ()
- (void)applyUndoableReplacementInRange:(NSRange)range withString:(NSString *)replacement newSelection:(NSRange)newSel;
@end

@implementation InputMirrorTextView

- (BOOL)needsPanelToBecomeKey { return YES; }

- (BOOL)showingMirrorPlaceholder {
    return self.string.length == 0 && !self.hasMarkedText && self.mirrorPlaceholder.length > 0;
}

- (void)applyUndoableReplacementInRange:(NSRange)range withString:(NSString *)replacement newSelection:(NSRange)newSel {
    if (![self shouldChangeTextInRange:range replacementString:replacement]) return;
    [self.textStorage replaceCharactersInRange:range withString:replacement];
    [self didChangeText];
    NSUInteger maxLen = self.string.length;
    if (newSel.location > maxLen) newSel.location = maxLen;
    if (NSMaxRange(newSel) > maxLen) newSel.length = maxLen - newSel.location;
    [self setSelectedRange:newSel];
}

- (NSRange)contentRangeForLineAtIndex:(NSUInteger)index {
    NSString *text = self.string ?: @"";
    NSUInteger safeIdx = MIN(index, text.length);
    NSRange lineRange = [text lineRangeForRange:NSMakeRange(safeIdx, 0)];
    NSUInteger contentLen = lineRange.length;
    while (contentLen > 0) {
        unichar ch = [text characterAtIndex:lineRange.location + contentLen - 1];
        if (ch == '\n' || ch == '\r') contentLen--;
        else break;
    }
    return NSMakeRange(lineRange.location, contentLen);
}

- (BOOL)handleSmartListNewline {
    NSRange sel = self.selectedRange;
    if (sel.length > 0) return NO;
    NSString *text = self.string ?: @"";
    NSRange contentRange = [self contentRangeForLineAtIndex:sel.location];
    NSString *line = [text substringWithRange:contentRange];
    IMParsedListLine *info = IMParseListLine(line);
    if (info.kind == IMListLineKindNone) return NO;

    NSUInteger col = sel.location - contentRange.location;
    if (col < info.prefixLength) return NO;

    NSString *trimmedBody = IMTrimWhitespaceAndNBSP(info.body);
    if (trimmedBody.length == 0) {
        // Empty list item: outdent one level if nested, or exit list if already top-level
        if (info.indent.length > 0) {
            NSString *newIndent = IMOutdentOneLevel(info.indent);
            NSInteger nextNum = (info.kind == IMListLineKindOrdered)
                ? IMNextOrderedNumberBeforeLine(text, contentRange.location, IMIndentColumns(newIndent))
                : 0;
            NSString *newPrefix = IMBuildListPrefix(info, newIndent, nextNum, YES);
            [self applyUndoableReplacementInRange:contentRange
                                       withString:newPrefix
                                     newSelection:NSMakeRange(contentRange.location + newPrefix.length, 0)];
        } else {
            [self applyUndoableReplacementInRange:contentRange
                                       withString:@""
                                     newSelection:NSMakeRange(contentRange.location, 0)];
        }
        return YES;
    }

    // Non-empty list item: continue list on next line with matching level/marker (and incremented number for ordered lists)
    NSInteger nextNum = (info.kind == IMListLineKindOrdered) ? (info.orderedNumber + 1) : 0;
    NSString *nextPrefix = IMBuildListPrefix(info, info.indent, nextNum, YES);
    NSString *insertion = [@"\n" stringByAppendingString:nextPrefix];
    [self applyUndoableReplacementInRange:sel
                               withString:insertion
                             newSelection:NSMakeRange(sel.location + insertion.length, 0)];
    return YES;
}

- (BOOL)handleSmartListIndent:(BOOL)isOutdent {
    NSString *text = self.string ?: @"";
    NSRange sel = self.selectedRange;
    NSRange effectiveSel = sel;
    if (effectiveSel.length > 0 && NSMaxRange(effectiveSel) > 0 &&
        [text characterAtIndex:NSMaxRange(effectiveSel) - 1] == '\n') {
        effectiveSel.length -= 1;
    }
    NSRange blockRange = [text lineRangeForRange:effectiveSel];
    NSUInteger blockEnd = NSMaxRange(blockRange);

    // Collect line content ranges in blockRange
    NSMutableArray<NSValue *> *lineRanges = [NSMutableArray array];
    BOOL hasListLine = NO;
    BOOL hasIndentedLine = NO;
    NSUInteger pos = blockRange.location;
    while (pos < blockEnd || (pos == blockEnd && blockRange.length == 0)) {
        NSRange lr = [text lineRangeForRange:NSMakeRange(pos, 0)];
        NSUInteger cLen = lr.length;
        while (cLen > 0) {
            unichar ch = [text characterAtIndex:lr.location + cLen - 1];
            if (ch == '\n' || ch == '\r') cLen--;
            else break;
        }
        NSRange cr = NSMakeRange(lr.location, cLen);
        [lineRanges addObject:[NSValue valueWithRange:cr]];
        NSString *line = [text substringWithRange:cr];
        IMParsedListLine *info = IMParseListLine(line);
        if (info.kind != IMListLineKindNone) hasListLine = YES;
        if (info.indent.length > 0) hasIndentedLine = YES;
        pos = NSMaxRange(lr);
        if (lr.length == 0) break;
    }

    if (!hasListLine && !(isOutdent && hasIndentedLine)) return NO;

    NSMutableString *rebuilt = [NSMutableString string];
    NSInteger selStartDelta = 0;
    NSInteger selEndDelta = 0;
    NSUInteger origSelStart = sel.location;
    NSUInteger origSelEnd = NSMaxRange(sel);

    NSUInteger cursor = blockRange.location;
    for (NSUInteger i = 0; i < lineRanges.count; i++) {
        NSRange cr = lineRanges[i].rangeValue;
        NSString *line = [text substringWithRange:cr];
        IMParsedListLine *info = IMParseListLine(line);
        NSString *newLine = line;
        NSInteger linePrefixDelta = 0;

        if (info.kind != IMListLineKindNone) {
            if (!isOutdent) {
                if (IMIndentColumns(info.indent) < 12) {
                    NSString *newIndent = [info.indent stringByAppendingString:@"  "];
                    NSInteger nextNum = (info.kind == IMListLineKindOrdered)
                        ? IMNextOrderedNumberBeforeLine(text, cr.location, IMIndentColumns(newIndent))
                        : 0;
                    NSString *newPrefix = IMBuildListPrefix(info, newIndent, nextNum, NO);
                    newLine = [newPrefix stringByAppendingString:info.body];
                    linePrefixDelta = (NSInteger)newPrefix.length - (NSInteger)info.prefixLength;
                }
            } else if (info.indent.length > 0) {
                NSString *newIndent = IMOutdentOneLevel(info.indent);
                NSInteger nextNum = (info.kind == IMListLineKindOrdered)
                    ? IMNextOrderedNumberBeforeLine(text, cr.location, IMIndentColumns(newIndent))
                    : 0;
                NSString *newPrefix = IMBuildListPrefix(info, newIndent, nextNum, NO);
                newLine = [newPrefix stringByAppendingString:info.body];
                linePrefixDelta = (NSInteger)newPrefix.length - (NSInteger)info.prefixLength;
            }
        } else if (!isOutdent && lineRanges.count > 1 && line.length > 0) {
            newLine = [@"  " stringByAppendingString:line];
            linePrefixDelta = 2;
        } else if (isOutdent && line.length > 0) {
            unichar first = [line characterAtIndex:0];
            if (first == '\t' || first == 0x3000) {
                newLine = [line substringFromIndex:1];
                linePrefixDelta = -1;
            } else if (first == ' ' || first == 0x00A0) {
                NSUInteger remove = (line.length >= 2 && ([line characterAtIndex:1] == ' ' || [line characterAtIndex:1] == 0x00A0)) ? 2 : 1;
                newLine = [line substringFromIndex:remove];
                linePrefixDelta = -(NSInteger)remove;
            }
        }

        if (origSelStart >= cr.location) {
            if (origSelStart <= NSMaxRange(cr)) {
                selStartDelta += linePrefixDelta;
            } else {
                selStartDelta += linePrefixDelta;
            }
        }
        if (origSelEnd >= cr.location) {
            selEndDelta += linePrefixDelta;
        }

        [rebuilt appendString:newLine];
        // Append original line ending (\n or \r\n) if present inside blockRange
        NSUInteger lineContentEnd = NSMaxRange(cr);
        NSUInteger nextLineStart = (i + 1 < lineRanges.count) ? lineRanges[i + 1].rangeValue.location : blockEnd;
        if (nextLineStart > lineContentEnd) {
            [rebuilt appendString:[text substringWithRange:NSMakeRange(lineContentEnd, nextLineStart - lineContentEnd)]];
        }
        cursor = nextLineStart;
    }
    (void)cursor;

    NSInteger newStart = MAX((NSInteger)blockRange.location, (NSInteger)origSelStart + selStartDelta);
    NSInteger newEnd = MAX(newStart, (NSInteger)origSelEnd + selEndDelta);
    NSRange nextSel = NSMakeRange((NSUInteger)newStart, (NSUInteger)(newEnd - newStart));
    if (![rebuilt isEqualToString:[text substringWithRange:blockRange]]) {
        [self applyUndoableReplacementInRange:blockRange withString:rebuilt newSelection:nextSel];
    }
    return YES;
}

- (BOOL)handleSmartListBackspace {
    NSRange sel = self.selectedRange;
    if (sel.length > 0) return NO;
    NSString *text = self.string ?: @"";
    NSRange contentRange = [self contentRangeForLineAtIndex:sel.location];
    NSString *line = [text substringWithRange:contentRange];
    IMParsedListLine *info = IMParseListLine(line);
    if (info.kind == IMListLineKindNone) return NO;

    NSUInteger col = sel.location - contentRange.location;
    if (col != info.prefixLength) return NO;

    NSRange prefixRange = NSMakeRange(contentRange.location, info.prefixLength);
    if (info.indent.length > 0) {
        // Outdent back to previous list level (preserving any body text after the cursor)
        NSString *newIndent = IMOutdentOneLevel(info.indent);
        NSInteger nextNum = (info.kind == IMListLineKindOrdered)
            ? IMNextOrderedNumberBeforeLine(text, contentRange.location, IMIndentColumns(newIndent))
            : 0;
        NSString *newPrefix = IMBuildListPrefix(info, newIndent, nextNum, NO);
        [self applyUndoableReplacementInRange:prefixRange
                                   withString:newPrefix
                                 newSelection:NSMakeRange(contentRange.location + newPrefix.length, 0)];
    } else {
        // Top-level list item: remove list prefix to exit list (preserving any body text)
        [self applyUndoableReplacementInRange:prefixRange
                                   withString:@""
                                 newSelection:NSMakeRange(contentRange.location, 0)];
    }
    return YES;
}

// Accessory apps have no Edit menu, so explicitly handle standard Cmd+A/C/V/X/Z/Shift+Z & Cmd+/ shortcuts!
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown) {
        NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        BOOL cmdOnly = (mods == NSEventModifierFlagCommand);
        BOOL cmdShift = (mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift));
        NSString *key = event.charactersIgnoringModifiers.lowercaseString;
        if (cmdOnly) {
            if ([key isEqualToString:@"a"]) { [self selectAll:nil]; return YES; }
            if ([key isEqualToString:@"c"]) { [self copy:nil]; return YES; }
            if ([key isEqualToString:@"v"]) { [self paste:nil]; return YES; }
            if ([key isEqualToString:@"x"]) { [self cut:nil]; return YES; }
            if ([key isEqualToString:@"z"]) {
                if (self.undoManager.canUndo) [self.undoManager undo];
                return YES;
            }
            if ([key isEqualToString:@"/"] || event.keyCode == kVK_ANSI_Slash) {
                if (self.onNativeSlashHandoffShortcut) {
                    self.onNativeSlashHandoffShortcut();
                    return YES;
                }
            }
            if ([key isEqualToString:@"@"]) {
                if (self.onNativeMentionHandoffShortcut) {
                    self.onNativeMentionHandoffShortcut();
                    return YES;
                }
            }
        } else if (cmdShift) {
            if ([key isEqualToString:@"z"]) {
                if (self.undoManager.canRedo) [self.undoManager redo];
                return YES;
            }
            if ([key isEqualToString:@"2"] || [key isEqualToString:@"@"] || event.keyCode == kVK_ANSI_2) {
                if (self.onNativeMentionHandoffShortcut) {
                    self.onNativeMentionHandoffShortcut();
                    return YES;
                }
            }
        }
    }
    return [super performKeyEquivalent:event];
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    [super setMarkedText:string selectedRange:selectedRange replacementRange:replacementRange];
    if (self.onCompositionChanged) self.onCompositionChanged();
}

- (void)unmarkText {
    [super unmarkText];
    if (self.onCompositionChanged) self.onCompositionChanged();
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    [super insertText:string replacementRange:replacementRange];
    if (self.onCompositionChanged) self.onCompositionChanged();
}

- (void)didChangeText {
    [super didChangeText];
    if (self.onCompositionChanged) self.onCompositionChanged();
    [self setNeedsDisplay:YES];
    [self.enclosingScrollView.contentView setNeedsDisplay:YES];
    [self.enclosingScrollView setNeedsDisplay:YES];
    [self.window.contentView setNeedsDisplay:YES];
}

- (void)keyDown:(NSEvent *)event {
    if (!self.hasMarkedText && self.onSkillMenuKeyDown && self.onSkillMenuKeyDown(event)) {
        return;
    }
    unsigned short keyCode = event.keyCode;
    BOOL isReturn = (keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter);
    BOOL isTab = (keyCode == kVK_Tab);
    BOOL isDelete = (keyCode == kVK_Delete);
    BOOL isEscape = (keyCode == kVK_Escape);
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL hasShift = (mods & NSEventModifierFlagShift) != 0;
    BOOL hasOtherMods = (mods & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl)) != 0;

    if (isReturn && !self.hasMarkedText) {
        if (hasShift && !hasOtherMods) {
            if ([self handleSmartListNewline]) return;
            [self insertNewlineIgnoringFieldEditor:nil];
            return;
        }
        if (!hasShift && !hasOtherMods) {
            if (self.onSubmit) self.onSubmit();
            return;
        }
    }
    if (isTab && !hasOtherMods && !self.hasMarkedText) {
        if ([self handleSmartListIndent:hasShift]) return;
    }
    if (isDelete && !hasShift && !hasOtherMods && !self.hasMarkedText) {
        if (self.onAtomicChipBackspace && self.onAtomicChipBackspace()) return;
        if ([self handleSmartListBackspace]) return;
    }
    if (isEscape && !self.hasMarkedText) {
        if (self.onCancelEdit) self.onCancelEdit();
        return;
    }
    [super keyDown:event];
}

// Codex-style vector bullets: level 0 filled dot, level 1 hollow ring, level 2+ small filled square.
- (void)drawVectorListBullets {
    NSTextStorage *storage = self.textStorage;
    NSLayoutManager *lm = self.layoutManager;
    NSTextContainer *tc = self.textContainer;
    if (!storage.length || !lm || !tc) return;
    NSPoint origin = self.textContainerOrigin;
    [storage enumerateAttribute:InputMirrorListBulletLevelAttributeName
                        inRange:NSMakeRange(0, storage.length)
                        options:0
                     usingBlock:^(id value, NSRange range, BOOL *stop) {
        if (![value isKindOfClass:NSNumber.class]) return;
        NSUInteger level = [value unsignedIntegerValue];
        NSColor *color = [storage attribute:InputMirrorListBulletColorAttributeName atIndex:range.location effectiveRange:NULL] ?: NSColor.labelColor;
        NSRange glyphRange = [lm glyphRangeForCharacterRange:range actualCharacterRange:NULL];
        NSRect r = [lm boundingRectForGlyphRange:glyphRange inTextContainer:tc];
        if (NSIsEmptyRect(r)) return;
        r.origin.x += origin.x;
        r.origin.y += origin.y;
        if (!NSIntersectsRect(r, self.visibleRect)) return;
        NSFont *font = self.font ?: [NSFont systemFontOfSize:kMirrorBodyFontSize];
        CGFloat d = (level == 0) ? 6.0 : (level == 1 ? 6.0 : 4.5);
        CGFloat cx = NSMinX(r) + MAX(d * 0.5, NSWidth(r) * 0.5);
        CGFloat cy = NSMinY(r) + NSHeight(r) * 0.5 - (font.pointSize > 0 ? 0.5 : 0);
        NSRect b = NSMakeRect(cx - d * 0.5, cy - d * 0.5, d, d);
        [color setFill];
        [color setStroke];
        if (level == 0) {
            [[NSBezierPath bezierPathWithOvalInRect:b] fill];
        } else if (level == 1) {
            NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(b, 0.7, 0.7)];
            ring.lineWidth = 1.4;
            [ring stroke];
        } else {
            [[NSBezierPath bezierPathWithRoundedRect:b xRadius:0.8 yRadius:0.8] fill];
        }
    }];
}

- (void)drawMentionChips {
    NSTextStorage *storage = self.textStorage;
    NSLayoutManager *lm = self.layoutManager;
    NSTextContainer *tc = self.textContainer;
    if (!storage.length || !lm || !tc) return;
    [lm ensureLayoutForTextContainer:tc];
    NSPoint origin = self.textContainerOrigin;

    [storage enumerateAttribute:InputMirrorChipColorAttributeName
                        inRange:NSMakeRange(0, storage.length)
                        options:0
                     usingBlock:^(id borderVal, NSRange charRange, BOOL *stop) {
        if (![borderVal isKindOfClass:NSColor.class] || charRange.length == 0) return;
        NSColor *borderColor = (NSColor *)borderVal;
        NSColor *fillColor = [storage attribute:InputMirrorChipFillColorAttributeName atIndex:charRange.location effectiveRange:NULL];
        if (![fillColor isKindOfClass:NSColor.class]) {
            fillColor = [borderColor colorWithAlphaComponent:0.12];
        }
        NSRange glyphRange = [lm glyphRangeForCharacterRange:charRange actualCharacterRange:NULL];
        if (glyphRange.length == 0) return;
        [lm enumerateEnclosingRectsForGlyphRange:glyphRange
                        withinSelectedGlyphRange:NSMakeRange(NSNotFound, 0)
                                 inTextContainer:tc
                                      usingBlock:^(NSRect rect, BOOL *innerStop) {
            if (NSIsEmptyRect(rect)) return;
            NSRect pill = NSMakeRect(origin.x + rect.origin.x - 2.0,
                                     origin.y + rect.origin.y + 1.0,
                                     rect.size.width + 4.0,
                                     MAX(16.0, rect.size.height - 3.0));
            if (!NSIntersectsRect(pill, self.visibleRect)) return;
            NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:pill xRadius:5.0 yRadius:5.0];
            [fillColor setFill];
            [bp fill];
            bp.lineWidth = 0.85;
            [borderColor setStroke];
            [bp stroke];
        }];
    }];
}

- (void)drawRect:(NSRect)dirtyRect {
    // Explicitly clear transparent backing pixels before drawing so deleted text never ghosts in non-opaque panels
    [[NSColor clearColor] setFill];
    NSRectFillUsingOperation(dirtyRect, NSCompositingOperationClear);
    // Paint inline mention/skill/slash chips underneath text glyphs so typography stays Retina-crisp
    [self drawMentionChips];
    [super drawRect:dirtyRect];
    [self drawVectorListBullets];

    // Draw placeholder directly inside drawRect ONLY when completely empty and not composing IME text
    if (self.showingMirrorPlaceholder) {
        NSPoint origin = self.textContainerOrigin;
        NSDictionary *attrs = @{
            NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:kMirrorBodyFontSize],
            NSForegroundColorAttributeName: self.mirrorPlaceholderColor ?: NSColor.tertiaryLabelColor
        };
        [self.mirrorPlaceholder drawAtPoint:NSMakePoint(origin.x + 5.0, origin.y + 1.0) withAttributes:attrs];
    }

    if (!self.mirrorCaretVisible || !self.mirrorCaretBlinkOn || self.window.isKeyWindow) return;
    if (self.mirrorSelectionRange.length > 0) return;
    NSLayoutManager *lm = self.layoutManager;
    NSTextContainer *tc = self.textContainer;
    if (!lm || !tc) return;

    [lm ensureLayoutForTextContainer:tc];
    NSUInteger textLen = self.string.length;
    NSUInteger charIdx = MIN(self.mirrorSelectionRange.location, textLen);
    NSRect caretRect = NSZeroRect;
    NSPoint origin = self.textContainerOrigin;
    CGFloat defaultLineH = MAX(20.0, [lm defaultLineHeightForFont:self.font ?: [NSFont systemFontOfSize:kMirrorBodyFontSize]]);

    if (textLen == 0) {
        caretRect = NSMakeRect(origin.x + 2.0, origin.y + 1.0, 2.2, defaultLineH);
    } else if (charIdx >= textLen) {
        NSRect extra = lm.extraLineFragmentRect;
        if (!NSIsEmptyRect(extra)) {
            caretRect = NSMakeRect(origin.x + extra.origin.x, origin.y + extra.origin.y + 1.0, 2.2, MIN(defaultLineH + 2.0, MAX(18.0, extra.size.height - 2.0)));
        } else {
            NSUInteger glyphIdx = [lm glyphIndexForCharacterAtIndex:textLen - 1];
            NSRect lineUsed = [lm lineFragmentUsedRectForGlyphAtIndex:glyphIdx effectiveRange:NULL];
            NSRect glyphRect = [lm boundingRectForGlyphRange:NSMakeRange(glyphIdx, 1) inTextContainer:tc];
            CGFloat caretX = MAX(NSMaxX(glyphRect), NSMaxX(lineUsed));
            CGFloat caretH = MIN(defaultLineH + 2.0, MAX(18.0, lineUsed.size.height - 4.0));
            caretRect = NSMakeRect(origin.x + caretX, origin.y + lineUsed.origin.y + 1.0, 2.2, caretH);
        }
    } else {
        NSUInteger glyphIdx = [lm glyphIndexForCharacterAtIndex:charIdx];
        NSRect lineUsed = [lm lineFragmentUsedRectForGlyphAtIndex:glyphIdx effectiveRange:NULL];
        NSRect glyphRect = [lm boundingRectForGlyphRange:NSMakeRange(glyphIdx, 1) inTextContainer:tc];
        CGFloat caretH = MIN(defaultLineH + 2.0, MAX(18.0, lineUsed.size.height - 4.0));
        caretRect = NSMakeRect(origin.x + glyphRect.origin.x, origin.y + lineUsed.origin.y + 1.0, 2.2, caretH);
    }

    NSColor *caretColor = self.mirrorCaretColor ?: PanelColor(0x2563eb, 0x60a5fa, 0.95);
    [caretColor setFill];
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:caretRect xRadius:1.1 yRadius:1.1];
    [path fill];
}

@end

#pragma mark - InputMirrorController

@interface InputMirrorDraft : NSObject
@property(nonatomic, copy) NSString *text;
@property(nonatomic) NSRange selection;
@property(nonatomic, copy) NSString *baseTargetText;
@property(nonatomic, copy) NSSet<NSString *> *confirmedChips;
@property(nonatomic) NSTimeInterval savedAt;
@end

@implementation InputMirrorDraft
@end

@interface InputMirrorController ()
@property(nonatomic, strong, readwrite) InputMirrorPanel *panel;
@property(nonatomic, strong, readwrite) InputMirrorTextView *textView;
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, strong) NSVisualEffectView *glassView;
@property(nonatomic, strong) PanelSurface *cardSurface;
@property(nonatomic, strong) NSView *dragPill;
@property(nonatomic, strong) NSView *statusDot;
@property(nonatomic, strong) NSImageView *appIconView;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *countLabel;
@property(nonatomic, strong) NSButton *closeButton;
@property(nonatomic, copy, readwrite) NSString *mirroredText;
@property(nonatomic, readwrite) NSRange mirroredSelection;
@property(nonatomic, copy, readwrite) NSString *targetAppName;
@property(nonatomic, copy, readwrite) NSString *targetBundleID;
@property(nonatomic, assign) pid_t targetPID;
@property(nonatomic, assign) AXUIElementRef targetElement;
@property(nonatomic, assign) AXUIElementRef dismissedElement;
@property(nonatomic, copy) NSString *dismissedTextSnapshot;
@property(nonatomic, copy) NSString *lastSyncedToTargetText;
@property(nonatomic, assign) AXObserverRef axObserver;
@property(nonatomic, assign) pid_t observedPID;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *manualAXPids;
@property(nonatomic, strong) NSMutableDictionary<NSString *, InputMirrorDraft *> *unsyncedDrafts;
@property(nonatomic, strong) NSMutableSet<NSString *> *confirmedChipSet;
@property(nonatomic, assign, readwrite) BOOL lastNativeHandoffAutoConfirmed;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, strong) NSTimer *caretTimer;
@property(nonatomic, strong) NSTimer *liveSyncTimer;
@property(nonatomic, strong) id globalMouseMonitor;
@property(nonatomic, strong) id globalKeyMonitor;
@property(nonatomic, assign) NSTimeInterval lastExternalReturnTime;
@property(nonatomic, assign) NSTimeInterval sendCloseCooldownUntil;
@property(nonatomic, assign) NSTimeInterval postSyncGraceUntil;
@property(nonatomic, assign) NSTimeInterval lastInputSeenTime;
@property(nonatomic, assign) BOOL suppressFrameSave;
@property(nonatomic, assign) BOOL inPreviewSample;
@property(nonatomic, assign) BOOL applyingFormattedText;
@property(nonatomic, assign) BOOL hasLocalEditsPendingSync;
@property(nonatomic, assign) BOOL suppressResignSync;
@property(nonatomic, assign) BOOL syncInFlight;
@property(nonatomic, assign) BOOL axPollScheduled;
@property(nonatomic, assign, readwrite) BOOL awaitingUserClickAfterJump;

@property(nonatomic, strong) InputMirrorSkillMenuPanel *skillMenuPanel;
@property(nonatomic, strong) PanelSurface *skillMenuCard;
@property(nonatomic, strong) NSVisualEffectView *skillMenuGlass;
@property(nonatomic, strong) NSView *skillMenuCategoryBar;
@property(nonatomic, strong) NSView *skillMenuCategoryDivider;
@property(nonatomic, strong) NSScrollView *skillMenuScroll;
@property(nonatomic, strong) NSView *skillMenuListContainer;
@property(nonatomic, strong) NSView *skillMenuFooterDivider;
@property(nonatomic, strong) InputMirrorSkillRowView *skillMenuFooterRow;
@property(nonatomic, strong) NSTextField *skillMenuFooterTitle;
@property(nonatomic, strong) NSTextField *skillMenuFooterHint;
@property(nonatomic, strong) NSArray<InputMirrorSkillItem *> *skillMenuItems;
@property(nonatomic, strong) NSArray<InputMirrorSkillRowView *> *skillMenuRowViews;
@property(nonatomic, strong) NSArray<InputMirrorCategoryTabView *> *skillMenuCategoryTabViews;
@property(nonatomic, copy, readwrite) NSString *activeSkillMenuCategoryKey;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *availableSkillMenuCategories;
@property(nonatomic, assign) unichar lastCategoryTriggerChar;
@property(nonatomic, assign) NSInteger skillMenuSelectedIndex;
@property(nonatomic, assign) InputMirrorSkillTrigger activeSkillTrigger;
@property(nonatomic, assign) NSUInteger dismissedSkillTriggerLocation;
@property(nonatomic, copy) NSArray<InputMirrorSkillItem *> *cachedSkills;
@property(nonatomic, copy) NSString *cachedSkillsCacheKey;
@property(nonatomic, assign) NSTimeInterval cachedSkillsLoadedAt;
@property(nonatomic, copy) NSArray<InputMirrorSkillItem *> *cachedSlashCommands;
@property(nonatomic, copy) NSString *cachedSlashCommandsFamily;
@property(nonatomic, copy) NSArray<InputMirrorSkillItem *> *cachedMentions;
@property(nonatomic, copy) NSString *cachedMentionsCacheKey;
@property(nonatomic, assign) NSTimeInterval cachedMentionsLoadedAt;
- (void)pollFocusedInput;
@end

static void IMAxObserverCallback(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *refcon) {
    InputMirrorController *controller = (__bridge InputMirrorController *)refcon;
    if (!controller || controller.axPollScheduled) return;
    controller.axPollScheduled = YES;
    __weak InputMirrorController *weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        InputMirrorController *strong = weakController;
        if (!strong) return;
        strong.axPollScheduled = NO;
        [strong pollFocusedInput];
    });
}

@implementation InputMirrorController

- (instancetype)init {
    if ((self = [super init])) {
        _defaultsKeyPrefix = @"InputMirror";
        _style = InputMirrorStyleGlass;
        _mirroredText = @"";
        _mirroredSelection = NSMakeRange(0, 0);
        _targetAppName = @"";
        _targetBundleID = @"";
        _manualAXPids = [NSMutableSet set];
        _unsyncedDrafts = [NSMutableDictionary dictionary];
        _confirmedChipSet = [NSMutableSet set];
        _skillMenuItems = @[];
        _skillMenuRowViews = @[];
        _skillMenuCategoryTabViews = @[];
        _activeSkillMenuCategoryKey = @"all";
        _availableSkillMenuCategories = @[@"all"];
        _dismissedSkillTriggerLocation = NSNotFound;
        [self buildPanel];
        [self buildSkillMenuPanel];
        [self applyStyleAppearance];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(screenParametersChanged:)
                                                     name:NSApplicationDidChangeScreenParametersNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [self stop];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self clearTargetElement];
    [self clearDismissedElement];
}

- (BOOL)visible {
    return self.panel.visible;
}

- (BOOL)skillMenuVisible {
    return self.skillMenuPanel.visible;
}

- (BOOL)hasUnsyncedEdits {
    return self.hasLocalEditsPendingSync;
}

- (NSSet<NSString *> *)confirmedChipTokens {
    return [self.confirmedChipSet copy] ?: [NSSet set];
}

#pragma mark - Unsynced Draft Protection

static const NSTimeInterval kMirrorDraftTTL = 7200.0;

- (NSString *)draftKeyForBundleID:(NSString *)bundleID appName:(NSString *)appName pid:(pid_t)pid {
    NSString *ident = bundleID.length ? bundleID.lowercaseString : (appName.lowercaseString ?: @"");
    if (!ident.length) return @"";
    if (pid > 0) {
        return [NSString stringWithFormat:@"%@:%d", ident, (int)pid];
    }
    return ident;
}

- (NSString *)currentDraftKey {
    return [self draftKeyForBundleID:self.targetBundleID appName:self.targetAppName pid:self.targetPID];
}

- (void)saveCurrentDraftIfNeeded {
    if (self.inPreviewSample) return;
    NSString *key = [self currentDraftKey];
    if (!key.length) return;
    NSString *text = self.textView.string ?: @"";
    NSString *base = self.lastSyncedToTargetText ?: @"";
    if (!self.hasLocalEditsPendingSync || text.length == 0 || [text isEqualToString:base]) {
        if (text.length == 0 || [text isEqualToString:base]) {
            [self.unsyncedDrafts removeObjectForKey:key];
        }
        return;
    }
    InputMirrorDraft *draft = [[InputMirrorDraft alloc] init];
    draft.text = text;
    draft.selection = self.textView.selectedRange;
    draft.baseTargetText = base;
    draft.confirmedChips = [self.confirmedChipSet copy];
    draft.savedAt = NSProcessInfo.processInfo.systemUptime;
    self.unsyncedDrafts[key] = draft;
}

- (void)clearDraftForKey:(NSString *)key {
    if (key.length) {
        [self.unsyncedDrafts removeObjectForKey:key];
    }
}

- (InputMirrorDraft * _Nullable)validDraftForKey:(NSString *)key currentTargetText:(NSString *)targetText {
    if (!key.length) return nil;
    InputMirrorDraft *draft = self.unsyncedDrafts[key];
    if (!draft) return nil;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ((now - draft.savedAt) > kMirrorDraftTTL || draft.text.length == 0) {
        [self.unsyncedDrafts removeObjectForKey:key];
        return nil;
    }
    NSString *safeTarget = targetText ?: @"";
    if ([safeTarget isEqualToString:draft.text]) {
        [self.unsyncedDrafts removeObjectForKey:key];
        return nil;
    }
    if (safeTarget.length == 0 || [safeTarget isEqualToString:(draft.baseTargetText ?: @"")]) {
        return draft;
    }
    // User typed brand-new different non-empty content directly in the target app -> respect native input
    [self.unsyncedDrafts removeObjectForKey:key];
    return nil;
}

- (NSString * _Nullable)savedDraftTextForBundleID:(NSString *)bundleID appName:(NSString *)appName pid:(pid_t)pid {
    NSString *key = [self draftKeyForBundleID:bundleID appName:appName pid:pid];
    if (!key.length) return nil;
    InputMirrorDraft *draft = self.unsyncedDrafts[key];
    return draft ? draft.text : nil;
}

- (void)setStyle:(InputMirrorStyle)style {
    if (style < InputMirrorStyleGlass || style > InputMirrorStyleTerminal) style = InputMirrorStyleGlass;
    _style = style;
    [self applyStyleAppearance];
    [self applyFormattedText:self.textView.string ?: @""
                   selection:self.panel.isKeyWindow ? self.textView.selectedRange : self.mirroredSelection
         showMirrorSelection:!self.panel.isKeyWindow
               replaceString:NO];
}

#pragma mark - Style Palette

- (NSColor *)currentTextColor {
    switch (self.style) {
        case InputMirrorStyleObsidian: return [NSColor colorWithSRGBRed:0.95 green:0.96 blue:0.98 alpha:1.0];
        case InputMirrorStylePaper:    return PanelColor(0x27201a, 0xf3ece4, 1.0);
        case InputMirrorStyleTerminal: return [NSColor colorWithSRGBRed:0.86 green:0.97 blue:0.95 alpha:1.0];
        default:                       return PanelColor(0x111827, 0xf9fafb, 1.0);
    }
}

- (NSColor *)currentAccentColor {
    switch (self.style) {
        case InputMirrorStyleObsidian: return [NSColor colorWithSRGBRed:0.51 green:0.55 blue:0.98 alpha:1.0];
        case InputMirrorStylePaper:    return PanelColor(0xb45309, 0xf59e0b, 1.0);
        case InputMirrorStyleTerminal: return [NSColor colorWithSRGBRed:0.18 green:0.86 blue:0.74 alpha:1.0];
        default:                       return PanelColor(0x2563eb, 0x60a5fa, 1.0);
    }
}

- (NSColor *)currentMutedColor {
    switch (self.style) {
        case InputMirrorStyleObsidian: return [NSColor colorWithSRGBRed:0.58 green:0.62 blue:0.72 alpha:1.0];
        case InputMirrorStylePaper:    return PanelColor(0x8c7b6b, 0xa8998a, 1.0);
        case InputMirrorStyleTerminal: return [NSColor colorWithSRGBRed:0.44 green:0.62 blue:0.62 alpha:1.0];
        default:                       return PanelColor(0x6b7280, 0x9ca3af, 1.0);
    }
}

- (NSColor *)currentCodeBgColor {
    switch (self.style) {
        case InputMirrorStyleObsidian: return [NSColor colorWithSRGBRed:0.17 green:0.19 blue:0.26 alpha:0.95];
        case InputMirrorStylePaper:    return PanelColor(0xede5d8, 0x2e2822, 0.95);
        case InputMirrorStyleTerminal: return [NSColor colorWithSRGBRed:0.08 green:0.20 blue:0.22 alpha:0.95];
        default:                       return PanelColor(0xeef2f7, 0x262c38, 0.90);
    }
}

- (NSFont *)currentBodyFont {
    if (self.style == InputMirrorStyleTerminal) {
        return [NSFont monospacedSystemFontOfSize:kMirrorBodyFontSize - 1.0 weight:NSFontWeightRegular];
    }
    return [NSFont systemFontOfSize:kMirrorBodyFontSize weight:NSFontWeightRegular];
}

- (void)applyStyleAppearance {
    if (!self.cardSurface) return;
    switch (self.style) {
        case InputMirrorStyleGlass:
            self.glassView.hidden = NO;
            self.glassView.material = NSVisualEffectMaterialPopover;
            self.cardSurface.fillColor = NSColor.clearColor;
            self.cardSurface.outlineColor = PanelColor(0xd1d5db, 0x4b5563, 0.72);
            self.cardSurface.layer.cornerRadius = 18.0;
            self.cardSurface.layer.borderWidth = 1.0;
            self.dragPill.layer.backgroundColor = PanelColor(0x9ca3af, 0x6b7280, 0.48).CGColor;
            break;
        case InputMirrorStyleObsidian:
            self.glassView.hidden = YES;
            self.cardSurface.fillColor = [NSColor colorWithSRGBRed:0.075 green:0.086 blue:0.114 alpha:0.98];
            self.cardSurface.outlineColor = [NSColor colorWithSRGBRed:0.39 green:0.43 blue:0.88 alpha:0.55];
            self.cardSurface.layer.cornerRadius = 16.0;
            self.cardSurface.layer.borderWidth = 1.2;
            self.dragPill.layer.backgroundColor = [NSColor colorWithSRGBRed:0.51 green:0.55 blue:0.98 alpha:0.35].CGColor;
            break;
        case InputMirrorStylePaper:
            self.glassView.hidden = YES;
            self.cardSurface.fillColor = PanelColor(0xfaf6ef, 0x211d18, 0.98);
            self.cardSurface.outlineColor = PanelColor(0xe3d6c4, 0x463c32, 0.95);
            self.cardSurface.layer.cornerRadius = 16.0;
            self.cardSurface.layer.borderWidth = 1.0;
            self.dragPill.layer.backgroundColor = PanelColor(0xcab9a3, 0x6e5e4e, 0.55).CGColor;
            break;
        case InputMirrorStyleTerminal:
            self.glassView.hidden = YES;
            self.cardSurface.fillColor = [NSColor colorWithSRGBRed:0.045 green:0.075 blue:0.095 alpha:0.97];
            self.cardSurface.outlineColor = [NSColor colorWithSRGBRed:0.16 green:0.82 blue:0.72 alpha:0.65];
            self.cardSurface.layer.cornerRadius = 14.0;
            self.cardSurface.layer.borderWidth = 1.25;
            self.dragPill.layer.backgroundColor = [NSColor colorWithSRGBRed:0.18 green:0.86 blue:0.74 alpha:0.45].CGColor;
            break;
    }
    NSColor *headerMuted = (self.style == InputMirrorStyleGlass) ? NSColor.secondaryLabelColor : [self currentMutedColor];
    self.titleLabel.textColor = headerMuted;
    self.countLabel.textColor = headerMuted;
    self.closeButton.contentTintColor = headerMuted;
    self.textView.mirrorPlaceholder = @"开始输入…";
    self.textView.mirrorPlaceholderColor = (self.style == InputMirrorStyleGlass) ? NSColor.tertiaryLabelColor : [[self currentMutedColor] colorWithAlphaComponent:0.65];
    self.textView.font = [self currentBodyFont];
    self.textView.textColor = [self currentTextColor];
    self.textView.insertionPointColor = [self currentAccentColor];
    self.textView.mirrorCaretColor = [self currentAccentColor];
    self.statusDot.layer.backgroundColor = [self currentAccentColor].CGColor;
    [self.cardSurface setNeedsDisplay:YES];
    [self.textView setNeedsDisplay:YES];
    [self applySkillMenuStyle];
}

#pragma mark - Minimalist UI Construction

- (void)buildPanel {
    NSRect frame = [self loadRestoredFrame];
    self.panel = [[InputMirrorPanel alloc] initWithContentRect:frame
                                                     styleMask:NSWindowStyleMaskBorderless |
                                                               NSWindowStyleMaskNonactivatingPanel |
                                                               NSWindowStyleMaskResizable
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
    self.panel.delegate = self;
    self.panel.becomesKeyOnlyIfNeeded = YES;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.opaque = NO;
    self.panel.hasShadow = YES;
    self.panel.hidesOnDeactivate = NO;
    self.panel.movableByWindowBackground = YES;
    self.panel.releasedWhenClosed = NO;
    self.panel.minSize = NSMakeSize(kMirrorMinWidth, kMirrorMinHeight);
    self.panel.maxSize = NSMakeSize(1200.0, kMirrorMaxHeight);

    PanelSurface *card = [[PanelSurface alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))];
    card.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 18.0;
    card.layer.borderWidth = 1.0;
    card.layer.masksToBounds = YES;
    self.panel.contentView = card;
    self.cardSurface = card;

    // Frosted glass backdrop (used by Glass style)
    NSVisualEffectView *glass = [[NSVisualEffectView alloc] initWithFrame:card.bounds];
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    glass.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    glass.state = NSVisualEffectStateActive;
    glass.material = NSVisualEffectMaterialHUDWindow;
    [card addSubview:glass];
    self.glassView = glass;

    // Ultra-minimal Header bar (34pt): status dot + app icon + subtle app name + centered drag pill + minimal close
    NSView *header = [[NSView alloc] initWithFrame:NSMakeRect(0, NSHeight(frame) - kMirrorHeaderHeight, NSWidth(frame), kMirrorHeaderHeight)];
    header.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [card addSubview:header];

    NSView *pill = [[NSView alloc] initWithFrame:NSMakeRect(floor((NSWidth(frame) - 34.0) * 0.5), kMirrorHeaderHeight - 9.0, 34.0, 3.5)];
    pill.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    pill.wantsLayer = YES;
    pill.layer.cornerRadius = 1.75;
    [header addSubview:pill];
    self.dragPill = pill;

    NSView *dot = [[NSView alloc] initWithFrame:NSMakeRect(18, 12, 7, 7)];
    dot.wantsLayer = YES;
    dot.layer.cornerRadius = 3.5;
    [header addSubview:dot];
    self.statusDot = dot;

    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(31, 8, 16, 16)];
    iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [header addSubview:iconView];
    self.appIconView = iconView;

    NSTextField *title = [NSTextField labelWithString:@"镜像输入"];
    title.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.frame = NSMakeRect(53, 7, MAX(80.0, NSWidth(frame) - 215.0), 18);
    title.autoresizingMask = NSViewWidthSizable;
    [header addSubview:title];
    self.titleLabel = title;

    NSTextField *count = [NSTextField labelWithString:@"0 字 · 1 行"];
    count.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium];
    count.alignment = NSTextAlignmentRight;
    count.drawsBackground = NO;
    count.bezeled = NO;
    count.backgroundColor = NSColor.clearColor;
    count.wantsLayer = YES;
    count.layer.backgroundColor = NSColor.clearColor.CGColor;
    count.frame = NSMakeRect(NSWidth(frame) - 154, 7, 110, 18);
    count.autoresizingMask = NSViewMinXMargin;
    [header addSubview:count];
    self.countLabel = count;

    NSButton *closeBtn = [NSButton buttonWithTitle:@"×" target:self action:@selector(handleCloseButton:)];
    closeBtn.bordered = NO;
    closeBtn.font = [NSFont systemFontOfSize:16.5 weight:NSFontWeightRegular];
    closeBtn.frame = NSMakeRect(NSWidth(frame) - 36, 4, 26, 26);
    closeBtn.autoresizingMask = NSViewMinXMargin;
    closeBtn.toolTip = @"收起（再次点击输入框恢复）";
    [header addSubview:closeBtn];
    self.closeButton = closeBtn;

    // Clean full-bleed scrollable text canvas (no bottom footer bar, no Send button!)
    NSRect scrollFrame = NSMakeRect(14, kMirrorBottomPadding, NSWidth(frame) - 28, NSHeight(frame) - kMirrorHeaderHeight - kMirrorBottomPadding);
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:scrollFrame];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    [card addSubview:scroll];
    self.scrollView = scroll;

    InputMirrorTextView *tv = [[InputMirrorTextView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(scrollFrame), NSHeight(scrollFrame))];
    tv.wantsLayer = YES;
    tv.layer.opaque = NO;
    tv.layer.backgroundColor = NSColor.clearColor.CGColor;
    tv.minSize = NSMakeSize(0, NSHeight(scrollFrame));
    tv.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    tv.verticallyResizable = YES;
    tv.horizontallyResizable = NO;
    tv.autoresizingMask = NSViewWidthSizable;
    tv.textContainer.containerSize = NSMakeSize(NSWidth(scrollFrame), FLT_MAX);
    tv.textContainer.widthTracksTextView = YES;
    tv.textContainerInset = NSMakeSize(4.0, 6.0);
    tv.drawsBackground = NO;
    tv.richText = NO;
    tv.allowsUndo = YES;
    tv.automaticQuoteSubstitutionEnabled = NO;
    tv.automaticDashSubstitutionEnabled = NO;
    tv.automaticTextReplacementEnabled = NO;
    tv.editable = YES;
    tv.selectable = YES;
    tv.delegate = self;
    tv.mirrorCaretVisible = YES;
    tv.mirrorCaretBlinkOn = YES;

    __weak InputMirrorController *weakSelf = self;
    tv.onSubmit = ^{
        [weakSelf syncAndSend];
    };
    tv.onCancelEdit = ^{
        [weakSelf dismissTemporarily];
    };
    tv.onCompositionChanged = ^{
        [weakSelf updatePlaceholderVisibility];
    };
    tv.onSkillMenuKeyDown = ^BOOL(NSEvent *event) {
        return [weakSelf handleSkillMenuKeyDown:event];
    };
    tv.onAtomicChipBackspace = ^BOOL{
        return [weakSelf handleAtomicChipBackspace];
    };
    tv.onNativeSlashHandoffShortcut = ^{
        [weakSelf handoffToNativeSlashMenu];
    };
    tv.onNativeMentionHandoffShortcut = ^{
        [weakSelf handoffToNativeMentionMenu];
    };

    scroll.documentView = tv;
    self.textView = tv;
}

- (void)updatePlaceholderVisibility {
    [self.textView setNeedsDisplay:YES];
    if (self.panel.visible) {
        [self refreshSkillMenuForCurrentText];
    }
}

- (void)adjustHeightToFitContentAnimated:(BOOL)animated {
    if (!self.panel || !self.textView.layoutManager || !self.textView.textContainer) return;
    [self.textView.layoutManager ensureLayoutForTextContainer:self.textView.textContainer];
    NSRect used = [self.textView.layoutManager usedRectForTextContainer:self.textView.textContainer];
    CGFloat targetH = InputMirrorTargetHeightForContentHeight(used.size.height);
    NSRect current = self.panel.frame;
    if (fabs(current.size.height - targetH) < 2.0) return;

    // Anchor top edge so the input grows naturally downward (clamped safely to visible screen)
    CGFloat topY = NSMaxY(current);
    NSRect nextFrame = NSMakeRect(current.origin.x, topY - targetH, current.size.width, targetH);
    NSScreen *screen = self.panel.screen ?: NSScreen.mainScreen;
    if (screen) {
        nextFrame = ClampRectToVisibleFrame(nextFrame, screen.visibleFrame);
    }
    self.suppressFrameSave = YES;
    [self.panel setFrame:nextFrame display:YES animate:animated];
    self.suppressFrameSave = NO;
    if (self.skillMenuPanel.visible) {
        [self repositionSkillMenuPanel];
    }
}

#pragma mark - Position Persistence

- (NSString *)frameDefaultsKey {
    return [self.defaultsKeyPrefix stringByAppendingString:@"Frame"];
}

- (NSString *)screenDefaultsKey {
    return [self.defaultsKeyPrefix stringByAppendingString:@"ScreenID"];
}

- (NSRect)loadRestoredFrame {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *savedStr = [defaults stringForKey:[self frameDefaultsKey]];
    NSRect savedRect = savedStr.length ? NSRectFromString(savedStr) : NSZeroRect;
    CGDirectDisplayID savedScreenID = (CGDirectDisplayID)[defaults integerForKey:[self screenDefaultsKey]];
    return InputMirrorRestoredFrame(savedRect, savedScreenID, NSScreen.screens, NSScreen.mainScreen);
}

- (void)saveCurrentFrame {
    if (self.suppressFrameSave || !self.panel) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:NSStringFromRect(self.panel.frame) forKey:[self frameDefaultsKey]];
    NSScreen *screen = self.panel.screen ?: NSScreen.mainScreen;
    CGDirectDisplayID displayID = DisplayIDForScreen(screen);
    if (displayID != 0) {
        [defaults setInteger:(NSInteger)displayID forKey:[self screenDefaultsKey]];
    }
}

- (void)resetSavedPosition {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:[self frameDefaultsKey]];
    [defaults removeObjectForKey:[self screenDefaultsKey]];
    self.suppressFrameSave = YES;
    [self.panel setFrame:DefaultFrameForScreen(NSScreen.mainScreen) display:YES animate:YES];
    self.suppressFrameSave = NO;
}

- (void)screenParametersChanged:(NSNotification *)note {
    NSRect restored = [self loadRestoredFrame];
    self.suppressFrameSave = YES;
    [self.panel setFrame:restored display:YES];
    self.suppressFrameSave = NO;
}

- (void)windowDidMove:(NSNotification *)notification {
    [self saveCurrentFrame];
    if (self.skillMenuPanel.visible) {
        [self repositionSkillMenuPanel];
    }
}

- (void)windowDidResize:(NSNotification *)notification {
    [self saveCurrentFrame];
    if (self.skillMenuPanel.visible) {
        [self repositionSkillMenuPanel];
    }
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    // Sync cursor position into textView immediately when user clicks into the floating mirror
    NSRange safeSel = self.mirroredSelection;
    NSUInteger len = self.textView.string.length;
    if (safeSel.location > len) safeSel.location = len;
    if (NSMaxRange(safeSel) > len) safeSel.length = len - safeSel.location;
    if (self.textView.selectedRange.location == 0 && self.textView.selectedRange.length == 0 && len > 0 && safeSel.location > 0) {
        [self.textView setSelectedRange:safeSel];
    }
    [self.textView setNeedsDisplay:YES];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    [self hideSkillMenu];
    [self.liveSyncTimer invalidate];
    self.liveSyncTimer = nil;
    // Never forcibly reactivate targetApp or fire blind Cmd+A/Delete/keystrokes on resign
    // (which breaks Space switching, steals focus from other apps, and races with pollFocusedInput!).
    // Instead, preserve the unsynced draft safely and attempt a silent, non-activating AXValue sync.
    if (!self.suppressResignSync && !self.syncInFlight && self.hasLocalEditsPendingSync) {
        [self saveCurrentDraftIfNeeded];
        if (self.targetElement && self.targetPID > 0) {
            [self pushLiveEditsToTarget];
        }
    }
    [self.textView setNeedsDisplay:YES];
}

#pragma mark - Enable / Lifecycle

- (void)setEnabled:(BOOL)enabled {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (enabled) {
        if (!self.previewMode) [self startMonitoring];
    } else {
        [self stopMonitoring];
        self.inPreviewSample = NO;
        [self hidePanel];
    }
}

- (void)stop {
    [self stopMonitoring];
    self.inPreviewSample = NO;
    [self hidePanel];
}

- (void)startMonitoring {
    [self stopMonitoring];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
                                                       selector:@selector(activeAppDidChange:)
                                                           name:NSWorkspaceDidActivateApplicationNotification
                                                         object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
                                                       selector:@selector(activeSpaceDidChange:)
                                                           name:NSWorkspaceActiveSpaceDidChangeNotification
                                                         object:nil];

    __weak InputMirrorController *weakSelf = self;
    self.globalMouseMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^(NSEvent *event) {
        [weakSelf handleExternalMouseClick];
    }];
    self.globalKeyMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^(NSEvent *event) {
        unsigned short code = event.keyCode;
        if (code == kVK_Return || code == kVK_ANSI_KeypadEnter) {
            NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
            BOOL hasShift = (mods & NSEventModifierFlagShift) != 0;
            BOOL hasOther = (mods & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl)) != 0;
            if (!hasShift && !hasOther) {
                weakSelf.lastExternalReturnTime = NSProcessInfo.processInfo.systemUptime;
            }
        } else if (code == kVK_Delete || code == kVK_ForwardDelete) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.025 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf pollFocusedInput];
            });
        }
    }];

    self.pollTimer = [NSTimer timerWithTimeInterval:kMirrorPollInterval repeats:YES block:^(NSTimer *timer) {
        [weakSelf pollFocusedInput];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
    [self attachObserverForFrontmostApp];
    [self pollFocusedInput];
}

- (void)stopMonitoring {
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self
                                                              name:NSWorkspaceDidActivateApplicationNotification
                                                            object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self
                                                              name:NSWorkspaceActiveSpaceDidChangeNotification
                                                            object:nil];
    if (self.globalMouseMonitor) {
        [NSEvent removeMonitor:self.globalMouseMonitor];
        self.globalMouseMonitor = nil;
    }
    if (self.globalKeyMonitor) {
        [NSEvent removeMonitor:self.globalKeyMonitor];
        self.globalKeyMonitor = nil;
    }
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [self.liveSyncTimer invalidate];
    self.liveSyncTimer = nil;
    [self detachAXObserver];
    [self stopCaretTimer];
}

- (void)suppressAutoPopupUntilNextClick {
    [self.liveSyncTimer invalidate];
    self.liveSyncTimer = nil;
    [self saveCurrentDraftIfNeeded];
    self.awaitingUserClickAfterJump = YES;
    self.inPreviewSample = NO;
    self.suppressResignSync = YES;
    [self hidePanel];
    self.suppressResignSync = NO;
}

- (void)handleExternalMouseClick {
    if (!self.enabled) return;
    BOOL shouldRepoll = NO;
    if (self.sendCloseCooldownUntil > 0) {
        self.sendCloseCooldownUntil = 0;
        shouldRepoll = YES;
    }
    if (self.awaitingUserClickAfterJump) {
        self.awaitingUserClickAfterJump = NO;
        shouldRepoll = YES;
    }
    if (self.dismissedElement != NULL) {
        [self clearDismissedElement];
        shouldRepoll = YES;
    }
    if (shouldRepoll) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self pollFocusedInput];
        });
    }
}

- (void)startCaretTimer {
    if (self.caretTimer) return;
    self.textView.mirrorCaretBlinkOn = YES;
    __weak InputMirrorController *weakSelf = self;
    self.caretTimer = [NSTimer timerWithTimeInterval:0.53 repeats:YES block:^(NSTimer *timer) {
        InputMirrorController *owner = weakSelf;
        if (!owner || !owner.panel.visible || owner.panel.isKeyWindow) return;
        owner.textView.mirrorCaretBlinkOn = !owner.textView.mirrorCaretBlinkOn;
        [owner.textView setNeedsDisplay:YES];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.caretTimer forMode:NSRunLoopCommonModes];
}

- (void)stopCaretTimer {
    [self.caretTimer invalidate];
    self.caretTimer = nil;
}

#pragma mark - AX Observer & Polling

- (void)clearTargetElement {
    if (_targetElement) {
        CFRelease(_targetElement);
        _targetElement = NULL;
    }
}

- (void)clearDismissedElement {
    if (_dismissedElement) {
        CFRelease(_dismissedElement);
        _dismissedElement = NULL;
    }
    _dismissedTextSnapshot = nil;
}

- (void)detachAXObserver {
    if (_axObserver) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(_axObserver), kCFRunLoopCommonModes);
        CFRelease(_axObserver);
        _axObserver = NULL;
    }
    _observedPID = 0;
}

- (void)activeAppDidChange:(NSNotification *)note {
    [self saveCurrentDraftIfNeeded];
    [self clearDismissedElement];
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    pid_t myPid = NSProcessInfo.processInfo.processIdentifier;
    if (front && front.processIdentifier != myPid) {
        BOOL supported = InputMirrorIsSupportedAIApp(front.bundleIdentifier, front.localizedName) &&
                         !InputMirrorIsAppExcluded(front.bundleIdentifier, front.localizedName, self.excludeIDEs, self.excludedAppTokens);
        if (!supported) {
            if (!self.inPreviewSample && self.panel.visible) {
                self.suppressResignSync = YES;
                [self clearTargetElement];
                [self hidePanel];
                self.suppressResignSync = NO;
            }
            return;
        }
        if (self.targetPID > 0 && front.processIdentifier != self.targetPID && !self.inPreviewSample && self.panel.visible) {
            self.suppressResignSync = YES;
            [self clearTargetElement];
            [self hidePanel];
            self.suppressResignSync = NO;
        }
    }
    [self attachObserverForFrontmostApp];
    [self pollFocusedInput];
}

- (void)activeSpaceDidChange:(NSNotification *)note {
    [self handleActiveSpaceChange];
}

- (void)handleActiveSpaceChange {
    if (self.inPreviewSample) return;
    [self.liveSyncTimer invalidate];
    self.liveSyncTimer = nil;
    [self saveCurrentDraftIfNeeded];
    if (self.panel.visible) {
        self.suppressResignSync = YES;
        [self clearTargetElement];
        [self hidePanel];
        self.suppressResignSync = NO;
    }
    if (!self.enabled || self.previewMode) return;
    __weak InputMirrorController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf pollFocusedInput];
    });
}

- (BOOL)reconcileExternalFocusText:(NSString *)text
                         selection:(NSRange)selection
                          bundleID:(NSString *)bundleID
                           appName:(NSString *)appName
                               pid:(pid_t)pid
                           appIcon:(NSImage *)appIcon
                        sameTarget:(BOOL)sameTarget {
    NSString *safeText = text ?: @"";
    NSString *draftKey = [self draftKeyForBundleID:bundleID appName:appName pid:pid];
    InputMirrorDraft *draft = [self validDraftForKey:draftKey currentTargetText:safeText];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;

    // Auto-close after successful send in external app:
    // NEVER fire when we have unsynced local edits or a saved draft, and only when the target app
    // actually held synced text before suddenly emptying.
    NSString *trimmed = [safeText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *syncedSnapshot = self.lastSyncedToTargetText ?: @"";
    BOOL hasActiveUnsynced = self.hasLocalEditsPendingSync || (draft != nil);
    BOOL likelySent = (syncedSnapshot.length >= 2) || ((now - self.lastExternalReturnTime) < 1.5);
    if (sameTarget && self.panel.visible && !hasActiveUnsynced && syncedSnapshot.length > 0 && trimmed.length == 0 && likelySent) {
        self.mirroredText = @"";
        self.lastSyncedToTargetText = @"";
        [self clearDraftForKey:draftKey];
        return YES;
    }

    if (!sameTarget && self.targetPID > 0 && self.targetPID != pid) {
        [self saveCurrentDraftIfNeeded];
    }

    self.inPreviewSample = NO;
    self.targetBundleID = bundleID ?: @"";
    self.targetPID = pid;
    NSString *displayName = appName.length ? appName : @"输入中";
    if ([self.targetBundleID.lowercaseString hasPrefix:@"com.openai.codex"] &&
        [displayName.lowercaseString isEqualToString:@"chatgpt"]) {
        displayName = @"Codex";
    }

    if (draft != nil) {
        [self.confirmedChipSet removeAllObjects];
        if (draft.confirmedChips.count) {
            [self.confirmedChipSet unionSet:draft.confirmedChips];
        }
        [self updateMirroredText:draft.text
                       selection:draft.selection
                         appName:displayName
                         appIcon:appIcon];
        self.lastSyncedToTargetText = safeText;
        self.hasLocalEditsPendingSync = YES;
        return NO;
    }

    if (sameTarget && self.hasLocalEditsPendingSync && [safeText isEqualToString:syncedSnapshot]) {
        self.targetAppName = displayName;
        self.titleLabel.stringValue = displayName;
        self.appIconView.image = appIcon;
        [self saveCurrentDraftIfNeeded];
        return NO;
    }

    if (!sameTarget || safeText.length == 0) {
        [self.confirmedChipSet removeAllObjects];
    }
    [self updateMirroredText:safeText
                   selection:selection
                     appName:displayName
                     appIcon:appIcon];
    self.lastSyncedToTargetText = safeText;
    self.hasLocalEditsPendingSync = NO;
    return NO;
}

- (void)attachObserverForFrontmostApp {
    if (!AXIsProcessTrusted()) return;
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    pid_t myPid = NSProcessInfo.processInfo.processIdentifier;
    if (!front || front.processIdentifier == myPid) return;
    if (!InputMirrorIsSupportedAIApp(front.bundleIdentifier, front.localizedName) ||
        InputMirrorIsAppExcluded(front.bundleIdentifier, front.localizedName, self.excludeIDEs, self.excludedAppTokens)) return;
    pid_t pid = front.processIdentifier;
    if (pid == self.observedPID && self.axObserver) return;

    [self detachAXObserver];
    AXUIElementRef appElem = AXUIElementCreateApplication(pid);
    if (!appElem) return;

    if (![self.manualAXPids containsObject:@(pid)]) {
        AXUIElementSetAttributeValue(appElem, CFSTR("AXManualAccessibility"), kCFBooleanTrue);
        [self.manualAXPids addObject:@(pid)];
    }

    AXObserverRef observer = NULL;
    if (AXObserverCreate(pid, IMAxObserverCallback, &observer) == kAXErrorSuccess && observer) {
        AXObserverAddNotification(observer, appElem, kAXFocusedUIElementChangedNotification, (__bridge void *)self);
        AXObserverAddNotification(observer, appElem, kAXValueChangedNotification, (__bridge void *)self);
        AXObserverAddNotification(observer, appElem, kAXSelectedTextChangedNotification, (__bridge void *)self);
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes);
        self.axObserver = observer;
        self.observedPID = pid;
    }
    CFRelease(appElem);
}

- (void)pollFocusedInput {
    if (!self.enabled || self.previewMode) return;
    if (self.awaitingUserClickAfterJump) return;
    if (self.syncInFlight) return;
    if (self.panel.isKeyWindow) return;
    if (!AXIsProcessTrusted()) return;

    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    pid_t myPid = NSProcessInfo.processInfo.processIdentifier;
    if (!front) return;
    if (front.processIdentifier == myPid) return;

    // Only mirror inputs belonging to supported (and non-excluded) AI apps; hide immediately when switching to other apps
    if (!InputMirrorIsSupportedAIApp(front.bundleIdentifier, front.localizedName) ||
        InputMirrorIsAppExcluded(front.bundleIdentifier, front.localizedName, self.excludeIDEs, self.excludedAppTokens)) {
        if (!self.inPreviewSample && self.panel.visible) {
            [self saveCurrentDraftIfNeeded];
            self.suppressResignSync = YES;
            [self clearTargetElement];
            [self hidePanel];
            self.suppressResignSync = NO;
        }
        return;
    }

    if (front.processIdentifier != self.observedPID) {
        [self attachObserverForFrontmostApp];
    }

    AXUIElementRef appElem = AXUIElementCreateApplication(front.processIdentifier);
    if (!appElem) return;
    id focusedObj = IMAxCopyAttribute(appElem, kAXFocusedUIElementAttribute);
    CFRelease(appElem);

    AXUIElementRef focused = focusedObj ? (__bridge AXUIElementRef)focusedObj : NULL;
    if (focused && IMAxIsEditableElement(focused)) {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (now < self.sendCloseCooldownUntil || now < self.postSyncGraceUntil) {
            return;
        }
        BOOL usedStructuredList = NO;
        NSString *text = IMAxReadTextValue(focused, &usedStructuredList);
        BOOL sameTarget = (self.targetElement != NULL && CFEqual(self.targetElement, focused));

        if (self.dismissedElement && CFEqual(self.dismissedElement, focused)) {
            if ([text isEqualToString:(self.dismissedTextSnapshot ?: @"")] || text.length == 0) {
                return;
            }
            [self clearDismissedElement];
        }

        // Accurate cursor alignment:
        // 1. If structured AXList extraction was used, raw AXSelectedTextRange indices belong to the unformatted tree -> align to end.
        // 2. If Electron reports stale {0, 0} while text was just appended at the end, align to end.
        NSString *prevText = sameTarget ? (self.mirroredText ?: @"") : @"";
        NSRange sel = NSMakeRange(text.length, 0);
        if (!usedStructuredList) {
            NSRange axSel = NSMakeRange(text.length, 0);
            if (IMAxReadSelectedRange(focused, &axSel)) {
                BOOL appendedAtEnd = (text.length > prevText.length && [text hasPrefix:prevText]);
                if (appendedAtEnd && axSel.location == 0 && axSel.length == 0) {
                    sel = NSMakeRange(text.length, 0);
                } else {
                    sel = axSel;
                }
            }
        }
        if (sel.location > text.length) sel.location = text.length;
        if (sel.location + sel.length > text.length) sel.length = text.length - sel.location;

        BOOL detectedSent = [self reconcileExternalFocusText:text
                                                   selection:sel
                                                    bundleID:front.bundleIdentifier ?: @""
                                                     appName:front.localizedName ?: @"输入中"
                                                         pid:front.processIdentifier
                                                     appIcon:front.icon
                                                  sameTarget:sameTarget];
        if (detectedSent) {
            self.dismissedTextSnapshot = @"";
            [self clearDismissedElement];
            self.dismissedElement = (AXUIElementRef)CFRetain(focused);
            self.suppressResignSync = YES;
            [self hidePanel];
            self.suppressResignSync = NO;
            return;
        }

        self.inPreviewSample = NO;
        self.lastInputSeenTime = now;

        [self clearTargetElement];
        self.targetElement = (AXUIElementRef)CFRetain(focused);

        // Focus the non-activating mirror panel WITHOUT activating NSApp so:
        // 1) Typing & Chinese IME stay right in front of the user on our mirror panel, AND
        // 2) The AI app stays active in the background so live CGEvent/AX sync updates it in real time!
        [self showPanelAndFocus:YES];
        return;
    }

    if (self.inPreviewSample) return;
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - self.lastInputSeenTime;
    if (self.panel.visible && elapsed >= kMirrorHideGraceInterval) {
        [self saveCurrentDraftIfNeeded];
        self.suppressResignSync = YES;
        [self clearTargetElement];
        [self hidePanel];
        self.suppressResignSync = NO;
    }
}

#pragma mark - Presentation & Formatted Text Rendering

- (void)showPanelAndFocus:(BOOL)shouldFocus {
    BOOL wasVisible = self.panel.visible;
    if (!wasVisible) {
        NSRect restored = [self loadRestoredFrame];
        self.suppressFrameSave = YES;
        [self.panel setFrame:restored display:NO];
        self.suppressFrameSave = NO;
        [self adjustHeightToFitContentAnimated:NO];
        if (shouldFocus && !self.previewMode) {
            [self.panel makeKeyAndOrderFront:nil];
            [self.panel makeFirstResponder:self.textView];
            NSRange safeSel = self.mirroredSelection;
            NSUInteger len = self.textView.string.length;
            if (safeSel.location > len) safeSel.location = len;
            if (NSMaxRange(safeSel) > len) safeSel.length = len - safeSel.location;
            [self.textView setSelectedRange:safeSel];
        } else {
            [self.panel orderFrontRegardless];
        }
    }
    [self startCaretTimer];
}

- (void)showPanel {
    [self showPanelAndFocus:NO];
}

- (void)hidePanel {
    [self hideSkillMenu];
    [self stopCaretTimer];
    if (self.panel.visible) {
        [self.panel orderOut:nil];
    }
}

- (void)showPreviewSample {
    self.inPreviewSample = YES;
    NSString *sample = @"1. 极简跨屏镜像输入，支持 4 款设计感样式切换\n2. 多行内容自动增高，支持 `⌘A` 全选 / 复制 / 粘贴 / 撤销\n- 支持多级无序列表、`行内代码` 与 **加粗**\n  - 二级列表自动层级缩进与悬挂对齐\n    ◦ 三级列表兼容 `-` / `*` / `+` / `•` / `◦` / `▪`\n- Enter 发送自动收起 · Shift+Enter 换行";
    [self updateMirroredText:sample
                   selection:NSMakeRange(sample.length, 0)
                     appName:@"预览示例"
                     appIcon:[NSImage imageWithSystemSymbolName:@"keyboard" accessibilityDescription:@"输入镜像"]];
    [self showPanel];
}

- (void)applyFormattedText:(NSString *)text selection:(NSRange)selection showMirrorSelection:(BOOL)showMirrorSelection replaceString:(BOOL)replaceString {
    self.applyingFormattedText = YES;
    NSAttributedString *formatted = InputMirrorFormatAttributedText(
        text,
        [self currentBodyFont],
        [self currentTextColor],
        [self currentAccentColor],
        [self currentMutedColor],
        [self currentCodeBgColor],
        selection,
        showMirrorSelection
    );
    NSTextStorage *storage = self.textView.textStorage;
    [storage beginEditing];
    if (replaceString || ![storage.string isEqualToString:formatted.string]) {
        [storage setAttributedString:formatted];
    } else if (formatted.length > 0) {
        NSRange fullRange = NSMakeRange(0, formatted.length);
        [formatted enumerateAttributesInRange:fullRange options:0 usingBlock:^(NSDictionary<NSAttributedStringKey,id> *attrs, NSRange range, BOOL *stop) {
            [storage setAttributes:attrs range:range];
        }];
    }
    [storage endEditing];
    if (self.textView.layoutManager && self.textView.textContainer) {
        [self.textView.layoutManager ensureLayoutForTextContainer:self.textView.textContainer];
    }
    [self.textView setNeedsDisplay:YES];
    [self.scrollView.contentView setNeedsDisplay:YES];
    [self.scrollView setNeedsDisplay:YES];
    [self.cardSurface setNeedsDisplay:YES];
    [self.panel displayIfNeeded];
    self.applyingFormattedText = NO;
}

- (void)updateMirroredText:(NSString *)text
                 selection:(NSRange)selection
                   appName:(NSString *)appName
                   appIcon:(NSImage *)appIcon {
    NSString *safeText = text ?: @"";
    if (selection.location > safeText.length) selection.location = safeText.length;
    if (selection.location + selection.length > safeText.length) selection.length = safeText.length - selection.location;

    BOOL textChanged = ![self.mirroredText isEqualToString:safeText];
    BOOL selChanged = !NSEqualRanges(self.mirroredSelection, selection);
    self.mirroredText = safeText;
    self.mirroredSelection = selection;
    self.targetAppName = appName ?: @"";

    self.titleLabel.stringValue = appName.length ? appName : @"镜像输入";
    self.appIconView.image = appIcon;
    self.countLabel.stringValue = InputMirrorSummaryText(safeText);

    if (textChanged || selChanged) {
        if (textChanged) {
            self.dismissedSkillTriggerLocation = NSNotFound;
        }
        [self applyFormattedText:safeText selection:selection showMirrorSelection:!self.panel.isKeyWindow replaceString:YES];
        self.textView.mirrorSelectionRange = selection;
        self.textView.mirrorCaretBlinkOn = YES;
        // Keep NSTextView's own selectedRange aligned with the mirrored focus position!
        [self.textView setSelectedRange:selection];
        [self.textView scrollRangeToVisible:selection];
        [self.textView setNeedsDisplay:YES];
        if (textChanged) {
            [self adjustHeightToFitContentAnimated:self.panel.visible && !self.previewMode];
        }
    }
    [self updatePlaceholderVisibility];
}

#pragma mark - Direct Editing, Live Sync & Send-to-Close

- (void)textDidChange:(NSNotification *)notification {
    if (self.applyingFormattedText) return;
    NSString *current = self.textView.string ?: @"";
    self.mirroredText = current;
    self.mirroredSelection = self.textView.selectedRange;
    self.countLabel.stringValue = InputMirrorSummaryText(current);
    [self updatePlaceholderVisibility];

    if (!self.textView.hasMarkedText) {
        NSRange savedSel = self.textView.selectedRange;
        [self applyFormattedText:current selection:savedSel showMirrorSelection:NO replaceString:NO];
        if (NSMaxRange(savedSel) <= self.textView.string.length) {
            [self.textView setSelectedRange:savedSel];
        }
    }
    [self adjustHeightToFitContentAnimated:NO];
    [self refreshSkillMenuForCurrentText];

    self.hasLocalEditsPendingSync = YES;
    [self.liveSyncTimer invalidate];
    self.liveSyncTimer = nil;
    if (!self.textView.hasMarkedText) {
        [self saveCurrentDraftIfNeeded];
        __weak InputMirrorController *weakSelf = self;
        self.liveSyncTimer = [NSTimer scheduledTimerWithTimeInterval:0.04 repeats:NO block:^(NSTimer *timer) {
            [weakSelf pushLiveEditsToTarget];
        }];
    }
}

- (void)textViewDidChangeSelection:(NSNotification *)notification {
    if (self.applyingFormattedText) return;
    if (self.skillMenuPanel.visible || self.dismissedSkillTriggerLocation != NSNotFound) {
        [self refreshSkillMenuForCurrentText];
    }
}

#pragma mark - Skill Autocomplete Popover, Category Tabs, Atomic Chips & Native Segment Replay

static const CGFloat kSkillMenuCategoryBarHeight = 32.0;
static const CGFloat kSkillMenuRowHeight = 42.0;
static const CGFloat kSkillMenuFooterHeight = 32.0;
static const NSUInteger kSkillMenuMaxVisibleRows = 6;

static NSString *IMCategoryDisplayName(NSString *categoryKey, NSString *family) {
    if ([categoryKey isEqualToString:@"all"]) return @"全部";
    if ([categoryKey isEqualToString:@"files"]) return @"文件";
    if ([categoryKey isEqualToString:@"commands"]) return @"命令";
    if ([categoryKey isEqualToString:@"skills"]) return [family isEqualToString:@"antigravity"] ? @"工作流·技能" : @"技能";
    if ([categoryKey isEqualToString:@"chats"]) return @"对话";
    if ([categoryKey isEqualToString:@"mcp"]) return [family isEqualToString:@"codex"] ? @"MCP·智能体" : @"规则·MCP";
    if ([categoryKey isEqualToString:@"context"]) return @"上下文";
    return categoryKey ?: @"其他";
}

- (void)buildSkillMenuPanel {
    NSRect frame = NSMakeRect(0, 0, 460.0, 220.0);
    InputMirrorSkillMenuPanel *sp = [[InputMirrorSkillMenuPanel alloc] initWithContentRect:frame
                                                                                 styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                                                   backing:NSBackingStoreBuffered
                                                                                     defer:NO];
    sp.level = NSFloatingWindowLevel + 1;
    sp.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    sp.backgroundColor = NSColor.clearColor;
    sp.opaque = NO;
    sp.hasShadow = YES;
    sp.hidesOnDeactivate = NO;
    sp.releasedWhenClosed = NO;

    PanelSurface *card = [[PanelSurface alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))];
    card.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 14.0;
    card.layer.borderWidth = 1.0;
    card.layer.masksToBounds = YES;
    sp.contentView = card;
    self.skillMenuCard = card;

    NSVisualEffectView *glass = [[NSVisualEffectView alloc] initWithFrame:card.bounds];
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    glass.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    glass.state = NSVisualEffectStateActive;
    glass.material = NSVisualEffectMaterialPopover;
    [card addSubview:glass];
    self.skillMenuGlass = glass;

    NSView *catBar = [[NSView alloc] initWithFrame:NSMakeRect(0, NSHeight(frame) - kSkillMenuCategoryBarHeight, NSWidth(frame), kSkillMenuCategoryBarHeight)];
    catBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [card addSubview:catBar];
    self.skillMenuCategoryBar = catBar;

    NSView *catDiv = [[NSView alloc] initWithFrame:NSMakeRect(10.0, NSHeight(frame) - kSkillMenuCategoryBarHeight - 1.0, NSWidth(frame) - 20.0, 1.0)];
    catDiv.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    catDiv.wantsLayer = YES;
    [card addSubview:catDiv];
    self.skillMenuCategoryDivider = catDiv;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, kSkillMenuFooterHeight + 1.0, NSWidth(frame), NSHeight(frame) - kSkillMenuFooterHeight - kSkillMenuCategoryBarHeight - 2.0)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    [card addSubview:scroll];
    self.skillMenuScroll = scroll;

    NSView *listContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), 10.0)];
    scroll.documentView = listContainer;
    self.skillMenuListContainer = listContainer;

    NSView *divider = [[NSView alloc] initWithFrame:NSMakeRect(10.0, kSkillMenuFooterHeight, NSWidth(frame) - 20.0, 1.0)];
    divider.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    divider.wantsLayer = YES;
    [card addSubview:divider];
    self.skillMenuFooterDivider = divider;

    InputMirrorSkillRowView *footerRow = [[InputMirrorSkillRowView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), kSkillMenuFooterHeight)];
    footerRow.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    __weak InputMirrorController *weakSelf = self;
    footerRow.onHover = ^(NSInteger idx) {
        [weakSelf selectSkillMenuRow:idx scrollToVisible:NO];
    };
    footerRow.onClick = ^(NSInteger idx) {
        [weakSelf confirmSkillMenuItemAtIndex:idx];
    };
    [card addSubview:footerRow];
    self.skillMenuFooterRow = footerRow;

    NSTextField *footerTitle = [NSTextField labelWithString:@"在原应用原生菜单中打开…"];
    footerTitle.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    footerTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    footerTitle.frame = NSMakeRect(14.0, 7.0, NSWidth(frame) - 168.0, 18.0);
    footerTitle.autoresizingMask = NSViewWidthSizable;
    [footerRow addSubview:footerTitle];
    self.skillMenuFooterTitle = footerTitle;

    NSTextField *footerHint = [NSTextField labelWithString:@"↵ 确认 · ⇧Tab 分类"];
    footerHint.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightMedium];
    footerHint.alignment = NSTextAlignmentRight;
    footerHint.frame = NSMakeRect(NSWidth(frame) - 152.0, 7.0, 138.0, 18.0);
    footerHint.autoresizingMask = NSViewMinXMargin;
    [footerRow addSubview:footerHint];
    self.skillMenuFooterHint = footerHint;

    self.skillMenuPanel = sp;
}

- (void)applySkillMenuStyle {
    if (!self.skillMenuCard) return;
    switch (self.style) {
        case InputMirrorStyleGlass:
            self.skillMenuGlass.hidden = NO;
            self.skillMenuGlass.material = NSVisualEffectMaterialPopover;
            self.skillMenuCard.fillColor = NSColor.clearColor;
            self.skillMenuCard.outlineColor = PanelColor(0xd1d5db, 0x4b5563, 0.72);
            self.skillMenuCard.layer.cornerRadius = 14.0;
            break;
        case InputMirrorStyleObsidian:
            self.skillMenuGlass.hidden = YES;
            self.skillMenuCard.fillColor = [NSColor colorWithSRGBRed:0.075 green:0.086 blue:0.114 alpha:0.98];
            self.skillMenuCard.outlineColor = [NSColor colorWithSRGBRed:0.39 green:0.43 blue:0.88 alpha:0.55];
            self.skillMenuCard.layer.cornerRadius = 14.0;
            break;
        case InputMirrorStylePaper:
            self.skillMenuGlass.hidden = YES;
            self.skillMenuCard.fillColor = PanelColor(0xfaf6ef, 0x211d18, 0.98);
            self.skillMenuCard.outlineColor = PanelColor(0xe3d6c4, 0x463c32, 0.95);
            self.skillMenuCard.layer.cornerRadius = 14.0;
            break;
        case InputMirrorStyleTerminal:
            self.skillMenuGlass.hidden = YES;
            self.skillMenuCard.fillColor = [NSColor colorWithSRGBRed:0.045 green:0.075 blue:0.095 alpha:0.98];
            self.skillMenuCard.outlineColor = [NSColor colorWithSRGBRed:0.16 green:0.82 blue:0.72 alpha:0.65];
            self.skillMenuCard.layer.cornerRadius = 12.0;
            break;
    }
    NSColor *accent = [self currentAccentColor];
    NSColor *muted = (self.style == InputMirrorStyleGlass) ? NSColor.secondaryLabelColor : [self currentMutedColor];
    self.skillMenuCategoryDivider.layer.backgroundColor = [muted colorWithAlphaComponent:0.18].CGColor;
    self.skillMenuFooterDivider.layer.backgroundColor = [muted colorWithAlphaComponent:0.22].CGColor;
    self.skillMenuFooterTitle.textColor = [self currentTextColor];
    self.skillMenuFooterHint.textColor = muted;
    self.skillMenuFooterRow.selectionColor = [accent colorWithAlphaComponent:0.16];
    for (InputMirrorCategoryTabView *tab in self.skillMenuCategoryTabViews) {
        tab.accentColor = accent;
        tab.mutedColor = muted;
        [tab setNeedsDisplay:YES];
    }
    for (InputMirrorSkillRowView *row in self.skillMenuRowViews) {
        row.selectionColor = [accent colorWithAlphaComponent:0.16];
        [row setNeedsDisplay:YES];
    }
    [self.skillMenuCard setNeedsDisplay:YES];
}

- (NSArray<InputMirrorSkillItem *> *)slashCommandsForActiveApp {
    if (self.overrideSlashCommandsForTesting != nil) {
        return self.overrideSlashCommandsForTesting;
    }
    NSString *family = IMSkillAppFamilyKey(self.targetBundleID, self.targetAppName);
    if (self.cachedSlashCommands && [self.cachedSlashCommandsFamily isEqualToString:family]) {
        return self.cachedSlashCommands;
    }
    NSArray<InputMirrorSkillItem *> *loaded = InputMirrorLoadSlashCommandsForApp(self.targetBundleID, self.targetAppName);
    self.cachedSlashCommands = loaded;
    self.cachedSlashCommandsFamily = family;
    return loaded;
}

- (NSArray<InputMirrorSkillItem *> *)skillsForActiveApp {
    if (self.overrideSkillsForTesting != nil) {
        return self.overrideSkillsForTesting;
    }
    NSString *family = IMSkillAppFamilyKey(self.targetBundleID, self.targetAppName);
    NSString *workspaceRoot = [self resolveActiveWorkspaceRoot] ?: @"";
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", family, workspaceRoot];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (self.cachedSkills && [self.cachedSkillsCacheKey isEqualToString:cacheKey] && (now - self.cachedSkillsLoadedAt) < 15.0) {
        return self.cachedSkills;
    }
    NSArray<InputMirrorSkillItem *> *loaded = InputMirrorLoadSkillsForAppInWorkspace(self.targetBundleID, self.targetAppName, workspaceRoot, nil);
    self.cachedSkills = loaded;
    self.cachedSkillsCacheKey = cacheKey;
    self.cachedSkillsLoadedAt = now;
    return loaded;
}

- (NSArray<InputMirrorSkillItem *> *)slashAndSkillCandidatesForActiveApp {
    if (self.overrideSkillsForTesting != nil && self.overrideSlashCommandsForTesting == nil) {
        return self.overrideSkillsForTesting;
    }
    NSArray<InputMirrorSkillItem *> *cmds = [self slashCommandsForActiveApp];
    NSArray<InputMirrorSkillItem *> *skills = [self skillsForActiveApp];
    if (!cmds.count) return skills;
    if (!skills.count) return cmds;
    NSMutableArray<InputMirrorSkillItem *> *merged = [NSMutableArray arrayWithCapacity:cmds.count + skills.count];
    NSMutableSet<NSString *> *seenCmds = [NSMutableSet set];
    for (InputMirrorSkillItem *c in cmds) {
        [merged addObject:c];
        if (c.name.length) [seenCmds addObject:[NSString stringWithFormat:@"%@%@", c.insertPrefix ?: @"/", c.name.lowercaseString]];
    }
    for (InputMirrorSkillItem *s in skills) {
        NSString *key = [NSString stringWithFormat:@"%@%@", s.insertPrefix ?: @"/", s.name.lowercaseString ?: @""];
        if (![seenCmds containsObject:key]) {
            [merged addObject:s];
        }
    }
    return merged;
}

static NSString *IMFindProjectRootFromPath(NSString *path) {
    if (!path.length) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *expanded = [path stringByExpandingTildeInPath];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:expanded isDirectory:&isDir]) return nil;
    NSString *dir = isDir ? expanded : [expanded stringByDeletingLastPathComponent];
    NSString *home = NSHomeDirectory();
    static NSArray<NSString *> *markers = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        markers = @[@".git", @"package.json", @"Cargo.toml", @"pyproject.toml", @"go.mod", @"Package.swift"];
    });
    NSString *cursor = dir;
    for (NSUInteger depth = 0; depth < 8; depth++) {
        if (!cursor.length || [cursor isEqualToString:@"/"] || [cursor isEqualToString:home]) break;
        for (NSString *marker in markers) {
            if ([fm fileExistsAtPath:[cursor stringByAppendingPathComponent:marker]]) {
                return cursor;
            }
        }
        NSString *parent = [cursor stringByDeletingLastPathComponent];
        if ([parent isEqualToString:cursor]) break;
        cursor = parent;
    }
    return dir;
}

- (NSString *)resolveActiveWorkspaceRoot {
    if (self.overrideWorkspaceRootForTesting.length > 0) {
        return self.overrideWorkspaceRootForTesting;
    }
    if (self.targetPID > 0 && AXIsProcessTrusted()) {
        AXUIElementRef appElem = AXUIElementCreateApplication(self.targetPID);
        if (appElem) {
            id winObj = IMAxCopyAttribute(appElem, kAXFocusedWindowAttribute) ?: IMAxCopyAttribute(appElem, kAXMainWindowAttribute);
            CFRelease(appElem);
            if (winObj) {
                AXUIElementRef win = (__bridge AXUIElementRef)winObj;
                id docObj = IMAxCopyAttribute(win, kAXDocumentAttribute);
                if ([docObj isKindOfClass:NSString.class] && [(NSString *)docObj length] > 0) {
                    NSString *docStr = (NSString *)docObj;
                    NSURL *url = [NSURL URLWithString:docStr];
                    NSString *path = (url && url.isFileURL) ? url.path : docStr;
                    NSString *root = IMFindProjectRootFromPath(path);
                    if (root.length) return root;
                }

                id titleObj = IMAxCopyAttribute(win, kAXTitleAttribute);
                if ([titleObj isKindOfClass:NSString.class] && [(NSString *)titleObj length] > 0) {
                    NSString *title = (NSString *)titleObj;
                    NSArray<NSString *> *parts = [title componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"—–|"]];
                    for (NSString *part in parts) {
                        NSString *trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                        if ([trimmed hasPrefix:@"/"] || [trimmed hasPrefix:@"~/"]) {
                            NSString *root = IMFindProjectRootFromPath(trimmed);
                            if (root.length) return root;
                        }
                    }
                    NSString *family = IMSkillAppFamilyKey(self.targetBundleID, self.targetAppName);
                    if ([family isEqualToString:@"codex"]) {
                        NSString *cleanWinTitle = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                        if (cleanWinTitle.length >= 2 &&
                            ![cleanWinTitle.lowercaseString isEqualToString:@"codex"] &&
                            ![cleanWinTitle.lowercaseString isEqualToString:@"chatgpt"]) {
                            NSString *codexDB = [NSHomeDirectory() stringByAppendingPathComponent:@".codex/state_5.sqlite"];
                            NSString *matchedCwd = IMQueryBoundSQLiteText(codexDB, "SELECT cwd FROM threads WHERE (name = ?1 OR title = ?1) AND cwd IS NOT NULL AND cwd != '' ORDER BY updated_at DESC LIMIT 1;", cleanWinTitle);
                            NSString *dir = IMExistingDirectoryPathFromURIOrPath(matchedCwd);
                            if (dir.length) return dir;
                        }
                    }
                }
            }
        }
    }
    return InputMirrorResolveWorkspaceRootForApp(self.targetBundleID, self.targetAppName, nil);
}

- (NSArray<InputMirrorSkillItem *> *)mentionsForActiveApp {
    if (self.overrideMentionsForTesting != nil) {
        return self.overrideMentionsForTesting;
    }
    NSString *family = IMSkillAppFamilyKey(self.targetBundleID, self.targetAppName);
    NSString *workspaceRoot = [self resolveActiveWorkspaceRoot] ?: @"";
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", family, workspaceRoot];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (self.cachedMentions && [self.cachedMentionsCacheKey isEqualToString:cacheKey] && (now - self.cachedMentionsLoadedAt) < 15.0) {
        return self.cachedMentions;
    }

    NSArray<InputMirrorSkillItem *> *baseMentions = InputMirrorLoadMentionsForApp(self.targetBundleID, self.targetAppName, workspaceRoot);
    NSArray<InputMirrorSkillItem *> *convMentions = InputMirrorLoadConversationMentionsForApp(self.targetBundleID, self.targetAppName, nil);
    NSArray<InputMirrorSkillItem *> *codexSkills = [family isEqualToString:@"codex"] ? [self skillsForActiveApp] : @[];

    NSMutableArray<InputMirrorSkillItem *> *merged = [NSMutableArray arrayWithCapacity:baseMentions.count + convMentions.count + codexSkills.count];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    // 1. Workspace files & directories FIRST (aligned with Codex & Antigravity '@' behavior!)
    for (InputMirrorSkillItem *item in baseMentions) {
        if (!(item.itemKind == InputMirrorItemKindFile || item.itemKind == InputMirrorItemKindFolder ||
              [item.sourceLabel isEqualToString:@"文件"] || [item.sourceLabel isEqualToString:@"目录"])) continue;
        NSString *key = [NSString stringWithFormat:@"file:%@", item.name.lowercaseString ?: @""];
        if (![seen containsObject:key]) {
            [seen addObject:key];
            [merged addObject:item];
        }
    }
    // 2. Built-in context / MCP / Rules / Agents
    for (InputMirrorSkillItem *item in baseMentions) {
        if (item.itemKind == InputMirrorItemKindFile || item.itemKind == InputMirrorItemKindFolder ||
            [item.sourceLabel isEqualToString:@"文件"] || [item.sourceLabel isEqualToString:@"目录"]) continue;
        NSString *key = [NSString stringWithFormat:@"ctx:%@", item.name.lowercaseString ?: @""];
        if (![seen containsObject:key]) {
            [seen addObject:key];
            [merged addObject:item];
        }
    }
    // 3. Codex '@' also searches Skills (inserting $skill chip just like Codex's native composer.atMentionList.skills)
    for (InputMirrorSkillItem *sk in codexSkills) {
        NSString *key = [NSString stringWithFormat:@"skill:%@", sk.name.lowercaseString ?: @""];
        if (![seen containsObject:key]) {
            [seen addObject:key];
            [merged addObject:sk];
        }
    }
    // 4. Clean conversation / thread mentions
    for (InputMirrorSkillItem *item in convMentions) {
        NSString *key = [NSString stringWithFormat:@"chat:%@", item.name.lowercaseString ?: @""];
        if (![seen containsObject:key]) {
            [seen addObject:key];
            [merged addObject:item];
        }
    }

    self.cachedMentions = merged;
    self.cachedMentionsCacheKey = cacheKey;
    self.cachedMentionsLoadedAt = now;
    return merged;
}

- (NSArray<NSString *> *)categoriesForCandidates:(NSArray<InputMirrorSkillItem *> *)candidates triggerChar:(unichar)triggerChar {
    if (triggerChar == '$') return @[@"all"];
    NSMutableOrderedSet<NSString *> *present = [NSMutableOrderedSet orderedSet];
    for (InputMirrorSkillItem *item in candidates) {
        NSString *cat = item.categoryKey.length ? item.categoryKey : @"skills";
        [present addObject:cat];
    }
    if (present.count <= 1) return @[@"all"];
    NSArray<NSString *> *preferredOrder = (triggerChar == '@')
        ? @[@"files", @"skills", @"chats", @"mcp", @"context"]
        : @[@"commands", @"skills"];
    NSMutableArray<NSString *> *ordered = [NSMutableArray arrayWithObject:@"all"];
    for (NSString *k in preferredOrder) {
        if ([present containsObject:k]) [ordered addObject:k];
    }
    for (NSString *k in present) {
        if (![ordered containsObject:k]) [ordered addObject:k];
    }
    return ordered;
}

- (NSArray<InputMirrorSkillItem *> *)curateItems:(NSArray<InputMirrorSkillItem *> *)candidates
                                     forCategory:(NSString *)categoryKey
                                           query:(NSString *)query
                                     triggerChar:(unichar)triggerChar {
    NSString *cat = categoryKey.length ? categoryKey : @"all";
    NSArray<InputMirrorSkillItem *> *scoped = candidates;
    if (![cat isEqualToString:@"all"]) {
        NSMutableArray<InputMirrorSkillItem *> *sub = [NSMutableArray array];
        for (InputMirrorSkillItem *it in candidates) {
            NSString *itCat = it.categoryKey.length ? it.categoryKey : @"skills";
            if ([itCat isEqualToString:cat]) [sub addObject:it];
        }
        scoped = sub;
    }

    NSString *trimmedQuery = [query ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmedQuery.length > 0 || ![cat isEqualToString:@"all"]) {
        return InputMirrorFilterSkills(scoped, trimmedQuery);
    }

    // Empty '@' query in 'all' tab: balanced Codex/Antigravity overview (top recent files first, then concise slices of context/MCP, skills & chats)
    if (triggerChar == '@' && self.overrideMentionsForTesting == nil) {
        NSMutableArray<InputMirrorSkillItem *> *curated = [NSMutableArray array];
        NSUInteger fileCap = 12, ctxCap = 4, skillCap = 4, chatCap = 4;
        for (InputMirrorSkillItem *it in scoped) {
            NSString *c = it.categoryKey ?: @"";
            if ([c isEqualToString:@"files"]) {
                if (fileCap > 0) { [curated addObject:it]; fileCap--; }
            } else if ([c isEqualToString:@"mcp"] || [c isEqualToString:@"context"]) {
                if (ctxCap > 0) { [curated addObject:it]; ctxCap--; }
            } else if ([c isEqualToString:@"skills"]) {
                if (skillCap > 0) { [curated addObject:it]; skillCap--; }
            } else if ([c isEqualToString:@"chats"]) {
                if (chatCap > 0) { [curated addObject:it]; chatCap--; }
            } else {
                [curated addObject:it];
            }
        }
        return curated.count ? curated : scoped;
    }
    return scoped;
}

- (void)selectSkillMenuCategory:(NSString *)categoryKey {
    if (!categoryKey.length || ![self.availableSkillMenuCategories containsObject:categoryKey]) return;
    self.activeSkillMenuCategoryKey = categoryKey;
    [self refreshSkillMenuForCurrentText];
}

- (void)cycleSkillMenuCategoryByDelta:(NSInteger)delta {
    NSArray<NSString *> *cats = self.availableSkillMenuCategories;
    if (cats.count <= 1) return;
    NSUInteger cur = [cats indexOfObject:self.activeSkillMenuCategoryKey ?: @"all"];
    if (cur == NSNotFound) cur = 0;
    NSInteger count = (NSInteger)cats.count;
    NSInteger next = (((NSInteger)cur + delta) % count + count) % count;
    [self selectSkillMenuCategory:cats[(NSUInteger)next]];
}

- (void)hideSkillMenu {
    if (self.skillMenuPanel.visible) {
        [self.skillMenuPanel orderOut:nil];
    }
    self.skillMenuItems = @[];
    self.skillMenuRowViews = @[];
    self.skillMenuSelectedIndex = 0;
    self.activeSkillTrigger = (InputMirrorSkillTrigger){ NO, NSMakeRange(NSNotFound, 0), 0 };
}

- (CGFloat)preferredPopoverAnchorScreenX {
    NSRect parentFrame = self.panel.frame;
    if (!self.activeSkillTrigger.active || !self.textView.layoutManager || !self.textView.textContainer) {
        return NSMinX(parentFrame);
    }
    NSUInteger charIdx = MIN(self.activeSkillTrigger.tokenRange.location, self.textView.string.length);
    if (charIdx >= self.textView.string.length) return NSMinX(parentFrame);
    [self.textView.layoutManager ensureLayoutForTextContainer:self.textView.textContainer];
    NSUInteger glyphIdx = [self.textView.layoutManager glyphIndexForCharacterAtIndex:charIdx];
    NSRect glyphRect = [self.textView.layoutManager boundingRectForGlyphRange:NSMakeRange(glyphIdx, 1) inTextContainer:self.textView.textContainer];
    NSPoint viewPt = NSMakePoint(self.textView.textContainerOrigin.x + glyphRect.origin.x - 10.0,
                                 self.textView.textContainerOrigin.y + glyphRect.origin.y);
    NSPoint winPt = [self.textView convertPoint:viewPt toView:nil];
    NSRect screenRect = [self.panel convertRectToScreen:NSMakeRect(winPt.x, winPt.y, 1.0, 1.0)];
    return MAX(NSMinX(parentFrame), screenRect.origin.x);
}

- (void)repositionSkillMenuPanel {
    if (!self.panel || !self.skillMenuPanel) return;
    BOOL showCatBar = (self.availableSkillMenuCategories.count > 1);
    CGFloat catBarTotal = showCatBar ? (kSkillMenuCategoryBarHeight + 1.0) : 0.0;
    NSUInteger skillCount = self.skillMenuItems.count > 0 ? (self.skillMenuItems.count - 1) : 0;
    NSUInteger visibleRows = MIN(skillCount, kSkillMenuMaxVisibleRows);
    CGFloat listHeight = (visibleRows > 0) ? (visibleRows * kSkillMenuRowHeight + 8.0) : 0.0;
    CGFloat totalHeight = catBarTotal + listHeight + (listHeight > 0 ? 1.0 : 0.0) + kSkillMenuFooterHeight;

    NSRect parentFrame = self.panel.frame;
    CGFloat width = MIN(MAX(NSWidth(parentFrame) * 0.86, 390.0), 540.0);
    NSScreen *screen = self.panel.screen ?: NSScreen.mainScreen;
    NSRect visible = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);

    CGFloat x = [self preferredPopoverAnchorScreenX];
    if (x + width > NSMaxX(visible) - 8.0) x = MAX(NSMinX(visible) + 8.0, NSMaxX(visible) - 8.0 - width);
    if (x < NSMinX(visible) + 8.0) x = NSMinX(visible) + 8.0;

    CGFloat gap = 6.0;
    CGFloat belowY = NSMinY(parentFrame) - gap - totalHeight;
    CGFloat aboveY = NSMaxY(parentFrame) + gap;
    CGFloat y = belowY;
    if (belowY < NSMinY(visible) + 8.0 && (aboveY + totalHeight) <= NSMaxY(visible) - 8.0) {
        y = aboveY;
    } else if (belowY < NSMinY(visible) + 8.0) {
        y = MAX(NSMinY(visible) + 8.0, aboveY);
    }

    [self.skillMenuPanel setFrame:NSMakeRect(x, y, width, totalHeight) display:YES];
    self.skillMenuCategoryBar.hidden = !showCatBar;
    self.skillMenuCategoryDivider.hidden = !showCatBar;
    if (showCatBar) {
        self.skillMenuCategoryBar.frame = NSMakeRect(0, totalHeight - kSkillMenuCategoryBarHeight, width, kSkillMenuCategoryBarHeight);
        self.skillMenuCategoryDivider.frame = NSMakeRect(10.0, totalHeight - kSkillMenuCategoryBarHeight - 1.0, width - 20.0, 1.0);
    }
    self.skillMenuScroll.hidden = (skillCount == 0);
    self.skillMenuFooterDivider.hidden = (skillCount == 0);
    if (skillCount > 0) {
        self.skillMenuScroll.frame = NSMakeRect(0, kSkillMenuFooterHeight + 1.0, width, listHeight);
    }
    self.skillMenuFooterDivider.frame = NSMakeRect(10.0, kSkillMenuFooterHeight, width - 20.0, 1.0);
    self.skillMenuFooterRow.frame = NSMakeRect(0, 0, width, kSkillMenuFooterHeight);
}

- (void)rebuildCategoryTabViewsWithFamily:(NSString *)family {
    for (NSView *sub in [self.skillMenuCategoryBar.subviews copy]) {
        [sub removeFromSuperview];
    }
    NSArray<NSString *> *cats = self.availableSkillMenuCategories;
    if (cats.count <= 1) {
        self.skillMenuCategoryTabViews = @[];
        return;
    }
    NSColor *accent = [self currentAccentColor];
    NSColor *muted = (self.style == InputMirrorStyleGlass) ? NSColor.secondaryLabelColor : [self currentMutedColor];
    NSFont *measureFont = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
    NSDictionary *measureAttrs = @{ NSFontAttributeName: measureFont };

    NSMutableArray<InputMirrorCategoryTabView *> *tabs = [NSMutableArray arrayWithCapacity:cats.count];
    __weak InputMirrorController *weakSelf = self;
    CGFloat x = 10.0;
    for (NSString *key in cats) {
        NSString *label = IMCategoryDisplayName(key, family);
        CGFloat w = ceil([label sizeWithAttributes:measureAttrs].width) + 20.0;
        InputMirrorCategoryTabView *tab = [[InputMirrorCategoryTabView alloc] initWithFrame:NSMakeRect(x, 3.0, w, kSkillMenuCategoryBarHeight - 6.0)];
        tab.categoryKey = key;
        tab.titleText = label;
        tab.activeTab = [key isEqualToString:(self.activeSkillMenuCategoryKey ?: @"all")];
        tab.accentColor = accent;
        tab.mutedColor = muted;
        tab.onSelect = ^(NSString *selectedKey) {
            [weakSelf selectSkillMenuCategory:selectedKey];
        };
        [self.skillMenuCategoryBar addSubview:tab];
        [tabs addObject:tab];
        x += w + 4.0;
    }
    self.skillMenuCategoryTabViews = tabs;
}

- (void)rebuildSkillMenuRowsWithFilteredSkills:(NSArray<InputMirrorSkillItem *> *)filtered query:(NSString *)query triggerChar:(unichar)triggerChar {
    NSString *family = IMSkillAppFamilyKey(self.targetBundleID, self.targetAppName);
    [self rebuildCategoryTabViewsWithFamily:family];

    NSString *appDisplay = self.targetAppName.length ? self.targetAppName : @"原应用";
    BOOL isMention = (triggerChar == '@');
    InputMirrorSkillItem *handoffItem = [[InputMirrorSkillItem alloc] init];
    handoffItem.isNativeHandoffAction = YES;
    handoffItem.itemKind = InputMirrorItemKindNativeHandoff;
    if (isMention) {
        handoffItem.name = query.length > 0
            ? [NSString stringWithFormat:@"在 %@ 原生 @ 菜单打开「@%@」…", appDisplay, query]
            : [NSString stringWithFormat:@"在 %@ 原生 @ 菜单浏览全部…", appDisplay];
    } else {
        handoffItem.name = query.length > 0
            ? [NSString stringWithFormat:@"在 %@ 原生菜单运行「%C%@」…", appDisplay, triggerChar, query]
            : [NSString stringWithFormat:@"在 %@ 原生菜单浏览全部…", appDisplay];
    }

    NSMutableArray<InputMirrorSkillItem *> *allItems = [NSMutableArray arrayWithArray:filtered];
    [allItems addObject:handoffItem];
    self.skillMenuItems = allItems;

    self.skillMenuFooterTitle.stringValue = handoffItem.name;
    self.skillMenuFooterHint.stringValue = (self.availableSkillMenuCategories.count > 1)
        ? @"↵/Tab 确认 · ⇧Tab 分类"
        : (isMention ? @"↵/Tab 确认 · ⇧⌘2 原生" : @"↵/Tab 确认 · ⌘/ 原生");
    self.skillMenuFooterRow.rowIndex = (NSInteger)filtered.count;

    for (NSView *sub in [self.skillMenuListContainer.subviews copy]) {
        [sub removeFromSuperview];
    }

    NSRect parentFrame = self.panel.frame;
    CGFloat width = MIN(MAX(NSWidth(parentFrame) * 0.86, 390.0), 540.0);
    CGFloat contentH = filtered.count * kSkillMenuRowHeight + 8.0;
    self.skillMenuListContainer.frame = NSMakeRect(0, 0, width, MAX(contentH, 1.0));

    NSColor *accent = [self currentAccentColor];
    NSColor *textColor = [self currentTextColor];
    NSColor *muted = (self.style == InputMirrorStyleGlass) ? NSColor.secondaryLabelColor : [self currentMutedColor];
    NSColor *selBg = [accent colorWithAlphaComponent:0.16];

    NSMutableArray<InputMirrorSkillRowView *> *rowViews = [NSMutableArray arrayWithCapacity:filtered.count + 1];
    __weak InputMirrorController *weakSelf = self;

    for (NSUInteger i = 0; i < filtered.count; i++) {
        InputMirrorSkillItem *item = filtered[i];
        CGFloat rowY = contentH - 4.0 - (i + 1) * kSkillMenuRowHeight;
        InputMirrorSkillRowView *row = [[InputMirrorSkillRowView alloc] initWithFrame:NSMakeRect(0, rowY, width, kSkillMenuRowHeight)];
        row.autoresizingMask = NSViewWidthSizable;
        row.rowIndex = (NSInteger)i;
        row.selectionColor = selBg;
        row.onHover = ^(NSInteger idx) {
            [weakSelf selectSkillMenuRow:idx scrollToVisible:NO];
        };
        row.onClick = ^(NSInteger idx) {
            [weakSelf confirmSkillMenuItemAtIndex:idx];
        };

        // SF Symbol icon matching item kind (file, folder, command, skill, conversation, MCP)
        NSString *symName = item.symbolName.length ? item.symbolName : (isMention ? @"doc.text" : @"sparkles");
        NSImage *symImg = [NSImage imageWithSystemSymbolName:symName accessibilityDescription:nil];
        if (symImg) {
            NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:13.0 weight:NSFontWeightMedium];
            NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(13.0, 12.0, 18.0, 18.0)];
            iconView.image = [symImg imageWithSymbolConfiguration:cfg] ?: symImg;
            iconView.contentTintColor = (item.itemKind == InputMirrorItemKindFile || item.itemKind == InputMirrorItemKindFolder) ? muted : accent;
            [row addSubview:iconView];
        }

        NSString *prefix = item.insertPrefix.length ? item.insertPrefix : (isMention ? @"@" : @"/");
        NSString *primaryTitle = item.displayTitle.length ? item.displayTitle : [NSString stringWithFormat:@"%@%@", prefix, item.name];
        NSMutableAttributedString *titleAttr = [[NSMutableAttributedString alloc] initWithString:primaryTitle attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: (item.itemKind == InputMirrorItemKindFile || item.itemKind == InputMirrorItemKindConversation) ? textColor : accent
        }];
        if (item.displayDetail.length > 0) {
            NSAttributedString *detailAttr = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %@", item.displayDetail] attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: muted
            }];
            [titleAttr appendAttributedString:detailAttr];
        }

        NSTextField *nameLabel = [NSTextField labelWithAttributedString:titleAttr];
        nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        nameLabel.frame = NSMakeRect(36.0, 21.0, width - 118.0, 17.0);
        nameLabel.autoresizingMask = NSViewWidthSizable;
        [row addSubview:nameLabel];

        NSString *badgeText = item.sourceLabel ?: @"";
        if (item.autoConfirmOnNativeHandoff && [badgeText isEqualToString:@"命令"]) {
            badgeText = @"命令 ↵";
        }
        if (badgeText.length > 0) {
            NSTextField *badge = [NSTextField labelWithString:badgeText];
            badge.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
            badge.textColor = muted;
            badge.alignment = NSTextAlignmentRight;
            badge.frame = NSMakeRect(width - 80.0, 22.0, 66.0, 15.0);
            badge.autoresizingMask = NSViewMinXMargin;
            [row addSubview:badge];
        }

        NSString *fallbackDesc = isMention ? @"回车或 Tab 插入引用标签" : @"回车或 Tab 确认";
        NSString *desc = item.summary.length ? item.summary : fallbackDesc;
        NSTextField *descLabel = [NSTextField labelWithString:desc];
        descLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
        descLabel.textColor = [textColor colorWithAlphaComponent:0.66];
        descLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        descLabel.frame = NSMakeRect(36.0, 4.0, width - 50.0, 15.0);
        descLabel.autoresizingMask = NSViewWidthSizable;
        [row addSubview:descLabel];

        [self.skillMenuListContainer addSubview:row];
        [rowViews addObject:row];
    }

    [rowViews addObject:self.skillMenuFooterRow];
    self.skillMenuRowViews = rowViews;

    [self repositionSkillMenuPanel];
    if (filtered.count > 0) {
        CGFloat topY = MAX(0.0, NSHeight(self.skillMenuListContainer.frame) - NSHeight(self.skillMenuScroll.contentView.bounds));
        [self.skillMenuScroll.contentView scrollToPoint:NSMakePoint(0, topY)];
        [self.skillMenuScroll reflectScrolledClipView:self.skillMenuScroll.contentView];
    }
    [self selectSkillMenuRow:0 scrollToVisible:NO];
}

- (void)selectSkillMenuRow:(NSInteger)index scrollToVisible:(BOOL)scrollToVisible {
    if (!self.skillMenuRowViews.count) return;
    NSInteger count = (NSInteger)self.skillMenuRowViews.count;
    NSInteger clamped = ((index % count) + count) % count;
    self.skillMenuSelectedIndex = clamped;
    for (NSInteger i = 0; i < count; i++) {
        self.skillMenuRowViews[(NSUInteger)i].selectedRow = (i == clamped);
    }
    if (scrollToVisible && clamped < count - 1) {
        InputMirrorSkillRowView *targetRow = self.skillMenuRowViews[(NSUInteger)clamped];
        [self.skillMenuListContainer scrollRectToVisible:targetRow.frame];
    }
}

- (void)refreshSkillMenuForCurrentText {
    if (!self.panel.visible) {
        [self hideSkillMenu];
        return;
    }
    NSString *rawText = self.textView.string ?: @"";
    NSRange sel = self.textView.selectedRange;
    NSString *parseText = rawText;
    NSRange parseSel = sel;
    NSString *imeRawLatin = @"";

    // Keep the @ / / / $ popover smoothly open during Chinese Pinyin IME composition instead of flashing closed!
    if (self.textView.hasMarkedText) {
        NSRange marked = self.textView.markedRange;
        if (marked.location != NSNotFound && NSMaxRange(marked) <= rawText.length) {
            NSString *markedStr = [rawText substringWithRange:marked];
            NSMutableString *compact = [NSMutableString stringWithCapacity:markedStr.length];
            for (NSUInteger i = 0; i < markedStr.length; i++) {
                unichar c = [markedStr characterAtIndex:i];
                if (!IMIsTriggerBoundaryChar(c) && c != '\'' && c != 0x2019) {
                    [compact appendFormat:@"%C", c];
                }
            }
            imeRawLatin = compact;
            NSMutableString *committedOnly = [rawText mutableCopy];
            [committedOnly deleteCharactersInRange:marked];
            parseText = committedOnly;
            parseSel = NSMakeRange(marked.location, 0);
        } else {
            return;
        }
    }

    NSString *query = nil;
    InputMirrorSkillTrigger trigger = InputMirrorParseSkillTrigger(parseText, parseSel, &query);
    if (!trigger.active) {
        self.dismissedSkillTriggerLocation = NSNotFound;
        self.lastCategoryTriggerChar = 0;
        self.activeSkillMenuCategoryKey = @"all";
        [self hideSkillMenu];
        return;
    }
    if (self.dismissedSkillTriggerLocation == trigger.tokenRange.location) {
        return;
    }

    if (self.lastCategoryTriggerChar != trigger.triggerChar) {
        self.lastCategoryTriggerChar = trigger.triggerChar;
        self.activeSkillMenuCategoryKey = @"all";
    }

    NSArray<InputMirrorSkillItem *> *candidates = nil;
    if (trigger.triggerChar == '@') {
        candidates = [self mentionsForActiveApp];
    } else if (trigger.triggerChar == '$') {
        candidates = [self skillsForActiveApp];
    } else {
        candidates = [self slashAndSkillCandidatesForActiveApp];
    }

    self.availableSkillMenuCategories = [self categoriesForCandidates:candidates triggerChar:trigger.triggerChar];
    if (![self.availableSkillMenuCategories containsObject:(self.activeSkillMenuCategoryKey ?: @"all")]) {
        self.activeSkillMenuCategoryKey = @"all";
    }

    NSString *effectiveQuery = query ?: @"";
    NSArray<InputMirrorSkillItem *> *filtered = nil;
    if (imeRawLatin.length > 0) {
        NSString *tryCombined = [effectiveQuery stringByAppendingString:imeRawLatin];
        NSArray<InputMirrorSkillItem *> *imeFiltered = [self curateItems:candidates
                                                             forCategory:self.activeSkillMenuCategoryKey
                                                                   query:tryCombined
                                                             triggerChar:trigger.triggerChar];
        if (imeFiltered.count > 0) {
            filtered = imeFiltered;
            effectiveQuery = tryCombined;
        }
    }
    if (!filtered) {
        filtered = [self curateItems:candidates
                         forCategory:self.activeSkillMenuCategoryKey
                               query:effectiveQuery
                         triggerChar:trigger.triggerChar];
    }

    // Avoid popping up on prices or shell variables like "$100" / "$HOME" when no local skills match
    if (trigger.triggerChar == '$' && filtered.count == 0 && effectiveQuery.length > 0 && !self.textView.hasMarkedText) {
        [self hideSkillMenu];
        return;
    }

    self.activeSkillTrigger = trigger;
    [self rebuildSkillMenuRowsWithFilteredSkills:filtered query:effectiveQuery triggerChar:trigger.triggerChar];
    if (!self.skillMenuPanel.visible) {
        [self.skillMenuPanel orderFrontRegardless];
    }
}

- (BOOL)handleSkillMenuKeyDown:(NSEvent *)event {
    if (!self.skillMenuPanel.visible || !self.skillMenuItems.count) return NO;
    unsigned short keyCode = event.keyCode;
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL hasCmd = (mods & NSEventModifierFlagCommand) != 0;
    BOOL hasOpt = (mods & NSEventModifierFlagOption) != 0;
    BOOL hasCtrl = (mods & NSEventModifierFlagControl) != 0;
    BOOL hasShift = (mods & NSEventModifierFlagShift) != 0;
    BOOL hasMods = (hasCmd || hasOpt || hasCtrl || hasShift);

    // Category filter tab switching: Shift+Tab, Ctrl+Tab, or Option+Left/Right
    if (self.availableSkillMenuCategories.count > 1) {
        if (keyCode == kVK_Tab && (hasShift || hasCtrl) && !hasCmd && !hasOpt) {
            [self cycleSkillMenuCategoryByDelta:(hasShift && !hasCtrl) ? -1 : 1];
            return YES;
        }
        if ((keyCode == kVK_RightArrow || keyCode == kVK_LeftArrow) && hasOpt && !hasCmd && !hasCtrl && !hasShift) {
            [self cycleSkillMenuCategoryByDelta:(keyCode == kVK_RightArrow) ? 1 : -1];
            return YES;
        }
    }

    if (keyCode == kVK_DownArrow && !hasMods) {
        [self selectSkillMenuRow:self.skillMenuSelectedIndex + 1 scrollToVisible:YES];
        return YES;
    }
    if (keyCode == kVK_UpArrow && !hasMods) {
        [self selectSkillMenuRow:self.skillMenuSelectedIndex - 1 scrollToVisible:YES];
        return YES;
    }
    if ((keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter || keyCode == kVK_Tab) && !hasMods) {
        [self confirmSkillMenuItemAtIndex:self.skillMenuSelectedIndex];
        return YES;
    }
    if (keyCode == kVK_Escape && !hasMods) {
        self.dismissedSkillTriggerLocation = self.activeSkillTrigger.tokenRange.location;
        [self hideSkillMenu];
        return YES;
    }
    return NO;
}

- (BOOL)handleAtomicChipBackspace {
    if (self.skillMenuPanel.visible || !self.confirmedChipSet.count) return NO;
    NSRange sel = self.textView.selectedRange;
    if (sel.length != 0 || sel.location == 0) return NO;
    NSString *text = self.textView.string ?: @"";
    if (sel.location > text.length) return NO;

    NSUInteger caret = sel.location;
    NSUInteger tokenEnd = caret;
    if (tokenEnd > 0 && [text characterAtIndex:tokenEnd - 1] == ' ') {
        tokenEnd--;
    }
    if (tokenEnd == 0) return NO;

    NSInteger scan = (NSInteger)tokenEnd - 1;
    while (scan >= 0 && !IMIsChipTokenTerminator([text characterAtIndex:(NSUInteger)scan])) {
        unichar ch = [text characterAtIndex:(NSUInteger)scan];
        if (ch == '@' || ch == '$' || ch == '/') {
            if (scan == 0 || IMIsNativeChipPrefixBoundary([text characterAtIndex:(NSUInteger)(scan - 1)])) {
                NSUInteger start = (NSUInteger)scan;
                NSString *candidate = [text substringWithRange:NSMakeRange(start, tokenEnd - start)];
                if ([self.confirmedChipSet containsObject:candidate]) {
                    NSRange deleteRange = NSMakeRange(start, caret - start);
                    [self.textView applyUndoableReplacementInRange:deleteRange
                                                        withString:@""
                                                      newSelection:NSMakeRange(start, 0)];
                    return YES;
                }
            }
        }
        scan--;
    }
    return NO;
}

- (void)confirmSkillMenuItemAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.skillMenuItems.count) return;
    InputMirrorSkillItem *item = self.skillMenuItems[(NSUInteger)index];
    if (item.isNativeHandoffAction) {
        if (self.activeSkillTrigger.triggerChar == '@') {
            [self handoffToNativeMentionMenu];
        } else {
            [self handoffToNativeSlashMenu];
        }
        return;
    }
    if (!self.activeSkillTrigger.active) return;

    NSRange tokenRange = self.activeSkillTrigger.tokenRange;
    NSString *currentText = self.textView.string ?: @"";
    if (NSMaxRange(tokenRange) > currentText.length) {
        [self hideSkillMenu];
        return;
    }

    // Ensure a clean whitespace boundary before '@', '$', or '/' when preceded by CJK text
    // so Codex & Antigravity's /(?:^|[\s([{])[@$/]/ parser always activates!
    BOOL needsLeadingSpace = (tokenRange.location > 0 &&
                              !IMIsNativeChipPrefixBoundary([currentText characterAtIndex:tokenRange.location - 1]));
    NSString *lead = needsLeadingSpace ? @" " : @"";

    NSString *fallbackPrefix = (self.activeSkillTrigger.triggerChar == '@') ? @"@" : @"/";
    NSString *prefix = item.insertPrefix.length ? item.insertPrefix : fallbackPrefix;
    unichar effectiveTrigChar = prefix.length ? [prefix characterAtIndex:0] : self.activeSkillTrigger.triggerChar;

    if (item.requiresNativeHandoff) {
        NSString *nativeToken = (item.itemKind == InputMirrorItemKindConversation)
            ? IMNativeMentionQueryToken(item.name)
            : item.name;
        NSString *core = [NSString stringWithFormat:@"%@%@", prefix, nativeToken.length ? nativeToken : item.name];
        NSString *insertion = [lead stringByAppendingString:core];
        NSUInteger resolvedTrigLoc = tokenRange.location + lead.length;
        [self hideSkillMenu];
        [self.textView applyUndoableReplacementInRange:tokenRange
                                            withString:insertion
                                          newSelection:NSMakeRange(tokenRange.location + insertion.length, 0)];
        [self handoffToNativeMenuWithTriggerChar:effectiveTrigChar
                         explicitTriggerLocation:resolvedTrigLoc
                            autoConfirmSelection:item.autoConfirmOnNativeHandoff];
        return;
    }

    NSString *chipToken = [NSString stringWithFormat:@"%@%@", prefix, item.name];
    [self.confirmedChipSet addObject:chipToken];
    NSString *insertion = [NSString stringWithFormat:@"%@%@ ", lead, chipToken];
    [self hideSkillMenu];
    [self.textView applyUndoableReplacementInRange:tokenRange
                                        withString:insertion
                                      newSelection:NSMakeRange(tokenRange.location + insertion.length, 0)];
}

- (void)handoffToNativeSlashMenu {
    [self handoffToNativeMenuWithTriggerChar:'/' explicitTriggerLocation:NSNotFound autoConfirmSelection:NO];
}

- (void)handoffToNativeMentionMenu {
    [self handoffToNativeMenuWithTriggerChar:'@' explicitTriggerLocation:NSNotFound autoConfirmSelection:NO];
}

- (void)handoffToNativeMenuWithTriggerChar:(unichar)defaultTriggerChar
                   explicitTriggerLocation:(NSUInteger)explicitTriggerLocation
                      autoConfirmSelection:(BOOL)autoConfirmSelection {
    NSString *current = self.textView.string ?: @"";
    NSRange sel = self.textView.selectedRange;
    NSString *handoffText = current;
    BOOL wantsMention = (defaultTriggerChar == '@');
    NSUInteger resolvedTrigLoc = explicitTriggerLocation;

    if (resolvedTrigLoc == NSNotFound || resolvedTrigLoc >= current.length) {
        InputMirrorSkillTrigger trigger = InputMirrorParseSkillTrigger(current, sel, NULL);
        BOOL triggerMatches = trigger.active && (wantsMention ? (trigger.triggerChar == '@') : (trigger.triggerChar == '/' || trigger.triggerChar == '$'));
        if (triggerMatches) {
            if (trigger.tokenRange.location > 0 &&
                !IMIsNativeChipPrefixBoundary([current characterAtIndex:trigger.tokenRange.location - 1])) {
                NSMutableString *spaced = [current mutableCopy];
                [spaced insertString:@" " atIndex:trigger.tokenRange.location];
                handoffText = spaced;
                resolvedTrigLoc = trigger.tokenRange.location + 1;
                [self.textView setString:handoffText];
                [self.textView setSelectedRange:NSMakeRange(handoffText.length, 0)];
            } else {
                resolvedTrigLoc = trigger.tokenRange.location;
            }
        } else {
            NSString *trigStr = [NSString stringWithFormat:@"%C", defaultTriggerChar];
            if (current.length == 0) {
                resolvedTrigLoc = 0;
                handoffText = trigStr;
            } else if (IMIsTriggerBoundaryChar([current characterAtIndex:current.length - 1])) {
                resolvedTrigLoc = current.length;
                handoffText = [current stringByAppendingString:trigStr];
            } else {
                resolvedTrigLoc = current.length + 1;
                handoffText = [current stringByAppendingFormat:@" %@", trigStr];
            }
            [self.textView setString:handoffText];
            [self.textView setSelectedRange:NSMakeRange(handoffText.length, 0)];
        }
    }

    self.lastNativeHandoffAutoConfirmed = autoConfirmSelection;
    [self hideSkillMenu];
    [self.liveSyncTimer invalidate];
    self.liveSyncTimer = nil;
    [self clearDraftForKey:[self currentDraftKey]];
    self.hasLocalEditsPendingSync = NO;
    self.suppressResignSync = YES;
    self.inPreviewSample = NO;
    self.sendCloseCooldownUntil = NSProcessInfo.processInfo.systemUptime + 1.0;
    [self clearDismissedElement];
    if (self.targetElement) {
        self.dismissedElement = (AXUIElementRef)CFRetain(self.targetElement);
        self.dismissedTextSnapshot = autoConfirmSelection ? @"" : handoffText;
    }
    [self hidePanel];
    self.suppressResignSync = NO;

    if (wantsMention && self.onNativeMentionHandoff) {
        self.onNativeMentionHandoff(handoffText);
        return;
    }
    if (self.onNativeSlashHandoff) {
        self.onNativeSlashHandoff(handoffText);
        return;
    }
    [self flushLocalEditsToTargetAndSend:NO
                    forceKeystrokeEvents:YES
                         triggerLocation:resolvedTrigLoc
                    autoConfirmSelection:autoConfirmSelection];
}

static BOOL IMSegmentsContainNativeChip(NSArray<InputMirrorSyncSegment *> *segments) {
    for (InputMirrorSyncSegment *seg in segments) {
        if (seg.isNativeChip) return YES;
    }
    return NO;
}

static void IMReplaySyncSegmentsAtIndex(pid_t pid,
                                        NSArray<InputMirrorSyncSegment *> *segments,
                                        NSUInteger index,
                                        void (^completion)(void)) {
    if (index >= segments.count) {
        if (completion) completion();
        return;
    }
    InputMirrorSyncSegment *seg = segments[index];
    if (!seg.isNativeChip) {
        if (seg.text.length > 0) {
            IMSendUnicodeTextToPidEx(pid, seg.text, NO);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.015 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            IMReplaySyncSegmentsAtIndex(pid, segments, index + 1, completion);
        });
        return;
    }

    // Native chip segment: send real trigger keycode (@ / $ / /) -> wait for native menu -> type query -> Tab to bind real chip!
    NSString *trigStr = [NSString stringWithFormat:@"%C", seg.triggerChar];
    IMSendUnicodeTextToPidEx(pid, trigStr, YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.045 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (seg.text.length > 0) {
            IMSendUnicodeTextToPidEx(pid, seg.text, NO);
        }
        NSTimeInterval filterWait = (seg.triggerChar == '@') ? 0.085 : 0.055;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(filterWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            IMSendKeyToPid(pid, kVK_Tab, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.035 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                IMReplaySyncSegmentsAtIndex(pid, segments, index + 1, completion);
            });
        });
    });
}

- (void)pushLiveEditsToTarget {
    if (!self.targetElement || self.targetPID <= 0 || self.syncInFlight || self.textView.hasMarkedText) return;
    NSString *text = self.textView.string ?: @"";
    NSString *prev = self.lastSyncedToTargetText ?: @"";
    if ([text isEqualToString:prev]) {
        self.hasLocalEditsPendingSync = NO;
        [self clearDraftForKey:[self currentDraftKey]];
        return;
    }

    // Preserve confirmed @ / $ / / chips for structured native keystroke binding on send/dismiss
    // rather than flattening them into plain AXValue text.
    if (self.confirmedChipSet.count > 0 &&
        IMSegmentsContainNativeChip(InputMirrorBuildSyncSegments(text, self.confirmedChipSet))) {
        return;
    }

    // Try direct AXValue write (real-time live sync for native macOS text inputs).
    // For Electron/Chromium apps whose AXValue is read-only while unfocused, keep hasLocalEditsPendingSync=YES
    // and keep the draft preserved so edits are never lost on Space/app switch and flush cleanly on Enter or Esc/Close.
    AXError err = AXUIElementSetAttributeValue(self.targetElement, kAXValueAttribute, (__bridge CFStringRef)text);
    if (err == kAXErrorSuccess) {
        NSString *readBack = IMAxReadTextValue(self.targetElement, NULL);
        if ([readBack isEqualToString:text]) {
            self.lastSyncedToTargetText = text;
            self.hasLocalEditsPendingSync = NO;
            [self clearDraftForKey:[self currentDraftKey]];
            NSRange sel = self.textView.selectedRange;
            CFRange cfRange = CFRangeMake((CFIndex)sel.location, (CFIndex)sel.length);
            AXValueRef rangeVal = AXValueCreate(kAXValueCFRangeType, &cfRange);
            if (rangeVal) {
                AXUIElementSetAttributeValue(self.targetElement, kAXSelectedTextRangeAttribute, rangeVal);
                CFRelease(rangeVal);
            }
        }
    }
}

- (void)handleCloseButton:(id)sender {
    [self dismissTemporarily];
}

- (void)dismissTemporarily {
    [self.liveSyncTimer invalidate];
    self.liveSyncTimer = nil;
    NSString *text = self.textView.string ?: self.mirroredText ?: @"";
    BOOL hadPending = self.hasLocalEditsPendingSync || ![text isEqualToString:(self.lastSyncedToTargetText ?: @"")];
    if (hadPending) {
        [self saveCurrentDraftIfNeeded];
    }
    self.hasLocalEditsPendingSync = NO;
    self.suppressResignSync = YES;
    self.inPreviewSample = NO;
    self.sendCloseCooldownUntil = NSProcessInfo.processInfo.systemUptime + 0.45;
    [self clearDismissedElement];
    if (self.targetElement) {
        self.dismissedElement = (AXUIElementRef)CFRetain(self.targetElement);
        self.dismissedTextSnapshot = text;
    }
    [self hidePanel];
    self.suppressResignSync = NO;
    if (hadPending && !self.syncInFlight && self.targetElement && self.targetPID > 0) {
        [self flushLocalEditsToTargetAndSend:NO];
    } else if (self.targetPID > 0 && !self.previewMode) {
        NSRunningApplication *targetApp = [NSRunningApplication runningApplicationWithProcessIdentifier:self.targetPID];
        [targetApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    }
}

- (void)syncAndSend {
    [self.liveSyncTimer invalidate];
    self.liveSyncTimer = nil;
    NSString *text = self.textView.string ?: @"";
    AXUIElementRef element = self.targetElement ? (AXUIElementRef)CFRetain(self.targetElement) : NULL;
    BOOL hasNativeChips = (self.confirmedChipSet.count > 0 &&
                           IMSegmentsContainNativeChip(InputMirrorBuildSyncSegments(text, self.confirmedChipSet)));
    BOOL needsFlush = hasNativeChips || self.hasLocalEditsPendingSync || ![text isEqualToString:(self.lastSyncedToTargetText ?: @"")];
    pid_t pid = self.targetPID;

    // Clear draft, pending flag & suppress resign sync BEFORE hidePanel so windowDidResignKey NEVER triggers a second sync!
    [self clearDraftForKey:[self currentDraftKey]];
    self.hasLocalEditsPendingSync = NO;
    self.suppressResignSync = YES;
    self.inPreviewSample = NO;
    self.sendCloseCooldownUntil = NSProcessInfo.processInfo.systemUptime + 1.2;
    [self clearDismissedElement];
    if (element) {
        self.dismissedElement = (AXUIElementRef)CFRetain(element);
        self.dismissedTextSnapshot = @"";
        CFRelease(element);
    }
    [self hidePanel];
    self.suppressResignSync = NO;

    if (self.onSyncBack) {
        [self.confirmedChipSet removeAllObjects];
        self.onSyncBack(text, YES);
        return;
    }

    if (!needsFlush && pid > 0) {
        self.lastSyncedToTargetText = @"";
        [self.confirmedChipSet removeAllObjects];
        NSRunningApplication *targetApp = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        [targetApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            IMSendKeyToPid(pid, kVK_Return, 0);
        });
        return;
    }

    [self flushLocalEditsToTargetAndSend:YES];
}

- (void)flushLocalEditsToTargetAndSend:(BOOL)shouldSend {
    [self flushLocalEditsToTargetAndSend:shouldSend forceKeystrokeEvents:NO triggerLocation:NSNotFound autoConfirmSelection:NO];
}

- (void)flushLocalEditsToTargetAndSend:(BOOL)shouldSend
                  forceKeystrokeEvents:(BOOL)forceKeystrokes
                       triggerLocation:(NSUInteger)triggerLocation
                  autoConfirmSelection:(BOOL)autoConfirmSelection {
    if (self.syncInFlight) return;
    [self.liveSyncTimer invalidate];
    self.liveSyncTimer = nil;
    NSString *text = self.textView.string ?: @"";
    NSString *draftKey = [self currentDraftKey];
    NSArray<InputMirrorSyncSegment *> *segments = InputMirrorBuildSyncSegments(text, self.confirmedChipSet);
    BOOL hasNativeChips = IMSegmentsContainNativeChip(segments);
    if (shouldSend) {
        [self.confirmedChipSet removeAllObjects];
    }
    self.hasLocalEditsPendingSync = NO;

    AXUIElementRef element = self.targetElement ? (AXUIElementRef)CFRetain(self.targetElement) : NULL;
    pid_t pid = self.targetPID;
    if (!element || pid <= 0) {
        if (element) CFRelease(element);
        return;
    }

    self.syncInFlight = YES;
    NSRunningApplication *targetApp = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    [targetApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];

    // 1. Direct AXValue write + verify (skipped when handing off a native trigger or replaying native @/$ chips)
    if (!forceKeystrokes && !hasNativeChips) {
        AXError err = AXUIElementSetAttributeValue(element, kAXValueAttribute, (__bridge CFStringRef)text);
        BOOL verified = NO;
        if (err == kAXErrorSuccess) {
            NSString *readBack = IMAxReadTextValue(element, NULL);
            verified = [readBack isEqualToString:text];
        }

        if (verified) {
            CFRelease(element);
            [self clearDraftForKey:draftKey];
            self.lastSyncedToTargetText = shouldSend ? @"" : text;
            self.postSyncGraceUntil = NSProcessInfo.processInfo.systemUptime + 0.25;
            if (shouldSend) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    IMSendKeyToPid(pid, kVK_Return, 0);
                    self.syncInFlight = NO;
                });
            } else {
                self.syncInFlight = NO;
            }
            return;
        }
    }

    // 2. Fallback & Structured Chip Replayer for Electron/Web inputs (ZERO clipboard usage!):
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute, kCFBooleanTrue);
    CFRelease(element);

    NSTimeInterval settleDelay = 0.06 + MIN(0.40, (double)text.length * 0.0004);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.09 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        IMSendKeyToPid(pid, kVK_ANSI_A, kCGEventFlagMaskCommand);
        IMSendKeyToPid(pid, kVK_Delete, 0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            void (^finishSend)(void) = ^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(settleDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (shouldSend) {
                        IMSendKeyToPid(pid, kVK_Return, 0);
                        self.lastSyncedToTargetText = @"";
                    } else {
                        self.lastSyncedToTargetText = autoConfirmSelection ? @"" : text;
                    }
                    [self clearDraftForKey:draftKey];
                    self.postSyncGraceUntil = NSProcessInfo.processInfo.systemUptime + 0.30;
                    self.syncInFlight = NO;
                });
            };
            if (text.length == 0) {
                finishSend();
                return;
            }
            if (forceKeystrokes) {
                NSUInteger trigLoc = triggerLocation;
                if (trigLoc == NSNotFound || trigLoc >= text.length) {
                    InputMirrorSkillTrigger tailTrig = InputMirrorParseSkillTrigger(text, NSMakeRange(text.length, 0), NULL);
                    if (tailTrig.active) trigLoc = tailTrig.tokenRange.location;
                }
                if (trigLoc != NSNotFound && trigLoc < text.length) {
                    NSString *beforeTrig = [text substringToIndex:trigLoc];
                    NSString *trigOnly = [text substringWithRange:NSMakeRange(trigLoc, 1)];
                    NSString *afterTrig = (trigLoc + 1 < text.length) ? [text substringFromIndex:trigLoc + 1] : @"";
                    if (beforeTrig.length > 0) {
                        IMSendUnicodeTextToPidEx(pid, beforeTrig, NO);
                    }
                    IMSendUnicodeTextToPidEx(pid, trigOnly, YES);
                    if (afterTrig.length > 0) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.055 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            IMSendUnicodeTextToPidEx(pid, afterTrig, NO);
                            if (autoConfirmSelection) {
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.065 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                    IMSendKeyToPid(pid, kVK_Return, 0);
                                    finishSend();
                                });
                            } else {
                                finishSend();
                            }
                        });
                        return;
                    }
                    finishSend();
                    return;
                }
            }
            if (hasNativeChips) {
                IMReplaySyncSegmentsAtIndex(pid, segments, 0, ^{
                    finishSend();
                });
                return;
            }
            IMSendUnicodeTextToPidEx(pid, text, forceKeystrokes);
            finishSend();
        });
    });
}

@end
