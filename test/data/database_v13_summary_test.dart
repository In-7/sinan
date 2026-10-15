import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// v13 迁移的回归：`notes.summary` 投影列（plain_text 前 160 字符）。
///
/// 钉三件事：
/// 1. 存量行的 `summary` 由 `substr(plain_text, 1, 160)` **一次性回填**，
///    而 `plain_text` 原文一个字都不许动（全文搜索 / 字数统计还靠它）；
/// 2. 短文本原样回填，不补不截；
/// 3. 门闩**幂等重入**（版本号回拨 / 半成品夹具再跑一次不炸、不重写）。
void main() {
  /// 造一个 v5 形态的旧库（形状复制自 database_v6_test.dart：那份 schema
  /// 已演进，这里刻意保留"历史形态"让生产迁移自己跑到 v13）。
  Database openLegacy() {
    final Database db = sqlite3.openInMemory();
    db.execute('''CREATE TABLE notes (
      id           TEXT PRIMARY KEY,
      kind         TEXT NOT NULL CHECK (kind IN ('spark','note')),
      title        TEXT NOT NULL DEFAULT '',
      content      TEXT NOT NULL DEFAULT '',
      content_hash TEXT NOT NULL,
      plain_text   TEXT NOT NULL DEFAULT '',
      created_at   INTEGER NOT NULL,
      revised_at   INTEGER NOT NULL,
      promoted_at  INTEGER
    );''');
    db.execute('''CREATE TABLE settings (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );''');
    db.userVersion = 5;
    return db;
  }

  void insertNote(Database db, String id, String plainText) {
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      'created_at, revised_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[id, 'note', '', '', 'fp1:0:0', plainText, 1, 1],
    );
  }

  test('v13：summary 按前 160 字回填，plain_text 原文无损；短文本原样', () {
    final Database db = openLegacy();
    addTearDown(db.close);

    final String longText = '字' * 200;
    insertNote(db, 'long', longText);
    insertNote(db, 'short', '短文本');

    AppDatabase.migrateForTesting(db);

    expect(
      db.userVersion,
      greaterThanOrEqualTo(13),
      reason: 'v13 已跑（其后 v14 给 kind 加了 stream，链式继续）',
    );
    final ResultSet rows = db.select(
      'SELECT id, plain_text, summary FROM notes ORDER BY id',
    );
    final Map<String, Map<String, Object?>> byId = <String, Map<String, Object?>>{
      for (final Row r in rows) r['id'] as String: r,
    };

    // 长文：summary 恰好 160 字、等于前缀；plain_text 仍是完整 200 字。
    expect(
      byId['long']!['summary'] as String,
      longText.substring(0, Note.summaryLength),
    );
    expect((byId['long']!['summary'] as String).length, Note.summaryLength);
    expect(byId['long']!['plain_text'] as String, longText);

    // 短文：原样，不补不截。
    expect(byId['short']!['summary'] as String, '短文本');
    expect(byId['short']!['plain_text'] as String, '短文本');
  });

  test('v13：迁移幂等重入不抛、不重写', () {
    final Database db = openLegacy();
    addTearDown(db.close);
    insertNote(db, 'n1', '一次写完的内容');

    AppDatabase.migrateForTesting(db);
    final String first = db.select(
      'SELECT summary FROM notes WHERE id = ?',
      <Object?>['n1'],
    ).single['summary'] as String;

    // 再跑一遍：门闩与列存在性检查都应安全跳过。
    AppDatabase.migrateForTesting(db);
    final String second = db.select(
      'SELECT summary FROM notes WHERE id = ?',
      <Object?>['n1'],
    ).single['summary'] as String;

    expect(
      db.userVersion,
      greaterThanOrEqualTo(13),
      reason: 'v13 已跑（其后 v14 给 kind 加了 stream，链式继续）',
    );
    expect(second, first);
  });
}
