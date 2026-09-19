import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/canvas/canvas_surface.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_media.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 工具栏**缩放倍数实时显示**的回归（2026-09-18 用户要求"补放大倍数实时显示，
/// 和放大缩小放一起"）。
///
/// 要点：
/// ① 倍数与放大/缩小**同组**（滚轮 / 适应内容引发的缩放也要跟着变）；
/// ② 点徽标回到 100%（缩放到很偏时一键复位）。
void main() {
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

  Future<void> teardown(
    WidgetTester tester,
    CanvasController controller,
  ) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  testWidgets('倍数随放大/缩小实时变化', (WidgetTester tester) async {
    final CanvasController controller = await pumpSurface(tester);

    expect(find.text('100%'), findsOneWidget, reason: '初始应为 100%');

    await tester.tap(find.byTooltip('放大'));
    await tester.pump();
    expect(find.text('125%'), findsOneWidget);

    // 回到 100%，再缩一次 ⇒ 80%（1 / 1.25）。
    await tester.tap(find.byTooltip('缩小'));
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);

    await tester.tap(find.byTooltip('缩小'));
    await tester.pump();
    expect(find.text('80%'), findsOneWidget);

    await teardown(tester, controller);
  });

  testWidgets('滚轮缩放（不经按钮）也会更新倍数', (WidgetTester tester) async {
    final CanvasController controller = await pumpSurface(tester);

    // 直接改控制器（等价于滚轮/抓手缩放）——徽标靠外层 ListenableBuilder 刷新。
    controller.zoomBy(2.0);
    await tester.pump();
    expect(find.text('200%'), findsOneWidget);

    await teardown(tester, controller);
  });

  testWidgets('点倍数徽标回到 100%', (WidgetTester tester) async {
    final CanvasController controller = await pumpSurface(tester);

    controller.zoomBy(2.0);
    await tester.pump();
    expect(find.text('200%'), findsOneWidget);

    await tester.tap(find.text('200%'));
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
    expect(controller.camera.scale, closeTo(1.0, 1e-9));

    await teardown(tester, controller);
  });
}
