import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/chunker.dart';

/// 切块器回归（`docs/data_layer.md` 6.7 R3）。钉住三件事：
/// 1. **块即 chunk**——绝大多数块只有一个 chunk（不要为切而切）；
/// 2. 超长块按 `\n\n → \n → 。` 降级切，且每块不超过 [kChunkSize]；
/// 3. bigram 是**写入与查询两侧共用**的预处理（6.1），规则不能被悄悄改掉。
void main() {
  test('空文本（分隔线/图片这类块）⇒ 不产出 chunk', () {
    expect(chunkBlock('   \n  '), isEmpty);
  });

  test('短块：块即 chunk，index 从 0、searchText 是 bigram 结果', () {
    final List<Chunk> chunks = chunkBlock('番茄工作法');
    expect(chunks, hasLength(1));
    expect(chunks.single.index, 0);
    expect(chunks.single.text, '番茄工作法');
    expect(chunks.single.searchText, '番茄 茄工 工作 作法');
  });

  test('bigram：单字保底、空白剔除、与 6.1 的示例一致', () {
    expect(bigram('番茄工作法'), '番茄 茄工 工作 作法');
    expect(bigram('好'), '好');
    expect(bigram('  '), '');
    expect(bigram('a b'), 'ab');
  });

  test('超长块：按分隔符切成多块，编号连续、每块不超上限', () {
    // 每段 300 字、段间 `\n\n`：单段不超 512，但合起来远超 ⇒ 必须切。
    final String section = '${'甲' * 298}。';
    final String text = <String>[
      section,
      section,
      section,
      section,
    ].join('\n\n');

    final List<Chunk> chunks = chunkBlock(text);
    expect(chunks.length, greaterThan(1));
    for (int i = 0; i < chunks.length; i++) {
      expect(chunks[i].index, i);
      expect(
        chunks[i].text.length,
        lessThanOrEqualTo(kChunkSize),
        reason: '切块不能超过 $kChunkSize 字（重叠已计入）',
      );
      expect(chunks[i].searchText, isNotEmpty);
    }
  });

  test('无分隔符的超长块：退到硬切（不丢字）', () {
    final String text = '甲' * (kChunkSize * 2 + 7);
    final List<Chunk> chunks = chunkBlock(text);
    expect(chunks.length, greaterThanOrEqualTo(2));
    // 重叠会重复少量字符，但**绝不能少**（少 = 静默丢内容）。
    final int joined = chunks.fold(0, (int n, Chunk c) => n + c.text.length);
    expect(joined, greaterThanOrEqualTo(text.length));
  });
}
