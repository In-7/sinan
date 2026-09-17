/// 附件元数据：Delta 嵌入 data / 块节点 `meta` 属性的强类型视图。
///
/// 存储形态是一段 JSON：`{"path": "...", "name": "...", "size": 12345}`。
/// 附件文件**复制进数据目录**（`media/attachments/`）——库自包含，
/// 源文件移动/删除不影响；代价是大文件落盘耗时（选入时一次性）。
///
/// 本文件**不依赖任何编辑器库**：quill 的 EmbedBuilder 与 appflowy 的
/// 块组件共用它，这样迁移期间不会出现两份附件元数据定义。
class AttachmentMeta {
  const AttachmentMeta({
    required this.path,
    required this.name,
    required this.size,
  });

  factory AttachmentMeta.fromJson(Map<String, dynamic> json) => AttachmentMeta(
    path: json['path'] as String,
    name: json['name'] as String,
    size: (json['size'] as num).toInt(),
  );

  final String path;
  final String name;
  final int size;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'name': name,
    'size': size,
  };

  /// 人类可读的大小（B/KB/MB）。
  String get sizeLabel {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
