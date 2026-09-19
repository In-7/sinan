import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sqlite3/sqlite3.dart';

/// v9 迁移的回归：**块结构画布的地基**（卡片落点 + 自由连线）。
///
/// 与 v8 那份同口径——这一版仍没有 UI 消费新表，重点是把**设计约束**钉死：
/// 1. `canvas_items.block_id` 到位、`canvas_edges` 建成；
/// 2. **卡片分裂存储**：内容在 `blocks`、几何在 `canvas_items`，靠 block_id 关联；
/// 3. **binding**：边存 **id 而不是坐标** ⇒ 删卡片时几何与连线一起级联消失；
/// 4. **存量库补列幂等**：已升到 v8 的库（表是旧 DDL 建的、缺列）能补上。
///
/// 设计依据见 `database.dart` 的 v9 分支注释与
/// `docs/canvas_architecture.md` 第七章（为什么卡片是"不进 blocks"的例外）。
void main() {
  Database openMigrated() {
    final Database db = sqlite3.openInMemory();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    return db;
  }

  void insertCanvasNote(Database db, String id) {
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES (?, 'canvas', '画布', '', 'fp1:0:0', '', 1, 1)",
      <Object?>[id],
    );
  }

  /// 插一张**卡片**：内容进 `blocks`、几何进 `canvas_items`（分裂存储的两半）。
  void insertCard(
    Database db, {
    required String noteId,
    required String blockId,
    required String itemId,
  }) {
    db.execute(
      'INSERT INTO blocks (id, note_id, type, props_json, ord, created_at, '
      'updated_at, fingerprint) VALUES (?,?,?,?,?,1,1,?)',
      <Object?>[blockId, noteId, 'card', '{"text":"想法"}', 0, 'fp1:$blockId'],
    );
    db.execute(
      'INSERT INTO canvas_items (id, note_id, kind, z, x1, y1, x2, y2, '
      'created_at, updated_at, fingerprint, block_id) VALUES (?,?,?,?,?,?,?,?,1,1,?,?)',
      <Object?>[itemId, noteId, 'card', 0, 0, 0, 100, 60, 'fp1:$itemId', blockId],
    );
  }

  List<String> tableNames(Database db) => <String>[
    for (final Row r in db.select(
      "SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name",
    ))
      r['name'] as String,
  ];

  bool hasColumn(Database db, String table, String column) {
    for (final Row r in db.select('PRAGMA table_info($table)')) {
      if (r['name'] == column) return true;
    }
    return false;
  }

  test('v9：block_id 到位、canvas_edges 建成，vec 表仍按约定缺席', () {
    final Database db = openMigrated();

    expect(db.userVersion, greaterThanOrEqualTo(9));

    final List<String> names = tableNames(db);
    expect(names, contains('canvas_edges'));
    // v7 的约定继续有效：sqlite-vec 那两张成对延后。
    expect(names, isNot(contains('vec_chunks')));
    expect(names, isNot(contains('vec_map')));

    // 几何表里必须能承接"卡片"（形状/图片这一列是 NULL）。
    expect(hasColumn(db, 'canvas_items', 'block_id'), isTrue);
  });

  test('卡片分裂存储：内容在 blocks，几何在 canvas_items，靠 block_id 关联', () {
    final Database db = openMigrated();
    insertCanvasNote(db, 'c1');
    insertCard(db, noteId: 'c1', blockId: 'b1', itemId: 'card-1');

    // 内容（要能被 FTS5 / 向量检索到）。
    expect(
      db.select("SELECT type, props_json FROM blocks WHERE id='b1'").single['type'],
      'card',
    );
    // 几何（视口裁剪每帧要用 ⇒ 必须是真列，不能塞 JSON）。
    final Row item = db
        .select("SELECT kind, x2, y2, block_id FROM canvas_items WHERE id='card-1'")
        .single;
    expect(item['kind'], 'card');
    expect(item['x2'], 100.0);
    expect(item['block_id'], 'b1');
  });

  test('binding：边存 id 不存坐标，删卡片时几何与连线一起级联消失', () {
    final Database db = openMigrated();
    insertCanvasNote(db, 'c1');
    insertCard(db, noteId: 'c1', blockId: 'b1', itemId: 'card-1');
    insertCard(db, noteId: 'c1', blockId: 'b2', itemId: 'card-2');

    db.execute(
      'INSERT INTO canvas_edges (id, note_id, from_id, to_id, from_side, to_side, '
      "fingerprint) VALUES ('e1','c1','b1','b2','right','left','fp1:e1')",
    );
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_edges').single['c'], 1);

    // 删掉卡片 b1：**内容**一走，几何行与所有以它为端点的边都该消失
    // ——这正是"存 id 而不是坐标"换来的（否则会留下指向虚无的悬空连线）。
    db.execute("DELETE FROM blocks WHERE id='b1'");
    expect(
      db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'],
      1,
      reason: '卡片的几何行没跟着走：会留下没有内容的空框',
    );
    expect(
      db.select('SELECT COUNT(*) AS c FROM canvas_edges').single['c'],
      0,
      reason: '连线没跟着走：会留下指向已删卡片的悬空边',
    );
  });

  test('边指向不存在的块会被外键拒绝（binding 的引用完整性）', () {
    final Database db = openMigrated();
    insertCanvasNote(db, 'c1');

    expect(
      () => db.execute(
        'INSERT INTO canvas_edges (id, note_id, from_id, to_id) '
        "VALUES ('e1','c1','不存在','也不存在')",
      ),
      throwsA(isA<SqliteException>()),
      reason: '边必须指向真实存在的块',
    );
  });

  test('删画布笔记：卡片、几何、连线一并级联清空', () {
    final Database db = openMigrated();
    insertCanvasNote(db, 'c1');
    insertCard(db, noteId: 'c1', blockId: 'b1', itemId: 'card-1');
    insertCard(db, noteId: 'c1', blockId: 'b2', itemId: 'card-2');
    db.execute(
      'INSERT INTO canvas_edges (id, note_id, from_id, to_id, fingerprint) '
      "VALUES ('e1','c1','b1','b2','fp1:e1')",
    );

    db.execute("DELETE FROM notes WHERE id='c1'");
    expect(db.select('SELECT COUNT(*) AS c FROM blocks').single['c'], 0);
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'], 0);
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_edges').single['c'], 0);
  });

  test('存量库（已升到 v8、缺 block_id）能补列，且幂等不报错', () {
    final Database db = sqlite3.openInMemory();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);

    // 把 canvas_items 还原成 **v8 的旧形态**（没有 block_id），并把版本号退回 8，
    // 模拟"用户的库已经升到 v8、还没见过 v9"——这是补列分支唯一的服务对象。
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute('DROP TABLE canvas_items;');
    db.execute('''
      CREATE TABLE canvas_items (
        id TEXT NOT NULL,
        note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        z INTEGER NOT NULL,
        x1 REAL NOT NULL, y1 REAL NOT NULL, x2 REAL NOT NULL, y2 REAL NOT NULL,
        angle REAL NOT NULL DEFAULT 0,
        color INTEGER, filled INTEGER, stroke_width REAL, src TEXT,
        props_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(props_json)),
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        fingerprint TEXT NOT NULL,
        PRIMARY KEY (note_id, id)
      );
    ''');
    db.userVersion = 8;

    expect(hasColumn(db, 'canvas_items', 'block_id'), isFalse);

    // 再跑一次迁移：v9 分支应当补上这一列（而不是抛 duplicate column）。
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    expect(hasColumn(db, 'canvas_items', 'block_id'), isTrue);

    // 补列后功能完好：仍然能承接卡片。
    insertCanvasNote(db, 'c1');
    insertCard(db, noteId: 'c1', blockId: 'b1', itemId: 'card-1');
    expect(
      db.select("SELECT block_id FROM canvas_items WHERE id='card-1'").single['block_id'],
      'b1',
    );

    // 幂等：重复迁移不报错（ALTER 前判了列是否存在）。
    AppDatabase.migrateForTesting(db);
    expect(hasColumn(db, 'canvas_items', 'block_id'), isTrue);
  });
}
