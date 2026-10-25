import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart' as official;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/editor/blocks/custom_block_components.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 编辑器中文排版（`editor_typography.dart`）的验证。
///
/// 分两层：
/// 1. **单元**——档位/字距/字重/回退链的算术与取值（口径对齐 quill 版
///    `_chineseStyles`，改这里会同时影响两个视图）；
/// 2. **真编辑器**——官方 `HeadingBlockComponentBuilder` 的
///    `textSpanDecorator` 真的把我们的档位**合并**进了渲染 span（这条最
///    重要：单元测试通过而接线没接上，是这类"样式层"改动的典型失败模式）。
void main() {
  const EditorTypography typography = EditorTypography(
    fontSize: 16,
    lineHeight: 1.75,
  );

  group('中文排版：单元口径', () {
    test('标题档位 = 共识 ×0.875 后**吸附整像素**（16px 下 28 / 22 / 19 / 16）', () {
      expect(typography.heading(1).fontSize, 28); // 共识 2.0 收一档
      expect(typography.heading(2).fontSize, 22); // 1.6 收一档 → 22.4 吸附
      expect(typography.heading(3).fontSize, 19); // 1.29 收一档 → 19.2 吸附
      // h4 取 1.0（与正文同号）：原 1.16 收一档是 17.6，吸附后 18，与 h3（19）
      // 只差 1px——层级不可辨。两家共识的第四档本来就是"与正文同号"
      // （Apple 的 Headline、鸿蒙的 Subtitle_M 都与 Body 同号）。
      expect(typography.heading(4).fontSize, 16);
      // h5/h6 与正文同号（Apple 体系里 Headline 也是 17pt = Body）。
      for (final int level in <int>[5, 6]) {
        expect(typography.heading(level).fontSize, 16);
      }
      // 越界钳位（官方 headingNode 也钳 1~6），不抛异常。
      expect(typography.heading(0).fontSize, 28);
      expect(typography.heading(99).fontSize, 16);
    });

    test('行内加粗 = w600（不是官方默认的 w700）', () {
      // 官方 `TextStyleConfiguration.bold` 默认是 `FontWeight.bold`(w700)。
      // 中文字体（苹方 / 打包的单字重 LXGW）没有真 Bold 字重 ⇒ w700 是合成加粗
      // （笔画糊边）；且会让"加粗的字比标题还重"（标题是 w600）。
      final TextStyleConfiguration config = typography.toTextStyleConfiguration(
        text: const official.Color(0xFF3A3A3A),
        link: const official.Color(0xFF0000FF),
        codeBackground: const official.Color(0xFFEEEEEE),
        muted: const official.Color(0xFF999999),
      );
      expect(config.bold.fontWeight, FontWeight.w600);
      // 只给字重这一项：字族 / 回退链 / 字距由 span 基样式提供（`combine` 语义），
      // 写多了会顶掉它们。
      expect(config.bold.fontFamily, isNull);
      expect(config.bold.fontFamilyFallback, isNull);
    });

    test('标题：行盒吸附整像素（设计倍数 1.4）/ 零字距 / w600，且**不设字色**', () {
      final official.TextStyle heading = typography.heading(1);
      // `height` 是回填的"整数行盒 / 字号"（28px 字号 → 38px 行盒），
      // 所以断言行盒落在整像素，而不是倍数本身等于 1.4。
      expect(
        heading.fontSize! * heading.height!,
        closeTo(
          EditorTypography.lineBox(28, EditorTypography.headingLineHeight),
          1e-9,
        ),
      );
      expect(heading.letterSpacing, 0);
      // Apple 的中文要求：苹方只有 Regular/Medium/Semibold，w700 会**合成加粗**
      // （笔画糊边）；Semibold 在 Windows 雅黑 UI 与 macOS 苹方上都是真实字重。
      expect(heading.fontWeight, FontWeight.w600);
      expect(heading.leadingDistribution, TextLeadingDistribution.even);
      // 关键：字色留空才能继承基样式——一旦写死颜色，行内"文字颜色"
      // 属性会被标题档顶掉（官方是 combine 语义，后者赢）。
      expect(heading.color, isNull);
    });

    test('正文：CJK 回退链 + w400（Regular） + 零字距 + even 行盒', () {
      final official.TextStyle body = typography.body();
      expect(body.fontSize, 16);
      // 16 × 1.75 = 28 本来就是整数、且与字号同奇偶 ⇒ 倍数原样保留。
      expect(body.height, 1.75);
      // Apple 与鸿蒙两家的正文规范都写明 Regular。
      expect(body.fontWeight, FontWeight.w400);
      expect(body.letterSpacing, 0);
      expect(body.leadingDistribution, TextLeadingDistribution.even);
      expect(body.fontFamily, AppTheme.editorFont);
      expect(body.fontFamilyFallback, AppTheme.cjkFontFallback);
      expect(body.fontFamilyFallback, contains('Microsoft YaHei UI'));
    });

    test('字号/行高随设置缩放，档位比例不变（吸附后仍是整数像素）', () {
      const EditorTypography big = EditorTypography(
        fontSize: 20,
        lineHeight: 1.9,
      );
      expect(big.heading(1).fontSize, 35); // 20 × 1.75
      expect(big.heading(2).fontSize, 28); // 20 × 1.4
      expect(big.heading(3).fontSize, 24); // 20 × 1.2
      expect(big.body().height, 1.9); // 20 × 1.9 = 38（整数）⇒ 原样
      // 标题行高是固定值，不随正文行高走（汉字标题不需要 1.9 那么散）。
      expect(
        big.heading(1).fontSize! * big.heading(1).height!,
        closeTo(
          EditorTypography.lineBox(35, EditorTypography.headingLineHeight),
          1e-9,
        ),
      );
    });

    test('笔记标题 = 文内 h2（2026-09-14 定案）', () {
      // 与二级标题**同号**：17px 正文下 1.4 ⇒ 吸附后 24px（原为 1.75 = h1）。
      // ⚠️ 与 h1 的关系变成"有意地更小"——旧断言"不得小于 h1（层级倒挂）"
      // 已随这条定案作废，别照旧口径改回去。
      expect(EditorTypography.titleScale, EditorTypography.headingScale(2));
      expect(EditorTypography.snap(17 * EditorTypography.titleScale), 24);
    });

    test('编辑器字体 = 打包的思源黑体 SC 可变字体（全平台同一字族）', () {
      // 打包字体自带中英全套字形 ⇒ 混排天然同源、基线恒定，且全平台观感
      // 一致（2026-09-11 从"按平台选雅黑/苹方/思源"切换而来）。
      // 2026-10-24：霞鹜新晰黑（单字重）→ 思源黑体 SC VF（wght 轴 100~900）
      // ⇒ 标题 / 加粗是真字重，不再是合成加粗。
      // 缺字仍由 cjkFontFallback（雅黑/苹方/思源）逐字体兜底。
      expect(AppTheme.editorFont, 'SourceHanSansSC-VF');
      expect(AppTheme.cjkFontFallback, contains('Microsoft YaHei UI'));
    });

    test('字重轴：正文 / 标题都带 wght 显式轴（与 fontWeight 同值，冗余保险）', () {
      // 3.47 起 fontWeight **已隐式映射** wght 轴（engine 层，见
      // [AppTheme.weightVariation] 的更正记录）——显式轴与它同值共存，
      // 是"要轴值 ≠ 声明字重"场景的保险，不是生效的前提。
      expect(typography.body().fontVariations, <FontVariation>[
        const FontVariation('wght', 400),
      ]);
      expect(typography.heading(1).fontVariations, <FontVariation>[
        const FontVariation('wght', 600),
      ]);
    });

    test('基样式带前景色；链接 / 行内代码 / 自动补全只改色，不破坏中文项', () {
      const Color textColor = Color(0xFF202124);
      final TextStyleConfiguration config =
          typography.toTextStyleConfiguration(
            text: textColor,
            muted: const Color(0xFF888888),
            link: const Color(0xFF1A73E8),
            codeBackground: const Color(0xFFEEEEEE),
          );
      // ⚠️ "亮色下正文隐形"那个 bug 的回归：基样式不给 color，编辑器最终会落到
      // 引擎默认白（RichText 不继承 DefaultTextStyle）。
      expect(config.text.color, textColor);
      // 段落级行高同样吸附：16 × 1.75 = 28（整数）⇒ 原样。
      expect(config.lineHeight, 1.75);
      expect(config.leadingDistribution, TextLeadingDistribution.even);
      expect(config.href.fontFamilyFallback, AppTheme.cjkFontFallback);
      expect(config.code.fontFamily, AppTheme.monoFont);
      expect(config.code.fontFamilyFallback, AppTheme.monoFallback);
      // 行内代码字号继承正文（官方无法对行内 span 单独缩放）。
      expect(config.code.fontSize, isNull);
    });

    test('注册表：标题只补上间距（首块不给），段落内边距保持官方默认', () {
      final Map<String, BlockComponentBuilder> builders =
          sinanBlockComponentBuilders(
            typography: typography,
            markerColor: const Color(0xFF3B6FD4),
          );
      final BlockComponentBuilder heading = builders[HeadingBlockKeys.type]!;
      expect(heading, isA<HeadingBlockComponentBuilder>());

      // 段落：官方默认（上下各 4），我们一个字没动。
      expect(
        builders[ParagraphBlockKeys.type]!.configuration.padding(
          paragraphNode(text: '正文'),
        ),
        const EdgeInsets.symmetric(vertical: 4),
      );

      final Document document = Document(
        root: pageNode(
          children: <Node>[
            headingNode(level: 1, text: '开头就是标题'),
            paragraphNode(text: '前一段'),
            headingNode(level: 2, text: '中间标题'),
          ],
        ),
      );
      // 文档首块：不给上间距（对标 GitHub 的 `*:first-child { margin-top: 0 }`）。
      expect(
        heading.configuration.padding(document.root.children[0]),
        const EdgeInsets.only(bottom: 4),
      );
      // 非首块：上间距 = headingTopSpacing(档位) × 正文字号，下间距仍为官方 4。
      expect(
        heading.configuration.padding(document.root.children[2]),
        EdgeInsets.only(
          top: 16 * EditorTypography.headingTopSpacing(2),
          bottom: 4,
        ),
      );
      // 上间距**按级别递增**（2026-09-14）：三级之间"只剩字号一个维度"
      // 时读者分不出"新的一节"与"新的一小点"——间距是唯一不占横向空间的
      // 层级杠杆（正文列宽固定）。这条锁住递增关系，别改回统一值。
      expect(
        EditorTypography.headingTopSpacing(1),
        greaterThan(EditorTypography.headingTopSpacing(2)),
      );
      expect(
        EditorTypography.headingTopSpacing(2),
        greaterThan(EditorTypography.headingTopSpacing(3)),
      );
      // h4~h6 与 h3 同档（它们与正文同号，是"加粗的正文"，不抢结构）。
      for (final int level in <int>[4, 5, 6]) {
        expect(
          EditorTypography.headingTopSpacing(level),
          EditorTypography.headingTopSpacing(3),
        );
      }
    });
  });

  group('整像素（Impeller 锐度杠杆）：14 / 16 / 18px 正文', () {
    for (final double bodySize in <double>[14, 16, 18]) {
      test('正文 $bodySize：字号 / 行盒 / 行距 / 标题档 / 间距全是整数像素', () {
        final EditorTypography t = EditorTypography(
          fontSize: bodySize,
          lineHeight: 1.75,
        );

        /// 行盒（px）的整数性决定字形会不会被"半个像素"取样。
        /// （applyHeightToFirstAscent/LastDescent=true 后行距 = 行盒，
        /// 行盒整数 ⇒ 每行都在像素栅格上；旧"盒与字号同奇偶"约束已废弃。）
        void expectOnPixelGrid(double size, double multiple) {
          final double box =
              size * t.body(size: size, height: multiple).height!;
          final double snapped = box.roundToDouble();
          // 倍数由「行盒 / 字号」回填 ⇒ 乘积有 ~1e-15 浮点误差，故用容差
          // （误差远小于半个像素，观感上仍是整像素）。
          expect(box, closeTo(snapped, 1e-9), reason: '行盒 $box 不是整数像素');
        }

        expect(t.body().fontSize, bodySize);
        expectOnPixelGrid(bodySize, 1.75);
        for (int level = 1; level <= 6; level++) {
          final official.TextStyle heading = t.heading(level);
          expect(heading.fontSize, heading.fontSize!.roundToDouble());
          expectOnPixelGrid(
            heading.fontSize!,
            EditorTypography.headingLineHeight,
          );
        }

        // 标题下留白与标题块上间距同样吸附（半像素的空档看着"差一丝"）。
        expect(t.titleBottomGap, t.titleBottomGap.roundToDouble());
        final Document document = Document(
          root: pageNode(
            children: <Node>[
              paragraphNode(text: '前一段'),
              headingNode(level: 2, text: '标题'),
            ],
          ),
        );
        final double top = t
            .headingPadding(document.root.children[1])
            .resolve(TextDirection.ltr)
            .top;
        expect(top, top.roundToDouble());
      });
    }
  });

  group('中文排版：真编辑器实测渲染', () {
    testWidgets('标题用 28/w600，正文用 16/1.75/零字距（含 CJK 回退链）', (
      WidgetTester tester,
    ) async {
      final Document document = Document(
        root: pageNode(
          children: <Node>[
            headingNode(level: 1, text: '一级标题'),
            paragraphNode(text: '正文内容'),
          ],
        ),
      );
      await _pumpEditor(tester, document: document);

      final official.TextStyle heading = _renderedStyleOf(tester, '一级标题');
      expect(heading.fontSize, 28);
      // 行盒（= 字号 × height）落在整像素；倍数本身是回填值、不等于 1.4。
      // （snap(28 × 1.4) = 39；旧"同奇偶"回退到 38 的算法已废弃。）
      expect(heading.fontSize! * heading.height!, closeTo(39, 1e-9));
      expect(heading.fontWeight, FontWeight.w600);
      expect(heading.fontFamilyFallback, AppTheme.cjkFontFallback);

      final official.TextStyle body = _renderedStyleOf(tester, '正文内容');
      expect(body.fontSize, 16);
      expect(body.height, 1.75);
      expect(body.letterSpacing, 0);
      expect(body.fontFamily, AppTheme.editorFont);
      expect(body.fontFamilyFallback, AppTheme.cjkFontFallback);
    });

    testWidgets('正文/标题的文字色来自主题（缺了就是引擎默认白：深色侥幸、亮色隐形）', (
      WidgetTester tester,
    ) async {
      // 背景：官方 `AppFlowyRichText` 最后是交给 **RichText** 渲染的，而
      // RichText **不继承 `DefaultTextStyle`**——span 没有 color 时会落到
      // 引擎默认值（`dart:ui` 的 TextStyle 文档：color 默认 **white**）。
      // 于是"不设 color、交给 Ambient 样式"这个假设在编辑器里根本不成立：
      // 深色下白字侥幸正常，亮色下白底白字、正文近乎隐形。
      for (final Brightness brightness in Brightness.values) {
        final ThemeData theme = brightness == Brightness.light
            ? AppTheme.light()
            : AppTheme.dark();
        await _pumpEditor(
          tester,
          document: Document(
            root: pageNode(
              children: <Node>[
                headingNode(level: 1, text: '一级标题'),
                paragraphNode(text: '正文内容'),
              ],
            ),
          ),
          brightness: brightness,
        );

        final Color expectedText = AppTheme.editorText(
          brightness,
          theme.colorScheme,
        );
        expect(
          _renderedStyleOf(tester, '正文内容').color,
          expectedText,
          reason: '$brightness：正文 span 必须带主题前景色',
        );
        // 标题靠 `combine` 合并进基样式，**字色不能自己写**——写死会顶掉行内
        // "文字颜色"属性；正确做法是让它继承基样式刚给上的正文色。
        expect(
          _renderedStyleOf(tester, '一级标题').color,
          expectedText,
          reason: '$brightness：标题应继承基样式的前景色',
        );
      }
    });

    testWidgets('段落块间距 = 行盒 + 官方块内边距（padding 是按块生效的）', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(
        tester,
        document: Document(
          root: pageNode(
            children: <Node>[
              paragraphNode(text: '第一行'),
              paragraphNode(text: '第二行'),
            ],
          ),
        ),
      );

      final double upper = tester.getTopLeft(_paragraph('第一行')).dy;
      final double lower = tester.getTopLeft(_paragraph('第二行')).dy;

      // 行盒 28（16 × 1.75）+ 官方块内边距 8 ≈ 36。上界放到 48 只要求
      // 一件事：**没有被塞进额外的竖直 padding**。
      // 踩过的错误版本（把 quill 的"底部留白 96"搬进 EditorStyle.padding）
      // 在这里是 100+，表现成"行距是正常的 4 倍"。
      expect(
        lower - upper,
        lessThan(48),
        reason: 'EditorStyle.padding 是按块生效的，竖直方向不能写大值',
      );
    });
  });
}

/// 定位某个段落文字的渲染对象（官方用 RichText 渲染块内容）。
Finder _paragraph(String text) => find.byWidgetPredicate(
  (Widget widget) => widget is RichText && widget.text.toPlainText() == text,
);

/// 用真编辑器渲染（与 `custom_block_components_test.dart` 同构：
/// 真主题 + 主题桥 + 本地化；官方组件读的是 flutter/material 的主题）。
Future<void> _pumpEditor(
  WidgetTester tester, {
  required Document document,
  Brightness brightness = Brightness.light,
}) async {
  const EditorTypography typography = EditorTypography(
    fontSize: 16,
    lineHeight: 1.75,
  );
  final EditorState state = EditorState(document: document);
  final EditorScrollController scroll = EditorScrollController(
    editorState: state,
  );
  addTearDown(() {
    scroll.dispose();
    state.dispose();
  });

  final ThemeData theme = brightness == Brightness.light
      ? AppTheme.light()
      : AppTheme.dark();
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
            // 与视图同一来源：这是**按块**生效的内边距（竖直值会加在每个块上）。
            padding: EditorTypography.blockPadding,
            textStyleConfiguration: typography.toTextStyleConfiguration(
              // 与生产同源：正文色走 [AppTheme.editorText]（暗色降到 #D6D6D6）。
              text: AppTheme.editorText(
                theme.brightness,
                theme.colorScheme,
              ),
              muted: theme.colorScheme.onSurfaceVariant,
              link: theme.colorScheme.primary,
              codeBackground: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          blockComponentBuilders: sinanBlockComponentBuilders(
            typography: typography,
            // 列表/待办标记的主题色（本文件不测标记渲染，给固定值）。
            markerColor: const Color(0xFF3B6FD4),
          ),
          characterShortcutEvents: sinanCharacterShortcutEvents(
            // 本文件不测菜单配色（另有 slash_menu_items_test 守着）。
            slashMenuStyle: SelectionMenuStyle.light,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 取渲染树上某段纯文本的**实际样式**（官方用 RichText 渲染块内容）。
official.TextStyle _renderedStyleOf(WidgetTester tester, String text) {
  for (final RichText rich
      in tester.widgetList<RichText>(find.byType(RichText))) {
    if (rich.text.toPlainText() != text) continue;
    official.TextStyle? found;
    rich.text.visitChildren((InlineSpan span) {
      if (span is TextSpan && span.text == text && span.style != null) {
        found = span.style;
        return false;
      }
      return true;
    });
    if (found != null) return found!;
  }
  fail('渲染树上找不到文本 "$text"');
}
