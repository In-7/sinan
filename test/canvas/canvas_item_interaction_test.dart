import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';

/// 控制器交互测试用形状：世界坐标 (0,0)-(40,40)。
///
/// 控制器默认相机 scale=1 / translation=0 ⇒ 世界坐标 == 屏幕坐标，
/// 指针事件可以直接用世界坐标合成。
ShapeItem _item() => ShapeItem(
      rect: const Rect.fromLTRB(0, 0, 40, 40),
      kind: CanvasShapeKind.rectangle,
      color: const Color(0xFF1565C0),
      filled: true,
    );

CanvasController _controllerWithItem() {
  final CanvasController controller = CanvasController()
    ..setTool(CanvasTool.select);
  controller.document.addItem(_item());
  return controller;
}

const int _pointer = 1;

void main() {
  test('点击选中 → 拖动 → 松开落账；撤销还原', () {
    final CanvasController controller = _controllerWithItem();
    final CanvasItem item = controller.document.items.single;

    controller.onPointerDown(const PointerDownEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(20, 20),
    ));
    expect(controller.selectedItems, <CanvasItem>[item]);

    controller.onPointerMove(const PointerMoveEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(50, 45),
    ));
    expect(item.rect, const Rect.fromLTRB(30, 25, 70, 65));

    controller.onPointerUp(const PointerUpEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(50, 45),
    ));
    expect(item.rect, const Rect.fromLTRB(30, 25, 70, 65));

    controller.undo();
    expect(item.rect, const Rect.fromLTRB(0, 0, 40, 40));
    controller.dispose();
  });

  test('空白处按下拖出框选，松开收进 item 选区', () {
    final CanvasController controller = _controllerWithItem();

    controller.onPointerDown(const PointerDownEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(-50, -50),
    ));
    controller.onPointerMove(const PointerMoveEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(200, 200),
    ));
    controller.onPointerUp(const PointerUpEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(200, 200),
    ));

    expect(controller.selectedItems, hasLength(1));
    expect(controller.hasSelection, isTrue);
    controller.dispose();
  });

  test('单选手柄缩放：拖角跟手、minSize 钳住、松开落账可撤销', () {
    final CanvasController controller = _controllerWithItem();
    final CanvasItem item = controller.document.items.single;

    // 先点击选中（down + up，不动）。
    controller.onPointerDown(const PointerDownEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(20, 20),
    ));
    controller.onPointerUp(const PointerUpEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(20, 20),
    ));

    // 按在 bottomRight 手柄上（角 (40,40)，命中半径 10）。
    controller.onPointerDown(const PointerDownEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(42, 42),
    ));
    controller.onPointerMove(const PointerMoveEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(60, 55),
    ));
    expect(item.rect, const Rect.fromLTRB(0, 0, 60, 55));

    // 拖过头：minSize 钳住（对角锚定）。
    controller.onPointerMove(const PointerMoveEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(3, 3),
    ));
    expect(item.rect, const Rect.fromLTRB(0, 0, CanvasHandles.minSize, CanvasHandles.minSize));

    controller.onPointerUp(const PointerUpEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(3, 3),
    ));
    controller.undo();
    expect(item.rect, const Rect.fromLTRB(0, 0, 40, 40));
    controller.dispose();
  });

  test('点击没动过的 item：不产生撤销命令', () {
    final CanvasController controller = _controllerWithItem();

    controller.onPointerDown(const PointerDownEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(20, 20),
    ));
    controller.onPointerUp(const PointerUpEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(20, 20),
    ));

    // 撤销栈深度 = setup 的 addItem（revision 1）⇒ 本次点击没入栈。
    expect(controller.document.revision, 1);
    controller.dispose();
  });

  test('Delete 删除所选 item，撤销原位恢复（含 z 序）', () {
    final CanvasController controller = CanvasController()
      ..setTool(CanvasTool.select);
    final ShapeItem first = ShapeItem(
      rect: const Rect.fromLTRB(0, 0, 40, 40),
      kind: CanvasShapeKind.rectangle,
      color: const Color(0xFF000000),
      filled: true,
    );
    final ShapeItem second = ShapeItem(
      rect: const Rect.fromLTRB(100, 0, 140, 40),
      kind: CanvasShapeKind.rectangle,
      color: const Color(0xFF000000),
      filled: true,
    );
    controller.document
      ..addItem(first)
      ..addItem(second);

    // 点选第二个（最上层那片区域）。
    controller.onPointerDown(const PointerDownEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(120, 20),
    ));
    controller.onPointerUp(const PointerUpEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(120, 20),
    ));
    controller.deleteSelection();

    expect(controller.document.items, <CanvasItem>[first]);
    controller.undo();
    expect(controller.document.items, <CanvasItem>[first, second]);
    controller.dispose();
  });

  test('拖动中途 cancel：rect 弹回起点，不产生撤销命令', () {
    final CanvasController controller = _controllerWithItem();
    final CanvasItem item = controller.document.items.single;

    controller.onPointerDown(const PointerDownEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(20, 20),
    ));
    controller.onPointerMove(const PointerMoveEvent(
      pointer: _pointer,
      kind: PointerDeviceKind.mouse,
      position: Offset(50, 50),
    ));
    controller.onPointerCancel(const PointerCancelEvent(pointer: _pointer));

    expect(item.rect, const Rect.fromLTRB(0, 0, 40, 40));
    // 撤销栈深度 = setup 的 addItem（revision 1）⇒ cancel 没入栈。
    expect(controller.document.revision, 1);
    controller.dispose();
  });
}
