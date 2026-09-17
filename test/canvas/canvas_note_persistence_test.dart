import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 画布接入右侧内容区（2026-09-16）的**数据链路**回归。
///
/// 不测控件，只钉住两件会悄悄坏掉的事：
/// 1. 「画布 = 一种笔记形态」：`NoteKind.canvas` 与 DB `kind` 的 CHECK
///    （v6 已放行 `'canvas'`）对得上，能建、能读回；
/// 2. 画布序列化（`CanvasController.toJson`）能**原样存取往返**——存进
///    `notes.content`、再从 `noteById` 读回，笔迹一条不少。
///
/// ⚠️ 同时钉住一个集成前提：`updateContent` 会**双写 `blocks`**，而画布 JSON
/// 不是 v2 块树 ⇒ `BlockStore` 必须安全跳过（`format != 'blocks'` 返回 0），
/// 否则保存画布会炸或把正文投影坏。
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

  test('画布是一种笔记形态：kind=canvas 可落库并读回', () {
    expect(NoteKind.fromName('canvas'), NoteKind.canvas);
    expect(NoteKind.canvas.name, 'canvas');

    final Note n = store.create(kind: NoteKind.canvas);
    expect(store.noteById(n.id)?.kind, NoteKind.canvas);
  });

  test('画布 JSON 存取往返：笔迹原样回来（走真实序列化）', () async {
    final Note n = store.create(kind: NoteKind.canvas);

    // 造一张两条笔迹的画布，走内核真实的 toJson 路径。
    final CanvasController controller = CanvasController();
    controller.document.addStroke(
      InkStroke(
        id: 's1',
        color: const Color(0xFF1F1F1F),
        baseWidth: 4,
        points: const <InkPoint>[
          InkPoint(Offset(0, 0), 0),
          InkPoint(Offset(10, 0), 0),
        ],
      ),
    );
    controller.document.addStroke(
      InkStroke(
        id: 's2',
        color: const Color(0xFF1F1F1F),
        baseWidth: 4,
        points: const <InkPoint>[
          InkPoint(Offset(0, 20), 0),
          InkPoint(Offset(5, 25), 0.5),
        ],
      ),
    );

    final String json = jsonEncode(controller.toJson());
    expect(await store.updateContent(n.id, json, plainText: ''), isTrue);

    // ⚠️ 画布 JSON 不是 v2 块树 ⇒ 双写那句 `replaceNoteBlocks` 应安全跳过，
    // blocks 表里不该有这篇笔记的行。
    final int blockRows = db
        .select('SELECT COUNT(*) AS c FROM blocks WHERE note_id = ?', <Object?>[n.id])
        .single['c'] as int;
    expect(blockRows, 0, reason: '画布 JSON 被误当成块树投影进了 blocks');

    // 读回：noteById 走"校验不通过则回退旧列"，拿到的应是原样的画布 JSON。
    final String stored = store.noteById(n.id)!.content;
    final CanvasController loaded = CanvasController.fromJson(
      jsonDecode(stored) as Map<String, dynamic>,
    );

    expect(loaded.document.strokes.length, 2);
    expect(loaded.document.strokes.first.points.length, 2);
    expect(loaded.document.strokes.last.points.last.pressure, 0.5);
    expect(
      loaded.document.strokes.first.points.last.position,
      const Offset(10, 0),
    );
  });

  test('新建画布笔记正文为空串（右栏据此给一张空画布）', () {
    final Note n = store.create(kind: NoteKind.canvas);
    expect(store.noteById(n.id)!.content, '');
  });
}
