import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/note.dart';
import 'providers.dart';

/// 一条全局搜索命中（已归并到**笔记**粒度）。
///
/// 检索命中单元是 block（[RetrievalHit]），但搜索结果列表以笔记为单位——
/// 一篇笔记多个块命中只保留最优一条，否则"切了 5 段"会刷屏（同一篇
/// 笔记占掉整屏结果，是切块策略的副作用，不是相关性）。
typedef SearchHit = ({
  Note note,

  /// 标题里命中了查询词（内容是否命中看 [snippet] 是否非空）。
  bool titleMatch,

  /// 内容命中的摘要；null = 仅标题命中。
  String? snippet,

  /// RRF 融合分（内容命中才有）；null = 仅标题命中。
  double? score,
});

/// 全局搜索状态（[searchNotifierProvider]）。
///
/// **状态放 provider 而不是 widget 局部**：从搜索分区点开一篇笔记再回来，
/// 查询词与结果都还在——这是"分区切换，不是页面跳转"承诺的一部分。
class SearchState {
  const SearchState({
    this.query = '',
    this.hits = const <SearchHit>[],
    this.searching = false,
    this.vectorFallbackReason,
  });

  final String query;
  final List<SearchHit> hits;

  /// 去抖窗口内 / 检索进行中。
  final bool searching;

  /// 语义路降级原因（6.4：**提示而非错误**）——没配嵌入模型 / 扩展缺席时，
  /// 关键词路照常工作，UI 只需要一句话说明"本次只有关键词检索"。
  final String? vectorFallbackReason;
}

/// 输入去抖窗口。FTS5 查询本身 <10ms，去抖主要防每个键一次 rebuild +
/// 语义路（配了 Ollama 时）每个键一次 HTTP。
const Duration kSearchDebounce = Duration(milliseconds: 250);

/// 内容路取回的 block 命中数上限（给"归并到笔记"留余地，同 Retriever 的
/// `_candidateFactor` 思路——一篇笔记的多个块可能占掉好几个名次）。
const int _contentLimit = 30;

/// 全局搜索（标题 + 内容）。
///
/// ## 两条路，一次合并
/// - **标题路**：内存里做——[notesProvider] 本来就装着全部笔记的标题，
///   `contains` 即可，零 SQL、零索引依赖（新建未索引的笔记标题也能搜到）；
/// - **内容路**：复用 [Retriever]（FTS5 关键词路 + 可选语义路 → RRF），
///   命中后再按笔记归并、按 RRF 分取最优摘要。
///
/// ## 竞态
/// 异步检索返回时用户可能已经改了查询词。用单调递增序号 [_seq] 守门：
/// 只有**最后一次** [submit] 的结果允许落地，过期结果静默丢弃。
class SearchNotifier extends Notifier<SearchState> {
  Timer? _timer;
  int _seq = 0;

  @override
  SearchState build() {
    ref.onDispose(() => _timer?.cancel());
    return const SearchState();
  }

  /// 输入入口：立即回显查询词，[kSearchDebounce] 后执行检索。
  void submit(String raw) {
    _timer?.cancel();
    final String q = raw.trim();
    if (q.isEmpty) {
      _seq++; // 使在途检索作废
      state = const SearchState();
      return;
    }
    state = SearchState(query: raw, searching: true);
    _timer = Timer(kSearchDebounce, () => _search(q));
  }

  Future<void> _search(String q) async {
    final int seq = ++_seq;
    final List<Note> notes = ref.read(notesProvider).value ?? const <Note>[];
    final Map<String, Note> byId = <String, Note>{
      for (final Note n in notes) n.id: n,
    };

    // 标题路（大小写不敏感；中文 contains 天然成立）。
    final String needle = q.toLowerCase();
    final Map<String, SearchHit> merged = <String, SearchHit>{
      for (final Note n in notes)
        if (n.title.toLowerCase().contains(needle))
          n.id: (note: n, titleMatch: true, snippet: null, score: null),
    };

    // 内容路。检索的任何失败都不能让搜索整体失败（与 Retriever 同一原则）。
    String? fallback;
    try {
      final result = await ref.read(retrieverProvider).search(
            q,
            limit: _contentLimit,
          );
      for (final hit in result.hits) {
        final Note? n = byId[hit.noteId];
        if (n == null) continue; // 已删除 / 尚未装载
        final SearchHit? existing = merged[n.id];
        merged[n.id] = (
          note: n,
          titleMatch: existing?.titleMatch ?? false,
          snippet: hit.snippet,
          score: hit.score,
        );
      }
      fallback = result.vectorFallbackReason;
    } on Object catch (e) {
      fallback = '检索不可用（$e）：本次只用标题';
    }

    if (seq != _seq) return; // 过期结果：用户已经又输入了

    final List<SearchHit> hits = merged.values.toList()
      ..sort((SearchHit a, SearchHit b) {
        // 标题命中置顶（最强信号），组内按 RRF 分，最后按修改时间兜底。
        final int byTitle = (a.titleMatch ? 0 : 1).compareTo(b.titleMatch ? 0 : 1);
        if (byTitle != 0) return byTitle;
        if (a.score != null && b.score != null) {
          return b.score!.compareTo(a.score!);
        }
        if (a.score != null) return -1;
        if (b.score != null) return 1;
        return b.note.revisedAt.compareTo(a.note.revisedAt);
      });

    state = SearchState(
      query: q,
      hits: hits,
      vectorFallbackReason: fallback,
    );
  }
}

final searchNotifierProvider =
    NotifierProvider<SearchNotifier, SearchState>(SearchNotifier.new);
