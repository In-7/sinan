# 已踩过的坑（症状 / 根因 / 正解 / 证据位置）

每条都经过实测或源码核实；"证据位置"给的是**可查证**的地方（本机 SDK 源码或仓库内文件）。

## 1. 关窗口卡在 "(未响应)"（2026-09-17）

**症状**：改完内容立刻关窗口（X 按钮 / Alt+F4 / 标题栏关闭按钮都算），窗口标题变成 `sinan (未响应)`，并且**关不掉**。

**当时的做法**：`window_manager.setPreventClose(true)` 拦下关闭 + 落盘后自研 `windowManager.destroy()` 强关。

**根因**：
- `preventClose` 在窗口过程里**先吞掉** `WM_CLOSE`（原生 `return -1`），Flutter 引擎自己的退出流程**收不到**这条消息；
- 自研 `destroy()` 的原生实现是 `PostQuitMessage(0)`——在 Dart 侧还有未完成的落盘与平台通道往返时，把应用推进了**半拆解**状态：窗口既不销毁、也不再处理消息。

**正解（官方，引擎自带）**：Windows 上引擎提供**可取消的退出请求**——
`WM_CLOSE`（进程最后一个窗口）→ 引擎**消费**它并异步发 `System.requestAppExit`（平台线程**不阻塞**，窗口继续响应）→ `WidgetsBindingObserver.didRequestAppExit` → 答 `exit` 后引擎补发**第二个** `WM_CLOSE`，这一条才真正销毁窗口。
启用是**自动**的：`WidgetsFlutterBinding` 初始化时发 `System.initializationComplete` → 引擎 `BeginProcessingExit()`。

**证据位置**：
- `engine/src/flutter/shell/platform/windows/windows_lifecycle_manager.cc`：`HandleCloseMessage()`（`process_exit_` 闸门、`sent_close_messages_` 记账、`AppExitType::cancelable`）；
- `packages/flutter/lib/src/services/binding.dart`：`initializationComplete()`、`handleRequestAppExit()`；
- `packages/flutter/lib/src/widgets/binding.dart`：`WidgetsBindingObserver.didRequestAppExit`。

**落地**：`lib/main.dart` 的 `didRequestAppExit` → `lib/src/app/pending_saves.dart` 的 `flushThenExit`。
**回归测试**：`test/app/pending_saves_test.dart`（不变量：写完才放行、永远答 `exit`）、`test/canvas/canvas_note_save_path_test.dart`、`test/notes/note_editor_view_appflowy_test.dart`（防抖未到期也能写完）。

## 2. 暗色主题下画布笔迹几乎不可见（2026-09-17）

**症状**：暗色主题下"看不见自己画了什么"（画布纸面 `#161616`，而笔迹 `#1F1F1F`，对比度约 1.1:1）。

**根因**：画布底色**跟随主题**，而笔色是内核里**写死**的 `#1F1F1F`。

**正解**：墨色改为"**跟随主题的哨兵**"——
- `kThemeInk` 的值刻意取历史默认色 `#1F1F1F` ⇒ **存量画布零迁移**一起被修好（当时没有取色器，所有笔迹都是这个值）；
- 宿主注入真实墨色 `AppTheme.canvasInk(brightness)`（暗色与正文字色共用常量，约 12.7:1）；
- `resolveInk(strokeColor, ink)` 统一解析；`Picture` 缓存必须**按墨色失效**（`pictureFor(ink)`）——颜色是烤进显示列表的，不重录就会继续用旧墨色。

**连带的坑**：导出 / AI 栅格化是**白底**，若复用界面缓存的浅墨 → "白底白墨 = 一张空图"。离屏路径固定用 `kThemeInk` 自录一张、用完 `dispose()`。

**回归测试**：`test/canvas/canvas_ink_test.dart`（像素级：默认导出中心像素必须是墨色）、`test/canvas/canvas_picture_cache_test.dart`（换墨色必须重录）。

## 3. 画布载入失败会静默覆盖原文（2026-09-17）

**症状**：内容非空却解析不出（旧格式 / 半截 JSON / kind 记错）时，界面退回空画布，**防抖窗口后把空画布写回**，永久覆盖用户原文。

**正解**：**冻结自动保存**（`_loadFailed`：连防抖都不排、`dispose` 与退出前落盘都过同一道闸），并且**必须给可见提示条**（`errorContainer` + 图标）——否则用户以为在正常编辑，画完才发现什么都没存。

**纪律**：凡是"为保护数据而牺牲功能"的取舍，都要同时给出**可见的代价告知**；把可选项摆给用户（加提示 / 或备份原文后再允许编辑）。

## 4. Flutter 官方剪贴板只有纯文本，块级复制要自己开多格式（2026-11-22）

**症状**：图片块右键「复制/剪切」点了毫无反应；`Ctrl+C` 后再 `Ctrl+V` 粘不出任何东西。

**根因**：官方 `copyCommand` 只取 `text + html`，而 `AppFlowyClipboard.setData` 在
`text == null`（图片块 `delta == null`）时**直接 return** ⇒ 连 html 都没写进系统剪贴板。
更深一层：**Flutter 的 `Clipboard.setData` 三端都只能写纯文本**，没有任何自定义
格式/MIME 能力——想携带块结构必须自己下到平台层。

**正解**：分层（见 `SKILL.md` §7）。逻辑层定协议（`clipboard_codec.dart`：块 JSON +
版本号 + 明文兜底），平台层各写一套：Windows `RegisterClipboardFormat` 自定义格式、
macOS `NSPasteboard` 自定义 UTI；两边都**同时**挂纯文本与位图，外部应用才有得粘。
写失败或平台不支持时回落进程内内存剪贴板。

**纪律**：
- 系统能力先问"官方通道能不能承载我的数据"，不能就**按平台分层自建**，别硬塞进纯文本
  （塞 JSON 到 text 会让用户粘到外部应用时看到乱码）；
- 内存剪贴板是个陷阱：它检测不到"外部复制了别的东西"，会产生粘出旧内容的幽灵 bug——
  能用系统剪贴板就别只用内存；
- 平台层实现必须可注入，测试注入假实现，**测试不许碰真实系统剪贴板/窗口**。

### 4.1 富文本粘贴（粘进来）的两个上游坑（2026-11-22）

**① 官方 `pasteHtml` 是**库内私有**的 unnamed extension**（`paste_command.dart` 里
`extension on EditorState`），`appflowy_editor.dart` 也没导出那个库 ⇒ **跨库不可见**
（`import src/.../paste_command.dart` 也拿不到，unnamed extension 仅库内有效）。
要用只能自己用公开 API 复刻：`htmlToDocument(html)` + `insertNodes` /
`insertText`。注意 **`nodes.single` 在多块时会抛**，被外层 catch 吞成"粘贴失败"
——这个坑真踩过。

**② `DocumentHTMLDecoder` 没有 code 块解析器**：`plugins/html/decoder/` 只有
bulleted / numbered / todo / quote / heading / table / divider / image / text / html。
所以裸 `<pre>` / `<pre><code>` **解析出 0 个节点、内容凭空消失**（实测），比纯文本
还糟。粘贴前必须把 `<pre>` 降级成 `<p>`（见 `normalizeHtmlForPaste`）：文字与
`<code>` 行内样式保住，只是不再是"代码块"。**宁可降级，不能静默吞内容。**

另外：`<ul><li>` 会被解析成**多个并列的 `bulleted_list` 块**（不是一个容器节点）；
`enableColorParse = false` 才能保证"按应用自己的排版渲染"；字体/字号/行高本来就不解析。

### 4.1.1 块手柄的"首行对齐"对媒体块会失效（2026-11-23 用户截图确认）

**症状**：图片块的 `+` `⋮⋮` 手柄不在图片顶部，而是停在块中部（实测偏下）。

**根因**：`_SinanBlockHandleState._alignToFirstLine()` 靠
`selectable.getCursorRectInPosition(...)` 的中心算 `_top`，而：
- 图片没有"首行"，该函数返回的是**块高中心** ⇒ 算出来是居中而非贴顶；
- 它给文字用的 `cjkInkCompensation`（-0.06em，"汉字墨迹中心低于字盒中心"）
  对图片是**纯误差**，恒向下偏 ~1px；
- 更关键：`_alignToFirstLine` 只在 `initState` 后 + `node` 变化时跑。图片从占位
  高度（errorBuilder 100 / loading 150）切到真实高度**不会**触发它 ⇒ `_top`
  钉在过期值上，**偏移量 = 新旧高度差的一半，方向取决于高度变大还是变小**
  （所以"偏上/偏下"两种都能出现，别只按一种方向判断）。

**正解**：`delta == null` 的块（图片/公式/表格）**不参与首行对齐**——`initState`
里直接给固定贴顶值（= 该块 `configuration.padding.top`），`_alignToFirstLine`
开头 `return`。业界（Notion / 飞书 / Craft / Obsidian）图片块手柄都贴**顶**，
不居中。闸门：`sinanBlockHandleTop()`（`@visibleForTesting` 的纯函数）+
`test/notes/image_resize_test.dart`。

### 4.2 块组件里别用 `LayoutBuilder` 测宽度（测试全绿、真机拖块必崩，2026-11-22）

**症状**：`flutter test` 全过，`flutter run` 后一拖动块就炸：
`LayoutBuilder does not support returning intrinsic dimensions`，紧跟着几十条
`Cannot hit test a render box that has never been laid out`，整棵渲染树废掉。

**根因**：块拖拽的 feedback（`custom_block_components.dart` 的 `_buildFeedback`）用
`IntrinsicWidth` + `IntrinsicHeight` 重建整块；`LayoutBuilder` 不支持 intrinsic
计算（它不能在布局回调之外被"推算"一次）。而 widget 测试通常不经过拖拽 feedback，
所以完全测不出来。

**正解**：sinan 的正文列宽是**固定档位**（`AppSettings.contentWidth` 728/800/1008，
**不随窗口变**），需要列宽的地方一律**算好注入**（builder 参数 / 构造参数），
不要在块组件内部测量。要测宽度就用 `EditorTypography` / `BlockHeightPredictor`
那份同口径算式（列宽 − 块内边距 − 手柄占位）。

**闸门**：涉及块内布局的改动，测试里要显式构造
`IntrinsicWidth(IntrinsicHeight(YourBlock(...)))` 跑一遍
（见 `test/notes/image_resize_test.dart`），否则这条路径永远是裸奔。

**验证方式**：CF_HTML 的头部偏移是**字节**偏移，中文下极易算错——一律优先用
`<!--StartFragment-->` / `<!--EndFragment-->` 标记定位。端到端验证要**自己用
ffi 写 UTF-8 字节**再读回（PowerShell 5.1 的 `Set-Clipboard -AsHtml` 按 ANSI
写，读回来是乱码，会误判成自己的解码 bug；`[Clipboard]::SetData` 是延迟渲染，
进程退出后数据就没了）。
