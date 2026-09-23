/// 切块器（`docs/data_layer.md` 6.7 R3）。
///
/// ## 为什么"块即 chunk"，还要切
/// `blocks` 本来就是天然的语义单元（编辑器一段 = 一个块），所以**绝大多数块直接
/// 就是一块 chunk**。只有从外部粘进来的超长块（整篇文章塞进一段）需要二次切：
/// 一条 5000 字的块嵌成一个向量会把语义稀释成噪声，检索时既不像 A 也不像 B。
///
/// ## 切法：按分隔符逐级降级，最后硬切
/// `\n\n` → `\n` → `。` 逐级尝试，在 [chunkSize] 内尽量装在**语义边界**上；
/// 单个片段本身超长（没有可用分隔符）时按 [chunkSize] 硬切。[chunkOverlap] 让
/// 相邻块共享一小段尾部——跨边界的那句话不至于两边都不像。
///
/// ## 版本号：切块规则一变就必须 +1
/// `index_state.chunker_version` 存的就是它（6.6①）。改规则而版本没动 ⇒ 库里
/// 留着"用旧规则切的块"，检索质量静默变差（这类脏数据最隐蔽：不报错，只是
/// 召回变差）。
library;

/// 切块规则版本（沿用 `fp1:` 的"版本前缀"风格，便于 grep）。
///
/// ⚠️ **改 [chunkSize] / [chunkOverlap] / 分隔符序列 / [bigram] 的规则，都要 +1。**
const String kChunkerVersion = 'ck1';

/// 单块目标字符数。512 是 WeKnora（腾讯那套 RAG 平台）初始化向导给的默认值，
/// 也是常见嵌入模型上下文窗口的舒适区。
const int kChunkSize = 512;

/// 相邻切块的重叠字符数（同上，WeKnora 的默认 50）。
const int kChunkOverlap = 50;

/// 逐级降级的分隔符序列：先按大边界切，再退到小边界。
const List<String> kChunkSeparators = <String>['\n\n', '\n', '。'];

/// 一个切块：`index` 是块内序号（0 起），[text] 是原文（进 `chunk_text`），
/// [searchText] 是 bigram 预处理后的检索串（进 `search_text`）。
typedef Chunk = ({int index, String text, String searchText});

/// 把一个块的文本切成若干 chunk。
///
/// 空文本 ⇒ 空列表（分隔线 / 图片这类块不参与索引，见 6.7 的"待处理数"判据）。
List<Chunk> chunkBlock(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return const <Chunk>[];
  final List<String> pieces = trimmed.length <= kChunkSize
      ? <String>[trimmed]
      : _split(trimmed);
  return <Chunk>[
    for (int i = 0; i < pieces.length; i++)
      (index: i, text: pieces[i], searchText: bigram(pieces[i])),
  ];
}

/// bigram 预处理：相邻两字一切、空格分隔（6.1）。
///
/// ⚠️ **写入与查询必须用同一个函数**：FTS5 默认 `unicode61` 分词器会把连续中文
/// 当成一个 token（存了"番茄工作法"，查"番茄"命中 0）。两边都 bigram 之后，
/// 查询串按 `"番茄" OR "茄工" OR …` 组合即可容忍召回（精确性交给 RRF 融合）。
///
/// 拉丁文本同样逐字符 bigram——**不求最优，只求两侧一致**（不一致才是 bug）。
String bigram(String text) {
  final String s = text.replaceAll(RegExp(r'\s+'), '');
  if (s.isEmpty) return '';
  if (s.length == 1) return s;
  final StringBuffer out = StringBuffer();
  for (int i = 0; i + 1 < s.length; i++) {
    if (i > 0) out.write(' ');
    out.write(s[i]);
    out.write(s[i + 1]);
  }
  return out.toString();
}

/// 按 [kChunkSeparators] 逐级降级切分，片段超长则硬切，最后按
/// [kChunkSize] / [kChunkOverlap] 打包。
List<String> _split(String text) {
  final List<String> atoms = _atoms(text);
  final List<String> out = <String>[];
  final StringBuffer current = StringBuffer();
  for (final String atom in atoms) {
    if (current.length + atom.length > kChunkSize && current.isNotEmpty) {
      out.add(current.toString());
      final String prev = out.last;
      current.clear();
      // 重叠：把上一块的尾部接进新块开头。**上限按下一个原子让位**
      // （`kChunkSize - atom.length`）——否则"50 重叠 + 512 原子"会让切块超上限，
      // 或退化成反复冲出一个 50 字的碎块。
      final int room = kChunkSize - atom.length;
      final int overlap = kChunkOverlap.clamp(0, room < 0 ? 0 : room);
      if (overlap > 0) {
        current.write(
          prev.substring(prev.length - overlap.clamp(0, prev.length)),
        );
      }
    }
    current.write(atom);
  }
  if (current.isNotEmpty) out.add(current.toString());
  return out;
}

/// 把文本拆成"原子片段"：优先用最粗的分隔符切，剩下的片段若仍超长，
/// 用更细的分隔符继续切，都不行才按长度硬切。
List<String> _atoms(String text) {
  List<String> parts = <String>[text];
  for (final String sep in kChunkSeparators) {
    final List<String> next = <String>[];
    for (final String part in parts) {
      if (part.length <= kChunkSize) {
        next.add(part);
        continue;
      }
      // 保留分隔符本身（"。" 是语义的一部分），故用正则分行而不是 split。
      //
      // ⚠️ 分隔符必须**整体**加 `?`（`(?:…)?`）：写成 `…\n\n?` 时 `?` 只作用于
      // 最后一个字符（"换行 + 可选换行"），于是不含换行的长文本一个匹配都没有
      // ⇒ 整段被静默丢掉（内容凭空消失，最难发现的一类 bug）。
      for (final Match m in RegExp(
        '[^${RegExp.escape(sep)}]*(?:${RegExp.escape(sep)})?',
      ).allMatches(part)) {
        final String piece = m[0]!;
        if (piece.isNotEmpty) next.add(piece);
      }
    }
    parts = next;
  }
  // 仍超长的片段：没有可用分隔符 ⇒ 硬切。
  final List<String> out = <String>[];
  for (final String part in parts) {
    if (part.length <= kChunkSize) {
      out.add(part);
      continue;
    }
    for (int i = 0; i < part.length; i += kChunkSize) {
      out.add(part.substring(i, (i + kChunkSize).clamp(0, part.length)));
    }
  }
  return out;
}
