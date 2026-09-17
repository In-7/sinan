import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../domain/note.dart';
import 'block_store.dart';
import 'canvas_store.dart';
import 'fingerprint.dart';

/// 笔记的读写入口：CRUD。
///
/// 保存正文内部做**指纹判变**（见 [contentFingerprint]，已不是 SHA-256）：
/// 内容没变就一行都不写，revised_at 也不会被无谓刷新。
///
/// ⚠️ **当前处于 v7 的双写阶段**（`docs/data_layer.md` 迁移第 2、3 步）：
/// 写路径同时维护 `notes.content`（旧，读路径仍在用）与 `blocks`（新），
/// 前者仍是真相源。切读与删旧列分别是第 5、6 步。
class NoteStore {
  NoteStore(this.db);

  final Database db;

  static const Uuid _uuid = Uuid();

  BlockStore get _blocks => BlockStore(db);

  /// 画布落点的投影（表见 `docs/canvas_architecture.md` 第七章）。
  /// 与 [_blocks] 对称：两条投影**各自带格式门闩**，所以调用方无脑两个都调即可。
  CanvasStore get _canvas => CanvasStore(db);

  /// 新建一条笔记（默认灵感卡片）。标题/正文可为空。
  Note create({NoteKind kind = NoteKind.spark, String title = '', String content = ''}) {
    final String id = _uuid.v4();
    final DateTime now = DateTime.now();
    final String hash = contentFingerprint(content);
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, created_at, revised_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      <Object?>[id, kind.name, title, content, hash, now.millisecondsSinceEpoch, now.millisecondsSinceEpoch],
    );
    _blocks.replaceNoteBlocks(id, content);
    _canvas.replaceCanvasRows(id, content);
    return Note(
      id: id,
      kind: kind,
      title: title,
      content: content,
      plainText: content,
      contentHash: hash,
      createdAt: now,
      revisedAt: now,
    );
  }

  /// 保存正文。content 的格式**由当前编辑器决定**（quill 时期是 Delta，
  /// 换成 appflowy 后是 v2 块树；详见 NoteDocumentAdapter）——本层不关心
  /// 格式，只存字符串。plainText 同步入库（列表预览 / Tooltip / 搜索用）。
  /// 内部哈希判变：内容没变则不写。
  ///
  /// 返回是否真的落了盘——调用方可据此跳过状态刷新（连快照都不用换）。
  Future<bool> updateContent(
    String noteId,
    String content, {
    required String plainText,
  }) async {
    final ResultSet exists = db.select(
      'SELECT content_hash FROM notes WHERE id = ?',
      <Object?>[noteId],
    );
    if (exists.isEmpty) return false;

    // 哈希判变：同步算。指纹便宜到不占 UI 帧（977K 字符 ≈ 0.8ms，见
    // [contentFingerprint]），也就不需要为此新建 isolate（省掉它的堆与
    // 冷启动，还有整篇内容的跨 isolate 拷贝）。
    final String currentHash = exists.first['content_hash'] as String;
    final String hash = contentFingerprint(content);
    if (currentHash == hash) return false; // 没改，直接返回，不落盘

    final DateTime now = DateTime.now();
    db.execute(
      'UPDATE notes SET content = ?, plain_text = ?, content_hash = ?, revised_at = ? WHERE id = ?',
      <Object?>[content, plainText, hash, now.millisecondsSinceEpoch, noteId],
    );
    // 双写：把新的块树投影进 blocks（旧列仍是真相源，见 [BlockStore]）。
    // 画布同理投影进 canvas_items / canvas_meta / ink_shards（见 [CanvasStore]）——
    // 两条投影各有格式门闩，与 kind 无关，谁不匹配谁返回 0。
    _blocks.replaceNoteBlocks(noteId, content);
    _canvas.replaceCanvasRows(noteId, content);
    return true;
  }

  /// 保存标题。短字段直接更新；revised_at 一并刷新（影响列表排序）。
  Future<void> updateTitle(String noteId, String title) async {
    final DateTime now = DateTime.now();
    db.execute(
      'UPDATE notes SET title = ?, revised_at = ? WHERE id = ?',
      <Object?>[title, now.millisecondsSinceEpoch, noteId],
    );
  }

  /// 全部笔记（**列表快照，不含正文**）：**收藏的排在最前**（按收藏时间
  /// 倒序），其余按最近修改倒序。
  ///
  /// ⚠️ 查询刻意**不带 `content` 列**：正文是块树 JSON，单篇可达几百 KB，
  /// 全表读入是保存热路径最贵的一步。列表只需要元数据（标题/时间/纯文本
  /// 摘要）；正文按 id 单行另取，见 [noteById]。
  ///
  /// 用 `promoted_at IS NULL` 做分组键（SQLite 里 false=0 排在 true=1 前）。
  /// 收藏项内部不跟着 revised_at 走：否则编辑一条收藏会把它的位置也抖一下。
  ///
  /// ⚠️ 排序键末尾必须带**兜底键**：时间戳是**毫秒**精度，同毫秒创建/修改的
  /// 两条会并列（用户快速连点「新建」、或程序化批量建笔记时很常见）。并列且
  /// 无兜底键时，SQLite 的返回顺序取决于扫描顺序——同一份数据在不同刷新之间
  /// 都可能换序，列表会莫名跳动。兜底链：`created_at DESC`（后建的在前，
  /// 与"最近修改倒序"的直觉一致）→ `id ASC`（id 唯一 ⇒ 全序，一定稳定）。
  List<Note> allNotes() {
    final ResultSet rs = db.select(
      'SELECT id, kind, title, plain_text, content_hash, '
      'created_at, revised_at, promoted_at FROM notes '
      'ORDER BY (promoted_at IS NULL) ASC, promoted_at DESC, '
      'revised_at DESC, created_at DESC, id ASC',
    );
    return <Note>[for (final Map<String, Object?> row in rs) _noteFrom(row)];
  }

  /// 所有**画布**笔记的正文（画布 JSON 原文）。
  ///
  /// 用途是**媒体引用扫描**：画布里的图片与 AI 生成层把本地路径写在 JSON 里
  /// （`items[].src`），判断"某个媒体文件是否仍被引用"只需读这些文本。
  ///
  /// 为什么不复用 [allNotes]：后者刻意不背正文（列表快照只带 id/标题/时间）。
  /// 这里单开一个窄查询，只取 `kind='canvas'` 的那几行正文。
  List<String> canvasContents() {
    final ResultSet rs = db.select(
      'SELECT content FROM notes WHERE kind = ?',
      <Object?>[NoteKind.canvas.name],
    );
    return <String>[
      for (final Map<String, Object?> row in rs)
        row['content'] as String? ?? '',
    ];
  }

  /// 按 id 取**完整**笔记（含正文）。编辑器打开笔记时用它拿正文——
  /// 列表快照不背正文（见 [allNotes]）。不存在时返回 null。
  ///
  /// ## 迁移第 5 步：**切读（带降落伞）**
  /// 正文**优先从 `blocks` 还原**，但只有在**校验通过**时才采用；否则
  /// 静默回退到旧的 `notes.content`。这样任何还原偏差都不会让用户看到
  /// 内容丢失——最坏情况是"还没切过去"，而不是"切坏了"。
  /// 等 v8 删掉旧列时，这个回退才一并移除。
  Note? noteById(String id) {
    final ResultSet rs = db.select(
      'SELECT * FROM notes WHERE id = ?',
      <Object?>[id],
    );
    if (rs.isEmpty) return null;

    final Row row = rs.first;
    final String legacy = row['content'] as String? ?? '';
    final String? rebuilt = _blocks.readVerifiedDocument(id, legacy);
    return _noteFrom(row, content: rebuilt ?? legacy);
  }

  /// 收藏 / 取消收藏（`promoted_at` 同时充当"是否收藏"与"收藏时间"）。
  ///
  /// 不动 revised_at：收藏是整理动作，不是内容修改，不该影响"最近修改"。
  Future<void> setPromoted(String noteId, bool promoted) async {
    db.execute(
      'UPDATE notes SET promoted_at = ? WHERE id = ?',
      <Object?>[promoted ? DateTime.now().millisecondsSinceEpoch : null, noteId],
    );
  }

  Future<void> delete(String noteId) async {
    db.execute('DELETE FROM notes WHERE id = ?', <Object?>[noteId]);
  }

  /// 把一条笔记**原样**写回（删除后的「撤销」用）。
  ///
  /// 与 [create] 的区别：id / created_at / revised_at / promoted_at 全部
  /// 保留——撤销的意义就是"回到删之前的状态"，不是新建一条相似的。
  /// 用 `INSERT OR REPLACE`：目标 id 已存在时覆盖（幂等，重复撤销不炸）。
  Future<void> restore(Note note) async {
    db.execute(
      'INSERT OR REPLACE INTO notes '
      '(id, kind, title, content, plain_text, content_hash, created_at, revised_at, promoted_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        note.id,
        note.kind.name,
        note.title,
        note.content,
        note.plainText,
        note.contentHash,
        note.createdAt.millisecondsSinceEpoch,
        note.revisedAt.millisecondsSinceEpoch,
        note.promotedAt?.millisecondsSinceEpoch,
      ],
    );
    _blocks.replaceNoteBlocks(note.id, note.content);
    _canvas.replaceCanvasRows(note.id, note.content);
  }

  /// **回填**（迁移第 3 步）：把「内容是 v2 块树但还没有 blocks 行」的存量
  /// 笔记补进 `blocks`。建议在启动路径调用（上限 50 篇/次，天然可续跑）。
  ///
  /// 返回本次处理的篇数。
  int backfillBlocks({int limit = 50}) => _blocks.backfill(limit: limit);

  /// **回填**（画布侧第 2 步）：把「正文已是画布 JSON 但还没有画布行」的存量画布补进
  /// `canvas_items` / `canvas_meta` / `ink_shards`。
  ///
  /// 与 [backfillBlocks] 同节奏：启动路径调用、每批上限 50 篇、天然可续跑；
  /// 同样**只写不读**（画布仍从 `notes.content` 读）。返回本次处理的篇数。
  int backfillCanvas({int limit = 50}) => _canvas.backfill(limit: limit);

  /// [content] 由调用方给定：默认是行里的旧列，[noteById] 会在校验通过后
  /// 传入从 `blocks` 还原出来的正文（见那里的说明）。
  Note _noteFrom(Map<String, Object?> row, {String? content}) => Note(
        id: row['id'] as String,
        kind: NoteKind.fromName(row['kind'] as String),
        title: row['title'] as String,
        // 列表查询不带 content 列（大字段）→ 这里是 null；只有 [noteById]
        // 的完整行查询才有值。列表侧一律空串，正文永远走单行查询。
        content: content ?? (row['content'] as String?) ?? '',
        plainText: row['plain_text'] as String? ?? '',
        contentHash: row['content_hash'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        revisedAt: DateTime.fromMillisecondsSinceEpoch(row['revised_at'] as int),
        promotedAt: row['promoted_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['promoted_at'] as int),
      );
}
