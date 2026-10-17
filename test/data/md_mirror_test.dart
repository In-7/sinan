import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sinan/src/data/block_store.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/markdown/md_mirror.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/stream_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// Markdown **单向镜像**：导出 / 幂等 / 改名 / 撞名 / 不导形态 / 存量兜底 / 删除。
void main() {
  late Database db;
  late NoteStore store;
  late BlockStore blocks;
  late MdMirror mirror;
  late Directory tmp;

  int seq = 0;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
    blocks = BlockStore(db);
    mirror = MdMirror(db);
    tmp = Directory.systemTemp.createTempSync('sinan_md_');
  });

  tearDown(() {
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String doc(List<Object?> children) => jsonEncode(<String, Object?>{
    'v': 2,
    'format': 'blocks',
    'document': <String, Object?>{
      'id': 'root',
      'type': 'page',
      'children': children,
    },
  });

  Map<String, Object?> para(String text) => <String, Object?>{
    'id': 'b${seq++}',
    'type': 'paragraph',
    'data': <String, Object?>{
      'delta': <Object?>[
        <String, Object?>{'insert': text},
      ],
    },
  };

  /// 引用块节点（`type='ref'`）。属性名与 `RefBlockKeys` 一致。
  Map<String, Object?> ref(
    String refId, {
    String refType = 'note',
    String view = 'link',
  }) => <String, Object?>{
    'id': 'b${seq++}',
    'type': 'ref',
    'data': <String, Object?>{
      'ref_type': refType,
      'ref_id': refId,
      'ref_view': view,
    },
  };

  /// 造一篇带块树的笔记（body 会进 paragraph 块）。
  Note makeNote(String title, {String body = '正文'}) {
    final Note n = store.create(title: title);
    blocks.replaceNoteBlocks(n.id, doc(<Object?>[para(body)]));
    return n;
  }

  List<String> fileNames() =>
      tmp.listSync().map((FileSystemEntity e) => p.basename(e.path)).toList();

  test('导出单篇：YAML 头 + H1 + 正文落盘，账本记行', () {
    final Note n = makeNote('会议纪要', body: '讨论了架构');
    expect(mirror.exportOne(n.id, dir: tmp.path), isTrue);

    final File f = File(p.join(tmp.path, '会议纪要.md'));
    expect(f.existsSync(), isTrue);
    final String md = f.readAsStringSync();
    expect(md, contains('id: ${n.id}'));
    expect(md, contains('# 会议纪要'));
    expect(md, contains('讨论了架构'));

    final List<Map<String, Object?>> rows = db
        .select('SELECT path, revised_at FROM md_mirror WHERE note_id = ?', <Object?>[n.id])
        .map((row) => <String, Object?>{
              'path': row['path'],
              'revised_at': row['revised_at'],
            })
        .toList();
    expect(rows, hasLength(1));
    expect(rows.first['path'], f.path);
  });

  test('幂等：revised_at 未变 ⇒ 再扫不重导', () {
    makeNote('甲');
    expect(mirror.exportPending(dir: tmp.path), 1);
    expect(mirror.exportPending(dir: tmp.path), 0, reason: '没变就不该重写');
  });

  test('revised_at 变新 ⇒ 重新导出（内容跟着更新）', () {
    final Note n = makeNote('甲', body: '旧文');
    mirror.exportOne(n.id, dir: tmp.path);
    blocks.replaceNoteBlocks(n.id, doc(<Object?>[para('新文')]));
    db.execute('UPDATE notes SET revised_at = revised_at + 1000 WHERE id = ?', <Object?>[n.id]);

    expect(mirror.exportPending(dir: tmp.path), 1);
    expect(
      File(p.join(tmp.path, '甲.md')).readAsStringSync(),
      contains('新文'),
    );
  });

  test('标题改名 ⇒ 旧文件删、新文件在（等同改名）', () {
    final Note n = makeNote('旧名');
    mirror.exportOne(n.id, dir: tmp.path);
    expect(File(p.join(tmp.path, '旧名.md')).existsSync(), isTrue);

    db.execute(
      'UPDATE notes SET title = ?, revised_at = revised_at + 1000 WHERE id = ?',
      <Object?>['新名', n.id],
    );
    expect(mirror.exportPending(dir: tmp.path), 1);
    expect(File(p.join(tmp.path, '旧名.md')).existsSync(), isFalse);
    expect(File(p.join(tmp.path, '新名.md')).existsSync(), isTrue);
  });

  test('同名两篇 ⇒ 一篇占 <标题>.md，另一篇退 <标题> <id8>.md', () {
    makeNote('会议');
    makeNote('会议');
    expect(mirror.exportPending(dir: tmp.path), 2);

    final List<String> names = fileNames();
    expect(names, contains('会议.md'));
    expect(
      names.where((String s) => RegExp(r'^会议 [0-9a-f]{8}\.md$').hasMatch(s)),
      hasLength(1),
      reason: '撞名那篇带 8 位 id 后缀',
    );
    expect(names, hasLength(2));
  });

  test('画布不导；速记也不导（它不在 notes 里，天然看不见）', () {
    final Note canvas = store.create(kind: NoteKind.canvas, title: '画布');
    // v16 起速记是独立表（`stream_items`），不在 `notes` ⇒ 镜像连扫都扫不到。
    StreamStore(db).add('一条速记');
    expect(mirror.exportPending(dir: tmp.path), 0);
    expect(tmp.listSync(), isEmpty);
    expect(mirror.exportOne(canvas.id, dir: tmp.path), isFalse);
  });

  test('没有块行的存量笔记 ⇒ plain_text 兜底导出', () {
    final Note n = store.create(title: '老笔记');
    db.execute('UPDATE notes SET plain_text = ? WHERE id = ?', <Object?>[
      '第一段\n第二段',
      n.id,
    ]);
    expect(mirror.exportOne(n.id, dir: tmp.path), isTrue);
    final String md = File(p.join(tmp.path, '老笔记.md')).readAsStringSync();
    expect(md, contains('# 老笔记'));
    expect(md, contains('第一段'));
  });

  test('删笔记：先清镜像文件，CASCADE 再清账本行', () async {
    final Note n = makeNote('要删的');
    mirror.exportOne(n.id, dir: tmp.path);
    final File f = File(p.join(tmp.path, '要删的.md'));
    expect(f.existsSync(), isTrue);

    mirror.removeForNote(n.id);
    await store.delete(n.id);
    expect(f.existsSync(), isFalse);
    expect(
      db.select('SELECT 1 FROM md_mirror WHERE note_id = ?', <Object?>[n.id]),
      isEmpty,
    );
  });

  test('文件名消毒：非法字符换空格、空标题落「未命名」', () {
    final Note odd = makeNote('a/b:c*?');
    mirror.exportOne(odd.id, dir: tmp.path);
    expect(fileNames(), contains('a b c.md'));

    final Note empty = store.create();
    mirror.exportOne(empty.id, dir: tmp.path);
    expect(fileNames(), contains('未命名.md'));
  });

  // ── 引用块 → wikilink（边早已在库里，导出只做投影）─────────────────────

  test('引用另一篇笔记 ⇒ 导出 [[文件名]]（与镜像文件名同口径）', () {
    final Note target = makeNote('目标/a');
    final Note src = store.create(title: '引用方');
    blocks.replaceNoteBlocks(
      src.id,
      doc(<Object?>[para('见下：'), ref(target.id)]),
    );
    expect(mirror.exportOne(src.id, dir: tmp.path), isTrue);

    final String md = File(p.join(tmp.path, '引用方.md')).readAsStringSync();
    // `目标/a` 的文件名被消毒成 `目标 a`：链接目标必须跟着走，否则 Obsidian 解析不到。
    expect(md, contains('[[目标 a]]'));
  });

  test('ref_view=embed ⇒ 导出 ![[文件名]]', () {
    final Note target = makeNote('嵌入目标');
    final Note src = store.create(title: '嵌入方');
    blocks.replaceNoteBlocks(
      src.id,
      doc(<Object?>[ref(target.id, view: 'embed')]),
    );
    mirror.exportOne(src.id, dir: tmp.path);
    expect(
      File(p.join(tmp.path, '嵌入方.md')).readAsStringSync(),
      contains('![[嵌入目标]]'),
    );
  });

  test('块引用 ⇒ 链接到它所属的笔记（与编辑器同一口径）', () {
    final Note target = makeNote('所属笔记');
    final String blockId =
        db
                .select(
                  'SELECT id FROM blocks WHERE note_id = ? LIMIT 1',
                  <Object?>[target.id],
                )
                .first['id']
            as String;
    final Note src = store.create(title: '块引用方');
    blocks.replaceNoteBlocks(
      src.id,
      doc(<Object?>[ref(blockId, refType: 'block')]),
    );
    mirror.exportOne(src.id, dir: tmp.path);
    expect(
      File(p.join(tmp.path, '块引用方.md')).readAsStringSync(),
      contains('[[所属笔记]]'),
    );
  });

  test('引用已删目标 ⇒ 落「引用已失效（id8）」，不静默丢块', () {
    const String gone = 'deadbeef-1111-4111-8111-111111111111';
    final Note src = store.create(title: '断链方');
    blocks.replaceNoteBlocks(src.id, doc(<Object?>[ref(gone)]));
    mirror.exportOne(src.id, dir: tmp.path);
    final String md = File(p.join(tmp.path, '断链方.md')).readAsStringSync();
    expect(md, contains('引用已失效（deadbeef）'));
    expect(md, isNot(contains('[[')), reason: '死链不写进 Obsidian 图谱');
  });

  test('引用画布 ⇒ 纯文本 + 形态后缀，不造死链', () {
    final Note canvas = store.create(kind: NoteKind.canvas, title: '某画布');
    final Note src = store.create(title: '画布引用方');
    blocks.replaceNoteBlocks(src.id, doc(<Object?>[ref(canvas.id)]));
    mirror.exportOne(src.id, dir: tmp.path);
    final String md = File(p.join(tmp.path, '画布引用方.md')).readAsStringSync();
    expect(md, contains('某画布（画布）'));
    expect(md, isNot(contains('[[')));
  });

  test('空标题目标 ⇒ [[未命名]]（与文件名同口径）', () {
    final Note target = store.create();
    final Note src = store.create(title: '空目标方');
    blocks.replaceNoteBlocks(src.id, doc(<Object?>[ref(target.id)]));
    mirror.exportOne(src.id, dir: tmp.path);
    expect(
      File(p.join(tmp.path, '空目标方.md')).readAsStringSync(),
      contains('[[未命名]]'),
    );
  });

  test('后台导出（另开连接）：增量 0 篇、全量重写', () async {
    // 内存库没有路径，后台 worker 要 open(path) ⇒ 本用例单独开一个文件库。
    final String dbPath = p.join(tmp.path, 'mirror.db');
    final Database fileDb = sqlite3.open(dbPath);
    AppDatabase.migrateForTesting(fileDb);
    fileDb.execute('PRAGMA foreign_keys = ON;');
    final NoteStore s = NoteStore(fileDb);
    final BlockStore b = BlockStore(fileDb);
    final Note n = s.create(title: '后台甲');
    b.replaceNoteBlocks(n.id, doc(<Object?>[para('后台正文')]));
    fileDb.close();

    final String bg = p.join(tmp.path, 'bg');
    expect(
      await MdMirror.exportPendingInBackground(dbPath: dbPath, dir: bg),
      1,
    );
    expect(File(p.join(bg, '后台甲.md')).existsSync(), isTrue);

    // 账本已落 ⇒ 第二轮没有改动；强制全量仍重写一次。
    expect(
      await MdMirror.exportPendingInBackground(dbPath: dbPath, dir: bg),
      0,
    );
    expect(
      await MdMirror.exportPendingInBackground(
        dbPath: dbPath,
        dir: bg,
        all: true,
      ),
      1,
    );
  });

  test('目录解析：空覆盖 ⇒ 应用数据目录下的默认子目录', () {
    expect(MdMirror.resolveDir(r'C:\data', ''), p.join(r'C:\data', 'markdown-mirror'));
    expect(MdMirror.resolveDir(r'C:\data', r'D:\vault'), r'D:\vault');
    expect(MdMirror.resolveDir(r'C:\data', '   '), p.join(r'C:\data', 'markdown-mirror'));
  });
}
