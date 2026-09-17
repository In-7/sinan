import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

/// 笔迹上的一个点：**世界坐标** + 压感（0~1）。
///
/// 存世界坐标（不是屏幕坐标）是绘制与缓存的前提：缩放时只需重放变换，
/// 不用重算轮廓（见 [InkStroke.outline]）。
class InkPoint {
  const InkPoint(this.position, this.pressure);

  final Offset position;

  /// 0~1。鼠标/触摸没有真压感时给 0，由 perfect_freehand 的
  /// `simulatePressure` 按速度模拟出粗细变化。
  final double pressure;
}

/// 一条笔迹：点列 + 样式，轮廓由 perfect_freehand 生成并**按世界坐标缓存**。
///
/// ## 为什么依赖 perfect_freehand 而不是自己画
/// 变宽轮廓（压感 → 半径 → 两侧偏移点 + 端点收笔 + 平滑）是笔迹里最易
/// 踩坑的一块；它是 tldraw 官方算法的 Dart 移植（6.37k downloads/wk、MIT、
/// 零第三方依赖）。我们只负责：点抽稀、缓存、命中测试。
///
/// ## 缓存与失效
/// 轮廓在**世界坐标**下算一次并缓存（[outline]），增删改点走 [_invalidate]。
/// 平移/缩放只重放变换 → 不重算；只有正在书写的那条每条 move 重算一次
/// （点数量有限，成本可接受；后续按 [canvas_architecture.md] 的"已完笔画
/// 缓存"再优化成 ui.Picture 分块）。
/// 笔迹 id 发生器（持久化与撤销命令的稳定引用）。
int _nextStrokeId = 0;

/// 「跟随主题」的墨色哨兵：笔迹颜色等于它 ⇒ 按**当前主题墨色**绘制。
///
/// 值刻意取 `#1F1F1F`——2026-09-17 之前这是唯一的笔色默认值（当时**没有取色器**，
/// 所有笔迹都是它），于是一个哨兵同时解决两件事：
/// 1. 新笔迹（[CanvasController.penColor] 默认即本值）自动跟随主题；
/// 2. **存量画布不需要任何迁移**就一起跟随——否则暗色下就是"黑墨画黑纸"：
///    画布底色随主题（暗色纸面 `#161616`），而 `#1F1F1F` 压在上面几乎不可识别
///    （2026-09-17 用户截图反馈）。
///
/// ⚠️ 未来加取色器时注意：用户手选的"黑"必须写成**别的值**（如 `#000000`），
/// 否则会被当成自适应墨色。
const Color kThemeInk = Color(0xFF1F1F1F);

/// 把笔迹的**存储色**解析成**实际绘制色**：[kThemeInk] → [ink]，其余原样。
///
/// 绘制侧三处（[CanvasController.pictureFor] 的录制、[InkPainter]、
/// 离屏栅格化）**必须**都经它取色——各写一份三元表达式迟早漂移。
Color resolveInk(Color strokeColor, Color ink) =>
    strokeColor == kThemeInk ? ink : strokeColor;

class InkStroke {
  InkStroke({
    String? id,
    this.version = 1,
    required this.color,
    required this.baseWidth,
    this.simulatePressure = true,
    List<InkPoint>? points,
  }) // ⚠️ 必须拷贝：调用方（如 JSON 载入、测试）传进来的常常是 const 列表，
    // 直接持有的话 [add] 会抛 "Cannot add to an unmodifiable list"
    // （`test/canvas_document_test.dart` 的抽稀用例抓出的）。
    : id = id ?? 'stroke-${_nextStrokeId++}',
       points = <InkPoint>[...?points];

  /// 抽稀阈值（世界单位）：小于它的移动直接丢弃。
  ///
  /// 借鉴 `flutter_drawing_board` 的 `minPointDistance`（它是屏幕 2px，我们
  /// 是世界单位）：点数量直接决定内存与重算成本，实测可省 30~50% 的点，
  /// 观感无损（小于半个笔宽的抖动本来就画不出来）。
  static const double minPointDistance = 0.75;

  final Color color;

  /// 基准笔宽（世界单位）。
  final double baseWidth;

  /// 无真压感时按速度模拟粗细（鼠标/触摸为 true，手写笔为 false）。
  final bool simulatePressure;

  /// 稳定 id：持久化/同步时按此引用，而非按实例（对齐 [CanvasItem.id]）。
  final String id;

  /// 版本号：任何属性变更 +1。当前笔迹提交后不可变，恒为 1；预留给同步。
  final int version;

  final List<InkPoint> points;

  ui.Path? _outline;
  Rect? _bounds;

  /// 包围盒（含半个笔宽外扩）：裁剪与擦除命中的粗筛依据。空笔迹为 null。
  Rect? get bounds => _bounds ??= _computeBounds();

  /// 追加一个点；被抽稀掉时返回 false（调用方可据此跳过重绘）。
  bool add(InkPoint point) {
    if (points.isNotEmpty) {
      final Offset delta = point.position - points.last.position;
      if (delta.distance < minPointDistance) return false;
    }
    points.add(point);
    _invalidate();
    return true;
  }

  void _invalidate() {
    _outline = null;
    _bounds = null;
  }

  Rect? _computeBounds() {
    if (points.isEmpty) return null;
    double left = points.first.position.dx;
    double top = points.first.position.dy;
    double right = left;
    double bottom = top;
    for (final InkPoint p in points) {
      final Offset o = p.position;
      if (o.dx < left) left = o.dx;
      if (o.dy < top) top = o.dy;
      if (o.dx > right) right = o.dx;
      if (o.dy > bottom) bottom = o.dy;
    }
    // 轮廓在骨架之外（最宽处 = baseWidth/2），命中与裁剪都要算上。
    final double pad = baseWidth / 2;
    return Rect.fromLTRB(left - pad, top - pad, right + pad, bottom + pad);
  }

  /// 世界坐标下的轮廓（缓存）。
  ui.Path get outline {
    final ui.Path? cached = _outline;
    if (cached != null) return cached;

    final List<Offset> outlinePoints = getStroke(
      <PointVector>[
        for (final InkPoint p in points)
          PointVector(p.position.dx, p.position.dy, p.pressure),
      ],
      options: StrokeOptions(
        size: baseWidth,
        thinning: 0.6,
        smoothing: 0.5,
        streamline: 0.5,
        simulatePressure: simulatePressure,
        isComplete: true,
      ),
    );

    final ui.Path path = ui.Path();
    if (outlinePoints.length >= 2) {
      path.moveTo(outlinePoints.first.dx, outlinePoints.first.dy);
      for (int i = 1; i < outlinePoints.length; i++) {
        path.lineTo(outlinePoints[i].dx, outlinePoints[i].dy);
      }
      path.close();
    } else if (outlinePoints.length == 1) {
      // 单点（轻点一下）：轮廓退化，画个圆点兜底。
      path.addOval(
        Rect.fromCircle(center: outlinePoints.first, radius: baseWidth / 2),
      );
    }
    return _outline = path;
  }

  /// 点是否落在这条笔迹上（擦除用）：先过包围盒（快），再逐段求距离。
  bool hitTest(Offset world, double radius) {
    final Rect? box = bounds;
    if (box == null) return false;
    if (!box.inflate(radius).contains(world)) return false;
    for (int i = 0; i < points.length - 1; i++) {
      if (_distanceToSegment(
            world,
            points[i].position,
            points[i + 1].position,
          ) <=
          radius + baseWidth / 2) {
        return true;
      }
    }
    return points.length == 1 &&
        (world - points.first.position).distance <= radius + baseWidth / 2;
  }

  /// 序列化（纯数据，不含已解码资源）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'version': version,
    'color': color.toARGB32(),
    'baseWidth': baseWidth,
    'simulatePressure': simulatePressure,
    'points': <List<double>>[
      for (final InkPoint p in points)
        <double>[p.position.dx, p.position.dy, p.pressure],
    ],
  };

  /// 反序列化：点列重建后轮廓按需重算（[outline] 懒加载）。
  factory InkStroke.fromJson(Map<String, dynamic> j) => InkStroke(
    id: j['id'] as String,
    version: j['version'] as int? ?? 1,
    color: Color(j['color'] as int),
    baseWidth: (j['baseWidth'] as num).toDouble(),
    simulatePressure: j['simulatePressure'] as bool? ?? true,
    points: <InkPoint>[
      for (final List<dynamic> p in (j['points'] as List))
        InkPoint(
          Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
          (p[2] as num).toDouble(),
        ),
    ],
  );

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final Offset ab = b - a;
    final double lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lenSq == 0) return (p - a).distance;
    double t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lenSq;
    t = t.clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }
}
