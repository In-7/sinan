/// 极简 LRU 缓存（按**访问**顺序淘汰）。
///
/// ## 为什么自己写而不是用包
/// 需要的能力只有三条：容量上限、命中即刷新新近度、淘汰最久未用。`package:collection`
/// 的 `MapCache` 是 FIFO 语义（插入序），正好是这里要避免的——所以在 20 行内自备。
///
/// ## 与 FIFO 的差别（为什么值得换）
/// 记忆化的典型场景是"几段热文本反复进出"：FIFO 只看**插入**时间，会把仍在用的
/// 老条目踢掉（下一次访问又要重算）；LRU 看**访问**时间，热条目会一直被刷新到队尾。
///
/// ⚠️ 值不允许为 `null`：`operator []` 用 `null` 表示"未命中"，无法区分
/// "缓存了 null"。需要表达"已试过但没有结果"时，请用空集合之类的哨兵值。
class LruCache<K, V> {
  LruCache({required this.maxSize}) : assert(maxSize > 0, '容量必须为正');

  final int maxSize;

  /// 插入顺序即**访问顺序**：命中时把键删了重插，于是队首永远是"最久未用"。
  final Map<K, V> _entries = <K, V>{};

  int get length => _entries.length;

  bool containsKey(K key) => _entries.containsKey(key);

  /// 读：命中则同时刷新新近度；未命中返回 `null`。
  V? operator [](K key) {
    final V? value = _entries.remove(key);
    if (value == null) return null;
    _entries[key] = value;
    return value;
  }

  /// 写：已存在的键先移除（保证新近度正确），超容量则淘汰队首。
  void put(K key, V value) {
    _entries.remove(key);
    _entries[key] = value;
    if (_entries.length > maxSize) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clear() => _entries.clear();
}
