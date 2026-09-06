# 踩坑笔记

全部来自对 NDM 2 (v1.4 universal) 的实际逆向改造过程，适用于同类 macOS App。

## 1. PNG 资源替换必须保留原 DPI（状态栏图标消失真因）

- NSImage 点尺寸 = 像素 × 72 / DPI
- 原版 neaticon.png 是 **411 DPI**（100px → 17.5pt）；用普通渲染流程出的 PNG 默认 72 DPI（100px → 100pt）
- 状态项视图用 `[statusItem length] × [NSStatusBar thickness]` 建视图、drawRect 按 `[image size]` 居中绘制 → 100pt 巨图直接溢出不可见
- **替换任何 PNG 前先 `sips -g dpiWidth` 记录原值，替换后 `sips -s dpiWidth -s dpiHeight` 恢复**

排查套路：
1. `+[NSImage imageNamed:]` 断点（lldb `-C "po (id)$x2" -G true`）确认资源名
2. 反汇编 drawRect 看尺寸来源
3. DPI 对比实锤

## 2. lldb 运行时地址 → 静态地址

backtrace 里的返回地址减去滑移（slide）才是静态 VA。滑移 = 运行时返回地址 − (静态 bl 下一条指令地址)，结果应为 4K 对齐，可用来反推验证。

## 3. ObjC 方法表解析（arm64）

entsize 高位 `0x80000000` 表示 relative method list：count 在 +4，name/types/imp 都是 int32 相对偏移（相对条目自身 VA）。name 字段是 selref 槽偏移，需再解一次指针。

## 4. 颜色修改（colorWithCalibratedRed 字面量池）

颜色不在 nib，而是代码里 `[NSColor colorWithCalibratedRed:green:blue:alpha:]` 的字面量（`__TEXT,__const` 里的 double）+ 寄存器装配。找法：

1. ivar 属性串（`V_activeBarColor`）→ setter 选择器名
2. 全数据段扫 8 字节指针找 selref 槽
3. 扫 `__text` 的 LDR-literal（arm64 掩码 `0x58000000`，注意是高 8 位，`0xFFC00000` 会误判）找调用点
4. 反汇编看 d0-d3 装配（`ldr dN, #池` / `movi vN.2d,#0` / `fmov dN,#1.0`）

改色三招：
- 改池值为新分量
- 改指令寄存器把分量换通道
- `movi vN.2d,#0` → `ldr dN, #现成池` 借常量当另一通道

**池共享**：同一值可能被进度条和文字色共用，改池前全量扫引用；只想改一处用指令级方案。

## 5. 扩展名图标通用 hook

- 行图标函数只硬编码 3 对扩展名比较，其余走 `NSWorkspace iconForFile:`
- 函数旁常有死代码 helper（全 `__text` 扫 bl/b 确认零调用者后）可改写为通用 stub：`lowercaseString → [NSImage imageNamed:] → nil 回退`
- stub 只可 clobber x0-x18 和已死寄存器；回退路径依赖的寄存器（x19/x20）必须保留
- 进入收尾出口前 x0 须是 autorelease 池返回值（imageNamed 满足）
- 之后加新格式只需往 Resources 丢 `<ext>.png`，零二进制改动

## 6. cstring 原地劫持

等长 cstring 可原地改写（如 `app\0app.png\0` → `zip\0zip.png\0`）。改前用 `__cfstring` 全表扫确认只有一处 CFString 引用。arm64+x64 双切片同步。

## 7. codesign 顺序坑

- 含 PlugIns/*.appex 时：先单独签 appex，再 `codesign --force --deep -s -` 主 App
- 中断签名残留 `*.cstemp.cstemp*` 会污染 seal，先 `find <app> -name "*.cstemp*" -delete`
- 验证：`codesign --verify --deep <app>`

## 12. "死代码"判断必须覆盖 ObjC 方法表（视频嗅探下载卡死真因）

- 现象：浏览器嗅探视频 → 点下载 → 主 App 转风火轮数分钟；普通文件下载正常；原版无此问题
- 排查链：`sample` 抓到主线程 100% 忙在 NSTableView 布局循环 → 行图标 delegate (`+[类 getIconForExtension:category:]`) → `imageNamed:`(扩展名) 未命中 → 掉进另一个方法的 fallback → 无限重排
- 根因：`patch_ext_icon_hook.py` 把 0x10002fb00 判定为"死代码 helper"并改写为 stub。实际上它是 **`+getIconForExtension:category:` 的方法实现（IMP）**——下载列表 delegate 经 objc_msgSend 间接调用它。扫描 bl/b 直接调用必然漏掉方法表引用
- stub 在 `imageNamed:` 未命中时 cbz 跳进**另一个方法**的 fallback，该 fallback 收尾按自己方法的约定 release x19/x20——此时这两个寄存器装的是调用方（delegate）的活对象 → 过度释放 → 表格无限重建行
- 触发面：任何"Resources 里没有同名 PNG"的扩展名行（B 站 DASH 分段 `.m4s` 首当其冲；`.ts`/`.mp4` 因有 PNG 而幸免）
- 修复（2026-09-05）：还原 0x10002fb00 起的 10 条原始指令 + 还原 0x10002fd58 的 cbz 原始目标即可。**根本不需要 hook**——原版 `getIconForExtension:` 本来就执行 `[NSImage imageNamed: 小写扩展名]`，往 Resources 放 `<ext>.png` 天然生效；未命中返回 nil 走原版空图标路径，安全
- **教训：改写任何函数前，先用 class-dump / 方法表解析确认它不是某个 ObjC 方法的 IMP；"全 __text 扫描零 bl/b"不等于死代码**

## 13. 徽章不显示的完整真相（2026-09-05 凌晨）
- 图标体系：`+getIconForExtension:category:`(IMP 0x2fc30) = 特例映射 + NSWorkspace iconForFile 原生系统图标；`+getCustomIcon:category:`(IMP 0x2fb00, NeatNsUtils) = `[NSImage imageNamed: 小写参数]`。蓝色徽章只有走 getCustomIcon 才显示。
- 修复组合：① delegate 0x43b3c `mov x3, x24`（15:30 遗留，等价传 ext）；② 0x2fb10 `mov x0, x2`（getCustomIcon 用参数1=ext）；③ 0x2fc30 else 块改写为 `[NeatNsUtils getCustomIcon:ext category:ext]` + 直跳尾部（nil 安全），原 iconForFile 段 NOP。
- 教训：两个相邻函数名相似、行为文档全无，必须用 class_getMethodImplementation(object_getClass(cls), sel) 定位真实 IMP，别信反汇编线性扫描；多会话并行操作同一 App 时，改前先 stat mtime + dump 现场。

## 14. 工具栏/浏览器/状态栏图标的资源定位（2026-09-07）
- 工具栏按钮图标**不是**代码硬编码，而是 `Base.lproj/NeatMainWindow.nib` 里 `NSToolbarItem` 的 `NSToolbarItemImage → NSImage → IBDesignImageConfiguration → NSResourceName`。用 `plutil -p keyedobjects-110000.nib | grep NSResourceName` 顺藤摸到资源名。
- 实测映射：新建=`Newurl`、继续=`Resume`、暂停=`Pause`、删除=`delete`、设置=`options`、关于=`about`、退出=`quit`、**浏览器=`Google Chrome`**（工具栏"浏览器"按钮与浏览器窗口 Chrome 行共用同一张图，改它两处同时生效）。
- 浏览器窗口内各浏览器图标走 `NeatBrowsersWindow.nib` 的 `imgChrome/imgFox/imgEdge` → 直接对应 Resources 下 `Google Chrome.png / Firefox.png / Microsoft Edge.png / Safari.png / Opera.png`。
- 状态栏（菜单栏）图标 = `neaticon.png`（二进制里 `statusItemWithLength:` 之后紧跟 `neaticon` 字面量）。它 DPI 极高（200px@758），NSImage 点尺寸 = 200×72/758 ≈ 19pt，正好是菜单栏尺寸。**替换时必须保留 758 DPI**，否则菜单栏图标会撑爆或消失。
- 渲染部署统一走 `icons/build_icons.sh`：读目标 PNG 的 pixelWidth + dpiWidth，渲染同尺寸再 `sips -s dpiWidth/-s dpiHeight` 写回元数据，零猜测。
