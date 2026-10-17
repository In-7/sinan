import 'dart:async';

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
// 官方 Find&Replace 的面板本体 `FindReplaceMenu` **没在包的公开导出里**
// （barrel `find_and_replace.dart` 只导出了搜索服务；命令与样式
// `findAndReplaceCommands` / `FindReplaceStyle` 倒是公开的）。
// 故只这一处从 src/ 引入——本包是 vendored 的（third_party/appflowy_editor，
// 见其 PATCHES.md），上游改了路径会立刻变成编译错误，不会静默失效。
// ignore: implementation_imports
import 'package:appflowy_editor/src/editor/find_replace_menu/find_menu_service.dart';
// 同上：面板本体 `FindAndReplaceMenuWidget` 也只在 src/ 里（barrel 没导出）。
// ignore: implementation_imports
import 'package:appflowy_editor/src/editor/find_replace_menu/find_replace_widget.dart';
// 官方 material（appflowy 内部那一套）：查找面板的 `TextField` 找的是**官方**
// `Material` 祖先，material_ui 的同名类不算数，见 [_buildFindMenu]。
// ignore: implementation_imports
import 'package:flutter/material.dart' as official;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/note.dart';
import '../domain/settings.dart';
import '../app/providers.dart';
import '../app/save_debounce.dart';
import '../theme/app_float_surface.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../editor/core/block_height_predictor.dart';
import '../editor/core/block_heights.dart';
import '../editor/core/image_metrics.dart';
import '../editor/core/editor_typography.dart';
import '../editor/core/note_document_adapter.dart';
import '../editor/core/note_save.dart';
import '../editor/core/word_count.dart';
import '../editor/core/note_title_field.dart';
import '../editor/blocks/custom_block_components.dart';
import '../editor/blocks/ref_block_component.dart';
import '../editor/blocks/toggle_block_component.dart';
import '../editor/toolbar/fixed_toolbar.dart';
import '../editor/toolbar/link_toolbar_item.dart';
import '../editor/toolbar/slash_menu_items.dart';
import '../editor/panels/backlink_panel.dart';
import '../editor/panels/tags_panel.dart';
import '../editor/panels/toc_panel.dart';
import '../editor/widgets/editor_context_menu.dart';
import '../editor/widgets/link_hover_tooltip.dart';

// **编辑器视图（appflowy_editor）**——迁移 ④ 的落地件，现在是**唯一**的编辑器
// （quill 版 2026-09-10 退役并归档到 `archive/quill/src/notes/`，入口见
// `editor_switch.dart`；档案与恢复步骤见 `docs/editor_migration_spike.md`）。
//
// ## 阶段 1 覆盖
// - 标题 + 正文编辑（官方块组件：段落/标题/列表/待办/引用/图片/分隔线/表格）
// - 我们的增量块：代码块 / 公式 / 附件（见 custom_block_components.dart）
// - 顶部工具栏：官方 ToolbarItem 拼装的**常驻固定条**（fixed_toolbar.dart）
// - 编辑器偏好：正文列宽 / 字号 / 行高接设置面板（与 quill 版同口径——
//   限宽走 `EditorStyle.maxWidth`，官方按块居中、滚动器仍铺满全宽）
// - 自动保存：**写出 v2 块树**（落库格式在此切换）
// - 字数统计 / 修订时间
//
// 官方**悬浮工具栏**已由固定顶部工具栏取代（fixed_toolbar.dart，阶段 2 · 第 1 项）。
//
// ## 排版：**中文黄金排版**（`editor_typography.dart` 单一来源）
// 官方默认是按拉丁文标定的：标题写死 32/28/24、没有字距/回退链概念、
// `EditorStyle.desktop` 的默认颜色硬编码浅色。中文口径由 [EditorTypography]
// 提供（移植 quill 版 `_chineseStyles`：标题 base×1.5/1.25/1.0625·行高 1.4·
// 零字距，正文带 CJK 回退链 + w500 + even 行盒），经两处注入、零补丁：
// `toTextStyleConfiguration`（正文/链接/行内代码）与标题 `textStyleBuilder`。
// **每块的 padding 保持官方默认（上下各 4）**——块间距按官方来。
//
// ## 块间距：**按官方语义**（一个空行 = 一行的高度）
// 空行在块编辑器里就是一个空段落块：行盒 + 官方 `BlockComponentConfiguration`
// 的上下各 4 → 与一行文字等高，**刻意不做任何"压扁 / 折叠"**
// （曾试过两种做法，均撤销：见 `docs/editor_migration_spike.md` 的「已否决方案」）。
// ⚠️ `EditorStyle.padding` 是**按块**生效的（官方 `page_block_component.dart`
// 的 itemBuilder 把它包在**每个块**外面），竖直值会加在每个块上——见
// `EditorTypography.blockPadding`。实际踩过：把 quill 的"底部留白 96"搬过来，
// 每个块多出 100px，看着像"行距是正常的 4 倍"。
//
// ## 阶段 2（编辑器体验补齐，按"手感影响"排序）
// - [x] 固定顶部工具栏（官方 ToolbarItem 常驻拼接 + 打开即落光标）
// - [x] 目录面板（toc_panel.dart：EditorState 取标题 + visibleRangeNotifier
//       跟随滚动；跳转时压住官方"自动滚回光标"；激活项自动进面板可视区；
//       末尾留白取代了 quill 的「点击固定 / 到底兜底」两条补偿规则）
// - [x] 编辑器内搜索（**官方 Find&Replace**：ctrl+F 查找 / ctrl+H 替换，
//       面板与匹配高亮都用官方的；工具栏只加一个入口按钮）
// - [ ] 粘贴图片本地化（现有 _onClipboardPaste 是 quill 管线）
// - [x] 右键菜单（2026-09-15：`contextMenuBuilder` 此前**没接** ⇒ 右键毫无反应；
//       现为自建面板：剪切/复制/粘贴/全选，走浮层令牌、条目直接调官方命令
//       handler；页面末尾留白另有一份同款菜单，见
//       `widgets/editor_context_menu.dart`）
// - [x] 链接悬浮提示（2026-09-15：官方只有"点击 → 编辑菜单 / Ctrl+点击 →
//       打开"，没有悬浮；现为自研——停在链接上浮出 URL + 打开/复制，见
//       `widgets/link_hover_tooltip.dart`。拖选自动滚动官方已自带）
//
// ## 落库格式是**单向**的
// 本视图保存时走 NoteDocumentAdapter.storedContentFromDocument → **块树**。
// quill 视图已退役（2026-09-10 归档），所以"切回去编辑"这条路不存在了；
// 但要清楚**不可逆**：存量 Delta 笔记被本视图编辑保存过一次之后就是块树，
// 归档的 quill 视图即便搬回来也只能降级显示纯文本。
class NoteEditorViewAppFlowy extends ConsumerStatefulWidget {
  const NoteEditorViewAppFlowy({super.key, required this.noteId});

  final String noteId;

  @override
  ConsumerState<NoteEditorViewAppFlowy> createState() =>
      _NoteEditorViewAppFlowyState();
}

class _NoteEditorViewAppFlowyState
    extends ConsumerState<NoteEditorViewAppFlowy> {
  late final EditorState _editor;
  late final EditorScrollController _scroll;
  final TextEditingController _titleController = TextEditingController();
  final ValueNotifier<int> _wordCount = ValueNotifier<int>(0);

  /// 撤销 / 重做按钮的可用态（历史栈非空）。
  ///
  /// 为什么要这两个 notifier：`undoManager` 的栈**不是** [Listenable]（普通
  /// 类），而视图**不在每次事务时重建**（`_onContentChanged` 只动 `_wordCount`）
  /// ⇒ 可用态没有别的来源。它们在事务流里同步（[_syncHistoryAvailability]），
  /// 且只在**翻转时**通知（打字每键一次通知会白白重建标题行）。
  final ValueNotifier<bool> _canUndo = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _canRedo = ValueNotifier<bool>(false);

  /// 合并成一个 [Listenable] 供标题行覆盖层用（别每帧新建 merge）。
  late final Listenable _historyAvailability = Listenable.merge(<Listenable>[
    _canUndo,
    _canRedo,
  ]);

  StreamSubscription<EditorTransactionValue>? _changesSub;

  /// 跳转请求的订阅（见 [_maybeConsumeLocate]）。
  ProviderSubscription<LocateRequest?>? _locateSub;

  /// 正文 / 标题的落盘调度：**带上限**的防抖（见 [SaveDebounce]）。
  ///
  /// 纯防抖在连续输入下会**一直不落盘**（每次事务都重置计时器 ⇒ "停顿"永不成立），
  /// 加上 [kSaveMaxWait] 后才把"异常退出最多丢多少"变成一个**硬上界**。
  late final SaveDebounce _contentSave = SaveDebounce(
    window: _savePolicy.debounce,
    maxWait: kSaveMaxWait,
    onFlush: _flushContent,
  );

  /// 标题落盘：回调里**现读控制器**（不闭包捕获旧值），与 dispose 的兜底落盘同一口径。
  late final SaveDebounce _titleSave = SaveDebounce(
    window: _savePolicy.debounce,
    maxWait: kSaveMaxWait,
    onFlush: () => unawaited(_writeTitle()),
  );

  /// 退出前落盘的注销句柄（见 [PendingSaves]）：[dispose] 里必须注销，否则已销毁的
  /// 编辑器仍会在关窗口时被落盘。
  late final void Function() _exitFlush;

  /// 装载完成前**绝不保存**（否则空文档会盖掉真实内容）。
  bool _loaded = false;

  /// 目录面板开关（**按钮点击 / 快捷键 Ctrl+Shift+O** 切换；窗口放不下三栏时
  /// 仅隐藏、不重置）。
  ///
  /// 它是**悬浮气泡**语义：打开即常显（不随鼠标移开收起），点气泡外或再点按钮收起。
  ///
  /// ⚠️ 2026-09-23 用户定案：**取消"鼠标划过临时弹出"**，只留点击。理由：悬停弹层
  /// 会让人"没打算开也被弹一脸"，而目录是要细看的内容（不是扫读时的伴随物）。
  /// 顺带把一整套悬停防抖（两个计时器）+ 全局指针兜底路由都删了，交互与反链按钮
  /// 就此统一（那个一直是纯点击）。
  bool _tocVisible = false;

  /// 悬浮目录气泡的显示控制器（`OverlayPortal`）。
  ///
  /// 用官方 3.47 推荐的 `OverlayPortal.overlayChildLayoutBuilder` 取代原来的
  /// `CompositedTransformTarget` + `LayerLink` + `OverlayEntry`：不再需要锚点
  /// 和手写 OverlayEntry，气泡自动跟随按钮（按钮移动/窗口缩放都不用重算），
  /// 且隐藏时它的 RenderObject 会移出树、不参与 layout/paint。
  final OverlayPortalController _tocController = OverlayPortalController();

  /// 目录按钮的 key（挂在 `_EarButton` 上）：气泡用它取屏幕坐标来定位。
  final GlobalKey _tocButtonKey = GlobalKey();

  /// 「按钮 + 气泡」共用的 TapRegion 组：点击组外任意处 = 收起
  /// （浮层惯例"点外部即关"）。同组是为了**排除按钮自己**——否则点按钮关闭时，
  /// down 先触发组外回调收起、up 的 onPressed 又把它打开，永远关不掉。
  final Object _tocTapGroupId = Object();

  /// 反链面板开关（**第三个耳**）。
  ///
  /// 与目录气泡不同，它是**点击才开、没有悬停临时显示**：反链是"专门去查"的
  /// 信息，不是扫读时的伴随物，为它再养一套悬停防抖（三个计时器 + 全局指针
  /// 路由）不划算。
  bool _backlinkVisible = false;

  /// 反链气泡的显示控制器（`OverlayPortal`），理由同 [_tocController]。
  final OverlayPortalController _backlinkController = OverlayPortalController();

  /// 反链按钮的 key：气泡用它取屏幕坐标来定位。
  final GlobalKey _backlinkButtonKey = GlobalKey();

  /// 标签面板开关（**第四只耳**，2026-09-26）：打标签是"专门去整理"的动作，
  /// 与反链同一交互——点击开合、点外部收起，不做悬停触发（同上理由）。
  bool _tagsVisible = false;

  /// 标签气泡的显示控制器（`OverlayPortal`），理由同 [_tocController]。
  final OverlayPortalController _tagsController = OverlayPortalController();

  /// 标签按钮的 key：气泡用它取屏幕坐标来定位。
  final GlobalKey _tagsButtonKey = GlobalKey();

  /// 「按钮 + 标签气泡」共用的 TapRegion 组（理由同 [_backlinkTapGroupId]）。
  final Object _tagsTapGroupId = Object();

  /// 「按钮 + 气泡」共用的 TapRegion 组（理由同 [_tocTapGroupId]）。
  final Object _backlinkTapGroupId = Object();

  /// 引用块标题的刷新信号：笔记列表一变就 +1（改名 / 删除 / 新建都算）。
  ///
  /// 引用块里存的是 **id**，标题是**查出来的** —— 别处改了名，块里那份就得跟着
  /// 变。用 `ref.listen` 而非 `watch` 去驱动：整页重建只为几个引用块不值得
  /// （同下方标题同步那条注释）。
  final ValueNotifier<int> _refsRevision = ValueNotifier<int>(0);

  /// 引用块与宿主之间的接缝（解析目标标题 / 跳转），在 [initState] 装配。
  ///
  /// 块组件不碰 provider：解析与导航都由这一层注入 —— 与 `MediaResolver` /
  /// `EditorTypography` 同一条路子（见 `ref_block_component.dart`）。
  late final RefBlockBridge _refBridge;

  /// 标题行的定位锚点：查找面板要贴在它下方（见 [_showFind]）。
  final GlobalKey _titleRowKey = GlobalKey();

  /// 目录跳转后**短暂高亮**的落点块（node id；null = 当前没有）。
  ///
  /// 为什么需要：末尾留白是一屏（官方口径 600）时，**仍差一点点**才够让末尾
  /// 标题停到视口顶部（视口高 ≈690 − 末块高 ≈80 > 600）；另外目标块本来就在
  /// 视口里时跳转**有意不动**（见 `tocJumpCanReachTop`）。两种情况都靠高亮补
  /// "我落在哪"。
  ///
  /// 用 `ValueNotifier` + 官方逐块的口子（`AppFlowyEditor.blockWrapper`）实现：
  /// **纯渲染层**——不改文档、不进撤销栈、也不动选区（动选区的话，随手敲一个
  /// 键就会把整个标题覆盖掉）。
  final ValueNotifier<String?> _flashedNodeId = ValueNotifier<String?>(null);
  Timer? _flashTimer;

  /// **块高表**：实测高度 + 按块类型的默认估计（见 `block_heights.dart`）。
  ///
  /// 用途：把「块」换算成「像素」（目录跳转 / 当前章节 / 落点）。当前滚动器仍是
  /// 官方的锚点制 `ScrollablePositionedList`，表先按实测填起来（**零行为变化**），
  /// 换成普通 `ListView` 时即可直接使用。
  final BlockHeights _blockHeights = BlockHeights();

  /// 排版参数指纹（列宽 / 字号 / 行高 / 系统文字缩放 / **内容列有效宽度**）。
  ///
  /// 这些一变，**所有块高作废**——表是像素换算的输入，留着旧值会让换算长期偏。
  /// 统一在一处判变（[_syncBlockHeights]），比在设置面板各处埋 `clear()` 更难漏。
  String? _layoutFingerprint;

  /// **滚动器的逐 item 高度**（px；索引 = 滚动列表的 item index，含末尾留白）。
  ///
  /// 这是 vendored 补丁 `itemExtentOf` 的输入（见 `third_party/appflowy_editor/
  /// PATCHES.md` 的「补丁 10」）。**为什么值得**：官方列表对没构建过的块一律按
  /// 「已布局块的**平均**高度 × 剩余块数」外推 —— 局部平均 ≠ 全篇平均时（三行
  /// 标题 / 图片 / 代码块扎堆）总高被抬高，锚点制的内容就整体位移一次（手感
  /// "滚到中间像加速了一下"）；滚到末尾外推项消失 ⇒ 滚动条滑块变长。把逐块
  /// 高度喂进去，总高从第一帧起就是**精确**的。
  ///
  /// 维护策略（**不能整体重建**：`TextPainter` 预算 300 块 ≈ 7ms）：
  /// - 文档**结构**变了（增删 / 重排块、换笔记）或排版参数变了 ⇒ 整体重建；
  /// - 某块**被实测** ⇒ 只改那一项（O(1)，见 [_onBlockMeasured]）。
  List<double> _itemExtents = <double>[];

  /// 块 id → 它在 [_itemExtents] 里的下标（增量更新用）。
  Map<String, int> _itemIndexOf = const <String, int>{};

  /// 图片宽高比缓存（`blocks/image_metrics.dart`）。
  ///
  /// 预算器要它才能在图片块**被构建之前**算出真实高度——否则"没存尺寸的图片"
  /// 解码完成时块高会变，滚动总高跟着变一次（就是要消掉的那个现象）。
  final ImageAspectRatios _imageRatios = ImageAspectRatios();

  /// 逐 item 高度表的"代数"：每次重建 +1。异步回包（图片比例解析）靠它判断
  /// "这批值是不是已经过期"，避免用旧排版参数写回表里。
  int _extentsGeneration = 0;

  /// 文档结构指纹（块个数 + 逐个 id 的滚动哈希）：变了说明结构变了。
  ///
  /// 只做 O(N) 的整数运算，不碰任何高度计算 ⇒ 可以每次 build 都算（实测
  /// 300 块约十几微秒），从而不必依赖事务流的粒度。
  int? _structureHash;

  /// 交给滚动器的取值口子（读的是字段，不捕获旧值 ⇒ 列表换掉也能看到）。
  ///
  /// 越界 / 未知返回 `null` ⇒ 那段 sliver 退回官方外推（宁可少赚，不给错值）。
  double? _itemExtentAt(int index) {
    final List<double> extents = _itemExtents;
    return index >= 0 && index < extents.length ? extents[index] : null;
  }

  /// 高亮的淡入/淡出时长（两端各自的时间）。
  static const Duration _flashFade = Duration(milliseconds: 220);

  /// 高亮**总时长**：淡入 → 保持 → 淡出。太短看不见，太长像"选中态"。
  static const Duration _flashHold = Duration(milliseconds: 900);

  /// 笔记 notifier：**在 initState 存成字段**，供 [dispose] 兜底落盘使用。
  ///
  /// dispose 里**不能**用 `ref`：那时 widget 已 deactivate，而 `ref` 依赖
  /// BuildContext，Riverpod 会抛
  /// `Bad state: Using "ref" when a widget is about to or has been unmounted
  /// is unsafe`。而 dispose 恰恰是兜底落盘的位置（最后一次编辑通常还挂在
  /// 防抖计时器里）。quill 版一直这么存（它的 `_notifier` 字段），
  /// appflowy 版漏了——实测切笔记/关窗口必炸。
  late final NotesNotifier _notes;

  /// 落盘策略（防抖窗口 + isolate 编码阈值）：与 UI 无关的规则，
  /// 见 [NoteSavePolicy]（抽离原因同 [countWords]）。
  static const NoteSavePolicy _savePolicy = NoteSavePolicy();

  /// 落盘编排（读 Document → 抽纯文本 → 编码 → 写库）。
  late final NoteSaver _noteSaver;

  /// 查找面板样式。
  ///
  /// ⚠️ `FindReplaceStyle` 的两个高亮颜色字段**只对旧版 SearchService 生效**，
  /// V3（当前在用）不读——V3 的"命中高亮"是把编辑器选区移到命中处，颜色走
  /// `editorStyle.selectionColor`（已改主题色，见 build 里 editorStyle 的注释）。
  /// 那两个颜色保持默认即可。
  ///
  /// [FindReplaceStyle.findMenuBuilder] 是**面板表面**的入口（2026-09-14）：官方
  /// 默认面板的底色是 `editorStyle.selectionColor`（= 我们的选区色，主题色
  /// 30/40% 半透明）⇒ 一块半透明主题色面板，与其它浮层不是一路。这里**零
  /// vendored 改动**地换成统一浮层表面，见 [_buildFindMenu]。
  static final FindReplaceStyle _findStyle = FindReplaceStyle(
    findMenuBuilder: _buildFindMenu,
  );

  /// 查找面板的浮层表面（L2）：内容仍是官方 [FindAndReplaceMenuWidget]，
  /// **行为逐字不变**，只把外壳从"半透明选区色 Material"换成 [AppFloatSurface]。
  ///
  /// 官方 `FindReplaceMenu` 用 `style.findMenuBuilder?.call(...) ?? Material(...)`
  /// 选择外壳，所以这是官方留给宿主的正式口子（不是 hack）。
  ///
  /// ⚠️ 必须用 **official 前缀**的框架组件（Actions / Material）：面板内容来自
  /// vendored appflowy，它 import 的是 `package:flutter/material.dart`，其
  /// EditableText 的快捷键分发找的是**框架**的 Actions；material_ui 那套同名类
  /// 是另一份 Type，接不住（TextField 的 Material 祖先问题同理，见下）。
  ///
  /// ## Esc 关闭（2026-10-01 实测补丁，应用侧）
  /// 官方面板里查找 / 替换两个 TextField 的默认快捷键把 Esc 映射成
  /// `DismissIntent`，但**官方没在任何祖先处挂这个 Intent 的 Action** ⇒
  /// Esc 既关不掉面板，debug 下还直接抛
  /// "Unable to find an action for an Intent with type DismissIntent"
  /// （与我们自己 Ctrl+K 浮层曾踩的坑同源）。在这里接住它：Esc 走与关闭钮
  /// **同一个** `onDismiss`，和命令面板 / 搜索浮层的全局约定一致。
  ///
  /// ⚠️ `showRegexButton` / `showCaseSensitiveButton` 与官方默认**保持一致**
  /// （都是 true）——不传就等于悄悄去掉正则/大小写两个按钮。
  static Widget _buildFindMenu(
    BuildContext context,
    EditorState editorState,
    FindReplaceLocalizations? localizations,
    FindReplaceStyle style,
    bool showReplaceMenu,
    VoidCallback onDismiss,
  ) => AppFloatSurface(
    child: official.Actions(
      actions: <Type, official.Action<official.Intent>>{
        official.DismissIntent: official.CallbackAction<official.DismissIntent>(
          onInvoke: (official.DismissIntent _) {
            onDismiss();
            return null;
          },
        ),
      },
      child: official.Material(
        // ⚠️ 必须是**官方 material** 的 `Material`（所以带 `official.` 前缀）：
        // 面板内容 `FindAndReplaceMenuWidget` 来自 vendored appflowy，内部 import
        // 的是 `package:flutter/material.dart` ⇒ 它的 `TextField` 找**官方**
        // `Material` 祖先；`AppFloatSurface` 里那层是 material_ui 的同名类，
        // 在这条查找链上**不算数**（官方默认面板正是为此自己包了一层官方
        // Material，见 `find_menu_service.dart` 的 `?? Material(...)`）。
        // 这里只要"祖先"这层语义，视觉仍是外层 AppFloatSurface 的浮层三件套。
        type: official.MaterialType.transparency,
        child: FindAndReplaceMenuWidget(
          onDismiss: onDismiss,
          editorState: editorState,
          showReplaceMenu: showReplaceMenu,
          localizations: localizations,
          style: style,
        ),
      ),
    ),
  );

  /// 固定工具栏的静态条目段（全局常量，不依赖任何视图状态）。
  static final List<ToolbarItem> _staticToolbarItems = sinanFixedToolbarItems();

  @override
  void initState() {
    super.initState();

    // 注意：appflowy 的 `EditorState.document` 是 **final**，构造后不能替换
    // （quill 可以）。所以必须在构造前把内容读出来——笔记列表在进入本视图前
    // 必然已加载（用户是从列表里点进来的），因此这里同步取。
    //
    // 正文按 id 从存储**单行**取（SELECT ... WHERE id）：列表快照不带
    // content 大字段（见 NoteStore.allNotes），不能从这里拿正文。
    final Note? note = _findNote();
    final String? content = ref
        .read(noteStoreProvider)
        .noteById(widget.noteId)
        ?.content;

    _editor = EditorState(
      document: NoteDocumentAdapter.documentFromStoredContent(content),
    );
    _scroll = EditorScrollController(editorState: _editor);
    _placeInitialCursor();
    // 跳转请求（`locateProvider`，§4）：本视图按 `ValueKey(noteId)` 重建 ⇒ 切到
    // 目标笔记时这里是**新 State**，所以 initState 就能消费请求（见
    // `LocateNotifier` 的说明）。
    _locateSub = ref.listenManual(
      locateProvider,
      (LocateRequest? _, LocateRequest? _) => _maybeConsumeLocate(),
    );
    _maybeConsumeLocate();
    // 事务流同时驱动两件事：防抖落盘、以及撤销/重做按钮的可用态
    // （撤销本身也走 `apply` ⇒ 这个流同样会响，见官方 `UndoManager.undo`）。
    _changesSub = _editor.transactionStream.listen((_) {
      _onContentChanged();
      // ⚠️ **必须延到微任务**：官方 `applyTransaction` 里事务流是**先广播、
      // 后记录历史**的（`_recordRedoOrUndo` 在两处 `_observer.add` 之后），
      // 当场读栈会读到"这一步还没进去"⇒ 按钮永远慢一步。
      scheduleMicrotask(() {
        // 卸载后微任务仍可能跑：写已 dispose 的 notifier 会抛。
        if (!mounted) return;
        _syncHistoryAvailability();
      });
    });
    _syncHistoryAvailability();

    _titleController.text = note?.title ?? '';
    // 字数直接从刚建好的内存 Document 抽取——同一份 JSON 不解析第二遍
    // （此前打开笔记瞬间要连续两次全量解析，切笔记的第一帧因此掉帧）。
    _wordCount.value = countWords(
      NoteDocumentAdapter.plainTextFromDocument(_editor.document),
    );
    _loaded = note != null;
    _notes = ref.read(notesProvider.notifier);
    // 写入者绑定到本笔记的 id（编排本身在 [NoteSaver]，与 UI 无关）。
    _noteSaver = NoteSaver(
      save: (String content, {required String plainText}) =>
          _notes.saveContent(widget.noteId, content, plainText: plainText),
    );
    // 登记"关窗口时把防抖里还没写下去的编辑写完"（见 [PendingSaves]）。
    _exitFlush = ref.read(pendingSavesProvider).register(_flushForExit);

    // 双链：引用块的目标标题 / 跳转由宿主注入（块本身不碰 provider）。
    _refBridge = RefBlockBridge(
      resolve: _resolveRefTarget,
      open: _openRefTarget,
      // 嵌入（`ref_view='embed'`）的内容同样是宿主取：块组件不碰 provider。
      preview: (String refType, String refId) =>
          ref.read(noteStoreProvider).embedPreview(refType, refId),
      revision: _refsRevision,
    );
  }

  /// 打开笔记即落光标（Word/Notion 同款）。
  ///
  /// 落在第一个**文本块**行首：图片/分隔线这类块没有 delta，跳过——
  /// 给它们设 offset 0 的光标没有意义。顺带让固定工具栏的条目（可用性
  /// 依赖"有选区"）一开始就是可用态，而不是一屏灰按钮。
  void _placeInitialCursor() {
    for (final Node node in _editor.document.root.children) {
      if (node.delta == null) continue;
      _editor.selection = Selection.collapsed(Position(path: node.path));
      return;
    }
  }

  // 页面留白的右键菜单：2026-09-16 起**不再自建**，统一走官方链路
  // （`desktop_selection_service._onSecondaryTapDown` → `_showContextMenu`；
  // sinan 补丁 16 已让它对非文本块 / 空白 / 无选区都能弹）。此前视图侧另挂
  // 一份 OverlayEntry 菜单，与官方路径叠加成"页面底部两个菜单"，故移除。

  /// 点末尾留白 = **继续写**（官方 `_focusOnLastEmptyParagraph` 同款）。
  ///
  /// 留白属于"页面"（Word / 苹果备忘录 / 飞书都这样），点它没反应会让人以为
  /// 编辑器坏了——quill 版当年就有"点击定位到文末"。官方 app 的做法一致：
  /// 末尾已经是空段落 ⇒ 光标进它；否则**在末尾补一个空段落**再把光标放进去。
  ///
  /// 焦点不必手动要：官方的键盘服务在**选区变化**时会 `focusNode.requestFocus()`
  /// （vendored `keyboard_service_widget.dart` 的选区监听），所以设完选区就能直接打字。
  void _focusEndOfDocument() {
    final List<Node> children = _editor.document.root.children;
    final Node? last = children.isEmpty ? null : children.last;
    final Transaction transaction = _editor.transaction;
    // ⚠️ 判"空段落"用**纯文本 trim 后为空**，而不是官方的 `delta?.isEmpty`：
    // 空段落的 delta 里仍有一个 `\n`，`isEmpty` 的语义取决于 Delta 实现
    // （是否把单个换行视为空），不赌它——按可见文本判最稳。
    if (last != null &&
        last.type == ParagraphBlockKeys.type &&
        (last.delta?.toPlainText().trim().isEmpty ?? true)) {
      transaction.afterSelection = Selection.collapsed(
        Position(path: last.path),
      );
    } else {
      final int index = children.length;
      transaction.insertNode(<int>[index], paragraphNode());
      transaction.afterSelection = Selection.collapsed(
        Position(path: <int>[index]),
      );
    }
    unawaited(_editor.apply(transaction));
  }

  /// 打开官方查找面板（搜索耳与 Ctrl+F 走**同一实现**，行为天然一致）。
  ///
  /// **耳朵永远可点**（2026-09-12）：官方 `FindReplaceMenu.show()` 在
  /// "没有选区矩形"时静默返回（面板需要选区锚定位置）——从未点进正文、
  /// 点过外部、或清空过搜索词都会落到这个分支，表现为"点了没反应"。
  /// 这里检测到没有光标就先落到第一个文本块（[_placeInitialCursor]，与
  /// 打开笔记同款），语义变为"从头开始搜这篇"。落光标后选区矩形要等
  /// 一帧才可用，故延迟到帧末再开面板。
  void _showFind() {
    if (_editor.selection == null ||
        _editor.service.selectionService.selectionRects.isEmpty) {
      _placeInitialCursor();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openFindPanel();
      });
      return;
    }
    _openFindPanel();
  }

  /// 开面板本体：位置用标题行的 GlobalKey 实测底部（随字号/文本缩放
  /// 联动），再留 8px 间距传给补丁 7a 的可配置偏移，避免面板压住标题。
  void _openFindPanel() {
    // 兜底：标题栏 32 + 按钮带 + 标题行 ~52（实测失败时用）。
    double topOffset = 84 + _kHeaderBandHeight;
    final RenderBox? titleBox =
        _titleRowKey.currentContext?.findRenderObject() as RenderBox?;
    if (titleBox != null && titleBox.hasSize) {
      topOffset =
          titleBox.localToGlobal(Offset.zero).dy +
          titleBox.size.height +
          Tokens.spaceSm;
    }
    FindReplaceMenu(
      context: context,
      editorState: _editor,
      showReplaceMenu: false,
      style: _findStyle,
      topOffset: topOffset,
      rightOffset: Tokens.spaceLg,
    ).show();
  }

  @override
  void dispose() {
    _locateSub?.close();
    // 先注销退出前落盘：本视图即将消失，退出口径不该再找它（见 [PendingSaves]）。
    _exitFlush();
    // 关闭/切换前兜底落盘，但**只在有未写库的编辑时**（与 quill 版同节奏）：
    // 判据是 `SaveDebounce.pending`（有未落盘的变更），不再是"计时器是否为 null"。
    //
    // 不能无条件 flush——那会让"打开看一眼就关闭"也重写一遍内容：存量
    // Delta 笔记会被改写成块树，而 Delta 读入路径仍有有损项（对齐/缩进），
    // 等于白丢信息，且用户什么都没做。
    final bool pendingContent = _contentSave.pending;
    final bool pendingTitle = _titleSave.pending;
    _contentSave.cancel();
    _titleSave.cancel();
    if (_loaded) {
      if (pendingContent) _flushContent();
      if (pendingTitle) {
        unawaited(
          _notes.saveTitle(widget.noteId, _titleController.text.trim()),
        );
      }
    }
    unawaited(_changesSub?.cancel());
    _scroll.dispose();
    _editor.dispose();
    _titleController.dispose();
    _wordCount.dispose();
    _canUndo.dispose();
    _canRedo.dispose();
    _flashTimer?.cancel();
    _flashedNodeId.dispose();
    _refsRevision.dispose();
    _blockHeights.dispose();
    super.dispose();
  }

  Note? _findNote() {
    final List<Note>? notes = ref.read(notesProvider).value;
    if (notes == null) return null;
    for (final Note n in notes) {
      if (n.id == widget.noteId) return n;
    }
    return null;
  }

  /// 目录跳转落地：让正文里那一块闪一下（见 [_flashedNodeId]）。
  void _flashNode(String nodeId) {
    _flashTimer?.cancel();
    _flashedNodeId.value = nodeId;
    _flashTimer = Timer(_flashHold, () {
      if (mounted) _flashedNodeId.value = null;
    });
  }

  // == 跨笔记跳块（问答角标 → 原文）============================================
  // 通道是 `locateProvider`（§4）：调用方只写"想跳到哪里"，由本视图在自身就绪
  // 时消费（消费即置空，避免重开笔记时重复跳）。

  /// 有跳转请求、且是**本笔记**的就立即消费（先置空再跳，防重复触发）。
  ///
  /// 三种触发时机都要覆盖：新 State 的 initState（切笔记进来）、listener
  /// （笔记已打开时点角标）、以及列表尚未挂载时的重试（见 [_jumpToBlockRetrying]）。
  void _maybeConsumeLocate() {
    final LocateRequest? req = ref.read(locateProvider);
    if (req == null || req.noteId != widget.noteId) return;
    // ⚠️ 消费与跳转都**延到帧后**：本方法会在 initState（构建期间）被调，
    // 而构建期间改 provider 状态会撞 Riverpod 的断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(locateProvider.notifier).consume();
      final String? blockId = req.blockId;
      if (blockId != null) _jumpToBlockRetrying(blockId);
      // 焦点只有请求方明确要才交出去：从列表点开一篇时抢焦点，键盘上下选笔记就断了。
      if (req.focus) _focusAt(blockId);
    });
  }

  /// 把光标落到 [blockId]（null ⇒ 首个文本块），顺带让编辑器拿到键盘焦点。
  ///
  /// 为什么"设选区"就等于"聚焦"：vendored 的键盘服务在**选区变化**时会
  /// `focusNode.requestFocus()`（见 [_focusEndOfDocument] 的说明）。
  /// 目标不是文本块（图片 / 分隔线 / 已不存在）时退回 [_placeInitialCursor]——
  /// 给没有 delta 的块硬塞一个 offset 0 的光标没有意义。
  void _focusAt(String? blockId) {
    final Node? node = blockId == null ? null : _nodeById(blockId);
    if (node != null && node.delta != null) {
      _editor.selection = Selection.collapsed(Position(path: node.path));
      return;
    }
    _placeInitialCursor();
  }

  /// 按 id 找节点（含嵌套子树——目标可能在列表 / 引用 / 折叠块内部）。
  Node? _nodeById(String blockId) {
    for (final Node top in _editor.document.root.children) {
      final Node? hit = _findIn(top, blockId);
      if (hit != null) return hit;
    }
    return null;
  }

  static Node? _findIn(Node node, String blockId) {
    if (node.id == blockId) return node;
    for (final Node child in node.children) {
      final Node? hit = _findIn(child, blockId);
      if (hit != null) return hit;
    }
    return null;
  }

  /// 等到列表挂上再跳（刚切笔记的那一两帧里 `itemScrollController` 还没 attach）。
  void _jumpToBlockRetrying(String blockId, {int attempts = 0}) {
    final items = _scroll.itemScrollController;
    if (!items.isAttached || _editor.document.root.children.isEmpty) {
      if (attempts < 10) {
        Timer(const Duration(milliseconds: 120), () {
          if (mounted) _jumpToBlockRetrying(blockId, attempts: attempts + 1);
        });
      }
      return;
    }
    _jumpToBlock(blockId);
  }

  /// 瞬时定位 + 闪烁高亮。
  ///
  /// 与目录跳转同一套手法（`toc_panel.dart` 的 `_jump` 有完整推演）：先压住官方
  /// 的"自动滚回光标"（`disableAutoScroll`，两帧后恢复——它是 post-frame 发起的），
  /// 且必须用 `jumpTo`（瞬时、单列表）：动画版会起第二个列表把同一批 item 建两遍，
  /// 撞出重复 GlobalKey。这里不做目录那套"目标已在视口但够不到顶部"的细节判断
  /// （那段逻辑与目录的激活态耦合）。
  void _jumpToBlock(String blockId) {
    final int? index = _topLevelIndexOf(blockId);
    if (index == null) return;
    final bool previousDisableAutoScroll = _editor.disableAutoScroll;
    _editor.disableAutoScroll = true;
    _scroll.itemScrollController.jumpTo(index: index);
    _flashNode(blockId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editor.disableAutoScroll = previousDisableAutoScroll;
      });
    });
  }

  /// blockId → **顶层块索引**（列表 item 索引）。目标可能在嵌套子树里
  /// （列表 / 引用 / 折叠块内部），故找它所属的顶层祖先。
  int? _topLevelIndexOf(String blockId) {
    final List<Node> top = _editor.document.root.children;
    for (int i = 0; i < top.length; i++) {
      if (_subtreeContains(top[i], blockId)) return i;
    }
    return null;
  }

  static bool _subtreeContains(Node node, String blockId) {
    if (node.id == blockId) return true;
    for (final Node child in node.children) {
      if (_subtreeContains(child, blockId)) return true;
    }
    return false;
  }

  // == 悬浮目录气泡 ==========================================================
  // 取代原左侧推挤式目录面板：**点**标题行的目录按钮（或 Ctrl+Shift+O）弹出，
  // 再点按钮 / 快捷键 / 气泡外收起（不做悬停触发，理由见 [_tocVisible]）。
  // 气泡走 [AppFloatSurface]（浮层三件套），内容直接复用 [AppFlowyTocPanel]；
  // 面板高度完全跟随目录内容自适应（无内部滚动），这里只用 ConstrainedBox
  // 限制不超过屏幕剩余高度。

  /// 开合切换（按钮点击 / 键盘 Ctrl+Shift+O）。
  void _toggleToc() {
    setState(() => _tocVisible = !_tocVisible);
    if (_tocVisible) {
      _tocShowNow();
    } else {
      _tocHideNow();
    }
  }

  /// 立即弹出气泡（`OverlayPortal` 已挂好，这里只切显示态）。
  void _tocShowNow() {
    if (!_tocController.isShowing) _tocController.show();
  }

  /// 立即收起气泡。
  void _tocHideNow() {
    if (_tocController.isShowing) _tocController.hide();
  }

  /// 点击「按钮 + 气泡」之外任意处：收起（浮层惯例"点外部即关"）。
  void _tocUnpinAndHide() {
    if (_tocVisible) setState(() => _tocVisible = false);
    _tocHideNow();
  }

  /// 悬浮目录气泡：跟随目录按钮**右对齐**落下（Notion 同款）。高度完全跟随
  /// 目录内容自适应（面板已去掉内部滚动）。
  ///
  /// 由 `OverlayPortal` 调用：[info] 直接给出按钮在 Overlay 坐标系里的尺寸与
  /// 位置变换、以及 Overlay 自身尺寸，不必再自己 `MediaQuery` / 反查 context。
  Widget _tocPopover(BuildContext context, OverlayChildLayoutInfo info) {
    final Size screen = info.overlaySize;
    final RenderBox? box =
        _tocButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final Offset origin = box == null
        ? const Offset(0, 48)
        : box.localToGlobal(Offset.zero);
    // 与按钮底边**直接相接**（无缝隙）：消除「按钮↔气泡」之间的悬停死区，
    // 鼠标在两者之间移动不会经过既非按钮也非气泡的空白，避免误关 / onExit 漏触发。
    final double top = box == null ? 56 : origin.dy + box.size.height;
    final double right = box == null
        ? 16
        : screen.width - (origin.dx + box.size.width);
    // 面板**不滚动**、高度完全跟随内容：上限给到屏幕剩余可视高度（按钮底边到
    // 屏底），既不溢出屏幕、又尽量贴近内容；仅当标题多到一屏放不下时才会触底裁切。
    final double available = screen.height - top - 16;
    final double maxH = available.clamp(160, double.infinity);
    return Positioned(
      top: top,
      right: right,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: maxH,
          maxWidth: AppFlowyTocPanel.width,
        ),
        child: TapRegion(
          // 点气泡外（含正文）= 关闭；按钮与气泡同组，互相不算"外"。
          groupId: _tocTapGroupId,
          onTapOutside: (_) => _tocUnpinAndHide(),
          child: AppFloatSurface(
            width: AppFlowyTocPanel.width,
            padding: EdgeInsets.zero,
            // visible: true —— 气泡挂载期间必可见，无需冻结优化（卸载即不重建）。
            child: AppFlowyTocPanel(
              editorState: _editor,
              scrollController: _scroll,
              titleListenable: _titleController,
              onJumpedToNode: _flashNode,
            ),
          ),
        ),
      ),
    );
  }

  // == 反链气泡 ==============================================================
  // 第三个耳：**点击开关**（不做悬停临时显示，理由见 [_backlinkVisible]）。
  // 面板本体是 `BacklinkPanel`（自己 watch 列表、自己查库），这里只管浮层的
  // 定位 / 开关 / 点外部收起 —— 与目录气泡同一套浮层三件套。

  void _toggleBacklink() {
    final bool next = !_backlinkVisible;
    setState(() => _backlinkVisible = next);
    if (next) {
      _refsRevision.value++; // 打开即重算一次（可能刚从别处引用过来）
      if (!_backlinkController.isShowing) _backlinkController.show();
    } else {
      _closeBacklink();
    }
  }

  void _closeBacklink() {
    if (_backlinkVisible) setState(() => _backlinkVisible = false);
    if (_backlinkController.isShowing) _backlinkController.hide();
  }

  /// 点反链条目 → 打开来源笔记。
  ///
  /// 顺手关掉面板是刻意的：跳走之后它悬在原处没有意义（下次打开会重算）。
  void _openBacklink(String noteId) {
    _closeBacklink();
    ref.read(locateProvider.notifier).locate(noteId: noteId);
  }

  /// 解析引用块的目标（标题 + 形态）；目标不存在返回 null ⇒ 块显示"引用已失效"。
  RefTarget? _resolveRefTarget(String refType, String refId) {
    final store = ref.read(noteStoreProvider);
    if (refType == RefBlockKeys.refStream) {
      // 速记在独立表（`stream_items`），与笔记 / 块两条读口分开。
      final String? text = ref.read(streamStoreProvider).textOf(refId);
      if (text == null) return null;
      return RefTarget(
        title: _streamRefTitle(text),
        kind: NoteKind.spark,
        stream: true,
      );
    }
    if (refType == RefBlockKeys.refBlock) {
      // 块引用：显示它**所属笔记**的标题（块级定位留待后续）。
      final String? owner = store.blockNoteId(refId);
      if (owner == null) return null;
      final Note? n = store.noteById(owner);
      return n == null
          ? null
          : RefTarget(title: _displayTitle(n), kind: n.kind);
    }
    final Note? n = store.noteById(refId);
    return n == null ? null : RefTarget(title: _displayTitle(n), kind: n.kind);
  }

  /// 引用块跳转：块引用跳到它所属的那篇笔记。
  void _openRefTarget(String refType, String refId) {
    if (refType == RefBlockKeys.refStream) {
      // 速记不是笔记：切到「心流」视图（走统一导航历史，可「上一步」回来）。
      ref.read(navHistoryProvider.notifier).selectHome(HomeView.timeline);
      return;
    }
    final store = ref.read(noteStoreProvider);
    final String? noteId = refType == RefBlockKeys.refBlock
        ? store.blockNoteId(refId)
        : refId;
    if (noteId == null) return;
    ref.read(locateProvider.notifier).locate(noteId: noteId);
  }

  static String _displayTitle(Note n) =>
      n.title.trim().isEmpty ? '未命名笔记' : n.title;

  /// 速记引用的显示名：首行截断（速记没有标题）。
  static String _streamRefTitle(String text) {
    final String first = text.trim().split('\n').first.trim();
    if (first.isEmpty) return '速记';
    return first.length <= 24 ? first : '${first.substring(0, 24)}…';
  }

  /// 反链气泡：与目录气泡同一套定位（右对齐、与按钮底边无缝相接）。
  Widget _backlinkPopover(BuildContext context, OverlayChildLayoutInfo info) {
    final Size screen = info.overlaySize;
    final RenderBox? box =
        _backlinkButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final Offset origin = box == null
        ? const Offset(0, 48)
        : box.localToGlobal(Offset.zero);
    final double top = box == null ? 56 : origin.dy + box.size.height;
    final double right = box == null
        ? 16
        : screen.width - (origin.dx + box.size.width);
    final double available = screen.height - top - 16;
    return Positioned(
      top: top,
      right: right,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: available.clamp(160, double.infinity),
          maxWidth: BacklinkPanel.width,
        ),
        child: TapRegion(
          // 点气泡外（含正文）= 关闭；按钮与气泡同组，互相不算"外"。
          groupId: _backlinkTapGroupId,
          onTapOutside: (_) => _closeBacklink(),
          child: AppFloatSurface(
            width: BacklinkPanel.width,
            padding: EdgeInsets.zero,
            child: BacklinkPanel(
              noteId: widget.noteId,
              onOpenNote: _openBacklink,
            ),
          ),
        ),
      ),
    );
  }

  // == 标签气泡 ==============================================================
  // 第四只耳：**点击开关**（理由同 [_tagsVisible]）。面板本体是 `TagsPanel`
  // （自己 watch 列表、自己经 saveTags 写），这里只管浮层的定位 / 开关 /
  // 点外部收起 —— 与反链气泡同一套浮层三件套，一行新逻辑都不该有。

  void _toggleTags() {
    final bool next = !_tagsVisible;
    setState(() => _tagsVisible = next);
    if (next) {
      if (!_tagsController.isShowing) _tagsController.show();
    } else {
      _closeTags();
    }
  }

  void _closeTags() {
    if (_tagsVisible) setState(() => _tagsVisible = false);
    if (_tagsController.isShowing) _tagsController.hide();
  }

  /// 标签气泡：与反链气泡同一套定位（右对齐、与按钮底边无缝相接）。
  Widget _tagsPopover(BuildContext context, OverlayChildLayoutInfo info) {
    final Size screen = info.overlaySize;
    final RenderBox? box =
        _tagsButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final Offset origin = box == null
        ? const Offset(0, 48)
        : box.localToGlobal(Offset.zero);
    final double top = box == null ? 56 : origin.dy + box.size.height;
    final double right = box == null
        ? 16
        : screen.width - (origin.dx + box.size.width);
    final double available = screen.height - top - 16;
    return Positioned(
      top: top,
      right: right,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          // 标签面板内容少（不像反链可能一长串），下限给小一点贴内容收。
          maxHeight: available.clamp(120, double.infinity),
          maxWidth: TagsPanel.width,
        ),
        child: TapRegion(
          // 按钮与气泡同组（同反链）：点按钮自己不算"点外部"。
          groupId: _tagsTapGroupId,
          onTapOutside: (_) => _closeTags(),
          child: AppFloatSurface(
            width: TagsPanel.width,
            padding: EdgeInsets.zero,
            child: TagsPanel(noteId: widget.noteId),
          ),
        ),
      ),
    );
  }

  /// `AppFlowyEditor.blockWrapper` 的口子：逐块包一层"落点高亮"。
  ///
  /// 平时每个块只是多一层 `AnimatedContainer`（底色 null、竖条透明 ⇒ 不改布局
  /// 也不改观感）；只有 [_flashedNodeId] 指向本块时，左侧浮出一根主题色竖条 +
  /// 一层极淡底色，随后自动淡出。
  ///
  /// ⚠️ 竖条用 `foregroundDecoration` 而不是 `decoration` 的 border：border 会
  /// **算进盒子尺寸**、把标题文字整体右推 3px（闪一下、文字跳一下）；前景装饰
  /// 只画不占位。
  ///
  /// 底色会盖住标题**自带的**上间距（h1 有 34px）——这是有意的：它标的是
  /// "这一块/这一节"，不是"这一行文字"。
  Widget _flashWrapper(
    BuildContext context, {
    required Node node,
    required Widget child,
  }) {
    // 探针挂在同一口子（外层）：它量的是**块自身**的渲染盒，与高亮装饰无关
    // （前景边框不占位、底色不占位），两者互不影响。
    //
    // 回调走 [_onBlockMeasured] 而不是直连 `BlockHeights.measure`：实测值还要
    // **增量**喂给滚动器那份逐 item 高度（O(1)，见那里的说明）。
    return BlockHeightProbe(
      nodeId: node.id,
      onMeasured: _onBlockMeasured,
      child: ValueListenableBuilder<String?>(
        valueListenable: _flashedNodeId,
        builder: (BuildContext context, String? flashed, Widget? _) {
          final bool on = flashed != null && flashed == node.id;
          final ColorScheme scheme = Theme.of(context).colorScheme;
          return AnimatedContainer(
            duration: _flashFade,
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              // 与目录面板的激活底色**同一个令牌**：点哪一条、落在哪一块，
              // 两处的色是同一族（2026-10-08 随全局换装走强调色药丸，
              // 旧的 3px 左条一并撤掉——药丸一种形状信号就够）。
              color: on ? AppTheme.selectedPill(scheme) : null,
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
            ),
            child: child,
          );
        },
      ),
    );
  }

  void _onContentChanged() {
    if (!_loaded) return;
    // 停顿 500ms（`_savePolicy.debounce`）落盘；**连续输入时最迟 2s 也必落一次**。
    _contentSave.bump();
  }

  /// 把"历史栈是否非空"同步到撤销 / 重做按钮的可用态。
  ///
  /// `ValueNotifier` 自己会短路"值没变"（`==` 比较），所以直接写值即可。
  void _syncHistoryAvailability() {
    _canUndo.value = _editor.undoManager.undoStack.isNonEmpty;
    _canRedo.value = _editor.undoManager.redoStack.isNonEmpty;
  }

  /// 落盘：**写出 v2 块树**（落库格式在此切换）+ 同步纯文本。
  ///
  /// 纯文本直接从内存 Document 抽取——不再把刚 encode 好的 JSON 再 decode
  /// 一遍（那等于每次保存做两次完整序列化往返，全在 UI isolate 上）。
  ///
  /// `jsonEncode` 按文档大小走**后台 isolate**（长文编码几毫秒，不值得占
  /// UI 帧；短文不值得白付一次 isolate 冷启动开销，仍同步编码）。Document
  /// 的读取与纯文本抽取在调 `Isolate.run` **之前**同步完成——dispose 兜底
  /// 落盘时编辑器马上就要销毁，异步阶段只允许持有纯 JSON 值。
  void _flushContent() => unawaited(_writeContent());

  /// 正文落盘的**可等待**形态：快照同步取好后，await 编码（长文走 isolate）+ 写库。
  ///
  /// 防抖与 [dispose] 只需要"发出去"（[_flushContent]），而退出前落盘必须**等到
  /// 写完**——否则关窗口就成"发出去之后立刻杀掉进程"，等于没做。
  Future<void> _writeContent() async {
    // 同步阶段：取快照（`Document` 只能在销毁前读）。
    final NoteSavePayload payload = _noteSaver.capture(_editor.document);
    // 字数与落盘同源（同一份 plainText），不含第二次全量解析。
    _wordCount.value = countWords(payload.plainText);
    // 异步阶段：编码（长文走 isolate）+ 写库。编排见 [NoteSaver]。
    await _noteSaver.write(payload);
  }

  /// 标题落盘的**可等待**形态：回调里现读控制器（不闭包捕获旧值），与 [dispose]
  /// 的兜底落盘同一口径。
  Future<void> _writeTitle() =>
      _notes.saveTitle(widget.noteId, _titleController.text.trim());

  /// 退出前落盘：把两个防抖里还没写下去的编辑**写完**再放行窗口关闭。
  ///
  /// 2026-09-17 实测的丢数据现场就是这里没做：用户"改完（删掉一段）立刻关窗口"，
  /// 防抖那个 500ms 还没到期，进程已经退出——重开后被删的内容又回来了。
  ///
  /// 判据与 [dispose] 一致（`pending` 才写）：什么都不改就关窗口同样不该重写正文；
  /// 区别只在**要不要等**。`_loaded` 那道闸也不能少（未装载时保存会把空文档写回去）。
  Future<void> _flushForExit() async {
    if (!_loaded) return;
    final bool pendingContent = _contentSave.pending;
    final bool pendingTitle = _titleSave.pending;
    _contentSave.cancel();
    _titleSave.cancel();
    if (pendingContent) await _writeContent();
    if (pendingTitle) await _writeTitle();
  }

  /// 标题变更：值不在这里捕获——落盘时现读控制器（始终最新，且与 dispose 同口径）。
  void _onTitleChanged(String _) => _titleSave.bump();

  /// **排版参数 → 块高表的同步**（`BlockHeights` 的输入）。在拿到布局约束后调用
  /// （内容列宽只有那时才知道），做三件事：
  ///
  /// 1. **换预测器**：文字块的预算高度（`TextPainter` 干跑一次布局，实测偏差
  ///    **0.0px**，见 `block_height_predictor.dart` 与它的 spike）。它必须跟着
  ///    排版参数重建——清表只清实测值，**换不掉预测器里那套旧参数**；
  /// 2. **按指纹清表**：列宽 / 字号 / 行高 / 系统缩放 / 内容列有效宽度任一变化
  ///    ⇒ 全部实测值作废。漏清比"表里没值"更糟（留下**过期高度**，换算长期偏）。
  ///    清表延到帧末：布局期间通知监听者会踩"构建中标脏"；
  /// 3. **重建逐 item 高度**（喂给滚动器的 `itemExtentOf`，见 [_itemExtents]）：
  ///    文档结构或排版参数一变就得重算。**这一件必须在布局期间同步做完**——
  ///    它正是编辑器子树本次布局要用的输入（首帧就拿到精确总高，才不会出现
  ///    "第一帧用外推、第二帧修正一次"的那一跳）。
  void _syncBlockHeights({
    required EditorTypography typography,
    required ColorScheme scheme,
    required double contentWidth,
    required double columnWidth,
  }) {
    final double textScale = MediaQuery.textScalerOf(context).scale(1.0);
    // 列够宽时封顶在 contentWidth（官方按块限宽、居中），所以指纹取**有效**宽度：
    // 目录面板开合动画的过渡帧不会白清表（只有列真的被挤到上限以下才算变化）。
    final double effectiveWidth = math.min(columnWidth, contentWidth);

    final String fingerprint =
        '$contentWidth|${typography.fontSize}|${typography.lineHeight}'
        '|$textScale|${effectiveWidth.toStringAsFixed(1)}';
    final bool layoutChanged = _layoutFingerprint != fingerprint;
    _layoutFingerprint = fingerprint;

    final int structureHash = _structureHashOfDocument();
    final bool structureChanged = _structureHash != structureHash;
    _structureHash = structureHash;

    // ⚠️ **预测器必须先换**：下面重建逐 item 高度时会逐块调 `heightOf`，而它的
    // 取值链是"实测 → 预算(预测器) → 按一行估"。顺序颠倒的话，首帧重建拿到的
    // 全是"按一行估"（实测过：总高少算 3.4k px，正是 20 个多行段落被估成一行）。
    _blockHeights.predictor = BlockHeightPredictor(
      typography: typography,
      // 与 `EditorStyle.textStyleConfiguration` **同一份**：预测器要复刻渲染的
      // span 构造（行内加粗 / 斜体 / 等宽 / 链接都会改行盒）。
      textStyleConfiguration: typography.toTextStyleConfiguration(
        // 正文色走 [AppTheme.editorText]（两边都按 APCA 收到 Lc ±90 附近，
        // 见其文档），与下面编辑器那份**必须同源**。
        text: AppTheme.editorText(scheme.brightness, scheme),
        link: AppTheme.editorLink(scheme),
        codeBackground: AppTheme.editorInlineCodeBg(scheme.brightness),
        muted: scheme.onSurfaceVariant,
      ),
      maxWidth: contentWidth,
      blockPadding: EditorTypography.blockPadding,
      textScaleFactor: textScale,
      // 图片：用预解析的宽高比（见 [_prefetchImageRatios]）——让"没存尺寸的
      // 图片"在被构建之前就有真实高度，而不是等解码完成再改总高。
      imageAspectRatioOf: (String src) => _imageRatios[src],
    );

    if (layoutChanged || structureChanged) {
      if (_blockHeights.measuredCount == 0) {
        // 首帧 / 空表：清表无事可做，**同步**重建（本次布局就用上）。
        _rebuildItemExtents(
          typography: typography,
          availableWidth: effectiveWidth,
        );
        _prefetchImageRatios(typography, effectiveWidth);
      } else {
        // 表里有实测值 ⇒ 清表要等帧末（布局期间通知监听者会踩"构建中标脏"），
        // 重建跟着它一起放到帧末：**不能**用清表前的旧高度建表。
        final EditorTypography captured = typography;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _blockHeights.clear();
          _rebuildItemExtents(
            typography: captured,
            availableWidth: effectiveWidth,
          );
          _prefetchImageRatios(captured, effectiveWidth);
        });
      }
    }

    // 取值口子（幂等：方法读字段，换掉 [_itemExtents] 也照样看得到）。
    //
    // 始终把逐块精确高度喂给滚动器（补丁 10）：总高从第一帧起精确，滚动中
    // 不再因外推被修正 ⇒ 页面 / 滚动条都不跳。这是现在唯一保留的路径。
    _scroll.itemExtentOf = _itemExtentAt;
  }

  /// 预热文档里**没存尺寸**的图片：解析出宽高比后**就地**更新那几项高度。
  ///
  /// 只读图片头部（见 `image_metrics.dart`），本地文件是微秒级，所以在首次布局
  /// 之后就基本就绪——早于图片本身的解码，滚动器因此拿到的是真高度。
  void _prefetchImageRatios(
    EditorTypography typography,
    double availableWidth,
  ) {
    final int generation = _extentsGeneration;
    for (final Node node in _editor.document.root.children) {
      if (node.type != ImageBlockKeys.type) continue;
      // 存了 height 的图片与宽高比无关（官方 `SizedBox(height:)` 直接定高）。
      if (node.attributes[ImageBlockKeys.height] != null) continue;
      final String src = (node.attributes[ImageBlockKeys.url] as String?) ?? '';
      _imageRatios.ensure(
        src,
        onResolved: () =>
            _refreshImageExtents(generation, typography, availableWidth),
      );
    }
  }

  /// 比例解析完成：把**图片项**重算一遍（就地改，不重建整表、也不重建 widget
  /// 树——滚动器每帧都会重新求和，改完下一次布局就生效）。
  void _refreshImageExtents(
    int generation,
    EditorTypography typography,
    double availableWidth,
  ) {
    // 这批值已过期（排版参数 / 文档结构在这期间变过）⇒ 扔掉，由重建那轮负责。
    if (generation != _extentsGeneration) return;
    final List<Node> nodes = _editor.document.root.children;
    for (int i = 0; i < nodes.length && i < _itemExtents.length; i++) {
      final Node node = nodes[i];
      if (node.type != ImageBlockKeys.type) continue;
      if (node.attributes[ImageBlockKeys.height] != null) continue;
      final double value = _blockHeights.heightOf(
        node,
        typography,
        availableWidth: availableWidth,
      );
      final double old = _itemExtents[i];
      if (old == value) continue;
      // 图片比例解析完成时块高会变 ⇒ 同样走锚定纠偏（见 [_adjustScrollForExtentChange]）。
      _adjustScrollForExtentChange(i, value - old);
      _itemExtents[i] = value;
    }
  }

  /// 文档结构指纹：块个数 + 逐个 id 的滚动哈希（O(N) 整数运算，无字符串）。
  int _structureHashOfDocument() {
    int hash = 17;
    for (final Node node in _editor.document.root.children) {
      hash = hash * 31 + node.id.hashCode;
    }
    return hash;
  }

  /// 重建 [_itemExtents]（文档结构 / 排版参数变化时调用）。
  void _rebuildItemExtents({
    required EditorTypography typography,
    required double availableWidth,
  }) {
    // 换代：此前派出去的异步回包（图片比例）作废，避免用旧参数写回表里。
    _extentsGeneration++;
    final List<Node> nodes = _editor.document.root.children;
    _itemIndexOf = <String, int>{
      for (int i = 0; i < nodes.length; i++) nodes[i].id: i,
    };
    _itemExtents = <double>[
      for (final Node node in nodes)
        _blockHeights.heightOf(
          node,
          typography,
          availableWidth: availableWidth,
        ),
      // ⚠️ 末尾留白（footer）是滚动列表的**最后一项**，索引口径与官方
      // `page_block_component.dart` 的 `itemBuilder` 一致（我们只挂 footer、
      // 不挂 header ⇒ 就是"节点数"这个下标）。
      //
      // 它是列表里**最高的项**（一屏 600px）：官方那套外推在它没被构建时只按
      // 平均块高计入 ⇒ 滚到尾部估算被修正一次（滑块变短）。这里给它真值，
      // 那处尾部修正随之消失（见 [editorTrailingSpace] 的"代价"一节）。
      editorTrailingSpace,
    ];
  }

  /// 块高变化后保持视口锚定：变化的块若在当前顶部块**之上**，它下方的所有内容
  /// （含当前视口）会随新高度整体下移 `delta`；把滚动偏移同步 `+= delta`，顶部块
  /// 就钉在原本的像素位置、用户看不到跳变。
  ///
  /// 这是官方 `scrollable_positioned_list` **没有**的闭环（其 `itemPositionsListener`
  /// 只上报、不修正，见 `block_heights.dart` 的核实结论）。我们用 `_itemExtents`
  /// （喂给补丁 10 的逐块高度）做增量计算，不依赖官方的滚动 API 语义。
  ///
  /// 当前滚动偏移取自 [_scroll] 的 `offsetNotifier`（由官方 `scrollOffsetListener`
  /// 累加，等于真实像素）；顶部块索引用纯函数 [blockIndexAtOffset] 从**变化前**
  /// 的高度表算得（调用时 `_itemExtents[index]` 还是旧值）。
  void _adjustScrollForExtentChange(int changedIndex, double delta) {
    if (delta == 0) return;
    final double sOld = _scroll.offsetNotifier.value;
    final int topIndex = blockIndexAtOffset(_itemExtents, sOld);
    if (changedIndex >= topIndex) return; // 变化块在顶部或之下：无需纠偏
    _scroll.scrollOffsetController.jumpTo(offset: sOld + delta);
  }

  /// 块被实测：写进块高表，并**只改那一项**滚动高度（O(1)）。
  ///
  /// 不能整体重建：滚动时新块逐帧被实测，而重建一次要重算全篇预算
  /// （≈7ms / 300 块）。
  void _onBlockMeasured(String nodeId, double height) {
    _blockHeights.measure(nodeId, height);
    final int? index = _itemIndexOf[nodeId];
    if (index == null || index >= _itemExtents.length) return;
    // 与 `BlockHeights.measure` 同口径（吸附整像素）。
    final double value = height.roundToDouble();
    final double old = _itemExtents[index];
    if (old == value) return;
    // 上方块高度变化 ⇒ 视口下方的块会位移；用我们的形式把滚动偏移同步挪 delta，
    // 让当前顶部块钉在原处（官方锚点制不自动纠偏，见 [_adjustScrollForExtentChange]）。
    _adjustScrollForExtentChange(index, value - old);
    _itemExtents[index] = value;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // 编辑器偏好（列宽 / 字号 / 行高）与设置面板同一来源——改设置即时生效。
    final AppSettings settings = ref.watch(settingsProvider);
    // 中文排版：标题档位 / 字距 / 字体回退链的单一来源（编辑器与标题框共用）。
    final EditorTypography typography = EditorTypography(
      fontSize: settings.fontSize,
      lineHeight: settings.lineHeight,
    );

    // 标题的**外部改名同步**：在左侧列表里「重命名」当前这篇时，编辑器里的
    // 标题控制器还是旧文本，继续编辑就会把改名覆盖回去。这里盯住列表里的
    // 标题：与控制器不一致时就采纳（正在输入、防抖未落盘时跳过，别打断）。
    // 注意用 listen（不重建）而非 watch：列表快照变化不需要编辑器重跑 build，
    // 重建范围由各消费方自己订阅（如 _MetaBar 的 revisedAt）。
    ref.listen(notesProvider, (
      AsyncValue<List<Note>>? _,
      AsyncValue<List<Note>> next,
    ) {
      final List<Note>? notes = next.value;
      if (notes == null || _titleSave.pending) return;
      for (final Note n in notes) {
        if (n.id != widget.noteId) continue;
        if (_titleController.text != n.title) _titleController.text = n.title;
        return;
      }
    });

    // 引用块的标题是**查出来的**（块里只存 id）：别处改名 / 删除后，块里那份要
    // 跟着变。列表快照一变就 +1，让引用块自己重建（listen 而非 watch，理由同上）。
    ref.listen(notesProvider, (
      AsyncValue<List<Note>>? _,
      AsyncValue<List<Note>> _,
    ) {
      _refsRevision.value++;
    });

    // 目录列显隐：窗口 < 1100 放不下「列表 300 + 正文 + 目录 208」三栏，
    // 开关自动失效（状态保留，拉宽后恢复显示）——与 quill 版同规则。
    // 阈值随侧栏 320→300 同步下调 20。
    final bool wideEnough = MediaQuery.sizeOf(context).width >= 1100;

    // ⚠️ 块高表（预测器 + 按指纹清表）在**末尾的 LayoutBuilder 里**同步：
    // 内容列宽只有拿到布局约束才知道，而它是文字预算的关键输入。
    // 详见 [_syncBlockHeights]。

    final Widget editorColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 标题行：标题**居中**（2026-09-14 定案：不做左对齐）+ 右侧
        // 「文档工具双耳」（搜索 / 目录）——都是文档级操作，与选区无关，
        // 不该进浮动格式栏。
        Stack(
          key: _titleRowKey,
          children: <Widget>[
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: settings.titleWidth),
                // 标题**下移一条带的高度**（2026-09-26 定）：头部因此分成两条带——
                // 上带 = 撤销 / 重做 + 双耳，下带 = 标题。理由见下面按钮带的注释
                // （与浮栏**竖直错开**）。
                child: Padding(
                  padding: const EdgeInsets.only(top: _kHeaderBandHeight),
                  child: NoteTitleField(
                    controller: _titleController,
                    onChanged: _onTitleChanged,
                    typography: typography,
                  ),
                ),
              ),
            ),
            // 标题行两端各一组常驻件：**左 = 撤销 / 重做**，**右 = 目录 / 搜索**。
            //
            // ## 撤销 / 重做为什么搬到左端（2026-09-14 用户定案）
            // 它们原先是悬浮栏的 group 0，而悬浮栏**只在有选区时出现**——撤销最
            // 常用的时刻恰恰是"刚打完字、光标还在那儿"，那时按钮根本够不着。
            // 它们是**文档级、无选区也要能用**的操作，故常驻（Word / VS Code 同款），
            // 并与右端双耳左右对称。
            //
            // ## 为什么按钮独占**上面一条带**、标题下移一条（2026-09-26 定）
            // 拖选时浮出的格式栏（FloatingToolbar，跑在 Overlay 层）悬在**正文首行
            // 正上方**，水平范围与首行重合。按钮若与标题同带，就与浮栏落在**同一条
            // 竖直带**上——右移到正文左缘等于钻到浮栏底下（2026-09-25 实测：撤销后
            // 重做点不到，因为撤销会恢复选区 ⇒ 浮栏再现）。标题下移成独立一条后，
            // 正文整体下移 ⇒ 浮栏跟着下移到**标题带**，按钮这条带就空出来了——
            // 水平仍重合，但**竖直错开**，点得到。
            //
            // ⚠️ 由此 [_kHeaderActionTopPadding] 那条"图标字形顶略高于标题首行"的
            // 竖向校准**已失效**（按钮不再与标题同行），它现在只是按钮带的上留白。
            //
            // ## 两条硬约束（别换成别的写法）
            // - **Stack 定位 ⇒ 不占布局流**：标题的居中轴完全不受两端按钮影响
            //   （换成 Row 包标题会把标题挤偏，那是我们放弃的写法）；覆盖层内部
            //   的 Row 用 `CrossAxisAlignment.start` 让两端都贴顶。
            // - 空白区不吸点击（`Row` 不实现 `hitTestSelf`）⇒ 标题照常可点。
            Positioned.fill(
              child: ListenableBuilder(
                listenable: _historyAvailability,
                builder: (BuildContext context, Widget? _) => LayoutBuilder(
                  // 左缘**动态**对齐正文首行：正文块由
                  // `EditorStyle.desktop(maxWidth: settings.contentWidth)` **按块居中**，
                  // 块内还有 `EditorTypography.blockPadding`（左右各 16）⇒
                  //   正文左缘 =（列宽 − contentWidth）/ 2 + blockPadding.left
                  // 列宽随窗口 / 宽度模式变，故在这里按约束算（Positioned.fill 拿到的
                  // 正是正文列的宽度）。窄窗口时差为负 ⇒ 兜到 0。
                  builder: (BuildContext _, BoxConstraints c) {
                    final double gutter = math.max(
                      0.0,
                      (c.maxWidth - settings.contentWidth) / 2,
                    );
                    return Padding(
                      padding: EdgeInsets.only(
                        top: _kHeaderActionTopPadding,
                        left: gutter + EditorTypography.blockPadding.left,
                        right: Tokens.spaceMd,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          // 左：常驻撤销 / 重做（灰显表达"现在按不了"）。
                          _HistoryButton(
                            itemKey: 'editor.undo',
                            icon: const tabler.ArrowBackUp(strokeWidth: 1.5),
                            tooltip: kEditorTooltips['sinan.undo']!,
                            enabled: _canUndo.value,
                            onPressed: _editor.undoManager.undo,
                          ),
                          const SizedBox(width: Tokens.spaceXs),
                          _HistoryButton(
                            itemKey: 'editor.redo',
                            icon: const tabler.ArrowForwardUp(strokeWidth: 1.5),
                            tooltip: kEditorTooltips['sinan.redo']!,
                            enabled: _canRedo.value,
                            onPressed: _editor.undoManager.redo,
                          ),
                          // 中间留给标题（标题自己居中，这里只是把两端分开）。
                          const Spacer(),
                          // 顺序：搜索在左，**目录最右**（面板开关靠边的惯例）。
                          // 2026-09-18 由"搜索·目录·反链"改为"搜索·反链·目录"
                          // ——目录是最常用的那个，靠边更好按。2026-09-26 再加
                          // 第四只耳「标签」（夹在反链与目录之间），目录仍最右。
                          _EarButton(
                            itemKey: 'editor.ear.find',
                            // 「列表 + 放大镜」= 在本篇里找。刻意与顶栏那个**全局**搜索
                            // （`home_screen` 的 `tabler.Search`，纯放大镜）用不同图标，
                            // 免得两处搜索在视觉上混成一个（2026-09-23 用户挑的）。
                            icon: const tabler.ListSearch(strokeWidth: 1.5),
                            tooltip: '搜索（Ctrl+F）',
                            onPressed: _showFind,
                          ),
                          const SizedBox(width: Tokens.spaceXs),
                          // 反链（双链读侧）。**不受 wideEnough 限制**：目录耳那道
                          // 门槛是历史遗留的"推挤式右栏"约束，反链是纯浮层、不占布局。
                          OverlayPortal.overlayChildLayoutBuilder(
                            controller: _backlinkController,
                            overlayChildBuilder: _backlinkPopover,
                            child: TapRegion(
                              groupId: _backlinkTapGroupId,
                              child: _EarButton(
                                // ⚠️ 这个 key 是**定位的命根子**：`_backlinkPopover` 靠它取
                                // 按钮的屏幕坐标，漏挂 ⇒ `box == null` ⇒ 走兜底坐标
                                // （top 56 / right 16），面板会飞到左上角而不是按钮下边。
                                // 2026-09-23 实测踩到（目录那边挂了、反链这边漏了）。
                                key: _backlinkButtonKey,
                                itemKey: 'editor.ear.backlink',
                                // 两条**上下平行**的双向箭头 = "双向"（反链本就成对：我 ↔ 你）。
                                // 刻意不用 `tabler.Link`（链条）——那是链接弹窗 / 链接块 /
                                // 斜杠菜单"链接"条目的图标，同屏撞语义（2026-09-23 用户挑的）。
                                icon: const tabler.ArrowsSort(strokeWidth: 1.5),
                                tooltip: '反链（谁引用了我）',
                                active: _backlinkVisible,
                                onPressed: _toggleBacklink,
                              ),
                            ),
                          ),
                          const SizedBox(width: Tokens.spaceXs),
                          // 标签（第四只耳）。与反链同款：纯浮层不占布局、点击开合。
                          OverlayPortal.overlayChildLayoutBuilder(
                            controller: _tagsController,
                            overlayChildBuilder: _tagsPopover,
                            child: TapRegion(
                              groupId: _tagsTapGroupId,
                              child: _EarButton(
                                // 定位命根子（同反链耳的教训）：漏挂 ⇒ 气泡飞左上角。
                                key: _tagsButtonKey,
                                itemKey: 'editor.ear.tags',
                                icon: const tabler.Tag(strokeWidth: 1.5),
                                tooltip: '标签',
                                active: _tagsVisible,
                                onPressed: _toggleTags,
                              ),
                            ),
                          ),
                          if (wideEnough) ...<Widget>[
                            const SizedBox(width: Tokens.spaceXs),
                            // 官方 3.47 推荐写法：OverlayPortal 直接在按钮处挂浮层，
                            // 由 [_tocPopover] 按 layoutInfo 定位（不再需要 LayerLink）。
                            OverlayPortal.overlayChildLayoutBuilder(
                              controller: _tocController,
                              overlayChildBuilder: _tocPopover,
                              child: TapRegion(
                                // 与气泡同组：点按钮自己不算"点外部"，否则 down 先
                                // 收起、up 的 onPressed 又打开，按钮就关不掉气泡。
                                groupId: _tocTapGroupId,
                                // ⚠️ 不做悬停触发（2026-09-23 用户定案，见 [_tocVisible]）：
                                // 只有点击开合。`_tocButtonKey` 直接挂在按钮上（原先挂在
                                // 那层 MouseRegion 上），气泡定位照旧。
                                child: _EarButton(
                                  key: _tocButtonKey,
                                  itemKey: 'editor.ear.toc',
                                  // 三条**递增缩进**的横线 = 层级目录（官方 tags：
                                  // sublevels / structure / drilldown）。比原来的
                                  // `tabler.List` 多表达了"层级"（2026-09-23 用户挑的）。
                                  icon: const tabler.MenuDeep(strokeWidth: 1.5),
                                  tooltip: '目录（Ctrl+Shift+O）',
                                  active: _tocVisible,
                                  onPressed: _toggleToc,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
        Expanded(
          // 浮动工具栏（官方 FloatingToolbar，2026-09-12 替换常驻固定栏）：
          // 拖选浮出、光标/无选区即隐——空闲时条目 widget 根本不挂载，
          // "每次击键重建 ~20 个条目"的固定成本随之消失。条目全部是
          // 选区级格式操作（fixed_toolbar.dart，含按下保焦装饰）；文档级
          // 的搜索/目录已上移为标题行双耳。
          child: FloatingToolbar(
            items: _staticToolbarItems,
            editorState: _editor,
            editorScrollController: _scroll,
            textDirection: TextDirection.ltr,
            tooltipBuilder: sinanToolbarTooltip,
            // 浮动工具条外观完全交给 `decoration`（[AppTheme.neuFloatBar]）：
            // 与菜单/面板同口径的浮层三件套——[floatSurface] 底色（亮白/暗灰，
            // 与纸面各差一档）+ [menuBorder] 满档描边 + 单向下投投影，压在正文
            // 上也清晰可辨（2026-09-16 由轻拟态改为浮层口径，解决"融进纸里"）。
            // ⚠️ 三个"让位"参数缺一不可：`backgroundColor` 透传进官方容器的是
            // `Material(color: ...)`，不置透明的话那层**白色 r=8 矩形**会从装饰
            // 底下透出来，把柔边切成硬边；`toolbarElevation` 归零是让 M3 那层
            // 单向投影（还会给表面染色）彻底退场；激活态图标用满强度
            // `scheme.onSurface`（而非 `onSurfaceVariant`）以明确高亮当前按钮，
            // 其余图标沿用 `onSurfaceVariant` 与编辑器正文强调色错开。
            //
            // ⚠️ **1px 描边的等量补偿**：`Container` 会把 `decoration` 的边框
            // 计入内边距 ⇒ 条外形各方向比几何常量多 1px。这里刻意留 1px 的余量
            // 让它去吃掉描边，外形尺寸取整：
            // 横向 11 + 1 = **12**；纵向 38 + 2 = **40**。
            //
            // ⚠️ `floatingToolbarHeight` 不只是"条的内部行高"——官方定位数学
            // （`calculateToolbarOffset` 的上下翻位阈值、`_toolbarTop` 的让位）
            // 用的就是这个值，所以它必须与实际外高等价：现在它 38、外高 40，
            // 阈值那处分毫之差（1px 量级）不影响任何判定。
            //
            // （更正一条旧注释：官方 `FloatingToolbarStyle` 确实没有描边槽位，
            // 但 `FloatingToolbar` 另有 `decoration` 槽位作用在内层 Container 上
            // ——上一轮记成"官方给不了外观控制"是不准确的。）
            style: FloatingToolbarStyle(
              backgroundColor: const Color(0x00000000),
              toolbarActiveColor: scheme.onSurface,
              toolbarIconColor: scheme.onSurfaceVariant,
            ),
            decoration: AppTheme.neuFloatBar(theme.brightness, scheme),
            padding: const EdgeInsets.symmetric(horizontal: 11),
            floatingToolbarHeight: 38,
            // 链接悬浮提示：指针停在链接上浮出 URL 面板（**自研**——官方只有
            // "点击 → 编辑菜单 / Ctrl+点击 → 打开"这条链路，没有悬浮；
            // 详见 `widgets/link_hover_tooltip.dart`）。
            child: LinkHoverTooltip(
              editorState: _editor,
              child: AppFlowyEditor(
                editorState: _editor,
                editorScrollController: _scroll,
                // **不自动抢焦点**（2026-10-17 删掉原先的 `autoFocus: true`；官方默认
                // 即 false，故不显式传）：本类的焦点规矩全在 [_maybeConsumeLocate]——
                // "要开写"的入口（新建 / 日记 / 引文跳转）带 `focus: true` ⇒ `_focusAt`
                // 设选区、键盘服务随即聚焦；其余浏览入口（列表点开 / Ctrl+K / 日历 /
                // 撤销 toast）一律 `focus: false` ⇒ 焦点留在原处（列表行），键盘 ↑/↓
                // 选笔记才不断。挂载即抢焦会把这条规矩整个推翻（点开一篇就从列表被
                // 拽进编辑器）。⚠️ 别再把 autoFocus 加回 true。
                // 正文右键菜单：官方 `contextMenuBuilder` **不传就完全不弹**
                // （`_showContextMenu` 首行判空返回——此前右键毫无反应）。
                // 面板与条目见 `widgets/editor_context_menu.dart`。
                contextMenuBuilder:
                    (
                      BuildContext menuContext,
                      Offset position,
                      EditorState editorState,
                      VoidCallback onDismiss,
                    ) => sinanEditorContextMenu(
                      context: menuContext,
                      position: position,
                      editorState: editorState,
                      onDismiss: onDismiss,
                    ),
                // 末尾留白 = 官方口径的**一屏可点热区**：点它 = 继续写
                // （官方 `editor_page.dart` 的 footer 就是这么挂的；取值与取舍见
                // `editorTrailingSpace` 的文档）。
                //
                // 官方把 `footer` 作为滚动列表的**最后一项**（`page_block_component
                // .dart` 的 ScrollablePositionedList.builder），所以它只加尾部空间，
                // 不让任何块的索引偏移——目录按顶层块索引 jumpTo，照旧对得上。
                footer: GestureDetector(
                  key: const ValueKey<String>('editor.trailingArea'),
                  // translucent：空白处的**点击**归我们（继续写），滚轮/悬停照旧
                  // 穿透给滚动器；footer 外层已被官方包了
                  // `IgnoreEditorSelectionGesture`，不会和编辑器选字打架。
                  behavior: HitTestBehavior.translucent,
                  // ⚠️ [a11y] 不要把这块"点空白把光标放到末尾"的**鼠标便利区**暴露给
                  // 语义树。它没有任何文字，语义会**向上合并进滚动视口节点**（视口是最近的
                  // 一层语义边界），于是视口变成一个"没有名字的可点目标"——2026-09-17
                  // `test/a11y/` 的 `labeledTapTargetGuideline` 报的正是这条。
                  // 将来若要让读屏用户也有"跳到末尾"，正确做法是在工具栏加一个**有名字的
                  // 按钮**，而不是让一片无名区域可点。
                  excludeFromSemantics: true,
                  onTap: _focusEndOfDocument,
                  // 空白区右键：不再自建菜单，走官方链路（见官方
                  // `_onSecondaryTapDown` 的 sinan 补丁 16——非文本块 / 空白 /
                  // 无选区都会弹，且不会叠成两个菜单）。
                  child: const SizedBox(
                    width: double.infinity,
                    height: editorTrailingSpace,
                  ),
                ),
                // 目录跳转的落点高亮：逐块包一层（见 [_flashWrapper]）。
                blockWrapper: _flashWrapper,
                blockComponentBuilders: sinanBlockComponentBuilders(
                  typography: typography,
                  markerColor: scheme.onSurfaceVariant,
                  // 引用块的目标标题 / 跳转（双链）——块本身不碰 provider。
                  refBridge: _refBridge,
                ),
                characterShortcutEvents: sinanCharacterShortcutEvents(
                  // 斜杠菜单配色：官方默认是硬编码浅色盘（白底 + 青蓝强调色，
                  // 不看种子色也不看明暗）——不喂就是"菜单没跟随主题"。
                  slashMenuStyle: sinanSlashMenuStyle(
                    // 浮层令牌：斜杠菜单是浮层（不是纸面），底色走 floatSurface。
                    background: AppTheme.floatSurface(
                      Theme.of(context).brightness,
                    ),
                    foreground: scheme.onSurface,
                    muted: scheme.onSurfaceVariant,
                    outline: scheme.outlineVariant,
                    error: scheme.error,
                  ),
                ),
                // 官方 Find&Replace 的快捷键（ctrl+F 查找 / ctrl+H 替换）**不在**
                // `standardCommandShortcutEvents` 里（它需要 BuildContext 与样式），
                // 必须自己追加——这正是此前"Ctrl+F 完全无效"的原因。
                // 追加时必须带上标准表，否则会顶掉全部内置快捷键。
                commandShortcutEvents: <CommandShortcutEvent>[
                  // 粘贴 URL 自动转链（Ctrl+V）：**必须排在官方 paste 之前**
                  // （先命中先赢），并把官方那条从标准表里摘掉，避免两条 ctrl+v
                  // 并存（我们的实现读不到网址时会回退调官方 paste）。
                  sinanPasteCommand,
                  ...standardCommandShortcutEvents.where(
                    (CommandShortcutEvent event) =>
                        event.key != pasteCommand.key &&
                        // Ctrl+K 于 2026-09-30 **全局让位**给全局搜索浮层
                        // （`search.open`，⌘K 范式）。官方链接菜单随之摘掉；
                        // 加链接走工具栏「链接」钮（自研 sinan.link，支持
                        // 裸域名补协议 / 自定义名称，见 link_toolbar_item.dart）。
                        event.key != showLinkMenuCommand.key,
                  ),
                  ...findAndReplaceCommands(
                    context: context,
                    style: _findStyle,
                  ),
                  // 以下都是**官方没有**的工具栏快捷键（tooltip 里已声明）：
                  // 代码块 Ctrl+Shift+`、无序列表 Ctrl+Shift+8、有序列表 Ctrl+Shift+7、
                  // 引用 Ctrl+Shift+Q、对齐 Ctrl+Shift+L/E/R、目录 Ctrl+Shift+O。
                  sinanCodeBlockCommand,
                  sinanBulletedListCommand,
                  sinanNumberedListCommand,
                  sinanQuoteCommand,
                  ...sinanAlignCommands,
                  sinanTocCommand(onToggle: _toggleToc),
                  // 折叠块 Ctrl/Cmd+Enter 切换展开/折叠（官方同款 toggleToggleListCommand）。
                  toggleToggleListCommand,
                ],
                editorStyle: EditorStyle.desktop(
                  // maxWidth = 内容列限宽：官方按块居中（滚动器仍铺满全宽，
                  // 空白处滚轮照样生效），等价于 quill 的 maxContentWidth。
                  maxWidth: settings.contentWidth,
                  // ⚠️ **按块**生效的内边距（不是编辑器外框）：竖直值会加在
                  // 每一个块上。详见 EditorTypography.blockPadding 的说明。
                  padding: EditorTypography.blockPadding,
                  // 跟随系统"文字大小/缩放"（鸿蒙排版五项要求之一：支持系统大字体；
                  // Windows 在 设置 → 辅助功能 → 文本大小 里调）。
                  // 编辑器内部用的是显式 fontSize（不走 Ambient 样式），官方给的口子
                  // 就是 textScaleFactor —— 不传它等于忽略系统的无障碍字号设置。
                  // 标题输入框（TextField/EditableText）默认就会跟随，故两侧一致。
                  textScaleFactor: MediaQuery.textScalerOf(context).scale(1.0),
                  cursorColor: scheme.onSurface,
                  // 选区色兼作**查找命中高亮**：SearchServiceV3 用"把选区移到
                  // 命中处"表达当前命中（FindReplaceStyle 的颜色字段对 V3 无效，
                  // 见 _findStyle 注释）。中性灰选区在深色画布上几乎不可见
                  // （用户反馈），改主题色半透明——手动选择文字也会是同一色
                  // （V3 无法区分"查找命中"与"手动选择"，选区高亮本就是同一
                  // 视觉语义）。
                  selectionColor: scheme.primary.withValues(
                    alpha: scheme.brightness == Brightness.dark ? 0.40 : 0.30,
                  ),
                  // 中文排版（单一来源）：字号/行高取自设置，外加字距 0、
                  // CJK 回退链、w400、even 行盒——官方默认这几项全无。
                  // ⚠️ `text` 必须给：编辑器走 `RichText`、不继承 Ambient 样式，
                  // 不给就是引擎默认白（深色侥幸正常、亮色正文隐形——实测过）。
                  textStyleConfiguration: typography.toTextStyleConfiguration(
                    // 正文色走 [AppTheme.editorText]（亮 `#3A3A3A` / 暗 `#DDDDDD`
                    // ——APCA Lc ±90 附近，见其文档）。
                    text: AppTheme.editorText(scheme.brightness, scheme),
                    link: AppTheme.editorLink(scheme),
                    codeBackground: AppTheme.editorInlineCodeBg(
                      scheme.brightness,
                    ),
                    muted: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
        _MetaBar(wordCount: _wordCount, noteId: widget.noteId),
      ],
    );

    // 目录现在是悬浮气泡（覆盖式），不再推挤正文，故正文独占整行。
    // 仍包一层 Row + Expanded 维持原 flex 行为（正文填满宽度）。
    final Widget editorRow = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[Expanded(child: editorColumn)],
    );

    // 块高表要的是"内容列真正有多少宽度"（= 本视图宽度 − 目录面板占的宽度），
    // 只有布局约束知道。LayoutBuilder **只读约束、不改布局**（原样传下去）。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _syncBlockHeights(
          typography: typography,
          scheme: scheme,
          contentWidth: settings.contentWidth,
          // 目录现在是悬浮气泡（覆盖式），不占布局流，内容列恢复全宽。
          columnWidth: constraints.maxWidth,
        );
        return editorRow;
      },
    );
  }
}

/// 底部元信息：字数 + 修订时间。
///
/// 自己订阅"本条笔记的 revisedAt"（select 窄订阅）：保存落盘后只有这一条
/// 20px 高的元信息行重建，**编辑器根 build 不再陪跑**——此前 watch 挂在
/// 根上，每次保存都要重造整套 builder 表 / 快捷键表 / EditorStyle。
class _MetaBar extends ConsumerWidget {
  const _MetaBar({required this.wordCount, required this.noteId});

  final ValueNotifier<int> wordCount;
  final String noteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DateTime? revisedAt = ref.watch(
      notesProvider.select((AsyncValue<List<Note>> value) {
        final List<Note>? notes = value.value;
        if (notes == null) return null;
        for (final Note n in notes) {
          if (n.id == noteId) return n.revisedAt;
        }
        return null;
      }),
    );
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Tokens.spaceLg,
        vertical: Tokens.spaceSm,
      ),
      child: Row(
        children: <Widget>[
          ValueListenableBuilder<int>(
            valueListenable: wordCount,
            builder: (BuildContext context, int value, Widget? _) =>
                Text('$value 字', style: style),
          ),
          const Spacer(),
          if (revisedAt != null)
            Text('修改于 ${_formatRevised(revisedAt)}', style: style),
        ],
      ),
    );
  }
}

/// 修改时间的展示格式：今天只显时刻，跨日带日期。
String _formatRevised(DateTime t) {
  final DateTime now = DateTime.now();
  final String hhmm =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final bool isToday =
      t.year == now.year && t.month == now.month && t.day == now.day;
  return isToday
      ? hhmm
      : '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} $hhmm';
}

/// 标题行小按钮（撤销/重做 + 三个"耳"）的**图标色规格**。
///
/// 编辑页走**极简留白**（2026-09-23 用户定案）：常驻态只是"这里有入口"的
/// 暗示，压到很低对比；**鼠标悬停 / 键盘聚焦**才明确起来。
///
/// ⚠️ 只能经 `IconButton.foregroundColor` 下发：tabler 图标不直接读 Material 的
/// `IconTheme`（见 `AppIconTheme` 的说明），这份 style 就是图标唯一的色源。
WidgetStateProperty<Color?> _headerActionColor(
  ColorScheme scheme, {
  bool active = false,
}) {
  return WidgetStateProperty.resolveWith((Set<WidgetState> states) {
    // "开着"（目录 / 反链面板展开）用强调色，与面板建立视觉关联。
    if (active) {
      return scheme.primary;
    }
    if (states.contains(WidgetState.hovered) ||
        states.contains(WidgetState.focused)) {
      return scheme.onSurface;
    }
    return scheme.onSurfaceVariant.withValues(alpha: _kHeaderActionIdleAlpha);
  });
}

/// 常驻态的不透明度。
///
/// `onSurfaceVariant` 直接铺在暗色底上偏亮（实测 `#C2C2C2`，"极简留白"要的不是
/// 这个存在感）；压到 0.5 才是"隐约可见、不抢戏"。禁用态再降一档。
const double _kHeaderActionIdleAlpha = 0.5;
const double _kHeaderActionDisabledAlpha = 0.28;

/// 标题行两端按钮（撤销/重做 + 三个耳）的**上内边距**。
///
/// 它不是"随手一个间距"，而是从目标位置反推出来的：
///
///   图标字形顶 = 本值 +（[Tokens.headerActionSize] − [Tokens.iconMdSm]）/ 2 = **10**
///
/// 10 是用户实机比过、让图标略高于标题首行（约 3.5px）的落点。
/// 图标 18 → 20 → 24 时本值 4 → 5 → 7，每次都是为了把这个落点**钉住**
/// （见标题行的校准注释）。2026-09-25 图标改回 [Tokens.iconMdSm]=20，本值随之
/// 由 7 反推回 5（`5 + (30 − 20) / 2 = 10`），竖向校准不变。
///
/// ⚠️ 2026-09-26：按钮已从标题行**分出去独占上面一条带**（标题下移），那条
/// "略高于标题首行"的竖向校准随之**失效**——本值现在只是按钮带的上留白。
const double _kHeaderActionTopPadding = 5;

/// 头部**按钮带**的高度（2026-09-26 定）：撤销 / 重做 + 双耳独占最上面这一条，
/// 标题从它**下面**开始 ⇒ 头部分成两条带（理由见 build 里按钮带的注释）。
///
/// = 按钮带上留白 [_kHeaderActionTopPadding](5) + 按钮热区
/// [Tokens.headerActionSize](30) + 与标题的留白(5) = **40**。
///
/// ⚠️ 最后那档留白原为 4 ⇒ 带高 39。2026-10-15 改 5 是为了**与侧栏页头同高**：
/// 侧栏「logo + 应用名」行取 [Tokens.brandStripHeight]（40，锚就是本带），两列
/// 顶端的动作区于是是同一个矩形（**等高且同 y**——侧栏顶呼吸也用
/// [Tokens.spaceXxs]，与内容卡顶环缝同值 ⇒ 两条带起点一致）。
/// 改这里就把两列一起改（或改 [Tokens.brandStripHeight] 后同步，别只动一边）。
const double _kHeaderBandHeight =
    _kHeaderActionTopPadding + Tokens.headerActionSize + 5;

/// 标题行**左侧**的常驻历史按钮（撤销 / 重做）。
///
/// ## 为什么从悬浮栏搬出来（2026-09-14 用户定案）
/// 悬浮栏**只在有选区时出现**，而撤销最常用的时刻是"刚打完字、光标还停在
/// 那儿"——那时根本没有悬浮栏，按钮够不着。撤销 / 重做是**文档级、无选区也要
/// 能用**的操作，该常驻（Word / VS Code / Notion 同款），且与右端双耳左右对称。
///
/// 规格与 [_EarButton] 完全一致（同一热区 [Tokens.headerActionSize] / 同一图标档
/// [Tokens.iconMd] / 同一上内边距 [_kHeaderActionTopPadding]），差别只有两点：
/// 1. **灰显**表达可用性（历史栈空 ⇒ `onPressed: null` ⇒ M3 禁用态配色）；
/// 2. 包了 [withKeepEditorFocus]：点完按钮焦点回到正文，紧接着按 Ctrl+Z 仍然
///    生效（与悬浮栏条目走同一条保焦通路）。
class _HistoryButton extends StatelessWidget {
  const _HistoryButton({
    required this.itemKey,
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
  });

  /// 测试定位用 key（'editor.undo' / 'editor.redo'）。
  final String itemKey;
  final Widget icon;
  final String tooltip;

  /// 可用（历史栈非空）；false ⇒ 灰显且不可点。
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return withKeepEditorFocus(
      IconButton(
        key: ValueKey<String>(itemKey),
        // ⚠️ tooltip 必须交给 [IconButton] 自己，**不要**在外面包一层 [Tooltip]：
        // 外层 Tooltip 把提示挂在**父语义节点**上，按钮自己那个节点仍然没有名字
        // ——读屏（NVDA）念出来只是个"按钮"。2026-09-17 由 a11y 盘点实测
        // （`labeledTapTargetGuideline`，见 `test/a11y/accessibility_test.dart`）。
        tooltip: tooltip,
        onPressed: enabled ? onPressed : null,
        style:
            IconButton.styleFrom(
              minimumSize: const Size.square(Tokens.headerActionSize),
              maximumSize: const Size.square(Tokens.headerActionSize),
              padding: EdgeInsets.zero,
              iconSize: Tokens.iconMdSm,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Tokens.radiusButton),
              ),
              // 与三个耳同一套色（见 [_headerActionColor]）；不可用再降一档，
              // "现在按不了"一眼可见。
              disabledForegroundColor: scheme.onSurfaceVariant.withValues(
                alpha: _kHeaderActionDisabledAlpha,
              ),
            )
            // ⚠️ `styleFrom` 的 `foregroundColor` 只收 `Color?`；要按状态解析只能走
            // `ButtonStyle.copyWith`（它收 `WidgetStateProperty`）。
            .copyWith(foregroundColor: _headerActionColor(scheme)),
        icon: icon,
      ),
    );
  }
}

/// 标题行**右侧**的「文档工具耳」：搜索 / 目录这类**文档级**操作的小入口。
///
/// 设计要点（位置 2026-09-14 由左上角移到右侧；规格同日定为 18 / 30，
/// 2026-09-23 图标取**应用侧主力档** [Tokens.iconMd]，2026-09-25 改回
/// 顶条辅助档 [Tokens.iconMdSm]）：
/// - 常驻但不抢戏：图标 20px + 热区 [Tokens.headerActionSize]（30，够到最小可点目标）；
/// - 配色走 [_headerActionColor]（2026-09-23 用户定案）：编辑页**极简留白**
///   —— 常驻淡、鼠标悬停/键盘聚焦才明确、"开着"（目录展开）转 primary；
/// - 挂在 Stack 的**右上**（`Positioned.fill` + `Align.topRight`），
///   不占布局流，与标题居中互不干扰。
class _EarButton extends StatelessWidget {
  const _EarButton({
    super.key,
    required this.itemKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  /// 测试定位用 key（'editor.ear.find' / 'editor.ear.toc'）。
  final String itemKey;
  final Widget icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// 激活态（当前目录展开）。
  final bool active;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return IconButton(
      key: ValueKey<String>(itemKey),
      // 见 [_HistoryButton]：tooltip 交给按钮自己，别在外面包 Tooltip
      // （外层的提示会挂在父语义节点上，按钮节点仍然无标签）。
      tooltip: tooltip,
      onPressed: onPressed,
      style:
          IconButton.styleFrom(
            minimumSize: const Size.square(Tokens.headerActionSize),
            maximumSize: const Size.square(Tokens.headerActionSize),
            padding: EdgeInsets.zero,
            // ⚠️ 图标尺寸**只有这一条路**：`icon` 里刻意不写 height/width，
            // 由 `AppIconTheme` 把这个 `iconSize` 转发给 tabler（写死 24 会顶掉它，
            // 那正是 2026-09-23 这三个耳"偏大偏亮"的一半原因）。
            iconSize: Tokens.iconMdSm,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
            ),
          )
          // 极简留白：常驻淡、悬停/聚焦明确、"开着"用强调色。
          // ⚠️ `styleFrom` 的 `foregroundColor` 只收 `Color?`；按状态解析只能走
          // `ButtonStyle.copyWith`（它收 `WidgetStateProperty`）。
          .copyWith(
            foregroundColor: _headerActionColor(scheme, active: active),
          ),
      icon: icon,
    );
  }
}
