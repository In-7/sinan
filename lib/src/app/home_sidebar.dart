import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'home_hub.dart' show HomeViewIcon, kHomeTabs;
import 'new_note_capsule.dart';
import 'providers.dart';

/// 工作区**左侧扁平导航**（2026-10-12 用户定，参考 Craft）：直接贴在窗口底上，
/// **不带面板**（无 panelFill / 描边 / 投影 / 圆角卡）——层次靠"在窗口底上"本身，
/// 而不是一块浮起的卡。右边的**内容区**才包浮面卡（见 [HomeScreen] 的
/// `_FloatingPanel`）⇒ 视图集中、左侧只是导航。
///
/// 内容 = **新建胶囊** + **四枚视图导航**（心流 / 全部 / 日历 / 收藏）。它在工作区
/// 级常驻（主页态与编辑器态都在），所以新建 / 切视图在编辑器里也够得着（与已删的
/// 左索引面板同一条"常驻"原则，但去掉了面板外壳）。
class HomeSidebar extends ConsumerWidget {
  const HomeSidebar({super.key});

  /// 固定宽：要容下**展开态**的新建胶囊（枢纽 + 两枚 80 钮 ≈ 246）不溢出。
  static const double _width = 280;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Brightness brightness = Theme.of(context).brightness;
    final HomeView current = ref.watch(
      navHistoryProvider.select((NavHistoryState s) => s.view),
    );

    return SizedBox(
      width: _width,
      child: Padding(
        // 左 spaceMd / 右 spaceSm：给导航一点呼吸，又不至于太挤。
        padding: const EdgeInsets.fromLTRB(
          Tokens.spaceMd,
          Tokens.appPanelInset,
          Tokens.spaceSm,
          Tokens.spaceSm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 新建胶囊置顶（动作入口永远可点，不随下面的导航滚动）。
            const NewNoteCapsule(),
            const SizedBox(height: Tokens.spaceMd),
            // 四枚视图导航。
            for (final HomeView v in kHomeTabs)
              _SidebarItem(
                view: v,
                current: v == current,
                brightness: brightness,
                onTap: () =>
                    ref.read(navHistoryProvider.notifier).selectHome(v),
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

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.view,
    required this.current,
    required this.brightness,
    required this.onTap,
  });

  final HomeView view;
  final bool current;
  final Brightness brightness;
  final VoidCallback onTap;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
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
    final Brightness b = widget.brightness;
    final bool current = widget.current;
    // 包豪斯扁平：当前项 = 实心蓝块 + 纸字；其余透明 + 墨字、hover 墨 6% 轻覆。
    final Color fg = current ? Bauhaus.paper(b) : Bauhaus.ink(b);
    final Color bg = current
        ? Bauhaus.blue(b)
        : (_hover ? Bauhaus.hover(b) : Colors.transparent);
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
              widget.onTap();
              return null;
            },
          ),
        },
        child: FocusRing(
          focusNode: _focus,
          borderRadius: Bauhaus.radius,
          child: GestureDetector(
            onTap: widget.onTap,
            child: Container(
              height: Tokens.sidebarRowHeight,
              padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceSm),
              decoration: BoxDecoration(color: bg, borderRadius: Bauhaus.radius),
              child: Row(
                children: <Widget>[
                  widget.view.icon(fg),
                  const SizedBox(width: Tokens.spaceSm),
                  Text(
                    _viewLabel(widget.view),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: fg,
                      fontWeight: current ? FontWeight.w600 : FontWeight.w500,
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
