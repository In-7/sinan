/// 附件类型判定（2026-11-17 视频 Tier 0 接入）：按扩展名归 `'image'` / `'video'`。
///
/// 选择器放行清单、待发暂存、落库 `kind` 三处共用这一份（单一来源）。
/// 视频 Tier 0 = 文件片 + 系统播放器打开（不内置播放器，理由见
/// `attachment_file_chip.dart`）。
library;

/// 图片扩展名（不含点；`file_picker` 的 `allowedExtensions` 同格式）。
const Set<String> kImageExtensions = <String>{
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
};

/// 视频扩展名（不含点）。MKV 等容器系统播放器能不能放取决于用户装了什么
/// ——Tier 0 交给系统，这里只负责识别。
const Set<String> kVideoExtensions = <String>{
  'mp4',
  'm4v',
  'mov',
  'avi',
  'mkv',
  'webm',
  'wmv',
};

/// 是否视频路径（按末段扩展名，大小写不敏感）。无扩展名 ⇒ false。
bool isVideoPath(String path) {
  final int dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return false;
  return kVideoExtensions.contains(path.substring(dot + 1).toLowerCase());
}

/// 按路径扩展名判附件 kind：`'image'` | `'video'`。
/// 剪贴板位图没有扩展名，调用方直接给 `'image'`。
String kindForPath(String path) => isVideoPath(path) ? 'video' : 'image';
