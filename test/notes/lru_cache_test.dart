import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/notes/services/lru_cache.dart';

/// [LruCache] 的契约（2026-09-17）：容量上限 + **按访问顺序**淘汰。
///
/// 之所以要单独测：`note_code_syntax.dart` 的解析记忆化靠它兜住内存，
/// 而"淘汰顺序"这种性质在集成测试里几乎观察不到（只有换成 FIFO 才会露头，
/// 表现为交替编辑两段文本时反复重解析）。
void main() {
  group('容量与淘汰', () {
    test('超过容量时淘汰**最久未用**，不是最早插入', () {
      final LruCache<String, int> cache = LruCache<String, int>(maxSize: 3);
      cache.put('a', 1);
      cache.put('b', 2);
      cache.put('c', 3);

      // 访问 a ⇒ a 变成"最新"，最久未用的变成 b。
      expect(cache['a'], 1);

      cache.put('d', 4); // 应淘汰 b

      expect(cache.containsKey('b'), isFalse, reason: '被淘汰的应该是 b');
      expect(cache.containsKey('a'), isTrue);
      expect(cache.containsKey('c'), isTrue);
      expect(cache.containsKey('d'), isTrue);
      expect(cache.length, 3);
    });

    test('FIFO 会淘汰的那个恰好被保留（与 FIFO 的区别所在）', () {
      final LruCache<String, int> cache = LruCache<String, int>(maxSize: 2);
      cache.put('hot', 1);
      cache.put('cold', 2);

      // 反复访问 hot：它虽然插入最早，但一直是热的。
      expect(cache['hot'], 1);
      expect(cache['hot'], 1);

      cache.put('new', 3); // FIFO 会踢掉 hot；LRU 应踢掉 cold
      expect(cache.containsKey('hot'), isTrue);
      expect(cache.containsKey('cold'), isFalse);
    });

    test('覆盖已存在的键不撑大容量，且刷新新近度', () {
      final LruCache<String, int> cache = LruCache<String, int>(maxSize: 2);
      cache.put('a', 1);
      cache.put('b', 2);
      cache.put('a', 10); // 覆盖：a 移到队尾

      cache.put('c', 3); // 应淘汰 b

      expect(cache['a'], 10);
      expect(cache.containsKey('b'), isFalse);
      expect(cache.length, 2);
    });

    test('容量为 1 时只保留最后一个', () {
      final LruCache<String, int> cache = LruCache<String, int>(maxSize: 1);
      cache.put('a', 1);
      cache.put('b', 2);
      expect(cache.containsKey('a'), isFalse);
      expect(cache['b'], 2);
    });
  });

  group('读写语义', () {
    test('未命中返回 null，且不留下空条目', () {
      final LruCache<String, int> cache = LruCache<String, int>(maxSize: 2);
      expect(cache['missing'], isNull);
      expect(cache.length, 0);
    });

    test('clear 清空', () {
      final LruCache<String, int> cache = LruCache<String, int>(maxSize: 2);
      cache.put('a', 1);
      cache.clear();
      expect(cache.length, 0);
      expect(cache['a'], isNull);
    });

    test('值类型可以是空集合（否定缓存的用法）', () {
      final LruCache<String, List<int>> cache =
          LruCache<String, List<int>>(maxSize: 2);
      const List<int> noTokens = <int>[];
      cache.put('plain', noTokens);

      // 命中返回的是空列表本身，而不是 null（调用方据此区分"未命中"与"无结果"）。
      expect(cache['plain'], isNotNull);
      expect(cache['plain'], isEmpty);
    });

    test('容量必须为正', () {
      expect(() => LruCache<String, int>(maxSize: 0), throwsAssertionError);
    });
  });
}
