#import "Celebration.h"
#import "PanelTheme.h"

const CGFloat CelebrationArtworkCornerRadius = 36;
const NSInteger CelebrationRandomStyle = -1;
static const NSInteger FirstInteractiveStyle = 5;

NSArray<NSString *> *CelebrationStyleTitles(void) {
    return @[@"像素通关", @"金币到账", @"火箭交付", @"宝箱开箱", @"升级时刻",
        @"猫爪盖章", @"星座连线", @"气泡派对", @"纸飞机巡游", @"小鱼追光"];
}

static BOOL InteractiveStyle(NSInteger style) { return style >= FirstInteractiveStyle; }

NSInteger CelebrationPlaybackStyle(NSInteger selection, NSInteger previous) {
    if (selection != CelebrationRandomStyle) return selection;
    NSInteger count = (NSInteger)CelebrationStyleTitles().count;
    if (previous < 0 || previous >= count) return arc4random_uniform((uint32_t)count);
    NSInteger choice = arc4random_uniform((uint32_t)(count - 1));
    return choice >= previous ? choice + 1 : choice;
}

NSRect CelebrationOverlayFrame(NSRect visibleFrame) {
    CGFloat width = MIN(440, NSWidth(visibleFrame) * 0.85);
    CGFloat height = MIN(340, NSHeight(visibleFrame) * 0.85);
    CGFloat centerY = NSMaxY(visibleFrame) - NSHeight(visibleFrame) / 3;
    CGFloat y = MIN(centerY - height / 2, NSMaxY(visibleFrame) - height);
    return NSMakeRect(NSMidX(visibleFrame) - width / 2, y, width, height);
}

NSArray<NSString *> *CelebrationMessages(void) {
    static NSArray<NSString *> *messages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        messages = @[
            @"搞定，撒花！",
            @"这题，拿下！",
            @"叮！成果出炉",
            @"收工铃响啦",
            @"漂亮，这就成了",
            @"又一件事落地啦",
            @"进度条到站！",
            @"你的成果已送达",
            @"今天也有小胜利",
            @"好啦，轮到你看啦",
            @"小齿轮转出成果啦",
            @"灵感已落地",
            @"这一局，完成！",
            @"成功抵达终点",
            @"给这次完成鼓个掌",
            @"又翻过一座小山",
            @"待办清单瘦了一点",
            @"这颗星，点亮了",
            @"本轮顺利收尾",
            @"完成的快乐加一",
            @"新鲜成果，趁热看",
            @"这份成果刚出炉",
            @"叮咚，结果到门口",
            @"你的快递叫成果",
            @"签收一份小成就",
            @"成果已装盘",
            @"给你端上来啦",
            @"小小成果，请查收",
            @"这道菜可以上桌啦",
            @"结果热乎着呢",
            @"小旗子，插上了",
            @"又解锁一个完成",
            @"今天的勾勾加一",
            @"这格进度，点亮！",
            @"待办星球少颗石头",
            @"小目标已抵达",
            @"这一站，完成站",
            @"向前挪了一大步",
            @"你的进度长大了",
            @"小成就到账啦",
            @"脑洞已经变成果",
            @"想法有着落啦",
            @"把灵感接住了",
            @"这点子，落地啦",
            @"从想法走到结果",
            @"这一笔，画完啦",
            @"这块拼图拼好了",
            @"散落的线头收好啦",
            @"故事又写完一段",
            @"空白处长出成果啦",
            @"撒一把电子礼花",
            @"给努力比个耶",
            @"这次值得小庆祝",
            @"掌声可以响起来了",
            @"成就感冒泡啦",
            @"开心可以加一格",
            @"给今天添颗糖",
            @"完成的风吹来啦",
            @"小快乐已上线",
            @"这一刻，值得撒花",
            @"勤劳小引擎到站",
            @"小助手交卷啦",
            @"本轮忙碌已收尾",
            @"小齿轮可以歇歇啦",
            @"这趟旅程到站啦",
            @"任务小船靠岸啦",
            @"成果小火车进站啦",
            @"你的搭子交作业啦",
            @"这一棒，交给你啦",
            @"好了，等你来检阅",
            @"看，成果冒头了",
            @"刚刚又搞定一件事",
            @"这回可以打个勾啦",
            @"小事大事，搞定一件",
            @"来收一朵完成小花",
            @"给待办画个小句号",
            @"又多一件开心事",
            @"这份结果有啦",
            @"这一步，走完啦",
            @"一件件来，这件成啦",
            @"成果雷达有回音啦",
            @"完成信号已点亮",
            @"叮！收到完成信号",
            @"小灯亮了，快来看看",
            @"有结果啦，快来瞧瞧",
            @"成果在这里招手",
            @"这一份，准备好啦",
            @"结果等你来揭晓",
            @"你的成果闪亮登场",
            @"舞台交给成果啦",
            @"这颗待办摘下来啦",
            @"小山丘又越过一座",
            @"这一页，可以翻啦",
            @"小句号圆满落下",
            @"这块积木搭好啦",
            @"完成拼图又添一块",
            @"忙碌终于开出花啦",
            @"你点的成果上桌啦",
            @"又攒下一点成就感",
            @"叮，来领完成小红花",
            @"生命不息，牛马不停",
            @"这一单干完，先嚼口草",
            @"草料没涨，业务量涨了",
            @"牛马也有高光时刻",
            @"工牌还在，灵魂下班了",
            @"活干完了，人先放空",
            @"今日草料，靠这单换",
            @"缰绳松一格，喘口气",
            @"生产队的驴申请下线",
            @"工位耐力赛，又赢一局",
            @"干完了，奶茶续上",
            @"老板画饼，工头喵交卷",
            @"饼先放着，成果趁热",
            @"这单有结果，奖金再议",
            @"本轮交差，功德加一",
            @"已完成，离退休又近一步",
            @"钱包没鼓，进度条圆满了",
            @"工资按月，成就感按件",
            @"本单交付，精神奖金到账",
            @"今天的 KPI 可以喘气了",
            @"下班的风，吹了一秒",
            @"任务做完了，轮到鱼紧张了",
            @"忙里偷闲，偷到了三秒",
            @"工位局赢了，午休局待定",
            @"干完了，允许发呆十秒",
            @"咖啡见底，成果到手",
            @"活干完了，咖啡还在续命",
            @"一口冰美式，送走一件事",
            @"奶茶还没到，活先好了",
            @"这事终于不用带回梦里做",
            @"已交付，今天少叹一口气",
            @"待办少一条，头发保一根",
            @"脑袋冒烟，结果没糊",
            @"成果请查收，灵魂请稍候",
            @"交完了，祈祷没人回「再改改」",
            @"今日搬砖，砖已砌好",
            @"砖搬完了，腰还在",
            @"打工副本结算，掉落一杯奶茶",
            @"又活过一轮需求变更",
            @"这版能跑，先别碰它",
            @"终于轮到进度条下班",
            @"Bug 下班了，我再坐会儿",
            @"电脑说圆满完成，我说腿麻",
            @"上线平安，今晚能睡",
            @"工头喵已完工，尾巴申请休假",
            @"猫没摸鱼，猫只是盯着鱼",
            @"猫拍了拍你，交卷啦",
            @"收工，猫爪从键盘撤离",
            @"请给这只牛马一个罐头",
            @"今晚的梦，禁止开会",
        ];
    });
    return messages;
}

NSString *CelebrationRandomMessage(NSString *previous) {
    NSArray<NSString *> *messages = CelebrationMessages();
    NSUInteger previousIndex = previous ? [messages indexOfObject:previous] : NSNotFound;
    NSUInteger index = previousIndex == NSNotFound
        ? arc4random_uniform((uint32_t)messages.count)
        : (previousIndex+1+arc4random_uniform((uint32_t)messages.count-1))%messages.count;
    return messages[index];
}

static NSVisualEffectView *CelebrationGlass(NSRect frame, NSVisualEffectBlendingMode mode) {
    NSVisualEffectView *glass = [[NSVisualEffectView alloc] initWithFrame:frame];
    glass.material = NSVisualEffectMaterialHUDWindow;
    glass.blendingMode = mode;
    glass.state = NSVisualEffectStateActive;
    glass.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    glass.wantsLayer = YES;
    CGFloat radiusX = CelebrationArtworkCornerRadius*frame.size.width/600;
    CGFloat radiusY = CelebrationArtworkCornerRadius*frame.size.height/460;
    glass.layer.cornerRadius = MIN(radiusX,radiusY);
    glass.layer.masksToBounds = YES;
    // NSVisualEffectView composites its backdrop separately. Give it the same
    // rounded mask as the painted scene so blur cannot extend into the corners.
    glass.maskImage = [NSImage imageWithSize:frame.size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [NSColor.whiteColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radiusX yRadius:radiusY] fill];
        return YES;
    }];
    return glass;
}

@interface CelebrationView ()
@property(strong) NSTrackingArea *pointerTracking;
@end

static NSPoint FollowPointer(NSPoint center, NSValue *pointer, CGFloat distance) {
    if (!pointer) return center;
    NSPoint target = pointer.pointValue;
    CGFloat dx = target.x - center.x, dy = target.y - center.y;
    return NSMakePoint(center.x + distance * tanh(dx/150), center.y + distance * 0.65 * tanh(dy/110));
}

@implementation CelebrationView
- (BOOL)isOpaque { return NO; }
- (NSString *)completionMessage { return self.message ?: CelebrationMessages().firstObject; }

// Each effect uses normalized time, including its entrance and exit.
- (CGFloat)progress {
    return self.stillFrame ? 0.5 : MIN(1, MAX(0, (CACurrentMediaTime()-self.startTime)/self.duration));
}
- (CGFloat)effectOpacity { return 1; }
- (NSColor *)accentColor {
    return self.palette == 1
        ? [NSColor colorWithCalibratedRed:0.43 green:0.86 blue:0.90 alpha:1]
        : [NSColor colorWithCalibratedRed:0.98 green:0.77 blue:0.39 alpha:1];
}
- (NSColor *)inkColor {
    return [NSColor colorWithCalibratedRed:0.96 green:0.96 blue:0.99 alpha:1];
}
- (void)drawGameCard {
    [[NSColor colorWithCalibratedRed:0.105 green:0.13 blue:0.20 alpha:0.9] setFill];
    NSRectFill(self.bounds);
}
- (void)drawTitle:(NSString *)title at:(NSPoint)center font:(NSFont *)font color:(NSColor *)color {
    CGFloat maxWidth = MIN(400,self.bounds.size.width*0.72);
    CGFloat textWidth = [title sizeWithAttributes:@{NSFontAttributeName:font}].width;
    if (textWidth > maxWidth) font = [NSFontManager.sharedFontManager convertFont:font toSize:font.pointSize*maxWidth/textWidth];
    NSDictionary *attributes = @{NSFontAttributeName:font,
        NSForegroundColorAttributeName:[color colorWithAlphaComponent:[self effectOpacity]]};
    NSSize size = [title sizeWithAttributes:attributes];
    [title drawAtPoint:NSMakePoint(center.x-size.width/2,center.y-size.height/2) withAttributes:attributes];
}

- (void)drawPixel {
    CGFloat opacity = [self effectOpacity];
    CGFloat p = [self progress];
    CGFloat reveal = self.reducedMotion ? 1 : MIN(1,p/0.4);
    NSPoint center = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
    NSColor *accent = [self accentColor];
    NSArray<NSString *> *pixels = @[@"000000001",@"000000011",@"100000110",@"110001100",@"011011000",@"001110000",@"000100000"];
    [[accent colorWithAlphaComponent:opacity] setFill];
    for (NSInteger row=0;row<7;row++) {
        for (NSInteger col=0;col<9;col++) {
            if ([pixels[row] characterAtIndex:col] == '1' && col <= reveal*9)
                NSRectFill(NSMakeRect(center.x-36+col*8,center.y+60-row*8,7,7));
        }
    }
    [self drawTitle:[self completionMessage] at:NSMakePoint(center.x,center.y-21)
        font:[NSFont monospacedSystemFontOfSize:25 weight:NSFontWeightBold] color:[self inkColor]];
    NSInteger blocks = (NSInteger)round(reveal*16);
    for (NSInteger i=0;i<16;i++) {
        [[accent colorWithAlphaComponent:opacity*(i<blocks ? 0.9 : 0.12)] setFill];
        NSRectFill(NSMakeRect(center.x-111+i*14,center.y-67,12,7));
    }
    for (NSInteger i=0;i<(NSInteger)(16*self.intensity);i++) {
        CGFloat angle = i*2.39996323;
        CGFloat distance = 135+(i%4)*16+(self.reducedMotion ? 0 : p*20);
        [[accent colorWithAlphaComponent:opacity*0.5] setFill];
        NSRectFill(NSMakeRect(center.x+cos(angle)*distance*1.2,center.y+sin(angle)*distance,4,4));
    }
}

- (void)drawPixels:(NSArray<NSString *> *)rows at:(NSPoint)origin size:(CGFloat)size color:(NSColor *)color {
    [[color colorWithAlphaComponent:[self effectOpacity]] setFill];
    for (NSUInteger row=0;row<rows.count;row++) {
        for (NSUInteger column=0;column<rows[row].length;column++) {
            if ([rows[row] characterAtIndex:column] == '1')
                NSRectFill(NSMakeRect(origin.x+column*size,origin.y-row*size,size,size));
        }
    }
}
- (void)drawCoinAt:(NSPoint)point size:(CGFloat)size motion:(CGFloat)motion {
    CGFloat stretch = self.reducedMotion ? 1 : 0.35+0.65*fabs(cos(motion*M_PI*3));
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:point.x yBy:point.y];
    [transform scaleXBy:stretch yBy:1];
    [transform concat];
    [self drawPixels:@[@"00111100",@"01111110",@"11111111",@"11111111",@"11111111",@"11111111",@"01111110",@"00111100"]
        at:NSMakePoint(-4*size,4*size) size:size color:[self accentColor]];
    [self drawPixels:@[@"11",@"10",@"11",@"01",@"11"] at:NSMakePoint(-size,2*size) size:size
        color:[NSColor colorWithCalibratedRed:0.36 green:0.22 blue:0.08 alpha:1]];
    [NSGraphicsContext restoreGraphicsState];
}
- (void)drawCoins {
    NSPoint center = NSMakePoint(NSMidX(self.bounds),NSMidY(self.bounds));
    CGFloat motion = self.reducedMotion ? 0.5 : [self progress];
    for (NSInteger i=0;i<8;i++) {
        CGFloat x = center.x+(i-3.5)*44;
        CGFloat y = center.y+100-fmod(motion*150+i*31,150);
        [self drawCoinAt:NSMakePoint(x,y) size:2.5 motion:motion+i*0.17];
    }
    [self drawCoinAt:NSMakePoint(center.x,center.y+15) size:9 motion:motion];
    [self drawTitle:[self completionMessage] at:NSMakePoint(center.x,center.y-95)
        font:[NSFont systemFontOfSize:29 weight:NSFontWeightBold] color:[self inkColor]];
}
- (void)drawRocket {
    NSPoint center = NSMakePoint(NSMidX(self.bounds),NSMidY(self.bounds));
    CGFloat motion = self.reducedMotion ? 0.5 : [self progress];
    CGFloat lift = self.reducedMotion ? 15 : 60*(1-pow(1-motion,2));
    CGFloat x = center.x-40, y = center.y+50+lift;
    NSColor *body = [NSColor colorWithCalibratedRed:0.42 green:0.50 blue:0.69 alpha:1];
    [self drawPixels:@[@"00011000",@"00111100",@"00111100",@"01111110",@"01111110",@"01111110",@"11111111",@"11011011"]
        at:NSMakePoint(x,y) size:10 color:body];
    [self drawPixels:@[@"11",@"11"] at:NSMakePoint(center.x-10,y-30) size:10 color:[self accentColor]];
    CGFloat flame = self.reducedMotion ? 12 : 10+8*pow(sin(motion*30),2);
    [[self.accentColor colorWithAlphaComponent:[self effectOpacity]] setFill];
    NSRectFill(NSMakeRect(center.x-10,y-80-flame,20,flame));
    for (NSInteger i=0;i<18;i++) {
        CGFloat offset = self.reducedMotion ? 0 : fmod(motion*150+i*17,160);
        CGFloat starX = center.x+sin(i*127.1)*165;
        CGFloat starY = center.y+100-offset;
        [[self.accentColor colorWithAlphaComponent:[self effectOpacity]*0.65] setFill];
        NSRectFill(NSMakeRect(starX,starY,3,7));
    }
    [self drawTitle:[self completionMessage] at:NSMakePoint(center.x,center.y-100)
        font:[NSFont systemFontOfSize:29 weight:NSFontWeightBold] color:[self inkColor]];
}
- (void)drawChest {
    NSPoint center = NSMakePoint(NSMidX(self.bounds),NSMidY(self.bounds));
    CGFloat motion = self.reducedMotion ? 0.7 : [self progress];
    CGFloat opening = self.reducedMotion ? 1 : MIN(1,MAX(0,(motion-0.12)/0.25));
    CGFloat opacity = [self effectOpacity];
    NSColor *wood = [NSColor colorWithCalibratedRed:0.56 green:0.26 blue:0.12 alpha:1];
    [self drawPixels:@[@"11111111111111",@"11111111111111",@"11111111111111",@"11111111111111",@"11111111111111",@"11111111111111"]
        at:NSMakePoint(center.x-70,center.y+5) size:10 color:wood];
    [[self.accentColor colorWithAlphaComponent:opacity] setFill];
    NSRectFill(NSMakeRect(center.x-70,center.y-55,140,10));
    NSRectFill(NSMakeRect(center.x-60,center.y-45,10,50));
    NSRectFill(NSMakeRect(center.x+50,center.y-45,10,50));
    [self drawPixels:@[@"01111111111110",@"11111111111111",@"11111111111111",@"11111111111111"]
        at:NSMakePoint(center.x-70,center.y+45+opening*38) size:10 color:wood];
    [[self.accentColor colorWithAlphaComponent:opacity] setFill];
    NSRectFill(NSMakeRect(center.x-70,center.y+15+opening*38,140,10));
    NSRectFill(NSMakeRect(center.x-10,center.y-15,20,25));
    for (NSInteger i=0;i<7;i++) {
        CGFloat angle = M_PI*(0.12+i*0.125);
        CGFloat distance = opening*(75+i%3*20);
        [self drawCoinAt:NSMakePoint(center.x+cos(angle)*distance,center.y+30+sin(angle)*distance) size:2.2 motion:motion+i];
    }
    [self drawTitle:[self completionMessage] at:NSMakePoint(center.x,center.y-105)
        font:[NSFont systemFontOfSize:29 weight:NSFontWeightBold] color:[self inkColor]];
}
- (void)drawLevelUp {
    NSPoint center = NSMakePoint(NSMidX(self.bounds),NSMidY(self.bounds));
    CGFloat motion = self.reducedMotion ? 0.6 : [self progress];
    CGFloat growth = self.reducedMotion ? 1 : 0.65+0.35*MIN(1,motion/0.3);
    CGFloat size = 10*growth;
    [self drawPixels:@[@"000010000",@"000111000",@"111111111",@"011111110",@"001111100",@"011111110",@"011101110",@"110000011"]
        at:NSMakePoint(center.x-4.5*size,center.y+80) size:size color:[self accentColor]];
    [self drawPixels:@[@"00100",@"01110",@"11111",@"00100"]
        at:NSMakePoint(center.x-15,center.y+118) size:6 color:[self inkColor]];
    for (NSInteger i=0;i<20;i++) {
        CGFloat angle = i*M_PI*2/20;
        CGFloat radius = 65+(self.reducedMotion ? 0 : motion*60);
        [[self.accentColor colorWithAlphaComponent:[self effectOpacity]*(1-i%3*0.15)] setFill];
        NSRectFill(NSMakeRect(center.x+cos(angle)*radius,center.y+40+sin(angle)*radius*0.7,5,5));
    }
    NSInteger filled = self.reducedMotion ? 18 : MIN(18,(NSInteger)(motion*45));
    for (NSInteger i=0;i<18;i++) {
        [[self.accentColor colorWithAlphaComponent:[self effectOpacity]*(i<filled ? 1 : 0.15)] setFill];
        NSRectFill(NSMakeRect(center.x-108+i*12,center.y-38,10,8));
    }
    [self drawTitle:[self completionMessage] at:NSMakePoint(center.x,center.y-82)
        font:[NSFont systemFontOfSize:29 weight:NSFontWeightBold] color:[self inkColor]];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.pointerTracking) [self removeTrackingArea:self.pointerTracking];
    self.pointerTracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingInVisibleRect|NSTrackingActiveInKeyWindow|NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited
        owner:self userInfo:nil];
    [self addTrackingArea:self.pointerTracking];
}
- (void)redrawForPointer {
    if (InteractiveStyle(self.style) && !self.reducedMotion) [self setNeedsDisplay:YES];
}
- (void)mouseEntered:(NSEvent *)event { [self redrawForPointer]; }
- (void)mouseMoved:(NSEvent *)event { [self redrawForPointer]; }
- (void)mouseExited:(NSEvent *)event { [self redrawForPointer]; }
- (NSValue *)pointerInEffect {
    if (!self.window.visible) return nil;
    NSPoint inWindow = [self.window convertPointFromScreen:NSEvent.mouseLocation];
    NSPoint point = [self convertPoint:inWindow fromView:nil];
    return NSPointInRect(point, self.bounds) ? [NSValue valueWithPoint:point] : nil;
}
- (void)drawEllipseAt:(NSPoint)point width:(CGFloat)width height:(CGFloat)height color:(NSColor *)color {
    [color setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x-width/2,point.y-height/2,width,height)] fill];
}
- (void)drawSparkleAt:(NSPoint)point size:(CGFloat)size color:(NSColor *)color {
    [self drawPixels:@[@"00100",@"00100",@"11111",@"00100",@"00100"]
        at:NSMakePoint(point.x-2.5*size, point.y+1.5*size) size:size color:color];
}
- (void)drawPawAt:(NSPoint)point scale:(CGFloat)scale color:(NSColor *)color {
    [self drawEllipseAt:point width:66*scale height:45*scale color:color];
    for (NSInteger i=0; i<4; i++) {
        CGFloat offset = i-1.5;
        NSPoint toe = NSMakePoint(point.x+offset*24*scale, point.y+(40-fabs(offset)*8)*scale);
        [self drawEllipseAt:toe width:19*scale height:26*scale color:color];
    }
}
- (void)drawPawStampAt:(NSPoint)center time:(CGFloat)time pointer:(NSValue *)pointer {
    NSColor *accent = self.accentColor;
    NSPoint stamp = FollowPointer(center, pointer, 105);
    for (NSInteger i=0; i<4; i++) {
        CGFloat x = center.x - 164 + i*108;
        CGFloat y = center.y + ((i%2) ? 48 : -48);
        CGFloat alpha = (0.2 + 0.12 * sin((time+i*0.13)*2*M_PI)) * self.intensity;
        [self drawPawAt:NSMakePoint(x,y) scale:0.43 color:[accent colorWithAlphaComponent:MIN(1,alpha)]];
    }
    CGFloat size = 102 + 10*sin(time*M_PI);
    NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(stamp.x-size/2,stamp.y-size*0.42,size,size)];
    ring.lineWidth = 2;
    [[accent colorWithAlphaComponent:pointer ? 0.92 : 0.4] setStroke];
    [ring stroke];
    [self drawPawAt:stamp scale:0.95 color:accent];
    [self drawSparkleAt:NSMakePoint(stamp.x+57,stamp.y+36) size:3 color:self.inkColor];
}
- (void)drawConstellationAt:(NSPoint)center time:(CGFloat)time pointer:(NSValue *)pointer {
    const CGFloat xs[] = {-167,-111,-58,0,61,112,167};
    const CGFloat ys[] = {-30,24,4,68,21,47,-33};
    NSPoint stars[7];
    NSBezierPath *lines = [NSBezierPath bezierPath];
    for (NSInteger i=0; i<7; i++) {
        NSPoint point = NSMakePoint(center.x+xs[i],center.y+ys[i]+sin(time*2*M_PI+i)*9);
        stars[i] = FollowPointer(point,pointer,i == 3 ? 78 : 20);
        if (i == 0) [lines moveToPoint:stars[i]];
        else [lines lineToPoint:stars[i]];
    }
    lines.lineWidth = 2;
    [[self.accentColor colorWithAlphaComponent:MIN(1,(pointer ? 0.78 : 0.43)*self.intensity)] setStroke];
    [lines stroke];
    for (NSInteger i=0; i<7; i++)
        [self drawSparkleAt:stars[i] size:i == 3 ? 7 : 3 color:i == 3 ? self.accentColor : self.inkColor];
}
- (void)drawBubblesAt:(NSPoint)center time:(CGFloat)time pointer:(NSValue *)pointer {
    for (NSInteger i=0; i<9; i++) {
        CGFloat x = center.x + (i-4)*39 + 14*sin(time*2*M_PI+i);
        CGFloat y = center.y - 58 + fmod(time*82+i*31,146);
        CGFloat radius = 13 + (i*11)%17;
        NSPoint mouse = pointer.pointValue;
        CGFloat proximity = pointer ? MAX(0, 1-hypot(mouse.x-x,mouse.y-y)/(radius+33)) : 0;
        CGFloat alpha = MIN(0.92, (0.46 + proximity*0.34)*self.intensity);
        NSColor *color = [self.accentColor colorWithAlphaComponent:alpha];
        CGFloat spread = radius*(1 + proximity*0.5);
        NSBezierPath *bubble = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x-spread,y-spread,2*spread,2*spread)];
        bubble.lineWidth = 2;
        [[color colorWithAlphaComponent:alpha*(1-proximity)] setStroke];
        [bubble stroke];
        [self drawEllipseAt:NSMakePoint(x-radius/3,y+radius/2) width:5 height:5 color:color];
        if (proximity > 0) {
            for (NSInteger spark=0; spark<4; spark++) {
                CGFloat angle = spark*M_PI_2 + M_PI_4;
                NSPoint point = NSMakePoint(x+cos(angle)*(spread+8),y+sin(angle)*(spread+8));
                [self drawSparkleAt:point size:1.5+2*proximity color:[color colorWithAlphaComponent:proximity]];
            }
        }
    }
}
- (void)drawPaperPlaneAt:(NSPoint)center time:(CGFloat)time pointer:(NSValue *)pointer {
    CGFloat angle = time*2*M_PI;
    NSPoint cruise = NSMakePoint(center.x + 112*sin(angle),center.y + 32*cos(angle));
    NSPoint plane = FollowPointer(cruise,pointer,120);
    for (NSInteger i=1; i<=12; i++) {
        CGFloat trail = angle - i*0.13;
        NSPoint point = FollowPointer(NSMakePoint(center.x+112*sin(trail),center.y+32*cos(trail)),pointer,120);
        [self drawEllipseAt:point width:6-i*0.3 height:6-i*0.3
            color:[self.accentColor colorWithAlphaComponent:MIN(0.9,(13-i)*0.065*self.intensity)]];
    }
    NSPoint target = pointer ? pointer.pointValue : NSMakePoint(plane.x+112*cos(angle),plane.y-32*sin(angle));
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:plane.x yBy:plane.y];
    [transform rotateByRadians:atan2(target.y-plane.y,target.x-plane.x)];
    [transform concat];
    NSBezierPath *wing = [NSBezierPath bezierPath];
    [wing moveToPoint:NSMakePoint(53,0)];
    [wing lineToPoint:NSMakePoint(-40,31)];
    [wing lineToPoint:NSMakePoint(-22,0)];
    [wing lineToPoint:NSMakePoint(-40,-24)];
    [wing closePath];
    [self.accentColor setFill]; [wing fill];
    NSBezierPath *fold = [NSBezierPath bezierPath];
    [fold moveToPoint:NSMakePoint(-22,0)];
    [fold lineToPoint:NSMakePoint(45,0)];
    [self.inkColor setStroke];
    fold.lineWidth = 2; [fold stroke];
    [NSGraphicsContext restoreGraphicsState];
}
- (void)drawFishAt:(NSPoint)center time:(CGFloat)time pointer:(NSValue *)pointer {
    NSPoint drift = NSMakePoint(center.x + 48*sin(time*2*M_PI),center.y+10*cos(time*2*M_PI));
    NSPoint fish = FollowPointer(drift,pointer,115);
    CGFloat direction = (pointer ? pointer.pointValue.x >= fish.x : cos(time*2*M_PI) >= 0) ? 1 : -1;
    CGFloat tail = self.reducedMotion ? 0 : 6*sin(time*24);
    CGFloat x = fish.x, y = fish.y;
    NSColor *water = [NSColor colorWithSRGBRed:0.38 green:0.79 blue:0.90 alpha:1];
    for (NSInteger i=0; i<4; i++) {
        CGFloat radius = 12+i*13+4*sin(2*M_PI*time+i);
        NSBezierPath *wake = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x-direction*(i*21+50)-radius,y-radius/2,2*radius,radius)];
        [[water colorWithAlphaComponent:MIN(1,(0.55-i*0.1)*self.intensity)] setStroke];
        wake.lineWidth = 1.5; [wake stroke];
    }
    NSBezierPath *fin = [NSBezierPath bezierPath];
    [fin moveToPoint:NSMakePoint(x-direction*34,y)];
    [fin lineToPoint:NSMakePoint(x-direction*67,y+29+tail)];
    [fin lineToPoint:NSMakePoint(x-direction*64,y-29+tail)];
    [fin closePath];
    [self.accentColor setFill]; [fin fill];
    [self drawEllipseAt:fish width:91 height:56 color:self.accentColor];
    [self drawEllipseAt:NSMakePoint(x+direction*22,y+10) width:11 height:11 color:self.inkColor];
    [self drawEllipseAt:NSMakePoint(x+direction*24,y+10) width:5 height:5
        color:[NSColor colorWithWhite:0.14 alpha:1]];
    if (pointer) {
        NSPoint light = FollowPointer(fish,pointer,79);
        [self drawSparkleAt:light size:4 color:water];
    }
}
- (void)drawInteractiveEffect {
    NSValue *pointer = self.reducedMotion ? nil : [self pointerInEffect];
    CGFloat time = self.reducedMotion ? 0.32 : [self progress];
    NSPoint center = NSMakePoint(NSMidX(self.bounds),NSMidY(self.bounds)+22);
    switch (self.style) {
        case 5: [self drawPawStampAt:center time:time pointer:pointer]; break;
        case 6: [self drawConstellationAt:center time:time pointer:pointer]; break;
        case 7: [self drawBubblesAt:center time:time pointer:pointer]; break;
        case 8: [self drawPaperPlaneAt:center time:time pointer:pointer]; break;
        case 9: [self drawFishAt:center time:time pointer:pointer]; break;
    }
    [self drawTitle:[self completionMessage] at:NSMakePoint(center.x,center.y-115)
        font:[NSFont systemFontOfSize:29 weight:NSFontWeightBold] color:self.inkColor];
}
- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:CelebrationArtworkCornerRadius yRadius:CelebrationArtworkCornerRadius] addClip];
    CGContextBeginTransparencyLayer(context,NULL);
    [self drawGameCard];
    switch (self.style) {
        case 1: [self drawCoins]; break;
        case 2: [self drawRocket]; break;
        case 3: [self drawChest]; break;
        case 4: [self drawLevelUp]; break;
        case 0: [self drawPixel]; break;
        default: [self drawInteractiveEffect]; break;
    }
    if (self.mascotID.length) {
        DrawMascot(self.mascotID,NSMakeRect(34,350,68,68),@"completed");
        NSString *name = MascotDefinition(self.mascotID)[@"name"];
        [name drawAtPoint:NSMakePoint(116,390) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:16 weight:NSFontWeightSemibold],NSForegroundColorAttributeName:[self inkColor]}];
        [@"本轮忙碌已收尾，成果等你查收" drawAtPoint:NSMakePoint(116,367) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12],NSForegroundColorAttributeName:[[self inkColor] colorWithAlphaComponent:0.6]}];
    }
    CGContextEndTransparencyLayer(context);
    CGContextRestoreGState(context);
}

@end

@interface CelebrationController ()
@property NSInteger lastStyle;
@property(strong) NSTextField *interactionHint;
@property(weak) NSPopUpButton *themeControl;
@end

@implementation CelebrationController
- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) {
        self.settingsPath = [directory stringByAppendingPathComponent:@"settings.json"];
        self.settings = [@{@"enabled":@YES, @"duration":@4, @"intensity":@0.8, @"palette":@0, @"allScreens":@NO, @"style":@(CelebrationRandomStyle), @"styleVersion":@3, @"showStatusItem":@YES, @"mascotID":@"foreman", @"theme":@(PanelThemeDark), @"suppressAntigravityPermissionPrompt":@NO} mutableCopy];
        NSData *data = [NSData dataWithContentsOfFile:self.settingsPath];
        id saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([saved isKindOfClass:NSDictionary.class]) {
            for (NSString *key in self.settings.allKeys) if ([self.settings[key] isKindOfClass:NSNumber.class] && [saved[key] isKindOfClass:NSNumber.class]) self.settings[key] = saved[key];
            self.settings[@"mascotID"] = MascotDefinition(saved[@"mascotID"])[@"id"];
        }
        double duration = [self.settings[@"duration"] doubleValue];
        double intensity = [self.settings[@"intensity"] doubleValue];
        self.settings[@"duration"] = @(isfinite(duration) ? MIN(4, MAX(1,duration)) : 4);
        self.settings[@"intensity"] = @(isfinite(intensity) ? MIN(1.3,MAX(0.4,intensity)) : 0.8);
        self.settings[@"palette"] = @([self.settings[@"palette"] integerValue] == 1 ? 1 : 0);
        NSInteger style = [self.settings[@"style"] integerValue];
        id savedVersion = [saved isKindOfClass:NSDictionary.class] ? saved[@"styleVersion"] : nil;
        NSInteger version = [savedVersion isKindOfClass:NSNumber.class] ? [savedVersion integerValue] : 0;
        // Version 2 stored its default effect even when a user only saved another setting.
        BOOL validFixedStyle = style >= 0 && style < (NSInteger)CelebrationStyleTitles().count;
        BOOL savedFixedStyle = validFixedStyle && (version == 3 || (version == 2 && style > 0 && style < FirstInteractiveStyle));
        self.settings[@"style"] = @(savedFixedStyle ? style : CelebrationRandomStyle);
        self.settings[@"styleVersion"] = @3;
        NSInteger theme = [self.settings[@"theme"] integerValue];
        if (theme < PanelThemeDark || theme > PanelThemeSystem) self.settings[@"theme"] = @(PanelThemeDark);
        self.lastStyle = CelebrationRandomStyle;
        self.overlays = [NSMutableArray array];
    }
    return self;
}
- (void)showOnScreen:(NSScreen *)screen {
    if (![self.settings[@"enabled"] boolValue] || self.overlays.count) return;
    NSArray *screens = [self.settings[@"allScreens"] boolValue] ? NSScreen.screens : (screen ? @[screen] : @[]);
    if (!screens.count) return;
    NSString *message = CelebrationRandomMessage(self.lastMessage);
    self.lastMessage = message;
    NSInteger style = CelebrationPlaybackStyle([self.settings[@"style"] integerValue], self.lastStyle);
    self.lastStyle = style;
    CFTimeInterval start = CACurrentMediaTime();
    for (NSScreen *display in screens) {
        NSRect frame = CelebrationOverlayFrame(display.visibleFrame);
        NSPanel *overlay = [[NSPanel alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        overlay.backgroundColor = NSColor.clearColor;
        overlay.opaque = NO;
        overlay.alphaValue = 1;
        overlay.hasShadow = NO;
        overlay.ignoresMouseEvents = YES;
        overlay.hidesOnDeactivate = NO;
        overlay.releasedWhenClosed = NO;
        overlay.level = NSStatusWindowLevel;
        overlay.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorIgnoresCycle;
        CelebrationView *view = [[CelebrationView alloc] initWithFrame:NSMakeRect(0,0,NSWidth(frame),NSHeight(frame))];
        [view setBoundsSize:NSMakeSize(600,460)];
        view.wantsLayer = YES;
        view.layer.cornerRadius = CelebrationArtworkCornerRadius;
        view.layer.masksToBounds = YES;
        view.message = message;
        view.mascotID = self.settings[@"mascotID"];
        view.startTime = start;
        view.duration = MIN(3.90, [self.settings[@"duration"] doubleValue]);
        view.intensity = [self.settings[@"intensity"] doubleValue];
        view.palette = [self.settings[@"palette"] integerValue];
        view.style = style;
        view.reducedMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
        NSVisualEffectView *glass = CelebrationGlass(view.frame,NSVisualEffectBlendingModeBehindWindow);
        [glass addSubview:view];
        overlay.contentView = glass;
        [self.overlays addObject:overlay];
        [overlay orderFrontRegardless];
    }
    if (!self.overlays.count) return;
    __weak CelebrationController *weakSelf = self;
    self.animationTimer = [NSTimer timerWithTimeInterval:1.0/30 repeats:YES block:^(NSTimer *timer) {
        CelebrationController *owner = weakSelf;
        CelebrationView *first = (CelebrationView *)owner.overlays.firstObject.contentView.subviews.lastObject;
        if (!first || CACurrentMediaTime()-first.startTime >= first.duration) { [owner stop]; return; }
        for (NSPanel *overlay in owner.overlays)
            [overlay.contentView.subviews.lastObject setNeedsDisplay:YES];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.animationTimer forMode:NSRunLoopCommonModes];
}
- (void)stopPreview {
    [self.previewTimer invalidate];
    self.previewTimer = nil;
}
- (void)stop {
    [self.animationTimer invalidate];
    self.animationTimer = nil;
    for (NSPanel *overlay in self.overlays) [overlay close];
    [self.overlays removeAllObjects];
}
- (void)changeSetting:(NSControl *)sender {
    NSArray *keys = @[@"enabled",@"palette",@"duration",@"intensity",@"allScreens",@"style",@"showStatusItem"];
    NSString *key = keys[sender.tag];
    if ([sender isKindOfClass:NSPopUpButton.class]) {
        NSInteger index = [(NSPopUpButton *)sender indexOfSelectedItem];
        if (index < 0) return;
        self.settings[key] = @([key isEqual:@"style"] ? index - 1 : index);
    }
    else if ([sender isKindOfClass:NSButton.class]) self.settings[key] = @([(NSButton *)sender state] == NSControlStateValueOn);
    else self.settings[key] = @(sender.doubleValue);
    self.durationLabel.stringValue = [NSString stringWithFormat:@"%.1f 秒",[self.settings[@"duration"] doubleValue]];
    [self saveChange:key];
    if ([@[@"style", @"palette", @"duration", @"intensity"] containsObject:key]) [self preview:sender];
}
- (void)saveChange:(NSString *)key {
    [self stop];
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:self.settingsPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.settings options:NSJSONWritingPrettyPrinted error:&error];
    BOOL saved = data && [data writeToFile:self.settingsPath options:NSDataWritingAtomic error:&error];
    self.saveStatus.stringValue = saved ? @"设置已自动保存" : @"保存失败，请重新调整后重试";
    if (self.settingDidChange) self.settingDidChange(key);
}
- (void)changeMascot:(MascotChoiceButton *)sender {
    self.settings[@"mascotID"] = MascotDefinition(sender.mascotID)[@"id"];
    for (NSView *view in self.settingsWindow.contentView.subviews) if ([view isKindOfClass:MascotChoiceButton.class]) {
        MascotChoiceButton *choice = (MascotChoiceButton *)view;
        choice.chosen = [choice.mascotID isEqual:self.settings[@"mascotID"]];
        choice.accessibilityValue = choice.chosen ? @"已选择" : @"未选择";
        [choice setNeedsDisplay:YES];
    }
    self.mascotDescription.stringValue = MascotDefinition(self.settings[@"mascotID"])[@"description"];
    [self saveChange:@"mascotID"];
    [self preview:sender];
}
- (void)applyTheme {
    switch ([self.settings[@"theme"] integerValue]) {
        case PanelThemeLight: NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua]; break;
        case PanelThemeSystem: NSApp.appearance = nil; break;
        default: NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]; break;
    }
}
- (void)changeTheme:(id)sender {
    NSInteger theme = [sender isKindOfClass:NSPopUpButton.class] ? [sender indexOfSelectedItem] : [sender tag];
    if (theme < PanelThemeDark || theme > PanelThemeSystem) return;
    self.settings[@"theme"] = @(theme);
    [self.themeControl selectItemAtIndex:theme];
    [self applyTheme];
    [self saveChange:@"theme"];
}
- (void)preview:(id)sender {
    [self stopPreview];
    if (!self.previewView) return;
    CelebrationView *view = self.previewView;
    view.duration = MIN(3.90,[self.settings[@"duration"] doubleValue]);
    view.startTime = CACurrentMediaTime();
    view.stillFrame = NO;
    view.style = CelebrationPlaybackStyle([self.settings[@"style"] integerValue], view.style);
    view.mascotID = self.settings[@"mascotID"];
    view.palette = [self.settings[@"palette"] integerValue];
    view.intensity = [self.settings[@"intensity"] doubleValue];
    view.alphaValue = 1;
    view.reducedMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    self.interactionHint.hidden = !InteractiveStyle(view.style) || view.reducedMotion;
    view.message = CelebrationRandomMessage(self.lastMessage);
    self.lastMessage = view.message;
    [view setNeedsDisplay:YES];
    __weak CelebrationController *weakSelf = self;
    self.previewTimer = [NSTimer timerWithTimeInterval:1.0/30 repeats:YES block:^(NSTimer *timer) {
        CelebrationController *owner = weakSelf;
        CelebrationView *preview = owner.previewView;
        if (!owner) { [timer invalidate]; return; }
        if (!owner.settingsWindow.visible) { [owner stopPreview]; return; }
        if (CACurrentMediaTime()-preview.startTime >= preview.duration) {
            [owner stopPreview];
            preview.stillFrame = YES;
        }
        [preview setNeedsDisplay:YES];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.previewTimer forMode:NSRunLoopCommonModes];
}
- (void)windowWillClose:(NSNotification *)notification { [self stopPreview]; }
- (void)showSettings:(id)sender {
    if (self.settingsWindow) { [self.settingsWindow makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; [self preview:nil]; return; }
    [self buildSettings];
    [self.settingsWindow center]; [self.settingsWindow makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    [self preview:nil];
}
- (void)buildSettings {
    if (self.settingsWindow) return;
    self.settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,760) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.settingsWindow.title = @"工头喵 · 主面板";
    self.settingsWindow.releasedWhenClosed = NO;
    self.settingsWindow.delegate = self;
    PanelSurface *root = [[PanelSurface alloc] initWithFrame:self.settingsWindow.contentView.frame];
    root.fillColor = PanelColor(0xf7f8fb,0x1a1c21,1);
    self.settingsWindow.contentView = root;
    NSTextField *roleHeading = [NSTextField labelWithString:@"选一位，陪你盯进度"];
    roleHeading.font = [NSFont systemFontOfSize:23 weight:NSFontWeightSemibold];
    roleHeading.frame = NSMakeRect(28,710,226,32); [root addSubview:roleHeading];
    NSInteger roleIndex = 0;
    for (NSDictionary *role in MascotCatalog()) {
        MascotChoiceButton *choice = [[MascotChoiceButton alloc] initWithFrame:NSMakeRect(28+(roleIndex++)*142,550,128,132)];
        choice.mascotID = role[@"id"];
        choice.chosen = [role[@"id"] isEqual:self.settings[@"mascotID"]];
        choice.target = self; choice.action = @selector(changeMascot:);
        choice.bordered = NO;
        choice.toolTip = [NSString stringWithFormat:@"%@\n%@",role[@"name"],role[@"description"]];
        choice.accessibilityLabel = [NSString stringWithFormat:@"选择%@",role[@"name"]];
        choice.accessibilityValue = choice.chosen ? @"已选择" : @"未选择";
        [root addSubview:choice];
    }
    self.mascotDescription = [NSTextField labelWithString:MascotDefinition(self.settings[@"mascotID"])[@"description"]];
    self.mascotDescription.textColor = NSColor.secondaryLabelColor;
    self.mascotDescription.font = [NSFont systemFontOfSize:12];
    self.mascotDescription.frame = NSMakeRect(28,506,842,23); [root addSubview:self.mascotDescription];
    NSBox *section = [[NSBox alloc] initWithFrame:NSMakeRect(28,480,842,1)]; section.boxType = NSBoxSeparator; [root addSubview:section];
    NSButton *statusItem = [NSButton checkboxWithTitle:@"在状态栏显示任务数量" target:self action:@selector(changeSetting:)];
    statusItem.frame = NSMakeRect(28,136,420,24);
    statusItem.tag = 6;
    statusItem.state = [self.settings[@"showStatusItem"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    [root addSubview:statusItem];
    NSTextField *themeLabel = [NSTextField labelWithString:@"界面主题"];
    themeLabel.frame = NSMakeRect(28,92,82,24);
    [root addSubview:themeLabel];
    NSPopUpButton *theme = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(120,92,192,26) pullsDown:NO];
    [theme addItemsWithTitles:PanelThemeTitles()];
    [theme selectItemAtIndex:[self.settings[@"theme"] integerValue]];
    theme.accessibilityLabel = @"界面主题";
    theme.target = self;
    theme.action = @selector(changeTheme:);
    [root addSubview:theme];
    self.themeControl = theme;
    NSTextField *heading = [NSTextField labelWithString:@"任务完成提示"];
    heading.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
    heading.frame = NSMakeRect(28,426,420,30);
    [root addSubview:heading];
    NSButton *enabled = [NSButton checkboxWithTitle:@"任务完成时显示庆祝弹窗" target:self action:@selector(changeSetting:)];
    enabled.frame = NSMakeRect(28,384,420,24); enabled.tag = 0;
    enabled.state = [self.settings[@"enabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    [root addSubview:enabled];
    NSTextField *styleLabel = [NSTextField labelWithString:@"效果"];
    styleLabel.frame = NSMakeRect(28,342,80,24); [root addSubview:styleLabel];
    NSPopUpButton *style = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(120,342,300,26) pullsDown:NO];
    [style addItemWithTitle:@"随机"];
    [style addItemsWithTitles:CelebrationStyleTitles()];
    [style selectItemAtIndex:[self.settings[@"style"] integerValue] + 1];
    style.tag = 5; style.target = self; style.action = @selector(changeSetting:); [root addSubview:style];
    NSArray *labels = @[@"配色",@"时长",@"光效强度"];
    for (NSInteger i=0;i<3;i++) {
        NSTextField *label = [NSTextField labelWithString:labels[i]];
        label.frame = NSMakeRect(28,300-i*42,80,24); [root addSubview:label];
    }
    NSPopUpButton *palette = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(120,300,240,26) pullsDown:NO];
    [palette addItemsWithTitles:@[@"暖光",@"冷光"]];
    [palette selectItemAtIndex:[self.settings[@"palette"] integerValue]];
    palette.tag = 1; palette.target = self; palette.action = @selector(changeSetting:); [root addSubview:palette];
    NSSlider *duration = [NSSlider sliderWithValue:[self.settings[@"duration"] doubleValue] minValue:1 maxValue:4 target:self action:@selector(changeSetting:)];
    duration.continuous = NO;
    duration.frame = NSMakeRect(120,260,240,24); duration.tag = 2; duration.accessibilityLabel = @"庆祝持续时间，1 至 4 秒"; [root addSubview:duration];
    self.durationLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%.1f 秒",duration.doubleValue]];
    self.durationLabel.frame = NSMakeRect(376,260,80,24); [root addSubview:self.durationLabel];
    NSSlider *intensity = [NSSlider sliderWithValue:[self.settings[@"intensity"] doubleValue] minValue:0.4 maxValue:1.3 target:self action:@selector(changeSetting:)];
    intensity.continuous = NO;
    intensity.frame = NSMakeRect(120,218,240,24); intensity.tag = 3; intensity.accessibilityLabel = @"光效强度"; [root addSubview:intensity];
    NSButton *screens = [NSButton checkboxWithTitle:@"在所有显示器上庆祝" target:self action:@selector(changeSetting:)];
    screens.frame = NSMakeRect(28,176,420,24); screens.tag = 4;
    screens.state = [self.settings[@"allScreens"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff; [root addSubview:screens];
    NSButton *preview = [NSButton buttonWithTitle:@"预览效果" target:self action:@selector(preview:)];
    preview.bezelStyle = NSBezelStyleRounded; preview.frame = NSMakeRect(346,30,106,32); [root addSubview:preview];
    self.saveStatus = [NSTextField labelWithString:@"自动保存 · 遵循系统减少动态效果设置"];
    self.saveStatus.font = [NSFont systemFontOfSize:11]; self.saveStatus.textColor = NSColor.secondaryLabelColor;
    self.saveStatus.frame = NSMakeRect(28,36,310,18); [root addSubview:self.saveStatus];
    NSBox *divider = [[NSBox alloc] initWithFrame:NSMakeRect(470,28,1,444)];
    divider.boxType = NSBoxSeparator; [root addSubview:divider];
    NSTextField *previewTitle = [NSTextField labelWithString:@"效果预览"];
    previewTitle.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    previewTitle.frame = NSMakeRect(500,426,360,24); [root addSubview:previewTitle];
    NSView *previewStage = [[NSView alloc] initWithFrame:NSMakeRect(500,94,368,320)];
    [root addSubview:previewStage];
    NSVisualEffectView *previewGlass = CelebrationGlass(NSMakeRect(0,32,368,282),NSVisualEffectBlendingModeWithinWindow);
    [previewStage addSubview:previewGlass];
    self.previewView = [[CelebrationView alloc] initWithFrame:NSMakeRect(0,0,368,282)];
    [self.previewView setBoundsSize:NSMakeSize(600,460)];
    self.previewView.wantsLayer = YES;
    self.previewView.layer.cornerRadius = CelebrationArtworkCornerRadius;
    self.previewView.layer.masksToBounds = YES;
    [previewGlass addSubview:self.previewView];
    self.previewView.mascotID = self.settings[@"mascotID"];
    self.previewView.style = CelebrationPlaybackStyle([self.settings[@"style"] integerValue], CelebrationRandomStyle);
    self.previewView.reducedMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    self.previewView.stillFrame = YES;
    self.previewView.message = CelebrationMessages().firstObject;
    self.interactionHint = [NSTextField labelWithString:@"将指针移入预览区互动"];
    self.interactionHint.textColor = NSColor.secondaryLabelColor;
    self.interactionHint.font = [NSFont systemFontOfSize:12];
    self.interactionHint.frame = NSMakeRect(0,4,368,20);
    self.interactionHint.hidden = !InteractiveStyle(self.previewView.style) || self.previewView.reducedMotion;
    [previewStage addSubview:self.interactionHint];
}
@end
