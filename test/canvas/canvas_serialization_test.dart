import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';

void main() {
  test('InkStroke 序列化往返：id/样式/轮廓一致', () {
    final InkStroke stroke = InkStroke(
      color: const Color(0xFF123456),
      baseWidth: 3,
      simulatePressure: false,
    )
      ..add(const InkPoint(Offset(0, 0), 0.5))
      ..add(const InkPoint(Offset(10, 10), 0.8));

    final InkStroke restored = InkStroke.fromJson(stroke.toJson());

    expect(restored.id, stroke.id);
    expect(restored.color, stroke.color);
    expect(restored.baseWidth, stroke.baseWidth);
    expect(restored.points.length, stroke.points.length);
    final Rect a = restored.outline.getBounds();
    final Rect b = stroke.outline.getBounds();
    expect(a.left, b.left);
    expect(a.top, b.top);
    expect(a.right, b.right);
    expect(a.bottom, b.bottom);
  });

  test('CanvasDocument 序列化往返：含 shape + image', () {
    final CanvasDocument doc = CanvasDocument();
    doc.addStroke(InkStroke(color: const Color(0xFF000000), baseWidth: 2)
      ..add(const InkPoint(Offset(1, 1), 0.5)));
    doc.addItem(ShapeItem(
      rect: const Rect.fromLTWH(0, 0, 10, 20),
      kind: CanvasShapeKind.ellipse,
      color: const Color(0xFF00FF00),
      filled: true,
    ));
    doc.addItem(ImageItem(
      rect: const Rect.fromLTWH(5, 5, 30, 40),
      src: '/tmp/x.png',
    ));

    final CanvasDocument restored =
        CanvasDocument.fromJson(doc.toJson());

    expect(restored.strokes.length, 1);
    expect(restored.items.length, 2);
    expect(restored.items[0], isA<ShapeItem>());
    expect(restored.items[1], isA<ImageItem>());

    final ShapeItem shape = restored.items[0] as ShapeItem;
    expect(shape.kind, CanvasShapeKind.ellipse);
    expect(shape.filled, isTrue);
    expect(shape.rect.left, 0.0);

    final ImageItem img = restored.items[1] as ImageItem;
    expect(img.src, '/tmp/x.png');
    // 运行时资源不随 JSON 恢复：落盘只存路径，图片需懒加载。
    expect(img.loaded, isFalse);
  });

  test('CanvasController 序列化往返：相机还原', () {
    final CanvasController controller = CanvasController();
    controller.zoomBy(2);
    controller.document.addStroke(
      InkStroke(color: const Color(0xFF000000), baseWidth: 2)
        ..add(const InkPoint(Offset(1, 1), 0.5)),
    );

    final CanvasController restored =
        CanvasController.fromJson(controller.toJson());

    expect(restored.camera.scale, controller.camera.scale);
    expect(restored.document.strokes.length, 1);
  });

  test('ImageItem 未加载时绘制占位框、命中仍可用、dispose 不抛', () {
    final ImageItem img = ImageItem(
      rect: const Rect.fromLTWH(0, 0, 10, 10),
      src: '/no/such/file.png',
    );
    expect(img.hitTest(const Offset(5, 5), 0), isTrue);
    expect(img.loaded, isFalse);
    // 加载失败应静默（占位框保留），不抛异常。
    unawaited(img.load(onLoaded: () {}));
    img.dispose();
  });
}
