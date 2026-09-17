import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/canvas_insert_panel.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';

/// 插入形状 / 图片的回归（2026-09-17，画布 P0）。
///
/// 只测**插入逻辑**（纯函数，不必起 widget）：落点、尺寸口径、选中、以及两条
/// 容易悄悄坏掉的约定——
/// 1. **尺寸按缩放折算**：世界坐标写死后，缩放到 4× 插入的矩形会撑满屏幕；
/// 2. **颜色用哨兵**：写具体色就烤死在当前明暗档上，切主题后矩形在暗色画布
///    上隐形（正是刚修掉的那类 bug）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('插入矩形：落视口中心、世界尺寸按缩放折算、落地即选中', () {
    final CanvasController controller = CanvasController();
    controller.setViewport(const Size(800, 600));
    controller.zoomBy(2); // 2× ⇒ 目标 160×120 逻辑像素 = 80×60 世界单位

    insertShape(controller, CanvasShapeKind.rectangle);

    expect(controller.document.items, hasLength(1));
    final CanvasItem item = controller.document.items.single;
    expect(item, isA<ShapeItem>());
    final ShapeItem shape = item as ShapeItem;
    expect(shape.kind, CanvasShapeKind.rectangle);
    expect(
      shape.color,
      kThemeInk,
      reason: '写具体色就烤死在当前明暗档：切到另一档主题后形状隐形',
    );

    // 尺寸：屏幕观感恒定 ⇒ 2× 缩放下世界尺寸减半。
    expect(shape.rect.width, closeTo(80, 0.01));
    expect(shape.rect.height, closeTo(60, 0.01));
    // 落点：**屏幕上**正是视口中心（这才是用户视角的契约；世界坐标随缩放变，
    // 因为 zoomBy 以视口中心为焦点，缩放前后该点下的世界坐标不变）。
    final Offset onScreen = controller.camera.worldToScreen(shape.rect.center);
    expect(onScreen.dx, closeTo(400, 0.01));
    expect(onScreen.dy, closeTo(300, 0.01));

    // 落地即选中 + 切到选择工具（插入后下一步就是调位置/大小）。
    expect(controller.selectedItems.single, same(shape));
    expect(controller.tool, CanvasTool.select);

    // 走的是既有命令栈：撤销就把刚插入的收回去。
    controller.undo();
    expect(controller.document.items, isEmpty);
    controller.dispose();
  });

  test('插入椭圆与矩形是同一条路径（只有 kind 不同）', () {
    final CanvasController controller = CanvasController();
    controller.setViewport(const Size(800, 600));
    insertShape(controller, CanvasShapeKind.ellipse);
    expect(
      (controller.document.items.single as ShapeItem).kind,
      CanvasShapeKind.ellipse,
    );
    controller.dispose();
  });

  test('插入图片：初始框保持像素宽高比（不把图拉变形）', () async {
    final CanvasController controller = CanvasController();
    controller.setViewport(const Size(800, 600));

    final File png = await _writePng(const Size(4, 2)); // 2:1
    addTearDown(() {
      if (png.existsSync()) png.deleteSync();
    });

    final ImageItem item = await insertImageFromPath(controller, png.path);

    expect(item.loaded, isTrue, reason: '插入时先解码一次，首帧就该看到真图');
    expect(
      item.rect.width / item.rect.height,
      closeTo(2, 0.02),
      reason: '初始框没按像素宽高比算：插进来的图是变形的',
    );
    expect(controller.selectedItems.single, same(item));
    expect(controller.document.items, hasLength(1));

    controller.undo();
    expect(controller.document.items, isEmpty);
    controller.dispose();
  });

  test('插入多张图片：按屏幕偏移错开，不会完全重叠', () async {
    final CanvasController controller = CanvasController();
    controller.setViewport(const Size(800, 600));
    final File png = await _writePng(const Size(2, 2));
    addTearDown(() {
      if (png.existsSync()) png.deleteSync();
    });

    final ImageItem first = await insertImageFromPath(controller, png.path);
    final ImageItem second = await insertImageFromPath(
      controller,
      png.path,
      screenOffset: const Offset(24, 24),
    );

    expect(first.rect.center, isNot(second.rect.center));
    expect(second.rect.center.dx, greaterThan(first.rect.center.dx));
    controller.dispose();
  });
}

/// 造一张纯色 PNG（尺寸即断言用的像素宽高比）。
Future<File> _writePng(Size size) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    Offset.zero & size,
    Paint()..color = const Color(0xFFFF0000),
  );
  final ui.Image image = await recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
  final ByteData? data = await image.toByteData(
    format: ui.ImageByteFormat.png,
  );
  image.dispose();
  final File file = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'sinan_insert_${DateTime.now().microsecondsSinceEpoch}.png',
  );
  await file.writeAsBytes(data!.buffer.asUint8List());
  return file;
}
