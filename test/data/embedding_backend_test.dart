import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/ai/embedding_client.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/embedding_backend.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_vector/sqlite_vector.dart';

/// `LocalEmbeddingBackend` 的回归：**同库同事务**写入、幂等 upsert、
/// `vector_full_scan` 查询链（扩展真加载，嵌入用假客户端——HTTP 无可断言逻辑）。
///
/// 设计依据：`docs/data_layer.md` 6.6①（嵌入身份）、6.7（R2 行）。
/// 假嵌入客户端：向量由 [vectorsFor] 决定（默认全 0.5），记录调用入参。
class _FakeClient implements EmbeddingClient {
  _FakeClient();

  final List<List<String>> calls = <List<String>>[];
  Float32List Function(String text)? vectorsFor;

  @override
  String get provider => 'fake';

  @override
  String get model => 'emb';

  @override
  Future<List<Float32List>> embed(List<String> inputs) async {
    calls.add(inputs);
    if (vectorsFor != null) {
      return <Float32List>[for (final String t in inputs) vectorsFor!(t)];
    }
    return <Float32List>[
      for (final String _ in inputs) Float32List.fromList(<double>[0.5, 0.5]),
    ];
  }
}

void main() {
  // 扩展注册是进程级、只对之后打开的连接生效 ⇒ 先注册再 open。
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

  void insertBlock(Database db, String id, String noteId) {
    db.execute(
      'INSERT INTO blocks (id, note_id, type, props_json, ord, created_at, '
      "updated_at, fingerprint) VALUES (?, ?, 'paragraph', '{}', 0, 1, 1, 'fp1:$id')",
      <Object?>[id, noteId],
    );
  }

  test('index：向量与状态同事务落库，身份串 provider:model:dim 进两处', () async {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1');
    insertBlock(db, 'b2', 'n1');
    final _FakeClient client = _FakeClient();
    final LocalEmbeddingBackend backend = LocalEmbeddingBackend(
      db: db,
      client: client,
    );

    await backend.index(const <EmbeddingInput>[
      (blockId: 'b1', chunkIndex: 0, text: '苹果', fingerprint: 'fp1:a'),
      (blockId: 'b2', chunkIndex: 0, text: '香蕉', fingerprint: 'fp1:b'),
    ], chunkerVersion: 'ck1');

    // 一次批量请求（R3 分批策略的地基）。
    expect(client.calls, hasLength(1));
    expect(client.calls.single, <String>['苹果', '香蕉']);

    // vec_chunks：float32 原始字节可还原。
    final Row blob = db
        .select("SELECT embedding FROM vec_chunks WHERE block_id = 'b1'")
        .single;
    final Float32List restored = Float32List.view(
      (blob['embedding'] as Uint8List).buffer,
    );
    expect(restored.toList(), <double>[0.5, 0.5]);

    // index_state：身份串 + 切块版本一起写（6.6① 的过期判据三要素）。
    final Row state = db
        .select(
          "SELECT model, chunker_version FROM index_state WHERE block_id = 'b1'",
        )
        .single;
    expect(state['model'], 'fake:emb:2');
    expect(state['chunker_version'], 'ck1');

    // rag_meta：当前身份（R3"待处理数"的判变基准）。
    expect(backend.storedIdentity, 'fake:emb:2');
  });

  test('index：同块重索引是覆盖不是堆积（幂等 upsert）', () async {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1');
    final LocalEmbeddingBackend backend = LocalEmbeddingBackend(
      db: db,
      client: _FakeClient(),
    );

    await backend.index(const <EmbeddingInput>[
      (blockId: 'b1', chunkIndex: 0, text: '旧文本', fingerprint: 'fp1:old'),
    ], chunkerVersion: 'ck1');
    await backend.index(const <EmbeddingInput>[
      (blockId: 'b1', chunkIndex: 0, text: '新文本', fingerprint: 'fp1:new'),
    ], chunkerVersion: 'ck1');

    expect(db.select('SELECT COUNT(*) AS c FROM vec_chunks').single['c'], 1);
    expect(
      db
          .select("SELECT fingerprint FROM index_state WHERE block_id = 'b1'")
          .single['fingerprint'],
      'fp1:new',
    );
  });

  test('delete：vec_chunks 与 index_state 同事务清掉', () async {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1');
    final LocalEmbeddingBackend backend = LocalEmbeddingBackend(
      db: db,
      client: _FakeClient(),
    );
    await backend.index(const <EmbeddingInput>[
      (blockId: 'b1', chunkIndex: 0, text: '文本', fingerprint: 'fp1:a'),
    ], chunkerVersion: 'ck1');

    await backend.delete(const <String>['b1']);

    expect(db.select('SELECT COUNT(*) AS c FROM vec_chunks').single['c'], 0);
    expect(db.select('SELECT COUNT(*) AS c FROM index_state').single['c'], 0);
  });

  test('query：文本 → 向量 → full_scan，命中按距离升序映射回 block_id', () async {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1');
    insertBlock(db, 'b2', 'n1');
    insertBlock(db, 'b3', 'n1');
    final _FakeClient client = _FakeClient();
    final LocalEmbeddingBackend backend = LocalEmbeddingBackend(
      db: db,
      client: client,
    );
    // 三块向量各不相同（查询向量与 b1 完全同向 ⇒ 距离 0、排最前）。
    client.vectorsFor = (String text) => switch (text) {
      '近的' => Float32List.fromList(<double>[1, 0]),
      '远的' => Float32List.fromList(<double>[0, 1]),
      _ => Float32List.fromList(<double>[0.7, 0.7]),
    };
    await backend.index(const <EmbeddingInput>[
      (blockId: 'b1', chunkIndex: 0, text: '近的', fingerprint: 'fp1:a'),
      (blockId: 'b2', chunkIndex: 0, text: '远的', fingerprint: 'fp1:b'),
      (blockId: 'b3', chunkIndex: 0, text: '更远', fingerprint: 'fp1:c'),
    ], chunkerVersion: 'ck1');

    final List<EmbeddingHit> hits = await backend.query('近的', k: 3);
    expect(hits.first.blockId, 'b1');
    expect(hits.first.distance, 0.0);
    expect(hits, hasLength(3));
    expect(hits.last.blockId, isNot('b1'));
  });

  test('query：空文本短路返回空（不发请求）', () async {
    final _FakeClient client = _FakeClient();
    final LocalEmbeddingBackend backend = LocalEmbeddingBackend(
      db: openMigrated(),
      client: client,
    );
    expect(await backend.query('  '), isEmpty);
    expect(client.calls, isEmpty);
  });

  test('query：从未索引过 ⇒ 空结果（扩展元数据缺席也不报错）', () async {
    final Database db = openMigrated();
    final LocalEmbeddingBackend backend = LocalEmbeddingBackend(
      db: db,
      client: _FakeClient(),
    );
    expect(await backend.query('问题'), isEmpty);
  });

  test('query：维度与库内不一致（换模型未重索引）⇒ 大声失败', () async {
    final Database db = openMigrated();
    insertNote(db, 'n1');
    insertBlock(db, 'b1', 'n1');
    final _FakeClient client = _FakeClient();
    final LocalEmbeddingBackend backend = LocalEmbeddingBackend(
      db: db,
      client: client,
    );
    await backend.index(const <EmbeddingInput>[
      (blockId: 'b1', chunkIndex: 0, text: '文本', fingerprint: 'fp1:a'),
    ], chunkerVersion: 'ck1');

    // 同一后端忽然吐出不同维度的向量 = 换了模型但没重建索引。
    client.vectorsFor = (String text) =>
        Float32List.fromList(<double>[1, 2, 3]);
    expect(
      () => backend.query('问题'),
      throwsA(isA<StateError>()),
      reason: '维度不齐的查询结果是垃圾，必须让上层走降级而不是静默给错答案',
    );
  });

  test('storedIdentity：从未索引过 ⇒ null', () {
    final LocalEmbeddingBackend backend = LocalEmbeddingBackend(
      db: openMigrated(),
      client: _FakeClient(),
    );
    expect(backend.storedIdentity, isNull);
  });
}
