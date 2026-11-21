import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/canvas/canvas_switch.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 打开**存量画布**（plain_text 为空）时的补齐（2026-11-21）：
/// 补写 plain_text / summary 后要刷新列表快照，但**不能在 initState（build 期）
/// 同步改 provider**——Riverpod 会抛 "Tried to modify a provider while the
/// widget tree was building"（用户实报的崩溃）。补齐必须延到帧末。
void main() {
  late Database db;
  late NoteStore store;
  late ProviderContainer container;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noteStoreProvider.overrideWithValue(store),
        settingsStoreProvider.overrideWithValue(SettingsStore(db)),
        appDataDirProvider.overrideWithValue(r'C:\test\sinan'),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  testWidgets('打开存量画布不抛 build 期改 provider，且 plainText 被补齐', (
    tester,
  ) async {
    // 造一篇"旧画布"：content 有卡片文字、plain_text 为空。
    // 用内核权威序列化造 JSON，避免手写格式漂移。
    final Note canvas = store.create(kind: NoteKind.canvas);
    final CanvasController controller = CanvasController();
    addTearDown(controller.dispose);
    controller.document.addItem(
      CardItem(
        id: 'i1',
        rect: const Rect.fromLTRB(0, 0, 200, 100),
        blockId: 'b1',
        text: '番茄工作法',
      ),
    );
    final String content = jsonEncode(controller.toJson());
    await store.updateContent(canvas.id, content, plainText: '');
    expect(store.noteById(canvas.id)!.plainText, '');
    // 先把列表快照 settle 掉：真实应用启动时它早已装好；若不等，初始异步加载
    // 会在 post-frame 补齐之后完成，把新快照覆盖回旧值（测试假阴性）。
    await container.read(notesProvider.future);
    container.read(selectedNoteIdProvider.notifier).select(canvas.id);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (BuildContext context) =>
                buildNoteCanvasView(noteId: canvas.id),
          ),
        ),
      ),
    );
    // 关键：pump 一帧就应完成 build，不得抛 provider 修改断言。
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: 'build 期不得改 provider');
    expect(
      store.noteById(canvas.id)!.plainText,
      contains('番茄工作法'),
      reason: '帧末补齐 plainText',
    );
    final Note row = container
        .read(notesProvider)
        .value!
        .firstWhere((Note n) => n.id == canvas.id);
    expect(row.summary, contains('番茄工作法'), reason: '列表快照的 summary 也跟着刷新');
  });
}
