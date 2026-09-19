import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_edge.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';

/// 连线（v9）的回归。
///
/// 最重要的一组是 **binding**：连线存的是**端点的 id 而不是坐标**，
/// 于是"拖动卡片 → 连线跟随""删除卡片 → 连线消失"都应该是**自动**的，
/// 不需要任何同步代码。这里就是把这两件事钉死。
void main() {
  /// 足够大的视口（不做裁剪，方便直接断言端点坐标）。
  const Rect big = Rect.fromLTWH(-10000, -10000, 20000, 20000);

  CardItem card(String id, {double left = 0}) => CardItem(
    id: id,
    rect: Rect.fromLTWH(left, 0, 100, 60),
    blockId: 'blk-$id',
  );

  CanvasDocument twoCards({double secondLeft = 200}) {
    final CanvasDocument doc = CanvasDocument();
    doc.addItem(card('a'));
    doc.addItem(card('b', left: secondLeft));
    return doc;
  }

  group('CanvasEdge 序列化', () {
    test('往返：端点 / 端口 / props 都不丢', () {
      final CanvasEdge edge = CanvasEdge(
        fromId: 'blk-a',
        toId: 'blk-b',
        fromSide: CanvasSide.right,
        toSide: CanvasSide.left,
        props: <String, dynamic>{'color': 1},
      );
      final CanvasEdge back = CanvasEdge.fromJson(edge.toJson());
      expect(back.id, edge.id);
      expect(back.fromId, 'blk-a');
      expect(back.toId, 'blk-b');
      expect(back.fromSide, CanvasSide.right);
      expect(back.toSide, CanvasSide.left);
      expect(back.props, <String, dynamic>{'color': 1});
    });

    test('缺省字段不写（否则深比较会差一个键）', () {
      final Map<String, dynamic> j = CanvasEdge(fromId: 'blk-a', toId: 'blk-b').toJson();
      expect(j.containsKey('fromSide'), isFalse);
      expect(j.containsKey('toSide'), isFalse);
      expect(j.containsKey('props'), isFalse);
    });

    test('未知名端口 → null（脏存档不该让整张画布打不开）', () {
      final CanvasEdge edge = CanvasEdge.fromJson(<String, dynamic>{
        'id': 'e1',
        'fromId': 'a',
        'toId': 'b',
        'fromSide': 'nonsense',
      });
      expect(edge.fromSide, isNull);
    });
  });

  group('端口解析', () {
    test('自动选：水平相邻 ⇒ right→left；垂直相邻 ⇒ bottom→top', () {
      expect(
        CanvasEdges.autoSides(
          const Rect.fromLTWH(0, 0, 100, 60),
          const Rect.fromLTWH(200, 0, 100, 60),
        ),
        (CanvasSide.right, CanvasSide.left),
      );
      expect(
        CanvasEdges.autoSides(
          const Rect.fromLTWH(0, 0, 100, 60),
          const Rect.fromLTWH(0, 200, 100, 60),
        ),
        (CanvasSide.bottom, CanvasSide.top),
      );
    });

    test('锚点：四个端口各就各位', () {
      const Rect box = Rect.fromLTWH(0, 0, 100, 60);
      expect(CanvasEdges.anchorOf(box, CanvasSide.top), const Offset(50, 0));
      expect(CanvasEdges.anchorOf(box, CanvasSide.right), const Offset(100, 30));
      expect(CanvasEdges.anchorOf(box, CanvasSide.bottom), const Offset(50, 60));
      expect(CanvasEdges.anchorOf(box, CanvasSide.left), const Offset(0, 30));
      expect(CanvasEdges.anchorOf(box, null), const Offset(50, 30));
    });
  });

  group('binding（连线存 id 不存坐标）', () {
    test('端点跟随卡片：拖走卡片，连线**自己**跟着走', () {
      final CanvasDocument doc = twoCards();
      doc.addEdge(CanvasEdge(fromId: 'blk-a', toId: 'blk-b'));

      final EdgeGeometry before = doc.edgesIn(big).single;
      expect(before.from, const Offset(100, 30)); // a 的右边中点
      expect(before.to, const Offset(200, 30)); // b 的左边中点

      // 拖动 b —— **没有任何"同步连线"的代码**，端点应当自己跟着走。
      // 这正是"存 id"换来的：坐标从不落库，绘制时才现算。
      doc.itemById('b')!.rect = const Rect.fromLTWH(400, 0, 100, 60);
      final EdgeGeometry after = doc.edgesIn(big).single;
      expect(after.to, const Offset(400, 30));
      expect(after.from, const Offset(100, 30));
    });

    test('端点卡片被删 ⇒ 悬空边不画（连线不是独立内容）', () {
      final CanvasDocument doc = twoCards();
      doc.addEdge(CanvasEdge(fromId: 'blk-a', toId: 'blk-b'));
      expect(doc.edgesIn(big), hasLength(1));

      doc.removeItems(<CanvasItem>[doc.itemById('b')!]);
      expect(
        doc.edgesIn(big),
        isEmpty,
        reason: '悬空边不该画出来指向虚无',
      );
    });

    test('删卡片连带删连线；一次撤销两者一起回来', () {
      final CanvasDocument doc = twoCards();
      doc.addEdge(CanvasEdge(fromId: 'blk-a', toId: 'blk-b'));
      expect(doc.edges, hasLength(1));

      doc.removeItems(<CanvasItem>[doc.itemById('b')!]);
      expect(doc.edges, isEmpty, reason: '卡片没了，指向它的连线不该留下');

      doc.undo();
      expect(doc.itemById('b'), isNotNull);
      expect(
        doc.edges,
        hasLength(1),
        reason: '分成两条命令就得按两次撤销，中间还会出现"卡片回来了、连线没了"的怪状态',
      );
    });
  });

  group('文档序列化', () {
    test('没有连线 ⇒ 不写 edges 键（旧存档兼容）', () {
      expect(CanvasDocument().toJson().containsKey('edges'), isFalse);
    });

    test('有连线 ⇒ 写，且往返后端点仍能解析', () {
      final CanvasDocument doc = twoCards();
      doc.addEdge(CanvasEdge(fromId: 'blk-a', toId: 'blk-b'));
      final Map<String, dynamic> j = doc.toJson();
      expect(j['edges'], isA<Map<String, dynamic>>());

      final CanvasDocument back = CanvasDocument.fromJson(j);
      expect(back.edges, hasLength(1));
      expect(back.edges.single.fromId, 'blk-a');
      // 端点能解析（两张卡片也一起回来了）⇒ 连线画得出来。
      expect(back.edgesIn(big), hasLength(1));
    });
  });

  group('增删与撤销', () {
    test('单独删连线可撤销（回到原位）', () {
      final CanvasDocument doc = twoCards();
      final CanvasEdge edge = CanvasEdge(fromId: 'blk-a', toId: 'blk-b');
      doc.addEdge(edge);
      doc.removeEdges(<CanvasEdge>[edge]);
      expect(doc.edges, isEmpty);

      doc.undo();
      expect(doc.edges, hasLength(1));
      expect(doc.edges.single.id, edge.id);
    });
  });

  group('路径', () {
    test('贝塞尔路径覆盖两端', () {
      const EdgeGeometry geo = EdgeGeometry(
        from: Offset(0, 0),
        to: Offset(100, 0),
        fromSide: CanvasSide.right,
        toSide: CanvasSide.left,
      );
      final ui.Path path = geo.path();
      final Rect bounds = path.getBounds();
      expect(bounds.left, lessThanOrEqualTo(0));
      expect(bounds.right, greaterThanOrEqualTo(100));
    });
  });

  group('箭头（缺口2）', () {
    test('尖端在终点、两翼朝端口外侧张开', () {
      const EdgeGeometry geo = EdgeGeometry(
        from: Offset(0, 0),
        to: Offset(100, 0),
        fromSide: CanvasSide.right,
        toSide: CanvasSide.left,
      );
      final Rect b = geo.endMarkerPath().getBounds();
      expect(b.right, lessThanOrEqualTo(100.001)); // 尖端不越过 to
      expect(b.left, lessThan(100)); // 两翼在来向一侧张开
      expect(b.width, greaterThan(0));
      expect(b.height, greaterThan(0));
    });

    test('预览（无终点端口）也有箭头', () {
      const EdgeGeometry geo = EdgeGeometry(
        from: Offset(0, 0),
        to: Offset(100, 0),
        fromSide: CanvasSide.right,
      );
      expect(geo.endMarkerPath().getBounds().isEmpty, isFalse);
    });
  });

  group('交互（CanvasController）', () {
    // 默认相机 screen==world，故事件 localPosition 直接用世界坐标即可。
    testWidgets('连线工具：从卡片 A 拖到卡片 B 创建边', (tester) async {
      final CanvasController controller = CanvasController();
      controller.setTool(CanvasTool.connect);
      final CardItem a =
          CardItem(rect: const Rect.fromLTWH(0, 0, 100, 60), blockId: 'blk-a');
      final CardItem b =
          CardItem(rect: const Rect.fromLTWH(200, 0, 100, 60), blockId: 'blk-b');
      controller.document.addItem(a);
      controller.document.addItem(b);

      final TestPointer tp = TestPointer();
      controller.onPointerDown(tp.down(const Offset(50, 30)));
      expect(controller.pendingEdgeGeometry, isNotNull,
          reason: '在卡片 A 上按下应进入连线预览');
      controller.onPointerMove(tp.move(const Offset(250, 30)));
      controller.onPointerUp(tp.up());

      expect(controller.document.edges, hasLength(1));
      expect(controller.document.edges.single.fromId, 'blk-a');
      expect(controller.document.edges.single.toId, 'blk-b');

      // 端点跟随：拖动 B，连线自己跟着走（binding）。
      b.rect = const Rect.fromLTWH(500, 0, 100, 60);
      final EdgeGeometry geo = controller.document.edgesIn(big).single;
      expect(geo.to, const Offset(500, 30));
    });

    testWidgets('连线工具：松手没落在卡片上 ⇒ 不建边', (tester) async {
      final CanvasController controller = CanvasController();
      controller.setTool(CanvasTool.connect);
      final CardItem a =
          CardItem(rect: const Rect.fromLTWH(0, 0, 100, 60), blockId: 'blk-a');
      controller.document.addItem(a);
      final TestPointer tp = TestPointer(2);
      controller.onPointerDown(tp.down(const Offset(50, 30)));
      controller.onPointerMove(tp.move(const Offset(400, 400)));
      controller.onPointerUp(tp.up());
      expect(controller.document.edges, isEmpty);
    });

    testWidgets('点中连线选中并删除', (tester) async {
      final CanvasController controller = CanvasController();
      controller.setTool(CanvasTool.connect);
      final CardItem a =
          CardItem(rect: const Rect.fromLTWH(0, 0, 100, 60), blockId: 'blk-a');
      final CardItem b =
          CardItem(rect: const Rect.fromLTWH(200, 0, 100, 60), blockId: 'blk-b');
      controller.document.addItem(a);
      controller.document.addItem(b);
      controller.document.addEdge(CanvasEdge(fromId: 'blk-a', toId: 'blk-b'));

      // 连线几何 from(100,30)→to(200,30)，中点 (150,30) 在其上。
      final TestPointer tp = TestPointer(3);
      controller.onPointerDown(tp.down(const Offset(150, 30)));
      expect(controller.selectedEdge, isNotNull, reason: '点中连线应选中它');
      controller.deleteSelection();
      expect(controller.document.edges, isEmpty);
    });

    testWidgets('切换工具清空连线预览与选中', (tester) async {
      final CanvasController controller = CanvasController();
      controller.setTool(CanvasTool.connect);
      final CardItem a =
          CardItem(rect: const Rect.fromLTWH(0, 0, 100, 60), blockId: 'blk-a');
      final CardItem b =
          CardItem(rect: const Rect.fromLTWH(200, 0, 100, 60), blockId: 'blk-b');
      controller.document.addItem(a);
      controller.document.addItem(b);
      controller.document.addEdge(CanvasEdge(fromId: 'blk-a', toId: 'blk-b'));

      final TestPointer tp = TestPointer(4);
      controller.onPointerDown(tp.down(const Offset(150, 30)));
      expect(controller.selectedEdge, isNotNull);
      controller.setTool(CanvasTool.select);
      expect(controller.selectedEdge, isNull);
    });

    testWidgets('撤销掉连线后，幽灵选中被清空', (tester) async {
      final CanvasController controller = CanvasController();
      controller.setTool(CanvasTool.connect);
      final CardItem a =
          CardItem(rect: const Rect.fromLTWH(0, 0, 100, 60), blockId: 'blk-a');
      final CardItem b =
          CardItem(rect: const Rect.fromLTWH(200, 0, 100, 60), blockId: 'blk-b');
      controller.document.addItem(a);
      controller.document.addItem(b);
      controller.document.addEdge(CanvasEdge(fromId: 'blk-a', toId: 'blk-b'));

      final TestPointer tp = TestPointer(5);
      controller.onPointerDown(tp.down(const Offset(150, 30)));
      expect(controller.selectedEdge, isNotNull);

      controller.undo();
      expect(controller.document.edges, isEmpty);
      expect(controller.selectedEdge, isNull,
          reason: '边已不在文档，选中态应被清（否则浮层画幽灵高亮）');
    });

    testWidgets('同向重复连线不重复创建', (tester) async {
      final CanvasController controller = CanvasController();
      controller.setTool(CanvasTool.connect);
      final CardItem a =
          CardItem(rect: const Rect.fromLTWH(0, 0, 100, 60), blockId: 'blk-a');
      final CardItem b =
          CardItem(rect: const Rect.fromLTWH(200, 0, 100, 60), blockId: 'blk-b');
      controller.document.addItem(a);
      controller.document.addItem(b);

      // 连续两次同样的 A→B 拖拽：只应留下一条边。
      for (int i = 0; i < 2; i++) {
        final TestPointer tp = TestPointer(10 + i);
        controller.onPointerDown(tp.down(const Offset(50, 30)));
        controller.onPointerMove(tp.move(const Offset(250, 30)));
        controller.onPointerUp(tp.up());
      }
      expect(controller.document.edges, hasLength(1));
    });

    testWidgets('端口手动指定（缺口1）：从左半按下 ⇒ 从左边拉出', (tester) async {
      final CanvasController controller = CanvasController();
      controller.setTool(CanvasTool.connect);
      final CardItem a =
          CardItem(rect: const Rect.fromLTWH(0, 0, 100, 60), blockId: 'blk-a');
      final CardItem b =
          CardItem(rect: const Rect.fromLTWH(200, 0, 100, 60), blockId: 'blk-b');
      controller.document.addItem(a);
      controller.document.addItem(b);

      final TestPointer tp = TestPointer(20);
      // 按在 A 的左半（x=10 < 中心 50）⇒ 起始端口应是 left，而不是自动选 right。
      controller.onPointerDown(tp.down(const Offset(10, 30)));
      controller.onPointerMove(tp.move(const Offset(250, 30)));
      controller.onPointerUp(tp.up());

      expect(controller.document.edges.single.fromSide, CanvasSide.left);
    });

    testWidgets('端点可拖改（缺口4）：把 to 端改接到第三张卡片', (tester) async {
      final CanvasController controller = CanvasController();
      controller.setTool(CanvasTool.connect);
      final CardItem a =
          CardItem(rect: const Rect.fromLTWH(0, 0, 100, 60), blockId: 'blk-a');
      final CardItem b =
          CardItem(rect: const Rect.fromLTWH(200, 0, 100, 60), blockId: 'blk-b');
      final CardItem c =
          CardItem(rect: const Rect.fromLTWH(400, 0, 100, 60), blockId: 'blk-c');
      controller.document.addItem(a);
      controller.document.addItem(b);
      controller.document.addItem(c);
      controller.document.addEdge(CanvasEdge(fromId: 'blk-a', toId: 'blk-b'));

      // 先点中线选中它（按下即抬手，不改端点）。
      final TestPointer p1 = TestPointer(21, ui.PointerDeviceKind.mouse);
      controller.onPointerDown(p1.down(const Offset(150, 30)));
      controller.onPointerUp(p1.up());
      expect(controller.selectedEdge, isNotNull);

      // 抓住 to 端把手（几何 to = b 左边中点 (200,30)），拖到 C。
      final TestPointer p2 = TestPointer(22, ui.PointerDeviceKind.mouse);
      controller.onPointerDown(p2.down(const Offset(200, 30)));
      expect(controller.edgeGripPreview, isNotNull, reason: '抓端点应进入拖改预览');
      controller.onPointerMove(p2.move(const Offset(450, 30)));
      controller.onPointerUp(p2.up());

      expect(controller.document.edges.single.fromId, 'blk-a');
      expect(controller.document.edges.single.toId, 'blk-c');
      // 拖端点是一次可撤销操作。
      controller.undo();
      expect(controller.document.edges.single.toId, 'blk-b');
    });
  });
}
