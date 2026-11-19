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

/// 反链面板 × 灵感来源（2026-11-19 用户定：**不进双链**）。
///
/// 灵感转笔记只在灵感页的「已处理」台账单向记录（`stream_exports`），**不反向**
/// 投到笔记的双链面板——双链只认结构化引用边（ref 块 / 画布卡）。
/// 这里是**反向闸门**：钉住"复制进来的灵感不出现在反链面板"，防将来又接回去。
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

  testWidgets('复制进来的灵感**不**出现在反链面板（只在台账单向记录）', (WidgetTester tester) async {
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
                  child: BacklinkPanel(noteId: target.id, onOpenNote: (_) {}),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 灵感原文**不出**现在反链面板（只有结构化引用才进双链）。
    expect(find.text('想清楚的那句话'), findsNothing);
    expect(find.text('来自灵感'), findsNothing);
    // 没有结构化引用 ⇒ 走空态引导。
    expect(find.text('还没有笔记引用这里。\n在别处输入「引用笔记」就能建立链接'), findsOneWidget);
  });

  testWidgets('空态：既无引用也无灵感来源时，还是那句引导', (WidgetTester tester) async {
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
                  child: BacklinkPanel(noteId: lonely.id, onOpenNote: (_) {}),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有笔记引用这里。\n在别处输入「引用笔记」就能建立链接'), findsOneWidget);
    expect(find.text('来自灵感'), findsNothing);
  });
}

class _FakeNotes extends NotesNotifier {
  _FakeNotes(this.notes);

  final List<Note> notes;

  @override
  Future<List<Note>> build() async => notes;
}
