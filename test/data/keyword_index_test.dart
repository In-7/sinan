import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/index_job.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/retriever.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 保存即索引（关键词路）与删除清理的回归。
///
/// 钉三条结构性事实：
/// ① 刚写的块**立刻可搜**（全局搜索的底线，2026-09-25 定稿）；
/// ② 整篇重写会清掉**已删块的孤儿 FTS 行**（FTS5 无外键，没人替它清）；
/// ③ 删笔记时 `chunks_fts` 行同步清空（否则出现"幽灵命中"）。
void main() {
  late Database db;
  late NoteStore notes;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    notes = NoteStore(db);
  });
  tearDown(() => db.close());

  int ftsCount(String noteId) => db
      .select('SELECT COUNT(*) AS c FROM chunks_fts WHERE note_id = ?',
          <Object?>[noteId])
      .single['c'] as int;

  /// 直插一个带文本的段落块（绕过编辑器栈；schema 见 database.dart v7）。
  void insertBlock({
    required String id,
    required String noteId,
    required String text,
  }) {
    db.execute(
      'INSERT INTO blocks (id, note_id, type, props_json, ord, parent_id, '
      'created_at, updated_at, fingerprint) '
      "VALUES (?, ?, 'paragraph', ?, 1024, NULL, 0, 0, 'fp-test')",
      <Object?>[id, noteId, jsonEncode(<String, String>{'text': text})],
    );
  }

  test('保存即索引：刚写的块立刻可搜，摘要带回原文', () async {
    final Note n = notes.create();
    insertBlock(id: 'b1', noteId: n.id, text: '番茄工作法的核心是专注二十五个分钟');

    IndexJob(db: db).indexNoteKeywordPath(n.id);

    expect(ftsCount(n.id), 1);
    final RetrievalResult r = await Retriever(db: db).search('番茄工作法');
    expect(r.hits, isNotEmpty, reason: '刚索引的块必须立刻能被关键词路搜到');
    expect(r.hits.first.noteId, n.id);
    expect(r.hits.first.snippet, contains('番茄工作法'));
  });

  test('整篇重写：清掉已删块的孤儿 FTS 行（幽灵命中修复）', () async {
    final Note n = notes.create();
    insertBlock(id: 'b1', noteId: n.id, text: '正常内容');

    // 模拟"块被删但 FTS 行没人清"的孤儿（历史遗留：按块清漏掉已删的）。
    db.execute(
      'INSERT INTO chunks_fts (search_text, block_id, note_id, chunk_text) '
      "VALUES ('yz', 'ghost-block', ?, '幽灵内容')",
      <Object?>[n.id],
    );

    IndexJob(db: db).indexNoteKeywordPath(n.id);

    expect(ftsCount(n.id), 1, reason: '只剩现存块的一行');
    final RetrievalResult r = await Retriever(db: db).search('幽灵');
    expect(
      r.hits.where((RetrievalHit h) => h.noteId == n.id),
      isEmpty,
      reason: '已删块的 FTS 行必须被整篇重写清掉',
    );
  });

  test('删除笔记：chunks_fts 行同步清空', () async {
    final Note n = notes.create();
    insertBlock(id: 'b1', noteId: n.id, text: '将被删除的内容');
    IndexJob(db: db).indexNoteKeywordPath(n.id);
    expect(ftsCount(n.id), 1);

    await notes.delete(n.id);

    expect(ftsCount(n.id), 0, reason: '删笔记必须连带清检索索引，否则幽灵命中');
  });
}
