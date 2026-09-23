import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sinan/main.dart' as app;

/// 命令层的**端到端**检查（`docs/ui_rewrite_plan.md` §13 阶段 1 的 "integration 1"）。
///
/// 单测（`test/command/`）覆盖了过滤、置灰、执行这些逻辑，但覆盖不到这一段
/// **接线**：
/// - 分发器是否真的装在应用外壳上（`main.dart` 的 `installCommandDispatcher`）；
/// - `Ctrl+Shift+P` 是否真的能被注册表解析到 `palette.open`；
/// - 面板是否真的浮在 root Overlay 上、Esc 是否真的能关掉它。
///
/// 这些只有真应用（真 `ProviderScope`、真 Overlay、真按键管线）里才验得了。
///
/// 跑法：`flutter test integration_test/command_palette_test.dart -d windows`
/// （会打开真实窗口，并且用**真实数据库**——但它只开关面板，不写任何数据。）
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Ctrl+Shift+P 打开命令面板，Esc 关闭', (WidgetTester tester) async {
    await app.main();
    await tester.pumpAndSettle();

    // 修饰键要**逐个按下**再按 P：`KeyBinding.matches` 读的是 `HardwareKeyboard`
    // 的**按下集合**，不是事件自带的修饰位（见 command.dart 的说明）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      find.text('命令面板'),
      findsOneWidget,
      reason: 'Ctrl+Shift+P 没打开面板：分发器没装、或键位没解析到 palette.open。',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('命令面板'), findsNothing);
  });
}
