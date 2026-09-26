import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'canvas_item.dart';
import 'canvas_media.dart';
import 'canvas_palette.dart';

/// 思维导图节点 id 前缀（存档里 id 的形态：`mn-<递增序号>`）�?
const String _nodeIdPrefix = 'mn-';

/// 节点 id 发生器�?
///
/// ⚠️ �?`CanvasItem` �?id 一样是**进程�?*计数器：存档里的 id 是上一个进�?
/// 分配的，新进程从 0 开�?�?载入存档�?*必须**�?[advanceMindNodeIdSequence]
/// 把它推到已有 id 之后，否则新增节点会与存档里的节点撞 id�?
int _nextNodeId = 0;

/// 把节�?id 发生器推进到所�?[existingIds] 之后（载入存档后必做）�?
///
/// 只认 `mn-<数字>` 形式，其它形态原样忽略（唯一性由后续自增继续保证）�?
void advanceMindNodeIdSequence(Iterable<String> existingIds) {
  for (final String id in existingIds) {
    if (!id.startsWith(_nodeIdPrefix)) continue;
    final int? seq = int.tryParse(id.substring(_nodeIdPrefix.length));
    if (seq != null && seq >= _nextNodeId) _nextNodeId = seq + 1;
  }
}

/// 思维导图的一个节点：文本 + 子节点（树）�?*轻量**——不�?`CardItem`�?
/// 没有自己�?rect（位置由 [layoutMindMap] 推导），所以不占画�?item 的份额�?
class MindNode {
  MindNode({String? id, this.text = '', List<MindNode>? children})
    : id = id ?? '$_nodeIdPrefix${_nextNodeId++}',
      children = children ?? <MindNode>[];

  final String id;

  /// 节点文本�?*可变**：改文本走宿主层，并 [MindMapItem.invalidateLayout]）�?
  String text;

  final List<MindNode> children;

  /// 深拷贝（留给"编辑前后快照 / 撤销"用）�?
  MindNode clone() => MindNode(
    id: id,
    text: text,
    children: <MindNode>[for (final MindNode c in children) c.clone()],
  );

  /// 先序收集所有节�?id（载入后推进 id 发生器用）�?
  void collectIds(List<String> out) {
    out.add(id);
    for (final MindNode c in children) {
      c.collectIds(out);
    }
  }

  /// ⚠️ `children` 为空**不写**这个键（�?`CanvasEdge` 的缺省不写同口径�?
  /// 少一个键，行 �?原文的深比较才不会失配）�?
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'text': text,
    if (children.isNotEmpty)
      'children': <Map<String, dynamic>>[
        for (final MindNode c in children) c.toJson(),
      ],
  };

  factory MindNode.fromJson(Map<String, dynamic> j) => MindNode(
    id: j['id'] as String?,
    text: j['text'] as String? ?? '',
    children: <MindNode>[
      for (final Object? c in (j['children'] as List?) ?? const <Object?>[])
        MindNode.fromJson((c as Map).cast<String, dynamic>()),
    ],
  );
}

/// 思维导图布局常量�?*自然坐标**，世界单位；整图�?`MindMapItem.rect` 等比缩放）�?
abstract final class MindMapMetrics {
  static const double nodeWidth = 132;
  static const double nodeHeight = 38;

  /// 层间距（父子水平间隙）与兄弟间距（垂直间隙）�?
  static const double hGap = 56;
  static const double vGap = 14;

  /// 内容四周留白（自然坐标）�?
  static const double padding = 14;

  /// 节点内文本左右留白�?
  static const double textPadding = 8;

  static const double fontSize = 13;
  static const double lineHeight = 1.3;

  static const double radius = 8;

  /// [CanvasItem.paint] 没给 ink 时的兜底（导�?/ AI 路径 �?"白纸黑墨"口径）�?
  static const ui.Color fallbackInk = ui.Color(0xFF1F1F1F);
}

/// 布局结果：节�?id �?自然坐标（节点左上角�? 内容总尺寸�?
class MindMapLayout {
  const MindMapLayout({required this.positions, required this.size});

  final Map<String, Offset> positions;
  final Size size;
}

/// **独立实现�?tidy-tree 布局**（Reingold–Tilford 思路，约 40 行）�?
///
/// 刻意不引第三方图库：层级 = x（每层固定列宽），垂直位�?= 后序遍历分配
/// （叶子依次排开、父节点**居中于孩�?*）⇒ 子树之间自然不重叠、父节点对齐
/// 孩子中心。坐标是**自然坐标**（原点在内容左上角），与画布/相机无关�?
MindMapLayout layoutMindMap(MindNode root) {
  final Map<String, Offset> positions = <String, Offset>{};
  double nextLeafY = MindMapMetrics.padding;

  /// 放置 [node] 及其子树，返回该子树�?*垂直中心**（供父节点居中）�?
  double place(MindNode node, int depth) {
    final double x =
        MindMapMetrics.padding +
        depth * (MindMapMetrics.nodeWidth + MindMapMetrics.hGap);
    if (node.children.isEmpty) {
      final double y = nextLeafY;
      nextLeafY += MindMapMetrics.nodeHeight + MindMapMetrics.vGap;
      positions[node.id] = Offset(x, y);
      return y + MindMapMetrics.nodeHeight / 2;
    }
    final List<double> centers = <double>[
      for (final MindNode c in node.children) place(c, depth + 1),
    ];
    final double center = (centers.first + centers.last) / 2;
    final double y = center - MindMapMetrics.nodeHeight / 2;
    positions[node.id] = Offset(x, y);
    return center;
  }

  place(root, 0);

  double maxX = 0;
  double maxY = 0;
  for (final Offset o in positions.values) {
    maxX = math.max(maxX, o.dx + MindMapMetrics.nodeWidth);
    maxY = math.max(maxY, o.dy + MindMapMetrics.nodeHeight);
  }
  return MindMapLayout(
    positions: positions,
    size: Size(maxX + MindMapMetrics.padding, maxY + MindMapMetrics.padding),
  );
}

/// JSON 矩形 `[left, top, right, bottom]` �?[Rect]�?
Rect _rectFromJson(List<dynamic> j) => Rect.fromLTRB(
  (j[0] as num).toDouble(),
  (j[1] as num).toDouble(),
  (j[2] as num).toDouble(),
  (j[3] as num).toDouble(),
);

/// 思维导图块：画布上的**容器�?item**�?
///
/// ## 为什么内部节点不�?`CardItem`
/// 节点位置�?*布局算法派生�?*（不是用户手放的），所以不需要各自一�?rect �?
/// 命中/撤销开销——那正是"思维导图复用卡片会太�?的根因。内部节点是轻量
/// [MindNode]（树），整张图作�?*一�?*画布 item 参与拖动/缩放/选中/连线�?
///
/// ## 坐标：自然坐�?+ 等比映射
/// [layoutMindMap] 在自然坐标下算出内容尺寸；绘制时�?[rect] **等比**缩放并居�?
/// （非等比会把节点拉变形）�?用户缩放整张图解——拖动改 [rect] 位置�?
/// 角点手柄改尺寸，都走既有 item 交互，无需专门代码�?
class MindMapItem extends CanvasItem {
  MindMapItem({
    super.id,
    required super.rect,
    super.angle,
    required this.root,
    this.colorSlot,
    super.meta,
  });

  /// 根节点（整棵树）。改树结构后�?[invalidateLayout]�?
  MindNode root;

  /// 语义色槽位（覆盖基类的统一读写口）；`null` = 跟随主题墨色�?
  @override
  CanvasColorSlot? colorSlot;

  MindMapLayout? _layoutCache;

  /// 布局（惰�?+ 缓存；树变化时由 [invalidateLayout] 失效）�?
  MindMapLayout get layout => _layoutCache ??= layoutMindMap(root);

  /// 节点/文本/结构变化后调用：下次绘制重算布局�?
  void invalidateLayout() => _layoutCache = null;

  final Map<String, ui.Paragraph> _paragraphs = <String, ui.Paragraph>{};
  final Map<String, String> _paragraphTexts = <String, String>{};
  ui.Color? _paragraphInk;

  @override
  bool hitTest(Offset world, double radius) =>
      rect.inflate(radius).contains(toLocal(world));

  @override
  void paint(ui.Canvas canvas, {ui.Color? ink, ui.Color? slotColor}) {
    // 语义槽位优先（节点底色与描边按它着色）；无槽位则跟随主题墨色�?
    final ui.Color base = slotColor ?? ink ?? MindMapMetrics.fallbackInk;
    final bool marked = slotColor != null;
    // 文本颜色�?base；颜色变了要重建段落（缓存的是上一种颜色）�?
    if (_paragraphInk != base) {
      _disposeParagraphs();
      _paragraphInk = base;
    }
    final MindMapLayout l = layout;
    if (l.size.width <= 0 || l.size.height <= 0) return;
    // 等比缩放�?rect 并在其中居中（非等比会把节点拉变形）�?
    final double s = math.min(
      rect.width / l.size.width,
      rect.height / l.size.height,
    );
    if (s <= 0) return;
    canvas.save();
    canvas.translate(
      rect.left + (rect.width - l.size.width * s) / 2,
      rect.top + (rect.height - l.size.height * s) / 2,
    );
    canvas.scale(s);
    _paintBranches(canvas, base);
    _paintNodes(canvas, base, marked);
    canvas.restore();
  }

  /// 父子之间的连线：从父节点右中点到子节点左中点，横向三次贝塞尔�?
  void _paintBranches(ui.Canvas canvas, ui.Color base) {
    final ui.Paint paint = ui.Paint()
      ..color = base.withValues(alpha: 0.45)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = ui.StrokeCap.round;

    void walk(MindNode node) {
      final Offset? p = layout.positions[node.id];
      for (final MindNode c in node.children) {
        final Offset? cp = layout.positions[c.id];
        if (p != null && cp != null) {
          final Offset from = Offset(
            p.dx + MindMapMetrics.nodeWidth,
            p.dy + MindMapMetrics.nodeHeight / 2,
          );
          final Offset to = Offset(
            cp.dx,
            cp.dy + MindMapMetrics.nodeHeight / 2,
          );
          final double dx = (to.dx - from.dx) * 0.5;
          canvas.drawPath(
            ui.Path()
              ..moveTo(from.dx, from.dy)
              ..cubicTo(from.dx + dx, from.dy, to.dx - dx, to.dy, to.dx, to.dy),
            paint,
          );
        }
        walk(c);
      }
    }

    walk(root);
  }

  void _paintNodes(ui.Canvas canvas, ui.Color base, bool marked) {
    // 标了语义色时底色/描边加深一档（否则 6% 淡染看不出颜色）�?
    final ui.Paint fill = ui.Paint()
      ..color = base.withValues(alpha: marked ? 0.18 : 0.06);
    final ui.Paint edge = ui.Paint()
      ..color = base.withValues(alpha: marked ? 0.55 : 0.35)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1;

    void walk(MindNode node) {
      final Offset? p = layout.positions[node.id];
      if (p != null) {
        final RRect box = RRect.fromRectAndRadius(
          Rect.fromLTWH(
            p.dx,
            p.dy,
            MindMapMetrics.nodeWidth,
            MindMapMetrics.nodeHeight,
          ),
          const Radius.circular(MindMapMetrics.radius),
        );
        canvas.drawRRect(box, fill);
        canvas.drawRRect(box, edge);
        if (node.text.isNotEmpty) {
          const double textH =
              MindMapMetrics.fontSize * MindMapMetrics.lineHeight;
          canvas.drawParagraph(
            _paragraphOf(node, base),
            Offset(
              p.dx + MindMapMetrics.textPadding,
              p.dy + (MindMapMetrics.nodeHeight - textH) / 2,
            ),
          );
        }
      }
      for (final MindNode c in node.children) {
        walk(c);
      }
    }

    walk(root);
  }

  /// 单行居中段落（超长省略）；按 (节点 id, 文本) 缓存，颜色变化时整体重建�?
  ui.Paragraph _paragraphOf(MindNode node, ui.Color color) {
    final ui.Paragraph? cached = _paragraphs[node.id];
    if (cached != null && _paragraphTexts[node.id] == node.text) return cached;
    final ui.Paragraph p =
        (ui.ParagraphBuilder(
                ui.ParagraphStyle(
                  fontSize: MindMapMetrics.fontSize,
                  height: MindMapMetrics.lineHeight,
                  textAlign: .center,
                  maxLines: 1,
                  ellipsis: '�?,
                ),
              )
              ..pushStyle(
                ui.TextStyle(color: color, fontSize: MindMapMetrics.fontSize),
              )
              ..addText(node.text))
            .build()
          ..layout(
            const ui.ParagraphConstraints(
              width: MindMapMetrics.nodeWidth - MindMapMetrics.textPadding * 2,
            ),
          );
    _paragraphs[node.id]?.dispose();
    _paragraphs[node.id] = p;
    _paragraphTexts[node.id] = node.text;
    return p;
  }

  void _disposeParagraphs() {
    for (final ui.Paragraph p in _paragraphs.values) {
      p.dispose();
    }
    _paragraphs.clear();
    _paragraphTexts.clear();
  }

  @override
  void dispose() {
    _disposeParagraphs();
    super.dispose();
  }

  /// ⚠️ 字段�?*存储契约**逐项对齐（`data/canvas_store.dart` �?mindmap 分支）：
  /// 节点树自包含序列化（存档可读、可导出、可往返），与卡片�?文本�?blocks"
  /// 不同——思维导图的树先做自包含，投影�?blocks 留待下一步�?
  @override
  Map<String, dynamic> toJson({MediaResolver? media}) => <String, dynamic>{
    'type': 'mindmap',
    'id': id,
    'angle': angle,
    'rect': <double>[rect.left, rect.top, rect.right, rect.bottom],
    'nodes': root.toJson(),
    // 空槽位不写（理由同卡片：老存档没这个键，写了会让深比较失配）�?
    if (colorSlot != null) 'colorSlot': colorSlot!.name,
    'meta': meta,
  };

  factory MindMapItem.fromJson(
    Map<String, dynamic> j, {
    MediaResolver? media,
  }) => MindMapItem(
    id: j['id'] as String?,
    rect: _rectFromJson(j['rect'] as List),
    angle: (j['angle'] as num?)?.toDouble() ?? 0,
    root: MindNode.fromJson((j['nodes'] as Map).cast<String, dynamic>()),
    colorSlot: canvasColorSlotOf(j['colorSlot']),
    meta: (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
  );
}

/// 新建一张默认思维导图�?中心主题" + 两个分支），插入即可见、可拖�?
MindMapItem newMindMapItem({required Rect rect}) => MindMapItem(
  rect: rect,
  root: MindNode(
    text: '中心主题',
    children: <MindNode>[
      MindNode(text: '分支一'),
      MindNode(text: '分支�?),
    ],
  ),
);
