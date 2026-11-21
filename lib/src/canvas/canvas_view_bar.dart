import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../theme/app_float_surface.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'kernel/canvas_controller.dart';

/// 画布**右下角视图组**（2026-11-21）：缩小 / 倍数 / 放大 / 适应内容，
/// 加一枚「更多」收文件级动作（导出 PNG / 导出包 / 导入包）。
///
/// 为什么在右下而不是顶部：缩放改的是**视角**，不是画布内容，和"画什么"
/// 不同层（Figma / Miro / tldraw 同款位置）。左下留给删除通知条（`showUndoToast`）。
///
/// 尺寸用 [Tokens.headerActionSize]（28，辅助档），比顶部主工具（32）小一档，
/// 自动退为次级、不跟顶部抢注意力。
class CanvasViewBar extends StatelessWidget {
  const CanvasViewBar({
    super.key,
    required this.controller,
    this.onExport,
    this.onExportBundle,
    this.onImport,
  });

  final CanvasController controller;

  /// 导出 PNG / 自包含 `.canvas.json` / 导入（会替换当前画布）。
  final VoidCallback? onExport;
  final VoidCallback? onExportBundle;
  final Future<void> Function()? onImport;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 倍数徽标 / 禁用态都随控制器变化 ⇒ 整条订阅（与旧底部工具条同一条路）。
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) => _buildBar(scheme, context),
    );
  }

  Widget _buildBar(ColorScheme scheme, BuildContext context) {
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: IconButton.styleFrom(
          iconSize: Tokens.iconSm,
          fixedSize: const Size.square(Tokens.headerActionSize),
          minimumSize: const Size.square(Tokens.headerActionSize),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
          ),
          foregroundColor: scheme.onSurfaceVariant,
        ),
      ),
      child: AppFloatSurface(
        padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceXs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FocusRingIconButton(
              icon: const tabler.ZoomOut(
                height: Tokens.iconSm,
                width: Tokens.iconSm,
                strokeWidth: Tokens.iconStroke,
              ),
              tooltip: '缩小',
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
              onPressed: () => controller.zoomBy(1 / 1.25),
            ),
            _ZoomBadge(
              controller: controller,
              foreground: scheme.onSurfaceVariant,
              textStyle: Theme.of(context).textTheme.labelMedium,
            ),
            FocusRingIconButton(
              icon: const tabler.ZoomIn(
                height: Tokens.iconSm,
                width: Tokens.iconSm,
                strokeWidth: Tokens.iconStroke,
              ),
              tooltip: '放大',
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
              onPressed: () => controller.zoomBy(1.25),
            ),
            FocusRingIconButton(
              icon: const tabler.ArrowsMaximize(
                height: Tokens.iconSm,
                width: Tokens.iconSm,
                strokeWidth: Tokens.iconStroke,
              ),
              tooltip: '适应内容',
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
              onPressed: controller.fitToContent,
            ),
            if (onExport != null || onExportBundle != null || onImport != null)
              PopupMenuButton<String>(
                tooltip: '更多',
                icon: const tabler.Dots(
                  height: Tokens.iconSm,
                  width: Tokens.iconSm,
                  strokeWidth: Tokens.iconStroke,
                ),
                iconSize: Tokens.iconSm,
                padding: EdgeInsets.zero,
                position: PopupMenuPosition.over,
                onSelected: (String v) {
                  switch (v) {
                    case 'png':
                      onExport?.call();
                    case 'bundle':
                      onExportBundle?.call();
                    case 'import':
                      // 导入是异步且自带结果提示，这里只需发起。
                      unawaited(onImport?.call() ?? Future<void>.value());
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  if (onExport != null)
                    const PopupMenuItem<String>(
                      value: 'png',
                      child: Text('导出 PNG'),
                    ),
                  if (onExportBundle != null)
                    const PopupMenuItem<String>(
                      value: 'bundle',
                      child: Text('导出画布文件（含图片）'),
                    ),
                  if (onImport != null) ...<PopupMenuEntry<String>>[
                    const PopupMenuDivider(),
                    const PopupMenuItem<String>(
                      value: 'import',
                      child: Text('导入画布文件（替换当前）'),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// 缩放倍数徽标：点一下回到 100%。
///
/// 单独一件而非复用 [FocusRingIconButton]：形状不同（`TextButton` 的圆角来自
/// 全局主题）。固定最小宽度 ⇒ 位数变化时按钮不左右抖。
class _ZoomBadge extends StatefulWidget {
  const _ZoomBadge({
    required this.controller,
    required this.foreground,
    required this.textStyle,
  });

  final CanvasController controller;
  final Color foreground;
  final TextStyle? textStyle;

  @override
  State<_ZoomBadge> createState() => _ZoomBadgeState();
}

class _ZoomBadgeState extends State<_ZoomBadge> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusRing(
      focusNode: _focus,
      borderRadius: BorderRadius.circular(Tokens.radiusSm),
      child: Tooltip(
        message: '当前缩放（点击回到 100%）',
        child: TextButton(
          focusNode: _focus,
          onPressed: widget.controller.resetZoom,
          style: TextButton.styleFrom(
            minimumSize: const Size(48, Tokens.headerActionSize),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceXs),
            foregroundColor: widget.foreground,
            textStyle: widget.textStyle,
          ),
          child: Text('${(widget.controller.camera.scale * 100).round()}%'),
        ),
      ),
    );
  }
}
