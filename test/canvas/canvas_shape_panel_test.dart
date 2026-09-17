import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/canvas/canvas_shape_panel.dart';
import 'package:sinan/src/canvas/canvas_surface.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/canvas_media.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';
import 'package:sinan/src/theme/app_color_swatch.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 图形属性面板（颜色 / 填充 / 描边粗细）的回归（2026-09-17，画布 P0 收尾）。
///
/// 三条最值得钉的：
/// ① **只在选中形状时出现**——没有作用对象却占工具条的位，是纯噪声；
/// ② 改动必须**进撤销栈**（"一次面板操作 = 一条命令"是这个面板的设计前提，
///    否则用户调坏颜色回不去）；
/// ③ 填充时描边滑杆**禁用**——"拖了没反应"最容易被当成坏了。
void main() {
  /// 图形属性按钮的定位器（tooltip 是它唯一稳定的对外标识，同笔刷按钮）。
  final Finder shapeButton = find.byTooltip('图形属性：颜色 / 填充 / 描边');

  ShapeItem shape() => ShapeItem(
        rect: const Rect.fromLTWH(0, 0, 40, 40),
        kind: CanvasShapeKind.rectangle,
        color: kThemeInk,
      );

  Future<CanvasController> pumpSurface(WidgetTester tester) async {
    final CanvasController controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: CanvasSurface(
            controller: controller,
            media: const RelativeMediaResolver('/data/sinan'),
          ),
        ),
      ),
    );
    return controller;
  }

  /// 卸载视图后再销毁控制器：先 dispose 会让视图在拆除时用到已销毁对象。
  Future<void> teardown(WidgetTester tester, CanvasController controller) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  /// 选中一个形状并打开面板，返回该形状。
  Future<ShapeItem> openPanel(
    WidgetTester tester,
    CanvasController controller,
  ) async {
    final ShapeItem item = shape();
    controller.document.addItem(item);
    controller.selectItems(<CanvasItem>[item]);
    await tester.pumpAndSettle();

    await tester.tap(shapeButton);
    await tester.pumpAndSettle();
    expect(find.byType(CanvasShapePanel), findsOneWidget);
    return item;
  }

  testWidgets('没选中形状时不出现；选中后出现，取消选中又消失', (WidgetTester tester) async {
    final CanvasController controller = await pumpSurface(tester);
    expect(shapeButton, findsNothing, reason: '没有作用对象却占了工具条的位');

    final ShapeItem item = shape();
    controller.document.addItem(item);
    controller.selectItems(<CanvasItem>[item]);
    await tester.pumpAndSettle();
    expect(shapeButton, findsOneWidget);

    controller.clearSelection();
    await tester.pumpAndSettle();
    expect(shapeButton, findsNothing, reason: '取消选中后按钮该跟着消失');

    await teardown(tester, controller);
  });

  testWidgets('选中的是图片时不出现（属性面板只管形状）', (WidgetTester tester) async {
    final CanvasController controller = await pumpSurface(tester);
    final ImageItem image = ImageItem(rect: const Rect.fromLTWH(0, 0, 40, 40));
    controller.document.addItem(image);
    controller.selectItems(<CanvasItem>[image]);
    await tester.pumpAndSettle();

    expect(shapeButton, findsNothing);
    await teardown(tester, controller);
  });

  testWidgets('切填充：写进 item，并且能撤销回去', (WidgetTester tester) async {
    final CanvasController controller = await pumpSurface(tester);
    final ShapeItem item = await openPanel(tester, controller);

    await tester.tap(find.byKey(CanvasShapePanel.filledKey));
    await tester.pumpAndSettle();
    expect(item.filled, isTrue);

    controller.undo();
    await tester.pumpAndSettle();
    expect(item.filled, isFalse, reason: '面板改动没进撤销栈：调坏了回不去');

    await teardown(tester, controller);
  });

  testWidgets('改颜色：写进 item，并且能撤销回去', (WidgetTester tester) async {
    final CanvasController controller = await pumpSurface(tester);
    final ShapeItem item = await openPanel(tester, controller);

    const Color red = Color(0xFFE5484D);
    await tester.tap(
      find.byWidgetPredicate(
        (Widget w) => w is AppColorSwatch && w.color == red,
      ),
    );
    await tester.pumpAndSettle();
    expect(item.color, red);

    controller.undo();
    await tester.pumpAndSettle();
    expect(item.color, kThemeInk, reason: '改色没进撤销栈');

    await teardown(tester, controller);
  });

  testWidgets('拖描边滑杆改 strokeWidth（夹在 1~24）', (WidgetTester tester) async {
    final CanvasController controller = await pumpSurface(tester);
    final ShapeItem item = await openPanel(tester, controller);
    final double before = item.strokeWidth;

    await tester.drag(
      find.byKey(CanvasShapePanel.strokeWidthKey),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();

    expect(item.strokeWidth, greaterThan(before));
    expect(item.strokeWidth, lessThanOrEqualTo(24)); // 控制器里的夹取
    await teardown(tester, controller);
  });

  testWidgets('填充时描边滑杆禁用（拖了没反应最容易被当成坏了）', (WidgetTester tester) async {
    final CanvasController controller = await pumpSurface(tester);
    await openPanel(tester, controller);

    Slider slider() => tester.widget<Slider>(
      find.descendant(
        of: find.byKey(CanvasShapePanel.strokeWidthKey),
        matching: find.byType(Slider),
      ),
    );

    expect(slider().onChanged, isNotNull, reason: '空心形状的描边粗细必须能调');

    controller.updateSelectedShapeStyle(filled: true);
    await tester.pumpAndSettle();
    expect(
      slider().onChanged,
      isNull,
      reason: '填充后没有描边：滑杆该禁用，而不是让人拖了没反应',
    );

    await teardown(tester, controller);
  });

  testWidgets('窄窗口下工具条换行，按钮一个都不藏（实测反馈的"看不到了"）', (
    WidgetTester tester,
  ) async {
    // 420 ≈ "最小窗口 720 + 侧栏 300"时画布区的宽度：按钮排不下是常态而非极端。
    tester.view.physicalSize = const Size(420, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final CanvasController controller = await pumpSurface(tester);

    expect(
      tester.takeException(),
      isNull,
      reason: '工具条溢出（RenderFlex overflow）：右端按钮会被裁掉，用户根本点不到',
    );
    // 被裁掉的正是最右端这两个（导出画布文件 / 导入）——它们必须在树上。
    expect(find.byTooltip('导出画布文件（.canvas.json，含图片）'), findsOneWidget);
    expect(find.byTooltip('导入画布文件（.canvas.json，替换当前画布）'), findsOneWidget);

    await teardown(tester, controller);
  });
}
