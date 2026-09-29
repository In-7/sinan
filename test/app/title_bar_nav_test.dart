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
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// **主区顶条的导航簇**（2026-09-29 用户定：50px 第一列总导航栏撤掉，
/// 主页 / 设置 / 上一步 / 下一步搬进 [WindowStrip]）。
///
/// 钉的是这几条结构性事实：
/// ① 左簇 = 主页 + 上一步 + 下一步 + 折叠面板；右簇 = 设置 + AI 开关
///    （设置紧挨 AI——全局动作靠右、页面导航靠左）；
/// ② 箭头是视图历史（[homeViewProvider]）的出口：初始禁用，导航后可用；
/// ③ 第一列 [AppRail] 已删——HubNav 子树与整窗里都不许再有它的位置；
/// ④ 编辑器页同一簇替换旧「上一页」：箭头按下 = 先回主页再走历史。
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

  testWidgets('左簇 = 主页/上一步/下一步/折叠，右簇 = 设置紧挨 AI；箭头初始禁用', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    expect(find.byTooltip('主页'), findsOneWidget);
    expect(find.byTooltip('上一步'), findsOneWidget);
    expect(find.byTooltip('下一步'), findsOneWidget);
    expect(find.byTooltip('折叠面板'), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
    expect(find.byTooltip('问笔记（Ctrl+J）'), findsOneWidget);

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

  testWidgets('上一步/下一步驱动视图历史：更多→画布后可退回、可重做', (WidgetTester tester) async {
    final ProviderContainer container = await pump(tester);

    // 主页顶栏：更多 → 画布（「更多」面板第一行的视图入口）。
    // ⚠️ 整壳里有第二列 HubNav 的「画布」空间标签，finder 必须圈进 [HomeHub]。
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(HomeHub), matching: find.text('画布')),
    );
    await tester.pumpAndSettle();
    expect(container.read(homeViewProvider), HomeView.canvas);

    // 顶条「上一步」：退回「更多」，再退回落地的「全部」。
    await tester.tap(find.byTooltip('上一步'));
    await tester.pumpAndSettle();
    expect(container.read(homeViewProvider), HomeView.filter);
    await tester.tap(find.byTooltip('上一步'));
    await tester.pumpAndSettle();
    expect(container.read(homeViewProvider), HomeView.all);
    expect(buttonOf(tester, '上一步').onPressed, isNull, reason: '退到底了');

    // 顶条「下一步」：重做。
    await tester.tap(find.byTooltip('下一步'));
    await tester.pumpAndSettle();
    expect(container.read(homeViewProvider), HomeView.filter);
  });

  testWidgets('编辑器页同一簇替换旧「上一页」；上一步 = 回主页 + 退回上一视图', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pump(tester);

    // 先走到「更多」，再建一篇笔记并打开（进编辑器）。
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    final Note note = await container.read(notesProvider.notifier).createNote();
    container.read(selectedNoteIdProvider.notifier).select(note.id);
    await tester.pumpAndSettle();

    // 编辑器顶条：旧「上一页」没了，同一簇在（主页 / 上一步 / 下一步）。
    expect(find.byTooltip('上一页'), findsNothing, reason: '已被左簇取代');
    expect(find.byTooltip('主页'), findsOneWidget);
    expect(find.byTooltip('上一步'), findsOneWidget);
    expect(find.byTooltip('下一步'), findsOneWidget);

    // 顶条「主页」：回主页（视图仍是「更多」）。
    await tester.tap(find.byTooltip('主页'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull);
    expect(
      container.read(homeViewProvider),
      HomeView.filter,
      reason: '主页不动视图历史',
    );

    // 在编辑器里按「上一步」：先回主页、再退回「全部」。
    container.read(selectedNoteIdProvider.notifier).select(note.id);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('上一步'));
    await tester.pumpAndSettle();
    expect(container.read(selectedNoteIdProvider), isNull, reason: '先离开编辑器');
    expect(container.read(homeViewProvider), HomeView.all, reason: '再退回上一视图');
  });
}
