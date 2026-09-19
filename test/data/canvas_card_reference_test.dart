import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/canvas_store.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 块可迁移 #5 的**反向**：文档 → 画布，走「双链多视图」。
///
/// 与"搬去画布"（`block_migration_test.dart`，块改归属）的分水岭是：
/// **文档里那块原地不动**，画布上只是多一张指向**同一份内容**的卡片。
/// 于是这里最该钉死的不是"卡片加上了"，而是三件容易悄悄坏掉的事：
///
/// 1. **不摘除**：引用之后文档块树里那块必须还在（否则就成了搬走）；
/// 2. **不污染对方的块**：画布改卡片文本只许更新那个块的 `text`，
///    `note_id` / `type` / 其余属性（标题的 `level`…）一律不许动；
/// 3. **不误删**：画布上把引用卡片删掉，文档正文不能跟着少一块。
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

  String v2(List<Map<String, Object?>> children) => jsonEncode(<String, Object?>{
        'v': 2,
        'format': 'blocks',
        'document': <String, Object?>{
          'id': 'root',
          'type': 'page',
          'children': children,
        },
      });

  Map<String, Object?> block(
    String id,
    String type, {
    Map<String, Object?> data = const <String, Object?>{},
  }) =>
      <String, Object?>{
        'id': id,
        'type': type,
        'data': data,
      };

  /// 一张最小可解析的画布（`camera` + `document.items` 缺一不可，
  /// 见 `CanvasStore._parseCanvasDocument`）。
  String canvasJson({
    Map<String, Object?> items = const <String, Object?>{},
    List<String> order = const <String>[],
  }) =>
      jsonEncode(<String, Object?>{
        'camera': <String, Object?>{},
        'document': <String, Object?>{
          'items': items,
          'itemOrder': order,
          'strokes': <String, Object?>{},
        },
      });

  /// 一张卡片（字段与 `CanvasStore` 的「卡片 JSON 契约」逐项对齐）。
  Map<String, Object?> card(String id, String blockId, String text) =>
      <String, Object?>{
        'type': 'card',
        'id': id,
        'blockId': blockId,
        'text': text,
        'angle': 0.0,
        'rect': <double>[0.0, 0.0, 240.0, 120.0],
        'meta': <String, Object?>{},
      };

  /// 一篇笔记的正文（含大字段，`allNotes` 的快照没有它，测试要直接查）。
  String contentOf(String noteId) =>
      db.select('SELECT content FROM notes WHERE id = ?', <Object?>[noteId])
          .first['content'] as String;

  /// 画布正文里的 `document.items`。
  Map<String, Object?> itemsOf(String noteId) =>
      ((jsonDecode(contentOf(noteId)) as Map)['document'] as Map)['items']
          as Map<String, Object?>;

  /// 画布 JSON 里那张卡片（只有一张时用）。
  Map<String, Object?> onlyCardOf(String noteId) =>
      itemsOf(noteId).values.single as Map<String, Object?>;

  /// 文档块树根部的 children。
  List<Object?> childrenOf(String noteId) =>
      ((jsonDecode(contentOf(noteId)) as Map)['document'] as Map)['children']
          as List<Object?>;

  /// `blocks` 里一行的关键三列（`props_json` 解成 Map 便于断言）。
  Map<String, Object?> blockRow(String id) {
    final Row r = db
        .select(
          'SELECT note_id, type, props_json FROM blocks WHERE id = ?',
          <Object?>[id],
        )
        .first;
    return <String, Object?>{
      'note_id': r['note_id'],
      'type': r['type'],
      'props': jsonDecode(r['props_json'] as String) as Map<String, Object?>,
    };
  }

  test('引用到画布：文档里那块原地不动，画布上多一张指向它的卡片', () {
    final Note doc = store.create(
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '原文'}),
      ]),
    );
    final Note cv = store.create(kind: NoteKind.canvas, content: canvasJson());

    expect(store.referenceBlockOnCanvas('b1', cv.id), isTrue);

    // ① 文档块树里那块**还在** —— 这是与"搬去画布"的根本差别。
    final List<Object?> children = childrenOf(doc.id);
    expect(children.length, 1);
    expect((children.single! as Map<String, Object?>)['id'], 'b1');

    // ② 画布上多了一张引用同一块的卡片，文本就是真身的内容。
    final Map<String, Object?> c = onlyCardOf(cv.id);
    expect(c['type'], 'card');
    expect(c['blockId'], 'b1');
    expect(c['text'], '原文');

    // ③ 块的归属仍是文档（没被画布抢走）。
    expect(blockRow('b1')['note_id'], doc.id);
  });

  test('重复引用同一块：幂等返回 false，不重复加卡片', () {
    store.create(
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '一'}),
      ]),
    );
    final Note cv = store.create(kind: NoteKind.canvas, content: canvasJson());

    expect(store.referenceBlockOnCanvas('b1', cv.id), isTrue);
    expect(store.referenceBlockOnCanvas('b1', cv.id), isFalse);
    expect(itemsOf(cv.id).length, 1);
  });

  test('块不存在时拒绝引用（不留指向空气的卡片）', () {
    final Note cv = store.create(kind: NoteKind.canvas, content: canvasJson());

    expect(store.referenceBlockOnCanvas('ghost', cv.id), isFalse);
    expect(itemsOf(cv.id), isEmpty);
  });

  test('画布改卡片文本 → 只更新文档块的 text，归属/类型/其余属性都不动', () {
    final Note doc = store.create(
      content: v2(<Map<String, Object?>>[
        block('h1', 'heading', data: <String, Object?>{'text': '旧标题', 'level': 2}),
      ]),
    );
    final Note cv = store.create(kind: NoteKind.canvas, content: canvasJson());
    store.referenceBlockOnCanvas('h1', cv.id);

    // 模拟"在画布上把卡片改名后自动保存"：改 JSON 里的文本再投影一次。
    final Map<String, Object?> doc2 =
        (jsonDecode(contentOf(cv.id)) as Map).cast<String, Object?>();
    final Map<String, Object?> items =
        ((doc2['document']! as Map)['items'] as Map).cast<String, Object?>();
    final Map<String, Object?> c =
        (items.values.single as Map).cast<String, Object?>();
    c['text'] = '新标题';
    canvas.replaceCanvasRows(cv.id, jsonEncode(doc2));

    final Map<String, Object?> row = blockRow('h1');
    expect(row['note_id'], doc.id, reason: '归属不能被画布抢走');
    expect(row['type'], 'heading', reason: '类型不能被改成 card');
    final Map<String, Object?> props = row['props']! as Map<String, Object?>;
    expect(props['text'], '新标题');
    expect(props['level'], 2, reason: '其余属性必须原样保留');
  });

  test('文档改了块：打开画布时快照被刷新回最新文本', () async {
    final Note doc = store.create(
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '旧'}),
      ]),
    );
    final Note cv = store.create(kind: NoteKind.canvas, content: canvasJson());
    store.referenceBlockOnCanvas('b1', cv.id);
    expect(onlyCardOf(cv.id)['text'], '旧');

    // 文档侧正常编辑：块投影会把新文本写进 blocks。
    await store.updateContent(
      doc.id,
      v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '新'}),
      ]),
      plainText: '新',
    );

    expect(store.syncCanvasCardTexts(cv.id), isTrue);
    expect(onlyCardOf(cv.id)['text'], '新');
    // 已经一致 ⇒ 再刷不写。
    expect(store.syncCanvasCardTexts(cv.id), isFalse);
  });

  test('画布上删掉引用卡片：文档块不受影响', () {
    store.create(
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '留下的'}),
      ]),
    );
    final Note cv = store.create(kind: NoteKind.canvas, content: canvasJson());
    store.referenceBlockOnCanvas('b1', cv.id);

    // 画布保存一份"没有卡片"的 JSON = 这张卡片被删了。
    canvas.replaceCanvasRows(cv.id, canvasJson());

    expect(
      db.select("SELECT COUNT(*) AS c FROM blocks WHERE id = 'b1'").first['c'],
      1,
      reason: '文档正文不能因为画布删了引用卡片而少一块',
    );
    expect(
      db.select("SELECT COUNT(*) AS c FROM canvas_items WHERE block_id = 'b1'")
          .first['c'],
      0,
    );
  });

  test('引用卡片指向的块已不存在：画布保存不炸，转成画布自有块', () {
    // 存档里留着一张指向已消失块的卡片（文档里那块被删过）。
    // 外键 `canvas_items.block_id → blocks(id)` 要求先有块行，否则插入时炸。
    final Note cv = store.create(
      kind: NoteKind.canvas,
      content: canvasJson(
        items: <String, Object?>{'item-0': card('item-0', 'gone', '悬空')},
        order: <String>['item-0'],
      ),
    );

    // 块被补建为画布自有块（归属画布、类型 card），卡片文本因此没丢。
    final Map<String, Object?> row = blockRow('gone');
    expect(row['note_id'], cv.id);
    expect(row['type'], 'card');
    expect((row['props']! as Map<String, Object?>)['text'], '悬空');
  });
}
