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
