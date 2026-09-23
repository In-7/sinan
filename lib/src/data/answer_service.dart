import '../ai/llm_client.dart';
import 'retriever.dart';

/// 一条引用：编号 [index] 就是 prompt 里的 `[n]`，其余是它对应的块。
typedef Citation = ({int index, String blockId, String noteId, String snippet});

/// 一次问答的结果。
///
/// [unknownCitations] 是模型**编出来的编号**（不在本次资料范围内，如只给了 5 条
/// 却引用 `[7]`）。它不进 [citations]（宁可不显示，也不能指错块——见类文档），
/// 但保留下来便于排查模型质量。
typedef Answer = ({
  String text,
  List<Citation> citations,
  List<int> unknownCitations,
  bool vectorUsed,
  String? vectorFallbackReason,
});

/// 问答层（`docs/data_layer.md` 6.7 R5）：**检索 → 带编号的资料 → 生成 → 引用还原**。
///
/// ## 引用是这层的契约核心
/// prompt 里每条资料带死编号（`[1]`…），模型在答案里回投同样的编号。于是
/// **编号 → block 的映射由我们控制**，模型只负责"说哪条对得上"，不负责给坐标。
/// 这比让模型吐 `block_id` 可靠得多（模型没有稳定 id 的概念，编出来的 id 指到
/// 别的块 = **引到别人的话**，是这类功能最严重的事故）。
///
/// ## 初版不做流式
/// 现客户端是整段返回（6.7 的 R5 行）。SSE 留到真实使用后按手感决定，而不是
/// 先写一套流式状态机再猜它值不值。
class AnswerService {
  AnswerService({required this.retriever, required this.llm});

  final Retriever retriever;
  final LlmClient llm;

  /// 系统提示词。**要求编号引用**是它唯一的硬约束；其余（语气、长度）都是软的，
  /// 因为模型忽略软要求的代价小，忽略编号要求则会让引用还原失效。
  static const String systemPrompt =
      '你是本地笔记库的问答助手。规则：\n'
      '1. 只依据下面给出的资料回答，不要使用资料之外的知识，也不要编造；\n'
      '2. 每个结论后面用方括号标出资料编号，例如 [1] 或 [2][3]；\n'
      '3. 资料不足以回答时，直接说"笔记里没有相关内容"；\n'
      '4. 用简体中文简洁作答。';

  /// 检索几条资料给模型。太少覆盖面不足，太多会稀释注意力（也更容易被乱引）。
  static const int defaultLimit = 6;

  Future<Answer> ask(String question, {int limit = defaultLimit}) async {
    final RetrievalResult retrieved = await retriever.search(
      question,
      limit: limit,
    );

    // 一条都没检索到 ⇒ **不调模型**。此时让模型自由发挥只会得到幻觉，
    // 而"没有相关内容"本身就是正确答案（也省一次往返）。
    if (retrieved.hits.isEmpty) {
      return (
        text: '笔记里没有相关内容。',
        citations: const <Citation>[],
        unknownCitations: const <int>[],
        vectorUsed: retrieved.vectorUsed,
        vectorFallbackReason: retrieved.vectorFallbackReason,
      );
    }

    final String prompt = buildUserPrompt(question, retrieved.hits);
    final String text = await llm.complete(system: systemPrompt, user: prompt);

    final List<int> cited = parseCitationIndexes(text);
    final List<Citation> citations = <Citation>[];
    final List<int> unknown = <int>[];
    final Set<int> seen = <int>{};
    for (final int index in cited) {
      if (!seen.add(index)) continue;
      if (index < 1 || index > retrieved.hits.length) {
        unknown.add(index);
        continue;
      }
      final RetrievalHit hit = retrieved.hits[index - 1];
      citations.add((
        index: index,
        blockId: hit.blockId,
        noteId: hit.noteId,
        snippet: hit.snippet,
      ));
    }

    return (
      text: text,
      citations: citations,
      unknownCitations: unknown,
      vectorUsed: retrieved.vectorUsed,
      vectorFallbackReason: retrieved.vectorFallbackReason,
    );
  }

  /// 拼用户提示词（**纯函数**）：`[n] 资料` 若干行 + 最后一行提问。
  ///
  /// 编号从 1 起、与 [hits] 顺序严格对应——[ask] 还原引用时用的就是这个下标关系，
  /// 两边必须一起改。
  static String buildUserPrompt(String question, List<RetrievalHit> hits) {
    final StringBuffer out = StringBuffer('资料：\n');
    for (int i = 0; i < hits.length; i++) {
      out
        ..write('[${i + 1}] ')
        // 摘要里的换行会打乱"一行一条"的结构，压成单行（内容不截断：截断可能
        // 恰好切掉答案所在的那句）。
        ..writeln(hits[i].snippet.replaceAll(RegExp(r'\s+'), ' ').trim());
    }
    out
      ..writeln()
      ..write('问题：')
      ..write(question);
    return out.toString();
  }

  /// 从答案里抽出引用编号（**纯函数**）：按出现顺序，**不去重**。
  ///
  /// 去重与越界校验是 [ask] 的职责——这里只做"文本里出现了哪些编号"这一件事，
  /// 职责越窄越好测（去重后的顺序语义是 ask 定的，不该在这里藏一份）。
  ///
  /// 只认 `[数字]`；`[1,2]`、`(1)`、`【1】` 一概不认——**宁可漏认也不能错认**：
  /// 漏认只是少个角标，错认会指到别的块上。
  static List<int> parseCitationIndexes(String answer) {
    final List<int> out = <int>[];
    for (final RegExpMatch m in RegExp(r'\[(\d+)\]').allMatches(answer)) {
      final int? n = int.tryParse(m[1]!);
      if (n != null) out.add(n);
    }
    return out;
  }
}
