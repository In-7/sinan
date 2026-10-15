// dart:convert 供 [Note.parseTags] 解析 `notes.tags` 列。
import 'dart:convert';

/// 笔记形态：灵感卡片 -> 正式笔记。
enum NoteKind {
  /// 灵感卡片：随手记的碎片想法，尚未成型。
  spark,

  /// 正式笔记：已从灵感演变、值得长期保留的内容。
  note,

  /// 无限画布：手写墨迹 / 图片 / 卡片（见 `docs/canvas_architecture.md`）。
  ///
  /// 数据库侧 v6 迁移已把 `'canvas'` 加进 `notes.kind` 的 CHECK 约束
  /// （`docs/data_layer.md` 评审结论 1），Dart 侧 2026-09-16 同步。
  /// 其正文存画布 JSON（`CanvasController.toJson`），与块树互不冲突
  /// ——画布笔记与文档笔记是**两条不同的笔记**。
  canvas,

  /// 心流收件箱的**系统容器**（2026-10-16 用户定）：一篇隐藏的特殊笔记，只装心流块，
  /// 不进文库 / 搜索 / 日历 / 收藏。心流块可被笔记 / 画布**单向**引用或注入
  /// （见 [NoteStore] 的 stream 方法）；心流本身不读用户笔记内容。
  stream;

  String get name => switch (this) {
    NoteKind.spark => 'spark',
    NoteKind.note => 'note',
    NoteKind.canvas => 'canvas',
    NoteKind.stream => 'stream',
  };

  static NoteKind fromName(String value) => NoteKind.values.firstWhere(
    (NoteKind k) => k.name == value,
    orElse: () => NoteKind.spark,
  );
}

/// 一条心流（收件箱条目）：[NoteStore] 心流容器的段落块投影（块 id + 文本）。
///
/// 心流与笔记**单向**：心流只经 [NoteStore] 的 stream 方法读写自己那个隐藏容器，
/// 不读用户笔记；条目可被笔记 / 画布**引用或注入**（导出），但不反过来。
class StreamItem {
  const StreamItem({
    required this.id,
    required this.text,
    required this.createdAt,
  });

  /// 底层块 id（引用 / 注入 / 反链都认它）。
  final String id;

  /// 条目文本。
  final String text;

  /// 落库时间（卡片 meta 行的相对时间用）。
  final DateTime createdAt;
}

/// 一条笔记。
class Note {
  const Note({
    required this.id,
    required this.kind,
    required this.title,
    required this.content,
    required this.plainText,
    required this.summary,
    required this.contentHash,
    required this.createdAt,
    required this.revisedAt,
    this.promotedAt,
    this.tags = const <String>[],
  });

  final String id;
  final NoteKind kind;
  final String title;

  /// 正文。**格式由当前编辑器决定**（写出方见 NoteDocumentAdapter）：
  /// - quill 仍是编辑器 → Quill Delta JSON（`[...]` 裸数组）；
  /// - 换成 appflowy 后 → v2 块树（`{"v":2,"format":"blocks",...}`，块节点带稳定 id）。
  ///
  /// 历史数据还可能有纯文本或 `{"ops":[...]}` 包装形态。读取一律走
  /// `NoteContent.decode`（三形态通吃，不依赖编辑器库）。
  final String content;

  /// 从正文提取的纯文本（全文搜索 / 字数统计用；**列表快照不再带它**，
  /// 见 [summary] 与 v13 迁移）。
  final String plainText;

  /// 列表快照专用投影：[plainText] 的前 [summaryLength] 个字符（v13 迁移）。
  ///
  /// 主页卡片 4 行摘要 / 无标题借首行只读它——`allNotes()` 全表快照只 SELECT
  /// 这一列而非整篇 `plain_text`，万篇级笔记的快照内存降一个量级（行也更窄、
  /// 查询更快）。与 [plainText] 在每次保存时同步写入；存量数据由 v13
  /// `substr(plain_text, 1, n)` 一次性回填。
  final String summary;

  /// 摘要截断长度（字符）。卡片内容区 4 行约 60 个中文字，160 留足
  /// 「无标题笔记借走首行后还要有 3 行余料」的余量。
  static const int summaryLength = 160;

  /// 摘要截断：超过 [summaryLength] 取前缀，否则原样返回。
  /// 写路径（[NoteStore]）与迁移回填的 SQL `substr(…,1,n)` 同一口径。
  static String summarize(String plainText) => plainText.length <= summaryLength
      ? plainText
      : plainText.substring(0, summaryLength);

  /// 内容 SHA-256。用于判定「是否真的改了」，没改就不落盘。
  final String contentHash;
  final DateTime createdAt;
  final DateTime revisedAt;

  /// 预留字段（当前 UI 未使用）。
  final DateTime? promotedAt;

  /// 标签（分类）。**跨 kind 一套池子**——kind 已是"类型"维度（spark/note/canvas），
  /// 标签别按形态分家（两层正交：搜索里可同时叠 kind 与标签过滤）。
  ///
  /// 存储形态：`notes.tags` 列（v12 迁移）= JSON 字符串数组；内存里是归一化
  /// 后的 [List]（见 [sanitizeTags]）。
  final List<String> tags;

  /// 标签入库/进内存前的归一化：逐个 trim、丢空串、去重（**保序**）。
  /// UI 传原始列表即可，归一化统一在这里做（读取路径 [parseTags] 也走它）。
  static List<String> sanitizeTags(List<String> raw) {
    final List<String> out = <String>[];
    for (final String t in raw) {
      final String v = t.trim();
      if (v.isEmpty || out.contains(v)) continue;
      out.add(v);
    }
    return out;
  }

  /// 解析库里的 `tags` 列（JSON 数组字符串）。脏数据 / 空值 → 空列表：
  /// 标签是装饰元数据，解析失败绝不许把整篇笔记读挂。
  static List<String> parseTags(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <String>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return sanitizeTags(<String>[
        for (final Object? v in decoded)
          if (v is String) v,
      ]);
    } on FormatException {
      return const <String>[];
    }
  }
}
