import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'canvas_ai.dart';
import 'canvas_media.dart';
import 'ink_stroke.dart';

/// item 的 id 前缀（存档里 id 的形态：`item-<递增序号>`）。
const String _itemIdPrefix = 'item-';

/// item 的 id 发生器（持久化与撤销命令的稳定引用）。
///
/// ⚠️ 它是**进程级**计数器：存档里的 id 是**上一个进程**分配的，新进程从 0 开始。
/// 因此载入存档后**必须**用 [advanceItemIdSequence] 把它推到已有 id 之后，
/// 否则新建元素会分到与存档重复的 id —— 而 `CanvasDocument.addItem` 是
/// `_items[id] = item` 的**覆盖**语义，旧元素会凭空消失。
/// （2026-09-17 修复：此前的表现是"存画布 → 重启 → 打开 → 新建形状 → 旧形状没了"。）
int _nextItemId = 0;

/// 把 id 发生器推进到所有 [existingIds] 之后。
///
/// 只认 `item-<数字>` 形式：其它形态（旧存档的自由 id、将来换方案）原样忽略，
/// 不影响正确性——它们只是不参与推进，而唯一性由后续自增继续保证。
void advanceItemIdSequence(Iterable<String> existingIds) {
  for (final String id in existingIds) {
    if (!id.startsWith(_itemIdPrefix)) continue;
    final int? seq = int.tryParse(id.substring(_itemIdPrefix.length));
    if (seq != null && seq >= _nextItemId) _nextItemId = seq + 1;
  }
}

/// JSON 矩形 `[left, top, right, bottom]` → [Rect]。
Rect _rectFromJson(List<dynamic> j) => Rect.fromLTRB(
  (j[0] as num).toDouble(),
  (j[1] as num).toDouble(),
  (j[2] as num).toDouble(),
  (j[3] as num).toDouble(),
);

/// 保存：运行时绝对路径 → 文档内**相对引用**（无 [media] 时原样写，保持旧行为）。
String _refOf(String src, MediaResolver? media) =>
    media == null || src.isEmpty ? src : media.toRef(src);

/// 载入：文档内引用 → 运行时**绝对路径**（旧存档里的绝对路径原样通过）。
String _pathOf(dynamic raw, MediaResolver? media) {
  final String src = raw as String? ?? '';
  return media == null || src.isEmpty ? src : media.toPath(src);
}

/// 画布 item：图片 / 形状这类"**少量大对象**"的基类。
///
/// ## 与笔迹的分工
/// 笔迹是画布里"量大"的一侧（一页几千条，走裁剪 + 显示列表 + 抽稀那套
/// 管线）；item 是"少量大"的一侧（几十个，每个自带命中与绘制）。文档里
/// 两条列表并存、互不进入对方的裁剪管线——架构文档 §三 的 item 层即此。
///
/// ## 坐标与可变性
/// [rect] 是世界坐标的轴对齐包围盒（**可变**）：拖动/缩放由控制器就地改，
/// 改动前后的快照由撤销命令持有（`CanvasDocument.setItemRects`）。绘制与
/// 命中都从 [rect] 推导，子类不存第二份几何。
///
/// ## z 序
/// item 画在笔迹**下方**（OneNote 口径：墨迹可以批注在图片上）。
abstract class CanvasItem {
  CanvasItem({
    String? id,
    required this.rect,
    this.angle = 0,
    this.meta = const <String, dynamic>{},
  }) : id = id ?? '$_itemIdPrefix${_nextItemId++}';

  final String id;

  /// 自由字段：AI 参数 / 业务标签挂这里，渲染逻辑不感知（schema v2 的 meta）。
  final Map<String, dynamic> meta;

  /// 世界坐标包围盒（轴对齐）。拖动/缩放就地更新。
  Rect rect;

  /// 旋转弧度（绕 [rect.center]）。默认 0（轴对齐）。
  double angle;

  /// 世界坐标 → 本地坐标（逆旋转，绕中心）。命中测试先转本地再算。
  Offset toLocal(Offset world) {
    if (angle == 0) return world;
    final Offset c = rect.center;
    final double dx = world.dx - c.dx;
    final double dy = world.dy - c.dy;
    final double cos = math.cos(-angle);
    final double sin = math.sin(-angle);
    return Offset(c.dx + dx * cos - dy * sin, c.dy + dx * sin + dy * cos);
  }

  /// 世界轴对齐包围盒：有旋转时返回旋转后的 AABB（供框选/导出/对齐）。
  Rect get bounds {
    if (angle == 0) return rect;
    final Offset c = rect.center;
    final double cos = math.cos(angle);
    final double sin = math.sin(angle);
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = -double.infinity;
    double maxY = -double.infinity;
    for (final Offset corner in CanvasHandles.corners(rect)) {
      final double dx = corner.dx - c.dx;
      final double dy = corner.dy - c.dy;
      final double x = c.dx + dx * cos - dy * sin;
      final double y = c.dy + dx * sin + dy * cos;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// 世界坐标命中测试（[radius] 为命中容差，世界单位）。
  bool hitTest(Offset world, double radius);

  /// 世界坐标下绘制自己（相机变换由调用方完成）。
  ///
  /// [ink] 是当前**主题墨色**：颜色等于哨兵 [kThemeInk] 的 item 按它绘制
  /// （见 [resolveInk]）。导出/AI 路径不传 ⇒ 走"白纸黑墨"的口径。
  void paint(ui.Canvas canvas, {Color? ink});

  /// 序列化为纯数据（不含 `ui.Image` 等运行时资源）。
  ///
  /// [media] 提供时，图片路径写成**相对引用**（可移植）；不传则保持旧行为
  /// （写绝对路径），使既有测试与调用方无需改动。
  Map<String, dynamic> toJson({MediaResolver? media});

  /// 释放运行时资源（如已解码的图片）；默认空实现。
  void dispose() {}

  /// 反序列化入口：按 `type` 分发到具体子类。
  static CanvasItem fromJson(Map<String, dynamic> j, {MediaResolver? media}) {
    switch (j['type']) {
      case 'shape':
        return ShapeItem.fromJson(j, media: media);
      case 'image':
        return ImageItem.fromJson(j, media: media);
      case 'aiImage':
        return AiImageItem.fromJson(j, media: media);
      default:
        throw ArgumentError('unknown canvas item type: ${j['type']}');
    }
  }
}

/// 形状种类。
enum CanvasShapeKind { rectangle, ellipse }

/// 形状样式的**纯值快照**：撤销命令持有"改动前 / 改动后"两份。
///
/// 与 `_ItemTransform` 同思路——命令只记**值**与 `id`，不持有实例引用，因此可
/// 序列化、可重放，也不会因为实例被替换（如 AI 重生节点）而失效。
class ShapeStyle {
  const ShapeStyle({
    required this.color,
    required this.strokeWidth,
    required this.filled,
  });

  final Color color;
  final double strokeWidth;
  final bool filled;
}

/// 矢量形状（矩形 / 椭圆）：空心描边或填充。
///
/// 样式（[color] / [strokeWidth] / [filled]）与 [rect] 一样是**可变**的：选中后由
/// 属性面板就地改，改动前后的值由 `CanvasDocument.setItemStyles` 的命令持有。
class ShapeItem extends CanvasItem {
  ShapeItem({
    super.id,
    required super.rect,
    super.angle,
    required this.kind,
    required this.color,
    this.strokeWidth = 2,
    this.filled = false,
    super.meta,
  });

  final CanvasShapeKind kind;

  /// 描边 / 填充色。**可变**（理由见类文档）。
  Color color;

  /// 描边宽（世界单位），空心时生效。**可变**（理由见类文档）。
  double strokeWidth;

  /// 是否填充。**可变**（理由见类文档）。
  bool filled;

  /// 当前样式的快照：改之前先取一份交给撤销命令。
  ShapeStyle get style =>
      ShapeStyle(color: color, strokeWidth: strokeWidth, filled: filled);

  /// 就地写回一份样式快照（撤销 / 重做走这里）。
  void applyStyle(ShapeStyle s) {
    color = s.color;
    strokeWidth = s.strokeWidth;
    filled = s.filled;
  }

  @override
  bool hitTest(Offset world, double radius) {
    final Offset local = toLocal(world);
    if (!rect.inflate(radius).contains(local)) return false;
    // 填充形状：盒内即命中。
    if (filled) return true;
    return switch (kind) {
      // 空心矩形：靠近四条边之一。
      CanvasShapeKind.rectangle => _nearRectEdge(local, radius),
      // 空心椭圆：归一化半径落在边带内（边带厚 [radius]，按平均半径近似——
      // 命中容差本来就是模糊量，不值得做精确的椭圆距离）。
      CanvasShapeKind.ellipse => _nearEllipseEdge(local, radius),
    };
  }

  bool _nearRectEdge(Offset world, double radius) {
    final bool withinX =
        world.dx >= rect.left - radius && world.dx <= rect.right + radius;
    final bool withinY =
        world.dy >= rect.top - radius && world.dy <= rect.bottom + radius;
    final bool nearVertical =
        (world.dx - rect.left).abs() <= radius ||
        (rect.right - world.dx).abs() <= radius;
    final bool nearHorizontal =
        (world.dy - rect.top).abs() <= radius ||
        (rect.bottom - world.dy).abs() <= radius;
    return (nearVertical && withinY) || (nearHorizontal && withinX);
  }

  bool _nearEllipseEdge(Offset world, double radius) {
    final double rx = rect.width / 2;
    final double ry = rect.height / 2;
    if (rx <= 0 || ry <= 0) return false;
    final Offset center = rect.center;
    final double nx = (world.dx - center.dx) / rx;
    final double ny = (world.dy - center.dy) / ry;
    final double r = math.sqrt(nx * nx + ny * ny);
    final double band = radius / ((rx + ry) / 2);
    return r >= 1 - band && r <= 1 + band;
  }

  @override
  void paint(ui.Canvas canvas, {Color? ink}) {
    // 哨兵色（[kThemeInk]，插入形状的默认色）⇒ 按当前主题墨色画：否则暗色画布上
    // 插入的矩形是近黑描边，又一个"黑墨画黑纸"。
    final ui.Paint paint = ui.Paint()..color = resolveInk(color, ink ?? color);
    if (!filled) {
      paint
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = strokeWidth;
    }
    switch (kind) {
      case CanvasShapeKind.rectangle:
        canvas.drawRect(rect, paint);
      case CanvasShapeKind.ellipse:
        canvas.drawOval(rect, paint);
    }
  }

  @override
  Map<String, dynamic> toJson({MediaResolver? media}) => <String, dynamic>{
    'type': 'shape',
    'id': id,
    'kind': kind.name,
    'color': color.toARGB32(),
    'strokeWidth': strokeWidth,
    'filled': filled,
    'angle': angle,
    'rect': <double>[rect.left, rect.top, rect.right, rect.bottom],
    'meta': meta,
  };

  factory ShapeItem.fromJson(Map<String, dynamic> j, {MediaResolver? media}) =>
      ShapeItem(
        id: j['id'] as String,
        rect: _rectFromJson(j['rect'] as List),
        angle: (j['angle'] as num?)?.toDouble() ?? 0,
        kind: CanvasShapeKind.values.byName(j['kind'] as String),
        color: Color(j['color'] as int),
        strokeWidth: (j['strokeWidth'] as num).toDouble(),
        filled: j['filled'] as bool? ?? false,
        meta: (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

/// 图片 item：持久化只存 [src]，运行时**懒加载**解码成 `ui.Image`
/// （见 [load]）——这样文档可序列化、可存档/重载/导出，且多张图不会一次性
/// 占满显存（Excalidraw 同款：element 是纯数据，图片单独管理）。
///
/// ## [src] 的两副面孔
/// - **运行时**：绝对路径（[load] 直接拿去读文件）；
/// - **落盘时**：若有 [MediaResolver]（见 `canvas_media.dart`），写成**相对引用**
///   ——于是同一份 JSON 换台机器（数据目录不同）依然找得到图。
///
/// 换算只发生在序列化边界（`toJson`/`fromJson`），内存里始终是绝对路径，
/// 绘制与加载路径无需感知。
class ImageItem extends CanvasItem implements ImageSink {
  ImageItem({
    super.id,
    required super.rect,
    super.angle,
    this.src = '',
    super.meta,
  });

  /// 图片的**运行时绝对路径**；落盘时由 `toJson` 换算成相对引用（见类文档）。
  /// 生成中的 AI 层可暂为空。
  String src;

  /// 运行时解码结果（**不序列化**）；加载完成前为 null，绘制时画占位框。
  ui.Image? _image;

  /// 是否已解码完成（用于懒加载去重与占位判断）。
  bool get loaded => _image != null;

  /// 已解码的图像；未加载/加载失败为 null。
  ///
  /// ⚠️ **只读**用途（如插入图片时按它算初始宽高比）：不要 dispose，所有权在本 item。
  ui.Image? get image => _image;

  bool _loading = false;

  /// 是否**已经试过**加载（含"src 为空 ⇒ 无从加载"与"读了但坏了"两种）。
  ///
  /// ⚠️ 少了它就是一个**无限重建**：`src` 为空时既不置 [_loading] 也不置 [_image]，
  /// 于是每次 rebuild 都会再进来一次 → [onLoaded] → `notifyListeners` → rebuild …
  /// 空转到底（AI 生成中的 item 正好是 `src` 为空；坏图则是反复读盘）。
  /// 2026-09-17 由形状属性面板的用例撞出来（"选中图片"那条直接 pumpAndSettle 超时）。
  bool _attempted = false;

  /// 懒加载：仅解码一次；完成后通过 [onLoaded] 通知重绘（如
  /// `controller.notifyListeners`）。[src] 读不到时静默失败（占位框保留），
  /// 不让单张坏图拖垮整页。
  ///
  /// **每个 item 只尝试一次**（见 [_attempted]）：失败或 `src` 为空都不再重试，
  /// 否则调用方"加载完就重绘"的写法会把这里变成无限循环。
  @override
  Future<void> load({required void Function() onLoaded}) async {
    if (_image != null || _loading || _attempted) return;
    _attempted = true;
    if (src.isEmpty) {
      // 尚在生成中（src 未定）或本地图缺失：保留占位框，不抛。
      onLoaded();
      return;
    }
    _loading = true;
    try {
      final Uint8List bytes = await File(src).readAsBytes();
      // 此 Flutter 版本 decodeImageFromList 为回调式（非 Future）。
      final Completer<ui.Image> completer = Completer<ui.Image>();
      ui.decodeImageFromList(bytes, completer.complete);
      _image = await completer.future;
      onLoaded();
    } on Object catch (_) {
      // 文件缺失/损坏：保留占位框，不抛。
    } finally {
      _loading = false;
    }
  }

  /// 直接注入已解码图像（AI 生成结果等不走文件路径的场景）。
  @override
  void setImage(ui.Image img) {
    _image?.dispose();
    _image = img;
    _loading = false;
  }

  /// 设定图片路径（网络后端生成完毕、落盘后调用）。
  @override
  void setSrc(String src) {
    this.src = src;
    // src 有值了 ⇒ 允许再试一次加载（此前那次可能是"src 还空着"的空转）。
    _attempted = false;
  }

  @override
  void dispose() {
    _image?.dispose();
    _image = null;
  }

  @override
  bool hitTest(Offset world, double radius) =>
      rect.inflate(radius).contains(toLocal(world));

  @override
  void paint(ui.Canvas canvas, {Color? ink}) {
    final ui.Image? img = _image;
    if (img == null) {
      // 占位：加载前也能看到框、能命中、能落账。颜色取**低透明度的主题墨色**
      // ——固定浅灰在暗色画布上比图本身还抢眼。
      canvas.drawRect(
        rect,
        ui.Paint()
          ..color = (ink ?? const Color(0xFFE0E0E0)).withValues(alpha: 0.18),
      );
      return;
    }
    final ui.Rect srcRect = ui.Rect.fromLTWH(
      0,
      0,
      img.width.toDouble(),
      img.height.toDouble(),
    );
    canvas.drawImageRect(
      img,
      srcRect,
      rect,
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
  }

  @override
  Map<String, dynamic> toJson({MediaResolver? media}) => <String, dynamic>{
    'type': 'image',
    'id': id,
    'angle': angle,
    'rect': <double>[rect.left, rect.top, rect.right, rect.bottom],
    'src': _refOf(src, media),
    'meta': meta,
  };

  factory ImageItem.fromJson(Map<String, dynamic> j, {MediaResolver? media}) =>
      ImageItem(
        id: j['id'] as String,
        rect: _rectFromJson(j['rect'] as List),
        angle: (j['angle'] as num?)?.toDouble() ?? 0,
        src: _pathOf(j['src'], media),
        meta: (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

/// AI 生成层：渲染/懒加载/命中/序列化**完全复用 [ImageItem]**，仅多带一份
/// 生成配方 [gen]（存"怎么生成的参数"而非只存像素——非破坏性迭代、分支比较）。
/// 生成中 [src] 为空 → 走 [ImageItem] 占位框；完成后由 [ImageSink.setImage]
/// 注入内存图（本地 stub）或 [ImageSink.setSrc]+[load]（网络后端落盘文件）。
class AiImageItem extends ImageItem {
  AiImageItem({
    super.id,
    required super.rect,
    super.angle,
    super.src,
    required this.gen,
    super.meta,
  });

  /// 生成配方（model / prompt / seed / inputs 等）。
  GenRecipe gen;

  @override
  Map<String, dynamic> toJson({MediaResolver? media}) => <String, dynamic>{
    'type': 'aiImage',
    'id': id,
    'angle': angle,
    'rect': <double>[rect.left, rect.top, rect.right, rect.bottom],
    'src': _refOf(src, media),
    'gen': gen.toJson(),
    'meta': meta,
  };

  factory AiImageItem.fromJson(
    Map<String, dynamic> j, {
    MediaResolver? media,
  }) => AiImageItem(
    id: j['id'] as String?,
    rect: _rectFromJson(j['rect'] as List),
    angle: (j['angle'] as num?)?.toDouble() ?? 0,
    src: _pathOf(j['src'], media),
    gen: GenRecipe.fromJson(j['gen'] as Map<String, dynamic>),
    meta: (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
  );
}

/// 选中 item 四角的缩放手柄。
enum CanvasHandle { topLeft, topRight, bottomLeft, bottomRight }

/// 手柄几何：绘制与命中的**屏幕像素**常量（不随缩放变化——手柄是交互件，
/// 世界坐标下忽大忽小没法点），以及角点拖拽的矩形推导。
abstract final class CanvasHandles {
  /// 手柄绘制半径（屏幕像素）。
  static const double radius = 4.5;

  /// 手柄命中半径（屏幕像素）。略大于绘制半径：宁可易中，不可难点。
  static const double hitRadius = 10;

  /// 缩放下限（世界单位）：拖过头时钳住，矩形不允许翻面。
  static const double minSize = 8;

  /// 世界坐标四角，顺序与 [CanvasHandle.values] 一致。
  static List<Offset> corners(Rect rect) => <Offset>[
    rect.topLeft,
    rect.topRight,
    rect.bottomLeft,
    rect.bottomRight,
  ];

  /// 屏幕坐标下的手柄命中；[cornersScreen] 即 [corners] 经相机变换后的四角。
  static CanvasHandle? hitTest(List<Offset> cornersScreen, Offset point) {
    for (int i = 0; i < cornersScreen.length; i++) {
      if ((cornersScreen[i] - point).distance <= hitRadius) {
        return CanvasHandle.values[i];
      }
    }
    return null;
  }

  /// 旋转手柄距顶边的屏幕像素（控制器 / 浮层共用，保持一致）。
  static const double rotateHandleDistance = 22;

  /// 旋转后的世界四角（顺序同 [corners]）。
  static List<Offset> rotatedCorners(Rect rect, double angle) {
    if (angle == 0) return corners(rect);
    final Offset c = rect.center;
    final double cos = math.cos(angle);
    final double sin = math.sin(angle);
    return <Offset>[
      for (final Offset o in corners(rect))
        Offset(
          c.dx + (o.dx - c.dx) * cos - (o.dy - c.dy) * sin,
          c.dy + (o.dx - c.dx) * sin + (o.dy - c.dy) * cos,
        ),
    ];
  }

  /// 旋转手柄的屏幕位置：顶边中点向上偏移 [rotateHandleDistance] 像素。
  static Offset rotationHandlePos(List<Offset> cornersScreen, double distance) {
    final Offset topMid = (cornersScreen[0] + cornersScreen[1]) / 2;
    return topMid - Offset(0, distance);
  }

  /// 旋转手柄命中（屏幕坐标）。
  static bool hitRotation(Offset rotPos, Offset point) =>
      (rotPos - point).distance <= hitRadius;

  /// 拖拽 [handle] 角到 [world] 后的新矩形：**保留 [angle]**（对角锚定，
  /// 边长不小于 [minSize]）。[angle] == 0 时退化为 [resize]。
  static Rect resizeRotated(
    Rect original,
    double angle,
    CanvasHandle handle,
    Offset world,
  ) {
    final Offset u = Offset(math.cos(angle), math.sin(angle)); // 本地 x 轴（世界方向）
    final Offset v = Offset(-math.sin(angle), math.cos(angle)); // 本地 y 轴
    final CanvasHandle opp = _opposite(handle);
    final Offset fixed = _rotatedCorner(original, angle, opp);
    final Offset d = world - fixed;
    double du = d.dx * u.dx + d.dy * u.dy;
    double dv = d.dx * v.dx + d.dy * v.dy;
    if (du.abs() < minSize) du = du.sign * minSize;
    if (dv.abs() < minSize) dv = dv.sign * minSize;
    final Offset newCenter = fixed + u * (du / 2) + v * (dv / 2);
    return Rect.fromCenter(
      center: newCenter,
      width: du.abs(),
      height: dv.abs(),
    );
  }

  /// 绕 [pivot] 缩放矩形（各角按 (sx, sy) 比例）。
  static Rect scaleAbout(Rect rect, Offset pivot, double sx, double sy) {
    final double left = pivot.dx + (rect.left - pivot.dx) * sx;
    final double right = pivot.dx + (rect.right - pivot.dx) * sx;
    final double top = pivot.dy + (rect.top - pivot.dy) * sy;
    final double bottom = pivot.dy + (rect.bottom - pivot.dy) * sy;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// 绕 [pivot] 旋转矩形（仅位置旋转，尺寸不变；[angle] 弧度）。
  static Rect rotateAbout(Rect rect, Offset pivot, double angle) {
    final Offset c = rect.center;
    final double cos = math.cos(angle);
    final double sin = math.sin(angle);
    final Offset nc = Offset(
      pivot.dx + (c.dx - pivot.dx) * cos - (c.dy - pivot.dy) * sin,
      pivot.dy + (c.dx - pivot.dx) * sin + (c.dy - pivot.dy) * cos,
    );
    return Rect.fromCenter(center: nc, width: rect.width, height: rect.height);
  }

  /// 拖动 [handle] 角到 [world] 后的新矩形（[angle] == 0 的便捷封装）。
  static Rect resize(Rect original, CanvasHandle handle, Offset world) =>
      resizeRotated(original, 0, handle, world);

  static CanvasHandle _opposite(CanvasHandle h) => switch (h) {
    CanvasHandle.topLeft => CanvasHandle.bottomRight,
    CanvasHandle.topRight => CanvasHandle.bottomLeft,
    CanvasHandle.bottomLeft => CanvasHandle.topRight,
    CanvasHandle.bottomRight => CanvasHandle.topLeft,
  };

  static Offset _corner(Rect rect, CanvasHandle h) => switch (h) {
    CanvasHandle.topLeft => rect.topLeft,
    CanvasHandle.topRight => rect.topRight,
    CanvasHandle.bottomLeft => rect.bottomLeft,
    CanvasHandle.bottomRight => rect.bottomRight,
  };

  static Offset _rotatedCorner(Rect rect, double angle, CanvasHandle h) {
    final Offset base = _corner(rect, h);
    if (angle == 0) return base;
    final Offset c = rect.center;
    final double cos = math.cos(angle);
    final double sin = math.sin(angle);
    final double dx = base.dx - c.dx;
    final double dy = base.dy - c.dy;
    return Offset(c.dx + dx * cos - dy * sin, c.dy + dx * sin + dy * cos);
  }
}
