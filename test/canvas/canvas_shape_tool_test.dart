import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';

// 构造指针事件用 `position`：无变换时 `localPosition` 就等于它，而控制器读的是
// `localPosition`（真实事件由 Listener 把全局坐标折算成局部坐标）。
PointerDownEvent _down(Offset at) =>
    PointerDownEvent(pointer: 1, position: at, kind: PointerDeviceKind.mouse);

PointerMoveEvent _move(Offset at) =>
    PointerMoveEvent(pointer: 1, position: at, kind: PointerDeviceKind.mouse);

PointerUpEvent _up(Offset at) =>
    PointerUpEvent(pointer: 1, position: at, kind: PointerDeviceKind.mouse);

/// 形状工具（`CanvasTool.shape`）的回归（2026-09-17，画布 P0 修正）。
///
/// ## 它修的是什么
/// 实测反馈："点'矩形'只插入一个固定大小、还立刻切回框选，于是接着拖出来的是
/// **框选**——矩形工具像假的"。契约因此定为：
/// ① 选形状 = 进入**绘制模式**（拖拽定尺寸，点一下给默认大小）；
/// ② 画完**停在形状工具**里（可连着画几个），Esc 才回选择工具；
/// ③ 拖拽期间有**预览框**（不然用户不知道自己在画什么）；
/// ④ 落账走既有命令栈（一条撤销就能收回去）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CanvasController setUpController() {
    final CanvasController controller = CanvasController();
    controller.setViewport(const Size(800, 600));
    return controller;
  }

  test('拖拽：按拖出来的框落账，世界尺寸随缩放折算', () {
    final CanvasController controller = setUpController();
    controller.zoomBy(2); // 2× ⇒ 屏幕 100×60 = 世界 50×30

    controller.setShapeTool(CanvasShapeKind.rectangle);
    expect(controller.tool, CanvasTool.shape);

    controller.onPointerDown(_down(const Offset(100, 100)));
    controller.onPointerMove(_move(const Offset(200, 160)));
    expect(controller.shapeDraft, isNotNull, reason: '拖拽中没有预览框：用户不知道自己在画什么');

    controller.onPointerUp(_up(const Offset(200, 160)));

    expect(controller.shapeDraft, isNull, reason: '抬笔后预览框该清掉');
    expect(controller.document.items, hasLength(1));
    final ShapeItem shape = controller.document.items.single as ShapeItem;
    expect(shape.kind, CanvasShapeKind.rectangle);
    expect(shape.rect.width, closeTo(50, 0.01), reason: '世界尺寸没按缩放折算');
    expect(shape.rect.height, closeTo(30, 0.01));

    // 画完即选中（能马上调色/调描边），但**工具不切回选择**——切回去正是
    // "矩形像框选"的老毛病。
    expect(controller.selectedItems.single, same(shape));
    expect(
      controller.tool,
      CanvasTool.shape,
      reason: '画完就切回选择工具：再拖拽就变成框选了（实测反馈的那个 bug）',
    );

    // 落账走既有命令栈。
    controller.undo();
    expect(controller.document.items, isEmpty);
    controller.dispose();
  });

  test('点一下（没拖动）：落一个默认大小，且屏幕观感恒定', () {
    final CanvasController controller = setUpController();
    controller.zoomBy(2); // 2× ⇒ 世界尺寸应为默认值的一半

    controller.setShapeTool(CanvasShapeKind.rectangle);
    controller.onPointerDown(_down(const Offset(300, 200)));
    controller.onPointerUp(_up(const Offset(301, 200))); // 1px 抖动仍算"点"

    final ShapeItem shape = controller.document.items.single as ShapeItem;
    expect(shape.rect.width, closeTo(80, 0.01));
    expect(shape.rect.height, closeTo(60, 0.01));
    // 落点就是点下去的地方（不是视口中心）。
    final Offset onScreen = controller.camera.worldToScreen(shape.rect.center);
    expect(onScreen.dx, closeTo(300, 0.01));
    expect(onScreen.dy, closeTo(200, 0.01));
    controller.dispose();
  });

  test('颜色跟随笔刷（默认仍是哨兵：暗色画布上自动变浅）', () {
    final CanvasController controller = setUpController();
    controller.setShapeTool(CanvasShapeKind.rectangle);
    controller.onPointerDown(_down(const Offset(10, 10)));
    controller.onPointerUp(_up(const Offset(60, 60)));
    expect(
      (controller.document.items.single as ShapeItem).color,
      kThemeInk,
      reason: '写具体色就烤死在当前明暗档：切主题后形状会隐形',
    );

    controller.setPenColor(const Color(0xFFE5484D));
    controller.onPointerDown(_down(const Offset(80, 80)));
    controller.onPointerUp(_up(const Offset(120, 120)));
    expect(
      (controller.document.items.last as ShapeItem).color,
      const Color(0xFFE5484D),
      reason: '形状工具就是"用当前笔刷画个框"：笔色改了形状也该跟着改',
    );
    controller.dispose();
  });

  test('椭圆工具：预览与落账都是椭圆（只有 kind 不同）', () {
    final CanvasController controller = setUpController();
    controller.setShapeTool(CanvasShapeKind.ellipse);
    expect(controller.shapeKind, CanvasShapeKind.ellipse);

    controller.onPointerDown(_down(const Offset(0, 0)));
    controller.onPointerUp(_up(const Offset(50, 50)));
    expect(
      (controller.document.items.single as ShapeItem).kind,
      CanvasShapeKind.ellipse,
    );
    controller.dispose();
  });

  test('取消手势：不落账、也不留预览框', () {
    final CanvasController controller = setUpController();
    controller.setShapeTool(CanvasShapeKind.rectangle);
    controller.onPointerDown(_down(const Offset(10, 10)));
    controller.onPointerMove(_move(const Offset(100, 100)));

    controller.onPointerCancel(
      const PointerCancelEvent(pointer: 1, position: Offset(100, 100)),
    );

    expect(controller.document.items, isEmpty, reason: '取消不该落账');
    expect(controller.shapeDraft, isNull);
    controller.dispose();
  });
}
