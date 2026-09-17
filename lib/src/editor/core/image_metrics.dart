import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 图片**宽高比**（高 ÷ 宽）的解析与缓存，按 `src`（本地路径 / data URL）键。
///
/// ## 为什么需要（2026-09-14）
/// 图片块的高度有两个来源：
/// 1. 节点里存的 `height`（用户拖过宽度的图片有）；
/// 2. **没存**时：官方先给一个固定的"加载中"高度（`resizable_image.dart` 的
///    150），解码完成后按**原始宽高比**×显示宽度撑开。
///
/// 于是"没存尺寸的图片"在**解码完成的那一刻**会改变块高 ⇒ 滚动器总高跟着变
/// （用户看到的现象：滚动条滑块动一下）。而滚动器要在**块被构建之前**就给出
/// 高度（见 `../block_height_predictor.dart`），所以必须提前知道比例。
///
/// ## 只读标头，不做完整解码
/// `ui.ImageDescriptor.encoded` 解析图片头部就能给出原始宽高，不分配像素缓冲
/// ——对本地文件是微秒级，因此可以在笔记打开时对全文图片批量预热。
///
/// ## 失败即记住
/// 解析失败（文件被删、格式不认识、网络 URL 不预取）也写进缓存（值为 null），
/// **不重试**：预算器退回"加载中高度"，等块真的被构建时由实测替换。
class ImageAspectRatios {
  final Map<String, double> _ratios = <String, double>{};
  final Set<String> _failed = <String>{};
  final Set<String> _pending = <String>{};

  /// 已知的宽高比（高 ÷ 宽）；不知道或已失败返回 null。
  double? operator [](String src) => _ratios[src];

  /// 是否已交手过（无论成功失败）——避免重复解析。
  bool _known(String src) => _ratios.containsKey(src) || _failed.contains(src);

  /// 确保 [src] 的比例已知；不知道就异步解析，完成后回调 [onResolved]。
  ///
  /// 回调**每张图只调一次**（成功或失败都算），调用方据此更新那一项的滚动高度。
  void ensure(String src, {required VoidCallback onResolved}) {
    if (src.isEmpty || _known(src) || !_pending.add(src)) return;
    // 立即执行的异步闭包：它的 Future 被故意丢弃（fire-and-forget），
    // 显式 unawaited 表明"有意为之"而非漏掉 await。
    unawaited(() async {
      final double? ratio = await _ratioOf(src);
      _pending.remove(src);
      if (ratio == null || !ratio.isFinite || ratio <= 0) {
        _failed.add(src);
      } else {
        _ratios[src] = ratio;
      }
      onResolved();
    }());
  }

  /// 解析宽高比：本地文件读字节，`data:` URL 直接解 base64；其余（http 等）
  /// **不预取**——那会变成"打开笔记就下载所有图"，代价与副作用都不对。
  static Future<double?> _ratioOf(String src) async {
    try {
      final Uint8List? bytes = await _bytesOf(src);
      if (bytes == null || bytes.isEmpty) return null;
      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
        bytes,
      );
      final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(
        buffer,
      );
      final double ratio = descriptor.height / descriptor.width;
      descriptor.dispose();
      buffer.dispose();
      return ratio;
    } on Object catch (_) {
      // 解析失败（损坏 / 不支持的格式 / 文件不存在）由调用方退回默认估计。
      return null;
    }
  }

  static Future<Uint8List?> _bytesOf(String src) async {
    if (src.startsWith('data:')) {
      final int comma = src.indexOf(',');
      if (comma < 0) return null;
      return base64Decode(src.substring(comma + 1));
    }
    if (src.startsWith('http://') || src.startsWith('https://')) return null;
    final File file = File(src);
    // `existsSync`：`exists()` 是异步 IO，会为此多排一次事件循环，而这里
    // 紧接着就要读文件，同步判存在更快（lint `avoid_slow_async_io`）。
    if (file.existsSync()) return file.readAsBytes();
    return _tryBase64(src);
  }

  /// 裸 base64（不带 `data:` 前缀）——quill 的 Web 侧就这么存图片。
  ///
  /// 官方 `resizable_image.dart` 也是这个判定顺序（先 base64 后文件），这里
  /// 只是把"文件不存在"当作进入 base64 分支的信号，避免误把路径当 base64 解。
  static Uint8List? _tryBase64(String src) {
    if (src.length < 64 || !_base64Pattern.hasMatch(src)) return null;
    try {
      return base64Decode(src);
    } on Object catch (_) {
      return null;
    }
  }

  static final RegExp _base64Pattern = RegExp(r'^[A-Za-z0-9+/=\r\n]+$');
}
