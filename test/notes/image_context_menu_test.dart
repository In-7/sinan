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

/// 用户实报（2026-11-22）：在图片上右键**没反应**。
///
/// 根因（vendored 补丁 16 只修了一半）：`desktop_selection_service.dart` 的
/// `_showContextMenu` 里仍留着官方 "only support the text node" 门禁——
/// `currentSelectedNodes.every(delta != null)`。图片块有 `SelectableMixin`
/// 但 `delta == null`，右键时选区落到图片 ⇒ 门禁 return，菜单根本不弹。
///
/// 本测试复刻用户路径：左键选中图片 → 右键 → 断言菜单出现。
void main() {
  testWidgets('选中图片后右键：应弹出上下文菜单（当前门禁 return，红）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const String img = 'data:image/png;base64,iVBORw0KGgo=';
    final String content = NoteDocumentAdapter.storedContentFromDocument(
      Document(
        root: pageNode(children: <Node>[
          paragraphNode(text: '开头'),
          imageNode(url: img, width: 500, height: 200),
          paragraphNode(text: '结尾'),
        ]),
      ),
    );
    final Note note = Note(
      id: 'n1',
      kind: NoteKind.note,
      title: '带图片的笔记',
      content: content,
      plainText: '开头 结尾',
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

    // 左键选中图片（真实 uiEvent 路径）。
    unawaited(
      state.updateSelectionWithReason(
        Selection.collapsed(Position(path: image.path)),
        reason: SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();
    expect(state.selection?.start.path, image.path, reason: '前置：图片被选中');

    // 在图片上右键。
    final Finder imageFinder = find.bySemanticsLabel('图片').first;
    expect(imageFinder, findsWidgets, reason: '图片块没有语义标签');
    await tester.tapAt(
      tester.getCenter(imageFinder),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(
      find.text('粘贴'),
      findsOneWidget,
      reason: '图片右键应弹出菜单（门禁 return 会让它完全不弹）',
    );
    // 媒体块首行是「删除图片」（不是对图片无意义的「剪切」）。
    expect(find.text('删除图片'), findsOneWidget);

    // 点「删除图片」⇒ 图片块从文档里消失。
    await tester.tap(find.text('删除图片'));
    await tester.pumpAndSettle();
    expect(
      state.document.root.children
          .where((Node n) => n.type == ImageBlockKeys.type),
      isEmpty,
      reason: '删除图片应真的从文档移除',
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
