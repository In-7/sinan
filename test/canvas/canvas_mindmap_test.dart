import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/canvas_insert_panel.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/canvas_mindmap.dart';

void main() {
  group('布局（独立 tidy-tree）', () {
    test('层级向右递增、兄弟不重叠、父居中于孩子', () {
      final MindNode root = MindNode(
        text: '根',
        children: <MindNode>[
          MindNode(text: 'a'),
          MindNode(text: 'b'),
          MindNode(text: 'c'),
        ],
      );
      final MindMapLayout l = layoutMindMap(root);
      final Offset r = l.positions[root.id]!;
      final Offset a = l.positions[root.children[0].id]!;
      final Offset b = l.positions[root.children[1].id]!;
      final Offset c = l.positions[root.children[2].id]!;

      // 层级 = x 递增。
      expect(a.dx, greaterThan(r.dx));
      // 三个兄弟垂直依次排开、不重叠。
      expect(a.dy, lessThan(b.dy));
      expect(b.dy, lessThan(c.dy));
      expect(b.dy - a.dy, greaterThanOrEqualTo(MindMapMetrics.nodeHeight));
      // 父节点垂直中心 = 首尾孩子的中点。
      final double childCenter =
          (a.dy + c.dy) / 2 + MindMapMetrics.nodeHeight / 2;
      expect(
        r.dy + MindMapMetrics.nodeHeight / 2,
        closeTo(childCenter, 0.001),
      );
    });

    test('尺寸覆盖全部节点 + 留白', () {
      final MindNode root = MindNode(
        text: '根',
        children: <MindNode>[MindNode(text: 'x')],
      );
      final MindMapLayout l = layoutMindMap(root);
      double maxRight = 0;
      double maxBottom = 0;
      for (final Offset o in l.positions.values) {
        final double right = o.dx + MindMapMetrics.nodeWidth;
        final double bottom = o.dy + MindMapMetrics.nodeHeight;
        if (right > maxRight) maxRight = right;
        if (bottom > maxBottom) maxBottom = bottom;
      }
      expect(l.size.width, greaterThan(maxRight));
      expect(l.size.height, greaterThan(maxBottom));
    });

    test('单节点也有合理尺寸', () {
      final MindMapLayout l = layoutMindMap(MindNode(text: '仅根'));
      expect(l.size.width, greaterThan(MindMapMetrics.nodeWidth));
      expect(l.size.height, greaterThan(MindMapMetrics.nodeHeight));
    });
  });

  group('序列化', () {
    test('节点树往返不丢结构', () {
      final MindNode root = MindNode(
        text: '根',
        children: <MindNode>[
          MindNode(text: 'a', children: <MindNode>[MindNode(text: 'a1')]),
          MindNode(text: 'b'),
        ],
      );
      final MindNode back = MindNode.fromJson(
        Map<String, dynamic>.from(root.toJson()),
      );
      expect(back.id, root.id);
      expect(back.text, '根');
      expect(back.children.length, 2);
      expect(back.children[0].children.single.text, 'a1');
    });

    test('MindMapItem 往返：rect 与树都在（走 CanvasItem.fromJson 分发）', () {
      final MindMapItem item =
          newMindMapItem(rect: const Rect.fromLTWH(10, 20, 300, 200));
      final Map<String, dynamic> j = item.toJson();
      expect(j['type'], 'mindmap');

      final CanvasItem back = CanvasItem.fromJson(j);
      expect(back, isA<MindMapItem>());
      final MindMapItem map = back as MindMapItem;
      expect(map.rect, item.rect);
      expect(map.root.text, '中心主题');
      expect(map.root.children.length, 2);
    });

    test('载入后推进节点 id 发生器 ⇒ 新建节点不撞 id', () {
      final MindMapItem item =
          newMindMapItem(rect: const Rect.fromLTWH(0, 0, 300, 200));
      final List<String> ids = <String>[];
      item.root.collectIds(ids);
      advanceMindNodeIdSequence(ids);

      final MindNode fresh = MindNode(text: '新');
      expect(ids.contains(fresh.id), isFalse, reason: '新节点 id 不能与存档里的重复');
    });
  });

  group('CanvasItem 行为', () {
    test('命中：rect 内命中、外不命中', () {
      final MindMapItem item =
          newMindMapItem(rect: const Rect.fromLTWH(0, 0, 300, 200));
      expect(item.hitTest(const Offset(150, 100), 0), isTrue);
      expect(item.hitTest(const Offset(500, 500), 0), isFalse);
    });

    test('加分支后布局缓存失效 ⇒ 尺寸变大', () {
      final MindMapItem item =
          newMindMapItem(rect: const Rect.fromLTWH(0, 0, 300, 200));
      final Size before = item.layout.size;
      item.root.children.add(MindNode(text: '分支三'));
      item.invalidateLayout();
      expect(item.layout.size.height, greaterThan(before.height));
    });

    test('paint 不崩（离屏绘制，含缩放居中）', () {
      final MindMapItem item =
          newMindMapItem(rect: const Rect.fromLTWH(0, 0, 300, 200));
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(recorder);
      item.paint(canvas, ink: const Color(0xFF000000));
      recorder.endRecording().dispose();
    });

    test('极小 rect 也不崩（缩放比不为正时直接跳过）', () {
      final MindMapItem item =
          newMindMapItem(rect: const Rect.fromLTWH(0, 0, 0, 0));
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(recorder);
      item.paint(canvas, ink: const Color(0xFF000000));
      recorder.endRecording().dispose();
    });
  });

  group('插入（CanvasController）', () {
    testWidgets('插入思维导图 ⇒ 落进文档并选中', (tester) async {
      final CanvasController controller = CanvasController();
      final MindMapItem item = insertMindMap(controller);
      expect(controller.document.items, contains(item));
      expect(controller.selectedItems, contains(item));
      expect(item.rect.width, greaterThan(0));
      expect(item.rect.height, greaterThan(0));
    });
  });
}
