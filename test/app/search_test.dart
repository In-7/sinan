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

  /// 标签筛选（2026-09-26）：chips 点选 = 过滤（有词）或标签视图（无词），
  /// 再点取消。钉的是筛选契约，不是 chip 的样式。
  ///
  /// 回归价值：`selectTag` 忘了过滤（或 `_search` 落地不带 activeTag）都会让
  /// "点了标签结果不变"，这条直接红。
  testWidgets('标签 chips：点选过滤命中，清词落标签视图，再点取消', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = newContainer();

    // A：标题命中 + 有标签；B：仅内容命中 + 无标签。
    final a = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(a.id, '番茄工作法笔记');
    await container.read(notesProvider.notifier).saveTags(a.id, <String>['工作法']);
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

    // chips 行已出现（A 有标签 ⇒ 池子非空）。
    expect(find.text('工作法'), findsOneWidget);

    // 无查询词点 chip ⇒ 标签视图：只列 A。
    await tester.tap(find.text('工作法'));
    await tester.pumpAndSettle();
    expect(find.text('番茄工作法笔记'), findsOneWidget);
    expect(find.text('读书摘抄'), findsNothing);

    // 再点 chip = 取消 ⇒ 回空态。
    await tester.tap(find.text('工作法'));
    await tester.pumpAndSettle();
    expect(find.text('番茄工作法笔记'), findsNothing);

    // 有查询词（两条命中）再点 chip ⇒ 内存过滤，只剩 A。
    await tester.enterText(find.byType(TextField), '番茄');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('番茄工作法笔记'), findsOneWidget);
    expect(find.text('读书摘抄'), findsOneWidget);

    await tester.tap(find.text('工作法'));
    await tester.pumpAndSettle();
    expect(find.text('番茄工作法笔记'), findsOneWidget);
    expect(
      find.text('读书摘抄'),
      findsNothing,
      reason: 'B 没有该标签，必须被筛掉',
    );

    // 清词（Esc / 清空按钮）不丢标签筛选 ⇒ 落回标签视图。
    await tester.tap(find.byTooltip('清空（Esc）'));
    await tester.pumpAndSettle();
    expect(find.text('番茄工作法笔记'), findsOneWidget);
    expect(find.text('读书摘抄'), findsNothing);
  });

  /// 摘掉标签后结果必须**跟着走**（2026-09-26 实机 bug）：hits 是静态快照，
  /// 不 listen 列表的话——chips 实时消失、带标签的文章却还挂在结果里。
  /// 钉三层：摘一篇收窄一档；最后一篇摘掉时池子空、chips 消失、筛选一并撤
  /// （不给"死 chip 对应的空列表"）。
  testWidgets('摘掉标签：结果列表同步收窄，最后一个摘掉时连筛选一起撤', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = newContainer();
    final a = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(a.id, '甲');
    final b = await container.read(notesProvider.notifier).createNote();
    await container.read(notesProvider.notifier).saveTitle(b.id, '乙');
    await container.read(notesProvider.notifier).saveTags(a.id, <String>['工作法']);
    await container.read(notesProvider.notifier).saveTags(b.id, <String>['工作法']);

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

    // 标签视图：甲 + 乙（丙不存在，这里只有两篇）。
    await tester.tap(find.text('工作法'));
    await tester.pumpAndSettle();
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsOneWidget);

    // 摘掉甲的标签 ⇒ 甲立即从结果里消失，乙还在（chip 仍在、篇数变 1）。
    await container.read(notesProvider.notifier).saveTags(a.id, <String>[]);
    await tester.pumpAndSettle();
    expect(
      find.text('甲'),
      findsNothing,
      reason: '标签摘了，结果列表不许还挂着这篇（快照不同步的实机 bug）',
    );
    expect(find.text('乙'), findsOneWidget);

    // 摘掉乙的 ⇒ 池子空、chip 消失、筛选一并撤（回空态而非空结果页）。
    await container.read(notesProvider.notifier).saveTags(b.id, <String>[]);
    await tester.pumpAndSettle();
    expect(
      find.text('工作法'),
      findsNothing,
      reason: '最后一篇的标签摘掉后，chip 必须消失',
    );
    expect(find.text('乙'), findsNothing);
  });
}
