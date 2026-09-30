import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/home_screen.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/app/search_palette.dart';
import 'package:sinan/src/app/settings_panel.dart' show appNavigatorKey;
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// **主区顶条的导航簇**（2026-09-29 用户定：50px 第一列总导航栏撤掉，
/// 主页 / 设置 / 上一步 / 下一步搬进 [WindowStrip]）。
///
/// 钉的是这几条结构性事实：
/// ① 左簇自左向右 = **折叠面板**（整栏开关，钉最左）+ 上一步 + **主页** +
///    下一步（主页夹在两个历史箭头中间）；右簇 = 设置 + AI 开关
///    （设置紧挨 AI——全局动作靠右、页面导航靠左）；
/// ② 箭头是统一导航历史（[navHistoryProvider]）的出口：初始禁用，导航后可用；
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

  /// 三点溢出菜单里的某一项（2026-09-29 起「更多」是菜单、不是视图）。
  ///
  /// ⚠️ 两个坑：① 菜单画在 **overlay** 里，不在 [HomeHub] 子树内 ⇒ 不能沿用
  /// 旧版 `descendant(of: HomeHub)` 的定位；② 整壳里还有第二列 HubNav 的
  /// 「画布」空间标签 ⇒ 裸 `find.text('画布')` 会撞两处。故必须圈进菜单项本身。
  Finder menuItem(String label) => find.descendant(
    of: find.byType(PopupMenuItem<void>),
    matching: find.text(label),
  );

  testWidgets('左簇 = 折叠/上一步/主页/下一步，右簇 = 设置紧挨 AI；箭头初始禁用', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    expect(find.byTooltip('主页'), findsOneWidget);
    expect(find.byTooltip('上一步'), findsOneWidget);
    expect(find.byTooltip('下一步'), findsOneWidget);
    expect(find.byTooltip('折叠面板'), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
    expect(find.byTooltip('问笔记（Ctrl+J）'), findsOneWidget);

    // **左簇顺序闸门**（2026-09-29 用户定）：折叠面板钉最左，主页夹在
    // 上一步 / 下一步**中间**——顺序被改动这里就会红。
    // （2026-09-30：左侧 HubNav 列表面板已整列暂撤，但按钮保留。）
    final Rect collapse = tester.getRect(find.byTooltip('折叠面板'));
    final Rect back = tester.getRect(find.byTooltip('上一步'));
    final Rect home = tester.getRect(find.byTooltip('主页'));
    final Rect forward = tester.getRect(find.byTooltip('下一步'));
    expect(
      collapse.right,
      lessThanOrEqualTo(back.left),
      reason: '折叠面板应在最左（整栏开关，不混进页面导航）',
    );
    expect(back.right, lessThanOrEqualTo(home.left), reason: '主页应在上一步右侧');
    expect(
      home.right,
      lessThanOrEqualTo(forward.left),
      reason: '主页应在下一步左侧 ⇒ 夹在两个历史箭头中间',
    );

    // 初始无历史：两枚箭头都置灰（onPressed null）。
    expect(buttonOf(tester, '上一步').onPressed, isNull);
    expect(buttonOf(tester, '下一步').onPressed, isNull);

    // 设置紧挨 AI：设置.right ≤ AI.left（同一右簇，设置在 AI 左边）。
    final Rect settings = tester.getRect(find.byTooltip('设置'));
    final Rect ai = tester.getRect(find.byTooltip('问笔记（Ctrl+J）'));
    expect(
      settings.right,
      lessThanOrEqualTo(ai.left + 0.5),
      reason: '设置应在 AI 开关左边、紧挨着它',
    );
  });

  testWidgets('上一步/下一步驱动视图历史：三点菜单进画布后可退回、可重做', (WidgetTester tester) async {
    final ProviderContainer container = await pump(tester);

    // 主页顶栏**三点菜单** → 画布（低频页面的整页入口）。
    await tester.tap(find.byTooltip('更多页面'));
    await tester.pumpAndSettle();
    await tester.tap(menuItem('画布'));
    await tester.pumpAndSettle();
    expect(container.read(navHistoryProvider).view, HomeView.canvas);

    // 顶条「上一步」：直退落地的「全部」（中间不再有"「更多」页"这一跳——
    // 它就是 2026-09-29 拆掉的那一层）。
    await tester.tap(find.byTooltip('上一步'));
    await tester.pumpAndSettle();
    expect(container.read(navHistoryProvider).view, HomeView.all);
    expect(buttonOf(tester, '上一步').onPressed, isNull, reason: '退到底了');

    // 顶条「下一步」：重做，回到画布。
    await tester.tap(find.byTooltip('下一步'));
    await tester.pumpAndSettle();
    expect(container.read(navHistoryProvider).view, HomeView.canvas);
  });

  testWidgets('编辑器在统一历史栈里：主页→上一步=回笔记，再上一步=回画布', (WidgetTester tester) async {
    final ProviderContainer container = await pump(tester);

    // 与真实点击路径一致：三点菜单进「画布」（整页切换），再走 locateProvider
    // 打开笔记（卡片 / 列表的入口同路）。
    await tester.tap(find.byTooltip('更多页面'));
    await tester.pumpAndSettle();
    await tester.tap(menuItem('画布'));
    await tester.pumpAndSettle();
    final Note note = await container.read(notesProvider.notifier).createNote();
    container.read(locateProvider.notifier).locate(noteId: note.id);
    await tester.pumpAndSettle();

    // 编辑器顶条：旧「上一页」没了，同一簇在（主页 / 上一步 / 下一步）。
    expect(find.byTooltip('上一页'), findsNothing, reason: '已被左簇取代');
    expect(find.byTooltip('主页'), findsOneWidget);
    expect(find.byTooltip('上一步'), findsOneWidget);
    expect(find.byTooltip('下一步'), findsOneWidget);

    // 顶条「主页」：离开编辑器、落回「全部」，并把"这篇笔记"记入统一历史。
    await tester.tap(find.byTooltip('主页'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull, reason: '先离开编辑器');
    expect(
      container.read(navHistoryProvider).view,
      HomeView.all,
      reason: '主页应落回「全部」',
    );

    // 「上一步」：按点击顺序回到刚离开的那篇笔记（重新打开编辑器）。
    await tester.tap(find.byTooltip('上一步'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), note.id, reason: '退回笔记');

    // 再「上一步」：回到进笔记前的「画布」视图。
    await tester.tap(find.byTooltip('上一步'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull, reason: '离开编辑器');
    expect(container.read(navHistoryProvider).view, HomeView.canvas);

    // 「下一步」×2：原路重做——先回笔记，再回主页「全部」。
    await tester.tap(find.byTooltip('下一步'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), note.id);
    await tester.tap(find.byTooltip('下一步'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull);
    expect(container.read(navHistoryProvider).view, HomeView.all);
    expect(buttonOf(tester, '下一步').onPressed, isNull, reason: '进到底了');
  });

  testWidgets('全局搜索胶囊：拖拽带正中，主页/编辑器都在；点击开 Ctrl+K 浮层', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pump(tester);

    // 主页分支：胶囊只有一枚（WindowStrip 正中），文案 + 键位徽标。
    final Finder capsuleTip = find.byTooltip('搜索全部笔记与画布（Ctrl+K）');
    expect(capsuleTip, findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('Ctrl+K'), findsOneWidget);

    // 点击走 search.open 命令 ⇒ 全局浮层。
    await tester.tap(capsuleTip);
    // ⚠️ 浮层输入框聚焦后光标周期性闪烁，pumpAndSettle 会永久挂起，只能 pump。
    await tester.pump();
    expect(find.byType(SearchPalette), findsOneWidget);
    expect(find.text('搜索全部笔记与画布'), findsOneWidget, reason: '浮层输入框 hint');
    // 收尾：Esc 关掉，避免单例浮层泄漏给后续用例。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
    expect(find.byType(SearchPalette), findsNothing);

    // 编辑器分支：胶囊仍在（写笔记时不回主页也能搜）。
    final Note note = await container.read(notesProvider.notifier).createNote();
    container.read(locateProvider.notifier).locate(noteId: note.id);
    await tester.pumpAndSettle();
    expect(capsuleTip, findsOneWidget, reason: '编辑器顶条同构，胶囊不消失');
  });
}
