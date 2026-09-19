import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/kernel/canvas_ai.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/canvas_painters.dart';

/// 重绘判定（`shouldRepaint`）的回归。
///
/// ## 背景：这里是**真 bug**
/// 相机、item 几何、进行中的笔迹全部是**就地修改**的；两个 painter 拿到的是
/// **同一批对象**，所以 `oldDelegate.camera.scale != camera.scale`、
/// `oldDelegate.items[i].rect != items[i].rect` 这类比较等于"和自己比"，
/// 恒为 false ⇒ 平移/拖拽/湿墨都不触发重绘。
///
/// 修法是控制器侧的 `repaintStamp`（每次通知 +1）。本文件既钉住它有效，
/// 也钉住"去掉它就会坏"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('反面钉子：不传 stamp 时，就地改几何/相机都判不出重绘（同一批对象）', () {
    final CanvasController controller = CanvasController();
    final ShapeItem shape = ShapeItem(
      rect: const Rect.fromLTWH(0, 0, 20, 20),
      kind: CanvasShapeKind.rectangle,
      color: const Color(0xFF000000),
    );
    controller.document.addItem(shape);
    final ItemPainter before = ItemPainter(
      camera: controller.camera,
      items: controller.document.items,
    );

    shape.rect = const Rect.fromLTWH(400, 400, 20, 20); // 就地改几何
    controller.camera.panBy(const Offset(3, 4)); // 就地平移

    final ItemPainter after = ItemPainter(
      camera: controller.camera,
      items: controller.document.items,
    );
    expect(
      after.shouldRepaint(before),
      isFalse,
      reason: '这正是必须引入 repaintStamp 的原因（字段比较恒等）',
    );
  });

  test('相机平移：网格层靠相机版本号快照判定重绘', () {
    final CanvasController controller = CanvasController();
    GridPainter grid() => GridPainter(
          camera: controller.camera,
          color: const Color(0xFF000000),
          stamp: controller.camera.revision,
        );
    final GridPainter before = grid();
    controller.onPointerSignal(
      const PointerScrollEvent(
        position: Offset(400, 300),
        scrollDelta: Offset(0, 40),
      ),
    );
    expect(grid().shouldRepaint(before), isTrue);
  });

  test('写字期间网格层**不**重绘（重层隔离，每帧上千个圆不能白画）', () {
    final CanvasController controller = CanvasController();
    controller.setViewport(const Size(800, 600));
    // 2026-09-18：默认工具改为"选择" ⇒ 笔迹相关用例须显式进入画笔工具。
    controller.setTool(CanvasTool.pen);
    GridPainter grid() => GridPainter(
          camera: controller.camera,
          color: const Color(0xFF000000),
          stamp: controller.camera.revision,
        );
    final GridPainter before = grid();

    controller
      ..onPointerDown(
        const PointerDownEvent(
          pointer: 1,
          kind: PointerDeviceKind.stylus,
          position: Offset(10, 10),
        ),
      )
      ..onPointerMove(
        const PointerMoveEvent(
          pointer: 1,
          kind: PointerDeviceKind.stylus,
          position: Offset(120, 90),
        ),
      );

    expect(grid().shouldRepaint(before), isFalse);
    expect(controller.repaintStamp, greaterThan(0), reason: '其余层仍在重绘');
  });

  test('相机平移：其余各层判定需要重绘', () {
    final CanvasController controller = CanvasController();
    final InkPainter inkBefore = InkPainter(
      camera: controller.camera,
      stamp: controller.repaintStamp,
    );
    final OverlayPainter overlayBefore = OverlayPainter(
      camera: controller.camera,
      color: const Color(0xFF000000),
      stamp: controller.repaintStamp,
    );
    final int stampBefore = controller.repaintStamp;

    controller.onPointerSignal(
      const PointerScrollEvent(
        position: Offset(400, 300),
        scrollDelta: Offset(0, 40),
      ),
    );

    expect(controller.repaintStamp, greaterThan(stampBefore));
    expect(
      InkPainter(
        camera: controller.camera,
        stamp: controller.repaintStamp,
      ).shouldRepaint(inkBefore),
      isTrue,
    );
    expect(
      OverlayPainter(
        camera: controller.camera,
        color: const Color(0xFF000000),
        stamp: controller.repaintStamp,
      ).shouldRepaint(overlayBefore),
      isTrue,
    );
  });

  test('湿墨生长（就地加点）：InkPainter 判定需要重绘', () {
    final CanvasController controller = CanvasController();
    controller.setViewport(const Size(800, 600));
    // 2026-09-18：默认工具改为"选择" ⇒ 笔迹相关用例须显式进入画笔工具
    //（否则 down 走"框选"分支，根本不会产生 activeStroke）。
    controller.setTool(CanvasTool.pen);
    controller.onPointerDown(
      const PointerDownEvent(
        pointer: 1,
        kind: PointerDeviceKind.stylus,
        position: Offset(10, 10),
      ),
    );
    final InkPainter before = InkPainter(
      camera: controller.camera,
      activeStroke: controller.activeStroke,
      stamp: controller.repaintStamp,
    );

    controller.onPointerMove(
      const PointerMoveEvent(
        pointer: 1,
        kind: PointerDeviceKind.stylus,
        position: Offset(80, 80),
      ),
    );

    final InkPainter after = InkPainter(
      camera: controller.camera,
      activeStroke: controller.activeStroke,
      stamp: controller.repaintStamp,
    );
    expect(
      after.shouldRepaint(before),
      isTrue,
      reason: 'activeStroke 是同一个对象，靠字段比较看不出新加了点',
    );
    expect(controller.activeStroke!.points.length, greaterThan(1));
  });

  test('stale 状态翻转后 ItemPainter 判定需要重绘（否则标记不会出现）', () async {
    final CanvasController controller = CanvasController();
    final ShapeItem shape = ShapeItem(
      rect: const Rect.fromLTWH(0, 0, 80, 60),
      kind: CanvasShapeKind.rectangle,
      color: const Color(0xFF112233),
      filled: true,
    );
    controller.document.addItem(shape);
    final AiImageItem layer = await controller.generateFromRegion(
      Region(id: 'r', bbox: shape.rect),
    );
    expect(layer.gen.status, GenStatus.done);

    final ItemPainter before = ItemPainter(
      camera: controller.camera,
      items: controller.document.items,
      stamp: controller.repaintStamp,
      staleColor: const Color(0xFFFF0000),
    );

    shape.rect = shape.rect.shift(const Offset(20, 0));
    expect(controller.refreshStaleness(), isTrue);
    controller.requestRepaint(); // 视图侧通知（stamp 随之 +1）

    final ItemPainter after = ItemPainter(
      camera: controller.camera,
      items: controller.document.items,
      stamp: controller.repaintStamp,
      staleColor: const Color(0xFFFF0000),
    );
    expect(after.shouldRepaint(before), isTrue);
    expect(layer.gen.status, GenStatus.stale);
    controller.dispose();
  });
}
