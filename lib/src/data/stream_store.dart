import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../domain/note.dart';

/// 速记 / 心流的**唯一**读写入口（2026-10-17 用户定：心流独立存储）。
///
/// ## 为什么不再借笔记的壳
/// v16 之前心流是"一篇隐藏笔记（`kind='stream'`）+ 一串段落块"，代价是：
/// - 文库 / 搜索 / 索引 / 日历 / 收藏 / Markdown 镜像**每处都要为它写一条
///   "排除隐藏容器"的特例**，漏一处就漏一次；
/// - 每条速记都是 `blocks` 的一行，会被块选择器、反链上下文当成"笔记的块"看到；
/// - 编辑一条要重写整个容器并全量重投影（O(N) 写放大）。
///
/// 现在它是独立表 [table]：与 `notes` / `blocks` **无外键、无反向读写**，
/// 下游（笔记 / 画布）只能经 `NoteStore` 的导出方法**单向**取用。
///
/// ## 单向契约
/// 本类**只碰 [table]**：不 import 笔记 / 画布的任何 store，也不查它们的表。
/// 引用方（笔记里的 `ref` 块）由对方单向读取本表，本表永不回读。
class StreamStore {
  StreamStore(this.db);

  final Database db;

  static const Uuid _uuid = Uuid();

  /// 表名（迁移与测试共用，避免字符串漂移）。
  static const String table = 'stream_items';

  /// 表 DDL：独立表，无外键。`archived_at` 非空 = 已处理（不删，可回看）。
  static const String ddl = '''
    CREATE TABLE IF NOT EXISTS $table (
      id          TEXT PRIMARY KEY,
      text        TEXT NOT NULL,
      created_at  INTEGER NOT NULL,
      updated_at  INTEGER NOT NULL,
      archived_at INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_stream_items_created
      ON $table (created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_stream_items_open
      ON $table (archived_at) WHERE archived_at IS NULL;
  ''';

  /// 列表：**最新在上**（速记是流，时间序即语义）。
  ///
  /// [includeArchived] 为 false（默认）时只给「待处理」区；归档区单独读，
  /// 免得处理过的旧想法混在眼前干扰回看。
  List<StreamItem> list({bool includeArchived = false}) {
    final ResultSet rs = db.select(
      'SELECT id, text, created_at, updated_at, archived_at FROM $table '
      '${includeArchived ? '' : 'WHERE archived_at IS NULL '}'
      // 同一毫秒连记两条时按插入顺序兜底（rowid），否则两次读取顺序会翻。
      'ORDER BY created_at DESC, rowid DESC',
    );
    return <StreamItem>[for (final Row r in rs) _itemOf(r)];
  }

  StreamItem? byId(String id) {
    final ResultSet rs = db.select(
      'SELECT id, text, created_at, updated_at, archived_at FROM $table '
      'WHERE id = ?',
      <Object?>[id],
    );
    return rs.isEmpty ? null : _itemOf(rs.first);
  }

  /// 文本（引用块 / 画布复制 / Markdown 镜像的读口）。条目不存在返回 null。
  String? textOf(String id) => byId(id)?.text;

  /// 新增一条（空白文本拒绝，返回 null —— 速记不该落空卡）。
  StreamItem? add(String text) {
    final String t = text.trim();
    if (t.isEmpty) return null;
    final DateTime now = DateTime.now();
    final String id = _uuid.v4();
    db.execute(
      'INSERT INTO $table (id, text, created_at, updated_at) VALUES (?, ?, ?, ?)',
      <Object?>[id, t, now.millisecondsSinceEpoch, now.millisecondsSinceEpoch],
    );
    return StreamItem(id: id, text: t, createdAt: now);
  }

  /// 改文本（不改创建时间 —— 速记的位置由"记下来的时刻"决定）。没这条返回 false。
  bool update(String id, String text) {
    final String t = text.trim();
    if (t.isEmpty) return false;
    final int changed = db
        .select('SELECT 1 FROM $table WHERE id = ?', <Object?>[id])
        .length;
    if (changed == 0) return false;
    db.execute(
      'UPDATE $table SET text = ?, updated_at = ? WHERE id = ?',
      <Object?>[t, DateTime.now().millisecondsSinceEpoch, id],
    );
    return true;
  }

  /// 归档（已处理）：文本保留、可回看，**不删除**。
  bool archive(String id) {
    db.execute(
      'UPDATE $table SET archived_at = ? WHERE id = ? AND archived_at IS NULL',
      <Object?>[DateTime.now().millisecondsSinceEpoch, id],
    );
    // `updatedRows` = 上一条语句改动的行数（sqlite3_changes）。
    return db.updatedRows > 0;
  }

  /// 从归档里拿回「待处理」。
  bool unarchive(String id) {
    db.execute(
      'UPDATE $table SET archived_at = NULL WHERE id = ? AND archived_at IS NOT NULL',
      <Object?>[id],
    );
    return db.updatedRows > 0;
  }

  /// 真删（用户显式点删除，不可撤销）。
  bool remove(String id) {
    db.execute('DELETE FROM $table WHERE id = ?', <Object?>[id]);
    return db.updatedRows > 0;
  }

  StreamItem _itemOf(Row r) => StreamItem(
    id: r['id'] as String,
    text: r['text'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
    archivedAt: r['archived_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['archived_at'] as int),
  );

  /// 供导出 / 测试使用：把文本按行拆成段落（转新笔记的正文口径）。
  static List<String> linesOf(String text) {
    final List<String> lines = text.split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return lines.isEmpty ? <String>[''] : lines;
  }

  /// 文本 → v2 块树（数据层不 import 编辑器层，故在此自持一份编码）。
  static String blocksTreeFromText(String text) {
    final List<Object?> children = <Object?>[
      for (final String line in linesOf(text))
        <String, Object?>{
          'id': _uuid.v4(),
          'type': 'paragraph',
          'data': <String, Object?>{
            'delta': <Object?>[
              <String, Object?>{'insert': line},
            ],
            // 同时写 `text`：数据层的 blockText / 画布快照 / 反链上下文读它。
            'text': line,
          },
        },
    ];
    return jsonEncode(<String, Object?>{
      'v': 2,
      'format': 'blocks',
      'document': <String, Object?>{'type': 'page', 'children': children},
    });
  }
}
