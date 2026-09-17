import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../notes/services/note_media_service.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'canvas_brush_panel.dart';
import 'canvas_insert_panel.dart';
import 'kernel/canvas_bundle.dart';
import 'kernel/canvas_controller.dart';
import 'kernel/canvas_export.dart';
import 'kernel/canvas_media.dart';
import 'kernel/canvas_view.dart';

/// 画布面板（**可嵌入**）：工具条 + [CanvasView]。
///
/// 2026-09-16 从原 `canvas_page.dart` 抽出（那是整页路由版）。抽出后本组件
/// **不含 Scaffold / 路由**，可直接作为右侧内容区的一个视图挂载——文档笔记挂
/// 块编辑器、画布笔记挂本组件（见 `home_screen.dart` 的 `detailPane`）。
///
/// 职责与分层：内核（[CanvasController]/[CanvasView]）不依赖 Material，
/// 颜色与主题接线（[AppTheme] / [Tokens]）以及键盘、PNG 导出都收在这一层。
class CanvasSurface extends StatefulWidget {
  const CanvasSurface({
    super.key,
    required this.controller,
    required this.media,
  });

  final CanvasController controller;

  /// 媒体引用解析器：导出**自包含 `.canvas.json`** 时要把磁盘上的图片读出来
  /// 内联，得先经它把相对引用换算成绝对路径。
  final MediaResolver media;

  @override
  State<CanvasSurface> createState() => _CanvasSurfaceState();
}

class _CanvasSurfaceState extends State<CanvasSurface> {
  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Brightness brightness = Theme.of(context).brightness;
    return Focus(
      // 键盘：空格临时抓手 / Delete 删所选 / Ctrl+Z·Ctrl+Shift+Z 撤销重做。
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Column(
        children: <Widget>[
          _CanvasToolbar(
            controller: widget.controller,
            onExport: () => _export(context, widget.controller),
            onExportBundle: () => _exportBundle(context, widget.controller),
            onInsertImage: () => _insertImage(context, widget.controller),
          ),
          Expanded(
            child: CanvasView(
              controller: widget.controller,
              // 与笔记编辑区同一块画布底色（亮/暗都跟随主题）。
              backgroundColor: AppTheme.contentCanvas(brightness),
              // 墨色**必须与底色同源**：底色暗而墨色黑 = 看不见自己画了什么
              // （2026-09-17 用户反馈，见 AppTheme.canvasInk）。
              inkColor: AppTheme.canvasInk(brightness),
              gridColor: AppTheme.divider(scheme),
              accentColor: scheme.primary,
              // AI 层过期标记：用与主色不同的色角色，避免和选中框混淆。
              staleColor: scheme.tertiary,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _export(
    BuildContext context,
    CanvasController controller,
  ) async {
    // 在 async gap 之前取出 messenger 状态，避免跨 await 使用 BuildContext。
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final File file = await exportCanvasToPng(
        controller,
        directory: 'sinan_media',
        pixelRatio: MediaQuery.of(context).devicePixelRatio,
      );
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('已导出：${file.path}')),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
      }
    }
  }

  /// 导出**自包含** `.canvas.json`：文档 + 图片字节（base64 内联），单个文件即
  /// 可带走——换机器 / 发给别人也能完整打开（见 `canvas_bundle.dart`）。
  Future<void> _exportBundle(
    BuildContext context,
    CanvasController controller,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final File file = await exportCanvasBundle(
        controller,
        media: widget.media,
        directory: 'sinan_media',
      );
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('已导出画布文件：${file.path}')),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
      }
    }
  }

  /// 插入图片：拾取（可多选）→ 复制进应用数据目录 → 逐张建 item。
  ///
  /// 走 [NoteMediaService]（与笔记里的插图同一个落点 `<appSupport>/media/`）：
  /// 文件被复制进数据目录，画布因此**自包含**——源文件删了/挪了都不影响，
  /// 存 JSON 时再经 `MediaResolver` 写成相对引用（换机器也能打开）。
  Future<void> _insertImage(
    BuildContext context,
    CanvasController controller,
  ) async {
    // 在 async gap 之前取出 messenger，避免跨 await 用 BuildContext。
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final List<String> paths = await NoteMediaService.pickAndStoreImages();
      if (paths.isEmpty) return; // 用户取消
      // 多选时逐张错开，避免全部叠在视口中心（看起来像只插了一张）。
      for (int i = 0; i < paths.length; i++) {
        await insertImageFromPath(
          controller,
          paths[i],
          screenOffset: Offset(24.0 * i, 24.0 * i),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('插入图片失败：$e')));
      }
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.space) {
      widget.controller.setSpacePanning(event is KeyDownEvent);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final bool ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        widget.controller.redo();
      } else {
        widget.controller.undo();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      widget.controller.deleteSelection();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

/// 工具条：工具切换 + 撤销/重做 + 缩放 + 删除所选。
///
/// 用 [ListenableBuilder] 订阅控制器（工具/撤销态变化即刷新），
/// 尺寸与图标档位走 [Tokens]（与编辑器工具栏同口径）。
class _CanvasToolbar extends StatelessWidget {
  const _CanvasToolbar({
    required this.controller,
    this.onExport,
    this.onExportBundle,
    this.onInsertImage,
  });

  final CanvasController controller;

  /// 导出当前画布为 PNG 的回调（由面板提供，需 BuildContext）。
  final VoidCallback? onExport;

  /// 导出**自包含** `.canvas.json`（含图片字节）的回调。
  final VoidCallback? onExportBundle;

  /// 插入图片（拾取 + 落盘）的回调：需 BuildContext 做错误提示，故由面板提供。
  final Future<void> Function()? onInsertImage;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? child) {
        Widget toolButton(
          CanvasTool tool,
          IconData icon,
          String tooltip,
        ) {
          final bool selected = controller.tool == tool;
          return IconButton(
            icon: Icon(icon, size: Tokens.iconSm),
            tooltip: tooltip,
            style: ButtonStyle(
              backgroundColor: WidgetStatePropertyAll<Color>(
                selected ? scheme.secondaryContainer : Colors.transparent,
              ),
              foregroundColor: WidgetStatePropertyAll<Color>(
                selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
              ),
            ),
            onPressed: () => controller.setTool(tool),
          );
        }

        return Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceSm),
          decoration: BoxDecoration(
            color: AppTheme.contentCanvas(Theme.of(context).brightness),
            border: Border(
              bottom: BorderSide(color: AppTheme.divider(scheme)),
            ),
          ),
          child: Row(
            children: <Widget>[
              toolButton(CanvasTool.pen, LucideIcons.pencil300, '笔'),
              toolButton(CanvasTool.eraser, LucideIcons.eraser300, '橡皮'),
              toolButton(
                CanvasTool.select,
                LucideIcons.mousePointer2300,
                '框选',
              ),
              toolButton(CanvasTool.pan, LucideIcons.hand300, '抓手（空格）'),
              // 笔刷设置（颜色 / 粗细 / 橡皮）与工具按钮同组：它改的就是"笔"这个
              // 工具的参数。按钮上叠一颗当前墨色圆点，改色有即时反馈。
              CanvasBrushButton(controller: controller),
              CanvasInsertButton(
                controller: controller,
                onInsertImage: onInsertImage ?? () async {},
              ),
              const VerticalDivider(width: 24),
              IconButton(
                icon: const Icon(LucideIcons.undo2300, size: 18),
                tooltip: '撤销（Ctrl+Z）',
                onPressed:
                    controller.document.canUndo ? controller.undo : null,
              ),
              IconButton(
                icon: const Icon(LucideIcons.redo2300, size: 18),
                tooltip: '重做（Ctrl+Shift+Z）',
                onPressed:
                    controller.document.canRedo ? controller.redo : null,
              ),
              const VerticalDivider(width: 24),
              IconButton(
                icon: const Icon(LucideIcons.zoomOut300, size: 18),
                tooltip: '缩小',
                onPressed: () => controller.zoomBy(1 / 1.25),
              ),
              IconButton(
                icon: const Icon(LucideIcons.zoomIn300, size: 18),
                tooltip: '放大',
                onPressed: () => controller.zoomBy(1.25),
              ),
              IconButton(
                icon: const Icon(LucideIcons.maximize300, size: 18),
                tooltip: '适应内容',
                onPressed: controller.fitToContent,
              ),
              IconButton(
                icon: const Icon(LucideIcons.image300, size: 18),
                tooltip: '导出 PNG',
                onPressed: onExport,
              ),
              IconButton(
                icon: const Icon(LucideIcons.package300, size: 18),
                tooltip: '导出画布文件（.canvas.json，含图片）',
                onPressed: onExportBundle,
              ),
              const Spacer(),
              if (controller.hasSelection)
                IconButton(
                  icon: const Icon(LucideIcons.trash2300, size: 18),
                  tooltip: '删除所选（Delete）',
                  onPressed: controller.deleteSelection,
                ),
            ],
          ),
        );
      },
    );
  }
}
