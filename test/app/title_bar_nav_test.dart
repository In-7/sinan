import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/app_icon_rail.dart';
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
import 'package:sinan/src/window/app_title_bar.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// **全宽顶条 + 内嵌浮面的导航结构**（2026-10-09 用户定，opencode 风；
/// 替代当日早上的 50 最左图标轨）。
///
/// 钉的是这几条结构性事实：
/// ① **标题栏不放目的地导航**（2026-10-12 用户定：取消左侧索引面板后，四枚目的地
///    + 新建胶囊搬到工作区**左侧扁平导航** [AppIconRail]，无面板、贴窗口底）；
///    上一步 / 下一步 在条内左簇（内容卡左缘 + 12px 呼吸，不随布局移动，
///    2026-10-19 用户定），栈空置灰；
/// ② 条下无分割线：工作区是 8px 环缝内的圆角浮面卡（CalendarPage 几何即卡几何）；
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

  /// 四枚目的地的名称（= [HomeView.label]，左侧 [AppIconRail] 导航文字）。
  const List<String> kDestinations = <String>['灵感', '全部', '日历', '收藏'];

  /// 点左侧 [AppIconRail] 的某个视图导航（切换主区视图）。
  Future<void> tapViewTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: find.byType(AppIconRail), matching: find.byTooltip(label)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('标题栏无目的地导航：目的地不在条内；历史钮在内容卡左缘内缩 12px', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pump(tester);

    // 2026-10-12 用户定：四枚目的地搬到左侧导航（2026-10-16 起是 [AppIconRail] 48
    // 图标轨）⇒ 标题栏 **不放任何导航**。反向断言：钉住"搬走了"，防止又被塞回条内。
    for (final String label in kDestinations) {
      expect(
        find.descendant(
          of: find.byType(WindowStrip),
          matching: find.byTooltip(label),
        ),
        findsNothing,
        reason: '$label 在左侧 AppIconRail（tooltip），标题栏不该再有',
      );
    }
    // 上一步 / 下一步：2026-10-19 用户定**内容卡左缘 + 12px 呼吸**；
    // 两枚钮相接、位置不随列表折叠 / 视图移动。栈空时置灰（不进 Tab 链）。
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
    final Rect backRect = tester.getRect(find.byTooltip('上一步（Alt+←）'));
    final Rect forwardRect = tester.getRect(find.byTooltip('下一步（Alt+→）'));
    // 两枚钮相接（64 宽簇）。
    expect(
      backRect.right,
      closeTo(forwardRect.left, 0.5),
      reason: '两枚钮相接',
    );
    // 内容卡左缘（轨宽 60）+ 12px 呼吸。
    expect(
      backRect.left,
      closeTo(Tokens.railWidth + Tokens.spaceMd, 0.5),
      reason: '历史簇在内容卡左缘内缩 12px',
    );
    // 条内垂直居中（条高 32 ⇒ 中心 16）。
    expect(
      backRect.center.dy,
      closeTo(Tokens.titleBarHeightMain / 2, 0.5),
      reason: '左簇在条内垂直居中',
    );
    // 视图导航 + 新建胶囊在工作区左侧扁平导航（AppIconRail）上。
    expect(container.read(navHistoryProvider).view, HomeView.timeline);
    // 2026-10-17：灵感 = **灵感页**（一页纸流），不做主从布局 ⇒ 默认视图里
    // 没有列表列；列表列只服务「全部 / 收藏」（下面切过去再验）。
    expect(find.byType(NoteListColumn), findsNothing);
    expect(find.text('记下此刻的想法…'), findsOneWidget, reason: '灵感是灵感页');
    await tapViewTab(tester, '全部');
    expect(find.byType(NoteListColumn), findsOneWidget,
        reason: '全部 / 收藏才走主从列表列');
    // 固定锚点：切到「全部」（列表 + 折叠钮出现）后历史簇位置不变。
    final Rect backAll = tester.getRect(find.byTooltip('上一步（Alt+←）'));
    expect(
      backAll.left,
      closeTo(backRect.left, 0.5),
      reason: '历史簇不随列表/折叠钮出现而移动',
    );
    for (final String label in kDestinations) {
      expect(
        find.descendant(of: find.byType(AppIconRail), matching: find.byTooltip(label)),
        findsOneWidget,
        reason: 'AppIconRail 必须有视图导航：$label',
      );
    }
    expect(find.byKey(const Key('new-note-trigger')), findsOneWidget,
        reason: '新建胶囊（图标模式）在 AppIconRail');

    // 顶条几何：全宽贴顶，高 44（拖拽区铺满，故仍通栏）。
    final Rect strip = tester.getRect(find.byType(WindowStrip));
    expect(strip.top, closeTo(0, 0.5));
    expect(strip.left, closeTo(0, 0.5));
    expect(strip.right, closeTo(1200, 0.5));
    expect(strip.height, closeTo(32, 0.5));

    // 右簇：设置、问笔记都在 `trailing`，紧贴「最小化」左侧（与窗控成组）；问笔记
    // 2026-10-16 从工作区右角搬来，夹在设置右、最小化左之间。仍以 [aiPanelOpenProvider]
    // 单布尔开合。
    final Rect minRect = tester.getRect(find.byTooltip('最小化'));
    final Rect settingsRect = tester.getRect(find.byTooltip('设置'));
    final Rect aiRect = tester.getRect(find.byTooltip('问笔记（Ctrl+J）'));
    // 三钮都在 32 顶条内（贴顶、占满条高）。
    for (final Rect r in <Rect>[settingsRect, aiRect, minRect]) {
      expect(r.top, lessThan(32), reason: '钮在 32 顶条内');
      expect(r.bottom, lessThanOrEqualTo(32.5), reason: '钮占满顶条高');
    }
    // 顺序：设置 → 问笔记 → 最小化，问笔记夹在中间、两侧各紧贴（与窗控成组）。
    expect(aiRect.left - settingsRect.right, inInclusiveRange(-0.5, 4),
        reason: '问笔记紧贴设置右侧');
    expect(minRect.left - aiRect.right, inInclusiveRange(-0.5, 4),
        reason: '问笔记紧贴最小化左侧');
    expect(container.read(aiPanelOpenProvider), isFalse, reason: '默认未开');
  });

  testWidgets('AppIconRail：四枚视图导航带图标、新建胶囊两态常驻', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pump(tester);

    // 四枚目的地以**视图导航**形式常驻最左 AppIconRail（灵感 / 全部 / 日历 / 收藏）。
    // 轨上钮是图标 + tooltip（不是文字行）⇒ 用 find.byTooltip 定位。
    for (final String label in kDestinations) {
      expect(
        find.descendant(of: find.byType(AppIconRail), matching: find.byTooltip(label)),
        findsOneWidget,
        reason: 'AppIconRail 必须有视图导航：$label',
      );
    }
    // 导航带目的地图标（复用 HomeViewIcon ⇒ 与旧标题栏同一套图形）：每个视图钮是
    // 一个含图标的方块（[_RailButton] 的 Container）。
    expect(
      find.descendant(
        of: find.byType(AppIconRail),
        matching: find.byType(Container),
      ),
      findsWidgets,
      reason: '导航钮是含图标的方块',
    );
    // 新建胶囊也在 AppIconRail 常驻。
    expect(find.byKey(const Key('new-note-trigger')), findsOneWidget,
        reason: '新建胶囊（图标模式）在 AppIconRail');

    // 默认视图 = 灵感。
    expect(container.read(navHistoryProvider).view, HomeView.timeline);

    // 编辑态：CalendarPage 被编辑器替换，但 AppIconRail 在工作区级常驻 ⇒ 视图导航 /
    // 新建胶囊**两态都在**（与已删的左索引面板同一条"常驻"原则）。
    final Note note = await container.read(notesProvider.notifier).createNote();
    container.read(locateProvider.notifier).locate(noteId: note.id);
    await tester.pumpAndSettle();
    expect(
      find.byType(CalendarPage),
      findsNothing,
      reason: '编辑器态不渲染日历页（CalendarPage）',
    );
    expect(find.byType(AppIconRail), findsOneWidget, reason: '侧栏两态常驻');
    expect(find.byKey(const Key('new-note-trigger')), findsOneWidget,
        reason: '新建胶囊（图标模式）编辑器态仍可见');
    for (final String label in kDestinations) {
      expect(
        find.descendant(of: find.byType(AppIconRail), matching: find.byTooltip(label)),
        findsOneWidget,
        reason: '编辑态视图导航仍常驻：$label',
      );
    }

    // 顶条仍是同一条全宽条（编辑器不另起一条、也不长回导航）。
    final Rect stripInEditor = tester.getRect(find.byType(WindowStrip));
    expect(stripInEditor.left, closeTo(0, 0.5));
    expect(stripInEditor.right, closeTo(1200, 0.5));
    expect(stripInEditor.height, closeTo(32, 0.5));
    expect(
      find.descendant(
        of: find.byType(WindowStrip),
        matching: find.byTooltip('灵感'),
      ),
      findsNothing,
      reason: '标题栏不放导航',
    );
  });

  testWidgets('顶条目的地切视图驱动统一历史：切到日历后箭头可退回、可重做', (WidgetTester tester) async {
    final ProviderContainer container = await pump(tester);

    // 起点是「灵感」（2026-10-05 决策 C 的默认视图），点左侧 AppIconRail「日历」导航换视图。
    expect(container.read(navHistoryProvider).view, HomeView.timeline);
    await tapViewTab(tester, '日历');
    expect(container.read(navHistoryProvider).view, HomeView.calendar);

    // 上一步：退回「灵感」。UI 入口已撤，走 provider（与全局键 Alt+←/→ 同一条路）。
    container.read(navHistoryProvider.notifier).goBack();
    await tester.pumpAndSettle();
    expect(container.read(navHistoryProvider).view, HomeView.timeline);
    expect(container.read(navHistoryProvider).canGoBack, isFalse, reason: '退到底了');

    // 下一步：重做，回到日历。
    container.read(navHistoryProvider.notifier).goForward();
    await tester.pumpAndSettle();
    expect(container.read(navHistoryProvider).view, HomeView.calendar);
  });

  testWidgets('编辑器在统一历史栈里：切灵感→上一步=回笔记，再上一步=回日历', (WidgetTester tester) async {
    final ProviderContainer container = await pump(tester);

    // 与真实点击路径一致：点左侧 AppIconRail「日历」导航换视图，再走 locateProvider
    // 打开笔记（卡片 / 列表的入口同路）。
    await tapViewTab(tester, '日历');
    final Note note = await container.read(notesProvider.notifier).createNote();
    container.read(locateProvider.notifier).locate(noteId: note.id);
    await tester.pumpAndSettle();

    // 时间轴按钮已从标题栏撤掉（UI 入口无，Alt+←/→ 仍在）。
    expect(find.byTooltip('上一步'), findsNothing);
    expect(find.byTooltip('下一步'), findsNothing);

    // AppIconRail 两态常驻 ⇒ 编辑器里直接点「灵感」导航离开编辑器、落回「灵感」，
    // 并把"这篇笔记"记入统一历史。
    await tapViewTab(tester, '灵感');
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull, reason: '先离开编辑器');
    expect(
      container.read(navHistoryProvider).view,
      HomeView.timeline,
      reason: '灵感是默认落地页（2026-10-05 决策 C）',
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

    // 下一步×2：原路重做——先回笔记，再回灵感。
    container.read(navHistoryProvider.notifier).goForward();
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), note.id);
    container.read(navHistoryProvider.notifier).goForward();
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull);
    expect(container.read(navHistoryProvider).view, HomeView.timeline);
    expect(container.read(navHistoryProvider).canGoForward, isFalse, reason: '进到底了');
  });

  testWidgets('AppIconRail 新建胶囊：两半各是一个动作，走 note.new / canvas.new', (
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

    // AppIconRail 两态常驻 ⇒ 重新点「新建」展开，再点「画布」建的是画布（不用回主页）。
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
  // ② **明暗同规则**——收边统一为 1px 发丝线，颜色 = [AppTheme.surfaceRingColor]；
  //    主卡 / 右栏走 foreground 内描边（2026-10-20 用户定：内描边比外扩环好看），
  //    [AppTheme.surfaceRing] 外扩环作为合法备选保留；③ **无柔影**（暗色黑影无
  //    对比度，立体感由明度阶梯 + 1px 线 + 圆角承担）。
  // ⚠️ 明暗**必须分成两条** testWidgets：同一测试体里连 pump 两棵 App 会让
  // 第一棵的挂起定时器（AI 轨过渡等）在收尾时炸 "!timersPending"。
  for (final Brightness brightness in Brightness.values) {
    testWidgets('工作区浮面卡（$brightness）：panelFill 实面 + 1px 收边 + 无柔影', (
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
        // 收边有**两种**合法形态，取决于外面有没有裁切：
        // - 主内容卡：外扩 1px 的 [AppTheme.surfaceRing]（boxShadow spread）；
        // - AI 轨：外面套着 `ClipRect` 给宽度动画裁切，顶/底/右没有 1px 缝，
        //   外扩环会被裁掉 ⇒ 改走 foreground 1px 内描边（同色），见 `_AiRailSlot`。
        // 两者都**不许**混进柔影（blur > 0）。
        final List<BoxShadow>? shadows = d.boxShadow;
        if (shadows == null || shadows.isEmpty) {
          final DecoratedBox? fg =
              e.findAncestorWidgetOfExactType<DecoratedBox>();
          final BoxDecoration? fd = fg?.decoration as BoxDecoration?;
          final Border? border = fd?.border as Border?;
          expect(
            border,
            isNotNull,
            reason: '$brightness：浮面卡既没有外扩环、也没有 1px 内描边',
          );
          expect(
            border!.top.width,
            1,
            reason: '$brightness：内描边必须 1px',
          );
          expect(
            border.top.color,
            AppTheme.surfaceRingColor(brightness),
            reason: '$brightness：内描边颜色必须与发丝环同色',
          );
          continue;
        }
        expect(
          shadows.length,
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
        expect(
          shadows.single.color,
          AppTheme.surfaceRingColor(brightness),
          reason: '$brightness：环色必须走表面环令牌',
        );
      }
    });
  }

  testWidgets('全局回收站：图标轨底部入口打开浮层（空态）', (WidgetTester tester) async {
    await pump(tester);

    await tester.tap(
      find.descendant(
        of: find.byType(AppIconRail),
        matching: find.byTooltip('回收站'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('回收站 0 条'), findsOneWidget);
    expect(find.text('回收站是空的'), findsOneWidget);
  });

  testWidgets('笔记列表行内删除：确认后进回收站（软删）', (WidgetTester tester) async {
    final ProviderContainer container = await pump(tester);
    await tapViewTab(tester, '全部');

    final NotesNotifier notifier = container.read(notesProvider.notifier);
    final Note note = await notifier.createNote();
    await notifier.saveTitle(note.id, '要删的');
    container.read(locateProvider.notifier).locate(noteId: note.id);
    await tester.pumpAndSettle();

    // 行内删除在 hover / 选中时露出；当前笔记已选中 ⇒ 按钮可见。
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移入回收站'));
    await tester.pumpAndSettle();

    final NoteStore store = container.read(noteStoreProvider);
    expect(store.allNotes().map((Note n) => n.id), isNot(contains(note.id)));
    expect(
      store.listTrashNotes().map((e) => e.id),
      contains(note.id),
      reason: '软删进回收站，不是硬删',
    );
  });
}
