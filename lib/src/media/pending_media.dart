import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../domain/note.dart';
import 'media_kind.dart';

/// 待发送附件暂存（2026-11-17 从 `_CaptureBar` 的私有类提出来，视频 Tier 0
/// 需要"两种来源两种暂存法"，也让笔记/画布将来共用）。
///
/// - **字节**（剪贴板位图，没有源路径）⇒ 留 [bytes]，提交时写盘；
/// - **文件**（文件选择器，尤其视频）⇒ 只留 [sourcePath]，**提交时才拷贝**——
///   大视频绝不整读内存（"不发就不落盘，零孤儿"语义不变：用户选了又不发，
///   磁盘上不会多出任何副本）。
class PendingMedia {
  const PendingMedia({
    this.bytes,
    this.sourcePath,
    required this.ext,
    required this.kind,
  }) : assert(bytes != null || sourcePath != null, 'bytes 与 sourcePath 至少给一个');

  /// 剪贴板位图的暂存字节；文件来源为 null。
  final Uint8List? bytes;

  /// 文件来源的**源路径**（提交时才拷贝）；剪贴板来源为 null。
  final String? sourcePath;

  /// 含点的扩展名，如 `.png` / `.mp4`。
  final String ext;

  /// `'image'` | `'video'`（见 [kindForPath]）。
  final String kind;

  bool get isVideo => kind == 'video';
}

/// 把待发送附件逐条拷进 [baseDir]（`stream_media/`），返回落库用的入参。
///
/// **这里才真正落盘**：字节条目写文件、文件条目拷贝副本（源文件移动/删除
/// 不影响，与图同语义）。返回的 [StreamAttachmentInput.path] 都是私有目录里
/// 那份独立副本的绝对路径。
Future<List<StreamAttachmentInput>> materializePendingMedia(
  String baseDir,
  List<PendingMedia> items,
) async {
  if (items.isEmpty) return const <StreamAttachmentInput>[];
  await Directory(baseDir).create(recursive: true);
  final List<StreamAttachmentInput> result = <StreamAttachmentInput>[];
  const Uuid uuid = Uuid();
  for (final PendingMedia m in items) {
    final String ext = m.ext.isEmpty ? (m.isVideo ? '.mp4' : '.img') : m.ext;
    final String dest = '$baseDir${Platform.pathSeparator}${uuid.v4()}$ext';
    final Uint8List? bytes = m.bytes;
    if (bytes != null) {
      await File(dest).writeAsBytes(bytes);
    } else {
      await File(m.sourcePath!).copy(dest);
    }
    result.add(StreamAttachmentInput(kind: m.kind, path: dest));
  }
  return result;
}
