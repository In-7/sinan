import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';
import 'package:sinan/src/editor/core/note_title_field.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 标题输入框回归测试。
///
/// 这一组守的是**实际踩过的坑**：编辑页标题莫名多出一圈圆角描边，看起来
/// 像个表单输入框。根因是主题 `inputDecorationTheme` 设了
/// `enabledBorder` / `focusedBorder`，而 Flutter 解析 `InputDecoration` 时
/// 这两个**优先于** `border`——只写 `border: InputBorder.none` 盖不住。
void main() {
  const EditorTypography typography = EditorTypography(
    fontSize: 16,
    lineHeight: 1.7,
  );

  group('笔记标题输入框', () {
    testWidgets('主题的表单描边不会漏到标题上（各状态全置空）', (WidgetTester tester) async {
      // 前提：主题确实设了描边。没有这一条，下面的断言就是空转
      // （主题若本来就没有描边，漏写 enabledBorder 也不会出问题）。
      // 主题侧的取值类型随 Material 版本演进而变（InputDecorationThemeData），
      // 这里让类型自动推导，只关心"描边确实被设上了"这一事实。
      final InputDecorationThemeData ids =
          AppTheme.dark().inputDecorationTheme;
      expect(ids.enabledBorder, isA<OutlineInputBorder>());
      expect(ids.focusedBorder, isA<OutlineInputBorder>());

      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _harness(controller: controller, typography: typography),
      );

      final InputDecoration decoration = tester
          .widget<TextField>(find.byType(TextField))
          .decoration!;
      expect(decoration.border, InputBorder.none);
      expect(decoration.enabledBorder, InputBorder.none);
      expect(decoration.focusedBorder, InputBorder.none);
      expect(decoration.disabledBorder, InputBorder.none);
      expect(decoration.errorBorder, InputBorder.none);
      expect(decoration.focusedErrorBorder, InputBorder.none);
    });

    testWidgets('标题排版：随正文字号 1.4 倍（＝ h2）+ 中文黄金排版项', (WidgetTester tester) async {
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _harness(controller: controller, typography: typography),
      );

      final TextField field = tester.widget<TextField>(find.byType(TextField));
      final TextStyle style = field.style!;
      // 字号吸附整像素（16 × 1.4 = 22.4 → 22）。
      expect(
        style.fontSize,
        EditorTypography.snap(16 * EditorTypography.titleScale),
      );
      expect(style.fontWeight, FontWeight.w600);
      // 行盒也吸附（22 × 1.35 = 29.7 → 30）：`height` 是回填的"行盒 / 字号"。
      expect(
        style.fontSize! * style.height!,
        closeTo(
          EditorTypography.lineBox(style.fontSize!, NoteTitleField.lineHeight),
          1e-9,
        ),
      );
      // 汉字相关项：字距 0、even 行盒、CJK 回退链（缺回退链会出现
      // 逐字符挑字体 → 笔画粗细不一 / 缺字形方框）。
      expect(style.letterSpacing, 0);
      expect(style.leadingDistribution, TextLeadingDistribution.even);
      expect(style.fontFamily, AppTheme.editorFont);
      expect(style.fontFamilyFallback, AppTheme.cjkFontFallback);
      // 空标题提示词（与列表里的回退文案同词）。
      expect(field.decoration!.hintText, '无标题');
    });

    testWidgets('标题 → 正文的间距：按字号缩放，且不为 0（"太近"那个 bug 的原状）', (
      WidgetTester tester,
    ) async {
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);

      /// NoteTitleField 的最外层 Padding：下留白 = 字号 × titleBottomSpacing。
      double bottomOf(EditorTypography t) => tester
          .widget<Padding>(
            find
                .ancestor(
                  of: find.byType(TextField),
                  matching: find.byType(Padding),
                )
                .first,
          )
          .padding
          .resolve(TextDirection.ltr)
          .bottom;

      await tester.pumpWidget(
        _harness(controller: controller, typography: typography),
      );
      expect(bottomOf(typography), typography.titleBottomGap);
      expect(
        bottomOf(typography),
        greaterThan(0),
        reason: '为 0 时标题贴着正文——就是本轮修掉的那个观感',
      );

      // 与字号联动（沿用"改设置即时生效"口径：正文 20px 时按 20 缩放）。
      const EditorTypography bigger = EditorTypography(
        fontSize: 20,
        lineHeight: 1.9,
      );
      await tester.pumpWidget(
        _harness(controller: controller, typography: bigger),
      );
      expect(bottomOf(bigger), bigger.titleBottomGap);
    });

    testWidgets('字号设置联动标题（改字号 → 标题跟着变）', (WidgetTester tester) async {
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _harness(
          controller: controller,
          typography: const EditorTypography(fontSize: 20, lineHeight: 1.9),
        ),
      );

      expect(
        tester.widget<TextField>(find.byType(TextField)).style!.fontSize,
        EditorTypography.snap(20 * EditorTypography.titleScale),
      );
    });
  });
}

Widget _harness({
  required TextEditingController controller,
  required EditorTypography typography,
}) => MaterialApp(
  theme: AppTheme.dark(),
  home: Scaffold(
    body: NoteTitleField(
      controller: controller,
      onChanged: (String _) {},
      typography: typography,
    ),
  ),
);
