import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';

InkStroke _stroke() => InkStroke(
      color: const Color(0xFF000000),
      baseWidth: 4,
      points: const <InkPoint>[
        InkPoint(Offset(0, 0), 0),
        InkPoint(Offset(10, 10), 0),
      ],
    );

ShapeItem _shape() => ShapeItem(
      rect: const Rect.fromLTWH(0, 0, 20, 20),
      kind: CanvasShapeKind.rectangle,
      color: const Color(0xFF000000),
    );

Future<ui.Image> _solidImage() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 4, 4),
    ui.Paint()..color = const Color(0xFF00FF00),
  );
  return recorder.endRecording().toImage(4, 4);
}

/// 撤销命令**按 id 寻址**（命令里不持实例）的回归。
///
/// 钉子：① undo/redo 必须拿回**同一个对象**（笔迹不重算 perfect_freehand 轮廓、
/// 图片不丢已解码的 `ui.Image`）；② z 序按原位插回；③ 暂存记录不能无界增长。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('按 id 寻址：还原的是同一实例', () {
    test('笔迹 add → undo → redo 拿回同一实例', () {
      final CanvasDocument document = CanvasDocument();
      final InkStroke stroke = _stroke();
      document.addStroke(stroke);

      document.undo();
      expect(document.strokes, isEmpty);
      document.redo();
      expect(document.strokes.single, same(stroke));
    });

    test('笔迹 eraseAt → undo 拿回同一实例', () {
      final CanvasDocument document = CanvasDocument()
        ..addStroke(_stroke());
      final InkStroke original = document.strokes.single;

      expect(document.eraseAt(const Offset(0, 0), 12), hasLength(1));
      expect(document.strokes, isEmpty);
      document.undo();
      expect(document.strokes.single, same(original));
    });

    test('item 删除 → 撤销：同一实例，且已解码的图不丢（不重新解码）', () async {
      final CanvasDocument document = CanvasDocument();
      final ImageItem item = ImageItem(rect: const Rect.fromLTWH(0, 0, 10, 10));
      document.addItem(item);
      final ui.Image image = await _solidImage();
      item.setImage(image);
      expect(item.loaded, isTrue);

      document.removeItems(<CanvasItem>[item]);
      expect(document.items, isEmpty);
      document.undo();

      expect(document.items.single, same(item));
      expect(
        (document.items.single as ImageItem).loaded,
        isTrue,
        reason: '重建对象会让图消失并需要重新解码，这正是按 id 还原要避免的',
      );
      image.dispose();
    });
  });

  group('z 序与返回顺序保持旧行为', () {
    test('删除中间的 item 再撤销：插回原位而不是叠到最上', () {
      final CanvasDocument document = CanvasDocument();
      final ShapeItem a = _shape();
      final ShapeItem b = _shape();
      final ShapeItem c = _shape();
      document
        ..addItem(a)
        ..addItem(b)
        ..addItem(c);

      document.removeItems(<CanvasItem>[b]);
      expect(
        document.items.map((CanvasItem i) => i.id).toList(),
        <String>[a.id, c.id],
      );

      document.undo();
      expect(
        document.items.map((CanvasItem i) => i.id).toList(),
        <String>[a.id, b.id, c.id],
      );
    });

    test('removeStrokes 返回顺序仍是 z 序升序', () {
      final CanvasDocument document = CanvasDocument();
      final InkStroke s1 = _stroke();
      final InkStroke s2 = _stroke();
      final InkStroke s3 = _stroke();
      document
        ..addStroke(s1)
        ..addStroke(s2)
        ..addStroke(s3);

      final List<InkStroke> removed =
          document.removeStrokes(<InkStroke>[s1, s3]);
      expect(removed.map((InkStroke s) => s.id).toList(),
          <String>[s1.id, s3.id]);
      expect(document.strokes.single, same(s2));
    });
  });

  group('暂存记录的生命周期', () {
    test('移出在场 ⇒ 暂存；撤销放回 ⇒ 清空；重做再移出 ⇒ 又暂存', () {
      final CanvasDocument document = CanvasDocument()
        ..addStroke(_stroke());
      expect(document.detachedCount, 0);

      document.removeStrokes(document.strokes);
      expect(document.detachedCount, 1, reason: '撤销栈里那条命令还要还原它');

      document.undo();
      expect(document.detachedCount, 0, reason: '已放回在场');

      document.redo();
      expect(document.detachedCount, 1, reason: '重做栈里那条命令仍要还原它');
    });

    test('永久离场的记录会被回收，不无界增长', () {
      final CanvasDocument document = CanvasDocument()
        ..addStroke(_stroke());

      document.undo(); // 笔迹移出在场，进入暂存
      expect(document.detachedCount, 1);

      // 新操作作废重做栈 ⇒ 那条"添加"再也回不来 ⇒ 暂存记录应当被回收。
      document.addStroke(_stroke());
      expect(document.canRedo, isFalse);
      expect(document.detachedCount, 0);
    });

    test('一条删除命令的暂存随它被撤销而清空', () {
      final CanvasDocument document = CanvasDocument();
      for (int i = 0; i < 5; i++) {
        document.addStroke(_stroke());
      }
      document.removeStrokes(document.strokes);
      expect(document.detachedCount, 5, reason: '撤销这条删除要还原 5 条');

      document.undo();
      expect(document.detachedCount, 0);
      expect(document.strokes, hasLength(5));
    });

    test('被作废的命令会交还它暂存的记录（不随会话累积）', () {
      final CanvasDocument document = CanvasDocument();
      for (int i = 0; i < 5; i++) {
        final InkStroke stroke = _stroke();
        document.addStroke(stroke);
        document.undo(); // 记录进暂存，命令进重做栈
        // 每轮只应有**当前**这一条：上一轮的命令被新操作作废后即交还记录。
        expect(document.detachedCount, 1);
      }
      // 再来一个新操作作废重做栈 ⇒ 最后一条也应被回收。
      document.addStroke(_stroke());
      expect(document.detachedCount, 0);
    });
  });
}
