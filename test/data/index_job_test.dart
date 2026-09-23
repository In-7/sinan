import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/ai/embedding_client.dart';
import 'package:sinan/src/data/chunker.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/embedding_backend.dart';
import 'package:sinan/src/data/index_job.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_vector/sqlite_vector.dart';

/// 索引任务的回归（`docs/data_layer.md` 6.5 / 6.7 R3）。验收口径就是 6.5 那五条：
/// **增量、幂等（重复点零开销）、可取消、有进度、失败可重试**——外加两条通道
/// 的降级（没模型也能建关键词路）。
class _FakeClient implements EmbeddingClient {
  _FakeClient({this.unavailable = false});

  bool unavailable;
  final List<List<String>> calls = <List<String>>[];

  @override
  String get provider => 'fake';

  @override
  String get model => 'emb';

  @override
  Future<List<Float32List>> embed(List<String> inputs) async {
    calls.add(inputs);
    if (unavailable) {
      throw const LlmUnavailableException('连不上模型服务（测试）');
    }
    return <Float32List>[
      for (final String _ in inputs) Float32List.fromList(<double>[0.5, 0.5]),
    ];
  }
}

void main() {
  sqlite3.loadSqliteVectorExtension();

  Database openMigrated() {
    final Database db = sqlite3.openInMemory();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    return db;
  }

  void insertNote(Database db, String id, {String? deletedAt}) {
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at, deleted_at) VALUES (?, 'note', '标题', '', "
      "'fp1:0:0', '', 1, 1, ?)",
      <Object?>[id, deletedAt],
    );
  }

  /// 插一个块；[text] 为 null 表示"没有文本"的块（分隔线/图片那类）。
  void insertBlock(
    Database db,
    String id,
    String noteId,
    String? text, {
    String fingerprint = 'fp1:x',
  }) {
    db.execute(
      'INSERT INTO blocks (id, note_id, type, props_json, ord, created_at, '
      'updated_at, fingerprint) VALUES (?, ?, ?, ?, 0, 1, 1, ?)',
      <Object?>[
        id,
        noteId,
        'paragraph',
        // 一律 jsonEncode：文本里可能有换行/引号，手拼会写出非法 JSON。
        text == null ? '{}' : jsonEncode(<String, Object?>{'text': text}),
        fingerprint,
      ],
    );
  }

  int ftsRows(Database db, String blockId) =>
      db.select(
            'SELECT COUNT(*) AS c FROM chunks_fts WHERE block_id = ?',
            <Object?>[blockId],
          ).single['c']
          as int;

  test('pendingCount：只数有文本的块；空文本块不参与索引', () {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1', '有文本');
    insertBlock(db, 'b2', 'n1', null); // 分隔线那类

    expect(IndexJob(db: db).pendingCount(), 1);
  });

  test('pendingCount：已删笔记的块不计', () {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertNote(db, 'n2', deletedAt: '2026-09-21');
    insertBlock(db, 'b1', 'n1', '活着的');
    insertBlock(db, 'b2', 'n2', '已删的');

    expect(IndexJob(db: db).pendingCount(), 1);
  });

  test('backend 为 null ⇒ 只建关键词路（6.4 降级在索引侧的形态）', () async {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1', '番茄工作法');
    final IndexJob job = IndexJob(db: db);

    final IndexResult result = await job.run(onProgress: (IndexProgress _) {});

    expect(result.done, 1);
    expect(ftsRows(db, 'b1'), 1);
    expect(
      db.select('SELECT COUNT(*) AS c FROM index_state').single['c'],
      0,
      reason: '没有模型就不该写索引进度记录，否则会被误判为"已索引"',
    );
    expect(job.pendingCount(), 1, reason: '语义路没建，块仍待处理');
  });

  test('两条通道一次写完：FTS + 向量 + 进度记录，随后待处理归零', () async {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1', '番茄工作法', fingerprint: 'fp1:a');
    final _FakeClient client = _FakeClient();
    final IndexJob job = IndexJob(
      db: db,
      backend: LocalEmbeddingBackend(db: db, client: client),
    );

    final List<IndexProgress> progress = <IndexProgress>[];
    final IndexResult result = await job.run(onProgress: progress.add);

    expect(result.total, 1);
    expect(result.done, 1);
    expect(result.failed, 0);
    expect(result.cancelled, isFalse);
    expect(ftsRows(db, 'b1'), 1);
    expect(db.select('SELECT COUNT(*) AS c FROM vec_chunks').single['c'], 1);
    expect(
      db
          .select("SELECT chunker_version FROM index_state WHERE block_id='b1'")
          .single['chunker_version'],
      kChunkerVersion,
    );
    expect(progress.last, (done: 1, total: 1, failed: 0));
    expect(job.pendingCount(), 0);
  });

  test('幂等：重复点按钮零开销（不再请求模型）', () async {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1', '文本', fingerprint: 'fp1:a');
    final _FakeClient client = _FakeClient();
    final IndexJob job = IndexJob(
      db: db,
      backend: LocalEmbeddingBackend(db: db, client: client),
    );

    await job.run(onProgress: (IndexProgress _) {});
    final int callsAfterFirst = client.calls.length;
    final IndexResult second = await job.run(onProgress: (IndexProgress _) {});

    expect(second.total, 0, reason: '没有待处理块就不该取数');
    expect(client.calls.length, callsAfterFirst, reason: '重复点击不应再请求模型');
  });

  test('增量：指纹变了才重算那一块', () async {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1', '甲', fingerprint: 'fp1:a');
    insertBlock(db, 'b2', 'n1', '乙', fingerprint: 'fp1:b');
    final _FakeClient client = _FakeClient();
    final IndexJob job = IndexJob(
      db: db,
      backend: LocalEmbeddingBackend(db: db, client: client),
    );
    await job.run(onProgress: (IndexProgress _) {});

    db.execute("UPDATE blocks SET fingerprint = 'fp1:a2' WHERE id = 'b1'");
    expect(job.pendingCount(), 1);

    final IndexResult second = await job.run(onProgress: (IndexProgress _) {});
    expect(second.total, 1);
    expect(client.calls.last, <String>['甲'], reason: '只该重算变了的块');
  });

  test('超长块 ⇒ 多 chunk 两条通道都摊开，进度记录仍是一块一行', () async {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    final String long = <String>['${'甲' * 400}。', '${'乙' * 400}。'].join('\n\n');
    insertBlock(db, 'b1', 'n1', long, fingerprint: 'fp1:a');
    final _FakeClient client = _FakeClient();
    final IndexJob job = IndexJob(
      db: db,
      backend: LocalEmbeddingBackend(db: db, client: client),
    );

    await job.run(onProgress: (IndexProgress _) {});

    expect(ftsRows(db, 'b1'), greaterThan(1));
    expect(
      db.select('SELECT COUNT(*) AS c FROM vec_chunks').single['c'],
      greaterThan(1),
    );
    expect(
      db.select('SELECT COUNT(*) AS c FROM index_state').single['c'],
      1,
      reason: 'block 是新鲜度单元：一块只记一行',
    );
  });

  test('可取消：批次边界停下，且不写任何东西', () async {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1', '文本', fingerprint: 'fp1:a');
    final IndexCancelToken token = IndexCancelToken()..cancel();

    final IndexResult result = await IndexJob(db: db)
        .run(onProgress: (IndexProgress _) {}, cancelToken: token);

    expect(result.cancelled, isTrue);
    expect(ftsRows(db, 'b1'), 0);
  });

  test('模型不可达：中止整轮、关键词路已生效、块仍待处理', () async {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1', '文本', fingerprint: 'fp1:a');
    final _FakeClient client = _FakeClient(unavailable: true);
    final IndexJob job = IndexJob(
      db: db,
      backend: LocalEmbeddingBackend(db: db, client: client),
    );

    final IndexResult result = await job.run(onProgress: (IndexProgress _) {});

    expect(result.abortReason, isNotNull);
    expect(ftsRows(db, 'b1'), 1, reason: '关键词路不需要模型，应当已经生效');
    expect(job.pendingCount(), 1, reason: '语义路没成，下次点继续补');
  });
}
