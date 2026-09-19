import 'ai_action.dart';
import 'ai_inventory.dart';

/// 动作的默认尺寸与上限（**视口比例**，不是世界单位）。
///
/// ## 为什么用视口比例而不是世界单位
/// 归一化坐标已经是以视口为基准的；默认尺寸若用世界单位，在极端缩放级别下就会
/// 出现"缩到 5% 时 AI 插进来的卡片只有一个像素"。用比例则任何缩放下看起来都一样大，
/// 与插入面板"按屏幕尺寸给"（`_screenToWorld`）同一个思路。
abstract final class AiDefaults {
  /// 引用块做成的卡片。
  static const double cardWidth = 0.18;
  static const double cardHeight = 0.10;

  /// 形状。
  static const double shapeWidth = 0.15;
  static const double shapeHeight = 0.10;

  /// 思维导图（比卡片大，它要装一棵树）。
  static const double mindMapWidth = 0.30;
  static const double mindMapHeight = 0.22;

  /// 退化判据：宽/高小于视口的这个比例就算"模型没给有效尺寸"。
  static const double degenerate = 0.01;

  /// 一批动作的条数上限（与 `kAiActionSchema` 的 `maxItems` 保持一致）。
  static const int maxActions = 50;

  /// 思维导图分支数上限与单条文本长度上限。
  static const int maxMindMapChildren = 12;
  static const int maxTextLength = 80;

  /// 分组框标题长度上限（框顶那条标签，太长会拖出框外）。
  static const int maxLabelLength = 40;
}

/// 净化结果。[warnings] 是**给用户看的**丢弃原因——不静默吞掉任何一条。
class AiSanitizeResult {
  const AiSanitizeResult({required this.actions, required this.warnings});

  /// 可以安全应用的动作，**保持原顺序**。
  final List<AiAction> actions;

  /// 丢弃/修正的原因（中文，直接展示）。
  final List<String> warnings;

  bool get isEmpty => actions.isEmpty;
}

/// 净化层：把模型给的（半可信的）动作变成**可以无脑应用**的动作。
///
/// ## 为什么必须有这一层（而不是应用时顺手校验）
/// tldraw 为 agent 专门写了一层 sanitization——这是结构派的**全部工程难点**：
/// 模型必然给出不存在的 id、越界坐标、退化尺寸、自连、重复目标。散落在应用层
/// 一处一处判，结果一定是"某条路径漏判 ⇒ 抛异常 ⇒ 整批白做"。
/// 集中成一个**纯函数**，才能把每条规则逐个钉进单测（`ai_sanitize_test.dart`）。
///
/// ## 两条贯穿始终的原则
/// ① **丢弃优于抛错**：一个坏动作不该让整批失败，用户要的是"能用的部分照做"；
/// ② **修正要有据**：能确定性修好的就修（越界坐标、退化尺寸、重复 move），
///    修不了才丢，且**每一条都留 warning**。
///
/// ## 一个"政策闸门"
/// 有些动作**能力上做得到、但不该默认允许**，于是放在这里而不是应用层：
/// [allowTextRewrite]（默认 false）—— 改写卡片文本会**覆盖用户已有内容**，而文本
/// 不进退避栈（全应用都还没有文本编辑的撤销通道）⇒ 没得撤销就不该默认开。
///
/// （`group` / `ungroup` 曾在阶段 A 被一律丢弃，因为那时 `CanvasItem.groupId` 是
/// `final`、文档层没有成员关系 API。**A6 补上了** `setItemGroupIds`，它们已归队。）
AiSanitizeResult sanitizeAiActions(
  Iterable<AiAction> raw, {
  required AiInventory inv,
  bool allowTextRewrite = false,
}) {
  final List<AiAction> out = <AiAction>[];
  final List<String> warnings = <String>[];

  /// 同一 item 的多次 `move_item` ⇒ 只保留**最后**一条（模型常自我修正）。
  final Map<String, int> moveIndexById = <String, int>{};

  /// 本批已引用过的块 / 已建立的连线（批内去重）。
  final Set<String> referenced = <String>{};
  final Set<String> connected = <String>{...inv.edgeKeys};

  /// `connect` 的端点判定用**投影态**：本批前面刚引用上来的块也算"已在画布上"。
  ///
  /// ⚠️ 少了这条，「把这两块摆到右边并连起来」这个**最常见**的指令会整条失败 ——
  /// 模型不可能知道还没生成的 item id，它只能按语义顺序表达（先摆、后连）。
  /// 用批前快照校验等于要求模型逆着语义顺序说话。
  final Set<String> liveCardBlockIds = <String>{...inv.cardBlockIds};

  int overflow = 0;

  void drop(String reason) => warnings.add(reason);

  for (final AiAction action in raw) {
    if (out.length >= AiDefaults.maxActions) {
      overflow++;
      continue;
    }

    switch (action) {
      case final ReferenceBlockAction a:
        if (!inv.blockIds.contains(a.blockId)) {
          drop('忽略了引用：块 ${a.blockId} 不在可引用范围内');
          continue;
        }
        if (inv.cardBlockIds.contains(a.blockId) ||
            referenced.contains(a.blockId)) {
          drop('忽略了重复引用：该块已经在画布上');
          continue;
        }
        referenced.add(a.blockId);
        liveCardBlockIds.add(a.blockId);
        out.add(
          ReferenceBlockAction(
            blockId: a.blockId,
            // 卡片有默认尺寸 ⇒ 把中心钳进"保证整张卡都在视口内"的范围，
            // 否则在边缘指一下就会有一半落在视口外。
            at: _clampCenter(
              a.at,
              halfWidth: AiDefaults.cardWidth / 2,
              halfHeight: AiDefaults.cardHeight / 2,
            ),
          ),
        );

      case final AddShapeAction a:
        final NormRect? rect = _normalizeRect(
          a.rect,
          defaultWidth: AiDefaults.shapeWidth,
          defaultHeight: AiDefaults.shapeHeight,
        );
        if (rect == null) {
          drop('忽略了形状：矩形无效');
          continue;
        }
        out.add(AddShapeAction(kind: a.kind, rect: rect));

      case final AddMindMapAction a:
        final NormRect? rect = _normalizeRect(
          a.rect,
          defaultWidth: AiDefaults.mindMapWidth,
          defaultHeight: AiDefaults.mindMapHeight,
        );
        if (rect == null) {
          drop('忽略了思维导图：矩形无效');
          continue;
        }
        final List<String> children = <String>[
          for (final String c in a.children.take(AiDefaults.maxMindMapChildren))
            _truncate(c),
        ];
        if (a.children.length > AiDefaults.maxMindMapChildren) {
          drop('思维导图分支过多，只保留了前 ${AiDefaults.maxMindMapChildren} 个');
        }
        out.add(
          AddMindMapAction(
            rect: rect,
            root: _truncate(a.root),
            children: children,
          ),
        );

      case final MoveItemAction a:
        if (!inv.itemIds.contains(a.id)) {
          drop('忽略了移动：元素 ${a.id} 不存在');
          continue;
        }
        final MoveItemAction fixed = MoveItemAction(
          id: a.id,
          at: _clampCenter(a.at),
        );
        final int? previous = moveIndexById[a.id];
        if (previous != null) {
          out[previous] = fixed; // 取最后一条
          continue;
        }
        moveIndexById[a.id] = out.length;
        out.add(fixed);

      case final SetTextAction a:
        // ⚠️ 默认关闭：这是唯一会**覆盖用户已有内容**的动作，而它不可撤销
        // （卡片文本不进撤销栈 —— 全应用都还没有文本编辑的撤销通道）。
        if (!allowTextRewrite) {
          drop('忽略了改文本：本阶段未开启"改写卡片文本"（该操作暂不可撤销）');
          continue;
        }
        if (!inv.cardItemIds.contains(a.id)) {
          drop('忽略了改文本：${a.id} 不是画布上的卡片');
          continue;
        }
        out.add(SetTextAction(id: a.id, text: _truncate(a.text)));

      case final ConnectAction a:
        if (!liveCardBlockIds.contains(a.fromBlockId) ||
            !liveCardBlockIds.contains(a.toBlockId)) {
          drop('忽略了连线：端点卡片不在画布上');
          continue;
        }
        if (a.fromBlockId == a.toBlockId) {
          drop('忽略了连线：不能连到自身');
          continue;
        }
        final String key = '${a.fromBlockId}>${a.toBlockId}';
        if (connected.contains(key)) {
          drop('忽略了重复连线');
          continue;
        }
        connected.add(key);
        out.add(a);

      case final GroupAction a:
        // 成员必须是画布上的 item；分组框不能进别的组（**不做嵌套**）；
        // 已在别的组里的也不收（否则归属有歧义：一个成员只能属于一个框）。
        final List<String> members = <String>[
          for (final String id in a.ids)
            if (inv.itemIds.contains(id) &&
                !inv.groupItemIds.contains(id) &&
                !inv.groupedItemIds.contains(id))
              id,
        ];
        if (members.length < 2) {
          drop('忽略了分组：可用成员不足两个');
          continue;
        }
        if (members.length != a.ids.length) {
          drop('分组只收下了 ${members.length} 个成员（其余不可用）');
        }
        out.add(
          GroupAction(
            ids: members,
            label: _truncate(a.label, max: AiDefaults.maxLabelLength),
          ),
        );

      case final UngroupAction a:
        final List<String> groups = <String>[
          for (final String id in a.ids)
            if (inv.groupItemIds.contains(id)) id,
        ];
        if (groups.isEmpty) {
          drop('忽略了解散分组：目标不是分组框');
          continue;
        }
        out.add(UngroupAction(ids: groups));

      case final DeleteAction a:
        final List<String> victims = <String>[
          for (final String id in a.ids)
            if (inv.itemIds.contains(id)) id,
        ];
        if (victims.isEmpty) {
          drop('忽略了删除：目标元素不存在');
          continue;
        }
        out.add(DeleteAction(ids: victims));
    }
  }

  if (overflow > 0) {
    warnings.add('动作超过上限（${AiDefaults.maxActions} 条），已忽略 $overflow 条');
  }
  return AiSanitizeResult(actions: out, warnings: warnings);
}

/// 把中心钳进 `[half, 1-half]`：保证带默认尺寸的元素**整块**落在视口内。
NormPoint _clampCenter(
  NormPoint p, {
  double halfWidth = 0,
  double halfHeight = 0,
}) {
  final double loX = halfWidth.clamp(0.0, 1.0);
  final double loY = halfHeight.clamp(0.0, 1.0);
  return NormPoint(
    _clamp01(p.x, lo: loX, hi: 1 - loX),
    _clamp01(p.y, lo: loY, hi: 1 - loY),
  );
}

/// 规整归一化矩形：换序 → 钳到 `[0,1]` → 退化则补默认尺寸 → 顶回边界内。
///
/// 返回 `null` 表示**无法修正**（NaN/无穷）——那种情况才丢。
NormRect? _normalizeRect(
  NormRect r, {
  required double defaultWidth,
  required double defaultHeight,
}) {
  if (!_isFinite(r.left) ||
      !_isFinite(r.top) ||
      !_isFinite(r.right) ||
      !_isFinite(r.bottom)) {
    return null;
  }
  double left = r.left.clamp(0.0, 1.0);
  double right = r.right.clamp(0.0, 1.0);
  double top = r.top.clamp(0.0, 1.0);
  double bottom = r.bottom.clamp(0.0, 1.0);
  // 换序：模型经常把两点写成 [x2,y2,x1,y1]。
  if (left > right) {
    final double swap = left;
    left = right;
    right = swap;
  }
  if (top > bottom) {
    final double swap = top;
    top = bottom;
    bottom = swap;
  }
  // 退化（没给尺寸，或给成了一条线）⇒ 用默认尺寸从左上角长出来。
  if (right - left < AiDefaults.degenerate) {
    right = left + defaultWidth;
  }
  if (bottom - top < AiDefaults.degenerate) {
    bottom = top + defaultHeight;
  }
  // 补完尺寸可能顶出边界 ⇒ 整体平移回来（尺寸不变，只挪位置）。
  if (right > 1) {
    left = (1 - (right - left)).clamp(0.0, 1.0);
    right = 1;
  }
  if (bottom > 1) {
    top = (1 - (bottom - top)).clamp(0.0, 1.0);
    bottom = 1;
  }
  return NormRect.ofLTRB(left, top, right, bottom);
}

double _clamp01(double v, {double lo = 0, double hi = 1}) =>
    v.isNaN ? lo : v.clamp(lo, hi);

bool _isFinite(double v) => v.isFinite;

/// 截断过长文本（模型的"顺便多写两句"会让卡片、导图节点被撑爆）。
String _truncate(String s, {int max = AiDefaults.maxTextLength}) =>
    s.length <= max ? s : s.substring(0, max);
