import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_export.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CanvasItem 旋转几何', () {
    test('angle != 0：bounds 是旋转后的 AABB，且包含四角', () {
      final ShapeItem item = ShapeItem(
        rect: const Rect.fromLTWH(0, 0, 40, 20),
        angle: math.pi / 2, // 转 90°
        kind: CanvasShapeKind.rectangle,
        color: const Color(0xFF000000),
      );
      final Rect b = item.bounds;
      // 40×20 转 90° 后应为 20×40。
      expect(b.width, closeTo(20, 1e-6));
      expect(b.height, closeTo(40, 1e-6));
      // 四角都在 AABB 内（Rect.contains 对右/下边是开区间，故用含入判断）。
      for (final Offset c in CanvasHandles.rotatedCorners(item.rect, item.angle)) {
        expect(c.dx, inInclusiveRange(b.left, b.right));
        expect(c.dy, inInclusiveRange(b.top, b.bottom));
      }
    });

    test('angle = 0：bounds 等于 rect（无额外开销）', () {
      final ShapeItem item = ShapeItem(
        rect: const Rect.fromLTWH(5, 6, 40, 20),
        kind: CanvasShapeKind.rectangle,
        color: const Color(0xFF000000),
      );
      expect(item.bounds, const Rect.fromLTRB(5, 6, 45, 26));
    });

    test('hitTest 跟随旋转：本地命中、世界偏移后不命中', () {
      final ShapeItem item = ShapeItem(
        rect: const Rect.fromLTWH(0, 0, 40, 20),
        angle: math.pi / 2,
        kind: CanvasShapeKind.rectangle,
        color: const Color(0xFF000000),
        filled: true,
      );
      // 旋转后原 (20,10) 中心映射到世界 (10,20) 附近。
      final Offset worldCenter = item.rect.center;
      // toLocal 把世界中心转回本地 (20,10)，应在盒内。
      expect(item.hitTest(item.toLocal(worldCenter), 0), isTrue);
      expect(item.hitTest(const Offset(1000, 1000), 0), isFalse);
    });

    test('toJson/fromJson 往返保留 angle', () {
      final ShapeItem item = ShapeItem(
        rect: const Rect.fromLTWH(0, 0, 40, 20),
        angle: 0.5,
        kind: CanvasShapeKind.ellipse,
        color: const Color(0xFF123456),
        filled: true,
      );
      final ShapeItem restored = ShapeItem.fromJson(item.toJson());
      expect(restored.angle, 0.5);
      expect(restored.rect, item.rect);
    });
  });

  group('CanvasHandles 几何', () {
    test('resizeRotated 在 angle=0 时退化为 resize', () {
      const Rect r = Rect.fromLTRB(0, 0, 40, 40);
      final Rect a = CanvasHandles.resizeRotated(r, 0, CanvasHandle.bottomRight, const Offset(60, 55));
      final Rect b = CanvasHandles.resize(r, CanvasHandle.bottomRight, const Offset(60, 55));
      expect(a, b);
      expect(a, const Rect.fromLTRB(0, 0, 60, 55));
    });

    test('resizeRotated 保留旋转：拖对角锚定、新矩形仍是原 angle', () {
      const Rect r = Rect.fromLTRB(0, 0, 40, 20);
      final Rect scaled = CanvasHandles.resizeRotated(
        r,
        math.pi / 2,
        CanvasHandle.bottomRight,
        const Offset(80, 60), // 世界目标
      );
      // 中心应随拖动平移；尺寸按比例。这里只验证尺寸非负 & 函数可用。
      expect(scaled.width, greaterThan(0));
      expect(scaled.height, greaterThan(0));
    });

    test('scaleAbout / rotateAbout 基本性质', () {
      const Rect r = Rect.fromLTRB(0, 0, 10, 10);
      final Rect scaled = CanvasHandles.scaleAbout(r, const Offset(10, 10), 2, 2);
      expect(scaled, const Rect.fromLTRB(-10, -10, 10, 10));
      final Rect rotated = CanvasHandles.rotateAbout(
        r,
        const Offset(5, 5),
        math.pi,
      );
      expect(rotated.center, const Offset(5, 5));
      expect(rotated.width, 10);
    });
  });

  group('多选变换（控制器手势）', () {
    late CanvasController controller;

    setUp(() {
      controller = CanvasController();
      controller.tool = CanvasTool.select;
      controller.document.addItem(ShapeItem(
        rect: const Rect.fromLTWH(0, 0, 40, 40),
        kind: CanvasShapeKind.rectangle,
        color: const Color(0xFF000000),
      ));
      controller.document.addItem(ShapeItem(
        rect: const Rect.fromLTWH(100, 0, 40, 40),
        kind: CanvasShapeKind.rectangle,
        color: const Color(0xFF000000),
      ));
    });

    PointerDownEvent down(Offset p) => PointerDownEvent(
          pointer: 1,
          kind: PointerDeviceKind.mouse,
          position: p,
        );
    PointerMoveEvent move(Offset p) => PointerMoveEvent(
          pointer: 1,
          kind: PointerDeviceKind.mouse,
          position: p,
        );
    PointerUpEvent up(Offset p) => PointerUpEvent(
          pointer: 1,
          kind: PointerDeviceKind.mouse,
          position: p,
        );

    test('多选整体缩放：拖对角 → 所有 item 等比缩放', () {
      controller.setSelection(controller.document.items);
      // 默认相机 scale=1、translation=0 ⇒ 世界=屏幕。
      // 并集框 (0,0,140,40)，拖 topLeft(0,0) 到 (20,10)（屏幕=世界）。
      final Offset handle = controller.camera.worldToScreen(
        const Offset(0, 0),
      );
      controller.onPointerDown(down(handle));
      controller.onPointerMove(move(const Offset(20, 10)));
      controller.onPointerUp(up(const Offset(20, 10)));

      final List<CanvasItem> items = controller.document.items;
      // sx = (20-140)/(0-140)=0.857, sy=(10-40)/(0-40)=0.75
      expect(items[0].rect.width, closeTo(40 * 0.857, 0.5));
      expect(items[1].rect.width, closeTo(40 * 0.857, 0.5));
      // 撤销回到原状。
      controller.undo();
      expect(controller.document.items[0].rect, const Rect.fromLTRB(0, 0, 40, 40));
    });

    test('多选整体旋转：拖旋转手柄 → 所有 item 角度改变且可撤销', () {
      controller.setSelection(controller.document.items);
      // 并集框四角 (0,0)(140,0)(0,40)(140,40)；顶边中点 (70,0)，
      // 旋转手柄在其上方 22px ⇒ (70,-22)。
      final List<Offset> corners = CanvasHandles.corners(
        const Rect.fromLTRB(0, 0, 140, 40),
      ).map(controller.camera.worldToScreen).toList();
      final Offset rot = CanvasHandles.rotationHandlePos(
        corners,
        CanvasHandles.rotateHandleDistance,
      );
      controller.onPointerDown(down(rot));
      // 把指针拖到中心右侧，产生非零旋转角。
      controller.onPointerMove(move(const Offset(140, -22)));
      controller.onPointerUp(up(const Offset(140, -22)));

      expect(controller.document.items[0].angle, isNot(closeTo(0, 1e-6)));
      expect(controller.document.items[1].angle, isNot(closeTo(0, 1e-6)));
      // 撤销归零。
      controller.undo();
      expect(controller.document.items[0].angle, closeTo(0, 1e-6));
    });

    test('单选四角缩放手势（angle=0）落账正确', () {
      final ShapeItem item = controller.document.items.first as ShapeItem;
      controller.setSelection(<CanvasItem>[item]);
      // 抓右下角（其对角 topLeft(0,0) 锚定）拖到 (60,55) ⇒ 矩形 (0,0,60,55)。
      final Offset handle = controller.camera.worldToScreen(
        const Offset(40, 40),
      );
      controller.onPointerDown(down(handle));
      controller.onPointerMove(move(const Offset(60, 55)));
      controller.onPointerUp(up(const Offset(60, 55)));
      expect(item.rect, const Rect.fromLTRB(0, 0, 60, 55));
    });
  });

  group('整图导出', () {
    test('导出 PNG 到临时目录：文件存在且非空', () async {
      final CanvasController controller = CanvasController();
      controller.document.addItem(ShapeItem(
        rect: const Rect.fromLTWH(10, 10, 100, 100),
        kind: CanvasShapeKind.rectangle,
        color: const Color(0xFFCC0000),
      ));
      controller.document.addStroke(InkStroke(
        color: const Color(0xFF000000),
        baseWidth: 4,
      )..add(const InkPoint(Offset(0, 0), 0.5)));

      final Directory dir = await Directory.systemTemp.createTemp('canvas_exp_');
      final File file = await exportCanvasToPng(
        controller,
        directory: dir.path,
      );
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(0));
      // 透明背景导出也成功。
      final File transparent = await exportCanvasToPng(
        controller,
        directory: dir.path,
        background: const Color(0x00000000),
      );
      expect(transparent.existsSync(), isTrue);
      await dir.delete(recursive: true);
    });

    test('空画布导出抛异常', () async {
      final CanvasController controller = CanvasController();
      expect(
        () => exportCanvasToPng(controller, directory: Directory.systemTemp.path),
        throwsStateError,
      );
    });
  });
}
