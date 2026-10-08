import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

// 键盘事件类型（↑↓ 换行 / Enter 打开）：KeyDownEvent / LogicalKeyboardKey
// 在 `services.dart`，不由 material 转出。
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/note.dart';
import '../theme/app_custom_icons.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'home_hub.dart'
    show NoteKindFacet, homeItemsProvider, homeKindFacetProvider;
import 'omni_bar.dart' show OmniBar;
import 'note_display.dart';
import 'providers.dart' show HomeView, locateProvider, notesProvider;

/// 「更早」分组的**折叠阈值**：超过这么多条就折成一行计数，点开再展开。
///
/// 取 200 的理由是**密度**：更早是"考古区"，一次铺几千行既无意义又拖慢首帧；
/// 真要翻找用搜索（Ctrl+K / 捕获条），不靠滚。
const int kOlderCollapseThreshold = 200;

/// 心流流的一个**分组**（今天 / 昨天 / 本周 / 本月 / 更早）。
class StreamGroup {
  const StreamGroup(this.label, this.notes);

  final String label;
  final List<Note> notes;
}

/// 按 `revisedAt` 分组（**纯函数**，可单测）。
///
/// - 键 = `revisedAt`（与 `allNotes` 的 `revised_at DESC` 同源 ⇒ 组内顺序沿用
///   入参顺序，不必再排一次）；
/// - **收藏不提升置顶**（保持时间线纯度——收藏走 favorites 视图）；
/// - 空组**不返回**（今天没写过就不出现"今天"这个头）；
/// - 「本周」以**周一**为始（与日历视图同口径）。
List<StreamGroup> groupByRecency(List<Note> notes, {DateTime? now}) {
  final DateTime n = now ?? DateTime.now();
  final DateTime today = DateTime(n.year, n.month, n.day);
  final DateTime yesterday = today.subtract(const Duration(days: 1));
  final DateTime weekStart = today.subtract(Duration(days: n.weekday - 1));

  final Map<String, List<Note>> buckets = <String, List<Note>>{};
  void add(String key, Note note) =>
      buckets.putIfAbsent(key, () => <Note>[]).add(note);

  for (final Note note in notes) {
    final DateTime r = note.revisedAt;
    final DateTime day = DateTime(r.year, r.month, r.day);
    if (day == today) {
      add('今天', note);
    } else if (day == yesterday) {
      add('昨天', note);
    } else if (!day.isBefore(weekStart)) {
      add('本周', note);
    } else if (r.year == n.year && r.month == n.month) {
      add('本月', note);
    } else {
      add('更早', note);
    }
  }

  const List<String> order = <String>['今天', '昨天', '本周', '本月', '更早'];
  return <StreamGroup>[
    for (final String key in order)
      if (buckets[key]?.isNotEmpty ?? false) StreamGroup(key, buckets[key]!),
  ];
}

/// **心流流**（2026-10-06，阶段 1 ②A）：主页的启动默认视图。
///
/// 与卡片网格的关系：同一个池子（同一个 [homeItemsProvider] 入参，形态 /
/// 标签 facet 同样生效）的**另一种投影**——卡片是"一眼扫读"，心流是"按时间
/// 回看"。所以排序仍走顶栏全局控件，心流不另起一套。
///
/// ⚠️ 这不是"最近编辑列表"：它按 `revisedAt` **分组**（今天 / 昨天 / …），
/// 组的存在本身就是信息（"我这周碰过哪些"）。
class StreamView extends ConsumerStatefulWidget {
  const StreamView({super.key, this.tag});

  /// 顶栏标签筛选（全局控件）⇒ 对心流同样生效。
  final String? tag;

  @override
  ConsumerState<StreamView> createState() => _StreamViewState();
}

class _StreamViewState extends ConsumerState<StreamView> {
  /// 「更早」组的展开态（默认折叠，见 [kOlderCollapseThreshold]）。
  bool _olderExpanded = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final NoteKindFacet kind = ref.watch(homeKindFacetProvider);
    final List<Note> items = ref.watch(
      homeItemsProvider((
        view: HomeView.timeline,
        tag: widget.tag,
        kind: kind,
      )),
    );

    if (items.isEmpty) {
      // 空库：顶栏捕获条已隐藏（见 [HomeHub] 的 `timelineEmpty`），这里用
      // 居中的大捕获条接管——"第一眼能打字的地方"就是它，不是一句灰字。
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '还没有笔记或画布',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: Tokens.spaceXs),
              Text(
                '在上面输入一句话，回车即创建',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Tokens.spaceLg),
              // 唯一自动聚焦的捕获条（顶栏那条已隐藏），空库首屏即聚焦。
              const OmniBar(),
            ],
          ),
        ),
      );
    }

    final List<_Entry> entries = _entriesOf(groupByRecency(items));
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        Tokens.spaceLg,
        0,
        Tokens.spaceLg,
        Tokens.spaceLg,
      ),
      itemCount: entries.length,
      itemBuilder: (BuildContext context, int i) => switch (entries[i]) {
        _GroupHeader(:final String label) => _SectionHeader(label: label),
        _NoteRow(:final Note note) => _StreamTile(note: note),
        _ShowMoreRow(:final int hidden) => _ShowMoreTile(
          hidden: hidden,
          onTap: () => setState(() => _olderExpanded = true),
        ),
      },
    );
  }

  /// 把分组摊平成一列（组头 / 行 / 「还有 N 篇」），供 [ListView.builder]
  /// 惰性渲染。
  List<_Entry> _entriesOf(List<StreamGroup> groups) {
    final List<_Entry> out = <_Entry>[];
    for (final StreamGroup g in groups) {
      out.add(_GroupHeader(g.label));
      final bool collapse =
          g.label == '更早' &&
          g.notes.length > kOlderCollapseThreshold &&
          !_olderExpanded;
      final List<Note> shown = collapse
          ? g.notes.take(kOlderCollapseThreshold).toList()
          : g.notes;
      for (final Note n in shown) {
        out.add(_NoteRow(n));
      }
      if (collapse) {
        out.add(_ShowMoreRow(g.notes.length - kOlderCollapseThreshold));
      }
    }
    return out;
  }
}

// ─── 摊平后的三种行 ───────────────────────────────────────────────────
sealed class _Entry {
  const _Entry();
}

class _GroupHeader extends _Entry {
  const _GroupHeader(this.label);
  final String label;
}

class _NoteRow extends _Entry {
  const _NoteRow(this.note);
  final Note note;
}

class _ShowMoreRow extends _Entry {
  const _ShowMoreRow(this.hidden);
  final int hidden;
}

/// 分组头（今天 / 昨天 / …）：小字灰，只做"这一坨是什么时候"的标签。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.spaceMd,
        Tokens.spaceMd,
        Tokens.spaceMd,
        Tokens.spaceXs,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 「还有 N 篇」行：点开把「更早」展开（一次性，不收起——考古区展开后就是
/// 普通长列表）。
class _ShowMoreTile extends StatelessWidget {
  const _ShowMoreTile({required this.hidden, required this.onTap});

  final int hidden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
      child: TextButton(
        onPressed: onTap,
        child: Text(
          '还有 $hidden 篇',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// 心流里的一行（高 44，两行：标题 + 元数据）。
///
/// - 标题 13px/medium，无标题借正文首行，真空白显示「（空白）」（与卡片同
///   口径，见 [noteDisplayTitle]）；画布笔记带 [CustomIcons.canvas] 角标
///   （**不画缩略图**——这一档要的是密度，不是预览）；
/// - 元数据 11px 灰：标签 · 相对时间；
/// - hover = [AppTheme.hoverOverlay] 微底 + 行尾浮出收藏钮；
/// - 点击 / Enter = [locateProvider].locate（**不带 focus**，与现列表同口径
///   ——"点开看看"不该把键盘焦点抢进编辑器）；↑↓ 走框架焦点遍历换行。
class _StreamTile extends ConsumerStatefulWidget {
  const _StreamTile({required this.note});

  final Note note;

  @override
  ConsumerState<_StreamTile> createState() => _StreamTileState();
}

class _StreamTileState extends ConsumerState<_StreamTile> {
  final FocusNode _focus = FocusNode();
  bool _hover = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _open() {
    ref.read(locateProvider.notifier).locate(noteId: widget.note.id);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Note n = widget.note;
    final String title = noteDisplayTitle(n);
    final bool blank = title == '无标题';
    final String tags = n.tags.take(3).join(' · ');
    final String meta = tags.isEmpty
        ? relativeTime(n.revisedAt)
        : '$tags · ${relativeTime(n.revisedAt)}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MouseRegion(
        // 卸载中派发的 onExit 不许 setState（列表重排时会发生）。
        onEnter: (_) {
          if (mounted) setState(() => _hover = true);
        },
        onExit: (_) {
          if (mounted) setState(() => _hover = false);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _open,
          child: FocusRing(
            focusNode: _focus,
            borderRadius: BorderRadius.circular(Tokens.radiusMd),
            child: Focus(
              focusNode: _focus,
              onKeyEvent: (FocusNode _, KeyEvent event) {
                if (event is KeyDownEvent) {
                  if (event.logicalKey == LogicalKeyboardKey.enter) {
                    _open();
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    FocusScope.of(context).nextFocus();
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    FocusScope.of(context).previousFocus();
                    return KeyEventResult.handled;
                  }
                }
                return KeyEventResult.ignored;
              },
              child: SizedBox(
                height: 44,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _hover
                        ? AppTheme.hoverOverlay(theme.brightness)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(Tokens.radiusMd),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Tokens.spaceMd,
                    ),
                    child: Row(
                      children: <Widget>[
                        if (n.kind == NoteKind.canvas) ...<Widget>[
                          CustomIcons.canvas(size: Tokens.iconXs),
                          const SizedBox(width: Tokens.spaceXs),
                        ],
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                blank ? '（空白）' : title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurface,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                meta,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // hover 才浮出（静止态保持留白，不塞一排常驻按钮）。
                        if (_hover)
                          SizedBox(
                            width: 28,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              iconSize: Tokens.iconXs,
                              tooltip: n.promotedAt == null ? '收藏' : '取消收藏',
                              icon: n.promotedAt == null
                                  ? const tabler.Star(
                                      height: Tokens.iconXs,
                                      width: Tokens.iconXs,
                                      strokeWidth: Tokens.iconStroke,
                                    )
                                  : const tabler.StarFilled(
                                      height: Tokens.iconXs,
                                      width: Tokens.iconXs,
                                      strokeWidth: Tokens.iconStroke,
                                    ),
                              onPressed: () => ref
                                  .read(notesProvider.notifier)
                                  .togglePromoted(n),
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
      ),
    );
  }
}
