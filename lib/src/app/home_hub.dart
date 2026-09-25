import 'dart:async';
import 'dart:ui' as ui;

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../command/commands.dart';
import '../domain/note.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'providers.dart';

/// **主页**：Things 3 式「呼吸极简」的一页纸（2026-09-24 重写，取代 Bento 卡片格）。
///
/// ## 为什么放弃 Bento
/// 2026-09-22 的 Bento（hero 大卡 + 两列中卡 + 小卡）是**控件语言**：底色块、
/// 圆角、玻璃光泽、hover 抬档。它的信息密度适合"仪表盘"，但主页要回答的只有一个
/// 问题——「我上次在写哪篇」。Bento 里这个问题被图标、摘要、卡片边距稀释了。
/// Things 3 证明桌面端更好的答案是**排版语言**：大标题 + 全宽行 + 字重分层，
/// 一行 = 一条笔记，没有容器。
///
/// ## 四条结构事实（改动前先读）
/// 1. **行就是单元**：无底、无框、无图标框；hover 才给一档淡底
///    （[AppTheme.boardFillHover]，与导航行同一套"再叠一档"语言）。
/// 2. **层级交给排版**：页标题 `headlineMedium` 轻字重；「继续」行 `titleMedium`
///    加粗；普通行 `bodyMedium`；时间 `labelSmall` 灰字右对齐。**摘要砍掉**——
///    主页回答"在写哪篇"，不回答"写了什么"。
/// 3. **永远单列**（[maxWidth] 700）：两列 Bento 整个退场。列窄 + 页首 [Tokens.spaceXxl]
///    大留白 = 呼吸感的两个来源。
/// 4. **每行都接 [FocusRing]**（§5.2）：自绘交互件必须能键盘用——这是桌面特权，
///    与视觉极简同等重要。
///
/// ## 分组的时间叙事
/// 「继续」（最近一篇，加粗）→「最近」（可折叠，`▸` 头）→「新建」（ghost 行，
/// 灰字加号）。等价于 Things 的 Today / Earlier 节奏感。
///
/// ## 页面模型（不变）
/// 未选中笔记 = 主页；选中 = 笔记 / 画布页。同一个 `selectedNoteIdProvider` 驱动。
class HomeHub extends ConsumerStatefulWidget {
  const HomeHub({super.key});

  /// 最近列表条数。
  static const int recentCount = 6;

  /// 内容列宽：Things 的"一页纸"宽度。比 Bento 时代的 880 窄——
  /// 单列下 880 会让一行文字横跨过宽，700 是 13px 正文的舒适阅读宽。
  static const double maxWidth = 700;

  @override
  ConsumerState<HomeHub> createState() => _HomeHubState();
}

class _HomeHubState extends ConsumerState<HomeHub> {
  /// 「最近」分组的展开态。只放本地 State：折叠是纯视图节奏，
  /// 不进 provider 也不落盘（重启回展开 = Things 的默认行为）。
  bool _recentOpen = true;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<Note> notes = ref.watch(notesProvider).value ?? const <Note>[];
    // 排序依据 `revisedAt`（不是 `createdAt`）：主页要回答的是"我上次在写哪篇"。
    final List<Note> byRecent = <Note>[...notes]
      ..sort((Note a, Note b) => b.revisedAt.compareTo(a.revisedAt));
    final Note? latest = byRecent.isEmpty ? null : byRecent.first;

    // **收藏**：`promotedAt` 非空的笔记，按收藏时间倒序（最新置顶）。
    // 2026-09-25 A 方案：收藏进主页分区，取代把它塞进侧栏切换器（那样得 4 段）。
    final List<Note> favorites = <Note>[
      ...notes.where((Note n) => n.promotedAt != null),
    ]..sort((Note a, Note b) => b.promotedAt!.compareTo(a.promotedAt!));

    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        // 页首呼吸是 [Tokens.spaceXxl]（48）——比普通页面留白大一档，
        // 这是"一页纸"开头的空气感；左右与底部 [Tokens.spaceXl]。
        padding: const EdgeInsets.fromLTRB(
          Tokens.spaceXl,
          Tokens.spaceXxl,
          Tokens.spaceXl,
          Tokens.spaceXl,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: HomeHub.maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 页面大标题：轻字重——层级靠它"大而轻"与下面"小而实"拉开，
              // 不靠颜色不靠盒子。
              Text(
                '主页',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w300,
                ),
              ),
              const SizedBox(height: Tokens.spaceXxl),
              if (latest == null)
                const _EmptyHub()
              else ...<Widget>[
                if (favorites.isNotEmpty) ...<Widget>[
                  // 收藏分区（2026-09-25 A 方案）：promotedAt 非空的笔记，
                  // 按收藏时间倒序。只在有收藏时渲染——不出空分组头。
                  _Section(
                    label: '收藏',
                    child: Column(
                      children: <Widget>[
                        for (final Note n in favorites)
                          _HubRow(
                            title: _titleOf(n),
                            kindTag: _kindTagOf(n),
                            trailing: _TimeLabel(at: n.revisedAt),
                            promoted: true,
                            onTogglePromoted: () => ref
                                .read(notesProvider.notifier)
                                .togglePromoted(n),
                            onTap: () => ref
                                .read(locateProvider.notifier)
                                .locate(noteId: n.id),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Tokens.spaceXl),
                ],
                _Section(
                  label: '继续',
                  child: _HubRow(
                    title: _titleOf(latest),
                    emphasized: true,
                    kindTag: _kindTagOf(latest),
                    trailing: _TimeLabel(at: latest.revisedAt),
                    onTap: () => ref
                        .read(locateProvider.notifier)
                        .locate(noteId: latest.id, focus: true),
                  ),
                ),
                // 只有 1 篇时「最近」没有内容 ⇒ 整组不渲染（不出空分组头）。
                if (byRecent.length > 1) ...<Widget>[
                  const SizedBox(height: Tokens.spaceXl),
                  _Section(
                    label: '最近',
                    open: _recentOpen,
                    onToggle: () =>
                        setState(() => _recentOpen = !_recentOpen),
                    collapsedHint: '${byRecent.length - 1} 篇',
                    child: Column(
                      children: <Widget>[
                        for (final Note n
                            in byRecent.skip(1).take(HomeHub.recentCount))
                          _HubRow(
                            title: _titleOf(n),
                            kindTag: _kindTagOf(n),
                            trailing: _TimeLabel(at: n.revisedAt),
                            onTap: () => ref
                                .read(locateProvider.notifier)
                                .locate(noteId: n.id),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: Tokens.spaceXl),
                _Section(
                  label: '新建',
                  child: Column(
                    children: <Widget>[
                      _HubRow(
                        leading: _ghostPlus(scheme),
                        title: '新建笔记',
                        ghost: true,
                        onTap: () =>
                            unawaited(runCommandById(ref, 'note.new')),
                      ),
                      _HubRow(
                        leading: _ghostPlus(scheme),
                        title: '新建画布',
                        ghost: true,
                        onTap: () =>
                            unawaited(runCommandById(ref, 'canvas.new')),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// ghost 行的加号：次级小图标（[Tokens.iconXs]）+ 灰——
  /// 「新建」是次级动作，视觉重量必须低于任何一条笔记行。
  static Widget _ghostPlus(ColorScheme scheme) => tabler.Plus(
        height: Tokens.iconXs,
        width: Tokens.iconXs,
        strokeWidth: Tokens.iconStroke,
        colorFilter: ui.ColorFilter.mode(
          scheme.onSurfaceVariant,
          ui.BlendMode.srcIn,
        ),
      );
}

String _titleOf(Note note) => note.title.isEmpty ? '无标题' : note.title;

/// 画布笔记的形态标签（文档是默认形态 ⇒ 不标）。
/// 相当于 Things 行尾的项目 tag：只有"不是默认"的才说。
String? _kindTagOf(Note note) =>
    note.kind == NoteKind.canvas ? '画布' : null;

/// 相对时间：主页关心的是"多久没碰了"，不是精确时刻。
String _relativeTime(DateTime at) {
  final Duration d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  if (d.inDays < 7) return '${d.inDays} 天前';
  return '${at.month}-${at.day.toString().padLeft(2, '0')}';
}

/// 时间小字（行尾那格）：灰、右对齐、永远只有一格宽。
class _TimeLabel extends StatelessWidget {
  const _TimeLabel({required this.at});

  final DateTime at;

  @override
  Widget build(BuildContext context) => Text(
        _relativeTime(at),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      );
}

/// 分组：小灰字标题 + 其下的行。
///
/// [open]/[onToggle] 非 null 时是**可折叠分组**（`▸` 头 + 计数），
/// 折叠是 Things 的节奏工具——"最近"一长，收起来让"继续"独占视线。
class _Section extends StatelessWidget {
  const _Section({
    required this.label,
    required this.child,
    this.open,
    this.onToggle,
    this.collapsedHint,
  });

  final String label;
  final Widget child;

  /// 展开/折叠态。`null` = 该分组不可折叠（无箭头、永远展开）。
  final bool? open;

  /// 折叠开关（[open] 非 null 时必有）。
  final VoidCallback? onToggle;

  /// 折叠时标题右侧的提示（如「3 篇」）——收起来的内容要有交代。
  final String? collapsedHint;

  @override
  Widget build(BuildContext context) {
    final bool expanded = open ?? true;
    final Widget header = onToggle == null
        ? _plainHeader(context)
        : _FoldHeader(
            label: label,
            open: expanded,
            onToggle: onToggle!,
            collapsedHint: collapsedHint,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        header,
        if (expanded) ...<Widget>[
          const SizedBox(height: Tokens.spaceXs),
          child,
        ],
      ],
    );
  }

  /// 不可折叠的分组头：左缘与行内文字对齐（行内 padding [Tokens.spaceMd]）。
  Widget _plainHeader(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Tokens.spaceMd,
        vertical: Tokens.spaceXs,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 可折叠分组头：`▸` 箭头（展开旋 90°）+ 小灰字标题；折叠时右侧出计数。
///
/// 高 28（比行矮 6）——分组头是"节奏标记"不是目标，比行更轻。
class _FoldHeader extends StatefulWidget {
  const _FoldHeader({
    required this.label,
    required this.open,
    required this.onToggle,
    this.collapsedHint,
  });

  final String label;
  final bool open;
  final VoidCallback onToggle;
  final String? collapsedHint;

  @override
  State<_FoldHeader> createState() => _FoldHeaderState();
}

class _FoldHeaderState extends State<_FoldHeader> {
  final FocusNode _focus = FocusNode();
  bool _hover = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color fill = _hover
        ? AppTheme.boardFillHover(theme.brightness)
        : Colors.transparent;

    return FocusRing(
      focusNode: _focus,
      borderRadius: BorderRadius.circular(Tokens.radiusSm),
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(Tokens.radiusSm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          focusNode: _focus,
          borderRadius: BorderRadius.circular(Tokens.radiusSm),
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          onHover: (bool v) => setState(() => _hover = v),
          onTap: widget.onToggle,
          child: SizedBox(
            height: 28,
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceXs),
              child: Row(
                children: <Widget>[
                  AnimatedRotation(
                    turns: widget.open ? 0.25 : 0,
                    duration: Tokens.durationFast,
                    child: tabler.ChevronRight(
                      height: Tokens.iconXs,
                      width: Tokens.iconXs,
                      strokeWidth: Tokens.iconStroke,
                      colorFilter: ui.ColorFilter.mode(
                        scheme.onSurfaceVariant,
                        ui.BlendMode.srcIn,
                      ),
                    ),
                  ),
                  const SizedBox(width: Tokens.spaceXs),
                  Text(
                    widget.label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (!widget.open && widget.collapsedHint != null)
                    Text(
                      widget.collapsedHint!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// **一页纸里的一行**：标题 + 右侧灰信息（形态 tag + 时间），没有容器。
///
/// 状态：
/// - **悬停**：整行叠一档淡底（[AppTheme.boardFillHover]，与导航行同语言）；
/// - **聚焦**：[FocusRing] 画环（§5.2）。
///
/// ⚠️ 高度 34 是**档位**（Things 的行高），标题一律 `maxLines + ellipsis`。
/// 「继续」行 [emphasized] 用 `titleMedium` 加粗——主次靠字重，不靠盒子。
/// 「新建」行 [ghost] 灰字 + 加号 leading——次级动作的视觉重量低于笔记行。
class _HubRow extends StatefulWidget {
  const _HubRow({
    required this.title,
    required this.onTap,
    this.trailing,
    this.leading,
    this.kindTag,
    this.emphasized = false,
    this.ghost = false,
    this.promoted = false,
    this.onTogglePromoted,
  });

  final String title;
  final VoidCallback onTap;

  /// 行尾信息（笔记行 = 相对时间）。
  final Widget? trailing;

  /// 行首小图标（新建行的加号）。笔记行没有——图标是导航的语言，不是这里的。
  final Widget? leading;

  /// 形态标签（「画布」）。文档是默认 ⇒ 不标。
  final String? kindTag;

  final bool emphasized;
  final bool ghost;

  /// 收藏态（决定星标实/空）。非收藏行传 `false`。
  final bool promoted;

  /// **就地切换收藏**（2026-09-25 A 方案）。非 null 时行尾恒显一枚星标按钮，
  /// 收藏区用它在主页直接取消收藏；普通行不传 ⇒ 不显星标（标记入口在左侧
  /// 列表的 `···` 菜单，见 [NoteListView]）。
  final VoidCallback? onTogglePromoted;

  @override
  State<_HubRow> createState() => _HubRowState();
}

class _HubRowState extends State<_HubRow> {
  final FocusNode _focus = FocusNode();
  bool _hover = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final BorderRadius radius = BorderRadius.circular(Tokens.radiusMd);
    final Color fill = _hover
        ? AppTheme.boardFillHover(theme.brightness)
        : Colors.transparent;

    // ghost 行平时灰；hover/聚焦抬成 onSurface（"次级但活着"）。
    final Color titleColor = widget.ghost && !_hover && !_focus.hasFocus
        ? scheme.onSurfaceVariant
        : scheme.onSurface;

    return FocusRing(
      focusNode: _focus,
      borderRadius: radius,
      child: Material(
        // ⚠️ 静止态必须显式 transparent（与导航行同款的坑：
        // null 会落到 canvasColor，把窗口底盖成黑方块）。
        color: fill,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          focusNode: _focus,
          borderRadius: radius,
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          onHover: (bool v) => setState(() => _hover = v),
          onTap: widget.onTap,
          child: SizedBox(
            height: 34,
            width: double.infinity,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
              child: Row(
                children: <Widget>[
                  if (widget.leading != null) ...<Widget>[
                    widget.leading!,
                    const SizedBox(width: Tokens.spaceSm),
                  ],
                  Expanded(
                    child: Text(
                      widget.title,
                      style: (widget.emphasized
                              ? theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                )
                              : theme.textTheme.bodyMedium)
                          ?.copyWith(color: titleColor),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.kindTag != null) ...<Widget>[
                    const SizedBox(width: Tokens.spaceSm),
                    Text(
                      widget.kindTag!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (widget.trailing != null) ...<Widget>[
                    const SizedBox(width: Tokens.spaceMd),
                    DefaultTextStyle.merge(
                      // 时间与形态 tag 同灰——行尾是"次要信息列"，不抢标题。
                      style: theme.textTheme.labelSmall!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      child: widget.trailing!,
                    ),
                  ],
                  // 就地收藏切换（仅收藏区行传了 onTogglePromoted）：恒显星标，
                  // 实/空随 promoted。与左侧列表 `···` 菜单里的「收藏」同一条
                  // 通道（togglePromoted），主页就能直接取消收藏。
                  if (widget.onTogglePromoted != null) ...<Widget>[
                    const SizedBox(width: Tokens.spaceSm),
                    SizedBox(
                      width: Tokens.formatButtonHeight,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: widget.promoted ? '取消收藏' : '收藏',
                        icon: widget.promoted
                            ? tabler.StarFilled(
                                height: Tokens.iconMd,
                                width: Tokens.iconMd,
                                strokeWidth: Tokens.iconStroke,
                                colorFilter: ui.ColorFilter.mode(
                                  scheme.onSurfaceVariant,
                                  ui.BlendMode.srcIn,
                                ),
                              )
                            : tabler.Star(
                                height: Tokens.iconMd,
                                width: Tokens.iconMd,
                                strokeWidth: Tokens.iconStroke,
                                colorFilter: ui.ColorFilter.mode(
                                  scheme.onSurfaceVariant,
                                  ui.BlendMode.srcIn,
                                ),
                              ),
                        onPressed: widget.onTogglePromoted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 空库：不给空行，直接指路（新建是此时唯一有意义的事）。
class _EmptyHub extends ConsumerWidget {
  const _EmptyHub();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Tokens.spaceXl),
      child: Column(
        children: <Widget>[
          Text('还没有笔记', style: theme.textTheme.titleMedium),
          const SizedBox(height: Tokens.spaceSm),
          FilledButton(
            onPressed: () => unawaited(runCommandById(ref, 'note.new')),
            child: const Text('新建第一条'),
          ),
        ],
      ),
    );
  }
}
