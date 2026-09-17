import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';

ShapeItem _rect({Rect rect = const Rect.fromLTRB(0, 0, 40, 40), bool filled = false}) =>
    ShapeItem(
      rect: rect,
      kind: CanvasShapeKind.rectangle,
      color: const Color(0xFF1565C0),
      filled: filled,
    );

void main() {
  group('ShapeItem.hitTest', () {
    test('空心矩形：边上命中、中心不命中、盒外不命中', () {
      final ShapeItem item = _rect();
      expect(item.hitTest(const Offset(0, 20), 3), isTrue); // 左边
      expect(item.hitTest(const Offset(20, 40), 3), isTrue); // 下边
      expect(item.hitTest(const Offset(20, 20), 3), isFalse); // 中心（空心）
      expect(item.hitTest(const Offset(100, 20), 3), isFalse); // 盒外
    });

    test('填充矩形：中心也命中', () {
      final ShapeItem item = _rect(filled: true);
      expect(item.hitTest(const Offset(20, 20), 3), isTrue);
    });

    test('空心椭圆：边带命中、中心不命中；填充则中心命中', () {
      final ShapeItem hollow = ShapeItem(
        rect: const Rect.fromLTRB(-40, -30, 40, 30),
        kind: CanvasShapeKind.ellipse,
        color: const Color(0xFF1565C0),
      );
      expect(hollow.hitTest(const Offset(40, 0), 2), isTrue); // 右顶点
      expect(hollow.hitTest(const Offset(0, 0), 2), isFalse); // 中心
      final ShapeItem filled = ShapeItem(
        rect: const Rect.fromLTRB(-40, -30, 40, 30),
        kind: CanvasShapeKind.ellipse,
        color: const Color(0xFF1565C0),
        filled: true,
      );
      expect(filled.hitTest(const Offset(0, 0), 2), isTrue);
    });
  });

  group('CanvasHandles', () {
    test('hitTest：屏幕坐标四角命中，远处为 null', () {
      final List<Offset> corners = CanvasHandles.corners(
        const Rect.fromLTRB(0, 0, 40, 40),
      );
      expect(CanvasHandles.hitTest(corners, const Offset(2, 2)),
          CanvasHandle.topLeft);
      expect(CanvasHandles.hitTest(corners, const Offset(38, 42)),
          CanvasHandle.bottomRight);
      expect(CanvasHandles.hitTest(corners, const Offset(20, 20)), isNull);
    });

    test('resize：拖 bottomRight，对角 topLeft 锚定', () {
      final Rect result = CanvasHandles.resize(
        const Rect.fromLTRB(0, 0, 40, 40),
        CanvasHandle.bottomRight,
        const Offset(60, 55),
      );
      expect(result, const Rect.fromLTRB(0, 0, 60, 55));
    });

    test('resize：拖 topLeft，对角 bottomRight 锚定', () {
      final Rect result = CanvasHandles.resize(
        const Rect.fromLTRB(0, 0, 40, 40),
        CanvasHandle.topLeft,
        const Offset(-10, -5),
      );
      expect(result, const Rect.fromLTRB(-10, -5, 40, 40));
    });

    test('resize：minSize 下限，矩形不允许翻面', () {
      final Rect result = CanvasHandles.resize(
        const Rect.fromLTRB(0, 0, 40, 40),
        CanvasHandle.bottomRight,
        const Offset(3, 3),
      );
      expect(result, const Rect.fromLTRB(0, 0, CanvasHandles.minSize, CanvasHandles.minSize));
    });
  });

  group('CanvasDocument items', () {
    test('addItem / bounds / itemsIn / undo / redo', () {
      final CanvasDocument document = CanvasDocument();
      final ShapeItem item = _rect();
      document.addItem(item);

      expect(document.items, hasLength(1));
      expect(document.bounds, item.bounds);
      expect(document.itemsIn(const Rect.fromLTWH(-5, -5, 30, 30)), hasLength(1));
      expect(document.itemsIn(const Rect.fromLTWH(500, 500, 30, 30)), isEmpty);

      document.undo();
      expect(document.items, isEmpty);
      document.redo();
      expect(document.items, hasLength(1));
    });

    test('hitItemAt：重叠时最上层（后加的）优先', () {
      final CanvasDocument document = CanvasDocument()
        ..addItem(_rect())
        ..addItem(_rect()); // 完全重叠
      // 空心矩形只有边带命中：取左边缘上的点。
      expect(document.hitItemAt(const Offset(0, 20), 3),
          same(document.items.last));
      expect(document.hitItemAt(const Offset(500, 500), 3), isNull);
    });

    test('removeItems：撤销恢复 z 序原位', () {
      final CanvasDocument document = CanvasDocument();
      final ShapeItem bottom = _rect(rect: const Rect.fromLTRB(0, 0, 10, 10));
      final ShapeItem middle = _rect(rect: const Rect.fromLTRB(20, 0, 30, 10));
      final ShapeItem top = _rect(rect: const Rect.fromLTRB(40, 0, 50, 10));
      document
        ..addItem(bottom)
        ..addItem(middle)
        ..addItem(top);

      document.removeItems(<CanvasItem>[middle]);
      expect(document.items, <CanvasItem>[bottom, top]);

      document.undo();
      expect(document.items, <CanvasItem>[bottom, middle, top]);

      document.redo();
      expect(document.items, <CanvasItem>[bottom, top]);
    });

    test('setItemRects：拖动落账可撤销/重做；未变化的拖拽不产生命令', () {
      final CanvasDocument document = CanvasDocument();
      final ShapeItem item = _rect();
      document.addItem(item);
      final int revisionBefore = document.revision;
      final Rect original = item.rect;

      // 模拟一次拖动（rect 就地改 + 落账）。
      item.rect = original.shift(const Offset(10, 5));
      document.setItemTransforms(<(CanvasItem, Rect, double)>[
        (item, original, 0),
      ]);
      expect(item.rect, original.shift(const Offset(10, 5)));
      expect(document.revision, revisionBefore + 1);

      document.undo();
      expect(item.rect, original);

      document.redo();
      expect(item.rect, original.shift(const Offset(10, 5)));

      // 没真的动（rect/angle 未变）：不产生命令。
      final int revisionBeforeNoop = document.revision;
      document.setItemTransforms(<(CanvasItem, Rect, double)>[
        (item, item.rect, item.angle),
      ]);
      expect(document.revision, revisionBeforeNoop);
      expect(document.canUndo, isTrue); // 之前的命令还在
    });

    test('bounds 覆盖笔迹与 item 的并集', () {
      final CanvasDocument document = CanvasDocument()
        ..addItem(_rect(rect: const Rect.fromLTRB(0, 0, 10, 10)))
        ..addStroke(InkStroke(
          color: const Color(0xFF000000),
          baseWidth: 4,
          points: <InkPoint>[
            const InkPoint(Offset(100, 100), 0),
            const InkPoint(Offset(120, 100), 0),
          ],
        ));
      expect(document.bounds, const Rect.fromLTRB(0, 0, 122, 102));
    });
  });
}
