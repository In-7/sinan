import 'dart:ui' show Rect;

import '../kernel/canvas_document.dart';
import '../kernel/canvas_edge.dart';
import '../kernel/canvas_item.dart';
import '../kernel/canvas_mindmap.dart';
import '../kernel/ink_stroke.dart' show kThemeInk;
import 'ai_action.dart';
import 'ai_sanitize.dart' show AiDefaults;

/// 应用结果（给 UI 汇报：改了几个、加了什么、哪些被跳过）。
class AiApplyResult {
  const AiApplyResult({
    required this.applied,
    required this.created,
    required this.notes,
  });

  /// 真正落地的动作条数。
  final int applied;

  /// 本批**新建**的元素（宿主可据此选中它们，让用户看见"AI 动了什么"）。
  final List<CanvasItem> created;

  /// 应用期的补充说明（如"该块已不存在"）。与净化层的 warnings 分开：那些是
  /// "模型说错了"，这些是"说对了但已经来不及"。
  final List<String> notes;

  bool get isEmpty => applied == 0;
}

/// 把**已净化**的动作应用到文档。
///
/// ## 一次调用 = 一条撤销命令
/// 全程包在 [CanvasDocument.batch] 里，用户按**一次** Ctrl+Z 就回到指令之前。
/// 少了这一步，AI 改 8 个元素要按 8 次 —— 等于不可撤销。
///
/// ## 为什么这里"不校验"
/// 校验全在 [sanitizeAiActions]（纯函数、逐规则单测）。这一层只负责把动作翻译成
/// **既有**的文档 API 调用；再判一遍等于把规则写两份，迟早漂移。
/// 唯一保留的判断是"元素在净化之后消失了"（[blockTextOf] 返回 null / `itemById`
/// 找不到）——那属于**应用期的竞态**，不是模型说错。
///
/// ## 为什么不经手"新建 blocks 行"
/// `CardItem.blockId` 是指向 `blocks(id)` 的外键，而数据层目前**没有**创建块的 API
/// （`blocks` 行由编辑器的块树经 `BlockStore.replaceNoteBlocks` 产出）⇒
/// `reference_block` 只引用**已存在**的块，凭空造卡片会挂空外键。
/// 见 `docs/ai_structure_track_plan.md` §5。
AiApplyResult applyAiActions(
  CanvasDocument doc,
  List<AiAction> actions, {
  required Rect viewportWorld,
  required String? Function(String blockId) blockTextOf,
}) {
  final List<CanvasItem> created = <CanvasItem>[];
  final List<String> notes = <String>[];
  int applied = 0;

  double widthOf(double fraction) => viewportWorld.width * fraction;
  double heightOf(double fraction) => viewportWorld.height * fraction;

  doc.batch(() {
    for (final AiAction action in actions) {
      switch (action) {
        case final ReferenceBlockAction a:
          final String? text = blockTextOf(a.blockId);
          if (text == null) {
            notes.add('跳过了引用：块已不存在');
            continue;
          }
          final CardItem card = CardItem(
            // 尺寸由**视口比例**给（见 [AiDefaults]）：任何缩放级别下插进来都
            // 看起来一样大，与插入面板"按屏幕尺寸给"同口径。
            rect: Rect.fromCenter(
              center: a.at.toWorld(viewportWorld),
              width: widthOf(AiDefaults.cardWidth),
              height: heightOf(AiDefaults.cardHeight),
            ),
            blockId: a.blockId,
            text: text,
          );
          doc.addItem(card);
          created.add(card);
          applied++;

        case final AddShapeAction a:
          final ShapeItem shape = ShapeItem(
            rect: a.rect.toWorld(viewportWorld),
            kind: a.kind,
            // 哨兵色 ⇒ 跟随主题墨色（否则暗色画布上会出现"黑墨画黑纸"）。
            color: kThemeInk,
          );
          doc.addItem(shape);
          created.add(shape);
          applied++;

        case final AddMindMapAction a:
          final MindMapItem map = MindMapItem(
            rect: a.rect.toWorld(viewportWorld),
            root: MindNode(
              text: a.root,
              children: <MindNode>[
                for (final String c in a.children) MindNode(text: c),
              ],
            ),
          );
          doc.addItem(map);
          created.add(map);
          applied++;

        case final MoveItemAction a:
          final CanvasItem? item = doc.itemById(a.id);
          if (item == null) {
            notes.add('跳过了移动：元素已不存在');
            continue;
          }
          final Rect before = item.rect;
          final double angle = item.angle;
          item.rect = Rect.fromCenter(
            center: a.at.toWorld(viewportWorld),
            width: before.width, // 只挪位置，**不改尺寸**
            height: before.height,
          );
          // 走既有的变换命令通道（与拖拽落账同一条路），撤销栈才能认得。
          doc.setItemTransforms(<(CanvasItem, Rect, double)>[(item, before, angle)]);
          applied++;

        case final SetTextAction a:
          final CanvasItem? item = doc.itemById(a.id);
          if (item is! CardItem) {
            notes.add('跳过了改文本：目标已不是卡片');
            continue;
          }
          // ⚠️ 卡片文本**不在撤销栈里**（全应用都还没有文本编辑的撤销通道），
          // 所以这条默认被净化层挡在门外（见 `sanitizeAiActions` 的
          // `allowTextRewrite`）。能走到这里说明调用方明确开了闸。
          item.text = a.text;
          applied++;

        case final ConnectAction a:
          doc.addEdge(
            CanvasEdge(
              fromId: a.fromBlockId,
              toId: a.toBlockId,
              endShape: a.endShape,
            ),
          );
          applied++;

        case final DeleteAction a:
          final List<CanvasItem> victims = <CanvasItem>[
            for (final String id in a.ids)
              if (doc.itemById(id) case final CanvasItem it) it,
          ];
          if (victims.isEmpty) {
            notes.add('跳过了删除：元素已不存在');
            continue;
          }
          doc.removeItems(victims);
          applied++;

        case final GroupAction a:
          final List<CanvasItem> members = <CanvasItem>[
            for (final String id in a.ids)
              if (doc.itemById(id) case final CanvasItem it) it,
          ];
          if (members.length < 2) {
            notes.add('跳过了分组：成员已不足两个');
            continue;
          }
          // 框 = 成员的包围盒外扩一圈：贴死会让框线与元素边缘重叠、看不清。
          Rect box = members.first.bounds;
          for (final CanvasItem m in members.skip(1)) {
            box = box.expandToInclude(m.bounds);
          }
          final CanvasGroupItem group = CanvasGroupItem(
            rect: box.inflate(widthOf(0.012)),
            label: a.label,
          );
          // ⚠️ 顺序：**先加框、再绑成员**。批撤销是逆序执行的 ⇒ 先解绑、再删框，
          // 中间态干净（不会出现"成员指向一个已经不存在的框"）。
          doc.addItem(group);
          doc.setItemGroupIds(_bind(members, group.id));
          created.add(group);
          applied++;

        case final UngroupAction a:
          final List<CanvasItem> frames = <CanvasItem>[
            for (final String id in a.ids)
              if (doc.itemById(id) case final CanvasItem it) it,
          ];
          if (frames.isEmpty) {
            notes.add('忽略了解散分组：分组框已不存在');
            continue;
          }
          // 先解绑、再删框（同一条 batch ⇒ 一次撤销全回来）。
          // 注意 `removeItems` 自己也会解绑（防"框被删而成员悬空"），这里已经解开
          // 了所以那边会查到空集，不冲突。
          final List<CanvasItem> bound = <CanvasItem>[
            for (final CanvasItem frame in frames)
              for (final CanvasItem item in doc.items)
                if (item.groupId == frame.id) item,
          ];
          doc.setItemGroupIds(_bind(bound, null));
          doc.removeItems(frames);
          applied++;
      }
    }
  });

  return AiApplyResult(applied: applied, created: created, notes: notes);
}

/// 把 [items] 的归属**就地**改成 [groupId]，并返回"改动前"的快照。
///
/// [CanvasDocument.setItemGroupIds] 的契约是"调用方已就地改好、把旧值交进来"
/// （与 `setItemColorSlots` 同范式）。取旧值与就地改**必须**在同一个循环里做：
/// 分成两步就会出现"记下来的旧值其实是新值"这种经典错误，而它的症状是
/// **撤销后成员没解绑**（看着像撤销失效）。
List<(CanvasItem, String?)> _bind(Iterable<CanvasItem> items, String? groupId) {
  final List<(CanvasItem, String?)> changes = <(CanvasItem, String?)>[];
  for (final CanvasItem item in items) {
    changes.add((item, item.groupId)); // 旧值：就地改**之前**取
    item.groupId = groupId;
  }
  return changes;
}
