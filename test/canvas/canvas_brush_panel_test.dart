import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/canvas/canvas_brush_panel.dart';
import 'package:sinan/src/canvas/canvas_surface.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_media.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';
import 'package:sinan/src/theme/app_color_swatch.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 笔刷设置面板（颜色 / 粗细 / 橡皮大小）的回归（2026-09-17，画布 P0）。
///
/// 这是用户提的第一需求——"笔不能选颜色"。用例只钉三件事：**能开、能改、能关**。
/// 最容易悄悄坏掉的是**哨兵**那条：面板显示"解析后的颜色"，但写回的必须是哨兵，
/// 否则颜色会被烤死在当前明暗档上，切主题就看不见（暗色画布那次的同类坑）。
void main() {
  /// 笔刷按钮的定位器（tooltip 是它唯一稳定的对外标识）。
  final Finder brushButton = find.byTooltip('笔刷：颜色 / 粗细 / 橡皮');

  Future<CanvasController> pumpSurface(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
  }) async {
    final CanvasController controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
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

  /// 卸载视图后再销毁控制器：先 dispose 控制器会让视图在拆除时用到已销毁对象。
  Future<void> teardown(WidgetTester tester, CanvasController controller) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  testWidgets('笔刷按钮能打开面板（初始不显示）', (WidgetTester tester) async {
    final CanvasController controller = await pumpSurface(tester);
    expect(find.byType(CanvasBrushPanel), findsNothing);

    await tester.tap(brushButton);
    await tester.pumpAndSettle();

    expect(find.byType(CanvasBrushPanel), findsOneWidget);
    expect(find.text('颜色'), findsOneWidget);
    expect(find.text('橡皮大小  8'), findsOneWidget);

    await teardown(tester, controller);
  });

  testWidgets('点色块把颜色写回控制器', (WidgetTester tester) async {
    final CanvasController controller = await pumpSurface(tester);
    await tester.tap(brushButton);
    await tester.pumpAndSettle();

    const Color red = Color(0xFFE5484D);
    await tester.tap(
      find.byWidgetPredicate(
        (Widget w) => w is AppColorSwatch && w.color == red,
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.penColor, red);
    await teardown(tester, controller);
  });

  testWidgets('暗色下「跟随主题」显示浅墨，但写回的是哨兵（不是烤死的具体色）', (
    WidgetTester tester,
  ) async {
    final CanvasController controller = await pumpSurface(
      tester,
      brightness: Brightness.dark,
    );
    await tester.tap(brushButton);
    await tester.pumpAndSettle();

    final Color darkInk = AppTheme.canvasInk(Brightness.dark);
    expect(darkInk, isNot(kThemeInk)); // 前提：暗色档确实不是哨兵值

    final Finder themeSwatch = find.byWidgetPredicate(
      (Widget w) => w is AppColorSwatch && w.color == darkInk,
    );
    expect(
      themeSwatch,
      findsOneWidget,
      reason: '哨兵项要按暗色墨色显示，否则暗色浮层上是个看不见的近黑点',
    );

    await tester.tap(themeSwatch);
    await tester.pumpAndSettle();
    expect(
      controller.penColor,
      kThemeInk,
      reason: '写回解析后的浅色就烤死了：切回亮色主题这笔就隐形',
    );

    await teardown(tester, controller);
  });

  testWidgets('拖笔宽滑杆改 penWidth', (WidgetTester tester) async {
    final CanvasController controller = await pumpSurface(tester);
    await tester.tap(brushButton);
    await tester.pumpAndSettle();

    final double before = controller.penWidth;
    await tester.drag(
      find.byKey(CanvasBrushPanel.penWidthKey),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();

    expect(controller.penWidth, greaterThan(before));
    expect(controller.penWidth, lessThanOrEqualTo(24)); // setter 的夹取
    await teardown(tester, controller);
  });

  testWidgets('点面板外关闭；点按钮自己也能关（按钮与面板同组）', (
    WidgetTester tester,
  ) async {
    final CanvasController controller = await pumpSurface(tester);

    await tester.tap(brushButton);
    await tester.pumpAndSettle();
    expect(find.byType(CanvasBrushPanel), findsOneWidget);

    // 点画布空白处（面板之外）⇒ 关闭。
    await tester.tapAt(const Offset(400, 400));
    await tester.pumpAndSettle();
    expect(
      find.byType(CanvasBrushPanel),
      findsNothing,
      reason: '点外部不收，浮层就成了甩不掉的挡板',
    );

    // 再开一次，点按钮 ⇒ 也能关（若按钮不在同组，down 会先收起、up 又打开）。
    await tester.tap(brushButton);
    await tester.pumpAndSettle();
    expect(find.byType(CanvasBrushPanel), findsOneWidget);
    await tester.tap(brushButton);
    await tester.pumpAndSettle();
    expect(find.byType(CanvasBrushPanel), findsNothing);

    await teardown(tester, controller);
  });
}
