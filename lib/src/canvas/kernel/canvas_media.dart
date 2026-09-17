import 'dart:io' show Platform;

/// 文档内**媒体引用**与运行时**绝对路径**之间的双向换算。
///
/// ## 为什么需要
/// 画布 JSON 存在 `notes.content` 里，而图片本体是磁盘上的一个文件。早先把
/// `ImageItem.src` 直接写成**绝对路径**（如
/// `C:\Users\xxx\AppData\Roaming\sinan\ai_cache\ab.png`），于是：
/// - 换机器 / 重装 / 恢复备份后数据目录变了 ⇒ 全部图片失联（静默退化成占位框，
///   不报错也查不出原因）；
/// - 文档里嵌了一台具体机器的文件系统信息 ⇒ 无法分享 / 同步 / 导出。
///
/// 现在文档只存**相对引用**（`ai_cache/ab.png`），运行时经本接口换算成绝对路径。
/// 这正是 Excalidraw `files` / glTF `buffers` 的思路：**场景图只存引用，二进制
/// 资产放在侧表 / 磁盘上**。
abstract class MediaResolver {
  /// 绝对路径 → 文档内相对引用（保存时）。
  String toRef(String path);

  /// 文档内相对引用 → 绝对路径（载入 / 读取字节时）。
  String toPath(String ref);
}

/// 以某个**应用数据根目录**为基准的相对引用解析器。
///
/// 约定：引用统一用 `/` 分隔（JSON 里跨平台一致，不掺 `\` 转义，也就不会与
/// JSON 自身的转义打架）；基准目录**之外的**绝对路径**原样保留**——外部拖进来
/// 的图片无法相对化，但仍能用，只是不具可移植性。
///
/// 对**旧存档**（`src` 仍是绝对路径）天然兼容：[toPath] 遇到绝对路径直接返回，
/// 因此不需要任何迁移步骤。
class RelativeMediaResolver implements MediaResolver {
  const RelativeMediaResolver(this.baseDirectory);

  /// 绝对路径（应用数据根，如 `getApplicationSupportDirectory()` 的结果）。
  final String baseDirectory;

  @override
  String toRef(String path) {
    if (path.isEmpty) return path;
    final String normalized = _slashes(path);
    final String prefix = _withTrailingSlash(_slashes(baseDirectory));
    if (normalized.startsWith(prefix)) {
      return normalized.substring(prefix.length);
    }
    // 基准目录之外（旧存档 / 外部图片）：保持原样。
    return path;
  }

  @override
  String toPath(String ref) {
    if (ref.isEmpty) return ref;
    if (_isAbsolute(ref)) return ref; // 旧存档里的绝对路径：直接可用。
    return '$baseDirectory${Platform.pathSeparator}'
        '${ref.replaceAll('/', Platform.pathSeparator)}';
  }

  static String _slashes(String p) => p.replaceAll('\\', '/');

  static String _withTrailingSlash(String p) => p.endsWith('/') ? p : '$p/';

  /// 是否已是绝对路径（POSIX `/…` 或 Windows `C:\…` / `C:/…`）。
  ///
  /// 不用正则：这里在每次序列化每个 item 时都会走到，字符码判断更直接。
  static bool _isAbsolute(String p) {
    if (p.startsWith('/')) return true;
    if (p.length < 2 || p[1] != ':') return false;
    final int c = p.codeUnitAt(0);
    return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A); // A-Z / a-z
  }
}

/// 媒体 MIME 推断（目前实际只承载 PNG）。
///
/// 收口在一处：侧表里记 `mime` 而不是让每个读方各自看后缀，日后加 JPEG/WebP
/// 时只需改这里。
String mediaMimeOf(String ref) {
  final String lower = ref.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  return 'image/png';
}
