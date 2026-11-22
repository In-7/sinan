import 'dart:async' show unawaited;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/pending_saves.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/domain/settings.dart';
import 'package:sinan/src/editor/core/note_document_adapter.dart';
import 'package:sinan/src/editor/keys/image_arrow_commands.dart';
import 'package:sinan/src/notes/note_editor_view_appflowy.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 用户实报（2026-11-22）：正文底部有图片时，纯键盘 ↓ 到图片就停了、看不全。
///
/// 两阶段策略（真实编辑器 + 真实按键）：
/// - 图片**未完整入视口** ⇒ 命令走官方滚动通道滚一档（50px），连按看全；
/// - 图片**已完整入视口** ⇒ 交回官方 moveCursorDownCommand 跳到下一块。
/// 两个用例各钉一半，外加图片语义标签（补丁 23）。
void main() {
  const String img = 'data:image/png;base64,iVBORw0KGgo=';

  Future<(EditorState, Node, ScrollPosition)> pumpWithImage(
    WidgetTester tester, {
    required double imageHeight,
  }) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final String content = NoteDocumentAdapter.storedContentFromDocument(
      Document(
        root: pageNode(children: <Node>[
          paragraphNode(text: '开头'),
          imageNode(url: img, width: 500, height: imageHeight),
          paragraphNode(text: '图片后面的一段'),
        ]),
      ),
    );
    final Note note = Note(
      id: 'n1',
      kind: NoteKind.note,
      title: '带大图的笔记',
      content: content,
      plainText: '开头 图片后面的一段',
      summary: '',
      contentHash: 'h',
      createdAt: DateTime(2026),
      revisedAt: DateTime(2026),
    );

    final Database db = sqlite3.openInMemory();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);
    final NoteStore store = NoteStore(db);
    await store.restore(note);
    final _FakeNotes notes = _FakeNotes(<Note>[note]);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        notesProvider.overrideWith(() => notes),
        settingsProvider.overrideWith(_FakeSettings.new),
        noteStoreProvider.overrideWithValue(store),
        pendingSavesProvider.overrideWithValue(PendingSaves()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(notesProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            ...GlobalMaterialLocalizations.delegates,
            AppFlowyEditorLocalizations.delegate,
          ],
          supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
          home: const Scaffold(body: NoteEditorViewAppFlowy(noteId: 'n1')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final EditorState state = tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
    final Node image = state.document.root.children
        .where((Node n) => n.type == ImageBlockKeys.type)
        .single;
    final ScrollPosition pos = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(AppFlowyEditor),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;

    // 把选区落到图片块（真实 uiEvent 路径，编辑器持焦）。
    // uiEvent 分支靠 post-frame 回调完成，不能 await（会挂死），交给 pump。
    unawaited(
      state.updateSelectionWithReason(
        Selection.collapsed(Position(path: image.path)),
        reason: SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();
    expect(state.selection?.start.path, image.path, reason: '前置：选区应在图片块');
    return (state, image, pos);
  }

  testWidgets('大图未看全：↓ 滚动且选区留在图片块，连按持续滚', (tester) async {
    final (EditorState state, Node image, ScrollPosition pos) =
        await pumpWithImage(tester, imageHeight: 900);
    expect(imageFullyVisible(state, image), isFalse, reason: '前置：大图未完整可见');

    final double before = pos.pixels;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(pos.pixels, greaterThan(before), reason: '按 ↓ 应滚动');
    expect(state.selection?.start.path, image.path, reason: '未看全不能被跳走');

    final double afterFirst = pos.pixels;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(pos.pixels, greaterThan(afterFirst), reason: '第二次 ↓ 仍需滚动');
  });

  testWidgets('小图已看全：↓ 交回官方命令跳到下一块', (tester) async {
    final (EditorState state, Node image, ScrollPosition pos) =
        await pumpWithImage(tester, imageHeight: 120);
    expect(imageFullyVisible(state, image), isTrue, reason: '前置：小图完整可见');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      state.selection?.start.path,
      isNot(image.path),
      reason: '看全后 ↓ 应跳到图片后面的块，而不是卡住',
    );
  });

  testWidgets('图片块有语义标签（补丁 23：读屏能念出图片）', (tester) async {
    await pumpWithImage(tester, imageHeight: 200);
    expect(find.bySemanticsLabel('图片'), findsWidgets);
  });
}

class _FakeNotes extends NotesNotifier {
  _FakeNotes(this.notes);
  final List<Note> notes;

  @override
  Future<List<Note>> build() async => notes;
}

class _FakeSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}
