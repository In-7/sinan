import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_view.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';

/// 画布**必须**裁剪在自身范围内。
///
/// 这是一个实测过的真 bug：`CustomPaint` 不裁剪绘制内容，而 `Stack` 的
/// `clipBehavior` 只在"子件**布局**越界"时才生效——画布的 Stack 子件尺寸恰好
/// 等于自身，于是它认为没越界、不裁。表现为笔迹（尤其按住拖到相邻列表栏上）
/// 直接画到面板之外，整个界面都能看到墨迹。
void main() {
  testWidgets('画布内容被硬裁剪在自身范围内（笔迹不会画到相邻面板）',
      (WidgetTester tester) async {
    final CanvasController controller = CanvasController();
    addTearDown(controller.dispose);
    // 一条远超视口的笔迹：没有裁剪时它会一路画到面板之外。
    controller.document.addStroke(
      InkStroke(
        color: const Color(0xFF000000),
        baseWidth: 4,
        points: const <InkPoint>[
          InkPoint(Offset(0, 0), 0),
          InkPoint(Offset(4000, 4000), 0),
        ],
      ),
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 320,
            height: 200,
            child: CanvasView(
              controller: controller,
              backgroundColor: const Color(0xFFFFFFFF),
              gridColor: const Color(0xFFEEEEEE),
              accentColor: const Color(0xFF3366FF),
              staleColor: const Color(0xFFFF8800),
              inkColor: const Color(0xFF1F1F1F),
            ),
          ),
        ),
      ),
    );

    // 裁剪切在画布边界上：尺寸等于画布自己，而不是整个窗口。
    final Finder clip = find.byType(ClipRect);
    expect(clip, findsOneWidget);
    expect(tester.getSize(clip), const Size(320, 200));
    // 四层绘制都落在裁剪之内。
    expect(
      find.descendant(of: clip, matching: find.byType(CustomPaint)),
      findsWidgets,
    );
  });
}
