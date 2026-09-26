import 'dart:ui' show Rect;

import '../kernel/canvas_document.dart';
import '../kernel/canvas_edge.dart';
import '../kernel/canvas_item.dart';
import '../kernel/canvas_mindmap.dart';

/// 系统提示词：角色 + **输出契约** + 坐标规则。
///
/// 分三层是刻意的——把"是什么角色"、"输出什么形状"、"坐标怎么算"混成一大段散文，
/// 是本地小模型跑偏的主要原因。这里逐条编号，且只写模型必须知道的事。
///
/// ⚠️ 动作清单与 schema 是 [kAiActionOps] / [kAiActionSchema] 的镜像，改动时三处
/// 必须同步：提示词漏写一个 op，模型就永远不会用它。
const String kAiSystemPrompt = '''
你是笔记画布的操作助手。用户会用一句中文说明想怎么调整画布，你要把它翻译成一组结构化动作。

规则：
1. 只输出 JSON，形如 {"actions": [...]}，不要任何解释文字。
2. 坐标一律用**视口归一化**值：x、y 取 0~1，表示在当前可见范围内的相对位置
   （[0,0] 是左上角，[1,1] 是右下角）。**绝对不要**输出世界坐标或像素值。
3. 矩形写成 [左, 上, 右, 下] 四个归一化数；点写成 [x, y] 两个数。
4. 只能用这些动作：
   - reference_block：把一个**已存在的块**引用到画布上成卡片。参数 blockId、at（中心点）。
   - add_shape：加形状。参数 kind（rectangle / ellipse）、rect。
   - add_mindmap：加思维导图。参数 rect、root（中心主题）、children（一级分支文本数组）。
   - move_item：移动已有元素到新位置。参数 id、at（新中心点）。
   - set_text：改写某张卡片的文本。参数 id、text。
   - connect：连线。参数 from、to（都是 **blockId**）、endShape（arrow / dot / diamond / none）。
   - group：把若干元素框成一组。参数 ids（至少两个，不能含已有的分组框）、label（可选标题）。
   - ungroup：解散分组框。参数 ids（填**分组框**的 id）。
   - delete：删除元素。参数 ids。
5. 只能引用"可引用的块"清单里出现过的 blockId；只能引用元素清单里出现过的 id。
   清单里没有的一律不要写——写了也会被忽略。
6. 不要臆造用户的意图。指令含糊时，宁可少做（返回空数组）也不要乱改画布。
''';

/// 把画布现状与候选块拼成给模型的上下文文本（**纯函数**）。
///
/// ## 为什么内容刻意精简
/// ① 上下文越短，本地小模型越不容易跑偏 —— 所以每个元素只给
///    `id / 类型 / 一句摘要 / 归一化矩形`，**不给**颜色、角度、meta 那些它用不上的；
/// ② 笔迹只报"有几条"，不逐条列：笔迹没有语义，列出来只是噪声（也最占 token）；
/// ③ 坐标用**归一化**值，与要求模型输出的口径一致 —— 同一套坐标说话，模型
///    不用做两次换算，这也正是 tldraw agent 做坐标空间转换的用意。
String buildCanvasContext(
  CanvasDocument doc, {
  required Rect viewportWorld,
  Map<String, String> candidateBlocks = const <String, String>{},
}) {
  final StringBuffer out = StringBuffer();

  out.writeln('## 画布现状');
  if (viewportWorld.width <= 0 || viewportWorld.height <= 0) {
    // 视口还没布局（首帧）：此时归一化没有基准，明说比给个错的强。
    out.writeln('（视口尺寸未知，暂不能给出坐标）');
  } else {
    out.writeln(
      '视口：宽 ${viewportWorld.width.round()} × 高 ${viewportWorld.height.round()}'
      '（归一化坐标以它为基准）',
    );
  }

  final List<CanvasItem> items = doc.items;
  if (items.isEmpty) {
    out.writeln('元素：无');
  } else {
    out.writeln('元素：');
    for (final CanvasItem item in items) {
      out.writeln('  ${item.id}  ${describeItem(item, viewportWorld)}');
    }
  }

  final List<CanvasEdge> edges = doc.edges;
  if (edges.isEmpty) {
    out.writeln('连线：无');
  } else {
    out.writeln('连线：');
    for (final CanvasEdge e in edges) {
      out.writeln('  ${e.fromId} → ${e.toId}');
    }
  }

  if (doc.strokes.isNotEmpty) {
    out.writeln('手绘笔迹：${doc.strokes.length} 条（没有文本；"这里画过东西"这个信息够用了）');
  }

  out.writeln();
  out.writeln('## 可引用的块（只能从中选 blockId）');
  if (candidateBlocks.isEmpty) {
    out.writeln('（无）');
  } else {
    candidateBlocks.forEach((String id, String label) {
      out.writeln('  $id  $label');
    });
  }
  return out.toString();
}

/// 一个元素的一句话描述：`类型 "摘要"  矩形=[归一化 l,t,r,b]`。
///
/// 公开是为了单测（"归一化坐标算对没有"是这一层唯一的真风险）。
String describeItem(CanvasItem item, Rect viewport) {
  final String kind = itemKindName(item);
  final String label = _labelOf(item);
  final String text = label.isEmpty ? '' : ' "$label"';
  return '$kind$text  rect=${normalizedRectOf(item.rect, viewport)}';
}

/// 元素类型名（给模型的词汇表；也是提示词与测试共用的口径）。
String itemKindName(CanvasItem item) => switch (item) {
  CardItem() => 'card',
  CanvasGroupItem() => 'group',
  MindMapItem() => 'mindmap',
  ShapeItem(:final CanvasShapeKind kind) => 'shape:${kind.name}',
  ImageItem() => 'image',
  _ => 'item',
};

/// 世界矩形 → 归一化 `[l, t, r, b]`（保留三位小数：够用且短）。
String normalizedRectOf(Rect r, Rect viewport) {
  if (viewport.width <= 0 || viewport.height <= 0) return '[?]';
  double n(double v, double origin, double size) =>
      ((v - origin) / size).clamp(0.0, 1.0);
  String f(double v) => v.toStringAsFixed(3);
  return '[${f(n(r.left, viewport.left, viewport.width))}, '
      '${f(n(r.top, viewport.top, viewport.height))}, '
      '${f(n(r.right, viewport.left, viewport.width))}, '
      '${f(n(r.bottom, viewport.top, viewport.height))}]';
}

String _labelOf(CanvasItem item) => switch (item) {
  CardItem(:final String text) => oneLine(text),
  CanvasGroupItem(:final String label) => oneLine(label),
  // 思维导图给"中心主题 + 分支数"，比列全树省得多。
  MindMapItem(:final MindNode root) =>
    '${oneLine(root.text)}（${root.children.length} 个分支）',
  // 图片类没有文本，给文件名足够定位。
  ImageItem(:final String src) => _basename(src),
  _ => '',
};

/// 压成一行并截断：多行文本会把清单撑爆，而坐标才是清单的重点。
///
/// 公开是因为宿主拼**候选块标签**时要用同一个口径（`「笔记标题」文本摘要`）——
/// 两处各写一份截断逻辑，迟早一个 40 字一个 80 字。
String oneLine(String s, {int max = 40}) {
  final String flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= max ? flat : '${flat.substring(0, max)}…';
}

String _basename(String path) {
  final int slash = path.lastIndexOf(RegExp(r'[/\\]'));
  return slash >= 0 ? path.substring(slash + 1) : path;
}
