import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'canvas_ai.dart';
import 'canvas_camera.dart';
import 'canvas_edge.dart';
import 'canvas_item.dart';
import 'canvas_palette.dart';
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
///
/// ## 2026-09-19 核实：`paint()` 里直接 `ui.Paint()` 是**已知且刻意不改**的
/// 通用建议是"别在 `paint()` 里创建 `Paint`"。这里没照做：真实画布规模
/// （实测 ≤ 31 个 item）下每帧几十个短命对象，对 Dart 分代 GC 无感；而改成
/// 复用实例要动几十处，且漏重置 `filterQuality` / `blendMode` 一类字段就会
/// 画错——收益趋零、风险实在。
///
/// 画布真正的量级风险是**笔迹条数**（几千条），不是 item 数；那条已由
/// 视口裁剪（只画 `visibleWorld` 内的）+ 笔迹烤成 `Picture` 兜住。
/// 若真遇到拖动掉帧，先去量笔迹层，不要从这里下手。
///
/// ## 2026-09-19 新增：LOD（细节分级）代理渲染
/// 视口裁剪只在"item 落在视口**外**"时有用；一旦**缩小**，`visibleWorld` 会
/// 包住整张画布 ⇒ 裁剪失效，每帧变成"全保真地画全部 item"（卡片建段落、图片
/// 采样、思维导图逐节点排字），块一多就掉帧。**这正是裁剪救不了的场景**。
///
/// 解法是对**小到看不清**的 item 改用代理绘制（[lodProxyScreenSize]）：只画
/// 一个身份色圆角块，跳过文本排版与图片采样，并**不触发** [onImageMissing]
/// （否则缩小时满屏图片会一起去解码整张原图）。放大回来自动恢复全保真。
///
/// ⚠️ [lod] **默认 false（全保真）**，只有实时视图传 true。导出 / AI 栅格化
/// （`canvas_raster.dart` 复用本 painter）必须以默认值调用——否则缩小的全图
/// 导出会输出一堆色块。这与 [staleColor] "只有界面传、导出不传"是同一约定。
class ItemPainter extends CustomPainter {
  const ItemPainter({
    required this.camera,
    this.inkColor = kThemeInk,
    this.items = const <CanvasItem>[],
    this.edges = const <EdgeGeometry>[],
    this.onImageMissing,
    this.staleColor,
    this.lod = false,
    this.lodScale,
    this.pinnedIds = const <String>{},
    this.stamp = 0,
  });

  /// LOD 阈值：item 的**屏幕短边**（世界短边 × 缩放）小于它就改用代理绘制。
  ///
  /// 取 20 逻辑像素：此时卡片内的 14pt 文本在任何常见卡片尺寸下都已 < 5px、
  /// 完全不可读，图片细节同样看不见 ⇒ 全保真绘制只剩成本没有信息。
  static const double lodProxyScreenSize = 20;

  final CanvasCamera camera;

  /// 当前**主题墨色**（同 [InkPainter.inkColor]）：哨兵色的 item 按它绘制。
  /// 默认值即哨兵，只对"没有主题"的离屏路径成立（导出/AI：白纸黑墨）。
  final Color inkColor;

  /// 待绘制的 item（应已按视口裁剪，见 `CanvasDocument.itemsIn`）。
  final List<CanvasItem> items;

  /// 待绘制的连线（端点**已算好**，见 `CanvasDocument.edgesIn`）。
  ///
  /// 放在 item 之前画 ⇒ 连线被卡片盖住端点，观感是"从卡片边缘长出来"。
  final List<EdgeGeometry> edges;

  /// 遇到未加载的图片 item 时回调（视图层据此触发懒加载）。
  final void Function(ImageItem)? onImageMissing;

  /// AI 层"输入已变、可重算"标记的颜色；null = 不画。
  ///
  /// 导出与栅格化都不传 ⇒ 标记**不会**进导出图、也不会进模型输入图。
  final Color? staleColor;

  /// 是否启用 **LOD 代理渲染**（见类文档）：小到看不清的 item 只画身份色块。
  ///
  /// 实时视图传 true；导出 / AI 栅格化**必须**保持默认 false——它们要的是
  /// 全保真像素，退化不得。
  final bool lod;

  /// LOD 判据用的**缩放**。`null` ⇒ 直接用 `camera.scale`。
  ///
  /// 实时视图传 `CanvasController.lodScale`（**稳定缩放**）：缩放进行中保持不变、
  /// 停稳后才跳一次。若直接跟 `camera.scale`，手势中途要付两笔代价——① item 沿途
  /// 在"色块 ⇄ 全保真"之间反复翻转（画面闪变）；② 每个跨过阈值的图片 item 会
  /// **立刻**触发 [onImageMissing] ⇒ 手势正忙时批量读盘 + 解码几十张原图。
  /// 导出 / 测试不传即可（一次性静态渲染，没有"手势进行中"这回事）。
  final double? lodScale;

  /// **必须保持全保真**的 item id（选中 / 编辑中的那些）。
  ///
  /// 照 tldraw 的硬规则「正在操作的东西必须可见」（它的 `getCulledShapes` 会把
  /// 选中 / 编辑中的形状从剔除集合里减掉）：否则一选中某张小卡片，它反而变成
  /// 一个色块，比不选中还难辨认。
  final Set<String> pinnedIds;

  /// 视觉状态版本号（见 `CanvasController.repaintStamp`）。拖拽/缩放/过期状态
  /// 都是**就地**改的，只有它能判定"这一帧与上一帧不同"。
  final int stamp;

  @override
  void paint(Canvas canvas, Size size) {
    if (items.isEmpty && edges.isEmpty) return;
    canvas.save();
    canvas.translate(camera.translation.dx, camera.translation.dy);
    canvas.scale(camera.scale);
    // 连线**先画**：它连的两端是卡片，端点被卡片盖住才自然（也避免线压在字上）。
    if (edges.isNotEmpty) {
      final Paint edgePaint = Paint()
        ..color = inkColor.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      // 箭头同色填充（缺口2：让"从哪连到哪"可见）。落在端口外侧，不被卡片盖住。
      final Paint arrowPaint = Paint()
        ..color = inkColor.withValues(alpha: 0.55)
        ..style = PaintingStyle.fill;
      for (final EdgeGeometry edge in edges) {
        canvas.drawPath(edge.path(), edgePaint);
        // 起点 / 终点各自按形状画标记（箭头/圆点/菱形/无）。`none` 返回空路径，
        // drawPath 是 no-op，无副作用。默认"起点无、终点箭头"与旧观感一致。
        if (edge.startShape != EdgeEndpointShape.none) {
          canvas.drawPath(edge.startMarkerPath(), arrowPaint);
        }
        if (edge.endShape != EdgeEndpointShape.none) {
          canvas.drawPath(edge.endMarkerPath(), arrowPaint);
        }
      }
    }
    // 分组框是**容器**，必须画在成员**下方**：先画 group 类型、再画其余，
    // 两组各自仍保持原 z 序（itemOrder 已保证内部顺序）。否则框会被自己的
    // 成员盖住、看不出"框住了一组"。
    final List<CanvasItem> ordered = <CanvasItem>[
      for (final CanvasItem item in items)
        if (item is CanvasGroupItem) item,
      for (final CanvasItem item in items)
        if (item is! CanvasGroupItem) item,
    ];
    for (final CanvasItem item in ordered) {
      // LOD：小到看不清的 item 只画身份色块，**先于** onImageMissing 返回 ⇒
      // 缩小时不会为满屏图片触发整图解码（放大回来自动恢复，见类文档）。
      if (_isProxy(item)) {
        _paintProxy(canvas, item, _slotColorOf(item));
        continue;
      }
      if (item is ImageItem && !item.loaded) {
        onImageMissing?.call(item);
      }
      // 逐 item 绕自身中心旋转绘制（rect 保持轴对齐本地坐标，旋转只在此处）。
      // 语义色槽位在这里**统一解析**（卡片/思维导图会用它，其余子类忽略）。
      final Color? slot = _slotColorOf(item);
      if (item.angle == 0) {
        item.paint(canvas, ink: inkColor, slotColor: slot);
      } else {
        canvas.save();
        final Offset center = item.rect.center;
        canvas.translate(center.dx, center.dy);
        canvas.rotate(item.angle);
        canvas.translate(-center.dx, -center.dy);
        item.paint(canvas, ink: inkColor, slotColor: slot);
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
      // 同一个 LOD 判据：小到看不见时，虚线框也只是噪声（还要几十条 drawLine）。
      if (_isProxy(item)) continue;
      final Rect box = Rect.fromPoints(
        camera.worldToScreen(item.bounds.topLeft),
        camera.worldToScreen(item.bounds.bottomRight),
      );
      _drawStaleMarker(canvas, box, stale);
    }
  }

  /// 该 item 这一帧是否走 **LOD 代理**（见类文档）。
  ///
  /// 两个"恒不代理"的例外：
  /// - [lod] 关（导出 / AI）⇒ 恒 false，全保真；
  /// - [pinnedIds] 里的（选中 / 编辑中）⇒ 恒 false，见该字段的文档。
  bool _isProxy(CanvasItem item) =>
      lod &&
      !pinnedIds.contains(item.id) &&
      isTooSmallForDetail(item, lodScale ?? camera.scale);

  /// 纯判据（与开关、钉住集合无关，故可单测）：item 在 [scale] 下是否**小到看不清**。
  ///
  /// - 形状排除在外：它本来就是单次 `drawRect` / `drawOval`，代理不掉成本，
  ///   而且空心形状画成实心色块会**改变语义**（看起来像填充了）。
  static bool isTooSmallForDetail(CanvasItem item, double scale) =>
      item is! ShapeItem && item.rect.shortestSide * scale < lodProxyScreenSize;

  /// 代理绘制：一个身份色圆角块，跳过文本排版 / 图片采样 / 旋转。
  ///
  /// 颜色口径与真实 item 一致（语义槽位优先，否则主题墨色），只是把淡染略微
  /// 加深——在这个尺度下太淡就整个消失了，而"能一眼看出这里有个块"才是 LOD
  /// 唯一要保留的信息。
  void _paintProxy(ui.Canvas canvas, CanvasItem item, Color? slotColor) {
    final bool marked = slotColor != null;
    final Color base = slotColor ?? inkColor;
    final RRect box = RRect.fromRectAndRadius(
      item.rect,
      const Radius.circular(CardMetrics.radius),
    );
    canvas.drawRRect(
      box,
      ui.Paint()..color = base.withValues(alpha: marked ? 0.18 : 0.08),
    );
    canvas.drawRRect(
      box,
      ui.Paint()
        ..color = base.withValues(alpha: marked ? 0.5 : 0.28)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  /// 两个 id 集合是否**同内容**（[pinnedIds] 每次构建都是新 Set，比身份恒不等）。
  ///
  /// 不用 `setEquals`：本文件刻意只依赖 `package:flutter/widgets.dart`（内核要能
  /// 在 material_ui / 官方 material 两套主题下复用），不为一个三行比较加 import。
  static bool _sameIds(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  /// item 的**语义色槽位 → 实色**（无槽位 = null ⇒ 子类回落到主题墨色）。
  ///
  /// 只有卡片与思维导图支持槽位，但基类给了统一的 [CanvasItem.colorSlot] 读写口，
  /// 所以这里不必 `is` 判断；"槽位 → 颜色"的映射也只有一处（[canvasSlotColor]）。
  static Color? _slotColorOf(CanvasItem item) {
    final CanvasColorSlot? slot = item.colorSlot;
    return slot == null ? null : canvasSlotColor(slot);
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
        canvas.drawLine(
          a + dir * t,
          a + dir * math.min(t + dash, total),
          paint,
        );
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
        oldDelegate.lod != lod ||
        oldDelegate.lodScale != lodScale ||
        !_sameIds(oldDelegate.pinnedIds, pinnedIds) ||
        oldDelegate.camera.scale != camera.scale ||
        oldDelegate.camera.translation != camera.translation ||
        oldDelegate.staleColor != staleColor) {
      return true;
    }
    // 下面的字段比较只在"两个 painter 拿到**不同**实例"时有效：视图每帧传给
    // 两个 painter 的是同一批 item 对象，比身份/几何等于和自己比 ⇒ 恒等。
    // 真正兜住就地修改（拖拽、stale 状态翻转）的是上面的 [stamp]。
    if (oldDelegate.items.length != items.length) return true;
    if (oldDelegate.edges.length != edges.length) return true;
    for (int i = 0; i < items.length; i++) {
      final CanvasItem before = oldDelegate.items[i];
      final CanvasItem after = items[i];
      if (before != after ||
          before.rect != after.rect ||
          before.angle != after.angle) {
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
    this.shapeDraft,
    this.shapeDraftKind,
    this.eraserCenter,
    this.eraserRadius,
    this.selectedItems = const <CanvasItem>[],
    this.pendingEdge,
    this.selectedEdge,
    this.stamp = 0,
  });

  final CanvasCamera camera;
  final Color color;

  /// 视觉状态版本号（见 `CanvasController.repaintStamp`）：框选矩形与选中框
  /// 都是就地变化的，只有它能判定重绘。
  final int stamp;

  /// 框选矩形（世界坐标）。
  final Rect? marquee;

  /// 形状工具拖拽中的预览框（世界坐标）；没在拖就是 null。
  final Rect? shapeDraft;

  /// 预览要画的形状种类（椭圆工具预览的就该是椭圆，而不是一个方框）。
  final CanvasShapeKind? shapeDraftKind;

  final Offset? eraserCenter;

  /// 橡皮半径（世界单位）。
  final double? eraserRadius;

  /// 选中的 item（世界坐标）。单选画旋转后的描边 + 四角/旋转手柄；
  /// 多选画并集包围盒 + 四角/旋转手柄（整体缩放/旋转）。
  final List<CanvasItem> selectedItems;

  /// 连线预览（世界几何）：连线工具拖动中，从起点卡片到光标的虚线。
  final EdgeGeometry? pendingEdge;

  /// 选中的连线（世界几何）：高亮重画一遍，提示"这条线被选中、可删除"。
  final EdgeGeometry? selectedEdge;

  @override
  void paint(Canvas canvas, Size size) {
    // 形状工具的预览：半透明填充 + 描边，与框选共用一套"临时框"视觉语言。
    // 预览形状必须与最终落下来的形状一致——不一致的话，拖的时候根本没法判断
    // 自己在画什么（椭圆尤其明显）。
    final Rect? draft = shapeDraft;
    if (draft != null) {
      final Rect screenRect = Rect.fromPoints(
        camera.worldToScreen(draft.topLeft),
        camera.worldToScreen(draft.bottomRight),
      );
      final ui.Paint fill = ui.Paint()..color = color.withValues(alpha: 0.10);
      final ui.Paint edge = ui.Paint()
        ..color = color
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1.5;
      if (shapeDraftKind == CanvasShapeKind.ellipse) {
        canvas.drawOval(screenRect, fill);
        canvas.drawOval(screenRect, edge);
      } else {
        canvas.drawRect(screenRect, fill);
        canvas.drawRect(screenRect, edge);
      }
    }

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
        final List<Offset> corners = CanvasHandles.rotatedCorners(
          item.rect,
          item.angle,
        ).map(camera.worldToScreen).toList(growable: false);
        _drawPolygon(canvas, corners, outline);
        for (final Offset c in corners) {
          _drawHandle(canvas, c, color);
        }
        final Offset topMid = (corners[0] + corners[1]) / 2;
        final Offset rot = CanvasHandles.rotationHandlePos(
          corners,
          CanvasHandles.rotateHandleDistance,
        );
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
          corners,
          CanvasHandles.rotateHandleDistance,
        );
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

    // 选中连线：在世界变换下重画一遍、加粗高亮（与正式连线同一路径，视觉连续）。
    final EdgeGeometry? sel = selectedEdge;
    if (sel != null) {
      _drawWorldPath(
        canvas,
        sel,
        ui.Paint()
          ..color = color
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 3,
      );
      _drawWorldArrow(
        canvas,
        sel,
        ui.Paint()
          ..color = color
          ..style = ui.PaintingStyle.fill,
      );
      // 两端端点把手（缺口4）：拖它可改接到另一张卡片。屏幕坐标画，大小恒定。
      _drawHandle(canvas, camera.worldToScreen(sel.from), color);
      _drawHandle(canvas, camera.worldToScreen(sel.to), color);
    }
    // 预览连线：从起点卡片到光标的虚线（世界变换下画，随缩放一致）。
    final EdgeGeometry? pend = pendingEdge;
    if (pend != null) {
      _drawDashedWorldPath(
        canvas,
        pend,
        ui.Paint()
          ..color = color
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      // 预览也画箭头，指出"会连到哪里"。
      _drawWorldArrow(
        canvas,
        pend,
        ui.Paint()
          ..color = color
          ..style = ui.PaintingStyle.fill,
      );
    }
  }

  /// 画闭合多边形（选中框）。
  ///
  /// 角点进来是**手柄枚举序**（`[左上, 右上, 左下, 右下]`），**不是绕序** ⇒
  /// 必须重排，否则画成"上边 + 两条对角线 + 下边"的蝴蝶结。见
  /// [CanvasHandles.orderForOutline]。
  void _drawPolygon(Canvas canvas, List<Offset> corners, ui.Paint paint) {
    if (corners.length < 3) return;
    final List<Offset> ordered = CanvasHandles.orderForOutline(corners);
    final ui.Path path = ui.Path()..moveTo(ordered[0].dx, ordered[0].dy);
    for (int i = 1; i < ordered.length; i++) {
      path.lineTo(ordered[i].dx, ordered[i].dy);
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

  void _drawRotateHandle(
    Canvas canvas,
    Offset rot,
    Offset topMid,
    Color color,
  ) {
    canvas.drawLine(
      topMid,
      rot,
      ui.Paint()
        ..color = color
        ..strokeWidth = 1,
    );
    canvas.drawCircle(rot, 5, ui.Paint()..color = const Color(0xFFFFFFFF));
    final ui.Paint border = ui.Paint()
      ..color = color
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(rot, 5, border);
  }

  /// 在世界变换下画一条连线几何（随相机缩放/平移，与正式连线视觉一致）。
  void _drawWorldPath(Canvas canvas, EdgeGeometry geo, ui.Paint paint) {
    canvas.save();
    canvas.translate(camera.translation.dx, camera.translation.dy);
    canvas.scale(camera.scale);
    canvas.drawPath(geo.path(), paint);
    canvas.restore();
  }

  /// 在世界变换下画连线两端标记（按各自形状，见 [EdgeEndpointShape]）。
  ///
  /// 选中高亮 / 预览连线都用它，于是高亮跟正式连线视觉一致（包括圆点 / 菱形）。
  void _drawWorldArrow(Canvas canvas, EdgeGeometry geo, ui.Paint paint) {
    canvas.save();
    canvas.translate(camera.translation.dx, camera.translation.dy);
    canvas.scale(camera.scale);
    if (geo.startShape != EdgeEndpointShape.none) {
      canvas.drawPath(geo.startMarkerPath(), paint);
    }
    if (geo.endShape != EdgeEndpointShape.none) {
      canvas.drawPath(geo.endMarkerPath(), paint);
    }
    canvas.restore();
  }

  /// 在世界变换下画**虚线**连线（预览）。
  void _drawDashedWorldPath(Canvas canvas, EdgeGeometry geo, ui.Paint paint) {
    final ui.Path path = geo.path();
    canvas.save();
    canvas.translate(camera.translation.dx, camera.translation.dy);
    canvas.scale(camera.scale);
    const double dash = 8;
    const double gap = 6;
    for (final ui.PathMetric m in path.computeMetrics()) {
      double d = 0;
      while (d < m.length) {
        final double next = (d + dash).clamp(0, m.length);
        final ui.Offset a = m.getTangentForOffset(d)!.position;
        final ui.Offset b = m.getTangentForOffset(next)!.position;
        canvas.drawLine(a, b, paint);
        d = next + gap;
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(OverlayPainter oldDelegate) {
    if (oldDelegate.stamp != stamp ||
        oldDelegate.marquee != marquee ||
        oldDelegate.shapeDraft != shapeDraft ||
        oldDelegate.shapeDraftKind != shapeDraftKind ||
        oldDelegate.eraserCenter != eraserCenter ||
        oldDelegate.eraserRadius != eraserRadius ||
        oldDelegate.camera.translation != camera.translation ||
        oldDelegate.camera.scale != camera.scale ||
        oldDelegate.pendingEdge != pendingEdge ||
        oldDelegate.selectedEdge != selectedEdge) {
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
