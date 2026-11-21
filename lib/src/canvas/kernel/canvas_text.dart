import 'canvas_item.dart';
import 'canvas_mindmap.dart';

/// 从画布的 item 里抽出**可搜索文字**（2026-11-21）：
/// 画布正文是 Canvas JSON，但其中的文字（`CardItem` / 导图节点 / 分组标题）
/// 应该像笔记正文一样投影进 `notes.plain_text`，让列表页内搜索（走 summary）
/// 和全局搜索的 plain_text 兜底路都能命中。
///
/// **只收文字**：图片 / 形状 / 连线 / 墨迹没有可搜文字，跳过——这与笔记的
/// 图片/视频块不进 plainText 是同一条口径（文字搜索只搜文字）。
///
/// 顺序按传入的 z 序（[CanvasDocument.items] 已按 itemOrder 排好），用换行连接
/// ——`Note.summarize` 会把它压成单行摘要，全局关键词索引按空白切词，换行等价于
/// 分隔，不会把两张卡的字粘成一个词。
String canvasSearchableText(Iterable<CanvasItem> items) =>
    items.map(canvasItemText).where((String t) => t.isNotEmpty).join('\n');

/// **单件** item 的可搜索文字（2026-11-21 画布内搜索用）：
/// 卡片正文 / 分组标题 / 导图（全部节点，空格连接）。无文字的 item 返回空串。
///
/// 与 [canvasSearchableText] 同一口径（同一套分支），只是不拼接多件——
/// 搜索面板要"命中哪张卡就带我去看哪张"，所以得按件取。
String canvasItemText(CanvasItem item) {
  switch (item) {
    case CardItem():
      return item.text.trim();
    case CanvasGroupItem():
      return item.label.trim();
    case MindMapItem():
      final List<String> parts = <String>[];
      _collectMindText(item.root, parts);
      return parts.join('\n');
    default:
      return '';
  }
}

void _collectMindText(MindNode node, List<String> out) {
  final String t = node.text.trim();
  if (t.isNotEmpty) out.add(t);
  for (final MindNode child in node.children) {
    _collectMindText(child, out);
  }
}
