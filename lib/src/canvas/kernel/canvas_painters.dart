import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'canvas_ai.dart';
import 'canvas_camera.dart';
import 'canvas_item.dart';
import 'ink_stroke.dart';

/// 背景点阵网格：**屏幕坐标**下按相机绘制，间距随缩放自适应。
///
/// 画点阵而不是实线网格：无限画布没有"页边界"，点阵既能表达空间又不喧宾夺主
/// （tldraw / Figma 同款）。间距固定在屏幕 16~96px 之间（[GridPainter] 里
/// 的倍率调整），缩放到任何层级密度都稳定。
class GridPainter extends CustomPainter {
  const GridPainter({
    required this.camera,
    required this.color,
    this.stamp = 0,
  });

  /// 世界单位下的基准间距。
  static const double baseSpacing = 24;

  final CanvasCamera camera;
  final Color color;

  /// 相机版本号的**快照**（调用方传 `camera.revision`）。
  ///
  /// ⚠️ 必须在构造时把值捕获下来：两个 painter 持有的是**同一个** camera 对象，
  /// 在 `shouldRepaint` 里读 `oldDelegate.camera.revision` 等于读当前值、和自己
  /// 比，恒等——与下面那些字段比较一样是无效的。
  final int stamp;

  @override
  void paint(Canvas canvas, Size size) {
    double step = baseSpacing;
    // 太密就翻倍、太疏就减半：屏幕间距钳在 16~96px。
    while (camera.toScreen(step) < 16) {
      step *= 2;
    }
    while (camera.toScreen(step) > 96) {
      step /= 2;
    }

    final double screenStep = camera.toScreen(step);
    final Offset origin = camera.worldToScreen(Offset.zero);
    final double startX = origin.dx % screenStep;
    final double startY = origin.dy % screenStep;

    final ui.Paint paint = ui.Paint()..color = color;
    for (double y = startY; y < size.height; y += screenStep) {
      for (double x = startX; x < size.width; x += screenStep) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  /// 只认**相机版本号快照**：网格是唯一的重层（整屏点阵，每帧上千个圆），
  /// 写字/拖 item 时相机没动就不该重绘它——高频局部刷新的关键就在这一条。
  /// （下面的字段比较对"同一个相机对象"恒等，只对跨对象调用方有意义。）
  @override
  bool shouldRepaint(GridPainter oldDelegate) =>
      oldDelegate.stamp != stamp ||
      oldDelegate.camera.scale != camera.scale ||
      oldDelegate.camera.translation != camera.translation ||
      oldDelegate.color != color;
}

/// item 层（图片 / 形状）：世界坐标重放，画在笔迹**下方**
/// （OneNote 口径：墨迹批注在图片上）。
///
/// 与笔迹层分开的仍是**重绘隔离**：item 的增删拖拽只重绘本层，
/// 几千条笔迹那层不动（反之亦然）。
class ItemPainter extends CustomPainter {
  const ItemPainter({
    required this.camera,
    this.inkColor = kThemeInk,
    this.items = const <CanvasItem>[],
    this.onImageMissing,
    this.staleColor,
    this.stamp = 0,
  });

  final CanvasCamera camera;

  /// 当前**主题墨色**（同 [InkPainter.inkColor]）：哨兵色的 item 按它绘制。
  /// 默认值即哨兵，只对"没有主题"的离屏路径成立（导出/AI：白纸黑墨）。
  final Color inkColor;

  /// 待绘制的 item（应已按视口裁剪，见 `CanvasDocument.itemsIn`）。
  final List<CanvasItem> items;

  /// 遇到未加载的图片 item 时回调（视图层据此触发懒加载）。
  final void Function(ImageItem)? onImageMissing;

  /// AI 层"输入已变、可重算"标记的颜色；null = 不画。
  ///
  /// 导出与栅格化都不传 ⇒ 标记**不会**进导出图、也不会进模型输入图。
  final Color? staleColor;

  /// 视觉状态版本号（见 `CanvasController.repaintStamp`）。拖拽/缩放/过期状态
  /// 都是**就地**改的，只有它能判定"这一帧与上一帧不同"。
  final int stamp;

  @override
  void paint(Canvas canvas, Size size) {
    if (items.isEmpty) return;
    canvas.save();
    canvas.translate(camera.translation.dx, camera.translation.dy);
    canvas.scale(camera.scale);
    for (final CanvasItem item in items) {
      if (item is ImageItem && !item.loaded) {
        onImageMissing?.call(item);
      }
      // 逐 item 绕自身中心旋转绘制（rect 保持轴对齐本地坐标，旋转只在此处）。
      if (item.angle == 0) {
        item.paint(canvas, ink: inkColor);
      } else {
        canvas.save();
        final Offset center = item.rect.center;
        canvas.translate(center.dx, center.dy);
        canvas.rotate(item.angle);
        canvas.translate(-center.dx, -center.dy);
        item.paint(canvas, ink: inkColor);
        canvas.restore();
      }
    }
    canvas.restore();

    // 过期标记：画在**屏幕坐标**下（虚线节拍与线宽不随缩放变化，否则放大后
    // 边框会变成一条实线）。它描述的是 item 自身状态，所以留在内容层而非浮层。
    final Color? stale = staleColor;
    if (stale == null) return;
    for (final CanvasItem item in items) {
      if (item is! AiImageItem || item.gen.status != GenStatus.stale) continue;
      final Rect box = Rect.fromPoints(
        camera.worldToScreen(item.bounds.topLeft),
        camera.worldToScreen(item.bounds.bottomRight),
      );
      _drawStaleMarker(canvas, box, stale);
    }
  }

  /// 虚线描边：一眼看出"这层该重算了"，又不遮挡内容（不铺半透明底色）。
  void _drawStaleMarker(Canvas canvas, Rect box, Color color) {
    final ui.Paint paint = ui.Paint()
      ..color = color
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.5;
    const double dash = 6;
    const double gap = 4;
    void dashed(Offset a, Offset b) {
      final double total = (b - a).distance;
      if (total <= 0) return;
      final Offset dir = (b - a) / total;
      for (double t = 0; t < total; t += dash + gap) {
        canvas.drawLine(a + dir * t, a + dir * math.min(t + dash, total), paint);
      }
    }

    dashed(box.topLeft, box.topRight);
    dashed(box.topRight, box.bottomRight);
    dashed(box.bottomRight, box.bottomLeft);
    dashed(box.bottomLeft, box.topLeft);
  }

  @override
  bool shouldRepaint(ItemPainter oldDelegate) {
    if (oldDelegate.stamp != stamp ||
        oldDelegate.inkColor != inkColor ||
        oldDelegate.camera.scale != camera.scale ||
        oldDelegate.camera.translation != camera.translation ||
        oldDelegate.staleColor != staleColor) {
      return true;
    }
    // 下面的字段比较只在"两个 painter 拿到**不同**实例"时有效：视图每帧传给
    // 两个 painter 的是同一批 item 对象，比身份/几何等于和自己比 ⇒ 恒等。
    // 真正兜住就地修改（拖拽、stale 状态翻转）的是上面的 [stamp]。
    if (oldDelegate.items.length != items.length) return true;
    for (int i = 0; i < items.length; i++) {
      final CanvasItem before = oldDelegate.items[i];
      final CanvasItem after = items[i];
      if (before != after || before.rect != after.rect || before.angle != after.angle) {
        return true;
      }
    }
    return false;
  }
}

/// 笔迹层：把世界坐标的轮廓**按相机变换**重放。
///
/// ⚠️ 传进来的 [strokes] 应当是**已裁剪**的（见 [CanvasDocument.strokesIn]）：
/// 绘制成本与条数线性相关，视口外的笔迹不该进 paint。
class InkPainter extends CustomPainter {
  const InkPainter({
    required this.camera,
    this.inkColor = kThemeInk,
    this.strokes = const <InkStroke>[],
    this.picture,
    this.activeStroke,
    this.stamp = 0,
  });

  final CanvasCamera camera;

  /// 当前**主题墨色**：[kThemeInk] 色的笔迹按它绘制（见 [resolveInk]）。
  ///
  /// 默认值即哨兵——那只在"没有主题"的场合成立（如导出：白底黑墨）；界面必须
  /// 由宿主传真实墨色，否则暗色下又变回"黑墨画黑纸"。
  final Color inkColor;

  /// 逐条绘制的笔迹（[picture] 为 null 时使用）。
  final List<InkStroke> strokes;

  /// 已完笔迹的合成显示列表（世界坐标）。不为 null 时**一次 drawPicture**
  /// 取代 N 次 drawPath，平移/缩放因此几乎零成本。
  final ui.Picture? picture;

  /// 正在书写的那条（每帧重算轮廓，故与已完成的分开传）。
  final InkStroke? activeStroke;

  /// 视觉状态版本号（见 `CanvasController.repaintStamp`）：**湿墨生长**是就地
  /// 给同一个 [InkStroke] 加点，字段/身份比较都看不出来，只能靠它。
  final int stamp;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(camera.translation.dx, camera.translation.dy);
    canvas.scale(camera.scale);

    // 缓存那张 Picture 已经**按墨色烤好**了（见 `CanvasController.pictureFor`），
    // 直接重放；只有下面逐条/湿墨两条路径需要在这里解析墨色。
    final ui.Picture? cached = picture;
    if (cached != null) {
      canvas.drawPicture(cached);
    } else {
      for (final InkStroke stroke in strokes) {
        canvas.drawPath(
          stroke.outline,
          ui.Paint()..color = resolveInk(stroke.color, inkColor),
        );
      }
    }

    final InkStroke? active = activeStroke;
    if (active != null) {
      canvas.drawPath(
        active.outline,
        ui.Paint()..color = resolveInk(active.color, inkColor),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(InkPainter oldDelegate) =>
      oldDelegate.stamp != stamp ||
      oldDelegate.inkColor != inkColor ||
      oldDelegate.camera.scale != camera.scale ||
      oldDelegate.camera.translation != camera.translation ||
      oldDelegate.picture != picture ||
      oldDelegate.strokes != strokes ||
      oldDelegate.activeStroke != activeStroke;
}

/// 交互浮层（屏幕坐标）：框选矩形 + 橡皮光标。
///
/// 与内容层分开是为了**重绘隔离**：拖拽框选时只有这一层重绘，
/// 几千条笔迹的那一层不动（项目渲染规范：高频局部刷新不牵动整页）。
class OverlayPainter extends CustomPainter {
  const OverlayPainter({
    required this.camera,
    required this.color,
    this.marquee,
    this.eraserCenter,
    this.eraserRadius,
    this.selectedItems = const <CanvasItem>[],
    this.stamp = 0,
  });

  final CanvasCamera camera;
  final Color color;

  /// 视觉状态版本号（见 `CanvasController.repaintStamp`）：框选矩形与选中框
  /// 都是就地变化的，只有它能判定重绘。
  final int stamp;

  /// 框选矩形（世界坐标）。
  final Rect? marquee;

  final Offset? eraserCenter;

  /// 橡皮半径（世界单位）。
  final double? eraserRadius;

  /// 选中的 item（世界坐标）。单选画旋转后的描边 + 四角/旋转手柄；
  /// 多选画并集包围盒 + 四角/旋转手柄（整体缩放/旋转）。
  final List<CanvasItem> selectedItems;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect? box = marquee;
    if (box != null) {
      final Offset topLeft = camera.worldToScreen(box.topLeft);
      final Offset bottomRight = camera.worldToScreen(box.bottomRight);
      final Rect screenRect = Rect.fromPoints(topLeft, bottomRight);
      canvas.drawRect(
        screenRect,
        ui.Paint()..color = color.withValues(alpha: 0.12),
      );
      canvas.drawRect(
        screenRect,
        ui.Paint()
          ..color = color
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    // 选中 item：单选画旋转矩形，多选画并集包围盒；均带四角 + 旋转手柄。
    final ui.Paint outline = ui.Paint()
      ..color = color
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.5;
    if (selectedItems.isNotEmpty) {
      if (selectedItems.length == 1) {
        final CanvasItem item = selectedItems.single;
        final List<Offset> corners = CanvasHandles.rotatedCorners(item.rect, item.angle)
            .map(camera.worldToScreen)
            .toList(growable: false);
        _drawPolygon(canvas, corners, outline);
        for (final Offset c in corners) {
          _drawHandle(canvas, c, color);
        }
        final Offset topMid = (corners[0] + corners[1]) / 2;
        final Offset rot = CanvasHandles.rotationHandlePos(
            corners, CanvasHandles.rotateHandleDistance);
        _drawRotateHandle(canvas, rot, topMid, color);
      } else {
        Rect group = selectedItems.first.bounds;
        for (int i = 1; i < selectedItems.length; i++) {
          group = group.expandToInclude(selectedItems[i].bounds);
        }
        final List<Offset> corners = CanvasHandles.corners(group)
            .map(camera.worldToScreen)
            .toList(growable: false);
        _drawPolygon(canvas, corners, outline);
        for (final Offset c in corners) {
          _drawHandle(canvas, c, color);
        }
        final Offset topMid = (corners[0] + corners[1]) / 2;
        final Offset rot = CanvasHandles.rotationHandlePos(
            corners, CanvasHandles.rotateHandleDistance);
        _drawRotateHandle(canvas, rot, topMid, color);
      }
    }

    final Offset? center = eraserCenter;
    final double? radius = eraserRadius;
    if (center != null && radius != null) {
      canvas.drawCircle(
        camera.worldToScreen(center),
        camera.toScreen(radius),
        ui.Paint()
          ..color = color.withValues(alpha: 0.25)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  void _drawPolygon(Canvas canvas, List<Offset> corners, ui.Paint paint) {
    if (corners.isEmpty) return;
    final ui.Path path = ui.Path()..moveTo(corners[0].dx, corners[0].dy);
    for (int i = 1; i < corners.length; i++) {
      path.lineTo(corners[i].dx, corners[i].dy);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  void _drawHandle(Canvas canvas, Offset screen, Color color) {
    final Rect square = Rect.fromCenter(
      center: screen,
      width: CanvasHandles.radius * 2,
      height: CanvasHandles.radius * 2,
    );
    canvas.drawRect(square, ui.Paint()..color = const Color(0xFFFFFFFF));
    final ui.Paint border = ui.Paint()
      ..color = color
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(square, border);
  }

  void _drawRotateHandle(Canvas canvas, Offset rot, Offset topMid, Color color) {
    canvas.drawLine(
      topMid,
      rot,
      ui.Paint()..color = color..strokeWidth = 1,
    );
    canvas.drawCircle(rot, 5, ui.Paint()..color = const Color(0xFFFFFFFF));
    final ui.Paint border = ui.Paint()
      ..color = color
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(rot, 5, border);
  }

  @override
  bool shouldRepaint(OverlayPainter oldDelegate) {
    if (oldDelegate.stamp != stamp ||
        oldDelegate.marquee != marquee ||
        oldDelegate.eraserCenter != eraserCenter ||
        oldDelegate.eraserRadius != eraserRadius ||
        oldDelegate.camera.translation != camera.translation ||
        oldDelegate.camera.scale != camera.scale) {
      return true;
    }
    // 选中集合每帧都是新实例；比长度 + 每个 item 的“身份 + 几何 + 旋转”，
    // 否则纯写字时浮层会跟着每帧重绘。
    if (oldDelegate.selectedItems.length != selectedItems.length) return true;
    for (int i = 0; i < selectedItems.length; i++) {
      if (oldDelegate.selectedItems[i] != selectedItems[i] ||
          oldDelegate.selectedItems[i].rect != selectedItems[i].rect ||
          oldDelegate.selectedItems[i].angle != selectedItems[i].angle) {
        return true;
      }
    }
    return false;
  }
}
