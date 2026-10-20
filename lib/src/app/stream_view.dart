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
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:uuid/uuid.dart';

import '../domain/note.dart';
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
/// ## 交互
/// - hover 一行：铺 [AppTheme.hoverOverlay] + 左侧 2px 蓝竖条 + 右侧操作簇浮出；
/// - 点击行：就地编辑（`Esc` / `Ctrl+Enter` 保存），不是"放大成卡片"；
/// - 选择：工具行换成「已选 N 条 / 取消」，底部浮出唯一的实色按钮「合并为新笔记」；
/// - 已处理：列表末尾一条折叠行；归档条目降对比、只读、行尾「拿回」。
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

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<StreamItem?> _capture(String text, List<StreamAttachmentInput> media) async {
    if (media.isEmpty) {
      await ref.read(streamProvider.notifier).add(text);
      return null;
    }
    return ref.read(streamProvider.notifier).addMedia(text, media);
  }

  bool _matches(StreamItem item) {
    final String q = _query.trim().toLowerCase();
    return q.isEmpty || item.text.toLowerCase().contains(q);
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
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('已复制 ${_selected.length} 条')));
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
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('已移入回收站（${ids.length} 条）')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<StreamItem>> streamAsync = ref.watch(streamProvider);
    final List<StreamItem> all = streamAsync.value ?? const <StreamItem>[];
    // 从笔记里的灵感引用跳过来：只显示那一条（`null` = 正常时间流）。
    final String? focusId = ref.watch(streamFocusProvider);
    final List<StreamItem> scoped = focusId == null
        ? all
        : <StreamItem>[
            for (final StreamItem i in all)
              if (i.id == focusId) i,
          ];
    // 目标已删（引用断链）：清掉聚焦，回到正常流。
    // ⚠️ 必须等数据**装载完成**再判：首帧 `value` 还是 null，直接判会把刚设的
    // 聚焦当成"目标不存在"清掉（一开始就是这么写错的）。
    if (focusId != null && streamAsync.hasValue && scoped.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(streamFocusProvider.notifier).clear();
      });
    }
    final List<StreamItem> open = <StreamItem>[
      for (final StreamItem i in scoped)
        if (!i.archived && _matches(i)) i,
    ];
    // 已处理**不在这里**：它是一整页（`StreamLedgerView`，2026-10-18 P1）。
    // 工具栏的「归档 N」入口要报**归档总数**，不能参与搜索过滤：否则一搜
    // 不到归档条目，按钮就消失、右侧操作簇跟着跳（2026-10-20 实报）。
    final List<StreamItem> archived = <StreamItem>[
      for (final StreamItem i in scoped)
        if (i.archived && _matches(i)) i,
    ];
    final int archivedTotal = scoped
        .where((StreamItem i) => i.archived)
        .length;
    // 时间流永远只有"当下"；聚焦（从引用跳来）时只给那一条。
    final List<StreamItem> shown = focusId != null ? scoped : open;
    // 选择模式全选的候选：**当前可见**的待处理条目（含搜索过滤）。
    final List<String> visibleIds = <String>[
      for (final StreamItem i in open) i.id,
    ];
    final bool empty = shown.isEmpty;
    // 聚焦：清掉搜索词，否则"引用的那条"可能被上次的搜索过滤掉，页面变成"什么都没有"。
    ref.listen<String?>(streamFocusProvider, (String? _, String? next) {
      if (next != null && _query.isNotEmpty) {
        _search.clear();
        setState(() => _query = '');
      }
    });
    final List<_Entry> entries = empty
        ? const <_Entry>[]
        // 聚焦视图是一条条的清单，不需要日期分组。
        : _entries(shown, withDates: focusId == null);

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
            _pageColumn(_selectionToolbar(visibleIds))
          else if (_query.isNotEmpty ||
              open.isNotEmpty ||
              archived.isNotEmpty)
            _pageColumn(_listHeader(open.length, archivedTotal)),
          if (focusId != null ||
              _selectMode ||
              _query.isNotEmpty ||
              open.isNotEmpty ||
              archived.isNotEmpty)
            const SizedBox(height: Tokens.spaceSm),
          // 书写区**永远在**：即便正在看归档面板，这一页的主任务还是"记"。
          _pageColumn(_CaptureBar(onSubmit: _capture)),
          // 输入块下方 24：与页首 48 一起构成长短边，书写区自然浮在"纸面上"。
          const SizedBox(height: Tokens.spaceXl),
          Expanded(
            child: Stack(
              children: <Widget>[
                if (empty)
                  _pageColumn(
                    _StreamEmpty(
                      searching: _query.trim().isNotEmpty,
                      archivedCount: archived.length,
                    ),
                  )
                else
                  // `builder`（不是 `children`）：条目再多也只构建视口内那几行
                  // ——之前每次 hover / 输入都会重建全部卡片（2026-10-17 复查）。
                  //
                  // **列表铺满整卡宽**、条目在内部居中到 640（2026-10-18 用户定）：
                  // ① 滚动条由 `MaterialScrollBehavior` 自动挂在 Scrollable 边缘
                  //    ⇒ 它贴在**窗口/卡片右缘**，而不是缩在 640 列里那条"小细线"；
                  // ② 鼠标放在两侧留白上也能滚—— Scrollable 的热区就是整卡宽，
                  //    不再只有中间那条（用户实报"以为不能滚"）。
                  ListView.builder(
                    padding: const EdgeInsets.only(bottom: 72),
                    itemCount: entries.length,
                    itemBuilder: (BuildContext context, int i) =>
                        _pageColumn(
                          switch (entries[i]) {
                            _DateEntry(:final String label) => _DayHeader(
                              label: label,
                            ),
                            _ItemEntry(
                              :final StreamItem item,
                              archived: final bool a,
                            ) => _row(item, archived: a),
                          },
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

  /// 页面内容的**水平栅格**：左右 `gridMargin` 呼吸 + 640 阅读列居中。
  ///
  /// 头部 / 书写区 / 每一条灵感都走它 ⇒ 三者的左缘永远同在一条竖线上；
  /// 而**滚动视口本身是整卡宽**（见 build 里的 ListView），滚动条因此贴边、
  /// 留白也能滚。
  Widget _pageColumn(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Tokens.gridMargin),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        // **撑到列宽**：Center 给子节点的是松约束（0..640），不撑的话输入框
        // 会缩成自己的内容宽，左右留白就歪了。
        child: SizedBox(width: double.infinity, child: child),
      ),
    ),
  );

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
            Row(children: <Widget>[Expanded(child: count), selectAll, cancel]),
            const SizedBox(height: Tokens.spaceXs),
            Align(alignment: Alignment.centerRight, child: actions),
          ],
        );
      },
    );
  }

  // ── 时间流 ───────────────────────────────────────────────────────────

  /// 拍平成`[日期标, 条目, 条目…]`，供 `ListView.builder`。
  ///
  /// [withDates]：时间流需要日期分组；「已处理」清单与引用聚焦都是一条条列出来，
  /// 分组只会让人以为它们还在时间轴上。
  List<_Entry> _entries(List<StreamItem> items, {required bool withDates}) {
    final List<_Entry> out = <_Entry>[];
    String? lastDay;
    for (final StreamItem item in items) {
      if (withDates) {
        final String day = _dayKey(item.createdAt);
        if (day != lastDay) {
          out.add(_DateEntry(_dayLabel(item.createdAt)));
          lastDay = day;
        }
      }
      out.add(_ItemEntry(item, archived: item.archived));
    }
    return out;
  }

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

  /// 单条灵感：**铺满整列**（没有左侧日期栏，正文左缘 = 行内 padding 8 + 竖条 2）。
  ///
  /// 行间距 6：底色**常显**之后，相邻两行的色块会连成一条长带；6px 让每条是
  /// 独立的一张"纸片"，又还没松到把一组日期拆成两份（2026-10-17 用户定）。
  Widget _row(StreamItem item, {bool archived = false}) => Padding(
    padding: const EdgeInsets.only(bottom: Tokens.spaceXs + Tokens.spaceXxs),
    child: _StreamRow(
      key: ValueKey<String>(item.id),
      item: item,
      archived: archived,
      selectMode: _selectMode,
      selected: _selected.contains(item.id),
      onToggleSelect: () => _toggleSelected(item.id),
    ),
  );

  static String _dayKey(DateTime t) => '${t.year}-${t.month}-${t.day}';

  static String _dayLabel(DateTime t) {
    final DateTime now = DateTime.now();
    final DateTime day = DateTime(t.year, t.month, t.day);
    final DateTime today = DateTime(now.year, now.month, now.day);
    final int diff = today.difference(day).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (day.year == today.year) return '${day.month} 月 ${day.day} 日';
    return '${day.year} 年 ${day.month} 月 ${day.day} 日';
  }
}

/// 列表里的一项：日期标题 / 一条灵感 / 「已处理」折叠行。
///
/// 拍平成一维再交给 `ListView.builder`——不为列表性能保留 widget 树。
sealed class _Entry {
  const _Entry();
}

class _DateEntry extends _Entry {
  const _DateEntry(this.label);
  final String label;
}

class _ItemEntry extends _Entry {
  const _ItemEntry(this.item, {this.archived = false});
  final StreamItem item;
  final bool archived;
}


/// 日期组标题（今天 / 昨天 / `12 月 31 日`）：单独一行、左对齐内容左缘，
/// 条目在它下面**铺满整列**。
class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 日期是**分类标题**：没有自己的底色、没有纸片，只是正文上方的一行字
    // （2026-10-17 用户定）。行的底色只在灵感卡上。
    return Padding(
      // 左缘对齐列表头的「N 条」（= 内容区左缘，0 缩进）：日期是这一段的标签，
      // 和上面的条数、下面的卡片同一条竖线，才有"段落"的读法（2026-10-17 用户定）。
      // 上下留 16 / 4：上边距撑开与上一组的距离，下边距只隔一条呼吸缝。
      padding: const EdgeInsets.only(
        top: Tokens.spaceLg,
        bottom: Tokens.spaceXs,
      ),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: Bauhaus.inkMuted(theme.brightness),
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}

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
  ) onSubmit;

  @override
  ConsumerState<_CaptureBar> createState() => _CaptureBarState();
}

class _CaptureBarState extends ConsumerState<_CaptureBar> {
  final TextEditingController _controller = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);

  /// 待发送附件：选图后先暂存，提交时才拷进私有目录（不发就不落盘，零孤儿）。
  final List<_PendingMedia> _pendingMedia = <_PendingMedia>[];

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
            _PendingMedia(bytes: img, ext: '.png', kind: 'image'),
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
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('没记下来，请重试')));
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
    return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
  }

  /// 文件选择器里挑图（桌面端原生对话框，`file_picker` 支持一次多选）。
  /// 默认打开**桌面**目录，贴近"截图刚存桌面"的随手导入场景。
  /// 视频在第二步接入，这里先只开图片（用户确认先做图片附件）。
  Future<void> _pickFiles() async {
    // 12.x：`pickFiles` 返回非空列表（取消则为空列表）；`allowMultiple` 已废弃
    // （本身就是多选取）。取消时循环直接不进，无需判空。
    final List<PlatformFile> files = await FilePicker.pickFiles(
      type: FileType.image,
      initialDirectory: _desktopDir,
    );
    if (!mounted) return;
    for (final PlatformFile f in files) {
      final String? path = f.path;
      if (path == null) continue;
      final Uint8List bytes = await File(path).readAsBytes();
      setState(
        () => _pendingMedia.add(
          _PendingMedia(bytes: bytes, ext: p.extension(path), kind: 'image'),
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
  Future<List<StreamAttachmentInput>> _materializeMedia() async {
    if (_pendingMedia.isEmpty) return const <StreamAttachmentInput>[];
    final String base = p.join(ref.read(appDataDirProvider), 'stream_media');
    await Directory(base).create(recursive: true);
    final List<StreamAttachmentInput> result = <StreamAttachmentInput>[];
    const Uuid uuid = Uuid();
    for (final _PendingMedia m in _pendingMedia) {
      final String ext = m.ext.isEmpty ? '.img' : m.ext;
      final String dest = p.join(base, '${uuid.v4()}$ext');
      await File(dest).writeAsBytes(m.bytes);
      result.add(StreamAttachmentInput(kind: m.kind, path: dest));
    }
    return result;
  }

  /// 待发送附件的预览条（提交前看一眼贴了什么）。
  Widget _pendingStrip(ThemeData theme) {
    final ColorScheme scheme = theme.colorScheme;
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
                  child: Image.memory(
                    _pendingMedia[i].bytes,
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                  ),
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
                      child: Icon(
                        Icons.close,
                        size: 14,
                        color: scheme.onError,
                      ),
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
                  // **贴图入口**：左下图钉，点一下直接打开图片文件框（默认桌面，可多选）。
                  // 截图走 Ctrl+V（输入框里直接贴上剪贴板的图）；右键菜单粘贴文本即可。
                  IconButton(
                    onPressed: _pickFiles,
                    tooltip: '贴图片',
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

/// 待发送附件的暂存：选图后先留在这里，提交时才拷进私有目录。
///
/// 只存**解码后的字节 + 扩展名**（不存源文件句柄）——文件选择器 / 剪贴板两条
/// 来源都最终汇成字节，提交时统一落盘到 `stream_media/`。源截图被删也不影响。
class _PendingMedia {
  const _PendingMedia({
    required this.bytes,
    required this.ext,
    required this.kind,
  });
  final Uint8List bytes;
  final String ext; // 含点的扩展名，如 '.png'
  final String kind; // 'image' | 'video'
}

// ───────────────────────────── 灵感行 ─────────────────────────────

/// 一行灵感：**没有卡片边框**，静止透明；hover / 选中才铺底色与左侧蓝竖条。
///
/// - 点击就地编辑（`Esc` / `Ctrl+Enter` 保存），不是"放大成卡片"；
/// - hover 时右侧浮出「更多」（复制已收进菜单；**归档由使用/转换自动触发**，无手动钮）；
/// - 归档条目只读、降对比，行尾给「删除」。
class _StreamRow extends ConsumerStatefulWidget {
  const _StreamRow({
    super.key,
    required this.item,
    required this.archived,
    required this.selectMode,
    required this.selected,
    this.onToggleSelect,
  });

  final StreamItem item;
  final bool archived;
  final bool selectMode;
  final bool selected;
  final VoidCallback? onToggleSelect;

  @override
  ConsumerState<_StreamRow> createState() => _StreamRowState();
}

class _StreamRowState extends ConsumerState<_StreamRow> {
  final FocusNode _rowFocus = FocusNode();
  final FocusNode _editFocus = FocusNode();
  final TextEditingController _editController = TextEditingController();
  bool _hover = false;
  bool _expanded = false;

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
    setState(() => _expanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
  }

  void _onEditFocusChange() {
    if (!_editFocus.hasFocus && _expanded) {
      unawaited(_saveAndCollapse());
    }
  }

  Future<void> _saveAndCollapse() async {
    final String text = _editController.text;
    // 允许清空：flomo 式——已有卡片可清成空，空卡留着、输入态保留、不弹错。
    // 空文本直接写回 store（`StreamStore.update` 已放行空）。
    if (text.trim() != widget.item.text.trim()) {
      await ref.read(streamProvider.notifier).edit(widget.item.id, text);
    }
    if (mounted) setState(() => _expanded = false);
  }

  /// 复制到系统剪贴板（纯文本）。**不归档**——复制不等于"在应用里使用"，
  /// 随手复制一下不该让条目从收件箱消失（2026-10-18 用户定）。
  Future<void> _copyToClipboard() async {
    final String text = widget.item.text.trim();
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('没有可复制的文字')));
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
  }

  Future<void> _onMenu(String value) async {
    final String id = widget.item.id;
    switch (value) {
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
    return MouseRegion(
      onEnter: (_) {
        if (mounted && !_hover) setState(() => _hover = true);
      },
      onExit: (_) {
        if (mounted && _hover) setState(() => _hover = false);
      },
      child: _expanded ? _buildEditor(theme) : _buildView(theme),
    );
  }

  Widget _buildView(ThemeData theme) {
    final ColorScheme scheme = theme.colorScheme;
    final Brightness brightness = theme.brightness;
    // 这条灵感贴的图（视频在第二步接入）；落库即不变，MVP 不编辑附件。
    final List<StreamAttachment> attachments =
        ref.watch(streamAttachmentsProvider(widget.item.id));
    final bool marked = widget.selected;
    // 菜单打开也算"悬浮中"：否则弹窗一开、按钮就滑走了。
    final bool active = _hover || _menuOpen;
    // hover 的回答是"纸被轻推了一下"——见下方 `TweenAnimationBuilder`。归档条目
    // 不参与任何悬浮动效（它已经"放下了"）。
    final bool lifted = active && !widget.archived && !widget.selectMode;
    // hover **不画描边**（2026-10-17 用户定：发丝边在常显底色上像"框"）。
    // 描边只留给选中——并且必须是单一颜色：`borderRadius` 与"四边异色"不能共存。
    final Color edge = marked
        ? scheme.primary.withValues(alpha: 0.4)
        : Colors.transparent;
    // **常显底色**（2026-10-17 用户定）：原来 hover 才铺的那层底色改成每行常驻，
    // 悬浮时不再换底色——只留左侧颜色带与右上角按钮两个信号，安静得多。
    //
    // 底色**烤实**（alphaBlend 进 surface）：半透明底会让对比度检查把文字算在
    // "未知/低对比"背景上，a11y 会红；而且行底本来就压在 panel 的 surface 上，
    // 合成结果完全相同。
    final Color rowFill = Color.alphaBlend(
      AppTheme.hoverOverlay(brightness),
      scheme.surface,
    );
    final Color bg = marked
        ? scheme.primaryContainer.withValues(alpha: 0.35)
        : rowFill;

    return Semantics(
      button: !widget.archived,
      selected: widget.selectMode ? marked : null,
      label: widget.item.text,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 归档条目**不参与多选**（否则已处理的旧条目会被混进"合并成新笔记"里）。
        onTap: widget.selectMode
            ? (widget.archived ? null : widget.onToggleSelect)
            : (widget.archived ? null : _expand),
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
            // **轻推**：整体左移 2px（不缩放、不上下移）。
            //
            // 只做纯位移、**不缩放**：放大哪怕 0.6%，卡片左右也会各溢出 1~2px，
            // 被 `ListView` 的视口切掉一条边（2026-10-17 用户实报）。位移不改变
            // 横向尺寸，永远不会被切；热区跟着走，也不会"看得见点不到"。
            // 左移安全：每张卡经 `_pageColumn` 左右各缩进 24px（gridMargin），
            // 2px 推不到视口裁剪边，比上移（顶边是硬边）还稳（2026-10-20 改）。
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: lifted ? 1.0 : 0.0),
              curve: Curves.easeOut,
              duration: Tokens.durationHover,
              builder: (BuildContext context, double t, Widget? child) =>
                  Transform.translate(
                    offset: Offset(-2.0 * t, 0),
                    child: child,
                  ),
              child: AnimatedContainer(
                curve: Curves.easeOut,
                duration: Tokens.durationHover,
                padding: const EdgeInsets.fromLTRB(
                  Tokens.spaceSm,
                  Tokens.spaceSm,
                  Tokens.spaceSm,
                  Tokens.spaceSm,
                ),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(Tokens.radiusSm),
                  // 描边**永远占位**（透明也算 1px）：宽度恒定 ⇒ hover 不挤动文字。
                  border: Border.all(color: edge),
                ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (widget.selectMode && !widget.archived) ...<Widget>[
                    _SelectBox(selected: marked),
                    const SizedBox(width: Tokens.spaceSm),
                  ],
                  Expanded(
                    // 正文由外层 [Semantics.label] 朗读（整条一起念），这里排除，
                    // 免得"标签 + 正文"念两遍；行内按钮的语义**保留**（可单独聚焦）。
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          // 空卡（flomo 式，清空后保留）：显示淡灰占位，保证卡片
                          // 仍可见、可点、能重新展开编辑，而不是一行纯空白。
                          Text(
                            widget.item.text.trim().isNotEmpty
                                ? widget.item.text
                                : '（空）',
                            maxLines: 8,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: widget.item.text.trim().isEmpty
                                  ? Bauhaus.inkMuted(brightness)
                                  : (widget.archived
                                      ? Bauhaus.inkMuted(brightness)
                                      : Bauhaus.ink(brightness)),
                              height: 1.6,
                            ),
                          ),
                          // 贴的图：缩略图条（视频在第二步接入）。
                          if (attachments.isNotEmpty)
                            _attachmentStrip(theme, attachments),
                        ],
                      ),
                    ),
                  ),
                  // **时间挪到右上角**（2026-10-17 用户定），与 hover 操作簇共用
                  // 同一个 92 的固定槽：平时显示 `17:52`，悬浮/菜单打开时换成三枚
                  // 图标——位置不变、宽度不变，正文永远不重排。
                  if (widget.archived) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.only(
                        top: Tokens.spaceXxs,
                        left: Tokens.spaceSm,
                      ),
                      // 时间是装饰性 meta：不参与朗读（行标签已含正文）。
                      child: ExcludeSemantics(
                        child: Text(
                          '归档于 ${_clock(widget.item.archivedAt ?? widget.item.createdAt)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Bauhaus.inkMuted(brightness),
                          ),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final bool ok = await confirmTrashStream(context, 1);
                        if (!ok || !mounted) return;
                        await ref
                            .read(streamProvider.notifier)
                            .trash(widget.item.id);
                      },
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: scheme.error,
                        textStyle: theme.textTheme.labelSmall,
                      ),
                      child: const Text('删除'),
                    ),
                  ] else
                    SizedBox(
                      width: _actionsWidth,
                      height: _actionSlot,
                      // **从右侧滑出来**（而不是凭空出现）：与时间标签交叉淡入
                      // 淡出，动势指向"手是从右边过来取操作的"。槽位尺寸恒定，
                      // 所以正文依旧不重排（与 hover 不挤动文字同一条规矩）。
                      child: AnimatedSwitcher(
                        duration: Tokens.durationHover,
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeOut,
                        transitionBuilder: (Widget child, Animation<double> a) =>
                            SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0.25, 0),
                                end: Offset.zero,
                              ).animate(a),
                              child: FadeTransition(opacity: a, child: child),
                            ),
                        child: (_hover || _menuOpen) && !widget.selectMode
                            ? _actions(
                                theme,
                                key: const ValueKey<String>('actions'),
                              )
                            : _timeLabel(
                                theme,
                                brightness,
                                key: const ValueKey<String>('time'),
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
    );
  }

  /// 灵感贴图的缩略图条：左对齐、可横向滚动（图多时不挤正文）。
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
                child: ClipRRect(
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

  /// 右上角的时间标签（与操作簇共用同一个槽位，右对齐、贴首行基线）。
  Widget _timeLabel(ThemeData theme, Brightness brightness, {Key? key}) => Align(
    key: key,
    heightFactor: 1,
    child: Padding(
      padding: const EdgeInsets.only(
        top: Tokens.spaceXxs,
        right: Tokens.spaceXs,
      ),
      // 装饰性 meta：读屏只念行标签里的正文，不念时间。
      child: ExcludeSemantics(
        child: Text(
          _clock(widget.item.createdAt),
          style: theme.textTheme.labelSmall?.copyWith(
            color: Bauhaus.inkMuted(brightness),
          ),
        ),
      ),
    ),
  );

  /// hover 操作入口：只有「更多」一枚（复制已收进它的菜单，2026-10-20 用户定；
  /// 归档自动，不在这里）。
  ///
  /// 2026-10-17 调整：
  /// - **去掉「引用到笔记」**——引用应从笔记 / 画布那一端发起（在正文里挑一条
  ///   灵感），而不是在灵感列表里逐个推出去；
  /// - 图标 24 → **20 框**（视觉 ≈15），槽 24；整簇占位 **40** 且**始终保留**
  ///   （见 [_actionsWidth]），所以 hover 不会挤动文字。
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
        items: const <PopupMenuEntry<String>>[
          PopupMenuItem(value: 'copy', child: Text('复制')),
          PopupMenuDivider(),
          PopupMenuItem(value: 'to-note', child: Text('转为新笔记')),
          PopupMenuItem(value: 'to-canvas', child: Text('转为新画布')),
          PopupMenuDivider(),
          PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
      ),
    );
  }

  /// 动作槽边长（热区）：24（= a11y 触达下限）。图标 20 框居中，留 2。
  static const double _actionSlot = 24;

  /// 操作簇的**固定占位宽** = 左留白 8 + 1 槽 24 + 右留白 8 = 40。
  ///
  /// 只剩「更多」一枚，但仍要留够时间标签 `17:52`（约 30 + 右内边距）的宽度；
  /// 行内永远留出这 40，hover 只是把图标填进来 ⇒ 文字宽度恒定，不会重排。
  static const double _actionsWidth =
      Tokens.spaceSm + _actionSlot + Tokens.spaceSm;

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
      onCanceled: () => setState(() => _menuOpen = false),
      onSelected: (String value) {
        setState(() => _menuOpen = false);
        unawaited(_onMenu(value));
      },
      itemBuilder: (BuildContext _) => items,
      // 用 child 而不是 icon：icon 版内部固定 48 的 IconButton，热区过大。
      child: SizedBox(
        width: _actionSlot,
        height: _actionSlot,
        child: Center(child: icon),
      ),
    );
  }

  Widget _buildEditor(ThemeData theme) {
    final ColorScheme scheme = theme.colorScheme;
    final Brightness brightness = theme.brightness;
    return Focus(
      onKeyEvent: (FocusNode _, KeyEvent event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final bool escape =
            event.logicalKey == LogicalKeyboardKey.escape;
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
            const SizedBox(height: Tokens.spaceXs),
            Row(
              children: <Widget>[
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
    );
  }

  static String _clock(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }
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


