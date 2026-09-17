import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/block_store.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 迁移第 4、5 步：**校验 + 切读**。
///
/// 切读是这次迁移里唯一"能直接毁掉用户内容"的一步，所以它的验收标准
/// 不是"能读回来"，而是三件事：
/// 1. **还原必须与原始块树结构等价**（数组顺序也算）；
/// 2. 校验不通过时**必须静默回退**旧列，而不是交出一个残缺文档；
/// 3. 编辑器读到的正文，块 id 与顺序都要和保存时一致（否则引用会漂）。
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

  String v2(List<Map<String, Object?>> children) => jsonEncode(<String, Object?>{
        'v': 2,
        'format': 'blocks',
        'document': <String, Object?>{
          'id': 'root',
          'type': 'page',
          'children': children,
        },
      });

  Map<String, Object?> block(
    String id,
    String type, {
    Map<String, Object?> data = const <String, Object?>{},
    List<Map<String, Object?>> children = const <Map<String, Object?>>[],
  }) =>
      <String, Object?>{
        'id': id,
        'type': type,
        'data': data,
        if (children.isNotEmpty) 'children': children,
      };

  Future<Note> save(String content) async {
    final Note note = store.create(content: content);
    await store.updateContent(note.id, content, plainText: 'x');
    return note;
  }

  test('还原结果与原始块树结构等价（含 children 顺序）', () async {
    const String content = '''
{"v":2,"format":"blocks","document":{"id":"root","type":"page","children":[
  {"id":"b1","type":"paragraph","data":{"text":"一"}},
  {"id":"b2","type":"bulleted_list","data":{"level":1},"children":[
    {"id":"b2c1","type":"paragraph","data":{"text":"子1"}},
    {"id":"b2c2","type":"paragraph","data":{"text":"子2"}}
  ]},
  {"id":"b3","type":"divider","data":{}}
]}}''';
    final Note note = await save(content);

    final BlockStore blocks = BlockStore(db);
    final String? rebuilt = blocks.readNoteDocument(note.id);
    expect(rebuilt, isNotNull);

    final Map<String, Object?> originalDoc =
        (jsonDecode(content) as Map<String, Object?>)['document']! as Map<String, Object?>;
    final Map<String, Object?> rebuiltDoc =
        (jsonDecode(rebuilt!) as Map<String, Object?>)['document']! as Map<String, Object?>;
    expect(rebuiltDoc, equals(originalDoc));

    // 校验本身也要通过。
    expect(blocks.verifyNoteBlocks(note.id, content), isTrue);
  });

  test('切读：noteById 返回从 blocks 还原的正文，块 id 与顺序不变', () async {
    final Note saved = await save(v2(<Map<String, Object?>>[
      block('b1', 'paragraph', data: <String, Object?>{'text': '一'}),
      block('b2', 'paragraph', data: <String, Object?>{'text': '二'}),
    ]));

    final Note? loaded = store.noteById(saved.id);
    expect(loaded, isNotNull);
    final Map<String, Object?> doc =
        (jsonDecode(loaded!.content) as Map<String, Object?>)['document']! as Map<String, Object?>;
    final List<Object?> children = doc['children']! as List<Object?>;
    expect(
      children.map((Object? c) => ((c! as Map<String, Object?>)['id']) as String).toList(),
      <String>['b1', 'b2'],
    );
    expect(
      ((children[1]! as Map<String, Object?>)['data']! as Map<String, Object?>)['text'],
      '二',
    );
  });

  test('校验不过时静默回退旧列（不交出残缺文档）', () async {
    const String content = '''
{"v":2,"format":"blocks","document":{"id":"root","type":"page","children":[
  {"id":"b1","type":"paragraph","data":{"text":"一"}}
]}}''';
    final Note note = await save(content);

    // 人为破坏：删掉 blocks 里的一行（模拟回填不完整 / 双写漏了一块）。
    db.execute("DELETE FROM blocks WHERE id = 'b1'");
    // 只剩空集 ⇒ 没有块可读 ⇒ 必须回退。
    expect(store.noteById(note.id)?.content, content);

    // 另一种破坏：块还在，但被改成对不上的内容 ⇒ 校验失败 ⇒ 同样回退。
    await save(content);
    db.execute(
      "UPDATE blocks SET props_json = '{\"text\":\"被改坏了\"}' WHERE id = 'b1'",
    );
    expect(store.noteById(note.id)?.content, content);
    expect(BlockStore(db).verifyNoteBlocks(note.id, content), isFalse);
  });

  test('老格式 / 未回填的笔记：读路径不受影响', () async {
    const String delta = '[{"insert":"老数据\\n"}]';
    final Note note = store.create(content: delta);
    await store.updateContent(note.id, delta, plainText: '老数据');

    // blocks 里没有它的行 ⇒ 回退旧列，正文一字不差。
    expect(store.noteById(note.id)?.content, delta);
  });

  test('往返稳定：读出来再存一次，不该产生新的写入', () async {
    final Note saved = await save(v2(<Map<String, Object?>>[
      block('b1', 'paragraph', data: <String, Object?>{'text': '一'}),
    ]));

    final Note? loaded = store.noteById(saved.id);
    final int before = db.select("SELECT updated_at AS t FROM blocks WHERE id = 'b1'").single['t'] as int;

    await Future<void>.delayed(const Duration(milliseconds: 5));
    // 用读出来的正文再存一次（编辑器的典型行为：打开 → 立刻保存）。
    await store.updateContent(saved.id, loaded!.content, plainText: '一');

    // 内容没变 ⇒ 整篇判变直接挡住，连 blocks 都不该动。
    final int after = db.select("SELECT updated_at AS t FROM blocks WHERE id = 'b1'").single['t'] as int;
    expect(after, before);
  });
}
