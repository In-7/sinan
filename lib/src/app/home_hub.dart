import 'dart:async';
import 'dart:ui' as ui;

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../command/commands.dart';
import '../domain/note.dart';
import '../theme/app_theme.dart';
import '../theme/noise_texture.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'providers.dart';

/// **主页**：Things 3 式「呼吸极简」的一页纸�?026-09-24 重写，取�?Bento 卡片格）�?
///
/// ## 为什么放�?Bento
/// 2026-09-22 �?Bento（hero 大卡 + 两列中卡 + 小卡）是**控件语言**：底色块�?
/// 圆角、玻璃光泽、hover 抬档。它的信息密度适合"仪表�?，但主页要回答的只有一�?
/// 问题——「我上次在写哪篇」。Bento 里这个问题被图标、摘要、卡片边距稀释了�?
/// Things 3 证明桌面端更好的答案�?*排版语言**：大标题 + 全宽�?+ 字重分层�?
/// 一�?= 一条笔记，没有容器�?
///
/// ## 四条结构事实（改动前先读�?
/// 1. **行就是单�?*：无底、无框、无图标框；hover 才给一档淡�?
///    （[AppTheme.boardFillHover]，与导航行同一�?再叠一�?语言）�?
/// 2. **层级交给排版**：页标题已撤�?026-09-26 用户定）；「继续」行
///    `titleMedium` 加粗；普通行 `bodyMedium`；时�?`labelSmall` 灰字右对齐�?
///    **摘要砍掉**——主页回�?在写哪篇"，不回答"写了什�?�?
/// 3. **永远单列**（[maxWidth] 700）：两列 Bento 整个退场。列�?+ 页首 [Tokens.spaceXxl]
///    大留�?= 呼吸感的两个来源�?
/// 4. **每行都接 [FocusRing]**（�?.2）：自绘交互件必须能键盘用——这是桌面特权，
///    与视觉极简同等重要�?
///
/// ## 分组的时间叙�?
/// 「日历」（页首�?026-09-26 用户定；�?*新建日期**回看）→「收藏」→「继续�?
/// （最近一篇，加粗）→「最近」（可折叠，`▸` 头）→「新建」（ghost 行，灰字加号）�?
///
/// ## 页面模型（不变）
/// 未选中笔记 = 主页；选中 = 笔记 / 画布页。同一�?`selectedNoteIdProvider` 驱动�?
class HomeHub extends ConsumerStatefulWidget {
  const HomeHub({super.key});

  /// 最近列表条数�?
  static const int recentCount = 6;

  /// 内容列宽：Things �?一页纸"宽度。比 Bento 时代�?880 窄—�?
  /// 单列�?880 会让一行文字横跨过宽，700 �?13px 正文的舒适阅读宽�?
  static const double maxWidth = 700;

  @override
  ConsumerState<HomeHub> createState() => _HomeHubState();
}

class _HomeHubState extends ConsumerState<HomeHub> {
  /// 「最近」分组的展开态。只放本�?State：折叠是纯视图节奏，
  /// 不进 provider 也不落盘（重启回展开 = Things 的默认行为）�?
  bool _recentOpen = true;

  /// 日历分区的视图状态：显示月份与选中日。只放本�?State（与 [_recentOpen]
  /// 同理）：切月/选中是纯浏览节奏，不�?provider 不落盘，重启回今天�?
  DateTime _calMonth = _todayMonth();
  DateTime _calSelected = _today();

  static DateTime _today() {
    final DateTime n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static DateTime _todayMonth() {
    final DateTime n = DateTime.now();
    return DateTime(n.year, n.month);
  }

  @override
  Widget build(BuildContext context) {
    final List<Note> notes = ref.watch(notesProvider).value ?? const <Note>[];
    // 排序依据 `revisedAt`（不�?`createdAt`）：主页要回答的�?我上次在写哪�?�?
    final List<Note> byRecent = <Note>[...notes]
      ..sort((Note a, Note b) => b.revisedAt.compareTo(a.revisedAt));
    final Note? latest = byRecent.isEmpty ? null : byRecent.first;

    // 滚动条永远贴窗口最右缘�?026-09-26 用户定）：viewport 占满全宽�?
    // 内容列的居中交给内层 [Align] + [ConstrainedBox]，不跟着内容走�?
    return SingleChildScrollView(
      // 页首呼吸�?026-09-26 用户定：日历置顶后顶留白减半）：
      // 顶部 [Tokens.spaceXl]�?4）；左右与底部不�?[Tokens.spaceXl]�?
      padding: const EdgeInsets.fromLTRB(
        Tokens.spaceXl,
        Tokens.spaceXl,
        Tokens.spaceXl,
        Tokens.spaceXl,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: HomeHub.maxWidth),
          child: Column(
            crossAxisAlignment: .stretch,
            children: <Widget>[
              // 页标题已撤（2026-09-26 用户定）：分区名不再在页内重复，
              // 页首呼吸交给外层 [Tokens.spaceXxl] 大留白�?
              if (latest == null)
                const _EmptyHub()
              else ...<Widget>[
                // 日历分区�?026-09-26）：�?*新建日期**（createdAt）回看，
                // 不跟修改日期走。放页首�?026-09-26 用户定：日历置顶）�?
                _Section(
                  label: '日历',
                  child: _CalendarView(
                    notes: notes,
                    month: _calMonth,
                    selected: _calSelected,
                    onPickMonth: (DateTime m) => setState(() => _calMonth = m),
                    onPickDay: (DateTime d) => setState(() {
                      _calSelected = d;
                      _calMonth = DateTime(d.year, d.month);
                    }),
                    onOpenNote: (Note n) =>
                        ref.read(locateProvider.notifier).locate(noteId: n.id),
                  ),
                ),
                const SizedBox(height: Tokens.spaceXl),
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
                // 只有 1 篇时「最近」没有内�?�?整组不渲染（不出空分组头）�?
                if (byRecent.length > 1) ...<Widget>[
                  const SizedBox(height: Tokens.spaceXl),
                  _Section(
                    label: '最�?,
                    open: _recentOpen,
                    onToggle: () => setState(() => _recentOpen = !_recentOpen),
                    collapsedHint: '${byRecent.length - 1} �?,
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
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _titleOf(Note note) => note.title.isEmpty ? '无标�? : note.title;

/// 画布笔记的形态标签（文档是默认形�?�?不标）�?
/// 相当�?Things 行尾的项�?tag：只�?不是默认"的才说�?
String? _kindTagOf(Note note) => note.kind == NoteKind.canvas ? '画布' : null;

/// 相对时间：主页关心的�?多久没碰�?，不是精确时刻�?
String _relativeTime(DateTime at) {
  final Duration d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟�?;
  if (d.inDays < 1) return '${d.inHours} 小时�?;
  if (d.inDays < 7) return '${d.inDays} 天前';
  return '${at.month}-${at.day.toString().padLeft(2, '0')}';
}

/// 时间小字（行尾那格）：灰、右对齐、永远只有一格宽�?
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

/// 分组：小灰字标题 + 其下的行�?
///
/// [open]/[onToggle] �?null 时是**可折叠分�?*（`▸` �?+ 计数），
/// 折叠�?Things 的节奏工具—�?最�?一长，收起来让"继续"独占视线�?
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

  /// 展开/折叠态。`null` = 该分组不可折叠（无箭头、永远展开）�?
  final bool? open;

  /// 折叠开关（[open] �?null 时必有）�?
  final VoidCallback? onToggle;

  /// 折叠时标题右侧的提示（如�? 篇」）——收起来的内容要有交代�?
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
      crossAxisAlignment: .stretch,
      children: <Widget>[
        header,
        if (expanded) ...<Widget>[
          const SizedBox(height: Tokens.spaceXs),
          child,
        ],
      ],
    );
  }

  /// 不可折叠的分组头：左缘与行内文字对齐（行�?padding [Tokens.spaceMd]）�?
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
          fontWeight: .w600,
        ),
      ),
    );
  }
}

/// 可折叠分组头：`▸` 箭头（展开�?90°�? 小灰字标题；折叠时右侧出计数�?
///
/// �?28（比行矮 6）——分组头�?节奏标记"不是目标，比行更轻�?
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
        clipBehavior: .antiAlias,
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
                      fontWeight: .w600,
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

/// **一页纸里的一�?*：标�?+ 右侧灰信息（形�?tag + 时间），没有容器�?
///
/// 状态：
/// - **悬停**：整行叠一档淡底（[AppTheme.boardFillHover]，与导航行同语言）；
/// - **聚焦**：[FocusRing] 画环（�?.2）�?
///
/// ⚠️ 高度 34 �?*档位**（Things 的行高），标题一�?`maxLines + ellipsis`�?
/// 「继续」行 [emphasized] �?`titleMedium` 加粗——主次靠字重，不靠盒子�?
class _HubRow extends StatefulWidget {
  const _HubRow({
    required this.title,
    required this.onTap,
    this.trailing,
    this.kindTag,
    this.emphasized = false,
  });

  final String title;
  final VoidCallback onTap;

  /// 行尾信息（笔记行 = 相对时间）�?
  final Widget? trailing;

  /// 形态标签（「画布」）。文档是默认 �?不标�?
  final String? kindTag;

  final bool emphasized;

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

    // 标题色：�?onSurface（「继续」加粗、普通行同色；hover 不再改色）�?
    final Color titleColor = scheme.onSurface;

    return FocusRing(
      focusNode: _focus,
      borderRadius: radius,
      child: Material(
        // ⚠️ 静止态必须显�?transparent（与导航行同款的坑：
        // null 会落�?canvasColor，把窗口底盖成黑方块）�?
        color: fill,
        borderRadius: radius,
        clipBehavior: .antiAlias,
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
              padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.title,
                      style:
                          (widget.emphasized
                                  ? theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: .w600,
                                    )
                                  : theme.textTheme.bodyMedium)
                              ?.copyWith(color: titleColor),
                      maxLines: 1,
                      overflow: .ellipsis,
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
                      // 时间与形�?tag 同灰——行尾是"次要信息�?，不抢标题�?
                      style: theme.textTheme.labelSmall!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      child: widget.trailing!,
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

/// 空库：不给空行，直接指路（新建是此时唯一有意义的事）�?
class _EmptyHub extends ConsumerWidget {
  const _EmptyHub();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Tokens.spaceXl),
      child: Column(
        children: <Widget>[
          Text('还没有笔�?, style: theme.textTheme.titleMedium),
          const SizedBox(height: Tokens.spaceSm),
          FilledButton(
            onPressed: () => unawaited(runCommandById(ref, 'note.new')),
            child: const Text('新建第一�?),
          ),
        ],
      ),
    );
  }
}

/// 日历分区�?026-09-26）：�?*新建日期**（`createdAt`）回看一个月�?
/// 不跟修改日期走——它回答"我什么时候写过什�?，与「最近」（`revisedAt`�?
/// �?我上次在写哪�?互补。语言延续主页排版风：无容器、文字网格、语义色状态�?
///
/// 2026-09-26 用户定：周一起始；标�?= 日期下小圆点（≥3 篇两枚，不显数字）；
/// 今天 = 细描边圈（不填充）、选中 = 玻璃�?tint 填充；分区在「最近」之后�?
class _CalendarView extends StatelessWidget {
  const _CalendarView({
    required this.notes,
    required this.month,
    required this.selected,
    required this.onPickMonth,
    required this.onPickDay,
    required this.onOpenNote,
  });

  final List<Note> notes;

  /// 当前显示月份（传任意一天即可，内部只看年月）�?
  final DateTime month;
  final DateTime selected;
  final ValueChanged<DateTime> onPickMonth;
  final ValueChanged<DateTime> onPickDay;

  /// 打开某篇（父层走 `locateProvider`，主页不直接导航）�?
  final ValueChanged<Note> onOpenNote;

  /// 日期归一化键（去时间，本地时区）�?
  static DateTime _dayKey(DateTime d) => DateTime(d.year, d.month, d.day);

  /// 网格行高。总高恒按**最�?6 �?*预留�?026-09-26 用户定：不压缩行高）—�?
  /// 周一起始下最挤的月份�? 号是周日�?31 天月）恰需 6 行；5 行的月份
  /// 下方空一行，总高恒定 �?切月不跳动�?
  static const double _calRowHeight = 36;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    // 按新建日期归组（每次 build 重算：桌面量级小，不值得缓存）�?
    final Map<DateTime, List<Note>> byDay = <DateTime, List<Note>>{};
    for (final Note n in notes) {
      byDay.putIfAbsent(_dayKey(n.createdAt), () => <Note>[]).add(n);
    }
    for (final List<Note> list in byDay.values) {
      list.sort((Note a, Note b) => b.createdAt.compareTo(a.createdAt));
    }

    final DateTime first = DateTime(month.year, month.month);
    final int daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // 周一起始：周一 = 0 �?周日 = 6�?
    final int leading = (first.weekday + 6) % 7;
    final int rowCount = ((leading + daysInMonth) / 7).ceil();
    final DateTime today = _dayKey(DateTime.now());

    // 网格：动态行数（5/6 行），首尾用相邻月日期补位（淡化、不可点）�?
    // DateTime 构造自带溢出规范化（day �?0 自动借位到上月）�?
    final List<Widget> grid = <Widget>[];
    int day = 1 - leading;
    for (int r = 0; r < rowCount; r++) {
      final List<Widget> cells = <Widget>[];
      for (int c = 0; c < 7; c++, day++) {
        final DateTime d = DateTime(month.year, month.month, day);
        final bool inMonth = d.month == month.month;
        cells.add(
          Expanded(
            child: _CalCell(
              date: d,
              inMonth: inMonth,
              isToday: d == today,
              isSelected: d == _dayKey(selected),
              count: inMonth ? (byDay[_dayKey(d)]?.length ?? 0) : 0,
              onTap: inMonth ? () => onPickDay(d) : null,
            ),
          ),
        );
      }
      grid.add(
        SizedBox(
          height: _calRowHeight,
          child: Row(children: cells),
        ),
      );
    }

    // 选中日的列表（日历正下方，单列叙事不出右栏）�?
    final List<Note> dayNotes = byDay[_dayKey(selected)] ?? const <Note>[];

    // 新拟态面板（2026-09-26 用户定）：同色浮起，双向软阴影分区，
    // 不引入实�?边框——只靠光影把「日�?+ 选中日列表」整组托起�?
    final bool isLight = theme.brightness == Brightness.light;
    // 面板底色与纸�?*只差一�?*、两边对称（2026-09-26 用户定）�?
    // 亮色比纸�?*�?�? ΔL***（boardFill = ladder.board�?EFEFED）；
    // 暗色比底**�?�? ΔL***（从"�?往 board 方向�?30%）�?
    // ⚠️ 两边**都不描边**：描边会让暗色那块出现一条框、与亮色无框的语言
    // 不一致（用户反馈别扭）——边界一律由「色�?+ 双向阴影」定义�?
    final Color panel = isLight
        ? AppTheme.boardFill(theme.brightness)
        : Color.lerp(
            AppTheme.contentCanvas(theme.brightness),
            AppTheme.boardFill(theme.brightness),
            0.3,
          )!;
    // 双向软阴影：暗侧把面板压在纸面、亮侧给左上缘高光，合成"浮起"�?
    // ⚠️ **明暗分开�?*�?026-09-26 用户反馈）：两边一起减弱后，暗色下面板
    // "糊、没有边"——暗环境里底色差的感知弱，浮起感主要靠阴影撑，暗色恢�?
    // 初版强度�?.45/0.06 + blur14/offset6，此前用户确认清晰）；亮色底色差
    // 够读出边界，保持减弱版（0.15/0.7 + blur10/offset4）�?
    final Color hi = isLight
        ? Color.lerp(panel, Colors.white, 0.7)!
        : Color.lerp(panel, Colors.white, 0.06)!;
    final Color lo = isLight
        ? Color.lerp(panel, Colors.black, 0.15)!
        : Color.lerp(panel, Colors.black, 0.45)!;
    // 偏移明暗分开：亮色收紧到 2（更贴边、更平面，它的色差够用）；暗色回�?
    // 6——去掉描边后暗色的边界由"色差 + 更强阴影"撑，offset 太小就又糊�?
    final Offset shadowOffset = isLight
        ? const Offset(2, 2)
        : const Offset(6, 6);
    // 羽化�?�?的直接来源（2026-09-26 用户澄清：糊指的�?*面板与它周围
    // 阴影之间**的过渡化开，不是面板与背景对比不够）：blur 收小 �?阴影
    // 变利落、边界清楚，不再在面板周围糊成一圈晕�?
    final double shadowBlur = isLight ? 6 : 8;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(Tokens.radiusLg),
        boxShadow: <BoxShadow>[
          BoxShadow(color: lo, offset: shadowOffset, blurRadius: shadowBlur),
          BoxShadow(color: hi, offset: -shadowOffset, blurRadius: shadowBlur),
        ],
      ),
      // 面板上挂同款纸面颗粒（paperNoiseAlpha）：颗粒铺在底色上、内容之下�?
      // ⚠️ 噪点层必须铺�?*整个面板**：padding 不能放在 Container 上——Stack
      // 会被内缩 �?颗粒只铺内容区，面板边缘留一圈无颗粒的纯色、看起来
      // "颜色不一�?�?026-09-26 用户截图反馈）。改为内容自�?padding�?
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: NoiseTexture(
              intensity: AppTheme.paperNoiseAlpha(theme.brightness),
              grain: AppTheme.windowNoiseGrain(theme.brightness),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Tokens.spaceLg),
            child: Column(
              crossAxisAlignment: .stretch,
              children: <Widget>[
                _monthHeader(theme, scheme, today),
                const SizedBox(height: Tokens.spaceSm),
                // 星期表头：与网格同构�?7 列，只提�?列名"，不是交互件�?
                Row(
                  children: <Widget>[
                    for (final String s in const <String>[
                      '一',
                      '�?,
                      '�?,
                      '�?,
                      '�?,
                      '�?,
                      '�?,
                    ])
                      Expanded(
                        child: Center(
                          child: Text(
                            s,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: Tokens.spaceXs),
                // 切月动效�?50ms 淡入（克制，不滑动不缩放）�?
                AnimatedSwitcher(
                  duration: Tokens.durationFast,
                  child: KeyedSubtree(
                    key: ValueKey<DateTime>(first),
                    child: SizedBox(
                      width: double.infinity,
                      // 恒定总高 = 最�?6 �?× 行高（预留，不压缩）�?
                      height: _calRowHeight * 6,
                      child: Column(children: grid),
                    ),
                  ),
                ),
                const SizedBox(height: Tokens.spaceSm),
                // 分组头：日期数字放进与日历选中格同款的灰圆片（navSelectedTint
                // 圆形填充 + bodyMedium），建立「下面这些行 = 上面圈住的那天」的
                // 视觉呼应——分区靠呼应而非容器（A 方案核心）�?
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Tokens.spaceMd,
                  ),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: 30,
                        height: 30,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppTheme.navSelectedTint(scheme.onSurface),
                            shape: .circle,
                          ),
                          child: Center(
                            child: Text(
                              '${selected.day}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: Tokens.spaceSm),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: <InlineSpan>[
                              TextSpan(
                                text: '${selected.month} �?,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurface,
                                ),
                              ),
                              TextSpan(
                                text: '  ·  新建 ${dayNotes.length} �?,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Tokens.spaceXs),
                if (dayNotes.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Tokens.spaceMd,
                    ),
                    child: Text(
                      '这天没有新建笔记',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  for (final Note n in dayNotes)
                    _HubRow(
                      title: _titleOf(n),
                      kindTag: _kindTagOf(n),
                      trailing: _TimeLabel(at: n.createdAt),
                      onTap: () => onOpenNote(n),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 月份头：`titleLarge` 月份 + 右侧切月 ghost 圆钮�? 非本月时的「回到今天」）�?
  Widget _monthHeader(ThemeData theme, ColorScheme scheme, DateTime today) {
    final bool atCurrentMonth =
        month.year == today.year && month.month == today.month;
    return Row(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
          child: Text(
            '${month.year} �?${month.month} �?,
            style: theme.textTheme.titleLarge?.copyWith(
              color: scheme.onSurface,
              fontWeight: .w500,
            ),
          ),
        ),
        const Spacer(),
        if (!atCurrentMonth) ...<Widget>[
          _CalGhostButton(label: '回到今天', onTap: () => onPickDay(today)),
          const SizedBox(width: Tokens.spaceXs),
        ],
        _CalNavButton(
          tooltip: '上个�?,
          icon: tabler.ChevronLeft(
            height: Tokens.iconSm,
            width: Tokens.iconSm,
            strokeWidth: Tokens.iconStroke,
            colorFilter: ui.ColorFilter.mode(
              scheme.onSurfaceVariant,
              ui.BlendMode.srcIn,
            ),
          ),
          onTap: () => onPickMonth(DateTime(month.year, month.month - 1)),
        ),
        const SizedBox(width: Tokens.spaceXs),
        _CalNavButton(
          tooltip: '下个�?,
          icon: tabler.ChevronRight(
            height: Tokens.iconSm,
            width: Tokens.iconSm,
            strokeWidth: Tokens.iconStroke,
            colorFilter: ui.ColorFilter.mode(
              scheme.onSurfaceVariant,
              ui.BlendMode.srcIn,
            ),
          ),
          onTap: () => onPickMonth(DateTime(month.year, month.month + 1)),
        ),
      ],
    );
  }
}

/// 日历单元格：36 高、数字居中、圆形状态底。无格线无底色——文字网格�?
class _CalCell extends StatefulWidget {
  const _CalCell({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.count,
    this.onTap,
  });

  final DateTime date;
  final bool inMonth;
  final bool isToday;
  final bool isSelected;

  /// 当天新建篇数�? = 无标记）�?
  final int count;

  /// `null` = 非本月补位，不可点�?
  final VoidCallback? onTap;

  @override
  State<_CalCell> createState() => _CalCellState();
}

class _CalCellState extends State<_CalCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool dim = !widget.inMonth;
    // 状态底：选中 = 玻璃�?tint（与导航选中同语言）；hover = 再叠一档�?
    final Color? fill = widget.isSelected
        ? AppTheme.navSelectedTint(scheme.onSurface)
        : (_hover && widget.onTap != null)
        ? AppTheme.boardFillHover(theme.brightness)
        : null;
    final Color textColor = dim
        ? scheme.onSurface.withValues(alpha: 0.3)
        : scheme.onSurfaceVariant;

    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) {
        if (mounted) setState(() => _hover = true);
      },
      onExit: (_) {
        if (mounted) setState(() => _hover = false);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Center(
          child: SizedBox(
            width: 30,
            height: 30,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                if (fill != null)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: fill,
                        shape: .circle,
                      ),
                    ),
                  ),
                // 今天（未选中）：细描边圈，不填充�?026-09-26 用户定）�?
                if (widget.isToday && !widget.isSelected)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: .circle,
                        border: Border.all(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                Column(
                  mainAxisSize: .min,
                  children: <Widget>[
                    Text(
                      '${widget.date.day}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: widget.isSelected ? scheme.onSurface : textColor,
                      ),
                    ),
                    // 新建标记：日期下一枚小圆点；≥3 篇两枚（不显数字）�?
                    if (widget.count > 0) ...<Widget>[
                      const SizedBox(height: 2),
                      Row(
                        mainAxisSize: .min,
                        children: <Widget>[
                          _calDot(theme.brightness),
                          if (widget.count >= 3) ...<Widget>[
                            const SizedBox(width: 3),
                            _calDot(theme.brightness),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 新建标记点：绿色系（2026-09-26 用户定），明暗各一档保证两种主题都清晰
  /// ——亮色窗用深绿、暗色窗用亮绿（同一色相，只调明度）�?
  Widget _calDot(Brightness brightness) => Container(
    width: 4,
    height: 4,
    decoration: BoxDecoration(
      color: switch (brightness) {
        Brightness.dark => const Color(0xFF4ADE80),
        Brightness.light => const Color(0xFF16A34A),
      },
      shape: .circle,
    ),
  );
}

/// 切月 ghost 圆钮�?8 圆，静止透明，hover 叠一档（"再叠一�?同语言）�?
class _CalNavButton extends StatefulWidget {
  const _CalNavButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_CalNavButton> createState() => _CalNavButtonState();
}

class _CalNavButtonState extends State<_CalNavButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) {
          if (mounted) setState(() => _hover = true);
        },
        onExit: (_) {
          if (mounted) setState(() => _hover = false);
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: SizedBox(
            width: 28,
            height: 28,
            child: Material(
              color: _hover
                  ? AppTheme.boardFillHover(brightness)
                  : Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: .antiAlias,
              child: Center(child: widget.icon),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「回到今天」ghost 文字钮：小灰字，hover 淡底圆角�?
class _CalGhostButton extends StatefulWidget {
  const _CalGhostButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_CalGhostButton> createState() => _CalGhostButtonState();
}

class _CalGhostButtonState extends State<_CalGhostButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return MouseRegion(
      onEnter: (_) {
        if (mounted) setState(() => _hover = true);
      },
      onExit: (_) {
        if (mounted) setState(() => _hover = false);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Material(
          color: _hover
              ? AppTheme.boardFillHover(theme.brightness)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(Tokens.radiusSm),
          clipBehavior: .antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Tokens.spaceSm,
              vertical: Tokens.spaceXs,
            ),
            child: Text(
              widget.label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
