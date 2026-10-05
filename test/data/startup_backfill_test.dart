import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sinan/src/data/block_store.dart';
import 'package:sinan/src/data/canvas_store.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/index_job.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/startup_backfill.dart';
import 'package:sqlite3/sqlite3.dart';

/// 启动回填后台 isolate（阶段 A，2026-10-01）。
///
/// 两类保证要钉：
///  A. **端到端**：worker 用独立连接开同一个文件库，把三类存量派生数据补齐
///     （blocks / canvas 三表 / chunks_fts），且与主连接同时存活时不打架；
///     再跑一遍幂等、行数不增；坏路径（打不开文件）错误能传回调用方。
///  B. **并发守卫**：投影前逐篇重读"已落表"标记 + 取**最新** content，
///     已投影返 null，不被候选名单时刻的旧快照带跑。
void main() {
  String v2Doc(String blockId, String text) => jsonEncode(<String, Object?>{
        'v': 2,
        'format': 'blocks',
        'document': <String, Object?>{
          'id': 'root',
          'type': 'page',
          'children': <Map<String, Object?>>[
            <String, Object?>{
              'id': blockId,
              'type': 'paragraph',
              'data': <String, Object?>{'text': text},
            },
          ],
        },
      });

  String canvasWithRect() => jsonEncode(<String, Object?>{
        'camera': <String, Object?>{
          'scale': 1.0,
          'translation': <double>[0.0, 0.0],
          'minScale': 0.05,
          'maxScale': 4.0,
        },
        'document': <String, Object?>{
          'schemaVersion': 2,
          'strokes': <String, Object?>{},
          'items': <String, Object?>{
            'r1': <String, Object?>{
              'type': 'shape',
              'id': 'r1',
              'kind': 'rectangle',
              'color': 0xFF1F1F1F,
              'strokeWidth': 2.0,
              'filled': false,
              'angle': 0.0,
              'rect': <double>[0.0, 0.0, 10.0, 20.0],
              'meta': <String, Object?>{},
            },
          },
          'strokeOrder': <String>[],
          'itemOrder': <String>['r1'],
        },
      });

  group('runStartupBackfill（后台 isolate 端到端）', () {
    late Directory dir;
    late String path;
    late Database db;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('sinan_backfill_');
      path = p.join(dir.path, 'sinan.db');
      db = sqlite3.open(path);
      // 与生产 AppDatabase.open 同口径（主连接保持开着：刻意验证双连接并发）。
      AppDatabase.applyConnectionPragmas(db, requestWal: true);
      AppDatabase.migrateForTesting(db);

      // 裸 INSERT 造"存量未投影"现场（store.create 会立刻双写，造不出来）。
      void legacy(String id, String kind, String content) {
        db.execute(
          'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
          'created_at, revised_at) VALUES (?,?,?,?,?,?,?,?)',
          <Object?>[id, kind, '', content, 'fp1:1:$id', '', 1, 1],
        );
      }

      legacy('n1', 'note', v2Doc('b1', '番茄工作法关键词'));
      legacy('c1', 'canvas', canvasWithRect());
      expect(db.select('SELECT COUNT(*) AS c FROM blocks').single['c'], 0);
      expect(db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'], 0);
      expect(db.select('SELECT COUNT(*) AS c FROM chunks_fts').single['c'], 0);
    });

    tearDown(() {
      db.close();
      dir.deleteSync(recursive: true);
    });

    test('三类派生数据在 worker 中全部补齐，主连接立即可见', () async {
      await runStartupBackfill(path);

      expect(
        db.select('SELECT note_id FROM blocks').map((Row r) => r['note_id']),
        contains('n1'),
      );
      expect(
        db.select('SELECT note_id FROM canvas_meta').map(
          (Row r) => r['note_id'],
        ),
        contains('c1'),
      );
      expect(db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'], 1);
      // 关键词路可搜（bigram 词元 "番茄"）。
      final ResultSet hit = db.select(
        'SELECT note_id FROM chunks_fts WHERE chunks_fts MATCH ?',
        <Object?>['"番茄"'],
      );
      expect(hit.map((Row r) => r['note_id']), contains('n1'));
    });

    test('再跑一遍幂等：已投影的不动，行数不增', () async {
      await runStartupBackfill(path);
      final int blocks = db.select('SELECT COUNT(*) AS c FROM blocks').single['c'] as int;
      final int items = db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'] as int;
      final int fts = db.select('SELECT COUNT(*) AS c FROM chunks_fts').single['c'] as int;

      await runStartupBackfill(path);
      expect(db.select('SELECT COUNT(*) AS c FROM blocks').single['c'], blocks);
      expect(db.select('SELECT COUNT(*) AS c FROM canvas_items').single['c'], items);
      expect(db.select('SELECT COUNT(*) AS c FROM chunks_fts').single['c'], fts);
    });

    test('打不开库（路径不存在）：错误经 Future 传回，不静默吞掉', () async {
      final String bad = p.join(dir.path, 'no_such_dir', 'x.db');
      await expectLater(runStartupBackfill(bad), throwsA(isA<SqliteException>()));
    });
  });

  group('并发守卫（投影前重读标记 + 最新 content）', () {
    late Database db;

    setUp(() {
      db = sqlite3.openInMemory();
      AppDatabase.migrateForTesting(db);
      db.execute('PRAGMA foreign_keys = ON;');
    });

    tearDown(() => db.close());

    void legacy(String id, String kind, String content) {
      db.execute(
        'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
        'created_at, revised_at) VALUES (?,?,?,?,?,?,?,?)',
        <Object?>[id, kind, '', content, 'fp1:1:$id', '', 1, 1],
      );
    }

    test('blocks：未投影给最新 content；名单后 content 被改读到的是新值；投影后 null',
        () {
      final BlockStore blocks = BlockStore(db);
      legacy('n1', 'note', v2Doc('b1', '旧正文'));

      expect(blocks.pendingBackfillContent('n1'), contains('旧正文'));

      // 模拟"候选名单选出后、投影前，用户保存了同一篇"：真源已换新。
      db.execute(
        'UPDATE notes SET content = ? WHERE id = ?',
        <Object?>[v2Doc('b1', '新正文'), 'n1'],
      );
      expect(
        blocks.pendingBackfillContent('n1'),
        contains('新正文'),
        reason: '必须重读最新 content，拿名单快照去投影就会覆盖新数据',
      );

      expect(NoteStore(db).backfillBlocks(), 1);
      expect(
        blocks.pendingBackfillContent('n1'),
        isNull,
        reason: '保存/回填路径已落 blocks 行 ⇒ 守卫必须放行跳过',
      );
    });

    test('canvas：未投影给 content，已落 meta / 空白画布 / 不存在 ⇒ null', () {
      final CanvasStore canvas = CanvasStore(db);
      legacy('c1', 'canvas', canvasWithRect());
      legacy('c2', 'canvas', '');

      expect(canvas.pendingBackfillContent('c1'), isNotNull);
      expect(canvas.pendingBackfillContent('c2'), isNull);
      expect(canvas.pendingBackfillContent('ghost'), isNull);

      expect(NoteStore(db).backfillCanvas(), 1);
      expect(canvas.pendingBackfillContent('c1'), isNull);
    });

    test('关键词索引：已有 FTS 行即不再待建（避免与保存路径抢写）', () {
      final IndexJob job = IndexJob(db: db);
      legacy('n1', 'note', v2Doc('b1', '番茄工作法关键词'));
      expect(job.isKeywordIndexPending('n1'), isTrue);

      NoteStore(db).backfillBlocks();
      job.ensureKeywordIndex();
      expect(job.isKeywordIndexPending('n1'), isFalse);
    });
  });
}
