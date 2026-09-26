import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// **外引图标**（单枚引进，不走 `tabler_icons_next` 包）。
///
/// ## 口子只开给"官方包里没有更好字形"的个别图标
/// SVG 资产放 `assets/icons/custom/`（pubspec `flutter.assets` 已注册），
/// 每枚文件头保留来源许可注释。当前选型 **Remix Icon**（Apache 2.0 可商用）
/// ——同为 24×24 画板、视觉 2px 线重，与旁边的 tabler 图标混排不打架。
/// ⚠️ 格式差异：Remix line 图标是**填充路径**（`fill`，描边已烘焙进几何），
/// 不是 stroke 属性 ⇒ 没有 strokeWidth 可调，着色仍走 `colorFilter.srcIn`。
/// （曾试过 Lucide `search`（ISC，stroke 制），用户对比后选了 Remix。）
///
/// ⚠️ 与 tabler 包图标的着色差别：tabler 走 `AppIconTheme` 桥接（读
/// Material `IconTheme`），本类的 SVG 是**裸资产**，`currentColor` 没有主题
/// 可解析 ⇒ **调用点必须显式传 `color`**（通常 `scheme.onSurfaceVariant`），
/// 不传就是资产里的死黑。
///
/// ⚠️ 尺寸走 [Tokens] 图标档（默认 [Tokens.iconMd]）——画板同为 24，
/// 换算规则与 tabler 一致（见 [Tokens.iconMd] 的注释）。
class CustomIcons {
  const CustomIcons._();

  static Widget _asset(String name, {double size = Tokens.iconMd, Color? color}) =>
      SvgPicture.asset(
        'assets/icons/custom/$name.svg',
        height: size,
        width: size,
        colorFilter: color == null
            ? null
            : ColorFilter.mode(color, BlendMode.srcIn),
      );

  /// 主页（Remix `home-4-line`）。顶行工具图标在用。
  static Widget home({double size = Tokens.iconMd, Color? color}) =>
      _asset('home', size: size, color: color);

  /// 搜索（Remix `search-ai-line`）。顶行工具图标在用。
  static Widget search({double size = Tokens.iconMd, Color? color}) =>
      _asset('search', size: size, color: color);

  /// 设置（Remix `settings-2-line`）。顶行工具图标在用。
  static Widget settings({double size = Tokens.iconMd, Color? color}) =>
      _asset('settings', size: size, color: color);

  /// 新建（Remix `add-line`，2026-09-26 定）。顶行工具图标在用。
  ///
  /// 新建（Remix `add-circle-line`，2026-09-26 回到这个）。顶行工具图标在用。
  ///
  /// 顶行四枚**同源**（Remix）才能"一排安静的工具图标"：早先这枚用过 `tabler.Plus`
  /// （stroke 制，不在 Remix 体系），又试过 `add-line`（纯描边加号）与 `add-large-fill`
  /// （实心填充、比另三枚显重）。最终用户定回 `add-circle-line`——闭合圆环 + 圈内
  /// 加号，是"新建"语义最直白的那种图标。
  static Widget add({double size = Tokens.iconMd, Color? color}) =>
      _asset('add-circle-line', size: size, color: color);

  /// **彩色插画图标**（注意：与上面 Remix 单色线形不同族）。
  ///
  /// 来源是 iconfont 式多色 SVG（`阳光` / `星球`，画板 1024×1024，`fill` 写死
  /// 色值、非 `currentColor`）。它们是插画不是字形，故**不套 `colorFilter`**
  /// ——`color` 永远不传，渲染资产里的原彩色。落地在导航列表里（笔记 / 画布）
  /// 会与旁边单色线形图标形成"一点彩色"，2026-09-24 用户定。
  /// 若要它们也变单色，改在 `_asset` 里强制 `color: scheme.onSurfaceVariant`。
  static Widget canvas({double size = Tokens.iconMd}) => _asset('canvas', size: size);
  /// **笔记**：`书籍.svg`（2026-09-25 用户定：用下载的书籍图标替换原 notes.svg）。
  /// 走 `_asset` 原彩色渲染；同 `canvas` 是插画不是字形。文件在 `assets/icons/custom/书籍.svg`。
  static Widget book({double size = Tokens.iconMd}) => _asset('书籍', size: size);
}
