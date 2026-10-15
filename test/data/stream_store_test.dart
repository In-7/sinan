import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/block_props.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/backlink.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 心流收件箱（stream 容器 + 块 CRUD + 单向导出）的回归。
///
/// 钉四件事：① 心流容器**不进文库**（allNotes 永不出现 kind=stream）；② 增/列**最新
/// 在上**；③ 改 / 删按块 id 定位；④ 心流块是**真块行**（归容器、带 text 投影、可被
/// 引用 / 反链认）；⑤ **单向导出**：引用（活链，块留心流）/ 注入（快照副本）/
/// 转新（消耗）三种语义各就各位。
const String _emptyBlocks =
    '{"v":2,"format":"blocks","document":{"type":"page","children":[]}}';

void main() {
  late Database db;
  late NoteStore store;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
  });

  tearDown(() => db.close());

  test('心流容器隐藏：建了心流也不进 allNotes 文库', () {
    store.addStreamItem('第一条');
    expect(
      store.allNotes().every((Note n) => n.kind != NoteKind.stream),
      isTrue,
    );
    expect(store.allNotes(), isEmpty, reason: '心流容器不算文库笔记');
    expect(store.streamContainer().kind, NoteKind.stream);
  });

  test('add / list：最新在上', () {
    store.addStreamItem('旧');
    store.addStreamItem('新');
    expect(
      store.listStreamItems().map((StreamItem i) => i.text).toList(),
      <String>['新', '旧'],
    );
  });

  test('update：改文本、位置不变；命不中返回 false', () {
    final String id = store.addStreamItem('原文');
    expect(store.updateStreamItem(id, '改后'), isTrue);
    expect(store.listStreamItems().single.text, '改后');
    expect(store.updateStreamItem('no-such-id', 'x'), isFalse);
  });

  test('delete：摘掉；命不中返回 false', () {
    final String a = store.addStreamItem('甲');
    store.addStreamItem('乙');
    expect(store.deleteStreamItem(a), isTrue);
    expect(
      store.listStreamItems().map((StreamItem i) => i.text).toList(),
      <String>['乙'],
    );
    expect(store.deleteStreamItem(a), isFalse);
  });

  test('心流块是真块行：归容器（引用 / 反链认它）', () {
    final String id = store.addStreamItem('可被引用');
    expect(store.blockNoteId(id), store.streamContainer().id);
    // 落进 blocks 投影（不是只躺在 content JSON 里）。
    expect(
      db.select('SELECT id FROM blocks WHERE id = ?', <Object?>[id]),
      isNotEmpty,
    );
  });

  group('心流导出（单向：心流 → 笔记）', () {
    test('心流块带 text 投影：blockText 读得到（画布引用 / 搜索的前置）', () {
      final String id = store.addStreamItem('双投影');
      expect(
        store.blockText(id),
        '双投影',
        reason: '心流段落块必须同时带 text，否则画布引用 / 搜索拿到空串',
      );
    });

    test('引用到笔记：插 ref 块（活链）——块留心流、反链记账、幂等', () {
      final String id = store.addStreamItem('可被引用');
      final Note target = store.createSpark(
        kind: NoteKind.note,
        content: _emptyBlocks,
        plainText: '',
      );

      expect(store.referenceStreamBlockInNote(id, target.id), isTrue);
      // 引用不消耗：心流条目还在。
      expect(store.listStreamItems().map((StreamItem i) => i.id), contains(id));
      // 反链认这笔引用（source = 目标笔记）。
      final List<Backlink> links = store.backlinks(store.streamContainer().id);
      expect(
        links.map((Backlink b) => b.sourceNoteId),
        contains(target.id),
        reason: 'ref 块要让心流块的反链出现目标笔记',
      );
      // 幂等：再引一次不重复插。
      expect(store.referenceStreamBlockInNote(id, target.id), isFalse);
    });

    test('注入到笔记：复制成真段落块（快照）——块留心流', () {
      final String id = store.addStreamItem('注入我');
      final Note target = store.createSpark(
        kind: NoteKind.note,
        content: _emptyBlocks,
        plainText: '',
      );

      expect(store.injectStreamBlockInNote(id, target.id), isTrue);
      // 快照副本：心流条目不动。
      expect(store.listStreamItems().map((StreamItem i) => i.id), contains(id));
      // 目标里多了一个真段落块，文本一致。
      final List<Row> rows = db.select(
        'SELECT props_json FROM blocks WHERE note_id = ?',
        <Object?>[target.id],
      );
      expect(rows, hasLength(1));
      expect(textOfProps(rows.first['props_json'] as String?), '注入我');
    });

    test('转成新笔记：建正式笔记装上文本 + 心流条目消失（消耗）', () {
      final String id = store.addStreamItem('转我');
      final Note? created = store.streamBlockToNewNote(id);

      expect(created, isNotNull);
      expect(created!.kind, NoteKind.note);
      // 消耗：心流里没了。
      expect(
        store.listStreamItems().map((StreamItem i) => i.id),
        isNot(contains(id)),
      );
      // 新笔记进文库、正文落了块（带 text 投影）。
      expect(store.allNotes().map((Note n) => n.id), contains(created.id));
      final List<Row> rows = db.select(
        'SELECT props_json FROM blocks WHERE note_id = ?',
        <Object?>[created.id],
      );
      expect(textOfProps(rows.first['props_json'] as String?), '转我');
    });

    test('画布 / 心流不当文档目标：引用 / 注入都拒绝', () {
      final String id = store.addStreamItem('x');
      final Note canvas = store.create(kind: NoteKind.canvas);
      expect(store.referenceStreamBlockInNote(id, canvas.id), isFalse);
      expect(store.injectStreamBlockInNote(id, canvas.id), isFalse);
      // 心流容器自己也不能当目标（单向：心流 → 心流无意义）。
      expect(
        store.referenceStreamBlockInNote(id, store.streamContainer().id),
        isFalse,
      );
    });
  });
}
