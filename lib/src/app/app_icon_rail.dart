import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../theme/app_custom_icons.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'home_hub.dart' show HomeViewIcon, kHomeTabs;
import 'providers.dart';
import 'search_palette.dart';
import 'settings_panel.dart' show showSettingsPanel;
import 'trash_panel.dart' show showTrash;

/// 最左**图标导航轨**（2026-10-16 用户定，Option 2 第一阶段）：60px 常驻脊梁，直接贴
/// 窗口底（同旧 256 侧栏的扁平口径，无面板 / 描边 / 投影）。它把旧侧栏的
/// 「品牌行 + 搜索 + 四视图」收成一列图标。
///（2026-10-21 曾试加宽到 70，同日撤回——图标 / 钮不变时纯加宽只是多出空白边距。）
///
/// 上→下：**logo（装饰）· 搜索（Ctrl+K）· 四枚视图图标**（灵感 / 笔记 / 画布 /
/// 日历），弹性 spacer，底部**回收站 · 设置**两枚工具钮（2026-11-01 视图簇从
/// 底部上移、设置从标题栏搬来，对齐 ima 的「品牌 → 导航簇 → 大片留白 → 底部工具」）。
///
/// 间距**三级**：组内 [Tokens.spaceXs](4)、组间 [Tokens.spaceLg](16)、轨道边距
/// [Tokens.spaceSm](8)——**组间是组内的 4 倍**，人眼才读得出"这是两簇"；1.5~2 倍
/// 的分组会糊成一片。
///
/// 选中 = hover 2× 的 selectedBg（亮 onSurface@8% / 暗 white@12%），
/// hover = [AppTheme.hoverOverlay]，同旧侧栏口径。
///
/// 第二阶段的 208 列表列接在它右边；本轨是 App 脊梁（Phase D 起常驻不折叠）。
class AppIconRail extends ConsumerWidget {
  const AppIconRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Brightness b = theme.brightness;
    final HomeView current =
        ref.watch(navHistoryProvider.select((NavHistoryState s) => s.view));
    final int trashCount = ref.watch(trashProvider).length;

    return SizedBox(
      width: Tokens.railWidth,
      child: Padding(
        // **纵向 12 / 横向 8**（2026-11-01 日式"外松内紧"）：
        // - 横向必须 8：轨 60 − 8×2 = 44 内容区，36 的钮居中后视觉边距 12；
        // - 纵向提到 12：原来 8 比组间（24）还紧，顶部 logo / 底部设置会被"顶住"。
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceSm,
          vertical: Tokens.spaceMd,
        ),
        // **响应式**（2026-11-01）：按**轨道自身分到的高度**分档，不是窗口高——
        // 官方 General approach 的「组件级 Measure」就是 LayoutBuilder。
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final _RailSpacing s = _RailSpacing.forHeight(
              constraints.maxHeight,
            );
            return Column(
              children: <Widget>[
                // logo（装饰）：包豪斯三色条占位（同旧品牌行），24 方。
                const _RailLogo(),
                // 组间：品牌 → 目的地。**组间是组内的 4 倍**——人眼要靠 ≥3 倍的
                // 间距差才读得出"分组"（4:16 成立；4:8 只有 2 倍，会糊成一片）。
                SizedBox(height: s.betweenGroups),
                // 视图簇：**Expanded + ScrollView 取代 Spacer**。
                // - 空间富余 ⇒ viewport **强制撑满**分到的高度（Expanded = tight）、
                //   内容顶部对齐，视觉等同 Spacer；
                // - 空间不足 ⇒ 簇内滚动，**永不溢出**（Spacer 只会被压到 0，再挤就报黄条）。
                //
                // ⚠️ 必须是 Expanded 不是 Flexible：loose 下 SingleChildScrollView 会
                // 收缩到内容高度（实测底部组停在 380 而非贴底 552），Spacer 的效果就没了。
                Expanded(
                  child: ScrollConfiguration(
                    // 不溢出时本就不画滚动条；关掉是为了极矮时也不突然冒出来。
                    behavior: ScrollConfiguration.of(
                      context,
                    ).copyWith(scrollbars: false),
                    child: SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      child: Column(
                        children: <Widget>[
                          // 四枚视图导航（2026-11-01 从轨道**底部**移到搜索之下，
                          // 对齐 ima 的「品牌 → 导航簇 → 大片留白 → 底部工具」）。
                          // 组内紧凑成列：36 + 组内间距的节奏，读成"一列"。
                          for (final HomeView v in kHomeTabs) ...<Widget>[
                            if (v != kHomeTabs.first)
                              SizedBox(height: s.withinGroup),
                            _RailButton(
                              tooltip: _viewLabel(v),
                              selected: v == current,
                              onTap: () => ref
                                  .read(navHistoryProvider.notifier)
                                  .selectHome(v),
                              child: v.icon(
                                v == current
                                    ? scheme.onSurface
                                    : scheme.onSurfaceVariant,
                                size: Tokens.iconMd,
                              ),
                            ),
                          ],
                          // 目的地 → 搜索：与「笔记 ↔ 画布」**同档**（组内间距），
                          // 2026-11-01 用户定——搜索跟着四个目的地走同一个节奏，
                          // 读成"第 5 项"；与底部工具的区隔交给下方那片大留白。
                          SizedBox(height: s.withinGroup),
                          // 搜索：图标开门，接全局搜索面板（Ctrl+K 同源）。2026-11-01
                          // 换成 `238_搜索`（1024 画板）——它比 Fluent 的小一圈，
                          // 所以用满 iconMd(24) 而不是原来的 iconMd−2 补偿档。
                          _RailButton(
                            tooltip: '搜索（Ctrl+K）',
                            onTap: showSearchPalette,
                            child: CustomIcons.search238(
                              color: Bauhaus.ink(b),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // 组间：导航 → 底部工具组。矮窗时也保底这么多，不会贴住回收站。
                SizedBox(height: s.betweenGroups),
                // **全局回收站**（2026-10-18）：笔记 / 画布 / 灵感一个入口。
                _RailButton(
                  tooltip: trashCount > 0 ? '回收站（$trashCount）' : '回收站',
                  onTap: showTrash,
                  child: tabler.Trash(
                    height: Tokens.iconMd,
                    width: Tokens.iconMd,
                    strokeWidth: Tokens.iconStroke,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                // 组内：底部工具组，与视图簇的组内节奏一致。
                SizedBox(height: s.withinGroup),
                // **设置**（2026-11-01 从标题栏 `trailing` 搬来）：全局配置放轨道**最底**。
                // 轨道自上而下是"越往下越元级"——目的地导航（去哪）→ 回收站（内容终点）
                // → 设置（应用配置）；与 VS Code / Obsidian / Notion 的左下角惯例一致。
                // 图标档取 [Tokens.iconMd]（跟着轨道其它钮，不用标题栏那档 20）。
                _RailButton(
                  tooltip: '设置',
                  onTap: showSettingsPanel,
                  child: tabler.Settings(
                    height: Tokens.iconMd,
                    width: Tokens.iconMd,
                    strokeWidth: Tokens.iconStroke,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 轨上 tooltip 一律**向右**展开（2026-11-01 用户定）。
///
/// 轨道只有 [Tokens.railWidth] 宽，默认的"下方居中"会横跨到轨道外的内容卡上、
/// 还会盖住相邻钮；竖向 Activity Bar 的通用做法就是向右（VS Code 同款）。
///
/// 右侧放不下时翻到左侧，再夹进 overlay 边界——避免窄窗 / 贴边时被裁掉。
Offset _railTooltipPosition(TooltipPositionContext c) {
  const double gap = Tokens.spaceSm;
  // ⚠️ `target` 是**锚点中心**（不是左上角）——配 `targetSize` 还原成矩形再算边。
  final Rect anchor = Rect.fromCenter(
    center: c.target,
    width: c.targetSize.width,
    height: c.targetSize.height,
  );
  final bool fitsRight =
      c.overlaySize.width - anchor.right >= c.tooltipSize.width + gap;
  final double x = fitsRight
      ? anchor.right + gap
      : anchor.left - gap - c.tooltipSize.width;
  final double y = anchor.center.dy - c.tooltipSize.height / 2;
  return Offset(
    x.clamp(0, math.max(0, c.overlaySize.width - c.tooltipSize.width)),
    y.clamp(0, math.max(0, c.overlaySize.height - c.tooltipSize.height)),
  );
}

/// 轨道的**间距档位**（2026-11-01 响应式，方案 A）。
///
/// 断点按轨道**自身分到的高度**分，不是窗口高：轨道 = 窗口高 − 标题栏 32，
/// 未来若加环缝 / 多窗口，只有这个高度是准的。
///
/// ## 为什么 spacious 是 24 : 8 这一对
/// 图标 24 装在 36 的钮里 ⇒ **图标间空白 = 12 + 组内间距**。组内 4 时只有 16
/// （比微信侧栏的 20~24 挤），且 hover 底块之间只剩 4 的缝，视觉上糊成一片。
///
/// token 阶梯只有 `2/4/8/12/16/24/48`，要同时满足"不挤（≥8）"和"组间 ≥3 倍
/// 组内（否则分组糊）"，可用的组合只有 `8 : 24`：
/// - `4 : 16`（旧值）→ 挤
/// - `8 : 16` → 2 倍，分组糊
/// - `8 : 24` → **3 倍** ✅ 图标间空白 20（微信水平）、块间缝 8
///
/// 三档的最小内容高（**含纵向 padding 12**；搜索与目的地同档 8）：
/// - spacious `24/8` ≈ **388**：默认 800 高（轨 768）与最低窗 560（轨 528）都落这档；
/// - regular `16/8` ≈ **372**：高度被压掉一截时的退路；
/// - compact `12/4` ≈ **344**：极端矮窗，再往下就靠视图簇内部滚动兜底。
class _RailSpacing {
  const _RailSpacing({required this.betweenGroups, required this.withinGroup});

  /// 组间：品牌↔目的地、目的地↔搜索、搜索↔底部工具。也是 `betweenGroups :
  /// withinGroup` 的倍数关系——**≥3 倍**才能被眼睛读成"两簇"。
  final double betweenGroups;

  /// 组内：目的地之间、回收站↔设置。
  final double withinGroup;

  static _RailSpacing forHeight(double h) {
    if (h >= 388) {
      return const _RailSpacing(
        betweenGroups: Tokens.spaceXl, // 24
        withinGroup: Tokens.spaceSm, // 8
      );
    }
    if (h >= 372) {
      return const _RailSpacing(
        betweenGroups: Tokens.spaceLg, // 16
        withinGroup: Tokens.spaceSm, // 8
      );
    }
    return const _RailSpacing(
      betweenGroups: Tokens.spaceMd, // 12
      withinGroup: Tokens.spaceXs, // 4
    );
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

/// 轨顶 logo（装饰）：包豪斯三色条（蓝 = 主题点睛 / 黄·绿 = 内容层两 accent），24 方、
/// 三条 6 高 + spaceBetween。非交互、退出语义（纯品牌占位；拿到正式 SVG 再换）。
class _RailLogo extends StatelessWidget {
  const _RailLogo();

  @override
  Widget build(BuildContext context) {
    final Brightness b = Theme.of(context).brightness;
    return Semantics(
      excludeSemantics: true,
      child: SizedBox(
        width: Tokens.iconMd,
        height: Tokens.iconMd,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final Color c in <Color>[
              Bauhaus.blue(b),
              Bauhaus.yellow(b),
              Bauhaus.green(b),
            ])
              Container(
                height: 6,
                decoration: BoxDecoration(
                  color: c,
                  borderRadius: BorderRadius.circular(Tokens.radiusFull),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 轨上单枚图标钮（搜索 / 四视图共用）：32 方、圆角 10、hover 铺 [AppTheme.hoverOverlay]、
/// 选中铺 2× selectedBg、焦点环、读屏 button/selected。图标子件 excludeSemantics
/// （tabler 的 isImage 会并进节点读成"…，图像"），标签靠 Tooltip（同旧侧栏导航项口径）。
class _RailButton extends StatefulWidget {
  const _RailButton({
    required this.child,
    required this.tooltip,
    required this.onTap,
    this.selected,
  });

  final Widget child;
  final String tooltip;
  final VoidCallback onTap;
  /// 选中态：**仅视图导航传**（true=当前视图 / false=其它视图）；搜索等非导航钮不传
  /// （= null ⇒ 不声明 selected，读屏不会把它念成"未选中的导航项"）。
  final bool? selected;

  @override
  State<_RailButton> createState() => _RailButtonState();
}

class _RailButtonState extends State<_RailButton> {
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
    final bool isSelected = widget.selected ?? false;
    // 选中 = hover 的 2×（2026-10-16 用户定，明暗同比例）：暗 white@12% / 亮 onSurface@8%。
    final Color selectedBg = b == Brightness.dark
        ? Colors.white.withValues(alpha: 0.12)
        : scheme.onSurface.withValues(alpha: 0.08);
    final Color bg = isSelected
        ? selectedBg
        : (_hover ? AppTheme.hoverOverlay(b) : Colors.transparent);
    return Tooltip(
      message: widget.tooltip,
      // 竖向轨道：tooltip 向右展开（见 [_railTooltipPosition]）。
      positionDelegate: _railTooltipPosition,
      child: MouseRegion(
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
                widget.onTap();
                return null;
              },
            ),
          },
          child: Semantics(
            button: true,
            enabled: true,
            selected: widget.selected,
            // 标签落**按钮自己的节点**（不靠外层 Tooltip——那会挂到父节点、按钮仍无标签；
            // 且焦点顺序测试只读聚焦节点的后代，外层 Tooltip 是祖先读不到）。外层 Tooltip
            // 仍保留，仅供鼠标悬浮的视觉提示。
            label: widget.tooltip,
            child: FocusRing(
              focusNode: _focus,
              borderRadius: Bauhaus.radius,
              child: GestureDetector(
                onTap: widget.onTap,
                child: Container(
                  width: Tokens.railButtonSize,
                  height: Tokens.railButtonSize,
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: Bauhaus.radius,
                  ),
                  child: Center(
                    child: Semantics(
                      excludeSemantics: true,
                      child: widget.child,
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
