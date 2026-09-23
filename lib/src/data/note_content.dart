import 'dart:convert';

import '../editor/core/note_document_adapter.dart';

/// 正文在存储层的三种形态。
///
/// **写出格式由当前编辑器决定**，不由本文件决定：
/// 编辑器仍是 quill → 落库 Delta；换成 appflowy 后 → 落库 v2 块树
/// （切换时机与"为什么不能提前切"见 [NoteDocumentAdapter] 的类注释）。
/// 本文件的唯一职责：**把任意存储形态读成编辑器与预览能用的形状**。
enum NoteContentFormat {
  /// v2 块树 JSON：`{"v":2,"format":"blocks","document":{...}}`（块节点带 id）。
  blocks,

  /// 存量 Quill Delta JSON：`[...]`（quill 写出）或 `{"ops":[...]}`。
  delta,

  /// 历史纯文本（非 JSON，或无法解析的脏数据）。
  plainText,
}

/// 笔记正文读入：格式识别 + 纯文本提取 +（过渡期）quill Delta 输出。
///
/// ## 本文件**不依赖 flutter_quill**
/// 纯文本提取统一走 [NoteDocumentAdapter]——与将来的编辑器读**同一份实现**，
/// 于是换成 appflowy 时数据层不需要再改成一次。旧实现是
/// `quill.Document.fromJson(...).toPlainText()`，正是迁移清单里
/// 「数据层解耦」要拆掉的那一处。
///
/// ## 三种存储形态怎么读
/// | 存储形态 | 识别依据 | `plainText` 来源 | `delta`（供 quill） |
/// |---|---|---|---|
/// | v2 块树 | `format == 'blocks'` | 适配器读块树 | 纯文本兜底 |
/// | Quill Delta | `[...]` / `{"ops":[...]}` | 适配器（Delta→Document） | 原样（清洗后） |
/// | 历史纯文本 | 其余（含脏数据） | 原文 | 单段 Delta |
class NoteContent {
  const NoteContent({
    required this.format,
    required this.delta,
    required this.plainText,
  });

  /// 存储层实际形态（便于调用方分流，例如编辑器替换期做灰度）。
  final NoteContentFormat format;

  /// 供**过渡期** quill 编辑器装载的 Delta。
  ///
  /// 非 Delta 形态（块树/纯文本）以纯文本兜底，保证「不丢字」且 quill
  /// 不会拿到非法输入。编辑器换成 appflowy 后本字段及其消费者一并删除。
  final List<dynamic> delta;

  /// 纯文本：列表预览 / 字数 / 搜索（将来向量化的输入）。
  final String plainText;

  /// 原始数据是否已是富文本（false = 历史纯文本）。
  bool get wasRichText => format != NoteContentFormat.plainText;

  factory NoteContent.decode(String raw) {
    final String text = raw.trim();

    // Delta：quill 写出的是裸数组 `[...]`。
    if (text.startsWith('[') && _decodedIsList(text)) {
      return NoteContent(
        format: NoteContentFormat.delta,
        delta: _sanitizedDelta(text),
        plainText: NoteDocumentAdapter.plainTextOfStoredContent(text),
      );
    }

    if (text.startsWith('{')) {
      if (_jsonIsBlockTree(text)) {
        // 块树内容在当前（quill）编辑器里没有等价渲染 → 纯文本兜底展示。
        // 实际不会发生：编辑器换成 appflowy 之前落库格式始终是 Delta
        // （见 NoteDocumentAdapter「何时切换落库格式」）。
        final String plain = NoteDocumentAdapter.plainTextOfStoredContent(text);
        return NoteContent(
          format: NoteContentFormat.blocks,
          delta: _deltaOfPlainText(plain),
          plainText: plain,
        );
      }
      if (_jsonHasOps(text)) {
        return NoteContent(
          format: NoteContentFormat.delta,
          delta: _sanitizedDelta(text),
          plainText: NoteDocumentAdapter.plainTextOfStoredContent(text),
        );
      }
    }

    // 历史纯文本 / 空文本 / 无法识别的脏数据：原样当纯文本（**绝不丢字**）。
    return NoteContent(
      format: NoteContentFormat.plainText,
      delta: _deltaOfPlainText(raw),
      plainText: raw,
    );
  }

  /// 纯文本 → 单段 Delta。
  ///
  /// Quill 要求文档非空且以换行结尾：空文本给单个 `'\n'`（合法空文档），
  /// 非空文本确保换行收尾，否则 `quill.Document.fromJson` 直接抛异常。
  static List<dynamic> _deltaOfPlainText(String raw) {
    final String insertText = raw.isEmpty
        ? '\n'
        : (raw.endsWith('\n') ? raw : '$raw\n');
    return <dynamic>[
      <String, dynamic>{'insert': insertText},
    ];
  }

  /// Delta JSON（`[...]` 或 `{"ops":[...]}`）→ 清洗后的 ops。
  static List<dynamic> _sanitizedDelta(String text) {
    final Object? decoded = _tryDecode(text);
    final Object? ops = decoded is List
        ? decoded
        : (decoded is Map ? decoded['ops'] : null);
    if (ops is! List) return _deltaOfPlainText('');
    return <dynamic>[for (final Object? op in ops) _cleanOperation(op)];
  }

  static Object? _tryDecode(String text) {
    try {
      return jsonDecode(text);
    } on Object catch (_) {
      return null;
    }
  }

  static bool _decodedIsList(String text) => _tryDecode(text) is List;

  static bool _jsonIsBlockTree(String text) {
    final Object? decoded = _tryDecode(text);
    return decoded is Map &&
        decoded['format'] == NoteDocumentAdapter.blocksFormat;
  }

  static bool _jsonHasOps(String text) {
    final Object? decoded = _tryDecode(text);
    return decoded is Map && decoded['ops'] is List;
  }

  /// 清洗单个 Delta 操作：移除非法的 `header: 0`。
  ///
  /// 旧版正文按钮写入过 0，Quill 渲染时会抛 `Invalid level 0`——
  /// 这是**给 quill 的兼容处理**，appflowy 侧不需要（其标题层为 1~6）。
  static Object? _cleanOperation(Object? op) {
    // `op['attributes']['header']` 曾是 **dynamic 调用**（绕过类型检查）——
    // 先落到局部变量并定类型，既让 lint 通过，也让这行在编译期可查。
    //
    // ⚠️ 参数与返回值是 `Object?` 而**不是** `dynamic`（2026-09-21 收紧）：它只被
    // `is` 判过，从没被当动态调用过。用 `dynamic` 声明等于"允许"将来某行写出绕过
    // 编译检查的调用；`Object?` 让那种写法直接编译不过 —— 动态性被锁死在"必须先
    // 收窄"这唯一一条路上。
    final Object? rawAttributes = op is Map ? op['attributes'] : null;
    if (op is Map<String, dynamic> &&
        rawAttributes is Map &&
        rawAttributes['header'] == 0) {
      final Map<String, dynamic> attributes = Map<String, dynamic>.from(
        rawAttributes,
      )..remove('header');
      return <String, dynamic>{...op, 'attributes': attributes};
    }
    return op;
  }
}
