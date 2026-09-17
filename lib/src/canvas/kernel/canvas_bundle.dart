import 'dart:convert';
import 'dart:io';

import 'canvas_ai.dart';
import 'canvas_controller.dart';
import 'canvas_export.dart' show canvasFileTimestamp;
import 'canvas_media.dart';

/// 自包含画布的读写：`<...>.canvas.json` = 文档 JSON + **内联的媒体字节**。
///
/// ## 与"存到 `notes.content`"的关系
/// 两者是**同一格式**，只是完备程度不同：
/// - 存进笔记：图片 `src` 是相对引用，媒体侧表只记 `{mime}`（字节仍在磁盘
///   `ai_cache/` 里）——轻，够本机用；
/// - 导出成文件：同一份 JSON，侧表每一项**多一个 `data`**（base64 内联字节）
///   ——重，但整个文件自包含，拷到别的机器/发给别人也能完整打开。
///
/// 因为格式一致，这里不需要另写一套解析：导出 = `toJson` + 往侧表塞字节；
/// 导入 = 把侧表里的字节写回磁盘 + 走原来的 `fromJson`。两条路径不会各自漂移。
///
/// ## 为什么内联 base64 而不是打包 zip
/// 目标是"**一个文件**能带走"。zip 会引入归档依赖，且 .canvas.json 本身仍是
/// 纯文本、可 diff、可直接读——对"画布 JSON 可读"这条价值更划算。代价是体积
/// 约 +33%（base64 膨胀），对本地画布可接受。

/// 把一个画布编码成自包含 JSON（媒体字节内联进侧表）。
///
/// 读不到字节的引用（文件已被清理）**跳过不内联**：导出不该因为一张坏图整体
/// 失败，侧表里保留该条目（`mime` 仍在）以便事后发现缺了谁。
Future<Map<String, dynamic>> encodeCanvasBundle(
  CanvasController controller, {
  required MediaResolver media,
}) async {
  final Map<String, dynamic> bundle = controller.toJson(media: media);
  final dynamic document = bundle['document'];
  if (document is! Map<String, dynamic>) return bundle;
  final dynamic manifest = document['media'];
  if (manifest is! Map<String, dynamic>) return bundle;

  for (final MapEntry<String, dynamic> entry in manifest.entries) {
    final dynamic value = entry.value;
    if (value is! Map<String, dynamic>) continue;
    final File file = File(media.toPath(entry.key));
    if (!file.existsSync()) continue;
    final List<int> bytes = await file.readAsBytes();
    value['data'] = base64Encode(bytes);
    value['bytes'] = bytes.length;
  }
  return bundle;
}

/// 导出为 `.canvas.json` 文件（不存在 `directory` 会自动创建）。
Future<File> exportCanvasBundle(
  CanvasController controller, {
  required MediaResolver media,
  required String directory,
}) async {
  final Map<String, dynamic> bundle =
      await encodeCanvasBundle(controller, media: media);
  final Directory dir = Directory(directory);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final File file = File(
    '$directory${Platform.pathSeparator}'
    'canvas_${canvasFileTimestamp()}.canvas.json',
  );
  // 缩进写：导出文件是"给人看 / 可 diff"的，不值得为省几 KB 压成一行。
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(bundle),
    flush: true,
  );
  return file;
}

/// 把 bundle 里内联的媒体**落回本地磁盘**，返回可直接交给
/// [CanvasController.fromJson] 的 JSON。
///
/// 文件名沿用侧表里的**引用**（`ai_cache/<key>.png`），因此在本机导出再导入时
/// 通常命中的是同一批文件（存在即跳过，不重复写）；换机器时引用会被就地
/// 物化到本机的媒体目录，画布随即可用。
///
/// 已存在的文件**不覆盖**：`ai_cache` 的键是内容寻址的，同引用即同内容；
/// `media/` 里是时间戳命名，也不会撞。
Future<Map<String, dynamic>> materializeCanvasBundle(
  Map<String, dynamic> bundle, {
  required MediaResolver media,
}) async {
  final dynamic document = bundle['document'];
  if (document is! Map<String, dynamic>) return bundle;
  final dynamic manifest = document['media'];
  if (manifest is! Map<String, dynamic>) return bundle;

  for (final MapEntry<String, dynamic> entry in manifest.entries) {
    final dynamic value = entry.value;
    if (value is! Map<String, dynamic>) continue;
    final dynamic data = value['data'];
    if (data is! String || data.isEmpty) continue;
    final File file = File(media.toPath(entry.key));
    if (file.existsSync()) continue;
    file.parent.createSync(recursive: true);
    await file.writeAsBytes(base64Decode(data), flush: true);
  }
  return bundle;
}

/// 从 `.canvas.json` 文本还原一个画布：先物化内联媒体，再反序列化。
///
/// 解析失败（不是 JSON / 结构不对）会抛 [FormatException] 或 [ArgumentError]，
/// 由调用方决定怎么呈现——导入是显式用户动作，静默吞掉反而难查。
Future<CanvasController> importCanvasBundleText(
  String text, {
  required MediaResolver media,
  AiGenerator? generator,
}) async {
  final dynamic decoded = jsonDecode(text);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('画布文件的顶层不是 JSON 对象');
  }
  final Map<String, dynamic> bundle =
      await materializeCanvasBundle(decoded, media: media);
  return CanvasController.fromJson(
    bundle,
    media: media,
    generator: generator,
  );
}
