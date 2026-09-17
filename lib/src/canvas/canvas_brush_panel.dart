import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_color_swatch.dart';
import '../theme/app_popover.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'canvas_panel_widgets.dart';
import 'kernel/canvas_controller.dart';
import 'kernel/ink_stroke.dart';

/// 画布调色板：**亮/暗底都够对比**的中高饱和色（Excalidraw 口径）。
///
/// 首项是 [kThemeInk]——**哨兵 = 跟随主题**，保证"默认就是能看见的颜色"：用户
/// 不必知道暗色档具体是多少，选它就永远可见（这正是暗色画布那次修复的入口）。
const List<Color> canvasPalette = <Color>[
  kThemeInk, // 跟随主题（亮：近黑 / 暗：浅灰）
  Color(0xFFE5484D), // 红
  Color(0xFFF76B15), // 橙
  Color(0xFFFFC53D), // 黄
  Color(0xFF30A46C), // 绿
  Color(0xFF00A2C7), // 青
  Color(0xFF3E63DD), // 蓝
  Color(0xFF8E4EC6), // 紫
  Color(0xFFE93D82), // 粉
];

/// [canvasPalette] 的显示项：哨兵换成**当前主题墨色**。
///
/// 否则暗色浮层上的"当前色"是个近黑点，等于看不见（同 [AppColorOption.display]
/// 的说明）。笔刷面板与形状属性面板都必须经这里取，别各写一份。
List<AppColorOption> canvasPaletteOptions(Brightness brightness) =>
    <AppColorOption>[
      for (final Color color in canvasPalette)
        AppColorOption(
          value: color,
          display: color == kThemeInk ? AppTheme.canvasInk(brightness) : color,
          tooltip: color == kThemeInk ? '跟随主题（亮/暗自动）' : null,
        ),
    ];

/// 工具条上的「笔刷」按钮：弹出 [CanvasBrushPanel]。
///
/// 按钮上叠一颗**当前墨色**小圆点：颜色选择的结果要能一眼看到，否则用户改完
/// 颜色没有任何反馈（工具栏其余按钮都是无状态图标）。
class CanvasBrushButton extends StatelessWidget {
  const CanvasBrushButton({super.key, required this.controller});

  final CanvasController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) => AppPopover(
        panelWidth: CanvasBrushPanel.width,
        anchorBuilder:
            (BuildContext context, VoidCallback toggle, bool isOpen) =>
                IconButton(
                  tooltip: '笔刷：颜色 / 粗细 / 橡皮',
                  isSelected: isOpen,
                  onPressed: toggle,
                  icon: CanvasInkDotIcon(
                    icon: LucideIcons.brush300,
                    ink: resolvedInkOf(context, controller),
                  ),
                ),
        // 面板里滑杆要连着调，不需要"选完即关"，故忽略 close。
        builder: (BuildContext context, VoidCallback _) =>
            CanvasBrushPanel(controller: controller),
      ),
    );
  }
}

/// 把 [CanvasController.penColor] 解析成**实际画出来的颜色**：哨兵 [kThemeInk]
/// 按当前主题墨色显示，其余原样。浮层/按钮上的"当前色"都必须经它取。
Color resolvedInkOf(BuildContext context, CanvasController controller) =>
    resolveInk(
      controller.penColor,
      AppTheme.canvasInk(Theme.of(context).brightness),
    );

/// 笔刷设置面板：颜色 + 笔迹粗细 + 橡皮大小。
///
/// 三件事放同一个面板（不随当前工具切换内容）：都是"笔刷"的属性，切来切去反而
/// 让人找不到橡皮大小改哪儿。
class CanvasBrushPanel extends StatelessWidget {
  const CanvasBrushPanel({super.key, required this.controller});

  /// 面板固定宽度（同时供 [AppPopover] 做屏幕内钳制）。
  static const double width = 236;

  /// 两个滑杆的 key（测试与无障碍定位用）。
  static const Key penWidthKey = Key('canvas.brush.penWidth');
  static const Key eraserSizeKey = Key('canvas.brush.eraserSize');

  final CanvasController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) => Padding(
        padding: const EdgeInsets.all(Tokens.spaceMd),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _label(theme, '颜色'),
            const SizedBox(height: Tokens.spaceSm),
            AppColorGrid(
              options: canvasPaletteOptions(theme.brightness),
              selected: controller.penColor,
              onSelect: controller.setPenColor,
            ),
            const SizedBox(height: Tokens.spaceLg),
            _label(theme, '笔迹粗细  ${controller.penWidth.round()}'),
            CanvasPanelSlider(
              key: penWidthKey,
              value: controller.penWidth,
              min: 1,
              max: 24,
              onChanged: controller.setPenWidth,
            ),
            const SizedBox(height: Tokens.spaceSm),
            _label(theme, '橡皮大小  ${controller.eraserRadius.round()}'),
            CanvasPanelSlider(
              key: eraserSizeKey,
              value: controller.eraserRadius,
              min: 4,
              max: 48,
              onChanged: controller.setEraserRadius,
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(ThemeData theme, String text) => Text(
    text,
    style: theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    ),
  );
}
