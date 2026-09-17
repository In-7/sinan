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
  canvas;

  String get name => switch (this) {
        NoteKind.spark => 'spark',
        NoteKind.note => 'note',
        NoteKind.canvas => 'canvas',
      };

  static NoteKind fromName(String value) =>
      NoteKind.values.firstWhere((NoteKind k) => k.name == value,
          orElse: () => NoteKind.spark);
}

/// 一条笔记。
class Note {
  const Note({
    required this.id,
    required this.kind,
    required this.title,
    required this.content,
    required this.plainText,
    required this.contentHash,
    required this.createdAt,
    required this.revisedAt,
    this.promotedAt,
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
  /// 从正文提取的纯文本（列表预览 / Tooltip / 搜索用）。
  final String plainText;
  /// 内容 SHA-256。用于判定「是否真的改了」，没改就不落盘。
  final String contentHash;
  final DateTime createdAt;
  final DateTime revisedAt;
  /// 预留字段（当前 UI 未使用）。
  final DateTime? promotedAt;
}
