import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sqlite3/sqlite3.dart';

/// v6 迁移的回归：**notes 表重建**（迁移第 0 步，见 `docs/data_layer.md`）。
///
/// 这一动之所以需要测试兜着，是因为它是**不可逆操作的近邻**：
/// 删表 + 改名。一旦拷数据的列名写漏一个，正文就静默没了，
/// 而应用在当下完全看不出来（列表只显示标题，正文要打开才读）。
///
/// 所以这份测试锁三件事：
/// 1. 迁移后 `kind` 能吃 `'canvas'`（此行的全部目的）；
/// 2. 旧行**一个字段都不丢**（逐列比对，而不是只比行数）；
/// 3. `CHECK` 依然有效（不能被重建弄丢了）。
void main() {
  /// 造一个**迁移前**的库：真实地重放 v1~v5 结束时 notes 应有的形状，
  /// 并把 userVersion 钉在 5，让生产迁移自己去跑 v6 分支。
  ///
  /// ⚠️ 这里**刻意**复制一份旧 schema 而不是复用 `AppDatabase` 的 CREATE：
  /// 那份 schema 已经变了，正是我们要覆盖的"历史形态"。
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

  void insertLegacyNote(
    Database db, {
    required String id,
    required String kind,
    required String title,
    required String content,
    required String hash,
    required String plainText,
    required int createdAt,
    required int revisedAt,
    int? promotedAt,
  }) {
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      'created_at, revised_at, promoted_at) VALUES (?,?,?,?,?,?,?,?,?)',
      <Object?>[
        id,
        kind,
        title,
        content,
        hash,
        plainText,
        createdAt,
        revisedAt,
        promotedAt,
      ],
    );
  }

  test('v6：旧库迁移后 kind 能吃 canvas，且旧行逐列无损', () {
    final Database db = openLegacy();
    addTearDown(db.close);

    insertLegacyNote(
      db,
      id: 'n1',
      kind: 'note',
      title: '一篇正式笔记',
      content: '{"v":2,"format":"blocks","document":{}}',
      hash: 'fp1:20:abc123',
      plainText: '正文一行',
      createdAt: 1700000000000,
      revisedAt: 1700000005000,
      promotedAt: 1700000001000,
    );
    insertLegacyNote(
      db,
      id: 'n2',
      kind: 'spark',
      title: '',
      content: '{"v":2,"format":"blocks","document":{}}',
      hash: 'fp1:0:def456',
      plainText: '',
      createdAt: 1700000002000,
      revisedAt: 1700000002000,
    );

    AppDatabase.migrateForTesting(db);

    expect(db.userVersion, greaterThanOrEqualTo(6));

    // 1) 此行的全部目的：画布能作为笔记形态落库。
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES ('c1','canvas','画名','{}','fp1:0:0','',0,0)",
    );
    expect(
      db.select('SELECT kind FROM notes WHERE id = ?', <Object?>['c1']).single
          ['kind'],
      'canvas',
    );

    // 2) 旧行逐列比对——比行数严格，拷数据漏列的错误藏不住。
    final Row row = db
        .select('SELECT * FROM notes WHERE id = ?', <Object?>['n1'])
        .single;
    expect(row['kind'], 'note');
    expect(row['title'], '一篇正式笔记');
    expect(row['content'], '{"v":2,"format":"blocks","document":{}}');
    expect(row['content_hash'], 'fp1:20:abc123');
    expect(row['plain_text'], '正文一行');
    expect(row['created_at'], 1700000000000);
    expect(row['revised_at'], 1700000005000);
    expect(row['promoted_at'], 1700000001000);
    // 新列存在且不改写旧数据。
    expect(row['deleted_at'], isNull);

    // 没传 promoted_at 的那条，迁移后仍应是 NULL（不能被写成 0）。
    expect(
      db.select('SELECT promoted_at FROM notes WHERE id = ?', <Object?>['n2'])
          .single['promoted_at'],
      isNull,
    );

    // 3) 行数一首一尾都对得上（没有多写也没少写）。
    expect(db.select('SELECT COUNT(*) AS c FROM notes').single['c'], 3);
  });

  test('v6：CHECK 仍然有效（非法 kind 被拒）', () {
    final Database db = openLegacy();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);

    expect(
      () => db.execute(
        "INSERT INTO notes (id, kind, title, content, content_hash, plain_text, "
        "created_at, revised_at) VALUES ('x','bogus','','','','',0,0)",
      ),
      throwsA(isA<SqliteException>()),
    );
    // 合法的三种仍照常通过。
    for (final String kind in <String>['spark', 'note', 'canvas']) {
      db.execute(
        'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
        "created_at, revised_at) VALUES (?,?,'','','','',0,0)",
        <Object?>['k_$kind', kind],
      );
    }
    expect(db.select('SELECT COUNT(*) AS c FROM notes').single['c'], 3);
  });

  test('v6：全新安装（空库）跑完迁移后同样可用', () {
    final Database db = sqlite3.openInMemory();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);

    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES ('c1','canvas','新画布','{}','fp1:0:0','',0,0)",
    );
    expect(db.select('SELECT COUNT(*) AS c FROM notes').single['c'], 1);
    // 外键在重建工序结束后必须重新开着，否则级联删除会失效。
    expect(
      db.select('PRAGMA foreign_keys;').single['foreign_keys'],
      isNonZero,
    );
  });
}
