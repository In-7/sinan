import 'package:flutter_test/flutter_test.dart';
import 'package:highlight/highlight.dart' as hl;
import 'package:sinan/src/notes/services/note_code_syntax.dart';

/// [CodeTokenCache] 的契约（2026-09-17）：
/// 记忆化、**否定缓存**（无 token / 抛异常也记住）、LRU 容量上限。
///
/// 之所以要单独测：这三条以前只能靠"看代码推理"——解析入口是私有的顶层函数，
/// 而"有没有重复解析"在集成测试里根本观察不到。注入 [CodeTokenCache.parse]
/// 替身之后，解析次数成了可直接断言的事实。
/// 可计数的解析替身：按文本返回预设结果（`throwsFor` 里的文本抛异常）。
class _Counter {
  int calls = 0;
  final Map<String, List<hl.Node>?> results = <String, List<hl.Node>?>{};
  final Set<String> throwsFor = <String>{};

  List<hl.Node>? parse(String text) {
    calls++;
    if (throwsFor.contains(text)) throw StateError('boom');
    return results[text];
  }
}

void main() {
  List<hl.Node> token(String value) => <hl.Node>[hl.Node(value: value)];

  test('同一段文本只解析一次（记忆化）', () {
    final _Counter c = _Counter()..results['a = 1'] = token('a');
    final CodeTokenCache cache = CodeTokenCache(parse: c.parse);

    expect(cache.of('a = 1'), isNotNull);
    expect(cache.of('a = 1'), isNotNull);
    expect(cache.of('a = 1'), isNotNull);
    expect(c.calls, 1, reason: '命中了缓存却仍在解析');
  });

  test('无 token 的文本被记住（否定缓存）：不再反复解析 26 种语言', () {
    final _Counter c = _Counter(); // '---' 没有结果
    final CodeTokenCache cache = CodeTokenCache(parse: c.parse);

    expect(cache.of('---'), isNull);
    expect(cache.of('---'), isNull);
    expect(c.calls, 1, reason: '否定结果没被缓存，每帧都会重试');
    expect(cache.length, 1);
  });

  test('解析抛异常：不崩、返回 null，且同样被记住', () {
    final _Counter c = _Counter()..throwsFor.add('炸');
    final CodeTokenCache cache = CodeTokenCache(parse: c.parse);

    expect(cache.of('炸'), isNull);
    expect(cache.of('炸'), isNull);
    expect(c.calls, 1);
    expect(cache.length, 1);
  });

  test('容量上限 + 淘汰最久未用（LRU）', () {
    final _Counter c = _Counter();
    for (final String t in <String>['a', 'b', 'c']) {
      c.results[t] = token(t);
    }
    final CodeTokenCache cache = CodeTokenCache(parse: c.parse, maxSize: 3);

    cache.of('a');
    cache.of('b');
    cache.of('c');
    cache.of('a'); // a 变热

    cache.of('d'); // 应淘汰 b

    final int before = c.calls;
    expect(cache.of('a'), isNotNull);
    expect(c.calls, before, reason: 'a 被误淘汰（说明不是 LRU）');
    expect(cache.length, 3);
  });
}
