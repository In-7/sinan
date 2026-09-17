import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'tokens.dart';

/// 浮层（菜单 / 面板 / 工具条）的**统一表面**：浮层底 + 1px 描边 + 投影。
///
/// ## 三件套（缺一件就不像浮层）
/// 底色 [AppTheme.floatSurface]（与纸面**只差一档明度**）
/// + 描边 [AppTheme.menuBorder] + 投影 [AppTheme.menuElevation]。
///
/// ## 底色是"抬一档的中性色"：不是画布色，也不染种子色
/// - **不再用**编辑页那张"纸"的 [AppTheme.contentCanvas]：它与纸面逐像素同色，
///   浮层只能靠描边/投影勉强分层——2026-09-14 前的状态是 6 个浮层里 4 个连投影
///   都没有，且同屏能撞出 4 种底色（画布色 / M3 表面色 / 选区色 / 反色）；
/// - **也不取** M3 的 `surfaceContainerHigh`：那档带主题色相，与 [AppTheme]
///   头部"大面不染种子色"的规则冲突（主题色只作强调点）。
///
/// ## 谁该用、谁不该用
/// 用：**短暂浮起**的东西——菜单、下拉、工具条、弹出面板（含查找面板）。
/// 不用：**长时间停留的大面**（编辑器纸面、笔记卡片、列表条目悬浮、抽屉、
/// 底部面板）——它们是"内容容器"，仍走 [AppTheme.contentCanvas]；混进浮层会让
/// 整个应用看起来"到处在浮"。
///
/// 官方组件用不了本容器的（悬浮工具栏 / 斜杠菜单 / 右键菜单 / 主菜单 / 查找
/// 面板），也取同一批令牌填色——**改一处，全场浮层跟着变**。
class AppFloatSurface extends StatelessWidget {
  const AppFloatSurface({
    super.key,
    required this.child,
    this.width,
    this.padding,
    this.borderRadius,
  });

  final Widget child;

  /// 固定宽度（不传则随内容）。
  final double? width;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final BorderRadius radius =
        borderRadius ?? BorderRadius.circular(Tokens.radiusMd);
    return Material(
      color: AppTheme.floatSurface(theme.brightness),
      elevation: AppTheme.menuElevation,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: AppTheme.menuBorder(theme.colorScheme),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding ?? EdgeInsets.zero,
        child: width == null ? child : SizedBox(width: width, child: child),
      ),
    );
  }
}
