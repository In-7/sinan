import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/app/settings_panel.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/settings.dart';
import 'package:sinan/src/theme/app_float_surface.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/focus_ring.dart';
import 'package:sqlite3/sqlite3.dart';

/// 设置面板的结构闸门（2026-09-18 重构：行组件换成 M3 `ListTile`、新增「关于」分区）。
///
/// 钉的是**结构性事实**，不是像素：三分区都在、默认落在「外观」、每个设置项都带
/// 说明文字（M3 `subtitle` —— 它正是"把设计理由从注释搬到 UI"的那一格）、
/// 「关于」里三条信息齐备。观感仍要靠上机看。
void main() {
  late Database db;
  late NoteStore notes;
  late SettingsStore settings;

  /// 焦点环是否存在。
  ///
  /// ⚠️ 两个"别拿它当判据"的坑（都踩过）：
  /// 1. 面板里可能有别的带 `foregroundDecoration` 的容器 ⇒ 必须按**形状**区分：
  ///    环是 `Border.all`（四边都画）。注：导航项的 3px 左指示条已随 2026-10-08
  ///    强调色药丸换装撤掉，这里仍保留形状校验（防未来单边装饰混进来）。
  /// 2. 只限定在 [FocusRing] 子树还不够（见上），要两者一起用。
  Finder ringFinder() => find.descendant(
    of: find.byType(FocusRing),
    matching: find.byWidgetPredicate((Widget w) {
      if (w is! Container) return false;
      final Decoration? fg = w.foregroundDecoration;
      if (fg is! BoxDecoration) return false;
      final BoxBorder? border = fg.border;
      return border is Border &&
          border.top.width > 0 &&
          border.bottom.width > 0;
    }),
  );

  const String kDataDir = r'C:\Users\test\AppData\Roaming\sinan';

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    notes = NoteStore(db);
    settings = SettingsStore(db);
  });

  tearDown(() => db.close());

  /// 挂一个能打开设置面板的最小宿主：面板从 `appNavigatorKey` 的 Overlay 取出，
  /// 所以 MaterialApp 必须带上这个 key。
  Future<void> openPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noteStoreProvider.overrideWithValue(notes),
          settingsStoreProvider.overrideWithValue(settings),
          appDataDirProvider.overrideWithValue(kDataDir),
        ],
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          theme: AppTheme.light(),
          home: Builder(
            builder: (BuildContext context) => const Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    // 模拟"面板背后那个占着焦点的控件"——真实场景里是编辑器
                    // （它 `autoFocus: true`）。有它，"打开即接管焦点"那条断言
                    // 才是真闸门：面板若不抢焦点，焦点就留在这儿。
                    Focus(
                      autofocus: true,
                      child: SizedBox(width: 40, height: 20),
                    ),
                    FilledButton(
                      onPressed: showSettingsPanel,
                      child: Text('open'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> goto(WidgetTester tester, String section) async {
    await tester.tap(find.text(section));
    await tester.pumpAndSettle();
  }

  testWidgets('三分区都在，默认落在「外观」', (WidgetTester tester) async {
    await openPanel(tester);

    expect(find.text('设置'), findsOneWidget);
    // 分区名出现两次 = 左导航项 + 右侧分区标题；未选中的只有导航那一次。
    expect(find.text('外观'), findsNWidgets(2), reason: '默认分区标题应落在右侧');
    expect(find.text('编辑器'), findsOneWidget, reason: '导航少了分区：编辑器');
    expect(find.text('关于'), findsOneWidget, reason: '导航少了分区：关于');
    // 默认「外观」：明暗两档可见。
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
  });

  /// 2026-09-22 用户定：设置面板与关于面板**统一成一档** —— **实色底 + 玻璃光泽**。
  /// （此前是 A/B 对照：设置 = 半透 0.98、关于 = 实色；实测两者只差 1~3 Lc、肉眼不可分
  /// ⇒ 对照无意义，只留一个。那档半透 `panelFill` 连同 `panelLayerAlpha` 一起删了。）
  ///
  /// 三件都要钉：
  /// 1. **底走 `floatSurface` token 且必须是实色**（半透的代价是清晰鬼影 ∝ 1−α，
  ///    而本面板面积大 + 不开模糊 ⇒ 鬼影既大又清晰；想在它身上要"透"只能开模糊）；
  /// 2. **玻璃光泽在**（`glass: true`）—— 这是它现在**唯一**的观感来源（亮色下"透"
  ///    本来就只差 1~2 级，见 `AppTheme.menuLayerAlpha` 的注释）；
  /// 3. **刻意不模糊**：成本 ∝ 面积 × 重绘次数，本面板 ≈ 全屏 11% 且拖滑杆时背后每帧重绘。
  testWidgets('实色底 + 玻璃光泽，且**刻意不模糊**', (WidgetTester tester) async {
    await openPanel(tester);

    final AppFloatSurface surface = tester.widget<AppFloatSurface>(
      find.byType(AppFloatSurface),
    );
    expect(
      surface.color,
      AppTheme.floatSurface(Brightness.light),
      reason: '面板底要走浮层令牌，别在调用点手写颜色 / alpha',
    );
    expect(
      surface.color?.a,
      1,
      reason:
          '底必须是不透明：它又变半透了 ⇒ 背后内容会透出**清晰字影**（面板面积大 + 无模糊，'
          '鬼影最明显的一处）。想要"透"请开 `blur`，不要偷偷降 alpha',
    );
    expect(
      surface.glass,
      isTrue,
      reason: '底已是实色（"透"不提供任何观感）⇒ 外观全靠光泽 + 光边，这条丢了面板就什么特征都不剩',
    );
    expect(
      surface.blur,
      isFalse,
      reason:
          '设置面板刻意不开模糊：面板约全屏 11%，而拖滑杆时背后每帧重绘 ⇒ '
          '每帧重算滤镜。要开回来先量 `F9` 的 raster_p90_ms（见 AppTheme.floatBlurSigma）',
    );
    expect(
      find.descendant(
        of: find.byType(AppFloatSurface),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
      reason: '没开 blur 却还挂着 BackdropFilter ⇒ 这个性能取舍被悄悄推翻了',
    );
  });

  testWidgets('「外观」的设置项带说明文字（M3 ListTile 的 subtitle）', (
    WidgetTester tester,
  ) async {
    await openPanel(tester);

    expect(find.text('明暗'), findsOneWidget);
    expect(
      find.textContaining('点一下立刻生效'),
      findsOneWidget,
      reason: '说明文字丢了 —— 设计理由又回到只有代码注释知道的状态',
    );
  });

  testWidgets('「编辑器」：三项都在，两个连续值项各带 Slider', (WidgetTester tester) async {
    await openPanel(tester);
    await goto(tester, '编辑器');

    expect(find.text('正文宽度'), findsOneWidget);
    expect(find.text('正文字号'), findsOneWidget);
    expect(find.text('行高（正文）'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(2));
    // 宽度是"少量互斥选项" ⇒ M3 的 SegmentedButton（不是 Radio / 下拉）。
    expect(find.byType(SegmentedButton<EditorWidthMode>), findsOneWidget);
    expect(find.text('窄'), findsOneWidget);
    expect(find.text('标准'), findsOneWidget);
    expect(find.text('宽'), findsOneWidget);
  });

  testWidgets('「关于」：应用信息 / 开源许可 / 数据目录', (WidgetTester tester) async {
    await openPanel(tester);
    await goto(tester, '关于');

    expect(find.text('开源许可'), findsOneWidget);
    expect(find.text('数据目录'), findsOneWidget);
    // 数据目录路径以可选中文本呈现（AppData 路径肉眼抄不下）。
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text(kDataDir), findsOneWidget);
  });

  /// §5.2：面板打开后**必须接管焦点**。
  ///
  /// 不接管的话 Esc 照旧能用（它走全局 handler），但 **Tab 不能**：焦点还留在
  /// 编辑器（它 `autoFocus: true`），Tab 只在前一个作用域里转 ⇒ 在面板里按 Tab
  /// "毫无反应"（2026-09-21 用户实报）。这条测试就是那个 bug 的闸门。
  testWidgets('打开即接管焦点：Tab 能走进面板并看到焦点环', (WidgetTester tester) async {
    await openPanel(tester);

    // ① 直接断言"面板拿住了焦点"——这才是**真正的闸门**：修之前这里会是宿主里
    // 那个 `autofocus` 的控件（`debugLabel` 为 null）。只靠"Tab 能不能走到环"
    // 不够：宿主元素少时，不接管焦点也可能在几次 Tab 之内就碰到面板。
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'settings.panel',
      reason: '面板没有在打开时接管焦点 ⇒ Tab 会落在遮罩背后的控件上',
    );
    expect(
      ringFinder(),
      findsNothing,
      reason: '刚打开时焦点在面板本身（还没有环）——若这里有环，说明判据混进了别的东西',
    );

    // 面板里第一个可聚焦的可能不是导航项（比如标题栏的关闭按钮，IconButton
    // 没有环）⇒ 给几次预算，只要**在面板内**走到导航项就会看到环。
    bool sawRing = false;
    for (int i = 0; i < 8 && !sawRing; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      // 焦点变化在**帧末**结算 ⇒ 多推一帧（见 `theme/focus_ring.dart` 的经验）。
      await tester.pump();
      await tester.pump();
      sawRing = ringFinder().evaluate().isNotEmpty;
    }

    expect(sawRing, isTrue, reason: 'Tab 8 次都没在面板里出现焦点环：面板没接住焦点，或左导航不可遍历');

    // ② **焦点陷阱**：Tab 不得漏到遮罩背后。宿主里那两个可聚焦控件（autoFocus
    // 的占位 + "open" 按钮）就是"背后"，没圈住边界的话几步之内必然漏出去 ——
    // 2026-09-21 用户实报的第二个洞（`FocusTraversalGroup` 只管顺序不管边界）。
    bool insidePanel(FocusNode? node) =>
        node != null &&
        (node.debugLabel == 'settings.panel' ||
            node.ancestors.any(
              (FocusNode n) => n.debugLabel == 'settings.panel',
            ));

    for (int i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        insidePanel(FocusManager.instance.primaryFocus),
        isTrue,
        reason: '第 ${i + 1} 次 Tab 漏出了面板（焦点陷阱失效）',
      );
    }
  });
}
