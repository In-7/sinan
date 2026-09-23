import 'dart:async';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter_riverpod/flutter_riverpod.dart';import 'package:material_ui/material_ui.dart';

import '../command/commands.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/nav_ink.dart';
import '../theme/tokens.dart';
import 'settings_panel.dart' show showSettingsPanel;

/// 主页导航的分区（index 与 [hubNavSelectionProvider] 对应）。
///
/// ⚠️ 除 0（主页）外都是**占位**——对应页面还没建。接新页面时：往这里加一项、挂进
/// [hubNavGroups] 的某个组，再在 `home_screen.dart` 的主页分支按 index 分发。
const List<({IconData icon, String label})> hubNavItems =
    <({IconData icon, String label})>[
      (icon: tabler.LayoutDashboard(height: 24, width: 24, strokeWidth: 1.5), label: '主页'),
      (icon: tabler.FileText(height: 24, width: 24, strokeWidth: 1.5), label: '全部笔记'),
      (icon: tabler.Crop(height: 24, width: 24, strokeWidth: 1.5), label: '画布'),
    ];

/// 导航板的**分组**（显示用）：组标题（null = 不显示标题）+ 组内分区 index。
///
/// Craft 的侧栏留白主要花在这里：分区标题 + 组间距，让"一串按钮"变成"有组织的
/// 导航"（2026-09-22 对照实机截图的结论）。
const List<({String? title, List<int> indices})> hubNavGroups =
    <({String? title, List<int> indices})>[
      (title: null, indices: <int>[0]),
      (title: '工作区', indices: <int>[1, 2]),
    ];

/// 主页导航当前选中的分区（0 = 主页）。
///
/// 骨架阶段它是唯一在动的导航状态。放在 provider 而不是组件的 `setState` 里：
/// **内容区也要读它**（占位分区要显示"还没建"），状态提升到双方共同的祖先之下。
final hubNavSelectionProvider = NotifierProvider<HubNavSelection, int>(
  HubNavSelection.new,
);

class HubNavSelection extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

/// 导航板里一行的左缩进：外层 6 + 行内 10 ⇒ 图标起于 16，**标签起于 44**
/// （[HubNav] 的分区标题按 44 对齐，改这里要同步改 [_GroupTitle] 的 left）。
const double _kLabelInset = 44;

/// 主页左侧的**导航板**（`docs/ui_rewrite_plan.md` §5.6，2026-09-22 对齐 Craft）。
///
/// 结构照 Craft 的侧栏抄：**顶部主操作**（新建）→ 分隔线 → 分组（组标题 + 组内项）
/// → 底部固定项（设置）。底 = [AppTheme.boardFill]（**近实中性色**，见其说明——
/// "通透感 ≠ 低不透明度"）。
///
/// ## ⚠️ 它是**贴着窗口三边的通高列**（2026-09-22 用户定）
/// 宿主（`home_screen.dart`）不给它任何边距 ⇒ **上 / 左 / 下三条边都贴在窗口边上**。
/// 由此派生两条：
/// 1. **只圆右侧两角**（`BorderRadius.horizontal`）——贴窗的那两个角必须是
///    方角：留圆角会在 window 角上留下两块"窗口底色的月牙"（你能看到"它不是一整列"）。
///    🔧 想要四角全方（Notion / VS Code 那种）就改成 `BorderRadius.zero`。
/// 2. 它不再是"浮在窗口底上的一块板" ⇒ **分界只靠明度差**（`boardFill` vs
///    [AppTheme.windowBackground]），别再指望靠留白与圆角去承担层次。
class HubNav extends ConsumerWidget {
  const HubNav({super.key, this.width = 220});

  /// 板宽。**它就是这一列的全部宽度**（此前"不含窗口左缘 6px 间距"那句已作废：
  /// 间距取消了，宿主不再留缝）。
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final int selected = ref.watch(hubNavSelectionProvider);

    // 圆角：**只圆右边两角**（见类注释）——上 / 左 / 下三条边贴在窗口边上。
    const BorderRadius radius = BorderRadius.horizontal(
      right: Radius.circular(Tokens.radiusLg),
    );
    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          // ⚠️ 这层现在是**回退底**：shader 未就绪（老 GPU / 测试环境）时看到的就是它；
          // 就绪后 mesh 铺在它上面（不透明 ⇒ 把它整块盖住）。
          // 🔧 要四角全方（Notion / VS Code 那种）就改成 `BorderRadius.zero`。
          color: AppTheme.boardFill(theme.brightness),
          borderRadius: radius,
        ),
        // ⚠️ **必须裁切**：mesh 画的是满矩形 ⇒ 不裁的话右边两角会露出方角
        // （压在圆角底上，看着像 bug）。
        child: ClipRRect(
          borderRadius: radius,
          // 🎨 水墨底（fBm + 域扭曲 + 同 pass 抖动 ⇒ 晕染边缘无 8-bit 色带）。
          // `painter` 画在 child **之下**；shader 未就绪时它是 null ⇒ 只剩回退底。
          //
          // ⚠️ **订阅 [NavInk.readyNotifier]**：preload 在 `runApp` 之后才异步完成，
          // 若不在这里接信号，首帧之后的水墨就绪不会触发重绘（要用户点一下才出来）。
          // `child` 是整列导航、只建一次，翻信号时只重建外层 CustomPaint。
          child: ValueListenableBuilder<bool>(
            valueListenable: NavInk.readyNotifier,
            builder: (BuildContext context, bool _, Widget? child) => CustomPaint(
              painter: NavInk.painter(theme.brightness),
              child: child,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SizedBox(height: Tokens.spaceSm),
                // 顶部主操作：Craft 的 "New Doc" 同位——最常用的动作不该埋在内容区里。
                _NavItem(
                  icon: tabler.Plus(height: 24, width: 24, strokeWidth: 1.5),
                  label: '新建笔记',
                  selected: false,
                  onTap: () => unawaited(runCommandById(ref, 'note.new')),
                ),
                const SizedBox(height: Tokens.spaceSm),
                // 分隔线**内缩**（Craft 的线不顶到板边）；用极淡描边色，不另造令牌。
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Tokens.spaceMd,
                  ),
                  child: Container(
                    height: 1,
                    color: AppTheme.cardStroke(theme.brightness),
                  ),
                ),
                for (final ({String? title, List<int> indices}) group
                    in hubNavGroups) ...<Widget>[
                  if (group.title != null) _GroupTitle(title: group.title!),
                  for (final int i in group.indices)
                    _NavItem(
                      icon: hubNavItems[i].icon,
                      label: hubNavItems[i].label,
                      selected: i == selected,
                      onTap: () =>
                          ref.read(hubNavSelectionProvider.notifier).select(i),
                    ),
                ],
                const Spacer(),
                const _NavItem(
                  icon: tabler.Settings(height: 24, width: 24, strokeWidth: 1.5),
                  label: '设置',
                  selected: false,
                  onTap: showSettingsPanel,
                ),
                const SizedBox(height: Tokens.spaceSm),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 分区标题（Craft 的 "Starred" / "Folders" 同位）：小号灰字，**与项标签左对齐**。
class _GroupTitle extends StatelessWidget {
  const _GroupTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        left: _kLabelInset,
        right: Tokens.spaceMd,
        top: Tokens.spaceLg,
        bottom: Tokens.spaceXs,
      ),
      child: Text(
        title,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 导航板里的一行：图标 + 标签，高 36，圆角 8。
///
/// 状态（2026-09-22 对齐 Craft）：
/// - **选中 = 中性 pill**（[AppTheme.navSelectedTint]，onSurface 10%）——Craft 的选中
///   没有 accent 也没有指示条，`accent` 省给真正需要它的地方；文字升到 onSurface + w600。
/// - 悬停 = [AppTheme.boardFillHover]（叠在板底上的量，刻意轻）。
///
/// ⚠️ 静止态**必须显式 `Colors.transparent`**，不能传 null：`Material(color: null)`
/// 会落到 canvasColor（= `surface` = 近黑的窗口底色）⇒ 每个未选中项都自己画一块
/// 黑方块，把板底盖住（2026-09-22 用户实报"还是黑色显示"）。
class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
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
    final Color fill = widget.selected
        ? AppTheme.navSelectedTint(theme.colorScheme.onSurface)
        : _hover
        ? AppTheme.boardFillHover(theme.brightness)
        : Colors.transparent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: FocusRing(
        focusNode: _focus,
        borderRadius: BorderRadius.circular(8),
        child: Material(
          color: fill,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            focusNode: _focus,
            borderRadius: BorderRadius.circular(8),
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            onHover: (bool v) => setState(() => _hover = v),
            onTap: widget.onTap,
            child: SizedBox(
              height: 36,
              child: Row(
                children: <Widget>[
                  const SizedBox(width: 10),
                  Icon(
                    widget.icon,
                    size: 18,
                    color: widget.selected
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: widget.selected
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight: widget.selected ? FontWeight.w600 : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: Tokens.spaceSm),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
