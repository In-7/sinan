---
name: sinan-conventions
description: "sinan 桌面笔记应用的开发约定与代码地图。当在本仓库新增或修改功能、挑选或引入依赖、触及窗口与材质、落盘与数据层、编辑器（vendored appflowy/quill）、画布内核，或打算自研一个官方可能已有的能力时使用。"
description_zh: sinan 仓库开发约定：官方优先的取源顺序、代码地图、已踩过的坑
description_en: sinan repo conventions: official-first sourcing, code map, verified pitfalls
version: 1.0.0
allowed-tools: Read,Write,Bash
---

# sinan 仓库开发约定

目标是让改动**走官方正路**、不重犯已修复过的错，并保持本仓库的注释与验证风格。

## 1. 取源顺序（先查，再动手）

1. **Flutter 引擎 / 框架自带**——桌面能力尤其如此：窗口关闭与生命周期、文本输入、系统菜单、剪贴板等，引擎几乎都有官方入口。
2. **官方 SDK 与官方文档**——`docs.flutter.dev` / `dart.dev` / 官方 API 参考。查包用 pub.dev 搜索（本机已接 Dart MCP：`pub_dev_search`、analyzer 诊断、跑测试、`dart format`）。
3. **官方推荐或 pub.dev 上成熟插件**——引入前先搜，并说明"官方路径为什么不够"。
4. **最后**才是自研，或绕过官方机制的三方旁路。

> 要引入依赖或自研前，先在回答里写一句「官方路径是什么、为什么不够」。这条纪律的由来见 `references/pitfalls.md` 案例 1。
>
> ⚠️ 引擎/框架源码就在本机 SDK 里，可以直接查证而不是凭记忆：`<flutter sdk>/engine/src/flutter/shell/platform/windows/**`、`<flutter sdk>/packages/flutter/lib/src/**`。

## 2. 代码地图（改前先定位"这块的性质"）

| 区域 | 性质 | 规矩 |
|---|---|---|
| `lib/src/canvas/**` | **自研**画布内核（文档 / 命令 / 绘制 / 导出 / 栅格化） | 内核**不读 `Theme`**、不依赖 UI 层；笔迹颜色经 `kThemeInk` + `resolveInk` 解析，主题墨色由宿主注入 |
| `lib/src/editor/**`、`lib/src/notes/**` | 自研 UI，构建在 vendored 编辑器之上 | 框架级回调（如 `didRequestAppExit`）统一在 `lib/main.dart` 接线 |
| `third_party/appflowy_editor`、`third_party/flutter_quill` | **vendored 第三方 + 本地补丁** | 改动必须走对应 `PATCHES.md` 的补丁流程；**不要**当上游 API 用，也不要直接升级。`appflowy_editor` 曾是**独立仓库**、2026-09-17 已并入主仓库（原 gitlink 导致克隆后构建不了），其"上游基线 → 补丁"历史在备份 bundle 里，**还原方式见 `PATCHES.md` 文首** |
| `lib/src/data/**` | SQLite 的**唯一出口** | 业务层不拼 SQL；视图不直写库（唯一写入者是 `NotesNotifier`） |
| `lib/src/app/save_debounce.dart`、`lib/src/app/pending_saves.dart` | 落盘调度 / 退出前落盘 | 见 §4 |
| `lib/src/window/**`、`lib/main.dart` | 窗口、材质、退出 | 见 §3 |
| `tools/backup.ps1` | 离线备份（bundle 全量历史 + 工作区镜像 + vendored 历史） | 必须保持**纯 ASCII**：PS 5.1 读无 BOM 的 UTF-8 会按 GBK 解码，中文会让脚本解析失败（实测踩过）。`-Target` 应指向**第二块物理盘**——git 防不了盘坏 |

## 3. 窗口与材质：三个已验证事实

- **退出**：用官方的**可取消退出请求**（`WidgetsBindingObserver.didRequestAppExit` → `pending_saves.dart` 的 `flushThenExit`）。**不要**用 `window_manager.setPreventClose()`——它会先吞掉 `WM_CLOSE`，引擎的官方流程收不到。
- **材质（Mica）**：`acrylic.Window.initialize()` 内部是模块级 `Completer`，**一个进程只能成功调一次**（第二次抛 `Future already completed`）；`hideWindowControls()` 必须在 `setEffect()` **之前**、且只做一次（重设窗口样式会清掉 DWM backdrop）。
- **关闭按钮 / 菜单"退出"**：`WindowService.close()` 最终也汇入同一条 `WM_CLOSE` → 退出请求路径；不需要（也不要）另写一套拦截。

## 4. 落盘：三条路径，别混用

| 路径 | 触发者 | 能否等 |
|---|---|---|
| 防抖 `SaveDebounce`（窗口 500 / 600 ms + **硬上限 2 s**） | 每次编辑 | —（到点即写） |
| **退出前落盘** `PendingSaves` + `flushThenExit` | 关窗口 | ✅ 能**等到写完**（上限 2 s，永远答 `exit`） |
| `dispose` 兜底 | 切笔记 / 卸载 | ❌ fire-and-forget |

- 新视图要支持"关窗口不丢最后一次编辑"：`initState` 里 `ref.read(pendingSavesProvider).register(...)`，`dispose` 里注销（不注销就会对已销毁的视图落盘）。
- 判据统一用 `SaveDebounce.pending`（**没有未落盘变更就不写**）——避免"打开看一眼就关"重写正文。
- 画布**载入失败必须冻结保存**并显示提示条：把空内容写回去等于删用户数据。

## 5. 验证纪律

- 改完必须跑全量：`flutter test` 与 `flutter analyze --fatal-infos --fatal-warnings`（与 CI 同参数）。
- 行为改动要配**能变红**的回归测试：写完先自问"把修复改回去，这个断言会不会照样通过"。
- 视觉色值、时序（悬停延迟）、**真实窗口关闭**这类无法单测的，明确说出来，并给用户"手点 2 分钟"的验收清单，不要含糊过去。

## 6. 注释与文档风格

- 注释写**为什么**、**原来的错法**、**证据**（带日期，如 `2026-09-17 实测`）；不写"做了什么"的流水账。
- 长期设计结论进 `docs/`（如 `docs/data_layer.md` 的 §7.1 落盘时机、`docs/canvas_architecture.md`），代码里只留指针与理由。

已有坑的完整案例（症状 / 根因 / 正解 / 证据位置）见 [references/pitfalls.md](references/pitfalls.md)。
