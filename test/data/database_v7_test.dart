import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sqlite3/sqlite3.dart';

/// v7 迁移的回归：**块级表 + AI 检索的事实表**（`docs/data_layer.md` 迁移第 1 步）。
///
/// 这一版没有任何 UI 消费这些表，所以测试的重点不是业务行为，而是
/// **把设计时约定的约束钉死**，避免将来有人改 schema 时悄悄丢失：
/// 1. FTS5 在自带 SQLite 里**确实可用**（换 SDK / 升 package 会在这里红）；
/// 2. CJK 必须 bigram 才有召回——用一条反例把那个坑变成活的；
/// 3. `json_valid` CHECK、外键级联、`userVersion` 前进三者都成立。
void main() {
  Database openMigrated() {
    final Database db = sqlite3.openInMemory();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);
    // 级联行为依赖这个 pragma（真实 Confirm 路径见 AppDatabase.open）。
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

  List<String> tableNames(Database db) => <String>[
        for (final Row r in db.select(
          "SELECT name FROM sqlite_master WHERE type IN ('table','view') "
          'ORDER BY name',
        ))
          r['name'] as String,
      ];

  test('v7：新表齐备，vec 表按约定缺席，userVersion 前进到 7', () {
    final Database db = openMigrated();

    expect(db.userVersion, greaterThanOrEqualTo(7));

    final List<String> names = tableNames(db);
    for (final String t in <String>[
      'notes',
      'settings',
      'blocks',
      'ink_shards',
      'chunks_fts',
      'index_state',
      'rag_meta',
    ]) {
      expect(names, contains(t), reason: '缺少表 $t');
    }
    // 评审结论：sqlite-vec 那两张**成对**延后到接入 Ollama 时再建。
    expect(names, isNot(contains('vec_chunks')));
    expect(names, isNot(contains('vec_map')));
  });

  test('v7：FTS5 自带可用 + 中文必须 bigram 才有召回', () {
    final Database db = openMigrated();

    // bigram 预处理：相邻两字一切，空格分隔（设计文档 6.1）。
    const String searchText = '番茄 茄工 工作 作法';
    db.execute(
      'INSERT INTO chunks_fts (search_text, block_id, note_id, chunk_text) '
      'VALUES (?, ?, ?, ?)',
      <Object?>[searchText, 'b1', 'n1', '原文：番茄工作法'],
    );

    // ① 预处理过的 db 能被 bigram 查询命中。
    expect(
      db.select(
        "SELECT block_id FROM chunks_fts WHERE chunks_fts MATCH ?",
        <Object?>['"番茄"'],
      ),
      hasLength(1),
    );

    // ② **反面证据**：把同样的原文**不做预处理**直接塞进去，查"番茄"命中 0。
    // 这条断言存在的意义是：将来有人"优化掉" bigram 预处理时，这里立刻红。
    db.execute(
      'INSERT INTO chunks_fts (search_text, block_id, note_id, chunk_text) '
      'VALUES (?, ?, ?, ?)',
      <Object?>['番茄工作法', 'b2', 'n1', '原文：番茄工作法'],
    );
    expect(
      db.select(
        "SELECT block_id FROM chunks_fts WHERE chunks_fts MATCH ? AND block_id = 'b2'",
        <Object?>['"番茄"'],
      ),
      isEmpty,
      reason: '未做 bigram 预处理的中文不应被命中（这正是必须预处理的原因）',
    );

    // ③ UNINDEXED 列仍能取回原文做摘要。
    final Row hit = db
        .select(
          "SELECT chunk_text FROM chunks_fts WHERE chunks_fts MATCH ? AND block_id = 'b1'",
          <Object?>['"番茄"'],
        )
        .single;
    expect(hit['chunk_text'], '原文：番茄工作法');
  });

  test('v7：props_json / style_json 的 json_valid 约束生效', () {
    final Database db = openMigrated();
    insertNote(db, 'n1');

    expect(
      () => db.execute(
        'INSERT INTO blocks (id, note_id, type, props_json, ord, created_at, '
        "updated_at, fingerprint) VALUES ('b1','n1','paragraph','{坏 JSON',0,1,1,'fp1:1:1')",
      ),
      throwsA(isA<SqliteException>()),
      reason: '非法 JSON 必须被 CHECK 拒绝',
    );

    // 合法 JSON（含空对象默认值）应通过。
    db.execute(
      'INSERT INTO blocks (id, note_id, type, ord, created_at, updated_at, '
      "fingerprint) VALUES ('b2','n1','paragraph',0,1,1,'fp1:1:1')",
    );
    expect(db.select("SELECT props_json FROM blocks WHERE id='b2'").single['props_json'], '{}');
  });

  test('v7：删笔记级联清掉 blocks / ink_shards，母块级联清子块', () {
    final Database db = openMigrated();
    insertNote(db, 'n1');

    db.execute(
      'INSERT INTO blocks (id, note_id, type, ord, created_at, updated_at, '
      "fingerprint) VALUES ('母','n1','paragraph',0,1,1,'fp1:1:1')",
    );
    db.execute(
      'INSERT INTO blocks (id, note_id, type, ord, parent_id, created_at, '
      "updated_at, fingerprint) VALUES ('子','n1','paragraph',1024,'母',1,1,'fp1:1:2')",
    );
    db.execute(
      'INSERT INTO ink_shards (note_id, shard_index, points_blob, count, '
      "fingerprint, updated_at) VALUES ('n1',0,x'0000',3,'fp1:1:3',1)",
    );
    db.execute(
      "INSERT INTO index_state (block_id, fingerprint, model, updated_at) "
      "VALUES ('子','fp1:1:2','nomic-embed-text',1)",
    );

    db.execute("DELETE FROM blocks WHERE id = '母'");
    expect(
      db.select("SELECT COUNT(*) AS c FROM blocks WHERE note_id='n1'").single['c'],
      0,
      reason: '删母块应级联删子块；index_state 也应随之清掉',
    );
    expect(
      db.select('SELECT COUNT(*) AS c FROM index_state').single['c'],
      0,
    );

    db.execute("DELETE FROM notes WHERE id = 'n1'");
    expect(db.select('SELECT COUNT(*) AS c FROM ink_shards').single['c'], 0);
  });

  test('v7：index_state 以 block_id 为主键，重复索引是覆盖而非堆积', () {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    db.execute(
      'INSERT INTO blocks (id, note_id, type, ord, created_at, updated_at, '
      "fingerprint) VALUES ('b1','n1','paragraph',0,1,1,'fp1:1:1')",
    );

    void indexAs(String fp) => db.execute(
          'INSERT OR REPLACE INTO index_state (block_id, fingerprint, model, '
          'updated_at) VALUES (?,?,?,?)',
          <Object?>['b1', fp, 'nomic-embed-text', 1],
        );

    indexAs('fp1:1:1');
    indexAs('fp1:1:2'); // 块改了，指纹变了
    expect(
      db.select(
        "SELECT fingerprint FROM index_state WHERE block_id='b1'",
      ).single['fingerprint'],
      'fp1:1:2',
    );
    expect(db.select('SELECT COUNT(*) AS c FROM index_state').single['c'], 1);
  });
}
