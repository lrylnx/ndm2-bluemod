# 下载确认窗口（ndm_confirm.dylib）

IDM 风格的下载前确认窗：浏览器发起下载时弹出，显示网址/文件名/分类，可浏览选择保存目录，点「开始下载」才真正开始，「取消」则不下载。

## 原理

纯 ObjC dylib + ObjC Runtime swizzle，不修改主程序代码段（仅一条 LC_LOAD_DYLIB 注入）。

| Hook 点 | 作用 |
|---|---|
| `-[AppDelegate handleBrowserDownloadRequest:]` | 浏览器扩展请求入口（websocket 行协议）。弹确认窗；取消→直接 return 不调原方法；开始→记下所选目录后放行。文件名可编辑（重写 payload 的 `3:` 行） |
| `-[NeatDownloadWindow initWithValues:appStatusMenu:request:tempOutputPath:finalOutputPath:rowIdx:doResume:]` | temp/final 输出路径参数替换为用户所选目录 |
| `-[NeatDownloadWindowMKV initMKVWithValues:...]` | 同上（视频嗅探流程） |

关键发现（逆向结论）：

- 扩展 → 主程序走 websocket `ws://127.0.0.1:10007/download`（子协议 `neatextension.v1`），消息为行协议：`1:方法\r\n2:URL\r\n3:文件名\r\n6:分类\r\nReferer: ...\r\nCookie: ...`（见扩展 `bg.js`，无 JSON）
- `initWithValues:` 的 **`request:` 参数是 C++ 结构体裸指针**——dylib 里必须声明为 `void*`，声明成 `id` 会被 ARC retain → SIGSEGV（第一次实测即栽在这）
- `tempOutputPath/finalOutputPath` 参数来自 AppDelegate 的目录 ivar（`setAppDirectories` 设置），是目录而非完整文件路径；以有无 `pathExtension` 区分目录/文件路径再决定替换策略
- `handleBrowserDownloadRequest:` 在主线程被调（NSThreadPerformPerform），弹窗无需跨线程 dispatch（仍保留 isMainThread 判断以防万一）
- 默认目录策略：上次使用（NSUserDefaults `ndm_confirm_last_dir`）> NDM 分类目录（`getFolderPath:`）> `~/Downloads`
- 窗口未弹时（如 LSP 初始化前就崩溃），hook 不生效即回归原版行为；payload 解析失败也直接放行

## 安装（已安装过，重装时）

```bash
S=scripts; A=/Applications/NeatDownloadManager2.app
# 备份
cp $A/Contents/MacOS/NeatDownloadManager $A/Contents/MacOS/NeatDownloadManager.bak.confirm
# 编译
clang -arch arm64 -arch x86_64 -dynamiclib -fobjc-arc \
  -framework Foundation -framework AppKit \
  -install_name @executable_path/../Frameworks/ndm_confirm.dylib \
  -o $S/ndm_confirm.dylib $S/ndm_confirm.m
# 部署 + 注入
cp $S/ndm_confirm.dylib $A/Contents/Frameworks/
python3 $S/patch_inject_dylib.py $A/Contents/MacOS/NeatDownloadManager \
  "@executable_path/../Frameworks/ndm_confirm.dylib"
# 签名（appex 先签）
codesign --force -s - "$A/Contents/PlugIns/NeatDownloadManager Extension.appex"
codesign --force --deep -s - $A
codesign --verify --deep $A
```

## 卸载

```bash
cp /Applications/NeatDownloadManager2.app/Contents/MacOS/NeatDownloadManager.bak.confirm \
   /Applications/NeatDownloadManager2.app/Contents/MacOS/NeatDownloadManager
# 再重签一次（备份是未注入版，签名已含确认dylib引用）
codesign --force --deep -s - /Applications/NeatDownloadManager2.app
```

## 调试

```bash
# 终端启动看 NSLog
/Applications/NeatDownloadManager2.app/Contents/MacOS/NeatDownloadManager 2>&1 | grep ndm_confirm
```

日志标记：`[ndm_confirm] loaded / hooks installed / 路径覆盖 / 用户取消下载`。

## 按钮交互与 App 激活（2026-09-05 补充）
- macOS 14+ 协作式激活：用户刚在其他 App 操作时 `[NSApp activate]` 会被系统拒绝（红绿灯保持灰色），非激活状态收不到任何鼠标事件
- 双通道激活：先 `[NSApp activate]`，再 AppleScript `tell application id "com.NeatDownloadManager" to activate` 自激活（不受协作式限制），0.25s 后检查 isActive 失败则重试
- HoverButton：自定义按钮类，baseColor 保存原始底色，hover 加深 18%、普通按钮淡蓝底、按压加深 35%
- 兜底：弹窗期间挂 `NSEvent addGlobalMonitorForEventsMatchingMask:(MouseMoved|LeftMouseDragged)` 全局监视器，鼠标命中检测驱动 hover（激活成功后此监视器实际不触发，留作保险）
- 已知系统行为：弹窗后第一次点击仅激活 App，不触发按钮
