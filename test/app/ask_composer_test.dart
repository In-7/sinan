import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:sinan/src/ai/llm_client.dart';
import 'package:sinan/src/app/ask_panel.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/answer_service.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/tokens.dart';

/// 一体化提问 Composer（2026-09-29 落地，ChatGPT/Claude 范式）的行为闸门：
///
/// 1. 空内容：圆形发送钮 disabled（点了不发）；
/// 2. 有内容：发送 → 带原文调 AnswerService → 输入清空、答案落位；
/// 3. 桌面 **Enter 发送**（焦点节点拦截，不插入换行）；
/// 4. `busy`：纸飞机原位换成转圈，期间再发被忽略；
/// 5. 视觉契约：1–6 行自适应、板色容器圆角 12、聚焦只提亮描边（不染主色）；
/// 6. 服务不可用：报错压在 composer 之上。
void main() {
  late _FakeAnswerService service;

  Widget host(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(
        body: Center(
          child: SizedBox(
            width: Tokens.askRailWidth,
            height: 640,
            child: Padding(
              padding: EdgeInsets.all(Tokens.spaceLg),
              child: AskPanelBody(fillExpanded: true),
            ),
          ),
        ),
      ),
    ),
  );

  ProviderContainer makeContainer() {
    service = _FakeAnswerService();
    final ProviderContainer container = ProviderContainer(
      overrides: [answerServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    return container;
  }

  Finder field() => find.byType(TextField);
  Finder sendButton() => find.byTooltip('发送（Enter）');

  testWidgets('空内容 ⇒ 发送钮 disabled，点击不触发 ask', (WidgetTester tester) async {
    final ProviderContainer container = makeContainer();
    await tester.pumpWidget(host(container));

    // 空内容时 InkWell 没有 onTap（语义 disabled）：直接点发送位置，
    // 唯一可观察的契约就是 AnswerService 一次都没被调到。
    await tester.tap(sendButton(), warnIfMissed: false);
    await tester.pump();
    expect(service.calls, isEmpty, reason: 'disabled 状态点击必须被吞掉');
  });

  testWidgets('输入后发送 ⇒ 原文入参、输入清空、答案与引用落位', (WidgetTester tester) async {
    final ProviderContainer container = makeContainer();
    await tester.pumpWidget(host(container));

    await tester.enterText(field(), '这段讲了什么');
    await tester.pump();

    await tester.tap(sendButton());
    await tester.pumpAndSettle();

    expect(service.calls.single, '这段讲了什么');
    expect(
      tester.widget<TextField>(field()).controller?.text,
      isEmpty,
      reason: '一问发出即清空，方便连续追问',
    );
    expect(find.text('答案在这里。[1]'), findsOneWidget);
    expect(find.byType(ActionChip), findsOneWidget);
    // 发完焦点必须留在提问框里（连续追问不需要再点一次）。
    expect(tester.widget<TextField>(field()).focusNode?.hasFocus, isTrue);
  });

  testWidgets('Enter 发送（焦点节点拦截，不插入换行）', (WidgetTester tester) async {
    final ProviderContainer container = makeContainer();
    await tester.pumpWidget(host(container));

    await tester.enterText(field(), '用 Enter 发');
    await tester.pump();
    expect(tester.widget<TextField>(field()).focusNode?.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(service.calls.single, '用 Enter 发');
    expect(tester.widget<TextField>(field()).controller?.text, isEmpty);
  });

  testWidgets('检索中 ⇒ 原位转圈且发送被忽略；完成后恢复', (WidgetTester tester) async {
    final ProviderContainer container = makeContainer();
    final Completer<Answer> completer = Completer<Answer>();
    service.responder = (_) => completer.future;
    await tester.pumpWidget(host(container));

    await tester.enterText(field(), '慢点答');
    await tester.pump();
    await tester.tap(sendButton());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(service.calls, <String>['慢点答']);

    // busy 期间再触发（比如又按一次 Enter）必须被 _ask 的忙等挡掉。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(service.calls, hasLength(1), reason: '检索中不得重入');

    completer.complete(service.answerFor('慢点答'));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('答案在这里。[1]'), findsOneWidget);
  });

  testWidgets('视觉契约：板色圆角容器，聚焦只提亮描边（不染色、不发光）', (WidgetTester tester) async {
    final ProviderContainer container = makeContainer();
    await tester.pumpWidget(host(container));

    final Finder composerBox = find.descendant(
      of: find.byType(AskPanelBody),
      matching: find.byType(AnimatedContainer),
    );
    expect(composerBox, findsOneWidget, reason: 'composer 是唯一的动画容器');

    final TextField tf = tester.widget<TextField>(field());
    expect(tf.minLines, 1);
    expect(tf.maxLines, 6, reason: '多行问题要能长到 6 行再内部滚动');

    final BoxDecoration idle =
        tester.widget<AnimatedContainer>(composerBox).decoration!
            as BoxDecoration;
    expect(idle.borderRadius, BorderRadius.circular(Tokens.radiusLg));
    final Color idleBorder = (idle.border! as Border).top.color;

    // 聚焦输入框，等 150ms 描边过渡走完。
    await tester.tap(field());
    await tester.pump(Tokens.durationFast);
    await tester.pumpAndSettle();

    final BoxDecoration focused =
        tester.widget<AnimatedContainer>(composerBox).decoration!
            as BoxDecoration;
    final Color focusedBorder = (focused.border! as Border).top.color;
    expect(focusedBorder, isNot(idleBorder), reason: '聚焦要有描边反馈');
    expect(
      focusedBorder,
      isNot(AppTheme.light().colorScheme.primary),
      reason: '反馈只提亮中性描边，不染主色、不发光',
    );
    expect(
      focused.color,
      AppTheme.boardFill(Brightness.light),
      reason: '容器底板色不随聚焦变化',
    );
  });

  testWidgets('服务不可用 ⇒ 报错压在 composer 之上且不影响继续提问', (WidgetTester tester) async {
    final ProviderContainer container = makeContainer();
    service.responder = (_) async =>
        throw const LlmUnavailableException('还没配置模型，先去设置里接一个');
    await tester.pumpWidget(host(container));

    await tester.enterText(field(), '你好');
    await tester.pump();
    await tester.tap(sendButton());
    await tester.pumpAndSettle();

    expect(find.text('还没配置模型，先去设置里接一个'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // 报错后 composer 仍在、仍可继续输入。
    expect(sendButton(), findsOneWidget);
  });

  testWidgets('发送钮与灵感同款：24 方钮 + 绿勾瞬时确认 + 朝上纸飞机', (WidgetTester tester) async {
    // 2026-11-18 用户定：与灵感「记下」一样的样式、方案与图标，两处差异：
    // 按钮尺寸 24（AI composer 更紧凑）+ 纸飞机旋转朝上（灵感朝右上）。
    final ProviderContainer container = makeContainer();
    await tester.pumpWidget(host(container));

    IconButton button() => tester.widget<IconButton>(find.byType(IconButton));
    Color? bg() =>
        button().style?.backgroundColor?.resolve(const <WidgetState>{});

    // 与灵感同款：按钮是真 24×24（灵感 36）；图标 18（灵感 24，2026-11-19
    // 用户定小一号，24 钮配 24 图标太满）。
    // ⚠️ 只断 minimumSize 不够——默认 tap-target 下限 48 会顶住，必须连
    // padding:zero + shrinkWrap 一起断，否则渲染仍是 48。
    expect(button().iconSize, Tokens.iconSm);
    expect(
      button().style?.minimumSize?.resolve(const <WidgetState>{}),
      const Size(24, 24),
    );
    expect(
      button().style?.padding?.resolve(const <WidgetState>{}),
      EdgeInsets.zero,
    );
    expect(button().style?.tapTargetSize, MaterialTapTargetSize.shrinkWrap);
    expect(tester.getSize(find.byType(IconButton)), const Size(24, 24));
    // Send2 原始尖端朝右（SVG 顶点 M21 12），逆时针 90° 转到正上。
    // 像素量测已确认（2026-11-19 光栅化扫墨迹横向跨度：top=28 < mid=60
    // < bottom=72 ⇒ 顶部窄=尖端、底部宽=分叉尾翼，确为朝上）。
    final RotatedBox rotated = tester.widget<RotatedBox>(
      find.descendant(
        of: find.byType(IconButton),
        matching: find.byType(RotatedBox),
      ),
    );
    expect(rotated.quarterTurns, -1);
    expect(
      find.descendant(
        of: find.byType(RotatedBox),
        matching: find.byType(tabler.Send2),
      ),
      findsOneWidget,
    );
    // 禁用态：灰底（surfaceContainerHighest——与灵感同一套 disabled 语言，
    // 不是 primary 透明度）+ 纸飞机。
    expect(bg(), AppTheme.light().colorScheme.surfaceContainerHighest);
    expect(find.byType(tabler.Send2), findsOneWidget);

    await tester.enterText(field(), '一个问题');
    await tester.pump();
    expect(bg(), AppTheme.light().colorScheme.primary, reason: '可发态主色底');

    await tester.tap(sendButton());
    // ⚠️ 这里不能 `pumpAndSettle`：它按 100ms/泵推进假时钟，异步链拖过 6 泵
    // 就把 600ms 绿勾窗整个跑完了（实测踩过）。零时推进的 `pump` 取样才在窗内。
    await tester.pump();
    await tester.pump();
    // 发送成功 ⇒ 绿勾瞬时确认（灵感「记下」同款方案）。
    expect(bg(), Bauhaus.green(Brightness.light));
    expect(find.byType(tabler.Check), findsOneWidget);
    expect(find.byTooltip('已发送'), findsOneWidget);

    await tester.pump(Tokens.durationFeedback);
    await tester.pumpAndSettle();
    expect(
      bg(),
      AppTheme.light().colorScheme.surfaceContainerHighest,
      reason: '绿勾窗过后回纸飞机、回禁用底（文本已清空）',
    );
    expect(find.byType(tabler.Send2), findsOneWidget);
    expect(sendButton(), findsOneWidget, reason: 'tooltip 回「发送（Enter）」');
  });
}

class _FakeAnswerService implements AnswerService {
  final List<String> calls = <String>[];
  Future<Answer> Function(String question)? responder;

  Answer answerFor(String question) => (
    text: '答案在这里。[1]',
    citations: const <Citation>[
      (index: 1, noteId: 'n1', blockId: 'b1', snippet: '原文片段内容在这里'),
    ],
    unknownCitations: const <int>[],
    vectorUsed: true,
    vectorFallbackReason: null,
  );

  @override
  Future<Answer> ask(
    String question, {
    int limit = AnswerService.defaultLimit,
  }) {
    calls.add(question);
    return responder?.call(question) ??
        Future<Answer>.value(answerFor(question));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
