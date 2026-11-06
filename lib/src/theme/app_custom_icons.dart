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
///   ⇒ 清晰。2026-10-28 整族迁入（当时弃用 lucide）。图标轨 2026-11-06
///   试过 238 / Remix 后回到 **tabler 统一**（stroke 型、线宽 1.5px）；文件末尾
///   的 238 / Remix 方法**留存未用**，供以后对比 / 回退，调用点不要动它们。
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

  /// **搜索**：Fluent `search` **24 档 Regular**（2026-10-28 用户定：从 20 档
  /// 换回 24 档，为了线宽与新建 / 筛选一致）。
  ///
  /// 线宽账：24 画板描边 **1.5 单位** ⇒ 18 框实得 `1.5 × 18 / 24 = 1.125px`
  /// （与 `tab-add` 32 档的 2 单位同比例 6.25%）；bbox 占板 78%（3 → 21.78，
  /// 含斜手柄）⇒ 视觉 ≈14.1px。
  ///
  /// ⚠️ 档位的"线宽 / 画板"比并不都一致：24 与 32 档是 6.25%，而 20 档只有
  /// 5%、28 档只有 5.36%（Fluent 为小尺寸不糊而刻意调细）。所以**混用画板
  /// 会让线宽漂**——要统一到 1.125px，只用 24 / 32 两档。
  static Widget search({double size = Tokens.iconMd, Color? color}) =>
      _stroke('fluent-search', size: size, color: color);

  /// **折叠列表**：Fluent `panel-left-default` **28 档 Regular**（2026-10-28
  /// 用户定：换掉 24 档 `panel-left`）。
  ///
  /// 线宽账：28 画板描边 **1.5 单位**（外框 2→26、内线 3.5→24.5）⇒ 18 框
  /// 实得 `1.5 × 18 / 28 = 0.96px`；bbox 占板 86% ⇒ 视觉 ≈15.4px，
  /// 比 24 档那枚（≈14px）略大。
  ///
  /// ⚠️ 这枚**没有 24 档**（上游只有 28 filled / 28 regular / 32 light），
  /// 所以线宽只能停在 0.96px、比 1.125px 那族细 15%（DPR 1.5 下 1.44 物理
  /// 像素，仍清晰）。要对齐到 1.125px 只能换回 `panel-left` 24 档——图形不同。
  static Widget panelLeft({double size = Tokens.iconMd, Color? color}) =>
      _stroke('fluent-panel-left-default', size: size, color: color);

  /// **新建（标签页 + 加号）**：Fluent `tab-add` **32 档 Regular**
  /// （2026-10-28 用户定：先用 Light 实机看过，线太细，改 Regular）。
  /// 语义贴"新建一条"；画布页同枚。
  ///
  /// 线宽账：Regular 在 32 画板下描边 **2 单位**（外框 3→29、内框 5→27）⇒
  /// 渲染到 18 框实得 `2 × 18 / 32 = 1.125px`，DPR 1.5 下 ≈1.7 物理像素，
  /// 与 24 画板 1.5 那一档（[search] 等）**完全同粗**。Light 档只有 1 单位
  /// （0.56px），已实测偏虚，别回头。
  ///
  /// ⚠️ 视觉仍偏大：bbox 占板 86%（x 3 → 30.5）⇒ 18 框下 ≈15.5px，
  /// 比 [search]（≈14.1px）大 10%。这是这枚图形的固有比例，不是 bug。
  static Widget tabAdd({double size = Tokens.iconMd, Color? color}) =>
      _stroke('fluent-tab-add', size: size, color: color);

  /// **新建（不带圈）**：Fluent `add`（2026-10-28 自 lucide `plus` 迁入）。
  /// 与 [tabAdd]（标签页 + 加号）是两枚，别混用。
  static Widget plus({double size = Tokens.iconMd, Color? color}) =>
      _stroke('fluent-add', size: size, color: color);

  /// **下拉三角（实心）**：Fluent `caret-down` **Filled**（2026-10-28 新增）。
  ///
  /// 为什么不是 chevron：chevron 是线条 V，缩到 8px 仍占满视觉面积、读起来还是
  /// "一枚正经图标"；实心三角的重量随尺寸线性下降，8px 就明确是"附着的小角标"。
  static Widget caretDown({double size = Tokens.iconMd, Color? color}) =>
      _stroke('fluent-caret-down', size: size, color: color);

  /// **上翻三角（实心）**：Fluent `caret-up` Filled。菜单展开时用它。
  static Widget caretUp({double size = Tokens.iconMd, Color? color}) =>
      _stroke('fluent-caret-up', size: size, color: color);

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

  // ── 238_* 系列（单色填充，**1024 画板**，2026-11-01）— **留存未用 / 可回退** ──
  //
  // ⚠️ 这组的坐标系和 Fluent/tabler 完全不同：**1024 画板**、图形只占 ~58%
  // （Fluent 24 档占 ~80%）。同样渲染到 24 框时，视觉只有 **≈14px**，比 tabler
  // 那批（≈18px）小一圈；要视觉齐平得给到 ~30。改 size 前先看这条。
  //
  // 三枚都是纯 path（无 `fill` 属性 ⇒ 默认黑），`srcIn` 染色正常。

  /// **导航搜索**：`238_搜索`（1024 画板）。
  /// ⚠️ **只换最左图标轨那一枚**；页内搜索框的放大镜、左侧轨搜索仍用 Fluent
  /// [search]，别一起改。
  static Widget search238({double size = Tokens.iconMd, Color? color}) =>
      _stroke('238_搜索', size: size, color: color);

  /// **灵感（扩写）**：`238_扩写`（1024 画板）。图标轨「灵感」目的地。
  static Widget expand238({double size = Tokens.iconMd, Color? color}) =>
      _stroke('238_扩写', size: size, color: color);

  /// **画布（生图）**：`238_生图`（1024 画板）。图标轨「画布」目的地。
  static Widget image238({double size = Tokens.iconMd, Color? color}) =>
      _stroke('238_生图', size: size, color: color);

  // ── Remix Icon（line 版，2026-11-06）— **留存未用 / 可回退** ────────────
  //
  // 三枚都是 **24 画板 + fill 型**（line 版也是 `fill` 路径，不是 stroke），
  // ⚠️ 所以**粗细仍不可调**；但线宽 **2 单位 / 24 画板** ⇒ 24 框下实得
  // **2.0px**，DPR 1.0 也是 2 个物理像素，比 238 的 0.94px 清楚得多。
  // 图形占板 ~83%（2 → 22），24 框下视觉 ≈20px，比 tabler 略大。
  //
  // 238 三枚方法**保留供回退**：想换回只需把调用点的方法名改回去。

  /// **导航搜索**：Remix `search-line`。只换最左图标轨那一枚。
  static Widget remixSearch({double size = Tokens.iconMd, Color? color}) =>
      _stroke('remix-search', size: size, color: color);

  /// **灵感**：Remix `ai-generate`（Editor）。星星 + 生成语义。
  static Widget remixInspire({double size = Tokens.iconMd, Color? color}) =>
      _stroke('remix-inspire', size: size, color: color);

  /// **画布**：Remix `image-add-line`（Media）。图片 + 加号 = 生图。
  static Widget remixImage({double size = Tokens.iconMd, Color? color}) =>
      _stroke('remix-image', size: size, color: color);
}
