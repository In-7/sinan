import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/canvas_mindmap.dart';
import 'package:sinan/src/canvas/kernel/canvas_text.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 画布可搜索文字投影（2026-11-21）：只收文字型 item（卡片 / 导图 / 组标题），
/// 图片 / 形状 / 连线跳过——与笔记的图片视频不进 plainText 同一口径。
void main() {
  CardItem card(String id, String text) => CardItem(
    id: id,
    rect: const Rect.fromLTRB(0, 0, 100, 60),
    blockId: 'block-$id',
    text: text,
  );

  test('卡片 / 导图 / 组标题都进，按 z 序用换行分隔', () {
    final List<CanvasItem> items = <CanvasItem>[
      card('c1', '番茄工作法'),
      ShapeItem(
        id: 's1',
        rect: const Rect.fromLTRB(0, 0, 10, 10),
        kind: CanvasShapeKind.rectangle,
        color: const Color(0xFF000000),
      ),
      CanvasGroupItem(
        id: 'g1',
        rect: const Rect.fromLTRB(0, 0, 200, 200),
        label: '项目组',
      ),
      MindMapItem(
        id: 'm1',
        rect: const Rect.fromLTRB(0, 0, 300, 200),
        root: MindNode(
          text: '中心',
          children: <MindNode>[
            MindNode(text: '分支甲', children: <MindNode>[
              MindNode(text: '叶子乙'),
            ]),
          ],
        ),
      ),
    ];
    expect(
      canvasSearchableText(items),
      '番茄工作法\n项目组\n中心\n分支甲\n叶子乙',
    );
  });

  test('空文字 / 只有图片形状 ⇒ 空串（不产生噪声）', () {
    expect(canvasSearchableText(<CanvasItem>[card('c', '   ')]), '');
    expect(
      canvasSearchableText(<CanvasItem>[
        ImageItem(id: 'i', rect: Rect.zero, src: 'x.png'),
      ]),
      '',
    );
    expect(canvasSearchableText(const <CanvasItem>[]), '');
  });

  group('NoteStore.backfillPlainText（存量画布补齐）', () {
    late Database db;
    late NoteStore store;
    setUp(() {
      db = sqlite3.openInMemory();
      AppDatabase.migrateForTesting(db);
      store = NoteStore(db);
    });
    tearDown(() => db.close());

    test('只补 plain_text/summary，不动 content / content_hash / revised_at', () async {
      final Note canvas = store.create(kind: NoteKind.canvas);
      // 模拟旧画布保存：content 变了、plainText 传空串（历史行为）。
      await store.updateContent(canvas.id, '{"document":{}}', plainText: '');
      expect(store.noteById(canvas.id)!.plainText, '');
      final Note before = store.noteById(canvas.id)!;

      final bool wrote = store.backfillPlainText(canvas.id, '番茄工作法\n项目组');

      expect(wrote, isTrue);
      final Note after = store.noteById(canvas.id)!;
      expect(after.plainText, '番茄工作法\n项目组');
      expect(after.summary, contains('番茄工作法'), reason: 'summary 同步补上 ⇒ 页内搜索能命中');
      expect(after.content, before.content, reason: 'content 不动');
      expect(after.contentHash, before.contentHash, reason: 'hash 不动');
      expect(
        after.revisedAt.millisecondsSinceEpoch,
        before.revisedAt.millisecondsSinceEpoch,
        reason: '不刷新修改时间（补齐不是用户编辑）',
      );
    });

    test('已有 plainText / 空投影 / 不存在 id ⇒ 不写', () {
      final Note canvas = store.create(kind: NoteKind.canvas);
      expect(store.backfillPlainText(canvas.id, ''), isFalse);
      expect(store.backfillPlainText('不存在', '字'), isFalse);
      store.backfillPlainText(canvas.id, '第一次');
      expect(store.backfillPlainText(canvas.id, '第二次'), isFalse, reason: '幂等，不覆盖');
      expect(store.noteById(canvas.id)!.plainText, '第一次');
    });
  });
}
