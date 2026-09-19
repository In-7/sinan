/// 嵌入预览的一行（**只读**渲染用，见 `ref_block_component.dart`）。
///
/// 为什么不是"把目标块树原样渲染"：引用目标属于**另一篇笔记**，它没有本编辑器
/// 的 `EditorState`，用块组件去渲染外来的节点会牵出整条渲染链（样式配置、
/// 选区、事务）。嵌入的定位是"在这里看到内容"，所以只带够画的那些信息。
///
/// ⚠️ 由此也天然规避了**嵌入递归**：预览只取**有文本**的块，`ref` 块自己没有
/// 文本 ⇒ 不会出现"A 嵌 B、B 又嵌 A"的无限展开。
class EmbedLine {
  const EmbedLine({required this.text, required this.blockType, this.checked});

  final String text;

  /// 块类型（`paragraph` / `heading` / `quote` / `code` / `todo_list` …）。
  final String blockType;

  /// 仅 `todo_list`：勾选态（只读展示，不在这里编辑）。
  final bool? checked;
}
