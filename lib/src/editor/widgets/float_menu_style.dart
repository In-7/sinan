import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// **编辑器子树内**的浮层菜单样式（官方 material 那一套）。
///
/// ## 为什么必须显式传（2026-09-15 探针实测）
/// 编辑器子树跑在**官方 material + `MaterialUiCompatibilityBridge`** 上，而那座桥
/// **不透传 `menuTheme` / `popupMenuTheme`** ⇒ 子树里的 `MenuAnchor`（如块操作菜单）
/// 会落到 M3 默认：**带种子色的 `surfaceContainerHigh`（实测亮色 `#E9EFEE`）
/// + elevation 3 + radius 4 + 无描边**。与场外菜单（浮层三件套：`floatSurface`
/// + `menuBorder` 描边 + `menuElevation`）**不是一族**——底色带绿、没有描边，
/// 同屏并置一眼就看出两套。
///
/// ## 与 `AppTheme.menuBorder` 的关系
/// 那支函数收的是 **material_ui 的 `ColorScheme`**（应用侧类型），这里天然拿不到
/// （子树里是官方 `ColorScheme`）——所以改用它的**裸色版**
/// [AppTheme.menuBorderColor]：同一个色源、同一个 APCA 钳制、同一个发丝宽度
/// （`Tokens.hairlineWidth`）。**别再手写 `BorderSide(color: outlineVariant)`**：
/// 那样在暗色下只有 Lc −8.2，等于没描边（2026-09-22 统一时发现的）。
///
/// 场外（应用侧）的菜单**不要**用本函数：那边的 `menuTheme` 已经生效。
MenuStyle sinanEditorFloatMenuStyle(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  final ColorScheme scheme = theme.colorScheme;
  return MenuStyle(
    backgroundColor: WidgetStatePropertyAll<Color>(
      AppTheme.floatSurface(theme.brightness),
    ),
    shape: WidgetStatePropertyAll<OutlinedBorder>(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tokens.radiusSm),
        // 与浮层同一道描边（发丝宽 + APCA 钳到 Lc 22）：此前这里是**裸的
        // `outlineVariant`**，暗色下 `floatSurface` 上只有 Lc −8.2 ⇒ 等于没描边，
        // 与 `popupMenuTheme` / `AppFloatSurface` 也不一致（2026-09-22 统一）。
        side: BorderSide(
          width: Tokens.hairlineWidth,
          color: AppTheme.menuBorderColor(
            scheme.outlineVariant,
            theme.brightness,
          ),
        ),
      ),
    ),
    elevation: const WidgetStatePropertyAll<double>(AppTheme.menuElevation),
  );
}
