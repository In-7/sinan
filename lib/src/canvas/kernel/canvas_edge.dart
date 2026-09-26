import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// 连线的端口（吸附到卡片的哪条边）。
enum CanvasSide { top, right, bottom, left }

/// 连线**端点形状**（2026-09-18 新增，原只有终点箭头）。
///
/// 三种语义对齐主流标杆：箭头=因果/指向(tldraw/Excalidraw 默认)、圆点=无向关联
/// (JSON Canvas 的 `arrow-end` 之一)、菱形=分类/汇聚(流程图惯例)。`none` 即无标记。
/// 默认：**起点 none、终点 arrow**——与旧存档"只在终点画箭头"的观感一致，且
/// 不写进序列化（见 `CanvasEdge.toJson`），老画布静默回退 JSON 不受影响。
enum EdgeEndpointShape {
  none,
  arrow,
  dot,
  diamond;

  /// 名称 → 枚举；未知名/未知值返回 [default]，脏存档不该让整张画布打不开。
  static EdgeEndpointShape parse(
    Object? raw, {
    required EdgeEndpointShape defaultShape,
  }) {
    if (raw is! String) return defaultShape;
    for (final EdgeEndpointShape s in EdgeEndpointShape.values) {
      if (s.name == raw) return s;
    }
    return defaultShape;
  }
}

/// 起/终点形状的**缺省值**（刻意与旧行为一致）。
const EdgeEndpointShape _defaultStartShape = EdgeEndpointShape.none;
const EdgeEndpointShape _defaultEndShape = EdgeEndpointShape.arrow;

/// 边的 id 前缀（存档里 id 的形态：`edge-<递增序号>`）。
const String _edgeIdPrefix = 'edge-';

/// 边的 id 发生器。
///
/// ⚠️ 与 `CanvasItem` 的 id 一样是**进程级**计数器：存档里的 id 是上一个进程
/// 分配的，新进程从 0 开始 ⇒ 载入存档后**必须**用 [advanceEdgeIdSequence]
/// 把它推到已有 id 之后，否则新建边会分到与存档重复的 id。
int _nextEdgeId = 0;

/// 把 id 发生器推进到所有 [existingIds] 之后（载入存档后必做，见 [_nextEdgeId]）。
///
/// 只认 `edge-<数字>` 形式：其它形态（旧存档的自由 id）原样忽略，不影响正确性
/// ——它们只是不参与推进，唯一性由后续自增继续保证。与
/// `advanceItemIdSequence` 同一思路。
void advanceEdgeIdSequence(Iterable<String> existingIds) {
  for (final String id in existingIds) {
    if (!id.startsWith(_edgeIdPrefix)) continue;
    final int? seq = int.tryParse(id.substring(_edgeIdPrefix.length));
    if (seq != null && seq >= _nextEdgeId) _nextEdgeId = seq + 1;
  }
}

/// **自由连线**（v9）。
///
/// ## binding：存 **id 而不是坐标**
/// 这是"块结构画布"与"画画画布"的分水岭。端点位置**不落库**，而是运行时由两端
/// item 的**当前 rect** 推出（见 [CanvasEdges.geometryOf]）⇒ 拖走卡片连线自动
/// 跟随；卡片被删时，数据库侧由 `canvas_edges.from_id/to_id` 外键
/// `blocks(id) ON DELETE CASCADE` 让连线一并消失，运行时则是"找不到端点就不画"。
///
/// ## 只做自由连线
/// 思维导图是**树**，用 `blocks.parent_id` 表达即可（布局算法跑在 blocks 树上），
/// 不走这张表——两者各自用最合适的方案（2026-09-18 拍板）。
class CanvasEdge {
  CanvasEdge({
    String? id,
    required this.fromId,
    required this.toId,
    this.fromSide,
    this.toSide,
    this.startShape = _defaultStartShape,
    this.endShape = _defaultEndShape,
    Map<String, dynamic>? props,
  }) : id = id ?? '$_edgeIdPrefix${_nextEdgeId++}',
       props = props ?? const <String, dynamic>{};

  final String id;

  /// 起点卡片的 **`blocks.id`**（**不是** item id）。
  ///
  /// ⚠️ 用 blockId 而不是 item id，是为了与存储侧**同口径**：`canvas_edges.from_id`
  /// 外键 `blocks(id)`，于是卡片被删时连线随外键级联消失，两端不会漂移。
  /// 代价是内核要按它**反查** item（见 `CanvasDocument._itemByBlockId`）
  /// ——卡片数量少，这个遍历值得。
  final String fromId;

  /// 终点卡片的 `blocks.id`（同上）。
  final String toId;

  /// 起点端口；**null = 自动**（按两盒相对位置挑最短的一对，见 [CanvasEdges]）。
  final CanvasSide? fromSide;
  final CanvasSide? toSide;

  /// 起点形状（2026-09-18）；缺省 [EdgeEndpointShape.none]。
  final EdgeEndpointShape startShape;

  /// 终点形状（2026-09-18）；缺省 [EdgeEndpointShape.arrow]，与旧行为一致。
  final EdgeEndpointShape endShape;

  /// 扩展位（与 item 的 `meta` 同思路：渲染逻辑不感知，存样式等）。
  final Map<String, dynamic> props;

  /// ⚠️ 字段与**存储契约**逐项对齐（`data/canvas_store.dart`）：
  /// `fromSide` / `toSide` / `startShape` / `endShape` / `props` 缺省都**不写**
  /// （空值会让"行 ⇄ 原文"的深比较更容易失配）。端点形状与 item 的 `colorSlot`
  /// / `groupId` 同口径：**内核 JSON 里是顶层键**，落库时收进 `canvas_edges.
  /// props_json` 扩展位（不占任何新列、靠 `props_json` 往返）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'fromId': fromId,
    'toId': toId,
    if (fromSide != null) 'fromSide': fromSide!.name,
    if (toSide != null) 'toSide': toSide!.name,
    if (startShape != _defaultStartShape) 'startShape': startShape.name,
    if (endShape != _defaultEndShape) 'endShape': endShape.name,
    if (props.isNotEmpty) 'props': props,
  };

  factory CanvasEdge.fromJson(Map<String, dynamic> j) => CanvasEdge(
    id: j['id'] as String?,
    fromId: j['fromId'] as String? ?? '',
    toId: j['toId'] as String? ?? '',
    fromSide: _sideOf(j['fromSide']),
    toSide: _sideOf(j['toSide']),
    startShape: EdgeEndpointShape.parse(
      j['startShape'],
      defaultShape: _defaultStartShape,
    ),
    endShape: EdgeEndpointShape.parse(
      j['endShape'],
      defaultShape: _defaultEndShape,
    ),
    props:
        (j['props'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{},
  );

  /// 端口名 → 枚举；未知名返回 null（**不抛**，脏存档不该让整张画布打不开）。
  static CanvasSide? _sideOf(Object? raw) {
    if (raw is! String) return null;
    for (final CanvasSide s in CanvasSide.values) {
      if (s.name == raw) return s;
    }
    return null;
  }
}

/// 连线的**几何**换算：端口 → 世界坐标锚点 → 曲线控制点。
///
/// 全部是纯函数（只吃 rect，不碰文档），于是绘制、命中、导出都能共用。
abstract final class CanvasEdges {
  /// 端口在世界坐标中的位置；[side] 为 null 时取中心。
  static Offset anchorOf(Rect rect, CanvasSide? side) => switch (side) {
    CanvasSide.top => rect.topCenter,
    CanvasSide.right => rect.centerRight,
    CanvasSide.bottom => rect.bottomCenter,
    CanvasSide.left => rect.centerLeft,
    null => rect.center,
  };

  /// [side] 为 null 时**自动**选一对端口：按两盒中心的相对位置挑**跨度大的那个轴**
  /// （连线因此不会"绕到盒子背面"）。
  static (CanvasSide, CanvasSide) autoSides(Rect from, Rect to) {
    final double dx = to.center.dx - from.center.dx;
    final double dy = to.center.dy - from.center.dy;
    if (dx.abs() >= dy.abs()) {
      return dx >= 0
          ? (CanvasSide.right, CanvasSide.left)
          : (CanvasSide.left, CanvasSide.right);
    }
    return dy >= 0
        ? (CanvasSide.bottom, CanvasSide.top)
        : (CanvasSide.top, CanvasSide.bottom);
  }

  /// 一条边的两端锚点（世界坐标）。
  ///
  /// 任一端 rect 缺失（卡片被删 / 还没载入）⇒ 返回 null：**悬空边不画**。
  /// 这正是 binding 该有的行为——连线不是独立的内容，它依附于两端的卡片。
  ///
  /// 返回 [EdgeGeometry]（含两端**实际采用的**端口）——端口要留给绘制算控制点，
  /// 只回传两个点的画，自动选端口的结果就丢了。
  static EdgeGeometry? geometryOf(
    CanvasEdge edge,
    Rect? fromRect,
    Rect? toRect,
  ) {
    if (fromRect == null || toRect == null) return null;
    final (CanvasSide f, CanvasSide t) = switch ((edge.fromSide, edge.toSide)) {
      (final CanvasSide a, final CanvasSide b) => (a, b),
      // 只给了一个端口 ⇒ 另一个自动（尊重用户显式指定的那一个）。
      (final CanvasSide a, null) => (a, autoSides(fromRect, toRect).$2),
      (null, final CanvasSide b) => (autoSides(fromRect, toRect).$1, b),
      (null, null) => autoSides(fromRect, toRect),
    };
    return EdgeGeometry(
      from: anchorOf(fromRect, f),
      to: anchorOf(toRect, t),
      fromSide: f,
      toSide: t,
      startShape: edge.startShape,
      endShape: edge.endShape,
    );
  }

  /// 端口朝外的**单位方向**（控制点沿它外推，曲线才从端口"垂直"出发）。
  static Offset directionOf(CanvasSide side) => switch (side) {
    CanvasSide.top => const Offset(0, -1),
    CanvasSide.right => const Offset(1, 0),
    CanvasSide.bottom => const Offset(0, 1),
    CanvasSide.left => const Offset(-1, 0),
  };
}

/// 一条待绘制的连线（端点已算好，绘制层不再需要文档）。
class EdgeGeometry {
  const EdgeGeometry({
    required this.from,
    required this.to,
    required this.fromSide,
    this.toSide,
    this.startShape = _defaultStartShape,
    this.endShape = _defaultEndShape,
  });

  final Offset from;
  final Offset to;

  /// 两端端口（控制点按它外推）。[toSide] 为 null 仅用于**预览连线**
  /// （终点跟着光标走，没有真实卡片、故无端口）——见 [pendingEdgeGeometry]。
  final CanvasSide fromSide;
  final CanvasSide? toSide;

  /// 起点形状（2026-09-18）；缺省 [EdgeEndpointShape.none]。
  final EdgeEndpointShape startShape;

  /// 终点形状（2026-09-18）；缺省 [EdgeEndpointShape.arrow]。
  final EdgeEndpointShape endShape;

  /// 三次贝塞尔的路径：控制点沿端口方向外推，长度取**两端距离的一部分**
  /// （于是靠得近的卡片不会甩出夸张的弧线）。
  ui.Path path({double curvature = 0.4}) {
    final double d = (to - from).distance * curvature;
    final Offset c1 = from + CanvasEdges.directionOf(fromSide) * d;
    final Offset? c2 = toSide == null
        ? null
        : to + CanvasEdges.directionOf(toSide!) * d;
    final ui.Path p = ui.Path()..moveTo(from.dx, from.dy);
    if (c2 != null) {
      p.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, to.dx, to.dy);
    } else {
      // 预览连线：终点无端口，用与起点对称的控制点，得到自然的回弹弧。
      p.quadraticBezierTo(c1.dx, c1.dy, to.dx, to.dy);
    }
    return p;
  }

  /// 起点标记路径（按 [startShape] 决定形态；[EdgeEndpointShape.none] 返回空路径）。
  ///
  /// 尖端/中心在 [from]，朝外方向取 [fromSide] 端口朝外（总在卡片外侧、不被盖住）。
  ui.Path startMarkerPath({double size = 10}) =>
      _markerPath(from, CanvasEdges.directionOf(fromSide), startShape, size);

  /// 终点标记路径（按 [endShape] 决定形态；[EdgeEndpointShape.none] 返回空路径）。
  ///
  /// 尖端/中心在 [to]。[toSide] 非空时朝外方向恰是端口朝外；预览（[toSide] 空）
  /// 退化为"背离起点"，标记指向光标。
  ui.Path endMarkerPath({double size = 10}) => _markerPath(
    to,
    toSide != null ? CanvasEdges.directionOf(toSide!) : _outFromStart(),
    endShape,
    size,
  );

  /// 在 [tip] 处、朝 [out] 方向画一个端点标记（见 [EdgeEndpointShape]）。
  static ui.Path _markerPath(
    Offset tip,
    Offset out,
    EdgeEndpointShape shape,
    double size,
  ) {
    switch (shape) {
      case EdgeEndpointShape.none:
        return ui.Path();
      case EdgeEndpointShape.arrow:
        // 填充三角形：尖端在 tip，两翼沿"朝外"方向反向张开。
        const double spread = 0.42;
        final Offset a = tip + _rotate(out, spread) * size;
        final Offset b = tip + _rotate(out, -spread) * size;
        return ui.Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy)
          ..close();
      case EdgeEndpointShape.dot:
        // 实心圆点（无向关联）。
        return ui.Path()
          ..addOval(Rect.fromCenter(center: tip, width: size, height: size));
      case EdgeEndpointShape.diamond:
        // 菱形（流程图分类/汇聚）。
        final Offset a = tip + out * size;
        final Offset b = tip + _rotate(out, math.pi / 2) * size * 0.6;
        final Offset c = tip - out * size;
        final Offset d = tip - _rotate(out, math.pi / 2) * size * 0.6;
        return ui.Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy)
          ..lineTo(c.dx, c.dy)
          ..lineTo(d.dx, d.dy)
          ..close();
    }
  }

  /// 预览兜底：标记"朝外"方向 = 背离起点。
  Offset _outFromStart() {
    final Offset d = from - to;
    final double len = d.distance;
    return len == 0 ? const Offset(1, 0) : d / len;
  }

  static Offset _rotate(Offset v, double radians) {
    final double c = math.cos(radians);
    final double s = math.sin(radians);
    return Offset(v.dx * c - v.dy * s, v.dx * s + v.dy * c);
  }
}
