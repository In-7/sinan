import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/canvas_store.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 画布落点**第 1 步（双写）**的回归（2026-09-17，见 `docs/canvas_architecture.md` 第七章）。
///
/// 双写阶段最该钉的不是"写进去了"，而是三件会悄悄坏掉的事：
/// 1. **格式门闩**：文档笔记的块树 / Delta / 空串都不能在画布表里留行
///    （留了就等于给两类笔记互相污染）；
/// 2. **判变**：同样的内容重复保存必须**一行都不写**，改一个 item 只重写那一行
///    （`created_at` 纹丝不动）——否则自动保存每次防抖都在写全表；
/// 3. **几何精度**：rect 存四条边，往返不能有浮点误差（第 3 步的深比较依赖它）。
void main() {
  late Database db;
  late NoteStore store;
  late CanvasStore canvas;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
    canvas = CanvasStore(db);
    // 画布三张表都外键到 `notes` ⇒ 直接调投影前必须有一篇画布笔记。
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES ('n1','canvas','','','fp1:0:0','',1,1)",
    );
  });

  tearDown(() => db.close());

  /// 一条 shape item（字段与 `ShapeItem.toJson` 逐项对齐）。
  Map<String, Object?> shape(String id, {List<double>? rect}) => <String, Object?>{
    'type': 'shape',
    'id': id,
    'kind': 'rectangle',
    'color': 0xFF1F1F1F,
    'strokeWidth': 2.0,
    'filled': false,
    'angle': 0.0,
    'rect': rect ?? <double>[0.0, 0.0, 10.0, 20.0],
    'meta': <String, Object?>{},
  };

  /// 一条笔迹（字段与 `InkStroke.toJson` 逐项对齐）。
  Map<String, Object?> stroke(String id, {int points = 2}) => <String, Object?>{
    'id': id,
    'version': 1,
    'color': 0xFF000000,
    'baseWidth': 4.0,
    'simulatePressure': true,
    'points': <List<double>>[
      for (int i = 0; i < points; i++) <double>[i * 1.0, i * 2.0, 0.5],
    ],
  };

  String canvasJson({
    Map<String, Map<String, Object?>> items = const {},
    List<String> itemOrder = const <String>[],
    Map<String, Map<String, Object?>> strokes = const {},
    List<String> strokeOrder = const <String>[],
    double scale = 1.0,
    int schemaVersion = 2,
  }) => jsonEncode(<String, Object?>{
    'camera': <String, Object?>{'scale': scale, 'translation': <double>[0.0, 0.0]},
    'document': <String, Object?>{
      'schemaVersion': schemaVersion,
      'strokes': strokes,
      'items': items,
      'strokeOrder': strokeOrder,
      'itemOrder': itemOrder,
    },
  });

  /// 文档笔记的 v2 块树（带格式标记，与 `NoteDocumentAdapter` 一致）。
  String blocksJson() => jsonEncode(<String, Object?>{
    'v': 2,
    'format': 'blocks',
    'document': <String, Object?>{'id': 'root', 'type': 'page', 'children': <Object?>[]},
  });

  test('首次投影：items 落成行（z 序 + 四边 + kind 拍平），meta 与墨迹一并写入', () {
    final String json = canvasJson(
      items: <String, Map<String, Object?>>{
        's1': shape('s1', rect: <double>[1.5, 2.5, 11.5, 22.5]),
        's2': shape('s2'),
      },
      itemOrder: <String>['s2', 's1'], // z 序：s2 在下
      strokes: <String, Map<String, Object?>>{'k1': stroke('k1')},
      strokeOrder: <String>['k1'],
      scale: 2.0,
    );

    // 2 item + 1 shard + 1 meta = 4 行。
    expect(canvas.replaceCanvasRows('n1', json), 4);
    expect(canvas.hasRows('n1'), isTrue);

    final ResultSet items = db.select(
      'SELECT id, kind, z, x1, y1, x2, y2, angle, color, filled, stroke_width, src '
      'FROM canvas_items WHERE note_id = ? ORDER BY z',
      <Object?>['n1'],
    );
    expect(items, hasLength(2));
    // z 序按 itemOrder：s2 = 0、s1 = 1（不是按 id 或插入顺序）。
    expect(items[0]['id'], 's2');
    expect(items[1]['id'], 's1');
    expect(items[0]['kind'], 'shape.rectangle'); // type + 形状 kind 拍平成一列
    expect(items[0]['z'], 0);
    expect(items[1]['z'], 1);
    // 四边**原样**存：不做 w=r-l 的换算（第 3 步深比较依赖它）。
    expect(items[1]['x1'], 1.5);
    expect(items[1]['y1'], 2.5);
    expect(items[1]['x2'], 11.5);
    expect(items[1]['y2'], 22.5);
    expect(items[1]['color'], 0xFF1F1F1F);
    expect(items[1]['filled'], 0); // bool → 0/1
    expect(items[1]['stroke_width'], 2.0);

    final Row meta = db
        .select('SELECT camera_json, schema_version FROM canvas_meta WHERE note_id = ?',
            <Object?>['n1'])
        .single;
    expect((jsonDecode(meta['camera_json'] as String) as Map)['scale'], 2.0);
    expect(meta['schema_version'], 2); // ← 画布格式版本终于有落点了

    final Row shard = db
        .select('SELECT points_blob, style_json, count FROM ink_shards WHERE note_id = ?',
            <Object?>['n1'])
        .single;
    expect(shard['count'], 1); // 本片**笔数**（不是点数）
    expect(shard['points_blob'], hasLength(2 * 3 * 4)); // 2 点 × (x,y,p) × Float32
    final Map<String, dynamic> style =
        jsonDecode(shard['style_json'] as String) as Map<String, dynamic>;
    expect(style['v'], 1);
    final List<dynamic> styleStrokes = style['strokes'] as List<dynamic>;
    expect(
      (styleStrokes.first as Map<String, dynamic>)['points'],
      2,
      reason: 'blob 是连续三元组，解码必须靠每笔的点数切片',
    );
  });

  test('判变：同样内容重复保存一行不写；改一个 item 只重写那一行', () {
    final String json = canvasJson(
      items: <String, Map<String, Object?>>{'s1': shape('s1'), 's2': shape('s2')},
      itemOrder: <String>['s1', 's2'],
    );
    expect(canvas.replaceCanvasRows('n1', json), greaterThan(0));

    // ① 幂等：内容没变 ⇒ 0（自动保存每次防抖都会调到这里）。
    expect(canvas.replaceCanvasRows('n1', json), 0);

    final Map<String, int> createdBefore = <String, int>{
      for (final Row r in db.select('SELECT id, created_at FROM canvas_items'))
        r['id'] as String: r['created_at'] as int,
    };

    // ② 只改 s2 的几何 ⇒ 只重写 s2 这一行（s1 的 created_at 必须纹丝不动）。
    final String moved = canvasJson(
      items: <String, Map<String, Object?>>{
        's1': shape('s1'),
        's2': shape('s2', rect: <double>[50.0, 0.0, 60.0, 20.0]),
      },
      itemOrder: <String>['s1', 's2'],
    );
    expect(canvas.replaceCanvasRows('n1', moved), 1);
    expect(db.select("SELECT x1 FROM canvas_items WHERE id='s2'").single['x1'], 50.0);
    expect(
      db.select("SELECT created_at FROM canvas_items WHERE id='s1'").single['created_at'],
      createdBefore['s1'],
      reason: '没变的 item 被重写了：判变失效，自动保存会写全表',
    );
  });

  test('删 item：行随之删除（同时因 id 集合变化而更新 meta）', () {
    final String two = canvasJson(
      items: <String, Map<String, Object?>>{'s1': shape('s1'), 's2': shape('s2')},
      itemOrder: <String>['s1', 's2'],
    );
    canvas.replaceCanvasRows('n1', two);

    final String one = canvasJson(
      items: <String, Map<String, Object?>>{'s1': shape('s1')},
      itemOrder: <String>['s1'],
    );
    // 1 行删除 + 1 行 meta（id 集合变了 ⇒ meta 指纹变）。
    expect(canvas.replaceCanvasRows('n1', one), 2);
    expect(
      db.select('SELECT id FROM canvas_items').map((Row r) => r['id']).toSet(),
      <String>{'s1'},
    );
  });

  test('格式门闩：块树 / Delta / 空串都不在画布表里留行', () {
    for (final String notCanvas in <String>[blocksJson(), '[{"insert":"x"}]', '', '  ']) {
      expect(
        canvas.replaceCanvasRows('n1', notCanvas),
        0,
        reason: '非画布内容被投影了：两类笔记会互相污染',
      );
    }
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'], 0);
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_meta').single['c'], 0);
    expect(canvas.hasRows('n1'), isFalse);
  });

  test('笔迹分片：超过一片（256 笔）时按片落行', () {
    final Map<String, Map<String, Object?>> strokes = <String, Map<String, Object?>>{
      for (int i = 0; i < 300; i++) 'k$i': stroke('k$i'),
    };
    final String json = canvasJson(
      strokes: strokes,
      strokeOrder: strokes.keys.toList(),
    );

    canvas.replaceCanvasRows('n1', json);
    final ResultSet shards = db.select(
      'SELECT shard_index, count FROM ink_shards WHERE note_id = ? ORDER BY shard_index',
      <Object?>['n1'],
    );
    expect(shards, hasLength(2));
    expect(shards[0]['count'], CanvasStore.strokesPerShard);
    expect(shards[1]['count'], 300 - CanvasStore.strokesPerShard);
    // blob 长度 = 全部点数 × 3 分量 × Float32。
    final Uint8List blob = db
        .select("SELECT points_blob FROM ink_shards WHERE shard_index = 0")
        .single['points_blob'] as Uint8List;
    expect(blob.lengthInBytes, CanvasStore.strokesPerShard * 2 * 3 * 4);
  });

  test('回填（第 2 步）：存量画布补齐；空白画布不占名额、幂等可续跑', () {
    void legacy(String id, String kind, String content, int ts) {
      db.execute(
        'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
        'created_at, revised_at) VALUES (?,?,?,?,?,?,?,?)',
        <Object?>[id, kind, '', content, 'fp1:1:$id', '', ts, ts],
      );
    }

    final String live = canvasJson(
      items: <String, Map<String, Object?>>{'s1': shape('s1')},
      itemOrder: <String>['s1'],
    );
    // 四行三种情况：空白新画布（常态）、两张存量画布、一条文档笔记。
    // 注意 setUp 里那张 'n1' 也是空内容的画布笔记。
    legacy('c0', 'canvas', '', 1);
    legacy('c1', 'canvas', live, 2);
    legacy('c2', 'canvas', live, 3);
    legacy('d1', 'note', blocksJson(), 4);

    // 名额恰好 2：空白画布与文档笔记**都不能进候选**——否则它们会占掉名额、
    // 每次启动白扫一遍（那正是 blocks 侧刚修掉的同一类问题）。
    expect(store.backfillCanvas(limit: 2), 2);
    expect(canvas.hasRows('c1'), isTrue);
    expect(canvas.hasRows('c2'), isTrue);
    expect(canvas.hasRows('c0'), isFalse, reason: '空白画布不是"待回填"');
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'], 2);
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_meta').single['c'], 2);

    // 幂等 + 可续跑：再跑没有任何新增（已落行的不会被重写一遍）。
    expect(store.backfillCanvas(), 0);
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'], 2);
  });

  test('跨画布撞号：两张画布的同名 item id 各存一行（主键含 note_id）', () {
    // 内核的 item id 是**进程内自增计数器**（`item-0`、`item-1`…），应用重启后从头的
    // 值开始 ⇒ 两张画布同时存在 `item-1` 是常态。主键若只是单列 id，后写的那张会把
    // 前一张的行抢走（`ON CONFLICT(id) DO UPDATE` 连 note_id 一起改）。
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES ('c2','canvas','','','fp1:0:0','',2,2)",
    );
    final String json = canvasJson(
      items: <String, Map<String, Object?>>{'item-1': shape('item-1')},
      itemOrder: <String>['item-1'],
    );

    canvas.replaceCanvasRows('n1', json);
    canvas.replaceCanvasRows('c2', json);

    expect(
      db
          .select("SELECT note_id FROM canvas_items WHERE id = 'item-1'")
          .map((Row r) => r['note_id'])
          .toSet(),
      <String>{'n1', 'c2'},
      reason: '同名的 item id 被后写的画布抢走了：主键必须是 (note_id, id)',
    );
  });

  test('经 NoteStore 的真实写入路径也会双写（画布笔记）', () async {
    final Note note = store.create(
      kind: NoteKind.canvas,
      content: canvasJson(
        items: <String, Map<String, Object?>>{'s1': shape('s1')},
        itemOrder: <String>['s1'],
      ),
    );
    expect(canvas.hasRows(note.id), isTrue);
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'], 1);

    // 保存新内容：行跟着更新（走 updateContent 的双写）。
    await store.updateContent(
      note.id,
      canvasJson(
        items: <String, Map<String, Object?>>{'s1': shape('s1'), 's2': shape('s2')},
        itemOrder: <String>['s1', 's2'],
      ),
      plainText: '',
    );
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'], 2);

    // 删画布笔记：外键级联清干净。
    await store.delete(note.id);
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'], 0);
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_meta').single['c'], 0);
    expect(db.select('SELECT COUNT(*) AS c FROM ink_shards').single['c'], 0);
  });

  test('文档笔记（v2 块树）不会在画布表里留行', () async {
    final Note note = store.create(content: blocksJson());
    expect(canvas.hasRows(note.id), isFalse);
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'], 0);
  });
}
