import 'dart:ui' show Rect;

import '../kernel/canvas_document.dart';
import '../kernel/canvas_edge.dart';
import '../kernel/canvas_item.dart';

/// 净化层与应用层共用的**画布现状快照**。
///
/// ## 为什么要单独抽出来（而不是在净化函数里现查文档）
/// ① 净化层要能**脱离文档单测**（"引用了不存在的块"这类规则不值得为了测它去搭一份
/// 文档）；② 净化与应用必须是**同一份快照**——中途文档变了就会出现"净化时合法、
/// 应用时找不到"的错位；③ 它同时也是 A5 里**给模型的上下文**的数据源（元素清单 +
/// 候选块），两处同源才不会漂移。
///
/// 各字段的存在理由都是"某条净化规则需要它"，没有一个是预留的。
class AiInventory {
  const AiInventory({
    required this.itemIds,
    required this.cardItemIds,
    required this.groupItemIds,
    required this.groupedItemIds,
    required this.cardBlockIds,
    required this.blockIds,
    required this.edgeKeys,
    required this.viewportWorld,
  });

  /// 文档里所有 item 的 id（`move_item` / `delete` / `group` 的合法性依据）。
  final Set<String> itemIds;

  /// **卡片**的 item id（只有卡片能 `set_text`）。
  final Set<String> cardItemIds;

  /// 分组框本身的 item id（`ungroup` 的目标）。
  final Set<String> groupItemIds;

  /// 已经属于某个分组的 item id。
  ///
  /// `group` 规则用它挡住"把一个已在别组里的成员再收进来"——归属有歧义时宁可
  /// 不收（见 `ai_sanitize.dart` 的 group 分支）。
  final Set<String> groupedItemIds;

  /// 已经**在画布上**的卡片所指向的 `blockId`。
  ///
  /// 两个用途：`connect` 的端点必须在这里面（否则连线指向虚无，与
  /// `CanvasDocument.edgesIn`「任一端缺失就不返回」同口径）；
  /// 以及挡住"把已经在画布上的块再引用一次"。
  final Set<String> cardBlockIds;

  /// **可引用到画布**的块候选（A5 由 `NoteStore.searchBlocks` 填充）。
  ///
  /// ⚠️ 这是白名单而非"全部块"：模型只能引用我们**主动喂给它**的那些，
  /// 免得它凭记忆编一个看起来合理的 blockId 出来。
  final Set<String> blockIds;

  /// 已有连线的 `"fromBlockId>toBlockId"` 键（挡住重复连线）。
  final Set<String> edgeKeys;

  /// 当前视口的世界矩形——归一化坐标的换算基准。
  final Rect viewportWorld;

  /// 从文档现算（唯一装配点）。
  ///
  /// [blockIds] 由宿主传入（它才拿得到块库），不传就是"本批不允许引用任何块"。
  factory AiInventory.of(
    CanvasDocument doc, {
    required Rect viewportWorld,
    Set<String> blockIds = const <String>{},
  }) {
    final Set<String> itemIds = <String>{};
    final Set<String> cardItemIds = <String>{};
    final Set<String> groupItemIds = <String>{};
    final Set<String> groupedItemIds = <String>{};
    final Set<String> cardBlockIds = <String>{};
    for (final CanvasItem item in doc.items) {
      itemIds.add(item.id);
      if (item is CardItem) {
        cardItemIds.add(item.id);
        cardBlockIds.add(item.blockId);
      }
      if (item is CanvasGroupItem) groupItemIds.add(item.id);
      if (item.groupId != null) groupedItemIds.add(item.id);
    }
    return AiInventory(
      itemIds: itemIds,
      cardItemIds: cardItemIds,
      groupItemIds: groupItemIds,
      groupedItemIds: groupedItemIds,
      cardBlockIds: cardBlockIds,
      blockIds: blockIds,
      edgeKeys: <String>{
        for (final CanvasEdge e in doc.edges) '${e.fromId}>${e.toId}',
      },
      viewportWorld: viewportWorld,
    );
  }
}
