import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        HardwareKeyboard,
        KeyDownEvent,
        LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../domain/note.dart';
import '../media/attachment_file_chip.dart';
import '../media/media_kind.dart';
import '../media/pending_media.dart';
import '../notes/services/note_media_service.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'providers.dart'
    show
        appDataDirProvider,
        streamAttachmentsProvider,
        streamFocusProvider,
        streamProvider;
import 'stream_delete.dart';
import 'stream_export.dart';
import 'stream_ledger_panel.dart' show showStreamLedger;

/// **灵感**（2026-10-17 定：flomo 式低摩擦收件箱）。
///
/// ## 版式（本轮定稿）
/// `单列 · 上限 640 · 居中`：灵感靠时间序读，不铺网格；宽屏把留白当设计，
/// 不把内容拉成一整行（长文本每行 50+ 字时反而难扫）。
///
/// 一屏三区，从上到下：
/// 1. **捕获条**（surface + 1px 发丝边、零投影、focus 才转蓝）；
/// 2. **工具行**（28 高：搜索 / 选择 + 快捷键提示与条数）；
/// 3. **时间流**（左侧 56 日期栏 + 右侧行；行间只靠 8px 间距，**不画分隔线**）。
///
/// ## 交互（2026-11-17 卡片墙改版，同日三次收口）
/// - **真瀑布卡片墙**（可用宽 <680 单列 / <1100 两列 / 其上三列）：内容
///   自适应高、**全文零截断**、两列各自堆叠不等高——一眼概览所有想法
///   （用户定）。时间顺序不重要：排序按 createdAt，显示不带时间；
/// - **双击**卡：就地编辑（同列宽、随内容长高，`Esc` / `Ctrl+Enter` 保存
///   收起）——单击不编辑（2026-11-17 用户定，防误触）；右键菜单「编辑」、
///   键盘 Enter 同一入口。时间与「更多」只在编辑态脚注里出现；
/// - hover 卡：放大 1.025（呼应点击放大）；行上**右键**弹动作菜单（墙上
///   最快的操作入口，零版面成本）；
/// - 选择：工具行换成「已选 N 条 / 取消」，勾选框覆盖卡左上角，合并走唯一的
///   实色按钮「合并为新笔记」；
/// - 归档条目：只出现在「引用聚焦」视图，降对比、只读、脚注给红字「删除」。
///
/// ## 边界
/// 只读 `streamProvider`（独立表 `stream_items`），**不读笔记 / 画布数据**；
/// 条目经 `stream_export.dart` 单向流出。
class StreamView extends ConsumerStatefulWidget {
  const StreamView({super.key, this.tag});

  /// 顶栏标签筛选。**灵感刻意忽略它**（灵感是纯文本、没有标签）。
  final String? tag;

  @override
  ConsumerState<StreamView> createState() => _StreamViewState();
}

class _StreamViewState extends ConsumerState<StreamView> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';

  /// 多选合并：进入后点击行 = 勾选，不再展开编辑。
  bool _selectMode = false;
  final Set<String> _selected = <String>{};

  /// 卡片墙里**就地编辑**的那一条（2026-11-17：同列宽、随内容长高，不跨列）。
  /// 单值 ⇒ 同时只展开一张。换卡时旧卡的失焦保存是异步的，收尾**只清自己**
  /// （见下），否则会把刚展开的新卡挤回折叠态。
  String? _expandedId;

  void _setExpanded(String id, bool value) {
    setState(() {
      if (value) {
        _expandedId = id;
      } else if (_expandedId == id) {
        _expandedId = null;
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<StreamItem?> _capture(
    String text,
    List<StreamAttachmentInput> media,
  ) async {
    if (media.isEmpty) {
      await ref.read(streamProvider.notifier).add(text);
      return null;
    }
    return ref.read(streamProvider.notifier).addMedia(text, media);
  }

  // ── 派生结果缓存（2026-11-16）────────────────────────────────────
  // build 里对全表要跑好几遍 O(n)：scoped / open / archived / 归档总数 /
  // visibleIds / 拍平 entries ——**每敲一个搜索字符**都从头来一遍，万条以上
  // 打字会卡（`_matches` 还对每条做 trim/toLowerCase）。
  //
  // 这里按「数据引用 + 搜索词 + 聚焦」缓存一整份派生结果，命中就整份复用；
  // query 在算之前只小写化一次。`identical` 吃 provider 的 List 引用：
  // `StreamNotifier` 的增删改都换新 List ⇒ 引用一变自然失效，不会读到旧结果。
  List<StreamItem>? _sliceSource;
  String? _sliceQuery;
  String? _sliceFocusId;
  _FlowSlice? _sliceCache;

  _FlowSlice _flowSlice(List<StreamItem> items, {required String? focusId}) {
    if (identical(_sliceSource, items) &&
        _sliceQuery == _query &&
        _sliceFocusId == focusId) {
      return _sliceCache!;
    }

    // 从笔记里的灵感引用跳过来：只显示那一条（`null` = 正常时间流）。
    final List<StreamItem> scoped = focusId == null
        ? items
        : <StreamItem>[
            for (final StreamItem i in items)
              if (i.id == focusId) i,
          ];
    final String q = _query.trim().toLowerCase();
    bool match(StreamItem i) => q.isEmpty || i.text.toLowerCase().contains(q);
    final List<StreamItem> open = <StreamItem>[
      for (final StreamItem i in scoped)
        if (!i.archived && match(i)) i,
    ];
    // 已处理**不在这里**：它是一整页（`StreamLedgerView`，2026-10-18 P1）。
    // 工具栏的「归档 N」入口要报**归档总数**，不能参与搜索过滤：否则一搜
    // 不到归档条目，按钮就消失、右侧操作簇跟着跳（2026-10-20 实报）。
    final List<StreamItem> archived = <StreamItem>[
      for (final StreamItem i in scoped)
        if (i.archived && match(i)) i,
    ];
    final int archivedTotal = scoped.where((StreamItem i) => i.archived).length;
    // 时间流永远只有"当下"；聚焦（从引用跳来）时只给那一条。
    final List<StreamItem> shown = focusId != null ? scoped : open;
    final bool empty = shown.isEmpty;

    final _FlowSlice out = (
      scoped: scoped,
      open: open,
      archived: archived,
      archivedTotal: archivedTotal,
      // 选择模式全选的候选：**当前可见**的待处理条目（含搜索过滤）。
      visibleIds: <String>[for (final StreamItem i in open) i.id],
      empty: empty,
      shown: shown,
    );
    _sliceSource = items;
    _sliceQuery = _query;
    _sliceFocusId = focusId;
    _sliceCache = out;
    return out;
  }

  void _toggleSelectMode() {
    setState(() {
      _selectMode = !_selectMode;
      if (!_selectMode) _selected.clear();
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  /// 全选 / 取消全选**当前可见**的条目（含搜索过滤）。
  void _toggleSelectAll(List<String> visibleIds) {
    setState(() {
      final bool all =
          visibleIds.isNotEmpty && visibleIds.every(_selected.contains);
      if (all) {
        _selected.removeAll(visibleIds);
      } else {
        _selected.addAll(visibleIds);
      }
    });
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
    _searchFocus.unfocus();
  }

  Future<void> _merge() async {
    final List<String> ids = _selected.toList(growable: false);
    if (ids.isEmpty) return;
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
    await mergeStreamToNewNote(context: context, streamIds: ids);
  }

  /// 复制选中条目：按列表顺序（新 → 旧）换行拼接。
  Future<void> _copySelected() async {
    final List<StreamItem> all =
        ref.read(streamProvider).value ?? const <StreamItem>[];
    final String text = <String>[
      for (final StreamItem i in all)
        if (_selected.contains(i.id) && i.text.trim().isNotEmpty) i.text,
    ].join('\n');
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text('已复制 ${_selected.length} 条')));
  }

  /// 删除选中条目：确认后移入回收站。
  Future<void> _deleteSelected() async {
    final List<String> ids = _selected.toList(growable: false);
    if (ids.isEmpty) return;
    final bool ok = await confirmTrashStream(context, ids.length);
    if (!ok || !mounted) return;
    await ref.read(streamProvider.notifier).trashMany(ids);
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text('已移入回收站（${ids.length} 条）')));
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<StreamItem>> streamAsync = ref.watch(streamProvider);
    final List<StreamItem> all = streamAsync.value ?? const <StreamItem>[];
    // 从笔记里的灵感引用跳过来：只显示那一条（`null` = 正常时间流）。
    final String? focusId = ref.watch(streamFocusProvider);
    final _FlowSlice flow = _flowSlice(all, focusId: focusId);
    // 目标已删（引用断链）：清掉聚焦，回到正常流。
    // ⚠️ 必须等数据**装载完成**再判：首帧 `value` 还是 null，直接判会把刚设的
    // 聚焦当成"目标不存在"清掉（一开始就是这么写错的）。
    if (focusId != null && streamAsync.hasValue && flow.scoped.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(streamFocusProvider.notifier).clear();
      });
    }
    // 聚焦：清掉搜索词，否则"引用的那条"可能被上次的搜索过滤掉，页面变成"什么都没有"。
    ref.listen<String?>(streamFocusProvider, (String? _, String? next) {
      if (next != null && _query.isNotEmpty) {
        _search.clear();
        setState(() => _query = '');
      }
    });

    return Padding(
      // 上留白 **12**（2026-10-20 用户改；原来 24）：页眉 + 搜索框上移，
      // 落笔更靠上；下 0、左右 0，留白区域也要能滚（见下方 [_pageColumn]）。
      padding: const EdgeInsets.only(top: Tokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // **列表头挪到输入框之上**（2026-10-18 用户定，对齐 flomo 的版式）：
          // 条数 / 搜索 / 选择是"这一页的工具栏"，写在纸上就是页眉——先于
          // 书写区出现，眼睛从左上角顺着读下来。空库时整行不出现。
          if (focusId != null)
            _pageColumn(_focusHeader())
          else if (_selectMode)
            _pageColumn(_selectionToolbar(flow.visibleIds))
          else if (_query.isNotEmpty ||
              flow.open.isNotEmpty ||
              flow.archived.isNotEmpty)
            _pageColumn(_listHeader(flow.open.length, flow.archivedTotal)),
          if (focusId != null ||
              _selectMode ||
              _query.isNotEmpty ||
              flow.open.isNotEmpty ||
              flow.archived.isNotEmpty)
            const SizedBox(height: Tokens.spaceSm),
          // 书写区**永远在**：即便正在看归档面板，这一页的主任务还是"记"。
          _pageColumn(_CaptureBar(onSubmit: _capture)),
          // 输入块下方 24：与页首 48 一起构成长短边，书写区自然浮在"纸面上"。
          const SizedBox(height: Tokens.spaceXl),
          Expanded(
            child: Stack(
              children: <Widget>[
                if (flow.empty)
                  _pageColumn(
                    _StreamEmpty(
                      searching: _query.trim().isNotEmpty,
                      archivedCount: flow.archived.length,
                    ),
                  )
                else
                  // `builder`（不是 `children`）：条目再多也只构建视口内那几行
                  // ——之前每次 hover / 输入都会重建全部卡片（2026-10-17 复查）。
                  //
                  // **真瀑布卡片墙**（2026-11-17 用户定，二次收口）：内容自适应高、
                  // 两边各自堆叠**不等高**——行对齐方案会在矮卡旁留大片白（用户
                  // 实报"个别留白会多"）。[MasonryGridView] 按**真实高度**把每条
                  // 追加到较矮的列（连高度估算代码都不用写），懒构建虚拟化保留
                  // （选它的主因；官方布局无"变高 + 懒"的网格，见依赖纪律说明）。
                  // 列数按**可用宽**自适应——AI 栏在 <1000 会自动收起、内容反而
                  // 变宽，按窗口宽定列会在 1000~1150（AI 开着、内容最窄）排成碎卡。
                  //
                  // 就地编辑（2026-11-17 同日定）：点开的卡在**自己的列里**长高，
                  // 不跨列；时间 /「更多」进编辑脚注。全文零截断——长卡只是把
                  // 那一列拉长，瀑布下不破版。
                  //
                  // 滚动视口仍整卡宽：滚动条贴窗口/卡片右缘，两侧留白也能滚
                  // （2026-10-18 用户实报"以为不能滚"）。
                  LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints c) =>
                        MasonryGridView.count(
                          crossAxisCount: _wallColumns(c.maxWidth),
                          mainAxisSpacing: Tokens.cardGridSpacing,
                          crossAxisSpacing: Tokens.cardGridSpacing,
                          padding: const EdgeInsets.fromLTRB(
                            Tokens.gridMargin,
                            0,
                            Tokens.gridMargin,
                            72,
                          ),
                          itemCount: flow.shown.length,
                          // `double.infinity` ⇒ 松约束下撑满列宽、紧约束下不变：
                          // 卡片必须满列宽（内容再短也不缩成一条）。
                          itemBuilder: (BuildContext context, int i) =>
                              SizedBox(
                                width: double.infinity,
                                child: _card(flow.shown[i]),
                              ),
                        ),
                  ),
                // 批量动作已挪到顶部「全选」左边（2026-10-18 用户定）：
                // 不再有底部浮条，选择控件与动作在同一处。
                // 归档是浮层（2026-10-18 定稿）：点表头那枚「归档 N」弹出来，
                // 背后这一页原样不动。
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 页面内容的**水平栅格**：左右 `gridMargin` 呼吸，**铺满可用宽**。
  ///
  /// 2026-11-17 卡片墙改版起不再是「640 阅读列居中」：页眉 / 书写区 / 卡片墙
  /// 同一栅格锚点，整页读作一块板（卡片墙是全宽版式，顶部缩在 640 里会散）。
  /// 滚动视口仍整卡宽（见 build 的 ListView）⇒ 滚动条贴边、留白也能滚。
  Widget _pageColumn(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Tokens.gridMargin),
    child: SizedBox(width: double.infinity, child: child),
  );

  /// 卡片墙列数（2026-11-17）：按**可用宽**自适应，不按窗口宽——
  /// AI 栏在 <1000 会自动收起、内容反而变宽，按窗口宽定列会在
  /// 1000~1150 这段（AI 开着、内容最窄）排成 ~264px 的碎卡。
  /// 账：可用宽 = 容器宽 − 2×gridMargin(24)；两列舒适区卡宽 340~540。
  int _wallColumns(double maxWidth) {
    final double u = maxWidth - Tokens.gridMargin * 2;
    if (u < 680) return 1;
    if (u < 1100) return 2;
    return 3;
  }

  // ── 列表头（条数 + 搜索框 + 选择）────────────────────────────────────

  /// 列表头，照 Apple 备忘录 / Bear / flomo 的做法：
  /// - **搜索常驻**（不是"点开才出现"）：左起一个 190×28 的搜索框，点一下就能
  ///   打字，边打边过滤；有词时出现清空 ×；
  /// - **选择是文字**（不是一枚看不懂的图标）：`选择` 两字，中性色、hover 铺底，
  ///   与搜索框同一条基线——之前那枚虚线方框图标在实机上根本认不出（用户实报）；
  /// - **左起** `归档 N` 入口（箱子图标 + 动词，低频功能不指望用户猜）；
  ///   **最右** `灵感 N 条` 计数 + `选择`。2026-10-20 用户定：归档与计数左右对调。
  Widget _listHeader(int openCount, int archivedCount) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle? muted = theme.textTheme.labelSmall?.copyWith(
      color: Bauhaus.inkMuted(theme.brightness),
    );
    // 窄窗收窄搜索框（< 560 时 190 → 120），免得「N 条 + 搜索 + 选择」挤成一团。
    final double searchWidth = MediaQuery.sizeOf(context).width < 560
        ? 120
        : 190;
    // 输入行高度 = 字号 × 行高；contentPadding 上下对称补齐到 28，
    // 让 `InputDecorator` 的内容区正好 28，`EditableText` 才会真居中。
    // 否则 `isCollapsed` + 0 padding 会把 15 高的文本行顶到上沿，
    // caret 与占位符差 ~5px（2026-10-20 实报"输入位置不对"）。
    final TextStyle? searchStyle = theme.textTheme.bodySmall;
    final double searchLineHeight =
        (searchStyle?.fontSize ?? 11) * (searchStyle?.height ?? 1.4);
    final double searchVerticalPadding = (28 - searchLineHeight) / 2;
    return SizedBox(
      height: 28,
      child: Row(
        children: <Widget>[
          // **归档入口** → 左端（2026-10-20 用户定：从右侧操作区移到最左，
          // 与右侧的「灵感 N 条 / 选择」交换位置）。
          if (archivedCount > 0) ...<Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 28),
              child: TextButton.icon(
                onPressed: () {
                  if (_selectMode) setState(() => _selectMode = false);
                  showStreamLedger();
                },
                icon: const tabler.Archive(
                  height: Tokens.iconXs,
                  width: Tokens.iconXs,
                  strokeWidth: Tokens.iconStroke,
                ),
                label: Text('归档 $archivedCount'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Tokens.spaceSm,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  // 归档入口用主题蓝，在操作区里突出重点（其余按钮保持中性）。
                  foregroundColor: scheme.primary,
                  textStyle: theme.textTheme.labelMedium,
                ),
              ),
            ),
            const SizedBox(width: Tokens.spaceSm),
          ],
          // **搜索框**：结构自己定高 28，不用 `InputDecorator` 的 border /
          // isDense / contentPadding / prefixIcon —— 那套会让 hint 按基线
          // 贴底，怎么调都不稳（2026-10-20 实报）。这里：
          //   外框 Container 画 1px 边线（焦点转蓝）
          //   内部 Row：放大镜 + 28 高 Stack（占位符 / 无装饰 TextField 都居中）
          SizedBox(
            width: searchWidth,
            height: 28,
            child: ListenableBuilder(
              listenable: _searchFocus,
              builder: (BuildContext context, Widget? _) {
                final bool focused = _searchFocus.hasFocus;
                return Container(
                  height: 28,
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  foregroundDecoration: BoxDecoration(
                    border: Border.all(
                      color: focused ? scheme.primary : scheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(Tokens.radiusSm),
                  ),
                  child: Row(
                    children: <Widget>[
                      const tabler.Search(
                        height: Tokens.iconXs,
                        width: Tokens.iconXs,
                      ),
                      const SizedBox(width: Tokens.spaceSm),
                      Expanded(
                        child: SizedBox(
                          height: 28,
                          child: Stack(
                            alignment: Alignment.centerLeft,
                            children: <Widget>[
                              if (_query.isEmpty)
                                ExcludeSemantics(
                                  child: IgnorePointer(
                                    child: Text(
                                      '搜索',
                                      style: searchStyle?.copyWith(
                                        color: Bauhaus.inkMuted(
                                          theme.brightness,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              Positioned.fill(
                                child: Semantics(
                                  label: '搜索',
                                  child: TextField(
                                    controller: _search,
                                    focusNode: _searchFocus,
                                    style: searchStyle,
                                    cursorColor: scheme.primary,
                                    textAlignVertical: TextAlignVertical.center,
                                    // ⚠️ 不能只用 `InputDecoration.collapsed`：
                                    // 它只把 `border` 设成 none，`enabledBorder` /
                                    // `focusedBorder` 仍是 null，会被主题的
                                    // `inputDecorationTheme` 兜底成 OutlineInputBorder
                                    // ⇒ 外面一层 Container 边 + 里面一层输入框边，
                                    // 看起来像"两个搜索框"（2026-10-20 实报）。
                                    decoration: InputDecoration(
                                      contentPadding: EdgeInsets.symmetric(
                                        vertical: searchVerticalPadding,
                                      ),
                                      hintText: '',
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      disabledBorder: InputBorder.none,
                                      errorBorder: InputBorder.none,
                                      focusedErrorBorder: InputBorder.none,
                                    ),
                                    onChanged: (String v) =>
                                        setState(() => _query = v),
                                    onSubmitted: (String _) =>
                                        _searchFocus.unfocus(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_query.isNotEmpty)
                        IconButton(
                          tooltip: '清空搜索',
                          iconSize: Tokens.iconXs,
                          onPressed: _clearSearch,
                          style: IconButton.styleFrom(
                            minimumSize: const Size(28, 28),
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const tabler.X(),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: Tokens.spaceSm),
          // **灵感 N 条** → 最右（2026-10-20 用户定：从最左挪到最右，右对齐贴住「选择」）。
          // 用 Expanded + textAlign.right：既把计数推到最右，窄屏又能自动省略号收缩。
          Expanded(
            child: Text(
              '灵感 $openCount 条',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: muted,
            ),
          ),
          const SizedBox(width: Tokens.spaceSm),
          // `minimumSize` 会被 compact 密度再压成 20 高（触达尺寸会红）⇒ 用
          // ConstrainedBox 把**按钮本身**撑到 28，语义矩形同步变大。
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 28),
            child: TextButton.icon(
              onPressed: _toggleSelectMode,
              // 图标 + 文字：单放图标认不出（15px 的虚线方块），单放文字又
              // 缺少"这是多选"的识别点 ⇒ 两者一起，图标 14 框（视觉 ≈10.5）。
              icon: const tabler.Checkbox(
                height: Tokens.iconXs,
                width: Tokens.iconXs,
                strokeWidth: Tokens.iconStroke,
              ),
              label: const Text('选择'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceSm),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: scheme.onSurfaceVariant,
                textStyle: theme.textTheme.labelMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectionToolbar(List<String> visibleIds) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool allSelected =
        visibleIds.isNotEmpty && visibleIds.every(_selected.contains);
    final TextStyle? labelStyle = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    final Widget count = Text(
      _selected.isEmpty
          ? '选择灵感'
          : '已选 ${_selected.length} / ${visibleIds.length} 条',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: labelStyle,
    );
    final Widget selectAll = TextButton(
      onPressed: visibleIds.isEmpty ? null : () => _toggleSelectAll(visibleIds),
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      child: Text(allSelected ? '取消全选' : '全选'),
    );
    final Widget cancel = TextButton(
      onPressed: _toggleSelectMode,
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      child: const Text('取消'),
    );
    // 批量动作：空选时不出现，避免一排置灰按钮常年占位。
    final Widget? actions = _selected.isEmpty
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextButton(
                onPressed: _copySelected,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.labelMedium,
                ),
                child: const Text('复制'),
              ),
              TextButton(
                onPressed: _deleteSelected,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: scheme.error,
                  textStyle: theme.textTheme.labelMedium,
                ),
                child: const Text('删除'),
              ),
              const SizedBox(width: Tokens.spaceSm),
              FilledButton(
                onPressed: _merge,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: theme.textTheme.labelMedium,
                ),
                child: const Text('合并为新笔记'),
              ),
            ],
          );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 宽窗：动作直接排在「全选」左边（2026-10-18 用户定：一眼可见，
        // 不用去底部找）。窄窗（最小窗 720 时正文只有 ~430）动作换第二行。
        if (actions == null || constraints.maxWidth >= 520) {
          return Row(
            children: <Widget>[
              Expanded(child: count),
              if (actions != null) ...<Widget>[
                actions,
                const SizedBox(width: Tokens.spaceSm),
              ],
              selectAll,
              cancel,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: count),
                selectAll,
                cancel,
              ],
            ),
            const SizedBox(height: Tokens.spaceXs),
            Align(alignment: Alignment.centerRight, child: actions),
          ],
        );
      },
    );
  }

  // ── 时间流 ───────────────────────────────────────────────────────────

  /// 聚焦态头部：告诉你"这是从某篇笔记引用跳过来的"，并给出回全量流的出口。
  Widget _focusHeader() {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      height: 28,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '正在查看被引用的灵感',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: Bauhaus.inkMuted(theme.brightness),
              ),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 28),
            child: TextButton(
              onPressed: () => ref.read(streamFocusProvider.notifier).clear(),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceSm),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: theme.colorScheme.onSurfaceVariant,
                textStyle: theme.textTheme.labelMedium,
              ),
              child: const Text('显示全部'),
            ),
          ),
        ],
      ),
    );
  }

  /// 一张灵感卡：**自适应高**（全文零截断，卡高由内容决定）；**双击**就地编辑
  /// （同列宽、长高，不跨列）——单击不编辑，右键「编辑」/ Enter 同入口。
  /// 稳定 [ValueKey]：state（编辑文本 / 悬浮 / 菜单）跟条目走，不跟索引走。
  Widget _card(StreamItem item) => _StreamCard(
    key: ValueKey<String>(item.id),
    item: item,
    archived: item.archived,
    expanded: _expandedId == item.id,
    onExpandChanged: (bool value) => _setExpanded(item.id, value),
    selectMode: _selectMode,
    selected: _selected.contains(item.id),
    onToggleSelect: () => _toggleSelected(item.id),
  );
}

/// 一次 build 需要的全部派生结果（见 `_StreamViewState._flowSlice`）。
///
/// 2026-11-16 收口：过滤 / 计数原先在 build 里各跑一遍 O(n)，且每敲一个
/// 搜索字符都重来。整份缓存之后，只有「数据引用 / 搜索词 / 聚焦」变了才重算。
/// （2026-11-17 卡片墙改版起不再拍平日期标——日期落进卡脚注。）
typedef _FlowSlice = ({
  List<StreamItem> scoped,
  List<StreamItem> open,
  List<StreamItem> archived,
  int archivedTotal,
  List<String> visibleIds,
  bool empty,
  List<StreamItem> shown,
});

// （日期组标 `_DayHeader` / 拍平 `_Entry` 2026-11-17 撤：卡片墙把日期收进
//   每张卡的脚注，不再按天分组。）

/// 空态：一句轻邀请 + 键位提示（输入条常驻，空库也能直接写第一条）。
class _StreamEmpty extends StatelessWidget {
  const _StreamEmpty({this.searching = false, this.archivedCount = 0});

  /// 搜索无结果是另一回事：这时该说"没有匹配"，而不是"还没有灵感"。
  final bool searching;

  /// 待处理空、但归档里还有东西：这是"清空了"，不是"没开始"。
  final int archivedCount;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness brightness = theme.brightness;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            searching
                ? '没有匹配的灵感'
                : archivedCount > 0
                ? '待处理清空了'
                : '还没有灵感',
            style: theme.textTheme.titleMedium?.copyWith(
              color: Bauhaus.ink(brightness),
            ),
          ),
          const SizedBox(height: Tokens.spaceXs),
          Text(
            searching
                ? '换个词试试'
                : archivedCount > 0
                ? '已处理的 $archivedCount 条还在上面的计数里，点开就能回看'
                : '按 Ctrl+Shift+M 随时记一条，或在上面写第一句',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Bauhaus.inkMuted(brightness),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── 捕获条 ─────────────────────────────

/// 顶部捕获条：**扁平**（surface + 1px 发丝边、零投影）。
///
/// 原先的"同色新拟态 + 双层柔光"是全站唯一的阴影例外，与「Bauhaus 零投影」
/// 冲突，本轮去掉：浮起感交给边线与留白，focus 时才把边线换成 primary。
class _CaptureBar extends ConsumerStatefulWidget {
  const _CaptureBar({required this.onSubmit});

  /// 提交：文本 + 已拷进 app 私有目录的附件（图片/视频）。无附件时只存文本。
  final Future<StreamItem?> Function(
    String text,
    List<StreamAttachmentInput> attachments,
  )
  onSubmit;

  @override
  ConsumerState<_CaptureBar> createState() => _CaptureBarState();
}

class _CaptureBarState extends ConsumerState<_CaptureBar> {
  final TextEditingController _controller = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);

  /// 待发送附件：选图/视频后先暂存，提交时才拷进私有目录（不发就不落盘，零孤儿）。
  /// 视频条目只留源路径、**不整读内存**（见 [PendingMedia]）。
  final List<PendingMedia> _pendingMedia = <PendingMedia>[];

  /// 提交后的**一次性**反馈：按钮变绿勾 600ms，然后回纸飞机。
  ///
  /// 之前是底行常驻「✓ 已记下」，一直亮到下次敲字 —— 空闲时它一直在说
  /// "已记下"，而你并没有刚记下任何东西（2026-10-17 用户实报）。
  /// 确认信号本来就该由"新卡片出现在正下方"承担，按钮只做瞬时应答。
  bool _justSent = false;
  Timer? _sentTimer;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
    // **进入灵感页即可写**（2026-10-17 用户定）：捕获区是这一页的入口，挂载后
    // 直接把焦点交给它，省掉"先点一下输入框"。放帧末请求，避免与首帧焦点树打架
    // （也保证 `_focus` 已挂上 RenderObject）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _sentTimer?.cancel();
    _focus.removeListener(_onFocusChange);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  /// Enter 记下 / Shift+Enter 换行（挂在输入框自己的焦点节点上）。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      unawaited(_submit());
      return KeyEventResult.handled;
    }
    // Ctrl / Cmd + V：剪贴板有图就贴成附件；没有图则把剪贴板文字手动插入。
    // 读图是异步平台通道（macOS 没有同步 API），所以这里**始终拦截**、异步判定，
    // 跨 Windows / macOS 行为一致（2026-10-18 用户定）。
    // macOS 用 Cmd（meta）；Windows/Linux 用 Ctrl。不能两个都判：Windows 的
    // meta 是 Win 键，兼判会把 Win+V（系统剪贴板历史）一起吞掉。
    final bool pasteModifier = Platform.isMacOS
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        pasteModifier) {
      unawaited(_pasteIntoField());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 智能粘贴：剪贴板是图 ⇒ 贴成待发附件；否则把剪贴板文字插入当前选区。
  ///
  /// 读图走 [NoteMediaService.readClipboardImage]（`pasteboard` 平台通道，
  /// Windows/macOS 通用；Windows 失败时回落 win32）。因为它是异步的，
  /// Ctrl/Cmd+V 与右键「粘贴」都必须"先拦截、再异步决定"。
  Future<void> _pasteIntoField() async {
    try {
      final Uint8List? img = await NoteMediaService.readClipboardImage();
      if (img != null) {
        if (!mounted) return;
        setState(
          () => _pendingMedia.add(
            PendingMedia(bytes: img, ext: '.png', kind: 'image'),
          ),
        );
        return;
      }
      // 没有图 ⇒ 手动贴文字（等价于框架的纯文本粘贴；本输入框无输入法格式化器）。
      final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      final String? text = data?.text;
      if (text == null || text.isEmpty || !mounted) return;
      final TextEditingValue value = _controller.value;
      final TextSelection sel = _controller.selection;
      final int start = sel.isValid ? sel.start : value.text.length;
      final int end = sel.isValid ? sel.end : value.text.length;
      _controller.value = TextEditingValue(
        text: value.text.replaceRange(start, end, text),
        selection: TextSelection.collapsed(offset: start + text.length),
      );
    } on Object catch (_) {
      // 平台通道 / 原生剪贴板异常：静默失败，不打断输入。
    }
  }

  /// 右键菜单：把默认的「粘贴」换成**智能粘贴**（图贴图、文贴文）。
  ///
  /// 默认菜单只探测剪贴板里的**文字**（`ClipboardStatus` 走 `Clipboard.hasStrings`），
  /// 剪贴板只有一张图时会把「粘贴」整项藏掉。这里在缺项时补回「粘贴」，让
  /// "复制图片 → 右键粘贴" 也能贴成附件，和 Ctrl+V 行为完全一致（2026-10-18 用户定）。
  Widget _buildContextMenu(BuildContext context, EditableTextState state) {
    final List<ContextMenuButtonItem> items = <ContextMenuButtonItem>[];
    bool hasPaste = false;
    for (final ContextMenuButtonItem item in state.contextMenuButtonItems) {
      if (item.type == ContextMenuButtonType.paste) {
        hasPaste = true;
        items.add(
          ContextMenuButtonItem(
            type: ContextMenuButtonType.paste,
            onPressed: () {
              // 贴图/贴字都在异步路径里完成；菜单先收起（官方文字粘贴的
              // `_pasteText` 内部会 hideToolbar，我们这条自定义路径要手动关）。
              unawaited(_pasteIntoField());
              state.hideToolbar();
            },
          ),
        );
      } else {
        items.add(item);
      }
    }
    // 剪贴板只有图、没文字时默认列表里没有「粘贴」——缺就补一项。
    // 不预先判断"有没有图"：跨平台读图是异步的，由 _pasteIntoField 决定
    // 贴图还是贴字（空剪贴板时这一项无副作用），排「全选」前与默认顺序一致。
    if (!hasPaste) {
      final ContextMenuButtonItem paste = ContextMenuButtonItem(
        type: ContextMenuButtonType.paste,
        onPressed: () {
          unawaited(_pasteIntoField());
          state.hideToolbar(); // 同上：自定义路径要自己收菜单
        },
      );
      final int insertAt = items.indexWhere(
        (ContextMenuButtonItem i) => i.type == ContextMenuButtonType.selectAll,
      );
      if (insertAt < 0) {
        items.add(paste);
      } else {
        items.insert(insertAt, paste);
      }
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: items,
    );
  }

  Future<void> _submit() async {
    final String text = _controller.text.trim();
    if (text.isEmpty && _pendingMedia.isEmpty) return;
    // 提交前把待发送附件**拷进 app 私有目录**（拷成功才落库；不发则无副本）。
    final List<StreamAttachmentInput> attachments = await _materializeMedia();
    // **先落库、再清空**：写失败时把原文留在输入框里并给一句提示，别让人以为
    // "记下了"却什么都没存（2026-10-17 复查）。
    try {
      await widget.onSubmit(text, attachments);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('没记下来，请重试')));
      return;
    }
    if (!mounted) return;
    if (_controller.text.trim() == text) {
      _controller.clear(); // 清空但保留焦点，方便连续记录
    }
    if (_pendingMedia.isNotEmpty) setState(_pendingMedia.clear);
    _sentTimer?.cancel();
    setState(() => _justSent = true);
    _sentTimer = Timer(Tokens.durationFeedback, () {
      if (mounted) setState(() => _justSent = false);
    });
  }

  /// 底行左侧**只描述当下输入**：有字给字数，没字给键位提示。
  /// 不再承载"刚刚记下了"这种一次性事件（那是按钮的活儿）。
  Widget _status(ThemeData theme, bool focused, int length) {
    final TextStyle? style = theme.textTheme.labelSmall?.copyWith(
      color: Bauhaus.inkMuted(theme.brightness),
    );
    final String text = length > 0
        ? '$length 字'
        : focused
        ? 'Enter 记下 · Shift+Enter 换行'
        : 'Ctrl+Shift+M 随时记 · Enter 记下';
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }

  /// 文件选择器里挑图片/视频（桌面端原生对话框，`file_picker` 支持一次多选）。
  /// 默认打开**桌面**目录，贴近"截图刚存桌面"的随手导入场景。
  ///
  /// 2026-11-17 视频 Tier 0：放行视频扩展名（[kVideoExtensions]），按扩展名
  /// 判 kind。⚠️ 选中**不读文件**——只留源路径，提交时才拷贝（见
  /// [materializePendingMedia]）：大视频整读内存会爆，"不发不落盘"语义也靠它。
  Future<void> _pickFiles() async {
    // 12.x：`pickFiles` 返回非空列表（取消则为空列表）；`allowMultiple` 已废弃
    // （本身就是多选取）。取消时循环直接不进，无需判空。
    final List<PlatformFile> files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>[...kImageExtensions, ...kVideoExtensions],
      initialDirectory: _desktopDir,
    );
    if (!mounted) return;
    for (final PlatformFile f in files) {
      final String? path = f.path;
      if (path == null) continue;
      setState(
        () => _pendingMedia.add(
          PendingMedia(
            sourcePath: path,
            ext: p.extension(path),
            kind: kindForPath(path),
          ),
        ),
      );
    }
  }

  /// 文件框默认打开位置：桌面（Windows=`%USERPROFILE%\Desktop`，其它=`~/Desktop`）。
  String get _desktopDir {
    final String? home = Platform.isWindows
        ? Platform.environment['USERPROFILE']
        : Platform.environment['HOME'];
    if (home == null) return '.';
    return p.join(home, 'Desktop');
  }

  /// 把待发送附件逐张**拷进 app 私有目录**（`stream_media/`），返回落库用的入参。
  ///
  /// 这里才真正落盘：用户选了又不发，磁盘上不会留下任何副本（零孤儿）。
  /// 拷贝语义见 [materializePendingMedia]（共享给笔记/画布的那份）。
  Future<List<StreamAttachmentInput>> _materializeMedia() =>
      materializePendingMedia(
        p.join(ref.read(appDataDirProvider), 'stream_media'),
        _pendingMedia,
      );

  /// 待发送附件的预览条（提交前看一眼贴了什么）。
  ///
  /// 图片给缩略图（剪贴板位图走字节、文件走源路径）；视频给 56 视频片
  /// （Tier 0 不生成缩略图）。右上角 × 随时可撤。
  Widget _pendingStrip(ThemeData theme) {
    final ColorScheme scheme = theme.colorScheme;
    final Brightness b = theme.brightness;
    return Padding(
      padding: const EdgeInsets.only(bottom: Tokens.spaceXs),
      child: Wrap(
        spacing: Tokens.spaceXs,
        runSpacing: Tokens.spaceXs,
        children: <Widget>[
          for (int i = 0; i < _pendingMedia.length; i++)
            Stack(
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(Tokens.radiusSm),
                  child: switch ((
                    _pendingMedia[i].bytes,
                    _pendingMedia[i].sourcePath,
                  )) {
                    (final Uint8List bytes, _) => Image.memory(
                      bytes,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                    ),
                    (null, final String path) =>
                      _pendingMedia[i].isVideo
                          ? Container(
                              width: 56,
                              height: 56,
                              color: Bauhaus.surface(b),
                              child: Center(
                                child: tabler.Video(
                                  height: Tokens.iconMd,
                                  width: Tokens.iconMd,
                                  color: Bauhaus.inkMuted(b),
                                ),
                              ),
                            )
                          : Image.file(
                              File(path),
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                            ),
                    // 不可达：[PendingMedia] 构造断言保证两者至少给一个。
                    _ => const SizedBox.shrink(),
                  },
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () => setState(() => _pendingMedia.removeAt(i)),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.54),
                        borderRadius: BorderRadius.circular(Tokens.radiusSm),
                      ),
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.close, size: 14, color: scheme.onError),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool focused = _focus.hasFocus;
    return AnimatedContainer(
      duration: Tokens.durationHover,
      decoration: BoxDecoration(
        // focus / 点击态**只有框变蓝**：底色恒定 surface、边框粗细恒定 1px
        // （2026-10-17 用户定）。之前还会叠一层 4% 主色底纹，视觉上像"整块
        // 被染色"，反而糊；只换线的颜色最干净，也绝不挤动内部文字。
        color: scheme.surface,
        borderRadius: BorderRadius.circular(Tokens.radiusLg),
        border: Border.all(
          color: focused ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        Tokens.spaceXl,
        Tokens.spaceLg,
        Tokens.spaceMd,
        Tokens.spaceSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            textField: true,
            label: '灵感输入，回车记下',
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              // 右键「粘贴」也走智能判定（图贴图、文贴文），与 Ctrl+V 一致。
              contextMenuBuilder: _buildContextMenu,
              // **一屏的视觉重心**：至少三行文字的高度（≈ 96），空态也是一块
              // 可以往里写的区域，而不是一条细输入框（2026-10-17 用户实报
              // "输入框太小、重心不在这里"）。内容长了继续长到 12 行。
              minLines: 3,
              maxLines: 12,
              style: theme.textTheme.bodyLarge?.copyWith(
                height: 1.7,
                color: Bauhaus.ink(theme.brightness),
              ),
              cursorColor: scheme.primary,
              decoration: InputDecoration(
                hintText: '记下此刻的想法…',
                hintStyle: theme.textTheme.bodyLarge?.copyWith(
                  height: 1.7,
                  color: Bauhaus.inkMuted(theme.brightness),
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (_pendingMedia.isNotEmpty) _pendingStrip(theme),
          const SizedBox(height: Tokens.spaceSm),
          // 底行：左 = 当下输入的状态（字数 / 键位提示），右 = 发送。
          // 字数用 ValueListenableBuilder 读输入框自身——不在每次按键都 setState
          // 整块。提交确认不在这里（按钮瞬时勾选），底行永远不会"残留旧状态"。
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (BuildContext _, TextEditingValue value, Widget? _) {
              final int length = value.text.trim().length;
              return Row(
                children: <Widget>[
                  // **贴图/视频入口**：左下图钉，点一下打开文件框（默认桌面，
                  // 可多选）。截图走 Ctrl+V（输入框里直接贴上剪贴板的图）；
                  // 右键菜单粘贴文本即可。
                  IconButton(
                    onPressed: _pickFiles,
                    tooltip: '贴图片/视频',
                    iconSize: Tokens.iconMd,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(36, 36),
                      foregroundColor: scheme.onSurfaceVariant,
                    ),
                    icon: const tabler.Photo(),
                  ),
                  const SizedBox(width: Tokens.spaceXs),
                  // `Expanded`（不是 Flexible）：状态文案吃掉左侧剩余宽度，把
                  // 发送钮顶到**最右边**——Flexible 只按内容取宽，按钮会紧贴文字
                  // （2026-10-17 用户截图实报）。
                  Expanded(child: _status(theme, focused, length)),
                  const SizedBox(width: Tokens.spaceSm),
                  IconButton(
                    onPressed: length > 0 ? _submit : null,
                    tooltip: _justSent ? '已记下' : '记下',
                    // 24 框（视觉 ≈18、描边 1.5）：36 的圆里正好，18 框在实机上
                    // 显得太轻（2026-10-17 用户定）。
                    iconSize: Tokens.iconMd,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(36, 36),
                      // 提交后 600ms 绿勾（瞬时确认），随后回纸飞机。
                      backgroundColor: _justSent
                          ? Bauhaus.green(theme.brightness)
                          : length > 0
                          ? scheme.primary
                          : scheme.surfaceContainerHighest,
                      foregroundColor: _justSent
                          ? Bauhaus.onAccent(theme.brightness)
                          : length > 0
                          ? scheme.onPrimary
                          : scheme.onSurfaceVariant,
                    ),
                    icon: _justSent
                        ? const tabler.Check()
                        // 纸飞机（原 ArrowUp）：灵感是"发出去"，不是"上传"。
                        : const tabler.Send2(),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// （待发附件暂存 2026-11-17 挪去 `media/pending_media.dart`：视频要"文件
//   条目不整读内存"，共享给笔记/画布的那份落盘逻辑也在那里。）

// ───────────────────────────── 灵感卡 ─────────────────────────────

/// 卡片墙里的一张灵感卡（2026-11-17 由时间流的「行」改版，同日三次收口）。
///
/// - **自适应高 + 全文零截断**：内容就是全部版面（2026-11-17 用户定"看全部"）。
///   右上角「N 图」「N 视频」角标（有附件才有：这是内容信号；视频 Tier 0 起
///   分开计数）；
/// - **双击**就地编辑（同列宽、随内容长高，不跨列），`Esc` / `Ctrl+Enter`
///   保存收起——单击不编辑（2026-11-17 用户定，防误触），右键菜单「编辑」、
///   键盘 Enter 同一入口。**时间与「更多」只在编辑态**的底部条里出现；
/// - **右键**弹动作菜单（复制 / 转为 / 删除红字，锚在光标处）——墙上最快的
///   操作入口，零版面成本（2026-11-16 起，2026-11-17 用户定保留）；
/// - 多选模式：勾选框覆盖在左上角；归档条目只读、降对比、保留细脚注
///   （「归档于 …」）——**不设删除**（2026-11-17 用户定：归档 = 已转为
///   笔记/画布，内容有落地，这里是历史记录）。

/// 按 id **稳定**分配便签色下标（确定性 hash，不依赖 Dart 的 `hashCode`
/// 跨运行稳定性）：同一条灵感永远同色、相邻几乎必然不同色 ⇒ 一眼区分。
/// public 供测试直接钉映射语义（确定性 + 分布）。
int noteIndexOf(String id) {
  int h = 0;
  for (final int c in id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h % Bauhaus.noteSwatchCount;
}

class _StreamCard extends ConsumerStatefulWidget {
  const _StreamCard({
    super.key,
    required this.item,
    required this.archived,
    required this.selectMode,
    required this.selected,
    required this.expanded,
    required this.onExpandChanged,
    this.onToggleSelect,
  });

  // （等高 `tileHeight` 2026-11-17 撤：用户定"两边各自自适应高度，不要等高"
  //   ——行对齐在矮卡旁留白太多；真瀑布下高度全由内容决定。）

  final StreamItem item;
  final bool archived;
  final bool selectMode;
  final bool selected;

  /// 就地编辑（同列宽、随内容长高）。归档条目不可编辑。
  final bool expanded;
  final ValueChanged<bool> onExpandChanged;
  final VoidCallback? onToggleSelect;

  @override
  ConsumerState<_StreamCard> createState() => _StreamCardState();
}

class _StreamCardState extends ConsumerState<_StreamCard> {
  final FocusNode _rowFocus = FocusNode();
  final FocusNode _editFocus = FocusNode();
  final TextEditingController _editController = TextEditingController();
  bool _hover = false;

  /// 指针按在卡内（含按下未放）。点「更多」时输入框在**按下瞬间**失焦、菜单
  /// 要到抬起才开——失焦即收会把按钮连编辑态一起卸载（2026-11-17 用户实报
  /// "点更多就关卡"）。[_onEditFocusChange] 靠这个标志区别"点卡内控件"
  /// （焦点暂离，不收）与"点到卡外"（保存收起）。
  bool _pressInCard = false;

  /// 菜单打开期间保持"悬浮态"：鼠标移进菜单时 [MouseRegion] 会触发 onExit，
  /// 只看 `_hover` 会让操作簇在弹窗打开的瞬间消失（2026-10-17 用户实报）。
  bool _menuOpen = false;

  @override
  void initState() {
    super.initState();
    _editFocus.addListener(_onEditFocusChange);
  }

  @override
  void dispose() {
    _editFocus.removeListener(_onEditFocusChange);
    _rowFocus.dispose();
    _editFocus.dispose();
    _editController.dispose();
    super.dispose();
  }

  void _expand() {
    if (widget.archived || widget.selectMode) return;
    _editController.text = widget.item.text;
    widget.onExpandChanged(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
  }

  /// 失焦即收，但**一帧后再判**（2026-11-17 bug 修复）：点「更多」时输入框在
  /// 按下瞬间失焦、菜单抬起才开，立即收会把按钮连编辑态一起卸载（用户实报
  /// "点更多就关卡"）。指针还按在卡上（点卡内控件）或菜单 / 确认框开着 ⇒
  /// 焦点只是暂离，不收；点到卡外（含切别的卡）才保存收起。
  void _onEditFocusChange() {
    if (_editFocus.hasFocus || !widget.expanded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.expanded) return;
      if (_menuOpen || _pressInCard) return;
      unawaited(_saveAndCollapse());
    });
  }

  Future<void> _saveAndCollapse() async {
    final String text = _editController.text;
    // 允许清空：flomo 式——已有卡片可清成空，空卡留着、输入态保留、不弹错。
    // 空文本直接写回 store（`StreamStore.update` 已放行空）。
    if (text.trim() != widget.item.text.trim()) {
      await ref.read(streamProvider.notifier).edit(widget.item.id, text);
    }
    // 收尾只通知"自己收起"：换卡时这份异步回调可能晚于新卡的展开，
    // 父级 [_setExpanded] 用 id 守卫，不会把新卡挤回去。
    if (mounted) widget.onExpandChanged(false);
  }

  /// 菜单动作的统一入口：动作全程挂"菜单开着"（`delete` 的确认框在**卡外**、
  /// 会触发失焦，不挂起会把卡收掉），完事把焦点还给输入框、重挂"失焦即收"。
  Future<void> _runMenuAction(String value) async {
    if (!mounted) return;
    setState(() => _menuOpen = true);
    try {
      await _onMenu(value);
    } finally {
      if (mounted) {
        setState(() => _menuOpen = false);
        _refocusEditor();
      }
    }
  }

  void _refocusEditor() {
    if (mounted && widget.expanded && !_editFocus.hasFocus) {
      _editFocus.requestFocus();
    }
  }

  /// 复制到系统剪贴板（纯文本）。**不归档**——复制不等于"在应用里使用"，
  /// 随手复制一下不该让条目从收件箱消失（2026-10-18 用户定）。
  Future<void> _copyToClipboard() async {
    final String text = widget.item.text.trim();
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('没有可复制的文字')));
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
  }

  Future<void> _onMenu(String value) async {
    final String id = widget.item.id;
    switch (value) {
      case 'edit':
        // 读态右键菜单「编辑」（2026-11-17 用户定）：与双击、键盘 Enter 同入口。
        _expand();
      case 'copy':
        await _copyToClipboard();
      case 'to-note':
        await streamToNewNote(context: context, streamId: id);
      case 'to-canvas':
        await streamToNewCanvas(context: context, streamId: id);
      case 'delete':
        if (await confirmTrashStream(context, 1) && mounted) {
          await ref.read(streamProvider.notifier).trash(id);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 这条灵感贴的图（视频在第二步接入）；落库即不变，MVP 不编辑附件。
    final List<StreamAttachment> attachments = ref.watch(
      streamAttachmentsProvider(widget.item.id),
    );
    return MouseRegion(
      onEnter: (_) {
        if (mounted && !_hover) setState(() => _hover = true);
      },
      onExit: (_) {
        if (mounted && _hover) setState(() => _hover = false);
      },
      child: Listener(
        // 见 [_pressInCard]：按下置位在失焦之前（Listener 在命中链里先于
        // TextField 的 TapRegion 收到事件），抬起清位。
        onPointerDown: (_) => _pressInCard = true,
        onPointerUp: (_) {
          _pressInCard = false;
          // 点完卡内控件把焦点还给输入框：重挂"失焦即收"，否则点过一次
          // 卡内按钮后（焦点已丢）再点卡外不会触发收起。
          if (mounted &&
              widget.expanded &&
              !_menuOpen &&
              !_editFocus.hasFocus) {
            _editFocus.requestFocus();
          }
        },
        onPointerCancel: (_) => _pressInCard = false,
        child: widget.expanded
            ? _buildEditor(theme, attachments)
            : _buildView(theme, attachments),
      ),
    );
  }

  Widget _buildView(ThemeData theme, List<StreamAttachment> attachments) {
    final ColorScheme scheme = theme.colorScheme;
    final Brightness brightness = theme.brightness;
    final bool marked = widget.selected;
    // 图/视频**分开计数**（视频 Tier 0 起）：角标是内容信号，混成一个数会
    // 把"这条有视频"这个信号抹掉。
    final int imageCount = attachments
        .where((StreamAttachment a) => !a.isVideo)
        .length;
    final int videoCount = attachments
        .where((StreamAttachment a) => a.isVideo)
        .length;
    // 菜单打开也算"悬浮中"：否则弹窗一开、按钮就滑走了。
    final bool active = _hover || _menuOpen;
    // hover 的回答是"卡片迎上来"（放大 1.025，见下方 `TweenAnimationBuilder`）
    // ——呼应点击"放大看全部"，一套语言（2026-11-17 用户定，替换旧的轻推左移）。
    // 归档条目不参与任何悬浮动效（它已经"放下了"）。
    final bool lifted = active && !widget.archived && !widget.selectMode;
    // hover **不画描边**（2026-10-17 用户定：发丝边在常显底色上像"框"）。
    // 描边只留给选中——并且必须是单一颜色：`borderRadius` 与"四边异色"不能共存。
    final Color edge = marked
        ? scheme.primary.withValues(alpha: 0.4)
        : Colors.transparent;
    // **便签色**（2026-11-19 用户定）：满墙同色毫无区分，改 Google Keep 式
    // 多彩便签——每条按 id 稳定分配一个 Bauhaus 便签色（零操作、相邻几乎必然
    // 不同色 ⇒ 一眼区分），不违背灵感"低摩擦收件箱"。
    //
    // 底色**烤实**（alphaBlend 进 surface）：半透明底会让对比度检查把文字算在
    // "未知/低对比"背景上，a11y 会红；而且行底本来就压在 panel 的 surface 上，
    // 合成结果完全相同（2026-10-17 教训沿用）。
    final int noteIdx = noteIndexOf(widget.item.id);
    final Color rowFill = Color.alphaBlend(
      AppTheme.hoverOverlay(brightness),
      scheme.surface,
    );
    // 便签纸底（Keep 式粉彩纸片）；归档退灰（中性，已"放下"）；选中压过走 primary。
    // hover **不换底色**（2026-11-19 用户定：只放大就够，不变色）。
    final Color bg;
    if (marked) {
      bg = scheme.primaryContainer.withValues(alpha: 0.35);
    } else if (widget.archived) {
      bg = rowFill;
    } else {
      bg = Bauhaus.noteSwatch(brightness, noteIdx);
    }

    // Semantics **下移到内容**（见下方 _stripeAround 的 child）：它的 label 边界
    // 只包正文、不含左侧色带 ⇒ Flutter 的 `textContrastGuideline` 不会把装饰色带
    // 误当"文字前景"采样（否则饱和便签色压在 tint 底上被判假低对比、a11y 红）。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 单击**不编辑**（2026-11-17 用户定，防误触）：单击只在多选模式勾选。
      // 归档条目**不参与多选**（否则已处理的旧条目会被混进"合并成新笔记"里）。
      onTap: widget.selectMode
          ? (widget.archived ? null : widget.onToggleSelect)
          : null,
      // 双击 = 进编辑；与右键菜单「编辑」、键盘 Enter（下方 [Focus.onKeyEvent]）
      // 同一入口。
      onDoubleTap: widget.selectMode || widget.archived ? null : _expand,
      // 右键 = 行级动作菜单（与 hover「更多」同款，锚在光标处）。
      // 归档行、多选模式都照常弹（2026-11-16 用户定）。
      onSecondaryTapDown: (details) =>
          unawaited(_showRowMenu(details.globalPosition)),
      child: FocusRing(
        focusNode: _rowFocus,
        borderRadius: BorderRadius.circular(Tokens.radiusSm),
        child: Focus(
          focusNode: _rowFocus,
          onKeyEvent: (FocusNode _, KeyEvent event) {
            if (event is! KeyDownEvent ||
                event.logicalKey != LogicalKeyboardKey.enter) {
              return KeyEventResult.ignored;
            }
            if (widget.archived) return KeyEventResult.ignored;
            if (widget.selectMode) {
              widget.onToggleSelect?.call();
            } else {
              _expand();
            }
            return KeyEventResult.handled;
          },
          // **放大**：hover 放大到 1.025（2026-11-17 用户定，替换旧的"轻推
          // 左移"）——这张卡的点击动作是"放大看全部"，hover 放大正是它的预告。
          //
          // 数字的账：404 宽卡 ×1.025 ⇒ 每侧溢出 ~5px，落进列距 20 / 页边距
          // 24 的空当里——不撞邻卡、不贴视口裁剪边；高向每侧 ~1px 量级。
          // 圆心缩放、四向均匀；文字随矩阵重绘、不糊（不是缩放已栅格化层）。
          // 📌 2026-10-17 旧注释警告"缩放会被 ListView 切边"——那是当年行铺满
          // 列宽、无空当时的账；卡片墙有列距 + 页边距，5px 溢出安全。
          // 变换不改布局尺寸 ⇒ 邻卡不重排、`getSize` 读数不变；命中区跟着
          // 缩放后的范围走，不会"看得见点不到"。
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: lifted ? 1.0 : 0.0),
            curve: Curves.easeOut,
            duration: Tokens.durationHover,
            builder: (BuildContext context, double t, Widget? child) =>
                Transform.scale(scale: 1.0 + 0.025 * t, child: child),
            child: AnimatedContainer(
              curve: Curves.easeOut,
              duration: Tokens.durationHover,
              // 自适应高（2026-11-17 二次收口）：内容即全部版面、零截断——
              // 等高卡撤了（行对齐会在矮卡旁留白）；长卡只把这一列拉长。
              // 裁圆角：让内容贴合卡片圆角（不露直角）。
              clipBehavior: Clip.antiAlias,
              padding: const EdgeInsets.fromLTRB(
                Tokens.spaceSm,
                Tokens.spaceSm,
                Tokens.spaceSm,
                Tokens.spaceSm,
              ),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(Tokens.radiusMd),
                // 描边**永远占位**（透明也算 1px）：宽度恒定 ⇒ hover 不挤动文字。
                border: Border.all(color: edge),
              ),
              // 归档行只读、只在聚焦视图出现；普通卡全文上墙——高度都随
              // 内容（真瀑布，2026-11-17 用户定）。左侧便签色带由
              // [_stripeAround] 包在内容外（Positioned，不参与卡高）。
              child: _stripeAround(
                child: Semantics(
                  button: !widget.archived,
                  selected: widget.selectMode ? marked : null,
                  label: widget.item.text,
                  child: widget.archived
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            ExcludeSemantics(
                              child: Text(
                                widget.item.text.trim().isNotEmpty
                                    ? widget.item.text
                                    : '（空）',
                                maxLines: 8,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: Bauhaus.inkMuted(brightness),
                                  height: 1.6,
                                ),
                              ),
                            ),
                            const SizedBox(height: Tokens.spaceSm),
                            // 归档行的细脚注。**不设删除**（2026-11-17 用户定：
                            // 归档 = 已转为笔记/画布，内容有落地，这里是历史记录）。
                            ExcludeSemantics(
                              child: Text(
                                '归档于 ${_dateClock(widget.item.archivedAt ?? widget.item.createdAt)}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: Bauhaus.inkMuted(brightness),
                                ),
                              ),
                            ),
                          ],
                        )
                      : Stack(
                          children: <Widget>[
                            // 正文 **全文零截断**（2026-11-17 用户定"看全部"）——
                            // 一眼概览的原始目标就是不截断。它是 Stack 里唯一
                            // 非定位子节点 ⇒ 卡高由内容决定。正文由外层
                            // [Semantics.label] 朗读（整卡一起念），这里排除，免得
                            // "标签 + 正文"念两遍。
                            ExcludeSemantics(
                              child: Text(
                                // 空卡（flomo 式，清空后保留）：淡灰占位，保证
                                // 仍可见、可点、能重新编辑，而不是一行纯空白。
                                widget.item.text.trim().isNotEmpty
                                    ? widget.item.text
                                    : '（空）',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: widget.item.text.trim().isEmpty
                                      ? Bauhaus.inkMuted(brightness)
                                      : Bauhaus.ink(brightness),
                                  height: 1.6,
                                ),
                              ),
                            ),
                            // 附件计数角标（右上角常显）：「这条有图/视频」是
                            // **内容信号**不是元数据——长文里附件往往是这条的重点
                            // （2026-11-17 用户定脚注撤、角标留；视频 Tier 0 起
                            // 图/视频分开计数）。
                            if (attachments.isNotEmpty)
                              Positioned(
                                top: 0,
                                right: 0,
                                child: ExcludeSemantics(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      if (imageCount > 0)
                                        _countChip(
                                          theme,
                                          brightness,
                                          '$imageCount 图',
                                        ),
                                      if (videoCount > 0) ...<Widget>[
                                        if (imageCount > 0)
                                          const SizedBox(
                                            width: Tokens.spaceXxs,
                                          ),
                                        _countChip(
                                          theme,
                                          brightness,
                                          '$videoCount 视频',
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            // 多选勾选框：覆盖在左上角（多选模式才出现）——
                            // 脚注撤掉后勾选指示挪这儿，合并入口仍靠它。
                            if (widget.selectMode)
                              Positioned(
                                top: 0,
                                left: 0,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: bg,
                                    borderRadius: BorderRadius.circular(
                                      Tokens.radiusXxs,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(2),
                                    child: _SelectBox(selected: marked),
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 左侧便签色带包裹：4px 实带（hover 加宽到 6）贴卡片左缘当"色标"。
  ///
  /// `Positioned` 满高 ⇒ 不参与卡高计算（卡高仍由内容决定）；被外层
  /// `AnimatedContainer(clipBehavior: Clip.antiAlias)` 裁到圆角内，贴合不露直角。
  ///
  /// 色带语义（2026-11-19）：常态 = 便签色（按 id 稳定分配，饱和点睛）；
  /// hover 加宽到 6（"迎上来"）；选中转 primary（选中语义压过便签色）；归档退灰。
  ///
  /// [pinned]：编辑态传 true —— 色带固定不随 hover 加宽（编辑时鼠标常驻卡上，
  /// 随 hover 抖会一直保持宽态）。
  /// 左侧便签色带**已去掉**（2026-11-19 用户定：色带遮住文字）——便签观感改由
  /// 彩色 tint 底承担（见 [_buildView] 的 bg），不再画色带。保留方法签名作直通，
  /// 调用点结构不动。
  Widget _stripeAround({required Widget child, bool pinned = false}) => child;

  /// 角标芯片（右上角常显）：图 / 视频计数各一枚。
  Widget _countChip(ThemeData theme, Brightness b, String label) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: Tokens.spaceXs,
      vertical: 1,
    ),
    decoration: BoxDecoration(
      color: Bauhaus.surface(b),
      borderRadius: BorderRadius.circular(Tokens.radiusXxs),
    ),
    child: Text(
      label,
      style: theme.textTheme.labelSmall?.copyWith(color: Bauhaus.inkMuted(b)),
    ),
  );

  /// 灵感附件条：图片缩略图、视频文件片（双击系统播放器），左对齐、可横向滚动。
  ///
  /// 视频 Tier 0（2026-11-17）：不内联播放、不生成缩略图——文件片双击交给
  /// 系统播放器（编解码覆盖反而更好），升级应用内播放时只换文件片的双击行为。
  Widget _attachmentStrip(ThemeData theme, List<StreamAttachment> items) {
    return Padding(
      padding: const EdgeInsets.only(top: Tokens.spaceXs),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            for (final StreamAttachment a in items)
              Padding(
                padding: const EdgeInsets.only(right: Tokens.spaceXs),
                child: a.isVideo
                    ? AttachmentFileChip(
                        path: a.path,
                        label: p
                            .extension(a.path)
                            .replaceFirst('.', '')
                            .toUpperCase(),
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(Tokens.radiusSm),
                        child: Image.file(
                          File(a.path),
                          width: 96,
                          height: 96,
                          fit: BoxFit.cover,
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }

  /// hover 操作入口：只有「更多」一枚（复制已收进它的菜单，2026-10-20 用户定；
  /// 归档自动，不在这里）。
  ///
  /// 同一份菜单也由行上**右键**唤出（2026-11-16 用户定，见 [_showRowMenu]）。
  ///
  /// 2026-10-17 调整：
  /// - **去掉「引用到笔记」**——引用应从笔记 / 画布那一端发起（在正文里挑一条
  ///   灵感），而不是在灵感列表里逐个推出去；
  /// - 图标 24 → **20 框**（视觉 ≈15），槽 24。
  ///
  /// 📌 2026-11-17 起只出现在**编辑态**的底部条（读态卡只有内容）；
  /// 卡上右键菜单是同款 actions 的快捷入口。
  Widget _actions(ThemeData theme, {Key? key}) {
    // 只剩一枚图标，靠右对齐，位置与原来的「更多」一致。
    return Align(
      key: key,
      alignment: Alignment.centerRight,
      child: _popupSlot(
        tooltip: '更多',
        icon: const tabler.Dots(
          height: Tokens.iconMdSm,
          width: Tokens.iconMdSm,
        ),
        items: _menuItems(theme.colorScheme),
      ),
    );
  }

  /// 「更多」菜单的条目：编辑态的「更多」与**右键**共用这一份（2026-11-16）。
  ///
  /// [withEdit]：读态右键菜单给「编辑」首项（2026-11-17 用户定：双击编辑 +
  /// 右键编辑入口）；编辑态的「更多」不给（已经在编辑）。归档 / 多选模式
  /// 也不给（归档只读，多选点卡是勾选）。
  ///
  /// [withDelete]：归档条目**不给删除**（2026-11-17 用户定：归档 = 已转为
  /// 笔记/画布，内容有落地，这里只是历史记录）。「删除」给 [ColorScheme.error]
  /// 红字——两处删除入口（本菜单 / 批量工具条）视觉统一，破坏性动作一眼可辨。
  /// 确认框与软删语义在 [_onMenu] 的 `delete` 分支（`confirmTrashStream` ⇒
  /// 进回收站，可恢复）。
  List<PopupMenuEntry<String>> _menuItems(
    ColorScheme scheme, {
    bool withEdit = false,
    bool withDelete = true,
  }) => <PopupMenuEntry<String>>[
    if (withEdit) ...<PopupMenuEntry<String>>[
      const PopupMenuItem(value: 'edit', child: Text('编辑')),
      const PopupMenuDivider(),
    ],
    const PopupMenuItem(value: 'copy', child: Text('复制')),
    const PopupMenuDivider(),
    const PopupMenuItem(value: 'to-note', child: Text('转为新笔记')),
    const PopupMenuItem(value: 'to-canvas', child: Text('转为新画布')),
    if (withDelete) ...<PopupMenuEntry<String>>[
      const PopupMenuDivider(),
      PopupMenuItem(
        value: 'delete',
        child: Text('删除', style: TextStyle(color: scheme.error)),
      ),
    ],
  ];

  /// 右键弹同一份「更多」菜单，锚在**光标处**（不是图标下方）。
  ///
  /// 归档行、多选模式照常弹（2026-11-16 用户定）：右键是行级动作的快捷入口，
  /// 与左键（展开编辑 / 勾选）不冲突。`_menuOpen` 全程为 true ⇒ 弹窗期行
  /// 保持悬浮态（与 [_popupSlot] 的 onOpened / onCanceled 同一口径）。
  Future<void> _showRowMenu(Offset globalPos) async {
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final Offset local = overlay.globalToLocal(globalPos);
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromLTWH(local.dx, local.dy, 0, 0),
      Offset.zero & overlay.size,
    );
    setState(() => _menuOpen = true);
    final String? value = await showMenu<String>(
      context: context,
      position: position,
      items: _menuItems(
        Theme.of(context).colorScheme,
        withEdit: !widget.archived && !widget.selectMode,
        // 归档条目不设删除（2026-11-17 用户定）。
        withDelete: !widget.archived,
      ),
    );
    if (!mounted) return;
    if (value == null) {
      setState(() => _menuOpen = false);
      _refocusEditor();
      return;
    }
    // `_runMenuAction` 接管 `_menuOpen` 与收尾（含 delete 确认框期间挂起）。
    await _runMenuAction(value);
  }

  /// 动作槽边长（热区）：24（= a11y 触达下限）。图标 20 框居中，留 2。
  static const double _actionSlot = 24;

  Widget _popupSlot({
    required String tooltip,
    required Widget icon,
    required List<PopupMenuEntry<String>> items,
  }) {
    return PopupMenuButton<String>(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      // 弹窗期保持行的悬浮态（鼠标移进菜单会触发 onExit）。
      onOpened: () => setState(() => _menuOpen = true),
      onCanceled: () {
        setState(() => _menuOpen = false);
        _refocusEditor();
      },
      // `_runMenuAction` 接管 `_menuOpen`：动作全程挂起"失焦即收"
      //（`delete` 的确认框在卡外、会触发失焦），完事还焦点给输入框。
      onSelected: (String value) => unawaited(_runMenuAction(value)),
      itemBuilder: (BuildContext _) => items,
      // 用 child 而不是 icon：icon 版内部固定 48 的 IconButton，热区过大。
      child: SizedBox(
        width: _actionSlot,
        height: _actionSlot,
        child: Center(child: icon),
      ),
    );
  }

  Widget _buildEditor(ThemeData theme, List<StreamAttachment> attachments) {
    final ColorScheme scheme = theme.colorScheme;
    final Brightness brightness = theme.brightness;
    return Focus(
      onKeyEvent: (FocusNode _, KeyEvent event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final bool escape = event.logicalKey == LogicalKeyboardKey.escape;
        final bool save =
            event.logicalKey == LogicalKeyboardKey.enter &&
            HardwareKeyboard.instance.isControlPressed;
        if (escape || save) {
          unawaited(_saveAndCollapse());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        // 裁圆角：让左侧便签色带贴合（与读态同法）。
        clipBehavior: Clip.antiAlias,
        // 左内距让开色带宽：文字不被色带压住。
        padding: const EdgeInsets.fromLTRB(
          Tokens.spaceSm,
          Tokens.spaceSm,
          Tokens.spaceSm,
          Tokens.spaceSm,
        ),
        decoration: BoxDecoration(
          // 行底色现在**常显**，编辑态反过来用纯 surface：正在改的那条像一张
          // 白纸压在一叠浅灰纸片上，靠色差自然浮出来（仍无阴影）。
          color: scheme.surface,
          borderRadius: BorderRadius.circular(Tokens.radiusSm),
          // 整圈主色发丝边：整浮动的语言一致（不再用左侧单竖条），也不踩
          // "圆角 + 四边异色"的 paint 断言。
          border: Border.all(color: scheme.primary),
        ),
        // 左侧便签色带（pinned：编辑态固定 4px 不随 hover 抖）当"我是哪张"的锚。
        child: _stripeAround(
          pinned: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: _editController,
                focusNode: _editFocus,
                autofocus: true,
                minLines: 1,
                maxLines: null,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Bauhaus.ink(brightness),
                  height: 1.6,
                ),
                cursorColor: scheme.primary,
                decoration: const InputDecoration(
                  hintText: '改点什么…',
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              // 编辑态看附件全貌：缩略图条（读态只报个数角标）。
              if (attachments.isNotEmpty) _attachmentStrip(theme, attachments),
              const SizedBox(height: Tokens.spaceXs),
              // 编辑态的元信息条：**时间 + 更多**都只在这里出现（2026-11-17 用户定
              // "内容是主要的"——读态卡不带脚注，操作挪进编辑态；右键菜单仍在卡上）。
              Row(
                children: <Widget>[
                  // 时间是装饰性 meta：不参与朗读（卡标签已含正文）。
                  ExcludeSemantics(
                    child: Text(
                      _dateClock(widget.item.createdAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Bauhaus.inkMuted(brightness),
                      ),
                    ),
                  ),
                  const SizedBox(width: Tokens.spaceSm),
                  Flexible(
                    child: Text(
                      'Esc 保存 · Ctrl+Enter 保存',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Bauhaus.inkMuted(brightness),
                      ),
                    ),
                  ),
                  const Spacer(),
                  _actions(theme),
                  TextButton(
                    onPressed: _saveAndCollapse,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: theme.textTheme.labelMedium,
                    ),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _clock(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }

  /// 卡脚注的日期时间：`11-14 17:52`（2026-11-17 去日期组标后，日期落卡内）。
  String _dateClock(DateTime t) => '${t.month}-${t.day} ${_clock(t)}';
}

/// 选择态勾选框：16×16、2px 硬边、圆角 4（包豪斯几何，不用 Material Checkbox
/// 那套 18px 的圆头内填充，与本页的"纸面"气质更贴）。
class _SelectBox extends StatelessWidget {
  const _SelectBox({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 16,
      height: 16,
      margin: const EdgeInsets.only(top: 3),
      decoration: BoxDecoration(
        color: selected ? scheme.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(Tokens.radiusXxs),
        border: Border.all(
          color: selected ? scheme.primary : scheme.outline,
          width: 2,
        ),
      ),
      child: selected
          ? tabler.Check(
              height: Tokens.iconXxs,
              width: Tokens.iconXxs,
              color: scheme.onPrimary,
            )
          : null,
    );
  }
}
