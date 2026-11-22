import 'dart:async' show unawaited;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
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
import 'package:sinan/src/notes/note_editor_view_appflowy.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 右键交互（2026-11-22，补丁 16e + 图片选中描边）：
///
/// 用户心智 = "左键点那一下是聚焦，我准备对这块动手"；图片没光标，之前
/// 右键要先左键点两下才出图片菜单。修后：
/// - 光标在文字上、直接右键图片一次 ⇒ 先聚焦图片（整块选区）再弹图片菜单；
/// - 图片被聚焦时有主题色描边（画面上能看出"当前是这块"）。
void main() {
  const String img = 'data:image/png;base64,iVBORw0KGgo=';

  Future<EditorState> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final String content = NoteDocumentAdapter.storedContentFromDocument(
      Document(
        root: pageNode(children: <Node>[
          paragraphNode(text: '开头段落'),
          imageNode(url: img, width: 500, height: 200),
          paragraphNode(text: '结尾段落'),
        ]),
      ),
    );
    final Note note = Note(
      id: 'n1',
      kind: NoteKind.note,
      title: '聚焦右键',
      content: content,
      plainText: '开头段落 结尾段落',
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
    await container.read(notesProvider.future);
    addTearDown(container.dispose);
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
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
    return tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
  }

  testWidgets('光标在文字上，右键图片一次就弹图片菜单（先聚焦图片）', (tester) async {
    final EditorState state = await pumpEditor(tester);
    final Node image = state.document.root.children
        .where((Node n) => n.type == ImageBlockKeys.type)
        .single;

    // 前置：先把光标放在第一段文字上（collapsed 选区在文字块）。
    unawaited(
      state.updateSelectionWithReason(
        Selection.collapsed(Position(path: [0], offset: 2)),
        reason: SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();
    expect(state.selection?.start.path, [0], reason: '前置：光标在文字块');

    // 直接右键图片（不先左键点它）。
    await tester.tapAt(
      tester.getCenter(find.bySemanticsLabel('图片').first),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    // 补丁 16e：选区应先移到图片整块（cover 0..1）。
    expect(state.selection?.start.path, image.path, reason: '右键应先聚焦图片');
    expect(state.selection!.isCollapsed, isFalse,
        reason: '图片是 cover 块，选区应为整块 0..1');

    // 菜单应是图片菜单，不是文字菜单。
    expect(find.text('删除图片'), findsOneWidget,
        reason: '应弹图片菜单（否则用户要点两下）');
    expect(find.text('预览图片'), findsOneWidget);
  });

  testWidgets('图片被聚焦时画主题色描边（foreground 不占位）', (tester) async {
    final EditorState state = await pumpEditor(tester);
    final Color primary = AppTheme.light().colorScheme.primary;

    // 光标在文字上 ⇒ 图片无描边。
    unawaited(
      state.updateSelectionWithReason(
        Selection.collapsed(Position(path: [0], offset: 2)),
        reason: SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border != null &&
            (w.decoration as BoxDecoration).border!.top.color == primary,
      ),
      findsNothing,
      reason: '未聚焦图片不该有主题色描边',
    );

    // 选区移到图片 ⇒ 出现主题色描边。
    unawaited(
      state.updateSelectionWithReason(
        Selection(
          start: Position(path: [1]),
          end: Position(path: [1], offset: 1),
        ),
        reason: SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border != null &&
            (w.decoration as BoxDecoration).border!.top.color == primary,
      ),
      findsOneWidget,
      reason: '聚焦图片应画主题色描边',
    );
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
