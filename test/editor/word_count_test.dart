import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/editor/core/word_count.dart';

/// 字数统计口径的回归（2026-09-17 抽离自编辑器的巨型 State）。
///
/// 这些用例此前**无法写**：算法埋在 1200 行的 `_NoteEditorViewAppFlowyState`
/// 里，只能靠 widget test 间接观察。抽出纯函数后，口径本身成了可钉的契约。
void main() {
  group('CJK 逐字计数', () {
    test('中文按字', () {
      expect(countWords('你好世界'), 4);
    });

    test('重复字也逐字算', () {
      expect(countWords('哈哈哈哈哈'), 5);
    });

    test('日文假名并入 CJK', () {
      expect(countWords('こんにちは'), 5);
    });

    test('全角标点不计入（不在 CJK 区间）', () {
      expect(countWords('，。！？；：'), 0);
      expect(countWords('你好，世界！'), 4);
    });
  });

  group('拉丁 / 数字按词', () {
    test('英文按词，不按字母', () {
      expect(countWords('hello world'), 2);
    });

    test('连续字母数字算一个词', () {
      expect(countWords('abc123'), 1);
    });

    test('下划线是分隔符（foo_bar = 2 个词）', () {
      expect(countWords('foo_bar'), 2);
    });

    test('标点分隔不计入', () {
      expect(countWords('hello, world!'), 2);
      expect(countWords('!!!'), 0);
    });
  });

  group('混合与边界', () {
    test('中英混排相加', () {
      // 你/好/世/界 = 4 字；hello、123 = 2 词
      expect(countWords('你好 hello 世界 123'), 6);
    });

    test('空串与纯空白为 0', () {
      expect(countWords(''), 0);
      expect(countWords('   \n\t  '), 0);
    });

    test('换行不粘连两个词', () {
      expect(countWords('foo\nbar'), 2);
    });

    test('代码片段：符号分隔出多个词', () {
      // final、x、1、y、2 → 5 个词
      expect(countWords('final x = 1 + y * 2;'), 5);
    });
  });
}
