import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/focus_ring.dart';
import 'package:sinan/src/theme/tokens.dart';

/// [FocusRing] 的行为（`docs/ui_rewrite_plan.md` §5.2）。
///
/// 三件事必须成立，否则"统一焦点环"就是摆设：
/// ① 控件拿到焦点 ⇒ 出现环；焦点移到**别的控件** ⇒ 环撤掉；
/// ② **不参与布局**（环出现/消失时控件尺寸逐像素不变）——否则列表行会跳动；
/// ③ 环取主题 primary、粗细取令牌、圆角由调用方给。
///
/// ⚠️ 写这类测试的一条硬经验（2026-09-21）：`requestFocus()` 之后**要多推一帧**。
/// 焦点变化由 `FocusManager` 在**帧末**统一结算，监听回调引发的重建落在下一帧
/// ——只推一帧会断到"上一帧的环"，表现为"环卡住不撤"的**假红**（第一版就是这么
/// 误诊的，当时还错怪了 ancestor 探针的写法）。下面的用例把这条钉住了。
void main() {
  /// 环是否存在（`foregroundDecoration` 非空即戴上环）。
  ///
  /// ⚠️ 必须限定在 [FocusRing] **子树内**：整棵树别处也可能有带
  /// `foregroundDecoration` 的 `Container`，不限定就会出现"永远找得到"的假绿。
  Finder ringFinder() => find.descendant(
    of: find.byType(FocusRing),
    matching: find.byWidgetPredicate(
      (Widget w) => w is Container && w.foregroundDecoration != null,
    ),
  );

  Future<void> pumpRing(
    WidgetTester tester,
    FocusNode node,
    FocusNode other, {
    required BorderRadius radius,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // 另一个可聚焦控件：用来把焦点**移走**。
                Focus(
                  focusNode: other,
                  child: const SizedBox(width: 40, height: 20),
                ),
                FocusRing(
                  focusNode: node,
                  borderRadius: radius,
                  child: Focus(
                    focusNode: node,
                    child: const SizedBox(width: 40, height: 20),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('拿到焦点 ⇒ 出现环；焦点移到别的控件 ⇒ 环撤掉', (WidgetTester tester) async {
    final FocusNode node = FocusNode();
    final FocusNode other = FocusNode();
    addTearDown(node.dispose);
    addTearDown(other.dispose);

    await pumpRing(
      tester,
      node,
      other,
      radius: BorderRadius.circular(Tokens.radiusSm),
    );
    expect(ringFinder(), findsNothing, reason: '没有焦点时不该有环');

    node.requestFocus();
    await tester.pump();
    expect(ringFinder(), findsOneWidget, reason: '控件获得焦点后应有环');

    other.requestFocus();
    await tester.pump();
    expect(other.hasFocus, isTrue, reason: '前置事实：焦点确实移走了');
    expect(node.hasFocus, isFalse, reason: '前置事实：原节点确实失焦了');
    // 焦点变化是在**帧末**统一结算的（`FocusManager` 防重入）⇒ 监听回调引发的
    // 重建落在下一帧。这里多推一帧再断言，否则断的是"上一帧的环"（会假红）。
    await tester.pump();
    expect(ringFinder(), findsNothing, reason: '焦点移走后环必须撤掉');
  });

  testWidgets('环不参与布局：控件尺寸逐像素不变', (WidgetTester tester) async {
    final FocusNode node = FocusNode();
    final FocusNode other = FocusNode();
    addTearDown(node.dispose);
    addTearDown(other.dispose);

    await pumpRing(
      tester,
      node,
      other,
      radius: BorderRadius.circular(Tokens.radiusSm),
    );
    final Size before = tester.getSize(find.byType(FocusRing));

    node.requestFocus();
    await tester.pump();
    expect(ringFinder(), findsOneWidget);
    final Size after = tester.getSize(find.byType(FocusRing));

    expect(after, before, reason: '焦点环改变了布局 ⇒ 列表行会跳动');
  });

  testWidgets('环取主题 primary、粗细取 Tokens.focusRingWidth', (
    WidgetTester tester,
  ) async {
    final FocusNode node = FocusNode();
    final FocusNode other = FocusNode();
    addTearDown(node.dispose);
    addTearDown(other.dispose);
    final BorderRadius radius = BorderRadius.circular(Tokens.radiusLg);

    await pumpRing(tester, node, other, radius: radius);
    node.requestFocus();
    await tester.pump();

    final Container box = tester.widget<Container>(ringFinder());
    final BoxDecoration decoration = box.foregroundDecoration! as BoxDecoration;
    final BoxBorder border = decoration.border! as Border;
    final ColorScheme scheme = AppTheme.light().colorScheme;

    expect(border.top.color, scheme.primary);
    expect(border.top.width, Tokens.focusRingWidth);
    expect(decoration.borderRadius, radius, reason: '环的圆角必须由调用方给（要与控件形状一致）');
  });
}
