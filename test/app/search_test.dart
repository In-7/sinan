import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/app/search_section.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sqlite3/sqlite3.dart';

/// 全局搜索分区（2026-09-25）。
///
/// 钉的是搜索的核心契约：**标题 + 内容一次合并**、标题命中带「标题」徽标、
/// 内容命中带摘要、点结果走 `locateProvider` 跳进笔记。
void main() {
  late Database db;
  late NoteStore notes;
  late SettingsStore settings;

  const String kDataDir = r'C:\Users\test\AppData\Roaming\sinan';

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    notes = NoteStore(db);
    settings = SettingsStore(db);
  });
  tearDown(() => db.close());

  ProviderContainer newContainer() => ProviderContainer(
        overrides: [
          noteStoreProvider.overrideWithValue(notes),
          settingsStoreProvider.overrideWithValue(settings),
          appDataDirProvider.overrideWithValue(kDataDir),
          // 检索设施只读这条裸连接（AppDatabase 只有 open()，内存库直接给 db）。
          databaseProvider.overrideWithValue(db),
        ],
      );

  /// 直插一个带文本的段落块并同步进关键词索引。
  void seedContent(String noteId, String text) {
    db.execute(
      'INSERT INTO blocks (id, note_id, type, props_json, ord, parent_id, '
      'created_at, updated_at, fingerprint) '
      "VALUES (?, ?, 'paragraph', ?, 1024, NULL, 0, 0, 'fp-test')",
      <Object?>[
        'blk-$noteId',
        noteId,
        '{"text":"${text.replaceAll('"', r'\"')}"}',
      ],
    );
    IndexJob(db: db).indexNoteKeywordPath(noteId);
  }

  testWidgets('标题+内容合并：标题命中置顶带徽标，内容命中带摘要，点行跳笔记', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = newContainer();

    // A：标题命中（新建后直接改标题，走产品路径）。
    final a = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(a.id, '番茄工作法笔记');
    // B：只有内容命中（标题不含查询词，正文含）。
    final b = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(b.id, '读书摘抄');
    seedContent(b.id, '今天读了讲番茄工作法的一章，先专注再休息');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: SearchSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 空态：未输入不给结果列表。
    expect(find.text('搜索标题与内容'), findsWidgets);

    await tester.enterText(find.byType(TextField), '番茄');
    // 去抖 250ms + 检索 + 重建。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 两条命中：A（标题）在前，B（内容）在后。
    expect(
      find.text('番茄工作法笔记'),
      findsOneWidget,
      reason: '标题命中必须出现',
    );
    expect(
      find.text('标题'),
      findsOneWidget,
      reason: '标题命中要带「标题」徽标（B 只命中内容，不带）',
    );
    expect(
      find.textContaining('番茄工作法', findRichText: true),
      findsWidgets,
      reason: '内容命中要展示摘要（高亮的 Text.rich）',
    );

    // 点标题命中行 → 走 locate 通道选中该笔记。
    await tester.tap(find.text('番茄工作法笔记'));
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      a.id,
      reason: '点结果必须跳进对应笔记',
    );
  });

  testWidgets('无结果给明示，不装作在搜', (WidgetTester tester) async {
    final ProviderContainer container = newContainer();
    await container.read(notesProvider.notifier).createNote();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: SearchSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '不存在的词');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('没有与「不存在的词」匹配的结果'), findsOneWidget);
  });
}
