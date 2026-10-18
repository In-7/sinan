/// 全局回收站里的条目类型。
enum TrashKind { stream, note, canvas }

/// 全局回收站的一条记录（笔记 / 画布 / 速记统一形态）。
///
/// 只带**列表展示**需要的字段：标题、类型、删除时间。正文/内容不背进快照
/// （恢复时由各 store 自己按 id 取）。
class TrashEntry {
  const TrashEntry({
    required this.kind,
    required this.id,
    required this.title,
    required this.deletedAt,
  });

  final TrashKind kind;
  final String id;
  final String title;
  final DateTime deletedAt;
}
