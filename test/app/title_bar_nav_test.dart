import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/home_screen.dart';
import 'package:sinan/src/app/nav_rail.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/app/settings_panel.dart' show appNavigatorKey;
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/focus_ring.dart';
import 'package:sinan/src/theme/tokens.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// **主区顶条 + 左导航栏的导航结构**（2026-09-29 用户定：50px 第一列总导航栏
/// 撤掉；2026-10-08 修订：撤销决策 B，目的地从 [WindowStrip] 迁回左 [NavRail]）。
///
/// 钉的是这几条结构性事实：
/// ① 顶条左簇只剩 **上一步 / 下一步**（统一导航历史 [navHistoryProvider] 的出口），
///    初始禁用，导航后可用；
/// ② 目的地（主页 / 心流 / 全部 / 日历 / 收藏 / 搜索）+ 设置 + 问笔记都在左
///    [NavRail]（左栏 tile 用 Text，无 Tooltip）；折叠按钮在左栏底部；
/// ③ 第一列 [AppRail] 已删——HubNav 子树与整窗里都不许再有它的位置；
/// ④ 编辑器页同一簇替换旧「上一页」：编辑器也在统一历史栈里，箭头按点击顺序进退。
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

  testWidgets('顶条只含历史箭头；左栏承载全部目的地，底部署设置/问笔记', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    // 顶条左簇：只剩上一步 / 下一步（统一导航历史），初始禁用。
    // （2026-10-08 修订：撤销决策 B——主页 / 日历 / 收藏 / 设置 / 问笔记都迁回
    // 左导航栏，顶条只留历史箭头。）
    expect(find.byTooltip('上一步'), findsOneWidget);
    expect(find.byTooltip('下一步'), findsOneWidget);
    expect(buttonOf(tester, '上一步').onPressed, isNull);
    expect(buttonOf(tester, '下一步').onPressed, isNull);

    // 左导航栏的目的地（左栏 tile 用 Text，无 Tooltip）。
    Finder railTile(String label) =>
        find.descendant(of: find.byType(NavRail), matching: find.text(label));
    for (final String label in <String>[
      '主页',
      '全部',
      '日历',
      '收藏',
      '搜索',
      '设置',
      '问笔记',
    ]) {
      expect(railTile(label), findsOneWidget, reason: '左栏应有目的地：$label');
    }

    // 折叠（展开态）按钮在左栏底部；旧的「折叠面板」已撤。
    expect(find.byTooltip('折叠面板'), findsNothing);
    expect(find.byTooltip('展开面板'), findsNothing);
    expect(find.byTooltip('折叠导航栏'), findsOneWidget);

    // **左栏垂直顺序闸门**：主页在上、日历 / 收藏在中、设置 / 问笔记在底——
    // 顺序被改动这里就会红。
    double topOf(String label) => tester.getRect(railTile(label)).top;
    expect(topOf('主页'), lessThan(topOf('全部')));
    expect(topOf('全部'), lessThan(topOf('日历')));
    expect(topOf('日历'), lessThan(topOf('收藏')));
    expect(topOf('收藏'), lessThan(topOf('设置')));
    expect(topOf('设置'), lessThan(topOf('问笔记')));
  });

  testWidgets('上一步/下一步驱动视图历史：左栏切视图后可退回、可重做', (WidgetTester tester) async {
    final ProviderContainer container = await pump(tester);

    // 起点是「心流」（2026-10-05 决策 C 的默认视图），点左栏「日历」换视图。
    // （2026-10-08 修订：日历入口在左导航栏，用 find.descendant 锁定，避免与
    // 主区日历视图自身的「日历」标题撞名。）
    final Finder calendar = find.descendant(
      of: find.byType(NavRail),
      matching: find.text('日历'),
    );
    expect(container.read(navHistoryProvider).view, HomeView.timeline);
    await tester.tap(calendar);
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

  testWidgets('编辑器在统一历史栈里：主页→上一步=回笔记，再上一步=回日历', (WidgetTester tester) async {
    final ProviderContainer container = await pump(tester);

    Finder railTile(String label) =>
        find.descendant(of: find.byType(NavRail), matching: find.text(label));

    // 与真实点击路径一致：点左栏「日历」换视图，再走 locateProvider 打开笔记
    // （卡片 / 列表的入口同路）。
    await tester.tap(railTile('日历'));
    await tester.pumpAndSettle();
    final Note note = await container.read(notesProvider.notifier).createNote();
    container.read(locateProvider.notifier).locate(noteId: note.id);
    await tester.pumpAndSettle();

    // 编辑器顶条：旧「上一页」没了，同一簇在（上一步 / 下一步）；主页在左栏。
    expect(find.byTooltip('上一页'), findsNothing, reason: '已被左簇取代');
    expect(railTile('主页'), findsOneWidget);
    expect(find.byTooltip('上一步'), findsOneWidget);
    expect(find.byTooltip('下一步'), findsOneWidget);

    // 左栏「主页」：离开编辑器、落回「心流」，并把"这篇笔记"记入统一历史。
    await tester.tap(railTile('主页'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull, reason: '先离开编辑器');
    expect(
      container.read(navHistoryProvider).view,
      HomeView.timeline,
      reason: '主页落回默认落地页「心流」（2026-10-05 决策 C）',
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

    // 「下一步」×2：原路重做——先回笔记，再回主页（心流）。
    await tester.tap(find.byTooltip('下一步'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), note.id);
    await tester.tap(find.byTooltip('下一步'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull);
    expect(container.read(navHistoryProvider).view, HomeView.timeline);
    expect(buttonOf(tester, '下一步').onPressed, isNull, reason: '进到底了');
  });

  testWidgets('标题栏两分支都不放搜索入口（主页页内框 / 编辑器 Ctrl+F / 全局 Ctrl+K）', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pump(tester);

    // 标题栏**任何分支**都不挂搜索图标 / 胶囊（2026-10-01 用户定）：
    // 主页有页内搜索框、编辑器有 Ctrl+F 内容查找、全局跳转统一走 Ctrl+K。
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

  /// tile 的圆角底（AnimatedContainer）。**不是** Container 子类，finder 要用它。
  AnimatedContainer tileOf(WidgetTester tester, String label) =>
      tester.widget<AnimatedContainer>(
        find
            .ancestor(
              of: find.descendant(
                of: find.byType(NavRail),
                matching: find.text(label),
              ),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );

  Color tileBg(WidgetTester tester, String label) =>
      (tileOf(tester, label).decoration! as BoxDecoration).color!;

  testWidgets('侧栏项：按住叠一档 stateLayer（比 hover 更实），松手复原', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    // 用「设置」：它的 `active` 恒为 false ⇒ 静止底色**恒**透明，不受
    // aiPanelOpen / navHistory 等其它 provider 的初值影响。
    expect(tileBg(tester, '设置'), Colors.transparent, reason: '静止态透明');

    final Offset at = tester.getCenter(
      find.descendant(
        of: find.byType(NavRail),
        matching: find.text('设置'),
      ),
    );
    // 用鼠标指针：这是桌面场景，且 hover 高亮在 touch 模式下本就不显示。
    final TestGesture g = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    final Color pressed = tileBg(tester, '设置');
    expect(pressed, isNot(Colors.transparent), reason: '按下 ⇒ 有反馈');
    // 按下档 = stateLayerPressed(18%) 叠在静止底上，不是 hover 那档(4%)。
    expect(
      pressed.a,
      greaterThan(AppTheme.hoverOverlay(Brightness.light).a),
      reason: '按下必须比 hover 更实（stateLayer 18% > hover 4%）',
    );

    await g.up();
    await tester.pumpAndSettle();
    expect(tileBg(tester, '设置'), Colors.transparent, reason: '松手复原');
  });

  testWidgets('侧栏项：键盘聚焦出现统一焦点环，且环与圆角底同半径', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    final Finder setting = find.descendant(
      of: find.byType(NavRail),
      matching: find.text('设置'),
    );
    // ⚠️ 必须先 `.first` 定位到**这一项**的 FocusRing：全树还有
    // FocusRingIconButton 带的那些环，不限定就会取到别人的（未聚焦 ⇒ null）。
    final Finder ring = find
        .ancestor(of: setting, matching: find.byType(FocusRing))
        .first;

    FocusRing host() => tester.widget<FocusRing>(ring);
    // 环必须与 tile 的圆角一致，否则会"错位一个圆角"。
    expect(host().borderRadius, BorderRadius.circular(Tokens.radiusSm));
    expect(host().focusNode.hasFocus, isFalse);

    host().focusNode.requestFocus();
    // 焦点由 FocusManager 在**帧末**结算 ⇒ 监听引发的重建落在下一帧，
    // 少推一帧断的就是"上一帧的环"（见 FocusRing 的调试经验）。
    await tester.pump();
    await tester.pump();

    expect(host().focusNode.hasFocus, isTrue);
    // 环真的画出来了：FocusRing 内部那个 Container 带了描边。
    final Container box = tester.widget<Container>(
      find.descendant(of: ring, matching: find.byType(Container)).first,
    );
    expect(box.foregroundDecoration, isNotNull);
    final BoxDecoration ringDecoration = box.foregroundDecoration! as BoxDecoration;
    final Border border = ringDecoration.border! as Border;
    expect(border.top.color, AppTheme.light().colorScheme.primary);
    expect(border.top.width, Tokens.focusRingWidth);
  });
}
