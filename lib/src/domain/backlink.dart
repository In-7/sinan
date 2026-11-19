import 'note.dart';

/// 一条**反链**：某处引用了当前笔记（或它的某一块）。
///
/// ## 为什么粒度是"块 + 容器"而不是"笔记 → 笔记"
/// sinan 的引用边是**结构化**的（外键 / `props_json` 里的 id），不是正文里的
/// `[[…]]` 文本。真正存在的边只有两类：
///
/// 1. **文档**：某篇笔记里的 `ref` 块（`type='ref'`，`props_json.ref_type =
///    'note' | 'block'`）；
/// 2. **画布**：画布上的卡片（`canvas_items.block_id` 指向某个块 —— 卡片本就
///    是"块的视图"）。
///
/// 两者都指向**块**，于是"笔记之间"的关系是它在容器这一层的投影：A 拥有块 X、
/// B 引用块 X ⇒ A 与 B 相关。查询因此不需要一张"链接表"。
class Backlink {
  const Backlink({
    required this.sourceNoteId,
    required this.sourceTitle,
    required this.sourceKind,
    required this.viaBlockId,
    required this.viaCanvasCard,
    required this.context,
  });

  /// 引用方的笔记 id（文档或画布）。
  final String sourceNoteId;

  /// 引用方的标题（空标题由 UI 显示占位，不在这里编）。
  final String sourceTitle;

  /// 引用方是文档还是画布 —— UI 用它出徽标。
  final NoteKind sourceKind;

  /// 承载这条引用的块：
  /// - 文档侧 = 那个 `ref` 块的 id（跳过去可高亮它）；
  /// - 画布侧 = 卡片指向的 `block_id`（不是卡片 id）。
  final String viaBlockId;

  /// 来源是**画布卡片**（false = 文档里的 `ref` 块）。
  final bool viaCanvasCard;

  /// 引用处**附近的文字**（上下文）；取不到时为空串。
  ///
  /// 只有来源标题时，用户看不出"它为什么引用我"——Roam / Logseq 的反链都带
  /// 这一句，它是判断要不要点进去的唯一依据。
  ///
  /// 取值口径（见 `NoteStore.backlinks`）：
  /// - 文档侧 = `ref` 块**前面**最近一个有文本的块（`ref` 块自身没有文本）；
  /// - 画布侧 = 被引用块自己的文本（卡片的真身就是它）。
  final String context;
}
