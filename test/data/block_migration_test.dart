import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 块可迁移（#5）：文档块 ↔ 画布卡片是同一份 `blocks` 内容，搬动只改归属。
///
/// 关键回归：把块从文档块树摘掉去画布后，`BlockStore.replaceNoteBlocks` 的删除集
/// 必须**保留被画布卡片引用的块**——否则文档保存会把块连同卡片一起删掉。
void main() {
  late Database db;
  late NoteStore store;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
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

  Map<String, Object?> block(String id, String type,
          {Map<String, Object?> data = const <String, Object?>{},
          List<Map<String, Object?>> children = const <Map<String, Object?>>[]}) =>
      <String, Object?>{
        'id': id,
        'type': type,
        'data': data,
        if (children.isNotEmpty) 'children': children,
      };

  /// 造一张画布，并在 canvas_items 里放一张引用该 blockId 的卡片，
  /// 让这块被 `BlockStore._canvasReferencedBlockIds` 视为"画布托管"。
  void stubCanvasCard(String blockId) {
    db.execute(
      "INSERT INTO notes (id, kind, title, content, content_hash, created_at, revised_at) "
      "VALUES ('cv', 'canvas', '', '{\"camera\":{},\"document\":{}}', '', 0, 0)",
    );
    db.execute(
      "INSERT INTO canvas_items (note_id, id, kind, z, x1, y1, x2, y2, created_at, updated_at, fingerprint, block_id) "
      "VALUES ('cv', 'card-1', 'card', 0, 0, 0, 10, 10, 0, 0, '', ?)",
      <Object?>[blockId],
    );
  }

  /// 正文里的 `document.children`。
  ///
  /// 先在 `Map` 上取一次 `['document']` 再转 `Map` 下钻 —— 否则
  /// `(jsonDecode(x) as Map)['document']['children']` 的第二次索引是在
  /// **dynamic** 上做的（`avoid_dynamic_calls`）。
  List<Object?> docChildren(String content) =>
      ((jsonDecode(content) as Map)['document'] as Map)['children']
          as List<Object?>;

  test('搬去画布：块从文档树消失，但 blocks 行保留（被卡片引用）', () {
    final Note note = store.create(
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '抬走'}),
      ]),
    );
    stubCanvasCard('b1');

    expect(store.moveBlockToCanvas('b1'), isTrue);

    // 文档树里没了 b1。
    final String content =
        db.select("SELECT content FROM notes WHERE id=?", <Object?>[note.id])
            .first['content'] as String;
    expect(docChildren(content), isEmpty);

    // blocks 行还在——画布卡片救了它，否则 replaceNoteBlocks 会删掉。
    expect(
      db.select("SELECT COUNT(*) AS c FROM blocks WHERE id='b1'").first['c'],
      1,
    );
  });

  test('搬回文档：块重新挂回文档块树根部', () {
    final Note note = store.create(
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '抬走'}),
      ]),
    );
    stubCanvasCard('b1');
    store.moveBlockToCanvas('b1');

    expect(store.moveBlockToDocument('b1'), isTrue);

    final String content =
        db.select("SELECT content FROM notes WHERE id=?", <Object?>[note.id])
            .first['content'] as String;
    final List<Object?> children = docChildren(content);
    expect(children.length, 1);
    expect((children.first as Map)['id'], 'b1');
  });

  test('往返幂等：已在树里的块 moveBlockToDocument 不重复加', () {
    store.create(
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '一'}),
      ]),
    );
    expect(store.moveBlockToDocument('b1'), isFalse);
  });

  test('没有画布卡片时，搬去画布的块仍被删（旧行为，防止孤儿堆积）', () {
    store.create(
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '孤'}),
      ]),
    );
    // 注意：没调 stubCanvasCard ⇒ 没有卡片引用 b1。
    expect(store.moveBlockToCanvas('b1'), isTrue);
    expect(
      db.select("SELECT COUNT(*) AS c FROM blocks WHERE id='b1'").first['c'],
      0,
      reason: '没人引用就该删，避免孤儿块堆积',
    );
  });
}
