import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sinan/src/data/database.dart';
import 'package:sqlite3/sqlite3.dart';

/// 连接 PRAGMA 配置（方案 2，2026-10-01）。
///
/// 要钉的不是"PRAGMA 能执行"这种废话，而是三条安全语义：
///  1. 文件库请求 WAL 后返回值只能是 `wal` 或合法回退 `delete`（网络盘），
///     且 WAL 成功是**文件级持久属性**——第二连接裸开也读到 wal；
///  2. `synchronous` 必须随 journal 联动：WAL ⇒ NORMAL(1)，其余 ⇒ FULL(2)，
///     绝不能在 DELETE 回滚模式下降档（掉电损坏风险）；
///  3. `busy_timeout` / `foreign_keys` 这两个连接级开关在每条路径上都打开。
///
/// 内存库（全项目 30 处测试夹具）不请求 WAL，保持原有行为不被新配置改变。
void main() {
  group('applyConnectionPragmas', () {
    test('文件库：WAL 落地、持久化、synchronous=NORMAL、-wal 文件出现', () {
      final Directory dir = Directory.systemTemp.createTempSync('sinan_wal_');
      final String path = p.join(dir.path, 'pragma.db');
      final Database db = sqlite3.open(path);
      late final Database second;
      try {
        final String journal = AppDatabase.applyConnectionPragmas(
          db,
          requestWal: true,
        );
        // 本机本地盘必然 wal；CI/重定向盘可能回退 delete，两者都合法。
        expect(<String>['wal', 'delete'], contains(journal));
        expect(db.select('PRAGMA busy_timeout;').single.values.first, 5000);
        expect(db.select('PRAGMA foreign_keys;').single.values.first, 1);

        final int sync =
            db.select('PRAGMA synchronous;').single.values.first as int;
        if (journal == 'wal') {
          expect(sync, 1); // NORMAL
          // 文件级持久属性：不做任何配置的第二连接也看到 wal。
          second = sqlite3.open(path);
          expect(
            second.select('PRAGMA journal_mode;').single.values.first,
            'wal',
          );
          // 写一笔后 WAL 文件真实存在（写走进 -wal 而不是覆盖主库）。
          db.execute('CREATE TABLE t(x INTEGER);');
          db.execute('INSERT INTO t VALUES (1);');
          expect(File(p.join(dir.path, 'pragma.db-wal')).existsSync(), isTrue);
          second.close();
        } else {
          // 回退环境必须保守 FULL，绝不跟着降 NORMAL。
          expect(sync, 2);
        }
      } finally {
        db.close();
        dir.deleteSync(recursive: true);
      }
    });

    test('内存库（不请求 WAL）：busy/外键打开，synchronous 保持 FULL', () {
      final Database db = sqlite3.openInMemory();
      try {
        final String journal = AppDatabase.applyConnectionPragmas(db);
        expect(journal, 'delete'); // 未请求时固定按保守口径返回
        expect(db.select('PRAGMA busy_timeout;').single.values.first, 5000);
        expect(db.select('PRAGMA foreign_keys;').single.values.first, 1);
        expect(
          db.select('PRAGMA synchronous;').single.values.first,
          2, // FULL：内存库无 WAL 语义，不能降档
        );
      } finally {
        db.close();
      }
    });

    test('内存库请求 WAL：SQLite 原样返回 memory，synchronous 仍为 FULL', () {
      final Database db = sqlite3.openInMemory();
      try {
        final String journal = AppDatabase.applyConnectionPragmas(
          db,
          requestWal: true,
        );
        expect(journal, 'memory');
        expect(db.select('PRAGMA synchronous;').single.values.first, 2);
      } finally {
        db.close();
      }
    });
  });
}
