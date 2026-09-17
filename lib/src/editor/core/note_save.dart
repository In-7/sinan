import 'dart:convert';
import 'dart:isolate';

import 'package:appflowy_editor/appflowy_editor.dart' show Document;

import 'note_document_adapter.dart';

/// 落盘策略：两个可调参数 + 一个纯判断（与 UI 无关，可单测）。
class NoteSavePolicy {
  const NoteSavePolicy({
    this.debounce = const Duration(milliseconds: 500),
    this.isolateEncodeThreshold = 32 * 1024,
  });

  /// 编辑事件到落盘的防抖窗口（正文与标题共用）。
  final Duration debounce;

  /// 纯文本超过这个**字符数**时，JSON 编码挪去后台 isolate。
  ///
  /// 32K 字符 ≈ 一篇数万字的长文；更短的编码耗时不足 1ms，不值得付一次
  /// isolate 冷启动（还要跨 isolate 拷一份内容）。
  final int isolateEncodeThreshold;

  bool shouldEncodeInIsolate(String plainText) =>
      plainText.length > isolateEncodeThreshold;
}

/// 待落盘的数据快照：**必须在编辑器销毁前同步取好**。
///
/// `Document` 只存在于本 isolate 的内存里；异步阶段（编码 + 写库）只允许
/// 持有这里这些纯值。
class NoteSavePayload {
  const NoteSavePayload({required this.json, required this.plainText});

  /// v2 块树 JSON（`jsonEncode` 之前的 Map）。
  final Map<String, Object> json;

  /// 与正文同步抽好的纯文本（列表摘要 / 字数 / 检索都用它）。
  final String plainText;
}

/// 文档落盘的**编排**：把"读内存 Document → 抽纯文本 → 编码（长文走后台
/// isolate）→ 交给写入者"这段与 UI 无关的顺序固定下来。
///
/// ## 为什么分两步（[capture] / [write]）
/// `capture` 刻意**不是 async**：dispose 兜底落盘时编辑器马上就要销毁，
/// 读取 Document 必须同步完成，异步阶段只能持有纯值。这个约束原先只写在
/// 视图的注释里，现在由接口形状本身保证。
///
/// ## 为什么可注入 [isolateEncode]
/// "长文才走 isolate"是一条**业务规则**，但 `Isolate.run` 在生产里不可观测。
/// 留一个钩子后，测试可以断言"长文确实走了隔离、短文没走"，而不必真起 isolate。
class NoteSaver {
  NoteSaver({
    required this.save,
    this.policy = const NoteSavePolicy(),
    Future<String> Function(Map<String, Object> json)? isolateEncode,
  }) : _isolateEncode = isolateEncode ?? _encodeInIsolate;

  /// 写入者（生产上是 `NotesNotifier.saveContent`）。
  final Future<void> Function(String content, {required String plainText}) save;

  final NoteSavePolicy policy;

  final Future<String> Function(Map<String, Object> json) _isolateEncode;

  static Future<String> _encodeInIsolate(Map<String, Object> json) =>
      Isolate.run(() => jsonEncode(json));

  /// **同步阶段**：读内存 Document，产出可跨异步边界持有的纯值快照。
  NoteSavePayload capture(Document document) => NoteSavePayload(
    json: NoteDocumentAdapter.documentToJsonMap(document),
    plainText: NoteDocumentAdapter.plainTextFromDocument(document),
  );

  /// **异步阶段**：编码 + 写库。
  Future<void> write(NoteSavePayload payload) async {
    final String content = policy.shouldEncodeInIsolate(payload.plainText)
        ? await _isolateEncode(payload.json)
        : jsonEncode(payload.json);
    await save(content, plainText: payload.plainText);
  }
}
