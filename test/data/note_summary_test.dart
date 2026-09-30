import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// `summary` 投影列（v13）写读路径的回归。
///
/// 钉的是"快照变轻"这条不变量：
/// 1. 保存正文时 summary 与 plain_text **同步写入**（前 160 字截断）；
/// 2. 列表快照 [NoteStore.allNotes] 只背 summary、plain_text 留空（调用方
///    误读 plainText 就会拿到空串——卡片因此改读 summary）；
/// 3. 整篇纯文本仍可经 [NoteStore.plainTextOf] / [NoteStore.noteById] 取到；
/// 4. 删除撤销（[NoteStore.restore]）不丢 summary。
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

  test('保存：summary 随 plain_text 同步截断；快照只背 summary', () async {
    final Note n = store.create(title: '长文');
    final String full = '第${'一二三四五六七八九' * 200}段'; // 远超 160 字
    expect(full.length, greaterThan(Note.summaryLength));

    expect(await store.updateContent(n.id, '正文-v2', plainText: full), isTrue);

    final Note snap = store.allNotes().singleWhere((Note x) => x.id == n.id);
    expect(snap.summary, Note.summarize(full));
    expect(snap.summary.length, Note.summaryLength);
    // 列表快照刻意不 SELECT plain_text ⇒ 空串，而不是原文。
    expect(snap.plainText, '');

    // 整篇纯文本依旧可取（窄查询 / 完整行两条路）。
    expect(store.plainTextOf(n.id), full);
    final Note? fullNote = store.noteById(n.id);
    expect(fullNote!.plainText, full);
    expect(fullNote.summary, Note.summarize(full));
  });

  test('短文本不截断', () async {
    final Note n = store.create();
    await store.updateContent(n.id, 'c', plainText: '只有短短一句');
    final Note snap = store.allNotes().singleWhere((Note x) => x.id == n.id);
    expect(snap.summary, '只有短短一句');
  });

  test('撤销删除：summary 原样回到快照', () async {
    final Note n = store.create(title: '可撤销');
    await store.updateContent(n.id, 'c', plainText: '撤销前写下的正文');
    final Note before = store.allNotes().singleWhere((Note x) => x.id == n.id);
    expect(before.summary, '撤销前写下的正文');

    await store.delete(n.id);
    expect(store.allNotes(), isEmpty);

    await store.restore(before);
    final Note after = store.allNotes().singleWhere((Note x) => x.id == n.id);
    expect(after.summary, '撤销前写下的正文');
    expect(after.title, '可撤销');
  });
}
