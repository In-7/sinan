import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'block_clipboard_win32.dart';

/// **平台层**：读系统剪贴板里的**富文本 HTML**。
///
/// 为什么要它：官方 `AppFlowyClipboard.getData` 只读纯文本，`html` 恒为 null，
/// 于是 `pasteCommand` 里 `if (html != null) { pasteHtml(html) }` 是死分支
/// ——从网页/Word 复制过来的标题、列表、加粗、链接全部塌成纯文本。
///
/// 这里只负责"把 HTML 取出来"；解析与块映射用官方 `DocumentHTMLDecoder`，
/// 它天然只认语义标签（h1~h6 / ul / ol / blockquote / pre / table / strong…），
/// **不解析 font-family / font-size / line-height** ⇒ 粘进来的内容一律按
/// sinan 自己的排版渲染（颜色另由 `DocumentHTMLDecoder.enableColorParse` 控制，
/// 见 `editor_image_paste.dart` 里的关闭逻辑）。
///
/// - Windows：`RegisterClipboardFormat('HTML Format')`（即 CF_HTML），
///   数据带一段键值头部，用 [extractCfHtmlFragment] 剥壳取 fragment。
/// - macOS：`NSPasteboard` 的 `public.html`（Swift 侧 `readHtml` 方法）。
/// - 其它平台：返回 null（回落纯文本）。
Future<String?> readClipboardHtml() async {
  if (kIsWeb) return null;
  if (Platform.isWindows) {
    final String? raw = await readWindowsClipboardFormatText('HTML Format');
    return raw == null ? null : extractCfHtmlFragment(raw);
  }
  if (Platform.isMacOS) {
    try {
      return await _macChannel.invokeMethod<String>('readHtml');
    } on Object {
      return null;
    }
  }
  return null;
}

const MethodChannel _macChannel = MethodChannel('com.sinan/clipboard');

/// 粘贴前的 HTML 归一化：把 `<pre>` 降级成 `<p>`。
///
/// ⚠️ 官方 `DocumentHTMLDecoder` **没有 code 块解析器**（`plugins/html/decoder/`
/// 只有 bulleted/numbered/todo/quote/heading/table/divider/image/text/html），
/// `<pre>` / `<pre><code>` 整段会被**直接丢弃**——实测解析出 0 个节点。
/// 也就是说从网页/IDE 复制一段代码粘进 sinan，代码会凭空消失（比纯文本还糟）。
///
/// 这里把 `<pre>` 换成 `<p>`：文字与 `<code>` 行内样式都保住，只是不再是
/// "代码块"。宁可降级，也不能静默吞内容。
String normalizeHtmlForPaste(String html) => html
    .replaceAll(RegExp(r'<pre\b[^>]*>', caseSensitive: false), '<p>')
    .replaceAll(RegExp(r'</pre\s*>', caseSensitive: false), '</p>');

/// 从 CF_HTML 原始数据里取出真正的 HTML 片段。
///
/// CF_HTML 的格式是：
/// ```
/// Version:0.9
/// StartHTML:0000000105
/// EndHTML:0000000234
/// StartFragment:0000000141
/// EndFragment:0000000198
/// <html><body><!--StartFragment--><h1>标题</h1><!--EndFragment--></body></html>
/// ```
/// 头部的偏移量是**字节**偏移，中文内容下极易算错，所以优先用
/// `<!--StartFragment-->` / `<!--EndFragment-->` 标记定位（ASCII 唯一串，
/// 不受编码影响）；没有标记时退化到从 `<html` 截断（丢掉键值头）。
///
/// 认不出来一律返回 null —— 宁可当没有 HTML，也不能把 `Version:0.9` 当正文粘进去。
String? extractCfHtmlFragment(String raw) {
  if (raw.trim().isEmpty) return null;

  const String startMark = '<!--StartFragment-->';
  const String endMark = '<!--EndFragment-->';
  final int start = raw.indexOf(startMark);
  final int end = raw.indexOf(endMark);
  if (start >= 0 && end > start) {
    final String fragment = raw.substring(start + startMark.length, end).trim();
    return fragment.isEmpty ? null : fragment;
  }

  // 兜底：没有 fragment 标记 ⇒ 从 <html / <body 起截（头部键值行必须丢掉）。
  final String lower = raw.toLowerCase();
  final int htmlAt = lower.indexOf('<html');
  final int bodyAt = lower.indexOf('<body');
  final int at = htmlAt >= 0 ? htmlAt : bodyAt;
  if (at < 0) return null;
  final String fallback = raw.substring(at).trim();
  return fallback.isEmpty ? null : fallback;
}
