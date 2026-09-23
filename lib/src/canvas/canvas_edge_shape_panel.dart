import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:material_ui/material_ui.dart';

import '../theme/app_popover.dart';
import '../theme/tokens.dart';
import 'kernel/canvas_controller.dart';
import 'kernel/canvas_edge.dart';

/// 中文标签（面板用）。`none` 即无标记。
String edgeShapeLabel(EdgeEndpointShape shape) => switch (shape) {
  EdgeEndpointShape.none => '无',
  EdgeEndpointShape.arrow => '箭头',
  EdgeEndpointShape.dot => '圆点',
  EdgeEndpointShape.diamond => '菱形',
};

/// 工具条上的「端点形状」按钮：**只在选中一条连线时出现**，弹出
/// [CanvasEdgeShapePanel]（起点 / 终点各自选形状）。
///
/// 与 [CanvasColorSlotButton] 同口径：没有选中连线时渲染成空，不占位。
class CanvasEdgeShapeButton extends StatelessWidget {
  const CanvasEdgeShapeButton({super.key, required this.controller});

  final CanvasController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        if (controller.selectedEdge == null) return const SizedBox.shrink();
        return AppPopover(
          panelWidth: CanvasEdgeShapePanel.width,
          anchorBuilder:
              (BuildContext context, VoidCallback toggle, bool isOpen) =>
                  IconButton(
                    tooltip: '端点形状：连线两端标记（箭头 / 圆点 / 菱形）',
                    isSelected: isOpen,
                    onPressed: toggle,
                    icon: tabler.Shape(height: Tokens.iconSm, width: Tokens.iconSm, strokeWidth: 1.5),
                  ),
          builder: (BuildContext context, VoidCallback _) =>
              CanvasEdgeShapePanel(controller: controller),
        );
      },
    );
  }
}

/// 端点形状面板：起点、终点各一行 [SegmentedButton]，四选一。
///
/// 每次选择都走 [CanvasController.setSelectedEdgeStartShape] /
/// [setSelectedEdgeEndShape]——**一次操作一条撤销命令**，调完形状可直接 Ctrl+Z 回退。
class CanvasEdgeShapePanel extends StatelessWidget {
  const CanvasEdgeShapePanel({super.key, required this.controller});

  /// 面板固定宽度（同时供 [AppPopover] 做屏幕内钳制）。
  static const double width = 248;

  final CanvasController controller;

  static const List<EdgeEndpointShape> _options = <EdgeEndpointShape>[
    EdgeEndpointShape.none,
    EdgeEndpointShape.arrow,
    EdgeEndpointShape.dot,
    EdgeEndpointShape.diamond,
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final CanvasEdge? edge = controller.selectedEdge;
        if (edge == null) return const SizedBox.shrink();

        Widget row(
          String title,
          EdgeEndpointShape current,
          void Function(EdgeEndpointShape) onPick,
        ) {
          return Padding(
            padding: const EdgeInsets.only(bottom: Tokens.spaceSm),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: theme.textTheme.labelMedium),
                const SizedBox(height: Tokens.spaceXs),
                SegmentedButton<EdgeEndpointShape>(
                  showSelectedIcon: false, // 只换填充，不加对勾（§5.1）
                  selected: <EdgeEndpointShape>{current},
                  onSelectionChanged: (Set<EdgeEndpointShape> s) =>
                      onPick(s.first),
                  segments: <ButtonSegment<EdgeEndpointShape>>[
                    for (final EdgeEndpointShape s in _options)
                      ButtonSegment<EdgeEndpointShape>(
                        value: s,
                        label: Text(edgeShapeLabel(s)),
                      ),
                  ],
                ),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.all(Tokens.spaceMd),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('连线端点形状', style: theme.textTheme.labelLarge),
              const SizedBox(height: Tokens.spaceSm),
              row('起点', edge.startShape, controller.setSelectedEdgeStartShape),
              row('终点', edge.endShape, controller.setSelectedEdgeEndShape),
              const SizedBox(height: Tokens.spaceXs),
              Text(
                '默认"起点无、终点箭头"——与旧画布一致；圆点=无向关联，菱形=分类/汇聚。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
