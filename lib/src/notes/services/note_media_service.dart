import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:ffi/ffi.dart' show Utf16, Utf16Pointer;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart';

import 'attachment_meta.dart';

/// 笔记媒体文件服务（图片插入/粘贴直存/批量，机制对齐官方扩展）。
///
/// 官方插入约定（quill_controller.dart）：图片地址字符串经
/// `BlockEmbed.image(url)` 写进 Delta——本服务负责产生这个 url。
/// 官方示例直接引用拾取的临时路径（应用重启后失效），这里改为
/// **复制进应用数据目录**（`<appSupport>/media/`，时间戳命名）
/// 再返回长期路径，保证笔记长期可读。
abstract final class NoteMediaService {
  /// 多选拾取图片并复制进数据目录，返回长期路径列表
  /// （空列表 = 用户取消或全部失败）。
  static Future<List<String>> pickAndStoreImages() async {
    final List<PlatformFile> files = await FilePicker.pickFiles(
      type: FileType.image,
    );
    final Directory mediaDir = await _ensureMediaDir();
    final List<String> stored = <String>[];
    for (final PlatformFile file in files) {
      final String? sourcePath = file.path;
      if (sourcePath == null) continue;
      stored.add(await _copyInto(mediaDir, sourcePath));
    }
    return stored;
  }

  /// 拾取任意文件并复制进数据目录（media/attachments/），返回附件
  /// 元数据；取消返回 null。附件**复制进库**保持自包含（源文件移动
  /// 或删除不影响），代价是大文件落盘耗时（选入时一次性）。
  static Future<AttachmentMeta?> pickAndStoreAttachment() async {
    final List<PlatformFile> files = await FilePicker.pickFiles();
    final PlatformFile? file = files.isEmpty ? null : files.first;
    final String? sourcePath = file?.path;
    if (sourcePath == null) return null;
    final Directory mediaDir = await _ensureMediaDir();
    final Directory attachmentsDir = Directory(
      '${mediaDir.path}${Platform.pathSeparator}attachments',
    );
    if (!attachmentsDir.existsSync()) {
      attachmentsDir.createSync(recursive: true);
    }
    final String storedPath = await _copyInto(attachmentsDir, sourcePath);
    // file_picker 12.x：PlatformFile 变为抽象接口（无 size 字段），
    // 大小取自复制后的文件本体（最可靠）。
    final int size = File(storedPath).lengthSync();
    return AttachmentMeta(path: storedPath, name: file!.name, size: size);
  }

  /// 剪贴板截图/复制图片直存：图片字节写入数据目录，返回长期路径。
  /// 由 quill 的 `onImagePaste` 钩子与粘贴本地化流程调用。
  /// 扩展名按字节魔数判定（截图是 PNG；网页下载的多为 JPEG/WebP）。
  static Future<String> saveBytes(Uint8List bytes, {String? extension}) async {
    final Directory mediaDir = await _ensureMediaDir();
    final String targetPath = _targetPath(
      mediaDir,
      extension ?? _extFor(bytes),
    );
    await File(targetPath).writeAsBytes(bytes);
    return targetPath;
  }

  /// 按文件头魔数判图片格式（flutter Image.file 全都支持）。
  static String _extFor(Uint8List b) {
    if (b.length >= 4 && b[0] == 0x89 && b[1] == 0x50) {
      return '.png'; // ‰PNG
    }
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8) {
      return '.jpg'; // FFD8FF
    }
    if (b.length >= 3 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      return '.gif'; // GIF8
    }
    if (b.length >= 12 &&
        b[0] == 0x52 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return '.webp'; // RIFF....WEBP
    }
    if (b.length >= 2 && b[0] == 0x42 && b[1] == 0x4D) {
      return '.bmp'; // BM
    }
    return '.png';
  }

  /// 读取 Windows 剪贴板中的位图（截图工具/「复制图片」写入的
  /// CF_BITMAP/DIB/PNG 格式）。
  ///
  /// quill_native_bridge_windows 0.1.0 **没有实现**图片剪贴板 API
  /// （getClipboardImage 只在移动端/macOS 有）——win32 FFI 直调
  /// `OpenClipboard/GetClipboardData(CF_DIB)`（曾试验 super_clipboard
  /// 原生层：其 irondash 运行时与本环境的 dart_api_dl 符号表不兼
  /// 容，冷启动即 abort，故弃用；本 FFI 路径锁重试 + 必检 Close +
  /// 后台 isolate，实测稳定）。
  static Future<Uint8List?> readWindowsClipboardImage() async {
    if (!Platform.isWindows) return null;
    // 预检：剪贴板里没有 DIB 位图（如复制的是文件/纯文本）时直接返回。
    try {
      if (IsClipboardFormatAvailable(CF_DIB).value == false) {
        return null;
      }
    } on Object catch (_) {
      // 预检 API 异常不阻断主路径。
    }
    // FFI 全程（含重试 sleep 与位图解码）放**后台 isolate**：
    // 不阻塞 UI，且与 Flutter engine 的剪贴板平台通道线程隔离。
    return Isolate.run(_readClipboardImageNative);
  }

  /// 读剪贴板纯文本（win32 FFI，与图片同套受控开关流程）。
  static Future<String?> readClipboardText() async {
    if (!Platform.isWindows) return null;
    return Isolate.run(_readClipboardTextNative);
  }

  /// 打开剪贴板（重试 10 次 × 20ms——独占锁瞬态竞争的解药）。
  static bool _openClipboardWithRetry() {
    for (var attempt = 0; attempt < 10; attempt++) {
      if (attempt > 0) {
        sleep(const Duration(milliseconds: 20));
      }
      if (!OpenClipboard(null).error.isError) {
        return true;
      }
    }
    return false;
  }

  /// 关闭剪贴板（**必检**）：CloseClipboard 失败 = 锁被本进程永久
  /// 持有——系统级后果是所有其他程序的剪贴板读/写（包括截图写入）
  /// 全部失败（实验三实测）。失败重试 3 次，仍失败则大声告警。
  static bool _closeClipboardSafe() {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!CloseClipboard().error.isError) {
        return true;
      }
      sleep(const Duration(milliseconds: 10));
    }
    debugPrint(
      'NoteMediaService: FATAL — CloseClipboard failed after retries; '
      'clipboard is locked by this process until it exits!',
    );
    return false;
  }

  /// 原生路径：win32 FFI 读 CF_DIB → 补 BMP 文件头 → image 包转 PNG。
  /// 任何失败（剪贴板被占/非 BI_RGB/解析失败）返回 null 走兜底。
  ///
  /// OpenClipboard 带**重试**：剪贴板是独占资源，粘贴瞬间常被写入方
  /// （截图工具）/剪贴板监听器短暂持有（实测 error 5 ACCESS_DENIED）
  /// ——瞬态锁，10 次 × 20ms 重试即可穿过（同步阻塞 ≤200ms 无感）。
  static Uint8List? _readClipboardImageNative() {
    try {
      if (!_openClipboardWithRetry()) {
        _debugReport('native: OpenClipboard denied ×10', code: -1);
        return null;
      }
      try {
        final data = GetClipboardData(CF_DIB);
        if (data.error.isError) {
          _debugReport('native: GetClipboardData', code: data.error);
          return null;
        }
        final hGlobal = HGLOBAL(data.value);
        // 空句柄/无效句柄会在这里报错兜住，无需单独比较。
        final sizeResult = GlobalSize(hGlobal);
        if (sizeResult.error.isError || sizeResult.value == 0) return null;
        final lockResult = GlobalLock(hGlobal);
        if (lockResult.error.isError) return null;
        final Uint8List dib;
        try {
          // **必须拷贝**：GMEM_MOVEABLE 块在 GlobalUnlock 后可能被
          // 系统移动/改写，视图（asTypedList）绑定的是原生内存——
          // 解码若放在 Unlock 之后会读到失效数据（「第一次成功、
          // 后续全失败」的根因）。
          dib = Uint8List.fromList(
            lockResult.value.cast<ffi.Uint8>().asTypedList(sizeResult.value),
          );
        } finally {
          GlobalUnlock(hGlobal);
        }
        final Uint8List? png = _dibToPng(dib);
        if (png == null) {
          // DIB 头信息进日志，定位不支持的具体格式。
          final header = ByteData.sublistView(dib);
          debugPrint(
            'NoteMediaService: unsupported DIB '
            '${header.getInt32(4, Endian.little)}x'
            '${header.getInt32(8, Endian.little)} '
            '${header.getUint16(14, Endian.little)}bpp '
            'comp=${header.getUint32(16, Endian.little)} '
            '(${dib.length}B)',
          );
          return null;
        }
        return png;
      } finally {
        _closeClipboardSafe();
      }
    } on Object catch (_) {
      return null;
    }
  }

  /// 原生读剪贴板纯文本（CF_UNICODETEXT）：与图片读同一套受控开关
  /// 流程——纯文本兜底从 Flutter engine 的 Clipboard.getData 切换到
  /// 此路径，消除 engine 通道的不可控时序（its OpenClipboard 与我们
  /// 的 FFI 跨线程竞争是 error 5 的另一来源）。
  static String? _readClipboardTextNative() {
    try {
      if (!_openClipboardWithRetry()) {
        return null;
      }
      try {
        final data = GetClipboardData(CF_UNICODETEXT);
        if (data.error.isError) {
          return null;
        }
        final hGlobal = HGLOBAL(data.value);
        final sizeResult = GlobalSize(hGlobal);
        if (sizeResult.error.isError || sizeResult.value < 2) return null;
        final lockResult = GlobalLock(hGlobal);
        if (lockResult.error.isError) return null;
        String text;
        try {
          final ffi.Pointer<Utf16> textPtr = lockResult.value.cast();
          text = textPtr.toDartString();
        } finally {
          GlobalUnlock(hGlobal);
        }
        return text;
      } finally {
        _closeClipboardSafe();
      }
    } on Object catch (_) {
      return null;
    }
  }

  /// CF_DIB（BITMAPINFOHEADER[+掩码/调色板]+像素）→ 补 14 字节 BMP
  /// 文件头构造合法 BMP → image 包解码 → PNG 字节。
  ///
  /// 支持无压缩 BI_RGB(0) 与 BI_BITFIELDS(3) 的 24/32bpp——BITFIELDS
  /// 是部分浏览器/截图工具的写法，实践中掩码与 BI_RGB 标准字节序
  /// （BGR/BGRA）一致：改写压缩标志为 BI_RGB 按标准布局解码，像素
  /// 数据偏移计入头外掩码的 12 字节（V4/V5 头的掩码在头内）。
  /// 其余压缩（JPEG/PNG 内嵌）与 16bpp 返回 null（不支持）。
  static Uint8List? _dibToPng(Uint8List dib) {
    if (dib.length < 40) return null;
    final header = ByteData.sublistView(dib);
    final int headerSize = header.getUint32(0, Endian.little); // biSize
    final int width = header.getInt32(4, Endian.little);
    final int height = header.getInt32(8, Endian.little); // 有符号：负=top-down
    final int bitCount = header.getUint16(14, Endian.little);
    final int compression = header.getUint32(16, Endian.little);
    if (width <= 0 || height == 0) return null;

    int extraOffset = 0; // 头外掩码字节数（计入像素数据偏移）
    if (compression == 3) {
      // BI_BITFIELDS
      if (bitCount != 24 && bitCount != 32) return null;
      if (headerSize == 40) {
        // 40B 基础头：掩码在头外紧跟 12 字节。
        extraOffset = 12;
      }
      // headerSize > 40（V4/V5 头）：掩码在头内，无需偏移。
      header.setUint32(16, 0, Endian.little); // 改写为 BI_RGB
    } else if (compression != 0) {
      return null;
    }

    final int pixelOffset = 14 + headerSize + extraOffset;
    if (dib.length < pixelOffset) return null;

    final bmp = BytesBuilder();
    bmp.add(const [0x42, 0x4D]); // 'BM'
    final fileHeader = ByteData(12)
      ..setUint32(0, 14 + dib.length, Endian.little) // 文件大小
      ..setUint32(4, 0, Endian.little) // 保留
      ..setUint32(8, pixelOffset, Endian.little); // 像素数据偏移
    bmp.add(fileHeader.buffer.asUint8List());
    bmp.add(dib);

    final img.Image? decoded = img.decodeBmp(bmp.takeBytes());
    if (decoded == null) return null;
    return Uint8List.fromList(img.encodePng(decoded));
  }

  /// 把本地图片文件写入 Windows 剪贴板（供「复制图片」菜单使用）。
  ///
  /// win32 FFI：解码任意格式 → 自构造**标准 32bpp BI_RGB DIB** →
  /// `EmptyClipboard + SetClipboardData(CF_DIB)`。
  ///
  /// 不用 image 包的 encodeBmp：它输出 V5 头(124B) + BITFIELDS + 24bpp
  /// 的组合，作为剪贴板 DIB 兼容性差（自家解析器都不认）。标准
  /// 32bpp BI_RGB 是 Windows 剪贴板位图的最通用形态（带 alpha 且
  /// 所有应用可读）。成功后数据所有权归系统（不可 GlobalFree）。
  static Future<void> copyImageFileToWindowsClipboard(String imagePath) async {
    if (!Platform.isWindows) return;
    await Isolate.run(() => _copyImageFileToWindowsClipboardSync(imagePath));
  }

  /// img.Image → 32bpp BI_RGB DIB（bottom-up，BGRA 像素序）。
  static Uint8List _imageToDib(img.Image image) {
    final int w = image.width;
    final int h = image.height;
    final header = ByteData(40)
      ..setUint32(0, 40, Endian.little) // biSize
      ..setInt32(4, w, Endian.little)
      ..setInt32(8, h, Endian.little) // 正 = bottom-up 行序
      ..setUint16(12, 1, Endian.little) // biPlanes
      ..setUint16(14, 32, Endian.little) // 32bpp
      ..setUint32(16, 0, Endian.little) // BI_RGB
      ..setUint32(20, w * h * 4, Endian.little) // biSizeImage
      ..setInt32(24, 0, Endian.little) // xPelsPerMeter
      ..setInt32(28, 0, Endian.little) // yPelsPerMeter
      ..setUint32(32, 0, Endian.little) // biClrUsed
      ..setUint32(36, 0, Endian.little); // biClrImportant

    final pixels = Uint8List(w * h * 4);
    var i = 0;
    // bottom-up：从最后一行往前写。
    for (int y = h - 1; y >= 0; y--) {
      for (int x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        pixels[i++] = p.b.toInt();
        pixels[i++] = p.g.toInt();
        pixels[i++] = p.r.toInt();
        pixels[i++] = p.a.toInt();
      }
    }
    final builder = BytesBuilder()
      ..add(header.buffer.asUint8List())
      ..add(pixels);
    return builder.takeBytes();
  }

  static void _copyImageFileToWindowsClipboardSync(String imagePath) {
    try {
      final Uint8List bytes = File(imagePath).readAsBytesSync();
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) return;
      final Uint8List dib = _imageToDib(decoded);

      if (!_openClipboardWithRetry()) return;
      try {
        if (EmptyClipboard().error.isError) return;
        final alloc = GlobalAlloc(GMEM_MOVEABLE, dib.length);
        if (alloc.error.isError) return;
        final lock = GlobalLock(alloc.value);
        if (lock.error.isError) {
          GlobalFree(alloc.value);
          return;
        }
        try {
          lock.value.cast<ffi.Uint8>().asTypedList(dib.length).setAll(0, dib);
        } finally {
          GlobalUnlock(alloc.value);
        }
        final set = SetClipboardData(CF_DIB, HANDLE(alloc.value));
        if (set.error.isError) {
          // 所有权未转移，自行释放避免泄漏。
          GlobalFree(alloc.value);
        }
        // 成功：所有权归系统，句柄由剪贴板管理。
      } finally {
        _closeClipboardSafe();
      }
    } on Object catch (_) {
      // 静默失败：复制是增值操作。
    }
  }

  /// 调试输出 FFI 失败详情（错误码），便于回报排查。
  static void _debugReport(String api, {required int code}) {
    assert(() {
      debugPrint('NoteMediaService.$api failed: code=$code');
      return true;
    }());
  }

  static Future<Directory> _ensureMediaDir() async {
    final Directory supportDir = await getApplicationSupportDirectory();
    final Directory mediaDir = Directory(
      '${supportDir.path}${Platform.pathSeparator}media',
    );
    if (!mediaDir.existsSync()) {
      mediaDir.createSync(recursive: true);
    }
    return mediaDir;
  }

  static Future<String> _copyInto(Directory mediaDir, String sourcePath) {
    final String targetPath = _targetPath(mediaDir, _extensionOf(sourcePath));
    return File(sourcePath).copy(targetPath).then((_) => targetPath);
  }

  static String _targetPath(Directory mediaDir, String extension) =>
      '${mediaDir.path}${Platform.pathSeparator}'
      '${DateTime.now().millisecondsSinceEpoch}$extension';

  static String _extensionOf(String path) =>
      path.contains('.') ? path.substring(path.lastIndexOf('.')) : '.png';
}
