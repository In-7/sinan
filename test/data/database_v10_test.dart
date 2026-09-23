import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_vector/sqlite_vector.dart';

/// v10 迁移的回归：检索层**向量路**（机制 A）+ 远端删除墓碑
/// （`docs/data_layer.md` 6.7 的 R1；schema 语义见 v10 迁移注释）。
///
/// 测试重点同样是**把设计约定钉死**：
/// 1. `vec_chunks` 是普通表 ⇒ 外键级联成立（机制 A 的核心收益，6.3 坑 -1）；
/// 2. `pending_delete` 是**孤岛表** ⇒ 删笔记后墓碑必须还在（6.6② 约束 2）；
/// 3. 向量扩展冒烟：加载 → 写入 → 全量扫描这条链真的通（机制 A 构建钩子的
///    验收，就是 6.7 说的"R1 第一天见分晓"）。
void main() {
  Database openMigrated({bool withVector = false}) {
    // 扩展注册是进程级、只对**之后**打开的连接生效 ⇒ 必须先注册再 open。
    if (withVector) sqlite3.loadSqliteVectorExtension();
    final Database db = sqlite3.openInMemory();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);
    // 级联行为依赖这个 pragma（真实路径见 AppDatabase.open）。
    db.execute('PRAGMA foreign_keys = ON;');
    return db;
  }

  String insertNote(Database db, String id) {
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES (?, 'note', '标题', '', 'fp1:0:0', '', 1, 1)",
      <Object?>[id],
    );
    return id;
  }

  void insertBlock(Database db, String id, String noteId) {
    db.execute(
      'INSERT INTO blocks (id, note_id, type, props_json, ord, created_at, '
      "updated_at, fingerprint) VALUES (?, ?, 'paragraph', '{}', 0, 1, 1, 'fp1:1:1')",
      <Object?>[id, noteId],
    );
  }

  test(
    'v10：vec_chunks / pending_delete 落地，index_state 加 chunker_version 列',
    () {
      final Database db = openMigrated();

      expect(db.userVersion, greaterThanOrEqualTo(10));

      // chunker_version：存量行为 ''（= 永远过期 ⇒ 首次建索引全量重算，6.6①）。
      insertNote(db, 'n1');
      insertBlock(db, 'b1', 'n1');
      db.execute(
        'INSERT INTO index_state (block_id, fingerprint, model, updated_at) '
        "VALUES ('b1', 'fp1:1:1', 'ollama:bge-m3:1024', 1)",
      );
      expect(
        db.select(
          'SELECT chunker_version FROM index_state WHERE block_id = ?',
          <Object?>['b1'],
        ).single['chunker_version'],
        '',
      );

      // pending_delete 的主键口径：(kind, ref) —— 入队用 **upsert**（6.6② 约束 3：
      // "远端 id 由本地 id 确定性派生，upsert 覆盖即可"），重复入队是覆盖不是堆积。
      db.execute(
        "INSERT INTO pending_delete (kind, ref, note_id, queued_at) "
        "VALUES ('chunk', 'b1', 'n1', 1)",
      );
      db.execute(
        "INSERT OR REPLACE INTO pending_delete (kind, ref, note_id, queued_at, attempts) "
        "VALUES ('chunk', 'b1', 'n1', 2, 1)",
      );
      expect(
        db.select('SELECT COUNT(*) AS c FROM pending_delete').single['c'],
        1,
      );
    },
  );

  test('v10：vec_chunks 随笔记级联消失（普通表 ⇒ 外键可用，机制 A 核心收益）', () {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1');
    // ⚠️ 形状按 v11（chunk 粒度）：本用例只关心级联，故写 chunk 0。
    db.execute(
      'INSERT INTO vec_chunks (block_id, chunk_index, embedding) VALUES (?, ?, ?)',
      <Object?>[
        'b1',
        0,
        <int>[0, 0, 128, 63],
      ], // float32 LE 的 1.0
    );

    db.execute("DELETE FROM notes WHERE id = 'n1'");
    expect(
      db.select('SELECT COUNT(*) AS c FROM vec_chunks').single['c'],
      0,
      reason: '向量行必须随笔记级联消失——否则会"检索到已删的笔记"（6.3）',
    );
  });

  test('v10：pending_delete 是孤岛表——删笔记后墓碑仍在（6.6② 约束 2）', () {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1');
    db.execute(
      "INSERT INTO pending_delete (kind, ref, note_id, queued_at) "
      "VALUES ('chunk', 'b1', 'n1', 1)",
    );

    db.execute("DELETE FROM notes WHERE id = 'n1'");
    // index_state 被 CASCADE 清掉的同时，墓碑必须**幸存**——否则远端副本
    // 永久残留、"搜到已删内容"（这正是孤岛表存在的全部理由）。
    expect(db.select('SELECT COUNT(*) AS c FROM index_state').single['c'], 0);
    expect(
      db.select('SELECT ref FROM pending_delete WHERE kind = ?', <Object?>[
        'chunk',
      ]).single['ref'],
      'b1',
    );
  });

  test('v10：向量扩展冒烟——加载 → vector_init → full_scan 全链可用', () {
    final Database db = openMigrated(withVector: true);

    // 按包文档的口径走一遍（独立玩具表，不依赖业务 schema）：
    db.execute('CREATE TABLE vec_t (id INTEGER PRIMARY KEY, v BLOB NOT NULL)');
    db.execute("SELECT vector_init('vec_t', 'v', 'type=FLOAT32,dimension=4')");
    db.execute(
      "INSERT INTO vec_t (id, v) VALUES (1, vector_as_f32('[1,0,0,0]'))",
    );
    db.execute(
      "INSERT INTO vec_t (id, v) VALUES (2, vector_as_f32('[0,1,0,0]'))",
    );
    final List<Row> rows = db.select(
      "SELECT rowid, distance FROM vector_full_scan("
      "'vec_t', 'v', vector_as_f32('[1,0,0,0]'), 2)",
    );
    expect(rows, hasLength(2));
    // 查询向量与 id=1 完全相同 ⇒ 距离 0、排最前。
    expect(rows.first['rowid'], 1);
    expect((rows.first['distance'] as num).toDouble(), 0.0);
  });
}
