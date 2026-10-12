import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/home_hub.dart';
import 'package:sinan/src/app/home_screen.dart';
import 'package:sinan/src/app/home_sidebar.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/app/settings_panel.dart' show appNavigatorKey;
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/tokens.dart';
import 'package:sinan/src/window/app_title_bar.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// **全宽顶条 + 内嵌浮面的导航结构**（2026-10-09 用户定，opencode 风；
/// 替代当日早上的 50 最左图标轨）。
///
/// 钉的是这几条结构性事实：
/// ① **标题栏不放导航**（2026-10-12 用户定：取消左侧索引面板后，四枚目的地
///    + 新建胶囊搬到工作区**左侧扁平导航** [HomeSidebar]，无面板、贴窗口底）；
///    上一步 / 下一步 的 UI 入口已撤（功能仍在全局键 `Alt+←/→`）。条内只剩
///    拖拽区 + 右簇设置钮 + 窗控；
/// ② 条下无分割线：工作区是 8px 环缝内的圆角浮面卡（HomeHub 几何即卡几何）；
/// ③ 问笔记不是顶条钮：它是工作区右角折叠钮，钉在内容卡内缘 4px、y 与编辑页
///    顶栏「标签」耳按钮同高；
/// ④ 视图切换与进编辑器都走统一历史栈，按点击顺序进退（`Alt+←/→` 或 provider）。
void main() {
  /// `WindowStrip` / 窗控按钮在 initState 里问 window_manager（isFocused /
  /// isMaximized）。测试环境没有插件，补一个返回假值的通道 mock。
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

  /// 全量内存库覆写：HomeScreen 主页分支会读 notes / settings 等真实 provider。
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

  /// 改测试视口的逻辑尺寸（dpr 锁定 1 ⇒ physical 即 logical），用完还原。
  void setSurfaceSize(WidgetTester tester, double width, double height) {
    final TestFlutterView view = tester.view;
    final Size oldSize = view.physicalSize;
    final double oldDpr = view.devicePixelRatio;
    view
      ..devicePixelRatio = 1
      ..physicalSize = Size(width, height);
    addTearDown(() {
      view
        ..physicalSize = oldSize
        ..devicePixelRatio = oldDpr;
    });
  }

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    double width = 1200,
  }) async {
    setSurfaceSize(tester, width, 900);
    mockWindowManager(tester);
    final ProviderContainer container = buildContainer();
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();
    return container;
  }

  /// 四枚目的地的名称（= [HomeView.label]，左侧 [HomeSidebar] 导航文字）。
  const List<String> kDestinations = <String>['心流', '全部', '日历', '收藏'];

  /// 点左侧 [HomeSidebar] 的某个视图导航（切换主区视图）。
  Future<void> tapViewTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: find.byType(HomeSidebar), matching: find.text(label)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('标题栏无导航：目的地/时间轴都不在条内，条只剩拖拽区+设置+窗控', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pump(tester);

    // 2026-10-12 用户定：四枚目的地搬到左侧 [HomeSidebar] ⇒ 标题栏
    // **不放任何导航**。这是反向断言：钉住"搬走了"，防止哪天又被塞回条内。
    for (final String label in kDestinations) {
      expect(
        find.byTooltip(label),
        findsNothing,
        reason: '$label 是左侧 HomeSidebar 的纯文字导航（无 tooltip），标题栏不该再有',
      );
    }
    expect(find.byTooltip('上一步'), findsNothing, reason: '时间轴 UI 入口已撤（功能在 Alt+←/→）');
    expect(find.byTooltip('下一步'), findsNothing, reason: '时间轴 UI 入口已撤（功能在 Alt+←/→）');
    // 视图导航 + 新建胶囊在工作区左侧扁平导航（HomeSidebar）上。
    expect(container.read(navHistoryProvider).view, HomeView.timeline);
    expect(find.byType(HomeHub), findsOneWidget, reason: '主页态渲染 HomeHub');
    for (final String label in kDestinations) {
      expect(
        find.descendant(of: find.byType(HomeSidebar), matching: find.text(label)),
        findsOneWidget,
        reason: 'HomeSidebar 必须有视图导航：$label',
      );
    }
    expect(find.text('新建'), findsOneWidget, reason: '新建胶囊在 HomeSidebar');

    // 顶条几何：全宽贴顶，高 44（拖拽区铺满，故仍通栏）。
    final Rect strip = tester.getRect(find.byType(WindowStrip));
    expect(strip.top, closeTo(0, 0.5));
    expect(strip.left, closeTo(0, 0.5));
    expect(strip.right, closeTo(1200, 0.5));
    expect(strip.height, closeTo(44, 0.5));

    // 右簇：设置钮紧挨「最小化」左侧（与窗控成组）。
    final Rect minRect = tester.getRect(find.byTooltip('最小化'));
    final Rect settingsRect = tester.getRect(find.byTooltip('设置'));
    expect(
      minRect.left - settingsRect.right,
      inInclusiveRange(-0.5, 4),
      reason: '设置紧贴「最小化」左侧',
    );

    // 问笔记是工作区**右角折叠钮**（不在条内）：钉内容卡内缘 4px、y 与编辑页
    // 顶栏「标签」耳按钮同高（中心 20）。
    final Rect aiRect = tester.getRect(find.byTooltip('问笔记（Ctrl+J）'));
    expect(aiRect.top, greaterThan(44), reason: '问笔记钮不在 44 顶条内');
    expect(
      aiRect.right,
      closeTo(1200 - Tokens.appPanelInset - Tokens.spaceXs, 0.5),
      reason: '右角钮：距内容卡内缘 4px',
    );
    expect(
      aiRect.top + aiRect.height / 2,
      closeTo(44 + 20, 1),
      reason: '右角钮与编辑页顶栏「标签」耳按钮同高（内容区顶部下 20）',
    );
    expect(container.read(aiPanelOpenProvider), isFalse, reason: '默认未开');
  });

  testWidgets('HomeSidebar：四枚视图导航带图标、新建胶囊两态常驻', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pump(tester);

    // 四枚目的地以**视图导航**形式常驻左侧 HomeSidebar（心流 / 全部 / 日历 / 收藏）。
    // 导航是文字行（不是 IconButton）⇒ 用 find.text 定位。
    for (final String label in kDestinations) {
      expect(
        find.descendant(of: find.byType(HomeSidebar), matching: find.text(label)),
        findsOneWidget,
        reason: 'HomeSidebar 必须有视图导航：$label',
      );
    }
    // 导航带目的地图标（复用 HomeViewIcon ⇒ 与原标题栏同一套图形）：
    // 心流 = 时钟，用 Clock 的 tooltip/语义不方便，改为断言图标节点存在。
    expect(
      find.descendant(of: find.byType(HomeSidebar), matching: find.byType(Row)),
      findsWidgets,
      reason: '导航是含图标的行',
    );
    // 新建胶囊也在 HomeSidebar 常驻。
    expect(find.text('新建'), findsOneWidget, reason: '新建胶囊在 HomeSidebar');

    // 默认视图 = 心流。
    expect(container.read(navHistoryProvider).view, HomeView.timeline);

    // 编辑态：HomeHub 被编辑器替换，但 HomeSidebar 在工作区级常驻 ⇒ 视图导航 /
    // 新建胶囊**两态都在**（与已删的左索引面板同一条"常驻"原则）。
    final Note note = await container.read(notesProvider.notifier).createNote();
    container.read(locateProvider.notifier).locate(noteId: note.id);
    await tester.pumpAndSettle();
    expect(find.byType(HomeHub), findsNothing, reason: '编辑器态不渲染 HomeHub');
    expect(find.byType(HomeSidebar), findsOneWidget, reason: '侧栏两态常驻');
    expect(find.text('新建'), findsOneWidget, reason: '新建胶囊编辑器态仍可见');
    for (final String label in kDestinations) {
      expect(
        find.descendant(of: find.byType(HomeSidebar), matching: find.text(label)),
        findsOneWidget,
        reason: '编辑态视图导航仍常驻：$label',
      );
    }

    // 顶条仍是同一条全宽条（编辑器不另起一条、也不长回导航）。
    final Rect stripInEditor = tester.getRect(find.byType(WindowStrip));
    expect(stripInEditor.left, closeTo(0, 0.5));
    expect(stripInEditor.right, closeTo(1200, 0.5));
    expect(stripInEditor.height, closeTo(44, 0.5));
    expect(find.byTooltip('心流'), findsNothing, reason: '标题栏不放导航');
  });

  testWidgets('顶条目的地切视图驱动统一历史：切到日历后箭头可退回、可重做', (WidgetTester tester) async {
    final ProviderContainer container = await pump(tester);

    // 起点是「心流」（2026-10-05 决策 C 的默认视图），点左侧 HomeSidebar「日历」导航换视图。
    expect(container.read(navHistoryProvider).view, HomeView.timeline);
    await tapViewTab(tester, '日历');
    expect(container.read(navHistoryProvider).view, HomeView.calendar);

    // 上一步：退回「心流」。UI 入口已撤，走 provider（与全局键 Alt+←/→ 同一条路）。
    container.read(navHistoryProvider.notifier).goBack();
    await tester.pumpAndSettle();
    expect(container.read(navHistoryProvider).view, HomeView.timeline);
    expect(container.read(navHistoryProvider).canGoBack, isFalse, reason: '退到底了');

    // 下一步：重做，回到日历。
    container.read(navHistoryProvider.notifier).goForward();
    await tester.pumpAndSettle();
    expect(container.read(navHistoryProvider).view, HomeView.calendar);
  });

  testWidgets('编辑器在统一历史栈里：切心流→上一步=回笔记，再上一步=回日历', (WidgetTester tester) async {
    final ProviderContainer container = await pump(tester);

    // 与真实点击路径一致：点左侧 HomeSidebar「日历」导航换视图，再走 locateProvider
    // 打开笔记（卡片 / 列表的入口同路）。
    await tapViewTab(tester, '日历');
    final Note note = await container.read(notesProvider.notifier).createNote();
    container.read(locateProvider.notifier).locate(noteId: note.id);
    await tester.pumpAndSettle();

    // 时间轴按钮已从标题栏撤掉（UI 入口无，Alt+←/→ 仍在）。
    expect(find.byTooltip('上一步'), findsNothing);
    expect(find.byTooltip('下一步'), findsNothing);

    // HomeSidebar 两态常驻 ⇒ 编辑器里直接点「心流」导航离开编辑器、落回「心流」，
    // 并把"这篇笔记"记入统一历史。
    await tapViewTab(tester, '心流');
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull, reason: '先离开编辑器');
    expect(
      container.read(navHistoryProvider).view,
      HomeView.timeline,
      reason: '心流是默认落地页（2026-10-05 决策 C）',
    );

    // 上一步：按点击顺序回到刚离开的那篇笔记（重新打开编辑器）。
    container.read(navHistoryProvider.notifier).goBack();
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), note.id, reason: '退回笔记');

    // 再上一步：回到进笔记前的「日历」视图。
    container.read(navHistoryProvider.notifier).goBack();
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull, reason: '离开编辑器');
    expect(container.read(navHistoryProvider).view, HomeView.calendar);

    // 下一步×2：原路重做——先回笔记，再回心流。
    container.read(navHistoryProvider.notifier).goForward();
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), note.id);
    container.read(navHistoryProvider.notifier).goForward();
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull);
    expect(container.read(navHistoryProvider).view, HomeView.timeline);
    expect(container.read(navHistoryProvider).canGoForward, isFalse, reason: '进到底了');
  });

  testWidgets('HomeSidebar 新建胶囊：两半各是一个动作，走 note.new / canvas.new', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pump(tester);

    final int before = container.read(notesProvider).value?.length ?? 0;

    // 胶囊默认**收起**（只显示「新建 ▾」），两半在悬停/键盘聚焦「新建」后才出现。
    // 点「新建」枢纽 = 聚焦即展开，且**不创建**任何东西（用户 2026-10-12 定
    // "主按钮不可点"）。先以此触发展开，同时验证它不创建。
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    expect(
      container.read(notesProvider).value?.length ?? before,
      before,
      reason: '点「新建」枢纽（外胶囊）不创建任何东西',
    );
    expect(container.read(selectedNoteIdProvider), isNull, reason: '外胶囊不可点');

    // 展开后两半都在（tooltip 同时是 a11y 标签 ⇒ 用它们定位），且**不是**单选组：
    // 没有 SegmentedButton，两半各自是一个按钮。
    expect(find.byTooltip('新建笔记（Ctrl+N）'), findsOneWidget);
    expect(find.byTooltip('新建画布（Ctrl+Shift+N）'), findsOneWidget);
    // 「新建」标签常驻可见（动词不靠 hover 才知道）——2026-10-12 用户定：标签放
    // 左侧、不可点、无「＋」前缀。
    expect(find.text('新建'), findsOneWidget);
    expect(
      find.byType(SegmentedButton<Object>),
      findsNothing,
      reason: '新建是自绘内嵌胶囊，不是 M3 SegmentedButton（那是单选语义）',
    );
    // 两枚内胶囊带文字（不是纯图标）⇒ 辨识度不依赖 hover。
    expect(find.text('笔记'), findsOneWidget);
    expect(find.text('画布'), findsOneWidget);
    expect(find.text('＋ 笔记'), findsNothing, reason: '不带「＋」前缀（用户定）');

    // 点「笔记」⇒ 真的建了一篇笔记并跳进去（走 note.new，与 Ctrl+N 同一条路）。
    await tester.tap(find.byTooltip('新建笔记（Ctrl+N）'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNotNull, reason: '新建后立刻选中');

    // HomeSidebar 两态常驻 ⇒ 建完笔记落到编辑器，胶囊仍在侧栏且仍展开 ⇒ 直接
    // 再点「画布」建的是画布（不用回主页）。
    await tester.tap(find.byTooltip('新建画布（Ctrl+Shift+N）'));
    await tester.pumpAndSettle();
    final String? id = container.read(selectedNoteIdProvider);
    expect(id, isNotNull, reason: '新建后立刻选中');
    final Note current = container
        .read(notesProvider)
        .value!
        .firstWhere((Note n) => n.id == id);
    expect(current.kind, NoteKind.canvas, reason: '走 canvas.new ⇒ 建出来是画布');
  });

  testWidgets('标题栏不放搜索入口（主页页内搜索态 / 编辑器 Ctrl+F / 全局 Ctrl+K）', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pump(tester);

    // 标题栏不挂搜索图标 / 胶囊（2026-10-01 用户定）：主页搜索是页内状态、
    // 编辑器有 Ctrl+F 内容查找、全局跳转统一走 Ctrl+K。
    expect(find.byTooltip('快速跳转（Ctrl+K）'), findsNothing);
    expect(find.text('Ctrl+K'), findsNothing);

    // 进编辑器后标题栏同样没有入口（Ctrl+K 键位由命令元测试钉，本 harness
    // 不挂 main() 里的全局键盘分发，故这里只断言可见入口）。
    final Note note = await container.read(notesProvider.notifier).createNote();
    container.read(locateProvider.notifier).locate(noteId: note.id);
    await tester.pumpAndSettle();
    expect(find.byTooltip('快速跳转（Ctrl+K）'), findsNothing);
    expect(find.text('Ctrl+K'), findsNothing);
  });

}
