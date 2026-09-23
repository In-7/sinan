import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'block_props.dart';
import 'fingerprint.dart';
import 'json_deep_eq.dart';

/// 画布落点的**存储层**（表结构见 `docs/canvas_architecture.md` 第七章）。
///
/// ## 现在处在五步纪律的第 1 步（双写）
/// 写 `notes.content` 的同时把这些行也写一份；**读路径仍然是 JSON**
/// （`canvas_note_view.dart` 走 `CanvasController.fromJson`）。第 3 步的校验
/// （`verifyCanvasRows`）与第 4 步的切读尚未实现——按纪律，要等双写在真实数据上跑稳。
///
/// ## 与 [BlockStore] 的关系：刻意另起一套
/// 两者都是"JSON ⇄ 表"的投影，但列的含义不同名不同义：`blocks.ord` 是**阅读顺序**、
/// `canvas_items.z` 是 **z 序**；`blocks.parent_id` 是层级，画布没有这一维。共用同一套
/// 函数会让"一列两义"（正是决定不让画布进 `blocks` 的原因），所以这里只共用**约定**：
/// 稳定 id、`note_id` 级联、`fingerprint` 判变、`*_json` 扩展位。
///
/// ## 本层只认 JSON，不认内核类
/// 入参与 [BlockStore] 一样是**序列化字符串**（`CanvasController.toJson` 的输出）：
/// 于是 `data/` 不依赖画布内核，内核也不必知道表结构。格式的唯一权威仍是内核的
/// `toJson/fromJson`，表只是它的另一种物理布局。
class CanvasStore {
  CanvasStore(this.db);

  final Database db;

  /// 一片笔迹装多少笔（`docs/data_layer.md` 第五节：256~512）。
  ///
  /// 第 1 步先用**固定分片**：真正的增量粒度（"只重写最后变动的那片"）等切读跑通、
  /// 分片策略稳定后再谈——分片边界一旦改，所有 blob 都要重排。
  static const int strokesPerShard = 256;

  /// 画布卡片在 `blocks` 里的 `type` 值（与 `canvas_items.kind = 'card'` 对应）。
  static const String _cardType = 'card';

  /// 把一张画布**整体同步**进三张表；返回真正写到的行数（0 = 没变化 / 不是画布内容）。
  ///
  /// 与 `BlockStore.replaceNoteBlocks` 同语义：**先算差量再落笔**，没变就一行都不写
  /// ——自动保存每次防抖都会调到这里，不能产生无谓的写放大。
  ///
  /// 非画布内容（v2 块树 / Delta / 空串）一律返回 0：与 `replaceNoteBlocks` 的
  /// 格式门闩对称，于是 `NoteStore` 可以两条投影都无脑调用。
  int replaceCanvasRows(String noteId, String content) {
    final Map<String, dynamic>? json = _parseCanvasDocument(content);
    if (json == null) return 0;

    final Map<String, dynamic> document = (json['document'] as Map)
        .cast<String, dynamic>();
    final int schemaVersion = (document['schemaVersion'] as num?)?.toInt() ?? 1;
    final String cameraJson = jsonEncode(
      (json['camera'] as Map).cast<String, dynamic>(),
    );

    final List<_ItemRow> items = _itemRows(document);
    final Map<int, _ShardRow> shards = _shardRows(document);
    final Map<String, dynamic> itemMap = document['items'] is Map
        ? (document['items'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    // 把「item 规范化后长什么样」也算进 meta 指纹：否则几何/样式变了但相机没变时
    // 会漏写——这里不做增量比较，交给 items 各自的 fingerprint 判定，meta 只看
    // 相机 + 画布格式版本 + item 集合的形状（见 [_metaFingerprint]）。
    final String metaFingerprint = _metaFingerprint(
      cameraJson,
      schemaVersion,
      itemMap.keys.toList(),
    );

    final int now = DateTime.now().millisecondsSinceEpoch;
    final Map<String, _ExistingItem> oldItems = _existingItems(noteId);
    final Set<String> keep = <String>{for (final _ItemRow r in items) r.id};
    final List<String> removedItems = <String>[
      for (final String id in oldItems.keys)
        if (!keep.contains(id)) id,
    ];
    final List<_ItemRow> changedItems = <_ItemRow>[
      for (final _ItemRow row in items)
        if (oldItems[row.id]?.fingerprint != row.fingerprint) row,
    ];
    final Map<int, _ExistingShard> oldShards = _existingShards(noteId);
    final List<_ShardRow> changedShards = <_ShardRow>[
      for (final MapEntry<int, _ShardRow> e in shards.entries)
        if (oldShards[e.key]?.fingerprint != e.value.fingerprint) e.value,
    ];
    final List<int> removedShards = <int>[
      for (final int i in oldShards.keys)
        if (!shards.containsKey(i)) i,
    ];
    // 首次落行时 `rag_meta` 里没有指纹 ⇒ `_metaChanged` 返回 true，天然覆盖"新建"。
    final List<_EdgeRow> edges = _edgeRows(document);
    final Map<String, _ExistingEdge> oldEdges = _existingEdges(noteId);
    final Set<String> keepEdges = <String>{
      for (final _EdgeRow r in edges) r.id,
    };
    final List<String> removedEdgeIds = <String>[
      for (final String id in oldEdges.keys)
        if (!keepEdges.contains(id)) id,
    ];
    final List<_EdgeRow> changedEdges = <_EdgeRow>[
      for (final _EdgeRow row in edges)
        if (oldEdges[row.id]?.fingerprint != row.fingerprint) row,
    ];

    final bool metaChanged = _metaChanged(noteId, metaFingerprint);

    if (removedItems.isEmpty &&
        changedItems.isEmpty &&
        removedEdgeIds.isEmpty &&
        changedEdges.isEmpty &&
        removedShards.isEmpty &&
        changedShards.isEmpty &&
        !metaChanged) {
      return 0;
    }

    int cardsWritten = 0;
    int edgesWritten = 0;
    db.execute('BEGIN;');
    try {
      for (final String id in removedItems) {
        db.execute(
          'DELETE FROM canvas_items WHERE note_id = ? AND id = ?',
          <Object?>[noteId, id],
        );
      }
      // ⚠️ 卡片**内容必须先于几何**写：`canvas_items.block_id` 外键到
      //    `blocks(id)`，先插几何会因"指向一个尚不存在的块"而违反外键（v9 实测）。
      //    删卡片时顺序天然正确（几何行先被 removedItems 删掉，blocks 才失去引用）。
      cardsWritten = _replaceCardBlocks(noteId, items);

      for (final _ItemRow row in changedItems) {
        db.execute(
          'INSERT INTO canvas_items (id, note_id, kind, z, x1, y1, x2, y2, '
          'angle, color, filled, stroke_width, src, block_id, props_json, '
          'created_at, updated_at, fingerprint) '
          'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
          // ⚠️ 冲突目标必须是 **(note_id, id)**：item id 是内核的进程内自增计数器
          // （`item-1`…），两张画布同时存在同一个 id 是常态（见 database.dart 的
          // `_canvasItemsDdl`）。写成单列 id 会让后写的那张把前一行的 note_id 抢走。
          'ON CONFLICT(note_id, id) DO UPDATE SET '
          'kind=excluded.kind, z=excluded.z, x1=excluded.x1, y1=excluded.y1, '
          'x2=excluded.x2, y2=excluded.y2, angle=excluded.angle, '
          'color=excluded.color, filled=excluded.filled, '
          'stroke_width=excluded.stroke_width, src=excluded.src, '
          'block_id=excluded.block_id, '
          'props_json=excluded.props_json, updated_at=excluded.updated_at, '
          'fingerprint=excluded.fingerprint',
          <Object?>[
            row.id,
            noteId,
            row.kind,
            row.z,
            row.rect[0],
            row.rect[1],
            row.rect[2],
            row.rect[3],
            row.angle,
            row.color,
            row.filled,
            row.strokeWidth,
            row.src,
            row.blockId,
            row.propsJson,
            // created_at 只在**首次**落行时写：更新不该动它（否则"只改一块"
            // 的语义就没了 —— 与 blocks 的判变口径一致）。
            oldItems[row.id]?.createdAt ?? now,
            now,
            row.fingerprint,
          ],
        );
      }
      // 自由连线（v9）。⚠️ 必须在**卡片内容之后**写：`from_id` / `to_id` 外键到
      // `blocks(id)`，先写边会因"指向尚不存在的块"而违反外键。
      for (final String id in removedEdgeIds) {
        db.execute(
          'DELETE FROM canvas_edges WHERE note_id = ? AND id = ?',
          <Object?>[noteId, id],
        );
      }
      for (final _EdgeRow row in changedEdges) {
        db.execute(
          'INSERT INTO canvas_edges (id, note_id, from_id, to_id, from_side, '
          'to_side, props_json, fingerprint) VALUES (?,?,?,?,?,?,?,?) '
          'ON CONFLICT(note_id, id) DO UPDATE SET from_id=excluded.from_id, '
          'to_id=excluded.to_id, from_side=excluded.from_side, '
          'to_side=excluded.to_side, props_json=excluded.props_json, '
          'fingerprint=excluded.fingerprint',
          <Object?>[
            row.id,
            noteId,
            row.fromId,
            row.toId,
            row.fromSide,
            row.toSide,
            row.propsJson,
            row.fingerprint,
          ],
        );
      }
      edgesWritten = removedEdgeIds.length + changedEdges.length;

      for (final int index in removedShards) {
        db.execute(
          'DELETE FROM ink_shards WHERE note_id = ? AND shard_index = ?',
          <Object?>[noteId, index],
        );
      }
      for (final _ShardRow row in changedShards) {
        db.execute(
          'INSERT INTO ink_shards (note_id, shard_index, points_blob, '
          'style_json, count, fingerprint, updated_at) VALUES (?,?,?,?,?,?,?) '
          'ON CONFLICT(note_id, shard_index) DO UPDATE SET '
          'points_blob=excluded.points_blob, style_json=excluded.style_json, '
          'count=excluded.count, fingerprint=excluded.fingerprint, '
          'updated_at=excluded.updated_at',
          <Object?>[
            noteId,
            row.shardIndex,
            row.points,
            row.styleJson,
            row.count,
            row.fingerprint,
            now,
          ],
        );
      }
      db.execute(
        'INSERT INTO canvas_meta (note_id, camera_json, schema_version, '
        'updated_at) VALUES (?,?,?,?) ON CONFLICT(note_id) DO UPDATE SET '
        'camera_json=excluded.camera_json, '
        'schema_version=excluded.schema_version, updated_at=excluded.updated_at',
        <Object?>[noteId, cameraJson, schemaVersion, now],
      );
      db.execute(
        'INSERT INTO rag_meta (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
        <Object?>['canvas.meta.fp.$noteId', metaFingerprint],
      );
      db.execute('COMMIT;');
    } on Object {
      db.execute('ROLLBACK;');
      rethrow;
    }

    return removedItems.length +
        changedItems.length +
        cardsWritten +
        edgesWritten +
        removedShards.length +
        changedShards.length +
        (metaChanged ? 1 : 0);
  }

  /// **回填**（五步纪律第 2 步）：把「正文已是画布 JSON、却还没有画布行」的存量画布
  /// 补进三张表。与 `BlockStore.backfill` 同口径：分批（[limit] 封顶）、幂等、可续跑，
  /// 且**只写不读**（读路径仍是 JSON）。
  ///
  /// 返回**成功投影的**篇数；非画布内容会被跳过且**不计数**（与 blocks 侧一致）。
  ///
  /// ⚠️ 候选里刻意排掉 `content = ''`：**空白新画布是常态**（刚建、还没画过），它不是
  /// "待回填"，不该每次启动都占 [limit] 名额——这正是 blocks 侧 `kind != 'canvas'`
  /// 修掉的同一类问题（见 `BlockStore.backfill` 的注释）。
  int backfill({int limit = 50}) {
    final ResultSet rs = db.select(
      // 候选 = 画布笔记、正文非空、且还没有 meta 行（meta 行是"已落表"的标记）。
      "SELECT id, content FROM notes WHERE kind = 'canvas' AND content <> '' "
      'AND NOT EXISTS (SELECT 1 FROM canvas_meta WHERE note_id = notes.id) '
      'LIMIT ?',
      <Object?>[limit],
    );
    int done = 0;
    for (final Row row in rs) {
      if (replaceCanvasRows(row['id'] as String, row['content'] as String) >
          0) {
        done++;
      }
    }
    return done;
  }

  /// 这篇笔记当前有没有画布行（第 2 步回填、第 3 步校验的判据）。
  bool hasRows(String noteId) => db.select(
    'SELECT 1 FROM canvas_meta WHERE note_id = ? LIMIT 1',
    <Object?>[noteId],
  ).isNotEmpty;

  // ── 第 3 步：校验（行 → JSON，与原文深比较）───────────────────────

  /// **校验**（五步纪律第 3 步）：把三张表的行组装回 `toJson` 结构，与
  /// `notes.content` 里的原文做**结构深比较**。
  ///
  /// 与 `BlockStore.verifyNoteBlocks` 同口径：不做字节比较（键顺序无语义），
  /// 但**列表顺序有语义**（`itemOrder` / `strokeOrder` / 点列都是数组）。
  ///
  /// 返回 false 的常见情形：content 不是画布 JSON、还没回填（没有 meta 行）、
  /// 或者两边真的不一致——第 4 步切读**必须**能拦住最后这一种。
  bool verifyCanvasRows(String noteId, String content) =>
      readVerifiedCanvas(noteId, content) != null;

  /// 「校验 + 取回」一次做完（第 4 步切读用它，避免读两遍）。
  ///
  /// 校验通过则返回**从行还原出的**画布 JSON；否则返回 null，调用方回退旧列。
  ///
  /// ⚠️ 还原结果**不含 `media` 侧表**：它是派生索引（真源是各 item 的 `src`），
  /// 刻意不落库、载入时按需重建（架构文档第七章），因此不参与比较。
  String? readVerifiedCanvas(String noteId, String content) {
    final Map<String, dynamic>? original = _parseCanvasDocument(content);
    if (original == null) return null;

    final _MetaRow? meta = _readMeta(noteId);
    if (meta == null) return null; // 还没回填

    final Object? camera;
    try {
      camera = jsonDecode(meta.cameraJson);
    } on FormatException {
      return null;
    }
    if (camera is! Map<String, dynamic>) return null;

    final List<_ItemRowRead> items = _readItems(noteId);
    final List<String> strokeOrder = <String>[];
    final Map<String, dynamic> strokes = <String, dynamic>{};
    for (final _ShardRowRead shard in _readShards(noteId)) {
      for (final Map<String, dynamic> s in _decodeShard(shard)) {
        final String id = s['id'] as String;
        strokes[id] = s;
        strokeOrder.add(id);
      }
    }

    // 卡片的**内容**在 blocks（另一半），还原时取回来拼上。
    final Map<String, String> cardTexts = _cardTexts(noteId);
    final Map<String, dynamic> itemMap = <String, dynamic>{};
    for (final _ItemRowRead row in items) {
      final Map<String, dynamic>? json = _itemJsonOf(
        row,
        cardTexts[row.blockId] ?? '',
      );
      if (json != null) itemMap[row.id] = json;
    }

    final Map<String, dynamic> edgeMap = <String, dynamic>{
      for (final _EdgeRowRead r in _readEdges(noteId)) r.id: r.toJson(),
    };
    final Map<String, dynamic> rebuilt = <String, dynamic>{
      'camera': camera,
      'document': <String, dynamic>{
        'schemaVersion': meta.schemaVersion,
        'strokes': strokes,
        'items': itemMap,
        // ⚠️ 与内核 `toJson` **同口径：为空则不写这个键**。旧存档本来没有它，
        // 若无条件写空 map，深比较会把"原文无 edges / 还原有 edges {}"判成
        // 不一致 ⇒ 所有老画布静默回退 JSON。
        if (edgeMap.isNotEmpty) 'edges': edgeMap,
        'strokeOrder': strokeOrder,
        'itemOrder': <String>[for (final _ItemRowRead r in items) r.id],
      },
    };

    return jsonDeepEquals(_normalize(rebuilt), _normalize(original))
        ? jsonEncode(rebuilt)
        : null;
  }

  _MetaRow? _readMeta(String noteId) {
    final ResultSet rs = db.select(
      'SELECT camera_json, schema_version FROM canvas_meta WHERE note_id = ?',
      <Object?>[noteId],
    );
    if (rs.isEmpty) return null;
    return _MetaRow(
      cameraJson: rs.single['camera_json'] as String,
      schemaVersion: (rs.single['schema_version'] as num).toInt(),
    );
  }

  /// item 行按 **z 升序**读出（z 就是 `itemOrder` 的下标）。
  List<_ItemRowRead> _readItems(String noteId) => <_ItemRowRead>[
    for (final Row r in db.select(
      'SELECT id, kind, z, x1, y1, x2, y2, angle, color, filled, '
      'stroke_width, src, block_id, props_json FROM canvas_items '
      'WHERE note_id = ? ORDER BY z',
      <Object?>[noteId],
    ))
      _ItemRowRead(
        id: r['id'] as String,
        kind: r['kind'] as String,
        rect: <double>[
          (r['x1'] as num).toDouble(),
          (r['y1'] as num).toDouble(),
          (r['x2'] as num).toDouble(),
          (r['y2'] as num).toDouble(),
        ],
        angle: (r['angle'] as num).toDouble(),
        color: (r['color'] as num?)?.toInt(),
        filled: (r['filled'] as num?)?.toInt(),
        strokeWidth: (r['stroke_width'] as num?)?.toDouble(),
        src: r['src'] as String?,
        blockId: r['block_id'] as String?,
        propsJson: r['props_json'] as String,
      ),
  ];

  List<_ShardRowRead> _readShards(String noteId) => <_ShardRowRead>[
    for (final Row r in db.select(
      'SELECT shard_index, points_blob, style_json FROM ink_shards '
      'WHERE note_id = ? ORDER BY shard_index',
      <Object?>[noteId],
    ))
      _ShardRowRead(
        shardIndex: r['shard_index'] as int,
        points: r['points_blob'] as Uint8List,
        styleJson: r['style_json'] as String,
      ),
  ];

  /// 画布里各卡片的文本（`block_id` → text），供还原卡片 JSON 用。
  ///
  /// 卡片是"内容在 blocks、几何在 canvas_items"的**分裂存储**，还原时必须把两半
  /// 拼回来——否则还原出的画布里每张卡片都是空的。
  ///
  /// ⚠️ 按 **`block_id` 关联**取，**不是**按 `blocks.note_id` 过滤：块可迁移 #5
  /// 的「双链多视图」下，卡片引用的块**可以属于别的笔记**（文档里的一个段落被
  /// 引用到画布上，真身仍留在文档）。按 `note_id` 过滤会让这类卡片还原成空文本。
  Map<String, String> _cardTexts(String noteId) => <String, String>{
    for (final Row r in db.select(
      'SELECT b.id AS id, b.props_json AS props_json FROM blocks b '
      'JOIN canvas_items i ON i.block_id = b.id '
      'WHERE i.note_id = ? AND i.kind = ?',
      <Object?>[noteId, _cardType],
    ))
      r['id'] as String: textOfProps(r['props_json'] as String?),
  };

  /// 一个分片 → 若干笔的完整 JSON。
  ///
  /// blob 是**连续**的 Float32 三元组，每笔的点数记在
  /// `style_json.strokes[i].points` ⇒ 必须按它切片，否则点会在笔之间串位。
  static List<Map<String, dynamic>> _decodeShard(_ShardRowRead shard) {
    final Map<String, dynamic> style = (jsonDecode(shard.styleJson) as Map)
        .cast<String, dynamic>();
    final List<Object?> metas =
        (style['strokes'] as List?) ?? const <Object?>[];
    final Float32List floats = Float32List.view(
      shard.points.buffer,
      shard.points.offsetInBytes,
      shard.points.lengthInBytes ~/ 4,
    );
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    int i = 0;
    for (final Object? raw in metas) {
      if (raw is! Map) continue;
      final Map<String, dynamic> meta = raw.cast<String, dynamic>();
      final int n = (meta['points'] as num?)?.toInt() ?? 0;
      final List<List<double>> points = <List<double>>[];
      for (int k = 0; k < n && i + 2 < floats.length; k++) {
        points.add(<double>[floats[i], floats[i + 1], floats[i + 2]]);
        i += 3;
      }
      out.add(<String, dynamic>{
        'id': meta['id'],
        'version': meta['version'],
        'color': meta['color'],
        'baseWidth': meta['baseWidth'],
        'simulatePressure': meta['simulatePressure'],
        'points': points,
      });
    }
    return out;
  }

  /// item 行 → item JSON。各子类字段不同，**不多写也不少写**：多一个键或
  /// 少一个键都会让深比较失败（对照 `ShapeItem.toJson` 等）。
  static Map<String, dynamic>? _itemJsonOf(_ItemRowRead row, String cardText) {
    final Map<String, dynamic> props = (jsonDecode(row.propsJson) as Map)
        .cast<String, dynamic>();
    switch (row.kind) {
      case 'card':
        // 内容是**另一半**（在 blocks），由 [readVerifiedCanvas] 取回后传进来。
        // 少了这一步，还原出的画布里每张卡片都是空的 —— 而校验仍会"通过"，
        // 因为两边都空（那正是最难发现的失败：静默丢内容）。
        return <String, dynamic>{
          'type': 'card',
          'id': row.id,
          'blockId': row.blockId,
          'text': cardText,
          'angle': row.angle,
          'rect': row.rect,
          if (props['colorSlot'] != null) 'colorSlot': props['colorSlot'],
          if (props['groupId'] != null) 'groupId': props['groupId'],
          'meta': props['meta'] ?? const <String, dynamic>{},
        };
      case 'shape.rectangle':
      case 'shape.ellipse':
        return <String, dynamic>{
          'type': 'shape',
          'id': row.id,
          'kind': row.kind.substring('shape.'.length),
          'color': row.color,
          'strokeWidth': row.strokeWidth,
          'filled': row.filled == 1,
          'angle': row.angle,
          'rect': row.rect,
          if (props['groupId'] != null) 'groupId': props['groupId'],
          // 原 JSON 里 `meta` 总是写（可能为空 {}），而落库时**空 meta 不进
          // props_json** ⇒ 这里补回 {}，否则"没设过 meta 的形状"永远校验失败。
          'meta': props['meta'] ?? const <String, dynamic>{},
        };
      case 'image':
        return <String, dynamic>{
          'type': 'image',
          'id': row.id,
          'angle': row.angle,
          'rect': row.rect,
          'src': row.src,
          if (props['groupId'] != null) 'groupId': props['groupId'],
          'meta': props['meta'] ?? const <String, dynamic>{},
        };
      case 'ai_image':
        return <String, dynamic>{
          'type': 'aiImage',
          'id': row.id,
          'angle': row.angle,
          'rect': row.rect,
          'src': row.src,
          'gen': props['gen'],
          if (props['groupId'] != null) 'groupId': props['groupId'],
          'meta': props['meta'] ?? const <String, dynamic>{},
        };
      case 'mindmap':
        return <String, dynamic>{
          'type': 'mindmap',
          'id': row.id,
          'angle': row.angle,
          'rect': row.rect,
          'nodes': props['nodes'],
          if (props['colorSlot'] != null) 'colorSlot': props['colorSlot'],
          if (props['groupId'] != null) 'groupId': props['groupId'],
          'meta': props['meta'] ?? const <String, dynamic>{},
        };
      case 'group':
        // 分组框（2026-09-18）：容器型 item。标题 / 槽位 / 所属组都是扩展位，
        // 与内核 `CanvasGroupItem.toJson` 逐项对齐（空值不写键）。
        return <String, dynamic>{
          'type': 'group',
          'id': row.id,
          'angle': row.angle,
          'rect': row.rect,
          if (props['label'] != null) 'label': props['label'],
          if (props['colorSlot'] != null) 'colorSlot': props['colorSlot'],
          if (props['groupId'] != null) 'groupId': props['groupId'],
          'meta': props['meta'] ?? const <String, dynamic>{},
        };
      default:
        return null;
    }
  }

  /// 比较前的**归一化**（与 `BlockStore._normalize` 同职责，规则各自不同）。
  ///
  /// 两件事，都是"不这么做就永远比不上"：
  /// 1. **剔除 `media`**：派生侧表、刻意不落库 ⇒ 还原侧根本没有它；
  /// 2. **`points` 按 Float32 量化**：blob 存 Float32 而原文是 double
  ///    （如 `1.1` 存进去读回是 `1.100000023841858`）⇒ 不量化则所有带笔迹
  ///    的画布都校验失败。
  ///
  /// ⚠️ `rect` / `angle` / `strokeWidth` 存在 REAL 列（SQLite REAL = double）
  /// ⇒ **没有**精度损失，不需要量化。
  static Object? _normalize(Object? node) {
    if (node is List) {
      return <Object?>[for (final Object? c in node) _normalize(c)];
    }
    if (node is! Map) return node;
    return <Object?, Object?>{
      for (final MapEntry<Object?, Object?> e in node.entries)
        if (e.key != 'media')
          e.key: e.key == 'points'
              ? _quantizePoints(e.value)
              : _normalize(e.value),
    };
  }

  /// 点列（三元组数组）按 Float32 往返一次，与 blob 同精度。
  static Object? _quantizePoints(Object? raw) {
    if (raw is! List) return _normalize(raw);
    final Float32List buf = Float32List(1);
    return <Object?>[
      for (final Object? triple in raw)
        if (triple is List)
          <Object?>[for (final Object? v in triple) _quantize(v, buf)]
        else
          triple,
    ];
  }

  /// 单个数按 Float32 往返一次；非数值原样返回。
  static Object? _quantize(Object? v, Float32List buf) {
    if (v is! num) return v;
    buf[0] = v.toDouble();
    return buf[0];
  }

  // ── 解析与投影 ────────────────────────────────────────────────────

  /// 画布 JSON 的格式门闩：顶层是 `{camera, document}`，且 document 里带
  /// `strokes` / `items`。**不是画布内容就返回 null**（v2 块树、Delta、空串都在这里
  /// 被挡掉），于是它可以像 `replaceNoteBlocks` 一样被无脑调用。
  static Map<String, dynamic>? _parseCanvasDocument(String content) {
    if (content.trim().isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final Object? camera = decoded['camera'];
    final Object? document = decoded['document'];
    if (camera is! Map || document is! Map) return null;
    if (document['strokes'] is! Map && document['items'] is! Map) return null;
    return decoded;
  }

  static List<_ItemRow> _itemRows(Map<String, dynamic> document) {
    final Object? itemsRaw = document['items'];
    if (itemsRaw is! Map) return const <_ItemRow>[];
    final Map<String, dynamic> items = itemsRaw.cast<String, dynamic>();
    final List<Object?> order =
        (document['itemOrder'] as List?) ?? const <Object?>[];
    // z 序 = `itemOrder` 的下标；不在 order 里的（异常存档）按 Map 顺序排到末尾。
    final Set<String> inOrder = <String>{
      for (final Object? id in order)
        if (id is String && items.containsKey(id)) id,
    };
    final List<String> ids = <String>[
      for (final Object? id in order)
        if (inOrder.contains(id)) id as String,
      for (final String id in items.keys)
        if (!inOrder.contains(id)) id,
    ];
    return <_ItemRow>[
      for (int i = 0; i < ids.length; i++)
        if (_itemRowOf(ids[i], items[ids[i]], i) case final _ItemRow row) row,
    ];
  }

  /// 一行 item：几何用 rect 的**四条边**（不做 `w = r - l` 的换算，避免浮点往返误差，
  /// 第 3 步要拿它和原文深比较）；`kind` 把内核对 `type` + 形状 `kind` 两级判别拍平成一列。
  static _ItemRow? _itemRowOf(String id, Object? raw, int z) {
    if (raw is! Map) return null;
    final Map<String, dynamic> item = raw.cast<String, dynamic>();
    final Object? rectRaw = item['rect'];
    if (rectRaw is! List || rectRaw.length < 4) return null;
    final List<double> rect = <double>[
      for (final Object? v in rectRaw.take(4)) (v as num).toDouble(),
    ];
    final String type = item['type'] as String? ?? 'shape';
    final String? shapeKind = item['kind'] as String?;
    final String kind = switch (type) {
      'shape' => 'shape.${shapeKind ?? 'rectangle'}',
      'aiImage' => 'ai_image',
      'card' => 'card',
      _ => type, // 'image'
    };
    // 扩展位只装**非空**的 meta / gen：空对象会让"行 ⇄ 原文"的深比较更容易失配。
    //
    // ⚠️ card 的**文本刻意不进 props_json**：它属于"内容"，落 `blocks`
    // （见 [_replaceCardBlocks]）。理由是有可索引文本 ⇒ 必须能被 FTS5 / 向量
    // 检索到，而这两者都建在 blocks 上。文本因此只有**一份**真相源，
    // 还原时再从 blocks 取回来（见 [_itemJsonOf]）。
    final Map<String, dynamic> props = <String, dynamic>{
      if ((item['meta'] as Map?)?.isNotEmpty ?? false) 'meta': item['meta'],
      if (item['gen'] != null) 'gen': item['gen'],
      // 思维导图的节点树自包含存在扩展位（本轮先自包含，投影到 blocks 留待下一步）。
      if (item['nodes'] != null) 'nodes': item['nodes'],
      // 语义色槽位（卡片/思维导图/分组框）。**只在有值时写**：老存档没这个键，
      // 写了会让"行 ⇄ 原文"深比较失配 ⇒ 老画布静默回退 JSON。
      if (item['colorSlot'] != null) 'colorSlot': item['colorSlot'],
      // 分组框标题（非空才写，与内核 `CanvasGroupItem.toJson` 同口径）。
      if ((item['label'] as String?)?.isNotEmpty ?? false)
        'label': item['label'],
      // 成员指向分组框的 id（分组框自身恒为 null，不写）：落 `props_json` 扩展位，
      // 不占独立列（与 meta / nodes 同思路）。
      if (item['groupId'] != null) 'groupId': item['groupId'],
    };
    return _ItemRow(
      id: id,
      kind: kind,
      z: z,
      rect: rect,
      angle: (item['angle'] as num?)?.toDouble() ?? 0,
      color: (item['color'] as num?)?.toInt(),
      filled: item['filled'] == null
          ? null
          : ((item['filled'] as bool) ? 1 : 0),
      strokeWidth: (item['strokeWidth'] as num?)?.toDouble(),
      src: item['src'] as String?,
      blockId: item['blockId'] as String?,
      text: item['text'] as String?,
      propsJson: jsonEncode(props),
      fingerprint: contentFingerprint(jsonEncode(item)),
    );
  }

  /// **卡片（card）的 JSON 契约**——存储层与内核 `CardItem` 之间的约定
  /// （本层只认 JSON，不认内核类；格式的权威仍是内核的 `toJson`）。
  ///
  /// ```json
  /// { "type": "card", "id": "card-1", "blockId": "b1",
  ///   "text": "想法…", "angle": 0, "rect": [l, t, r, b], "meta": {} }
  /// ```
  ///
  /// - `blockId` 指向 `blocks.id`：**内容**（`text`）存在那一行；
  /// - 本表只承接**几何**（rect / angle / z 序）+ 这个引用。
  ///
  /// 于是 `text` 在存档 JSON 里是**可见的**（自包含、可读、可导出），
  /// 但落库时被拆到 blocks —— 两边由 [verifyCanvasRows] 的深比较守住一致。

  static List<_EdgeRow> _edgeRows(Map<String, dynamic> document) {
    final Object? raw = document['edges'];
    // 旧存档 / 无边画布：这个键**不存在**（内核 toJson 也是空则不写）。
    if (raw is! Map) return const <_EdgeRow>[];
    final Map<String, dynamic> edges = raw.cast<String, dynamic>();
    return <_EdgeRow>[
      for (final MapEntry<String, dynamic> e in edges.entries)
        if (_edgeRowOf(e.key, e.value) case final _EdgeRow row) row,
    ];
  }

  /// 一行连线：**端点存 id**（binding）——坐标从不落库，绘制时才由两端卡片现算。
  static _EdgeRow? _edgeRowOf(String id, Object? raw) {
    if (raw is! Map) return null;
    final Map<String, dynamic> e = raw.cast<String, dynamic>();
    final String? fromId = e['fromId'] as String?;
    final String? toId = e['toId'] as String?;
    // 缺端点的边无法落库（外键会拒绝），直接丢弃——它本来也画不出来。
    if (fromId == null || toId == null) return null;
    // 端点形状（非缺省时）随 props_json 扩展位往返——与 item 的 colorSlot /
    // groupId 同口径：**内核 JSON 是顶层键，落库收进 props_json**，不占任何新列。
    final Map<String, dynamic> edgeProps = <String, dynamic>{
      ...?(e['props'] as Map?)?.cast<String, dynamic>(),
      if (e['startShape'] != null) 'startShape': e['startShape'],
      if (e['endShape'] != null) 'endShape': e['endShape'],
    };
    return _EdgeRow(
      id: id,
      fromId: fromId,
      toId: toId,
      fromSide: e['fromSide'] as String?,
      toSide: e['toSide'] as String?,
      propsJson: jsonEncode(edgeProps),
      fingerprint: contentFingerprint(jsonEncode(e)),
    );
  }

  static Map<int, _ShardRow> _shardRows(Map<String, dynamic> document) {
    final Object? strokesRaw = document['strokes'];
    if (strokesRaw is! Map) return const <int, _ShardRow>{};
    final Map<String, dynamic> strokes = strokesRaw.cast<String, dynamic>();
    final List<Object?> order =
        (document['strokeOrder'] as List?) ?? const <Object?>[];

    final List<Map<String, dynamic>> list = <Map<String, dynamic>>[];
    final Set<String> seen = <String>{};
    for (final Object? id in order) {
      if (id is! String) continue;
      final Object? s = strokes[id];
      if (s is Map && seen.add(id)) list.add(s.cast<String, dynamic>());
    }
    for (final MapEntry<String, dynamic> e in strokes.entries) {
      if (seen.contains(e.key)) continue;
      if (e.value is Map) list.add((e.value as Map).cast<String, dynamic>());
    }

    final Map<int, _ShardRow> shards = <int, _ShardRow>{};
    for (int start = 0; start < list.length; start += strokesPerShard) {
      final List<Map<String, dynamic>> slice = list.sublist(
        start,
        math.min(start + strokesPerShard, list.length),
      );
      final int index = start ~/ strokesPerShard;
      shards[index] = _ShardRow(
        shardIndex: index,
        points: _encodePoints(slice),
        styleJson: jsonEncode(<String, dynamic>{
          'v': 1,
          'strokes': <Map<String, dynamic>>[
            for (final Map<String, dynamic> s in slice)
              <String, dynamic>{
                'id': s['id'],
                'color': s['color'],
                'baseWidth': s['baseWidth'],
                'simulatePressure': s['simulatePressure'],
                'version': s['version'],
                // blob 是**连续**的 Float32 三元组 ⇒ 解码必须知道每笔几个点。
                'points': (s['points'] as List?)?.length ?? 0,
              },
          ],
        }),
        count: slice.length,
        // 指纹取**源 JSON**：它包含点坐标，所以坐标一动指纹就变（比只哈希样式可靠）。
        fingerprint: contentFingerprint(jsonEncode(slice)),
      );
    }
    return shards;
  }

  /// 一个分片的点列 → 连续 Float32 三元组 `(x, y, pressure)`。
  /// 每笔的点数记在 `style_json.strokes[i].points`，解码时按它切片。
  static Uint8List _encodePoints(List<Map<String, dynamic>> slice) {
    int total = 0;
    for (final Map<String, dynamic> s in slice) {
      total += (s['points'] as List?)?.length ?? 0;
    }
    final Float32List out = Float32List(total * 3);
    int i = 0;
    for (final Map<String, dynamic> s in slice) {
      final List<Object?>? points = s['points'] as List?;
      if (points == null) continue;
      for (final Object? p in points) {
        final List<Object?> triple = p as List;
        out[i++] = (triple[0] as num).toDouble();
        out[i++] = (triple[1] as num).toDouble();
        out[i++] = (triple[2] as num).toDouble();
      }
    }
    return out.buffer.asUint8List();
  }

  /// 把画布里的**卡片内容**同步进 `blocks`（v9）。
  ///
  /// 卡片与形状 / 图片的根本差别是**它有可索引文本** ⇒ 内容必须落 `blocks`，
  /// 否则画布上的想法搜不到、引不到、AI 索引不到（`chunks_fts` 与 `index_state`
  /// 都建在 blocks 上）。详见 `docs/canvas_architecture.md` 第七章
  /// 「卡片为什么是例外」。
  ///
  /// 与 [replaceCanvasRows] 同口径：**先算差量再落笔**，没变就一行都不写
  /// （自动保存每次防抖都会走到这里）。返回真正写到的行数。
  ///
  /// ## 两种卡片，两条写路径（块可迁移 #5「双链多视图」）
  ///
  /// - **自有卡片**：`block_id` 就是本画布自己的块（或那一行还不存在 ⇒ 该新建）。
  ///   内容完全归画布 —— 照旧整行写入，卡片删掉时行也删掉。
  /// - **引用卡片**：`block_id` 在**别的笔记**里（典型：文档正文里的一个段落被
  ///   引用到画布上，真身必须留下）。这里**只更新它的 `text`**：`note_id` / `type`
  ///   一律不动、其余属性（标题的 `level`、待办的 `checked`…）原样保留，
  ///   更**绝不删行** —— 删行等于删文档正文。
  ///
  /// 两种卡片判变口径也不同：自有按内容指纹、引用**按文本比对**（只看这一个键，
  /// 免得几何一动就重写别人的块、惊动它的 AI 索引）。
  ///
  /// ⚠️ 必须在 [replaceCanvasRows] 的事务内调用：几何与内容是同一张卡的**两半**，
  /// 只写一半会留下"没有内容的空框"或"没有几何的孤儿文本"。
  int _replaceCardBlocks(String noteId, List<_ItemRow> items) {
    final List<_ItemRow> cards = <_ItemRow>[
      for (final _ItemRow r in items)
        if (r.kind == 'card' && r.blockId != null) r,
    ];
    // 每个 block_id 此刻归谁。**查不到 = 那一行还不存在** ⇒ 当作自有，走新建
    // （顺带修好"文档里删了块、画布 JSON 还留着卡片"的悬空引用：重建成自有块）。
    final Map<String, _BlockOwner> owners = _ownersOf(<String>[
      for (final _ItemRow r in cards) r.blockId!,
    ]);
    bool mine(_ItemRow r) => (owners[r.blockId]?.noteId ?? noteId) == noteId;

    final List<_ItemRow> own = <_ItemRow>[
      for (final _ItemRow r in cards)
        if (mine(r)) r,
    ];
    final List<_ItemRow> foreign = <_ItemRow>[
      for (final _ItemRow r in cards)
        if (!mine(r)) r,
    ];

    // ── 自有卡片：整行随卡片生灭（旧行为，不动）──
    final Map<String, String> existing = <String, String>{
      for (final Row r in db.select(
        'SELECT id, fingerprint FROM blocks WHERE note_id = ? AND type = ?',
        <Object?>[noteId, _cardType],
      ))
        r['id'] as String: r['fingerprint'] as String,
    };
    final Set<String> keep = <String>{for (final _ItemRow r in own) r.blockId!};
    final List<String> removed = <String>[
      for (final String id in existing.keys)
        if (!keep.contains(id)) id,
    ];
    final List<_ItemRow> changedOwn = <_ItemRow>[
      for (final _ItemRow r in own)
        if (existing[r.blockId] != _cardFingerprint(r)) r,
    ];

    // ── 引用卡片：只改对方的 `text`，且真的变了才写 ──
    final List<_ItemRow> changedForeign = <_ItemRow>[
      for (final _ItemRow r in foreign)
        if ((owners[r.blockId]?.text ?? '') != (r.text ?? '')) r,
    ];

    if (removed.isEmpty && changedOwn.isEmpty && changedForeign.isEmpty) {
      return 0;
    }

    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final String id in removed) {
      db.execute('DELETE FROM blocks WHERE id = ?', <Object?>[id]);
    }
    for (final _ItemRow row in changedOwn) {
      db.execute(
        'INSERT INTO blocks (id, note_id, type, props_json, ord, created_at, '
        'updated_at, fingerprint) VALUES (?,?,?,?,?,?,?,?) '
        'ON CONFLICT(id) DO UPDATE SET props_json=excluded.props_json, '
        'updated_at=excluded.updated_at, fingerprint=excluded.fingerprint',
        <Object?>[
          row.blockId,
          noteId,
          _cardType,
          jsonEncode(<String, dynamic>{'text': row.text ?? ''}),
          // ⚠️ ord 对画布卡片**不承载语义**：z 序的权威在 `canvas_items.z`。
          // 填 0 是刻意的 —— 让 `ord` 保持"阅读顺序"这一个含义，避免一列两义
          // （那正是第七章决定不让画布进 blocks 的理由之一）。
          0,
          now,
          now,
          _cardFingerprint(row),
        ],
      );
    }
    for (final _ItemRow row in changedForeign) {
      final _BlockOwner owner = owners[row.blockId]!;
      final Map<String, dynamic> props = _decodePropsMap(owner.propsJson);
      props['text'] = row.text ?? '';
      final String propsJson = jsonEncode(props);
      db.execute(
        'UPDATE blocks SET props_json = ?, updated_at = ?, fingerprint = ? '
        'WHERE id = ?',
        <Object?>[
          propsJson,
          now,
          // 指纹与 `BlockStore` **同口径**（`type\npropsJson`）：否则那次保存会
          // 把这块当成"变了"再整行重写一遍（多一次写，且惊动 AI 索引）。
          contentFingerprint('${owner.type}\n$propsJson'),
          row.blockId,
        ],
      );
    }
    return removed.length + changedOwn.length + changedForeign.length;
  }

  /// 一批 `block_id` 此刻的归属与内容（引用卡片判变 / 回写用）。
  ///
  /// 不存在于 `blocks` 的 id **不在结果里** —— 调用方按"当作自有、走新建"处理。
  Map<String, _BlockOwner> _ownersOf(List<String> blockIds) {
    if (blockIds.isEmpty) return const <String, _BlockOwner>{};
    final String placeholders = List<String>.filled(
      blockIds.length,
      '?',
    ).join(',');
    final ResultSet rs = db.select(
      'SELECT id, note_id, type, props_json FROM blocks WHERE id IN ($placeholders)',
      blockIds,
    );
    return <String, _BlockOwner>{
      for (final Row r in rs)
        r['id'] as String: _BlockOwner(
          noteId: r['note_id'] as String,
          type: r['type'] as String,
          propsJson: r['props_json'] as String,
          text: textOfProps(r['props_json'] as String?),
        ),
    };
  }

  /// `props_json` → 可变 Map。脏数据（非对象 / 半截 JSON）降级为空 Map——
  /// 回写时至少能把 `text` 落进去，而不是让整次画布保存失败。
  static Map<String, dynamic> _decodePropsMap(String propsJson) {
    try {
      final Object? decoded = jsonDecode(propsJson);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } on FormatException {
      // 落到下面的空 Map。
    }
    return <String, dynamic>{};
  }

  /// 卡片内容的指纹：**只看文本**。
  ///
  /// 几何变了不该重写内容（那是 `canvas_items` 的事）——否则拖一下卡片就要重写
  /// blocks 行，还会连带让 AI 索引以为内容变了（`index_state` 按 fingerprint 判）。
  static String _cardFingerprint(_ItemRow row) =>
      contentFingerprint(row.text ?? '');

  // ── 差量所需的既有行 ──────────────────────────────────────────────

  Map<String, _ExistingItem> _existingItems(
    String noteId,
  ) => <String, _ExistingItem>{
    for (final Row r in db.select(
      'SELECT id, fingerprint, created_at FROM canvas_items WHERE note_id = ?',
      <Object?>[noteId],
    ))
      r['id'] as String: _ExistingItem(
        fingerprint: r['fingerprint'] as String,
        createdAt: r['created_at'] as int,
      ),
  };

  Map<int, _ExistingShard> _existingShards(String noteId) =>
      <int, _ExistingShard>{
        for (final Row r in db.select(
          'SELECT shard_index, fingerprint FROM ink_shards WHERE note_id = ?',
          <Object?>[noteId],
        ))
          r['shard_index'] as int: _ExistingShard(
            fingerprint: r['fingerprint'] as String,
          ),
      };

  Map<String, _ExistingEdge> _existingEdges(
    String noteId,
  ) => <String, _ExistingEdge>{
    for (final Row r in db.select(
      'SELECT id, fingerprint FROM canvas_edges WHERE note_id = ?',
      <Object?>[noteId],
    ))
      r['id'] as String: _ExistingEdge(fingerprint: r['fingerprint'] as String),
  };

  /// 读出连线行（还原用）。按主键顺序即可——连线没有 z 序语义。
  List<_EdgeRowRead> _readEdges(String noteId) => <_EdgeRowRead>[
    for (final Row r in db.select(
      'SELECT id, from_id, to_id, from_side, to_side, props_json '
      'FROM canvas_edges WHERE note_id = ?',
      <Object?>[noteId],
    ))
      _EdgeRowRead(
        id: r['id'] as String,
        fromId: r['from_id'] as String,
        toId: r['to_id'] as String,
        fromSide: r['from_side'] as String?,
        toSide: r['to_side'] as String?,
        propsJson: r['props_json'] as String,
      ),
  ];

  bool _metaChanged(String noteId, String fingerprint) {
    final ResultSet rs = db.select(
      'SELECT value FROM rag_meta WHERE key = ?',
      <Object?>['canvas.meta.fp.$noteId'],
    );
    return rs.isEmpty || rs.single['value'] != fingerprint;
  }

  /// `canvas_meta` 有没有"该重写"的变化。相机与格式版本在表里，item 集合的形状
  /// （id 列表）寄存在 `rag_meta`——**不把 z 序塞进 canvas_meta**：z 属于每个 item 行，
  /// 这里只需要一个"集合变了"的信号。
  static String _metaFingerprint(
    String cameraJson,
    int schemaVersion,
    List<String> itemIds,
  ) => contentFingerprint('$cameraJson|$schemaVersion|${itemIds.join(',')}');
}

class _ItemRow {
  const _ItemRow({
    required this.id,
    required this.kind,
    required this.z,
    required this.rect,
    required this.angle,
    required this.color,
    required this.filled,
    required this.strokeWidth,
    required this.src,
    required this.blockId,
    required this.text,
    required this.propsJson,
    required this.fingerprint,
  });

  final String id;
  final String kind;
  final int z;

  /// `[left, top, right, bottom]`（世界坐标，原样四条边）。
  final List<double> rect;
  final double angle;
  final int? color;
  final int? filled;
  final double? strokeWidth;
  final String? src;
  final String propsJson;
  final String fingerprint;

  /// 仅 `kind='card'`：卡片**内容**所在的 `blocks.id`（几何在本行）。
  final String? blockId;

  /// 仅 `kind='card'`：卡片文本。落 `blocks`，**不**进 `props_json`。
  final String? text;
}

/// 一个块此刻的归属与内容（`_ownersOf` 的结果）。
///
/// [noteId] 用来判定卡片是"自有"还是"引用"（见 [_replaceCardBlocks]）；
/// [propsJson] / [text] 供引用路径判变与回写一个键。
class _BlockOwner {
  const _BlockOwner({
    required this.noteId,
    required this.type,
    required this.propsJson,
    required this.text,
  });

  final String noteId;
  final String type;
  final String propsJson;
  final String text;
}

class _ShardRow {
  const _ShardRow({
    required this.shardIndex,
    required this.points,
    required this.styleJson,
    required this.count,
    required this.fingerprint,
  });

  final int shardIndex;
  final Uint8List points;
  final String styleJson;
  final int count;
  final String fingerprint;
}

class _ExistingItem {
  const _ExistingItem({required this.fingerprint, required this.createdAt});

  final String fingerprint;
  final int createdAt;
}

class _ExistingShard {
  const _ExistingShard({required this.fingerprint});

  final String fingerprint;
}

/// `canvas_meta` 的一行（相机 + 画布格式版本）。
class _MetaRow {
  const _MetaRow({required this.cameraJson, required this.schemaVersion});

  final String cameraJson;
  final int schemaVersion;
}

/// `canvas_items` 的一行（反向投影用：行 → item JSON）。
class _ItemRowRead {
  const _ItemRowRead({
    required this.id,
    required this.kind,
    required this.rect,
    required this.angle,
    required this.color,
    required this.filled,
    required this.strokeWidth,
    required this.src,
    required this.blockId,
    required this.propsJson,
  });

  final String id;
  final String kind;

  /// `[left, top, right, bottom]`。
  final List<double> rect;
  final double angle;
  final int? color;
  final int? filled;
  final double? strokeWidth;
  final String? src;
  final String propsJson;

  /// 仅 `kind='card'`：卡片内容所在的 `blocks.id`。
  final String? blockId;
}

/// `ink_shards` 的一行（反向投影用：blob + 样式 → 笔迹 JSON）。
class _ShardRowRead {
  const _ShardRowRead({
    required this.shardIndex,
    required this.points,
    required this.styleJson,
  });

  final int shardIndex;

  /// 连续的 Float32 三元组（平台字节序；本项目目标平台是 Windows 桌面）。
  final Uint8List points;
  final String styleJson;
}

/// `canvas_edges` 的**写入**行。
class _EdgeRow {
  const _EdgeRow({
    required this.id,
    required this.fromId,
    required this.toId,
    required this.fromSide,
    required this.toSide,
    required this.propsJson,
    required this.fingerprint,
  });

  final String id;

  /// 端点：**id 而不是坐标**（binding，见 `CanvasEdge` 的类文档）。
  final String fromId;
  final String toId;
  final String? fromSide;
  final String? toSide;
  final String propsJson;
  final String fingerprint;
}

/// `canvas_edges` 的**读取**行（还原用）。
class _EdgeRowRead {
  const _EdgeRowRead({
    required this.id,
    required this.fromId,
    required this.toId,
    required this.fromSide,
    required this.toSide,
    required this.propsJson,
  });

  final String id;
  final String fromId;
  final String toId;
  final String? fromSide;
  final String? toSide;
  final String propsJson;

  /// 还原成连线 JSON：**缺省字段不写**——与 `CanvasEdge.toJson` 逐项对齐，
  /// 否则深比较会差一个键（表现是所有带连线的画布静默回退 JSON）。
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> props = (jsonDecode(propsJson) as Map)
        .cast<String, dynamic>();
    // 端点形状从 props_json 里取出、升回顶层（与内核 toJson 同口径）。
    final Object? startShape = props.remove('startShape');
    final Object? endShape = props.remove('endShape');
    return <String, dynamic>{
      'id': id,
      'fromId': fromId,
      'toId': toId,
      if (fromSide != null) 'fromSide': fromSide,
      if (toSide != null) 'toSide': toSide,
      'startShape': ?startShape,
      'endShape': ?endShape,
      if (props.isNotEmpty) 'props': props,
    };
  }
}

class _ExistingEdge {
  const _ExistingEdge({required this.fingerprint});

  final String fingerprint;
}
