import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:sinan/src/domain/settings.dart';
import 'package:sinan/src/editor/blocks/custom_block_components.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/tokens.dart';

import '../support/app_font.dart';

/// 引用块**淡底外衣**（2026-11-18 用户定："竖条不够明显，加背景"）的视觉契约：
/// primary 淡底（亮 8% / 暗 12%）+ [Tokens.radiusSm] 圆角。
///
/// 内距（`quoteBgPadding`）进不进预测的**几何**由 `block_height_predictor_
/// spike_test` 钉（逐像素）；这里钉"底色确实在、取对了色"——防止哪天优化时
/// 把外衣拆掉没人发现。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('引用块：primary 淡底 + 圆角 10', (WidgetTester tester) async {
    await loadAppFont();
    const EditorTypography typography = EditorTypography(
      fontSize: AppSettings.defaultFontSize,
      lineHeight: AppSettings.defaultLineHeight,
    );
    final ThemeData theme = AppTheme.light();
    final TextStyleConfiguration config = typography.toTextStyleConfiguration(
      text: theme.colorScheme.onSurface,
      link: theme.colorScheme.primary,
      codeBackground: theme.colorScheme.surfaceContainerHighest,
      muted: theme.colorScheme.onSurfaceVariant,
    );
    final EditorState state = EditorState(
      document: Document(
        root: pageNode(
          children: <Node>[quoteNode(delta: Delta()..insert('引用文本'))],
        ),
      ),
    );
    final EditorScrollController scroll = EditorScrollController(
      editorState: state,
    );
    addTearDown(() {
      scroll.dispose();
      state.dispose();
    });

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
              padding: EditorTypography.blockPadding,
              maxWidth: 800,
              textStyleConfiguration: config,
            ),
            blockComponentBuilders: sinanBlockComponentBuilders(
              typography: typography,
              markerColor: theme.colorScheme.primary,
            ),
            characterShortcutEvents: const <CharacterShortcutEvent>[],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // appflowy 正文是 RichText ⇒ find.text 要开 findRichText 才认。
    expect(
      find.text('引用文本', findRichText: true),
      findsOneWidget,
      reason: '引用正文应已渲染',
    );
    final Finder bg = find.ancestor(
      of: find.text('引用文本', findRichText: true),
      matching: find.byWidgetPredicate((Widget w) {
        if (w is! DecoratedBox || w.decoration is! BoxDecoration) return false;
        final BoxDecoration d = w.decoration as BoxDecoration;
        return d.color ==
            Bauhaus.quoteTint(Brightness.light, theme.colorScheme.primary);
      }),
    );
    expect(bg, findsOneWidget, reason: '引用正文应裹在 primary 淡底里');
    final BoxDecoration d =
        tester.widget<DecoratedBox>(bg).decoration as BoxDecoration;
    expect(
      d.borderRadius,
      BorderRadius.circular(Tokens.radiusSm),
      reason: '圆角 10',
    );

    // 背景**不带块手柄**（2026-11-18 用户定）：手柄是编辑器 chrome，不该被
    // 内容底色罩住；结构 = ActionWrapper[手柄, 淡底[内容]]。
    expect(
      find.ancestor(
        of: find.byType(tabler.Plus),
        matching: find.byWidgetPredicate((Widget w) {
          if (w is! DecoratedBox || w.decoration is! BoxDecoration) {
            return false;
          }
          final BoxDecoration dec = w.decoration as BoxDecoration;
          return dec.color ==
              Bauhaus.quoteTint(Brightness.light, theme.colorScheme.primary);
        }),
      ),
      findsNothing,
      reason: '块手柄要在淡底之外',
    );
  });
}
