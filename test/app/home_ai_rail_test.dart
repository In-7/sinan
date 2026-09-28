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
// 只取 Database / sqlite3：sqlite3 还导出一个 `Row`，与 Flutter 的 Row 撞名。
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// **AI 问答轨 · 外壳集成**（2026-09-28）。
///
/// 组件自身的语义在 [ask_rail_test.dart] 里钉；这里钉 [HomeScreen] 外壳对
/// `aiPanelOpenProvider` 的**呈现选择**（`docs/ui_rewrite_plan.md` §2.4：
/// 断点重排，不是等比缩小）：
/// - 宽窗（≥ [kAskRailBreakpoint]）：第三列常驻，关闭时收成宽 0（裁切掉、点不着）；
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

  /// 顶条右端那枚开关的**位置闸门**：它必须紧贴「最小化」左侧，而不是跑到
  /// 别处（用户明确指定："位置放在最小化左边"）。
  testWidgets('宽窗：顶条右端有「问笔记」按钮，紧贴最小化左侧（左栏按钮的镜像）', (WidgetTester tester) async {
    setSurfaceSize(tester, 1200, 900);
    mockWindowManager(tester);
    final ProviderContainer container = buildContainer();
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final Finder toggle = find.byTooltip('问笔记（Ctrl+J）');
    expect(toggle, findsOneWidget, reason: '顶条必须有可见的开关按钮');

    final Rect ai = tester.getRect(toggle);
    final Rect minimize = tester.getRect(find.byTooltip('最小化'));
    expect(
      ai.right,
      lessThanOrEqualTo(minimize.left + 0.5),
      reason: '开关应在最小化**左边**（主角：${ai.right} vs 最小化左缘 ${minimize.left}）',
    );
    // 与左端折叠按钮同一条窗控带（同一水平中线）。
    final Rect collapse = tester.getRect(find.byTooltip('折叠面板'));
    expect(
      (ai.center.dy - collapse.center.dy).abs(),
      lessThan(0.5),
      reason: '两枚开关应在同一条顶条上左右对称，而不是错开高度',
    );
  });

  testWidgets('宽窗：顶条按钮开合右轨；关闭时轨收为 0 宽、开态披 tint', (WidgetTester tester) async {
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

    final Finder toggle = find.byTooltip('问笔记（Ctrl+J）');
    // `byTooltip` 命中的是按钮**内部**的 Tooltip ⇒ 样式要去它的祖先 IconButton 上取。
    final Finder toggleButton = find
        .ancestor(of: toggle, matching: find.byType(IconButton))
        .first;
    // 关闭态底色必须透明（不能落到 surface 的近黑 ⇒ 黑方块）。
    expect(
      tester
          .widget<IconButton>(toggleButton)
          .style
          ?.backgroundColor
          ?.resolve(const <WidgetState>{}),
      Colors.transparent,
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle(); // 200ms 宽度动画走完

    expect(container.read(aiPanelOpenProvider), isTrue);
    expect(tester.getSize(slot).width, kAskRailWidth, reason: '打开 ⇒ 恢复 340 宽');
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
    // 开态披一档中性 tint：它是个开/关，得如实显示现在开着。
    expect(
      tester
          .widget<IconButton>(toggleButton)
          .style
          ?.backgroundColor
          ?.resolve(const <WidgetState>{}),
      isNot(Colors.transparent),
    );

    // 再点一次 ⇒ 收起（同一个按钮管开也管关）。
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(container.read(aiPanelOpenProvider), isFalse);
    expect(tester.getSize(slot).width, 0);
  });

  testWidgets('窄窗：打开开关降级为居中浮层，开关立即复位', (WidgetTester tester) async {
    setSurfaceSize(tester, 900, 700); // < kAskRailBreakpoint
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
