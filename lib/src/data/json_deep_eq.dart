/// JSON 值的**结构深比较**：Map 按键比（顺序无关），List **按顺序**比。
///
/// 两条投影的迁移校验共用它：
/// - `BlockStore`（块树 ⇄ `blocks` 行）
/// - `CanvasStore`（画布 JSON ⇄ `canvas_items` / `ink_shards` 行）
///
/// 各自只实现自己的**归一化**（补默认值、剔除派生键、浮点量化），
/// **比较规则只有这一份**——两边各写一份深比较迟早会漂移，而漂移的表现是
/// "校验静默失效"（该拦住的没拦住），是迁移纪律里最危险的失败模式。
///
/// ⚠️ 不做字节比较：JSON 对象的键顺序无语义，而还原顺序未必与写出顺序一致。
/// ⚠️ 但**列表顺序有语义**（`children` / `itemOrder` / `strokeOrder` 是数组），
///    所以列表仍然被严格按顺序比较。
bool jsonDeepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!jsonDeepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final Object? key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!jsonDeepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}
