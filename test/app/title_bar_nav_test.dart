import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/home_hub.dart';
import 'package:sinan/src/app/home_screen.dart';
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
/// ① 44 高全宽 [WindowStrip] 左簇**横排**四枚目的地
///    （心流 / 全部 / 日历 / 收藏，36 方块 / 24 图标 + tooltip，
///    主页 / 编辑两态**常驻**；选中披 [AppTheme.selectedPill]，编辑态全灰），
///    16 隔后接时间轴（上一步 / 下一步）；
/// ② 条下无分割线：工作区是 8px 环缝内的圆角浮面卡（HomeHub 几何即卡几何）；
///    右簇 = 设置 + 问笔记（紧贴「最小化」左侧）；
/// ④ 视图切换与进编辑器都走统一历史栈，顶条箭头按点击顺序进退。
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

  IconButton buttonOf(WidgetTester tester, String tooltip) =>
      tester.widget<IconButton>(
        find
            .ancestor(
              of: find.byTooltip(tooltip),
              matching: find.byType(IconButton),
            )
            .first,
      );

  /// 顶条左簇的四枚目的地（tooltip = 视图名）。
  const List<String> kDestinations = <String>['心流', '全部', '日历', '收藏'];

  testWidgets('44 全宽顶条：四枚目的地横排 + 16 隔 + 时间轴；条下 0 缝浮面卡', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pump(tester);

    // ① 四枚目的地都在顶条左簇，36 方块横排（vendored IconButton 子像素取整 ±1）：
    // 首枚贴 x=0、垂直居中于 44 条（top≈4）；水平顺序 心流 < 全部 < 日历 < 收藏，
    // 相邻两枚首尾相接（36 一档，不密堆也不留缝）。
    for (final String label in kDestinations) {
      expect(find.byTooltip(label), findsOneWidget, reason: '顶条必须有：$label');
    }
    final Rect first = tester.getRect(find.byTooltip('心流'));
    expect(first.left, closeTo(0, 1.5), reason: '顶条全宽，左簇贴窗左缘');
    expect(first.height, inInclusiveRange(35, 37), reason: '36 固定方块，上下各 4 呼吸');
    expect(
      first.top,
      inInclusiveRange(3, 5),
      reason: '36 方块在 44 条内垂直居中（top≈4）',
    );
    final List<Rect> destRects = <Rect>[
      for (final String l in kDestinations) tester.getRect(find.byTooltip(l)),
    ];
    for (int i = 1; i < destRects.length; i++) {
      expect(destRects[i - 1].right, closeTo(destRects[i].left, 1.5));
      expect(destRects[i].top, closeTo(first.top, 0.5), reason: '同一水平带');
    }

    // ① 选中态：默认落心流 ⇒ 心流披 selectedPill，其余透明。
    final ColorScheme scheme = AppTheme.light().colorScheme;
    Color? tileFill(String label) => buttonOf(
      tester,
      label,
    ).style?.backgroundColor?.resolve(<WidgetState>{});
    expect(tileFill('心流'), AppTheme.selectedPill(scheme));
    expect(tileFill('全部'), Colors.transparent);
    expect(tileFill('日历'), Colors.transparent);
    expect(tileFill('收藏'), Colors.transparent);

    // 顶条几何：全宽贴顶，高 44。
    final Rect strip = tester.getRect(find.byType(WindowStrip));
    expect(strip.top, closeTo(0, 0.5));
    expect(strip.left, closeTo(0, 0.5));
    expect(strip.right, closeTo(1200, 0.5));
    expect(strip.height, closeTo(44, 0.5));

    // 时间轴（上一步 / 下一步）在目的地之后、间隔 16（spaceLg）；初始禁用。
    expect(find.byTooltip('主页'), findsNothing, reason: '由「心流」承担');
    final Rect back = tester.getRect(find.byTooltip('上一步'));
    expect(
      back.left - destRects.last.right,
      closeTo(Tokens.spaceLg, 1.5),
      reason: '目的地组与时间轴之间 16 隔，不用竖分割线',
    );
    expect(back.left, lessThan(tester.getRect(find.byTooltip('下一步')).left));
    expect(buttonOf(tester, '上一步').onPressed, isNull);
    expect(buttonOf(tester, '下一步').onPressed, isNull);

    // ② 条下无分割线、**无间隙**（2026-10-09 用户定顶缝 0）：HomeHub 充满
    // 浮面卡——卡顶 = 44（顶缝 0，四角圆角），左右下各 8 环缝。
    final Rect hub = tester.getRect(find.byType(HomeHub));
    expect(hub.top, closeTo(44, 0.5));
    expect(hub.left, closeTo(Tokens.appPanelInset, 0.5));
    expect(hub.right, closeTo(1200 - Tokens.appPanelInset, 0.5));
    expect(hub.bottom, closeTo(900 - Tokens.appPanelInset, 0.5));

    // 右簇：设置 + 问笔记，AI 紧贴「最小化」左侧、设置紧挨 AI 左侧。
    final Rect minRect = tester.getRect(find.byTooltip('最小化'));
    final Rect aiRect = tester.getRect(find.byTooltip('问笔记（Ctrl+J）'));
    final Rect settingsRect = tester.getRect(find.byTooltip('设置'));
    expect(minRect.left - aiRect.right, inInclusiveRange(-0.5, 4));
    expect(aiRect.left - settingsRect.right, inInclusiveRange(-0.5, 4));
    expect(container.read(aiPanelOpenProvider), isFalse, reason: '默认未开');

    // ① 编辑态：目的地两态常驻，四枚全灰（"在笔记里"不属于任何目的地）。
    final Note note = await container.read(notesProvider.notifier).createNote();
    container.read(locateProvider.notifier).locate(noteId: note.id);
    await tester.pumpAndSettle();
    for (final String label in kDestinations) {
      expect(find.byTooltip(label), findsOneWidget, reason: '编辑态目的地仍常驻');
      expect(tileFill(label), Colors.transparent, reason: '编辑态全灰：$label');
    }
    // 顶条仍是同一条全宽条（编辑器不另起一条）。
    final Rect stripInEditor = tester.getRect(find.byType(WindowStrip));
    expect(stripInEditor.left, closeTo(0, 0.5));
    expect(stripInEditor.right, closeTo(1200, 0.5));
    expect(stripInEditor.height, closeTo(44, 0.5));
  });

  testWidgets('顶条目的地切视图驱动统一历史：切到日历后箭头可退回、可重做', (WidgetTester tester) async {
    final ProviderContainer container = await pump(tester);

    // 起点是「心流」（2026-10-05 决策 C 的默认视图），点顶条「日历」换视图。
    expect(container.read(navHistoryProvider).view, HomeView.timeline);
    await tester.tap(find.byTooltip('日历'));
    await tester.pumpAndSettle();
    expect(container.read(navHistoryProvider).view, HomeView.calendar);

    // 顶条「上一步」：退回「心流」。
    await tester.tap(find.byTooltip('上一步'));
    await tester.pumpAndSettle();
    expect(container.read(navHistoryProvider).view, HomeView.timeline);
    expect(buttonOf(tester, '上一步').onPressed, isNull, reason: '退到底了');

    // 顶条「下一步」：重做，回到日历。
    await tester.tap(find.byTooltip('下一步'));
    await tester.pumpAndSettle();
    expect(container.read(navHistoryProvider).view, HomeView.calendar);
  });

  testWidgets('编辑器在统一历史栈里：顶条心流→上一步=回笔记，再上一步=回日历', (WidgetTester tester) async {
    final ProviderContainer container = await pump(tester);

    // 与真实点击路径一致：点顶条「日历」换视图，再走 locateProvider 打开笔记
    // （卡片 / 列表的入口同路）。
    await tester.tap(find.byTooltip('日历'));
    await tester.pumpAndSettle();
    final Note note = await container.read(notesProvider.notifier).createNote();
    container.read(locateProvider.notifier).locate(noteId: note.id);
    await tester.pumpAndSettle();

    // 顶条：旧「上一页」没了，只有时间轴（上一步 / 下一步）。
    expect(find.byTooltip('上一页'), findsNothing, reason: '已被时间轴取代');
    expect(find.byTooltip('上一步'), findsOneWidget);
    expect(find.byTooltip('下一步'), findsOneWidget);

    // 顶条「心流」：离开编辑器、落回「心流」，并把"这篇笔记"记入统一历史。
    await tester.tap(find.byTooltip('心流'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull, reason: '先离开编辑器');
    expect(
      container.read(navHistoryProvider).view,
      HomeView.timeline,
      reason: '心流是默认落地页（2026-10-05 决策 C）',
    );

    // 「上一步」：按点击顺序回到刚离开的那篇笔记（重新打开编辑器）。
    await tester.tap(find.byTooltip('上一步'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), note.id, reason: '退回笔记');

    // 再「上一步」：回到进笔记前的「日历」视图。
    await tester.tap(find.byTooltip('上一步'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull, reason: '离开编辑器');
    expect(container.read(navHistoryProvider).view, HomeView.calendar);

    // 「下一步」×2：原路重做——先回笔记，再回心流。
    await tester.tap(find.byTooltip('下一步'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), note.id);
    await tester.tap(find.byTooltip('下一步'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull);
    expect(container.read(navHistoryProvider).view, HomeView.timeline);
    expect(buttonOf(tester, '下一步').onPressed, isNull, reason: '进到底了');
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
