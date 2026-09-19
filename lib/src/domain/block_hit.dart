import 'note.dart';

/// 全库块搜索的一条命中（「引用块」选择器的数据）。
///
/// 它同时带着块**和**它所属的笔记——这正是块引用能做成**一级搜索**的原因：
/// sinan 的 `blocks` 表是全库扁平的（块不"住"在文件里，只是**属于**某篇笔记），
/// 一次 JOIN 就能给出"块内容 + 来源笔记标题"，用户不必先回答"它在哪篇里"。
class BlockHit {
  const BlockHit({
    required this.blockId,
    required this.text,
    required this.blockType,
    required this.noteId,
    required this.noteTitle,
    required this.noteKind,
  });

  /// 块 id（引用写进 `ref_id` 的就是它）。
  final String blockId;

  /// 块的纯文本（UI 负责截断）。
  final String text;

  /// 块类型（`paragraph` / `heading` / `todo` …），UI 可据此出图标。
  final String blockType;

  /// 块所属笔记的 id。
  final String noteId;

  /// 块所属笔记的标题——在**全库**结果里它是唯一的定位线索。
  final String noteTitle;

  /// 所属笔记是文档还是画布。
  final NoteKind noteKind;
}
