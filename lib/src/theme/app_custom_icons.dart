import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// **外引图标**（单枚引进，不走 `tabler_icons_next` 包）。
///
/// 三类资产都放 `assets/icons/custom/`（pubspec `flutter.assets` 已注册）：
/// - **Fluent UI System Icons**（2026-10-28 引入，Regular 24 档）：`search` /
///   `panel-left` / `note-add` / `filter` / `chevron-down` / `chevron-up` /
///   `dismiss` 七枚。**填充型**路径（源文件写死 `fill="#212121"`），靠
///   [ColorFilter.srcIn] 整体染色 ⇒ 与 tabler 一样跟随前景色。
///   图形占满 24 画板（视觉 ≈ 框的 83%），比 tabler 的 ~75% 更饱满。
///   ⚠️ 2026-10-15 起的 lucide 线形版（描边制、1.5 描边）在 18px 小框下实得仅
///   1.125px ⇒ 低 DPR 屏幕发虚；Fluent 是**填充型**，栅格化时对亚像素不敏感
///   ⇒ 清晰。2026-10-28 整族迁入，项目**不再用 lucide，也不再用 remix**。
/// - **下载图标（197_* 系列）**：`197_编辑-19` / `197_画笔`（2026-10-15 用户定，落在
///   新建菜单「笔记 / 画布」两项）。**固定蓝黑双色**（非 currentColor）——必须随前景
///   染 [color]，否则深色底下黑色笔画会消失。
/// - **彩色插画图标**（非字形）：`canvas` / `book`，多色 SVG 原样渲染不染色。
///
/// ⚠️ 着色：Fluent / 下载图标都用 `colorFilter.srcIn` 染 `currentColor` / 前景色；插画
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

  /// **单色图标（Fluent 一族）**：`color` 缺省时从 [IconTheme] 解析——
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

  /// **搜索**：Fluent `search`（2026-10-28 自 lucide 迁入）。
  static Widget search({double size = Tokens.iconMd, Color? color}) =>
      _stroke('fluent-search', size: size, color: color);

  /// **折叠列表**：Fluent `panel-left`（2026-10-28 自 lucide 迁入）。
  static Widget panelLeft({double size = Tokens.iconMd, Color? color}) =>
      _stroke('fluent-panel-left', size: size, color: color);

  /// **新建（便签 +）**：Fluent `note-add`（2026-10-28 自 lucide `sticky-note-plus`
  /// 迁入）。语义贴"新建一条笔记"；画布页同枚（用户定）。
  static Widget stickyNotePlus({double size = Tokens.iconMd, Color? color}) =>
      _stroke('fluent-note-add', size: size, color: color);

  /// **新建（不带圈）**：Fluent `add`（2026-10-28 自 lucide `plus` 迁入）。
  /// 与 [stickyNotePlus]（便签 +）是两枚，别混用。
  static Widget plus({double size = Tokens.iconMd, Color? color}) =>
      _stroke('fluent-add', size: size, color: color);

  /// **下箭头**：Fluent `chevron-down`（2026-10-28 自 lucide 迁入）。
  static Widget chevronDown({double size = Tokens.iconMd, Color? color}) =>
      _stroke('fluent-chevron-down', size: size, color: color);

  /// **上箭头**：Fluent `chevron-up`（2026-10-28 自 lucide 迁入）。
  static Widget chevronUp({double size = Tokens.iconMd, Color? color}) =>
      _stroke('fluent-chevron-up', size: size, color: color);

  /// **筛选（漏斗）**：Fluent `filter`（2026-10-28 自 lucide 迁入）。
  static Widget filter({double size = Tokens.iconMd, Color? color}) =>
      _stroke('fluent-filter', size: size, color: color);

  /// **收起（×）**：Fluent `dismiss`（2026-10-28 自 lucide `x` 迁入）。
  static Widget x({double size = Tokens.iconMd, Color? color}) =>
      _stroke('fluent-dismiss', size: size, color: color);

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
