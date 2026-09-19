import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/backlink.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 反链查询（`NoteStore.backlinks`）。
///
/// 引用边只有两类，且都指向**块**：文档里的 `ref` 块、画布上的卡片。这个查询是
/// "双链"的读侧，最该钉的是**误报与漏报**——把不相关的笔记列进来，或漏掉某一条
/// 真实存在的边，用户都会对"谁引用了我"失去信任。
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

  /// 一个 ref 块节点（属性与 `RefBlockKeys` 对齐）。
  Map<String, Object?> refBlock(String id, String refType, String refId) =>
      block(id, 'ref', data: <String, Object?>{'ref_type': refType, 'ref_id': refId});

  String canvasJson({
    Map<String, Object?> items = const <String, Object?>{},
    List<String> order = const <String>[],
  }) =>
      jsonEncode(<String, Object?>{
        'camera': <String, Object?>{},
        'document': <String, Object?>{
          'items': items,
          'itemOrder': order,
          'strokes': <String, Object?>{},
        },
      });

  Map<String, Object?> card(String id, String blockId, String text) =>
      <String, Object?>{
        'type': 'card',
        'id': id,
        'blockId': blockId,
        'text': text,
        'angle': 0.0,
        'rect': <double>[0.0, 0.0, 240.0, 120.0],
        'meta': <String, Object?>{},
      };

  test('文档里的 ref 块引用整篇笔记 ⇒ 列出一条反链', () {
    final Note target = store.create(title: '被引用', content: v2(<Map<String, Object?>>[]));
    final Note source = store.create(
      title: '引用方',
      content: v2(<Map<String, Object?>>[refBlock('r1', 'note', target.id)]),
    );

    final List<Backlink> links = store.backlinks(target.id);
    expect(links.length, 1);
    expect(links.single.sourceNoteId, source.id);
    expect(links.single.sourceTitle, '引用方');
    expect(links.single.sourceKind, NoteKind.spark);
    expect(links.single.viaBlockId, 'r1');
    expect(links.single.viaCanvasCard, isFalse);
  });

  test('ref 块引用本笔记里的**某一块** ⇒ 也算引用了这篇笔记', () {
    final Note target = store.create(
      title: '目标',
      content: v2(<Map<String, Object?>>[
        block('t1', 'paragraph', data: <String, Object?>{'text': '正文'}),
      ]),
    );
    final Note source = store.create(
      content: v2(<Map<String, Object?>>[refBlock('r1', 'block', 't1')]),
    );

    final List<Backlink> links = store.backlinks(target.id);
    expect(links.length, 1);
    expect(links.single.sourceNoteId, source.id);
    expect(links.single.viaBlockId, 'r1');
    // 引用的是"块"，但被引的块属于本笔记 ⇒ 在笔记这一层显示为一条反链。
    expect(links.single.viaCanvasCard, isFalse);
  });

  test('画布卡片指向本笔记的块 ⇒ 列出一条画布反链', () {
    final Note target = store.create(
      title: '目标',
      content: v2(<Map<String, Object?>>[
        block('t1', 'paragraph', data: <String, Object?>{'text': '正文'}),
      ]),
    );
    final Note canvas = store.create(
      kind: NoteKind.canvas,
      title: '一张画布',
      content: canvasJson(
        items: <String, Object?>{'item-0': card('item-0', 't1', '正文')},
        order: <String>['item-0'],
      ),
    );

    final List<Backlink> links = store.backlinks(target.id);
    expect(links.length, 1);
    expect(links.single.sourceNoteId, canvas.id);
    expect(links.single.sourceKind, NoteKind.canvas);
    expect(links.single.viaCanvasCard, isTrue);
    expect(links.single.viaBlockId, 't1');
  });

  test('指向**别的**笔记的 ref 块不算我的反链（不误报）', () {
    final Note me = store.create(title: '我', content: v2(<Map<String, Object?>>[]));
    final Note other = store.create(title: '别人', content: v2(<Map<String, Object?>>[]));
    store.create(
      content: v2(<Map<String, Object?>>[refBlock('r1', 'note', other.id)]),
    );

    expect(store.backlinks(me.id), isEmpty);
  });

  test('同一篇笔记里的两处引用 ⇒ 两条反链（粒度是"哪一处"）', () {
    final Note target = store.create(title: '目标', content: v2(<Map<String, Object?>>[]));
    store.create(
      content: v2(<Map<String, Object?>>[
        refBlock('r1', 'note', target.id),
        refBlock('r2', 'note', target.id),
      ]),
    );

    final List<Backlink> links = store.backlinks(target.id);
    expect(links.length, 2);
    expect(
      links.map((Backlink b) => b.viaBlockId).toSet(),
      <String>{'r1', 'r2'},
    );
  });

  test('自引用照常列出（是真实存在的边，不该悄悄过滤）', () async {
    final Note self = store.create(title: '自篇', content: v2(<Map<String, Object?>>[]));
    // ref 要指向自己的 id，只能建完再写一次。
    await store.updateContent(
      self.id,
      v2(<Map<String, Object?>>[refBlock('r1', 'note', self.id)]),
      plainText: '',
    );

    final List<Backlink> links = store.backlinks(self.id);
    expect(links.length, 1);
    expect(links.single.sourceNoteId, self.id);
  });

  test('没有任何引用 ⇒ 空列表', () {
    final Note lonely = store.create(title: '没人引用我', content: v2(<Map<String, Object?>>[]));
    expect(store.backlinks(lonely.id), isEmpty);
  });
}
