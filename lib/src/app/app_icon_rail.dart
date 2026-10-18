import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../theme/app_custom_icons.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'home_hub.dart' show HomeViewIcon, kHomeTabs;
import 'new_note_capsule.dart';
import 'providers.dart';
import 'search_palette.dart';
import 'trash_panel.dart' show showTrash;

/// 最左**图标导航轨**（2026-10-16 用户定，Option 2 第一阶段）：60px 常驻脊梁，直接贴
/// 窗口底（同旧 256 侧栏的扁平口径，无面板 / 描边 / 投影）。它把旧侧栏的
/// 「品牌行 + 搜索 + 新建 + 四视图」收成一列图标。
///
/// 上→下：**logo（装饰）· 搜索（Ctrl+K）· 新建「+」**，弹性 spacer，**四枚视图图标**
/// （心流 / 全部 / 日历 / 收藏）。选中 = hover 2× 的 selectedBg（亮 onSurface@8% /
/// 暗 white@12%），hover = [AppTheme.hoverOverlay]，同旧侧栏口径。
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
        // 四边 8 呼吸 ⇒ 内容区 44 宽；钮取 [Tokens.railButtonSize](36) 居中、两侧各余 4。
        padding: const EdgeInsets.all(Tokens.spaceSm),
        child: Column(
          children: <Widget>[
            // logo（装饰）：包豪斯三色条占位（同旧品牌行），24 方。
            const _RailLogo(),
            const SizedBox(height: Tokens.spaceSm),
            // 搜索：图标开门，接全局搜索面板（Ctrl+K 同源）。图标 22（iconMd−2，同旧
            // 搜索钮光学补偿：放大镜闭环显大，比新建小一档）。
            _RailButton(
              tooltip: '搜索（Ctrl+K）',
              onTap: showSearchPalette,
              child: CustomIcons.search(
                size: Tokens.iconMd - 2,
                color: Bauhaus.ink(b),
              ),
            ),
            const SizedBox(height: Tokens.spaceSm),
            // 新建：复用胶囊图标态（36×36，向下弹「笔记 / 画布」菜单；自带焦点环 +
            // Semantics label='新建'，故不走 [_RailButton] 以免双语义 / 双焦点）。
            const NewNoteCapsule(iconOnly: true, size: Tokens.railButtonSize),
            const Spacer(),
            // 四枚视图导航。
            for (final HomeView v in kHomeTabs)
              _RailButton(
                tooltip: _viewLabel(v),
                selected: v == current,
                onTap: () =>
                    ref.read(navHistoryProvider.notifier).selectHome(v),
                child: v.icon(
                  v == current ? scheme.onSurface : scheme.onSurfaceVariant,
                  size: Tokens.iconMd,
                ),
              ),
            const SizedBox(height: Tokens.spaceXs),
            // **全局回收站**（2026-10-18）：笔记 / 画布 / 速记一个入口。
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
          ],
        ),
      ),
    );
  }
}

String _viewLabel(HomeView v) => switch (v) {
  HomeView.timeline => '心流',
  HomeView.all => '全部',
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
