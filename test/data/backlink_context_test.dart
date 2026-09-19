import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/backlink.dart';
import 'package:sinan/src/domain/embed_line.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 双链**读侧**的两个增强：
///
/// 1. 反链带**上下文**（引用处附近的文字）——只有来源标题时，用户看不出
///    "它为什么引用我"，也就无从判断要不要点进去；
/// 2. **嵌入预览**（`NoteStore.embedPreview`）——把引用目标的内容取出来只读展示。
///
/// 这里钉的是两条容易悄悄坏掉的口径：上下文在文档侧取的是 `ref` 块**前面**的
/// 相邻块（`ref` 块自身没有文本），以及嵌入预览**只取有文本的块**（这条顺带
/// 让"A 嵌 B、B 又嵌 A"不可能无限展开）。
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
  }) =>
      <String, Object?>{'id': id, 'type': type, 'data': data};

  String canvasJson() => jsonEncode(<String, Object?>{
        'camera': <String, Object?>{},
        'document': <String, Object?>{
          'items': <String, Object?>{},
          'itemOrder': <String>[],
          'strokes': <String, Object?>{},
        },
      });

  test('反链上下文（文档侧）：取 ref 块前面最近一个有文本的块', () {
    final Note target = store.create(
      title: '目标',
      content: v2(<Map<String, Object?>>[
        block('t1', 'paragraph', data: <String, Object?>{'text': '目标块'}),
      ]),
    );
    store.create(
      title: '来源',
      content: v2(<Map<String, Object?>>[
        block('c1', 'paragraph', data: <String, Object?>{'text': '前文在这里'}),
        // ref 块自身没有文本 ⇒ 上下文只能来自它前面的块。
        block(
          'r1',
          'ref',
          data: <String, Object?>{'ref_type': 'note', 'ref_id': target.id},
        ),
      ]),
    );

    final List<Backlink> links = store.backlinks(target.id);
    expect(links.single.context, '前文在这里');
  });

  test('反链上下文（画布侧）：取被引用块自己的文本', () {
    final Note doc = store.create(
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '被引用的正文'}),
      ]),
    );
    final Note cv = store.create(kind: NoteKind.canvas, content: canvasJson());
    expect(store.referenceBlockOnCanvas('b1', cv.id), isTrue);

    final List<Backlink> links = store.backlinks(doc.id);
    final Backlink viaCard = links.firstWhere(
      (Backlink b) => b.viaCanvasCard,
    );
    // 卡片的真身就是被引用那块 ⇒ 上下文直接是它的文本。
    expect(viaCard.context, '被引用的正文');
  });

  test('上下文过长会截短（面板不能被一段长文撑坏）', () {
    final Note target = store.create(
      content: v2(<Map<String, Object?>>[
        block('t1', 'paragraph', data: <String, Object?>{'text': 'x'}),
      ]),
    );
    store.create(
      content: v2(<Map<String, Object?>>[
        block(
          'c1',
          'paragraph',
          data: <String, Object?>{'text': '很长的正文' * 40},
        ),
        block(
          'r1',
          'ref',
          data: <String, Object?>{'ref_type': 'note', 'ref_id': target.id},
        ),
      ]),
    );

    final String context = store.backlinks(target.id).single.context;
    expect(context, endsWith('…'));
    expect(context.length, lessThan(90));
  });

  test('嵌入预览：块级只取那一块', () {
    store.create(
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '第一块'}),
        block('b2', 'paragraph', data: <String, Object?>{'text': '第二块'}),
      ]),
    );

    expect(
      store.embedPreview('block', 'b2').map((EmbedLine l) => l.text),
      <String>['第二块'],
    );
  });

  test('嵌入预览：笔记级按阅读顺序取，且受 limit 约束', () {
    final Note n = store.create(
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '一'}),
        block('b2', 'paragraph', data: <String, Object?>{'text': '二'}),
        block('b3', 'paragraph', data: <String, Object?>{'text': '三'}),
      ]),
    );

    expect(
      store.embedPreview('note', n.id, limit: 2).map((EmbedLine l) => l.text),
      <String>['一', '二'],
    );
  });

  test('嵌入预览跳过没有文本的块 ⇒ 嵌入不会递归展开', () {
    final Note a = store.create(
      title: 'A',
      content: v2(<Map<String, Object?>>[
        block('a1', 'paragraph', data: <String, Object?>{'text': 'A 的正文'}),
      ]),
    );
    final Note b = store.create(
      title: 'B',
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': 'B 的正文'}),
        block(
          'r1',
          'ref',
          data: <String, Object?>{'ref_type': 'note', 'ref_id': a.id},
        ),
      ]),
    );

    // B 里有一个指向 A 的 ref 块，但预览只给**有文本**的块 ⇒ 展开 B 不会再去
    // 展开 A（否则 A 若反过来嵌 B 就是死循环）。
    expect(
      store.embedPreview('note', b.id).map((EmbedLine l) => l.text),
      <String>['B 的正文'],
    );
  });

  test('嵌入预览带勾选态（待办）', () {
    store.create(
      content: v2(<Map<String, Object?>>[
        block(
          't1',
          'todo_list',
          data: <String, Object?>{'text': '待办项', 'checked': true},
        ),
      ]),
    );

    final EmbedLine line = store.embedPreview('block', 't1').single;
    expect(line.blockType, 'todo_list');
    expect(line.checked, isTrue);
  });
}
