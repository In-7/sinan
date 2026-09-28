import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/ask_panel.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/answer_service.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 右侧常驻 **AI 问答轨**（[AskRail]）的行为测试（2026-09-28）。
///
/// 与 [ask_panel_test.dart]（浮层态）互补，这里钉右轨**自己的**三条语义：
/// 1. 开关 false → true 时把焦点递进提问框；
/// 2. 焦点在栏内按 Esc / 点关闭钮 ⇒ 收起整栏（并摘焦点）；
/// 3. 点引用角标只跳转、**不关栏**——答案要留着和原文对照（浮层态相反）。
void main() {
  /// 直接把右轨挂成 Row 的固定宽子项（与产品里 `_AiRailSlot > OverflowBox`
  /// 喂给它的布局条件一致：有界高、固定 340 宽）。
  Widget host(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(
        body: Row(
          children: <Widget>[
            Expanded(child: ColoredBox(color: Colors.grey)),
            AskRail(),
          ],
        ),
      ),
    ),
  );

  testWidgets('开关翻转 ⇒ 焦点进提问框；关闭钮收起并摘焦点', (WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(host(container));

    final Finder field = find.byType(TextField);
    expect(field, findsOneWidget);
    expect(
      tester.widget<TextField>(field).focusNode?.hasFocus,
      isFalse,
      reason: '初始关闭态不抢焦点',
    );

    // false → true ⇒ AskRail 的 ref.listen 在首帧后聚焦输入框。
    container.read(aiPanelOpenProvider.notifier).open();
    await tester.pump();
    await tester.pump();
    expect(
      tester.widget<TextField>(field).focusNode?.hasFocus,
      isTrue,
      reason: '打开右轨就该能直接打字',
    );

    // 点关闭钮 ⇒ 收起且焦点从提问框摘走（不能落在正在收为宽 0 的控件上）。
    // 注：unfocus() 后 primaryFocus 回到根 FocusScopeNode 是 Flutter 的正常
    // 行为，这里只钉「输入框不再持有焦点」这一条产品语义。
    await tester.tap(find.byTooltip('关闭（Esc）'));
    await tester.pump();
    expect(container.read(aiPanelOpenProvider), isFalse);
    expect(
      tester.widget<TextField>(field).focusNode?.hasFocus,
      isFalse,
      reason: '收起时必须先 unfocus 输入框',
    );
  });

  testWidgets('焦点在栏内按 Esc ⇒ 收起整栏（焦点祖先链消费，不波及别处）', (WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(host(container));

    // 打开并点进提问框，让焦点真的落在右栏子树里。
    container.read(aiPanelOpenProvider.notifier).open();
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(
      container.read(aiPanelOpenProvider),
      isFalse,
      reason: 'Esc 在右栏焦点子树内应被 AskRail 的 Focus 消费为「收起」',
    );
  });

  testWidgets('点引用角标 ⇒ 经 locate 跳转，但问答轨保持打开', (WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer(
      overrides: [
        answerServiceProvider.overrideWithValue(_StubAnswerService()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(host(container));
    // 模拟轨已打开（此时点引用本就不该关它）。
    container.read(aiPanelOpenProvider.notifier).open();
    await tester.pump();

    // 问一句 ⇒ stub 答案带一条引用 [1]。
    await tester.enterText(find.byType(TextField), '这段讲了什么');
    await tester.pump(); // 等一帧让发送钮从 disabled 翻成可点
    await tester.tap(find.byTooltip('发送（Enter）'));
    await tester.pump();
    expect(find.byType(ActionChip), findsOneWidget);

    await tester.tap(find.byType(ActionChip));
    await tester.pump();

    // ① 真的经唯一跳转通道定位到了原文块；
    expect(
      container.read(locateProvider)?.noteId,
      'n1',
      reason: '角标必须经 locateProvider 跳到原文',
    );
    expect(container.read(locateProvider)?.blockId, 'b1');
    // ② 右轨**不收起**（与浮层态最关键的差异：答案留着对照）。
    expect(container.read(aiPanelOpenProvider), isTrue, reason: '点角标只跳转，不关轨');
  });
}

/// 不碰真模型 / 真检索的问答桩：答案固定带一条编号引用。
class _StubAnswerService implements AnswerService {
  @override
  Future<Answer> ask(
    String question, {
    int limit = AnswerService.defaultLimit,
  }) async {
    return (
      text: '答案在这里。[1]',
      citations: const <Citation>[
        (index: 1, noteId: 'n1', blockId: 'b1', snippet: '原文片段内容在这里'),
      ],
      unknownCitations: const <int>[],
      vectorUsed: true,
      vectorFallbackReason: null,
    );
  }

  // 其余成员（retriever / llm）本测试用不到。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
