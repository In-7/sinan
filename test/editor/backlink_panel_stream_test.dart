import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/stream_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/editor/panels/backlink_panel.dart';
import 'package:sinan/src/theme/app_float_surface.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sqlite3/sqlite3.dart';

/// 反链面板的**速记侧**（双链的另一半，2026-10-18）。
///
/// 结构化引用（ref 块 / 画布卡）的反链早就有了；这里钉的是**复制**这类快照边——
/// 它没有结构化痕迹，只存在于台账 `stream_exports`，所以必须由面板反过来读。
void main() {
  late Database db;
  late NoteStore store;
  late StreamStore streams;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    store = NoteStore(db);
    streams = StreamStore(db);
  });

  tearDown(() => db.close());

  testWidgets('「来自速记」段：列出来源、手法与原文；点它去心流定位', (WidgetTester tester) async {
    final Note target = store.create(title: '周五的闲聊');
    final StreamItem s = streams.add('想清楚的那句话')!;
    expect(store.copyStreamIntoNote(s.id, target.id), isTrue);

    final ProviderContainer container = ProviderContainer(
      overrides: [
        notesProvider.overrideWith(() => _FakeNotes(<Note>[target])),
        noteStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    await container.read(notesProvider.future);

    String? opened;
    // 挂载环境**照生产**：编辑器的气泡经 Overlay 挂到根 Overlay，外层是
    // `AppFloatSurface`（它负责提供 Material 祖先，见 tags_panel 的同类回归）。
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (BuildContext _) => AppFloatSurface(
                  width: BacklinkPanel.width,
                  padding: EdgeInsets.zero,
                  child: BacklinkPanel(
                    noteId: target.id,
                    onOpenNote: (_) {},
                    onOpenStream: (String id) => opened = id,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('来自速记'), findsOneWidget);
    expect(find.text('想清楚的那句话'), findsOneWidget, reason: '原文当上下文');
    expect(find.text('复制'), findsOneWidget, reason: '手法要说清');

    await tester.tap(find.text('想清楚的那句话'));
    await tester.pumpAndSettle();
    expect(opened, s.id, reason: '点它 = 心流页定位这一条');
  });

  testWidgets('空态：既无引用也无速记来源时，还是那句引导', (WidgetTester tester) async {
    final Note lonely = store.create(title: '谁都没引用我');

    final ProviderContainer container = ProviderContainer(
      overrides: [
        notesProvider.overrideWith(() => _FakeNotes(<Note>[lonely])),
        noteStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    await container.read(notesProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (BuildContext _) => AppFloatSurface(
                  width: BacklinkPanel.width,
                  padding: EdgeInsets.zero,
                  child: BacklinkPanel(
                    noteId: lonely.id,
                    onOpenNote: (_) {},
                    onOpenStream: (_) {},
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('还没有笔记引用这里。\n在别处输入「引用笔记」就能建立链接'),
      findsOneWidget,
    );
    expect(find.text('来自速记'), findsNothing);
  });
}

class _FakeNotes extends NotesNotifier {
  _FakeNotes(this.notes);

  final List<Note> notes;

  @override
  Future<List<Note>> build() async => notes;
}
