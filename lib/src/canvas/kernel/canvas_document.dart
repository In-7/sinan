import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'canvas_edge.dart';
import 'canvas_item.dart';
import 'canvas_media.dart';
import 'canvas_migration.dart';
import 'canvas_palette.dart';
import 'ink_stroke.dart';

/// 画布文档：笔迹集合 + 视口裁剪 + 撤销/重做。
///
/// ## v2 重构：id-keyed store
/// 原实现用两个 `List` 存笔迹/图片，靠**列表顺序**表达 z 序，且撤销命令按
/// 实例引用记录变更——没有稳定寻址，无法「重新生成一个节点」「跨进程同步」。
/// 现改为：
///   - `_strokes` / `_items`：以 `id` 为键的 **Map**（稳定引用，O(1) 查找）；
///   - `_strokeOrder` / `_itemOrder`：显式 z 序（底→顶），绘制与命中按此遍历；
///   - 撤销命令全部**按 id 寻址**（增 / 删 / 改一致口径，命令里不再持实例），
///     天然可序列化、可重放，为日后 CRDT 同步 / AI 节点重生铺路；被移除的原件
///     由文档暂存（`_detached*`），撤销命令只记 `(index, id)`。
///
/// 行为完全等价于重构前（items 恒在 strokes 下方，命中优先 items，撤销/重做
/// 还原 z 序）。[toJson] 输出 [kCanvasSchemaVersion]（当前 2）；[fromJson] **先经
/// [CanvasMigrations] 把任意旧存档升到当前版本**——历史格式的兼容收敛在迁移链里，
/// 解析器只认当前版本。
///
/// ## 为什么先只做笔迹
/// 笔迹是画布里**唯一量大**（一页几千条）且决定性能下限的内容——先把它的
/// 裁剪、命中、撤销跑通，再往上加卡片/图片/形状（它们都是"少量大对象"，
/// 走同一套 [strokesIn] 之外的 item 列表即可，架构不变）。
///
/// ## 空间索引的现状
/// 目前是**线性扫描 + 包围盒粗筛**（[strokesIn]）：几千条笔迹下每次裁剪
/// 是几千次 `Rect.overlaps`，量级上仍远小于绘制成本（实测前先用这个）。
/// 真到万级再换均匀网格/瓦片——见 `docs/canvas_architecture.md` 的性能预算。
class CanvasDocument {
  final Map<String, InkStroke> _strokes = <String, InkStroke>{};
  final Map<String, CanvasItem> _items = <String, CanvasItem>{};

  /// 自由连线（v9）。**端点存 id 不存坐标**（binding）：端点位置在绘制时才由
  /// 两端 item 的当前 rect 推出 ⇒ 拖动卡片连线自动跟随，删卡片连线自动消失。
  final Map<String, CanvasEdge> _edges = <String, CanvasEdge>{};

  /// z 序（底→顶）。绘制/命中/序列化均按此遍历；与 Map 配合保证稳定寻址下
  /// 仍能精确还原 z 序（撤销插入回原位）。
  final List<String> _strokeOrder = <String>[];
  final List<String> _itemOrder = <String>[];

  /// 连线的**序列化顺序**（与 Map 配合，撤销插入能回原位）。连线没有 z 序语义，
  /// 这条只保证往返稳定。
  final List<String> _edgeOrder = <String>[];

  final List<CanvasCommand> _undoStack = <CanvasCommand>[];
  final List<CanvasCommand> _redoStack = <CanvasCommand>[];

  /// 批处理中收集到的命令；**非 null 表示正处在 [batch] 里**。
  ///
  /// [batch] 期间 [_push] 只往这里记账，收尾时才合成一条入栈。
  List<CanvasCommand>? _batching;

  /// **已移出但在等还原**的记录（id → 原件）。
  ///
  /// ## 为什么需要暂存（撤销命令按 id 寻址的配套）
  /// "把删掉的记录放回来"有两条路：① 命令里存**副本数据**（JSON），还原时重建
  /// 对象；② 文档**暂存原件**，命令只存 `(index, id)`。这里选 ②，因为重建有
  /// 真实代价与副作用：
  /// - [InkStroke] 重建要重算 perfect_freehand 轮廓（`outline`）——一次撤销/重做
  ///   一条笔迹就要付一次，而这恰好在最热的路径上；
  /// - [ImageItem] 已解码的 `ui.Image` 不在 JSON 里 ⇒ 重建后图会消失、还得重解码，
  ///   旧句柄也无人释放；
  /// - 选区与其他命令持有的实例引用会因"换了新对象"而失效。
  ///
  /// 代价是与命令生命周期绑定的回收：只有**两个栈都不再需要**的记录才可丢，
  /// 见 [_gcRetained]。
  final Map<String, InkStroke> _detachedStrokes = <String, InkStroke>{};
  final Map<String, CanvasItem> _detachedItems = <String, CanvasItem>{};
  final Map<String, CanvasEdge> _detachedEdges = <String, CanvasEdge>{};

  /// 内容版本号：任何增删改（含撤销/重做）都 +1。
  ///
  /// 存在意义是**缓存失效**：笔迹合成的 `ui.Picture` 只在版本号变化时重录
  /// （见 `CanvasController.committedPicture`）。用版本号而不是"比较列表
  /// 内容"，才能把撤销/重做这类"内容变了但条数可能没变"的情况也覆盖。
  int revision = 0;

  /// 笔迹集合（按 z 序）；仅供渲染/序列化读取，写入走 [addStroke]/[removeStrokes]。
  List<InkStroke> get strokes => <InkStroke>[
    for (final String id in _strokeOrder) _strokes[id]!,
  ];

  /// item 集合（按 z 序，**列表顺序即 z 序**，后加的在上）。绘制在笔迹**下方**
  /// （OneNote 口径：墨迹批注在图片上），但**命中优先于笔迹**——框选工具
  /// 下点到的"能整体拖走的对象"优先响应。
  List<CanvasItem> get items => <CanvasItem>[
    for (final String id in _itemOrder) _items[id]!,
  ];

  /// item 条数。**不分配列表**——[items] 每次都新建一个 List，而本 getter 要供
  /// `CanvasController` 的 LOD（每次通知都读）这类热路径用，不能让它分配。
  int get itemCount => _itemOrder.length;

  /// 连线集合（按序列化顺序）。绘制不直接用它——端点要现算，见 [edgesIn]。
  List<CanvasEdge> get edges => <CanvasEdge>[
    for (final String id in _edgeOrder) _edges[id]!,
  ];

  bool get canUndo => _undoStack.isNotEmpty;

  bool get canRedo => _redoStack.isNotEmpty;

  /// 暂存区里的记录条数（诊断/测试用）：>0 表示有"移出在场、还等着被还原"的
  /// 记录。正常情况下它应当与撤销/重做栈里命令的引用保持一致，不会无界增长。
  int get detachedCount => _detachedStrokes.length + _detachedItems.length;

  /// 所有内容（笔迹 + item）的包围盒（世界坐标）。空文档返回 null。
  Rect? get bounds {
    Rect? result;
    for (final String id in _strokeOrder) {
      final Rect? box = _strokes[id]!.bounds;
      if (box == null) continue;
      result = result == null ? box : result.expandToInclude(box);
    }
    for (final String id in _itemOrder) {
      final CanvasItem item = _items[id]!;
      result = result == null
          ? item.bounds
          : result.expandToInclude(item.bounds);
    }
    return result;
  }

  /// 与 [worldViewport] 相交的笔迹（绘制与命中测试的输入）。
  List<InkStroke> strokesIn(Rect worldViewport) => <InkStroke>[
    for (final String id in _strokeOrder)
      if (_strokes[id]!.bounds?.overlaps(worldViewport) ?? false) _strokes[id]!,
  ];

  /// 按 id 稳定查表（生成器做 img2img 时按 [GenRecipe.inputs] 找引用节点）。
  CanvasItem? itemById(String id) => _items[id];

  /// 按**卡片内容 id**（`CardItem.blockId`）反查卡片。
  ///
  /// 连线存的是 blockId 而不是 item id（与 `canvas_edges.from_id` 外键
  /// `blocks(id)` 同口径，见 [CanvasEdge.fromId]），所以绘制连线时要走这里。
  /// 线性扫描即可：卡片是"少量大对象"，不值得为它维护一份索引。
  ///
  /// 端点卡片被删 ⇒ 返回 null ⇒ 那条边不画（悬空边，见 [edgesIn]）。
  CanvasItem? itemByBlockId(String blockId) {
    for (final String id in _itemOrder) {
      final CanvasItem? item = _items[id];
      if (item is CardItem && item.blockId == blockId) return item;
    }
    return null;
  }

  /// 与 [worldViewport] 相交的 item（绘制与框选的输入；item 数量少，
  /// 不值得再做缓存）。
  List<CanvasItem> itemsIn(Rect worldViewport) => <CanvasItem>[
    for (final String id in _itemOrder)
      if (_items[id]!.bounds.overlaps(worldViewport)) _items[id]!,
  ];

  /// 最上层命中的 item（框选工具的点击选择）。没有则 null。
  CanvasItem? hitItemAt(Offset world, double radius) {
    for (int i = _itemOrder.length - 1; i >= 0; i--) {
      final CanvasItem? item = _items[_itemOrder[i]];
      if (item != null && item.hitTest(world, radius)) return item;
    }
    return null;
  }

  void addItem(CanvasItem item) {
    _items[item.id] = item;
    _itemOrder.add(item.id);
    _push(_AddItem(item.id));
    revision++;
  }

  /// 删除指定 item（框选后删除共用）。返回实际删掉的。
  ///
  /// 只是"移出在场"：原件进 [_detachedItems] 暂存，命令只记 `(index, id)`，
  /// 于是 undo/redo 拿回的是**同一个对象**。
  List<CanvasItem> removeItems(Iterable<CanvasItem> victims) {
    final List<_IndexedItem> hit = <_IndexedItem>[];
    for (int i = 0; i < _itemOrder.length; i++) {
      final String id = _itemOrder[i];
      final CanvasItem? item = _items[id];
      if (item != null && victims.contains(item)) {
        hit.add(_IndexedItem(i, id));
      }
    }
    if (hit.isEmpty) return const <CanvasItem>[];

    // 按索引降序删除，保证靠前的索引在删除后仍有效。
    final List<CanvasItem> removed = <CanvasItem>[];
    for (final _IndexedItem e in hit.reversed) {
      _itemOrder.removeAt(e.index);
      final CanvasItem? item = _detachItem(e.id);
      if (item != null) removed.add(item);
    }
    // binding：卡片没了，指向它的连线不该留下 —— 与数据库外键同语义
    // （`canvas_edges.from_id/to_id` → `blocks(id) ON DELETE CASCADE`）。
    // ⚠️ 同样**降序**删，撤销时按 cutEdges.reversed 插回。
    // 被删对象的**连线身份**：卡片是 `blockId`（连线存的是它，见
    // [CanvasEdge.fromId]），其它 item 是 item id —— **两者都要匹配**，
    // 否则会出现"卡片删了、指向它的连线还留着"的悬空边。
    final Set<String> victimIds = <String>{
      for (final CanvasItem item in victims) item.id,
      for (final CanvasItem item in victims)
        if (item is CardItem) item.blockId,
    };
    final List<_IndexedEdge> cutEdges = <_IndexedEdge>[];
    for (int i = _edgeOrder.length - 1; i >= 0; i--) {
      final CanvasEdge? edge = _edges[_edgeOrder[i]];
      if (edge == null) continue;
      if (!victimIds.contains(edge.fromId) && !victimIds.contains(edge.toId)) {
        continue;
      }
      _edgeOrder.removeAt(i);
      _detachEdge(edge.id);
      cutEdges.add(_IndexedEdge(i, edge.id));
    }

    // **分组框没了 ⇒ 成员必须解绑**：否则它们会留下指向不存在分组的 `groupId`
    // （悬空），从此既进不了别的组、框也画不出来。与上面那条连线同理，必须放在
    // 同一条命令里 —— 否则撤销后会"框回来了、成员却不再属于它"。
    final List<_ItemGroupId> unbound = <_ItemGroupId>[];
    for (final CanvasItem victim in victims) {
      if (victim is! CanvasGroupItem) continue;
      for (final CanvasItem member in _items.values) {
        if (member.groupId != victim.id) continue;
        unbound.add(_ItemGroupId(member.id, victim.id, null));
        member.groupId = null;
      }
    }

    // hit 本身即升序索引，撤销时按升序插回原位。
    _push(_RemoveItems(hit, edges: cutEdges, unboundMembers: unbound));
    revision++;
    // 返回顺序与旧实现一致：按索引升序。
    return removed.reversed.toList(growable: false);
  }

  /// 新增一条连线（端点用 **id**，见 [CanvasEdge] 的 binding 说明）。
  void addEdge(CanvasEdge edge) {
    _edges[edge.id] = edge;
    _edgeOrder.add(edge.id);
    _push(_AddEdge(edge.id));
    revision++;
  }

  /// 更新一条连线的端点（拖端点把手改接另一张卡片；[next] 的 id 必须与旧的一致）。
  ///
  /// `CanvasEdge` 是不可变的 ⇒ 更新 = **替换对象**，撤销时把旧对象换回来即可。
  /// z 序/序列化位置不变（`_edgeOrder` 只认 id）。
  void updateEdge(CanvasEdge next) {
    final CanvasEdge? old = _edges[next.id];
    if (old == null) return;
    _edges[next.id] = next;
    _push(_UpdateEdge(next.id, old, next));
    revision++;
  }

  /// 删除连线。返回实际删掉的（按序列化顺序）。
  List<CanvasEdge> removeEdges(Iterable<CanvasEdge> victims) {
    final List<_IndexedEdge> hit = <_IndexedEdge>[];
    for (int i = 0; i < _edgeOrder.length; i++) {
      final CanvasEdge? edge = _edges[_edgeOrder[i]];
      if (edge != null && victims.contains(edge)) {
        hit.add(_IndexedEdge(i, edge.id));
      }
    }
    if (hit.isEmpty) return const <CanvasEdge>[];

    final List<CanvasEdge> removed = <CanvasEdge>[];
    for (final _IndexedEdge e in hit.reversed) {
      _edgeOrder.removeAt(e.index);
      final CanvasEdge? edge = _detachEdge(e.id);
      if (edge != null) removed.add(edge);
    }
    _push(_RemoveEdges(hit));
    revision++;
    return removed.reversed.toList(growable: false);
  }

  /// 与视口相交的连线（**端点已算好**，绘制层不再需要文档）。
  ///
  /// 任一端 item 缺失（卡片被删 / 还没载入）⇒ 该边**不返回**：连线依附于两端的
  /// 卡片，不是独立内容 —— 悬空边画出来只会指向虚无。
  List<EdgeGeometry> edgesIn(Rect worldViewport) {
    final List<EdgeGeometry> out = <EdgeGeometry>[];
    for (final String id in _edgeOrder) {
      final CanvasEdge? edge = _edges[id];
      if (edge == null) continue;
      // 端点按 **blockId** 反查（与存储外键同口径，见 [CanvasEdge.fromId]）。
      final CanvasItem? from = itemByBlockId(edge.fromId);
      final CanvasItem? to = itemByBlockId(edge.toId);
      if (from == null || to == null) continue;
      final EdgeGeometry? geo = CanvasEdges.geometryOf(
        edge,
        from.rect,
        to.rect,
      );
      if (geo == null) continue;
      // 粗筛：两端锚点的包围盒（放宽 64 —— 贝塞尔的控制点会甩到盒外一点）。
      if (!Rect.fromPoints(
        geo.from,
        geo.to,
      ).inflate(64).overlaps(worldViewport)) {
        continue;
      }
      out.add(geo);
    }
    return out;
  }

  /// 连线的**命中测试**：[world] 到某条边线的最近距离 ≤ [tolerance]（世界单位）
  /// ⇒ 返回该边（离得最近的那条）。用于"点连线选中 → 删除"。
  ///
  /// 与 [edgesIn] 不同，这里**不做视口裁剪**——用户点连线不该被"视口外就不命中"
  /// 限制；且命中只在按下时发生，不在每帧，多算几条无妨。
  CanvasEdge? hitEdgeAt(Offset world, double tolerance) {
    CanvasEdge? best;
    double bestDist = tolerance;
    for (final String id in _edgeOrder) {
      final CanvasEdge? edge = _edges[id];
      if (edge == null) continue;
      // 端点按 blockId 反查（与 [edgesIn] 同口径：连线依附卡片）。
      final CanvasItem? from = itemByBlockId(edge.fromId);
      final CanvasItem? to = itemByBlockId(edge.toId);
      if (from == null || to == null) continue;
      final EdgeGeometry? geo = CanvasEdges.geometryOf(
        edge,
        from.rect,
        to.rect,
      );
      if (geo == null) continue;
      final double d = _distanceToPath(geo.path(), world);
      if (d <= bestDist) {
        bestDist = d;
        best = edge;
      }
    }
    return best;
  }

  /// 点到一段贝塞尔曲线的最近距离（沿度量采样逐段求最短）。
  double _distanceToPath(ui.Path path, Offset point) {
    double min = double.infinity;
    for (final ui.PathMetric m in path.computeMetrics()) {
      const int steps = 24;
      for (int i = 0; i <= steps; i++) {
        final double t = m.length * i / steps;
        final ui.Offset p = m.getTangentForOffset(t)!.position;
        final double d = (p - point).distance;
        if (d < min) min = d;
      }
    }
    return min;
  }

  /// 设置一批 item 的**语义色槽位**（一次面板操作 = 一条撤销命令）。
  ///
  /// 与 [setItemTransforms] 同口径：调用方**先就地改** item，再把"改动前的值"交
  /// 进来；命令按 id 寻址。与当前值相同的项被过滤（连点色板不会刷栈）。
  void setItemColorSlots(List<(CanvasItem, CanvasColorSlot?)> changes) {
    final List<_ItemColorSlot> entries = <_ItemColorSlot>[
      for (final (CanvasItem item, CanvasColorSlot? before) in changes)
        if (item.colorSlot != before)
          _ItemColorSlot(item.id, before, item.colorSlot),
    ];
    if (entries.isEmpty) return;
    _push(_SetItemColorSlots(entries));
    revision++;
  }

  /// 设置一批 item 的**分组归属**（一次分组 / 解散 = 一条撤销命令）。
  ///
  /// 与 [setItemColorSlots] 同范式：调用方**先就地改** [CanvasItem.groupId]，
  /// 再把"改动前的值"交进来；命令按 id 寻址、只存值，因而可撤销可重放。
  /// 值没真变的项被过滤（重复调用不刷栈）。
  ///
  /// ⚠️ [CanvasItem.groupId] 于 2026-09-19 由 `final` 改为可变 —— 此前"把元素加进
  /// 分组框"在运行时**做不到**，`CanvasGroupItem` 只有存档与测试能造。
  void setItemGroupIds(List<(CanvasItem, String?)> changes) {
    final List<_ItemGroupId> entries = <_ItemGroupId>[
      for (final (CanvasItem item, String? before) in changes)
        if (item.groupId != before) _ItemGroupId(item.id, before, item.groupId),
    ];
    if (entries.isEmpty) return;
    _push(_SetItemGroupIds(entries));
    revision++;
  }

  /// 拖动/缩放/旋转**结束**后的落账：[changes] 为 (item, 改动前 rect, 改动前
  /// angle) 三元组，item 的 rect/angle 此时已是新值。一次手势合并成一条命令。
  ///
  /// 命令内部改为**按 id 寻址**（[ _ItemTransform.id]），撤销/重做时回查节点——
  /// 不再持有实例引用，从而可序列化、可重放。
  void setItemTransforms(List<(CanvasItem, Rect, double)> changes) {
    final List<_ItemTransform> entries = <_ItemTransform>[
      for (final (CanvasItem item, Rect oldRect, double oldAngle) in changes)
        if (item.rect != oldRect || item.angle != oldAngle)
          _ItemTransform(item.id, oldRect, oldAngle, item.rect, item.angle),
    ];
    if (entries.isEmpty) return;
    _push(_SetItemTransforms(entries));
    revision++;
  }

  /// 改**形状样式**结束后的落账：[changes] 为 (item, 改动前样式) 二元组，
  /// item 的样式此时已是新值。一次面板操作（点色块 / 拖滑杆）= 一条命令，
  /// 与 [setItemTransforms] 同范式。
  ///
  /// 值没真变的项不进命令——滑杆拖动会连发很多次，值相同的那些不该各占一条历史。
  void setItemStyles(List<(ShapeItem, ShapeStyle)> changes) {
    final List<_ItemStyle> entries = <_ItemStyle>[
      for (final (ShapeItem item, ShapeStyle oldStyle) in changes)
        if (item.color != oldStyle.color ||
            item.strokeWidth != oldStyle.strokeWidth ||
            item.filled != oldStyle.filled)
          _ItemStyle(item.id, oldStyle, item.style),
    ];
    if (entries.isEmpty) return;
    _push(_SetItemStyles(entries));
    revision++;
  }

  void addStroke(InkStroke stroke) {
    _strokes[stroke.id] = stroke;
    _strokeOrder.add(stroke.id);
    _push(_AddStroke(stroke.id));
    revision++;
  }

  /// 橡皮（OneNote「笔画橡皮」口径：命中即整条删除）。返回被删掉的笔迹。
  List<InkStroke> eraseAt(Offset world, double radius) =>
      removeStrokes(<InkStroke>[
        for (final String id in _strokeOrder)
          if (_strokes[id]!.hitTest(world, radius)) _strokes[id]!,
      ]);

  /// 删除指定笔迹（框选后删除 / 橡皮共用）。返回实际删掉的。
  List<InkStroke> removeStrokes(Iterable<InkStroke> victims) {
    final List<_IndexedStroke> hit = <_IndexedStroke>[];
    for (int i = 0; i < _strokeOrder.length; i++) {
      final String id = _strokeOrder[i];
      final InkStroke? stroke = _strokes[id];
      if (stroke != null && victims.contains(stroke)) {
        hit.add(_IndexedStroke(i, id));
      }
    }
    if (hit.isEmpty) return const <InkStroke>[];

    final List<InkStroke> removed = <InkStroke>[];
    for (final _IndexedStroke e in hit.reversed) {
      _strokeOrder.removeAt(e.index);
      final InkStroke? stroke = _detachStroke(e.id);
      if (stroke != null) removed.add(stroke);
    }
    _push(_RemoveStrokes(hit));
    revision++;
    return removed.reversed.toList(growable: false);
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    final CanvasCommand command = _undoStack.removeLast();
    command.undo(this);
    _redoStack.add(command);
    revision++;
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    final CanvasCommand command = _redoStack.removeLast();
    command.redo(this);
    _undoStack.add(command);
    revision++;
  }

  /// 把 [body] 里产生的所有命令**合并成一条**（照 tldraw `editor.run()` 的思路）。
  ///
  /// ## 为什么必须有
  /// 一次 AI 指令往往同时改很多元素（摆几张卡片、连几条线、挪几个位置）。按单条
  /// 入栈的话，用户要按 N 次 Ctrl+Z 才回到原点 —— 那等于"AI 的改动不可撤销"。
  ///
  /// ## 为什么清重做栈与暂存回收都推迟到收尾
  /// 批中途文档处于**半套**状态（可能"先删卡片、再把别的东西连到它上面"这种中间
  /// 态）。若沿用单条那套规矩，在批中间就清空重做栈或回收暂存记录，会误伤**同一
  /// 批里后面还要用**的记录与历史。故两件事都留到组合命令入栈之后，完全复用
  /// [_push] 的既有语义。
  ///
  /// ## 边界
  /// - **嵌套安全**：内层 [batch] 只是并入外层，不产生第二条命令；
  /// - **异常安全**：即使 [body] 抛了，已收集的命令**仍然**合成一条入栈 —— 那些
  ///   改动确实已经生效，必须可撤销，不能留下"改了但撤不了"的状态；
  /// - 空批不产生命令（撤销栈长度不变）。
  void batch(void Function() body) {
    if (_batching != null) {
      // 已在批里：直接并入当前批，别产生第二条。
      body();
      return;
    }
    final List<CanvasCommand> collected = <CanvasCommand>[];
    _batching = collected;
    try {
      body();
    } finally {
      _batching = null;
      if (collected.isNotEmpty) {
        // 只有一条时不必包一层：避免无意义的嵌套命令。
        _push(
          collected.length == 1 ? collected.single : _BatchCommands(collected),
        );
      }
    }
  }

  void _push(CanvasCommand command) {
    // 批处理中：只记账，收尾时合成一条。清重做栈与回收都**推迟**到那时——
    // 批中途文档处于"半套"状态，提前做会误伤同批后面还要用的记录/历史。
    final List<CanvasCommand>? batching = _batching;
    if (batching != null) {
      batching.add(command);
      return;
    }
    if (_redoStack.isNotEmpty) {
      // 新操作作废重做栈（标准语义）——这是命令**唯一**永久离场的时刻，
      // 故回收暂存记录只可能发生在这里。
      _redoStack.clear();
    }
    // ⚠️ 必须先入栈再回收：新命令也是它那条记录的归属者，否则刚被它移出、
    // 正等还原的原件会被当成垃圾丢掉。
    _undoStack.add(command);
    if (_detachedStrokes.isNotEmpty || _detachedItems.isNotEmpty) {
      _gcRetained();
    }
  }

  /// 回收暂存记录：只有**两个栈都不再可能还原**它的才可以丢。
  ///
  /// 丢掉的只是文档这一侧的引用；若该记录持有 `ui.Image`，Dart GC 的终结器会
  /// 释放底层资源（此前它被撤销命令永久持有，反而回收不了）。
  void _gcRetained() {
    final Set<String> live = <String>{};
    for (final CanvasCommand command in _undoStack) {
      live.addAll(command.retainedIds);
    }
    for (final CanvasCommand command in _redoStack) {
      live.addAll(command.retainedIds);
    }
    _detachedStrokes.removeWhere(
      (String id, InkStroke value) => !live.contains(id),
    );
    _detachedItems.removeWhere(
      (String id, CanvasItem value) => !live.contains(id),
    );
    _detachedEdges.removeWhere(
      (String id, CanvasEdge value) => !live.contains(id),
    );
  }

  /// 记录移出"在场"（进暂存区，等还原）。返回被移出的原件。
  InkStroke? _detachStroke(String id) {
    final InkStroke? stroke = _strokes.remove(id);
    if (stroke != null) _detachedStrokes[id] = stroke;
    return stroke;
  }

  /// 记录放回"在场"（从暂存区取回**同一个**对象）。
  InkStroke? _reattachStroke(String id) {
    final InkStroke? stroke = _detachedStrokes.remove(id);
    if (stroke != null) _strokes[id] = stroke;
    return stroke;
  }

  CanvasItem? _detachItem(String id) {
    final CanvasItem? item = _items.remove(id);
    if (item != null) _detachedItems[id] = item;
    return item;
  }

  CanvasItem? _reattachItem(String id) {
    final CanvasItem? item = _detachedItems.remove(id);
    if (item != null) _items[id] = item;
    return item;
  }

  CanvasEdge? _detachEdge(String id) {
    final CanvasEdge? edge = _edges.remove(id);
    if (edge != null) _detachedEdges[id] = edge;
    return edge;
  }

  CanvasEdge? _reattachEdge(String id) {
    final CanvasEdge? edge = _detachedEdges.remove(id);
    if (edge != null) _edges[id] = edge;
    return edge;
  }

  /// 序列化为纯数据（schemaVersion=2：id-keyed map + 显式 z 序）。
  ///
  /// [media] 提供时：图片 `src` 写成**相对引用**，并附一份 `media` **侧表**
  /// （引用 → `{mime}`）。侧表是 items 的**派生索引**（单一真源仍是各 item 的
  /// `src`，因此不会漂移），用途有三：导出时按它内联字节、载入时可校验缺失、
  /// 宿主可据此做引用保护。
  ///
  /// 不传 [media] 则完全保持旧行为（`src` 写绝对路径、无侧表），既有调用方与
  /// 测试无需改动。
  Map<String, dynamic> toJson({MediaResolver? media}) => <String, dynamic>{
    'schemaVersion': kCanvasSchemaVersion,
    'strokes': <String, dynamic>{
      for (final String id in _strokeOrder) id: _strokes[id]!.toJson(),
    },
    'items': <String, dynamic>{
      for (final String id in _itemOrder) id: _items[id]!.toJson(media: media),
    },
    // ⚠️ 连线**为空时故意不写这个键**：旧存档本来就没有它，若总是写空 map，
    // 第 3 步的深比较会把"原文无 edges / 还原有 edges {}"判成不一致
    // ⇒ 所有老画布静默回退 JSON（不报错、只是切读永不生效）。
    if (_edgeOrder.isNotEmpty)
      'edges': <String, dynamic>{
        for (final String id in _edgeOrder) id: _edges[id]!.toJson(),
      },
    'strokeOrder': List<String>.from(_strokeOrder),
    'itemOrder': List<String>.from(_itemOrder),
    if (media != null) 'media': _mediaManifest(media),
  };

  /// 媒体侧表：文档引用到的每个媒体文件 → `{mime}`。
  ///
  /// 只列 `src` 有值的图片（生成中的 AI 层 `src` 为空 ⇒ 不入表）。
  Map<String, dynamic> _mediaManifest(MediaResolver media) {
    final Map<String, dynamic> manifest = <String, dynamic>{};
    for (final String id in _itemOrder) {
      final CanvasItem item = _items[id]!;
      if (item is! ImageItem) continue;
      final String ref = media.toRef(item.src);
      if (ref.isEmpty) continue;
      manifest[ref] = <String, dynamic>{'mime': mediaMimeOf(ref)};
    }
    return manifest;
  }

  /// 反序列化：**先经 [CanvasMigrations] 把任意旧存档升到当前版本**，再按当前
  /// 版本解析（历史格式的兼容收敛在迁移链里，解析器不再散落 `if`）。
  /// 载入即权威状态，不产生撤销命令。
  ///
  /// [media] 用于把侧表里的**相对引用**换算回运行时绝对路径；旧存档若存的是
  /// 绝对路径，解析器原样通过，因此无需迁移。
  ///
  /// 抛 [CanvasSchemaTooNewException]（存档比内核新）——不静默降级解析，否则会
  /// 丢掉新字段；宿主侧有"载入失败 ⇒ 冻结保存"的兜底，数据不会被覆盖。
  static CanvasDocument fromJson(
    Map<String, dynamic> j, {
    MediaResolver? media,
  }) {
    // 迁移到当前版本后，下面只按**当前**格式解析。
    final Map<String, dynamic> doc = CanvasMigrations.migrate(j);

    final CanvasDocument out = CanvasDocument();
    final Object? strokesRaw = doc['strokes'];
    if (strokesRaw is Map) {
      (strokesRaw as Map<Object?, Object?>).forEach((Object? k, Object? v) {
        if (v is! Map<String, dynamic>) return;
        final InkStroke st = InkStroke.fromJson(v);
        out._strokes[st.id] = st;
      });
    }
    final Object? itemsRaw = doc['items'];
    if (itemsRaw is Map) {
      (itemsRaw as Map<Object?, Object?>).forEach((Object? k, Object? v) {
        if (v is! Map<String, dynamic>) return;
        final CanvasItem it = CanvasItem.fromJson(v, media: media);
        out._items[it.id] = it;
      });
    }
    // z 序：显式数组（迁移已保证存在）。非 String 的脏元素跳过。
    for (final Object? id
        in (doc['strokeOrder'] as List?) ?? const <Object?>[]) {
      if (id is String) out._strokeOrder.add(id);
    }
    for (final Object? id in (doc['itemOrder'] as List?) ?? const <Object?>[]) {
      if (id is String) out._itemOrder.add(id);
    }

    // ⚠️ 载入即**把 id 发生器推到已有 id 之后**：存档里的 id 来自之前的进程，
    // 而计数器每次启动都从 0 开始 —— 不推进的话，新建元素会拿到与存档重复的
    // id，`addItem` 的覆盖语义会让旧元素凭空消失（2026-09-17 修，见
    // `advanceItemIdSequence` 的说明）。
    // 连线（v9，**可选键**）：缺即空。与 items 不同它没有 z 序数组 —— 连线
    // 无所谓谁上谁下，只有一条序列化顺序。
    final Object? edgesRaw = doc['edges'];
    if (edgesRaw is Map) {
      (edgesRaw as Map<Object?, Object?>).forEach((Object? k, Object? v) {
        if (v is! Map<String, dynamic>) return;
        final CanvasEdge edge = CanvasEdge.fromJson(v);
        out._edges[edge.id] = edge;
        out._edgeOrder.add(edge.id);
      });
    }
    advanceItemIdSequence(out._items.keys);
    advanceEdgeIdSequence(out._edges.keys);
    return out;
  }
}

/// 撤销命令：记录"做了什么"，[undo] / [redo] 互为逆操作。
///
/// ## 按 id 寻址（命令里不持实例）
/// 命令只存 `(index, id)`；被移除的原件由文档暂存（`_detached*`），因而命令是
/// **纯数据**——可序列化、可重放，也不怕实例被替换（如 AI 层重算）。这与
/// [_SetItemTransforms] 的口径一致。
///
/// 注意边界：命令本身是纯数据，但"还原"依赖文档内的暂存表，故撤销栈是**会话内**
/// 的（不落盘）。跨进程同步要传的是 diff（命令的 id 序列 + 记录的 `toJson`），
/// 而不是这套命令对象。
abstract class CanvasCommand {
  const CanvasCommand();

  void undo(CanvasDocument document);

  void redo(CanvasDocument document);

  /// 该命令**可能还原**的记录 id。文档据此回收暂存记录：只要还有命令可能还原
  /// 它，就不能丢（见 `CanvasDocument._gcRetained`）。
  Iterable<String> get retainedIds => const <String>[];
}

/// 组合命令：把一批命令当**一条**对待（见 [CanvasDocument.batch]）。
///
/// [undo] **逆序**、[redo] **顺序**：批内后面那条可能依赖前面那条的结果
/// （先建卡片、再把连线接上去），只有严格互逆才能回滚干净。
class _BatchCommands extends CanvasCommand {
  const _BatchCommands(this.commands);

  /// 按批内**实际执行顺序**。
  final List<CanvasCommand> commands;

  /// 取**并集**：批里任何一条可能还原的记录都不能被回收。
  ///
  /// ⚠️ 少了这条，`_gcRetained` 会把批中途移进暂存区的原件当垃圾丢掉 ——
  /// 症状是"撤销后元素回不来"（而且只在批里删过东西时才出现）。
  @override
  Iterable<String> get retainedIds => <String>[
    for (final CanvasCommand c in commands) ...c.retainedIds,
  ];

  @override
  void undo(CanvasDocument document) {
    for (final CanvasCommand c in commands.reversed) {
      c.undo(document);
    }
  }

  @override
  void redo(CanvasDocument document) {
    for (final CanvasCommand c in commands) {
      c.redo(document);
    }
  }
}

class _AddStroke extends CanvasCommand {
  const _AddStroke(this.id);

  final String id;

  @override
  Iterable<String> get retainedIds => <String>[id];

  @override
  void undo(CanvasDocument document) {
    document._strokeOrder.remove(id);
    document._detachStroke(id);
  }

  @override
  void redo(CanvasDocument document) {
    if (document._reattachStroke(id) == null) return;
    document._strokeOrder.add(id);
  }
}

class _RemoveStrokes extends CanvasCommand {
  const _RemoveStrokes(this.entries);

  /// 按**索引升序**，撤销时依次插回原位。
  final List<_IndexedStroke> entries;

  @override
  Iterable<String> get retainedIds => <String>[
    for (final _IndexedStroke e in entries) e.id,
  ];

  @override
  void undo(CanvasDocument document) {
    for (final _IndexedStroke e in entries) {
      if (document._reattachStroke(e.id) == null) continue;
      document._strokeOrder.insert(e.index, e.id);
    }
  }

  @override
  void redo(CanvasDocument document) {
    for (final _IndexedStroke e in entries.reversed) {
      document._strokeOrder.removeAt(e.index);
      document._detachStroke(e.id);
    }
  }
}

class _IndexedStroke {
  const _IndexedStroke(this.index, this.id);

  final int index;
  final String id;
}

class _AddItem extends CanvasCommand {
  const _AddItem(this.id);

  final String id;

  @override
  Iterable<String> get retainedIds => <String>[id];

  @override
  void undo(CanvasDocument document) {
    document._itemOrder.remove(id);
    document._detachItem(id);
  }

  @override
  void redo(CanvasDocument document) {
    if (document._reattachItem(id) == null) return;
    // 重新加回即"最新的一层"（与 [CanvasDocument.addItem] 一致，z 序之顶）。
    document._itemOrder.add(id);
  }
}

class _RemoveItems extends CanvasCommand {
  const _RemoveItems(
    this.entries, {
    this.edges = const <_IndexedEdge>[],
    this.unboundMembers = const <_ItemGroupId>[],
  });

  /// 按**索引升序**，撤销时依次插回原位（z 序一并还原）。
  final List<_IndexedItem> entries;

  /// 因卡片被删而**连带**删掉的连线（**降序**，撤销时需反转）。
  ///
  /// 放在**同一条命令**里是刻意的：用户按一次撤销，卡片和它的连线要一起回来。
  /// 分成两条命令就得按两次，且中间态是"卡片回来了、连线没了"的怪状态。
  final List<_IndexedEdge> edges;

  /// 因**分组框被删**而解绑的成员（`old = 原 groupId`、`new = null`）。
  ///
  /// 与 [edges] 同一条理由：解绑与删框必须在同一条命令里。此外它还挡住一种更难查
  /// 的坏状态 —— 成员带着**指向不存在分组**的 `groupId` 活下来（悬空引用）。
  final List<_ItemGroupId> unboundMembers;

  @override
  Iterable<String> get retainedIds => <String>[
    for (final _IndexedItem e in entries) e.id,
    for (final _IndexedEdge e in edges) e.id,
  ];

  @override
  void undo(CanvasDocument document) {
    for (final _IndexedEdge e in edges.reversed) {
      if (document._reattachEdge(e.id) == null) continue;
      document._edgeOrder.insert(e.index, e.id);
    }
    for (final _IndexedItem e in entries) {
      if (document._reattachItem(e.id) == null) continue;
      document._itemOrder.insert(e.index, e.id);
    }
    // 框已经回来了 ⇒ 成员重新绑上（顺序无所谓：改的是同一个实例的字段）。
    for (final _ItemGroupId e in unboundMembers) {
      document._items[e.id]?.groupId = e.oldGroupId;
    }
  }

  @override
  void redo(CanvasDocument document) {
    for (final _IndexedItem e in entries.reversed) {
      document._itemOrder.removeAt(e.index);
      document._detachItem(e.id);
    }
    for (final _IndexedEdge e in edges) {
      document._edgeOrder.removeAt(e.index);
      document._detachEdge(e.id);
    }
    for (final _ItemGroupId e in unboundMembers) {
      document._items[e.id]?.groupId = e.newGroupId;
    }
  }
}

class _IndexedItem {
  const _IndexedItem(this.index, this.id);

  final int index;
  final String id;
}

class _AddEdge extends CanvasCommand {
  const _AddEdge(this.id);

  final String id;

  @override
  Iterable<String> get retainedIds => <String>[id];

  @override
  void undo(CanvasDocument document) {
    document._edgeOrder.remove(id);
    document._detachEdge(id);
  }

  @override
  void redo(CanvasDocument document) {
    if (document._reattachEdge(id) == null) return;
    document._edgeOrder.add(id);
  }
}

class _UpdateEdge extends CanvasCommand {
  const _UpdateEdge(this.id, this.oldEdge, this.newEdge);

  final String id;
  final CanvasEdge oldEdge;
  final CanvasEdge newEdge;

  @override
  Iterable<String> get retainedIds => <String>[id];

  @override
  void undo(CanvasDocument document) {
    document._edges[id] = oldEdge;
  }

  @override
  void redo(CanvasDocument document) {
    document._edges[id] = newEdge;
  }
}

class _RemoveEdges extends CanvasCommand {
  const _RemoveEdges(this.entries);

  /// 按**索引升序**，撤销时依次插回原位。
  final List<_IndexedEdge> entries;

  @override
  Iterable<String> get retainedIds => <String>[
    for (final _IndexedEdge e in entries) e.id,
  ];

  @override
  void undo(CanvasDocument document) {
    for (final _IndexedEdge e in entries) {
      if (document._reattachEdge(e.id) == null) continue;
      document._edgeOrder.insert(e.index, e.id);
    }
  }

  @override
  void redo(CanvasDocument document) {
    for (final _IndexedEdge e in entries.reversed) {
      document._edgeOrder.removeAt(e.index);
      document._detachEdge(e.id);
    }
  }
}

class _IndexedEdge {
  const _IndexedEdge(this.index, this.id);

  final int index;
  final String id;
}

/// 一次拖拽/缩放/旋转 = 一条命令（多选整体变换也是一条）。
///
/// **v2 改动**：不再持有 [CanvasItem] 实例，只存 `id` + 变换前后值；撤销/重做时
/// 回查 [CanvasDocument._items]。这使得命令可序列化、可重放，且不因实例被替换
/// （如 AI 重生节点）而失效。
class _SetItemTransforms extends CanvasCommand {
  const _SetItemTransforms(this.entries);

  final List<_ItemTransform> entries;

  @override
  void undo(CanvasDocument document) {
    for (final _ItemTransform e in entries) {
      final CanvasItem? item = document._items[e.id];
      if (item != null) {
        item.rect = e.oldRect;
        item.angle = e.oldAngle;
      }
    }
  }

  @override
  void redo(CanvasDocument document) {
    for (final _ItemTransform e in entries) {
      final CanvasItem? item = document._items[e.id];
      if (item != null) {
        item.rect = e.newRect;
        item.angle = e.newAngle;
      }
    }
  }
}

class _ItemTransform {
  const _ItemTransform(
    this.id,
    this.oldRect,
    this.oldAngle,
    this.newRect,
    this.newAngle,
  );

  /// 目标节点 id（稳定引用，取代原实例引用）。
  final String id;
  final Rect oldRect;
  final double oldAngle;
  final Rect newRect;
  final double newAngle;
}

/// 一次样式修改（属性面板）= 一条撤销命令。范式同 [_SetItemTransforms]：
/// 只存 `id` + 前后样式，撤销/重做时回查节点。
class _SetItemStyles extends CanvasCommand {
  const _SetItemStyles(this.entries);

  final List<_ItemStyle> entries;

  @override
  void undo(CanvasDocument document) {
    for (final _ItemStyle e in entries) {
      final CanvasItem? item = document._items[e.id];
      if (item is ShapeItem) item.applyStyle(e.oldStyle);
    }
  }

  @override
  void redo(CanvasDocument document) {
    for (final _ItemStyle e in entries) {
      final CanvasItem? item = document._items[e.id];
      if (item is ShapeItem) item.applyStyle(e.newStyle);
    }
  }
}

/// 一条 item 的"语义色槽位"改动（[CanvasItem.colorSlot] 可为 null = 跟随主题）。
class _ItemColorSlot {
  const _ItemColorSlot(this.id, this.oldSlot, this.newSlot);

  final String id;
  final CanvasColorSlot? oldSlot;
  final CanvasColorSlot? newSlot;
}

/// 一次面板操作 = 一条命令（照 [ _SetItemStyles] 的结构：按 id 寻址、纯值）。
class _SetItemColorSlots extends CanvasCommand {
  const _SetItemColorSlots(this.entries);

  final List<_ItemColorSlot> entries;

  @override
  Iterable<String> get retainedIds => <String>[
    for (final _ItemColorSlot e in entries) e.id,
  ];

  @override
  void undo(CanvasDocument document) {
    for (final _ItemColorSlot e in entries) {
      document._items[e.id]?.colorSlot = e.oldSlot;
    }
  }

  @override
  void redo(CanvasDocument document) {
    for (final _ItemColorSlot e in entries) {
      document._items[e.id]?.colorSlot = e.newSlot;
    }
  }
}

/// 一条 item 的"分组归属"改动（[CanvasItem.groupId] 为 null = 不属于任何组）。
class _ItemGroupId {
  const _ItemGroupId(this.id, this.oldGroupId, this.newGroupId);

  final String id;
  final String? oldGroupId;
  final String? newGroupId;
}

/// 一次分组 / 解散 = 一条命令（照 [_SetItemColorSlots] 的结构：按 id 寻址、纯值）。
///
/// ⚠️ 删掉的分组框是**另一条**命令（`_RemoveItems`）的事：解散分组 = 清成员归属
/// ＋ 删框，两者必须在**同一个 batch** 里（见 `CanvasDocument.batch`），否则用户
/// 会看到"框没了但成员还认为自己在组里"的中间态。
class _SetItemGroupIds extends CanvasCommand {
  const _SetItemGroupIds(this.entries);

  final List<_ItemGroupId> entries;

  @override
  Iterable<String> get retainedIds => <String>[
    for (final _ItemGroupId e in entries) e.id,
  ];

  @override
  void undo(CanvasDocument document) {
    for (final _ItemGroupId e in entries) {
      document._items[e.id]?.groupId = e.oldGroupId;
    }
  }

  @override
  void redo(CanvasDocument document) {
    for (final _ItemGroupId e in entries) {
      document._items[e.id]?.groupId = e.newGroupId;
    }
  }
}

class _ItemStyle {
  const _ItemStyle(this.id, this.oldStyle, this.newStyle);

  /// 目标节点 id（稳定引用，同 [_ItemTransform]）。
  final String id;
  final ShapeStyle oldStyle;
  final ShapeStyle newStyle;
}
