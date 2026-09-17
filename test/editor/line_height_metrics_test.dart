import 'dart:ui' show BoxHeightStyle;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/editor/blocks/custom_block_components.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 「行高」在 **appflowy 渲染管线**下的真实几何，以及**整像素吸附**的回归。
///
/// appflowy 的文字管线和 quill 不同（`AppFlowyRichText` 用
/// `TextHeightBehavior(applyHeightToFirstAscent: false,
/// applyHeightToLastDescent: false)` + `leadingDistribution: even`），行盒算法
/// 不能照抄，实测出来的两条规律（见 `EditorTypography.lineBox` 的文档）：
///
/// 1. **首行盒 = 字号 × 倍数**；
/// 2. **行距 =（行盒 + 字号）/ 2**（16px 下 = 8 ×(1 + 倍数)）——
///    官方把首行升部余量与末行降部余量都裁掉了，所以行距比"字号 × 倍数"紧，
///    滑杆值 ≠ 视觉倍数。
///
/// 因此**行距是整数** ⇔「行盒 − 字号」是偶数 ⇔ 行盒与字号同奇偶。
/// `EditorTypography.lineBox` 就是按这条把行盒吸附到整数像素的：字号/行盒/
/// 行距全落在像素栅格上，字形才不被"半个像素"取样。
///
/// 测量手段：`RenderParagraph.getBoxesForSelection` 读**字形盒**的真实坐标
/// （浮点、不取整）——是否落在整像素，看这里。
///
/// ⚠️ 边界：**"笔画是否发虚"属光栅化观感**。widget 测试用的是测试字体
/// （不走真实字形光栅化，也没有亚像素 AA），所以这一项**测不了**；这里测的是
/// 机制层（几何是否落在整像素），肉眼验证仍要走截图。
void main() {
  // 足够长的一段中文：720 列宽 / 16px 下约 45 字一行，必然折成多行。
  final String longText = '这是一段用来测量行距的中文文本。' * 6;

  group('行高 → 行距几何（appflowy 实测 + 整像素吸附）', () {
    for (final double lineHeight in <double>[1.5, 1.625, 1.7, 1.75, 2.0, 2.5]) {
      testWidgets('行高 $lineHeight', (WidgetTester tester) async {
        await _pumpEditor(tester, text: longText, lineHeight: lineHeight);

        final RenderParagraph paragraph = _paragraphOf(tester, longText);
        final double firstLineTop = _lineTop(paragraph, 0);
        final double secondLineTop = _lineTop(paragraph, _charsPerLine);
        final double stride = secondLineTop - firstLineTop;

        // 折行确实发生了（否则测的不是"行距"）。
        expect(paragraph.size.height, greaterThan(3 * 16));

        // 规律 1 + 2（applyHeightToFirstAscent/LastDescent=true 后的新几何）：
        // 行盒是"字号 × 倍数"吸附后的整数；**行距 = 行盒**（每行同构，
        // 滑杆值 = 视觉倍数——旧几何的（盒+字号)/2 公式已随
        // applyHeightToFirstAscent:false 一起废弃）。
        final double box = EditorTypography.lineBox(16, lineHeight);
        expect(box, box.roundToDouble(), reason: '行盒必须落在整像素上');
        expect(stride, box);

        // 整像素：**行距与首行顶都是整数** ⇒ 每一行的字形都落在像素栅格上。
        // 吸附前这里是 1.7 → 行距 21.4、首行顶被顶下 0.4（半个像素，汉字发灰）。
        expect((stride * 100).round() % 100, 0, reason: '行距不该落在半像素上');
        expect(
          (firstLineTop * 100).round() % 100,
          0,
          reason: '首行顶不该落在半像素上',
        );
      });
    }
  });

  group('字号 14 / 16 / 18 都不落在半像素（Impeller 锐度）', () {
    // 滑杆的 0.125 步长只在 16px 下天然给出整数行盒（16 × 0.125 = 2）；
    // 14px（1.75）与 18px（2.25）都会算出小数 ⇒ 必须靠吸附。
    for (final double fontSize in <double>[14, 16, 18]) {
      for (final double lineHeight in <double>[1.5, 1.75, 2.0]) {
        testWidgets('字号 $fontSize / 行高 $lineHeight', (
          WidgetTester tester,
        ) async {
          await _pumpEditor(
            tester,
            text: longText,
            lineHeight: lineHeight,
            fontSize: fontSize,
          );

          final RenderParagraph paragraph = _paragraphOf(tester, longText);
          final double firstLineTop = _lineTop(paragraph, 0);

          // 字号 × 倍数吸附后行盒必须是整数（行距 = 行盒，见第一组）。
          final double box = EditorTypography.lineBox(fontSize, lineHeight);
          expect(box, box.roundToDouble());
          expect(
            (firstLineTop * 100).round() % 100,
            0,
            reason: '首行顶应在整像素上',
          );
        });
      }
    }
  });
}

/// 720 列宽 / 16px 下一行约 45 字；取第 46 个字即落在第二行。
const int _charsPerLine = 46;

Document _document(String text) =>
    Document(root: pageNode(children: <Node>[paragraphNode(text: text)]));

/// 取某个字符的字形盒顶部（浮点，不取整）——行距的"整像素/半像素"看它。
double _lineTop(RenderParagraph paragraph, int offset) {
  final List<TextBox> boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: offset, extentOffset: offset + 1),
    boxHeightStyle: BoxHeightStyle.max,
  );
  expect(boxes, isNotEmpty, reason: '偏移 $offset 处应有字形盒');
  return boxes.first.toRect().top;
}

RenderParagraph _paragraphOf(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is RichText && widget.text.toPlainText() == text,
      ),
    );

Future<void> _pumpEditor(
  WidgetTester tester, {
  required String text,
  required double lineHeight,
  double fontSize = 16,
}) async {
  final EditorTypography typography = EditorTypography(
    fontSize: fontSize,
    lineHeight: lineHeight,
  );
  final EditorState state = EditorState(document: _document(text));
  final EditorScrollController scroll = EditorScrollController(
    editorState: state,
  );
  addTearDown(() {
    scroll.dispose();
    state.dispose();
  });

  final ThemeData theme = AppTheme.light();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        ...GlobalMaterialLocalizations.delegates,
        AppFlowyEditorLocalizations.delegate,
      ],
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      builder: (BuildContext context, Widget? child) =>
          // ignore: deprecated_member_use
          MaterialUiCompatibilityBridge(child: child!),
      home: Scaffold(
        body: AppFlowyEditor(
          editorState: state,
          editorScrollController: scroll,
          editorStyle: EditorStyle.desktop(
            // 与视图同一来源（**按块**生效的内边距）。
            padding: EditorTypography.blockPadding,
            // 固定 720：折行位置可预测（测量用它反推"第 46 字落在第二行"）。
            maxWidth: 720,
            textStyleConfiguration: typography.toTextStyleConfiguration(
              text: theme.colorScheme.onSurface,
              muted: theme.colorScheme.onSurfaceVariant,
              link: theme.colorScheme.primary,
              codeBackground: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          blockComponentBuilders: sinanBlockComponentBuilders(
            typography: typography,
            // 列表/待办标记的主题色（与视图同一来源：primary）。
            markerColor: theme.colorScheme.primary,
          ),
          characterShortcutEvents: const <CharacterShortcutEvent>[],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
