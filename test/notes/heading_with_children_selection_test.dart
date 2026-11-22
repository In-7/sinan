import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/pending_saves.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/domain/settings.dart';
import 'package:sinan/src/notes/note_editor_view_appflowy.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 回归（2026-11-22 用户实报）：一篇笔记里写着「我在这里」的 heading
/// **带了一个 paragraph 子节点**，点它的标题文字选不中、编辑/删除全失效。
///
/// 根因在 vendored appflowy 的命中测试 `getNodeInOffset`：
/// 子节点被列表虚拟化卸载时 `node.rect == Rect.zero`，而原判定
/// `child.rect.top <= offset.dy`（0 ≤ 186）恒真 ⇒ 递归进 children 用 zero rect
/// 二分 ⇒ 点击被路由到**前一个块**。表现就是"这个标题点不动、删不掉"。
/// 修复见 `PATCHES.md` 补丁 22；本测试用**渲染树里文字的真实位置**点击
/// （不是 getRectsInSelection 反推——那条路在带 children 时自己就会偏），
/// 钉住"点标题文字必须选中该 heading"。
void main() {
  testWidgets('带子节点的 heading：点标题文字选中它自己（不被 zero-rect 子节点抢走）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 用户真实库里的形态：heading 带一个 paragraph 子节点。
    const String content = '''
{"v":2,"format":"blocks","document":{"type":"page","children":[
{"type":"paragraph","data":{"delta":[{"insert":"上文\\r"}]}},
{"type":"heading","children":[{"type":"paragraph","data":{"delta":[{"insert":"子节点内容\\r"}]}}],"data":{"level":1,"delta":[{"insert":"我在这里"}]}},
{"type":"paragraph","data":{"delta":[{"insert":"下文\\r"}]}}
]}}''';
    final Note note = Note(
      id: 'n1',
      kind: NoteKind.note,
      title: '有一篇标题的笔记',
      content: content,
      plainText: '我在这里',
      summary: '我在这里',
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
          builder: (BuildContext context, Widget? child) =>
              // ignore: deprecated_member_use
              MaterialUiCompatibilityBridge(child: child!),
          home: const Scaffold(body: NoteEditorViewAppFlowy(noteId: 'n1')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final EditorState state = tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
    final Node heading = state.document.root.children
        .where((Node n) => n.type == HeadingBlockKeys.type)
        .single;

    // 屏幕里「我在这里」那段 RichText 的真实中心（= 用户手指/鼠标点的地方）。
    Offset? tapPoint;
    for (final Element e in find.byType(RichText).evaluate()) {
      final RichText rich = e.widget as RichText;
      if (!rich.text.toPlainText().contains('我在这里')) continue;
      final RenderBox box = e.renderObject! as RenderBox;
      if (!box.hasSize) continue;
      tapPoint = box.localToGlobal(box.size.center(Offset.zero));
      break;
    }
    expect(tapPoint, isNotNull, reason: '屏幕上找不到「我在这里」这段文字');

    await tester.tapAt(tapPoint!);
    await tester.pumpAndSettle();
    expect(
      state.selection?.start.path,
      heading.path,
      reason: '点标题文字应选中该 heading（补丁 22 前会落到前一个块）',
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
