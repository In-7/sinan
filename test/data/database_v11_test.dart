import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sqlite3/sqlite3.dart';

/// v11 迁移的回归（`docs/data_layer.md` 6.7 R3）：`vec_chunks` 由**块粒度**
/// 升到 **chunk 粒度**（复合主键 `(block_id, chunk_index)`）。
///
/// 粒度分工的理由见迁移注释：chunk 是检索单元、block 是新鲜度单元。
void main() {
  Database openMigrated() {
    final Database db = sqlite3.openInMemory();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    return db;
  }

  void insertNote(Database db, String id) {
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES (?, 'note', '标题', '', 'fp1:0:0', '', 1, 1)",
      <Object?>[id],
    );
  }

  void insertBlock(Database db, String id, String noteId) {
    db.execute(
      'INSERT INTO blocks (id, note_id, type, props_json, ord, created_at, '
      "updated_at, fingerprint) VALUES (?, ?, 'paragraph', '{}', 0, 1, 1, 'fp1:$id')",
      <Object?>[id, noteId],
    );
  }

  test('v11：userVersion 前进到 11，vec_chunks 带 chunk_index 复合主键', () {
    final Database db = openMigrated();
    expect(db.userVersion, greaterThanOrEqualTo(11));

    final List<String> cols = <String>[
      for (final Row r in db.select('PRAGMA table_info(vec_chunks)'))
        r['name'] as String,
    ];
    expect(cols, contains('chunk_index'));
  });

  test('v11：同一块的多个 chunk 共存（块粒度已升级）', () {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1');
    for (int i = 0; i < 3; i++) {
      db.execute(
        'INSERT INTO vec_chunks (block_id, chunk_index, embedding) '
        'VALUES (?, ?, ?)',
        <Object?>[
          'b1',
          i,
          <int>[0, 0, 128, 63],
        ],
      );
    }
    expect(db.select('SELECT COUNT(*) AS c FROM vec_chunks').single['c'], 3);

    // 同一块同一 chunk 序号**重复**写入是覆盖（复合主键的唯一性）。
    expect(
      () => db.execute(
        'INSERT INTO vec_chunks (block_id, chunk_index, embedding) '
        'VALUES (?, 0, ?)',
        <Object?>[
          'b1',
          <int>[0, 0, 128, 63],
        ],
      ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('v11：整块的 chunk 行随笔记级联消失', () {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1');
    for (int i = 0; i < 2; i++) {
      db.execute(
        'INSERT INTO vec_chunks (block_id, chunk_index, embedding) '
        'VALUES (?, ?, ?)',
        <Object?>[
          'b1',
          i,
          <int>[0, 0, 128, 63],
        ],
      );
    }
    db.execute("DELETE FROM notes WHERE id = 'n1'");
    expect(db.select('SELECT COUNT(*) AS c FROM vec_chunks').single['c'], 0);
  });
}
