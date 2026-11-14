import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/home_hub.dart';
import 'package:sinan/src/app/home_screen.dart';
import 'package:sinan/src/app/note_list_column.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/app/settings_panel.dart' show appNavigatorKey;
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/tokens.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// **日历视图布局契约**（2026-11-14 用户定）。
///
/// 日期面板搬到笔记列表列的位置：同样 [Tokens.noteListWidth](240) 宽、同样
/// 可折叠，但内容是月份网格而不是笔记行 ⇒ 不复用 [NoteListColumn]（它写死了
/// 搜索 / 筛选 / 新建分半钮）。日历页**不要筛选与搜索**。
///
/// 数据口径是「日记」：按 `createdAt` 归组、笔记与画布混排显示、不受后来
/// 修改日期影响；写日记入口只新建笔记。
void main() {
  void mockWindowManager(WidgetTester tester) {
    const MethodChannel channel = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      MethodCall call,
    ) async {
      return switch (call.method) {
        'isFocused' || 'isMaximized' || 'isFullScreen' => false,
        _ => null,
      };
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
  }

  ProviderContainer buildContainer() {
    final Database db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    final ProviderContainer container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noteStoreProvider.overrideWithValue(NoteStore(db)),
        settingsStoreProvider.overrideWithValue(SettingsStore(db)),
        appDataDirProvider.overrideWithValue(r'C:\test\sinan'),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
    return container;
  }

  Widget app(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      navigatorKey: appNavigatorKey,
      theme: AppTheme.light(),
      home: const HomeScreen(),
    ),
  );

  Future<ProviderContainer> pumpCalendar(
    WidgetTester tester, {
    List<String> titles = const <String>[],
    List<String> canvasTitles = const <String>[],
  }) async {
    final TestFlutterView view = tester.view;
    view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1280, 800);
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
    mockWindowManager(tester);

    final ProviderContainer container = buildContainer();
    final List<String> ids = <String>[];
    for (final String t in titles) {
      final Note n = await container.read(notesProvider.notifier).createNote();
      await container.read(notesProvider.notifier).saveTitle(n.id, t);
      ids.add(n.id);
    }
    for (final String t in canvasTitles) {
      final Note n = await container
          .read(notesProvider.notifier)
          .createNote(kind: NoteKind.canvas);
      await container.read(notesProvider.notifier).saveTitle(n.id, t);
      ids.add(n.id);
    }
    container.read(navHistoryProvider.notifier).selectHome(HomeView.calendar);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('日历：左 240 列 + 右内容、可折叠、无筛选与搜索入口', (WidgetTester tester) async {
    final ProviderContainer container = await pumpCalendar(tester);

    expect(find.byType(CalendarListColumn), findsOneWidget);
    expect(find.byType(CalendarDayContent), findsOneWidget);
    expect(
      find.byType(NoteListColumn),
      findsNothing,
      reason: '日历列不复用写死了搜索/筛选/新建的笔记列',
    );
    expect(
      tester.getSize(find.byType(CalendarListColumn)).width,
      Tokens.noteListWidth,
      reason: '列宽与笔记页一致（240）',
    );
    expect(find.byTooltip('筛选与排序'), findsNothing, reason: '日历页不需要筛选');
    expect(find.byTooltip('搜索'), findsNothing, reason: '日历页不需要搜索');

    // 折叠钮文案按视图变，且按下去真的生效（旧整卡日历里它按了没反应）。
    final Finder collapse = find.byTooltip('收起日历');
    expect(collapse, findsOneWidget);
    await tester.tap(collapse);
    await tester.pumpAndSettle();
    expect(container.read(listCollapsedProvider), isTrue);
    expect(find.byTooltip('展开日历'), findsOneWidget);
  });

  testWidgets('日历列头部与笔记列同构：折叠位留空、标题同位、内容区底色区分', (WidgetTester tester) async {
    final ProviderContainer container = await pumpCalendar(tester);
    final Rect column = tester.getRect(find.byType(CalendarListColumn));
    final Rect month = tester.getRect(find.text('${DateTime.now().month} 月'));

    // ① 折叠钮占 y=4..32、x=7..35 ⇒ 月份标题必须在它下方（工具行留 36）。
    expect(month.top, greaterThanOrEqualTo(36), reason: '工具行要把折叠钮的位置空出来');
    // ② 标题左缘与笔记列「视图名」同为 spaceMd(12)。
    expect(month.left, closeTo(column.left + Tokens.spaceMd, 1));
    // 标题行**只放月份**：紧挨月份放篇数会被读成「10 月 54 日」
    //（2026-11-14 用户实报），本月新建数交给绿点与右内容区表达。
    final Finder titleRow = find
        .ancestor(
          of: find.text('${DateTime.now().month} 月'),
          matching: find.byType(Row),
        )
        .first;
    expect(
      find.descendant(of: titleRow, matching: find.byType(Text)),
      findsOneWidget,
      reason: '标题行不该再有篇数文字',
    );

    // ③ 内容区与头部区分：通栏 surface 底色（不是又套一张卡）。
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w is ColoredBox && w.color == Bauhaus.surface(Brightness.light),
      ),
      findsOneWidget,
      reason: '内容区要有自己的底色，与头部区分',
    );

    // ④ 切到笔记视图，标题基线一致。
    container.read(navHistoryProvider.notifier).selectHome(HomeView.notes);
    await tester.pumpAndSettle();
    final Rect noteLabel = tester.getRect(find.text('笔记'));
    expect(
      (month.center.dy - noteLabel.center.dy).abs(),
      lessThan(2),
      reason: '日历的月份标题与「笔记」标题同一 y',
    );
  });

  testWidgets('日记口径：同一天笔记 + 画布都显示，改标题也不会挪到别的日期', (WidgetTester tester) async {
    final ProviderContainer container = await pumpCalendar(
      tester,
      titles: const <String>['甲笔记'],
      canvasTitles: const <String>['乙画布'],
    );

    // 两类结果混排，计数是合计（用户定：不加分项计数）。
    expect(find.textContaining('新建 2 篇', findRichText: true), findsOneWidget);
    // 二元标记：有内容的那天铺**一整块浅绿圆角方底**；绿点已撤、
    // 也不编码篇数（2026-11-14 用户定「只要这天写了就行」）。
    final Color entryFill = AppTheme.calendarEntryFill(Brightness.light);
    Finder entryFills() => find.descendant(
      of: find.byType(CalendarListColumn),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color == entryFill,
      ),
    );
    expect(entryFills(), findsOneWidget, reason: '有新建的那天铺浅绿底');
    expect(
      find.byWidgetPredicate((Widget w) => w is Positioned && w.bottom == 2),
      findsNothing,
      reason: '绿点已撤',
    );
    expect(
      find.descendant(
        of: find.byType(CalendarListColumn),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).shape == BoxShape.circle,
        ),
      ),
      findsNothing,
      reason: '状态底与今天描边都改成圆角方形',
    );

    expect(
      find.textContaining('甲笔记', findRichText: true),
      findsOneWidget,
      reason: '笔记结果要显示',
    );
    expect(
      find.textContaining('乙画布', findRichText: true),
      findsOneWidget,
      reason: '画布结果也要显示',
    );

    // 改标题会推进 revisedAt，但日历按 createdAt 归组 ⇒ 仍留在今天。
    final List<Note> all = container.read(notesProvider).value!;
    final Note first = all.firstWhere((Note n) => n.title == '甲笔记');
    await container.read(notesProvider.notifier).saveTitle(first.id, '甲笔记改');
    await tester.pumpAndSettle();
    expect(find.textContaining('甲笔记改', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('新建 2 篇', findRichText: true),
      findsOneWidget,
      reason: '改过的内容仍算今天新建，篇数不变',
    );

    // 再加 3 篇（同一天）⇒ 篇数 2→5，网格标记仍是同一块浅绿底：
    // 二元标记不随篇数变化，确数只由右内容区负责。
    for (int i = 0; i < 3; i++) {
      await container.read(notesProvider.notifier).createNote();
    }
    await tester.pumpAndSettle();
    expect(entryFills(), findsOneWidget, reason: '二元标记不随篇数变化');
    expect(
      find.textContaining('新建 5 篇', findRichText: true),
      findsOneWidget,
      reason: '确数在右内容区如实增长',
    );
  });

  testWidgets('空态：没有新建内容（文案同时涵盖笔记与画布）', (WidgetTester tester) async {
    await pumpCalendar(tester);
    expect(find.textContaining('这天没有新建内容', findRichText: true), findsOneWidget);
  });
}
