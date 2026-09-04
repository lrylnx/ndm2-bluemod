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
