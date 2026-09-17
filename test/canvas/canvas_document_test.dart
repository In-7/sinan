import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';

InkStroke _stroke(List<Offset> worldPoints) => InkStroke(
      color: const Color(0xFF000000),
      baseWidth: 4,
      points: <InkPoint>[
        for (final Offset p in worldPoints) InkPoint(p, 0),
      ],
    );

void main() {
  test('add → undo → redo 还原笔迹', () {
    final CanvasDocument document = CanvasDocument();
    final InkStroke stroke = _stroke(const <Offset>[Offset(0, 0), Offset(10, 10)]);
    document.addStroke(stroke);

    expect(document.strokes, hasLength(1));
    expect(document.canUndo, isTrue);

    document.undo();
    expect(document.strokes, isEmpty);
    expect(document.canRedo, isTrue);

    document.redo();
    expect(document.strokes, hasLength(1));
    expect(document.strokes.single, same(stroke));
  });

  test('strokesIn：只返回与视口相交的笔迹', () {
    final CanvasDocument document = CanvasDocument()
      ..addStroke(_stroke(const <Offset>[Offset(0, 0), Offset(20, 0)]))
      ..addStroke(_stroke(const <Offset>[Offset(500, 500), Offset(520, 500)]));

    final List<InkStroke> visible = document.strokesIn(
      const Rect.fromLTWH(-10, -10, 100, 100),
    );
    expect(visible, hasLength(1));
    expect(document.strokes, hasLength(2));
  });

  test('eraseAt：命中即整条删除，且可撤销回原位', () {
    final CanvasDocument document = CanvasDocument()
      ..addStroke(_stroke(const <Offset>[Offset(0, 0), Offset(30, 0)]))
      ..addStroke(_stroke(const <Offset>[Offset(100, 100), Offset(130, 100)]));

    final List<InkStroke> erased =
        document.eraseAt(const Offset(15, 1), 6);
    expect(erased, hasLength(1));
    expect(document.strokes, hasLength(1));
    // 剩下的是远处那条。
    expect(document.strokes.single.points.first.position, const Offset(100, 100));

    document.undo();
    expect(document.strokes, hasLength(2));
  });

  test('eraseAt：没命中就不产生撤销记录', () {
    final CanvasDocument document = CanvasDocument()
      ..addStroke(_stroke(const <Offset>[Offset(0, 0), Offset(10, 0)]));

    final int undoDepthBefore = document.canUndo ? 1 : 0;
    final List<InkStroke> erased =
        document.eraseAt(const Offset(500, 500), 6);
    expect(erased, isEmpty);
    expect(document.canUndo ? 1 : 0, undoDepthBefore);
  });

  test('bounds：所有笔迹的并集（空文档为 null）', () {
    final CanvasDocument empty = CanvasDocument();
    expect(empty.bounds, isNull);

    final CanvasDocument document = CanvasDocument()
      ..addStroke(_stroke(const <Offset>[Offset(0, 0), Offset(10, 0)]))
      ..addStroke(_stroke(const <Offset>[Offset(50, 40), Offset(60, 40)]));
    final Rect? bounds = document.bounds;
    expect(bounds, isNotNull);
    // 笔宽 4 ⇒ 上下各外扩 2。
    expect(bounds!.left, closeTo(-2, 1e-9));
    expect(bounds.right, closeTo(62, 1e-9));
    expect(bounds.top, closeTo(-2, 1e-9));
    expect(bounds.bottom, closeTo(42, 1e-9));
  });

  test('InkStroke.add：小于抽稀阈值的点被丢弃', () {
    final InkStroke stroke = InkStroke(
      color: const Color(0xFF000000),
      baseWidth: 4,
      points: const <InkPoint>[InkPoint(Offset(0, 0), 0)],
    );
    final bool added = stroke.add(const InkPoint(Offset(0.2, 0.1), 0));
    expect(added, isFalse);
    expect(stroke.points, hasLength(1));

    expect(stroke.add(const InkPoint(Offset(5, 5), 0)), isTrue);
    expect(stroke.points, hasLength(2));
  });
}
