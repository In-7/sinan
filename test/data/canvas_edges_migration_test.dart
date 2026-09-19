import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sqlite3/sqlite3.dart';

/// 存量库迁移回归（2026-09-18 用户实测崩溃）。
///
/// 根因：早期 v9 的 `canvas_edges` DDL **没有 `fingerprint` 列**，而
/// `userVersion` 已经被写成 9 ⇒ `if (db.userVersion < 9)` 不再成立，建表语句
/// 永不重跑 ⇒ 每次自动保存都抛
/// `no such column: fingerprint`（`CanvasStore._existingEdges`）。
///
/// 修复 = 迁移末尾的**列自愈**（`AppDatabase._repairCanvasEdgesTable`）：表是
/// 影子副本（只写不读）⇒ 缺列就重建，不丢用户数据。
void main() {
  test('canvas_edges 缺 fingerprint 列的存量库 ⇒ 迁移后自愈，SELECT 不再抛', () {
    final Database db = sqlite3.openInMemory();
    // 造一个"早期 v9"库：notes 在、canvas_edges 是**缺列**的老 DDL、userVersion = 9。
    db.execute('''
      CREATE TABLE notes (
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL DEFAULT '', content_hash TEXT NOT NULL,
        plain_text TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL,
        revised_at INTEGER NOT NULL, promoted_at INTEGER, deleted_at INTEGER
      );
    ''');
    db.execute('''
      CREATE TABLE canvas_edges (
        id TEXT NOT NULL, note_id TEXT NOT NULL, from_id TEXT NOT NULL,
        to_id TEXT NOT NULL, from_side TEXT, to_side TEXT,
        props_json TEXT NOT NULL DEFAULT '{}', PRIMARY KEY (note_id, id)
      );
    ''');
    db.userVersion = 9;

    AppDatabase.migrateForTesting(db);

    // 自愈后该列存在：这条**曾经抛异常**的语句现在应正常返回空集。
    expect(
      db.select(
        'SELECT id, fingerprint FROM canvas_edges WHERE note_id = ?',
        <Object?>['n1'],
      ),
      isEmpty,
    );
    db.close();
  });

  test('迁移幂等：再跑一次不抛（表已带列 ⇒ 直接跳过）', () {
    final Database db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    AppDatabase.migrateForTesting(db);
    final List<String> cols = <String>[
      for (final Row r in db.select('PRAGMA table_info(canvas_edges)'))
        r['name'] as String,
    ];
    expect(cols, contains('fingerprint'));
    db.close();
  });

  test('新库迁移后 canvas_edges 带 fingerprint 列', () {
    final Database db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    final List<String> cols = <String>[
      for (final Row r in db.select('PRAGMA table_info(canvas_edges)'))
        r['name'] as String,
    ];
    expect(cols, contains('fingerprint'));
    expect(cols, contains('from_side'));
    db.close();
  });
}
