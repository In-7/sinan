import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../domain/note.dart';

/// 灵感的**唯一**读写入口（2026-10-17 用户定：灵感独立存储）。
///
/// ## 为什么不再借笔记的壳
/// v16 之前灵感是"一篇隐藏笔记（`kind='stream'`）+ 一串段落块"，代价是：
/// - 文库 / 搜索 / 索引 / 日历 / 收藏 / Markdown 镜像**每处都要为它写一条
///   "排除隐藏容器"的特例**，漏一处就漏一次；
/// - 每条灵感都是 `blocks` 的一行，会被块选择器、反链上下文当成"笔记的块"看到；
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

  /// 表 DDL：独立表，无外键。
  /// `archived_at` 非空 = 已处理（不删，可回看）；`deleted_at` 非空 = 在回收站。
  static const String ddl = '''
    CREATE TABLE IF NOT EXISTS $table (
      id          TEXT PRIMARY KEY,
      text        TEXT NOT NULL,
      created_at  INTEGER NOT NULL,
      updated_at  INTEGER NOT NULL,
      archived_at INTEGER,
      deleted_at  INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_stream_items_created
      ON $table (created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_stream_items_open
      ON $table (archived_at) WHERE archived_at IS NULL;
    CREATE INDEX IF NOT EXISTS idx_stream_items_trash
      ON $table (deleted_at) WHERE deleted_at IS NOT NULL;
  ''';

  /// 列表：**最新在上**（灵感是流，时间序即语义）。
  ///
  /// [includeArchived] 为 false（默认）时只给「待处理」区；归档区单独读，
  /// 免得处理过的旧想法混在眼前干扰回看。
  List<StreamItem> list({bool includeArchived = false}) {
    final String where = includeArchived
        ? 'WHERE deleted_at IS NULL '
        : 'WHERE deleted_at IS NULL AND archived_at IS NULL ';
    final ResultSet rs = db.select(
      'SELECT id, text, created_at, updated_at, archived_at, deleted_at '
      'FROM $table $where'
      // 同一毫秒连记两条时按插入顺序兜底（rowid），否则两次读取顺序会翻。
      'ORDER BY created_at DESC, rowid DESC',
    );
    return <StreamItem>[for (final Row r in rs) _itemOf(r)];
  }

  /// 回收站：已软删的条目，按删除时间倒序。
  List<StreamItem> listTrash() {
    final ResultSet rs = db.select(
      'SELECT id, text, created_at, updated_at, archived_at, deleted_at '
      'FROM $table WHERE deleted_at IS NOT NULL '
      'ORDER BY deleted_at DESC, rowid DESC',
    );
    return <StreamItem>[for (final Row r in rs) _itemOf(r)];
  }

  StreamItem? byId(String id) {
    final ResultSet rs = db.select(
      'SELECT id, text, created_at, updated_at, archived_at, deleted_at '
      'FROM $table WHERE id = ? AND deleted_at IS NULL',
      <Object?>[id],
    );
    return rs.isEmpty ? null : _itemOf(rs.first);
  }

  /// 文本（引用块 / 画布复制 / Markdown 镜像的读口）。条目不存在返回 null。
  String? textOf(String id) => byId(id)?.text;

  /// 新增一条。
  ///
  /// 普通录入要求非空文本；[allowEmpty] 为 true 时允许空文本（仅当带着附件，
  /// 用于"只有一张图、没写字的灵感"）。两种情况都拒绝"既没有字也没有附件"。
  StreamItem? add(String text, {bool allowEmpty = false}) {
    final String t = text.trim();
    if (t.isEmpty && !allowEmpty) return null;
    final DateTime now = DateTime.now();
    final String id = _uuid.v4();
    db.execute(
      'INSERT INTO $table (id, text, created_at, updated_at) VALUES (?, ?, ?, ?)',
      <Object?>[id, t, now.millisecondsSinceEpoch, now.millisecondsSinceEpoch],
    );
    return StreamItem(id: id, text: t, createdAt: now);
  }

  /// 新增一条附件（UI 已把文件**拷进 app 私有目录**，这里只落元数据）。
  ///
  /// [path] 是那份独立副本的绝对路径；源截图被删也不影响（见 [remove] 的级联）。
  /// 返回新附件 id。
  String addAttachment({
    required String streamId,
    required String kind,
    required String path,
    int? width,
    int? height,
    int? durationMs,
  }) {
    final String id = _uuid.v4();
    final int now = DateTime.now().millisecondsSinceEpoch;
    // sort 用"当前已几条"自增：同条目并发极少，足够稳；不依赖 rowid 以防中间删过。
    final int sort = attachmentsOf(streamId).length;
    db.execute(
      'INSERT INTO stream_attachments '
      '(id, stream_id, kind, path, width, height, duration_ms, sort, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        id,
        streamId,
        kind,
        path,
        _zeroToNull(width),
        _zeroToNull(height),
        durationMs,
        sort,
        now,
      ],
    );
    return id;
  }

  /// 某条灵感的全部附件（按展示顺序升序）。
  List<StreamAttachment> attachmentsOf(String streamId) {
    final ResultSet rs = db.select(
      'SELECT id, stream_id, kind, path, width, height, duration_ms, sort, '
      'created_at FROM stream_attachments WHERE stream_id = ? ORDER BY sort ASC',
      <Object?>[streamId],
    );
    return <StreamAttachment>[for (final Row r in rs) _attachmentOf(r)];
  }

  StreamAttachment _attachmentOf(Row r) => StreamAttachment(
        id: r['id'] as String,
        streamId: r['stream_id'] as String,
        kind: r['kind'] as String,
        path: r['path'] as String,
        width: _zeroToNull(r['width'] as int?),
        height: _zeroToNull(r['height'] as int?),
        durationMs: r['duration_ms'] as int?,
        sort: r['sort'] as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );

  /// 全是 0 / null 时按"无尺寸"处理（避免存 0 误判成 0px）。
  static int? _zeroToNull(int? v) => v == null || v <= 0 ? null : v;

  /// 启动时兜底：删掉"盘上有文件、库里没记录"的孤儿。
  ///
  /// 仅在 [mediaDir] 存在时扫一遍；导入中途崩溃可能留下没对应 DB 行的副本，
  /// 这里清掉，避免占用空间、也避免下次同名拷贝冲突。
  static void sweepOrphans(Database db, String mediaDir) {
    final Directory dir = Directory(mediaDir);
    if (!dir.existsSync()) return;
    final ResultSet rs = db.select('SELECT path FROM stream_attachments');
    // 统一分隔符再比：存的路径与 `listSync` 返回的在 Windows 上可能 `/`、`\` 混用，
    // 直接字符串比对会漏判"已知文件"而误删（2026-10-18 修）。不引第三方 path 包，
    // 用 [Platform.pathSeparator] 就地归一（保持 StreamStore 依赖白名单纯净）。
    final String sep = Platform.pathSeparator;
    String norm(String p) => p.replaceAll('/', sep).replaceAll('\\', sep);
    final Set<String> known = <String>{
      for (final Row r in rs) norm(r['path'] as String),
    };
    for (final FileSystemEntity e in dir.listSync()) {
      if (e is File && !known.contains(norm(e.path))) {
        try {
          e.deleteSync();
        } on Object {
          // 锁住 / 权限问题：忽略，下次启动再试。
        }
      }
    }
  }

  /// 改文本（不改创建时间 —— 灵感的位置由"记下来的时刻"决定）。没这条返回 false。
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

  /// 软删（进回收站）：列表不再显示，可在回收站恢复或彻底删除。
  bool trash(String id) {
    db.execute(
      'UPDATE $table SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL',
      <Object?>[DateTime.now().millisecondsSinceEpoch, id],
    );
    return db.updatedRows > 0;
  }

  /// 批量软删（多选删除）。
  bool trashMany(Iterable<String> ids) {
    final List<String> list = ids.toList(growable: false);
    if (list.isEmpty) return false;
    final String marks = List<String>.filled(list.length, '?').join(',');
    db.execute(
      'UPDATE $table SET deleted_at = ? '
      'WHERE id IN ($marks) AND deleted_at IS NULL',
      <Object?>[DateTime.now().millisecondsSinceEpoch, ...list],
    );
    return db.updatedRows > 0;
  }

  /// 从回收站恢复（回到原状态：待处理 / 已处理）。
  bool restore(String id) {
    db.execute(
      'UPDATE $table SET deleted_at = NULL '
      'WHERE id = ? AND deleted_at IS NOT NULL',
      <Object?>[id],
    );
    return db.updatedRows > 0;
  }

  /// 批量彻底删除（回收站「清空」）：先删附件文件，再删附件行与灵感行。
  bool removeMany(Iterable<String> ids) {
    final List<String> list = ids.toList(growable: false);
    if (list.isEmpty) return false;
    final String marks = List<String>.filled(list.length, '?').join(',');
    final ResultSet rs = db.select(
      'SELECT path FROM stream_attachments WHERE stream_id IN ($marks)',
      list,
    );
    final List<String> files = <String>[
      for (final Row r in rs) r['path'] as String,
    ];
    db.execute(
      'DELETE FROM stream_attachments WHERE stream_id IN ($marks)',
      list,
    );
    db.execute('DELETE FROM $table WHERE id IN ($marks)', list);
    final bool removed = db.updatedRows > 0;
    for (final String f in files) {
      try {
        File(f).deleteSync();
      } on Object {
        // 副本已经不在了：忽略。
      }
    }
    return removed;
  }

  /// 彻底删除回收站里超过 [maxAge] 的灵感（30 天自动清理）。返回条数。
  bool purgeExpired(Duration maxAge) {
    final int cutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    final ResultSet rs = db.select(
      'SELECT id FROM $table WHERE deleted_at IS NOT NULL AND deleted_at < ?',
      <Object?>[cutoff],
    );
    final List<String> ids = <String>[for (final Row r in rs) r['id'] as String];
    return removeMany(ids);
  }

  /// 真删（用户显式点删除，不可撤销）。
  ///
  /// **级联删文件**：先把这条的附件文件从 app 私有目录删掉，再清附件行与灵感行。
  /// 源文件早被用户删了也没关系——`deleteSync` 失败只当"已经没了"，不挡删除。
  bool remove(String id) {
    final List<StreamAttachment> files = attachmentsOf(id);
    db.execute(
      'DELETE FROM stream_attachments WHERE stream_id = ?',
      <Object?>[id],
    );
    db.execute('DELETE FROM $table WHERE id = ?', <Object?>[id]);
    final bool removed = db.updatedRows > 0;
    for (final StreamAttachment a in files) {
      try {
        File(a.path).deleteSync();
      } on Object {
        // 副本已经不在了（拷一半崩溃 / 手动清理过）：忽略。
      }
    }
    return removed;
  }

  StreamItem _itemOf(Row r) => StreamItem(
    id: r['id'] as String,
    text: r['text'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
    archivedAt: r['archived_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['archived_at'] as int),
    deletedAt: r['deleted_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['deleted_at'] as int),
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
