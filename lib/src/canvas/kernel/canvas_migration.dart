/// 画布 JSON 的 **schema 迁移链**（对标数据库侧的 `userVersion` + 自愈）。
///
/// ## 为什么需要它
/// `CanvasDocument.toJson` 的 `schemaVersion` 以前是**散落的兼容 `if`**（v1 走一个
/// 分支、v2 走另一个），每加一版就在解析器里再插一段条件判断；而且**没有"未来版本"
/// 的保护**——用新版 app 写过的画布，被旧版打开时会按旧规则解析，**静默丢字段**。
///
/// 这里把它收敛成一条**有向链**：
///
/// ```
/// v1 ──(_v1ToV2)──▶ v2 ──▶ ... ──▶ current
/// ```
///
/// - 解析器因此**只认当前版本**（迁移之后再解析）；
/// - 加新版本 = 加一个 `_vNToVn1` 分支，不动解析器；
/// - 存档版本**比内核新**时**抛异常**，绝不静默降级（宿主侧有"载入失败 ⇒ 冻结
///   保存"的兜底，数据不会被空画布覆盖）。
///
/// ## 迁移是纯 JSON 层的
/// 迁移函数只搬 JSON 键（不构造 `CanvasDocument`），所以可以在解析前跑，也便于
/// 单测。"迁移"与"解析"因此是两件事：前者管**格式落差**，后者管**对象构造**。
/// 当前内核支持的**最新**画布 schema 版本（= [CanvasMigrations.current]）。
///
/// 版本史：
/// - **v1**：`strokes` / `items` 是**数组**，列表顺序即 z 序（无显式 order 键）；
/// - **v2**：`strokes` / `items` 是 **id-keyed map** + 显式 `strokeOrder` /
///   `itemOrder`（2026-09 起）。
const int kCanvasSchemaVersion = 2;

abstract final class CanvasMigrations {
  /// 当前内核支持的**最新**画布 schema 版本（见 [kCanvasSchemaVersion]）。
  static const int current = kCanvasSchemaVersion;

  /// 把画布 **document 节点**（`{schemaVersion, strokes, items, ...}`，即
  /// `notes.content` 里 `document` 那一层）迁移到 [current]。
  ///
  /// **幂等**：对已是当前版本的输入直接返回等价内容。
  ///
  /// 抛：
  /// - [CanvasSchemaTooNewException]：存档版本 > [current]（拒绝按旧规则解析）；
  /// - [StateError]：迁移链缺一步（只会在开发期改链时发生，属于编码错误）。
  static Map<String, dynamic> migrate(Map<String, dynamic> document) {
    int v = _versionOf(document);
    if (v > current) {
      throw CanvasSchemaTooNewException(found: v, supported: current);
    }
    Map<String, dynamic> out = document;
    if (v < 2) {
      out = _v1ToV2(out);
      v = 2;
    }
    if (v != current) {
      throw StateError('画布迁移链缺 v$v → v$current 的一步');
    }
    // 归一化版本号：v1 存档本来没有这个键，迁完要写上（否则每次载入都重跑迁移）。
    out['schemaVersion'] = current;
    return out;
  }

  /// 读出处看到的版本号；**缺键 = v1**（v1 存档不写版本）。
  static int _versionOf(Map<String, dynamic> doc) {
    final dynamic raw = doc['schemaVersion'];
    return raw is num ? raw.toInt() : 1;
  }

  /// v1 → v2：`strokes` / `items` 由**数组**改成 **id-keyed map**，并把原来的
  /// 列表顺序提升为显式的 `strokeOrder` / `itemOrder`。
  ///
  /// 没有 `id` 的畸形条目**跳过**（v2 的 map 需要一个键；宁可少一条脏数据，
  /// 也不能造出空键把别的条目顶掉）。
  static Map<String, dynamic> _v1ToV2(Map<String, dynamic> j) {
    final Map<String, dynamic> out = Map<String, dynamic>.of(j);

    final dynamic strokes = j['strokes'];
    if (strokes is List) {
      final Map<String, dynamic> map = <String, dynamic>{};
      final List<String> order = <String>[];
      for (final dynamic s in strokes) {
        if (s is Map && s['id'] is String) {
          final String id = s['id'] as String;
          map[id] = s;
          order.add(id);
        }
      }
      out['strokes'] = map;
      out['strokeOrder'] = order;
    }

    final dynamic items = j['items'];
    if (items is List) {
      final Map<String, dynamic> map = <String, dynamic>{};
      final List<String> order = <String>[];
      for (final dynamic i in items) {
        if (i is Map && i['id'] is String) {
          final String id = i['id'] as String;
          map[id] = i;
          order.add(id);
        }
      }
      out['items'] = map;
      out['itemOrder'] = order;
    }

    return out;
  }
}

/// 存档的 schema 版本**比当前内核新**：用更新版本的 app 写过这篇画布。
///
/// 刻意**抛**而不是"尽力解析"——按旧规则解析会静默丢掉新字段（用户以为数据还在）。
/// 抛出去之后：宿主会提示并**冻结自动保存**（见 `canvas_note_view.dart`），
/// 于是旧版开新版画布**只会看不了，不会写坏**。
class CanvasSchemaTooNewException implements Exception {
  const CanvasSchemaTooNewException({
    required this.found,
    required this.supported,
  });

  /// 存档里的版本号。
  final int found;

  /// 本内核支持的最高版本（[CanvasMigrations.current]）。
  final int supported;

  @override
  String toString() =>
      'CanvasSchemaTooNewException: 画布存档 schemaVersion=$found，'
      '本版本只支持到 $supported。拒绝按旧规则解析（否则会静默丢弃新字段），'
      '请升级应用后打开。';
}
