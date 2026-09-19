import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_camera.dart';

void main() {
  test('screenToWorld / worldToScreen 互为逆变换', () {
    final CanvasCamera camera = CanvasCamera(
      scale: 2,
      translation: const Offset(30, -12),
    );
    const Offset world = Offset(100, 50);
    final Offset screen = camera.worldToScreen(world);
    expect(screen, const Offset(230, 88));
    expect(camera.screenToWorld(screen).dx, closeTo(world.dx, 1e-9));
    expect(camera.screenToWorld(screen).dy, closeTo(world.dy, 1e-9));
  });

  test('zoomAt：焦点下的世界点保持不动', () {
    final CanvasCamera camera = CanvasCamera();
    const Offset focal = Offset(320, 240);
    final Offset anchorBefore = camera.screenToWorld(focal);

    camera.zoomAt(focal, 2.5);
    expect(camera.scale, closeTo(2.5, 1e-9));
    final Offset anchorAfter = camera.screenToWorld(focal);
    expect(anchorAfter.dx, closeTo(anchorBefore.dx, 1e-9));
    expect(anchorAfter.dy, closeTo(anchorBefore.dy, 1e-9));
  });

  test('zoomAt：缩放被钳在 min/max 之间', () {
    // maxScale 用默认值（= 天花板 4，见下一条用例），只显式给 minScale。
    final CanvasCamera camera = CanvasCamera(minScale: 0.5);
    camera.zoomAt(Offset.zero, 0.01);
    expect(camera.scale, 0.5);
    camera.zoomAt(Offset.zero, 1000);
    expect(camera.scale, 4);
  });

  test('默认缩放上限是 400%（2026-09-18 由 3200% 下调）', () {
    final CanvasCamera camera = CanvasCamera();
    expect(camera.maxScale, CanvasCamera.maxScaleCeiling);
    expect(camera.maxScale, 4);
    camera.zoomAt(Offset.zero, 1000);
    expect(camera.scale, 4, reason: '放大 1000 倍应被钳到 4（400%）');
  });

  test('旧存档的 maxScale: 32 会被钳到天花板（否则改默认值对老画布无效）', () {
    final CanvasCamera camera = CanvasCamera.fromJson(<String, dynamic>{
      'scale': 1.0,
      'translation': <double>[0, 0],
      'minScale': 0.05,
      'maxScale': 32.0,
    });
    expect(camera.maxScale, CanvasCamera.maxScaleCeiling);
    camera.zoomAt(Offset.zero, 1000);
    expect(camera.scale, 4);
  });

  test('visibleWorld：以当前视口反算世界矩形', () {
    final CanvasCamera camera = CanvasCamera(
      scale: 2,
      translation: const Offset(10, 20),
    );
    final Rect visible = camera.visibleWorld(const Size(800, 600));
    expect(visible.left, closeTo(-5, 1e-9)); // (0 - 10) / 2
    expect(visible.top, closeTo(-10, 1e-9)); // (0 - 20) / 2
    expect(visible.width, closeTo(400, 1e-9));
    expect(visible.height, closeTo(300, 1e-9));
  });

  test('fit：内容居中且完整落入视口（含 padding）', () {
    final CanvasCamera camera = CanvasCamera();
    const Rect content = Rect.fromLTWH(100, 100, 400, 200);
    camera.fit(content, const Size(800, 600), padding: 40);

    final Rect visible = camera.visibleWorld(const Size(800, 600));
    expect(visible.left, lessThanOrEqualTo(content.left));
    expect(visible.top, lessThanOrEqualTo(content.top));
    expect(visible.right, greaterThanOrEqualTo(content.right));
    expect(visible.bottom, greaterThanOrEqualTo(content.bottom));

    // 内容中心应落在视口中心。
    final Offset centerOnScreen =
        camera.worldToScreen(const Offset(300, 200));
    expect(centerOnScreen.dx, closeTo(400, 1e-6));
    expect(centerOnScreen.dy, closeTo(300, 1e-6));
  });
}
