import 'package:sqlite3/sqlite3.dart';

import 'chunker.dart';
import 'embedding_backend.dart';

/// 一条检索命中。**引用单元是 block**（角标要跳到块、答案要引到块）。
typedef RetrievalHit = ({
  String blockId,
  String noteId,
  String snippet,
  double score,
  bool fromKeyword,
  bool fromVector,
});

/// 一次检索的结果 + 降级信息。
///
/// [vectorFallbackReason] 非空表示**只有关键词路在工作**（语义路不可用/未索引），
/// UI 该把它当提示而不是当错误（6.4：降级而非不可用）。
typedef RetrievalResult = ({
  List<RetrievalHit> hits,
  bool vectorUsed,
  String? vectorFallbackReason,
});

/// 融合排名里的一项（[score] 是 RRF 分数）。
typedef RrfEntry = ({
  String id,
  double score,
  int? keywordRank,
  int? vectorRank,
});

/// 混合检索：关键词路（FTS5 + bigram）＋ 语义路（sqlite-vector）→ **RRF 融合**。
///
/// ## 融合粒度：先在**各自通道内归并到 block**，再融合
/// 两条路的原始命中都是 chunk 粒度（`chunks_fts` / `vec_chunks`），但引用单元是
/// block。所以每路先按 block **去重保最优名次**，再在 block 上做 RRF——否则同一
/// 个块会因为"切了 5 段"而在分数上碾压别人（那是切块策略的副作用，不是相关性）。
///
/// ## RRF（6.4）：`Σ 1/(k + rank + 1)`，k = 60
/// 只吃名次不吃原始分数——这是它最值钱的地方：bm25 与 cosine 距离**量纲不同、
/// 无法直接相加**，而名次是可比的。两路都命中的块自然排到最前。
///
/// ## 降级（6.4）
/// 语义路缺席（没配嵌入模型 / 未索引 / 维度不符 / 扩展没加载）⇒ **只用关键词路**，
/// 并在 [RetrievalResult.vectorFallbackReason] 里说明原因。任何一种语义路失败都
/// **不能**让检索整体失败——本地优先应用里，"搜得到但没那么聪明"远好过"搜不了"。
class Retriever {
  Retriever({required this.db, this.backend});

  final Database db;

  /// 语义路后端；null ⇒ 纯关键词检索（6.4 的降级形态之一）。
  final EmbeddingBackend? backend;

  /// RRF 的 k（6.4 定的 60：够大 ⇒ 名次差不多的条目分数接近，避免单路独大）。
  static const int rrfK = 60;

  /// `props_json` 里文本的路径。
  ///
  /// ⚠️ 必须用常量插值：把 `$.text` 直接写进 SQL 字符串里，Dart 会把 `$` 当插值
  /// 开头而**编译报错**（同 `NoteStore._textPath` 的说明）。
  static const String _textPath = r'$.text';

  /// 取候选时按 [limit] 的倍数放宽，给"归并到 block"留出余地
  /// （一个块可能占掉好几个 chunk 位次）。
  static const int _candidateFactor = 4;

  /// 检索。[limit] 是**返回的 block 条数**上限。
  Future<RetrievalResult> search(String query, {int limit = 8}) async {
    final String q = query.trim();
    if (q.isEmpty) {
      return (
        hits: const <RetrievalHit>[],
        vectorUsed: false,
        vectorFallbackReason: null,
      );
    }

    final List<_RankedBlock> keyword = _keywordRanked(
      q,
      limit * _candidateFactor,
    );

    List<String> vectorOrder = const <String>[];
    String? fallbackReason;
    if (backend == null) {
      fallbackReason = '未配置嵌入模型：本次只用关键词检索';
    } else {
      try {
        vectorOrder = _vectorRanked(
          await backend!.query(q, k: limit * _candidateFactor),
        );
      } on Object catch (e) {
        // 语义路的任何失败都不该让检索失败（6.4）。这里就要 catch Object：
        // HTTP 不可达、维度不符的 StateError、扩展缺席的 SqliteException 都是
        // "这条路今天不能用"，而不是程序 bug。
        fallbackReason = '语义检索不可用（$e）：本次只用关键词检索';
        vectorOrder = const <String>[];
      }
    }

    // 关键词路为空时不必再融合：向量路的名次若存在，仍单独成榜。
    final List<RrfEntry> fused = fuse(
      keywordOrder: <String>[for (final _RankedBlock b in keyword) b.blockId],
      vectorOrder: vectorOrder,
    );

    final Map<String, _RankedBlock> byId = <String, _RankedBlock>{
      for (final _RankedBlock b in keyword) b.blockId: b,
    };
    final List<RetrievalHit> hits = <RetrievalHit>[];
    for (final RrfEntry e in fused) {
      if (hits.length >= limit) break;
      final _RankedBlock? known = byId[e.id];
      final _RankedBlock? detail = known ?? _detailsOf(e.id);
      if (detail == null) continue;
      hits.add((
        blockId: e.id,
        noteId: detail.noteId,
        snippet: detail.snippet,
        score: e.score,
        fromKeyword: e.keywordRank != null,
        fromVector: e.vectorRank != null,
      ));
    }

    return (
      hits: hits,
      vectorUsed: vectorOrder.isNotEmpty,
      vectorFallbackReason: fallbackReason,
    );
  }

  /// RRF 融合（**纯函数**，故可单测）：名次 → 分数 → 稳定排序。
  ///
  /// 排序键依次是：分数降序 → 两路中较好的名次 → id（保证同分时结果**可复现**，
  /// 否则测试与 UI 都会随机抖动）。
  static List<RrfEntry> fuse({
    required List<String> keywordOrder,
    required List<String> vectorOrder,
    int k = rrfK,
  }) {
    final Map<String, double> scores = <String, double>{};
    final Map<String, int> keywordRank = <String, int>{};
    final Map<String, int> vectorRank = <String, int>{};

    void accumulate(List<String> order, Map<String, int> ranks) {
      for (int i = 0; i < order.length; i++) {
        final String id = order[i];
        if (ranks.containsKey(id)) continue; // 同通道内只认最优名次
        ranks[id] = i;
        scores[id] = (scores[id] ?? 0) + 1 / (k + i + 1);
      }
    }

    accumulate(keywordOrder, keywordRank);
    accumulate(vectorOrder, vectorRank);

    final List<RrfEntry> out = <RrfEntry>[
      for (final MapEntry<String, double> e in scores.entries)
        (
          id: e.key,
          score: e.value,
          keywordRank: keywordRank[e.key],
          vectorRank: vectorRank[e.key],
        ),
    ];
    out.sort((RrfEntry a, RrfEntry b) {
      final int byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      int bestOf(RrfEntry e) => <int>[
        e.keywordRank ?? 1 << 30,
        e.vectorRank ?? 1 << 30,
      ].reduce((int x, int y) => x < y ? x : y);
      final int byRank = bestOf(a).compareTo(bestOf(b));
      return byRank != 0 ? byRank : a.id.compareTo(b.id);
    });
    return out;
  }

  /// 关键词路：bigram 查询串 → FTS5 MATCH → 按 bm25 名次**归并到 block**。
  ///
  /// ⚠️ 查询侧与写入侧必须用同一个 [bigram]（6.1）——不一致就是这个功能最隐蔽的
  /// 失效方式：不报错，只是永远搜不到。
  List<_RankedBlock> _keywordRanked(String query, int candidateLimit) {
    final String tokens = bigram(query);
    if (tokens.isEmpty) return const <_RankedBlock>[];
    final String match = <String>[
      for (final String t in tokens.split(' ')) '"${t.replaceAll('"', '""')}"',
    ].join(' OR ');

    final ResultSet rows = db.select(
      'SELECT block_id, note_id, chunk_text, bm25(chunks_fts) AS rank '
      'FROM chunks_fts WHERE chunks_fts MATCH ? '
      'ORDER BY rank LIMIT ?',
      <Object?>[match, candidateLimit],
    );
    final Map<String, _RankedBlock> seen = <String, _RankedBlock>{};
    for (final Row r in rows) {
      final String blockId = r['block_id'] as String;
      seen.putIfAbsent(
        blockId,
        () => (
          blockId: blockId,
          noteId: r['note_id'] as String,
          snippet: r['chunk_text'] as String,
        ),
      );
    }
    return seen.values.toList(growable: false);
  }

  /// 语义路：向量近邻 → **归并到 block**（同块多 chunk 只留最近的那个名次）。
  List<String> _vectorRanked(List<EmbeddingHit> hits) {
    final List<String> out = <String>[];
    final Set<String> seen = <String>{};
    for (final EmbeddingHit h in hits) {
      if (seen.add(h.blockId)) out.add(h.blockId);
    }
    return out;
  }

  /// 补齐向量路独有的块（关键词路没命中它，就没有摘要可用）。
  ///
  /// 优先取 `chunks_fts` 的 chunk_text（与关键词路同一份摘要口径）；该块没有
  /// FTS 行时（理论上不该发生，两条通道同一次任务写）退回块文本本身。
  _RankedBlock? _detailsOf(String blockId) {
    final ResultSet fts = db.select(
      'SELECT note_id, chunk_text FROM chunks_fts WHERE block_id = ? LIMIT 1',
      <Object?>[blockId],
    );
    if (fts.isNotEmpty) {
      return (
        blockId: blockId,
        noteId: fts.single['note_id'] as String,
        snippet: fts.single['chunk_text'] as String,
      );
    }
    final ResultSet block = db.select(
      'SELECT note_id, '
      "COALESCE(json_extract(props_json, '$_textPath'), '') AS text "
      'FROM blocks WHERE id = ?',
      <Object?>[blockId],
    );
    if (block.isEmpty) return null;
    return (
      blockId: blockId,
      noteId: block.single['note_id'] as String,
      snippet: block.single['text'] as String,
    );
  }
}

typedef _RankedBlock = ({String blockId, String noteId, String snippet});
