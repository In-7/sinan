import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'canvas_ai_button.dart';
import 'canvas_brush_panel.dart';
import 'canvas_insert_panel.dart';
import 'kernel/canvas_controller.dart';

/// 画布**绘制工具组**（2026-11-21 从底部工具条搬到顶部动作带中段）。
///
/// 只放"画什么"：选择 / 抓手 / 画笔 / 橡皮 / 连线 + 笔刷 / 插入 / AI。
/// 缩放属"看哪里"（右下视图组）、导出导入属"文件级"（右下"更多"菜单），
/// 都不在这里——一条带里混三种语义会互相稀释。
///
/// 规格：按钮 [Tokens.toolbarButtonSize]（32，主操作档，比两端的 28 高一档），
/// **方角** [Tokens.radiusSm]（与顶部两端的耳统一；不再用 M3 默认圆底，
/// 否则"圆对方"在一条带上一眼可见）。单行 `Row`，**不换行**——换行会把
/// 40 高的顶部带撑成 80，直接压掉画布一条。
class CanvasToolStrip extends StatelessWidget {
  const CanvasToolStrip({
    super.key,
    required this.controller,
    this.onInsertImage,
    this.onAiRun,
  });

  final CanvasController controller;

  /// 插入图片（拾取 + 落盘）。为 null 时按钮仍渲染但空实现。
  final Future<void> Function()? onInsertImage;

  /// 跑一次 AI 指令；为 null（未在设置里启用）时按钮不渲染。
  final Future<void> Function(String instruction)? onAiRun;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        Widget toolButton(CanvasTool tool, Widget icon, String tooltip) {
          final bool selected = controller.tool == tool;
          return FocusRingIconButton(
            icon: icon,
            tooltip: tooltip,
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
            style: ButtonStyle(
              // 选中态用主题主色（不借派生色角色）；onPrimary 由 M3 算法
              // 保证 ≥4.5:1。
              backgroundColor: WidgetStatePropertyAll<Color>(
                selected ? scheme.primary : Colors.transparent,
              ),
              foregroundColor: WidgetStatePropertyAll<Color>(
                selected ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
              // 方角：与顶部两端按钮同一套形状语言（见类文档）。
              shape: WidgetStatePropertyAll<OutlinedBorder>(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Tokens.radiusSm),
                ),
              ),
            ),
            onPressed: () => controller.setTool(tool),
          );
        }

        // 统一热区：布局尺寸 = 热区尺寸（48 的 padded 目标会顶出浮岛边缘）。
        return IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(
              iconSize: Tokens.iconMd,
              fixedSize: const Size(
                Tokens.toolbarButtonSize,
                Tokens.toolbarButtonSize,
              ),
              minimumSize: const Size(
                Tokens.toolbarButtonSize,
                Tokens.toolbarButtonSize,
              ),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 排布对齐 tldraw：选择 → 抓手 → 画笔 → 橡皮 → 连线。
              toolButton(
                CanvasTool.select,
                const tabler.Mouse(
                  height: Tokens.iconMd,
                  width: Tokens.iconMd,
                  strokeWidth: Tokens.iconStroke,
                ),
                '选择 / 框选',
              ),
              toolButton(
                CanvasTool.pan,
                const tabler.HandStop(
                  height: Tokens.iconMd,
                  width: Tokens.iconMd,
                  strokeWidth: Tokens.iconStroke,
                ),
                '抓手（空格）',
              ),
              toolButton(
                CanvasTool.pen,
                const tabler.Edit(
                  height: Tokens.iconMd,
                  width: Tokens.iconMd,
                  strokeWidth: Tokens.iconStroke,
                ),
                '画笔',
              ),
              toolButton(
                CanvasTool.eraser,
                const tabler.Eraser(
                  height: Tokens.iconMd,
                  width: Tokens.iconMd,
                  strokeWidth: Tokens.iconStroke,
                ),
                '橡皮',
              ),
              toolButton(
                CanvasTool.connect,
                const tabler.Hierarchy(
                  height: Tokens.iconMd,
                  width: Tokens.iconMd,
                  strokeWidth: Tokens.iconStroke,
                ),
                '连线（从一个卡片拖到另一个）',
              ),
              const SizedBox(
                height: 20,
                child: VerticalDivider(width: Tokens.spaceSm),
              ),
              CanvasBrushButton(controller: controller),
              CanvasInsertButton(
                controller: controller,
                onInsertImage: onInsertImage ?? () async {},
              ),
              if (onAiRun != null) CanvasAiButton(onRun: onAiRun!),
            ],
          ),
        );
      },
    );
  }
}
