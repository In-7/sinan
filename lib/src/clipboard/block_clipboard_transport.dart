import 'dart:io';

import 'package:flutter/foundation.dart';

import 'block_clipboard_macos.dart';
import 'block_clipboard_win32.dart';

/// **平台层接口**：把「块载荷」写/读系统剪贴板的某个自定义格式。
///
/// 各端一套实现（Windows FFI / macOS 平台通道），上层 [BlockClipboard] 只认
/// 这个接口——**逻辑层与平台层解耦**，平台实现可注入假实现做单测。
abstract interface class BlockClipboardTransport {
  /// 本平台是否支持自定义格式。false ⇒ 上层回落内存剪贴板。
  bool get isSupported;

  /// 写剪贴板：[payload] 是 `ClipboardCodec.encode` 的结果；
  /// [plainText] 给外部应用做兜底文本；[imageFilePath] 存在时同时挂一张
  /// 位图（外部应用「粘贴为图片」）。返回是否成功。
  Future<bool> write({
    required String payload,
    required String plainText,
    String? imageFilePath,
  });

  /// 读自定义格式载荷；没有/读失败返回 null。
  Future<String?> read();
}

/// 按平台挑实现。
///
/// 只做编译期可见性、不做能力探测：Windows / macOS 各一套，其它平台
/// （Linux/Web）直接不支持 ⇒ 上层自动回落内存剪贴板，行为与改造前一致。
BlockClipboardTransport createClipboardTransport() {
  if (kIsWeb) return const UnsupportedClipboardTransport();
  if (Platform.isWindows) return WindowsBlockClipboardTransport();
  if (Platform.isMacOS) return const MacBlockClipboardTransport();
  return const UnsupportedClipboardTransport();
}

/// 不支持自定义格式的平台：写返回失败、读返回 null，上层回落内存。
class UnsupportedClipboardTransport implements BlockClipboardTransport {
  const UnsupportedClipboardTransport();

  @override
  bool get isSupported => false;

  @override
  Future<bool> write({
    required String payload,
    required String plainText,
    String? imageFilePath,
  }) async =>
      false;

  @override
  Future<String?> read() async => null;
}
