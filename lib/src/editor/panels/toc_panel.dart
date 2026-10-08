import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// 目录（TOC）面板 · appflowy 版（阶段 2 · 第 2 项）。
///
/// 与 quill 版（`note_toc_panel.dart`）**同规约、换数据源**——那 300 行里
/// 真正的产品判断一条都没丢，并按标杆应用（Notion / Google Docs / 飞书 /
/// VS Code 大纲）的规则做了两处**结构性修正**（见文末）：
/// - **只读**：标题体系（H1~H3）本来就是文档数据，目录只是读侧，不写任何块；
/// - **数据**：遍历 `document.root.children` 取 `heading` 块的 1~3 级
///   （比 quill 的 `header` 属性更直白：appflowy 的标题类型 + level 属性）；
/// - **高亮跟随滚动**：官方 `EditorScrollController.visibleRangeNotifier`
///   直接给"首个可见顶层块索引"⇒ 当前章节 = 索引 ≤ 它且最近的标题。
///   比 quill 版对渲染对象做偏移命中更直接，也不存在
///   `!debugNeedsLayout` 那类时序坑；
/// - **跳转用 `jumpTo` 而非 `scrollTo`**（瞬时、无动画）：官方动画版远跳会
///   起第二个列表交叉淡入、把同一批块重建一遍，而块容器的 key 是
///   `node.key`（GlobalKey）→ 元素在 sliver 布局期间被搬移，实测炸
///   `Duplicate GlobalKey detected` / `RenderLeaderLayer was mutated in
///   RenderSliverList.performLayout`。详见 [_AppFlowyTocPanelState._jump]；
/// - **首条 = 页面标题**（点击**回到文档开头**）：笔记标题是应用层的输入框、
///   **不在文档里**（编辑器之外），所以目录里没有任何入口能回到顶部——
///   这里补上。它随标题实时变化（收 `TextEditingValue`，直接给标题
///   `TextEditingController`）；文档滚到最顶时它高亮（"你在页面开头"）；
///   正文**第一个块本身就是标题**时与它合并成一条（点击目标完全相同）。
/// - **视觉**：层级缩进 + 字号/字重梯度 + 激活底色，与 quill 版逐项一致。
///
/// ## 本轮修正的两处（对着实测现象改，不是重构）
/// 1. **点击目录会"滑下去又弹回"**：官方在**选区变化**时 post-frame 把光标
///    "撑"回视口（`scroll_service_widget.dart` 的 `_onSelectionChanged`
///    → `startAutoScroll(edgeOffset: 220)`），点目录会连带触发它，于是跳转
///    被拽回光标处。修法：跳转期间关掉 `EditorState.disableAutoScroll`
///    （官方为这个场景留的开关），两帧后恢复。
/// 2. **末尾标题永远停不到视口顶部**（`maxScrollExtent` 卡住）——quill 版
///    用「点击固定 + 到底兜底」两条补偿规则绕开它。当时改为从根上解决：
///    给编辑器加"一屏高"的末尾留白，任何块都能滚到顶部 ⇒ 两条补偿规则
///    连同其状态一起删除，高亮只剩一条规则（视口顶部之上最近的标题）。
///    ⚠️ 末尾留白 2026-09-14 **回到官方口径（固定一屏 600px，且可点"继续写"）**
///    （见 [editorTrailingSpace]）：末段因此大体能滚到视口顶部，目录跳转的
///    "目标到顶部"基本都成立；仍差一点点的那一小段（视口高 ≈690 − 末块高）由
///    [activeTocIndex] 的「到底兜底」+ 落点高亮补位。
///    另外激活项会**自动滚进面板可视区**（VS Code 大纲行为），只在真的
///    出界时才动，不打断手动滚动。
class AppFlowyTocPanel extends StatefulWidget {
  const AppFlowyTocPanel({
    super.key,
    required this.editorState,
    required this.scrollController,
    required this.titleListenable,
    this.onJumpedToNode,
    this.visible = true,
  });

  /// 面板宽度（推挤式挂载：宿主用它在 0 ↔ [width] 之间做滑出动画）。
  static const double width = 208;

  /// 跳转落地后的回调：把**落点块的 node id** 报给宿主（首条"页面标题"
  /// 不是文档里的块，不回调）。
  ///
  /// 宿主用它做"正文里短暂高亮落点"：末尾留白改小后（见
  /// [editorTrailingSpace]），末尾若干块不再能停在视口顶部，"标题跑到最上面"
  /// 这个位置线索就失效了——高亮补上"我落在哪"。
  /// 面板自己不做高亮：它不认识主题与正文渲染，保持"只读数据侧"的边界。
  final ValueChanged<String>? onJumpedToNode;

  final EditorState editorState;
  final EditorScrollController scrollController;

  /// 笔记标题来源（视图的标题 `TextEditingController` 即是；
  /// 它是 `ValueListenable<TextEditingValue>`，故读 `value.text`）。
  final ValueListenable<TextEditingValue> titleListenable;

  /// 面板当前是否**可见**（宿主在收起 / 窗口过窄时传 false）。
  ///
  /// 面板是**常驻挂载**的（宿主用 0 ↔ 208 的 AnimatedContainer 做滑出动画），
  /// 收起后若照常跟随滚动，激活项每变一次就把**全部条目**重建一遍——而结果
  /// 反正看不见。实测这占滚动每步 **~35-40%** 的泵帧成本（2026-09-14，420 块
  /// 文档：26.2ms → 冻结后 17.4ms）。故收起期间**冻结**：滚动/文档变化只标脏
  /// 不重建，重新可见时一次性补算（见 `didUpdateWidget`）。
  final bool visible;

  @override
  State<AppFlowyTocPanel> createState() => _AppFlowyTocPanelState();
}

class _AppFlowyTocPanelState extends State<AppFlowyTocPanel> {
  List<TocEntry> _entries = const <TocEntry>[];

  /// 上一次 setState 时的激活项索引（差量门闩，见 [_refresh]）。
  /// 初值取任何合法索引都取不到的 -2，保证首次刷新必过。
  int _lastActiveItem = -2;

  /// 文档结构是否已变而尚未反映到界面（[_recompute] 置位、[_refresh] 消费）。
  bool _entriesDirty = false;

  StreamSubscription<EditorTransactionValue>? _transactionSub;

  @override
  void initState() {
    super.initState();
    _recompute();
    // 滚动 → 只重算高亮；标题列表不变（成本 O(标题数)）。
    widget.scrollController.visibleRangeNotifier.addListener(_onViewChanged);
    // 事务 → 文档变了：标题列表与索引都可能变，整体重算。
    _transactionSub = widget.editorState.transactionStream.listen(
      (_) => _onDocumentChanged(),
    );
  }

  @override
  void didUpdateWidget(AppFlowyTocPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从收起变展开：冻结期间攒下的变更在这里一次性补算（滚动位置与文档结构
    // 都可能变了，直接全量重算最稳）。
    if (!oldWidget.visible && widget.visible) {
      _recompute();
      _entriesDirty = true;
      _refresh();
    }
  }

  @override
  void dispose() {
    widget.scrollController.visibleRangeNotifier.removeListener(_onViewChanged);
    unawaited(_transactionSub?.cancel());
    super.dispose();
  }

  void _recompute() {
    _entries = tocEntriesOf(widget.editorState.document);
  }

  void _onViewChanged() {
    // 收起时冻结：只标脏，不重算不重建（见 [AppFlowyTocPanel.visible]）。
    if (!widget.visible) {
      _entriesDirty = true;
      return;
    }
    _refresh();
  }

  void _onDocumentChanged() {
    // 收起时冻结：连 _recompute 都不做（它要遍历全文档，白算），只标脏。
    if (!widget.visible) {
      _entriesDirty = true;
      return;
    }
    _recompute();
    _entriesDirty = true;
    _refresh();
  }

  /// 事务流是 `sync: true` 的（`EditorState.apply` 内同步广播），直接
  /// setState 有"构建期间标脏"的风险 → 落在构建/布局阶段时延到帧末。
  void _refresh() {
    if (!mounted) return;
    // ⚡ 差量门闩：visibleRange 在滚动期间**逐帧**变化，但绝大多数帧算出的
    // 激活项没变、条目列表也没变——原样 setState 会把整个面板（全部条目）
    // 每帧重建一遍，滚动成本与标题数成正比。两项都没变就什么都不做。
    final int activeItem = _currentActiveItem();
    if (activeItem == _lastActiveItem && !_entriesDirty) return;
    _lastActiveItem = activeItem;
    _entriesDirty = false;

    // 同步广播落在构建/布局阶段时，延到帧末再 setState，避免"构建期标脏"。
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  /// 复算 build 里的"当前激活项"索引（含"页面标题在顶部时高亮首条"与
  /// "合并首块标题"的换算），供 [_refresh] 做差量判断——两处规则必须
  /// 保持一致，改一处要同步另一处。
  int _currentActiveItem() {
    final (int, int) range = widget.scrollController.visibleRangeNotifier.value;
    final bool mergeLeading = _entries.isNotEmpty && _entries.first.index == 0;
    final bool atTop = range.$1 == 0;
    final int active = activeTocIndex(
      entries: _entries,
      visibleRange: range,
      endInView: _endInView,
    );
    return atTop ? 0 : (active < 0 ? -1 : (mergeLeading ? active : active + 1));
  }

  /// 文档**末尾是否已经落在视口里**（最后一块的下沿不再超出视口下沿）——
  /// 「到底兜底」的判据（见 [activeTocIndex] 的 [endInView]）。
  ///
  /// 取官方条目位置（视口比例，来自 `itemPositions`）：最后一块的
  /// `itemTrailingEdge ≤ 1` 就是"内容已经到头了"。**不猜像素**——末尾留白
  /// 只有 [editorTrailingSpace]，用像素判会依赖视口高度与留白的关系。
  ///
  /// 最后一块不在可见列表里（我们还离得很远）时返回 false。
  bool get _endInView {
    final int lastBlock = widget.editorState.document.root.children.length - 1;
    if (lastBlock < 0) return false;
    for (final position
        in widget.scrollController.itemPositionsListener.itemPositions.value) {
      if (position.index == lastBlock) {
        return position.itemTrailingEdge <= 1;
      }
    }
    return false;
  }

  void _jump(TocEntry entry) {
    // 类型用推断：`ItemScrollController` 来自官方 vendored 的
    // scrollable_positioned_list，不在包公开导出里（不能写类型名）。
    final items = widget.scrollController.itemScrollController;
    if (!items.isAttached) return;

    // ⚡ 目标**已经在视口里、但够不到视口顶部**（末尾那一段）⇒ **完全不动**，
    // 只给落点高亮。
    //
    // 为什么：官方 `jumpTo` 是"先归零、再重锚"，末尾够不到顶部时归零的位置不
    // 合法，框架会把偏移**动画**修正回来（实测 `-644 → 0 → … → -644`），观感就
    // 是"往上跳一下再回去"；而目标已经在屏幕上、挪也挪不到顶，位移本身没有意义。
    // 反馈由落点高亮 + 目录激活条给（都不依赖滚动）。
    //
    // 其余情况一律走下面的**瞬时跳**（官方 `jumpTo`）：不做动画 ⇒ 没有动画起止
    // 的问题，也就不会有"过冲再弹回"那件事。
    final int lastBlock = widget.editorState.document.root.children.length - 1;
    double? leadingEdge;
    double lastVisibleTrailing = 0;
    double? lastBlockTrailing;
    for (final position
        in widget.scrollController.itemPositionsListener.itemPositions.value) {
      if (position.index == entry.index) leadingEdge = position.itemLeadingEdge;
      if (position.itemTrailingEdge > lastVisibleTrailing) {
        lastVisibleTrailing = position.itemTrailingEdge;
      }
      if (position.index == lastBlock) {
        lastBlockTrailing = position.itemTrailingEdge;
      }
    }
    if (leadingEdge != null &&
        !tocJumpCanReachTop(
          leadingEdge: leadingEdge,
          viewportHeight: MediaQuery.sizeOf(context).height,
          trailingSpace: editorTrailingSpace,
          lastBlockTrailingEdge: lastBlockTrailing,
          blocksBelow: lastBlock - entry.index,
          lastVisibleTrailingEdge: lastVisibleTrailing,
        )) {
      _notifyJumped(entry);
      return;
    }

    // ⚠️ **先压住官方的"自动滚回光标"**——这是"点目录滑下去又弹回"的根因。
    //
    // 官方 `ScrollServiceWidget._onSelectionChanged` 一见到选区变化就
    // post-frame 调 `startAutoScroll(..., edgeOffset: autoScrollEdgeOffset)`
    // （桌面默认 220px）把光标"撑"回视口。点目录会连带触发它（点面板会让
    // 编辑器失焦/选区事件），于是我们刚跳过去就被拽回光标处。
    // 官方给这个场景留了开关：`EditorState.disableAutoScroll`
    // （`desktop_scroll_service.dart` 的 `startAutoScroll` 直接 return）。
    // **两帧后**恢复：自动滚动是 post-frame 发起的，早恢复会被它抓住。
    final EditorState state = widget.editorState;
    final bool previousDisableAutoScroll = state.disableAutoScroll;
    state.disableAutoScroll = true;

    // ⚠️ 跳转必须用 `jumpTo`（瞬时、**单列表**），不能用 `scrollTo`（动画版）。
    //
    // 动画版在远跳时会起第二个列表做交叉淡入——
    // `scrollable_positioned_list.dart` 里 `if (_isTransitioning) ...`
    // 会把**同一批 item 再建一遍**，于是同一个块被两个列表同时构建：
    // 该块的 `node.key`（appflowy 每个块容器都是
    // `CompositedTransformTarget(link: node.layerLink)` 且用 node.key 做 key）
    // 就在 sliver 布局期间被搬移，实测炸成一串（不是必现，取决于帧调度）：
    //   - A RenderLeaderLayer was mutated in RenderSliverList.performLayout
    //   - Duplicate GlobalKey detected in widget tree
    //   报错位置都在 block_component_container.dart 的 Consumer<Node>。
    //
    // 官方自己也不用这个 API：翻页 / Home / End 全走**像素级**
    // `scrollService.scrollTo`（单列表）。我们曾是它唯一的调用方。
    // 代价：跳转没有动画（瞬时定位）。
    //
    // 首条"页面标题"不是块（笔记标题在编辑器之外）→ 直接回文档开头。
    // 其余按**顶层块索引**定位：官方 footer（末尾留白）在列表末位，
    // 不改变块索引，所以 entry.index 与列表 item 索引始终一致。
    items.jumpTo(index: entry.index);
    _notifyJumped(entry);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) state.disableAutoScroll = previousDisableAutoScroll;
      });
    });
  }

  /// 把"落点块"报给宿主（见 [AppFlowyTocPanel.onJumpedToNode]）。
  ///
  /// 按 [TocEntry.path] 取节点：目录存的是**路径**（编辑后索引会漂移、路径指
  /// 的还是那一块），`node.id` 才是稳定标识。
  ///
  /// 首条"页面标题"不是文档里的块（`path` 为空表），落点取**文档第一块**：
  /// 点这一条时页面往往已经在顶部（跳转无事可做），若连高亮也没有，这一行就
  /// 成了"点了没反应的按钮"——高亮首块同样表达了"我在开头"。
  void _notifyJumped(TocEntry entry) {
    final ValueChanged<String>? notify = widget.onJumpedToNode;
    if (notify == null) return;
    final Node? node = widget.editorState.document.nodeAtPath(
      entry.isTitle ? const <int>[0] : entry.path,
    );
    if (node != null && node.id.isNotEmpty) notify(node.id);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return SizedBox(
      width: AppFlowyTocPanel.width,
      // 内描边原是给旧「贴正文左侧」推挤面板用的分隔线；现在目录是悬浮气泡
      // （外层 AppFloatSurface 已带 1px 描边 + 投影），内描边冗余，去掉。
      child: Column(
        // 高度**自适应内容**（气泡用法）：条目少就贴着内容收短，条目多才在
        // 上层给定的 maxHeight 内滚动。列表用 Flexible（松 fit）而非 Expanded
        // ——Expanded 是紧 fit，会把面板撑满约束上限，气泡底部就会留一大截白。
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tokens.spaceLg,
              Tokens.spaceLg,
              Tokens.spaceLg,
              Tokens.spaceXs,
            ),
            child: Text(
              '目录',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                letterSpacing: 1,
              ),
            ),
          ),
          // 用 Flexible（松 fit）而非直接放：条目总高在可用高度**以内**时面板
          // 紧贴内容；**超出**时才由下面的滚动态吸收。
          //
          // ⚠️ 这层滚动是"超限兜底"，不是常态：去掉它的话，长目录（标题多到
          // 一屏放不下）会直接 RenderFlex 溢出（测试里实测溢出 3255px）。
          // 日常文档条目远少于一屏，滚动条根本不出现。
          Flexible(
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.titleListenable,
              builder:
                  (BuildContext context, TextEditingValue value, Widget? _) {
                    // 首条固定是**页面标题**（点击回到文档开头）——笔记标题在
                    // 编辑器之外，文档里没有任何块能代表它，故在此单独构造。
                    //
                    // 正文**第一个块本身就是标题**时与它合并成一条：两者点击
                    // 目标完全相同（都是"文档第 0 块"），分两条是同一个目标
                    // 的重复；合并后标题为空则显示那条标题的文字。
                    final bool mergeLeading =
                        _entries.isNotEmpty && _entries.first.index == 0;
                    final List<TocEntry> items = <TocEntry>[
                      titleEntryOf(
                        value.text,
                        fallbackText: mergeLeading ? _entries.first.text : null,
                      ),
                      ..._entries.skip(mergeLeading ? 1 : 0),
                    ];

                    // "在页面顶部"（视口首个可见块就是文档第 0 块）时高亮首条：
                    // 此时"页面标题"比"第一个标题块"更准确地表达用户位置。
                    final bool atTop =
                        widget.scrollController.visibleRangeNotifier.value.$1 ==
                        0;
                    final int active = activeTocIndex(
                      entries: _entries,
                      visibleRange:
                          widget.scrollController.visibleRangeNotifier.value,
                      endInView: _endInView,
                    );
                    // 章节高亮索引换算到 [items]：合并了首块标题时索引不变
                    // （第 0 条就是它），否则整体 +1（-1 保持 -1）。
                    final int activeItem = atTop
                        ? 0
                        : (active < 0
                              ? -1
                              : (mergeLeading ? active : active + 1));

                    // 条目**全量构建**（几十条的成本可忽略），高度跟随内容自适应；
                    // 只有在超出可用高度时外层滚动态才起作用（见上面的 Flexible）。
                    // 不再有"激活项自动进可视区"逻辑——滚动态只是溢出兜底。
                    return SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.only(
                          left: Tokens.spaceMd,
                          right: Tokens.spaceMd,
                          bottom: Tokens.spaceLg,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            for (int i = 0; i < items.length; i++)
                              _itemOf(
                                entry: items[i],
                                isActive: i == activeItem,
                                theme: theme,
                                scheme: scheme,
                              ),
                            // 没有标题时在末尾追一条引导文案（首条入口仍在）。
                            if (_entries.isEmpty) _hintOf(theme, scheme),
                          ],
                        ),
                      ),
                    );
                  },
            ),
          ),
        ],
      ),
    );
  }

  /// 一条目录项（首条"页面标题"与标题块共用；前者无缩进、字号更大、字色更实）。
  Widget _itemOf({
    required TocEntry entry,
    required bool isActive,
    required ThemeData theme,
    required ColorScheme scheme,
  }) {
    final TextStyle? textStyle = theme.textTheme.bodySmall?.copyWith(
      // 首条 15；标题三级梯度 14/13/12（H2/H3 同字号时层级全靠
      // 缩进，H2 会显得偏小）。
      fontSize: entry.isTitle
          ? 15
          : switch (entry.level) {
              1 => 14,
              2 => 13,
              _ => 12,
            },
      // 字重梯度（600/500/400）配合字号强化层级；选中态一律加重。
      fontWeight: isActive
          ? FontWeight.w600
          : (entry.isTitle
                ? FontWeight.w600
                : switch (entry.level) {
                    1 => FontWeight.w600,
                    2 => FontWeight.w500,
                    _ => FontWeight.w400,
                  }),
      // 首条用更实的 onSurface（标题块用更淡的 onSurfaceVariant），
      // 一眼区分"页面标题"与"章节"。
      color: isActive
          ? scheme.onSurface
          : (entry.isTitle ? scheme.onSurface : scheme.onSurfaceVariant),
    );
    return InkWell(
      borderRadius: BorderRadius.circular(Tokens.radiusSm),
      onTap: () => _jump(entry),
      child: Container(
        padding: EdgeInsetsDirectional.only(
          // 页面标题条目不缩进；标题块按级别缩进（一级 0 / 二级 16 /
          // 三级 32）。
          //
          // **每级 16px**——成熟应用的常见档位：AppKit 的 NSOutlineView
          // 默认 `indentationPerLevel = 16pt`（Apple 文档），Windows
          // 资源管理器树 19px，VS Code 资源管理器 8px（它靠缩进参考线表达
          // 层级，不靠空隙，所以敢小）。
          //
          // 层级现在**只靠视觉三重表达**：缩进 16 + 字号梯度 14/13/12 +
          // 字重梯度 600/500/400。取 16 而不是 8：面板只有 208px 宽，
          // 16 能拉开层级，三级标题也还剩 ~170px 放文字。
          start: entry.isTitle ? 0 : (entry.level - 1) * 16,
          top: 5,
          bottom: 5,
          end: Tokens.spaceXs,
        ),
        decoration: BoxDecoration(
          // 「当前项」统一读法（2026-10-08 全局换装）：强调色药丸底，
          // 取代旧的"中性 tint + 3px 左指示条"混搭。
          color: isActive ? AppTheme.selectedPill(scheme) : null,
          borderRadius: BorderRadius.circular(Tokens.radiusSm),
        ),
        child: Text(
          entry.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textStyle,
        ),
      ),
    );
  }

  /// 没有标题时的引导文案（首条标题入口仍在，故不占满整屏）。
  Widget _hintOf(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.spaceSm,
        Tokens.spaceMd,
        Tokens.spaceSm,
        0,
      ),
      child: Text(
        '用「标题 1~3」组织正文，\n结构会出现在这里',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          height: 1.8,
        ),
      ),
    );
  }
}

// ─────────────────────────── 纯逻辑（可单测） ───────────────────────────

/// 目录条目：级别（1~3）、标题文本、所在**顶层块索引**、块路径。
class TocEntry {
  TocEntry({
    required this.level,
    required this.text,
    required this.index,
    required this.path,
    this.isTitle = false,
  });

  final int level;
  final String text;

  /// 是否是首条"页面标题"条目（不是文档里的块）。
  ///
  /// 为 true 时：`level` 固定 0、`index` 固定 0、`path` 为空表，
  /// 且**不参与**滚动规则的章节高亮判定。
  final bool isTitle;

  /// 顶层块索引——appflowy 的滚动定位（`ItemScrollController`）按它走。
  /// 会随编辑漂移，因此每次重算时刷新。
  final int index;

  /// 块路径：编辑后索引会变、路径指的还是那一块（固定项靠它自校验）。
  final Path path;
}

/// 目录首条：**页面标题**（点击回到文档开头）。
///
/// 标题为空时回落为 [fallbackText]（正文首块本身是标题时给的那条标题文字），
/// 再回落为「无标题」——与标题输入框的 hint、列表里的空标题回退同一措辞
/// （三处同词是既有规约）。
TocEntry titleEntryOf(String title, {String? fallbackText}) {
  final String text = title.trim();
  final String fallback = (fallbackText ?? '').trim();
  return TocEntry(
    level: 0,
    text: text.isNotEmpty ? text : (fallback.isNotEmpty ? fallback : '无标题'),
    index: 0,
    path: const <int>[],
    isTitle: true,
  );
}

/// 从文档抽出 1~3 级标题（**只读**，不写任何块）。
///
/// - 只收 1~3 级：与 Notion/飞书的目录一致，4 级及以上不入目录；
/// - 文本为空（只有格式没有字）的标题跳过：目录里点一个空条目没有意义。
List<TocEntry> tocEntriesOf(Document document) {
  final List<Node> children = document.root.children;
  final List<TocEntry> entries = <TocEntry>[];
  for (int i = 0; i < children.length; i++) {
    final Node node = children[i];
    if (node.type != HeadingBlockKeys.type) continue;
    final Object? level = node.attributes[HeadingBlockKeys.level];
    if (level is! int || level < 1 || level > 3) continue;
    final String text = (node.delta?.toPlainText() ?? '').trim();
    if (text.isEmpty) continue;
    entries.add(TocEntry(level: level, text: text, index: i, path: node.path));
  }
  return entries;
}

/// 一个块的最小高度（px）：一行正文行盒（小字号 × 小行高 ≈ 20px）。
///
/// 只用于"下方还有多少内容"的**下界**估计（见 [tocJumpCanReachTop]）：取小一点
/// 更安全——估小的后果只是"这次不跳"，估大的后果是"跳了却够不到"。
const double _kMinBlockHeight = 20;

/// 已经在视口里的目标，**够不够得到"停在视口顶部"**。
///
/// ## 为什么要判它
/// 官方 `jumpTo` 是"**先归零、再把锚点挪到目标**"（`_jumpTo` 里那句
/// `primary.scrollController.jumpTo(0)`）。目标够得到顶部时，归零后的位置合法，
/// 一步到位；**末尾那一段够不到**时（下方内容不足一屏），归零的位置不合法，
/// 框架会把偏移**动画**修正回来——实测轨迹 `-644 → 0 → … → -644`，观感就是
/// "往上跳一下再回去"（用户实测）。既然目标已经在屏幕上、挪也挪不到顶，这一次
/// 就**完全不动**，反馈交给落点高亮与目录激活条（两者都不依赖滚动）。
///
/// ## 判据（全程用**视口比例**，不做像素测量）
/// "够得到" ⟺ 目标下方还有 ≥ 一个视口的内容可滚。只用一个**下界**判：判为
/// "够得到"必须真的够得到（宁可少跳一次，也不要跳了却没到位）。
///
/// ```
/// 可滚余量/V ≥ 留白/V + 20×下方块数/V + max(0, 末项下沿 − 1)
/// ```
/// - **末块可见**（[lastBlockTrailingEdge] 非空）⇒ 上式就是精确值（末块下沿
///   超出视口的那一截一定在下方）；
/// - **末块在视口外** ⇒ 用"最后可见项下沿超出视口的那一截" + "每块至少一行"
///   （[_kMinBlockHeight]）× 下方块数 兜住下界。
///
/// [viewportHeight] 传**窗口**高（≥ 编辑器视口）⇒ 各项比例偏小 ⇒ 判据偏严 ⇒
/// 偏保守（宁可不动，也不动一下还没到位）。
bool tocJumpCanReachTop({
  required double leadingEdge,
  required double viewportHeight,
  required double trailingSpace,
  required double? lastBlockTrailingEdge,
  required int blocksBelow,
  required double lastVisibleTrailingEdge,
}) {
  if (viewportHeight <= 0) return true; // 量不到视口：不武断拦
  final double trailing = trailingSpace / viewportHeight;
  final double belowFold = lastVisibleTrailingEdge > 1
      ? lastVisibleTrailingEdge - 1
      : 0;
  final double? lastTrailing = lastBlockTrailingEdge;
  if (lastTrailing != null) {
    final double needed = trailing + (lastTrailing > 1 ? lastTrailing - 1 : 0);
    return leadingEdge <= needed;
  }
  final double lowerBound =
      trailing + _kMinBlockHeight * blocksBelow / viewportHeight + belowFold;
  return leadingEdge <= lowerBound;
}

/// 当前章节索引（-1 = 不高亮）：**视口顶部之上最近的标题**
/// （网页端目录的"我读到哪了"语义）。
///
/// 另有一条**「到底兜底」**（[endInView] 为真时直接取最后一条）：
/// 留白虽已回到一屏（[editorTrailingSpace] = 600），但**仍差一点点**才够让
/// 末尾标题停到"视口顶部之上"（视口高 ≈690 − 末块高 ≈80 > 600），纯"视口顶
/// 最近的标题"会**永远选不到它**——表现为滚到底 / 点最后一条时目录里那一行
/// 不高亮（用户实测）。当年的 quill 版正是用这条补偿规则兜的。
int activeTocIndex({
  required List<TocEntry> entries,
  required (int, int) visibleRange,
  bool endInView = false,
}) {
  if (entries.isEmpty) return -1;
  // 「到底兜底」优先：文档末尾已落在视口里 ⇒ 当前章节就是最后一条。
  if (endInView) return entries.length - 1;

  final int first = visibleRange.$1;
  if (first < 0) return -1;

  int active = -1;
  for (int i = 0; i < entries.length; i++) {
    if (entries[i].index <= first) {
      active = i;
    } else {
      break;
    }
  }
  return active;
}

// ────────────────── 编辑器侧留白（配合目录，不是目录的一部分） ──────────────────

/// 编辑器**末尾留白**：**官方口径（桌面一屏 600px）**，且是**可点热区**
/// （点它 = 继续写，见 `note_editor_view_appflowy.dart` 的 `_focusEndOfDocument`）。
///
/// ## 为什么是 600（2026-09-14 定，回到官方）
///
/// 官方 app 就是给编辑器挂一块固定 600px 的 footer：
///
/// ```dart
/// // frontend/appflowy_flutter/.../document/presentation/editor_page.dart
/// footer: GestureDetector(
///   behavior: HitTestBehavior.translucent,
///   onTap: () => _focusOnLastEmptyParagraph(),
///   child: SizedBox(height: UniversalPlatform.isDesktopOrWeb ? 600 : 400),
/// ),
/// ```
///
/// 它买到两件事：① 点空白处**继续写**（留白属于"页面"，Word/备忘录/飞书同理；
/// quill 版当年也有"点击定位到文末"）；② 距文末一屏内的块**大体**能滚到视口
/// 顶部（目录 `jumpTo(alignment: 0)` 的前提）。
///
/// ⚠️ 取**固定 600** 而不是"视口高 − 一行"：后者随窗口高度变化，而 footer 是
/// 滚动列表的最后一项、会参与总高的计算 ⇒ 窗口一改、总高跟着跳。固定值就没
/// 这个问题。
///
/// ## 曾经的代价：**已消除**（2026-09-14 当天）
///
/// 一屏留白是列表里**最高的项**（普通段落的 20 多倍）。滚动器原先按"已布局块
/// 的**平均**高度 × 剩余块数"外推总高（Flutter `SliverChildDelegate.
/// estimateMaxScrollOffset` 默认返回 null），于是它在**未被构建**时只按平均
/// 块高计入 ⇒ 滚到尾部估算被修正一次 ⇒ **滚到文档末尾时滚动条滑块略变短**。
/// 白天曾把它收到 48px 以消除这一跳，但那同时丢掉了上面两件事，遂改回 600、
/// 接受"尾部一次小幅修正"。
///
/// 现在这条代价没有了：滚动器改吃**应用侧逐块给出的高度**
/// （`EditorScrollController.itemExtentOf`，清单里也含这一项 = 600），
/// 总高从第一帧起就是精确值 —— 见 `note_editor_view_appflowy.dart` 的
/// `_itemExtents` 与 `third_party/appflowy_editor/PATCHES.md` 的「补丁 10」。
/// 因此也不必再"想让末尾标题稳稳停在顶部就先加大留白"。
const double editorTrailingSpace = 600;
