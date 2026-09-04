// ndm_theme.m v3 — NDM 2 主题注入 dylib（保守版）
// 仅 2 个纯绘制层效果，零交互侵入：
//   1) 进度条圆角胶囊化：NeatProgressBar / NeatSegmentsProgressBar 的 drawRect 输出裁剪为胶囊
//   2) 列表选中行圆角：裁剪 NSTableRowView 及其全部子类的 drawSelectionInRect: 输出
//      （选中底色仍由原实现绘制，只是被裁成圆角 → 视觉天然跟随点击，不改任何选中状态）
// 不做：按钮动效、hover、trackingArea、anchorPoint、selectionHighlightStyle 修改
// 日志：/tmp/ndm_theme.log
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static void NDMDlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void NDMDlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen("/tmp/ndm_theme.log", "a");
    if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); }
}

// ---------------- 1) 进度条胶囊化 ----------------
static IMP origProgA = NULL;   // NeatProgressBar 的原 drawRect
static IMP origProgB = NULL;   // NeatSegmentsProgressBar 的原 drawRect

static void NDMCapsuleDraw(id self, SEL _cmd, NSRect r) {
    Class B = NSClassFromString(@"NeatSegmentsProgressBar");
    IMP orig = (B && [(Class)B isSubclassOfClass:[NSView class]] && [self isKindOfClass:B]) ? origProgB : origProgA;
    if (r.size.height < 4 || r.size.width < 4 || !orig) {
        if (orig) ((void(*)(id,SEL,NSRect))orig)(self, _cmd, r);
        return;
    }
    NSGraphicsContext *ctx = [NSGraphicsContext currentContext];
    [ctx saveGraphicsState];
    NSRect rr = NSInsetRect(r, 0.5, 0.5);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:rr
                      xRadius:r.size.height/2.0 yRadius:r.size.height/2.0];
    [p addClip];
    ((void(*)(id,SEL,NSRect))orig)(self, _cmd, r);
    [ctx restoreGraphicsState];
}

// ---------------- 2) 选中行圆角裁剪（覆盖 NSTableRowView 及其所有子类） ----------------
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
    static int logged = 0;
    if (logged < 5) {
        logged++;
        NDMDlog(@"drawSel called: %@ bounds=%.0fx%.0f", NSStringFromClass(object_getClass(self)),
                [(NSView *)self bounds].size.width, [(NSView *)self bounds].size.height);
    }
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

// 选中状态变化：同步给 layer 加圆角（蓝色若为 layer 背景色则由此生效）
static IMP origRowViewSetSel = NULL;
static void NDMRowViewSetSelected(id self, SEL _cmd, BOOL sel) {
    if (origRowViewSetSel) ((void(*)(id,SEL,BOOL))origRowViewSetSel)(self, _cmd, sel);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSView *v = (NSView *)self;
        if (!v.window) return;
        if (!v.layer) [v wantsLayer];
        if (v.layer) { v.layer.cornerRadius = 6; v.layer.masksToBounds = YES; }
        [v setNeedsDisplay:YES];
    });
}

// ---------------- 安装 ----------------
static void NDMPatch(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 1) 进度条
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
        // 2) 列表选中行圆角：swizzle NSTableRowView 基类 + 所有有自己的 drawSelectionInRect:
        //    实现的子类（含 AppKit 私有类，逐类替换、逐类存原 IMP）
        selOrigMap = [NSMutableDictionary new];
        SEL ds = @selector(drawSelectionInRect:);
        int overridden = 0, inherited = 0;
        NSMutableArray *subT = [NSMutableArray array];
        unsigned int n = 0;
        Class *classes = objc_copyClassList(&n);
        for (unsigned int i = 0; i < n; i++) {
            Class c = classes[i];
            // 顺手记录自定义 NSTableView 子类（诊断用）
            if (![NSStringFromClass(c) hasPrefix:@"NS"] && ![NSStringFromClass(c) hasPrefix:@"_"]) {
                for (Class s = c; s; s = class_getSuperclass(s))
                    if (s == [NSTableView class]) { [subT addObject:NSStringFromClass(c)]; break; }
            }
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
                if (ownImpl && c != [NSTableRowView class]) {
                    overridden++;
                    NDMDlog(@"sel-override swizzled: %@", NSStringFromClass(c));
                }
            } else inherited++;   // 继承基类 → 已被基类替换覆盖
        }
        if (classes) free(classes);
        NDMDlog(@"table subclasses: %@", subT);
        NDMDlog(@"row-clip: base + %d overrides (%d inherit)", overridden, inherited);
        // setSelected: 钩子（layer 圆角兜底）
        SEL ss = @selector(setSelected:);
        Method mss = class_getInstanceMethod([NSTableRowView class], ss);
        if (mss) {
            origRowViewSetSel = method_getImplementation(mss);
            method_setImplementation(mss, (IMP)NDMRowViewSetSelected);
            NDMDlog(@"setSelected hook installed");
        }
        NDMDlog(@"v3 patch installed");
    });
}

__attribute__((constructor))
static void NDMEntry(void) {
    // 等 App 的自定义类完成注册后安装
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ NDMPatch(); });
}
