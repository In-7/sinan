import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/home_hub.dart' show CanvasThumbnailView;
import 'package:sinan/src/app/home_screen.dart';
import 'package:sinan/src/app/note_list_column.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 列表里的画布笔记行 → **整图鸟瞰总览卡**（2026-11-21 用户定）：
/// 一篇画布 = 一行鸟瞰（苹果无边记式），不是把一张画布拆成几条卡片；
/// `all` 视图里的画布行同样生效。行高固定 72 ⇒ 虚拟列表不跳。
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

  /// 搭一台宽面 HomeScreen（1200 > 列表断点），建 1 篇笔记 + 1 篇画布。
  Future<ProviderContainer> pumpHome(
    WidgetTester tester, {
    required HomeView view,
  }) async {
    final TestFlutterView flutterView = tester.view;
    flutterView.devicePixelRatio = 1;
    flutterView.physicalSize = const Size(1200, 900);
    addTearDown(() {
      flutterView.devicePixelRatio = 3;
      flutterView.physicalSize = const Size(2400, 1800);
    });
    mockWindowManager(tester);

    final Database db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    final NoteStore store = NoteStore(db);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noteStoreProvider.overrideWithValue(store),
        settingsStoreProvider.overrideWithValue(SettingsStore(db)),
        appDataDirProvider.overrideWithValue(r'C:\test\sinan'),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);

    store.create(title: '文字笔记');
    store.create(title: '画布甲', kind: NoteKind.canvas);
    container.read(navHistoryProvider.notifier).selectHome(view);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Finder inList(Finder of) =>
      find.descendant(of: find.byType(NoteListColumn), matching: of);

  testWidgets('画布视图：画布行 = 标题 + 72px 鸟瞰，文字笔记行不受影响', (tester) async {
    await pumpHome(tester, view: HomeView.canvas);

    expect(inList(find.text('画布甲')), findsOneWidget, reason: '标题仍是 Text');
    expect(inList(find.byType(CanvasThumbnailView)), findsOneWidget,
        reason: '画布行有整图鸟瞰');
    expect(inList(find.text('文字笔记')), findsNothing, reason: '画布视图只列画布');

    // 鸟瞰块固定 72：SizedBox 直接包着 CanvasThumbnailView。
    final Finder sized = find.ancestor(
      of: find.byType(CanvasThumbnailView),
      matching: find.byType(SizedBox),
    );
    expect(sized, findsWidgets);
    final SizedBox box = tester.widget<SizedBox>(sized.first);
    expect(box.height, 72, reason: '画布鸟瞰固定 72px');
  });

  testWidgets('全部视图：画布行也有鸟瞰，笔记行仍是文字预览', (tester) async {
    await pumpHome(tester, view: HomeView.all);

    expect(inList(find.text('画布甲')), findsOneWidget);
    expect(inList(find.text('文字笔记')), findsOneWidget);
    // 只有一篇画布 ⇒ 全列表恰好一枚鸟瞰，等价于"画布行画了、笔记行没画"。
    expect(inList(find.byType(CanvasThumbnailView)), findsOneWidget,
        reason: 'all 视图里画布行同样画鸟瞰（视觉一致），笔记行不画');
  });

  testWidgets('鸟瞰加载前后行高不变（虚拟列表不跳）', (tester) async {
    await pumpHome(tester, view: HomeView.canvas);

    // provider 是 FutureProvider：pumpHome 已 pumpAndSettle，慢路径也已落地。
    // 这里再取鸟瞰组件外层的固定高 SizedBox 断言——它不依赖 thumb 状态，
    // 所以加载 / 空 / 有数据三态都是同一个 72。
    final Finder thumb = find.byType(CanvasThumbnailView);
    final Finder sized = find.ancestor(
      of: thumb,
      matching: find.byType(SizedBox),
    );
    final SizedBox box = tester.widget<SizedBox>(sized.first);
    expect(box.height, 72);
    final double h1 = tester.getRect(thumb.first).height;

    // 触发一次重建（hover 不改变鸟瞰高度）。
    await tester.pump();
    final double h2 = tester.getRect(find.byType(CanvasThumbnailView).first).height;
    expect(h2, h1, reason: '重建前后鸟瞰高度一致');
  });

  testWidgets('画布行仍可点开、点中走 locateProvider', (tester) async {
    final ProviderContainer container = await pumpHome(
      tester,
      view: HomeView.canvas,
    );

    await tester.tap(inList(find.text('画布甲')));
    await tester.pumpAndSettle();

    final Note? opened = container
        .read(notesProvider)
        .value
        ?.where((Note n) => n.title == '画布甲')
        .cast<Note?>()
        .first;
    expect(opened, isNotNull);
    expect(
      container.read(selectedNoteIdProvider),
      opened!.id,
      reason: '点画布行标题即选中（鸟瞰块不改变点击链路）',
    );
  });
}
