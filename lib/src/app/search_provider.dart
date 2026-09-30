import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/note.dart';
import 'providers.dart';

/// 一条全局搜索命中（已归并到**笔记**粒度）。
///
/// 检索命中单元是 block（内容路返回的 `ContentRetrievalHit`），但搜索结果列表
/// 以笔记为单位——
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
    this.activeTag,
  });

  final String query;
  final List<SearchHit> hits;

  /// 去抖窗口内 / 检索进行中。
  final bool searching;

  /// 语义路降级原因（6.4：**提示而非错误**）——没配嵌入模型 / 扩展缺席时，
  /// 关键词路照常工作，UI 只需要一句话说明"本次只有关键词检索"。
  final String? vectorFallbackReason;

  /// 当前选中的**标签筛选**（null = 不过滤）。与查询词正交：
  /// 有词时对命中做内存过滤；无词时单独当"标签视图"用（见 [SearchNotifier.selectTag]）。
  final String? activeTag;
}

/// 输入去抖窗口。FTS5 查询本身 <10ms，去抖主要防每个键一次 rebuild +
/// 语义路（配了 Ollama 时）每个键一次 HTTP。
const Duration kSearchDebounce = Duration(milliseconds: 250);

/// 全局搜索（标题 + 内容）。
///
/// ## 两条路，一次合并
/// - **标题路**：内存里做——[notesProvider] 本来就装着全部笔记的标题，
///   `contains` 即可，零 SQL、零索引依赖（新建未索引的笔记标题也能搜到）；
/// - **内容路**：经注入的 `ContentRetriever` 端口（FTS5 关键词路 + 可选语义
///   路 → RRF，实现在 data 层、由 providers 适配），
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
    // **列表一变，结果跟着重算**（为什么必须 listen，见 [_onNotesChanged]）。
    ref.listen(notesProvider, (
      AsyncValue<List<Note>>? _,
      AsyncValue<List<Note>> next,
    ) {
      if (next.value != null) _onNotesChanged();
    });
    return const SearchState();
  }

  /// notesProvider 变化（打/删标签、删除/恢复笔记）后重算结果。
  ///
  /// 为什么必须 listen 而不是把 hits 里的 Note 当活的：[SearchState.hits] 是
  /// `selectTag` / `_search` 算出来的**静态快照**，里面抱的 Note 也是旧对象
  /// （tags 字段是打快照那一刻的）。chips 行 watch 着新列表、结果列表停在
  /// 快照上，两边必然打架——"标签取消了，chips 没了，带标签的文章还挂着"
  /// （2026-09-26 实机）。有查询词时重跑一次检索（FTS 便宜；语义路重打一次
  /// HTTP，但只在列表真变了时发生，打/删标签不是高频操作，可接受）。
  void _onNotesChanged() {
    final SearchState s = state;
    final List<Note> notes = ref.read(notesProvider).value ?? const <Note>[];
    final String? tag = s.activeTag;
    // 选中的标签从池子里**彻底消失**（最后一篇的标签被摘掉）⇒ 连筛选一起撤：
    // 否则用户盯着一个已不存在的 chip 对应的空列表，Esc 都得多按一层。
    final bool tagAlive = tag == null
        ? true
        : notes.any((Note n) => n.tags.contains(tag));

    if (s.query.isEmpty) {
      // 空查询：标签视图 / 空态是纯内存推导，直接用新列表算。
      state = tagAlive ? _tagView(s.activeTag) : const SearchState();
      return;
    }
    // 有查询词：重跑检索（落地时按 activeTag 过滤的那套不变）。
    if (!tagAlive) {
      state = SearchState(
        query: s.query,
        searching: s.searching,
        vectorFallbackReason: s.vectorFallbackReason,
      );
    }
    unawaited(_search(s.query));
  }

  /// 输入入口：立即回显查询词，[kSearchDebounce] 后执行检索。
  ///
  /// 清词**不丢标签筛选**：activeTag 还在时就落进"标签视图"（标签本身就是
  /// 一条查询），Esc 清词后 chips 的选中态与结果保持一致。
  void submit(String raw) {
    _timer?.cancel();
    final String q = raw.trim();
    if (q.isEmpty) {
      _seq++; // 使在途检索作废
      state = _tagView(state.activeTag);
      return;
    }
    state = SearchState(
      query: raw,
      activeTag: state.activeTag,
      searching: true,
    );
    _timer = Timer(kSearchDebounce, () => _search(q));
  }

  /// 选中 / 取消一个标签筛选（点已选中的 = 取消，传 null）。
  ///
  /// 三种情形：
  /// - **无查询词**：标签本身就是查询 ⇒ 落进"标签视图"（该标签的全部笔记，
  ///   最近修改倒序，与列表口径一致）——chips 单独就能当按标签逛的入口；
  /// - **有查询词且空闲**：对当前命中做**内存过滤**，不重跑检索——FTS 便宜，
  ///   但语义路是 HTTP，为点一个 chip 重打一遍 Ollama 不值得；
  /// - **有查询词且在途**：只改 state，[_search] 落地时统一按 activeTag 过滤。
  void selectTag(String? tag) {
    if (state.activeTag == tag) return;
    final String q = state.query.trim();
    if (q.isEmpty) {
      _seq++; // 作废在途检索
      state = _tagView(tag);
      return;
    }
    state = SearchState(
      query: state.query,
      activeTag: tag,
      searching: state.searching,
      vectorFallbackReason: state.vectorFallbackReason,
      hits: _filterByTag(state.hits, tag),
    );
  }

  /// 空查询的"标签视图"。查 null = 回到初始空态。
  SearchState _tagView(String? tag) {
    if (tag == null) return const SearchState();
    final List<Note> notes = ref.read(notesProvider).value ?? const <Note>[];
    final List<SearchHit> hits =
        <SearchHit>[
          for (final Note n in notes)
            if (n.tags.contains(tag))
              (note: n, titleMatch: false, snippet: null, score: null),
        ]..sort(
          (SearchHit a, SearchHit b) =>
              b.note.revisedAt.compareTo(a.note.revisedAt),
        );
    return SearchState(activeTag: tag, hits: hits);
  }

  /// 标签筛选（纯内存；标签**跨 kind 一套池子**，画布笔记同样命中）。
  static List<SearchHit> _filterByTag(List<SearchHit> hits, String? tag) =>
      tag == null
      ? hits
      : hits
            .where((SearchHit h) => h.note.tags.contains(tag))
            .toList(growable: false);

  Future<void> _search(String q) async {
    final int seq = ++_seq;
    final List<Note> notes = ref.read(notesProvider).value ?? const <Note>[];

    // 检索本体（标题路 + 内容路、归并、排序）抽成了**纯函数**
    // [searchAllNotes]：页内搜索与 Ctrl+K 全局浮层共用同一条相关性口径，
    // 这里只补竞态序号与标签过滤两件 SearchNotifier 自己的事。
    final ({List<SearchHit> hits, String? fallback}) outcome =
        await searchAllNotes(
          notes: notes,
          retrieve: ref.read(contentRetrieverProvider),
          query: q,
        );

    if (seq != _seq) return; // 过期结果：用户已经又输入了

    // 标签筛选在**落地时**统一套（读此刻的 state.activeTag）：覆盖"筛选选中
    // 期间输入新词 / 在途检索"两种时序，筛选逻辑只有 [_filterByTag] 一份。
    state = SearchState(
      query: q,
      activeTag: state.activeTag,
      hits: _filterByTag(outcome.hits, state.activeTag),
      vectorFallbackReason: outcome.fallback,
    );
  }
}

/// 全局检索的**纯算法核心**（无 Riverpod、无竞态状态、不依赖 data 层）：
/// 标题路（内存 contains，新建未索引的笔记也搜得到）＋ 内容路
/// （[ContentRetriever] 端口：FTS5 关键词路 + 可选语义路 → RRF），
/// 归并到**笔记粒度**、标题命中置顶、组内按 RRF 分、最后修改时间兜底。
///
/// 两个消费方共用它，相关性口径因此只有一份：
/// - 页内搜索 [SearchNotifier]（在外面套竞态序号 + 标签过滤）；
/// - Ctrl+K 全局搜索浮层（在外面套自己的去抖与 mounted 守卫）。
Future<({List<SearchHit> hits, String? fallback})> searchAllNotes({
  required List<Note> notes,
  required ContentRetriever retrieve,
  required String query,
  int contentLimit = 30,
}) async {
  final Map<String, Note> byId = <String, Note>{
    for (final Note n in notes) n.id: n,
  };

  // 标题路（大小写不敏感；中文 contains 天然成立）。
  final String needle = query.toLowerCase();
  final Map<String, SearchHit> merged = <String, SearchHit>{
    for (final Note n in notes)
      if (n.title.toLowerCase().contains(needle))
        n.id: (note: n, titleMatch: true, snippet: null, score: null),
  };

  // 内容路。检索的任何失败都不能让搜索整体失败（与 data 层 Retriever
  // 同一原则）。
  String? fallback;
  try {
    final ContentRetrievalOutcome result = await retrieve(
      query,
      limit: contentLimit,
    );
    for (final ContentRetrievalHit hit in result.hits) {
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

  final List<SearchHit> sorted = merged.values.toList()
    ..sort((SearchHit a, SearchHit b) {
      // 标题命中置顶（最强信号），组内按 RRF 分，最后按修改时间兜底。
      final int byTitle = (a.titleMatch ? 0 : 1).compareTo(
        b.titleMatch ? 0 : 1,
      );
      if (byTitle != 0) return byTitle;
      if (a.score != null && b.score != null) {
        return b.score!.compareTo(a.score!);
      }
      if (a.score != null) return -1;
      if (b.score != null) return 1;
      return b.note.revisedAt.compareTo(a.note.revisedAt);
    });

  return (hits: sorted, fallback: fallback);
}

final searchNotifierProvider = NotifierProvider<SearchNotifier, SearchState>(
  SearchNotifier.new,
);

/// 全库**标签池**（跨 kind 一套）：按出现篇数倒序、同数按名称排。
///
/// 搜索页标签 chips 的数据源。[notesProvider] 本来就装着全部笔记的元数据，
/// 这里纯内存聚合，零额外查询；标签一变（打/删）列表刷新时自动跟着重算。
final allTagsProvider = Provider<List<(String, int)>>((ref) {
  final List<Note> notes = ref.watch(notesProvider).value ?? const <Note>[];
  final Map<String, int> counts = <String, int>{};
  for (final Note n in notes) {
    for (final String t in n.tags) {
      counts[t] = (counts[t] ?? 0) + 1;
    }
  }
  final List<(String, int)> out =
      <(String, int)>[
        for (final MapEntry<String, int> e in counts.entries) (e.key, e.value),
      ]..sort(((String, int) a, (String, int) b) {
        final int byCount = b.$2.compareTo(a.$2);
        if (byCount != 0) return byCount;
        return a.$1.compareTo(b.$1);
      });
  return out;
});
