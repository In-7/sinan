import 'dart:async';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter_riverpod/flutter_riverpod.dart';import 'package:material_ui/material_ui.dart';

import '../command/commands.dart';
import '../domain/note.dart';
import '../theme/app_float_surface.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'providers.dart';

/// **主页**（`docs/ui_rewrite_plan.md` §5.6）：**Bento 卡片格**。
///
/// ## 卡片走"卡片档"底，且**没有描边、没有投影**
/// 底 = [AppTheme.cardFill]（叠在板底之上的量）+ [AppGlass] 的**玻璃光泽**
/// （内光泽 + 顶沿光边，纯绘制、零 `saveLayer`），hover 叠 [AppTheme.cardFillHover]。
/// **不加 1px 描边**（2026-09-22 用户反馈："卡片不要边框线"）；**不加投影**——投影是
/// "短暂浮层"的语言，常驻卡一多就是噪音（同一批结论）。
///
/// ⚠️ 试过并否决：**半透明 Mica Layer**（`floatSurface` × 0.7 压在 Mica 上）。
/// 深色下 `#222` × 0.7 盖在近黑背景上是一种"脏灰"，不如干脆的第二档灰干净。
///
/// ## Bento 是什么、以及它与"小方卡"的区别
/// 2026-09-22 曾否决过 **260px 等大小方卡**，理由是"把每行压成两三行、图标和字都缩，
/// 密度翻倍看起来就廉价"。**Bento 不是那种东西**，三条区别（缺一条就会退化成它）：
/// 1. **尺寸有主次**：一块大（跨两列）+ 若干中 + 两个小，不是等大小重复；
/// 2. **每列够宽**：[maxWidth] 之下两列各 ≈420px，**卡内不缩字**（标题仍 `titleSmall`、
///    摘要仍 `bodySmall`）——上一版的问题出在"字被缩小"，不是"有两列"；
/// 3. **卡高够**（中卡 104、不是 80）：压扁行高才是"廉价感"的直接来源。
///
/// ## 页面模型：**切换，不是叠加**
/// 未选中笔记 = 主页；选中 = 笔记 / 画布页。同一个 `selectedNoteIdProvider` 驱动。
class HomeHub extends ConsumerWidget {
  const HomeHub({super.key});

  /// 最近列表条数（骨架值，手感待调）。
  static const int recentCount = 6;

  /// 内容列宽：与"读"的宽度一致，不给 2000px 的超宽行。
  static const double maxWidth = 880;

  /// 两列的**最低可用宽度**：比它窄就退回单列（窗口最小 720，故正常不触发）。
  static const double twoColumnMinWidth = 620;

  /// 格缝（Bento 的"缝"）：与导航板的 6px 缝同量级，但卡片之间要更松一点。
  static const double gap = Tokens.spaceSm;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final List<Note> notes = ref.watch(notesProvider).value ?? const <Note>[];
    // 排序依据 `revisedAt`（不是 `createdAt`）：主页要回答的是"我上次在写哪篇"。
    final List<Note> byRecent = <Note>[...notes]
      ..sort((Note a, Note b) => b.revisedAt.compareTo(a.revisedAt));

    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Tokens.spaceLg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxWidth),
          // LayoutBuilder 拿的是**钳制后**的可用宽度 ⇒ 列宽由它算，不写死 880。
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final double full = c.maxWidth;
              final bool two = full >= twoColumnMinWidth;
              // 列数交给网格：窄屏时"跨 1 列"就是**满宽**（不出现半宽残格）。
              final int columns = two ? 2 : 1;
              final Note? latest = byRecent.isEmpty ? null : byRecent.first;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // 页面大标题：卡片已经够"控件"了，标题要把它拉回"一页纸"。
                  Text('主页', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: Tokens.spaceLg),
                  if (latest == null)
                    const _EmptyHub()
                  else ...<Widget>[
                    _Section(
                      label: '上次编辑',
                      child: _BentoGrid(
                        availableWidth: full,
                        columns: columns,
                        tiles: <({int span, Widget child})>[
                          (
                            span: 2,
                            child: _HubCard(
                              size: _CardSize.hero,
                              icon: _iconOf(latest),
                              title: _titleOf(latest),
                              subtitle: _summaryOf(latest),
                              trailing: _TimeLabel(at: latest.revisedAt),
                              onTap: () => ref
                                  .read(locateProvider.notifier)
                                  .locate(noteId: latest.id, focus: true),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Tokens.spaceLg),
                    _Section(
                      label: '最近编辑',
                      child: _BentoGrid(
                        availableWidth: full,
                        columns: columns,
                        tiles: <({int span, Widget child})>[
                          // 大卡已经是第一篇 ⇒ 最近列表从第二篇起。
                          for (final Note n
                              in byRecent.skip(1).take(recentCount))
                            (
                              span: 1,
                              child: _HubCard(
                                icon: _iconOf(n),
                                title: _titleOf(n),
                                subtitle: _summaryOf(n),
                                trailing: _TimeLabel(at: n.revisedAt),
                                onTap: () => ref
                                    .read(locateProvider.notifier)
                                    .locate(noteId: n.id),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: Tokens.spaceLg),
                  _Section(
                    label: '新建',
                    child: _BentoGrid(
                      availableWidth: full,
                      columns: columns,
                      tiles: <({int span, Widget child})>[
                        (
                          span: 1,
                          child: _HubCard(
                            size: _CardSize.small,
                            icon: tabler.FileText(height: 24, width: 24, strokeWidth: 1.5),
                            title: '笔记',
                            subtitle: '块编辑器，支持 Markdown 输入',
                            trailing: tabler.Plus(height: 18, width: 18, strokeWidth: 1.5),
                            onTap: () =>
                                unawaited(runCommandById(ref, 'note.new')),
                          ),
                        ),
                        (
                          span: 1,
                          child: _HubCard(
                            size: _CardSize.small,
                            icon: tabler.LayoutDashboard(height: 24, width: 24, strokeWidth: 1.5),
                            title: '画布',
                            subtitle: '手写笔迹、卡片与连线',
                            trailing: tabler.Plus(height: 18, width: 18, strokeWidth: 1.5),
                            onTap: () =>
                                unawaited(runCommandById(ref, 'canvas.new')),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

IconData _iconOf(Note note) => note.kind == NoteKind.canvas
    ? tabler.LayoutDashboard(height: 24, width: 24, strokeWidth: 1.5)
    : tabler.FileText(height: 24, width: 24, strokeWidth: 1.5);

String _titleOf(Note note) => note.title.isEmpty ? '无标题' : note.title;

String _summaryOf(Note note) {
  final String text = note.plainText.trim();
  return text.isEmpty ? '还没有内容' : text;
}

/// 相对时间：主页关心的是"多久没碰了"，不是精确时刻。
String _relativeTime(DateTime at) {
  final Duration d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  if (d.inDays < 7) return '${d.inDays} 天前';
  return '${at.month}-${at.day.toString().padLeft(2, '0')}';
}

/// 时间小字（卡片右上/右下角那格）。
class _TimeLabel extends StatelessWidget {
  const _TimeLabel({required this.at});

  final DateTime at;

  @override
  Widget build(BuildContext context) => Text(
    _relativeTime(at),
    style: Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
  );
}

/// 分区：小灰字标题 + 其下的 Bento 格。
///
/// 📌 标题**保留**（它是"这些卡片是什么"的读法，也是 §5.6 的分区语言）；Bento 的
/// 特征落在**卡片尺寸档**上。要做"完全无标题的纯 Bento"，删掉这里的 `Text` 即可。
class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Tokens.spaceSm),
        child,
      ],
    );
  }
}

/// **Bento 网格**：把卡片按"跨几列"铺进 2 列网格（窄屏自动是 1 列 × 全宽）。
///
/// 用 [Wrap] 而不是 `GridView`：卡高由**尺寸档**决定（不是按比例），`Wrap` 直接按
/// 显式宽度换行，行与行之间自然对齐；`GridView` 的 `childAspectRatio` 表达不了
/// "同一行里 2 跨与 1 跨混排"。
class _BentoGrid extends StatelessWidget {
  const _BentoGrid({
    required this.availableWidth,
    required this.columns,
    required this.tiles,
  });

  final double availableWidth;

  /// 列数（1 = 窄屏单列；2 = 正常）。
  final int columns;

  /// 每一项 = 跨列数（≥ [columns] 时占满整行）+ 卡片。
  final List<({int span, Widget child})> tiles;

  @override
  Widget build(BuildContext context) {
    // 单列宽 = 总宽扣掉列间缝再对分；`span` 占满整行时直接给总宽。
    final double one = (availableWidth - HomeHub.gap * (columns - 1)) / columns;
    return Wrap(
      spacing: HomeHub.gap,
      runSpacing: HomeHub.gap,
      children: <Widget>[
        for (final ({int span, Widget child}) t in tiles)
          SizedBox(
            width: t.span >= columns ? availableWidth : one,
            child: t.child,
          ),
      ],
    );
  }
}

/// 卡片尺寸档：**Bento 的"主次"就是它**（高度、内边距、摘要行数三件一起变）。
enum _CardSize {
  /// 大卡：跨两列。竖向排版（顶部"这是什么 + 多久没碰"，下面大标题 + 两行摘要）。
  hero,

  /// 中卡：一列。图标 + 标题 / 一行摘要 / 底部时间。
  medium,

  /// 小卡：一列。横排（图标 + 标题 + 一行说明 + 右侧动作），给"新建"这类入口。
  small;

  double get height => switch (this) {
    hero => 148,
    medium => 104,
    small => 76,
  };

  EdgeInsets get padding => switch (this) {
    hero => const EdgeInsets.all(20),
    medium => const EdgeInsets.all(16),
    small => const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
  };

  int get summaryLines => switch (this) {
    hero => 2,
    medium => 1,
    small => 1,
  };
}

/// 一张 Bento 卡。
///
/// 状态：
/// - **悬停**：把底色抬一档（用统一的 [AppTheme.cardFillHover]，不自己挑比例）；
/// - **聚焦**：[FocusRing] 画环（§5.2：自绘交互件必须能键盘用）。`InkWell` 自己的
///   叠层**关掉**——否则同一件事被表达两遍。
///
/// ⚠️ 高度是**档位**（不是随内容）：Bento 的"行对齐"靠它。因此文案一律
/// `maxLines + ellipsis`，任何长度都不会把卡片撑破。
/// ⚠️ 高度会乘 `TextScaler`：用户放大字号时卡片一起长高，否则文字会溢出。
class _HubCard extends StatefulWidget {
  const _HubCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.size = _CardSize.medium,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// 右侧补信息（笔记卡 = 相对时间；新建卡 = 加号）。
  final Widget? trailing;

  final _CardSize size;

  @override
  State<_HubCard> createState() => _HubCardState();
}

class _HubCardState extends State<_HubCard> {
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
    final BorderRadius radius = BorderRadius.circular(Tokens.radiusLg);
    // Craft 式卡片（2026-09-22 用户定）：**无描边、无投影**——浮起靠**档差**
    // 不靠影子；填充用卡片档（cardFill，叠在板底之上的 Layer）。
    final Color color = _hover
        ? AppTheme.cardFillHover(theme.brightness)
        : AppTheme.cardFill(theme.brightness);
    final double height =
        widget.size.height * MediaQuery.textScalerOf(context).scale(1);

    return FocusRing(
      focusNode: _focus,
      borderRadius: radius,
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, borderRadius: radius),
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: radius),
          clipBehavior: Clip.antiAlias,
          // 玻璃光泽（内光泽 + 顶沿光边）：与设置 / 关于面板同一套令牌。
          // 它不自己裁圆角 ⇒ 借上面这层 `Clip.antiAlias`（省一次图层切换）。
          child: AppGlass(
            child: InkWell(
              focusNode: _focus,
              borderRadius: radius,
              hoverColor: Colors.transparent,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              onHover: (bool v) => setState(() => _hover = v),
              onTap: widget.onTap,
              child: SizedBox(
                height: height,
                width: double.infinity,
                child: Padding(
                  padding: widget.size.padding,
                  child: switch (widget.size) {
                    _CardSize.hero => _heroBody(theme),
                    _CardSize.medium => _mediumBody(theme),
                    _CardSize.small => _smallBody(theme),
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 大卡：竖向。顶部一行是"这是什么（caption）+ 多久没碰（trailing）"，
  /// 下面才是标题与摘要 —— 主次靠**字号**拉开，不靠颜色。
  Widget _heroBody(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Row(
        children: <Widget>[
          Icon(
            widget.icon,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const Spacer(),
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
      const Spacer(),
      Text(
        widget.title,
        style: theme.textTheme.titleLarge,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: 4),
      Text(
        widget.subtitle,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        maxLines: widget.size.summaryLines,
        overflow: TextOverflow.ellipsis,
      ),
    ],
  );

  /// 中卡：图标 + 标题一行、摘要一行、**时间贴在底部**（与相邻卡对齐）。
  Widget _mediumBody(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Row(
        children: <Widget>[
          Icon(
            widget.icon,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: Tokens.spaceSm),
          Expanded(
            child: Text(
              widget.title,
              style: theme.textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        widget.subtitle,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        maxLines: widget.size.summaryLines,
        overflow: TextOverflow.ellipsis,
      ),
      const Spacer(),
      if (widget.trailing != null) widget.trailing!,
    ],
  );

  /// 小卡：横排（图标 + 标题 + 说明 + 右侧动作）。
  Widget _smallBody(ThemeData theme) => Row(
    children: <Widget>[
      Icon(widget.icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
      const SizedBox(width: Tokens.spaceMd),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              widget.title,
              style: theme.textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              widget.subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: widget.size.summaryLines,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
      if (widget.trailing != null) ...<Widget>[
        const SizedBox(width: Tokens.spaceMd),
        widget.trailing!,
      ],
    ],
  );
}

/// 空库：不给空卡片，直接指路（新建是此时唯一有意义的事）。
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
