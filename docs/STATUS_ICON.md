# 状态栏图标单色自适应（v2.2）

> 目标：菜单栏那个下载图标从「固定蓝色」变成和系统图标一样 —— 深色菜单栏显示白色、浅色菜单栏显示黑色，跟随系统自动切换。

## 一、问题与根因

原版 NDM 的状态栏图标是 `Resources/neaticon.png`：**浅蓝→深蓝渐变圆角块 + 白色下载箭头**。
它是彩色位图，所以不管系统是深色还是浅色菜单栏，画出来永远是那块蓝色。

macOS 的规则很简单：

- `NSImage.isTemplate == YES` 的图 → 系统只取其 alpha 通道，按所在容器的明暗渲染成纯黑或纯白。
- 其余图 → 原样绘制，什么颜色就什么颜色。

所以关键就一句话：**`neaticon.png` 不是 template image。**

排查时的第一个硬证据，是在二进制里搜 `setTemplate`：

```bash
python3 -c "
import re
d=open('/Applications/NeatDownloadManager2.app/Contents/MacOS/NeatDownloadManager','rb').read()
for kw in [b'setTemplate', b'neaticon', b'NSStatusBar']:
    print(kw, len(re.findall(re.escape(kw), d)))
"
# setTemplate -> 0        ← 从来没设过模板图
# neaticon    -> 2        ← 两个架构切片各一处
# NSStatusBar -> 若干
```

`setTemplate` 出现 0 次 —— 坐实了「NDM 从来没把这张图设成模板图」。

## 二、两个必须绕开的坑

### 坑 1：不能直接改 `neaticon.png`

`neaticon` 这个资源名同时被 **`NeatQuitWindow.nib`**（退出确认框）和 **`NeatAboutWindow.nib`**（关于窗口）引用，
是对话框左侧那个彩色图标。把它改成单色，对话框会一起跟着变丑。

> 顺带一提：`docs/NOTES.md` 里记过一版「用等长改名把二进制里的 `neaticon` 改成 `Template`」的零代码思路
> （脚本保留在 `scripts/patch_rename_iconname.py`）。它确实能生效，但会连带影响上面两个对话框，
> **已废弃**，仅作为「macOS 资源命名约定」的参考留档。

结论：状态栏必须**另起一张图**，对话框的 `neaticon.png` 原样不动。

### 坑 2：自定义 view 里 template 属性不生效

用 lldb attach 到运行中的 NDM，问它要状态项结构：

```bash
lldb -b -p <pid> \
  -o 'expr -l objc++ -O -- (id)[[[NSStatusBar systemStatusBar] valueForKey:@"_statusItems"] objectAtIndex:0]' \
  -o 'detach' -o 'quit'
```

拿到的事实：

- 状态项类名是 `NSSceneStatusItem`
- 它有个 `button`（`NSStatusBarButton`，`NSButton` 子类）—— **标准控件**
- 但 NDM 实际走的是 **`item.view.image`** 路径，也就是**自定义 view**，不是标准按钮

这点很要命。实测（`/tmp/tmpl_test.swift` 那类小样程序验证过）：

| 承载方式 | template 图是否自动变色 |
|---|---|
| `NSButton` / `NSImageView` 标准控件 | ✅ 会 |
| 自定义 `NSView.drawRect:` 里直接绘制 | ❌ **不会**，一律按原色画 |

所以哪怕把图设成 template，走自定义 view 这条路也是**恒黑**（在深色菜单栏上等于看不见）。
这也是为什么不能只靠「改资源名」解决。

## 三、最终方案

两个部分配合：

### 1) 单色 glyph 资源：`neaticonTemplate.png`

`icons/toolbar/neaticonTemplate.svg` 渲染而成，纯黑描线、透明底、无背景色块：

- 一根竖线（下载柱）
- 一个 V 形箭头
- 一个开口托盘

> **命名是关键**：macOS 的 `+[NSImage imageNamed:]` 有个约定 —— **资源名以 `Template` 结尾时自动 `isTemplate = YES`**。
> 实测验证过：`Template` / `neaticonTemplate` / `StatusIconTemplate` 全部返回 `isTemplate=1`，`Plain` 返回 0。

渲染部署（保 758 DPI 元数据，DPI 不对图标会「消失」，见 `docs/NOTES.md`）：

```bash
icons/dist_out/render_hd icons/toolbar/neaticonTemplate.svg 200 \
  <app>/Contents/Resources/neaticonTemplate.png
```

### 2) `scripts/ndm_statusicon.m` → `ndm_statusicon.dylib`

因为自定义 view 不吃 template，代码里改用**绘制时动态取色的图**：

```objc
static NSImage *MonoIcon(void) {
    if (gMonoIcon) return gMonoIcon;
    NSImage *glyph = [NSImage imageNamed:@"neaticonTemplate"];
    gMonoIcon = [NSImage imageWithSize:glyph.size flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        [[NSColor labelColor] setFill];                       // ← 跟随外观
        NSRectFillUsingOperation(dstRect, NSCompositingOperationSourceOver);
        [glyph drawInRect:dstRect fromRect:NSZeroRect
                operation:NSCompositingOperationDestinationIn fraction:1.0];  // alpha 当蒙版
        return YES;
    }];
    return gMonoIcon;
}
```

`drawingHandler` 每次绘制都会重新求值，`labelColor` 会自动跟随菜单栏 vibrancy —— 深色取白、浅色取黑。

三处 hook 保证它在正确的时机被装上：

| Hook | 目的 |
|---|---|
| `NSStatusBar -statusItemWithLength:` | 状态项一建好就换图（并补 0.3s/1.0s/2.5s 三次延时兜底） |
| `NSImage +imageNamed:` | 记录原图对象，用于识别「NDM 自己要设的那张图」 |
| `NSStatusBarButton -setImage:` | 若 NDM 后续自己覆盖，拦下来换回单色图 |

再加一层 **KVO 保险**：监听 view 的 `effectiveAppearance`，外观一变就 `setNeedsDisplay:`，
确保切换深浅色时立刻重绘、不吃缓存。

## 四、怎么验证（不靠肉眼）

菜单栏区域截图，然后**按像素统计**该列的白/黑像素数：

```bash
screencapture -x -R "860,0,80,30" /tmp/shot.png
```

再逐列统计亮度 >200（白）与 <60（黑）的像素数量 —— 图标所在列会明显偏一边。
多次量下来：深色菜单栏下该图标区域以白像素为主，浅色下以黑像素为主，与旁边系统图标一致。

另外开日志看 dylib 自己的判断：

```bash
defaults write com.NeatDownloadManager ndm_statusicon_log -bool YES
# 日志在 /tmp/ndm_statusicon.log
```

## 五、走过的弯路（别重复）

中途曾怀疑「`drawingHandler` 重绘不生效」，把方案改成**在生成图那一刻就把颜色定死**
（`NSColor.whiteColor` / `NSColor.blackColor`），并在 KVO 里重新生成整张图。
后来实机验证表明：**原来那版 `labelColor` + 重绘本来就是对的**，那次「不生效」的结论来自
测试方法本身（切壁纸不一定立刻改变菜单栏外观 + 截图时机），属于误判。

教训：

- 改方向之前，先确保「原方案失败」这个结论本身是可靠的 —— 尤其是**用截图/像素做的判断**，
  截图区域、时机、外观实际是否切换都要单独确认。
- 能用 `labelColor` 就别硬编码黑白：前者会跟随菜单栏 vibrancy，渲染更"系统正确"。
