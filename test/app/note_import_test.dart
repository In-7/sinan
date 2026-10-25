import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/app/note_import.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/canvas/kernel/canvas_bundle.dart'
    show encodeCanvasBundle, importCanvasBundleText;
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_media.dart'
    show RelativeMediaResolver;
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/editor/core/note_document_adapter.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 导入 = **新建**（2026-10-21 用户定）：md / 画布文件都落成一篇新笔记，
/// 不覆盖当前内容。
///
/// 钉四件事：
/// ① md 走 appflowy 的解析器 ⇒ 标题 / 正文结构进库（不是纯文本硬塞）；
/// ② 标题取首个 H1 / 首行、截 20 字（与灵感转笔记同一套规则）；
/// ③ 画布 bundle 走"还原 → 自包含再编码"，导入后内容可整包带走；
/// ④ 失败（空文件 / 坏 JSON）返回一句实话，不崩、不静默。
void main() {
  late Database db;
  late NoteStore store;
  late ProviderContainer container;
  late Directory tmp;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
    tmp = Directory.systemTemp.createTempSync('sinan_import_');
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noteStoreProvider.overrideWithValue(store),
        settingsStoreProvider.overrideWithValue(SettingsStore(db)),
        appDataDirProvider.overrideWithValue(tmp.path),
        mediaResolverProvider.overrideWithValue(
          RelativeMediaResolver(tmp.path),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
  });

  test('标题兜底：H1 优先、去井号、截 20 字', () {
    expect(importTitleFromText('# 一周复盘\n正文'), '一周复盘');
    expect(importTitleFromText('第一行\n第二行'), '第一行');
    expect(importTitleFromText('## 二级标题'), '二级标题');
    // 截到 20 字（含"十"这个字，别数错）。
    expect(
      importTitleFromText('一二三四五六七八九十一二三四五六七八九十一二'),
      '一二三四五六七八九十一二三四五六七八九十',
    );
    expect(importTitleFromText('\n\n  \n'), '导入的笔记');
  });

  test('导入 md：新建一篇笔记，标题 / 正文结构都进库', () async {
    const String md = '# 一周复盘\n\n- 第一条\n- 第二条\n';
    final ImportOutcome outcome = await importMarkdownNote(
      container.read(notesProvider.notifier),
      pickText: () async => (text: md, fileName: '一周复盘'),
    );

    expect(outcome.error, isNull);
    final Note? note = outcome.note;
    expect(note, isNotNull);
    expect(note!.kind, NoteKind.note);
    expect(note.title, '一周复盘');
    expect(note.plainText, contains('第一条'));
    // 正文是 v2 块树 JSON（不是纯文本硬塞）⇒ 能解析出多条块，且纯文本投影
    // 里两条列表项都在。
    final Object? decoded = jsonDecode(note.content);
    expect(decoded, isA<Map<String, dynamic>>());
    expect(
      NoteDocumentAdapter.plainTextOfStoredContent(note.content),
      allOf(contains('第一条'), contains('第二条')),
    );
    expect(store.allNotes().map((Note n) => n.id), contains(note.id));
  });

  test('导入 md：空文件返回一句实话，不建笔记', () async {
    final ImportOutcome outcome = await importMarkdownNote(
      container.read(notesProvider.notifier),
      pickText: () async => (text: '   \n\n', fileName: '空'),
    );
    expect(outcome.note, isNull);
    expect(outcome.error, '这个文件是空的');
    expect(store.allNotes(), isEmpty);
  });

  test('导入 md：用户取消 = 什么都不做', () async {
    final ImportOutcome outcome = await importMarkdownNote(
      container.read(notesProvider.notifier),
      pickText: () async => (text: null, fileName: null),
    );
    expect(outcome.note, isNull);
    expect(outcome.error, isNull);
    expect(store.allNotes(), isEmpty);
  });

  test('导入画布：bundle 还原后新建一篇画布，内容可整包带走', () async {
    // 造一个自包含 bundle（同导出链路）。
    final CanvasController source = CanvasController();
    final Map<String, dynamic> bundle = await encodeCanvasBundle(
      source,
      media: RelativeMediaResolver(tmp.path),
    );

    final ImportOutcome outcome = await importCanvasNote(
      container.read(notesProvider.notifier),
      pickText: () async => (text: jsonEncode(bundle), fileName: '我的画布'),
      media: RelativeMediaResolver(tmp.path),
    );

    expect(outcome.error, isNull);
    final Note? note = outcome.note;
    expect(note, isNotNull);
    expect(note!.kind, NoteKind.canvas);
    expect(note.title, '我的画布');
    // 内容仍是合法 bundle：能再还原出一个控制器（证明没在往返里损坏）。
    final CanvasController restored = await importCanvasBundleText(
      note.content,
      media: RelativeMediaResolver(tmp.path),
    );
    expect(restored.document.items, hasLength(source.document.items.length));
  });

  test('导入画布：坏 JSON 返回错误，不崩', () async {
    final ImportOutcome outcome = await importCanvasNote(
      container.read(notesProvider.notifier),
      pickText: () async => (text: '[1,2,3]', fileName: '坏文件'),
      media: RelativeMediaResolver(tmp.path),
    );
    expect(outcome.note, isNull);
    expect(outcome.error, isNotNull);
    expect(store.allNotes(), isEmpty);
  });
}
