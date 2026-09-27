import 'dart:async';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'dart:ui' as ui;
import 'package:material_ui/material_ui.dart';

import '../theme/app_popover.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'kernel/canvas_controller.dart';
import 'kernel/canvas_item.dart';
import 'kernel/canvas_mindmap.dart';

/// 工具条上的「插入」按钮：形状（矩�?/ 椭圆�? 图片�?
///
/// ## 形状�?工具"，不�"?一次性插�?�?026-09-17 用户反馈修正�"?
/// 上一版点"矩形"就落一个固定大小的矩形、并立刻切回选择工具，于是用户接着拖拽
/// 出来的是**框�?*—�?矩形工具像假�?。现在选形�?= 进入 [CanvasTool.shape]�?
/// **按住拖拽定尺�?*，点一下则落一个默认大小；画完**停在形状工具**里可以接着画�?
/// 落账仍走既有命令（`_AddItem`），撤销栈不受影响�?
class CanvasInsertButton extends StatelessWidget {
  const CanvasInsertButton({
    super.key,
    required this.controller,
    required this.onInsertImage,
  });

  final CanvasController controller;

  /// 插入图片：拾取文�?�?复制进数据目�?�?�?item。由宿主提供（它才拿得到
  /// BuildContext 做错误提示）�?
  final Future<void> Function() onInsertImage;

  /// 面板固定宽度（同时供 [AppPopover] 做屏幕内钳制）�?
  static const double panelWidth = 168;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) => AppPopover(
        panelWidth: panelWidth,
        anchorBuilder:
            (BuildContext context, VoidCallback toggle, bool isOpen) =>
                FocusRingIconButton(
                  tooltip: '插入形状（按住拖拽定尺寸）/ 图片',
                  // 形状工具生效期间按钮保持"选中"：否则用户看不出自己现在是在�?
                  // 形状、还是已经回到选择工具（这正是"矩形像框�"?的知觉根源）�"?
                  isSelected: isOpen || controller.tool == CanvasTool.shape,
                  onPressed: toggle,
                  icon: const tabler.Shape(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                ),
        builder: (BuildContext context, VoidCallback close) => Padding(
          padding: const EdgeInsets.all(Tokens.spaceXs),
          child: Column(
            mainAxisSize: .min,
            crossAxisAlignment: .stretch,
            children: <Widget>[
              _MenuItem(
                icon: const tabler.Square(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                label: '矩形',
                onTap: () {
                  controller.setShapeTool(CanvasShapeKind.rectangle);
                  close();
                },
              ),
              _MenuItem(
                icon: const tabler.Circle(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                label: '椭圆',
                onTap: () {
                  controller.setShapeTool(CanvasShapeKind.ellipse);
                  close();
                },
              ),
              _MenuItem(
                icon: const tabler.Photo(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                label: '图片',
                onTap: () {
                  close();
                  // 拾取是异步的：先收起浮层（否则文件对话框会压在浮层上）；
                  // 有意�?await——这里只是发起，结果由宿主自己提示�?
                  unawaited(onInsertImage());
                },
              ),
              _MenuItem(
                icon: const tabler.Hierarchy(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                label: '思维导图',
                onTap: () {
                  insertMindMap(controller);
                  close();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 浮层里的一行菜单项（图�?+ 文字，整行可点）�?
class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Widget icon;
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
            icon,
            const SizedBox(width: Tokens.spaceSm),
            Text(label, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// �?*已复制进数据目录**的文件插入一张图片，返回�?item�?
///
/// 初始框按图片**像素宽高�?*定（长边�?320 逻辑像素），所以不会把图拉变形�?
/// 为此先解码一次（同时让首帧就画出真图，不必等懒加载的下一帧）�?
///
/// 路径约定：调用方负责把文件复制进应用数据目录（见 [NoteMediaService]），
/// �?*绝对路径**进来——落盘时�?`MediaResolver` 换算成相对引用，画布因此自包含�?
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

/// 在视口中心插入一张默认思维导图�?中心主题"+ 两个分支），落地即选中�""?
///
/// 尺寸�?*屏幕**给（�?420×260 屏幕像素）⇒ 任何缩放级别下插进来�?看起来一样大"�""?
/// 之后用户拖角点缩放它即可——绘制按 rect **等比映射**，节点不会变形�?
MindMapItem insertMindMap(CanvasController controller) {
  final Size box = _screenToWorld(controller, const Size(420, 260));
  final MindMapItem item = newMindMapItem(
    rect: _centeredRectOf(controller, box),
  );
  controller.document.addItem(item);
  controller.setTool(CanvasTool.select);
  controller.selectItems(<CanvasItem>[item]);
  return item;
}

/// 屏幕尺寸 �?世界尺寸（保�?屏幕上看起来一样大"）�""?
Size _screenToWorld(CanvasController controller, Size screen) =>
    screen / controller.camera.scale;

/// 视口中心的矩形；[screenOffset] �?*屏幕**像素错开（一次插入多张时不重叠）�?
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
