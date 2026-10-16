import 'package:flutter/gestures.dart';
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

  testWidgets('标题栏无目的地导航：目的地不在条内；历史钮在条内左端且与内容卡对齐', (
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
    // 上一步 / 下一步：2026-10-15 用户定**加回标题栏左端**（左缘由
    // leadingInset = 侧栏宽 ⇒ 与内容卡左缘对齐）；栈空时置灰（不进 Tab 链）。
    expect(
      find.byTooltip('上一步（Alt+←）'),
      findsOneWidget,
      reason: '上一步钮在标题栏左簇',
    );
    expect(
      find.byTooltip('下一步（Alt+→）'),
      findsOneWidget,
      reason: '下一步钮在标题栏左簇',
    );
    // 左缘与内容卡左缘严格对齐（内容卡左缝为 0 ⇒ 就是侧栏宽）。
    final Rect backRect = tester.getRect(find.byTooltip('上一步（Alt+←）'));
    expect(
      backRect.left,
      closeTo(Tokens.sidebarWidth, 0.5),
      reason: '左簇与内容卡左缘对齐（侧栏宽）',
    );
    // 条内垂直居中（条高 32 ⇒ 中心 16）。
    expect(
      backRect.center.dy,
      closeTo(Tokens.titleBarHeightMain / 2, 0.5),
      reason: '左簇在条内垂直居中',
    );
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
    expect(find.byKey(const Key('new-note-trigger')), findsOneWidget,
        reason: '新建胶囊（图标模式）在 HomeSidebar');

    // 顶条几何：全宽贴顶，高 44（拖拽区铺满，故仍通栏）。
    final Rect strip = tester.getRect(find.byType(WindowStrip));
    expect(strip.top, closeTo(0, 0.5));
    expect(strip.left, closeTo(0, 0.5));
    expect(strip.right, closeTo(1200, 0.5));
    expect(strip.height, closeTo(32, 0.5));

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
    expect(aiRect.top, greaterThan(32), reason: '问笔记钮不在 32 顶条内');
    expect(
      aiRect.right,
      closeTo(1200 - Tokens.appPanelInset - Tokens.spaceXs, 0.5),
      reason: '右角钮：距内容卡内缘 4px',
    );
    expect(
      aiRect.top + aiRect.height / 2,
      // 面板顶部 = 顶条 32 + 顶缝（[AppTheme.surfaceRingRetreat]，2026-10-15
      // 起 1；以前是 spaceXxs=2）⇒ 中心 = 其下 20。
      // ⚠️ 必须**从常量推**：写成字面量的话，调顶缝这条几何断言会悄悄漂。
      closeTo(32 + AppTheme.surfaceRingRetreat + 20, 1),
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
    expect(find.byKey(const Key('new-note-trigger')), findsOneWidget,
        reason: '新建胶囊（图标模式）在 HomeSidebar');

    // 默认视图 = 心流。
    expect(container.read(navHistoryProvider).view, HomeView.timeline);

    // 编辑态：HomeHub 被编辑器替换，但 HomeSidebar 在工作区级常驻 ⇒ 视图导航 /
    // 新建胶囊**两态都在**（与已删的左索引面板同一条"常驻"原则）。
    final Note note = await container.read(notesProvider.notifier).createNote();
    container.read(locateProvider.notifier).locate(noteId: note.id);
    await tester.pumpAndSettle();
    expect(find.byType(HomeHub), findsNothing, reason: '编辑器态不渲染 HomeHub');
    expect(find.byType(HomeSidebar), findsOneWidget, reason: '侧栏两态常驻');
    expect(find.byKey(const Key('new-note-trigger')), findsOneWidget,
        reason: '新建胶囊（图标模式）编辑器态仍可见');
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
    expect(stripInEditor.height, closeTo(32, 0.5));
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

    // 胶囊默认**收起**（只显示图标），两半在悬停/键盘聚焦触发钮后才出现。
    // 点「新建」枢纽 = 聚焦即展开，且**不创建**任何东西（用户 2026-10-12 定
    // "主按钮不可点"）。先以此触发展开，同时验证它不创建。
    await tester.tap(find.byKey(const Key('new-note-trigger')));
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
    // 触发钮常驻可见（图标模式，2026-10-15 坐品牌行右端）⇒ 用其 Key 定位；
    // 文字标签改为 Tooltip '新建'（屏幕不显示，a11y 仍可读）。
    expect(find.byKey(const Key('new-note-trigger')), findsOneWidget);
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

    // 用掉后胶囊**主动收起**（两枚钮卸载、焦点环残留一并清掉）⇒ 画布钮已不在
    //（BUG 回归：以前会留在展开态 + 无障碍选中态）。
    expect(
      find.byTooltip('新建画布（Ctrl+Shift+N）'),
      findsNothing,
      reason: '用完即收：不再留在展开态、也不留焦点环',
    );

    // HomeSidebar 两态常驻 ⇒ 重新点「新建」展开，再点「画布」建的是画布（不用回主页）。
    await tester.tap(find.byKey(const Key('new-note-trigger')));
    await tester.pumpAndSettle();
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

  testWidgets('新建胶囊：点击钉住后，鼠标离开也必须收起（不卡住）', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    final Offset at = tester.getCenter(find.byKey(const Key('new-note-trigger')));
    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    // 鼠标按下到「新建」上（同时触发 MouseRegion onEnter ⇒ 悬停展开）。
    await gesture.down(at);
    await tester.pumpAndSettle();
    expect(find.byTooltip('新建笔记（Ctrl+N）'), findsOneWidget, reason: '悬停即展开');

    // 松开 ⇒ 「新建」onTap 切到"钉住展开"态。
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byTooltip('新建笔记（Ctrl+N）'), findsOneWidget, reason: '点击后仍展开');

    // 鼠标挪出胶囊 ⇒ **必须收起**（修复前：钉住态不随鼠标离开收起 ⇒ 卡住）。
    // ⚠️ 收起走 200ms 延迟定时器：pumpAndSettle 在没有帧可跑时**不推进假时钟**，
    // 定时器永远不响 ⇒ 必须显式 pump 推过 200ms 再 settle。
    await gesture.moveTo(const Offset(2, 2));
    await gesture.removePointer();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(
      find.byTooltip('新建笔记（Ctrl+N）'),
      findsNothing,
      reason: '鼠标离开一律收起，不卡在钉住态',
    );
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

  // 2026-10-15 面板契约（承接已删的 panelShadow/panelEdge 主题闸门，改在真实
  // 外壳上钉）：① 底色 = ladder 的 panelFill（画布页同档，切笔记类型不"变色"）；
  // ② **明暗同规则**——都只叠一条发丝环 [AppTheme.surfaceRing]（外扩 1px 的
  // shadow spread，不占布局、不被子级盖住）；③ **无柔影**（暗色黑影无对比度，
  // 立体感由明度阶梯 + 环 + 圆角承担）；④ 不再用 border + foregroundDecoration
  // 兜底那套。
  // ⚠️ 明暗**必须分成两条** testWidgets：同一测试体里连 pump 两棵 App 会让
  // 第一棵的挂起定时器（AI 轨过渡等）在收尾时炸 "!timersPending"。
  for (final Brightness brightness in Brightness.values) {
    testWidgets('工作区浮面卡（$brightness）：panelFill 实面 + 只有发丝环 + 无柔影', (
      WidgetTester tester,
    ) async {
      setSurfaceSize(tester, 1200, 900);
      mockWindowManager(tester);
      final ProviderContainer c = buildContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            navigatorKey: appNavigatorKey,
            theme: brightness == Brightness.light
                ? AppTheme.light()
                : AppTheme.dark(),
            home: const HomeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder panels = find.byWidgetPredicate((Widget w) {
        if (w is! DecoratedBox) return false;
        final Object d = w.decoration;
        if (d is! BoxDecoration) return false;
        return d.color == AppTheme.panelFill(brightness) &&
            d.borderRadius is BorderRadius &&
            (d.borderRadius as BorderRadius).topLeft.x == Tokens.radiusMd;
      });
      expect(
        panels,
        findsWidgets,
        reason: '$brightness：找不到 panelFill 浮面卡（主卡 / AI 卡）',
      );
      for (final Element e in panels.evaluate()) {
        final DecoratedBox w = e.widget as DecoratedBox;
        final BoxDecoration d = w.decoration as BoxDecoration;
        // 明暗**同规则**：都只有一条发丝环（外扩 1px 的 shadow spread），**不含柔影**。
        // [DecoratedBox] 本就没有 foregroundDecoration 位 ⇒ 收边不可能走 border 兜底，
        // 只可能是下面这条 boxShadow 环。
        final List<BoxShadow>? shadows = d.boxShadow;
        expect(
          shadows,
          isNotNull,
          reason: '$brightness：浮面卡必须有发丝环（明度阶梯 + 环 + 圆角 = 立体）',
        );
        expect(
          shadows!.length,
          1,
          reason: '$brightness：只能有一条环，不许混进柔影',
        );
        expect(
          shadows.single.blurRadius,
          0,
          reason: '$brightness：亮线必须无模糊（有 blur 就是投影不是线）',
        );
        // 四边都画 ⇒ 整圈外扩 1px（spread=1）。⚠️ 前提：每个方向都有"缝"可待
        // （顶 2px / 左 0 / 右 4 / 底 4）——左侧刻意 0 缝，线落在侧栏那一列
        // 像素上（用户 2026-10-15 接受）；顶 / 右 / 下都落在缝里。
        expect(
          shadows.single.spreadRadius,
          1,
          reason: '$brightness：亮线靠 spread 外扩 1px；spread=0 等于没画'
              '（影子与盒子重合、被盒子自己盖住）',
        );
        expect(
          shadows.single.offset,
          Offset.zero,
          reason: '$brightness：整圈等宽 ⇒ 不许有偏移（有偏移就只露两边）',
        );
      }
    });
  }

}
