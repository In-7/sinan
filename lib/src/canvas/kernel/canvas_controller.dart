import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter/widgets.dart';

import 'canvas_ai.dart';
import 'canvas_camera.dart';
import 'canvas_document.dart';
import 'canvas_edge.dart';
import 'canvas_item.dart';
import 'canvas_media.dart';
import 'canvas_palette.dart';
import 'canvas_raster.dart';
import 'ink_stroke.dart';

/// 工具状态机：每种工具的「按下」行为抽成独立处理器（见 `canvas_tool_handler.dart`）。
part 'canvas_tool_handler.dart';

/// 变换手势类型：四角缩放 / 旋转。
enum _GripKind { corner, rotate }

/// 手势起点快照（落账时比对 rect + angle）。
class _TransformStart {
  _TransformStart(this.item, this.rect, this.angle);

  final CanvasItem item;
  final Rect rect;
  final double angle;
}

/// 多个 item 的世界并集包围盒。
Rect _unionBounds(List<CanvasItem> items) {
  Rect result = items.first.bounds;
  for (int i = 1; i < items.length; i++) {
    result = result.expandToInclude(items[i].bounds);
  }
  return result;
}

/// 当前工具。
enum CanvasTool {
  /// 笔（压感或模拟压感）。
  pen,

  /// 橡皮（整条笔迹擦除）。
  eraser,

  /// 框选（选中后可整体删除 / 后续移动）。
  select,

  /// 抓手（平移视图）。
  pan,

  /// 画形状：**按住拖拽定尺寸**；点一下则落一个默认大小。
  ///
  /// 它存在的直接原因是实测反馈——"点'矩形'只插入一个固定大小、还立刻切回框选，
  /// 于是拖出来的是框选，矩形工具像假的"。只提供"插入一个矩形"不算一个**工具**：
  /// 用户要的是"用当前笔刷画个框"。
  shape,

  /// 连线（v9）：选工具后从一个**卡片**拖到另一个**卡片**，松手即建一条
  /// [CanvasEdge]（端点存 blockId，binding）。点已有连线则选中它（再 Delete 删除）。
  /// 只连卡片——连线端点存 blockId，与 `canvas_edges.from_id` 外键同口径；
  /// 形状/图片没有 blockId，连了也画不出来（见 `CanvasEdge.fromId`）。
  connect,
}

/// 画布控制器：相机 + 文档 + 工具状态 + **输入流水线**。
///
/// ## 为什么用裸 [Listener] 而不是 GestureDetector
/// 手写需要 `PointerEvent` 的 **pressure / pressureMin·Max / kind / size**
/// （压感、笔的橡皮端、手掌接触面），这些 GestureDetector 的手势回调里
/// 拿不全；而且"笔=画、鼠标=选择、中键/空格=平移、滚轮=平移·Ctrl+滚轮=缩放"
/// 这套桌面语义必须自己裁决手势竞争（官方手势栈的竞技场裁决不了）。
///
/// ## 掌拒（palm rejection）
/// 两条判据照 `flutter_drawing_board` 的实测值：接触面 > [_palmSize]
/// 判为手掌；100ms 内连续落下的第二根手指也判为手掌（手已放在屏上）。
class CanvasController extends ChangeNotifier {
  CanvasController({
    CanvasCamera? camera,
    CanvasDocument? document,
    this.generator = const LocalStubGenerator(),
  }) : camera = camera ?? CanvasCamera(),
       document = document ?? CanvasDocument();

  final CanvasCamera camera;
  final CanvasDocument document;

  /// AI 生成器（依赖倒置）：默认离线桩，可替换为网络后端。
  final AiGenerator generator;

  // ───────────────────────── 工具与笔刷状态 ─────────────────────────

  /// 默认"选择"：2026-09-18 砍掉笔迹入口后，默认**不再是画笔**——否则一进画布
  /// 左键拖拽就是在画画（用户看不到任何笔迹工具，却画出了线）。
  CanvasTool tool = CanvasTool.select;

  /// 笔宽（世界单位）。
  double penWidth = 4;

  /// 当前笔色。默认 [kThemeInk]——**哨兵**而非具体色，于是新笔迹自动跟随主题
  /// （画布底色随主题，墨色不跟就会"黑墨画黑纸"）。
  Color penColor = kThemeInk;

  /// 橡皮半径（世界单位）。
  double eraserRadius = 8;

  /// AI 生成提示词（由宿主页面绑定输入框设置；内核保持 Material-free）。
  String aiPrompt = '';

  /// 空白处是否按空格临时切抓手（由页面按键状态驱动）。
  bool spacePanning = false;

  // ───────────────────────── 交互中的临时状态 ─────────────────────────

  Size _viewport = Size.zero;
  Size get viewport => _viewport;

  InkStroke? _activeStroke;
  InkStroke? get activeStroke => _activeStroke;

  Rect? _marquee;
  Rect? get marquee => _marquee;

  /// 形状工具当前要画的种类（由插入面板选定）。
  CanvasShapeKind _shapeKind = CanvasShapeKind.rectangle;
  CanvasShapeKind get shapeKind => _shapeKind;

  /// 形状工具**拖拽中的预览框**（世界坐标）；没在拖就是 null。
  Rect? _shapeDraft;
  Rect? get shapeDraft => _shapeDraft;

  /// 本次形状拖拽的起点（世界坐标 + 屏幕坐标）。屏幕那份用来判定"这是点还是拖"
  /// ——世界位移随缩放变化，当阈值不可靠。
  Offset? _shapeStartWorld;
  Offset? _shapeStartScreen;

  final List<InkStroke> _selection = <InkStroke>[];
  List<InkStroke> get selection => List<InkStroke>.unmodifiable(_selection);

  /// 选中的 item（与笔迹选区并存；框选同时收两者）。
  final List<CanvasItem> _selectedItems = <CanvasItem>[];
  List<CanvasItem> get selectedItems =>
      List<CanvasItem>.unmodifiable(_selectedItems);

  /// 是否有任何选区（页面据此显示删除按钮）。连线选中（[selectedEdge]）也算。
  bool get hasSelection =>
      _selection.isNotEmpty || _selectedItems.isNotEmpty || _selectedEdge != null;

  /// 当前唯一选中的**卡片**（块可迁移 #5 用：把这张卡片发回它的文档）。
  /// 不是恰好一张卡片选中、或选中的不是卡片则返回 null。
  CardItem? get selectedCard {
    if (_selectedItems.length != 1) return null;
    final CanvasItem item = _selectedItems.single;
    return item is CardItem ? item : null;
  }

  /// 把选中的卡片**从画布移除**（内存），并返回它的 `blockId`（供上层把块迁回文档）。
  ///
  /// 只做内存侧：卡片摘除 + 选区清空 + 通知。块内容"搬去文档"的持久化由上层
  /// （持有 [NoteStore] 的宿主）用 `blockId` 调 [NoteStore.moveBlockToDocument] 完成——
  /// 控制器刻意不碰数据库（见 `CanvasController` 类注释的 DB 隔离）。
  /// 没有选中卡片则返回 null、不动任何状态。
  String? detachSelectedCard() {
    final CardItem? card = selectedCard;
    if (card == null) return null;
    document.removeItems(<CanvasItem>[card]);
    _selectedItems.clear();
    _selection.clear();
    notifyListeners();
    return card.blockId;
  }

  /// 当前选区的世界包围盒（进行中的框选 + 已选中的 item / 笔迹），无选区返回 null。
  /// UI 的"生成"按钮据此定位并判断是否有有效选区。
  Rect? get selectionBounds {
    Rect? result;
    if (_marquee != null) result = _marquee!;
    for (final CanvasItem item in _selectedItems) {
      result = result == null
          ? item.bounds
          : result.expandToInclude(item.bounds);
    }
    for (final InkStroke stroke in _selection) {
      final Rect? b = stroke.bounds;
      if (b == null) continue;
      result = result == null ? b : result.expandToInclude(b);
    }
    return result;
  }

  /// 橡皮光标位置（世界坐标），仅橡皮工具下维护。
  Offset? _eraserAt;
  Offset? get eraserAt => _eraserAt;

  // ───────────────────────── 连线（交互中 + 选中） ─────────────────────────

  /// 连线工具下，拖动起点卡片（[onPointerUp] 命中另一张卡片才落账）。
  CanvasItem? _pendingFrom;

  /// 连线预览的当前光标世界坐标（随 pointer move 更新）。
  Offset? _pendingCursor;

  /// 当前选中的连线（点已有连线选中；Delete 删除）。
  CanvasEdge? _selectedEdge;

  /// 选中的连线（世界几何，供浮层高亮）。
  CanvasEdge? get selectedEdge => _selectedEdge;

  /// 预览连线（世界几何）：从起点卡片朝向光标的端口 → 光标点。
  /// 仅在连线工具拖动中非空。
  EdgeGeometry? get pendingEdgeGeometry {
    final CanvasItem? from = _pendingFrom;
    final Offset? cursor = _pendingCursor;
    if (from == null || cursor == null) return null;
    // 起点端口由**按下位置**决定（缺口1）；缺省才回落到"朝向光标"。
    final CanvasSide side = _pendingFromSide ?? _sideTowards(from.rect, cursor);
    return EdgeGeometry(
      from: CanvasEdges.anchorOf(from.rect, side),
      to: cursor,
      fromSide: side,
    );
  }

  /// 选中连线的世界几何（供浮层高亮）。
  EdgeGeometry? get selectedEdgeGeometry {
    final CanvasEdge? e = _selectedEdge;
    if (e == null) return null;
    final CanvasItem? from = document.itemByBlockId(e.fromId);
    final CanvasItem? to = document.itemByBlockId(e.toId);
    if (from == null || to == null) return null;
    return CanvasEdges.geometryOf(e, from.rect, to.rect);
  }

  /// 连线命中容差（**屏幕像素**，使用时换算成世界单位）。
  static const double _edgeHitTolerance = 6;

  /// 矩形哪条边最朝向 [point]（连线起点端口的选择）。
  static CanvasSide _sideTowards(Rect rect, Offset point) {
    final double dx = point.dx - rect.center.dx;
    final double dy = point.dy - rect.center.dy;
    if (dx.abs() >= dy.abs()) {
      return dx >= 0 ? CanvasSide.right : CanvasSide.left;
    }
    return dy >= 0 ? CanvasSide.bottom : CanvasSide.top;
  }

  /// 端口对边（端点拖改的预览用：活动端沿用固定端口的**反向**）。
  static CanvasSide _opposite(CanvasSide s) => switch (s) {
    CanvasSide.top => CanvasSide.bottom,
    CanvasSide.bottom => CanvasSide.top,
    CanvasSide.left => CanvasSide.right,
    CanvasSide.right => CanvasSide.left,
  };

  /// 端口"边缘带"宽度（**屏幕像素**）：按下/松开落在距某条边这么近的位置，
  /// 就**手动指定**那条边；落在卡片中部则返回 null（交给自动选端口）。
  static const double _portZoneTolerance = 28;

  /// [point] 落在 [rect] 边缘带内 ⇒ 返回那条边；落在中部/外部 ⇒ null（自动）。
  CanvasSide? _portAt(Rect rect, Offset point) {
    final double zone = _edgeZoneOf(rect);
    final double dLeft = point.dx - rect.left;
    final double dRight = rect.right - point.dx;
    final double dTop = point.dy - rect.top;
    final double dBottom = rect.bottom - point.dy;
    final double d = math.min(math.min(dLeft, dRight), math.min(dTop, dBottom));
    if (d < 0 || d > zone) return null;
    if (d == dLeft) return CanvasSide.left;
    if (d == dRight) return CanvasSide.right;
    if (d == dTop) return CanvasSide.top;
    return CanvasSide.bottom;
  }

  /// 边缘带宽度（世界单位）：随缩放保持屏幕观感一致，并封顶到卡片短边的 1/3，
  /// 免得小卡片上四条带叠在一起、方向失去意义。
  double _edgeZoneOf(Rect rect) {
    final double zone = camera.toWorld(_portZoneTolerance);
    final double cap = rect.shortestSide / 3;
    return zone < cap ? zone : cap;
  }

  /// 连线工具下，起点卡片上**按下位置**决定的起始端口（"从哪条边拉出"，缺口1）。
  CanvasSide? _pendingFromSide;

  /// 端点拖改（缺口4）：正在拖的连线、拖的是哪一端、当前光标世界坐标。
  CanvasEdge? _edgeGripEdge;
  bool _edgeGripIsFrom = false;
  Offset? _edgeGripCursor;

  /// 端点把手命中容差（**屏幕像素**）。
  static const double _edgeGripTolerance = 9;

  /// 端点拖改预览（世界几何，虚线）：固定另一端，活动端跟光标。
  /// 非拖动中返回 null。
  EdgeGeometry? get edgeGripPreview {
    final CanvasEdge? edge = _edgeGripEdge;
    final Offset? cursor = _edgeGripCursor;
    if (edge == null || cursor == null) return null;
    final CanvasItem? from = document.itemByBlockId(edge.fromId);
    final CanvasItem? to = document.itemByBlockId(edge.toId);
    if (from == null || to == null) return null;
    final (CanvasSide, CanvasSide) auto =
        CanvasEdges.autoSides(from.rect, to.rect);
    if (_edgeGripIsFrom) {
      final CanvasSide ts = edge.toSide ?? auto.$2;
      return EdgeGeometry(
        from: cursor,
        to: CanvasEdges.anchorOf(to.rect, ts),
        fromSide: _opposite(ts),
        toSide: ts,
      );
    }
    final CanvasSide fs = edge.fromSide ?? auto.$1;
    return EdgeGeometry(
      from: CanvasEdges.anchorOf(from.rect, fs),
      to: cursor,
      fromSide: fs,
      toSide: _opposite(fs),
    );
  }

  int? _activePointer;
  int? _panPointer;
  Offset? _panLast;
  Offset? _marqueeStart;
  bool _erasing = false;
  DateTime? _lastTouchDown;

  // item 拖动 / 缩放的交互中状态：
  // 拖动 = 起点快照（多选一起动），缩放 = 单选 + 被拖的角。
  Offset? _moveStartWorld;
  Map<CanvasItem, Rect>? _moveStartRects;
  CanvasHandle? _resizeHandle; // 单选四角缩放
  Rect? _resizeStartRect;
  double _resizeStartAngle = 0;

  // 多选整体缩放 / 旋转手势状态：
  _GripKind? _gripKind;
  Rect? _groupStartRect; // 多选整体缩放的起始并集框
  Offset? _gripFixedCorner; // 缩放锚定的对角（世界）
  Offset? _gripStartCorner; // 被拖动角（世界）
  Offset? _gripGroupCenter; // 旋转中心（世界）
  double? _gripStartPointerAngle; // 旋转起点指针角
  List<_TransformStart>? _transformStarts; // 所有选中 item 的起点

  /// 掌拒：接触面阈值（逻辑像素），实测值来自
  /// `flutter_drawing_board`（它用 `size > 15` 判手掌）。
  static const double palmSize = 15;

  /// 掌拒：连续落指的时间窗。
  static const Duration palmWindow = Duration(milliseconds: 100);

  ui.Picture? _picture;
  int _pictureRevision = -1;

  /// 录上面那张 Picture 时用的**墨色**（见 [pictureFor]）：主题明暗切换会换墨色，
  /// 颜色是**烤进显示列表**的，不比对它就会继续画旧墨色。
  Color? _pictureInk;

  /// 已完笔迹的合成显示列表（世界坐标）；**内容与墨色都没变就复用**
  /// （平移/缩放与**书写中**都不重录，这正是缓存的意义）。
  ///
  /// L1 性能件（见 `docs/canvas_architecture.md`）：把**全部**已完笔迹按世界坐标
  /// 录成一张 `ui.Picture`，书写时只额外重绘 `activeStroke` + 这张 Picture
  /// （代替每帧重绘可见笔迹）；平移/缩放也只需 `drawPicture` 一次。
  /// Picture 是**显示列表**而非位图 ⇒ 换缩放下重放仍是矢量清晰度。
  /// 空文档返回一张空 Picture（`drawPicture` 等于无操作），调用方无需特判。
  ///
  /// [ink] 由宿主按主题给（内核不读 Theme，见 [kThemeInk] 的自适应规则）。
  ui.Picture? pictureFor(Color ink) {
    if (_picture != null &&
        _pictureRevision == document.revision &&
        _pictureInk == ink) {
      return _picture;
    }
    _picture?.dispose();
    _picture = recordPicture(ink: ink);
    _pictureRevision = document.revision;
    _pictureInk = ink;
    return _picture;
  }

  /// 按**指定墨色**把全部已完笔迹录成一张 Picture（世界坐标）。
  ///
  /// 颜色等于 [kThemeInk] 的笔迹按 [ink] 绘制，其余按各自存储色（见 [resolveInk]）。
  /// **所有权归调用方**：导出与 AI 输入要的是"白底黑墨"、与界面主题无关，故各自
  /// 用 [kThemeInk] 录一张、用完 `dispose()`——直接复用界面的缓存会在暗色下把
  /// 浅墨导到白底上（白底白墨 = 一张空图）。
  ui.Picture recordPicture({required Color ink}) {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    for (final InkStroke stroke in document.strokes) {
      canvas.drawPath(
        stroke.outline,
        ui.Paint()..color = resolveInk(stroke.color, ink),
      );
    }
    return recorder.endRecording();
  }

  void setViewport(Size size) {
    if (_viewport == size) return;
    _viewport = size;
    notifyListeners();
  }

  void setTool(CanvasTool value) {
    if (tool == value) return;
    tool = value;
    _eraserAt = null;
    _selection.clear();
    _selectedItems.clear();
    _selectedEdge = null;
    _pendingFrom = null;
    _pendingCursor = null;
    _pendingFromSide = null;
    _edgeGripEdge = null;
    _edgeGripCursor = null;
    notifyListeners();
  }

  /// 进入形状工具（插入面板的"矩形 / 椭圆"调它）。
  ///
  /// 与"直接落一个图形"的区别：**不立刻落图形**，而是让接下来的拖拽去定尺寸
  /// ——这才像个工具（见 [CanvasTool.shape] 的说明）。
  void setShapeTool(CanvasShapeKind kind) {
    _shapeKind = kind;
    setTool(CanvasTool.shape);
  }

  void setSpacePanning(bool value) {
    if (spacePanning == value) return;
    spacePanning = value;
    notifyListeners();
  }

  /// 换笔色（[kThemeInk] = 跟随主题，见该常量）。
  ///
  /// 三个笔刷 setter 都要 `notifyListeners`：工具条上的"当前墨色"圆点靠它刷新
  /// ——只改字段的话用户改完颜色看不到任何反馈。
  void setPenColor(Color value) {
    if (penColor == value) return;
    penColor = value;
    notifyListeners();
  }

  /// 换笔宽（世界单位）。夹在 `1~24`：0 画不出东西，过大则一笔盖满整屏。
  void setPenWidth(double value) {
    final double next = value.clamp(1, 24);
    if (penWidth == next) return;
    penWidth = next;
    notifyListeners();
  }

  /// 换橡皮半径（世界单位），夹在 `4~48`（理由同 [setPenWidth]）。
  void setEraserRadius(double value) {
    final double next = value.clamp(4, 48);
    if (eraserRadius == next) return;
    eraserRadius = next;
    notifyListeners();
  }

  void undo() {
    document.undo();
    refreshStaleness();
    _pruneEdgeSelection();
    notifyListeners();
  }

  void redo() {
    document.redo();
    refreshStaleness();
    _pruneEdgeSelection();
    notifyListeners();
  }

  /// 选中的连线若已不在文档（撤销/重做把它删了）⇒ 清掉——否则浮层会画出
  /// 一条**幽灵高亮**（普通连线已没了，高亮还在），且删除按钮会误显示。
  void _pruneEdgeSelection() {
    final CanvasEdge? e = _selectedEdge;
    if (e == null) return;
    if (!document.edges.any((CanvasEdge other) => other.id == e.id)) {
      _selectedEdge = null;
    }
  }

  /// 缩放（[focal] 缺省取视口中心）。
  void zoomBy(double factor, {Offset? focal}) {
    camera.zoomAt(focal ?? _viewport.center(Offset.zero), factor);
    notifyListeners();
  }

  /// 重置缩放为 **100%**（视口中心不动）。工具栏的倍数徽标点一下就回到这里。
  void resetZoom() {
    camera.setScaleAt(_viewport.center(Offset.zero), 1.0);
    notifyListeners();
  }

  /// 适应内容：把所有笔迹装进视口。
  void fitToContent() {
    final Rect? bounds = document.bounds;
    if (bounds == null) return;
    camera.fit(bounds, _viewport);
    notifyListeners();
  }

  /// 改**所选形状**的样式（属性面板的唯一入口）。一次调用 = 一条撤销命令。
  ///
  /// 只作用于选中的 [ShapeItem]（笔迹与图片没有这个面板）。参数传 null 表示
  /// "这一项不动"——改色时不该顺带把粗细重置回默认值。
  ///
  /// 值没真变时不记命令（`setItemStyles` 内部按差异过滤），所以拖滑杆不会把
  /// 撤销栈刷满。
  void updateSelectedShapeStyle({
    Color? color,
    double? strokeWidth,
    bool? filled,
  }) {
    final List<(ShapeItem, ShapeStyle)> changes = <(ShapeItem, ShapeStyle)>[];
    for (final CanvasItem item in _selectedItems) {
      if (item is! ShapeItem) continue;
      final ShapeStyle before = item.style;
      item.applyStyle(
        ShapeStyle(
          color: color ?? before.color,
          // 只在**显式传入**时钳制：老存档里的越界值不该因为改个颜色被改掉。
          strokeWidth: strokeWidth == null
              ? before.strokeWidth
              : strokeWidth.clamp(1, 24),
          filled: filled ?? before.filled,
        ),
      );
      changes.add((item, before));
    }
    if (changes.isEmpty) return;
    document.setItemStyles(changes);
    notifyListeners();
  }

  /// 给选中的 item 设置**语义色槽位**（一次操作 = 一条撤销命令）。
  ///
  /// 只有卡片与思维导图支持槽位（覆盖了基类的读写口）；选中的形状/图片会被基类的
  /// 空 setter 忽略，不影响它们自己的颜色面板。`null` = 回到"跟随主题"。
  void setSelectedColorSlot(CanvasColorSlot? slot) {
    if (_selectedItems.isEmpty) return;
    final List<(CanvasItem, CanvasColorSlot?)> changes =
        <(CanvasItem, CanvasColorSlot?)>[];
    for (final CanvasItem item in _selectedItems) {
      final CanvasColorSlot? before = item.colorSlot;
      if (before == slot) continue;
      item.colorSlot = slot;
      changes.add((item, before));
    }
    if (changes.isEmpty) return;
    document.setItemColorSlots(changes);
    notifyListeners();
  }

  /// 改选中连线的**起点**形状（一次操作 = 一条撤销命令）。
  ///
  /// 没选中连线时静默忽略；形状没变也不记命令（避免 Ctrl+Z 刷满）。
  void setSelectedEdgeStartShape(EdgeEndpointShape shape) {
    final CanvasEdge? old = _selectedEdge;
    if (old == null || old.startShape == shape) return;
    final CanvasEdge next = CanvasEdge(
      id: old.id,
      fromId: old.fromId,
      toId: old.toId,
      fromSide: old.fromSide,
      toSide: old.toSide,
      startShape: shape,
      endShape: old.endShape,
      props: old.props,
    );
    document.updateEdge(next);
    _selectedEdge = next;
    notifyListeners();
  }

  /// 改选中连线的**终点**形状（一次操作 = 一条撤销命令）。
  void setSelectedEdgeEndShape(EdgeEndpointShape shape) {
    final CanvasEdge? old = _selectedEdge;
    if (old == null || old.endShape == shape) return;
    final CanvasEdge next = CanvasEdge(
      id: old.id,
      fromId: old.fromId,
      toId: old.toId,
      fromSide: old.fromSide,
      toSide: old.toSide,
      startShape: old.startShape,
      endShape: shape,
      props: old.props,
    );
    document.updateEdge(next);
    _selectedEdge = next;
    notifyListeners();
  }

  /// 删除当前选中（笔迹 + item，框选 → Delete）。
  void deleteSelection() {
    if (!hasSelection) return;
    if (_selection.isNotEmpty) document.removeStrokes(_selection);
    if (_selectedItems.isNotEmpty) document.removeItems(_selectedItems);
    if (_selectedEdge != null) {
      document.removeEdges(<CanvasEdge>[_selectedEdge!]);
      _selectedEdge = null;
    }
    _selection.clear();
    _selectedItems.clear();
    // 删掉的可能是别人的输入 ⇒ 重算过期状态。
    refreshStaleness();
    notifyListeners();
  }

  /// 选中给定 item（替换当前选区）。插入形状/图片后"落地即选中"，于是可以马上
  /// 拖动、缩放；也是属性面板将来取"选中了什么"的入口。
  void selectItems(Iterable<CanvasItem> items) {
    _selection.clear();
    _selectedItems
      ..clear()
      ..addAll(items);
    _selectedEdge = null;
    notifyListeners();
  }

  void clearSelection() {
    if (!hasSelection) return;
    _selection.clear();
    _selectedItems.clear();
    _selectedEdge = null;
    notifyListeners();
  }

  /// 以编程方式设定 item 选中集合（如"全选"、测试、或后续分组功能）。
  void setSelection(Iterable<CanvasItem> items) {
    _selectedItems
      ..clear()
      ..addAll(items);
    _selectedEdge = null;
    notifyListeners();
  }

  // ───────────────────────── AI 生成闭环 ─────────────────────────

  /// 由 [Region] 触发一次生成：先以 loading 态落一个 [AiImageItem]（占位框），
  /// 异步拿到结果后注入图像并翻 status。回来的是同一节点 ⇒ 撤销即删该层。
  ///
  /// 这是"region-as-data"主循环：选区 → 配方 → 调模型 → 新层，[generator]
  /// 决定是本地桩还是远程模型，画布侧无需感知。
  ///
  /// img2img：在**加入新层之前**把选区内容栅格化成 PNG 字节喂给生成器
  /// （此时文档里还没有占位框，避免把"正在生成的灰框"喂给自己）。
  Future<AiImageItem> generateFromRegion(
    Region region, {
    String model = 'stub',
    String? prompt,
    String? negativePrompt,
    int? seed,
  }) async {
    // 先栅格化 img2img 输入（文档尚未加入新层，避免把占位框喂给自己）。
    final Map<String, Uint8List> inputImages = await _rasterInputs(region);

    final GenRecipe recipe = GenRecipe(
      model: model,
      prompt: prompt ?? region.prompt ?? '',
      negativePrompt: negativePrompt ?? '',
      // 种子必须落到**具体值**：null 意味着"后端随便挑"，结果不可复现，
      // 缓存键也就失去意义（同键不同图）。这里定下一个随机种子并记进配方，
      // 使每次生成都是"可复现的一次"——重复配方才能可靠命中缓存。
      seed: seed ?? _randomSeed(),
      inputs: <String, String>{
        if (region.nodeRef != null) 'image': region.nodeRef!,
        if (region.maskRef != null) 'mask': region.maskRef!,
      },
      // 只有真有输入时才记指纹：纯文生图无输入可言 ⇒ 永不 stale。
      inputFingerprint: inputImages.isEmpty
          ? null
          : inputFingerprint(document, region.bbox),
    );

    final AiImageItem item = AiImageItem(rect: region.bbox, gen: recipe);
    document.addItem(item); // 显示 loading 占位框，并入撤销栈
    notifyListeners();

    try {
      final GeneratedResult result = await generator.generate(
        recipe,
        region: region,
        inputImages: inputImages,
      );
      result.applyTo(item, onLoaded: requestRepaint);
      item.gen = recipe.copyWith(status: GenStatus.done);
    } on Object catch (_) {
      item.gen = recipe.copyWith(status: GenStatus.error);
    }
    notifyListeners();
    return item;
  }

  /// 32 位随机种子（留在 int 安全区，JSON 往返无损）。
  static int _randomSeed() => math.Random().nextInt(0x7FFFFFFF);

  /// 重算所有 AI 层的**过期**状态：输入变过 ⇒ [GenStatus.stale]（结果还在，
  /// 但已"可重算"）；输入又改回去 ⇒ 自动恢复 [GenStatus.done]（撤销之后不该
  /// 一直挂着过期标记）。
  ///
  /// ## 为什么是"拉"而不是"推"
  /// 不在每次增删改里挨个通知下游（要维护依赖图），而是在**手势落账点**统一
  /// 比对一次指纹——依赖关系由几何重叠直接推出，无需登记。
  ///
  /// 返回是否有状态变化。刻意**不**在这里 [notifyListeners]：调用方（撤销/重做/
  /// 落账）本来就要刷新一次，避免同一次改动通知两遍。
  bool refreshStaleness() {
    // 只挑"有输入可言的生成层"。没有这类层 ⇒ 直接返回：纯写字/画图场景
    // 每次抬手都零成本（指纹计算要遍历覆盖到的笔迹，不该白跑）。
    final List<AiImageItem> tracked = <AiImageItem>[
      for (final CanvasItem item in document.items)
        if (item is AiImageItem && item.gen.inputFingerprint != null) item,
    ];
    if (tracked.isEmpty) return false;

    bool changed = false;
    for (final AiImageItem layer in tracked) {
      final String recorded = layer.gen.inputFingerprint!;
      final bool stale = inputFingerprint(document, layer.rect) != recorded;
      if (stale && layer.gen.status != GenStatus.stale) {
        layer.gen = layer.gen.copyWith(status: GenStatus.stale);
        changed = true;
      } else if (!stale && layer.gen.status == GenStatus.stale) {
        layer.gen = layer.gen.copyWith(status: GenStatus.done);
        changed = true;
      }
    }
    return changed;
  }

  /// 把 [region] 覆盖到的画布内容栅格化为 img2img 输入图：
  /// - `image`：选区自身的世界矩形（有内容时才给，纯 txt2img 留空）；
  /// - `mask`：若 [Region.maskRef] 指向某个节点，则栅格化该节点包围盒。
  Future<Map<String, Uint8List>> _rasterInputs(Region region) async {
    final Map<String, Uint8List> out = <String, Uint8List>{};
    final Rect box = region.bbox;
    if (box.width < 1 || box.height < 1) return out;
    final bool hasContent =
        document.itemsIn(box).isNotEmpty || document.strokesIn(box).isNotEmpty;
    if (!hasContent) return out;
    out['image'] = await rasterizeRegion(document, box);
    if (region.maskRef != null) {
      final CanvasItem? mask = document.itemById(region.maskRef!);
      if (mask != null) {
        out['mask'] = await rasterizeRegion(document, mask.bounds);
      }
    }
    return out;
  }

  /// 便捷入口：拿当前选区（框选矩形 / 已选中 item / 笔迹）的包围盒生成。
  /// 选区过小视为无效。提示词优先用参数 [prompt]，否则取 [aiPrompt]
  /// （由宿主页面输入框设置）。
  Future<AiImageItem?> generateFromSelection({
    String? prompt,
    String model = 'stub',
  }) async {
    final Rect? box = selectionBounds;
    if (box == null || box.width < 4 || box.height < 4) return null;
    final String? p = prompt ?? (aiPrompt.isEmpty ? null : aiPrompt);
    return generateFromRegion(
      Region(id: Region.nextId(), bbox: box, prompt: p),
      model: model,
      prompt: p,
    );
  }

  // ───────────────────────── 输入流水线 ─────────────────────────

  void onPointerDown(PointerDownEvent event) {
    if (_isPalm(event)) return;

    // 中键 / 空格 / 抓手工具 ⇒ 平移，优先级最高（不与绘制冲突）。
    final bool wantsPan =
        _isMiddleButton(event) || spacePanning || tool == CanvasTool.pan;
    if (wantsPan) {
      _panPointer = event.pointer;
      _panLast = event.localPosition;
      return;
    }

    final Offset world = camera.screenToWorld(event.localPosition);
    _activePointer = event.pointer;

    // 工具状态机：把「按下」交给当前工具的处理器（见 `canvas_tool_handler.dart`）。
    // 平移已在上面 return，不会到这里；move/up/cancel 仍是共享的手势瞬态判断。
    CanvasToolHandlers.of(tool).onPointerDown(this, event, world);
    notifyListeners();
  }

  void onPointerMove(PointerMoveEvent event) {
    if (event.pointer == _panPointer && _panLast != null) {
      camera.panBy(event.localPosition - _panLast!);
      _panLast = event.localPosition;
      notifyListeners();
      return;
    }
    if (event.pointer != _activePointer) return;

    final Offset world = camera.screenToWorld(event.localPosition);

    // 形状工具：拖拽更新预览框（视图据此画出"正在画的那个框"）。
    if (_shapeStartWorld != null) {
      _shapeDraft = Rect.fromPoints(_shapeStartWorld!, world);
      notifyListeners();
      return;
    }

    // 连线拖动中：只更新预览光标（起点卡片已固定）。
    if (_pendingFrom != null) {
      _pendingCursor = world;
      notifyListeners();
      return;
    }

    // 端点拖改中（缺口4）：只更新活动端光标。
    if (_edgeGripEdge != null) {
      _edgeGripCursor = world;
      notifyListeners();
      return;
    }

    // 缩放 / 旋转手势：优先于普通拖动。
    if (_gripKind != null) {
      _applyGrip(world);
      notifyListeners();
      return;
    }

    // item 拖动：全部选中 item 按起点快照整体平移（含多选整体移动）。
    final Map<CanvasItem, Rect>? startRects = _moveStartRects;
    if (startRects != null && _moveStartWorld != null) {
      final Offset delta = world - _moveStartWorld!;
      for (final MapEntry<CanvasItem, Rect> e in startRects.entries) {
        e.key.rect = e.value.shift(delta);
      }
      notifyListeners();
      return;
    }

    final InkStroke? stroke = _activeStroke;
    if (stroke != null) {
      // 抽稀掉了（位移过小）就不重绘——省掉大量无意义的帧。
      if (stroke.add(InkPoint(world, _pressureOf(event)))) {
        notifyListeners();
      }
    } else if (_erasing) {
      _eraserAt = world;
      document.eraseAt(world, eraserRadius);
      notifyListeners();
    } else if (_marqueeStart != null) {
      _marquee = Rect.fromPoints(_marqueeStart!, world);
      notifyListeners();
    }
  }

  void onPointerUp(PointerUpEvent event) {
    if (event.pointer == _panPointer) {
      _panPointer = null;
      _panLast = null;
      return;
    }
    if (event.pointer != _activePointer) return;
    final Offset world = camera.screenToWorld(event.localPosition);

    // 形状工具：抬手时落账（拖出来的框，或"点一下"的默认大小）。
    if (_shapeStartWorld != null) {
      _commitShape(event);
      return;
    }

    // 连线拖动结束：命中另一张卡片才落账，否则取消。
    if (_pendingFrom != null) {
      _commitConnect(world);
      return;
    }

    // 端点拖改结束（缺口4）：落在卡片上就换端点，否则取消（保持原样）。
    if (_edgeGripEdge != null) {
      _commitEdgeGrip(world);
      return;
    }

    final InkStroke? stroke = _activeStroke;
    if (stroke != null && stroke.points.isNotEmpty) {
      document.addStroke(stroke);
    }
    final Rect? box = _marquee;
    if (box != null) {
      _selection
        ..clear()
        ..addAll(document.strokesIn(box));
      _selectedItems
        ..clear()
        ..addAll(document.itemsIn(box));
    }

    // 缩放 / 旋转落账：一条撤销命令包含本次手势所有 item 的 rect + angle。
    if (_gripKind != null) {
      _commitGrip();
    }

    // item 拖动落账：只记真的动了的。
    final Map<CanvasItem, Rect>? startRects = _moveStartRects;
    if (startRects != null) {
      document.setItemTransforms(<(CanvasItem, Rect, double)>[
        for (final MapEntry<CanvasItem, Rect> e in startRects.entries)
          (e.key, e.value, e.key.angle),
      ]);
      _moveStartRects = null;
      _moveStartWorld = null;
    }

    _activeStroke = null;
    _activePointer = null;
    _erasing = false;
    _marqueeStart = null;
    _marquee = null;
    _pendingFrom = null;
    _pendingCursor = null;
    _pendingFromSide = null;
    _edgeGripEdge = null;
    _edgeGripCursor = null;
    // 一次手势结束、变更全部落账后才重算过期状态（拖动中不做，省掉每帧遍历）。
    refreshStaleness();
    notifyListeners();
  }

  void onPointerCancel(PointerCancelEvent event) {
    // 取消：进行中的那条直接丢弃（不进文档，也就不进撤销栈）。
    if (event.pointer == _activePointer) {
      _activeStroke = null;
      _erasing = false;
      _marqueeStart = null;
      _marquee = null;
      _cancelShapeDraft();
      _activePointer = null;
      // 连线/端点拖改：丢弃进行中的预览与拖改（不改文档）。
      _pendingFrom = null;
      _pendingCursor = null;
      _pendingFromSide = null;
      _edgeGripEdge = null;
      _edgeGripCursor = null;
      // item 拖拽/缩放/旋转：就地改过的 rect/angle 弹回起点快照。
      final Map<CanvasItem, Rect>? startRects = _moveStartRects;
      if (startRects != null) {
        for (final MapEntry<CanvasItem, Rect> e in startRects.entries) {
          e.key.rect = e.value;
        }
        _moveStartRects = null;
        _moveStartWorld = null;
      }
      if (_transformStarts != null) {
        for (final _TransformStart s in _transformStarts!) {
          s.item.rect = s.rect;
          s.item.angle = s.angle;
        }
      }
      _gripKind = null;
      _resizeHandle = null;
      _resizeStartRect = null;
      _groupStartRect = null;
      _gripFixedCorner = null;
      _gripStartCorner = null;
      _gripGroupCenter = null;
      _gripStartPointerAngle = null;
      _transformStarts = null;
      // 就地改过的 rect/angle 已弹回起点 ⇒ 过期状态也要跟着回退。
      refreshStaleness();
      notifyListeners();
    }
    if (event.pointer == _panPointer) {
      _panPointer = null;
      _panLast = null;
    }
  }

  /// 悬停：只维护橡皮光标（笔工具下不画圈，避免干扰）。
  /// 丢掉进行中的形状预览（取消、或已经落账）。
  void _cancelShapeDraft() {
    _shapeStartWorld = null;
    _shapeStartScreen = null;
    _shapeDraft = null;
  }

  /// 连线按下：点中已有连线 ⇒ 选中；否则从卡片起拉（只接受卡片，端点要 blockId）。
  void _beginConnect(Offset world) {
    // 0) 已选中连线时，先看是否抓住了它的端点把手（缺口4：拖端点改接）。
    final CanvasEdge? selected = _selectedEdge;
    if (selected != null) {
      final EdgeGeometry? geo = selectedEdgeGeometry;
      if (geo != null) {
        final double tol = camera.toWorld(_edgeGripTolerance);
        if ((world - geo.from).distance <= tol) {
          _startEdgeGrip(selected, true, world);
          return;
        }
        if ((world - geo.to).distance <= tol) {
          _startEdgeGrip(selected, false, world);
          return;
        }
      }
    }
    // 1) 点中已有连线 ⇒ 选中它。
    final CanvasEdge? hit = document.hitEdgeAt(
      world,
      camera.toWorld(_edgeHitTolerance),
    );
    if (hit != null) {
      _selectedEdge = hit;
      _selectedItems.clear();
      _selection.clear();
      return;
    }
    // 2) 从卡片起拉：起点端口由**按下位置**决定（缺口1，"从哪边拉出"）。
    final CanvasItem? item = document.hitItemAt(
      world,
      camera.toWorld(_itemHitTolerance),
    );
    if (item is CardItem) {
      _pendingFrom = item;
      _pendingFromSide = _portAt(item.rect, world);
      _pendingCursor = world;
      _selectedEdge = null;
      _selectedItems.clear();
      _selection.clear();
    } else {
      // 点空白/非卡片：清掉连线选区（不开始拉）。
      _selectedEdge = null;
      _selectedItems.clear();
      _selection.clear();
    }
  }

  /// 进入端点拖改：记下连线与活动端。
  void _startEdgeGrip(CanvasEdge edge, bool isFrom, Offset world) {
    _edgeGripEdge = edge;
    _edgeGripIsFrom = isFrom;
    _edgeGripCursor = world;
    _selectedEdge = edge;
  }

  /// 端点拖改落账：活动端落在卡片上就换端点，否则取消（保持原样）。
  void _commitEdgeGrip(Offset world) {
    final CanvasEdge? edge = _edgeGripEdge;
    final bool isFrom = _edgeGripIsFrom;
    _edgeGripEdge = null;
    _edgeGripCursor = null;
    if (edge == null) return;

    final CanvasItem? target = document.hitItemAt(
      world,
      camera.toWorld(_itemHitTolerance),
    );
    if (target is! CardItem) return; // 没落在卡片上：取消
    final CanvasSide? side = _portAt(target.rect, world);
    final String newFromId = isFrom ? target.blockId : edge.fromId;
    final String newToId = isFrom ? edge.toId : target.blockId;
    if (newFromId == newToId) return; // 不许自连
    // 换端点后若与既有边完全同向 ⇒ 放弃（与起拉去重同口径）。
    final bool dup = document.edges.any(
      (CanvasEdge e) =>
          e.id != edge.id && e.fromId == newFromId && e.toId == newToId,
    );
    if (dup) return;

    final CanvasEdge next = CanvasEdge(
      id: edge.id,
      fromId: newFromId,
      toId: newToId,
      fromSide: isFrom ? side : edge.fromSide,
      toSide: isFrom ? edge.toSide : side,
      props: edge.props,
    );
    document.updateEdge(next);
    _selectedEdge = next;
  }

  /// 连线松手：命中另一张卡片才建边，否则取消（不残留半截）。
  void _commitConnect(Offset world) {
    final CanvasItem? from = _pendingFrom;
    final CanvasItem? to = document.hitItemAt(
      world,
      camera.toWorld(_itemHitTolerance),
    );
    _pendingFrom = null;
    _pendingCursor = null;
    if (from is CardItem && to is CardItem && to != from) {
      // 同向重复不重复建：端点/几何完全重合的两条边在屏幕上分不出来，
      // 删除也只能删中其中一条（"看不见的重复"比"少一条"更糟）。
      final bool exists = document.edges.any(
        (CanvasEdge e) => e.fromId == from.blockId && e.toId == to.blockId,
      );
      if (!exists) {
        // 两端端口都由**操作位置**决定（缺口1：从哪边拉出、连到哪边）。
        document.addEdge(
          CanvasEdge(
            fromId: from.blockId,
            toId: to.blockId,
            fromSide: _pendingFromSide,
            toSide: _portAt(to.rect, world),
          ),
        );
      }
    }
  }

  /// 结束一次形状拖拽并落账：够大就按拖出来的框，几乎没动就落一个默认大小。
  ///
  /// "点一下也要能建"是刻意的（Excalidraw 同款）：只支持拖拽的话，习惯点击的用户
  /// 会以为工具栏坏了。阈值按**屏幕**位移判定（世界位移随缩放变化，不能当阈值）。
  void _commitShape(PointerEvent event) {
    final Offset world = camera.screenToWorld(event.localPosition);
    final Offset? startWorld = _shapeStartWorld;
    final Offset? startScreen = _shapeStartScreen;
    _cancelShapeDraft();
    if (startWorld == null || startScreen == null) return;

    // 屏幕像素：位移小于它算"点一下"。
    const double clickSlop = 4;
    // "点一下"落下的默认尺寸（**屏幕**尺寸，任何缩放级别观感一致）。
    const Size defaultSize = Size(160, 120);

    final bool isClick =
        (event.localPosition - startScreen).distance < clickSlop;
    final Rect rect = isClick
        ? Rect.fromCenter(
            // 落点取**按下**的位置：抬手那 1px 抖动不该把形状挪走。
            center: startWorld,
            width: defaultSize.width / camera.scale,
            height: defaultSize.height / camera.scale,
          )
        : _clampDraftSize(Rect.fromPoints(startWorld, world));

    final ShapeItem item = ShapeItem(
      rect: rect,
      kind: _shapeKind,
      // 颜色跟随笔刷：形状工具就是"用当前笔刷画个框"（改色在笔刷面板）。
      color: penColor,
    );
    document.addItem(item);
    // 画完即选中：接着就能调色/调描边（图形属性面板也正是在选中形状时出现）。
    // 工具**不切回**选择——连续画几个框是常态，切回去才是"矩形像框选"的老毛病。
    selectItems(<CanvasItem>[item]);
    notifyListeners();
  }

  /// 拖出来的框太小时钳到最小（屏幕上约 8px），免得落一个点不中的元素。
  Rect _clampDraftSize(Rect rect) {
    final double minWorld = 8 / camera.scale;
    return Rect.fromLTWH(
      rect.left,
      rect.top,
      rect.width < minWorld ? minWorld : rect.width,
      rect.height < minWorld ? minWorld : rect.height,
    );
  }

  void onPointerHover(PointerHoverEvent event) {
    if (tool != CanvasTool.eraser) return;
    _eraserAt = camera.screenToWorld(event.localPosition);
    notifyListeners();
  }

  /// 滚轮 / 触控板：
  /// - Ctrl/Cmd + 滚轮 = **以光标为焦点缩放**；
  /// - 直接滚轮 = 平移（触控板双指滑动也走这条）。
  void onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final bool zoomIntent =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (zoomIntent) {
      camera.zoomAt(event.localPosition, math.exp(-event.scrollDelta.dy / 300));
    } else {
      camera.panBy(-event.scrollDelta);
    }
    notifyListeners();
  }

  // ───────────────────────── 手势判定辅助 ─────────────────────────

  /// item 点击命中容差（**屏幕像素**，换算成世界单位使用）——任何缩放级别
  /// 下"好点"程度一致。
  static const double _itemHitTolerance = 4;

  /// 命中 [screenPoint]（屏幕）是否落在选中集合的手柄 / 旋转手柄上。
  ({_GripKind kind, CanvasHandle? handle})? _gripAtScreen(Offset screenPoint) {
    final List<CanvasItem> sel = _selectedItems;
    if (sel.isEmpty) return null;
    List<Offset> cornersWorld;
    if (sel.length == 1) {
      cornersWorld = CanvasHandles.rotatedCorners(
        sel.single.rect,
        sel.single.angle,
      );
    } else {
      final Rect group = _unionBounds(sel);
      if (group.isEmpty) return null;
      cornersWorld = CanvasHandles.corners(group);
    }
    final List<Offset> cornersScreen = cornersWorld
        .map<Offset>(camera.worldToScreen)
        .toList(growable: false);
    final Offset rot = CanvasHandles.rotationHandlePos(
      cornersScreen,
      CanvasHandles.rotateHandleDistance,
    );
    if (CanvasHandles.hitRotation(rot, screenPoint)) {
      return (kind: _GripKind.rotate, handle: null);
    }
    final CanvasHandle? h = CanvasHandles.hitTest(cornersScreen, screenPoint);
    if (h != null) return (kind: _GripKind.corner, handle: h);
    return null;
  }

  /// 记录手势起点（所有选中 item 的 rect + angle）。
  void _beginGrip(({_GripKind kind, CanvasHandle? handle}) grip, Offset world) {
    _gripKind = grip.kind;
    _transformStarts = <_TransformStart>[
      for (final CanvasItem it in _selectedItems)
        _TransformStart(it, it.rect, it.angle),
    ];
    if (grip.kind == _GripKind.corner) {
      if (_selectedItems.length == 1 && grip.handle != null) {
        _resizeHandle = grip.handle;
        _resizeStartRect = _selectedItems.single.rect;
        _resizeStartAngle = _selectedItems.single.angle;
      } else {
        final Rect group = _unionBounds(_selectedItems);
        _groupStartRect = group;
        final CanvasHandle h = grip.handle!;
        _gripFixedCorner = switch (h) {
          CanvasHandle.topLeft => group.bottomRight,
          CanvasHandle.topRight => group.bottomLeft,
          CanvasHandle.bottomLeft => group.topRight,
          CanvasHandle.bottomRight => group.bottomLeft,
        };
        _gripStartCorner = switch (h) {
          CanvasHandle.topLeft => group.topLeft,
          CanvasHandle.topRight => group.topRight,
          CanvasHandle.bottomLeft => group.bottomLeft,
          CanvasHandle.bottomRight => group.bottomRight,
        };
      }
    } else {
      final Offset center = _selectedItems.length == 1
          ? _selectedItems.single.rect.center
          : _unionBounds(_selectedItems).center;
      _gripGroupCenter = center;
      _gripStartPointerAngle = (world - center).direction;
    }
  }

  /// 根据当前指针世界坐标应用缩放 / 旋转（绝对值，每次从起点重算）。
  void _applyGrip(Offset world) {
    final List<_TransformStart>? starts = _transformStarts;
    if (starts == null || _gripKind == null) return;
    if (_gripKind == _GripKind.corner) {
      if (_selectedItems.length == 1 && _resizeHandle != null) {
        _selectedItems.single.rect = CanvasHandles.resizeRotated(
          _resizeStartRect!,
          _resizeStartAngle,
          _resizeHandle!,
          world,
        );
      } else if (_gripFixedCorner != null && _gripStartCorner != null) {
        final Offset d = world - _gripFixedCorner!;
        final Offset s0 = _gripStartCorner!;
        final double denomX = s0.dx - _gripFixedCorner!.dx;
        final double denomY = s0.dy - _gripFixedCorner!.dy;
        double sx = denomX == 0 ? 1 : d.dx / denomX;
        double sy = denomY == 0 ? 1 : d.dy / denomY;
        final Rect g = _groupStartRect!;
        const double minSize = CanvasHandles.minSize;
        if (sx.abs() * g.width < minSize) sx = sx.sign * minSize / g.width;
        if (sy.abs() * g.height < minSize) sy = sy.sign * minSize / g.height;
        for (final _TransformStart s in starts) {
          s.item.rect = CanvasHandles.scaleAbout(
            s.rect,
            _gripFixedCorner!,
            sx,
            sy,
          );
        }
      }
    } else if (_gripKind == _GripKind.rotate &&
        _gripGroupCenter != null &&
        _gripStartPointerAngle != null) {
      final double cur = (world - _gripGroupCenter!).direction;
      final double delta = cur - _gripStartPointerAngle!;
      for (final _TransformStart s in starts) {
        s.item.rect = CanvasHandles.rotateAbout(
          s.rect,
          _gripGroupCenter!,
          delta,
        );
        s.item.angle = s.angle + delta;
      }
    }
  }

  /// 落账：一条撤销命令包含本次手势所有 item 的 rect + angle 变更。
  void _commitGrip() {
    final List<_TransformStart>? starts = _transformStarts;
    _gripKind = null;
    _resizeHandle = null;
    _resizeStartRect = null;
    _groupStartRect = null;
    _gripFixedCorner = null;
    _gripStartCorner = null;
    _gripGroupCenter = null;
    _gripStartPointerAngle = null;
    _transformStarts = null;
    if (starts == null) return;
    document.setItemTransforms(<(CanvasItem, Rect, double)>[
      for (final _TransformStart s in starts) (s.item, s.rect, s.angle),
    ]);
  }

  bool _isMiddleButton(PointerEvent event) =>
      event.buttons & kMiddleMouseButton != 0;

  bool _isPalm(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) return false;
    if (event.size > palmSize) return true;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastTouchDown;
    _lastTouchDown = now;
    return last != null && now.difference(last) < palmWindow;
  }

  /// 手写笔（含橡皮端）且驱动真的给了压感值。
  bool _hasRealPressure(PointerEvent event) =>
      (event.kind == PointerDeviceKind.stylus ||
          event.kind == PointerDeviceKind.invertedStylus) &&
      event.pressure > 0;

  /// 压感归一化到 0~1：不同驱动的 `pressureMin/Max` 区间不同。
  /// 没有真压感时返回 0，交给 perfect_freehand 的 `simulatePressure` 模拟。
  double _pressureOf(PointerEvent event) {
    if (!_hasRealPressure(event)) return 0;
    final double min = event.pressureMin;
    final double max = event.pressureMax;
    if (max > min) {
      return ((event.pressure - min) / (max - min)).clamp(0.0, 1.0);
    }
    return event.pressure.clamp(0.0, 1.0);
  }

  /// 整页序列化（相机 + 文档），供保存/重载/导出。
  ///
  /// [media] 提供时图片路径写成**相对引用**（可移植），并随文档带一份媒体侧表；
  /// 不传则保持旧行为（绝对路径、无侧表）。
  Map<String, dynamic> toJson({MediaResolver? media}) => <String, dynamic>{
    'camera': camera.toJson(),
    'document': document.toJson(media: media),
  };

  /// 反序列化：相机与文档整体重建（两者在控制器内为 final，故用工厂构造）。
  ///
  /// [media] 把文档里的媒体**相对引用**换算回运行时绝对路径；
  /// [generator] 可注入（宿主层装入 [CachingAiGenerator] 等装饰器）；不传则用
  /// 离线桩，保持内核默认零依赖。
  factory CanvasController.fromJson(
    Map<String, dynamic> j, {
    MediaResolver? media,
    AiGenerator? generator,
  }) => CanvasController(
    camera: CanvasCamera.fromJson(j['camera'] as Map<String, dynamic>),
    document: CanvasDocument.fromJson(
      j['document'] as Map<String, dynamic>,
      media: media,
    ),
    generator: generator ?? const LocalStubGenerator(),
  );

  /// 公开封装 [notifyListeners]，供视图层（如图片懒加载完成）在外部触发重绘
  /// —— [notifyListeners] 本身为 protected，不能在视图里直接调用。
  void requestRepaint() => notifyListeners();

  // ─────────────────── LOD：缩放期间冻结判据 ───────────────────

  /// item 数**达到**它才启用"缩放期间冻结 LOD 判据"。
  ///
  /// 与 tldraw 的 `debouncedZoomThreshold`（同为 500）取同一个量级：少量 item 时
  /// 冻结只会让 LOD 显得迟钝（明明能立刻变清晰，却非等停稳），大文档才值得——
  /// 见 [lodScale] 里那两笔代价。
  static const int lodFreezeThreshold = 500;

  /// 停稳判定：相机缩放最后一次变化后等待这么久，才把 LOD 判据切到新缩放。
  static const Duration lodSettleDelay = Duration(milliseconds: 180);

  double? _lodScale;
  Timer? _lodSettleTimer;

  /// LOD 判据用的**稳定缩放**（与 tldraw `getEfficientZoomLevel` 同思路）。
  ///
  /// 与 `camera.scale` 的差别只在**缩放进行中**：相机的缩放逐帧都变，若 LOD
  /// 直接跟它走，手势中途要付两笔代价——① 沿途的 item 在"色块 ⇄ 全保真"之间
  /// 反复翻转（画面闪变）；② 每个跨过阈值的图片 item 会**立刻**触发
  /// `onImageMissing` ⇒ 手势正忙时批量读盘 + 解码几十张原图。
  /// 冻结到停稳再跳一次，两笔都省，且 LOD 只"弹"一次而不是一路闪。
  ///
  /// 未同步过（首帧 / 刚载入存档）⇒ 直接跟随相机，不做冻结：那时并没有手势
  /// 在进行，冻结只会让首帧用错判据。
  double get lodScale => _lodScale ?? camera.scale;

  /// 相机缩放变化后同步 LOD 判据。由 [notifyListeners] 统一驱动，于是**所有**
  /// 改相机缩放的路径都覆盖到，无需在 4 个缩放入口各写一遍。
  void _syncLodScale() {
    final double scale = camera.scale;
    if (_lodScale == null || document.itemCount < lodFreezeThreshold) {
      _lodScale = scale;
      _lodSettleTimer?.cancel();
      _lodSettleTimer = null;
      return;
    }
    if (_lodScale == scale) return; // 已稳定，无未决事项
    _lodSettleTimer?.cancel();
    _lodSettleTimer = Timer(lodSettleDelay, () {
      _lodSettleTimer = null;
      if (_lodScale == camera.scale) return;
      _lodScale = camera.scale;
      // 停稳后必须再通知一次：视图要按新判据重绘（这一帧才从色块变清晰）。
      notifyListeners();
    });
  }

  int _repaintStamp = 0;

  /// 视觉状态版本号：**每次通知（"画面该更新了"）都 +1**，供 painter 在
  /// `shouldRepaint` 里判定"这一帧与上一帧是否不同"。
  ///
  /// ## 为什么必须有它
  /// 相机、item 几何、进行中的笔迹都是**就地修改**的：painter 收到的
  /// `oldDelegate.camera` / `oldDelegate.items[i]` 与当前是**同一批对象**，逐字段
  /// 比较等于"和自己比"，恒等 ⇒ 判定恒为 false。实测三种情况全部返回 false
  /// （平移相机、拖动 item、湿墨生长），表现为画面不更新。
  ///
  /// 用一个单调递增的整数当"内容戳"即可根治，且天然覆盖所有视觉变更（任何视觉
  /// 变更都会经过 [notifyListeners]）。字段比较仍保留：对**跨对象**的调用方
  /// （如离线渲染、测试里各建一个相机）依旧有意义。
  int get repaintStamp => _repaintStamp;

  @override
  void notifyListeners() {
    // LOD 判据在这里统一同步：**所有**改相机缩放的路径都以 notifyListeners
    // 收尾（zoomBy / resetZoom / fitToContent / 滚轮缩放），挂这里就不用在每个
    // 入口各写一遍，将来新增缩放入口也不会漏。
    _syncLodScale();
    _repaintStamp++;
    super.notifyListeners();
  }

  @override
  void dispose() {
    // 未决的 LOD 停稳定时器必须取消：它稍后会在**已 dispose** 的 notifier 上
    // 再通知一次（debug 下直接抛）。
    _lodSettleTimer?.cancel();
    _lodSettleTimer = null;
    _selection.clear();
    // 图片 item 持有的 ui.Image 是引擎侧资源，必须显式释放。
    for (final CanvasItem item in document.items) {
      item.dispose();
    }
    // Picture 持有引擎侧资源，必须显式释放（GC 不会及时回收）。
    _picture?.dispose();
    _picture = null;
    super.dispose();
  }
}
