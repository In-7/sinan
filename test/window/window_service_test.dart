import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/window/window_service.dart';

/// **窗口自身底色**（[WindowService.applyWindowBackground]）的闸门（2026-09-23）。
///
/// 它钉的是这次性能改动里**唯一能被机器判定的部分**：
/// 1. 发给平台的值必须是 [AppTheme.windowBackground]（同一个令牌，写死就漂）；
/// 2. **必须不透明**（A=255）——半透就等于没改，透明窗口那笔照付；
/// 3. **幂等**：明暗没变时不该反复重设（每次都是一次平台往返）。
///
/// 判据用 platform channel（与 `window_base_test.dart` 同一套路）：结构对不对会骗人，
/// 真正发出去的值不会。窗口那侧到底省了多少，只有实机看（见该方法的文档）。
void main() {
  const MethodChannel channel = MethodChannel('window_manager');

  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  List<MethodCall> bgCalls() =>
      calls.where((MethodCall c) => c.method == 'setBackgroundColor').toList();

  Map<Object?, Object?> argsOf(MethodCall c) =>
      c.arguments as Map<Object?, Object?>;

  void expectMatchesToken(MethodCall c, Brightness b) {
    final Color token = AppTheme.windowBackground(b);
    expect(
      argsOf(c)['backgroundColorA'],
      255,
      reason: '$b：窗口底必须**不透明**——半透就等于没省（透明窗口那笔照付）',
    );
    for (final (String key, double channelValue) in <(String, double)>[
      ('R', token.r),
      ('G', token.g),
      ('B', token.b),
    ]) {
      expect(
        argsOf(c)['backgroundColor$key'],
        closeTo((channelValue * 255).round(), 1),
        reason: '$b：$key 与窗口底令牌不符 ⇒ 改主题时窗口不跟着变',
      );
    }
  }

  testWidgets('亮色：把不透明的窗口底发给平台', (WidgetTester tester) async {
    await WindowService.applyWindowBackground(Brightness.light);

    expect(bgCalls(), hasLength(1), reason: '没发出 setBackgroundColor');
    expectMatchesToken(bgCalls().single, Brightness.light);
  });

  testWidgets('幂等：明暗没变 ⇒ 不再重设（每次都是一次平台往返）', (tester) async {
    await WindowService.applyWindowBackground(Brightness.light);
    expect(bgCalls(), isEmpty, reason: '明暗没变却又重设了一次');
  });

  testWidgets('切到暗色：重设，且值跟着令牌走', (WidgetTester tester) async {
    await WindowService.applyWindowBackground(Brightness.dark);

    expect(bgCalls(), hasLength(1), reason: '明暗变了却没有重设窗口底');
    expectMatchesToken(bgCalls().single, Brightness.dark);
  });
}
