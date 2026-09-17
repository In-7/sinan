import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 双写阶段（迁移第 2、3 步）的回归。
///
/// 真正要钉住的不是"能不能写进去"，而是**拆块到底有没有换来增量**：
/// 1. 改一个块 → 只重写那一块（其它块的 `created_at` 必须纹丝不动）；
/// 2. 只挪位置 / 只换父节点 → 也要落（位置变了但内容没变同样要写）；
/// 3. 存量笔记能回填，且**可续跑**（有上限、非 v2 格式跳过、**画布笔记不占名额**）。
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

  /// 造一篇 v2 块树（结构照 `NoteDocumentAdapter` 的写出格式）。
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

  List<Row> rows() => db.select('SELECT * FROM blocks ORDER BY ord').toList();

  test('扁平化：嵌套块得到正确的 ord / parent，根节点不入表', () async {
    final Note note = store.create(content: v2(<Map<String, Object?>>[
      block('b1', 'paragraph', data: <String, Object?>{'text': '一'}),
      block('b2', 'bulleted_list', children: <Map<String, Object?>>[
        block('b2c1', 'paragraph', data: <String, Object?>{'text': '子'}),
      ]),
      block('b3', 'paragraph', data: <String, Object?>{'text': '三'}),
    ]));
    await store.updateContent(note.id, note.content, plainText: '一\n子\n三');

    final List<Row> r = rows();
    expect(r.map((Row e) => e['id']).toList(), <String>['b1', 'b2', 'b2c1', 'b3']);
    // 文档顺序而非层级顺序（先父后子）。
    expect(r[0]['ord'], 0);
    expect(r[1]['ord'], 1024);
    expect(r[2]['ord'], 2048);
    expect(r[3]['ord'], 3072);
    // 根的直挂块 parent 为 null；子块指向父块。
    expect(r[0]['parent_id'], isNull);
    expect(r[2]['parent_id'], 'b2');
    // 根节点（文档容器）不应成为一行。
    expect(r.map((Row e) => e['id']), isNot(contains('root')));
    // 块身份沿用 v2 里的 id（这是将来 AI 索引不重建的前提）。
    expect(r[2]['id'], 'b2c1');
  });

  test('增量：改一个块只重写那一行，其余 created_at 不变', () async {
    final Note note = store.create(content: v2(<Map<String, Object?>>[
      block('b1', 'paragraph', data: <String, Object?>{'text': '一'}),
      block('b2', 'paragraph', data: <String, Object?>{'text': '二'}),
      block('b3', 'paragraph', data: <String, Object?>{'text': '三'}),
    ]));
    await store.updateContent(note.id, note.content, plainText: '一\n二\n三');
    final Map<String, int> before = <String, int>{
      for (final Row r in rows()) r['id'] as String: r['created_at'] as int,
    };

    // 只改中间那块的文字。
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await store.updateContent(
      note.id,
      v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '一'}),
        block('b2', 'paragraph', data: <String, Object?>{'text': '二改'}),
        block('b3', 'paragraph', data: <String, Object?>{'text': '三'}),
      ]),
      plainText: '一\n二改\n三',
    );

    final Map<String, int> after = <String, int>{
      for (final Row r in rows()) r['id'] as String: r['created_at'] as int,
    };
    // 没动的两块：created_at 原样保留（UPSERT 不覆盖它）⇒ 没被重写。
    expect(after['b1'], before['b1']);
    expect(after['b3'], before['b3']);
    // 动了的那块：updated_at 推进。
    final Row changed = db.select(
      "SELECT updated_at, props_json FROM blocks WHERE id = 'b2'",
    ).single;
    expect(changed['props_json'], contains('二改'));
    expect(changed['updated_at'] as int, greaterThan(before['b2']!));
  });

  test('只挪位置也要落盘（ord 变了但内容没变）', () async {
    final Note note = store.create(content: v2(<Map<String, Object?>>[
      block('b1', 'paragraph'),
      block('b2', 'paragraph'),
    ]));
    await store.updateContent(note.id, note.content, plainText: 'x');

    // 交换顺序：内容一字未改，但 ord 变了。
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await store.updateContent(
      note.id,
      v2(<Map<String, Object?>>[block('b2', 'paragraph'), block('b1', 'paragraph')]),
      plainText: 'x',
    );

    final List<Row> r = rows();
    expect(r.first['id'], 'b2');
    expect(r.last['id'], 'b1');
  });

  test('删掉的块从 blocks 里消失；父块被删则子块级联', () async {
    final Note note = store.create(content: v2(<Map<String, Object?>>[
      block('b1', 'paragraph'),
      block('b2', 'paragraph', children: <Map<String, Object?>>[
        block('b2c1', 'paragraph'),
      ]),
    ]));
    await store.updateContent(note.id, note.content, plainText: 'x');

    await store.updateContent(
      note.id,
      v2(<Map<String, Object?>>[block('b1', 'paragraph')]),
      plainText: 'x',
    );
    // b2 被删；b2c1 靠外键级联一起走。
    expect(rows().map((Row e) => e['id']), <String>['b1']);
  });

  test('非 v2 内容（存量 Delta）不投影，也不报错', () async {
    final Note note = store.create(content: '[{"insert":"老数据\\n"}]');
    await store.updateContent(note.id, '[{"insert":"老数据\\n"}]', plainText: '老数据');

    expect(rows(), isEmpty);
    // 但正文照旧落库（旧列仍是真相源）。
    expect(db.select('SELECT content FROM notes').single['content'],
        '[{"insert":"老数据\\n"}]');
  });

  test('回填：存量笔记补齐且可续跑（limit 生效、跳过非 v2）', () async {
    // 三条存量：两条 v2、一条 Delta。
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES (?,?,?,?,?,?,?,?)",
      <Object?>['n1', 'note', '', v2(<Map<String, Object?>>[block('b1', 'paragraph')]), 'fp1:1:1', '', 1, 1],
    );
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES (?,?,?,?,?,?,?,?)",
      <Object?>['n2', 'note', '', v2(<Map<String, Object?>>[block('b2', 'paragraph')]), 'fp1:1:2', '', 2, 2],
    );
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES (?,?,?,?,?,?,?,?)",
      <Object?>['n3', 'note', '', '[{"insert":"delta\\n"}]', 'fp1:1:3', '', 3, 3],
    );

    // 上限 1 ⇒ 一次只处理一篇（可续跑）。
    expect(store.backfillBlocks(limit: 1), 1);
    expect(db.select('SELECT COUNT(*) AS c FROM blocks').single['c'], 1);

    // 剩下的：n2 补齐、n3 是 Delta 跳过（**跳过的不计数**）。
    expect(store.backfillBlocks(), 1);
    expect(
      db.select('SELECT note_id FROM blocks ORDER BY note_id').map((Row r) => r['note_id']).toSet(),
      <String>{'n1', 'n2'},
    );

    // 再跑一次：只剩 n3 这个永远投影不了的老格式 ⇒ 返回 0、且不重复写。
    expect(store.backfillBlocks(), 0);
    expect(db.select('SELECT COUNT(*) AS c FROM blocks').single['c'], 2);
  });

  test('回填名额不被画布笔记占用（它们永远没有 blocks 行，会被反复扫）', () {
    // 画布笔记的正文**永远不是** v2 块树（是画布 JSON），所以它永远没有 blocks 行；
    // 而回填候选的判据正是"这篇笔记还没有 blocks 行" ⇒ 画布会被**每次启动**反复选中、
    // 解析一遍再跳过，白占 `limit` 名额，把真正待回填的文档挤掉（2026-09-17 修）。
    //
    // ⚠️ 全部走**裸 INSERT**：`store.create` 会立刻双写 blocks，造不出"存量未回填"
    // 的现场——而 `backfill` 处理的正是那种现场。
    void legacy(String id, String kind, String content, int ts) {
      db.execute(
        'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
        'created_at, revised_at) VALUES (?,?,?,?,?,?,?,?)',
        <Object?>[id, kind, '', content, 'fp1:1:$id', '', ts, ts],
      );
    }

    for (int i = 0; i < 3; i++) {
      legacy(
        'c$i',
        'canvas',
        '{"camera":{"scale":1},"document":{"schemaVersion":2}}',
        10 + i,
      );
    }
    // 两种文档 kind 都放：spark 是新建笔记的默认形态，过滤条件若写成白名单
    // `kind = 'note'` 就会整类漏掉（这条断言就是拦这个的）。
    legacy('s1', 'spark', v2(<Map<String, Object?>>[block('s1b', 'paragraph')]), 20);
    legacy('n1', 'note', v2(<Map<String, Object?>>[block('n1b', 'paragraph')]), 21);

    // 名额恰好 = 画布数：若画布进了候选集，这一轮会被它们占满、一条文档都回填不上。
    expect(store.backfillBlocks(limit: 3), 2);
    expect(
      db
          .select('SELECT note_id FROM blocks')
          .map((Row r) => r['note_id'])
          .toSet(),
      <String>{'s1', 'n1'},
      reason: '画布占用了回填名额：待回填的文档被挤掉（每次启动还白解析一遍画布）',
    );
  });

  test('删笔记时 blocks 随外键级联清空', () async {
    final Note note = store.create(content: v2(<Map<String, Object?>>[
      block('b1', 'paragraph'),
    ]));
    await store.updateContent(note.id, note.content, plainText: 'x');
    expect(rows(), hasLength(1));

    await store.delete(note.id);
    expect(rows(), isEmpty);
  });
}
