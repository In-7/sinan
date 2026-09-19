import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'canvas_camera.dart';
import 'canvas_document.dart';
import 'canvas_edge.dart';
import 'canvas_item.dart';
import 'canvas_painters.dart';
import 'ink_stroke.dart';

/// 画布**离屏渲染**模块：不经过任何 Flutter 控件，用内核 Painter 把内容直接
/// 画进 [ui.PictureRecorder] → 位图 → PNG 字节。
///
/// 两条用途共用**同一条**渲染路径（新增绘制语义只改一处 Painter，不会分叉）：
/// - 整图导出：`canvas_export.dart` 的 [exportCanvasToPng]（落盘为文件）；
/// - img2img / inpaint 输入图：[rasterizeRegion]（选区 → 字节，喂给模型）。
///
/// ## 坐标系约定
/// 相机把**世界坐标**映射到**像素画布**；[CanvasCamera.translation] 是屏幕像素。
/// 本模块内所有相机都是**直接构造**（写死 scale/translation），**不要**走
/// [CanvasCamera.fit] —— `fit` 会把 scale 钳进 `[minScale, maxScale]`（默认
/// 0.05~4），而小选区（几个世界单位）需要数十倍放大，被钳后内容只占画布
/// 一角、四周全是背景。

/// 预加载与 [world] 相交的图片 item，避免渲染时画出占位灰框。
/// [world] 为 null 时处理文档内**全部** item。
Future<void> ensureImagesLoaded(CanvasDocument document, {Rect? world}) async {
  final Iterable<CanvasItem> items = world == null
      ? document.items
      : document.itemsIn(world);
  for (final CanvasItem item in items) {
    if (item is ImageItem && !item.loaded) {
      await item.load(onLoaded: () {});
    }
  }
}

/// 离屏渲染内核（与实时视图共用同一批 Painter）：用 [camera] 把 [items] 与
/// [inkPicture] 画进 [pixelSize] 的位图并编码 PNG。
///
/// **不**释放 [inkPicture]——所有权归调用方：导出与 img2img 都自录一张、用完
/// 自行释放。⚠️ 它里面的颜色**已经烤定**，调用方必须按目标墨色录制
/// （见 `CanvasController.recordPicture` 与本文件的 [rasterizeRegion]）：
/// 界面在暗色下录的是浅墨，直接拿去铺白底就是一张空图。
///
/// [includeGrid] 默认 false：导出与喂模型都不该带上背景点阵（AI 会把网格当
/// 内容）。需要时才显式传 [gridColor] + true。
Future<Uint8List> rasterizeWithCamera(
  CanvasCamera camera,
  Size pixelSize, {
  required List<CanvasItem> items,
  List<EdgeGeometry> edges = const <EdgeGeometry>[],
  required ui.Picture inkPicture,
  Color background = const Color(0xFFFFFFFF),
  Color? gridColor,
  bool includeGrid = false,
}) async {
  final int pxW = math.max(1, pixelSize.width.ceil());
  final int pxH = math.max(1, pixelSize.height.ceil());

  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  // 底色铺满（模型/导出都不喜欢透明底）。
  canvas.drawColor(background, ui.BlendMode.src);

  if (includeGrid && gridColor != null) {
    GridPainter(camera: camera, color: gridColor).paint(canvas, pixelSize);
  }
  ItemPainter(camera: camera, items: items, edges: edges).paint(canvas, pixelSize);
  InkPainter(camera: camera, picture: inkPicture).paint(canvas, pixelSize);

  final ui.Image image = await recorder.endRecording().toImage(pxW, pxH);
  final ByteData? bytes = await image.toByteData(
    format: ui.ImageByteFormat.png,
  );
  image.dispose();
  if (bytes == null) throw StateError('rasterizeWithCamera: PNG 编码失败');
  return bytes.buffer.asUint8List();
}

/// 把世界矩形 [world] 等比铺进「最长边不超过 [maxPixels]」的像素画布，栅格化
/// 成 PNG 字节 —— img2img / inpaint 的输入图。
///
/// 结果**无留边**：[world] 的宽/高分别对齐像素画布的宽/高，因此长宽比与选区
/// 完全一致（微小差异来自像素取整 <1px）。
///
/// [includeGrid] 默认 false：AI 不该看到背景点阵。
Future<Uint8List> rasterizeRegion(
  CanvasDocument document,
  Rect world, {
  int maxPixels = 1024,
  bool includeGrid = false,
  Color? gridColor,
  Color background = const Color(0xFFFFFFFF),
  Color inkColor = kThemeInk,
}) async {
  if (world.width <= 0 || world.height <= 0) {
    throw ArgumentError('rasterizeRegion: 空矩形 $world');
  }

  // 像素尺寸：保持长宽比，最长边 = maxPixels。
  final double aspect = world.width / world.height;
  final int pxW;
  final int pxH;
  if (aspect >= 1) {
    pxW = maxPixels;
    pxH = math.max(1, (maxPixels / aspect).round());
  } else {
    pxH = maxPixels;
    pxW = math.max(1, (maxPixels * aspect).round());
  }
  final Size pixelSize = Size(pxW.toDouble(), pxH.toDouble());

  // 等比铺满：scale = 像素宽 / 世界宽（长宽比一致 ⇒ 两轴同值、无留边）。
  // 直接构造相机而不是 `fit`，绕开 minScale/maxScale 钳制（见文件头注释）。
  final double scale = pixelSize.width / world.width;
  final CanvasCamera camera = CanvasCamera(
    scale: scale,
    translation: pixelSize.center(Offset.zero) - world.center * scale,
  );

  await ensureImagesLoaded(document, world: world);

  final ui.Picture inkPicture = _recordInk(document, world, inkColor);
  try {
    return await rasterizeWithCamera(
      camera,
      pixelSize,
      items: document.itemsIn(world),
      // 连线与 item 同口径裁剪（端点按 world 现算）。
      edges: document.edgesIn(world),
      inkPicture: inkPicture,
      background: background,
      gridColor: gridColor,
      includeGrid: includeGrid,
    );
  } finally {
    // 这张 Picture 是本次调用自录的临时资源，用完即弃（GC 不会及时回收）。
    inkPicture.dispose();
  }
}

/// 录制定区域笔迹为一张 Picture（**世界坐标**；相机变换由 Painter 在 paint
/// 内施加，与实时视图的 `pictureFor` 同一口径）。
///
/// [ink] 是墨色（见 [kThemeInk] 的自适应规则）：离屏路径一律用"白底黑墨"的
/// [kThemeInk]，**与界面主题无关**。
ui.Picture _recordInk(CanvasDocument document, Rect world, Color ink) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  for (final InkStroke stroke in document.strokesIn(world)) {
    canvas.drawPath(
      stroke.outline,
      ui.Paint()..color = resolveInk(stroke.color, ink),
    );
  }
  return recorder.endRecording();
}

/// 生成**输入**的结构指纹：世界矩形 [box] 覆盖到的内容是谁、在哪、什么形状。
///
/// ## 为什么不直接哈希栅格化后的像素
/// 栅格化要编码 PNG（毫秒级 + 分配几百 KB），而指纹在**每次手势落账**都要算。
/// 结构指纹只读几何（几十次比较），廉价到可以在提交点随手调用。
///
/// ## 为什么要排除 [AiImageItem]
/// 生成层是**输出**不是输入。若把它算进去，图层自己一移动就会把自己判成过期
/// （它恰好铺满自己的矩形）——那样 stale 就没意义了。输入永远是"下面的内容"。
///
/// 笔迹用 `id` 即可：笔迹**加入后不可变**（绘制中的可变对象不进文档），
/// 因此 id 唯一决定其内容。
String inputFingerprint(CanvasDocument document, Rect box) {
  final List<String> parts = <String>[];
  for (final CanvasItem item in document.itemsIn(box)) {
    if (item is AiImageItem) continue;
    parts.add(
      'i:${item.id}:${_n(item.rect.left)},${_n(item.rect.top)},'
      '${_n(item.rect.right)},${_n(item.rect.bottom)}:${_n(item.angle)}'
      '${item is ImageItem ? ':${item.src}' : ''}',
    );
  }
  for (final InkStroke stroke in document.strokesIn(box)) {
    parts.add('s:${stroke.id}');
  }
  // 排序：指纹只关心"有哪些输入"，与遍历（z 序）无关。
  parts.sort();
  return parts.join('|');
}

/// 定点化浮点（避免不同路径算出的同一几何因末位抖动被判成"变了"）。
String _n(double v) => v.toStringAsFixed(3);
