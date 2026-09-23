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

/// 支持**语义色槽位**的 item：卡片与思维导图。
///
/// 形状/图片不在内——形状有自己的颜色面板（[ShapeItem.color] 是任意色），
/// 图片的"颜色"没有意义。
bool supportsColorSlot(CanvasItem item) => item is CardItem || item is MindMapItem;

/// 当前选中里"能标语义色"的 item（面板与按钮的作用对象）。
List<CanvasItem> selectedColorSlotTargets(CanvasController controller) =>
    controller.selectedItems.where(supportsColorSlot).toList(growable: false);

/// 工具条上的「语义色」按钮：**只在选中卡片/思维导图时出现**，弹出
/// [CanvasColorSlotPanel]。
///
/// 没选中这类对象时渲染成空——属性面板是针对**所选对象**的，没有对象就不该占位
/// （同 [CanvasShapeButton] 的口径）。
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
                    tooltip: '语义色：给卡片 / 思维导图标一个"含义色"',
                    isSelected: isOpen,
                    onPressed: toggle,
                    icon: tabler.Palette(height: Tokens.iconSm, width: Tokens.iconSm, strokeWidth: 1.5),
                  ),
          // 连着试色不需要"选完即关"（同笔刷 / 形状面板）。
          builder: (BuildContext context, VoidCallback _) =>
              CanvasColorSlotPanel(controller: controller),
        );
      },
    );
  }
}

/// 语义色面板：8 个槽位 + "跟随主题"。
///
/// 每次操作都走 [CanvasController.setSelectedColorSlot]——**一次操作一条撤销命令**，
/// 于是调完色可以直接 Ctrl+Z 回去。
class CanvasColorSlotPanel extends StatelessWidget {
  const CanvasColorSlotPanel({super.key, required this.controller});

  /// 面板固定宽度（同时供 [AppPopover] 做屏幕内钳制）。
  static const double width = 236;

  final CanvasController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final List<CanvasItem> targets = selectedColorSlotTargets(controller);
        // 选区在浮层开着时被清掉（Esc / 点到空白）：退化成空面板比抛异常好。
        if (targets.isEmpty) return const SizedBox.shrink();
        // 多选时以**第一个**为准显示；改动仍应用到所有选中项。
        final CanvasColorSlot? current = targets.first.colorSlot;

        return Padding(
          padding: const EdgeInsets.all(Tokens.spaceMd),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
                '颜色只是**标记**，具体色值跟着主题走；选"跟随主题"则不着色。',
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

  /// 面板选项：首项 = 跟随主题（哨兵），其后 = 8 个语义槽位。
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

/// 色块颜色 → 槽位。首项哨兵（[kThemeInk]）与未知色都返回 `null`（= 跟随主题）。
CanvasColorSlot? slotOfColor(Color color) {
  for (final CanvasColorSlot slot in CanvasColorSlot.values) {
    if (canvasSlotColor(slot) == color) return slot;
  }
  return null;
}

/// 槽位的中文名（面板 tooltip）。
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
