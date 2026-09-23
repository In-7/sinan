import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../ai/embedding_client.dart';
import 'chunker.dart';
import 'embedding_backend.dart';

/// 一次索引运行的进度快照（6.5 的"有进度"）：`done / total` + 已失败块数。
typedef IndexProgress = ({int done, int total, int failed});

/// 一次运行的收尾结果。
typedef IndexResult = ({
  int total,
  int done,
  int failed,
  bool cancelled,
  String? abortReason,
});

/// 取消令牌（6.5 的"可取消"）：UI 置位后，任务在**批次边界**停下。
///
/// 只做一件事、且只被一个线程读——刻意不做成 `Future`/`Stream` 那套：任务本身
/// 是同步 SQL + 异步 HTTP 的直线流程，一个布尔位就够，机械复杂度最低（6.5 的
/// 立论：AI 是唯一有外部依赖的部分，越显式越好排查）。
class IndexCancelToken {
  bool _cancelled = false;
  void cancel() => _cancelled = true;
  bool get isCancelled => _cancelled;
}

/// 「建立 / 更新索引」任务（`docs/data_layer.md` 6.5 / 6.7 R3）。
///
/// ## 两条通道，一次任务
/// 每次运行同时写**关键词路**（`chunks_fts`，本地、不需要模型）与**语义路**
/// （`vec_chunks`，需要嵌入模型）。于是：
/// - 没配 Ollama（[backend] 为 null）⇒ 只建关键词路，按钮照常可用、搜索照常有
///   结果——这就是 6.4「降级而非不可用」在**索引侧**的形态；
/// - 语义路失败 ⇒ 关键词路已生效，下次点按钮只补语义（判据留在 `index_state`）。
///
/// ## 幂等与增量
/// 待处理判据四条（6.5）：**无记录 ‖ 指纹变了 ‖ 嵌入身份变了 ‖ 切块版本变了**。
/// 每条都以 `index_state` 为凭据 ⇒ 重复点按钮的开销 ≈ 一次 SELECT。写入按块
/// **先清后写**，所以"块被删短"这类收缩场景也不会留下旧行。
class IndexJob {
  IndexJob({required this.db, this.backend});

  final Database db;

  /// 嵌入后端。null ⇒ **只建关键词路**（见类文档）。
  final EmbeddingBackend? backend;

  /// 每批块数（6.5：一次 32~64 条，既省请求开销又能出进度）。
  static const int batchSize = 32;

  /// `props_json` 里文本的路径。
  ///
  /// ⚠️ 与 `NoteStore._textPath` / `CanvasStore` 同一口径（数据层不互相 import
  /// 私有常量，各自复刻一份——同 `CanvasStore._cardType` 的做法）。
  static const String _textPath = r'$.text';

  /// 待处理块数（6.5：**按钮上要显示待处理数量**，否则用户不知道该不该点）。
  ///
  /// 空文本的块（分隔线 / 图片）不参与索引，故不进计数。
  int pendingCount() {
    final String? identity = backend?.storedIdentity;
    final Row row = db.select('SELECT COUNT(*) AS c $_pendingFrom', <Object?>[
      kChunkerVersion,
      identity,
      identity,
    ]).single;
    return row['c'] as int;
  }

  /// 跑一次。批次边界检查取消；每批结束回调 [onProgress]。
  ///
  /// 失败策略（6.5 的"失败可重试，不要因为一块错了就整体回滚"）：
  /// - **模型服务不可达** ⇒ 中止整轮（后面每批都会失败，继续只是浪费）；
  ///   关键词路已写入的部分**保持有效**；
  /// - **单批答得不对**（脏响应） ⇒ 只跳过该批，继续跑后面的。
  Future<IndexResult> run({
    required void Function(IndexProgress progress) onProgress,
    IndexCancelToken? cancelToken,
  }) async {
    final String? identity = backend?.storedIdentity;
    final List<_WorkBlock> work = <_WorkBlock>[
      for (final Row r in db.select(
        'SELECT b.id AS id, b.note_id AS note_id, b.props_json AS props_json, '
        '       b.fingerprint AS fingerprint $_pendingFrom',
        <Object?>[kChunkerVersion, identity, identity],
      ))
        (
          id: r['id'] as String,
          noteId: r['note_id'] as String,
          text: _textOf(r['props_json'] as String?),
          fingerprint: r['fingerprint'] as String,
        ),
    ];

    final int total = work.length;
    int done = 0;
    int failed = 0;
    String? abortReason;

    for (int start = 0; start < work.length; start += batchSize) {
      if (cancelToken?.isCancelled ?? false) {
        return (
          total: total,
          done: done,
          failed: failed,
          cancelled: true,
          abortReason: null,
        );
      }
      final List<_WorkBlock> batch = work.sublist(
        start,
        (start + batchSize).clamp(0, work.length),
      );

      // ① 关键词路：本地、不需要模型，先写（语义路失败也不影响它生效）。
      _writeKeyword(batch);

      // ② 语义路：需要模型。失败按类分流（见 run 的文档）。
      if (backend != null) {
        final List<EmbeddingInput> chunks = <EmbeddingInput>[
          for (final _WorkBlock b in batch)
            for (final Chunk c in chunkBlock(b.text))
              (
                blockId: b.id,
                chunkIndex: c.index,
                text: c.text,
                fingerprint: b.fingerprint,
              ),
        ];
        try {
          await backend!.index(chunks, chunkerVersion: kChunkerVersion);
        } on LlmUnavailableException catch (e) {
          abortReason = e.message;
          done += batch.length;
          onProgress((done: done, total: total, failed: failed));
          return (
            total: total,
            done: done,
            failed: failed,
            cancelled: false,
            abortReason: abortReason,
          );
        } on LlmResponseException {
          // 脏响应：只丢这一批，后面的继续（下一轮会重新捡起这些块，因为
          // `index_state` 没写成）。**不 catch Object**：程序错误必须炸出来，
          // 否则会被当成"这批模型答得不好"而静默跳过。
          failed += batch.length;
        }
      }

      done += batch.length;
      onProgress((done: done, total: total, failed: failed));
    }

    return (
      total: total,
      done: done,
      failed: failed,
      cancelled: false,
      abortReason: abortReason,
    );
  }

  /// 待处理判据（四条，见类文档）。占位参数顺序：切块版本、身份、身份。
  ///
  /// `? IS NULL` 那一支负责"从未索引过"（`rag_meta` 里没有身份）⇒ 所有有记录
  /// 的块也一律待处理——否则换过模型却没写下身份的库会被误判为已索引。
  static const String _pendingCondition =
      's.block_id IS NULL '
      'OR s.fingerprint <> b.fingerprint '
      'OR s.chunker_version <> ? '
      'OR ? IS NULL OR s.model <> ?';

  /// 待处理的 FROM/WHERE 片段（计数与取数共用，避免两处判据漂移）。
  static const String _pendingFrom =
      'FROM blocks b LEFT JOIN index_state s ON s.block_id = b.id '
      'WHERE b.note_id IN (SELECT id FROM notes WHERE deleted_at IS NULL) '
      "  AND COALESCE(json_extract(b.props_json, '$_textPath'), '') <> '' "
      '  AND ($_pendingCondition)';

  /// 写关键词路：**先清后写**（FTS5 虚拟表不支持外键，删块时没人替它清，见 6.3；
  /// 这里顺带承担"块文本变短/变空"的收缩）。
  void _writeKeyword(List<_WorkBlock> batch) {
    db.execute('BEGIN');
    try {
      for (final _WorkBlock b in batch) {
        db.execute('DELETE FROM chunks_fts WHERE block_id = ?', <Object?>[
          b.id,
        ]);
        for (final Chunk c in chunkBlock(b.text)) {
          db.execute(
            'INSERT INTO chunks_fts (search_text, block_id, note_id, chunk_text) '
            'VALUES (?, ?, ?, ?)',
            <Object?>[c.searchText, b.id, b.noteId, c.text],
          );
        }
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// `props_json` → 文本（与 `NoteStore.textOfProps` 同口径：容错解析，坏 JSON
  /// 视为空文本而不是崩掉整轮索引）。
  static String _textOf(String? propsJson) {
    if (propsJson == null || propsJson.isEmpty) return '';
    final Object? decoded = _tryDecode(propsJson);
    if (decoded is! Map) return '';
    final Object? text = decoded['text'];
    return text is String ? text : '';
  }

  static Object? _tryDecode(String json) {
    try {
      return const JsonDecoder().convert(json);
    } on FormatException {
      return null;
    }
  }
}

typedef _WorkBlock = ({
  String id,
  String noteId,
  String text,
  String fingerprint,
});
