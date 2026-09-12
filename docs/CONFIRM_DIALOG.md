# 下载确认窗口（ndm_confirm.dylib）

IDM 风格的下载前确认窗：浏览器发起下载时弹出，显示网址/文件名/分类，可浏览选择保存目录，点「开始下载」才真正开始，「取消」则不下载。

## 原理

纯 ObjC dylib + ObjC Runtime swizzle，不修改主程序代码段（仅一条 LC_LOAD_DYLIB 注入）。

| Hook 点 | 作用 |
|---|---|
| `-[AppDelegate handleBrowserDownloadRequest:]` | 浏览器扩展请求入口（websocket 行协议）。弹确认窗；取消→直接 return 不调原方法；开始→记下所选文件名后放行。**文件名可编辑**：改名在 C++ 请求结构体上完成（见下） |
| `-[NeatDownloadWindow initWithValues:appStatusMenu:request:tempOutputPath:finalOutputPath:rowIdx:doResume:]` | 改名落地点：调用原方法**之前**改写 `request`（C++ 结构体）里的 `Url.FileName`，窗口/落盘名/数据库 filename 都由它派生 |
| `-[NeatDownloadWindowMKV initMKVWithValues:...]` | 同上（视频嗅探流程） |

关键发现（逆向结论）：

- 扩展 → 主程序走 websocket `ws://127.0.0.1:10007/download`（子协议 `neatextension.v1`），消息为行协议：`1:方法\r\n2:URL\r\n3:第二路媒体流URL\r\n6:分类\r\nReferer: ...\r\nCookie: ...`（见扩展 `bg.js`，无 JSON）
- ⚠️ **协议 `3:` 字段不是文件名，而是「第二路媒体流 URL」**（音视频分离时引擎用它合成 MKV）。早期版本把用户文件名塞进 `3:`，会被引擎误判为视频合成下载 → 文件名强制变 `xxx.mkv`、分类变 Video、下载必定失败（`Server Closed Connection Suddenly`）。**正确做法是保持 payload 原样，在 C++ 结构体里改名。**
- 改名位置：`NeatDownloadRequest::Url.FileName`，结构体偏移 **296**。布局推导：
  `struct NeatDownloadRequest { NeatUrl Url; NeatUrl UrlAudio; int64 downloadID; ... }`，
  `struct NeatUrl { int Protocol; uint16 Port; bool Secure; std::string RawUrl, AbsoluteUrl, Scheme, QueryString, Path, AbsolutePath, AbsoluteHostPath, Host, OriginalHost, Fragment, User, Pass, FileName, mNonUnicodeRawUrl; }`
  → `8(头部) + 12×24 = 296`（每个 std::string 24 字节）。
  赋值走 libc++ 的 `std::string::operator=`（`scripts/ndm_request_name.mm`），写入前做结构自洽校验，校验失败就保持原文件名、绝不写坏请求；任意长度（含 >22 字节长串、中文）都安全。
- `initWithValues:` 的 **`request:` 参数是 C++ 结构体裸指针**——dylib 里必须声明为 `void*`，声明成 `id` 会被 ARC retain → SIGSEGV（第一次实测即栽在这）
- `handleBrowserDownloadRequest:` 在主线程被调（NSThreadPerformPerform），弹窗无需跨线程 dispatch（仍保留 isMainThread 判断以防万一）
- 默认目录策略：上次使用（NSUserDefaults `ndm_confirm_last_dir`）> NDM 分类目录（`getFolderPath:`）> `~/Downloads`
- 窗口未弹时（如 LSP 初始化前就崩溃），hook 不生效即回归原版行为；payload 解析失败也直接放行

### 已知限制：输出目录覆盖不生效（2026-09-13 实测）

确认窗的「保存到」框目前**只影响弹窗显示，不影响真实落盘位置**，文件仍写入 NDM 分类目录（如 `~/Downloads`）。实测证据：

- `-initWithValues:...finalOutputPath` 传入的目录被引擎忽略；即使改成所选目录，文件仍落分类目录
- 引擎在窗口 init **之后约 165ms 异步**调用 `-[AppDelegate getFolderPath:]`（传的是数字任务 ID，不是分类名）；hook 它返回所选目录同样无效，说明真实目录在更早阶段（AppDelegate 目录 ivar）就已固定
- 请求结构体前 4096 字节内**不含**任何目录路径字符串，故目录无法像文件名那样在结构体上改写

若要真正支持自定义目录，需要继续逆向：定位 `initWithRequest:applicationWindow:appOutPath:` 所属的下载对象类，或在任务创建前改写 AppDelegate 的目录 ivar。

## 安装（已安装过，重装时）

```bash
S=scripts; A=/Applications/NeatDownloadManager2.app
# 备份
cp $A/Contents/MacOS/NeatDownloadManager $A/Contents/MacOS/NeatDownloadManager.bak.confirm
# 编译（两个源文件；注意用 clang++ 以链接 libc++ —— .mm 里调用了 std::string）
clang++ -arch arm64 -arch x86_64 -dynamiclib -fobjc-arc \
  -framework Foundation -framework AppKit \
  -install_name @executable_path/../Frameworks/ndm_confirm.dylib \
  -o $S/ndm_confirm.dylib $S/ndm_confirm.m $S/ndm_request_name.mm
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

App 是托盘态常驻进程，`NSLog` 在无终端时看不到，故内置文件日志：

```bash
# 打开文件日志（写 /tmp/ndm_confirm.log）
defaults write com.NeatDownloadManager ndm_confirm_log -bool YES
tail -f /tmp/ndm_confirm.log
# 关掉
defaults delete com.NeatDownloadManager ndm_confirm_log
```

同样可用终端前台拉起看 NSLog：

```bash
/Applications/NeatDownloadManager2.app/Contents/MacOS/NeatDownloadManager 2>&1 | grep ndm_confirm
```

日志标记：`[ndm_confirm] loaded / hooks installed / 弹窗 / 用户取消下载`、`[confirm] url=... needRename=...`、`[rename] 请求文件名 -> ...`（改名为空则不打印）。

## 按钮交互与 App 激活（2026-09-05 补充）
- macOS 14+ 协作式激活：用户刚在其他 App 操作时 `[NSApp activate]` 会被系统拒绝（红绿灯保持灰色），非激活状态收不到任何鼠标事件
- 双通道激活：先 `[NSApp activate]`，再 AppleScript `tell application id "com.NeatDownloadManager" to activate` 自激活（不受协作式限制），0.25s 后检查 isActive 失败则重试
- HoverButton：自定义按钮类，baseColor 保存原始底色，hover 加深 18%、普通按钮淡蓝底、按压加深 35%
- 兜底：弹窗期间挂 `NSEvent addGlobalMonitorForEventsMatchingMask:(MouseMoved|LeftMouseDragged)` 全局监视器，鼠标命中检测驱动 hover（激活成功后此监视器实际不触发，留作保险）
- 已知系统行为：弹窗后第一次点击仅激活 App，不触发按钮
