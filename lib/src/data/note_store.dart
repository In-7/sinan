import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../domain/backlink.dart';
import '../domain/block_hit.dart';
import '../domain/embed_line.dart';
import '../domain/note.dart';
import 'block_props.dart';
import 'block_store.dart';
import 'canvas_store.dart';
import 'fingerprint.dart';
import 'index_job.dart';
import 'stream_store.dart';

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
  ///
  /// 新建 / 修改日期都取当下——"写日记"也**只落今天**（2026-09-29 用户定：
  /// 日历点选日只管回看，不改变落笔日期）。
  Note create({
    NoteKind kind = NoteKind.spark,
    String title = '',
    String content = '',
  }) {
    final String id = _uuid.v4();
    final DateTime now = DateTime.now();
    final String hash = contentFingerprint(content);
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, created_at, revised_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        id,
        kind.name,
        title,
        content,
        hash,
        now.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
      ],
    );
    _blocks.replaceNoteBlocks(id, content);
    _canvas.replaceCanvasRows(id, content);
    return Note(
      id: id,
      kind: kind,
      title: title,
      content: content,
      // 新建时没有纯文本（首编才由编辑器提取 plainText 走 updateContent），
      // plain_text / summary 两列都吃默认 ''，这里与库里保持一致。
      plainText: content,
      summary: '',
      contentHash: hash,
      createdAt: now,
      revisedAt: now,
    );
  }

  /// **一步建一篇带正文的笔记**（含 `plain_text` / `summary`），返回可直接进列表
  /// 快照的 [Note]——`summary` 已填 ⇒ 卡片预览立即可见，无「先建空卡再填」的中间
  /// 闪烁。与 [create] 的差别：正文一起落，且写好摘要投影列。
  ///
  /// 两个使用者：心流输入框（[NoteKind.spark]）与心流「转成新笔记」导出
  /// （[NoteKind.note]）——都是「文本一步落成一篇」。
  Note createSpark({
    NoteKind kind = NoteKind.spark,
    required String content,
    required String plainText,
    String title = '',
  }) {
    final String id = _uuid.v4();
    final DateTime now = DateTime.now();
    final String hash = contentFingerprint(content);
    db.execute(
      'INSERT INTO notes (id, kind, title, content, plain_text, summary, '
      'content_hash, created_at, revised_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        id,
        kind.name,
        title,
        content,
        plainText,
        Note.summarize(plainText),
        hash,
        now.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
      ],
    );
    _blocks.replaceNoteBlocks(id, content);
    _canvas.replaceCanvasRows(id, content);
    return Note(
      id: id,
      kind: kind,
      title: title,
      content: content,
      plainText: plainText,
      summary: Note.summarize(plainText),
      contentHash: hash,
      createdAt: now,
      revisedAt: now,
    );
  }

  // ── 速记（心流）→ 笔记 / 画布：**单向导出** ─────────────────────────────
  //
  // 速记的真相源是独立表 `stream_items`（见 `StreamStore`），与 notes / blocks
  // **无外键**。这里只做"用户手动把一条速记变成内容"的写路径：
  //
  // - **引用**（活链）：笔记里插 `ref` 块（`ref_type='stream'`）。只有笔记读速记，
  //   速记永不回读；删速记后引用处显示「已失效」，笔记内容不丢。
  // - **复制**（快照）：笔记里插独立段落块 / 画布上建独立块 + 卡片，之后互不相干。
  // - **转新**（归档）：建成一篇新笔记，速记条目**归档**（2026-10-17 定：不删，
  //   可回看、可撤销）。
  //
  // 画布**不做**活链（同日定）：卡片必须有自己的块，速记更新不推送过去。

  /// 速记文本（引用解析 / 复制 / 转新的唯一读口）。条目不存在返回 null。
  String? streamTextOf(String streamId) => StreamStore(db).textOf(streamId);

  /// 复制 / 注入共用的段落块节点。**同时写 `delta` 与 `text`**：`delta` 给 AppFlowy
  /// 编辑器读；`text` 给数据层的 [textOfProps] / `blockText` / 画布卡片快照 / 反链
  /// 上下文读——editor 写的块只有 `delta`，缺 `text` 会让这些读口拿到空串。
  static Map<String, Object?> _paragraphNode(String id, String text) =>
      <String, Object?>{
        'id': id,
        'type': 'paragraph',
        'data': <String, Object?>{
          'delta': <Object?>[
            <String, Object?>{'insert': text},
          ],
          'text': text,
        },
      };

  static Map<String, Object?> _emptyTreeMap() => <String, Object?>{
    'v': 2,
    'format': 'blocks',
    'document': <String, Object?>{'type': 'page', 'children': <Object?>[]},
  };

  /// 目标**文档**笔记的 v2 块树；画布 / 不存在 / 脏内容 ⇒ null，空正文 ⇒ 空树。
  Map<String, Object?>? _targetDocTree(String noteId) {
    final Note? n = noteById(noteId);
    if (n == null || n.kind == NoteKind.canvas) return null;
    final String raw = n.content.trim();
    if (raw.isEmpty) return _emptyTreeMap();
    try {
      final Object? d = jsonDecode(raw);
      if (d is Map<String, Object?> && d['document'] is Map<String, Object?>) {
        return d;
      }
    } on FormatException {
      // 脏内容不当目标。
    }
    return null;
  }

  static List<Object?> _treeChildren(Map<String, Object?> tree) {
    final Map<String, Object?> document =
        tree['document'] as Map<String, Object?>;
    final Object? ch = document['children'];
    document['children'] = ch is List<Object?> ? ch : <Object?>[];
    return document['children'] as List<Object?>;
  }

  /// **处理台账**：记一次"这条速记流去了哪里"（背景见 [StreamExport]）。
  ///
  /// 只追加、删目标**不清行**：台账是回忆录，不是导航索引。标题取**当时的快照**——
  /// 之后目标改名甚至被删，这一行照样读得懂。
  void _recordStreamExport(
    String streamId, {
    required String targetType,
    required String targetId,
    required StreamExportKind kind,
    String? targetBlockId,
  }) {
    final ResultSet rs = db.select(
      'SELECT title FROM notes WHERE id = ?',
      <Object?>[targetId],
    );
    if (rs.isEmpty) return;
    final String title = (rs.first['title'] as String?)?.trim() ?? '';
    db.execute(
      'INSERT INTO stream_exports '
      '(id, stream_id, target_type, target_id, target_title, kind, created_at, target_block_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        _uuid.v4(),
        streamId,
        targetType,
        targetId,
        title.isEmpty ? '（无标题）' : title,
        kind.name,
        DateTime.now().millisecondsSinceEpoch,
        targetBlockId,
      ],
    );
  }

  /// **处理台账**：按速记分组读（一次 `IN` 查完再分组，不在界面里 N 次查）。
  Map<String, List<StreamExport>> streamExportsOf(Iterable<String> streamIds) {
    if (streamIds.isEmpty) return const <String, List<StreamExport>>{};
    final String marks = List<String>.filled(streamIds.length, '?').join(',');
    return _groupExports(
      db.select(
        'SELECT id, stream_id, target_type, target_id, target_title, kind, created_at, target_block_id '
        'FROM stream_exports WHERE stream_id IN ($marks) '
        'ORDER BY created_at DESC, rowid DESC',
        <Object?>[...streamIds],
      ),
    );
  }

  /// 整本台账（界面用：面板一屏就是全部已处理条目，没必要先筛 id）。
  Map<String, List<StreamExport>> allStreamExports() => _groupExports(
    db.select(
      'SELECT id, stream_id, target_type, target_id, target_title, kind, created_at, target_block_id '
      'FROM stream_exports ORDER BY created_at DESC, rowid DESC',
    ),
  );

  Map<String, List<StreamExport>> _groupExports(ResultSet rs) {
    final Map<String, List<StreamExport>> out = <String, List<StreamExport>>{};
    for (final Row r in rs) {
      final String sid = r['stream_id'] as String;
      out.putIfAbsent(sid, () => <StreamExport>[]).add(
        StreamExport(
          id: r['id'] as String,
          streamId: sid,
          targetType: r['target_type'] as String,
          targetId: r['target_id'] as String,
          targetTitle: r['target_title'] as String,
          kind: StreamExportKind.parse(r['kind'] as String),
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            r['created_at'] as int,
          ),
          targetBlockId: r['target_block_id'] as String?,
        ),
      );
    }
    return out;
  }

  /// 块树 JSON 里**第一个块**的 id：新建笔记/合并笔记的流向落点。
  ///
  /// 解析失败返回 null（老数据 / 异常格式）⇒ 点流向退化为"只跳那篇"，不定位。
  static String? _firstBlockIdOf(String treeJson) {
    try {
      final Object? decoded = jsonDecode(treeJson);
      if (decoded is! Map<String, Object?>) return null;
      final Object? document = decoded['document'];
      if (document is! Map<String, Object?>) return null;
      final Object? children = document['children'];
      if (children is! List<Object?> || children.isEmpty) return null;
      final Object? first = children.first;
      return first is Map<String, Object?> ? first['id'] as String? : null;
    } on Object {
      return null;
    }
  }

  /// 由速记文本推导标题（≤20 字，首行）：新建的笔记 / 画布不该叫"无标题"——
  /// 台账念的是《标题》，空标题会让"这条流去了哪"读不出来。
  static String _titleFromText(String text) {
    final String first = text.trim().split('\n').first.trim();
    if (first.isEmpty) return '速记';
    return first.length <= 20 ? first : '${first.substring(0, 20)}…';
  }

  /// 台账要能点进去 ⇒ 跳之前先确认目标还在（删掉的话就别跳了）。
  bool targetNoteExists(String targetId) => db
      .select('SELECT 1 FROM notes WHERE id = ?', <Object?>[targetId])
      .isNotEmpty;

  /// **引用到笔记**（活链）：在目标块树里插一个 `ref` 块（`ref_type='stream'`）。
  /// 速记留在心流；已引用过 ⇒ 幂等 false。
  bool referenceStreamInNote(String streamId, String noteId) {
    final Map<String, Object?>? tree = _targetDocTree(noteId);
    if (tree == null) return false;
    // 目标条目必须还在：否则插进去的就是一条天生的断链。
    if (streamTextOf(streamId) == null) return false;
    final List<Object?> children = _treeChildren(tree);
    for (final Object? n in children) {
      if (n is! Map<String, Object?> || n['type'] != _refType) continue;
      final Object? data = n['data'];
      if (data is Map<String, Object?> &&
          data['ref_type'] == _refTargetStream &&
          data['ref_id'] == streamId) {
        return false;
      }
    }
    final String refBlockId = _uuid.v4();
    children.add(<String, Object?>{
      'id': refBlockId,
      'type': _refType,
      'data': <String, Object?>{
        'ref_type': _refTargetStream,
        'ref_id': streamId,
        'ref_view': 'link',
      },
    });
    _persistContentSync(noteId, jsonEncode(tree));
    _recordStreamExport(
      streamId,
      targetType: 'note',
      targetId: noteId,
      kind: StreamExportKind.reference,
      targetBlockId: refBlockId,
    );
    return true;
  }

  /// **复制到笔记**（快照）：把速记文本复制成目标里的**段落**。
  ///
  /// 多行速记按行拆成多个段落块——与 `streamToNewNote` 同一口径；否则整段换行
  /// 塞进一个块里，在编辑器里表现成"一块超大段落"（2026-10-17 复查）。
  bool copyStreamIntoNote(String streamId, String noteId) {
    final Map<String, Object?>? tree = _targetDocTree(noteId);
    if (tree == null) return false;
    final String? text = streamTextOf(streamId);
    if (text == null || text.trim().isEmpty) return false;
    final List<Object?> children = _treeChildren(tree);
    // 第一段（多行速记会拆成多个块）就是"这条流去了哪"的落点。
    final List<String> lines = StreamStore.linesOf(text);
    final String firstBlockId = _uuid.v4();
    for (int i = 0; i < lines.length; i++) {
      children.add(_paragraphNode(i == 0 ? firstBlockId : _uuid.v4(), lines[i]));
    }
    _persistContentSync(noteId, jsonEncode(tree));
    _recordStreamExport(
      streamId,
      targetType: 'note',
      targetId: noteId,
      kind: StreamExportKind.copy,
      targetBlockId: firstBlockId,
    );
    return true;
  }

  /// **复制到画布**（快照卡）：新建一张**独立**卡片（自己的块 + 自己的文本），
  /// 速记更新不会再推过来（2026-10-17 用户定：画布只复制、不做活链）。
  bool copyStreamOntoCanvas(
    String streamId,
    String canvasId, {
    StreamExportKind kind = StreamExportKind.copy,
  }) {
    final String? text = streamTextOf(streamId);
    if (text == null || text.trim().isEmpty) return false;
    final Map<String, Object?>? doc = _canvasDoc(canvasId);
    if (doc == null) return false;
    final Map<String, Object?>? document = _canvasDocument(doc);
    if (document == null) return false;
    final Map<String, Object?>? items = _canvasItems(document);
    if (items == null) return false;

    final String itemId = _nextCanvasItemId(items.keys);
    final String cardBlockId = _uuid.v4();
    items[itemId] = <String, Object?>{
      'type': 'card',
      'id': itemId,
      'blockId': cardBlockId,
      'text': text,
      'angle': 0,
      'rect': _freeCardRect(items),
      'meta': <String, Object?>{},
    };
    final Object? rawOrder = document['itemOrder'];
    final List<Object?> order = rawOrder is List
        ? rawOrder.toList()
        : <Object?>[];
    order.add(itemId);
    document['itemOrder'] = order;

    // 落盘 + 投影：`_replaceCardBlocks` 会为这张新卡建好 `blocks` 行
    // （先内容后几何，外键才不会炸）。
    _persistContentSync(canvasId, jsonEncode(doc));
    _recordStreamExport(
      streamId,
      targetType: 'canvas',
      targetId: canvasId,
      kind: kind,
      targetBlockId: cardBlockId,
    );
    return true;
  }

  /// **转成新笔记**（归档）：建一篇正式笔记装上这段文本，速记条目**归档**
  /// （不删 —— 速记最怕误删，归档区还能找回来）。
  Note? streamToNewNote(String streamId, {NoteKind kind = NoteKind.note}) {
    final String? text = streamTextOf(streamId);
    if (text == null) return null;
    final Note n = createSpark(
      kind: kind,
      // 标题取自首行：台账念的是《标题》，一篇"无标题"会让那行读不出去了哪。
      title: _titleFromText(text),
      content: StreamStore.blocksTreeFromText(text),
      plainText: text,
    );
    StreamStore(db).archive(streamId);
    _recordStreamExport(
      streamId,
      targetType: 'note',
      targetId: n.id,
      kind: StreamExportKind.toNote,
      targetBlockId: _firstBlockIdOf(n.content),
    );
    return n;
  }

  /// **合并成一篇新笔记**（归档）：多条速记按时间顺序（旧 → 新）拼成正文。
  ///
  /// 这是速记 → 深思考的主路径：零散记录攒够了，一次提炼成一篇笔记。
  /// 参与合并的条目全部归档（可回看）；返回 null = 一条有效的都没有。
  Note? streamMergeToNewNote(List<String> streamIds) {
    if (streamIds.isEmpty) return null;
    // 顺序在 SQL 里定死：`created_at`（同一毫秒再按插入顺序 rowid）——
    // 只在内存里 sort 会因为入库时间戳截到毫秒而并列，合并顺序时对时错。
    final String marks = List<String>.filled(streamIds.length, '?').join(',');
    final ResultSet rs = db.select(
      'SELECT id, text FROM stream_items WHERE id IN ($marks) '
      'ORDER BY created_at ASC, rowid ASC',
      streamIds,
    );
    if (rs.isEmpty) return null;
    final List<String> lines = <String>[
      for (final Row r in rs)
        ...(r['text'] as String).split('\n').where(
          (String l) => l.trim().isNotEmpty,
        ),
    ];
    if (lines.isEmpty) return null;
    final String plain = lines.join('\n');
    final Note n = createSpark(
      kind: NoteKind.note,
      // 同「转新」：台账要读得懂这条合并出来的是哪一篇。
      title: _titleFromText(plain),
      content: StreamStore.blocksTreeFromText(plain),
      plainText: plain,
    );
    final StreamStore streams = StreamStore(db);
    for (final Row r in rs) {
      final String id = r['id'] as String;
      streams.archive(id);
      _recordStreamExport(
        id,
        targetType: 'note',
        targetId: n.id,
        kind: StreamExportKind.merge,
        targetBlockId: _firstBlockIdOf(n.content),
      );
    }
    return n;
  }

  /// **转成新画布**（归档）：新建一张画布，里面放一条独立卡片（速记文本）。
  Note? streamToNewCanvas(String streamId) {
    final String? text = streamTextOf(streamId);
    if (text == null) return null;
    final Note n = create(kind: NoteKind.canvas, title: _titleFromText(text));
    // 画布需要合法骨架才能被 `_canvasDoc` 认出来（create 只给空 content）。
    _persistContentSync(
      n.id,
      jsonEncode(<String, Object?>{
        'camera': <String, Object?>{'x': 0, 'y': 0, 'scale': 1},
        'document': <String, Object?>{
          'items': <String, Object?>{},
          'itemOrder': <Object?>[],
        },
      }),
    );
    // 卡片建失败就**别归档**（否则速记被标成已处理、却哪儿都没有）——顺手把这张
    // 空画布删掉，不留半成品。
    if (!copyStreamOntoCanvas(
      streamId,
      n.id,
      kind: StreamExportKind.toCanvas,
    )) {
      db.execute('DELETE FROM notes WHERE id = ?', <Object?>[n.id]);
      return null;
    }
    StreamStore(db).archive(streamId);
    return noteById(n.id);
  }

  /// 保存正文。content 的格式**由当前编辑器决定**（quill 时期是 Delta，
  /// 换成 appflowy 后是 v2 块树；详见 NoteDocumentAdapter）——本层不关心
  /// 格式，只存字符串。plainText 同步入库（全文搜索 / 字数统计用），其
  /// [Note.summarize] 截断投影 `summary` 一并写入（列表卡片快照专用）。
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
      'UPDATE notes SET content = ?, plain_text = ?, summary = ?, '
      'content_hash = ?, revised_at = ? WHERE id = ?',
      <Object?>[
        content,
        plainText,
        Note.summarize(plainText),
        hash,
        now.millisecondsSinceEpoch,
        noteId,
      ],
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

  /// 全部笔记（**列表快照**：元数据 + 摘要，**不含块树正文、不含整篇纯文本**）：
  /// **收藏的排在最前**（按收藏时间倒序），其余按最近修改倒序。
  ///
  /// ⚠️ 查询刻意**不带 `content` 列**：正文是块树 JSON，单篇可达几百 KB，
  /// 全表读入是保存热路径最贵的一步。列表只需要元数据（标题/时间）；
  /// 正文按 id 单行另取，见 [noteById]。
  ///
  /// 纯文本只带 **`summary` 投影**（v13，`plain_text` 前 160 字符，见
  /// [Note.summarize]）：卡片 4 行摘要 / 无标题借首行这两个消费方够用，
  /// 万篇级快照内存比带整篇 `plain_text` 降一个量级。整篇纯文本仍可经
  /// [plainTextOf] / [noteById] 单行取。
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
      'SELECT id, kind, title, content_hash, tags, summary, '
      'created_at, revised_at, promoted_at FROM notes '
      // v16 起速记不再是笔记（独立表 `stream_items`）⇒ 已没有要排除的形态。
      'ORDER BY (promoted_at IS NULL) ASC, promoted_at DESC, '
      'revised_at DESC, created_at DESC, id ASC',
    );
    return <Note>[for (final Map<String, Object?> row in rs) _noteFrom(row)];
  }

  /// **列表快照的排序**：Dart 侧等价于 [allNotes] 的 `ORDER BY`。
  ///
  /// 保存后只换一行的**增量补丁**（见 `NotesNotifier._replaceRow`）用它重排，
  /// 免去整表重查 + 全量 `Row → Note` 映射（万篇级 ≈ 百毫秒，全在 UI 线程）。
  /// 但消费者是**按索引渲染**的（左侧列表 / 空间内联列表），顺序必须与
  /// [allNotes] **逐字等价**——两处口径由测试钉死，改一处漏另一处会立刻红。
  static int compareForList(Note a, Note b) {
    // (promoted_at IS NULL) ASC：已收藏（非空）在前。
    final DateTime? ap = a.promotedAt;
    final DateTime? bp = b.promotedAt;
    if ((ap == null) != (bp == null)) return ap == null ? 1 : -1;
    if (ap != null && bp != null) {
      final int byPromoted = bp.compareTo(ap); // promoted_at DESC
      if (byPromoted != 0) return byPromoted;
    }
    final int byRevised = b.revisedAt.compareTo(a.revisedAt); // revised_at DESC
    if (byRevised != 0) return byRevised;
    final int byCreated = b.createdAt.compareTo(a.createdAt); // created_at DESC
    if (byCreated != 0) return byCreated;
    return a.id.compareTo(b.id); // id ASC（兜底全序，稳）
  }

  /// 按 id 取**列表快照形态**的单行（**不含正文 / 整篇纯文本**）。
  ///
  /// 与 [allNotes] 同一列投影，但只取一行——保存后的增量补丁用它拿"换行后"
  /// 的最新值（新 `revised_at` / `summary` / `content_hash`）。不存在返回 null。
  Note? noteListRow(String id) {
    final ResultSet rs = db.select(
      'SELECT id, kind, title, content_hash, tags, summary, '
      'created_at, revised_at, promoted_at FROM notes WHERE id = ?',
      <Object?>[id],
    );
    if (rs.isEmpty) return null;
    return _noteFrom(rs.first);
  }

  /// 按 id 取**整篇纯文本**（懒取）：`noteById` 之外的窄查询。
  ///
  /// 列表快照只带 160 字的 `summary` 投影（v13，见 [allNotes]）；本方法
  /// 留给"需要整篇 plain_text"的调用方（字数统计 / 导出 / 检索兜底）。
  ///
  /// 不存在 / 该列为空时返回空串（与 [_noteFrom] 的口径一致）。
  String plainTextOf(String noteId) {
    final ResultSet rs = db.select(
      'SELECT plain_text FROM notes WHERE id = ?',
      <Object?>[noteId],
    );
    if (rs.isEmpty) return '';
    return rs.first['plain_text'] as String? ?? '';
  }

  /// 按 id 取**单篇画布的 JSON 原文**（懒取）：主页画布卡片缩略图专用窄查询。
  ///
  /// 与 [canvasContents] 同口径（直接读 `notes.content`，双写阶段它仍是画布
  /// 读路径的权威），但按 id 只取一行——网格里每张可见画布卡各取一次，结果
  /// 由调用方的 autoDispose provider 缓存，不背进列表快照。
  /// 不存在 / 非画布 / 空串都返回空串，调用方按空串渲染空画布占位。
  String canvasContentOf(String noteId) {
    final ResultSet rs = db.select(
      'SELECT content FROM notes WHERE id = ? AND kind = ?',
      <Object?>[noteId, NoteKind.canvas.name],
    );
    if (rs.isEmpty) return '';
    return rs.first['content'] as String? ?? '';
  }

  /// 画布缩略图的**关系表快路径**：闸门通过时返回 `canvas_items` 逆投影的
  /// item JSON（不读 MB 级 content、不解析笔迹，无需 Isolate）；闸门不过
  /// （回填未到 / 行落后 / 行数不符）返回 null，调用方降落伞走
  /// [canvasContentOf] + 全文解析。不存在 / 非画布也返回 null。
  List<Map<String, dynamic>>? canvasThumbnailItemJson(String noteId) {
    final ResultSet rs = db.select(
      'SELECT content_hash FROM notes WHERE id = ? AND kind = ?',
      <Object?>[noteId, NoteKind.canvas.name],
    );
    if (rs.isEmpty) return null;
    return _canvas.thumbnailItemJson(
      noteId,
      rs.first['content_hash'] as String,
    );
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
  /// 正文**优先从投影表还原**，但只有在**校验通过**时才采用；否则
  /// 静默回退到旧的 `notes.content`。这样任何还原偏差都不会让用户看到
  /// 内容丢失——最坏情况是"还没切过去"，而不是"切坏了"。
  /// 等 v10 删掉旧列时，这个回退才一并移除。
  ///
  /// 两条投影**各自带格式门闩**（块树只认 v2、画布只认 `{camera, document}`）
  /// ⇒ 可以无脑都试：对任何一篇笔记，另一条必然返回 null，不会互相抢。
  Note? noteById(String id) {
    final ResultSet rs = db.select(
      'SELECT * FROM notes WHERE id = ?',
      <Object?>[id],
    );
    if (rs.isEmpty) return null;

    final Row row = rs.first;
    final String legacy = row['content'] as String? ?? '';
    final String? rebuilt =
        _blocks.readVerifiedDocument(id, legacy) ??
        _canvas.readVerifiedCanvas(id, legacy);
    return _noteFrom(row, content: rebuilt ?? legacy);
  }

  /// 收藏 / 取消收藏（`promoted_at` 同时充当"是否收藏"与"收藏时间"）。
  ///
  /// 不动 revised_at：收藏是整理动作，不是内容修改，不该影响"最近修改"。
  Future<void> setPromoted(String noteId, bool promoted) async {
    db.execute('UPDATE notes SET promoted_at = ? WHERE id = ?', <Object?>[
      promoted ? DateTime.now().millisecondsSinceEpoch : null,
      noteId,
    ]);
  }

  /// 保存标签。与 [setPromoted] 同一性质：**整理元数据**，不动 revised_at
  /// ——贴标签不该把笔记顶到"最近修改"最前，否则列表会跳。
  ///
  /// 归一化（trim / 丢空 / 去重）在这里做（[Note.sanitizeTags]），UI 传原始
  /// 列表即可。存储形态：JSON 字符串数组（v12，见 database.dart 迁移注释）。
  Future<void> updateTags(String noteId, List<String> tags) async {
    db.execute('UPDATE notes SET tags = ? WHERE id = ?', <Object?>[
      jsonEncode(Note.sanitizeTags(tags)),
      noteId,
    ]);
  }

  Future<void> delete(String noteId) async {
    // chunks_fts 是 FTS5 虚拟表、**无外键**（见 database.dart 建表注释）——
    // blocks 靠 CASCADE 清，它的行没人替 ⇒ 必须在这里手工清，否则已删笔记
    // 的块永远留在检索索引里（"幽灵命中"）。
    db.execute('DELETE FROM chunks_fts WHERE note_id = ?', <Object?>[noteId]);
    // rag_meta 是无外键 KV：画布投影的两把指纹键（meta 指纹 + 缩略图快路径
    // 闸门）没人随笔记级联，顺手清掉，避免删笔记后留下永久孤儿键。
    db.execute('DELETE FROM rag_meta WHERE key = ? OR key = ?', <Object?>[
      'canvas.meta.fp.$noteId',
      'canvas.srcfp.$noteId',
    ]);
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
      '(id, kind, title, content, plain_text, summary, content_hash, '
      'created_at, revised_at, promoted_at, tags) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        note.id,
        note.kind.name,
        note.title,
        note.content,
        note.plainText,
        // 撤销来源是删除前的列表快照（只带 summary）。INSERT OR REPLACE
        // 后首次保存会把两列一起刷新；这里为空也不影响卡片显示之外的东西。
        note.summary,
        note.contentHash,
        note.createdAt.millisecondsSinceEpoch,
        note.revisedAt.millisecondsSinceEpoch,
        note.promotedAt?.millisecondsSinceEpoch,
        // ⚠️ tags 必须带上：漏了它，`INSERT OR REPLACE` 会用列默认 '[]'
        // 覆盖——撤销一次删除，标签就静默清空了。
        jsonEncode(note.tags),
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

  /// 启动期补关键词索引：把「还没进 `chunks_fts`」的笔记整篇索引进去（幂等、纯 SQL）。
  ///
  /// 覆盖存量 AppFlowy 笔记——它们之前因块 `data` 内文本在 `delta` 里（非顶层
  /// `text`）而漏索引，导致全局搜索正文搜不到（2026-09-25 修）。只补缺的，已索引
  /// 的笔记不动；建议在 `backfillBlocks` 之后调用（先有 blocks 行才能索引）。
  void ensureKeywordIndex() => IndexJob(db: db).ensureKeywordIndex();

  // ───────────────────── 块可迁移（#5，2026-09-18） ─────────────────────
  //
  // 文档块 ↔ 画布卡片是**同一份内容**（`blocks` 里的一行）：卡片用 `blockId` 指向它。
  // 于是"搬动"只是改这块的**归属**——在文档块树里、还是在画布上——块内容永不动。
  // 难点在 [BlockStore.replaceNoteBlocks] 的删除集：它把"不在块树里"的块当孤儿删。
  // 为此该删除集已破例**保留被画布卡片引用的块**（见 `BlockStore._canvasReferencedBlockIds`），
  // 于是"搬去画布"后那块不会被文档保存误删。

  /// 一块当前归属的笔记（从 `blocks.note_id` 反查）。不存在的块返回 null。
  String? blockNoteId(String blockId) {
    final ResultSet rs = db.select(
      'SELECT note_id FROM blocks WHERE id = ?',
      <Object?>[blockId],
    );
    return rs.isEmpty ? null : rs.first['note_id'] as String?;
  }

  /// 把一块**搬回文档块树**（画布 → 文档）。块内容一直都在，只是不在树里时被画布托管；
  /// 这里把它加回文档块树根部。已在一棵树里则幂等返回 false。
  ///
  /// ⚠️ 调用方负责把块从画布卡片摘掉（或保留卡片也行——同一块可同时在两边）。
  bool moveBlockToDocument(String blockId) {
    final String? noteId = blockNoteId(blockId);
    if (noteId == null) return false;
    final Map<String, Object?>? node = _blockNode(blockId);
    if (node == null) return false;
    final String? content = _rawContent(noteId);
    if (content == null) return false;
    final Map<String, Object?> doc =
        jsonDecode(content) as Map<String, Object?>;
    final List<Object?> children =
        (doc['document']! as Map<String, Object?>)['children']!
            as List<Object?>;
    if (_findNode(children, blockId) != null) return false;
    children.add(node);
    _persistContentSync(noteId, jsonEncode(doc));
    return true;
  }

  /// 把一块**从文档块树摘掉**（文档 → 画布）。块内容留在 `blocks`，由画布卡片托管。
  ///
  /// ⚠️ 调用前必须先建好引用该 `blockId` 的画布卡片，否则 [BlockStore] 的删除集
  /// 会把这块当成孤儿删掉（破例只保留**已建卡片**引用的块）。
  bool moveBlockToCanvas(String blockId) {
    final String? noteId = blockNoteId(blockId);
    if (noteId == null) return false;
    final String? content = _rawContent(noteId);
    if (content == null) return false;
    final Map<String, Object?> doc =
        jsonDecode(content) as Map<String, Object?>;
    final List<Object?> children =
        (doc['document']! as Map<String, Object?>)['children']!
            as List<Object?>;
    if (_removeNode(children, blockId)) {
      _persistContentSync(noteId, jsonEncode(doc));
      return true;
    }
    return false;
  }

  // ── 「双链多视图」：把文档里的块**引用**到画布上（#5 反向）───────────────
  //
  // 与上面两个 `move*` 的分水岭：`move*` 改的是块的**归属**（块同一时刻只在一边）；
  // 这里**不动归属** —— 块留在文档块树里，画布上只是多一张指向**同一份内容**的
  // 卡片。于是两边都能编辑同一份真身，也没有"块到底在哪边"的心智负担。
  //
  // 卡片文本的读写落在两处：画布 JSON 里的 `text` 只是**快照**，真身在 `blocks`。
  // 所以①打开画布前先 [syncCanvasCardTexts] 刷新快照（文档侧的改动能看见）；
  // ②画布保存时由 `CanvasStore._replaceCardBlocks` 把 `text` 写回那个块。

  /// 块的文本（`blocks.props_json` 的 `text`）。块不存在返回 null。
  String? blockText(String blockId) {
    final ResultSet rs = db.select(
      'SELECT props_json FROM blocks WHERE id = ?',
      <Object?>[blockId],
    );
    if (rs.isEmpty) return null;
    return textOfProps(rs.first['props_json'] as String?);
  }

  /// **流向预览**（P2）：这条速记落地后那一块的**真实正文**。
  ///
  /// 台账不再只给一个标题——扫读时就想看到"它变成了什么"，所以直接把落点块的
  /// 文本取回来（画布卡与笔记段落同在 `blocks` 里，一把查询通吃）。
  ///
  /// - 复制 / 转为：落点块的正文；
  /// - 合并 / 引用：落点是整篇（ref 块本身没有可读正文）⇒ 给目标笔记的**开头两行**；
  /// - 目标被删：返回 null（界面显示"原文已删"）。
  String? streamExportPreview(StreamExport e) {
    if (e.targetBlockId != null && e.kind != StreamExportKind.reference) {
      final String? text = blockText(e.targetBlockId!)?.trim();
      if (text != null && text.isNotEmpty) return text;
    }
    if (e.kind == StreamExportKind.merge ||
        e.kind == StreamExportKind.reference) {
      final ResultSet rs = db.select(
        'SELECT plain_text FROM notes WHERE id = ?',
        <Object?>[e.targetId],
      );
      if (rs.isEmpty) return null;
      final String plain = (rs.first['plain_text'] as String?) ?? '';
      final List<String> lines = plain
          .split('\n')
          .where((String l) => l.trim().isNotEmpty)
          .take(2)
          .toList();
      return lines.isEmpty ? null : lines.join('\n');
    }
    return null;
  }

  /// 把画布 JSON 里卡片的 `text` 刷新成 `blocks` 里的最新值（**打开画布前**调）。
  ///
  /// 卡片文本的真身在 `blocks`，画布 JSON 只是保存时的快照；文档侧改了被引用的
  /// 块之后快照就旧了。这里按 `blockId` 逐个取回，有变化才落盘。返回是否改了。
  bool syncCanvasCardTexts(String canvasNoteId) {
    final Map<String, Object?>? doc = _canvasDoc(canvasNoteId);
    if (doc == null) return false;
    final Map<String, Object?>? document = _canvasDocument(doc);
    if (document == null) return false;
    final Map<String, Object?>? items = _canvasItems(document);
    if (items == null) return false;

    bool changed = false;
    for (final Object? v in items.values) {
      if (v is! Map) continue;
      final Map<String, Object?> card = v.cast<String, Object?>();
      if (card['type'] != 'card') continue;
      final Object? blockId = card['blockId'];
      if (blockId is! String) continue;
      final String? text = blockText(blockId);
      if (text == null || text == card['text']) continue;
      card['text'] = text;
      changed = true;
    }
    if (changed) _persistContentSync(canvasNoteId, jsonEncode(doc));
    return changed;
  }

  /// 在 [canvasNoteId] 这张画布上**引用** [blockId] 这块（#5 反向）。
  ///
  /// [rect] 是卡片的初始矩形（`[l, t, r, b]`，世界坐标）；不传则自动排布到
  /// 现有元素**下方**，免得盖住已有内容。
  ///
  /// 同一张画布里已经有指向这块的卡片时幂等返回 false（不重复加）。
  bool referenceBlockOnCanvas(
    String blockId,
    String canvasNoteId, {
    List<double>? rect,
  }) {
    // 真身必须在：否则画布上会多一张指向空气的卡片。
    final String? text = blockText(blockId);
    if (text == null) return false;

    final Map<String, Object?>? doc = _canvasDoc(canvasNoteId);
    if (doc == null) return false;
    final Map<String, Object?>? document = _canvasDocument(doc);
    if (document == null) return false;
    final Map<String, Object?>? items = _canvasItems(document);
    if (items == null) return false;

    for (final Object? v in items.values) {
      if (v is! Map) continue;
      final Map<String, Object?> card = v.cast<String, Object?>();
      if (card['type'] == 'card' && card['blockId'] == blockId) return false;
    }

    final String id = _nextCanvasItemId(items.keys);
    items[id] = <String, Object?>{
      'type': 'card',
      'id': id,
      'blockId': blockId,
      'text': text,
      'angle': 0,
      'rect': rect ?? _freeCardRect(items),
      'meta': <String, Object?>{},
    };
    final Object? rawOrder = document['itemOrder'];
    final List<Object?> order = rawOrder is List
        ? rawOrder.toList()
        : <Object?>[];
    order.add(id);
    document['itemOrder'] = order;

    // 同步落盘 + 双写投影（`_canvas.replaceCanvasRows` 会把这行写进
    // `canvas_items`；卡的 `block_id` 指向已存在的块，外键成立）。
    _persistContentSync(canvasNoteId, jsonEncode(doc));
    return true;
  }

  // ── 全库块搜索：「引用块」选择器的数据来源 ────────────────────────────
  //
  // 引用块走**一级扁平搜索**（Roam / Logseq 的路子），而不是"先选笔记、再选块"。
  // 两级导航是**文件优先**模型（Notion / Obsidian）的产物——块住在文件里，所以
  // 得先定位文件。sinan 的块是全库扁平的，一次查询就能搜到，不该让用户先回答
  // "它在哪篇笔记里"。

  /// 按文本搜块；[query] 为空时返回最近修改的一批。
  ///
  /// 空查询也返回结果是有意的：打开选择器就该看到东西，而不是一片空白等着打字
  /// （Roam 的 `((` 就是这个手感）。
  List<BlockHit> searchBlocks(String query, {int limit = 50}) {
    final String q = query.trim();
    final StringBuffer sql = StringBuffer(
      'SELECT b.id AS block_id, b.type AS block_type, b.props_json AS props_json, '
      'n.id AS note_id, n.title AS note_title, n.kind AS note_kind '
      'FROM blocks b JOIN notes n ON n.id = b.note_id '
      'WHERE n.deleted_at IS NULL '
      // 没有文本的块（分隔线 / 图片 / 引用块本身）不占名额——引用它们没有意义。
      "AND COALESCE(json_extract(b.props_json, '$_textPath'), '') <> ''",
    );
    final List<Object?> args = <Object?>[];
    if (q.isNotEmpty) {
      sql.write(" AND json_extract(b.props_json, '$_textPath') LIKE ?");
      args.add('%$q%');
    }
    sql.write(' ORDER BY b.updated_at DESC LIMIT ?');
    args.add(limit);

    return <BlockHit>[
      for (final Row r in db.select(sql.toString(), args))
        BlockHit(
          blockId: r['block_id'] as String,
          text: textOfProps(r['props_json'] as String?),
          blockType: r['block_type'] as String,
          noteId: r['note_id'] as String,
          noteTitle: r['note_title'] as String,
          noteKind: NoteKind.fromName(r['note_kind'] as String),
        ),
    ];
  }

  // ── 反链：谁引用了我 ────────────────────────────────────────────────
  //
  // 引用边只有两类，且都指向**块**（见 `domain/backlink.dart`）：
  // ① 文档里的 `ref` 块（`props_json.ref_type/ref_id`）；
  // ② 画布上的卡片（`canvas_items.block_id`）。
  // 于是"谁引用了这篇笔记" = 「ref 块指向本笔记」∪「ref 块指向本笔记的块」
  //   ∪「画布卡片指向本笔记的块」—— 两条 SQL 就够，不需要链接表。

  /// `ref` 块在 `blocks.type` 里的值（与编辑器的 `RefBlockKeys.type` 对齐）。
  ///
  /// 数据层不 import 编辑器层（那边依赖 material），故在此复刻一份 ——
  /// 与 `CanvasStore._cardType` 同一个做法。
  static const String _refType = 'ref';

  /// `props_json` 里文本的路径。
  ///
  /// ⚠️ 用常量插值、而不是把 `$.text` 直接写进 SQL 字符串：Dart 把 `$` 当作
  /// 插值开头，后面不是标识符时**编译报错**（"Expected an identifier"）。
  static const String _textPath = r'$.text';

  /// `ref_type` 的取值（与 `RefBlockKeys.refNote / refBlock / refStream` 对齐）。
  static const String _refTargetNote = 'note';
  static const String _refTargetBlock = 'block';
  static const String _refTargetStream = 'stream';

  /// 谁引用了 [noteId]（或它的块），按来源笔记的最近修改倒序。
  ///
  /// **自引用照常列出**（本笔记里的 ref 块指向自己）：它是一条真实存在的边，
  /// 悄悄过滤掉反而让人以为"没引用"。
  List<Backlink> backlinks(String noteId) {
    final ResultSet docRefs = db.select(
      'SELECT b.note_id AS source_note, n.kind AS source_kind, '
      '       n.title AS source_title, b.id AS via_block, '
      // 上下文：`ref` 块**自身没有文本**，故取它前面最近一个有文本的块。
      '       (SELECT p.props_json FROM blocks p '
      '        WHERE p.note_id = b.note_id AND p.ord < b.ord '
      "        AND COALESCE(json_extract(p.props_json, '$_textPath'), '') <> '' "
      '        ORDER BY p.ord DESC LIMIT 1) AS ctx '
      'FROM blocks b JOIN notes n ON n.id = b.note_id '
      'WHERE b.type = ? AND ('
      '  (json_extract(b.props_json, ?) = ? AND json_extract(b.props_json, ?) = ?) '
      '  OR (json_extract(b.props_json, ?) = ? AND json_extract(b.props_json, ?) IN '
      '      (SELECT id FROM blocks WHERE note_id = ?))'
      ') '
      'ORDER BY n.revised_at DESC',
      <Object?>[
        _refType,
        r'$.ref_type',
        _refTargetNote,
        r'$.ref_id',
        noteId,
        r'$.ref_type',
        _refTargetBlock,
        r'$.ref_id',
        noteId,
      ],
    );
    final ResultSet cards = db.select(
      'SELECT i.note_id AS source_note, n.kind AS source_kind, '
      '       n.title AS source_title, i.block_id AS via_block, '
      // 上下文：卡片的真身就是被引用那块 ⇒ 直接取它的文本。
      '       bt.props_json AS ctx '
      'FROM canvas_items i JOIN notes n ON n.id = i.note_id '
      '     JOIN blocks bt ON bt.id = i.block_id '
      'WHERE i.kind = ? AND i.block_id IN '
      '      (SELECT id FROM blocks WHERE note_id = ?) '
      'ORDER BY n.revised_at DESC',
      <Object?>['card', noteId],
    );

    final Set<String> seen = <String>{};
    final List<Backlink> out = <Backlink>[];
    void add(Row r, {required bool canvasCard}) {
      final String source = r['source_note'] as String;
      final String via = r['via_block'] as String;
      // 同一处引用只列一次（同笔记 + 同承载块 + 同来源类型）。
      if (!seen.add('$source|$via|$canvasCard')) return;
      out.add(
        Backlink(
          sourceNoteId: source,
          sourceTitle: r['source_title'] as String,
          sourceKind: NoteKind.fromName(r['source_kind'] as String),
          viaBlockId: via,
          viaCanvasCard: canvasCard,
          context: _contextOf(r['ctx'] as String?),
        ),
      );
    }

    for (final Row r in docRefs) {
      add(r, canvasCard: false);
    }
    for (final Row r in cards) {
      add(r, canvasCard: true);
    }
    return out;
  }

  /// **来自速记的反链**（双链的另一半）：这篇笔记收过哪些速记、怎么收的。
  ///
  /// 与 [backlinks] 的方向相反，数据来源也相反：结构化引用（`ref` 块 / 画布卡）
  /// 那边已经能查到；而**复制是快照、没有边**，只能靠台账 `stream_exports`。
  /// 一条速记对同一目标可能有多种手法（先复制后又转新）⇒ 按速记去重，留最新那笔。
  List<StreamSource> streamSourcesOf(String noteId) {
    final ResultSet rs = db.select(
      'SELECT e.stream_id AS sid, s.text AS text, e.kind AS kind, '
      '       e.created_at AS at, e.target_block_id AS block_id '
      'FROM stream_exports e JOIN stream_items s ON s.id = e.stream_id '
      'WHERE e.target_id = ? '
      'ORDER BY e.created_at DESC, e.rowid DESC',
      <Object?>[noteId],
    );
    final Set<String> seen = <String>{};
    final List<StreamSource> out = <StreamSource>[];
    for (final Row r in rs) {
      final String sid = r['sid'] as String;
      if (!seen.add(sid)) continue;
      out.add(
        StreamSource(
          streamId: sid,
          text: r['text'] as String,
          kind: StreamExportKind.parse(r['kind'] as String),
          createdAt: DateTime.fromMillisecondsSinceEpoch(r['at'] as int),
          blockId: r['block_id'] as String?,
        ),
      );
    }
    return out;
  }

  /// 反链的上下文：取文本并**截短**（它只用来"一眼判断要不要点进去"，
  /// 换行与超长都会把面板撑坏）。
  static String _contextOf(String? propsJson) {
    final String text = textOfProps(propsJson).replaceAll('\n', ' ').trim();
    const int max = 80;
    return text.length <= max ? text : '${text.substring(0, max)}…';
  }

  // ── 嵌入预览：把引用目标的内容取出来（只读） ──────────────────────────

  /// 嵌入块要显示的内容（[refType] = 'note' 取整篇的顶层块，'block' 取那一块）。
  ///
  /// ## 为什么只返回"有文本的块"
  /// 嵌入是**只读摘要**，且这条过滤顺带让递归不可能发生：`ref` 块自己没有文本
  /// ⇒ "A 嵌 B、B 又嵌 A" 不会无限展开。
  ///
  /// [limit] 只在 `refType='note'` 时生效（整篇可能很长，不能全展开）。
  List<EmbedLine> embedPreview(String refType, String refId, {int limit = 30}) {
    // 速记是独立表：不在这里拦，`ref_view='embed'` 的速记引用会得到一个空嵌入框。
    if (refType == _refTargetStream) {
      final ResultSet rs = db.select(
        'SELECT text FROM stream_items WHERE id = ?',
        <Object?>[refId],
      );
      if (rs.isEmpty) return const <EmbedLine>[];
      return <EmbedLine>[
        for (final String line
            in (rs.first['text'] as String).split('\n').take(limit))
          EmbedLine(text: line, blockType: 'paragraph'),
      ];
    }
    final ResultSet rs = refType == _refTargetBlock
        ? db.select(
            "SELECT type, props_json FROM blocks WHERE id = ? "
            "AND COALESCE(json_extract(props_json, '$_textPath'), '') <> ''",
            <Object?>[refId],
          )
        : db.select(
            "SELECT type, props_json FROM blocks WHERE note_id = ? "
            "AND COALESCE(json_extract(props_json, '$_textPath'), '') <> '' "
            'ORDER BY ord LIMIT ?',
            <Object?>[refId, limit],
          );
    return <EmbedLine>[
      for (final Row r in rs)
        _embedLineOf(r['type'] as String, r['props_json'] as String),
    ];
  }

  static EmbedLine _embedLineOf(String type, String propsJson) {
    bool? checked;
    try {
      final Object? decoded = jsonDecode(propsJson);
      if (decoded is Map && decoded['checked'] is bool) {
        checked = decoded['checked'] as bool;
      }
    } on FormatException {
      // 脏 props：就当没有勾选态，文本照样显示。
    }
    return EmbedLine(
      text: textOfProps(propsJson),
      blockType: type,
      checked: checked,
    );
  }

  /// 读画布正文并解析成可变 Map（不是画布笔记 / 脏数据 → null）。
  Map<String, Object?>? _canvasDoc(String canvasNoteId) {
    final ResultSet rs = db.select(
      'SELECT content FROM notes WHERE id = ? AND kind = ?',
      <Object?>[canvasNoteId, NoteKind.canvas.name],
    );
    if (rs.isEmpty) return null;
    return _parseJsonObject(rs.first['content'] as String?);
  }

  /// 画布正文的 `document` 子树（可变视图；写它即写回 [doc]）。
  static Map<String, Object?>? _canvasDocument(Map<String, Object?> doc) {
    final Object? document = doc['document'];
    if (document is! Map) return null;
    return document.cast<String, Object?>();
  }

  /// `document.items`（item id → item JSON 的可变视图）。
  static Map<String, Object?>? _canvasItems(Map<String, Object?> document) {
    final Object? items = document['items'];
    if (items is! Map) return null;
    return items.cast<String, Object?>();
  }

  /// 下一个画布元素 id。**沿用内核的 `item-<自增>` 形态**——内核载入时会用
  /// `advanceItemIdSequence` 把分配器推到已有 id 之后，两边因此不会撞号；
  /// 换个更可读的形态反而会让内核的推进逻辑看不见它（于是新建元素覆盖旧元素）。
  static String _nextCanvasItemId(Iterable<String> existingIds) {
    int max = -1;
    for (final String id in existingIds) {
      if (!id.startsWith('item-')) continue;
      final int? n = int.tryParse(id.substring(5));
      if (n != null && n > max) max = n;
    }
    return 'item-${max + 1}';
  }

  /// 自动排布：落在所有元素**下方**（最底边 + 24）。卡片尺寸按画布常用档位给。
  static List<double> _freeCardRect(Map<String, Object?> items) {
    const double w = 240;
    const double h = 120;
    double bottom = 0;
    for (final Object? v in items.values) {
      if (v is! Map) continue;
      final Object? r = v['rect'];
      if (r is List && r.length == 4 && r[3] is num) {
        final double b = (r[3] as num).toDouble();
        if (b > bottom) bottom = b;
      }
    }
    return <double>[0, bottom + 24, w, bottom + 24 + h];
  }

  /// 解析一个 JSON 对象；空串 / 数组 / 脏数据 → null。
  static Map<String, Object?>? _parseJsonObject(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return decoded.cast<String, Object?>();
    } on FormatException {
      return null;
    }
  }

  /// 照 `v2` 块树节点格式，从 `blocks` 取一块拼成待插入节点（含 children 空列表）。
  Map<String, Object?>? _blockNode(String blockId) {
    final ResultSet rs = db.select(
      'SELECT type, props_json FROM blocks WHERE id = ?',
      <Object?>[blockId],
    );
    if (rs.isEmpty) return null;
    final Object? props = _decodeProps(rs.first['props_json'] as String?);
    return <String, Object?>{
      'id': blockId,
      'type': rs.first['type'] as String,
      'data': props ?? const <String, Object?>{},
      'children': <Object?>[],
    };
  }

  String? _rawContent(String noteId) {
    final ResultSet rs = db.select(
      'SELECT content FROM notes WHERE id = ?',
      <Object?>[noteId],
    );
    return rs.isEmpty ? null : rs.first['content'] as String?;
  }

  /// 同步落盘正文 + 双写投影（与 [updateContent] 等价，但同步、不给 plain_text 重算）。
  ///
  /// 块迁移是底层操作，plain_text 仅供列表预览，下一次编辑会自动刷新，这里不纠结。
  void _persistContentSync(String noteId, String content) {
    final String hash = contentFingerprint(content);
    final int now = DateTime.now().millisecondsSinceEpoch;
    db.execute(
      'UPDATE notes SET content = ?, content_hash = ?, revised_at = ? WHERE id = ?',
      <Object?>[content, hash, now, noteId],
    );
    _blocks.replaceNoteBlocks(noteId, content);
    _canvas.replaceCanvasRows(noteId, content); // 非画布笔记 ⇒ 返回 0，无害
  }

  static Map<String, Object?>? _findNode(List<Object?> nodes, String id) {
    for (final Object? n in nodes) {
      final Map<String, Object?> node = n! as Map<String, Object?>;
      if (node['id'] == id) return node;
      final Object? kids = node['children'];
      if (kids is List<Object?>) {
        final Map<String, Object?>? hit = _findNode(kids, id);
        if (hit != null) return hit;
      }
    }
    return null;
  }

  /// 从树里摘掉 id 节点（递归）。返回是否真的摘掉了。
  static bool _removeNode(List<Object?> nodes, String id) {
    for (int i = 0; i < nodes.length; i++) {
      final Map<String, Object?> node = nodes[i]! as Map<String, Object?>;
      if (node['id'] == id) {
        nodes.removeAt(i);
        return true;
      }
      final Object? kids = node['children'];
      if (kids is List<Object?> && _removeNode(kids, id)) return true;
    }
    return false;
  }

  static Object? _decodeProps(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

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
    // 列表查询不带 content 列（块树大字段）→ 这里是 null；只有 [noteById]
    // 的完整行查询才有值。列表侧一律空串，块树正文永远走单行查询。
    content: content ?? (row['content'] as String?) ?? '',
    // 列表快照只 SELECT summary（不带 plain_text 列 ⇒ 缺失取 ''）；
    // noteById 走 SELECT *，两列都有。
    plainText: row['plain_text'] as String? ?? '',
    summary: row['summary'] as String? ?? '',
    contentHash: row['content_hash'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    revisedAt: DateTime.fromMillisecondsSinceEpoch(row['revised_at'] as int),
    promotedAt: row['promoted_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['promoted_at'] as int),
    tags: Note.parseTags(row['tags'] as String?),
  );
}
