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

/// 208px **笔记列表列**（主从布局的"主"，2026-10-16 Option 2 进卡方案）：坐在浮面卡
/// **左格**，右格是详情（编辑器 / 画布 / 空态）。取代原主页卡片墙——心流 / 全部 / 收藏
/// 三视图走它，开笔记不再整屏替换、列表常驻。
///
/// - 头 = 视图名 + 篇数 + 「筛选」钮（[FilterMenuButton]：排序 / 形态 / 标签，全局控件）。
/// - 体 = 当前视图的笔记行（[homeItemsProvider]，已按排序 + 形态 + 标签过滤）。
/// - 行：点 / Enter 开（走 [locateProvider]，`focus` 默认 false ⇒ 焦点不被编辑器抢走）；
///   选中行（== [selectedNoteIdProvider]）铺 navSelectedTint 同款选中底（= hover 2×）。
///
/// ## 极简留白（2026-10-17 用户定，完整版）
/// **不用行间分割线**（满格横线 = 表格感，长列表显乱）——分层靠三样：
/// ① **留白**：行 vertical padding 提到 spaceMd，行高自然、短行也不糊；
/// ② **字重三级**：标题 w600 浓墨 / 摘要 w400 淡墨 / 时间·图标 最小最淡；
/// ③ **选中态**：当前行的淡色底即"分隔"，静止干净、交互才显形。
/// **心流**再按 `revisedAt` 日期分桶（今天 / 昨天 / 前天 / 本周 / 更早），重复的日期从
/// 每行上移到**分组小标**、行内只留 图标 + 标题 + 摘要；分组顶多一档留白当"間"。
/// 全部 / 收藏（非时间流）不分组，日期保留行内（更小更淡）。
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
    final bool grouped = view == HomeView.timeline;

    // 拍平成一串条目：心流 = [分组标, 行, 行, 分组标, 行…]；其余 = [行, 行…]。
    // items 已按 revisedAt 倒序 ⇒ 同桶行必然相邻，遇新桶插一个分组标即可。
    final List<_ListItem> entries = <_ListItem>[];
    String? lastBucket;
    for (final Note n in items) {
      if (grouped) {
        final String bucket = _dateBucket(n.revisedAt);
        if (bucket != lastBucket) {
          entries.add(_HeaderItem(bucket));
          lastBucket = bucket;
        }
      }
      entries.add(_NoteItem(n));
    }

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
                  itemCount: entries.length,
                  itemBuilder: (BuildContext context, int i) {
                    final _ListItem e = entries[i];
                    if (e is _HeaderItem) {
                      return _GroupHeader(label: e.label);
                    }
                    final Note n = (e as _NoteItem).note;
                    return _NoteRow(
                      note: n,
                      selected: n.id == selectedId,
                      // 心流已按日期分组 ⇒ 行内不再显示日期；全部 / 收藏保留。
                      showDate: !grouped,
                      onOpen: () => ref
                          .read(locateProvider.notifier)
                          .locate(noteId: n.id),
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

/// `revisedAt` 的日期分桶（心流分组小标）：今天 / 昨天 / 前天 / 本周 / 更早（显日月，
/// 跨年带年）。本地时区、按"自然日"归一。
String _dateBucket(DateTime at) {
  final DateTime now = DateTime.now();
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime day = DateTime(at.year, at.month, at.day);
  final int diff = today.difference(day).inDays;
  if (diff <= 0) return '今天';
  if (diff == 1) return '昨天';
  if (diff == 2) return '前天';
  if (diff <= 6) return '本周';
  return at.year == now.year
      ? '${at.month} 月 ${at.day} 日'
      : '${at.year} 年 ${at.month} 月 ${at.day} 日';
}

/// 列表条目：要么一个分组小标（[_HeaderItem]），要么一行笔记（[_NoteItem]）。
sealed class _ListItem {}

class _HeaderItem extends _ListItem {
  _HeaderItem(this.label);
  final String label;
}

class _NoteItem extends _ListItem {
  _NoteItem(this.note);
  final Note note;
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

/// 分组小标（心流）：小字 + 微字距 + 淡墨，上面多一档留白当"間"（组与组的分隔全靠
/// 留白，不画线）。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    return Padding(
      // 上 spaceMd = 组间「間」（比行距再松一档）；下 spaceXs 贴近首行。
      padding: const EdgeInsets.fromLTRB(
        Tokens.spaceMd,
        Tokens.spaceMd,
        Tokens.spaceMd,
        Tokens.spaceXs,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: Bauhaus.inkMuted(b),
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
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
    this.showDate = true,
  });

  final Note note;
  final bool selected;
  final VoidCallback onOpen;
  final bool showDate;

  @override
  State<_NoteRow> createState() => _NoteRowState();
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
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<Intent>(
            onInvoke: (_) {
              widget.onOpen();
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
              onTap: widget.onOpen,
              child: Container(
                color: bg,
                // 行 vertical padding 提到 spaceMd：靠留白分隔，不靠线。
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
                    if (widget.showDate) ...<Widget>[
                      const SizedBox(width: Tokens.spaceSm),
                      Text(
                        relativeTime(n.revisedAt),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Bauhaus.inkMuted(b),
                        ),
                      ),
                    ],
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
