import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../command/commands.dart' show runCommandById;
import '../domain/settings.dart';
import '../theme/app_custom_icons.dart' show CustomIcons;
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart' show FocusRing;
import '../theme/tokens.dart';
import 'hub_nav.dart' show hubNavSelectionProvider;
import 'providers.dart'
    show
        HomeView,
        aiPanelOpenProvider,
        navCollapsedProvider,
        navHistoryProvider,
        selectedNoteIdProvider,
        settingsProvider;
import 'search_palette.dart' show showSearchPalette;
import 'settings_panel.dart' show showSettingsPanel;

/// **可折叠左导航栏**（2026-10-08 修订：撤销原决策 B，目的地从 [WindowStrip] 迁回左栏）。
///
/// - 折叠：56px 纯图标轨；展开：图标 + 文字（默认 248，可拖拽记忆 200–340）。
/// - 复用既有 [navCollapsedProvider]；`Ctrl+\` 接上折叠 / 展开。
/// - **空间轴**（去哪）放这里；**时间轴**（上一步 / 下一步）留在 [WindowStrip] 左簇。
// 度量收编（2026-10-08）：宽高/区间见 [Tokens.navRailCollapsedWidth] 等。

/// tile 的左右 inset：圆角块离 rail 侧边的距离。
///
/// macOS 侧栏的行都是内缩的（不是贴边铺满）——圆角矩形一旦贴边就又宽又扁，
/// 观感立刻掉一档。折叠态（56px）同样吃这个 inset，图标仍几何居中。
const double _kTileInset = 6;

/// 键盘激活侧栏项：Enter / Space / 小键盘 Enter → [ActivateIntent]。
///
/// 3.47 的 [FocusableActionDetector] **删掉了 `onActivate`**（激活改为
/// `shortcuts` + `actions` 成对配置），所以这层得自己配；`actions` 里的
/// [CallbackAction] 因为要捕获 `widget.onTap`，只能在 build 里现建。
const Map<ShortcutActivator, Intent> _kTileActivateShortcuts =
    <ShortcutActivator, Intent>{
      SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    };

class NavRail extends ConsumerStatefulWidget {
  const NavRail({super.key});

  @override
  ConsumerState<NavRail> createState() => _NavRailState();
}

class _NavRailState extends ConsumerState<NavRail> {
  double _width = Tokens.navRailExpandedWidth;

  @override
  void initState() {
    super.initState();
    // 展开宽度记忆（持久化到 AppSettings.navRailWidth，拖拽结束时写回）。
    final double saved = ref.read(settingsProvider).navRailWidth;
    _width = saved.clamp(Tokens.navRailMinWidth, Tokens.navRailMaxWidth);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool collapsed = ref.watch(navCollapsedProvider);
    final double w = collapsed ? Tokens.navRailCollapsedWidth : _width;

    final bool onHome = ref.watch(selectedNoteIdProvider) == null;
    final HomeView view = ref.watch(navHistoryProvider).view;
    final bool aiOpen = ref.watch(aiPanelOpenProvider);

    bool activeFor(HomeView v) => onHome && view == v;

    return AnimatedContainer(
      duration: Tokens.durationNormal,
      curve: Curves.easeInOut,
      width: w,
      decoration: BoxDecoration(
        // ⚠️ 这里是**侧轨**（[AppTheme.railFill]），不是"板底"（[boardFill]）
        // ——两者方向相反：board 是"浮在底上的 sheet"（暗色比底**亮** 9.9），
        // rail 是"凹进窗体的列"（两个模式都比纸面沉，暗 −2.2 / 亮 −3.0）。
        // 此前误用 boardFill ⇒ 暗色下侧栏成了浮起的亮板，而最左图标轨用
        // 的是 railFill ⇒ 同一窗口里两套材质语言。且暗色 board 带 alpha 0.95，
        // 色值本就不确定。
        color: AppTheme.railFill(theme.brightness),
        border: Border(right: BorderSide(color: AppTheme.divider(scheme))),
      ),
      child: Stack(
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: Tokens.spaceSm),
              _tile(
                '主页',
                (Color c) => CustomIcons.home(size: Tokens.iconMdSm, color: c),
                onHome,
                () {
                  ref
                      .read(navHistoryProvider.notifier)
                      .selectHome(HomeView.timeline);
                  ref.read(hubNavSelectionProvider.notifier).select(0);
                },
                collapsed,
              ),
              _tile(
                '心流',
                _timelineIcon,
                activeFor(HomeView.timeline),
                () => ref
                    .read(navHistoryProvider.notifier)
                    .selectHome(HomeView.timeline),
                collapsed,
              ),
              _tile(
                '全部',
                _allIcon,
                activeFor(HomeView.all),
                () => ref
                    .read(navHistoryProvider.notifier)
                    .selectHome(HomeView.all),
                collapsed,
              ),
              _tile(
                '日历',
                _calendarIcon,
                activeFor(HomeView.calendar),
                () => ref
                    .read(navHistoryProvider.notifier)
                    .selectHome(HomeView.calendar),
                collapsed,
              ),
              _tile(
                '收藏',
                _starIcon,
                activeFor(HomeView.favorites),
                () => ref
                    .read(navHistoryProvider.notifier)
                    .selectHome(HomeView.favorites),
                collapsed,
              ),
              _tile('搜索', _searchIcon, false, showSearchPalette, collapsed),
              const Spacer(),
              const Padding(
                padding: EdgeInsets.fromLTRB(
                  Tokens.spaceSm,
                  2,
                  Tokens.spaceSm,
                  2,
                ),
                child: Divider(height: 1),
              ),
              _tile('设置', _settingsIcon, false, showSettingsPanel, collapsed),
              _tile(
                '问笔记',
                _aiIcon,
                aiOpen,
                () => unawaited(runCommandById(ref, 'ai.ask')),
                collapsed,
              ),
              const SizedBox(height: Tokens.spaceXs),
              _collapseButton(collapsed),
              const SizedBox(height: Tokens.spaceXs),
            ],
          ),
          if (!collapsed)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.deferToChild,
                  onHorizontalDragUpdate: (DragUpdateDetails d) {
                    setState(() {
                      _width = (_width + d.delta.dx).clamp(
                        Tokens.navRailMinWidth,
                        Tokens.navRailMaxWidth,
                      );
                    });
                  },
                  onHorizontalDragEnd: (_) {
                    final AppSettings s = ref.read(settingsProvider);
                    ref
                        .read(settingsProvider.notifier)
                        .update(s.copyWith(navRailWidth: _width));
                  },
                  child: const SizedBox(width: Tokens.navRailSplitterWidth),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile(
    String label,
    Widget Function(Color) icon,
    bool active,
    VoidCallback onTap,
    bool collapsed,
  ) => Padding(
    // 按钮之间留 2px 呼吸：Padding 不吃 hit 测试 ⇒ 缝里点不到，
    // 正好把「可点区域」和「视觉行」都收在各自 28px（[Tokens.sidebarRowHeight]）里。
    padding: const EdgeInsets.only(bottom: 2),
    child: _NavRailTile(
      label: label,
      icon: icon,
      active: active,
      collapsed: collapsed,
      onTap: onTap,
    ),
  );

  Widget _collapseButton(bool collapsed) => IconButton(
    icon: collapsed
        ? const tabler.ChevronsRight(
            height: Tokens.iconMdSm,
            width: Tokens.iconMdSm,
            strokeWidth: Tokens.iconStroke,
          )
        : const tabler.ChevronsLeft(
            height: Tokens.iconMdSm,
            width: Tokens.iconMdSm,
            strokeWidth: Tokens.iconStroke,
          ),
    tooltip: collapsed ? '展开导航栏' : '折叠导航栏',
    onPressed: ref.read(navCollapsedProvider.notifier).toggle,
  );

  static Widget _timelineIcon(Color c) => tabler.Clock(
    height: Tokens.iconMdSm,
    width: Tokens.iconMdSm,
    strokeWidth: Tokens.iconStroke,
    colorFilter: ui.ColorFilter.mode(c, ui.BlendMode.srcIn),
  );

  static Widget _allIcon(Color c) => tabler.LayoutGrid(
    height: Tokens.iconMdSm,
    width: Tokens.iconMdSm,
    strokeWidth: Tokens.iconStroke,
    colorFilter: ui.ColorFilter.mode(c, ui.BlendMode.srcIn),
  );

  static Widget _calendarIcon(Color c) => tabler.Calendar(
    height: Tokens.iconMdSm,
    width: Tokens.iconMdSm,
    strokeWidth: Tokens.iconStroke,
    colorFilter: ui.ColorFilter.mode(c, ui.BlendMode.srcIn),
  );

  static Widget _starIcon(Color c) => tabler.Star(
    height: Tokens.iconMdSm,
    width: Tokens.iconMdSm,
    strokeWidth: Tokens.iconStroke,
    colorFilter: ui.ColorFilter.mode(c, ui.BlendMode.srcIn),
  );

  static Widget _searchIcon(Color c) => tabler.Search(
    height: Tokens.iconMdSm,
    width: Tokens.iconMdSm,
    strokeWidth: Tokens.iconStroke,
    colorFilter: ui.ColorFilter.mode(c, ui.BlendMode.srcIn),
  );

  static Widget _settingsIcon(Color c) => tabler.Settings(
    height: Tokens.iconMdSm,
    width: Tokens.iconMdSm,
    strokeWidth: Tokens.iconStroke,
    colorFilter: ui.ColorFilter.mode(c, ui.BlendMode.srcIn),
  );

  static Widget _aiIcon(Color c) => tabler.Sparkles(
    height: Tokens.iconMdSm,
    width: Tokens.iconMdSm,
    strokeWidth: Tokens.iconStroke,
    colorFilter: ui.ColorFilter.mode(c, ui.BlendMode.srcIn),
  );
}

/// 导航栏内的一行（图标，或图标 + 文字）。
///
/// 选中态 = **强调色药丸** [AppTheme.selectedPill]（primary 12%，2026-10-08
/// 用户拍板全局统一）；hover 叠 `hoverOverlay`。旧的"中性 tint + 3px 左条"
/// 混搭已撤——药丸一种形状信号就够，两根信号并存反而打架。
///
/// hover 形状刻意对齐 macOS 侧栏（2026-10-08）：左右 `_kTileInset` 内缩、
/// 与选中**同半径**、底色经 `durationHover` 淡入淡出。三者缺一就会从
/// "精致"掉回"方角灰块"。行高 [Tokens.sidebarRowHeight]（28，Apple 口径）。
///
/// 交互由 [FocusableActionDetector] 承担（hover / 按下 / 焦点 / Enter·Space），
/// 焦点环用全项目统一的 [FocusRing]（§5.2），按压档用 [AppTheme.stateLayerPressed]。
class _NavRailTile extends StatefulWidget {
  const _NavRailTile({
    required this.label,
    required this.icon,
    required this.active,
    required this.collapsed,
    required this.onTap,
  });

  final String label;
  final Widget Function(Color) icon;
  final bool active;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  State<_NavRailTile> createState() => _NavRailTileState();
}

class _NavRailTileState extends State<_NavRailTile> {
  /// 焦点环要观察的节点——**同一个节点也要给 [FocusableActionDetector]**（见
  /// [FocusRing]：环必须跟着控件自己的节点，"祖先探针"那条路实测不回调）。
  final FocusNode _focus = FocusNode();

  bool _hover = false;
  bool _pressed = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _setHover(bool v) {
    if (_hover != v) setState(() => _hover = v);
  }

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Brightness brightness = theme.brightness;
    final Color iconColor = widget.active
        ? scheme.onSurface
        : scheme.onSurfaceVariant;

    // 三档底色 + 按压叠一档。按下用 [Color.alphaBlend] 叠在**当前底色**之上，
    // 而不是三选一 —— 否则选中项按下时 `base` 已经是选中底色、没有更重的一档，
    // 按压会"没反应"。
    final Color base = widget.active
        ? AppTheme.selectedPill(scheme)
        : (_hover ? AppTheme.hoverOverlay(brightness) : Colors.transparent);
    final Color bg = _pressed
        ? Color.alphaBlend(AppTheme.stateLayerPressed(scheme.onSurface), base)
        : base;

    return Container(
      // inset 放在**外层**：圆角底往里收了两侧各 6px（macOS 侧栏的内缩行）。
      // 2026-10-08 换装后不再有贴 rail 左缘的 3px 指示条（药丸一种信号），
      // inset 纯为行的呼吸服务。
      padding: const EdgeInsets.symmetric(horizontal: _kTileInset),
      // [FocusRing] 放在 inset **之内**：它要画在和圆角底同宽、同半径的盒子上，
      // 放到外层就会"错位一个圆角"（见 [FocusRing] 的 borderRadius 说明）。
      child: FocusRing(
        focusNode: _focus,
        borderRadius: BorderRadius.circular(Tokens.radiusSm),
        child: Semantics(
          button: true,
          selected: widget.active,
          // 按下态只能自己记：3.47 的 [FocusableActionDetector] **既没有**
          // `onActivate` 也**不通知按压**（激活已改为 shortcuts+actions），所以
          // 按压仍由 GestureDetector 的 onTapDown/Up/Cancel 承担；焦点、Tab 序、
          // Enter·Space 激活交给内层那个 detector。
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onTapDown: (_) => _setPressed(true),
            onTapUp: (_) => _setPressed(false),
            onTapCancel: () => _setPressed(false),
            child: FocusableActionDetector(
              focusNode: _focus,
              mouseCursor: SystemMouseCursors.click,
              onShowHoverHighlight: _setHover,
              shortcuts: _kTileActivateShortcuts,
              actions: <Type, Action<Intent>>{
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) {
                    widget.onTap();
                    return null;
                  },
                ),
              },
              child: AnimatedContainer(
                duration: Tokens.durationHover,
                height: Tokens.sidebarRowHeight,
                padding: widget.collapsed
                    ? EdgeInsets.zero
                    : const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
                decoration: BoxDecoration(
                  color: bg,
                  // hover / 按下 / 选中**同半径**。此前 hover 走 `null` ⇒ 指针
                  // 扫过是一块方角灰，是"廉价感"的主因。
                  borderRadius: BorderRadius.circular(Tokens.radiusSm),
                ),
                child: Row(
                  mainAxisAlignment: widget.collapsed
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: <Widget>[
                    widget.icon(iconColor),
                    if (!widget.collapsed)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: Tokens.spaceMd),
                          child: Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: widget.active
                                  ? scheme.onSurface
                                  : scheme.onSurfaceVariant,
                              fontWeight: widget.active
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
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
}
