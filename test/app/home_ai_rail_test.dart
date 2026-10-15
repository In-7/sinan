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
import 'package:sinan/src/theme/app_float_surface.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/tokens.dart';
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// **AI 问答轨 · 外壳集成**（2026-09-28；2026-10-09 修订：opencode 风外壳；
/// 2026-10-11 再修订：开关从顶条搬进**工作区右角折叠钮**——它是 AI 轨唯一的
/// 开合入口，钉在内容卡内缘 4px、y 与编辑页顶栏「标签」耳按钮同高）。
///
/// 组件自身的语义在 [ask_rail_test.dart] 里钉；这里钉 [HomeScreen] 外壳对
/// `aiPanelOpenProvider` 的**呈现选择**（`docs/ui_rewrite_plan.md` §2.4：
/// 断点重排，不是等比缩小）：
/// - 宽窗（≥ [Tokens.askRailBreakpoint]）：第二张浮面卡常驻，关闭时槽收宽 0
///   （裁切掉、点不着；打开 = 340 卡 + 4 左缝）；
/// - 窄窗：不渲染可见轨，「打开」降级为居中浮层，开关立刻复位；
/// - 开着轨把窗口拖过断点：同样降级，且不弹两层浮层。
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

  /// AI 开关的**位置闸门**：2026-10-11 用户定它不再是顶条钮（顶条右端只留设置），
/// 而是**工作区右角折叠钮**——钉在内容卡内缘 4px、y 与编辑页顶栏「标签」耳按钮
/// 同高，且开合两态坐标不变（好发现好记忆）。
testWidgets('宽窗：工作区右角有「问笔记」折叠钮，点开右轨', (WidgetTester tester) async {
    setSurfaceSize(tester, 1200, 900);
    mockWindowManager(tester);
    final ProviderContainer container = buildContainer();
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final Finder ai = find.byTooltip('问笔记（Ctrl+J）');
    expect(ai, findsOneWidget, reason: '右角必须有可见的 AI 折叠钮');

    // 不在 44 顶条内；钉在内容卡内缘 4px（= 窗口右缘 − appPanelInset − spaceXs）。
    final Rect aiRect = tester.getRect(ai);
    expect(aiRect.top, greaterThan(32), reason: 'AI 钮不在顶条内（已搬出）');
    expect(
      aiRect.right,
      closeTo(1200 - Tokens.appPanelInset - Tokens.spaceXs, 0.5),
      reason: '钉在内容卡内缘 4px',
    );
    expect(
      aiRect.top + aiRect.height / 2,
      // 面板顶部 = 顶条 32 + 顶缝（[AppTheme.surfaceRingRetreat]，随外扩亮线走）
      // ⇒ 中心 = 其下 20。从常量推，别写死。
      closeTo(32 + AppTheme.surfaceRingRetreat + 20, 1),
      reason: '与编辑页顶栏「标签」耳按钮同高（内容区顶部下 20）',
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

  testWidgets('窄窗：打开开关降级为居中浮层，开关立即复位', (WidgetTester tester) async {
    setSurfaceSize(tester, 900, 700); // < Tokens.askRailBreakpoint
    mockWindowManager(tester);
    final ProviderContainer container = buildContainer();
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    container.read(aiPanelOpenProvider.notifier).open();
    await tester.pump(); // post-frame 降级：复位 + 插浮层
    await tester.pumpAndSettle();

    expect(
      container.read(aiPanelOpenProvider),
      isFalse,
      reason: '浮层显隐不归这个布尔管，降级后必须立刻复位',
    );
    expect(
      find.byType(AppFloatSurface),
      findsOneWidget,
      reason: '窄窗应弹出居中浮层，而不是把右轨压进窄窗',
    );
    // 浮层问答体同样打开即聚焦。注意常驻轨此时仍挂在树里（保活）、自带一个
    // TextField，所以要在 AppFloatSurface 子树内取。
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byType(AppFloatSurface),
              matching: find.byType(TextField),
            ),
          )
          .focusNode
          ?.hasFocus,
      isTrue,
    );
  });

  testWidgets('宽窗开着轨拖过断点 ⇒ 已有的打开态也降级成浮层（不弹两层）', (WidgetTester tester) async {
    setSurfaceSize(tester, 1200, 900);
    mockWindowManager(tester);
    final ProviderContainer container = buildContainer();
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    container.read(aiPanelOpenProvider.notifier).open();
    await tester.pumpAndSettle();
    expect(find.byType(AppFloatSurface), findsNothing);

    // 模拟用户把窗口拖窄到断点以下。
    setSurfaceSize(tester, 900, 700);
    await tester.pump(); // post-frame 降级
    await tester.pumpAndSettle();

    expect(container.read(aiPanelOpenProvider), isFalse);
    expect(
      find.byType(AppFloatSurface),
      findsOneWidget,
      reason: '跨断点要降级；同帧多个 post-frame 回调也不得叠两层浮层',
    );
  });
}
