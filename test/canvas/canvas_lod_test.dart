import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/kernel/canvas_camera.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/canvas_painters.dart';

/// item 层 **LOD 代理渲染**的回归（2026-09-19）。
///
/// ## 背景：视口裁剪救不了"缩小"
/// 裁剪只在 item 落在视口**外**时省事；一缩小，`visibleWorld` 就包住整张画布
/// ⇒ 每帧变成全量 **全保真**绘制（卡片建段落、图片采样、思维导图逐节点排字），
/// 块一多就掉帧。LOD 承接的正是这个场景。
///
/// 本文件钉住四条**不能退化**的契约：
/// 1. 缩小时小 item 走代理 ⇒ **不触发** `onImageMissing`（否则满屏图片一起去
///    解码整张原图，这是缩小时最贵的一笔）；
/// 2. `lod` 默认 false ⇒ 导出 / AI 栅格化（复用同一 painter）**永远全保真**，
///    否则当内容被缩小拟合时，导出会输出一堆色块；
/// 3. 选中 / 编辑中的 item **永不代理**（照 tldraw「正在操作的东西必须可见」）；
/// 4. 大文档缩放期间 LOD 判据**冻结**，停稳才跳一次（否则手势中途反复闪变 +
///    批量解码图片）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ImageItem image({Rect? rect}) =>
      ImageItem(rect: rect ?? const Rect.fromLTWH(0, 0, 100, 100));

  ShapeItem square() => ShapeItem(
    rect: const Rect.fromLTWH(0, 0, 20, 20),
    kind: CanvasShapeKind.rectangle,
    color: const Color(0xFF000000),
  );

  /// 画一帧，返回 `onImageMissing` 被调用的次数。
  ///
  /// **它就是 LOD 的可观测面**：命中代理的 item 会**先于**该回调返回，于是
  /// "计数为 0" 等价于"这一帧没有触发整图解码"。
  int countMissing({
    required CanvasItem item,
    double cameraScale = 1,
    bool lod = false,
    double? lodScale,
    Set<String> pinnedIds = const <String>{},
  }) {
    int missing = 0;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    ItemPainter(
      camera: CanvasCamera(scale: cameraScale),
      items: <CanvasItem>[item],
      onImageMissing: (ImageItem _) => missing++,
      lod: lod,
      lodScale: lodScale,
      pinnedIds: pinnedIds,
    ).paint(canvas, const Size(800, 600));
    // ⚠️ endRecording 必须在绘制**之后**：它结束录制，之后 canvas 就画不动了。
    recorder.endRecording().dispose();
    return missing;
  }

  group('isTooSmallForDetail（纯判据）', () {
    test('小到阈值的卡片/图片为 true，放大回来为 false', () {
      final ImageItem item = image();
      // 100 世界单位 × 0.1 = 10 屏幕像素 < 20 ⇒ 看不清。
      expect(ItemPainter.isTooSmallForDetail(item, 0.1), isTrue);
      // 100 × 0.5 = 50 ≥ 20 ⇒ 看清，全保真。
      expect(ItemPainter.isTooSmallForDetail(item, 0.5), isFalse);
    });

    test('形状**永远**不代理（单次 drawRect/drawOval 本就没有可省的成本）', () {
      expect(
        ItemPainter.isTooSmallForDetail(square(), 0.01),
        isFalse,
        reason: '空心形状画成实心色块会改变语义（看起来像填充了）',
      );
    });

    test('判据用**短边**：细长条即使很长也看不清', () {
      final ImageItem strip = image(rect: const Rect.fromLTWH(0, 0, 4000, 10));
      expect(
        ItemPainter.isTooSmallForDetail(strip, 1),
        isTrue,
        reason: '4000×10 的长条在 scale=1 下短边只有 10px',
      );
    });
  });

  group('paint 期的 LOD 闸门（图片解码）', () {
    test('lod: true + 缩小 ⇒ 不触发 onImageMissing（不解码），且不抛', () {
      expect(
        countMissing(item: image(), cameraScale: 0.1, lod: true),
        0,
        reason: '缩小到看不清时不该为满屏图片触发整图解码',
      );
    });

    test('lod: true + 放大 ⇒ 触发 onImageMissing（恢复全保真）', () {
      expect(countMissing(item: image(), lod: true), 1);
    });

    test('lod 默认 false（导出 / AI 路径）⇒ 再小也全保真，照常触发加载', () {
      expect(
        // ⚠️ 刻意不传 lod：这正是 `rasterizeWithCamera` 的调用形态。
        countMissing(item: image(), cameraScale: 0.1),
        1,
        reason: '导出的图必须是全保真像素，不能退化成色块',
      );
    });

    test('判据用的是 lodScale，**不是** camera.scale', () {
      // 相机很小（本该代理），但稳定缩放还很大 ⇒ 不代理、照常加载。
      expect(
        countMissing(item: image(), cameraScale: 0.05, lod: true, lodScale: 1),
        1,
      );
      // 反过来：相机已放大，但稳定缩放还停在很小的旧值 ⇒ 仍走代理。
      expect(
        countMissing(item: image(), lod: true, lodScale: 0.05),
        0,
        reason: '缩放中冻结判据的关键：这一帧还不该恢复全保真',
      );
    });

    test('pinnedIds（选中 / 编辑中）⇒ 再小也全保真', () {
      final ImageItem item = image();
      expect(
        countMissing(
          item: item,
          cameraScale: 0.1,
          lod: true,
          pinnedIds: <String>{item.id},
        ),
        1,
        reason: '正在操作的东西必须看得见（否则一选中反而变成色块）',
      );
    });
  });

  group('缩放期间冻结 LOD 判据（CanvasController.lodScale）', () {
    test('小文档：立即跟随缩放（冻结只会让 LOD 显得迟钝）', () {
      final CanvasController controller = CanvasController();
      addTearDown(controller.dispose);
      controller.setViewport(const Size(800, 600));
      controller.document.addItem(square()); // 1 个 item ≪ 阈值
      controller.requestRepaint(); // 首次同步：直接跟随

      controller.zoomBy(0.1);

      expect(controller.lodScale, closeTo(0.1, 1e-9));
    });

    test('大文档：缩放中冻结，停稳后才跳一次', () async {
      final CanvasController controller = CanvasController();
      addTearDown(controller.dispose);
      controller.setViewport(const Size(800, 600));
      for (int i = 0; i < CanvasController.lodFreezeThreshold; i++) {
        controller.document.addItem(square());
      }
      controller.requestRepaint(); // 首次同步：lodScale = 1

      controller.zoomBy(0.1); // 手势中 ⇒ 判据应保持不动

      expect(
        controller.lodScale,
        1.0,
        reason: '手势进行中跟着相机变 ⇒ 一路闪变 + 批量解码图片',
      );
      await Future<void>.delayed(CanvasController.lodSettleDelay * 3);
      expect(
        controller.lodScale,
        closeTo(0.1, 1e-9),
        reason: '停稳后应跳到真实缩放',
      );
    });
  });

  test('shouldRepaint 认 lod / lodScale / pinnedIds', () {
    final CanvasCamera camera = CanvasCamera(scale: 1);
    final ImageItem item = image();
    final List<CanvasItem> items = <CanvasItem>[item];
    final ItemPainter on = ItemPainter(camera: camera, items: items, lod: true);
    final ItemPainter off = ItemPainter(camera: camera, items: items);
    expect(on.shouldRepaint(off), isTrue);
    expect(off.shouldRepaint(on), isTrue);

    expect(
      ItemPainter(
        camera: camera,
        items: items,
        lod: true,
        pinnedIds: <String>{item.id},
      ).shouldRepaint(on),
      isTrue,
    );
    expect(
      ItemPainter(
        camera: camera,
        items: items,
        lod: true,
        lodScale: 0.5,
      ).shouldRepaint(on),
      isTrue,
    );
  });
}
