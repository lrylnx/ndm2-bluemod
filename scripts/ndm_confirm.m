// ndm_confirm.m — NDM2 浏览器下载确认窗口（IDM 风格）
// Hook:
//   1) -[AppDelegate handleBrowserDownloadRequest:]  弹出确认窗；取消则不启动下载、不弹主界面
//   2) -[NeatDownloadWindow initWithValues:appStatusMenu:request:tempOutputPath:finalOutputPath:rowIdx:doResume:]
//      -[NeatDownloadWindowMKV initMKVWithValues:...]  用用户所选目录覆盖 temp/final 输出路径
// 编译:
//   clang -arch arm64 -arch x86_64 -dynamiclib -fobjc-arc \
//     -framework Foundation -framework AppKit \
//     -install_name @executable_path/../Frameworks/ndm_confirm.dylib \
//     -o ndm_confirm.dylib ndm_confirm.m

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSString *gOverrideDir = nil;   // 待消费的覆盖目录
static NSString *kLastDirKey = @"ndm_confirm_last_dir";

static NSColor *BlueColor(void) {
    return [NSColor colorWithCalibratedRed:0.239 green:0.608 blue:1.0 alpha:1.0]; // #3D9BFF
}

#pragma mark - IMP 保存/恢复

static void Exchange(Class cls, SEL sel, IMP newIMP) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NSLog(@"[ndm_confirm] method missing: %@ on %@", NSStringFromSelector(sel), cls); return; }
    IMP old = method_getImplementation(m);
    if (!old) return;
    method_setImplementation(m, newIMP);
    objc_setAssociatedObject(cls, sel, [NSValue valueWithPointer:old], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static IMP OrigIMP(Class cls, SEL sel) {
    NSValue *v = objc_getAssociatedObject(cls, sel);
    return v ? (IMP)[v pointerValue] : NULL;
}

#pragma mark - 协议解析

// 解析扩展行协议 "N:value\r\n"（单字符数字键）
static BOOL ParsePayload(NSString *payload, NSString **outUrl,
                         NSString **outName, NSString **outCategory) {
    if (![payload isKindOfClass:[NSString class]]) return NO;
    NSMutableDictionary *kv = [NSMutableDictionary dictionary];
    for (NSString *line in [payload componentsSeparatedByString:@"\r\n"]) {
        if (line.length < 2) continue;
        NSRange r = [line rangeOfString:@":"];
        if (r.location != 1) continue;
        NSString *k = [line substringToIndex:1];
        NSString *v = [line substringFromIndex:2];
        if (v.length) kv[k] = v;
    }
    if (!kv[@"2"]) return NO;              // 没有 2: URL 键 → 不视为下载请求
    if (outUrl) *outUrl = kv[@"2"];
    if (outName) *outName = kv[@"3"];
    if (outCategory) *outCategory = kv[@"6"] ?: @"normal";
    return YES;
}

// 从 URL 提取文件名（去 query/fragment、URL 解码）
static NSString *DeriveNameFromURL(NSString *url) {
    if (!url.length) return nil;
    NSString *p = url;
    NSRange q = [p rangeOfString:@"?"];
    if (q.location != NSNotFound) p = [p substringToIndex:q.location];
    NSRange h = [p rangeOfString:@"#"];
    if (h.location != NSNotFound) p = [p substringToIndex:h.location];
    while (p.length > 1 && [p hasSuffix:@"/"]) p = [p substringToIndex:p.length - 1];
    NSString *name = [p lastPathComponent];
    NSString *dec = [name stringByRemovingPercentEncoding];
    if (dec.length) name = dec;
    if (!name.length || [name isEqualToString:@"/"]) return nil;
    return name;
}

// 把 payload 中 3: 文件名行替换为 newName（没有则插到 2: 行之后）
// 注意：不能追加到末尾——payload 末尾可能有空行/尾部标记，追加会破坏解析
static NSString *ReplaceNameInPayload(NSString *payload, NSString *newName) {
    NSMutableArray *lines = [[payload componentsSeparatedByString:@"\r\n"] mutableCopy];
    BOOL replaced = NO;
    for (NSUInteger i = 0; i < lines.count; i++) {
        if ([lines[i] hasPrefix:@"3:"]) {
            if (!replaced) {
                lines[i] = [NSString stringWithFormat:@"3:%@", newName];
                replaced = YES;
            } else {
                [lines removeObjectAtIndex:i--];
            }
        }
    }
    if (!replaced) {
        for (NSUInteger i = 0; i < lines.count; i++) {
            if ([lines[i] hasPrefix:@"2:"]) {
                [lines insertObject:[NSString stringWithFormat:@"3:%@", newName]
                            atIndex:i + 1];
                replaced = YES;
                break;
            }
        }
        if (!replaced) [lines addObject:[NSString stringWithFormat:@"3:%@", newName]];
    }
    NSString *out = [lines componentsJoinedByString:@"\r\n"];
    NSLog(@"[ndm_confirm] 最终payload=[%@]", [out stringByReplacingOccurrencesOfString:@"\r\n" withString:@" | "]);
    return out;
}

#pragma mark - 确认窗口

@interface ConfirmActionHandler : NSObject
@property (strong) NSWindow *win;
@property (strong) NSTextField *dirField, *nameField;
@end
@implementation ConfirmActionHandler
- (void)okClicked:(id)s     { [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancelClicked:(id)s { [NSApp stopModalWithCode:NSModalResponseCancel]; }
- (void)browseClicked:(id)s {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    [p setCanChooseDirectories:YES];
    [p setCanChooseFiles:NO];
    [p setCanCreateDirectories:YES];
    [p setPrompt:@"选择"];
    NSString *cur = [self.dirField stringValue];
    if (cur.length) [p setDirectoryURL:[NSURL fileURLWithPath:cur]];
    if ([p runModal] == NSModalResponseOK && p.directoryURL)
        [self.dirField setStringValue:p.directoryURL.path];
}
@end

// 自定义按钮：hover/按压自绘高亮，不依赖 App 激活状态
// App 非激活时系统不派发鼠标事件（tracking area 收不到 mouseEntered），
// 所以 RunConfirmDialog 里用全局 NSEvent monitor 补充驱动 hovered 状态
@interface HoverButton : NSButton
@property (nonatomic, assign) BOOL hovered;
@property (nonatomic, strong) NSColor *baseColor;   // 原始底色（nil = 系统默认样式）
@end
@implementation HoverButton
- (void)setHovered:(BOOL)h {
    if (_hovered == h) return;
    _hovered = h;
    NSColor *base = self.baseColor ?: [NSColor controlColor];
    if (h)   // 主按钮加深 18%，普通按钮淡蓝底提示
        self.bezelColor = self.baseColor
            ? [base blendedColorWithFraction:0.18 ofColor:[NSColor blackColor]]
            : [BlueColor() blendedColorWithFraction:0.12 ofColor:[NSColor whiteColor]];
    else
        self.bezelColor = self.baseColor;
    [self setNeedsDisplay:YES];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    for (NSTrackingArea *ta in self.trackingAreas) [self removeTrackingArea:ta];
    NSTrackingArea *ta = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
                    | NSTrackingInVisibleRect
               owner:self userInfo:nil];
    [self addTrackingArea:ta];
}
- (void)mouseEntered:(NSEvent *)e { self.hovered = YES; }
- (void)mouseExited:(NSEvent *)e  { self.hovered = NO; }
- (void)mouseDown:(NSEvent *)e {
    NSColor *base = self.baseColor ?: [NSColor controlColor];
    self.bezelColor = [base blendedColorWithFraction:0.35 ofColor:[NSColor blackColor]];
    [self setNeedsDisplay:YES];
    [super mouseDown:e];
    self.hovered = self.hovered;    // 触发按压后恢复（hover 状态重算底色）
    [self setNeedsDisplay:YES];
}
@end

static NSDictionary *RunConfirmDialog(NSString *url, NSString *fname,
                                      NSString *category, NSString *defaultDir) {
    __block NSDictionary *result = nil; // @{@"go":@YES, @"dir":..., @"name":...}
    void (^block)(void) = ^{
        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 470, 190)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        [win setTitle:@"新建下载任务"];
        [win setReleasedWhenClosed:NO];

        ConfirmActionHandler *handler = [ConfirmActionHandler new];

        NSRect sf = [NSScreen mainScreen].visibleFrame;
        NSFont *small = [NSFont systemFontOfSize:11];
        NSColor *gray = [NSColor secondaryLabelColor];
        CGFloat y = 156;

        NSTextField *urlLabel = [NSTextField labelWithString:@"网址:"];
        urlLabel.frame = NSMakeRect(16, y, 56, 17);
        NSTextField *urlField = [NSTextField labelWithString:url ?: @"(未知)"];
        urlField.frame = NSMakeRect(74, y, 380, 17);
        urlField.lineBreakMode = NSLineBreakByTruncatingMiddle;
        urlField.font = small; urlField.textColor = gray;
        y -= 28;

        NSTextField *nameLabel = [NSTextField labelWithString:@"文件名:"];
        nameLabel.frame = NSMakeRect(16, y, 56, 17);
        NSTextField *nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(74, y - 2, 380, 22)];
        nameField.stringValue = fname ?: @"";
        handler.nameField = nameField;
        y -= 34;

        NSTextField *dirLabel = [NSTextField labelWithString:@"保存到:"];
        dirLabel.frame = NSMakeRect(16, y, 56, 17);
        NSTextField *dirField = [[NSTextField alloc] initWithFrame:NSMakeRect(74, y - 2, 310, 22)];
        dirField.stringValue = defaultDir ?: @"";
        handler.dirField = dirField;

        HoverButton *browse = [[HoverButton alloc] initWithFrame:NSMakeRect(390, y - 4, 64, 26)];
        browse.title = @"浏览...";
        browse.bezelStyle = NSBezelStyleRounded;
        browse.target = handler; browse.action = @selector(browseClicked:);
        y -= 42;

        NSTextField *catLabel = [NSTextField labelWithString:
            [NSString stringWithFormat:@"分类: %@    （取消将不开始此下载）", category ?: @"normal"]];
        catLabel.frame = NSMakeRect(16, y + 6, 270, 17);
        catLabel.font = small; catLabel.textColor = gray;

        HoverButton *cancel = [[HoverButton alloc] initWithFrame:NSMakeRect(296, y, 80, 28)];
        cancel.title = @"取消";
        cancel.bezelStyle = NSBezelStyleRounded;
        cancel.keyEquivalent = @"\e";
        cancel.target = handler; cancel.action = @selector(cancelClicked:);

        HoverButton *ok = [[HoverButton alloc] initWithFrame:NSMakeRect(382, y, 72, 28)];
        ok.title = @"开始下载";
        ok.bezelStyle = NSBezelStyleRounded;
        ok.baseColor = BlueColor();
        ok.bezelColor = ok.baseColor;
        ok.keyEquivalent = @"\r";
        ok.target = handler; ok.action = @selector(okClicked:);

        NSView *content = win.contentView;
        for (NSView *v in @[urlLabel, urlField, nameLabel, nameField,
                            dirLabel, dirField, browse, catLabel, cancel, ok])
            [content addSubview:v];

        // App 非激活时收不到鼠标移动事件 → 全局 monitor 兜底驱动 hover
        __block NSArray<HoverButton *> *hovers = @[browse, cancel, ok];
        id hoverMon = [NSEvent addGlobalMonitorForEventsMatchingMask:
                       NSEventTypeMouseMoved | NSEventTypeLeftMouseDragged
                                                  handler:^(NSEvent *e) {
            NSPoint m = [NSEvent mouseLocation];
            for (HoverButton *b in hovers) {
                if (!b.window) continue;
                NSRect r = [b.window convertRectToScreen:
                            [b convertRect:b.bounds toView:nil]];
                BOOL inside = NSMouseInRect(m, r, NO);
                if (b.hovered != inside) b.hovered = inside;
            }
        }];

        [win setFrameOrigin:
            NSMakePoint(sf.origin.x + (sf.size.width - win.frame.size.width) / 2,
                        sf.origin.y + (sf.size.height - win.frame.size.height) / 2)];
        // 激活 App：NDM 平时在托盘非激活，非激活状态系统不派发鼠标事件
        // macOS 14+ 协作式激活常被拒 → 两条腿：先常规激活，再发 Apple Event 自激活
        if (@available(macOS 14.0, *))
            [NSApp activate];
        else
            [NSApp activateIgnoringOtherApps:YES];
        {
            NSString *src = [NSString stringWithFormat:
                @"tell application id \"%@\" to activate",
                NSBundle.mainBundle.bundleIdentifier];
            NSAppleScript *as =
                [[NSAppleScript alloc] initWithSource:src];
            [as executeAndReturnError:nil];
        }
        // 兜底：若仍未激活，延迟重试（协作式激活偶尔首轮被拒）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (![NSApp isActive]) {
                if (@available(macOS 14.0, *)) [NSApp activate];
                else [NSApp activateIgnoringOtherApps:YES];
                NSString *src = [NSString stringWithFormat:
                    @"tell application id \"%@\" to activate",
                    NSBundle.mainBundle.bundleIdentifier];
                NSAppleScript *as2 =
                    [[NSAppleScript alloc] initWithSource:src];
                [as2 executeAndReturnError:nil];
            }
        });
        [win makeKeyAndOrderFront:nil];
        NSLog(@"[ndm_confirm] 弹窗: isActive=%d keyWindow=%d", [NSApp isActive],
              win.isKeyWindow);
        NSInteger res = [NSApp runModalForWindow:win];
        if (hoverMon) [NSEvent removeMonitor:hoverMon];

        if (res == NSModalResponseOK) {
            NSString *dir = dirField.stringValue;
            while (dir.length > 1 && [dir hasSuffix:@"/"])
                dir = [dir substringToIndex:dir.length - 1];
            [NSUserDefaults.standardUserDefaults setObject:dir forKey:kLastDirKey];
            result = @{@"go": @YES, @"dir": dir, @"name": nameField.stringValue};
        } else {
            result = @{@"go": @NO};
        }
        [win orderOut:nil];
    };

    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
    return result;
}

#pragma mark - Hook 实现

static Class gAppDelClass, gDlWinClass, gDlWinMKVClass;

// 默认目录：上次使用 > NDM 分类目录 > ~/Downloads
static NSString *DefaultDirFor(id appDelegate, NSString *category) {
    NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:kLastDirKey];
    if (last.length && [[NSFileManager defaultManager] fileExistsAtPath:last]) return last;
    @try {
        if (category.length &&
            [appDelegate respondsToSelector:@selector(getFolderPath:)]) {
            NSString *p = [appDelegate performSelector:@selector(getFolderPath:)
                                            withObject:category];
            if ([p isKindOfClass:[NSString class]] && p.length) return p;
        }
    } @catch (NSException *e) { NSLog(@"[ndm_confirm] getFolderPath failed: %@", e); }
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
}

static void HookedHandleRequest(id self_, SEL _cmd, id payload) {
    IMP orig = OrigIMP(gAppDelClass, @selector(handleBrowserDownloadRequest:));
    NSString *url = nil, *fname = nil, *category = nil;
    if (!ParsePayload(payload, &url, &fname, &category)) {   // 解析失败 → 放行
        if (orig) ((void(*)(id, SEL, id))orig)(self_, _cmd, payload);
        return;
    }
    // 调试开关: defaults write com.NeatDownloadManager ndm_confirm_passthrough -bool YES
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"ndm_confirm_passthrough"]) {
        NSLog(@"[ndm_confirm] passthrough 直通模式");
        if (orig) ((void(*)(id, SEL, id))orig)(self_, _cmd, payload);
        return;
    }
    NSString *origFname = fname;                 // payload 里的原始文件名（可能为 nil）
    if (!fname.length) fname = DeriveNameFromURL(url);   // 兜底：从 URL 提取
    NSLog(@"[ndm_confirm] payload=[%@]",
          [payload isKindOfClass:[NSString class]]
              ? [(NSString *)payload substringToIndex:MIN((NSUInteger)400, [(NSString *)payload length])]
              : payload);
    NSLog(@"[ndm_confirm] url=%@ origFname=%@ derived=%@", url, origFname, fname);

    // 记录弹窗前状态：取消时还原，避免弹出主界面
    NSWindow *mainWin = nil;
    @try {
        id mw = [self_ valueForKey:@"mainWindow"];
        if ([mw isKindOfClass:[NSWindow class]]) mainWin = mw;
    } @catch (NSException *e) {}
    BOOL mainWasVisible = mainWin.isVisible;
    BOOL appWasHidden = [NSApp isHidden];

    NSString *defaultDir = DefaultDirFor(self_, category);
    NSDictionary *r = RunConfirmDialog(url, fname, category, defaultDir);
    if (![r[@"go"] boolValue]) {
        NSLog(@"[ndm_confirm] 用户取消下载: %@", url);
        if (mainWin && !mainWasVisible) [mainWin orderOut:nil];
        if (appWasHidden || !mainWasVisible) [NSApp hide:self_];   // 回到托盘
        return;                      // 取消 → 不调用原方法，下载不开始
    }

    // 用户改了文件名才改写 payload（保持与原生流程一致，避免干扰引擎探测）
    NSString *newName = r[@"name"];
    BOOL needReplace = NO;
    if (newName.length) {
        if (origFname.length) needReplace = ![newName isEqualToString:origFname];
        else if (fname.length) needReplace = ![newName isEqualToString:fname];
    }
    if (needReplace) payload = ReplaceNameInPayload(payload, newName);

    gOverrideDir = r[@"dir"];
    @try {
        if (orig) ((void(*)(id, SEL, id))orig)(self_, _cmd, payload);
    } @finally {
        gOverrideDir = nil;          // 兜底清除（正常由 init hook 消费）
    }
}

// request 是 C++ 结构体指针，必须用 void*，绝不能声明为 id（ARC 会 retain 导致崩溃）
static NSString *ApplyOverride(NSString *tempPath, NSString **finalPathPtr) {
    if (!gOverrideDir) return tempPath;
    NSString *finalPath = *finalPathPtr;
    if (![finalPath isKindOfClass:[NSString class]] || !finalPath.length) return tempPath;
    NSString *dir = gOverrideDir;
    gOverrideDir = nil;
    NSLog(@"[ndm_confirm] 原始参数 temp=%@ final=%@", tempPath, finalPath);
    NSString *newTemp = tempPath, *newFinal = finalPath;
    // final/temp 可能是目录（无扩展名）或完整文件路径（有扩展名）
    if ([[finalPath pathExtension] length] > 0)
        newFinal = [dir stringByAppendingPathComponent:[finalPath lastPathComponent]];
    else
        newFinal = [dir copy];
    if ([tempPath isKindOfClass:[NSString class]] && tempPath.length &&
        [[tempPath pathExtension] length] == 0)
        newTemp = [dir copy];                       // temp 是目录 → 直接替换
    NSLog(@"[ndm_confirm] 路径覆盖: final=%@ temp=%@", newFinal, newTemp);
    *finalPathPtr = newFinal;
    return newTemp;
}

static id HookedDLInit(id self_, SEL _cmd, id values, id menu, void *request,
                       NSString *tempPath, NSString *finalPath, NSInteger rowIdx, BOOL resume) {
    tempPath = ApplyOverride(tempPath, &finalPath);
    IMP orig = OrigIMP(gDlWinClass, @selector(initWithValues:appStatusMenu:request:tempOutputPath:finalOutputPath:rowIdx:doResume:));
    return ((id(*)(id, SEL, id, id, void *, NSString *, NSString *, NSInteger, BOOL))orig)(
        self_, _cmd, values, menu, request, tempPath, finalPath, rowIdx, resume);
}

static id HookedDLInitMKV(id self_, SEL _cmd, id values, id menu, void *request,
                          NSString *tempPath, NSString *finalPath, NSInteger rowIdx, BOOL resume) {
    tempPath = ApplyOverride(tempPath, &finalPath);
    IMP orig = OrigIMP(gDlWinMKVClass, @selector(initMKVWithValues:appStatusMenu:request:tempOutputPath:finalOutputPath:rowIdx:doResume:));
    return ((id(*)(id, SEL, id, id, void *, NSString *, NSString *, NSInteger, BOOL))orig)(
        self_, _cmd, values, menu, request, tempPath, finalPath, rowIdx, resume);
}

#pragma mark - 设置/浏览器/关于 弹窗居中到主界面

// 只处理这三个弹窗: 窗口本身是普通 NSWindow, NeatXxxWindow 是其委托类
static BOOL IsManagedPopup(NSWindow *w) {
    id del = w.delegate;
    if (!del) return NO;
    NSString *cls = NSStringFromClass(object_getClass(del));
    return [cls isEqualToString:@"NeatSettingWindow"]
        || [cls isEqualToString:@"NeatBrowsersWindow"]
        || [cls isEqualToString:@"NeatAboutWindow"];
}

static NSPoint CenterInRect(NSRect inner, NSRect outer) {
    return NSMakePoint(outer.origin.x + (outer.size.width - inner.size.width) / 2,
                       outer.origin.y + (outer.size.height - inner.size.height) / 2);
}

// 居中到主界面窗口；找不到则取最大的可见窗口；再不行就屏幕居中
static void CenterPopupOverMain(NSWindow *w) {
    NSRect f = w.frame;
    NSPoint o = NSZeroPoint;
    BOOL done = NO;

    NSWindow *main = [NSApp mainWindow];
    if (!done && main && main != w && main.frame.size.width > 0) {
        o = CenterInRect(f, main.frame);
        done = YES;
    }
    if (!done) {   // mainWindow 为空（托盘态）→ 用最大的可见窗口当主界面
        NSWindow *best = nil;
        for (NSWindow *cand in [NSApp windows]) {
            if (cand == w || !cand.isVisible || IsManagedPopup(cand)) continue;
            CGFloat a = cand.frame.size.width * cand.frame.size.height;
            CGFloat ba = best ? best.frame.size.width * best.frame.size.height : 0;
            if (a > ba) best = cand;
        }
        if (best) { o = CenterInRect(f, best.frame); done = YES; }
    }
    if (!done) {
        NSRect sf = NSScreen.mainScreen.visibleFrame;
        o = CenterInRect(f, sf);
    }
    [w setFrameOrigin:o];
    NSLog(@"[ndm_confirm] 弹窗居中: %@ -> (%.0f, %.0f)", NSStringFromClass(w.class), o.x, o.y);
}

static void HookedMakeKeyAndOrderFront(id self_, SEL _cmd, id sender) {
    if (IsManagedPopup(self_)) CenterPopupOverMain(self_);
    IMP orig = OrigIMP(objc_getClass("NSWindow"), @selector(makeKeyAndOrderFront:));
    if (orig) ((void(*)(id, SEL, id))orig)(self_, _cmd, sender);
}

static void HookedOrderFront(id self_, SEL _cmd, id sender) {
    if (IsManagedPopup(self_)) CenterPopupOverMain(self_);
    IMP orig = OrigIMP(objc_getClass("NSWindow"), @selector(orderFront:));
    if (orig) ((void(*)(id, SEL, id))orig)(self_, _cmd, sender);
}

// showWindow: 按控制器类名过滤（NeatSettingWindow 等是 NSWindowController 子类）
static void HookedShowWindow(id self_, SEL _cmd, id sender) {
    NSString *cls = NSStringFromClass(object_getClass(self_));
    IMP orig = OrigIMP(objc_getClass("NSWindowController"), @selector(showWindow:));
    if (orig) ((void(*)(id, SEL, id))orig)(self_, _cmd, sender);
    if ([cls isEqualToString:@"NeatSettingWindow"]
        || [cls isEqualToString:@"NeatBrowsersWindow"]
        || [cls isEqualToString:@"NeatAboutWindow"]) {
        NSWindow *w = [(NSWindowController *)self_ window];
        if (w) CenterPopupOverMain(w);   // 显示之后再摆位置，防止被 nib 坐标覆盖
    }
}

// 注意: orderWindow:relativeTo: 的第二个参数是窗口编号(NSInteger)而非对象指针,
// 声明成 id 会被 ARC retain 整数值 → SIGSEGV
static void HookedOrderWindow(id self_, SEL _cmd, NSInteger place, NSInteger otherWinNum) {
    if (IsManagedPopup(self_)) CenterPopupOverMain(self_);
    IMP orig = OrigIMP(objc_getClass("NSWindow"), @selector(orderWindow:relativeTo:));
    if (orig) ((void(*)(id, SEL, NSInteger, NSInteger))orig)(self_, _cmd, place, otherWinNum);
}

__attribute__((constructor))
static void ndm_confirm_init(void) {
    @autoreleasepool {
        NSLog(@"[ndm_confirm] loaded");

        gAppDelClass   = objc_getClass("AppDelegate");
        gDlWinClass    = objc_getClass("NeatDownloadWindow");
        gDlWinMKVClass = objc_getClass("NeatDownloadWindowMKV");
        if (!gAppDelClass) { NSLog(@"[ndm_confirm] AppDelegate not found"); return; }

        Exchange(gAppDelClass, @selector(handleBrowserDownloadRequest:),
                 (IMP)HookedHandleRequest);

        if (gDlWinClass)
            Exchange(gDlWinClass,
                     @selector(initWithValues:appStatusMenu:request:tempOutputPath:finalOutputPath:rowIdx:doResume:),
                     (IMP)HookedDLInit);
        if (gDlWinMKVClass)
            Exchange(gDlWinMKVClass,
                     @selector(initMKVWithValues:appStatusMenu:request:tempOutputPath:finalOutputPath:rowIdx:doResume:),
                     (IMP)HookedDLInitMKV);

        // 设置/浏览器/关于 弹窗居中到主界面
        Class winCls = objc_getClass("NSWindow");
        Exchange(winCls, @selector(makeKeyAndOrderFront:), (IMP)HookedMakeKeyAndOrderFront);
        Exchange(winCls, @selector(orderFront:), (IMP)HookedOrderFront);
        Exchange(winCls, @selector(orderWindow:relativeTo:), (IMP)HookedOrderWindow);
        Exchange(objc_getClass("NSWindowController"), @selector(showWindow:), (IMP)HookedShowWindow);

        NSLog(@"[ndm_confirm] hooks installed");

        // 调试观察器: defaults write com.NeatDownloadManager ndm_confirm_watch -bool YES
        if ([NSUserDefaults.standardUserDefaults boolForKey:@"ndm_confirm_watch"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *t) {
                    static Ivar ivConn = NULL, ivName = NULL;
                    if (!ivConn) {
                        ivConn = class_getInstanceVariable(objc_getClass("NeatDownloadWindow"), "lastConnectionsCount");
                        ivName = class_getInstanceVariable(objc_getClass("NeatDownloadWindow"), "fileName");
                    }
                    for (NSWindow *w in NSApp.windows) {
                        if (![w isKindOfClass:objc_getClass("NeatDownloadWindow")]) continue;
                        NSString *name = ivName ? object_getIvar(w, ivName) : nil;
                        long long conn = ivConn ? *(long long *)((char *)(__bridge void *)w + ivar_getOffset(ivConn)) : -1;
                        NSLog(@"[ndm_confirm][watch] %@ connections=%lld", name, conn);
                    }
                }];
            });
            NSLog(@"[ndm_confirm] watcher ON");
        }
    }
}
