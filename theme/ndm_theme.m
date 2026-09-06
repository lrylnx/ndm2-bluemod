// ndm_theme.m v6 — NDM 2 主题注入 dylib（全面现代化版）
// 设计语言：macOS 原生现代风，强调色 #3D9BFF 贯穿
// 模块（每项独立回退开关 defaults write com.NeatDownloadManager ndm_theme_disable_<x> -bool YES）：
//   buttons   文字按钮：圆角扁平 + hover/按压 + 主按钮蓝底白字
//   progress  进度条：胶囊 + 轨道底色 + 顶部高光 + 外描边（baranim 单独控平滑动画）
//   selection 列表选中行圆角裁剪 + 行 hover 淡蓝底
//   checkradio 复选/单选自绘（圆角蓝底白勾 / 蓝心圆点）
//   fields    输入框圆角化 + 聚焦蓝框
// 日志：/tmp/ndm_theme.log
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void NDMDlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void NDMDlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen("/tmp/ndm_theme.log", "a");
    if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); }
}

// ---------------- 设计规范常量 ----------------
static BOOL NDMOff(NSString *feature) {
    return [NSUserDefaults.standardUserDefaults
        boolForKey:[@"ndm_theme_disable_" stringByAppendingString:feature]];
}
static NSColor *NDMHex(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb>>16)&0xFF)/255.0
                               green:((rgb>>8)&0xFF)/255.0
                                blue:(rgb&0xFF)/255.0 alpha:1];
}
static NSColor *NDMAccent(void)      { return NDMHex(0x3D9BFF); }
static NSColor *NDMAccentDark(void)  { return NDMHex(0x2E7FD6); }   // hover 加深
static NSColor *NDMAccentDeep(void)  { return NDMHex(0x2569B0); }   // 按压加深
static NSColor *NDMBorder(void)      { return NDMHex(0xCDD9E6); }
static NSColor *NDMBtnBG(void)       { return NDMHex(0xFDFDFE); }
static NSColor *NDMHoverBG(void)     { return NDMHex(0xEFF6FF); }
static NSColor *NDMRowHoverBG(void)  { return [NDMAccent() colorWithAlphaComponent:0.10]; }
static NSColor *NDMTrackBG(void)     { return NDMHex(0xEAF0F6); }
static NSColor *NDMDisabledText(void){ return NDMHex(0xA9B4C0); }

// 关联对象 key
static const void *KStyled   = &KStyled;     // 已样式化标记
static const void *KScanned  = &KScanned;    // 已扫描标记
static const void *KWatcher  = &KWatcher;    // NDMHoverWatcher
static const void *KPressed  = &KPressed;    // 按钮按压中

// ---------------- hover watcher（tracking area owner；按钮/行/工具栏通用） ----------------
typedef NS_ENUM(NSInteger, NDMHoverKind) {
    NDMHoverButton, NDMHoverRow, NDMHoverToolbar,
};

@interface NDMHoverWatcher : NSObject {
    __weak NSView *_view;
    NDMHoverKind _kind;
}
- (instancetype)initWithView:(NSView *)v kind:(NDMHoverKind)k;
- (void)applyHover:(BOOL)on;
@end

@implementation NDMHoverWatcher
- (instancetype)initWithView:(NSView *)v kind:(NDMHoverKind)k {
    if ((self = [super init])) { _view = v; _kind = k; }
    return self;
}
- (void)applyHover:(BOOL)on {
    NSView *v = _view;
    if (!v || !v.layer) return;
    if (_kind == NDMHoverRow) {
        if ([(NSTableRowView *)v isSelected]) {
            v.layer.backgroundColor = NSColor.clearColor.CGColor;
        } else {
            v.layer.backgroundColor = on ? NDMRowHoverBG().CGColor
                                         : NSColor.clearColor.CGColor;
        }
        return;
    }
    if (_kind == NDMHoverToolbar) {
        v.layer.backgroundColor = on ? NDMRowHoverBG().CGColor : NSColor.clearColor.CGColor;
        return;
    }
    // 按钮：主/普通 两态 × hover/按压
    NSButton *b = (NSButton *)v;
    if (!b.isEnabled) return;
    BOOL primary = (b.keyEquivalent.length && [b.keyEquivalent characterAtIndex:0] == '\r');
    BOOL pressed = [objc_getAssociatedObject(b, KPressed) boolValue];
    if (primary) {
        NSColor *c = pressed ? NDMAccentDeep() : (on ? NDMAccentDark() : NDMAccent());
        v.layer.backgroundColor = c.CGColor;
        v.layer.borderColor = c.CGColor;
    } else {
        v.layer.backgroundColor = (on || pressed) ? NDMHoverBG().CGColor : NDMBtnBG().CGColor;
        v.layer.borderColor = (on || pressed) ? NDMAccent().CGColor : NDMBorder().CGColor;
    }
}
- (void)mouseEntered:(NSEvent *)e { [self applyHover:YES]; }
- (void)mouseExited:(NSEvent *)e  { [self applyHover:NO]; }
@end

static void NDMAddHover(NSView *v, NDMHoverKind kind) {
    if (objc_getAssociatedObject(v, KWatcher)) return;
    if (!v.wantsLayer) [v wantsLayer];
    NDMHoverWatcher *w = [[NDMHoverWatcher alloc] initWithView:v kind:kind];
    objc_setAssociatedObject(v, KWatcher, w, OBJC_ASSOCIATION_RETAIN);
    NSTrackingArea *ta = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
                    | NSTrackingInVisibleRect
               owner:w userInfo:nil];
    [v addTrackingArea:ta];
}

// ---------------- 1) 进度条：胶囊 + 轨道 + 高光 + 描边 ----------------
static IMP origProgA = NULL;   // NeatProgressBar drawRect
static IMP origProgB = NULL;   // NeatSegmentsProgressBar drawRect
static IMP origSetCur = NULL;  // NeatProgressBar setCurrentValue:
static const void *KAnimTimer = &KAnimTimer;
static const void *KAnimTarget = &KAnimTarget;

static void NDMCapsuleDraw(id self, SEL _cmd, NSRect r) {
    Class B = NSClassFromString(@"NeatSegmentsProgressBar");
    BOOL isSeg = B && [self isKindOfClass:B];
    IMP orig = isSeg ? origProgB : origProgA;
    if (r.size.height < 4 || r.size.width < 4 || !orig) {
        if (orig) ((void(*)(id,SEL,NSRect))orig)(self, _cmd, r);
        return;
    }
    NSGraphicsContext *ctx = [NSGraphicsContext currentContext];
    [ctx saveGraphicsState];
    NSRect outer = NSInsetRect(r, 0.5, 0.5);
    NSBezierPath *p;
    if (isSeg) {
        p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1.0, 1.0)
                              xRadius:4 yRadius:4];
    } else {
        p = [NSBezierPath bezierPathWithRoundedRect:outer
                              xRadius:outer.size.height/2.0 yRadius:outer.size.height/2.0];
        [NDMTrackBG() setFill];   // 轨道底色，原实现画在其上
        [p fill];
    }
    [p addClip];
    ((void(*)(id,SEL,NSRect))orig)(self, _cmd, r);
    if (!NDMOff(@"progress")) {
        // 顶部高光：sourceAtop 只作用于已绘制的不透明像素 → 填充块获得上亮下深层次
        [ctx setCompositingOperation:NSCompositingOperationSourceAtop];
        NSGradient *g = [[NSGradient alloc]
            initWithColorsAndLocations:[NSColor colorWithWhite:1 alpha:0.22], 0.0,
                                       [NSColor colorWithWhite:1 alpha:0.05], 0.5,
                                       [NSColor colorWithWhite:0 alpha:0.06], 1.0, nil];
        [g drawInRect:r angle:-90];
    }
    [ctx restoreGraphicsState];
    // 外描边增强精致感
    NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.75, 0.75)
                                  xRadius:isSeg ? 4 : outer.size.height/2.0
                                  yRadius:isSeg ? 4 : outer.size.height/2.0];
    bp.lineWidth = 1;
    [NDMBorder() setStroke];
    [bp stroke];
}

// 数值平滑动画：大跳变时逐帧插值（中间帧写 ivar 经 KVC + setNeedsDisplay，收尾调原方法）
static void NDMAnimateTick(id timer, id bar) {
    if (!bar || ![bar window] || !origSetCur) { [timer invalidate]; return; }
    double target = [objc_getAssociatedObject(bar, KAnimTarget) doubleValue];
    double c, max;
    @try {
        c = [[bar valueForKey:@"curValue"] doubleValue];
        max = [[bar valueForKey:@"maxValue"] doubleValue];
    } @catch (NSException *e) { [timer invalidate]; return; }
    if (max <= 0) { [timer invalidate]; return; }
    if (fabs(target - c) < max * 0.002) {   // 收敛 → 原方法落最终值
        ((void(*)(id,SEL,double))origSetCur)(bar, @selector(setCurrentValue:), target);
        [timer invalidate];
        objc_setAssociatedObject(bar, KAnimTimer, nil, OBJC_ASSOCIATION_RETAIN);
        return;
    }
    c += (target - c) * 0.3;
    @try { [bar setValue:@(c) forKey:@"curValue"]; }
    @catch (NSException *e) { [timer invalidate]; return; }
    [bar setNeedsDisplay:YES];
}

static void HookedSetCurrentValue(id self, SEL _cmd, double v) {
    if (NDMOff(@"baranim")) {
        if (origSetCur) ((void(*)(id,SEL,double))origSetCur)(self, _cmd, v);
        return;
    }
    double old = 0, max = 100;
    @try {
        old = [[self valueForKey:@"curValue"] doubleValue];
        max = [[self valueForKey:@"maxValue"] doubleValue] ?: 100;
    } @catch (NSException *e) {}
    NSTimer *t = objc_getAssociatedObject(self, KAnimTimer);
    if (v < old) {   // 回退（新任务/重置）→ 取消动画直接落值
        if (t) { [t invalidate]; objc_setAssociatedObject(self, KAnimTimer, nil, OBJC_ASSOCIATION_RETAIN); }
        if (origSetCur) ((void(*)(id,SEL,double))origSetCur)(self, _cmd, v);
        return;
    }
    if (fabs(v - old) > max * 0.04) {       // 明显前进跳变 → 启动/更新动画
        objc_setAssociatedObject(self, KAnimTarget, @(v), OBJC_ASSOCIATION_RETAIN);
        if (!t) {
            t = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0 repeats:YES
                                                 block:^(NSTimer *tm){ NDMAnimateTick(tm, self); }];
            objc_setAssociatedObject(self, KAnimTimer, t, OBJC_ASSOCIATION_RETAIN);
        }
        return;
    }
    if (origSetCur) ((void(*)(id,SEL,double))origSetCur)(self, _cmd, v);
}

// ---------------- 2) 文字按钮现代化（圆角扁平 + hover/按压 + 主按钮蓝底） ----------------
static NSButtonType NDMButtonType(NSButton *b) {
    // NSButton 有运行时 getter -buttonType，但头文件里是只写属性，直接 msgSend
    SEL s = @selector(buttonType);
    if ([b respondsToSelector:s])
        return ((NSButtonType(*)(id,SEL))objc_msgSend)(b, s);
    return NSButtonTypeMomentaryPushIn;
}

static void NDMStyleButton(NSButton *b) {
    // 只结构化改造"原生 NSButton"。任何子类（ndm_confirm 的 HoverButton、
    // 工具栏 NeatCustomButton、NeatTextField 等）一律不碰其 bordered/cell，
    // 否则会破坏其自带的点击/自绘逻辑（实测：改了 HoverButton 导致确认窗按钮失灵）。
    Class cls = object_getClass(b);
    if (cls != [NSButton class]) {
        NSString *cn = NSStringFromClass(cls);
        if ([cn containsString:@"NeatCustomButton"]) {   // 工具栏图标按钮：只加 hover 胶囊底
            b.wantsLayer = YES;
            b.layer.cornerRadius = 8;
            NDMAddHover(b, NDMHoverToolbar);
        }
        return;
    }
    NSButtonType bt = NDMButtonType(b);
    if (bt == NSButtonTypeSwitch || bt == NSButtonTypeRadio)
        return;                                // 复选/单选走 cell 自绘
    if (!b.bordered || b.title.length == 0)    // 纯图标 push button：交给原生
        return;
    // 统一为原生圆角胶囊外观（macOS 11+ 自带精致渲染，默认按钮自动用强调色蓝）。
    // 不再 bordered=NO + layer 扁平底色——那正是用户不喜欢的"老款"观感。
    // 保留原生绘制即天然可点击、自带按压反馈，零交互侵入。
    if (b.bezelStyle != NSBezelStyleRounded)
        b.bezelStyle = NSBezelStyleRounded;
    b.font = [NSFont systemFontOfSize:b.font.pointSize weight:NSFontWeightMedium];
    objc_setAssociatedObject(b, KStyled, @YES, OBJC_ASSOCIATION_RETAIN);
}

// 按压态：swizzle NSButton.mouseDown:
static IMP origBtnMouseDown = NULL;
static void HookedBtnMouseDown(id self, SEL _cmd, NSEvent *e) {
    NSButton *b = (NSButton *)self;
    NDMHoverWatcher *w = objc_getAssociatedObject(b, KWatcher);
    if (w) {
        objc_setAssociatedObject(b, KPressed, @YES, OBJC_ASSOCIATION_RETAIN);
        [w applyHover:YES];
    }
    ((void(*)(id,SEL,NSEvent*))origBtnMouseDown)(self, _cmd, e);
    if (w) {
        objc_setAssociatedObject(b, KPressed, @NO, OBJC_ASSOCIATION_RETAIN);
        // 按压结束按鼠标是否仍在按钮内恢复态
        NSPoint p = [b convertPoint:b.window.mouseLocationOutsideOfEventStream fromView:nil];
        [w applyHover:NSPointInRect(p, b.bounds)];
    }
}

// ---------------- 3) 复选框/单选框自绘 ----------------
static IMP origCellDraw = NULL;

static void NDMDrawIndicator(NSRect box, NSControlStateValue st, BOOL enabled, BOOL radio) {
    BOOL on = (st == NSControlStateValueOn), mixed = (st == NSControlStateValueMixed);
    NSColor *fill   = enabled && (on || mixed) ? NDMAccent() : NSColor.whiteColor;
    NSColor *stroke = (on || mixed) ? (enabled ? NDMAccentDark() : NDMDisabledText())
                                    : (enabled ? NDMBorder() : NDMDisabledText());
    if (radio) {
        NSBezierPath *c = [NSBezierPath bezierPathWithOvalInRect:box];
        c.lineWidth = 1.2;
        [fill setFill]; [c fill];
        [stroke setStroke]; [c stroke];
        if (on) {
            NSRect dot = NSInsetRect(box, box.size.width*0.29, box.size.height*0.29);
            [(enabled ? NDMAccent() : NDMDisabledText()) setFill];
            [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
        }
        return;
    }
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:box xRadius:4 yRadius:4];
    p.lineWidth = 1.2;
    [fill setFill]; [p fill];
    [stroke setStroke]; [p stroke];
    if (on || mixed) {
        NSBezierPath *mark = [NSBezierPath bezierPath];
        if (mixed) {   // 半选：横杠
            CGFloat y = box.origin.y + box.size.height/2.0;
            [mark moveToPoint:NSMakePoint(box.origin.x + box.size.width*0.27, y)];
            [mark lineToPoint:NSMakePoint(box.origin.x + box.size.width*0.73, y)];
        } else {       // 对勾
            [mark moveToPoint:NSMakePoint(box.origin.x + box.size.width*0.24,
                                          box.origin.y + box.size.height*0.52)];
            [mark lineToPoint:NSMakePoint(box.origin.x + box.size.width*0.43,
                                          box.origin.y + box.size.height*0.33)];
            [mark lineToPoint:NSMakePoint(box.origin.x + box.size.width*0.78,
                                          box.origin.y + box.size.height*0.70)];
        }
        mark.lineWidth = 1.8;
        mark.lineCapStyle = NSLineCapStyleRound;
        mark.lineJoinStyle = NSLineJoinStyleRound;
        [(enabled ? NSColor.whiteColor : NDMDisabledText()) setStroke];
        [mark stroke];
    }
}

static void NDMDrawCheckRadio(NSButtonCell *cell, NSRect frameRect, NSView *controlView) {
    NSButton *b = (NSButton *)controlView;
    NSButtonType bt = NDMButtonType(b);
    BOOL radio = (bt == NSButtonTypeRadio);
    CGFloat bs = 14;
    NSRect r = frameRect;
    NSRect box;
    box.origin.x = r.origin.x + 1;
    box.origin.y = r.origin.y + (r.size.height - bs)/2.0;
    box.size = NSMakeSize(bs, bs);
    NDMDrawIndicator(box, cell.state, b.isEnabled, radio);
    NSString *title = cell.title;
    if (title.length) {
        NSFont *font = cell.font ?: [NSFont systemFontOfSize:13];
        NSColor *tc = b.isEnabled ? NSColor.labelColor : NDMDisabledText();
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineBreakMode = NSLineBreakByTruncatingTail;
        NSDictionary *attrs = @{ NSFontAttributeName: font,
                                 NSForegroundColorAttributeName: tc,
                                 NSParagraphStyleAttributeName: ps };
        NSSize ts = [title sizeWithAttributes:attrs];
        [title drawAtPoint:NSMakePoint(box.origin.x + bs + 5,
                                       r.origin.y + (r.size.height - ts.height)/2.0)
            withAttributes:attrs];
    }
}

static void HookedCellDraw(id self, SEL _cmd, NSRect frameRect, NSView *controlView) {
    NSButtonCell *cell = (NSButtonCell *)self;
    BOOL handled = NO;
    if (!NDMOff(@"checkradio") && [controlView isKindOfClass:[NSButton class]]) {
        NSButtonType bt = NDMButtonType((NSButton *)controlView);
        if (bt == NSButtonTypeRadio || bt == NSButtonTypeSwitch) {
            handled = YES;
            @try {
                NDMDrawCheckRadio(cell, frameRect, controlView);
            } @catch (NSException *e) {
                NDMDlog(@"checkradio draw EXC: %@ %@", e.name, e.reason);
                handled = NO;   // 回退原生绘制
            }
        }
    }
    if (!handled)
        ((void(*)(id,SEL,NSRect,id))origCellDraw)(self, _cmd, frameRect, controlView);
}

// ---------------- 4) 输入框圆角化 ----------------
static void NDMStyleField(NSTextField *f) {
    if (object_getClass(f) != [NSTextField class]) return;  // 不碰 NeatTextField 等子类
    if (!f.isEditable || !f.bezeled) return;   // 只处理可编辑输入框，label 不碰
    f.wantsLayer = YES;
    f.focusRingType = NSFocusRingTypeNone;
    f.layer.cornerRadius = 6;
    f.layer.borderWidth = 1;
    f.layer.borderColor = NDMBorder().CGColor;
    f.layer.backgroundColor = NSColor.whiteColor.CGColor;
    f.layer.masksToBounds = YES;
    objc_setAssociatedObject(f, KStyled, @YES, OBJC_ASSOCIATION_RETAIN);
}

// ---------------- 5) 视图扫描（窗口 key 事件驱动 + 定时器兜底） ----------------
static void NDMScanViews(void) {
    int fresh = 0;
    for (NSWindow *w in [NSApp windows]) {
        if (!w.contentView) continue;
        NSView *root = w.contentView;
        while (root.superview && root.superview.window == w) root = root.superview;
        NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count) {
            NSView *v = stack.lastObject; [stack removeLastObject];
            if (!v.hiddenOrHasHiddenAncestor && !objc_getAssociatedObject(v, KScanned)) {
                objc_setAssociatedObject(v, KScanned, @YES, OBJC_ASSOCIATION_RETAIN);
                if ([v isKindOfClass:[NSButton class]]) {
                    if (!NDMOff(@"buttons") && !NDMOff(@"toolbar")) {
                        NDMStyleButton((NSButton *)v); fresh++;
                    }
                } else if ([v isKindOfClass:[NSTextField class]] && !NDMOff(@"fields")) {
                    NDMStyleField((NSTextField *)v); fresh++;
                }
            }
            [stack addObjectsFromArray:v.subviews];
        }
    }
    if (fresh) NDMDlog(@"views styled: %d", fresh);
}

// 焦点态刷新：styled 按钮/输入框获焦 → 边框变蓝；禁用 → 半透明
static void NDMRestyleFocus(void) {
    for (NSWindow *w in [NSApp windows]) {
        if (!w.contentView) continue;
        NSView *root = w.contentView;
        while (root.superview && root.superview.window == w) root = root.superview;
        NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count) {
            NSView *v = stack.lastObject; [stack removeLastObject];
            if ([v isKindOfClass:[NSButton class]] && objc_getAssociatedObject(v, KStyled)) {
                ((NSButton *)v).alphaValue = ((NSButton *)v).isEnabled ? 1.0 : 0.5;  // 原生外观，仅禁用态半透明
            } else if ([v isKindOfClass:[NSTextField class]] && objc_getAssociatedObject(v, KStyled)) {
                NSTextField *f = (NSTextField *)v;
                BOOL focused = (w.firstResponder == f || w.firstResponder == f.currentEditor);
                f.layer.borderWidth = focused ? 1.5 : 1;
                f.layer.borderColor = (focused ? NDMAccent() : NDMBorder()).CGColor;
            }
            [stack addObjectsFromArray:v.subviews];
        }
    }
}

// ---------------- 6) 列表选中行圆角裁剪 + 行 hover ----------------
static NSMutableDictionary *selOrigMap;   // Class -> 原 drawSelectionInRect IMP

static IMP SelOrigFor(Class c) {
    while (c) {
        NSValue *v = selOrigMap[NSStringFromClass(c)];
        if (v) return (IMP)v.pointerValue;
        c = class_getSuperclass(c);
    }
    return NULL;
}

static void NDMRoundSelection(id self, SEL _cmd, NSRect dirtyRect) {
    NSView *v = (NSView *)self;
    if (v.layer) { v.layer.cornerRadius = 6; v.layer.masksToBounds = YES; }
    NSRect r = v.bounds;
    IMP orig = SelOrigFor(object_getClass(self));
    if (r.size.height >= 8) {
        NSGraphicsContext *ctx = [NSGraphicsContext currentContext];
        [ctx saveGraphicsState];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1.0, 1.0)
                          xRadius:6 yRadius:6] addClip];
        if (orig) ((void(*)(id,SEL,NSRect))orig)(self, _cmd, dirtyRect);
        [ctx restoreGraphicsState];
    } else if (orig) {
        ((void(*)(id,SEL,NSRect))orig)(self, _cmd, dirtyRect);
    }
}

static IMP origRowViewSetSel = NULL;
static void NDMRowViewSetSelected(id self, SEL _cmd, BOOL sel) {
    if (origRowViewSetSel) ((void(*)(id,SEL,BOOL))origRowViewSetSel)(self, _cmd, sel);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSView *v = (NSView *)self;
        if (!v.window) return;
        if (!v.layer) [v wantsLayer];
        if (v.layer) {
            v.layer.cornerRadius = 6; v.layer.masksToBounds = YES;
            if (!sel) v.layer.backgroundColor = NSColor.clearColor.CGColor;  // 取消选中清 hover 残留
        }
        [v setNeedsDisplay:YES];
    });
}

static IMP origRowUpdateTA = NULL;
static void HookedRowUpdateTA(id self, SEL _cmd) {
    if (origRowUpdateTA) ((void(*)(id,SEL))origRowUpdateTA)(self, _cmd);
    if (NDMOff(@"selection")) return;
    NDMAddHover((NSView *)self, NDMHoverRow);
}

static void NDMSweepSelection(void) {
    int fixed = 0;
    for (NSWindow *w in [NSApp windows]) {
        if (!w.contentView) continue;
        NSView *root = w.contentView;
        while (root.superview && root.superview.window == w) root = root.superview;
        NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count) {
            NSView *v = stack.lastObject; [stack removeLastObject];
            if ([v isKindOfClass:[NSTableRowView class]] && ((NSTableRowView *)v).isSelected) {
                CALayer *ly = v.layer;
                if (ly && ly.cornerRadius != 6) {
                    ly.cornerRadius = 6;
                    ly.masksToBounds = YES;
                    [v setNeedsDisplay:YES];
                    fixed++;
                }
            }
            [stack addObjectsFromArray:v.subviews];
        }
    }
    if (fixed) NDMDlog(@"sweep: rounded %d pre-selected rows", fixed);
}

// ---------------- 安装 ----------------
// 类局部 hook：目标类若"自己"实现了 sel 则替换其 IMP；否则（继承自父类）
// 用 class_addMethod 在目标类新增一个覆写，orig 保存父类 IMP 供 super 调用。
// 关键：绝不 method_setImplementation 继承来的 Method——那会污染父类、
// 波及全部同类控件（实测：曾劫持 NSControl.mouseDown / NSView.updateTrackingAreas，
// 导致确认窗 HoverButton 等一切按钮点击失灵）。
static void NDMInstallHook(Class target, SEL sel, IMP newImp, IMP *origOut) {
    if (!target) return;
    Method m  = class_getInstanceMethod(target, sel);
    Class  sc = class_getSuperclass(target);
    Method sm = sc ? class_getInstanceMethod(sc, sel) : NULL;
    BOOL own = m && (!sm || method_getImplementation(m) != method_getImplementation(sm));
    if (own) {
        if (origOut) *origOut = method_getImplementation(m);
        method_setImplementation(m, newImp);
    } else {
        Method ref = m ?: sm;
        if (!ref) { NDMDlog(@"hook skip (no impl): %@ %@", NSStringFromClass(target), NSStringFromSelector(sel)); return; }
        if (class_addMethod(target, sel, newImp, method_getTypeEncoding(ref))) {
            if (origOut) *origOut = sm ? method_getImplementation(sm) : NULL;
        } else {
            if (origOut) *origOut = m ? method_getImplementation(m) : NULL;
            method_setImplementation(m, newImp);
        }
    }
}

static void NDMPatch(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 1) 进度条（自定义类，drawRect 为自身实现）
        for (NSString *name in @[@"NeatProgressBar", @"NeatSegmentsProgressBar"]) {
            Class c = NSClassFromString(name);
            if (!c) { NDMDlog(@"class not found: %@", name); continue; }
            Method m = class_getInstanceMethod(c, @selector(drawRect:));
            if (!m) { NDMDlog(@"%@: no drawRect", name); continue; }
            IMP *slot = [name isEqualToString:@"NeatProgressBar"] ? &origProgA : &origProgB;
            *slot = method_getImplementation(m);
            method_setImplementation(m, (IMP)NDMCapsuleDraw);
            NDMDlog(@"capsule: %@", name);
        }
        Class progCls = NSClassFromString(@"NeatProgressBar");
        if (progCls) {
            Method msc = class_getInstanceMethod(progCls, @selector(setCurrentValue:));
            if (msc) {
                origSetCur = method_getImplementation(msc);
                method_setImplementation(msc, (IMP)HookedSetCurrentValue);
                NDMDlog(@"baranim hook installed");
            } else NDMDlog(@"setCurrentValue: not found");
        }
        // 2) 按钮按压：仅给 NSButton 自身新增 mouseDown:（orig=NSControl 的），不碰其它控件
        NDMInstallHook([NSButton class], @selector(mouseDown:), (IMP)HookedBtnMouseDown, &origBtnMouseDown);
        // 3) 复选/单选自绘：给 NSButtonCell 新增 drawWithFrame:inView:（orig=NSCell 的）
        NDMInstallHook([NSButtonCell class], @selector(drawWithFrame:inView:), (IMP)HookedCellDraw, &origCellDraw);
        NDMDlog(@"checkradio hook installed");
        // 4) 列表选中行圆角 + 行 hover
        selOrigMap = [NSMutableDictionary new];
        SEL ds = @selector(drawSelectionInRect:);
        // updateTrackingAreas 继承自 NSView → 必须类局部新增，否则劫持全部 NSView
        NDMInstallHook([NSTableRowView class], @selector(updateTrackingAreas), (IMP)HookedRowUpdateTA, &origRowUpdateTA);
        unsigned int n = 0;
        Class *classes = objc_copyClassList(&n);
        for (unsigned int i = 0; i < n; i++) {
            Class c = classes[i];
            BOOL isRow = NO;
            for (Class s = c; s; s = class_getSuperclass(s))
                if (s == [NSTableRowView class]) { isRow = YES; break; }
            if (!isRow) continue;
            Method mc = class_getInstanceMethod(c, ds);
            if (!mc) continue;
            Method mp = class_getInstanceMethod(class_getSuperclass(c), ds);
            BOOL ownImpl = !mp || method_getImplementation(mc) != method_getImplementation(mp);
            if (c == [NSTableRowView class] || ownImpl) {
                selOrigMap[NSStringFromClass(c)] = [NSValue valueWithPointer:method_getImplementation(mc)];
                method_setImplementation(mc, (IMP)NDMRoundSelection);
            }
        }
        if (classes) free(classes);
        Method mss = class_getInstanceMethod([NSTableRowView class], @selector(setSelected:));
        if (mss) {
            origRowViewSetSel = method_getImplementation(mss);
            method_setImplementation(mss, (IMP)NDMRowViewSetSelected);
        }
        NDMDlog(@"v6 patch installed");
    });
}

// 诊断：抓原始 ObjC 异常（AppKit reportException 在 os_log 格式化 callStackSymbols 时
// 会踩 dyld findClosestSymbol SIGSEGV，异常本体反而看不到）
static void NDMExcHandler(NSException *e) {
    NDMDlog(@"EXC %@ | %@ | %@", e.name, e.reason,
            [e.callStackSymbols componentsJoinedByString:@" <- "]);
    abort();
}

__attribute__((constructor))
static void NDMEntry(void) {
    NSSetUncaughtExceptionHandler(&NDMExcHandler);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NDMPatch();
        NDMScanViews();
        NDMSweepSelection();
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowDidBecomeKeyNotification object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note){
                NDMScanViews();
                NDMSweepSelection();
                NDMRestyleFocus();
            }];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowDidResignKeyNotification object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note){ NDMRestyleFocus(); }];
        // 兜底扫描（延迟创建的视图 / 焦点变化）
        [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *t){
            NDMScanViews();
            NDMSweepSelection();
            NDMRestyleFocus();
        }];
    });
}
