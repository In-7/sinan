import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_custom_icons.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import '../domain/note.dart';
import 'home_hub.dart'
    show FilterMenuButton, homeItemsProvider, homeKindFacetProvider;
import 'note_display.dart';
import 'providers.dart';
import 'search_provider.dart';

/// 240px **笔记列表列**（主从布局的"主"，Option 2 进卡）：坐在浮面卡左格，右格是详情
/// （编辑器 / 画布 / 空态）。**只服务「全部 / 收藏」**——速记（心流）是一页纸时间流，
/// 由外壳直接挂 `StreamView`，不经过这里（2026-10-17 收口）。
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
    // ⚠️ 速记（心流）**不走这里**：它是独立的一页纸流（`StreamView`，由外壳直接
    // 挂载）。列表列只服务「全部 / 收藏」——2026-10-17 前它还把 timeline 当成
    // "笔记时间流"并按日期分桶，与速记页形成两套语义（用户实报"改了没变化"）。
    //
    // 于是这里不再有分组条目，也没有"心流"这一档的专属显示口径。

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
                  itemCount: items.length,
                  itemBuilder: (BuildContext context, int i) {
                    final Note n = items[i];
                    return _NoteRow(
                      note: n,
                      selected: n.id == selectedId,
                      onOpen: () => ref
                          .read(locateProvider.notifier)
                          .locate(noteId: n.id),
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
}

String _viewLabel(HomeView v) => switch (v) {
  HomeView.timeline => '心流',
  HomeView.all => '全部',
  HomeView.calendar => '日历',
  HomeView.favorites => '收藏',
};

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

/// 单行笔记：kind 图标 + 标题（1 行 w600 浓墨）+ 摘要（2 行 w400 淡墨）[+ 右对齐相对
/// 时间，仅非心流]。选中 / hover 底与 60 轨同口径（选中 = hover 2×）。
class _NoteRow extends StatefulWidget {
  const _NoteRow({
    required this.note,
    required this.selected,
    required this.onOpen,
    required this.onNavigate,
  });

  final Note note;
  final bool selected;
  final VoidCallback onOpen;

  /// ↑/↓ 由本行方向键快捷键触发，回调给父列切上/下一篇（父才知道全局顺序）。
  final ValueChanged<int> onNavigate;

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

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Brightness b = theme.brightness;
    final Note n = widget.note;
    final bool selected = widget.selected;
    final bool isCanvas = n.kind == NoteKind.canvas;

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
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
            child: GestureDetector(
              onTap: () {
                // 点行即把键盘锚放到这行：紧接着按 ↑/↓ 能继续在列表里走。
                _focus.requestFocus();
                widget.onOpen();
              },
              child: Container(
                color: bg,
                // 行 vertical padding spaceMd：靠留白分隔，不靠线。
                padding: const EdgeInsets.symmetric(
                  horizontal: Tokens.spaceMd,
                  vertical: Tokens.spaceMd,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // kind 图标（装饰，退出语义）：画布 = 笔刷，文档 = 编辑。
                    Semantics(
                      excludeSemantics: true,
                      child: isCanvas
                          ? CustomIcons.brush(
                              size: Tokens.iconXs,
                              color: Bauhaus.inkMuted(b),
                            )
                          : CustomIcons.edit19(
                              size: Tokens.iconXs,
                              color: Bauhaus.inkMuted(b),
                            ),
                    ),
                    const SizedBox(width: Tokens.spaceSm),
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
                    const SizedBox(width: Tokens.spaceSm),
                    Text(
                      relativeTime(n.revisedAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Bauhaus.inkMuted(b),
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
