import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import '../domain/note.dart';
import 'home_hub.dart'
    show
        FilterMenuButton,
        NoteSort,
        homeItemsProvider,
        homeKindFacetProvider,
        homeSortProvider;
import 'note_display.dart';
import 'providers.dart';
import 'search_provider.dart';
import 'stream_delete.dart' show showStreamConfirm;

/// 240px **笔记列表列**（主从布局的"主"，Option 2 进卡）：坐在浮面卡左格，右格是详情
/// （编辑器 / 画布 / 空态）。服务「全部 / 笔记 / 画布 / 收藏」四个主从视图——
/// 灵感是一页纸时间流，由外壳直接挂 `StreamView`，不经过这里（2026-10-17 收口）；
/// 日历整卡显示，也不经过这里。
///
/// - 头 = 视图名 + 篇数 + 「筛选」钮（[FilterMenuButton]：排序 / 形态 / 标签，全局控件）。
/// - 体 = 当前视图的笔记行（[homeItemsProvider]，已按排序 + 形态 + 标签过滤）。
/// - 行：点 / Enter 开（走 [locateProvider]，`focus` 默认 false ⇒ 焦点不被编辑器抢走）；
///   选中行（== [selectedNoteIdProvider]）铺 navSelectedTint 同款选中底（= hover 2×）。
///
/// ## 极简留白（2026-10-17 用户定）
/// 不用行间分割线（满格横线 = 表格感）——分层靠：① 留白（行 vertical padding spaceMd）；
/// ② 字重三级（标题 w600 浓墨 / 摘要 w400 淡墨 / 时间·图标 最小最淡）；③ 选中态淡色底。
class NoteListColumn extends ConsumerWidget {
  const NoteListColumn({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    final HomeView view = ref.watch(
      navHistoryProvider.select((NavHistoryState s) => s.view),
    );
    final List<Note> items = ref.watch(
      homeItemsProvider((
        view: view,
        tag: ref.watch(searchNotifierProvider).activeTag,
        kind: ref.watch(homeKindFacetProvider),
      )),
    );
    final String? selectedId = ref.watch(selectedNoteIdProvider);
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
      for (final Note n in items) {
        final String next = dayLabel(n.revisedAt);
        if (next != label) {
          rows.add(next);
          label = next;
        }
        rows.add(n);
      }
    } else {
      rows.addAll(items);
    }
    // ⚠️ 灵感**不走这里**：它是独立的一页纸流（`StreamView`，由外壳直接挂载）。

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 头：视图名 + 篇数 + 筛选钮。上 12 / 左 12 清开卡片圆角（_kPanelRadius=12）。
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Tokens.spaceMd,
            Tokens.spaceMd,
            Tokens.spaceSm,
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
                '${items.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Bauhaus.inkMuted(b),
                ),
              ),
              const Spacer(),
              const FilterMenuButton(),
            ],
          ),
        ),
        // 头下发丝（通栏，结构线：固定头 ↔ 滚动体；非行间装饰线）。
        Container(height: 1, color: Bauhaus.line(b)),
        // 体：滚动条目 / 空态。
        Expanded(
          child: items.isEmpty
              ? _ListEmpty(view: view)
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (BuildContext context, int i) {
                    final Object row = rows[i];
                    // 组头 = String（不可点、不进焦点链，只做分段）。
                    if (row is String) {
                      return _RowHeader(label: row, first: i == 0);
                    }
                    final Note n = row as Note;
                    return _NoteRow(
                      note: n,
                      selected: n.id == selectedId,
                      onOpen: () => ref
                          .read(locateProvider.notifier)
                          .locate(noteId: n.id),
                      onDelete: () => _trash(context, ref, n),
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
  const _RowHeader({required this.label, this.first = false});

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

/// 列表列空态（当前视图 / 筛选下没有笔记）。
class _ListEmpty extends StatelessWidget {
  const _ListEmpty({required this.view});

  final HomeView view;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    final String text = switch (view) {
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
    required this.note,
    required this.selected,
    required this.onOpen,
    required this.onNavigate,
    required this.onDelete,
  });

  final Note note;
  final bool selected;
  final VoidCallback onOpen;

  /// ↑/↓ 由本行方向键快捷键触发，回调给父列切上/下一篇（父才知道全局顺序）。
  final ValueChanged<int> onNavigate;

  /// 行内「删除」（软删进全局回收站）。
  final VoidCallback onDelete;

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
        Scrollable.ensureVisible(
          context,
          duration: Tokens.durationFast,
          curve: Curves.easeOut,
        );
        _focus.requestFocus();
      });
    }
  }

  /// 条目菜单（右键）：目前在列里的动作只有「删除」（软删进全局回收站）。
  ///
  /// 入口与样式对齐左侧旧列表 `NoteListView._openMenu`：零尺寸矩形锚在指针处、
  /// 危险项用 `scheme.error`。
  Future<void> _openMenu(Offset position) async {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: <PopupMenuEntry<void>>[
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
    final Color bg = selected
        ? selectedBg
        : (_hover ? AppTheme.hoverOverlay(b) : Colors.transparent);

    final String title = noteDisplayTitle(n);
    final String summary = n.summary.trim();

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
                // hover / 选中都做成**内缩的圆角块**（2026-10-21 用户定"和图标栏
                // 一致"）：60 轨的钮就是 36 圆角 pill，不是通栏色带。外缩 4 + 内距 8
                // = 原来的 12 ⇒ 文字左缘不动。
                margin: const EdgeInsets.symmetric(horizontal: Tokens.spaceXs),
                padding: const EdgeInsets.symmetric(
                  horizontal: Tokens.spaceMd - Tokens.spaceXs,
                  vertical: Tokens.spaceMd,
                ),
                decoration: BoxDecoration(color: bg, borderRadius: Bauhaus.radius),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // 标题前**不再放 kind 图标**（2026-10-21 用户定：各页列表列统一去掉
                    // 行首图标，标题直接从行左缘起排，行更干净、也不靠小图标区分形态）。
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Bauhaus.ink(b),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (summary.isNotEmpty) ...<Widget>[
                            const SizedBox(height: Tokens.spaceXxs),
                            Text(
                              summary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Bauhaus.inkMuted(b),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // 行内**不再显示日期**（2026-10-21 方案 A）：时间由上方组头
                    // （今天 / 昨天 / `12 月 31 日`）表达 ⇒ 每行右缘不再重复同一天，
                    // 行 = 纯标题 + 摘要。删除同样已收进右键菜单。
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
