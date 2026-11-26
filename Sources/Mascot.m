#import "Mascot.h"
#import "PanelTheme.h"
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#include <stdlib.h>

static NSString *gCustomAvatarDirectory = nil;
static NSString *gCustomAvatarName = nil;
static NSMutableDictionary<NSString *, NSImage *> *gAvatarImageCache = nil;
static NSUInteger gCustomAvatarRevision = 1;

static NSMutableDictionary<NSString *, NSImage *> *AvatarCache(void) {
    if (!gAvatarImageCache) gAvatarImageCache = [NSMutableDictionary dictionary];
    return gAvatarImageCache;
}

void MascotSetCustomAvatarDirectory(NSString *directory) {
    if (directory.length && ![gCustomAvatarDirectory isEqualToString:directory]) {
        gCustomAvatarDirectory = [directory copy];
        [AvatarCache() removeObjectForKey:@"custom"];
        gCustomAvatarRevision++;
    }
}

NSString *MascotCustomAvatarDirectory(void) {
    if (gCustomAvatarDirectory.length) return gCustomAvatarDirectory;
    NSString *envDir = NSProcessInfo.processInfo.environment[@"TASK_PANEL_DATA_DIR"];
    if (envDir.length) return envDir;
    return [NSHomeDirectory() stringByAppendingPathComponent:@".codex/task-manager"];
}

void MascotSetCustomAvatarName(NSString *name) {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    gCustomAvatarName = trimmed.length ? [trimmed copy] : nil;
}

NSString *MascotCustomAvatarName(void) {
    return gCustomAvatarName.length ? gCustomAvatarName : @"我的头像";
}

static NSString *CustomAvatarProcessedPath(void) {
    return [MascotCustomAvatarDirectory() stringByAppendingPathComponent:@"custom-avatar.png"];
}

static NSString *CustomAvatarOriginalPath(void) {
    return [MascotCustomAvatarDirectory() stringByAppendingPathComponent:@"custom-avatar-original.png"];
}

BOOL MascotHasCustomAvatar(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:CustomAvatarProcessedPath()];
}

BOOL MascotHasCustomAvatarOriginal(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:CustomAvatarOriginalPath()];
}

NSArray<NSDictionary *> *MascotCatalog(void) {
    return @[
        @{@"id":@"foreman",@"name":@"工头喵",@"description":@"安全帽一戴，今天也把进度安排明白。"},
        @{@"id":@"inspector",@"name":@"督督喵",@"description":@"眼镜后的小眼神，每一份交付都盯得很稳。"},
        @{@"id":@"fisher",@"name":@"摸鱼喵",@"description":@"把活交给 AI，把空闲留给自己。"},
        @{@"id":@"electric",@"name":@"闪电喵",@"description":@"耳机一戴，任务开跑；有结果就来报。"},
        @{@"id":@"fortune",@"name":@"发财喵",@"description":@"一件件收工，一点点攒下成就感。"},
        @{@"id":@"cosmic",@"name":@"星舰喵",@"description":@"巡航你的任务星球，把成果带回地面。"}
    ];
}

NSArray<NSDictionary *> *PresetAvatarCatalog(void) {
    return @[
        @{@"id":@"avatar_thumbsup",@"name":@"点赞搭子",@"image":@"avatar-thumbsup.png",@"description":@"竖起大拇指，稳稳接住每一项交付。"},
        @{@"id":@"avatar_sunny",@"name":@"元气搭子",@"image":@"avatar-sunny.png",@"description":@"笑容满格开跑，复杂任务也轻松拿下。"},
        @{@"id":@"avatar_aloha",@"name":@"松弛搭子",@"image":@"avatar-aloha.png",@"description":@"花衬衫一穿，从容盯盘不焦虑。"},
        @{@"id":@"avatar_bear",@"name":@"极客搭子",@"image":@"avatar-bear.png",@"description":@"黑框眼镜配小熊，细节逻辑全在线。"},
        @{@"id":@"avatar_polo",@"name":@"清爽搭子",@"image":@"avatar-polo.png",@"description":@"干净利落推进度，件件有着落。"},
        @{@"id":@"avatar_knitboy",@"name":@"暖绒搭子",@"image":@"avatar-knitboy.png",@"description":@"暖橙针织配微笑，温和稳妥把活干漂亮。"},
        @{@"id":@"avatar_foldcat",@"name":@"折耳喵",@"image":@"avatar-foldcat.png",@"description":@"圆眼乖巧蹲守桌面，安静陪你收工。"}
    ];
}

static NSDictionary *CustomAvatarDefinition(void) {
    return @{
        @"id": @"custom",
        @"name": MascotCustomAvatarName(),
        @"custom": @YES,
        @"description": @"自定义专属头像，浮窗、菜单栏与完成庆祝同步展示。"
    };
}

NSArray<NSDictionary *> *AllMascotCatalog(void) {
    NSMutableArray<NSDictionary *> *all = [NSMutableArray arrayWithArray:MascotCatalog()];
    [all addObjectsFromArray:PresetAvatarCatalog()];
    if (MascotHasCustomAvatar()) [all addObject:CustomAvatarDefinition()];
    return all;
}

NSDictionary *MascotDefinition(NSString *identifier) {
    if ([identifier isEqual:@"custom"] && MascotHasCustomAvatar()) {
        return CustomAvatarDefinition();
    }
    for (NSDictionary *entry in MascotCatalog()) {
        if ([entry[@"id"] isEqual:identifier]) return entry;
    }
    for (NSDictionary *entry in PresetAvatarCatalog()) {
        if ([entry[@"id"] isEqual:identifier]) return entry;
    }
    return MascotCatalog().firstObject;
}

static NSString *ResolvePresetAvatarPath(NSString *filename) {
    if (!filename.length) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *resPath = NSBundle.mainBundle.resourcePath;
    if (resPath.length) {
        [candidates addObject:[[resPath stringByAppendingPathComponent:@"avatars"] stringByAppendingPathComponent:filename]];
        [candidates addObject:[resPath stringByAppendingPathComponent:filename]];
    }
    NSString *execDir = NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent;
    if (execDir.length) {
        [candidates addObject:[[execDir stringByAppendingPathComponent:@"avatars"] stringByAppendingPathComponent:filename]];
        [candidates addObject:[[[execDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Resources/avatars"] stringByAppendingPathComponent:filename]];
        [candidates addObject:[[[execDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"assets/avatars"] stringByAppendingPathComponent:filename]];
    }
    NSString *cwd = fm.currentDirectoryPath;
    if (cwd.length) {
        [candidates addObject:[[cwd stringByAppendingPathComponent:@"assets/avatars"] stringByAppendingPathComponent:filename]];
        [candidates addObject:[[cwd stringByAppendingPathComponent:@"build/avatars"] stringByAppendingPathComponent:filename]];
    }
    [candidates addObject:[[NSHomeDirectory() stringByAppendingPathComponent:@".codex/bin/avatars"] stringByAppendingPathComponent:filename]];
    for (NSString *path in candidates) {
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

static NSImage *ResolvedAvatarBitmapImage(NSDictionary *definition) {
    NSString *identifier = definition[@"id"];
    if ([identifier isEqual:@"custom"]) {
        NSString *cacheKey = [NSString stringWithFormat:@"custom:%lu", (unsigned long)gCustomAvatarRevision];
        NSImage *cached = AvatarCache()[cacheKey];
        if (cached) return cached;
        NSString *path = CustomAvatarProcessedPath();
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data.length) return nil;
        NSImage *img = [[NSImage alloc] initWithData:data];
        if (img) AvatarCache()[cacheKey] = img;
        return img;
    }
    NSString *filename = definition[@"image"];
    if (!filename.length) return nil;
    NSImage *cached = AvatarCache()[identifier];
    if (cached) return cached;
    NSString *path = ResolvePresetAvatarPath(filename);
    if (!path.length) return nil;
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
    if (img) AvatarCache()[identifier] = img;
    return img;
}

// ==================== Background Removal & Normalization ====================

static CGImageRef CreateCGImageFromNSImage(NSImage *image) {
    if (!image) return NULL;
    NSRect rect = NSMakeRect(0, 0, image.size.width, image.size.height);
    CGImageRef cg = [image CGImageForProposedRect:&rect context:nil hints:nil];
    if (cg) return CGImageRetain(cg);
    return NULL;
}

static CGImageRef DownscaleCGImageIfNeeded(CGImageRef src, size_t maxDim) {
    if (!src) return NULL;
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (w <= maxDim && h <= maxDim) return CGImageRetain(src);
    CGFloat scale = (CGFloat)maxDim / (CGFloat)MAX(w, h);
    size_t nw = MAX((size_t)1, (size_t)llround(w * scale));
    size_t nh = MAX((size_t)1, (size_t)llround(h * scale));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, nw, nh, 8, nw * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return CGImageRetain(src);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, nw, nh), src);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out ?: CGImageRetain(src);
}

static BOOL ImageAlreadyHasTransparentCorners(const uint8_t *pixels, size_t w, size_t h) {
    if (w < 4 || h < 4) return NO;
    size_t coords[4][2] = {{0, 0}, {w - 1, 0}, {0, h - 1}, {w - 1, h - 1}};
    int transparentCount = 0;
    for (int i = 0; i < 4; i++) {
        size_t idx = (coords[i][1] * w + coords[i][0]) * 4;
        if (pixels[idx + 3] < 24) transparentCount++;
    }
    return transparentCount >= 3;
}

static BOOL MaskRemovedCornersAndKeptSubject(CGImageRef candidate) {
    if (!candidate) return NO;
    size_t w = CGImageGetWidth(candidate), h = CGImageGetHeight(candidate);
    if (w < 4 || h < 4) return NO;
    size_t count = w * h;
    uint8_t *buf = (uint8_t *)calloc(count * 4, 1);
    if (!buf) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NO; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), candidate);
    CGContextRelease(ctx);
    BOOL cornersTransparent = ImageAlreadyHasTransparentCorners(buf, w, h);
    size_t fg = 0;
    for (size_t i = 0; i < count; i++) {
        if (buf[i * 4 + 3] > 128) fg++;
    }
    free(buf);
    return cornersTransparent && (fg * 100 >= count * 2) && (fg * 100 <= count * 96);
}

static CGImageRef VisionForegroundCutoutCreate(CGImageRef cgImage) {
    if (!cgImage) return NULL;
    if (@available(macOS 14.0, *)) {
        Class reqClass = NSClassFromString(@"VNGenerateForegroundInstanceMaskRequest");
        if (!reqClass) return NULL;
        VNGenerateForegroundInstanceMaskRequest *request = [[reqClass alloc] init];
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];
        NSError *error = nil;
        if (![handler performRequests:@[request] error:&error] || !request.results.count) {
            return NULL;
        }
        VNInstanceMaskObservation *obs = request.results.firstObject;
        if (!obs.allInstances.count) return NULL;
        CVPixelBufferRef maskBuffer = [obs generateScaledMaskForImageForInstances:obs.allInstances fromRequestHandler:handler error:&error];
        if (!maskBuffer) return NULL;
        CIImage *ciInput = [CIImage imageWithCGImage:cgImage];
        CIImage *ciMask = [CIImage imageWithCVPixelBuffer:maskBuffer];
        CIFilter *blend = [CIFilter filterWithName:@"CIBlendWithMask"];
        [blend setValue:ciInput forKey:kCIInputImageKey];
        [blend setValue:[CIImage emptyImage] forKey:kCIInputBackgroundImageKey];
        [blend setValue:ciMask forKey:kCIInputMaskImageKey];
        CIImage *output = blend.outputImage;
        CGImageRef result = NULL;
        if (output) {
            CIContext *ciCtx = [CIContext contextWithOptions:nil];
            result = [ciCtx createCGImage:output fromRect:ciInput.extent];
        }
        CVPixelBufferRelease(maskBuffer);
        if (result && MaskRemovedCornersAndKeptSubject(result)) {
            return result;
        }
        if (result) CGImageRelease(result);
    }
    return NULL;
}

static CGImageRef FloodFillCutoutCreate(CGImageRef cgImage) {
    if (!cgImage) return NULL;
    size_t w = CGImageGetWidth(cgImage), h = CGImageGetHeight(cgImage);
    size_t count = w * h;
    if (w < 4 || h < 4) return CGImageRetain(cgImage);
    uint8_t *pixels = (uint8_t *)calloc(count * 4, 1);
    if (!pixels) return CGImageRetain(cgImage);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if (!ctx) { CGColorSpaceRelease(cs); free(pixels); return CGImageRetain(cgImage); }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImage);
    CGContextRelease(ctx);

    if (ImageAlreadyHasTransparentCorners(pixels, w, h)) {
        CGColorSpaceRelease(cs);
        free(pixels);
        return CGImageRetain(cgImage);
    }

    // Estimate background color by averaging the 4 corners
    size_t sampleCoords[8][2] = {
        {0, 0}, {w - 1, 0}, {0, h - 1}, {w - 1, h - 1},
        {MIN((size_t)2, w - 1), MIN((size_t)2, h - 1)},
        {w > 3 ? w - 3 : 0, MIN((size_t)2, h - 1)},
        {MIN((size_t)2, w - 1), h > 3 ? h - 3 : 0},
        {w > 3 ? w - 3 : 0, h > 3 ? h - 3 : 0}
    };
    int sumR = 0, sumG = 0, sumB = 0;
    for (int i = 0; i < 8; i++) {
        size_t idx = (sampleCoords[i][1] * w + sampleCoords[i][0]) * 4;
        sumR += pixels[idx];
        sumG += pixels[idx + 1];
        sumB += pixels[idx + 2];
    }
    int bgR = sumR / 8, bgG = sumG / 8, bgB = sumB / 8;
    BOOL lightNeutralBg = (MIN(bgR, MIN(bgG, bgB)) >= 182 && (MAX(bgR, MAX(bgG, bgB)) - MIN(bgR, MIN(bgG, bgB))) <= 20);
    const int tolerance = 32;

    uint8_t *visited = (uint8_t *)calloc(count, 1);
    uint8_t *bgMask = (uint8_t *)calloc(count, 1);
    size_t *queue = (size_t *)malloc(count * sizeof(size_t));
    if (!visited || !bgMask || !queue) {
        free(visited); free(bgMask); free(queue); free(pixels); CGColorSpaceRelease(cs);
        return CGImageRetain(cgImage);
    }
    size_t head = 0, tail = 0;

    #define IS_BG_PIXEL(idx4) ({ \
        int _pr = (int)pixels[(idx4)], _pg = (int)pixels[(idx4) + 1], _pb = (int)pixels[(idx4) + 2]; \
        int _dr = abs(_pr - bgR); \
        int _dg = abs(_pg - bgG); \
        int _db = abs(_pb - bgB); \
        int _m = MAX(_dr, MAX(_dg, _db)); \
        BOOL _checkerMatch = lightNeutralBg && (MIN(_pr, MIN(_pg, _pb)) >= 182) && ((MAX(_pr, MAX(_pg, _pb)) - MIN(_pr, MIN(_pg, _pb))) <= 20); \
        (pixels[(idx4) + 3] < 20) || (_m <= tolerance) || _checkerMatch; \
    })

    for (size_t x = 0; x < w; x++) {
        size_t top = x, bot = (h - 1) * w + x;
        if (!visited[top] && IS_BG_PIXEL(top * 4)) { visited[top] = 1; queue[tail++] = top; }
        if (!visited[bot] && IS_BG_PIXEL(bot * 4)) { visited[bot] = 1; queue[tail++] = bot; }
    }
    for (size_t y = 0; y < h; y++) {
        size_t left = y * w, right = y * w + (w - 1);
        if (!visited[left] && IS_BG_PIXEL(left * 4)) { visited[left] = 1; queue[tail++] = left; }
        if (!visited[right] && IS_BG_PIXEL(right * 4)) { visited[right] = 1; queue[tail++] = right; }
    }

    while (head < tail) {
        size_t cur = queue[head++];
        bgMask[cur] = 1;
        size_t cx = cur % w, cy = cur / w;
        if (cx > 0) { size_t n = cur - 1; if (!visited[n] && IS_BG_PIXEL(n * 4)) { visited[n] = 1; queue[tail++] = n; } }
        if (cx + 1 < w) { size_t n = cur + 1; if (!visited[n] && IS_BG_PIXEL(n * 4)) { visited[n] = 1; queue[tail++] = n; } }
        if (cy > 0) { size_t n = cur - w; if (!visited[n] && IS_BG_PIXEL(n * 4)) { visited[n] = 1; queue[tail++] = n; } }
        if (cy + 1 < h) { size_t n = cur + w; if (!visited[n] && IS_BG_PIXEL(n * 4)) { visited[n] = 1; queue[tail++] = n; } }
    }
    #undef IS_BG_PIXEL

    // Guard against over-erasing if almost entire image matched background
    size_t bgCount = 0;
    for (size_t i = 0; i < count; i++) if (bgMask[i]) bgCount++;
    if (bgCount * 100 >= count * 98) {
        free(visited); free(bgMask); free(queue); free(pixels); CGColorSpaceRelease(cs);
        return CGImageRetain(cgImage);
    }

    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            size_t i = y * w + x;
            if (bgMask[i]) {
                pixels[i * 4] = pixels[i * 4 + 1] = pixels[i * 4 + 2] = pixels[i * 4 + 3] = 0;
                continue;
            }
            if (x > 0 && x + 1 < w && y > 0 && y + 1 < h) {
                int bgNeighbors = bgMask[i - 1] + bgMask[i + 1] + bgMask[i - w] + bgMask[i + w];
                if (bgNeighbors > 0) {
                    int dr = abs((int)pixels[i * 4] - bgR);
                    int dg = abs((int)pixels[i * 4 + 1] - bgG);
                    int db = abs((int)pixels[i * 4 + 2] - bgB);
                    int dist = MAX(dr, MAX(dg, db));
                    if (dist < 64) {
                        int a = MIN(255, MAX(60, (dist - 16) * 5));
                        pixels[i * 4]     = (uint8_t)((pixels[i * 4] * a) / 255);
                        pixels[i * 4 + 1] = (uint8_t)((pixels[i * 4 + 1] * a) / 255);
                        pixels[i * 4 + 2] = (uint8_t)((pixels[i * 4 + 2] * a) / 255);
                        pixels[i * 4 + 3] = (uint8_t)a;
                    }
                }
            }
        }
    }

    CGContextRef outCtx = CGBitmapContextCreate(pixels, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef outImg = outCtx ? CGBitmapContextCreateImage(outCtx) : NULL;
    if (outCtx) CGContextRelease(outCtx);
    CGColorSpaceRelease(cs);
    free(visited);
    free(bgMask);
    free(queue);
    free(pixels);
    return outImg ?: CGImageRetain(cgImage);
}

static CGImageRef NormalizeAvatarSquareCreate(CGImageRef cgImage, BOOL circularCrop, size_t targetSize) {
    if (!cgImage) return NULL;
    size_t w = CGImageGetWidth(cgImage), h = CGImageGetHeight(cgImage);
    size_t count = w * h;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();

    if (circularCrop) {
        CGContextRef sqCtx = CGBitmapContextCreate(NULL, targetSize, targetSize, 8, targetSize * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(cs);
        if (!sqCtx) return CGImageRetain(cgImage);
        CGContextSetInterpolationQuality(sqCtx, kCGInterpolationHigh);
        CGFloat inset = 10.0;
        CGRect circle = CGRectMake(inset, inset, targetSize - inset * 2, targetSize - inset * 2);
        CGContextBeginPath(sqCtx);
        CGContextAddEllipseInRect(sqCtx, circle);
        CGContextClip(sqCtx);
        CGFloat scale = MAX(circle.size.width / (CGFloat)w, circle.size.height / (CGFloat)h);
        CGFloat dw = w * scale, dh = h * scale;
        CGFloat dx = CGRectGetMidX(circle) - dw / 2.0;
        CGFloat dy = CGRectGetMidY(circle) - dh / 2.0;
        CGContextDrawImage(sqCtx, CGRectMake(dx, dy, dw, dh), cgImage);
        CGImageRef out = CGBitmapContextCreateImage(sqCtx);
        CGContextRelease(sqCtx);
        return out;
    }

    uint8_t *pixels = (uint8_t *)calloc(count * 4, 1);
    if (!pixels) { CGColorSpaceRelease(cs); return CGImageRetain(cgImage); }
    CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if (!ctx) { free(pixels); CGColorSpaceRelease(cs); return CGImageRetain(cgImage); }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImage);
    CGContextRelease(ctx);

    size_t minX = w, minY = h, maxX = 0, maxY = 0;
    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            if (pixels[(y * w + x) * 4 + 3] > 16) {
                if (x < minX) minX = x;
                if (x > maxX) maxX = x;
                if (y < minY) minY = y;
                if (y > maxY) maxY = y;
            }
        }
    }
    free(pixels);

    CGImageRef cropped = NULL;
    if (minX < maxX && minY < maxY) {
        cropped = CGImageCreateWithImageInRect(cgImage, CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1));
    }
    if (!cropped) cropped = CGImageRetain(cgImage);

    CGContextRef sqCtx = CGBitmapContextCreate(NULL, targetSize, targetSize, 8, targetSize * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!sqCtx) return cropped;
    CGContextSetInterpolationQuality(sqCtx, kCGInterpolationHigh);
    CGFloat pad = 12.0;
    CGFloat avail = (CGFloat)targetSize - pad * 2.0;
    size_t cw = CGImageGetWidth(cropped), ch = CGImageGetHeight(cropped);
    CGFloat scale = MIN(avail / (CGFloat)MAX((size_t)1, cw), avail / (CGFloat)MAX((size_t)1, ch));
    CGFloat dw = cw * scale, dh = ch * scale;
    CGFloat dx = ((CGFloat)targetSize - dw) / 2.0;
    CGFloat dy = ((CGFloat)targetSize - dh) / 2.0;
    CGContextDrawImage(sqCtx, CGRectMake(dx, dy, dw, dh), cropped);
    CGImageRelease(cropped);
    CGImageRef out = CGBitmapContextCreateImage(sqCtx);
    CGContextRelease(sqCtx);
    return out;
}

static BOOL WriteCGImageAsPNG(CGImageRef cgImage, NSString *path, NSError **error) {
    if (!cgImage || !path.length) return NO;
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:error];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png.length) return NO;
    return [png writeToFile:path options:NSDataWritingAtomic error:error];
}

static BOOL ProcessCGImageIntoCustomAvatar(CGImageRef sourceCG, BOOL removeBackground, NSError **error) {
    if (!sourceCG) return NO;
    CGImageRef stage = NULL;
    if (removeBackground) {
        stage = VisionForegroundCutoutCreate(sourceCG);
        if (!stage) {
            stage = FloodFillCutoutCreate(sourceCG);
        }
    } else {
        stage = CGImageRetain(sourceCG);
    }
    BOOL hasTransparency = MaskRemovedCornersAndKeptSubject(stage);
    CGImageRef finalCG = NormalizeAvatarSquareCreate(stage, !removeBackground && !hasTransparency, 320);
    CGImageRelease(stage);
    if (!finalCG) return NO;
    BOOL ok = WriteCGImageAsPNG(finalCG, CustomAvatarProcessedPath(), error);
    CGImageRelease(finalCG);
    if (ok) {
        [AvatarCache() removeAllObjects];
        gCustomAvatarRevision++;
    }
    return ok;
}

BOOL MascotImportCustomAvatarFromURL(NSURL *url, BOOL removeBackground, NSError **error) {
    if (!url) return NO;
    NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
    CGImageRef rawCG = CreateCGImageFromNSImage(image);
    if (!rawCG) {
        if (error) {
            *error = [NSError errorWithDomain:@"CodexBuddyAvatar" code:1 userInfo:@{NSLocalizedDescriptionKey: @"无法读取所选图片文件"}];
        }
        return NO;
    }
    CGImageRef normalizedRaw = DownscaleCGImageIfNeeded(rawCG, 1024);
    CGImageRelease(rawCG);
    WriteCGImageAsPNG(normalizedRaw, CustomAvatarOriginalPath(), NULL);
    BOOL ok = ProcessCGImageIntoCustomAvatar(normalizedRaw, removeBackground, error);
    CGImageRelease(normalizedRaw);
    return ok;
}

BOOL MascotReprocessCustomAvatar(BOOL removeBackground, NSError **error) {
    NSString *origPath = MascotHasCustomAvatarOriginal() ? CustomAvatarOriginalPath() : CustomAvatarProcessedPath();
    if (![NSFileManager.defaultManager fileExistsAtPath:origPath]) return NO;
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:origPath];
    CGImageRef rawCG = CreateCGImageFromNSImage(image);
    if (!rawCG) return NO;
    BOOL ok = ProcessCGImageIntoCustomAvatar(rawCG, removeBackground, error);
    CGImageRelease(rawCG);
    return ok;
}

void MascotClearCustomAvatar(void) {
    [NSFileManager.defaultManager removeItemAtPath:CustomAvatarProcessedPath() error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:CustomAvatarOriginalPath() error:NULL];
    [AvatarCache() removeAllObjects];
    gCustomAvatarRevision++;
}

// ==================== Drawing & Views ====================

static NSColor *Hex(unsigned value) { return [NSColor colorWithSRGBRed:((value>>16)&255)/255.0 green:((value>>8)&255)/255.0 blue:(value&255)/255.0 alpha:1]; }
static NSColor *Ink(void) { return Hex(0x27303F); }
static void Shape(NSBezierPath *path, NSColor *fill, CGFloat stroke) {
    if (fill) { [fill setFill]; [path fill]; }
    if (stroke) { [Ink() setStroke]; path.lineWidth = stroke; path.lineJoinStyle = NSLineJoinStyleRound; [path stroke]; }
}
static void Round(CGFloat x, CGFloat y, CGFloat w, CGFloat h, CGFloat r, NSColor *fill, CGFloat stroke) {
    Shape([NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x,y,w,h) xRadius:r yRadius:r],fill,stroke);
}
static void Oval(CGFloat x, CGFloat y, CGFloat w, CGFloat h, NSColor *fill, CGFloat stroke) {
    Shape([NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x,y,w,h)],fill,stroke);
}
static void CatPolygon(NSArray<NSValue *> *points, NSColor *fill, CGFloat stroke) {
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:points.firstObject.pointValue];
    for (NSValue *point in [points subarrayWithRange:NSMakeRange(1,points.count-1)]) [path lineToPoint:point.pointValue];
    [path closePath]; Shape(path,fill,stroke);
}
#define P(x,y) [NSValue valueWithPoint:NSMakePoint((x),(y))]
static void Line(CGFloat x, CGFloat y, CGFloat endX, CGFloat endY, NSColor *color, CGFloat width) {
    NSBezierPath *path = [NSBezierPath bezierPath]; [path moveToPoint:NSMakePoint(x,y)]; [path lineToPoint:NSMakePoint(endX,endY)];
    path.lineWidth = width; path.lineCapStyle = NSLineCapStyleRound; [color setStroke]; [path stroke];
}
static void Smile(CGFloat x, CGFloat y, CGFloat size, BOOL closed) {
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(x-size,y)];
    [path curveToPoint:NSMakePoint(x+size,y) controlPoint1:NSMakePoint(x-size/2,y+(closed ? 6 : -5)) controlPoint2:NSMakePoint(x+size/2,y+(closed ? 6 : -5))];
    path.lineWidth = 2.8; path.lineCapStyle = NSLineCapStyleRound; [Ink() setStroke]; [path stroke];
}

void DrawMascot(NSString *identifier, NSRect rect, NSString *state) {
    NSDictionary *definition = MascotDefinition(identifier);
    NSImage *bitmapAvatar = ResolvedAvatarBitmapImage(definition);
    if (bitmapAvatar) {
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
        CGFloat side = MIN(rect.size.width, rect.size.height);
        NSRect target = NSMakeRect(NSMidX(rect) - side / 2.0, NSMidY(rect) - side / 2.0, side, side);
        if ([state isEqual:@"completed"] && side >= 40) {
            NSRect glow = NSInsetRect(target, side * 0.08, side * 0.08);
            [[Hex(0xFFD166) colorWithAlphaComponent:0.22] setFill];
            [[NSBezierPath bezierPathWithOvalInRect:glow] fill];
        }
        [bitmapAvatar drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:nil];
        [NSGraphicsContext restoreGraphicsState];
        return;
    }

    NSString *role = definition[@"id"];
    BOOL foreman = [role isEqual:@"foreman"], inspector = [role isEqual:@"inspector"], fisher = [role isEqual:@"fisher"];
    BOOL electric = [role isEqual:@"electric"], fortune = [role isEqual:@"fortune"], cosmic = [role isEqual:@"cosmic"];
    BOOL happy = [state isEqual:@"completed"];
    NSColor *fur = Hex(foreman ? 0xF2AE61 : inspector ? 0x8EA3B9 : fisher ? 0xFFF1DB : electric ? 0x45445F : fortune ? 0xFFE2A2 : 0xB6A5E4);
    NSColor *accent = Hex(foreman ? 0xFFC94A : inspector ? 0x6586EA : fisher ? 0x7FD7B6 : electric ? 0xA589F5 : fortune ? 0xE86161 : 0x89D8E8);
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    CGFloat scale = MIN(rect.size.width,rect.size.height)/128;
    [transform translateXBy:rect.origin.x+(rect.size.width-128*scale)/2 yBy:rect.origin.y+(rect.size.height-128*scale)/2];
    [transform scaleBy:scale]; [transform concat];
    Oval(28,4,73,9,[Ink() colorWithAlphaComponent:0.13],0);
    if (cosmic) Oval(7,26,114,100,[accent colorWithAlphaComponent:0.18],3);
    if (fisher) Oval(18,31,92,85,accent,3);
    Round(35,9,58,48,20,cosmic ? Hex(0xE4F2FA) : accent,3.2);
    // Thick, soft silhouettes remain readable in a 24-point floating avatar.
    CatPolygon(@[P(25,84),P(21,119),P(55,100)],fur,3.2);
    CatPolygon(@[P(76,100),P(107,119),P(103,82)],fur,3.2);
    CatPolygon(@[P(29,94),P(27,110),P(43,100)],Hex(0xE7A4A2),0);
    CatPolygon(@[P(87,100),P(101,110),P(99,94)],Hex(0xE7A4A2),0);
    Round(23,36,82,68,29,fur,3.2);
    if (!electric) Oval(36,37,56,33,Hex(0xFFF4E6),0);
    if (foreman) {
        Line(57,99,59,91,Hex(0xC87B3F),4); Line(70,99,68,91,Hex(0xC87B3F),4);
        Round(24,88,80,26,15,accent,3.2); Round(57,88,14,31,5,Hex(0xFFE9A4),2.5);
        Round(17,83,94,11,5,accent,3.2);
    } else if (inspector) {
        Round(27,99,74,15,8,Hex(0x3C526C),3); Oval(48,108,20,8,Hex(0x3C526C),0);
    } else if (fortune) {
        Round(32,92,65,10,4,accent,2.5);
        CatPolygon(@[P(64,108),P(72,100),P(64,92),P(56,100)],Hex(0xF8C651),2);
    }
    if (happy || fortune) { Smile(46,72,6,YES); Smile(82,72,6,YES); }
    else if (fisher) { Line(40,73,51,71,Ink(),3); Line(77,71,88,73,Ink(),3); }
    else { Oval(42,67,7,12,electric ? Hex(0xFFE798) : Ink(),0); Oval(79,67,7,12,electric ? Hex(0xFFE798) : Ink(),0); }
    if (inspector) {
        Shape([NSBezierPath bezierPathWithOvalInRect:NSMakeRect(32,61,26,26)],nil,3);
        Shape([NSBezierPath bezierPathWithOvalInRect:NSMakeRect(70,61,26,26)],nil,3);
        Line(58,73,70,73,Ink(),3);
    }
    if (electric) {
        NSBezierPath *band = [NSBezierPath bezierPath]; [band moveToPoint:NSMakePoint(21,69)];
        [band curveToPoint:NSMakePoint(107,69) controlPoint1:NSMakePoint(14,122) controlPoint2:NSMakePoint(114,122)];
        [accent setStroke]; band.lineWidth = 8; [band stroke];
        Round(16,59,12,26,5,accent,2.8); Round(100,59,12,26,5,accent,2.8);
        Line(105,61,96,53,accent,3); Oval(90,49,8,6,accent,0);
        CatPolygon(@[P(62,39),P(53,23),P(63,23),P(60,12),P(76,30),P(66,30),P(71,39)],Hex(0xFFE27A),1.8);
    }
    CatPolygon(@[P(59,61),P(69,61),P(64,56)],electric ? Hex(0xE8B8C7) : Hex(0xC67B7B),0);
    Smile(59,53,5,NO); Smile(69,53,5,NO);
    for (NSInteger side=0;side<2;side++) {
        CGFloat x = side ? 91 : 37, direction = side ? 1 : -1;
        Line(x,58,x+direction*13,61,[Ink() colorWithAlphaComponent:0.65],1.8);
        Line(x,53,x+direction*12,51,[Ink() colorWithAlphaComponent:0.65],1.8);
    }
    if (!electric) { Oval(31,60,11,6,[Hex(0xED9C99) colorWithAlphaComponent:0.6],0); Oval(87,60,11,6,[Hex(0xED9C99) colorWithAlphaComponent:0.6],0); }
    if (foreman || inspector) {
        Round(78,9,28,35,5,Hex(0xF7EDDB),2.7); Round(85,38,14,7,2,accent,1.8);
        Line(84,29,89,24,Hex(0x579D86),2.7); Line(89,24,99,33,Hex(0x579D86),2.7);
        Oval(70,15,14,12,fur,2.5);
    } else if (fisher) {
        Oval(51,13,46,22,Hex(0x90BDD6),2.8);
        CatPolygon(@[P(53,25),P(38,33),P(39,13)],Hex(0x90BDD6),2.8);
        Oval(84,23,3,3,Ink(),0); Line(65,17,65,29,Hex(0x5A8EA7),2);
        Oval(44,8,16,12,fur,2.5);
    } else if (fortune) {
        CatPolygon(@[P(44,42),P(84,42),P(72,31),P(60,26)],accent,2);
        Oval(59,7,34,34,Hex(0xFFD36C),2.8); Oval(66,14,20,20,Hex(0xF3B64A),1.5);
        Round(73,19,6,9,1,Hex(0xFFF1AD),0); Oval(48,12,15,12,fur,2.5);
    } else if (cosmic) {
        Round(29,32,70,12,6,Hex(0xDBF5F7),3);
        Oval(53,17,13,9,accent,2); Oval(74,18,7,7,Hex(0xF2C064),0);
        NSBezierPath *shine = [NSBezierPath bezierPath]; [shine moveToPoint:NSMakePoint(17,80)];
        [shine curveToPoint:NSMakePoint(31,108) controlPoint1:NSMakePoint(17,91) controlPoint2:NSMakePoint(22,101)];
        [Hex(0xE2FAFF) setStroke]; shine.lineWidth = 4; shine.lineCapStyle = NSLineCapStyleRound; [shine stroke];
        Oval(101,50,14,22,Hex(0xD1EDF2),2.7);
    }
    [NSGraphicsContext restoreGraphicsState];
}

NSImage *MascotImage(NSString *identifier, CGFloat size) {
    return [NSImage imageWithSize:NSMakeSize(size,size) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        DrawMascot(identifier,rect,@"idle"); return YES;
    }];
}

@implementation MascotAvatarView
- (void)drawRect:(NSRect)dirtyRect { DrawMascot(self.mascotID,self.bounds,self.state); }
@end

@implementation MascotChoiceButton
- (BOOL)isFlipped { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    BOOL compact = self.bounds.size.height < 100.0;
    CGFloat radius = compact ? 11.0 : 14.0;
    NSColor *accent = PanelColor(0x855315,0xe8bc72,1);
    NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:radius yRadius:radius];
    NSColor *fill = self.highlighted ? PanelColor(0xe5e9f0,0x383838,1) : PanelColor(0xffffff,0x242424,1);
    [(self.chosen ? [accent colorWithAlphaComponent:0.11] : fill) setFill]; [card fill];
    if (self.uploadPlaceholder && !MascotHasCustomAvatar()) {
        CGFloat dash[2] = {4.0, 3.0};
        [card setLineDash:dash count:2 phase:0];
        [PanelColor(0x94a3b8, 0x525b6b, 1.0) setStroke];
        card.lineWidth = 1.1;
        [card stroke];
        CGFloat circleSize = compact ? 36.0 : 52.0;
        CGFloat cy = compact ? 29.0 : 48.0;
        CGFloat cx = (self.bounds.size.width - circleSize) / 2.0;
        NSBezierPath *badge = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx, cy, circleSize, circleSize)];
        [[accent colorWithAlphaComponent:0.12] setFill];
        [badge fill];
        CGFloat midX = NSMidX(self.bounds), midY = cy + circleSize / 2.0;
        Line(midX - 7, midY, midX + 7, midY, accent, 2.0);
        Line(midX, midY - 7, midX, midY + 7, accent, 2.0);
        NSString *title = @"上传头像";
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:compact ? 11.5 : 13.0 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: NSColor.secondaryLabelColor
        };
        NSSize sz = [title sizeWithAttributes:attrs];
        [title drawAtPoint:NSMakePoint((self.bounds.size.width - sz.width) / 2.0, compact ? 7.0 : 17.0) withAttributes:attrs];
        return;
    }
    [(self.chosen ? accent : PanelColor(0xd3d9e2,0x454545,1)) setStroke];
    card.lineWidth = self.chosen ? 1.6 : 0.6;
    [card stroke];
    BOOL narrow = self.bounds.size.width < 88.0;
    CGFloat artSize = compact ? (narrow ? 45.0 : 48.0) : 76.0;
    CGFloat artY = compact ? 25.0 : 38.0;
    DrawMascot(self.mascotID, NSMakeRect((self.bounds.size.width - artSize) / 2.0, artY, artSize, artSize), @"idle");
    NSDictionary *definition = MascotDefinition(self.mascotID);
    NSString *title = definition[@"name"];
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:compact ? (narrow ? 11.0 : 11.5) : 13.0 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: self.chosen ? accent : NSColor.labelColor
    };
    NSSize size = [title sizeWithAttributes:attributes];
    [title drawAtPoint:NSMakePoint((self.bounds.size.width - size.width) / 2.0, compact ? 6.5 : 17.0) withAttributes:attributes];
    if (self.chosen) {
        CGFloat x = self.bounds.size.width - (compact ? 13 : 17), y = self.bounds.size.height - (compact ? 13 : 17);
        CGFloat r = compact ? 6.0 : 7.0;
        Oval(x - r, y - r, r * 2, r * 2, accent, 0);
        NSColor *check = PanelColor(0xffffff,0x27303f,1);
        Line(x - 2.6, y, x - 0.4, y - 2.4, check, 1.5);
        Line(x - 0.4, y - 2.4, x + 3.4, y + 2.5, check, 1.5);
    }
}
@end

@implementation MascotGalleryView
- (void)drawRect:(NSRect)dirtyRect {
    [Hex(0x181C23) setFill]; NSRectFill(self.bounds);
    [@"今天，谁来陪你盯进度？" drawAtPoint:NSMakePoint(32,570) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:26 weight:NSFontWeightSemibold],NSForegroundColorAttributeName:Hex(0xF1EADF)}];
    [@"工头喵小队与精选头像  /  随时换班或上传专属形象" drawAtPoint:NSMakePoint(34,542) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13],NSForegroundColorAttributeName:Hex(0x9DA8B7)}];
    NSArray<NSDictionary *> *roles = [MascotCatalog() arrayByAddingObjectsFromArray:PresetAvatarCatalog()];
    NSInteger index = 0;
    for (NSDictionary *role in roles) {
        NSInteger col = index % 5, row = index / 5; index++;
        NSRect card = NSMakeRect(24 + col * 172, 378 - row * 170, 158, 152);
        Round(card.origin.x, card.origin.y, card.size.width, card.size.height, 16, Hex(0x232A34), 0);
        DrawMascot(role[@"id"], NSMakeRect(NSMidX(card) - 44, card.origin.y + 46, 88, 88), @"idle");
        NSString *name = role[@"name"];
        NSDictionary *attributes = @{NSFontAttributeName:[NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold],NSForegroundColorAttributeName:Hex(0xF1EADF)};
        CGFloat width = [name sizeWithAttributes:attributes].width;
        [name drawAtPoint:NSMakePoint(NSMidX(card) - width / 2, card.origin.y + 16) withAttributes:attributes];
    }
}
@end
