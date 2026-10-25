import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
// 与 appflowy 内部同一套 material（官方 material 同名类型是**另一套**，
// 两边同时导入会 ambiguous，见 `block_height_predictor_spike_test.dart`）。
import 'package:material_ui/material_ui.dart';

import '../support/app_font.dart';
import 'package:sinan/src/editor/core/block_height_predictor.dart';
import 'package:sinan/src/editor/blocks/custom_block_components.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';

/// 块手柄的**布局契约**：手柄是行内布局
/// （`BlockComponentActionWrapper` 的 `Row[手柄, 正文]` + `maintainSize`
/// 常驻占位，见 `custom_block_components.dart` 的 `_SinanBlockHandle`），
/// 文字列 = **列宽 − 块内边距 32 − 手柄 48**。
///
/// 这条闸门钉住 2026-09-15 的那类回归：预测器漏扣手柄宽度 ⇒ 折行提前 ⇒
/// 预测与渲染脱节 ⇒ 滚动总高边滚边变（当时漂了 286px）。
/// 判据是诊断时用的那把尺子：`RenderParagraph.constraints.maxWidth`。
///
/// （2026-09-15 曾试过"零宽动作槽 + OverflowBox 侧绘"让手柄不占布局，
/// 因命中测试限制回滚：画在块盒外的部件按 Flutter 的 `RenderBox.hitTest`
/// 规则不可点，且离开块内容区就触发 vendored 的 onExit 隐藏。）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // 真实字体：与 spike 同理，测试字体的字符全是 1em 方格，测不准。
    await loadAppFont();
  });

  testWidgets('块手柄不占布局宽度：正文列 = 列宽 − 32', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const double contentWidth = 720;
    const EditorTypography typography = EditorTypography(
      fontSize: 17,
      lineHeight: 1.5,
    );
    final TextStyleConfiguration config = typography.toTextStyleConfiguration(
      text: const Color(0xFF000000),
      link: const Color(0xFF1565C0),
      codeBackground: const Color(0xFFEEEEEE),
      muted: const Color(0xFF757575),
    );

    final Node paragraph = paragraphNode(text: '汉' * 10);
    final EditorState state = EditorState(
      document: Document(root: pageNode(children: <Node>[paragraph])),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1400,
          height: 4000,
          child: AppFlowyEditor(
            editorState: state,
            editorStyle: EditorStyle.desktop(
              padding: EditorTypography.blockPadding,
              maxWidth: contentWidth,
              textStyleConfiguration: config,
            ),
            // 与生产同一份 builder 表：手柄已对所有非页面块开启（showActions）。
            blockComponentBuilders: sinanBlockComponentBuilders(
              typography: typography,
              markerColor: const Color(0xFF1565C0),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 找正文那层 RenderParagraph（占位符那层排的是单个空格，排除之）。
    final List<RenderParagraph> paragraphs = <RenderParagraph>[];
    void collect(RenderObject object) {
      if (object is RenderParagraph &&
          object.text.toPlainText().length == 10) {
        paragraphs.add(object);
      }
      object.visitChildren(collect);
    }

    collect(tester.renderObject<RenderBox>(find.byType(AppFlowyEditor)));
    expect(paragraphs, hasLength(1), reason: '没找到正文段落（结构变了？）');

    // 32 = blockPadding.horizontal、48 = 块手柄（EdgeInsets 的 getter 不是
    // 常量，这里展开；口径见 `EditorTypography.blockHandleWidth`）。
    const double expected = contentWidth - 32 - 48;
    expect(
      paragraphs.single.constraints.maxWidth,
      moreOrLessEquals(expected),
      reason:
          '正文列宽 ${paragraphs.single.constraints.maxWidth}px ≠ 预期 $expected：'
          '手柄没有占布局宽度（改成零宽侧绘了？）或预测器/渲染口径脱节'
          '（见文件头注释）',
    );

    // 预测器与渲染同口径：同样的文字列宽，折行/行盒才会一致。
    final BlockHeightPredictor predictor = BlockHeightPredictor(
      typography: typography,
      textStyleConfiguration: config,
      maxWidth: contentWidth,
      blockPadding: EditorTypography.blockPadding,
    );
    expect(
      predictor.textWidthOf(paragraph),
      moreOrLessEquals(expected),
      reason: '预测器的文字列宽与渲染不一致',
    );
  });
}
