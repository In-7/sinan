# AppFlowy Editor 本地补丁记录

> 本目录是 AppFlowy Editor **6.2.0** 的 vendored 拷贝。
> 上游仓库: https://github.com/AppFlowy-IO/appflowy-editor
> 协议: AGPL-3.0 / MPL-2.0 双协议，**本项目选用 MPL-2.0**（与 askia 一致）。
> vendored 目的：
> 1. 不依赖 pub 的发版节奏——国内镜像（pub.flutter-io.cn）解析到的 `appflowy_editor`
>    最新只有 **0.1.12**，与官方 6.2.0 天差地别；
> 2. 可就地打补丁（依赖冲突、平台适配），不必等上游。
>
> **版本锁（2026-10-25）**：`path:` 依赖 ⇒ pub 升级碰不到本目录，"锁"天然成立；
> 真正的风险是手动跟上游时覆盖目录/漏放补丁。`test/architecture/appflowy_baseline_test.dart`
> 钉住基线版本号 + 关键补丁指纹（丢了立刻红）。**换基线的唯一正路**：下方
> 「同步上游的操作指南」重放补丁 → 更新本文件 → 更新该测试的版本断言。

## 历史形态：曾是独立仓库，**2026-09-17 已并入主仓库**

> **现状**：本目录现在是主仓库里的**普通目录**——父仓库直接跟踪这里的 851 个文件
> （无 `.git`、无 gitlink）。下面记的"独立仓库"是它的**历史形态**，那段历史一条都没丢，
> 完整保存在备份 bundle 里（见下方「历史在哪 / 怎么还原」）。
>
> **为什么并进来**：它原先是一个**没有 `.gitmodules` 的嵌套仓库**（父仓库里只记着一个
> gitlink 提交号），而 `pubspec.yaml` 又以 `path:` 依赖它 ⇒ **克隆主仓库后这个目录是空的、
> 项目构建不了**，也没法 `submodule update`（没有远程地址）。并入后主仓库自包含：
> `git clone` 即可构建，任何回滚都能还原 vendored 源码。

### 历史在哪 / 怎么还原

那段"上游基线 → 我们的补丁"的历史现存在**备份 bundle** 里（含 `refs/tags/6.2.0`）：

```bash
git clone "<备份>/vendored-history/appflowy_editor-final.bundle" /tmp/afe
cd /tmp/afe && git log --oneline        # 上游 pristine → 补丁 → 本文件
git diff 6.2.0 main --stat              # "补丁是否失控"的足迹指标（见下）
```

还原是只读的、可反复做；**改代码不要在那个临时仓库里改**——本目录的文件由主仓库跟踪。

### 曾经的独立仓库历史（`git log`）

```
<补丁>     sinan: register analyzer exclude line + correct verify workflow docs
<补丁>     sinan: patches (file_picker 12.x, drop device_info_plus)
<上游基线>  upstream: appflowy_editor 6.2.0 (pristine, from pub cache)   ← tag 6.2.0
<元文件>    chore: vendored repo hygiene (ignore build artifacts, freeze LF)
```

- **tag `6.2.0` 与上游包逐字节一致**（已用 git 对象哈希逐文件比对：847 个文件）。
  基线内容取自 pub 缓存的原始包
  `%LOCALAPPDATA%\Pub\Cache\hosted\pub.flutter-io.cn\appflowy_editor-6.2.0`
  （**不是** GitHub，直连会超时）。
- 我们与上游的差异 = `git diff 6.2.0 main` ——⚠️ **这个命令现在只能在"还原出的临时
  仓库"里跑**（见上方「历史在哪 / 怎么还原」）。判据：结果应恰好是**下方补丁列表里
  提到的文件 + 本文件**（`example/` 原样保留，不该出现它的增删）。数字变大就说明
  混进了非预期改动——这是判断"补丁是否失控"的唯一指标。
- ✅ **2026-09-11~14 那批"未入档"补丁已于 2026-09-17 提交**（嵌套仓库 `0bd3e53`，
  内容随后并入主仓库 `cc8a9f8`），文末那一节已随之改写为「已入档」。

### 为什么值得建这个仓库

之前 `.git` 是坏的（HEAD 未初始化，`git log` 直接报 broken），于是"升级上游"
只能靠人肉：拷新版本 → 手工重打补丁 → 无法自动发现上游已修好的补丁。
现在升级 = 一条 `git cherry-pick` / `git rebase`，冲突点自动定位。

### 仓库元文件（我们加的，不是上游的）

| 文件 | 作用 |
|---|---|
| `.gitignore` | 挡住 `.dart_tool/`、`pubspec.lock` 等依赖产物。**它们是 pub get / Dart 分析服务自动生成的**，曾被混进基线提交；入库后会让本目录独立 analyze 按旧依赖解析、并淹没真正的补丁差异。 |
| `.gitattributes` | `* -text` **冻结换行**。本机系统级 gitconfig 设了 `core.autocrlf=true`，不冻结则检出时整包 LF→CRLF，整个包看起来"全文件被改"，补丁对比与升级重放全部失效。 |

### 保留 `example/`（与上游一致）

上游自带的 `example/`（139 个文件）**保留**，不再做"瘦身"：
- 删掉它会让 `git diff 6.2.0 HEAD` 多出 139 个删除条目，污染补丁足迹；
- 保留则基线 = 上游原样，未来与 6.3.0 对比时不会出现"example/ 被新增"的噪声。

代价：`example/` 自身有分析报错，且其 pubspec 含 GitHub 上的 git 依赖（本机直连不通），
所以**不要在本目录单独跑 pub/analyze**——正确姿势见文末「怎么检查 vendored 代码」。

## 已验证的重要事实

- **文档主体是惰性渲染的**：`editor_component/entry/page_block_component.dart`
  用 `ScrollablePositionedList.builder`（`itemBuilder` 按需构建）——即**块级虚拟化**，
  只构建视口内的块。这是相对 quill（全量 RenderObject）的大文档性能优势。
- 目标平台 Windows 下，`lib/` 分析**零 error**。

## 补丁列表

### [2026-09-10] 补丁 1 + 3 — file_picker 12.x 全面适配

**文件**: `pubspec.yaml`、`lib/src/editor/util/file_picker/file_picker_impl.dart`、
`lib/src/editor/block_component/image_block_component/image_upload_widget.dart`

**问题**: 官方锁 `file_picker: ^10.2.0`，本项目用 `^12.2.0` → 无交集，
version solving 失败；放宽约束后 **12.x 的破坏性变更**又导致编译失败：

| 变更 | 旧（10/11） | 新（12.x） |
|---|---|---|
| 入口 | `FilePicker.platform.pickFiles()`（实例） | `FilePicker.pickFiles()`（**静态**） |
| 返回 | `FilePickerResult?` | `List<PlatformFile>` |
| 取字节 | `PlatformFile.bytes`（同步可空） | `PlatformFile.readAsBytes()`（**异步**） |
| 保存 | `saveFile()` 只选路径，返回 `String?` | `saveFile(fileName:, bytes:)` 写入并返回 `Uri?` |

**改动**:
1. `pubspec.yaml`：约束放宽为 `>=10.2.0 <13.0.0`；
2. `file_picker_impl.dart`：三处调用改静态方法；`pickFiles` 适配新返回类型；
   `saveFile` 因语义无法对应（新 API 要求提供 bytes）返回 `null`——
   本项目无任何调用点依赖保存对话框；
3. `image_upload_widget.dart`：`file.bytes` → `await file.readAsBytes()`（仅 Web 分支）。

**验证**: `flutter build windows --debug` 通过 ✓

**何时可撤销**: 上游适配 file_picker 12 后（迁移到新 API 是上游的 breaking change，
短期不会发生）。

### [2026-09-10] 补丁 2 — 移除 device_info_plus（Android 死路径）

**文件**: `pubspec.yaml` +
`lib/src/editor/toolbar/mobile/utils/keyboard_height_observer.dart`

**问题**: `device_info_plus ^11` 依赖 `win32 ^5`，与本项目 `win32 ^6`（剪贴板 DIB 用）
冲突；所有 11.x/12.x 版本都锁 win32 ^5，放宽 appflowy 侧约束无效。

**改动**: 移除该依赖，并把 `KeyboardHeightObserver` 中查询 Android SDK 版本的调用
置为死分支（原逻辑保留为注释）。该包在本项目目标平台（Windows 桌面）用不到。

**何时可撤销**: 上游改用不依赖 win32 的平台检测，或我们不再需要 win32 ^6。

### [2026-09-10] 编外一行 — `analysis_options.yaml` 排除 `build/**`

**文件**: `analysis_options.yaml`

**内容**: `analyzer.exclude` 追加一行 `- build/**`（并补了文件末尾换行）。

**说明**: 这一行**无实际作用**——本目录下并不存在 `build/`（真正的构建发生在仓库根
目录）。它原先未登记；2026-09-10 重建基线时先丢弃，但发现**本机工具链/编辑器会反复
写回该行**（丢弃后又被自动写回，工作区长期处于脏状态）。为消除这种噪声，**纳入补丁
并在此登记**。

**何时可撤销**: 查明并消除写回源头后，随下次上游升级一并丢弃即可（丢弃不影响任何功能）。

### [2026-09-14] 补丁 10 — 把精确块高喂给滚动器（总高不再靠外推）

**文件**：
- `lib/src/editor/editor_component/service/scroll/editor_scroll_controller.dart`（+12 行：新增 `itemExtentOf` 字段）
- `lib/src/editor/editor_component/entry/page_block_component.dart`（+2 行：透传给列表）
- `lib/src/flutter/scrollable_positioned_list/src/scrollable_positioned_list.dart`（+13 行：两个构造函数 + 字段 + 两处透传）
- `lib/src/flutter/scrollable_positioned_list/src/positioned_list.dart`（+38 行：字段 + 三段 sliver 换用新 delegate）
- `lib/src/flutter/scrollable_positioned_list/scrollable_positioned_list.dart`（+1 行：barrel 导出）
- **新增**：`lib/src/flutter/scrollable_positioned_list/src/extent_aware_sliver_delegate.dart`

**问题**（用户现象：**滚动条滑块在滚动中变长变短；滚到文档中段会"猛滑一下"**）：

滚动列表的总高来自 Flutter 对**未布局块**的外推——
`SliverChildBuilderDelegate.estimateMaxScrollOffset` 默认返回 `null`，于是走
`_extrapolateMaxScrollOffset`：**「已布局块的平均高度 × 剩余块数」**（`flutter/
lib/src/widgets/sliver.dart`）。局部平均 ≠ 全篇平均时（三行标题 / 图片 / 代码块
扎堆）总高被抬高，锚点制（`PositionedList` 的三段 sliver）的内容就整体位移一次
= 手感"滚到中间像加速了一下"；滚到末尾外推项消失、总高回落到真值 ⇒ **滑块变长**。
应用侧实测（`test/note_editor_view_appflowy_test.dart`）：

| 文档 | 初始估计 | 真值 | 滑块长度 |
|---|---|---|---|
| 均匀 320 个单行段落 | 10224 | — | 43.6px（不动） |
| **20 个 6 行段落在前 + 300 个单行段落** | **68646** | 13864 | **6.9px → 32.7px** |
| 末尾一屏留白 600px 的文档 | 尾部被修正一次 | — | 滚到底时突然变长 |

**改动**：新增 `ExtentAwareSliverChildBuilderDelegate`（`SliverChildBuilderDelegate`
的子类），把 `estimateMaxScrollOffset` 直接返回**该段内容的已知总长**；三段 sliver
各自按"全局 item 区间"求和，逐项高度由应用侧通过 `EditorScrollController.itemExtentOf`
给出。要点：

- **全加法**：`itemExtentOf` 为 `null`（默认）时，`positioned_list` 的三处
  delegate 求和路径与上游**逐字相同**（仍走官方外推）；
- **不变量**：返回值钳到 ≥ 本段**已布局**部分的长度——`RenderSliverList.performLayout`
  里有断言，且小于它会让内容被裁（高度被低估时，例如图片还没量到，靠这条兜住）；
- **按全局区间求和**而不是"本段的相对 index"：锚点前那段是**倒序构建**的
  （相对 index `i` → 全局 `positionedIndex - 1 - i`），两者不成线性对应；
- **`separatorBuilder` 非空时不生效**（item 与 separator 的 index 空间交错，
  本表按 item index 给值对不上）⇒ 那种情况退回官方外推。

**效果**（`test/note_editor_view_appflowy_test.dart` 的两条闸门）：
`C：总高从第一帧起精确——高矮块扎堆时全程不变` 断言整段滚动里总高变化 < 1px
（修前是 **3458px**）；`滚动中估计总高稳定` 一并**收紧**（原先刻意排除"首屏高块
扎堆"与"末尾一屏留白"两种官方外推治不了的情形，现在整段含尾部都在闸门内）。

**应用侧配套**（不在本目录）：
- `block_height_predictor.dart`：`TextPainter` 干跑布局，对**文字块 / 分隔线 /
  代码块 / 图片**逐像素准确（3 组排版 × 34 个块偏差全为 0.0px）；**表格**用节点里的
  `colsHeight` 估到"同量级"（近似，非逐像素——原因见该文件的 `_tableHeightOf` 文档：
  官方 `updateRowHeight` 是 post-frame 异步写回，"属性 ↔ 渲染"本就有时序差）；
  公式 / 附件仍返回 null（退回"按一行估"，被布局到时由实测替换）。
- `blocks/image_metrics.dart`：**只读图片标头**解析原始宽高比并缓存。没存尺寸的
  图片（导入的图片都不带）解码完成时块高会变 ⇒ 总高变一次；预解析后**在块被构建
  之前**就能算准，那次变化随之消失。
- `block_heights.dart`：取值链 **实测 → 预算 → 类型兜底**。
- `note_editor_view_appflowy.dart` 的 `_itemExtents`：结构/参数变化时重建，实测与
  图片比例回包时 **O(1) 就地改一项**（整体重建要 ~10ms/300 块，逐帧做不起）。

⚠️ 预算器是**复刻**渲染几何，所以应用侧那 3 处几何（`getTextSpan`/`adjustTextSpan`、
各块的 `Container(padding:)`、我们自己代码块的字体比例与内边距）任一改动都会让预测偏
——`test/block_height_predictor_spike_test.dart` 就是为此立的闸门（它会红）。

**验证**: `flutter test`（仓库根）全绿 183 passed / 1 skipped，`flutter analyze` 零问题 ✓

**何时可撤销**: 上游自己暴露"精确高度"的能力时（例如接出 `minCacheExtent`、
`itemExtent`/`itemExtentBuilder`，或换用 `super_sliver_list`——它本就有
`estimateExtent` 回调）。撤销方式：应用侧不再设 `EditorScrollController.itemExtentOf`
即完全回到官方行为，本目录的补丁可整体丢弃。

### [2026-09-14] 补丁 11 — 选区刷新防抖的悬垂引用（热重启 / 切笔记时的未捕获异步异常）

**文件**：
- `lib/src/editor/editor_component/service/selection/desktop_selection_service.dart`（+22 行）

**问题**（用户实机报回：连做几次热重启后出现，**未捕获异步异常**）：

```
Null check operator used on a null value
#0 _DesktopSelectionServiceWidgetState.didChangeMetrics.<anonymous closure>
   (desktop_selection_service.dart:84:53)
#1 Debounce.debounce.<anonymous closure> (debounce.dart:22:19)
```

上游把"选区非空"的判据放在**排定时**，取值却发生在 **100ms 后的闭包**里：

```dart
if (currentSelection.value != null) {               // 排定时判一次
  Debounce.debounce(key, 100ms,
    () => updateSelection(currentSelection.value!)); // 100ms 后才取，且用 `!`
}
```

这 100ms 里选区只要被清空——`dispose()` 里就会 `clearSelection()`（切笔记、
热重启、关闭编辑器都会走）——闭包就对着 null 取 `!`。而且 `dispose()`
**不取消**这个定时器（`Debounce` 的表是**静态**的，不随 State 走）⇒ 它会在
控件卸载之后照常执行，去碰已 dispose 的 `currentSelection`。

**改动**（两处，都是"补漏"，不改正常路径行为）：

1. **回调里现取 + 空判**：`final selection = currentSelection.value; if (selection == null) return;`
   —— 选区还在时（正常路径）行为逐字不变；
2. **`dispose()` 里 `Debounce.cancel(_kRefreshSelectionDebounce)`**：定时器不再跨卸载存活。

防抖 key 抽成常量 `_kRefreshSelectionDebounce`：同一字符串要在两处用，
就地写两遍迟早写漂。

**验证**：新增闸门 `test/note_editor_view_appflowy_test.dart` 的
`改窗口尺寸后立刻卸载：不留抛异常的选区刷新定时器`——点正文落光标 ⇒ 改窗口
尺寸（排定防抖）⇒ 100ms 内卸载 ⇒ 越过防抖窗口。**修前它以完全相同的栈失败**
（`desktop_selection_service.dart:84:53` → `debounce.dart:22:19`），修后通过。

**何时可撤销**: 上游改成"回调里取 + 卸载时撤"（或不依赖静态防抖表的写法）后，
还原这两处即可。

### [2026-09-14] 补丁 12 — 重做只能做一次（"重做自身"被当成新编辑，清空了重做栈）

**文件**：
- `lib/src/history/undo_manager.dart`（+18 行：`_applyingRedo` 标记 + `getUndoHistoryItem` 里跳过 `redoStack.clear()`）

**问题**（用户现象：**"重做好像只能重做一次"**）：

`UndoManager.redo()` 用 `recordUndo: true` 应用重做事务（重做出来的内容理应成为
一条新的撤销历史）⇒ 于是会走 `getUndoHistoryItem()`；而那条路径上有一条
**"新的用户编辑作废重做栈"**的规则：

```dart
    final last = undoStack.last;
    if (last.sealed) {
      redoStack.clear();      // ← "重做"自己也走了这条路
      …
```

于是"重做"这个动作本身把**剩余的重做历史**清掉了。实测
（`test/note_editor_view_appflowy_test.dart`）：3 次编辑 → 3 次撤销 → 重做只能走
**2** 步，第 3 步静默失效（实测序列 `['你好世界1','你好世界12','你好世界12']`）。

> 为什么是 N−1 而不是 1：第 1 次重做时 `undoStack` 还是空的（走 `isEmpty` 分支，
> 不清栈）；从第 2 次起，上一步重做留下的历史项已经封口（50ms 合并窗口）⇒ 触发清空。

**改动**：加 `_applyingRedo` 标记（`redo()` 的应用期置位、try/finally 复原），
`getUndoHistoryItem()` 里**只在非重做时**清重做栈——语义就是"重做不是新的用户编辑"。

**验证**：`test/note_editor_view_appflowy_test.dart` 的
`多步撤销 / 重做：重做要能一路做到头`——3 编辑 / 3 撤销 / 3 重做，逐步断言文本
回到 `你好世界1 → 你好世界12 → 你好世界123`。**修前它以 `['…1','…12','…12']`
失败**，修后通过。

**何时可撤销**: 上游让 `redo()` 改用"不写撤销栈"的 ApplyOptions（或显式区分
"这条事务来自重做"）后，还原这两处即可。

### [2026-09-15] 补丁 13 — 浮动工具栏与选区留 8px 间隔

**文件**：
- `lib/src/editor/toolbar/desktop/floating_toolbar.dart`（+22 行：`_toolbarTop` + `_toolbarGap`）

**问题**（用户现象：**"浮动工具栏和拖选区域距离太近"**，附截图）：

官方落位是 `Positioned(top: max(0, top) - floatingToolbarHeight)`，而
`calculateToolbarOffset` 在正常分支返回的就是**选区顶缘** ⇒ 条的下缘被放在
**正好等于**选区上缘的位置，零间隔；选区贴近编辑器顶部时改放下方，
`top = rect.bottom + floatingToolbarHeight`，减掉浮条高后同样零间隔。
观感就是"条和选区粘在一起"。

**改动**：新增 `_toolbarTop(rect)`——方向判据不变（`rect.top <
floatingToolbarHeight` ⇒ 放下方），但上下各让出 `_toolbarGap`，并保留官方的
非负钳制。**不复用 `calculateToolbarOffset` 返回的 `top`**：它在下方落位分支
已加过 `floatingToolbarHeight`，再减回去容易错符号，直接用 `rect` 算更直白。

**间隔取值**：**8px**。先取 2px 试过，用户实机反馈"变化不大"；对照新版官方与
主流笔记应用的浮条（截图里间隔 ≈ 正文行高的 1/3）定为 8。这个值只跟手感有关，
不牵动任何布局契约（浮条是 overlay，不占正文）。

**我们的调用侧无需改动**：`note_editor_view_appflowy.dart` 传的
`floatingToolbarHeight: 30` 与 1px 发丝描边（`padding: horizontal 7`）等量补偿
后，条的外形仍是 32 —— 官方定位数学与补丁都用同一个常量，不会错位。

**验证**：`test/editor/fixed_toolbar_test.dart` 的
`浮条与选区留 8px 间隔（不贴着拖选区域）`——取选区的锚定 rect 与浮条外框
（`Material`）的实际 Rect，断言落位那一侧的空隙**恰好 8px**。
（该用例已反向验证：把 `_toolbarGap` 改回 0 立刻以"下方 0.0"失败。）

**何时可撤销**: 上游给 `FloatingToolbar` 加"浮条与选区间隔"的样式槽位
（或默认值），改传参数即可。

### [2026-09-15] 补丁 14 — 斜杠菜单的投影与描边对齐"浮层三件套"

**文件**：
- `lib/src/editor/selection_menu/selection_menu_widget.dart`（`DecoratedBox` 的
  `BoxDecoration`：+`border`、投影换成与 `menuElevation` 同档）

**问题**（用户现象：**"手柄菜单和其他菜单的背景色/对比度不统一"**）：

探针实测（`test/editor/editor_overlay_tokens_test.dart`）两处不齐：
1. **块操作菜单**（子树里的 `MenuAnchor`）落到 M3 默认：带种子色的
   `surfaceContainerHigh`（亮色实测 `#E9EFEE`）+ elevation 3 + radius 4 + 无描边
   —— 根因是 `MaterialUiCompatibilityBridge` **不透传 `menuTheme`**。这条在
   **应用侧**修（`lib/src/editor/widgets/float_menu_style.dart`，显式传
   `MenuStyle`），**不动 vendored**；
2. **斜杠菜单**底色本来就是我们的 `floatSurface`（✓），但投影是**硬编码**
   （单向 blur 5 / spread 1 / 黑 10%）且**没有描边** ⇒ 比应用侧菜单"扁"。

**改动**：给 `SelectionMenuStyle` 的既有槽位 `selectionMenuDividerColor` 当描边色
（我方在该槽位传的就是 `outlineVariant`，与 `AppTheme.menuBorder` 同源），
并把投影抬到与 `menuElevation` 同档（黑 16% / blur 12 / offset (0,4)）。
圆角 6 与应用侧 `Tokens.radiusSm` 本来就相同，未动。

**验证**：`test/editor/editor_overlay_tokens_test.dart` 同时钉住两个菜单的
底色 / 描边 / 投影，与 `AppTheme.floatSurface` / `outlineVariant` /
`menuElevation` 逐项相等。

**何时可撤销**: 上游给 `SelectionMenuStyle` 加描边与投影槽位（或直接默认对齐
Material 的浮层规格）后，改传参数、还原这三行即可。

### [2026-09-15] 补丁 15 — 点击链接时不再连带弹出浮动格式工具栏

**文件**：
- `lib/src/editor/editor_component/style/default_text_span_decorator_for_attribute.dart`
  （+6 行：那次 `updateSelectionWithReason` 补 `extraInfo`）

**问题**（用户现象：**"点击链接后浮动工具栏和链接的编辑栏都会跳出来，正常吗"**）：

官方对 href 的点击实现就在本文件——单击后（200ms 与双击区分）把**整条链接**
设成选区，再由 `showLinkMenu` 弹出链接编辑菜单。而浮动工具栏是靠"选区变化"自
己冒出来的（`floating_toolbar.dart` 的 `_onSelectionChanged` / `_showToolbar`），
于是两个浮层叠在一起：链接编辑菜单 + 格式工具栏。

**改动**：给那次选区更新补上官方现成的开关

```dart
extraInfo: { selectionExtraInfoDisableToolbar: true }
```

工具栏两处判定都认这个标记（`floating_toolbar.dart:139` / `:202`），所以一条
就够；同一文件里的**右键**（`desktop_selection_service.dart:378`）与**查找
高亮**（`find_replace_menu`）本来就这么写——上游漏的正是链接点击这一条。

**为什么不改成"点击直接打开链接"**：本项目已经用**悬浮提示**
（`lib/src/editor/widgets/link_hover_tooltip.dart`）承担了"打开/复制"，
而点击保留"编辑链接"语义（Ctrl/Cmd+点击或双击打开，官方原有行为不变）——
工具分工清楚，改动面最小。

**验证**：`test/notes/note_editor_view_appflowy_test.dart` 的
`点击链接：只弹链接编辑菜单，不再连带浮动工具栏`——单击链接后断言链接编辑
菜单在、而浮动工具栏（`FloatingToolbar` 的 `Material`）不在。
（反证：把那行 `extraInfo` 删掉，该用例立刻以"浮动工具栏也弹了"失败。）

**何时可撤销**: 上游把"链接点击"也纳入 `selectionExtraInfoDisableToolbar`
口径（或干脆不再借"设选区"来弹链接菜单）后，还原这一处即可。

### [2026-09-16] 补丁 16 — 右键菜单体感修复（非文本块 / 空白 / 无选区都能弹，且不挪动视图）

**文件**：
- `lib/src/editor_state.dart`（+1 行：`SelectionUpdateReason` 枚举加 `contextMenu` 值，带 `[sinan]` 注释）
- `lib/src/editor/editor_component/service/selection/desktop_selection_service.dart`
  （`_onSecondaryTapDown` / `_showContextMenu` / `_clearContextMenu` 三处改动）

**问题**（用户现象：**右键点在非文本块（图片 / 分割线 / 代码 / 嵌入）、文档末尾空白区、
或当前无选区时毫无反应**；且**右键后视图跳到光标处**、点外部关闭菜单又跳回去）：

官方 `_onSecondaryTapDown` 的逻辑分两段出问题：
1. 点到的节点 `selectable == null`（非文本块 / 末尾空白）时，原逻辑 `clearSelection()`
   后直接 `return` ⇒ 右键彻底没反应；
2. 即使有选区，原逻辑会用**默认 `uiEvent` 原因**更新选区（把光标移到点击点）。而 `uiEvent`
   会触发 `_selectionType = inline`（`editor_state.dart:333`），这条正是"选区变化→滚到光标"
   的开关 ⇒ 右键一下视图跳到中间；关闭菜单时 `_clearContextMenu` 同样用 `uiEvent` 刷选区
   ⇒ 已滚开的视图又被拉回光标处（"滚开后点外部关闭会跳回去"）。

另有 `_showContextMenu` 里 `if (selectionRects.isEmpty) return;`：点末尾空白 / 非文本块时
选区矩形为空 ⇒ 菜单根本不弹（须先左键落光标，违背右键直觉）。

**改动**（三处，互相配合，都走新增的 `contextMenu` 原因）：
1. **[16]** `_onSecondaryTapDown`：`selectable == null` 时**不再 `clearSelection()`+return**，
   改为保留当前选区、直接 `_showContextMenu(details)`（菜单按点击点定位，剪切/复制按可用性
   置灰）。有选区时改用 `SelectionUpdateReason.contextMenu`（据此豁免"选区变化→滚到光标"，
   见下），并带 `selectionExtraInfoDisableToolbar` 不让浮条冒出。
2. **[16b]** `_showContextMenu`：删掉 `if (selectionRects.isEmpty) return;`。菜单本就按
   `details.localPosition` 定位、不依赖选区矩形，只要 builder 在就弹（剪切/复制按可用性
   置灰）——非文本块 / 末尾空白 / 无选区都能弹。
3. **[16c]** `_clearContextMenu`：关闭菜单时的两次 `updateSelectionWithReason` 从 `uiEvent`
   改为 `contextMenu` 原因，只刷新选区渲染、不触发"选区变化→滚到光标"。

> **`contextMenu` 原因的豁免机制**：`editor_state.dart:333` 只在 `reason == uiEvent` 时把
> `_selectionType` 设成 `inline`（驱动滚动的开关）。`contextMenu` 不是 `uiEvent` ⇒
> `_selectionType` 保持原值、不进滚动分支。所以新增枚举值本身 + 改用它，就达成了"右键
> 锚定菜单、不挪动视图"——即"scroll 服务已豁免该原因"的含义。

**应用侧配套**（不在本目录）：`note_editor_view_appflowy.dart` 据此**移除**了视图层另挂的
一份 OverlayEntry 右键菜单（与官方路径叠加会成"页面底部两个菜单"），统一走官方链路。

**验证**：`test/notes/note_editor_view_appflowy_test.dart` 两条——
- `正文右键：出菜单（此前 contextMenuBuilder 没接 ⇒ 毫无反应）`：右键正文断言"剪切/粘贴/
  全选"都在、且面板走浮层令牌 `AppFloatSurface`；再点"全选"验证选区覆盖整段文字；
- `页面留白右键：同一个菜单（官方链路不管这片空白）`：右键末尾留白热区断言"粘贴/全选"都在；
  点别处被遮罩关掉；二次右键再卸载，断言 `takeException() == null`（overlay 条目被干净
  撤掉、不挂在下一屏）。

**何时可撤销**：上游让右键对非文本块 / 空白 / 无选区都能弹、且右键不触发"选区变化→滚到
光标"后，把本目录三处改动还原、并删掉 `editor_state.dart` 的 `contextMenu` 枚举值即可
（应用侧移除自建菜单的那部分也一并还原）。

### [2026-09-17] 补丁 17 — "整个编辑器可点"不再暴露给无障碍树（a11y）

**文件**：
- `lib/src/service/selection/selection_gesture.dart`（`RawGestureDetector` +1 行：
  `excludeFromSemantics: true`）

**问题**（`test/a11y/` 的 `labeledTapTargetGuideline` 报出）：桌面端把**整个编辑器**包在
`SelectionGestureDetector`（落光标用，见 `desktop_selection_service.dart:124`）里，这一层
因此给语义树留下一个**没有名字的可点节点**。判据是 `flutter_test` 的
`accessibility.dart:264`——`label` 与 `tooltip` 都为空即判违规（**`tooltip` 也算合格标签**）。
读屏（NVDA）会念出一个无名按钮。

**改动**：`RawGestureDetector` 加 `excludeFromSemantics: true`——只让**本层**不贡献语义
（`_GestureSemantics` 完全不挂），子节点（各块、文本域）自己的语义不受影响。这正是"只删掉
那个多余动作"的精确手段；**在外层包 `Semantics` 做不到**：只能加不能减，`container: true`
还会把子树语义压成一层（读屏丢掉逐块导航），`ExcludeSemantics` 则是整棵子树全丢。

**验证**：`test/a11y/accessibility_test.dart`——首次盘点时编辑器报 3 个无标签可点节点；
修 `_HistoryButton`/`_EarButton` 的 tooltip 归属（应用侧，不是本补丁）后 3→2；**本补丁后 2→1**。
最后的 1 条（滚动视口 `tags: [RenderViewport.twoPane]`）经查明**与本补丁无关、也与本目录无关**：
它是应用侧 `footer`（"点文档末尾空白继续输入"那块**无文字**的可点区）的 `tap` 语义**向上合并**
到视口节点造成的，已由应用侧 `GestureDetector(excludeFromSemantics: true)` 修掉。
三段贡献可分离：**3→2** 是应用侧 tooltip 归属修复，**2→1** 是本补丁，**1→0** 是应用侧 footer。
详见 `docs/a11y.md` §4。

**何时可撤销**: 上游给这一层加 `excludeFromSemantics` 槽位（或不再用无名手势层承载"落光标"）
后，还原这一行即可。

### [2026-09-17] 补丁 18 — 斜杠菜单里按退格越界断言（键盘路径）

**文件**：
- `lib/src/editor/selection_menu/selection_menu_widget.dart`（`_deleteLastCharacters` +8 行：越界防护）

**问题**（用户实机粘贴的崩栈，Windows）：

```
'package:appflowy_editor/src/core/transform/transaction.dart':
Failed assertion: line 279 pos 7: 'index + length <= delta.length && index >= 0 && length >= 0'
#2  TextTransaction.deleteText
#3  _SelectionMenuWidgetState._deleteLastCharacters (selection_menu_widget.dart:640:9)
#4  _SelectionMenuWidgetState._onKeyEvent              (selection_menu_widget.dart:562:7)
KeyMessage: KeyMessage([KeyDownEvent ... debugName: "Backspace" ...])
```

斜杠菜单开着、光标又落在**块首**（offset 0）时按退格：`_onKeyEvent` 的退格分支先
`keyword.isEmpty → onExit()`，然后**无条件**调 `_deleteLastCharacters()`，那里算出的
`offset - 1 = -1` 被直接喂给 `deleteText` ⇒ 断言，并**打断整条键盘分发**（不是普通的
渲染报错，是输入整条链路卡住）。

复现路径：输入 `/` 打开菜单 → 退格删掉 `/`（菜单 `onExit` 了，但这一帧 widget 仍挂着）
→ 再按一次退格。

⚠️ 这与 `SelectionMenuItem._deleteSlash` 那条是**同源问题的第二处**（那条此前已有防护，
见 `test/editor/slash_menu_delete_guard_test.dart`）——**键盘这条漏了**。两处一起看，别再补第三处。

**改动**：算出 `index` 后先做边界检查，越界即早退。"块首没有前一个字符可删"就是正确语义；
keyword 非空时照旧删掉刚输入的搜索字符。

**验证**：`test/editor/slash_menu_delete_guard_test.dart` 新增两条——

1. **前置事实**：`deleteText(node, -1, 1)` 确实 `throwsAssertionError`（证明断言真实存在，
   否则下面的 widget 用例可能是空转）；
2. **键盘路径**：挂 `SelectionMenuWidget` + 光标在块首 + `sendKeyEvent(backspace)` ⇒
   断言 `takeException() == null`、文本不变。⚠️ 该用例**同时断言 `onExit` 被调用过**——
   这个回调只可能由退格分支触发，于是"按键确实到了 handler"是被证明的，排除空转。

**何时可撤销**: 上游在 `_deleteLastCharacters` 里自加边界检查（或让 `_onKeyEvent` 在
`keyword.isEmpty` 时不再调它）后，还原这一处即可。

### [2026-09-23] 补丁 19 — 斜杠菜单图标槽位 `IconData?` → `Widget?`（应用侧图标整体改走 tabler 控件）

**文件**：
- `lib/src/editor/selection_menu/selection_menu_icon.dart`（`icon` 字段类型 + 渲染改 `SizedBox(18)`）
- `lib/src/editor/selection_menu/selection_menu_widget.dart`（`iconData` 参数类型 + 渲染同上）
- `lib/src/editor/block_component/table_block_component/table_block_component.dart`（`tableMenuItem` 图标包 `Icon()`）
- `lib/src/editor/block_component/divider_block_component/divider_menu_item.dart`（`dividerMenuItem` 同上）

**问题**：应用侧把编辑器图标从**字体图标**（`IconData`）整体换成 **tabler 控件**
（`tabler_icons_next` 的 SVG Widget）——映射表 `editor_icons.dart` 的
`EditorIconBuilder` 现在返回 `Widget`，经 `EditorSvg.iconOverride`（补丁 4）换皮。
但斜杠菜单这条路径**不经过 `EditorSvg`**：`SelectionMenuItem.icon` 直接把图标交给
`SelectionMenuIconWidget`，而后者字段是 `IconData?` ⇒ 应用侧换成 Widget 后类型对不上。

**改动**：两个 widget 的图标槽位改收 `Widget?`；渲染处的 `Icon(...)` 换成
`SizedBox(width: 18, height: 18, child: icon)`——18 是官方工具栏的 `iconSize` 契约，
原先靠 `Icon` 自带的 24 框约束，换成任意 Widget 后必须显式定框，否则 tabler 控件的
固有尺寸（24）会让斜杠菜单条目比官方条目大一圈。`SelectionMenuItem(_iconWidget)`
的**构造点本来就不必动**（它一直收 `Widget`）。

⚠️ 官方自带的两条 item（`tableMenuItem` / `dividerMenuItem`）在**各自文件里**传的是
`Icons.table_view` / `Icons.horizontal_rule`：字段放宽成 `Widget?` 后这两处编译不过
（`IconData` 不是 `Widget`）⇒ 就地包一层 `Icon(...)`，**上游语义逐字保留**。
这两条在应用侧被 `slash_menu_items.dart` 的 `_isNotMaterialIconItem` **整体剔除**
（换成了自己的 tabler 版条目，见 `test/editor/slash_menu_items_test.dart` 的断言），
所以**永远不会被渲染**，包 `Icon()` 只为编译通过。

**验证**：`flutter test`（仓库根）**897 passed / 0 failed**；`flutter analyze` 零问题 ✓

⚠️ **这道补丁的漏改很难自查**：`analysis_options.yaml` 排除了 `third_party/**`
⇒ **`flutter analyze` 看不见本目录的编译错误**，漏改只由 `flutter test` /
`flutter build windows` 暴露（当时的症状是 25 个测试文件**加载即失败**：
`Compilation failed ... The argument type 'IconData' can't be assigned to the
parameter type 'Widget?'`）。改本目录后**务必跑一次仓库根的 `flutter test`**。

**何时可撤销**: 上游把 `SelectionMenuItem.icon` 也接到 `EditorSvg.iconOverride`
（或直接把图标槽位类型放宽为 `Widget`）后，还原这四个文件即可。

### [2026-10-25] 补丁 21 — 连续标点互挤（jiya 行内可判子集）

**问题**：全角标点自带半宽空白，两个标点相邻时空隙成倍出现（`。」`、`』，`、
`！？`），中文段落出现"洞"。印刷界的解法是标点挤压（jiya / CSS
`text-spacing-trim` 的"减法规则"）：相邻可挤标点对删去之间的空。

**改动**：
- 同一纯函数文件扩展（`text_span_cjk_spacing.dart`，入口改名
  `applyCjkTextSpacing`）：**单遍扫描**同时算中西文间距（正）与标点互挤
  （负）。字符表按减法规则分四类：开启符號 / 結束符號 / 句終中點（可挤）、
  連接省略（`——……～・`，不挤且打断链）。互挤量 `kPunctSqueezeEm = 0.1em`
  负尾随 letterSpacing（实测标定：palt 后 `。」` 残余墨缝 ≈0.15–0.17em，
  收到 ≈0.15em 起笔画相触 ⇒ 0.1em 留 25–40% 余量）。
- 接线沿用补丁 20 的两处（`adjustTextSpan` 尾部 + `BlockHeightPredictor`
  同源），**不改任何调用点结构**。
- 只做"行内可判"部分；行首/行尾收紧需折行信息（两遍排版），实时编辑器
  代价过高，不在此列——见 `docs/editor_migration_spike.md`。

**为何不用 CSS `hanging-punctuation`/行尾方案**：需要折行信息，编辑器每敲
一键重测重排；Han.css 的 web 实现靠 DOM 测量包裹 span，同理不适配。

**何时可撤销**: 引擎提供行内标点挤压（如 Flutter 支持 `text-spacing-trim`
语义）后，删本函数的互挤分支即可（间距分支是补丁 20）。

### [2026-10-25] 补丁 20 — 中西文自动间距（显示层，不动文本）

**问题**：中文与拉丁字母/数字直接相邻（`使用API`、`2026年`）时代排版惯例要留
约 ¼ em 空隙（CLREQ / pangu 方向），引擎不提供；应用层又不能往文本里插空格
——编辑器按**字符索引**映射光标/选区/IME，插字符会让全部位置映射错位、复制
被污染。

**改动**：
- 新增 `lib/src/extensions/text_span_cjk_spacing.dart`：纯函数
  `applyCjkLatinSpacing(TextSpan)`——在表意↔西文直接相邻的边界处，给**边界前
  那个字符**加尾随 `letterSpacing`（`(fontSize × 0.25).roundToDouble()`）。
  带间隙的字符独占单字 span（`letterSpacing` 作用于段内每个字形，多字段会把
  段内字距也撑开）。文本逐字节不变；无边界时原样返回（`identical`）。
  经 `extensions.dart` 导出。
- `appflowy_rich_text.dart` 的 `adjustTextSpan` 末尾调用它。**必须在各块的
  `textSpanDecorator`（`updateTextStyle` 样式合并）之后**——heading 合并会把
  `letterSpacing: 0` 覆盖到叶子上，先加间隙就被顶掉。
  ⚠️ 为何不用官方 `EditorStyle.textSpanDecorator`（`textSpanDecoratorForAttribute`）
  扩展点：它在 `getTextSpan` 的**逐条合并管线内**执行，随后各块的
  `updateTextStyle` 会经 `TextStyle.combine` **无条件覆盖** `letterSpacing`
  （`text_style_extension.dart` 的 `combine`：`letterSpacing: other.letterSpacing`）
  ⇒间隙必被顶掉。官方没有"合并后"的样式钩子，`adjustTextSpan` 尾部是唯一
  能在全部合并之后改 span 的位置（2026-10-25 对照官方 main 源码确认，官方
  至今无任何 letterSpacing/字体特性/标点处理）。
- 应用侧 `BlockHeightPredictor._heightOfSpan` 复用**同一函数**（预测与渲染
  同源），闸门 `test/editor/cjk_spacing_test.dart`。

**何时可撤销**: 上游提供官方的中西文间距/标点处理后，还原 `adjustTextSpan`
两行 + 删扩展文件即可（预测器侧同步删）。

## 已核对但**无需**补丁的项

### Flutter 3.44+ 的 `TextInputClient.onFocusReceived`

askia 的 6.2.0 副本缺少该方法实现（编译期报 Missing concrete implementation），
我们的副本 `lib/src/editor/editor_component/service/ime/delta_input_service.dart:137`
**已自带** `bool onFocusReceived() => false;`——无需补丁（上游/镜像版本已含此修复）。

### Flutter 3.41+ 弃用警告（info 级）

集中在 vendored 的 `scrollable_positioned_list`（`cacheExtent` / `translate` 等
新弃用项）。纯 info 级，不影响编译与运行，暂不处理。

## 同步上游的操作指南（git 化）

> ⚠️ **2026-09-17 起本目录不再是 git 仓库** ⇒ 下面这些 `git` 命令**不能就地跑**。
> 先在**临时目录**还原那段历史（`git clone <备份>/vendored-history/appflowy_editor-final.bundle`，
> 见文首「历史在哪 / 怎么还原」），在**那里**做基线/重放，最后把结果**拷回**本目录
> （本目录的文件改动由主仓库跟踪、由主仓库提交）。

> 网络约束：GitHub 直连在本机会超时 → 优先从 pub 镜像缓存取包
> （`%LOCALAPPDATA%\Pub\Cache\hosted\pub.flutter-io.cn\appflowy_editor-<version>`）。

```bash
# 0. 一次性：还原历史到临时目录（只读用途，别在这里长期开发）
git clone "<备份>/vendored-history/appflowy_editor-final.bundle" /tmp/afe
cd /tmp/afe

# 1. 把新版本内容放到一个独立分支，作为新的上游基线（tag 6.3.0 之类）
#    （从 pub 缓存拷入工作区，先删干净旧文件再拷，避免残留）
git checkout -b upstream-next
#    ... 删除工作区旧内容 → 从缓存拷入新版本 → ...
git add -A && git commit -m "upstream: appflowy_editor <version> (pristine, from pub cache)"
git tag <version>

# 2. 把我们的补丁重放到新基线上（会自动三方合并，冲突点=需要人工判断处）
git checkout main
git rebase --onto <version> 6.2.0 main

# 3. 把重放结果拷回 third_party/appflowy_editor，然后在**主仓库根**验证
#    （别在 vendored 目录里单独跑 pub/analyze，见下一节）
flutter pub get && flutter analyze --no-pub && flutter test

# 4. 若某条补丁上游已修 → 在 rebase 时丢弃该提交，并更新本文件的「何时可撤销」
```

**别跟 `main` 分支**：main 无版本号、无 CHANGELOG、随时可能半成品，
跟进它会把"可复现的升级"变成"不可复现的漂移"。要 main 上某个具体修复时，
**cherry-pick 那一个 commit 并在此登记为一条补丁**。

## 怎么检查 vendored 代码（**别在本目录单独跑 pub/analyze**）

**坑（实测）**：在 `third_party/appflowy_editor` 里直接 `flutter pub get` +
`flutter analyze lib`，会得到**与真实构建不符的假报错**：

- 它按**本目录自己的** `pubspec.lock` 解析依赖（实测解到 `file_picker 10.3.10`，
  而我们的补丁代码写的是 12.x API）→ 报
  `The method 'readAsBytes' isn't defined for the type 'PlatformFile'`；
- 它还会去解析 `example/`，而 `example/pubspec.yaml` 含 GitHub 上的 git 依赖
  （`AppFlowy-IO/AppFlowy-plugins`）→ 本机直连超时 → `Failed to update packages`。

正确姿势 = **在仓库根**、用**应用的真实依赖解析**去编译：

```bash
# 仓库根
flutter pub get
flutter test --no-pub            # 测试 import 了 appflowy_editor → 其源码参与编译
flutter analyze --no-pub         # 应用侧静态检查（不含依赖内部）

# 需要更严格（含平台插件、整体编译）时：
flutter build windows --debug
```

本目录的 `.dart_tool/`、`pubspec.lock` 都是上面这些命令的**副产物**，已由
`.gitignore` 挡住，不入库。

## 升级前哨（比盯上游版本号更重要）

真正的隐蔽 breakage 来自 **Flutter 升级**（如 3.44+ 给 `TextInputClient` 加抽象
方法，直接让 vendored 包编译失败），而不是 appflowy 落后。Flutter 每次升级
（尤其 minor+）后，跑上面那组根目录命令（`flutter test` / `build`）。

报错落在 vendored 代码里时，先怀疑"Flutter 加了接口"，而不是"上游写错了"。

## 工作区未提交的补丁（**已入档：2026-09-17**）

这批改动此前一直躺在工作区、未提交。**2026-09-17 已提交归档**：

- 嵌套仓库提交 `0bd3e53`（21 项：补丁 10~15 涉及的文件 + 新增
  `lib/src/flutter/scrollable_positioned_list/src/extent_aware_sliver_delegate.dart`）；
- 随后随"并入主仓库"进入主仓库提交 `cc8a9f8`。

于是足迹指标恢复**完整**可用：`git diff 6.2.0 main` 现在反映的是"补丁 1~15 + 本文件"
的全量足迹（仍要在**还原出的临时仓库**里跑，见文首「历史在哪 / 怎么还原」）。

下面这张表保留作**索引**（哪些文件属于哪些功能），不再表示"未入档"：

| 文件 | 线索 |
|---|---|
| `lib/src/editor/block_component/quote_block_component/quote_block_component.dart` | 引用块（**2026-10-25 已还原官方原版**——主题色迁移为官方 `iconBuilder` 扩展点，见应用侧 `custom_block_components.dart` 的 `_SinanQuoteIcon`，vendored 零改动） |
| `lib/src/editor/find_replace_menu/find_menu_service.dart` | 查找面板（偏移 / 聚焦 / 防抖） |
| `lib/src/editor/find_replace_menu/find_replace_widget.dart` | 同上 |
| `lib/src/editor/toolbar/desktop/items/icon_item_widget.dart` | 工具栏激活底色 |
| `lib/src/infra/flowy_svg.dart` | 图标覆盖色（`iconOverride`） |
| `lib/src/l10n/intl/messages_zh-CN.dart` | 中文本地化（⚠️ 重新生成 l10n 会被覆盖） |

**建议**：把工作区改动整理成一个 `sinan:` 提交并逐条登记，让
`git diff 6.2.0 HEAD` 重新成为可用的足迹指标（现在它只反映补丁 1/2/3）。
