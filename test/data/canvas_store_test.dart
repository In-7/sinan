import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/data/canvas_store.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 画布落点的回归（2026-09-17，见 `docs/canvas_architecture.md` 第七章）。
///
/// **第 1 步（双写）**最该钉的不是"写进去了"，而是三件会悄悄坏掉的事：
/// 1. **格式门闩**：文档笔记的块树 / Delta / 空串都不能在画布表里留行
///    （留了就等于给两类笔记互相污染）；
/// 2. **判变**：同样的内容重复保存必须**一行都不写**，改一个 item 只重写那一行
///    （`created_at` 纹丝不动）——否则自动保存每次防抖都在写全表；
/// 3. **几何精度**：rect 存四条边，往返不能有浮点误差（第 3 步的深比较依赖它）。
///
/// **第 3 步（校验）**见文末 `group`：它最危险的不是"报错"，而是**静默失效**
/// ——该拦住的不一致没拦住，于是第 4 步切读会把坏数据当成真相读出来。
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

  /// 一张**卡片**（字段与存储契约逐项对齐，见 `CanvasStore` 的「卡片 JSON 契约」）。
  ///
  /// `text` 在存档 JSON 里是可见的（自包含、可读、可导出），落库时被拆到 `blocks`。
  Map<String, Object?> card(
    String id,
    String blockId,
    String text, {
    List<double>? rect,
  }) => <String, Object?>{
    'type': 'card',
    'id': id,
    'blockId': blockId,
    'text': text,
    'angle': 0.0,
    'rect': rect ?? <double>[0.0, 0.0, 120.0, 60.0],
    'meta': <String, Object?>{},
  };

  String canvasJson({
    Map<String, Map<String, Object?>> items = const {},
    List<String> itemOrder = const <String>[],
    Map<String, Map<String, Object?>> strokes = const {},
    List<String> strokeOrder = const <String>[],
    Map<String, Map<String, Object?>>? edges,
    double scale = 1.0,
    int schemaVersion = 2,
  }) {
    final Map<String, Object?> document = <String, Object?>{
      'schemaVersion': schemaVersion,
      'strokes': strokes,
      'items': items,
      'strokeOrder': strokeOrder,
      'itemOrder': itemOrder,
    };
    // 连线是**可选键**：与内核 toJson 同口径（为空则不写），
    // 传 null 即模拟"没有连线 / 旧存档"的形态。
    if (edges != null) document['edges'] = edges;
    return jsonEncode(<String, Object?>{
      'camera': <String, Object?>{
        'scale': scale,
        'translation': <double>[0.0, 0.0],
        // ⚠️ 与 `CanvasCamera.toJson` **逐项对齐**：真实存档总有这四个键。
        // 夹具少写这两个键 ⇒ 测不出"切读结果能否被内核吃下"。
        'minScale': 0.05,
        'maxScale': 4.0,
      },
      'document': document,
    });
  }

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

  group('第 3 步：校验（行 → JSON 深比较）', () {
    test('往返：相机 / schema 版本 / z 序 / 笔迹顺序全部还原', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          's1': shape('s1', rect: <double>[1.5, 2.5, 11.5, 22.5]),
          's2': shape('s2'),
        },
        itemOrder: <String>['s2', 's1'], // z 序：s2 在下
        strokes: <String, Map<String, Object?>>{'k1': stroke('k1', points: 3)},
        strokeOrder: <String>['k1'],
        scale: 2.0,
      );
      canvas.replaceCanvasRows('n1', json);

      expect(canvas.verifyCanvasRows('n1', json), isTrue);

      final String? rebuilt = canvas.readVerifiedCanvas('n1', json);
      expect(rebuilt, isNotNull);
      final Map<String, dynamic> got =
          (jsonDecode(rebuilt!) as Map).cast<String, dynamic>();
      final Map<String, dynamic> want =
          (jsonDecode(json) as Map).cast<String, dynamic>();
      expect(got['camera'], equals(want['camera']));
      final Map<String, dynamic> doc =
          (got['document'] as Map).cast<String, dynamic>();
      expect(doc['schemaVersion'], 2);
      // 顺序是有语义的（不是"集合相等"就行）。
      expect(doc['itemOrder'], equals(<String>['s2', 's1']));
      expect(doc['strokeOrder'], equals(<String>['k1']));
      expect((doc['items'] as Map)['s1'], isNotNull);
    });

    test('笔迹浮点精度：非精确坐标也能通过（blob 是 Float32，必须量化后比较）', () {
      // 1.1 / 2.3 在 Float32 里**无法精确表示**：存进 blob 再读回是
      // 1.100000023841858… 不量化的话，任何带笔迹的画布都会校验失败
      // ——而失败的表现是"永远回退 JSON"，切读永远不生效（静默）。
      final Map<String, Object?> wobbly = <String, Object?>{
        'id': 'k1',
        'version': 1,
        'color': 0xFF000000,
        'baseWidth': 4.0,
        'simulatePressure': true,
        'points': <List<double>>[
          <double>[1.1, 2.3, 0.7],
          <double>[1234.5678, -0.0001, 0.9999999],
        ],
      };
      final String json = canvasJson(
        strokes: <String, Map<String, Object?>>{'k1': wobbly},
        strokeOrder: <String>['k1'],
      );
      canvas.replaceCanvasRows('n1', json);

      expect(
        canvas.verifyCanvasRows('n1', json),
        isTrue,
        reason: 'Float32 往返误差让校验失效了：所有带笔迹的画布都会静默回退',
      );
    });

    test('media 侧表（派生、不落库）不参与比较', () {
      // 真实存档走 `toJson(media: _media)` ⇒ document 里带 media 清单；
      // 而它刻意不落库（真源是各 item 的 src），还原侧必然没有 ⇒ 必须剔除。
      final Map<String, Object?> doc =
          (jsonDecode(canvasJson(
                items: <String, Map<String, Object?>>{'s1': shape('s1')},
                itemOrder: <String>['s1'],
              )) as Map)
              .cast<String, Object?>();
      (doc['document'] as Map)['media'] = <String, Object?>{
        'media/a.png': <String, Object?>{'mime': 'image/png'},
      };
      final String json = jsonEncode(doc);
      canvas.replaceCanvasRows('n1', json);

      expect(
        canvas.verifyCanvasRows('n1', json),
        isTrue,
        reason: '派生侧表不该让校验失效',
      );
      // 还原结果里也不必带它（切读时按需重建）。
      final String rebuilt = canvas.readVerifiedCanvas('n1', json)!;
      expect((jsonDecode(rebuilt) as Map)['document'], isNot(contains('media')));
    });

    test('未落表（还没回填）→ false', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{'s1': shape('s1')},
        itemOrder: <String>['s1'],
      );
      // 刻意不调 replaceCanvasRows。
      expect(
        canvas.verifyCanvasRows('n1', json),
        isFalse,
        reason: '没落表不该算通过 —— 否则切读会拿到空画布覆盖原文',
      );
    });

    test('非画布内容 → false（与格式门闩同口径）', () {
      for (final String notCanvas in <String>[blocksJson(), '', '  ']) {
        expect(canvas.verifyCanvasRows('n1', notCanvas), isFalse);
      }
    });

    test('篡改几何 → 校验失败（第 4 步切读靠这条拦住坏数据）', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{'s1': shape('s1')},
        itemOrder: <String>['s1'],
      );
      canvas.replaceCanvasRows('n1', json);
      expect(canvas.verifyCanvasRows('n1', json), isTrue);

      db.execute("UPDATE canvas_items SET x1 = 999.0 WHERE id = 's1'");
      expect(canvas.verifyCanvasRows('n1', json), isFalse);
      expect(canvas.readVerifiedCanvas('n1', json), isNull);
    });

    test('丢了一个 item 行 → 校验失败（集合与顺序都变）', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          's1': shape('s1'),
          's2': shape('s2'),
        },
        itemOrder: <String>['s1', 's2'],
      );
      canvas.replaceCanvasRows('n1', json);
      expect(canvas.verifyCanvasRows('n1', json), isTrue);

      db.execute("DELETE FROM canvas_items WHERE id = 's2'");
      expect(
        canvas.verifyCanvasRows('n1', json),
        isFalse,
        reason: '少一行都该被拦住 —— 否则切读会静默丢掉用户的形状',
      );
    });

    test('z 序被改（两个 item 互换）→ 校验失败（顺序有语义）', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          's1': shape('s1'),
          's2': shape('s2'),
        },
        itemOrder: <String>['s1', 's2'],
      );
      canvas.replaceCanvasRows('n1', json);

      // 只互换 z，不动任何几何：内容集合完全相同，只有顺序不同。
      db.execute("UPDATE canvas_items SET z = 1 WHERE id = 's1'");
      db.execute("UPDATE canvas_items SET z = 0 WHERE id = 's2'");
      expect(
        canvas.verifyCanvasRows('n1', json),
        isFalse,
        reason: 'itemOrder 是数组，顺序有语义 —— 颠倒 z 序必须被拦住',
      );
    });

    test('切读（第 4 步）：noteById 返回从表还原的画布；校验不过则降落伞回退', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{'s1': shape('s1')},
        itemOrder: <String>['s1'],
        strokes: <String, Map<String, Object?>>{'k1': stroke('k1')},
        strokeOrder: <String>['k1'],
      );
      db.execute("UPDATE notes SET content = ? WHERE id = 'n1'", <Object?>[json]);
      canvas.replaceCanvasRows('n1', json);

      // ① 校验通过 ⇒ 走表。还原结果与原文**结构等价**（夹具不带 media）。
      final String? rebuilt = store.noteById('n1')?.content;
      expect(rebuilt, isNotNull);
      expect(jsonDecode(rebuilt!), equals(jsonDecode(json)));

      // ② 降落伞：把表改坏 ⇒ 静默回退 `notes.content`，绝不把坏数据交给 UI。
      db.execute("UPDATE canvas_items SET x1 = 999.0 WHERE id = 's1'");
      expect(
        store.noteById('n1')?.content,
        json,
        reason: '校验不过必须回退原文 —— 否则用户会看到画布被打回',
      );
    });

    test('切读互不干扰：文档笔记不会被画布投影抢走', () {
      db.execute("UPDATE notes SET kind = 'note', content = ? WHERE id = 'n1'",
          <Object?>[blocksJson()]);
      // 块树投影能还原 ⇒ 走 blocks；画布投影的格式门闩挡住 ⇒ 返回 null。
      expect(store.noteById('n1')?.content, isNotNull);
      expect(jsonDecode(store.noteById('n1')!.content), equals(jsonDecode(blocksJson())));
    });

    test('切读结果能被内核接受（真实存档带 media 侧表也照常反序列化）', () {
      // 真实存档走 `toJson(media: _media)` ⇒ 原文带 `media`；还原结果**没有**它
      // （派生、不落库）。内核必须能照常吃下这份"少了 media"的文档，
      // 否则切读等于把坏数据直接交给 UI。
      final Map<String, Object?> doc = (jsonDecode(canvasJson(
            items: <String, Map<String, Object?>>{'s1': shape('s1')},
            itemOrder: <String>['s1'],
            strokes: <String, Map<String, Object?>>{'k1': stroke('k1')},
            strokeOrder: <String>['k1'],
          )) as Map)
          .cast<String, Object?>();
      (doc['document'] as Map)['media'] = <String, Object?>{
        'media/a.png': <String, Object?>{'mime': 'image/png'},
      };
      final String json = jsonEncode(doc);
      db.execute("UPDATE notes SET content = ? WHERE id = 'n1'", <Object?>[json]);
      canvas.replaceCanvasRows('n1', json);

      final String rebuilt = store.noteById('n1')!.content;
      expect(rebuilt, isNot(contains('media')));
      expect(
        () => CanvasController.fromJson(
          (jsonDecode(rebuilt) as Map).cast<String, dynamic>(),
        ),
        returnsNormally,
        reason: '切读还原出的文档内核无法解析 —— 那等于把坏数据交给 UI',
      );
    });
  });

  group('卡片（v9）：内容进 blocks、几何进 canvas_items', () {
    test('投影：两半各就各位，block_id 把几何指向内容', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          'card-1': card('card-1', 'b1', '一个想法'),
        },
        itemOrder: <String>['card-1'],
      );
      canvas.replaceCanvasRows('n1', json);

      // 几何半边。
      final Row item = db
          .select(
            "SELECT kind, x2, y2, block_id FROM canvas_items WHERE id='card-1'",
          )
          .single;
      expect(item['kind'], 'card');
      expect(item['block_id'], 'b1');

      // 内容半边 —— 这才是"能被搜索 / 引用 / AI 索引"的关键
      // （`chunks_fts` 与 `index_state` 都建在 blocks 上）。
      final Row block =
          db.select("SELECT type, props_json FROM blocks WHERE id='b1'").single;
      expect(block['type'], 'card');
      expect(
        jsonDecode(block['props_json'] as String),
        <String, Object?>{'text': '一个想法'},
      );
    });

    test('校验往返：卡片文本原样还原（不是空字符串）', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          'card-1': card('card-1', 'b1', '一个想法'),
        },
        itemOrder: <String>['card-1'],
      );
      canvas.replaceCanvasRows('n1', json);

      expect(canvas.verifyCanvasRows('n1', json), isTrue);

      final String rebuilt = canvas.readVerifiedCanvas('n1', json)!;
      final Map<String, dynamic> items =
          (((jsonDecode(rebuilt) as Map)['document'] as Map)['items'] as Map)
              .cast<String, dynamic>();
      expect(
        (items['card-1'] as Map)['text'],
        '一个想法',
        reason: '内容半边没被拼回来：还原出的卡片是空的',
      );
    });

    test('内容丢了必须校验失败（分裂存储最危险的失败是静默丢内容）', () {
      // 危险在于"两边都看起来正常"：几何行还在、结构也对得上，只是文本没了。
      // 若校验放过它，切读会静默返回一框空白卡片 —— 用户以为想法还在。
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          'card-1': card('card-1', 'b1', '一个想法'),
        },
        itemOrder: <String>['card-1'],
      );
      canvas.replaceCanvasRows('n1', json);
      expect(canvas.verifyCanvasRows('n1', json), isTrue);

      db.execute("DELETE FROM blocks WHERE id='b1'");
      expect(
        canvas.verifyCanvasRows('n1', json),
        isFalse,
        reason: '内容半边丢了却校验通过 ⇒ 切读会静默返回空卡片',
      );
    });

    test('判变：改几何不重写内容；改文本才重写内容', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          'card-1': card('card-1', 'b1', '想法'),
        },
        itemOrder: <String>['card-1'],
      );
      canvas.replaceCanvasRows('n1', json);
      // ① 幂等。
      expect(canvas.replaceCanvasRows('n1', json), 0);

      // ② 只挪位置 ⇒ **只写几何那一行**，blocks 纹丝不动
      //    （否则拖一下卡片就会让 AI 索引以为内容变了）。
      expect(
        canvas.replaceCanvasRows(
          'n1',
          canvasJson(
            items: <String, Map<String, Object?>>{
              'card-1': card(
                'card-1',
                'b1',
                '想法',
                rect: <double>[50.0, 0.0, 170.0, 60.0],
              ),
            },
            itemOrder: <String>['card-1'],
          ),
        ),
        1,
        reason: '只改几何却重写了 blocks',
      );

      // ③ 改文本 ⇒ 内容行必写（几何行也因 fingerprint 覆盖整个 item 而重写）。
      expect(
        canvas.replaceCanvasRows(
          'n1',
          canvasJson(
            items: <String, Map<String, Object?>>{
              'card-1': card('card-1', 'b1', '新想法'),
            },
            itemOrder: <String>['card-1'],
          ),
        ),
        2,
      );
      expect(
        jsonDecode(
          db
              .select("SELECT props_json FROM blocks WHERE id='b1'")
              .single['props_json'] as String,
        ),
        <String, Object?>{'text': '新想法'},
      );
    });

    test('删卡片：几何与内容两半一起消失（不留孤儿）', () {
      canvas.replaceCanvasRows(
        'n1',
        canvasJson(
          items: <String, Map<String, Object?>>{
            'card-1': card('card-1', 'b1', '想法一'),
            'card-2': card('card-2', 'b2', '想法二'),
          },
          itemOrder: <String>['card-1', 'card-2'],
        ),
      );
      expect(db.select('SELECT COUNT(*) AS c FROM blocks').single['c'], 2);

      canvas.replaceCanvasRows(
        'n1',
        canvasJson(
          items: <String, Map<String, Object?>>{
            'card-1': card('card-1', 'b1', '想法一'),
          },
          itemOrder: <String>['card-1'],
        ),
      );

      expect(
        db.select('SELECT id FROM blocks').map((Row r) => r['id']).toSet(),
        <String>{'b1'},
        reason: '删掉的卡片在 blocks 里留了孤儿：搜得到却看不见',
      );
      expect(db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'], 1);
    });
  });

  group('连线（v9）：自由连线落 canvas_edges', () {
    test('落库 + 校验往返（端点存 id，不是坐标）', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          'card-1': card('card-1', 'b1', '想法一'),
          'card-2': card('card-2', 'b2', '想法二'),
        },
        itemOrder: <String>['card-1', 'card-2'],
        edges: <String, Map<String, Object?>>{
          'e1': <String, Object?>{
            'id': 'e1',
            'fromId': 'b1',
            'toId': 'b2',
            'fromSide': 'right',
            'toSide': 'left',
          },
        },
      );
      canvas.replaceCanvasRows('n1', json);

      final Row edge = db
          .select(
            'SELECT from_id, to_id, from_side, to_side FROM canvas_edges '
            "WHERE id='e1'",
          )
          .single;
      expect(edge['from_id'], 'b1');
      expect(edge['to_id'], 'b2');
      expect(edge['from_side'], 'right');
      expect(edge['to_side'], 'left');

      expect(
        canvas.verifyCanvasRows('n1', json),
        isTrue,
        reason: '连线没被还原 ⇒ 切读会静默丢掉连线',
      );
    });

    test('删掉卡片 ⇒ 连线随外键级联消失（binding 的数据库侧保证）', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          'card-1': card('card-1', 'b1', '想法一'),
          'card-2': card('card-2', 'b2', '想法二'),
        },
        itemOrder: <String>['card-1', 'card-2'],
        edges: <String, Map<String, Object?>>{
          'e1': <String, Object?>{'id': 'e1', 'fromId': 'b1', 'toId': 'b2'},
        },
      );
      canvas.replaceCanvasRows('n1', json);
      expect(db.select('SELECT COUNT(*) AS c FROM canvas_edges').single['c'], 1);

      db.execute("DELETE FROM blocks WHERE id='b2'");
      expect(
        db.select('SELECT COUNT(*) AS c FROM canvas_edges').single['c'],
        0,
        reason: '卡片没了却留下指向它的连线（悬空边）',
      );
    });

    test('端点形状（2026-09-18）存 props 扩展位、往返深比较通过', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          'card-1': card('card-1', 'b1', '想法一'),
          'card-2': card('card-2', 'b2', '想法二'),
        },
        itemOrder: <String>['card-1', 'card-2'],
        edges: <String, Map<String, Object?>>{
          'e1': <String, Object?>{
            'id': 'e1',
            'fromId': 'b1',
            'toId': 'b2',
            'startShape': 'dot',
            'endShape': 'diamond',
          },
        },
      );
      expect(canvas.replaceCanvasRows('n1', json), greaterThan(0));
      // 形状走 props_json，必须深比较通过，否则切读静默丢连线。
      expect(canvas.verifyCanvasRows('n1', json), isTrue);
      // 还原出的连线确实带着两端形状。
      final Map<String, Object?> edges =
          (jsonDecode(canvas.readVerifiedCanvas('n1', json)!)
                  as Map<String, Object?>)['document']
              as Map<String, Object?>;
      final Map<String, Object?> e =
          (edges['edges']! as Map<String, Object?>)
              .cast<String, Object?>()['e1']! as Map<String, Object?>;
      expect(e['startShape'], 'dot');
      expect(e['endShape'], 'diamond');
    });

    test('老画布（无端点形状键）照常校验通过', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          'card-1': card('card-1', 'b1', '想法一'),
          'card-2': card('card-2', 'b2', '想法二'),
        },
        itemOrder: <String>['card-1', 'card-2'],
        edges: <String, Map<String, Object?>>{
          'e1': <String, Object?>{'id': 'e1', 'fromId': 'b1', 'toId': 'b2'},
        },
      );
      canvas.replaceCanvasRows('n1', json);
      expect(canvas.verifyCanvasRows('n1', json), isTrue);
    });

    test('没有连线 ⇒ 两边都不含 edges 键，老画布照样校验通过', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          'card-1': card('card-1', 'b1', '想法'),
        },
        itemOrder: <String>['card-1'],
      );
      canvas.replaceCanvasRows('n1', json);

      expect(
        (jsonDecode(json) as Map)['document'],
        isNot(contains('edges')),
      );
      expect(canvas.verifyCanvasRows('n1', json), isTrue);
      // 还原结果也不该凭空多出这个键 —— 否则**所有**老画布都会静默回退 JSON
      // （原文无 edges、还原有 edges {} ⇒ 深比较判为不一致）。
      final Map<String, dynamic> rebuiltDoc =
          (jsonDecode(canvas.readVerifiedCanvas('n1', json)!) as Map)['document']
              as Map<String, dynamic>;
      expect(rebuiltDoc, isNot(contains('edges')));
    });
  });

  group('思维导图（MindMapItem）', () {
    /// 一条 mindmap item（字段与 `MindMapItem.toJson` 逐项对齐）。
    Map<String, Object?> mindmap(String id, {List<double>? rect}) => <String, Object?>{
      'type': 'mindmap',
      'id': id,
      'angle': 0.0,
      'rect': rect ?? <double>[0.0, 0.0, 300.0, 200.0],
      'nodes': <String, Object?>{
        'id': 'mn-root',
        'text': '中心主题',
        'children': <Object?>[
          <String, Object?>{'id': 'mn-a', 'text': '分支一'},
          <String, Object?>{'id': 'mn-b', 'text': '分支二'},
        ],
      },
      'meta': <String, Object?>{},
    };

    test('投影 + 校验通过（节点树走 props 扩展位）', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{'m1': mindmap('m1')},
        itemOrder: <String>['m1'],
      );
      expect(canvas.replaceCanvasRows('n1', json), greaterThan(0));
      // 关键：深比较必须通过 —— 不通过会**静默回退 JSON**（不报错、切读永不生效）。
      expect(canvas.verifyCanvasRows('n1', json), isTrue);
    });

    test('判变：重复保存同一张思维导图不再写行', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{'m1': mindmap('m1')},
        itemOrder: <String>['m1'],
      );
      expect(canvas.replaceCanvasRows('n1', json), greaterThan(0));
      expect(canvas.replaceCanvasRows('n1', json), 0);
    });

    test('改一个节点文本 ⇒ 重写该 item 行、created_at 不动、校验仍通过', () {
      final String json1 = canvasJson(
        items: <String, Map<String, Object?>>{'m1': mindmap('m1')},
        itemOrder: <String>['m1'],
      );
      canvas.replaceCanvasRows('n1', json1);
      final int createdBefore =
          db
                  .select(
                    'SELECT created_at FROM canvas_items WHERE note_id = ? AND id = ?',
                    <Object?>['n1', 'm1'],
                  )
                  .single['created_at']
              as int;

      final Map<String, Object?> changed = mindmap('m1');
      (((changed['nodes']! as Map<String, Object?>)['children']!)
              as List<Object?>)[0] =
          <String, Object?>{'id': 'mn-a', 'text': '改过的分支'};
      final String json2 = canvasJson(
        items: <String, Map<String, Object?>>{'m1': changed},
        itemOrder: <String>['m1'],
      );

      expect(canvas.replaceCanvasRows('n1', json2), greaterThan(0));
      expect(canvas.verifyCanvasRows('n1', json2), isTrue);
      // created_at 只在**首次**落行时写（与 blocks 侧判变口径一致）。
      expect(
        db
            .select(
              'SELECT created_at FROM canvas_items WHERE note_id = ? AND id = ?',
              <Object?>['n1', 'm1'],
            )
            .single['created_at'],
        createdBefore,
      );
    });

    test('语义色槽位（colorSlot）：写入扩展位、还原、深比较通过', () {
      final Map<String, Object?> marked = mindmap('m1');
      marked['colorSlot'] = 'green';
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{'m1': marked},
        itemOrder: <String>['m1'],
      );
      expect(canvas.replaceCanvasRows('n1', json), greaterThan(0));
      // 关键：不通过会**静默回退 JSON**（不报错、切读永不生效）。
      expect(canvas.verifyCanvasRows('n1', json), isTrue);
    });
  });

  group('分组框（CanvasGroupItem，2026-09-18）', () {
    /// 一条分组框（字段与 `CanvasGroupItem.toJson` 逐项对齐：空 label / 空 slot /
    /// 空 groupId 都不写键，否则深比较会差键 ⇒ 静默回退 JSON）。
    Map<String, Object?> group(
      String id, {
      String? label,
      String? colorSlot,
      String? groupId,
      List<double>? rect,
    }) =>
        <String, Object?>{
          'type': 'group',
          'id': id,
          'angle': 0.0,
          'rect': rect ?? <double>[0.0, 0.0, 400.0, 300.0],
          'label': ?label,
          'colorSlot': ?colorSlot,
          'groupId': ?groupId,
          'meta': <String, Object?>{},
        };

    test('投影 + 校验通过（label / colorSlot / groupId 走 props 扩展位）', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          'g1': group('g1', label: '需求', colorSlot: 'blue'),
        },
        itemOrder: <String>['g1'],
      );
      expect(canvas.replaceCanvasRows('n1', json), greaterThan(0));
      expect(canvas.verifyCanvasRows('n1', json), isTrue);
    });

    test('空 label ⇒ 不写 label 键，深处仍一致', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          'g1': group('g1'), // 无 label / colorSlot / groupId
        },
        itemOrder: <String>['g1'],
      );
      expect(canvas.replaceCanvasRows('n1', json), greaterThan(0));
      expect(canvas.verifyCanvasRows('n1', json), isTrue);
    });

    test('成员 item 的 groupId 透传：还原后指向分组框、深处一致', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          'g1': group('g1', label: '分组'),
          'c1': <String, Object?>{
            'type': 'card',
            'id': 'c1',
            'blockId': 'b-c1',
            'text': '框里的卡片',
            'angle': 0.0,
            'rect': <double>[10.0, 10.0, 110.0, 50.0],
            'groupId': 'g1', // 成员指向分组框
            'meta': <String, Object?>{},
          },
        },
        itemOrder: <String>['g1', 'c1'],
      );
      expect(canvas.replaceCanvasRows('n1', json), greaterThan(0));
      expect(canvas.verifyCanvasRows('n1', json), isTrue);
      // 还原出的 card 必须带着 groupId（否则分组关系在表侧丢失）。
      final Map<String, Object?> rebuilt =
          (jsonDecode(canvas.readVerifiedCanvas('n1', json)!)
                  as Map)['document']
              as Map<String, Object?>;
      final Map<String, Object?> items =
          (rebuilt['items']! as Map).cast<String, Object?>();
      expect((items['c1']! as Map)['groupId'], 'g1');
      expect((items['g1']! as Map)['type'], 'group');
    });
  });
}
