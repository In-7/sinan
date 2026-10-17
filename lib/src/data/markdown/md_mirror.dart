import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show Database, ResultSet, Row, sqlite3;

import '../block_store.dart';
import 'block_serializer.dart';

/// Markdown **单向镜像**（2026-10-17 用户定）：权威在 `blocks` 表，磁盘 `.md`
/// 只是导出镜像（Obsidian 可直接打开）。
///
/// ## 三条规矩
/// 1. **只写不读**：用户手改过的 .md 不会被回收，下次保存即以库为准覆写——
///    不做双向合并（那是 Notion/Obsidian 都踩烂的坑）。
/// 2. **幂等可续**：`md_mirror` 侧表记每篇的导出路径 + 导出时的 `revised_at`，
///    扫描条件 = 比记录新（或无记录）。崩溃/重启后靠库状态自愈，不需要内存态。
/// 3. **可预期**：文件名 = 干净化的标题（撞名退 `<标题> <id8>.md`），标题改了就
///    删旧写新（等同改名）。
///
/// ## 不导的
/// - `canvas`：画布是空间排版，压成 Markdown 没有意义；
/// - `stream`：心流收件箱的系统隐藏容器，不该出现在用户文件系统里。
///
/// ## 引用 = wikilink
/// `ref` 块导出成 `[[文件名]]`（`ref_view='embed'` ⇒ `![[文件名]]`）：引用边本来
/// 就存在 `blocks`（`ref_type` / `ref_id`），反链读的是同一份数据
/// （`NoteStore.backlinks`）。导出只是把它**投影**成 Obsidian 认得的语法——
/// 不解析正文、不建链接表、不做双向合并。
///
/// ## 已知取舍
/// 用户手动删掉的 .md **不会**自动重建（避免"删了又冒出来"）；想全量重生只能
/// 让笔记重新保存（revised_at 变新）。真需要"全量重导"再加按钮。
class MdMirror {
  MdMirror(this.db);

  final Database db;

  /// 解析导出目录：用户显式选过就用它，否则落在应用数据目录的 `markdown-mirror`。
  static String resolveDir(String appDataDir, String overrideDir) =>
      overrideDir.trim().isNotEmpty
      ? overrideDir.trim()
      : p.join(appDataDir, 'markdown-mirror');

  /// 扫描并导出所有"比导出记录新"的笔记，返回本次写出的篇数。
  int exportPending({required String dir}) {
    final List<String> ids = db
        .select(
          '''
          SELECT n.id FROM notes n
          LEFT JOIN md_mirror m ON m.note_id = n.id
          WHERE n.deleted_at IS NULL
            AND n.kind IN ('spark', 'note')
            AND (m.note_id IS NULL OR n.revised_at > m.revised_at)
          ORDER BY n.revised_at ASC''',
        )
        .map((Row r) => r['id'] as String)
        .toList(growable: false);
    int done = 0;
    for (final String id in ids) {
      try {
        if (exportOne(id, dir: dir)) done++;
      } on Object {
        // 单篇失败（磁盘满 / 文件被占用 / 权限）不拖垮整轮：下个周期再试。
      }
    }
    return done;
  }

  /// **全量**导出（无视 `revised_at`）：换了导出目录、或用户点「立即导出」时用。
  ///
  /// 与 [exportPending] 的差别只有"选哪些笔记"——都走 [exportOne]，因此改名 /
  /// 撞名 / 删旧文件那套规矩完全一致（换目录时旧目录里的文件会被顺手删掉，
  /// 因为账本里记的还是旧路径）。
  int exportAll({required String dir}) {
    final List<String> ids = db
        .select(
          'SELECT id FROM notes WHERE deleted_at IS NULL '
          "AND kind IN ('spark', 'note') ORDER BY revised_at ASC",
        )
        .map((Row r) => r['id'] as String)
        .toList(growable: false);
    int done = 0;
    for (final String id in ids) {
      try {
        if (exportOne(id, dir: dir)) done++;
      } on Object {
        // 同 exportPending：单篇失败不拖垮整轮。
      }
    }
    return done;
  }

  /// 导出单篇，返回是否写了文件（笔记不存在 / 是不该导的形态 ⇒ false）。
  bool exportOne(String noteId, {required String dir}) {
    final ResultSet rows = db.select(
      'SELECT title, created_at, revised_at, plain_text, kind FROM notes '
      'WHERE id = ? AND deleted_at IS NULL',
      <Object?>[noteId],
    );
    if (rows.isEmpty) return false;
    final Row note = rows.first;
    final String kind = (note['kind'] as String?) ?? '';
    if (kind != 'spark' && kind != 'note') return false;

    final String title = (note['title'] as String?) ?? '';
    final int createdAt = (note['created_at'] as int?) ?? 0;
    final int revisedAt = (note['revised_at'] as int?) ?? 0;
    final Map<String, Object?>? document = _documentOf(noteId);
    final String markdown = noteToMarkdown(
      noteId: noteId,
      title: title,
      createdAt: createdAt,
      revisedAt: revisedAt,
      document: document,
      // 存量 Delta 笔记（没有块行）：用快照清洗列兜底，文本不丢。
      plainFallback: (note['plain_text'] as String?) ?? '',
      // 引用块 → `[[文件名]]`：边本来就在库里（`ref` 块的 ref_type/ref_id），
      // 导出只是把它投影成 Obsidian 能认的 wikilink，不解析正文、不建表。
      refLink: _refLinker(),
    );

    final String target = _desiredPath(dir: dir, noteId: noteId, title: title);
    _dropStaleFile(noteId, target);
    final File f = File(target);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(markdown, flush: true);
    db.execute(
      'INSERT INTO md_mirror (note_id, path, revised_at) VALUES (?, ?, ?) '
      'ON CONFLICT(note_id) DO UPDATE SET '
      'path = excluded.path, revised_at = excluded.revised_at',
      <Object?>[noteId, target, revisedAt],
    );
    return true;
  }

  /// 笔记**删除前**调：清掉镜像文件（`md_mirror` 行由 CASCADE 清，文件它管不到）。
  void removeForNote(String noteId) {
    final ResultSet rows = db.select(
      'SELECT path FROM md_mirror WHERE note_id = ?',
      <Object?>[noteId],
    );
    if (rows.isEmpty) return;
    _deleteFile(rows.first['path'] as String);
  }

  // ─────────────────────────── 内部 ───────────────────────────

  /// 引用块解析器（**导出本篇期间**带缓存：同一目标可能被引用多次）。
  ///
  /// 口径与编辑器 `_resolveRefTarget` 一致：块引用（`ref_type='block'`）显示
  /// 它**所属笔记**的标题（块级定位在编辑里也还没做）。
  MdRefLink? Function(String, String) _refLinker() {
    final Map<String, MdRefLink?> cache = <String, MdRefLink?>{};
    return (String refType, String refId) {
      final String key = '$refType:$refId';
      if (cache.containsKey(key)) return cache[key];
      final MdRefLink? link = _resolveRef(refType, refId);
      cache[key] = link;
      return link;
    };
  }

  MdRefLink? _resolveRef(String refType, String refId) {
    if (refId.isEmpty) return null;
    // 速记（心流）没有镜像文件 ⇒ 落纯文本，不往 Obsidian 图谱里塞死链。
    if (refType == 'stream') {
      final ResultSet rs = db.select(
        'SELECT text FROM stream_items WHERE id = ?',
        <Object?>[refId],
      );
      if (rs.isEmpty) return null;
      final String text = ((rs.first['text'] as String?) ?? '').trim();
      final String first = text.split('\n').first.trim();
      final String label = first.length <= 24
          ? first
          : '${first.substring(0, 24)}…';
      return MdRefLink('速记：${label.isEmpty ? '（空）' : label}', linked: false);
    }
    final ResultSet rs = refType == 'block'
        ? db.select(
            'SELECT n.title AS title, n.kind AS kind FROM blocks b '
            'JOIN notes n ON n.id = b.note_id '
            'WHERE b.id = ? AND n.deleted_at IS NULL',
            <Object?>[refId],
          )
        : db.select(
            'SELECT title, kind FROM notes WHERE id = ? AND deleted_at IS NULL',
            <Object?>[refId],
          );
    if (rs.isEmpty) return null;
    final Row r = rs.first;
    final String title = ((r['title'] as String?) ?? '').trim();
    final String kind = (r['kind'] as String?) ?? '';
    // 有镜像文件的形态：链接目标必须**等于文件名**（`_slug`），否则 Obsidian
    // 解析不到（标题里的 `/ : *` 在文件名里已被消毒）。
    if (kind == 'note' || kind == 'spark') return MdRefLink(_slug(title));
    // 画布 / 心流没有 .md：写纯文本并标出形态，避免在 Obsidian 里长出死链节点。
    final String label = title.isEmpty ? '未命名笔记' : title;
    return MdRefLink('$label（${kind == 'canvas' ? '画布' : '心流'}）', linked: false);
  }

  /// 块树（v2 文档 JSON 里的 `document` 节点）；无块行 ⇒ null（走纯文本兜底）。
  Map<String, Object?>? _documentOf(String noteId) {
    final String? json = BlockStore(db).readNoteDocument(noteId);
    if (json == null) return null;
    final Object? decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    final Object? doc = decoded['document'];
    return doc is Map<String, Object?> ? doc : null;
  }

  /// 目标路径：`<slug>.md`；被**别的**笔记占用时退 `<slug> <id8>.md`。
  String _desiredPath({
    required String dir,
    required String noteId,
    required String title,
  }) {
    final String slug = _slug(title);
    final String plain = p.join(dir, '$slug.md');
    final ResultSet owner = db.select(
      'SELECT note_id FROM md_mirror WHERE path = ?',
      <Object?>[plain],
    );
    if (owner.isEmpty || owner.first['note_id'] == noteId) return plain;
    return p.join(dir, '$slug ${noteId.substring(0, 8)}.md');
  }

  /// 标题改过（目标路径 ≠ 上次路径）⇒ 删旧文件，等同改名。
  void _dropStaleFile(String noteId, String target) {
    final ResultSet prev = db.select(
      'SELECT path FROM md_mirror WHERE note_id = ?',
      <Object?>[noteId],
    );
    if (prev.isEmpty) return;
    final String old = prev.first['path'] as String;
    if (old != target) _deleteFile(old);
  }

  void _deleteFile(String path) {
    try {
      final File f = File(path);
      if (f.existsSync()) f.deleteSync();
    } on Object {
      // 被占用 / 无权限：留给用户，不阻断主流程。
    }
  }

  // ── 后台导出（UI 线程不碰解析 / 写盘）────────────────────────────────

  /// 上一次后台导出的 Future：**串行化**队列——连点「立即导出」不会两个 isolate
  /// 同时写同一批文件（后一次等前一次收尾）。
  static Future<int> _serial = Future<int>.value(0);

  /// 在后台 isolate 跑一轮导出，返回写出的篇数。
  ///
  /// 为什么另开连接：`sqlite3` 的 `Database` 句柄**绑定创建它的 isolate**，不能
  /// 直接跨 isolate 传（与 `runStartupBackfill` 同一手法）。WAL + `busy_timeout`
  /// 让第二连接与主连接并行读写。
  ///
  /// [all] = true 时无视 `revised_at` 全量重写（换目录 / 手动触发）。
  static Future<int> exportPendingInBackground({
    required String dbPath,
    required String dir,
    bool all = false,
  }) {
    final Future<int> run = _serial.then(
      (int _) => Isolate.run<int>(() {
        final Database worker = sqlite3.open(dbPath);
        try {
          final MdMirror mirror = MdMirror(worker);
          return all
              ? mirror.exportAll(dir: dir)
              : mirror.exportPending(dir: dir);
        } finally {
          worker.close();
        }
      }),
    );
    // 队列自身吞错：一次失败不该卡住后续任务（[run] 本身仍会把错误抛给调用方）。
    _serial = run.catchError((Object _) => 0);
    return run;
  }

  /// 标题 → 文件名：去 Windows 非法字符与控制符，压空白，去结尾点/空格，
  /// 上限 60 字（给 id8 后缀与路径留余量）；空标题落「未命名」。
  static String _slug(String title) {
    String s = title.trim();
    if (s.isEmpty) return '未命名';
    s = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
    if (s.isEmpty) return '未命名';
    if (s.length > 60) s = s.substring(0, 60).trim();
    return s;
  }
}
