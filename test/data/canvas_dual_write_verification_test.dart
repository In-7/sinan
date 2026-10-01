import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/data/canvas_store.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// `canvas_items`（连同 canvas_edges / canvas_meta / ink_shards / 卡片 blocks）
/// **双写读路径的全面验证**（2026-10-01）。
///
/// 架构现状见 `CanvasStore` 类文档：写路径在 `notes.content` 落 JSON 的同时把行投影
/// 一份（双写）；读路径 `NoteStore.noteById` 先信行、行还原与原文深比较不过则降落伞
/// 回退 JSON。本文件按六个维度把这条链路钉死：
///
///   A 完整性 ：每一种 item 类型的行 ⇄ JSON 往返都不丢字段（补 rect 之外类型的空白）；
///   B 读最新 ：任意一轮增量保存后，切读拿到的必须是**这一轮**的内容；
///   C 负载并发：单连接串行模型下的高频 / 交错 / 大文档 / 事务重入；
///   D 异常同步：投影事务失败时「新 JSON + 旧行」必须靠降落伞安全、下次保存自愈；
///   E 回填 ：存量库补行后，逐张深比较必须通过（不是只数行数）；
///   F 级联 ：删笔记 / 删块时几何、连线、内容、墨迹不残留孤儿。
///
/// 夹具字段与内核 `*Item.toJson` 逐项对齐（存储层只认 JSON，格式权威在内核）。
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
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES ('n1','canvas','','','fp1:0:0','',1,1)",
    );
  });

  tearDown(() => db.close());

  // ── 夹具 ───────────────────────────────────────────────────────────

  Map<String, Object?> shape(
    String id, {
    String kind = 'rectangle',
    List<double>? rect,
    int color = 0xFF1F1F1F,
    double angle = 0.0,
  }) => <String, Object?>{
    'type': 'shape',
    'id': id,
    'kind': kind,
    'color': color,
    'strokeWidth': 2.0,
    'filled': false,
    'angle': angle,
    'rect': rect ?? <double>[0.0, 0.0, 10.0, 20.0],
    'meta': <String, Object?>{},
  };

  Map<String, Object?> image(
    String id, {
    List<double>? rect,
    double angle = 0.0,
  }) => <String, Object?>{
    'type': 'image',
    'id': id,
    'angle': angle,
    'rect': rect ?? <double>[0.0, 0.0, 100.0, 80.0],
    'src': 'media/$id.png',
    'meta': <String, Object?>{},
  };

  Map<String, Object?> aiImage(String id) => <String, Object?>{
    'type': 'aiImage',
    'id': id,
    'angle': 0.0,
    'rect': <double>[0.0, 0.0, 100.0, 80.0],
    'src': 'media/$id.png',
    // gen 对存储层是不透明扩展对象（原样进 props_json、原样还原）。
    'gen': <String, Object?>{'model': 'sdxl', 'prompt': '一只猫', 'seed': 42},
    'meta': <String, Object?>{},
  };

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

  Map<String, Object?> edge(String id, String from, String to) =>
      <String, Object?>{'id': id, 'fromId': from, 'toId': to};

  String canvasJson({
    Map<String, Map<String, Object?>> items = const {},
    List<String> itemOrder = const <String>[],
    Map<String, Map<String, Object?>> strokes = const {},
    List<String> strokeOrder = const <String>[],
    Map<String, Map<String, Object?>>? edges,
    double scale = 1.0,
  }) {
    final Map<String, Object?> document = <String, Object?>{
      'schemaVersion': 2,
      'strokes': strokes,
      'items': items,
      'strokeOrder': strokeOrder,
      'itemOrder': itemOrder,
    };
    if (edges != null) document['edges'] = edges;
    return jsonEncode(<String, Object?>{
      'camera': <String, Object?>{
        'scale': scale,
        'translation': <double>[0.0, 0.0],
        'minScale': 0.05,
        'maxScale': 4.0,
      },
      'document': document,
    });
  }

  /// 切读结果与给定 JSON **结构等价**（行还原出的文档必须能代替原文）。
  ///
  /// 注意先把 JSON 落进 `notes.content`：镜像 `NoteStore.updateContent` 的真实
  /// 写盘顺序（JSON 先落、投影后写）。直接调 CanvasStore 投影不会替我们写这列。
  void expectReadEquals(String savedJson) {
    db.execute('UPDATE notes SET content = ? WHERE id = ?', <Object?>[
      savedJson,
      'n1',
    ]);
    expect(canvas.verifyCanvasRows('n1', savedJson), isTrue);
    expect(
      jsonDecode(store.noteById('n1')!.content),
      equals(jsonDecode(savedJson)),
      reason: '切读拿到的不是这一轮保存的内容',
    );
  }

  int countOf(String table, {String? where, List<Object?> args = const []}) =>
      db
              .select('SELECT COUNT(*) AS c FROM $table ${where ?? ''}', args)
              .single['c']
          as int;

  // ── A. 双写完整性：每一种 item 类型的往返 ────────────────────────────

  group('A 双写完整性', () {
    test('A1 椭圆：kind 两级判别拍平与还原', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          'o1': shape('o1', kind: 'ellipse'),
        },
        itemOrder: <String>['o1'],
      );
      canvas.replaceCanvasRows('n1', json);
      expect(countOf('canvas_items'), 1);
      expect(
        db.select('SELECT kind FROM canvas_items').single['kind'],
        'shape.ellipse',
      );
      expect(canvas.verifyCanvasRows('n1', json), isTrue);
      final Map<String, Object?> doc =
          (jsonDecode(canvas.readVerifiedCanvas('n1', json)!)
                  as Map)['document']
              as Map<String, Object?>;
      final Map<String, Object?> rebuiltItems =
          doc['items']! as Map<String, Object?>;
      expect((rebuiltItems['o1']! as Map)['kind'], 'ellipse');
      expect((rebuiltItems['o1']! as Map)['type'], 'shape');
    });

    test('A2 图片：src 相对引用、angle 往返', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{'i1': image('i1', angle: 0.7)},
        itemOrder: <String>['i1'],
      );
      canvas.replaceCanvasRows('n1', json);
      final Row row = db
          .select('SELECT kind, src, angle FROM canvas_items')
          .single;
      expect(row['kind'], 'image');
      expect(row['src'], 'media/i1.png');
      expect(row['angle'], closeTo(0.7, 1e-12));
      expect(canvas.verifyCanvasRows('n1', json), isTrue);
    });

    test('A3 AI 图片：gen 配方原样往返（存储层不解释）', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{'a1': aiImage('a1')},
        itemOrder: <String>['a1'],
      );
      canvas.replaceCanvasRows('n1', json);
      expect(
        db.select('SELECT kind FROM canvas_items').single['kind'],
        'ai_image',
      );
      expect(canvas.verifyCanvasRows('n1', json), isTrue);
      final Map<String, Object?> rebuilt =
          (((jsonDecode(canvas.readVerifiedCanvas('n1', json)!)
                          as Map)['document']
                      as Map)['items']!
                  as Map)['a1']!
              as Map<String, Object?>;
      expect(rebuilt['type'], 'aiImage');
      expect((rebuilt['gen']! as Map)['prompt'], '一只猫');
      expect((rebuilt['gen']! as Map)['seed'], 42);
    });

    test('A4 全家福：形状×2 + 图片×2 + 卡片 + 连线 + 笔迹，一次往返且内核能吃下', () {
      final String json = canvasJson(
        items: <String, Map<String, Object?>>{
          'r1': shape('r1', rect: <double>[1.5, 2.5, 11.5, 22.5]),
          'o1': shape('o1', kind: 'ellipse', rect: <double>[0, 0, 7, 9]),
          'i1': image('i1'),
          'a1': aiImage('a1'),
          'c1': card('c1', 'b1', '想法一', rect: <double>[0, 0, 50, 40]),
          'c2': card('c2', 'b2', '想法二', rect: <double>[80, 0, 130, 40]),
        },
        itemOrder: <String>['r1', 'o1', 'i1', 'a1', 'c1', 'c2'],
        strokes: <String, Map<String, Object?>>{'k1': stroke('k1', points: 3)},
        strokeOrder: <String>['k1'],
        edges: <String, Map<String, Object?>>{'e1': edge('e1', 'b1', 'b2')},
        scale: 1.5,
      );
      canvas.replaceCanvasRows('n1', json);

      // 六行 item、一条边、一片墨迹、两个卡片内容块、一行 meta。
      expect(countOf('canvas_items'), 6);
      expect(countOf('canvas_edges'), 1);
      expect(countOf('ink_shards'), 1);
      expect(countOf('blocks'), 2);
      expect(countOf('canvas_meta'), 1);
      expect(canvas.verifyCanvasRows('n1', json), isTrue);

      // 镜像 NoteStore 写盘顺序：JSON 先落 notes.content，切读才有原文可比。
      db.execute('UPDATE notes SET content = ? WHERE id = ?', <Object?>[
        json,
        'n1',
      ]);
      final String rebuilt = store.noteById('n1')!.content;
      expect(jsonDecode(rebuilt), equals(jsonDecode(json)));
      expect(
        () => CanvasController.fromJson(
          (jsonDecode(rebuilt) as Map).cast<String, dynamic>(),
        ),
        returnsNormally,
        reason: '行还原的全家福文档内核无法解析',
      );
    });
  });

  // ── B. 读路径必须拿到最新数据（每一轮增量保存后立刻切读）──────────────

  group('B 读路径最新数据', () {
    test('B1 连续多轮编辑：新增→挪动→改色→删除，每轮切读都等于该轮 JSON', () {
      String round(
        Map<String, Map<String, Object?>> items,
        List<String> order,
      ) => canvasJson(items: items, itemOrder: order);

      // 第 0 轮：一个矩形。
      String j = round(
        <String, Map<String, Object?>>{'s1': shape('s1')},
        <String>['s1'],
      );
      expect(canvas.replaceCanvasRows('n1', j), greaterThan(0));
      expectReadEquals(j);

      // 第 1 轮：加一个椭圆。
      j = round(
        <String, Map<String, Object?>>{
          's1': shape('s1'),
          'o1': shape('o1', kind: 'ellipse'),
        },
        <String>['s1', 'o1'],
      );
      canvas.replaceCanvasRows('n1', j);
      expectReadEquals(j);

      // 第 2 轮：挪动 s1（只重写 s1 行）。
      j = round(
        <String, Map<String, Object?>>{
          's1': shape('s1', rect: <double>[50, 60, 60, 80]),
          'o1': shape('o1', kind: 'ellipse'),
        },
        <String>['s1', 'o1'],
      );
      canvas.replaceCanvasRows('n1', j);
      expectReadEquals(j);

      // 第 3 轮：给 s1 改色。
      j = round(
        <String, Map<String, Object?>>{
          's1': shape('s1', rect: <double>[50, 60, 60, 80], color: 0xFFFF0000),
          'o1': shape('o1', kind: 'ellipse'),
        },
        <String>['s1', 'o1'],
      );
      canvas.replaceCanvasRows('n1', j);
      expectReadEquals(j);

      // 第 4 轮：删掉椭圆。
      j = round(
        <String, Map<String, Object?>>{
          's1': shape('s1', rect: <double>[50, 60, 60, 80], color: 0xFFFF0000),
        },
        <String>['s1'],
      );
      canvas.replaceCanvasRows('n1', j);
      expectReadEquals(j);
      expect(countOf('canvas_items'), 1);
    });

    test('B2 只改相机：meta 行更新，切读拿到新 scale', () {
      final String j1 = canvasJson(
        items: <String, Map<String, Object?>>{'s1': shape('s1')},
        itemOrder: <String>['s1'],
      );
      canvas.replaceCanvasRows('n1', j1);

      final String j2 = canvasJson(
        items: <String, Map<String, Object?>>{'s1': shape('s1')},
        itemOrder: <String>['s1'],
        scale: 3.25,
      );
      // item 一个没动 ⇒ 只有 meta 一行变化。
      expect(canvas.replaceCanvasRows('n1', j2), 1);
      final Map<String, Object?> camera = jsonDecode(
        db.select('SELECT camera_json FROM canvas_meta').single['camera_json']
            as String,
      ) as Map<String, Object?>;
      expect(camera['scale'], 3.25);
      expectReadEquals(j2);
    });

    test('B3 笔迹跨分片缩容：300 → 10 笔时尾分片被删，切读仍一致', () {
      Map<String, Map<String, Object?>> strokesOf(int n) =>
          <String, Map<String, Object?>>{
            for (int i = 0; i < n; i++) 'k$i': stroke('k$i'),
          };

      final String big = canvasJson(
        strokes: strokesOf(300),
        strokeOrder: <String>[for (int i = 0; i < 300; i++) 'k$i'],
      );
      canvas.replaceCanvasRows('n1', big);
      expect(countOf('ink_shards'), 2);

      final String small = canvasJson(
        strokes: strokesOf(10),
        strokeOrder: <String>[for (int i = 0; i < 10; i++) 'k$i'],
      );
      // 片 0 内容变了要重写、片 1 整体消失要删（+ meta：笔迹 id 集合变了）。
      expect(canvas.replaceCanvasRows('n1', small), greaterThan(0));
      expect(
        db
            .select('SELECT shard_index FROM ink_shards ORDER BY shard_index')
            .map((Row r) => r['shard_index']),
        <int>[0],
        reason: '缩容后尾分片残留 = 删掉的笔迹还在表里',
      );
      expectReadEquals(small);
    });

    test('B4 连线增删：切读跟随最新边集合', () {
      Map<String, Map<String, Object?>> items() =>
          <String, Map<String, Object?>>{
            'c1': card('c1', 'b1', '一'),
            'c2': card('c2', 'b2', '二'),
          };

      final String none = canvasJson(
        items: items(),
        itemOrder: <String>['c1', 'c2'],
      );
      canvas.replaceCanvasRows('n1', none);
      expect(countOf('canvas_edges'), 0);

      final String linked = canvasJson(
        items: items(),
        itemOrder: <String>['c1', 'c2'],
        edges: <String, Map<String, Object?>>{'e1': edge('e1', 'b1', 'b2')},
      );
      canvas.replaceCanvasRows('n1', linked);
      expect(countOf('canvas_edges'), 1);
      expectReadEquals(linked);

      // 再删掉连线。
      canvas.replaceCanvasRows('n1', none);
      expect(countOf('canvas_edges'), 0);
      expectReadEquals(none);
    });

    test('B5 回填补齐后，切读立即返回与原文等价的内容', () {
      final String legacy = canvasJson(
        items: <String, Map<String, Object?>>{'s1': shape('s1')},
        itemOrder: <String>['s1'],
        strokes: <String, Map<String, Object?>>{'k1': stroke('k1')},
        strokeOrder: <String>['k1'],
        scale: 2.0,
      );
      db.execute(
        'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
        "created_at, revised_at) VALUES ('c9','canvas','',?, 'fp1:1:x','',2,2)",
        <Object?>[legacy],
      );
      expect(store.backfillCanvas(), 1);
      expect(
        jsonDecode(store.noteById('c9')!.content),
        equals(jsonDecode(legacy)),
        reason: '回填后切读拿不到回填的内容',
      );
    });
  });

  // ── C. 负载与串行并发（sqlite3 单连接：调用天然串行，原子性靠事务）─────

  group('C 负载与并发', () {
    test('C1 高频自动保存 80 轮：每轮都改一点，行始终可还原、无漂移', () {
      for (int i = 0; i < 80; i++) {
        final String j = canvasJson(
          items: <String, Map<String, Object?>>{
            's1': shape('s1', rect: <double>[i * 1.0, 0, i + 10.0, 20]),
            's2': shape('s2'),
          },
          itemOrder: <String>['s1', 's2'],
          strokes: <String, Map<String, Object?>>{'k1': stroke('k1')},
          strokeOrder: <String>['k1'],
        );
        canvas.replaceCanvasRows('n1', j);
        if (i % 10 == 0) {
          // 每轮都做深比较太贵；每 10 轮 + 最后一轮强校验，中间靠判变计数隐式保证。
          expect(
            canvas.verifyCanvasRows('n1', j),
            isTrue,
            reason: '第 $i 轮自动保存后行与 JSON 漂移了',
          );
        }
      }
      final String last = canvasJson(
        items: <String, Map<String, Object?>>{
          's1': shape('s1', rect: <double>[79.0, 0, 89.0, 20]),
          's2': shape('s2'),
        },
        itemOrder: <String>['s1', 's2'],
        strokes: <String, Map<String, Object?>>{'k1': stroke('k1')},
        strokeOrder: <String>['k1'],
      );
      expectReadEquals(last);
    });

    test('C2 20 张画布交错保存、同名 item id 互不串号', () {
      for (int c = 0; c < 20; c++) {
        db.execute(
          'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
          "created_at, revised_at) VALUES (?,?, '', '', 'fp1:0:0', '', ?, ?)",
          <Object?>['cv$c', 'canvas', c, c],
        );
      }

      String contentOf(int c) => canvasJson(
        items: <String, Map<String, Object?>>{
          // 每张画布都用同一批内核自增 id（item-0/item-1）——靠 (note_id,id) 主键隔离。
          'item-0': shape(
            'item-0',
            rect: <double>[c * 3.0, 0, c * 3.0 + 10, 20],
          ),
          'item-1': shape('item-1'),
        },
        itemOrder: <String>['item-0', 'item-1'],
      );

      // 三轮交错写（模拟多标签页轮流自动保存）。
      for (int round = 0; round < 3; round++) {
        for (int c = 0; c < 20; c++) {
          expect(
            canvas.replaceCanvasRows('cv$c', contentOf(c)),
            round == 0 ? greaterThan(0) : 0,
            reason: '同内容重复保存应判变为 0',
          );
        }
      }

      expect(countOf('canvas_items'), 40);
      for (int c = 0; c < 20; c++) {
        final String j = contentOf(c);
        expect(
          canvas.verifyCanvasRows('cv$c', j),
          isTrue,
          reason: '画布 cv$c 被别的画布串号了',
        );
        final num x1 =
            db.select(
                  "SELECT x1 FROM canvas_items WHERE note_id = ? AND id = 'item-0'",
                  <Object?>['cv$c'],
                ).single['x1']
                as num;
        expect(x1, c * 3.0);
      }
    });

    test('C3 大画布：500 item + 600 笔（3 分片）往返，二次保存零写入', () {
      final Map<String, Map<String, Object?>> items =
          <String, Map<String, Object?>>{
            for (int i = 0; i < 500; i++)
              's$i': shape(
                's$i',
                kind: i.isEven ? 'rectangle' : 'ellipse',
                rect: <double>[i * 2.0, 0, i * 2.0 + 5, 8],
              ),
          };
      final Map<String, Map<String, Object?>> strokes =
          <String, Map<String, Object?>>{
            for (int i = 0; i < 600; i++) 'k$i': stroke('k$i'),
          };
      final String big = canvasJson(
        items: items,
        itemOrder: <String>[for (int i = 0; i < 500; i++) 's$i'],
        strokes: strokes,
        strokeOrder: <String>[for (int i = 0; i < 600; i++) 'k$i'],
      );

      expect(canvas.replaceCanvasRows('n1', big), greaterThan(0));
      expect(countOf('canvas_items'), 500);
      expect(countOf('ink_shards'), 3); // ceil(600/256)
      expect(canvas.verifyCanvasRows('n1', big), isTrue);

      // 防抖再来一次：判变必须拦住全部 500+3 行（写放大红线）。
      expect(canvas.replaceCanvasRows('n1', big), 0, reason: '大画布重复保存产生了写放大');

      // 改一个 item：只动该 item + meta（z 序集合没变，几何行一行）。
      final Map<String, Map<String, Object?>> moved =
          Map<String, Map<String, Object?>>.of(items);
      moved['s250'] = shape('s250', rect: <double>[-100, -100, -90, -90]);
      final String big2 = canvasJson(
        items: moved,
        itemOrder: <String>[for (int i = 0; i < 500; i++) 's$i'],
        strokes: strokes,
        strokeOrder: <String>[for (int i = 0; i < 600; i++) 'k$i'],
      );
      expect(canvas.replaceCanvasRows('n1', big2), 1);
      expect(canvas.verifyCanvasRows('n1', big2), isTrue);
    });

    test('C4 事务重入：投影在未提交事务中失败时不留半行写入', () {
      final String base = canvasJson(
        items: <String, Map<String, Object?>>{'s1': shape('s1')},
        itemOrder: <String>['s1'],
      );
      canvas.replaceCanvasRows('n1', base);

      // 调用方（或重入）留了一个未提交事务 ⇒ 投影自己的 BEGIN 必然失败。
      db.execute('BEGIN;');
      expect(
        () => canvas.replaceCanvasRows(
          'n1',
          canvasJson(
            items: <String, Map<String, Object?>>{
              's1': shape('s1'),
              's2': shape('s2'),
            },
            itemOrder: <String>['s1', 's2'],
          ),
        ),
        throwsA(isA<SqliteException>()),
      );
      // 投影 catch 里的 ROLLBACK 已把（外层空）事务结束。新 item 半行都不能落库。
      expect(countOf('canvas_items'), 1);
      expect(
        db
            .select('SELECT id FROM canvas_items')
            .map((Row r) => r['id'])
            .toList(),
        <String>['s1'],
      );
      // 库已回到自动提交：紧接着一次正常保存必须成功（无残留锁 / 残留事务）。
      expect(canvas.replaceCanvasRows('n1', base), 0);
    });
  });

  // ── D. 异常场景：事务原子性、降落伞、自愈 ────────────────────────────

  group('D 异常场景数据同步', () {
    test('D1 连线外键失败 → 整笔回滚；JSON 已新行仍旧时降落伞回退；下次保存自愈', () async {
      // 基线：两张卡片、没有连线，行与 JSON 一致。
      final String base = canvasJson(
        items: <String, Map<String, Object?>>{
          'c1': card('c1', 'b1', '一'),
          'c2': card('c2', 'b2', '二'),
        },
        itemOrder: <String>['c1', 'c2'],
      );
      expect(canvas.replaceCanvasRows('n1', base), greaterThan(0));
      expect(countOf('canvas_edges'), 0);

      // 坏保存：连线指向一个不存在的块 b99。edges 插入违反外键。
      final String broken = canvasJson(
        items: <String, Map<String, Object?>>{
          'c1': card('c1', 'b1', '一'),
          'c2': card('c2', 'b2', '二'),
        },
        itemOrder: <String>['c1', 'c2'],
        edges: <String, Map<String, Object?>>{'e1': edge('e1', 'b1', 'b99')},
      );
      await expectLater(
        store.updateContent('n1', broken, plainText: ''),
        throwsA(isA<SqliteException>()),
      );

      // ① notes.content 的更新在投影事务**之外**（见 NoteStore.updateContent）：
      //    JSON 已经是新的，但行整笔回滚到旧状态。
      expect(
        db.select('SELECT content FROM notes WHERE id = ?', <Object?>[
          'n1',
        ]).single['content'],
        broken,
      );
      expect(countOf('canvas_edges'), 0, reason: '回滚后不该留下坏连线');
      expect(countOf('canvas_items'), 2);

      // ② 降落伞：行（旧）与 JSON（新）深比较不过 ⇒ 切读回退原文，
      //    用户看到的仍是刚画完的完整画布，而不是被打回的旧版本。
      expect(
        canvas.verifyCanvasRows('n1', broken),
        isFalse,
        reason: '旧行与新 JSON 本就不该校验通过',
      );
      expect(store.noteById('n1')!.content, broken);

      // ③ 自愈：下一次合法保存（连线指向真实的 b2）把行收敛到最新。
      final String healed = canvasJson(
        items: <String, Map<String, Object?>>{
          'c1': card('c1', 'b1', '一'),
          'c2': card('c2', 'b2', '二'),
        },
        itemOrder: <String>['c1', 'c2'],
        edges: <String, Map<String, Object?>>{'e1': edge('e1', 'b1', 'b2')},
      );
      expect(await store.updateContent('n1', healed, plainText: ''), isTrue);
      expect(countOf('canvas_edges'), 1);
      expect(canvas.verifyCanvasRows('n1', healed), isTrue);
      expect(
        jsonDecode(store.noteById('n1')!.content),
        equals(jsonDecode(healed)),
      );
    });

    test('D2 坏 item（非对象 / rect 残缺）被跳过：投影不炸，校验拦截、读回退', () {
      final Map<String, Object?> raw = (jsonDecode(
        canvasJson(
          items: <String, Map<String, Object?>>{'s1': shape('s1')},
          itemOrder: <String>['s1'],
        ),
      ) as Map).cast<String, Object?>();
      final Map<String, Object?> document = (raw['document']! as Map)
          .cast<String, Object?>();
      final Map<String, Object?> items = (document['items']! as Map)
          .cast<String, Object?>();
      // 两种坏数据：值不是对象；对象缺 rect。
      items['bad1'] = 'not-an-item';
      items['bad2'] = <String, Object?>{'type': 'shape'};
      (document['itemOrder']! as List<Object?>).addAll(<String>[
        'bad1',
        'bad2',
      ]);
      final String dirty = jsonEncode(raw);

      expect(() => canvas.replaceCanvasRows('n1', dirty), returnsNormally);
      // 只有合法的 s1 落了行。
      expect(
        db
            .select('SELECT id FROM canvas_items')
            .map((Row r) => r['id'])
            .toList(),
        <String>['s1'],
      );
      // 行比原文少两个 item ⇒ 深比较必败 ⇒ 切读回退原文（绝不把缺 item 的版本给 UI）。
      // （同样镜像真实写盘：坏 JSON 已在 notes.content，行是它的不完整投影。）
      db.execute('UPDATE notes SET content = ? WHERE id = ?', <Object?>[
        dirty,
        'n1',
      ]);
      expect(canvas.verifyCanvasRows('n1', dirty), isFalse);
      expect(canvas.readVerifiedCanvas('n1', dirty), isNull);
      expect(store.noteById('n1')!.content, dirty);
    });

    test('D3 meta 的 camera_json 类型损坏（合法 JSON 但不是对象）→ 判不可读，降落伞回退', () {
      final String j = canvasJson(
        items: <String, Map<String, Object?>>{'s1': shape('s1')},
        itemOrder: <String>['s1'],
      );
      db.execute('UPDATE notes SET content = ? WHERE id = ?', <Object?>[
        j,
        'n1',
      ]);
      canvas.replaceCanvasRows('n1', j);

      // 列上有 CHECK(json_valid)，**非法 JSON 文本根本写不进去**（下面顺带钉死）；
      // 能注入的损坏是「合法 JSON、类型不对」（camera 必须是对象）。
      expect(
        () => db.execute(
          "UPDATE canvas_meta SET camera_json = '{not json' WHERE note_id = 'n1'",
        ),
        throwsA(isA<SqliteException>()),
      );
      db.execute(
        "UPDATE canvas_meta SET camera_json = 'null' WHERE note_id = 'n1'",
      );
      expect(canvas.readVerifiedCanvas('n1', j), isNull);
      expect(store.noteById('n1')!.content, j);
    });

    test('D4 画布正文被空串覆盖：旧行残留但读路径安全，下次真实保存收敛', () {
      final String j = canvasJson(
        items: <String, Map<String, Object?>>{'s1': shape('s1')},
        itemOrder: <String>['s1'],
      );
      canvas.replaceCanvasRows('n1', j);
      expect(countOf('canvas_items'), 1);

      // 空串过不了格式门闩 ⇒ 0 行写入（旧行暂时残留，但空画布永远读不出它们）。
      expect(canvas.replaceCanvasRows('n1', ''), 0);
      expect(store.noteById('n1')!.content, '', reason: '残留行不该让被清空的画布又冒出旧形状');

      // 同一张画布重新有了内容：差量比对以旧行为基线， upsert 后重新一致。
      final String again = canvasJson(
        items: <String, Map<String, Object?>>{
          's1': shape('s1'),
          's2': shape('s2'),
        },
        itemOrder: <String>['s1', 's2'],
      );
      canvas.replaceCanvasRows('n1', again);
      expect(canvas.verifyCanvasRows('n1', again), isTrue);
    });

    test('D5 删除后撤销（restore）：行随原笔记一起重建并校验通过', () async {
      final String j = canvasJson(
        items: <String, Map<String, Object?>>{'c1': card('c1', 'b1', '想法')},
        itemOrder: <String>['c1'],
      );
      final Note note = store.create(kind: NoteKind.canvas, content: j);
      final Note snapshot = store.noteById(note.id)!;
      expect(countOf('canvas_items'), 1);

      await store.delete(note.id);
      expect(countOf('canvas_items'), 0);
      expect(countOf('blocks'), 0);

      await store.restore(snapshot);
      expect(canvas.hasRows(note.id), isTrue);
      expect(
        canvas.verifyCanvasRows(note.id, snapshot.content),
        isTrue,
        reason: '撤销恢复只回了 JSON、没回行 ⇒ 首次打开靠回退、且永远不切读',
      );
    });
  });

  // ── E. 回填：不只数行数，逐张深比较 ────────────────────────────────

  group('E 回填可靠性', () {
    test('E1 批量回填后每张画布都必须通过行 ⇄ JSON 深比较', () {
      final List<(String, String)> canvases = <(String, String)>[
        for (int i = 0; i < 5; i++)
          (
            'c$i',
            canvasJson(
              items: <String, Map<String, Object?>>{
                's1': shape('s1', rect: <double>[i * 1.0, 0, i + 5.0, 9]),
                if (i.isEven) 'o1': shape('o1', kind: 'ellipse'),
              },
              itemOrder: <String>['s1', if (i.isEven) 'o1'],
              strokes: <String, Map<String, Object?>>{'k1': stroke('k1')},
              strokeOrder: <String>['k1'],
            ),
          ),
      ];
      for (final (String id, String content) in canvases) {
        db.execute(
          'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
          "created_at, revised_at) VALUES (?, 'canvas','',?, 'fp1:1:x','',1,1)",
          <Object?>[id, content],
        );
      }

      // 小名额强制多批续跑。
      expect(store.backfillCanvas(limit: 2), 2);
      expect(store.backfillCanvas(limit: 2), 2);
      expect(store.backfillCanvas(limit: 2), 1);
      expect(store.backfillCanvas(limit: 2), 0);

      for (final (String id, String content) in canvases) {
        expect(
          canvas.verifyCanvasRows(id, content),
          isTrue,
          reason: '$id 回填后行与原文不一致',
        );
        expect(
          jsonDecode(store.noteById(id)!.content),
          equals(jsonDecode(content)),
        );
      }
    });

    test('E2 回填含卡片的画布：内容半边 blocks 一并补齐', () {
      final String withCards = canvasJson(
        items: <String, Map<String, Object?>>{'c1': card('c1', 'b1', '可搜索的想法')},
        itemOrder: <String>['c1'],
      );
      db.execute(
        'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
        "created_at, revised_at) VALUES ('cc','canvas','',?, 'fp1:1:c','',1,1)",
        <Object?>[withCards],
      );

      expect(store.backfillCanvas(), 1);
      final Row block = db
          .select("SELECT note_id, type, props_json FROM blocks WHERE id='b1'")
          .single;
      expect(block['note_id'], 'cc');
      expect(block['type'], 'card');
      expect(jsonDecode(block['props_json'] as String), <String, Object?>{
        'text': '可搜索的想法',
      });
      expect(canvas.verifyCanvasRows('cc', withCards), isTrue);
    });
  });

  // ── F. 级联：删笔记 / 删块不残留孤儿 ───────────────────────────────

  group('F 级联完整性', () {
    test('F1 删画布笔记：几何/连线/meta/墨迹/自有卡片块五张表全清空', () async {
      final Note cv = store.create(
        kind: NoteKind.canvas,
        content: canvasJson(
          items: <String, Map<String, Object?>>{
            'c1': card('c1', 'b1', '一'),
            'c2': card('c2', 'b2', '二'),
            's1': shape('s1'),
          },
          itemOrder: <String>['c1', 'c2', 's1'],
          strokes: <String, Map<String, Object?>>{'k1': stroke('k1')},
          strokeOrder: <String>['k1'],
          edges: <String, Map<String, Object?>>{'e1': edge('e1', 'b1', 'b2')},
        ),
      );
      expect(countOf('canvas_items'), 3);
      expect(countOf('canvas_edges'), 1);
      expect(countOf('canvas_meta'), 1);
      expect(countOf('ink_shards'), 1);
      expect(countOf('blocks'), 2);

      await store.delete(cv.id);
      expect(countOf('canvas_items'), 0);
      expect(countOf('canvas_edges'), 0);
      expect(countOf('canvas_meta'), 0);
      expect(countOf('ink_shards'), 0);
      expect(countOf('blocks'), 0, reason: '自有卡片块没随笔记级联删除');
    });

    test('F2 直接删卡片块：几何行随 block_id 外键级联消失，其余 item 不动', () {
      canvas.replaceCanvasRows(
        'n1',
        canvasJson(
          items: <String, Map<String, Object?>>{
            'c1': card('c1', 'b1', '一'),
            'c2': card('c2', 'b2', '二'),
          },
          itemOrder: <String>['c1', 'c2'],
        ),
      );
      expect(countOf('canvas_items'), 2);

      db.execute("DELETE FROM blocks WHERE id = 'b1'");
      expect(
        db
            .select('SELECT id FROM canvas_items')
            .map((Row r) => r['id'])
            .toList(),
        <String>['c2'],
        reason: '块删掉后指向它的几何行成了悬空行',
      );
    });

    test('F3 引用卡片的真身随对方笔记删除：读回退快照，重新保存后转自有块自愈', () async {
      // 文档里的块 b1。
      final Note doc = store.create(
        content: jsonEncode(<String, Object?>{
          'v': 2,
          'format': 'blocks',
          'document': <String, Object?>{
            'id': 'root',
            'type': 'page',
            'children': <Object?>[
              <String, Object?>{
                'id': 'b1',
                'type': 'paragraph',
                'data': <String, Object?>{'text': '原文'},
              },
            ],
          },
        }),
      );
      final Note cv = store.create(
        kind: NoteKind.canvas,
        content: canvasJson(),
      );
      expect(store.referenceBlockOnCanvas('b1', cv.id), isTrue);
      expect(countOf('canvas_items', where: "WHERE note_id='${cv.id}'"), 1);

      // 删掉文档 ⇒ 块 b1 级联消失 ⇒ 画布上那张引用卡的几何行跟着级联。
      await store.delete(doc.id);
      expect(
        db.select(
          'SELECT COUNT(*) AS c FROM canvas_items WHERE note_id = ? AND block_id = ?',
          <Object?>[cv.id, 'b1'],
        ).single['c'],
        0,
      );

      // 行没了、JSON 快照还在 ⇒ 深比较不过 ⇒ 切读回退自包含 JSON（卡片仍可见）。
      final String snapshotJson =
          db.select('SELECT content FROM notes WHERE id = ?', <Object?>[
                cv.id,
              ]).single['content']
              as String;
      expect(canvas.verifyCanvasRows(cv.id, snapshotJson), isFalse);
      expect(store.noteById(cv.id)!.content, snapshotJson);

      // 下次画布保存：blocks 里查无此 id ⇒ 按「悬空引用」重建成画布自有块。
      canvas.replaceCanvasRows(cv.id, snapshotJson);
      final Row rebuilt = db
          .select("SELECT note_id, type FROM blocks WHERE id='b1'")
          .single;
      expect(rebuilt['note_id'], cv.id);
      expect(rebuilt['type'], 'card');
      expect(canvas.verifyCanvasRows(cv.id, snapshotJson), isTrue);
    });
  });
}
