import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// 顶部动作带（标题行 / 画布顶部）的**共享规格**（2026-11-21 抽出）。
///
/// 原先这三档常量与两个按钮类都私有在 `note_editor_view_appflowy.dart` 里；
/// 画布要"把笔记顶部的按钮同样位置放过来"，两处必须逐像素一致，所以提到
/// 主题层共享，**别在任一侧复制一份数字**。
///
/// ## 规格链（改一处必须同步另一处）
/// - 热区 [Tokens.headerActionSize]（28）、图标 [Tokens.iconSm]（18）；
/// - 上留白 [kHeaderActionTopPadding]（4）；
/// - 按钮带高 [kHeaderActionBandHeight] = 4 + 28 + 8 = **40**
///   （与侧栏品牌条 [Tokens.brandStripHeight] 同高，两列顶端动作区等高同 y）。
const double kHeaderActionIdleAlpha = 0.5;
const double kHeaderActionDisabledAlpha = 0.28;
const double kHeaderActionTopPadding = 4;
const double kHeaderActionBandHeight =
    kHeaderActionTopPadding + Tokens.headerActionSize + 8;

/// 顶部动作按钮的**唯一色源**（2026-09-23 "极简留白"）。
///
/// ⚠️ 只能经 `IconButton.foregroundColor` 下发：tabler 图标不直接读 Material 的
/// `IconTheme`（见 `AppIconTheme` 的说明），这份 style 就是图标唯一的色源。
WidgetStateProperty<Color?> headerActionColor(
  ColorScheme scheme, {
  bool active = false,
}) {
  return WidgetStateProperty.resolveWith((Set<WidgetState> states) {
    // "开着"（面板展开）用强调色，与面板建立视觉关联。
    if (active) return scheme.primary;
    if (states.contains(WidgetState.hovered) ||
        states.contains(WidgetState.focused)) {
      return scheme.onSurface;
    }
    return scheme.onSurfaceVariant.withValues(alpha: kHeaderActionIdleAlpha);
  });
}

/// 顶部**文档工具耳**：搜索 / 反链 / 标签这类文档级操作的小入口。
///
/// 常驻但不抢戏：淡色 → 悬停/聚焦明确 → 展开转 primary。
/// 笔记编辑器与画布共用，保证两处同一位置、同一观感。
class HeaderActionButton extends StatelessWidget {
  const HeaderActionButton({
    super.key,
    required this.itemKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  /// 测试定位用 key（如 'editor.ear.find' / 'canvas.ear.find'）。
  final String itemKey;
  final Widget icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// 激活态（对应面板当前展开）。
  final bool active;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return IconButton(
      key: ValueKey<String>(itemKey),
      // tooltip 交给按钮自己，别在外面包 Tooltip（外层会把提示挂在父语义节点）。
      tooltip: tooltip,
      onPressed: onPressed,
      style:
          IconButton.styleFrom(
            minimumSize: const Size.square(Tokens.headerActionSize),
            maximumSize: const Size.square(Tokens.headerActionSize),
            padding: EdgeInsets.zero,
            // ⚠️ 图标尺寸只经 iconSize 下发：icon 里刻意不写 height/width，
            // 由 AppIconTheme 转发给 tabler（写死会顶掉它）。
            iconSize: Tokens.iconSm,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
            ),
          ).copyWith(
            foregroundColor: headerActionColor(scheme, active: active),
          ),
      icon: icon,
    );
  }
}

/// 顶部**历史按钮**（撤销 / 重做）：文档级、无选区也要能用，故常驻。
///
/// 与 [HeaderActionButton] 同规格，差别：
/// 1. **灰显**表达可用性（历史栈空 ⇒ `onPressed: null` ⇒ M3 禁用态配色）；
/// 2. [wrap] 可包一层交互包装（编辑器用它做"按下保焦"，画布不需要）。
class HeaderHistoryButton extends StatelessWidget {
  const HeaderHistoryButton({
    super.key,
    required this.itemKey,
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
    this.wrap,
  });

  final String itemKey;
  final Widget icon;
  final String tooltip;

  /// 可用（历史栈非空）；false ⇒ 灰显且不可点。
  final bool enabled;
  final VoidCallback onPressed;

  /// 可选交互包装（如编辑器的 `withKeepEditorFocus`）。为 null 原样返回。
  final Widget Function(Widget child)? wrap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget button = IconButton(
      key: ValueKey<String>(itemKey),
      tooltip: tooltip,
      onPressed: enabled ? onPressed : null,
      style:
          IconButton.styleFrom(
            minimumSize: const Size.square(Tokens.headerActionSize),
            maximumSize: const Size.square(Tokens.headerActionSize),
            padding: EdgeInsets.zero,
            iconSize: Tokens.iconSm,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Tokens.radiusButton),
            ),
            disabledForegroundColor: scheme.onSurfaceVariant.withValues(
              alpha: kHeaderActionDisabledAlpha,
            ),
          ).copyWith(foregroundColor: headerActionColor(scheme)),
      icon: icon,
    );
    return wrap?.call(button) ?? button;
  }
}
