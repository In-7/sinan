import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/home_hub.dart'
    show homeItemsProvider, homeKindFacetProvider;
import 'package:sinan/src/app/home_screen.dart';
import 'package:sinan/src/app/note_list_column.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/focus_ring.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 笔记列表列的 **↑/↓ 键盘选**（2026-10-17 用户定；曾两度触雷回退，此测试钉住）。
///
/// 钉四条：
/// ① 点行 → 开（走 [locateProvider]，入历史）；
/// ② ↑/↓ → 预览切上/下一篇（[LocateNotifier.preview]：**不入导航历史**——连续浏览
///    不该把前进/后退栈刷爆，`Alt+←` 一步回到点开前，而不是逐篇回退）；
/// ③ 两端钳制：末行再 ↓ 不动、首行再 ↑ 不动；
/// ④ 列表在宽面（≥ [noteListBreakpoint]）常开——窄窗自动折是另一条断点，此处不混测。
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

  testWidgets('↑/↓ 预览选中（不入历史）+ 点行开 + 两端钳制', (tester) async {
    // dpr 锁 1 ⇒ physical 即 logical；1200 宽 > noteListBreakpoint(1040) ⇒ 列表常开。
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

    // 建三篇（同视图、默认"最近编辑在前"排序 ⇒ 列表顺序由 provider 定；测试自读、
    // 不假设方向，避免同毫秒创建时排序不稳定）。
    store.create(title: '甲');
    store.create(title: '乙');
    store.create(title: '丙');

    // 列表列只服务「全部 / 收藏」；灵感不走主从布局（见 home_screen 的
    // 视图分发）。所以这里先把视图切到「全部」再挂载。
    container.read(navHistoryProvider.notifier).selectHome(HomeView.all);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // 列表实际渲染顺序（与列表列同一个 [homeItemsProvider] ⇒ 自洽）。
    final List<Note> ordered = container.read(
      homeItemsProvider((
        view: HomeView.all,
        tag: null,
        kind: container.read(homeKindFacetProvider),
      )),
    );
    expect(ordered.length, 3, reason: '三篇都在列表里');
    expect(find.byType(NoteListColumn), findsOneWidget, reason: '宽面列表常开');

    // ① 点首行 → 开（locate：选中 + 入历史；焦点留在**行**上——编辑器不抢，
    //   这样紧接着按 ↑/↓ 能继续在列表里走，见 note_editor_view 的 autoFocus 注释）。
    await tester.tap(find.text(ordered.first.title));
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      ordered.first.id,
      reason: '点行即开（选中该篇）',
    );
    expect(
      container.read(navHistoryProvider).canGoBack,
      isTrue,
      reason: '点行开笔记 = 一次导航（入历史）',
    );

    // ② ↓ → 下一篇（预览，不入历史）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      ordered[1].id,
      reason: '↓ 切下一篇',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      ordered[2].id,
      reason: '再 ↓ 切再下一篇',
    );

    // ③ 两端钳制。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      ordered[2].id,
      reason: '末行再 ↓ 不动',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      ordered[0].id,
      reason: '↑↑ 回首行',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      ordered[0].id,
      reason: '首行再 ↑ 不动',
    );

    // ②（续）预览不入历史：连按 ↓↑ 之后「上一步」应一步回到点开前的主页空态，
    // 而非逐篇回退（若每篇预览都入栈，这里会落在中间某篇）。
    await tester.tap(find.byTooltip('上一步（Alt+←）'));
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      isNull,
      reason: '↑/↓ 预览不入历史：上一步直接回主页空态',
    );
    expect(
      container.read(navHistoryProvider).canGoForward,
      isTrue,
      reason: '回退后可在“下一步”重进点开的那篇',
    );
  });

  testWidgets('悬浮不挤动布局；删除在右键菜单里', (tester) async {
    // 2026-10-21：hover 曾插入删除钮（行宽变化 ⇒ 标题折行/右移）；随后删除**整体
    // 收进右键菜单**。两条一起钉：hover 不出现任何行内按钮、几何完全不动，
    // 右键能拿到「删除」。
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

    // 标题够长：若行宽被挤，省略号位置会变 ⇒ 宽度可测地缩水。
    const String title = '一个足够长的标题用来观察是否被删除按钮挤动';
    store.create(title: title);
    container.read(navHistoryProvider.notifier).selectHome(HomeView.all);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final Finder titleFinder = find.text(title);
    expect(titleFinder, findsOneWidget);
    final Rect before = tester.getRect(titleFinder);
    expect(find.byTooltip('删除'), findsNothing, reason: '行内已无删除钮');

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(before.center);
    await tester.pumpAndSettle();

    expect(find.byTooltip('删除'), findsNothing, reason: 'hover 不再出现行内按钮');
    final Rect after = tester.getRect(titleFinder);
    expect(after.left, before.left, reason: '标题左缘不动');
    expect(after.width, before.width, reason: '标题宽度不动（无重排）');
    expect(after.top, before.top, reason: '标题行高不动');

    // 右键 ⇒ 条目菜单里能拿到「删除」。
    await tester.tap(titleFinder, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget, reason: '右键菜单提供删除');
  });

  testWidgets('列表按时间分组：今天 / 昨天组头，行内不再显示日期', (tester) async {
    // 2026-10-21 方案 A：组头替行内日期说话（行内"2 天前"整列取消）。
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

    // 用 restore 精确钉 revisedAt（create 只给当下）。
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day, 9);
    final DateTime yesterday = today.subtract(const Duration(days: 1));
    Future<void> put(String id, DateTime at) => store.restore(
      Note(
        id: id,
        kind: NoteKind.note,
        title: id,
        content: '',
        plainText: '',
        summary: '',
        contentHash: '',
        createdAt: at,
        revisedAt: at,
      ),
    );
    await put('今日笔记', today);
    await put('昨日笔记', yesterday);
    container.invalidate(notesProvider);
    container.read(navHistoryProvider.notifier).selectHome(HomeView.all);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    Finder inColumn(String t) => find.descendant(
      of: find.byType(NoteListColumn),
      matching: find.text(t),
    );
    expect(inColumn('今天'), findsOneWidget, reason: '今天的组头');
    expect(inColumn('昨天'), findsOneWidget, reason: '昨天的组头');
    expect(
      tester.getRect(inColumn('今天')).top,
      lessThan(tester.getRect(inColumn('昨天')).top),
      reason: '最近编辑倒序 ⇒ 今天那组在昨天之前',
    );
    expect(inColumn('今日笔记'), findsOneWidget);
    expect(inColumn('昨日笔记'), findsOneWidget);
    expect(inColumn('刚刚'), findsNothing, reason: '行内不再显示相对时间');
  });

  testWidgets('列表行按 noteId 钉 key（Element 复用不串行）', (tester) async {
    // 2026-10-21：`ListView.builder` 按下标复用 Element，行没 key 时行的 State
    // （hover / 键盘焦点锚）会跟着位置走，新建插到最前就错配到别的笔记。
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

    final List<Note> seeded = <Note>[
      for (int i = 0; i < 3; i++) store.create(title: '甲$i'),
    ];
    container.read(navHistoryProvider.notifier).selectHome(HomeView.all);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    for (final Note n in seeded) {
      expect(
        find.descendant(
          of: find.byType(NoteListColumn),
          matching: find.byKey(ValueKey<String>('note-row-${n.id}')),
        ),
        findsOneWidget,
        reason: '每行都要有自己的 key（${n.title}）',
      );
    }
  });

  testWidgets('点击可见行不滚动（不"置顶"）', (tester) async {
    // 2026-10-21 用户实报"点击后会置顶"：根因是 `Scrollable.ensureVisible` 默认
    // alignment 0 ⇒ 把目标行对齐到视口**顶端**，点一行本来就可见的笔记也会猛滚。
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

    // 24 篇 ⇒ 列表可滚（900 高下大约只放得下 13 行）。
    for (int i = 0; i < 24; i++) {
      store.create(title: '笔记 $i');
    }
    container.read(navHistoryProvider.notifier).selectHome(HomeView.all);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final Finder listScroll = find.descendant(
      of: find.byType(NoteListColumn),
      matching: find.byType(Scrollable),
    );
    final ScrollPosition pos = tester
        .state<ScrollableState>(listScroll)
        .position;
    pos.jumpTo(pos.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    final double before = pos.pixels;
    expect(before, greaterThan(0), reason: '先滚到中部');

    // 点一处**当前可见**的行（列表头下方 120px，稳落在某行内）。
    final Rect list = tester.getRect(find.byType(NoteListColumn));
    await tester.tapAt(Offset(list.center.dx, list.top + 120));
    await tester.pumpAndSettle();

    expect(
      container.read(selectedNoteIdProvider),
      isNotNull,
      reason: '点的是某一行的行体，应确实打开一篇',
    );
    expect(pos.pixels, before, reason: '点击可见行不该滚动列表（不"置顶"）');
  });

  testWidgets('点行不出蓝框（环只给键盘）', (tester) async {
    // 2026-10-21 用户实报"列表有蓝色选中框"：点行会 requestFocus（为了 ↑/↓ 的
    // 键盘锚）⇒ FocusRing 一见焦点就画 primary 蓝环，被误读成选中态。
    // 现在环只在**键盘**聚焦时出现（与 60 轨一致）。
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
    container.read(navHistoryProvider.notifier).selectHome(HomeView.all);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // 打开后编辑器标题也叫「甲」⇒ 必须限定在**列表列**里找，否则找到两个。
    final Finder titleFinder = find.descendant(
      of: find.byType(NoteListColumn),
      matching: find.text('甲'),
    );
    final Finder rowRing = find.descendant(
      of: find.ancestor(of: titleFinder, matching: find.byType(FocusRing)),
      matching: find.byWidgetPredicate(
        (Widget w) => w is Container && w.foregroundDecoration != null,
      ),
    );
    expect(rowRing, findsNothing, reason: '初始无环');

    // 鼠标点行 ⇒ 选中，但**不戴蓝框**。
    await tester.tap(titleFinder);
    await tester.pumpAndSettle();
    expect(
      container.read(selectedNoteIdProvider),
      store.allNotes().single.id,
      reason: '点行即选中',
    );
    expect(rowRing, findsNothing, reason: '鼠标点出来的焦点不该画环');

    // **用户实报的场景**：按的键不是遍历键（Ctrl+N / Ctrl+K 这类命令键）⇒
    // 即使行随后被程序化聚焦，也不该出蓝框。
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    tester
        .widget<FocusRing>(
          find.ancestor(of: titleFinder, matching: find.byType(FocusRing)),
        )
        .focusNode
        .requestFocus();
    await tester.pumpAndSettle();
    expect(rowRing, findsNothing, reason: '非遍历键之后的聚焦不该出蓝框');

    // 遍历键（Tab / 方向键 / Home·End·PageUp·PageDown）之后 ⇒ 环必须回来，
    // 否则键盘用户在列表里就失去"我在哪"的指示。
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(rowRing, findsOneWidget, reason: '遍历键之后的聚焦要出环');

    // 指针按下 ⇒ 立刻熄灭。
    await tester.tap(titleFinder);
    await tester.pumpAndSettle();
    expect(rowRing, findsNothing, reason: '点一下就熄灭');
  });
}
