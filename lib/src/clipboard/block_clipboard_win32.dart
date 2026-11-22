import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'block_clipboard_transport.dart';
import 'clipboard_codec.dart';

/// `String` → `PCWSTR`（UTF-16 原生内存，调用方负责 [freePcwstr]）。
PCWSTR _pcwstr(String value) => PCWSTR(value.toNativeUtf16());

/// 释放 [_pcwstr] 分配的内存。
void freePcwstr(PCWSTR value) => malloc.free(value);

/// **平台层 · Windows**：win32 FFI 读写自定义剪贴板格式。
///
/// 与 `note_media_service.dart` 的位图剪贴板共用同一套约束（那不是巧合，
/// 是在本项目实测出来的）：
/// - `OpenClipboard` 是**独占锁**，粘贴瞬间常被别的程序短暂持有 ⇒ 重试；
/// - `CloseClipboard` 必须兜底重试，失败 = 本进程永久锁住系统剪贴板；
/// - FFI 全程放**后台 isolate**（含重试 sleep），不阻塞 UI，也避开与
///   Flutter engine 剪贴板平台通道的跨线程竞争。
class WindowsBlockClipboardTransport implements BlockClipboardTransport {
  @override
  bool get isSupported => Platform.isWindows;

  @override
  Future<bool> write({
    required String payload,
    required String plainText,
    String? imageFilePath,
  }) async {
    if (!isSupported) return false;
    final _WriteRequest request = _WriteRequest(
      payload: payload,
      plainText: plainText,
      imageFilePath: imageFilePath,
    );
    return Isolate.run(() => _writeSync(request));
  }

  @override
  Future<String?> read() async {
    if (!isSupported) return null;
    return Isolate.run(_readSync);
  }
}

class _WriteRequest {
  const _WriteRequest({
    required this.payload,
    required this.plainText,
    required this.imageFilePath,
  });

  final String payload;
  final String plainText;
  final String? imageFilePath;
}

/// 打开剪贴板（重试 10 次 × 20ms——独占锁瞬态竞争的解药）。
bool _openWithRetry() {
  for (int attempt = 0; attempt < 10; attempt++) {
    if (attempt > 0) {
      sleep(const Duration(milliseconds: 20));
    }
    if (!OpenClipboard(null).error.isError) return true;
  }
  return false;
}

/// 关闭剪贴板（必检 + 重试）：失败 = 本进程永久持有系统剪贴板锁。
bool _closeSafe() {
  for (int attempt = 0; attempt < 3; attempt++) {
    if (!CloseClipboard().error.isError) return true;
    sleep(const Duration(milliseconds: 10));
  }
  return false;
}

/// 把一段字节写成某个剪贴板格式（数据所有权成功时归系统）。
bool _setBytes(int format, Uint8List bytes) {
  final alloc = GlobalAlloc(GMEM_MOVEABLE, bytes.length);
  if (alloc.error.isError) return false;
  final lock = GlobalLock(alloc.value);
  if (lock.error.isError) {
    GlobalFree(alloc.value);
    return false;
  }
  try {
    lock.value.cast<ffi.Uint8>().asTypedList(bytes.length).setAll(0, bytes);
  } finally {
    GlobalUnlock(alloc.value);
  }
  final set = SetClipboardData(format, HANDLE(alloc.value));
  if (set.error.isError) {
    GlobalFree(alloc.value);
    return false;
  }
  return true;
}

/// 写 UTF-16 文本（CF_UNICODETEXT 要求以 \0 结尾）。
bool _setText(int format, String text) {
  final units = text.codeUnits;
  final int byteLength = (units.length + 1) * 2;
  return _setBytes(
    format,
    Uint8List(byteLength)..buffer.asUint16List().setAll(0, units),
  );
}

/// 写 PNG 位图（Windows 剪贴板标准位图是 CF_DIB；CF_DIBV5 次之）。
///
/// 这里挂 **PNG 注册格式**（`RegisterClipboardFormat('PNG')`）：现代应用
/// （Chrome / 微信 / Word 较新版本）都认；CF_DIB 需要 DIB 编码，而那条路
/// 已在 `NoteMediaService` 里有实现，这里不重复造——若 PNG 无人认领，
/// 外部应用仍可拿到纯文本兜底。
bool _setPng(String filePath) {
  try {
    final Uint8List bytes = File(filePath).readAsBytesSync();
    final PCWSTR pngName = _pcwstr('PNG');
    final int pngFormat = RegisterClipboardFormat(pngName).value;
    freePcwstr(pngName);
    if (pngFormat == 0) return false;
    return _setBytes(pngFormat, bytes);
  } on Object {
    return false;
  }
}

bool _writeSync(_WriteRequest request) {
  try {
    if (!_openWithRetry()) return false;
    try {
      if (EmptyClipboard().error.isError) return false;

      final PCWSTR name = _pcwstr(ClipboardCodec.formatName);
      final int customFormat = RegisterClipboardFormat(name).value;
      freePcwstr(name);
      if (customFormat == 0) return false;

      // 自定义格式 = 块载荷（UTF-8 字节，不加 BOM / 结尾 \0）。
      if (!_setBytes(customFormat, Uint8List.fromList(utf8.encode(request.payload)))) {
        return false;
      }
      // 纯文本兜底：外部应用粘到的是文件名/文字，不是 JSON。
      if (request.plainText.isNotEmpty) {
        _setText(CF_UNICODETEXT, request.plainText);
      }
      // 位图（单张本地图时）：外部应用可「粘贴为图片」。
      final String? imagePath = request.imageFilePath;
      if (imagePath != null && imagePath.isNotEmpty) {
        _setPng(imagePath);
      }
      return true;
    } finally {
      _closeSafe();
    }
  } on Object {
    return false;
  }
}

/// 读自定义格式载荷；没有/失败返回 null。
String? _readSync() => _readFormatTextSync(ClipboardCodec.formatName);

/// 读任意**已注册剪贴板格式**的 UTF-8 文本（如 `'HTML Format'`）。
///
/// 供富文本粘贴复用：与块载荷共用同一套「独占锁重试 + 必检关闭 + 拷贝后
/// Unlock」的约束（见本文件顶部说明）。
String? _readFormatTextSync(String formatName) {
  try {
    if (!_openWithRetry()) return null;
    try {
      final PCWSTR name = _pcwstr(formatName);
      final int format = RegisterClipboardFormat(name).value;
      freePcwstr(name);
      if (format == 0) return null;

      final data = GetClipboardData(format);
      if (data.error.isError) return null;
      final hGlobal = HGLOBAL(data.value);
      final sizeResult = GlobalSize(hGlobal);
      if (sizeResult.error.isError || sizeResult.value == 0) return null;
      final lockResult = GlobalLock(hGlobal);
      if (lockResult.error.isError) return null;
      final Uint8List bytes;
      try {
        // **必须拷贝**：GMEM_MOVEABLE 块在 Unlock 后可能被系统移动。
        bytes = Uint8List.fromList(
          lockResult.value.cast<ffi.Uint8>().asTypedList(sizeResult.value),
        );
      } finally {
        GlobalUnlock(hGlobal);
      }
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      _closeSafe();
    }
  } on Object {
    return null;
  }
}

/// 读任意已注册格式的文本（跨 isolate 封装）；非 Windows / 失败 → null。
Future<String?> readWindowsClipboardFormatText(String formatName) async {
  if (!Platform.isWindows) return null;
  return Isolate.run(() => _readFormatTextSync(formatName));
}


