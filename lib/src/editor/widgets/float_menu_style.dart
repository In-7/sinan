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
/// （子树里是官方 `ColorScheme`）——所以描边色直接取 `scheme.outlineVariant`，
/// 与 `menuBorder` 用的是**同一个色源**，观感一致（这条差异只在类型层面）。
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
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    elevation: const WidgetStatePropertyAll<double>(AppTheme.menuElevation),
  );
}
