import 'dart:io';

import 'package:file_picker/file_picker.dart';

/// 拾取一个画布文件（`.canvas.json`）并读成**文本**；用户取消返回 null。
///
/// 刻意只做"取到文本"，不解析：解析与还原在 `kernel/canvas_bundle.dart` 的
/// `importCanvasBundleText`（那边才知道 `media` / `generator` 怎么接）。
///
/// 分成两半还有一个原因：**一半可测**。宿主 [CanvasNoteView] 把本函数作为默认值
/// 注入，测试换成"直接返回一段 JSON"的替身，就能绕开文件对话框把导入链路
/// （确认 → 还原 → 换文档 → 落盘）整条测完。
Future<String?> pickCanvasBundleText() async {
  final List<PlatformFile> files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: <String>['json'],
  );
  final String? path = files.isEmpty ? null : files.first.path;
  if (path == null) return null;
  return File(path).readAsString();
}
