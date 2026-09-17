import 'package:flutter/widgets.dart';

import 'canvas_item.dart';
import 'canvas_media.dart';
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
/// 还原 z 序）。[toJson] 输出 schemaVersion=2；[fromJson] 兼容 v1 列表格式存档。
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

  /// z 序（底→顶）。绘制/命中/序列化均按此遍历；与 Map 配合保证稳定寻址下
  /// 仍能精确还原 z 序（撤销插入回原位）。
  final List<String> _strokeOrder = <String>[];
  final List<String> _itemOrder = <String>[];

  final List<CanvasCommand> _undoStack = <CanvasCommand>[];
  final List<CanvasCommand> _redoStack = <CanvasCommand>[];

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

  /// 内容版本号：任何增删改（含撤销/重做）都 +1。
  ///
  /// 存在意义是**缓存失效**：笔迹合成的 `ui.Picture` 只在版本号变化时重录
  /// （见 `CanvasController.committedPicture`）。用版本号而不是"比较列表
  /// 内容"，才能把撤销/重做这类"内容变了但条数可能没变"的情况也覆盖。
  int revision = 0;

  /// 笔迹集合（按 z 序）；仅供渲染/序列化读取，写入走 [addStroke]/[removeStrokes]。
  List<InkStroke> get strokes =>
      <InkStroke>[for (final String id in _strokeOrder) _strokes[id]!];

  /// item 集合（按 z 序，**列表顺序即 z 序**，后加的在上）。绘制在笔迹**下方**
  /// （OneNote 口径：墨迹批注在图片上），但**命中优先于笔迹**——框选工具
  /// 下点到的"能整体拖走的对象"优先响应。
  List<CanvasItem> get items =>
      <CanvasItem>[for (final String id in _itemOrder) _items[id]!];

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
      result = result == null ? item.bounds : result.expandToInclude(item.bounds);
    }
    return result;
  }

  /// 与 [worldViewport] 相交的笔迹（绘制与命中测试的输入）。
  List<InkStroke> strokesIn(Rect worldViewport) => <InkStroke>[
        for (final String id in _strokeOrder)
          if (_strokes[id]!.bounds?.overlaps(worldViewport) ?? false)
            _strokes[id]!,
      ];

  /// 按 id 稳定查表（生成器做 img2img 时按 [GenRecipe.inputs] 找引用节点）。
  CanvasItem? itemById(String id) => _items[id];

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
    // hit 本身即升序索引，撤销时按升序插回原位。
    _push(_RemoveItems(hit));
    revision++;
    // 返回顺序与旧实现一致：按索引升序。
    return removed.reversed.toList(growable: false);
  }

  /// 拖动/缩放/旋转**结束**后的落账：[changes] 为 (item, 改动前 rect, 改动前
  /// angle) 三元组，item 的 rect/angle 此时已是新值。一次手势合并成一条命令。
  ///
  /// 命令内部改为**按 id 寻址**（[ _ItemTransform.id]），撤销/重做时回查节点——
  /// 不再持有实例引用，从而可序列化、可重放。
  void setItemTransforms(
    List<(CanvasItem, Rect, double)> changes,
  ) {
    final List<_ItemTransform> entries = <_ItemTransform>[
      for (final (CanvasItem item, Rect oldRect, double oldAngle) in changes)
        if (item.rect != oldRect || item.angle != oldAngle)
          _ItemTransform(
            item.id,
            oldRect,
            oldAngle,
            item.rect,
            item.angle,
          ),
    ];
    if (entries.isEmpty) return;
    _push(_SetItemTransforms(entries));
    revision++;
  }

  void addStroke(InkStroke stroke) {
    _strokes[stroke.id] = stroke;
    _strokeOrder.add(stroke.id);
    _push(_AddStroke(stroke.id));
    revision++;
  }

  /// 橡皮（OneNote「笔画橡皮」口径：命中即整条删除）。返回被删掉的笔迹。
  List<InkStroke> eraseAt(Offset world, double radius) => removeStrokes(
        <InkStroke>[
          for (final String id in _strokeOrder)
            if (_strokes[id]!.hitTest(world, radius)) _strokes[id]!,
        ],
      );

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

  void _push(CanvasCommand command) {
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
    _detachedItems.removeWhere((String id, CanvasItem value) => !live.contains(id));
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
        'schemaVersion': 2,
        'strokes': <String, dynamic>{
          for (final String id in _strokeOrder) id: _strokes[id]!.toJson(),
        },
        'items': <String, dynamic>{
          for (final String id in _itemOrder) id: _items[id]!.toJson(media: media),
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

  /// 反序列化：兼容 v1（双 List）与 v2（id-keyed map）两种存档格式；
  /// 载入即权威状态，不产生撤销命令。
  ///
  /// [media] 用于把侧表里的**相对引用**换算回运行时绝对路径；旧存档若存的是
  /// 绝对路径，解析器原样通过，因此无需迁移。
  static CanvasDocument fromJson(
    Map<String, dynamic> j, {
    MediaResolver? media,
  }) {
    final CanvasDocument doc = CanvasDocument();
    final dynamic strokesRaw = j['strokes'];
    final dynamic itemsRaw = j['items'];

    if (strokesRaw is List) {
      // ── v1：双 List 格式，按列表顺序推导 z 序 ──
      for (final dynamic s in strokesRaw) {
        final InkStroke st = InkStroke.fromJson(s as Map<String, dynamic>);
        doc._strokes[st.id] = st;
        doc._strokeOrder.add(st.id);
      }
      for (final dynamic i in (itemsRaw as List)) {
        final CanvasItem it =
            CanvasItem.fromJson(i as Map<String, dynamic>, media: media);
        doc._items[it.id] = it;
        doc._itemOrder.add(it.id);
      }
    } else {
      // ── v2：id-keyed map + 显式 z 序 ──
      (strokesRaw as Map<Object?, Object?>).forEach((Object? k, Object? v) {
        final InkStroke st = InkStroke.fromJson(v as Map<String, dynamic>);
        doc._strokes[st.id] = st;
      });
      (itemsRaw as Map<Object?, Object?>).forEach((Object? k, Object? v) {
        final CanvasItem it =
            CanvasItem.fromJson(v as Map<String, dynamic>, media: media);
        doc._items[it.id] = it;
      });
      doc._strokeOrder
          .addAll((j['strokeOrder'] as List<dynamic>).cast<String>());
      doc._itemOrder.addAll((j['itemOrder'] as List<dynamic>).cast<String>());
    }
    // ⚠️ 载入即**把 id 发生器推到已有 id 之后**：存档里的 id 来自之前的进程，
    // 而计数器每次启动都从 0 开始 —— 不推进的话，新建元素会拿到与存档重复的
    // id，`addItem` 的覆盖语义会让旧元素凭空消失（2026-09-17 修，见
    // `advanceItemIdSequence` 的说明）。
    advanceItemIdSequence(doc._items.keys);
    return doc;
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
  Iterable<String> get retainedIds =>
      <String>[for (final _IndexedStroke e in entries) e.id];

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
  const _RemoveItems(this.entries);

  /// 按**索引升序**，撤销时依次插回原位（z 序一并还原）。
  final List<_IndexedItem> entries;

  @override
  Iterable<String> get retainedIds =>
      <String>[for (final _IndexedItem e in entries) e.id];

  @override
  void undo(CanvasDocument document) {
    for (final _IndexedItem e in entries) {
      if (document._reattachItem(e.id) == null) continue;
      document._itemOrder.insert(e.index, e.id);
    }
  }

  @override
  void redo(CanvasDocument document) {
    for (final _IndexedItem e in entries.reversed) {
      document._itemOrder.removeAt(e.index);
      document._detachItem(e.id);
    }
  }
}

class _IndexedItem {
  const _IndexedItem(this.index, this.id);

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
