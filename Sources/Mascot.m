#import "Mascot.h"
#import "PanelTheme.h"

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

NSDictionary *MascotDefinition(NSString *identifier) {
    for (NSDictionary *entry in MascotCatalog()) if ([entry[@"id"] isEqual:identifier]) return entry;
    return MascotCatalog().firstObject;
}
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
    NSColor *accent = PanelColor(0x855315,0xe8bc72,1);
    NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:14 yRadius:14];
    NSColor *fill = self.highlighted ? PanelColor(0xe5e9f0,0x383838,1) : PanelColor(0xffffff,0x242424,1);
    [(self.chosen ? [accent colorWithAlphaComponent:0.11] : fill) setFill]; [card fill];
    [(self.chosen ? accent : PanelColor(0xd3d9e2,0x454545,1)) setStroke]; card.lineWidth = self.chosen ? 1.6 : 0.6; [card stroke];
    DrawMascot(self.mascotID,NSMakeRect((self.bounds.size.width-76)/2,38,76,76),@"idle");
    NSDictionary *definition = MascotDefinition(self.mascotID);
    NSString *title = definition[@"name"];
    NSDictionary *attributes = @{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],NSForegroundColorAttributeName:self.chosen ? accent : NSColor.labelColor};
    NSSize size = [title sizeWithAttributes:attributes];
    [title drawAtPoint:NSMakePoint((self.bounds.size.width-size.width)/2,17) withAttributes:attributes];
    if (self.chosen) {
        CGFloat x = self.bounds.size.width-17, y = self.bounds.size.height-17;
        Oval(x-7,y-7,14,14,accent,0);
        NSColor *check = PanelColor(0xffffff,0x27303f,1);
        Line(x-3,y,x-0.5,y-3,check,1.6); Line(x-0.5,y-3,x+4,y+3,check,1.6);
    }
}
@end

@implementation MascotGalleryView
- (void)drawRect:(NSRect)dirtyRect {
    [Hex(0x181C23) setFill]; NSRectFill(self.bounds);
    [@"今天，谁来陪你盯进度？" drawAtPoint:NSMakePoint(32,570) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:26 weight:NSFontWeightSemibold],NSForegroundColorAttributeName:Hex(0xF1EADF)}];
    [@"工头喵小队  /  六位伙伴，随时换班" drawAtPoint:NSMakePoint(34,542) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13],NSForegroundColorAttributeName:Hex(0x9DA8B7)}];
    NSInteger index = 0;
    for (NSDictionary *role in MascotCatalog()) {
        NSInteger col = index%3, row = index/3; index++;
        NSRect card = NSMakeRect(28+col*284,278-row*250,266,238);
        Round(card.origin.x,card.origin.y,card.size.width,card.size.height,20,Hex(0x232A34),0);
        DrawMascot(role[@"id"],NSMakeRect(card.origin.x+61,card.origin.y+69,144,144),@"idle");
        NSString *name = role[@"name"];
        NSDictionary *attributes = @{NSFontAttributeName:[NSFont systemFontOfSize:18 weight:NSFontWeightSemibold],NSForegroundColorAttributeName:Hex(0xF1EADF)};
        CGFloat width = [name sizeWithAttributes:attributes].width;
        [name drawAtPoint:NSMakePoint(NSMidX(card)-width/2,card.origin.y+38) withAttributes:attributes];
        NSArray *captions = @[@"安全帽与小清单",@"眼镜与交付检查表",@"薄荷兜帽与小鱼",@"紫色耳机与闪电",@"红领巾与成就金币",@"透明头盔与宇航服"];
        NSString *caption = captions[index-1];
        NSDictionary *small = @{NSFontAttributeName:[NSFont systemFontOfSize:12],NSForegroundColorAttributeName:Hex(0x9DA8B7)};
        CGFloat captionWidth = [caption sizeWithAttributes:small].width;
        [caption drawAtPoint:NSMakePoint(NSMidX(card)-captionWidth/2,card.origin.y+17) withAttributes:small];
    }
}
@end
