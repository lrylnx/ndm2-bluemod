// ndm_theme.m — NDM 2 主题注入 dylib
// 效果：1) 列表选中/hover 圆角高亮  2) 图标按钮 hover/按压动效  3) 进度条圆角胶囊化
// 日志：/tmp/ndm_theme.log
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// ---------------- logging ----------------
static void NLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void NLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen("/tmp/ndm_theme.log", "a");
    if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); }
}

// ---------------- helpers ----------------
static NSColor *NDMSelColor(void) {
    return [NSColor colorWithCalibratedRed:61.0/255.0 green:155.0/255.0 blue:1.0 alpha:0.22];
}
static NSColor *NDMHoverColor(void) {
    return [NSColor colorWithCalibratedRed:61.0/255.0 green:155.0/255.0 blue:1.0 alpha:0.09];
}
static NSInteger NDMHoverRow(NSTableView *tv) {
    NSNumber *n = objc_getAssociatedObject(tv, @selector(NDMHoverRowMarker));
    return n ? n.integerValue : -1;
}
static NSString * const NDMThemedMarker = @"ndm_themed";

static void NDMCenterAnchor(CALayer *l) {
    // 一次性把 anchorPoint 设为中心并补偿 position（避免点击时图层移位）
    if (l.anchorPoint.x == 0.5 && l.anchorPoint.y == 0.5) return;
    CGPoint p = l.position, a = l.anchorPoint;
    CGSize s = l.bounds.size;
    l.position = CGPointMake(p.x + (0.5 - a.x) * s.width, p.y + (0.5 - a.y) * s.height);
    l.anchorPoint = CGPointMake(0.5, 0.5);
}
static void NDMScaleLayer(NSView *v, CGFloat scale, CGFloat opacity, NSTimeInterval dur) {
    if (!v.layer) return;
    [CATransaction begin];
    [CATransaction setAnimationDuration:dur];
    if (scale == 1.0 && opacity == 1.0) {
        v.layer.transform = CATransform3DIdentity;
        v.layer.opacity = 1;
    } else {
        v.layer.transform = CATransform3DMakeScale(scale, scale, 1);
        v.layer.opacity = opacity;
    }
    [CATransaction commit];
}

// ---------------- helper object: tracking-area owner ----------------
@interface NDMThemeHelper : NSObject
- (void)install:(NSView *)view;
@end

@implementation NDMThemeHelper

// 追踪区事件统一走这里（owner = helper）
- (void)mouseEntered:(NSEvent *)e {
    id btn = e.trackingArea.userInfo[@"btn"];
    if ([btn isKindOfClass:[NSButton class]]) { NDMScaleLayer(btn, 1.06, 0.85, 0.12); return; }
    id tv = e.trackingArea.userInfo[@"table"];
    if ([tv isKindOfClass:[NSTableView class]]) [self updateHover:tv event:e];
}
- (void)mouseExited:(NSEvent *)e {
    id btn = e.trackingArea.userInfo[@"btn"];
    if ([btn isKindOfClass:[NSButton class]]) { NDMScaleLayer(btn, 1.0, 1.0, 0.15); return; }
    id tv = e.trackingArea.userInfo[@"table"];
    if ([tv isKindOfClass:[NSTableView class]]) [self updateHover:tv event:nil];
}
- (void)mouseMoved:(NSEvent *)e {
    id tv = e.trackingArea.userInfo[@"table"];
    if ([tv isKindOfClass:[NSTableView class]]) [self updateHover:tv event:e];
}

- (void)updateHover:(NSTableView *)tv event:(NSEvent *)e {
    NSInteger row = -1;
    if (e) {
        NSPoint p = [tv convertPoint:e.locationInWindow fromView:nil];
        row = [tv rowAtPoint:p];
        if (row < 0) row = -1;
    }
    if (row == NDMHoverRow(tv)) return;
    // 只重画变化的两行
    NSInteger old = NDMHoverRow(tv);
    objc_setAssociatedObject(tv, @selector(NDMHoverRowMarker), @(row), OBJC_ASSOCIATION_RETAIN);
    if (old >= 0) [tv setNeedsDisplayInRect:[tv rectOfRow:old]];
    if (row >= 0) [tv setNeedsDisplayInRect:[tv rectOfRow:row]];
}

// 给视图挂追踪区 + 标记
- (void)install:(NSView *)view {
    if (objc_getAssociatedObject(view, (__bridge const void *)NDMThemedMarker)) return;
    objc_setAssociatedObject(view, (__bridge const void *)NDMThemedMarker, @YES, OBJC_ASSOCIATION_RETAIN);
    NSTrackingAreaOptions opt = NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                                NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect | NSTrackingAssumeInside;
    if ([view isKindOfClass:[NSTableView class]]) {
        NSTrackingArea *ta = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                        options:opt owner:self userInfo:@{@"table": view}];
        [view addTrackingArea:ta];
        NLog(@"table themed: %@ frame=%@", NSStringFromClass([view class]), NSStringFromRect(view.frame));
    } else if ([view isKindOfClass:[NSButton class]]) {
        NSTrackingArea *ta = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                                NSTrackingInVisibleRect | NSTrackingAssumeInside
                        owner:self userInfo:@{@"btn": view}];
        [view addTrackingArea:ta];
        view.wantsLayer = YES;
        NDMCenterAnchor(view.layer);
    }
}

@end

static NDMThemeHelper *helper = nil;

// ---------------- 1) 表格背景 swizzle：自绘圆角选中/hover ----------------
static void (*origDrawBg)(id, SEL, NSRect);
static void NDMTableDrawBg(id self, SEL _cmd, NSRect clip) {
    if (origDrawBg) origDrawBg(self, _cmd, clip);
    NSTableView *tv = self;
    NSRange visible = [tv rowsInRect:clip];
    for (NSUInteger r = visible.location; r < NSMaxRange(visible); r++) {
        BOOL sel = [tv isRowSelected:r];
        BOOL hov = (r == NDMHoverRow(tv));
        if (!sel && !hov) continue;
        NSRect rr = NSInsetRect([tv rectOfRow:r], 2.0, 1.5);
        if (rr.size.height < 4) continue;
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:rr xRadius:6 yRadius:6];
        if (sel) [NDMSelColor() setFill]; else [NDMHoverColor() setFill];
        [p fill];
    }
}

// ---------------- 1b) NeatTableView drawRow 圆角裁剪（其自带全宽选中蓝色）----------------
static IMP origNeatDrawRow = NULL;
static void NDMRoundRowDraw(id self, SEL _cmd, NSInteger row, NSRect clip) {
    NSTableView *tv = self;
    NSRect rr = NSInsetRect([tv rectOfRow:row], 2.0, 1.5);
    NSGraphicsContext *ctx = [NSGraphicsContext currentContext];
    [ctx saveGraphicsState];
    if (rr.size.height >= 4) {
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:rr xRadius:6 yRadius:6];
        [p addClip];
    }
    ((void(*)(id,SEL,NSInteger,NSRect))origNeatDrawRow)(self, _cmd, row, clip);
    [ctx restoreGraphicsState];
}

// ---------------- 3) 进度条 swizzle：圆角胶囊裁剪 ----------------
static IMP origNeatPBar = NULL, origSegPBar = NULL;
static void NDMCapsuleDraw(id self, SEL _cmd, NSRect r) {
    IMP orig = [self isKindOfClass:NSClassFromString(@"NeatSegmentsProgressBar")] ? origSegPBar : origNeatPBar;
    if (!orig) return;
    if (r.size.height < 4) { ((void(*)(id,SEL,NSRect))orig)(self, _cmd, r); return; }
    NSGraphicsContext *ctx = [NSGraphicsContext currentContext];
    [ctx saveGraphicsState];
    NSRect rr = NSInsetRect(r, 0.5, 0.5);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:rr
                      xRadius:r.size.height/2.0 yRadius:r.size.height/2.0];
    [p addClip];
    ((void(*)(id,SEL,NSRect))orig)(self, _cmd, r);
    [ctx restoreGraphicsState];
}

static void Swizzle(Class c, SEL sel, IMP newImp, IMP *origOut) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { NLog(@"NO METHOD %@ %@", c, NSStringFromSelector(sel)); return; }
    *origOut = method_getImplementation(m);
    method_setImplementation(m, newImp);
    NLog(@"swizzled %@ %@", c, NSStringFromSelector(sel));
}

// ---------------- 2) 按钮按压动效：本地事件监听（无 swizzle，零风险）----------------
static NSMutableSet *NDMThemedButtons(void) {
    static NSMutableSet *set; static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}
static void NDMButtonPressAnim(NSButton *b, CGFloat scale, CGFloat opacity) {
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.10];
    b.layer.transform = CATransform3DMakeScale(scale, scale, 1);
    b.layer.opacity = opacity;
    [CATransaction commit];
}

static void InstallButtonPressMonitor(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp;
        [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *e) {
            NSWindow *w = e.window;
            if (!w || w.className && [w.className containsString:@"StatusBar"]) return e;
            NSView *hit = [w.contentView hitTest:[w.contentView convertPoint:e.locationInWindow fromView:nil]];
            while (hit && ![hit isKindOfClass:[NSButton class]]) hit = hit.superview;
            if (!hit) return e;
            NSButton *b = (NSButton *)hit;
            if (![NDMThemedButtons() containsObject:b]) return e;
            if (e.type == NSEventTypeLeftMouseDown) {
                NDMButtonPressAnim(b, 0.92, 0.9);
            } else {
                NDMButtonPressAnim(b, 1.0, 1.0);
            }
            return e;
        }];
        NLog(@"press monitor installed");
    });
}

static void NDMStyleButton(NSButton *b);
static void NDMStyleTextField(NSTextField *f);

// ---------------- 扫描注册 ----------------
static void ScanWindows(void) {
    static NSMutableDictionary *seen; static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableDictionary new]; });
    int fresh = 0;
    static NSMutableSet *knownClasses; static dispatch_once_t onceCls;
    dispatch_once(&onceCls, ^{ knownClasses = [NSMutableSet set]; });
    NSMutableSet *newClasses = [NSMutableSet set];
    for (NSWindow *w in [NSApp windows]) {
        if (!w.contentView) continue;
        // 从窗口根视图开始（覆盖标题栏/工具栏层级）
        NSView *root = w.contentView;
        while (root.superview && root.superview.window == w) root = root.superview;
        NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count) {
            NSView *v = stack.lastObject; [stack removeLastObject];
            {
                NSString *cn = NSStringFromClass(v.class);
                if (![cn hasPrefix:@"NS"] && ![cn hasPrefix:@"_"] && ![cn hasPrefix:@"__"] &&
                    ![knownClasses containsObject:cn]) {
                    [knownClasses addObject:cn]; [newClasses addObject:cn];
                }
            }
            BOOL isTable = [v isKindOfClass:[NSTableView class]];
            BOOL isBtn = [v isKindOfClass:[NSButton class]];
            BOOL isField = [v isKindOfClass:[NSTextField class]];
            if ((isTable || isBtn || isField) && v.window && !v.hiddenOrHasHiddenAncestor) {
                NSString *key = [NSString stringWithFormat:@"%@|%@|%@", NSStringFromClass(v.class),
                                 NSStringFromRect(v.frame), w.title];
                if (seen[key]) continue;
                seen[key] = @YES;
                if (isTable) {
                    NSTableView *tv = (NSTableView *)v;
                    tv.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
                    [helper install:v]; fresh++;
                } else if (isField) {
                    NDMStyleTextField((NSTextField *)v); fresh++;
                } else {
                    NDMStyleButton((NSButton *)v);
                    [helper install:v];
                    [NDMThemedButtons() addObject:v]; fresh++;
                }
            }
            [stack addObjectsFromArray:v.subviews];
        }
    }
    if (newClasses.count) {
        NLog(@"new app view classes: %@", [newClasses.allObjects sortedArrayUsingSelector:@selector(compare:)]);
    }
    if (fresh) NLog(@"scan: %d fresh views, %d buttons total", fresh, (int)NDMThemedButtons().count);
}

// ---------------- 文字按钮/输入框现代化 ----------------
static void NDMStyleButton(NSButton *b) {
    // 只处理带文字的 bezel 按钮（图标按钮保持原样）
    if (![b isBordered] || b.title.length == 0) return;
    [b setBordered:NO];
    b.wantsLayer = YES;
    b.layer.cornerRadius = 6;
    b.layer.borderWidth = 1;
    b.layer.borderColor = [NSColor colorWithCalibratedRed:0.82 green:0.86 blue:0.91 alpha:1].CGColor;
    b.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.99 green:0.99 blue:1.0 alpha:1].CGColor;
    NLog(@"button styled: '%@' class=%@", b.title, NSStringFromClass(b.class));
}

static void NDMStyleTextField(NSTextField *f) {
    if (![f isBordered] || ![f isEditable]) return;
    [f setBordered:NO];
    f.wantsLayer = YES;
    f.layer.cornerRadius = 5;
    f.layer.borderWidth = 1;
    f.layer.borderColor = [NSColor colorWithCalibratedRed:0.80 green:0.85 blue:0.90 alpha:1].CGColor;
    f.layer.backgroundColor = [NSColor whiteColor].CGColor;
    NLog(@"field styled: class=%@", NSStringFromClass(f.class));
}

// ---------------- entry ----------------
__attribute__((constructor))
static void NDMThemeEntry(void) {
    @autoreleasepool {
        NLog(@"===== ndm_theme loaded, pid=%d =====", getpid());
        helper = [NDMThemeHelper new];

        // 1) 表格背景
        Swizzle([NSTableView class], @selector(drawBackgroundInClipRect:),
                (IMP)NDMTableDrawBg, (IMP *)&origDrawBg);

        // 1b) NeatTableView 行绘制圆角（用 addMethod 加子类覆盖，不动父类）
        Class ntc = NSClassFromString(@"NeatTableView");
        if (ntc) {
            SEL dr = @selector(drawRow:clipRect:);
            Method m = class_getInstanceMethod([NSTableView class], dr);
            origNeatDrawRow = method_getImplementation(m);
            if (!class_addMethod(ntc, dr, (IMP)NDMRoundRowDraw, method_getTypeEncoding(m)))
                NLog(@"NeatTableView already overrides drawRow:clipRect:");
            else NLog(@"added NeatTableView drawRow clip");
        } else NLog(@"class not found: NeatTableView");

        // 3) 进度条（App 自有类）
        Class pc = NSClassFromString(@"NeatProgressBar");
        if (pc) Swizzle(pc, @selector(drawRect:), (IMP)NDMCapsuleDraw, &origNeatPBar);
        else NLog(@"class not found: NeatProgressBar");
        Class sc = NSClassFromString(@"NeatSegmentsProgressBar");
        if (sc) Swizzle(sc, @selector(drawRect:), (IMP)NDMCapsuleDraw, &origSegPBar);
        else NLog(@"class not found: NeatSegmentsProgressBar");

        // 2) 按钮动效
        InstallButtonPressMonitor();

        // 启动后等窗口就绪再扫描 + keyWindow 变化时重扫
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ScanWindows(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ScanWindows(); });
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification
            object:nil queue:nil usingBlock:^(NSNotification *n) { ScanWindows(); }];
        NLog(@"entry done");
    }
}
