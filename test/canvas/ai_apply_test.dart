import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/ai/ai_action.dart';
import 'package:sinan/src/canvas/ai/ai_apply.dart';
import 'package:sinan/src/canvas/ai/ai_sanitize.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_edge.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/canvas_mindmap.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart' show kThemeInk;

/// 应用层的回归（A3，2026-09-19）。
///
/// 这一层的职责只有一个：把**已净化**的动作翻译成**既有**的文档 API 调用。
/// 所以用例关心的也是两件事：
/// 1. 每种动作是否落到了正确的 API、产出的元素对不对；
/// 2. **一批动作 = 一条撤销命令**（A 阶段的核心承诺，见 `CanvasDocument.batch`）。
void main() {
  const Rect viewport = Rect.fromLTWH(0, 0, 1000, 800);

  /// 假的块库：只有 blk-1 / blk-2 有文本，其余视为"已被删掉"。
  String? blockTextOf(String blockId) => switch (blockId) {
    'blk-1' => '番茄工作法',
    'blk-2' => '间隔重复',
    _ => null,
  };

  ShapeItem shape(Rect rect) => ShapeItem(
    rect: rect,
    kind: CanvasShapeKind.rectangle,
    color: kThemeInk,
  );

  test('reference_block 落成引用卡片：带 blockId、带块文本、尺寸按视口比例', () {
    final CanvasDocument doc = CanvasDocument();

    final AiApplyResult r = applyAiActions(
      doc,
      <AiAction>[
        const ReferenceBlockAction(blockId: 'blk-1', at: NormPoint(0.5, 0.5)),
      ],
      viewportWorld: viewport,
      blockTextOf: blockTextOf,
    );

    expect(r.applied, 1);
    final CardItem card = doc.items.single as CardItem;
    expect(card.blockId, 'blk-1');
    expect(card.text, '番茄工作法', reason: '卡片文本是块内容的快照');
    expect(card.rect.center, const Offset(500, 400));
    expect(card.rect.width, closeTo(1000 * AiDefaults.cardWidth, 1e-9));
    expect(card.rect.height, closeTo(800 * AiDefaults.cardHeight, 1e-9));
  });

  test('块在净化之后消失（应用期竞态）⇒ 跳过 + note，不抛', () {
    final CanvasDocument doc = CanvasDocument();

    final AiApplyResult r = applyAiActions(
      doc,
      <AiAction>[
        const ReferenceBlockAction(blockId: 'blk-已删', at: NormPoint(0.5, 0.5)),
      ],
      viewportWorld: viewport,
      blockTextOf: blockTextOf,
    );

    expect(r.applied, 0);
    expect(r.notes.single, contains('块已不存在'));
    expect(doc.items, isEmpty);
    expect(doc.canUndo, isFalse, reason: '什么都没做 ⇒ 不该留一条空命令');
  });

  test('add_shape 用**哨兵色**（跟随主题墨色），矩形按归一化换算', () {
    final CanvasDocument doc = CanvasDocument();

    applyAiActions(
      doc,
      <AiAction>[
        const AddShapeAction(
          kind: CanvasShapeKind.ellipse,
          rect: NormRect(0.1, 0.2, 0.4, 0.5),
        ),
      ],
      viewportWorld: viewport,
      blockTextOf: blockTextOf,
    );

    final ShapeItem s = doc.items.single as ShapeItem;
    expect(s.kind, CanvasShapeKind.ellipse);
    expect(s.rect, const Rect.fromLTRB(100, 160, 400, 400));
    expect(
      s.color,
      kThemeInk,
      reason: '哨兵色才跟随主题（否则暗色画布上是"黑墨画黑纸"）',
    );
  });

  test('add_mindmap 建出带一级分支的树', () {
    final CanvasDocument doc = CanvasDocument();

    applyAiActions(
      doc,
      <AiAction>[
        const AddMindMapAction(
          rect: NormRect(0.1, 0.1, 0.5, 0.5),
          root: '复习策略',
          children: <String>['当天', '隔日', '一周后'],
        ),
      ],
      viewportWorld: viewport,
      blockTextOf: blockTextOf,
    );

    final MindMapItem map = doc.items.single as MindMapItem;
    expect(map.root.text, '复习策略');
    expect(
      map.root.children.map((MindNode n) => n.text),
      <String>['当天', '隔日', '一周后'],
    );
  });

  test('move_item 只挪位置、**不改尺寸**，且走既有的变换命令', () {
    final CanvasDocument doc = CanvasDocument();
    final ShapeItem s = shape(const Rect.fromLTWH(0, 0, 60, 40));
    doc.addItem(s);

    applyAiActions(
      // ⚠️ 用 s.id 而不是字面量：item id 是**进程级**自增（`_nextItemId`），
      // 同一进程里前面的用例已经消耗过号。
      doc,
      <AiAction>[MoveItemAction(id: s.id, at: const NormPoint(0.5, 0.5))],
      viewportWorld: viewport,
      blockTextOf: blockTextOf,
    );

    expect(s.rect.center, const Offset(500, 400));
    expect(s.rect.width, 60);
    expect(s.rect.height, 40);

    // 撤销应回到原位置（说明走的是变换命令，不是就地改完就完事）。
    doc.undo();
    expect(s.rect, const Rect.fromLTWH(0, 0, 60, 40));
  });

  test('元素在应用期消失 ⇒ 跳过移动 + note', () {
    final CanvasDocument doc = CanvasDocument();

    final AiApplyResult r = applyAiActions(
      doc,
      <AiAction>[const MoveItemAction(id: 'item-404', at: NormPoint(0.5, 0.5))],
      viewportWorld: viewport,
      blockTextOf: blockTextOf,
    );

    expect(r.applied, 0);
    expect(r.notes.single, contains('元素已不存在'));
  });

  test('connect 建连线，端点用 blockId', () {
    final CanvasDocument doc = CanvasDocument();

    applyAiActions(
      doc,
      <AiAction>[
        const ConnectAction(fromBlockId: 'blk-1', toBlockId: 'blk-2'),
      ],
      viewportWorld: viewport,
      blockTextOf: blockTextOf,
    );

    final CanvasEdge edge = doc.edges.single;
    expect(edge.fromId, 'blk-1');
    expect(edge.toId, 'blk-2');
    expect(edge.endShape, EdgeEndpointShape.arrow);
  });

  test('delete 只删存在的那些', () {
    final CanvasDocument doc = CanvasDocument();
    final ShapeItem keep = shape(const Rect.fromLTWH(0, 0, 20, 20));
    final ShapeItem drop = shape(const Rect.fromLTWH(40, 0, 20, 20));
    doc.addItem(keep);
    doc.addItem(drop);

    final AiApplyResult r = applyAiActions(
      doc,
      <AiAction>[
        DeleteAction(ids: <String>[drop.id, 'item-404']),
      ],
      viewportWorld: viewport,
      blockTextOf: blockTextOf,
    );

    expect(r.applied, 1);
    expect(doc.items.single, same(keep));
  });

  test('set_text 改的是卡片文本（调用方已开闸）', () {
    final CanvasDocument doc = CanvasDocument();
    doc.addItem(
      CardItem(rect: const Rect.fromLTWH(0, 0, 100, 50), blockId: 'blk-1', text: '旧'),
    );

    applyAiActions(
      doc,
      <AiAction>[SetTextAction(id: doc.items.single.id, text: '新')],
      viewportWorld: viewport,
      blockTextOf: blockTextOf,
    );

    expect((doc.items.single as CardItem).text, '新');
  });

  test('**一批动作 = 一条撤销命令**（A 阶段的核心承诺）', () {
    final CanvasDocument doc = CanvasDocument();

    final AiApplyResult r = applyAiActions(
      doc,
      <AiAction>[
        const ReferenceBlockAction(blockId: 'blk-1', at: NormPoint(0.3, 0.3)),
        const ReferenceBlockAction(blockId: 'blk-2', at: NormPoint(0.7, 0.3)),
        const AddShapeAction(
          kind: CanvasShapeKind.rectangle,
          rect: NormRect(0.1, 0.6, 0.9, 0.9),
        ),
        const ConnectAction(fromBlockId: 'blk-1', toBlockId: 'blk-2'),
      ],
      viewportWorld: viewport,
      blockTextOf: blockTextOf,
    );

    expect(r.applied, 4);
    expect(r.created.length, 3);
    expect(doc.items.length, 3);
    expect(doc.edges.length, 1);

    doc.undo();

    expect(doc.items, isEmpty, reason: '一次撤销要回滚整批');
    expect(doc.edges, isEmpty);
    expect(
      doc.canUndo,
      isFalse,
      reason: '整批只应产生一条命令（否则用户要按 N 次 Ctrl+Z）',
    );

    doc.redo();
    expect(doc.items.length, 3);
    expect(doc.edges.length, 1);
  });

  test('group：建框 + 绑成员；一次撤销把框与归属一起收回', () {
    final CanvasDocument doc = CanvasDocument();
    final ShapeItem a = shape(const Rect.fromLTWH(0, 0, 40, 40));
    final ShapeItem b = shape(const Rect.fromLTWH(100, 40, 40, 40));
    doc.addItem(a);
    doc.addItem(b);

    final AiApplyResult r = applyAiActions(
      doc,
      <AiAction>[
        GroupAction(ids: <String>[a.id, b.id], label: '一组'),
      ],
      viewportWorld: viewport,
      blockTextOf: blockTextOf,
    );

    expect(r.applied, 1);
    final CanvasGroupItem group = r.created.single as CanvasGroupItem;
    expect(group.label, '一组');
    expect(a.groupId, group.id, reason: '成员要绑上框');
    expect(b.groupId, group.id);
    expect(doc.items, hasLength(3));
    // 框要包住成员并外扩一圈（贴死会让框线与元素边缘重叠）。
    expect(group.rect.contains(a.rect.center), isTrue);
    expect(group.rect.contains(b.rect.center), isTrue);
    expect(
      group.rect.width,
      greaterThan(b.rect.right - a.rect.left),
      reason: '外扩过：框比成员的并集略大',
    );

    doc.undo();
    expect(a.groupId, isNull, reason: '撤销必须**同时**解绑，否则成员指向死框');
    expect(b.groupId, isNull);
    expect(doc.items, hasLength(2), reason: '框也要一起消失');
  });

  test('ungroup：解绑成员 + 删框；一次撤销全回来', () {
    final CanvasDocument doc = CanvasDocument();
    final ShapeItem a = shape(const Rect.fromLTWH(0, 0, 40, 40));
    final ShapeItem b = shape(const Rect.fromLTWH(100, 0, 40, 40));
    doc.addItem(a);
    doc.addItem(b);
    // 先经同一条 apply 路径造出真实的组，别手搓状态。
    final String groupId =
        applyAiActions(
              doc,
              <AiAction>[
                GroupAction(ids: <String>[a.id, b.id]),
              ],
              viewportWorld: viewport,
              blockTextOf: blockTextOf,
            ).created
            .single
            .id;

    final AiApplyResult r = applyAiActions(
      doc,
      <AiAction>[
        UngroupAction(ids: <String>[groupId]),
      ],
      viewportWorld: viewport,
      blockTextOf: blockTextOf,
    );

    expect(r.applied, 1);
    expect(a.groupId, isNull);
    expect(b.groupId, isNull);
    expect(doc.items, hasLength(2), reason: '框被删了');

    doc.undo();
    expect(doc.items, hasLength(3), reason: '一次撤销要把框带回来');
    expect(a.groupId, groupId, reason: '归属也要一起回来（同一条命令）');
    expect(b.groupId, groupId);
  });

  test('delete 掉分组框 ⇒ 成员自动解绑（不留悬空归属）', () {
    final CanvasDocument doc = CanvasDocument();
    final ShapeItem a = shape(const Rect.fromLTWH(0, 0, 40, 40));
    final ShapeItem b = shape(const Rect.fromLTWH(100, 0, 40, 40));
    doc.addItem(a);
    doc.addItem(b);
    final String groupId =
        applyAiActions(
              doc,
              <AiAction>[
                GroupAction(ids: <String>[a.id, b.id]),
              ],
              viewportWorld: viewport,
              blockTextOf: blockTextOf,
            ).created
            .single
            .id;

    applyAiActions(
      doc,
      <AiAction>[
        DeleteAction(ids: <String>[groupId]),
      ],
      viewportWorld: viewport,
      blockTextOf: blockTextOf,
    );

    expect(a.groupId, isNull, reason: '框被删了，成员不能还认为自己属于它');
    expect(b.groupId, isNull);
    expect(doc.items, hasLength(2));

    doc.undo();
    expect(a.groupId, groupId, reason: '撤销后成员重新绑回同一个框');
    expect(doc.items, hasLength(3));
  });

  test('空动作列表不产生撤销记录', () {
    final CanvasDocument doc = CanvasDocument();
    final AiApplyResult r = applyAiActions(
      doc,
      const <AiAction>[],
      viewportWorld: viewport,
      blockTextOf: blockTextOf,
    );
    expect(r.isEmpty, isTrue);
    expect(doc.canUndo, isFalse);
  });
}
