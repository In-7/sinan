import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/kernel/canvas_ai.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/canvas_raster.dart';

/// 记录收到的输入图，并回答一个"无图无路径"的结果（测试只关心输入）。
class _RecordingGenerator implements AiGenerator {
  Map<String, Uint8List>? seen;

  @override
  Future<GeneratedResult> generate(
    GenRecipe recipe, {
    required Region region,
    Map<String, Uint8List>? inputImages,
  }) async {
    seen = inputImages;
    return const GeneratedResult();
  }
}

Future<ui.Image> _decode(Uint8List bytes) {
  final Completer<ui.Image> completer = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, completer.complete);
  return completer.future;
}

ShapeItem _filledRect(Rect rect, {Color color = const Color(0xFFCC0000)}) =>
    ShapeItem(
      rect: rect,
      kind: CanvasShapeKind.rectangle,
      color: color,
      filled: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('小选区不被相机 scale 钳制：内容铺满画布（回归 fit() clamp 坑）', () async {
    // 4×4 世界单位的小选区，在 1024 像素下需要 256 倍放大——远超
    // CanvasCamera 默认 maxScale(4)。若误用 `fit()` 会被钳到 4，
    // 内容缩成画布中央一小块、四周全是背景。
    final CanvasDocument doc = CanvasDocument();
    const Rect world = Rect.fromLTWH(0, 0, 4, 4);
    doc.addItem(_filledRect(world));

    final Uint8List png = await rasterizeRegion(doc, world);
    final ui.Image img = await _decode(png);
    expect(img.width, 1024);
    expect(img.height, 1024);

    final ByteData raw =
        (await img.toByteData())!;
    // 左上角 (2,2) 必须仍是形状色；被钳制时这里会是背景白。
    final int offset = (2 * img.width + 2) * 4;
    expect(raw.getUint8(offset), 0xCC); // R
    expect(raw.getUint8(offset + 1), 0x00); // G
    expect(raw.getUint8(offset + 2), 0x00); // B
    img.dispose();
  });

  test('像素尺寸保持长宽比，最长边等于 maxPixels', () async {
    final CanvasDocument doc = CanvasDocument();
    const Rect world = Rect.fromLTWH(0, 0, 100, 50);
    doc.addItem(_filledRect(world));

    final ui.Image img = await _decode(
      await rasterizeRegion(doc, world, maxPixels: 256),
    );
    expect(img.width, 256);
    expect(img.height, 128);
    img.dispose();
  });

  test('空矩形抛 ArgumentError', () async {
    await expectLater(
      rasterizeRegion(CanvasDocument(), Rect.zero),
      throwsArgumentError,
    );
  });

  test('generateFromRegion：有内容时栅格化为 image 输入，空选区不带输入', () async {
    final _RecordingGenerator generator = _RecordingGenerator();
    final CanvasController controller = CanvasController(generator: generator);
    final ShapeItem shape = _filledRect(
      const Rect.fromLTWH(0, 0, 40, 30),
      color: const Color(0xFF112233),
    );
    controller.document.addItem(shape);

    // ① 选区盖住形状 ⇒ 应产出 image 输入，且是 PNG（魔数校验）。
    await controller.generateFromRegion(Region(id: 'r1', bbox: shape.rect));
    expect(generator.seen, isNotNull);
    final Uint8List? image = generator.seen!['image'];
    expect(image, isNotNull);
    expect(image!.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);

    // ② 选区落在空白处 ⇒ 纯 txt2img，不带输入图。
    await controller.generateFromRegion(
      Region(id: 'r2', bbox: const Rect.fromLTWH(5000, 5000, 5100, 5100)),
    );
    expect(generator.seen, isEmpty);

    controller.dispose();
  });
}
