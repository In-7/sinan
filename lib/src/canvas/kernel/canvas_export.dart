import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'canvas_camera.dart';
import 'canvas_controller.dart';
import 'canvas_raster.dart';
import 'ink_stroke.dart';

/// 整图导出：把 [controller] 的文档离线渲染成一张位图并落盘为 PNG。
///
/// 渲染内核是 `canvas_raster.dart` 的 [rasterizeWithCamera]（与 img2img 输入图
/// 共用同一条离屏路径），本函数只负责**导出几何 + 落盘**：
/// 固定 `1 世界单位 = pixelRatio 设备像素`、四周留 24×pixelRatio 像素边距，
/// 因此导出尺寸随内容包围盒变化（不是"装进某个固定画布"）。
///
/// [pixelRatio] 决定导出清晰度（建议传 `MediaQuery.devicePixelRatio`）。
/// [directory] 为输出目录（不存在会自动创建），文件名按时间戳避免覆盖。
/// [background] 默认白色；传 [Color] 透明白可导出透明背景。
/// [inkColor] 默认 [kThemeInk]（近黑）——导出是**白纸黑墨**，与界面明暗无关。
Future<File> exportCanvasToPng(
  CanvasController controller, {
  required String directory,
  double pixelRatio = 1,
  Color background = const Color(0xFFFFFFFF),
  Color inkColor = kThemeInk,
}) async {
  final Rect? bounds = controller.document.bounds;
  if (bounds == null) {
    throw StateError('空画布无法导出');
  }

  // 先确保图片都解码完成，否则导出会画占位框。
  await ensureImagesLoaded(controller.document);

  final double pad = 24 * pixelRatio;
  final double scale = pixelRatio; // 1 世界单位 = pixelRatio 设备像素
  final CanvasCamera camera = CanvasCamera(
    scale: scale,
    translation: Offset(
      pad - bounds.left * scale,
      pad - bounds.top * scale,
    ),
  );
  final Size size = Size(
    bounds.width * scale + pad * 2,
    bounds.height * scale + pad * 2,
  );

  // 网格不导出，只导内容。笔迹**按导出墨色自录一张**，不复用界面缓存：界面在
  // 暗色下录的是浅墨，直接复用就成了"白底白墨"的空图（见 `recordPicture`）。
  // 这张是本次调用的临时资源，用完即弃（GC 不会及时回收）。
  final ui.Picture ink = controller.recordPicture(ink: inkColor);
  late final Uint8List bytes;
  try {
    bytes = await rasterizeWithCamera(
      camera,
      size,
      items: controller.document.items,
      inkPicture: ink,
      background: background,
    );
  } finally {
    ink.dispose();
  }

  final Directory dir = Directory(directory);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final File file = File('$directory/canvas_${canvasFileTimestamp()}.png');
  await file.writeAsBytes(bytes);
  return file;
}

/// 导出的文件名时间戳（`yyyyMMdd_HHmmss`）：避免覆盖同名导出。
///
/// 公开给 `canvas_bundle.dart` 复用——两处导出（PNG / 自包含 JSON）应当同一种
/// 命名口径，各写一份迟早会漂移。
String canvasFileTimestamp() {
  final DateTime now = DateTime.now();
  String pad2(int n) => n.toString().padLeft(2, '0');
  return '${now.year}${pad2(now.month)}${pad2(now.day)}'
      '_${pad2(now.hour)}${pad2(now.minute)}${pad2(now.second)}';
}
