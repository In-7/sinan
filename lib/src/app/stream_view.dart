import 'dart:async';

import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../domain/note.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'providers.dart' show streamFocusProvider, streamProvider;
import 'stream_ledger_panel.dart' show showStreamLedger;
import 'stream_export.dart';

/// **速记 / 心流**（2026-10-17 定：flomo 式低摩擦收件箱）。
///
/// ## 版式（本轮定稿）
/// `单列 · 上限 640 · 居中`：速记靠时间序读，不铺网格；宽屏把留白当设计，
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

  /// 顶栏标签筛选。**速记刻意忽略它**（速记是纯文本、没有标签）。
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

  Future<void> _capture(String text) async {
    await ref.read(streamProvider.notifier).add(text);
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

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<StreamItem>> streamAsync = ref.watch(streamProvider);
    final List<StreamItem> all = streamAsync.value ?? const <StreamItem>[];
    // 从笔记里的速记引用跳过来：只显示那一条（`null` = 正常时间流）。
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
    // 这里仍算出归档集，只为了让工具栏报「N 条 · M 已处理」的计数。
    final List<StreamItem> archived = <StreamItem>[
      for (final StreamItem i in scoped)
        if (i.archived && _matches(i)) i,
    ];
    // 时间流永远只有"当下"；聚焦（从引用跳来）时只给那一条。
    final List<StreamItem> shown = focusId != null ? scoped : open;
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
      // 上留白 **24** / 下 0（2026-10-18 用户改）：工具栏上移之后，页首不需要
      // 再靠 48 的留白把书写区推到"黄金位"了——输入块本身就在视线起手处，
      // 24 与输入块下方留白同档，整页是均匀的呼吸。
      // 上留白 24 / 下 0；**左右不留**——留白区域也要能滚（见下方 [_pageColumn]）。
      padding: const EdgeInsets.only(top: Tokens.spaceXl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // **列表头挪到输入框之上**（2026-10-18 用户定，对齐 flomo 的版式）：
          // 条数 / 搜索 / 选择是"这一页的工具栏"，写在纸上就是页眉——先于
          // 书写区出现，眼睛从左上角顺着读下来。空库时整行不出现。
          if (focusId != null)
            _pageColumn(_focusHeader())
          else if (_selectMode)
            _pageColumn(_selectionToolbar())
          else if (_query.isNotEmpty ||
              open.isNotEmpty ||
              archived.isNotEmpty)
            _pageColumn(_listHeader(open.length, archived.length)),
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
                if (_selectMode && _selected.isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: Tokens.spaceLg,
                    child: Center(child: _pageColumn(_mergeBar())),
                  ),
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
  /// 头部 / 书写区 / 每一条速记都走它 ⇒ 三者的左缘永远同在一条竖线上；
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
  /// - **搜索常驻**（不是"点开才出现"）：右侧一个 190×28 的搜索框，点一下就能
  ///   打字，边打边过滤；有词时右侧出现清空 ×；
  /// - **选择是文字**（不是一枚看不懂的图标）：`选择` 两字，中性色、hover 铺底，
  ///   与搜索框同一条基线——之前那枚虚线方框图标在实机上根本认不出（用户实报）；
  /// - 左侧报条数；`N 已处理` 是**入口**（2026-10-18 用户定：归档不放在流里，
  ///   就挂在这个计数上，点进去看清单）。
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
    return SizedBox(
      height: 28,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              // 左端只报**待处理**条数：归档数由右侧那枚「归档 N」按钮说
              // （2026-10-18 用户定稿）——同一个数字出现两遍只会让人以为能点两次。
              '$openCount 条',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          ),
          SizedBox(
            width: searchWidth,
            height: 28,
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              style: theme.textTheme.bodySmall,
              cursorColor: scheme.primary,
              textAlignVertical: TextAlignVertical.center,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索',
                hintStyle: muted,
                // 与捕获条同一口径（2026-10-17 用户定）：**不要底色**，只有
                // 1px 边线；聚焦时边线转蓝。填充色会让这枚小控件看起来像一块
                // 按钮，和周围的纸面不搭。
                filled: false,
                prefixIcon: const tabler.Search(
                  height: Tokens.iconXs,
                  width: Tokens.iconXs,
                ),
                prefixIconConstraints: const BoxConstraints(minWidth: 28),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        iconSize: Tokens.iconXs,
                        onPressed: _clearSearch,
                        icon: const tabler.X(),
                      ),
                suffixIconConstraints: const BoxConstraints(minWidth: 28),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: Tokens.spaceXs,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Tokens.radiusSm),
                  borderSide: BorderSide(color: scheme.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Tokens.radiusSm),
                  borderSide: BorderSide(color: scheme.outlineVariant),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Tokens.radiusSm),
                  borderSide: BorderSide(color: scheme.primary),
                ),
              ),
              onChanged: (String v) => setState(() => _query = v),
              onSubmitted: (String _) => _searchFocus.unfocus(),
            ),
          ),
          const SizedBox(width: Tokens.spaceSm),
          // **归档入口**（2026-10-18 用户定稿）：图标 + 「归档 N」。
          //
          // 曾经它是左端计数里的一枚文字链（`3 条 · 2 已处理`）——用户实报"不知道
          // 这是干啥的"。低频功能不能指望用户猜：给它一枚箱子图标和一个动词，
          // 与「选择」并排放到右侧操作区，观感与语义才一致。
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
                  foregroundColor: scheme.onSurfaceVariant,
                  textStyle: theme.textTheme.labelMedium,
                ),
              ),
            ),
            const SizedBox(width: Tokens.spaceXs),
          ],
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

  Widget _selectionToolbar() {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      height: 28,
      child: Row(
        children: <Widget>[
          Text(
            _selected.isEmpty ? '选择要合并的速记' : '已选 ${_selected.length} 条',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => setState(_selected.clear),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('清空'),
          ),
          TextButton(
            onPressed: _toggleSelectMode,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  /// 底部唯一的实色主按钮：合并（页面里 primary 只出现在 focus / 选中 / 这里）。
  Widget _mergeBar() {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(Tokens.radiusLg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Tokens.spaceLg,
          Tokens.spaceSm,
          Tokens.spaceSm,
          Tokens.spaceSm,
        ),
        // 条数在工具行上，这里不再重复（同一句话出现两遍会读成两个控件）。
        child: FilledButton(
          onPressed: _merge,
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            textStyle: theme.textTheme.labelMedium,
          ),
          child: const Text('合并为新笔记'),
        ),
      ),
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
              '正在查看被引用的速记',
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

  /// 单条速记：**铺满整列**（没有左侧日期栏，正文左缘 = 行内 padding 8 + 竖条 2）。
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

/// 列表里的一项：日期标题 / 一条速记 / 「已处理」折叠行。
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
    // （2026-10-17 用户定）。行的底色只在速记卡上。
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
                ? '没有匹配的速记'
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

  final Future<void> Function(String text) onSubmit;

  @override
  ConsumerState<_CaptureBar> createState() => _CaptureBarState();
}

class _CaptureBarState extends ConsumerState<_CaptureBar> {
  final TextEditingController _controller = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);

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
    // **进入心流页即可写**（2026-10-17 用户定）：捕获区是这一页的入口，挂载后
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
    return KeyEventResult.ignored;
  }

  Future<void> _submit() async {
    final String text = _controller.text.trim();
    if (text.isEmpty) return;
    // **先落库、再清空**：写失败时把原文留在输入框里并给一句提示，别让人以为
    // "记下了"却什么都没存（2026-10-17 复查）。
    try {
      await widget.onSubmit(text);
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
            label: '速记输入，回车记下',
            child: TextField(
              controller: _controller,
              focusNode: _focus,
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
                        // 纸飞机（原 ArrowUp）：速记是"发出去"，不是"上传"。
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

// ───────────────────────────── 速记行 ─────────────────────────────

/// 一行速记：**没有卡片边框**，静止透明；hover / 选中才铺底色与左侧蓝竖条。
///
/// - 点击就地编辑（`Esc` / `Ctrl+Enter` 保存），不是"放大成卡片"；
/// - hover 时右侧浮出操作簇（引用 / 复制 / 归档 / 更多）；
/// - 归档条目只读、降对比，行尾给「拿回」。
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
    // **不许改空**：`StreamStore.update` 会拒绝空文本，但这里若直接收起，用户
    // 看到的还是旧文本——像是"我删的内容又回来了"（2026-10-17 复查）。
    // 明确说一句、留在编辑态，让人自己再写。
    if (text.trim().isEmpty && widget.item.text.trim().isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('速记不能为空')),
      );
      if (mounted) _editFocus.requestFocus();
      return;
    }
    if (text.trim() != widget.item.text.trim()) {
      await ref.read(streamProvider.notifier).edit(widget.item.id, text);
    }
    if (mounted) setState(() => _expanded = false);
  }

  Future<void> _onMenu(String value) async {
    final String id = widget.item.id;
    switch (value) {
      case 'copy-note':
        await copyStreamToNote(context: context, streamId: id);
      case 'copy-canvas':
        await copyStreamToCanvas(context: context, streamId: id);
      case 'to-note':
        await streamToNewNote(context: context, streamId: id);
      case 'to-canvas':
        await streamToNewCanvas(context: context, streamId: id);
      case 'delete':
        await ref.read(streamProvider.notifier).remove(id);
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
            // **轻推**：整体上移 2px。
            //
            // 只做纯位移、**不缩放**：放大哪怕 0.6%，卡片左右也会各溢出 1~2px，
            // 被 `ListView` 的视口切掉一条边（2026-10-17 用户实报）。位移不改变
            // 横向尺寸，永远不会被切；热区跟着走，也不会"看得见点不到"。
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: lifted ? 1.0 : 0.0),
              curve: Curves.easeOut,
              duration: Tokens.durationHover,
              builder: (BuildContext context, double t, Widget? child) =>
                  Transform.translate(
                    offset: Offset(0, -2.0 * t),
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
                      child: Text(
                        widget.item.text,
                        maxLines: 8,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: widget.archived
                              ? Bauhaus.inkMuted(brightness)
                              : Bauhaus.ink(brightness),
                          height: 1.6,
                        ),
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
                      onPressed: () => ref
                          .read(streamProvider.notifier)
                          .unarchive(widget.item.id),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        textStyle: theme.textTheme.labelSmall,
                      ),
                      child: const Text('拿回'),
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

  /// hover 操作簇：复制 / 归档 / 更多。
  ///
  /// 2026-10-17 调整：
  /// - **去掉「引用到笔记」**——引用应从笔记 / 画布那一端发起（在正文里挑一条
  ///   速记），而不是在速记列表里逐个推出去；
  /// - 图标 24 → **20 框**（视觉 ≈15），槽 24、槽间 6、左留白 8；整簇占位
  ///   **92** 且**始终保留**（见 [_actionsWidth]），所以 hover 不会挤动文字。
  Widget _actions(ThemeData theme, {Key? key}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(left: Tokens.spaceSm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _popupSlot(
            tooltip: '复制到…',
            icon: const tabler.Copy(
              height: Tokens.iconMdSm,
              width: Tokens.iconMdSm,
            ),
            items: const <PopupMenuEntry<String>>[
              PopupMenuItem(value: 'copy-note', child: Text('复制到笔记…')),
              PopupMenuItem(value: 'copy-canvas', child: Text('复制到画布…')),
            ],
          ),
          const SizedBox(width: _actionGap),
          _iconSlot(
            tooltip: '归档（已处理）',
            onPressed: () =>
                ref.read(streamProvider.notifier).archive(widget.item.id),
            icon: const tabler.Archive(
              height: Tokens.iconMdSm,
              width: Tokens.iconMdSm,
            ),
          ),
          const SizedBox(width: _actionGap),
          _popupSlot(
            tooltip: '更多',
            icon: const tabler.Dots(
              height: Tokens.iconMdSm,
              width: Tokens.iconMdSm,
            ),
            items: const <PopupMenuEntry<String>>[
              PopupMenuItem(value: 'to-note', child: Text('转为新笔记')),
              PopupMenuItem(value: 'to-canvas', child: Text('转为新画布')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }

  /// 动作槽边长（热区）：24（= a11y 触达下限）。图标 20 框居中，留 2。
  static const double _actionSlot = 24;

  /// 槽间留白：6（比图标间距松一档，避免三个图标糊成一团）。
  static const double _actionGap = 6;

  /// 操作簇的**固定占位宽** = 左留白 8 + 3 槽 24 + 2 间隙 6 = 92。
  ///
  /// 行内永远留出这 92，hover 只是把内容填进来 ⇒ 文字宽度恒定，不会重排。
  static const double _actionsWidth =
      Tokens.spaceSm + _actionSlot * 3 + _actionGap * 2;

  Widget _iconSlot({
    required String tooltip,
    required VoidCallback onPressed,
    required Widget icon,
  }) {
    // 不用 IconButton：M3 默认最小 40×40，塞进 24 槽会溢出。
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: _actionSlot / 2,
        child: SizedBox(
          width: _actionSlot,
          height: _actionSlot,
          child: Center(child: icon),
        ),
      ),
    );
  }

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


