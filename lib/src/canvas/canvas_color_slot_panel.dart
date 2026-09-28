import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:material_ui/material_ui.dart';

import '../theme/app_color_swatch.dart';
import '../theme/app_popover.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'kernel/canvas_controller.dart';
import 'kernel/canvas_item.dart';
import 'kernel/canvas_mindmap.dart';
import 'kernel/canvas_palette.dart';
import 'kernel/ink_stroke.dart';

/// /
///
/// 形状/图片不在内——形状有自己的颜色面板（[ShapeItem.color] 是任意色），
/// /
bool supportsColorSlot(CanvasItem item) => item is CardItem || item is MindMapItem;

/// /
List<CanvasItem> selectedColorSlotTargets(CanvasController controller) =>
    controller.selectedItems.where(supportsColorSlot).toList(growable: false);

/// /
/// /
///
/// /
/// /
class CanvasColorSlotButton extends StatelessWidget {
  const CanvasColorSlotButton({super.key, required this.controller});

  final CanvasController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        if (selectedColorSlotTargets(controller).isEmpty) {
          return const SizedBox.shrink();
        }
        return AppPopover(
          panelWidth: CanvasColorSlotPanel.width,
          anchorBuilder:
              (BuildContext context, VoidCallback toggle, bool isOpen) =>
                  IconButton(
                    tooltip: '语义色：给卡片 / 思维导图标一种含义',
                    isSelected: isOpen,
                    onPressed: toggle,
                    icon: const tabler.Palette(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                  ),
          //  
          builder: (BuildContext context, VoidCallback _) =>
              CanvasColorSlotPanel(controller: controller),
        );
      },
    );
  }
}

/// /
///
/// /
/// /
class CanvasColorSlotPanel extends StatelessWidget {
  const CanvasColorSlotPanel({super.key, required this.controller});

  ///  
  static const double width = 236;

  final CanvasController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final List<CanvasItem> targets = selectedColorSlotTargets(controller);
        //  
        if (targets.isEmpty) return const SizedBox.shrink();
        //  
        final CanvasColorSlot? current = targets.first.colorSlot;

        return Padding(
          padding: const EdgeInsets.all(Tokens.spaceMd),
          child: Column(
            mainAxisSize: .min,
            crossAxisAlignment: .start,
            children: <Widget>[
              Text(
                targets.length > 1 ? '语义色（${targets.length} 个）' : '语义色',
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: Tokens.spaceSm),
              AppColorGrid(
                options: _slotOptions(theme.brightness),
                selected: current == null
                    ? kThemeInk
                    : canvasSlotColor(current),
                onSelect: (Color color) =>
                    controller.setSelectedColorSlot(slotOfColor(color)),
              ),
              const SizedBox(height: Tokens.spaceSm),
              Text(
                '颜色只是**标记**，具体色值跟着主题走；不跟随主题则不着色',
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

  ///  
  List<AppColorOption> _slotOptions(Brightness brightness) => <AppColorOption>[
    AppColorOption(
      value: kThemeInk,
      display: AppTheme.canvasInk(brightness),
      tooltip: '跟随主题（不着色）',
    ),
    for (final CanvasColorSlot slot in CanvasColorSlot.values)
      AppColorOption(
        value: canvasSlotColor(slot),
        display: canvasSlotColor(slot),
        tooltip: slotLabel(slot),
      ),
  ];
}

/// /
CanvasColorSlot? slotOfColor(Color color) {
  for (final CanvasColorSlot slot in CanvasColorSlot.values) {
    if (canvasSlotColor(slot) == color) return slot;
  }
  return null;
}

/// /
String slotLabel(CanvasColorSlot slot) => switch (slot) {
  CanvasColorSlot.red => '红',
  CanvasColorSlot.orange => '橙',
  CanvasColorSlot.yellow => '黄',
  CanvasColorSlot.green => '绿',
  CanvasColorSlot.cyan => '青',
  CanvasColorSlot.blue => '蓝',
  CanvasColorSlot.purple => '紫',
  CanvasColorSlot.pink => '粉',
};
