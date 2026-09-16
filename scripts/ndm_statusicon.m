// ndm_statusicon.m — 状态栏图标改为单色，并随菜单栏明暗自动黑白变色
//
// 背景：
//   NDM 状态栏用的是 neaticon.png（浅蓝渐变圆角块 + 白色箭头）。macOS 只对
//   template image 做明暗自适应，而它是彩色图 —— 所以永远是那块蓝色。
//
// 两个坑（都实测过）：
//   1) neaticon.png 还被 NeatQuitWindow.nib / NeatAboutWindow.nib 引用（退出确认框
//      左侧图标），所以不能改这张图，要另起一张只在状态栏用。
//   2) NDM 的状态项不是标准 NSStatusBarButton，而是自定义 view ——
//      自定义 view 的 drawRect 里直接绘制时，**template 属性不生效**，
//      无论深浅都会按位图原色画出来。所以这里不用 template，
//      改用 drawingHandler 动态图，绘制时按当前外观取色。
//
// 编译：
//   clang -arch arm64 -arch x86_64 -dynamiclib -fobjc-arc \
//     -framework Foundation -framework AppKit \
//     -install_name @executable_path/../Frameworks/ndm_statusicon.dylib \
//     -o ndm_statusicon.dylib ndm_statusicon.m
//
// 日志开关：defaults write com.NeatDownloadManager ndm_statusicon_log -bool YES

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSString *const kSourceName = @"neaticon";         // 原彩色图标（对话框也在用，保持不动）
static NSString *const kGlyphName  = @"neaticonTemplate"; // 单色 glyph（名字以 Template 结尾）

static NSImage *gSourceIcon = nil;
static NSImage *gMonoIcon = nil;

static void DbgLog(NSString *fmt, ...) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"ndm_statusicon_log"]) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%.3f %@\n", [NSDate date].timeIntervalSince1970, msg];
    FILE *f = fopen("/tmp/ndm_statusicon.log", "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
}

// 单色图：用 glyph 的 alpha 当蒙版，绘制时按「当前外观」取色。
// drawingHandler 每次绘制都会重新执行，所以外观变化后重绘即可自动换色 ——
// 这是最省事也最"系统正确"的做法（labelColor 会跟随菜单栏 vibrancy）。
static NSImage *MonoIcon(void) {
    if (gMonoIcon) return gMonoIcon;
    NSImage *glyph = [NSImage imageNamed:kGlyphName];
    if (!glyph) { DbgLog(@"[statusicon] !! 资源缺失: %@", kGlyphName); return nil; }
    DbgLog(@"[statusicon] glyph loaded size=%@ template=%d",
           NSStringFromSize(glyph.size), glyph.isTemplate);
    gMonoIcon = [NSImage imageWithSize:glyph.size flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        [[NSColor labelColor] setFill];
        NSRectFillUsingOperation(dstRect, NSCompositingOperationSourceOver);
        [glyph drawInRect:dstRect fromRect:NSZeroRect
                operation:NSCompositingOperationDestinationIn fraction:1.0];
        return YES;
    }];
    return gMonoIcon;
}

// 诊断：把 view 的实际渲染结果采出来，看它到底画成什么颜色
static void Diagnose(NSView *v, NSString *tag) {
    if (!v) return;
    DbgLog(@"[diag/%@] view=%@ frame=%@ appearance=%@ effective=%@",
           tag, NSStringFromClass([v class]), NSStringFromRect(v.frame),
           v.appearance.name ?: @"nil", v.effectiveAppearance.name);
    NSImage *cur = [v respondsToSelector:@selector(image)] ? [(id)v image] : nil;
    DbgLog(@"[diag/%@] view.image=%@ size=%@ template=%d", tag, cur,
           cur ? NSStringFromSize(cur.size) : @"-", cur ? cur.isTemplate : -1);
    NSAppearance *ea = v.effectiveAppearance;
    __block NSColor *lc = nil;
    [ea performAsCurrentDrawingAppearance:^{
        lc = [[NSColor labelColor] colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    }];
    DbgLog(@"[diag/%@] labelColor under view appearance: r=%.2f g=%.2f b=%.2f",
           tag, lc.redComponent, lc.greenComponent, lc.blueComponent);
    // 真正渲染一遍，采样不透明像素的平均亮度
    if (v.bounds.size.width > 0 && v.bounds.size.height > 0) {
        NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
        if (rep) {
            [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
            long sum = 0, n = 0;
            for (NSInteger y = 0; y < rep.pixelsHigh; y++) {
                for (NSInteger x = 0; x < rep.pixelsWide; x++) {
                    NSColor *c = [rep colorAtX:x y:y];
                    if (!c) continue;
                    c = [c colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
                    if (c.alphaComponent < 0.5) continue;
                    sum += (long)((c.redComponent + c.greenComponent + c.blueComponent) / 3.0 * 255);
                    n++;
                }
            }
            if (n > 0) DbgLog(@"[diag/%@] rendered %ld opaque px, avg luma=%.0f", tag, n, (double)sum / n);
        }
    }
}

// 保险：菜单栏明暗变化时，让 view 重绘，确保 drawingHandler 被重新求值
@interface NdmAppearanceWatcher : NSObject
@end
@implementation NdmAppearanceWatcher
- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj
                        change:(NSDictionary *)ch context:(void *)ctx {
    if ([kp isEqualToString:@"effectiveAppearance"]) {
        DbgLog(@"[statusicon] appearance changed -> %@ ; redraw",
               [(NSView *)obj effectiveAppearance].name);
        [(NSView *)obj setNeedsDisplay:YES];
    }
}
@end

static NdmAppearanceWatcher *gWatcher = nil;
static NSMutableSet *gWatched = nil;

static void WatchAppearance(NSView *v) {
    if (!v) return;
    if (!gWatcher) gWatcher = [NdmAppearanceWatcher new];
    if (!gWatched) gWatched = [NSMutableSet set];
    NSValue *key = [NSValue valueWithNonretainedObject:v];
    if ([gWatched containsObject:key]) return;
    @try {
        [v addObserver:gWatcher forKeyPath:@"effectiveAppearance"
               options:NSKeyValueObservingOptionNew context:NULL];
        [gWatched addObject:key];
        DbgLog(@"[statusicon] watching appearance of %@", NSStringFromClass([v class]));
    } @catch (NSException *e) {
        DbgLog(@"[statusicon] KVO 失败 on %@: %@", NSStringFromClass([v class]), e.reason);
    }
}

static void ApplyToItem(NSStatusItem *item, NSString *why) {
    if (!item) return;
    NSImage *mono = MonoIcon();
    if (!mono) return;

    NSButton *btn = item.button;
    if (btn) {
        if (btn.image != mono) {
            btn.image = mono;
            DbgLog(@"[statusicon] (%@) button.image -> mono", why);
        }
        if ([why isEqualToString:@"immediate"]) Diagnose(btn, why);
        return;
    }
    NSView *v = item.view;
    if (v && [v respondsToSelector:@selector(setImage:)]) {
        [(id)v setImage:mono];
        DbgLog(@"[statusicon] (%@) view.image -> mono", why);
        WatchAppearance(v);
        if ([why isEqualToString:@"after1.0s"]) Diagnose(v, why);
    } else if (v) {
        DbgLog(@"[statusicon] (%@) view=%@ 不响应 setImage:", why, NSStringFromClass([v class]));
    }
}

#pragma mark - hooks

static IMP gOrigImageNamed = NULL;
static NSImage *HookImageNamed(Class cls, SEL _cmd, NSString *name) {
    NSImage *img = ((NSImage *(*)(Class, SEL, NSString *))(gOrigImageNamed))(cls, _cmd, name);
    if (img && [name isEqualToString:kSourceName]) gSourceIcon = img;
    return img;
}

static IMP gOrigStatusItemWithLength = NULL;
static id HookStatusItemWithLength(id self, SEL _cmd, CGFloat length) {
    NSStatusItem *item = ((id (*)(id, SEL, CGFloat))gOrigStatusItemWithLength)(self, _cmd, length);
    ApplyToItem(item, @"immediate");
    for (NSNumber *d in @[@0.3, @1.0, @2.5]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(),
                       ^{ ApplyToItem(item, [NSString stringWithFormat:@"after%.1fs", d.doubleValue]); });
    }
    return item;
}

static IMP gOrigButtonSetImage = NULL;
static void HookButtonSetImage(id self, SEL _cmd, NSImage *img) {
    if (img && gSourceIcon && img == gSourceIcon) {
        NSImage *mono = MonoIcon();
        if (mono) { DbgLog(@"[statusicon] intercepted setImage: (source) -> mono"); img = mono; }
    }
    ((void (*)(id, SEL, NSImage *))gOrigButtonSetImage)(self, _cmd, img);
}

static void Swizzle(Class cls, SEL sel, IMP newIMP, IMP *origOut, BOOL classMethod) {
    if (!cls) { DbgLog(@"[statusicon] !! class nil %@", NSStringFromSelector(sel)); return; }
    Method m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) { DbgLog(@"[statusicon] !! missing %@ on %@", NSStringFromSelector(sel), cls); return; }
    *origOut = method_getImplementation(m);
    method_setImplementation(m, newIMP);
}

__attribute__((constructor))
static void ndm_statusicon_init(void) {
    @autoreleasepool {
        DbgLog(@"[statusicon] loaded");
        Swizzle(objc_getClass("NSImage"), @selector(imageNamed:), (IMP)HookImageNamed, &gOrigImageNamed, YES);
        Swizzle(objc_getClass("NSStatusBar"), @selector(statusItemWithLength:), (IMP)HookStatusItemWithLength, &gOrigStatusItemWithLength, NO);
        Swizzle(objc_getClass("NSStatusBarButton"), @selector(setImage:), (IMP)HookButtonSetImage, &gOrigButtonSetImage, NO);
    }
}
