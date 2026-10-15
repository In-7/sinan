import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// **外引图标**（单枚引进，不走 `tabler_icons_next` 包）。
///
/// 三类资产都放 `assets/icons/custom/`（pubspec `flutter.assets` 已注册）：
/// - **Lucide 线形图标**（2026-10-15 引入）：`circle-plus` / `search` 两枚，描边制、
///   `currentColor` 可染色，与 tabler 同档视觉。项目**不再用 remix**（原 remix 线形
///   图标已迁出：主页 / 箭头 / 设置 / 收藏 / + 走 tabler，新建 / 搜索走 lucide）。
/// - **下载图标（197_* 系列）**：`197_编辑-19` / `197_画笔`（2026-10-15 用户定，落在
///   新建菜单「笔记 / 画布」两项）。**固定蓝黑双色**（非 currentColor）——必须随前景
///   染 [color]，否则深色底下黑色笔画会消失。
/// - **彩色插画图标**（非字形）：`canvas` / `book`，多色 SVG 原样渲染不染色。
///
/// ⚠️ 着色：Lucide / 下载图标都用 `colorFilter.srcIn` 染 `currentColor` / 前景色；插画
/// 原彩色不染。tabler 包图标走自己的 `colorFilter`；本类 SVG 是裸资产、`currentColor`
/// 无主题可解析 ⇒ 需染色的调用点必须显式传 `color`。
class CustomIcons {
  const CustomIcons._();

  static Widget _asset(
    String name, {
    double size = Tokens.iconMd,
    Color? color,
  }) => SvgPicture.asset(
    'assets/icons/custom/$name.svg',
    height: size,
    width: size,
    colorFilter: color == null
        ? null
        : ColorFilter.mode(color, BlendMode.srcIn),
  );

  /// **新建**：lucide `circle-plus`（2026-10-15 用户定，从 remix 迁出改 lucide）。
  static Widget circlePlus({double size = Tokens.iconMd, Color? color}) =>
      _asset('circle-plus', size: size, color: color);

  /// **搜索**：lucide `search`（2026-10-15 用户定，从 remix 迁出改 lucide）。
  static Widget search({double size = Tokens.iconMd, Color? color}) =>
      _asset('search', size: size, color: color);

  /// **下载图标（197_* 系列，2026-10-15 用户定）**：新建菜单「笔记」项。固定蓝黑双色，
  /// 统一染 [color]（随前景）以适配明暗主题。
  static Widget edit19({double size = Tokens.iconMd, Color? color}) =>
      _asset('197_编辑-19', size: size, color: color);

  /// **下载图标（197_* 系列，2026-10-15 用户定）**：新建菜单「画布」项。固定蓝黑双色，
  /// 统一染 [color]（随前景）以适配明暗主题。
  static Widget brush({double size = Tokens.iconMd, Color? color}) =>
      _asset('197_画笔', size: size, color: color);

  /// **彩色插画图标**（画布）：多色 SVG，原样渲染不染色，落地在导航列表 / 笔记卡片。
  static Widget canvas({double size = Tokens.iconMd}) =>
      _asset('canvas', size: size);

  /// **笔记**：`书籍.svg`（2026-09-25 用户定）。彩色插画，原样渲染。
  static Widget book({double size = Tokens.iconMd}) => _asset('书籍', size: size);
}
