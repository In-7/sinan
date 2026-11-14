import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/ask_panel.dart';
import 'package:sinan/src/app/home_screen.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/app/settings_panel.dart' show appNavigatorKey;
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/tokens.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// **AI 问答轨 · 外壳集成**（2026-09-28；2026-10-09 修订：opencode 风外壳；
/// 2026-10-16 再修订：开关从工作区右角搬回**顶条 `trailing`**（设置右、最小化左）——
/// 它仍是 AI 轨唯一开合入口，开合走 [aiPanelOpenProvider] 单布尔）。
///
/// 组件自身的语义在 [ask_rail_test.dart] 里钉；这里钉 [HomeScreen] 外壳对
/// `aiPanelOpenProvider` 的**呈现选择**（`docs/ui_rewrite_plan.md` §2.4：
/// 断点重排，不是等比缩小）：
/// - 宽窗（≥ [Tokens.askRailBreakpoint]）：第二张浮面卡常驻，关闭时槽收宽 0
///   （裁切掉、点不着；打开 = 340 卡 + 4 左缝）；
/// - 窄窗（< 1000，2026-11-14 用户定）：入口置灰 + 开关立刻复位，**不再有
///   居中浮层**（浮层挡正文、点引用角标还得先关自己）；
/// - 开着轨把窗口拖过断点：右栏收起、开关复位，不留浮层。
void main() {
  /// `WindowStrip` / 窗控按钮在 initState 里问 window_manager（isFocused /
  /// isMaximized）。测试环境没有插件，补一个返回假值的通道 mock，其余调用
  /// 一律回 null（本测试不触发最小化 / 最大化等动作）。
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

  /// AI 开关的**位置闸门**：2026-10-16 用户定它从工作区右角搬进顶条 `trailing`
  /// （设置右、最小化左），仍是 AI 轨唯一开合入口，开合走 [aiPanelOpenProvider]。
  testWidgets('宽窗：顶条 `trailing` 有「问笔记」钮，点开右轨', (WidgetTester tester) async {
    setSurfaceSize(tester, 1200, 900);
    mockWindowManager(tester);
    final ProviderContainer container = buildContainer();
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final Finder ai = find.byTooltip('问笔记（Ctrl+J）');
    expect(ai, findsOneWidget, reason: '顶条必须有可见的 AI 钮');

    // 在 32 顶条内（贴顶、占满条高），且紧贴最小化左侧（与窗控成组）。
    final Rect aiRect = tester.getRect(ai);
    expect(aiRect.top, lessThan(32), reason: 'AI 钮在顶条内（已搬入）');
    expect(aiRect.bottom, lessThanOrEqualTo(32.5), reason: '占满顶条高');

    final Rect minRect = tester.getRect(find.byTooltip('最小化'));
    expect(
      minRect.left - aiRect.right,
      inInclusiveRange(-0.5, 4),
      reason: '问笔记紧贴最小化左侧',
    );

    // 默认未开。
    expect(container.read(aiPanelOpenProvider), isFalse);
  });

  testWidgets('宽窗：顶条「问笔记」开合右轨；关闭收 0 宽、开态披 tint', (WidgetTester tester) async {
    setSurfaceSize(tester, 1200, 900);
    mockWindowManager(tester);
    final ProviderContainer container = buildContainer();
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    // 轨始终在树里（保活问答体），由 [AnimatedContainer] 的宽度开合。
    expect(find.byType(AskRail), findsOneWidget);
    final Finder slot = find
        .ancestor(
          of: find.byType(AskRail),
          matching: find.byType(AnimatedContainer),
        )
        .first;
    expect(tester.getSize(slot).width, 0, reason: '默认收起 ⇒ 槽宽 0（内容被裁掉、点不着）');

    final Finder ai = find.byTooltip('问笔记（Ctrl+J）');
    final Finder button = find
        .ancestor(of: ai, matching: find.byType(IconButton))
        .first;
    // 顶条开关走 IconButton.styleFrom ⇒ 底色在 style 上（不是 AnimatedContainer
    // 的 decoration），按状态集 resolve。
    Color? bg() => tester
        .widget<IconButton>(button)
        .style
        ?.backgroundColor
        ?.resolve(<WidgetState>{});
    // 关闭态透明（不能落到 surface 的近黑 ⇒ 黑方块）。
    expect(bg(), Colors.transparent);

    await tester.tap(ai);
    await tester.pumpAndSettle(); // 200ms 宽度动画走完

    expect(container.read(aiPanelOpenProvider), isTrue);
    expect(
      tester.getSize(slot).width,
      Tokens.askRailWidth + Tokens.appPanelInset,
      reason: '打开 ⇒ 340 卡 + 4 左缝（seam = Tokens.appPanelInset，两张浮面卡之间的缝，露窗口底）',
    );
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byType(AskRail),
              matching: find.byType(TextField),
            ),
          )
          .focusNode
          ?.hasFocus,
      isTrue,
      reason: '开轨即聚焦提问框',
    );
    // 开态披一档中性 tint：它是个开/关，得如实显示现在开着
    //（[AiRailToggleButton] 写的正是 navSelectedTint）。
    expect(
      bg(),
      AppTheme.navSelectedTint(AppTheme.light().colorScheme.onSurface),
    );

    // 再点一次 ⇒ 收起（同一个按钮管开也管关）。
    await tester.tap(ai);
    await tester.pumpAndSettle();
    expect(container.read(aiPanelOpenProvider), isFalse);
    expect(tester.getSize(slot).width, 0);
  });

  testWidgets('窄窗：问笔记入口置灰、开关复位、不弹浮层', (WidgetTester tester) async {
    // 2026-11-14 用户定：撤掉居中浮层（挡正文、点引用得先关自己）。窄窗以
    // 阅读为主，直接禁用入口；右栏只在 ≥ [Tokens.askRailBreakpoint] 出现。
    setSurfaceSize(tester, 900, 700); // < Tokens.askRailBreakpoint
    mockWindowManager(tester);
    final ProviderContainer container = buildContainer();
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    // 入口置灰：tooltip 说实话，IconButton.onPressed 为 null。
    final Finder ai = find.byTooltip('问笔记（窗口宽度需 ≥ 1000）');
    expect(ai, findsOneWidget, reason: '窄窗应给出可解释的禁用提示');
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(of: ai, matching: find.byType(IconButton)).first,
          )
          .onPressed,
      isNull,
      reason: '窄窗禁用问笔记',
    );

    // 命令层仍只翻布尔（不判宽度）⇒ 外壳负责立刻复位，避免拖宽后突然弹出。
    container.read(aiPanelOpenProvider.notifier).open();
    await tester.pumpAndSettle();
    expect(container.read(aiPanelOpenProvider), isFalse, reason: '误开的开关必须立刻复位');

    // 不再有任何居中浮层；右栏槽保持收起。
    expect(find.byKey(const Key('askRailFloatSurface')), findsNothing);
    final Finder slot = find
        .ancestor(
          of: find.byType(AskRail),
          matching: find.byType(AnimatedContainer),
        )
        .first;
    expect(tester.getSize(slot).width, 0, reason: '窄窗右栏槽保持收起');
  });

  testWidgets('宽窗开着轨拖窄 ⇒ 右栏收起、开关复位、不留浮层', (WidgetTester tester) async {
    setSurfaceSize(tester, 1200, 900);
    mockWindowManager(tester);
    final ProviderContainer container = buildContainer();
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    container.read(aiPanelOpenProvider.notifier).open();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('askRailFloatSurface')), findsNothing);
    final Finder slot = find
        .ancestor(
          of: find.byType(AskRail),
          matching: find.byType(AnimatedContainer),
        )
        .first;
    expect(tester.getSize(slot).width, greaterThan(0), reason: '宽窗右栏已展开');

    // 模拟用户把窗口拖窄到断点以下。
    setSurfaceSize(tester, 900, 700);
    await tester.pump(); // post-frame 复位开关
    await tester.pumpAndSettle();

    expect(
      container.read(aiPanelOpenProvider),
      isFalse,
      reason: '跨断点要复位，否则拖回宽窗会突然弹出右栏',
    );
    expect(
      find.byKey(const Key('askRailFloatSurface')),
      findsNothing,
      reason: '不再降级浮层',
    );
    expect(tester.getSize(slot).width, 0, reason: '右栏收起');
  });
}
