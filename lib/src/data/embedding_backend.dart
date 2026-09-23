import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../ai/embedding_client.dart';

/// 语义近邻的一条命中。`distance` 越小越近（cosine 距离，0 = 同向）。
typedef EmbeddingHit = ({String blockId, double distance});

/// 一条待索引的 **chunk**：指纹与切块版本由调用方给（R3 的切块器统一负责）。
///
/// ⚠️ 粒度是 chunk 不是 block（v11）：同一个 [blockId] 的多个 chunk 必须**同批**
/// 传入——[EmbeddingBackend.index] 会先清该块的旧 chunk 行再写（块变短时旧行
/// 不能残留）。
typedef EmbeddingInput = ({
  String blockId,
  int chunkIndex,
  String text,
  String fingerprint,
});

/// 嵌入后端抽象（`docs/data_layer.md` 6.6③）：**index / delete / query** 三个操作
/// 遮住"向量存哪、嵌入从哪来"。本地实现（[LocalEmbeddingBackend]）= 同库
/// sqlite-vector + Ollama HTTP；将来云端实现 = 远端向量库——`pending_delete`
/// 墓碑表就是为那个实现备的，本接口不动。
abstract interface class EmbeddingBackend {
  /// 索引一批 **chunk**：文本 → 向量 → 落库。
  ///
  /// **幂等**：按 block 先清旧 chunk 行再写（块变短时旧向量必须消失，否则会
  /// "检索到一段已经不存在的文字"）；`vec_chunks` 与 `index_state` 在**同一个
  /// 事务**里写（同库路线的核心收益，见 6.7 复核结论）。向量维度取自首次响应，
  /// 身份串 `provider:model:dim` 同时写进 `index_state.model` 与
  /// `rag_meta['embedding_identity']`（后者是 6.5"待处理数"的判变基准）。
  /// HTTP 失败时抛 [LlmUnavailableException] / [LlmResponseException]，
  /// **已写入的批次保持有效**（分批由 R3 负责，一批一事务）。
  Future<void> index(
    List<EmbeddingInput> chunks, {
    required String chunkerVersion,
  });

  /// 删除块的向量行（`vec_chunks` + `index_state` 同事务）。
  ///
  /// 本地路径里删笔记靠级联（v10），本方法服务**块级**场景（R3 重索引前清旧行）
  /// 与云端实现的删除传播。
  Future<void> delete(Iterable<String> blockIds);

  /// 语义近邻：文本 → 向量 → `vector_full_scan` 全量扫描（6.2 容量预算口径）。
  ///
  /// ⚠️ 只查**当前身份**的向量是调用方的责任（身份变更 ⇒ R3 全量重索引）；
  /// 本方法不做身份闸——R4 的查询侧接 [AppDatabase.vectorExtensionAvailable]
  /// 与身份检查后决定降级。
  Future<List<EmbeddingHit>> query(String text, {int k});

  /// 最近一次成功索引写入 `rag_meta` 的嵌入身份串；从未索引过 ⇒ null。
  String? get storedIdentity;
}

/// [EmbeddingBackend] 的本地实现：同库 `vec_chunks` + Ollama `/api/embed`。
///
/// ## 字节口径
/// 向量按 **float32 little-endian** 原始字节进 BLOB（sqlite-vector 的约定）。
/// Dart `Float32List` 是宿主字节序，桌面三平台（x64/ARM64）均为 LE ⇒ 直接取
/// buffer 字节即可；将来若上大端平台（不存在），这里要显式转换。
class LocalEmbeddingBackend implements EmbeddingBackend {
  LocalEmbeddingBackend({required this.db, required this.client});

  final Database db;
  final EmbeddingClient client;

  /// 同步事务外壳（package:sqlite3 的 `Database` 没有 transaction 方法；这里
  /// 的批量写全是同步 SQL，HTTP 已在事务外完成，无需 async 事务）。
  void _inTransaction(void Function() body) {
    db.execute('BEGIN');
    try {
      body();
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  String? get storedIdentity {
    final List<Row> rows = db.select(
      "SELECT value FROM rag_meta WHERE key = 'embedding_identity'",
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  @override
  Future<void> index(
    List<EmbeddingInput> chunks, {
    required String chunkerVersion,
  }) async {
    if (chunks.isEmpty) return;
    final List<Float32List> vectors = await client.embed(<String>[
      for (final EmbeddingInput c in chunks) c.text,
    ]);
    final String identity =
        '${client.provider}:${client.model}:${vectors.first.length}';
    final int now = DateTime.now().millisecondsSinceEpoch;
    _inTransaction(() {
      // vector_init 是 vector_full_scan 的**硬前提**（维度/度量写进扩展的元数据
      // 表，扫描靠它解析 BLOB）。已核实：<https://deepwiki.com/sqliteai/sqlite-vector>
      // 维度变了（= 换嵌入模型，身份必变）⇒ 重算 init；旧行在那次全量重算中
      // 会被先清空（R3），这里不做清理。
      _ensureVectorInit(vectors.first.length);
      // 逐块先清后写：块变短时旧的低序号之后的行必须一起消失（否则留下"用旧
      // 文本算的向量"）。同块的 chunk 由调用方保证同批传入。
      final Set<String> cleared = <String>{};
      for (int i = 0; i < chunks.length; i++) {
        final EmbeddingInput c = chunks[i];
        if (cleared.add(c.blockId)) {
          db.execute('DELETE FROM vec_chunks WHERE block_id = ?', <Object?>[
            c.blockId,
          ]);
        }
        db.execute(
          'INSERT INTO vec_chunks (block_id, chunk_index, embedding) '
          'VALUES (?, ?, ?)',
          <Object?>[c.blockId, c.chunkIndex, _f32Blob(vectors[i])],
        );
        // index_state 是**块粒度**（新鲜度判据）：同块多 chunk 重复写同值。
        db.execute(
          'INSERT OR REPLACE INTO index_state '
          '(block_id, fingerprint, model, chunker_version, updated_at) '
          'VALUES (?, ?, ?, ?, ?)',
          <Object?>[c.blockId, c.fingerprint, identity, chunkerVersion, now],
        );
      }
      db.execute(
        'INSERT OR REPLACE INTO rag_meta (key, value) '
        "VALUES ('embedding_identity', ?)",
        <Object?>[identity],
      );
    });
  }

  @override
  Future<void> delete(Iterable<String> blockIds) async {
    final List<String> ids = blockIds.toList(growable: false);
    if (ids.isEmpty) return;
    _inTransaction(() {
      for (final String id in ids) {
        db.execute('DELETE FROM vec_chunks WHERE block_id = ?', <Object?>[id]);
        db.execute('DELETE FROM index_state WHERE block_id = ?', <Object?>[id]);
      }
    });
  }

  @override
  Future<List<EmbeddingHit>> query(String text, {int k = 8}) async {
    if (text.trim().isEmpty) return const <EmbeddingHit>[];
    final Float32List vector = (await client.embed(<String>[text])).single;
    // 身份闸：从未索引过 ⇒ 无可查；维度与库内不一致（= 换了模型没重索引）⇒
    // 查出来的是垃圾，宁可大声失败让 R4 走降级，也不能静默给错答案。
    final int? storedDim = _storedDim();
    if (storedDim == null) return const <EmbeddingHit>[];
    if (storedDim != vector.length) {
      throw StateError(
        '嵌入维度不一致（库内 $storedDim，当前 ${vector.length}）：'
        '嵌入模型已更换，请先重建索引',
      );
    }
    final List<Row> rows = db.select(
      'SELECT c.block_id AS block_id, f.distance AS distance '
      "FROM vector_full_scan('vec_chunks', 'embedding', ?, ?) AS f "
      'JOIN vec_chunks c ON c.rowid = f.rowid '
      'ORDER BY f.distance',
      <Object?>[_f32Blob(vector), k],
    );
    return <EmbeddingHit>[
      for (final Row r in rows)
        (
          blockId: r['block_id'] as String,
          distance: (r['distance'] as num).toDouble(),
        ),
    ];
  }

  /// 库内向量的维度（`rag_meta` 记账；从未 init 过 ⇒ null）。
  int? _storedDim() {
    final List<Row> rows = db.select(
      "SELECT value FROM rag_meta WHERE key = 'vec_dim'",
    );
    return rows.isEmpty ? null : int.tryParse(rows.single['value'] as String);
  }

  /// 确保 `vec_chunks.embedding` 已按 [dim] 注册到扩展元数据（幂等）。
  void _ensureVectorInit(int dim) {
    if (_storedDim() == dim) return;
    db.execute(
      "SELECT vector_init('vec_chunks', 'embedding', "
      "'dimension=$dim,distance_metric=cosine')",
    );
    db.execute(
      'INSERT OR REPLACE INTO rag_meta (key, value) VALUES (?, ?)',
      <Object?>['vec_dim', '$dim'],
    );
  }
}

/// float32 向量 → little-endian 原始字节（见类文档的字节口径）。
Uint8List _f32Blob(Float32List v) =>
    v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes);
