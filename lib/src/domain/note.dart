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
  canvas;

  String get name => switch (this) {
    NoteKind.spark => 'spark',
    NoteKind.note => 'note',
    NoteKind.canvas => 'canvas',
  };

  static NoteKind fromName(String value) => NoteKind.values.firstWhere(
    (NoteKind k) => k.name == value,
    // 历史行可能还写着 'stream'（v16 之前的隐藏容器）：迁移已删除，
    // 万一读到按普通笔记兜底，绝不崩。
    orElse: () => NoteKind.spark,
  );
}

/// 一条**速记**（心流收件箱条目）。
///
/// 2026-10-17 起心流**独立存储**（`stream_items` 表，见 `StreamStore`）：
/// 不再是一篇隐藏笔记里的块，与 `notes` / `blocks` 无任何外键关系。
///
/// 单向：心流从不读笔记 / 画布内容；条目可被**用户手动**转为新内容或复制 /
/// 引用到已有笔记、画布（导出），但反过来永远不成立。
class StreamItem {
  const StreamItem({
    required this.id,
    required this.text,
    required this.createdAt,
    DateTime? updatedAt,
    this.archivedAt,
    this.deletedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  /// 条目 id（引用块的 `ref_id` 认它；与 `blocks.id` 无关系）。
  final String id;

  /// 条目文本（纯文本，低摩擦：没有标题、标签、富文本）。
  final String text;

  /// 记下来的时间（卡片 meta 行的相对时间用）。
  final DateTime createdAt;

  /// 最后一次改文本的时间。
  final DateTime updatedAt;

  /// 已处理 / 归档的时间；`null` = 还在「待处理」区。
  final DateTime? archivedAt;

  /// 进回收站的时间；`null` = 未删除。
  final DateTime? deletedAt;

  bool get archived => archivedAt != null;

  bool get deleted => deletedAt != null;
}

/// 一条速记「流去了哪里」的记录（2026-10-18 定：**处理台账**的数据行）。
///
/// 「已处理」原本只是一个能拿回来的仓库（等于可撤销的删除），它没回答速记真正
/// 要的那件事——**这条灵感最后变成了什么**。台账每次导出写一行，回收列举：
/// `一条想法 → 笔记《周五的闲聊》`。
class StreamExport {
  const StreamExport({
    required this.id,
    required this.streamId,
    required this.targetType,
    required this.targetId,
    required this.targetTitle,
    required this.kind,
    required this.createdAt,
    this.targetBlockId,
  });

  final String id;

  /// 源速记 id。
  final String streamId;

  /// `'note'` / `'canvas'`。
  final String targetType;

  /// 目标笔记 / 画布 id（点击可跳过去）。
  final String targetId;

  /// **当时的标题快照**：目标之后改名甚至删了，台账里这条仍然读得懂
  /// （它是回忆录，不是导航索引 ⇒ 不能跟着目标一起变）。
  final String targetTitle;

  final StreamExportKind kind;
  final DateTime createdAt;

  /// 导出时**真正写入的那个块**（ref 块 / 第一个段落块 / 画布卡的块）。
  ///
  /// P2 的落点：点「流向」时 `locate(noteId, blockId)` 直接定位并高亮这一段，
  /// 而不是把人扔到那篇笔记的顶部自己找。老行（v18 之前）为 null ⇒ 退化为只跳笔记。
  final String? targetBlockId;

  bool get isCanvas => targetType == 'canvas';
}

/// 一条速记的**媒体附件**（2026-10-18 加）：图片 / 视频。
///
/// 只存**指向 app 私有目录里那份独立副本**的绝对路径——源截图被用户删了也不影响
/// （见 [StreamStore] 的"拷贝导入"与删除级联）。二进制不进 SQLite（视频太大）。
class StreamAttachment {
  const StreamAttachment({
    required this.id,
    required this.streamId,
    required this.kind,
    required this.path,
    this.width,
    this.height,
    this.durationMs,
    required this.sort,
    required this.createdAt,
  });

  final String id;
  final String streamId;

  /// `'image'` | `'video'`。
  final String kind;

  /// app 私有目录里**副本**的绝对路径（绝不引用源位置）。
  final String path;

  final int? width;
  final int? height;

  /// 视频时长（毫秒）；图片为 null。
  final int? durationMs;

  /// 同条目内的展示顺序（升序）。
  final int sort;

  final DateTime createdAt;

  bool get isVideo => kind == 'video';
}

/// 新增附件时的入参：UI 已完成"拷进私有目录"，把最终路径传进来即可。
class StreamAttachmentInput {
  const StreamAttachmentInput({
    required this.kind,
    required this.path,
    this.width,
    this.height,
    this.durationMs,
  });

  final String kind;
  final String path;
  final int? width;
  final int? height;
  final int? durationMs;
}

/// 导出的**手法**：决定了台账里那一行动词怎么写。
enum StreamExportKind {
  /// 笔记里插了指向这条速记的 `ref`（活链，双向可跳）。
  reference('引用'),

  /// 复制成笔记段落 / 画布独立卡（快照，之后互不相干）。
  copy('复制'),

  /// 转成一篇新笔记。
  toNote('转为笔记'),

  /// 转成一张新画布。
  toCanvas('转为画布'),

  /// 与别的一起合并成一篇新笔记。
  merge('合并进');

  const StreamExportKind(this.label);

  /// 台账里显示给用户的动词。
  final String label;

  static StreamExportKind parse(String s) => switch (s) {
    'reference' => reference,
    'toNote' => toNote,
    'toCanvas' => toCanvas,
    'merge' => merge,
    _ => copy,
  };
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
