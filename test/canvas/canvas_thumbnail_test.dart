import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/canvas_thumbnail.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';

/// 主页画布卡片缩略图快照（[parseCanvasThumbnail]）的回归。
///
/// 关键口径：只要 item 层、不碰笔迹、坏元素不崩卡、z 序保留。
void main() {
  /// 用内核权威序列化造一张画布 JSON（避免手写格式漂移）。
  String canvasJsonWith(List<CanvasItem> items) {
    final CanvasController controller = CanvasController();
    addTearDown(controller.dispose);
    for (final CanvasItem item in items) {
      controller.document.addItem(item);
    }
    return jsonEncode(controller.toJson());
  }

  ShapeItem shape(String id, Rect rect) => ShapeItem(
    id: id,
    rect: rect,
    kind: CanvasShapeKind.rectangle,
    color: const Color(0xFF1F1F1F),
  );

  group('parseCanvasThumbnail', () {
    test('有 item：按 z 序解析，bounds 是全部 item 的并集', () {
      final String json = canvasJsonWith(<CanvasItem>[
        shape('s1', const Rect.fromLTRB(0, 0, 10, 10)),
        shape('s2', const Rect.fromLTRB(20, 20, 30, 40)),
      ]);

      final CanvasThumbnail? thumb = parseCanvasThumbnail(json);

      expect(thumb, isNotNull);
      expect(thumb!.items, hasLength(2));
      // itemOrder 即添加序（z 序），快照必须保持，painter 才能画对层次。
      expect(thumb.items[0].id, 's1');
      expect(thumb.items[1].id, 's2');
      expect(thumb.bounds, const Rect.fromLTRB(0, 0, 30, 40));
      thumb.dispose();
    });

    test('只解析 item 层：有大量笔迹也不进快照、不报错', () {
      final CanvasController controller = CanvasController();
      addTearDown(controller.dispose);
      controller.document.addItem(
        shape('s1', const Rect.fromLTRB(0, 0, 10, 10)),
      );
      final String json = jsonEncode(controller.toJson());

      final CanvasThumbnail? thumb = parseCanvasThumbnail(json);

      expect(thumb, isNotNull);
      expect(thumb!.items.single.id, 's1');
      thumb.dispose();
    });

    test('空串 / 非法 JSON / 非画布格式 / 空画布 ⇒ 一律 null（落占位，不抛）', () {
      expect(parseCanvasThumbnail(''), isNull);
      expect(parseCanvasThumbnail('   '), isNull);
      expect(parseCanvasThumbnail('{not json'), isNull);
      expect(parseCanvasThumbnail(jsonEncode(<String, Object?>{})), isNull);
      expect(
        parseCanvasThumbnail(
          jsonEncode(<String, Object?>{
            'camera': <String, Object?>{},
            'document': <String, Object?>{'items': <String, Object?>{}},
          }),
        ),
        isNull,
      );
    });

    test('单个坏 item 只跳过本人，其余 item 与 bounds 照常保留', () {
      final String good = canvasJsonWith(<CanvasItem>[
        shape('s1', const Rect.fromLTRB(0, 0, 10, 10)),
      ]);
      final Map<String, dynamic> decoded =
          jsonDecode(good) as Map<String, dynamic>;
      final Map<String, dynamic> document = (decoded['document'] as Map)
          .cast<String, dynamic>();
      final Map<String, dynamic> items = (document['items'] as Map)
          .cast<String, dynamic>();
      final List<Object?> order = document['itemOrder'] as List<Object?>;
      // 塞一个类型未知的坏元素到 z 序最前。
      items['bad'] = <String, Object?>{'type': 'nope'};
      order.insert(0, 'bad');

      final CanvasThumbnail? thumb = parseCanvasThumbnail(jsonEncode(decoded));

      expect(thumb, isNotNull);
      expect(thumb!.items.single.id, 's1');
      expect(thumb.bounds, const Rect.fromLTRB(0, 0, 10, 10));
      thumb.dispose();
    });
  });
}
