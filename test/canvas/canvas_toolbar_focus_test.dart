import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/canvas/canvas_surface.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_media.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/focus_ring.dart';

/// 画布工具条的**焦点环**（`docs/ui_rewrite_plan.md` §5.2 第二步"铺开"）。
///
/// 工具条按钮本来就键盘可达（`IconButton` 自带焦点），缺的是"我在哪"的表达：一串
/// 同形图标按钮里，此前只有 M3 的淡色状态层。这里钉两件事——**聚焦才画环**、
/// **环不参与布局**（后者是 `FocusRing` 的核心取舍：环一出现就位移内容，比没有环更糟）。
void main() {
  Future<CanvasController> pumpToolbar(WidgetTester tester) async {
    final CanvasController controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: CanvasSurface(
            controller: controller,
            media: const RelativeMediaResolver('/data/sinan'),
            // 带上它 ⇒ AI 入口按钮才渲染（`onAiRun == null` 时整块不渲染），
            // 下面那条"都接了环"的覆盖要把它算进去。
            onAiRun: (String _) async {},
          ),
        ),
      ),
    );
    return controller;
  }

  Future<void> teardown(
    WidgetTester tester,
    CanvasController controller,
  ) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  /// 某个按钮**自己的**焦点环画着没有。
  ///
  /// 判据 = 那个 `FocusRing` 子树里 `foregroundDecoration` 非空的 `Container`
  /// （画法见 `lib/src/theme/focus_ring.dart`）。
  Finder ringOf(String tooltip) => find.descendant(
    of: find.ancestor(
      of: find.byTooltip(tooltip),
      matching: find.byType(FocusRing),
    ),
    matching: find.byWidgetPredicate(
      (Widget w) => w is Container && w.foregroundDecoration != null,
    ),
  );

  /// 按钮自己的 `FocusNode`。
  ///
  /// `FocusRingIconButton` 的契约就是"**同一个节点**交给 `FocusRing` 与 `IconButton`"
  /// ⇒ 从 `FocusRing` 上取到的那个，正是按钮在用的那个。
  FocusNode nodeOf(WidgetTester tester, String tooltip) => tester
      .widget<FocusRing>(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(FocusRing),
        ),
      )
      .focusNode;

  /// 焦点变化在**帧末**结算 ⇒ 多推一帧（见 `theme/focus_ring.dart` 的调试经验）。
  Future<void> settleFocus(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  testWidgets('焦点落在工具按钮上才画环，且环不改变布局', (WidgetTester tester) async {
    final CanvasController controller = await pumpToolbar(tester);

    expect(ringOf('画笔'), findsNothing, reason: '没聚焦就不该有环（环是焦点表达）');

    final Size before = tester.getSize(find.byTooltip('画笔'));
    nodeOf(tester, '画笔').requestFocus();
    await settleFocus(tester);

    expect(ringOf('画笔'), findsOneWidget);
    expect(
      tester.getSize(find.byTooltip('画笔')),
      before,
      reason: '环必须画在边界内侧、不参与布局（否则按钮会位移）',
    );

    // 焦点移走 ⇒ 环撤掉（不是"卡住不撤"，那是测试没多推一帧的假象）。
    nodeOf(tester, '缩小').requestFocus();
    await settleFocus(tester);
    expect(ringOf('画笔'), findsNothing);
    expect(ringOf('缩小'), findsOneWidget);

    await teardown(tester, controller);
  });

  testWidgets('主条上 15 个可聚焦控件都接了环（别漏掉条上的按钮）', (WidgetTester tester) async {
    final CanvasController controller = await pumpToolbar(tester);

    // 工具 5（`FocusRingIconButton`）+ 缩放/适应 3 + 导出 2 + 导入 1；
    // 三块浮层入口按钮（笔刷 / 插入 / AI，锚点也是 `FocusRingIconButton`）；
    // 缩放徽标 1（`TextButton`，走 `_ZoomBadge` 自带节点那条路）。
    const List<String> tooltips = <String>[
      '选择 / 框选',
      '抓手（空格）',
      '画笔',
      '橡皮',
      '连线（从一个卡片拖到另一个）',
      '缩小',
      '放大',
      '适应内容',
      '导出 PNG',
      '导出画布文件（.canvas.json，含图片）',
      '导入画布文件（.canvas.json，替换当前画布）',
      '笔刷：颜色 / 粗细 / 橡皮',
      '插入形状（按住拖拽定尺寸）/ 图片',
      'AI：用一句话让模型调整画布',
      '当前缩放（点击回到 100%）',
    ];

    for (final String tooltip in tooltips) {
      expect(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(FocusRing),
        ),
        findsOneWidget,
        reason: '「$tooltip」没有焦点环（新增按钮时别忘了用 FocusRingIconButton）',
      );
    }

    await teardown(tester, controller);
  });
}
