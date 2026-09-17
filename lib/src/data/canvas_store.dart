import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'fingerprint.dart';

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

    final Map<String, dynamic> document =
        (json['document'] as Map).cast<String, dynamic>();
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
    final bool metaChanged = _metaChanged(noteId, metaFingerprint);

    if (removedItems.isEmpty &&
        changedItems.isEmpty &&
        removedShards.isEmpty &&
        changedShards.isEmpty &&
        !metaChanged) {
      return 0;
    }

    db.execute('BEGIN;');
    try {
      for (final String id in removedItems) {
        db.execute(
          'DELETE FROM canvas_items WHERE note_id = ? AND id = ?',
          <Object?>[noteId, id],
        );
      }
      for (final _ItemRow row in changedItems) {
        db.execute(
          'INSERT INTO canvas_items (id, note_id, kind, z, x1, y1, x2, y2, '
          'angle, color, filled, stroke_width, src, props_json, created_at, '
          'updated_at, fingerprint) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
          // ⚠️ 冲突目标必须是 **(note_id, id)**：item id 是内核的进程内自增计数器
          // （`item-1`…），两张画布同时存在同一个 id 是常态（见 database.dart 的
          // `_canvasItemsDdl`）。写成单列 id 会让后写的那张把前一行的 note_id 抢走。
          'ON CONFLICT(note_id, id) DO UPDATE SET '
          'kind=excluded.kind, z=excluded.z, x1=excluded.x1, y1=excluded.y1, '
          'x2=excluded.x2, y2=excluded.y2, angle=excluded.angle, '
          'color=excluded.color, filled=excluded.filled, '
          'stroke_width=excluded.stroke_width, src=excluded.src, '
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
            row.propsJson,
            // created_at 只在**首次**落行时写：更新不该动它（否则"只改一块"
            // 的语义就没了 —— 与 blocks 的判变口径一致）。
            oldItems[row.id]?.createdAt ?? now,
            now,
            row.fingerprint,
          ],
        );
      }
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
      if (replaceCanvasRows(row['id'] as String, row['content'] as String) > 0) {
        done++;
      }
    }
    return done;
  }

  /// 这篇笔记当前有没有画布行（第 2 步回填、第 3 步校验的判据）。
  bool hasRows(String noteId) => db
      .select(
        'SELECT 1 FROM canvas_meta WHERE note_id = ? LIMIT 1',
        <Object?>[noteId],
      )
      .isNotEmpty;

  // ── 解析与投影 ────────────────────────────────────────────────────

  /// 画布 JSON 的格式门闩：顶层是 `{camera, document}`，且 document 里带
  /// `strokes` / `items`。**不是画布内容就返回 null**（v2 块树、Delta、空串都在这里
  /// 被挡掉），于是它可以像 `replaceNoteBlocks` 一样被无脑调用。
  static Map<String, dynamic>? _parseCanvasDocument(String content) {
    if (content.trim().isEmpty) return null;
    final dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final dynamic camera = decoded['camera'];
    final dynamic document = decoded['document'];
    if (camera is! Map || document is! Map) return null;
    if (document['strokes'] is! Map && document['items'] is! Map) return null;
    return decoded;
  }

  static List<_ItemRow> _itemRows(Map<String, dynamic> document) {
    final dynamic itemsRaw = document['items'];
    if (itemsRaw is! Map) return const <_ItemRow>[];
    final Map<String, dynamic> items = itemsRaw.cast<String, dynamic>();
    final List<dynamic> order = (document['itemOrder'] as List?) ?? const <dynamic>[];
    // z 序 = `itemOrder` 的下标；不在 order 里的（异常存档）按 Map 顺序排到末尾。
    final Set<String> inOrder = <String>{
      for (final dynamic id in order)
        if (id is String && items.containsKey(id)) id,
    };
    final List<String> ids = <String>[
      for (final dynamic id in order)
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
  static _ItemRow? _itemRowOf(String id, dynamic raw, int z) {
    if (raw is! Map) return null;
    final Map<String, dynamic> item = raw.cast<String, dynamic>();
    final dynamic rectRaw = item['rect'];
    if (rectRaw is! List || rectRaw.length < 4) return null;
    final List<double> rect = <double>[
      for (final dynamic v in rectRaw.take(4)) (v as num).toDouble(),
    ];
    final String type = item['type'] as String? ?? 'shape';
    final String? shapeKind = item['kind'] as String?;
    final String kind = switch (type) {
      'shape' => 'shape.${shapeKind ?? 'rectangle'}',
      'aiImage' => 'ai_image',
      _ => type, // 'image'
    };
    // 扩展位只装**非空**的 meta / gen：空对象会让"行 ⇄ 原文"的深比较更容易失配。
    final Map<String, dynamic> props = <String, dynamic>{
      if ((item['meta'] as Map?)?.isNotEmpty ?? false) 'meta': item['meta'],
      if (item['gen'] != null) 'gen': item['gen'],
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
      propsJson: jsonEncode(props),
      fingerprint: contentFingerprint(jsonEncode(item)),
    );
  }

  static Map<int, _ShardRow> _shardRows(Map<String, dynamic> document) {
    final dynamic strokesRaw = document['strokes'];
    if (strokesRaw is! Map) return const <int, _ShardRow>{};
    final Map<String, dynamic> strokes = strokesRaw.cast<String, dynamic>();
    final List<dynamic> order =
        (document['strokeOrder'] as List?) ?? const <dynamic>[];

    final List<Map<String, dynamic>> list = <Map<String, dynamic>>[];
    final Set<String> seen = <String>{};
    for (final dynamic id in order) {
      if (id is! String) continue;
      final dynamic s = strokes[id];
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
      final List<dynamic>? points = s['points'] as List?;
      if (points == null) continue;
      for (final dynamic p in points) {
        final List<dynamic> triple = p as List;
        out[i++] = (triple[0] as num).toDouble();
        out[i++] = (triple[1] as num).toDouble();
        out[i++] = (triple[2] as num).toDouble();
      }
    }
    return out.buffer.asUint8List();
  }

  // ── 差量所需的既有行 ──────────────────────────────────────────────

  Map<String, _ExistingItem> _existingItems(String noteId) => <String, _ExistingItem>{
    for (final Row r in db.select(
      'SELECT id, fingerprint, created_at FROM canvas_items WHERE note_id = ?',
      <Object?>[noteId],
    ))
      r['id'] as String: _ExistingItem(
        fingerprint: r['fingerprint'] as String,
        createdAt: r['created_at'] as int,
      ),
  };

  Map<int, _ExistingShard> _existingShards(String noteId) => <int, _ExistingShard>{
    for (final Row r in db.select(
      'SELECT shard_index, fingerprint FROM ink_shards WHERE note_id = ?',
      <Object?>[noteId],
    ))
      r['shard_index'] as int: _ExistingShard(
        fingerprint: r['fingerprint'] as String,
      ),
  };

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
  ) =>
      contentFingerprint('$cameraJson|$schemaVersion|${itemIds.join(',')}');
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
