import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// **外引图标**（单枚引进，不走 `tabler_icons_next` 包）。
///
/// 三类资产都放 `assets/icons/custom/`（pubspec `flutter.assets` 已注册）：
/// - **Lucide 线形图标**（2026-10-15 引入）：`circle-plus` / `search` 两枚，描边制、
///   `currentColor` 可染色，与 tabler 同档视觉。项目**不再用 remix**（原 remix 线形
///   图标已迁出：主页 / 箭头 / 设置 / 收藏 / + 走 tabler，新建 / 搜索走 lucide）。
///   2026-10-25 用户定：**列表顶工具行整排**（折叠 / 新建 / 托盘箭头 / 搜索 /
///   筛选 / 搜索框放大镜与收起）也换 lucide——`panel-left` / `plus` /
///   `chevron-down` / `chevron-up` / `filter` / `x` 六枚。仅此一处，其余
///   tabler 不动。
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

  /// **线形图标（lucide 一族）**：`color` 缺省时从 [IconTheme] 解析——
  /// 与 tabler 包图标的取色行为**对齐**（tabler 经 AppIconTheme 桥读的正是
  /// Material `IconTheme`）。这样 `_HeadIconButton` / `IconTheme` 包装里的
  /// 图标不用逐个显式传色，`IconButton` 的默认图标色也照常生效。
  /// 显式传 [color] 时照旧优先。
  static Widget _stroke(
    String name, {
    double size = Tokens.iconMd,
    Color? color,
  }) => Builder(
    builder: (BuildContext context) => _asset(
      name,
      size: size,
      color: color ?? IconTheme.of(context).color,
    ),
  );

  /// **新建**：lucide `circle-plus`（2026-10-15 用户定，从 remix 迁出改 lucide）。
  static Widget circlePlus({double size = Tokens.iconMd, Color? color}) =>
      _stroke('circle-plus', size: size, color: color);

  /// **搜索**：lucide `search`（2026-10-15 用户定，从 remix 迁出改 lucide）。
  static Widget search({double size = Tokens.iconMd, Color? color}) =>
      _stroke('search', size: size, color: color);

  /// **折叠列表**：lucide `panel-left`（2026-10-25，列表顶工具行换 lucide）。
  static Widget panelLeft({double size = Tokens.iconMd, Color? color}) =>
      _stroke('panel-left', size: size, color: color);

  /// **新建（不带圈）**：lucide `plus`（2026-10-25，列表顶新建钮左半）。
  /// 与 [circlePlus]（带圈，导航新建胶囊）是两枚，别混用。
  static Widget plus({double size = Tokens.iconMd, Color? color}) =>
      _stroke('plus', size: size, color: color);

  /// **下箭头**：lucide `chevron-down`（2026-10-25，托盘收起态）。
  static Widget chevronDown({double size = Tokens.iconMd, Color? color}) =>
      _stroke('chevron-down', size: size, color: color);

  /// **上箭头**：lucide `chevron-up`（2026-10-25，托盘展开态）。
  static Widget chevronUp({double size = Tokens.iconMd, Color? color}) =>
      _stroke('chevron-up', size: size, color: color);

  /// **筛选（漏斗）**：lucide `filter`（2026-10-25，列表顶筛选钮）。
  static Widget filter({double size = Tokens.iconMd, Color? color}) =>
      _stroke('filter', size: size, color: color);

  /// **收起（×）**：lucide `x`（2026-10-25，页内搜索框收起钮）。
  static Widget x({double size = Tokens.iconMd, Color? color}) =>
      _stroke('x', size: size, color: color);

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
