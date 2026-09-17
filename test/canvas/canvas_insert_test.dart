import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/canvas_insert_panel.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';

/// 插入图片的回归（2026-09-17，画布 P0）。
///
/// 形状已改为**工具**（按住拖拽定尺寸），其回归见 `canvas_shape_tool_test.dart`；
/// 这里只剩图片：初始框必须保持**像素宽高比**（不把图拉变形）、插入时先解码一次。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFF0000));
  final ui.Image image = await recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final File file = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'sinan_insert_${DateTime.now().microsecondsSinceEpoch}.png',
  );
  await file.writeAsBytes(data!.buffer.asUint8List());
  return file;
}
