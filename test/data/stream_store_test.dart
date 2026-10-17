import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/block_props.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/stream_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 速记（心流）独立存储 + 单向导出 + v16 迁移的回归。
///
/// 2026-10-17 起速记不再借笔记的壳：它有独立表 `stream_items`，与
/// `notes` / `blocks` **无外键**。这里钉五件事：
/// ① CRUD / 归档（不删）；② 与笔记数据互不渗漏；③ 三种导出各自的语义
/// （引用=单向活链、复制=快照、转新=归档）；④ 画布只复制不做活链；
/// ⑤ 旧容器（kind='stream' + 段落块）迁移后：条目在、引用不断、容器消失。
const String _emptyBlocks =
    '{"v":2,"format":"blocks","document":{"type":"page","children":[]}}';

void main() {
  late Database db;
  late NoteStore store;
  late StreamStore stream;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
    stream = StreamStore(db);
  });

  tearDown(() => db.close());

  group('存储（独立表）', () {
    test('add / list：最新在上；空白文本拒绝', () {
      expect(stream.add('   '), isNull);
      final StreamItem? a = stream.add('旧');
      final StreamItem? b = stream.add('新');
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(
        stream.list().map((StreamItem i) => i.text).toList(),
        <String>['新', '旧'],
      );
    });

    test('update：改文本、创建时间不动；命不中返回 false', () {
      final StreamItem item = stream.add('原文')!;
      expect(stream.update(item.id, '改后'), isTrue);
      final StreamItem after = stream.list().single;
      expect(after.text, '改后');
      expect(
        after.createdAt.millisecondsSinceEpoch,
        item.createdAt.millisecondsSinceEpoch,
        reason: '位置由"记下来的时刻"决定',
      );
      expect(stream.update('no-such-id', 'x'), isFalse);
    });

    test('archive：默认列表不再返回，可回看、可拿回、不删行', () {
      final StreamItem item = stream.add('要归档')!;
      expect(stream.archive(item.id), isTrue);
      expect(stream.list(), isEmpty);
      expect(
        stream.list(includeArchived: true).map((StreamItem i) => i.id),
        contains(item.id),
      );
      expect(stream.byId(item.id)!.archived, isTrue);
      expect(stream.unarchive(item.id), isTrue);
      expect(stream.list().single.id, item.id);
      expect(stream.archive('no-such-id'), isFalse);
    });

    test('remove：真删', () {
      final StreamItem item = stream.add('删我')!;
      expect(stream.remove(item.id), isTrue);
      expect(stream.byId(item.id), isNull);
      expect(stream.remove(item.id), isFalse);
    });

    test('与笔记数据互不渗漏：速记不进 notes / blocks / 文库', () {
      stream.add('一条速记');
      expect(store.allNotes(), isEmpty);
      expect(db.select('SELECT id FROM notes'), isEmpty);
      expect(db.select('SELECT id FROM blocks'), isEmpty);
    });
  });

  group('单向导出：速记 → 笔记', () {
    test('引用（活链）：插 ref 块 ref_type=stream，幂等，速记不动', () {
      final StreamItem item = stream.add('可被引用')!;
      final Note target = store.createSpark(
        kind: NoteKind.note,
        content: _emptyBlocks,
        plainText: '',
      );

      expect(store.referenceStreamInNote(item.id, target.id), isTrue);
      // 幂等：同一篇再引一次不重复插。
      expect(store.referenceStreamInNote(item.id, target.id), isFalse);
      // 速记不动（引用不消耗）。
      expect(stream.byId(item.id), isNotNull);

      final Row ref = db.select(
        "SELECT props_json FROM blocks WHERE note_id = ? AND type = 'ref'",
        <Object?>[target.id],
      ).single;
      final Map<String, Object?> props =
          (jsonDecode(ref['props_json'] as String) as Map)
              .cast<String, Object?>();
      expect(props['ref_type'], 'stream');
      expect(props['ref_id'], item.id);
    });

    test('复制（快照）：目标多一个真段落块，速记不动', () {
      final StreamItem item = stream.add('复制我')!;
      final Note target = store.createSpark(
        kind: NoteKind.note,
        content: _emptyBlocks,
        plainText: '',
      );
      expect(store.copyStreamIntoNote(item.id, target.id), isTrue);

      final List<Row> rows = db.select(
        'SELECT props_json FROM blocks WHERE note_id = ?',
        <Object?>[target.id],
      );
      expect(rows, hasLength(1));
      expect(textOfProps(rows.single['props_json'] as String?), '复制我');
      expect(stream.byId(item.id), isNotNull);
    });

    test('转新笔记（归档）：新笔记落块、速记归档但不删', () {
      final StreamItem item = stream.add('转我')!;
      final Note? created = store.streamToNewNote(item.id);

      expect(created, isNotNull);
      expect(created!.kind, NoteKind.note);
      expect(store.allNotes().map((Note n) => n.id), contains(created.id));
      final Row row = db.select(
        'SELECT props_json FROM blocks WHERE note_id = ?',
        <Object?>[created.id],
      ).first;
      expect(textOfProps(row['props_json'] as String?), '转我');

      // 归档（不是删除）：默认列表看不到，但行还在。
      expect(stream.list().map((StreamItem i) => i.id), isNot(contains(item.id)));
      expect(stream.byId(item.id)!.archived, isTrue);
    });

    test('合并成新笔记：按时间（旧→新）成段，参与的都归档', () {
      final StreamItem older = stream.add('第一句')!;
      final StreamItem newer = stream.add('第二句')!;
      // 反着传，验证内部按创建时间排序。
      final Note? merged = store.streamMergeToNewNote(<String>[
        newer.id,
        older.id,
      ]);
      expect(merged, isNotNull);
      final List<Row> rows = db.select(
        'SELECT props_json FROM blocks WHERE note_id = ? ORDER BY ord',
        <Object?>[merged!.id],
      );
      expect(
        rows.map((Row r) => textOfProps(r['props_json'] as String?)).toList(),
        <String>['第一句', '第二句'],
      );
      expect(stream.list(), isEmpty);
      expect(stream.byId(older.id)!.archived, isTrue);
      expect(stream.byId(newer.id)!.archived, isTrue);
    });

    test('转成新画布：建画布 + 一条卡片，速记归档', () {
      final StreamItem item = stream.add('画布开局')!;
      final Note? created = store.streamToNewCanvas(item.id);
      expect(created, isNotNull);
      expect(created!.kind, NoteKind.canvas);

      final Map<String, Object?> doc =
          (jsonDecode(store.canvasContentOf(created.id)) as Map)
              .cast<String, Object?>();
      final Map<String, Object?> items =
          ((doc['document'] as Map)['items'] as Map).cast<String, Object?>();
      expect(items, hasLength(1));
      expect((items.values.single as Map)['text'], '画布开局');
      expect(stream.byId(item.id)!.archived, isTrue);
    });

    test('画布 / 不存在的速记：引用与复制都拒绝', () {
      final StreamItem item = stream.add('x')!;
      final Note canvas = store.create(kind: NoteKind.canvas);
      expect(store.referenceStreamInNote(item.id, canvas.id), isFalse);
      expect(store.copyStreamIntoNote(item.id, canvas.id), isFalse);
      expect(store.referenceStreamInNote('no-such-id', canvas.id), isFalse);
      expect(store.copyStreamIntoNote('no-such-id', canvas.id), isFalse);
    });
  });

  group('单向导出：速记 → 画布（只复制，不做活链）', () {
    test('复制成独立卡片：新块 + 卡片，速记之后与它无关', () {
      final StreamItem item = stream.add('画布卡')!;
      final Note canvas = _canvasNote(store, '画布甲');

      expect(store.copyStreamOntoCanvas(item.id, canvas.id), isTrue);

      final Map<String, Object?> doc =
          (jsonDecode(store.canvasContentOf(canvas.id)) as Map)
              .cast<String, Object?>();
      final Map<String, Object?> document =
          (doc['document'] as Map).cast<String, Object?>();
      final Map<String, Object?> items =
          (document['items'] as Map).cast<String, Object?>();
      expect(items, hasLength(1));
      final Map<String, Object?> card =
          (items.values.single as Map).cast<String, Object?>();
      expect(card['type'], 'card');
      expect(card['text'], '画布卡');
      final String blockId = card['blockId'] as String;
      expect(blockId, isNot(item.id), reason: '卡片必须有自己的块，不能指向速记');
      // 卡片内容落进 blocks（画布卡的通用契约）。
      expect(
        textOfProps(
          db.select('SELECT props_json FROM blocks WHERE id = ?', <Object?>[
                blockId,
              ]).single['props_json']
              as String?,
        ),
        '画布卡',
      );
      // 再复制一次 = 第二张卡（复制不幂等，引用才幂等）。
      expect(store.copyStreamOntoCanvas(item.id, canvas.id), isTrue);
      final Map<Object?, Object?> after =
          (((jsonDecode(store.canvasContentOf(canvas.id)) as Map)
                      ['document'] as Map)['items'] as Map)
              .cast<Object?, Object?>();
      expect(after, hasLength(2));
    });

    test('速记更新不推送：卡片文本保持复制时的快照', () {
      final StreamItem item = stream.add('旧文本')!;
      final Note canvas = _canvasNote(store, '画布乙');
      store.copyStreamOntoCanvas(item.id, canvas.id);

      stream.update(item.id, '新文本');
      final Map<String, Object?> doc =
          (jsonDecode(store.canvasContentOf(canvas.id)) as Map)
              .cast<String, Object?>();
      final Map<String, Object?> items =
          ((doc['document'] as Map)['items'] as Map).cast<String, Object?>();
      expect((items.values.single as Map)['text'], '旧文本');
    });
  });

  group('v16 迁移：旧心流容器 → 独立表', () {
    test('条目搬迁、引用改类型、容器消失、原文有备份', () {
      // 1. 造一个"v15 的世界"：隐藏容器 + 两条段落块 + 目标笔记里一条块引用。
      const String s1 = 'stream-1';
      const String s2 = 'stream-2';
      const String containerId = 'container-1';
      final String tree = jsonEncode(<String, Object?>{
        'v': 2,
        'format': 'blocks',
        'document': <String, Object?>{
          'type': 'page',
          'children': <Object?>[
            <String, Object?>{
              'id': s2,
              'type': 'paragraph',
              'data': <String, Object?>{
                'delta': <Object?>[
                  <String, Object?>{'insert': '新的'},
                ],
                'text': '新的',
              },
            },
            <String, Object?>{
              'id': s1,
              'type': 'paragraph',
              'data': <String, Object?>{
                'delta': <Object?>[
                  <String, Object?>{'insert': '旧的'},
                ],
              },
            },
          ],
        },
      });
      _insertNote(db, containerId, 'stream', '', tree, 1000);
      _insertBlock(db, s1, containerId, 'paragraph', '{"text":"旧的"}', 1000);
      _insertBlock(db, s2, containerId, 'paragraph', '{"text":"新的"}', 2000);

      _insertNote(db, 'target', 'note', '目标', _emptyBlocks, 1500);
      _insertBlock(
        db,
        'ref-1',
        'target',
        'ref',
        jsonEncode(<String, Object?>{
          'ref_type': 'block',
          'ref_id': s1,
          'ref_view': 'link',
        }),
        1000,
      );

      // 2. 把版本回拨，触发 v16。
      db.userVersion = 15;
      AppDatabase.migrateForTesting(db);

      // 3. 断言。
      final List<StreamItem> items = StreamStore(db).list();
      expect(items.map((StreamItem i) => i.id), <String>[s2, s1]);
      expect(items.map((StreamItem i) => i.text), <String>['新的', '旧的']);
      // 引用改类型（id 没变 ⇒ 不断链）。
      final Row ref = db.select(
        'SELECT props_json FROM blocks WHERE id = ?',
        <Object?>['ref-1'],
      ).single;
      final Map<String, Object?> props =
          (jsonDecode(ref['props_json'] as String) as Map)
              .cast<String, Object?>();
      expect(props['ref_type'], 'stream');
      expect(props['ref_id'], s1);
      // 容器与它的块都清了。
      expect(
        db.select("SELECT id FROM notes WHERE kind = 'stream'"),
        isEmpty,
      );
      expect(db.select('SELECT id FROM blocks WHERE id = ?', <Object?>[s1]), isEmpty);
      // 原文备份留了一手。
      expect(
        db.select("SELECT value FROM settings WHERE key = 'stream.migration.backup'"),
        isNotEmpty,
      );
      // 迁移后可正常读写。
      expect(StreamStore(db).byId(s1)!.text, '旧的');
    });

    test('画布上指向心流块的卡片：转成独立复制卡（不留悬空块引用）', () {
      const String s1 = 'stream-x';
      const String containerId = 'container-x';
      final String tree = jsonEncode(<String, Object?>{
        'v': 2,
        'format': 'blocks',
        'document': <String, Object?>{
          'type': 'page',
          'children': <Object?>[
            <String, Object?>{
              'id': s1,
              'type': 'paragraph',
              'data': <String, Object?>{'text': '卡片文本'},
            },
          ],
        },
      });
      _insertNote(db, containerId, 'stream', '', tree, 1000);
      _insertBlock(db, s1, containerId, 'paragraph', '{"text":"卡片文本"}', 1000);

      final String canvasJson = jsonEncode(<String, Object?>{
        'camera': <String, Object?>{'x': 0, 'y': 0, 'scale': 1},
        'document': <String, Object?>{
          'items': <String, Object?>{
            'item-1': <String, Object?>{
              'type': 'card',
              'id': 'item-1',
              'blockId': s1,
              'text': '卡片文本',
              'angle': 0,
              'rect': <double>[0, 0, 100, 60],
              'meta': <String, Object?>{},
            },
          },
          'itemOrder': <Object?>['item-1'],
        },
      });
      _insertNote(db, 'canvas-1', 'canvas', '画布', canvasJson, 1200);
      db.execute(
        'INSERT INTO canvas_items (id, note_id, kind, z, x1, y1, x2, y2, angle, '
        'block_id, props_json, created_at, updated_at, fingerprint) '
        "VALUES ('item-1', 'canvas-1', 'card', 0, 0, 0, 100, 60, 0, ?, '{}', "
        '1200, 1200, ?)',
        <Object?>[s1, 'fp'],
      );

      db.userVersion = 15;
      AppDatabase.migrateForTesting(db);

      // 卡片换了自己的块（不再是速记 id）。
      final Map<String, Object?> doc =
          (jsonDecode(
                    db.select(
                          'SELECT content FROM notes WHERE id = ?',
                          <Object?>['canvas-1'],
                        ).single['content']
                        as String,
                  )
                  as Map)
              .cast<String, Object?>();
      final Map<String, Object?> items =
          ((doc['document'] as Map)['items'] as Map).cast<String, Object?>();
      final Map<String, Object?> card =
          (items['item-1'] as Map).cast<String, Object?>();
      final String blockId = card['blockId'] as String;
      expect(blockId, isNot(s1));
      expect(card['text'], '卡片文本');
      // 新块真的建了（否则下次投影会因外键失败）。
      expect(
        db.select('SELECT note_id FROM blocks WHERE id = ?', <Object?>[blockId]),
        isNotEmpty,
      );
      // 旧投影行已删（指向马上消失的块）。
      expect(
        db.select('SELECT id FROM canvas_items WHERE note_id = ?', <Object?>[
          'canvas-1',
        ]),
        isEmpty,
      );
    });
  });
}

/// 造一张空画布（`create` 只给空 content，画布导出需要 `document` 结构）。
Note _canvasNote(NoteStore store, String title) {
  final Note n = store.create(kind: NoteKind.canvas);
  store.db.execute(
    'UPDATE notes SET title = ?, content = ? WHERE id = ?',
    <Object?>[
      title,
      jsonEncode(<String, Object?>{
        'camera': <String, Object?>{'x': 0, 'y': 0, 'scale': 1},
        'document': <String, Object?>{
          'items': <String, Object?>{},
          'itemOrder': <Object?>[],
        },
      }),
      n.id,
    ],
  );
  return store.noteById(n.id)!;
}

void _insertNote(
  Database db,
  String id,
  String kind,
  String title,
  String content,
  int createdAt,
) {
  db.execute(
    'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
    'summary, created_at, revised_at, tags) '
    "VALUES (?, ?, ?, ?, '', '', '', ?, ?, '[]')",
    <Object?>[id, kind, title, content, createdAt, createdAt],
  );
}

void _insertBlock(
  Database db,
  String id,
  String noteId,
  String type,
  String props,
  int createdAt,
) {
  db.execute(
    'INSERT INTO blocks (id, note_id, type, props_json, ord, created_at, '
    'updated_at, fingerprint) VALUES (?, ?, ?, ?, 1024, ?, ?, ?)',
    <Object?>[id, noteId, type, props, createdAt, createdAt, 'fp'],
  );
}
