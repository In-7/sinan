import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:appflowy_editor/appflowy_editor.dart';

/// **逻辑层**：块 ⇄ 剪贴板载荷的编解码（纯 Dart、无平台依赖）。
///
/// 平台层只负责「把这串字符串塞进系统剪贴板的某个自定义格式」以及反向读，
/// 内容格式在这里定义——Windows / macOS 两套平台实现共用同一份协议。
abstract final class ClipboardCodec {
  /// 载荷协议版本。改结构必须 +1：旧版读不懂新载荷时按 null 处理（当没数据），
  /// 绝不猜测字段——宁可粘不出块，也不能粘出坏块。
  static const int version = 1;

  /// 自定义剪贴板格式名（Windows 注册名 / macOS UTI 的本地部分）。
  ///
  /// 用反向域名风格，避免与其它应用撞名。
  static const String formatName = 'com.sinan.blocks';

  /// 剪贴板里人类可读的兜底文本（粘到外部应用时看到的内容）。
  /// 图片块取文件名，其余取纯文本。
  static String plainTextOf(List<Node> nodes) {
    final StringBuffer buffer = StringBuffer();
    for (final Node node in nodes) {
      if (node.delta != null) {
        buffer.write(node.delta!.toPlainText());
      } else if (node.type == ImageBlockKeys.type) {
        final String url =
            (node.attributes[ImageBlockKeys.url] as String?) ?? '';
        // 只留文件名：粘到外部应用时路径无意义、还泄漏目录结构。
        final int cut = url.lastIndexOf(RegExp(r'[/\\]'));
        buffer.write(cut >= 0 && cut + 1 < url.length
            ? url.substring(cut + 1)
            : url);
      }
      buffer.write('\n');
    }
    return buffer.toString().trimRight();
  }

  /// 单张图片的字节（外部应用「粘贴为图片」用）；非单图返回 null。
  ///
  /// 只处理本地文件：网络图/base64 要额外下载或解码，塞进剪贴板属于过度设计。
  static String? singleLocalImagePath(List<Node> nodes) {
    if (nodes.length != 1) return null;
    final Node node = nodes.single;
    if (node.type != ImageBlockKeys.type) return null;
    final String url = (node.attributes[ImageBlockKeys.url] as String?) ?? '';
    if (url.isEmpty || url.startsWith('http') || url.startsWith('data:')) {
      return null;
    }
    return url;
  }

  /// 块列表 → 载荷字符串（JSON）。
  static String encode(List<Node> nodes) {
    return jsonEncode(<String, Object>{
      'v': version,
      'nodes': nodes.map((Node n) => n.toJson()).toList(growable: false),
    });
  }

  /// 载荷字符串 → 块列表；协议不认识/损坏一律返回 null（当作"没有块数据"）。
  static List<Node>? decode(String raw) {
    try {
      final Object? parsed = jsonDecode(raw);
      if (parsed is! Map<String, Object?>) return null;
      if (parsed['v'] != version) return null;
      final Object? rawNodes = parsed['nodes'];
      if (rawNodes is! List) return null;
      final List<Node> nodes = <Node>[];
      for (final Object? item in rawNodes) {
        if (item is! Map) return null;
        nodes.add(Node.fromJson(Map<String, Object>.from(item)));
      }
      return nodes.isEmpty ? null : nodes;
    } on Object {
      return null;
    }
  }

}
