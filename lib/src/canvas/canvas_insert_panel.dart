import 'dart:async';
import 'dart:ui' as ui;

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_popover.dart';
import '../theme/tokens.dart';
import 'kernel/canvas_controller.dart';
import 'kernel/canvas_item.dart';
import 'kernel/ink_stroke.dart';

/// 工具条上的「插入」按钮：形状（矩形 / 椭圆）+ 图片。
///
/// 插入**不改内核**：`CanvasDocument.addItem` 已是带撤销的命令（`_AddItem`），
/// 形状/图片的数据模型与选中手柄早就都在，缺的只是创建入口。
class CanvasInsertButton extends StatelessWidget {
  const CanvasInsertButton({
    super.key,
    required this.controller,
    required this.onInsertImage,
  });

  final CanvasController controller;

  /// 插入图片：拾取文件 → 复制进数据目录 → 建 item。由宿主提供（它才拿得到
  /// BuildContext 做错误提示）。
  final Future<void> Function() onInsertImage;

  /// 面板固定宽度（同时供 [AppPopover] 做屏幕内钳制）。
  static const double panelWidth = 168;

  @override
  Widget build(BuildContext context) {
    return AppPopover(
      panelWidth: panelWidth,
      anchorBuilder: (BuildContext context, VoidCallback toggle, bool isOpen) =>
          IconButton(
            tooltip: '插入形状 / 图片',
            isSelected: isOpen,
            onPressed: toggle,
            icon: const Icon(LucideIcons.shapes300, size: Tokens.iconSm),
          ),
      builder: (BuildContext context, VoidCallback close) => Padding(
        padding: const EdgeInsets.all(Tokens.spaceXs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _MenuItem(
              icon: LucideIcons.square300,
              label: '矩形',
              onTap: () {
                insertShape(controller, CanvasShapeKind.rectangle);
                close();
              },
            ),
            _MenuItem(
              icon: LucideIcons.circle300,
              label: '椭圆',
              onTap: () {
                insertShape(controller, CanvasShapeKind.ellipse);
                close();
              },
            ),
            _MenuItem(
              icon: LucideIcons.image300,
              label: '图片…',
              onTap: () {
                close();
                // 拾取是异步的：先收起浮层（否则文件对话框会压在浮层上）；
                // 有意不 await——这里只是发起，结果由宿主自己提示。
                unawaited(onInsertImage());
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 浮层里的一行菜单项（图标 + 文字，整行可点）。
class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tokens.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceSm,
          vertical: Tokens.spaceSm,
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, size: Tokens.iconSm, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: Tokens.spaceSm),
            Text(label, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// 在**视口中心**插入一个默认大小的形状，并选中它（可直接拖 / 缩放）。
///
/// ## 两个约定
/// - **屏幕尺寸恒定**：世界坐标里写死大小的话，高缩放下会大得离谱。这里把
///   160×120 逻辑像素折算进世界坐标，于是任何缩放级别插入的"观感大小"一致。
/// - **颜色用哨兵** [kThemeInk]：暗色画布上自动变浅（见 [resolveInk]），用户
///   不必关心明暗档。
///
/// 拖拽拉框式创建（Excalidraw 那种"按下拖动定尺寸"）留到后续：它要动指针状态机，
/// 而"点一下就落一个默认大小、再拖手柄调"已经能完成同样的事。
void insertShape(CanvasController controller, CanvasShapeKind kind) {
  final ShapeItem item = ShapeItem(
    rect: _centeredRect(controller, const Size(160, 120)),
    kind: kind,
    color: kThemeInk,
  );
  controller.document.addItem(item);
  // 落到「选择」工具：插入之后的下一步几乎一定是调位置/大小。
  controller.setTool(CanvasTool.select);
  controller.selectItems(<CanvasItem>[item]);
}

/// 从**已复制进数据目录**的文件插入一张图片，返回该 item。
///
/// 初始框按图片**像素宽高比**定（长边约 320 逻辑像素），所以不会把图拉变形；
/// 为此先解码一次（同时让首帧就画出真图，不必等懒加载的下一帧）。
///
/// 路径约定：调用方负责把文件复制进应用数据目录（见 [NoteMediaService]），
/// 传**绝对路径**进来——落盘时由 `MediaResolver` 换算成相对引用，画布因此自包含。
Future<ImageItem> insertImageFromPath(
  CanvasController controller,
  String path, {
  Offset screenOffset = Offset.zero,
}) async {
  final Size box = _screenToWorld(controller, const Size(320, 320));
  final Rect provisional = _centeredRectOf(controller, box, screenOffset);
  final ImageItem item = ImageItem(rect: provisional, src: path);
  await item.load(onLoaded: () {});

  final ui.Image? img = item.image;
  if (img != null && img.height > 0) {
    final double height = box.width * img.height / img.width;
    item.rect = Rect.fromCenter(
      center: provisional.center,
      width: box.width,
      height: height,
    );
  }

  controller.document.addItem(item);
  controller.setTool(CanvasTool.select);
  controller.selectItems(<CanvasItem>[item]);
  return item;
}

/// 屏幕尺寸 → 世界尺寸（保证"屏幕上看起来一样大"）。
Size _screenToWorld(CanvasController controller, Size screen) =>
    screen / controller.camera.scale;

Rect _centeredRect(CanvasController controller, Size screen) =>
    _centeredRectOf(controller, _screenToWorld(controller, screen));

/// 视口中心的矩形；[screenOffset] 按**屏幕**像素错开（一次插入多张时不重叠）。
Rect _centeredRectOf(
  CanvasController controller,
  Size world, [
  Offset screenOffset = Offset.zero,
]) => Rect.fromCenter(
  center: controller.camera.screenToWorld(
    controller.viewport.center(Offset.zero) + screenOffset,
  ),
  width: world.width,
  height: world.height,
);
