import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/block_hit.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 全库块搜索（`NoteStore.searchBlocks`）——「引用块」选择器的数据来源。
///
/// 钉的是它作为**一级扁平搜索**该有的性质：跨笔记、带来源、空查询也有结果，
/// 以及"没有文本的块不该占名额"。之所以能一级（而不必先选笔记），是因为
/// `blocks` 表是全库扁平的——这条性质反过来也由本测试守住。
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

  test('跨笔记：一次搜索拿到两篇里的块，且各自带来源标题', () {
    store.create(
      title: '甲',
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '苹果很好吃'}),
      ]),
    );
    store.create(
      title: '乙',
      content: v2(<Map<String, Object?>>[
        block('b2', 'paragraph', data: <String, Object?>{'text': '香蕉也不错'}),
      ]),
    );

    final List<BlockHit> hits = store.searchBlocks('');
    // 一级扁平搜索的核心：不必先选笔记，跨笔记一次拿到。
    expect(
      hits.map((BlockHit h) => h.blockId),
      containsAll(<String>['b1', 'b2']),
    );
    final Map<String, BlockHit> byId = <String, BlockHit>{
      for (final BlockHit h in hits) h.blockId: h,
    };
    // 来源标题是全库结果里唯一的定位线索，缺了它用户不知道块来自哪篇。
    expect(byId['b1']!.noteTitle, '甲');
    expect(byId['b2']!.noteTitle, '乙');
  });

  test('关键词过滤：只回匹配的块', () {
    store.create(
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '苹果很好吃'}),
        block('b2', 'paragraph', data: <String, Object?>{'text': '香蕉也不错'}),
      ]),
    );

    expect(
      store.searchBlocks('苹果').map((BlockHit h) => h.blockId),
      <String>['b1'],
    );
  });

  test('没有文本的块不占名额（分隔线 / 引用块本身）', () {
    store.create(
      content: v2(<Map<String, Object?>>[
        block('dv', 'divider'),
        block('b1', 'paragraph', data: <String, Object?>{'text': '有文字'}),
      ]),
    );

    expect(
      store.searchBlocks('').map((BlockHit h) => h.blockId),
      <String>['b1'],
      reason: '引用一个没有文本的块没有意义，它不该挤掉真正的候选',
    );
  });

  test('空查询也给结果（打开选择器就有东西看，而不是空着等打字）', () {
    store.create(
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '一'}),
      ]),
    );

    expect(store.searchBlocks(''), hasLength(1));
  });

  test('limit 生效', () {
    store.create(
      content: v2(<Map<String, Object?>>[
        for (int i = 0; i < 10; i++)
          block('b$i', 'paragraph', data: <String, Object?>{'text': 'x$i'}),
      ]),
    );

    expect(store.searchBlocks('', limit: 3), hasLength(3));
  });

  test('已删除的笔记里的块不出现', () {
    final Note note = store.create(
      content: v2(<Map<String, Object?>>[
        block('b1', 'paragraph', data: <String, Object?>{'text': '待删'}),
      ]),
    );
    db.execute(
      'UPDATE notes SET deleted_at = ? WHERE id = ?',
      <Object?>[DateTime.now().millisecondsSinceEpoch, note.id],
    );

    expect(store.searchBlocks('待删'), isEmpty);
  });
}
