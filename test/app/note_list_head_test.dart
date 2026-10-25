import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/home_screen.dart';
import 'package:sinan/src/app/note_list_column.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/editor/core/note_title_field.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/tokens.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// **列表头**的四个交互（2026-10-21 用户定，复刻 ima 的头部）：
///
/// ① 折叠钮在**内容卡左上角**，折叠（收到 0）/ 展开时**位置不变**；
/// ② 工具行右端三枚：新建 / 搜索 / 筛选；
/// ③ 点 ⌕ 展开输入框、输入即过滤、Esc 收起；
/// ④ `+ ▾` 的箭头**能开托盘**（`MenuAnchor` 不会自动响应点击，必须由按钮自己
///    `controller.open()`——第一版漏了这步，箭头点了没反应，新建菜单 / 导入全
///    用不了，故这条测试是那次返工的闸门）。
void main() {
  void mockWindowManager(WidgetTester tester) {
    const MethodChannel channel = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall call) async {
        return switch (call.method) {
          'isFocused' || 'isMaximized' || 'isFullScreen' => false,
          _ => null,
        };
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
  }

  Future<ProviderContainer> pumpList(WidgetTester tester) async {
    final TestFlutterView view = tester.view;
    view.devicePixelRatio = 1;
    view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      view.devicePixelRatio = 3;
      view.physicalSize = const Size(2400, 1800);
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

    store.create(title: '甲');
    store.create(title: '乙');
    container.read(navHistoryProvider.notifier).selectHome(HomeView.notes);

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

  /// 只认 [Text]（排除输入框的 `EditableText`——搜索框里也有同样的字）。
  Finder listText(String s) => inList(
    find.byWidgetPredicate((Widget w) => w is Text && w.data == s),
  );

  testWidgets('折叠钮：折叠到 0 后仍在原坐标（位置不变）', (tester) async {
    await pumpList(tester);

    final Finder collapse = find.byTooltip('收起列表');
    expect(collapse, findsOneWidget, reason: '内容卡左上角要有折叠钮');
    final Rect before = tester.getRect(collapse);

    await tester.tap(collapse);
    await tester.pumpAndSettle();

    expect(find.byTooltip('展开列表'), findsOneWidget, reason: '折叠后钮还在');
    final Rect after = tester.getRect(find.byTooltip('展开列表'));
    expect(
      after.topLeft,
      before.topLeft,
      reason: '折叠 / 展开都在同一坐标——按钮位置不变',
    );
  });

  testWidgets('搜索：点 ⌕ 展开输入框，输入即过滤，Esc 收起', (tester) async {
    await pumpList(tester);

    expect(listText('甲'), findsOneWidget);
    expect(listText('乙'), findsOneWidget);

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(inList(find.byType(TextField)), findsOneWidget, reason: '出现输入框');

    await tester.enterText(inList(find.byType(TextField)), '乙');
    await tester.pumpAndSettle();
    expect(listText('甲'), findsNothing, reason: '没命中 ⇒ 滤掉');
    expect(listText('乙'), findsOneWidget);

    // Esc ⇒ 收起并清词，列表恢复。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(inList(find.byType(TextField)), findsNothing, reason: 'Esc 收起');
    expect(listText('甲'), findsOneWidget, reason: '清词后恢复');
  });

  testWidgets('新建：点 + 直建当前页类型（笔记页建笔记）', (tester) async {
    final ProviderContainer container = await pumpList(tester);
    final int before = container.read(notesProvider).value!.length;

    await tester.tap(find.byTooltip('新建笔记'));
    await tester.pumpAndSettle();

    expect(
      container.read(notesProvider).value!.length,
      before + 1,
      reason: '新建一篇',
    );
    expect(container.read(selectedNoteIdProvider), isNotNull);
  });

  testWidgets('头部标尺：与编辑页撤销 / 重做同一 y、同一 30 热区', (tester) async {
    // 2026-10-22 用户定：列表顶部按钮的**位置与大小**要和编辑页头部那排一致
    // （上留白 5 + 热区 30 + 图标 20）。先开一篇笔记让编辑器渲染出撤销钮，
    // 再逐个比矩形——纯肉眼对齐很难看出 2px 差。
    final ProviderContainer container = await pumpList(tester);
    container.read(locateProvider.notifier).locate(
      noteId: container.read(notesProvider).value!.first.id,
    );
    await tester.pumpAndSettle();

    // **带高锚点**（2026-10-22 热区 30→28 时最怕断的那一根）：编辑页按钮带高
    // = 上留白 + 热区 + 下留白，必须仍是 [Tokens.brandStripHeight](40)（侧栏
    // 「logo + 应用名」行的锚）。标题行就挂在带下面 ⇒ 量它离卡顶的距离即可。
    final Rect column = tester.getRect(find.byType(NoteListColumn));
    final Rect title = tester.getRect(find.byType(NoteTitleField));
    expect(
      title.top - column.top,
      Tokens.brandStripHeight,
      reason: '编辑页按钮带高要仍锚着侧栏页头 40（标题行位置不能漂）',
    );

    // 编辑器那两个钮是 M3 `IconButton`：**可视 30、热区被 tap target 撑到 46**。
    // 所以按**中心**比（中心相同 = 视觉同一行），另外单独钉列表侧是 30 的可视盒。
    final Rect undo = tester.getRect(find.byTooltip('撤销（Ctrl+Z）'));
    final double undoCenter = undo.center.dy;
    for (final String tip in <String>['新建笔记', '搜索', '更多新建选项', '收起列表']) {
      final Rect r = tester.getRect(find.byTooltip(tip));
      expect(
        r.height,
        Tokens.headerActionSize,
        reason: '「$tip」的可视热区要是 30（与撤销钮的图标盒同档）',
      );
      expect(
        (r.center.dy - undoCenter).abs(),
        lessThan(1.5),
        reason: '「$tip」要与撤销钮落在同一条竖向位置（r=$r undo=$undo）',
      );
    }
  });

  testWidgets('托盘：点箭头能开（新建笔记 / 新建画布 / 导入）', (tester) async {
    await pumpList(tester);

    // 先确认托盘是**收起**的（菜单项不在树上）。
    expect(find.text('导入 Markdown…'), findsNothing);

    await tester.tap(find.byTooltip('更多新建选项'));
    await tester.pumpAndSettle();

    // ⚠️ 这条是返工闸门：`MenuAnchor` 不会自动响应点击 ⇒ 箭头必须自己 open。
    expect(find.text('新建笔记'), findsOneWidget, reason: '托盘要能开出来');
    expect(find.text('新建画布'), findsOneWidget);
    expect(find.text('导入 Markdown…'), findsOneWidget, reason: '导入项在托盘里');
  });
}
