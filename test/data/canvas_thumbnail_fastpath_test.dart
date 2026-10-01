import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/canvas_thumbnail.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/canvas_mindmap.dart';
import 'package:sinan/src/data/canvas_store.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 主页画布缩略图**关系表快路径**（2026-10-01）的验证。
///
/// 链路：`canvas_items` 投影成功时在同事务写 srcfp 闸门
/// （`<content_hash>#<item 行数>`，存 rag_meta）→ 缩略图 provider 先试
/// `NoteStore.canvasThumbnailItemJson`（不读 content / 笔迹），闸门不过再
/// 降落伞回退 content 全文解析。
///
/// 本文件钉死：① 命中时行逆投影与 content 解析**渲染等价**（六类 item）；
/// ② 闸门三态（无 / 哈希不符 / 行数不符）都安全回退；③ 纯笔迹 0-item 重画布
/// 也命中（直接空水印，不碰 MB 级 content）；④ 引用卡片文本跨笔记 JOIN；
/// ⑤ 差量 0 早返回刷新闸门；⑥ 删笔记清孤儿键。
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
  });

  tearDown(() => db.close());

  // ── 夹具 ───────────────────────────────────────────────────────────

  Map<String, Object?> shape(
    String id, {
    String kind = 'rectangle',
    List<double>? rect,
    int color = 0xFF1F1F1F,
  }) => <String, Object?>{
    'type': 'shape',
    'id': id,
    'kind': kind,
    'color': color,
    'strokeWidth': 2.0,
    'filled': false,
    'angle': 0.0,
    'rect': rect ?? <double>[0.0, 0.0, 10.0, 20.0],
    'meta': <String, Object?>{},
  };

  Map<String, Object?> image(String id) => <String, Object?>{
    'type': 'image',
    'id': id,
    'angle': 0.0,
    'rect': <double>[0.0, 0.0, 100.0, 80.0],
    'src': 'media/$id.png',
    'meta': <String, Object?>{},
  };

  Map<String, Object?> aiImage(String id) => <String, Object?>{
    'type': 'aiImage',
    'id': id,
    'angle': 0.0,
    'rect': <double>[0.0, 0.0, 100.0, 80.0],
    'src': 'media/$id.png',
    'gen': <String, Object?>{'model': 'sdxl', 'prompt': '一只猫', 'seed': 42},
    'meta': <String, Object?>{},
  };

  Map<String, Object?> card(
    String id,
    String blockId,
    String text, {
    String? colorSlot,
  }) => <String, Object?>{
    'type': 'card',
    'id': id,
    'blockId': blockId,
    'text': text,
    'colorSlot': ?colorSlot,
    'angle': 0.0,
    'rect': <double>[0.0, 0.0, 120.0, 60.0],
    'meta': <String, Object?>{},
  };

  Map<String, Object?> mindmap(String id) => <String, Object?>{
    'type': 'mindmap',
    'id': id,
    'angle': 0.0,
    'rect': <double>[0.0, 0.0, 200.0, 120.0],
    'nodes': <String, Object?>{
      'id': 'n0',
      'text': '中心主题',
      'children': <Object?>[
        <String, Object?>{'id': 'n1', 'text': '分支'},
      ],
    },
    'meta': <String, Object?>{},
  };

  Map<String, Object?> group(String id) => <String, Object?>{
    'type': 'group',
    'id': id,
    'angle': 0.0,
    'rect': <double>[-50.0, -50.0, 300.0, 300.0],
    'label': '组一',
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

  String canvasJson({
    Map<String, Map<String, Object?>> items = const {},
    List<String> itemOrder = const <String>[],
    Map<String, Map<String, Object?>> strokes = const {},
    List<String> strokeOrder = const <String>[],
  }) => jsonEncode(<String, Object?>{
    'camera': <String, Object?>{
      'scale': 1.0,
      'translation': <double>[0.0, 0.0],
      'minScale': 0.05,
      'maxScale': 4.0,
    },
    'document': <String, Object?>{
      'schemaVersion': 2,
      'strokes': strokes,
      'items': items,
      'strokeOrder': strokeOrder,
      'itemOrder': itemOrder,
    },
  });

  String docWithParagraph(String blockId, String text) =>
      jsonEncode(<String, Object?>{
        'v': 2,
        'format': 'blocks',
        'document': <String, Object?>{
          'id': 'root',
          'type': 'page',
          'children': <Object?>[
            <String, Object?>{
              'id': blockId,
              'type': 'paragraph',
              'data': <String, Object?>{'text': text},
            },
          ],
        },
      });

  /// 快路径产物与 content 全文解析产物必须**渲染等价**：同 z 序、同类型、
  /// 同包围盒（UI 消费的就是这些）。
  void expectRenderEquivalent(
    List<Map<String, dynamic>> rowItems,
    String content,
  ) {
    final CanvasThumbnail fast = thumbnailFromItemJson(rowItems)!;
    final CanvasThumbnail legacy = parseCanvasThumbnail(content)!;
    expect(fast.items.length, legacy.items.length);
    expect(fast.bounds.left, closeTo(legacy.bounds.left, 1e-9));
    expect(fast.bounds.top, closeTo(legacy.bounds.top, 1e-9));
    expect(fast.bounds.right, closeTo(legacy.bounds.right, 1e-9));
    expect(fast.bounds.bottom, closeTo(legacy.bounds.bottom, 1e-9));
    for (int i = 0; i < fast.items.length; i++) {
      final CanvasItem a = fast.items[i];
      final CanvasItem b = legacy.items[i];
      expect(a.runtimeType, b.runtimeType, reason: 'z=$i 类型不一致');
      expect(a.id, b.id);
      expect(a.bounds.left, closeTo(b.bounds.left, 1e-9));
      expect(a.bounds.top, closeTo(b.bounds.top, 1e-9));
      expect(a.bounds.right, closeTo(b.bounds.right, 1e-9));
      expect(a.bounds.bottom, closeTo(b.bounds.bottom, 1e-9));
    }
  }

  int countOf(String table, {String? where, List<Object?> args = const []}) =>
      db
              .select('SELECT COUNT(*) AS c FROM $table ${where ?? ''}', args)
              .single['c']
          as int;

  // ── 1. 命中：六类 item 全家福，快路径 ⇄ content 解析渲染等价 ──────────

  test('1 六类全家福：快路径按 z 序返回，与全文解析渲染等价', () {
    final Map<String, Map<String, Object?>> items =
        <String, Map<String, Object?>>{
          'r1': shape('r1', rect: <double>[1.0, 2.0, 11.0, 22.0]),
          'o1': shape('o1', kind: 'ellipse', rect: <double>[0, 0, 7, 9]),
          'i1': image('i1'),
          'a1': aiImage('a1'),
          'c1': card('c1', 'b1', '想法一', colorSlot: 'yellow'),
          'm1': mindmap('m1'),
          'g1': group('g1'),
        };
    // z 序故意与 Map 顺序不同，验证 ORDER BY z 生效。
    final List<String> order = <String>[
      'g1',
      'r1',
      'o1',
      'i1',
      'a1',
      'c1',
      'm1',
    ];
    final String j = canvasJson(items: items, itemOrder: order);
    final Note n = store.create(kind: NoteKind.canvas, content: j);

    final List<Map<String, dynamic>>? rows = store.canvasThumbnailItemJson(
      n.id,
    );
    expect(rows, isNotNull);
    expect(rows!.length, 7);
    expect(rows.map((Map<String, dynamic> r) => r['id']), order);
    expectRenderEquivalent(rows, j);

    // 关键字段抽查（证明 JOIN / props 逆投影真的取到了内容侧）。
    final CardItem cardItem = thumbnailFromItemJson(rows)!.items
        .whereType<CardItem>()
        .single;
    expect(cardItem.text, '想法一');
    expect(cardItem.blockId, 'b1');
    expect(cardItem.colorSlot?.name, 'yellow');
    final AiImageItem ai = thumbnailFromItemJson(rows)!.items
        .whereType<AiImageItem>()
        .single;
    expect(ai.gen.prompt, '一只猫');
    final MindMapItem mm = thumbnailFromItemJson(rows)!.items
        .whereType<MindMapItem>()
        .single;
    expect(mm.root.text, '中心主题');
    expect(mm.root.children.single.text, '分支');
    final CanvasGroupItem g = thumbnailFromItemJson(rows)!.items
        .whereType<CanvasGroupItem>()
        .single;
    expect(g.label, '组一');
  });

  // ── 2. 闸门三态：任何一态不符都回退 null（降落伞）──────────────────

  test('2a 无投影（存量未回填）→ null 走降落伞', () {
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES ('c9','canvas','',?, 'fp1:1:x','',1,1)",
      <Object?>[
        canvasJson(
          items: <String, Map<String, Object?>>{'s1': shape('s1')},
          itemOrder: <String>['s1'],
        ),
      ],
    );
    expect(store.canvasThumbnailItemJson('c9'), isNull);
    // 降落伞路径仍然能解析出内容。
    expect(parseCanvasThumbnail(store.canvasContentOf('c9')), isNotNull);
  });

  test('2b content_hash 不匹配（投影失败 / 行落后）→ null', () {
    final Note n = store.create(
      kind: NoteKind.canvas,
      content: canvasJson(
        items: <String, Map<String, Object?>>{'s1': shape('s1')},
        itemOrder: <String>['s1'],
      ),
    );
    expect(store.canvasThumbnailItemJson(n.id), isNotNull);

    // content 已新、投影事务整笔回滚后的状态：哈希是新的，闸门还是旧的。
    db.execute(
      "UPDATE notes SET content_hash = 'fp1:1:stale' WHERE id = ?",
      <Object?>[n.id],
    );
    expect(store.canvasThumbnailItemJson(n.id), isNull);
  });

  test('2c item 行数不符（meta 在、行被 DROP 的历史空洞）→ null', () {
    final Note n = store.create(
      kind: NoteKind.canvas,
      content: canvasJson(
        items: <String, Map<String, Object?>>{
          's1': shape('s1'),
          's2': shape('s2'),
        },
        itemOrder: <String>['s1', 's2'],
      ),
    );
    expect(store.canvasThumbnailItemJson(n.id), isNotNull);

    db.execute(
      "DELETE FROM canvas_items WHERE note_id = ? AND id = 's2'",
      <Object?>[n.id],
    );
    expect(store.canvasThumbnailItemJson(n.id), isNull);
  });

  test('2d 不存在 / 非画布 → null（不炸）', () {
    expect(store.canvasThumbnailItemJson('nope'), isNull);
    final Note doc = store.create(content: docWithParagraph('b1', '正文'));
    expect(store.canvasThumbnailItemJson(doc.id), isNull);
  });

  // ── 3. 纯笔迹 0-item：content 再大也命中快路径，直接空水印 ────────────

  test('3 纯笔迹重画布（>128KB、0 item）命中快路径且返回空列表', () {
    final String huge = canvasJson(
      strokes: <String, Map<String, Object?>>{
        for (int i = 0; i < 400; i++) 'k$i': stroke('k$i', points: 80),
      },
      strokeOrder: <String>[for (int i = 0; i < 400; i++) 'k$i'],
    );
    expect(huge.length, greaterThan(128 * 1024));

    final Note n = store.create(kind: NoteKind.canvas, content: huge);
    expect(countOf('ink_shards'), greaterThan(1));

    final List<Map<String, dynamic>>? rows = store.canvasThumbnailItemJson(
      n.id,
    );
    expect(rows, isNotNull, reason: '纯笔迹画布本该靠 #0 闸门命中快路径');
    expect(rows, isEmpty);
    // 与降落伞路径同口径：空 item ⇒ null ⇒ UI 落水印。
    expect(thumbnailFromItemJson(rows!), isNull);
    expect(parseCanvasThumbnail(huge), isNull);
  });

  test('3b 空画布（content 空串，从未落行）→ 降落伞同样得空水印', () {
    final Note n = store.create(kind: NoteKind.canvas);
    expect(store.canvasThumbnailItemJson(n.id), isNull);
    expect(parseCanvasThumbnail(store.canvasContentOf(n.id)), isNull);
  });

  // ── 4. 引用卡片：文本真身属于别的笔记，靠 block_id JOIN 取回 ──────────

  test('4 引用卡片文本跨笔记 JOIN；几何在外、真身在文档', () {
    final Note doc = store.create(content: docWithParagraph('b1', '真身文本'));
    final Note cv = store.create(kind: NoteKind.canvas, content: canvasJson());
    expect(store.referenceBlockOnCanvas('b1', cv.id), isTrue);

    final List<Map<String, dynamic>>? rows = store.canvasThumbnailItemJson(
      cv.id,
    );
    expect(rows, isNotNull);
    expect(rows!.single['type'], 'card');
    expect(rows.single['blockId'], 'b1');
    expect(rows.single['text'], '真身文本');

    final CardItem item = thumbnailFromItemJson(rows)!.items.single as CardItem;
    expect(item.text, '真身文本');
    // 文档仍在，块没有被搬走。
    expect(
      db.select('SELECT note_id FROM blocks WHERE id = ?', <Object?>[
        'b1',
      ]).single['note_id'],
      doc.id,
    );
  });

  // ── 5. 闸门维护：早返回刷新 / 笔迹编辑跟随 / 二次保存 0 写 ────────────

  test('5a 差量 0 早返回：闸门缺失时补写，且 0 行投影写入', () {
    final String j = canvasJson(
      items: <String, Map<String, Object?>>{'s1': shape('s1')},
      itemOrder: <String>['s1'],
    );
    final Note n = store.create(kind: NoteKind.canvas, content: j);
    expect(store.canvasThumbnailItemJson(n.id), isNotNull);

    // 模拟「老版本已投影视、但还没有 srcfp 闸门」的存量状态。
    db.execute("DELETE FROM rag_meta WHERE key = 'canvas.srcfp.${n.id}'");
    expect(store.canvasThumbnailItemJson(n.id), isNull);

    // 再来一次同内容保存：差量为 0（投影返回 0），但闸门要被补上。
    expect(canvas.replaceCanvasRows(n.id, j), 0);
    expect(store.canvasThumbnailItemJson(n.id), isNotNull);
  });

  test('5b 纯笔迹编辑：几何 0 变化，闸门随新 hash 刷新，仍命中', () async {
    final String shapeOnly = canvasJson(
      items: <String, Map<String, Object?>>{'s1': shape('s1')},
      itemOrder: <String>['s1'],
    );
    final Note n = store.create(kind: NoteKind.canvas, content: shapeOnly);
    final String before =
        db.select('SELECT content_hash FROM notes WHERE id = ?', <Object?>[
              n.id,
            ]).single['content_hash']
            as String;

    final String withStroke = canvasJson(
      items: <String, Map<String, Object?>>{'s1': shape('s1')},
      itemOrder: <String>['s1'],
      strokes: <String, Map<String, Object?>>{'k1': stroke('k1')},
      strokeOrder: <String>['k1'],
    );
    expect(await store.updateContent(n.id, withStroke, plainText: ''), isTrue);
    final String after =
        db.select('SELECT content_hash FROM notes WHERE id = ?', <Object?>[
              n.id,
            ]).single['content_hash']
            as String;
    expect(after, isNot(before));

    final List<Map<String, dynamic>>? rows = store.canvasThumbnailItemJson(
      n.id,
    );
    expect(rows, isNotNull, reason: '笔迹-only 编辑后闸门没跟上新 hash');
    expect(rows!.length, 1);
    expect(rows.single['id'], 's1');
  });

  // ── 6. 删笔记清理两把 rag_meta 键 ──────────────────────────────────

  test('6 删除画布：srcfp / meta fp 两把孤儿键一并清掉', () async {
    final Note n = store.create(
      kind: NoteKind.canvas,
      content: canvasJson(
        items: <String, Map<String, Object?>>{'s1': shape('s1')},
        itemOrder: <String>['s1'],
      ),
    );
    expect(
      countOf('rag_meta', where: "WHERE key LIKE 'canvas.%fp.${n.id}'"),
      2,
    );
    await store.delete(n.id);
    expect(
      countOf('rag_meta', where: "WHERE key LIKE 'canvas.%fp.${n.id}'"),
      0,
    );
    expect(store.canvasThumbnailItemJson(n.id), isNull);
  });
}
