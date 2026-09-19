import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/ai/ai_action.dart';
import 'package:sinan/src/canvas/ai/ai_inventory.dart';
import 'package:sinan/src/canvas/ai/ai_sanitize.dart';
import 'package:sinan/src/canvas/kernel/canvas_edge.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';

/// 净化层的回归（A2，2026-09-19）。
///
/// ## 为什么这一层值得逐条钉
/// tldraw 为 agent 专门写了 sanitization——**这是结构派的全部工程难点**：模型必然
/// 给出不存在的 id、越界坐标、退化尺寸、自连、重复目标。散落在应用层判，结果一定是
/// "某条路径漏判 ⇒ 抛异常 ⇒ 整批白做"。所以规则集中成一个纯函数，**一条规则一个用例**。
///
/// 两条贯穿原则也各有用例守着：丢弃优于抛错、修得好的就修（且必留 warning）。
void main() {
  AiInventory inv({
    Set<String> itemIds = const <String>{},
    Set<String> cardItemIds = const <String>{},
    Set<String> groupItemIds = const <String>{},
    Set<String> groupedItemIds = const <String>{},
    Set<String> cardBlockIds = const <String>{},
    Set<String> blockIds = const <String>{},
    Set<String> edgeKeys = const <String>{},
  }) => AiInventory(
    itemIds: itemIds,
    cardItemIds: cardItemIds,
    groupItemIds: groupItemIds,
    groupedItemIds: groupedItemIds,
    cardBlockIds: cardBlockIds,
    blockIds: blockIds,
    edgeKeys: edgeKeys,
    viewportWorld: const Rect.fromLTWH(0, 0, 1000, 800),
  );

  AddShapeAction shape(NormRect rect) =>
      AddShapeAction(kind: CanvasShapeKind.rectangle, rect: rect);

  String? onlyWarning(AiSanitizeResult r) =>
      r.warnings.isEmpty ? null : r.warnings.first;

  group('AiAction.tryParse：不合规一律返回 null（绝不抛）', () {
    test('未知 op / 非 Map ⇒ null', () {
      expect(AiAction.tryParse(<String, Object?>{'op': '自创动作'}), isNull);
      expect(AiAction.tryParse('不是对象'), isNull);
      expect(AiAction.tryParse(null), isNull);
    });

    test('缺字段 / 字段类型不对 ⇒ null', () {
      expect(
        AiAction.tryParse(<String, Object?>{'op': 'reference_block'}),
        isNull,
        reason: '缺 blockId 与 at',
      );
      expect(
        AiAction.tryParse(<String, Object?>{
          'op': 'move_item',
          'id': 42, // 不是字符串
          'at': <double>[0.1, 0.2],
        }),
        isNull,
      );
      expect(
        AiAction.tryParse(<String, Object?>{
          'op': 'add_shape',
          'rect': <double>[0.1, 0.2, 0.3], // 少于 4 个数
        }),
        isNull,
      );
    });

    test('合规动作能被解析出来', () {
      final AiAction? a = AiAction.tryParse(<String, Object?>{
        'op': 'connect',
        'from': 'blk-1',
        'to': 'blk-2',
        'endShape': 'diamond',
      });
      expect(a, isA<ConnectAction>());
      expect((a! as ConnectAction).endShape, EdgeEndpointShape.diamond);
    });

    test('kind 缺失 ⇒ 退回矩形（比丢整条动作友好）', () {
      final AiAction? a = AiAction.tryParse(<String, Object?>{
        'op': 'add_shape',
        'rect': <double>[0.1, 0.1, 0.2, 0.2],
      });
      expect((a! as AddShapeAction).kind, CanvasShapeKind.rectangle);
    });
  });

  group('reference_block', () {
    test('块不在候选白名单 ⇒ 丢弃（不许凭记忆编 blockId）', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const ReferenceBlockAction(
            blockId: 'blk-999',
            at: NormPoint(0.5, 0.5),
          ),
        ],
        inv: inv(blockIds: <String>{'blk-1'}),
      );
      expect(r.actions, isEmpty);
      expect(onlyWarning(r), contains('不在可引用范围内'));
    });

    test('块已经在画布上 ⇒ 丢弃（一张卡片一个块）', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const ReferenceBlockAction(
            blockId: 'blk-1',
            at: NormPoint(0.5, 0.5),
          ),
        ],
        inv: inv(blockIds: <String>{'blk-1'}, cardBlockIds: <String>{'blk-1'}),
      );
      expect(r.actions, isEmpty);
      expect(onlyWarning(r), contains('重复引用'));
    });

    test('批内重复引用同一块 ⇒ 只留一条', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const ReferenceBlockAction(
            blockId: 'blk-1',
            at: NormPoint(0.2, 0.2),
          ),
          const ReferenceBlockAction(
            blockId: 'blk-1',
            at: NormPoint(0.6, 0.6),
          ),
        ],
        inv: inv(blockIds: <String>{'blk-1'}),
      );
      expect(r.actions.length, 1);
    });

    test('中心钳进"整张卡都在视口内"的范围', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const ReferenceBlockAction(
            blockId: 'blk-1',
            at: NormPoint(1, 1), // 贴右下角：半张卡会跑到视口外
          ),
        ],
        inv: inv(blockIds: <String>{'blk-1'}),
      );
      final ReferenceBlockAction a = r.actions.single as ReferenceBlockAction;
      expect(a.at.x, closeTo(1 - AiDefaults.cardWidth / 2, 1e-9));
      expect(a.at.y, closeTo(1 - AiDefaults.cardHeight / 2, 1e-9));
    });
  });

  group('add_shape / add_mindmap 的矩形规整', () {
    test('越界坐标被钳到 [0,1]', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[shape(const NormRect(-3, -3, 5, 5))],
        inv: inv(),
      );
      final NormRect rect = (r.actions.single as AddShapeAction).rect;
      expect(rect.left, 0);
      expect(rect.top, 0);
      expect(rect.right, 1);
      expect(rect.bottom, 1);
    });

    test('反向矩形（模型把两点写反）被换序', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[shape(const NormRect(0.6, 0.5, 0.2, 0.1))],
        inv: inv(),
      );
      final NormRect rect = (r.actions.single as AddShapeAction).rect;
      expect(rect.left, closeTo(0.2, 1e-9));
      expect(rect.top, closeTo(0.1, 1e-9));
      expect(rect.right, closeTo(0.6, 1e-9));
      expect(rect.bottom, closeTo(0.5, 1e-9));
    });

    test('退化成一点的矩形 ⇒ 补默认尺寸', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[shape(const NormRect(0.3, 0.3, 0.3, 0.3))],
        inv: inv(),
      );
      final NormRect rect = (r.actions.single as AddShapeAction).rect;
      expect(rect.width, closeTo(AiDefaults.shapeWidth, 1e-9));
      expect(rect.height, closeTo(AiDefaults.shapeHeight, 1e-9));
      expect(rect.left, closeTo(0.3, 1e-9), reason: '从左上的锚点长出来');
    });

    test('补尺寸后顶出右下边界 ⇒ 平移回来且尺寸不变', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[shape(const NormRect(0.98, 0.98, 0.98, 0.98))],
        inv: inv(),
      );
      final NormRect rect = (r.actions.single as AddShapeAction).rect;
      expect(rect.right, closeTo(1, 1e-9));
      expect(rect.bottom, closeTo(1, 1e-9));
      expect(rect.width, closeTo(AiDefaults.shapeWidth, 1e-9));
      expect(rect.height, closeTo(AiDefaults.shapeHeight, 1e-9));
    });

    test('NaN / 无穷 ⇒ 丢弃（这种矩形修不了）', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[shape(const NormRect(double.nan, 0, 1, 1))],
        inv: inv(),
      );
      expect(r.actions, isEmpty);
      expect(onlyWarning(r), contains('矩形无效'));
    });

    test('思维导图分支过多 ⇒ 截断 + warning', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          AddMindMapAction(
            rect: const NormRect(0.1, 0.1, 0.4, 0.4),
            root: '主题',
            children: <String>[for (int i = 0; i < 20; i++) '分支$i'],
          ),
        ],
        inv: inv(),
      );
      final AddMindMapAction a = r.actions.single as AddMindMapAction;
      expect(a.children.length, AiDefaults.maxMindMapChildren);
      expect(onlyWarning(r), contains('分支过多'));
    });

    test('过长文本被截断（否则卡片 / 节点被撑爆）', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          AddMindMapAction(
            rect: const NormRect(0.1, 0.1, 0.4, 0.4),
            root: 'x' * 200,
          ),
        ],
        inv: inv(),
      );
      expect(
        (r.actions.single as AddMindMapAction).root.length,
        AiDefaults.maxTextLength,
      );
    });
  });

  group('move_item / set_text 的合法性', () {
    test('item 不存在 ⇒ 丢弃', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const MoveItemAction(id: 'item-404', at: NormPoint(0.5, 0.5)),
        ],
        inv: inv(itemIds: <String>{'item-1'}),
      );
      expect(r.actions, isEmpty);
      expect(onlyWarning(r), contains('不存在'));
    });

    test('同一 item 多次 move ⇒ 只留最后一条', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const MoveItemAction(id: 'item-1', at: NormPoint(0.1, 0.1)),
          const MoveItemAction(id: 'item-1', at: NormPoint(0.9, 0.9)),
        ],
        inv: inv(itemIds: <String>{'item-1'}),
      );
      expect(r.actions.length, 1);
      expect((r.actions.single as MoveItemAction).at.x, closeTo(0.9, 1e-9));
    });

    test('set_text 的目标不是卡片 ⇒ 丢弃（形状 / 图片没有文本）', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[const SetTextAction(id: 'item-1', text: '改我')],
        inv: inv(itemIds: <String>{'item-1'}), // 是 item，但不是卡片
        // 开闸是为了走到类型检查这一步（否则先被"默认关闭"挡掉）。
        allowTextRewrite: true,
      );
      expect(r.actions, isEmpty);
      expect(onlyWarning(r), contains('不是画布上的卡片'));
    });

    test('set_text **默认关闭**（唯一会覆盖用户内容的动作，且不可撤销）', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[const SetTextAction(id: 'item-1', text: '新文本')],
        inv: inv(itemIds: <String>{'item-1'}, cardItemIds: <String>{'item-1'}),
      );
      expect(r.actions, isEmpty);
      expect(onlyWarning(r), contains('暂不可撤销'));
    });

    test('调用方显式开闸后才放行 set_text', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[const SetTextAction(id: 'item-1', text: '新文本')],
        inv: inv(itemIds: <String>{'item-1'}, cardItemIds: <String>{'item-1'}),
        allowTextRewrite: true,
      );
      expect((r.actions.single as SetTextAction).text, '新文本');
    });
  });

  group('connect', () {
    test('端点不在画布上 ⇒ 丢弃（与 edgesIn「找不到端点就不画」同口径）', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const ConnectAction(fromBlockId: 'blk-1', toBlockId: 'blk-2'),
        ],
        inv: inv(cardBlockIds: <String>{'blk-1'}),
      );
      expect(r.actions, isEmpty);
      expect(onlyWarning(r), contains('端点卡片不在画布上'));
    });

    test('自连 ⇒ 丢弃', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const ConnectAction(fromBlockId: 'blk-1', toBlockId: 'blk-1'),
        ],
        inv: inv(cardBlockIds: <String>{'blk-1'}),
      );
      expect(r.actions, isEmpty);
      expect(onlyWarning(r), contains('自身'));
    });

    test('与**已有**连线重复 ⇒ 丢弃', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const ConnectAction(fromBlockId: 'blk-1', toBlockId: 'blk-2'),
        ],
        inv: inv(
          cardBlockIds: <String>{'blk-1', 'blk-2'},
          edgeKeys: <String>{'blk-1>blk-2'},
        ),
      );
      expect(r.actions, isEmpty);
      expect(onlyWarning(r), contains('重复连线'));
    });

    test('批内重复 ⇒ 只留一条', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const ConnectAction(fromBlockId: 'blk-1', toBlockId: 'blk-2'),
          const ConnectAction(fromBlockId: 'blk-1', toBlockId: 'blk-2'),
        ],
        inv: inv(cardBlockIds: <String>{'blk-1', 'blk-2'}),
      );
      expect(r.actions.length, 1);
    });
  });

  group('group / ungroup / delete', () {
    test('可用成员不足两个 ⇒ 丢弃', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const GroupAction(ids: <String>['item-1', 'item-404']),
        ],
        inv: inv(itemIds: <String>{'item-1'}),
      );
      expect(r.actions, isEmpty);
      expect(onlyWarning(r), contains('不足两个'));
    });

    test('分组框自身与已在别的组里的成员被剔除（不做嵌套、归属不歧义）', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const GroupAction(
            ids: <String>['item-1', 'item-2', 'item-3', 'item-4'],
            label: '一组',
          ),
        ],
        inv: inv(
          itemIds: <String>{'item-1', 'item-2', 'item-3', 'item-4'},
          groupItemIds: <String>{'item-3'}, // 它本身就是个分组框：不做嵌套
          groupedItemIds: <String>{'item-4'}, // 已在别的组里
        ),
      );
      expect((r.actions.single as GroupAction).ids, <String>['item-1', 'item-2']);
      expect(r.warnings, isNotEmpty, reason: '剔除了成员就必须告知');
    });

    test('正常分组通过；标题过长被截断', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          GroupAction(ids: <String>['item-1', 'item-2'], label: 'x' * 100),
        ],
        inv: inv(itemIds: <String>{'item-1', 'item-2'}),
      );
      expect(
        (r.actions.single as GroupAction).label.length,
        AiDefaults.maxLabelLength,
      );
    });

    test('ungroup 的目标不是分组框 ⇒ 丢弃', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const UngroupAction(ids: <String>['item-1']),
        ],
        inv: inv(itemIds: <String>{'item-1'}),
      );
      expect(r.actions, isEmpty);
      expect(onlyWarning(r), contains('不是分组框'));
    });

    test('ungroup 命中分组框 ⇒ 保留（不存在的那些被剔掉）', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const UngroupAction(ids: <String>['item-1', 'item-404']),
        ],
        inv: inv(itemIds: <String>{'item-1'}, groupItemIds: <String>{'item-1'}),
      );
      expect((r.actions.single as UngroupAction).ids, <String>['item-1']);
    });

    test('delete 只删存在的，部分命中不整条丢', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const DeleteAction(ids: <String>['item-1', 'item-404']),
        ],
        inv: inv(itemIds: <String>{'item-1'}),
      );
      expect((r.actions.single as DeleteAction).ids, <String>['item-1']);
    });

    test('delete 全不命中 ⇒ 丢弃', () {
      final AiSanitizeResult r = sanitizeAiActions(
        <AiAction>[
          const DeleteAction(ids: <String>['item-404']),
        ],
        inv: inv(itemIds: <String>{'item-1'}),
      );
      expect(r.actions, isEmpty);
    });
  });

  test('超过条数上限 ⇒ 截断 + warning（不静默）', () {
    final AiSanitizeResult r = sanitizeAiActions(
      <AiAction>[
        for (int i = 0; i < AiDefaults.maxActions + 7; i++)
          shape(const NormRect(0.1, 0.1, 0.2, 0.2)),
      ],
      inv: inv(),
    );
    expect(r.actions.length, AiDefaults.maxActions);
    expect(r.warnings.single, contains('超过上限'));
  });

  test('净化保持原顺序，且**批内投影态**生效（先摆后连）', () {
    // 这是最常见的指令形态：「把这两块摆上来并连起来」。
    // 初始画布上没有卡片 ⇒ connect 的端点只能靠**本批前面的 reference_block**成立。
    final AiSanitizeResult r = sanitizeAiActions(
      <AiAction>[
        const ReferenceBlockAction(blockId: 'blk-1', at: NormPoint(0.2, 0.2)),
        const ReferenceBlockAction(blockId: 'blk-2', at: NormPoint(0.8, 0.2)),
        const ConnectAction(fromBlockId: 'blk-1', toBlockId: 'blk-2'),
      ],
      inv: inv(blockIds: <String>{'blk-1', 'blk-2'}),
    );
    expect(r.actions.length, 3, reason: '用批前快照校验的话这里只会剩 0~1 条');
    expect(r.actions[0], isA<ReferenceBlockAction>());
    expect(r.actions[1], isA<ReferenceBlockAction>());
    expect(r.actions[2], isA<ConnectAction>());
  });

  test('批内投影态**不**放宽"块必须来自候选白名单"', () {
    // 投影态只影响"已在画布上"的判定，不能让模型凭空引用白名单外的块。
    final AiSanitizeResult r = sanitizeAiActions(
      <AiAction>[
        const ConnectAction(fromBlockId: 'blk-999', toBlockId: 'blk-1'),
        const ReferenceBlockAction(blockId: 'blk-1', at: NormPoint(0.2, 0.2)),
      ],
      inv: inv(blockIds: <String>{'blk-1'}),
    );
    expect(r.actions.length, 1);
    expect(r.actions.single, isA<ReferenceBlockAction>());
  });
}
