import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/ai/embedding_client.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/embedding_backend.dart';
import 'package:sinan/src/data/index_job.dart';
import 'package:sinan/src/data/retriever.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_vector/sqlite_vector.dart';

/// 词向量由文本决定（便于构造"某块只被语义路命中"这类场景）。
class _FakeClient implements EmbeddingClient {
  _FakeClient({
    this.vectors = const <String, List<double>>{},
    this.fail = false,
  });

  final Map<String, List<double>> vectors;
  final bool fail;

  @override
  String get provider => 'fake';

  @override
  String get model => 'emb';

  @override
  Future<List<Float32List>> embed(List<String> inputs) async {
    if (fail) throw const LlmUnavailableException('连不上模型服务（测试）');
    return <Float32List>[
      for (final String t in inputs)
        Float32List.fromList(vectors[t] ?? const <double>[0.5, 0.5]),
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

  void insertNote(Database db, String id) {
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES (?, 'note', '标题', '', 'fp1:0:0', '', 1, 1)",
      <Object?>[id],
    );
  }

  void insertBlock(Database db, String id, String noteId, String text) {
    db.execute(
      'INSERT INTO blocks (id, note_id, type, props_json, ord, created_at, '
      'updated_at, fingerprint) VALUES (?, ?, ?, ?, 0, 1, 1, ?)',
      <Object?>[
        id,
        noteId,
        'paragraph',
        jsonEncode(<String, Object?>{'text': text}),
        'fp1:$id',
      ],
    );
  }

  group('RRF 纯函数（6.4）', () {
    test('分数 = Σ 1/(k+rank+1)：两路都命中 ⇒ 分数是两路之和、排最前', () {
      final List<RrfEntry> fused = Retriever.fuse(
        keywordOrder: <String>['A', 'B'],
        vectorOrder: <String>['B', 'C'],
      );
      final Map<String, RrfEntry> byId = <String, RrfEntry>{
        for (final RrfEntry e in fused) e.id: e,
      };

      expect(fused.first.id, 'B', reason: '两路都命中的必须排最前');
      expect(byId['B']!.score, 1 / 62 + 1 / 61);
      expect(byId['A']!.score, 1 / 61);
      expect(byId['A']!.keywordRank, 0);
      expect(byId['A']!.vectorRank, isNull);
      expect(byId['C']!.vectorRank, 1);
    });

    test('同通道内重复 id 只认最优名次（不重复计分）', () {
      final List<RrfEntry> fused = Retriever.fuse(
        keywordOrder: <String>['A', 'A', 'B'],
        vectorOrder: const <String>[],
      );
      final RrfEntry a = fused.firstWhere((RrfEntry e) => e.id == 'A');
      expect(a.keywordRank, 0);
      expect(a.score, 1 / 61);
      expect(fused, hasLength(2));
    });

    test('空输入 ⇒ 空结果；同分时按 id 稳定排序（结果可复现）', () {
      expect(
        Retriever.fuse(
          keywordOrder: const <String>[],
          vectorOrder: const <String>[],
        ),
        isEmpty,
      );
      final List<RrfEntry> fused = Retriever.fuse(
        keywordOrder: <String>['B', 'A'],
        vectorOrder: const <String>[],
      );
      expect(
        <String>[for (final RrfEntry e in fused) e.id],
        <String>['B', 'A'],
      );
    });
  });

  group('检索（真库 + 真 FTS/向量）', () {
    /// 建三个块并索引：b1/b2 含"番茄"，b3 只与查询语义相近。
    Future<Retriever> build(Database db, {EmbeddingClient? client}) async {
      insertNote(db, 'n1');
      insertBlock(db, 'b1', 'n1', '番茄工作法');
      insertBlock(db, 'b2', 'n1', '番茄钟的用法');
      insertBlock(db, 'b3', 'n1', '完全无关的一段');
      final LocalEmbeddingBackend? backend = client == null
          ? null
          : LocalEmbeddingBackend(db: db, client: client);
      await IndexJob(
        db: db,
        backend: backend,
      ).run(onProgress: (IndexProgress _) {});
      return Retriever(db: db, backend: backend);
    }

    test('关键词路：中文查询走 bigram 两侧一致 ⇒ 命中', () async {
      final Database db = openMigrated();
      final Retriever retriever = await build(db);

      final RetrievalResult result = await retriever.search('番茄');
      expect(result.hits, isNotEmpty);
      expect(<String>[
        for (final RetrievalHit h in result.hits) h.blockId,
      ], containsAll(<String>['b1', 'b2']));
      expect(result.hits.first.noteId, 'n1');
      expect(result.hits.first.snippet, contains('番茄'));
      expect(result.vectorUsed, isFalse);
      expect(result.vectorFallbackReason, isNotNull, reason: '没配模型要说明降级');
    });

    test('融合：两路都命中的块排最前；只被语义命中的块也进榜', () async {
      final Database db = openMigrated();
      final _FakeClient client = _FakeClient(
        vectors: <String, List<double>>{
          '番茄工作法': <double>[1, 0],
          '番茄钟的用法': <double>[0.95, 0.05],
          '完全无关的一段': <double>[0, 1],
          '番茄': <double>[1, 0], // 查询向量：与 b1 同向
        },
      );
      final Retriever retriever = await build(db, client: client);

      final RetrievalResult result = await retriever.search('番茄');
      expect(result.vectorUsed, isTrue);
      expect(result.vectorFallbackReason, isNull);

      final RetrievalHit top = result.hits.first;
      expect(top.blockId, 'b1', reason: '关键词与语义都命中的块必须排最前');
      expect(top.fromKeyword, isTrue);
      expect(top.fromVector, isTrue);

      // b3 关键词路搜不到（不含"番茄"），但语义路把它排在第二位 ⇒ 应出现在结果里。
      final RetrievalHit? b3 = result.hits
          .where((RetrievalHit h) => h.blockId == 'b3')
          .firstOrNull;
      expect(b3, isNotNull, reason: '纯语义命中也要进榜（否则混合检索没意义）');
      expect(b3!.fromKeyword, isFalse);
      expect(b3.fromVector, isTrue);
    });

    test('多 chunk 的块只占一条（融合前先归并到 block）', () async {
      final Database db = openMigrated();
      insertNote(db, 'n1');
      final String long = <String>['番茄' * 150, '番茄' * 150].join('\n\n');
      insertBlock(db, 'b1', 'n1', long);
      await IndexJob(db: db).run(onProgress: (IndexProgress _) {});

      // 前提：这个块确实被切成了多段（否则本用例没有意义）。
      expect(
        db.select('SELECT COUNT(*) AS c FROM chunks_fts').single['c'],
        greaterThan(1),
      );

      final RetrievalResult result = await Retriever(db: db).search('番茄');
      expect(result.hits, hasLength(1));
      expect(result.hits.single.blockId, 'b1');
    });

    test('降级：语义路抛异常（模型不可达）⇒ 关键词路结果照常返回并说明原因', () async {
      final Database db = openMigrated();
      // 索引时用健康客户端（保证向量在库），检索时换成会失败的客户端。
      await build(
        db,
        client: _FakeClient(
          vectors: <String, List<double>>{
            '番茄工作法': <double>[1, 0],
            '番茄钟的用法': <double>[1, 0],
            '完全无关的一段': <double>[0, 1],
          },
        ),
      );
      final Retriever failing = Retriever(
        db: db,
        backend: LocalEmbeddingBackend(db: db, client: _FakeClient(fail: true)),
      );

      final RetrievalResult result = await failing.search('番茄');
      expect(result.vectorUsed, isFalse);
      expect(result.vectorFallbackReason, contains('语义检索不可用'));
      expect(result.hits, isNotEmpty, reason: '语义路挂了不能让检索整体失败（6.4：降级而非不可用）');
    });

    test('空查询 ⇒ 空结果（不发任何请求）', () async {
      final Database db = openMigrated();
      final Retriever retriever = await build(db);
      final RetrievalResult result = await retriever.search('   ');
      expect(result.hits, isEmpty);
    });
  });
}
