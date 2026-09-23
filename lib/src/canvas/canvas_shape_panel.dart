import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:material_ui/material_ui.dart';

import '../theme/app_color_swatch.dart';
import '../theme/app_popover.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'canvas_brush_panel.dart' show canvasPaletteOptions;
import 'canvas_panel_widgets.dart';
import 'kernel/canvas_controller.dart';
import 'kernel/canvas_item.dart';
import 'kernel/ink_stroke.dart';

/// 工具条上的「图形属性」按钮：**只在选中形状时出现**，弹出 [CanvasShapePanel]。
///
/// 没选中形状（含"选的全是笔迹/图片"）时渲染成空——属性面板是针对**所选对象**
/// 的，没有对象就不该占工具条的位。
class CanvasShapeButton extends StatelessWidget {
  const CanvasShapeButton({super.key, required this.controller});

  final CanvasController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final List<ShapeItem> shapes = selectedShapes(controller);
        if (shapes.isEmpty) return const SizedBox.shrink();
        return AppPopover(
          panelWidth: CanvasShapePanel.width,
          anchorBuilder:
              (BuildContext context, VoidCallback toggle, bool isOpen) =>
                  IconButton(
                    tooltip: '图形属性：颜色 / 填充 / 描边',
                    isSelected: isOpen,
                    onPressed: toggle,
                    icon: CanvasInkDottabler.Palette(height: 24, width: 24, strokeWidth: 1.5),
                  ),
          // 滑杆/色板要连着调，不需要"选完即关"（同笔刷面板）。
          builder: (BuildContext context, VoidCallback _) =>
              CanvasShapePanel(controller: controller),
        );
      },
    );
  }
}

/// 当前选中的形状（属性面板的作用对象）。
List<ShapeItem> selectedShapes(CanvasController controller) =>
    controller.selectedItems.whereType<ShapeItem>().toList(growable: false);

/// 形状颜色的显示色：哨兵按当前主题墨色显示（理由同 [CanvasInkDotIcon]）。
Color _displayInk(BuildContext context, Color color) =>
    resolveInk(color, AppTheme.canvasInk(Theme.of(context).brightness));

/// 图形属性面板：颜色 / 填充 / 描边粗细。
///
/// 每次操作都走 [CanvasController.updateSelectedShapeStyle]——**一次操作一条撤销
/// 命令**，于是调完颜色可以直接 Ctrl+Z 回去。
class CanvasShapePanel extends StatelessWidget {
  const CanvasShapePanel({super.key, required this.controller});

  /// 面板固定宽度（同时供 [AppPopover] 做屏幕内钳制）。
  static const double width = 236;

  /// 填充开关与描边滑杆的 key（测试与无障碍定位用）。
  static const Key filledKey = Key('canvas.shape.filled');
  static const Key strokeWidthKey = Key('canvas.shape.strokeWidth');

  final CanvasController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final List<ShapeItem> shapes = selectedShapes(controller);
        // 选区在浮层开着时被清掉（按 Esc / 点到空白）：退化成空面板比抛异常好。
        if (shapes.isEmpty) return const SizedBox.shrink();
        // 多选时以**第一个**形状为准显示；改动仍会应用到所有选中形状。
        final ShapeItem first = shapes.first;

        return Padding(
          padding: const EdgeInsets.all(Tokens.spaceMd),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _label(
                theme,
                shapes.length > 1 ? '颜色（${shapes.length} 个形状）' : '颜色',
              ),
              const SizedBox(height: Tokens.spaceSm),
              AppColorGrid(
                options: canvasPaletteOptions(theme.brightness),
                selected: first.color,
                onSelect: (Color color) =>
                    controller.updateSelectedShapeStyle(color: color),
              ),
              const SizedBox(height: Tokens.spaceLg),
              Row(
                children: <Widget>[
                  Expanded(child: _label(theme, '填充')),
                  Switch(
                    key: filledKey,
                    value: first.filled,
                    onChanged: (bool value) =>
                        controller.updateSelectedShapeStyle(filled: value),
                  ),
                ],
              ),
              _label(theme, '描边粗细  ${first.strokeWidth.round()}'),
              CanvasPanelSlider(
                key: strokeWidthKey,
                value: first.strokeWidth,
                min: 1,
                max: 24,
                // 填充形状没有描边：禁用而不是"拖了没反应"。
                onChanged: first.filled
                    ? null
                    : (double value) => controller.updateSelectedShapeStyle(
                        strokeWidth: value,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _label(ThemeData theme, String text) => Text(
    text,
    style: theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    ),
  );
}
