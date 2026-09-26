import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// v12 迁移与标签读写的回归：`notes.tags` 单列 JSON 数组（方案 A）。
///
/// 钉四条：
/// ① 迁移幂等前进，列带默认 `'[]'`；
/// ② `updateTags` 归一化（trim / 丢空 / 去重）且**不动 revised_at**（整理
///    元数据不该把笔记顶到"最近修改"最前，同 `setPromoted` 的口径）；
/// ③ `restore` 必须带上 tags——漏了它 `INSERT OR REPLACE` 用列默认覆盖，
///    "撤销一次删除，标签静默清空"（这个坑就写在 store 的注释里）；
/// ④ `parseTags` 对脏数据免疫（标签是装饰元数据，解析失败不许把整篇读挂）。
void main() {
  Database openMigrated() {
    final Database db = sqlite3.openInMemory();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    return db;
  }

  test('v12：userVersion 前进到 12，notes.tags 列存在且默认 []', () {
    final Database db = openMigrated();
    expect(db.userVersion, greaterThanOrEqualTo(12));

    final List<Map<String, Object?>> cols = <Map<String, Object?>>[
      for (final Row r in db.select('PRAGMA table_info(notes)'))
        <String, Object?>{
          'name': r['name'] as String,
          'dflt': r['dflt_value'],
        },
    ];
    expect(
      cols.where((Map<String, Object?> c) => c['name'] == 'tags'),
      hasLength(1),
      reason: 'v12 必须给 notes 补 tags 列',
    );
    expect(
      cols.singleWhere((Map<String, Object?> c) => c['name'] == 'tags')['dflt'],
      contains('[]'),
      reason: '默认空数组：新建笔记天然无标签',
    );
  });

  test('updateTags：归一化（trim/丢空/去重）且不动 revised_at', () async {
    final Database db = openMigrated();
    final NoteStore store = NoteStore(db);
    final Note note = store.create(title: '工作法');

    final DateTime before = store.allNotes().single.revisedAt;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await store.updateTags(note.id, <String>[' 工作法 ', '', '深度', '工作法']);

    final Note after = store.allNotes().single;
    expect(after.tags, <String>['工作法', '深度'], reason: '去空/去重/保序');
    expect(after.revisedAt, before, reason: '整理元数据不动 revised_at');
    // 完整行（noteById）同样带出标签。
    expect(store.noteById(note.id)!.tags, <String>['工作法', '深度']);
  });

  test('restore：撤销删除后标签还在（INSERT OR REPLACE 不许用默认覆盖）', () async {
    final Database db = openMigrated();
    final NoteStore store = NoteStore(db);
    final Note note = store.create(title: '带标签的笔记');
    await store.updateTags(note.id, <String>['重要']);

    final Note full = store.noteById(note.id)!;
    await store.delete(note.id);
    expect(store.allNotes(), isEmpty);

    await store.restore(full);
    expect(store.allNotes().single.tags, <String>['重要'],
        reason: 'restore 漏带 tags 列 ⇒ 撤销一次删除标签就清空');
  });

  test('parseTags：脏数据免疫（非 JSON / 非数组 / 非字符串元素）', () {
    expect(Note.parseTags(null), isEmpty);
    expect(Note.parseTags(''), isEmpty);
    expect(Note.parseTags('not-json'), isEmpty);
    expect(Note.parseTags('{"a":1}'), isEmpty, reason: '对象不是数组');
    expect(Note.parseTags('[1,null,"a"," a "]'), <String>['a'],
        reason: '非字符串元素丢弃，字符串照常归一化');
  });
}
