// ndm_confirm.m — NDM2 浏览器下载确认窗口（IDM 风格）
// Hook:
//   1) -[AppDelegate handleBrowserDownloadRequest:]  弹出确认窗；取消则不启动下载、不弹主界面
//   2) -[NeatDownloadWindow initWithValues:appStatusMenu:request:tempOutputPath:finalOutputPath:rowIdx:doResume:]
//      -[NeatDownloadWindowMKV initMKVWithValues:...]
//      用用户所选目录覆盖 temp/final 输出路径，并把改名写进 C++ 请求结构体
//      （NeatDownloadRequest::Url.FileName，见 scripts/ndm_request_name.mm）
//
// 改名机制说明（重要）：
//   协议 payload 的 "3:" 字段**不是文件名**，而是第二路媒体流 URL
//   （音视频分离时引擎用它合成 MKV）。若把文件名塞进 "3:"，会被引擎误判为
//   视频合成下载 → 强制改名 .mkv / 分类变 Video / 下载失败。
//   正确做法：保持 payload 原样，直接在 C++ 请求结构体里改 Url.FileName。
//
// 编译（两个源文件，注意用 clang++ 以链接 libc++ —— .mm 里调用了 std::string）:
//   clang++ -arch arm64 -arch x86_64 -dynamiclib -fobjc-arc \
//     -framework Foundation -framework AppKit \
//     -install_name @executable_path/../Frameworks/ndm_confirm.dylib \
//     -o ndm_confirm.dylib ndm_confirm.m ndm_request_name.mm

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// C++ 侧（ndm_request_name.mm）：改 NeatDownloadRequest::Url.FileName
extern int ndm_set_request_file_name(void *request, const char *utf8_name);

static NSString *gOverrideDir = nil;   // 待消费的覆盖目录
static NSString *gOverrideName = nil;  // 待消费的覆盖文件名（nil = 不改名）
static NSString *kLastDirKey = @"ndm_confirm_last_dir";

// 文件日志：App 是托盘态常驻，NSLog 在沙箱/无终端时看不到，写文件便于排查
// 开关: defaults write com.NeatDownloadManager ndm_confirm_log -bool YES
static void DbgLog(NSString *fmt, ...) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"ndm_confirm_log"]) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%.3f %@\n",
                      [NSDate date].timeIntervalSince1970, msg];
    NSString *path = @"/tmp/ndm_confirm.log";
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
    @catch (NSException *e) {}
    [fh closeFile];
}

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

// 用户改了文件名时，把它写进 C++ 请求结构体的 Url.FileName。
// 必须在调用原 initWithValues: 之前改：原方法会拿它算出窗口 fileName / 落盘名 / 数据库 filename。
// 失败（结构校验不通过）时保持原文件名，绝不让下载失败。
static void PatchRequestName(void *request, NSString *name) {
    if (!request || !name.length) return;
    const char *utf8 = name.UTF8String;
    if (!utf8) return;
    int rc = ndm_set_request_file_name(request, utf8);
    if (rc == 0) DbgLog(@"[rename] 请求文件名 -> %@", name);
    else         DbgLog(@"[rename] 改写请求文件名失败 rc=%d，保持原文件名", rc);
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
    NSString *origFname = fname;                 // payload 里的原始文件名（可能为 nil）
    if (!fname.length) fname = DeriveNameFromURL(url);   // 兜底：从 URL 提取
    DbgLog(@"[confirm] url=%@ origFname=%@ derived=%@", url, origFname, fname);

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

    // 用户改了文件名才记录改名意图（**不改 payload**：payload 的 3: 是第二路媒体流 URL，
    // 不是文件名，改写它会被引擎当成音视频合成下载 → 下载必然失败）
    NSString *newName = r[@"name"];
    BOOL needRename = NO;
    if (newName.length) {
        if (origFname.length) needRename = ![newName isEqualToString:origFname];
        else if (fname.length) needRename = ![newName isEqualToString:fname];
    }
    gOverrideName = needRename ? newName : nil;
    DbgLog(@"[confirm] origFname=[%@] fname=[%@] 用户输入=[%@] needRename=%d",
           origFname, fname, newName, needRename);

    gOverrideDir = r[@"dir"];
    @try {
        if (orig) ((void(*)(id, SEL, id))orig)(self_, _cmd, payload);
    } @finally {
        gOverrideDir = nil;          // 兜底清除（正常由 init hook 消费）
        gOverrideName = nil;
    }
}

// request 是 C++ 结构体指针，必须用 void*，绝不能声明为 id（ARC 会 retain 导致崩溃）
static NSString *ApplyOverride(NSString *tempPath, NSString **finalPathPtr) {
    NSString *finalPath = *finalPathPtr;
    DbgLog(@"[init] 原始参数 temp=[%@] final=[%@] dir=[%@] name=[%@]",
           tempPath, finalPath, gOverrideDir, gOverrideName);
    if (!gOverrideDir) return tempPath;
    if (![finalPath isKindOfClass:[NSString class]] || !finalPath.length) return tempPath;
    NSString *dir = gOverrideDir;
    gOverrideDir = nil;
    NSString *name = gOverrideName;
    gOverrideName = nil;
    NSString *newTemp = tempPath, *newFinal = finalPath;
    // final/temp 可能是目录（无扩展名）或完整文件路径（有扩展名）
    if ([[finalPath pathExtension] length] > 0)
        newFinal = [dir stringByAppendingPathComponent:[finalPath lastPathComponent]];
    else
        newFinal = [dir copy];
    if ([tempPath isKindOfClass:[NSString class]] && tempPath.length &&
        [[tempPath pathExtension] length] == 0)
        newTemp = [dir copy];                       // temp 是目录 → 直接替换
    DbgLog(@"[init] 路径覆盖: final=[%@] temp=[%@] (期望文件名=[%@])", newFinal, newTemp, name);
    *finalPathPtr = newFinal;
    return newTemp;
}

// libc++ std::string 内存布局说明（本 App 实测，ndm_request_name.mm 里做同样校验）：
//   短串 = data[0..22] + '\0' + 长度字节在 +23（最高位 0）
//   长串 = 堆指针(0) / 长度(8) / 容量|最高位(16)
// 改名已在 C++ 侧（PatchRequestName）完成，窗口的 fileName / 落盘名 / 数据库 filename
// 都由原 initWithValues: 从被改写后的结构体派生，故此处无需再动 ObjC ivar。
static id HookedDLInit(id self_, SEL _cmd, id values, id menu, void *request,
                       NSString *tempPath, NSString *finalPath, NSInteger rowIdx, BOOL resume) {
    NSString *wantName = gOverrideName;      // ApplyOverride 会消费，先留存
    PatchRequestName(request, wantName);
    tempPath = ApplyOverride(tempPath, &finalPath);
    IMP orig = OrigIMP(gDlWinClass, @selector(initWithValues:appStatusMenu:request:tempOutputPath:finalOutputPath:rowIdx:doResume:));
    id win = ((id(*)(id, SEL, id, id, void *, NSString *, NSString *, NSInteger, BOOL))orig)(
        self_, _cmd, values, menu, request, tempPath, finalPath, rowIdx, resume);
    return win;
}

static id HookedDLInitMKV(id self_, SEL _cmd, id values, id menu, void *request,
                          NSString *tempPath, NSString *finalPath, NSInteger rowIdx, BOOL resume) {
    NSString *wantName = gOverrideName;
    PatchRequestName(request, wantName);
    tempPath = ApplyOverride(tempPath, &finalPath);
    IMP orig = OrigIMP(gDlWinMKVClass, @selector(initMKVWithValues:appStatusMenu:request:tempOutputPath:finalOutputPath:rowIdx:doResume:));
    id win = ((id(*)(id, SEL, id, id, void *, NSString *, NSString *, NSInteger, BOOL))orig)(
        self_, _cmd, values, menu, request, tempPath, finalPath, rowIdx, resume);
    return win;
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
    }
}
