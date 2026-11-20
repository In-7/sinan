import 'dart:async' show unawaited;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../command/commands.dart';
import '../theme/app_custom_icons.dart';
import '../theme/app_float_surface.dart';
import '../theme/app_icon_button.dart';
import '../theme/app_split_icon_button.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import '../domain/note.dart';
import 'home_hub.dart'
    show FilterMenuButton, NoteSort, homeItemsProvider, homeSortProvider;
import 'note_display.dart';
import 'note_import.dart';
import 'providers.dart';
import 'search_provider.dart';
import 'stream_delete.dart' show showStreamConfirm;

/// 列表头**动作带**的上/下留白（4）：与编辑页头部按钮带的上留白同值
///（`_kHeaderActionTopPadding` = 4）。两条带都从内容卡顶边起算 ⇒ 按钮
/// **同一 y、同一尺寸**（2026-10-22 用户定）。
const double _kHeadBandPadding = 4;

/// 动作钮热区：与编辑页撤销 / 重做 / 双耳同一个 [Tokens.headerActionSize]（30）。
const double _kHeadButtonSize = Tokens.headerActionSize;

/// 列表头**工具行**左内缩：悬浮折叠钮（**热区**左 7〔= 标题左留白 12 − 图标
/// 居中偏移 5〕+ 28 钮）+ 4 呼吸 = **39**。
/// ⚠️ 这块只给折叠钮让位；右簇（搜索 / 新建）靠右对齐，不占左侧。
/// 📌 搜索框展开时也从这里起算 ⇒ 必须 ≥ 折叠钮热区右缘（7 + 28 = 35），
/// 否则输入框会压住折叠钮。
///
/// 钮本体不在列表里——它悬浮在内容卡左上角（`home_screen.dart` 的 Stack 顶层，
/// 折叠时不随列宽移动），这里只是给它让位。
const double _kHeadToolInset =
    Tokens.spaceMd -
    (Tokens.headerActionSize - Tokens.iconSm) / 2 +
    _kHeadButtonSize +
    _kHeadBandPadding;

// （第二行右侧内缩 `_kHeadSecondRowInset`(23) 2026-11-17 撤：它只为"漏斗中心
//   对齐第一行＋中心"存在；同日筛选钮挪到篇数右边，右留白回到 spaceMd。）

/// 240px **笔记列表列**（主从布局的"主"，Option 2 进卡）：坐在浮面卡左格，右格是详情
/// （编辑器 / 画布 / 空态）。服务「全部 / 笔记 / 画布 / 收藏」四个主从视图——
/// 灵感是一页纸时间流，由外壳直接挂 `StreamView`，不经过这里（2026-10-17 收口）；
/// 日历视图也走同一列槽几何，但列内容换成 `CalendarListColumn`（2026-11-14），
/// 同样不经过本类——本类写死了搜索 / 筛选 / 新建分半钮与笔记行数据源。
///
/// - 头（2026-10-21 用户定，复刻 ima）：**第一行 = 工具行**（左留位给悬浮折叠钮，
///   右簇 搜索 / **新建**〔新建最右〕）；**第二行 = 视图名 + 篇数 + 筛选**
///   （2026-11-09 筛选从工具行搬来本行右端）。折叠钮是独立左侧区域。
/// - 体 = 当前视图的笔记行（[homeItemsProvider]，已按视图范围 + 排序 + 标签过滤），
///   再叠一层**页内搜索**（标题 + 摘要内存过滤，见 [_NoteListColumnState]）。
/// - 行：点 / Enter 开（走 [locateProvider]，`focus` 默认 false ⇒ 焦点不被编辑器抢走）；
///   选中行（== [selectedNoteIdProvider]）铺 navSelectedTint 同款选中底（= hover 2×）。
///
/// ## 极简留白（2026-10-17 用户定）
/// 不用行间分割线（满格横线 = 表格感）——分层靠：① 留白（行 vertical padding spaceMd）；
/// ② 字重三级（标题 w600 浓墨 / 摘要 w400 淡墨 / 时间·图标 最小最淡）；③ 选中态淡色底。
class NoteListColumn extends ConsumerStatefulWidget {
  const NoteListColumn({super.key});

  @override
  ConsumerState<NoteListColumn> createState() => _NoteListColumnState();
}

class _NoteListColumnState extends ConsumerState<NoteListColumn> {
  /// 页内搜索态（2026-10-21）：点 ⌕ 展开输入框，输入即过滤。
  /// 空查询时点外部可收起（"取消"语义）；**有词时不自动关**，退出走
  /// 关闭钮 / Esc（两者都清空）——点结果查看笔记不打断搜索。
  ///
  /// 只过滤**当前列表**（标题 + 摘要），刻意不碰全局检索
  /// （[searchNotifierProvider]）——全局搜索后续要撤，先不耦合。
  bool _searching = false;
  final TextEditingController _searchInput = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// 「⌕ 钮 + 展开后的搜索框」共用的 [TapRegion] 组：点组外任意处 = 收起
  /// 页内搜索（浮层惯例"点外部即关"）。同组是为了**排除搜索钮自己**——
  /// 否则点「⌕」开搜索时那一下会被算成"点外部"，刚展开就自己关掉
  /// （[AppPopover] 记的同一个坑）。
  final Object _searchTapGroupId = Object();

  /// 「⌕」钮的焦点节点：搜索收起后把焦点还回去（键盘用户不用再 Tab 一圈）。
  final FocusNode _searchButtonFocus = FocusNode();

  /// 键盘导航当前高亮的**笔记 id**（搜索态专用；`null` = 未高亮）。
  /// 只做视觉高亮、**不动** `selectedNoteIdProvider`——↑/↓ 移动，Enter 才打开。
  String? _activeNoteId;

  /// 当前过滤结果（build 刷新；键盘导航按同一顺序走，省得再算一遍）。
  List<Note> _shown = const <Note>[];

  /// 高亮行的锚：把键盘走到视口外的行滚进来。
  final GlobalKey _activeRowKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _searchInput.addListener(_onQueryChanged);
    // ↑/↓/Enter 挂在 focusNode 上 ⇒ 抢在 EditableText 的方向键处理之前。
    _searchFocus.onKeyEvent = _onSearchKey;
  }

  @override
  void dispose() {
    _searchFocus.onKeyEvent = null;
    _searchButtonFocus.dispose();
    _searchInput.removeListener(_onQueryChanged);
    _searchInput.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// 输入变了 ⇒ 高亮作废（结果集换了，旧的"当前项"没意义了）。
  void _onQueryChanged() => setState(() => _activeNoteId = null);

  void _openSearch() {
    setState(() {
      _searching = true;
      _activeNoteId = null;
    });
    // 帧末再要焦点：AnimatedSwitcher 的新子件当帧还没挂上焦点节点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  /// 收起并清词（Esc / 收起钮 / 空查询时点外部），焦点还给「⌕」钮。
  void _closeSearch() {
    setState(() {
      _searching = false;
      _activeNoteId = null;
      _searchInput.clear();
    });
    _searchButtonFocus.requestFocus();
  }

  /// 搜索框内的键盘导航：↑/↓ 移动高亮、Enter 打开当前高亮项。
  ///
  /// 挂在 [_searchFocus] 的 `onKeyEvent` 上（不是 [CallbackShortcuts]）：
  /// 焦点节点的回调**先于** EditableText 的方向键默认处理，否则 ↑/↓ 会被
  /// 当成"光标移动"吃掉。
  KeyEventResult _onSearchKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveActive(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveActive(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _openActive();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 在过滤结果里移动高亮（首次按下从首 / 尾进入）。
  void _moveActive(int delta) {
    if (_shown.isEmpty) return;
    final int cur = _activeNoteId == null
        ? -1
        : _shown.indexWhere((Note n) => n.id == _activeNoteId);
    final int next = cur < 0
        ? (delta > 0 ? 0 : _shown.length - 1)
        : (cur + delta).clamp(0, _shown.length - 1);
    setState(() => _activeNoteId = _shown[next].id);
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealActive());
  }

  /// 高亮行走到视口外时滚进来（帧末做：要等新布局）。
  void _revealActive() {
    if (!mounted) return;
    final BuildContext? anchor = _activeRowKey.currentContext;
    if (anchor == null) return;
    Scrollable.ensureVisible(
      anchor,
      duration: Tokens.durationFast,
      curve: Curves.easeOut,
    );
  }

  /// Enter：打开当前高亮项；无高亮时只有"唯一结果"才代为打开（多条不猜）。
  void _openActive() {
    if (_shown.isEmpty) return;
    final String? id = _activeNoteId;
    if (id != null) {
      ref.read(locateProvider.notifier).locate(noteId: id);
      return;
    }
    if (_shown.length == 1) {
      ref.read(locateProvider.notifier).locate(noteId: _shown.first.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    final HomeView view = ref.watch(
      navHistoryProvider.select((NavHistoryState s) => s.view),
    );
    final List<Note> items = ref.watch(
      homeItemsProvider((
        view: view,
        tag: ref.watch(searchNotifierProvider).activeTag,
      )),
    );
    final String? selectedId = ref.watch(selectedNoteIdProvider);

    // 页内过滤：命中标题或摘要（大小写不敏感；中文天然子串命中）。
    final String query = _searchInput.text.trim();
    final List<Note> shown = query.isEmpty
        ? items
        : items
              .where(
                (Note n) =>
                    noteDisplayTitle(n)
                        .toLowerCase()
                        .contains(query.toLowerCase()) ||
                    n.summary.toLowerCase().contains(query.toLowerCase()),
              )
              .toList(growable: false);
    // 键盘导航用同一份顺序（见 [_moveActive]）。
    _shown = shown;

    // **按时间分组**（2026-10-21 用户定，方案 A）：组头（今天 / 昨天 / `12 月 31 日`）
    // 替行内日期说话，行内不再显示"2 天前"——那玩意儿每行重复同一天、还把右缘
    // 占成一条竖列（见 [_NoteRow]）。
    //
    // 只在**列表顺序本身是时间顺序**时分组：默认「最近编辑」；收藏视图按收藏时间
    // 排（不是 revisedAt）、标题 / 最近创建排序同理 ⇒ 那些情况退回平铺。
    final bool grouped =
        view != HomeView.favorites &&
        ref.watch(homeSortProvider) == NoteSort.revised;
    // 组头与行交错成扁平列表，交给一个 ListView.builder 渲染（组头 = String，
    // 行 = Note）。
    final List<Object> rows = <Object>[];
    if (grouped) {
      String? label;
      for (final Note n in shown) {
        final String next = dayLabel(n.revisedAt);
        if (next != label) {
          rows.add(next);
          label = next;
        }
        rows.add(n);
      }
    } else {
      rows.addAll(shown);
    }
    // ⚠️ 灵感**不走这里**：它是独立的一页纸流（`StreamView`，由外壳直接挂载）。

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 第一行 = **工具行**：折叠钮悬浮在卡左上角（独立区域、位置不动，
        // 本行只给它让位）；**右簇整体靠右** = 搜索 / 新建（新建最右，
        // 2026-11-09 用户定；筛选已下移到第二行）。点「搜索」整行换成输入框，
        // 右簇一起让位。
        Padding(
          // 上/下留白 = 编辑页按钮带同值；右侧取 spaceSm(8)——2026-11-09 用户定：
          // 比编辑页右留白（spaceMd 12）再收 4，新建钮更贴右缘。
          // ⚠️ 这是**有意偏差**，别按"与编辑页一致"改回去。
          padding: const EdgeInsets.fromLTRB(
            _kHeadToolInset,
            _kHeadBandPadding,
            Tokens.spaceSm,
            _kHeadBandPadding,
          ),
          child: AnimatedSwitcher(
            duration: Tokens.durationFast,
            child: _searching
                ? TapRegion(
                    // "点外部即关"**只对空查询生效**：有词时点外部（含点结果
                    // 查看笔记）**不关**，否则刚搜到就断了；退出搜索只走
                    // 关闭钮 / Esc（两者都清空）。
                    // 与「⌕」钮同组 ⇒ 点搜索钮自己不算"点外部"。
                    groupId: _searchTapGroupId,
                    onTapOutside: (_) {
                      if (_searchInput.text.trim().isEmpty) _closeSearch();
                    },
                    child: _ListSearchField(
                      key: const ValueKey<String>('list-search'),
                      hint: view == HomeView.canvas ? '搜索画布' : '搜索笔记',
                      controller: _searchInput,
                      focusNode: _searchFocus,
                      onClose: _closeSearch,
                      resultCount: shown.length,
                    ),
                  )
                : Row(
                    key: const ValueKey<String>('list-head-actions'),
                    // **右簇整体靠右**；折叠钮悬浮在卡左上角、是独立区域，不参与
                    // 这一排（2026-11-09 用户定：搜索在右、新建最右；筛选已移到
                    // 下方「视图名 + 篇数」行的右端，见下一段）。
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      // 与展开后的搜索框**同组**（[TapRegion]）：点「⌕」开搜索的那
                      // 一下不算"点外部"，否则刚展开就自己关掉。
                      TapRegion(
                        groupId: _searchTapGroupId,
                        child: AppIconButton(
                          tooltip: '搜索',
                          // 收起搜索后焦点回这枚钮（键盘用户不用再 Tab 一圈）。
                          focusNode: _searchButtonFocus,
                          // 列表顶工具行 2026-10-25 换 Fluent（见 [CustomIcons]）。
                          icon: CustomIcons.search(size: Tokens.iconSm),
                          onPressed: _openSearch,
                        ),
                      ),
                      const SizedBox(width: Tokens.spaceXxs),
                      // 新建（`+ ▾`）：左半直建当前页类型，右半开托盘；**最右端**。
                      _ListNewButton(view: view),
                    ],
                  ),
          ),
        ),
        // 第二行 = **视图名 + 篇数 + 筛选**（筛选 2026-11-09 从工具行搬来，
        // 2026-11-17 挪到**篇数右边**紧挨着——它整理的是"当前这个列表"，语义
        // 挨着列表名与篇数；此前的行右端位置撤掉，"漏斗对齐＋中心"的光学约定
        // 随之作废）。皮肤与日历小按钮同款（4px 圆角方件 + hairline、透明底、
        // hover 才亮，见 [FilterMenuButton]）。
        //
        // ⚠️ 行高由 [FilterMenuButton] 的热区 20 决定（不是 28）：文字 18 居中
        // 只下沉 1px，标题行不会被撑高（2026-11-17 用户定热区维持 20）。
        // 📌 bottom = [Tokens.spaceSm](8)：2026-11-15 加回。它原本就是 8，
        // 2026-11-09 为容纳热区 28 的筛选钮临时减到 0，热区降到 20 后没跟回来。
        // 加在行**外** ⇒ 标题文字的 y 不动，只是发丝下移 8。
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Tokens.spaceMd,
            0,
            Tokens.spaceMd,
            Tokens.spaceSm,
          ),
          child: Row(
            children: <Widget>[
              Text(
                _viewLabel(view),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: Bauhaus.ink(b),
                ),
              ),
              const SizedBox(width: Tokens.spaceXs),
              Text(
                '${shown.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Bauhaus.inkMuted(b),
                ),
              ),
              const SizedBox(width: Tokens.spaceSm),
              // 热区 20：本行行高由它决定，28 会把标题行撑高（见组件注释）。
              const FilterMenuButton(size: 20),
            ],
          ),
        ),
        // 头下发丝（通栏，结构线：固定头 ↔ 滚动体；非行间装饰线）。
        // 2026-11-16 改 [Bauhaus.dividerSoft]：侧栏分区线比全局发丝淡一档。
        Container(height: 1, color: Bauhaus.dividerSoft(b)),
        // 体：滚动条目 / 空态。
        Expanded(
          child: shown.isEmpty
              ? _ListEmpty(view: view, query: query)
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (BuildContext context, int i) {
                    final Object row = rows[i];
                    // 组头 = String（不可点、不进焦点链，只做分段）。
                    if (row is String) {
                      return _RowHeader(
                        // key 钉在**组名**：组头随日期变化时靠它换元素，
                        // 不会把上一个组头的 State 借给新组。
                        key: ValueKey<String>('note-row-header-$row'),
                        label: row,
                        first: i == 0,
                      );
                    }
                    final Note n = row as Note;
                    return _NoteRow(
                      // key 钉在 **noteId**（2026-10-21）：`ListView.builder` 按**下标**
                      // 复用 Element，无 key 时 `_NoteRowState` 里的 hover / 键盘焦点锚
                      // 会跟着**位置**走而不是跟着笔记走——新建一篇插到最前，所有行下移
                      // 一格，锚点就错配到别的笔记上。与网格卡片 `_NoteCard`
                      //（`note-card-$id`）同一处理。
                      key: ValueKey<String>('note-row-${n.id}'),
                      note: n,
                      selected: n.id == selectedId,
                      active: n.id == _activeNoteId,
                      query: query,
                      anchorKey: n.id == _activeNoteId ? _activeRowKey : null,
                      onOpen: () => ref
                          .read(locateProvider.notifier)
                          .locate(noteId: n.id),
                      onDelete: () => _trash(context, ref, n),
                      onToggleFavorite: () =>
                          ref.read(notesProvider.notifier).togglePromoted(n),
                      // ↑/↓：读当前顺序 + 选中，算上/下一篇，走 [LocateNotifier.preview]
                      // （静默选中、**不入历史**，不刷爆前进/后退栈）。选中行自己在
                      // didUpdateWidget 里滚入视野 + 接管焦点（焦点锚跟着选中走）。
                      onNavigate: (int delta) {
                        final String? cur = ref.read(selectedNoteIdProvider);
                        final int i = cur == null
                            ? -1
                            : items.indexWhere((Note n) => n.id == cur);
                        final int target = i < 0
                            ? (delta > 0 ? 0 : items.length - 1)
                            : (i + delta).clamp(0, items.length - 1);
                        if (target == i) return;
                        ref
                            .read(locateProvider.notifier)
                            .preview(noteId: items[target].id);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 删除 = 软删进**全局回收站**（30 天后自动彻底删除）。
  Future<void> _trash(BuildContext context, WidgetRef ref, Note note) async {
    final bool ok = await showStreamConfirm(
      context: context,
      title: '移入回收站',
      message: '将「${noteDisplayTitle(note)}」移入回收站？30 天后自动彻底删除。',
      confirmLabel: '移入回收站',
    );
    if (!ok) return;
    await ref.read(notesProvider.notifier).trashNote(note.id);
  }
}

/// 把 [text] 里每一处命中 [query] 的片段切成 span：普通段用 [base]、命中段用
/// [hit]。大小写不敏感（中文不受影响）；[query] 为空 ⇒ 单段原文。
List<InlineSpan> _highlightSpans(
  String text,
  String query,
  TextStyle base,
  TextStyle hit,
) {
  final String q = query.trim();
  if (q.isEmpty) {
    return <InlineSpan>[TextSpan(text: text, style: base)];
  }
  final String lowerText = text.toLowerCase();
  final String lowerQuery = q.toLowerCase();
  final List<InlineSpan> spans = <InlineSpan>[];
  int start = 0;
  int at = lowerText.indexOf(lowerQuery);
  while (at >= 0) {
    if (at > start) {
      spans.add(TextSpan(text: text.substring(start, at), style: base));
    }
    spans.add(TextSpan(text: text.substring(at, at + q.length), style: hit));
    start = at + q.length;
    at = lowerText.indexOf(lowerQuery, start);
  }
  if (start < text.length) {
    spans.add(TextSpan(text: text.substring(start), style: base));
  }
  if (spans.isEmpty) {
    spans.add(TextSpan(text: text, style: base));
  }
  return spans;
}

String _viewLabel(HomeView v) => switch (v) {
  HomeView.timeline => '灵感',
  HomeView.all => '全部',
  HomeView.notes => '笔记',
  HomeView.canvas => '画布',
  HomeView.calendar => '日历',
  HomeView.favorites => '收藏',
};

/// 列表内的**日期组头**（今天 / 昨天 / `12 月 31 日`）：一句 labelSmall，左对齐
/// 行文字左缘（= 行的 horizontal padding），不可点、不进焦点链。
///
/// 读法沿用灵感页的日期组头（`stream_view._DayHeader`）：时间信息由组头承担，
/// 行内不再重复（2026-10-21 用户定，方案 A）。
class _RowHeader extends StatelessWidget {
  const _RowHeader({super.key, required this.label, this.first = false});

  final String label;

  /// 是不是**列表第一组**：第一组紧贴表头分界线，顶距收成 `spaceSm`；
  /// 其余组之间要拉开段落感，用 `spaceLg`（2026-10-21 用户定）。
  final bool first;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Tokens.spaceMd,
        first ? Tokens.spaceSm : Tokens.spaceLg,
        Tokens.spaceMd,
        Tokens.spaceXs,
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

/// 托盘宽（180：容得下最长的一条「导入 Markdown…」）。
const double _kTrayWidth = 180;

/// 列表头的**新建分半钮**（2026-10-21 用户定，复刻 ima 的 `+ ▾`）：
/// 左半 `+` 直建**当前页类型**（笔记页建笔记、画布页建画布），右半 `▾` 开托盘
/// （2026-11-09 起**只留导入**：新建两项与主区重复，已撤）。
///
/// 刻意**不复用** [NewNoteCapsule]：那个是"整块点击即开托盘"（轨上在用，交互已
/// 定型），这里要的是"主按钮直接建 + 箭头开托盘"两种分工。
class _ListNewButton extends ConsumerStatefulWidget {
  const _ListNewButton({required this.view});

  final HomeView view;

  @override
  ConsumerState<_ListNewButton> createState() => _ListNewButtonState();
}

class _ListNewButtonState extends ConsumerState<_ListNewButton> {
  /// 托盘开合（供箭头翻转）：`MenuAnchor` 的 onOpen / onClose 驱动。
  bool _menuOpen = false;

  @override
  Widget build(BuildContext context) {
    final Brightness b = Theme.of(context).brightness;
    final bool canvasPage = widget.view == HomeView.canvas;

    return MenuAnchor(
      style: MenuStyle(
        elevation: const WidgetStatePropertyAll<double?>(0),
        // 面板本体不涂色：真正的面由 menuChildren 里的 [AppFloatSurface] 画
        // （同 `NewNoteCapsule` 的口径，主题 surface 实色）。
        backgroundColor: const WidgetStatePropertyAll<Color?>(
          Colors.transparent,
        ),
        side: const WidgetStatePropertyAll<BorderSide?>(BorderSide.none),
        shape: WidgetStatePropertyAll<OutlinedBorder?>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Tokens.radiusLg),
          ),
        ),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry?>(
          EdgeInsets.zero,
        ),
        // 从箭头**正下方**向下展开（左缘对齐、顶边贴底边）——零布局位移。
        alignment: AlignmentDirectional.bottomStart,
        minimumSize: const WidgetStatePropertyAll<Size?>(Size(_kTrayWidth, 0)),
      ),
      alignmentOffset: const Offset(0, Tokens.spaceXxs),
      // ⚠️ `MenuAnchor` **不会**自动在点击 child 时开菜单（官方用法就是按钮的
      // `onPressed` 里自己 `controller.open()`）。所以箭头必须拿到 builder 里的
      // 控制器、自己 toggle——只挂个装饰性箭头会"点了没反应"。
      onOpen: () => setState(() => _menuOpen = true),
      onClose: () => setState(() => _menuOpen = false),
      builder: (BuildContext context, MenuController controller, Widget? _) =>
          AppSplitIconButton(
            // 左半 = 直接新建（当前页类型）；右半 = 开托盘。两半同属一枚
            // 控件外壳，整块亮 + 当前半再加深（2026-11-09 方案 A）。
            // 2026-11-09 用户定：tooltip 统一「新建」，两页不再写死类型——
            // 按钮本来就是"建当前页类型"，画布页也不必重复提示。
            primaryTooltip: '新建',
            // 列表顶新建钮 2026-10-28 换 Fluent `tab-add`（32 档 Light，
            // 用户指定）：标签页 + 圆形加号，与搜索 / 筛选同属 Fluent 家族。
            primaryIcon: CustomIcons.tabAdd(size: Tokens.iconSm),
            onPrimary: () => unawaited(
              runCommandById(ref, canvasPage ? 'canvas.new' : 'note.new'),
            ),
            // 菜单开着时三角上翻 + 整块保持激活底色（"这是个下拉"的线索）。
            // 8px 实心三角：只当角标，不再是一枚"图标"（[Tokens.iconMicro]）。
            secondaryTooltip: '更多',
            secondaryIcon: _menuOpen
                ? CustomIcons.caretUp(size: Tokens.iconMicro)
                : CustomIcons.caretDown(size: Tokens.iconMicro),
            secondaryActive: _menuOpen,
            onSecondary: () {
              if (_menuOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
          ),
      // 2026-11-09 用户定：托盘**只保留导入**。「新建笔记 / 新建画布」由主区
      // 「＋」按当前页类型直接建（画布页建画布），菜单里再列两遍是重复入口；
      // 两项与它们之间的发丝分隔线一并撤掉。
      menuChildren: <Widget>[
        AppFloatSurface(
          color: Bauhaus.surface(b),
          borderRadius: BorderRadius.circular(Tokens.radiusLg),
          width: _kTrayWidth,
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 导入 = **新建**（不覆盖）：md 走 appflowy 的 md 解析器、
              // 画布走 bundle 还原，两条链路都落在 importNote 上。
              // ⚠️ 托盘行**不放快捷键提示**：180 宽放"图标 + 标签 +
              // Ctrl+Shift+N" 会溢出 52px（实测）。键位由命令面板 / 设置
              // 里的键位表负责，这里只给动作本身。
              _TrayTile(
                icon: tabler.Download(
                  height: Tokens.iconMdSm,
                  width: Tokens.iconMdSm,
                  strokeWidth: Tokens.iconStroke,
                  colorFilter: ui.ColorFilter.mode(
                    Bauhaus.ink(b),
                    ui.BlendMode.srcIn,
                  ),
                ),
                label: canvasPage ? '导入画布文件…' : '导入 Markdown…',
                onTap: () => unawaited(_runImport(ref, canvasPage)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 跑导入并把结果接到定位 / 报错上。
  Future<void> _runImport(WidgetRef ref, bool canvasPage) async {
    final NotesNotifier notes = ref.read(notesProvider.notifier);
    final ImportOutcome outcome = canvasPage
        ? await importCanvasNote(notes, media: ref.read(mediaResolverProvider))
        : await importMarkdownNote(notes);
    if (!mounted) return;
    final String? error = outcome.error;
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    final Note? note = outcome.note;
    if (note == null) return; // 用户取消
    // 建完就打开（带焦点：导入就是为了接着看 / 改）。
    ref.read(locateProvider.notifier).locate(noteId: note.id, focus: true);
  }
}

/// 托盘里的一行：图标 + 标签，36 高，hover 铺底。
///
/// 标签走 `Expanded` + 省略号：托盘宽 180，**任何**标签都不许把行撑溢出
/// （"导入 Markdown…" 差 5px 就溢出过一次）。
class _TrayTile extends StatefulWidget {
  const _TrayTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Widget icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_TrayTile> createState() => _TrayTileState();
}

class _TrayTileState extends State<_TrayTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 36,
          margin: const EdgeInsets.symmetric(horizontal: Tokens.spaceXxs),
          padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceSm),
          decoration: BoxDecoration(
            color: _hover ? AppTheme.hoverOverlay(b) : Colors.transparent,
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
          ),
          child: Row(
            children: <Widget>[
              widget.icon,
              const SizedBox(width: Tokens.spaceSm),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Bauhaus.ink(b),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 页内搜索框（2026-10-21）：点 ⌕ 后**整行替换**工具钮（ima 同款）。
///
/// 32 高、1px 发丝边、左放大镜、右**常驻**收起钮；Esc / 点外部收起并清词。
/// 过滤逻辑在 [_NoteListColumnState]（标题 + 摘要内存过滤），本件只管输入。
class _ListSearchField extends StatelessWidget {
  const _ListSearchField({
    super.key,
    required this.hint,
    required this.controller,
    required this.focusNode,
    required this.onClose,
    required this.resultCount,
  });

  final String hint;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClose;

  /// 当前命中条数（显示在输入框右侧、收起钮左边）。
  final int resultCount;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    final Color line = Bauhaus.line(b);
    final Widget magnifier = IconTheme(
      data: IconThemeData(color: Bauhaus.inkMuted(b), size: Tokens.iconMdSm),
      // 列表顶工具行 2026-10-25 换 Fluent（仅此行，见 [CustomIcons]）。
      child: CustomIcons.search(size: Tokens.iconSm),
    );
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): onClose,
      },
      child: Container(
        height: Tokens.headerActionSize,
        padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceSm),
        decoration: BoxDecoration(
          color: Bauhaus.surface(b),
          borderRadius: BorderRadius.circular(Tokens.radiusMd),
          border: Border.all(color: line),
        ),
        child: Row(
          children: <Widget>[
            magnifier,
            const SizedBox(width: Tokens.spaceXs),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                cursorColor: theme.colorScheme.primary,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Bauhaus.ink(b),
                ),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  hintText: hint,
                  hintStyle: theme.textTheme.bodySmall?.copyWith(
                    color: Bauhaus.inkMuted(b),
                  ),
                  // 四个状态全置空：主题的 inputDecorationTheme 有描边框
                  // （表单场景），只写 border 会被 enabledBorder 盖掉。
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                ),
              ),
            ),
            // 命中计数（2026-10-28）：恒显——0 条也是信息（配下方空态）。
            const SizedBox(width: Tokens.spaceXs),
            Text(
              '$resultCount 条',
              style: theme.textTheme.labelSmall?.copyWith(
                color: Bauhaus.inkMuted(b),
              ),
            ),
            // 收起钮**常驻**（2026-10-28 用户实报"点开后关不掉"）：不输入词时
            // 也必须留一个可见的关闭入口——"点外部即关"只是兜底，可见入口是主路。
            Tooltip(
              message: '关闭搜索',
              child: GestureDetector(
                onTap: onClose,
                child: IconTheme(
                  data: IconThemeData(
                    color: Bauhaus.inkMuted(b),
                    size: Tokens.iconMdSm,
                  ),
                  // 列表顶工具行 2026-10-25 换 Fluent（仅此行，见 [CustomIcons]）。
                  child: CustomIcons.x(size: Tokens.iconSm),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 列表列空态（当前视图 / 筛选下没有笔记）。
class _ListEmpty extends StatelessWidget {
  const _ListEmpty({required this.view, this.query = ''});

  final HomeView view;

  /// 页内搜索的查询词（非空 ⇒ 空态说"没有匹配"，不说"还没有"）。
  final String query;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    final String text = query.isNotEmpty
        ? '没有匹配「$query」'
        : switch (view) {
            HomeView.favorites => '还没有收藏的笔记',
            HomeView.notes => '还没有笔记',
            HomeView.canvas => '还没有画布',
            _ => '这个视图还没有笔记',
          };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Tokens.spaceLg),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: Bauhaus.inkMuted(b),
          ),
        ),
      ),
    );
  }
}

/// 单行笔记：标题（1 行 w600 浓墨）+ 摘要（2 行 w400 淡墨）+ 右对齐相对时间。
/// **行首不放 kind 图标**（2026-10-21 用户定），**删除走右键菜单**（同日定，行内
/// 不再有垃圾桶按钮——常驻的时间 + 桶把右缘占成一条竖列，视觉很重）。
/// 选中 / hover 底与 60 轨同口径（选中 = hover 2×）。
class _NoteRow extends StatefulWidget {
  const _NoteRow({
    super.key,
    required this.note,
    required this.selected,
    required this.active,
    required this.query,
    required this.onOpen,
    required this.onNavigate,
    required this.onDelete,
    required this.onToggleFavorite,
    this.anchorKey,
  });

  final Note note;
  final bool selected;

  /// 键盘导航的高亮行（搜索态）。与 [selected]（真正打开的笔记）是两回事：
  /// 高亮只表示"↑/↓ 移到了这行"，按 Enter 才打开。
  final bool active;

  /// 搜索词（非空 ⇒ 标题 / 摘要里高亮命中片段）。
  final String query;

  /// 高亮行的滚动锚（只有当前高亮那行为非空，用于滚进视口）。
  final Key? anchorKey;

  final VoidCallback onOpen;

  /// ↑/↓ 由本行方向键快捷键触发，回调给父列切上/下一篇（父才知道全局顺序）。
  final ValueChanged<int> onNavigate;

  /// 行内「删除」（软删进全局回收站）。
  final VoidCallback onDelete;

  /// 收藏 / 取消收藏（`Note.promotedAt` 非空 = 已收藏；收藏项在列表置顶，
  /// 见 `NoteStore.allNotes` 的 ORDER BY）。
  final VoidCallback onToggleFavorite;

  @override
  State<_NoteRow> createState() => _NoteRowState();
}

/// ↑/↓ 的意图（带方向 delta）：行内 [SingleActivator] 快捷键映射到它，动作回调给父
/// 切上/下一篇——父才知道全局顺序，行只知道"我被按了"。
class _RowNavIntent extends Intent {
  const _RowNavIntent(this.delta);
  final int delta;
}

class _NoteRowState extends State<_NoteRow> {
  bool _hover = false;

  /// 本行的条目菜单是否正开着（2026-11-20 修 bug：点「···」后鼠标移向菜单时
  /// `onExit` 把 [_hover] 置 false ⇒ 悬浮底色消失）。菜单开着 ⇒ 行保持 hover 底色，
  /// 与移动端 `NoteListView._menuOpen` 同一先例。
  bool _menuOpen = false;
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_NoteRow old) {
    super.didUpdateWidget(old);
    // 被选中（点开 / ↑↓ 预览切到这篇）⇒ 帧末把自己滚进视野 + 接管焦点。这样 ↑/↓ 的
    // "键盘锚"始终跟着选中行走，连续按不会断；只抢**行**的焦点、不抢编辑器（locate
    // 不带 focus）。放 post-frame：didUpdateWidget 在 build 期，布局还没定。
    if (widget.selected && !old.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _revealIfNeeded();
        _focus.requestFocus();
      });
    }
  }

  /// **只在看不见时**才滚动（2026-10-21 用户定：点一下就"置顶"太跳）。
  ///
  /// 此前直接调 `Scrollable.ensureVisible`：它默认 `alignment: 0.0`，会把目标行
  /// 对齐到视口**顶端** —— 于是点一行**当前就可见**的笔记，整列也会猛地滚到顶
  ///（用户读作"点击后这一条被置顶了"）。这里先量：整行已在视口内就一动不动，
  /// 只有键盘 ↑/↓ 走到折叠区外时才滚。
  void _revealIfNeeded() {
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    final RenderObject? box = context.findRenderObject();
    if (scrollable == null || box is! RenderBox || !box.hasSize) return;
    final RenderAbstractViewport? viewport = RenderAbstractViewport.maybeOf(
      box,
    );
    if (viewport == null) return;

    // 对齐顶端 / 底端所需的两个滚动偏移：当前像素区间能同时容下这两个 ⇒ 完全可见。
    final ScrollPosition pos = scrollable.position;
    final double alignTop = viewport.getOffsetToReveal(box, 0.0).offset;
    final double alignBottom = viewport.getOffsetToReveal(box, 1.0).offset;
    final double visibleMin = pos.pixels;
    final double visibleMax = pos.pixels + pos.viewportDimension;
    if (alignTop >= visibleMin && alignBottom <= visibleMax) return; // 已整行可见

    Scrollable.ensureVisible(
      context,
      duration: Tokens.durationFast,
      curve: Curves.easeOut,
    );
  }

  /// 条目菜单（右键）：目前在列里的动作只有「删除」（软删进全局回收站）。
  ///
  /// 入口与样式对齐左侧旧列表 `NoteListView._openMenu`：零尺寸矩形锚在指针处、
  /// 危险项用 `scheme.error`。
  Future<void> _openMenu(Offset position) async {
    // 菜单开着期间把本行标成"菜单目标"（2026-11-20 修 bug：点「···」后鼠标移向
    // 菜单 ⇒ onExit 把 _hover 置 false ⇒ 悬浮底色消失，不知道点到哪行）。照移动端
    // `NoteListView._openMenu` 的 `_menuOpen` 先例：菜单开着 ⇒ 行保持 hover 底色。
    // `showMenu` 在**菜单关闭后**才返回，所以这是一对 setState。
    setState(() => _menuOpen = true);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool promoted = widget.note.promotedAt != null;
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: <PopupMenuEntry<void>>[
        // 收藏 / 取消收藏（2026-11-20 用户定）：与移动端 `NoteListView._openMenu`
        // 同款（收藏 / 删除）。收藏项列表置顶（promoted_at，见 NoteStore.allNotes）。
        PopupMenuItem<void>(
          onTap: widget.onToggleFavorite,
          child: Row(
            children: <Widget>[
              if (promoted)
                const tabler.StarFilled(
                  height: Tokens.iconSm,
                  width: Tokens.iconSm,
                  strokeWidth: Tokens.iconStroke,
                )
              else
                const tabler.Star(
                  height: Tokens.iconSm,
                  width: Tokens.iconSm,
                  strokeWidth: Tokens.iconStroke,
                ),
              const SizedBox(width: Tokens.spaceSm),
              Text(promoted ? '取消收藏' : '收藏'),
            ],
          ),
        ),
        PopupMenuItem<void>(
          onTap: widget.onDelete,
          child: Row(
            children: <Widget>[
              tabler.Trash(
                height: Tokens.iconSm,
                width: Tokens.iconSm,
                strokeWidth: Tokens.iconStroke,
                color: scheme.error,
              ),
              const SizedBox(width: Tokens.spaceSm),
              Text('删除', style: TextStyle(color: scheme.error)),
            ],
          ),
        ),
      ],
    );
    // 菜单关闭（showMenu 返回）⇒ 复位「菜单目标」标记。此时若鼠标仍悬在本行，
    // `_hover` 仍为 true ⇒ 底色保持；若鼠标已移到菜单后没回来，底色自然退去。
    if (mounted) setState(() => _menuOpen = false);
  }

  /// 「···」按钮的锚点（菜单贴在按钮下弹出）。
  final GlobalKey _moreKey = GlobalKey();

  /// 点「···」→ 在按钮处弹条目菜单（与右键同一 [_openMenu]）。
  void _openMenuAtButton() {
    final RenderBox? box =
        _moreKey.currentContext?.findRenderObject() as RenderBox?;
    final Offset pos =
        box?.localToGlobal(box.size.bottomRight(Offset.zero)) ?? Offset.zero;
    unawaited(_openMenu(pos));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Brightness b = theme.brightness;
    final Note n = widget.note;
    final bool selected = widget.selected;
    // 选中底 = hover 的 2×（与 60 轨 [_RailButton] 同口径，2026-10-21 用户定）。

    final Color selectedBg = b == Brightness.dark
        ? Colors.white.withValues(alpha: 0.12)
        : scheme.onSurface.withValues(alpha: 0.08);
    // 键盘高亮：介于 hover 与 selected 之间 —— 与"已打开"的选中态可区分。
    final Color activeBg = b == Brightness.dark
        ? Colors.white.withValues(alpha: 0.07)
        : scheme.onSurface.withValues(alpha: 0.05);
    final Color bg = selected
        ? selectedBg
        : (widget.active
              ? activeBg
              // 菜单开着也算 hover（2026-11-20 修 bug）：点「···」后鼠标移向菜单
              // 时 onExit 会置 _hover=false，靠 _menuOpen 保住底色 ⇒ 知道点到哪行。
              : (_hover || _menuOpen
                    ? AppTheme.hoverOverlay(b)
                    : Colors.transparent));

    final String title = noteDisplayTitle(n);
    final String summary = n.summary.trim();

    // 搜索命中片段：普通段沿用原样式，命中段用主色 + 加粗（只给命中的那截
    // 上色，Apple Notes 同款）。
    final TextStyle titleStyle =
        theme.textTheme.bodyMedium?.copyWith(
          color: Bauhaus.ink(b),
          fontWeight: FontWeight.w600,
        ) ??
        const TextStyle();
    final TextStyle summaryStyle =
        theme.textTheme.bodySmall?.copyWith(color: Bauhaus.inkMuted(b)) ??
        const TextStyle();
    final TextStyle hitStyle = titleStyle.copyWith(
      color: scheme.primary,
      fontWeight: FontWeight.w700,
    );

    // 无搜索词时保持普通 [Text]（`data` 可用——现有测试与 a11y 都按 `Text.data`
    // 认行）；只有带词才切 `Text.rich` 做命中高亮。
    Widget rich(String text, int maxLines, TextStyle base) =>
        widget.query.isEmpty
        ? Text(
            text,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: base,
          )
        : Text.rich(
            TextSpan(
              children: _highlightSpans(text, widget.query, base, hitStyle),
            ),
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
          );

    return MouseRegion(
      onEnter: (_) {
        if (!_hover) setState(() => _hover = true);
      },
      onExit: (_) {
        if (_hover) setState(() => _hover = false);
      },
      child: FocusableActionDetector(
        focusNode: _focus,
        mouseCursor: SystemMouseCursors.click,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowDown): _RowNavIntent(1),
          SingleActivator(LogicalKeyboardKey.arrowUp): _RowNavIntent(-1),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<Intent>(
            onInvoke: (_) {
              widget.onOpen();
              return null;
            },
          ),
          _RowNavIntent: CallbackAction<_RowNavIntent>(
            onInvoke: (_RowNavIntent intent) {
              widget.onNavigate(intent.delta);
              return null;
            },
          ),
        },
        child: Semantics(
          button: true,
          enabled: true,
          selected: selected,
          // 标签 = 显示标题（屏幕阅读器 / 焦点顺序测试靠它认行）。
          label: title,
          child: FocusRing(
            focusNode: _focus,
            // 环只给**键盘**（2026-10-21 用户定）——鼠标点行也会抢焦点
            //（为了 ↑/↓ 的键盘锚），环若跟着焦点走就会被误读成选中态。
            keyboardOnly: true,
            borderRadius: Bauhaus.radius,
            child: GestureDetector(
              onTap: () {
                // 点行即把键盘锚放到这行：紧接着按 ↑/↓ 能继续在列表里走。
                _focus.requestFocus();
                widget.onOpen();
              },
              // 右键（2026-10-21 用户定）：删除从行内挪进**条目菜单**——入口与
              // 样式对齐左侧旧列表 `NoteListView`（指针处弹出、危险项红字）。
              onSecondaryTapDown: (TapDownDetails d) =>
                  _openMenu(d.globalPosition),
              child: Container(
                // 键盘高亮行挂锚（滚进视口用）；其余行为 null。
                key: widget.anchorKey,
                // hover / 选中都做成**内缩的圆角块**（2026-10-21 用户定"和图标栏
                // 一致"）：60 轨的钮就是 36 圆角 pill，不是通栏色带。外缩 4 + 内距 8
                // = 原来的 12 ⇒ 文字左缘不动。
                margin: const EdgeInsets.symmetric(horizontal: Tokens.spaceXs),
                padding: const EdgeInsets.symmetric(
                  horizontal: Tokens.spaceMd - Tokens.spaceXs,
                  vertical: Tokens.spaceMd,
                ),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: Bauhaus.radius,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // 标题前**不再放 kind 图标**（2026-10-21 用户定：各页列表列统一去掉
                    // 行首图标，标题直接从行左缘起排，行更干净、也不靠小图标区分形态）。
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          rich(title, 1, titleStyle),
                          if (summary.isNotEmpty) ...<Widget>[
                            const SizedBox(height: Tokens.spaceXxs),
                            rich(summary, 2, summaryStyle),
                          ],
                        ],
                      ),
                    ),
                    // 「···」按钮（2026-11-20 用户定）：hover 露出，点击弹条目菜单
                    // （收藏 / 删除）。收藏入口收进菜单（不单列星标）；查看收藏走
                    // 筛选的「只看收藏」。`maintainSize` 让 hover 显隐不推挤标题。
                    Visibility(
                      visible: _hover,
                      maintainSize: true,
                      maintainAnimation: true,
                      maintainState: true,
                      child: IconButton(
                        key: _moreKey,
                        // tooltip 不叫「更多」——那会撞列表头「新建」分半钮副区的
                        // tooltip（`find.byTooltip('更多')`）。
                        tooltip: '更多操作',
                        iconSize: Tokens.iconXs,
                        style: IconButton.styleFrom(
                          minimumSize: const Size.square(
                            Tokens.headerActionSize,
                          ),
                          maximumSize: const Size.square(
                            Tokens.headerActionSize,
                          ),
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const tabler.Dots(
                          height: Tokens.iconXs,
                          width: Tokens.iconXs,
                          strokeWidth: Tokens.iconStroke,
                        ),
                        onPressed: _openMenuAtButton,
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
}
