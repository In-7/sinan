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
String canvasSearchableText(Iterable<CanvasItem> items) {
  final List<String> parts = <String>[];
  for (final CanvasItem item in items) {
    switch (item) {
      case CardItem():
        final String t = item.text.trim();
        if (t.isNotEmpty) parts.add(t);
      case CanvasGroupItem():
        final String t = item.label.trim();
        if (t.isNotEmpty) parts.add(t);
      case MindMapItem():
        _collectMindText(item.root, parts);
      default:
        break;
    }
  }
  return parts.join('\n');
}

void _collectMindText(MindNode node, List<String> out) {
  final String t = node.text.trim();
  if (t.isNotEmpty) out.add(t);
  for (final MindNode child in node.children) {
    _collectMindText(child, out);
  }
}
