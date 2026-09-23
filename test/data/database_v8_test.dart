import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sqlite3/sqlite3.dart';

/// v8 迁移的回归：**画布落点表**（`docs/canvas_architecture.md` 第七章）。
///
/// 与 v7 那份同口径——这一版还没有 UI 消费新表（处在五步纪律的"双写"阶段），所以
/// 重点是把设计约束钉死：
/// 1. 两张新表齐备（`ink_shards` 是 v7 就有的，画布笔迹直接用它）；
/// 2. `vec_chunks` 已由 v10 落地（机制 A）；`vec_map`（vec0 时代的 rowid 映射）不应存在；
/// 3. 外键级联、`json_valid` CHECK、`userVersion` 前进三者都成立。
void main() {
  Database openMigrated() {
    final Database db = sqlite3.openInMemory();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    return db;
  }

  String insertCanvasNote(Database db, String id) {
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES (?, 'canvas', '画布', '', 'fp1:0:0', '', 1, 1)",
      <Object?>[id],
    );
    return id;
  }

  List<String> tableNames(Database db) => <String>[
    for (final Row r in db.select(
      "SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name",
    ))
      r['name'] as String,
  ];

  test('v8：画布表齐备，userVersion 前进到 8', () {
    final Database db = openMigrated();

    expect(db.userVersion, greaterThanOrEqualTo(8));

    final List<String> names = tableNames(db);
    for (final String t in <String>[
      'notes',
      'blocks',
      'ink_shards',
      'canvas_items',
      'canvas_meta',
    ]) {
      expect(names, contains(t), reason: '缺少表 $t');
    }
    // v10 已落地向量路（机制 A）：vec_chunks 是普通表；vec_map 不该存在。
    expect(names, contains('vec_chunks'));
    expect(names, isNot(contains('vec_map')));
  });

  test('v8：删笔记级联清掉 canvas_items / canvas_meta / ink_shards', () {
    final Database db = openMigrated();
    insertCanvasNote(db, 'c1');

    db.execute(
      'INSERT INTO canvas_items (id, note_id, kind, z, x1, y1, x2, y2, '
      "created_at, updated_at, fingerprint) VALUES "
      "('s1','c1','shape.rectangle',0,0,0,10,20,1,1,'fp1:1:1')",
    );
    db.execute(
      'INSERT INTO canvas_meta (note_id, camera_json, schema_version, updated_at) '
      "VALUES ('c1','{}',2,1)",
    );
    db.execute(
      'INSERT INTO ink_shards (note_id, shard_index, points_blob, count, '
      "fingerprint, updated_at) VALUES ('c1',0,x'0000',1,'fp1:1:2',1)",
    );

    db.execute("DELETE FROM notes WHERE id = 'c1'");
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'], 0);
    expect(db.select('SELECT COUNT(*) AS c FROM canvas_meta').single['c'], 0);
    expect(db.select('SELECT COUNT(*) AS c FROM ink_shards').single['c'], 0);
  });

  test('v8：canvas_items 主键是 (note_id, id)——item id 跨画布会撞号', () {
    final Database db = openMigrated();
    insertCanvasNote(db, 'c1');
    insertCanvasNote(db, 'c2');

    // 同一个 id 在两张画布下各存一行（内核的 item id 是进程内计数器，重启后从头来）。
    for (final String note in <String>['c1', 'c2']) {
      db.execute(
        'INSERT INTO canvas_items (id, note_id, kind, z, x1, y1, x2, y2, '
        "created_at, updated_at, fingerprint) VALUES "
        "('item-1',?,'shape.rectangle',0,0,0,1,1,1,1,'fp1:1:1')",
        <Object?>[note],
      );
    }

    expect(db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'], 2);
    expect(
      db
          .select("SELECT note_id FROM canvas_items WHERE id = 'item-1'")
          .map((Row r) => r['note_id'])
          .toSet(),
      <String>{'c1', 'c2'},
    );
  });

  test('v8：camera_json / props_json 的 json_valid 约束生效', () {
    final Database db = openMigrated();
    insertCanvasNote(db, 'c1');

    expect(
      () => db.execute(
        'INSERT INTO canvas_meta (note_id, camera_json, schema_version, updated_at) '
        "VALUES ('c1','{坏 JSON',2,1)",
      ),
      throwsA(isA<SqliteException>()),
      reason: '非法 JSON 必须被 CHECK 拒绝',
    );

    // 默认值可用（props_json 缺省 '{}'）。
    db.execute(
      'INSERT INTO canvas_items (id, note_id, kind, z, x1, y1, x2, y2, '
      "created_at, updated_at, fingerprint) VALUES "
      "('s1','c1','image',0,0,0,1,1,1,1,'fp1:1:1')",
    );
    expect(
      db
          .select("SELECT props_json FROM canvas_items WHERE id='s1'")
          .single['props_json'],
      '{}',
    );
  });
}
