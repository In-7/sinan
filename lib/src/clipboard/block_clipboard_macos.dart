import 'package:flutter/services.dart';

import 'block_clipboard_transport.dart';
import 'clipboard_codec.dart';

/// **平台层 · macOS**：`NSPasteboard` 自定义 UTI（平台通道）。
///
/// Swift 侧见 `macos/Runner/BlockClipboardPlugin.swift`：
/// - 写：`declareTypes([customUTI, .string, .png], owner: nil)` 后逐项 set；
/// - 读：`data(forType: customUTI)` → UTF-8 字符串。
///
/// 与 Windows 实现**协议完全一致**（同一份 [ClipboardCodec] 载荷、
/// 同一个格式名）——两端剪贴板互不通用是系统限制，但业务语义一致。
class MacBlockClipboardTransport implements BlockClipboardTransport {
  const MacBlockClipboardTransport();

  static const MethodChannel _channel = MethodChannel(
    'com.sinan/clipboard',
  );

  @override
  bool get isSupported => true;

  @override
  Future<bool> write({
    required String payload,
    required String plainText,
    String? imageFilePath,
  }) async {
    try {
      final bool? ok = await _channel.invokeMethod<bool>('write', <String, Object?>{
        'format': ClipboardCodec.formatName,
        'payload': payload,
        'plainText': plainText,
        'imagePath': imageFilePath,
      });
      return ok ?? false;
    } on Object {
      // 通道缺失（未注册/未在 macOS 构建）⇒ 视为不支持，上层回落内存。
      return false;
    }
  }

  @override
  Future<String?> read() async {
    try {
      return await _channel.invokeMethod<String>('read', <String, Object?>{
        'format': ClipboardCodec.formatName,
      });
    } on Object {
      return null;
    }
  }
}
