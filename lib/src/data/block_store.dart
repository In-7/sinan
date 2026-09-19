import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'fingerprint.dart';
import 'json_deep_eq.dart';

/// 块级写入：`notes.content`（v2 块树 JSON）→ `blocks` 行。
///
/// ## 定位
/// 这是 `docs/data_layer.md` 迁移第 2 步（双写）的实现。此刻 `notes.content`
/// 仍是**真相源**，`blocks` 是它的**投影**；读路径还没切过来（第 5 步）。
///
/// ## 做什么、不做什么
/// - ✅ **只做结构扁平化**：把嵌套的块树摊平成 `(id, parent_id, ord, type, props_json)`；
/// - ❌ **不解析 `props_json`**：存储层对块内部结构保持无知（设计原则：
///   「透明的块边界 + 不透明的块内容」），所以加块类型永远不用改表。
///
/// ## 判变粒度
/// 每块一个指纹，**只覆盖它自己的 `type` + `data`，不含子孙**。
/// 这样改一个段落只重写那一行；若把子孙算进去，改最深的叶子会连带把
/// 整条祖先链都判为"变了"——那正是"整篇重写"的翻版，等于白拆。
class BlockStore {
  BlockStore(this.db);

  final Database db;

  /// `ord` 的步长：留空隙，插入时可夹在中间而不重排（见设计文档第四节）。
  static const int ordStep = 1024;

  /// v2 块树的格式标记（与 `NoteDocumentAdapter` 的 `blocksFormat` 一致）。
  ///
  /// 只认这个值：存量 Delta / 裸 appflowy JSON 的笔记**不投影**，
  /// 等它被编辑、写成块树后再同步（编辑器首次保存即升级为 v2）。
  static const String _blocksFormat = 'blocks';

  /// 把一篇笔记的块树**整体同步**进 `blocks`。
  ///
  /// 返回本次**真正写到的**行数（新增 + 更新 + 删除）。没变化返回 0，
  /// 调用方可以据此跳过后续动作。
  ///
  /// [content] 是整篇正文（v2 块树 JSON 字符串）；不是这个格式的直接跳过（返回 0）。
  int replaceNoteBlocks(String noteId, String content) {
    final Map<String, Object?>? document = _parseBlocksDocument(content);
    if (document == null) return 0;

    final List<_FlatBlock> flat = _flatten(document);
    final Map<String, _Existing> existing = _existingOf(noteId);

    final Set<String> keep = <String>{
      for (final _FlatBlock b in flat) b.id,
    };
    // 块可迁移（#5）的**安全前提**：被画布卡片引用的块（canvas_items.block_id）
    // 即便不在文档块树里，也**不许删**。否则"把块搬到画布"后，下一次文档保存
    // 的 replaceNoteBlocks 会把这块连同卡片一起删掉。所以删除集要排除这些块——
    // 它们由画布侧的生命周期托管，不归文档块树管。
    final Set<String> canvasReferenced = _canvasReferencedBlockIds();
    final List<String> removed = <String>[
      for (final MapEntry<String, _Existing> e in existing.entries)
        if (!keep.contains(e.key) && !canvasReferenced.contains(e.key)) e.key,
    ];
    final List<_FlatBlock> changed = <_FlatBlock>[
      for (final _FlatBlock b in flat)
        if (_needsWrite(b, existing[b.id])) b,
    ];

    if (removed.isEmpty && changed.isEmpty) return 0;

    final int now = DateTime.now().millisecondsSinceEpoch;
    db.execute('BEGIN;');
    try {
      for (final String id in removed) {
        db.execute('DELETE FROM blocks WHERE id = ?', <Object?>[id]);
      }
      for (final _FlatBlock b in changed) {
        db.execute(
          'INSERT INTO blocks '
          '(id, note_id, type, props_json, ord, parent_id, created_at, updated_at, fingerprint) '
          'VALUES (?,?,?,?,?,?,?,?,?) '
          'ON CONFLICT(id) DO UPDATE SET '
          'type = excluded.type, props_json = excluded.props_json, '
          'ord = excluded.ord, parent_id = excluded.parent_id, '
          'updated_at = excluded.updated_at, fingerprint = excluded.fingerprint',
          <Object?>[
            b.id,
            noteId,
            b.type,
            b.propsJson,
            b.ord,
            b.parentId,
            now,
            now,
            b.fingerprint,
          ],
        );
      }
      db.execute('COMMIT;');
    } on Object {
      db.execute('ROLLBACK;');
      rethrow;
    }
    return changed.length + removed.length;
  }

  /// 删掉一篇笔记的块（`notes` 的级联删除已经覆盖，这里给显式调用留口）。
  void deleteNoteBlocks(String noteId) {
    db.execute('DELETE FROM blocks WHERE note_id = ?', <Object?>[noteId]);
  }

  /// **反向投影**：`blocks` 行 → v2 块树 JSON 字符串。
  ///
  /// 这是迁移第 5 步（切读）的另一半：[replaceNoteBlocks] 把树摊平，
  /// 它把树装回去。装回去的结果必须能被编辑器**原样读回**。
  ///
  /// 一篇没有任何块行时返回 null（交给调用方回退到旧列）。
  String? readNoteDocument(String noteId) {
    final ResultSet rs = db.select(
      'SELECT id, type, props_json, ord, parent_id FROM blocks '
      'WHERE note_id = ? ORDER BY ord',
      <Object?>[noteId],
    );
    if (rs.isEmpty) return null;

    // 先把所有节点建出来（含空 children），再按 parent_id 挂上去。
    final Map<String, Map<String, Object?>> nodes = <String, Map<String, Object?>>{};
    for (final Row row in rs) {
      final Object? props = _decodeProps(row['props_json'] as String?);
      nodes[row['id'] as String] = <String, Object?>{
        'id': row['id'] as String,
        'type': row['type'] as String,
        'data': props ?? const <String, Object?>{},
        'children': <Object?>[],
      };
    }
    final List<Object?> roots = <Object?>[];
    for (final Row row in rs) {
      final String id = row['id'] as String;
      final String? parentId = row['parent_id'] as String?;
      final Map<String, Object?> node = nodes[id]!;
      final Map<String, Object?>? parent = parentId == null ? null : nodes[parentId];
      if (parent == null) {
        roots.add(node); // 父节点缺失 ⇒ 顶到根，绝不丢块
      } else {
        (parent['children']! as List<Object?>).add(node);
      }
    }

    return jsonEncode(<String, Object?>{
      'v': 2,
      'format': _blocksFormat,
      'document': <String, Object?>{
        'id': 'root',
        'type': 'page',
        'children': <Object?>[for (final Object? r in roots) _toOut(r! as Map<String, Object?>)],
      },
    });
  }

  /// 还原成节点 JSON：**没有子节点就不要 `children` 键**
  /// （原始文档里叶子节点不带这个键，多写会让结构比较失败）。
  static Map<String, Object?> _toOut(Map<String, Object?> node) {
    final List<Object?> kids = (node['children']! as List<Object?>)
        .map((Object? c) => _toOut(c! as Map<String, Object?>))
        .toList(growable: false);
    return <String, Object?>{
      'id': node['id'],
      'type': node['type'],
      'data': node['data'],
      if (kids.isNotEmpty) 'children': kids,
    };
  }

  /// **校验**（迁移第 4 步）：把 blocks 还原成树，与 `notes.content` 里的
  /// 原始块树做**结构深比较**。
  ///
  /// 不做字节比较：JSON 对象的键顺序无语义，而我们的还原顺序未必与编辑器的
  /// 写出顺序一致（appflowy 的 `_nodeToJson` 是先 type/data 后 id）。
  /// **列表顺序有语义**（children 是数组），所以顺序仍然被严格比较。
  ///
  /// 返回 false 的常见情形：content 不是 v2（老格式）、blocks 还没回填、
  /// 或者两边真的不一致（切读前必须能拦住这种）。
  bool verifyNoteBlocks(String noteId, String content) =>
      readVerifiedDocument(noteId, content) != null;

  /// 「校验 + 取回」一次做完（[noteById] 用这个，避免读两遍）。
  ///
  /// 校验通过则返回还原出的整篇 JSON；否则返回 null，调用方回退旧列。
  String? readVerifiedDocument(String noteId, String content) {
    final Map<String, Object?>? original = _parseBlocksDocument(content);
    if (original == null) return null;

    final String? rebuiltJson = readNoteDocument(noteId);
    if (rebuiltJson == null) return null;

    Object? rebuilt;
    try {
      rebuilt = jsonDecode(rebuiltJson);
    } on FormatException {
      return null;
    }
    if (rebuilt is! Map<String, Object?>) return null;
    final Object? rebuiltDoc = rebuilt['document'];
    if (rebuiltDoc is! Map<String, Object?>) return null;

    return _deepEq(rebuiltDoc, original) ? rebuiltJson : null;
  }

  /// **回填**：把「内容是 v2 块树、但还没有 blocks 行」的笔记补上。
  ///
  /// 每次运行**最多处理 [limit] 篇**（默认 50）：
  /// - 存量库可能有很多篇，不该在启动路径上一次全做（卡顿 + 不可预测）；
  /// - 分批也因此**天然可续跑**：这次没做完，下次启动接着来；
  /// - 存量 Delta 笔记无法投影（不是 v2），会被跳过——它们每次都是候选，
  ///   所以必须有这个上限，否则永远在白扫描。
  /// - **画布笔记不进候选**（见下方 SQL 的 `kind != 'canvas'`）：它们的正文是画布
  ///   JSON、**永远**没有 blocks 行，否则每次启动都被选中并白解析一遍。
  ///
  /// 返回**成功投影的**篇数（不是候选数）：
  /// 非 v2 格式的笔记会被跳过且**不计数**——它们要等被编辑、写成块树后
  /// 才轮得到，于是每次启动都会重新成为候选（成本低：只读到 limit 篇为止）。
  int backfill({int limit = 50}) {
    final ResultSet rs = db.select(
      // ⚠️ `kind != 'canvas'`：判断候选的判据是"这篇还没有 blocks 行"，而画布
      // 笔记**永远**没有 blocks 行（正文是画布 JSON）⇒ 不加这个条件，它们每次启动
      // 都会被选中、解析一遍再跳过，白占 [limit] 名额：有 N 张画布就少回填 N 篇文档。
      //
      // 条件是**排除 canvas**，不是白名单 `kind = 'note'`：`spark`（新建笔记的默认
      // 形态）同样是块树文档，用白名单会把整类灵感卡片漏掉（测试两种 kind 都钉了）。
      'SELECT id, content FROM notes '
      "WHERE kind != 'canvas' "
      'AND NOT EXISTS (SELECT 1 FROM blocks WHERE note_id = notes.id) '
      'LIMIT ?',
      <Object?>[limit],
    );
    int done = 0;
    for (final Row row in rs) {
      final String content = row['content'] as String;
      // 先判格式：不是 v2 就不算"处理过"，下次还会再试（届时可能已被编辑成 v2）。
      if (_parseBlocksDocument(content) == null) continue;
      replaceNoteBlocks(row['id'] as String, content);
      done++;
    }
    return done;
  }

  // ── 内部 ──────────────────────────────────────────────────────────

  static Object? _decodeProps(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  /// 比较前先**归一化**：节点缺 `data` 键时补 `{}`。
  ///
  /// 投影侧总是写 `data`（默认 `{}`），而原始文档里个别节点可能压根没这个键；
  /// 不归一化的话这类笔记会永远校验失败、只能走回退分支。
  static Object? _normalize(Object? node) {
    if (node is List) return <Object?>[for (final Object? c in node) _normalize(c)];
    if (node is! Map) return node;
    return <Object?, Object?>{
      for (final MapEntry<Object?, Object?> e in node.entries)
        e.key: e.key == 'children' ? _normalize(e.value) : e.value,
      if (!node.containsKey('data')) 'data': const <String, Object?>{},
    };
  }

  /// 结构深比较：Map 按键比（顺序无关），List **按顺序**比。
  /// 归一化后交给**共用**的深比较（与 `CanvasStore` 同一份规则，见
  /// `json_deep_eq.dart`）。这里只保留块树特有的归一化（补 `data`、递归 `children`）。
  static bool _deepEq(Object? a, Object? b) =>
      jsonDeepEquals(_normalize(a), _normalize(b));

  /// 解析出 v2 块树的 document 节点；不是这个格式返回 null。
  static Map<String, Object?>? _parseBlocksDocument(String content) {
    if (content.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    if (decoded['format'] != _blocksFormat) return null;
    final Object? document = decoded['document'];
    return document is Map<String, Object?> ? document : null;
  }

  /// 前序遍历扁平化。**根节点不入表**（它只是文档容器，没有内容）。
  static List<_FlatBlock> _flatten(Map<String, Object?> root) {
    final List<_FlatBlock> out = <_FlatBlock>[];
    int ord = 0;

    void walk(Map<String, Object?> node, String? parentId) {
      final Object? children = node['children'];
      if (children is List) {
        for (final Object? child in children) {
          if (child is! Map<String, Object?>) continue;
          final String id = child['id'] is String
              ? child['id']! as String
              : 'gen_${out.length}_${ord ~/ ordStep}';
          final Object? data = child['data'];
          final String propsJson = data == null ? '{}' : jsonEncode(data);
          out.add(
            _FlatBlock(
              id: id,
              parentId: parentId,
              type: (child['type'] ?? 'unknown').toString(),
              propsJson: propsJson,
              ord: ord,
              fingerprint: contentFingerprint(
                '${child['type'] ?? 'unknown'}\n$propsJson',
              ),
            ),
          );
          ord += ordStep;
          walk(child, id); // 先记父、再递归子孙 ⇒ ord 即文档顺序
        }
      }
    }

    walk(root, null);
    return out;
  }

  Map<String, _Existing> _existingOf(String noteId) => <String, _Existing>{
        for (final Row r in db.select(
          'SELECT id, fingerprint, ord, parent_id FROM blocks WHERE note_id = ?',
          <Object?>[noteId],
        ))
          r['id'] as String: _Existing(
            r['fingerprint'] as String,
            r['ord'] as int,
            r['parent_id'] as String?,
          ),
      };

  /// 当前被画布卡片引用的全部 `block_id`（块可迁移 #5 用：这些块由画布托管，
  /// 即使不在任何文档块树里也不许在块投影里被删）。
  Set<String> _canvasReferencedBlockIds() {
    final ResultSet rs = db.select(
      'SELECT DISTINCT block_id FROM canvas_items WHERE block_id IS NOT NULL',
    );
    return <String>{for (final Row r in rs) r['block_id'] as String};
  }

  /// 指纹变了、或位置/父节点变了，才需要写。
  static bool _needsWrite(_FlatBlock b, _Existing? old) {
    if (old == null) return true;
    return old.fingerprint != b.fingerprint ||
        old.ord != b.ord ||
        old.parentId != b.parentId;
  }
}

/// 扁平化后的一个块（未落库）。
class _FlatBlock {
  const _FlatBlock({
    required this.id,
    required this.parentId,
    required this.type,
    required this.propsJson,
    required this.ord,
    required this.fingerprint,
  });

  final String id;
  final String? parentId;
  final String type;
  final String propsJson;
  final int ord;
  final String fingerprint;
}

/// 库里已有的块（用于判变）。
class _Existing {
  const _Existing(this.fingerprint, this.ord, this.parentId);

  final String fingerprint;
  final int ord;
  final String? parentId;
}
